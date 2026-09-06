import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('L10nArbMutation', () {
    test('creates valid ARB mutation', () {
      final mutation = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: ImmutableBytes.fromString('{"key":"value"}'),
        originalHash: 'hash1',
        candidateBytes: ImmutableBytes.fromString('{}'),
        candidateHash: 'hash2',
        mode: 420,
      );

      expect(mutation.relativePath, 'lib/l10n/app_en.arb');
      expect(mutation.originalHash, 'hash1');
      expect(mutation.candidateHash, 'hash2');
      expect(mutation.mode, 420);
    });

    test('equality works correctly', () {
      final mutation1 = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: ImmutableBytes.fromString('{"key":"value"}'),
        originalHash: 'hash1',
        candidateBytes: ImmutableBytes.fromString('{}'),
        candidateHash: 'hash2',
        mode: 420,
      );

      final mutation2 = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: ImmutableBytes.fromString('{"key":"value"}'),
        originalHash: 'hash1',
        candidateBytes: ImmutableBytes.fromString('{}'),
        candidateHash: 'hash2',
        mode: 420,
      );

      expect(mutation1, mutation2);
      expect(mutation1.hashCode, mutation2.hashCode);
    });
  });

  group('L10nGeneratedOutputMutation', () {
    test('creates mutation for existing file', () {
      final mutation = L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations_en.dart',
        originalBytes: ImmutableBytes.fromString('class AppLocalizationsEn {}'),
        originalHash: 'hash1',
        candidateBytes: ImmutableBytes.fromString(
          'class AppLocalizationsEn { /* updated */ }',
        ),
        candidateHash: 'hash2',
        mode: 420,
      );

      expect(mutation.relativePath, 'lib/l10n/app_localizations_en.dart');
      expect(mutation.originalBytes, isNotNull);
      expect(mutation.originalHash, 'hash1');
    });

    test('creates mutation for new file', () {
      final mutation = L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations_en.dart',
        originalBytes: null,
        originalHash: null,
        candidateBytes: ImmutableBytes.fromString(
          'class AppLocalizationsEn {}',
        ),
        candidateHash: 'hash1',
        mode: 420,
      );

      expect(mutation.originalBytes, isNull);
      expect(mutation.originalHash, isNull);
    });

    test('equality works correctly', () {
      final mutation1 = L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations_en.dart',
        originalBytes: null,
        originalHash: null,
        candidateBytes: ImmutableBytes.fromString(
          'class AppLocalizationsEn {}',
        ),
        candidateHash: 'hash1',
        mode: 420,
      );

      final mutation2 = L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations_en.dart',
        originalBytes: null,
        originalHash: null,
        candidateBytes: ImmutableBytes.fromString(
          'class AppLocalizationsEn {}',
        ),
        candidateHash: 'hash1',
        mode: 420,
      );

      expect(mutation1, mutation2);
      expect(mutation1.hashCode, mutation2.hashCode);
    });
  });

  group('L10nRemovalBatch', () {
    L10nRemovalBatch createValidBatch({
      String familyId = 'family1',
      Set<String>? selectedKeys,
      Set<String>? findingIds,
      List<L10nArbMutation>? arbMutations,
      List<L10nGeneratedOutputMutation>? generatedOutputMutations,
      MutationFootprint? footprint,
    }) {
      final effectiveFindingIds = findingIds ?? {'finding1'};
      final effectiveKeys =
          selectedKeys ??
          (effectiveFindingIds.length == 1
              ? {'key1'}
              : {
                  for (
                    var index = 0;
                    index < effectiveFindingIds.length;
                    index++
                  )
                    'key${index + 1}',
                });
      final sortedFindingIds = effectiveFindingIds.toList()..sort();
      final sortedKeys = effectiveKeys.toList()..sort();
      final selection = L10nMutationSelection(
        requestedFindingIds: effectiveFindingIds,
        effectiveFindingIds: effectiveFindingIds,
        findingIdToKey: {
          for (var index = 0; index < sortedFindingIds.length; index++)
            sortedFindingIds[index]: sortedKeys[index],
        },
      );

      return L10nRemovalBatch(
        familyId: familyId,
        selection: selection,
        arbMutations:
            arbMutations ??
            [
              L10nArbMutation(
                relativePath: 'lib/l10n/app_en.arb',
                originalBytes: ImmutableBytes.fromString('{"key1":"value1"}'),
                originalHash: 'hash1',
                candidateBytes: ImmutableBytes.fromString('{}'),
                candidateHash: 'hash2',
                mode: 420,
              ),
            ],
        generatedOutputMutations: generatedOutputMutations ?? [],
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'toolchain-fp',
        footprint:
            footprint ??
            MutationFootprint(
              findingIds: {'finding1'},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
              familyId: familyId,
            ),
      );
    }

    test('creates valid batch', () {
      final batch = createValidBatch();

      expect(batch.familyId, 'family1');
      expect(batch.selectedKeys, {'key1'});
      expect(batch.findingIds, {'finding1'});
      expect(batch.arbMutations, hasLength(1));
      expect(batch.generatedOutputMutations, isEmpty);
    });

    test('validates successfully for valid batch', () {
      final batch = createValidBatch();
      expect(() => batch.validate(), returnsNormally);
    });

    test('validation fails when no ARB mutations', () {
      final batch = createValidBatch(arbMutations: []);

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('At least one ARB mutation is required'),
          ),
        ),
      );
    });

    test('validation fails when no finding IDs', () {
      final batch = createValidBatch(findingIds: {});

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('At least one finding ID is required'),
          ),
        ),
      );
    });

    test('validation fails when footprint is not boundedFamily', () {
      final batch = createValidBatch(
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedSingle,
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Footprint must have boundedFamily risk scope'),
          ),
        ),
      );
    });

    test('validation fails when footprint familyId mismatches', () {
      final batch = createValidBatch(
        familyId: 'family1',
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family2',
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Footprint familyId must match batch familyId'),
          ),
        ),
      );
    });

    test('validation fails when ARB path is absolute', () {
      final batch = createValidBatch(
        arbMutations: [
          L10nArbMutation(
            relativePath: '/absolute/path/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'/absolute/path/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Path must be relative to project root'),
          ),
        ),
      );
    });

    test('validation fails when generated path is absolute', () {
      final batch = createValidBatch(
        generatedOutputMutations: [
          L10nGeneratedOutputMutation(
            relativePath: '/absolute/path/app_localizations.dart',
            originalBytes: null,
            originalHash: null,
            candidateBytes: ImmutableBytes.fromString('class {}'),
            candidateHash: 'hash1',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {
            'lib/l10n/app_en.arb',
            '/absolute/path/app_localizations.dart',
          },
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Path must be relative to project root'),
          ),
        ),
      );
    });

    test('validation fails with duplicate ARB paths', () {
      final batch = createValidBatch(
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Duplicate path in ARB mutations'),
          ),
        ),
      );
    });

    test('validation fails with duplicate paths across ARB and generated', () {
      final batch = createValidBatch(
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
        ],
        generatedOutputMutations: [
          L10nGeneratedOutputMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: null,
            originalHash: null,
            candidateBytes: ImmutableBytes.fromString('class {}'),
            candidateHash: 'hash1',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Duplicate path across mutations'),
          ),
        ),
      );
    });

    test('handles single key removal', () {
      final batch = createValidBatch(
        selectedKeys: {'obsoleteKey'},
        findingIds: {'finding1'},
      );

      batch.validate();
      expect(batch.selectedKeys, {'obsoleteKey'});
      expect(batch.findingIds, {'finding1'});
    });

    test('handles multiple keys removal', () {
      final batch = createValidBatch(
        selectedKeys: {'key1', 'key2', 'key3'},
        findingIds: {'finding1', 'finding2', 'finding3'},
      );

      batch.validate();
      expect(batch.selectedKeys, {'key1', 'key2', 'key3'});
      expect(batch.findingIds, {'finding1', 'finding2', 'finding3'});
    });

    test('handles template + multiple locales', () {
      final batch = createValidBatch(
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{"key":"en"}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
          L10nArbMutation(
            relativePath: 'lib/l10n/app_es.arb',
            originalBytes: ImmutableBytes.fromString('{"key":"es"}'),
            originalHash: 'hash3',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash4',
            mode: 420,
          ),
          L10nArbMutation(
            relativePath: 'lib/l10n/app_fr.arb',
            originalBytes: ImmutableBytes.fromString('{"key":"fr"}'),
            originalHash: 'hash5',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash6',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {
            'lib/l10n/app_en.arb',
            'lib/l10n/app_es.arb',
            'lib/l10n/app_fr.arb',
          },
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      batch.validate();
      expect(batch.arbMutations, hasLength(3));
    });

    test('handles generated outputs for existing files', () {
      final batch = createValidBatch(
        generatedOutputMutations: [
          L10nGeneratedOutputMutation(
            relativePath: 'lib/l10n/app_localizations.dart',
            originalBytes: ImmutableBytes.fromString('class Old {}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('class New {}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {
            'lib/l10n/app_en.arb',
            'lib/l10n/app_localizations.dart',
          },
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      batch.validate();
      expect(batch.generatedOutputMutations, hasLength(1));
      expect(batch.generatedOutputMutations.first.originalBytes, isNotNull);
    });

    test('handles generated outputs for new files', () {
      final batch = createValidBatch(
        generatedOutputMutations: [
          L10nGeneratedOutputMutation(
            relativePath: 'lib/l10n/app_localizations.dart',
            originalBytes: null,
            originalHash: null,
            candidateBytes: ImmutableBytes.fromString('class New {}'),
            candidateHash: 'hash1',
            mode: 420,
          ),
        ],
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {
            'lib/l10n/app_en.arb',
            'lib/l10n/app_localizations.dart',
          },
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      batch.validate();
      expect(batch.generatedOutputMutations, hasLength(1));
      expect(batch.generatedOutputMutations.first.originalBytes, isNull);
    });

    test('footprint consistency with batch metadata', () {
      final findingIds = {'finding1', 'finding2'};
      final physicalPaths = {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'};

      final batch = createValidBatch(
        familyId: 'family1',
        findingIds: findingIds,
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash1',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash2',
            mode: 420,
          ),
          L10nArbMutation(
            relativePath: 'lib/l10n/app_es.arb',
            originalBytes: ImmutableBytes.fromString('{}'),
            originalHash: 'hash3',
            candidateBytes: ImmutableBytes.fromString('{}'),
            candidateHash: 'hash4',
            mode: 420,
          ),
        ],
        footprint: MutationFootprint(
          findingIds: findingIds,
          physicalPaths: physicalPaths,
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
      );

      batch.validate();
      expect(batch.footprint.findingIds, findingIds);
      expect(batch.footprint.physicalPaths, physicalPaths);
      expect(batch.footprint.riskScope, ActionRiskScope.boundedFamily);
      expect(batch.footprint.familyId, 'family1');
    });

    test('equality works correctly', () {
      final batch1 = createValidBatch();
      final batch2 = createValidBatch();

      expect(batch1, batch2);
      expect(batch1.hashCode, batch2.hashCode);
    });
  });
}
