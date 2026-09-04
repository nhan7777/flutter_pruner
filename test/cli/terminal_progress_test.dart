import 'package:flutter_pruner/src/cli/cli_signal_coordinator.dart';
import 'package:flutter_pruner/src/cli/terminal_progress.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
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

  test('renders package-internal names as terminal-safe escapes', () {
    const hostile = 'package\nFORGED\r\x1B[2K\u202e\u2028\u2029\u2066';

    final plain = _stripAnsi(packageInternalWarning(hostile));

    expect(
      plain,
      startsWith(
        r'⚠  WARNING · PACKAGE INTERNAL (package\nFORGED\r\x1B[2K'
        r'\u202E\u2028\u2029\u2066)',
      ),
    );
    expect(plain, isNot(contains('\r')));
    expect(plain, isNot(contains('\x1B')));
    expect(
      plain,
      isNot(matches(RegExp(r'[\u2028\u2029\u202a-\u202e\u2066-\u2069]'))),
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
    expect(rendered, contains('Scanning Dart declaration analyzer…'));
    expect(rendered, contains('Scanning Asset analyzer…'));
    expect(rendered, isNot(contains('\r')));
    expect(rendered, isNot(contains('\x1B[2K')));
    expect(rendered, isNot(contains('\x1B[?25')));
  });

  test('supports apply activities without changing the scan default', () {
    final output = StringBuffer();
    TerminalProgress(sink: output, animated: false)
      ..start('verification baseline', activity: 'Capturing')
      ..start('atomic unit 1', activity: 'Verifying')
      ..finish(succeeded: false);

    final rendered = output.toString();
    expect(rendered, contains('Capturing verification baseline…'));
    expect(rendered, contains('Verifying atomic unit 1…'));
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

  test('finishing an activity twice cancels and emits its completion once', () {
    final output = StringBuffer();
    var canceledTickers = 0;
    final progress = TerminalProgress(
      sink: output,
      animated: true,
      startTicker: (_) =>
          () => canceledTickers++,
    );

    progress
      ..start('Dart declaration analyzer')
      ..finish(succeeded: true)
      ..finish(succeeded: true);

    final plain = _stripAnsi(output.toString());
    expect(canceledTickers, 1);
    expect('✓ Dart declaration analyzer'.allMatches(plain), hasLength(1));
  });

  test('queued ticks from a finished activity write nothing', () {
    final output = StringBuffer();
    late void Function() tick;
    final progress = TerminalProgress(
      sink: output,
      animated: true,
      startTicker: (callback) {
        tick = callback;
        return () {};
      },
    );

    progress
      ..start('Dart declaration analyzer')
      ..finish(succeeded: true);
    final finished = output.toString();
    tick();

    expect(output.toString(), finished);
  });

  test('ticker cancellation cannot render a late frame during finish', () {
    final output = StringBuffer();
    late void Function() tick;
    final progress = TerminalProgress(
      sink: output,
      animated: true,
      startTicker: (callback) {
        tick = callback;
        return tick;
      },
    );

    progress
      ..start('Dart declaration analyzer')
      ..finish(succeeded: true);

    expect('⠙'.allMatches(output.toString()), isEmpty);
  });

  test('starting new activity completes the old activity exactly once', () {
    final output = StringBuffer();
    var canceledTickers = 0;
    final progress = TerminalProgress(
      sink: output,
      animated: true,
      startTicker: (_) =>
          () => canceledTickers++,
    );

    progress
      ..start('Dart declaration analyzer')
      ..start('Asset analyzer')
      ..finish(succeeded: true);

    final plain = _stripAnsi(output.toString());
    expect('✓ Dart declaration analyzer'.allMatches(plain), hasLength(1));
    expect('✓ Asset analyzer'.allMatches(plain), hasLength(1));
    expect(canceledTickers, 2);
  });

  test(
    'signal clearer cancels animation and restores a complete line once',
    () {
      final output = StringBuffer();
      final coordinator = _FakeSignalCoordinator();
      late void Function() tick;
      var canceledTickers = 0;
      final progress = TerminalProgress(
        sink: output,
        animated: true,
        signalCoordinator: coordinator,
        startTicker: (callback) {
          tick = callback;
          return () => canceledTickers++;
        },
      );

      progress.start('verification baseline');
      final clearer = coordinator.clearer;
      expect(clearer, isNotNull);
      clearer!();
      final interrupted = output.toString();
      tick();
      progress.finish(succeeded: true);

      expect(canceledTickers, 1);
      expect(interrupted, endsWith('\r\x1B[2K\n'));
      expect(output.toString(), interrupted);
      expect(_stripAnsi(interrupted), isNot(contains('✓')));
      expect(coordinator.clearer, isNull);
    },
  );

  test(
    'non-animated progress emits bounded milestones without cursor clear',
    () {
      final output = StringBuffer();
      TerminalProgress(sink: output, animated: false)
        ..start('Dart declaration analyzer')
        ..finish(succeeded: true)
        ..finish(succeeded: true);

      final plain = _stripAnsi(output.toString());
      expect(plain, '• Scanning Dart declaration analyzer…\n');
      expect(output.toString(), isNot(contains('\r')));
      expect(output.toString(), isNot(contains('\x1B[2K')));
    },
  );

  test('finishing without an active activity is a no-op', () {
    final output = StringBuffer();

    TerminalProgress(sink: output, animated: true).finish(succeeded: false);

    expect(output.toString(), isEmpty);
  });

  test('failed progress emits no green completion glyph', () {
    final output = StringBuffer();
    TerminalProgress(sink: output, animated: true, startTicker: (_) => () {})
      ..start('verification baseline')
      ..finish(succeeded: false);

    final rendered = output.toString();
    expect(rendered, isNot(contains('\x1B[32m✓')));
    expect(_stripAnsi(rendered), contains('! verification baseline stopped'));
  });

  test(
    'renders dynamic project and activity text as terminal-safe escapes',
    () {
      const hostile = 'project\nFORGED\r\x1B[2K\u202e\u2028\u2029\u2066';
      final output = StringBuffer();
      final progress = TerminalProgress(sink: output, animated: false);

      progress
        ..writeProject(hostile)
        ..start(hostile, activity: hostile)
        ..finish(succeeded: false);

      final plain = _stripAnsi(output.toString());
      const escaped = r'project\nFORGED\r\x1B[2K\u202E\u2028\u2029\u2066';
      expect(
        plain,
        '◆ PROJECT  $escaped\n'
        '• $escaped $escaped…\n'
        '! $escaped stopped\n',
      );
      expect(plain, isNot(contains('\r')));
      expect(plain, isNot(contains('\x1B')));
      expect(
        plain,
        isNot(matches(RegExp(r'[\u2028\u2029\u202a-\u202e\u2066-\u2069]'))),
      );
    },
  );
}

final class _FakeSignalCoordinator implements CliSignalCoordinator {
  @override
  final ManagedProcessCancellationController processCancellation =
      ManagedProcessCancellationController();

  void Function()? clearer;

  @override
  Future<T> guard<T>(Future<T> Function() body) => body();

  @override
  void setActiveLineClearer(void Function()? clearer) {
    this.clearer = clearer;
  }
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
