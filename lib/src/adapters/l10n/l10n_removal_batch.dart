import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import 'action_readiness/immutable_bytes.dart';

/// Represents a mutation to one ARB file in an l10n removal transaction.
@immutable
final class L10nArbMutation {
  const L10nArbMutation({
    required this.relativePath,
    required this.originalBytes,
    required this.originalHash,
    required this.candidateBytes,
    required this.candidateHash,
    required this.mode,
  });

  final String relativePath;
  final ImmutableBytes originalBytes;
  final String originalHash;
  final ImmutableBytes candidateBytes;
  final String candidateHash;
  final int mode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nArbMutation &&
          runtimeType == other.runtimeType &&
          relativePath == other.relativePath &&
          originalBytes == other.originalBytes &&
          originalHash == other.originalHash &&
          candidateBytes == other.candidateBytes &&
          candidateHash == other.candidateHash &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(
        relativePath,
        originalBytes,
        originalHash,
        candidateBytes,
        candidateHash,
        mode,
      );
}

/// Represents a mutation to one generated Dart file in an l10n removal transaction.
@immutable
final class L10nGeneratedOutputMutation {
  const L10nGeneratedOutputMutation({
    required this.relativePath,
    this.originalBytes,
    this.originalHash,
    required this.candidateBytes,
    required this.candidateHash,
    required this.mode,
  });

  final String relativePath;
  final ImmutableBytes? originalBytes;
  final String? originalHash;
  final ImmutableBytes candidateBytes;
  final String candidateHash;
  final int mode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nGeneratedOutputMutation &&
          runtimeType == other.runtimeType &&
          relativePath == other.relativePath &&
          originalBytes == other.originalBytes &&
          originalHash == other.originalHash &&
          candidateBytes == other.candidateBytes &&
          candidateHash == other.candidateHash &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(
        relativePath,
        originalBytes,
        originalHash,
        candidateBytes,
        candidateHash,
        mode,
      );
}

/// Represents one family-level atomic l10n removal transaction.
@immutable
final class L10nRemovalBatch {
  const L10nRemovalBatch({
    required this.familyId,
    required this.selectedKeys,
    required this.findingIds,
    required this.arbMutations,
    required this.generatedOutputMutations,
    required this.configurationFingerprint,
    required this.packageResolutionFingerprint,
    required this.toolchainFingerprint,
    required this.footprint,
  });

  final String familyId;
  final Set<String> selectedKeys;
  final Set<String> findingIds;

  final List<L10nArbMutation> arbMutations;
  final List<L10nGeneratedOutputMutation> generatedOutputMutations;

  final String configurationFingerprint;
  final String packageResolutionFingerprint;
  final String toolchainFingerprint;

  final MutationFootprint footprint;

  void validate() {
    if (arbMutations.isEmpty) {
      throw ArgumentError('At least one ARB mutation is required');
    }
    if (findingIds.isEmpty) {
      throw ArgumentError('At least one finding ID is required');
    }
    if (footprint.riskScope != ActionRiskScope.boundedFamily) {
      throw ArgumentError('Footprint must have boundedFamily risk scope');
    }
    if (footprint.familyId != familyId) {
      throw ArgumentError(
          'Footprint familyId must match batch familyId: ${footprint.familyId} != $familyId');
    }

    // Validate no duplicate paths
    final allPaths = <String>{};
    for (final arb in arbMutations) {
      if (!allPaths.add(arb.relativePath)) {
        throw ArgumentError('Duplicate path in ARB mutations: ${arb.relativePath}');
      }
      if (arb.relativePath.startsWith('/')) {
        throw ArgumentError('Path must be relative to project root: ${arb.relativePath}');
      }
    }
    for (final gen in generatedOutputMutations) {
      if (!allPaths.add(gen.relativePath)) {
        throw ArgumentError('Duplicate path across mutations: ${gen.relativePath}');
      }
      if (gen.relativePath.startsWith('/')) {
        throw ArgumentError('Path must be relative to project root: ${gen.relativePath}');
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nRemovalBatch &&
          runtimeType == other.runtimeType &&
          familyId == other.familyId &&
          _setEquals(selectedKeys, other.selectedKeys) &&
          _setEquals(findingIds, other.findingIds) &&
          _listEquals(arbMutations, other.arbMutations) &&
          _listEquals(generatedOutputMutations, other.generatedOutputMutations) &&
          configurationFingerprint == other.configurationFingerprint &&
          packageResolutionFingerprint == other.packageResolutionFingerprint &&
          toolchainFingerprint == other.toolchainFingerprint &&
          footprint == other.footprint;

  @override
  int get hashCode => Object.hash(
        familyId,
        Object.hashAll(selectedKeys),
        Object.hashAll(findingIds),
        Object.hashAll(arbMutations),
        Object.hashAll(generatedOutputMutations),
        configurationFingerprint,
        packageResolutionFingerprint,
        toolchainFingerprint,
        footprint,
      );

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
