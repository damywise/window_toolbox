#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define EXPORT __attribute__((visibility("default")))

EXPORT void cw_nswindow_remove_titlebar(void *ns_window);

typedef struct {
  double x;
  double y;
  double w;
  double h;
} cw_rect_t;

typedef struct {
  double w;
  double h;
} cw_size_t;

EXPORT void cw_nswindow_update_draggable_areas(void *ns_window,
                                               cw_rect_t *exclude,
                                               size_t exclude_count);

EXPORT void cw_nswindow_disable_draggable_areas(void *ns_window);

typedef enum {
  CW_APPEARANCE_AUTO,
  CW_APPEARANCE_LIGHT,
  CW_APPEARANCE_DARK,
} cw_appearance_t;

typedef struct {
  double offset_x;
  double offset_y;
  cw_appearance_t appearance;
  bool custom_inactive_traffic_light;
  int64_t inactive_background_color;
  int64_t inactive_border_color;
  double inactive_border_width;
  bool show_as_inactive_in_key_window;
} cw_traffic_light_config_t;

EXPORT void
cw_nswindow_update_traffic_light(void *ns_window,
                                 const cw_traffic_light_config_t *config);

EXPORT cw_size_t cw_nswindow_traffic_light_size(void *ns_window);

EXPORT void cw_nswindow_request_close(void *ns_window);

EXPORT void cw_nswindow_set_style_mask(void *ns_window,
                                       unsigned long style_mask);

EXPORT unsigned long cw_nswindow_get_style_mask(void *ns_window);

EXPORT void
cw_nswindow_set_collection_behavior(void *ns_window,
                                    unsigned long collection_behavior);

EXPORT unsigned long cw_nswindow_get_collection_behavior(void *ns_window);

typedef struct {
  cw_size_t (*on_window_will_resize)(cw_size_t new_size);
  void (*on_window_will_start_live_resize)();
  void (*on_window_did_end_live_resize)();
  void (*on_window_will_close)();
  void (*on_window_will_enter_fullscreen)();
  void (*on_window_did_enter_fullscreen)();
  void (*on_window_will_exit_fullscreen)();
  void (*on_window_did_exit_fullscreen)();
  cw_rect_t (*on_window_will_use_standard_frame)(cw_rect_t default_frame);
} cw_delegate_config_t;

EXPORT void cw_nswindow_init_delegate(void *ns_window,
                                      cw_delegate_config_t config);

EXPORT void cw_nswindow_set_frame(void *ns_window, cw_rect_t frame);
EXPORT cw_rect_t cw_nswindow_get_frame(void *ns_window);
/// AppKit bottom-left frame (no Flutter Y-flip). Matches legacy window_lifecycle.
EXPORT void cw_nswindow_set_frame_bottom_left(void *ns_window, cw_rect_t frame);
EXPORT cw_rect_t cw_nswindow_get_frame_bottom_left(void *ns_window);
/// Near-fullscreen window on [NSScreen screens][screen_index].frame (width-1).
EXPORT void cw_nswindow_set_fullscreen_on_screen_index(void *ns_window,
                                                       int32_t screen_index);

/// Panel behavior flags for [cw_nswindow_set_panel_flags].
enum {
  CW_PANEL_FLAG_STATIONARY = 1u << 0,
  CW_PANEL_FLAG_IMMOVABLE = 1u << 1,
};
EXPORT void cw_nswindow_set_panel_flags(void *ns_window, uint32_t flags);
EXPORT void cw_nswindow_position_on_screen_index(void *ns_window,
                                                 int32_t screen_index);

EXPORT void cw_nswindow_set_alpha(void *ns_window, double alpha);
EXPORT void cw_nswindow_set_level(void *ns_window, int level);
EXPORT void cw_nswindow_set_ignores_mouse_events(void *ns_window, bool ignores);
EXPORT void cw_nswindow_set_corner_radius(void *ns_window, double radius);
EXPORT void cw_nswindow_set_background_clear(void *ns_window);

EXPORT int32_t cw_nswindow_promote_to_panel(void *ns_window, bool floating);
EXPORT void cw_nswindow_set_shadow(void *ns_window, bool has_shadow);
EXPORT void cw_nswindow_force_redraw(void *ns_window);
EXPORT void cw_nswindow_set_app_window_level(void *ns_window,
                                             int32_t level_offset);
EXPORT void cw_nswindow_make_frameless(void *ns_window);
EXPORT void cw_nswindow_make_titleless(void *ns_window);
EXPORT void cw_nswindow_start_drag(void *ns_window);
EXPORT void cw_nswindow_make_key(void *ns_window);
EXPORT void cw_nswindow_activate_app(void);
EXPORT void cw_nswindow_center(void *ns_window);
EXPORT void cw_nswindow_set_min_size(void *ns_window, double width,
                                     double height);
EXPORT void cw_nswindow_order_front(void *ns_window);
EXPORT void cw_nswindow_set_capture_exclusion(void *ns_window, bool exclude);

typedef void (*cw_window_event_callback_t)(
    int32_t event_type, void *window_handle, const char *title, double x,
    double y, double width, double height, void *context);

EXPORT void cw_hooks_init(void);
EXPORT void cw_hooks_set_window_event_callback(
    cw_window_event_callback_t callback, void *context);
EXPORT void cw_hooks_dispose(void);
/// Emit WINDOW_EVENT_MOVED for hooks consumers (e.g. drag tracker during performDrag).
EXPORT void cw_hooks_emit_window_moved(void *ns_window);

#ifdef __cplusplus
}
#endif