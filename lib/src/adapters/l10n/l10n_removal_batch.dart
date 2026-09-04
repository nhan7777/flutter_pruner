import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import 'action_readiness/immutable_bytes.dart';

/// One ARB file edit in a family-level removal batch.
///
/// Represents the byte-level mutation of a single ARB file (template or locale).
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

  /// Path relative to project root (e.g., 'lib/l10n/app_en.arb').
  final String relativePath;

  /// Original file bytes before mutation.
  final ImmutableBytes originalBytes;

  /// SHA-256 hash of original bytes.
  final String originalHash;

  /// Candidate file bytes after key removal.
  final ImmutableBytes candidateBytes;

  /// SHA-256 hash of candidate bytes.
  final String candidateHash;

  /// File mode (Unix permissions).
  final int mode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nArbMutation &&
          runtimeType == other.runtimeType &&
          relativePath == other.relativePath &&
          originalHash == other.originalHash &&
          candidateHash == other.candidateHash &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(
        relativePath,
        originalHash,
        candidateHash,
        mode,
      );

  @override
  String toString() => 'L10nArbMutation($relativePath)';
}

/// One generated Dart file mutation in a family-level removal batch.
///
/// Represents the output of `gen-l10n` after ARB edits are applied.
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

  /// Path relative to project root (e.g., 'lib/generated/l10n.dart').
  final String relativePath;

  /// Original file bytes, or null if file was absent before.
  ///
  /// Stage 2 Promotion supports only replacements (not creations/deletions),
  /// so this will always be non-null for the initial cohort.
  final ImmutableBytes? originalBytes;

  /// SHA-256 hash of original bytes, or null if absent.
  final String? originalHash;

  /// Candidate file bytes after regeneration.
  final ImmutableBytes candidateBytes;

  /// SHA-256 hash of candidate bytes.
  final String candidateHash;

  /// File mode (Unix permissions).
  final int mode;

  /// Whether this file was absent before the mutation.
  bool get wasAbsent => originalBytes == null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nGeneratedOutputMutation &&
          runtimeType == other.runtimeType &&
          relativePath == other.relativePath &&
          originalHash == other.originalHash &&
          candidateHash == other.candidateHash &&
          mode == other.mode;

  @override
  int get hashCode => Object.hash(
        relativePath,
        originalHash,
        candidateHash,
        mode,
      );

  @override
  String toString() => 'L10nGeneratedOutputMutation($relativePath)';
}

/// One family-level atomic l10n removal batch.
///
/// Represents all ARB edits and generated output mutations for a complete
/// configured ARB family. The batch is atomic: all mutations succeed or fail
/// together during quarantine transaction.
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

  /// Family identifier (e.g., 'app_localizations').
  final String familyId;

  /// Localization keys being removed in this batch.
  final Set<String> selectedKeys;

  /// Logical finding IDs addressed by this batch.
  ///
  /// These are the canonical node IDs from the reachability graph.
  final Set<String> findingIds;

  /// ARB file mutations (template + locales).
  final List<L10nArbMutation> arbMutations;

  /// Generated Dart file mutations.
  final List<L10nGeneratedOutputMutation> generatedOutputMutations;

  /// Configuration fingerprint (l10n.yaml hash).
  final String configurationFingerprint;

  /// Package resolution fingerprint (pubspec.lock hash).
  final String packageResolutionFingerprint;

  /// Toolchain fingerprint (Flutter SDK version + path).
  final String toolchainFingerprint;

  /// Mutation footprint for this family-level batch.
  final MutationFootprint footprint;

  /// Validates batch constraints.
  ///
  /// Throws [ArgumentError] if:
  /// - No ARB mutations
  /// - No finding IDs
  /// - Footprint is not boundedFamily with matching familyId
  /// - Paths are absolute instead of relative
  /// - Duplicate paths across ARB and generated mutations
  void validate() {
    if (arbMutations.isEmpty) {
      throw ArgumentError('arbMutations cannot be empty');
    }
    if (findingIds.isEmpty) {
      throw ArgumentError('findingIds cannot be empty');
    }
    if (footprint.riskScope != ActionRiskScope.boundedFamily) {
      throw ArgumentError(
        'footprint must be boundedFamily, got ${footprint.riskScope}',
      );
    }
    if (footprint.familyId != familyId) {
      throw ArgumentError(
        'footprint familyId mismatch: expected $familyId, '
        'got ${footprint.familyId}',
      );
    }

    // Check all paths are relative
    for (final mutation in arbMutations) {
      if (_isAbsolutePath(mutation.relativePath)) {
        throw ArgumentError(
          'ARB path must be relative: ${mutation.relativePath}',
        );
      }
    }
    for (final mutation in generatedOutputMutations) {
      if (_isAbsolutePath(mutation.relativePath)) {
        throw ArgumentError(
          'Generated output path must be relative: ${mutation.relativePath}',
        );
      }
    }

    // Check no duplicate paths
    final allPaths = <String>{};
    for (final mutation in arbMutations) {
      if (!allPaths.add(mutation.relativePath)) {
        throw ArgumentError('Duplicate path: ${mutation.relativePath}');
      }
    }
    for (final mutation in generatedOutputMutations) {
      if (!allPaths.add(mutation.relativePath)) {
        throw ArgumentError('Duplicate path: ${mutation.relativePath}');
      }
    }
  }

  static bool _isAbsolutePath(String path) {
    return path.startsWith('/') || path.contains(':\\');
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
        _setHashCode(selectedKeys),
        _setHashCode(findingIds),
        _listHashCode(arbMutations),
        _listHashCode(generatedOutputMutations),
        configurationFingerprint,
        packageResolutionFingerprint,
        toolchainFingerprint,
        footprint,
      );

  @override
  String toString() => 'L10nRemovalBatch('
      'family: $familyId, '
      'keys: ${selectedKeys.length}, '
      'arbs: ${arbMutations.length}, '
      'outputs: ${generatedOutputMutations.length}'
      ')';

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  static int _setHashCode<T>(Set<T> set) {
    return set.fold(0, (hash, element) => hash ^ element.hashCode);
  }

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static int _listHashCode<T>(List<T> list) {
    return list.fold(0, (hash, element) => hash ^ element.hashCode);
  }
}
