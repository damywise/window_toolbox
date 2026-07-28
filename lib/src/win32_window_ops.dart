import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Win32 window operations ported from window_lifecycle.
class Win32WindowOps {
  Win32WindowOps._();

  static bool isWindowAbove(HWND hwndA, HWND hwndB) {
    if (hwndA.isNull || hwndB.isNull || !IsWindow(hwndA) || !IsWindow(hwndB)) {
      return false;
    }
    if (hwndA == hwndB) {
      return false;
    }

    var above = GetWindow(hwndB, GW_HWNDPREV).value;
    while (!above.isNull) {
      if (above == hwndA) {
        return true;
      }
      above = GetWindow(above, GW_HWNDPREV).value;
    }
    return false;
  }

  static bool setCaptureExclusion(HWND hwnd, bool exclude) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return false;
    }
    return SetWindowDisplayAffinity(
          hwnd,
          exclude ? WDA_EXCLUDEFROMCAPTURE : WDA_NONE,
        ) !=
        0;
  }

  static void forceRedraw(HWND hwnd) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return;
    }
    InvalidateRect(hwnd, null, true);
    UpdateWindow(hwnd);
  }

  static void startDrag(HWND hwnd) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return;
    }
    ReleaseCapture();
    SendMessage(hwnd, WM_NCLBUTTONDOWN, WPARAM(HTCAPTION), LPARAM(0));
  }

  static bool showItemInFolder(String filePath) {
    if (!Platform.isWindows) {
      return false;
    }
    try {
      final result = Process.runSync(
        'explorer.exe',
        ['/select,', filePath],
        runInShell: true,
      );
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }

  static int checkSingleInstance(String windowMarker) {
    final markerPtr = windowMarker.toNativeUtf16();
    try {
      final existing = FindWindowEx(
        null,
        null,
        null,
        PCWSTR(markerPtr),
      ).value;
      if (!existing.isNull) {
        if (IsIconic(existing)) {
          ShowWindow(existing, SW_RESTORE);
        }
        SetForegroundWindow(existing);
        return 1;
      }
      return 0;
    } finally {
      calloc.free(markerPtr);
    }
  }

  static int setWindowMarker(HWND hwnd, String marker) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return -1;
    }
    final markerPtr = marker.toNativeUtf16();
    try {
      return SetProp(hwnd, PCWSTR(markerPtr), HANDLE(hwnd)).value ? 0 : -1;
    } finally {
      calloc.free(markerPtr);
    }
  }

  static int removeWindowMarker(HWND hwnd, String marker) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return -1;
    }
    final markerPtr = marker.toNativeUtf16();
    try {
      return RemoveProp(hwnd, PCWSTR(markerPtr)).error.isError ? -1 : 0;
    } finally {
      calloc.free(markerPtr);
    }
  }

  static void destroyWindow(HWND hwnd) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return;
    }
    DestroyWindow(hwnd);
  }

  static void makeActive(HWND hwnd) {
    if (hwnd.isNull || !IsWindow(hwnd)) {
      return;
    }
    if (IsIconic(hwnd)) {
      ShowWindow(hwnd, SW_RESTORE);
    }
    SetForegroundWindow(hwnd);
  }
}
