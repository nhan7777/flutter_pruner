import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_journal_builder.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_expectation.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('L10nBatchJournalBuilder', () {
    late L10nBatchJournalBuilder builder;

    setUp(() {
      builder = const L10nBatchJournalBuilder();
    });

    test('builds quarantine entries with baseline hashes', () {
      final batch = _createTestBatch();

      final entries = builder.buildQuarantineEntries(batch);

      expect(entries.length, equals(2)); // 1 ARB + 1 generated

      // ARB entry
      final arbEntry = entries[0];
      expect(arbEntry.originalPath, equals('lib/l10n/app_en.arb'));
      expect(arbEntry.sha256, equals('baseline-arb-hash'));
      expect(arbEntry.sizeBytes, equals(100));
      expect(arbEntry.wasAbsentBeforeTransaction, isFalse);

      // Generated entry
      final genEntry = entries[1];
      expect(genEntry.originalPath, equals('lib/l10n/app_localizations.dart'));
      expect(genEntry.sha256, equals('baseline-gen-hash'));
      expect(genEntry.sizeBytes, equals(200));
      expect(genEntry.wasAbsentBeforeTransaction, isFalse);
    });

    test('marks absent files correctly in quarantine entries', () {
      final batch = _createBatchWithAbsentGenerated();

      final entries = builder.buildQuarantineEntries(batch);

      final genEntry = entries.firstWhere(
        (e) => e.originalPath.endsWith('.dart'),
      );

      expect(genEntry.wasAbsentBeforeTransaction, isTrue);
      expect(genEntry.sizeBytes, equals(0));
      expect(
        genEntry.sha256,
        equals(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
    });

    test('builds mutation expectation with candidate hashes', () {
      final batch = _createTestBatch();

      final expectation = builder.buildExpectation(batch);

      expect(expectation.familyId, equals('test-family'));
      expect(expectation.configurationFingerprint, equals('config-fp'));
      expect(expectation.writeExpectations.length, equals(2));

      // ARB expectation
      final arbExpectation = expectation.writeExpectations[0];
      expect(arbExpectation.path, equals('lib/l10n/app_en.arb'));
      expect(arbExpectation.role, equals(FileRole.arb));
      expect(arbExpectation.baselineHash, equals('baseline-arb-hash'));
      expect(arbExpectation.candidateHash, equals('candidate-arb-hash'));
      expect(arbExpectation.wasAbsent, isFalse);

      // Generated expectation
      final genExpectation = expectation.writeExpectations[1];
      expect(genExpectation.path, equals('lib/l10n/app_localizations.dart'));
      expect(genExpectation.role, equals(FileRole.generated));
      expect(genExpectation.baselineHash, equals('baseline-gen-hash'));
      expect(genExpectation.candidateHash, equals('candidate-gen-hash'));
    });

    test('builds generated output inventory', () {
      final batch = _createTestBatch();

      final expectation = builder.buildExpectation(batch);

      expect(expectation.generatedOutputInventory.length, equals(1));

      final inventory = expectation.generatedOutputInventory[0];
      expect(inventory.path, equals('lib/l10n/app_localizations.dart'));
      expect(inventory.expectedHash, equals('candidate-gen-hash'));
      expect(inventory.sizeBytes, equals(300));
    });

    test('computes deterministic selection fingerprint', () {
      final batch1 = _createTestBatch();
      final batch2 = _createTestBatch();

      final exp1 = builder.buildExpectation(batch1);
      final exp2 = builder.buildExpectation(batch2);

      expect(exp1.selectionFingerprint, equals(exp2.selectionFingerprint));
      expect(exp1.selectionFingerprint, isNotEmpty);
      expect(exp1.selectionFingerprint.length, equals(64)); // SHA-256 hex
    });

    test('validates expectation after building', () {
      final batch = _createTestBatch();

      final expectation = builder.buildExpectation(batch);

      // Should not throw
      expect(() => expectation.validate(), returnsNormally);
    });

    test('handles absent generated files in expectation', () {
      final batch = _createBatchWithAbsentGenerated();

      final expectation = builder.buildExpectation(batch);

      final genExpectation = expectation.writeExpectations.firstWhere(
        (e) => e.role == FileRole.generated,
      );

      expect(genExpectation.wasAbsent, isTrue);
      expect(
        genExpectation.baselineHash,
        equals(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
    });

    test('preserves posixMode in quarantine entries', () {
      final batch = _createTestBatch();

      final entries = builder.buildQuarantineEntries(batch);

      final arbEntry = entries[0];
      expect(arbEntry.posixMode, equals(420)); // 0o644 in decimal
    });

    test('sets posixMode to null when mode is 0', () {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'test:id'},
        effectiveFindingIds: {'test:id'},
        findingIdToKey: {'test:id': 'key'},
      );

      final batch = L10nRemovalBatch(
        familyId: 'test',
        selection: selection,
        arbMutations: [
          L10nArbMutation(
            relativePath: 'test.arb',
            originalBytes: ImmutableBytes.copyOf([1, 2, 3]),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.copyOf([4, 5, 6]),
            candidateHash: 'hash2',
            mode: 0, // Windows or no mode
          ),
        ],
        generatedOutputMutations: [],
        configurationFingerprint: 'config',
        packageResolutionFingerprint: 'pkg',
        toolchainFingerprint: 'tool',
        footprint: MutationFootprint(
          familyId: 'test',
          findingIds: {'test:id'},
          physicalPaths: {'test.arb'},
          riskScope: ActionRiskScope.boundedFamily,
        ),
      );

      final entries = builder.buildQuarantineEntries(batch);

      expect(entries[0].posixMode, isNull);
    });
  });
}

L10nRemovalBatch _createTestBatch() {
  final selection = L10nMutationSelection(
    requestedFindingIds: {'l10n:test.key1'},
    effectiveFindingIds: {'l10n:test.key1'},
    findingIdToKey: {'l10n:test.key1': 'key1'},
  );

  return L10nRemovalBatch(
    familyId: 'test-family',
    selection: selection,
    arbMutations: [
      L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: ImmutableBytes.copyOf(List.filled(100, 1)),
        originalHash: 'baseline-arb-hash',
        candidateBytes: ImmutableBytes.copyOf(List.filled(150, 2)),
        candidateHash: 'candidate-arb-hash',
        mode: 420, // 0o644
      ),
    ],
    generatedOutputMutations: [
      L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations.dart',
        originalBytes: ImmutableBytes.copyOf(List.filled(200, 3)),
        originalHash: 'baseline-gen-hash',
        candidateBytes: ImmutableBytes.copyOf(List.filled(300, 4)),
        candidateHash: 'candidate-gen-hash',
        mode: 420, // 0o644
      ),
    ],
    configurationFingerprint: 'config-fp',
    packageResolutionFingerprint: 'pkg-fp',
    toolchainFingerprint: 'tool-fp',
    footprint: MutationFootprint(
      familyId: 'test-family',
      findingIds: {'l10n:test.key1'},
      physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_localizations.dart'},
      riskScope: ActionRiskScope.boundedFamily,
    ),
  );
}

L10nRemovalBatch _createBatchWithAbsentGenerated() {
  final selection = L10nMutationSelection(
    requestedFindingIds: {'l10n:test.key1'},
    effectiveFindingIds: {'l10n:test.key1'},
    findingIdToKey: {'l10n:test.key1': 'key1'},
  );

  return L10nRemovalBatch(
    familyId: 'test-family',
    selection: selection,
    arbMutations: [
      L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: ImmutableBytes.copyOf(List.filled(100, 1)),
        originalHash: 'baseline-arb-hash',
        candidateBytes: ImmutableBytes.copyOf(List.filled(150, 2)),
        candidateHash: 'candidate-arb-hash',
        mode: 420, // 0o644
      ),
    ],
    generatedOutputMutations: [
      L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations.dart',
        originalBytes: null, // File was absent
        originalHash: null,
        candidateBytes: ImmutableBytes.copyOf(List.filled(300, 4)),
        candidateHash: 'candidate-gen-hash',
        mode: 420, // 0o644
      ),
    ],
    configurationFingerprint: 'config-fp',
    packageResolutionFingerprint: 'pkg-fp',
    toolchainFingerprint: 'tool-fp',
    footprint: MutationFootprint(
      familyId: 'test-family',
      findingIds: {'l10n:test.key1'},
      physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_localizations.dart'},
      riskScope: ActionRiskScope.boundedFamily,
    ),
  );
}
