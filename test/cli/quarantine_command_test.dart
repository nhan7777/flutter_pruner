import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/quarantine_command.dart';
import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'cli_process_harness.dart';

final _unsafeRenderedControl = RegExp(
  r'[\x00-\x09\x0B-\x1F\x7F-\x9F\u061C\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]',
);
final _unsafeJsonRepresentationControl = RegExp(
  r'[\x00-\x1F\x7F-\x9F\u061C\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]',
);

final _hostileCleanPathSegment = Platform.isWindows
    ? 'invalid\u061c\u200e\u200f'
          '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069 FORGED CLEAN ROW'
    : 'invalid\x1b[31m\u0085\u061c\u200e\u200f\u2028\u2029'
          '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\nFORGED CLEAN ROW';
final _visibleHostileCleanPathSegment = Platform.isWindows
    ? r'invalid\u061C\u200E\u200F'
          r'\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069 FORGED CLEAN ROW'
    : r'invalid\x1B[31m\u0085\u061C\u200E\u200F\u2028\u2029'
          r'\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\nFORGED CLEAN ROW';
final _hostileLegacyPathSegment = Platform.isWindows
    ? 'legacy-\u0080\u0081\u0082\u0083\u0084\u0085\u0086\u0087'
          '\u0088\u0089\u008a\u008b\u008c\u008d\u008e\u008f'
          '\u0090\u0091\u0092\u0093\u0094\u0095\u0096\u0097'
          '\u0098\u0099\u009a\u009b\u009c\u009d\u009e\u009f'
          '\u061c\u200e\u200f\u2028\u2029\u202a\u202b\u202c\u202d\u202e'
          '\u2066\u2067\u2068\u2069 FORGED LEGACY ROW'
    : 'legacy-\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0b\x0c\r'
          '\x0e\x0f\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1a\x1b\x1c\x1d\x1e\x1f\x7f'
          '\u0080\u0081\u0082\u0083\u0084\u0085\u0086\u0087'
          '\u0088\u0089\u008a\u008b\u008c\u008d\u008e\u008f'
          '\u0090\u0091\u0092\u0093\u0094\u0095\u0096\u0097'
          '\u0098\u0099\u009a\u009b\u009c\u009d\u009e\u009f'
          '\u061c\u200e\u200f\u2028\u2029\u202a\u202b\u202c\u202d\u202e'
          '\u2066\u2067\u2068\u2069\nFORGED LEGACY ROW';
final _visibleHostileLegacyPathSegment = Platform.isWindows
    ? r'legacy-\u0080\u0081\u0082\u0083\u0084\u0085\u0086\u0087'
          r'\u0088\u0089\u008A\u008B\u008C\u008D\u008E\u008F'
          r'\u0090\u0091\u0092\u0093\u0094\u0095\u0096\u0097'
          r'\u0098\u0099\u009A\u009B\u009C\u009D\u009E\u009F'
          r'\u061C\u200E\u200F\u2028\u2029\u202A\u202B\u202C\u202D\u202E'
          r'\u2066\u2067\u2068\u2069 FORGED LEGACY ROW'
    : r'legacy-\x01\x02\x03\x04\x05\x06\x07\x08\t\n\x0B\x0C\r'
          r'\x0E\x0F\x10\x11\x12\x13\x14\x15\x16\x17\x18\x19\x1A\x1B\x1C\x1D\x1E\x1F\x7F'
          r'\u0080\u0081\u0082\u0083\u0084\u0085\u0086\u0087'
          r'\u0088\u0089\u008A\u008B\u008C\u008D\u008E\u008F'
          r'\u0090\u0091\u0092\u0093\u0094\u0095\u0096\u0097'
          r'\u0098\u0099\u009A\u009B\u009C\u009D\u009E\u009F'
          r'\u061C\u200E\u200F\u2028\u2029\u202A\u202B\u202C\u202D\u202E'
          r'\u2066\u2067\u2068\u2069\nFORGED LEGACY ROW';

final _hostileTerminalProjectSegment = Platform.isWindows
    ? 'quarantine terminal \u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e'
          '\u2066\u2067\u2068\u2069 forged '
    : 'quarantine terminal \x1b[31m\u009b31m\u061c\u200e\u200f\u2028\u2029'
          '\u202a\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\nforged ';
final _visibleHostileTerminalProjectSegment = Platform.isWindows
    ? r'\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069 forged'
    : r'\x1B[31m\u009B31m\u061C\u200E\u200F\u2028\u2029\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\nforged';
final _hostileTerminalInvalidSegment = Platform.isWindows
    ? 'invalid\u061c\u200e\u200f\u202a\u202b\u202c\u202d\u202e'
          '\u2066\u2067\u2068\u2069 ACTIVE'
    : 'invalid\x1b[32m\u009b32m\u061c\u200e\u200f\u2028\u2029\u202a'
          '\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\nACTIVE';
final _visibleHostileTerminalInvalidSegment = Platform.isWindows
    ? r'invalid\u061C\u200E\u200F\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069 ACTIVE'
    : r'invalid\x1B[32m\u009B32m\u061C\u200E\u200F\u2028\u2029\u202A\u202B\u202C\u202D\u202E\u2066\u2067\u2068\u2069\nACTIVE';
final _hostileJsonProjectSegment = Platform.isWindows
    ? 'quarantine JSON controls \u061c\u200e\u200f\u202a\u202b\u202c\u202d'
          '\u202e\u2066\u2067\u2068\u2069 forged '
    : 'quarantine JSON controls \x1b[31m\u0085\u0090\u0098\u009b31m'
          '\u009d\u009e\u009f\u061c\u200e\u200f\u2028\u2029\u202a'
          '\u202b\u202c\u202d\u202e\u2066\u2067\u2068\u2069\nforged ';

void main() {
  test(
    'terminal human output uses a terminal stderr sink when COLUMNS is absent',
    () {
      final redirectedStdout = _TerminalRecordingSink();
      final terminalStderr = _TerminalRecordingSink(
        terminalColumnsOverride: 32,
      );
      final output = TerminalHumanOutput(environment: () => const {});

      expect(output.lineWidth(redirectedStdout), 160);
      expect(output.lineWidth(terminalStderr), 32);

      final lines = output.wrap(
        terminalStderr,
        'Error: ${'界e\u0301😀' * 8}/dynamic\nFORGED\x1b[31m',
      );
      const metrics = TerminalTextMetrics();
      expect(
        lines,
        everyElement(
          predicate<String>((line) => metrics.visibleWidth(line) <= 32),
        ),
      );
      expect(
        _unwrapVisualLines(lines.join('\n')),
        contains(
          r'Error:界é😀界é😀界é😀界é😀界é😀界é😀界é😀界é😀/dynamic\nFORGED\x1B[31m',
        ),
      );
    },
  );

  const processTestTimeout = Timeout(Duration(minutes: 2));

  test(
    'root-only run seams reject invalid argv before launch or tree inspection',
    () async {
      var treeReads = 0;
      final harness = CliProcessHarness.repository(
        posixProcessTableReader: () async {
          treeReads++;
          return null;
        },
      );
      addTearDown(harness.close);

      await expectLater(
        harness.runQuarantineOnly(const <String>[]),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        harness.runQuarantineOnly(const <String>['scan']),
        throwsA(isA<ArgumentError>()),
      );
      await expectLater(
        harness.runQuarantineCleanFake(const <String>['quarantine', 'list']),
        throwsA(isA<ArgumentError>()),
      );

      expect(treeReads, 0);
      expect(harness.activeInvocationCount, 0);
    },
    timeout: processTestTimeout,
  );

  test('root-only start fake rejects non-clean argv before launch', () {
    var treeReads = 0;
    final harness = CliProcessHarness.repository(
      posixProcessTableReader: () async {
        treeReads++;
        return null;
      },
    );
    addTearDown(harness.close);

    expect(
      () => harness.startQuarantineCleanFake(const <String>['quarantine']),
      throwsArgumentError,
    );
    expect(treeReads, 0);
    expect(harness.activeInvocationCount, 0);
  }, timeout: processTestTimeout);

  test(
    'dedicated clean fake helpers bypass unavailable tree inspection',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine fake root only ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_fake_root_only\n',
      });
      await QuarantineManager(fixture.root).createQuarantine(
        runId: 'fake-root-only',
        entries: const <QuarantineEntry>[],
      );
      var inspectionReads = 0;
      final harness = CliProcessHarness.repository(
        posixProcessTableReader: () async {
          inspectionReads++;
          return null;
        },
      );
      addTearDown(harness.close);
      final argv = <String>[
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--dry-run',
        'fake-root-only',
      ];

      final runResult = await harness.runQuarantineCleanFake(argv);
      final invocation = await harness.startQuarantineCleanFake(argv);
      final startResult = await invocation.result;

      expect(runResult.exitCode, 0);
      expect(runResult.timedOut, isFalse);
      expect(startResult.exitCode, 0);
      expect(startResult.timedOut, isFalse);
      expect(inspectionReads, 0);
      expect(harness.activeInvocationCount, 0);
    },
    timeout: processTestTimeout,
  );

  test(
    'list reports invalid evidence instead of a false empty state',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine list invalid ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_list_invalid\n',
        '.flutter_pruner/quarantine/unreadable-ledger/manifest.json': '{broken',
      });

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expect(result.stdoutText, contains('ATTENTION'));
      expect(result.stdoutText, contains('invalid_manifest'));
      expect(result.stdoutText, contains('unreadable-ledger'));
      expect(result.stdoutText, isNot(contains('No quarantines found.')));
    },
    timeout: processTestTimeout,
  );

  test('list JSON is one canonical document with UTC timestamps', () async {
    final fixture = CliFixture.create(prefix: 'quarantine list json ');
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_list_json\n',
    });
    final manager = QuarantineManager(fixture.root);
    await manager.createQuarantine(
      runId: 'json-run',
      entries: const <QuarantineEntry>[],
    );

    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'list',
      '--project',
      fixture.root.path,
      '--format',
      'json',
    ]);

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    expectNoAnsi(result);
    expectJsonStdout(
      result,
      allOf(
        containsPair('schemaVersion', 1),
        containsPair('total', 1),
        containsPair('returned', 1),
        containsPair('truncated', false),
        containsPair(
          'items',
          contains(
            allOf(
              containsPair('kind', 'valid'),
              containsPair('runId', 'json-run'),
              containsPair('createdAtUtc', endsWith('Z')),
            ),
          ),
        ),
      ),
    );
  }, timeout: processTestTimeout);

  test(
    'list keeps redirected human output styled and JSON as one document',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine list stream formats ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_list_stream_formats\n',
      });
      await QuarantineManager(fixture.root).createQuarantine(
        runId: 'stream-format-run',
        entries: const <QuarantineEntry>[],
      );
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final human = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);
      final json = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);

      expect(human.exitCode, 0);
      expect(human.stderrBytes, isEmpty);
      expect(human.stdoutText, contains('\x1B['));
      expect(
        _stripAnsi(human.stdoutText),
        contains('COMPLETED · stream-format-run'),
      );
      expect(json.exitCode, 0);
      expect(json.stderrBytes, isEmpty);
      expectNoAnsi(json);
      expectJsonStdout(
        json,
        allOf(
          containsPair('schemaVersion', 1),
          containsPair('total', 1),
          containsPair('returned', 1),
          containsPair('items', hasLength(1)),
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'human quarantine paths wrap Unicode terminal cells without losing bytes',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine-width-' * 6 + '界e\u0301😀' * 5,
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_unicode_width\n',
      });
      final manager = QuarantineManager(fixture.root);
      final quarantine = await manager.createQuarantine(
        runId: 'run-long-evidence',
        entries: const <QuarantineEntry>[],
      );

      final human = await CliProcessHarness.repository().runQuarantineOnly(
        ['quarantine', 'list', '--project', fixture.root.path],
        environmentAdditions: const <String, String>{'COLUMNS': '32'},
      );
      final json = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);

      expect(human.exitCode, 0);
      expect(human.stderrBytes, isEmpty);
      const metrics = TerminalTextMetrics();
      final plain = _stripAnsi(human.stdoutText);
      expect(
        plain.split('\n').where((line) => line.isNotEmpty),
        everyElement(
          predicate<String>((line) => metrics.visibleWidth(line) <= 32),
        ),
      );
      expect(plain.replaceAll(RegExp(r'\s+'), ''), contains(fixture.root.path));
      expect(json.exitCode, 0);
      expectJsonStdout(
        json,
        predicate(
          (value) =>
              ((value as Map<String, Object?>)['items']! as List<Object?>)
                  .cast<Map<Object?, Object?>>()
                  .single['path'] ==
              quarantine.path,
          'JSON keeps the exact unwrapped quarantine path',
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test('list rejects invalid limits before resolving the project', () async {
    final missingProject = p.join(
      Directory.systemTemp.path,
      'quarantine-list-missing-${DateTime.now().microsecondsSinceEpoch}',
    );
    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'list',
      '--project',
      missingProject,
      '--limit',
      '0',
    ]);

    expect(result.exitCode, 64);
    expect(result.stdoutBytes, isEmpty);
    expect(result.stderrText, contains('--limit must be a positive integer'));
  }, timeout: processTestTimeout);

  test('inspect selects journal authority and emits canonical JSON', () async {
    final fixture = CliFixture.create(prefix: 'quarantine inspect json ');
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_inspect_json\n',
    });
    final manager = QuarantineManager(fixture.root);
    await manager.createQuarantine(
      runId: 'inspect-run',
      entries: const <QuarantineEntry>[],
    );

    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'inspect',
      '--project',
      fixture.root.path,
      '--format',
      'json',
      'inspect-run',
    ]);

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    expectNoAnsi(result);
    expectJsonStdout(
      result,
      allOf(
        containsPair('schemaVersion', 1),
        containsPair('runId', 'inspect-run'),
        containsPair('authority', 'primary'),
        containsPair('repairAction', 'none'),
        containsPair('canonicalManifest', isA<Map<String, Object?>>()),
      ),
    );
  }, timeout: processTestTimeout);

  test(
    'inspect human output leads with validated evidence and repair guidance',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine inspect human ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_inspect_human\n',
      });
      final manager = QuarantineManager(fixture.root);
      final quarantine = await manager.createQuarantine(
        runId: 'repair-run',
        entries: const <QuarantineEntry>[],
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      primary.renameSync('${primary.path}.tmp');

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'inspect',
        '--project',
        fixture.root.path,
        'repair-run',
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(result.stdoutText);
      expect(result.stdoutText, contains('Quarantine: repair-run'));
      expect(result.stdoutText, contains('Authority: temporary'));
      expect(result.stdoutText, contains('Revision: 1'));
      expect(result.stdoutText, contains('Checksum:'));
      expect(
        result.stdoutText,
        contains(
          'Promote the temporary manifest only through a locked recovery operation',
        ),
      );
      expect(result.stdoutText, contains('Transactions: 0 total'));
      expect(result.stdoutText, contains('Cleanable:'));
      expect(result.stdoutText, contains('Canonical manifest:'));
      expect(result.stdoutText, contains('"runId": "repair-run"'));
      expect(primary.existsSync(), isFalse);
      expect(File('${primary.path}.tmp').existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test('inspect invalid runtime evidence keeps JSON stdout empty', () async {
    final fixture = CliFixture.create(prefix: 'quarantine inspect invalid ');
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_inspect_invalid\n',
    });
    Directory(
      fixture.file('.flutter_pruner/quarantine/broken-run/manifest.json').path,
    ).createSync(recursive: true);

    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'inspect',
      '--project',
      fixture.root.path,
      '--format',
      'json',
      'broken-run',
    ]);

    expect(result.exitCode, 1);
    expect(result.stdoutBytes, isEmpty);
    expect(result.stderrText, contains('Quarantine evidence is invalid'));
    expectNoAnsi(result);
  }, timeout: processTestTimeout);

  test(
    'list includes current and legacy bases then states default truncation',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine list limit ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_list_limit\n',
      });
      final manager = QuarantineManager(fixture.root);
      for (var index = 0; index < 51; index++) {
        await manager.createQuarantine(
          runId: 'current-${index.toString().padLeft(2, '0')}',
          entries: const <QuarantineEntry>[],
        );
      }
      await manager.createQuarantine(
        runId: 'legacy-run',
        quarantineBase: QuarantineManager.legacyQuarantineDir,
        entries: const <QuarantineEntry>[],
      );

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expectJsonStdout(
        result,
        allOf(
          containsPair('total', 52),
          containsPair('returned', 50),
          containsPair('truncated', true),
          containsPair(
            'items',
            isA<List<Object?>>().having(
              (items) => items.map((item) => (item as Map)['path']),
              'paths',
              contains(contains(QuarantineManager.legacyQuarantineDir)),
            ),
          ),
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'inspect reports temporary and previous authority without repairing either',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine inspect authority ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_inspect_authority\n',
      });
      final manager = QuarantineManager(fixture.root);
      final temporary = await manager.createQuarantine(
        runId: 'temporary-run',
        entries: const <QuarantineEntry>[],
      );
      final previous = await manager.createQuarantine(
        runId: 'previous-run',
        entries: const <QuarantineEntry>[],
      );
      final temporaryPrimary = File(p.join(temporary.path, 'manifest.json'));
      temporaryPrimary.renameSync('${temporaryPrimary.path}.tmp');
      final previousPrimary = File(p.join(previous.path, 'manifest.json'));
      previousPrimary.renameSync('${previousPrimary.path}.previous');
      final before = <String, String>{
        '${temporaryPrimary.path}.tmp': File(
          '${temporaryPrimary.path}.tmp',
        ).readAsStringSync(),
        '${previousPrimary.path}.previous': File(
          '${previousPrimary.path}.previous',
        ).readAsStringSync(),
      };

      for (final expected in <(String, String)>[
        ('temporary-run', 'temporary'),
        ('previous-run', 'previous'),
      ]) {
        final result = await CliProcessHarness.repository().runQuarantineOnly([
          'quarantine',
          'inspect',
          '--project',
          fixture.root.path,
          '--format',
          'json',
          expected.$1,
        ]);
        expect(result.exitCode, 0);
        expect(result.stderrBytes, isEmpty);
        expectJsonStdout(
          result,
          allOf(
            containsPair('authority', expected.$2),
            containsPair('repairAction', isNot('none')),
          ),
        );
      }

      expect(
        File('${temporaryPrimary.path}.tmp').readAsStringSync(),
        before['${temporaryPrimary.path}.tmp'],
      );
      expect(
        File('${previousPrimary.path}.previous').readAsStringSync(),
        before['${previousPrimary.path}.previous'],
      );
      expect(temporaryPrimary.existsSync(), isFalse);
      expect(previousPrimary.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'list surfaces manifest repair as attention without changing evidence',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine list repair ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_list_repair\n',
      });
      final manager = QuarantineManager(fixture.root);
      final temporary = await manager.createQuarantine(
        runId: 'temporary-repair',
        entries: const <QuarantineEntry>[],
      );
      final previous = await manager.createQuarantine(
        runId: 'previous-repair',
        entries: const <QuarantineEntry>[],
      );
      final temporaryPrimary = File(p.join(temporary.path, 'manifest.json'));
      temporaryPrimary.renameSync('${temporaryPrimary.path}.tmp');
      final previousPrimary = File(p.join(previous.path, 'manifest.json'));
      previousPrimary.renameSync('${previousPrimary.path}.previous');
      final before = <String, String>{
        '${temporaryPrimary.path}.tmp': File(
          '${temporaryPrimary.path}.tmp',
        ).readAsStringSync(),
        '${previousPrimary.path}.previous': File(
          '${previousPrimary.path}.previous',
        ).readAsStringSync(),
      };

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(result.stdoutText);
      final plain = _stripAnsi(result.stdoutText);
      expect(
        plain,
        contains('ATTENTION · REPAIR REQUIRED · COMPLETED · temporary-repair'),
      );
      expect(
        plain,
        contains('ATTENTION · REPAIR REQUIRED · COMPLETED · previous-repair'),
      );
      expect(plain, contains('Repair: Promote the temporary manifest'));
      expect(plain, contains('Repair: Restore the previous manifest'));
      expect(
        File('${temporaryPrimary.path}.tmp').readAsStringSync(),
        before['${temporaryPrimary.path}.tmp'],
      );
      expect(
        File('${previousPrimary.path}.previous').readAsStringSync(),
        before['${previousPrimary.path}.previous'],
      );
      expect(temporaryPrimary.existsSync(), isFalse);
      expect(previousPrimary.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'human output escapes hostile paths while JSON retains exact path bytes',
    () async {
      final fixture = CliFixture.create(prefix: _hostileTerminalProjectSegment);
      addTearDown(fixture.dispose);
      final rootToken = 'terminal-root:${p.basename(fixture.root.path)}';
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_terminal_path\n',
        '.fixture-root-token': rootToken,
        '.flutter_pruner/quarantine/$_hostileTerminalInvalidSegment/manifest.json':
            '{broken',
      });
      final manager = QuarantineManager(fixture.root);
      await manager.createQuarantine(
        runId: 'valid-run',
        entries: const <QuarantineEntry>[],
      );

      final human = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);
      final json = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);
      final inspectHuman = await CliProcessHarness.repository()
          .runQuarantineOnly(
            [
              'quarantine',
              'inspect',
              '--project',
              fixture.root.path,
              'valid-run',
            ],
            environmentAdditions: const <String, String>{'COLUMNS': '32'},
          );
      final inspectJson = await CliProcessHarness.repository()
          .runQuarantineOnly([
            'quarantine',
            'inspect',
            '--project',
            fixture.root.path,
            '--format',
            'json',
            'valid-run',
          ]);

      expect(human.exitCode, 0);
      expect(human.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(human.stdoutText);
      final humanPlain = _stripAnsi(human.stdoutText);
      expect(
        _unwrapVisualLines(humanPlain),
        contains(_unwrapVisualLines(_visibleHostileTerminalProjectSegment)),
      );
      expect(
        _unwrapVisualLines(humanPlain),
        contains(_unwrapVisualLines(_visibleHostileTerminalInvalidSegment)),
      );
      expect(humanPlain, isNot(contains('\x1b')));
      expect(humanPlain, isNot(contains('\nforged')));
      expect(humanPlain, isNot(contains(_unsafeRenderedControl)));
      expect(json.exitCode, 0);
      expect(json.stderrBytes, isEmpty);
      expectJsonStdout(
        json,
        predicate((value) {
          final document = value as Map<String, Object?>;
          final items = document['items']! as List<Object?>;
          final reportedProjectRoot = document['projectRoot']! as String;
          final reportedRootToken = File(
            p.join(reportedProjectRoot, '.fixture-root-token'),
          );
          return reportedRootToken.existsSync() &&
              reportedRootToken.readAsStringSync() == rootToken &&
              items
                  .cast<Map<Object?, Object?>>()
                  .map((item) => item['path'])
                  .contains(
                    p.join(
                      reportedProjectRoot,
                      QuarantineManager.defaultQuarantineDir,
                      _hostileTerminalInvalidSegment,
                    ),
                  ) &&
              items
                  .cast<Map<Object?, Object?>>()
                  .map((item) => item['path'])
                  .contains(
                    p.join(
                      reportedProjectRoot,
                      QuarantineManager.defaultQuarantineDir,
                      'valid-run',
                    ),
                  );
        }, 'JSON preserves exact path controls'),
      );
      expect(inspectHuman.exitCode, 0);
      expect(inspectHuman.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(inspectHuman.stdoutText);
      final inspectHumanPlain = _stripAnsi(inspectHuman.stdoutText);
      expect(
        _unwrapVisualLines(inspectHumanPlain),
        contains(_unwrapVisualLines(_visibleHostileTerminalProjectSegment)),
      );
      expect(inspectHumanPlain, isNot(contains('\nforged')));
      expect(inspectHumanPlain, isNot(contains(_unsafeRenderedControl)));
      final canonicalStart = inspectHumanPlain.indexOf('Canonical manifest:\n');
      expect(canonicalStart, isNonNegative);
      const metrics = TerminalTextMetrics();
      final summary = inspectHumanPlain.substring(0, canonicalStart);
      expect(
        summary.split('\n').where((line) => line.isNotEmpty),
        everyElement(
          predicate<String>((line) => metrics.visibleWidth(line) <= 32),
        ),
      );
      final canonical = inspectHumanPlain.substring(
        canonicalStart + 'Canonical manifest:\n'.length,
      );
      final canonicalDocument = jsonDecode(canonical) as Map<Object?, Object?>;
      expect(
        canonicalDocument['projectRoot'],
        contains(_visibleHostileTerminalProjectSegment),
      );
      expect(inspectJson.exitCode, 0);
      expect(inspectJson.stderrBytes, isEmpty);
      expectJsonStdout(
        inspectJson,
        predicate(
          (value) =>
              (value as Map<String, Object?>)['path'] ==
              p.join(
                fixture.root.path,
                QuarantineManager.defaultQuarantineDir,
                'valid-run',
              ),
          'inspect JSON preserves the exact valid path',
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'JSON surfaces escape raw controls without changing decoded path values',
    () async {
      final fixture = CliFixture.create(prefix: _hostileJsonProjectSegment);
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_json_controls\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'json-control-run',
        entries: const <QuarantineEntry>[],
      );
      final canonicalBase = Directory(
        p.join(fixture.root.path, QuarantineManager.defaultQuarantineDir),
      ).resolveSymbolicLinksSync();
      final canonicalLegacyBase = p.join(
        fixture.root.resolveSymbolicLinksSync(),
        QuarantineManager.legacyQuarantineDir,
      );
      final logicalTarget = quarantine.path;
      final canonicalTarget = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final list = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);
      final inspect = await harness.runQuarantineOnly([
        'quarantine',
        'inspect',
        '--project',
        fixture.root.path,
        '--format',
        'json',
        'json-control-run',
      ]);
      final cleanPlan = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
        '--format',
        'json',
      ]);
      final cleanPlanDocument =
          jsonDecode(cleanPlan.stdoutText) as Map<String, Object?>;
      final fingerprint = cleanPlanDocument['fingerprint']! as String;
      final cleanResult = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--format',
        'json',
        '--confirm-clean-fingerprint',
        fingerprint,
      ]);

      for (final result in <CliProcessResult>[
        list,
        inspect,
        cleanPlan,
        cleanResult,
      ]) {
        expect(result.exitCode, 0);
        expect(result.stderrBytes, isEmpty);
      }

      final listDocument = jsonDecode(list.stdoutText) as Map<String, Object?>;
      expect(listDocument['projectRoot'], fixture.root.path);
      final listItems = listDocument['items']! as List<Object?>;
      expect((listItems.single as Map<String, Object?>)['path'], logicalTarget);

      final inspectDocument =
          jsonDecode(inspect.stdoutText) as Map<String, Object?>;
      expect(inspectDocument['projectRoot'], fixture.root.path);
      expect(inspectDocument['path'], logicalTarget);
      expect(
        (inspectDocument['canonicalManifest']!
            as Map<String, Object?>)['projectRoot'],
        fixture.root.path,
      );

      expect(cleanPlanDocument['canonicalBases'], <Object?>[
        canonicalBase,
        canonicalLegacyBase,
      ]);
      final cleanTargets = cleanPlanDocument['targets']! as List<Object?>;
      expect(
        (cleanTargets.single as Map<String, Object?>)['canonicalPath'],
        canonicalTarget,
      );

      final cleanResultDocument =
          jsonDecode(cleanResult.stdoutText) as Map<String, Object?>;
      final cleanOutcomes = cleanResultDocument['outcomes']! as List<Object?>;
      expect(
        (cleanOutcomes.single as Map<String, Object?>)['canonicalPath'],
        canonicalTarget,
      );

      for (final result in <CliProcessResult>[
        list,
        inspect,
        cleanPlan,
        cleanResult,
      ]) {
        _expectTerminalSafeJsonRepresentation(result);
        expectJsonStdout(result, isA<Map<String, Object?>>());
      }
      expect(quarantine.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test('list empty remains an explicit successful empty state', () async {
    final fixture = CliFixture.create(prefix: 'quarantine list empty ');
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_list_empty\n',
    });

    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'list',
      '--project',
      fixture.root.path,
    ]);

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    _expectOnlyStaticSgr(result.stdoutText);
    expect(_stripAnsi(result.stdoutText), 'No quarantines found.\n');
  }, timeout: processTestTimeout);

  test(
    'list labels completed active and recovery-required evidence distinctly',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine list lifecycle ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_list_lifecycle\n',
      });
      final manager = QuarantineManager(fixture.root);
      await manager.createQuarantine(
        runId: 'completed-run',
        entries: const <QuarantineEntry>[],
      );
      final active = await manager.createCaseQuarantine(
        runId: 'active-run',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: active,
        transactionId: 'active-tx',
        round: 1,
        componentId: 'active-unit',
        findingIds: const <String>['active-finding'],
        caseIds: const <String>['active-case'],
      );
      final recovery = await manager.createCaseQuarantine(
        runId: 'recovery-run',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: recovery,
        transactionId: 'recovery-tx',
        round: 1,
        componentId: 'recovery-unit',
        findingIds: const <String>['recovery-finding'],
        caseIds: const <String>['recovery-case'],
      );
      await manager.markRunRecoveryRequired(
        quarantineDir: recovery,
        reason: 'fixture recovery',
      );

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(result.stdoutText);
      final plain = _stripAnsi(result.stdoutText);
      expect(plain, contains('COMPLETED · completed-run'));
      expect(plain, contains('ACTIVE · active-run'));
      expect(plain, contains('RECOVERY REQUIRED · recovery-run'));
    },
    timeout: processTestTimeout,
  );

  test('list labels a fully verified rollback from journal evidence', () async {
    final fixture = CliFixture.create(prefix: 'quarantine list rolled back ');
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_list_rolled_back\n',
      'lib/rolled_back.dart': 'const before = true;\n',
    });
    final manager = QuarantineManager(fixture.root);
    final evidence = _verificationEvidence(fixture.root);
    final quarantine = await manager.createCaseQuarantine(
      runId: 'rolled-back-run',
      verificationPolicyHash: 'policy',
      baselineVerification: evidence,
    );
    final source = fixture.file('lib/rolled_back.dart');
    await manager.beginTransaction(
      quarantineDir: quarantine,
      transactionId: 'rolled-back-tx',
      round: 1,
      componentId: 'rolled-back-unit',
      findingIds: const <String>['rolled-back-finding'],
      caseIds: const <String>['rolled-back-case'],
    );
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'rolled-back-case',
      findingId: 'rolled-back-finding',
      file: source,
      operationType: QuarantineOperationType.declaration,
      transactionId: 'rolled-back-tx',
    );
    source.writeAsStringSync('const after = true;\n');
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'rolled-back-case',
    );
    await manager.recordTransactionApplied(
      quarantineDir: quarantine,
      transactionId: 'rolled-back-tx',
      caseIds: const <String>['rolled-back-case'],
    );
    await manager.verifyTransaction(
      quarantineDir: quarantine,
      transactionId: 'rolled-back-tx',
      policyHash: 'policy',
      requiredStepIds: const <String>['analyze'],
      observedStepIds: const <String>['analyze'],
    );
    await manager.commitTransaction(
      quarantineDir: quarantine,
      transactionId: 'rolled-back-tx',
    );
    await manager.markRunRecoveryRequired(
      quarantineDir: quarantine,
      reason: 'fixture rollback',
    );
    await manager.restoreRunBytes(quarantineDir: quarantine);
    await manager.verifyRunOriginalBytes(quarantineDir: quarantine);
    await manager.completeVerifiedFullRollback(
      quarantineDir: quarantine,
      reason: 'fixture rollback',
      verificationEvidence: evidence,
      baselineEquivalent: true,
    );

    final result = await CliProcessHarness.repository().runQuarantineOnly([
      'quarantine',
      'list',
      '--project',
      fixture.root.path,
    ]);

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    _expectOnlyStaticSgr(result.stdoutText);
    expect(
      _stripAnsi(result.stdoutText),
      contains('ROLLED BACK · VERIFIED · rolled-back-run'),
    );
  }, timeout: processTestTimeout);

  test('clean rejects --all combined with a run ID before prompting', () async {
    final project = Directory.systemTemp.createTempSync(
      'quarantine_command_test_',
    );
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: quarantine_test\n');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'quarantine',
        'clean',
        '--project',
        project.path,
        '--all',
        'one-run',
      ]);

      expect(exitCode, 64);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'clean --all dry-run renders complete evidence without reading stdin or mutating bytes',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean dry run ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_dry_run\n',
      });
      final manager = QuarantineManager(fixture.root);
      final quarantine = await manager.createQuarantine(
        runId: 'dry-run-target',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
      ], stdinText: 'clean-all 1 forged-proof\n');

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(result.stdoutText);
      expect(result.stdoutText, contains('QUARANTINE CLEAN PREVIEW'));
      expect(result.stdoutText, contains('Scope: all'));
      expect(result.stdoutText, contains('Targets: 1'));
      expect(result.stdoutText, contains('dry-run-target'));
      expect(
        result.stdoutText,
        contains(quarantine.resolveSymbolicLinksSync()),
      );
      expect(
        result.stdoutText,
        contains(RegExp(r'Fingerprint: v2:[0-9a-f]{64}')),
      );
      expect(result.stdoutText, contains('Backend: recoverableLogicalMove'));
      expect(result.stdoutText, contains('Identity-bound move: yes'));
      expect(result.stdoutText, contains('Physical delete: no'));
      expect(result.stdoutText, contains('CLEAN-TOCTOU-1'));
      expect(
        result.stdoutText,
        contains('No quarantine evidence was removed.'),
      );
      expect(quarantine.existsSync(), isTrue);
      expect(manifest.readAsBytesSync(), originalManifestBytes);
    },
    timeout: processTestTimeout,
  );

  test(
    'targeted clean dry-run JSON is one exact non-mutating document',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean json dry run ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_json_dry_run\n',
      });
      final manager = QuarantineManager(fixture.root);
      final quarantine = await manager.createQuarantine(
        runId: 'json-dry-run',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--dry-run',
        '--format',
        'json',
        'json-dry-run',
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expectNoAnsi(result);
      expectJsonStdout(
        result,
        allOf(
          containsPair('schemaVersion', 1),
          containsPair('kind', 'quarantineCleanPlan'),
          containsPair('scope', 'targeted'),
          containsPair('targetCount', 1),
          containsPair('fingerprint', matches(r'^v2:[0-9a-f]{64}$')),
          containsPair(
            'targets',
            contains(
              allOf(
                containsPair('runId', 'json-dry-run'),
                containsPair(
                  'canonicalPath',
                  quarantine.resolveSymbolicLinksSync(),
                ),
              ),
            ),
          ),
          containsPair(
            'backend',
            allOf(
              containsPair('name', 'recoverableLogicalMove'),
              containsPair('identityBoundMove', true),
              containsPair('physicalDelete', false),
              containsPair('releaseEligible', false),
              containsPair('blockerCode', 'CLEAN-TOCTOU-1'),
            ),
          ),
        ),
      );
      expect(quarantine.existsSync(), isTrue);
      expect(manifest.readAsBytesSync(), originalManifestBytes);
    },
    timeout: processTestTimeout,
  );

  test(
    'clean dry-run escapes hostile human paths while JSON retains exact values',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean safe projection ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_safe_projection\n',
      });
      final relativeBase = '.flutter_pruner/custom-$_hostileCleanPathSegment';
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'safe-projection-run',
        entries: const <QuarantineEntry>[],
        quarantineBase: relativeBase,
      );
      final canonicalBase = Directory(
        p.join(fixture.root.path, relativeBase),
      ).resolveSymbolicLinksSync();
      final canonicalTarget = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final human = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
        '--quarantine',
        relativeBase,
      ]);
      final json = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
        '--format',
        'json',
        '--quarantine',
        relativeBase,
      ]);

      expect(human.exitCode, 0);
      expect(human.stderrBytes, isEmpty);
      _expectOnlyStaticSgr(human.stdoutText);
      final humanPlain = _stripAnsi(human.stdoutText);
      expect(
        _unwrapVisualLines(humanPlain),
        contains(_unwrapVisualLines(_visibleHostileCleanPathSegment)),
      );
      expect(humanPlain, isNot(contains('\nFORGED CLEAN ROW')));
      expect(humanPlain, isNot(contains(_unsafeRenderedControl)));
      expect(json.exitCode, 0);
      expect(json.stderrBytes, isEmpty);
      expectNoAnsi(json);
      expectJsonStdout(
        json,
        allOf(
          containsPair('canonicalBases', <Object?>[canonicalBase]),
          containsPair('targets', <Object?>[
            allOf(
              containsPair('runId', 'safe-projection-run'),
              containsPair('canonicalPath', canonicalTarget),
            ),
          ]),
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'clean preview and reviewed errors escape hostile invalid paths',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean safe errors ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_safe_errors\n',
        '.flutter_pruner/quarantine/$_hostileCleanPathSegment/manifest.json':
            '{broken',
      });
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final preview = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
      ]);
      final reviewed = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--format',
        'json',
        '--confirm-clean-fingerprint',
        'v1:0000000000000000000000000000000000000000000000000000000000000000',
      ]);

      for (final result in <CliProcessResult>[preview, reviewed]) {
        expect(result.exitCode, 1);
        expect(result.stdoutBytes, isEmpty);
        expectNoAnsi(result);
        expect(
          result.stderrText.replaceAll('\n', ''),
          contains(_visibleHostileCleanPathSegment),
        );
        expect(result.stderrText, isNot(contains('\nFORGED CLEAN ROW')));
        expect(result.stderrText, isNot(contains(_unsafeRenderedControl)));
        expect(
          const LineSplitter()
              .convert(result.stderrText)
              .where((line) => line == 'FORGED CLEAN ROW'),
          isEmpty,
        );
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'clean rejects a hostile explicit base without terminal injection',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean hostile base ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_hostile_base\n',
      });
      final hostileBase = '../$_hostileCleanPathSegment';
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final preview = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
        '--quarantine',
        hostileBase,
      ]);
      final reviewed = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--quarantine',
        hostileBase,
      ]);

      for (final result in <CliProcessResult>[preview, reviewed]) {
        expect(result.exitCode, 64);
        expect(result.stdoutBytes, isEmpty);
        expectNoAnsi(result);
        expect(result.stderrText, contains(_visibleHostileCleanPathSegment));
        expect(result.stderrText, isNot(contains('\nFORGED CLEAN ROW')));
        expect(result.stderrText, isNot(contains(_unsafeRenderedControl)));
        expect(
          const LineSplitter()
              .convert(result.stderrText)
              .where((line) => line == 'FORGED CLEAN ROW'),
          isEmpty,
        );
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'test-only fake all-target JSON requires the full proof and emits a typed receipt',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean fake success ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_fake_success\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'fake-success',
        entries: const <QuarantineEntry>[],
      );
      final canonicalQuarantinePath = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final preview = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--dry-run',
        '--format',
        'json',
      ]);
      final previewJson =
          jsonDecode(preview.stdoutText) as Map<String, Object?>;
      final fingerprint = previewJson['fingerprint']! as String;

      final result = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--format',
        'json',
        '--confirm-clean-fingerprint',
        fingerprint,
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expectNoAnsi(result);
      expectJsonStdout(
        result,
        allOf(
          containsPair('schemaVersion', 1),
          containsPair('kind', 'quarantineCleanResult'),
          containsPair('fingerprint', fingerprint),
          containsPair('deletionAttempted', true),
          containsPair('complete', true),
          containsPair('receiptCrashDurable', false),
          containsPair('outcomes', <Object?>[
            allOf(
              containsPair('runId', 'fake-success'),
              containsPair('canonicalPath', canonicalQuarantinePath),
              containsPair('state', 'removed'),
            ),
          ]),
        ),
      );
      expect(quarantine.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'interactive all-target clean cancels on generic assent, blank input, and EOF',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean cancel ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_cancel\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'cancel-run',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      for (final input in <String?>['y\n', 'yes\n', '\n', null]) {
        final events = fixture.file(
          'events-${input == null ? 'eof' : input.codeUnits.first}.txt',
        );
        final result = await harness.runQuarantineCleanFake(
          ['quarantine', 'clean', '--project', fixture.root.path, '--all'],
          stdinText: input,
          environmentAdditions: <String, String>{
            'FLUTTER_PRUNER_TEST_CLEAN_TTY': '1',
            'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
          },
        );

        expect(result.exitCode, 0, reason: '$input');
        expect(result.stderrBytes, isEmpty, reason: '$input');
        expect(result.stdoutText, contains('Cancelled.'), reason: '$input');
        expect(events.existsSync(), isFalse, reason: '$input');
        expect(quarantine.existsSync(), isTrue, reason: '$input');
        expect(
          manifest.readAsBytesSync(),
          originalManifestBytes,
          reason: '$input',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'non-TTY all-target execution never reads stdin and requires full proof',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean non tty ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_non_tty\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'non-tty-run',
        entries: const <QuarantineEntry>[],
      );
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final phrase = 'clean-all 1 ${fingerprint.substring(3, 15)}\n';

      final missing = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
      ], stdinText: phrase);
      final malformed = await harness.runQuarantineCleanFake([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--confirm-clean-fingerprint',
        'v1:ABC',
      ]);

      for (final result in [missing, malformed]) {
        expect(result.exitCode, 64);
        expect(result.stdoutBytes, isEmpty);
        expect(result.stderrText, contains('--confirm-clean-fingerprint'));
      }
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'empty all-target execution returns without proof or stdin reads',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean empty ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_empty\n',
      });
      final result = await CliProcessHarness.repository()
          .runQuarantineCleanFake([
            'quarantine',
            'clean',
            '--project',
            fixture.root.path,
            '--all',
            '--format',
            'json',
          ], stdinText: 'must-not-be-read\n');

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expectJsonStdout(
        result,
        allOf(
          containsPair('kind', 'quarantineCleanPlan'),
          containsPair('targetCount', 0),
        ),
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'interactive prompt releases the project lock and execution reacquires it',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean lock prompt ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_lock_prompt\n',
      });
      final quarantine = await QuarantineManager(
        fixture.root,
      ).createQuarantine(runId: 'lock-run', entries: const <QuarantineEntry>[]);
      final promptReady = fixture.file('prompt.ready');
      final promptRelease = fixture.file('prompt.release');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final phrase = 'clean-all 1 ${fingerprint.substring(3, 15)}\n';
      final invocation = await harness.startQuarantineCleanFake(
        ['quarantine', 'clean', '--project', fixture.root.path, '--all'],
        stdinText: phrase,
        readyFile: promptReady,
        releaseFile: promptRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_TTY': '1',
          'FLUTTER_PRUNER_TEST_CLEAN_PROMPT_READY': promptReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_PROMPT_RELEASE': promptRelease.path,
        },
      );
      await waitForReadyFile(promptReady, timeout: const Duration(seconds: 15));

      final competingLock = await ProjectOperationLock.acquire(
        workspace: ToolWorkspace(fixture.root),
        operation: 'q5-lock-release-proof',
      );
      await competingLock.release();
      promptRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expect(result.stdoutText, contains('Removed: lock-run'));
      expect(quarantine.existsSync(), isFalse);
    },
    timeout: processTestTimeout,
  );

  test(
    'evidence drift while the prompt is unlocked stops before the first delete',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean prompt drift ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_prompt_drift\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'prompt-drift-run',
        entries: const <QuarantineEntry>[],
      );
      final promptReady = fixture.file('prompt.ready');
      final promptRelease = fixture.file('prompt.release');
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final invocation = await harness.startQuarantineCleanFake(
        ['quarantine', 'clean', '--project', fixture.root.path, '--all'],
        stdinText: 'clean-all 1 ${fingerprint.substring(3, 15)}\n',
        readyFile: promptReady,
        releaseFile: promptRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_TTY': '1',
          'FLUTTER_PRUNER_TEST_CLEAN_PROMPT_READY': promptReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_PROMPT_RELEASE': promptRelease.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );
      await waitForReadyFile(promptReady, timeout: const Duration(seconds: 15));
      File(p.join(quarantine.path, 'drift.txt')).writeAsStringSync('changed');
      promptRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 2);
      expect(result.stderrText, contains('changed before the retained move'));
      expect(result.stdoutText, isNot(contains('QUARANTINE CLEAN RECEIPT')));
      expect(events.existsSync(), isFalse);
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'suffix drift after one removal emits removed and preserved JSON outcomes',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean suffix drift ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_suffix_drift\n',
      });
      final manager = QuarantineManager(fixture.root);
      final first = await manager.createQuarantine(
        runId: 'first-run',
        entries: const <QuarantineEntry>[],
      );
      final second = await manager.createQuarantine(
        runId: 'second-run',
        entries: const <QuarantineEntry>[],
      );
      final third = await manager.createQuarantine(
        runId: 'third-run',
        entries: const <QuarantineEntry>[],
      );
      final executorReady = fixture.file('executor.ready');
      final executorRelease = fixture.file('executor.release');
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        readyFile: executorReady,
        releaseFile: executorRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'pause_after_first',
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY': executorReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE': executorRelease.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );
      await waitForReadyFile(
        executorReady,
        timeout: const Duration(seconds: 30),
      );
      expect(first.existsSync(), isFalse);
      File(p.join(second.path, 'suffix-drift.txt')).writeAsStringSync('drift');
      executorRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 1);
      expect(result.stderrText, contains('stopped after a target changed'));
      expectJsonStdout(
        result,
        allOf(
          containsPair('deletionAttempted', true),
          containsPair('complete', false),
          containsPair('outcomes', <Object?>[
            containsPair('state', 'removed'),
            containsPair('state', 'preserved'),
            containsPair('state', 'notAttempted'),
          ]),
        ),
      );
      expect(second.existsSync(), isTrue);
      expect(third.existsSync(), isTrue);
      expect(events.readAsLinesSync(), <String>[
        'boundary:first-run',
        'removed:first-run',
      ]);
    },
    timeout: processTestTimeout,
  );

  test(
    'new cleanable sibling after one removal invalidates the remaining all-target suffix',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean suffix insertion ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_suffix_insertion\n',
      });
      final manager = QuarantineManager(fixture.root);
      final first = await manager.createQuarantine(
        runId: 'a-first-run',
        entries: const <QuarantineEntry>[],
      );
      final second = await manager.createQuarantine(
        runId: 'b-second-run',
        entries: const <QuarantineEntry>[],
      );
      final executorReady = fixture.file('executor.ready');
      final executorRelease = fixture.file('executor.release');
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        readyFile: executorReady,
        releaseFile: executorRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'pause_after_first',
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY': executorReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE': executorRelease.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );
      await waitForReadyFile(
        executorReady,
        timeout: const Duration(seconds: 30),
      );
      expect(first.existsSync(), isFalse);
      final inserted = await manager.createQuarantine(
        runId: 'inserted-run',
        entries: const <QuarantineEntry>[],
      );
      executorRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 1);
      expectJsonStdout(
        result,
        containsPair('outcomes', <Object?>[
          containsPair('state', 'removed'),
          containsPair('state', 'preserved'),
        ]),
      );
      expect(second.existsSync(), isTrue);
      expect(inserted.existsSync(), isTrue);
      expect(events.readAsLinesSync(), <String>[
        'boundary:a-first-run',
        'removed:a-first-run',
      ]);
    },
    timeout: processTestTimeout,
  );

  test(
    'first all-target JSON delete exception is outcomeUnknown with no false removal',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean unknown all ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_unknown_all\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'unknown-all',
        entries: const <QuarantineEntry>[],
      );
      final canonicalPath = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        environmentAdditions: const <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'mutate_then_throw',
          'COLUMNS': '32',
        },
      );

      expect(result.exitCode, 1);
      _expectHumanLinesAtMost(result, width: 32, includeStdout: false);
      expect(
        _unwrapVisualLines(result.stderrText),
        'Error:quarantinedeletionoutcomeisunknown.Inspectsurvivingevidencebeforeanotheraction.',
      );
      final expected = <String, Object?>{
        'schemaVersion': 1,
        'kind': 'quarantineCleanResult',
        'fingerprint': fingerprint,
        'deletionAttempted': true,
        'complete': false,
        'receiptCrashDurable': false,
        'outcomes': <Object?>[
          <String, Object?>{
            'runId': 'unknown-all',
            'canonicalPath': canonicalPath,
            'state': 'outcomeUnknown',
            'failure': <String, Object?>{
              'code': 'delete_failed',
              'message': 'Injected failure after fixture mutation.',
            },
          },
        ],
        'failure': <String, Object?>{
          'code': 'delete_failed',
          'message': 'Injected failure after fixture mutation.',
        },
      };
      expect(result.stdoutText, jsonEncode(expected));
      expectJsonStdout(result, equals(expected));
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'targeted JSON delete exception emits a receipt after its deletion boundary',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean unknown targeted ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_unknown_targeted\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'unknown-targeted',
        entries: const <QuarantineEntry>[],
      );
      final canonicalPath = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(
        harness,
        fixture.root,
        runId: 'unknown-targeted',
      );

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--format',
          'json',
          'unknown-targeted',
        ],
        environmentAdditions: const <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'throw',
        },
      );

      expect(result.exitCode, 1);
      expect(
        result.stderrText,
        'Error: quarantine deletion outcome is unknown. Inspect surviving evidence before another action.\n',
      );
      final expected = <String, Object?>{
        'schemaVersion': 1,
        'kind': 'quarantineCleanResult',
        'fingerprint': fingerprint,
        'deletionAttempted': true,
        'complete': false,
        'receiptCrashDurable': false,
        'outcomes': <Object?>[
          <String, Object?>{
            'runId': 'unknown-targeted',
            'canonicalPath': canonicalPath,
            'state': 'outcomeUnknown',
            'failure': <String, Object?>{
              'code': 'delete_failed',
              'message': 'Injected delete failure.',
            },
          },
        ],
        'failure': <String, Object?>{
          'code': 'delete_failed',
          'message': 'Injected delete failure.',
        },
      };
      expect(result.stdoutText, jsonEncode(expected));
      expectJsonStdout(result, equals(expected));
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'reviewed human delete exception wraps complete evidence at 32 columns',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean reviewed human outcome unknown ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_reviewed_human_unknown\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'human-unknown-target',
        entries: const <QuarantineEntry>[],
      );
      final canonicalPath = quarantine.resolveSymbolicLinksSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          'human-unknown-target',
        ],
        environmentAdditions: const <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'throw',
          'COLUMNS': '32',
        },
      );

      expect(result.exitCode, 1);
      _expectHumanLinesAtMost(result, width: 32);
      final receipt = _unwrapVisualLines(_stripAnsi(result.stdoutText));
      expect(receipt, contains('Outcomeunknown:human-unknown-target'));
      expect(receipt, contains('Path:${_unwrapVisualLines(canonicalPath)}'));
      expect(receipt, contains('Failure:delete_failed—Injecteddeletefailure.'));
      expect(
        _unwrapVisualLines(result.stderrText),
        'Error:quarantinedeletionoutcomeisunknown.Inspectsurvivingevidencebeforeanotheraction.',
      );
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'stale JSON proof stops before the delete boundary with empty stdout',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean stale json ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_stale_json\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'stale-json-run',
        entries: const <QuarantineEntry>[],
      );
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      File(
        p.join(quarantine.path, 'new-evidence.txt'),
      ).writeAsStringSync('drift');

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        stdinText: 'must-not-be-read\n',
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );

      expect(result.exitCode, 2);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrText, contains('evidence is stale'));
      expect(events.existsSync(), isFalse);
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'typed drift after the full-plan compare remains stale before the first boundary',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean pre-boundary drift ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_pre_boundary_drift\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'pre-boundary-drift',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();
      final planReady = fixture.file('plan.ready');
      final planRelease = fixture.file('plan.release');
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        readyFile: planReady,
        releaseFile: planRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_PLAN_PAUSE_CALL': '3',
          'FLUTTER_PRUNER_TEST_CLEAN_PLAN_READY': planReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_PLAN_RELEASE': planRelease.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );
      await waitForReadyFile(planReady, timeout: const Duration(seconds: 15));
      final drift = File(p.join(quarantine.path, 'post-compare-drift.txt'))
        ..writeAsStringSync('drift');
      planRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 2);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrText, contains('drifted between snapshots'));
      expect(events.existsSync(), isFalse);
      expect(quarantine.existsSync(), isTrue);
      expect(drift.readAsStringSync(), 'drift');
      expect(manifest.readAsBytesSync(), originalManifestBytes);
    },
    timeout: processTestTimeout,
  );

  test(
    'unexpected planner errors after the full compare retain internal failure semantics',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean unexpected planner ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_unexpected_planner\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'unexpected-planner',
        entries: const <QuarantineEntry>[],
      );
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);

      for (final throwKind in const <String>[
        'state_error',
        'format_exception',
      ]) {
        final events = fixture.file('$throwKind.events');
        final result = await harness.runQuarantineCleanFake(
          [
            'quarantine',
            'clean',
            '--project',
            fixture.root.path,
            '--all',
            '--format',
            'json',
            '--confirm-clean-fingerprint',
            fingerprint,
          ],
          environmentAdditions: <String, String>{
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_CALL': '3',
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_KIND': throwKind,
            'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
          },
        );

        expect(result.exitCode, 70, reason: throwKind);
        expect(result.stdoutBytes, isEmpty, reason: throwKind);
        expect(
          result.stderrText,
          startsWith('Internal error:'),
          reason: throwKind,
        );
        expect(
          result.stderrText,
          isNot(contains('stopped after a target changed')),
          reason: throwKind,
        );
        expect(events.existsSync(), isFalse, reason: throwKind);
        expect(quarantine.existsSync(), isTrue, reason: throwKind);
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'unexpected planner errors after one removal emit one exact JSON receipt',
    () async {
      for (final throwKind in const <String>[
        'state_error',
        'format_exception',
      ]) {
        final fixture = CliFixture.create(
          prefix: 'quarantine clean post-removal JSON $throwKind ',
        );
        addTearDown(fixture.dispose);
        await fixture.writeText(<String, String>{
          'pubspec.yaml':
              'name: quarantine_clean_post_removal_json_$throwKind\n',
        });
        final manager = QuarantineManager(fixture.root);
        final first = await manager.createQuarantine(
          runId: 'internal-a-removed',
          entries: const <QuarantineEntry>[],
        );
        final second = await manager.createQuarantine(
          runId: 'internal-b-preserved',
          entries: const <QuarantineEntry>[],
        );
        final third = await manager.createQuarantine(
          runId: 'internal-c-not-attempted',
          entries: const <QuarantineEntry>[],
        );
        final firstPath = first.resolveSymbolicLinksSync();
        final secondPath = second.resolveSymbolicLinksSync();
        final thirdPath = third.resolveSymbolicLinksSync();
        final events = fixture.file('$throwKind.events');
        final harness = CliProcessHarness.repository();
        addTearDown(harness.close);
        final fingerprint = await _previewCleanFingerprint(
          harness,
          fixture.root,
        );

        final result = await harness.runQuarantineCleanFake(
          [
            'quarantine',
            'clean',
            '--project',
            fixture.root.path,
            '--all',
            '--format',
            'json',
            '--confirm-clean-fingerprint',
            fingerprint,
          ],
          environmentAdditions: <String, String>{
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_CALL': '4',
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_KIND': throwKind,
            'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
            'COLUMNS': '32',
          },
        );

        expect(result.exitCode, 70, reason: throwKind);
        _expectHumanLinesAtMost(result, width: 32, includeStdout: false);
        expectJsonStdout(
          result,
          equals(<String, Object?>{
            'schemaVersion': 1,
            'kind': 'quarantineCleanResult',
            'fingerprint': fingerprint,
            'deletionAttempted': true,
            'complete': false,
            'receiptCrashDurable': false,
            'outcomes': <Object?>[
              <String, Object?>{
                'runId': 'internal-a-removed',
                'canonicalPath': firstPath,
                'state': 'removed',
              },
              <String, Object?>{
                'runId': 'internal-b-preserved',
                'canonicalPath': secondPath,
                'state': 'preserved',
                'failure': <String, Object?>{
                  'code': 'internal_revalidation_failed',
                  'message':
                      'Quarantine clean stopped after an internal revalidation failure.',
                },
              },
              <String, Object?>{
                'runId': 'internal-c-not-attempted',
                'canonicalPath': thirdPath,
                'state': 'notAttempted',
              },
            ],
            'failure': <String, Object?>{
              'code': 'internal_revalidation_failed',
              'message':
                  'Quarantine clean stopped after an internal revalidation failure.',
            },
          }),
        );
        expect(
          _unwrapVisualLines(result.stderrText),
          'Internalerror:quarantinecleanstoppedafteraninternalrevalidationfailure.Inspectthepartialreceiptbeforeanotheraction.',
          reason: throwKind,
        );
        expect(
          '${result.stdoutText}${result.stderrText}',
          isNot(contains('Injected clean-plan')),
          reason: throwKind,
        );
        expect(events.readAsLinesSync(), <String>[
          'boundary:internal-a-removed',
          'removed:internal-a-removed',
        ], reason: throwKind);
        expect(first.existsSync(), isFalse, reason: throwKind);
        expect(second.existsSync(), isTrue, reason: throwKind);
        expect(third.existsSync(), isTrue, reason: throwKind);
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'unexpected planner errors after one removal retain the human partial receipt',
    () async {
      for (final throwKind in const <String>[
        'state_error',
        'format_exception',
      ]) {
        final fixture = CliFixture.create(
          prefix: 'quarantine clean post-removal human $throwKind ',
        );
        addTearDown(fixture.dispose);
        await fixture.writeText(<String, String>{
          'pubspec.yaml':
              'name: quarantine_clean_post_removal_human_$throwKind\n',
        });
        final manager = QuarantineManager(fixture.root);
        final first = await manager.createQuarantine(
          runId: 'human-internal-a-removed',
          entries: const <QuarantineEntry>[],
        );
        final second = await manager.createQuarantine(
          runId: 'human-internal-b-preserved',
          entries: const <QuarantineEntry>[],
        );
        final third = await manager.createQuarantine(
          runId: 'human-internal-c-not-attempted',
          entries: const <QuarantineEntry>[],
        );
        final secondPath = second.resolveSymbolicLinksSync();
        final events = fixture.file('$throwKind.human.events');
        final harness = CliProcessHarness.repository();
        addTearDown(harness.close);
        final fingerprint = await _previewCleanFingerprint(
          harness,
          fixture.root,
        );

        final result = await harness.runQuarantineCleanFake(
          [
            'quarantine',
            'clean',
            '--project',
            fixture.root.path,
            '--all',
            '--confirm-clean-fingerprint',
            fingerprint,
          ],
          environmentAdditions: <String, String>{
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_CALL': '4',
            'FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_KIND': throwKind,
            'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
            'COLUMNS': '32',
          },
        );

        expect(result.exitCode, 70, reason: throwKind);
        _expectHumanLinesAtMost(result, width: 32);
        final transcript = _unwrapVisualLines(result.stdoutText);
        expect(
          RegExp('QUARANTINECLEANRECEIPT').allMatches(transcript),
          hasLength(1),
          reason: throwKind,
        );
        expect(
          transcript,
          contains('Removed:human-internal-a-removed'),
          reason: throwKind,
        );
        expect(
          transcript,
          contains('Preserved:human-internal-b-preserved'),
          reason: throwKind,
        );
        expect(
          transcript,
          contains('Notattempted:human-internal-c-not-attempted'),
          reason: throwKind,
        );
        expect(
          transcript,
          contains('Path:${_unwrapVisualLines(secondPath)}'),
          reason: throwKind,
        );
        expect(
          transcript,
          contains(
            'Failure:internal_revalidation_failed—Quarantinecleanstoppedafteraninternalrevalidationfailure.',
          ),
          reason: throwKind,
        );
        expect(
          transcript,
          contains('Receipt:notcrash-durableproof.'),
          reason: throwKind,
        );
        expect(
          _unwrapVisualLines(result.stderrText),
          'Internalerror:quarantinecleanstoppedafteraninternalrevalidationfailure.Inspectthepartialreceiptbeforeanotheraction.',
          reason: throwKind,
        );
        expect(
          '${result.stdoutText}${result.stderrText}',
          isNot(contains('Injected clean-plan')),
          reason: throwKind,
        );
        expect(events.readAsLinesSync(), <String>[
          'boundary:human-internal-a-removed',
          'removed:human-internal-a-removed',
        ], reason: throwKind);
        expect(first.existsSync(), isFalse, reason: throwKind);
        expect(second.existsSync(), isTrue, reason: throwKind);
        expect(third.existsSync(), isTrue, reason: throwKind);
      }
    },
    timeout: processTestTimeout,
  );

  test(
    'production clean-all retains exact evidence while the release blocker stays open',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean no wiring ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_no_wiring\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'no-wiring-run',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);

      final result = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--format',
        'json',
        '--confirm-clean-fingerprint',
        fingerprint,
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      final receipt = jsonDecode(result.stdoutText) as Map<String, Object?>;
      expect(receipt['kind'], 'quarantineCleanResult');
      expect(receipt['physicalDelete'], isFalse);
      expect(receipt['complete'], isTrue);
      final outcome =
          (receipt['outcomes']! as List<Object?>).single
              as Map<String, Object?>;
      expect(outcome['state'], 'retained');
      expect(outcome['physicalBytesRetained'], isTrue);
      expect(quarantine.existsSync(), isFalse);
      expect(
        File(
          p.join(outcome['retainedPath']! as String, 'manifest.json'),
        ).readAsBytesSync(),
        originalManifestBytes,
      );
    },
    timeout: processTestTimeout,
  );

  test(
    'legacy targeted clean escapes a hostile custom-base manager error',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine legacy targeted safe error ',
      );
      addTearDown(fixture.dispose);
      final relativeBase =
          '.flutter_pruner/legacy-targeted-$_hostileLegacyPathSegment';
      const runId = 'legacy-invalid-target';
      final manifestPath = '$relativeBase/$runId/manifest.json';
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_legacy_targeted_safe_error\n',
        manifestPath: '{broken',
      });
      final manifest = fixture.file(manifestPath);
      final originalManifestBytes = manifest.readAsBytesSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final result = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--quarantine',
        relativeBase,
        runId,
      ]);

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      _expectTerminalSafeLegacyFailure(result);
      expect(manifest.readAsBytesSync(), originalManifestBytes);
      expect(manifest.parent.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'legacy all clean escapes a hostile invalid child and preserves the batch',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine legacy all safe error ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_legacy_all_safe_error\n',
      });
      final relativeBase =
          '.flutter_pruner/legacy-all-$_hostileLegacyPathSegment';
      final cleanable = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'legacy-cleanable-sibling',
        entries: const <QuarantineEntry>[],
        quarantineBase: relativeBase,
      );
      final cleanableManifest = File(p.join(cleanable.path, 'manifest.json'));
      final originalCleanableBytes = cleanableManifest.readAsBytesSync();
      final invalidManifest = fixture.file(
        '$relativeBase/legacy-invalid-child/manifest.json',
      );
      await invalidManifest.parent.create(recursive: true);
      await invalidManifest.writeAsString('{broken');
      final originalInvalidBytes = invalidManifest.readAsBytesSync();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final result = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--quarantine',
        relativeBase,
      ], stdinText: 'y\n');

      expect(result.exitCode, 1);
      expect(result.stdoutText, isEmpty);
      _expectTerminalSafeLegacyFailure(result);
      expect(cleanable.existsSync(), isTrue);
      expect(cleanableManifest.readAsBytesSync(), originalCleanableBytes);
      expect(invalidManifest.readAsBytesSync(), originalInvalidBytes);
    },
    timeout: processTestTimeout,
  );

  test(
    'legacy clean lock error escapes a hostile project path without mutation',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine legacy lock safe error ',
      );
      addTearDown(fixture.dispose);
      final project = Directory(
        p.join(fixture.root.path, _hostileLegacyPathSegment),
      );
      await project.create(recursive: true);
      await File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsString('name: quarantine_legacy_lock_safe_error\n');
      final quarantine = await QuarantineManager(project).createQuarantine(
        runId: 'legacy-lock-target',
        entries: const <QuarantineEntry>[],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      final originalManifestBytes = manifest.readAsBytesSync();
      final lock = await ProjectOperationLock.acquire(
        workspace: ToolWorkspace(project),
        operation: 'hostile-project-lock-holder',
      );
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      late final CliProcessResult result;
      try {
        result = await harness.runQuarantineOnly([
          'quarantine',
          'clean',
          '--project',
          project.path,
          'legacy-lock-target',
        ]);
      } finally {
        await lock.release();
      }

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      _expectTerminalSafeLegacyFailure(result);
      expect(quarantine.existsSync(), isTrue);
      expect(manifest.readAsBytesSync(), originalManifestBytes);
    },
    timeout: processTestTimeout,
  );

  test(
    'production targeted clean moves evidence into retained storage',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean legacy targeted ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_legacy_targeted\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'legacy-targeted-run',
        entries: const <QuarantineEntry>[],
      );

      final result = await CliProcessHarness.repository().runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        'legacy-targeted-run',
      ]);

      expect(result.exitCode, 0);
      expect(result.stderrBytes, isEmpty);
      expect(result.stdoutText, contains('QUARANTINE LOGICALLY CLEANED'));
      expect(result.stdoutText, contains('Disk space: retained'));
      expect(result.stdoutText, contains('Recovery copy:'));
      expect(result.stdoutText, isNot(contains('Removed quarantine')));
      expect(quarantine.existsSync(), isFalse);
      final retainedRoot = Directory(
        p.join(
          fixture.root.path,
          '.flutter_pruner',
          'quarantine',
          '.clean-retained',
          'v1',
        ),
      );
      expect(retainedRoot.listSync(), hasLength(1));
    },
    timeout: processTestTimeout,
  );

  test(
    'retained list inspect and restore expose durable recovery authority',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine retained cli ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_retained_cli\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'retained-cli-run',
        entries: const <QuarantineEntry>[],
      );
      final harness = CliProcessHarness.repository();
      final cleaned = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        'retained-cli-run',
      ]);
      final operationId = RegExp(
        r'Operation ID: (clean-[0-9TZ-]+[0-9a-f]+)',
      ).firstMatch(cleaned.stdoutText)!.group(1)!;

      final listed = await harness.runQuarantineOnly([
        'quarantine',
        'retained',
        'list',
        '--project',
        fixture.root.path,
        '--format',
        'json',
      ]);
      expect(listed.exitCode, 0);
      expectJsonStdout(
        listed,
        allOf(
          containsPair('kind', 'retainedCleanList'),
          containsPair(
            'operations',
            contains(
              allOf(
                containsPair('operationId', operationId),
                containsPair('state', 'retained'),
                containsPair('runIds', contains('retained-cli-run')),
              ),
            ),
          ),
        ),
      );

      final inspected = await harness.runQuarantineOnly([
        'quarantine',
        'retained',
        'inspect',
        '--project',
        fixture.root.path,
        '--format',
        'json',
        operationId,
      ]);
      expect(inspected.exitCode, 0);
      expect(inspected.stdoutText, contains('retained-committed'));

      final restored = await harness.runQuarantineOnly([
        'quarantine',
        'retained',
        'restore',
        '--project',
        fixture.root.path,
        '--format',
        'json',
        operationId,
        'retained-cli-run',
      ]);
      expect(restored.exitCode, 0);
      expectJsonStdout(
        restored,
        allOf(
          containsPair('kind', 'retainedCleanRestore'),
          containsPair('operationId', operationId),
          containsPair('runId', 'retained-cli-run'),
          containsPair('noReplace', true),
        ),
      );
      expect(quarantine.existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('targeted logical clean retains unreadable descendant bytes', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final fixture = CliFixture.create(
      prefix: 'quarantine legacy targeted delete unknown ',
    );
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_legacy_targeted_delete_unknown\n',
    });
    final quarantine = await QuarantineManager(fixture.root).createQuarantine(
      runId: 'legacy-targeted-delete-unknown',
      entries: const <QuarantineEntry>[],
    );
    final locked = Directory(p.join(quarantine.path, 'locked'))..createSync();
    final retained = File(p.join(locked.path, 'retained.bin'))
      ..writeAsBytesSync(<int>[0, 1, 2, 3], flush: true);
    final originalBytes = retained.readAsBytesSync();
    _chmodPath(locked.path, 0x140);
    addTearDown(() {
      final lockedDirectories = fixture.root
          .listSync(recursive: true, followLinks: false)
          .whereType<Directory>()
          .where((directory) => p.basename(directory.path) == 'locked');
      for (final directory in lockedDirectories) {
        _chmodPath(directory.path, 0x1c0);
      }
    });

    final result = await CliProcessHarness.repository().runQuarantineOnly(
      [
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        'legacy-targeted-delete-unknown',
      ],
      environmentAdditions: const <String, String>{'COLUMNS': '32'},
    );

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    _expectHumanLinesAtMost(result, width: 32);
    final transcript = _unwrapVisualLines(
      '${result.stdoutText}\n${result.stderrText}',
    );
    expect(transcript, contains('QUARANTINELOGICALLYCLEANED'));
    expect(transcript, contains('Diskspace:retained'));
    expect(result.stdoutText, isNot(contains('Removed quarantine')));
    final retainedFiles =
        Directory(
              p.join(
                fixture.root.path,
                '.flutter_pruner',
                'quarantine',
                '.clean-retained',
                'v1',
              ),
            )
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => p.basename(file.path) == 'retained.bin')
            .toList();
    expect(retainedFiles, hasLength(1));
    expect(retainedFiles.single.readAsBytesSync(), originalBytes);
  }, timeout: processTestTimeout);

  test('logical clean all retains every selected quarantine', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final fixture = CliFixture.create(
      prefix: 'quarantine legacy all delete unknown ',
    );
    addTearDown(fixture.dispose);
    await fixture.writeText(<String, String>{
      'pubspec.yaml': 'name: quarantine_legacy_all_delete_unknown\n',
    });
    final manager = QuarantineManager(fixture.root);
    final notAttempted = await manager.createQuarantine(
      runId: 'legacy-c-not-attempted',
      entries: const <QuarantineEntry>[],
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final outcomeUnknown = await manager.createQuarantine(
      runId: 'legacy-b-outcome-unknown',
      entries: const <QuarantineEntry>[],
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final removed = await manager.createQuarantine(
      runId: 'legacy-a-removed',
      entries: const <QuarantineEntry>[],
    );
    final notAttemptedManifest = File(
      p.join(notAttempted.path, 'manifest.json'),
    );
    final notAttemptedBytes = notAttemptedManifest.readAsBytesSync();
    final locked = Directory(p.join(outcomeUnknown.path, 'locked'))
      ..createSync();
    File(
      p.join(locked.path, 'retained.bin'),
    ).writeAsBytesSync(<int>[4, 5, 6, 7], flush: true);
    _chmodPath(locked.path, 0x140);
    addTearDown(() {
      final lockedDirectories = fixture.root
          .listSync(recursive: true, followLinks: false)
          .whereType<Directory>()
          .where((directory) => p.basename(directory.path) == 'locked');
      for (final directory in lockedDirectories) {
        _chmodPath(directory.path, 0x1c0);
      }
    });

    final harness = CliProcessHarness.repository();
    final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
    final result = await harness.runQuarantineOnly(
      [
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--all',
        '--confirm-clean-fingerprint',
        fingerprint,
      ],
      environmentAdditions: const <String, String>{'COLUMNS': '32'},
    );

    expect(result.exitCode, 0);
    expect(result.stderrBytes, isEmpty);
    _expectHumanLinesAtMost(result, width: 32);
    final transcript = _unwrapVisualLines(
      '${result.stdoutText}\n${result.stderrText}',
    );
    expect(transcript, contains('QUARANTINELOGICALLYCLEANED'));
    expect(transcript, contains('Retained:legacy-a-removed'));
    expect(transcript, contains('Retained:legacy-b-outcome-unknown'));
    expect(transcript, contains('Retained:legacy-c-not-attempted'));
    expect(removed.existsSync(), isFalse);
    expect(outcomeUnknown.existsSync(), isFalse);
    expect(notAttempted.existsSync(), isFalse);
    final retainedManifests =
        Directory(
              p.join(
                fixture.root.path,
                '.flutter_pruner',
                'quarantine',
                '.clean-retained',
                'v1',
              ),
            )
            .listSync(recursive: true, followLinks: false)
            .whereType<File>()
            .where((file) => p.basename(file.path) == 'manifest.json')
            .toList();
    expect(retainedManifests, hasLength(3));
    expect(
      retainedManifests.any(
        (file) => _byteListsEqual(file.readAsBytesSync(), notAttemptedBytes),
      ),
      isTrue,
    );
  }, timeout: processTestTimeout);

  test(
    'human partial receipt names every state and denies crash-durable proof',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean human partial ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_human_partial\n',
      });
      final manager = QuarantineManager(fixture.root);
      final first = await manager.createQuarantine(
        runId: 'human-first',
        entries: const <QuarantineEntry>[],
      );
      final second = await manager.createQuarantine(
        runId: 'human-second',
        entries: const <QuarantineEntry>[],
      );
      final executorReady = fixture.file('executor.ready');
      final executorRelease = fixture.file('executor.release');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        readyFile: executorReady,
        releaseFile: executorRelease,
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'pause_after_first',
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY': executorReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE': executorRelease.path,
        },
      );
      await waitForReadyFile(
        executorReady,
        timeout: const Duration(seconds: 15),
      );
      expect(first.existsSync(), isFalse);
      File(p.join(second.path, 'drift.txt')).writeAsStringSync('drift');
      executorRelease.writeAsStringSync('release', flush: true);
      final result = await invocation.result;

      expect(result.exitCode, 1);
      expect(result.stdoutText, contains('Removed: human-first'));
      expect(result.stdoutText, contains('Preserved: human-second'));
      expect(result.stdoutText, contains('Receipt: not crash-durable proof.'));
      expect(result.stdoutText, isNot(contains('✓ Removed 2 quarantines')));
      expect(second.existsSync(), isTrue);
    },
    timeout: processTestTimeout,
  );

  test(
    'human delete failure receipt preserves all ordered target outcomes',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean human delete failure ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_human_delete_failure\n',
      });
      final manager = QuarantineManager(fixture.root);
      final first = await manager.createQuarantine(
        runId: 'partial-a-removed',
        entries: const <QuarantineEntry>[],
      );
      final second = await manager.createQuarantine(
        runId: 'partial-b-unknown',
        entries: const <QuarantineEntry>[],
      );
      final third = await manager.createQuarantine(
        runId: 'partial-c-not-attempted',
        entries: const <QuarantineEntry>[],
      );
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'throw',
          'FLUTTER_PRUNER_TEST_CLEAN_FAIL_RUN_ID': 'partial-b-unknown',
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );

      expect(result.exitCode, 1);
      expect(
        const LineSplitter()
            .convert(result.stdoutText)
            .where(
              (line) =>
                  line.startsWith('  Removed:') ||
                  line.startsWith('  Outcome unknown:') ||
                  line.startsWith('  Not attempted:'),
            )
            .toList(growable: false),
        <String>[
          '  Removed: partial-a-removed',
          '  Outcome unknown: partial-b-unknown',
          '  Not attempted: partial-c-not-attempted',
        ],
      );
      expect(result.stdoutText, contains('Deletion attempted: yes'));
      expect(result.stdoutText, contains('Receipt: not crash-durable proof.'));
      expect(
        result.stdoutText,
        contains('This receipt describes only the current process.'),
      );
      expect(result.stdoutText, isNot(contains('✓ Removed 3 quarantines')));
      expect(
        result.stderrText,
        contains('quarantine deletion outcome is unknown'),
      );
      expect(first.existsSync(), isFalse);
      expect(second.existsSync(), isTrue);
      expect(third.existsSync(), isTrue);
      expect(events.readAsLinesSync(), <String>[
        'boundary:partial-a-removed',
        'removed:partial-a-removed',
        'boundary:partial-b-unknown',
      ]);
    },
    timeout: processTestTimeout,
  );

  test(
    'JSON delete-1 success delete-2 failure emits one exact ordered envelope',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean JSON delete failure ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_json_delete_failure\n',
      });
      final manager = QuarantineManager(fixture.root);
      final first = await manager.createQuarantine(
        runId: 'json-a-removed',
        entries: const <QuarantineEntry>[],
      );
      final second = await manager.createQuarantine(
        runId: 'json-b-unknown',
        entries: const <QuarantineEntry>[],
      );
      final third = await manager.createQuarantine(
        runId: 'json-c-not-attempted',
        entries: const <QuarantineEntry>[],
      );
      final firstPath = first.resolveSymbolicLinksSync();
      final secondPath = second.resolveSymbolicLinksSync();
      final thirdPath = third.resolveSymbolicLinksSync();
      final secondManifest = File(p.join(second.path, 'manifest.json'));
      final thirdManifest = File(p.join(third.path, 'manifest.json'));
      final originalSecondManifest = secondManifest.readAsBytesSync();
      final originalThirdManifest = thirdManifest.readAsBytesSync();
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fingerprint = await _previewCleanFingerprint(harness, fixture.root);

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          '--all',
          '--format',
          'json',
          '--confirm-clean-fingerprint',
          fingerprint,
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'throw',
          'FLUTTER_PRUNER_TEST_CLEAN_FAIL_RUN_ID': 'json-b-unknown',
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );

      final expected = <String, Object?>{
        'schemaVersion': 1,
        'kind': 'quarantineCleanResult',
        'fingerprint': fingerprint,
        'deletionAttempted': true,
        'complete': false,
        'receiptCrashDurable': false,
        'outcomes': <Object?>[
          <String, Object?>{
            'runId': 'json-a-removed',
            'canonicalPath': firstPath,
            'state': 'removed',
          },
          <String, Object?>{
            'runId': 'json-b-unknown',
            'canonicalPath': secondPath,
            'state': 'outcomeUnknown',
            'failure': <String, Object?>{
              'code': 'delete_failed',
              'message': 'Injected delete failure.',
            },
          },
          <String, Object?>{
            'runId': 'json-c-not-attempted',
            'canonicalPath': thirdPath,
            'state': 'notAttempted',
          },
        ],
        'failure': <String, Object?>{
          'code': 'delete_failed',
          'message': 'Injected delete failure.',
        },
      };
      expect(result.exitCode, 1);
      expect(result.stdoutText, jsonEncode(expected));
      expectJsonStdout(result, equals(expected));
      expectNoAnsi(result);
      expect(
        result.stderrText,
        'Error: quarantine deletion outcome is unknown. Inspect surviving evidence before another action.\n',
      );
      expect(first.existsSync(), isFalse);
      expect(secondManifest.readAsBytesSync(), originalSecondManifest);
      expect(thirdManifest.readAsBytesSync(), originalThirdManifest);
      expect(events.readAsLinesSync(), <String>[
        'boundary:json-a-removed',
        'removed:json-a-removed',
        'boundary:json-b-unknown',
      ]);
    },
    timeout: processTestTimeout,
  );

  test(
    'process interruption at the fake deletion boundary produces no durable receipt',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean interrupted ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_interrupted\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'interrupted-run',
        entries: const <QuarantineEntry>[],
      );
      final executorReady = fixture.file('executor.ready');
      final neverRelease = fixture.file('executor.never-release');
      final events = fixture.file('delete.events');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          'interrupted-run',
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'pause_at_boundary',
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY': executorReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE': neverRelease.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );
      await waitForReadyFile(
        executorReady,
        timeout: const Duration(seconds: 15),
      );
      await invocation.close();
      final result = await invocation.result;

      expect(result.exitCode, isNot(0));
      expect(result.stdoutText, isNot(contains('QUARANTINE CLEAN RECEIPT')));
      expect(events.readAsLinesSync(), <String>['boundary:interrupted-run']);
      expect(quarantine.existsSync(), isTrue);
      final lock = await ProjectOperationLock.acquire(
        workspace: ToolWorkspace(fixture.root),
        operation: 'q5-after-interruption',
      );
      await lock.release();
    },
    timeout: processTestTimeout,
  );

  test(
    'clean --all rejects an invalid raw run before deleting any sibling',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final manager = QuarantineManager(project);
        final cleanable = await manager.createQuarantine(
          runId: 'cleanable-run',
          entries: const [],
        );
        final invalid = Directory(
          p.join(
            project.path,
            QuarantineManager.defaultQuarantineDir,
            'invalid-run',
          ),
        )..createSync(recursive: true);
        File(
          p.join(invalid.path, 'manifest.json'),
        ).writeAsStringSync('{invalid');

        final process = await Process.start(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          '--all',
        ]);
        process.stdin.writeln('y');
        await process.stdin.close();
        final stderrText = await process.stderr
            .transform(systemEncoding.decoder)
            .join();
        await process.stdout.drain<void>();
        final exitCode = await process.exitCode;

        expect(exitCode, 1);
        expect(_unwrapVisualLines(stderrText), contains('invalid-run'));
        expect(cleanable.existsSync(), isTrue);
        expect(invalid.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean preserves a quarantine whose manifest belongs to another project',
    () async {
      final selected = Directory.systemTemp.createTempSync(
        'quarantine_selected_',
      );
      final recorded = Directory.systemTemp.createTempSync(
        'quarantine_recorded_',
      );
      try {
        for (final project in [selected, recorded]) {
          File(
            p.join(project.path, 'pubspec.yaml'),
          ).writeAsStringSync('name: quarantine_test\n');
        }
        final quarantine = await QuarantineManager(recorded)
            .createCaseQuarantine(
              runId: 'foreign-run',
              quarantineBase: p.join(
                selected.path,
                QuarantineManager.defaultQuarantineDir,
              ),
            );

        final exitCode = await FlutterPrunerCommandRunner().run([
          'quarantine',
          'clean',
          '--project',
          selected.path,
          'foreign-run',
        ]);

        expect(exitCode, 1);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (selected.existsSync()) selected.deleteSync(recursive: true);
        if (recorded.existsSync()) recorded.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean refuses a pending transaction',
    () => _expectCleanRefusal(recoveryRequired: false),
  );

  test(
    'clean refuses a recovery-required transaction',
    () => _expectCleanRefusal(recoveryRequired: true),
  );

  test(
    'clean refuses a committed transaction that still owns rollback',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final source = File(p.join(project.path, 'lib', 'committed.dart'));
        source.parent.createSync(recursive: true);
        source.writeAsStringSync('void original() {}\n');
        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'committed-run',
          verificationPolicyHash: 'test-policy',
        );
        await manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          round: 1,
          componentId: 'component-1',
          findingIds: const ['finding-1'],
          caseIds: const ['case-1'],
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          transactionId: 'transaction-1',
        );
        source.writeAsStringSync('void committedMutation() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-1',
        );
        await manager.recordTransactionApplied(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          caseIds: const ['case-1'],
        );
        await manager.verifyTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          policyHash: 'test-policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        );
        await manager.commitTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
        );

        final result = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'committed-run',
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('committed-run is not cleanable'));
        expect(quarantine.existsSync(), isTrue);
        expect(source.readAsStringSync(), 'void committedMutation() {}\n');
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean refuses a verified failed-case rollback while lifecycle is active',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final source = File(p.join(project.path, 'lib', 'restored.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        source.writeAsStringSync(original);
        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'verified-rollback',
          verificationPolicyHash: 'test-policy',
        );
        await manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          round: 1,
          componentId: 'component-1',
          findingIds: const ['finding-1'],
          caseIds: const ['case-1'],
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          transactionId: 'transaction-1',
        );
        source.writeAsStringSync('void partialMutation() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-1',
        );
        await manager.rollbackCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          reason: 'injected apply failure',
          failed: true,
        );
        await manager.rollbackTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          reason: 'restored verification baseline',
          policyHash: 'test-policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        );

        final result = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'verified-rollback',
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('verified-rollback is not cleanable'));
        expect(source.readAsStringSync(), original);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );
}

Future<void> _expectCleanRefusal({required bool recoveryRequired}) async {
  final project = Directory.systemTemp.createTempSync(
    'quarantine_command_test_',
  );
  try {
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: quarantine_test\n');
    final manager = QuarantineManager(project);
    final suffix = recoveryRequired ? 'recovery' : 'pending';
    final runId = '$suffix-run';
    final caseId = '$suffix-case';
    final transactionId = '$suffix-transaction';
    final source = File(p.join(project.path, 'lib', '$suffix.dart'));
    source.parent.createSync(recursive: true);
    source.writeAsStringSync('void $suffix() {}\n');
    final quarantine = await manager.createCaseQuarantine(
      runId: runId,
      verificationPolicyHash: 'test-policy',
    );
    await manager.beginTransaction(
      quarantineDir: quarantine,
      transactionId: transactionId,
      round: 1,
      componentId: suffix,
      findingIds: ['$suffix-finding'],
      caseIds: [caseId],
    );
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: caseId,
      findingId: '$suffix-finding',
      file: source,
      operationType: QuarantineOperationType.declaration,
      transactionId: transactionId,
    );
    if (recoveryRequired) {
      await manager.requireTransactionRecovery(
        quarantineDir: quarantine,
        transactionId: transactionId,
        reason: 'injected interruption',
      );
    }

    final result = await Process.run(Platform.resolvedExecutable, [
      p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
      'quarantine',
      'clean',
      '--project',
      project.path,
      runId,
    ]);

    expect(result.exitCode, 1, reason: suffix);
    expect(result.stderr, contains('$runId is not cleanable'));
    expect(quarantine.existsSync(), isTrue);
  } finally {
    if (project.existsSync()) project.deleteSync(recursive: true);
  }
}

void _expectTerminalSafeLegacyFailure(CliProcessResult result) {
  expectNoAnsi(result);
  expect(
    _unwrapVisualLines(result.stderrText),
    contains(_unwrapVisualLines(_visibleHostileLegacyPathSegment)),
  );
  expect(result.stderrText, isNot(contains(_hostileLegacyPathSegment)));
  expect(result.stderrText, isNot(contains('\nFORGED LEGACY ROW')));
  expect(result.stderrText, isNot(contains(_unsafeRenderedControl)));
  expect(
    const LineSplitter()
        .convert(result.stderrText)
        .where((line) => line == 'FORGED LEGACY ROW'),
    isEmpty,
  );
}

class _TerminalRecordingSink implements Stdout {
  _TerminalRecordingSink({this.terminalColumnsOverride});

  final int? terminalColumnsOverride;

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  bool get hasTerminal => terminalColumnsOverride != null;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns =>
      terminalColumnsOverride ??
      (throw const StdoutException('not a terminal'));

  @override
  int get terminalLines => throw const StdoutException('not a terminal');

  @override
  IOSink get nonBlocking => this;

  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {}

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) {}

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {}

  @override
  void writeCharCode(int charCode) {}

  @override
  void writeln([Object? object = '']) {}
}

void _expectHumanLinesAtMost(
  CliProcessResult result, {
  required int width,
  bool skipPromptLine = false,
  bool includeStdout = true,
}) {
  const metrics = TerminalTextMetrics();
  for (final stream in <String>[
    if (includeStdout) result.stdoutText,
    result.stderrText,
  ]) {
    expect(
      _stripAnsi(stream)
          .split('\n')
          .where(
            (line) =>
                line.isNotEmpty &&
                (!skipPromptLine ||
                    !line.startsWith('Remove all quarantines?')),
          ),
      everyElement(
        predicate<String>((line) => metrics.visibleWidth(line) <= width),
      ),
    );
  }
}

void _expectTerminalSafeJsonRepresentation(CliProcessResult result) {
  expectNoAnsi(result);
  expect(result.stdoutText, isNot(contains(_unsafeJsonRepresentationControl)));
}

void _chmodPath(String path, int mode) {
  final result = Process.runSync('/bin/chmod', [mode.toRadixString(8), path]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

Future<String> _previewCleanFingerprint(
  CliProcessHarness harness,
  Directory project, {
  String? runId,
}) async {
  final preview = await harness.runQuarantineOnly([
    'quarantine',
    'clean',
    '--project',
    project.path,
    if (runId == null) '--all' else runId,
    '--dry-run',
    '--format',
    'json',
  ]);
  expect(preview.exitCode, 0);
  expect(preview.stderrBytes, isEmpty);
  final document = jsonDecode(preview.stdoutText) as Map<String, Object?>;
  return document['fingerprint']! as String;
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

String _unwrapVisualLines(String value) => value.replaceAll(RegExp(r'\s+'), '');

void _expectOnlyStaticSgr(String value) {
  final sgr = RegExp(r'\x1B\[[0-9;]*m');
  final sequences = sgr
      .allMatches(value)
      .map((match) => match.group(0))
      .toList(growable: false);
  expect(sequences, isNotEmpty);
  expect(
    sequences,
    everyElement(
      isIn(const <String>{
        '\x1B[0m',
        '\x1B[1m',
        '\x1B[2m',
        '\x1B[32m',
        '\x1B[33m',
        '\x1B[36m',
      }),
    ),
  );
  final plain = _stripAnsi(value);
  expect(plain, isNot(contains('\x1B')));
  expect(plain, isNot(contains(_unsafeRenderedControl)));
}

QuarantineVerificationEvidence _verificationEvidence(Directory project) {
  final baseline = VerificationBaselineEvidence(
    policyHash: 'policy',
    requiredStepIds: const <String>['analyze'],
    requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
    workingDirectory: p.normalize(p.absolute(project.path)),
    toolchainIdentity: 'test-toolchain',
    steps: <VerificationStepBaselineEvidence>[
      VerificationStepBaselineEvidence(
        name: 'analyze',
        parserKind: VerificationOutputParserKind.humanAnalyzer,
        passed: true,
        exitCode: 0,
        failureEvidenceComplete: false,
        reportedFailureCount: null,
        fingerprintCount: 0,
        fingerprintDigests: <String, int>{},
      ),
    ],
  );
  return QuarantineVerificationEvidence(
    policyHash: 'policy',
    requiredStepIds: const <String>['analyze'],
    observedStepIds: const <String>['analyze'],
    workingDirectory: p.normalize(p.absolute(project.path)),
    toolchainIdentity: 'test-toolchain',
    available: true,
    passed: true,
    comparisonBaseline: baseline,
  );
}

bool _byteListsEqual(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
