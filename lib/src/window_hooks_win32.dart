import 'dart:ffi' as ffi;

import 'package:win32/win32.dart';

import 'window_hooks.dart';
import 'win32_window_ops.dart';

/// Windows-specific global hooks (WinEvent, single-instance).
class Win32WindowHooks {
  Win32WindowHooks();

  void Function(WindowHookEvent event)? _windowCallback;
  void Function(
    ffi.Pointer<ffi.Void> windowHandle,
    int newDpi,
    double scaleFactor,
  )?
  _dpiCallback;

  void init(
    void Function(WindowHookEvent event) windowCallback, {
    void Function(
      ffi.Pointer<ffi.Void> windowHandle,
      int newDpi,
      double scaleFactor,
    )?
    onDpiChanged,
  }) {
    _windowCallback = windowCallback;
    _dpiCallback = onDpiChanged;
  }

  void dispose() {
    _windowCallback = null;
    _dpiCallback = null;
  }

  int checkSingleInstance(String windowMarker) =>
      Win32WindowOps.checkSingleInstance(windowMarker);

  int setWindowMarker(ffi.Pointer<ffi.Void> windowHandle, String marker) =>
      Win32WindowOps.setWindowMarker(HWND(windowHandle), marker);

  int removeWindowMarker(ffi.Pointer<ffi.Void> windowHandle, String marker) =>
      Win32WindowOps.removeWindowMarker(HWND(windowHandle), marker);

  bool showItemInFolder(String filePath) =>
      Win32WindowOps.showItemInFolder(filePath);
}
