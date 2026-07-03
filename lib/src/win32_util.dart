// ignore_for_file: constant_identifier_names, non_constant_identifier_names

@DefaultAsset('package:win32/win32.dart')
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

int _fixSign(int v) => v >= 0x8000 ? v - 0x10000 : v;

(int, int) splitLParam(int lParam) {
  final x = _fixSign(lParam & 0xFFFF);
  final y = _fixSign((lParam >> 16) & 0xFFFF);
  return (x, y);
}

int makeLParam(int x, int y) => (y << 16) | (x & 0xFFFF);

(int, int) screenToClient(HWND hwnd, int screenX, int screenY) {
  final point = malloc<POINT>();
  try {
    point.ref.x = screenX;
    point.ref.y = screenY;
    ScreenToClient(hwnd, point);
    return (point.ref.x, point.ref.y);
  } finally {
    malloc.free(point);
  }
}

final class TRACKMOUSEEVENT extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwFlags;

  external Pointer _hwndTrack;

  HWND get hwndTrack => HWND(_hwndTrack);
  set hwndTrack(HWND value) => _hwndTrack = value;

  @Uint32()
  external int dwHoverTime;
}

const TME_HOVER = 0x00000001;
const TME_LEAVE = 0x00000002;
const TME_CANCEL = 0x80000000;
const TME_NONCLIENT = 0x00000010;

const WM_SIZING = 0x0214;
const WM_NCMOUSELEAVE = 0x02A2;
const WM_MOUSELEAVE = 0x02A3;
const WM_ENTERSIZEMOVE = 0x0231;
const WM_EXITSIZEMOVE = 0x0232;

const WMSZ_LEFT = 1;
const WMSZ_RIGHT = 2;
const WMSZ_TOP = 3;
const WMSZ_TOPLEFT = 4;
const WMSZ_TOPRIGHT = 5;
const WMSZ_BOTTOM = 6;
const WMSZ_BOTTOMLEFT = 7;
const WMSZ_BOTTOMRIGHT = 8;

@Native<Int32 Function(Pointer<TRACKMOUSEEVENT>)>(
  isLeaf: true,
  symbol: 'TrackMouseEvent',
)
external int _TrackMouseEvent(Pointer<TRACKMOUSEEVENT> lpEventTrack);

bool TrackMouseEvent(Pointer<TRACKMOUSEEVENT> lpEventTrack) =>
    _TrackMouseEvent(lpEventTrack) != FALSE;

/// Screen-coordinate rectangle used by Win32 maximize helpers.
typedef Win32IntRect = ({int left, int top, int right, int bottom});

/// [NCCALCSIZE_PARAMS.rgrc] slot 0 as a native [RECT] pointer.
Pointer<RECT> nccalcsizeProposedClientRect(Pointer<NCCALCSIZE_PARAMS> params) =>
    Pointer<RECT>.fromAddress(params.address);

/// Returns whether [hwnd] is maximized using Win32 placement state.
bool isWindowMaximizedForHwnd(HWND hwnd) {
  if (IsZoomed(hwnd)) {
    return true;
  }
  final placement = calloc<WINDOWPLACEMENT>()
    ..ref.length = sizeOf<WINDOWPLACEMENT>();
  try {
    if (!GetWindowPlacement(hwnd, placement).value) {
      return false;
    }
    return placement.ref.showCmd == SW_MAXIMIZE;
  } finally {
    calloc.free(placement);
  }
}

/// True when [proposed] extends past the nearest monitor [MONITORINFO.rcWork].
bool proposedFrameExtendsBeyondWorkArea(Win32IntRect proposed) {
  final frameRectPtr = calloc<RECT>()
    ..ref.left = proposed.left
    ..ref.top = proposed.top
    ..ref.right = proposed.right
    ..ref.bottom = proposed.bottom;
  try {
    final monitor = MonitorFromRect(frameRectPtr, MONITOR_DEFAULTTONEAREST);
    if (monitor.isNull) {
      return false;
    }
    final monitorInfo = calloc<MONITORINFO>()
      ..ref.cbSize = sizeOf<MONITORINFO>();
    try {
      if (!GetMonitorInfo(monitor, monitorInfo)) {
        return false;
      }
      final work = monitorInfo.ref.rcWork;
      return proposed.left < work.left ||
          proposed.top < work.top ||
          proposed.right > work.right ||
          proposed.bottom > work.bottom;
    } finally {
      calloc.free(monitorInfo);
    }
  } finally {
    calloc.free(frameRectPtr);
  }
}

/// Client rect for a maximized frameless window (8 px fallback only).
Win32IntRect maximizeClientRect(Win32IntRect proposed, {Win32IntRect? rcWork}) {
  if (rcWork != null) {
    return rcWork;
  }
  const l = 8;
  const t = 8;
  return (
    left: proposed.left - l,
    top: proposed.top - t,
    right: proposed.right + l,
    bottom: proposed.bottom + t,
  );
}

void writeNccalcsizeProposedClientRect(
  Pointer<NCCALCSIZE_PARAMS> params,
  Win32IntRect rect,
) {
  final rgrc0 = nccalcsizeProposedClientRect(params);
  rgrc0.ref.left = rect.left;
  rgrc0.ref.top = rect.top;
  rgrc0.ref.right = rect.right;
  rgrc0.ref.bottom = rect.bottom;
}

/// Pure-Dart form of window_manager maximize inset math (for tests).
Win32IntRect windowManagerMaximizeClientRect(
  Win32IntRect proposed,
  Win32IntRect rcWork,
) {
  final l = proposed.left - rcWork.left;
  final t = proposed.top - rcWork.top;
  return (
    left: proposed.left - l,
    top: proposed.top - t,
    right: proposed.right + l,
    bottom: proposed.bottom + t,
  );
}

/// window_manager inset math: shrink extended maximize frame to [rcWork].
void applyWindowManagerMaximizeInsets(
  Pointer<RECT> rgrc0,
  Win32IntRect rcWork,
) {
  final adjusted = windowManagerMaximizeClientRect(
    (
      left: rgrc0.ref.left,
      top: rgrc0.ref.top,
      right: rgrc0.ref.right,
      bottom: rgrc0.ref.bottom,
    ),
    rcWork,
  );
  rgrc0.ref.left = adjusted.left;
  rgrc0.ref.top = adjusted.top;
  rgrc0.ref.right = adjusted.right;
  rgrc0.ref.bottom = adjusted.bottom;
}

/// Shrinks [NCCALCSIZE_PARAMS.rgrc] slot 0 to the nearest monitor work area.
void adjustMaximizedNccalcsizeClientRect(Pointer<NCCALCSIZE_PARAMS> params) {
  final rgrc0 = nccalcsizeProposedClientRect(params);
  final proposed = (
    left: rgrc0.ref.left,
    top: rgrc0.ref.top,
    right: rgrc0.ref.right,
    bottom: rgrc0.ref.bottom,
  );

  final frameRectPtr = calloc<RECT>()..ref = rgrc0.ref;
  try {
    final monitor = MonitorFromRect(frameRectPtr, MONITOR_DEFAULTTONEAREST);
    if (!monitor.isNull) {
      final monitorInfo = calloc<MONITORINFO>()
        ..ref.cbSize = sizeOf<MONITORINFO>();
      try {
        if (GetMonitorInfo(monitor, monitorInfo)) {
          final work = monitorInfo.ref.rcWork;
          applyWindowManagerMaximizeInsets(
            rgrc0,
            (
              left: work.left,
              top: work.top,
              right: work.right,
              bottom: work.bottom,
            ),
          );
          return;
        }
      } finally {
        calloc.free(monitorInfo);
      }
    }
  } finally {
    calloc.free(frameRectPtr);
  }

  writeNccalcsizeProposedClientRect(params, maximizeClientRect(proposed));
}

/// Sets [WM_GETMINMAXINFO] maximize position/size to the monitor work area.
void adjustFramelessMinMaxInfo(HWND hwnd, Pointer<MINMAXINFO> info) {
  DefWindowProc(hwnd, WM_GETMINMAXINFO, WPARAM(0), LPARAM(info.address));

  final windowRect = calloc<RECT>();
  try {
    GetWindowRect(hwnd, windowRect);
    final monitor = MonitorFromRect(windowRect, MONITOR_DEFAULTTONEAREST);
    if (monitor.isNull) {
      return;
    }
    final monitorInfo = calloc<MONITORINFO>()
      ..ref.cbSize = sizeOf<MONITORINFO>();
    try {
      if (!GetMonitorInfo(monitor, monitorInfo)) {
        return;
      }
      final work = monitorInfo.ref.rcWork;
      final monitorRect = monitorInfo.ref.rcMonitor;
      info.ref.ptMaxPosition.x = work.left - monitorRect.left;
      info.ref.ptMaxPosition.y = work.top - monitorRect.top;
      info.ref.ptMaxSize.x = work.right - work.left;
      info.ref.ptMaxSize.y = work.bottom - work.top;
    } finally {
      calloc.free(monitorInfo);
    }
  } finally {
    calloc.free(windowRect);
  }
}

final int Function(Pointer<Void>) flutterDesktopDpiForHwnd =
    DynamicLibrary.process().lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('FlutterDesktopGetDpiForHWND');
