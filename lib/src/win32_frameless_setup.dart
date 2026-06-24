import 'dart:ffi';
import 'dart:ui' show Rect;

import 'package:ffi/ffi.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:win32/win32.dart';

import 'custom_window_init_options.dart';
import 'win32_mouse_passthrough.dart';
import 'win32_window_chrome.dart';

/// Resizes [hwnd] to the content size Flutter intended before frameless
/// [WM_NCCALCSIZE] handling expanded the client area to the full frame.
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

// -- DWM transparent effect (lifecycle WindowEffect::Transparent) --

const int _wcaAccentPolicy = 19;
const int _accentEnableTransparentGradient = 2;

final int Function(Pointer, Pointer) _setWindowCompositionAttribute =
    DynamicLibrary.open('user32.dll').lookupFunction<
      Int32 Function(Pointer, Pointer),
      int Function(Pointer, Pointer)
    >('SetWindowCompositionAttribute');

final int Function(int hwnd, Pointer<MARGINS> pMarInset)
_dwmExtendFrameIntoClientArea = DynamicLibrary.open('dwmapi.dll')
    .lookupFunction<
      Int32 Function(IntPtr hwnd, Pointer<MARGINS> pMarInset),
      int Function(int hwnd, Pointer<MARGINS> pMarInset)
    >('DwmExtendFrameIntoClientArea');

/// Toolbar-style transparent backdrop (accent only, no DwmExtendFrameIntoClientArea).
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

/// Lifecycle-exact transparent effect for overlay windows.
void enableLifecycleTransparentEffectForHwnd(
  HWND hwnd, {
  int gradientColor = 0,
}) {
  final margins = calloc<MARGINS>();
  try {
    margins.ref.cxLeftWidth = 0;
    margins.ref.cxRightWidth = 0;
    margins.ref.cyTopHeight = 0;
    margins.ref.cyBottomHeight = 1;
    _dwmExtendFrameIntoClientArea(hwnd.address, margins);
  } finally {
    calloc.free(margins);
  }

  final accent = calloc<_AccentPolicy>();
  accent.ref.accentState = _accentEnableTransparentGradient;
  accent.ref.accentFlags = 2;
  accent.ref.gradientColor = gradientColor;

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

void scheduleWin32FramelessSetup(
  WindowControllerWin32 controller, {
  Rect? frame,
  bool transparentBackdrop = false,
  bool compensateSize = false,
  bool mousePassthrough = false,
  bool hideFromSwitcher = false,
  bool alwaysOnTop = false,
  bool fullscreenCompatibleTopmost = true,
  bool hideUntilFirstFrame = false,
  bool revealAfterSetup = false,
  bool useLifecycleTransparentEffect = false,
}) {
  final state = _framelessSetupState[controller] ??=
      _Win32FramelessSetupPending();

  if (frame != null) {
    state.frame = frame;
  }
  if (transparentBackdrop) {
    state.transparentBackdrop = true;
  }
  if (useLifecycleTransparentEffect) {
    state.useLifecycleTransparentEffect = true;
  }
  if (compensateSize) {
    state.compensateSize = true;
  }
  if (mousePassthrough) {
    state.mousePassthrough = true;
  }
  if (hideFromSwitcher) {
    state.hideFromSwitcher = true;
  }
  if (alwaysOnTop) {
    state.alwaysOnTop = true;
    state.fullscreenCompatibleTopmost = fullscreenCompatibleTopmost;
  }
  if (hideUntilFirstFrame) {
    state.hideUntilFirstFrame = true;
  }
  if (revealAfterSetup) {
    state.revealAfterSetup = true;
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

void scheduleWin32FramelessSetupFromOptions(
  WindowControllerWin32 controller,
  CustomWindowInitOptions options, {
  bool compensateSize = false,
  bool revealAfterSetup = false,
}) {
  scheduleWin32FramelessSetup(
    controller,
    frame: options.frame,
    transparentBackdrop: options.transparentBackdrop,
    compensateSize: compensateSize && options.frame == null,
    mousePassthrough: options.mousePassthrough,
    hideFromSwitcher: options.hideFromSwitcher,
    alwaysOnTop: options.alwaysOnTop,
    fullscreenCompatibleTopmost: options.fullscreenCompatibleTopmost,
    hideUntilFirstFrame: options.hideUntilFirstFrame,
    revealAfterSetup: revealAfterSetup,
  );
}

final _framelessSetupState = Expando<_Win32FramelessSetupPending>(
  'Win32FramelessSetup',
);

class _Win32FramelessSetupPending {
  bool applyScheduled = false;
  bool compensateSize = false;
  bool transparentBackdrop = false;
  bool useLifecycleTransparentEffect = false;
  bool mousePassthrough = false;
  bool hideFromSwitcher = false;
  bool alwaysOnTop = false;
  bool fullscreenCompatibleTopmost = true;
  bool hideUntilFirstFrame = false;
  bool revealAfterSetup = false;
  Rect? frame;
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

  if (state.useLifecycleTransparentEffect) {
    enableLifecycleTransparentEffectForHwnd(hwnd);
    state.useLifecycleTransparentEffect = false;
    state.transparentBackdrop = false;
  } else if (state.transparentBackdrop) {
    enableTransparentBackdropForHwnd(hwnd);
    state.transparentBackdrop = false;
  }

  if (state.hideFromSwitcher) {
    setHideFromSwitcherForHwnd(hwnd, true);
    state.hideFromSwitcher = false;
  }

  if (state.alwaysOnTop) {
    setAlwaysOnTopForHwnd(
      hwnd,
      true,
      fullscreenCompatible: state.fullscreenCompatibleTopmost,
    );
    state.alwaysOnTop = false;
  }

  if (state.mousePassthrough) {
    state.mousePassthrough = false;
    _scheduleLayeredMousePassthrough(hwnd);
  }

  if (state.revealAfterSetup) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    });
    state.revealAfterSetup = false;
    state.hideUntilFirstFrame = false;
  }
}

/// Layered passthrough after DWM backdrop — matches overlay matrix variants E/F.
void _scheduleLayeredMousePassthrough(HWND hwnd) {
  Future<void>.delayed(const Duration(milliseconds: 150), () {
    if (!IsWindow(hwnd)) {
      return;
    }
    setIgnoresMouseEventsForHwnd(hwnd, true);
  });
}
