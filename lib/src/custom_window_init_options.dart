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
    this.allowKeyboardFocus = false,
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

  /// When true, transparent-backdrop windows skip [WS_EX_NOACTIVATE] so text
  /// fields can receive keyboard focus. Overlays default to false.
  final bool allowKeyboardFocus;

  /// Full frameless mode: client fills the outer frame and native NC chrome is
  /// suppressed. Implied when [titleless] is false or overlay flags are set.
  bool get isFrameless =>
      !titleless || transparentBackdrop || mousePassthrough;

  /// Overlay satellites (dialog, drawing) skip classic WS_CAPTION resize
  /// chrome. Resizable windows like the toolbar keep resize chrome even with
  /// [transparentBackdrop].
  bool get skipClassicResizeChrome =>
      mousePassthrough || (transparentBackdrop && hideFromSwitcher);

  static const none = CustomWindowInitOptions();

  CustomWindowInitOptions merge(CustomWindowInitOptions other) {
    return CustomWindowInitOptions(
      frame: other.frame ?? frame,
      titleless: titleless || other.titleless,
      transparentBackdrop: transparentBackdrop || other.transparentBackdrop,
      mousePassthrough: mousePassthrough || other.mousePassthrough,
      hideFromSwitcher: hideFromSwitcher || other.hideFromSwitcher,
      alwaysOnTop: alwaysOnTop || other.alwaysOnTop,
      fullscreenCompatibleTopmost: other.fullscreenCompatibleTopmost,
      allowKeyboardFocus: allowKeyboardFocus || other.allowKeyboardFocus,
    );
  }

  CustomWindowInitOptions copyWith({
    Rect? frame,
    bool? titleless,
    bool? transparentBackdrop,
    bool? mousePassthrough,
    bool? hideFromSwitcher,
    bool? alwaysOnTop,
    bool? fullscreenCompatibleTopmost,
    bool? allowKeyboardFocus,
  }) {
    return CustomWindowInitOptions(
      frame: frame ?? this.frame,
      titleless: titleless ?? this.titleless,
      transparentBackdrop: transparentBackdrop ?? this.transparentBackdrop,
      mousePassthrough: mousePassthrough ?? this.mousePassthrough,
      hideFromSwitcher: hideFromSwitcher ?? this.hideFromSwitcher,
      alwaysOnTop: alwaysOnTop ?? this.alwaysOnTop,
      fullscreenCompatibleTopmost:
          fullscreenCompatibleTopmost ?? this.fullscreenCompatibleTopmost,
      allowKeyboardFocus: allowKeyboardFocus ?? this.allowKeyboardFocus,
    );
  }
}
