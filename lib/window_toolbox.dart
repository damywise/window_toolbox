export 'src/widgets.dart';
export 'src/macos_extra.dart';
export 'src/win32_extra.dart';
export 'src/linux_extra.dart';
export 'src/win32_mouse_passthrough.dart' show setIgnoresMouseEventsForHwnd;
export 'src/win32_satellite_gap.dart';

import 'dart:ui' show Rect;

import 'package:flutter/src/widgets/_window.dart';

import 'src/custom_window.dart';
import 'src/custom_window_init_options.dart';

extension CustomWindowExtension on BaseWindowController {
  /// Enables window customization features for this window.
  ///
  /// On Win32, pass `titleless: true` to keep the native non-client frame and
  /// only remove the caption band (knopp/window_toolbox titleless mode). The
  /// default is frameless chrome (client fills the outer frame). Overlay flags
  /// (`transparentBackdrop`, `mousePassthrough`) also select frameless mode.
  ///
  /// Optional [frame], [transparentBackdrop], [mousePassthrough],
  /// [hideFromSwitcher], and [alwaysOnTop] are applied during deferred setup
  /// after the first frame.
  void enableCustomWindow({
    Rect? frame,
    bool titleless = false,
    bool transparentBackdrop = false,
    bool mousePassthrough = false,
    bool hideFromSwitcher = false,
    bool alwaysOnTop = false,
    bool fullscreenCompatibleTopmost = true,
  }) {
    CustomWindow.init(
      this,
      options: CustomWindowInitOptions(
        frame: frame,
        titleless: titleless,
        transparentBackdrop: transparentBackdrop,
        mousePassthrough: mousePassthrough,
        hideFromSwitcher: hideFromSwitcher,
        alwaysOnTop: alwaysOnTop,
        fullscreenCompatibleTopmost: fullscreenCompatibleTopmost,
      ),
    );
  }

  /// Configures optional Win32 frameless extras. No-op on other platforms.
  ///
  /// Prefer [enableCustomWindow] with the same parameters. This schedules
  /// deferred setup when custom window is already enabled.
  void configureFramelessWindow({
    Rect? frame,
    bool transparentBackdrop = false,
    bool mousePassthrough = false,
  }) {
    CustomWindow.configureFramelessWindow(
      this,
      frame: frame,
      transparentBackdrop: transparentBackdrop,
      mousePassthrough: mousePassthrough,
    );
  }

  /// Win32-only: lifecycle-exact layered click-through toggle.
  void setIgnoresMouseEvents(bool ignores) {
    CustomWindow.setIgnoresMouseEvents(this, ignores);
  }
}
