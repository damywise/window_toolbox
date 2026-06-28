import 'package:win32/win32.dart';

void setHideFromSwitcherForHwnd(HWND hwnd, bool hide) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
  if (hide) {
    exStyle |= WS_EX_TOOLWINDOW;
    exStyle &= ~WS_EX_APPWINDOW;
  } else {
    exStyle &= ~WS_EX_TOOLWINDOW;
    exStyle |= WS_EX_APPWINDOW;
  }

  SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
  SetWindowPos(
    hwnd,
    null,
    0,
    0,
    0,
    0,
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED | SWP_NOACTIVATE,
  );
}

/// Undocumented but set by `SetWindowPos` with `HWND_TOPMOST` / `HWND_NOTOPMOST`.
const _WS_EX_TOPMOST = 0x00000008;

bool _hwndHasDesiredTopmostState(
  HWND hwnd,
  bool onTop, {
  required bool fullscreenCompatible,
}) {
  final exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
  final isTopmost = (exStyle & _WS_EX_TOPMOST) != 0;
  if (!onTop) {
    return !isTopmost;
  }
  if (!isTopmost) {
    return false;
  }
  if (!fullscreenCompatible) {
    return true;
  }
  final hasToolWindow = (exStyle & WS_EX_TOOLWINDOW) != 0;
  final hasAppWindow = (exStyle & WS_EX_APPWINDOW) != 0;
  return hasToolWindow && !hasAppWindow;
}

/// Port of `window_lifecycle_set_always_on_top` in ZOrderManagement.cpp.
void setAlwaysOnTopForHwnd(
  HWND hwnd,
  bool onTop, {
  bool fullscreenCompatible = true,
}) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  if (_hwndHasDesiredTopmostState(
    hwnd,
    onTop,
    fullscreenCompatible: fullscreenCompatible,
  )) {
    return;
  }

  if (onTop) {
    SetWindowPos(
      hwnd,
      HWND_TOPMOST,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );

    if (fullscreenCompatible) {
      var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
      exStyle |= WS_EX_TOOLWINDOW;
      exStyle &= ~WS_EX_APPWINDOW;
      SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
    }
  } else {
    SetWindowPos(
      hwnd,
      HWND_NOTOPMOST,
      0,
      0,
      0,
      0,
      SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
    );
  }
}

/// Sets per-pixel alpha on [hwnd] via [WS_EX_LAYERED] / [SetLayeredWindowAttributes].
void setWindowAlphaForHwnd(HWND hwnd, int alpha) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  final clamped = alpha.clamp(0, 255);
  var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
  if ((exStyle & WS_EX_LAYERED) == 0) {
    exStyle |= WS_EX_LAYERED;
    SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
  }
  SetLayeredWindowAttributes(hwnd, COLORREF(0), clamped, LWA_ALPHA);
}

/// Brings [hwnd] to the front without activating it.
void bringToFrontForHwnd(HWND hwnd) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  SetWindowPos(
    hwnd,
    HWND_TOP,
    0,
    0,
    0,
    0,
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE,
  );
}

/// Re-applies [WS_EX_NOACTIVATE] after optional DWM / ex-style tweaks.
///
/// Flutter tooltip/popup HWNDs are created with this flag; losing it lets
/// satellites steal foreground and triggers popup auto-close ([WM_ACTIVATE]).
void preserveNoActivateForHwnd(HWND hwnd) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
    return;
  }

  var exStyle = GetWindowLongPtr(hwnd, GWL_EXSTYLE).value;
  exStyle |= WS_EX_NOACTIVATE;
  SetWindowLongPtr(hwnd, GWL_EXSTYLE, exStyle);
  SetWindowPos(
    hwnd,
    null,
    0,
    0,
    0,
    0,
    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
  );
}
