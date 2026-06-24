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

/// Port of `window_lifecycle_set_always_on_top` in ZOrderManagement.cpp.
void setAlwaysOnTopForHwnd(
  HWND hwnd,
  bool onTop, {
  bool fullscreenCompatible = true,
}) {
  if (hwnd.isNull || !IsWindow(hwnd)) {
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
