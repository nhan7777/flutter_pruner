import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/core/process/managed_process_runner.dart'
    show PosixProcessTableSnapshot;
import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'cli_process_harness.dart';

const _rootHelp =
    '''Find unused assets, duplicate files and unreachable code in Flutter/Dart projects

Usage: flutter_pruner <command> [arguments]

Global options:
-h, --help       Print this usage information.
-v, --verbose    Show diagnostic output, including per-adapter timings
    --version    Print tool version and exit

Available commands:
  apply        Apply findings; rollback restores quarantined regular-file bytes and POSIX modes where available, subject to verification
  init         Create a conservative project-local Flutter Pruner configuration
  quarantine   Manage quarantine directories (alias: q)
  rollback     Restore files from quarantine and reverse an apply operation
  scan         Analyse without changing project sources; always saves a report

Run "flutter_pruner help <command>" for more information about a command.
Examples:
  flutter_pruner init
  flutter_pruner scan
  flutter_pruner scan --format json --output scan.json
  flutter_pruner apply --dry-run
  flutter_pruner quarantine list

Filesystem effects:
  init writes configuration and .gitignore
  scan and apply --dry-run may persist tool state or reports
  Only help and version are filesystem-read-only
''';

const _rootUsageWithoutDescription =
    '''Usage: flutter_pruner <command> [arguments]

Global options:
-h, --help       Print this usage information.
-v, --verbose    Show diagnostic output, including per-adapter timings
    --version    Print tool version and exit

Available commands:
  apply        Apply findings; rollback restores quarantined regular-file bytes and POSIX modes where available, subject to verification
  init         Create a conservative project-local Flutter Pruner configuration
  quarantine   Manage quarantine directories (alias: q)
  rollback     Restore files from quarantine and reverse an apply operation
  scan         Analyse without changing project sources; always saves a report

Run "flutter_pruner help <command>" for more information about a command.
Examples:
  flutter_pruner init
  flutter_pruner scan
  flutter_pruner scan --format json --output scan.json
  flutter_pruner apply --dry-run
  flutter_pruner quarantine list

Filesystem effects:
  init writes configuration and .gitignore
  scan and apply --dry-run may persist tool state or reports
  Only help and version are filesystem-read-only
''';

const _initHelp =
    '''Create a conservative project-local Flutter Pruner configuration

Usage: flutter_pruner init [arguments] [project-path]
-h, --help                Print this usage information.
    --type                Project shape; defaults to conservative filesystem detection
                          [application, package, package-internal]
    --entrypoint          Entrypoint relative to the project; may be passed more than once
    --platform            Target platform; may be passed more than once
                          [android, ios, web, macos, linux, windows]
    --complete            Assert every supported build target is declared
    --force               Replace existing Flutter Pruner configuration
    --[no-]interactive    Ask questions when attached to a terminal
                          (defaults to on)
    --yes                 Accept conservative detected defaults without prompting; does not assert complete coverage
-p, --project             Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner init
  flutter_pruner init --project ./example

Writes configuration and .gitignore
''';

const _scanHelp =
    '''Analyse without changing project sources; always saves a report

Usage: flutter_pruner scan [arguments] [project-path]
-h, --help            Print this usage information.
    --format          Saved report format; defaults to self-contained interactive HTML
                      [human, json, html (default)]
-o, --output          Override automatic .flutter_pruner/reports destination; absolute paths remain supported
    --json-version    JSON report schema; version 2 is legacy
                      [2, 3 (default)]
    --adapter         Run only these adapter IDs; defaults to all registered
    --config          Configuration path; relative paths start at selected project
-p, --project         Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner scan
  flutter_pruner scan --format json --output scan.json
  flutter_pruner scan --project ./example

Scan may persist tool state and reports
''';

const _applyHelp =
    '''Apply findings; rollback restores quarantined regular-file bytes and POSIX modes where available, subject to verification

Usage: flutter_pruner apply [arguments] [project-path]
-h, --help                          Print this usage information.
-n, --dry-run                       Preview dependency-closed plan without changing files
    --yes                           Accept package-internal external-consumer risk without prompting
    --adapter                       Run only these adapter IDs; defaults to all registered
    --finding-id                    Apply only these exact, case-sensitive finding IDs; repeat for an atomic batch
    --expect-preview-fingerprint    Require exact v1 preview fingerprint before verification or mutation
    --config                        Configuration path; relative paths start at selected project
    --quarantine                    Quarantine directory; defaults to .flutter_pruner/quarantine in the selected project
    --report-output                 Override automatic .flutter_pruner/reports destination; absolute paths remain supported
    --report-format                 Saved report format; defaults to HTML and also keeps canonical quarantine JSON
                                    [json, html (default)]
-p, --project                       Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner apply --dry-run
  flutter_pruner apply --finding-id dart:example/lib/main.dart#unusedFunction --finding-id dart:example/lib/main.dart#unusedClass --dry-run
  flutter_pruner apply --finding-id dart:example/lib/main.dart#unusedFunction --expect-preview-fingerprint v1:0000000000000000000000000000000000000000000000000000000000000000
  flutter_pruner apply --dry-run --format json --output apply.json

The preview fingerprint requires the same exact --finding-id selection
Apply, including --dry-run, may persist tool state and reports
--format and --output are aliases for --report-format and --report-output
''';

const _rollbackHelp =
    '''Restore files from quarantine and reverse an apply operation

Usage: flutter_pruner rollback [arguments] <run-id>
-h, --help          Print this usage information.
    --clean         Logically clean quarantine after a successful rollback; bytes remain retained
    --quarantine    Quarantine directory; defaults to .flutter_pruner/quarantine in the selected project
-p, --project       Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner rollback RUN_ID
  flutter_pruner rollback --project ./example RUN_ID
''';

const _quarantineHelp = '''Manage quarantine directories (alias: q)

Usage: flutter_pruner quarantine <subcommand> [arguments]
-h, --help    Print this usage information.

Available subcommands:
  clean      Logically clean quarantines while retaining recovery bytes
  inspect    Show quarantine manifest details
  list       List quarantines
  retained   Inspect or restore logically cleaned quarantines

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner quarantine list
  flutter_pruner quarantine inspect RUN_ID
  flutter_pruner quarantine clean RUN_ID --dry-run
''';

const _quarantineUsage =
    '''Usage: flutter_pruner quarantine <subcommand> [arguments]
-h, --help    Print this usage information.

Available subcommands:
  clean      Logically clean quarantines while retaining recovery bytes
  inspect    Show quarantine manifest details
  list       List quarantines
  retained   Inspect or restore logically cleaned quarantines

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner quarantine list
  flutter_pruner quarantine inspect RUN_ID
  flutter_pruner quarantine clean RUN_ID --dry-run
''';

const _quarantineListHelp = '''List quarantines

Usage: flutter_pruner quarantine list [arguments]
-h, --help          Print this usage information.
    --format        Output format
                    [human (default), json]
    --limit         Maximum quarantine entries to show
                    (defaults to "50")
    --quarantine    Quarantine directory; defaults to .flutter_pruner/quarantine in the selected project
-p, --project       Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner quarantine list
  flutter_pruner quarantine list --format json
''';

const _quarantineInspectHelp = '''Show quarantine manifest details

Usage: flutter_pruner quarantine inspect [arguments] <run-id>
-h, --help          Print this usage information.
    --format        Output format
                    [human (default), json]
    --quarantine    Quarantine directory; defaults to .flutter_pruner/quarantine in the selected project
-p, --project       Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner quarantine inspect RUN_ID
  flutter_pruner quarantine inspect RUN_ID --format json
''';

const _quarantineCleanHelp =
    '''Logically clean quarantines while retaining recovery bytes

Usage: flutter_pruner quarantine clean [arguments] [<run-id> | --all]
-h, --help                         Print this usage information.
    --all                          Logically clean all quarantines
    --dry-run                      Preview quarantine evidence without moving it
    --format                       Output format
                                   [human (default), json]
    --confirm-clean-fingerprint    Confirm full reviewed fingerprint for --all execution
    --quarantine                   Quarantine directory; defaults to .flutter_pruner/quarantine in the selected project
-p, --project                      Dart or Flutter project root; defaults to current directory

Run "flutter_pruner help" to see global options.
Examples:
  flutter_pruner quarantine clean RUN_ID --dry-run
  flutter_pruner quarantine clean --all --dry-run
  flutter_pruner quarantine clean --all --confirm-clean-fingerprint v2:0000000000000000000000000000000000000000000000000000000000000000

Clean-all:
  --all moves only terminal cleanable evidence into retained storage
  Run --dry-run before supplying --confirm-clean-fingerprint
  Current backend: recoverableLogicalMove
  Current backend is non-atomic, identity-bound, and crash-recoverable
  Physical bytes are retained; no disk space is reclaimed
  Release eligibility remains pending hosted evidence for CLEAN-TOCTOU-1
''';

void main() {
  const processTestTimeout = Timeout(Duration(minutes: 2));
  late CliProcessHarness harness;

  setUp(() {
    harness = CliProcessHarness.repository();
  });

  tearDown(() => harness.close());

  test(
    'baseline: real-process harness launches the package entrypoint',
    () async {
      final result = await harness.run(const ['--version']);

      expect(result.exitCode, 0);
      expect(
        result.stdoutText,
        'flutter_pruner 1.6.0${Platform.isWindows ? '\r\n' : '\n'}',
      );
      expect(result.stderrBytes, isEmpty);
      expectNoAnsi(result);
    },
    timeout: processTestTimeout,
  );

  final helpCases = <(List<String>, String)>[
    (const ['--help'], _rootHelp),
    (const ['init', '--help'], _initHelp),
    (const ['scan', '--help'], _scanHelp),
    (const ['apply', '--help'], _applyHelp),
    (const ['rollback', '--help'], _rollbackHelp),
    (const ['quarantine', '--help'], _quarantineHelp),
    (const ['quarantine', 'list', '--help'], _quarantineListHelp),
    (const ['quarantine', 'inspect', '--help'], _quarantineInspectHelp),
    (const ['quarantine', 'clean', '--help'], _quarantineCleanHelp),
  ];

  for (final helpCase in helpCases) {
    test(
      'baseline: ${helpCase.$1.join(' ')} stays a stdout-only help path',
      () async {
        final isInitHelp =
            helpCase.$1.length == 2 &&
            helpCase.$1[0] == 'init' &&
            helpCase.$1[1] == '--help';
        // The generic 45-second harness bound remains in force for all other
        // CLI contracts. This specific real process took 50+ seconds when 12
        // Dart VMs compiled concurrently, while retaining its exact stdout and
        // empty stderr contract. Match only this invocation to its enclosing
        // two-minute process-test deadline; early exit still resolves at once.
        final timeout = isInitHelp ? const Duration(minutes: 2) : null;
        final result = helpCase.$1.first == 'quarantine'
            ? await harness.runQuarantineOnly(helpCase.$1, timeout: timeout)
            : await harness.run(helpCase.$1, timeout: timeout);

        expect(result.timedOut, isFalse);
        expect(result.exitCode, 0);
        expect(result.stdoutBytes, utf8.encode(helpCase.$2));
        expect(result.stderrBytes, isEmpty);
        expectNoAnsi(result);
      },
      timeout: processTestTimeout,
    );
  }

  test(
    'bare root and bare quarantine render their own discoverable help',
    () async {
      final root = await harness.run(const []);
      final quarantine = await harness.runQuarantineOnly(const ['quarantine']);

      expect(root.exitCode, 0);
      expect(root.stdoutBytes, utf8.encode(_rootHelp));
      expect(root.stderrBytes, isEmpty);
      expect(quarantine.exitCode, 0);
      expect(quarantine.stdoutBytes, utf8.encode(_quarantineHelp));
      expect(quarantine.stderrBytes, isEmpty);
      expectNoAnsi(root);
      expectNoAnsi(quarantine);
    },
    timeout: processTestTimeout,
  );

  test(
    'help gives safe examples, side-effect disclosure, and current clean limitations',
    () async {
      final root = await harness.run(const ['--help']);
      final apply = await harness.run(const ['apply', '--help']);
      final clean = await harness.runQuarantineOnly(const [
        'quarantine',
        'clean',
        '--help',
      ]);

      expect(root.stdoutText, contains('Examples:\n  flutter_pruner init'));
      expect(root.stdoutText, contains('flutter_pruner apply --dry-run'));
      expect(
        root.stdoutText,
        contains('init writes configuration and .gitignore'),
      );
      expect(
        root.stdoutText,
        contains('scan and apply --dry-run may persist tool state or reports'),
      );
      expect(
        root.stdoutText,
        contains('Only help and version are filesystem-read-only'),
      );

      expect(apply.stdoutText, contains('flutter_pruner apply --dry-run'));
      expect(
        apply.stdoutText,
        contains('--finding-id dart:example/lib/main.dart#unusedFunction'),
      );
      expect(
        apply.stdoutText,
        contains('--expect-preview-fingerprint v1:${'0' * 64}'),
      );
      expect(apply.stdoutText, contains('same exact --finding-id selection'));

      expect(
        clean.stdoutText,
        contains('flutter_pruner quarantine clean --all --dry-run'),
      );
      expect(
        clean.stdoutText,
        contains(
          'moves only terminal cleanable evidence into retained storage',
        ),
      );
      expect(
        clean.stdoutText,
        contains('Run --dry-run before supplying --confirm-clean-fingerprint'),
      );
      expect(
        clean.stdoutText,
        contains('Release eligibility remains pending hosted evidence'),
      );
      expect(clean.stdoutText, contains('non-atomic, identity-bound'));
      expect(clean.stdoutText, contains('crash-recoverable'));
      expect(clean.stdoutText, contains('no disk space is reclaimed'));
    },
    timeout: processTestTimeout,
  );

  final usageFailures = <(List<String>, int, String)>[
    (
      const ['unknown'],
      64,
      'Error: Could not find a command named "unknown".\n\n$_rootUsageWithoutDescription',
    ),
    (
      const ['quarantine', 'missing'],
      64,
      'Error: Could not find a subcommand named "missing" for "flutter_pruner quarantine".\n\n$_quarantineUsage',
    ),
    (
      const ['--not-an-option'],
      64,
      'Error: Could not find an option named "--not-an-option".\n\n$_rootUsageWithoutDescription',
    ),
    (const ['rollback'], 64, 'Error: A run ID is required.\n\n$_rollbackHelp'),
    (
      const ['rollback', 'one', 'two'],
      64,
      'Error: A run ID is required.\n\n$_rollbackHelp',
    ),
    (
      const [
        'rollback',
        '--project',
        '/definitely/missing/q6-project',
        'one',
        'two',
      ],
      64,
      'Error: A run ID is required.\n\n$_rollbackHelp',
    ),
    (
      const ['rollback', '../bad'],
      64,
      'Error: Invalid run ID: ../bad\n\n$_rollbackHelp',
    ),
    (
      const ['quarantine', 'inspect'],
      64,
      'Error: A run ID is required.\n\n$_quarantineInspectHelp',
    ),
    (
      const ['quarantine', 'clean', '--all', 'run-id'],
      64,
      'Error: Do not combine --all with a quarantine run ID.\n\n$_quarantineCleanHelp',
    ),
  ];

  for (final failure in usageFailures) {
    test(
      'baseline: ${failure.$1.join(' ')} preserves stderr and exit status',
      () async {
        final result = await harness.run(failure.$1);

        expect(result.exitCode, failure.$2);
        expect(result.stdoutBytes, isEmpty);
        expect(result.stderrBytes, utf8.encode(failure.$3));
        expectNoAnsi(result);
      },
      timeout: processTestTimeout,
    );
  }

  final argvMisuseCases = <(String, List<String> Function(CliFixture), String, String)>[
    (
      'scan unknown flag',
      (_) => const ['scan', '--unknown-flag'],
      'Could not find an option named "--unknown-flag".',
      'Usage: flutter_pruner scan',
    ),
    (
      'scan duplicate project selector',
      (fixture) => ['scan', '--project', fixture.root.path, fixture.root.path],
      'Pass the project once, using either --project or [project-path].',
      'Usage: flutter_pruner scan',
    ),
    (
      'scan unknown adapter',
      (_) => const ['scan', '--adapter', 'not_registered'],
      'Unknown adapter id requested by --adapter: not_registered.',
      'Usage: flutter_pruner scan',
    ),
    (
      'rollback missing run ID',
      (_) => const ['rollback'],
      'A run ID is required.',
      'Usage: flutter_pruner rollback',
    ),
    (
      'quarantine clean mutually exclusive target selectors',
      (_) => const ['quarantine', 'clean', '--all', 'run-id'],
      'Do not combine --all with a quarantine run ID.',
      'Usage: flutter_pruner quarantine clean',
    ),
    (
      'apply malformed preview fingerprint',
      (_) => [
        'apply',
        '--expect-preview-fingerprint',
        'not-a-preview-fingerprint',
      ],
      'Preview fingerprint must use v1:<64 lowercase hex>.',
      'Usage: flutter_pruner apply',
    ),
    (
      'apply unknown adapter',
      (_) => const ['apply', '--adapter', 'not_registered'],
      'Unknown adapter id requested by --adapter: not_registered.',
      'Usage: flutter_pruner apply',
    ),
    (
      'quarantine clean malformed fingerprint',
      (_) => const [
        'quarantine',
        'clean',
        '--all',
        '--confirm-clean-fingerprint',
        'not-a-clean-fingerprint',
      ],
      '--confirm-clean-fingerprint must be a versioned lowercase SHA-256 fingerprint.',
      'Usage: flutter_pruner quarantine clean',
    ),
    (
      'quarantine list invalid limit',
      (_) => const ['quarantine', 'list', '--limit', '0'],
      '--limit must be a positive integer.',
      'Usage: flutter_pruner quarantine list',
    ),
    (
      'init interactive non-TTY',
      (fixture) => ['init', '--project', fixture.root.path, '--interactive'],
      '--interactive requires an attached terminal. Use --no-interactive for scripts and CI.',
      'Usage: flutter_pruner init',
    ),
    (
      'init interactive and yes',
      (fixture) => [
        'init',
        '--project',
        fixture.root.path,
        '--interactive',
        '--yes',
      ],
      '--interactive cannot be combined with --yes. Choose the wizard or conservative automatic defaults.',
      'Usage: flutter_pruner init',
    ),
  ];

  for (final misuse in argvMisuseCases) {
    test('exit taxonomy: ${misuse.$1} is usage before side effects', () async {
      final fixture = CliFixture.create(prefix: 'c2 argv misuse ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: c2_fixture\n',
      });
      final fixtureBefore = _snapshotTree(fixture.root);
      final repositoryBefore = _snapshotSelectedPaths(Directory.current, const [
        '.flutter_pruner',
        'flutter_pruner.yaml',
        '.gitignore',
      ]);

      final result = await harness.run(
        misuse.$2(fixture),
        workingDirectory: fixture.root,
        timeout: const Duration(seconds: 90),
      );

      expect(result.exitCode, 64);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrText, startsWith('Error: ${misuse.$3}\n\n'));
      if (misuse.$1.startsWith('scan') || misuse.$1.startsWith('apply')) {
        expect(result.stderrText, isNot(contains('--only')));
      }
      expect(result.stderrText, contains(misuse.$4));
      expectNoAnsi(result);
      expect(fixture.file('.flutter_pruner').existsSync(), isFalse);
      expect(fixture.file('flutter_pruner.yaml').existsSync(), isFalse);
      expect(fixture.file('.gitignore').existsSync(), isFalse);
      expect(_snapshotTree(fixture.root), fixtureBefore);
      expect(
        _snapshotSelectedPaths(Directory.current, const [
          '.flutter_pruner',
          'flutter_pruner.yaml',
          '.gitignore',
        ]),
        repositoryBefore,
      );
    }, timeout: processTestTimeout);
  }

  test(
    'exit taxonomy: invalid report output is an operational failure without an escaped write',
    () async {
      final fixture = CliFixture.create(prefix: 'c2 invalid output ');
      addTearDown(fixture.dispose);
      final outsideReport = File(
        '${fixture.root.parent.path}${Platform.pathSeparator}'
        'c2-outside-report-${DateTime.now().microsecondsSinceEpoch}.json',
      );

      final result = await harness.run([
        'scan',
        '--project',
        fixture.root.path,
        '--output',
        '../${outsideReport.uri.pathSegments.last}',
      ], timeout: const Duration(seconds: 90));

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      expect(
        result.stderrText,
        startsWith(
          'Error: Relative report path escapes .flutter_pruner/reports:',
        ),
      );
      expectNoAnsi(result);
      expect(fixture.file('.flutter_pruner').existsSync(), isFalse);
      expect(outsideReport.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'scan and apply keep machine evidence in equivalent saved reports',
    () async {
      final fixture = CliFixture.create(prefix: 'c7 apply report aliases ');
      addTearDown(fixture.dispose);
      final project = Directory(p.join(fixture.root.path, 'project'));
      await fixture.writeText(<String, String>{
        'project/pubspec.yaml': '''
name: c7_apply_report_aliases
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'project/.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[{"name":"c7_apply_report_aliases","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}]}
''',
        'project/.flutter_pruner/config.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
        'project/lib/main.dart': 'void main() {}\n',
      });
      final source = fixture.file('project/lib/main.dart');
      final originalSourceBytes = source.readAsBytesSync();
      final scanReport = fixture.file('project/scan-report.json');
      final legacyReport = fixture.file('project/legacy-report.json');
      final aliasReport = fixture.file('project/alias-report.json');

      final scan = await harness.run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        scanReport.path,
        project.path,
      ], timeout: const Duration(seconds: 90));

      final legacy = await harness.run([
        'apply',
        '--dry-run',
        '--adapter',
        'dart',
        '--report-format',
        'json',
        '--report-output',
        legacyReport.path,
        project.path,
      ], timeout: const Duration(seconds: 90));
      final alias = await harness.run([
        'apply',
        '--dry-run',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        aliasReport.path,
        project.path,
      ], timeout: const Duration(seconds: 90));

      expect(scan.exitCode, 0, reason: scan.stderrText);
      expect(scan.stderrText, contains('\x1B['));
      expect(scan.stderrText, isNot(contains('\r')));
      expect(scan.stderrText, isNot(contains('\x1B[2K')));
      expect(scan.stdoutText, contains('\x1B['));
      expect(scan.stdoutText, contains('SCAN COMPLETED'));
      expect(scan.stdoutText, contains(scanReport.resolveSymbolicLinksSync()));
      expect(() => jsonDecode(scan.stdoutText), throwsFormatException);
      expect(scanReport.existsSync(), isTrue);
      final scanEvidence =
          jsonDecode(scanReport.readAsStringSync()) as Map<String, dynamic>;
      expect((scanEvidence['run'] as Map)['command'], 'scan');
      expect((scanEvidence['run'] as Map)['status'], 'completed');
      expect((scanEvidence['run'] as Map)['exitCode'], 0);

      for (final result in [legacy, alias]) {
        expect(result.exitCode, 0, reason: result.stderrText);
        expect(result.stderrText, contains('\x1B['));
        expect(result.stderrText, isNot(contains('\r')));
        expect(result.stderrText, isNot(contains('\x1B[2K')));
        expect(result.stdoutText, contains('\x1B['));
        expect(result.stdoutText, contains('APPLY NO CHANGES'));
        expect(() => jsonDecode(result.stdoutText), throwsFormatException);
      }
      expect(
        legacy.stdoutText,
        contains(legacyReport.resolveSymbolicLinksSync()),
      );
      expect(
        alias.stdoutText,
        contains(aliasReport.resolveSymbolicLinksSync()),
      );
      expect(legacyReport.existsSync(), isTrue);
      expect(aliasReport.existsSync(), isTrue);
      final legacyEvidence =
          jsonDecode(legacyReport.readAsStringSync()) as Map<String, dynamic>;
      final aliasEvidence =
          jsonDecode(aliasReport.readAsStringSync()) as Map<String, dynamic>;
      expect(
        _stableReportEvidence(legacyEvidence),
        _stableReportEvidence(aliasEvidence),
      );
      expect((legacyEvidence['run'] as Map)['command'], 'apply');
      expect((legacyEvidence['run'] as Map)['status'], 'noChanges');
      expect((legacyEvidence['run'] as Map)['exitCode'], 0);
      expect(source.readAsBytesSync(), orderedEquals(originalSourceBytes));
      expect(
        Directory(
          p.join(project.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      await _expectOperationLockReleased(project);
    },
    timeout: processTestTimeout,
  );

  test(
    'process outcome matrix freezes streams exits and filesystem evidence',
    () async {
      Future<CliFixture> projectFixture(String name) async {
        final fixture = CliFixture.create(prefix: 'c7 matrix $name ');
        addTearDown(fixture.dispose);
        await fixture.writeText(<String, String>{
          'pubspec.yaml': 'name: c7_matrix_$name\n',
        });
        return fixture;
      }

      final successFixture = await projectFixture('success');
      final successManager = QuarantineManager(successFixture.root);
      final successBase = Directory(
        p.join(
          successFixture.root.path,
          QuarantineManager.defaultQuarantineDir,
        ),
      );
      final successQuarantine = await successManager.createQuarantine(
        runId: 'success-run',
        entries: const <QuarantineEntry>[],
      );
      final successPath = successQuarantine.resolveSymbolicLinksSync();
      final successPlan = await successManager.planCleanQuarantine(
        runId: 'success-run',
        quarantineBases: [successBase],
      );
      final success = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        successFixture.root.path,
        '--quarantine',
        successBase.path,
        '--format',
        'json',
        'success-run',
      ]);
      final expectedSuccess = <String, Object?>{
        'schemaVersion': 1,
        'kind': 'quarantineCleanResult',
        'fingerprint': successPlan.fingerprint,
        'deletionAttempted': true,
        'complete': true,
        'receiptCrashDurable': false,
        'outcomes': <Object?>[
          <String, Object?>{
            'runId': 'success-run',
            'canonicalPath': successPath,
            'state': 'removed',
          },
        ],
      };
      expect(success.exitCode, 0);
      expect(success.stdoutText, jsonEncode(expectedSuccess));
      expect(success.stderrBytes, isEmpty);
      expectJsonStdout(success, equals(expectedSuccess));
      expectNoAnsi(success);
      expect(successQuarantine.existsSync(), isFalse);
      _expectNoReportArtifacts(successFixture.root);
      await _expectOperationLockReleased(successFixture.root);

      final noChangesFixture = await projectFixture('no_changes');
      final noChangesManager = QuarantineManager(noChangesFixture.root);
      final noChangesBase = Directory(
        p.join(
          noChangesFixture.root.path,
          QuarantineManager.defaultQuarantineDir,
        ),
      );
      final noChangesPlan = await noChangesManager.planCleanQuarantine(
        quarantineBases: [noChangesBase],
      );
      final noChanges = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        noChangesFixture.root.path,
        '--quarantine',
        noChangesBase.path,
        '--all',
        '--dry-run',
        '--format',
        'json',
      ]);
      final expectedNoChanges = _cleanPlanJson(noChangesPlan);
      expect(noChanges.exitCode, 0);
      expect(noChanges.stdoutText, jsonEncode(expectedNoChanges));
      expect(noChanges.stderrBytes, isEmpty);
      expectJsonStdout(noChanges, equals(expectedNoChanges));
      expectNoAnsi(noChanges);
      expect(noChangesBase.existsSync(), isFalse);
      _expectNoReportArtifacts(noChangesFixture.root);
      expect(
        ToolWorkspace(noChangesFixture.root).operationLockFile.existsSync(),
        isFalse,
      );

      final cancelFixture = await projectFixture('cancel');
      final cancelManager = QuarantineManager(cancelFixture.root);
      final cancelBase = Directory(
        p.join(cancelFixture.root.path, QuarantineManager.defaultQuarantineDir),
      );
      final cancelQuarantine = await cancelManager.createQuarantine(
        runId: 'cancel-run',
        entries: const <QuarantineEntry>[],
      );
      final cancelManifest = File(
        p.join(cancelQuarantine.path, 'manifest.json'),
      );
      final originalCancelManifest = cancelManifest.readAsBytesSync();
      final cancelPlan = await cancelManager.planCleanQuarantine(
        quarantineBases: [cancelBase],
      );
      final cancelEvents = cancelFixture.file('delete.events');
      final cancel = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          cancelFixture.root.path,
          '--quarantine',
          cancelBase.path,
          '--all',
        ],
        stdinText: 'y\n',
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_TTY': '1',
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': cancelEvents.path,
        },
      );
      expect(cancel.exitCode, 0);
      expect(cancel.stdoutText, _cancelledCleanTranscript(cancelPlan));
      expect(cancel.stderrBytes, isEmpty);
      expect(cancel.stdoutText, contains('\x1B['));
      expect(cancel.stdoutText, isNot(contains('\r')));
      expect(cancel.stdoutText, isNot(contains('\x1B[2K')));
      expect(cancelEvents.existsSync(), isFalse);
      expect(cancelManifest.readAsBytesSync(), originalCancelManifest);
      _expectNoReportArtifacts(cancelFixture.root);
      await _expectOperationLockReleased(cancelFixture.root);

      final operationalFixture = await projectFixture('operational');
      final missingProject = operationalFixture.file('missing-project');
      final operational = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        missingProject.path,
      ]);
      expect(operational.exitCode, 1);
      expect(operational.stdoutBytes, isEmpty);
      expect(
        operational.stderrText,
        'Error: Directory not found: ${missingProject.path}\n',
      );
      expectNoAnsi(operational);
      expect(operationalFixture.file('.flutter_pruner').existsSync(), isFalse);

      final safeStopFixture = await projectFixture('safe_stop');
      final safeStopManager = QuarantineManager(safeStopFixture.root);
      final safeStopBase = Directory(
        p.join(
          safeStopFixture.root.path,
          QuarantineManager.defaultQuarantineDir,
        ),
      );
      final safeStopQuarantine = await safeStopManager.createQuarantine(
        runId: 'safe-stop-run',
        entries: const <QuarantineEntry>[],
      );
      final safeStopManifest = File(
        p.join(safeStopQuarantine.path, 'manifest.json'),
      );
      final originalSafeStopManifest = safeStopManifest.readAsBytesSync();
      final safeStopEvents = safeStopFixture.file('delete.events');
      final safeStop = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          safeStopFixture.root.path,
          '--quarantine',
          safeStopBase.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          'v1:${'0' * 64}',
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': safeStopEvents.path,
        },
      );
      expect(safeStop.exitCode, 2);
      expect(safeStop.stdoutBytes, isEmpty);
      expect(
        safeStop.stderrText,
        'Error: quarantine clean evidence is stale; run --dry-run again.\n',
      );
      expectNoAnsi(safeStop);
      expect(safeStopEvents.existsSync(), isFalse);
      expect(safeStopManifest.readAsBytesSync(), originalSafeStopManifest);
      _expectNoReportArtifacts(safeStopFixture.root);
      await _expectOperationLockReleased(safeStopFixture.root);

      final usageFixture = await projectFixture('usage');
      final usage = await harness.run(const [
        '--not-an-option',
      ], workingDirectory: usageFixture.root);
      expect(usage.exitCode, 64);
      expect(usage.stdoutBytes, isEmpty);
      expect(
        usage.stderrText,
        'Error: Could not find an option named "--not-an-option".\n\n'
        '$_rootUsageWithoutDescription',
      );
      expectNoAnsi(usage);
      expect(usageFixture.file('.flutter_pruner').existsSync(), isFalse);

      final internalFixture = await projectFixture('internal');
      final internalManager = QuarantineManager(internalFixture.root);
      final internalBase = Directory(
        p.join(
          internalFixture.root.path,
          QuarantineManager.defaultQuarantineDir,
        ),
      );
      final internalQuarantine = await internalManager.createQuarantine(
        runId: 'internal-run',
        entries: const <QuarantineEntry>[],
      );
      final internalManifest = File(
        p.join(internalQuarantine.path, 'manifest.json'),
      );
      final originalInternalManifest = internalManifest.readAsBytesSync();
      final internalPlan = await internalManager.planCleanQuarantine(
        quarantineBases: [internalBase],
      );
      final internalEvents = internalFixture.file('delete.events');
      final internal = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          internalFixture.root.path,
          '--quarantine',
          internalBase.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          internalPlan.fingerprint,
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_CALL': '3',
          'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_KIND': 'state_error',
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': internalEvents.path,
        },
      );
      expect(internal.exitCode, 70);
      expect(internal.stdoutBytes, isEmpty);
      expect(
        internal.stderrText,
        'Internal error: Bad state: Injected clean-plan programmer error.\n',
      );
      expectNoAnsi(internal);
      expect(internalEvents.existsSync(), isFalse);
      expect(internalManifest.readAsBytesSync(), originalInternalManifest);
      _expectNoReportArtifacts(internalFixture.root);
      await _expectOperationLockReleased(internalFixture.root);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'failure reports keep saved and not-saved stream contracts in real processes',
    () async {
      final fixture = CliFixture.create(prefix: 'c6 failure report ');
      addTearDown(fixture.dispose);
      final project = Directory(p.join(fixture.root.path, 'project'));
      final driver = fixture.file('failure_driver.dart');
      final marker = fixture.file('formatter-writes.txt');
      await fixture.writeText(<String, String>{
        'failure_driver.dart': r'''
import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/scan_command.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';

final class ThrowingAnalyzer extends ProjectAnalyzer {
  ThrowingAnalyzer({required super.project, super.only});

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final adapter = adapters.single;
    onAdapter?.call(adapter);
    onAdapterFinished?.call(adapter, AdapterRunStatus.failed);
    throw StateError('raw process analyzer exception');
  }
}

final class PostAdapterThrowingAnalyzer extends ProjectAnalyzer {
  PostAdapterThrowingAnalyzer({required super.project, super.only});

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    throw StateError('raw process post-adapter exception');
  }
}

final class FailingJsonFormatter extends JsonFormatter {
  FailingJsonFormatter({required super.version, required this.markerPath});

  final String markerPath;

  @override
  void writeTo(RunReport report, StringSink sink) {
    File(markerPath).writeAsStringSync(
      'write\n',
      mode: FileMode.append,
      flush: true,
    );
    throw StateError('injected process report writer failure');
  }
}

Future<void> main(List<String> arguments) async {
  final failWrite = Platform.environment['C6_FAIL_REPORT_WRITE'] == '1';
  final failAfterAdapter =
      Platform.environment['C6_FAIL_AFTER_ADAPTER'] == '1';
  final markerPath = Platform.environment['C6_REPORT_WRITE_MARKER']!;
  final runner = FlutterPrunerCommandRunner(
    scanCommandFactory: () => ScanCommand(
      analyzerFactory: (project, only) => failAfterAdapter
          ? PostAdapterThrowingAnalyzer(project: project, only: only)
          : ThrowingAnalyzer(project: project, only: only),
      jsonFormatterFactory: failWrite
          ? (version) => FailingJsonFormatter(
              version: version,
              markerPath: markerPath,
            )
          : (version) => JsonFormatter(version: version),
    ),
  );
  exit(await runner.run(arguments));
}
''',
        'project/pubspec.yaml': '''
name: c6_failure_report
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'project/.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[{"name":"c6_failure_report","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}]}
''',
        'project/.flutter_pruner/config.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
        'project/lib/main.dart': 'void main() {}\n',
      });
      final originalSource = File(
        p.join(project.path, 'lib', 'main.dart'),
      ).readAsBytesSync();
      final saved = File(p.join(project.path, 'saved-failure.json'));
      final incompatibleV2 = File(
        p.join(project.path, 'not-saved-v2-failure.json'),
      );
      final postAdapter = File(
        p.join(project.path, 'saved-post-adapter-failure.json'),
      );
      final human = File(p.join(project.path, 'saved-human-failure.txt'));
      final notSaved = File(p.join(project.path, 'not-saved-failure.json'));
      List<FileSystemEntity> transactionArtifacts(File output) => output.parent
          .listSync(followLinks: false)
          .where(
            (entity) =>
                p.basename(entity.path).contains('.tmp') ||
                p.basename(entity.path).contains('.previous'),
          )
          .toList(growable: false);

      final savedResult = await harness.run(
        [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'json',
          '--output',
          saved.path,
          project.path,
        ],
        entrypointOverride: driver,
        environmentAdditions: {'C6_REPORT_WRITE_MARKER': marker.path},
        timeout: const Duration(seconds: 90),
      );

      expect(savedResult.exitCode, 70);
      expect(savedResult.stdoutBytes, isEmpty);
      expect(
        savedResult.stderrText,
        contains(
          'Error: Analysis failed after adapter Dart declaration analyzer '
          '(dart) started.',
        ),
      );
      expect(
        savedResult.stderrText,
        contains('Failure report saved: ${saved.resolveSymbolicLinksSync()}'),
      );
      expect(savedResult.stderrText, isNot(contains('report was not saved')));
      expect(
        savedResult.stderrText,
        isNot(contains('raw process analyzer exception')),
      );
      final savedReport =
          jsonDecode(saved.readAsStringSync()) as Map<String, dynamic>;
      expect((savedReport['run'] as Map)['status'], 'internalError');
      expect((savedReport['run'] as Map)['exitCode'], 70);
      expect(savedReport['findings'], isEmpty);
      expect(
        File(
          p.join(saved.parent.path, '.${p.basename(saved.path)}.commit.json'),
        ).existsSync(),
        isTrue,
      );
      expect(transactionArtifacts(saved), isEmpty);

      final incompatibleV2Result = await harness.run(
        [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'json',
          '--json-version',
          '2',
          '--output',
          incompatibleV2.path,
          project.path,
        ],
        entrypointOverride: driver,
        environmentAdditions: {'C6_REPORT_WRITE_MARKER': marker.path},
        timeout: const Duration(seconds: 90),
      );

      expect(incompatibleV2Result.exitCode, 70);
      expect(incompatibleV2Result.stdoutBytes, isEmpty);
      expect(
        incompatibleV2Result.stderrText,
        contains(
          'Error: Analysis failed after adapter Dart declaration analyzer '
          '(dart) started.',
        ),
      );
      expect(
        incompatibleV2Result.stderrText,
        contains(
          'report was not saved: JSON v2 cannot represent failed run reports. '
          'Use --json-version 3.',
        ),
      );
      expect(
        incompatibleV2Result.stderrText,
        isNot(contains('Failure report saved:')),
      );
      expect(
        incompatibleV2Result.stderrText,
        isNot(contains('raw process analyzer exception')),
      );
      expect(incompatibleV2Result.stderrText, isNot(contains('.tmp')));
      expect(incompatibleV2Result.stderrText, isNot(contains('.previous')));
      expect(incompatibleV2.existsSync(), isFalse);
      expect(
        File(
          p.join(
            incompatibleV2.parent.path,
            '.${p.basename(incompatibleV2.path)}.commit.json',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(transactionArtifacts(incompatibleV2), isEmpty);
      expect(marker.existsSync(), isFalse);

      final postAdapterResult = await harness.run(
        [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'json',
          '--output',
          postAdapter.path,
          project.path,
        ],
        entrypointOverride: driver,
        environmentAdditions: {
          'C6_FAIL_AFTER_ADAPTER': '1',
          'C6_REPORT_WRITE_MARKER': marker.path,
        },
        timeout: const Duration(seconds: 90),
      );

      expect(postAdapterResult.exitCode, 70);
      expect(postAdapterResult.stdoutBytes, isEmpty);
      expect(
        postAdapterResult.stderrText,
        contains('Error: Project analysis did not complete.'),
      );
      expect(
        postAdapterResult.stderrText,
        isNot(contains('Analysis failed after adapter')),
      );
      expect(
        postAdapterResult.stderrText,
        isNot(contains('raw process post-adapter exception')),
      );
      expect(
        postAdapterResult.stderrText,
        contains(
          'Failure report saved: ${postAdapter.resolveSymbolicLinksSync()}',
        ),
      );
      final postAdapterReport =
          jsonDecode(postAdapter.readAsStringSync()) as Map<String, dynamic>;
      expect(
        (postAdapterReport['diagnostics'] as List)
            .cast<Map<String, dynamic>>()
            .single,
        {
          'code': 'analysis_failed',
          'message': 'Project analysis did not complete.',
          'phase': 'analysis',
        },
      );
      expect(transactionArtifacts(postAdapter), isEmpty);
      expect(marker.existsSync(), isFalse);

      final humanResult = await harness.run(
        [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'human',
          '--output',
          human.path,
          project.path,
        ],
        entrypointOverride: driver,
        environmentAdditions: {'C6_REPORT_WRITE_MARKER': marker.path},
        timeout: const Duration(seconds: 90),
      );

      expect(humanResult.exitCode, 70);
      expect(humanResult.stdoutBytes, isEmpty);
      expect(
        humanResult.stderrText,
        contains('Failure report saved: ${human.resolveSymbolicLinksSync()}'),
      );
      expect(humanResult.stderrText, isNot(contains('report was not saved')));
      expect(
        humanResult.stderrText,
        isNot(contains('raw process analyzer exception')),
      );
      expect(human.existsSync(), isTrue);
      final humanReport = human.readAsStringSync().replaceAll(
        RegExp(r'\x1B\[[0-9;]*m'),
        '',
      );
      expect(humanReport, contains('✕ SCAN FAILED'));
      expect(humanReport, contains('status internalError'));
      expect(humanReport, contains('exit 70'));
      expect(humanReport, contains('adapter_analysis_failed'));
      expect(
        humanReport,
        contains(
          'Analysis failed after adapter Dart declaration analyzer (dart) '
          'started.',
        ),
      );
      expect(humanReport, isNot(contains('raw process analyzer exception')));
      expect(humanReport, isNot(contains('✓')));
      expect(humanReport, isNot(contains('SCAN COMPLETED')));
      expect(humanReport, isNot(contains('No unused candidates')));
      expect(
        File(
          p.join(human.parent.path, '.${p.basename(human.path)}.commit.json'),
        ).existsSync(),
        isTrue,
      );
      expect(transactionArtifacts(human), isEmpty);
      expect(marker.existsSync(), isFalse);

      final notSavedResult = await harness.run(
        [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'json',
          '--output',
          notSaved.path,
          project.path,
        ],
        entrypointOverride: driver,
        environmentAdditions: {
          'C6_FAIL_REPORT_WRITE': '1',
          'C6_REPORT_WRITE_MARKER': marker.path,
        },
        timeout: const Duration(seconds: 90),
      );

      expect(notSavedResult.exitCode, 70);
      expect(notSavedResult.stdoutBytes, isEmpty);
      expect(
        notSavedResult.stderrText,
        contains(
          'Error: Analysis failed after adapter Dart declaration analyzer '
          '(dart) started.',
        ),
      );
      expect(notSavedResult.stderrText, contains('report was not saved'));
      expect(
        notSavedResult.stderrText,
        isNot(contains('Failure report saved:')),
      );
      expect(
        notSavedResult.stderrText,
        isNot(contains('raw process analyzer exception')),
      );
      expect(marker.readAsLinesSync(), ['write']);
      expect(notSaved.existsSync(), isTrue);
      expect(notSaved.lengthSync(), 0);
      expect(
        File(
          p.join(
            notSaved.parent.path,
            '.${p.basename(notSaved.path)}.commit.json',
          ),
        ).existsSync(),
        isFalse,
      );
      expect(transactionArtifacts(notSaved), isEmpty);
      expect(
        File(p.join(project.path, 'lib', 'main.dart')).readAsBytesSync(),
        orderedEquals(originalSource),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'exit taxonomy: missing selected project is an operational failure',
    () async {
      final fixture = CliFixture.create(prefix: 'c1 missing project ');
      addTearDown(fixture.dispose);
      final missingProject = fixture.file('does-not-exist');

      final result = await harness.run([
        'quarantine',
        'list',
        '--project',
        missingProject.path,
      ], timeout: const Duration(seconds: 90));

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      expect(
        result.stderrBytes,
        utf8.encode('Error: Directory not found: ${missingProject.path}\n'),
      );
      expectNoAnsi(result);
    },
    timeout: processTestTimeout,
  );

  test(
    'rollback recovery escapes hostile project paths in the real process',
    () async {
      final fixture = CliFixture.create(prefix: 'q6 hostile ');
      addTearDown(fixture.dispose);
      final hostileName = Platform.isWindows
          ? "hostile' Rollback verified\u061c\u200e\u200f"
                '\u202a\u202e\u2066\u2069'
          : "hostile'\nRollback: verified\x1b\t\x7f\u0085\u009b\u061c\u200e\u200f"
                '\u2028\u2029\u202a\u202e\u2066\u2069';
      final project = Directory(
        '${fixture.root.path}${Platform.pathSeparator}$hostileName',
      )..createSync(recursive: true);
      File(
        '${project.path}${Platform.pathSeparator}pubspec.yaml',
      ).writeAsStringSync('name: hostile_rollback\n');
      final quarantine = Directory(
        '${project.path}${Platform.pathSeparator}.flutter_pruner'
        '${Platform.pathSeparator}quarantine'
        '${Platform.pathSeparator}hostile-run',
      )..createSync(recursive: true);
      File(
        '${quarantine.path}${Platform.pathSeparator}manifest.json',
      ).writeAsStringSync('{invalid');

      final result = await harness.run([
        'rollback',
        '--clean',
        '--project',
        project.path,
        'hostile-run',
      ]);

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrText, contains('ROLLBACK RECOVERY REQUIRED'));
      expect(
        result.stderrText,
        contains('Failure: manifest could not be read.'),
      );
      expect(
        result.stderrText,
        contains(
          Platform.isWindows
              ? r"hostile' Rollback verified\u061C\u200E"
              : r"hostile'\nRollback: verified\x1B\t",
        ),
      );
      if (!Platform.isWindows) {
        expect(result.stderrText, contains(r'\x7F'));
      }
      final lines = const LineSplitter().convert(result.stderrText);
      final argvLabel = lines.indexOf(
        'Exact action argv (JSON; invoke without a shell):',
      );
      expect(argvLabel, greaterThanOrEqualTo(0));
      expect(
        (jsonDecode(lines[argvLabel + 1]) as List<dynamic>).cast<String>(),
        <String>[
          'flutter_pruner',
          'quarantine',
          'inspect',
          '--project',
          project.path,
          '--quarantine',
          quarantine.parent.path,
          'hostile-run',
        ],
      );
      for (final unsafe in const [
        '\x1b',
        '\t',
        '\x7f',
        '\u0085',
        '\u009b',
        '\u061c',
        '\u200e',
        '\u200f',
        '\u2028',
        '\u2029',
        '\u202a',
        '\u202e',
        '\u2066',
        '\u2069',
      ]) {
        expect(result.stderrText, isNot(contains(unsafe)));
      }
      expect(result.stderrText, isNot(contains('\nRollback: verified\x1b')));
      expectNoAnsi(result);
    },
    timeout: processTestTimeout,
  );

  test(
    'baseline: help consumes EOF and benign stdin without blocking',
    () async {
      final eof = await harness.run(const [
        '--help',
      ], timeout: const Duration(seconds: 45));
      final payload = await harness.run(
        const ['--help'],
        stdinText: 'not an interactive answer\n',
        timeout: const Duration(seconds: 45),
      );

      for (final result in [eof, payload]) {
        expect(result.exitCode, 0);
        expect(result.timedOut, isFalse);
        expect(result.stdoutBytes, utf8.encode(_rootHelp));
        expect(result.stderrBytes, isEmpty);
      }
    },
    timeout: processTestTimeout,
  );

  test('harness: fixture paths are literal and deterministic', () async {
    final fixture = CliFixture.create(prefix: 'w0b fixture ');
    addTearDown(fixture.dispose);
    const names = <String>[
      'lib/main.dart',
      'lib/generated/companion.g.dart',
      'assets/2.0x/icon.png',
      'assets/empty.bin',
      "odd/a space and ' apostrophe.dart",
      r'odd/literal $().dart',
      'odd/backtick`semi;and&.dart',
      'odd/CJK-漢字.dart',
      'odd/combining-é.dart',
      'odd/emoji-😀.dart',
    ];
    await fixture.writeText(<String, String>{
      for (final name in names)
        name: name.endsWith('empty.bin') ? '' : 'void main() {}\n',
    });

    expect(
      names.map(fixture.file),
      everyElement(predicate((File file) => file.existsSync())),
    );
    expect(fixture.file('assets/empty.bin').lengthSync(), 0);
    expect(() => fixture.file('../outside.dart'), throwsArgumentError);
  }, timeout: processTestTimeout);

  test(
    'harness: explicit entrypoint observes cwd and controlled environment',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final observer = fixture.file('observe.dart');
      await fixture.writeText(<String, String>{
        'observe.dart': '''
import 'dart:convert';
import 'dart:io';
void main() => stdout.write(jsonEncode({
  'cwd': Directory.current.path,
  'added': Platform.environment['W0B_ADDED'],
  'removedPresent': Platform.environment.containsKey('W0B_REMOVAL_PROBE'),
}));
''',
      });

      final result = await harness.run(
        const [],
        entrypointOverride: observer,
        workingDirectory: fixture.root,
        environmentAdditions: const {
          'W0B_ADDED': 'controlled',
          'W0B_REMOVAL_PROBE': 'remove-me',
        },
        environmentRemovals: const {'W0B_REMOVAL_PROBE'},
      );

      final observed = jsonDecode(result.stdoutText) as Map<String, dynamic>;
      expect(
        observed['cwd'],
        Platform.isWindows
            ? fixture.root.path
            : fixture.root.resolveSymbolicLinksSync(),
      );
      expect(observed['added'], 'controlled');
      expect(observed['removedPresent'], isFalse);
      expect(result.stderrBytes, isEmpty);
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: JSON helper rejects prefix contamination without trimming',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'json.dart':
            "import 'dart:io'; void main() => stdout.write('{\\\"ok\\\":true}');",
        'contaminated.dart':
            "import 'dart:io'; void main() => stdout.write('note\\n{\\\"ok\\\":true}');",
      });

      final json = await harness.run(
        const [],
        entrypointOverride: fixture.file('json.dart'),
      );
      final contaminated = await harness.run(
        const [],
        entrypointOverride: fixture.file('contaminated.dart'),
      );

      expectJsonStdout(json, equals({'ok': true}));
      expect(() => expectJsonStdout(contaminated, anything), throwsA(anything));
    },
    timeout: processTestTimeout,
  );

  test('harness: rejects JSON suffixes and accepts non-ANSI Unicode', () {
    CliProcessResult result(List<int> bytes) => CliProcessResult(
      argv: const [],
      processId: 0,
      exitCode: 0,
      timedOut: false,
      elapsed: Duration.zero,
      stdoutBytes: bytes,
      stderrBytes: const [],
      readyFile: null,
      releaseFile: null,
    );
    expectNoAnsi(result(utf8.encode('Û')));
    expect(
      () =>
          expectJsonStdout(result(utf8.encode('{"ok":true} suffix')), anything),
      throwsA(anything),
    );
    expect(() => result([0xff]).stdoutText, throwsFormatException);
  });

  test(
    'harness: default POSIX tracking cleans a descendant after timeout',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final release = fixture.file('release');
      final childPid = fixture.file('child.pid');
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  while (!File(args[1]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2]]);
  while (!File(args[1]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  File(args[3]).writeAsStringSync('ready');
  while (!File(args[2]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
''',
      });

      CliProcessResult? result;
      Object? failure;
      var childGone = false;
      try {
        result = await harness.run(
          [
            fixture.file('child.dart').path,
            childPid.path,
            release.path,
            ready.path,
          ],
          entrypointOverride: fixture.file('parent.dart'),
          readyFile: ready,
          releaseFile: release,
          timeout: const Duration(seconds: 15),
          timeoutAfterReady: const Duration(seconds: 1),
        );
      } catch (error) {
        failure = error;
      } finally {
        if (childPid.existsSync()) {
          final child = int.parse(childPid.readAsStringSync());
          childGone = await _waitForPidToDisappear(child);
          if (!childGone) {
            await release.writeAsString('release');
            await _waitForPidToDisappear(child);
          }
        }
      }

      expect(failure, isNull, reason: 'Unexpected harness failure: $failure');
      expect(result, isNotNull);
      expect(result!.timedOut, isTrue);
      expect(childGone, isTrue);
      expect(harness.activeInvocationCount, 0);
    },
    timeout: processTestTimeout,
  );

  test('harness: JSON is raw-exact, stdin bytes stay unmodified', () async {
    final fixture = CliFixture.create();
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'stdin.dart': '''
import 'dart:convert';
import 'dart:io';
Future<void> main() async {
  final input = await stdin.fold<List<int>>(<int>[], (all, chunk) => all..addAll(chunk));
  stdout.write(jsonEncode(input));
}
''',
      'prefix.dart':
          "import 'dart:io'; void main() => stdout.write('x{\\\"ok\\\":true}');",
      'suffix.dart':
          "import 'dart:io'; void main() => stdout.write('{\\\"ok\\\":true}x');",
    });

    final stdin = await harness.run(
      const [],
      entrypointOverride: fixture.file('stdin.dart'),
      stdinBytes: const [0, 127, 128, 255],
    );
    final prefix = await harness.run(
      const [],
      entrypointOverride: fixture.file('prefix.dart'),
    );
    final suffix = await harness.run(
      const [],
      entrypointOverride: fixture.file('suffix.dart'),
    );

    expectJsonStdout(stdin, equals([0, 127, 128, 255]));
    expect(() => expectJsonStdout(prefix, anything), throwsA(anything));
    expect(() => expectJsonStdout(suffix, anything), throwsA(anything));
  }, timeout: processTestTimeout);

  test('harness: ANSI rejects bare and incomplete control introducers', () {
    CliProcessResult result(String value) => CliProcessResult(
      argv: const [],
      processId: 0,
      exitCode: 0,
      timedOut: false,
      elapsed: Duration.zero,
      stdoutBytes: utf8.encode(value),
      stderrBytes: const [],
      readyFile: null,
      releaseFile: null,
    );

    for (final styling in const <String>[
      '\x1b',
      '\x1b[',
      '\x1b]',
      '\x1bP',
      '\u009b31',
      '\u009dtitle',
      '\u0090payload',
      '\u0098payload',
      '\u009epayload',
      '\u009fpayload',
      '\x1bXpayload',
      '\x1b^payload',
      '\x1b_payload',
    ]) {
      expect(() => expectNoAnsi(result(styling)), throwsA(anything));
    }
    expectNoAnsi(result('Tiếng Việt 漢字 é 😀 Û'));
  });

  test('harness: identity-reuse seam never signals a replaced PID', () {
    final observed = PosixProcessTableSnapshot.parse(
      '42 1 Sun Aug 16 10:00:00 2026 S\n',
    ).identityFor(42)!;
    final reused = PosixProcessTableSnapshot.parse(
      '42 1 Sun Aug 16 10:00:01 2026 S\n',
    );
    final signalled = <int>[];

    final wasSent = PosixProcessTreeSafety.signalIfIdentityCurrent(
      identity: observed,
      table: reused,
      signal: ProcessSignal.sigkill,
      signalSender: (identity, _) => signalled.add(identity.pid),
    );

    expect(wasSent, isFalse);
    expect(signalled, isEmpty);
  });

  test(
    'harness: tracked inspection failure never reports cleanup success',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'hang.dart': '''
import 'dart:async';
Future<void> main() async { while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); } }
''',
      });
      final unreliable = CliProcessHarness.repository(
        posixProcessTableReader: () async => null,
      );
      addTearDown(() async {
        try {
          await unreliable.close();
        } on CliProcessTerminationUnconfirmedException {
          // This test deliberately keeps inspection unavailable. The root was
          // already best-effort killed; retaining the lifecycle entry is the
          // fail-closed contract exercised here.
        }
      });

      await expectLater(
        unreliable.start(
          const [],
          entrypointOverride: fixture.file('hang.dart'),
          trackProcessTree: true,
        ),
        throwsA(isA<CliProcessTerminationUnconfirmedException>()),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: ready/release barrier is public and avoids cold-start races',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final release = fixture.file('release');
      await fixture.writeText(<String, String>{
        'barrier.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync('ready');
  while (!File(args[1]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  stdout.write('released');
}
''',
      });

      final invocation = await harness.start(
        [ready.path, release.path],
        entrypointOverride: fixture.file('barrier.dart'),
        readyFile: ready,
        releaseFile: release,
        timeout: const Duration(seconds: 15),
      );
      await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
      await release.writeAsString('go');
      final result = await invocation.result;

      expect(result.timedOut, isFalse);
      expect(result.exitCode, 0);
      expect(result.stdoutText, 'released');
      expect(result.stderrBytes, isEmpty);
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: successful early root exit still cleans the observed child',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final childPid = fixture.file('child.pid');
      final acknowledgement = fixture.file('child.ack');
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  while (!File(args[1]).existsSync() ||
      File(args[1]).readAsStringSync() != 'registered:early-root-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await stdout.close();
  await stderr.close();
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2]]);
  while (!File(args[2]).existsSync() ||
      File(args[2]).readAsStringSync() != 'registered:early-root-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  exit(0);
}
''',
      });

      final invocation = await harness.start(
        [fixture.file('child.dart').path, childPid.path, acknowledgement.path],
        entrypointOverride: fixture.file('parent.dart'),
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: childPid,
          acknowledgementFile: acknowledgement,
          token: 'early-root-token',
        ),
        timeout: const Duration(seconds: 15),
        trackProcessTree: true,
      );
      await waitForReadyFile(
        acknowledgement,
        timeout: const Duration(seconds: 10),
      );
      final result = await invocation.result;

      expect(result.exitCode, 0);
      expect(result.timedOut, isFalse);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrBytes, isEmpty);
      expect(
        await _waitForPidToDisappear(int.parse(childPid.readAsStringSync())),
        isTrue,
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: automatic POSIX tracking accepts an exited root without descendants',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final release = fixture.file('release');
      final entrypoint = fixture.file('exit.dart');
      await fixture.writeText(<String, String>{
        'exit.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync('ready');
  while (!File(args[1]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
''',
      });
      int? rootPid;
      var tableReads = 0;
      final exitedRoot = CliProcessHarness.repository(
        posixProcessTableReader: () async {
          tableReads++;
          if (rootPid == null) {
            final table = await Process.run('ps', const [
              '-axo',
              'pid=,command=',
            ]);
            final line = (table.stdout as String)
                .split('\n')
                .firstWhere((value) => value.contains(entrypoint.path));
            rootPid = int.parse(line.trim().split(RegExp(r'\s+')).first);
            return PosixProcessTableSnapshot.parse(
              '$rootPid 1 Sun Aug 16 10:00:00 2026 S\n',
            );
          }
          return PosixProcessTableSnapshot.parse(
            '$rootPid 1 Sun Aug 16 10:00:00 2026 Z\n',
          );
        },
        posixIdentitySignalSender: (_, _) {},
      );
      addTearDown(exitedRoot.close);

      final invocation = await exitedRoot.start([
        ready.path,
        release.path,
      ], entrypointOverride: entrypoint);
      await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
      await release.writeAsString('release');
      final result = await invocation.result;

      expect(result.exitCode, 0);
      expect(result.timedOut, isFalse);
      expect(tableReads, greaterThanOrEqualTo(2));
      expect(exitedRoot.activeInvocationCount, 0);
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: preflight rejects unsupported tracked trees before launch',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final marker = fixture.file('launched');
      await fixture.writeText(<String, String>{
        'marker.dart':
            "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
      });
      final unsupported = CliProcessHarness.repository(
        trackedProcessTreeSupport: () => false,
      );

      await expectLater(
        unsupported.start(
          [marker.path],
          entrypointOverride: fixture.file('marker.dart'),
          trackProcessTree: true,
        ),
        throwsUnsupportedError,
      );
      expect(marker.existsSync(), isFalse);
    },
  );

  test(
    'harness: registration validation runs before unavailable tree tracking',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final pidFile = fixture.file('child.pid')..writeAsStringSync('stale');
      final acknowledgement = fixture.file('child.ack');
      final marker = fixture.file('launched');
      await fixture.writeText(<String, String>{
        'marker.dart':
            "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
      });
      final unsupported = CliProcessHarness.repository(
        trackedProcessTreeSupport: () => false,
      );
      addTearDown(unsupported.close);

      await expectLater(
        unsupported.start(
          [marker.path],
          entrypointOverride: fixture.file('marker.dart'),
          trackProcessTree: true,
          trackedChildRegistration: TrackedChildRegistration(
            pidFile: pidFile,
            acknowledgementFile: acknowledgement,
            token: 'stale-token',
          ),
        ),
        throwsStateError,
      );
      expect(marker.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: automatic tracking remains runnable when tree support is unavailable',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final marker = fixture.file('launched');
      await fixture.writeText(<String, String>{
        'marker.dart':
            "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
      });
      final unsupported = CliProcessHarness.repository(
        trackedProcessTreeSupport: () => false,
      );
      addTearDown(unsupported.close);

      final result = await unsupported.run([
        marker.path,
      ], entrypointOverride: fixture.file('marker.dart'));

      expect(result.exitCode, 0);
      expect(marker.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test('harness: stale registration files are rejected before launch', () async {
    final fixture = CliFixture.create();
    addTearDown(fixture.dispose);
    final pidFile = fixture.file('child.pid');
    final acknowledgement = fixture.file('child.ack');
    final marker = fixture.file('launched');
    await fixture.writeText(<String, String>{
      'child.pid': '999999\n',
      'marker.dart':
          "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
    });

    await expectLater(
      harness.start(
        [marker.path],
        entrypointOverride: fixture.file('marker.dart'),
        trackProcessTree: true,
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: pidFile,
          acknowledgementFile: acknowledgement,
          token: 'stale-token',
        ),
      ),
      throwsStateError,
    );
    expect(marker.existsSync(), isFalse);
    expect(acknowledgement.existsSync(), isFalse);
  });

  test('harness: registration paths reject stale ack, links, and aliases', () async {
    Future<void> expectRejected(
      void Function(CliFixture fixture, File pid, File ack) prepare,
    ) async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final pid = fixture.file('child.pid');
      final ack = fixture.file('child.ack');
      final marker = fixture.file('launched');
      await fixture.writeText(<String, String>{
        'marker.dart':
            "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
      });
      prepare(fixture, pid, ack);
      await expectLater(
        harness.start(
          [marker.path],
          entrypointOverride: fixture.file('marker.dart'),
          trackProcessTree: true,
          trackedChildRegistration: TrackedChildRegistration(
            pidFile: pid,
            acknowledgementFile: ack,
            token: 'path-token',
          ),
        ),
        throwsStateError,
      );
      expect(marker.existsSync(), isFalse);
    }

    await expectRejected((_, _, ack) => ack.writeAsStringSync('stale'));
    await expectRejected(
      (_, pid, _) => Link(pid.path).createSync('missing-target'),
    );
    await expectRejected(
      (_, _, ack) => Link(ack.path).createSync('missing-target'),
    );

    final fixture = CliFixture.create();
    addTearDown(fixture.dispose);
    final path = fixture.file('same');
    final alias = File(
      '${fixture.root.path}${Platform.pathSeparator}.${Platform.pathSeparator}same',
    );
    final marker = fixture.file('launched');
    await fixture.writeText(<String, String>{
      'marker.dart':
          "import 'dart:io'; void main(List<String> args) => File(args.single).writeAsStringSync('launched');",
    });
    await expectLater(
      harness.start(
        [marker.path],
        entrypointOverride: fixture.file('marker.dart'),
        trackProcessTree: true,
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: path,
          acknowledgementFile: alias,
          token: 'path-token',
        ),
      ),
      throwsStateError,
    );
    expect(marker.existsSync(), isFalse);
  });

  test(
    'harness: a wrong or partial acknowledgement is not accepted or replaced',
    () async {
      if (Platform.isWindows) return;
      for (final invalidAcknowledgement in <String>[
        'registered:wrong-token',
        'registered:expected-token',
      ]) {
        final fixture = CliFixture.create();
        final pid = fixture.file('child.pid');
        final ack = fixture.file('child.ack');
        final ready = fixture.file('ready');
        await fixture.writeText(<String, String>{
          'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  File(args[1]).writeAsStringSync(args[2]);
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
          'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2], args[4]]);
  while (!File(args[2]).existsSync() || File(args[2]).readAsStringSync() != 'registered:expected-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(args[3]).writeAsStringSync('ready');
}
''',
        });
        try {
          final invocation = await harness.start(
            [
              fixture.file('child.dart').path,
              pid.path,
              ack.path,
              ready.path,
              invalidAcknowledgement,
            ],
            entrypointOverride: fixture.file('parent.dart'),
            readyFile: ready,
            timeout: const Duration(seconds: 15),
            trackProcessTree: true,
            trackedChildRegistration: TrackedChildRegistration(
              pidFile: pid,
              acknowledgementFile: ack,
              token: 'expected-token',
            ),
          );
          await waitForReadyFile(ack, timeout: const Duration(seconds: 10));
          await expectLater(
            waitForReadyFile(ready, timeout: const Duration(milliseconds: 400)),
            throwsA(isA<TimeoutException>()),
          );
          expect(ack.readAsStringSync(), invalidAcknowledgement);
          await invocation.close();
          await harness.close();
        } finally {
          await fixture.dispose();
        }
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: acknowledgement payload remains on the exclusively opened inode after path replacement',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      final pidFile = fixture.file('child.pid');
      final acknowledgement = fixture.file('child.ack');
      final openedAcknowledgement = fixture.file('child.ack.opened');
      final replacementTarget = fixture.file('replacement-target');
      const token = 'same-inode-token';
      await fixture.writeText(<String, String>{
        'replacement-target': 'must-not-change',
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args.single).writeAsStringSync(pid.toString());
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1]]);
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      });
      final trackedRegistration = TrackedChildRegistration(
        pidFile: pidFile,
        acknowledgementFile: acknowledgement,
        token: token,
      );
      int? modeBeforeFchmod;
      final racing = CliProcessHarness.repository(
        acknowledgementExclusiveOpenModeObserver: (opened) {
          modeBeforeFchmod = opened.statSync().mode & 0x1ff;
        },
        acknowledgementExclusiveOpenObserver: (opened) {
          opened.renameSync(openedAcknowledgement.path);
          Link(acknowledgement.path).createSync(replacementTarget.path);
        },
      );

      try {
        final invocation = await racing.start(
          [fixture.file('child.dart').path, pidFile.path],
          entrypointOverride: fixture.file('parent.dart'),
          timeout: const Duration(seconds: 15),
          timeoutAfterReady: null,
          trackProcessTree: true,
          trackedChildRegistration: trackedRegistration,
        );
        await waitForReadyFile(
          openedAcknowledgement,
          timeout: const Duration(seconds: 10),
        );

        expect(
          openedAcknowledgement.readAsStringSync(),
          trackedRegistration.acknowledgementText,
        );
        expect(modeBeforeFchmod, 0x180);
        expect(replacementTarget.readAsStringSync(), 'must-not-change');
        expect(
          FileSystemEntity.typeSync(acknowledgement.path, followLinks: false),
          FileSystemEntityType.link,
        );

        await invocation.close();
        final result = await invocation.result;
        expect(result.timedOut, isFalse);
        expect(
          await _waitForPidToDisappear(int.parse(pidFile.readAsStringSync())),
          isTrue,
        );
      } finally {
        await racing.close();
        await fixture.dispose();
      }
    },
    timeout: processTestTimeout,
  );

  test('harness: unrelated PID registration is never acknowledged', () async {
    if (Platform.isWindows) return;
    final fixture = CliFixture.create();
    addTearDown(fixture.dispose);
    final pidFile = fixture.file('child.pid');
    final acknowledgement = fixture.file('child.ack');
    await fixture.writeText(<String, String>{
      'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args.single).writeAsStringSync('1');
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
    });
    final invocation = await harness.start(
      [pidFile.path],
      entrypointOverride: fixture.file('parent.dart'),
      timeout: const Duration(seconds: 15),
      trackProcessTree: true,
      trackedChildRegistration: TrackedChildRegistration(
        pidFile: pidFile,
        acknowledgementFile: acknowledgement,
        token: 'unrelated-token',
      ),
    );

    await expectLater(
      waitForReadyFile(
        acknowledgement,
        timeout: const Duration(milliseconds: 400),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(acknowledgement.existsSync(), isFalse);
    await invocation.close();
    await harness.close();
    expect(harness.activeInvocationCount, 0);
  }, timeout: processTestTimeout);

  test(
    'harness: close cleans a registered child before any ready barrier',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('never-ready');
      final pidFile = fixture.file('child.pid');
      final acknowledgement = fixture.file('child.ack');
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  while (!File(args[1]).existsSync() || File(args[1]).readAsStringSync() != 'registered:pre-ready-token\\n') { await Future<void>.delayed(const Duration(milliseconds: 10)); }
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2]]);
  while (!File(args[2]).existsSync() || File(args[2]).readAsStringSync() != 'registered:pre-ready-token\\n') { await Future<void>.delayed(const Duration(milliseconds: 10)); }
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      });
      final invocation = await harness.start(
        [fixture.file('child.dart').path, pidFile.path, acknowledgement.path],
        entrypointOverride: fixture.file('parent.dart'),
        readyFile: ready,
        timeout: const Duration(seconds: 15),
        trackProcessTree: true,
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: pidFile,
          acknowledgementFile: acknowledgement,
          token: 'pre-ready-token',
        ),
      );
      await waitForReadyFile(
        acknowledgement,
        timeout: const Duration(seconds: 10),
      );
      expect(harness.activeInvocationCount, 1);
      await harness.close();
      expect(harness.activeInvocationCount, 0);
      await expectLater(invocation.result, throwsA(isA<StateError>()));
      expect(
        await _waitForPidToDisappear(int.parse(pidFile.readAsStringSync())),
        isTrue,
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: unconfirmed cleanup stays registered for external retry',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'hang.dart': '''
import 'dart:async';
Future<void> main() async { while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); } }
''',
      });
      var reads = 0;
      var recover = false;
      final retryHarness = CliProcessHarness.repository(
        posixProcessTableReader: () async {
          reads++;
          if (reads > 1 && !recover) return null;
          return _readCurrentProcessTable();
        },
      );
      addTearDown(retryHarness.close);
      final invocation = await retryHarness.start(
        const [],
        entrypointOverride: fixture.file('hang.dart'),
        timeout: const Duration(seconds: 15),
        trackProcessTree: true,
      );

      await expectLater(
        invocation.close(),
        throwsA(isA<CliProcessTerminationUnconfirmedException>()),
      );
      expect(retryHarness.activeInvocationCount, 1);
      recover = true;
      await retryHarness.close();
      expect(retryHarness.activeInvocationCount, 0);
      await expectLater(invocation.result, completes);
      expect(reads, greaterThan(2));
    },
    timeout: processTestTimeout,
  );

  test('harness: signals grandchild before child before root', () {
    final table = PosixProcessTableSnapshot.parse('''
1 0 Sun Aug 16 10:00:00 2026 S
2 1 Sun Aug 16 10:00:00 2026 S
3 2 Sun Aug 16 10:00:00 2026 S
''');

    expect(
      PosixProcessTreeSafety.childBeforeParentOrder(
        table: table,
        live: {1, 2, 3},
        rootPid: 1,
      ),
      [3, 2, 1],
    );
  });

  test(
    'harness: confirmed completion-error cleanup releases active registry',
    () async {
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final missingReady = fixture.file('missing-ready');
      await fixture.writeText(<String, String>{
        'exit.dart': 'void main() {}\n',
      });
      final invocation = await harness.start(
        const [],
        entrypointOverride: fixture.file('exit.dart'),
        readyFile: missingReady,
        timeout: const Duration(seconds: 15),
      );
      await expectLater(invocation.result, throwsA(isA<StateError>()));
      expect(harness.activeInvocationCount, 0);
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: run automatically retries one transient cleanup inspection',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final childPid = fixture.file('child.pid');
      final acknowledgement = fixture.file('child.ack');
      const token = 'automatic-retry-token';
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  while (!File(args[1]).existsSync() ||
      File(args[1]).readAsStringSync() != 'registered:automatic-retry-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2]]);
  while (!File(args[2]).existsSync() ||
      File(args[2]).readAsStringSync() != 'registered:automatic-retry-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(args[3]).writeAsStringSync('ready');
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      });
      var failNextRead = false;
      final attempts = <(int, int)>[];
      final automatic = CliProcessHarness.repository(
        cleanupAttemptObserver: (episode, attempt) {
          attempts.add((episode, attempt));
          if (attempt == 1) failNextRead = true;
        },
        posixProcessTableReader: () async {
          if (failNextRead) {
            failNextRead = false;
            return null;
          }
          return _readCurrentProcessTable();
        },
      );
      addTearDown(automatic.close);
      final resultFuture = automatic.run(
        [
          fixture.file('child.dart').path,
          childPid.path,
          acknowledgement.path,
          ready.path,
        ],
        entrypointOverride: fixture.file('parent.dart'),
        readyFile: ready,
        timeout: const Duration(seconds: 15),
        timeoutAfterReady: const Duration(seconds: 1),
        trackProcessTree: true,
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: childPid,
          acknowledgementFile: acknowledgement,
          token: token,
        ),
      );

      await waitForReadyFile(
        acknowledgement,
        timeout: const Duration(seconds: 10),
      );
      expect(acknowledgement.readAsStringSync(), 'registered:$token\n');
      await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
      expect(childPid.existsSync(), isTrue);

      final result = await resultFuture;
      expect(result.timedOut, isTrue);
      expect(automatic.activeInvocationCount, 0);
      expect(attempts, hasLength(2));
      expect(attempts[0].$1, attempts[1].$1);
      expect(attempts.map((value) => value.$2), [1, 2]);
      expect(
        await _waitForPidToDisappear(int.parse(childPid.readAsStringSync())),
        isTrue,
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'harness: a mid-cleanup inspection failure remains retryable and fail-closed',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final childPid = fixture.file('child.pid');
      final acknowledgement = fixture.file('child.ack');
      const token = 'explicit-retry-token';
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync(pid.toString());
  while (!File(args[1]).existsSync() ||
      File(args[1]).readAsStringSync() != 'registered:explicit-retry-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
        'hang.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2]]);
  while (!File(args[2]).existsSync() ||
      File(args[2]).readAsStringSync() != 'registered:explicit-retry-token\\n') {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(args[3]).writeAsStringSync('ready');
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      });
      var reads = 0;
      var failNextRead = false;
      final flaky = CliProcessHarness.repository(
        posixProcessTableReader: () async {
          reads++;
          if (failNextRead) {
            failNextRead = false;
            return null;
          }
          return _readCurrentProcessTable();
        },
      );
      addTearDown(flaky.close);

      final invocation = await flaky.start(
        [
          fixture.file('child.dart').path,
          childPid.path,
          acknowledgement.path,
          ready.path,
        ],
        entrypointOverride: fixture.file('hang.dart'),
        readyFile: ready,
        timeout: const Duration(seconds: 15),
        trackProcessTree: true,
        trackedChildRegistration: TrackedChildRegistration(
          pidFile: childPid,
          acknowledgementFile: acknowledgement,
          token: token,
        ),
      );
      await waitForReadyFile(
        acknowledgement,
        timeout: const Duration(seconds: 10),
      );
      expect(acknowledgement.readAsStringSync(), 'registered:$token\n');
      await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
      expect(childPid.existsSync(), isTrue);
      failNextRead = true;
      await expectLater(
        invocation.close(),
        throwsA(isA<CliProcessTerminationUnconfirmedException>()),
      );
      expect(flaky.activeInvocationCount, 1);
      await expectLater(invocation.close(), completes);
      await expectLater(invocation.result, completes);
      expect(flaky.activeInvocationCount, 0);
      expect(reads, greaterThan(2));
      expect(
        await _waitForPidToDisappear(int.parse(childPid.readAsStringSync())),
        isTrue,
      );
    },
    timeout: processTestTimeout,
  );

  test('harness: tracked teardown closes a multi-generation fixture', () async {
    if (Platform.isWindows) return;
    final fixture = CliFixture.create();
    addTearDown(fixture.dispose);
    final ready = fixture.file('ready');
    final childPid = fixture.file('child.pid');
    final grandchildPid = fixture.file('grandchild.pid');
    await fixture.writeText(<String, String>{
      'grandchild.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  File(args[0]).writeAsStringSync('not-a-pid');
  await Future<void>.delayed(const Duration(milliseconds: 100));
  File(args[0]).writeAsStringSync(pid.toString());
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      'child.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1]]);
  File(args[2]).writeAsStringSync(pid.toString());
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  await Process.start(Platform.resolvedExecutable, [args[0], args[1], args[2], args[3]]);
  bool hasPositivePid(File file) {
    try {
      return int.parse(file.readAsStringSync().trim()) > 0;
    } on FileSystemException {
      return false;
    } on FormatException {
      return false;
    }
  }
  while (!hasPositivePid(File(args[2])) || !hasPositivePid(File(args[3]))) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(args[4]).writeAsStringSync('ready');
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
    });

    final invocation = await harness.start(
      [
        fixture.file('child.dart').path,
        fixture.file('grandchild.dart').path,
        grandchildPid.path,
        childPid.path,
        ready.path,
      ],
      entrypointOverride: fixture.file('parent.dart'),
      readyFile: ready,
      timeout: const Duration(seconds: 15),
      timeoutAfterReady: const Duration(seconds: 1),
      trackProcessTree: true,
    );
    await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
    await waitForReadyFile(childPid, timeout: const Duration(seconds: 10));
    await waitForReadyFile(grandchildPid, timeout: const Duration(seconds: 10));
    final child = int.parse(childPid.readAsStringSync());
    final grandchild = int.parse(grandchildPid.readAsStringSync());
    final result = await invocation.result;

    expect(result.timedOut, isTrue);
    expect(await _waitForPidToDisappear(child), isTrue);
    expect(await _waitForPidToDisappear(grandchild), isTrue);
  }, timeout: processTestTimeout);

  test(
    'harness: close drives tracked teardown before invocation timeout',
    () async {
      if (Platform.isWindows) return;
      final fixture = CliFixture.create();
      addTearDown(fixture.dispose);
      final ready = fixture.file('ready');
      final childPid = fixture.file('child.pid');
      await fixture.writeText(<String, String>{
        'child.dart': '''
import 'dart:async';
Future<void> main() async { while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); } }
''',
        'parent.dart': '''
import 'dart:async';
import 'dart:io';
Future<void> main(List<String> args) async {
  final child = await Process.start(Platform.resolvedExecutable, [args[0]]);
  File(args[1]).writeAsStringSync(child.pid.toString());
  File(args[2]).writeAsStringSync('ready');
  while (true) { await Future<void>.delayed(const Duration(milliseconds: 25)); }
}
''',
      });

      final invocation = await harness.start(
        [fixture.file('child.dart').path, childPid.path, ready.path],
        entrypointOverride: fixture.file('parent.dart'),
        readyFile: ready,
        timeout: const Duration(seconds: 20),
        trackProcessTree: true,
      );
      await waitForReadyFile(ready, timeout: const Duration(seconds: 10));
      await invocation.close();
      final result = await invocation.result;

      expect(result.timedOut, isFalse);
      expect(
        await _waitForPidToDisappear(int.parse(childPid.readAsStringSync())),
        isTrue,
      );
    },
    timeout: processTestTimeout,
  );
}

Map<String, dynamic> _stableReportEvidence(Map<String, dynamic> report) {
  final stable = jsonDecode(jsonEncode(report)) as Map<String, dynamic>;
  final run = stable['run']! as Map<String, dynamic>;
  run
    ..remove('id')
    ..remove('startedAtUtc')
    ..remove('finishedAtUtc');
  _removeElapsedMicros(stable);
  return stable;
}

Map<String, Object?> _cleanPlanJson(QuarantineCleanPlan plan) =>
    <String, Object?>{
      'schemaVersion': 1,
      'kind': 'quarantineCleanPlan',
      'scope': plan.scope.name,
      'canonicalBases': plan.canonicalBases,
      'targetCount': plan.targets.length,
      'targets': plan.targets
          .map(
            (target) => <String, Object?>{
              'runId': target.runId,
              'canonicalPath': target.canonicalPath,
              'layoutSha256': target.layoutSha256,
              'journalRevision': target.journalRevision,
              'payloadSha256': target.payloadSha256,
              'authority': target.authority.name,
              'repairAction': target.repairAction.name,
            },
          )
          .toList(growable: false),
      'fingerprint': plan.fingerprint,
      'backend': <String, Object?>{
        'version': CleanBackendDisclosure.version,
        'name': plan.backend.name,
        'batchAtomic': plan.backend.batchAtomic,
        'identityBoundDelete': plan.backend.identityBoundDelete,
        'identityBoundMove': plan.backend.identityBoundMove,
        'physicalDelete': plan.backend.physicalDelete,
        'crashRecoverableReceipt': plan.backend.crashRecoverableReceipt,
        'releaseEligible': plan.backend.releaseEligible,
        'blockerCode': plan.backend.blockerCode,
      },
    };

String _cancelledCleanTranscript(QuarantineCleanPlan plan) {
  final target = plan.targets.single;
  final phrase = 'clean-all 1 ${plan.fingerprint.substring(3, 15)}';
  return '\x1B[1m\x1B[36mQUARANTINE CLEAN PREVIEW\x1B[0m\n'
      '\n'
      '  Scope: all\n'
      '  Targets: 1\n'
      '  Fingerprint: ${plan.fingerprint}\n'
      '  Canonical base: ${plan.canonicalBases.single}\n'
      '  Backend: recoverableLogicalMove\n'
      '  Batch atomic: no\n'
      '  Identity-bound delete: no\n'
      '  Identity-bound move: yes\n'
      '  Physical delete: no\n'
      '  Crash-recoverable receipt: yes\n'
      '  Release eligible: no\n'
      '  Disk space reclaimed: no\n'
      '\x1B[33m!\x1B[0m Blocker: CLEAN-TOCTOU-1\n'
      '\n'
      '  1. ${target.runId}\n'
      '     Path: ${target.canonicalPath}\n'
      '\n'
      '\x1B[2mNo quarantine evidence was removed.\x1B[0m\n'
      "Type '$phrase' to logically clean this quarantine evidence: Cancelled.\n";
}

void _expectNoReportArtifacts(Directory project) {
  expect(
    Directory(p.join(project.path, '.flutter_pruner', 'reports')).existsSync(),
    isFalse,
  );
}

void _removeElapsedMicros(Object? value) {
  switch (value) {
    case Map<Object?, Object?>():
      value.remove('elapsedMicros');
      for (final child in value.values) {
        _removeElapsedMicros(child);
      }
    case List<Object?>():
      for (final child in value) {
        _removeElapsedMicros(child);
      }
  }
}

Future<void> _expectOperationLockReleased(Directory project) async {
  final workspace = ToolWorkspace(project);
  expect(workspace.operationLockFile.existsSync(), isTrue);
  final lock = await ProjectOperationLock.acquire(
    workspace: workspace,
    operation: 'c7-contract-probe',
  );
  await lock.release();
}

Future<bool> _waitForPidToDisappear(int pid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run('ps', ['-p', '$pid', '-o', 'pid=']);
    if (result.exitCode != 0 || (result.stdout as String).trim().isEmpty) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

Future<PosixProcessTableSnapshot?> _readCurrentProcessTable() async {
  final result = await Process.run('ps', const [
    '-axo',
    'pid=,ppid=,lstart=,state=',
  ]);
  if (result.exitCode != 0) return null;
  return PosixProcessTableSnapshot.parse(result.stdout as String);
}

List<String> _snapshotSelectedPaths(Directory root, Iterable<String> paths) =>
    paths.expand((path) => _snapshotEntity(root, path)).toList(growable: false);

List<String> _snapshotTree(Directory root) =>
    _snapshotEntity(root.parent, p.basename(root.path));

List<String> _snapshotEntity(Directory root, String relativePath) {
  final entityPath = p.join(root.path, relativePath);
  final type = FileSystemEntity.typeSync(entityPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) return ['$relativePath|missing'];

  final entries = <FileSystemEntity>[
    FileSystemEntity.typeSync(entityPath, followLinks: false) ==
            FileSystemEntityType.directory
        ? Directory(entityPath)
        : File(entityPath),
  ];
  if (type == FileSystemEntityType.directory) {
    entries.addAll(
      Directory(entityPath).listSync(recursive: true, followLinks: false),
    );
  }
  final snapshots =
      entries
          .map((entity) {
            final path = p.relative(entity.path, from: root.path);
            final entityType = FileSystemEntity.typeSync(
              entity.path,
              followLinks: false,
            );
            final mode = entity.statSync().mode & 0xfff;
            return switch (entityType) {
              FileSystemEntityType.file =>
                '$path|file|$mode|${base64Encode(File(entity.path).readAsBytesSync())}',
              FileSystemEntityType.directory => '$path|directory|$mode',
              FileSystemEntityType.link =>
                '$path|link|$mode|${Link(entity.path).targetSync()}',
              FileSystemEntityType.notFound => '$path|missing',
              _ => '$path|other|$mode',
            };
          })
          .toList(growable: false)
        ..sort();
  return snapshots;
}
