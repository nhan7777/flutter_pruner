import 'dart:typed_data';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:test/test.dart';

void main() {
  group('L10nArbMutation', () {
    test('constructs with all fields', () {
      final original = ImmutableBytes.copyOf(Uint8List.fromList([1, 2, 3]));
      final candidate = ImmutableBytes.copyOf(Uint8List.fromList([4, 5, 6]));

      final mutation = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: original,
        originalHash: original.sha256Hex,
        candidateBytes: candidate,
        candidateHash: candidate.sha256Hex,
        mode: 420, // 0644
      );

      expect(mutation.relativePath, equals('lib/l10n/app_en.arb'));
      expect(mutation.originalBytes, equals(original));
      expect(mutation.candidateBytes, equals(candidate));
      expect(mutation.mode, equals(420));
    });

    test('equality works correctly', () {
      final bytes1 = ImmutableBytes.copyOf(Uint8List.fromList([1, 2, 3]));
      final bytes2 = ImmutableBytes.copyOf(Uint8List.fromList([4, 5, 6]));

      final mutation1 = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: bytes1,
        originalHash: bytes1.sha256Hex,
        candidateBytes: bytes2,
        candidateHash: bytes2.sha256Hex,
        mode: 420,
      );

      final mutation2 = L10nArbMutation(
        relativePath: 'lib/l10n/app_en.arb',
        originalBytes: bytes1,
        originalHash: bytes1.sha256Hex,
        candidateBytes: bytes2,
        candidateHash: bytes2.sha256Hex,
        mode: 420,
      );

      expect(mutation1, equals(mutation2));
      expect(mutation1.hashCode, equals(mutation2.hashCode));
    });
  });

  group('L10nGeneratedOutputMutation', () {
    test('constructs with existing file', () {
      final original = ImmutableBytes.copyOf(Uint8List.fromList([1, 2, 3]));
      final candidate = ImmutableBytes.copyOf(Uint8List.fromList([4, 5, 6]));

      final mutation = L10nGeneratedOutputMutation(
        relativePath: 'lib/generated/l10n.dart',
        originalBytes: original,
        originalHash: original.sha256Hex,
        candidateBytes: candidate,
        candidateHash: candidate.sha256Hex,
        mode: 420,
      );

      expect(mutation.relativePath, equals('lib/generated/l10n.dart'));
      expect(mutation.originalBytes, equals(original));
      expect(mutation.candidateBytes, equals(candidate));
      expect(mutation.wasAbsent, isFalse);
    });

    test('constructs with absent file', () {
      final candidate = ImmutableBytes.copyOf(Uint8List.fromList([4, 5, 6]));

      final mutation = L10nGeneratedOutputMutation(
        relativePath: 'lib/generated/l10n.dart',
        originalBytes: null,
        originalHash: null,
        candidateBytes: candidate,
        candidateHash: candidate.sha256Hex,
        mode: 420,
      );

      expect(mutation.wasAbsent, isTrue);
      expect(mutation.originalBytes, isNull);
      expect(mutation.originalHash, isNull);
    });
  });

  group('L10nRemovalBatch', () {
    test('constructs with valid parameters', () {
      final arbMutation = _createArbMutation('lib/l10n/app_en.arb');
      final outputMutation = _createOutputMutation('lib/generated/l10n.dart');

      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [arbMutation],
        generatedOutputMutations: [outputMutation],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(batch.familyId, equals('app_localizations'));
      expect(batch.selectedKeys, equals({'greeting'}));
      expect(batch.arbMutations, hasLength(1));
      expect(batch.generatedOutputMutations, hasLength(1));
    });

    test('validates successfully with correct parameters', () {
      final batch = _createValidBatch();
      expect(() => batch.validate(), returnsNormally);
    });

    test('rejects empty ARB mutations', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/generated/l10n.dart'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [],
        generatedOutputMutations: [_createOutputMutation('lib/generated/l10n.dart')],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('arbMutations cannot be empty'),
          ),
        ),
      );
    });

    test('rejects empty finding IDs', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {},
        arbMutations: [_createArbMutation('lib/l10n/app_en.arb')],
        generatedOutputMutations: [],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('findingIds cannot be empty'),
          ),
        ),
      );
    });

    test('rejects non-boundedFamily footprint', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedSingle,
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [_createArbMutation('lib/l10n/app_en.arb')],
        generatedOutputMutations: [],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('footprint must be boundedFamily'),
          ),
        ),
      );
    });

    test('rejects familyId mismatch', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'other_family',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [_createArbMutation('lib/l10n/app_en.arb')],
        generatedOutputMutations: [],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('footprint familyId mismatch'),
          ),
        ),
      );
    });

    test('rejects absolute ARB path', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'/absolute/path/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [_createArbMutation('/absolute/path/app_en.arb')],
        generatedOutputMutations: [],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('ARB path must be relative'),
          ),
        ),
      );
    });

    test('rejects duplicate paths', () {
      final footprint = MutationFootprint(
        findingIds: {'l10n:app_localizations/greeting'},
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting'},
        findingIds: {'l10n:app_localizations/greeting'},
        arbMutations: [
          _createArbMutation('lib/l10n/app_en.arb'),
          _createArbMutation('lib/l10n/app_en.arb'),
        ],
        generatedOutputMutations: [],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(
        () => batch.validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('Duplicate path'),
          ),
        ),
      );
    });

    test('multiple keys and files', () {
      final arbMutation1 = _createArbMutation('lib/l10n/app_en.arb');
      final arbMutation2 = _createArbMutation('lib/l10n/app_es.arb');
      final outputMutation = _createOutputMutation('lib/generated/l10n.dart');

      final footprint = MutationFootprint(
        findingIds: {
          'l10n:app_localizations/greeting',
          'l10n:app_localizations/farewell',
        },
        physicalPaths: {
          'lib/l10n/app_en.arb',
          'lib/l10n/app_es.arb',
          'lib/generated/l10n.dart',
        },
        riskScope: ActionRiskScope.boundedFamily,
        familyId: 'app_localizations',
      );

      final batch = L10nRemovalBatch(
        familyId: 'app_localizations',
        selectedKeys: {'greeting', 'farewell'},
        findingIds: {
          'l10n:app_localizations/greeting',
          'l10n:app_localizations/farewell',
        },
        arbMutations: [arbMutation1, arbMutation2],
        generatedOutputMutations: [outputMutation],
        configurationFingerprint: 'sha256:config',
        packageResolutionFingerprint: 'sha256:pubspec',
        toolchainFingerprint: 'flutter-3.44.1',
        footprint: footprint,
      );

      expect(() => batch.validate(), returnsNormally);
      expect(batch.selectedKeys, hasLength(2));
      expect(batch.arbMutations, hasLength(2));
      expect(batch.generatedOutputMutations, hasLength(1));
    });

    test('toString provides useful debugging info', () {
      final batch = _createValidBatch();
      final str = batch.toString();

      expect(str, contains('family: app_localizations'));
      expect(str, contains('keys: 1'));
      expect(str, contains('arbs: 1'));
      expect(str, contains('outputs: 1'));
    });
  });
}

// Test helpers

L10nArbMutation _createArbMutation(String path) {
  final original = ImmutableBytes.copyOf(Uint8List.fromList([1, 2, 3]));
  final candidate = ImmutableBytes.copyOf(Uint8List.fromList([4, 5, 6]));

  return L10nArbMutation(
    relativePath: path,
    originalBytes: original,
    originalHash: original.sha256Hex,
    candidateBytes: candidate,
    candidateHash: candidate.sha256Hex,
    mode: 420,
  );
}

L10nGeneratedOutputMutation _createOutputMutation(String path) {
  final original = ImmutableBytes.copyOf(Uint8List.fromList([7, 8, 9]));
  final candidate = ImmutableBytes.copyOf(Uint8List.fromList([10, 11, 12]));

  return L10nGeneratedOutputMutation(
    relativePath: path,
    originalBytes: original,
    originalHash: original.sha256Hex,
    candidateBytes: candidate,
    candidateHash: candidate.sha256Hex,
    mode: 420,
  );
}

L10nRemovalBatch _createValidBatch() {
  final arbMutation = _createArbMutation('lib/l10n/app_en.arb');
  final outputMutation = _createOutputMutation('lib/generated/l10n.dart');

  final footprint = MutationFootprint(
    findingIds: {'l10n:app_localizations/greeting'},
    physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
    riskScope: ActionRiskScope.boundedFamily,
    familyId: 'app_localizations',
  );

  return L10nRemovalBatch(
    familyId: 'app_localizations',
    selectedKeys: {'greeting'},
    findingIds: {'l10n:app_localizations/greeting'},
    arbMutations: [arbMutation],
    generatedOutputMutations: [outputMutation],
    configurationFingerprint: 'sha256:config',
    packageResolutionFingerprint: 'sha256:pubspec',
    toolchainFingerprint: 'flutter-3.44.1',
    footprint: footprint,
  );
}
