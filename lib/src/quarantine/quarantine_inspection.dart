import 'manifest.dart';
import 'manifest_authority.dart';

/// Read-only projection of one raw entry in a quarantine inventory.
sealed class QuarantineInspection {
  /// Creates an inventory entry.
  const QuarantineInspection({required this.path});

  /// Normalized absolute path of the raw entry.
  final String path;
}

/// Stable, sanitized inventory error codes.
abstract final class QuarantineInspectionErrorCodes {
  /// A quarantine base contains a child that is not a run directory.
  static const unexpectedEntry = 'unexpected_entry';

  /// A manifest candidate is missing, unreadable, corrupt, or invalid.
  static const invalidManifest = 'invalid_manifest';

  /// Candidate revisions or payloads do not establish one authority.
  static const ambiguousAuthority = 'ambiguous_authority';

  /// A manifest run ID differs from its containing directory name.
  static const runIdMismatch = 'run_id_mismatch';

  /// A manifest belongs to a different project root.
  static const foreignProject = 'foreign_project';

  /// The same validated run ID exists in more than one directory.
  static const duplicateRunId = 'duplicate_run_id';

  /// A raw base or child is a symbolic link.
  static const symlinkEntry = 'symlink_entry';

  /// A run directory name is not a valid run ID.
  static const invalidRunId = 'invalid_run_id';

  /// A quarantine base could not be enumerated safely.
  static const unreadableBase = 'unreadable_base';

  /// A child changed after enumeration and before inspection.
  static const entryChanged = 'entry_changed';
}

/// Counts transactions by their validated manifest status.
final class QuarantineTransactionSummary {
  /// Creates an immutable transaction summary from typed manifest evidence.
  factory QuarantineTransactionSummary.fromManifest(
    QuarantineManifest manifest,
  ) {
    var pending = 0;
    var applied = 0;
    var verified = 0;
    var committed = 0;
    var rolledBackVerified = 0;
    var recoveryRequired = 0;
    for (final transaction in manifest.transactions) {
      switch (transaction.status) {
        case QuarantineTransactionStatus.pending:
          pending++;
        case QuarantineTransactionStatus.applied:
          applied++;
        case QuarantineTransactionStatus.verified:
          verified++;
        case QuarantineTransactionStatus.committed:
          committed++;
        case QuarantineTransactionStatus.rolledBackVerified:
          rolledBackVerified++;
        case QuarantineTransactionStatus.recoveryRequired:
          recoveryRequired++;
      }
    }
    return QuarantineTransactionSummary._(
      total: manifest.transactions.length,
      pending: pending,
      applied: applied,
      verified: verified,
      committed: committed,
      rolledBackVerified: rolledBackVerified,
      recoveryRequired: recoveryRequired,
    );
  }

  const QuarantineTransactionSummary._({
    required this.total,
    required this.pending,
    required this.applied,
    required this.verified,
    required this.committed,
    required this.rolledBackVerified,
    required this.recoveryRequired,
  });

  /// Total validated transactions.
  final int total;

  /// Transactions declared but not yet applied.
  final int pending;

  /// Transactions whose cases were applied.
  final int applied;

  /// Transactions with transaction-local verification evidence.
  final int verified;

  /// Transactions accepted by the run.
  final int committed;

  /// Transactions restored and verified against their original bytes.
  final int rolledBackVerified;

  /// Transactions explicitly requiring recovery.
  final int recoveryRequired;
}

/// A validated quarantine run and its read-only safety projection.
final class ValidQuarantineInspection extends QuarantineInspection {
  /// Creates a valid inventory entry from typed manifest authority.
  const ValidQuarantineInspection({
    required super.path,
    required this.runId,
    required this.timestamp,
    required this.entryCount,
    required this.authority,
    required this.cleanable,
    required this.recoveryRequired,
    required this.transactions,
  });

  /// Validated run ID matching the containing directory.
  final String runId;

  /// Manifest creation timestamp.
  final DateTime timestamp;

  /// Number of V1 entries or V2/V3 cases.
  final int entryCount;

  /// Immutable validated journal authority.
  final ManifestAuthorityDecision authority;

  /// Whether all manifest and filesystem evidence permits cleanup.
  final bool cleanable;

  /// Whether typed state or recovery artifacts require recovery.
  final bool recoveryRequired;

  /// Transaction counts derived only from the typed manifest.
  final QuarantineTransactionSummary transactions;

  /// Validated lifecycle marker, when the manifest version has one.
  QuarantineRunLifecycleState? get lifecycle => authority.lifecycle;

  /// Whether this valid run belongs in the leading attention group.
  bool get requiresAttention =>
      !cleanable || authority.repairAction != ManifestRepairAction.none;
}

/// A raw quarantine entry that could not be validated as a run.
final class InvalidQuarantineInspection extends QuarantineInspection {
  /// Creates an invalid inventory entry.
  const InvalidQuarantineInspection({
    required super.path,
    required this.errorCode,
    required this.message,
    this.blocksApply = true,
  });

  /// Stable machine-readable reason.
  final String errorCode;

  /// Sanitized user-facing explanation without raw exception details.
  final String message;

  /// Whether this raw entry prevents another apply from starting.
  final bool blocksApply;
}

/// Whether typed transaction state prevents evidence cleanup.
bool quarantineTransactionBlocksClean(
  QuarantineTransaction transaction, {
  required bool fullRollbackVerified,
}) => switch (transaction.status) {
  QuarantineTransactionStatus.rolledBackVerified => false,
  QuarantineTransactionStatus.committed => !fullRollbackVerified,
  QuarantineTransactionStatus.pending ||
  QuarantineTransactionStatus.applied ||
  QuarantineTransactionStatus.verified ||
  QuarantineTransactionStatus.recoveryRequired => true,
};

/// Whether typed case state prevents evidence cleanup.
bool quarantineCaseBlocksClean(
  QuarantineCase applyCase, {
  required bool fullRollbackVerified,
}) => switch (applyCase.status) {
  QuarantineCaseStatus.rolledBack || QuarantineCaseStatus.failed => false,
  QuarantineCaseStatus.kept => !fullRollbackVerified,
  QuarantineCaseStatus.backedUp || QuarantineCaseStatus.applied => true,
};

/// Pure typed-state cleanability predicate shared by inventory and planning.
///
/// A `true` result still requires filesystem recovery-artifact, legacy-backup,
/// and displacement validation before cleanup is permitted.
bool isQuarantineManifestStateCleanable({
  required QuarantineManifest manifest,
  required QuarantineRunLifecycleState? lifecycle,
}) {
  if (lifecycle == QuarantineRunLifecycleState.active ||
      lifecycle == QuarantineRunLifecycleState.recoveryRequired) {
    return false;
  }
  return !manifest.transactions.any(
        (transaction) => quarantineTransactionBlocksClean(
          transaction,
          fullRollbackVerified: manifest.fullRollbackVerified,
        ),
      ) &&
      !manifest.cases.any(
        (applyCase) => quarantineCaseBlocksClean(
          applyCase,
          fullRollbackVerified: manifest.fullRollbackVerified,
        ),
      );
}

/// Whether typed validated manifest state explicitly requires recovery.
bool quarantineManifestRequiresRecovery({
  required QuarantineManifest manifest,
  required QuarantineRunLifecycleState? lifecycle,
}) =>
    lifecycle == QuarantineRunLifecycleState.recoveryRequired ||
    manifest.transactions.any(
      (transaction) =>
          transaction.status == QuarantineTransactionStatus.recoveryRequired,
    );
