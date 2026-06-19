// Standalone repro entry point — upstream example/lib/main.dart is unchanged.
//
// Secondary dialog window content appears stretched on Windows when spawned
// from a frameless transparent main window. Win32 setup is inlined in
// win32_stretch_repro.dart (no package/lib changes required).
//
// Run: fvm flutter run -d windows lib/main_stretch_repro.dart
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart';
import 'package:window_toolbox/window_toolbox.dart';
import 'package:window_toolbox_example/win32_stretch_repro.dart';

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

  @override
  void initState() {
    super.initState();
    _main = RegularWindowController(
      preferredSize: const Size(400, 300),
      title: 'Stretch Repro',
      delegate: _MainDelegate(),
    );
    _main.enableCustomWindow();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_main is WindowControllerWin32) {
        configureMainWindowFrameless(_main as WindowControllerWin32);
      }
    });
  }

  @override
  void dispose() {
    _main.dispose();
    super.dispose();
  }

  void _showDialog(WindowRegistry registry) {
    late final WindowEntry entry;
    final controller = DialogWindowController(
      preferredSize: const Size(224, 160),
      title: 'Dialog',
      delegate: _DialogDelegate(
        onDestroyed: () => registry.unregister(entry),
      ),
    );
    entry = WindowEntry(
      controller: controller,
      builder: (context) => const _DialogView(),
    );
    registry.register(entry);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller is WindowControllerWin32) {
        final win32 = controller as WindowControllerWin32;
        configureDialogAsToolWindow(win32);
        Future.microtask(() => applyDialogFrame(win32));
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: _main,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (_, child) => ColoredBox(
          color: Colors.transparent,
          child: child,
        ),
        home: Scaffold(
          backgroundColor: Colors.transparent,
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
                    child: ElevatedButton(
                      onPressed: () => _showDialog(WindowRegistry.of(context)),
                      child: const Text('Show Dialog'),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
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

class _DialogView extends StatelessWidget {
  const _DialogView();

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Container(
        color: const Color(0xFF2D2D2D),
        alignment: Alignment.center,
        child: const Text(
          '224×160',
          style: TextStyle(color: Colors.white, fontSize: 24),
        ),
      ),
    );
  }
}
