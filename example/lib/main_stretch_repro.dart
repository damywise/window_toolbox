// Standalone repro entry point — upstream example/lib/main.dart is unchanged.
//
// Run: fvm flutter run -d windows lib/main_stretch_repro.dart
//
// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart' hide CloseButton;
import 'package:flutter/src/widgets/_window.dart';
import 'package:window_toolbox/window_toolbox.dart';

void main() {
  runWidget(const StretchRepro());
}

class StretchRepro extends StatefulWidget {
  const StretchRepro({super.key});

  @override
  State<StretchRepro> createState() => _StretchReproState();
}

class _StretchReproState extends State<StretchRepro> {
  late final RegularWindowController _main;

  ui.Display get _display => ui.PlatformDispatcher.instance.displays.first;

  double get _dpr => _display.devicePixelRatio;

  @override
  void initState() {
    super.initState();
    _main = RegularWindowController(
      preferredSize: const Size(400, 300),
      title: 'Stretch Repro',
      delegate: _MainDelegate(),
    );
    _main.enableCustomWindow();
    _main.finishFramelessSetup();
  }

  @override
  void dispose() {
    _main.dispose();
    super.dispose();
  }

  void _showDialog(WindowRegistry registry) {
    const contentSize = Size(224, 160);
    late final WindowEntry entry;
    final controller = DialogWindowController(
      preferredSize: contentSize,
      title: 'Dialog',
      delegate: _DialogDelegate(
        onDestroyed: () => registry.unregister(entry),
      ),
    );
    entry = WindowEntry(
      controller: controller,
      builder: (context) => const _DialogView(),
    );
    _openFramelessWindow(registry, entry, transparentBackdrop: true);
  }

  void _showFullScreenSizedWindow(WindowRegistry registry) {
    final contentSize = ui.Size(
      _display.size.width / _dpr,
      _display.size.height / _dpr,
    );
    late final WindowEntry entry;
    final controller = RegularWindowController(
      preferredSize: contentSize,
      title: 'Full Screen',
      delegate: _FullScreenDelegate(
        onDestroyed: () => registry.unregister(entry),
      ),
    );
    entry = WindowEntry(
      controller: controller,
      builder: (context) => const _FullScreenView(),
    );
    _openFramelessWindow(
      registry,
      entry,
      frame: ui.Rect.fromLTWH(0, 0, _display.size.width, _display.size.height),
      transparentBackdrop: true,
    );
  }

  void _openFramelessWindow(
    WindowRegistry registry,
    WindowEntry entry, {
    ui.Rect? frame,
    bool transparentBackdrop = false,
  }) {
    entry.controller.enableCustomWindow();
    registry.register(entry);
    entry.controller.finishFramelessSetup(
      frame: frame,
      transparentBackdrop: transparentBackdrop,
    );
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: _main,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: LayoutBuilder(
          builder: (context, constraints) {
            return Scaffold(
              body: Column(
                children: [
                  WindowDragArea(
                    child: Container(
                      height: 32,
                      color: Colors.grey.shade400,
                      alignment: Alignment.center,
                      child: const Text('Stretch Repro'),
                    ),
                  ),
                  Expanded(
                    child: ColoredBox(
                      color: Colors.white,
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 12,
                          children: [
                            _SizeLabel.fromConstraints(
                              constraints,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w500,
                                color: Colors.black87,
                              ),
                            ),
                            Builder(
                              builder: (context) => ElevatedButton(
                                onPressed: () =>
                                    _showDialog(WindowRegistry.of(context)),
                                child: const Text('Show Dialog'),
                              ),
                            ),
                            Builder(
                              builder: (context) => ElevatedButton(
                                onPressed: () => _showFullScreenSizedWindow(
                                  WindowRegistry.of(context),
                                ),
                                child: const Text('Show Full Screen Window'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _SizeLabel extends StatelessWidget {
  const _SizeLabel._({required this.constraints, required this.style});

  factory _SizeLabel.fromConstraints(
    BoxConstraints constraints, {
    required TextStyle style,
  }) {
    return _SizeLabel._(constraints: constraints, style: style);
  }

  final BoxConstraints constraints;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Text(
      '${constraints.maxWidth.toStringAsFixed(0)}×'
      '${constraints.maxHeight.toStringAsFixed(0)}',
      style: style,
    );
  }
}

class _MainDelegate with RegularWindowControllerDelegate {
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    exit(0);
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

class _FullScreenDelegate with RegularWindowControllerDelegate {
  _FullScreenDelegate({required this.onDestroyed});

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class _DialogView extends StatelessWidget {
  const _DialogView();

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Container(
            decoration: BoxDecoration(
              color: const Color(0xE62D2D2D),
              border: Border.all(color: Colors.white24),
            ),
            alignment: Alignment.center,
            child: _SizeLabel.fromConstraints(
              constraints,
              style: const TextStyle(color: Colors.white, fontSize: 24),
            ),
          );
        },
      ),
    );
  }
}

class _FullScreenView extends StatelessWidget {
  const _FullScreenView();

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Column(
        children: [
          WindowDragArea(
            child: Container(
              height: 40,
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Full Screen Window',
                      style: TextStyle(color: Colors.white),
                    ),
                  ),
                  CloseButton(
                    builder: (context, state) => Icon(
                      Icons.close,
                      color: state.hovered ? Colors.white : Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: ColoredBox(
              color: const Color(0x660000FF),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return Center(
                    child: _SizeLabel.fromConstraints(
                      constraints,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
