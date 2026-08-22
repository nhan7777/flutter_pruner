/// Stable reasons a finding was assigned to its confidence tier.
enum ClassificationReason {
  /// The configured build targets are inferred or explicitly partial.
  incompleteTargetMatrix('incomplete-target-matrix'),

  /// Externally addressable application/package roots are incomplete.
  incompleteRootCoverage('incomplete-root-coverage'),

  /// Reusable package mode is intentionally audit-only.
  packageReviewOnly('package-review-only'),

  /// The analysis graph contains an edge whose source or target is missing.
  incompleteGraphIntegrity('incomplete-graph-integrity'),

  /// A dynamic or unresolved reference could address the node.
  dynamicReference('dynamic-reference'),

  /// Generated code prevents an independent proof of removal.
  generatedCodeUncertainty('generated-code-uncertainty'),

  /// A human must select the canonical member of a duplicate group.
  duplicateCanonicalChoice('duplicate-canonical-choice'),

  /// No production apply operation exists for this finding.
  unsupportedAction('unsupported-action'),

  /// The proposed edit cannot yet be reversed deterministically.
  nonDeterministicInverse('non-deterministic-inverse'),

  /// External package consumers were intentionally excluded from analysis.
  externalConsumersNotScanned('external-consumers-not-scanned'),

  /// An execution context retains the node without proving an exact caller.
  retainedOnly('retained-only'),

  /// The operation spans a whole library or dependency closure.
  broadRemovalScope('broad-removal-scope');

  const ClassificationReason(this.code);

  /// Stable wire value used by JSON reports and manifests.
  final String code;

  /// Concise explanation suitable for human-readable reports.
  String get humanDescription => switch (this) {
    ClassificationReason.incompleteTargetMatrix =>
      'Missing targets in .flutter_pruner/config.yaml',
    ClassificationReason.incompleteRootCoverage =>
      'Missing entry roots in .flutter_pruner/config.yaml',
    ClassificationReason.packageReviewOnly =>
      'Reusable package mode is review-only',
    ClassificationReason.incompleteGraphIntegrity =>
      'Broken analysis edge; inspect adapter diagnostics',
    ClassificationReason.dynamicReference =>
      'A dynamic reference may still use this',
    ClassificationReason.generatedCodeUncertainty =>
      'Generated code could not be fully resolved',
    ClassificationReason.duplicateCanonicalChoice =>
      'Choose the canonical duplicate manually',
    ClassificationReason.unsupportedAction => 'No supported apply action',
    ClassificationReason.nonDeterministicInverse =>
      'This change cannot be reversed exactly',
    ClassificationReason.externalConsumersNotScanned =>
      'External consumers may still use this package surface',
    ClassificationReason.retainedOnly =>
      'Retention evidence prevents automatic removal',
    ClassificationReason.broadRemovalScope =>
      'Removal affects a broad dependency scope',
  };
}

/// Manual risks that may qualify for HIGH when every hard gate holds.
enum ManualRisk {
  /// External consumers may depend on package surface excluded from the scan.
  externalConsumersNotScanned('external-consumers-not-scanned'),

  /// The edit removes a broad closure rather than one narrow node.
  broadRemovalScope('broad-removal-scope');

  const ManualRisk(this.code);

  /// Stable wire value used by reports and apply authorization.
  final String code;
}
