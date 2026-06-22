import 'package:ffi/ffi.dart';
import 'package:flutter/widgets.dart';
import 'package:win32/win32.dart';

import 'custom_window.dart';
import 'win32_extra.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;

import 'dart:ffi' hide Size;

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
      GetCursorPos(cursorPos);
      final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
      free(cursorPos);
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
      trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
      trackMouseEvent.ref.hwndTrack = HWND(hwnd);
      trackMouseEvent.ref.dwFlags = TME_LEAVE;
      TrackMouseEvent(trackMouseEvent);
      malloc.free(trackMouseEvent);
      state.needRearmMouseTracker = false;
    }
  }
  return DefSubclassProc(HWND(hwnd), msg, WPARAM(wparam), LPARAM(lparam));
}

class CustomWindowWin32 extends CustomWindow {
  CustomWindowWin32(this.controller, {required this.onClose}) {
    controller.addWindowsMessageHandler(handleWindowsMessage);
    _framelessActive = true;
    _makeWindowUndecorated(_hwnd);
    
    _flutterView = _findFlutterView();    
    
    SetWindowSubclass(
      _flutterView,
      Pointer.fromFunction<SUBCLASSPROC>(_subclassProc, 0),
      0,
      0,
    );

    // SetWindowLongPtr above replaces GWL_STYLE without WS_VISIBLE; restore show
    // state and correct the frame size after WM_NCCALCSIZE expands the client
    // area to the full frame (see flutter/flutter#188270).
    ShowWindow(_hwnd, SW_SHOW);
    controller.compensateFramelessContentSize();
    controller.updateSize();
    _enableTransparentBackdrop(_hwnd);
  }

  final VoidCallback onClose;

  late final HWND _flutterView;
  bool _framelessActive = false;

  static const int _wmNcUahDrawCaption = 0x00AE;
  static const int _wmNcUahDrawFrame = 0x00AF;

  HWND _findFlutterView() {
    final className = "FlutterView".toNativeUtf16();
    final child = FindWindowEx(_hwnd, null, PCWSTR(className), null);
    free(className);
    if (child.value.isNull) {
      throw Exception('Could not find FlutterView child window');
    }
    return child.value;
  }

  final WindowControllerWin32 controller;

  HWND get _hwnd => HWND(controller.windowHandle);

  static final int Function(Pointer<Void>) _getDpiForWindow =
      DynamicLibrary.process().lookupFunction<
        Uint32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FlutterDesktopGetDpiForHWND');

  static const int _wcaAccentPolicy = 19;
  static const int _accentEnableTransparentGradient = 2;

  static final int Function(Pointer, Pointer) _setWindowCompositionAttribute =
      DynamicLibrary.open('user32.dll').lookupFunction<
        Int32 Function(Pointer, Pointer),
        int Function(Pointer, Pointer)
      >('SetWindowCompositionAttribute');

  static void _enableTransparentBackdrop(HWND hwnd) {
    // Per-pixel transparency is driven by the accent policy alone.
    // DwmExtendFrameIntoClientArea(-1) conflicts with frameless WM_NCCALCSIZE
    // handling and restores visible non-client chrome.
    final accent = calloc<_AccentPolicy>();
    accent.ref.accentState = _accentEnableTransparentGradient;
    accent.ref.accentFlags = 2;

    final data = calloc<_WindowCompositionAttribData>();
    data.ref.attrib = _wcaAccentPolicy;
    data.ref.pvData = accent.cast();
    data.ref.cbData = sizeOf<_AccentPolicy>();

    try {
      _setWindowCompositionAttribute(hwnd.cast(), data.cast());
    } finally {
      calloc.free(data);
      calloc.free(accent);
    }
  }

  static void _makeWindowUndecorated(HWND hwnd) {
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

  /// Compensates for off-screen borders when maximized. See window_manager's
  /// adjustNCCALCSIZE and MonitorFromRect vs MonitorFromWindow notes.
  static void _adjustNccalcsizeForMaximized(Pointer<NCCALCSIZE_PARAMS> params) {
    var leftInset = 8;
    var topInset = 8;

    final frameRect = params.ref.rgrc[0];
    final frameRectPtr = calloc<RECT>();
    frameRectPtr.ref = frameRect;
    final monitor = MonitorFromRect(frameRectPtr, MONITOR_DEFAULTTONEAREST);
    calloc.free(frameRectPtr);
    if (monitor != 0) {
      final monitorInfo = calloc<MONITORINFO>();
      monitorInfo.ref.cbSize = sizeOf<MONITORINFO>();
      if (GetMonitorInfo(monitor, monitorInfo) != 0) {
        leftInset = frameRect.left - monitorInfo.ref.rcWork.left;
        topInset = frameRect.top - monitorInfo.ref.rcWork.top;
      }
      calloc.free(monitorInfo);
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
        return 0;
      case WM_SIZE:
        // This would cause Flutter relayout with a very small size.
        if (wParam == SIZE_MINIMIZED) return 0;
        break;
      case WM_NCCALCSIZE:
        if (wParam == 1 && _framelessActive) {
          if (IsZoomed(_hwnd)) {
            final params = Pointer<NCCALCSIZE_PARAMS>.fromAddress(lParam);
            _adjustNccalcsizeForMaximized(params);
          }
          return 0;
        }
        break;
      case WM_NCACTIVATE:
        if (_framelessActive) {
          return 1;
        }
        break;
      case _wmNcUahDrawCaption:
      case _wmNcUahDrawFrame:
        if (_framelessActive) {
          return 0;
        }
        break;
      case WM_NCHITTEST:
        final (xPos, yPos) = splitLParam(lParam);
        final (xClient, yClient) = screenToClient(_hwnd, xPos, yPos);

        double scale = _getDpiForWindow(windowHandle.cast()) / 96.0;
        double x = xClient / scale;
        double y = yClient / scale;

        final rect = malloc<RECT>();
        GetClientRect(_hwnd, rect);
        final width = (rect.ref.right - rect.ref.left) / scale;
        final height = (rect.ref.bottom - rect.ref.top) / scale;
        malloc.free(rect);

        const edgeSize = 1;

        if (_maximizeButtonRects.values.any((r) => r.contains(Offset(x, y)))) {
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
            trackMouseEvent.ref.cbSize = sizeOf<TRACKMOUSEEVENT>();
            trackMouseEvent.ref.hwndTrack = _hwnd;
            trackMouseEvent.ref.dwFlags = TME_LEAVE | TME_NONCLIENT;
            TrackMouseEvent(trackMouseEvent);
            malloc.free(trackMouseEvent);
            _trackingMouseLeave = true;
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
        GetCursorPos(cursorPos);
        final cursorPosLparam = makeLParam(cursorPos.ref.x, cursorPos.ref.y);
        free(cursorPos);
        final flutterHitTest = SendMessage(
          _flutterView,
          WM_NCHITTEST,
          WPARAM(0),
          LPARAM(cursorPosLparam),
        ).value;
        if (flutterHitTest != HTCLIENT) {
          SendMessage(_flutterView, WM_MOUSELEAVE, WPARAM(0), LPARAM(0));
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

final class _AccentPolicy extends Struct {
  @Uint32()
  external int accentState;

  @Uint32()
  external int accentFlags;

  @Uint32()
  external int gradientColor;

  @Uint32()
  external int animationId;
}

final class _WindowCompositionAttribData extends Struct {
  @Uint32()
  external int attrib;

  external Pointer<Void> pvData;

  @Uint32()
  external int cbData;
}
