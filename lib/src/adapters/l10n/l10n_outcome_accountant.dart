import 'l10n_batch_verifier.dart';
import 'l10n_mutation_expectation.dart';
import 'l10n_mutation_selection.dart';

/// Tracks mutation outcomes per finding (not per file).
///
/// Maps verification results back to individual findings to determine
/// which findings were successfully applied vs which failed.
final class L10nOutcomeAccountant {
  /// Creates an outcome accountant.
  const L10nOutcomeAccountant();

  /// Computes per-finding outcomes from a verification result.
  ///
  /// All findings in [L10nMutationSelection.effectiveFindingIds] are tracked:
  /// - [FindingOutcome.applied] if verification succeeded
  /// - [FindingOutcome.failed] if verification failed with specific mismatches
  ///
  /// The expectation and verification family IDs must match the family ID
  /// argument.
  FindingAccountingResult account({
    required String familyId,
    required L10nMutationSelection selection,
    required L10nMutationExpectation expectation,
    required VerificationResult verificationResult,
  }) {
    if (expectation.familyId != familyId) {
      throw ArgumentError(
        'expectation.familyId (${expectation.familyId}) must match familyId ($familyId)',
      );
    }
    if (verificationResult.familyId != familyId) {
      throw ArgumentError(
        'verificationResult.familyId (${verificationResult.familyId}) must match familyId ($familyId)',
      );
    }

    final outcomes = <String, FindingOutcome>{};

    switch (verificationResult) {
      case VerificationSuccess():
        // All effective findings succeeded.
        for (final findingId in selection.effectiveFindingIds) {
          outcomes[findingId] = FindingOutcome.applied;
        }

      case VerificationFailed(:final mismatches):
        // All effective findings failed (atomic family mutation).
        for (final findingId in selection.effectiveFindingIds) {
          outcomes[findingId] = FindingOutcome.failed(
            reason: 'Verification failed: ${mismatches.length} mismatch(es)',
            verificationMismatches: mismatches,
          );
        }
    }

    return FindingAccountingResult(
      familyId: familyId,
      requestedFindingIds: selection.requestedFindingIds,
      effectiveFindingIds: selection.effectiveFindingIds,
      outcomes: outcomes,
    );
  }
}

/// Per-finding accounting result for a family mutation.
final class FindingAccountingResult {
  /// Creates an accounting result.
  const FindingAccountingResult({
    required this.familyId,
    required this.requestedFindingIds,
    required this.effectiveFindingIds,
    required this.outcomes,
  });

  /// Identifier of the family that was accounted.
  final String familyId;

  /// Finding IDs explicitly requested by the user.
  final Set<String> requestedFindingIds;

  /// All finding IDs included in the mutation.
  final Set<String> effectiveFindingIds;

  /// Outcome recorded for each effective finding ID.
  final Map<String, FindingOutcome> outcomes;

  /// Whether all effective findings succeeded.
  bool get allApplied =>
      outcomes.values.every((outcome) => outcome == FindingOutcome.applied);

  /// Whether at least one effective finding failed.
  bool get anyFailed =>
      outcomes.values.any((outcome) => outcome != FindingOutcome.applied);

  /// Count of applied findings.
  int get appliedCount => outcomes.values
      .where((outcome) => outcome == FindingOutcome.applied)
      .length;

  /// Count of failed findings.
  int get failedCount => outcomes.values
      .where((outcome) => outcome != FindingOutcome.applied)
      .length;
}

/// Outcome for a single finding.
sealed class FindingOutcome {
  /// Creates a finding outcome.
  const FindingOutcome();

  /// Finding was successfully applied and verified.
  static const applied = FindingOutcomeApplied._();

  /// Creates a failed finding outcome.
  factory FindingOutcome.failed({
    required String reason,
    List<VerificationMismatch> verificationMismatches = const [],
  }) => FindingOutcomeFailed(
    reason: reason,
    verificationMismatches: verificationMismatches,
  );
}

/// Successful finding outcome.
final class FindingOutcomeApplied extends FindingOutcome {
  const FindingOutcomeApplied._();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is FindingOutcomeApplied;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'FindingOutcome.applied';
}

/// Failed finding outcome.
final class FindingOutcomeFailed extends FindingOutcome {
  /// Creates a failed finding outcome.
  const FindingOutcomeFailed({
    required this.reason,
    this.verificationMismatches = const [],
  });

  /// Explanation for why the finding failed.
  final String reason;

  /// Verification mismatches associated with the failure.
  final List<VerificationMismatch> verificationMismatches;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FindingOutcomeFailed &&
          reason == other.reason &&
          verificationMismatches.length == other.verificationMismatches.length;

  @override
  int get hashCode => Object.hash(reason, verificationMismatches.length);

  @override
  String toString() =>
      'FindingOutcome.failed(reason: $reason, mismatches: ${verificationMismatches.length})';
}
