import 'dart:ui' show Rect;

/// Win32 init options passed to [CustomWindow.init] via [enableCustomWindow].
class CustomWindowInitOptions {
  const CustomWindowInitOptions({
    this.frame,
    this.transparentBackdrop = false,
    this.mousePassthrough = false,
    this.hideFromSwitcher = false,
    this.alwaysOnTop = false,
    this.fullscreenCompatibleTopmost = true,
    this.hideUntilFirstFrame = false,
  });

  final Rect? frame;
  final bool transparentBackdrop;
  final bool mousePassthrough;
  final bool hideFromSwitcher;
  final bool alwaysOnTop;
  final bool fullscreenCompatibleTopmost;
  final bool hideUntilFirstFrame;

  static const none = CustomWindowInitOptions();

  CustomWindowInitOptions merge(CustomWindowInitOptions other) {
    return CustomWindowInitOptions(
      frame: other.frame ?? frame,
      transparentBackdrop: transparentBackdrop || other.transparentBackdrop,
      mousePassthrough: mousePassthrough || other.mousePassthrough,
      hideFromSwitcher: hideFromSwitcher || other.hideFromSwitcher,
      alwaysOnTop: alwaysOnTop || other.alwaysOnTop,
      fullscreenCompatibleTopmost: other.fullscreenCompatibleTopmost,
      hideUntilFirstFrame: hideUntilFirstFrame || other.hideUntilFirstFrame,
    );
  }
}
