// Transparent floating toolbar demo with tool-option dialogs and tooltips.
//
// Run: fvm flutter run -d windows lib/main_transparent.dart
//
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart' hide CloseButton;
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/src/widgets/_window_macos.dart';
import 'package:flutter/src/widgets/_window_positioner.dart';
import 'package:flutter/src/widgets/_window_win32.dart' hide HWND;
import 'package:win32/win32.dart';
import 'package:window_toolbox/window_toolbox.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final toolbarController = RegularWindowController(
    preferredSize: const ui.Size(650, 44),
    title: 'Toolbar',
    delegate: _ToolbarDelegate(),
  );
  toolbarController.enableCustomWindow();
  runWidget(ToolbarApp(toolbarController: toolbarController));
}

class _ToolbarDelegate with RegularWindowControllerDelegate {
  @override
  void onWindowDestroyed() {
    super.onWindowDestroyed();
    exit(0);
  }
}

class ToolbarApp extends StatefulWidget {
  const ToolbarApp({super.key, required this.toolbarController});

  final RegularWindowController toolbarController;

  @override
  State<ToolbarApp> createState() => _ToolbarAppState();
}

class _ToolbarAppState extends State<ToolbarApp> {
  late final RegularWindowController _toolbarController;
  late final TooltipService _tooltipService;
  late final DialogService _dialogService;

  @override
  void initState() {
    super.initState();
    _toolbarController = widget.toolbarController;
    _positionWindowAtTopCenter(_toolbarController, 650, 44);
    _tooltipService = TooltipService(parentController: _toolbarController);
    _dialogService = DialogService(parentController: _toolbarController);
  }

  @override
  void dispose() {
    _dialogService.dispose();
    _tooltipService.dispose();
    _toolbarController.dispose();
    super.dispose();
  }

  void _positionWindowAtTopCenter(
    RegularWindowController controller,
    double width,
    double height,
  ) {
    final display = ui.PlatformDispatcher.instance.displays.first;
    final dpr = display.devicePixelRatio;
    final logicalW = display.size.width / dpr;
    final logicalH = display.size.height / dpr;
    final x = (logicalW - width) / 2;
    final y = Platform.isMacOS ? logicalH - height - 8 : 8.0;
    final frame = ui.Rect.fromLTWH(x * dpr, y * dpr, width * dpr, height * dpr);
    if (Platform.isWindows) {
      controller.configureFramelessWindow(
        frame: frame,
        transparentBackdrop: true,
      );
    } else if (controller is WindowControllerMacOS) {
      (controller as WindowControllerMacOS).setWindowFrame(frame);
    }
  }

  @override
  Widget build(BuildContext context) {
    return RegularWindow(
      controller: _toolbarController,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        builder: (context, child) => Container(
          color: Colors.transparent,
          child: child,
        ),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: ToolbarWindowContent(
            parentController: _toolbarController,
            tooltipService: _tooltipService,
            dialogService: _dialogService,
          ),
        ),
      ),
    );
  }
}

class DialogService {
  static const maxWidth = 224.0;
  static const _positioner = WindowPositioner(
    parentAnchor: WindowPositionerAnchor.bottom,
    childAnchor: WindowPositionerAnchor.top,
    offset: Offset(0, 8),
  );

  final BaseWindowController parentController;

  WindowRegistry? _registry;
  PopupWindowController? _controller;
  String? _activeTool;
  bool _isDestroyed = false;

  DialogService({required this.parentController});

  void show(String tool, Rect anchorRect, WindowRegistry registry) {
    _registry = registry;

    if (_activeTool == tool && !_isDestroyed) {
      hide();
      return;
    }

    hide();
    _createPopup(tool, anchorRect);
  }

  void hide() {
    try {
      _controller?.destroy();
    } on StateError {
      // Already destroyed.
    }
    _controller = null;
    _activeTool = null;
    _isDestroyed = true;
  }

  void dispose() {
    hide();
  }

  void _createPopup(String tool, Rect anchorRect) {
    final registry = _registry;
    if (registry == null) return;

    late final WindowEntry entry;
    final controller = PopupWindowController(
      parent: parentController,
      anchorRect: anchorRect,
      positioner: _positioner,
      preferredConstraints: const BoxConstraints(maxWidth: maxWidth),
      delegate: _PopupDelegate(
        onDestroyed: () {
          registry.unregister(entry);
          _controller = null;
          _activeTool = null;
          _isDestroyed = true;
        },
      ),
    );

    entry = WindowEntry(
      controller: controller,
      builder: (BuildContext context) => _ToolOptionsPopupContent(tool: tool),
    );
    registry.register(entry);

    _controller = controller;
    _activeTool = tool;
    _isDestroyed = false;
  }
}

class _PopupDelegate with PopupWindowControllerDelegate {
  _PopupDelegate({required this.onDestroyed});

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class _ToolOptionsPopupContent extends StatelessWidget {
  const _ToolOptionsPopupContent({required this.tool});

  final String tool;

  int get _optionRowCount {
    return switch (tool) {
      'Cursor' => 1,
      'Draw' => 2,
      'Line' => 3,
      'Shapes' => 4,
      'Arrow' => 5,
      'Text' => 6,
      'Highlight' => 5,
      'Screenshot' => 3,
      'Eraser' => 2,
      'Clear all' => 1,
      'Settings' => 4,
      'Toggle orientation' => 3,
      'Close toolbar' => 1,
      _ => 2,
    };
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: LayoutBuilder(
          builder: (context, constraints) {
            return Container(
              width: DialogService.maxWidth,
              decoration: BoxDecoration(
                color: const Color(0xFF2D2D2D),
                border: Border.all(color: Colors.white12),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(12, 10, 4, 6),
                    child: Row(
                      children: [
                        Icon(
                          _iconForTool(tool),
                          size: 16,
                          color: Colors.white54,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '$tool Options',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Colors.white12),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Text(
                      '${constraints.maxWidth.toStringAsFixed(0)}×'
                      '${constraints.maxHeight.toStringAsFixed(0)} '
                      '($_optionRowCount options)',
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 11,
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < _optionRowCount; i++) ...[
                          if (i > 0) const SizedBox(height: 6),
                          Container(
                            height: 28,
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            alignment: Alignment.centerLeft,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.06),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              'Option ${i + 1}',
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ),
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

  static IconData _iconForTool(String tool) {
    return switch (tool) {
      'Cursor' => Icons.near_me,
      'Draw' => Icons.draw,
      'Line' => Icons.show_chart,
      'Shapes' => Icons.category,
      'Arrow' => Icons.arrow_forward,
      'Text' => Icons.text_fields,
      'Highlight' => Icons.format_paint,
      'Screenshot' => Icons.camera_alt_outlined,
      'Eraser' => Icons.auto_fix_high,
      'Clear all' => Icons.clear_all,
      _ => Icons.tune,
    };
  }
}

class TooltipService {
  final BaseWindowController parentController;
  final ValueNotifier<String> textNotifier = ValueNotifier<String>('');

  WindowRegistry? _registry;
  TooltipWindowController? _controller;
  bool _isCreated = false;
  bool _isWindowDestroyed = false;
  Timer? _hideTimer;

  TooltipService({required this.parentController});

  void show(String text, Rect anchorRect, WindowRegistry registry) {
    _hideTimer?.cancel();
    _registry = registry;

    if (!_isCreated || _isWindowDestroyed) {
      _createWindow(text, anchorRect);
    } else {
      _updateWindow(text, anchorRect);
    }
    _showWindow();
  }

  void hide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 200), _hideWindow);
  }

  void dispose() {
    _hideTimer?.cancel();
    _destroyController();
    textNotifier.dispose();
  }

  void _createWindow(String text, Rect anchorRect) {
    final registry = _registry;
    if (registry == null) return;

    textNotifier.value = text;

    late final WindowEntry entry;
    final controller = TooltipWindowController(
      parent: parentController,
      anchorRect: anchorRect,
      positioner: const WindowPositioner(
        parentAnchor: WindowPositionerAnchor.bottom,
        childAnchor: WindowPositionerAnchor.top,
        offset: Offset(0, 8),
      ),
      delegate: _TooltipDelegate(
        onDestroyed: () {
          _isWindowDestroyed = true;
          registry.unregister(entry);
        },
      ),
    );

    entry = WindowEntry(
      controller: controller,
      builder: (BuildContext context) => _PersistentTooltipWindow(
        textNotifier: textNotifier,
      ),
    );

    registry.register(entry);

    _controller = controller;
    _isCreated = true;
    _isWindowDestroyed = false;

    if (Platform.isWindows && controller is TooltipWindowControllerWin32) {
      _Win32TooltipWindow.configureTransparentBackdrop(controller);
    }
  }

  void _updateWindow(String text, Rect anchorRect) {
    try {
      textNotifier.value = text;
      _controller?.updatePosition(anchorRect: anchorRect);
    } on StateError {
      _isWindowDestroyed = true;
    }
  }

  void _showWindow() {
    if (!_isCreated || _isWindowDestroyed) return;
    try {
      if (Platform.isWindows && _controller is TooltipWindowControllerWin32) {
        _Win32TooltipWindow.show(_controller as TooltipWindowControllerWin32);
      }
    } on StateError {
      _isWindowDestroyed = true;
    }
  }

  void _hideWindow() {
    if (!_isCreated || _isWindowDestroyed) return;
    try {
      if (Platform.isWindows && _controller is TooltipWindowControllerWin32) {
        _Win32TooltipWindow.hide(_controller as TooltipWindowControllerWin32);
      }
    } on StateError {
      _isWindowDestroyed = true;
    }
  }

  void _destroyController() {
    try {
      _controller?.destroy();
    } on StateError {
      // Already destroyed.
    }
    _controller = null;
    _isCreated = false;
    _isWindowDestroyed = false;
  }
}

class _PersistentTooltipWindow extends StatelessWidget {
  const _PersistentTooltipWindow({required this.textNotifier});

  final ValueNotifier<String> textNotifier;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: textNotifier,
      builder: (context, text, _) {
        return Material(
          type: MaterialType.transparency,
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1E1E1E),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white12),
              ),
              child: Text(
                text,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _TooltipDelegate with TooltipWindowControllerDelegate {
  _TooltipDelegate({required this.onDestroyed});

  final VoidCallback onDestroyed;

  @override
  void onWindowDestroyed() {
    onDestroyed();
    super.onWindowDestroyed();
  }
}

class ToolbarWindowContent extends StatelessWidget {
  const ToolbarWindowContent({
    super.key,
    required this.parentController,
    required this.tooltipService,
    required this.dialogService,
  });

  final BaseWindowController parentController;
  final TooltipService tooltipService;
  final DialogService dialogService;

  static const _toolbarBg = Color(0xFF2D2D2D);

  Widget _exclude(Widget child) => WindowDragExcludeArea(child: child);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: Stack(
        fit: StackFit.expand,
        children: [
          WindowDragArea(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: _toolbarBg,
                borderRadius: BorderRadius.circular(10),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(
              children: [
                if (Platform.isMacOS) ...[
                  const SizedBox(width: 76),
                  _exclude(const _Separator()),
                ],
                _exclude(
                  _ToolButton(
                    tooltip: 'Cursor',
                    icon: Icons.near_me,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Draw',
                    icon: Icons.draw,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Line',
                    icon: Icons.show_chart,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Shapes',
                    icon: Icons.category,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Arrow',
                    icon: Icons.arrow_forward,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Text',
                    icon: Icons.text_fields,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Highlight',
                    icon: Icons.format_paint,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(const _Separator()),
                _exclude(
                  _ToolButton(
                    tooltip: 'Screenshot',
                    icon: Icons.camera_alt_outlined,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Eraser',
                    icon: Icons.auto_fix_high,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Clear all',
                    icon: Icons.clear_all,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(const _Separator()),
                _exclude(
                  _ToolButton(
                    tooltip: 'Settings',
                    icon: Icons.settings_outlined,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(
                  _ToolButton(
                    tooltip: 'Toggle orientation',
                    icon: Icons.swap_horiz,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                  ),
                ),
                _exclude(const _Separator()),
                _exclude(
                  _ToolButton(
                    tooltip: 'Close toolbar',
                    icon: Icons.close,
                    tooltipService: tooltipService,
                    dialogService: dialogService,
                    isDestructive: true,
                  ),
                ),
                const SizedBox(width: 4),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    required this.tooltip,
    required this.icon,
    required this.tooltipService,
    required this.dialogService,
    this.isDestructive = false,
  });

  final String tooltip;
  final IconData icon;
  final TooltipService tooltipService;
  final DialogService dialogService;
  final bool isDestructive;

  void _onEnter(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final globalPos = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final anchorRect = Rect.fromLTWH(
      globalPos.dx,
      globalPos.dy,
      size.width,
      size.height,
    );
    tooltipService.show(tooltip, anchorRect, WindowRegistry.of(context));
  }

  void _onTap(BuildContext context) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final globalPos = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;
    final anchorRect = Rect.fromLTWH(
      globalPos.dx,
      globalPos.dy,
      size.width,
      size.height,
    );
    final registry = WindowRegistry.of(context);
    tooltipService.hide();
    dialogService.show(tooltip, anchorRect, registry);
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => _onEnter(context),
      onExit: (_) => tooltipService.hide(),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => _onTap(context),
          hoverColor: Colors.white.withValues(alpha: 0.1),
          splashColor: Colors.white.withValues(alpha: 0.15),
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Icon(
              icon,
              size: 20,
              color: isDestructive ? Colors.red.shade300 : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }
}

class _Separator extends StatelessWidget {
  const _Separator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Container(
        width: 1,
        height: 20,
        color: Colors.white24,
      ),
    );
  }
}

/// Win32 helpers for tooltip windows. Tooltip controllers are engine-managed
/// and do not go through [enableCustomWindow], so these stay example-local.
abstract final class _Win32TooltipWindow {
  static const _wcaAccentPolicy = 19;
  static const _accentEnableTransparentGradient = 2;

  static final _setWindowCompositionAttribute =
      DynamicLibrary.open(
        'user32.dll',
      ).lookupFunction<
        Int32 Function(Pointer, Pointer),
        int Function(Pointer, Pointer)
      >(
        'SetWindowCompositionAttribute',
      );

  static void configureTransparentBackdrop(
    TooltipWindowControllerWin32 controller,
  ) {
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

    final margins = calloc<MARGINS>();
    margins.ref.cxLeftWidth = -1;
    margins.ref.cxRightWidth = -1;
    margins.ref.cyTopHeight = -1;
    margins.ref.cyBottomHeight = -1;
    DwmExtendFrameIntoClientArea(hwnd, margins);
    calloc.free(margins);

    final accent = calloc<_AccentPolicy>();
    accent.ref.accentState = _accentEnableTransparentGradient;
    accent.ref.accentFlags = 2;

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

  static void show(TooltipWindowControllerWin32 controller) {
    ShowWindow(HWND(controller.windowHandle), SW_SHOWNOACTIVATE);
  }

  static void hide(TooltipWindowControllerWin32 controller) {
    ShowWindow(HWND(controller.windowHandle), SW_HIDE);
  }
}

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

  @Uint32()
  external int cbData;
}
