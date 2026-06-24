import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// HWNDs registered for DWM-compatible click-through (no [WS_EX_LAYERED]).
final _dwmPassthroughHwnds = <int>{};

bool isDwmCompatiblePassthroughHwnd(HWND hwnd) =>
    _dwmPassthroughHwnds.contains(hwnd.address);

/// Click-through compatible with DWM [transparentBackdrop].
///
/// Uses [WM_NCHITTEST] registration plus [WS_EX_TRANSPARENT] only — never
/// [WS_EX_LAYERED], which breaks Flutter compositing on overlay windows.
void applyDwmCompatibleMousePassthrough(HWND hwnd, bool enabled) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  if (enabled) {
    _dwmPassthroughHwnds.add(hwnd.address);
    var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
    exStyle |= WS_EX_TRANSPARENT;
    exStyle &= ~WS_EX_LAYERED;
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
  } else {
    _dwmPassthroughHwnds.remove(hwnd.address);
    var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
    exStyle &= ~WS_EX_TRANSPARENT;
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
  }

  SetWindowPos(
    hwnd,
    null,
    0,
    0,
    0,
    0,
    SWP_NOMOVE |
        SWP_NOSIZE |
        SWP_NOZORDER |
        SWP_FRAMECHANGED |
        SWP_NOACTIVATE,
  );
}

/// Applies DWM-compatible passthrough on [hwnd] and its FlutterView child.
void applyDwmCompatibleMousePassthroughForWindow(HWND hwnd, bool enabled) {
  applyDwmCompatibleMousePassthrough(hwnd, enabled);

  final flutterView = _findFlutterView(hwnd);
  if (flutterView != null) {
    applyDwmCompatibleMousePassthrough(flutterView, enabled);
  }
}

/// Returns [HTTRANSPARENT] when [hwnd] or its root is in passthrough mode.
int? mousePassthroughNchitTest(HWND hwnd, int message) {
  if (message != WM_NCHITTEST) {
    return null;
  }

  if (_dwmPassthroughHwnds.contains(hwnd.address)) {
    return HTTRANSPARENT;
  }

  final root = GetAncestor(hwnd, GA_ROOT);
  if (root.isNotNull && _dwmPassthroughHwnds.contains(root.address)) {
    return HTTRANSPARENT;
  }

  return null;
}

HWND? _findFlutterView(HWND parent) {
  final className = 'FlutterView'.toNativeUtf16();
  try {
    final child = FindWindowEx(parent, null, PCWSTR(className), null);
    if (child.value.isNull) {
      return null;
    }
    return child.value;
  } finally {
    malloc.free(className);
  }
}

/// Lifecycle-exact layered click-through on the top-level HWND.
///
/// Overlay windows: apply [transparentBackdrop] first, then call this after a
/// short delay (~150ms) so Flutter content stays visible (matrix variants E/F).
void setIgnoresMouseEventsForHwnd(HWND hwnd, bool ignores) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
  if ((exStyle & WS_EX_LAYERED) == 0) {
    exStyle |= WS_EX_LAYERED;
  }

  if (ignores) {
    exStyle |= WS_EX_TRANSPARENT;
  } else {
    exStyle &= ~WS_EX_TRANSPARENT;
  }

  SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);

  var alpha = 255;
  final alphaPtr = calloc<Uint8>();
  final flags = calloc<Uint32>();
  try {
    if (GetLayeredWindowAttributes(hwnd, nullptr, alphaPtr, flags).value) {
      alpha = alphaPtr.value;
    }
    if (alpha == 0) {
      alpha = 255;
    }
    SetLayeredWindowAttributes(hwnd, COLORREF(0), alpha, LWA_ALPHA);
  } finally {
    calloc.free(alphaPtr);
    calloc.free(flags);
  }
}
