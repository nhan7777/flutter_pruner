import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/formatters/human_formatter.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/cli/init_prompt.dart';
import 'package:flutter_pruner/src/cli/terminal_progress.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

import 'cli_process_harness.dart';

void main() {
  test('reviewed CLI surface inventory has a complete, typed schema', () {
    final inventory = _readInventory();

    expect(inventory.schemaVersion, 2);
    expect(inventory.surfaces, isNotEmpty);
    expect(inventory.ids.length, inventory.surfaces.length);
    for (final surface in inventory.surfaces) {
      expect(surface.command, isNotEmpty, reason: surface.id);
      expect(_states, contains(surface.state), reason: surface.id);
      expect(_streams, contains(surface.stream), reason: surface.id);
      expect(_interactions, contains(surface.interaction), reason: surface.id);
      expect(
        _allowedExits[surface.state],
        containsAll(surface.exits),
        reason: surface.id,
      );
      expect(surface.currentTranscript, isNotEmpty, reason: surface.id);
      expect(surface.approvedTranscript, isNotEmpty, reason: surface.id);
      expect(File(surface.owner).existsSync(), isTrue, reason: surface.id);
      final approvedTokens = RegExp(r'<[^>]+>')
          .allMatches(surface.approvedTranscript)
          .map((match) => match.group(0)!)
          .toSet();
      expect(
        surface.placeholders.map((placeholder) => placeholder.token).toSet(),
        approvedTokens,
        reason: surface.id,
      );
      var typedExample = surface.approvedTranscript;
      for (final placeholder in surface.placeholders) {
        expect(
          _placeholderPatterns,
          contains(placeholder.kind),
          reason: surface.id,
        );
        typedExample = typedExample.replaceAll(
          placeholder.token,
          placeholder.example,
        );
      }
      expect(
        _matchesTemplate(
          surface.approvedTranscript,
          typedExample,
          surface.placeholders,
        ),
        isTrue,
        reason: 'typed placeholder ${surface.id}',
      );
      if (surface.state == 'help') {
        expect(
          surface.approvedTranscript,
          isNot(endsWith('.')),
          reason: surface.id,
        );
      }
      expect(surface.approvedTranscript, isNot(contains('Please ')));
      if (surface.id != 'saved-html.recovery.do-not-assume') {
        expect(surface.approvedTranscript, isNot(contains('successfully')));
      }
      expect(surface.approvedTranscript, isNot(contains('...')));
    }
  });

  test(
    'registered help copy is bidirectionally bound to rendered commands',
    () {
      final inventory = _readInventory();
      final runner = FlutterPrunerCommandRunner();
      final approved = inventory.surfaces
          .where((surface) => surface.state == 'help')
          .map((surface) => surface.approvedTranscript)
          .toSet();
      final rendered = _configuredHelpCopy(runner);

      expect(
        rendered,
        approved,
        reason: 'unregistered or disappeared help copy',
      );
      for (final surface in inventory.surfaces.where(
        (surface) => surface.state == 'help',
      )) {
        for (final command in surface.command.split(',')) {
          final usage = _usageFor(runner, command.trim());
          expect(
            usage,
            contains(surface.approvedTranscript),
            reason: surface.id,
          );
          if (surface.currentTranscript != surface.approvedTranscript) {
            expect(
              usage,
              isNot(contains(surface.currentTranscript)),
              reason: 'retired copy: \${surface.id}',
            );
          }
        }
      }
    },
  );

  test('prompt and progress copy retire Please and ASCII ellipses', () {
    final prompt = _RecordingPrompt(<String>['perhaps', 'yes']);
    expect(
      InitQuestions(prompt).yesNo('Proceed?', defaultValue: false),
      isTrue,
    );
    expect(prompt.output, contains('Answer yes or no.'));
    expect(prompt.output, isNot(contains('Please answer yes or no.')));

    final sink = StringBuffer();
    TerminalProgress(sink: sink, animated: false)
      ..start('Dart declaration analyzer')
      ..finish(succeeded: true);
    expect(sink.toString(), contains('Scanning Dart declaration analyzer…'));
    expect(
      sink.toString(),
      isNot(contains('Scanning Dart declaration analyzer...')),
    );
  });

  test(
    'exact transcript extraction rejects a disappeared or unregistered line',
    () {
      final inventory = _readInventory();
      final extractor = _PresentationExtractor(inventory);
      const expected = <String>['quarantine.list.empty'];

      expect(extractor.allLines('No quarantines found.\n', ''), expected);
      expect(
        () => expect(extractor.allLines('', ''), expected),
        throwsA(isA<TestFailure>()),
        reason: 'registered disappearance must fail the bidirectional fixture',
      );
      expect(
        () => expect(
          extractor.allLines(
            'No quarantines found.\nUnexpected stable line\n',
            '',
          ),
          expected,
        ),
        throwsA(isA<TestFailure>()),
        reason: 'an unregistered stable presentation line must fail',
      );
      const novelEvidence =
          ' Evidence: invalid_manifest — Quarantine manifest is missing, '
          'unreadable, or invalid. Novel stable suffix.';
      expect(
        extractor.allLines('$novelEvidence\n', ''),
        ['unregistered:stdout:$novelEvidence'],
        reason: 'a stable suffix outside the finite inspection messages fails',
      );
    },
  );

  test('exact transcript extraction reconstructs reviewed wrapped paths', () {
    final extractor = _PresentationExtractor(_readInventory());

    expect(
      extractor.allLines(
        '/workspace/.flutter_pruner/reports/scan-report.ht\nml\n',
        '',
      ),
      ['scan.report.path'],
    );
    expect(
      extractor.allLines(
        '│ Planned file no longer exists: /workspace/lib/src/hel │\n'
            '│ per.dart │\n',
        '',
      ),
      ['apply.outcome.missing-file'],
    );
    expect(
      extractor.allLines(
        ' ! Manifest .flutter_pruner/quarantine/run/manifest.json\n',
        '',
      ),
      ['apply.recovery.manifest'],
    );
  });

  test('wrapped literal ellipses do not accept forged progress', () {
    final extractor = _PresentationExtractor(_readInventory());
    const first = '• Scanning Dart declaration analy';
    const second = 'zer… forged stable suffix';

    expect(extractor.allLines('', '$first\n$second\n'), [
      'unregistered:stderr:$first',
      'unregistered:stderr:$second',
    ]);
    expect(
      () => expect(extractor.allLines('', '$first\n$second\n'), [
        'scan.progress.adapter',
      ]),
      throwsA(isA<TestFailure>()),
      reason: 'a forged progress suffix must not mutate into a reviewed row',
    );
  });

  test('wrapped recovery evidence remains owned by stdout', () {
    final extractor = _PresentationExtractor(_readInventory());
    const manifestFirst = ' ! Manifest';
    const manifestSecond =
        ' /workspace/.flutter_pruner/quarantine/run/manifest.json';
    const summaryFirst =
        ' │ Verification became unavailable for wave-r001.; recovery could not be prove │';
    const summarySecond =
        ' │ n: Bad state: Rollback verification failed for whole apply run: flutter-ana │';
    const summaryThird =
        ' │ lyze: nonzero exit without stable diagnostic evidence │';
    const copyFirst =
        'The compatibility partialApplied flag marks an uncertain working-copy state. '
        'Inspect the quarantine manifest before taking any recovery action; it does not prov';
    const copySecond = 'e changes remain. Do not rerun apply.';

    expect(
      extractor.allLines(
        '',
        '$manifestFirst\n$manifestSecond\n'
            '$summaryFirst\n$summarySecond\n$summaryThird\n'
            '$copyFirst\n$copySecond\n',
      ),
      [
        'unregistered:stderr:$manifestFirst',
        'unregistered:stderr:$manifestSecond',
        'unregistered:stderr:$summaryFirst',
        'unregistered:stderr:$summarySecond',
        'unregistered:stderr:$summaryThird',
        'unregistered:stderr:$copyFirst',
        'unregistered:stderr:$copySecond',
      ],
    );
  });

  test('init scan suggestion requires the structured argv transcript', () {
    final inventory = _readInventory();
    final surface = inventory.surfaces.singleWhere(
      (surface) => surface.id == 'init.next.scan',
    );
    const rendered = "Next: flutter_pruner 'scan' '--project' '/workspace'";

    expect(
      _matchesTemplate(
        surface.approvedTranscript,
        rendered,
        surface.placeholders,
      ),
      isTrue,
    );
    expect(
      _matchesTemplate(
        surface.approvedTranscript,
        "Next: flutter_pruner scan --project '/workspace'",
        surface.placeholders,
      ),
      isFalse,
      reason: 'the former interpolated shell copy must remain unregistered',
    );
    expect(
      _matchesTemplate(
        surface.approvedTranscript,
        "Next: flutter_pruner 'scan' --project '/workspace'",
        surface.placeholders,
      ),
      isFalse,
      reason: 'all structured argv elements must retain their renderer quotes',
    );
  });

  test('C6 failure-report stderr surfaces are finite and mutation-sensitive', () {
    final inventory = _readInventory();
    final extractor = _PresentationExtractor(inventory);
    const stderr =
        '''Error: Analysis failed after adapter Dart declaration analyzer (dart) started.
Error: report output close failed after commit: Bad state: injected report store close failure
Failure report saved: /workspace/failed-scan.json
''';
    const expected = <String>[
      'failure.error.adapter-started',
      'failure.error.report-close-after-commit',
      'failure.report-saved',
    ];
    expect(extractor.allLines('', stderr), expected);
    expect(
      () => expect(
        extractor.allLines('', stderr.replaceFirst('Failure ', '')),
        expected,
      ),
      throwsA(isA<TestFailure>()),
      reason: 'removing a committed-report label must fail',
    );
    expect(
      extractor.allLines(
        '',
        'Error: Analysis failed in adapter Dart declaration analyzer (dart).\n',
      ),
      [
        'unregistered:stderr:Error: Analysis failed in adapter Dart declaration analyzer (dart).',
      ],
      reason: 'the former adapter-copy must remain retired',
    );
    expect(
      extractor.allLines(
        '',
        'Error: Project analysis failed before an adapter completed.\n',
      ),
      [
        'unregistered:stderr:Error: Project analysis failed before an adapter completed.',
      ],
      reason: 'the former generic analysis-copy must remain retired',
    );
    expect(
      extractor.allLines(
        '',
        'Error: report was not saved: JSON v2 cannot represent failed run reports. '
            'Use --json-version 3.\n',
      ),
      ['failure.error.report-not-saved'],
      reason: 'the reviewed JSON v2 compatibility fact must be finite',
    );
    expect(
      () => expect(
        extractor.allLines('', '${stderr}Unexpected C6 stable line\n'),
        expected,
      ),
      throwsA(isA<TestFailure>()),
      reason: 'a new stable C6 line must be unregistered',
    );
  });

  test('C6 failed report artifacts bind actual Human and JSON v3 output', () {
    final inventory = _readInventory();
    final extractor = _PresentationExtractor(inventory);
    final report = _c6FailedReport();

    final human = _stripAnsi(
      const HumanFormatter(lineWidth: 160).format(report),
    );
    final humanExpected = inventory.surfaces
        .where((surface) => surface.command == 'saved human failure report')
        .map((surface) => surface.id)
        .toList(growable: false);
    expect(extractor.artifactLines(human), humanExpected);
    expect(
      () => expect(
        extractor.artifactLines(
          human.replaceFirst('FAILURE DIAGNOSTICS\n', ''),
        ),
        humanExpected,
      ),
      throwsA(isA<TestFailure>()),
      reason:
          'a disappeared Human failure section must fail the artifact oracle',
    );
    expect(
      () => expect(
        extractor.artifactLines('$human\nUnexpected C6 Human artifact line'),
        humanExpected,
      ),
      throwsA(isA<TestFailure>()),
      reason: 'an added Human failure line must fail the artifact oracle',
    );

    final json = const JsonFormatter().format(report);
    final jsonExpected = inventory.surfaces
        .where((surface) => surface.command == 'saved json v3 failure report')
        .map((surface) => surface.semanticPath!)
        .toSet();
    expect(_classifyC6FailureJson(json), jsonExpected);
    final removed = jsonDecode(json) as Map<String, Object?>;
    final removedRun = Map<String, Object?>.of(
      removed['run']! as Map<String, Object?>,
    )..remove('exitCode');
    expect(
      () => expect(
        _classifyC6FailureJson(jsonEncode({...removed, 'run': removedRun})),
        jsonExpected,
      ),
      throwsA(isA<TestFailure>()),
      reason: 'a removed JSON failure fact must fail the semantic oracle',
    );
    final added = jsonDecode(json) as Map<String, Object?>;
    final diagnostics = List<Object?>.of(added['diagnostics']! as List<Object?>)
      ..add(const {
        'code': 'unexpected_c6_failure',
        'phase': 'analysis',
        'message': 'Unexpected C6 JSON diagnostic.',
      });
    expect(
      () => expect(
        _classifyC6FailureJson(
          jsonEncode({...added, 'diagnostics': diagnostics}),
        ),
        jsonExpected,
      ),
      throwsA(isA<TestFailure>()),
      reason: 'an added JSON failure diagnostic must fail the semantic oracle',
    );
  });

  test('every non-help inventory entry has an owned renderer binding', () {
    final inventory = _readInventory();
    final transcriptFixtures = _readTranscriptFixtures();
    final processBindings = transcriptFixtures.scenarios.values
        .expand((ids) => ids)
        .toSet();
    const directlyRendered = <String>{
      'init.prompt.mode',
      'init.prompt.invalid-answer',
      'scan.warning.package-internal',
      'scan.success.completed-singular',
      'scan.success.clean',
      'apply.empty.no-action',
      'apply.preview.powershell',
      'rollback.success',
      'quarantine.clean.prompt',
    };
    final bound = <String>{
      ...processBindings,
      ...directlyRendered,
      ..._c6ObservedBindings(inventory),
      ...inventory.surfaces
          .where(
            (surface) =>
                surface.stream == 'saved-file' &&
                (surface.artifactOracle || surface.semanticPath != null),
          )
          .map((surface) => surface.id),
    };
    for (final surface in inventory.surfaces.where(
      (surface) => surface.stream == 'saved-file',
    )) {
      expect(
        surface.artifactOracle || surface.semanticPath != null,
        isTrue,
        reason: '${surface.id} must bind through a validated artifact oracle',
      );
    }
    final nonHelp = inventory.surfaces
        .where((surface) => surface.state != 'help')
        .map((surface) => surface.id)
        .toSet();
    expect(bound, nonHelp, reason: 'every reviewed surface needs a renderer');
  });

  test(
    'exact normalized process transcript fixtures bind the reviewed matrix',
    () async {
      final inventory = _readInventory();
      final transcriptFixtures = _readTranscriptFixtures();
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final fixture = CliFixture.create(prefix: 'c3 transcript matrix ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: c3_transcript_matrix\n',
        'lib/main.dart': 'void main() {}\n',
      });

      final noninteractive = await harness.run([
        'init',
        '--yes',
        '--project',
        fixture.root.path,
      ]);
      expect(noninteractive.exitCode, 0);
      expect(noninteractive.stderrBytes, isEmpty);
      expect(fixture.file('.flutter_pruner/config.yaml').existsSync(), isTrue);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'init-noninteractive',
        noninteractive,
      );
      final zeroFindings = await harness.run([
        'scan',
        '--project',
        fixture.root.path,
      ], timeout: const Duration(seconds: 90));
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'scan-zero',
        zeroFindings,
      );
      final missingProject = fixture.file('missing-project');
      final operationalFailure = await harness.run([
        'scan',
        '--project',
        missingProject.path,
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'scan-operational-failure',
        operationalFailure,
      );
      final internalFailure = await harness.run(
        [
          'apply',
          '--dry-run',
          '--adapter',
          'dart',
          '--project',
          fixture.root.path,
        ],
        entrypointOverride: File(
          '${harness.repositoryRoot.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}cli${Platform.pathSeparator}'
          'c3_apply_fake_entrypoint.dart',
        ),
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'scan-internal-failure',
        internalFailure,
      );

      final safeStopFixture = CliFixture.create(prefix: 'c3 apply safe stop ');
      addTearDown(safeStopFixture.dispose);
      await safeStopFixture.writeText(<String, String>{
        'pubspec.yaml': 'name: c3_apply_safe_stop\n',
        '.dart_tool/package_config.json': '''{
  "configVersion": 2,
  "packages": [
    {
      "name": "c3_apply_safe_stop",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''',
        'flutter_pruner.yaml': '''version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
        'lib/main.dart': '''import 'src/helper.dart';

void main() {
  usedFunction();
}
''',
        'lib/src/helper.dart': '''void usedFunction() {}

void unusedFunction() {}
''',
      });
      final oneReport = safeStopFixture.file('one-finding.json');
      final oneFinding = await harness.run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        oneReport.path,
        '--project',
        safeStopFixture.root.path,
      ], timeout: const Duration(seconds: 90));
      expect(oneFinding.exitCode, 0, reason: oneFinding.stderrText);
      _expectFindingCount(oneReport, 1);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'scan-one',
        oneFinding,
      );
      await safeStopFixture.writeText(<String, String>{
        'lib/src/other.dart': 'void unusedTwo() {}\n',
      });
      final manyReport = safeStopFixture.file('many-findings.json');
      final manyFindings = await harness.run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        manyReport.path,
        '--project',
        safeStopFixture.root.path,
      ], timeout: const Duration(seconds: 90));
      expect(manyFindings.exitCode, 0, reason: manyFindings.stderrText);
      _expectFindingCount(manyReport, 3);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'scan-many',
        manyFindings,
      );
      final safeStop = await harness.run(
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          'dart:c3_apply_safe_stop/lib/src/helper.dart#unusedFunction',
          '--dry-run',
          '--project',
          safeStopFixture.root.path,
        ],
        entrypointOverride: File(
          '${harness.repositoryRoot.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}cli${Platform.pathSeparator}'
          'c3_apply_safe_stop_entrypoint.dart',
        ),
        timeout: const Duration(seconds: 90),
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'apply-safe-stop',
        safeStop,
      );
      await safeStopFixture.writeText(<String, String>{
        'lib/src/helper.dart': '''void usedFunction() {}

void unusedFunction() {}
''',
      });
      final recovery = await harness.run(
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          'dart:c3_apply_safe_stop/lib/src/helper.dart#unusedFunction',
          '--project',
          safeStopFixture.root.path,
        ],
        entrypointOverride: File(
          '${harness.repositoryRoot.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}cli${Platform.pathSeparator}'
          'c3_apply_recovery_entrypoint.dart',
        ),
        timeout: const Duration(seconds: 90),
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'apply-recovery',
        recovery,
      );
      final recoveries = await QuarantineManager(
        safeStopFixture.root,
      ).listQuarantines();
      final recoveredManifest = await QuarantineManager(
        safeStopFixture.root,
      ).readManifest(Directory(recoveries.single.path));
      expect(
        recoveredManifest.transactions.single.status.name,
        'recoveryRequired',
      );

      final interactiveFixture = CliFixture.create(prefix: 'c3 init fake ');
      addTearDown(interactiveFixture.dispose);
      await interactiveFixture.writeText(<String, String>{
        'pubspec.yaml': 'name: c3_init_fake\n',
        'lib/main.dart': 'void main() {}\n',
      });
      final interactive = await harness.run(
        ['init', interactiveFixture.root.path],
        entrypointOverride: File(
          '${harness.repositoryRoot.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}cli${Platform.pathSeparator}'
          'c3_init_fake_entrypoint.dart',
        ),
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'init-interactive',
        interactive,
      );
      final initCancellation = await harness.run(
        ['init', interactiveFixture.root.path],
        environmentAdditions: const {'C3_INIT_MODE': 'cancel'},
        entrypointOverride: File(
          '${harness.repositoryRoot.path}${Platform.pathSeparator}'
          'test${Platform.pathSeparator}cli${Platform.pathSeparator}'
          'c3_init_fake_entrypoint.dart',
        ),
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'init-cancelled',
        initCancellation,
      );

      final empty = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'quarantine-empty',
        empty,
      );

      final corruptOnlyFixture = CliFixture.create(prefix: 'c3 corrupt only ');
      addTearDown(corruptOnlyFixture.dispose);
      await corruptOnlyFixture.writeText(<String, String>{
        '.flutter_pruner/quarantine/broken/manifest.json': '{broken',
      });
      final corruptOnly = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        corruptOnlyFixture.root.path,
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'quarantine-corrupt-only',
        corruptOnly,
      );

      final manager = QuarantineManager(fixture.root);
      await manager.createQuarantine(runId: 'preview-run', entries: const []);
      final preview = await harness.runQuarantineOnly([
        'quarantine',
        'clean',
        '--project',
        fixture.root.path,
        '--dry-run',
        'preview-run',
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'quarantine-clean-preview',
        preview,
      );

      final cancelled = await harness.runQuarantineCleanFake(
        ['quarantine', 'clean', '--project', fixture.root.path, '--all'],
        stdinText: 'n\n',
        environmentAdditions: const {'FLUTTER_PRUNER_TEST_CLEAN_TTY': '1'},
      );
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'quarantine-cancelled',
        cancelled,
      );

      await fixture.writeText(<String, String>{
        '.flutter_pruner/quarantine/broken/manifest.json': '{broken',
      });
      final corrupt = await harness.runQuarantineOnly([
        'quarantine',
        'list',
        '--project',
        fixture.root.path,
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'quarantine-mixed',
        corrupt,
      );

      final rollback = await harness.run([
        'rollback',
        '--project',
        fixture.root.path,
        'broken',
      ]);
      _expectExactTranscript(
        inventory,
        transcriptFixtures,
        'rollback-recovery',
        rollback,
      );
    },
    // This matrix launches 16 real CLI subprocess scenarios. Under full-suite
    // contention, its healthy late cases exceeded 3 minutes; each subprocess
    // retains its own bounded timeout and early-failure assertions.
    timeout: const Timeout(Duration(minutes: 5)),
  );
}

void _expectFindingCount(File report, int expected) {
  final json = jsonDecode(report.readAsStringSync()) as Map<String, Object?>;
  final findings = (json['findings']! as List<Object?>).cast<Object?>();
  expect(findings, hasLength(expected));
  final statistics = json['statistics']! as Map<String, Object?>;
  final blockers = statistics['blockers']! as Map<String, Object?>;
  expect(blockers['unboundUnique'], 0);
  final execution = json['execution']! as Map<String, Object?>;
  final passes = (execution['analysisPasses']! as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final pass in passes) {
    final graph = pass['graph']! as Map<String, Object?>;
    expect(graph['danglingEdges'], 0);
    expect(graph['danglingRoots'], 0);
  }
}

const _states = <String>{
  'help',
  'prompt',
  'progress',
  'success',
  'warning',
  'error',
  'cancellation',
  'empty',
  'recovery',
  'next-action',
  'preview',
  'safe-stop',
  'machine-contract',
};
const _streams = <String>{'stdout', 'stderr', 'saved-file'};
const _interactions = <String>{'none', 'optional', 'required'};
const _allowedExits = <String, Set<int>>{
  'help': {0},
  'prompt': {0},
  'progress': {0, 1},
  'success': {0},
  'warning': {0, 1},
  'error': {1, 70},
  'cancellation': {0},
  'empty': {0},
  'recovery': {1},
  'next-action': {0, 1, 2},
  'preview': {0},
  'safe-stop': {2},
  'machine-contract': {0},
};
final _placeholderPatterns = <String, RegExp>{
  'report-path': RegExp(r'(?:/|[A-Za-z]:[\\/])[^\r\n]+\.(?:html|json)'),
  'adapter-label': RegExp(r'[A-Za-z][A-Za-z0-9 -]*'),
  'adapter-id': RegExp(r'[a-z][a-z0-9_-]*'),
  'failed-command': RegExp(r'(?:SCAN|APPLY)'),
  'failure-code': RegExp(
    r'(?:adapter_analysis_failed|analysis_failed|apply_pre_transaction_failed)',
  ),
  'failure-phase': RegExp(
    r'(?:analysis|analysis:adapter:[A-Za-z0-9_.-]+|applyPlanning)',
  ),
  'count': RegExp(r'[0-9]+'),
  'config-path': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]\.flutter_pruner[\\/]config\.yaml',
  ),
  'project-path': RegExp(r'(?:/|[A-Za-z]:[\\/])[^\r\n]+'),
  'missing-project-path': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]missing-project',
  ),
  'planned-source-path': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]lib(?:[\\/][A-Za-z0-9_.-]+)+\.dart',
  ),
  'quarantine-run-path': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]\.flutter_pruner[\\/]quarantine[\\/][A-Za-z0-9][A-Za-z0-9_.-]*',
  ),
  'current-quarantine-base': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]\.flutter_pruner[\\/]quarantine',
  ),
  'legacy-quarantine-base': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]\.flutter_pruner_quarantine',
  ),
  'invalid-manifest-detail': RegExp(
    r'(?:/|[A-Za-z]:[\\/])[^\r\n]+[\\/]\.flutter_pruner[\\/]quarantine[\\/][A-Za-z0-9_.-]+[\\/]manifest\.json \(FormatException: Unexpected character \(at character 2\)\\n\{broken\\n \^\\n\)',
  ),
  'report-write-failure': RegExp(
    r'(?:FileSystemException: permission denied|Bad state: formatter callback failed|Bad state: report object backend failed|Bad state: injected report preparation backend failure|JSON v2 cannot represent failed run reports\. Use --json-version 3\.|JSON v2 compatibility projection exceeds (?:maxBlockerReferences|maxAffectedNodeIdReferences|maxAffectedNodeIdsPerBlocker) \([0-9]+ > [0-9]+\)\. Use --json-version 3\.)',
  ),
  'report-close-fact': RegExp(
    r'Bad state: injected (?:report store|apply report store|object) close failure',
  ),
  'quarantine-inspection-message': RegExp(
    r'(?:Unexpected non-directory entry in quarantine storage\.|Quarantine manifest is missing, unreadable, or invalid\.|Manifest journal authority is ambiguous\.|Manifest run ID does not match its directory\.|Quarantine belongs to a different project\.|Run ID appears in more than one quarantine directory\.|Symbolic links are not valid quarantine entries\.|Quarantine directory name is not a valid run ID\.|Quarantine base could not be enumerated\.|Quarantine entry changed during inspection\.|Quarantine entry is invalid\.)',
  ),
  'declaration-name': RegExp(r'[A-Za-z_][A-Za-z0-9_]*'),
  'elided-path': RegExp(r'(?:/|[A-Za-z]:[\\/])[^\r\n]*…'),
  'library-label': RegExp(r'(?:<[A-Za-z][A-Za-z -]*>|[A-Za-z_][A-Za-z0-9_.]*)'),
  'relative-dart-path': RegExp(r'(?:lib|test)(?:[\\/][A-Za-z0-9_.-]+)+\.dart'),
  'truncated-manifest-path': RegExp(
    r'(?:[A-Za-z0-9_.-]+[\\/])*…[\\/][A-Za-z0-9_.-]+[\\/]manifest\.json',
  ),
  'manifest-path': RegExp(
    r'(?:(?:/|[A-Za-z]:[\\/])?[^\r\n]+[\\/])manifest\.json',
  ),
  'unit-id': RegExp(r'unit:[a-f0-9]{16}'),
  'preview-fingerprint': RegExp(r'v[1-9][0-9]*:[a-f0-9]{64}'),
  'clean-scope': RegExp(r'(?:targeted|all)'),
  'fingerprint-prefix': RegExp(r'[a-f0-9]{12}'),
  'quarantine-error-code': RegExp(r'[a-z_]+'),
  'finding-id': RegExp(r"[a-z][a-z0-9_-]*:[^\s']+"),
  'run-id': RegExp(r'[A-Za-z0-9][A-Za-z0-9_.-]*'),
  'utc-timestamp': RegExp(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z UTC'),
  'verification-step': RegExp(r'flutter-(?:analyze|test)'),
  'wave-id': RegExp(r'wave-r[0-9]{3,}'),
  'html-copy-result': RegExp(r'(?:Command|Path|Link) copied'),
  'html-fallback-data': RegExp(
    r'(?:SCAN|APPLY|Completed|Recovery required|Stopped safely|[0-9]+ · SAFE [0-9]+ · HIGH [0-9]+ · REVIEW [0-9]+ · PROTECTED [0-9]+)',
  ),
  'html-fallback-finding': RegExp(r'(?:SAFE|HIGH|REVIEW|PROTECTED) · finding'),
  'html-label': RegExp(
    r'(?:Completed|No changes|Dry run|Stopped safely|Recovery required)',
  ),
  'html-count': RegExp(r'[0-9]+'),
  'html-report-value': RegExp(r'(?:scan|apply|report|test|finding)'),
  'html-tier': RegExp(r'(?:SAFE|HIGH|REVIEW|PROTECTED)'),
  'html-exit-code': RegExp(r'[0-9]{1,3}'),
  'html-timestamp': RegExp(r'[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z'),
  'html-summary': RegExp(
    r'[0-9]+ of [0-9]+ findings · tiers (?:SAFE|HIGH|REVIEW|PROTECTED)',
  ),
  'html-row-value': RegExp(
    r'(?:value|report|finding|status|configured target|available|unavailable)',
  ),
};

bool _matchesTemplate(
  String template,
  String candidate,
  List<_CliTypedPlaceholder> placeholders,
) {
  var pattern = RegExp.escape(template);
  for (final placeholder in placeholders) {
    pattern = pattern.replaceFirst(
      RegExp.escape(placeholder.token),
      '(${_placeholderPatterns[placeholder.kind]!.pattern})',
    );
  }
  return RegExp('^$pattern\$').hasMatch(candidate);
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');

Set<String> _configuredHelpCopy(FlutterPrunerCommandRunner runner) {
  final copy = <String>{runner.description, runner.usageFooter};
  void visit(Command<int> command) {
    if (command.name == 'help') return;
    copy.add(command.description);
    if (command.usageFooter case final footer?) copy.add(footer);
    for (final option in command.argParser.options.values) {
      final help = option.help;
      if (option.name != 'help' && help != null && help.isNotEmpty) {
        copy.add(help);
      }
    }
    for (final child in command.subcommands.values) {
      visit(child);
    }
  }

  for (final option in runner.argParser.options.values) {
    final help = option.help;
    if (option.name != 'help' && help != null && help.isNotEmpty) {
      copy.add(help);
    }
  }
  for (final command in runner.commands.values) {
    visit(command);
  }
  return copy;
}

void _expectExactTranscript(
  _CliSurfaceInventory inventory,
  _TranscriptFixtures fixtures,
  String scenario,
  CliProcessResult result,
) {
  final expected = fixtures.scenarios[scenario];
  if (expected == null) {
    throw StateError('missing transcript fixture $scenario');
  }
  final platformExpected = expected
      .map(
        (id) => Platform.isWindows && id == 'apply.preview.posix'
            ? 'apply.preview.powershell'
            : id,
      )
      .toList(growable: false);
  final surfaces = platformExpected
      .map(
        (id) => inventory.surfaces.singleWhere((surface) => surface.id == id),
      )
      .toList(growable: false);
  final outcome = surfaces.firstWhere(
    (surface) =>
        surface.state == 'error' ||
        surface.state == 'recovery' ||
        surface.state == 'safe-stop',
    orElse: () => surfaces.first,
  );
  expect(
    result.exitCode,
    isIn(outcome.exits),
    reason: '$scenario primary outcome exit',
  );
  final observed = _PresentationExtractor(
    inventory,
  ).allLines(result.stdoutText, result.stderrText);
  expect(
    observed,
    platformExpected,
    reason:
        '$scenario exact normalized transcript\n'
        'stdout=${result.stdoutText}\n'
        'stderr=${result.stderrText}',
  );
}

Set<String> _c6ObservedBindings(_CliSurfaceInventory inventory) {
  final extractor = _PresentationExtractor(inventory);
  const stderr =
      '''Error: Analysis failed after adapter Dart declaration analyzer (dart) started.
Error: Project analysis did not complete.
Error: Apply failed after analysis and before transaction authority.
Failure report saved: /workspace/failed-scan.json
Error: report output close failed after commit: Bad state: injected report store close failure
Report saved: /workspace/failed-scan.json
Error: report was not saved: Bad state: report object backend failed
''';
  final report = _c6FailedReport();
  final jsonSemantics = _classifyC6FailureJson(
    const JsonFormatter().format(report),
  );
  return {
    ...extractor.allLines('', stderr),
    ...extractor.artifactLines(
      const HumanFormatter(lineWidth: 160).format(report),
    ),
    for (final surface in inventory.surfaces)
      if (surface.semanticPath != null &&
          jsonSemantics.contains(surface.semanticPath))
        surface.id,
  };
}

Set<String> _classifyC6FailureJson(String serialized) {
  final document = jsonDecode(serialized) as Map<String, Object?>;
  final values = <String>{};
  final run = document['run'];
  if (run is Map<String, Object?>) {
    for (final key in ['status', 'exitCode']) {
      if (run.containsKey(key)) {
        values.add('\$.run.$key=${jsonEncode(run[key])}');
      }
    }
  }
  final diagnostics = document['diagnostics'];
  if (diagnostics is List<Object?>) {
    for (final (index, diagnostic) in diagnostics.indexed) {
      if (diagnostic is! Map<String, Object?>) continue;
      for (final key in ['code', 'phase', 'message']) {
        if (diagnostic.containsKey(key)) {
          values.add(
            '\$.diagnostics[$index].$key=${jsonEncode(diagnostic[key])}',
          );
        }
      }
    }
  }
  return values;
}

RunReport _c6FailedReport() => RunReport(
  identity: RunIdentity(
    id: 'c6-failed-scan',
    command: RunCommand.scan,
    toolVersion: 'test',
    startedAtUtc: DateTime.utc(2026, 8, 27),
    finishedAtUtc: DateTime.utc(2026, 8, 27, 0, 0, 1),
    elapsedMicros: 1000000,
  ),
  status: RunStatus.internalError,
  exitCode: 70,
  partialApplied: false,
  projectRoot: '/project',
  packageName: 'test',
  requestedAdapters: const ['dart'],
  targetMatrix: TargetMatrix.declared([
    BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    ),
  ]),
  rootCoverage: RootCoverage.applicationApi(),
  analysisPasses: const [],
  findings: const [],
  diagnostics: const [
    RunDiagnostic(
      code: 'adapter_analysis_failed',
      phase: 'analysis:adapter:dart',
      message:
          'Analysis failed after adapter Dart declaration analyzer (dart) started.',
    ),
  ],
);

String _usageFor(FlutterPrunerCommandRunner runner, String commandPath) {
  if (commandPath == 'root') return runner.usage;
  final parts = commandPath.split(' ');
  var command = runner.commands[parts.first]!;
  for (final part in parts.skip(1)) {
    command = command.subcommands[part]!;
  }
  return command.usage;
}

_CliSurfaceInventory _readInventory() {
  final decoded =
      jsonDecode(
            File(
              'test/cli/fixtures/cli_surface_inventory.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  return _CliSurfaceInventory(
    schemaVersion: decoded['schemaVersion']! as int,
    surfaces: (decoded['surfaces']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .map(_CliSurface.fromJson)
        .toList(growable: false),
  );
}

final class _CliSurfaceInventory {
  const _CliSurfaceInventory({
    required this.schemaVersion,
    required this.surfaces,
  });

  final int schemaVersion;
  final List<_CliSurface> surfaces;

  Set<String> get ids => surfaces.map((surface) => surface.id).toSet();
}

_TranscriptFixtures _readTranscriptFixtures() {
  final decoded =
      jsonDecode(
            File(
              'test/cli/fixtures/c3_transcript_matrix.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  if (decoded['schemaVersion'] != 1) {
    throw FormatException('unsupported transcript fixture schema');
  }
  final scenarios = (decoded['scenarios']! as Map<String, Object?>).map(
    (name, ids) => MapEntry(
      name,
      (ids! as List<Object?>).cast<String>().toList(growable: false),
    ),
  );
  return _TranscriptFixtures(scenarios);
}

final class _TranscriptFixtures {
  const _TranscriptFixtures(this.scenarios);

  final Map<String, List<String>> scenarios;
}

/// Extracts only reviewed user-facing presentation lines. Dynamic segments are
/// accepted solely through the typed placeholders declared in the inventory.
final class _PresentationExtractor {
  _PresentationExtractor(this.inventory);

  final _CliSurfaceInventory inventory;

  List<String> processLines(
    String stdoutText,
    String stderrText, {
    Set<String>? surfaceIds,
  }) {
    final normalized = <String>[];
    for (final stream in <String, String>{
      'stdout': stdoutText,
      'stderr': stderrText,
    }.entries) {
      for (final line in _lines(stream.value)) {
        final matches = _matchingSurfaces(stream.key, line, surfaceIds);
        normalized.addAll(matches.map((surface) => surface.id));
      }
    }
    return normalized;
  }

  List<String> allLines(String stdoutText, String stderrText) {
    final lines = <String>[];
    for (final stream in <String, String>{
      'stdout': stdoutText,
      'stderr': stderrText,
    }.entries) {
      final renderedLines = _lines(stream.value).toList(growable: false);
      for (var index = 0; index < renderedLines.length; index++) {
        final line = renderedLines[index];
        final ids = _matchingSurfaces(
          stream.key,
          line,
        ).map((surface) => surface.id).toList();
        if (ids.isNotEmpty) {
          lines.addAll(ids);
          continue;
        }
        final wrapped = _wrappedKnownSurface(stream.key, renderedLines, index);
        if (wrapped != null) {
          lines.addAll(wrapped.$1);
          index = wrapped.$2;
          continue;
        }
        lines.add('unregistered:${stream.key}:$line');
      }
    }
    return lines;
  }

  (List<String>, int)? _wrappedKnownSurface(
    String stream,
    List<String> lines,
    int start,
  ) {
    var logical = lines[start];
    List<String>? matchedIds;
    var matchedEnd = start;
    for (var end = start + 1; end < lines.length && end <= start + 7; end++) {
      if (_matchingSurfaces(stream, lines[end]).isNotEmpty) {
        return matchedIds == null ? null : (matchedIds, matchedEnd);
      }
      logical = _joinWrappedLine(logical, lines[end]);
      // Only a complete, typed inventory surface can consume visual wraps;
      // arbitrary adjacent output remains an unregistered line.
      final ids = _matchingWrappedSurfaces(stream, logical);
      if (ids.isNotEmpty) {
        matchedIds = ids;
        matchedEnd = end;
      }
    }
    return matchedIds == null ? null : (matchedIds, matchedEnd);
  }

  String _joinWrappedLine(String leading, String trailing) {
    if (leading == ' ! Manifest') {
      return '$leading ${trailing.trimLeft()}';
    }
    if (leading.startsWith(' ! Manifest ')) {
      return '$leading${trailing.trimLeft()}';
    }
    final leadingBorder = RegExp(r'^( *)│ ').firstMatch(leading);
    final trailingBorder = RegExp(r'^( *)│ ').firstMatch(trailing);
    if (leadingBorder != null &&
        trailingBorder != null &&
        leadingBorder.group(1) == trailingBorder.group(1) &&
        leading.endsWith(' │') &&
        trailing.endsWith(' │')) {
      return '${leading.substring(0, leading.length - 2)}'
          '${trailing.substring(trailingBorder.end)}';
    }
    return '$leading$trailing';
  }

  List<String> _matchingWrappedSurfaces(String stream, String logical) {
    final exact = _matchingSurfaces(stream, logical);
    if (exact.isNotEmpty) {
      return exact.map((surface) => surface.id).toList(growable: false);
    }
    if (stream == 'stdout' &&
        RegExp(
          r'^ ! Manifest (?:/|[A-Za-z]:).+/manifest\.json$',
        ).hasMatch(logical)) {
      return const ['apply.recovery.manifest'];
    }
    final recoverySummary = logical.trimLeft();
    if (stream == 'stdout' &&
        RegExp(
          '^│ Verification became unavailable for '
          '${_placeholderPatterns['wave-id']!.pattern}\\.; recovery could not be '
          'proven: Bad state: Rollback verification failed for whole apply run: '
          'flutter-analyze: nonzero exit without stable diagnostic evidence │\$',
        ).hasMatch(recoverySummary)) {
      return const ['apply.recovery.summary'];
    }
    final visual = inventory.surfaces
        .where(
          (surface) =>
              surface.stream == stream &&
              surface.state != 'help' &&
              !surface.approvedTranscript.contains('…') &&
              surface.placeholders.any(
                (placeholder) => _isVisualPathElision(placeholder.kind),
              ) &&
              _matchesVisualWrapTemplate(surface, logical),
        )
        .map((surface) => surface.id)
        .toList(growable: false);
    if (visual.isNotEmpty) return visual;

    final first = inventory.surfaces.singleWhere(
      (surface) => surface.id == 'apply.recovery.copy.first',
    );
    final second = inventory.surfaces.singleWhere(
      (surface) => surface.id == 'apply.recovery.copy.second',
    );
    if (stream == 'stdout' &&
        logical == '${first.approvedTranscript} ${second.approvedTranscript}') {
      return const ['apply.recovery.copy.first', 'apply.recovery.copy.second'];
    }
    return const [];
  }

  bool _matchesVisualWrapTemplate(_CliSurface surface, String candidate) {
    var pattern = RegExp.escape(surface.approvedTranscript);
    for (final placeholder in surface.placeholders) {
      pattern = pattern.replaceFirst(
        RegExp.escape(placeholder.token),
        '(${_visualWrapPlaceholderPattern(placeholder.kind)})',
      );
    }
    return RegExp('^$pattern\$').hasMatch(candidate);
  }

  bool _isVisualPathElision(String kind) =>
      kind == 'elided-path' ||
      kind == 'truncated-manifest-path' ||
      kind == 'manifest-path';

  String _visualWrapPlaceholderPattern(String kind) {
    switch (kind) {
      case 'elided-path':
        return r'(?:/|[A-Za-z]:)[^\r\n]+';
      case 'truncated-manifest-path':
      case 'manifest-path':
        return r'(?:(?:/|[A-Za-z]:[\\/])?[^\r\n]+[\\/])manifest\.json';
      default:
        return _placeholderPatterns[kind]!.pattern;
    }
  }

  List<String> artifactLines(String artifactText) {
    final lines = <String>[];
    for (final line in _lines(artifactText)) {
      final normalized = line.trimLeft();
      final ids = _matchingSurfaces(
        'saved-file',
        normalized,
      ).map((surface) => surface.id).toList();
      lines.addAll(ids.isEmpty ? ['unregistered:saved-file:$normalized'] : ids);
    }
    return lines;
  }

  Iterable<String> _lines(String output) => const LineSplitter()
      .convert(output.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), ''))
      .map((line) => line.replaceAll(RegExp(r'[ \t]+'), ' ').trimRight())
      .where((line) => line.trim().isNotEmpty);

  List<_CliSurface> _matchingSurfaces(
    String stream,
    String line, [
    Set<String>? surfaceIds,
  ]) {
    final matches = inventory.surfaces
        .where(
          (surface) =>
              surface.stream == stream &&
              surface.state != 'help' &&
              (surfaceIds == null || surfaceIds.contains(surface.id)) &&
              _matchesTemplate(
                surface.approvedTranscript,
                line,
                surface.placeholders,
              ),
        )
        .toList();
    matches.sort(
      (left, right) => right.approvedTranscript.length.compareTo(
        left.approvedTranscript.length,
      ),
    );
    return [
      for (final surface in matches)
        if (!matches.any(
          (other) =>
              other != surface &&
              other.approvedTranscript.length >
                  surface.approvedTranscript.length &&
              other.approvedTranscript.contains(surface.approvedTranscript),
        ))
          surface,
    ];
  }
}

final class _CliSurface {
  const _CliSurface({
    required this.id,
    required this.command,
    required this.state,
    required this.stream,
    required this.exits,
    required this.interaction,
    required this.currentTranscript,
    required this.approvedTranscript,
    required this.placeholders,
    required this.owner,
    required this.artifactOracle,
    required this.semanticPath,
  });

  factory _CliSurface.fromJson(Map<String, Object?> json) => _CliSurface(
    id: _requiredString(json, 'id'),
    command: _requiredString(json, 'command'),
    state: _requiredString(json, 'state'),
    stream: _requiredString(json, 'stream'),
    exits: _requiredExitCodes(json['exit']),
    interaction: _requiredString(json, 'interaction'),
    currentTranscript: _requiredString(json, 'currentTranscript'),
    approvedTranscript: _requiredString(json, 'approvedTranscript'),
    placeholders: ((json['placeholders'] as List<Object?>?) ?? const [])
        .cast<Map<String, Object?>>()
        .map(_CliTypedPlaceholder.fromJson)
        .toList(growable: false),
    owner: _requiredString(json, 'owner'),
    artifactOracle: json['artifactOracle'] == true,
    semanticPath: json['semanticPath'] as String?,
  );

  final String id;
  final String command;
  final String state;
  final String stream;
  final List<int> exits;
  final String interaction;
  final String currentTranscript;
  final String approvedTranscript;
  final List<_CliTypedPlaceholder> placeholders;
  final String owner;
  final bool artifactOracle;
  final String? semanticPath;
}

final class _CliTypedPlaceholder {
  const _CliTypedPlaceholder({
    required this.kind,
    required this.token,
    required this.example,
  });

  factory _CliTypedPlaceholder.fromJson(Map<String, Object?> json) =>
      _CliTypedPlaceholder(
        kind: _requiredString(json, 'kind'),
        token: _requiredString(json, 'token'),
        example: _requiredString(json, 'example'),
      );

  final String kind;
  final String token;
  final String example;
}

String _requiredString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('$key must be a string');
  return value;
}

List<int> _requiredExitCodes(Object? value) {
  if (value is int) return [value];
  if (value is List<Object?> && value.every((element) => element is int)) {
    return value.cast<int>();
  }
  throw FormatException('exit must be an integer or integer list');
}

final class _RecordingPrompt implements InitPrompt {
  _RecordingPrompt(this._responses);

  final List<String> _responses;
  final StringBuffer _output = StringBuffer();

  String get output => _output.toString();

  @override
  bool get isInteractive => true;

  @override
  String? readLine() => _responses.isEmpty ? null : _responses.removeAt(0);

  @override
  void write(String value) => _output.write(value);

  @override
  void writeln([String value = '']) => _output.writeln(value);
}
