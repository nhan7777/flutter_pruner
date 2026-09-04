import 'package:flutter_pruner/src/core/confidence/action_readiness_index.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:test/test.dart';

void main() {
  group('DeterministicInverseKind', () {
    test('has three values', () {
      expect(DeterministicInverseKind.values, hasLength(3));
      expect(
        DeterministicInverseKind.values,
        contains(DeterministicInverseKind.proven),
      );
      expect(
        DeterministicInverseKind.values,
        contains(DeterministicInverseKind.generative),
      );
      expect(
        DeterministicInverseKind.values,
        contains(DeterministicInverseKind.none),
      );
    });
  });

  group('ActionReadinessEntry', () {
    test('constructs with all required fields', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'app_localizations',
        configurationFingerprint: 'sha256:abc123',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedFamily,
        hasExternalConsumerExposure: false,
      );

      expect(entry.adapterId, equals('l10n'));
      expect(entry.nodeKind, equals(NodeKind.localizationKey));
      expect(entry.familyId, equals('app_localizations'));
      expect(entry.configurationFingerprint, equals('sha256:abc123'));
      expect(entry.mutationFootprint, equals(footprint));
      expect(entry.inverseKind, equals(DeterministicInverseKind.proven));
      expect(entry.riskScope, equals(ActionRiskScope.boundedFamily));
      expect(entry.hasExternalConsumerExposure, isFalse);
    });

    test('equality works correctly', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry1 = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final entry2 = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final entry3 = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family2',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      expect(entry1, equals(entry2));
      expect(entry1, isNot(equals(entry3)));
      expect(entry1.hashCode, equals(entry2.hashCode));
    });

    test('toString provides useful debugging info', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'app_localizations',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final str = entry.toString();
      expect(str, contains('adapter: l10n'));
      expect(str, contains('kind: NodeKind.localizationKey'));
      expect(str, contains('family: app_localizations'));
      expect(str, contains('scope: ActionRiskScope.boundedSingle'));
    });
  });

  group('ActionReadinessIndex', () {
    test('constructs empty index', () {
      final index = ActionReadinessIndex.empty;

      expect(index.isEmpty, isTrue);
      expect(index.isNotEmpty, isFalse);
      expect(index.length, equals(0));
      expect(index.entries, isEmpty);
    });

    test('constructs index with entries', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({
        'l10n:family1/key1': entry,
      });

      expect(index.isEmpty, isFalse);
      expect(index.isNotEmpty, isTrue);
      expect(index.length, equals(1));
      expect(index.entries, hasLength(1));
    });

    test('lookup returns entry when present', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({
        'l10n:family1/key1': entry,
      });

      expect(index['l10n:family1/key1'], equals(entry));
      expect(index.containsNode('l10n:family1/key1'), isTrue);
    });

    test('lookup returns null when absent', () {
      final index = ActionReadinessIndex.empty;

      expect(index['nonexistent'], isNull);
      expect(index.containsNode('nonexistent'), isFalse);
    });

    test('index with multiple entries', () {
      final footprint1 = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final footprint2 = MutationFootprint(
        findingIds: {'finding-2'},
        physicalPaths: {'lib/bar.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry1 = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint1,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final entry2 = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint2,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({
        'l10n:family1/key1': entry1,
        'l10n:family1/key2': entry2,
      });

      expect(index.length, equals(2));
      expect(index['l10n:family1/key1'], equals(entry1));
      expect(index['l10n:family1/key2'], equals(entry2));
      expect(index.entries, containsAll([entry1, entry2]));
    });

    test('index is immutable', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final mutableMap = {'l10n:family1/key1': entry};
      final index = ActionReadinessIndex(mutableMap);

      // Modifying original map should not affect index
      mutableMap['l10n:family1/key2'] = entry;

      expect(index.length, equals(1));
      expect(index.containsNode('l10n:family1/key2'), isFalse);
    });

    test('equality works correctly', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final index1 = ActionReadinessIndex({
        'l10n:family1/key1': entry,
      });

      final index2 = ActionReadinessIndex({
        'l10n:family1/key1': entry,
      });

      final index3 = ActionReadinessIndex.empty;

      expect(index1, equals(index2));
      expect(index1, isNot(equals(index3)));
      expect(index1.hashCode, equals(index2.hashCode));
    });

    test('toString provides useful debugging info', () {
      final index = ActionReadinessIndex.empty;
      expect(index.toString(), contains('entries: 0'));

      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'sha256:abc',
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final indexWithEntries = ActionReadinessIndex({
        'l10n:family1/key1': entry,
      });

      expect(indexWithEntries.toString(), contains('entries: 1'));
    });
  });
}
