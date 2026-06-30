# window_toolbox

`window_toolbox` is a Flutter package for building custom window chrome compatible with Flutter's multi-window API. Special care has been taken to ensure that expected platform behavior, such [snap layout](https://support.microsoft.com/en-us/windows/snap-your-windows-885a9b1e-a983-a3b1-16cd-c531795e6241) on Windows, is preserved, while still allowing for a high degree of customization.

In addition to custom window chrome, this package also provides extension classes on top of native window controllers, exposing more native window functionality and allowing to react to subset of `NSWindowDelegate` methods or handing `win32` messages directly in Dart.

<img src="media/screenshot_linux.jpg" width="661">

## Custom window chrome

To customize window, it is necessary first to call [enableCustomWindow] on the controller:

```dart
controller = RegularWindowController(...);
controller.enableCustomWindow(); // frameless by default on Win32
// controller.enableCustomWindow(titleless: true); // native frame + custom caption
```

Pass `titleless: true` for **titleless** windows: the native caption is removed in favor of your Flutter chrome, while the system keeps the non-client frame (border, shadow, rounded corners). The default is **frameless** chrome (client area fills the outer frame). Overlay flags (`transparentBackdrop`, `mousePassthrough`) also select frameless mode.

On Windows, frameless mode schedules size correction automatically after the first frame. For transparent toolbars, pass `transparentBackdrop: true` (and optionally `frame` in physical pixels). Prefer `enableCustomWindow(...)` over a separate `configureFramelessWindow(...)` call.

**Drawing overlay (near-fullscreen, click-through):**

Exact fullscreen width can break DWM compositing on Windows; spawn one physical
pixel narrower than the display:

```dart
final display = PlatformDispatcher.instance.displays.first;
final frame = Rect.fromLTWH(
  0,
  0,
  display.size.width - 1,
  display.size.height,
);

controller.enableCustomWindow(
  frame: frame,
  transparentBackdrop: true,
  mousePassthrough: true,
  hideFromSwitcher: true,
  alwaysOnTop: true,
  fullscreenCompatibleTopmost: true,
);
```

Toggle passthrough at runtime with `controller.setIgnoresMouseEvents(true|false)`.

### Win32 satellite windows (tooltips / popups)

When a frameless toolbar hosts `TooltipWindowController` or `PopupWindowController` children, Flutter cannot place them below the toolbar with a positive Y offset via `WindowPositioner.offset` alone (anchor Y is clamped to the parent client rect). Use the **Flutter reference pattern** from `examples/multiple_windows`:

```dart
import 'package:window_toolbox/window_toolbox.dart';

// Satellite root — autosize like Flutter's popup example:
Overlay.wrap(
  alwaysSizeToContent: true,
  child: Material(
    type: MaterialType.transparency,
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [Text('Hello')],
    ),
  ),
)

// Default constraints (do not pass maxWidth: 280 unless you must):
final controller = TooltipWindowController(
  parent: toolbarController,
  anchorRect: buttonAnchorInParentSpace,
  positioner: const WindowPositioner(
    parentAnchor: WindowPositionerAnchor.bottomRight,
    childAnchor: WindowPositionerAnchor.topRight,
  ),
  // preferredConstraints defaults to BoxConstraints()
  delegate: delegate,
);

// Y gap below frameless toolbar (X stays with the engine positioner):
_maintainer = attachWin32SatelliteMaintainer(
  parent: toolbarController,
  child: controller,
  placement: Win32SatellitePlacement.trailing(gapLogical: 20),
  existing: _maintainer,
);
```

Track the anchor with `ElementPositionTracker` (see `example/lib/element_position_tracker.dart`) and call `updatePosition` when the button moves. For loose `maxWidth` caps without `Overlay.wrap`, use `Win32SatelliteTightSize` or `Win32SatellitePlacement.nativeTrailing`.

Call `Win32SatelliteGapController.dispose()` before hiding or destroying the child. See `example/lib/main_transparent_gap_matrix.dart` for a side-by-side comparison and `example/lib/main_transparent.dart` for a production toolbar demo.

Once that is done, you can place various widgets in your widget tree to build draggable areas, traffic light buttons (macOS) or window buttons:

- `WindowDragArea` - Widget that creates area that can be used to drag the window.
- `WindowDragExcludeArea` - Marks places inside `WindowDragArea` that should not be draggable. This is useful for buttons in title bar, tabs, or other controls that should not participate in window dragging.
- `WindowTrafficLight` - a "proxy" widget for macOS traffic light. Wherever this widget is placed, the actual macOS traffic light buttons will be positioned. This widget can also be used to hide the traffic light buttons completely or change the style of inactive traffic light.
- `MaximizeButton`, `MinimizeButton`, `CloseButton` - Widgets representing standard window buttons. These accept custom builders so the presentation is fully customizable, while ensuring the proper behavior on each platform. On Windows the `MaximizeButton` properly supports the [snap layout](https://support.microsoft.com/en-us/windows/snap-your-windows-885a9b1e-a983-a3b1-16cd-c531795e6241) popup.
- `WindowBorder` - On Linux draws shadows, border and clips the content to round corners (if specified). On other platforms this widget has no effect, since shadows, borders and clipping are handled by the system compositor.

A [complete example](example/lib/main.dart) of fully customized window can be found in the [example](example) directory.

<img src="media/snap_layout.jpg" width="344">

## Additional window functionality

On top of custom window chrome, `window_toolbox` also provides some additional platform specific functionality related to native windows.

This includes:

- Exposing more of `NSWindow` API and ability to register custom delegate for macOS windows. See [WindowDelegateMacOS](lib/src/macos_extra.dart) for more details.

- Ability to register custom delegate and message handlers on Windows. See [Win32MessageHandler](lib/src/win32_extra.dart) for more details.

- Ability to register custom delegate on linux. See [WindowDelegateLinux](lib/src/linux_extra.dart) for more details.

#### Example: Setting [NSWindowCollectionBehavior](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct) on macOS

```dart
final controller = RegularWindowController(...);
if (controller is WindowControllerMacOS) {
  final controllerMacOS = controller as WindowControllerMacOS;
  // Add fullScreenNone to existing collection behavior to disable
  // full screen mode for this window.
  controllerMacOS.collectionBehavior = {
    ...controllerMacOS.collectionBehavior,
    NSWindowCollectionBehavior.fullScreenNone,
  };
}
```

The  windowing API surface is very big and exposing more of the platform specific functionality is planned, requests and contributions are welcome.