import '../apply/finding_selection.dart';
import '../verification/verification_runner.dart';

/// Type of quarantine operation.
enum QuarantineOperationType {
  /// Entire file moved to quarantine.
  file,

  /// File edited to remove declarations, original backed up.
  declaration;

  /// Converts to JSON string.
  String toJson() => name;

  /// Creates from JSON string.
  static QuarantineOperationType fromJson(String value) {
    return QuarantineOperationType.values.firstWhere((e) => e.name == value);
  }
}

/// Lifecycle state of one independently reversible apply case.
enum QuarantineCaseStatus {
  /// The pre-change snapshot has been persisted.
  backedUp,

  /// The finding was applied and its resulting hash was recorded.
  applied,

  /// Verification accepted the change.
  kept,

  /// The change failed verification and its snapshot was restored.
  rolledBack,

  /// The operation failed before it could be accepted.
  failed;

  /// Converts to a JSON string.
  String toJson() => name;

  /// Creates a state from a JSON string.
  static QuarantineCaseStatus fromJson(String value) {
    return QuarantineCaseStatus.values.firstWhere((e) => e.name == value);
  }
}

/// Immutable apply-selection authorization persisted with a V3 journal.
class QuarantineSelectionEvidence {
  /// Creates validated selection evidence for one non-empty initial plan.
  factory QuarantineSelectionEvidence({
    required FindingSelectionMode mode,
    required List<String> requestedFindingIds,
    required String planFingerprint,
    int? previewFingerprintVersion,
    String? previewFingerprint,
    String? expectedPreviewFingerprint,
  }) => QuarantineSelectionEvidence._validated(
    evidenceVersion: 2,
    mode: mode,
    requestedFindingIds: requestedFindingIds,
    planFingerprint: planFingerprint,
    previewFingerprintVersion: previewFingerprintVersion,
    previewFingerprint: previewFingerprint,
    expectedPreviewFingerprint: expectedPreviewFingerprint,
  );

  factory QuarantineSelectionEvidence._validated({
    required int evidenceVersion,
    required FindingSelectionMode mode,
    required List<String> requestedFindingIds,
    required String planFingerprint,
    required int? previewFingerprintVersion,
    required String? previewFingerprint,
    required String? expectedPreviewFingerprint,
  }) {
    final requested = List<String>.unmodifiable(requestedFindingIds);
    if (requested.any((value) => value.isEmpty) ||
        requested.toSet().length != requested.length) {
      throw const FormatException(
        'selection requestedFindingIds must be non-empty and unique',
      );
    }
    final sorted = requested.toList()..sort();
    if (!_sameStrings(requested, sorted)) {
      throw const FormatException(
        'selection requestedFindingIds must be sorted',
      );
    }
    if (mode == FindingSelectionMode.exact && requested.isEmpty) {
      throw const FormatException('exact selection requires finding IDs');
    }
    if (mode == FindingSelectionMode.allEligible && requested.isNotEmpty) {
      throw const FormatException(
        'allEligible selection cannot contain finding IDs',
      );
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(planFingerprint)) {
      throw const FormatException('selection planFingerprint must be SHA-256');
    }
    final hasPreviewVersion = previewFingerprintVersion != null;
    final hasActualPreview = previewFingerprint != null;
    final hasExpectedPreview = expectedPreviewFingerprint != null;
    if (hasPreviewVersion != hasActualPreview ||
        hasActualPreview != hasExpectedPreview) {
      throw const FormatException(
        'selection preview evidence must be a complete triple',
      );
    }
    if (hasActualPreview) {
      if (mode != FindingSelectionMode.exact) {
        throw const FormatException(
          'selection preview evidence requires exact finding IDs',
        );
      }
      if (previewFingerprintVersion != 1) {
        throw const FormatException(
          'selection preview fingerprint version must be 1',
        );
      }
      final tokenPattern = RegExp(r'^v1:[0-9a-f]{64}$');
      if (!tokenPattern.hasMatch(previewFingerprint) ||
          !tokenPattern.hasMatch(expectedPreviewFingerprint!)) {
        throw const FormatException(
          'selection preview fingerprints must be full lowercase v1 tokens',
        );
      }
      if (previewFingerprint != expectedPreviewFingerprint) {
        throw const FormatException(
          'selection preview fingerprints must match',
        );
      }
    }
    return QuarantineSelectionEvidence._(
      evidenceVersion: evidenceVersion,
      mode: mode,
      requestedFindingIds: requested,
      planFingerprint: planFingerprint,
      previewFingerprintVersion: previewFingerprintVersion,
      previewFingerprint: previewFingerprint,
      expectedPreviewFingerprint: expectedPreviewFingerprint,
    );
  }

  const QuarantineSelectionEvidence._({
    required int evidenceVersion,
    required this.mode,
    required this.requestedFindingIds,
    required this.planFingerprint,
    required this.previewFingerprintVersion,
    required this.previewFingerprint,
    required this.expectedPreviewFingerprint,
  }) : _evidenceVersion = evidenceVersion;

  final int _evidenceVersion;

  /// Historical all-eligible behavior or an exact hard allowlist.
  final FindingSelectionMode mode;

  /// Sorted, case-sensitive IDs explicitly requested by the user.
  final List<String> requestedFindingIds;

  /// SHA-256 over the canonical initial plan.
  final String planFingerprint;

  /// Canonical preview fingerprint version, when an exact apply was bound.
  final int? previewFingerprintVersion;

  /// Current preview token accepted by the exact apply.
  final String? previewFingerprint;

  /// User-supplied preview token equal to [previewFingerprint].
  final String? expectedPreviewFingerprint;

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'version': _evidenceVersion,
    'mode': mode.name,
    'requestedFindingIds': List<String>.of(requestedFindingIds),
    'planFingerprint': planFingerprint,
    if (previewFingerprintVersion != null)
      'previewFingerprintVersion': previewFingerprintVersion,
    if (previewFingerprint != null) 'previewFingerprint': previewFingerprint,
    if (expectedPreviewFingerprint != null)
      'expectedPreviewFingerprint': expectedPreviewFingerprint,
  };

  /// Restores and validates persisted evidence.
  factory QuarantineSelectionEvidence.fromJson(Map<String, dynamic> json) {
    final evidenceVersion = json['version'];
    if ((evidenceVersion != 1 && evidenceVersion != 2) ||
        json['mode'] is! String ||
        json['requestedFindingIds'] is! List<dynamic> ||
        (json['requestedFindingIds'] as List<dynamic>).any(
          (value) => value is! String,
        ) ||
        json['planFingerprint'] is! String) {
      throw const FormatException('invalid quarantine selection evidence');
    }
    const previewKeys = {
      'previewFingerprintVersion',
      'previewFingerprint',
      'expectedPreviewFingerprint',
    };
    if (evidenceVersion == 1 && previewKeys.any(json.containsKey)) {
      throw const FormatException(
        'V1 quarantine selection cannot contain preview evidence',
      );
    }
    final presentPreviewKeyCount = previewKeys.where(json.containsKey).length;
    if (presentPreviewKeyCount != 0 &&
        (presentPreviewKeyCount != previewKeys.length ||
            previewKeys.any((key) => json[key] == null))) {
      throw const FormatException(
        'quarantine preview evidence cannot be partial or null',
      );
    }
    if ((json['previewFingerprintVersion'] != null &&
            json['previewFingerprintVersion'] is! int) ||
        (json['previewFingerprint'] != null &&
            json['previewFingerprint'] is! String) ||
        (json['expectedPreviewFingerprint'] != null &&
            json['expectedPreviewFingerprint'] is! String)) {
      throw const FormatException('invalid quarantine preview evidence');
    }
    try {
      return QuarantineSelectionEvidence._validated(
        evidenceVersion: evidenceVersion as int,
        mode: FindingSelectionMode.values.byName(json['mode'] as String),
        requestedFindingIds: (json['requestedFindingIds'] as List<dynamic>)
            .cast<String>(),
        planFingerprint: json['planFingerprint'] as String,
        previewFingerprintVersion: json['previewFingerprintVersion'] as int?,
        previewFingerprint: json['previewFingerprint'] as String?,
        expectedPreviewFingerprint:
            json['expectedPreviewFingerprint'] as String?,
      );
    } on ArgumentError {
      throw const FormatException('unknown quarantine selection mode');
    }
  }

  static bool _sameStrings(List<String> left, List<String> right) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (left[index] != right[index]) return false;
    }
    return true;
  }
}

/// Manifest describing a quarantine's contents.
///
/// Persisted as `manifest.json` in each quarantine directory.
class QuarantineManifest {
  /// Creates a manifest.
  const QuarantineManifest({
    required this.runId,
    required this.timestamp,
    this.projectRoot,
    this.entries = const [],
    this.cases = const [],
    this.transactions = const [],
    this.verificationWaves = const [],
    this.caseJournal = false,
    this.transactionJournal = false,
    this.verificationPolicyHash,
    this.baselineVerification,
    this.analysisMode,
    this.acceptedRiskCodes = const [],
    this.riskAcceptanceSource,
    this.selection,
    this.fullRollbackAtUtc,
    this.fullRollbackVerified = false,
  });

  /// Unique run identifier.
  final String runId;

  /// When the quarantine was created.
  final DateTime timestamp;

  /// Absolute project root used when the quarantine was created.
  final String? projectRoot;

  /// Files in this quarantine.
  final List<QuarantineEntry> entries;

  /// Independently reversible snapshots for V2/V3 apply runs.
  final List<QuarantineCase> cases;

  /// Atomic apply transactions and their verification evidence.
  final List<QuarantineTransaction> transactions;

  /// Accepted combined-state verification records, in fixed-point order.
  final List<QuarantineVerificationWave> verificationWaves;

  /// Whether this manifest contains V2-compatible case snapshots.
  final bool caseJournal;

  /// Whether this manifest uses V3 atomic transaction journaling.
  final bool transactionJournal;

  /// Hash of the verification policy required for this run.
  final String? verificationPolicyHash;

  /// Complete verifier evidence captured before the first mutation.
  final QuarantineVerificationEvidence? baselineVerification;

  /// Analysis mode that authorized this mutation.
  final String? analysisMode;

  /// Stable manual-risk codes explicitly accepted for this mutation.
  final List<String> acceptedRiskCodes;

  /// Confirmation source: interactive, yesFlag, or notRequired.
  final String? riskAcceptanceSource;

  /// Initial apply-selection authorization for new V3 runs.
  final QuarantineSelectionEvidence? selection;

  /// When the full-run rollback command restored the original project bytes.
  final DateTime? fullRollbackAtUtc;

  /// Whether every restored path matched its pre-apply bytes and recorded
  /// POSIX permission bits where that platform evidence is available.
  final bool fullRollbackVerified;

  /// Whether this manifest uses the case journal transaction model.
  bool get usesCaseJournal => caseJournal || cases.isNotEmpty;

  /// Whether this manifest uses the V3 transaction journal.
  bool get usesTransactionJournal =>
      transactionJournal || transactions.isNotEmpty;

  /// Converts to JSON.
  Map<String, dynamic> toJson() {
    if (selection != null && !usesTransactionJournal) {
      throw const FormatException(
        'quarantine selection requires a V3 manifest',
      );
    }
    return {
      'version': usesTransactionJournal
          ? '3.0.0'
          : usesCaseJournal
          ? '2.0.0'
          : '1.0.0',
      'runId': runId,
      'timestamp': timestamp.toIso8601String(),
      if (projectRoot != null) 'projectRoot': projectRoot,
      'entries': entries.map((e) => e.toJson()).toList(),
      if (usesCaseJournal) 'cases': cases.map((e) => e.toJson()).toList(),
      if (usesTransactionJournal)
        'transactions': transactions.map((e) => e.toJson()).toList(),
      if (verificationWaves.isNotEmpty)
        'verificationWaves': verificationWaves.map((e) => e.toJson()).toList(),
      if (verificationPolicyHash != null)
        'verificationPolicyHash': verificationPolicyHash,
      if (baselineVerification != null)
        'baselineVerification': baselineVerification!.toJson(),
      if (analysisMode != null) 'analysisMode': analysisMode,
      'acceptedRiskCodes': acceptedRiskCodes,
      if (riskAcceptanceSource != null)
        'riskAcceptanceSource': riskAcceptanceSource,
      if (selection != null) 'selection': selection!.toJson(),
      if (fullRollbackAtUtc != null)
        'fullRollback': {
          'status': 'restored',
          'verified': fullRollbackVerified,
          'restoredAtUtc': fullRollbackAtUtc!.toUtc().toIso8601String(),
        },
    };
  }

  /// Creates from JSON.
  factory QuarantineManifest.fromJson(Map<String, dynamic> json) {
    final entriesJson = json['entries'] as List<dynamic>? ?? const [];
    final casesJson = json['cases'] as List<dynamic>? ?? const [];
    final version = json['version'] as String? ?? '1.0.0';
    final transactionsJson = json['transactions'] as List<dynamic>? ?? const [];
    final verificationWavesJson =
        json['verificationWaves'] as List<dynamic>? ?? const [];
    final selection = switch (json['selection']) {
      null => null,
      final Map<String, dynamic> value => QuarantineSelectionEvidence.fromJson(
        value,
      ),
      _ => throw const FormatException('invalid quarantine selection value'),
    };
    if (selection != null && !version.startsWith('3.')) {
      throw const FormatException(
        'quarantine selection requires a V3 manifest',
      );
    }
    final verificationWaves = verificationWavesJson
        .map(
          (value) => QuarantineVerificationWave.fromJson(
            value as Map<String, dynamic>,
          ),
        )
        .toList();
    _validateVerificationWaveMembership(verificationWaves);
    return QuarantineManifest(
      runId: json['runId'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      projectRoot: json['projectRoot'] as String?,
      entries: entriesJson
          .map((e) => QuarantineEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      cases: casesJson
          .map((e) => QuarantineCase.fromJson(e as Map<String, dynamic>))
          .toList(),
      transactions: transactionsJson
          .map((e) => QuarantineTransaction.fromJson(e as Map<String, dynamic>))
          .toList(),
      verificationWaves: verificationWaves,
      caseJournal: version.startsWith('2.') || version.startsWith('3.'),
      transactionJournal: version.startsWith('3.'),
      verificationPolicyHash: json['verificationPolicyHash'] as String?,
      baselineVerification: json['baselineVerification'] == null
          ? null
          : QuarantineVerificationEvidence.fromJson(
              json['baselineVerification'] as Map<String, dynamic>,
            ),
      analysisMode: json['analysisMode'] as String?,
      acceptedRiskCodes:
          (json['acceptedRiskCodes'] as List<dynamic>? ?? const [])
              .cast<String>(),
      riskAcceptanceSource: json['riskAcceptanceSource'] as String?,
      selection: selection,
      fullRollbackAtUtc: switch (json['fullRollback']) {
        {'restoredAtUtc': final String value} => DateTime.parse(value),
        _ => null,
      },
      fullRollbackVerified: switch (json['fullRollback']) {
        {'verified': final bool value} => value,
        _ => false,
      },
    );
  }
}

void _validateVerificationWaveMembership(
  List<QuarantineVerificationWave> waves,
) {
  final waveIds = <String>{};
  final rounds = <int>{};
  final transactionIds = <String>{};
  for (final wave in waves) {
    if (!waveIds.add(wave.verificationWaveId) || !rounds.add(wave.round)) {
      throw const FormatException('duplicate verification wave identity');
    }
    for (final transactionId in wave.transactionIds) {
      if (!transactionIds.add(transactionId)) {
        throw const FormatException(
          'transaction belongs to multiple verification waves',
        );
      }
    }
  }
}

/// Non-secret verifier identity and step-completeness evidence.
class QuarantineVerificationEvidence {
  /// Creates immutable verification evidence.
  factory QuarantineVerificationEvidence({
    required String policyHash,
    required List<String> requiredStepIds,
    required List<String> observedStepIds,
    required String workingDirectory,
    required String toolchainIdentity,
    required bool available,
    bool? passed,
    VerificationBaselineEvidence? comparisonBaseline,
  }) => QuarantineVerificationEvidence._(
    policyHash: policyHash,
    requiredStepIds: List<String>.unmodifiable(requiredStepIds),
    observedStepIds: List<String>.unmodifiable(observedStepIds),
    workingDirectory: workingDirectory,
    toolchainIdentity: toolchainIdentity,
    available: available,
    passed: passed,
    comparisonBaseline: comparisonBaseline,
  );

  const QuarantineVerificationEvidence._({
    required this.policyHash,
    required this.requiredStepIds,
    required this.observedStepIds,
    required this.workingDirectory,
    required this.toolchainIdentity,
    required this.available,
    this.passed,
    this.comparisonBaseline,
  });

  /// Exact verification policy hash.
  final String policyHash;

  /// Step IDs required by the policy.
  final List<String> requiredStepIds;

  /// Step IDs observed in this run.
  final List<String> observedStepIds;

  /// Normalized project root used by verifier processes.
  final String workingDirectory;

  /// Version-probe identity of the verifier executables.
  final String toolchainIdentity;

  /// Whether all processes started and returned an exit code.
  final bool available;

  /// Whether all configured verifier steps passed.
  ///
  /// Null identifies older manifests that did not persist this fact and must
  /// not be treated as sufficient evidence for manual verified rollback.
  final bool? passed;

  /// Sanitized parser-bound evidence for baseline-delta comparison.
  final VerificationBaselineEvidence? comparisonBaseline;

  /// Converts to JSON without command output or environment values.
  Map<String, dynamic> toJson() => {
    'policyHash': policyHash,
    'requiredStepIds': List<String>.of(requiredStepIds),
    'observedStepIds': List<String>.of(observedStepIds),
    'workingDirectory': workingDirectory,
    'toolchainIdentity': toolchainIdentity,
    'available': available,
    if (passed != null) 'passed': passed,
    if (comparisonBaseline != null)
      'comparisonBaseline': comparisonBaseline!.toJson(),
  };

  /// Creates evidence from JSON.
  factory QuarantineVerificationEvidence.fromJson(
    Map<String, dynamic> json,
  ) => QuarantineVerificationEvidence(
    policyHash: json['policyHash'] as String,
    requiredStepIds: (json['requiredStepIds'] as List<dynamic>).cast<String>(),
    observedStepIds: (json['observedStepIds'] as List<dynamic>).cast<String>(),
    workingDirectory: json['workingDirectory'] as String,
    toolchainIdentity: json['toolchainIdentity'] as String,
    available: json['available'] as bool,
    passed: json['passed'] as bool?,
    comparisonBaseline: json['comparisonBaseline'] == null
        ? null
        : VerificationBaselineEvidence.fromJson(
            Map<String, Object?>.from(
              json['comparisonBaseline'] as Map<Object?, Object?>,
            ),
          ),
  );
}

/// Lifecycle state of one atomic removal transaction.
enum QuarantineTransactionStatus {
  /// The transaction was declared before any mutation.
  pending,

  /// Every case in the transaction was applied.
  applied,

  /// Required verification accepted the complete transaction.
  verified,

  /// Verification evidence and all owned case states were committed atomically.
  committed,

  /// Every mutation was restored and rollback verification passed.
  rolledBackVerified,

  /// Applying or restoring the transaction failed.
  recoveryRequired;

  /// Converts to a JSON string.
  String toJson() => name;

  /// Creates from a JSON string.
  static QuarantineTransactionStatus fromJson(String value) =>
      QuarantineTransactionStatus.values.firstWhere(
        (status) => status.name == value,
      );
}

/// Immutable accepted verification authority for one fixed-point wave.
final class QuarantineVerificationWave {
  /// Creates a validated accepted-wave record.
  factory QuarantineVerificationWave({
    required String verificationWaveId,
    required int round,
    required List<String> transactionIds,
    required String comparisonBaselineSha256,
    required VerificationBaselineEvidence candidateEvidence,
  }) {
    if (round <= 0 ||
        verificationWaveId != 'wave-r${round.toString().padLeft(3, '0')}') {
      throw const FormatException('invalid verification wave identity');
    }
    if (transactionIds.isEmpty ||
        transactionIds.toSet().length != transactionIds.length ||
        transactionIds.any(
          (transactionId) =>
              !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(transactionId),
        )) {
      throw const FormatException('invalid verification wave membership');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(comparisonBaselineSha256)) {
      throw const FormatException('invalid verification baseline digest');
    }
    if (!candidateEvidence.isComplete) {
      throw const FormatException('incomplete verification wave evidence');
    }
    return QuarantineVerificationWave._(
      verificationWaveId: verificationWaveId,
      round: round,
      transactionIds: List.unmodifiable(transactionIds),
      comparisonBaselineSha256: comparisonBaselineSha256,
      candidateEvidence: candidateEvidence,
    );
  }

  const QuarantineVerificationWave._({
    required this.verificationWaveId,
    required this.round,
    required this.transactionIds,
    required this.comparisonBaselineSha256,
    required this.candidateEvidence,
  });

  /// Stable deterministic wave identity.
  final String verificationWaveId;

  /// Positive fixed-point round.
  final int round;

  /// Exact ordered transaction membership.
  final List<String> transactionIds;

  /// Digest of the rolling comparison baseline.
  final String comparisonBaselineSha256;

  /// Complete sanitized accepted candidate evidence.
  final VerificationBaselineEvidence candidateEvidence;

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'verificationWaveId': verificationWaveId,
    'round': round,
    'transactionIds': List<String>.of(transactionIds),
    'comparisonBaselineSha256': comparisonBaselineSha256,
    'candidateEvidence': candidateEvidence.toJson(),
  };

  /// Restores a validated accepted-wave record.
  factory QuarantineVerificationWave.fromJson(Map<String, dynamic> json) =>
      QuarantineVerificationWave(
        verificationWaveId: json['verificationWaveId'] as String,
        round: json['round'] as int,
        transactionIds: (json['transactionIds'] as List<dynamic>)
            .cast<String>(),
        comparisonBaselineSha256: json['comparisonBaselineSha256'] as String,
        candidateEvidence: VerificationBaselineEvidence.fromJson(
          Map<String, Object?>.from(
            json['candidateEvidence'] as Map<Object?, Object?>,
          ),
        ),
      );
}

/// V3 audit record for one indivisible apply transaction.
class QuarantineTransaction {
  /// Creates a transaction record.
  const QuarantineTransaction({
    required this.transactionId,
    required this.round,
    required this.componentId,
    required this.findingIds,
    required this.caseIds,
    required this.status,
    this.verificationWaveId,
    this.verificationPolicyHash,
    this.requiredStepIds = const [],
    this.observedStepIds = const [],
    this.rollbackVerified = false,
    this.failureReason,
  });

  /// Stable identifier within an apply run.
  final String transactionId;

  /// Fixed-point round that planned this transaction.
  final int round;

  /// Planner SCC/component identifier.
  final String componentId;

  /// Findings committed or rolled back as one unit.
  final List<String> findingIds;

  /// Case snapshots owned by this transaction.
  final List<String> caseIds;

  /// Current transaction state.
  final QuarantineTransactionStatus status;

  /// Shared accepted-wave identity for wave-mode transactions.
  final String? verificationWaveId;

  /// Verification policy hash used for the decision.
  final String? verificationPolicyHash;

  /// Verification steps required by the policy.
  final List<String> requiredStepIds;

  /// Verification steps actually observed.
  final List<String> observedStepIds;

  /// Whether restored state was verified against the baseline.
  final bool rollbackVerified;

  /// Apply, verification, or rollback failure reason.
  final String? failureReason;

  /// Returns a copy with updated journal evidence.
  QuarantineTransaction withState({
    required QuarantineTransactionStatus status,
    List<String>? caseIds,
    String? verificationPolicyHash,
    List<String>? requiredStepIds,
    List<String>? observedStepIds,
    bool? rollbackVerified,
    String? failureReason,
  }) => QuarantineTransaction(
    transactionId: transactionId,
    round: round,
    componentId: componentId,
    findingIds: findingIds,
    caseIds: caseIds ?? this.caseIds,
    status: status,
    verificationPolicyHash:
        verificationPolicyHash ?? this.verificationPolicyHash,
    requiredStepIds: requiredStepIds ?? this.requiredStepIds,
    observedStepIds: observedStepIds ?? this.observedStepIds,
    rollbackVerified: rollbackVerified ?? this.rollbackVerified,
    failureReason: failureReason,
    verificationWaveId: verificationWaveId,
  );

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'transactionId': transactionId,
    'round': round,
    'componentId': componentId,
    'findingIds': findingIds,
    'caseIds': caseIds,
    'status': status.toJson(),
    if (verificationWaveId != null) 'verificationWaveId': verificationWaveId,
    if (verificationPolicyHash != null)
      'verificationPolicyHash': verificationPolicyHash,
    'requiredStepIds': requiredStepIds,
    'observedStepIds': observedStepIds,
    'rollbackVerified': rollbackVerified,
    if (failureReason != null) 'failureReason': failureReason,
  };

  /// Creates a transaction from JSON.
  factory QuarantineTransaction.fromJson(Map<String, dynamic> json) =>
      QuarantineTransaction(
        transactionId: json['transactionId'] as String,
        round: json['round'] as int,
        componentId: json['componentId'] as String,
        findingIds: (json['findingIds'] as List<dynamic>).cast<String>(),
        caseIds: (json['caseIds'] as List<dynamic>? ?? const []).cast<String>(),
        status: QuarantineTransactionStatus.fromJson(json['status'] as String),
        verificationWaveId: json['verificationWaveId'] as String?,
        verificationPolicyHash: json['verificationPolicyHash'] as String?,
        requiredStepIds: (json['requiredStepIds'] as List<dynamic>? ?? const [])
            .cast<String>(),
        observedStepIds: (json['observedStepIds'] as List<dynamic>? ?? const [])
            .cast<String>(),
        rollbackVerified: json['rollbackVerified'] as bool? ?? false,
        failureReason: json['failureReason'] as String?,
      );
}

/// Journal entry for one finding applied as an independent transaction.
class QuarantineCase {
  /// Creates a case journal entry.
  const QuarantineCase({
    required this.caseId,
    required this.findingId,
    required this.entry,
    required this.status,
    this.transactionId,
    this.failureReason,
  });

  /// Stable identifier within one apply run.
  final String caseId;

  /// Graph node ID of the finding being applied.
  final String findingId;

  /// Snapshot metadata for the one file affected by this finding.
  final QuarantineEntry entry;

  /// Current journal state.
  final QuarantineCaseStatus status;

  /// V3 transaction that owns this case.
  final String? transactionId;

  /// Failure or verification reason when the case was not kept.
  final String? failureReason;

  /// Returns this case with a new status and optional failure reason.
  QuarantineCase withStatus(
    QuarantineCaseStatus value, {
    String? failureReason,
  }) => QuarantineCase(
    caseId: caseId,
    findingId: findingId,
    entry: entry,
    status: value,
    transactionId: transactionId,
    failureReason: failureReason,
  );

  /// Returns this case with its post-apply hash recorded.
  QuarantineCase withAppliedHash(String? value) => QuarantineCase(
    caseId: caseId,
    findingId: findingId,
    entry: entry.withModifiedSha256(value),
    status: QuarantineCaseStatus.applied,
    transactionId: transactionId,
  );

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'caseId': caseId,
    'findingId': findingId,
    'status': status.toJson(),
    if (transactionId != null) 'transactionId': transactionId,
    'entry': entry.toJson(),
    if (failureReason != null) 'failureReason': failureReason,
  };

  /// Creates a case from JSON.
  factory QuarantineCase.fromJson(Map<String, dynamic> json) {
    return QuarantineCase(
      caseId: json['caseId'] as String,
      findingId: json['findingId'] as String,
      entry: QuarantineEntry.fromJson(json['entry'] as Map<String, dynamic>),
      status: QuarantineCaseStatus.fromJson(json['status'] as String),
      transactionId: json['transactionId'] as String?,
      failureReason: json['failureReason'] as String?,
    );
  }
}

/// A file entry in a quarantine manifest.
class QuarantineEntry {
  /// Creates a quarantine entry.
  const QuarantineEntry({
    required this.originalPath,
    required this.sha256,
    required this.sizeBytes,
    this.posixMode,
    this.operationType = QuarantineOperationType.file,
    this.declarationIds,
    this.modifiedSha256,
  }) : assert(posixMode == null || (posixMode >= 0 && posixMode <= 0xfff));

  /// Original absolute path before quarantine.
  final String originalPath;

  /// SHA-256 hash for verification.
  final String sha256;

  /// File size in bytes.
  final int sizeBytes;

  /// Original POSIX permission bits, including special permission bits.
  ///
  /// Null is retained for Windows and manifests written before this evidence
  /// was recorded.
  final int? posixMode;

  /// Type of operation this entry represents.
  final QuarantineOperationType operationType;

  /// Declaration IDs removed (declaration-level only).
  final List<String>? declarationIds;

  /// SHA-256 of modified file after declaration removal.
  final String? modifiedSha256;

  /// Returns this entry with the final working-copy hash recorded.
  QuarantineEntry withModifiedSha256(String? value) => QuarantineEntry(
    originalPath: originalPath,
    sha256: sha256,
    sizeBytes: sizeBytes,
    posixMode: posixMode,
    operationType: operationType,
    declarationIds: declarationIds,
    modifiedSha256: value,
  );

  /// Converts to JSON.
  Map<String, dynamic> toJson() => {
    'originalPath': originalPath,
    'sha256': sha256,
    'sizeBytes': sizeBytes,
    if (posixMode != null) 'posixMode': posixMode,
    'operationType': operationType.toJson(),
    if (declarationIds != null) 'declarationIds': declarationIds,
    if (modifiedSha256 != null) 'modifiedSha256': modifiedSha256,
  };

  /// Creates from JSON.
  factory QuarantineEntry.fromJson(Map<String, dynamic> json) {
    final posixMode = json['posixMode'];
    if (posixMode != null &&
        (posixMode is! int || posixMode < 0 || posixMode > 0xfff)) {
      throw const FormatException(
        'posixMode must be an integer between 0 and 4095.',
      );
    }
    return QuarantineEntry(
      originalPath: json['originalPath'] as String,
      sha256: json['sha256'] as String,
      sizeBytes: json['sizeBytes'] as int,
      posixMode: posixMode as int?,
      operationType: json.containsKey('operationType')
          ? QuarantineOperationType.fromJson(json['operationType'] as String)
          : QuarantineOperationType.file,
      declarationIds: json['declarationIds'] != null
          ? (json['declarationIds'] as List<dynamic>).cast<String>()
          : null,
      modifiedSha256: json['modifiedSha256'] as String?,
    );
  }
}
