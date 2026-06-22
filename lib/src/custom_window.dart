import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/src/widgets/_window_linux.dart';
import 'package:flutter/widgets.dart';

import 'custom_window_macos.dart';
import 'custom_window_win32.dart';
import 'custom_window_linux.dart';
import 'win32_frameless_setup.dart';

import 'widgets.dart' show WindowTrafficLightInactiveConfigration;

/// Platform window chrome customization backing [enableCustomWindow].
///
/// Native chrome removal differs by platform:
/// - **Win32:** full native frame removed (borders and title bar).
/// - **macOS:** title bar hidden via full-size content view; native frame remains.
/// - **Linux:** full decorations removed via GTK.
abstract class CustomWindow {
  static CustomWindow? forController(BaseWindowController controller) {
    return _expando[controller];
  }

  static void init(BaseWindowController controller) {
    final created = _create(
      controller,
      onClose: () {
        _expando[controller] = null;
      },
    );
    if (created != null) {
      _expando[controller] = created;
    }
  }

  /// Configures optional Win32 frameless extras. No-op on other platforms.
  ///
  /// Pass [frame] and/or set [transparentBackdrop] for transparent,
  /// full-screen, or engine-managed windows (e.g. tooltips). Size compensation
  /// (shrinking the window after frameless WM_NCCALCSIZE) runs only when
  /// [enableCustomWindow] was called — it is set automatically by that path.
  static void configureFramelessWindow(
    BaseWindowController controller, {
    Rect? frame,
    bool transparentBackdrop = false,
  }) {
    if (controller is WindowControllerWin32) {
      scheduleWin32FramelessSetup(
        controller as WindowControllerWin32,
        frame: frame,
        transparentBackdrop: transparentBackdrop,
      );
    }
  }

  static final _expando = Expando<CustomWindow>('CustomWindow');

  static CustomWindow? _create(
    BaseWindowController controller, {
    required VoidCallback onClose,
  }) {
    if (controller is WindowControllerMacOS) {
      return CustomWindowMacOS(
        controller as WindowControllerMacOS,
        onClose: onClose,
      );
    } else if (controller is WindowControllerWin32) {
      return CustomWindowWin32(
        controller as WindowControllerWin32,
        onClose: onClose,
      );
    } else if (controller is WindowControllerLinux) {
      return CustomWindowLinux(
        controller as WindowControllerLinux,
        onClose: onClose,
      );
    } else {
      return null;
    }
  }

  void setDraggableRectForElement(BuildContext element, Rect? rect);
  void setDragExcludeRectForElement(BuildContext element, Rect? rect);
  void setTrafficLightConfiguration(
    Offset offset,
    Brightness? brightness,
    WindowTrafficLightInactiveConfigration? inactiveConfigration,
  );
  void setMaximizeButtonFrame(BuildContext element, Rect? rect);
  Size getTrafficLightSize();
  void requestClose();

  bool windowNeedsMoveDragDetector();
  bool windowNeedsCustomBorder();
  bool titlebarNeedsDoubleClickDetector();
  void setCustomBorderShadowWidth(
    double top,
    double left,
    double bottom,
    double right,
  );

  void startWindowMoveDrag(Offset globalPosition);
  void startWindowResizeDrag(Offset globalPosition, WindowEdge edge);
}

enum WindowEdge {
  northWest,
  north,
  northEast,
  west,
  east,
  southWest,
  south,
  southEast,
}
