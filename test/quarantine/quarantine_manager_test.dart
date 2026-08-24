import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
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
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: caseId,
        findingId: 'finding-$id',
        file: source,
        operationType: QuarantineOperationType.declaration,
        transactionId: transactionId,
      );
      source.writeAsStringSync('const after$id = true;\n', flush: true);
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
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: state.caseId,
          findingId: 'finding-${state.caseId}',
          file: source,
          operationType: QuarantineOperationType.declaration,
          transactionId: state.transaction,
        );
        source.writeAsStringSync(state.output, flush: true);
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
      guarded.readManifest(staged.quarantine),
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

  test(
    'primary discards a fully written but uncommitted next manifest',
    () async {
      final quarantine = await manager.createCaseQuarantine(runId: 'staged');
      final primary = File(p.join(quarantine.path, 'manifest.json'));
      final payload = _payload(primary)..['analysisMode'] = 'application';
      File(
        '${primary.path}.tmp',
      ).writeAsStringSync(_document(payload, revision: 2), flush: true);

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

    await manager.cleanQuarantine(runId: 'retained-backup');
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
}) async {
  final source = File(p.join(project.path, 'lib', '$runId.dart'));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync('const before = true;\n');
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
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: 'case-r001-a',
    findingId: 'finding-a',
    file: source,
    operationType: QuarantineOperationType.declaration,
    transactionId: 'tx-r${round.toString().padLeft(3, '0')}-a',
  );
  source.writeAsStringSync('const after = true;\n', flush: true);
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
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: caseId,
      findingId: 'finding-$suffix',
      file: source,
      operationType: QuarantineOperationType.declaration,
      transactionId: transactionId,
    );
    source.writeAsStringSync('H2-$suffix\n', flush: true);
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
