import 'dart:typed_data';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:test/test.dart';

void main() {
  group('ImmutableBytes', () {
    test('retains defensive source and copy snapshots', () {
      final source = Uint8List.fromList([1, 2, 3]);
      final bytes = ImmutableBytes.copyOf(source);

      source[0] = 9;
      final returnedCopy = bytes.copy();
      returnedCopy[1] = 9;

      expect(bytes.length, 3);
      expect(bytes[2], 3);
      expect(bytes.copy(), [1, 2, 3]);
    });

    test('retains bytes when copies are held through maps and sets', () {
      final bytes = ImmutableBytes.copyOf([4, 5, 6]);
      final byLabel = <String, ImmutableBytes>{'bytes': bytes};
      final uniqueValues = <ImmutableBytes>{bytes};

      byLabel['bytes']!.copy()[0] = 9;
      uniqueValues.single.copy()[2] = 9;

      expect(bytes.copy(), [4, 5, 6]);
    });

    test('slices exact bytes without exposing retained storage', () {
      final bytes = ImmutableBytes.copyOf([1, 2, 3, 4]);
      final slice = bytes.slice(ByteSpan(1, 3));
      final sliceCopy = slice.copy();
      sliceCopy[0] = 9;

      expect(slice.length, 2);
      expect(slice.copy(), [2, 3]);
      expect(bytes.copy(), [1, 2, 3, 4]);
    });

    test('rejects invalid spans eagerly and rejects out-of-bounds slices', () {
      expect(() => ByteSpan(-1, 0), throwsRangeError);
      expect(() => ByteSpan(2, 1), throwsRangeError);

      final bytes = ImmutableBytes.copyOf([1, 2, 3]);
      expect(() => bytes.slice(ByteSpan(0, 4)), throwsRangeError);
      expect(() => bytes.slice(ByteSpan(4, 4)), throwsRangeError);
    });

    test('hashes the exact retained bytes with SHA-256', () {
      final bytes = ImmutableBytes.copyOf([0, 1, 2, 3]);

      expect(
        bytes.sha256Hex,
        '054edec1d0211f624fed0cbca9d4f9400b0e491c43742af2c5b0abebf0c990d8',
      );
    });

    test('compares equal content and gives equal content equal hashes', () {
      final first = ImmutableBytes.copyOf([10, 20, 30]);
      final second = ImmutableBytes.copyOf([10, 20, 30]);
      final different = ImmutableBytes.copyOf([10, 20, 31]);

      expect(first.contentEquals(second), isTrue);
      expect(first.contentEquals(different), isFalse);
      expect(first.sha256Hex, second.sha256Hex);
    });
  });

  group('L10nEvidenceFailure', () {
    test('uses exhaustive declaration-ordered stable rejection codes', () {
      expect(L10nEvidenceRejectionCode.values.map((code) => code.name), [
        'scanBlockerPresent',
        'invalidSelection',
        'unsupportedConfiguration',
        'invalidInputPath',
        'arbFamilyIncomplete',
        'arbParseFailure',
        'materializationFailed',
        'sourceDrift',
        'packageResolutionDrift',
        'toolchainUnavailable',
        'toolchainDrift',
        'editPostconditionFailed',
        'baselineGenerationFailed',
        'staleGeneratedOutput',
        'candidateGenerationFailed',
        'generatorOutputTruncated',
        'generatorTerminationUnconfirmed',
        'unexpectedStageWrite',
        'outputFamilyAmbiguous',
        'candidateVerificationFailed',
        'cleanupFailed',
        'internalFailure',
      ]);
    });

    test(
      'sorts failures by stable code, stage, path, and detail identities',
      () {
        final failures = [
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'preflight',
            detailCode: 'selection-empty',
          ),
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.scanBlockerPresent,
            stage: 'verify',
            detailCode: 'blocker-present',
          ),
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'apply',
            detailCode: 'selection-empty',
          ),
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'preflight',
            detailCode: 'path-missing',
            relativePath: 'lib/l10n/app_en.arb',
          ),
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'preflight',
            detailCode: 'selection-empty',
            relativePath: 'lib/l10n/app_en.arb',
          ),
        ]..sort(_compareFailures);

        expect(failures.map((failure) => failure.detailCode), [
          'blocker-present',
          'selection-empty',
          'selection-empty',
          'path-missing',
          'selection-empty',
        ]);
        expect(failures.map((failure) => failure.relativePath), [
          isNull,
          isNull,
          isNull,
          'lib/l10n/app_en.arb',
          'lib/l10n/app_en.arb',
        ]);
      },
    );
  });
}

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  final code = left.code.index.compareTo(right.code.index);
  if (code != 0) return code;

  final stage = left.stage.compareTo(right.stage);
  if (stage != 0) return stage;

  final relativePath = (left.relativePath ?? '').compareTo(
    right.relativePath ?? '',
  );
  if (relativePath != 0) return relativePath;

  return left.detailCode.compareTo(right.detailCode);
}
