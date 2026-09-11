import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_expectation.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_outcome_accountant.dart';
import 'package:test/test.dart';

void main() {
  group('L10nOutcomeAccountant', () {
    const accountant = L10nOutcomeAccountant();

    test('all findings marked applied when verification succeeds', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'finding1', 'finding2'},
        effectiveFindingIds: {'finding1', 'finding2'},
        findingIdToKey: {'finding1': 'key1', 'finding2': 'key2'},
      );

      final expectation = L10nMutationExpectation(
        familyId: 'family1',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [],
        generatedOutputInventory: [],
      );

      final verification = VerificationSuccess(
        familyId: 'family1',
        verifiedPaths: ['app_en.arb'],
      );

      final result = accountant.account(
        familyId: 'family1',
        selection: selection,
        expectation: expectation,
        verificationResult: verification,
      );

      expect(result.familyId, 'family1');
      expect(result.requestedFindingIds, {'finding1', 'finding2'});
      expect(result.effectiveFindingIds, {'finding1', 'finding2'});
      expect(result.outcomes.keys, {'finding1', 'finding2'});
      expect(result.outcomes['finding1'], FindingOutcome.applied);
      expect(result.outcomes['finding2'], FindingOutcome.applied);
      expect(result.allApplied, true);
      expect(result.anyFailed, false);
      expect(result.appliedCount, 2);
      expect(result.failedCount, 0);
    });

    test('all findings marked failed when verification fails', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'finding1', 'finding2'},
        effectiveFindingIds: {'finding1', 'finding2'},
        findingIdToKey: {'finding1': 'key1', 'finding2': 'key2'},
      );

      final expectation = L10nMutationExpectation(
        familyId: 'family1',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [],
        generatedOutputInventory: [],
      );

      final mismatches = [
        VerificationMismatch(
          path: 'app_en.arb',
          role: FileRole.arb,
          expected: 'hash1',
          observed: 'hash2',
          reason: 'Hash mismatch',
        ),
      ];

      final verification = VerificationFailed(
        familyId: 'family1',
        mismatches: mismatches,
      );

      final result = accountant.account(
        familyId: 'family1',
        selection: selection,
        expectation: expectation,
        verificationResult: verification,
      );

      expect(result.familyId, 'family1');
      expect(result.outcomes.keys, {'finding1', 'finding2'});
      expect(result.outcomes['finding1'], isA<FindingOutcomeFailed>());
      expect(result.outcomes['finding2'], isA<FindingOutcomeFailed>());
      expect(result.allApplied, false);
      expect(result.anyFailed, true);
      expect(result.appliedCount, 0);
      expect(result.failedCount, 2);

      final failed1 = result.outcomes['finding1'] as FindingOutcomeFailed;
      expect(failed1.reason, 'Verification failed: 1 mismatch(es)');
      expect(failed1.verificationMismatches, mismatches);
    });

    test('handles single effective finding', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'finding1'},
        effectiveFindingIds: {'finding1'},
        findingIdToKey: {'finding1': 'key1'},
      );

      final expectation = L10nMutationExpectation(
        familyId: 'family1',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [],
        generatedOutputInventory: [],
      );

      final verification = VerificationSuccess(
        familyId: 'family1',
        verifiedPaths: ['app_en.arb'],
      );

      final result = accountant.account(
        familyId: 'family1',
        selection: selection,
        expectation: expectation,
        verificationResult: verification,
      );

      expect(result.outcomes.keys, {'finding1'});
      expect(result.outcomes['finding1'], FindingOutcome.applied);
      expect(result.appliedCount, 1);
      expect(result.failedCount, 0);
    });

    test('handles multiple verification mismatches', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'finding1', 'finding2', 'finding3'},
        effectiveFindingIds: {'finding1', 'finding2', 'finding3'},
        findingIdToKey: {
          'finding1': 'key1',
          'finding2': 'key2',
          'finding3': 'key3',
        },
      );

      final expectation = L10nMutationExpectation(
        familyId: 'family1',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [],
        generatedOutputInventory: [],
      );

      final mismatches = [
        VerificationMismatch(
          path: 'app_en.arb',
          role: FileRole.arb,
          expected: 'hash1',
          observed: 'hash2',
          reason: 'Hash mismatch',
        ),
        VerificationMismatch(
          path: 'app_localizations.dart',
          role: FileRole.generated,
          expected: 'hash3',
          observed: 'hash4',
          reason: 'Hash mismatch',
        ),
      ];

      final verification = VerificationFailed(
        familyId: 'family1',
        mismatches: mismatches,
      );

      final result = accountant.account(
        familyId: 'family1',
        selection: selection,
        expectation: expectation,
        verificationResult: verification,
      );

      expect(result.outcomes.length, 3);
      expect(result.failedCount, 3);

      final failed = result.outcomes['finding1'] as FindingOutcomeFailed;
      expect(failed.reason, 'Verification failed: 2 mismatch(es)');
      expect(failed.verificationMismatches.length, 2);
    });

    test(
      'rejects mismatched familyId between expectation and verification',
      () {
        final selection = L10nMutationSelection(
          requestedFindingIds: {'finding1'},
          effectiveFindingIds: {'finding1'},
          findingIdToKey: {'finding1': 'key1'},
        );

        final expectation = L10nMutationExpectation(
          familyId: 'family1',
          selectionFingerprint: 'sel-fp',
          configurationFingerprint: 'config-fp',
          packageResolutionFingerprint: 'pkg-fp',
          toolchainFingerprint: 'tool-fp',
          writeExpectations: [],
          generatedOutputInventory: [],
        );

        final verification = VerificationSuccess(
          familyId: 'family2',
          verifiedPaths: ['app_en.arb'],
        );

        expect(
          () => accountant.account(
            familyId: 'family1',
            selection: selection,
            expectation: expectation,
            verificationResult: verification,
          ),
          throwsA(isA<ArgumentError>()),
        );
      },
    );

    test('handles requested vs effective finding distinction', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'finding1', 'finding2'},
        effectiveFindingIds: {'finding1', 'finding2', 'finding3'},
        findingIdToKey: {
          'finding1': 'key1',
          'finding2': 'key2',
          'finding3': 'key3',
        },
        expansionReasons: {'finding3': 'Dependency of finding1'},
      );

      final expectation = L10nMutationExpectation(
        familyId: 'family1',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [],
        generatedOutputInventory: [],
      );

      final verification = VerificationSuccess(
        familyId: 'family1',
        verifiedPaths: ['app_en.arb'],
      );

      final result = accountant.account(
        familyId: 'family1',
        selection: selection,
        expectation: expectation,
        verificationResult: verification,
      );

      expect(result.requestedFindingIds, {'finding1', 'finding2'});
      expect(result.effectiveFindingIds, {'finding1', 'finding2', 'finding3'});
      expect(result.outcomes.keys, {'finding1', 'finding2', 'finding3'});
      expect(result.appliedCount, 3);
    });

    test('FindingOutcome.applied equality', () {
      expect(FindingOutcome.applied, FindingOutcome.applied);
      expect(FindingOutcome.applied == FindingOutcome.applied, true);
    });

    test('FindingOutcomeFailed equality', () {
      final failed1 = FindingOutcome.failed(
        reason: 'test',
        verificationMismatches: [
          VerificationMismatch(
            path: 'file.arb',
            role: FileRole.arb,
            expected: 'h1',
            observed: 'h2',
            reason: 'mismatch',
          ),
        ],
      );

      final failed2 = FindingOutcome.failed(
        reason: 'test',
        verificationMismatches: [
          VerificationMismatch(
            path: 'other.arb',
            role: FileRole.arb,
            expected: 'h3',
            observed: 'h4',
            reason: 'different',
          ),
        ],
      );

      expect(failed1 == failed2, true); // Same length, same reason
      expect(FindingOutcome.applied == failed1, false);
    });
  });
}
