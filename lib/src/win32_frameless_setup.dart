import 'dart:ui' show Rect;



import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;

import 'package:flutter/widgets.dart' show WidgetsBinding;



import 'package:win32/win32.dart';



import 'win32_util.dart';



/// Schedules deferred Win32 frameless setup for [controller].

///

/// Merges repeated calls before the deferred run. [CustomWindowWin32]

/// schedules size correction on construction; [configureFramelessWindow] merges

/// optional [frame] and [transparentBackdrop] into the same deferred run.

void scheduleWin32FramelessSetup(

  WindowControllerWin32 controller, {

  Rect? frame,

  bool transparentBackdrop = false,

}) {

  final state = _framelessSetupState[controller] ??=

      _Win32FramelessSetupState();



  if (frame != null) {

    state.frame = frame;

  }

  if (transparentBackdrop) {

    state.transparentBackdrop = true;

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



final _framelessSetupState = Expando<_Win32FramelessSetupState>(

  'Win32FramelessSetup',

);



class _Win32FramelessSetupState {

  bool applyScheduled = false;

  Rect? frame;

  bool transparentBackdrop = false;

}



void _applyWin32FramelessSetup(

  WindowControllerWin32 controller,

  _Win32FramelessSetupState state,

) {

  final hwnd = HWND(controller.windowHandle);



  compensateFramelessContentSizeForHwnd(hwnd);



  final frame = state.frame;

  if (frame != null) {

    setWindowFrameForHwnd(hwnd, frame);

  }



  refreshWindowSizeForHwnd(hwnd);



  if (state.transparentBackdrop) {

    enableTransparentBackdropForHwnd(hwnd);

  }

}


