/// Current-process state for one reviewed quarantine clean target.
enum QuarantineCleanTargetState {
  /// The deletion future returned and the target is confirmed absent.
  removed,

  /// The run left active inventory and its physical bytes remain recoverable.
  retained,

  /// Validation failed before the deletion boundary.
  preserved,

  /// A previous target stopped the batch before this target was attempted.
  notAttempted,

  /// Deletion threw after its boundary, so descendants may already be gone.
  outcomeUnknown,

  /// A logical move crossed its boundary without terminal durable evidence.
  recoveryRequired,
}

/// One ordered target outcome in a non-durable current-process receipt.
final class QuarantineCleanTargetOutcome {
  /// Creates one typed target outcome.
  const QuarantineCleanTargetOutcome({
    required this.runId,
    required this.canonicalPath,
    required this.state,
    this.retainedPath,
    this.operationId,
    this.physicalBytesRetained = false,
    this.failureCode,
    this.failureMessage,
  });

  /// Validated run identifier.
  final String runId;

  /// Canonical absolute path reviewed immediately before execution.
  final String canonicalPath;

  /// Current-process outcome at the deletion boundary.
  final QuarantineCleanTargetState state;

  /// Canonical retained recovery path after a logical clean move.
  final String? retainedPath;

  /// Durable operation containing this retained target.
  final String? operationId;

  /// Whether the target's physical bytes remain stored after clean.
  final bool physicalBytesRetained;

  /// Stable failure category, when this target stopped the batch.
  final String? failureCode;

  /// Sanitized failure explanation, when available.
  final String? failureMessage;
}

/// Ordered current-process receipt for one clean execution attempt.
///
/// This object is not crash-durable recovery evidence and cannot establish
/// what happened after this process stopped.
final class QuarantineCleanResult {
  /// Creates an immutable receipt projection.
  QuarantineCleanResult({
    required this.fingerprint,
    bool? deletionAttempted,
    bool? mutationAttempted,
    this.operationId,
    required List<QuarantineCleanTargetOutcome> outcomes,
    this.failureCode,
    this.failureMessage,
  }) : mutationAttempted = _resolveMutationAttempted(
         deletionAttempted,
         mutationAttempted,
       ),
       outcomes = List<QuarantineCleanTargetOutcome>.unmodifiable(outcomes) {
    final crossedBoundary = this.outcomes.any(
      (outcome) =>
          outcome.state == QuarantineCleanTargetState.removed ||
          outcome.state == QuarantineCleanTargetState.retained ||
          outcome.state == QuarantineCleanTargetState.outcomeUnknown ||
          outcome.state == QuarantineCleanTargetState.recoveryRequired,
    );
    if (this.mutationAttempted != crossedBoundary) {
      throw ArgumentError(
        'mutationAttempted must match mutation-boundary evidence.',
      );
    }
    for (final outcome in this.outcomes) {
      if (outcome.state == QuarantineCleanTargetState.retained &&
          ((operationId == null && outcome.operationId == null) ||
              outcome.retainedPath == null ||
              !outcome.physicalBytesRetained)) {
        throw ArgumentError(
          'Retained outcomes require operation, path, and retained bytes.',
        );
      }
    }
  }

  /// Fingerprint of the reviewed initial plan.
  final String fingerprint;

  /// Whether any target crossed its deletion boundary in this process.
  final bool mutationAttempted;

  /// Backward-compatible alias for whether the old delete boundary was used.
  bool get deletionAttempted => mutationAttempted;

  /// Durable logical-clean transaction ID, when using retained semantics.
  final String? operationId;

  /// Ordered outcomes for every target in the reviewed initial plan.
  final List<QuarantineCleanTargetOutcome> outcomes;

  /// Stable batch-level failure category, when incomplete.
  final String? failureCode;

  /// Sanitized batch-level failure explanation, when incomplete.
  final String? failureMessage;
}

/// Address passed to an already authorized destructive backend.
///
/// This is deliberately not a clean plan or authority token. A caller must
/// rebuild and compare evidence through `QuarantineManager` before creating a
/// request. The interface itself grants no filesystem authority.
final class QuarantineCleanDeleteRequest {
  /// Creates a backend address after manager-owned revalidation.
  const QuarantineCleanDeleteRequest({
    required this.runId,
    required this.canonicalPath,
  });

  /// Revalidated run identifier.
  final String runId;

  /// Revalidated canonical target path.
  final String canonicalPath;
}

/// Backend-neutral deletion boundary consumed by the clean UX workflow.
///
/// No production implementation is registered while `CLEAN-TOCTOU-1` is
/// open. In particular, this interface must not be adapted to the current
/// pathname-based recursive-delete implementation.
abstract interface class QuarantineCleanExecutor {
  /// Crosses the deletion boundary for one manager-revalidated address.
  Future<void> delete(QuarantineCleanDeleteRequest request);
}

bool _resolveMutationAttempted(
  bool? deletionAttempted,
  bool? mutationAttempted,
) {
  if (deletionAttempted == null && mutationAttempted == null) {
    throw ArgumentError('One mutation-boundary observation must be provided.');
  }
  if (deletionAttempted != null &&
      mutationAttempted != null &&
      deletionAttempted != mutationAttempted) {
    throw ArgumentError('Mutation-boundary observations disagree.');
  }
  return mutationAttempted ?? deletionAttempted!;
}
