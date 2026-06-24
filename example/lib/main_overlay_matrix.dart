// Side-by-side overlay transparency / passthrough matrix (Windows).
//
// Run: fvm flutter run -d windows lib/main_overlay_matrix.dart
//
// Spawns 8 non-overlapping cells on the primary display. Each cell uses a
// different Win32 setup so you can compare rendering vs click-through at once.
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';
import 'package:window_toolbox/src/win32_frameless_setup.dart';
import 'package:window_toolbox/src/win32_mouse_passthrough.dart';
import 'package:window_toolbox/window_toolbox.dart';

import 'overlay_geometry.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runWidget(const OverlayMatrixApp());
}

/// One test cell: distinct color + label + native setup.
class _VariantSpec {
  const _VariantSpec({
    required this.id,
    required this.title,
    required this.technique,
    required this.tint,
    required this.apply,
  });

  final String id;
  final String title;
  final String technique;
  final Color tint;
  final void Function(RegularWindowController controller, ui.Rect physicalFrame)
  apply;
}

void _afterToolboxSetup(WindowControllerWin32 controller, void Function(HWND) fn) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      fn(HWND(controller.windowHandle));
    });
  });
}

final _variants = <_VariantSpec>[
  _VariantSpec(
    id: 'A',
    title: 'Accent DWM only',
    technique: 'enableCustomWindow(transparentBackdrop: true)',
    tint: const Color(0x99FF0000),
    apply: (c, frame) {
      c.enableCustomWindow(frame: frame, transparentBackdrop: true);
    },
  ),
  _VariantSpec(
    id: 'B',
    title: 'Accent + layered passthrough',
    technique: 'transparentBackdrop + mousePassthrough (deferred WS_EX_LAYERED)',
    tint: const Color(0x990000FF),
    apply: (c, frame) {
      c.enableCustomWindow(
        frame: frame,
        transparentBackdrop: true,
        mousePassthrough: true,
      );
    },
  ),
  _VariantSpec(
    id: 'C',
    title: 'Lifecycle DWM only',
    technique: 'enableLifecycleTransparentEffectForHwnd (manual post-frame)',
    tint: const Color(0x9900AA00),
    apply: (c, frame) {
      c.enableCustomWindow(frame: frame);
      if (Platform.isWindows) {
        _afterToolboxSetup(c as WindowControllerWin32, enableLifecycleTransparentEffectForHwnd);
      }
    },
  ),
  _VariantSpec(
    id: 'D',
    title: 'Lifecycle + DWM passthrough',
    technique: 'lifecycle effect + applyDwmCompatibleMousePassthroughForWindow',
    tint: const Color(0x9900AAAA),
    apply: (c, frame) {
      c.enableCustomWindow(frame: frame);
      if (Platform.isWindows) {
        final win32 = c as WindowControllerWin32;
        _afterToolboxSetup(win32, (hwnd) {
          enableLifecycleTransparentEffectForHwnd(hwnd);
          applyDwmCompatibleMousePassthroughForWindow(hwnd, true);
        });
      }
    },
  ),
  _VariantSpec(
    id: 'E',
    title: 'Accent + layered passthrough',
    technique: 'accent DWM + setIgnoresMouseEventsForHwnd (WS_EX_LAYERED)',
    tint: const Color(0x99AA00AA),
    apply: (c, frame) {
      c.enableCustomWindow(frame: frame, transparentBackdrop: true);
      if (Platform.isWindows) {
        _afterToolboxSetup(c as WindowControllerWin32, (hwnd) {
          setIgnoresMouseEventsForHwnd(hwnd, true);
        });
      }
    },
  ),
  _VariantSpec(
    id: 'F',
    title: 'Lifecycle + layered passthrough',
    technique: 'lifecycle effect + setIgnoresMouseEventsForHwnd',
    tint: const Color(0x99FF8800),
    apply: (c, frame) {
      c.enableCustomWindow(frame: frame);
      if (Platform.isWindows) {
        _afterToolboxSetup(c as WindowControllerWin32, (hwnd) {
          enableLifecycleTransparentEffectForHwnd(hwnd);
          setIgnoresMouseEventsForHwnd(hwnd, true);
        });
      }
    },
  ),
  _VariantSpec(
    id: 'G',
    title: 'Drawing overlay profile',
    technique: 'accent DWM + deferred layered passthrough (mousePassthrough)',
    tint: const Color(0x9900CCFF),
    apply: (c, frame) {
      c.enableCustomWindow(
        frame: frame,
        transparentBackdrop: true,
        mousePassthrough: true,
        hideFromSwitcher: true,
        alwaysOnTop: true,
        fullscreenCompatibleTopmost: true,
      );
    },
  ),
  _VariantSpec(
    id: 'H',
    title: 'Frameless only (tooltip path)',
    technique: 'configureFramelessWindow(transparentBackdrop) — no enableCustomWindow',
    tint: const Color(0x99FF66AA),
    apply: (c, frame) {
      c.configureFramelessWindow(
        frame: frame,
        transparentBackdrop: true,
      );
    },
  ),
];

class OverlayMatrixApp extends StatefulWidget {
  const OverlayMatrixApp({super.key});

  @override
  State<OverlayMatrixApp> createState() => _OverlayMatrixAppState();
}

class _OverlayMatrixAppState extends State<OverlayMatrixApp> {
  late final RegularWindowController _panel;
  final List<WindowEntry> _entries = [];

  @override
  void initState() {
    super.initState();
    _panel = RegularWindowController(
      preferredSize: const ui.Size(520, 640),
      title: 'Overlay matrix',
      delegate: _PanelDelegate(),
    );
    _panel.enableCustomWindow();
  }

  @override
  void dispose() {
    _destroyAll();
    _panel.dispose();
    super.dispose();
  }

  ui.Display get _display => ui.PlatformDispatcher.instance.displays.first;

  /// Variants that passed quadrant / passthrough tests.
  static const _workingVariantIds = {'A', 'B', 'E', 'F', 'G'};

  void _spawnVariant(
    WindowRegistry registry,
    _VariantSpec spec, {
    required ui.Rect physicalFrame,
    required ui.Size logicalSize,
  }) {
    late final WindowEntry entry;
    final controller = RegularWindowController(
      preferredSize: logicalSize,
      title: '${spec.id}: ${spec.title}',
      delegate: _VariantDelegate(
        onDestroyed: () {
          registry.unregister(entry);
          _entries.remove(entry);
          if (mounted) setState(() {});
        },
      ),
    );

    entry = WindowEntry(
      controller: controller,
      builder: (_) => _VariantView(spec: spec),
    );

    registry.register(entry);
    spec.apply(controller, physicalFrame);
    _entries.add(entry);
  }

  void _spawnAll(WindowRegistry registry) {
    if (!Platform.isWindows) return;
    _destroyAll();

    const cols = 2;
    const rows = 4;

    for (var i = 0; i < _variants.length; i++) {
      final spec = _variants[i];
      final col = i % cols;
      final row = i ~/ cols;
      final cell = matrixQuadrantCell(
        display: _display,
        column: col,
        row: row,
        columns: cols,
        rows: rows,
      );
      _spawnVariant(
        registry,
        spec,
        physicalFrame: cell.physicalFrame,
        logicalSize: cell.logicalSize,
      );
    }

    setState(() {});
  }

  void _spawnFullscreen(WindowRegistry registry, _VariantSpec spec) {
    if (!Platform.isWindows) return;
    _destroyAll();
    _spawnVariant(
      registry,
      spec,
      physicalFrame: nearFullscreenPhysicalFrame(_display),
      logicalSize: fullscreenLogicalSize(_display),
    );
    setState(() {});
  }

  void _spawnAllWorkingFullscreen(WindowRegistry registry) {
    if (!Platform.isWindows) return;
    _destroyAll();
    final logicalSize = fullscreenLogicalSize(_display);
    for (final spec in _variants) {
      if (!_workingVariantIds.contains(spec.id)) continue;
      _spawnVariant(
        registry,
        spec,
        physicalFrame: nearFullscreenPhysicalFrame(_display),
        logicalSize: logicalSize,
      );
    }
    setState(() {});
  }

  void _destroyAll() {
    for (final entry in _entries.toList()) {
      try {
        entry.controller.destroy();
      } on StateError {
        // Already destroyed.
      }
    }
    _entries.clear();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: _panel,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  WindowDragArea(
                    child: Container(
                      height: 36,
                      color: Colors.grey.shade300,
                      alignment: Alignment.center,
                      child: const Text(
                        'Overlay matrix — control panel',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ),
                  Expanded(
                    child: ListView(
                      padding: const EdgeInsets.all(12),
                      children: [
                        const Text(
                          'Each variant opens in its own screen quadrant (2×4 grid). '
                          'You should see a tinted panel with a large letter ID. '
                          'Click through each cell to test passthrough.',
                          style: TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 12),
                        if (!Platform.isWindows)
                          const Text(
                            'Windows only — spawn is a no-op on other platforms.',
                            style: TextStyle(color: Colors.red),
                          ),
                        FilledButton(
                          onPressed: Platform.isWindows
                              ? () => _spawnAll(WindowRegistry.of(context))
                              : null,
                          child: const Text('Spawn all 8 variants'),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Fullscreen spawn',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Uses display width minus 1 physical pixel — exact '
                          'fullscreen breaks DWM.',
                          style: TextStyle(fontSize: 13),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final spec in _variants)
                              if (_workingVariantIds.contains(spec.id))
                                OutlinedButton(
                                  onPressed: Platform.isWindows
                                      ? () => _spawnFullscreen(
                                            WindowRegistry.of(context),
                                            spec,
                                          )
                                      : null,
                                  child: Text('${spec.id} fullscreen'),
                                ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        FilledButton.tonal(
                          onPressed: Platform.isWindows
                              ? () => _spawnAllWorkingFullscreen(
                                    WindowRegistry.of(context),
                                  )
                              : null,
                          child: const Text(
                            'Stack A+B+E+F+G fullscreen (5 layers)',
                          ),
                        ),
                        const SizedBox(height: 8),
                        OutlinedButton(
                          onPressed: _entries.isEmpty ? null : _destroyAll,
                          child: Text(
                            'Destroy variants (${_entries.length} active)',
                          ),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Legend',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        for (final spec in _variants) ...[
                          _LegendTile(spec: spec),
                          const Divider(height: 16),
                        ],
                      ],
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

class _LegendTile extends StatelessWidget {
  const _LegendTile({required this.spec});

  final _VariantSpec spec;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: spec.tint,
            border: Border.all(color: Colors.black26),
          ),
          child: Text(
            spec.id,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 18,
              color: Colors.white,
              shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                spec.title,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                spec.technique,
                style: const TextStyle(fontSize: 12, color: Colors.black54),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VariantView extends StatelessWidget {
  const _VariantView({required this.spec});

  final _VariantSpec spec;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: ColoredBox(
        color: spec.tint,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  spec.id,
                  style: const TextStyle(
                    fontSize: 72,
                    fontWeight: FontWeight.w900,
                    color: Colors.white,
                    shadows: [
                      Shadow(color: Colors.black87, blurRadius: 4),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  spec.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                    shadows: [Shadow(color: Colors.black54, blurRadius: 2)],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  spec.technique,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PanelDelegate with RegularWindowControllerDelegate {
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    exit(0);
  }
}

class _VariantDelegate with RegularWindowControllerDelegate {
  _VariantDelegate({required this.onDestroyed});

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}
