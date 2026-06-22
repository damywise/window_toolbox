// ignore_for_file: constant_identifier_names, non_constant_identifier_names

@DefaultAsset('package:win32/win32.dart')
import 'dart:ffi';
import 'dart:ui' show Rect;

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
  point.ref.x = screenX;
  point.ref.y = screenY;
  ScreenToClient(hwnd, point);
  final result = (point.ref.x, point.ref.y);
  malloc.free(point);
  return result;
}

final class TRACKMOUSEEVENT extends Struct {
  @Uint32()
  external int cbSize;

  @Uint32()
  external int dwFlags;

  external Pointer _hwndTrack;

  HWND get hwndTrack => HWND(_hwndTrack);
  set hwndTrack(HWND value) => _hwndTrack = _hwndTrack = value;

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

final int Function(Pointer<Void>) GetDpiForWindow = DynamicLibrary.process()
    .lookupFunction<
      Uint32 Function(Pointer<Void>),
      int Function(Pointer<Void>)
    >('FlutterDesktopGetDpiForHWND');

/// Resizes [hwnd] to the content size Flutter intended before frameless
/// [WM_NCCALCSIZE] handling expanded the client area to the full frame.
///
/// Flutter sizes the window frame with `AdjustWindowRectExForDpi`, which is
/// unaware of custom non-client handling. Querying [WM_NCCALCSIZE] with
/// `wParam == 0` yields the standard client rect for the current frame.
void compensateFramelessContentSizeForHwnd(HWND hwnd) {
  final frameRect = calloc<RECT>();
  GetWindowRect(hwnd, frameRect);

  final clientRect = calloc<RECT>();
  clientRect.ref = frameRect.ref;
  calloc.free(frameRect);

  SendMessage(hwnd, WM_NCCALCSIZE, WPARAM(0), LPARAM(clientRect.address));
  final clientW = clientRect.ref.right - clientRect.ref.left;
  final clientH = clientRect.ref.bottom - clientRect.ref.top;
  calloc.free(clientRect);

  if (clientW <= 0 || clientH <= 0) {
    return;
  }

  SetWindowPos(
    hwnd,
    null,
    0,
    0,
    clientW,
    clientH,
    SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
  );
}

/// Sets [hwnd]'s outer frame in screen (physical) coordinates.
void setWindowFrameForHwnd(HWND hwnd, Rect frame) {
  SetWindowPos(
    hwnd,
    null,
    frame.left.round(),
    frame.top.round(),
    frame.width.round(),
    frame.height.round(),
    SWP_NOZORDER | SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
  );
}

/// Re-applies the current frame so Flutter picks up client-area changes.
void refreshWindowSizeForHwnd(HWND hwnd) {
  final rect = calloc<RECT>();
  GetWindowRect(hwnd, rect);
  SetWindowPos(
    hwnd,
    null,
    rect.ref.left,
    rect.ref.top,
    rect.ref.right - rect.ref.left,
    rect.ref.bottom - rect.ref.top,
    SWP_NOMOVE | SWP_NOACTIVATE,
  );
  calloc.free(rect);
}

const int _wcaAccentPolicy = 19;
const int _accentEnableTransparentGradient = 2;

final int Function(Pointer, Pointer) _setWindowCompositionAttribute =
    DynamicLibrary.open('user32.dll').lookupFunction<
      Int32 Function(Pointer, Pointer),
      int Function(Pointer, Pointer)
    >('SetWindowCompositionAttribute');

/// Enables per-pixel transparency via the DWM accent policy.
///
/// Does not call [DwmExtendFrameIntoClientArea]; that API conflicts with
/// frameless [WM_NCCALCSIZE] handling and restores visible non-client chrome.
void enableTransparentBackdropForHwnd(HWND hwnd) {
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
