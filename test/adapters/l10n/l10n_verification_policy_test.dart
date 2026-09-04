import 'package:flutter_pruner/src/adapters/l10n/l10n_verification_policy.dart';
import 'package:test/test.dart';

void main() {
  group('L10nVerificationPolicy', () {
    test('singleton instance is accessible', () {
      expect(L10nVerificationPolicy.instance, isNotNull);
      expect(
        L10nVerificationPolicy.instance,
        same(L10nVerificationPolicy.instance),
      );
    });

    test('allowsFindingResolution returns false', () {
      expect(
        L10nVerificationPolicy.instance.allowsFindingResolution,
        isFalse,
      );
    });

    test('requiresVerification returns true', () {
      expect(
        L10nVerificationPolicy.instance.requiresVerification,
        isTrue,
      );
    });

    test('supportsQuarantine returns true', () {
      expect(
        L10nVerificationPolicy.instance.supportsQuarantine,
        isTrue,
      );
    });

    test('requiresFamilyAtomicity returns true', () {
      expect(
        L10nVerificationPolicy.instance.requiresFamilyAtomicity,
        isTrue,
      );
    });

    test('requiresDeterministicInverse returns true', () {
      expect(
        L10nVerificationPolicy.instance.requiresDeterministicInverse,
        isTrue,
      );
    });

    group('validateFindingEligibility', () {
      test('accepts valid l10n localization key finding', () {
        final error = L10nVerificationPolicy.instance.validateFindingEligibility(
          findingId: 'l10n:app/greeting',
          adapterId: 'l10n',
          isLocalizationKey: true,
          hasProposedAction: false,
        );

        expect(error, isNull);
      });

      test('rejects non-l10n adapter finding', () {
        final error = L10nVerificationPolicy.instance.validateFindingEligibility(
          findingId: 'other:app/greeting',
          adapterId: 'other',
          isLocalizationKey: true,
          hasProposedAction: false,
        );

        expect(error, equals('L10n mutations only apply to l10n adapter findings'));
      });

      test('rejects non-localization key node', () {
        final error = L10nVerificationPolicy.instance.validateFindingEligibility(
          findingId: 'l10n:app/greeting',
          adapterId: 'l10n',
          isLocalizationKey: false,
          hasProposedAction: false,
        );

        expect(error, equals('L10n mutations only apply to localization key nodes'));
      });

      test('rejects finding with existing proposed action', () {
        final error = L10nVerificationPolicy.instance.validateFindingEligibility(
          findingId: 'l10n:app/greeting',
          adapterId: 'l10n',
          isLocalizationKey: true,
          hasProposedAction: true,
        );

        expect(
          error,
          equals('Finding already has proposed action (Stage 1 contract violation)'),
        );
      });
    });

    group('validateBatch', () {
      test('accepts valid batch parameters', () {
        final error = L10nVerificationPolicy.instance.validateBatch(
          arbMutationCount: 2,
          findingCount: 1,
          isBoundedFamily: true,
          hasOnlyRelativePaths: true,
        );

        expect(error, isNull);
      });

      test('rejects empty ARB mutations', () {
        final error = L10nVerificationPolicy.instance.validateBatch(
          arbMutationCount: 0,
          findingCount: 1,
          isBoundedFamily: true,
          hasOnlyRelativePaths: true,
        );

        expect(error, equals('Batch must contain at least one ARB mutation'));
      });

      test('rejects empty finding IDs', () {
        final error = L10nVerificationPolicy.instance.validateBatch(
          arbMutationCount: 2,
          findingCount: 0,
          isBoundedFamily: true,
          hasOnlyRelativePaths: true,
        );

        expect(error, equals('Batch must address at least one finding'));
      });

      test('rejects non-boundedFamily scope', () {
        final error = L10nVerificationPolicy.instance.validateBatch(
          arbMutationCount: 2,
          findingCount: 1,
          isBoundedFamily: false,
          hasOnlyRelativePaths: true,
        );

        expect(error, equals('L10n batches must be boundedFamily scope'));
      });

      test('rejects absolute paths', () {
        final error = L10nVerificationPolicy.instance.validateBatch(
          arbMutationCount: 2,
          findingCount: 1,
          isBoundedFamily: true,
          hasOnlyRelativePaths: false,
        );

        expect(error, equals('All batch paths must be relative to project root'));
      });
    });

    test('toString includes key policy values', () {
      final str = L10nVerificationPolicy.instance.toString();

      expect(str, contains('allowsResolution: false'));
      expect(str, contains('requiresVerification: true'));
      expect(str, contains('requiresAtomicity: true'));
    });
  });
}
