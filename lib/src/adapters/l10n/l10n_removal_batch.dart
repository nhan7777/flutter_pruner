import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import 'action_readiness/immutable_bytes.dart';
import 'l10n_mutation_selection.dart';

/// Represents a mutation to one ARB file in an l10n removal transaction.
@immutable
final class L10nArbMutation {
  /// Creates an ARB mutation with its original and candidate bytes.
  const L10nArbMutation({
    required this.relativePath,
    required this.originalBytes,
    required this.originalHash,
    required this.candidateBytes,
    required this.candidateHash,
    required this.mode,
  });

  /// ARB path relative to the project root.
  final String relativePath;

  /// Original file bytes captured before mutation.
  final ImmutableBytes originalBytes;

  /// SHA-256 hash of [originalBytes].
  final String originalHash;

  /// Candidate file bytes after removing the selected keys.
  final ImmutableBytes candidateBytes;

  /// SHA-256 hash of [candidateBytes].
  final String candidateHash;

  /// Original file mode bits.
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
  /// Creates a mutation for one generated output file.
  const L10nGeneratedOutputMutation({
    required this.relativePath,
    this.originalBytes,
    this.originalHash,
    required this.candidateBytes,
    required this.candidateHash,
    required this.mode,
  });

  /// Generated output path relative to the project root.
  final String relativePath;

  /// Original bytes, or null when the output did not exist.
  final ImmutableBytes? originalBytes;

  /// SHA-256 hash of [originalBytes], or null when the output did not exist.
  final String? originalHash;

  /// Candidate generated output bytes.
  final ImmutableBytes candidateBytes;

  /// SHA-256 hash of [candidateBytes].
  final String candidateHash;

  /// Original file mode bits.
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
  /// Creates one family-level atomic l10n removal batch.
  const L10nRemovalBatch({
    required this.familyId,
    required this.selection,
    required this.arbMutations,
    required this.generatedOutputMutations,
    required this.configurationFingerprint,
    required this.packageResolutionFingerprint,
    required this.toolchainFingerprint,
    required this.footprint,
  });

  /// Identifier of the family mutated atomically.
  final String familyId;

  /// Selection metadata: requested vs effective findings.
  final L10nMutationSelection selection;

  /// Localization keys selected for removal.
  ///
  /// Derived from `selection.effectiveKeys`.
  Set<String> get selectedKeys => selection.effectiveKeys;

  /// Finding IDs represented by this batch.
  ///
  /// Derived from `selection.effectiveFindingIds`.
  Set<String> get findingIds => selection.effectiveFindingIds;

  /// ARB file mutations in this batch.
  final List<L10nArbMutation> arbMutations;

  /// Generated output mutations in this batch.
  final List<L10nGeneratedOutputMutation> generatedOutputMutations;

  /// Fingerprint of the l10n configuration used to build the batch.
  final String configurationFingerprint;

  /// Fingerprint of resolved package inputs used to build the batch.
  final String packageResolutionFingerprint;

  /// Fingerprint of the toolchain used to build the batch.
  final String toolchainFingerprint;

  /// Complete logical and physical scope of this batch.
  final MutationFootprint footprint;

  /// Validates that this batch is safe to execute as a bounded mutation.
  void validate() {
    // Validate selection first
    selection.validate();

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
        'Footprint familyId must match batch familyId: ${footprint.familyId} != $familyId',
      );
    }

    // Validate no duplicate paths
    final allPaths = <String>{};
    for (final arb in arbMutations) {
      if (!allPaths.add(arb.relativePath)) {
        throw ArgumentError(
          'Duplicate path in ARB mutations: ${arb.relativePath}',
        );
      }
      if (arb.relativePath.startsWith('/')) {
        throw ArgumentError(
          'Path must be relative to project root: ${arb.relativePath}',
        );
      }
    }
    for (final gen in generatedOutputMutations) {
      if (!allPaths.add(gen.relativePath)) {
        throw ArgumentError(
          'Duplicate path across mutations: ${gen.relativePath}',
        );
      }
      if (gen.relativePath.startsWith('/')) {
        throw ArgumentError(
          'Path must be relative to project root: ${gen.relativePath}',
        );
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
          _listEquals(
            generatedOutputMutations,
            other.generatedOutputMutations,
          ) &&
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
