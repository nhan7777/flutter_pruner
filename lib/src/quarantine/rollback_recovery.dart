/// Failure categories emitted by the rollback recovery workflow.
enum RollbackFailureKind {
  /// The quarantine manifest could not be resolved or decoded.
  manifestReadFailure,

  /// Persisted baseline evidence cannot authorize V3 rollback verification.
  baselineEvidenceInvalid,

  /// The recorded project does not match the selected project.
  projectMismatch,

  /// Project bytes no longer match the journal-owned working copy.
  workingCopyConflict,

  /// Restoration failed before any project byte was observed to change.
  restoreFailedBeforeMutation,

  /// Restoration failed after project bytes may have changed.
  restoreFailedAfterMutation,

  /// The restored project did not reproduce its verification baseline.
  verificationFailed,

  /// The verifier threw before returning a complete result.
  verifierException,

  /// The verifier process tree may still be alive.
  verifierTerminationUnconfirmed,

  /// Retained run-original authority failed before journal publication.
  authoritySnapshotRevalidationFailed,

  /// Restored bytes, type, or permissions changed before journal publication.
  workingCopyRevalidationFailed,

  /// Manager-owned evidence rejected terminalization before journal writing.
  terminalizationPreconditionRejected,

  /// Original bytes verified, but the terminal journal revision failed.
  journalTerminalizationFailed,

  /// Clean validation failed before the logical-move boundary.
  cleanValidationFailed,

  /// Logical clean crossed its move boundary without terminal authority.
  cleanRecoveryRequired,

  /// Legacy recursive deletion outcome retained for old journal rendering.
  cleanOutcomeUnknown,
}

/// Typed classification produced at the restore boundary.
enum RollbackRestoreFailureKind {
  /// Journal-owned working-copy bytes no longer match.
  workingCopyConflict,

  /// Restore stopped before project bytes changed.
  failedBeforeMutation,

  /// Restore stopped after project bytes changed.
  failedAfterMutation,
}

/// Evidence about project bytes at the point rollback stopped.
enum RollbackWorkingCopyState {
  /// Rollback proved that it did not change project bytes.
  unchanged,

  /// Original project bytes were restored.
  originalBytesRestored,

  /// Project bytes may be partially restored or otherwise changed.
  outcomeUnknown,

  /// A restored state was observed to drift before journal terminalization.
  restoredStateInvalidated,

  /// Retained authority failed before the working copy could be revalidated.
  notRevalidatedAfterAuthorityFailure,
}

/// Evidence about the verifier phase.
enum RollbackVerificationState {
  /// No verifier was started.
  notStarted,

  /// Verification reproduced the recorded baseline.
  verified,

  /// Verification completed but did not reproduce the baseline.
  failed,

  /// The verifier failed before returning complete evidence.
  exception,

  /// Process-tree termination could not be confirmed.
  terminationUnconfirmed,

  /// A prior verifier result cannot authorize terminalization after drift.
  invalidatedByWorkingCopyRevalidation,

  /// Verification completed, but failed authority cannot authorize publication.
  completedButCannotAuthorizeTerminalizationDueToAuthorityEvidenceFailure,
}

/// Evidence retained in the run quarantine.
enum RollbackQuarantineState {
  /// Quarantine evidence remains unchanged and available.
  preserved,

  /// Quarantine remains available and is marked recovery-required.
  recoveryRequired,

  /// Quarantine remains recovery-required with corrupt run-original authority.
  authorityCorruptRecoveryRequired,

  /// Quarantine evidence was removed.
  removed,

  /// Quarantine left active inventory but remains retained for recovery.
  retained,

  /// Recursive deletion may have removed only part of the evidence.
  outcomeUnknown,
}

/// Evidence about the optional post-rollback clean phase.
enum RollbackCleanState {
  /// `--clean` was not requested.
  notRequested,

  /// `--clean` was requested but the delete boundary was not reached.
  notAttempted,

  /// Validation failed before deletion, so evidence remains preserved.
  validationFailedPreserved,

  /// Quarantine evidence was removed.
  removed,

  /// Logical clean committed retained recovery evidence.
  retained,

  /// Logical clean requires retained-journal recovery.
  recoveryRequired,

  /// Recursive deletion was invoked and its final outcome is unknown.
  outcomeUnknown,
}

/// Kind of follow-up allowed by a typed rollback outcome.
enum RollbackNextActionKind {
  /// Inspect the retained quarantine before deciding on another mutation.
  inspect,

  /// List surviving evidence, then inspect the retained run if present.
  listThenInspect,

  /// Independently confirm verifier termination, then inspect quarantine.
  confirmVerifierTerminationThenInspect,

  /// Remove the verified quarantine with the targeted clean command.
  targetedClean,
}

/// Purpose of one exact suggested command.
enum RollbackSuggestedCommandKind {
  /// List quarantine evidence that still exists.
  list,

  /// Inspect one retained quarantine run.
  inspect,

  /// Remove one verified quarantine run.
  clean,
}

/// Stable run and path identity captured before rollback mutation.
final class RollbackRunIdentity {
  /// Creates immutable rollback identity evidence.
  const RollbackRunIdentity({
    required this.runId,
    required this.projectPath,
    required this.quarantineBasePath,
    required this.quarantinePath,
    this.recordedProjectPath,
  });

  /// Validated quarantine run ID.
  final String runId;

  /// Selected and recorded project root.
  final String projectPath;

  /// Project root recorded by the manifest, when it could be decoded.
  final String? recordedProjectPath;

  /// Quarantine base containing [quarantinePath].
  final String quarantineBasePath;

  /// Exact run quarantine path.
  final String quarantinePath;
}

/// One exact command represented as raw argv rather than shell-interpolated text.
final class RollbackSuggestedCommand {
  /// Creates an immutable raw-argv command.
  RollbackSuggestedCommand({required this.kind, required List<String> argv})
    : argv = List<String>.unmodifiable(argv);

  /// Semantic purpose used only for surrounding explanatory copy.
  final RollbackSuggestedCommandKind kind;

  /// Exact raw process arguments, including the executable as element 0.
  final List<String> argv;
}

/// The only follow-up action allowed by a typed rollback outcome.
final class RollbackNextAction {
  RollbackNextAction._({
    required this.kind,
    required List<RollbackSuggestedCommand> commands,
  }) : commands = List<RollbackSuggestedCommand>.unmodifiable(commands);

  /// Inspects one retained run.
  factory RollbackNextAction.inspect(RollbackRunIdentity identity) =>
      RollbackNextAction._(
        kind: RollbackNextActionKind.inspect,
        commands: [_inspectCommand(identity)],
      );

  /// Lists surviving evidence, then inspects the selected run if present.
  factory RollbackNextAction.listThenInspect(RollbackRunIdentity identity) =>
      RollbackNextAction._(
        kind: RollbackNextActionKind.listThenInspect,
        commands: [_listCommand(identity), _inspectCommand(identity)],
      );

  /// Requires independent verifier termination confirmation before inspect.
  factory RollbackNextAction.confirmVerifierTerminationThenInspect(
    RollbackRunIdentity identity,
  ) => RollbackNextAction._(
    kind: RollbackNextActionKind.confirmVerifierTerminationThenInspect,
    commands: [_inspectCommand(identity)],
  );

  /// Removes one verified quarantine with the targeted legacy command.
  factory RollbackNextAction.targetedClean(RollbackRunIdentity identity) =>
      RollbackNextAction._(
        kind: RollbackNextActionKind.targetedClean,
        commands: [_cleanCommand(identity)],
      );

  /// Stable action category.
  final RollbackNextActionKind kind;

  /// Exact raw argv owned by the model, in required execution order.
  final List<RollbackSuggestedCommand> commands;

  static RollbackSuggestedCommand _listCommand(RollbackRunIdentity identity) =>
      RollbackSuggestedCommand(
        kind: RollbackSuggestedCommandKind.list,
        argv: [
          'flutter_pruner',
          'quarantine',
          'list',
          '--project',
          identity.projectPath,
          '--quarantine',
          identity.quarantineBasePath,
        ],
      );

  static RollbackSuggestedCommand _inspectCommand(
    RollbackRunIdentity identity,
  ) => RollbackSuggestedCommand(
    kind: RollbackSuggestedCommandKind.inspect,
    argv: [
      'flutter_pruner',
      'quarantine',
      'inspect',
      '--project',
      identity.projectPath,
      '--quarantine',
      identity.quarantineBasePath,
      identity.runId,
    ],
  );

  static RollbackSuggestedCommand _cleanCommand(RollbackRunIdentity identity) =>
      RollbackSuggestedCommand(
        kind: RollbackSuggestedCommandKind.clean,
        argv: [
          'flutter_pruner',
          'quarantine',
          'clean',
          '--project',
          identity.projectPath,
          '--quarantine',
          identity.quarantineBasePath,
          identity.runId,
        ],
      );
}

/// Role of the path that failed run-original revalidation.
enum RollbackObservedPathRole {
  /// Immutable run-original evidence retained in quarantine.
  runOriginalSnapshot,

  /// Canonical project working-copy path.
  workingCopy,
}

/// Typed filesystem observation that prevented rollback terminalization.
enum RollbackObservedState {
  /// The required path was absent.
  missing,

  /// The path existed but was not a regular file.
  nonRegularFile,

  /// Regular-file bytes did not match the run-original digest.
  byteMismatch,

  /// Bytes matched, but POSIX permission evidence did not.
  posixModeMismatch,
}

/// Exact observed evidence captured before any terminal journal write.
final class RollbackWorkingCopyObservation {
  /// Creates immutable revalidation evidence.
  const RollbackWorkingCopyObservation({
    required this.role,
    required this.path,
    required this.state,
    required this.expectedSha256,
    required this.observedSha256,
    required this.expectedPosixMode,
    required this.observedPosixMode,
    required this.observedType,
  });

  /// Whether [path] is the project target or retained snapshot.
  final RollbackObservedPathRole role;

  /// Exact raw path, sanitized only by the renderer.
  final String path;

  /// Stable mismatch category.
  final RollbackObservedState state;

  /// Run-original digest expected by the journal.
  final String expectedSha256;

  /// Digest observed for a regular file, when available.
  final String? observedSha256;

  /// Run-original POSIX mode expected by the journal.
  final int? expectedPosixMode;

  /// POSIX mode observed for a regular file, when available.
  final int? observedPosixMode;

  /// Stable filesystem type name observed without following links.
  final String observedType;
}

/// Manager-owned terminalization boundary category.
enum RollbackTerminalizationFailureKind {
  /// Retained run-original snapshot bytes, type, or mode failed revalidation.
  authoritySnapshotRevalidationFailed,

  /// Canonical project working-copy bytes, type, or mode failed revalidation.
  workingCopyRevalidationFailed,

  /// Verification or recovery-artifact evidence rejected terminalization.
  preconditionRejected,

  /// The terminal journal publication itself failed.
  journalPersistenceFailed,
}

/// Typed manager failure that distinguishes revalidation from journal writes.
final class RollbackTerminalizationException implements Exception {
  /// Creates a terminalization failure with optional observed filesystem state.
  const RollbackTerminalizationException({
    required this.kind,
    required this.detail,
    this.observation,
  });

  /// Stable terminalization boundary category.
  final RollbackTerminalizationFailureKind kind;

  /// Exact pre-write observation for a revalidation failure.
  final RollbackWorkingCopyObservation? observation;

  /// Diagnostic detail captured without renderer inference.
  final String detail;

  @override
  String toString() => detail;
}

/// Typed restore failure with byte evidence captured at the restore boundary.
final class RollbackRestorePhaseException implements Exception {
  /// Creates typed restore evidence.
  const RollbackRestorePhaseException({
    required this.kind,
    required this.workingCopy,
    required this.detail,
  });

  /// Stable restore failure category.
  final RollbackRestoreFailureKind kind;

  /// Working-copy evidence captured without renderer inference.
  final RollbackWorkingCopyState workingCopy;

  /// Diagnostic detail captured at the failure boundary.
  final String detail;

  @override
  String toString() => detail;
}

/// Typed rollback failure carrying all evidence needed by the CLI renderer.
final class RollbackRecoveryException implements Exception {
  /// Creates a complete rollback recovery failure.
  const RollbackRecoveryException({
    required this.kind,
    required this.identity,
    required this.workingCopy,
    required this.verification,
    required this.quarantine,
    required this.clean,
    required this.nextAction,
    required this.detail,
    this.observation,
  });

  /// Stable failure category.
  final RollbackFailureKind kind;

  /// Run and filesystem identities captured before the failure outcome.
  final RollbackRunIdentity identity;

  /// Working-copy byte evidence.
  final RollbackWorkingCopyState workingCopy;

  /// Verifier evidence.
  final RollbackVerificationState verification;

  /// Retained quarantine evidence.
  final RollbackQuarantineState quarantine;

  /// Optional clean-phase evidence.
  final RollbackCleanState clean;

  /// The only safe next action authorized by this outcome.
  final RollbackNextAction nextAction;

  /// Bounded diagnostic detail for support and tests.
  final String detail;

  /// Typed filesystem state for pre-journal revalidation failures.
  final RollbackWorkingCopyObservation? observation;

  /// Whether a clean mutation boundary was reached.
  bool get cleanAttempted =>
      clean == RollbackCleanState.outcomeUnknown ||
      clean == RollbackCleanState.recoveryRequired ||
      clean == RollbackCleanState.retained;

  @override
  String toString() => detail;
}
