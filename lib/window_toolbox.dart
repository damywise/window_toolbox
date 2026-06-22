export 'src/widgets.dart';
export 'src/macos_extra.dart';
export 'src/win32_extra.dart';
export 'src/linux_extra.dart';

import 'src/custom_window.dart';
import 'src/win32_extra.dart';
import 'dart:ui' show Rect;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;

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

  /// Completes frameless setup on Win32 after [enableCustomWindow].
  ///
  /// No-op on other platforms. See [WindowControllerWin32Extension.finishFramelessSetup].
  void finishFramelessSetup({Rect? frame, bool transparentBackdrop = false}) {
    if (this is WindowControllerWin32) {
      (this as WindowControllerWin32).finishFramelessSetup(
        frame: frame,
        transparentBackdrop: transparentBackdrop,
      );
    }
  }
}
