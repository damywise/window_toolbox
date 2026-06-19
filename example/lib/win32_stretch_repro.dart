// Win32 helpers inlined for the stretch repro. Keeps the example self-contained
// so it runs on upstream window_toolbox without any package/lib changes.
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';
import 'package:window_toolbox/window_toolbox.dart';

const _wcaAccentPolicy = 19;
const _accentEnableTransparentGradient = 2;

final _user32 = DynamicLibrary.open('user32.dll');
final _setWindowCompositionAttribute = _user32.lookupFunction<
  Int32 Function(Pointer, Pointer),
  int Function(Pointer, Pointer)
>('SetWindowCompositionAttribute');

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

  @Size()
  external int cbData;
}

final _configuredDialogs = <int>{};

void _enableTransparentGradient(HWND hwnd) {
  final accent = calloc<_AccentPolicy>();
  accent.ref.accentState = _accentEnableTransparentGradient;
  accent.ref.accentFlags = 2;
  accent.ref.gradientColor = 0;
  accent.ref.animationId = 0;

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

void _extendFrameIntoClientArea(HWND hwnd) {
  final margins = calloc<MARGINS>();
  margins.ref.cxLeftWidth = -1;
  margins.ref.cxRightWidth = -1;
  margins.ref.cyTopHeight = -1;
  margins.ref.cyBottomHeight = -1;
  DwmExtendFrameIntoClientArea(hwnd, margins);
  calloc.free(margins);
}

/// Matches the main-window setup from the fork's `setAsFrameless()`.
void configureMainWindowFrameless(WindowControllerWin32 controller) {
  if (controller.windowHandle.address == 0) return;
  final hwnd = HWND(controller.windowHandle);

  final rect = calloc<RECT>();
  GetWindowRect(hwnd, rect);
  SetWindowPos(
    hwnd,
    null,
    rect.ref.left,
    rect.ref.top,
    rect.ref.right - rect.ref.left,
    rect.ref.bottom - rect.ref.top,
    SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_NOACTIVATE | SWP_FRAMECHANGED,
  );
  calloc.free(rect);

  _extendFrameIntoClientArea(hwnd);
  _enableTransparentGradient(hwnd);
}

/// Matches the fork's `configureAsToolDialog()`.
void configureDialogAsToolWindow(WindowControllerWin32 controller) {
  if (controller.windowHandle.address == 0) return;
  final hwnd = HWND(controller.windowHandle);

  if (_configuredDialogs.add(hwnd.address)) {
    WindowControllerWin32Extension(controller).addWindowsMessageHandler(
      (windowHandle, message, wParam, lParam) {
        if (message == WM_NCCALCSIZE && wParam == 1) {
          return 0;
        }
        if (message == WM_NCACTIVATE) {
          return DefWindowProc(
            windowHandle,
            WM_NCACTIVATE,
            WPARAM(wParam),
            LPARAM(-1),
          );
        }
        if (message == WM_DESTROY) {
          _configuredDialogs.remove(windowHandle.address);
        }
        return null;
      },
    );
  }

  final style = GetWindowLongPtr(hwnd, GWL_STYLE).value;
  final newStyle =
      (style & ~WS_CAPTION & ~WS_SYSMENU) |
      WS_THICKFRAME |
      WS_CLIPCHILDREN |
      WS_CLIPSIBLINGS;
  SetWindowLongPtr(hwnd, GWL_STYLE, newStyle);
}

/// Matches the fork's `applyDialogFrame()`. Call outside a frame callback.
void applyDialogFrame(WindowControllerWin32 controller) {
  if (controller.windowHandle.address == 0) return;
  final hwnd = HWND(controller.windowHandle);

  _extendFrameIntoClientArea(hwnd);
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
