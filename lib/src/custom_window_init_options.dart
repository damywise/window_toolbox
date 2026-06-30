import 'dart:ui' show Rect;

/// Win32 init options passed to [CustomWindow.init] via [enableCustomWindow].
class CustomWindowInitOptions {
  const CustomWindowInitOptions({
    this.frame,
    this.titleless = false,
    this.transparentBackdrop = false,
    this.mousePassthrough = false,
    this.hideFromSwitcher = false,
    this.alwaysOnTop = false,
    this.fullscreenCompatibleTopmost = true,
  });

  final Rect? frame;
  /// When true, uses titleless chrome: native frame/border/shadow retained,
  /// only the caption band is removed via [WM_NCCALCSIZE]. Default is false
  /// (frameless chrome). Pass `titleless: true` for knopp-style titleless
  /// windows, or use overlay flags for frameless overlays.
  final bool titleless;
  final bool transparentBackdrop;
  final bool mousePassthrough;
  final bool hideFromSwitcher;
  final bool alwaysOnTop;
  final bool fullscreenCompatibleTopmost;

  /// Full frameless mode: client fills the outer frame and native NC chrome is
  /// suppressed. Implied when [titleless] is false or overlay flags are set.
  bool get isFrameless =>
      !titleless || transparentBackdrop || mousePassthrough;

  static const none = CustomWindowInitOptions();

  CustomWindowInitOptions merge(CustomWindowInitOptions other) {
    return CustomWindowInitOptions(
      frame: other.frame ?? frame,
      titleless: other.titleless && titleless,
      transparentBackdrop: transparentBackdrop || other.transparentBackdrop,
      mousePassthrough: mousePassthrough || other.mousePassthrough,
      hideFromSwitcher: hideFromSwitcher || other.hideFromSwitcher,
      alwaysOnTop: alwaysOnTop || other.alwaysOnTop,
      fullscreenCompatibleTopmost: other.fullscreenCompatibleTopmost,
    );
  }
}
