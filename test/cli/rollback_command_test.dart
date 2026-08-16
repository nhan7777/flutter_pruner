import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('V3 rollback runs verifier before claiming verified terminal', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      final run = await _createCompletedV3Run(project, runId: 'verified-v3');
      final verifier = _FixedRollbackVerifier(
        project,
        _verificationResult(project, passed: true),
      );

      final exitCode = await FlutterPrunerCommandRunner(
        verifierFactory: (_) => verifier,
      ).run(['rollback', '--project', project.path, 'verified-v3']);

      expect(exitCode, 0);
      expect(verifier.invocationCount, 1);
      expect(run.source.readAsStringSync(), 'void original() {}\n');
      final manifest = await run.manager.readManifest(run.quarantine);
      expect(manifest.fullRollbackVerified, isTrue);
      expect(
        await run.manager.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.rolledBackVerified,
      );
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'V3 rollback verifier failure preserves evidence and blocks clean',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'failed-verifier-v3',
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: false),
        );

        final exitCode =
            await FlutterPrunerCommandRunner(
              verifierFactory: (_) => verifier,
            ).run([
              'rollback',
              '--clean',
              '--project',
              project.path,
              'failed-verifier-v3',
            ]);

        expect(exitCode, 1);
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        final manifest = await run.manager.readManifest(run.quarantine);
        expect(manifest.fullRollbackVerified, isFalse);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
        await expectLater(
          run.manager.validateCleanQuarantine(runId: 'failed-verifier-v3'),
          throwsA(isA<QuarantineException>()),
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback chmod during verifier cannot terminalize or clean',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'chmod-during-verifier-v3',
          originalPosixMode: 0x1ed,
        );
        final verifier = _MutatingRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
          () => _chmod(run.source, 0x1a4),
        );

        final exitCode =
            await FlutterPrunerCommandRunner(
              verifierFactory: (_) => verifier,
            ).run([
              'rollback',
              '--clean',
              '--project',
              project.path,
              'chmod-during-verifier-v3',
            ]);

        expect(exitCode, 1);
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(_posixMode(run.source), 0x1a4);
        expect(run.quarantine.existsSync(), isTrue);
        final manifest = await run.manager.readManifest(run.quarantine);
        expect(manifest.fullRollbackVerified, isFalse);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
        await expectLater(
          run.manager.validateCleanQuarantine(
            runId: 'chmod-during-verifier-v3',
          ),
          throwsA(isA<QuarantineException>()),
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback accepts the same sanitized baseline-red evidence',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'baseline-red-v3',
          baselinePassed: false,
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: false),
        );

        final exitCode = await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', project.path, 'baseline-red-v3']);

        expect(exitCode, 0);
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        final manifest = await run.manager.readManifest(run.quarantine);
        expect(manifest.fullRollbackVerified, isTrue);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.rolledBackVerified,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback unconfirmed verifier termination stays recovery-required',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'unsafe-verifier-v3',
        );
        final verifier = _UnconfirmedRollbackVerifier(project);

        final exitCode = await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', project.path, 'unsafe-verifier-v3']);

        expect(exitCode, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback with legacy baseline evidence fails before mutation',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'legacy-evidence-v3',
          baselinePassed: null,
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );

        final exitCode = await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', project.path, 'legacy-evidence-v3']);

        expect(exitCode, 1);
        expect(verifier.invocationCount, 0);
        expect(run.source.readAsStringSync(), 'void modified() {}\n');
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.completed,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback uses the new project quarantine from another working directory',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'source.dart'));
        source.parent.createSync(recursive: true);
        source.writeAsStringSync('void original() {}\n');

        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(runId: 'run-1');
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-0001',
          findingId: 'dart:rollback_test/lib/source.dart#original',
          file: source,
          operationType: QuarantineOperationType.declaration,
        );
        source.writeAsStringSync('void modified() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-0001',
        );
        await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'run-1',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), 'void original() {}\n');
        final restored = await manager.readManifest(quarantine);
        expect(restored.fullRollbackVerified, isTrue);
        expect(restored.fullRollbackAtUtc, isNotNull);
        expect(restored.cases.single.status, QuarantineCaseStatus.rolledBack);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback --clean preserves unjournaled working-copy recovery bytes',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'source.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        const interrupted = 'void unjournaled() {}\n';
        source.writeAsStringSync(original);

        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'recovery-run',
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-0001',
          findingId: 'dart:rollback_test/lib/source.dart#original',
          file: source,
          operationType: QuarantineOperationType.declaration,
        );
        source.writeAsStringSync(interrupted);

        final result = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'rollback',
          '--clean',
          '--project',
          project.path,
          'recovery-run',
        ]);

        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains('expected bytes or permissions are outside the journal'),
        );
        expect(source.readAsStringSync(), interrupted);
        expect(quarantine.existsSync(), isTrue);
        final recovery = File(
          p.join(
            quarantine.path,
            'recovery',
            'case-0001',
            'lib',
            'source.dart',
          ),
        );
        expect(recovery.readAsStringSync(), interrupted);
        final manifest = await manager.readManifest(quarantine);
        expect(manifest.fullRollbackVerified, isFalse);
        expect(manifest.cases.single.status, QuarantineCaseStatus.backedUp);

        final cleanResult = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'recovery-run',
        ]);
        expect(cleanResult.exitCode, 1);
        expect(cleanResult.stderr, contains('contains recovery artifacts'));
        expect(recovery.readAsStringSync(), interrupted);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test('rollback falls back to the legacy project quarantine', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final source = File(p.join(project.path, 'lib', 'source.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void original() {}\n');

      final manager = QuarantineManager(project);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'legacy-run',
        quarantineBase: QuarantineManager.legacyQuarantineDir,
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'dart:rollback_test/lib/source.dart#original',
        file: source,
        operationType: QuarantineOperationType.declaration,
      );
      source.writeAsStringSync('void modified() {}\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'legacy-run',
      ]);

      expect(exitCode, 0);
      expect(source.readAsStringSync(), 'void original() {}\n');
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'rollback restores V1 mode and removes adjacent publish anchor',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'legacy.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void legacy() {}\n';
        source.writeAsStringSync(original);
        final originalPosixMode = Platform.isLinux || Platform.isMacOS
            ? 0x1ed
            : null;
        if (originalPosixMode != null) _chmod(source, originalPosixMode);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
          posixMode: originalPosixMode,
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'v1-run',
          entries: [entry],
        );
        await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'v1-run',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), original);
        if (originalPosixMode != null) {
          expect(_posixMode(source), originalPosixMode);
        }
        expect(
          source.parent
              .listSync(followLinks: false)
              .where(
                (entity) => p
                    .basename(entity.path)
                    .startsWith('.flutter_pruner-restore-'),
              ),
          isEmpty,
        );
        source.writeAsStringSync(
          'void editedAfterRollback() {}\n',
          flush: true,
        );
        expect(
          source.parent
              .listSync(followLinks: false)
              .whereType<File>()
              .where(
                (file) =>
                    file.path != source.path &&
                    file.readAsStringSync() ==
                        'void editedAfterRollback() {}\n',
              ),
          isEmpty,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback resumes interrupted V1 staging in the tool workspace',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'interrupted.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        const modified = 'void modified() {}\n';
        source.writeAsStringSync(original);
        final originalPosixMode = Platform.isLinux || Platform.isMacOS
            ? 0x1ed
            : null;
        if (originalPosixMode != null) _chmod(source, originalPosixMode);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
          posixMode: originalPosixMode,
          operationType: QuarantineOperationType.declaration,
          modifiedSha256: sha256.convert(utf8.encode(modified)).toString(),
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'interrupted-v1',
          entries: [entry],
        );
        final snapshot = await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );
        source.writeAsStringSync(modified);

        final token = sha256
            .convert(utf8.encode(p.normalize(p.absolute(snapshot.path))))
            .toString()
            .substring(0, 16);
        final staging = Directory(
          p.join(
            project.path,
            '.flutter_pruner',
            'tmp',
            'restore',
            'v1-interrupted-v1-$token',
          ),
        );
        staging.createSync(recursive: true);
        final restoredStage = await snapshot.copy(
          p.join(staging.path, 'restored'),
        );
        final displacedStage = await source.copy(
          p.join(staging.path, 'displaced'),
        );
        if (originalPosixMode != null) {
          _chmod(restoredStage, originalPosixMode);
          _chmod(displacedStage, originalPosixMode);
        }
        source.deleteSync();

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'interrupted-v1',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), original);
        if (originalPosixMode != null) {
          expect(_posixMode(source), originalPosixMode);
        }
        expect(snapshot.existsSync(), isFalse);
        expect(staging.existsSync(), isFalse);
        expect(
          File(
            '${source.path}.flutter_pruner_restore_interrupted-v1.staging',
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            '${source.path}.flutter_pruner_restore_interrupted-v1.recovery',
          ).existsSync(),
          isFalse,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test('rollback refuses fresh V1 modified bytes with chmod drift', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final source = File(p.join(project.path, 'lib', 'mode-drift.dart'));
      source.parent.createSync(recursive: true);
      const original = 'void original() {}\n';
      const modified = 'void modified() {}\n';
      source.writeAsStringSync(original);
      _chmod(source, 0x1ed);
      final entry = QuarantineEntry(
        originalPath: source.path,
        sha256: sha256.convert(source.readAsBytesSync()).toString(),
        sizeBytes: source.lengthSync(),
        posixMode: 0x1ed,
        operationType: QuarantineOperationType.declaration,
        modifiedSha256: sha256.convert(utf8.encode(modified)).toString(),
      );
      final manager = QuarantineManager(project);
      final quarantine = await manager.createQuarantine(
        runId: 'fresh-v1-mode-drift',
        entries: [entry],
      );
      final snapshot = await manager.quarantineFile(
        file: source,
        expectedSha256: entry.sha256,
        quarantineDir: quarantine,
        originalPath: source.path,
      );
      source.writeAsStringSync(modified, flush: true);
      _chmod(source, 0x1a4);

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'fresh-v1-mode-drift',
      ]);

      expect(exitCode, 1);
      expect(source.readAsStringSync(), modified);
      expect(_posixMode(source), 0x1a4);
      expect(snapshot.existsSync(), isTrue);
      expect(
        (await manager.readManifest(quarantine)).fullRollbackVerified,
        isFalse,
      );
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'rollback refuses a V1 restore through a symlinked project parent',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      final outside = Directory.systemTemp.createTempSync('rollback_outside_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'blocked.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void blocked() {}\n';
        source.writeAsStringSync(original);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'symlink-parent',
          entries: [entry],
        );
        await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );
        source.parent.deleteSync();
        Link(p.join(project.path, 'lib')).createSync(outside.path);
        final outsideTarget = File(p.join(outside.path, 'blocked.dart'));

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'symlink-parent',
        ]);

        expect(exitCode, 1);
        expect(outsideTarget.existsSync(), isFalse);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      }
    },
  );

  test('rollback refuses a V1 entry outside the selected project', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    final outside = Directory.systemTemp.createTempSync('rollback_outside_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final external = File(p.join(outside.path, 'external.dart'));
      external.writeAsStringSync('void external() {}\n');
      final entry = QuarantineEntry(
        originalPath: external.path,
        sha256: sha256.convert(external.readAsBytesSync()).toString(),
        sizeBytes: external.lengthSync(),
      );
      final quarantine = await QuarantineManager(
        project,
      ).createQuarantine(runId: 'outside-v1', entries: [entry]);

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'outside-v1',
      ]);

      expect(exitCode, 1);
      expect(external.readAsStringSync(), 'void external() {}\n');
      expect(quarantine.existsSync(), isTrue);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    }
  });

  test('rollback refuses a quarantine recorded for another project', () async {
    final selected = Directory.systemTemp.createTempSync('rollback_selected_');
    final recorded = Directory.systemTemp.createTempSync('rollback_recorded_');
    try {
      for (final project in [selected, recorded]) {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
      }
      final source = File(p.join(recorded.path, 'lib', 'source.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void original() {}\n');

      final selectedQuarantineBase = p.join(
        selected.path,
        QuarantineManager.defaultQuarantineDir,
      );
      final manager = QuarantineManager(recorded);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'wrong-project',
        quarantineBase: selectedQuarantineBase,
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'dart:rollback_test/lib/source.dart#original',
        file: source,
        operationType: QuarantineOperationType.declaration,
      );
      source.writeAsStringSync('void modified() {}\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        selected.path,
        'wrong-project',
      ]);

      expect(exitCode, 1);
      expect(source.readAsStringSync(), 'void modified() {}\n');
    } finally {
      if (selected.existsSync()) selected.deleteSync(recursive: true);
      if (recorded.existsSync()) recorded.deleteSync(recursive: true);
    }
  });
}

Future<({QuarantineManager manager, Directory quarantine, File source})>
_createCompletedV3Run(
  Directory project, {
  required String runId,
  bool? baselinePassed = true,
  int? originalPosixMode,
}) async {
  File(
    p.join(project.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: rollback_test\n');
  final source = File(p.join(project.path, 'lib', 'source.dart'));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync('void original() {}\n');
  if (originalPosixMode != null) _chmod(source, originalPosixMode);
  final policy = VerificationPolicy.flutterDefault;
  final baselineResult = _verificationResult(
    project,
    passed: baselinePassed ?? true,
  );
  final manager = QuarantineManager(project);
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    verificationPolicyHash: policy.hash,
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: policy.hash,
      requiredStepIds: policy.requiredStepIds,
      observedStepIds: policy.requiredStepIds,
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'rollback-test-toolchain',
      available: true,
      passed: baselinePassed,
      comparisonBaseline: baselinePassed == null
          ? null
          : baselineResult.toBaselineEvidence(),
    ),
  );
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    round: 1,
    componentId: 'unit:rollback',
    findingIds: const ['finding-1'],
    caseIds: const ['case-1'],
  );
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: 'case-1',
    findingId: 'finding-1',
    file: source,
    operationType: QuarantineOperationType.declaration,
    transactionId: 'tx-1',
  );
  source.writeAsStringSync('void modified() {}\n');
  await manager.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1');
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    caseIds: const ['case-1'],
  );
  await manager.verifyTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    policyHash: policy.hash,
    requiredStepIds: policy.requiredStepIds,
    observedStepIds: policy.requiredStepIds,
  );
  await manager.commitTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
  );
  await manager.completeApplyRun(quarantineDir: quarantine);
  return (manager: manager, quarantine: quarantine, source: source);
}

VerificationResult _verificationResult(
  Directory project, {
  required bool passed,
}) {
  final policy = VerificationPolicy.flutterDefault;
  return VerificationResult(
    passed: passed,
    steps: [
      VerificationStep(
        name: policy.requiredStepIds[0],
        parserKind: policy.requiredParserKinds[0],
        passed: passed,
        exitCode: passed ? 0 : 1,
        stdout: passed
            ? 'No issues found!'
            : 'error • broken • lib/source.dart:1:1 • test_error\n'
                  '1 issue found.',
        stderr: '',
        duration: Duration.zero,
      ),
      VerificationStep(
        name: policy.requiredStepIds[1],
        parserKind: policy.requiredParserKinds[1],
        passed: true,
        exitCode: 0,
        stdout: '00:00 +1: All tests passed!',
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    failedStep: passed ? null : policy.requiredStepIds.first,
    policyHash: policy.hash,
    requiredStepIds: policy.requiredStepIds,
    requiredParserKinds: policy.requiredParserKinds,
    workingDirectory: p.normalize(p.absolute(project.path)),
    toolchainIdentity: 'rollback-test-toolchain',
  );
}

class _FixedRollbackVerifier extends VerificationRunner {
  _FixedRollbackVerifier(super.projectRoot, this.result);

  final VerificationResult result;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    return result;
  }
}

class _MutatingRollbackVerifier extends VerificationRunner {
  _MutatingRollbackVerifier(super.projectRoot, this.result, this.mutate);

  final VerificationResult result;
  final void Function() mutate;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    mutate();
    return result;
  }
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

class _UnconfirmedRollbackVerifier extends VerificationRunner {
  _UnconfirmedRollbackVerifier(super.projectRoot);

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) => Future.error(
    const ProcessTerminationUnconfirmedException(
      processId: 42,
      message: 'injected unconfirmed verifier termination',
    ),
  );
}
