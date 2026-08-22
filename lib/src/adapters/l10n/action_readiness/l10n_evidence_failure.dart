/// Stable rejection identities emitted by l10n evidence stages.
enum L10nEvidenceRejectionCode {
  /// A scan blocker prevents evidence collection.
  scanBlockerPresent,

  /// The requested localization selection is invalid.
  invalidSelection,

  /// The configured l10n option is unsupported.
  unsupportedConfiguration,

  /// An input path is invalid or escapes the project.
  invalidInputPath,

  /// The ARB locale family is incomplete.
  arbFamilyIncomplete,

  /// An ARB input cannot be parsed safely.
  arbParseFailure,

  /// A staged input cannot be materialized.
  materializationFailed,

  /// A source changed after it was recorded.
  sourceDrift,

  /// Package resolution changed after it was recorded.
  packageResolutionDrift,

  /// The required l10n toolchain is unavailable.
  toolchainUnavailable,

  /// The l10n toolchain changed after it was recorded.
  toolchainDrift,

  /// A staged edit fails its required postcondition.
  editPostconditionFailed,

  /// Baseline generated output could not be produced.
  baselineGenerationFailed,

  /// Existing generated output is stale.
  staleGeneratedOutput,

  /// Candidate generated output could not be produced.
  candidateGenerationFailed,

  /// Generator output ended before it was complete.
  generatorOutputTruncated,

  /// Generator process termination could not be confirmed.
  generatorTerminationUnconfirmed,

  /// A stage wrote to an unexpected path.
  unexpectedStageWrite,

  /// Generated output cannot be assigned to one family.
  outputFamilyAmbiguous,

  /// Candidate output does not verify the requested change.
  candidateVerificationFailed,

  /// Staged resources could not be cleaned up.
  cleanupFailed,

  /// An unexpected internal condition prevented evidence collection.
  internalFailure,
}

/// A stable, structured l10n evidence rejection.
final class L10nEvidenceFailure {
  /// Creates a rejection identity without retaining free-form error text.
  const L10nEvidenceFailure({
    required this.code,
    required this.stage,
    required this.detailCode,
    this.relativePath,
  });

  /// The declaration-ordered category of rejection.
  final L10nEvidenceRejectionCode code;

  /// The named evidence stage that rejected the request.
  final String stage;

  /// A stable, machine-readable rejection detail.
  final String detailCode;

  /// The project-relative path involved in the rejection, when known.
  final String? relativePath;
}
