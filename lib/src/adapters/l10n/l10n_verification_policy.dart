import 'package:meta/meta.dart';

/// Policy for l10n mutation verification in Stage 2 Promotion.
///
/// Stage 2 enforces a no-resolution contract: l10n mutations do NOT resolve
/// findings. Instead, they contribute verified evidence that l10n keys are
/// safe to remove, and the actual finding resolution happens in a future stage
/// when the full removal workflow is complete.
@immutable
final class L10nVerificationPolicy {
  const L10nVerificationPolicy._();

  /// Singleton instance.
  static const instance = L10nVerificationPolicy._();

  /// Whether l10n mutations are allowed to resolve findings.
  ///
  /// Always returns `false` in Stage 2 Promotion. L10n mutations contribute
  /// verified evidence but do not resolve findings.
  bool get allowsFindingResolution => false;

  /// Whether l10n mutations require explicit verification before application.
  ///
  /// Always returns `true`. All l10n mutations must pass staging verification
  /// before they can be applied to the project.
  bool get requiresVerification => true;

  /// Whether l10n mutations support quarantine workflow.
  ///
  /// Returns `true`. L10n mutations follow the standard quarantine workflow:
  /// stage -> verify -> quarantine -> apply.
  bool get supportsQuarantine => true;

  /// Whether l10n mutations are atomic at the family level.
  ///
  /// Returns `true`. All ARB files and generated outputs for a family are
  /// applied atomically. Partial family mutations are not supported.
  bool get requiresFamilyAtomicity => true;

  /// Whether l10n mutations require deterministic inverse proof.
  ///
  /// Returns `true`. L10n evidence must prove that removing keys and
  /// regenerating outputs produces byte-exact inverse of the original state
  /// when keys are restored.
  bool get requiresDeterministicInverse => true;

  /// Validates that a finding can be addressed by l10n mutation.
  ///
  /// Checks:
  /// - Finding is from l10n adapter
  /// - Finding node is a localization key
  /// - Finding has no existing proposed action (Stage 1 contract)
  ///
  /// Returns validation error message if invalid, or null if valid.
  String? validateFindingEligibility({
    required String findingId,
    required String adapterId,
    required bool isLocalizationKey,
    required bool hasProposedAction,
  }) {
    if (adapterId != 'l10n') {
      return 'L10n mutations only apply to l10n adapter findings';
    }

    if (!isLocalizationKey) {
      return 'L10n mutations only apply to localization key nodes';
    }

    if (hasProposedAction) {
      return 'Finding already has proposed action (Stage 1 contract violation)';
    }

    return null;
  }

  /// Validates that a batch can be applied under this policy.
  ///
  /// Checks:
  /// - Batch has non-empty ARB mutations
  /// - Batch has non-empty finding IDs
  /// - Batch footprint is boundedFamily
  /// - All paths are relative
  ///
  /// Returns validation error message if invalid, or null if valid.
  String? validateBatch({
    required int arbMutationCount,
    required int findingCount,
    required bool isBoundedFamily,
    required bool hasOnlyRelativePaths,
  }) {
    if (arbMutationCount == 0) {
      return 'Batch must contain at least one ARB mutation';
    }

    if (findingCount == 0) {
      return 'Batch must address at least one finding';
    }

    if (!isBoundedFamily) {
      return 'L10n batches must be boundedFamily scope';
    }

    if (!hasOnlyRelativePaths) {
      return 'All batch paths must be relative to project root';
    }

    return null;
  }

  @override
  String toString() => 'L10nVerificationPolicy('
      'allowsResolution: $allowsFindingResolution, '
      'requiresVerification: $requiresVerification, '
      'requiresAtomicity: $requiresFamilyAtomicity'
      ')';
}
