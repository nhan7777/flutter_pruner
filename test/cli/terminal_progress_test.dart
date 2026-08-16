import 'package:flutter_pruner/src/cli/terminal_progress.dart';
import 'package:test/test.dart';

void main() {
  test('highlights package-internal scope and external-consumer risk', () {
    final rendered = packageInternalWarning('khlc_product');

    expect(
      rendered,
      startsWith('\x1B[1m\x1B[33m⚠  WARNING · PACKAGE INTERNAL'),
    );
    expect(rendered, contains('\x1B[1m\x1B[35m(khlc_product)'));
    expect(
      rendered,
      contains(
        '\x1B[33m┃\x1B[0m \x1B[1m'
        'Only references inside this package are analysed.',
      ),
    );
    expect(
      rendered,
      contains(
        '\x1B[33m┃ External applications and packages may still use public '
        'symbols,\x1B[0m\n'
        '\x1B[33m┃ deep imports, and package assets.',
      ),
    );
  });

  test('renders colored italic progress without animation when redirected', () {
    final output = StringBuffer();
    TerminalProgress(sink: output, animated: false)
      ..writeProject('/project')
      ..start('Dart declaration analyzer')
      ..start('Asset analyzer')
      ..finish(succeeded: true);

    final rendered = output.toString();
    expect(rendered, contains('\x1B[1m\x1B[35m◆ PROJECT'));
    expect(rendered, contains('\x1B[3m'));
    expect(rendered, contains('•\x1B[0m'));
    expect(rendered, contains('Scanning Dart declaration analyzer...'));
    expect(rendered, contains('Scanning Asset analyzer...'));
    expect(rendered, isNot(contains('\x1B[2K')));
  });

  test('supports apply activities without changing the scan default', () {
    final output = StringBuffer();
    TerminalProgress(sink: output, animated: false)
      ..start('verification baseline', activity: 'Capturing')
      ..start('atomic unit 1', activity: 'Verifying')
      ..finish(succeeded: false);

    final rendered = output.toString();
    expect(rendered, contains('Capturing verification baseline...'));
    expect(rendered, contains('Verifying atomic unit 1...'));
    expect(rendered, contains('atomic unit 1 stopped'));
  });

  test(
    'animates frames and completes each analyzer on an interactive terminal',
    () {
      final output = StringBuffer();
      late void Function() tick;
      var canceledTickers = 0;
      final progress = TerminalProgress(
        sink: output,
        animated: true,
        startTicker: (callback) {
          tick = callback;
          return () => canceledTickers++;
        },
      );

      progress.start('Dart declaration analyzer');
      tick();
      progress.start('Asset analyzer');
      progress.finish(succeeded: true);

      final rendered = output.toString();
      expect(rendered, contains('⠋'));
      expect(rendered, contains('⠙'));
      expect(rendered, contains('\r\x1B[2K'));
      expect(
        rendered,
        contains('✓\x1B[0m \x1B[3m\x1B[2mDart declaration analyzer'),
      );
      expect(rendered, contains('✓\x1B[0m \x1B[3m\x1B[2mAsset analyzer'));
      expect(canceledTickers, 2);
    },
  );
}
