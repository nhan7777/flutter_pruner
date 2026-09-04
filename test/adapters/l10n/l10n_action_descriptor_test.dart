import 'package:flutter_pruner/src/adapters/l10n/l10n_action_descriptor.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('L10nActionDescriptor', () {
    test('creates valid descriptor', () {
      final footprint = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family1',
      );

      final descriptor = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1', 'key2'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.familyId, 'family1');
      expect(descriptor.selectedKeys, {'key1', 'key2'});
      expect(descriptor.footprint, footprint);
      expect(descriptor.hasExternalConsumerExposure, isFalse);
    });

    test('riskScope is always boundedFamily', () {
      final descriptor = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.riskScope, ActionRiskScope.boundedFamily);
    });

    test('equality works correctly', () {
      final footprint = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family1',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1', 'key2'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1', 'key2'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor1, descriptor2);
      expect(descriptor1.hashCode, descriptor2.hashCode);
    });

    test('inequality when familyId differs', () {
      final footprint1 = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family1',
      );

      final footprint2 = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family2',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: footprint1,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'family2',
        selectedKeys: {'key1'},
        footprint: footprint2,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor1, isNot(descriptor2));
    });

    test('inequality when selectedKeys differ', () {
      final footprint = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family1',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key2'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor1, isNot(descriptor2));
    });

    test('inequality when hasExternalConsumerExposure differs', () {
      final footprint = const MutationFootprint(
        findingIds: {'finding1'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'family1',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: footprint,
        hasExternalConsumerExposure: true,
      );

      expect(descriptor1, isNot(descriptor2));
    });

    test('handles single key', () {
      final descriptor = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'singleKey'},
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.selectedKeys, {'singleKey'});
      expect(descriptor.selectedKeys.length, 1);
    });

    test('handles multiple keys', () {
      final descriptor = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1', 'key2', 'key3'},
        footprint: const MutationFootprint(
          findingIds: {'finding1', 'finding2', 'finding3'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.selectedKeys, {'key1', 'key2', 'key3'});
      expect(descriptor.selectedKeys.length, 3);
    });

    test('handles external consumer exposure', () {
      final descriptor = L10nActionDescriptor(
        familyId: 'family1',
        selectedKeys: {'key1'},
        footprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        hasExternalConsumerExposure: true,
      );

      expect(descriptor.hasExternalConsumerExposure, isTrue);
    });
  });
}
