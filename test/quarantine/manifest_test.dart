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
        'version': 2,
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
