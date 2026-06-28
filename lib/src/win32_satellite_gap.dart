import 'dart:async';
import 'dart:ffi';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';

import 'win32_extra.dart';

/// Default logical-pixel gap between a frameless toolbar and satellite windows.
const kDefaultToolbarSatelliteGap = 8.0;

/// Sizes a satellite child to its intrinsic width/height so the native HWND
/// matches painted content.
///
/// Place **outside** [Material] at the tooltip/popup root. A root [Material]
/// expands to [BoxConstraints.maxWidth]; corner [WindowPositioner] anchors then
/// use the loose cap and trailing tooltips appear far to the left.
class Win32SatelliteTightSize extends StatelessWidget {
  const Win32SatelliteTightSize({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: IntrinsicHeight(
        child: IntrinsicWidth(
          child: child,
        ),
      ),
    );
  }
}

/// High-level placement for Win32 satellite windows (tooltips, popups).
///
/// Use [attachWin32SatelliteMaintainer] after creating the child window.
///
/// **Horizontal (X):** use a corner [WindowPositioner] (`topRight` / `topLeft`)
/// with default [BoxConstraints] and [Overlay.wrap] `alwaysSizeToContent: true`
/// on the child so the engine autosizes the HWND. For legacy loose caps use
/// [Win32SatelliteTightSize] or [nativeTrailing] / [nativeLeading].
///
/// **Vertical (Y):** the maintainer applies [gapLogical] below the parent —
/// Flutter cannot offset children with positive Y below the toolbar.
class Win32SatellitePlacement {
  const Win32SatellitePlacement({
    this.gapLogical = kDefaultToolbarSatelliteGap,
    this.horizontalAlign = Win32SatelliteHorizontalAlign.flutter,
    this.shrinkChildToContent = false,
  });

  /// Centered under the anchor; maintains vertical [gapLogical] only.
  static const centeredBelowAnchor = Win32SatellitePlacement(
    gapLogical: kDefaultToolbarSatelliteGap,
  );

  /// Trailing below toolbar: Y gap only — pair with `topRight` positioner and
  /// [Overlay.wrap] `alwaysSizeToContent: true` (Flutter reference pattern).
  static const trailingBelowToolbar = Win32SatellitePlacement(
    gapLogical: kDefaultToolbarSatelliteGap,
  );

  /// Leading below toolbar: Y gap only — pair with `topLeft` positioner and
  /// [Overlay.wrap] `alwaysSizeToContent: true`.
  static const leadingBelowToolbar = Win32SatellitePlacement(
    gapLogical: kDefaultToolbarSatelliteGap,
  );

  /// Trailing below parent with a custom gap (logical pixels).
  static Win32SatellitePlacement trailing({double gapLogical = kDefaultToolbarSatelliteGap}) {
    return Win32SatellitePlacement(gapLogical: gapLogical);
  }

  /// Leading below parent with a custom gap (logical pixels).
  static Win32SatellitePlacement leading({double gapLogical = kDefaultToolbarSatelliteGap}) {
    return Win32SatellitePlacement(gapLogical: gapLogical);
  }

  /// Native parent-trailing X + shrink (matrix alternate — prefer positioner path).
  static Win32SatellitePlacement nativeTrailing({
    double gapLogical = kDefaultToolbarSatelliteGap,
  }) {
    return Win32SatellitePlacement(
      gapLogical: gapLogical,
      horizontalAlign: Win32SatelliteHorizontalAlign.parentTrailing,
      shrinkChildToContent: true,
    );
  }

  /// Native parent-leading X + shrink (matrix alternate).
  static Win32SatellitePlacement nativeLeading({
    double gapLogical = kDefaultToolbarSatelliteGap,
  }) {
    return Win32SatellitePlacement(
      gapLogical: gapLogical,
      horizontalAlign: Win32SatelliteHorizontalAlign.parentLeading,
      shrinkChildToContent: true,
    );
  }

  final double gapLogical;
  final Win32SatelliteHorizontalAlign horizontalAlign;
  final bool shrinkChildToContent;
}

/// Attaches or replaces a per-frame [Win32SatelliteGapController] for [child].
///
/// Call after creating the satellite window; call [Win32SatelliteGapController.dispose]
/// before hiding or destroying the child.
///
/// Returns null when [placement.gapLogical] is zero and no horizontal alignment
/// or content shrink is requested.
Win32SatelliteGapController? attachWin32SatelliteMaintainer({
  required BaseWindowController parent,
  required BaseWindowController child,
  Win32SatellitePlacement placement = Win32SatellitePlacement.centeredBelowAnchor,
  Win32SatelliteGapController? existing,
  VoidCallback? onApplied,
}) {
  existing?.dispose();
  final needsMaintainer = placement.gapLogical > 0 ||
      placement.horizontalAlign != Win32SatelliteHorizontalAlign.flutter ||
      placement.shrinkChildToContent;
  if (!needsMaintainer) {
    return null;
  }
  return Win32SatelliteGapController(
    parentController: parent,
    childController: child,
    gapLogical: placement.gapLogical,
    horizontalAlign: placement.horizontalAlign,
    shrinkChildToContent: placement.shrinkChildToContent,
    onApplied: onApplied,
  )..start();
}

/// How a satellite child is aligned to its parent on the X axis (Win32 only).
enum Win32SatelliteHorizontalAlign {
  /// Leave X to Flutter's [WindowPositioner].
  flutter,

  /// Child left edge flush with parent left edge (screen coords).
  parentLeading,

  /// Child right edge flush with parent right edge (screen coords).
  parentTrailing,
}

HWND? _hwndFor(BaseWindowController controller) {
  try {
    if (controller is WindowControllerWin32) {
      return HWND((controller as WindowControllerWin32).windowHandle);
    }
    if (controller is PopupWindowControllerWin32) {
      return HWND(controller.getWindowHandle());
    }
    if (controller is TooltipWindowControllerWin32) {
      return HWND(controller.windowHandle);
    }
  } on StateError {
    // Child window was destroyed while a frame callback was pending.
  }
  return null;
}

ui.Size? _contentSizeLogical(BaseWindowController controller) {
  try {
    final size = controller.contentSize;
    if (size.width <= 0 || size.height <= 0) {
      return null;
    }
    return size;
  } on StateError {
    return null;
  }
}

/// Laid-out child dimensions for shrinking the native HWND before edge align.
ui.Size? _layoutSizeLogical(BaseWindowController controller) {
  ui.Size? viewSize;
  try {
    final view = controller.rootView;
    final dpr = view.devicePixelRatio;
    if (dpr > 0) {
      final physical = view.physicalSize;
      if (physical.width > 0 && physical.height > 0) {
        viewSize = ui.Size(physical.width / dpr, physical.height / dpr);
      }
    }
  } on StateError {
    // Window destroyed.
  }

  final hwndSize = _contentSizeLogical(controller);
  if (viewSize == null) {
    return hwndSize;
  }
  if (hwndSize == null) {
    return viewSize;
  }
  return ui.Size(
    math.min(viewSize.width, hwndSize.width),
    math.min(viewSize.height, hwndSize.height),
  );
}

({int left, int top, int right, int bottom})? _parentClientScreenRect(HWND hwnd) {
  final clientRect = calloc<RECT>();
  final topLeft = calloc<POINT>();
  final bottomRight = calloc<POINT>();
  try {
    GetClientRect(hwnd, clientRect);
    topLeft.ref.x = clientRect.ref.left;
    topLeft.ref.y = clientRect.ref.top;
    bottomRight.ref.x = clientRect.ref.right;
    bottomRight.ref.y = clientRect.ref.bottom;
    ClientToScreen(hwnd, topLeft);
    ClientToScreen(hwnd, bottomRight);
    return (
      left: topLeft.ref.x,
      top: topLeft.ref.y,
      right: bottomRight.ref.x,
      bottom: bottomRight.ref.y,
    );
  } finally {
    calloc.free(clientRect);
    calloc.free(topLeft);
    calloc.free(bottomRight);
  }
}

/// Reapplies a gap below [parentController] on every frame for [childController].
///
/// Flutter's [WindowPositioner] clamps anchor Y to the parent client bottom, so
/// positive Y offsets cannot place children below the toolbar. The Win32 engine
/// also calls `SetWindowPos` whenever child content resizes. This controller
/// shifts the child frame down whenever Flutter snaps it flush to the parent
/// bottom.
///
/// Calls [PopupWindowController.updatePosition] / [TooltipWindowController.updatePosition]
/// only when the parent client screen rect changes (drag/resize), not every frame.
/// That avoids fighting the Y-gap [SetWindowPos] adjustment. Anchor moves while
/// the parent is static are handled by [ElementPositionTracker] in app code.
///
/// Call [start] after creating the child window; call [dispose] before destroying
/// the child or when hiding it.
class Win32SatelliteGapController {
  Win32SatelliteGapController({
    required this.parentController,
    required this.childController,
    this.gapLogical = kDefaultToolbarSatelliteGap,
    this.horizontalAlign = Win32SatelliteHorizontalAlign.flutter,
    this.shrinkChildToContent = false,
    this.onApplied,
  });

  final BaseWindowController parentController;
  final BaseWindowController childController;
  final double gapLogical;
  final Win32SatelliteHorizontalAlign horizontalAlign;

  /// When true, sizes the child frame from laid-out content before applying
  /// trailing/leading X (fixes corner anchors when [BoxConstraints.maxWidth]
  /// is much larger than painted content).
  final bool shrinkChildToContent;

  /// Optional debug hook when a gap adjustment is applied to the native HWND.
  final VoidCallback? onApplied;

  bool _active = false;
  int _generation = 0;
  ({int left, int top, int right, int bottom})? _lastParentClientScreenRect;

  bool _parentClientScreenRectChanged(
    ({int left, int top, int right, int bottom}) rect,
  ) {
    final last = _lastParentClientScreenRect;
    if (last == null) {
      return true;
    }
    return last.left != rect.left ||
        last.top != rect.top ||
        last.right != rect.right ||
        last.bottom != rect.bottom;
  }

  void _rememberParentClientScreenRect(
    ({int left, int top, int right, int bottom}) rect,
  ) {
    _lastParentClientScreenRect = rect;
  }

  /// Begins maintaining the gap until [dispose].
  void start() {
    if (_active) {
      return;
    }
    _active = true;
    _scheduleFrame();
  }

  void _scheduleFrame() {
    if (!_active) {
      return;
    }
    final generation = _generation;
    // Post-frame + microtask: run after Flutter's tooltip UpdatePosition task
    // (posted from the raster thread when view size changes).
    SchedulerBinding.instance.addPostFrameCallback((_) {
      scheduleMicrotask(() {
        if (!_active || generation != _generation) {
          return;
        }
        final keepGoing = _applyGap();
        if (keepGoing && _active && generation == _generation) {
          _scheduleFrame();
        }
      });
    });
  }

  /// Returns false when the child is gone and this controller should stop.
  bool _applyGap() {
    if (parentController is WindowControllerWin32 &&
        childController is WindowControllerWin32) {
      return _applyGapViaSetWindowFrame(
        parent: parentController as WindowControllerWin32,
        child: childController as WindowControllerWin32,
      );
    }

    return _applyGapViaSetWindowPos();
  }

  bool _applyGapViaSetWindowFrame({
    required WindowControllerWin32 parent,
    required WindowControllerWin32 child,
  }) {
    try {
      final parentHwnd = HWND(parent.windowHandle);
      if (parentHwnd.isNull || !IsWindow(parentHwnd)) {
        _active = false;
        return false;
      }

      final parentClient = _parentClientScreenRect(parentHwnd);
      if (parentClient == null) {
        return true;
      }

      final parentMoved = _parentClientScreenRectChanged(parentClient);
      if (parentMoved) {
        try {
          switch (childController) {
            case TooltipWindowController tooltip:
              tooltip.updatePosition();
            default:
              break;
          }
        } on StateError {
          _active = false;
          return false;
        }
      }

      final dpr = (child as BaseWindowController).rootView.devicePixelRatio;
      final gap = gapLogical * dpr;

      var width = child.getWindowFrame().width;
      var height = child.getWindowFrame().height;

      if (shrinkChildToContent) {
        final content = _layoutSizeLogical(childController);
        if (content != null) {
          final contentW = content.width * dpr;
          final contentH = content.height * dpr;
          if (contentW > 0 && contentH > 0) {
            width = contentW;
            height = contentH;
          }
        }
      }

      if (width <= 0 || height <= 0) {
        return true;
      }

      final left = switch (horizontalAlign) {
        Win32SatelliteHorizontalAlign.parentTrailing =>
          parentClient.right - width,
        Win32SatelliteHorizontalAlign.parentLeading =>
          parentClient.left.toDouble(),
        Win32SatelliteHorizontalAlign.flutter => child.getWindowFrame().left,
      };
      final top = gapLogical > 0
          ? parentClient.bottom + gap
          : child.getWindowFrame().top;

      final target = ui.Rect.fromLTWH(left, top, width, height);
      final current = child.getWindowFrame();
      if (!_frameNeedsUpdate(current, target)) {
        _rememberParentClientScreenRect(parentClient);
        return true;
      }

      child.setWindowFrame(target);
      onApplied?.call();
      _rememberParentClientScreenRect(parentClient);
      return true;
    } on StateError {
      _active = false;
      return false;
    }
  }

  bool _applyGapViaSetWindowPos() {
    final parentHwnd = _hwndFor(parentController);
    final childHwnd = _hwndFor(childController);
    if (parentHwnd == null ||
        childHwnd == null ||
        parentHwnd.isNull ||
        childHwnd.isNull ||
        !IsWindow(parentHwnd) ||
        !IsWindow(childHwnd)) {
      _active = false;
      return false;
    }

    final parentClient = _parentClientScreenRect(parentHwnd);
    if (parentClient == null) {
      return true;
    }

    final gapPhysical =
        (gapLogical * childController.rootView.devicePixelRatio).round();

    final parentMoved = _parentClientScreenRectChanged(parentClient);
    if (parentMoved) {
      try {
        switch (childController) {
          case PopupWindowController popup:
            popup.updatePosition();
          case TooltipWindowController tooltip:
            tooltip.updatePosition();
          default:
            break;
        }
      } on StateError {
        _active = false;
        return false;
      }
    }

    final childRect = calloc<RECT>();
    try {
      GetWindowRect(childHwnd, childRect);

      final dpr = childController.rootView.devicePixelRatio;
      var width = childRect.ref.right - childRect.ref.left;
      var height = childRect.ref.bottom - childRect.ref.top;

      if (shrinkChildToContent) {
        final content = _layoutSizeLogical(childController);
        if (content != null) {
          final contentW = (content.width * dpr).round();
          final contentH = (content.height * dpr).round();
          if (contentW > 0 && contentH > 0) {
            width = contentW;
            height = contentH;
          }
        }
      }

      final targetTop =
          gapPhysical > 0 ? parentClient.bottom + gapPhysical : childRect.ref.top;
      final childTop = childRect.ref.top;

      var targetLeft = childRect.ref.left;
      switch (horizontalAlign) {
        case Win32SatelliteHorizontalAlign.flutter:
          break;
        case Win32SatelliteHorizontalAlign.parentLeading:
          targetLeft = parentClient.left;
        case Win32SatelliteHorizontalAlign.parentTrailing:
          targetLeft = parentClient.right - width;
      }

      final needsY = gapPhysical > 0 && childTop < targetTop - 1;
      final needsX = switch (horizontalAlign) {
        Win32SatelliteHorizontalAlign.flutter => false,
        Win32SatelliteHorizontalAlign.parentLeading =>
          (targetLeft - childRect.ref.left).abs() > 1,
        Win32SatelliteHorizontalAlign.parentTrailing =>
          (targetLeft - childRect.ref.left).abs() > 1,
      };
      final needsResize = shrinkChildToContent &&
          (width != childRect.ref.right - childRect.ref.left ||
              height != childRect.ref.bottom - childRect.ref.top);

      if (!needsY && !needsX && !needsResize) {
        _rememberParentClientScreenRect(parentClient);
        return true;
      }

      SetWindowPos(
        childHwnd,
        null,
        targetLeft,
        needsY ? targetTop : childTop,
        width,
        height,
        SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER,
      );
      onApplied?.call();
      _rememberParentClientScreenRect(parentClient);
      return true;
    } finally {
      calloc.free(childRect);
    }
  }

  bool _frameNeedsUpdate(ui.Rect current, ui.Rect target) {
    return (current.left - target.left).abs() > 1 ||
        (current.top - target.top).abs() > 1 ||
        (current.width - target.width).abs() > 1 ||
        (current.height - target.height).abs() > 1;
  }

  /// Stops maintaining the gap.
  void dispose() {
    _active = false;
    _generation++;
    _lastParentClientScreenRect = null;
  }
}
