#include "macos.h"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

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



/// Container that keeps the Flutter surface at a FIXED size (captured from
/// the window's initial content size) and re-CENTERS it as the window
/// resizes. The window can then animate its frame freely WITHOUT ever
/// resizing the FlutterView — a view resize is precisely what trips the
/// engine's ResizeSynchronizer ("Resize timed out" + frame stalls). The
/// card's apparent growth is done with a LAYER scale (GPU compositing, no
/// engine involvement) plus a window-alpha fade, all outside the resize path.
@interface CWResizeWindowContainer : NSView {
  NSSize _fixedSize;
}

- (instancetype)initWithFixedSize:(NSSize)size;
- (NSView *)flutterView;
@end

@implementation CWResizeWindowContainer

- (instancetype)initWithFixedSize:(NSSize)size {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _fixedSize = size;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)layout {
  [super layout];
  NSView *content = self.subviews.lastObject;
  if (!content || _fixedSize.width <= 0 || _fixedSize.height <= 0) {
    return;
  }
  content.frame = NSMakeRect(
      roundf((self.bounds.size.width - _fixedSize.width) / 2),
      roundf((self.bounds.size.height - _fixedSize.height) / 2),
      _fixedSize.width, _fixedSize.height);
}

- (NSView *)flutterView {
  return self.subviews.lastObject;
}

@end

/// One-shot NATIVE setup for the middle notification window (call once, at
/// creation — never per animation frame):
///  - the Flutter surface becomes a FIXED-size, always-centered layer (see
///    CWResizeWindowContainer) so the window frame can animate without the
///    engine's resize synchronizer;
///  - the Clear/Regular Liquid Glass panel (whole window, rounded) sits
///    behind the content and AUTORESIZES with the window through every
///    animation stage;
///  - the window is fully click-through (all mouse passes to the desktop)
///    and cannot be dragged by its background.
EXPORT void cw_nswindow_setup_middle_window(void *ns_window,
                                            double corner_radius,
                                            int32_t style) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  NSView *contentView = window.contentView;
  if (!contentView) {
    return;
  }
  window.movableByWindowBackground = NO;
  [window setIgnoresMouseEvents:YES];
  if ([contentView isKindOfClass:[CWResizeWindowContainer class]]) {
    return;  // already set up once
  }
  if (CGRectIsEmpty(contentView.bounds)) {
    fprintf(stderr, "[cw-glass] middle: skipping wrap, empty bounds\n");
    return;
  }
  NSSize fixed = contentView.bounds.size;
  CWResizeWindowContainer *container =
      [[CWResizeWindowContainer alloc] initWithFixedSize:fixed];
  container.frame = contentView.bounds;
  container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  NSView *old = contentView;
  [container addSubview:old];
  old.autoresizingMask = NSViewNotSizable;  // never resize the FlutterView
  window.contentView = container;
  // Stop AppKit from re-sized the contentViewController's view to the window
  // on every frame change (it would resize the FlutterView and re-trigger the
  // engine's resize synchronizer). The engine keeps its controller + view.
  window.contentViewController = nil;
  if (@available(macOS 26.0, *)) {
    CWGlassEffectView *glass =
        [[CWGlassEffectView alloc] initWithFrame:container.bounds];
    glass.style = style == 1 ? NSGlassEffectViewStyleClear
                             : NSGlassEffectViewStyleRegular;
    glass.cornerRadius = corner_radius;
    glass.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [container addSubview:glass
                positioned:NSWindowBelow
                relativeTo:old];
    fprintf(stderr,
            "[cw-glass] middle: fixed content %.0fx%.0f, glass style %s\n",
            fixed.width, fixed.height, style == 1 ? "clear" : "regular");
  } else {
    fprintf(stderr, "[cw-glass] middle: fixed content %.0fx%.0f, no glass\n",
            fixed.width, fixed.height);
  }
}

/// Scales the middle notification's rendered CONTENT via the FlutterView's
/// layer transform (GPU compositing — no engine layout, no resize
/// synchronizer). The card grows/shrinks in lockstep with the window frame;
/// scale 1.0 = the card's design size.
EXPORT void cw_nswindow_set_content_scale(void *ns_window, double scale) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  NSView *contentView = window.contentView;
  if (![contentView isKindOfClass:[CWResizeWindowContainer class]]) {
    return;
  }
  NSView *flutter = [(CWResizeWindowContainer *)contentView flutterView];
  if (!flutter || !flutter.layer) {
    return;
  }
  CGFloat s = (CGFloat)(scale > 0.05 ? scale : 0.05);
  flutter.layer.transform = CATransform3DMakeScale(s, s, 1.0);
}

/// NSWindow.movableByWindowBackground: NO keeps the overlay windows
/// non-draggable so mouse events reach the Flutter content (the frameless
/// make-frameless path sets YES by default, which swallows every click-drag).
EXPORT void cw_nswindow_set_movable_by_background(void *ns_window,
                                                  bool movable) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (window) {
    window.movableByWindowBackground = movable;
  }
}

// ---------------------------------------------------------------------------
// Per-region click-through (edge notification stack).
//
// The window is kept FULLY click-through via [NSWindow setIgnoresMouseEvents:]
// and a GLOBAL mouse-move monitor flips it back to interactive ONLY while the
// cursor is over a registered toast-card rect — the mechanism overlay apps
// with "interactive shapes" actually rely on (a nil -hitTest: does NOT pass
// the click to the window below; ignoresMouseEvents does).
// ---------------------------------------------------------------------------

@interface CWMouseRectsBox : NSObject {
  double *_rects;
  size_t _count;
}

- (void)setRects:(const double *)rects count:(size_t)count;
- (BOOL)containsScreenPoint:(NSPoint)screenPoint inWindow:(NSWindow *)window;
@end

@implementation CWMouseRectsBox

- (void)dealloc {
  free(_rects);
}

- (void)setRects:(const double *)rects count:(size_t)count {
  free(_rects);
  _rects = NULL;
  _count = 0;
  if (count > 0 && rects) {
    _rects = malloc(sizeof(double) * count * 4);
    memcpy(_rects, rects, sizeof(double) * count * 4);
    _count = count;
  }
}

- (BOOL)containsScreenPoint:(NSPoint)screenPoint inWindow:(NSWindow *)window {
  if (_count == 0 || !_rects || !window) {
    return NO;
  }
  // The rects arrive in the window's FLUTTER-LOCAL space (top-left, logical
  // px) — the windowing embedder's localToGlobal is window-local because each
  // window is its own coordinate root. Convert the cursor into the SAME space:
  // AppKit screen coords -> window base via convertPointFromScreen, then flip
  // Y against the content height. Both sides are window-local by construction,
  // so display arrangement (second screens above/below) can never skew it.
  NSPoint winPt = [window convertPointFromScreen:screenPoint];
  CGFloat y = window.contentView.bounds.size.height - winPt.y;
  for (size_t i = 0; i < _count; i++) {
    double x0 = _rects[i * 4 + 0];
    double y0 = _rects[i * 4 + 1];
    double w = _rects[i * 4 + 2];
    double h = _rects[i * 4 + 3];
    if (winPt.x >= x0 && winPt.x <= x0 + w && y >= y0 && y <= y0 + h) {
      return YES;
    }
  }
  return NO;
}

@end

static void *kCWMouseRectsBoxKey = &kCWMouseRectsBoxKey;
static NSHashTable *gClickWindows = nil;
static BOOL gClickLocalMonitorInstalled = NO;
static BOOL gClickGlobalMonitorInstalled = NO;

static void CWEvalClickThrough(NSWindow *window) {
  CWMouseRectsBox *box = objc_getAssociatedObject(window, kCWMouseRectsBoxKey);
  if (!box) {
    return;
  }
  BOOL inside = [box containsScreenPoint:[NSEvent mouseLocation]
                                inWindow:window];
  BOOL ignoring = [window ignoresMouseEvents];
  if (inside == !ignoring) {
    return;  // already in the right state
  }
  [window setIgnoresMouseEvents:!inside];
  fprintf(stderr, "[cw-ct] eval: cursor %s rect(s) -> ignoresMouseEvents %s\n",
          inside ? "INSIDE" : "OUTSIDE", !inside ? "YES" : "NO");
}

/// Registers the window-LOCAL LOGICAL (top-left origin) interactive rects for
/// per-region click-through: the window stays click-through everywhere and is
/// flipped interactive only while the cursor hovers a rect. NULL/0 rects =
/// the whole window stays click-through. Safe to call repeatedly (layout /
/// scroll changes) — rects are simply replaced; the global monitor is
/// installed once.
EXPORT void cw_nswindow_set_click_through_rects(void *ns_window,
                                                const double *rects,
                                                size_t rect_count) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (!window) {
    return;
  }
  CWMouseRectsBox *box = objc_getAssociatedObject(window, kCWMouseRectsBoxKey);
  if (!box) {
    box = [[CWMouseRectsBox alloc] init];
    objc_setAssociatedObject(window, kCWMouseRectsBoxKey, box,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  [box setRects:rects count:rect_count];
  [window setIgnoresMouseEvents:rect_count == 0 || rects == NULL];
  // Opt the window into mouse-moved event posting (the window server only
  // synthesizes moved events where an app has opted in — the local monitor
  // below is backed by this).
  [window setAcceptsMouseMovedEvents:YES];
  if (rect_count > 0 && rects) {
    fprintf(stderr, "[cw-ct] setRects: %zu rect(s):", rect_count);
    for (size_t i = 0; i < rect_count && i < 3; i++) {
      fprintf(stderr, " [%.0f,%.0f %.0fx%.0f]", rects[i * 4],
              rects[i * 4 + 1], rects[i * 4 + 2], rects[i * 4 + 3]);
    }
    fprintf(stderr, "\n");
  } else {
    fprintf(stderr, "[cw-ct] setRects: empty\n");
  }
  if (gClickWindows == nil) {
    gClickWindows = [NSHashTable weakObjectsHashTable];
  }
  if (![gClickWindows containsObject:window]) {
    [gClickWindows addObject:window];
  }
  // The idler-game pattern: LOCAL + GLOBAL monitors. Mouse-moved events are
  // NOT delivered to a global monitor when the cursor is over the app's OWN
  // windows — a LOCAL monitor is what keeps own-window moves flowing (and
  // opts the app into moved-event posting). The local handler evaluates the
  // cursor BEFORE the event dispatches, so a click over a card lands while
  // the window is already interactive. The global one covers other apps.
  if (!gClickLocalMonitorInstalled) {
    gClickLocalMonitorInstalled = YES;
    [NSEvent addLocalMonitorForEventsMatchingMask:
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDown |
        NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged |
        NSEventMaskRightMouseDown | NSEventMaskRightMouseUp |
        NSEventMaskScrollWheel
        handler:^NSEvent *(NSEvent *event) {
          for (NSWindow *win in [gClickWindows allObjects]) {
            CWEvalClickThrough(win);
          }
          return event;
        }];
  }
  if (!gClickGlobalMonitorInstalled) {
    gClickGlobalMonitorInstalled = YES;
    [NSEvent addGlobalMonitorForEventsMatchingMask:
        NSEventMaskMouseMoved | NSEventMaskLeftMouseDown |
        NSEventMaskLeftMouseUp | NSEventMaskLeftMouseDragged |
        NSEventMaskRightMouseDown | NSEventMaskRightMouseUp
        handler:^(NSEvent *event) {
          for (NSWindow *win in [gClickWindows allObjects]) {
            CWEvalClickThrough(win);
          }
        }];
  }
  CWEvalClickThrough(window);
}

/// Re-evaluates the per-region click-through state RIGHT NOW (no event
/// dependency): reads the current cursor position, checks the registered card
/// rects, and toggles [NSWindow setIgnoresMouseEvents:] accordingly. Called
/// periodically by the app — mouse-moved event delivery can't be relied on
/// for the app's own windows.
EXPORT void cw_nswindow_eval_click_through(void *ns_window) {
  NSWindow *window = (__bridge NSWindow *)ns_window;
  if (window) {
    CWEvalClickThrough(window);
  }
}
