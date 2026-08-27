import 'dart:convert';

import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:test/test.dart';

void main() {
  group('QuarantineEntry', () {
    test('serializes declaration-level entry with all fields', () {
      final entry = QuarantineEntry(
        originalPath: '/proj/lib/utils.dart',
        sha256: 'abc123',
        sizeBytes: 500,
        posixMode: 0x1ed,
        operationType: QuarantineOperationType.declaration,
        declarationIds: ['dart:app/lib/utils.dart#unusedHelper'],
        modifiedSha256: 'def456',
      );

      final json = entry.toJson();

      expect(json['operationType'], 'declaration');
      expect(json['declarationIds'], ['dart:app/lib/utils.dart#unusedHelper']);
      expect(json['modifiedSha256'], 'def456');
      expect(json['posixMode'], 0x1ed);

      final restored = QuarantineEntry.fromJson(json);
      expect(restored.posixMode, 0x1ed);
    });

    test('deserializes declaration-level entry', () {
      final json = {
        'originalPath': '/proj/lib/utils.dart',
        'sha256': 'abc123',
        'sizeBytes': 500,
        'operationType': 'declaration',
        'declarationIds': ['dart:app/lib/utils.dart#unusedHelper'],
        'modifiedSha256': 'def456',
      };

      final entry = QuarantineEntry.fromJson(json);

      expect(entry.operationType, QuarantineOperationType.declaration);
      expect(entry.declarationIds, ['dart:app/lib/utils.dart#unusedHelper']);
      expect(entry.modifiedSha256, 'def456');
      expect(entry.posixMode, isNull);
    });

    test('file-level entry has default operationType', () {
      final entry = QuarantineEntry(
        originalPath: '/proj/assets/logo.png',
        sha256: 'abc123',
        sizeBytes: 1024,
      );

      expect(entry.operationType, QuarantineOperationType.file);
      expect(entry.declarationIds, isNull);
      expect(entry.modifiedSha256, isNull);
    });

    test('rejects malformed POSIX mode evidence', () {
      Map<String, dynamic> json(Object? posixMode) => {
        'originalPath': '/proj/lib/tool.dart',
        'sha256': 'abc123',
        'sizeBytes': 12,
        'posixMode': posixMode,
      };

      for (final value in <Object>['0755', -1, 0x1000]) {
        expect(
          () => QuarantineEntry.fromJson(json(value)),
          throwsFormatException,
          reason: 'mode $value must fail closed',
        );
      }
    });
  });

  test('V2 manifest round-trips case journal state', () {
    final manifest = QuarantineManifest(
      runId: 'run-1',
      timestamp: DateTime.utc(2026, 8, 13),
      projectRoot: '/workspace/example',
      analysisMode: 'package-internal',
      acceptedRiskCodes: const ['external-consumers-not-scanned'],
      riskAcceptanceSource: 'interactive',
      fullRollbackAtUtc: DateTime.utc(2026, 8, 14),
      fullRollbackVerified: true,
      cases: [
        QuarantineCase(
          caseId: 'case-0001',
          findingId: 'dart:app/lib/a.dart#unused',
          entry: const QuarantineEntry(
            originalPath: '/proj/lib/a.dart',
            sha256: 'before',
            sizeBytes: 10,
            operationType: QuarantineOperationType.declaration,
            declarationIds: ['dart:app/lib/a.dart#unused'],
            modifiedSha256: 'after',
          ),
          status: QuarantineCaseStatus.rolledBack,
          failureReason: 'new analyzer error',
        ),
      ],
    );

    final json = manifest.toJson();
    final restored = QuarantineManifest.fromJson(json);

    expect(json['version'], '2.0.0');
    expect(restored.projectRoot, '/workspace/example');
    expect(restored.analysisMode, 'package-internal');
    expect(restored.acceptedRiskCodes, ['external-consumers-not-scanned']);
    expect(restored.riskAcceptanceSource, 'interactive');
    expect(restored.fullRollbackAtUtc, DateTime.utc(2026, 8, 14));
    expect(restored.fullRollbackVerified, isTrue);
    expect(restored.entries, isEmpty);
    expect(restored.cases, hasLength(1));
    expect(restored.cases.single.caseId, 'case-0001');
    expect(restored.cases.single.status, QuarantineCaseStatus.rolledBack);
    expect(restored.cases.single.entry.modifiedSha256, 'after');
    expect(restored.cases.single.failureReason, 'new analyzer error');
  });

  test('empty V2 journal retains its manifest version', () {
    final manifest = QuarantineManifest(
      runId: 'empty-v2',
      timestamp: DateTime.utc(2026, 8, 13),
      caseJournal: true,
    );

    final restored = QuarantineManifest.fromJson(manifest.toJson());

    expect(manifest.toJson()['version'], '2.0.0');
    expect(restored.usesCaseJournal, isTrue);
    expect(restored.cases, isEmpty);
  });

  test('V3 manifest round-trips atomic verification evidence', () {
    final manifest = QuarantineManifest(
      runId: 'run-v3',
      timestamp: DateTime.utc(2026, 8, 13),
      caseJournal: true,
      transactionJournal: true,
      verificationPolicyHash: 'policy-hash',
      selection: QuarantineSelectionEvidence(
        mode: FindingSelectionMode.exact,
        requestedFindingIds: const ['dart:app/lib/a.dart#unused'],
        planFingerprint: 'a' * 64,
      ),
      baselineVerification: QuarantineVerificationEvidence(
        policyHash: 'policy-hash',
        requiredStepIds: ['analyze', 'test'],
        observedStepIds: ['analyze', 'test'],
        workingDirectory: '/workspace/example',
        toolchainIdentity: 'toolchain-hash',
        available: true,
        passed: true,
        comparisonBaseline: VerificationBaselineEvidence(
          policyHash: 'policy-hash',
          requiredStepIds: const ['analyze', 'test'],
          requiredParserKinds: const [
            VerificationOutputParserKind.humanAnalyzer,
            VerificationOutputParserKind.compactTest,
          ],
          workingDirectory: '/workspace/example',
          toolchainIdentity: 'toolchain-hash',
          steps: [
            for (final entry in const [
              ('analyze', VerificationOutputParserKind.humanAnalyzer),
              ('test', VerificationOutputParserKind.compactTest),
            ])
              VerificationStepBaselineEvidence(
                name: entry.$1,
                parserKind: entry.$2,
                passed: true,
                exitCode: 0,
                failureEvidenceComplete: false,
                reportedFailureCount: null,
                fingerprintCount: 0,
                fingerprintDigests: const {},
              ),
          ],
        ),
      ),
      transactions: const [
        QuarantineTransaction(
          transactionId: 'tx-r001-deadbeef',
          round: 1,
          componentId: 'unit:deadbeef',
          findingIds: ['dart:app/lib/a.dart#unused'],
          caseIds: ['case-0001'],
          status: QuarantineTransactionStatus.rolledBackVerified,
          verificationPolicyHash: 'policy-hash',
          requiredStepIds: ['analyze', 'test'],
          observedStepIds: ['analyze', 'test'],
          rollbackVerified: true,
          failureReason: 'verification regression',
        ),
      ],
    );

    final json = manifest.toJson();
    final restored = QuarantineManifest.fromJson(json);

    expect(json['version'], '3.0.0');
    expect(restored.usesTransactionJournal, isTrue);
    expect(restored.verificationPolicyHash, 'policy-hash');
    expect(restored.selection?.mode, FindingSelectionMode.exact);
    expect(restored.selection?.requestedFindingIds, [
      'dart:app/lib/a.dart#unused',
    ]);
    expect(restored.selection?.planFingerprint, 'a' * 64);
    expect(restored.baselineVerification?.available, isTrue);
    expect(restored.baselineVerification?.passed, isTrue);
    expect(
      restored.baselineVerification?.comparisonBaseline?.isComplete,
      isTrue,
    );
    expect(restored.baselineVerification?.observedStepIds, ['analyze', 'test']);
    expect(restored.transactions, hasLength(1));
    expect(
      restored.transactions.single.status,
      QuarantineTransactionStatus.rolledBackVerified,
    );
    expect(restored.transactions.single.rollbackVerified, isTrue);
    expect(restored.transactions.single.observedStepIds, ['analyze', 'test']);
  });

  test('V3 manifest round-trips immutable accepted verification waves', () {
    final candidate = _waveCandidateEvidence();
    final transactionIds = <String>['tx-r001-a', 'tx-r001-b'];
    final manifest = QuarantineManifest(
      runId: 'run-wave',
      timestamp: DateTime.utc(2026, 8, 23),
      caseJournal: true,
      transactionJournal: true,
      transactions: [
        for (final transactionId in transactionIds)
          QuarantineTransaction(
            transactionId: transactionId,
            round: 1,
            componentId: 'unit:$transactionId',
            findingIds: ['finding:$transactionId'],
            caseIds: ['case:$transactionId'],
            status: QuarantineTransactionStatus.committed,
            verificationWaveId: 'wave-r001',
          ),
      ],
      verificationWaves: [
        QuarantineVerificationWave(
          verificationWaveId: 'wave-r001',
          round: 1,
          transactionIds: transactionIds,
          comparisonBaselineSha256: 'a' * 64,
          candidateEvidence: candidate,
        ),
      ],
    );

    transactionIds.add('external');
    final json = manifest.toJson();
    final restored = QuarantineManifest.fromJson(json);
    final wave = restored.verificationWaves.single;

    expect(json['version'], '3.0.0');
    expect(wave.verificationWaveId, 'wave-r001');
    expect(wave.round, 1);
    expect(wave.transactionIds, ['tx-r001-a', 'tx-r001-b']);
    expect(wave.candidateEvidence.toJson(), candidate.toJson());
    expect(() => wave.transactionIds.add('external'), throwsUnsupportedError);
  });

  test('legacy V3 omits empty verification-wave fields', () {
    final manifest = QuarantineManifest(
      runId: 'legacy-v3',
      timestamp: DateTime.utc(2026, 8, 23),
      transactionJournal: true,
      transactions: const [
        QuarantineTransaction(
          transactionId: 'tx-legacy',
          round: 1,
          componentId: 'unit:legacy',
          findingIds: ['finding-legacy'],
          caseIds: ['case-legacy'],
          status: QuarantineTransactionStatus.applied,
        ),
      ],
    );

    final json = manifest.toJson();

    expect(json, isNot(contains('verificationWaves')));
    expect(
      (json['transactions'] as List).single,
      isNot(contains('verificationWaveId')),
    );
  });

  test('malformed or duplicated verification-wave membership fails closed', () {
    Map<String, dynamic> document({required String waveId}) => {
      'version': '3.0.0',
      'runId': 'wave-validation',
      'timestamp': DateTime.utc(2026, 8, 23).toIso8601String(),
      'entries': <Object>[],
      'cases': <Object>[],
      'transactions': <Object>[],
      'verificationWaves': <Object>[
        {
          'verificationWaveId': waveId,
          'round': 1,
          'transactionIds': ['tx-a'],
          'comparisonBaselineSha256': 'a' * 64,
          'candidateEvidence': _waveCandidateEvidence().toJson(),
        },
      ],
    };

    expect(
      () => QuarantineManifest.fromJson(document(waveId: 'wave-r002')),
      throwsFormatException,
    );
    final duplicated = document(waveId: 'wave-r001');
    (duplicated['verificationWaves'] as List).add(
      Map<String, dynamic>.from(
          (duplicated['verificationWaves'] as List).single as Map,
        )
        ..['verificationWaveId'] = 'wave-r002'
        ..['round'] = 2,
    );
    expect(
      () => QuarantineManifest.fromJson(duplicated),
      throwsFormatException,
    );
  });

  test('selection evidence snapshots inputs and JSON output', () {
    final requested = <String>['finding-a'];
    final evidence = QuarantineSelectionEvidence(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: requested,
      planFingerprint: 'b' * 64,
    );

    requested.add('finding-b');
    final json = evidence.toJson();
    (json['requestedFindingIds'] as List<String>).add('external');

    expect(evidence.requestedFindingIds, ['finding-a']);
    expect(
      () => evidence.requestedFindingIds.add('external'),
      throwsUnsupportedError,
    );
    expect(json['version'], 2);
  });

  test('V2 selection evidence round-trips matching preview authorization', () {
    final evidence = QuarantineSelectionEvidence(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      planFingerprint: 'b' * 64,
      previewFingerprintVersion: 1,
      previewFingerprint: 'v1:${'c' * 64}',
      expectedPreviewFingerprint: 'v1:${'c' * 64}',
    );

    final json = evidence.toJson();
    final restored = QuarantineSelectionEvidence.fromJson(json);

    expect(json, {
      'version': 2,
      'mode': 'exact',
      'requestedFindingIds': ['finding-a'],
      'planFingerprint': 'b' * 64,
      'previewFingerprintVersion': 1,
      'previewFingerprint': 'v1:${'c' * 64}',
      'expectedPreviewFingerprint': 'v1:${'c' * 64}',
    });
    expect(restored.previewFingerprintVersion, 1);
    expect(restored.previewFingerprint, 'v1:${'c' * 64}');
    expect(restored.expectedPreviewFingerprint, 'v1:${'c' * 64}');
    expect(restored.toJson(), json);
  });

  test('legacy V1 selection evidence retains its original projection', () {
    final json = <String, dynamic>{
      'version': 1,
      'mode': 'exact',
      'requestedFindingIds': ['finding-a'],
      'planFingerprint': 'a' * 64,
    };

    final restored = QuarantineSelectionEvidence.fromJson(json);

    expect(restored.previewFingerprintVersion, isNull);
    expect(restored.previewFingerprint, isNull);
    expect(restored.expectedPreviewFingerprint, isNull);
    expect(
      jsonEncode(restored.toJson()),
      '{"version":1,"mode":"exact","requestedFindingIds":["finding-a"],'
      '"planFingerprint":"${'a' * 64}"}',
    );
  });

  test('malformed or misplaced selection evidence fails closed', () {
    Map<String, dynamic> manifestWith(Object? selection) => {
      'version': '3.0.0',
      'runId': 'selection',
      'timestamp': DateTime.utc(2026, 8, 17).toIso8601String(),
      'entries': <Object>[],
      'cases': <Object>[],
      'transactions': <Object>[],
      'selection': selection,
    };

    for (final selection in <Object?>[
      'not-a-map',
      {
        'version': 3,
        'mode': 'exact',
        'requestedFindingIds': ['finding-a'],
        'planFingerprint': 'a' * 64,
      },
      {
        'version': 1,
        'mode': 'exact',
        'requestedFindingIds': <String>[],
        'planFingerprint': 'a' * 64,
      },
      {
        'version': 1,
        'mode': 'exact',
        'requestedFindingIds': ['finding-b', 'finding-a'],
        'planFingerprint': 'a' * 64,
      },
      {
        'version': 1,
        'mode': 'exact',
        'requestedFindingIds': ['finding-a', 'finding-a'],
        'planFingerprint': 'a' * 64,
      },
      {
        'version': 1,
        'mode': 'unknown',
        'requestedFindingIds': ['finding-a'],
        'planFingerprint': 'a' * 64,
      },
      {
        'version': 1,
        'mode': 'exact',
        'requestedFindingIds': ['finding-a'],
        'planFingerprint': 'short',
      },
      {
        'version': 1,
        'mode': 'exact',
        'requestedFindingIds': ['finding-a'],
        'planFingerprint': 'a' * 64,
        'previewFingerprintVersion': 1,
        'previewFingerprint': 'v1:${'b' * 64}',
        'expectedPreviewFingerprint': 'v1:${'b' * 64}',
      },
      for (final previewFields in <Map<String, Object?>>[
        {'previewFingerprintVersion': 1},
        {'previewFingerprintVersion': null},
        {
          'previewFingerprintVersion': 1,
          'previewFingerprint': 'v1:${'b' * 64}',
        },
        {
          'previewFingerprint': 'v1:${'b' * 64}',
          'expectedPreviewFingerprint': 'v1:${'b' * 64}',
        },
        {
          'previewFingerprintVersion': 2,
          'previewFingerprint': 'v1:${'b' * 64}',
          'expectedPreviewFingerprint': 'v1:${'b' * 64}',
        },
        {
          'previewFingerprintVersion': 1,
          'previewFingerprint': 'v1:${'B' * 64}',
          'expectedPreviewFingerprint': 'v1:${'B' * 64}',
        },
        {
          'previewFingerprintVersion': 1,
          'previewFingerprint': 'v1:${'b' * 64}',
          'expectedPreviewFingerprint': 'v1:${'c' * 64}',
        },
      ])
        {
          'version': 2,
          'mode': 'exact',
          'requestedFindingIds': ['finding-a'],
          'planFingerprint': 'a' * 64,
          ...previewFields,
        },
      {
        'version': 2,
        'mode': 'allEligible',
        'requestedFindingIds': <String>[],
        'planFingerprint': 'a' * 64,
        'previewFingerprintVersion': 1,
        'previewFingerprint': 'v1:${'b' * 64}',
        'expectedPreviewFingerprint': 'v1:${'b' * 64}',
      },
    ]) {
      expect(
        () => QuarantineManifest.fromJson(manifestWith(selection)),
        throwsFormatException,
        reason: '$selection must fail closed',
      );
    }

    final legacy = manifestWith({
      'version': 1,
      'mode': 'exact',
      'requestedFindingIds': ['finding-a'],
      'planFingerprint': 'a' * 64,
    })..['version'] = '2.0.0';
    expect(() => QuarantineManifest.fromJson(legacy), throwsFormatException);
  });

  test('verification evidence snapshots step lists and JSON output', () {
    final required = <String>['analyze'];
    final observed = <String>['analyze'];
    final evidence = QuarantineVerificationEvidence(
      policyHash: 'policy-hash',
      requiredStepIds: required,
      observedStepIds: observed,
      workingDirectory: '/workspace/example',
      toolchainIdentity: 'toolchain-hash',
      available: true,
      passed: true,
    );

    required.add('test');
    observed.clear();
    final json = evidence.toJson();
    (json['requiredStepIds'] as List<String>).add('external');
    (json['observedStepIds'] as List<String>).clear();

    expect(evidence.requiredStepIds, ['analyze']);
    expect(evidence.observedStepIds, ['analyze']);
    expect(() => evidence.requiredStepIds.add('test'), throwsUnsupportedError);
    expect(() => evidence.observedStepIds.clear(), throwsUnsupportedError);
  });
}

VerificationBaselineEvidence _waveCandidateEvidence() =>
    VerificationBaselineEvidence(
      policyHash: 'policy-hash',
      requiredStepIds: const ['analyze'],
      requiredParserKinds: const [VerificationOutputParserKind.humanAnalyzer],
      workingDirectory: '/workspace/example',
      toolchainIdentity: 'toolchain-hash',
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
