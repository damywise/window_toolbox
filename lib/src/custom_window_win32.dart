import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';

import 'custom_window.dart';
import 'custom_window_init_options.dart';
import 'win32_extra.dart';
import 'win32_frameless_setup.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;

import 'dart:ffi' hide Size;

import 'win32_mouse_passthrough.dart';
import 'win32_util.dart';
import 'widgets.dart' show WindowTrafficLightInactiveConfigration;

class SubclassState {
  bool needRearmMouseTracker = false;
}

final _subclassState = <int, SubclassState>{};

int _subclassProc(
  Pointer hwnd,
  int msg,
  int wparam,
  int lparam,
  int idSubclass,
  int refData,
) {
  final state = _subclassState.putIfAbsent(hwnd.address, () => SubclassState());
  if (msg == WM_DESTROY) {
    _subclassState.remove(hwnd.address);
  }
  if (msg == WM_MOUSELEAVE) {
    HWND parentWindow = GetAncestor(HWND(hwnd), GA_ROOT);
    if (parentWindow.isNotNull) {
      final cursorPos = malloc<POINT>();
      try {
        GetCursorPos(cursorPos);
        final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
        final parentHitTest = SendMessage(
          parentWindow,
          WM_NCHITTEST,
          WPARAM(0),
          LPARAM(cursorPosLparam),
        ).value;
        if (parentHitTest == HTMAXBUTTON || parentHitTest == HTCAPTION) {
          state.needRearmMouseTracker = true;
          return 0;
        }
      } finally {
        malloc.free(cursorPos);
      }
    }
  } else if (msg == WM_NCHITTEST) {
    // NCHITTEST needs to cooperate with parent (top level) window.
    HWND parentWindow = GetAncestor(HWND(hwnd), GA_ROOT);
    if (parentWindow.isNotNull) {
      final parentResult = SendMessage(
        parentWindow,
        msg,
        WPARAM(wparam),
        LPARAM(lparam),
      ).value;
      if (parentResult == HTCLIENT) {
        return HTCLIENT;
      } else {
        return HTTRANSPARENT;
      }
    } else {
      return HTCLIENT;
    }
  } else if (msg == WM_MOUSEMOVE) {
    if (state.needRearmMouseTracker) {
      final trackMouseEvent = malloc<TRACKMOUSEEVENT>();
      try {
        trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
        trackMouseEvent.ref.hwndTrack = HWND(hwnd);
        trackMouseEvent.ref.dwFlags = TME_LEAVE;
        TrackMouseEvent(trackMouseEvent);
        state.needRearmMouseTracker = false;
      } finally {
        malloc.free(trackMouseEvent);
      }
    }
  }
  return DefSubclassProc(HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam));
}

class CustomWindowWin32 extends CustomWindow {
  CustomWindowWin32(
    this.controller, {
    required this.onClose,
    this._options = CustomWindowInitOptions.none,
  }) : _isFrameless = _options.isFrameless {
    controller.addWindowsMessageHandler(handleWindowsMessage);
    _ensureResizeChromeStyle(_hwnd);

    _flutterView = _findFlutterView();

    SetWindowSubclass(
      _flutterView,
      Pointer.fromFunction<SUBCLASSPROC>(_subclassProc, 0),
      0,
      0,
    );

    if (_isFrameless) {
      ShowWindow(_hwnd, SW_SHOW);
    }

    if (_needsDeferredWin32Setup) {
      scheduleWin32FramelessSetupFromOptions(
        controller,
        _options,
        compensateSize: _isFrameless && _options.frame == null,
      );
    }
  }

  final CustomWindowInitOptions _options;
  final bool _isFrameless;

  bool get _needsDeferredWin32Setup =>
      _isFrameless ||
      _options.frame != null ||
      _options.transparentBackdrop ||
      _options.mousePassthrough ||
      _options.hideFromSwitcher ||
      _options.alwaysOnTop;

  final VoidCallback onClose;

  late final HWND _flutterView;

  static const int _wmNcUahDrawCaption = 0x00AE;
  static const int _wmNcUahDrawFrame = 0x00AF;

  HWND _findFlutterView() {
    final className = "FlutterView".toNativeUtf16();
    final child = FindWindowEx(_hwnd, null, PCWSTR(className), null);
    malloc.free(className);
    if (child.value.isNull) {
      throw Exception('Could not find FlutterView child window');
    }
    return child.value;
  }

  final WindowControllerWin32 controller;

  HWND get _hwnd => HWND(controller.windowHandle);

  static void _ensureResizeChromeStyle(HWND hwnd) {
    var style = GetWindowLongPtr(hwnd, GWL_STYLE).value;
    style |=
        WS_THICKFRAME |
        WS_CAPTION |
        WS_SYSMENU |
        WS_MAXIMIZEBOX |
        WS_MINIMIZEBOX |
        WS_OVERLAPPED;
    SetWindowLongPtr(hwnd, GWL_STYLE, style);
    SetWindowPos(
      hwnd,
      null,
      0,
      0,
      0,
      0,
      SWP_FRAMECHANGED |
          SWP_NOMOVE |
          SWP_NOSIZE |
          SWP_NOZORDER |
          SWP_NOACTIVATE,
    );
  }

  /// Titleless [WM_NCCALCSIZE]: remove the caption band but keep native frame
  /// insets on the sides and bottom (knopp/window_toolbox upstream).
  static int _applyTitlelessNccalcsize(HWND windowHandle, int lParam) {
    final dpi = flutterDesktopDpiForHwnd(windowHandle.cast<Void>());
    final padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi).value;
    final borderLR =
        GetSystemMetricsForDpi(SM_CXFRAME, dpi).value + padding;
    final borderTB =
        GetSystemMetricsForDpi(SM_CYFRAME, dpi).value + padding;
    final params = Pointer<NCCALCSIZE_PARAMS>.fromAddress(lParam);
    final rect = params.ref.rgrc[0];
    final scale = dpi / 96.0;
    if (IsZoomed(windowHandle)) {
      rect.top += borderTB;
    } else {
      // Otherwise we miss one pixel from top.
      rect.top += (1 * scale).round();
    }
    rect.left += borderLR;
    rect.right -= borderLR;
    rect.bottom -= borderTB;
    return 0;
  }

  /// Compensates for off-screen borders when maximized. See window_manager's
  /// adjustNCCALCSIZE and MonitorFromRect vs MonitorFromWindow notes.
  static void _adjustNccalcsizeForMaximized(Pointer<NCCALCSIZE_PARAMS> params) {
    var leftInset = 8;
    var topInset = 8;

    final frameRect = params.ref.rgrc[0];
    final frameRectPtr = calloc<RECT>();
    try {
      frameRectPtr.ref = frameRect;
      final monitor = MonitorFromRect(frameRectPtr, MONITOR_DEFAULTTONEAREST);
      if (!monitor.isNull) {
        final monitorInfo = calloc<MONITORINFO>();
        try {
          monitorInfo.ref.cbSize = sizeOf<MONITORINFO>();
          if (GetMonitorInfo(monitor, monitorInfo)) {
            leftInset = frameRect.left - monitorInfo.ref.rcWork.left;
            topInset = frameRect.top - monitorInfo.ref.rcWork.top;
          }
        } finally {
          calloc.free(monitorInfo);
        }
      }
    } finally {
      calloc.free(frameRectPtr);
    }

    frameRect.top += topInset;
    frameRect.left += leftInset;
    frameRect.bottom -= leftInset;
    frameRect.right -= leftInset;
  }

  final _dragExcludeRects = <BuildContext, Rect>{};
  final _maximizeButtonRects = <BuildContext, Rect>{};

  @override
  void setDragExcludeRectForElement(BuildContext element, Rect? rect) {
    if (rect == null) {
      _dragExcludeRects.remove(element);
    } else {
      _dragExcludeRects[element] = rect;
    }
  }

  @override
  void setDraggableRectForElement(BuildContext element, Rect? rect) {}

  @override
  void setMaximizeButtonFrame(BuildContext element, Rect? rect) {
    if (rect == null) {
      _maximizeButtonRects.remove(element);
    } else {
      _maximizeButtonRects[element] = rect;
    }
  }

  @override
  Size getTrafficLightSize() {
    return Size.zero;
  }

  @override
  void setTrafficLightConfiguration(
    Offset offset,
    Brightness? brightness,
    WindowTrafficLightInactiveConfigration? inactiveConfigration,
  ) {}

  @override
  void requestClose() {
    PostMessage(_hwnd, WM_CLOSE, WPARAM(0), LPARAM(0));
  }

  bool _trackingMouseLeave = false;

  void setIgnoresMouseEvents(bool ignores) {
    setIgnoresMouseEventsForHwnd(_hwnd, ignores);
  }

  int? _handleFramelessNchitTest(
    HWND windowHandle,
    int lParam,
  ) {
    final (xPos, yPos) = splitLParam(lParam);
    final (xClient, yClient) = screenToClient(_hwnd, xPos, yPos);

    final scale = flutterDesktopDpiForHwnd(windowHandle.cast<Void>()) / 96.0;
    final x = xClient / scale;
    final y = yClient / scale;

    final rect = malloc<RECT>();
    try {
      GetClientRect(_hwnd, rect);
      final width = (rect.ref.right - rect.ref.left) / scale;
      final height = (rect.ref.bottom - rect.ref.top) / scale;

      const edgeSize = 1.0;

      if (_maximizeButtonRects.values.any(
        (r) => r.contains(Offset(x, y)),
      )) {
        return HTMAXBUTTON;
      }

      if (y < edgeSize) {
        if (x < edgeSize) {
          return HTTOPLEFT;
        } else if (x > width - edgeSize) {
          return HTTOPRIGHT;
        } else {
          return HTTOP;
        }
      } else if (y > height - edgeSize) {
        if (x < edgeSize) {
          return HTBOTTOMLEFT;
        } else if (x > width - edgeSize) {
          return HTBOTTOMRIGHT;
        } else {
          return HTBOTTOM;
        }
      } else if (x < edgeSize) {
        return HTLEFT;
      } else if (x > width - edgeSize) {
        return HTRIGHT;
      }

      for (final excludeRect in _dragExcludeRects.values) {
        if (excludeRect.contains(Offset(x, y))) {
          return HTCLIENT;
        }
      }
      return HTCLIENT;
    } finally {
      malloc.free(rect);
    }
  }

  int? _handleTitlelessNchitTest(
    HWND windowHandle,
    int lParam,
  ) {
    final (xPos, yPos) = splitLParam(lParam);
    final (xClient, yClient) = screenToClient(_hwnd, xPos, yPos);

    final scale = flutterDesktopDpiForHwnd(windowHandle.cast<Void>()) / 96.0;
    final x = xClient / scale;
    final y = yClient / scale;

    final rect = malloc<RECT>();
    try {
      GetClientRect(_hwnd, rect);
      final width = (rect.ref.right - rect.ref.left) / scale;
      final height = (rect.ref.bottom - rect.ref.top) / scale;

      // Sides and bottom are extended through WM_NCCALCSIZE.
      const edgeSize = 1.0;
      const topEdgeSize = 3.0; // 1px from WM_NCCALCSIZE + 3px

      if (_maximizeButtonRects.values.any(
        (r) => r.contains(Offset(x, y)),
      )) {
        return HTMAXBUTTON;
      }

      if (y < topEdgeSize) {
        if (x < topEdgeSize) {
          return HTTOPLEFT;
        } else if (x > width - topEdgeSize) {
          return HTTOPRIGHT;
        } else {
          return HTTOP;
        }
      } else if (y > height - edgeSize) {
        if (x < edgeSize) {
          return HTBOTTOMLEFT;
        } else if (x > width - edgeSize) {
          return HTBOTTOMRIGHT;
        } else {
          return HTBOTTOM;
        }
      } else if (x < edgeSize) {
        return HTLEFT;
      } else if (x > width - edgeSize) {
        return HTRIGHT;
      }

      for (final excludeRect in _dragExcludeRects.values) {
        if (excludeRect.contains(Offset(x, y))) {
          return HTCLIENT;
        }
      }
      return HTCLIENT;
    } finally {
      malloc.free(rect);
    }
  }

  int? handleWindowsMessage(
    HWND windowHandle,
    int message,
    int wParam,
    int lParam,
  ) {
    switch (message) {
      case WM_DESTROY:
        onClose();
        break;
      case WM_ERASEBKGND:
        if (_isFrameless) {
          return 0;
        }
        break;
      case WM_SIZE:
        // This would cause Flutter relayout with a very small size.
        if (wParam == SIZE_MINIMIZED) return 0;
        break;
      case WM_NCCALCSIZE:
        if (wParam == 1) {
          if (_isFrameless) {
            // Frameless: client fills the outer frame (zero NC inset).
            if (IsZoomed(_hwnd)) {
              final params = Pointer<NCCALCSIZE_PARAMS>.fromAddress(lParam);
              _adjustNccalcsizeForMaximized(params);
            }
            return 0;
          }
          return _applyTitlelessNccalcsize(windowHandle, lParam);
        }
        break;
      case WM_NCACTIVATE:
        if (_isFrameless) {
          return 1;
        }
        break;
      case _wmNcUahDrawCaption:
      case _wmNcUahDrawFrame:
        if (_isFrameless) {
          return 0;
        }
        break;
      case WM_NCHITTEST:
        final passthrough = mousePassthroughNchitTest(_hwnd, message);
        if (passthrough != null) {
          return passthrough;
        }
        if (_isFrameless) {
          return _handleFramelessNchitTest(windowHandle, lParam);
        }
        return _handleTitlelessNchitTest(windowHandle, lParam);
      case WM_NCMOUSEMOVE:
        if (wParam == HTMAXBUTTON || wParam == HTCAPTION) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);

          SendMessage(
            _flutterView,
            WM_MOUSEMOVE,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );

          if (!_trackingMouseLeave) {
            final trackMouseEvent = malloc<TRACKMOUSEEVENT>();
            try {
              trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
              trackMouseEvent.ref.hwndTrack = _hwnd;
              trackMouseEvent.ref.dwFlags = TME_LEAVE | TME_NONCLIENT;
              TrackMouseEvent(trackMouseEvent);
              _trackingMouseLeave = true;
            } finally {
              malloc.free(trackMouseEvent);
            }
          }
          return 0;
        }
      case WM_NCLBUTTONDOWN:
        if (wParam == HTMAXBUTTON) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);
          SendMessage(
            _flutterView,
            WM_LBUTTONDOWN,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );
          return 0;
        }
        return null;
      case WM_NCLBUTTONUP:
        if (wParam == HTMAXBUTTON) {
          final (x, y) = splitLParam(lParam);
          final (flutterX, flutterY) = screenToClient(_flutterView, x, y);
          SendMessage(
            _flutterView,
            WM_LBUTTONUP,
            WPARAM(0),
            LPARAM(makeLParam(flutterX, flutterY)),
          );
          return 0;
        }
        return null;
      case WM_NCMOUSELEAVE:
        _trackingMouseLeave = false;
        final cursorPos = malloc<POINT>();
        try {
          GetCursorPos(cursorPos);
          final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
          final flutterHitTest = SendMessage(
            _flutterView,
            WM_NCHITTEST,
            WPARAM(0),
            LPARAM(cursorPosLparam),
          ).value;
          if (flutterHitTest != HTCLIENT) {
            SendMessage(_flutterView, WM_MOUSELEAVE, WPARAM(0), LPARAM(0));
          }
        } finally {
          malloc.free(cursorPos);
        }
        return 0;
    }
    return null;
  }

  @override
  bool windowNeedsCustomBorder() {
    return false;
  }

  @override
  bool windowNeedsMoveDragDetector() {
    return true;
  }

  @override
  void setCustomBorderShadowWidth(
    double top,
    double left,
    double bottom,
    double right,
  ) {}

  @override
  void startWindowMoveDrag(Offset globalPosition) {
    ReleaseCapture();
    SendMessage(_hwnd, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION), LPARAM(0));
  }

  @override
  void startWindowResizeDrag(Offset globalPosition, WindowEdge edge) {}

  @override
  bool titlebarNeedsDoubleClickDetector() {
    return true;
  }
}
