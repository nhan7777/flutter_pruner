import 'recoverable_clean_transaction.dart';

/// Read-only classification of one retained clean operation.
enum RecoverableCleanInspectionState {
  /// Intent exists and every target is still active.
  active,

  /// Every target is committed below retained storage.
  retained,

  /// Exact state cannot be proven safe automatically.
  recoveryRequired,

  /// Every target was restored to active inventory.
  restored,

  /// Durable intent was terminalized before any selected move occurred.
  aborted,

  /// Some targets are active and the others remain retained.
  partiallyRestored,
}

/// One operation discovered below a quarantine base's retained store.
final class RecoverableCleanInspection {
  /// Creates an immutable inspection result.
  const RecoverableCleanInspection({
    required this.operationId,
    required this.quarantineBasePath,
    required this.state,
    required this.observationCode,
    this.transaction,
  });

  /// Retained operation directory identifier.
  final String operationId;

  /// Canonical quarantine base containing this operation.
  final String quarantineBasePath;

  /// Conservative aggregate classification.
  final RecoverableCleanInspectionState state;

  /// Stable, sanitized explanation token.
  final String observationCode;

  /// Parsed latest durable authority, when unambiguous and valid.
  final RecoverableCleanTransaction? transaction;
}
