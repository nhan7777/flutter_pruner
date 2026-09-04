import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('ActionRiskScope', () {
    test('has three values', () {
      expect(ActionRiskScope.values, hasLength(3));
      expect(ActionRiskScope.values, contains(ActionRiskScope.boundedSingle));
      expect(ActionRiskScope.values, contains(ActionRiskScope.boundedFamily));
      expect(ActionRiskScope.values, contains(ActionRiskScope.openEnded));
    });

    test('can be serialized by name', () {
      expect(ActionRiskScope.boundedSingle.name, equals('boundedSingle'));
      expect(ActionRiskScope.boundedFamily.name, equals('boundedFamily'));
      expect(ActionRiskScope.openEnded.name, equals('openEnded'));
    });

    test('can be deserialized from name', () {
      expect(
        ActionRiskScope.values.byName('boundedSingle'),
        equals(ActionRiskScope.boundedSingle),
      );
      expect(
        ActionRiskScope.values.byName('boundedFamily'),
        equals(ActionRiskScope.boundedFamily),
      );
      expect(
        ActionRiskScope.values.byName('openEnded'),
        equals(ActionRiskScope.openEnded),
      );
    });
  });

  group('MutationFootprint', () {
    test('constructs with valid parameters', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(footprint.findingIds, equals({'finding-1'}));
      expect(footprint.physicalPaths, equals({'lib/foo.dart'}));
      expect(footprint.riskScope, equals(ActionRiskScope.boundedSingle));
      expect(footprint.familyId, isNull);
    });

    test('validates successfully for boundedSingle with one finding', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(() => footprint.validate(), returnsNormally);
    });

    test('validates successfully for boundedFamily with familyId', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1', 'finding-2'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      expect(() => footprint.validate(), returnsNormally);
    });

    test('validates successfully for openEnded with multiple findings', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1', 'finding-2', 'finding-3'},
        physicalPaths: {'lib/foo.dart', 'lib/bar.dart'},
        riskScope: ActionRiskScope.openEnded,
      );

      expect(() => footprint.validate(), returnsNormally);
    });

    test('rejects empty findingIds', () {
      final footprint = MutationFootprint(
        findingIds: {},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(
        () => footprint.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('findingIds cannot be empty'),
          ),
        ),
      );
    });

    test('rejects empty physicalPaths', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(
        () => footprint.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('physicalPaths cannot be empty'),
          ),
        ),
      );
    });

    test('rejects boundedFamily without familyId', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1', 'finding-2'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
      );

      expect(
        () => footprint.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('familyId is required for boundedFamily'),
          ),
        ),
      );
    });

    test('rejects boundedSingle with multiple findings', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1', 'finding-2'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(
        () => footprint.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('exactly one finding ID'),
          ),
        ),
      );
    });

    test('allows boundedSingle with multiple physical paths (generated outputs)', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(() => footprint.validate(), returnsNormally);
    });

    test('equality works correctly', () {
      final footprint1 = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final footprint2 = MutationFootprint(
        findingIds: {'finding-1'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final footprint3 = MutationFootprint(
        findingIds: {'finding-2'},
        physicalPaths: {'lib/foo.dart'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      expect(footprint1, equals(footprint2));
      expect(footprint1, isNot(equals(footprint3)));
      expect(footprint1.hashCode, equals(footprint2.hashCode));
    });

    test('equality handles set order independence', () {
      final footprint1 = MutationFootprint(
        findingIds: {'finding-1', 'finding-2'},
        physicalPaths: {'lib/foo.dart', 'lib/bar.dart'},
        riskScope: ActionRiskScope.openEnded,
      );

      final footprint2 = MutationFootprint(
        findingIds: {'finding-2', 'finding-1'},
        physicalPaths: {'lib/bar.dart', 'lib/foo.dart'},
        riskScope: ActionRiskScope.openEnded,
      );

      expect(footprint1, equals(footprint2));
    });

    test('toString provides useful debugging info', () {
      final footprint = MutationFootprint(
        findingIds: {'finding-1', 'finding-2'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final str = footprint.toString();
      expect(str, contains('findings: 2'));
      expect(str, contains('paths: 2'));
      expect(str, contains('boundedFamily'));
      expect(str, contains('family: app_localizations'));
    });
  });
}
