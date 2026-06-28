import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:flutter/src/widgets/_window_linux.dart';
import 'package:flutter/widgets.dart';

import 'custom_window_init_options.dart';
import 'custom_window_macos.dart';
import 'custom_window_win32.dart';
import 'custom_window_linux.dart';
import 'win32_frameless_setup.dart';
import 'widgets.dart' show WindowTrafficLightInactiveConfigration;

/// Platform window chrome customization backing [enableCustomWindow].
abstract class CustomWindow {
  static CustomWindow? forController(BaseWindowController controller) {
    return _expando[controller];
  }

  static void init(
    BaseWindowController controller, {
    CustomWindowInitOptions options = CustomWindowInitOptions.none,
  }) {
    final merged =
        (_pendingInitOptions.remove(controller) ?? CustomWindowInitOptions.none)
            .merge(options);

    final existing = forController(controller);

    if (existing != null) {
      mergeOrScheduleOptions(controller, merged);
      return;
    }

    _recordAppliedOptions(controller, merged);

    final created = _create(
      controller,
      options: merged,
      onClose: () {
        _expando[controller] = null;
        final handle = hwndAddressFor(controller);
        if (handle != null) {
          _appliedInitOptionsByHandle.remove(handle);
        }
      },
    );

    if (created != null) {
      _expando[controller] = created;
    }
  }

  /// Configures optional Win32 frameless extras. No-op on other platforms.
  ///
  /// Prefer passing options to [enableCustomWindow] for new code. This method
  /// schedules deferred setup when custom window is already enabled.
  static void configureFramelessWindow(
    BaseWindowController controller, {
    Rect? frame,
    bool transparentBackdrop = false,
    bool mousePassthrough = false,
  }) {
    mergeOrScheduleOptions(
      controller,
      CustomWindowInitOptions(
        frame: frame,
        transparentBackdrop: transparentBackdrop,
        mousePassthrough: mousePassthrough,
      ),
    );
  }

  static void mergeOrScheduleOptions(
    BaseWindowController controller,
    CustomWindowInitOptions options,
  ) {
    _recordAppliedOptions(controller, options);

    _pendingInitOptions[controller] =
        (_pendingInitOptions[controller] ?? CustomWindowInitOptions.none)
            .merge(options);

    // Frameless setup (e.g. transparent backdrop) must run even when
    // [enableCustomWindow] was not called — satellites use configureFramelessWindow.
    if (controller is WindowControllerWin32) {
      scheduleWin32FramelessSetupFromOptions(
        controller as WindowControllerWin32,
        options,
      );
    } else {
      scheduleWin32FramelessSetupFromOptionsForSatellite(controller, options);
    }
  }

  /// Re-applies Win32 backdrop, switcher, and topmost flags from the last
  /// [enableCustomWindow] / [configureFramelessWindow] options. Does not
  /// re-schedule mouse passthrough delays.
  static void reapplyWin32Chrome(WindowControllerWin32 controller) {
    final options = _appliedInitOptionsByHandle[controller.windowHandle.address];
    if (options == null) {
      return;
    }
    reapplyWin32ChromeFromOptions(controller, options);
  }

  /// Win32-only: lifecycle-exact layered click-through toggle.
  static void setIgnoresMouseEvents(
    BaseWindowController controller,
    bool ignores,
  ) {
    final customWindow = forController(controller);

    if (customWindow is CustomWindowWin32) {
      customWindow.setIgnoresMouseEvents(ignores);
    }
  }

  static final _expando = Expando<CustomWindow>('CustomWindow');

  static final _pendingInitOptions =
      <BaseWindowController, CustomWindowInitOptions>{};

  static final _appliedInitOptionsByHandle =
      <int, CustomWindowInitOptions>{};

  static void _recordAppliedOptions(
    BaseWindowController controller,
    CustomWindowInitOptions options,
  ) {
    final handle = hwndAddressFor(controller);
    if (handle == null) {
      return;
    }
    _appliedInitOptionsByHandle[handle] =
        (_appliedInitOptionsByHandle[handle] ?? CustomWindowInitOptions.none)
            .merge(options);
  }

  static CustomWindow? _create(
    BaseWindowController controller, {
    required CustomWindowInitOptions options,
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
        options: options,
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
