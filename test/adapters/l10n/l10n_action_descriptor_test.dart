import 'package:flutter_pruner/src/adapters/l10n/l10n_action_descriptor.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('L10nActionDescriptor', () {
    test('constructs with all required fields', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final descriptor = L10nActionDescriptor(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.familyId, equals('app_localizations'));
      expect(descriptor.selectedKeys, equals({'greeting'}));
      expect(descriptor.footprint, equals(footprint));
      expect(descriptor.hasExternalConsumerExposure, isFalse);
    });

    test('riskScope is always boundedFamily', () {
      final descriptor = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting'},
      );

      expect(descriptor.riskScope, equals(ActionRiskScope.boundedFamily));
    });

    test('equality works correctly', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      expect(descriptor1, equals(descriptor2));
      expect(descriptor1.hashCode, equals(descriptor2.hashCode));
    });

    test('different familyId results in inequality', () {
      final descriptor1 = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting'},
      );

      final descriptor2 = _createDescriptor(
        familyId: 'other_localizations',
        keys: {'greeting'},
      );

      expect(descriptor1, isNot(equals(descriptor2)));
    });

    test('different selectedKeys results in inequality', () {
      final descriptor1 = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting'},
      );

      final descriptor2 = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'farewell'},
      );

      expect(descriptor1, isNot(equals(descriptor2)));
    });

    test('different external exposure results in inequality', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final descriptor1 = L10nActionDescriptor(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        footprint: footprint,
        hasExternalConsumerExposure: false,
      );

      final descriptor2 = L10nActionDescriptor(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        footprint: footprint,
        hasExternalConsumerExposure: true,
      );

      expect(descriptor1, isNot(equals(descriptor2)));
    });

    test('application mode has no external exposure', () {
      final descriptor = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting'},
        hasExternalConsumerExposure: false,
      );

      expect(descriptor.hasExternalConsumerExposure, isFalse);
    });

    test('package-internal mode has external exposure', () {
      final descriptor = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting'},
        hasExternalConsumerExposure: true,
      );

      expect(descriptor.hasExternalConsumerExposure, isTrue);
    });

    test('multiple keys in descriptor', () {
      final descriptor = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting', 'farewell', 'welcome'},
      );

      expect(descriptor.selectedKeys, hasLength(3));
      expect(descriptor.selectedKeys, containsAll(['greeting', 'farewell', 'welcome']));
    });

    test('toString includes key information', () {
      final descriptor = _createDescriptor(
        familyId: 'app_localizations',
        keys: {'greeting', 'farewell'},
        hasExternalConsumerExposure: true,
      );

      final str = descriptor.toString();

      expect(str, contains('family: app_localizations'));
      expect(str, contains('keys: 2'));
      expect(str, contains('externalExposure: true'));
    });
  });
}

// Test helpers

L10nActionDescriptor _createDescriptor({
  required String familyId,
  required Set<String> keys,
  bool hasExternalConsumerExposure = false,
}) {
  final footprint = MutationFootprint(
    findingIds: keys.map((key) => 'l10n:$familyId/$key').toSet(),
    physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
    riskScope: ActionRiskScope.boundedFamily,
    familyId: familyId,
  );

  return L10nActionDescriptor(
    familyId: familyId,
    selectedKeys: keys,
    footprint: footprint,
    hasExternalConsumerExposure: hasExternalConsumerExposure,
  );
}
