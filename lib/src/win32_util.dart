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

// ============================================================================
// Transparency via SetWindowCompositionAttribute (undocumented API)
// ============================================================================

const int WCA_ACCENT_POLICY = 19;
const int ACCENT_DISABLED = 0;
const int ACCENT_ENABLE_TRANSPARENTGRADIENT = 2;
const int ACCENT_ENABLE_ACRYLICBLURBEHIND = 4;
const int ACCENT_ENABLE_HOSTBACKDROP = 5;

final _user32 = DynamicLibrary.open('user32.dll');
final _setWindowCompositionAttribute = _user32.lookupFunction<
  Int32 Function(Pointer, Pointer),
  int Function(Pointer, Pointer)
>('SetWindowCompositionAttribute');

final class _AccentPolicyStruct extends Struct {
  @Uint32()
  external int accentState;

  @Uint32()
  external int accentFlags;

  @Uint32()
  external int gradientColor;

  @Uint32()
  external int animationId;
}

final class _WindowCompositionAttribDataStruct extends Struct {
  @Uint32()
  external int attrib;

  external Pointer<Void> pvData;

  @Size()
  external int cbData;
}

/// Enables DWM transparent gradient on the given window.
///
/// This uses the undocumented `SetWindowCompositionAttribute` Win32 API
/// with `WCA_ACCENT_POLICY` and `AccentState = ACCENT_ENABLE_TRANSPARENTGRADIENT`
/// to enable per-pixel alpha through the DWM composition engine.
///
/// Combined with `DwmExtendFrameIntoClientArea({-1,-1,-1,-1})`, this
/// makes the Flutter content's transparent areas show the desktop behind.
///
/// Returns true on success, false on failure.
bool enableTransparentGradient(HWND hwnd) {
  return _applyAccentPolicy(hwnd, ACCENT_ENABLE_TRANSPARENTGRADIENT);
}

/// Disables DWM transparent gradient on the given window (restores opaque).
bool disableTransparentGradient(HWND hwnd) {
  return _applyAccentPolicy(hwnd, ACCENT_DISABLED);
}

bool _applyAccentPolicy(HWND hwnd, int accentState) {
  final accent = calloc<_AccentPolicyStruct>();
  accent.ref.accentState = accentState;
  accent.ref.accentFlags = 2;
  accent.ref.gradientColor = 0;
  accent.ref.animationId = 0;

  final data = calloc<_WindowCompositionAttribDataStruct>();
  data.ref.attrib = WCA_ACCENT_POLICY;
  data.ref.pvData = accent.cast();
  data.ref.cbData = sizeOf<_AccentPolicyStruct>();

  try {
    return _setWindowCompositionAttribute(
      hwnd.cast(),
      data.cast(),
    ) != 0;
  } finally {
    calloc.free(data);
    calloc.free(accent);
  }
}
