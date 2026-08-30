import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:ui' show Rect;

import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';

import 'custom_window.dart';
import 'custom_window_init_options.dart';
import 'macos.g.dart' as macos;
import 'macos_extra.dart';
import 'win32_extra.dart';
import 'win32_window_chrome.dart';
import 'win32_window_ops.dart';

/// Cross-platform window operations for [BaseWindowController].
extension WindowControllerOps on BaseWindowController {
  void promoteToPanel({bool floating = true}) {
    if (this is WindowControllerMacOS) {
      final macosController = this as WindowControllerMacOS;
      cw_nswindow_promote_to_panel(
        macosController.windowHandle,
        floating,
      );
      return;
    }
  }

  void setPanelFlags(int flags) {
    if (this is WindowControllerMacOS) {
      macos.cw_nswindow_set_panel_flags(
        (this as WindowControllerMacOS).windowHandle,
        flags,
      );
    }
  }

  void setShadow(bool hasShadow) {
    if (this is WindowControllerMacOS) {
      cw_nswindow_set_shadow(
        (this as WindowControllerMacOS).windowHandle,
        hasShadow,
      );
    }
  }

  void forceRedraw() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_force_redraw(
        (this as WindowControllerMacOS).windowHandle,
      );
      return;
    }
    if (this is WindowControllerWin32) {
      Win32WindowOps.forceRedraw(
        HWND((this as WindowControllerWin32).windowHandle),
      );
    }
  }

  /// Pindraw window level offset (1=drawing, 2=dialog, 3=toolbar).
  void setAppWindowLevel(int levelOffset) {
    if (this is WindowControllerMacOS) {
      cw_nswindow_set_app_window_level(
        (this as WindowControllerMacOS).windowHandle,
        levelOffset,
      );
      return;
    }
    setAlwaysOnTop(true, fullscreenCompatible: true);
  }

  void makeFrameless() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_make_frameless(
        (this as WindowControllerMacOS).windowHandle,
      );
      return;
    }
    if (this is WindowControllerWin32) {
      CustomWindow.init(
        this,
        options: const CustomWindowInitOptions(
          transparentBackdrop: true,
          mousePassthrough: false,
        ),
      );
      return;
    }
  }

  void makeTitleless({double? cornerRadius}) {
    if (this is WindowControllerMacOS) {
      final handle = (this as WindowControllerMacOS).windowHandle;
      cw_nswindow_make_titleless(handle);
      if (cornerRadius != null) {
        (this as WindowControllerMacOS).setCornerRadius(cornerRadius);
      }
      return;
    }
    if (this is WindowControllerWin32) {
      CustomWindow.init(
        this,
        options: const CustomWindowInitOptions(titleless: true),
      );
      return;
    }
  }

  void startDrag() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_start_drag((this as WindowControllerMacOS).windowHandle);
      return;
    }
    if (this is WindowControllerWin32) {
      Win32WindowOps.startDrag(
        HWND((this as WindowControllerWin32).windowHandle),
      );
    }
  }

  void makeActive() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_make_key((this as WindowControllerMacOS).windowHandle);
      return;
    }
    if (this is WindowControllerWin32) {
      Win32WindowOps.makeActive(
        HWND((this as WindowControllerWin32).windowHandle),
      );
    }
  }

  void activateApp() {
    if (Platform.isMacOS) {
      cw_nswindow_activate_app();
    }
  }

  void centerOnScreen() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_center((this as WindowControllerMacOS).windowHandle);
    }
  }

  void setMinSize(double width, double height) {
    if (this is WindowControllerMacOS) {
      cw_nswindow_set_min_size(
        (this as WindowControllerMacOS).windowHandle,
        width,
        height,
      );
    }
  }

  /// macOS 26+: makes the WHOLE window a Liquid Glass surface (glass view
  /// becomes the window's content view with the Flutter content EMBEDDED as
  /// its contentView — the documented model). [style]: 0 Regular, 1 Clear.
  /// No-op below 26.
  void setGlassBackdrop({int style = 0}) {
    if (this is! WindowControllerMacOS) return;
    try {
      cw_nswindow_set_glass_backdrop(
          (this as WindowControllerMacOS).windowHandle, style);
    } on Object {
      // Window already destroyed mid-teardown — nothing to set.
    }
  }

  /// macOS 26+: insets a Liquid Glass PANEL behind the Flutter content at
  /// [rect] (window-local LOGICAL px, top-left origin), rounded with
  /// [cornerRadius]. [style]: 0 Regular, 1 Clear. No-op below 26.
  void setGlassPanel(Rect? rect, {double cornerRadius = 16, int style = 0}) {
    if (this is! WindowControllerMacOS) return;
    try {
      final handle = (this as WindowControllerMacOS).windowHandle;
      final r = rect;
      if (r == null || r.isEmpty) return;
      cw_nswindow_set_glass_panel(
          handle, r.left, r.top, r.width, r.height, cornerRadius, style);
    } on Object {
      // Window already destroyed mid-teardown — nothing to set.
    }
  }

  void orderFront() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_order_front((this as WindowControllerMacOS).windowHandle);
      return;
    }
    if (this is WindowControllerWin32) {
      bringToFrontForHwnd(
        HWND((this as WindowControllerWin32).windowHandle),
      );
    }
  }

  /// Hides the window without activating or destroying it ([NSWindow
  /// orderOut:] — the window stays alive and re-usable via [orderFront]).
  /// Win32: no-op (the Win32 hide/show path is window_toolbox's ShowWindow
  /// helpers in the app).
  void orderOut() {
    if (this is WindowControllerMacOS) {
      cw_nswindow_order_out((this as WindowControllerMacOS).windowHandle);
    }
  }

  /// macOS: the visible frame (excludes the menu bar / dock) of the screen
  /// at [screenIndex] of `NSScreen screens`, in the flipped top-left
  /// global-union space [WindowControllerMacOSExtension.setWindowFrame]
  /// expects — hand it straight to that setter. Returns [Rect.zero] on
  /// non-macOS platforms.
  Rect visibleScreenFrame(int screenIndex) {
    if (this is WindowControllerMacOS) {
      return cw_nsscreen_visible_frame(screenIndex);
    }
    return Rect.zero;
  }

  bool setCaptureExclusion(bool exclude) {
    if (this is WindowControllerMacOS) {
      cw_nswindow_set_capture_exclusion(
        (this as WindowControllerMacOS).windowHandle,
        exclude,
      );
      return true;
    }
    if (this is WindowControllerWin32) {
      return Win32WindowOps.setCaptureExclusion(
        HWND((this as WindowControllerWin32).windowHandle),
        exclude,
      );
    }
    return false;
  }

  void setAlwaysOnTop(bool onTop, {bool fullscreenCompatible = true}) {
    if (this is WindowControllerWin32) {
      (this as WindowControllerWin32).setAlwaysOnTop(
        onTop,
        fullscreenCompatible: fullscreenCompatible,
      );
      return;
    }
    if (this is WindowControllerMacOS && onTop) {
      setAppWindowLevel(fullscreenCompatible ? 3 : 0);
    }
  }

  void hideFromSwitcher({bool hide = true}) {
    if (this is WindowControllerWin32) {
      (this as WindowControllerWin32).setHideFromSwitcher(hide);
      return;
    }
    if (this is WindowControllerMacOS) {
      final macosController = this as WindowControllerMacOS;
      final behavior = macosController.collectionBehavior;
      if (hide) {
        behavior
          ..remove(NSWindowCollectionBehavior.participatesInCycle)
          ..add(NSWindowCollectionBehavior.ignoresCycle)
          ..add(NSWindowCollectionBehavior.transient);
      } else {
        behavior
          ..remove(NSWindowCollectionBehavior.ignoresCycle)
          ..remove(NSWindowCollectionBehavior.transient)
          ..add(NSWindowCollectionBehavior.participatesInCycle);
      }
      macosController.collectionBehavior = behavior;
    }
  }

  void destroy() {
    if (this is WindowControllerWin32) {
      Win32WindowOps.destroyWindow(
        HWND((this as WindowControllerWin32).windowHandle),
      );
      return;
    }
    if (this is WindowControllerMacOS) {
      cw_nswindow_request_close(
        (this as WindowControllerMacOS).windowHandle,
      );
    }
  }
}

// Top-level FFI shims for macos_panel.m
void cw_nswindow_promote_to_panel(
  ffi.Pointer<ffi.Void> handle,
  bool floating,
) => macos.cw_nswindow_promote_to_panel(handle, floating);

void cw_nswindow_set_shadow(ffi.Pointer<ffi.Void> handle, bool hasShadow) =>
    macos.cw_nswindow_set_shadow(handle, hasShadow);

void cw_nswindow_force_redraw(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_force_redraw(handle);

void cw_nswindow_set_app_window_level(
  ffi.Pointer<ffi.Void> handle,
  int levelOffset,
) => macos.cw_nswindow_set_app_window_level(handle, levelOffset);

void cw_nswindow_make_frameless(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_make_frameless(handle);

void cw_nswindow_make_titleless(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_make_titleless(handle);

void cw_nswindow_start_drag(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_start_drag(handle);

void cw_nswindow_make_key(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_make_key(handle);

void cw_nswindow_activate_app() => macos.cw_nswindow_activate_app();

void cw_nswindow_center(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_center(handle);

void cw_nswindow_set_min_size(
  ffi.Pointer<ffi.Void> handle,
  double width,
  double height,
) => macos.cw_nswindow_set_min_size(handle, width, height);

void cw_nswindow_order_front(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_order_front(handle);

void cw_nswindow_order_out(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_order_out(handle);

int cw_nswindow_has_liquid_glass() => macos.cw_nswindow_has_liquid_glass();

void cw_nswindow_set_glass_backdrop(ffi.Pointer<ffi.Void> handle,
                                    int style) =>
    macos.cw_nswindow_set_glass_backdrop(handle, style);

void cw_nswindow_set_glass_panel(ffi.Pointer<ffi.Void> handle, double x,
                                 double y, double w, double h,
                                 double cornerRadius, int style) =>
    macos.cw_nswindow_set_glass_panel(
        handle, x, y, w, h, cornerRadius, style);

Rect cw_nsscreen_visible_frame(int screenIndex) {
  final r = macos.cw_nsscreen_visible_frame(screenIndex);
  return Rect.fromLTWH(r.x, r.y, r.w, r.h);
}

void cw_nswindow_set_capture_exclusion(
  ffi.Pointer<ffi.Void> handle,
  bool exclude,
) => macos.cw_nswindow_set_capture_exclusion(handle, exclude);

void cw_nswindow_request_close(ffi.Pointer<ffi.Void> handle) =>
    macos.cw_nswindow_request_close(handle);

bool isWindowAbove(ffi.Pointer<ffi.Void> a, ffi.Pointer<ffi.Void> b) {
  if (!Platform.isWindows) {
    return false;
  }
  return Win32WindowOps.isWindowAbove(HWND(a), HWND(b));
}

bool showItemInFolder(String filePath) {
  if (Platform.isWindows) {
    return Win32WindowOps.showItemInFolder(filePath);
  }
  if (Platform.isMacOS) {
    try {
      final result = Process.runSync('open', ['-R', filePath]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
  return false;
}
