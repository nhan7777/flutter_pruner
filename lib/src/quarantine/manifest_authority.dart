import 'manifest.dart';

/// Files that can participate in manifest journal authority.
enum ManifestCandidateName {
  /// The normal `manifest.json` path.
  primary,

  /// The flushed `manifest.json.tmp` replacement candidate.
  temporary,

  /// The `manifest.json.previous` recovery candidate.
  previous,
}

/// Filesystem repair required to make the selected manifest authoritative.
enum ManifestRepairAction {
  /// The selected candidate is already authoritative.
  none,

  /// Remove a fully written replacement that was never committed.
  discardUncommittedTemporary,

  /// Promote the flushed temporary candidate to `manifest.json`.
  promoteTemporary,

  /// Recreate `manifest.json` from the previous recovery candidate.
  restorePrevious,
}

/// Run-level lifecycle persisted alongside the transaction journal.
enum QuarantineRunLifecycleState {
  /// The command may still add transactions or perform convergence checks.
  active,

  /// Every transaction committed and all run-level obligations completed.
  completed,

  /// A process or recovery failure left project bytes unsafe to touch.
  recoveryRequired,

  /// The whole run was restored and verified against its original baseline.
  rolledBackVerified,
}

/// Read-only projection of the authoritative manifest candidate.
final class ManifestAuthorityDecision {
  /// Creates an immutable authority projection.
  factory ManifestAuthorityDecision({
    required QuarantineManifest manifest,
    required int revision,
    required String payloadSha256,
    required QuarantineRunLifecycleState? lifecycle,
    required ManifestCandidateName authority,
    required ManifestRepairAction repairAction,
    required Map<String, Object?> canonicalDocument,
  }) => ManifestAuthorityDecision._(
    manifest: _immutableManifest(manifest),
    revision: revision,
    payloadSha256: payloadSha256,
    lifecycle: lifecycle,
    authority: authority,
    repairAction: repairAction,
    canonicalDocument: _immutableJsonMap(canonicalDocument),
  );

  const ManifestAuthorityDecision._({
    required this.manifest,
    required this.revision,
    required this.payloadSha256,
    required this.lifecycle,
    required this.authority,
    required this.repairAction,
    required this.canonicalDocument,
  });

  /// Parsed quarantine manifest.
  final QuarantineManifest manifest;

  /// Journal revision, or zero for a legacy unjournaled manifest.
  final int revision;

  /// SHA-256 of the canonical payload without `_journal`.
  final String payloadSha256;

  /// Validated run lifecycle when present.
  final QuarantineRunLifecycleState? lifecycle;

  /// Candidate that carries the authoritative document.
  final ManifestCandidateName authority;

  /// Repair a mutating resolver must perform under its operation lock.
  final ManifestRepairAction repairAction;

  /// Deeply immutable validated JSON document, including `_journal`.
  final Map<String, Object?> canonicalDocument;
}

QuarantineManifest _immutableManifest(QuarantineManifest source) =>
    QuarantineManifest(
      runId: source.runId,
      timestamp: source.timestamp,
      projectRoot: source.projectRoot,
      entries: List<QuarantineEntry>.unmodifiable(
        source.entries.map(_immutableEntry),
      ),
      cases: List<QuarantineCase>.unmodifiable(
        source.cases.map(_immutableCase),
      ),
      transactions: List<QuarantineTransaction>.unmodifiable(
        source.transactions.map(_immutableTransaction),
      ),
      verificationWaves: List<QuarantineVerificationWave>.unmodifiable(
        source.verificationWaves.map(_immutableVerificationWave),
      ),
      caseJournal: source.caseJournal,
      transactionJournal: source.transactionJournal,
      verificationPolicyHash: source.verificationPolicyHash,
      baselineVerification: source.baselineVerification == null
          ? null
          : _immutableVerificationEvidence(source.baselineVerification!),
      analysisMode: source.analysisMode,
      acceptedRiskCodes: List<String>.unmodifiable(source.acceptedRiskCodes),
      riskAcceptanceSource: source.riskAcceptanceSource,
      selection: source.selection,
      fullRollbackAtUtc: source.fullRollbackAtUtc,
      fullRollbackVerified: source.fullRollbackVerified,
    );

QuarantineEntry _immutableEntry(QuarantineEntry source) => QuarantineEntry(
  originalPath: source.originalPath,
  sha256: source.sha256,
  sizeBytes: source.sizeBytes,
  posixMode: source.posixMode,
  operationType: source.operationType,
  declarationIds: source.declarationIds == null
      ? null
      : List<String>.unmodifiable(source.declarationIds!),
  modifiedSha256: source.modifiedSha256,
);

QuarantineCase _immutableCase(QuarantineCase source) => QuarantineCase(
  caseId: source.caseId,
  findingId: source.findingId,
  entry: _immutableEntry(source.entry),
  status: source.status,
  transactionId: source.transactionId,
  failureReason: source.failureReason,
);

QuarantineTransaction _immutableTransaction(QuarantineTransaction source) =>
    QuarantineTransaction(
      transactionId: source.transactionId,
      round: source.round,
      componentId: source.componentId,
      findingIds: List<String>.unmodifiable(source.findingIds),
      caseIds: List<String>.unmodifiable(source.caseIds),
      status: source.status,
      verificationWaveId: source.verificationWaveId,
      verificationPolicyHash: source.verificationPolicyHash,
      requiredStepIds: List<String>.unmodifiable(source.requiredStepIds),
      observedStepIds: List<String>.unmodifiable(source.observedStepIds),
      rollbackVerified: source.rollbackVerified,
      failureReason: source.failureReason,
    );

QuarantineVerificationEvidence _immutableVerificationEvidence(
  QuarantineVerificationEvidence source,
) => QuarantineVerificationEvidence(
  policyHash: source.policyHash,
  requiredStepIds: source.requiredStepIds,
  observedStepIds: source.observedStepIds,
  workingDirectory: source.workingDirectory,
  toolchainIdentity: source.toolchainIdentity,
  available: source.available,
  passed: source.passed,
  comparisonBaseline: source.comparisonBaseline,
);

QuarantineVerificationWave _immutableVerificationWave(
  QuarantineVerificationWave source,
) => QuarantineVerificationWave(
  verificationWaveId: source.verificationWaveId,
  round: source.round,
  transactionIds: source.transactionIds,
  comparisonBaselineSha256: source.comparisonBaselineSha256,
  candidateEvidence: source.candidateEvidence,
);

Map<String, Object?> _immutableJsonMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      source.map(
        (key, value) =>
            MapEntry<String, Object?>(key, _immutableJsonValue(value)),
      ),
    );

Object? _immutableJsonValue(Object? value) {
  if (value is Map<Object?, Object?>) {
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError.value(value, 'canonicalDocument');
      }
      result[key] = _immutableJsonValue(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_immutableJsonValue));
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw ArgumentError.value(value, 'canonicalDocument');
}

/// Selects manifest authority without reading or mutating the filesystem.
({ManifestCandidateName authority, ManifestRepairAction repairAction})
evaluateManifestAuthority({
  required ({int revision, String payloadSha256})? primary,
  required ({int revision, String payloadSha256})? temporary,
  required ({int revision, String payloadSha256})? previous,
  required String location,
}) {
  if (primary != null) {
    if (temporary != null) {
      final stagedNext = temporary.revision == primary.revision + 1;
      final duplicate =
          temporary.revision == primary.revision &&
          temporary.payloadSha256 == primary.payloadSha256;
      if (!stagedNext && !duplicate) {
        throw FormatException('Ambiguous manifest transition in $location.');
      }
    }
    if (previous != null) {
      final predecessor = primary.revision == previous.revision + 1;
      final duplicate =
          primary.revision == previous.revision &&
          primary.payloadSha256 == previous.payloadSha256;
      if (!predecessor && !duplicate) {
        throw FormatException('Ambiguous previous manifest in $location.');
      }
    }
    return (
      authority: ManifestCandidateName.primary,
      repairAction: temporary == null
          ? ManifestRepairAction.none
          : ManifestRepairAction.discardUncommittedTemporary,
    );
  }
  if (temporary != null && previous != null) {
    if (temporary.revision != previous.revision + 1) {
      throw FormatException(
        'Ambiguous interrupted manifest replacement in $location.',
      );
    }
    return (
      authority: ManifestCandidateName.temporary,
      repairAction: ManifestRepairAction.promoteTemporary,
    );
  }
  if (temporary != null) {
    if (temporary.revision != 1) {
      throw FormatException(
        'Manifest staging file has no authoritative predecessor in $location.',
      );
    }
    return (
      authority: ManifestCandidateName.temporary,
      repairAction: ManifestRepairAction.promoteTemporary,
    );
  }
  if (previous != null) {
    return (
      authority: ManifestCandidateName.previous,
      repairAction: ManifestRepairAction.restorePrevious,
    );
  }
  throw FormatException('Manifest not found in $location.');
}
