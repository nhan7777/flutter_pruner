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
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/reporting/report_commit.dart';
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
      expect(selection['planFingerprint'], matches(r'^[0-9a-f]{64}$'));
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
      final deadOriginalMode = _posixMode(dead);
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
      expect(_posixMode(deadBackup), deadOriginalMode);
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
        contains('flutter_pruner rollback --project'),
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
      final rollbackLine = capturedStdout.text
          .split('\n')
          .singleWhere((line) => line.contains('flutter_pruner rollback'));
      expect(rollbackLine, contains('--quarantine'));
      expect(rollbackLine, contains(quarantine.runId));
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
      expect(output, contains('flutter_pruner rollback --project'));
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
      final rollbackLine = output
          .split('\n')
          .singleWhere((line) => line.contains('flutter_pruner rollback'));
      expect(rollbackLine, contains('--quarantine'));
      expect(rollbackLine, contains(quarantine.runId));
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
    final resultIndex = output.indexOf('APPLY PREVIEW READY');
    final reportIndex = output.indexOf('HTML REPORT READY');
    expect(resultIndex, greaterThanOrEqualTo(0));
    expect(reportIndex, greaterThan(resultIndex));
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

Future<_CapturedApplyRun> _runApplyCaptured(
  FlutterPrunerCommandRunner runner,
  List<String> arguments,
) async {
  final capturedStdout = _RecordingStdout();
  final capturedStderr = _RecordingStdout();
  final exitCode = await IOOverrides.runZoned(
    () => runner.run(arguments),
    stdout: () => capturedStdout,
    stderr: () => capturedStderr,
  );
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
  }) async {
    invocationCount++;
    if (invocationCount == 2) {
      throw StateError('rescan analyzer crashed');
    }
    return super.analyze(onAdapter: onAdapter);
  }
}

class _DuplicateFindingProjectAnalyzer extends ProjectAnalyzer {
  _DuplicateFindingProjectAnalyzer({required super.project, super.only});

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
  }) async {
    final result = await super.analyze(onAdapter: onAdapter);
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
  }) async {
    final result = await super.analyze(onAdapter: onAdapter);
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

class _LateVariantProjectAnalyzer extends ProjectAnalyzer {
  _LateVariantProjectAnalyzer({
    required super.project,
    required this.findingId,
    required this.assetPath,
    required this.variantPath,
    super.only,
  });

  final String findingId;
  final String assetPath;
  final String variantPath;
  var invocationCount = 0;

  @override
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
  }) async {
    final result = await super.analyze(onAdapter: onAdapter);
    invocationCount++;
    if (invocationCount > 1) return result;
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
              'variantPaths': [variantPath],
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
  }) async {
    invocationCount++;
    final result = await super.analyze(onAdapter: onAdapter);
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
  }) async {
    invocationCount++;
    if (invocationCount == 3) {
      throw StateError('final convergence analyzer crashed');
    }
    return super.analyze(onAdapter: onAdapter);
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
