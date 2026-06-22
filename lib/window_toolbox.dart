export 'src/widgets.dart';
export 'src/macos_extra.dart';
export 'src/win32_extra.dart';
export 'src/linux_extra.dart';

import 'dart:ui' show Rect;

import 'package:flutter/src/widgets/_window.dart';

import 'src/custom_window.dart';

extension CustomWindowExtension on BaseWindowController {
  /// Enables window customization features for this window.
  /// The customization is done by placing the following widgets in the widget tree:
  /// - [WindowDragArea] for defining draggable areas of the window.
  /// - [WindowDragExcludeArea] for defining areas that should not be draggable
  ///   even if they are inside a [WindowDragArea].
  /// - [WindowTrafficLight] for positioning macOS traffic light buttons.
  /// - [MaximizeButton], [MinimizeButton], and [CloseButton].
  /// - [WindowBorder] for drawing custom window border and shadow.
  void enableCustomWindow() {
    CustomWindow.init(this);
  }

  /// Configures optional Win32 frameless extras. No-op on other platforms.
  ///
  /// Pass [frame] and/or set [transparentBackdrop] for transparent,
  /// full-screen, or engine-managed windows (e.g. tooltips). Size compensation
  /// (shrinking the window after frameless WM_NCCALCSIZE) runs automatically
  /// when [enableCustomWindow] was called on the same controller.
  void configureFramelessWindow({
    Rect? frame,
    bool transparentBackdrop = false,
  }) {
    CustomWindow.configureFramelessWindow(
      this,
      frame: frame,
      transparentBackdrop: transparentBackdrop,
    );
  }
}
