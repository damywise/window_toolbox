import 'dart:ui' as ui;

/// Exact fullscreen breaks DWM; one physical pixel less is enough.
const nearFullscreenWidthInset = 1;

ui.Rect nearFullscreenPhysicalFrame([ui.Display? display]) {
  final d = display ?? ui.PlatformDispatcher.instance.displays.first;
  return ui.Rect.fromLTWH(
    0,
    0,
    d.size.width - nearFullscreenWidthInset,
    d.size.height,
  );
}

ui.Size fullscreenLogicalSize([ui.Display? display]) {
  final d = display ?? ui.PlatformDispatcher.instance.displays.first;
  final dpr = d.devicePixelRatio;
  return ui.Size(d.size.width / dpr, d.size.height / dpr);
}

({ui.Rect physicalFrame, ui.Size logicalSize}) matrixQuadrantCell({
  ui.Display? display,
  int column = 0,
  int row = 0,
  int columns = 2,
  int rows = 4,
}) {
  final d = display ?? ui.PlatformDispatcher.instance.displays.first;
  final dpr = d.devicePixelRatio;
  final cellPhysW = d.size.width / columns;
  final cellPhysH = d.size.height / rows;
  return (
    physicalFrame: ui.Rect.fromLTWH(
      column * cellPhysW,
      row * cellPhysH,
      cellPhysW,
      cellPhysH,
    ),
    logicalSize: ui.Size(cellPhysW / dpr, cellPhysH / dpr),
  );
}
