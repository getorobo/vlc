/*****************************************************************************
 * VLCPlaybackProgressSlider.m
 *****************************************************************************
 * Copyright (C) 2017 VLC authors and VideoLAN
 *
 * Authors: Marvin Scholz <epirat07 at gmail dot com>
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston MA 02110-1301, USA.
 *****************************************************************************/

#import "VLCPlaybackProgressSlider.h"

#import "extensions/NSString+Helpers.h"
#import "extensions/NSView+VLCAdditions.h"
#import "library/VLCInputItem.h"
#import "main/CompatibilityFixes.h"
#import "main/VLCMain.h"
#import "views/VLCPlaybackProgressSliderCell.h"

#import <vlc_preparser.h>

static const int kSeekThumbnailWidth = 192;
static const NSInteger kSeekThumbnailBuckets = 100;

typedef void (^VLCSeekThumbnailDone)(BOOL success);

// Runs on the thumbnailer thread; the block is a +1 retained copy.
static void seekThumbnailOnEnded(vlc_preparser_req *req, int status,
                                 const bool *results, size_t resultCount,
                                 void *data)
{
    @autoreleasepool {
        VLCSeekThumbnailDone done = (__bridge_transfer VLCSeekThumbnailDone)data;
        done(status == VLC_SUCCESS && resultCount == 1 && results != NULL && results[0]);
    }
    vlc_preparser_req_Release(req);
}

@implementation VLCPlaybackProgressSlider {
    NSTrackingArea *_hoverTrackingArea;
    NSWindow *_hoverWindow;
    NSTextField *_hoverLabel;
    NSImageView *_hoverImageView;

    NSCache<NSNumber *, NSImage *> *_thumbnailCache;
    NSInteger _wantedBucket;
    BOOL _thumbnailInFlight;
    // shortcut: one failed grab (audio-only, unsupported file) disables previews for this item, retry on next item
    BOOL _thumbnailFailed;
    NSUInteger _thumbnailGeneration; // bumped when item/duration change, drops stale results
    CGFloat _lastHoverX;
    vlc_tick_t _lastHoverTime;
}

+ (Class)cellClass
{
    return VLCPlaybackProgressSliderCell.class;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];

    if (self) {
        NSAssert([self.cell isKindOfClass:[VLCPlaybackProgressSlider cellClass]],
                 @"VLCPlaybackProgressSlider cell is not a VLCPlaybackProgressSliderCell");
        self.scrollable = YES;
        if (@available(macOS 10.14, *)) {
            [self viewDidChangeEffectiveAppearance];
            self.clipsToBounds = YES;
        } else {
            [(VLCPlaybackProgressSliderCell*)self.cell setSliderStyleLight];
        }

    }
    return self;
}

- (void)scrollWheel:(NSEvent *)event
{
    if (!self.scrollable) {
        return [super scrollWheel:event];
    }

    double increment;
    CGFloat deltaY = [event scrollingDeltaY];
    double range = [self maxValue] - [self minValue];

    // Scroll less for high precision, else it's too fast
    if (event.hasPreciseScrollingDeltas) {
        increment = (range * 0.002) * deltaY;
    } else {
        if (deltaY == 0.0) {
            return;
        }
        increment = (range * 0.01 * deltaY);
    }

    // If scrolling is inversed, increment in other direction
    if (!event.isDirectionInvertedFromDevice) {
        increment = -increment;
    }

    self.doubleValue = self.doubleValue - increment;
    [self sendAction:self.action to:self.target];
}

// Workaround for 10.7
// http://stackoverflow.com/questions/3985816/custom-nsslidercell
- (void)setNeedsDisplayInRect:(NSRect)invalidRect
{
    [super setNeedsDisplayInRect:self.bounds];
}

- (BOOL)indefinite
{
    return [(VLCPlaybackProgressSliderCell*)self.cell indefinite];
}

- (void)setIndefinite:(BOOL)indefinite
{
    [(VLCPlaybackProgressSliderCell*)self.cell setIndefinite:indefinite];
}

- (BOOL)knobHidden
{
    return [(VLCPlaybackProgressSliderCell*)self.cell knobHidden];
}

- (void)setKnobHidden:(BOOL)knobHidden
{
    [(VLCPlaybackProgressSliderCell*)self.cell setKnobHidden:knobHidden];
}

- (BOOL)isFlipped
{
    return NO;
}

- (void)viewDidChangeEffectiveAppearance
{
    if (self.shouldShowDarkAppearance) {
        [(VLCPlaybackProgressSliderCell*)self.cell setSliderStyleDark];
    } else {
        [(VLCPlaybackProgressSliderCell*)self.cell setSliderStyleLight];
    }
    [self applyHoverAppearance];
}

#pragma mark -
#pragma mark Hover tracking

- (void)installHoverTrackingAreaIfNeeded
{
    if (_hoverTrackingArea != nil) {
        return;
    }
    _hoverTrackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                      options:NSTrackingMouseEnteredAndExited | NSTrackingMouseMoved | NSTrackingInVisibleRect | NSTrackingActiveInKeyWindow
                                                        owner:self
                                                     userInfo:nil];
    [self addTrackingArea:_hoverTrackingArea];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    [self installHoverTrackingAreaIfNeeded];
}

- (void)viewDidMoveToWindow
{
    [super viewDidMoveToWindow];
    if (self.window == nil) {
        [self hideHoverWindow];
        return;
    }
    [self installHoverTrackingAreaIfNeeded];
}

- (void)dealloc
{
    [self hideHoverWindow];
}

- (BOOL)hoverIsAvailable
{
    return self.enabled && !self.indefinite && self.mediaDuration > 0;
}

- (void)createHoverWindowIfNeeded
{
    if (_hoverWindow != nil) {
        return;
    }

    _hoverLabel = [NSTextField labelWithString:@""];
    _hoverLabel.font =
        [NSFont monospacedDigitSystemFontOfSize:NSFont.smallSystemFontSize
                                         weight:NSFontWeightRegular];
    _hoverLabel.alignment = NSTextAlignmentCenter;
    _hoverLabel.textColor = NSColor.controlTextColor;

    _hoverImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    _hoverImageView.imageScaling = NSImageScaleProportionallyUpOrDown;

    NSView * const contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    contentView.wantsLayer = YES;
    contentView.layer.borderWidth = 0.5;
    contentView.layer.cornerRadius = 3.0;
    [contentView addSubview:_hoverImageView];
    [contentView addSubview:_hoverLabel];

    _hoverWindow = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 60, 20)
                                              styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    _hoverWindow.contentView = contentView;
    _hoverWindow.opaque = NO;
    _hoverWindow.backgroundColor = NSColor.clearColor;
    _hoverWindow.hasShadow = YES;
    _hoverWindow.ignoresMouseEvents = YES;
    _hoverWindow.releasedWhenClosed = NO;

    [self applyHoverAppearance];
}

- (void)applyHoverAppearance
{
    if (_hoverWindow == nil) {
        return;
    }
    NSView * const contentView = _hoverWindow.contentView;
    if (@available(macOS 11.0, *)) {
        _hoverWindow.appearance = self.effectiveAppearance;
        [self.effectiveAppearance performAsCurrentDrawingAppearance:^{
            contentView.layer.backgroundColor =
                [NSColor.controlBackgroundColor colorWithAlphaComponent:0.95].CGColor;
            contentView.layer.borderColor = NSColor.gridColor.CGColor;
        }];
        return;
    }
    if (@available(macOS 10.14, *)) {
        _hoverWindow.appearance = self.effectiveAppearance;
    }
    contentView.layer.backgroundColor =
        [NSColor.controlBackgroundColor colorWithAlphaComponent:0.95].CGColor;
    contentView.layer.borderColor = NSColor.gridColor.CGColor;
}

- (void)hideHoverWindow
{
    if (_hoverWindow == nil) {
        return;
    }
    NSWindow * const parent = _hoverWindow.parentWindow;
    if (parent != nil) {
        [parent removeChildWindow:_hoverWindow];
    }
    [_hoverWindow orderOut:nil];
}

- (void)showHoverAtSliderX:(CGFloat)xInSlider time:(vlc_tick_t)time
{
    NSWindow * const parentWindow = self.window;
    if (parentWindow == nil) {
        return;
    }

    [self createHoverWindowIfNeeded];

    _hoverLabel.stringValue = [NSString stringWithTimeFromTicks:time];
    [_hoverLabel sizeToFit];

    const NSSize textSize = _hoverLabel.frame.size;
    const CGFloat horizontalPadding = 6.0;
    const CGFloat verticalPadding = 2.0;
    const CGFloat verticalGap = 6.0;

    _lastHoverX = xInSlider;
    _lastHoverTime = time;
    [self updateHoverImageForTime:time];

    const NSSize imageSize = _hoverImageView.image ? _hoverImageView.image.size : NSZeroSize;
    const CGFloat contentWidth = MAX(textSize.width, imageSize.width);
    const CGFloat imageBlockHeight = imageSize.height > 0 ? imageSize.height + verticalPadding : 0.0;
    const NSSize windowSize = NSMakeSize(contentWidth + horizontalPadding * 2.0,
                                         textSize.height + imageBlockHeight + verticalPadding * 2.0);
    _hoverLabel.frame = NSMakeRect((windowSize.width - textSize.width) / 2.0, verticalPadding,
                                   textSize.width, textSize.height);
    _hoverImageView.frame = NSMakeRect((windowSize.width - imageSize.width) / 2.0,
                                       verticalPadding * 2.0 + textSize.height,
                                       imageSize.width, imageSize.height);
    _hoverImageView.hidden = imageSize.height <= 0;

    const NSRect sliderOnScreen =
        [parentWindow convertRectToScreen:[self convertRect:self.bounds toView:nil]];
    const CGFloat anchorScreenX = NSMinX(sliderOnScreen) + xInSlider;

    CGFloat originX = anchorScreenX - windowSize.width / 2.0;
    originX = MAX(NSMinX(sliderOnScreen),
                  MIN(originX, NSMaxX(sliderOnScreen) - windowSize.width));
    const CGFloat originY = NSMaxY(sliderOnScreen) + verticalGap;

    [_hoverWindow setFrame:NSMakeRect(originX, originY,
                                      windowSize.width, windowSize.height)
                   display:YES];

    if (_hoverWindow.parentWindow != parentWindow) {
        [parentWindow addChildWindow:_hoverWindow ordered:NSWindowAbove];
    } else if (!_hoverWindow.visible) {
        [_hoverWindow orderFront:nil];
    }
}

#pragma mark Hover thumbnail

- (BOOL)thumbnailsAvailable
{
    return !_thumbnailFailed && _thumbnailInputItem != nil && !_thumbnailInputItem.isStream &&
           getThumbnailer() != NULL && _mediaDuration > 0;
}

- (vlc_tick_t)thumbnailBucketStep
{
    return MAX(_mediaDuration / kSeekThumbnailBuckets, VLC_TICK_FROM_SEC(1));
}

// Shows the cached frame for `time`, or keeps the previous one until the new one arrives.
- (void)updateHoverImageForTime:(vlc_tick_t)time
{
    if (![self thumbnailsAvailable]) {
        _hoverImageView.image = nil;
        return;
    }

    _wantedBucket = time / [self thumbnailBucketStep];
    NSImage * const cached = [_thumbnailCache objectForKey:@(_wantedBucket)];
    if (cached) {
        _hoverImageView.image = cached;
    } else {
        [self fetchWantedThumbnail];
    }
}

// One request in flight at a time; when it ends we fetch whatever is wanted by then.
- (void)fetchWantedThumbnail
{
    if (_thumbnailInFlight) {
        return;
    }
    if (_thumbnailCache == nil) {
        _thumbnailCache = [[NSCache alloc] init];
        _thumbnailCache.countLimit = kSeekThumbnailBuckets;
    }

    const NSInteger bucket = _wantedBucket;
    if ([_thumbnailCache objectForKey:@(bucket)]) {
        return;
    }

    NSString * const path = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"vlc-seekthumb-%@.jpg", NSUUID.UUID.UUIDString]];
    const struct vlc_thumbnailer_arg arg = {
        .seek = {
            .type = VLC_THUMBNAILER_SEEK_TIME,
            .time = bucket * [self thumbnailBucketStep],
            .speed = VLC_THUMBNAILER_SEEK_FAST,
        },
        .hw_dec = false,
    };
    const struct vlc_thumbnailer_output output = {
        .format = VLC_THUMBNAILER_FORMAT_JPEG,
        .width = kSeekThumbnailWidth,
        .height = 0, // keep aspect ratio
        .crop = false,
        .file_path = path.fileSystemRepresentation,
        .creat_mode = 0600,
    };
    static const struct vlc_thumbnailer_to_files_cbs cbs = {
        .on_ended = seekThumbnailOnEnded,
    };

    const NSUInteger generation = _thumbnailGeneration;
    __weak VLCPlaybackProgressSlider * const weakSelf = self;
    VLCSeekThumbnailDone done = ^(BOOL success) {
        NSImage * const image = success ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf thumbnailDidFinish:image bucket:bucket generation:generation];
        });
    };

    // The callback takes ownership of this retain; we only drop it if it can never run.
    void * const context = (__bridge_retained void *)[done copy];
    vlc_preparser_t * const thumbnailer = getThumbnailer();
    vlc_preparser_req * const req = vlc_preparser_req_NewThumbnailToFiles(
        thumbnailer, _thumbnailInputItem.vlcInputItem, &arg, &output, 1, &cbs, context);
    if (req == NULL) {
        (void)(__bridge_transfer id)context;
        _thumbnailFailed = YES;
        return;
    }
    _thumbnailInFlight = YES;
    if (vlc_preparser_Submit(thumbnailer, req) != VLC_SUCCESS) {
        vlc_preparser_req_Release(req);
        (void)(__bridge_transfer id)context;
        _thumbnailInFlight = NO;
        _thumbnailFailed = YES;
    }
}

- (void)thumbnailDidFinish:(NSImage *)image bucket:(NSInteger)bucket generation:(NSUInteger)generation
{
    _thumbnailInFlight = NO;
    if (generation != _thumbnailGeneration) {
        return;
    }

    if (image) {
        [_thumbnailCache setObject:image forKey:@(bucket)];
    } else {
        _thumbnailFailed = YES;
        _hoverImageView.image = nil;
    }

    if (_hoverWindow.visible) {
        if (_wantedBucket == bucket) {
            [self showHoverAtSliderX:_lastHoverX time:_lastHoverTime];
        } else {
            [self fetchWantedThumbnail];
        }
    }
}

- (void)reportHoverAtPoint:(NSPoint)locationInSelf
{
    if (![self hoverIsAvailable]) {
        [self hideHoverWindow];
        return;
    }

    const NSRect trackRect = [(NSSliderCell *)self.cell barRectFlipped:NO];
    if (NSWidth(trackRect) <= 0) {
        [self hideHoverWindow];
        return;
    }

    CGFloat fraction = (locationInSelf.x - NSMinX(trackRect)) / NSWidth(trackRect);
    if (fraction < 0.0) {
        fraction = 0.0;
    } else if (fraction > 1.0) {
        fraction = 1.0;
    }

    const vlc_tick_t time = (vlc_tick_t)(fraction * self.mediaDuration);
    [self showHoverAtSliderX:locationInSelf.x time:time];
}

- (void)mouseEntered:(NSEvent *)event
{
    [self reportHoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseMoved:(NSEvent *)event
{
    [self reportHoverAtPoint:[self convertPoint:event.locationInWindow fromView:nil]];
}

- (void)mouseExited:(NSEvent *)event
{
    [self hideHoverWindow];
}

- (void)mouseDown:(NSEvent *)event
{
    // NSSlider runs its own tracking loop here; mouseMoved is not delivered
    // during the drag, so the hover would otherwise show a stale time.
    [self hideHoverWindow];
    [super mouseDown:event];
}

- (void)resetThumbnails
{
    _thumbnailGeneration++;
    _thumbnailFailed = NO;
    [_thumbnailCache removeAllObjects];
    _hoverImageView.image = nil;
}

- (void)setThumbnailInputItem:(VLCInputItem *)item
{
    // The controls bar calls this on every position update with the same item.
    if (_thumbnailInputItem.vlcInputItem == item.vlcInputItem) {
        return;
    }
    _thumbnailInputItem = item;
    [self resetThumbnails];
}

- (void)setMediaDuration:(vlc_tick_t)mediaDuration
{
    if (mediaDuration != _mediaDuration) {
        [self resetThumbnails];
    }
    _mediaDuration = mediaDuration;
    if (![self hoverIsAvailable]) {
        [self hideHoverWindow];
    }
}

@end
