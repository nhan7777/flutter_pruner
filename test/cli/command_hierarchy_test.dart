import 'dart:convert';
import 'dart:io';

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

      final root = await harness.run(
        const [],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );
      final bare = await harness.runQuarantineOnly(
        const ['quarantine'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\\n',
      );
      final explicit = await harness.runQuarantineOnly(
        const ['quarantine', '--help'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\\n',
      );

      final alias = await harness.run(
        const ['q', '--help'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );

      final bareAlias = await harness.run(
        const ['q'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );
      final helpAlias = await harness.run(
        const ['help', 'q'],
        workingDirectory: fixture.root,
        stdinText: 'must not be read\n',
      );

      for (final result in [
        root,
        bare,
        explicit,
        alias,
        bareAlias,
        helpAlias,
      ]) {
        expect(result.timedOut, isFalse);
        expect(result.exitCode, 0);
        expect(result.stderrBytes, isEmpty);
        expect(result.stdoutBytes, isNotEmpty);
        expectNoAnsi(result);
      }
      expect(bare.stdoutBytes, explicit.stdoutBytes);
      expect(alias.stdoutBytes, explicit.stdoutBytes);
      expect(bareAlias.stdoutBytes, explicit.stdoutBytes);
      expect(helpAlias.stdoutBytes, explicit.stdoutBytes);
      expect(root.stdoutText, contains('Available commands:'));
      expect(root.stdoutText, contains('quarantine   Manage quarantine'));
      expect(root.stdoutText, isNot(contains('\n  q ')));
      expect(explicit.stdoutText, contains('Available subcommands:'));
      expect(explicit.stdoutText, isNot(contains('--project')));
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
      final narrow = await harness.run(
        const ['scan', '--help'],
        workingDirectory: fixture.root,
        environmentAdditions: const {'COLUMNS': '20', 'NO_COLOR': '1'},
        stdinText: 'must not be read\n',
      );
      final wide = await harness.run(
        const ['scan', '--help'],
        workingDirectory: fixture.root,
        environmentAdditions: const {'COLUMNS': '200', 'NO_COLOR': '1'},
        stdinText: 'must not be read\n',
      );

      for (final result in [narrow, wide]) {
        expect(result.exitCode, 0);
        expect(result.stderrBytes, isEmpty);
        expectNoAnsi(result);
      }
      final narrowFixture = File('test/cli/fixtures/scan_help_columns_20.txt');
      expect(narrow.stdoutText, narrowFixture.readAsStringSync());
      expect(narrow.stdoutBytes, isNot(wide.stdoutBytes));
      expect(
        const LineSplitter()
            .convert(narrow.stdoutText)
            .every(
              (line) =>
                  line.runes.length <= 20 ||
                  line
                      .split(RegExp(r'\s+'))
                      .any((word) => word.runes.length > 20),
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

      for (final path in paths) {
        final fromHelp = await harness.run(
          ['help', ...path],
          workingDirectory: fixture.root,
          stdinText: 'must not be read\\n',
        );
        final fromFlag = await harness.run(
          [...path, '--help'],
          workingDirectory: fixture.root,
          stdinText: 'must not be read\\n',
        );

        for (final result in [fromHelp, fromFlag]) {
          expect(result.timedOut, isFalse, reason: path.join(' '));
          expect(result.exitCode, 0, reason: path.join(' '));
          expect(result.stderrBytes, isEmpty, reason: path.join(' '));
          expectNoAnsi(result);
        }
        expect(
          fromHelp.stdoutBytes,
          fromFlag.stdoutBytes,
          reason: path.join(' '),
        );
      }
      expect(_snapshotTree(fixture), before);
    },
    timeout: const Timeout(Duration(minutes: 7)),
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

      for (final testCase in cases) {
        final result = await harness.run(
          testCase.$1,
          workingDirectory: fixture.root,
          stdinText: 'must not be read\\n',
        );

        expect(result.exitCode, 64, reason: testCase.$1.join(' '));
        expect(result.stdoutBytes, isEmpty, reason: testCase.$1.join(' '));
        expect(result.stderrText, contains(testCase.$2));
        expectNoAnsi(result);
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
      '${entry.runtimeType}|${entry.path}|'
          '${entry is File ? base64Encode(entry.readAsBytesSync()) : ''}',
  ];
}
