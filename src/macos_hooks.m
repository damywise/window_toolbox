#include "macos.h"

#import <AppKit/AppKit.h>

typedef void (*cw_window_event_callback_t)(
    int32_t event_type, void *window_handle, const char *title, double x,
    double y, double width, double height, void *context);

static cw_window_event_callback_t g_window_event_callback = NULL;
static void *g_window_event_context = NULL;
static NSMutableArray *g_observers = nil;

enum {
  CW_WINDOW_EVENT_CREATED = 0,
  CW_WINDOW_EVENT_DESTROYED = 1,
  CW_WINDOW_EVENT_MOVED = 2,
  CW_WINDOW_EVENT_RESIZED = 3,
  CW_WINDOW_EVENT_HIDDEN = 6,
  CW_WINDOW_EVENT_ACTIVATED = 8,
  CW_WINDOW_EVENT_DEACTIVATED = 9,
};

static char *cw_copy_title(NSString *title) {
  if (!title) {
    return NULL;
  }
  const char *utf8 = [title UTF8String];
  if (!utf8) {
    return NULL;
  }
  return strdup(utf8);
}

static void cw_emit_event(int32_t type, NSWindow *window) {
  if (!g_window_event_callback || !window) {
    return;
  }
  NSRect frame = window.frame;
  char *title = cw_copy_title(window.title);
  void *handle = (__bridge void *)window;
  g_window_event_callback(type, handle, title, frame.origin.x, frame.origin.y,
                          frame.size.width, frame.size.height,
                          g_window_event_context);
  if (title) {
    free(title);
  }
}

EXPORT void cw_hooks_emit_window_moved(void *ns_window) {
  if (!ns_window) {
    return;
  }
  NSWindow *window = (__bridge NSWindow *)ns_window;
  cw_emit_event(CW_WINDOW_EVENT_MOVED, window);
}

static void cw_add_observer(NSString *name, void (^block)(NSNotification *)) {
  if (!g_observers) {
    g_observers = [[NSMutableArray alloc] init];
  }
  id observer = [[NSNotificationCenter defaultCenter]
      addObserverForName:name
                  object:nil
                   queue:[NSOperationQueue mainQueue]
              usingBlock:block];
  [g_observers addObject:observer];
}

EXPORT void cw_hooks_init(void) {
  if (g_observers.count > 0) {
    return;
  }

  cw_add_observer(NSWindowDidMoveNotification, ^(NSNotification *note) {
    NSWindow *window = note.object;
    if ([window isKindOfClass:[NSWindow class]]) {
      cw_emit_event(CW_WINDOW_EVENT_MOVED, window);
    }
  });

  cw_add_observer(NSWindowDidResizeNotification, ^(NSNotification *note) {
    NSWindow *window = note.object;
    if ([window isKindOfClass:[NSWindow class]]) {
      cw_emit_event(CW_WINDOW_EVENT_RESIZED, window);
    }
  });

  cw_add_observer(NSWindowWillCloseNotification, ^(NSNotification *note) {
    NSWindow *window = note.object;
    if ([window isKindOfClass:[NSWindow class]]) {
      cw_emit_event(CW_WINDOW_EVENT_DESTROYED, window);
    }
  });

  cw_add_observer(NSWindowDidBecomeKeyNotification, ^(NSNotification *note) {
    NSWindow *window = note.object;
    if ([window isKindOfClass:[NSWindow class]]) {
      cw_emit_event(CW_WINDOW_EVENT_ACTIVATED, window);
    }
  });

  cw_add_observer(NSWindowDidResignKeyNotification, ^(NSNotification *note) {
    NSWindow *window = note.object;
    if ([window isKindOfClass:[NSWindow class]]) {
      cw_emit_event(CW_WINDOW_EVENT_DEACTIVATED, window);
    }
  });
}

EXPORT void cw_hooks_set_window_event_callback(
    cw_window_event_callback_t callback, void *context) {
  g_window_event_callback = callback;
  g_window_event_context = context;
}

EXPORT void cw_hooks_dispose(void) {
  for (id observer in g_observers) {
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
  }
  [g_observers removeAllObjects];
  g_window_event_callback = NULL;
  g_window_event_context = NULL;
}
