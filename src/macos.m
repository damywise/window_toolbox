#include "macos.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>

#import "window_buttons_proxy.h"

static BOOL cw_mouseDownCanMoveWindow(id self, SEL _cmd) { return YES; }

@interface CWDefaultWindowDelegate : NSObject <NSWindowDelegate>

@end

@interface CWWindowDelegate : NSObject <NSWindowDelegate>

@end

@interface CWDelegateState : NSObject {
@public
  cw_delegate_config_t _config;
}
@end

static size_t associate_object_key;

@implementation CWDelegateState
- (instancetype)initWithConfig:(cw_delegate_config_t)config {
  if (self = [super init]) {
    _config = config;
  }
  return self;
}

- (void)setForObject:(id)object {
  objc_setAssociatedObject(object, &associate_object_key, self,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

+ (CWDelegateState *)stateForObject:(id)object {
  return objc_getAssociatedObject(object, &associate_object_key);
}

@end

// We can call the original method (through [self __xxx]) because we know that
// the delegate implements all NSWindowDelegate method because we added them
// in the initSwizzleIfNeeded method.
@implementation CWWindowDelegate

- (void)__windowWillEnterFullScreen:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_will_enter_fullscreen();
  }
  [self __windowWillEnterFullScreen:notification];
}

- (void)__windowDidEnterFullScreen:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_did_enter_fullscreen();
  }
  [self __windowDidEnterFullScreen:notification];
}

- (void)__windowWillExitFullScreen:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_will_exit_fullscreen();
  }
  [self __windowWillExitFullScreen:notification];
}

- (void)__windowDidExitFullScreen:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_did_exit_fullscreen();
  }
  [self __windowDidExitFullScreen:notification];
}

- (NSSize)__windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    cw_size_t new_size = {frameSize.width, frameSize.height};
    cw_size_t size = state->_config.on_window_will_resize(new_size);
    if (size.w >= 0 && size.h >= 0) {
      return NSMakeSize(size.w, size.h);
    }
  }
  return [self __windowWillResize:sender toSize:frameSize];
}

- (void)__windowWillStartLiveResize:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_will_start_live_resize();
  }
  [self __windowWillStartLiveResize:notification];
}

- (void)__windowDidEndLiveResize:(NSNotification *)notification {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_did_end_live_resize();
  }
  [self __windowDidEndLiveResize:notification];
}

// This depends on particular method that's not part of window delegate :-/
- (void)__windowWillClose {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    state->_config.on_window_will_close();
  }
  [self __windowWillClose];
}

- (NSRect)__windowWillUseStandardFrame:(NSWindow *)window
                          defaultFrame:(NSRect)newFrame {
  CWDelegateState *state = [CWDelegateState stateForObject:self];
  if (state) {
    cw_rect_t new_frame = {newFrame.origin.x, newFrame.origin.y,
                           newFrame.size.width, newFrame.size.height};
    cw_rect_t frame =
        state->_config.on_window_will_use_standard_frame(new_frame);
    if (frame.w >= 0 && frame.h >= 0) {
      return NSMakeRect(frame.x, frame.y, frame.w, frame.h);
    }
  }
  return [self __windowWillUseStandardFrame:window defaultFrame:newFrame];
}

@end

static void initSwizzleIfNeeded() {
  static bool initialized = false;
  if (!initialized) {
    NSString *typeEncoding = [NSString stringWithFormat:@"%s@:", @encode(BOOL)];
    Class flutterViewClass = NSClassFromString(@"FlutterView");
    class_addMethod(flutterViewClass, @selector(mouseDownCanMoveWindow),
                    (IMP)cw_mouseDownCanMoveWindow, [typeEncoding UTF8String]);
    Class flutterViewWrapperClass = NSClassFromString(@"FlutterViewWrapper");
    class_addMethod(flutterViewWrapperClass, @selector(mouseDownCanMoveWindow),
                    (IMP)cw_mouseDownCanMoveWindow, [typeEncoding UTF8String]);

    Class FlutterWindowOwner = NSClassFromString(@"FlutterWindowOwner");

    // Add all missing methods from CWDefaultWindowDelegate to
    // FlutterWindowingOwner
    unsigned int methodCount = 0;
    Method *methods =
        class_copyMethodList([CWDefaultWindowDelegate class], &methodCount);
    for (unsigned int i = 0; i < methodCount; i++) {
      Method method = methods[i];
      SEL selector = method_getName(method);
      NSString *selectorName = NSStringFromSelector(selector);
      const char *typeEncoding = method_getTypeEncoding(method);
      if (class_getInstanceMethod(FlutterWindowOwner, selector) == NULL) {
        class_addMethod(FlutterWindowOwner, selector,
                        method_getImplementation(method), typeEncoding);
      }
    }
    free(methods);

    // Swizzle all methods from CWWindowDelegate with FlutterWindowOwner
    methodCount = 0;
    methods = class_copyMethodList([CWWindowDelegate class], &methodCount);
    // Go through all methods and exchange implementations with
    // FlutterWindowOwner
    for (unsigned int i = 0; i < methodCount; i++) {
      Method method = methods[i];
      SEL selector = method_getName(method);
      NSString *selectorName = NSStringFromSelector(selector);
      if ([selectorName hasPrefix:@"__"]) {
        NSString *originalSelectorName =
            [selectorName substringFromIndex:2]; // Remove __ prefix
        SEL originalSelector = NSSelectorFromString(originalSelectorName);
        const char *typeEncoding = method_getTypeEncoding(method);
        class_addMethod(FlutterWindowOwner, selector,
                        method_getImplementation(method), typeEncoding);
        method_exchangeImplementations(
            class_getInstanceMethod(FlutterWindowOwner, originalSelector),
            class_getInstanceMethod(FlutterWindowOwner, selector));
      }
    }
    free(methods);

    initialized = true;
  }
}

@interface CWWindowDragPreventer : NSView

@end

@implementation CWWindowDragPreventer

- (NSRect)_opaqueRectForWindowMoveWhenInTitlebar {
  return self.bounds;
}

- (BOOL)mouseDownCanMoveWindow {
  return NO;
}

- (NSView *)hitTest:(NSPoint)point {
  return nil;
}

@end

@interface CWWindowDraggingView : NSView {
  NSMutableArray<CWWindowDragPreventer *> *_dragExclusion;
  CWWindowButtonsProxy *trafficLight;
}

@end

@implementation CWWindowDraggingView

- (instancetype)initWithFrame:(NSRect)frameRect {
  if (self = [super initWithFrame:frameRect]) {
    _dragExclusion = [NSMutableArray new];
  }
  return self;
}

+ (CWWindowDraggingView *)forWindow:(NSWindow *)window {
  if (![window.contentView isKindOfClass:[CWWindowDraggingView class]]) {
    CWWindowDraggingView *view =
        [[CWWindowDraggingView alloc] initWithFrame:window.contentView.bounds];
    NSView *oldContentView = window.contentView;
    [view addSubview:window.contentView];
    window.contentView = view;
    oldContentView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  }
  return window.contentView;
}

- (CWWindowButtonsProxy *)trafficLight {
  if (trafficLight == nil) {
    trafficLight = [[CWWindowButtonsProxy alloc] initWithContainer:self];
  }
  return trafficLight;
}

- (void)layout {
  [[self trafficLight] performLayout];
}

- (BOOL)isFlipped {
  return YES;
}

- (BOOL)mouseDownCanMoveWindow {
  return YES;
}

- (void)updateExclusions:(cw_rect_t *)exclude withCount:(size_t)excludeCount {
  if (_dragExclusion.count > excludeCount) {
    [_dragExclusion
        removeObjectsInRange:NSMakeRange(excludeCount,
                                         _dragExclusion.count - excludeCount)];
  }
  while (_dragExclusion.count < excludeCount) {
    CWWindowDragPreventer *preventer = [CWWindowDragPreventer new];
    [self addSubview:preventer];
    [_dragExclusion addObject:preventer];
  }
  for (size_t i = 0; i < excludeCount; i++) {
    CWWindowDragPreventer *preventer = _dragExclusion[i];
    cw_rect_t rect = exclude[i];
    preventer.frame = NSMakeRect(rect.x, rect.y, rect.w, rect.h);
  }
}

@end

void cw_nswindow_remove_titlebar(void *ns_window) {
  initSwizzleIfNeeded();
  NSWindow *window = (__bridge NSWindow *)ns_window;
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  window.styleMask |= NSWindowStyleMaskFullSizeContentView;
}

void cw_nswindow_init_delegate(void *ns_window, cw_delegate_config_t config) {
  initSwizzleIfNeeded();
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  id<NSWindowDelegate> delegate = window.delegate;
  if (!delegate) {
    return;
  }
  CWDelegateState *state = [[CWDelegateState alloc] initWithConfig:config];
  [state setForObject:delegate];

  // Seems like NSWindow will query delegate for supported methods when setting
  // the delegate. It is possible that we have swizzled the delegate methods
  // after it was already set to window, so we temporarily set it to nil and
  // then back to original delegate. Otherwise some newly added methods such as
  // windowDidEnterFullScreen might not be called.
  window.delegate = nil;
  window.delegate = delegate;
}

EXPORT void cw_nswindow_update_draggable_areas(void *ns_window,
                                               cw_rect_t *exclude,
                                               size_t exclude_count) {
  initSwizzleIfNeeded();
  NSWindow *window = (__bridge NSWindow *)ns_window;
  [window setMovableByWindowBackground:YES];

  CWWindowDraggingView *draggingView = [CWWindowDraggingView forWindow:window];
  [draggingView updateExclusions:exclude withCount:exclude_count];
}

void cw_nswindow_disable_draggable_areas(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  [window setMovableByWindowBackground:NO];
}

void cw_nswindow_request_close(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  [window performClose:nil];
}

void cw_nswindow_set_style_mask(void *ns_window, unsigned long style_mask) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  window.styleMask = style_mask;
  CWWindowDraggingView *draggingView = [CWWindowDraggingView forWindow:window];
  [draggingView.trafficLight performLayout];
}

unsigned long cw_nswindow_get_style_mask(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  return window.styleMask;
}

void cw_nswindow_set_collection_behavior(void *ns_window,
                                         unsigned long collection_behavior) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  window.collectionBehavior = collection_behavior;
}

unsigned long cw_nswindow_get_collection_behavior(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  return window.collectionBehavior;
}

static NSColor *colorFromARGB(int64_t color) {
  CGFloat a = ((color >> 24) & 0xFF) / 255.0;
  CGFloat r = ((color >> 16) & 0xFF) / 255.0;
  CGFloat g = ((color >> 8) & 0xFF) / 255.0;
  CGFloat b = (color & 0xFF) / 255.0;
  return [NSColor colorWithRed:r green:g blue:b alpha:a];
}

void cw_nswindow_update_traffic_light(void *ns_window,
                                      const cw_traffic_light_config_t *config) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  CWWindowDraggingView *draggingView = [CWWindowDraggingView forWindow:window];
  CWWindowButtonsProxy *trafficLight = draggingView.trafficLight;

  NSPoint margin = NSMakePoint(config->offset_x, config->offset_y);
  [trafficLight setMargin:&margin];

  NSAppearance *appearance = nil;
  if (config->appearance == CW_APPEARANCE_LIGHT) {
    appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
  } else if (config->appearance == CW_APPEARANCE_DARK) {
    appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
  }
  [trafficLight setButttonAppearance:appearance];

  if (config->custom_inactive_traffic_light) {
    CWWindowButtonsProxyInactiveConfiguration *inactiveConfig =
        [CWWindowButtonsProxyInactiveConfiguration new];
    inactiveConfig.showAsInactiveInKeyWindow =
        config->show_as_inactive_in_key_window;
    inactiveConfig.backgroundColor =
        colorFromARGB(config->inactive_background_color);
    inactiveConfig.borderColor = colorFromARGB(config->inactive_border_color);
    inactiveConfig.borderWidth = config->inactive_border_width;
    [trafficLight setInactiveConfiguration:inactiveConfig];
  }
}

cw_size_t cw_nswindow_traffic_light_size(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  CWWindowDraggingView *draggingView = [CWWindowDraggingView forWindow:window];
  CWWindowButtonsProxy *trafficLight = draggingView.trafficLight;
  NSRect bounds = [trafficLight getButtonsBounds];
  return (cw_size_t){bounds.size.width, bounds.size.height};
}

static NSRect computeGlobalScreenFrame() {
  NSRect frame = NSZeroRect;
  for (NSScreen *screen in [NSScreen screens]) {
    NSRect screenFrame = screen.frame;
    if (NSIsEmptyRect(frame)) {
      frame = screenFrame;
    } else {
      frame = NSUnionRect(frame, screenFrame);
    }
  }
  return frame;
}

static void flipRect(NSRect *rect, const NSRect *globalScreenFrame) {
  // Flip the y coordinate to match Flutter coordinate system.
  rect->origin.y =
      (globalScreenFrame->origin.y + globalScreenFrame->size.height) -
      (rect->origin.y + rect->size.height);
}

void cw_nswindow_set_frame(void *ns_window, cw_rect_t frame) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSRect newFrame = NSMakeRect(frame.x, frame.y, frame.w, frame.h);
  NSRect globalScreenFrame = computeGlobalScreenFrame();
  flipRect(&newFrame, &globalScreenFrame);
  [window setFrame:newFrame display:YES];
}

EXPORT void cw_nswindow_set_frame_bottom_left(void *ns_window, cw_rect_t frame) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSRect newFrame = NSMakeRect(frame.x, frame.y, frame.w, frame.h);
  [window setFrame:newFrame display:YES];
}

EXPORT cw_rect_t cw_nswindow_get_frame_bottom_left(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSRect frame = window.frame;
  return (cw_rect_t){frame.origin.x, frame.origin.y, frame.size.width,
                     frame.size.height};
}

EXPORT void cw_nswindow_set_fullscreen_on_screen_index(void *ns_window,
                                                       int32_t screen_index) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if (screen_index < 0 || screen_index >= (int32_t)screens.count) {
    return;
  }
  NSScreen *screen = screens[screen_index];
  NSRect screenFrame = screen.frame;
  CGFloat width = screenFrame.size.width;
  if (width > 1.0) {
    width -= 1.0;
  }
  NSRect target = NSMakeRect(screenFrame.origin.x, screenFrame.origin.y, width,
                             screenFrame.size.height);
  [window setFrame:target display:YES];
}

EXPORT void cw_nswindow_position_on_screen_index(void *ns_window,
                                                 int32_t screen_index) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if (screen_index < 0 || screen_index >= (int32_t)screens.count) {
    return;
  }
  NSScreen *screen = screens[screen_index];
  // visibleFrame excludes menu bar / dock on that screen (drawing overlay fit).
  NSRect screenFrame = screen.visibleFrame;
  CGFloat width = screenFrame.size.width;
  if (width > 1.0) {
    width -= 1.0;
  }
  NSRect target = NSMakeRect(screenFrame.origin.x, screenFrame.origin.y, width,
                             screenFrame.size.height);
  [window setFrame:target display:YES];
}

cw_rect_t cw_nswindow_get_frame(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  NSRect frame = window.frame;
  NSRect globalScreenFrame = computeGlobalScreenFrame();
  flipRect(&frame, &globalScreenFrame);
  return (cw_rect_t){frame.origin.x, frame.origin.y, frame.size.width,
                     frame.size.height};
}

/// Visible frame (excludes menu bar / dock) of [NSScreen screens][index].
/// Returned in the same FLIPPED top-left global-union space as
/// [cw_nswindow_get_frame] / [cw_nswindow_set_frame], so callers can hand it
/// straight to [cw_nswindow_set_frame] without further Y conversions.
EXPORT cw_rect_t cw_nsscreen_visible_frame(int32_t screen_index) {
  NSArray<NSScreen *> *screens = [NSScreen screens];
  if (screen_index < 0 || screen_index >= (int32_t)screens.count) {
    return (cw_rect_t){0, 0, 0, 0};
  }
  NSRect frame = [screens[screen_index] visibleFrame];
  NSRect globalScreenFrame = computeGlobalScreenFrame();
  flipRect(&frame, &globalScreenFrame);
  return (cw_rect_t){frame.origin.x, frame.origin.y, frame.size.width,
                     frame.size.height};
}

EXPORT void cw_nswindow_set_alpha(void *ns_window, double alpha) {
    NSWindow *window = (__bridge NSWindow *)ns_window;
    [window setAlphaValue:alpha];
}

EXPORT void cw_nswindow_set_level(void *ns_window, int level) {
    NSWindow *window = (__bridge NSWindow *)ns_window;
    [window setLevel:level];
}

EXPORT void cw_nswindow_set_ignores_mouse_events(void *ns_window, bool ignores) {
    NSWindow *window = (__bridge NSWindow *)ns_window;
    [window setIgnoresMouseEvents:ignores];
}

EXPORT void cw_nswindow_set_corner_radius(void *ns_window, double radius) {
    NSWindow *window = (__bridge NSWindow *)ns_window;
    window.contentView.wantsLayer = YES;
    window.contentView.layer.cornerRadius = radius;
    window.contentView.layer.masksToBounds = YES;
}

static void cw_clear_view_hierarchy_transparent(NSView *view) {
  if (!view) {
    return;
  }
  view.wantsLayer = YES;
  view.layer.backgroundColor = [NSColor clearColor].CGColor;
  view.layer.opaque = NO;
  for (NSView *subview in view.subviews) {
    cw_clear_view_hierarchy_transparent(subview);
  }
}

EXPORT void cw_nswindow_set_background_clear(void *ns_window) {
    NSWindow *window = (__bridge NSWindow *)ns_window;
    if (!window) {
        return;
    }
    window.opaque = NO;
    [window setBackgroundColor:[NSColor clearColor]];

    NSView *contentView = window.contentView;
    if (contentView) {
        contentView.wantsLayer = YES;
        contentView.layer.backgroundColor = [NSColor clearColor].CGColor;
        contentView.layer.opaque = NO;
    }

    NSViewController *controller = window.contentViewController;
    if (controller) {
        SEL selector = NSSelectorFromString(@"setBackgroundColor:");
        if ([controller respondsToSelector:selector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [controller performSelector:selector withObject:[NSColor clearColor]];
#pragma clang diagnostic pop
        }
        controller.view.wantsLayer = YES;
        controller.view.layer.backgroundColor = [NSColor clearColor].CGColor;
        controller.view.layer.opaque = NO;
        cw_clear_view_hierarchy_transparent(controller.view);
    }
}

@implementation CWDefaultWindowDelegate

- (BOOL)windowShouldClose:(NSWindow *)sender {
  return YES;
}

- (nullable id)windowWillReturnFieldEditor:(NSWindow *)sender
                                  toObject:(nullable id)clien {
  return nil;
}

- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
  return frameSize;
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window
                        defaultFrame:(NSRect)newFrame {
  return newFrame;
}

- (BOOL)windowShouldZoom:(NSWindow *)window toFrame:(NSRect)newFrame {
  return YES;
}

- (nullable NSUndoManager *)windowWillReturnUndoManager:(NSWindow *)window {
  return nil;
}

- (NSRect)window:(NSWindow *)window
    willPositionSheet:(NSWindow *)sheet
            usingRect:(NSRect)rect {
  return rect;
}

- (BOOL)window:(NSWindow *)window shouldPopUpDocumentPathMenu:(NSMenu *)menu {
  return YES;
}

- (BOOL)window:(NSWindow *)window
    shouldDragDocumentWithEvent:(NSEvent *)event
                           from:(NSPoint)dragImageLocation
                 withPasteboard:(NSPasteboard *)pasteboard {
  return NO;
}

- (NSSize)window:(NSWindow *)window
    willUseFullScreenContentSize:(NSSize)proposedSize {
  return proposedSize;
}

- (NSApplicationPresentationOptions)window:(NSWindow *)window
      willUseFullScreenPresentationOptions:
          (NSApplicationPresentationOptions)proposedOptions {
  return proposedOptions;
}

- (nullable NSArray<NSWindow *> *)customWindowsToEnterFullScreenForWindow:
    (NSWindow *)window {
  return nil;
}

- (void)window:(NSWindow *)window
    startCustomAnimationToEnterFullScreenWithDuration:(NSTimeInterval)duration {
}

- (void)windowDidFailToEnterFullScreen:(NSWindow *)window {
}

- (nullable NSArray<NSWindow *> *)customWindowsToExitFullScreenForWindow:
    (NSWindow *)window {
  return nil;
}

- (void)window:(NSWindow *)window
    startCustomAnimationToExitFullScreenWithDuration:(NSTimeInterval)duration {
}

- (nullable NSArray<NSWindow *> *)
    customWindowsToEnterFullScreenForWindow:(NSWindow *)window
                                   onScreen:(NSScreen *)screen {
  return nil;
}

- (void)window:(NSWindow *)window
    startCustomAnimationToEnterFullScreenOnScreen:(NSScreen *)screen
                                     withDuration:(NSTimeInterval)duration {
}

- (void)windowDidFailToExitFullScreen:(NSWindow *)window {
}

- (NSSize)window:(NSWindow *)window
    willResizeForVersionBrowserWithMaxPreferredSize:
        (NSSize)maxPreferredFrameSize
                                     maxAllowedSize:
                                         (NSSize)maxAllowedFrameSize {
  return maxPreferredFrameSize;
}

- (void)window:(NSWindow *)window willEncodeRestorableState:(NSCoder *)state {
}

- (void)window:(NSWindow *)window didDecodeRestorableState:(NSCoder *)state {
}

- (NSArray<id<NSPreviewRepresentableActivityItem>> *_Nullable)
    previewRepresentableActivityItemsForWindow:(NSWindow *)window {
  return nil;
}

- (nullable NSWindow *)windowForSharingRequestFromWindow:(NSWindow *)window {
  return nil;
}

- (void)windowDidResize:(NSNotification *)notification {
}

- (void)windowDidExpose:(NSNotification *)notification {
}

- (void)windowWillMove:(NSNotification *)notification {
}

- (void)windowDidMove:(NSNotification *)notification {
}

- (void)windowDidBecomeKey:(NSNotification *)notification {
}

- (void)windowDidResignKey:(NSNotification *)notification {
}

- (void)windowDidBecomeMain:(NSNotification *)notification {
}

- (void)windowDidResignMain:(NSNotification *)notification {
}

- (void)windowWillClose:(NSNotification *)notification {
}

- (void)windowWillMiniaturize:(NSNotification *)notification {
}

- (void)windowDidMiniaturize:(NSNotification *)notification {
}

- (void)windowDidDeminiaturize:(NSNotification *)notification {
}

- (void)windowDidUpdate:(NSNotification *)notification {
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
}

- (void)windowDidChangeScreenProfile:(NSNotification *)notification {
}

- (void)windowDidChangeBackingProperties:(NSNotification *)notification {
}

- (void)windowWillBeginSheet:(NSNotification *)notification {
}

- (void)windowDidEndSheet:(NSNotification *)notification {
}

- (void)windowWillStartLiveResize:(NSNotification *)notification {
}

- (void)windowDidEndLiveResize:(NSNotification *)notification {
}

- (void)windowWillEnterFullScreen:(NSNotification *)notification {
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification {
}

- (void)windowWillExitFullScreen:(NSNotification *)notification {
}

- (void)windowDidExitFullScreen:(NSNotification *)notificatio {
}

- (void)windowWillEnterVersionBrowser:(NSNotification *)notification {
}

- (void)windowDidEnterVersionBrowser:(NSNotification *)notification {
}

- (void)windowWillExitVersionBrowser:(NSNotification *)notification {
}

- (void)windowDidExitVersionBrowser:(NSNotification *)notification {
}

- (void)windowDidChangeOcclusionState:(NSNotification *)notification {
}

@end

// ============================================================================
// Liquid Glass (macOS 26+) — whole-window backdrop + inset panel.
// Public NSGlassEffectView API: style (Regular/Clear), cornerRadius, contentView.
// Only used on macOS 26+; below that these are no-ops (AppKit availability).
// ============================================================================

/// Click-through-safe NSGlassEffectView. Panel mode (no contentView set):
/// hitTest -> nil, so glass placed BELOW the Flutter surface never swallows
/// clicks. Backdrop mode (contentView = the window's content): recurse into
/// it so embedded content keeps receiving input.
@interface CWGlassEffectView : NSGlassEffectView

@end

@implementation CWGlassEffectView

- (NSView *)hitTest:(NSPoint)point {
  NSView *content = self.contentView;
  if (content && content != self) {
    if (CGRectContainsPoint(content.frame, point)) {
      return [content hitTest:[self convertPoint:point toView:content]];
    }
    return nil;
  }
  return nil;
}

@end

/// Flipped container used by the panel path so a native glass view can sit
/// UNDER the Flutter content surface (same wrap pattern the drag overlay
/// uses via cw_nswindow_update_draggable_areas).
@interface CWGlassContainer : NSView

@end

@implementation CWGlassContainer

- (BOOL)isFlipped {
  return YES;
}

@end

/// macOS 26+: 1 when the public NSGlassEffectView class exists at runtime,
/// 0 otherwise.
EXPORT int32_t cw_nswindow_has_liquid_glass(void) {
  return NSClassFromString(@"NSGlassEffectView") != nil ? 1 : 0;
}

/// macOS 26+: makes the WHOLE window a Liquid Glass surface — the glass view
/// becomes the window's contentView with the existing content (the Flutter
/// view) EMBEDDED as its contentView (the documented model: "a view that
/// embeds its content view in a dynamic glass effect"). [style]: 0 = Regular
/// glass, 1 = Clear glass. No-op below macOS 26.
EXPORT void cw_nswindow_set_glass_backdrop(void *ns_window, int32_t style) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  NSView *current = window.contentView;
  if (!current) {
    return;
  }
  if (@available(macOS 26.0, *)) {
    CWGlassEffectView *glass =
        [[CWGlassEffectView alloc] initWithFrame:current.bounds];
    glass.style = style == 1 ? NSGlassEffectViewStyleClear
                             : NSGlassEffectViewStyleRegular;
    glass.contentView = current;
    current.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    window.contentView = glass;
    fprintf(stderr,
            "[cw-glass] backdrop: window %s contentView=%s (style %s)\n",
            class_getName([window class]),
            NSStringFromClass([current class]).UTF8String,
            style == 1 ? "clear" : "regular");
  }
}

static void *kCWGlassPanelKey = &kCWGlassPanelKey;

/// macOS 26+: insets a Liquid Glass PANEL behind the Flutter content at
/// window-local LOGICAL px (top-left origin, matching Flutter's coords),
/// rounded with [corner_radius]. [style]: 0 Regular / 1 Clear. First call
/// wraps the content in a flipped container so the glass can sit UNDER the
/// Flutter surface (z-order guaranteed by explicit relativeTo:). REPEATED
/// calls REPLACE the existing panel (one glass surface per window — never
/// stack glass-on-glass; the skills' anti-pattern). No-op below macOS 26.
EXPORT void cw_nswindow_set_glass_panel(void *ns_window, double x, double y,
                                        double w, double h,
                                        double corner_radius, int32_t style) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  NSView *contentView = window.contentView;
  if (!contentView) {
    return;
  }
  if (@available(macOS 26.0, *)) {
    // Drop the previous panel so repeated calls update in place.
    CWGlassEffectView *previous =
        objc_getAssociatedObject(window, kCWGlassPanelKey);
    if (previous && previous.superview) {
      [previous removeFromSuperview];
      objc_setAssociatedObject(window, kCWGlassPanelKey, nil,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSView *container = contentView;
    if (![container isKindOfClass:[CWGlassContainer class]]) {
      if (CGRectIsEmpty(contentView.bounds)) {
        fprintf(stderr, "[cw-glass] panel: skipping wrap, empty bounds\n");
        return;
      }
      container = [[CWGlassContainer alloc] initWithFrame:contentView.bounds];
      NSView *old = contentView;
      [container addSubview:old];
      old.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      window.contentView = container;
      fprintf(stderr, "[cw-glass] panel: wrapped contentView\n");
    }
    CWGlassEffectView *glass =
        [[CWGlassEffectView alloc] initWithFrame:NSMakeRect(x, y, w, h)];
    glass.style = style == 1 ? NSGlassEffectViewStyleClear
                             : NSGlassEffectViewStyleRegular;
    glass.cornerRadius = corner_radius;
    [container addSubview:glass
                positioned:NSWindowBelow
                relativeTo:contentView];
    objc_setAssociatedObject(window, kCWGlassPanelKey, glass,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    fprintf(stderr,
            "[cw-glass] panel: %.0fx%.0f at (%.0f,%.0f) style %s\n",
            w, h, x, y, style == 1 ? "clear" : "regular");
  }
}

