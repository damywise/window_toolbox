import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'macos.g.dart' as macos;
import 'window_hooks_win32.dart';

/// Window lifecycle event types.
enum WindowHookEventType {
  created(0),
  destroyed(1),
  moved(2),
  resized(3),
  hidden(6),
  activated(8),
  deactivated(9);

  const WindowHookEventType(this.value);
  final int value;

  static WindowHookEventType? fromValue(int value) {
    for (final type in values) {
      if (type.value == value) {
        return type;
      }
    }
    return null;
  }
}

/// Event payload for window lifecycle hooks.
class WindowHookEvent {
  const WindowHookEvent({
    required this.type,
    required this.windowHandle,
    required this.title,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final WindowHookEventType type;
  final ffi.Pointer<ffi.Void> windowHandle;
  final String title;
  final double x;
  final double y;
  final double width;
  final double height;
}

typedef WindowHookCallback = void Function(WindowHookEvent event);
typedef TrayHookCallback = void Function(int type, int menuItemId);

typedef _CwWindowEventCallbackNative =
    ffi.Void Function(
      ffi.Int32 eventType,
      ffi.Pointer<ffi.Void> windowHandle,
      ffi.Pointer<ffi.Char> title,
      ffi.Double x,
      ffi.Double y,
      ffi.Double width,
      ffi.Double height,
      ffi.Pointer<ffi.Void> context,
    );

/// Global window hooks (init, tray, single-instance, lifecycle callbacks).
class WindowHooks {
  WindowHooks._();

  static final WindowHooks instance = WindowHooks._();

  bool _initialized = false;
  ffi.NativeCallable<_CwWindowEventCallbackNative>? _nativeCallback;
  final Win32WindowHooks _win32 = Win32WindowHooks();

  void Function(WindowHookEvent)? onWindowDestroyed;
  void Function(WindowHookEvent)? onWindowMoved;
  void Function(WindowHookEvent)? onWindowResized;
  void Function(WindowHookEvent)? onWindowHidden;
  void Function(WindowHookEvent)? onWindowActivated;
  void Function(WindowHookEvent)? onWindowDeactivated;
  void Function(
    ffi.Pointer<ffi.Void> windowHandle,
    int newDpi,
    double scaleFactor,
  )?
  onDpiChanged;
  TrayHookCallback? onTrayEvent;

  void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;

    if (Platform.isMacOS) {
      macos.cw_hooks_init();
      _nativeCallback =
          ffi.NativeCallable<_CwWindowEventCallbackNative>.isolateLocal(
            _handleMacOSEvent,
          );
      macos.cw_hooks_set_window_event_callback(
        _nativeCallback!.nativeFunction,
        ffi.Pointer<ffi.Void>.fromAddress(0),
      );
    }

    if (Platform.isWindows) {
      _win32.init(_dispatchWindowEvent, onDpiChanged: onDpiChanged);
    }
  }

  void dispose() {
    if (!_initialized) {
      return;
    }
    if (Platform.isMacOS) {
      macos.cw_hooks_set_window_event_callback(
        ffi.Pointer.fromAddress(0),
        ffi.Pointer<ffi.Void>.fromAddress(0),
      );
      _nativeCallback?.close();
      _nativeCallback = null;
      macos.cw_hooks_dispose();
    }
    if (Platform.isWindows) {
      _win32.dispose();
    }
    _initialized = false;
  }

  void _handleMacOSEvent(
    int eventType,
    ffi.Pointer<ffi.Void> windowHandle,
    ffi.Pointer<ffi.Char> title,
    double x,
    double y,
    double width,
    double height,
    ffi.Pointer<ffi.Void> context,
  ) {
    final type = WindowHookEventType.fromValue(eventType);
    if (type == null) {
      return;
    }
    final event = WindowHookEvent(
      type: type,
      windowHandle: windowHandle,
      title: _decodeMacOSTitle(title),
      x: x,
      y: y,
      width: width,
      height: height,
    );
    _dispatchWindowEvent(event);
  }

  String _decodeMacOSTitle(ffi.Pointer<ffi.Char> title) {
    if (title == ffi.nullptr) {
      return '';
    }
    try {
      return title.cast<Utf8>().toDartString();
    } on Object {
      // Native passes a transient strdup() buffer; tolerate races gracefully.
      return '';
    }
  }

  void _dispatchWindowEvent(WindowHookEvent event) {
    switch (event.type) {
      case WindowHookEventType.destroyed:
        onWindowDestroyed?.call(event);
      case WindowHookEventType.moved:
        onWindowMoved?.call(event);
      case WindowHookEventType.resized:
        onWindowResized?.call(event);
      case WindowHookEventType.hidden:
        onWindowHidden?.call(event);
      case WindowHookEventType.activated:
        onWindowActivated?.call(event);
      case WindowHookEventType.deactivated:
        onWindowDeactivated?.call(event);
      case WindowHookEventType.created:
        break;
    }
  }

  int checkSingleInstance(String windowMarker) {
    if (!Platform.isWindows) {
      return -1;
    }
    return _win32.checkSingleInstance(windowMarker);
  }

  int setWindowMarker(ffi.Pointer<ffi.Void> windowHandle, String marker) {
    if (!Platform.isWindows) {
      return -1;
    }
    return _win32.setWindowMarker(windowHandle, marker);
  }

  int removeWindowMarker(ffi.Pointer<ffi.Void> windowHandle, String marker) {
    if (!Platform.isWindows) {
      return -1;
    }
    return _win32.removeWindowMarker(windowHandle, marker);
  }

  bool showItemInFolder(String filePath) {
    if (Platform.isMacOS) {
      return _showItemInFolderMacOS(filePath);
    }
    if (Platform.isWindows) {
      return _win32.showItemInFolder(filePath);
    }
    return false;
  }

  bool _showItemInFolderMacOS(String filePath) {
    // NSWorkspace.activateFileViewerSelecting — implemented via Process for now.
    try {
      final result = Process.runSync('open', ['-R', filePath]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
}
