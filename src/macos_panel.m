#include "macos.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>

@interface CWFlutterPanel : NSPanel
@end

@implementation CWFlutterPanel
- (BOOL)canBecomeKey {
  return YES;
}
- (BOOL)canBecomeMain {
  return YES;
}
// Borderless/nonactivating windows refuse to become the key window by
// default (canBecomeKeyWindow returns NO), so AppKit never routes keystrokes
// to them. Override it so the palette panel can accept keyboard input.
- (BOOL)canBecomeKeyWindow {
  return YES;
}
@end

static const void *kCWPanelFlagsKey = &kCWPanelFlagsKey;

static NSWindow *cw_find_window(void *handle) {
  if (!handle) {
    return nil;
  }
  NSWindow *target = (__bridge NSWindow *)handle;
  for (NSWindow *window in NSApp.windows) {
    if (window == target) {
      return window;
    }
  }
  return nil;
}

static uint32_t cw_panel_flags_for(NSWindow *window) {
  if (!window) {
    return 0;
  }
  NSNumber *flags = objc_getAssociatedObject(window, kCWPanelFlagsKey);
  return flags ? (uint32_t)flags.unsignedIntValue : 0;
}

static void cw_set_panel_flags_on(NSWindow *window, uint32_t flags) {
  if (!window) {
    return;
  }
  objc_setAssociatedObject(window, kCWPanelFlagsKey, @(flags),
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

EXPORT void cw_nswindow_set_panel_flags(void *ns_window, uint32_t flags) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  cw_set_panel_flags_on(window, flags);
}

// MARK: - Panel move delegate (live drags; port of window_lifecycle PanelMoveTracking)

@interface CWPanelMoveDelegate : NSObject <NSWindowDelegate>
@end

@implementation CWPanelMoveDelegate
+ (instancetype)shared {
  static CWPanelMoveDelegate *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [[CWPanelMoveDelegate alloc] init];
  });
  return instance;
}

- (void)windowDidMove:(NSNotification *)notification {
  NSWindow *window = notification.object;
  if ([window isKindOfClass:[NSWindow class]]) {
    cw_hooks_emit_window_moved((__bridge void *)window);
  }
}
@end

static void cw_attach_panel_move_delegate(NSWindow *window) {
  if (window.delegate == nil) {
    window.delegate = [CWPanelMoveDelegate shared];
  }
}

// MARK: - 60 Hz drag tracker during performDrag (port of DragMoveDisplayLinkTracker)

@interface CWDragMoveTracker : NSObject
+ (instancetype)shared;
- (void)beginTracking:(NSWindow *)window;
- (void)endTracking;
@end

@implementation CWDragMoveTracker {
  NSTimer *_timer;
  __weak NSWindow *_trackedWindow;
  NSRect _lastFrame;
}

+ (instancetype)shared {
  static CWDragMoveTracker *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    instance = [[CWDragMoveTracker alloc] init];
  });
  return instance;
}

- (void)beginTracking:(NSWindow *)window {
  [self endTracking];
  _trackedWindow = window;
  _lastFrame = window.frame;

  _timer = [NSTimer timerWithTimeInterval:(1.0 / 60.0)
                                  repeats:YES
                                    block:^(NSTimer *timer) {
                                      [self onTick];
                                    }];
  // .common keeps firing during performDrag's nested run loop.
  [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
}

- (void)endTracking {
  [_timer invalidate];
  _timer = nil;
  _trackedWindow = nil;
  _lastFrame = NSZeroRect;
}

- (void)onTick {
  NSWindow *window = _trackedWindow;
  if (!window) {
    [self endTracking];
    return;
  }

  NSRect frame = window.frame;
  if (!NSEqualRects(frame, _lastFrame)) {
    _lastFrame = frame;
    cw_hooks_emit_window_moved((__bridge void *)window);
  }

  if (NSEvent.pressedMouseButtons == 0) {
    cw_hooks_emit_window_moved((__bridge void *)window);
    [self endTracking];
  }
}

@end

EXPORT int32_t cw_nswindow_promote_to_panel(void *ns_window, bool floating) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return -1;
  }

  if ([window isKindOfClass:[NSPanel class]]) {
    return 1;
  }

  NSString *title = window.title;
  uint32_t panelFlags = cw_panel_flags_for(window);
  BOOL isStationary = (panelFlags & CW_PANEL_FLAG_STATIONARY) != 0;
  BOOL isImmovable = (panelFlags & CW_PANEL_FLAG_IMMOVABLE) != 0;

  NSViewController *contentViewController = window.contentViewController;
  BOOL isOpaque = window.isOpaque;
  NSColor *backgroundColor = window.backgroundColor;
  BOOL hasShadow = window.hasShadow;
  NSWindowLevel level = window.level;
  BOOL ignoresMouseEvents = window.ignoresMouseEvents;
  BOOL acceptsMouseMovedEvents = window.acceptsMouseMovedEvents;
  CGFloat alphaValue = window.alphaValue;

  NSRect panelFrame = window.frame;
  if (panelFrame.size.width < 1.0 || panelFrame.size.height < 1.0) {
    NSScreen *screen = window.screen ?: NSScreen.mainScreen;
    panelFrame = screen ? screen.frame : window.frame;
  }

  NSWindowStyleMask styleMask = floating ? (NSWindowStyleMaskBorderless |
                                            NSWindowStyleMaskNonactivatingPanel)
                                         : NSWindowStyleMaskBorderless;

  CWFlutterPanel *panel =
      [[CWFlutterPanel alloc] initWithContentRect:panelFrame
                                        styleMask:styleMask
                                          backing:NSBackingStoreBuffered
                                            defer:NO];

  panel.title = title;
  panel.opaque = isOpaque;
  panel.backgroundColor = backgroundColor;
  panel.hasShadow = hasShadow;
  panel.level = level;
  panel.contentViewController = contentViewController;
  panel.releasedWhenClosed = NO;
  panel.hidesOnDeactivate = NO;
  panel.movable = !isImmovable;
  panel.movableByWindowBackground = !isImmovable;
  panel.restorable = NO;
  panel.alphaValue = alphaValue;
  panel.acceptsMouseMovedEvents = acceptsMouseMovedEvents;
  panel.ignoresMouseEvents = ignoresMouseEvents;

  if (floating) {
    NSWindowCollectionBehavior behavior;
    if (isStationary) {
      behavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                 NSWindowCollectionBehaviorFullScreenAuxiliary |
                 NSWindowCollectionBehaviorStationary;
    } else {
      behavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                 NSWindowCollectionBehaviorFullScreenAuxiliary;
    }
    if (@available(macOS 13.0, *)) {
      behavior |= NSWindowCollectionBehaviorCanJoinAllApplications;
    }
    panel.collectionBehavior = behavior;
    panel.level = CGWindowLevelForKey(kCGMaximumWindowLevelKey);
  }

  id owner = window.delegate;
  if ([owner isKindOfClass:[NSObject class]]) {
    @try {
      [owner setValue:panel forKey:@"window"];
    } @catch (NSException *exception) {
      // FlutterWindowOwner may not expose KVC window ivar.
    }
  }

  window.delegate = nil;
  window.releasedWhenClosed = NO;
  [window orderOut:nil];
  window.contentView = nil;
  window.contentViewController = nil;

  panel.restorable = NO;
  [panel invalidateRestorableState];
  [panel setFrame:panelFrame display:YES];
  cw_set_panel_flags_on(panel, panelFlags);
  cw_attach_panel_move_delegate(panel);
  [panel makeKeyAndOrderFront:nil];

  return 0;
}

EXPORT void cw_nswindow_set_shadow(void *ns_window, bool has_shadow) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    window.hasShadow = has_shadow ? YES : NO;
  });
}

EXPORT void cw_nswindow_force_redraw(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [window displayIfNeeded];
    [window.contentView setNeedsDisplay:YES];
    [window.contentView displayIfNeeded];
  });
}

EXPORT void cw_nswindow_set_app_window_level(void *ns_window,
                                             int32_t level_offset) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }

  BOOL isStationary = (cw_panel_flags_for(window) & CW_PANEL_FLAG_STATIONARY) != 0;
  NSInteger maximumLevel = CGWindowLevelForKey(kCGMaximumWindowLevelKey);

  NSWindowLevel newLevel;
  NSWindowCollectionBehavior behavior;
  if (isStationary) {
    newLevel = maximumLevel;
    behavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
               NSWindowCollectionBehaviorFullScreenAuxiliary |
               NSWindowCollectionBehaviorStationary;
  } else {
    newLevel = maximumLevel + level_offset;
    behavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
               NSWindowCollectionBehaviorFullScreenAuxiliary;
  }
  if (@available(macOS 13.0, *)) {
    behavior |= NSWindowCollectionBehaviorCanJoinAllApplications;
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    window.level = newLevel;
    window.collectionBehavior = behavior;
    window.hidesOnDeactivate = NO;
  });
}

EXPORT void cw_nswindow_make_frameless(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }

  if ((cw_panel_flags_for(window) & CW_PANEL_FLAG_IMMOVABLE) != 0) {
    window.movable = NO;
    window.movableByWindowBackground = NO;
    return;
  }

  if ([window isKindOfClass:[NSPanel class]]) {
    window.styleMask |= NSWindowStyleMaskBorderless;
  } else {
    window.styleMask = NSWindowStyleMaskBorderless;
  }
  window.movableByWindowBackground = YES;
}

EXPORT void cw_nswindow_make_titleless(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.styleMask |= NSWindowStyleMaskFullSizeContentView;
}

EXPORT void cw_nswindow_start_drag(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  NSEvent *event = [NSApp currentEvent];
  if (!event) {
    event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                               location:[NSEvent mouseLocation]
                          modifierFlags:0
                              timestamp:0
                           windowNumber:window.windowNumber
                                context:nil
                            eventNumber:0
                             clickCount:1
                               pressure:1.0];
  }
  // 60 Hz frame sampling during performDrag's modal loop (window_lifecycle parity).
  [CWDragMoveTracker.shared beginTracking:window];
  [window performWindowDragWithEvent:event];
  [CWDragMoveTracker.shared endTracking];
}

EXPORT void cw_nswindow_make_key(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [window makeKeyAndOrderFront:nil];
  });
}

EXPORT void cw_nswindow_activate_app(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSApp activateIgnoringOtherApps:YES];
  });
}

EXPORT void cw_nswindow_center(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [window center];
  });
}

EXPORT void cw_nswindow_set_min_size(void *ns_window, double width,
                                     double height) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  window.contentMinSize = NSMakeSize(width, height);
}

EXPORT void cw_nswindow_order_front(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [window orderFront:nil];
  });
}

/// Hides the window without destroying it ([NSWindow orderOut:] — the
/// window stays alive and re-usable via [cw_nswindow_order_front]).
EXPORT void cw_nswindow_order_out(void *ns_window) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [window orderOut:nil];
  });
}

EXPORT void cw_nswindow_set_capture_exclusion(void *ns_window, bool exclude) {
  NSWindow *window = cw_find_window(ns_window);
  if (!window) {
    return;
  }
  if (@available(macOS 12.0, *)) {
    dispatch_async(dispatch_get_main_queue(), ^{
      window.sharingType =
          exclude ? NSWindowSharingNone : NSWindowSharingReadOnly;
    });
  }
}
