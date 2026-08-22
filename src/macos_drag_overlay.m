#include "macos.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

// All entry points are called from the Flutter UI isolate, which runs ON the
// main thread — dispatch_sync onto the main queue from there would deadlock,
// so AppKit work runs inline when already on main (and hops only if not).
static void cwRunOnMainSync(void (^block)(void)) {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_sync(dispatch_get_main_queue(), block);
  }
}

// Live overlay windows and their source-pixel sizes, keyed by the retained
// handle. Pixel size drives contentsScale so a capture taken at a different
// DPR than the target screen still renders at its exact logical size.
static NSMutableDictionary<NSValue *, NSWindow *> *gOverlayWindows = nil;
static NSMutableDictionary<NSValue *, NSValue *> *gOverlayPixels = nil;

static NSValue *BoxHandle(void *handle) {
  return [NSValue valueWithPointer:handle];
}

static void EnsureRegistries(void) {
  if (gOverlayWindows == nil) {
    gOverlayWindows = [NSMutableDictionary dictionary];
    gOverlayPixels = [NSMutableDictionary dictionary];
  }
}

static NSScreen *ScreenForPoint(NSPoint p) {
  for (NSScreen *s in [NSScreen screens]) {
    if (NSPointInRect(p, s.frame)) return s;
  }
  return [NSScreen mainScreen] ?: [NSScreen screens].firstObject;
}

static NSRect GlobalScreenFrame(void) {
  NSRect r = NSZeroRect;
  for (NSScreen *s in [NSScreen screens]) {
    if (NSIsEmptyRect(r)) r = s.frame;
    else r = NSUnionRect(r, s.frame);
  }
  return r;
}

EXPORT void *cw_drag_overlay_create(void) {
  __block NSWindow *window = nil;
  cwRunOnMainSync(^{
    EnsureRegistries();
    NSRect frame = NSMakeRect(0, 0, 100, 40);
    window = [[NSWindow alloc]
        initWithContentRect:frame
                  styleMask:NSWindowStyleMaskBorderless
                    backing:NSBackingStoreBuffered
                      defer:NO];
    window.opaque = NO;
    window.backgroundColor = [NSColor clearColor];
    // The captured pill already carries its own baked-in shadow margin;
    // a window shadow would double it.
    window.hasShadow = NO;
    window.ignoresMouseEvents = YES;
    window.movable = NO;
    window.movableByWindowBackground = NO;
    window.releasedWhenClosed = NO;
    window.hidesOnDeactivate = NO;
    window.level = NSPopUpMenuWindowLevel;
    // CanJoinAllSpaces and MoveToActiveSpace are mutually exclusive; AppKit
    // raises NSInternalInconsistencyException if both are set.
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                                NSWindowCollectionBehaviorTransient;
    window.sharingType = NSWindowSharingNone;
    window.contentView.wantsLayer = YES;
    window.contentView.layer.backgroundColor = [NSColor clearColor].CGColor;
    window.contentView.layer.opaque = NO;
    window.contentView.layer.masksToBounds = NO;
    window.alphaValue = 1.0;
    [window orderFrontRegardless];
  });
  if (!window) return NULL;
  // Retain for FFI lifetime; released in cw_drag_overlay_destroy.
  void *handle = (__bridge_retained void *)window;
  cwRunOnMainSync(^{
    EnsureRegistries();
    gOverlayWindows[BoxHandle(handle)] = window;
  });
  return handle;
}

static void ReleaseCopiedBytes(void *info, const void *data, size_t size) {
  (void)info; (void)size;
  free((void *)data);
}

EXPORT void cw_drag_overlay_set_image(void *handle, const uint8_t *rgba, int32_t width, int32_t height) {
  if (!handle || !rgba || width <= 0 || height <= 0) return;
  size_t len = (size_t)width * height * 4;
  uint8_t *copy = (uint8_t *)malloc(len);
  if (!copy) return;
  memcpy(copy, rgba, len);
  cwRunOnMainSync(^{
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window) { free(copy); return; }
    size_t bytesPerRow = (size_t)width * 4;
    CGDataProviderRef provider = CGDataProviderCreateWithData(
        NULL, copy, len, ReleaseCopiedBytes);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cg = CGImageCreate(
        width, height, 8, 32, bytesPerRow, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
        provider, NULL, false, kCGRenderingIntentDefault);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(cs);
    if (!cg) return;

    EnsureRegistries();
    gOverlayPixels[BoxHandle(handle)] = [NSValue valueWithSize:NSMakeSize(width, height)];
    NSView *contentView = window.contentView;
    contentView.wantsLayer = YES;
    contentView.layer.contents = (__bridge id)cg;
    contentView.layer.contentsGravity = kCAGravityTopLeft;
    CGImageRelease(cg);
    [window displayIfNeeded];
  });
}

static void ApplyContentsScale(NSWindow *window, double logicalWidth) {
  NSView *contentView = window.contentView;
  if (!contentView.layer) return;
  NSValue *pix = gOverlayPixels[BoxHandle((__bridge void *)window)];
  NSSize pixelSize = pix ? pix.sizeValue : NSZeroSize;
  if (logicalWidth > 0 && pixelSize.width > 0) {
    // Render the captured pixels at their original logical footprint,
    // independent of the target screen's backing scale.
    contentView.layer.contentsScale = pixelSize.width / logicalWidth;
  } else {
    NSScreen *screen = window.screen ?: [NSScreen mainScreen];
    contentView.layer.contentsScale = screen ? screen.backingScaleFactor : 2.0;
  }
}

EXPORT void cw_drag_overlay_set_frame(void *handle, double x, double y, double w, double h) {
  if (!handle) return;
  cwRunOnMainSync(^{
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window) return;
    // x,y are Flutter top-left logical points; convert to AppKit bottom-left.
    NSRect global = GlobalScreenFrame();
    NSRect frame = NSMakeRect(x, global.origin.y + global.size.height - (y + h), w, h);
    [window setFrame:frame display:YES];
    [window orderFrontRegardless];
    ApplyContentsScale(window, w);
  });
}

EXPORT void cw_drag_overlay_set_frame_bottom_left(void *handle, double x, double y, double w, double h) {
  if (!handle) return;
  cwRunOnMainSync(^{
    NSWindow *window = (__bridge NSWindow *)handle;
    if (!window) return;
    [window setFrame:NSMakeRect(x, y, w, h) display:YES];
    [window orderFrontRegardless];
    ApplyContentsScale(window, w);
  });
}

EXPORT void cw_drag_overlay_destroy(void *handle) {
  if (!handle) return;
  cwRunOnMainSync(^{
    EnsureRegistries();
    [gOverlayWindows removeObjectForKey:BoxHandle(handle)];
    [gOverlayPixels removeObjectForKey:BoxHandle(handle)];
    NSWindow *window = (__bridge_transfer NSWindow *)handle;
    [window orderOut:nil];
    [window close];
  });
}

EXPORT void cw_drag_overlay_mouse_location(double *out_x, double *out_y) {
  if (!out_x || !out_y) return;
  __block NSPoint p = NSZeroPoint;
  cwRunOnMainSync(^{
    p = [NSEvent mouseLocation];
  });
  *out_x = p.x;
  *out_y = p.y;
}

EXPORT void cw_drag_overlay_visible_frame(double *out_x, double *out_y, double *out_w, double *out_h) {
  if (!out_x || !out_y || !out_w || !out_h) return;
  __block NSRect vf = NSZeroRect;
  cwRunOnMainSync(^{
    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen *s = ScreenForPoint(mouse);
    vf = s ? s.visibleFrame : [NSScreen mainScreen].visibleFrame;
  });
  // AppKit bottom-left coords.
  *out_x = vf.origin.x;
  *out_y = vf.origin.y;
  *out_w = vf.size.width;
  *out_h = vf.size.height;
}

EXPORT double cw_drag_overlay_screen_height(void) {
  __block double height = 0;
  cwRunOnMainSync(^{
    height = GlobalScreenFrame().size.height;
  });
  return height;
}

EXPORT double cw_drag_overlay_backing_scale(void) {
  __block double scale = 2.0;
  cwRunOnMainSync(^{
    NSPoint mouse = [NSEvent mouseLocation];
    NSScreen *s = ScreenForPoint(mouse);
    scale = s ? s.backingScaleFactor : ([NSScreen mainScreen].backingScaleFactor ?: 2.0);
  });
  return scale;
}

EXPORT int32_t cw_drag_overlay_left_mouse_down(void) {
  return (NSEvent.pressedMouseButtons & 1) != 0 ? 1 : 0;
}

EXPORT int32_t cw_drag_overlay_right_mouse_down(void) {
  return (NSEvent.pressedMouseButtons & 2) != 0 ? 1 : 0;
}
