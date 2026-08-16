/// How confident the tool is that a finding can be acted on.
///
/// Deliberately a small ordered set of tiers rather than a numeric score.
/// A score like "97% confident" invites a threshold comparison, and
/// `confidence > 0.95` is exactly the wrong gate for an operation that deletes
/// files: eligibility must come from hard predicates that all have to hold.
///
/// Scores are still useful for *ordering* findings within a tier.
enum Confidence {
  /// Never eligible for automatic removal, under any flag.
  ///
  /// Entry points, native callbacks, plugin background handlers, keep rules,
  /// security-sensitive resources. Protection beats every other rule.
  protected,

  /// Something unresolved could address this node.
  ///
  /// Dynamic strings, deep links, server-driven input, runtime-only evidence,
  /// uncertain generator provenance, an incomplete target matrix. Reported,
  /// never auto-applied.
  review,

  /// Strong static evidence of unreachability, but removal has broad semantics.
  ///
  /// Eligible only when the active mode accepts its exact manual-risk set.
  high,

  /// All safety predicates hold and the edit has a deterministic inverse.
  ///
  /// The only tier eligible without manual-risk acknowledgement.
  safe;

  /// Whether this tier is automatically applicable before mode policy.
  bool get isAutoApplicable => this == Confidence.safe;

  /// Whether this tier may be applied with explicit opt-in.
  bool get isApplicableWithOptIn =>
      this == Confidence.safe || this == Confidence.high;

  /// Short label for report output.
  String get label => switch (this) {
    Confidence.protected => 'PROTECTED',
    Confidence.review => 'REVIEW',
    Confidence.high => 'HIGH',
    Confidence.safe => 'SAFE',
  };
}

/// The predicates that must **all** hold for a finding to be [Confidence.safe].
///
/// Modelled explicitly so reports can show precisely which predicate failed,
/// and so tests can assert on individual predicates. This is the tool's central
/// safety invariant: if you are tempted to relax one of these, add a tier
/// instead.
class SafetyPredicates {
  /// Records the outcome of each safety predicate.
  const SafetyPredicates({
    required this.ruleAllowsAutoFix,
    required this.unreachableAcrossAllTargets,
    required this.noDynamicBlockers,
    required this.notProtected,
    required this.noPublicApiRisk,
    required this.hasDeterministicInverse,
    this.analysisCoverageComplete = true,
    this.actionSupported = true,
  });

  /// The rule that produced this finding is on the auto-fix allowlist.
  final bool ruleAllowsAutoFix;

  /// The node is unreachable under every configured build target.
  final bool unreachableAcrossAllTargets;

  /// No unresolved dynamic construct could address this node.
  final bool noDynamicBlockers;

  /// The node carries no protection reason.
  final bool notProtected;

  /// The node is not part of an externally consumed public API.
  ///
  /// Relevant for reusable packages: a public export with no local consumer is
  /// still API for downstream packages.
  final bool noPublicApiRisk;

  /// The edit can be reversed byte-for-byte.
  final bool hasDeterministicInverse;

  /// The build-target matrix and externally addressable roots are complete.
  final bool analysisCoverageComplete;

  /// The production apply engine implements the preflighted edit.
  final bool actionSupported;

  /// Whether every predicate holds.
  bool get allHold =>
      ruleAllowsAutoFix &&
      unreachableAcrossAllTargets &&
      noDynamicBlockers &&
      notProtected &&
      noPublicApiRisk &&
      hasDeterministicInverse &&
      analysisCoverageComplete &&
      actionSupported;

  /// Names of the predicates that failed, for `explain` output.
  List<String> get failedPredicates => [
    if (!ruleAllowsAutoFix) 'rule not on auto-fix allowlist',
    if (!unreachableAcrossAllTargets) 'reachable in at least one target',
    if (!noDynamicBlockers) 'an unresolved dynamic construct could match',
    if (!notProtected) 'node is protected',
    if (!noPublicApiRisk) 'node may be part of a public API surface',
    if (!hasDeterministicInverse) 'edit is not reversibly invertible',
    if (!analysisCoverageComplete)
      'analysis target/root coverage is incomplete',
    if (!actionSupported) 'no supported apply action exists',
  ];
}
