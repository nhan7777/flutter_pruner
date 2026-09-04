import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart' as args;
import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/apply/import_cleanup_runner.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/apply_command.dart';
import 'package:flutter_pruner/src/cli/init_prompt.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_commit.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'report_output_collision_fixture.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('apply_command_test_');
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: apply_test
publish_to: none
environment:
  sdk: ^3.9.0
''');
    _writePackageConfig(tempDir);
    File(p.join(tempDir.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
    final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('''
import 'src/helper.dart';

void main() {
  usedFunction();
}
''');
    final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    helperFile.parent.createSync(recursive: true);
    helperFile.writeAsStringSync('''
void usedFunction() {}

void unusedFunction() {}
''');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  for (final variant in ReportOutputAliasVariant.values) {
    for (final invocation in _ReportCollisionApplyInvocation.values) {
      test(
        'apply rejects ${variant.name} report collision before ${invocation.name}',
        () async {
          final fixture = ReportOutputCollisionFixture.create(tempDir, variant);
          addTearDown(fixture.dispose);
          final verifier = _AlwaysPassingVerificationRunner(tempDir);
          final arguments = <String>[
            'apply',
            '--report-format',
            'json',
            '--report-output',
            fixture.requestedOutputPath,
            if (invocation ==
                _ReportCollisionApplyInvocation.dryRunNoAction) ...[
              '--dry-run',
              '--adapter',
              'duplicates',
            ] else ...[
              '--adapter',
              'dart',
              '--finding-id',
              'dart:apply_test/lib/src/helper.dart#unusedFunction',
            ],
            fixture.projectSelectionPath,
          ];

          final result = await _runApplyCaptured(
            FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
            arguments,
          );

          fixture.expectRetained();
          expect(result.exitCode, 1);
          expect(
            result.stderr,
            variant == ReportOutputAliasVariant.finalSymlink
                ? contains('category=collision')
                : contains('excluded by project path policy'),
          );
          expect(result.stderr, isNot(contains('Scanning')));
          expect(verifier.invocationCount, 0);
          expect(
            '${result.stdout}\n${result.stderr}',
            isNot(contains('REPORT READY')),
          );
        },
      );
    }
  }

  test(
    'apply rejects a final report symlink without replacing its target',
    () async {
      final target = File(p.join(tempDir.path, 'foreign-report.json'))
        ..writeAsStringSync('previous foreign report bytes');
      final alias = Link(p.join(tempDir.path, 'foreign-report-link.json'))
        ..createSync(target.path);
      final sentinel = File(p.join(tempDir.path, 'foreign-positive.bin'))
        ..writeAsBytesSync(const [9, 8, 7, 6]);
      final sentinelBytes = sentinel.readAsBytesSync();
      final sentinelMode = sentinel.statSync().mode & 0xfff;
      final sentinelSha = sha256.convert(sentinelBytes).toString();
      final originalLinkTarget = alias.targetSync();

      final result = await _runApplyCaptured(FlutterPrunerCommandRunner(), [
        'apply',
        '--dry-run',
        '--adapter',
        'duplicates',
        '--report-format',
        'json',
        '--report-output',
        alias.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 1);
      expect(result.stdout, isNot(contains('REPORT READY')));
      expect(result.stderr, contains('category=collision'));
      expect(
        FileSystemEntity.typeSync(alias.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(alias.targetSync(), originalLinkTarget);
      expect(
        alias.resolveSymbolicLinksSync(),
        target.resolveSymbolicLinksSync(),
      );
      expect(target.readAsStringSync(), 'previous foreign report bytes');
      final retainedSentinelBytes = sentinel.readAsBytesSync();
      expect(retainedSentinelBytes, orderedEquals(sentinelBytes));
      expect(sentinel.statSync().mode & 0xfff, sentinelMode);
      expect(sha256.convert(retainedSentinelBytes).toString(), sentinelSha);
      expect(
        target.parent
            .listSync(followLinks: false)
            .where(
              (entity) =>
                  p
                      .basename(entity.path)
                      .startsWith('${p.basename(target.path)}.') &&
                  (entity.path.endsWith('.tmp') ||
                      entity.path.endsWith('.previous')),
            ),
        isEmpty,
      );
    },
  );

  test(
    'apply project loader programmer error reaches runner exit 70',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'project-loader-error.json'),
      );
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            projectLoader:
                (
                  directory, {
                  configFile,
                  additionalExcludedPaths = const <String>[],
                }) async => throw StateError(
                  'injected apply project loader state error',
                ),
          ),
        ),
        [
          'apply',
          '--dry-run',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Internal error:'));
      expect(
        result.stderr,
        contains('injected apply project loader state error'),
      );
      expect(reportFile.existsSync(), isFalse);
    },
  );

  test(
    'apply report preparation programmer error reaches runner exit 70',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'report-preparation-error.json'),
      );
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            reportBackend: const _AnchorStateErrorReportObjectBackend(),
          ),
        ),
        [
          'apply',
          '--dry-run',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Internal error:'));
      expect(
        result.stderr,
        contains('injected apply report preparation state error'),
      );
      expect(reportFile.existsSync(), isFalse);
    },
  );

  test(
    'apply report preparation backend failure remains operational exit 1',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'report-backend-failure.json'),
      );
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            reportBackend: const _AnchorFailureReportObjectBackend(),
          ),
        ),
        [
          'apply',
          '--dry-run',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('report output could not be prepared'));
      expect(result.stderr, isNot(contains('Internal error:')));
      expect(reportFile.existsSync(), isFalse);
    },
  );

  test(
    'pre-transaction analyzer failure saves one sanitized failed report',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final reportFile = File(
        p.join(tempDir.path, 'pre-transaction-failure.json'),
      );
      const rawFailure = 'raw apply analyzer exception with private details';
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            analyzerFactory: (project, only) => _ThrowingInitialProjectAnalyzer(
              project: project,
              only: only,
              rawFailure: rawFailure,
            ),
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        contains(
          'Error: Analysis failed after adapter Dart declaration analyzer '
          '(dart) started.',
        ),
      );
      expect(result.stderr, isNot(contains(rawFailure)));
      expect(reportFile.existsSync(), isTrue);
      expect(
        result.stderr,
        contains(
          'Failure report saved: ${reportFile.resolveSymbolicLinksSync()}',
        ),
      );
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );

      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final run = report['run'] as Map<String, dynamic>;
      expect(run['command'], 'apply');
      expect(run['status'], 'internalError');
      expect(run['exitCode'], 70);
      expect(run['partialApplied'], isFalse);
      expect((report['execution'] as Map)['analysisPasses'], isEmpty);
      expect(report['findings'], isEmpty);
      expect(report, isNot(contains('quarantine')));
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().single,
        {
          'code': 'adapter_analysis_failed',
          'message':
              'Analysis failed after adapter Dart declaration analyzer (dart) '
              'started.',
          'phase': 'analysis:adapter:dart',
        },
      );
    },
  );

  test(
    'post-adapter apply analysis failure is not adapter-attributed',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'post-adapter-analysis-failure.json'),
      );
      const rawFailure = 'raw post-adapter apply analysis exception';
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            analyzerFactory: (project, only) =>
                _PostAdapterInitialProjectAnalyzer(
                  project: project,
                  only: only,
                  rawFailure: rawFailure,
                ),
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        contains('Error: Project analysis did not complete.'),
      );
      expect(
        result.stderr,
        isNot(contains('adapter Dart declaration analyzer')),
      );
      expect(result.stderr, isNot(contains(rawFailure)));
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().single,
        {
          'code': 'analysis_failed',
          'message': 'Project analysis did not complete.',
          'phase': 'analysis',
        },
      );
    },
  );

  test(
    'apply never emits or retains hostile adapter failure metadata',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'pre-transaction-hostile-adapter.json'),
      );
      const rawFailure = 'raw hostile apply analyzer exception';
      const hostileId = 'dart\nprivate\u202e';
      const hostileName = 'Dart\rprivate\u2066 analyzer';
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            analyzerFactory: (project, only) => _HostileInitialProjectAnalyzer(
              project: project,
              only: only,
              rawFailure: rawFailure,
            ),
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        contains('Error: Project analysis did not complete.'),
      );
      expect(result.stderr, isNot(contains(rawFailure)));
      expect(result.stderr, isNot(contains(hostileId)));
      expect(result.stderr, isNot(contains(hostileName)));
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect(report['findings'], isEmpty);
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().single,
        {
          'code': 'analysis_failed',
          'message': 'Project analysis did not complete.',
          'phase': 'analysis',
        },
      );
      expect(reportFile.readAsStringSync(), isNot(contains(rawFailure)));
      expect(reportFile.readAsStringSync(), isNot(contains(hostileId)));
      expect(reportFile.readAsStringSync(), isNot(contains(hostileName)));
    },
  );

  test(
    'post-analysis pre-transaction failure retains completed findings',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final reportFile = File(
        p.join(tempDir.path, 'post-analysis-failure.json'),
      );
      const rawFailure = 'raw baseline verifier exception with private details';
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          verifierFactory: (project) => _ThrowingBaselineVerificationRunner(
            project,
            rawFailure: rawFailure,
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          'dart:apply_test/lib/src/helper.dart#unusedFunction',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        contains(
          'Error: Apply failed after analysis and before transaction authority.',
        ),
      );
      expect(result.stderr, isNot(contains(rawFailure)));
      expect(
        result.stderr,
        contains(
          'Failure report saved: ${reportFile.resolveSymbolicLinksSync()}',
        ),
      );
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );

      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect((report['execution'] as Map)['analysisPasses'], hasLength(1));
      expect(
        (report['findings'] as List).cast<Map<String, dynamic>>().map(
          (finding) => (finding['node'] as Map<String, dynamic>)['id'],
        ),
        contains('dart:apply_test/lib/src/helper.dart#unusedFunction'),
      );
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().single,
        {
          'code': 'apply_pre_transaction_failed',
          'message':
              'Apply failed after analysis and before transaction authority.',
          'phase': 'applyPlanning',
        },
      );
    },
  );

  test(
    'confirmed baseline cancellation saves interrupted report before exit 130',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final reportFile = File(p.join(tempDir.path, 'baseline-cancelled.json'));

      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          verifierFactory: _CancellingBaselineVerificationRunner.new,
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          'dart:apply_test/lib/src/helper.dart#unusedFunction',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 130);
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect((report['run'] as Map)['status'], 'interrupted');
      expect((report['run'] as Map)['exitCode'], 130);
      expect(
        (report['diagnostics'] as List)
            .cast<Map<String, dynamic>>()
            .single['code'],
        'process_cancelled_before_mutation',
      );
    },
  );

  test(
    'unconfirmed baseline retains typed PID authority before any mutation',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final snapshot = await const ManagedProcessIdentityInspector().snapshot();
      final rootIdentity = snapshot?.identityFor(pid);
      expect(rootIdentity, isNotNull);
      final retainedRootIdentity = rootIdentity!;
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final reportFile = File(
        p.join(tempDir.path, 'baseline-unconfirmed.json'),
      );

      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          verifierFactory: (project) => _UnconfirmedBaselineVerificationRunner(
            project,
            rootIdentity: retainedRootIdentity,
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          'dart:apply_test/lib/src/helper.dart#unusedFunction',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('PID $pid'));
      expect(result.stderr, contains('may still be running'));
      expect(result.stderr, contains('No source mutation was attempted'));
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );

      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect((report['run'] as Map)['status'], 'infrastructureFailure');
      expect((report['run'] as Map)['exitCode'], 1);
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().single,
        {
          'code': 'process_termination_unconfirmed_before_mutation',
          'message':
              'A verification process rooted at PID $pid may still be '
              'running. No source mutation was attempted. Future mutating '
              'commands remain blocked until every exact recorded process '
              'identity is absent; rerun the command to recheck.',
          'phase': 'verificationBaseline',
        },
      );
      final journal = ToolWorkspace(
        tempDir,
      ).operationLockFile.readAsStringSync();
      expect(journal, contains('"state":"unconfirmed"'));
      expect(journal, contains('"rootPid":$pid'));
      expect(journal, contains(retainedRootIdentity.startFingerprint));
      await expectLater(
        ProjectOperationLock.acquire(
          workspace: ToolWorkspace(tempDir),
          operation: 'later-apply',
        ),
        throwsA(
          isA<ProjectOperationLockException>().having(
            (error) => error.message,
            'message',
            allOf(contains('PID $pid'), contains('No mutation was attempted')),
          ),
        ),
      );
    },
  );

  test(
    'failed-report writer is attempted once and keeps apply failure primary',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'pre-transaction-write-failure.json'),
      );
      final backend = _ApplyFailureReportObjectBackend(
        createIoReportObjectBackend(),
        mode: _ApplyReportBackendFailureMode.write,
      );
      const rawFailure = 'raw apply analyzer exception';
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            reportBackend: backend,
            analyzerFactory: (project, only) => _ThrowingInitialProjectAnalyzer(
              project: project,
              only: only,
              rawFailure: rawFailure,
            ),
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(
        result.stderr,
        contains(
          'Error: Analysis failed after adapter Dart declaration analyzer '
          '(dart) started.',
        ),
      );
      expect(result.stderr, contains('report was not saved'));
      expect(result.stderr, isNot(contains('Failure report saved:')));
      expect(result.stderr, isNot(contains(rawFailure)));
      expect(backend.createCalls, 1);
      expect(backend.writeCalls, 1);
      expect(reportFile.existsSync(), isTrue);
      expect(reportFile.lengthSync(), 0);
      expect(
        File(
          p.join(
            reportFile.parent.path,
            '.${p.basename(reportFile.path)}.commit.json',
          ),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'post-commit close failure retains exact apply failure-report authority',
    () async {
      final reportFile = File(
        p.join(tempDir.path, 'pre-transaction-close-store.json'),
      );
      final backend = _ApplyFailureReportObjectBackend(
        createIoReportObjectBackend(),
        mode: _ApplyReportBackendFailureMode.closeStore,
      );
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(
          applyCommandFactory: () => ApplyCommand(
            reportBackend: backend,
            analyzerFactory: (project, only) => _ThrowingInitialProjectAnalyzer(
              project: project,
              only: only,
              rawFailure: 'raw apply analyzer exception',
            ),
          ),
        ),
        [
          'apply',
          '--adapter',
          'dart',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ],
      );

      expect(result.exitCode, 70);
      expect(result.stdout, isEmpty);
      expect(reportFile.existsSync(), isTrue);
      expect(
        jsonDecode(reportFile.readAsStringSync()),
        isA<Map<String, dynamic>>(),
      );
      expect(
        result.stderr,
        contains(
          'Failure report saved: ${reportFile.resolveSymbolicLinksSync()}',
        ),
      );
      expect(
        result.stderr,
        contains('report output close failed after commit'),
      );
      expect(result.stderr, isNot(contains('report was not saved')));
      expect(backend.createCalls, 2);
      expect(backend.closeCalls, 2);
      expect(
        File(
          p.join(
            reportFile.parent.path,
            '.${p.basename(reportFile.path)}.commit.json',
          ),
        ).existsSync(),
        isTrue,
      );
    },
  );

  test('requires init before apply starts', () async {
    File(p.join(tempDir.path, 'flutter_pruner.yaml')).deleteSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--dry-run', tempDir.path]);

    expect(exitCode, 1);
    expect(verifier.invocationCount, 0);
    expect(
      Directory(p.join(tempDir.path, '.flutter_pruner')).existsSync(),
      isFalse,
    );
  });

  test('rejects incomplete coverage before apply analysis', () async {
    final config = File(p.join(tempDir.path, 'flutter_pruner.yaml'));
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        'complete: true',
        'complete: false',
      ),
    );
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--dry-run', tempDir.path]);

    expect(exitCode, 1);
    expect(verifier.invocationCount, 0);
    expect(
      Directory(p.join(tempDir.path, '.flutter_pruner')).existsSync(),
      isFalse,
    );
  });

  test('package mode rejects apply and dry-run before analysis', () async {
    final config = File(p.join(tempDir.path, 'flutter_pruner.yaml'));
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        '  mode: application\n',
        '  mode: package\n'
            '  public_entrypoints:\n'
            '    - lib/main.dart\n',
      ),
    );
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    expect(
      await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--dry-run', tempDir.path]),
      1,
    );
    expect(verifier.invocationCount, 0);
  });

  test('rejects an unknown adapter before verification or mutation', () async {
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = source.readAsBytesSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'not_registered', tempDir.path]);

    expect(exitCode, 64);
    expect(verifier.invocationCount, 0);
    expect(source.readAsBytesSync(), originalBytes);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'exact finding selector mutates only the requested same-file declaration',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      const original = '''
void usedFunction() {}

void unusedFunction() {}

void unselectedFunction() {}
''';
      source.writeAsStringSync(original);
      const requestedId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
      const unselectedId =
          'dart:apply_test/lib/src/helper.dart#unselectedFunction';
      final reportFile = File(p.join(tempDir.path, 'selector-apply.json'));
      final verifier = _AlwaysPassingVerificationRunner(tempDir);

      final exitCode =
          await FlutterPrunerCommandRunner(
            verifierFactory: (_) => verifier,
          ).run([
            'apply',
            '--finding-id',
            requestedId,
            '--report-format',
            'json',
            '--report-output',
            reportFile.path,
            tempDir.path,
          ]);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 2);
      expect(source.readAsStringSync(), isNot(contains('unusedFunction')));
      expect(source.readAsStringSync(), contains('unselectedFunction'));

      final manager = QuarantineManager(tempDir);
      final quarantineInfo = (await manager.listQuarantines()).single;
      final quarantine = Directory(quarantineInfo.path);
      final manifestJson =
          jsonDecode(
                File(
                  p.join(quarantine.path, 'manifest.json'),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final selection = manifestJson['selection'] as Map<String, dynamic>;
      expect(selection['mode'], 'exact');
      expect(selection['requestedFindingIds'], [requestedId]);
      expect(
        selection['planFingerprint'],
        '36e18b7231a4ebc73d665e151e3d77216d293cc68855462e2d44b36c4fc14280',
      );
      expect(
        ((manifestJson['transactions'] as List).single as Map)['findingIds'],
        [requestedId],
      );

      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final candidateAttempt = (report['verificationAttempts'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((attempt) => attempt['purpose'] == 'candidate');
      expect(candidateAttempt['waveId'], 'wave-r001');
      final transactionId =
          ((manifestJson['transactions'] as List).single
                  as Map)['transactionId']
              as String;
      expect(candidateAttempt['transactionIds'], [transactionId]);
      expect(candidateAttempt['transactionId'], transactionId);
      final apply = report['apply'] as Map<String, dynamic>;
      final reportSelection = apply['selection'] as Map<String, dynamic>;
      expect(reportSelection['mode'], 'exact');
      expect(reportSelection['requestedFindingIds'], [requestedId]);
      expect(reportSelection['plannedFindingIds'], [requestedId]);
      expect(reportSelection['planFingerprint'], selection['planFingerprint']);
      expect((apply['findingOutcomes'] as List), hasLength(1));
      expect(
        ((apply['findingOutcomes'] as List).single as Map)['findingId'],
        requestedId,
      );
      expect((apply['findings'] as Map)['remaining'], 0);
      expect(
        (report['findings'] as List).cast<Map<String, dynamic>>().singleWhere(
          (finding) =>
              (finding['node'] as Map<String, dynamic>)['id'] == unselectedId,
        )['applyEligible'],
        isTrue,
      );

      expect(
        await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', tempDir.path, quarantineInfo.runId]),
        0,
      );
      expect(source.readAsStringSync(), original);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('two exact transactions commit through one verification wave', () async {
    final first = File(p.join(tempDir.path, 'lib', 'src', 'first.dart'));
    const firstOriginal = '''
void keepFirst() {}

void selectedFirst() {}
''';
    first.writeAsStringSync(firstOriginal);
    final second = File(p.join(tempDir.path, 'lib', 'src', 'second.dart'));
    const secondOriginal = '''
void keepSecond() {}

void selectedSecond() {}
''';
    second.writeAsStringSync(secondOriginal);
    File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'src/first.dart';
import 'src/second.dart';

void main() {
  keepFirst();
  keepSecond();
}
''');
    const firstId = 'dart:apply_test/lib/src/first.dart#selectedFirst';
    const secondId = 'dart:apply_test/lib/src/second.dart#selectedSecond';
    final reportFile = File(
      p.join(tempDir.path, 'selector-later-unit-failure.json'),
    );
    final verifier = _CombinedStateVerificationRunner(
      tempDir,
      first: first,
      second: second,
    );

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--finding-id',
          firstId,
          '--finding-id',
          secondId,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

    expect(exitCode, 0);
    expect(verifier.invocationCount, 2);
    expect(first.readAsStringSync(), isNot(contains('selectedFirst')));
    expect(second.readAsStringSync(), isNot(contains('selectedSecond')));
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.selection?.requestedFindingIds, [firstId, secondId]);
    expect(manifest.transactions, hasLength(2));
    expect(manifest.transactions.expand((item) => item.findingIds).toSet(), {
      firstId,
      secondId,
    });
    expect(
      manifest.transactions,
      everyElement(
        isA<QuarantineTransaction>().having(
          (item) => item.status,
          'status',
          QuarantineTransactionStatus.committed,
        ),
      ),
    );
    expect(manifest.verificationWaves, hasLength(1));
    expect(manifest.verificationWaves.single.verificationWaveId, 'wave-r001');
    expect(manifest.verificationWaves.single.transactionIds, [
      ...manifest.transactions.map((item) => item.transactionId),
    ]);
    final report =
        jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
    final candidateAttempt = (report['verificationAttempts'] as List)
        .cast<Map<String, dynamic>>()
        .singleWhere((attempt) => attempt['purpose'] == 'candidate');
    expect(candidateAttempt['waveId'], 'wave-r001');
    expect(candidateAttempt['transactionIds'], [
      ...manifest.transactions.map((item) => item.transactionId),
    ]);
    expect(candidateAttempt, isNot(contains('transactionId')));
    final apply = report['apply'] as Map<String, dynamic>;
    final outcomes = (apply['findingOutcomes'] as List)
        .cast<Map<String, dynamic>>();
    expect(outcomes.map((item) => item['findingId']).toSet(), {
      firstId,
      secondId,
    });
    expect(
      outcomes,
      everyElement(
        isA<Map<String, dynamic>>()
            .having((item) => item['status'], 'status', 'committed')
            .having(
              (item) => item['reason'],
              'reason',
              'The verification wave was accepted and the transaction was '
                  'committed as a member.',
            ),
      ),
    );
    expect((apply['transactions'] as Map)['committed'], 2);
    expect((apply['transactions'] as Map)['rolledBackVerified'], 0);
    expect((apply['findings'] as Map)['remaining'], 0);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'deleted path recreation between wave cases fails closed and preserves bytes',
    () async {
      final first = File(p.join(tempDir.path, 'lib', 'src', 'first.dart'));
      const firstOriginal = '''
void keepFirst() {}

void selectedFirst() {}
''';
      first.writeAsStringSync(firstOriginal);
      final dead = File(p.join(tempDir.path, 'lib', 'src', 'dead.dart'));
      const deadOriginal = 'library dead;\n';
      dead.writeAsStringSync(deadOriginal);
      final firstOriginalMode = _posixMode(first);
      final deadOriginalMode = Platform.isLinux || Platform.isMacOS
          ? _posixMode(dead)
          : null;
      File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'src/first.dart';

void main() => keepFirst();
''');
      const deadId = 'dart:apply_test/lib/src/dead.dart';
      const firstId = 'dart:apply_test/lib/src/first.dart#selectedFirst';
      const recreated = 'external recreation\n';
      var injected = false;
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) => QuarantineManager(
              projectRoot,
              displacementHook: (context) {
                if (!injected &&
                    context.point ==
                        QuarantineDisplacementPoint.afterCandidateJournal &&
                    p.equals(context.source.path, dead.path)) {
                  injected = true;
                  context.source.writeAsStringSync(recreated, flush: true);
                  if (Platform.isLinux || Platform.isMacOS) {
                    _chmod(context.source, 0x1a0);
                  }
                }
              },
            ),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--finding-id',
        deadId,
        '--finding-id',
        firstId,
        tempDir.path,
      ]);

      expect(exitCode, 1);
      expect(injected, isTrue);
      expect(verifier.invocationCount, 1);
      expect(dead.readAsStringSync(), recreated);
      if (Platform.isLinux || Platform.isMacOS) {
        expect(_posixMode(dead), 0x1a0);
      }
      expect(first.readAsStringSync(), firstOriginal);
      expect(_posixMode(first), firstOriginalMode);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.verificationWaves, isEmpty);
      expect(
        manifest.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.recoveryRequired),
      );
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      expect(manifest.cases, hasLength(1));
      expect(manifest.transactions, hasLength(1));
      expect(manifest.transactions.single.findingIds, [deadId]);
      expect(
        manifest.transactions.single.failureReason,
        contains('Wave path was recreated after deletion'),
      );
      final deadCase = manifest.cases.single;
      expect(deadCase.entry.originalPath, dead.path);
      expect(deadCase.entry.modifiedSha256, isNull);
      expect(
        deadCase.entry.sha256,
        sha256.convert(utf8.encode(deadOriginal)).toString(),
      );
      expect(deadCase.entry.posixMode, deadOriginalMode);
      final deadBackup = await manager.promotedBackupForCase(
        quarantineDir: quarantine,
        caseId: deadCase.caseId,
      );
      expect(deadBackup, isNotNull);
      expect(deadBackup!.readAsStringSync(), deadOriginal);
      if (Platform.isLinux || Platform.isMacOS) {
        expect(_posixMode(deadBackup), deadOriginalMode);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'unknown exact finding selector stops before baseline and quarantine',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final reportFile = File(p.join(tempDir.path, 'selector-unknown.json'));
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      const unknownId = 'dart:apply_test/lib/src/helper.dart#typo';

      final exitCode =
          await FlutterPrunerCommandRunner(
            verifierFactory: (_) => verifier,
          ).run([
            'apply',
            '--finding-id',
            unknownId,
            '--report-format',
            'json',
            '--report-output',
            reportFile.path,
            tempDir.path,
          ]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 0);
      expect(source.readAsBytesSync(), originalBytes);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      expect((report['run'] as Map)['status'], 'safeStopped');
      final selection =
          ((report['apply'] as Map)['selection'] as Map<String, dynamic>);
      expect(selection['mode'], 'exact');
      expect(selection['requestedFindingIds'], [unknownId]);
      expect(selection['plannedFindingIds'], isEmpty);
      expect(selection['planFingerprint'], isNull);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('empty and duplicate finding selectors are usage errors', () async {
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = source.readAsBytesSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);
    const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';

    for (final arguments in <List<String>>[
      ['apply', '--finding-id=', tempDir.path],
      [
        'apply',
        '--finding-id',
        findingId,
        '--finding-id',
        findingId,
        tempDir.path,
      ],
    ]) {
      expect(
        await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(arguments),
        64,
      );
    }

    expect(verifier.invocationCount, 0);
    expect(source.readAsBytesSync(), originalBytes);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'preview expectation syntax is validated before project lock or analysis',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';

      for (final malformed in <String>[
        'a' * 64,
        'v1:${'A' * 64}',
        'v1:${'a' * 63}',
        'v2:${'a' * 64}',
      ]) {
        final result = await _runApplyCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'apply',
            '--finding-id',
            findingId,
            '--expect-preview-fingerprint',
            malformed,
            tempDir.path,
          ],
        );

        expect(result.exitCode, 64);
        expect(
          result.stderr,
          contains('Preview fingerprint must use v1:<64 lowercase hex>.'),
        );
        expect(result.stderr, isNot(contains('Scanning')));
      }

      expect(verifier.invocationCount, 0);
      expect(source.readAsBytesSync(), orderedEquals(originalBytes));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(p.join(tempDir.path, '.flutter_pruner')).existsSync(),
        isFalse,
      );
    },
  );

  test(
    'preview expectation requires an exact finding before project lock',
    () async {
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final result = await _runApplyCaptured(
        FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
        [
          'apply',
          '--expect-preview-fingerprint',
          'v1:${'a' * 64}',
          tempDir.path,
        ],
      );

      expect(result.exitCode, 64);
      expect(
        result.stderr,
        contains(
          '--expect-preview-fingerprint requires at least one --finding-id.',
        ),
      );
      expect(result.stderr, isNot(contains('Scanning')));
      expect(verifier.invocationCount, 0);
      expect(
        Directory(p.join(tempDir.path, '.flutter_pruner')).existsSync(),
        isFalse,
      );
    },
  );

  test('mixed known and unknown exact batch is rejected atomically', () async {
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = source.readAsBytesSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);
    const knownId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
    const unknownId = 'dart:apply_test/lib/src/helper.dart#missingFunction';
    final reportFile = File(p.join(tempDir.path, 'selector-mixed.json'));

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--finding-id',
          knownId,
          '--finding-id',
          unknownId,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 0);
    expect(source.readAsBytesSync(), originalBytes);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    final selection = (report['apply'] as Map)['selection'] as Map;
    expect(selection['requestedFindingIds'], [unknownId, knownId]);
    expect(selection['plannedFindingIds'], isEmpty);
    expect((report['verificationAttempts'] as List), isEmpty);
    final outcome =
        (((report['apply'] as Map)['findingOutcomes'] as List).single as Map);
    expect(outcome['findingId'], knownId);
    expect(outcome['reasonCode'], 'not_attempted_batch_invalid');
    expect(((report['apply'] as Map)['findings'] as Map)['remaining'], 1);
  });

  test('selected retained dependency blocks the entire exact batch', () async {
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    const original = '''
void usedFunction() {}

void unusedConsumer() {
  unusedDependency();
}

void unusedDependency() {}
''';
    source.writeAsStringSync(original);
    final canarySource = File(p.join(tempDir.path, 'lib', 'src', 'canary.dart'))
      ..writeAsStringSync('''
void keepCanaryFile() {}

void selectedCanary() {}
''');
    File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'src/canary.dart';
import 'src/helper.dart';

void main() {
  keepCanaryFile();
  usedFunction();
}
''');
    final canaryOriginal = canarySource.readAsBytesSync();
    const canaryId = 'dart:apply_test/lib/src/canary.dart#selectedCanary';
    const dependencyId = 'dart:apply_test/lib/src/helper.dart#unusedDependency';
    final reportFile = File(p.join(tempDir.path, 'selector-blocked.json'));
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--finding-id',
          canaryId,
          '--finding-id',
          dependencyId,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 0);
    expect(source.readAsStringSync(), original);
    expect(canarySource.readAsBytesSync(), canaryOriginal);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    final apply = report['apply'] as Map;
    expect((apply['selection'] as Map)['requestedFindingIds'], [
      canaryId,
      dependencyId,
    ]);
    final outcomes = (apply['findingOutcomes'] as List)
        .cast<Map<String, dynamic>>();
    expect(outcomes, hasLength(2));
    expect(
      outcomes.singleWhere(
        (item) => item['findingId'] == dependencyId,
      )['status'],
      'blocked',
    );
    expect(
      outcomes.singleWhere(
        (item) => item['findingId'] == canaryId,
      )['reasonCode'],
      'not_attempted_batch_blocked',
    );
  });

  test('non-actionable exact finding stops before baseline', () async {
    final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
    mainFile.writeAsStringSync('''
import 'src/helper.dart';

void main(dynamic receiver) {
  usedFunction();
  receiver.invoke();
}
''');
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    const original = '''
void usedFunction() {}

class InvocationOwner {
  void invoke() {}
}
''';
    source.writeAsStringSync(original);
    const reviewId = 'dart:apply_test/lib/src/helper.dart#InvocationOwner';
    final verifier = _AlwaysPassingVerificationRunner(tempDir);
    final reportFile = File(
      p.join(tempDir.path, 'selector-non-actionable.json'),
    );

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--finding-id',
          reviewId,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 0);
    expect(source.readAsStringSync(), original);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    final apply = report['apply'] as Map;
    expect((apply['findings'] as Map)['remaining'], 1);
    final outcome = (apply['findingOutcomes'] as List).single as Map;
    expect(outcome['findingId'], reviewId);
    expect(outcome['reasonCode'], 'not_attempted_batch_invalid');
  });

  test('dynamic spawnUri boundary admits no exact mutation unit', () async {
    File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'dart:isolate';
import 'src/helper.dart';

void main() {
  usedFunction();
}

void launch(Uri target) {
  Isolate.spawnUri(target, const [], null);
}
''');
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = source.readAsBytesSync();
    const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
    final reportFile = File(p.join(tempDir.path, 'spawn-uri-selection.json'));
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          findingId,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 0);
    expect(source.readAsBytesSync(), originalBytes);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final report =
        jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
    final finding = (report['findings']! as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere(
          (item) => (item['node']! as Map<String, Object?>)['id'] == findingId,
        );
    expect(finding['confidence'], 'REVIEW');
    expect(finding['applyEligible'], isFalse);
    expect(finding.containsKey('proposedAction'), isFalse);
    final blockers = (report['blockers']! as Map<String, Object?>).values
        .cast<Map<String, Object?>>();
    expect(
      blockers,
      contains(
        predicate<Map<String, Object?>>(
          (blocker) =>
              (blocker['reason'] as String).startsWith('spawn-uri-dynamic:'),
        ),
      ),
    );
    final apply = report['apply']! as Map<String, Object?>;
    expect(
      (apply['selection']! as Map<String, Object?>)['plannedFindingIds'],
      isEmpty,
    );
    final outcome =
        (apply['findingOutcomes']! as List<Object?>).single
            as Map<String, Object?>;
    expect(outcome['findingId'], findingId);
    expect(outcome['status'], 'remaining');
    expect(outcome['reasonCode'], 'not_attempted_batch_invalid');
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'mixed spawnUri provenance admits no exact conditional mutation unit',
    () async {
      File(p.join(tempDir.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/android.dart
    - name: ios
      platform: ios
      entrypoint: lib/ios.dart
''');
      File(p.join(tempDir.path, 'lib', 'android.dart')).writeAsStringSync('''
import 'dart:isolate';
void main() => launch();
void launch() {
  Isolate.spawnUri(Uri.parse('worker.dart'), const [], null);
}
''');
      File(p.join(tempDir.path, 'lib', 'ios.dart')).writeAsStringSync('''
import 'android.dart';
void main() => launch();
''');
      File(p.join(tempDir.path, 'tool', 'launcher.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void main() => launch();
''');
      File(p.join(tempDir.path, 'test', 'launcher_test.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void exercise() => launch();
''');
      File(p.join(tempDir.path, 'bin', 'launcher.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void main() => launch();
''');
      File(p.join(tempDir.path, 'lib', 'worker.dart')).writeAsStringSync('''
import 'branch_default.dart'
  if (dart.library.html) 'branch_web.dart'
  if (dart.library.io) 'branch_io.dart';
void main() => selectedBranch();
''');
      File(
        p.join(tempDir.path, 'lib', 'branch_default.dart'),
      ).writeAsStringSync('void selectedBranch() {}\n');
      final source = File(p.join(tempDir.path, 'lib', 'branch_web.dart'))
        ..writeAsStringSync('void selectedBranch() {}\n');
      File(
        p.join(tempDir.path, 'lib', 'branch_io.dart'),
      ).writeAsStringSync('void selectedBranch() {}\n');
      final originalBytes = source.readAsBytesSync();
      const findingId = 'dart:apply_test/lib/branch_web.dart#selectedBranch';
      final reportFile = File(
        p.join(tempDir.path, 'mixed-spawn-uri-selection.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);

      final exitCode =
          await FlutterPrunerCommandRunner(
            verifierFactory: (_) => verifier,
          ).run([
            'apply',
            '--adapter',
            'dart',
            '--finding-id',
            findingId,
            '--report-format',
            'json',
            '--report-output',
            reportFile.path,
            tempDir.path,
          ]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 0);
      expect(source.readAsBytesSync(), originalBytes);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
      final finding = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .singleWhere(
            (item) =>
                (item['node']! as Map<String, Object?>)['id'] == findingId,
          );
      expect(finding['confidence'], 'REVIEW');
      expect(finding['applyEligible'], isFalse);
      expect(finding.containsKey('proposedAction'), isFalse);
      expect(
        (finding['predicates']! as Map<String, Object?>)['notRetained'],
        isFalse,
      );
      final apply = report['apply']! as Map<String, Object?>;
      expect(
        (apply['selection']! as Map<String, Object?>)['plannedFindingIds'],
        isEmpty,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'exact execution never adopts an auxiliary path that appears after planning',
    () async {
      final asset = File(p.join(tempDir.path, 'assets', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('planned asset bytes\n');
      final lateCompanion = File(
        p.join(tempDir.path, 'assets', '2.0x', 'canary.txt'),
      )..parent.createSync(recursive: true);
      const lateContents = 'bytes created after the immutable action plan\n';
      const findingId = 'asset:apply_test/assets/canary.txt';
      final verifier = _MutatingBaselineVerificationRunner(
        tempDir,
        lateCompanion,
        lateContents,
      );

      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) => _LateVariantProjectAnalyzer(
              project: project,
              only: only,
              findingId: findingId,
              assetPath: asset.path,
              variantPath: lateCompanion.path,
            ),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--finding-id',
        findingId,
        tempDir.path,
      ]);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 2);
      expect(asset.existsSync(), isFalse);
      expect(lateCompanion.readAsStringSync(), lateContents);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.selection?.requestedFindingIds, [findingId]);
      expect(
        manifest.cases
            .map((item) => p.normalize(item.entry.originalPath))
            .toSet(),
        {p.normalize(asset.path)},
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('duplicate analysis finding ID is an integrity stop', () async {
    final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = source.readAsBytesSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);
    final reportFile = File(p.join(tempDir.path, 'selector-duplicate.json'));

    final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
      ..argParser.addFlag('verbose', negatable: false)
      ..addCommand(
        ApplyCommand(
          verifierFactory: (_) => verifier,
          analyzerFactory: (project, only) =>
              _DuplicateFindingProjectAnalyzer(project: project, only: only),
        ),
      );
    final exitCode = await runner.run([
      'apply',
      '--finding-id',
      'dart:apply_test/lib/src/helper.dart#unusedFunction',
      '--report-format',
      'json',
      '--report-output',
      reportFile.path,
      tempDir.path,
    ]);

    expect(exitCode, 70);
    expect(verifier.invocationCount, 0);
    expect(source.readAsBytesSync(), originalBytes);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    expect((report['run'] as Map)['status'], 'internalError');
    expect(
      (report['diagnostics'] as List)
          .cast<Map<String, dynamic>>()
          .single['code'],
      'finding_selection_snapshot_integrity',
    );
  });

  test(
    'exact apply rejects a retained SAFE snapshot before verification or mutation',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final originalSha = sha256.convert(originalBytes).toString();
      const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final reportFile = File(
        p.join(tempDir.path, 'retained-safe-selection.json'),
      );

      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) =>
                _RetainedSafeFindingProjectAnalyzer(
                  project: project,
                  only: only,
                  findingId: findingId,
                ),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        findingId,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 0);
      final retainedBytes = source.readAsBytesSync();
      expect(retainedBytes, orderedEquals(originalBytes));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(sha256.convert(retainedBytes).toString(), originalSha);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, Object?>;
      final finding = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>()
          .singleWhere(
            (item) =>
                (item['node']! as Map<String, Object?>)['id'] == findingId,
          );
      expect(finding['confidence'], 'SAFE');
      expect(finding['applyEligible'], isFalse);
      expect(
        (finding['predicates']! as Map<String, Object?>)['notRetained'],
        isFalse,
      );
      expect(
        (report['apply']! as Map<String, Object?>)['selection'],
        isA<Map<String, Object?>>().having(
          (selection) => selection['plannedFindingIds'],
          'plannedFindingIds',
          isEmpty,
        ),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'exact run rolls back when requested ID remains in the final scan',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final original = source.readAsStringSync();
      const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final reportFile = File(
        p.join(tempDir.path, 'selector-final-remaining.json'),
      );

      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) =>
                _ReappearingFinalProjectAnalyzer(
                  project: project,
                  only: only,
                  findingId: findingId,
                ),
          ),
        );
      final exitCode = await runner.run([
        'apply',
        '--finding-id',
        findingId,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 3);
      expect(source.readAsStringSync(), original);
      final manager = QuarantineManager(tempDir);
      final quarantine = (await manager.listQuarantines()).single;
      final quarantineDir = Directory(quarantine.path);
      expect(
        await manager.readRunLifecycleState(quarantineDir),
        QuarantineRunLifecycleState.rolledBackVerified,
      );
      final manifest = await manager.readManifest(quarantineDir);
      expect(manifest.selection?.requestedFindingIds, [findingId]);
      expect(manifest.transactions.expand((item) => item.findingIds).toSet(), {
        findingId,
      });
      expect(
        manifest.transactions,
        everyElement(
          isA<QuarantineTransaction>().having(
            (item) => item.status,
            'status',
            QuarantineTransactionStatus.rolledBackVerified,
          ),
        ),
      );
      final report = jsonDecode(reportFile.readAsStringSync()) as Map;
      expect((report['run'] as Map)['status'], 'safeStopped');
      final outcome =
          ((report['apply'] as Map)['findingOutcomes'] as List).single as Map;
      expect(outcome['findingId'], findingId);
      expect(outcome['status'], 'rejectedRecovered');
      expect(outcome['rollbackVerified'], isTrue);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'apply quarantines the original before editing and can roll back',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final original = helperFile.readAsStringSync();
      final htmlReport = File(p.join(tempDir.path, 'reports', 'apply.html'));
      htmlReport.parent.createSync(recursive: true);

      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      Directory? verifierProject;
      final exitCode =
          await FlutterPrunerCommandRunner(
            verifierFactory: (project) {
              verifierProject = project;
              return verifier;
            },
          ).run([
            'apply',
            '--report-output',
            htmlReport.path,
            '--report-format',
            'html',
            tempDir.path,
          ]);

      expect(exitCode, 0);
      expect(helperFile.readAsStringSync(), contains('usedFunction'));
      expect(helperFile.readAsStringSync(), isNot(contains('unusedFunction')));
      expect(verifier.invocationCount, 2);
      expect(verifierProject?.path, tempDir.path);

      final manager = QuarantineManager(tempDir);
      final quarantines = await manager.listQuarantines();
      expect(quarantines, hasLength(1));

      final quarantine = quarantines.single;
      expect(
        quarantine.path,
        startsWith(p.join(tempDir.path, '.flutter_pruner', 'quarantine')),
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(
                  Directory(quarantine.path),
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(report['version'], 3);
      expect((report['run'] as Map)['id'], quarantine.runId);
      expect((report['run'] as Map)['status'], 'completed');
      expect((report['apply'] as Map)['sourceBytesRemoved'], greaterThan(0));
      expect((report['verificationAttempts'] as List), hasLength(2));
      expect(report['findings'], isEmpty);
      final outcomes = (report['apply'] as Map)['findingOutcomes'] as List;
      expect(outcomes, hasLength(1));
      final outcome = outcomes.single as Map;
      expect(outcome['findingId'], contains('#unusedFunction'));
      expect(outcome['status'], 'committed');
      expect(outcome['reasonCode'], 'verification_accepted');
      expect(outcome['transactionId'], isNotEmpty);
      expect(outcome['rollbackVerified'], isNull);
      expect(
        ((outcome['finding'] as Map)['node'] as Map)['projectRelativeOrigin'],
        'lib/src/helper.dart',
      );
      expect(htmlReport.readAsStringSync(), startsWith('<!doctype html>'));
      expect(htmlReport.readAsStringSync(), contains('findingOutcomes'));
      expect(
        htmlReport.parent.listSync().where(
          (entity) => p.basename(entity.path).startsWith('apply.html.'),
        ),
        isEmpty,
      );
      expect(
        await manager.readRunLifecycleState(Directory(quarantine.path)),
        QuarantineRunLifecycleState.completed,
      );

      final rollbackExitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['rollback', '--project', tempDir.path, quarantine.runId]);

      expect(rollbackExitCode, 0);
      expect(helperFile.readAsStringSync(), original);
      expect(
        await manager.readRunLifecycleState(Directory(quarantine.path)),
        QuarantineRunLifecycleState.rolledBackVerified,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'apply and rollback preserve executable permission bits',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      _chmod(helperFile, 0x1ed);
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      );

      final applyExitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(applyExitCode, 0);
      expect(_posixMode(helperFile), 0x1ed);
      final quarantine = (await QuarantineManager(
        tempDir,
      ).listQuarantines()).single;
      final manager = QuarantineManager(tempDir);
      final quarantineDir = Directory(quarantine.path);
      final manifest = await manager.readManifest(quarantineDir);
      expect(manifest.cases, isNotEmpty);
      expect(
        manifest.cases.map((applyCase) => applyCase.entry.posixMode),
        everyElement(0x1ed),
      );
      final promoted = await manager.promotedBackupForCase(
        quarantineDir: quarantineDir,
        caseId: manifest.cases.first.caseId,
      );
      expect(promoted, isNotNull);
      expect(_posixMode(promoted!), 0x1ed);

      final rollbackExitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['rollback', '--project', tempDir.path, quarantine.runId]);

      expect(rollbackExitCode, 0);
      expect(_posixMode(helperFile), 0x1ed);
    },
    skip: Platform.isLinux || Platform.isMacOS
        ? false
        : 'POSIX permission preservation requires chmod.',
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'completed lifecycle is persisted before report becomes terminal',
    () async {
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      String? observedReportStatus;
      QuarantineRunLifecycleState? observedLifecycle;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            lifecycleCompletedHook: (quarantine) async {
              final report =
                  jsonDecode(
                        _latestCommittedCanonicalReport(
                          quarantine,
                        ).readAsStringSync(),
                      )
                      as Map<String, dynamic>;
              observedReportStatus =
                  (report['run'] as Map<String, dynamic>)['status'] as String;
              observedLifecycle = await QuarantineManager(
                tempDir,
              ).readRunLifecycleState(quarantine);
            },
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(exitCode, 0);
      expect(observedReportStatus, 'interrupted');
      expect(observedLifecycle, QuarantineRunLifecycleState.completed);
      final quarantine = Directory(
        (await QuarantineManager(tempDir).listQuarantines()).single.path,
      );
      final finalReport =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((finalReport['run'] as Map)['status'], 'completed');
      final immutableStates =
          Directory(
              p.join(quarantine.path, 'reports', 'objects'),
            ).listSync().whereType<File>().toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      expect(immutableStates.map((file) => p.basename(file.path)), [
        'run-report-000001.json',
        'run-report-000002.json',
      ]);
      expect(
        immutableStates
            .map(
              (file) =>
                  (jsonDecode(file.readAsStringSync()) as Map)['run'] as Map,
            )
            .map((run) => run['status']),
        ['interrupted', 'completed'],
      );
      final commits = _reportCommitsForRun(
        tempDir,
        p.basename(quarantine.path),
      );
      expect(commits.map((commit) => commit.sequence), [1, 2]);
      expect(commits.last.objects.map((object) => object.role), [
        'canonical',
        'export',
      ]);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'verification regression rolls back a same-file SCC atomically',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      const original = '''
void usedFunction() {}

void unusedOne() {}

void unusedTwo() {}

void unusedThree() {}
''';
      helperFile.writeAsStringSync(original);

      final verifier = _QueuedVerificationRunner(tempDir, [
        _verification(passed: true),
        _verification(
          passed: false,
          output:
              'error • Batch failure • lib/src/helper.dart:1:1 • batch_error',
        ),
        _verification(passed: true),
      ]);
      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', tempDir.path]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 3);
      final manager = QuarantineManager(tempDir);
      final quarantines = await manager.listQuarantines();
      final quarantine = Directory(quarantines.single.path);
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.cases.map((item) => item.status), [
        QuarantineCaseStatus.rolledBack,
        QuarantineCaseStatus.rolledBack,
        QuarantineCaseStatus.rolledBack,
      ]);
      final result = helperFile.readAsStringSync();
      for (final applyCase in manifest.cases) {
        expect(result, contains(applyCase.findingId.split('#').last));
      }
      expect(manifest.transactions, hasLength(1));
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.rolledBackVerified,
      );
      expect(manifest.transactions.single.rollbackVerified, isTrue);
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      final outcomes = (report['apply'] as Map)['findingOutcomes'] as List;
      expect(outcomes, hasLength(3));
      expect(
        outcomes.map((item) => (item as Map)['status']),
        everyElement('rejectedRecovered'),
      );
      expect(
        outcomes.map((item) => (item as Map)['reasonCode']),
        everyElement('verification_regression'),
      );
      expect(
        outcomes.map((item) => (item as Map)['rollbackVerified']),
        everyElement(isTrue),
      );
      expect(
        outcomes.map((item) => (item as Map)['transactionId']),
        everyElement(manifest.transactions.single.transactionId),
      );

      await manager.restore(
        quarantineDir: quarantine,
        runId: quarantines.single.runId,
      );
      expect(helperFile.readAsStringSync(), original);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'rejected wave restores both consumer and dependency transactions',
    () async {
      File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      ).writeAsStringSync('void usedFunction() {}\n');
      final consumer = File(p.join(tempDir.path, 'lib', 'src', 'consumer.dart'))
        ..writeAsStringSync('''
import 'dependency.dart';

void unusedConsumer() {
  unusedDependency();
}
''');
      final dependency = File(
        p.join(tempDir.path, 'lib', 'src', 'dependency.dart'),
      )..writeAsStringSync('void unusedDependency() {}\n');
      final consumerBytes = consumer.readAsBytesSync();
      final dependencyBytes = dependency.readAsBytesSync();
      final verifier = _QueuedVerificationRunner(tempDir, [
        _verification(passed: true),
        _verification(passed: false, output: 'error • consumer regression'),
        _verification(passed: true),
      ]);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 2);
      expect(consumer.readAsBytesSync(), consumerBytes);
      expect(dependency.readAsBytesSync(), dependencyBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.transactions, hasLength(2));
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      final apply = report['apply'] as Map;
      expect((apply['findings'] as Map)['rejectedRecovered'], 2);
      expect((apply['findings'] as Map)['skippedDependency'], 0);
      final outcomes = (apply['findingOutcomes'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        outcomes.map((outcome) => outcome['status']),
        everyElement('rejectedRecovered'),
      );
      expect(
        outcomes.map((outcome) => outcome['rollbackVerified']),
        everyElement(isTrue),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'unsupported sibling variables stay REVIEW while independent actions apply',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      helperFile.writeAsStringSync('''
void usedFunction() {}

const unusedOne = 1, unusedTwo = 2;

void removableUnused() {}
''');
      final independentFile = File(
        p.join(tempDir.path, 'lib', 'src', 'independent.dart'),
      )..writeAsStringSync('void independentlyUnused() {}\n');

      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', tempDir.path]);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 2);
      final result = helperFile.readAsStringSync();
      expect(result, contains('unusedOne = 1, unusedTwo = 2'));
      expect(result, isNot(contains('removableUnused')));
      expect(independentFile.existsSync(), isFalse);

      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(
        manifest.cases.map((item) => item.status),
        everyElement(QuarantineCaseStatus.kept),
      );
      expect(manifest.transactions, hasLength(2));
      expect(
        manifest.transactions.map((item) => item.status),
        everyElement(QuarantineTransactionStatus.committed),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('combined transaction wave regression restores every member', () async {
    final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    helperFile.writeAsStringSync('''
void usedFunction() {}

const unsupportedOne = 1, unsupportedTwo = 2;

void removableUnused() {}
''');
    final independentFile = File(
      p.join(tempDir.path, 'lib', 'src', 'independent.dart'),
    )..writeAsStringSync('void independentlyUnused() {}\n');
    final helperBytes = helperFile.readAsBytesSync();
    final independentBytes = independentFile.readAsBytesSync();
    const originalDiagnostic =
        'error • Existing baseline • lib/src/helper.dart:1:1 • baseline_error';
    final verifier = _QueuedVerificationRunner(tempDir, [
      _verification(passed: false, output: originalDiagnostic),
      _verification(passed: false, output: 'error • second transaction'),
      _verification(passed: false, output: originalDiagnostic),
    ]);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'dart', tempDir.path]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 3);
    expect(helperFile.readAsBytesSync(), helperBytes);
    expect(independentFile.readAsBytesSync(), independentBytes);
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.transactions, hasLength(2));
    expect(manifest.fullRollbackVerified, isTrue);
    expect(
      manifest.transactions.map((transaction) => transaction.status),
      everyElement(QuarantineTransactionStatus.rolledBackVerified),
    );
    final report =
        jsonDecode(
              _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
            )
            as Map;
    final apply = report['apply'] as Map;
    expect((apply['transactions'] as Map)['committed'], 0);
    expect((apply['transactions'] as Map)['rolledBackVerified'], 2);
    expect((apply['actions'] as Map)['committed'], 0);
    expect(apply['sourceBytesRemoved'], 0);
    expect(
      (apply['findingOutcomes'] as List).map((item) => (item as Map)['status']),
      everyElement('rejectedRecovered'),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'later transaction apply failure restores every earlier commit',
    () async {
      final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'))
        ..writeAsStringSync('''
void usedFunction() {}

const unsupportedOne = 1, unsupportedTwo = 2;

void removableUnused() {}
''');
      final independentFile = File(
        p.join(tempDir.path, 'lib', 'src', 'independent.dart'),
      )..writeAsStringSync('void independentlyUnused() {}\n');
      final helperBytes = helperFile.readAsBytesSync();
      final independentBytes = independentFile.readAsBytesSync();
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      late _SecondCleanupFails cleanup;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            cleanupRunnerFactory: (projectRoot) {
              cleanup = _SecondCleanupFails(projectRoot.path);
              return cleanup;
            },
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(exitCode, 2);
      expect(cleanup.invocationCount, 2);
      expect(verifier.invocationCount, 2);
      expect(helperFile.readAsBytesSync(), helperBytes);
      expect(independentFile.readAsBytesSync(), independentBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.transactions, hasLength(2));
      expect(
        manifest.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.rolledBackVerified),
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      final apply = report['apply'] as Map;
      expect((apply['transactions'] as Map)['committed'], 0);
      expect((apply['actions'] as Map)['committed'], 0);
      expect(
        (apply['findingOutcomes'] as List).map(
          (item) => (item as Map)['status'],
        ),
        everyElement('rejectedRecovered'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'failed whole-run rollback verification keeps every transaction recovery-required',
    () async {
      final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'))
        ..writeAsStringSync('''
void usedFunction() {}

const unsupportedOne = 1, unsupportedTwo = 2;

void removableUnused() {}
''');
      final independentFile = File(
        p.join(tempDir.path, 'lib', 'src', 'independent.dart'),
      )..writeAsStringSync('void independentlyUnused() {}\n');
      final helperBytes = helperFile.readAsBytesSync();
      final independentBytes = independentFile.readAsBytesSync();
      final verifier = _QueuedVerificationRunner(tempDir, [
        _verification(passed: true),
        _verification(passed: false, output: 'error • second transaction'),
        _verification(passed: false, output: 'error • rollback baseline'),
      ]);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(helperFile.readAsBytesSync(), helperBytes);
      expect(independentFile.readAsBytesSync(), independentBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.fullRollbackVerified, isFalse);
      expect(
        manifest.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.recoveryRequired),
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      final apply = report['apply'] as Map;
      expect((report['run'] as Map)['status'], 'recoveryRequired');
      expect((apply['transactions'] as Map)['committed'], 0);
      expect((apply['transactions'] as Map)['recoveryRequired'], 2);
      expect(
        (apply['findingOutcomes'] as List).map(
          (item) => (item as Map)['status'],
        ),
        everyElement('recoveryRequired'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('verification outage restores every case in the atomic unit', () async {
    final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    helperFile.writeAsStringSync('''
void usedFunction() {}

void unusedOne() {}

void unusedTwo() {}

void unusedThree() {}
''');
    final verifier = _QueuedVerificationRunner(tempDir, [
      _verification(passed: true),
      _unavailableVerification(),
      _verification(passed: true),
    ]);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', tempDir.path]);

    expect(exitCode, 1);
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.cases, hasLength(3));
    expect(
      manifest.cases.map((item) => item.status),
      everyElement(QuarantineCaseStatus.rolledBack),
    );
    expect(manifest.transactions.single.rollbackVerified, isTrue);

    final result = helperFile.readAsStringSync();
    for (final applyCase in manifest.cases) {
      expect(result, contains(applyCase.findingId.split('#').last));
    }
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'failed rollback verification records recovery-required findings',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _QueuedVerificationRunner(tempDir, [
        _verification(passed: true),
        _verification(passed: false, output: 'error • candidate regression'),
        _verification(passed: false, output: 'error • rollback regression'),
      ]);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(helperFile.readAsBytesSync(), originalBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(manifest.transactions.single.rollbackVerified, isFalse);
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      expect((report['run'] as Map)['status'], 'recoveryRequired');
      final outcomes = (report['apply'] as Map)['findingOutcomes'] as List;
      expect(outcomes, hasLength(1));
      final outcome = outcomes.single as Map;
      expect(outcome['status'], 'recoveryRequired');
      expect(outcome['reasonCode'], 'rollback_verification_failed');
      expect(outcome['rollbackVerified'], isFalse);
      expect(outcome['transactionId'], isNotEmpty);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'unexpected candidate verifier failure journals transaction recovery',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _ThrowingCandidateVerificationRunner(tempDir);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 3);
      expect(helperFile.readAsBytesSync(), originalBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.transactions, hasLength(1));
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(manifest.transactions.single.rollbackVerified, isFalse);
      expect(manifest.cases.single.status, QuarantineCaseStatus.applied);

      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      expect((report['run'] as Map)['status'], 'recoveryRequired');
      final apply = report['apply'] as Map;
      final transactions = apply['transactions'] as Map;
      expect(transactions['begun'], 1);
      expect(transactions['recoveryRequired'], 1);
      expect(transactions['nonTerminal'], 0);
      final outcome = (apply['findingOutcomes'] as List).single as Map;
      expect(outcome['status'], 'recoveryRequired');
      expect(outcome['reasonCode'], 'rollback_verification_failed');
      expect(outcome['rollbackVerified'], isFalse);
      expect(
        outcome['transactionId'],
        manifest.transactions.single.transactionId,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'candidate signal never overwrites recovery-required outcome with 130',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _CancelledCandidateAndRecoveryVerificationRunner(
        tempDir,
      );

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 3);
      expect(helperFile.readAsBytesSync(), originalBytes);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      expect((report['run'] as Map)['status'], 'recoveryRequired');
      expect((report['run'] as Map)['exitCode'], 1);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'unconfirmed cleanup termination marks recovery without rollback',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            cleanupRunnerFactory: (projectRoot) =>
                _UnsafeCleanupTermination(projectRoot.path),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 1);
      expect(helperFile.existsSync(), isFalse);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      final promoted = await manager.promotedBackupForCase(
        quarantineDir: quarantine,
        caseId: manifest.cases.single.caseId,
      );
      expect(promoted, isNotNull);
      expect(promoted!.readAsBytesSync(), originalBytes);
      expect(manifest.fullRollbackVerified, isFalse);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(manifest.cases.single.status, QuarantineCaseStatus.backedUp);
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      final outcome =
          ((report['apply'] as Map)['findingOutcomes'] as List).single as Map;
      expect(outcome['status'], 'recoveryRequired');
      expect(outcome['reasonCode'], 'mutation_process_termination_unconfirmed');
      expect(outcome['rollbackVerified'], isFalse);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'confirmed cleanup cancellation bypasses per-case mutation and requires recovery verification',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _CleanupCancellationVerificationRunner(tempDir);
      late _CaseMutationGuardManager quarantineManager;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            cleanupRunnerFactory: (projectRoot) =>
                _ConfirmedCleanupCancellation(projectRoot.path),
            quarantineManagerFactory: (projectRoot) =>
                quarantineManager = _CaseMutationGuardManager(projectRoot),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 2);
      expect(quarantineManager.recordCaseAppliedCalls, 0);
      expect(quarantineManager.rollbackCaseCalls, 0);
      expect(helperFile.readAsBytesSync(), originalBytes);
      final quarantine = Directory(
        (await quarantineManager.listQuarantines()).single.path,
      );
      final manifest = await quarantineManager.readManifest(quarantine);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(
        await quarantineManager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map;
      expect((report['run'] as Map)['status'], 'recoveryRequired');
      expect((report['run'] as Map)['exitCode'], 1);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  for (final cancellation in <({Exception error, String label})>[
    (
      error: const ProcessCancellationConfirmedException(
        ProcessSignal.sigterm,
        4545,
      ),
      label: 'confirmed',
    ),
    (
      error: const ProcessTerminationUnconfirmedException(
        processId: 4646,
        message: 'injected atomic publish termination uncertainty',
        triggerSignal: ProcessSignal.sigint,
      ),
      label: 'unconfirmed',
    ),
  ]) {
    test(
      'atomic publish ${cancellation.label} interruption preserves anchors and blocks recovery mutation',
      () async {
        final helperFile = File(
          p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
        );
        final originalBytes = helperFile.readAsBytesSync();
        final verifier = _AlwaysPassingVerificationRunner(tempDir);
        final publishRunner = _ApplyCancellationAtLink(
          failAt: 3,
          cancellation: cancellation.error,
        );
        late QuarantineManager quarantineManager;
        final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
          ..argParser.addFlag('verbose', negatable: false)
          ..addCommand(
            ApplyCommand(
              verifierFactory: (_) => verifier,
              cleanupRunnerFactory: (root) =>
                  _SuccessfulCleanupRunner(root.path),
              quarantineManagerFactory: (root) =>
                  quarantineManager = QuarantineManager(
                    root,
                    atomicPublishProcessRunner: publishRunner,
                  ),
            ),
          );

        final exitCode = await runner.run([
          'apply',
          '--adapter',
          'dart',
          tempDir.path,
        ]);

        expect(exitCode, 1);
        expect(verifier.invocationCount, 1);
        expect(publishRunner.invocationCount, 3);
        expect(helperFile.existsSync(), isTrue);
        expect(
          helperFile.readAsBytesSync(),
          isNot(orderedEquals(originalBytes)),
        );
        final quarantine = Directory(
          (await quarantineManager.listQuarantines()).single.path,
        );
        final manifest = await quarantineManager.readManifest(quarantine);
        final promoted = await quarantineManager.promotedBackupForCase(
          quarantineDir: quarantine,
          caseId: manifest.cases.single.caseId,
        );
        expect(promoted, isNotNull);
        expect(promoted!.readAsBytesSync(), orderedEquals(originalBytes));
        expect(manifest.fullRollbackVerified, isFalse);
        expect(
          manifest.transactions.single.status,
          QuarantineTransactionStatus.recoveryRequired,
        );
        expect(
          await quarantineManager.readRunLifecycleState(quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  for (final cancellation in <({Exception error, String label})>[
    (
      error: const ProcessCancellationConfirmedException(
        ProcessSignal.sigterm,
        4747,
      ),
      label: 'confirmed',
    ),
    (
      error: const ProcessTerminationUnconfirmedException(
        processId: 4848,
        message: 'injected chmod termination uncertainty',
        triggerSignal: ProcessSignal.sigint,
      ),
      label: 'unconfirmed',
    ),
  ]) {
    test(
      'chmod ${cancellation.label} interruption follows typed whole-run recovery boundary',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final helperFile = File(
          p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
        );
        final originalBytes = helperFile.readAsBytesSync();
        _chmodApplyFixture(helperFile, 0x1ed);
        final permissionRunner = _ApplyCancellationAtPermission(
          failAt: 2,
          cancellation: cancellation.error,
        );
        late final VerificationRunner verifier;
        late final int Function() verifierInvocationCount;
        if (cancellation.error is ProcessCancellationConfirmedException) {
          final concrete = _CleanupCancellationVerificationRunner(tempDir);
          verifier = concrete;
          verifierInvocationCount = () => concrete.invocationCount;
        } else {
          final concrete = _AlwaysPassingVerificationRunner(tempDir);
          verifier = concrete;
          verifierInvocationCount = () => concrete.invocationCount;
        }
        late _ApplyProcessGuardManager quarantineManager;
        final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
          ..argParser.addFlag('verbose', negatable: false)
          ..addCommand(
            ApplyCommand(
              verifierFactory: (_) => verifier,
              cleanupRunnerFactory: (root) =>
                  _SuccessfulCleanupRunner(root.path),
              quarantineManagerFactory: (root) =>
                  quarantineManager = _ApplyProcessGuardManager(
                    root,
                    permissionProcessRunner: permissionRunner,
                  ),
            ),
          );

        final exitCode = await runner.run([
          'apply',
          '--adapter',
          'dart',
          tempDir.path,
        ]);

        expect(exitCode, 1);
        expect(quarantineManager.recordCaseAppliedCalls, 0);
        expect(quarantineManager.rollbackCaseCalls, 0);
        final quarantine = Directory(
          (await quarantineManager.listQuarantines()).single.path,
        );
        final manifest = await quarantineManager.readManifest(quarantine);
        final promoted = await quarantineManager.promotedBackupForCase(
          quarantineDir: quarantine,
          caseId: manifest.cases.single.caseId,
        );
        expect(promoted, isNotNull);
        expect(promoted!.readAsBytesSync(), orderedEquals(originalBytes));
        expect(verifierInvocationCount(), 1);
        expect(permissionRunner.invocationCount, 2);
        expect(helperFile.existsSync(), isFalse);
        expect(
          manifest.transactions.single.status,
          QuarantineTransactionStatus.recoveryRequired,
        );
        expect(
          await quarantineManager.readRunLifecycleState(quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  test(
    'unconfirmed candidate verifier termination never starts rollback',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _UnsafeCandidateVerificationRunner(tempDir);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 2);
      expect(helperFile.readAsBytesSync(), isNot(originalBytes));
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.fullRollbackVerified, isFalse);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(manifest.cases.single.status, QuarantineCaseStatus.applied);
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );

      final secondVerifier = _AlwaysPassingVerificationRunner(tempDir);
      final secondExitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => secondVerifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);
      expect(secondExitCode, 1);
      expect(secondVerifier.invocationCount, 0);
      expect(helperFile.readAsBytesSync(), isNot(originalBytes));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('known invalid report parent is rejected before mutation', () async {
    final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = helperFile.readAsBytesSync();
    final blockedParent = File(p.join(tempDir.path, 'not-a-directory'))
      ..writeAsStringSync('preserve these bytes');
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode =
        await FlutterPrunerCommandRunner(verifierFactory: (_) => verifier).run([
          'apply',
          '--adapter',
          'dart',
          '--report-output',
          p.join(blockedParent.path, 'apply.html'),
          '--report-format',
          'html',
          tempDir.path,
        ]);

    expect(exitCode, 1);
    expect(verifier.invocationCount, 0);
    expect(helperFile.readAsBytesSync(), originalBytes);
    expect(blockedParent.readAsStringSync(), 'preserve these bytes');
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'invalid legacy quarantine blocks before baseline or mutation',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final stale = Directory(
        p.join(tempDir.path, '.flutter_pruner_quarantine', 'stale-run'),
      )..createSync(recursive: true);
      File(p.join(stale.path, 'manifest.json')).writeAsStringSync('{broken');
      final verifier = _AlwaysPassingVerificationRunner(tempDir);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 0);
      expect(helperFile.readAsBytesSync(), originalBytes);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'committed transaction without run completion blocks the next apply',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final manager = QuarantineManager(tempDir);
      final interrupted = await manager.createCaseQuarantine(
        runId: 'interrupted-after-transaction-commit',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-before-process-crash',
        round: 1,
        componentId: 'unit:before-process-crash',
        findingIds: const ['finding-before-process-crash'],
        caseIds: const ['case-before-process-crash'],
      );
      await manager.beginCase(
        quarantineDir: interrupted,
        caseId: 'case-before-process-crash',
        findingId: 'finding-before-process-crash',
        file: helperFile,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-before-process-crash',
      );
      const bytesAfterInterruptedCommit = '''
void usedFunction() {}

void unusedFunction() {}
// committed transaction, process stopped before run completion
''';
      helperFile.writeAsStringSync(bytesAfterInterruptedCommit);
      await manager.recordCaseApplied(
        quarantineDir: interrupted,
        caseId: 'case-before-process-crash',
      );
      await manager.recordTransactionApplied(
        quarantineDir: interrupted,
        transactionId: 'tx-before-process-crash',
        caseIds: const ['case-before-process-crash'],
      );
      await manager.verifyTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-before-process-crash',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-before-process-crash',
      );
      expect(
        await manager.readRunLifecycleState(interrupted),
        QuarantineRunLifecycleState.active,
      );

      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 0);
      expect(helperFile.readAsStringSync(), bytesAfterInterruptedCommit);
      expect(
        await manager.readRunLifecycleState(interrupted),
        QuarantineRunLifecycleState.active,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'edit after analysis during baseline aborts without source mutation',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final userEdit =
          '${helperFile.readAsStringSync()}// user baseline edit\n';
      final verifier = _MutatingBaselineVerificationRunner(
        tempDir,
        helperFile,
        userEdit,
      );

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 1);
      expect(helperFile.readAsStringSync(), userEdit);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'opaque red baseline is rejected before quarantine or mutation',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      File(p.join(tempDir.path, 'flutter_pruner.yaml')).writeAsStringSync('''
verification:
  steps:
    - id: custom-check
      argv: [custom-verifier, check]
''', mode: FileMode.append);
      final verifier = _OpaqueRedThenPassingVerificationRunner(tempDir);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 1);
      expect(verifier.invocationCount, 1);
      expect(helperFile.readAsBytesSync(), originalBytes);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'edit after analysis during acknowledgement aborts before baseline',
    () async {
      _setPackageInternalConfig(tempDir);
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final userEdit = '${helperFile.readAsStringSync()}// user prompt edit\n';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final prompt = _MutatingApplyPrompt(helperFile, userEdit);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
        applyPrompt: prompt,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 0);
      expect(helperFile.readAsStringSync(), userEdit);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'chmod after analysis during acknowledgement aborts before baseline',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      _setPackageInternalConfig(tempDir);
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      _chmod(helperFile, 0x1ed);
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final prompt = _ModeMutatingApplyPrompt(helperFile, 0x1a4);

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
        applyPrompt: prompt,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 2);
      expect(verifier.invocationCount, 0);
      expect(helperFile.readAsBytesSync(), originalBytes);
      expect(_posixMode(helperFile), 0x1a4);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'edit immediately before atomic displacement aborts without overwrite',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      const userEdit = '''
void usedFunction() {}

void editedDuringDisplacement() {}
''';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var injected = false;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) => QuarantineManager(
              projectRoot,
              displacementHook: (context) {
                if (!injected &&
                    context.point ==
                        QuarantineDisplacementPoint.beforeSourceRename) {
                  injected = true;
                  context.source.writeAsStringSync(userEdit, flush: true);
                }
              },
            ),
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        tempDir.path,
      ]);

      expect(exitCode, 1);
      expect(injected, isTrue);
      expect(verifier.invocationCount, 1);
      expect(helperFile.readAsStringSync(), userEdit);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      final recoveryFiles = Directory(
        p.join(quarantine.path, 'recovery', 'displacement'),
      ).listSync(recursive: true).whereType<File>().toList();
      expect(recoveryFiles, hasLength(1));
      expect(recoveryFiles.single.readAsStringSync(), userEdit);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'external export failure is a warning after canonical commit report',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final reportParent = Directory(p.join(tempDir.path, 'late-report-parent'))
        ..createSync();
      final reportPath = p.join(reportParent.path, 'apply.html');
      final verifier = _BlockingReportExportVerificationRunner(
        tempDir,
        reportParent,
      );

      final exitCode =
          await FlutterPrunerCommandRunner(
            verifierFactory: (_) => verifier,
          ).run([
            'apply',
            '--adapter',
            'dart',
            '--report-output',
            reportPath,
            '--report-format',
            'html',
            tempDir.path,
          ]);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 2);
      expect(
        File(reportParent.path).readAsStringSync(),
        'preserve these bytes',
      );
      final manager = QuarantineManager(tempDir);
      final quarantineInfo = (await manager.listQuarantines()).single;
      final quarantine = Directory(quarantineInfo.path);
      final canonical = _latestCommittedCanonicalReport(quarantine);
      final report =
          jsonDecode(canonical.readAsStringSync()) as Map<String, dynamic>;
      final run = report['run'] as Map<String, dynamic>;
      expect(run['status'], 'completed');
      expect(run['exitCode'], 0);
      expect(run['partialApplied'], isFalse);
      final diagnostic = (report['diagnostics'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .singleWhere(
            (item) => item['code'] == 'external_report_export_failed',
          );
      expect(diagnostic['phase'], 'reportExport');
      expect(diagnostic['message'], contains(reportPath));
      final apply = report['apply'] as Map<String, dynamic>;
      expect(((apply['transactions'] as Map<String, dynamic>)['committed']), 1);
      final outcome =
          (apply['findingOutcomes'] as List<dynamic>).single
              as Map<String, dynamic>;
      expect(outcome['status'], 'committed');
      expect(outcome['reasonCode'], 'verification_accepted');

      await manager.restore(
        quarantineDir: quarantine,
        runId: quarantineInfo.runId,
      );
      expect(helperFile.readAsBytesSync(), originalBytes);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'terminal canonical collision is not mislabeled as an export failure',
    () async {
      final reportPath = p.join(tempDir.path, 'reports', 'apply.html');
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            lifecycleCompletedHook: (quarantine) {
              Directory(
                p.join(
                  quarantine.path,
                  'reports',
                  'objects',
                  'run-report-000002.json',
                ),
              ).createSync();
            },
          ),
        );

      final exitCode = await runner.run([
        'apply',
        '--adapter',
        'dart',
        '--report-output',
        reportPath,
        '--report-format',
        'html',
        tempDir.path,
      ]);

      expect(exitCode, 0);
      expect(File(reportPath).existsSync(), isFalse);
      expect(
        File(
          p.join(tempDir.path, 'reports', '.apply.html.commit.json'),
        ).existsSync(),
        isFalse,
      );
      final quarantine = Directory(
        (await QuarantineManager(tempDir).listQuarantines()).single.path,
      );
      final report =
          jsonDecode(
                _latestCommittedCanonicalReport(quarantine).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect((report['run'] as Map<String, dynamic>)['status'], 'completed');
      final diagnosticCodes = (report['diagnostics'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .map((diagnostic) => diagnostic['code']);
      expect(diagnosticCodes, contains('report_batch_persistence_failed'));
      expect(diagnosticCodes, isNot(contains('external_report_export_failed')));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('rescan analyzer failure restores the original run bytes', () async {
    final helperFile = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    final originalBytes = helperFile.readAsBytesSync();
    final verifier = _AlwaysPassingVerificationRunner(tempDir);
    late _ThrowingRescanProjectAnalyzer analyzer;
    final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
      ..argParser.addFlag('verbose', negatable: false)
      ..addCommand(
        ApplyCommand(
          verifierFactory: (_) => verifier,
          analyzerFactory: (project, only) {
            analyzer = _ThrowingRescanProjectAnalyzer(
              project: project,
              only: only,
            );
            return analyzer;
          },
        ),
      );

    final exitCode = await runner.run([
      'apply',
      '--adapter',
      'dart',
      tempDir.path,
    ]);

    expect(exitCode, 70);
    expect(analyzer.invocationCount, 2);
    expect(verifier.invocationCount, 3);
    expect(helperFile.readAsBytesSync(), originalBytes);
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.fullRollbackVerified, isTrue);
    expect(manifest.verificationWaves, hasLength(1));
    expect(
      manifest.transactions.single.status,
      QuarantineTransactionStatus.rolledBackVerified,
    );
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'failure after begin transaction preserves recovery evidence without generic fallback',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final originalMode = helperFile.statSync().mode & 0xfff;
      final reportFile = File(
        p.join(tempDir.path, 'begin-transaction-failure.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      late _ThrowAfterBeginTransactionQuarantineManager manager;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) {
              manager = _ThrowAfterBeginTransactionQuarantineManager(
                projectRoot,
              );
              return manager;
            },
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        'dart:apply_test/lib/src/helper.dart#unusedFunction',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 70);
      expect(manager.beginCalls, 1);
      expect(helperFile.readAsBytesSync(), orderedEquals(originalBytes));
      expect(helperFile.statSync().mode & 0xfff, originalMode);
      expect(reportFile.existsSync(), isTrue);
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final run = report['run'] as Map<String, dynamic>;
      expect(run['status'], 'internalError');
      expect(run['exitCode'], 70);
      expect(
        (report['diagnostics'] as List).cast<Map<String, dynamic>>().map(
          (diagnostic) => diagnostic['code'],
        ),
        isNot(contains('apply_pre_transaction_failed')),
      );
      final quarantine = Directory(
        (report['quarantine'] as Map<String, dynamic>)['path'] as String,
      );
      expect(quarantine.existsSync(), isTrue);
      expect(
        quarantine.resolveSymbolicLinksSync(),
        startsWith(
          '${Directory(p.join(tempDir.path, '.flutter_pruner', 'quarantine')).resolveSymbolicLinksSync()}${p.separator}',
        ),
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.fullRollbackVerified, isTrue);
      expect(manifest.transactions, hasLength(1));
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.rolledBackVerified,
      );
      final commits = _reportCommitsForRun(tempDir, manifest.runId);
      expect(commits, hasLength(1));
      expect(commits.single.sequence, 1);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'final convergence analyzer failure persists internal-error report',
    () async {
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final originalBytes = helperFile.readAsBytesSync();
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      late _ThrowingFinalProjectAnalyzer analyzer;
      final capturedStdout = _RecordingStdout();
      final capturedStderr = _RecordingStdout();
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) {
              analyzer = _ThrowingFinalProjectAnalyzer(
                project: project,
                only: only,
              );
              return analyzer;
            },
          ),
        );

      final exitCode = await IOOverrides.runZoned(
        () => runner.run(['apply', '--adapter', 'dart', tempDir.path]),
        stdout: () => capturedStdout,
        stderr: () => capturedStderr,
      );
      await capturedStdout.close();
      await capturedStderr.close();

      expect(exitCode, 70);
      expect(analyzer.invocationCount, 3);
      expect(verifier.invocationCount, 3);
      expect(helperFile.readAsBytesSync(), originalBytes);
      expect(capturedStdout.text, contains('APPLY INTERNAL ERROR'));
      expect(capturedStdout.text, contains('REVERSIBILITY'));
      expect(
        capturedStdout.text,
        contains("flutter_pruner 'rollback' '--project'"),
      );
      expect(capturedStdout.text, isNot(contains('APPLY COMPLETED')));
      expect(capturedStderr.text, contains('APPLY FAILED'));
      final manager = QuarantineManager(tempDir);
      final quarantine = (await manager.listQuarantines()).single;
      final canonical = _latestCommittedCanonicalReport(
        Directory(quarantine.path),
      );
      expect(canonical.existsSync(), isTrue);
      final report =
          jsonDecode(canonical.readAsStringSync()) as Map<String, dynamic>;
      final run = report['run'] as Map<String, dynamic>;
      expect(run['status'], 'internalError');
      expect(run['exitCode'], 70);
      expect(run['partialApplied'], isFalse);
      expect(
        Directory(
          (report['quarantine'] as Map)['path'] as String,
        ).resolveSymbolicLinksSync(),
        Directory(quarantine.path).resolveSymbolicLinksSync(),
      );
      final apply = report['apply'] as Map;
      expect((apply['transactions'] as Map)['committed'], 0);
      expect((apply['transactions'] as Map)['rolledBackVerified'], 1);
      final outcome = (apply['findingOutcomes'] as List).single as Map;
      expect(outcome['status'], 'rejectedRecovered');
      expect(outcome['reasonCode'], 'whole_run_internal_error');
      expect(outcome['rollbackVerified'], isTrue);
      final manifest = await manager.readManifest(Directory(quarantine.path));
      expect(manifest.fullRollbackVerified, isTrue);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.rolledBackVerified,
      );
      final rollbackCommand = _wrappedCommandContaining(
        capturedStdout.text,
        "flutter_pruner 'rollback'",
      );
      expect(rollbackCommand, contains('--quarantine'));
      expect(rollbackCommand, contains(quarantine.runId));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'canonical report write failure still prints truthful rollback summary',
    () async {
      final config = File(p.join(tempDir.path, 'flutter_pruner.yaml'));
      config.writeAsStringSync(
        '${config.readAsStringSync()}${_canonicalReportFailureVerificationPolicy()}',
      );
      final helperFile = File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      );
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'apply',
          '--project',
          tempDir.path,
          '--adapter',
          'dart',
        ],
        workingDirectory: Directory.current.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      expect(result.exitCode, 70);
      expect(helperFile.readAsStringSync(), contains('unusedFunction'));
      final output = result.stdout as String;
      expect(output, contains('APPLY INTERNAL ERROR'));
      expect(output, contains('REVERSIBILITY'));
      expect(output, contains("flutter_pruner 'rollback' '--project'"));
      expect(output, isNot(contains('APPLY COMPLETED')));
      expect(output, contains('HTML REPORT READY'));
      final errorOutput = result.stderr as String;
      expect(errorOutput, contains('REPORT NOT SAVED'));
      expect(
        _withoutTerminalFormatting(errorOutput),
        contains('phase=createObject'),
      );

      final manager = QuarantineManager(tempDir);
      final quarantine = (await manager.listQuarantines()).single;
      expect(
        Directory(
          p.join(
            quarantine.path,
            'reports',
            'objects',
            'run-report-000001.json',
          ),
        ).existsSync(),
        isTrue,
      );
      final manifest = await manager.readManifest(Directory(quarantine.path));
      expect(
        manifest.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.rolledBackVerified),
      );
      expect(output, contains(quarantine.runId));
      final rollbackCommand = _wrappedCommandContaining(
        output,
        "flutter_pruner 'rollback'",
      );
      expect(rollbackCommand, contains('--quarantine'));
      expect(rollbackCommand, contains(quarantine.runId));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'matching preview authorizes canonicalized exact batch and survives rollback',
    () async {
      final first = File(p.join(tempDir.path, 'lib', 'src', 'first.dart'));
      const firstOriginal = '''
void keepFirst() {}

void selectedFirst() {}
''';
      first.writeAsStringSync(firstOriginal);
      final second = File(p.join(tempDir.path, 'lib', 'src', 'second.dart'));
      const secondOriginal = '''
void keepSecond() {}

void selectedSecond() {}
''';
      second.writeAsStringSync(secondOriginal);
      File(p.join(tempDir.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'src/first.dart';
import 'src/second.dart';

void main() {
  keepFirst();
  keepSecond();
}
''');
      const firstId = 'dart:apply_test/lib/src/first.dart#selectedFirst';
      const secondId = 'dart:apply_test/lib/src/second.dart#selectedSecond';
      final previewReport = File(
        p.join(tempDir.path, 'bound-preview-dry-run.json'),
      );
      final applyReport = File(
        p.join(tempDir.path, 'bound-preview-apply.json'),
      );

      final previewRun = await _runApplyCaptured(FlutterPrunerCommandRunner(), [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        secondId,
        '--finding-id',
        firstId,
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        previewReport.path,
        tempDir.path,
      ]);
      expect(previewRun.exitCode, 0, reason: previewRun.stderr);
      final previewJson =
          jsonDecode(previewReport.readAsStringSync()) as Map<String, dynamic>;
      final previewSelection =
          ((previewJson['apply'] as Map)['selection'] as Map<String, dynamic>);
      final expected = previewSelection['actualPreviewFingerprint'] as String;
      final verifier = _AlwaysPassingVerificationRunner(tempDir);

      final applyRun = await _runApplyCaptured(
        FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
        [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          firstId,
          '--finding-id',
          secondId,
          '--expect-preview-fingerprint',
          expected,
          '--report-format',
          'json',
          '--report-output',
          applyReport.path,
          tempDir.path,
        ],
      );

      expect(applyRun.exitCode, 0, reason: applyRun.stderr);
      expect(verifier.invocationCount, 2);
      expect(first.readAsStringSync(), isNot(contains('selectedFirst')));
      expect(second.readAsStringSync(), isNot(contains('selectedSecond')));
      final applyJson =
          jsonDecode(applyReport.readAsStringSync()) as Map<String, dynamic>;
      final selection =
          ((applyJson['apply'] as Map)['selection'] as Map<String, dynamic>);
      expect(selection['requestedFindingIds'], [firstId, secondId]);
      expect(selection['actualPreviewFingerprint'], expected);
      expect(selection['expectedPreviewFingerprint'], expected);
      expect(selection['previewComparison'], 'matched');

      final manager = QuarantineManager(tempDir);
      final quarantineInfo = (await manager.listQuarantines()).single;
      final quarantine = Directory(quarantineInfo.path);
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.selection?.toJson()['version'], 2);
      expect(manifest.selection?.requestedFindingIds, [firstId, secondId]);
      expect(manifest.selection?.previewFingerprintVersion, 1);
      expect(manifest.selection?.previewFingerprint, expected);
      expect(manifest.selection?.expectedPreviewFingerprint, expected);

      expect(
        await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', tempDir.path, quarantineInfo.runId]),
        0,
      );
      expect(first.readAsStringSync(), firstOriginal);
      expect(second.readAsStringSync(), secondOriginal);
      final rolledBack = await manager.readManifest(quarantine);
      expect(rolledBack.selection?.previewFingerprint, expected);
      expect(rolledBack.selection?.expectedPreviewFingerprint, expected);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  for (final drift in _ExpectedPreviewDrift.values) {
    test(
      'preview mismatch from ${drift.name} safe-stops before baseline or journal',
      () async {
        final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
        const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
        final expected = await _captureExactPreviewFingerprint(
          project: tempDir,
          findingIds: const [findingId],
          reportFile: File(p.join(tempDir.path, 'preview-${drift.name}.json')),
        );
        switch (drift) {
          case _ExpectedPreviewDrift.bytes:
            source.writeAsStringSync(
              '${source.readAsStringSync()}// external byte drift\n',
              flush: true,
            );
          case _ExpectedPreviewDrift.posixMode:
            _chmod(
              source,
              (source.statSync().mode & 0xfff) == 0x1a4 ? 0x180 : 0x1a4,
            );
        }
        final beforeBytes = source.readAsBytesSync();
        final beforeMode = source.statSync().mode & 0xfff;
        final verifier = _AlwaysPassingVerificationRunner(tempDir);
        var quarantineFactories = 0;
        final reportFile = File(
          p.join(tempDir.path, 'mismatch-${drift.name}.json'),
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
          ..argParser.addFlag('verbose', negatable: false)
          ..addCommand(
            ApplyCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: (projectRoot) {
                quarantineFactories++;
                return QuarantineManager(projectRoot);
              },
            ),
          );

        final result = await _runApplyCaptured(runner, [
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          findingId,
          '--expect-preview-fingerprint',
          expected,
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

        expect(result.exitCode, 2, reason: result.stderr);
        expect(verifier.invocationCount, 0);
        expect(quarantineFactories, 0);
        expect(source.readAsBytesSync(), orderedEquals(beforeBytes));
        expect(source.statSync().mode & 0xfff, beforeMode);
        expect(
          Directory(
            p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
          ).existsSync(),
          isFalse,
        );
        _expectPreviewFingerprintMismatchReport(
          reportFile,
          expected: expected,
          findingIds: const [findingId],
        );
      },
      skip:
          drift == _ExpectedPreviewDrift.posixMode &&
              !(Platform.isLinux || Platform.isMacOS)
          ? 'POSIX mode evidence is unavailable on this platform.'
          : false,
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  test(
    'preview mismatch binds the canonical project root before baseline',
    () async {
      const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
      final expected = await _captureExactPreviewFingerprint(
        project: tempDir,
        findingIds: const [findingId],
        reportFile: File(p.join(tempDir.path, 'preview-canonical-root.json')),
      );
      final equivalent = Directory.systemTemp.createTempSync(
        'apply_preview_canonical_root_',
      );
      addTearDown(() {
        if (equivalent.existsSync()) equivalent.deleteSync(recursive: true);
      });
      _writeEquivalentApplyProject(equivalent);
      final source = File(p.join(equivalent.path, 'lib', 'src', 'helper.dart'));
      final beforeBytes = source.readAsBytesSync();
      final beforeMode = source.statSync().mode & 0xfff;
      final verifier = _AlwaysPassingVerificationRunner(equivalent);
      var quarantineFactories = 0;
      final reportFile = File(
        p.join(equivalent.path, 'mismatch-canonical-root.json'),
      );
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) {
              quarantineFactories++;
              return QuarantineManager(projectRoot);
            },
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        findingId,
        '--expect-preview-fingerprint',
        expected,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        equivalent.path,
      ]);

      expect(result.exitCode, 2, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(quarantineFactories, 0);
      expect(source.readAsBytesSync(), orderedEquals(beforeBytes));
      expect(source.statSync().mode & 0xfff, beforeMode);
      _expectPreviewFingerprintMismatchReport(
        reportFile,
        expected: expected,
        findingIds: const [findingId],
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'preview mismatch binds exact selector identity before baseline',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      source.writeAsStringSync('''
void usedFunction() {}

void firstUnused() {}

void secondUnused() {}
''');
      const firstId = 'dart:apply_test/lib/src/helper.dart#firstUnused';
      const secondId = 'dart:apply_test/lib/src/helper.dart#secondUnused';
      final expected = await _captureExactPreviewFingerprint(
        project: tempDir,
        findingIds: const [firstId],
        reportFile: File(p.join(tempDir.path, 'preview-selector.json')),
      );
      final beforeBytes = source.readAsBytesSync();
      final beforeMode = source.statSync().mode & 0xfff;
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var quarantineFactories = 0;
      final reportFile = File(p.join(tempDir.path, 'mismatch-selector.json'));
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) {
              quarantineFactories++;
              return QuarantineManager(projectRoot);
            },
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        secondId,
        '--expect-preview-fingerprint',
        expected,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 2, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(quarantineFactories, 0);
      expect(source.readAsBytesSync(), orderedEquals(beforeBytes));
      expect(source.statSync().mode & 0xfff, beforeMode);
      _expectPreviewFingerprintMismatchReport(
        reportFile,
        expected: expected,
        findingIds: const [secondId],
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'preview mismatch binds physical action membership before baseline',
    () async {
      final asset = File(p.join(tempDir.path, 'assets', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('primary asset bytes\n');
      final variant = File(p.join(tempDir.path, 'assets', '2.0x', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('variant asset bytes\n');
      const findingId = 'asset:apply_test/assets/canary.txt';
      final previewReport = File(
        p.join(tempDir.path, 'preview-action-membership.json'),
      );
      final previewRunner =
          args.CommandRunner<int>('flutter_pruner', 'test runner')
            ..argParser.addFlag('verbose', negatable: false)
            ..addCommand(
              ApplyCommand(
                analyzerFactory: (project, only) => _LateVariantProjectAnalyzer(
                  project: project,
                  only: only,
                  findingId: findingId,
                  assetPath: asset.path,
                  variantPath: variant.path,
                ),
              ),
            );
      final expected = await _captureExactPreviewFingerprint(
        project: tempDir,
        findingIds: const [findingId],
        reportFile: previewReport,
        runner: previewRunner,
      );
      final before = {
        for (final file in [asset, variant])
          file.path: (
            bytes: file.readAsBytesSync(),
            mode: file.statSync().mode & 0xfff,
          ),
      };
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var quarantineFactories = 0;
      final reportFile = File(
        p.join(tempDir.path, 'mismatch-action-membership.json'),
      );
      final applyRunner =
          args.CommandRunner<int>('flutter_pruner', 'test runner')
            ..argParser.addFlag('verbose', negatable: false)
            ..addCommand(
              ApplyCommand(
                verifierFactory: (_) => verifier,
                analyzerFactory: (project, only) => _LateVariantProjectAnalyzer(
                  project: project,
                  only: only,
                  findingId: findingId,
                  assetPath: asset.path,
                  variantPath: null,
                ),
                quarantineManagerFactory: (projectRoot) {
                  quarantineFactories++;
                  return QuarantineManager(projectRoot);
                },
              ),
            );

      final result = await _runApplyCaptured(applyRunner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        findingId,
        '--expect-preview-fingerprint',
        expected,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 2, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(quarantineFactories, 0);
      for (final file in [asset, variant]) {
        expect(file.readAsBytesSync(), orderedEquals(before[file.path]!.bytes));
        expect(file.statSync().mode & 0xfff, before[file.path]!.mode);
      }
      _expectPreviewFingerprintMismatchReport(
        reportFile,
        expected: expected,
        findingIds: const [findingId],
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'preview expectation treats an empty current exact plan as mismatch',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      source.writeAsStringSync('''
void usedFunction() {}

void unusedConsumer() {
  unusedDependency();
}

void unusedDependency() {}
''');
      const dependencyId =
          'dart:apply_test/lib/src/helper.dart#unusedDependency';
      final beforeBytes = source.readAsBytesSync();
      final beforeMode = source.statSync().mode & 0xfff;
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var quarantineFactories = 0;
      final bootstrapReportFile = File(
        p.join(tempDir.path, 'mismatch-empty-plan-bootstrap.json'),
      );
      final reportFile = File(p.join(tempDir.path, 'mismatch-empty-plan.json'));
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            quarantineManagerFactory: (projectRoot) {
              quarantineFactories++;
              return QuarantineManager(projectRoot);
            },
          ),
        );

      final bootstrapResult = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        dependencyId,
        '--expect-preview-fingerprint',
        'v1:${'0' * 64}',
        '--report-format',
        'json',
        '--report-output',
        bootstrapReportFile.path,
        tempDir.path,
      ]);
      expect(bootstrapResult.exitCode, 2, reason: bootstrapResult.stderr);
      final bootstrapReport = _expectPreviewFingerprintMismatchReport(
        bootstrapReportFile,
        expected: 'v1:${'0' * 64}',
        findingIds: const [dependencyId],
      );
      final expected =
          (((bootstrapReport['apply'] as Map)['selection']
                  as Map<String, dynamic>)['actualPreviewFingerprint']
              as String);

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        dependencyId,
        '--expect-preview-fingerprint',
        expected,
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 2, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(quarantineFactories, 0);
      expect(source.readAsBytesSync(), orderedEquals(beforeBytes));
      expect(source.statSync().mode & 0xfff, beforeMode);
      final report = _expectPreviewFingerprintMismatchReport(
        reportFile,
        expected: expected,
        findingIds: const [dependencyId],
        equalTokens: true,
      );
      final initialPlan =
          ((report['apply'] as Map)['initialPlan'] as Map<String, dynamic>);
      expect(initialPlan['units'], isEmpty);
      expect(initialPlan['planFingerprint'], isNull);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'dry-run snapshots every physical action source without side effects',
    () async {
      final asset = File(p.join(tempDir.path, 'assets', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('primary asset bytes\n');
      final variant = File(p.join(tempDir.path, 'assets', '2.0x', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('variant asset bytes\n');
      final before = {
        for (final file in [asset, variant])
          file.path: (
            bytes: file.readAsBytesSync(),
            mode: file.statSync().mode & 0xfff,
          ),
      };
      const findingId = 'asset:apply_test/assets/canary.txt';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-initial-plan.json'),
      );
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) => _LateVariantProjectAnalyzer(
              project: project,
              only: only,
              findingId: findingId,
              assetPath: asset.path,
              variantPath: variant.path,
            ),
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      for (final file in [asset, variant]) {
        expect(file.readAsBytesSync(), orderedEquals(before[file.path]!.bytes));
        expect(file.statSync().mode & 0xfff, before[file.path]!.mode);
      }

      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final apply = report['apply'] as Map<String, dynamic>;
      final selection = apply['selection'] as Map<String, dynamic>;
      final initialPlan = apply['initialPlan'] as Map<String, dynamic>;
      final preview = initialPlan['preview'] as Map<String, dynamic>;
      final units = (initialPlan['units'] as List).cast<Map<String, dynamic>>();
      final actions = units
          .expand(
            (unit) => (unit['actions'] as List).cast<Map<String, dynamic>>(),
          )
          .toList(growable: false);
      final sources = (preview['sources'] as List).cast<Map<String, dynamic>>();

      expect((report['run'] as Map)['status'], 'dryRun');
      expect(initialPlan['scope'], 'initial_round_only');
      expect(actions, hasLength(2));
      expect(actions.map((action) => action['projectRelativePath']), [
        'assets/2.0x/canary.txt',
        'assets/canary.txt',
      ]);
      expect(sources, hasLength(2));
      expect(sources.map((source) => source['projectRelativePath']), [
        'assets/2.0x/canary.txt',
        'assets/canary.txt',
      ]);
      for (final source in sources) {
        final file = File(
          p.join(tempDir.path, source['projectRelativePath'] as String),
        );
        expect(source['canonicalPath'], file.resolveSymbolicLinksSync());
        expect(
          source['sha256'],
          sha256.convert(file.readAsBytesSync()).toString(),
        );
        expect(source['sizeBytes'], file.lengthSync());
        expect(
          source['posixMode'],
          Platform.isLinux || Platform.isMacOS
              ? file.statSync().mode & 0xfff
              : isNull,
        );
      }
      expect(selection['actualPreviewFingerprint'], preview['fingerprint']);
      expect(selection['previewComparison'], 'notRequested');
      expect((apply['actions'] as Map)['declared'], 0);
      expect(apply['verificationAttempts'], 0);
      expect(report['verificationAttempts'], isEmpty);
      final terminalOutput = result.stdout;
      expect(terminalOutput, contains('INITIAL PHYSICAL PLAN'));
      expect(terminalOutput, contains('assets/2.0x/canary.txt'));
      expect(terminalOutput, contains('assets/canary.txt'));
      expect(
        terminalOutput.indexOf('INITIAL PHYSICAL PLAN'),
        lessThan(terminalOutput.indexOf('OUTCOMES')),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'exact dry-run accepts a zero-byte source as complete preview evidence',
    () async {
      final emptySource = File(p.join(tempDir.path, 'lib', 'src', 'empty.dart'))
        ..writeAsBytesSync(const []);
      final originalMode = emptySource.statSync().mode & 0xfff;
      const findingId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final reportFile = File(p.join(tempDir.path, 'dry-run-zero-byte.json'));
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) =>
                _RemappedActionSourceProjectAnalyzer(
                  project: project,
                  only: only,
                  sourcePath: emptySource.path,
                ),
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--finding-id',
        findingId,
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 0, reason: result.stderr);
      expect(verifier.invocationCount, 0);
      expect(emptySource.readAsBytesSync(), isEmpty);
      expect(emptySource.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final apply = report['apply'] as Map<String, dynamic>;
      final selection = apply['selection'] as Map<String, dynamic>;
      final initialPlan = apply['initialPlan'] as Map<String, dynamic>;
      final preview = initialPlan['preview'] as Map<String, dynamic>;
      final source = ((preview['sources'] as List).single as Map);
      expect(initialPlan['scope'], 'complete_exact_selection');
      expect(source['projectRelativePath'], 'lib/src/empty.dart');
      expect(source['sizeBytes'], 0);
      expect(source['sha256'], sha256.convert(const <int>[]).toString());
      expect(selection['actualPreviewFingerprint'], preview['fingerprint']);
      expect((apply['actions'] as Map)['declared'], 0);
      expect(report['verificationAttempts'], isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  for (final kind in _UnsafePlannedSourceKind.values) {
    test(
      'dry-run rejects ${kind.name} planned source before verifier or quarantine',
      () async {
        if (kind == _UnsafePlannedSourceKind.symlink && Platform.isWindows) {
          return;
        }
        final helper = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
        final helperBytes = helper.readAsBytesSync();
        late final String sourcePath;
        Directory? externalDirectory;
        File? retainedTarget;
        Link? retainedLink;
        Directory? retainedDirectory;
        void Function()? afterAnalysisHook;
        switch (kind) {
          case _UnsafePlannedSourceKind.symlink:
            retainedTarget = File(
              p.join(tempDir.path, 'planned-link-target.bin'),
            )..writeAsStringSync('retained symlink target\n');
            retainedLink = Link(
              p.join(tempDir.path, 'lib', 'src', 'planned-link.dart'),
            );
            afterAnalysisHook = () =>
                retainedLink!.createSync(retainedTarget!.path);
            sourcePath = retainedLink.path;
          case _UnsafePlannedSourceKind.outOfRoot:
            externalDirectory = Directory.systemTemp.createTempSync(
              'apply_outside_preview_',
            );
            addTearDown(() {
              if (externalDirectory!.existsSync()) {
                externalDirectory.deleteSync(recursive: true);
              }
            });
            retainedTarget = File(
              p.join(externalDirectory.path, 'outside.dart'),
            )..writeAsStringSync('retained outside bytes\n');
            sourcePath = retainedTarget.path;
          case _UnsafePlannedSourceKind.nonRegular:
            retainedDirectory = Directory(
              p.join(tempDir.path, 'lib', 'src', 'planned-directory.dart'),
            );
            afterAnalysisHook = retainedDirectory.createSync;
            sourcePath = retainedDirectory.path;
        }
        final targetBytes = retainedTarget?.readAsBytesSync();
        final targetMode = retainedTarget?.statSync().mode;
        final reportFile = File(
          p.join(tempDir.path, 'dry-run-${kind.name}.json'),
        );
        final verifier = _AlwaysPassingVerificationRunner(tempDir);
        final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
          ..argParser.addFlag('verbose', negatable: false)
          ..addCommand(
            ApplyCommand(
              verifierFactory: (_) => verifier,
              analyzerFactory: (project, only) =>
                  _RemappedActionSourceProjectAnalyzer(
                    project: project,
                    only: only,
                    sourcePath: sourcePath,
                    afterAnalysisHook: afterAnalysisHook,
                  ),
            ),
          );

        final result = await _runApplyCaptured(runner, [
          'apply',
          '--adapter',
          'dart',
          '--dry-run',
          '--report-format',
          'json',
          '--report-output',
          reportFile.path,
          tempDir.path,
        ]);

        expect(result.exitCode, 2, reason: result.stderr);
        expect(verifier.invocationCount, 0);
        expect(helper.readAsBytesSync(), orderedEquals(helperBytes));
        expect(
          Directory(
            p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
          ).existsSync(),
          isFalse,
        );
        if (retainedTarget != null) {
          expect(retainedTarget.readAsBytesSync(), orderedEquals(targetBytes!));
          expect(retainedTarget.statSync().mode, targetMode);
        }
        if (retainedLink != null) {
          expect(
            FileSystemEntity.typeSync(retainedLink.path, followLinks: false),
            FileSystemEntityType.link,
          );
          expect(retainedLink.targetSync(), retainedTarget!.path);
        }
        expect(retainedDirectory?.existsSync() ?? true, isTrue);
        expect(reportFile.existsSync(), isTrue);
        final report =
            jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
        final apply = report['apply'] as Map<String, dynamic>;
        expect((report['run'] as Map)['status'], 'safeStopped');
        expect((report['run'] as Map)['exitCode'], 2);
        expect((apply['actions'] as Map)['declared'], 0);
        expect(apply['verificationAttempts'], 0);
        expect(report['verificationAttempts'], isEmpty);
        expect(
          (report['diagnostics'] as List).cast<Map<String, dynamic>>().map(
            (diagnostic) => diagnostic['code'],
          ),
          contains('analysis_snapshot_stale'),
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  test(
    'dry-run double-read rejects source drift after the first capture read',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final originalBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      final externalEdit = <int>[
        ...originalBytes,
        ...utf8.encode('// drift\n'),
      ];
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-double-read-drift.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var hookInvocations = 0;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            sourceSnapshotFirstReadHookForTesting: (captured) {
              if (p.normalize(captured.path) != p.normalize(source.path)) {
                return;
              }
              hookInvocations++;
              source.writeAsBytesSync(externalEdit, flush: true);
            },
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      expect(result.exitCode, 2, reason: result.stderr);
      expect(hookInvocations, 1);
      expect(verifier.invocationCount, 0);
      expect(source.readAsBytesSync(), orderedEquals(externalEdit));
      expect(source.statSync().mode & 0xfff, originalMode);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
      expect(reportFile.existsSync(), isTrue);
      final report =
          jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
      final apply = report['apply'] as Map<String, dynamic>;
      expect((report['run'] as Map)['status'], 'safeStopped');
      expect((report['run'] as Map)['exitCode'], 2);
      expect((apply['actions'] as Map)['declared'], 0);
      expect(apply['verificationAttempts'], 0);
      expect(report['verificationAttempts'], isEmpty);
      expect(
        (report['diagnostics'] as List)
            .cast<Map<String, dynamic>>()
            .singleWhere(
              (diagnostic) => diagnostic['code'] == 'analysis_snapshot_stale',
            )['message'],
        contains('changed while the analysis snapshot was captured'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'dry-run rejects an in-root intermediate symlink before side effects',
    () async {
      if (Platform.isWindows) return;
      final target = File(p.join(tempDir.path, 'preview-target', 'source.bin'))
        ..createSync(recursive: true)
        ..writeAsStringSync('retained intermediate-link target\n');
      final targetBytes = target.readAsBytesSync();
      final targetMode = target.statSync().mode & 0xfff;
      final alias = Link(p.join(tempDir.path, 'preview-source-alias'));
      final sourcePath = p.join(alias.path, p.basename(target.path));
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-intermediate-symlink.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) =>
                _RemappedActionSourceProjectAnalyzer(
                  project: project,
                  only: only,
                  sourcePath: sourcePath,
                  afterAnalysisHook: () => alias.createSync(target.parent.path),
                ),
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      final report = _expectPreviewValidationSafeStop(
        result: result,
        verifier: verifier,
        reportFile: reportFile,
        projectRoot: tempDir,
      );
      expect(target.readAsBytesSync(), orderedEquals(targetBytes));
      expect(target.statSync().mode & 0xfff, targetMode);
      expect(
        FileSystemEntity.typeSync(alias.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        _previewValidationDiagnostic(report)['message'],
        contains('relative and canonical paths identify different files'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'dry-run rejects duplicate lexical aliases of one canonical source',
    () async {
      if (Platform.isWindows) return;
      final asset = File(p.join(tempDir.path, 'assets', 'canary.txt'))
        ..createSync(recursive: true)
        ..writeAsStringSync('retained aliased asset bytes\n');
      final assetBytes = asset.readAsBytesSync();
      final assetMode = asset.statSync().mode & 0xfff;
      final alias = Link(p.join(tempDir.path, 'assets-alias'));
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-duplicate-canonical-alias.json'),
      );
      const findingId = 'asset:apply_test/assets/canary.txt';
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) => _LateVariantProjectAnalyzer(
              project: project,
              only: only,
              findingId: findingId,
              assetPath: asset.path,
              variantPath: p.join(alias.path, p.basename(asset.path)),
              afterAnalysisHook: () => alias.createSync(asset.parent.path),
            ),
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      final report = _expectPreviewValidationSafeStop(
        result: result,
        verifier: verifier,
        reportFile: reportFile,
        projectRoot: tempDir,
      );
      expect(asset.readAsBytesSync(), orderedEquals(assetBytes));
      expect(asset.statSync().mode & 0xfff, assetMode);
      expect(
        FileSystemEntity.typeSync(alias.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        _previewValidationDiagnostic(report)['message'],
        contains('Apply preview sources must be unique'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'dry-run read failure persists a safe-stop report without side effects',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final source = File(p.join(tempDir.path, 'preview-unreadable.bin'))
        ..writeAsStringSync('retained unreadable source bytes\n');
      final sourceBytes = source.readAsBytesSync();
      final originalMode = source.statSync().mode & 0xfff;
      addTearDown(() {
        if (source.existsSync()) _chmod(source, originalMode);
      });
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-source-read-failure.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            analyzerFactory: (project, only) =>
                _RemappedActionSourceProjectAnalyzer(
                  project: project,
                  only: only,
                  sourcePath: source.path,
                  afterAnalysisHook: () => _chmod(source, 0),
                ),
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      final report = _expectPreviewValidationSafeStop(
        result: result,
        verifier: verifier,
        reportFile: reportFile,
        projectRoot: tempDir,
      );
      expect(source.statSync().mode & 0xfff, 0);
      _chmod(source, originalMode);
      expect(source.readAsBytesSync(), orderedEquals(sourceBytes));
      expect(
        _previewValidationDiagnostic(report)['message'],
        contains('could not be read'),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'dry-run deletion after the first capture read remains a safe stop',
    () async {
      final source = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
      final retainedMain = File(p.join(tempDir.path, 'lib', 'main.dart'));
      final retainedMainBytes = retainedMain.readAsBytesSync();
      final retainedMainMode = retainedMain.statSync().mode & 0xfff;
      final reportFile = File(
        p.join(tempDir.path, 'dry-run-source-deleted-during-read.json'),
      );
      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      var deleted = false;
      final runner = args.CommandRunner<int>('flutter_pruner', 'test runner')
        ..argParser.addFlag('verbose', negatable: false)
        ..addCommand(
          ApplyCommand(
            verifierFactory: (_) => verifier,
            sourceSnapshotFirstReadHookForTesting: (captured) {
              if (deleted || !p.equals(captured.path, source.path)) return;
              deleted = true;
              source.deleteSync();
            },
          ),
        );

      final result = await _runApplyCaptured(runner, [
        'apply',
        '--adapter',
        'dart',
        '--dry-run',
        '--report-format',
        'json',
        '--report-output',
        reportFile.path,
        tempDir.path,
      ]);

      _expectPreviewValidationSafeStop(
        result: result,
        verifier: verifier,
        reportFile: reportFile,
        projectRoot: tempDir,
      );
      expect(deleted, isTrue);
      expect(source.existsSync(), isFalse);
      expect(retainedMain.readAsBytesSync(), orderedEquals(retainedMainBytes));
      expect(retainedMain.statSync().mode & 0xfff, retainedMainMode);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('apply accepts the same adapter filter as scan', () async {
    final exitCode = await FlutterPrunerCommandRunner().run([
      'apply',
      '--adapter',
      'dart',
      '--dry-run',
      tempDir.path,
    ]);

    expect(exitCode, 0);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
    final reportFile =
        Directory(p.join(tempDir.path, '.flutter_pruner', 'reports'))
            .listSync()
            .whereType<File>()
            .singleWhere((file) => p.basename(file.path).startsWith('apply-'));
    expect(p.basename(reportFile.path), startsWith('apply-'));
    expect(p.extension(reportFile.path), '.html');
    final html = reportFile.readAsStringSync();
    final embedded = RegExp(
      r'<script id="report-data" type="application/json">(.*?)</script>',
      dotAll: true,
    ).firstMatch(html);
    expect(embedded, isNotNull);
    final report = jsonDecode(embedded!.group(1)!) as Map;
    expect((report['run'] as Map)['status'], 'dryRun');
    final findingStatistics = (report['apply'] as Map)['findings'] as Map;
    expect(findingStatistics['remaining'], 1);
    final outcomes = (report['apply'] as Map)['findingOutcomes'] as List;
    expect(outcomes, hasLength(1));
    expect((outcomes.single as Map)['status'], 'remaining');
    expect((outcomes.single as Map)['reasonCode'], 'dry_run');
    expect((outcomes.single as Map)['rollbackVerified'], isNull);
  });

  test('prints the unified report callout after the dry-run result', () async {
    final reportFile = File(p.join(tempDir.path, 'reports', 'apply.html'));
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
        'apply',
        '--project',
        tempDir.path,
        '--adapter',
        'dart',
        '--dry-run',
        '--report-output',
        reportFile.path,
      ],
      workingDirectory: Directory.current.path,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = result.stdout as String;
    final progress = result.stderr as String;
    expect(output, isNot(contains('Report destination:')));
    expect(output, isNot(contains('Report written to')));
    expect(progress, contains('◆ PROJECT'));
    expect(progress, contains('Scanning Dart declaration analyzer'));
    expect(progress, contains('DRY RUN · NO FILES WILL BE CHANGED'));
    final plainProgress = progress.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
    expect(
      plainProgress,
      contains(
        '• Scanning Dart declaration analyzer…\n\n'
        '◆ DRY RUN · NO FILES WILL BE CHANGED\n',
      ),
    );
    final resultIndex = output.indexOf('APPLY PREVIEW READY');
    final reportIndex = output.indexOf('HTML REPORT READY');
    expect(resultIndex, greaterThanOrEqualTo(0));
    expect(reportIndex, greaterThan(resultIndex));
    expect(
      output.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), ''),
      contains(
        RegExp(r'APPLY PREVIEW READY[\s\S]*\n\n[\s\S]*HTML REPORT READY'),
      ),
    );
    final reportPath = reportFile.resolveSymbolicLinksSync();
    expect(_withoutTerminalFormatting(output), contains(reportPath));
  });

  test('--report-format overrides the automatic report format', () async {
    final exitCode = await FlutterPrunerCommandRunner().run([
      'apply',
      '--dry-run',
      '--report-format',
      'json',
      tempDir.path,
    ]);

    expect(exitCode, 0);
    final reportFile =
        Directory(p.join(tempDir.path, '.flutter_pruner', 'reports'))
            .listSync()
            .whereType<File>()
            .singleWhere((file) => p.basename(file.path).startsWith('apply-'));
    expect(p.basename(reportFile.path), startsWith('apply-'));
    expect(p.extension(reportFile.path), '.json');
    final report = jsonDecode(reportFile.readAsStringSync()) as Map;
    expect(report['version'], 3);
    expect((report['run'] as Map)['command'], 'apply');
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'report format and output aliases select the canonical apply options',
    () async {
      final canonical = ApplyCommand().argParser.parse([
        '--report-format',
        'json',
        '--report-output',
        'canonical.json',
      ]);
      final aliases = ApplyCommand().argParser.parse([
        '--format',
        'json',
        '--output',
        'canonical.json',
      ]);
      expect(
        aliases.option('report-format'),
        canonical.option('report-format'),
      );
      expect(
        aliases.option('report-output'),
        canonical.option('report-output'),
      );

      final output = File(p.join(tempDir.path, 'alias-report.json'));
      final exitCode = await FlutterPrunerCommandRunner().run([
        'apply',
        '--dry-run',
        '--format',
        'json',
        '--output',
        output.path,
        tempDir.path,
      ]);

      expect(exitCode, 0);
      expect(output.existsSync(), isTrue);
      expect((jsonDecode(output.readAsStringSync()) as Map)['version'], 3);
    },
  );

  test(
    'package-internal HIGH requires acknowledgement and records yesFlag',
    () async {
      _setPackageInternalConfig(tempDir);
      File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      ).writeAsStringSync('void usedFunction() {}\n');
      final publicFile = File(p.join(tempDir.path, 'lib', 'public_api.dart'))
        ..writeAsStringSync('class UnusedPublicApi {}\n');
      final rejectionPrompt = _FakeApplyPrompt(['n']);
      final verifier = _AlwaysPassingVerificationRunner(tempDir);

      final withoutOptIn = await FlutterPrunerCommandRunner(
        applyPrompt: rejectionPrompt,
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);
      expect(withoutOptIn, 2);
      expect(publicFile.readAsStringSync(), contains('UnusedPublicApi'));
      expect(verifier.invocationCount, 0);

      final withOptIn = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', '--yes', tempDir.path]);
      expect(withOptIn, 0);
      expect(publicFile.existsSync(), isFalse);
      expect(verifier.invocationCount, 3);
      final manager = QuarantineManager(tempDir);
      final quarantine = Directory(
        (await manager.listQuarantines()).single.path,
      );
      final manifest = await manager.readManifest(quarantine);
      expect(manifest.baselineVerification?.available, isTrue);
      expect(manifest.analysisMode, 'package-internal');
      expect(manifest.acceptedRiskCodes, ['external-consumers-not-scanned']);
      expect(manifest.riskAcceptanceSource, 'yesFlag');
      expect(
        manifest.transactions.map((item) => item.status),
        everyElement(QuarantineTransactionStatus.committed),
      );
    },
  );

  test('unselected HIGH does not broaden exact selection risk', () async {
    _setPackageInternalConfig(tempDir);
    final helper = File(p.join(tempDir.path, 'lib', 'src', 'helper.dart'));
    helper.writeAsStringSync('''
void usedFunction() {}

void _selectedCanary() {}
''');
    final publicFile = File(p.join(tempDir.path, 'lib', 'public_api.dart'))
      ..writeAsStringSync('class UnusedPublicApi {}\n');
    const findingId = 'dart:apply_test/lib/src/helper.dart#_selectedCanary';
    final prompt = _FakeApplyPrompt(['n']);
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode =
        await FlutterPrunerCommandRunner(
          applyPrompt: prompt,
          verifierFactory: (_) => verifier,
        ).run([
          'apply',
          '--adapter',
          'dart',
          '--finding-id',
          findingId,
          tempDir.path,
        ]);

    expect(exitCode, 0);
    expect(prompt.transcript, isEmpty);
    expect(verifier.invocationCount, 2);
    expect(helper.readAsStringSync(), isNot(contains('_selectedCanary')));
    expect(publicFile.readAsStringSync(), contains('UnusedPublicApi'));
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.selection?.requestedFindingIds, [findingId]);
    expect(manifest.acceptedRiskCodes, isEmpty);
    expect(manifest.riskAcceptanceSource, 'notRequired');
  });

  test('package-internal HIGH empty public library uses --yes', () async {
    _setPackageInternalConfig(tempDir);
    File(
      p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
    ).writeAsStringSync('void usedFunction() {}\n');
    final publicLibrary = File(p.join(tempDir.path, 'lib', 'empty_public.dart'))
      ..writeAsStringSync('\n');
    final rejectionPrompt = _FakeApplyPrompt(['n']);
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final withoutOptIn = await FlutterPrunerCommandRunner(
      applyPrompt: rejectionPrompt,
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'dart', tempDir.path]);
    expect(withoutOptIn, 2);
    expect(publicLibrary.existsSync(), isTrue);
    expect(verifier.invocationCount, 0);

    final withOptIn = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'dart', '--yes', tempDir.path]);
    expect(withOptIn, 0);
    expect(publicLibrary.existsSync(), isFalse);
    expect(verifier.invocationCount, 2);
  });

  test(
    'package-internal dry-run never prompts or creates quarantine',
    () async {
      _setPackageInternalConfig(tempDir);
      File(
        p.join(tempDir.path, 'lib', 'public_api.dart'),
      ).writeAsStringSync('class UnusedPublicApi {}\n');
      final prompt = _FakeApplyPrompt(['n']);

      final exitCode = await FlutterPrunerCommandRunner(
        applyPrompt: prompt,
      ).run(['apply', '--adapter', 'dart', '--dry-run', tempDir.path]);

      expect(exitCode, 0);
      expect(prompt.transcript, isEmpty);
      expect(
        Directory(
          p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('interactive rejection stops before verifier and quarantine', () async {
    _setPackageInternalConfig(tempDir);
    File(
      p.join(tempDir.path, 'lib', 'public_api.dart'),
    ).writeAsStringSync('class UnusedPublicApi {}\n');
    final prompt = _FakeApplyPrompt(['n']);
    final verifier = _AlwaysPassingVerificationRunner(tempDir);

    final exitCode = await FlutterPrunerCommandRunner(
      applyPrompt: prompt,
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'dart', tempDir.path]);

    expect(exitCode, 2);
    expect(prompt.transcript, contains('[y/N]'));
    expect(verifier.invocationCount, 0);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  });

  test('removed tier flags are rejected with usage exit code', () async {
    File(
      p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
    ).writeAsStringSync('void usedFunction() {}\n');
    final first = File(p.join(tempDir.path, 'assets', 'first.txt'));
    first.parent.createSync(recursive: true);
    first.writeAsStringSync('same bytes');
    File(
      p.join(tempDir.path, 'assets', 'second.txt'),
    ).writeAsStringSync('same bytes');

    for (final flag in ['--safe', '--high']) {
      final exitCode = await FlutterPrunerCommandRunner().run([
        'apply',
        '--adapter',
        'duplicates',
        flag,
        tempDir.path,
      ]);
      expect(exitCode, 64, reason: flag);
    }
    expect(first.existsSync(), isTrue);
    expect(
      Directory(
        p.join(tempDir.path, '.flutter_pruner', 'quarantine'),
      ).existsSync(),
      isFalse,
    );
  });

  test(
    'removes unreachable application libraries and generated companion',
    () async {
      final packageConfig = File(
        p.join(tempDir.path, '.dart_tool', 'package_config.json'),
      );
      packageConfig.parent.createSync(recursive: true);
      packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "apply_test",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
      File(
        p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
      ).writeAsStringSync('void usedFunction() {}\n');
      final importer = File(p.join(tempDir.path, 'lib', 'api.dart'));
      importer.writeAsStringSync("import 'src/dead_library.dart';\n");
      final deadLibrary = File(
        p.join(tempDir.path, 'lib', 'src', 'dead_library.dart'),
      );
      deadLibrary.writeAsStringSync("part 'dead_library.g.dart';\n");
      final generated = File(
        p.join(tempDir.path, 'lib', 'src', 'dead_library.g.dart'),
      );
      generated.writeAsStringSync("part of 'dead_library.dart';\n");

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => _AlwaysPassingVerificationRunner(tempDir),
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 0);
      expect(importer.existsSync(), isFalse);
      expect(deadLibrary.existsSync(), isFalse);
      expect(generated.existsSync(), isFalse);

      final manager = QuarantineManager(tempDir);
      final quarantine = (await manager.listQuarantines()).single;
      await manager.restore(
        quarantineDir: Directory(quarantine.path),
        runId: quarantine.runId,
      );
      expect(importer.readAsStringSync(), "import 'src/dead_library.dart';\n");
      expect(deadLibrary.readAsStringSync(), "part 'dead_library.g.dart';\n");
      expect(generated.readAsStringSync(), "part of 'dead_library.dart';\n");
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('retains a zero-byte Dart library reached by an exact import', () async {
    _writePackageConfig(tempDir);
    File(p.join(tempDir.path, 'lib', 'src', 'helper.dart')).deleteSync();
    final importer = File(p.join(tempDir.path, 'lib', 'main.dart'));
    const importerContent = "import 'src/empty.dart';\n\nvoid main() {}\n";
    importer.writeAsStringSync(importerContent);
    final emptyLibrary = File(p.join(tempDir.path, 'lib', 'src', 'empty.dart'))
      ..writeAsStringSync('');

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => _AlwaysPassingVerificationRunner(tempDir),
    ).run(['apply', '--adapter', 'dart', tempDir.path]);

    expect(exitCode, 0);
    expect(emptyLibrary.existsSync(), isTrue);
    expect(emptyLibrary.readAsBytesSync(), isEmpty);
    expect(importer.readAsStringSync(), importerContent);
    expect(await QuarantineManager(tempDir).listQuarantines(), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'one invocation retains a newly empty imported library after pruning',
    () async {
      _writePackageConfig(tempDir);
      final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
      const mainContent = "import 'src/dead.dart';\n\nvoid main() {}\n";
      mainFile.writeAsStringSync(mainContent);
      final deadFile = File(p.join(tempDir.path, 'lib', 'src', 'dead.dart'));
      const deadContent = 'void unusedFunction() {}\n';
      deadFile.writeAsStringSync(deadContent);
      File(p.join(tempDir.path, 'lib', 'src', 'helper.dart')).deleteSync();

      final verifier = _AlwaysPassingVerificationRunner(tempDir);
      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['apply', '--adapter', 'dart', tempDir.path]);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 2);
      expect(deadFile.existsSync(), isTrue);
      expect(deadFile.readAsBytesSync(), isEmpty);
      expect(mainFile.readAsStringSync(), mainContent);

      final manager = QuarantineManager(tempDir);
      final quarantine = (await manager.listQuarantines()).single;
      final quarantineDir = Directory(quarantine.path);
      final manifest = await manager.readManifest(quarantineDir);
      expect(manifest.transactions, hasLength(1));
      expect(manifest.transactions.map((item) => item.round), [1]);
      expect(
        manifest.cases.map((item) => item.caseId).toSet(),
        hasLength(manifest.cases.length),
      );
      expect(
        manifest.transactions.map((item) => item.status),
        everyElement(QuarantineTransactionStatus.committed),
      );

      await manager.restore(
        quarantineDir: quarantineDir,
        runId: quarantine.runId,
      );
      expect(mainFile.readAsStringSync(), mainContent);
      expect(deadFile.readAsStringSync(), deadContent);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('verification regression rolls back an empty library group', () async {
    _writePackageConfig(tempDir);
    File(
      p.join(tempDir.path, 'lib', 'src', 'helper.dart'),
    ).writeAsStringSync('void usedFunction() {}\n');
    final importer = File(p.join(tempDir.path, 'lib', 'api.dart'));
    const importerContent = "import 'src/dead_library.dart';\n";
    importer.writeAsStringSync(importerContent);
    final deadLibrary = File(
      p.join(tempDir.path, 'lib', 'src', 'dead_library.dart'),
    );
    const sourceContent = "part 'dead_library.g.dart';\n";
    deadLibrary.writeAsStringSync(sourceContent);
    final generated = File(
      p.join(tempDir.path, 'lib', 'src', 'dead_library.g.dart'),
    );
    const generatedContent = "part of 'dead_library.dart';\n";
    generated.writeAsStringSync(generatedContent);
    final verifier = _QueuedVerificationRunner(tempDir, [
      _verification(passed: true),
      _verification(passed: false, output: 'error • group regression'),
      _verification(passed: true),
    ]);

    final exitCode = await FlutterPrunerCommandRunner(
      verifierFactory: (_) => verifier,
    ).run(['apply', '--adapter', 'dart', tempDir.path]);

    expect(exitCode, 2);
    expect(verifier.invocationCount, 3);
    expect(importer.readAsStringSync(), importerContent);
    expect(deadLibrary.readAsStringSync(), sourceContent);
    expect(generated.readAsStringSync(), generatedContent);
    final manager = QuarantineManager(tempDir);
    final quarantine = Directory((await manager.listQuarantines()).single.path);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.cases, hasLength(3));
    expect(
      manifest.cases.map((item) => item.status),
      everyElement(QuarantineCaseStatus.rolledBack),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}

enum _ReportCollisionApplyInvocation { dryRunNoAction, exactActionable }

enum _UnsafePlannedSourceKind { symlink, outOfRoot, nonRegular }

enum _ExpectedPreviewDrift { bytes, posixMode }

Future<String> _captureExactPreviewFingerprint({
  required Directory project,
  required List<String> findingIds,
  required File reportFile,
  args.CommandRunner<int>? runner,
}) async {
  final result = await _runApplyCaptured(
    runner ?? FlutterPrunerCommandRunner(),
    [
      'apply',
      '--adapter',
      'dart',
      for (final findingId in findingIds) ...['--finding-id', findingId],
      '--dry-run',
      '--report-format',
      'json',
      '--report-output',
      reportFile.path,
      project.path,
    ],
  );
  if (result.exitCode != 0) {
    throw StateError('Preview fixture failed: ${result.stderr}');
  }
  final report =
      jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
  return (((report['apply'] as Map)['selection']
          as Map<String, dynamic>)['actualPreviewFingerprint']
      as String);
}

Map<String, dynamic> _expectPreviewFingerprintMismatchReport(
  File reportFile, {
  required String expected,
  required List<String> findingIds,
  bool equalTokens = false,
}) {
  expect(reportFile.existsSync(), isTrue);
  final report =
      jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
  final run = report['run'] as Map<String, dynamic>;
  final apply = report['apply'] as Map<String, dynamic>;
  final selection = apply['selection'] as Map<String, dynamic>;
  expect(run['status'], 'safeStopped');
  expect(run['exitCode'], 2);
  expect(selection['requestedFindingIds'], findingIds);
  if (equalTokens) {
    expect(selection['actualPreviewFingerprint'], expected);
  } else {
    expect(selection['actualPreviewFingerprint'], isNot(expected));
  }
  expect(selection['expectedPreviewFingerprint'], expected);
  expect(selection['previewComparison'], 'mismatched');
  expect((apply['actions'] as Map)['declared'], 0);
  expect(apply['verificationAttempts'], 0);
  expect(report['verificationAttempts'], isEmpty);
  expect(
    (report['diagnostics'] as List).cast<Map<String, dynamic>>().map(
      (diagnostic) => diagnostic['code'],
    ),
    contains('preview_fingerprint_mismatch'),
  );
  final outcomes = (apply['findingOutcomes'] as List)
      .cast<Map<String, dynamic>>();
  expect(outcomes.map((outcome) => outcome['findingId']).toList(), findingIds);
  expect(
    outcomes,
    everyElement(
      isA<Map<String, dynamic>>()
          .having((outcome) => outcome['status'], 'status', 'remaining')
          .having(
            (outcome) => outcome['reasonCode'],
            'reasonCode',
            'preview_fingerprint_mismatch',
          ),
    ),
  );
  return report;
}

Map<String, dynamic> _expectPreviewValidationSafeStop({
  required _CapturedApplyRun result,
  required _AlwaysPassingVerificationRunner verifier,
  required File reportFile,
  required Directory projectRoot,
}) {
  expect(result.exitCode, 2, reason: result.stderr);
  expect(verifier.invocationCount, 0);
  expect(
    Directory(
      p.join(projectRoot.path, '.flutter_pruner', 'quarantine'),
    ).existsSync(),
    isFalse,
  );
  expect(
    projectRoot
        .listSync(recursive: true, followLinks: false)
        .whereType<File>()
        .where((file) => p.basename(file.path) == 'manifest.json'),
    isEmpty,
  );
  expect(reportFile.existsSync(), isTrue);
  final report =
      jsonDecode(reportFile.readAsStringSync()) as Map<String, dynamic>;
  final run = report['run'] as Map<String, dynamic>;
  final apply = report['apply'] as Map<String, dynamic>;
  expect(run['status'], 'safeStopped');
  expect(run['exitCode'], 2);
  expect((apply['actions'] as Map)['declared'], 0);
  expect(apply['verificationAttempts'], 0);
  expect(report['verificationAttempts'], isEmpty);
  expect(
    _previewValidationDiagnostic(report)['code'],
    'analysis_snapshot_stale',
  );
  return report;
}

Map<String, dynamic> _previewValidationDiagnostic(
  Map<String, dynamic> report,
) => (report['diagnostics'] as List).cast<Map<String, dynamic>>().singleWhere(
  (diagnostic) => diagnostic['code'] == 'analysis_snapshot_stale',
);

Future<_CapturedApplyRun> _runApplyCaptured(
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
  return _CapturedApplyRun(
    exitCode: exitCode,
    stdout: capturedStdout.text,
    stderr: capturedStderr.text,
  );
}

final class _CapturedApplyRun {
  const _CapturedApplyRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _AnchorStateErrorReportObjectBackend
    implements ReportObjectBackend {
  const _AnchorStateErrorReportObjectBackend();

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async =>
      throw StateError('injected apply report preparation state error');
}

final class _AnchorFailureReportObjectBackend implements ReportObjectBackend {
  const _AnchorFailureReportObjectBackend();

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async =>
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.operationFailed,
        operation: 'injected-anchor',
      );
}

final class _ThrowAfterBeginTransactionQuarantineManager
    extends QuarantineManager {
  _ThrowAfterBeginTransactionQuarantineManager(super.projectRoot);

  var beginCalls = 0;

  @override
  Future<QuarantineTransaction> beginTransaction({
    required Directory quarantineDir,
    required String transactionId,
    required int round,
    required String componentId,
    required List<String> findingIds,
    required List<String> caseIds,
    String? verificationWaveId,
  }) async {
    await super.beginTransaction(
      quarantineDir: quarantineDir,
      transactionId: transactionId,
      round: round,
      componentId: componentId,
      findingIds: findingIds,
      caseIds: caseIds,
      verificationWaveId: verificationWaveId,
    );
    beginCalls++;
    throw StateError('injected failure after begin transaction persistence');
  }
}

enum _ApplyReportBackendFailureMode { write, closeStore }

final class _ApplyFailureReportObjectBackend implements ReportObjectBackend {
  _ApplyFailureReportObjectBackend(this.delegate, {required this.mode});

  final ReportObjectBackend delegate;
  final _ApplyReportBackendFailureMode mode;
  var createCalls = 0;
  var writeCalls = 0;
  var closeCalls = 0;

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async =>
      _ApplyFailureAnchoredReportDirectory(
        await delegate.anchor(directory),
        owner: this,
      );
}

final class _ApplyFailureAnchoredReportDirectory
    implements AnchoredReportDirectory {
  const _ApplyFailureAnchoredReportDirectory(
    this.delegate, {
    required this.owner,
  });

  final AnchoredReportDirectory delegate;
  final _ApplyFailureReportObjectBackend owner;

  @override
  String get canonicalPath => delegate.canonicalPath;

  @override
  Future<void> close() async {
    await delegate.close();
    owner.closeCalls++;
    if (owner.mode == _ApplyReportBackendFailureMode.closeStore) {
      throw StateError('injected apply report store close failure');
    }
  }

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async {
    owner.createCalls++;
    return _ApplyFailureExclusiveReportObject(
      await delegate.createExclusive(leaf),
      owner: owner,
    );
  }

  @override
  Future<ExistingReportObject> openExisting(String leaf) =>
      delegate.openExisting(leaf);

  @override
  Future<void> verifyReachable() => delegate.verifyReachable();
}

final class _ApplyFailureExclusiveReportObject
    implements ExclusiveReportObject {
  const _ApplyFailureExclusiveReportObject(
    this.delegate, {
    required this.owner,
  });

  final ExclusiveReportObject delegate;
  final _ApplyFailureReportObjectBackend owner;

  @override
  Future<void> close() => delegate.close();

  @override
  Future<void> flush() => delegate.flush();

  @override
  Future<ReportObjectIdentity> identity() => delegate.identity();

  @override
  Future<List<int>> read(int maximumBytes) => delegate.read(maximumBytes);

  @override
  Future<void> rewind() => delegate.rewind();

  @override
  Future<void> write(List<int> bytes) {
    owner.writeCalls++;
    if (owner.mode == _ApplyReportBackendFailureMode.write) {
      throw StateError('injected apply report object write failure');
    }
    return delegate.write(bytes);
  }
}

File _latestCommittedCanonicalReport(Directory quarantine) {
  final projectRoot = Directory(
    p.dirname(p.dirname(p.dirname(quarantine.path))),
  );
  final commits = _reportCommitsForRun(
    projectRoot,
    p.basename(quarantine.path),
  ).reversed;
  for (final commit in commits) {
    final canonicalRecords = commit.objects.where(
      (object) => object.role == 'canonical',
    );
    if (canonicalRecords.isEmpty) continue;
    final canonical = canonicalRecords.single;
    final file = File(
      p.join(
        quarantine.path,
        'reports',
        'objects',
        p.basename(canonical.relativePath),
      ),
    );
    if (!file.existsSync() ||
        file.lengthSync() != canonical.byteLength ||
        sha256.convert(file.readAsBytesSync()).toString() != canonical.sha256) {
      continue;
    }
    return file;
  }
  throw StateError('No committed canonical apply report was found.');
}

List<ReportCommit> _reportCommitsForRun(Directory projectRoot, String runId) {
  final commits = <ReportCommit>[];
  for (final file
      in projectRoot
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()) {
    if (!file.path.endsWith('.commit.json')) continue;
    try {
      final commit = ReportCommit.parse(file.readAsStringSync());
      if (commit.runId == runId) commits.add(commit);
    } on Object {
      // Invalid or unrelated commit artifacts are not authority.
    }
  }
  commits.sort((left, right) => left.sequence.compareTo(right.sequence));
  return commits;
}

String _canonicalReportFailureVerificationPolicy() {
  final fixture = p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'canonical_report_failure_verifier.dart',
  );
  return '''
verification:
  steps:
    - id: fixture
      argv:
        - ${jsonEncode(Platform.resolvedExecutable)}
        - ${jsonEncode(fixture)}
''';
}

void _writePackageConfig(Directory project) {
  final packageConfig = File(
    p.join(project.path, '.dart_tool', 'package_config.json'),
  );
  packageConfig.parent.createSync(recursive: true);
  packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "apply_test",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
}

void _writeEquivalentApplyProject(Directory project) {
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: apply_test
publish_to: none
environment:
  sdk: ^3.9.0
''');
  _writePackageConfig(project);
  File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
  final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
  mainFile.parent.createSync(recursive: true);
  mainFile.writeAsStringSync('''
import 'src/helper.dart';

void main() {
  usedFunction();
}
''');
  final helperFile = File(p.join(project.path, 'lib', 'src', 'helper.dart'));
  helperFile.parent.createSync(recursive: true);
  helperFile.writeAsStringSync('''
void usedFunction() {}

void unusedFunction() {}
''');
}

void _setPackageInternalConfig(Directory project) {
  final config = File(p.join(project.path, 'flutter_pruner.yaml'));
  config.writeAsStringSync(
    config.readAsStringSync().replaceFirst(
      '  mode: application\n',
      '  mode: package-internal\n'
          '  public_entrypoints:\n'
          '    - lib/main.dart\n',
    ),
  );
}

class _FakeApplyPrompt implements InitPrompt {
  _FakeApplyPrompt(Iterable<String?> responses)
    : _responses = List<String?>.from(responses);

  final List<String?> _responses;
  final StringBuffer _output = StringBuffer();
  var _index = 0;

  String get transcript => _output.toString();

  @override
  bool get isInteractive => true;

  @override
  String? readLine() =>
      _index < _responses.length ? _responses[_index++] : null;

  @override
  void write(String value) => _output.write(value);

  @override
  void writeln([String value = '']) => _output.writeln(value);
}

class _MutatingApplyPrompt implements InitPrompt {
  _MutatingApplyPrompt(this.file, this.contents);

  final File file;
  final String contents;
  var _answered = false;

  @override
  bool get isInteractive => true;

  @override
  String? readLine() {
    if (_answered) return null;
    _answered = true;
    file.writeAsStringSync(contents);
    return 'y';
  }

  @override
  void write(String value) {}

  @override
  void writeln([String value = '']) {}
}

class _ModeMutatingApplyPrompt implements InitPrompt {
  _ModeMutatingApplyPrompt(this.file, this.mode);

  final File file;
  final int mode;
  var _answered = false;

  @override
  bool get isInteractive => true;

  @override
  String? readLine() {
    if (_answered) return null;
    _answered = true;
    _chmod(file, mode);
    return 'y';
  }

  @override
  void write(String value) {}

  @override
  void writeln([String value = '']) {}
}

class _QueuedVerificationRunner extends VerificationRunner {
  _QueuedVerificationRunner(super.projectRoot, this.results);

  final List<VerificationResult> results;
  var _index = 0;

  int get invocationCount => _index;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    return results[_index++];
  }
}

class _AlwaysPassingVerificationRunner extends VerificationRunner {
  _AlwaysPassingVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    return _verification(
      passed: true,
      workingDirectory: p.normalize(p.absolute(projectRoot.path)),
    );
  }
}

class _ThrowingBaselineVerificationRunner extends VerificationRunner {
  _ThrowingBaselineVerificationRunner(
    super.projectRoot, {
    required this.rawFailure,
  });

  final String rawFailure;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    throw StateError(rawFailure);
  }
}

class _CancellingBaselineVerificationRunner extends VerificationRunner {
  _CancellingBaselineVerificationRunner(super.projectRoot);

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) {
    throw const ProcessCancellationConfirmedException(
      ProcessSignal.sigint,
      4242,
    );
  }
}

class _UnconfirmedBaselineVerificationRunner extends VerificationRunner {
  _UnconfirmedBaselineVerificationRunner(
    super.projectRoot, {
    required this.rootIdentity,
  });

  final PosixProcessIdentity rootIdentity;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) {
    throw ProcessTerminationUnconfirmedException(
      processId: rootIdentity.pid,
      message: 'fixture verification process may still be active',
      triggerSignal: ProcessSignal.sigterm,
      observedProcesses: <int, PosixProcessIdentity>{
        rootIdentity.pid: rootIdentity,
      },
      observationReliable: true,
    );
  }
}

class _CombinedStateVerificationRunner extends VerificationRunner {
  _CombinedStateVerificationRunner(
    super.projectRoot, {
    required this.first,
    required this.second,
  });

  final File first;
  final File second;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    final firstRemoved = !first.readAsStringSync().contains('selectedFirst');
    final secondRemoved = !second.readAsStringSync().contains('selectedSecond');
    final passed = firstRemoved == secondRemoved;
    return _verification(
      passed: passed,
      output: passed ? '' : 'error • incomplete combined state',
      workingDirectory: p.normalize(p.absolute(projectRoot.path)),
    );
  }
}

class _OpaqueRedThenPassingVerificationRunner extends VerificationRunner {
  _OpaqueRedThenPassingVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    final passed = invocationCount > 1;
    final command = policy.commands.single;
    return VerificationResult(
      passed: passed,
      steps: [
        VerificationStep(
          name: command.id,
          parserKind: command.parserKind,
          passed: passed,
          exitCode: passed ? 0 : 1,
          stdout: passed
              ? ''
              : 'error • lib/src/helper.dart:1:1 • custom_error\n'
                    '1 issue found.',
          stderr: '',
          duration: Duration.zero,
        ),
      ],
      failedStep: passed ? null : command.id,
      policyHash: policy.hash,
      requiredStepIds: policy.requiredStepIds,
      requiredParserKinds: policy.requiredParserKinds,
      workingDirectory: p.normalize(p.absolute(projectRoot.path)),
      toolchainIdentity: 'opaque-test-toolchain',
    );
  }
}

class _MutatingBaselineVerificationRunner extends VerificationRunner {
  _MutatingBaselineVerificationRunner(
    super.projectRoot,
    this.file,
    this.contents,
  );

  final File file;
  final String contents;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 1) file.writeAsStringSync(contents);
    return _verification(
      passed: true,
      workingDirectory: p.normalize(p.absolute(projectRoot.path)),
    );
  }
}

class _SecondCleanupFails extends ImportCleanupRunner {
  _SecondCleanupFails(String projectRoot) : super(projectRoot: projectRoot);

  var invocationCount = 0;

  @override
  Future<CleanupResult> run(List<String> filePaths) async {
    invocationCount++;
    if (invocationCount == 2) {
      return const CleanupResult(
        success: false,
        stderr: 'injected second cleanup failure',
        exitCode: 1,
      );
    }
    return const CleanupResult(success: true, stderr: '', exitCode: 0);
  }
}

class _UnsafeCleanupTermination extends ImportCleanupRunner {
  _UnsafeCleanupTermination(String projectRoot)
    : super(projectRoot: projectRoot);

  @override
  Future<CleanupResult> run(List<String> filePaths) {
    throw const ImportCleanupRecoveryRequiredException(
      processId: 4242,
      message: 'injected cleanup process may still be alive',
    );
  }
}

class _ConfirmedCleanupCancellation extends ImportCleanupRunner {
  _ConfirmedCleanupCancellation(String projectRoot)
    : super(projectRoot: projectRoot);

  @override
  Future<CleanupResult> run(List<String> filePaths) {
    throw const ProcessCancellationConfirmedException(
      ProcessSignal.sigterm,
      4343,
    );
  }
}

class _CleanupCancellationVerificationRunner extends VerificationRunner {
  _CleanupCancellationVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 1) {
      return _verification(
        passed: true,
        workingDirectory: p.normalize(p.absolute(projectRoot.path)),
      );
    }
    throw const ProcessCancellationBeforeLaunchException(ProcessSignal.sigterm);
  }
}

class _CaseMutationGuardManager extends QuarantineManager {
  _CaseMutationGuardManager(super.projectRoot);

  var recordCaseAppliedCalls = 0;
  var rollbackCaseCalls = 0;

  @override
  Future<QuarantineCase> recordCaseApplied({
    required Directory quarantineDir,
    required String caseId,
  }) {
    recordCaseAppliedCalls++;
    return super.recordCaseApplied(
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
  }

  @override
  Future<QuarantineCase> rollbackCase({
    required Directory quarantineDir,
    required String caseId,
    required String reason,
    bool failed = false,
  }) {
    rollbackCaseCalls++;
    return super.rollbackCase(
      quarantineDir: quarantineDir,
      caseId: caseId,
      reason: reason,
      failed: failed,
    );
  }
}

class _ApplyProcessGuardManager extends QuarantineManager {
  _ApplyProcessGuardManager(
    super.projectRoot, {
    required super.permissionProcessRunner,
  });

  var recordCaseAppliedCalls = 0;
  var rollbackCaseCalls = 0;

  @override
  Future<QuarantineCase> recordCaseApplied({
    required Directory quarantineDir,
    required String caseId,
  }) {
    recordCaseAppliedCalls++;
    return super.recordCaseApplied(
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
  }

  @override
  Future<QuarantineCase> rollbackCase({
    required Directory quarantineDir,
    required String caseId,
    required String reason,
    bool failed = false,
  }) {
    rollbackCaseCalls++;
    return super.rollbackCase(
      quarantineDir: quarantineDir,
      caseId: caseId,
      reason: reason,
      failed: failed,
    );
  }
}

class _SuccessfulCleanupRunner extends ImportCleanupRunner {
  _SuccessfulCleanupRunner(String projectRoot)
    : super(projectRoot: projectRoot);

  @override
  Future<CleanupResult> run(List<String> filePaths) async =>
      const CleanupResult(success: true, stderr: '', exitCode: 0);
}

class _ApplyCancellationAtLink implements ProcessExecutionRunner {
  _ApplyCancellationAtLink({required this.failAt, required this.cancellation});

  final int failAt;
  final Exception cancellation;
  final ProcessExecutionRunner _delegate = const ManagedProcessRunner();
  var invocationCount = 0;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    invocationCount++;
    final result = await _delegate.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
    );
    if (invocationCount == failAt) throw cancellation;
    return result;
  }
}

class _ApplyCancellationAtPermission implements ProcessExecutionRunner {
  _ApplyCancellationAtPermission({
    required this.failAt,
    required this.cancellation,
  });

  final int failAt;
  final Exception cancellation;
  final ProcessExecutionRunner _delegate = const ManagedProcessRunner();
  var invocationCount = 0;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    invocationCount++;
    final result = await _delegate.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
    );
    if (invocationCount == failAt) throw cancellation;
    return result;
  }
}

void _chmodApplyFixture(File file, int mode) {
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8),
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

class _ThrowingCandidateVerificationRunner extends VerificationRunner {
  _ThrowingCandidateVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 1) return _verification(passed: true);
    throw StateError('candidate verifier crashed');
  }
}

class _CancelledCandidateAndRecoveryVerificationRunner
    extends VerificationRunner {
  _CancelledCandidateAndRecoveryVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 1) {
      return _verification(
        passed: true,
        workingDirectory: p.normalize(p.absolute(projectRoot.path)),
      );
    }
    if (invocationCount == 2) {
      throw const ProcessCancellationConfirmedException(
        ProcessSignal.sigint,
        4242,
      );
    }
    throw const ProcessCancellationBeforeLaunchException(ProcessSignal.sigint);
  }
}

class _UnsafeCandidateVerificationRunner extends VerificationRunner {
  _UnsafeCandidateVerificationRunner(super.projectRoot);

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 2) {
      throw const ProcessTerminationUnconfirmedException(
        processId: 4242,
        message: 'injected verifier process may still be alive',
      );
    }
    return _verification(passed: true);
  }
}

class _BlockingReportExportVerificationRunner extends VerificationRunner {
  _BlockingReportExportVerificationRunner(super.projectRoot, this.reportParent);

  final Directory reportParent;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    if (invocationCount == 2) {
      reportParent.deleteSync();
      File(reportParent.path).writeAsStringSync('preserve these bytes');
    }
    return _verification(passed: true);
  }
}

class _ThrowingRescanProjectAnalyzer extends ProjectAnalyzer {
  _ThrowingRescanProjectAnalyzer({required super.project, super.only});

  var invocationCount = 0;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    invocationCount++;
    if (invocationCount == 2) {
      throw StateError('rescan analyzer crashed');
    }
    return super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
  }
}

class _ThrowingInitialProjectAnalyzer extends ProjectAnalyzer {
  _ThrowingInitialProjectAnalyzer({
    required super.project,
    super.only,
    required this.rawFailure,
  });

  final String rawFailure;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final adapter = adapters.single;
    onAdapter?.call(adapter);
    onAdapterFinished?.call(adapter, AdapterRunStatus.failed);
    throw StateError(rawFailure);
  }
}

class _PostAdapterInitialProjectAnalyzer extends ProjectAnalyzer {
  _PostAdapterInitialProjectAnalyzer({
    required super.project,
    super.only,
    required this.rawFailure,
  });

  final String rawFailure;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    throw StateError(rawFailure);
  }
}

class _HostileInitialProjectAnalyzer extends ProjectAnalyzer {
  _HostileInitialProjectAnalyzer({
    required super.project,
    super.only,
    required this.rawFailure,
  });

  final String rawFailure;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    const adapter = _HostileApplyAnalyzerAdapter();
    onAdapter?.call(adapter);
    onAdapterFinished?.call(adapter, AdapterRunStatus.failed);
    throw StateError(rawFailure);
  }
}

final class _HostileApplyAnalyzerAdapter extends AnalyzerAdapter {
  const _HostileApplyAnalyzerAdapter();

  @override
  String get id => 'dart\nprivate\u202e';

  @override
  String get name => 'Dart\rprivate\u2066 analyzer';

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {}
}

class _DuplicateFindingProjectAnalyzer extends ProjectAnalyzer {
  _DuplicateFindingProjectAnalyzer({required super.project, super.only});

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final result = await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    if (result.findings.isEmpty) return result;
    return AnalysisSnapshot(
      project: result.project,
      graph: result.graph,
      graphIntegrity: result.graphIntegrity,
      findings: [...result.findings, result.findings.first],
      adapterIds: result.adapterIds,
      adapterRuns: result.adapterRuns,
      elapsedMicros: result.elapsedMicros,
      exclusions: result.exclusions,
    );
  }
}

class _RetainedSafeFindingProjectAnalyzer extends ProjectAnalyzer {
  _RetainedSafeFindingProjectAnalyzer({
    required super.project,
    required this.findingId,
    super.only,
  });

  final String findingId;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final result = await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    final findings = result.findings
        .map((finding) {
          if (finding.node.id != findingId) return finding;
          final predicates = finding.predicates;
          return Finding(
            ruleId: finding.ruleId,
            node: finding.node,
            confidence: Confidence.safe,
            title: finding.title,
            predicates: SafetyPredicates(
              ruleAllowsAutoFix: predicates.ruleAllowsAutoFix,
              unreachableAcrossAllTargets:
                  predicates.unreachableAcrossAllTargets,
              notRetained: false,
              noDynamicBlockers: predicates.noDynamicBlockers,
              notProtected: predicates.notProtected,
              noPublicApiRisk: predicates.noPublicApiRisk,
              hasDeterministicInverse: predicates.hasDeterministicInverse,
              analysisCoverageComplete: predicates.analysisCoverageComplete,
              actionSupported: predicates.actionSupported,
            ),
            evidence: finding.evidence,
            blockers: finding.blockers,
            protectionReasons: finding.protectionReasons,
            unreachableIn: finding.unreachableIn,
            reachableIn: finding.reachableIn,
            retainedIn: finding.retainedIn,
            auxiliaryRetainedIn: const ['aux:test:retained-snapshot'],
            proposedAction: finding.proposedAction,
            sourceBytes: finding.sourceBytes,
            classificationReasons: finding.classificationReasons,
            manualRisks: finding.manualRisks,
            reportingAdapterId: finding.reportingAdapterId,
          );
        })
        .toList(growable: false);
    return AnalysisSnapshot(
      project: result.project,
      graph: result.graph,
      graphIntegrity: result.graphIntegrity,
      findings: findings,
      adapterIds: result.adapterIds,
      adapterRuns: result.adapterRuns,
      elapsedMicros: result.elapsedMicros,
      findingElapsedMicros: result.findingElapsedMicros,
      exclusions: result.exclusions,
    );
  }
}

class _RemappedActionSourceProjectAnalyzer extends ProjectAnalyzer {
  _RemappedActionSourceProjectAnalyzer({
    required super.project,
    required this.sourcePath,
    this.afterAnalysisHook,
    super.only,
  });

  static const _templateFindingId =
      'dart:apply_test/lib/src/helper.dart#unusedFunction';

  final String sourcePath;
  final void Function()? afterAnalysisHook;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final result = await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    afterAnalysisHook?.call();
    final findings = result.findings
        .map((finding) {
          if (finding.node.id != _templateFindingId) return finding;
          return Finding(
            ruleId: finding.ruleId,
            node: GraphNode(
              id: finding.node.id,
              kind: finding.node.kind,
              origin: File(sourcePath).uri,
              sizeBytes: finding.node.sizeBytes,
              sha256: finding.node.sha256,
              displayName: finding.node.displayName,
              metadata: finding.node.metadata,
            ),
            confidence: finding.confidence,
            title: finding.title,
            predicates: finding.predicates,
            evidence: finding.evidence,
            blockers: finding.blockers,
            protectionReasons: finding.protectionReasons,
            unreachableIn: finding.unreachableIn,
            reachableIn: finding.reachableIn,
            retainedIn: finding.retainedIn,
            auxiliaryRetainedIn: finding.auxiliaryRetainedIn,
            proposedAction: finding.proposedAction,
            sourceBytes: finding.sourceBytes,
            classificationReasons: finding.classificationReasons,
            manualRisks: finding.manualRisks,
            reportingAdapterId: finding.reportingAdapterId,
          );
        })
        .toList(growable: false);
    return AnalysisSnapshot(
      project: result.project,
      graph: result.graph,
      graphIntegrity: result.graphIntegrity,
      findings: findings,
      adapterIds: result.adapterIds,
      adapterRuns: result.adapterRuns,
      elapsedMicros: result.elapsedMicros,
      findingElapsedMicros: result.findingElapsedMicros,
      exclusions: result.exclusions,
    );
  }
}

class _LateVariantProjectAnalyzer extends ProjectAnalyzer {
  _LateVariantProjectAnalyzer({
    required super.project,
    required this.findingId,
    required this.assetPath,
    required this.variantPath,
    this.afterAnalysisHook,
    super.only,
  });

  final String findingId;
  final String assetPath;
  final String? variantPath;
  final void Function()? afterAnalysisHook;
  var invocationCount = 0;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    final result = await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    invocationCount++;
    if (invocationCount > 1) return result;
    afterAnalysisHook?.call();
    const templateId = 'dart:apply_test/lib/src/helper.dart#unusedFunction';
    final findings = result.findings
        .map((finding) {
          if (finding.node.id != templateId) return finding;
          final node = GraphNode(
            id: findingId,
            kind: NodeKind.asset,
            origin: File(assetPath).uri,
            sizeBytes: File(assetPath).lengthSync(),
            displayName: 'assets/canary.txt',
            metadata: {
              'removalSupported': true,
              'variantPaths': [if (variantPath != null) variantPath!],
            },
          );
          return Finding(
            ruleId: 'PRN-ASSET-001',
            node: node,
            confidence: finding.confidence,
            title: 'Unused asset',
            predicates: finding.predicates,
            evidence: finding.evidence,
            blockers: finding.blockers,
            protectionReasons: finding.protectionReasons,
            unreachableIn: finding.unreachableIn,
            reachableIn: finding.reachableIn,
            proposedAction: 'Move to quarantine',
            sourceBytes: File(assetPath).lengthSync(),
            classificationReasons: finding.classificationReasons,
            manualRisks: finding.manualRisks,
            reportingAdapterId: 'assets',
          );
        })
        .toList(growable: false);
    return AnalysisSnapshot(
      project: result.project,
      graph: result.graph,
      graphIntegrity: result.graphIntegrity,
      findings: findings,
      adapterIds: result.adapterIds,
      adapterRuns: result.adapterRuns,
      elapsedMicros: result.elapsedMicros,
      exclusions: result.exclusions,
    );
  }
}

class _ReappearingFinalProjectAnalyzer extends ProjectAnalyzer {
  _ReappearingFinalProjectAnalyzer({
    required super.project,
    required this.findingId,
    super.only,
  });

  final String findingId;
  var invocationCount = 0;
  Finding? _initialFinding;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    invocationCount++;
    final result = await super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
    if (invocationCount == 1) {
      _initialFinding = result.findings.singleWhere(
        (finding) => finding.node.id == findingId,
      );
      return result;
    }
    if (invocationCount < 3 ||
        result.findings.any((finding) => finding.node.id == findingId)) {
      return result;
    }
    return AnalysisSnapshot(
      project: result.project,
      graph: result.graph,
      graphIntegrity: result.graphIntegrity,
      findings: [...result.findings, _initialFinding!],
      adapterIds: result.adapterIds,
      adapterRuns: result.adapterRuns,
      elapsedMicros: result.elapsedMicros,
      exclusions: result.exclusions,
    );
  }
}

class _ThrowingFinalProjectAnalyzer extends ProjectAnalyzer {
  _ThrowingFinalProjectAnalyzer({required super.project, super.only});

  var invocationCount = 0;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
    AdapterFinishedCallback? onAdapterFinished,
  }) async {
    invocationCount++;
    if (invocationCount == 3) {
      throw StateError('final convergence analyzer crashed');
    }
    return super.analyze(
      onAdapter: onAdapter,
      onAdapterFinished: onAdapterFinished,
    );
  }
}

class _RecordingStdout implements Stdout {
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

VerificationResult _verification({
  required bool passed,
  String output = '',
  String workingDirectory = '/workspace/test',
}) {
  final analyzerOutput = !passed && output.isNotEmpty
      ? '${output.split(' • ').length >= 4 ? output : '$output • lib/src/helper.dart:1:1 • fixture_error'}\n'
            '1 issue found.'
      : output;
  return VerificationResult(
    passed: passed,
    steps: [
      VerificationStep(
        name: 'flutter-analyze',
        parserKind: VerificationOutputParserKind.humanAnalyzer,
        passed: passed,
        exitCode: passed ? 0 : 1,
        stdout: analyzerOutput,
        stderr: '',
        duration: Duration.zero,
      ),
      const VerificationStep(
        name: 'flutter-test',
        parserKind: VerificationOutputParserKind.compactTest,
        passed: true,
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    failedStep: passed ? null : 'flutter-analyze',
    policyHash: VerificationPolicy.flutterDefault.hash,
    requiredStepIds: VerificationPolicy.flutterDefault.requiredStepIds,
    requiredParserKinds: VerificationPolicy.flutterDefault.requiredParserKinds,
    workingDirectory: workingDirectory,
    toolchainIdentity: 'test-toolchain',
  );
}

VerificationResult _unavailableVerification() {
  return VerificationResult(
    passed: false,
    steps: const [
      VerificationStep(
        name: 'flutter-analyze',
        parserKind: VerificationOutputParserKind.humanAnalyzer,
        passed: false,
        exitCode: -1,
        stdout: '',
        stderr: 'Timed out',
        duration: Duration(minutes: 5),
      ),
      VerificationStep(
        name: 'flutter-test',
        parserKind: VerificationOutputParserKind.compactTest,
        passed: true,
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    failedStep: 'flutter-analyze',
    policyHash: VerificationPolicy.flutterDefault.hash,
    requiredStepIds: VerificationPolicy.flutterDefault.requiredStepIds,
    requiredParserKinds: VerificationPolicy.flutterDefault.requiredParserKinds,
    workingDirectory: '/workspace/test',
    toolchainIdentity: 'test-toolchain',
  );
}

String _withoutTerminalFormatting(String value) => value
    .replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '')
    .replaceAll(RegExp(r'\s+'), '');

String _wrappedCommandContaining(String value, String marker) {
  final lines = value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '').split('\n');
  final start = lines.indexWhere((line) => line.contains(marker));
  if (start == -1) throw StateError('Command marker not found: $marker');
  final command = StringBuffer();
  for (var index = start; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty) break;
    command.write(line);
  }
  return command.toString();
}

void _chmod(File file, int mode) {
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8),
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

int _posixMode(File file) => file.statSync().mode & 0xfff;
