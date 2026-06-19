// Win32 tool-dialog helpers inlined for the stretch repro.
// Keeps the example self-contained on upstream window_toolbox (no lib/ changes).
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';
import 'package:window_toolbox/window_toolbox.dart';

final _configuredDialogs = <int>{};

void _extendFrameIntoClientArea(HWND hwnd) {
  final margins = calloc<MARGINS>();
  margins.ref.cxLeftWidth = -1;
  margins.ref.cxRightWidth = -1;
  margins.ref.cyTopHeight = -1;
  margins.ref.cyBottomHeight = -1;
  DwmExtendFrameIntoClientArea(hwnd, margins);
  calloc.free(margins);
}

/// Titleless dialog with visible frame border (WM_NCCALCSIZE → 0, no caption).
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

/// Applies pending style changes. Call outside a frame callback.
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
