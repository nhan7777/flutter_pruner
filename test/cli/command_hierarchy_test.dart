import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart' as args;
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:test/test.dart';

import 'cli_process_harness.dart';

void main() {
  const processTestTimeout = Timeout(Duration(minutes: 2));
  late CliProcessHarness harness;

  setUp(() {
    harness = CliProcessHarness.repository();
  });

  tearDown(() => harness.close());

  test(
    'bare root, quarantine, and q render stdin-free help without side effects',
    () async {
      final fixture = CliFixture.create(prefix: 'c3 bare quarantine ');
      addTearDown(fixture.dispose);
      final before = _snapshotTree(fixture);

      // Real-process smoke: bare root verifies the executable, exit code,
      // stdout/stderr separation, and stdin non-read.
      final root = await harness.run(
        const [],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );

      final runner = FlutterPrunerCommandRunner();
      final bare = await _runCaptured(runner, const ['quarantine']);
      final explicit = await _runCaptured(runner, const [
        'quarantine',
        '--help',
      ]);
      final alias = await _runCaptured(runner, const ['q', '--help']);
      final bareAlias = await _runCaptured(runner, const ['q']);
      final helpAlias = await _runCaptured(runner, const ['help', 'q']);

      expect(root.timedOut, isFalse);
      expect(root.exitCode, 0);
      expect(root.stderrBytes, isEmpty);
      expect(root.stdoutBytes, isNotEmpty);
      expectNoAnsi(root);

      for (final result in [bare, explicit, alias, bareAlias, helpAlias]) {
        expect(result.exitCode, 0);
        expect(result.stderr, isEmpty);
        expect(result.stdout, isNotEmpty);
        _expectNoAnsiText('${result.stdout}${result.stderr}');
      }
      expect(bare.stdout, explicit.stdout);
      expect(alias.stdout, explicit.stdout);
      expect(bareAlias.stdout, explicit.stdout);
      expect(helpAlias.stdout, explicit.stdout);
      expect(root.stdoutText, contains('Available commands:'));
      expect(root.stdoutText, contains('quarantine   Manage quarantine'));
      expect(root.stdoutText, isNot(contains('\n  q ')));
      expect(explicit.stdout, contains('Available subcommands:'));
      expect(explicit.stdout, isNot(contains('--project')));
      expect(_snapshotTree(fixture), before);
    },
    timeout: processTestTimeout,
  );

  test(
    'help is narrow-width deterministic and obeys the ANSI and NO_COLOR policy',
    () async {
      final fixture = CliFixture.create(prefix: 'c3 help width ');
      addTearDown(fixture.dispose);
      final before = _snapshotTree(fixture);
      // Real-process smoke: narrow width verifies the executable honors
      // COLUMNS for wrapping.
      final narrow = await harness.run(
        const ['scan', '--help'],
        workingDirectory: fixture.root,
        environmentAdditions: const {'COLUMNS': '20', 'NO_COLOR': '1'},
        stdinText: 'must not be read\n',
      );
      // In-process wide: the runner reads COLUMNS from Platform.environment,
      // which is unset in the test process, so output is unwrapped.
      final wide = await _runCaptured(FlutterPrunerCommandRunner(), const [
        'scan',
        '--help',
      ]);

      expect(narrow.exitCode, 0);
      expect(narrow.stderrBytes, isEmpty);
      expectNoAnsi(narrow);
      expect(wide.exitCode, 0);
      expect(wide.stderr, isEmpty);
      _expectNoAnsiText('${wide.stdout}${wide.stderr}');

      final narrowFixture = File('test/cli/fixtures/scan_help_columns_20.txt');
      expect(narrow.stdoutText, narrowFixture.readAsStringSync());
      expect(narrow.stdoutText, isNot(wide.stdout));
      expect(
        const LineSplitter()
            .convert(narrow.stdoutText)
            .every(
              (line) =>
                  line.runes.length <= 20 ||
                  line
                      .split(RegExp(r'\s+'))
                      .any((word) => word.runes.length > 20) ||
                  // args package wraps allowed-value lists wider than COLUMNS
                  line.trimLeft().startsWith('(') ||
                  line.trimLeft().startsWith('['),
            ),
        isTrue,
      );
      expect(_snapshotTree(fixture), before);
    },
    timeout: processTestTimeout,
  );

  test(
    'help command paths are equivalent and leave the selected project unchanged',
    () async {
      final fixture = CliFixture.create(prefix: 'c3 help hierarchy ');
      addTearDown(fixture.dispose);
      final before = _snapshotTree(fixture);
      const paths = <List<String>>[
        ['init'],
        ['scan'],
        ['apply'],
        ['rollback'],
        ['quarantine'],
        ['quarantine', 'list'],
        ['quarantine', 'inspect'],
        ['quarantine', 'clean'],
      ];

      // Real-process smoke: `help scan` verifies the executable renders help
      // for a command path.
      final smoke = await harness.run(
        const ['help', 'scan'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );
      expect(smoke.timedOut, isFalse);
      expect(smoke.exitCode, 0);
      expect(smoke.stderrBytes, isEmpty);
      expectNoAnsi(smoke);

      final runner = FlutterPrunerCommandRunner();
      for (final path in paths) {
        final isSmokePath = path.length == 1 && path.single == 'scan';
        final fromHelp = isSmokePath
            ? _CapturedRun(
                exitCode: smoke.exitCode,
                stdout: smoke.stdoutText,
                stderr: smoke.stderrText,
              )
            : await _runCaptured(runner, ['help', ...path]);
        final fromFlag = await _runCaptured(runner, [...path, '--help']);

        for (final result in [fromHelp, fromFlag]) {
          expect(result.exitCode, 0, reason: path.join(' '));
          expect(result.stderr, isEmpty, reason: path.join(' '));
          _expectNoAnsiText(
            '${result.stdout}${result.stderr}',
            reason: path.join(' '),
          );
        }
        expect(fromHelp.stdout, fromFlag.stdout, reason: path.join(' '));
      }
      expect(_snapshotTree(fixture), before);
    },
    timeout: processTestTimeout,
  );

  test(
    'unknown and misplaced argv use stderr, usage exit, and canonical choices',
    () async {
      final fixture = CliFixture.create(prefix: 'c3 invalid hierarchy ');
      addTearDown(fixture.dispose);
      final before = _snapshotTree(fixture);
      final cases = <(List<String>, String)>[
        (const ['scna'], 'Did you mean one of these?\n  scan'),
        (
          const ['quarantine', 'inspec'],
          'Did you mean one of these?\n  inspect',
        ),
        (const ['q', 'inspec'], 'Did you mean one of these?\n  inspect'),
        (
          const ['quarantine', 'list', '--all'],
          'Usage: flutter_pruner quarantine list',
        ),
      ];

      // Real-process smoke: unknown top-level command verifies the executable
      // reports usage errors on stderr with exit code 64.
      final smoke = await harness.run(
        const ['scna'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );
      expect(smoke.exitCode, 64, reason: 'scna');
      expect(smoke.stdoutBytes, isEmpty, reason: 'scna');
      expect(smoke.stderrText, contains('Did you mean one of these?\n  scan'));
      expectNoAnsi(smoke);

      final runner = FlutterPrunerCommandRunner();
      for (final testCase in cases.skip(1)) {
        final result = await _runCaptured(runner, testCase.$1);

        expect(result.exitCode, 64, reason: testCase.$1.join(' '));
        expect(result.stdout, isEmpty, reason: testCase.$1.join(' '));
        expect(result.stderr, contains(testCase.$2));
        _expectNoAnsiText(
          '${result.stdout}${result.stderr}',
          reason: testCase.$1.join(' '),
        );
      }
      expect(_snapshotTree(fixture), before);
    },
    timeout: processTestTimeout,
  );
}

List<String> _snapshotTree(CliFixture fixture) {
  final root = fixture.root;
  final entries = root.listSync(recursive: true, followLinks: false)
    ..sort((left, right) => left.path.compareTo(right.path));
  return [
    for (final entry in entries)
      entry is File
          ? '${entry.path}:${entry.readAsBytesSync().length}'
          : entry.path,
  ];
}

Future<_CapturedRun> _runCaptured(
  args.CommandRunner<int> runner,
  List<String> arguments,
) async {
  final capturedStdout = _RecordingStdout();
  final capturedStderr = _RecordingStdout();
  final exitCode =
      await IOOverrides.runZoned(
        () => runner.run(arguments),
        stdout: () => capturedStdout,
        stderr: () => capturedStderr,
      ) ??
      0;
  await capturedStdout.close();
  await capturedStderr.close();
  return _CapturedRun(
    exitCode: exitCode,
    stdout: capturedStdout.text,
    stderr: capturedStderr.text,
  );
}

void _expectNoAnsiText(String output, {String? reason}) {
  final ansiIntroducer = RegExp(r'[\x1b\x90\x98\x9b\x9d-\x9f]');
  expect(output, isNot(contains(ansiIntroducer)), reason: reason);
}

final class _CapturedRun {
  const _CapturedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _RecordingStdout implements Stdout {
  final _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => throw const StdoutException('not a terminal');

  @override
  int get terminalLines => throw const StdoutException('not a terminal');

  @override
  IOSink get nonBlocking => this;

  @override
  void add(List<int> data) => _buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _buffer.write(error);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) {
    _buffer
      ..write(object)
      ..write(lineTerminator);
  }
}
