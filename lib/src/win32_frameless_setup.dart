import 'dart:ffi';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:win32/win32.dart';

/// Resizes [hwnd] to the content size Flutter intended before frameless
/// [WM_NCCALCSIZE] handling expanded the client area to the full frame.
///
/// Flutter sizes the window frame with AdjustWindowRectExForDpi, which is
/// unaware of custom non-client handling. Querying WM_NCCALCSIZE with
/// wParam == 0 yields the standard client rect for the current frame.
void compensateFramelessContentSizeForHwnd(HWND hwnd) {
  final frameRect = calloc<RECT>();
  try {
    GetWindowRect(hwnd, frameRect);

    final clientRect = calloc<RECT>();
    try {
      clientRect.ref = frameRect.ref;

      SendMessage(hwnd, WM_NCCALCSIZE, WPARAM(0), LPARAM(clientRect.address));
      final clientW = clientRect.ref.right - clientRect.ref.left;
      final clientH = clientRect.ref.bottom - clientRect.ref.top;

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
    } finally {
      calloc.free(clientRect);
    }
  } finally {
    calloc.free(frameRect);
  }
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
  try {
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
  } finally {
    calloc.free(rect);
  }
}

// -- DWM transparent backdrop --

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
/// frameless WM_NCCALCSIZE handling and restores visible non-client chrome.
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

// -- Deferred frameless setup scheduler --

/// Schedules deferred Win32 frameless setup for [controller].
///
/// Merges repeated calls before the first deferred run. [CustomWindowWin32]
/// schedules size correction on construction; [CustomWindow.configureFramelessWindow]
/// merges optional [frame] and [transparentBackdrop] into the same deferred
/// run. Pass [compensateSize] to shrink the window after frameless
/// [WM_NCCALCSIZE] removes the non-client area.
///
/// Timing: post-frame callback, then microtask — avoids Win32 subclass procs
/// re-entering the Flutter scheduler mid-draw.
void scheduleWin32FramelessSetup(
  WindowControllerWin32 controller, {
  Rect? frame,
  bool transparentBackdrop = false,
  bool compensateSize = false,
}) {
  final state = _framelessSetupState[controller] ??=
      _Win32FramelessSetupPending();

  if (frame != null) {
    state.frame = frame;
  }
  if (transparentBackdrop) {
    state.transparentBackdrop = true;
  }
  if (compensateSize) {
    state.compensateSize = true;
  }

  if (state.applyScheduled) {
    return;
  }
  state.applyScheduled = true;

  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future.microtask(() {
      state.applyScheduled = false;
      _applyWin32FramelessSetup(controller, state);
    });
  });
}

final _framelessSetupState = Expando<_Win32FramelessSetupPending>(
  'Win32FramelessSetup',
);

class _Win32FramelessSetupPending {
  bool applyScheduled = false;
  bool compensateSize = false;
  Rect? frame;
  bool transparentBackdrop = false;
}

void _applyWin32FramelessSetup(
  WindowControllerWin32 controller,
  _Win32FramelessSetupPending state,
) {
  final hwnd = HWND(controller.windowHandle);

  bool didSetGeometry = false;

  if (state.compensateSize) {
    compensateFramelessContentSizeForHwnd(hwnd);
    didSetGeometry = true;
    state.compensateSize = false;
  }

  if (state.frame != null) {
    setWindowFrameForHwnd(hwnd, state.frame!);
    didSetGeometry = true;
    state.frame = null;
  }

  if (didSetGeometry) {
    refreshWindowSizeForHwnd(hwnd);
  }

  if (state.transparentBackdrop) {
    enableTransparentBackdropForHwnd(hwnd);
    state.transparentBackdrop = false;
  }
}
