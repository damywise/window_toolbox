import 'package:test/test.dart';
import 'package:window_toolbox/src/custom_window_init_options.dart';
import 'package:window_toolbox/src/win32_util.dart';

void main() {
  group('CustomWindowInitOptions', () {
    test('frameless by default', () {
      const options = CustomWindowInitOptions();
      expect(options.titleless, isFalse);
      expect(options.isFrameless, isTrue);
    });

    test('titleless true keeps native frame chrome path', () {
      const options = CustomWindowInitOptions(titleless: true);
      expect(options.isFrameless, isFalse);
    });

    test('overlay flags imply frameless', () {
      const options = CustomWindowInitOptions(transparentBackdrop: true);
      expect(options.isFrameless, isTrue);
    });

    test('titleless false implies frameless', () {
      const options = CustomWindowInitOptions(titleless: false);
      expect(options.isFrameless, isTrue);
    });
  });

  test('Parse and make negative LPARAM X', () {
    final lparam = 0x3BFF775;
    final (x, y) = splitLParam(lparam);
    expect(x, equals(-2187));
    expect(y, equals(959));

    final madeLParam = makeLParam(x, y);
    expect(madeLParam, equals(lparam));
  });
  test('Parse and make negative LPARAM Y', () {
    final lparam = 0xF77503BF;
    final (x, y) = splitLParam(lparam);
    expect(x, equals(959));
    expect(y, equals(-2187));

    final madeLParam = makeLParam(x, y);
    expect(madeLParam & 0xFFFFFFFF, equals(lparam & 0xFFFFFFFF));
  });

  test('maximizeClientRect uses rcWork when provided', () {
    const proposed = (left: -8, top: -8, right: 1928, bottom: 1048);
    const rcWork = (left: 0, top: 0, right: 1920, bottom: 1040);

    expect(maximizeClientRect(proposed, rcWork: rcWork), equals(rcWork));
  });

  test('maximizeClientRect applies symmetric border fallback', () {
    const proposed = (left: 0, top: 0, right: 1920, bottom: 1080);

    expect(
      maximizeClientRect(proposed),
      equals((left: -8, top: -8, right: 1928, bottom: 1088)),
    );
  });
}
