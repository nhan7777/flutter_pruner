import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/manifest_authority.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/quarantine/recoverable_clean_store.dart';
import 'package:flutter_pruner/src/quarantine/rollback_recovery.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;
  late QuarantineManager manager;

  setUp(() {
    project = Directory.systemTemp.createTempSync('quarantine_manager_test_');
    manager = QuarantineManager(project);
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test('commits an applied transaction wave in one journal revision', () async {
    final baseline = _managerVerificationBaseline(project);
    final quarantine = await manager.createCaseQuarantine(
      runId: 'wave-batch',
      verificationPolicyHash: 'policy',
      baselineVerification: QuarantineVerificationEvidence(
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
        workingDirectory: p.normalize(p.absolute(project.path)),
        toolchainIdentity: 'test-toolchain',
        available: true,
        passed: true,
        comparisonBaseline: baseline,
      ),
    );
    final transactionIds = <String>[];
    for (final id in const ['a', 'b']) {
      final transactionId = 'tx-r001-$id';
      final caseId = 'case-r001-$id';
      final source = _source(project, '$id.dart', 'const before$id = true;\n');
      transactionIds.add(transactionId);
      await manager.beginTransaction(
        quarantineDir: quarantine,
        transactionId: transactionId,
        round: 1,
        componentId: 'unit:$id',
        findingIds: ['finding-$id'],
        caseIds: [caseId],
        verificationWaveId: 'wave-r001',
      );
      final prepared = await manager.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: caseId,
        findingId: 'finding-$id',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: _sha256(source),
        expectedPosixMode: _capturedPosixMode(source),
        transactionId: transactionId,
      );
      prepared.candidate.writeAsStringSync(
        'const after$id = true;\n',
        flush: true,
      );
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: caseId,
      );
      await manager.recordTransactionApplied(
        quarantineDir: quarantine,
        transactionId: transactionId,
        caseIds: [caseId],
      );
    }
    final before =
        jsonDecode(
              File(p.join(quarantine.path, 'manifest.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final candidate = VerificationResult(
      passed: true,
      failedStep: null,
      steps: const [
        VerificationStep(
          name: 'analyze',
          parserKind: VerificationOutputParserKind.humanAnalyzer,
          passed: true,
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: Duration.zero,
        ),
      ],
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
    );
    final accepted = candidate
        .compareToBaselineEvidence(baseline)
        .acceptedEvidence!;

    final committed = await manager.commitVerifiedTransactionWave(
      quarantineDir: quarantine,
      verificationWaveId: 'wave-r001',
      round: 1,
      transactionIds: transactionIds,
      acceptedVerification: accepted,
    );

    final after =
        jsonDecode(
              File(p.join(quarantine.path, 'manifest.json')).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(
      committed.map((item) => item.status),
      everyElement(QuarantineTransactionStatus.committed),
    );
    final beforeJournal = before['_journal'] as Map<String, dynamic>;
    final afterJournal = after['_journal'] as Map<String, dynamic>;
    expect(afterJournal['revision'], (beforeJournal['revision'] as int) + 1);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.verificationWaves.single.transactionIds, transactionIds);
    expect(
      manifest.cases.map((item) => item.status),
      everyElement(QuarantineCaseStatus.kept),
    );
    expect(
      await manager.readRunLifecycleState(quarantine),
      QuarantineRunLifecycleState.active,
    );
  });

  test(
    'commits same-path H1 to H2 to H3 using the wave final writer',
    () async {
      final baseline = _managerVerificationBaseline(project);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'same-path-wave',
        verificationPolicyHash: 'policy',
        baselineVerification: QuarantineVerificationEvidence(
          policyHash: 'policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
          workingDirectory: p.normalize(p.absolute(project.path)),
          toolchainIdentity: 'test-toolchain',
          available: true,
          passed: true,
          comparisonBaseline: baseline,
        ),
      );
      final source = _source(project, 'same.dart', 'H1\n');
      if (Platform.isLinux || Platform.isMacOS) _chmod(source, 0x1ed);
      for (final state in const [
        (transaction: 'tx-r001-a', caseId: 'case-a', output: 'H2\n'),
        (transaction: 'tx-r001-b', caseId: 'case-b', output: 'H3\n'),
      ]) {
        await manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: state.transaction,
          round: 1,
          componentId: state.transaction,
          findingIds: ['finding-${state.caseId}'],
          caseIds: [state.caseId],
          verificationWaveId: 'wave-r001',
        );
        final prepared = await manager.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: state.caseId,
          findingId: 'finding-${state.caseId}',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: _sha256(source),
          expectedPosixMode: _capturedPosixMode(source),
          transactionId: state.transaction,
        );
        prepared.candidate.writeAsStringSync(state.output, flush: true);
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: state.caseId,
        );
        await manager.recordTransactionApplied(
          quarantineDir: quarantine,
          transactionId: state.transaction,
          caseIds: [state.caseId],
        );
      }
      final candidate = _passingVerificationResult(project);

      await manager.commitVerifiedTransactionWave(
        quarantineDir: quarantine,
        verificationWaveId: 'wave-r001',
        round: 1,
        transactionIds: const ['tx-r001-a', 'tx-r001-b'],
        acceptedVerification: candidate
            .compareToBaselineEvidence(baseline)
            .acceptedEvidence!,
      );

      expect(source.readAsStringSync(), 'H3\n');
      final acceptedWave = (await manager.readManifest(
        quarantine,
      )).verificationWaves.single.toJson();
      expect(
        (await manager.readManifest(
          quarantine,
        )).transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.committed),
      );
      await manager.markRunRecoveryRequired(
        quarantineDir: quarantine,
        reason: 'injected whole-run recovery',
      );
      final recoveryRequired = await manager.readManifest(quarantine);
      expect(
        recoveryRequired.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.recoveryRequired),
      );
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      expect(recoveryRequired.verificationWaves.single.toJson(), acceptedWave);
      await manager.restoreRunBytes(quarantineDir: quarantine);
      await manager.verifyRunOriginalBytes(quarantineDir: quarantine);
      await manager.completeVerifiedFullRollback(
        quarantineDir: quarantine,
        reason: 'verified test rollback',
        verificationEvidence: QuarantineVerificationEvidence(
          policyHash: 'policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
          workingDirectory: p.normalize(p.absolute(project.path)),
          toolchainIdentity: 'test-toolchain',
          available: true,
          passed: true,
          comparisonBaseline: baseline,
        ),
        baselineEquivalent: true,
      );
      expect(source.readAsStringSync(), 'H1\n');
      if (Platform.isLinux || Platform.isMacOS) {
        expect(_posixMode(source), 0x1ed);
      }
      final rolledBack = await manager.readManifest(quarantine);
      expect(rolledBack.verificationWaves.single.toJson(), acceptedWave);
      expect(
        rolledBack.transactions.map((transaction) => transaction.status),
        everyElement(QuarantineTransactionStatus.rolledBackVerified),
      );
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.rolledBackVerified,
      );
    },
  );

  test(
    'snapshot drift after accepted verification has an authority terminalization kind',
    () async {
      const runId = 'snapshot-authority-terminalization';
      final quarantine = await _createCommittedRun(
        manager,
        project,
        runId: runId,
      );
      await manager.completeApplyRun(quarantineDir: quarantine);
      await manager.markRunRecoveryRequired(
        quarantineDir: quarantine,
        reason: 'fixture rollback',
      );
      await manager.restoreRunBytes(quarantineDir: quarantine);
      await manager.verifyRunOriginalBytes(quarantineDir: quarantine);
      final manifest = await manager.readManifest(quarantine);
      final applyCase = manifest.cases.single;
      final snapshot = File(
        p.join(
          quarantine.path,
          'cases',
          applyCase.caseId,
          p.relative(applyCase.entry.originalPath, from: project.path),
        ),
      );
      final originalBytes = snapshot.readAsBytesSync();
      final source = File(applyCase.entry.originalPath);
      expect(source.readAsBytesSync(), originalBytes);
      snapshot.writeAsStringSync('const corrupt = true;\n', flush: true);

      late final RollbackTerminalizationException failure;
      try {
        await manager.completeVerifiedFullRollback(
          quarantineDir: quarantine,
          reason: 'accepted verifier result',
          verificationEvidence: QuarantineVerificationEvidence(
            policyHash: 'policy',
            requiredStepIds: const ['analyze'],
            observedStepIds: const ['analyze'],
            workingDirectory: p.normalize(p.absolute(project.path)),
            toolchainIdentity: 'test-toolchain',
            available: true,
            passed: true,
            comparisonBaseline: _managerVerificationBaseline(project),
          ),
          baselineEquivalent: true,
        );
        fail(
          'Expected snapshot authority revalidation to stop terminalization.',
        );
      } on RollbackTerminalizationException catch (error) {
        failure = error;
      }

      expect(failure.kind.name, 'authoritySnapshotRevalidationFailed');
      expect(
        failure.observation?.role,
        RollbackObservedPathRole.runOriginalSnapshot,
      );
      expect(failure.observation?.path, snapshot.path);
      expect(failure.observation?.state, RollbackObservedState.byteMismatch);
      expect(source.readAsBytesSync(), originalBytes);
      expect(
        (await manager.readManifest(quarantine)).fullRollbackVerified,
        isFalse,
      );
    },
  );

  for (final crashPoint in const [
    QuarantineJournalPoint.temporaryFlushed,
    QuarantineJournalPoint.primaryMovedToPrevious,
    QuarantineJournalPoint.temporaryPromoted,
  ]) {
    test('recovers a wave commit interrupted at ${crashPoint.name}', () async {
      final staged = await _stageSingleVerificationWave(manager, project);
      var armed = true;
      manager = QuarantineManager(
        project,
        journalHook: (point) {
          if (armed && point == crashPoint) {
            armed = false;
            throw StateError('injected journal crash');
          }
        },
      );

      await expectLater(
        manager.commitVerifiedTransactionWave(
          quarantineDir: staged.quarantine,
          verificationWaveId: 'wave-r001',
          round: 1,
          transactionIds: const ['tx-r001-a'],
          acceptedVerification: staged.accepted,
        ),
        throwsStateError,
      );

      final recovered = await QuarantineManager(
        project,
      ).readManifest(staged.quarantine);
      final wasPublished =
          crashPoint != QuarantineJournalPoint.temporaryFlushed;
      expect(recovered.verificationWaves, hasLength(wasPublished ? 1 : 0));
      expect(
        recovered.transactions.single.status,
        wasPublished
            ? QuarantineTransactionStatus.committed
            : QuarantineTransactionStatus.applied,
      );
    });
  }

  test('fails closed before cleaning a stale journal candidate', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    var armed = true;
    final interrupted = QuarantineManager(
      project,
      journalHook: (point) {
        if (armed && point == QuarantineJournalPoint.temporaryFlushed) {
          armed = false;
          throw StateError('leave staged candidate');
        }
      },
    );
    await expectLater(
      interrupted.commitVerifiedTransactionWave(
        quarantineDir: staged.quarantine,
        verificationWaveId: 'wave-r001',
        round: 1,
        transactionIds: const ['tx-r001-a'],
        acceptedVerification: staged.accepted,
      ),
      throwsStateError,
    );

    final guarded = QuarantineManager(
      project,
      journalHook: (point) {
        if (point == QuarantineJournalPoint.beforeStaleCandidateCleanup) {
          throw StateError('injected cleanup crash');
        }
      },
    );
    await expectLater(
      _triggerManifestRepair(guarded, staged.quarantine),
      throwsStateError,
    );
    expect(
      File(p.join(staged.quarantine.path, 'manifest.json.tmp')).existsSync(),
      isTrue,
    );
  });

  test('rejects skipped wave rounds and inexact ordered membership', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    await expectLater(
      manager.commitVerifiedTransactionWave(
        quarantineDir: staged.quarantine,
        verificationWaveId: 'wave-r001',
        round: 1,
        transactionIds: const ['tx-r001-missing'],
        acceptedVerification: staged.accepted,
      ),
      throwsA(isA<QuarantineException>()),
    );

    final skipped = await _stageSingleVerificationWave(
      manager,
      project,
      round: 2,
    );
    await expectLater(
      manager.commitVerifiedTransactionWave(
        quarantineDir: skipped.quarantine,
        verificationWaveId: 'wave-r002',
        round: 2,
        transactionIds: const ['tx-r002-a'],
        acceptedVerification: skipped.accepted,
      ),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.toString(),
          'message',
          contains('does not follow accepted round'),
        ),
      ),
    );
  });

  test('rejects every inexact wave membership atomically', () async {
    for (final variant in const [
      'empty',
      'duplicate',
      'missing',
      'extra',
      'reorder',
      'wrong-state',
      'wrong-round',
      'wrong-wave',
      'ownership-mismatch',
    ]) {
      final staged = await _stageTwoVerificationWave(manager, project);
      var waveId = 'wave-r001';
      var round = 1;
      var transactionIds = [...staged.transactionIds];
      switch (variant) {
        case 'empty':
          transactionIds = [];
        case 'duplicate':
          transactionIds = [transactionIds.first, transactionIds.first];
        case 'missing':
          transactionIds = [transactionIds.first];
        case 'extra':
          transactionIds = [...transactionIds, 'tx-r001-extra'];
        case 'reorder':
          transactionIds = transactionIds.reversed.toList();
        case 'wrong-state':
          await manager.verifyTransaction(
            quarantineDir: staged.quarantine,
            transactionId: transactionIds.first,
            policyHash: 'policy',
            requiredStepIds: const ['analyze'],
            observedStepIds: const ['analyze'],
          );
        case 'wrong-round':
          waveId = 'wave-r002';
          round = 2;
        case 'wrong-wave':
          waveId = 'wave-r999';
        case 'ownership-mismatch':
          final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
          final decoded = jsonDecode(primary.readAsStringSync()) as Map;
          final revision = (decoded['_journal'] as Map)['revision'] as int;
          final payload = _payload(primary);
          final cases = payload['cases'] as List;
          (cases.first as Map)['transactionId'] = transactionIds.last;
          _replacePrimaryDocument(
            primary,
            _document(payload, revision: revision + 1),
          );
      }
      final before = _journalSnapshot(staged.quarantine);

      await expectLater(
        manager.commitVerifiedTransactionWave(
          quarantineDir: staged.quarantine,
          verificationWaveId: waveId,
          round: round,
          transactionIds: transactionIds,
          acceptedVerification: staged.accepted,
        ),
        throwsA(isA<QuarantineException>()),
        reason: variant,
      );

      expect(_journalSnapshot(staged.quarantine), before, reason: variant);
    }
  });

  test('historical wave evidence mismatch fails closed', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    await manager.commitVerifiedTransactionWave(
      quarantineDir: staged.quarantine,
      verificationWaveId: 'wave-r001',
      round: 1,
      transactionIds: const ['tx-r001-a'],
      acceptedVerification: staged.accepted,
    );
    final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
    final decoded = jsonDecode(primary.readAsStringSync()) as Map;
    final revision = (decoded['_journal'] as Map)['revision'] as int;
    final payload = _payload(primary);
    final waves = payload['verificationWaves'] as List;
    final wave = waves.single as Map;
    final candidate = wave['candidateEvidence'] as Map;
    candidate['policyHash'] = 'forged-policy';
    File('${primary.path}.previous').deleteSync();
    primary.writeAsStringSync(_document(payload, revision: revision + 1));

    await expectLater(
      manager.readManifest(staged.quarantine),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.toString(),
          'message',
          contains('violates the manifest verification contract'),
        ),
      ),
    );
  });

  test('historical wave with a newly failing step fails closed', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    await manager.commitVerifiedTransactionWave(
      quarantineDir: staged.quarantine,
      verificationWaveId: 'wave-r001',
      round: 1,
      transactionIds: const ['tx-r001-a'],
      acceptedVerification: staged.accepted,
    );
    final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
    final decoded = jsonDecode(primary.readAsStringSync()) as Map;
    final revision = (decoded['_journal'] as Map)['revision'] as int;
    final payload = _payload(primary);
    final waves = payload['verificationWaves'] as List;
    final candidate = (waves.single as Map)['candidateEvidence'] as Map;
    final step = (candidate['steps'] as List).single as Map;
    step
      ..['passed'] = false
      ..['exitCode'] = 1
      ..['failureEvidenceComplete'] = true
      ..['reportedFailureCount'] = 1
      ..['fingerprintCount'] = 1
      ..['fingerprintDigests'] = {'a' * 64: 1};
    _replacePrimaryDocument(
      primary,
      _document(payload, revision: revision + 1),
    );

    await expectLater(
      manager.readManifest(staged.quarantine),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.toString(),
          'message',
          contains('was not accepted against its comparison baseline'),
        ),
      ),
    );
  });

  test(
    'wave commit rejects a member without displacement atomically',
    () async {
      final staged = await _stageSingleVerificationWave(
        manager,
        project,
        displaced: false,
      );
      final before = _journalSnapshot(staged.quarantine);

      await expectLater(
        manager.commitVerifiedTransactionWave(
          quarantineDir: staged.quarantine,
          verificationWaveId: 'wave-r001',
          round: 1,
          transactionIds: const ['tx-r001-a'],
          acceptedVerification: staged.accepted,
        ),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('requires one installed displacement'),
          ),
        ),
      );

      expect(_journalSnapshot(staged.quarantine), before);
    },
  );

  test('wave commit rejects a non-installed displacement atomically', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
    final decoded = jsonDecode(primary.readAsStringSync()) as Map;
    final revision = (decoded['_journal'] as Map)['revision'] as int;
    final payload = _payload(primary);
    final displacements = payload['_caseDisplacements'] as List;
    (displacements.single as Map)['state'] = 'candidatePrepared';
    _replacePrimaryDocument(
      primary,
      _document(payload, revision: revision + 1),
    );
    final before = _journalSnapshot(staged.quarantine);

    await expectLater(
      manager.commitVerifiedTransactionWave(
        quarantineDir: staged.quarantine,
        verificationWaveId: 'wave-r001',
        round: 1,
        transactionIds: const ['tx-r001-a'],
        acceptedVerification: staged.accepted,
      ),
      throwsA(isA<QuarantineException>()),
    );

    expect(_journalSnapshot(staged.quarantine), before);
  });

  test('wave publish detects a manifest change after temp flush', () async {
    final staged = await _stageSingleVerificationWave(manager, project);
    manager = QuarantineManager(
      project,
      journalHook: (point) {
        if (point != QuarantineJournalPoint.temporaryFlushed) return;
        final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
        final decoded = jsonDecode(primary.readAsStringSync()) as Map;
        final revision = (decoded['_journal'] as Map)['revision'] as int;
        primary.writeAsStringSync(
          _document(_payload(primary), revision: revision + 1),
          flush: true,
        );
      },
    );

    await expectLater(
      manager.commitVerifiedTransactionWave(
        quarantineDir: staged.quarantine,
        verificationWaveId: 'wave-r001',
        round: 1,
        transactionIds: const ['tx-r001-a'],
        acceptedVerification: staged.accepted,
      ),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.toString(),
          'message',
          contains('changed while the verified wave was being published'),
        ),
      ),
    );
  });

  test(
    'wave publish preserves a same-revision writer before primary rename',
    () async {
      final staged = await _stageSingleVerificationWave(manager, project);
      var injectedContents = '';
      manager = QuarantineManager(
        project,
        journalHook: (point) {
          if (point != QuarantineJournalPoint.beforePrimaryMoveToPrevious) {
            return;
          }
          final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
          final decoded = jsonDecode(primary.readAsStringSync()) as Map;
          final revision = (decoded['_journal'] as Map)['revision'] as int;
          final payload = _payload(primary)..['analysisMode'] = 'package';
          injectedContents = _document(payload, revision: revision);
          primary.writeAsStringSync(injectedContents, flush: true);
        },
      );

      await expectLater(
        manager.commitVerifiedTransactionWave(
          quarantineDir: staged.quarantine,
          verificationWaveId: 'wave-r001',
          round: 1,
          transactionIds: const ['tx-r001-a'],
          acceptedVerification: staged.accepted,
        ),
        throwsA(isA<QuarantineException>()),
      );

      final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
      expect(primary.readAsStringSync(), injectedContents);
      final manifest = await manager.readManifest(staged.quarantine);
      expect(manifest.analysisMode, 'package');
      expect(manifest.verificationWaves, isEmpty);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.applied,
      );
    },
  );

  test(
    'wave publish verifies the authoritative revision after promotion',
    () async {
      final staged = await _stageSingleVerificationWave(manager, project);
      manager = QuarantineManager(
        project,
        journalHook: (point) {
          if (point != QuarantineJournalPoint.temporaryPromoted) return;
          final primary = File(p.join(staged.quarantine.path, 'manifest.json'));
          final decoded = jsonDecode(primary.readAsStringSync()) as Map;
          final revision = (decoded['_journal'] as Map)['revision'] as int;
          primary.writeAsStringSync(
            _document(_payload(primary), revision: revision + 1),
            flush: true,
          );
        },
      );

      await expectLater(
        manager.commitVerifiedTransactionWave(
          quarantineDir: staged.quarantine,
          verificationWaveId: 'wave-r001',
          round: 1,
          transactionIds: const ['tx-r001-a'],
          acceptedVerification: staged.accepted,
        ),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('changed while the verified wave was being published'),
          ),
        ),
      );
    },
  );

  test(
    'exact selection rejects an unauthorized transaction atomically',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'selection-subset',
        verificationPolicyHash: 'policy',
        selection: QuarantineSelectionEvidence(
          mode: FindingSelectionMode.exact,
          requestedFindingIds: const ['finding-a'],
          planFingerprint: 'a' * 64,
        ),
      );

      await expectLater(
        manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'tx-outside-selection',
          round: 1,
          componentId: 'unit:outside',
          findingIds: const ['finding-b'],
          caseIds: const ['case-b'],
        ),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('outside the persisted exact selection'),
          ),
        ),
      );
      expect((await manager.readManifest(quarantine)).transactions, isEmpty);
    },
  );

  test(
    'exact selection cannot complete with a requested finding missing',
    () async {
      final source = File(p.join(project.path, 'lib', 'selected.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('const before = true;\n');
      final quarantine = await manager.createCaseQuarantine(
        runId: 'selection-incomplete',
        verificationPolicyHash: 'policy',
        selection: QuarantineSelectionEvidence(
          mode: FindingSelectionMode.exact,
          requestedFindingIds: const ['finding-a', 'finding-b'],
          planFingerprint: 'b' * 64,
        ),
      );
      await manager.beginTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-a',
        round: 1,
        componentId: 'unit:a',
        findingIds: const ['finding-a'],
        caseIds: const ['case-a'],
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-a',
        findingId: 'finding-a',
        file: source,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-a',
      );
      source.writeAsStringSync('const after = true;\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-a',
      );
      await manager.recordTransactionApplied(
        quarantineDir: quarantine,
        transactionId: 'tx-a',
        caseIds: const ['case-a'],
      );
      await manager.verifyTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-a',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-a',
      );

      await expectLater(
        manager.completeApplyRun(quarantineDir: quarantine),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('missing selected findings'),
          ),
        ),
      );
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.active,
      );
    },
  );

  for (final crashPoint in const [
    QuarantineJournalPoint.temporaryFlushed,
    QuarantineJournalPoint.primaryMovedToPrevious,
    QuarantineJournalPoint.temporaryPromoted,
  ]) {
    test(
      'matching preview evidence survives ${crashPoint.name} journal recovery',
      () async {
        final evidence = QuarantineSelectionEvidence(
          mode: FindingSelectionMode.exact,
          requestedFindingIds: const ['finding-a'],
          planFingerprint: 'a' * 64,
          previewFingerprintVersion: 1,
          previewFingerprint: 'v1:${'b' * 64}',
          expectedPreviewFingerprint: 'v1:${'b' * 64}',
        );
        final quarantine = await manager.createCaseQuarantine(
          runId: 'preview-${crashPoint.name}',
          verificationPolicyHash: 'policy',
          selection: evidence,
        );
        var armed = true;
        final interrupted = QuarantineManager(
          project,
          journalHook: (point) {
            if (armed && point == crashPoint) {
              armed = false;
              throw StateError('injected preview-evidence journal crash');
            }
          },
        );

        await expectLater(
          interrupted.beginTransaction(
            quarantineDir: quarantine,
            transactionId: 'tx-preview',
            round: 1,
            componentId: 'unit:preview',
            findingIds: const ['finding-a'],
            caseIds: const ['case-preview'],
          ),
          throwsStateError,
        );

        final recovered = await QuarantineManager(
          project,
        ).readManifest(quarantine);
        expect(recovered.selection?.toJson(), evidence.toJson());
        expect(recovered.selection?.previewFingerprintVersion, 1);
        expect(recovered.selection?.previewFingerprint, 'v1:${'b' * 64}');
        expect(
          recovered.selection?.expectedPreviewFingerprint,
          'v1:${'b' * 64}',
        );
      },
    );
  }

  test(
    'rollback-facing journal updates preserve matching preview evidence',
    () async {
      final evidence = QuarantineSelectionEvidence(
        mode: FindingSelectionMode.exact,
        requestedFindingIds: const ['finding-a'],
        planFingerprint: 'a' * 64,
        previewFingerprintVersion: 1,
        previewFingerprint: 'v1:${'b' * 64}',
        expectedPreviewFingerprint: 'v1:${'b' * 64}',
      );
      final quarantine = await manager.createCaseQuarantine(
        runId: 'preview-rollback-facing',
        verificationPolicyHash: 'policy',
        selection: evidence,
      );
      await manager.beginTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-preview',
        round: 1,
        componentId: 'unit:preview',
        findingIds: const ['finding-a'],
        caseIds: const ['case-preview'],
      );

      await manager.rollbackTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-preview',
        reason: 'injected pre-mutation rollback',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );

      final restored = await manager.readManifest(quarantine);
      expect(restored.selection?.toJson(), evidence.toJson());
      expect(
        restored.transactions.single.status,
        QuarantineTransactionStatus.rolledBackVerified,
      );
    },
  );

  test('pure manifest evaluator owns the revision decision table', () {
    const revision1 = (revision: 1, payloadSha256: 'a');
    const revision2 = (revision: 2, payloadSha256: 'b');
    for (final variant in const [
      (
        primary: revision1,
        temporary: null,
        previous: null,
        authority: ManifestCandidateName.primary,
        repair: ManifestRepairAction.none,
      ),
      (
        primary: revision1,
        temporary: revision2,
        previous: null,
        authority: ManifestCandidateName.primary,
        repair: ManifestRepairAction.discardUncommittedTemporary,
      ),
      (
        primary: null,
        temporary: revision2,
        previous: revision1,
        authority: ManifestCandidateName.temporary,
        repair: ManifestRepairAction.promoteTemporary,
      ),
      (
        primary: null,
        temporary: null,
        previous: revision1,
        authority: ManifestCandidateName.previous,
        repair: ManifestRepairAction.restorePrevious,
      ),
    ]) {
      final result = evaluateManifestAuthority(
        primary: variant.primary,
        temporary: variant.temporary,
        previous: variant.previous,
        location: '/fixture',
      );

      expect(result.authority, variant.authority);
      expect(result.repairAction, variant.repair);
    }
  });

  test(
    'manifest authority inspection leaves a staged next revision untouched',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'inspect-primary-temporary',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final payload = _payload(primary)..['analysisMode'] = 'application';
      File(
        '${primary.path}.tmp',
      ).writeAsStringSync(_document(payload, revision: 2), flush: true);
      final before = _manifestCandidateSnapshot(quarantine);

      final decision = await manager.inspectManifestAuthority(quarantine);

      expect(decision.authority.name, 'primary');
      expect(decision.repairAction.name, 'discardUncommittedTemporary');
      expect(decision.revision, 1);
      expect(decision.payloadSha256, before['manifest.json']!['payloadSha256']);
      expect(_manifestCandidateSnapshot(quarantine), before);
    },
  );

  test('public manifest reads and listings never apply a repair', () async {
    final quarantine = await manager.createCaseQuarantine(
      runId: 'read-only-public-surfaces',
    );
    final primary = File(p.join(quarantine.path, 'manifest.json'));
    final payload = _payload(primary)..['analysisMode'] = 'application';
    File(
      '${primary.path}.tmp',
    ).writeAsStringSync(_document(payload, revision: 2), flush: true);
    final before = _manifestCandidateSnapshot(quarantine);

    final manifest = await manager.readManifest(quarantine);
    final listed = await manager.listQuarantines();

    expect(manifest.analysisMode, isNull);
    expect(listed.single.runId, 'read-only-public-surfaces');
    expect(_manifestCandidateSnapshot(quarantine), before);
  });

  for (final variant
      in <
        ({
          String label,
          ManifestCandidateName authority,
          ManifestRepairAction repair,
          void Function(Directory quarantine) arrange,
        })
      >[
        (
          label: 'discard',
          authority: ManifestCandidateName.primary,
          repair: ManifestRepairAction.discardUncommittedTemporary,
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
          },
        ),
        (
          label: 'promotion',
          authority: ManifestCandidateName.temporary,
          repair: ManifestRepairAction.promoteTemporary,
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
            primary.renameSync('${primary.path}.previous');
          },
        ),
        (
          label: 'restoration',
          authority: ManifestCandidateName.previous,
          repair: ManifestRepairAction.restorePrevious,
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            primary.renameSync('${primary.path}.previous');
          },
        ),
      ]) {
    test(
      'clean planning reports ${variant.label} authority without repair',
      () async {
        final quarantine = await manager.createQuarantine(
          runId: 'clean-plan-${variant.label}',
          entries: const [],
        );
        variant.arrange(quarantine);
        final before = _manifestCandidateSnapshot(quarantine);

        final plan = await manager.planCleanQuarantine(
          runId: 'clean-plan-${variant.label}',
        );

        expect(plan.targets.single.authority, variant.authority);
        expect(plan.targets.single.repairAction, variant.repair);
        expect(_manifestCandidateSnapshot(quarantine), before);
      },
    );
  }

  for (final variant
      in <({String label, void Function(Directory quarantine) arrange})>[
        (
          label: 'discard',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
          },
        ),
        (
          label: 'promotion',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
            primary.renameSync('${primary.path}.previous');
          },
        ),
        (
          label: 'restoration',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            primary.renameSync('${primary.path}.previous');
          },
        ),
      ]) {
    test('run lifecycle read is read-only for ${variant.label}', () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'lifecycle-read-${variant.label}',
        verificationPolicyHash: 'policy',
      );
      variant.arrange(quarantine);
      final before = _manifestCandidateSnapshot(quarantine);

      final lifecycle = await manager.readRunLifecycleState(quarantine);

      expect(lifecycle, QuarantineRunLifecycleState.active);
      expect(_manifestCandidateSnapshot(quarantine), before);
    });
  }

  test(
    'run lifecycle read rejects invalid authority without mutation',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'lifecycle-read-invalid',
        verificationPolicyHash: 'policy',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final payload = _payload(primary)
        ..['_runLifecycle'] = {'version': 1, 'state': 'unknown'};
      primary.writeAsStringSync(_document(payload, revision: 2), flush: true);
      final before = _manifestCandidateSnapshot(quarantine);

      await expectLater(
        manager.readRunLifecycleState(quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(_manifestCandidateSnapshot(quarantine), before);
    },
  );

  test('quarantine inventory never hides an unexpected raw child', () async {
    final base = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    )..createSync(recursive: true);
    final unexpected = File(p.join(base.path, 'unexpected.txt'))
      ..writeAsStringSync('do not omit or mutate\n', flush: true);
    final before = unexpected.readAsBytesSync();

    final inventory = await manager.inspectQuarantines();

    expect(inventory, hasLength(1));
    final inspection = inventory.single as InvalidQuarantineInspection;
    expect(inspection.path, p.normalize(unexpected.path));
    expect(inspection.errorCode, 'unexpected_entry');
    expect(unexpected.readAsBytesSync(), before);
  });

  test('clean validation shares the typed lifecycle predicate', () async {
    final quarantine = await manager.createCaseQuarantine(
      runId: 'active-empty',
      verificationPolicyHash: 'policy',
    );
    final before = _rawTreeSnapshot([quarantine]);

    final inventory = await manager.inspectQuarantines();

    final inspection = inventory.single as ValidQuarantineInspection;
    expect(inspection.lifecycle, QuarantineRunLifecycleState.active);
    expect(inspection.transactions.total, 0);
    expect(inspection.cleanable, isFalse);
    await expectLater(
      manager.validateCleanQuarantine(runId: 'active-empty'),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.message,
          'message',
          contains('active'),
        ),
      ),
    );
    expect(_rawTreeSnapshot([quarantine]), before);
  });

  test(
    'quarantine inventory projects every current and legacy raw child',
    () async {
      final currentBase = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      )..createSync(recursive: true);
      final legacyBase = Directory(
        p.join(project.path, QuarantineManager.legacyQuarantineDir),
      )..createSync(recursive: true);
      final unexpected = File(p.join(currentBase.path, '00-unexpected.txt'))
        ..writeAsStringSync('raw child\n', flush: true);
      final corrupt = Directory(p.join(currentBase.path, '01-corrupt'))
        ..createSync();
      File(
        p.join(corrupt.path, 'manifest.json'),
      ).writeAsStringSync('{broken', flush: true);
      final mismatch = await manager.createCaseQuarantine(
        runId: '02-mismatch',
        verificationPolicyHash: 'policy',
      );
      _rewritePrimaryPayload(mismatch, (payload) {
        payload['runId'] = 'different-run-id';
      });
      final foreign = await manager.createCaseQuarantine(
        runId: '03-foreign',
        verificationPolicyHash: 'policy',
      );
      _rewritePrimaryPayload(foreign, (payload) {
        payload['projectRoot'] = p.join(project.path, 'different-project');
      });
      final ambiguous = await manager.createCaseQuarantine(
        runId: '04-ambiguous',
        verificationPolicyHash: 'policy',
      );
      final ambiguousPrimary = File(p.join(ambiguous.path, 'manifest.json'));
      final ambiguousPayload = _payload(ambiguousPrimary)
        ..['analysisMode'] = 'application';
      File('${ambiguousPrimary.path}.tmp').writeAsStringSync(
        _document(ambiguousPayload, revision: 3),
        flush: true,
      );
      ambiguousPrimary.renameSync('${ambiguousPrimary.path}.previous');
      final active = await manager.createCaseQuarantine(
        runId: '05-active',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: active,
        transactionId: 'tx-active',
        round: 1,
        componentId: 'unit:active',
        findingIds: const ['finding-active'],
        caseIds: const ['case-active'],
      );
      final activePrimary = File(p.join(active.path, 'manifest.json'));
      final activeJournal =
          (jsonDecode(activePrimary.readAsStringSync()) as Map)['_journal']
              as Map;
      final activePayload = _payload(activePrimary)
        ..['analysisMode'] = 'application';
      File('${activePrimary.path}.tmp').writeAsStringSync(
        _document(
          activePayload,
          revision: (activeJournal['revision'] as int) + 1,
        ),
        flush: true,
      );
      final recovery = await manager.createCaseQuarantine(
        runId: '06-recovery',
        quarantineBase: legacyBase.path,
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: recovery,
        transactionId: 'tx-recovery',
        round: 1,
        componentId: 'unit:recovery',
        findingIds: const ['finding-recovery'],
        caseIds: const ['case-recovery'],
      );
      await manager.markRunRecoveryRequired(
        quarantineDir: recovery,
        reason: 'fixture recovery',
      );
      final completed = await _createCommittedRun(
        manager,
        project,
        runId: '07-completed',
        quarantineBase: legacyBase.path,
      );
      await manager.completeApplyRun(quarantineDir: completed);
      final rolledBack = await _createCommittedRun(
        manager,
        project,
        runId: '08-rolled-back',
        quarantineBase: legacyBase.path,
      );
      await manager.markRunRecoveryRequired(
        quarantineDir: rolledBack,
        reason: 'fixture rollback',
      );
      await manager.restoreRunBytes(quarantineDir: rolledBack);
      await manager.verifyRunOriginalBytes(quarantineDir: rolledBack);
      await manager.completeVerifiedFullRollback(
        quarantineDir: rolledBack,
        reason: 'fixture rollback',
        verificationEvidence: QuarantineVerificationEvidence(
          policyHash: 'policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
          workingDirectory: p.normalize(p.absolute(project.path)),
          toolchainIdentity: 'test-toolchain',
          available: true,
          passed: true,
          comparisonBaseline: _managerVerificationBaseline(project),
        ),
        baselineEquivalent: true,
      );
      final recoveryPath = p.normalize(p.join(legacyBase.path, '06-recovery'));
      final completedPath = p.normalize(
        p.join(legacyBase.path, '07-completed'),
      );
      final rolledBackPath = p.normalize(
        p.join(legacyBase.path, '08-rolled-back'),
      );
      final linkTarget = Directory(p.join(project.path, 'link-target'))
        ..createSync();
      final linkedPath = p.join(currentBase.path, '09-linked');
      var linked = false;
      try {
        Link(linkedPath).createSync(linkTarget.path);
        linked = true;
      } on FileSystemException {
        // Some Windows hosts do not grant symbolic-link creation authority.
      }
      final bases = [currentBase, legacyBase];
      final before = _rawTreeSnapshot(bases);

      final inventory = await manager.inspectQuarantines();

      final expectedPaths = <String>{
        p.normalize(unexpected.path),
        p.normalize(corrupt.path),
        p.normalize(mismatch.path),
        p.normalize(foreign.path),
        p.normalize(ambiguous.path),
        p.normalize(active.path),
        recoveryPath,
        completedPath,
        rolledBackPath,
        if (linked) p.normalize(linkedPath),
      };
      expect(inventory.map((item) => item.path).toSet(), expectedPaths);
      expect(inventory, hasLength(expectedPaths.length));
      final byPath = {for (final item in inventory) item.path: item};
      InvalidQuarantineInspection invalidAt(String path) =>
          byPath[p.normalize(path)]! as InvalidQuarantineInspection;
      ValidQuarantineInspection validAt(String path) =>
          byPath[p.normalize(path)]! as ValidQuarantineInspection;
      expect(invalidAt(unexpected.path).errorCode, 'unexpected_entry');
      expect(invalidAt(corrupt.path).errorCode, 'invalid_manifest');
      expect(invalidAt(mismatch.path).errorCode, 'run_id_mismatch');
      expect(invalidAt(foreign.path).errorCode, 'foreign_project');
      expect(invalidAt(ambiguous.path).errorCode, 'ambiguous_authority');
      if (linked) {
        expect(invalidAt(linkedPath).errorCode, 'symlink_entry');
      }
      for (final invalidPath in [
        unexpected.path,
        corrupt.path,
        mismatch.path,
        foreign.path,
        ambiguous.path,
        if (linked) linkedPath,
      ]) {
        final invalid = invalidAt(invalidPath);
        expect(invalid.blocksApply, isTrue);
        expect(invalid, isNot(isA<ValidQuarantineInspection>()));
      }
      final activeItem = validAt(active.path);
      expect(activeItem.runId, '05-active');
      expect(
        activeItem.authority.lifecycle,
        QuarantineRunLifecycleState.active,
      );
      expect(
        activeItem.authority.repairAction,
        ManifestRepairAction.discardUncommittedTemporary,
      );
      expect(activeItem.cleanable, isFalse);
      expect(activeItem.recoveryRequired, isFalse);
      expect(activeItem.transactions.total, 1);
      expect(activeItem.transactions.pending, 1);
      final recoveryItem = validAt(recoveryPath);
      expect(
        recoveryItem.authority.lifecycle,
        QuarantineRunLifecycleState.recoveryRequired,
      );
      expect(recoveryItem.cleanable, isFalse);
      expect(recoveryItem.recoveryRequired, isTrue);
      expect(recoveryItem.transactions.recoveryRequired, 1);
      final completedItem = validAt(completedPath);
      expect(
        completedItem.authority.lifecycle,
        QuarantineRunLifecycleState.completed,
      );
      expect(completedItem.cleanable, isFalse);
      expect(completedItem.recoveryRequired, isFalse);
      expect(completedItem.transactions.committed, 1);
      final rolledBackItem = validAt(rolledBackPath);
      expect(
        rolledBackItem.authority.lifecycle,
        QuarantineRunLifecycleState.rolledBackVerified,
      );
      expect(rolledBackItem.cleanable, isTrue);
      expect(rolledBackItem.recoveryRequired, isFalse);
      expect(rolledBackItem.entryCount, 1);
      expect(rolledBackItem.transactions.rolledBackVerified, 1);
      final attentionPaths =
          expectedPaths.where((path) => path != rolledBackPath).toList()
            ..sort();
      expect(inventory.map((item) => item.path), [
        ...attentionPaths,
        rolledBackPath,
      ]);
      expect(_rawTreeSnapshot(bases), before);
    },
  );

  test('quarantine inventory invalidates every duplicate run ID', () async {
    final currentBase = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final legacyBase = Directory(
      p.join(project.path, QuarantineManager.legacyQuarantineDir),
    );
    await manager.createCaseQuarantine(
      runId: 'duplicate',
      verificationPolicyHash: 'policy',
    );
    await manager.createCaseQuarantine(
      runId: 'duplicate',
      quarantineBase: legacyBase.path,
      verificationPolicyHash: 'policy',
    );
    final before = _rawTreeSnapshot([currentBase, legacyBase]);

    final inventory = await manager.inspectQuarantines();

    expect(inventory, hasLength(2));
    final expectedPaths = [
      p.normalize(p.join(currentBase.path, 'duplicate')),
      p.normalize(p.join(legacyBase.path, 'duplicate')),
    ]..sort();
    expect(inventory.map((item) => item.path), expectedPaths);
    for (final item in inventory) {
      final invalid = item as InvalidQuarantineInspection;
      expect(invalid.errorCode, 'duplicate_run_id');
      expect(invalid.blocksApply, isTrue);
      expect(invalid, isNot(isA<ValidQuarantineInspection>()));
    }
    expect(_rawTreeSnapshot([currentBase, legacyBase]), before);
  });

  test(
    'quarantine inventory orders ordinary valid runs deterministically',
    () async {
      final currentBase = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      );
      for (final fixture in [
        (runId: 'z-run', timestamp: DateTime.utc(2026, 8, 25, 12)),
        (runId: 'a-run', timestamp: DateTime.utc(2026, 8, 25, 12)),
        (runId: 'm-run', timestamp: DateTime.utc(2026, 8, 24, 12)),
      ]) {
        final quarantine = await manager.createQuarantine(
          runId: fixture.runId,
          entries: const [],
        );
        _rewritePrimaryPayload(quarantine, (payload) {
          payload['timestamp'] = fixture.timestamp.toIso8601String();
        });
      }
      final before = _rawTreeSnapshot([currentBase]);

      final inventory = await manager.inspectQuarantines();

      expect(
        inventory.map((item) => (item as ValidQuarantineInspection).runId),
        ['a-run', 'z-run', 'm-run'],
      );
      expect(_rawTreeSnapshot([currentBase]), before);
    },
  );

  test(
    'quarantine inventory rejects rootless legacy manifests without owned paths',
    () async {
      final base = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      );
      final empty = await manager.createQuarantine(
        runId: 'rootless-empty',
        entries: const [],
      );
      _rewritePrimaryPayload(empty, (payload) {
        payload.remove('projectRoot');
      });
      final outside = await manager.createQuarantine(
        runId: 'rootless-outside',
        entries: [
          QuarantineEntry(
            originalPath: p.join(project.parent.path, 'outside.dart'),
            sha256: 'a' * 64,
            sizeBytes: 1,
          ),
        ],
      );
      _rewritePrimaryPayload(outside, (payload) {
        payload.remove('projectRoot');
      });
      final before = _rawTreeSnapshot([base]);

      final inventory = await manager.inspectQuarantines();

      expect(inventory, hasLength(2));
      for (final item in inventory) {
        final invalid = item as InvalidQuarantineInspection;
        expect(invalid.errorCode, 'invalid_manifest');
        expect(invalid.blocksApply, isTrue);
      }
      expect(_rawTreeSnapshot([base]), before);
    },
  );

  test(
    'inventory and clean validation reject contradictory terminal journals',
    () async {
      final base = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      );
      final missingRollbackEvidence = await _createRolledBackRun(
        manager,
        project,
        runId: 'terminal-missing-evidence',
      );
      _rewritePrimaryPayload(missingRollbackEvidence, (payload) {
        final transactions = payload['transactions'] as List<dynamic>;
        (transactions.single as Map<String, dynamic>)['rollbackVerified'] =
            false;
      });
      final orphanedCase = await _createRolledBackRun(
        manager,
        project,
        runId: 'terminal-orphan',
      );
      _rewritePrimaryPayload(orphanedCase, (payload) {
        final transactions = payload['transactions'] as List<dynamic>;
        (transactions.single as Map<String, dynamic>)['caseIds'] = <String>[];
      });
      final inconsistentLifecycle = await _createRolledBackRun(
        manager,
        project,
        runId: 'terminal-lifecycle',
      );
      _rewritePrimaryPayload(inconsistentLifecycle, (payload) {
        (payload['_runLifecycle'] as Map<String, dynamic>)['state'] =
            'completed';
      });
      final before = _rawTreeSnapshot([base]);

      final inventory = await manager.inspectQuarantines();

      expect(inventory, hasLength(3));
      for (final item in inventory) {
        final invalid = item as InvalidQuarantineInspection;
        expect(invalid.errorCode, 'invalid_manifest');
      }
      for (final runId in const [
        'terminal-missing-evidence',
        'terminal-orphan',
        'terminal-lifecycle',
      ]) {
        await expectLater(
          manager.validateCleanQuarantine(runId: runId),
          throwsA(isA<QuarantineException>()),
        );
      }
      expect(_rawTreeSnapshot([base]), before);
    },
  );

  test('verified failed transaction rollback remains blocked while active or '
      'markerless', () async {
    const runId = 'verified-failed-transaction-rollback';
    final base = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final source = _source(
      project,
      'verified-failed-rollback.dart',
      'void original() {}\n',
    );
    final quarantine = await manager.createCaseQuarantine(
      runId: runId,
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

    final activeBefore = _rawTreeSnapshot([base]);
    final activeInventory = await manager.inspectQuarantines();
    final activeCleanFailure = await _captureFailure(
      () => manager.validateCleanQuarantine(runId: runId),
    );
    final activeHistoricalFailure = await _captureFailure(
      () => manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      ),
    );
    expect(_rawTreeSnapshot([base]), activeBefore);

    _removeLifecycleMarker(quarantine);
    final markerlessBefore = _rawTreeSnapshot([base]);
    final markerlessInventory = await manager.inspectQuarantines();
    final markerlessCleanFailure = await _captureFailure(
      () => manager.validateCleanQuarantine(runId: runId),
    );
    final markerlessHistoricalFailure = await _captureFailure(
      () => manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      ),
    );
    expect(_rawTreeSnapshot([base]), markerlessBefore);

    final activeInspection = activeInventory.single;
    final markerlessInspection = markerlessInventory.single;
    expect(
      (
        activeValid: activeInspection is ValidQuarantineInspection,
        activeCleanable:
            activeInspection is ValidQuarantineInspection &&
            activeInspection.cleanable,
        activeCleanRejected: activeCleanFailure is QuarantineException,
        activeHistoricalRejected:
            activeHistoricalFailure is QuarantineException,
        markerlessValid: markerlessInspection is ValidQuarantineInspection,
        markerlessCleanable:
            markerlessInspection is ValidQuarantineInspection &&
            markerlessInspection.cleanable,
        markerlessCleanRejected: markerlessCleanFailure is QuarantineException,
        markerlessHistoricalRejected:
            markerlessHistoricalFailure is QuarantineException,
      ),
      (
        activeValid: true,
        activeCleanable: false,
        activeCleanRejected: true,
        activeHistoricalRejected: true,
        markerlessValid: false,
        markerlessCleanable: false,
        markerlessCleanRejected: true,
        markerlessHistoricalRejected: true,
      ),
    );
    expect(
      (activeInspection as ValidQuarantineInspection).lifecycle,
      QuarantineRunLifecycleState.active,
    );
    expect(
      (markerlessInspection as InvalidQuarantineInspection).errorCode,
      QuarantineInspectionErrorCodes.invalidManifest,
    );
    expect(source.readAsStringSync(), 'void original() {}\n');
  });

  test(
    'markerless rollback claims without full-run proof are invalid',
    () async {
      const runId = 'markerless-rollback-without-proof';
      final base = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      );
      final quarantine = await _createRolledBackRun(
        manager,
        project,
        runId: runId,
      );
      _rewritePrimaryPayload(quarantine, (payload) {
        payload.remove('_runLifecycle');
        payload.remove('fullRollback');
      });
      final before = _rawTreeSnapshot([base]);

      final inventory = await manager.inspectQuarantines();
      final cleanFailure = await _captureFailure(
        () => manager.validateCleanQuarantine(runId: runId),
      );
      final historicalFailure = await _captureFailure(
        () => manager.ensureNoBlockingHistoricalQuarantines(
          quarantineBases: [base],
        ),
      );

      expect(_rawTreeSnapshot([base]), before);
      expect(
        (
          inventoryInvalid: inventory.single is InvalidQuarantineInspection,
          cleanRejected: cleanFailure is QuarantineException,
          historicalRejected: historicalFailure is QuarantineException,
        ),
        (inventoryInvalid: true, cleanRejected: true, historicalRejected: true),
      );
      expect(
        (inventory.single as InvalidQuarantineInspection).errorCode,
        QuarantineInspectionErrorCodes.invalidManifest,
      );
    },
  );

  test(
    'markerless full rollback evidence without verification is invalid',
    () async {
      const runId = 'markerless-unverified-full-rollback';
      final base = Directory(
        p.join(project.path, QuarantineManager.defaultQuarantineDir),
      );
      final quarantine = await manager.createCaseQuarantine(
        runId: runId,
        verificationPolicyHash: 'policy',
      );
      _rewritePrimaryPayload(quarantine, (payload) {
        payload.remove('_runLifecycle');
        payload['fullRollback'] = <String, Object?>{
          'status': 'restored',
          'verified': false,
          'restoredAtUtc': '2026-08-26T00:00:00.000Z',
        };
      });
      final before = _rawTreeSnapshot([base]);

      final inventory = await manager.inspectQuarantines();
      final cleanFailure = await _captureFailure(
        () => manager.validateCleanQuarantine(runId: runId),
      );
      final historicalFailure = await _captureFailure(
        () => manager.ensureNoBlockingHistoricalQuarantines(
          quarantineBases: [base],
        ),
      );

      expect(_rawTreeSnapshot([base]), before);
      expect(
        (
          inventoryInvalid: inventory.single is InvalidQuarantineInspection,
          cleanRejected: cleanFailure is QuarantineException,
          historicalRejected: historicalFailure is QuarantineException,
        ),
        (inventoryInvalid: true, cleanRejected: true, historicalRejected: true),
      );
      expect(inventory.single, isNot(isA<ValidQuarantineInspection>()));
      expect(
        (inventory.single as InvalidQuarantineInspection).errorCode,
        QuarantineInspectionErrorCodes.invalidManifest,
      );
    },
  );

  test('completed V3 without transactions is invalid', () async {
    const runId = 'completed-without-transactions';
    final base = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final quarantine = await manager.createCaseQuarantine(
      runId: runId,
      verificationPolicyHash: 'policy',
    );
    _rewritePrimaryPayload(quarantine, (payload) {
      payload['_runLifecycle'] = {'version': 1, 'state': 'completed'};
    });
    final before = _rawTreeSnapshot([base]);

    final inventory = await manager.inspectQuarantines();
    final cleanFailure = await _captureFailure(
      () => manager.validateCleanQuarantine(runId: runId),
    );
    final historicalFailure = await _captureFailure(
      () => manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      ),
    );

    expect(_rawTreeSnapshot([base]), before);
    expect(
      (
        inventoryInvalid: inventory.single is InvalidQuarantineInspection,
        cleanRejected: cleanFailure is QuarantineException,
        historicalRejected: historicalFailure is QuarantineException,
      ),
      (inventoryInvalid: true, cleanRejected: true, historicalRejected: true),
    );
    expect(
      (inventory.single as InvalidQuarantineInspection).errorCode,
      QuarantineInspectionErrorCodes.invalidManifest,
    );
  });

  test('terminal journal rejects duplicate transaction identities', () async {
    const runId = 'duplicate-transaction-identity';
    final base = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final quarantine = await _createRolledBackRun(
      manager,
      project,
      runId: runId,
    );
    _rewritePrimaryPayload(quarantine, (payload) {
      final cases = payload['cases'] as List<dynamic>;
      final duplicateCase =
          Map<String, dynamic>.from(cases.single as Map<String, dynamic>)
            ..['caseId'] = 'case-duplicate'
            ..['findingId'] = 'finding-duplicate';
      cases.add(duplicateCase);

      final transactions = payload['transactions'] as List<dynamic>;
      final duplicateTransaction =
          Map<String, dynamic>.from(transactions.single as Map<String, dynamic>)
            ..['findingIds'] = <String>['finding-duplicate']
            ..['caseIds'] = <String>['case-duplicate'];
      transactions.add(duplicateTransaction);
    });
    final before = _rawTreeSnapshot([base]);

    final inventory = await manager.inspectQuarantines();
    final cleanFailure = await _captureFailure(
      () => manager.validateCleanQuarantine(runId: runId),
    );
    final historicalFailure = await _captureFailure(
      () => manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      ),
    );

    expect(_rawTreeSnapshot([base]), before);
    expect(
      (
        inventoryInvalid: inventory.single is InvalidQuarantineInspection,
        cleanRejected: cleanFailure is QuarantineException,
        historicalRejected: historicalFailure is QuarantineException,
      ),
      (inventoryInvalid: true, cleanRejected: true, historicalRejected: true),
    );
    expect(
      (inventory.single as InvalidQuarantineInspection).errorCode,
      QuarantineInspectionErrorCodes.invalidManifest,
    );
  });

  test('rootless V2 without owned paths is invalid', () async {
    const runId = 'rootless-v2';
    final base = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final quarantine = await manager.createCaseQuarantine(runId: runId);
    _rewritePrimaryPayload(quarantine, (payload) {
      payload.remove('projectRoot');
    });
    final before = _rawTreeSnapshot([base]);

    final inventory = await manager.inspectQuarantines();
    final cleanFailure = await _captureFailure(
      () => manager.validateCleanQuarantine(runId: runId),
    );
    final historicalFailure = await _captureFailure(
      () => manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      ),
    );

    expect(_rawTreeSnapshot([base]), before);
    expect(
      (
        inventoryInvalid: inventory.single is InvalidQuarantineInspection,
        cleanRejected: cleanFailure is QuarantineException,
        historicalRejected: historicalFailure is QuarantineException,
      ),
      (inventoryInvalid: true, cleanRejected: true, historicalRejected: true),
    );
    expect(
      (inventory.single as InvalidQuarantineInspection).errorCode,
      QuarantineInspectionErrorCodes.invalidManifest,
    );
  });

  test(
    'quarantine inventory rejects an unsupported future manifest major',
    () async {
      final quarantine = await manager.createQuarantine(
        runId: 'future-major',
        entries: const [],
      );
      _rewritePrimaryPayload(quarantine, (payload) {
        payload['version'] = '4.0.0';
      });
      final before = _rawTreeSnapshot([quarantine]);

      final inventory = await manager.inspectQuarantines();

      final invalid = inventory.single as InvalidQuarantineInspection;
      expect(invalid.errorCode, 'invalid_manifest');
      await expectLater(
        manager.validateCleanQuarantine(runId: 'future-major'),
        throwsA(isA<QuarantineException>()),
      );
      expect(_rawTreeSnapshot([quarantine]), before);
    },
  );

  test('duplicate claims include mismatched and foreign directories', () async {
    final currentBase = Directory(
      p.join(project.path, QuarantineManager.defaultQuarantineDir),
    );
    final legacyBase = Directory(
      p.join(project.path, QuarantineManager.legacyQuarantineDir),
    );
    await manager.createCaseQuarantine(
      runId: 'claimed-run',
      verificationPolicyHash: 'policy',
    );
    final mismatched = await manager.createCaseQuarantine(
      runId: 'copied-directory',
      quarantineBase: legacyBase.path,
      verificationPolicyHash: 'policy',
    );
    _rewritePrimaryPayload(mismatched, (payload) {
      payload['runId'] = 'claimed-run';
    });
    await manager.createCaseQuarantine(
      runId: 'foreign-claim',
      verificationPolicyHash: 'policy',
    );
    final foreign = await manager.createCaseQuarantine(
      runId: 'foreign-claim',
      quarantineBase: legacyBase.path,
      verificationPolicyHash: 'policy',
    );
    _rewritePrimaryPayload(foreign, (payload) {
      payload['projectRoot'] = p.join(project.path, 'different-project');
    });
    final bases = [currentBase, legacyBase];
    final before = _rawTreeSnapshot(bases);

    final inventory = await manager.inspectQuarantines();

    final expectedPaths = [
      p.normalize(p.join(currentBase.path, 'claimed-run')),
      p.normalize(p.join(legacyBase.path, 'copied-directory')),
      p.normalize(p.join(currentBase.path, 'foreign-claim')),
      p.normalize(p.join(legacyBase.path, 'foreign-claim')),
    ]..sort();
    expect(inventory.map((item) => item.path), expectedPaths);
    for (final item in inventory) {
      final invalid = item as InvalidQuarantineInspection;
      expect(invalid.errorCode, 'duplicate_run_id');
    }
    expect(_rawTreeSnapshot(bases), before);
  });

  for (final variant
      in <
        ({
          String label,
          void Function(Directory quarantine) arrange,
          ManifestCandidateName authority,
          ManifestRepairAction repair,
          String candidateFilename,
        })
      >[
        (
          label: 'primary only',
          arrange: (_) {},
          authority: ManifestCandidateName.primary,
          repair: ManifestRepairAction.none,
          candidateFilename: 'manifest.json',
        ),
        (
          label: 'primary and previous',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final first = primary.readAsStringSync();
            File(
              '${primary.path}.previous',
            ).writeAsStringSync(first, flush: true);
            final payload = _payload(primary)..['analysisMode'] = 'application';
            primary.writeAsStringSync(
              _document(payload, revision: 2),
              flush: true,
            );
          },
          authority: ManifestCandidateName.primary,
          repair: ManifestRepairAction.none,
          candidateFilename: 'manifest.json',
        ),
        (
          label: 'temporary and previous',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
            primary.renameSync('${primary.path}.previous');
          },
          authority: ManifestCandidateName.temporary,
          repair: ManifestRepairAction.promoteTemporary,
          candidateFilename: 'manifest.json.tmp',
        ),
        (
          label: 'previous only',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            primary.renameSync('${primary.path}.previous');
          },
          authority: ManifestCandidateName.previous,
          repair: ManifestRepairAction.restorePrevious,
          candidateFilename: 'manifest.json.previous',
        ),
        (
          label: 'initial temporary only',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            primary.renameSync('${primary.path}.tmp');
          },
          authority: ManifestCandidateName.temporary,
          repair: ManifestRepairAction.promoteTemporary,
          candidateFilename: 'manifest.json.tmp',
        ),
      ]) {
    test(
      'manifest authority inspection is read-only for ${variant.label}',
      () async {
        final quarantine = await manager.createCaseQuarantine(
          runId: 'inspect-${variant.label.replaceAll(' ', '-')}',
        );
        variant.arrange(quarantine);
        final before = _manifestCandidateSnapshot(quarantine);

        final decision = await manager.inspectManifestAuthority(quarantine);

        final selected = before[variant.candidateFilename]!;
        expect(decision.authority, variant.authority);
        expect(decision.repairAction, variant.repair);
        expect(decision.revision, selected['revision']);
        expect(decision.payloadSha256, selected['payloadSha256']);
        expect(
          decision.canonicalDocument,
          jsonDecode(
            utf8.decode(base64Decode(selected['bytesBase64']! as String)),
          ),
        );
        expect(_manifestCandidateSnapshot(quarantine), before);
      },
    );
  }

  for (final variant in <({String label, void Function(File primary) corrupt})>[
    (
      label: 'checksum',
      corrupt: (primary) {
        final decoded =
            jsonDecode(primary.readAsStringSync()) as Map<String, dynamic>;
        decoded['analysisMode'] = 'application';
        primary.writeAsStringSync(jsonEncode(decoded), flush: true);
      },
    ),
    (
      label: 'schema',
      corrupt: (primary) {
        final payload = _payload(primary)..['runId'] = 7;
        primary.writeAsStringSync(_document(payload, revision: 2), flush: true);
      },
    ),
    (
      label: 'lifecycle',
      corrupt: (primary) {
        final payload = _payload(primary)
          ..['_runLifecycle'] = {'version': 1, 'state': 'unknown'};
        primary.writeAsStringSync(_document(payload, revision: 2), flush: true);
      },
    ),
    (
      label: 'displacement',
      corrupt: (primary) {
        final payload = _payload(primary)
          ..['_caseDisplacements'] = [
            {
              'version': 1,
              'caseId': 'case-a',
              'expectedSha256': 'a' * 64,
              'state': 'unknown',
            },
          ];
        primary.writeAsStringSync(_document(payload, revision: 2), flush: true);
      },
    ),
    (
      label: 'duplicate displacement',
      corrupt: (primary) {
        final displacement = {
          'version': 1,
          'caseId': 'case-a',
          'expectedSha256': 'a' * 64,
          'state': 'intent',
        };
        final payload = _payload(primary)
          ..['_caseDisplacements'] = [displacement, displacement];
        primary.writeAsStringSync(_document(payload, revision: 2), flush: true);
      },
    ),
    (
      label: 'empty file',
      corrupt: (primary) {
        primary.writeAsBytesSync(const [], flush: true);
      },
    ),
  ]) {
    test('manifest authority inspection rejects invalid ${variant.label} data '
        'without mutation', () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'inspect-invalid-${variant.label.replaceAll(' ', '-')}',
      );
      variant.corrupt(File(p.join(quarantine.path, 'manifest.json')));
      final before = _manifestCandidateSnapshot(quarantine);

      await expectLater(
        manager.inspectManifestAuthority(quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(_manifestCandidateSnapshot(quarantine), before);
    });
  }

  for (final variant
      in <({String label, void Function(Directory quarantine) arrange})>[
        (
          label: 'same-revision temporary with different payload',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 1), flush: true);
          },
        ),
        (
          label: 'same-revision previous with different payload',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary)..['analysisMode'] = 'application';
            File(
              '${primary.path}.previous',
            ).writeAsStringSync(_document(payload, revision: 1), flush: true);
          },
        ),
        (
          label: 'duplicate temporary and previous without primary',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final contents = primary.readAsStringSync();
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(contents, flush: true);
            primary.renameSync('${primary.path}.previous');
          },
        ),
        (
          label: 'temporary revision gap without predecessor',
          arrange: (quarantine) {
            final primary = File(p.join(quarantine.path, 'manifest.json'));
            final payload = _payload(primary);
            primary.deleteSync();
            File(
              '${primary.path}.tmp',
            ).writeAsStringSync(_document(payload, revision: 2), flush: true);
          },
        ),
      ]) {
    test('manifest authority inspection rejects ${variant.label} without '
        'mutation', () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'inspect-ambiguous-${variant.label.hashCode.abs()}',
      );
      variant.arrange(quarantine);
      final before = _manifestCandidateSnapshot(quarantine);

      await expectLater(
        manager.inspectManifestAuthority(quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(_manifestCandidateSnapshot(quarantine), before);
    });
  }

  for (final variant in const [
    (
      label: 'primary and temporary',
      suffix: '.tmp',
      repair: ManifestRepairAction.discardUncommittedTemporary,
    ),
    (
      label: 'primary and previous',
      suffix: '.previous',
      repair: ManifestRepairAction.none,
    ),
  ]) {
    test('manifest authority inspection accepts byte-identical duplicate '
        'revisions for ${variant.label}', () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'inspect-duplicate-${variant.suffix.substring(1)}',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      File(
        '${primary.path}${variant.suffix}',
      ).writeAsBytesSync(primary.readAsBytesSync(), flush: true);
      final before = _manifestCandidateSnapshot(quarantine);

      final decision = await manager.inspectManifestAuthority(quarantine);

      expect(decision.authority, ManifestCandidateName.primary);
      expect(decision.repairAction, variant.repair);
      expect(_manifestCandidateSnapshot(quarantine), before);
    });
  }

  test(
    'manifest authority projection retains typed lifecycle immutably',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'inspect-lifecycle',
        verificationPolicyHash: 'policy',
      );
      final before = _manifestCandidateSnapshot(quarantine);

      final decision = await manager.inspectManifestAuthority(quarantine);

      expect(decision.lifecycle, QuarantineRunLifecycleState.active);
      expect(
        () => decision.canonicalDocument['runId'] = 'changed',
        throwsUnsupportedError,
      );
      final lifecycle =
          decision.canonicalDocument['_runLifecycle'] as Map<String, Object?>;
      expect(() => lifecycle['state'] = 'changed', throwsUnsupportedError);
      expect(_manifestCandidateSnapshot(quarantine), before);
    },
  );

  test(
    'manifest authority decision defensively owns every projected collection',
    () {
      final declarationIds = <String>['declaration-a'];
      final findingIds = <String>['finding-a'];
      final caseIds = <String>['case-a'];
      final acceptedRiskCodes = <String>['risk-a'];
      final entries = <QuarantineEntry>[
        QuarantineEntry(
          originalPath: '/project/lib/a.dart',
          sha256: 'a' * 64,
          sizeBytes: 1,
          declarationIds: declarationIds,
        ),
      ];
      final transactions = <QuarantineTransaction>[
        QuarantineTransaction(
          transactionId: 'tx-a',
          round: 1,
          componentId: 'unit:a',
          findingIds: findingIds,
          caseIds: caseIds,
          status: QuarantineTransactionStatus.pending,
        ),
      ];
      final manifest = QuarantineManifest(
        runId: 'caller-owned',
        timestamp: DateTime.utc(2026, 8, 25),
        entries: entries,
        transactions: transactions,
        acceptedRiskCodes: acceptedRiskCodes,
      );
      final nested = <String, Object?>{'state': 'original'};
      final items = <Object?>['original'];
      final canonical = <String, Object?>{
        'runId': 'caller-owned',
        'nested': nested,
        'items': items,
      };

      final decision = ManifestAuthorityDecision(
        manifest: manifest,
        revision: 1,
        payloadSha256: 'b' * 64,
        lifecycle: null,
        authority: ManifestCandidateName.primary,
        repairAction: ManifestRepairAction.none,
        canonicalDocument: canonical,
      );
      declarationIds.add('changed');
      findingIds.add('changed');
      caseIds.add('changed');
      acceptedRiskCodes.add('changed');
      entries.clear();
      transactions.clear();
      canonical['runId'] = 'changed';
      nested['state'] = 'changed';
      items.add('changed');

      expect(decision.manifest.entries.single.declarationIds, [
        'declaration-a',
      ]);
      expect(decision.manifest.transactions.single.findingIds, ['finding-a']);
      expect(decision.manifest.transactions.single.caseIds, ['case-a']);
      expect(decision.manifest.acceptedRiskCodes, ['risk-a']);
      expect(decision.canonicalDocument['runId'], 'caller-owned');
      expect(decision.canonicalDocument['nested'], {'state': 'original'});
      expect(decision.canonicalDocument['items'], ['original']);
      expect(decision.manifest.entries.clear, throwsUnsupportedError);
      expect(decision.manifest.transactions.clear, throwsUnsupportedError);
      expect(decision.manifest.acceptedRiskCodes.clear, throwsUnsupportedError);
      expect(
        decision.manifest.entries.single.declarationIds!.clear,
        throwsUnsupportedError,
      );
      expect(
        decision.manifest.transactions.single.findingIds.clear,
        throwsUnsupportedError,
      );
      expect(
        () => decision.canonicalDocument['runId'] = 'changed-again',
        throwsUnsupportedError,
      );
      expect(
        () =>
            (decision.canonicalDocument['nested']!
                    as Map<String, Object?>)['state'] =
                'changed-again',
        throwsUnsupportedError,
      );
      expect(
        () => (decision.canonicalDocument['items']! as List<Object?>).add(
          'changed-again',
        ),
        throwsUnsupportedError,
      );
    },
  );

  for (final version in const ['1.0.0', '2.0.0', '3.0.0']) {
    test(
      'manifest authority inspection preserves manifest v$version',
      () async {
        final quarantine = switch (version) {
          '1.0.0' => await manager.createQuarantine(
            runId: 'inspect-v1',
            entries: const [],
          ),
          '2.0.0' => await manager.createCaseQuarantine(runId: 'inspect-v2'),
          _ => await manager.createCaseQuarantine(
            runId: 'inspect-v3',
            verificationPolicyHash: 'policy',
          ),
        };
        final before = _manifestCandidateSnapshot(quarantine);

        final decision = await manager.inspectManifestAuthority(quarantine);

        expect(decision.canonicalDocument['version'], version);
        expect(_manifestCandidateSnapshot(quarantine), before);
      },
    );
  }

  test(
    'manifest resolver preserves a replacement temporary before discard',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'resolver-temporary-drift',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final temporary = File('${primary.path}.tmp');
      final stagedPayload = _payload(primary)..['analysisMode'] = 'application';
      final staged = _document(stagedPayload, revision: 2);
      temporary.writeAsStringSync(staged, flush: true);
      final primaryBytes = primary.readAsBytesSync();
      final replacementPayload = _payload(primary)
        ..['analysisMode'] = 'package';
      final replacement = _document(replacementPayload, revision: 2);
      final guarded = QuarantineManager(
        project,
        journalHook: (point) {
          if (point == QuarantineJournalPoint.beforeStaleCandidateCleanup) {
            temporary.writeAsStringSync(replacement, flush: true);
          }
        },
      );

      await expectLater(
        _triggerManifestRepair(guarded, quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(primary.readAsBytesSync(), primaryBytes);
      expect(temporary.readAsStringSync(), replacement);
    },
  );

  test(
    'manifest resolver detects primary drift after declared repair',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'resolver-primary-drift',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final temporary = File('${primary.path}.tmp');
      final stagedPayload = _payload(primary)..['analysisMode'] = 'application';
      final staged = _document(stagedPayload, revision: 2);
      temporary.writeAsStringSync(staged, flush: true);
      final replacementPayload = _payload(primary)
        ..['analysisMode'] = 'package';
      final replacement = _document(replacementPayload, revision: 2);
      final guarded = QuarantineManager(
        project,
        journalHook: (point) {
          if (point == QuarantineJournalPoint.beforeStaleCandidateCleanup) {
            primary.writeAsStringSync(replacement, flush: true);
          }
        },
      );

      await expectLater(
        _triggerManifestRepair(guarded, quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(primary.readAsStringSync(), replacement);
      expect(temporary.readAsStringSync(), staged);
    },
  );

  test(
    'manifest resolver preserves a replaced candidate before promotion',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'resolver-promotion-drift',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final temporary = File('${primary.path}.tmp');
      final previous = File('${primary.path}.previous');
      final stagedPayload = _payload(primary)..['analysisMode'] = 'application';
      temporary.writeAsStringSync(
        _document(stagedPayload, revision: 2),
        flush: true,
      );
      primary.renameSync(previous.path);
      final previousBytes = previous.readAsBytesSync();
      final replacementPayload = _payload(previous)
        ..['analysisMode'] = 'package';
      final replacement = _document(replacementPayload, revision: 2);
      final guarded = QuarantineManager(
        project,
        journalHook: (point) {
          if (point ==
              QuarantineJournalPoint.beforeAuthorityRepairRevalidation) {
            temporary.writeAsStringSync(replacement, flush: true);
          }
        },
      );

      await expectLater(
        _triggerManifestRepair(guarded, quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(primary.existsSync(), isFalse);
      expect(temporary.readAsStringSync(), replacement);
      expect(previous.readAsBytesSync(), previousBytes);
    },
  );

  test('manifest resolver never overwrites a destination appearing before '
      'promotion', () async {
    final quarantine = await manager.createCaseQuarantine(
      runId: 'resolver-promotion-destination',
    );
    final primary = File(p.join(quarantine.path, 'manifest.json'));
    final temporary = File('${primary.path}.tmp');
    final previous = File('${primary.path}.previous');
    final stagedPayload = _payload(primary)..['analysisMode'] = 'application';
    final staged = _document(stagedPayload, revision: 2);
    temporary.writeAsStringSync(staged, flush: true);
    primary.renameSync(previous.path);
    final intruderPayload = _payload(previous)..['analysisMode'] = 'package';
    final intruder = _document(intruderPayload, revision: 3);
    final guarded = QuarantineManager(
      project,
      journalHook: (point) {
        if (point == QuarantineJournalPoint.beforeAuthorityRepairRevalidation) {
          primary.writeAsStringSync(intruder, flush: true);
        }
      },
    );

    await expectLater(
      _triggerManifestRepair(guarded, quarantine),
      throwsA(isA<QuarantineException>()),
    );

    expect(primary.readAsStringSync(), intruder);
    expect(temporary.readAsStringSync(), staged);
    expect(previous.existsSync(), isTrue);
  });

  test(
    'manifest resolver preserves a replaced previous before restoration',
    () async {
      final quarantine = await manager.createCaseQuarantine(
        runId: 'resolver-restoration-drift',
      );
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final previous = File('${primary.path}.previous');
      primary.renameSync(previous.path);
      final replacementPayload = _payload(previous)
        ..['analysisMode'] = 'package';
      final replacement = _document(replacementPayload, revision: 1);
      final guarded = QuarantineManager(
        project,
        journalHook: (point) {
          if (point ==
              QuarantineJournalPoint.beforeAuthorityRepairRevalidation) {
            previous.writeAsStringSync(replacement, flush: true);
          }
        },
      );

      await expectLater(
        _triggerManifestRepair(guarded, quarantine),
        throwsA(isA<QuarantineException>()),
      );

      expect(primary.existsSync(), isFalse);
      expect(previous.readAsStringSync(), replacement);
    },
  );

  test(
    'manifest resolver applies the inspected repair to the same document',
    () async {
      for (final layout in const [
        'primary',
        'primary-previous',
        'primary-temporary',
        'temporary-previous',
        'previous',
        'temporary',
      ]) {
        final quarantine = await manager.createCaseQuarantine(
          runId: 'resolver-$layout',
        );
        final primary = File(p.join(quarantine.path, 'manifest.json'));
        final temporary = File('${primary.path}.tmp');
        final previous = File('${primary.path}.previous');
        final original = primary.readAsStringSync();
        final nextPayload = _payload(primary)..['analysisMode'] = 'application';
        final next = _document(nextPayload, revision: 2);
        switch (layout) {
          case 'primary':
            break;
          case 'primary-previous':
            previous.writeAsStringSync(original, flush: true);
            primary.writeAsStringSync(next, flush: true);
          case 'primary-temporary':
            temporary.writeAsStringSync(next, flush: true);
          case 'temporary-previous':
            temporary.writeAsStringSync(next, flush: true);
            primary.renameSync(previous.path);
          case 'previous':
            primary.renameSync(previous.path);
          case 'temporary':
            primary.renameSync(temporary.path);
        }
        final before = _manifestCandidateSnapshot(quarantine);
        final decision = await manager.inspectManifestAuthority(quarantine);
        expect(_manifestCandidateSnapshot(quarantine), before, reason: layout);
        final selectedName = switch (decision.authority) {
          ManifestCandidateName.primary => 'manifest.json',
          ManifestCandidateName.temporary => 'manifest.json.tmp',
          ManifestCandidateName.previous => 'manifest.json.previous',
        };
        final selectedBytes = base64Decode(
          before[selectedName]!['bytesBase64']! as String,
        );

        await _triggerManifestRepair(manager, quarantine);
        final resolved = await manager.readManifest(quarantine);

        expect(primary.existsSync(), isTrue, reason: layout);
        expect(temporary.existsSync(), isFalse, reason: layout);
        expect(previous.readAsBytesSync(), selectedBytes, reason: layout);
        expect(resolved.runId, decision.manifest.runId, reason: layout);
        expect(resolved.timestamp, decision.manifest.timestamp, reason: layout);
        expect(
          resolved.analysisMode,
          decision.manifest.analysisMode,
          reason: layout,
        );
        expect(
          resolved.transactions.single.transactionId,
          'tx-repair-probe',
          reason: layout,
        );
      }
    },
  );

  test(
    'primary discards a fully written but uncommitted next manifest',
    () async {
      final quarantine = await manager.createCaseQuarantine(runId: 'staged');
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final payload = _payload(primary)..['analysisMode'] = 'application';
      File(
        '${primary.path}.tmp',
      ).writeAsStringSync(_document(payload, revision: 2), flush: true);

      await _triggerManifestRepair(manager, quarantine);
      final manifest = await manager.readManifest(quarantine);

      expect(manifest.analysisMode, isNull);
      expect(File('${primary.path}.tmp').existsSync(), isFalse);
      expect(primary.existsSync(), isTrue);
    },
  );

  test(
    'previous plus sequential tmp promotes the fully written next state',
    () async {
      final quarantine = await manager.createCaseQuarantine(runId: 'promote');
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final payload = _payload(primary)..['analysisMode'] = 'application';
      final temporary = File('${primary.path}.tmp')
        ..writeAsStringSync(_document(payload, revision: 2), flush: true);
      primary.renameSync('${primary.path}.previous');

      await _triggerManifestRepair(manager, quarantine);
      final manifest = await manager.readManifest(quarantine);

      expect(manifest.analysisMode, 'application');
      expect(primary.existsSync(), isTrue);
      expect(temporary.existsSync(), isFalse);
    },
  );

  test('primary plus previous keeps the newer authoritative primary', () async {
    final quarantine = await manager.createCaseQuarantine(
      runId: 'primary-wins',
      verificationPolicyHash: 'policy',
    );
    await manager.beginTransaction(
      quarantineDir: quarantine,
      transactionId: 'tx-1',
      round: 1,
      componentId: 'unit:1',
      findingIds: const ['finding'],
      caseIds: const ['case-1'],
    );

    final manifest = await manager.readManifest(quarantine);

    expect(manifest.transactions.single.transactionId, 'tx-1');
    expect(
      File(p.join(quarantine.path, 'manifest.json.previous')).existsSync(),
      isTrue,
    );
  });

  test('corrupt or ambiguous manifest candidates fail closed', () async {
    final corrupt = await manager.createCaseQuarantine(runId: 'corrupt');
    final corruptPrimary = File(p.join(corrupt.path, 'manifest.json'));
    File('${corruptPrimary.path}.tmp').writeAsStringSync('{broken');
    await expectLater(
      manager.readManifest(corrupt),
      throwsA(isA<QuarantineException>()),
    );

    final ambiguous = await manager.createCaseQuarantine(runId: 'ambiguous');
    final ambiguousPrimary = File(p.join(ambiguous.path, 'manifest.json'));
    final payload = _payload(ambiguousPrimary)
      ..['analysisMode'] = 'application';
    File(
      '${ambiguousPrimary.path}.tmp',
    ).writeAsStringSync(_document(payload, revision: 3), flush: true);
    ambiguousPrimary.renameSync('${ambiguousPrimary.path}.previous');
    await expectLater(
      manager.readManifest(ambiguous),
      throwsA(isA<QuarantineException>()),
    );
  });

  test(
    'historical preflight allows committed and blocks unsafe ledgers',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      );
      final source = File(p.join(project.path, 'lib', 'value.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('const before = true;\n');
      final committed = await manager.createCaseQuarantine(
        runId: 'committed',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: committed,
        transactionId: 'tx-committed',
        round: 1,
        componentId: 'unit:committed',
        findingIds: const ['finding'],
        caseIds: const ['case-committed'],
      );
      await manager.beginCase(
        quarantineDir: committed,
        caseId: 'case-committed',
        findingId: 'finding',
        file: source,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-committed',
      );
      source.writeAsStringSync('const after = true;\n');
      await manager.recordCaseApplied(
        quarantineDir: committed,
        caseId: 'case-committed',
      );
      await manager.recordTransactionApplied(
        quarantineDir: committed,
        transactionId: 'tx-committed',
        caseIds: const ['case-committed'],
      );
      await manager.verifyTransaction(
        quarantineDir: committed,
        transactionId: 'tx-committed',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: committed,
        transactionId: 'tx-committed',
      );
      await manager.completeApplyRun(quarantineDir: committed);
      expect(
        await manager.readRunLifecycleState(committed),
        QuarantineRunLifecycleState.completed,
      );

      await manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      );

      final pending = await manager.createCaseQuarantine(
        runId: 'pending',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: pending,
        transactionId: 'tx-pending',
        round: 1,
        componentId: 'unit:pending',
        findingIds: const ['pending-finding'],
        caseIds: const ['pending-case'],
      );
      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('lifecycle is active'),
          ),
        ),
      );
    },
  );

  test(
    'historical preflight blocks committed transactions without run completion',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      );
      final source = File(p.join(project.path, 'lib', 'interrupted.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('const before = true;\n');
      final interrupted = await manager.createCaseQuarantine(
        runId: 'interrupted-after-commit',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-committed-before-crash',
        round: 1,
        componentId: 'unit:interrupted',
        findingIds: const ['finding'],
        caseIds: const ['case-interrupted'],
      );
      await manager.beginCase(
        quarantineDir: interrupted,
        caseId: 'case-interrupted',
        findingId: 'finding',
        file: source,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-committed-before-crash',
      );
      source.writeAsStringSync('const after = true;\n');
      await manager.recordCaseApplied(
        quarantineDir: interrupted,
        caseId: 'case-interrupted',
      );
      await manager.recordTransactionApplied(
        quarantineDir: interrupted,
        transactionId: 'tx-committed-before-crash',
        caseIds: const ['case-interrupted'],
      );
      await manager.verifyTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-committed-before-crash',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: interrupted,
        transactionId: 'tx-committed-before-crash',
      );

      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('completion'),
          ),
        ),
      );
    },
  );

  test(
    'uncommitted completion tmp is discarded and active run stays blocked',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      );
      final interrupted = await _createCommittedRun(
        manager,
        project,
        runId: 'completion-not-authoritative',
      );
      final primary = File(p.join(interrupted.path, 'manifest.json'));
      final document = jsonDecode(primary.readAsStringSync()) as Map;
      final revision = ((document['_journal'] as Map)['revision'] as int);
      final payload = _payload(primary)
        ..['_runLifecycle'] = {'version': 1, 'state': 'completed'};
      File(
        '${primary.path}.tmp',
      ).writeAsStringSync(_document(payload, revision: revision + 1));

      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('completion'),
          ),
        ),
      );
      expect(
        await manager.readRunLifecycleState(interrupted),
        QuarantineRunLifecycleState.active,
      );
      expect(File('${primary.path}.tmp').existsSync(), isFalse);
    },
  );

  test(
    'previous active plus completed tmp promotes terminal completion',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      );
      final interrupted = await _createCommittedRun(
        manager,
        project,
        runId: 'completion-promoted',
      );
      final primary = File(p.join(interrupted.path, 'manifest.json'));
      final document = jsonDecode(primary.readAsStringSync()) as Map;
      final revision = ((document['_journal'] as Map)['revision'] as int);
      final payload = _payload(primary)
        ..['_runLifecycle'] = {'version': 1, 'state': 'completed'};
      File(
        '${primary.path}.tmp',
      ).writeAsStringSync(_document(payload, revision: revision + 1));
      final previous = File('${primary.path}.previous');
      if (previous.existsSync()) previous.deleteSync();
      primary.renameSync(previous.path);

      await manager.ensureNoBlockingHistoricalQuarantines(
        quarantineBases: [base],
      );

      expect(primary.existsSync(), isTrue);
      expect(
        await manager.readRunLifecycleState(interrupted),
        QuarantineRunLifecycleState.completed,
      );
    },
  );

  test(
    'markerless committed V3 remains blocked after byte-only rollback',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      );
      final legacy = await _createCommittedRun(
        manager,
        project,
        runId: 'legacy-v3',
      );
      _removeLifecycleMarker(legacy);

      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('no run-level completion marker'),
          ),
        ),
      );

      await manager.restore(quarantineDir: legacy, runId: 'legacy-v3');
      _removeLifecycleMarker(legacy);
      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('no run-level completion marker'),
          ),
        ),
      );
    },
  );

  test(
    'historical preflight blocks invalid manifests and recovery bytes',
    () async {
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      )..createSync(recursive: true);
      final invalid = Directory(p.join(base.path, 'invalid'))
        ..createSync(recursive: true);
      File(p.join(invalid.path, 'manifest.json')).writeAsStringSync('{broken');
      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(isA<QuarantineException>()),
      );

      invalid.deleteSync(recursive: true);
      final empty = await manager.createCaseQuarantine(
        runId: 'recovery-artifacts',
        verificationPolicyHash: 'policy',
      );
      final recovery = File(p.join(empty.path, 'recovery', 'bytes'));
      recovery.parent.createSync(recursive: true);
      recovery.writeAsBytesSync([0, 1, 2]);
      await expectLater(
        manager.ensureNoBlockingHistoricalQuarantines(quarantineBases: [base]),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.toString(),
            'message',
            contains('Recovery artifacts'),
          ),
        ),
      );
    },
  );

  test(
    'edit immediately before source rename is preserved and aborts',
    () async {
      final source = _source(
        project,
        'pre-rename.dart',
        'const original = 1;\n',
      );
      const userBytes = 'const userEdit = 2;\n';
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point == QuarantineDisplacementPoint.beforeSourceRename) {
            context.source.writeAsStringSync(userBytes, flush: true);
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'pre-rename-edit',
      );

      await expectLater(
        hooked.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: expected,
          transactionId: 'tx-1',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), userBytes);
      final recoveryFiles = Directory(
        p.join(quarantine.path, 'recovery', 'displacement'),
      ).listSync(recursive: true).whereType<File>().toList();
      expect(recoveryFiles, hasLength(1));
      expect(recoveryFiles.single.readAsStringSync(), userBytes);
      final promoted = await hooked.promotedBackupForCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
      );
      expect(promoted!.readAsStringSync(), userBytes);
    },
  );

  test(
    'chmod immediately before source rename is preserved and aborts',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final source = _source(
        project,
        'pre-rename-mode.dart',
        'const original = 1;\n',
      );
      _chmod(source, 0x1ed);
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point == QuarantineDisplacementPoint.beforeSourceRename) {
            _chmod(context.source, 0x1a4);
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'pre-rename-mode',
      );

      await expectLater(
        hooked.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: expected,
          expectedPosixMode: 0x1ed,
          transactionId: 'tx-1',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), 'const original = 1;\n');
      expect(_posixMode(source), 0x1a4);
      final recoveryFiles = Directory(
        p.join(quarantine.path, 'recovery', 'displacement'),
      ).listSync(recursive: true).whereType<File>().toList();
      expect(recoveryFiles, hasLength(1));
      expect(_posixMode(recoveryFiles.single), 0x1a4);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  for (final interruption in <({Exception error, String label})>[
    (
      error: const ProcessCancellationConfirmedException(
        ProcessSignal.sigterm,
        91,
      ),
      label: 'confirmed cancellation',
    ),
    (
      error: const ProcessTerminationUnconfirmedException(
        processId: 92,
        message: 'injected chmod termination uncertainty',
        triggerSignal: ProcessSignal.sigint,
      ),
      label: 'unconfirmed termination',
    ),
  ]) {
    test(
      'candidate chmod ${interruption.label} preserves authority and marks recovery',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        const original = 'const original = 1;\n';
        final source = _source(project, 'chmod-interrupted.dart', original);
        _chmod(source, 0x1ed);
        final expected = _sha256(source);
        final permissionRunner = _CancellationAtPermission(
          failAt: 2,
          cancellation: interruption.error,
        );
        final hooked = QuarantineManager(
          project,
          permissionProcessRunner: permissionRunner,
        );
        final quarantine = await _beginDisplacementTransaction(
          hooked,
          source,
          runId: 'chmod-interrupted-${permissionRunner.processId}',
        );

        await expectLater(
          hooked.beginDisplacedCase(
            quarantineDir: quarantine,
            caseId: 'case-1',
            findingId: 'finding-1',
            file: source,
            operationType: QuarantineOperationType.declaration,
            expectedSha256: expected,
            expectedPosixMode: 0x1ed,
            transactionId: 'tx-1',
          ),
          throwsA(same(interruption.error)),
        );

        expect(permissionRunner.invocationCount, 2);
        expect(source.existsSync(), isFalse);
        final promoted = await hooked.promotedBackupForCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
        );
        expect(promoted, isNotNull);
        expect(promoted!.readAsStringSync(), original);
        expect(_posixMode(promoted), 0x1ed);
        expect(
          await hooked.readRunLifecycleState(quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      },
    );
  }

  for (final interruption in <({Exception error, String label})>[
    (
      error: const ProcessCancellationConfirmedException(
        ProcessSignal.sigterm,
        93,
      ),
      label: 'confirmed cancellation',
    ),
    (
      error: const ProcessTerminationUnconfirmedException(
        processId: 94,
        message: 'injected install chmod termination uncertainty',
        triggerSignal: ProcessSignal.sigint,
      ),
      label: 'unconfirmed termination',
    ),
  ]) {
    test(
      'install chmod ${interruption.label} preserves displaced paths and recovery',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        const original = 'const original = 1;\n';
        const candidateBytes = 'const candidate = 2;\n';
        final source = _source(
          project,
          'install-chmod-interrupted.dart',
          original,
        );
        _chmod(source, 0x1ed);
        final expected = _sha256(source);
        final permissionRunner = _CancellationAtPermission(
          failAt: 3,
          cancellation: interruption.error,
        );
        final hooked = QuarantineManager(
          project,
          permissionProcessRunner: permissionRunner,
        );
        final quarantine = await _beginDisplacementTransaction(
          hooked,
          source,
          runId: 'install-chmod-${permissionRunner.processId}',
        );
        final prepared = await hooked.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: expected,
          expectedPosixMode: 0x1ed,
          transactionId: 'tx-1',
        );
        prepared.candidate.writeAsStringSync(candidateBytes, flush: true);
        _chmod(prepared.candidate, 0x1a4);

        await expectLater(
          hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
          throwsA(same(interruption.error)),
        );

        expect(permissionRunner.invocationCount, 3);
        expect(source.existsSync(), isFalse);
        expect(prepared.candidate.readAsStringSync(), candidateBytes);
        expect(prepared.promotedBackup.readAsStringSync(), original);
        expect(_posixMode(prepared.promotedBackup), 0x1ed);
        expect(
          await hooked.readRunLifecycleState(quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      },
    );
  }

  for (final point in [
    QuarantineDisplacementPoint.beforeSourceRename,
    QuarantineDisplacementPoint.afterSourceRename,
  ]) {
    test('crash at ${point.name} restores the original bytes', () async {
      const original = 'const original = 1;\n';
      final source = _source(project, '${point.name}.dart', original);
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point == point) {
            throw StateError('injected ${point.name} crash');
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'crash-${point.name}',
      );

      await expectLater(
        hooked.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: expected,
          transactionId: 'tx-1',
        ),
        throwsStateError,
      );

      await hooked.restoreRunBytes(quarantineDir: quarantine);
      expect(source.readAsStringSync(), original);
      final promoted = await hooked.promotedBackupForCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
      );
      expect(promoted!.readAsStringSync(), original);
    });
  }

  test('source recreation after rename preserves both paths', () async {
    const original = 'const original = 1;\n';
    const recreated = 'const recreatedByUser = 2;\n';
    final source = _source(project, 'recreated.dart', original);
    final expected = _sha256(source);
    final hooked = QuarantineManager(
      project,
      displacementHook: (context) {
        if (context.point == QuarantineDisplacementPoint.afterSourceRename) {
          context.source.writeAsStringSync(recreated, flush: true);
        }
      },
    );
    final quarantine = await _beginDisplacementTransaction(
      hooked,
      source,
      runId: 'recreated-source',
    );

    await expectLater(
      hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      ),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );

    expect(source.readAsStringSync(), recreated);
    final promoted = await hooked.promotedBackupForCase(
      quarantineDir: quarantine,
      caseId: 'case-1',
    );
    expect(promoted!.readAsStringSync(), original);
    await expectLater(
      hooked.restoreRunBytes(quarantineDir: quarantine),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );
    expect(source.readAsStringSync(), recreated);
    expect(promoted.readAsStringSync(), original);
  });

  test(
    'source recreation before candidate install is never overwritten',
    () async {
      const original = 'const original = 1;\n';
      const recreated = 'const recreatedByUser = 2;\n';
      final source = _source(project, 'install-race.dart', original);
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point ==
              QuarantineDisplacementPoint.beforeCandidateInstall) {
            context.source.writeAsStringSync(recreated, flush: true);
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'install-race',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(
        'const candidate = 3;\n',
        flush: true,
      );

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), recreated);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(prepared.candidate.existsSync(), isTrue);
    },
  );

  test(
    'source recreation after target preflight wins no-replace publish',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      const recreated = 'const recreated = 3;\n';
      final source = _source(project, 'publish-race.dart', original);
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point ==
              QuarantineDisplacementPoint.afterCandidateTargetPreflight) {
            context.source.writeAsStringSync(recreated, flush: true);
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'publish-race',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), recreated);
      expect(prepared.candidate.readAsStringSync(), candidate);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test(
    'writer observing candidate publish is never silently overwritten',
    () async {
      const original = 'const original = 1;\n';
      const userBytes = 'user-owned-bytes';
      final source = _source(project, 'publish-visibility.dart', original);
      final expected = _sha256(source);
      Future<void>? writer;
      final hooked = QuarantineManager(
        project,
        displacementHook: (context) async {
          if (context.point ==
              QuarantineDisplacementPoint.beforeCandidateInstall) {
            writer = () async {
              while (FileSystemEntity.typeSync(
                    context.source.path,
                    followLinks: false,
                  ) ==
                  FileSystemEntityType.notFound) {
                await Future<void>.delayed(Duration.zero);
              }
              final handle = await context.source.open(
                mode: FileMode.writeOnly,
              );
              try {
                await handle.writeString(userBytes);
                await handle.flush();
              } finally {
                await handle.close();
              }
            }();
          } else if (context.point ==
              QuarantineDisplacementPoint.afterCandidateInstall) {
            await writer;
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'publish-visibility',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsBytesSync(
        List<int>.filled(8 * 1024 * 1024, 0x63),
        flush: true,
      );

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), userBytes);
      expect(prepared.candidate.readAsStringSync(), userBytes);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test(
    'crash after candidate publish restores from installing journal',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'installing-crash.dart', original);
      final expected = _sha256(source);
      final crashing = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point ==
              QuarantineDisplacementPoint.afterCandidateInstall) {
            throw StateError('injected crash after candidate publish');
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        crashing,
        source,
        runId: 'installing-crash',
      );
      final prepared = await crashing.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        crashing.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsStateError,
      );
      expect(source.readAsStringSync(), candidate);

      final recovered = QuarantineManager(project);
      await recovered.restoreRunBytes(quarantineDir: quarantine);

      expect(source.readAsStringSync(), original);
      expect(prepared.promotedBackup.readAsStringSync(), original);
    },
  );

  test(
    'unconfirmed link process preserves published and prepared paths',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'unconfirmed-link.dart', original);
      final expected = _sha256(source);
      final processRunner = _UnconfirmedAfterSuccessfulLink(failAt: 3);
      final hooked = QuarantineManager(
        project,
        atomicPublishProcessRunner: processRunner,
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'unconfirmed-link',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(processRunner.invocationCount, 3);
      expect(source.readAsStringSync(), candidate);
      expect(prepared.candidate.readAsStringSync(), candidate);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test(
    'confirmed link cancellation re-inspects published and prepared paths',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'cancelled-link.dart', original);
      final expected = _sha256(source);
      final processRunner = _CancellationAtLink(
        failAt: 3,
        afterSuccessfulLink: true,
        cancellation: const ProcessCancellationConfirmedException(
          ProcessSignal.sigterm,
          73,
        ),
      );
      final hooked = QuarantineManager(
        project,
        atomicPublishProcessRunner: processRunner,
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'cancelled-link',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(
          isA<QuarantineDisplacementRecoveryRequiredException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('cancellation was confirmed'), contains('SIGTERM')),
          ),
        ),
      );

      expect(processRunner.invocationCount, 3);
      expect(source.readAsStringSync(), candidate);
      expect(prepared.candidate.readAsStringSync(), candidate);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test(
    'before-launch link cancellation preserves absent target and candidate',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'cancelled-before-link.dart', original);
      final expected = _sha256(source);
      final processRunner = _CancellationAtLink(
        failAt: 3,
        afterSuccessfulLink: false,
        cancellation: const ProcessCancellationBeforeLaunchException(
          ProcessSignal.sigint,
        ),
      );
      final hooked = QuarantineManager(
        project,
        atomicPublishProcessRunner: processRunner,
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'cancelled-before-link',
      );
      final prepared = await hooked.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        hooked.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsA(
          isA<QuarantineDisplacementRecoveryRequiredException>().having(
            (error) => error.toString(),
            'message',
            allOf(contains('cancelled before launch'), contains('SIGINT')),
          ),
        ),
      );

      expect(processRunner.invocationCount, 3);
      expect(source.existsSync(), isFalse);
      expect(prepared.candidate.readAsStringSync(), candidate);
      expect(prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await hooked.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test(
    'crash after installed journal removes only byte-exact candidate',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'installed-crash.dart', original);
      final expected = _sha256(source);
      final crashing = QuarantineManager(
        project,
        displacementHook: (context) {
          if (context.point ==
              QuarantineDisplacementPoint.afterCandidateJournal) {
            throw StateError('injected crash after installed journal');
          }
        },
      );
      final quarantine = await _beginDisplacementTransaction(
        crashing,
        source,
        runId: 'installed-crash',
      );
      final prepared = await crashing.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(candidate, flush: true);

      await expectLater(
        crashing.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1'),
        throwsStateError,
      );
      expect(prepared.candidate.existsSync(), isTrue);

      final recovered = QuarantineManager(project);
      await recovered.restoreRunBytes(quarantineDir: quarantine);

      expect(source.readAsStringSync(), original);
      expect(prepared.candidate.existsSync(), isFalse);
      expect(_restoreArtifactFiles(project), isEmpty);
    },
  );

  test(
    'cross-device source rename fails without copy-delete fallback',
    () async {
      const original = 'const original = 1;\n';
      final source = _source(project, 'cross-device.dart', original);
      final expected = _sha256(source);
      final hooked = QuarantineManager(
        project,
        sourceRenamer: (_, _) => Future<File>.error(
          const FileSystemException(
            'Invalid cross-device link',
            null,
            OSError('EXDEV', 18),
          ),
        ),
      );
      final quarantine = await _beginDisplacementTransaction(
        hooked,
        source,
        runId: 'cross-device',
      );

      await expectLater(
        hooked.beginDisplacedCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          expectedSha256: expected,
          transactionId: 'tx-1',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), original);
      final promoted = await hooked.promotedBackupForCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
      );
      expect(promoted!.existsSync(), isFalse);
    },
  );

  test(
    'open descriptor drift keeps promoted backup and blocks completion',
    () async {
      const original = 'const original = 1;\n';
      final source = _source(project, 'open-descriptor.dart', original);
      final expected = _sha256(source);
      final openDescriptor = source.openSync(mode: FileMode.append);
      final quarantine = await _beginDisplacementTransaction(
        manager,
        source,
        runId: 'open-descriptor',
      );
      if (Platform.isWindows) {
        await expectLater(
          manager.beginDisplacedCase(
            quarantineDir: quarantine,
            caseId: 'case-1',
            findingId: 'finding-1',
            file: source,
            operationType: QuarantineOperationType.declaration,
            expectedSha256: expected,
            transactionId: 'tx-1',
          ),
          throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
        );
        openDescriptor.closeSync();
        expect(source.readAsStringSync(), original);
        return;
      }
      final prepared = await manager.beginDisplacedCase(
        quarantineDir: quarantine,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: source,
        operationType: QuarantineOperationType.declaration,
        expectedSha256: expected,
        transactionId: 'tx-1',
      );
      prepared.candidate.writeAsStringSync(
        'const candidate = 2;\n',
        flush: true,
      );
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-1',
      );
      await manager.recordTransactionApplied(
        quarantineDir: quarantine,
        transactionId: 'tx-1',
        caseIds: const ['case-1'],
      );
      await manager.verifyTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-1',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-1',
      );
      expect(prepared.promotedBackup.existsSync(), isTrue);
      expect(prepared.promotedBackup.readAsStringSync(), original);

      openDescriptor.writeStringSync('open-fd-drift');
      openDescriptor.flushSync();
      openDescriptor.closeSync();

      expect(prepared.promotedBackup.existsSync(), isTrue);
      expect(prepared.promotedBackup.readAsStringSync(), isNot(original));
      await expectLater(
        manager.completeApplyRun(quarantineDir: quarantine),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );
      await expectLater(
        manager.restore(quarantineDir: quarantine, runId: 'open-descriptor'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );
      await expectLater(
        manager.validateCleanQuarantine(runId: 'open-descriptor'),
        throwsA(isA<QuarantineException>()),
      );
      expect(source.readAsStringSync(), 'const candidate = 2;\n');
      expect(prepared.promotedBackup.existsSync(), isTrue);
    },
  );

  test('promoted backup survives commit and rollback until clean', () async {
    const original = 'const original = 1;\n';
    final source = _source(project, 'retained-backup.dart', original);
    final expected = _sha256(source);
    final quarantine = await _beginDisplacementTransaction(
      manager,
      source,
      runId: 'retained-backup',
    );
    final prepared = await manager.beginDisplacedCase(
      quarantineDir: quarantine,
      caseId: 'case-1',
      findingId: 'finding-1',
      file: source,
      operationType: QuarantineOperationType.declaration,
      expectedSha256: expected,
      transactionId: 'tx-1',
    );
    prepared.candidate.writeAsStringSync('const candidate = 2;\n', flush: true);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-1',
    );
    await manager.recordTransactionApplied(
      quarantineDir: quarantine,
      transactionId: 'tx-1',
      caseIds: const ['case-1'],
    );
    await manager.verifyTransaction(
      quarantineDir: quarantine,
      transactionId: 'tx-1',
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
    );
    await manager.commitTransaction(
      quarantineDir: quarantine,
      transactionId: 'tx-1',
    );
    await manager.completeApplyRun(quarantineDir: quarantine);

    expect(prepared.promotedBackup.readAsStringSync(), original);
    await manager.restore(quarantineDir: quarantine, runId: 'retained-backup');
    expect(source.readAsStringSync(), original);
    expect(prepared.promotedBackup.readAsStringSync(), original);

    await manager.completeVerifiedFullRollback(
      quarantineDir: quarantine,
      reason: 'test verifier reproduced baseline',
      verificationEvidence: QuarantineVerificationEvidence(
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
        workingDirectory: p.normalize(p.absolute(project.path)),
        toolchainIdentity: 'test-toolchain',
        available: true,
        passed: true,
        comparisonBaseline: _managerVerificationBaseline(project),
      ),
      baselineEquivalent: true,
    );

    final cleanPlan = await manager.planCleanQuarantine(
      runId: 'retained-backup',
    );
    final cleanResult = await RecoverableCleanStore(projectRoot: project)
        .execute(
          plan: cleanPlan,
          quarantineBase: Directory(p.dirname(quarantine.path)),
        );
    expect(cleanResult.committed, isTrue);
    expect(quarantine.existsSync(), isFalse);
  });

  test(
    'restore edit after preflight aborts without overwriting either copy',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      const userEdit = 'const userEdit = 3;\n';
      final source = _source(project, 'restore-preflight-race.dart', original);
      final hooked = QuarantineManager(
        project,
        restoreHook: (context) {
          if (context.point ==
              QuarantineRestorePoint.beforeTargetDisplacement) {
            context.target.writeAsStringSync(userEdit, flush: true);
          }
        },
      );
      final run = await _completeDisplacementRun(
        hooked,
        source,
        runId: 'restore-preflight-race',
        candidate: candidate,
      );

      await expectLater(
        hooked.restore(
          quarantineDir: run.quarantine,
          runId: 'restore-preflight-race',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), userEdit);
      expect(run.prepared.promotedBackup.readAsStringSync(), original);
      final artifacts = _restoreArtifactFiles(project);
      expect(
        artifacts
            .where((file) => p.basename(file.path) == 'restored')
            .single
            .readAsStringSync(),
        original,
      );
      expect(
        artifacts
            .where((file) => p.basename(file.path) == 'displaced')
            .single
            .readAsStringSync(),
        userEdit,
      );
      await expectLater(
        hooked.validateCleanQuarantine(runId: 'restore-preflight-race'),
        throwsA(isA<QuarantineException>()),
      );
      expect(
        await hooked.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      expect(artifacts.every((file) => file.existsSync()), isTrue);
    },
  );

  test('restore recreation before exclusive install preserves both', () async {
    const original = 'const original = 1;\n';
    const candidate = 'const candidate = 2;\n';
    const recreated = 'const recreated = 3;\n';
    final source = _source(project, 'restore-recreation.dart', original);
    final hooked = QuarantineManager(
      project,
      restoreHook: (context) {
        if (context.point == QuarantineRestorePoint.beforeOriginalInstall) {
          context.target.writeAsStringSync(recreated, flush: true);
        }
      },
    );
    final run = await _completeDisplacementRun(
      hooked,
      source,
      runId: 'restore-recreation',
      candidate: candidate,
    );

    await expectLater(
      hooked.restore(
        quarantineDir: run.quarantine,
        runId: 'restore-recreation',
      ),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );

    expect(source.readAsStringSync(), recreated);
    final artifacts = _restoreArtifactFiles(project);
    expect(
      artifacts
          .where((file) => p.basename(file.path) == 'restored')
          .single
          .readAsStringSync(),
      original,
    );
    expect(
      artifacts
          .where((file) => p.basename(file.path) == 'displaced')
          .single
          .readAsStringSync(),
      candidate,
    );
  });

  test(
    'restore crash after displacement resumes from flushed intent',
    () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'restore-resume.dart', original);
      final crashing = QuarantineManager(
        project,
        restoreHook: (context) {
          if (context.point == QuarantineRestorePoint.beforeOriginalInstall) {
            throw StateError('injected restore crash');
          }
        },
      );
      final run = await _completeDisplacementRun(
        crashing,
        source,
        runId: 'restore-resume',
        candidate: candidate,
      );

      await expectLater(
        crashing.restore(
          quarantineDir: run.quarantine,
          runId: 'restore-resume',
        ),
        throwsStateError,
      );
      expect(source.existsSync(), isFalse);
      expect(_restoreArtifactFiles(project), isNotEmpty);

      final recovered = QuarantineManager(project);
      await recovered.restore(
        quarantineDir: run.quarantine,
        runId: 'restore-resume',
      );
      expect(source.readAsStringSync(), original);
      expect(_restoreArtifactFiles(project), isEmpty);
    },
  );

  test('partial restore target after crash is preserved fail-closed', () async {
    const original = 'const original = 1;\n';
    const candidate = 'const candidate = 2;\n';
    const partial = 'partial-user-bytes';
    final source = _source(project, 'restore-partial.dart', original);
    final crashing = QuarantineManager(
      project,
      restoreHook: (context) {
        if (context.point == QuarantineRestorePoint.beforeOriginalInstall) {
          throw StateError('injected restore crash');
        }
      },
    );
    final run = await _completeDisplacementRun(
      crashing,
      source,
      runId: 'restore-partial',
      candidate: candidate,
    );
    await expectLater(
      crashing.restore(quarantineDir: run.quarantine, runId: 'restore-partial'),
      throwsStateError,
    );
    source.writeAsStringSync(partial, flush: true);

    final recovered = QuarantineManager(project);
    await expectLater(
      recovered.restore(
        quarantineDir: run.quarantine,
        runId: 'restore-partial',
      ),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );
    expect(source.readAsStringSync(), partial);
    expect(_restoreArtifactFiles(project), isNotEmpty);
    await expectLater(
      recovered.validateCleanQuarantine(runId: 'restore-partial'),
      throwsA(isA<QuarantineException>()),
    );
  });

  test('restore displaced drift before journal cleanup is preserved', () async {
    const original = 'const original = 1;\n';
    const candidate = 'const candidate = 2;\n';
    const drift = 'late-open-descriptor-drift';
    final source = _source(project, 'restore-displaced-drift.dart', original);
    final hooked = QuarantineManager(
      project,
      restoreHook: (context) {
        if (context.point == QuarantineRestorePoint.afterOriginalInstall) {
          context.displacedTarget.writeAsStringSync(drift, flush: true);
        }
      },
    );
    final run = await _completeDisplacementRun(
      hooked,
      source,
      runId: 'restore-displaced-drift',
      candidate: candidate,
    );

    await expectLater(
      hooked.restore(
        quarantineDir: run.quarantine,
        runId: 'restore-displaced-drift',
      ),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );

    expect(source.readAsStringSync(), original);
    expect(
      _restoreArtifactFiles(project)
          .where((file) => p.basename(file.path) == 'displaced')
          .single
          .readAsStringSync(),
      drift,
    );
    expect(
      await hooked.readRunLifecycleState(run.quarantine),
      QuarantineRunLifecycleState.recoveryRequired,
    );
    await expectLater(
      hooked.validateCleanQuarantine(runId: 'restore-displaced-drift'),
      throwsA(isA<QuarantineException>()),
    );
  });

  test(
    'restore chmod race after preflight preserves both paths fail-closed',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      final source = _source(project, 'restore-mode-race.dart', original);
      _chmod(source, 0x1ed);
      final hooked = QuarantineManager(
        project,
        restoreHook: (context) {
          if (context.point ==
              QuarantineRestorePoint.beforeTargetDisplacement) {
            _chmod(context.target, 0x1a4);
          }
        },
      );
      final run = await _completeDisplacementRun(
        hooked,
        source,
        runId: 'restore-mode-race',
        candidate: candidate,
      );

      await expectLater(
        hooked.restore(
          quarantineDir: run.quarantine,
          runId: 'restore-mode-race',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(source.readAsStringSync(), candidate);
      expect(_posixMode(source), 0x1a4);
      expect(run.prepared.promotedBackup.readAsStringSync(), original);
      expect(_posixMode(run.prepared.promotedBackup), 0x1ed);
      final displaced = _restoreArtifactFiles(
        project,
      ).singleWhere((file) => p.basename(file.path) == 'displaced');
      expect(displaced.readAsStringSync(), candidate);
      expect(_posixMode(displaced), 0x1a4);
      expect(
        await hooked.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    },
  );

  test('original bytes with wrong mode are not accepted as restored', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    const original = 'const original = 1;\n';
    final source = _source(
      project,
      'restore-original-wrong-mode.dart',
      original,
    );
    _chmod(source, 0x1ed);
    final run = await _completeDisplacementRun(
      manager,
      source,
      runId: 'restore-original-wrong-mode',
      candidate: 'const candidate = 2;\n',
    );
    source.writeAsStringSync(original, flush: true);
    _chmod(source, 0x1a4);

    await expectLater(
      manager.restore(
        quarantineDir: run.quarantine,
        runId: 'restore-original-wrong-mode',
      ),
      throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
    );

    expect(source.readAsStringSync(), original);
    expect(_posixMode(source), 0x1a4);
    expect(run.prepared.promotedBackup.existsSync(), isTrue);
    expect(_posixMode(run.prepared.promotedBackup), 0x1ed);
  });

  for (final point in [
    QuarantineRestorePoint.beforeTargetDisplacement,
    QuarantineRestorePoint.beforeOriginalInstall,
  ]) {
    test('legacy no-intent ${point.name} drift is never adopted', () async {
      const original = 'const original = 1;\n';
      const candidate = 'const candidate = 2;\n';
      const drift = 'const externalDrift = 3;\n';
      final source = _source(
        project,
        'legacy-no-intent-${point.name}.dart',
        original,
      );
      final crashing = QuarantineManager(
        project,
        restoreHook: (context) {
          if (context.point == point) {
            throw StateError('injected ${point.name} crash');
          }
        },
      );
      final run = await _completeDisplacementRun(
        crashing,
        source,
        runId: 'legacy-no-intent-${point.name}',
        candidate: candidate,
      );
      await expectLater(
        crashing.restore(
          quarantineDir: run.quarantine,
          runId: 'legacy-no-intent-${point.name}',
        ),
        throwsStateError,
      );
      final artifacts = _restoreArtifactFiles(project);
      final intent = artifacts.singleWhere(
        (file) => p.basename(file.path) == 'intent.json',
      );
      intent.deleteSync();
      final displaced = artifacts.where(
        (file) => p.basename(file.path) == 'displaced',
      );
      final drifted = displaced.isEmpty ? source : displaced.single;
      drifted.writeAsStringSync(drift, flush: true);

      final recovered = QuarantineManager(project);
      await expectLater(
        recovered.restore(
          quarantineDir: run.quarantine,
          runId: 'legacy-no-intent-${point.name}',
        ),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(drifted.readAsStringSync(), drift);
      expect(intent.existsSync(), isFalse);
      expect(run.prepared.promotedBackup.readAsStringSync(), original);
      expect(
        await recovered.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
    });
  }

  test(
    'V1 anchor drift prevents terminal rollback and preserves evidence',
    () async {
      const original = 'const original = 1;\n';
      const drift = 'const anchorDrift = 2;\n';
      final source = _source(project, 'v1-anchor-drift.dart', original);
      final mode = Platform.isLinux || Platform.isMacOS
          ? _posixMode(source)
          : null;
      final entry = QuarantineEntry(
        originalPath: source.path,
        sha256: _sha256(source),
        sizeBytes: source.lengthSync(),
        posixMode: mode,
      );
      var injected = false;
      final hooked = QuarantineManager(
        project,
        restoreHook: (context) {
          if (context.point == QuarantineRestorePoint.afterOriginalInstall) {
            final anchor = context.target.parent
                .listSync(followLinks: false)
                .whereType<File>()
                .singleWhere(
                  (file) => p
                      .basename(file.path)
                      .startsWith('.flutter_pruner-restore-'),
                );
            anchor.writeAsStringSync(drift, flush: true);
            injected = true;
          }
        },
      );
      final quarantine = await hooked.createQuarantine(
        runId: 'v1-anchor-drift',
        entries: [entry],
      );
      await hooked.quarantineFile(
        file: source,
        expectedSha256: entry.sha256,
        quarantineDir: quarantine,
        originalPath: source.path,
      );

      await expectLater(
        hooked.restore(quarantineDir: quarantine, runId: 'v1-anchor-drift'),
        throwsA(isA<QuarantineDisplacementRecoveryRequiredException>()),
      );

      expect(injected, isTrue);
      expect(source.readAsStringSync(), drift);
      expect(
        source.parent
            .listSync(followLinks: false)
            .where(
              (entity) => p
                  .basename(entity.path)
                  .startsWith('.flutter_pruner-restore-'),
            ),
        isNotEmpty,
      );
      expect(
        (await hooked.readManifest(quarantine)).fullRollbackVerified,
        isFalse,
      );
      await expectLater(
        hooked.validateCleanQuarantine(runId: 'v1-anchor-drift'),
        throwsA(isA<QuarantineException>()),
      );
    },
  );
}

Future<QuarantineTransaction> _triggerManifestRepair(
  QuarantineManager manager,
  Directory quarantine,
) => manager.beginTransaction(
  quarantineDir: quarantine,
  transactionId: 'tx-repair-probe',
  round: 1,
  componentId: 'unit:repair-probe',
  findingIds: const ['finding-repair-probe'],
  caseIds: const ['case-repair-probe'],
);

Map<String, dynamic> _payload(File manifest) {
  final decoded =
      jsonDecode(manifest.readAsStringSync()) as Map<String, dynamic>;
  return Map<String, dynamic>.from(decoded)..remove('_journal');
}

String _document(Map<String, dynamic> payload, {required int revision}) {
  final checksum = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  return jsonEncode({
    ...payload,
    '_journal': {'revision': revision, 'payloadSha256': checksum},
  });
}

Future<Directory> _createCommittedRun(
  QuarantineManager manager,
  Directory project, {
  required String runId,
  String quarantineBase = QuarantineManager.defaultQuarantineDir,
}) async {
  final source = File(p.join(project.path, 'lib', '$runId.dart'));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync('const before = true;\n');
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    quarantineBase: quarantineBase,
    verificationPolicyHash: 'policy',
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
      workingDirectory: p.normalize(p.absolute(manager.projectRoot.path)),
      toolchainIdentity: 'test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: _managerVerificationBaseline(manager.projectRoot),
    ),
  );
  final transactionId = 'tx-$runId';
  final caseId = 'case-$runId';
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: transactionId,
    round: 1,
    componentId: 'unit:$runId',
    findingIds: ['finding-$runId'],
    caseIds: [caseId],
  );
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: caseId,
    findingId: 'finding-$runId',
    file: source,
    operationType: QuarantineOperationType.declaration,
    transactionId: transactionId,
  );
  source.writeAsStringSync('const after = true;\n');
  await manager.recordCaseApplied(quarantineDir: quarantine, caseId: caseId);
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: transactionId,
    caseIds: [caseId],
  );
  await manager.verifyTransaction(
    quarantineDir: quarantine,
    transactionId: transactionId,
    policyHash: 'policy',
    requiredStepIds: const ['analyze'],
    observedStepIds: const ['analyze'],
  );
  await manager.commitTransaction(
    quarantineDir: quarantine,
    transactionId: transactionId,
  );
  return quarantine;
}

Future<Directory> _createRolledBackRun(
  QuarantineManager manager,
  Directory project, {
  required String runId,
}) async {
  final quarantine = await _createCommittedRun(manager, project, runId: runId);
  await manager.markRunRecoveryRequired(
    quarantineDir: quarantine,
    reason: 'fixture rollback',
  );
  await manager.restoreRunBytes(quarantineDir: quarantine);
  await manager.verifyRunOriginalBytes(quarantineDir: quarantine);
  await manager.completeVerifiedFullRollback(
    quarantineDir: quarantine,
    reason: 'fixture rollback',
    verificationEvidence: QuarantineVerificationEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: _managerVerificationBaseline(project),
    ),
    baselineEquivalent: true,
  );
  return quarantine;
}

void _rewritePrimaryPayload(
  Directory quarantine,
  void Function(Map<String, dynamic> payload) update,
) {
  final primary = File(p.join(quarantine.path, 'manifest.json'));
  final document = jsonDecode(primary.readAsStringSync()) as Map;
  final revision = (document['_journal'] as Map)['revision'] as int;
  final payload = _payload(primary);
  update(payload);
  _replacePrimaryDocument(primary, _document(payload, revision: revision + 1));
}

Future<Object?> _captureFailure(Future<void> Function() action) async {
  try {
    await action();
  } on Object catch (error) {
    return error;
  }
  return null;
}

Map<String, String> _rawTreeSnapshot(Iterable<Directory> roots) {
  final snapshot = <String, String>{};

  void capture(String requestedPath) {
    final path = p.normalize(p.absolute(requestedPath));
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    switch (type) {
      case FileSystemEntityType.notFound:
        snapshot[path] = 'notFound';
      case FileSystemEntityType.file:
        snapshot[path] = 'file:${base64Encode(File(path).readAsBytesSync())}';
      case FileSystemEntityType.directory:
        snapshot[path] = 'directory';
        final children = Directory(path).listSync(followLinks: false)
          ..sort((left, right) => left.path.compareTo(right.path));
        for (final child in children) {
          capture(child.path);
        }
      case FileSystemEntityType.link:
        snapshot[path] = 'link:${Link(path).targetSync()}';
      case FileSystemEntityType.unixDomainSock:
        snapshot[path] = 'unixDomainSock';
      case FileSystemEntityType.pipe:
        snapshot[path] = 'pipe';
    }
  }

  for (final root in roots) {
    capture(root.path);
  }
  return snapshot;
}

void _removeLifecycleMarker(Directory quarantine) {
  final primary = File(p.join(quarantine.path, 'manifest.json'));
  final decoded = jsonDecode(primary.readAsStringSync()) as Map;
  final revision = ((decoded['_journal'] as Map)['revision'] as int);
  final payload = _payload(primary)..remove('_runLifecycle');
  final previous = File('${primary.path}.previous');
  final temporary = File('${primary.path}.tmp');
  if (previous.existsSync()) previous.deleteSync();
  if (temporary.existsSync()) temporary.deleteSync();
  primary.writeAsStringSync(_document(payload, revision: revision + 1));
}

Future<({Directory quarantine, AcceptedVerificationEvidence accepted})>
_stageSingleVerificationWave(
  QuarantineManager manager,
  Directory project, {
  int round = 1,
  bool displaced = true,
}) async {
  final baseline = _managerVerificationBaseline(project);
  final quarantine = await manager.createCaseQuarantine(
    runId: 'wave-crash-${DateTime.now().microsecondsSinceEpoch}',
    verificationPolicyHash: 'policy',
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: baseline,
    ),
  );
  final source = _source(project, 'wave.dart', 'const before = true;\n');
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-r${round.toString().padLeft(3, '0')}-a',
    round: round,
    componentId: 'unit:a',
    findingIds: const ['finding-a'],
    caseIds: const ['case-r001-a'],
    verificationWaveId: 'wave-r${round.toString().padLeft(3, '0')}',
  );
  if (displaced) {
    final prepared = await manager.beginDisplacedCase(
      quarantineDir: quarantine,
      caseId: 'case-r001-a',
      findingId: 'finding-a',
      file: source,
      operationType: QuarantineOperationType.declaration,
      expectedSha256: _sha256(source),
      expectedPosixMode: _capturedPosixMode(source),
      transactionId: 'tx-r${round.toString().padLeft(3, '0')}-a',
    );
    prepared.candidate.writeAsStringSync('const after = true;\n', flush: true);
  } else {
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-r001-a',
      findingId: 'finding-a',
      file: source,
      operationType: QuarantineOperationType.declaration,
      transactionId: 'tx-r${round.toString().padLeft(3, '0')}-a',
    );
    source.writeAsStringSync('const after = true;\n', flush: true);
  }
  await manager.recordCaseApplied(
    quarantineDir: quarantine,
    caseId: 'case-r001-a',
  );
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: 'tx-r${round.toString().padLeft(3, '0')}-a',
    caseIds: const ['case-r001-a'],
  );
  final candidate = VerificationResult(
    passed: true,
    failedStep: null,
    steps: const [
      VerificationStep(
        name: 'analyze',
        parserKind: VerificationOutputParserKind.humanAnalyzer,
        passed: true,
        exitCode: 0,
        stdout: '',
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    policyHash: 'policy',
    requiredStepIds: const ['analyze'],
    requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
    workingDirectory: p.normalize(p.absolute(project.path)),
    toolchainIdentity: 'test-toolchain',
  );
  return (
    quarantine: quarantine,
    accepted: candidate.compareToBaselineEvidence(baseline).acceptedEvidence!,
  );
}

Future<
  ({
    Directory quarantine,
    AcceptedVerificationEvidence accepted,
    List<String> transactionIds,
  })
>
_stageTwoVerificationWave(QuarantineManager manager, Directory project) async {
  final baseline = _managerVerificationBaseline(project);
  final quarantine = await manager.createCaseQuarantine(
    runId: 'wave-membership-${DateTime.now().microsecondsSinceEpoch}',
    verificationPolicyHash: 'policy',
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: baseline,
    ),
  );
  final transactionIds = <String>[];
  for (final suffix in const ['a', 'b']) {
    final transactionId = 'tx-r001-$suffix';
    final caseId = 'case-r001-$suffix';
    transactionIds.add(transactionId);
    final source = _source(project, 'membership-$suffix.dart', 'H1-$suffix\n');
    await manager.beginTransaction(
      quarantineDir: quarantine,
      transactionId: transactionId,
      round: 1,
      componentId: 'unit:$suffix',
      findingIds: ['finding-$suffix'],
      caseIds: [caseId],
      verificationWaveId: 'wave-r001',
    );
    final prepared = await manager.beginDisplacedCase(
      quarantineDir: quarantine,
      caseId: caseId,
      findingId: 'finding-$suffix',
      file: source,
      operationType: QuarantineOperationType.declaration,
      expectedSha256: _sha256(source),
      expectedPosixMode: _capturedPosixMode(source),
      transactionId: transactionId,
    );
    prepared.candidate.writeAsStringSync('H2-$suffix\n', flush: true);
    await manager.recordCaseApplied(quarantineDir: quarantine, caseId: caseId);
    await manager.recordTransactionApplied(
      quarantineDir: quarantine,
      transactionId: transactionId,
      caseIds: [caseId],
    );
  }
  return (
    quarantine: quarantine,
    accepted: _passingVerificationResult(
      project,
    ).compareToBaselineEvidence(baseline).acceptedEvidence!,
    transactionIds: transactionIds,
  );
}

Map<String, String> _journalSnapshot(Directory quarantine) {
  final primary = p.join(quarantine.path, 'manifest.json');
  return {
    for (final path in [primary, '$primary.tmp', '$primary.previous'])
      if (File(path).existsSync())
        p.basename(path): base64Encode(File(path).readAsBytesSync()),
  };
}

Map<String, Map<String, Object?>> _manifestCandidateSnapshot(
  Directory quarantine,
) {
  final primary = p.join(quarantine.path, 'manifest.json');
  return {
    for (final path in [primary, '$primary.tmp', '$primary.previous'])
      if (File(path).existsSync())
        p.basename(path): _manifestCandidateFileSnapshot(File(path)),
  };
}

Map<String, Object?> _manifestCandidateFileSnapshot(File file) {
  final bytes = file.readAsBytesSync();
  int? revision;
  String? payloadSha256;
  try {
    final decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final journal = decoded['_journal'] as Map<String, dynamic>?;
    revision = journal?['revision'] as int? ?? 0;
    payloadSha256 = journal?['payloadSha256'] as String?;
  } on Object {
    // Invalid candidates still need exact byte/path snapshots.
  }
  return <String, Object?>{
    'path': file.path,
    'bytesBase64': base64Encode(bytes),
    'fileSha256': sha256.convert(bytes).toString(),
    'revision': revision,
    'payloadSha256': payloadSha256,
  };
}

void _replacePrimaryDocument(File primary, String contents) {
  for (final suffix in ['.tmp', '.previous']) {
    final adjacent = File('${primary.path}$suffix');
    if (adjacent.existsSync()) adjacent.deleteSync();
  }
  primary.writeAsStringSync(contents, flush: true);
}

File _source(Directory project, String name, String contents) {
  final source = File(p.join(project.path, 'lib', name));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync(contents, flush: true);
  return source;
}

String _sha256(File file) => sha256.convert(file.readAsBytesSync()).toString();

VerificationBaselineEvidence _managerVerificationBaseline(Directory project) =>
    VerificationBaselineEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
      steps: [
        VerificationStepBaselineEvidence(
          name: 'analyze',
          parserKind: VerificationOutputParserKind.humanAnalyzer,
          passed: true,
          exitCode: 0,
          failureEvidenceComplete: false,
          reportedFailureCount: null,
          fingerprintCount: 0,
          fingerprintDigests: const {},
        ),
      ],
    );

VerificationResult _passingVerificationResult(Directory project) =>
    VerificationResult(
      passed: true,
      failedStep: null,
      steps: const [
        VerificationStep(
          name: 'analyze',
          parserKind: VerificationOutputParserKind.humanAnalyzer,
          passed: true,
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: Duration.zero,
        ),
      ],
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'test-toolchain',
    );

Future<Directory> _beginDisplacementTransaction(
  QuarantineManager manager,
  File source, {
  required String runId,
}) async {
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    verificationPolicyHash: 'policy',
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: 'policy',
      requiredStepIds: const ['analyze'],
      observedStepIds: const ['analyze'],
      workingDirectory: p.normalize(p.absolute(manager.projectRoot.path)),
      toolchainIdentity: 'test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: _managerVerificationBaseline(manager.projectRoot),
    ),
  );
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    round: 1,
    componentId: source.path,
    findingIds: const ['finding-1'],
    caseIds: const ['case-1'],
  );
  return quarantine;
}

Future<({Directory quarantine, QuarantinePreparedCase prepared})>
_completeDisplacementRun(
  QuarantineManager manager,
  File source, {
  required String runId,
  required String candidate,
}) async {
  final expected = _sha256(source);
  final quarantine = await _beginDisplacementTransaction(
    manager,
    source,
    runId: runId,
  );
  final prepared = await manager.beginDisplacedCase(
    quarantineDir: quarantine,
    caseId: 'case-1',
    findingId: 'finding-1',
    file: source,
    operationType: QuarantineOperationType.declaration,
    expectedSha256: expected,
    transactionId: 'tx-1',
  );
  prepared.candidate.writeAsStringSync(candidate, flush: true);
  await manager.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1');
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    caseIds: const ['case-1'],
  );
  await manager.verifyTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    policyHash: 'policy',
    requiredStepIds: const ['analyze'],
    observedStepIds: const ['analyze'],
  );
  await manager.commitTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
  );
  await manager.completeApplyRun(quarantineDir: quarantine);
  return (quarantine: quarantine, prepared: prepared);
}

List<File> _restoreArtifactFiles(Directory project) {
  final root = Directory(
    p.join(project.path, '.flutter_pruner', 'tmp', 'restore'),
  );
  if (!root.existsSync()) return const [];
  return root
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .toList();
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

int? _capturedPosixMode(File file) =>
    Platform.isLinux || Platform.isMacOS ? _posixMode(file) : null;

class _UnconfirmedAfterSuccessfulLink implements ProcessExecutionRunner {
  _UnconfirmedAfterSuccessfulLink({required this.failAt});

  final int failAt;
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
    if (invocationCount == failAt) {
      throw const ProcessTerminationUnconfirmedException(
        processId: 73,
        message: 'injected unconfirmed link helper termination',
      );
    }
    return result;
  }
}

class _CancellationAtLink implements ProcessExecutionRunner {
  _CancellationAtLink({
    required this.failAt,
    required this.afterSuccessfulLink,
    required this.cancellation,
  });

  final int failAt;
  final bool afterSuccessfulLink;
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
    if (invocationCount == failAt && !afterSuccessfulLink) {
      throw cancellation;
    }
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

class _CancellationAtPermission implements ProcessExecutionRunner {
  _CancellationAtPermission({required this.failAt, required this.cancellation});

  final int failAt;
  final Exception cancellation;
  final ProcessExecutionRunner _delegate = const ManagedProcessRunner();
  var invocationCount = 0;

  int get processId => switch (cancellation) {
    ProcessCancellationConfirmedException(:final rootPid) => rootPid,
    ProcessTerminationUnconfirmedException(:final processId) => processId,
    _ => 0,
  };

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
