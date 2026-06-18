// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// ignore_for_file: invalid_use_of_internal_member
// ignore_for_file: implementation_imports

import 'dart:io';

import 'package:window_toolbox/window_toolbox.dart';
import 'package:flutter/material.dart' hide CloseButton;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:window_toolbox_example/icons.dart';

class _MainDelegate with RegularWindowControllerDelegate {
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    exit(0);
  }
}

void main() {
  runWidget(const DialogStretchDemo());
}

class DialogStretchDemo extends StatefulWidget {
  const DialogStretchDemo({super.key});

  @override
  State<DialogStretchDemo> createState() => _DialogStretchDemoState();
}

class _DialogStretchDemoState extends State<DialogStretchDemo> {
  late final RegularWindowController controller;
  late final DialogService dialogService;

  @override
  void initState() {
    super.initState();
    controller = RegularWindowController(
      preferredSize: const Size(400, 300),
      title: 'Dialog Stretch Demo',
      delegate: _MainDelegate(),
    );
    controller.enableCustomWindow();
    controller.setAsFrameless();
    dialogService = DialogService(parentController: controller);
  }

  @override
  void dispose() {
    dialogService.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: controller,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => Container(
          color: Colors.transparent,
          child: child,
        ),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: _MainWindow(controller: controller, dialogService: dialogService),
        ),
      ),
    );
  }
}

class _MainWindow extends StatelessWidget {
  const _MainWindow({required this.controller, required this.dialogService});

  final RegularWindowController controller;
  final DialogService dialogService;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.max,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _TitleBar(),
        Expanded(
          child: WindowDragArea(
            child: Container(
              color: Colors.white,
              alignment: Alignment.center,
              child: _SpawnDialogButton(dialogService: dialogService),
            ),
          ),
        ),
      ],
    );
  }
}

class _TitleBar extends StatelessWidget {
  const _TitleBar();

  @override
  Widget build(BuildContext context) {
    return WindowDragArea(
      child: Container(
        decoration: BoxDecoration(
          color: Colors.grey.shade400,
          border: Border(
            bottom: BorderSide(color: Colors.grey.shade500, width: 1),
          ),
        ),
        height: 50,
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Center(
              child: Text(
                'Dialog Stretch Demo',
                style: TextStyle(fontSize: 13),
              ),
            ),
            if (Platform.isMacOS)
              const Positioned(
                left: 20,
                top: 0,
                bottom: 0,
                child: Center(
                  child: WindowTrafficLight(
                    mode: WindowTrafficLightMode.visible,
                  ),
                ),
              ),
            if (!Platform.isMacOS)
              const Positioned(
                right: 0,
                top: 0,
                child: _WindowButtons(),
              ),
          ],
        ),
      ),
    );
  }
}

class _WindowButtons extends StatelessWidget {
  const _WindowButtons();

  @override
  Widget build(BuildContext context) {
    const buttonSize = Size(40, 34);
    return SizedBox(
      height: buttonSize.height,
      child: Row(
        children: [
          MinimizeButton(
            builder: (context, state) {
              final Color backgroundColor;
              if (state.pressed) {
                backgroundColor = Colors.white.withValues(alpha: 0.5);
              } else if (state.hovered) {
                backgroundColor = Colors.white.withValues(alpha: 0.3);
              } else {
                backgroundColor = Colors.transparent;
              }
              return Container(
                width: buttonSize.width,
                color: backgroundColor,
                alignment: Alignment.center,
                child: MinimizeIcon(color: Colors.black),
              );
            },
          ),
          MaximizeButton(
            builder: (context, state, isMaximized) {
              final Color backgroundColor;
              if (state.pressed) {
                backgroundColor = Colors.white.withValues(alpha: 0.5);
              } else if (state.hovered) {
                backgroundColor = Colors.white.withValues(alpha: 0.3);
              } else {
                backgroundColor = Colors.transparent;
              }
              return Container(
                width: buttonSize.width,
                color: backgroundColor,
                alignment: Alignment.center,
                child: isMaximized
                    ? RestoreIcon(color: Colors.black)
                    : MaximizeIcon(color: Colors.black),
              );
            },
          ),
          CloseButton(
            builder: (context, state) {
              final Color backgroundColor;
              final Color iconColor;
              if (state.pressed) {
                backgroundColor = Colors.red.shade700;
                iconColor = Colors.white;
              } else if (state.hovered) {
                backgroundColor = Colors.red;
                iconColor = Colors.white;
              } else {
                backgroundColor = Colors.transparent;
                iconColor = Colors.black;
              }
              return Container(
                width: buttonSize.width,
                color: backgroundColor,
                alignment: Alignment.center,
                child: CloseIcon(color: iconColor),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _SpawnDialogButton extends StatelessWidget {
  const _SpawnDialogButton({required this.dialogService});

  final DialogService dialogService;

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      onPressed: () {
        final registry = WindowRegistry.of(context);
        dialogService.show(registry);
      },
      child: const Text('Spawn Dialog'),
    );
  }
}

class DialogService {
  static const _dialogSize = Size(224, 160);

  final BaseWindowController parentController;

  WindowRegistry? _registry;
  DialogWindowController? _controller;
  bool _isDestroyed = false;

  DialogService({required this.parentController});

  void show(WindowRegistry registry) {
    _registry = registry;

    if (_controller != null && !_isDestroyed) {
      hide();
      return;
    }

    _createDialog();
  }

  void hide() {
    try {
      _controller?.destroy();
    } on StateError {
      // Already destroyed — no-op.
    }
    _controller = null;
    _isDestroyed = true;
  }

  void dispose() {
    hide();
  }

  void _createDialog() {
    final registry = _registry;
    if (registry == null) return;

    late final WindowEntry entry;
    final controller = DialogWindowController(
      preferredSize: _dialogSize,
      title: 'Dialog',
      delegate: _DialogDelegate(
        onDestroyed: () {
          registry.unregister(entry);
          _controller = null;
          _isDestroyed = true;
        },
      ),
    );

    entry = WindowEntry(
      controller: controller,
      builder: (BuildContext context) => const _DialogContent(),
    );
    registry.register(entry);

    _controller = controller;
    _isDestroyed = false;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isDestroyed) return;
      _configureDialogWindow();
      Future.microtask(() {
        if (_isDestroyed) return;
        _applyDialogFrame();
      });
    });
  }

  void _configureDialogWindow() {
    if (_isDestroyed || _controller == null) return;
    if (_controller is WindowControllerWin32) {
      WindowControllerWin32Extension(
        _controller as WindowControllerWin32,
      ).configureAsToolDialog();
    }
  }

  void _applyDialogFrame() {
    if (_isDestroyed || _controller == null) return;
    if (_controller is WindowControllerWin32) {
      WindowControllerWin32Extension(
        _controller as WindowControllerWin32,
      ).applyDialogFrame();
    }
  }
}

class _DialogDelegate with DialogWindowControllerDelegate {
  _DialogDelegate({required this.onDestroyed});

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class _DialogContent extends StatelessWidget {
  const _DialogContent();

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF2D2D2D),
            border: Border.all(color: Colors.white12),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.info_outline, size: 16, color: Colors.white54),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Dialog Window',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const Divider(height: 16, color: Colors.white12),
              const Text(
                'This dialog window should render at its correct size.\n\n'
                'If the view appears stretched, it indicates a Flutter bug '
                'with multi-window window sizing.',
                style: TextStyle(color: Colors.white38, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
