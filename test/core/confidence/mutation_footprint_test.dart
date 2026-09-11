import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('MutationFootprint', () {
    group('validation', () {
      test('boundedSingle with one finding ID passes', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        expect(() => footprint.validate(), returnsNormally);
      });

      test('boundedSingle with multiple finding IDs throws', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/file.dart'},
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

      test('boundedFamily without familyId throws', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
          riskScope: ActionRiskScope.boundedFamily,
        );
        expect(
          () => footprint.validate(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('familyId is required'),
            ),
          ),
        );
      });

      test('boundedFamily with familyId passes', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'app_localizations',
        );
        expect(() => footprint.validate(), returnsNormally);
      });

      test('boundedSingle with familyId throws', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
          familyId: 'should-not-be-here',
        );
        expect(
          () => footprint.validate(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('familyId must be null'),
            ),
          ),
        );
      });

      test('empty findingIds throws', () {
        final footprint = MutationFootprint(
          findingIds: {},
          physicalPaths: {'lib/file.dart'},
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

      test('empty physicalPaths throws', () {
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

      test('openEnded with multiple findings and paths passes', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2', 'finding-3'},
          physicalPaths: {'lib/a.dart', 'lib/b.dart', 'lib/c.dart'},
          riskScope: ActionRiskScope.openEnded,
        );
        expect(() => footprint.validate(), returnsNormally);
      });
    });

    group('equality and hashCode', () {
      test('identical footprints are equal', () {
        final a = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        final b = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });

      test('different findingIds are not equal', () {
        final a = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        final b = MutationFootprint(
          findingIds: {'finding-2'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        expect(a, isNot(equals(b)));
      });

      test('different physicalPaths are not equal', () {
        final a = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file1.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        final b = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file2.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        expect(a, isNot(equals(b)));
      });

      test('different riskScope are not equal', () {
        final a = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        final b = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.openEnded,
        );
        expect(a, isNot(equals(b)));
      });

      test('different familyId are not equal', () {
        final a = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family-a',
        );
        final b = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family-b',
        );
        expect(a, isNot(equals(b)));
      });

      test('set order does not affect equality', () {
        final a = MutationFootprint(
          findingIds: {'finding-1', 'finding-2', 'finding-3'},
          physicalPaths: {'path-a', 'path-b', 'path-c'},
          riskScope: ActionRiskScope.openEnded,
        );
        final b = MutationFootprint(
          findingIds: {'finding-3', 'finding-1', 'finding-2'},
          physicalPaths: {'path-c', 'path-a', 'path-b'},
          riskScope: ActionRiskScope.openEnded,
        );
        expect(a, equals(b));
        expect(a.hashCode, equals(b.hashCode));
      });
    });

    group('toString', () {
      test('includes scope, finding count, path count', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1'},
          physicalPaths: {'lib/file.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        final str = footprint.toString();
        expect(str, contains('boundedSingle'));
        expect(str, contains('findings: 1'));
        expect(str, contains('paths: 1'));
        expect(str, isNot(contains('family:')));
      });

      test('includes familyId when present', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2'},
          physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_es.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'app_localizations',
        );
        final str = footprint.toString();
        expect(str, contains('boundedFamily'));
        expect(str, contains('findings: 2'));
        expect(str, contains('paths: 2'));
        expect(str, contains('family: app_localizations'));
      });
    });

    group('realistic scenarios', () {
      test('single Dart declaration removal', () {
        final footprint = MutationFootprint(
          findingIds: {'dart:my_package/lib/utils.dart#unused_function'},
          physicalPaths: {'lib/utils.dart'},
          riskScope: ActionRiskScope.boundedSingle,
        );
        expect(() => footprint.validate(), returnsNormally);
        expect(footprint.riskScope, ActionRiskScope.boundedSingle);
        expect(footprint.familyId, isNull);
      });

      test('l10n family removal with ARB files and generated output', () {
        final footprint = MutationFootprint(
          findingIds: {
            'l10n:app_localizations/unused_greeting',
            'l10n:app_localizations/unused_farewell',
          },
          physicalPaths: {
            'lib/l10n/app_en.arb',
            'lib/l10n/app_es.arb',
            'lib/l10n/app_fr.arb',
            'lib/generated/l10n.dart',
            'lib/generated/l10n_en.dart',
          },
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'app_localizations',
        );
        expect(() => footprint.validate(), returnsNormally);
        expect(footprint.riskScope.isFamily, isTrue);
        expect(footprint.familyId, 'app_localizations');
        expect(footprint.findingIds, hasLength(2));
        expect(footprint.physicalPaths, hasLength(5));
      });

      test('broad removal with multiple files', () {
        final footprint = MutationFootprint(
          findingIds: {'finding-1', 'finding-2', 'finding-3'},
          physicalPaths: {
            'lib/old_feature/a.dart',
            'lib/old_feature/b.dart',
            'lib/old_feature/c.dart',
          },
          riskScope: ActionRiskScope.openEnded,
        );
        expect(() => footprint.validate(), returnsNormally);
        expect(footprint.riskScope, ActionRiskScope.openEnded);
        expect(footprint.familyId, isNull);
      });
    });
  });
}
