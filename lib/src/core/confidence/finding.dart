import '../graph/evidence.dart';
import '../graph/node.dart';
import 'classification_reason.dart';
import 'confidence.dart';

/// A single actionable observation about the project.
///
/// A finding must always be able to explain itself. "unused" is not an
/// acceptable report; the tool has to say what it checked, under which targets,
/// what evidence it found, and what remains uncertain.
class Finding {
  /// Creates a finding.
  factory Finding({
    required String ruleId,
    required GraphNode node,
    required Confidence confidence,
    required String title,
    required SafetyPredicates predicates,
    List<Evidence> evidence = const [],
    List<Blocker> blockers = const [],
    List<String> protectionReasons = const [],
    List<String> unreachableIn = const [],
    List<String> reachableIn = const [],
    List<String> retainedIn = const [],
    List<String> auxiliaryRetainedIn = const [],
    String? proposedAction,
    int? sourceBytes,
    List<ClassificationReason> classificationReasons = const [],
    Set<ManualRisk> manualRisks = const {},
    String? reportingAdapterId,
  }) => Finding._(
    ruleId: ruleId,
    node: node,
    confidence: confidence,
    title: title,
    predicates: predicates,
    evidence: List<Evidence>.unmodifiable(evidence),
    blockers: List<Blocker>.unmodifiable(blockers),
    protectionReasons: List<String>.unmodifiable(protectionReasons),
    unreachableIn: _canonicalIdentities(unreachableIn),
    reachableIn: _canonicalIdentities(reachableIn),
    retainedIn: _canonicalIdentities(retainedIn),
    auxiliaryRetainedIn: _canonicalIdentities(auxiliaryRetainedIn),
    proposedAction: proposedAction,
    sourceBytes: sourceBytes,
    classificationReasons: List<ClassificationReason>.unmodifiable(
      classificationReasons,
    ),
    manualRisks: Set<ManualRisk>.unmodifiable(manualRisks),
    reportingAdapterId: reportingAdapterId,
  );

  const Finding._({
    required this.ruleId,
    required this.node,
    required this.confidence,
    required this.title,
    required this.predicates,
    required this.evidence,
    required this.blockers,
    required this.protectionReasons,
    required this.unreachableIn,
    required this.reachableIn,
    required this.retainedIn,
    required this.auxiliaryRetainedIn,
    required this.proposedAction,
    required this.sourceBytes,
    required this.classificationReasons,
    required this.manualRisks,
    required this.reportingAdapterId,
  });

  /// Stable rule identifier, for example `PRN-ASSET-001`.
  ///
  /// Stable ids let users suppress individual rules and let CI diff findings
  /// between runs.
  final String ruleId;

  /// The node this finding is about.
  final GraphNode node;

  /// The verdict.
  final Confidence confidence;

  /// One-line summary.
  final String title;

  /// Outcome of each safety predicate.
  final SafetyPredicates predicates;

  /// Positive evidence gathered while analysing this node.
  final List<Evidence> evidence;

  /// Unresolved constructs that could address this node.
  final List<Blocker> blockers;

  /// Why the node is protected, when it is.
  final List<String> protectionReasons;

  /// Names of targets where the node is unreachable.
  final List<String> unreachableIn;

  /// Names of targets where the node is reachable.
  final List<String> reachableIn;

  /// Configured target names whose fail-closed closure retains this node.
  final List<String> retainedIn;

  /// Full auxiliary execution-context IDs that retain this node.
  final List<String> auxiliaryRetainedIn;

  /// What the tool proposes to do, when it proposes anything.
  final String? proposedAction;

  /// Source bytes that would be removed.
  ///
  /// Source bytes only. Never present this as a binary-size saving: release
  /// builds tree-shake Dart code, and assets with build-time transformers are
  /// bundled at a different size than their source. Binary impact requires
  /// measuring the release artifact before and after.
  final int? sourceBytes;

  /// Stable reasons explaining conservative or opt-in classification.
  final List<ClassificationReason> classificationReasons;

  /// Explicit allowlisted risks required to act on this finding.
  final Set<ManualRisk> manualRisks;

  /// Adapter responsible for reporting this finding.
  final String? reportingAdapterId;

  /// Whether the tier is automatically applicable before mode policy.
  bool get isAutoApplicable => confidence.isAutoApplicable;

  /// Human-readable reason this finding is not [Confidence.safe].
  String? get whyNotSafe {
    if (confidence == Confidence.safe) return null;
    final failed = predicates.failedPredicates;
    if (failed.isEmpty) return null;
    return failed.join('; ');
  }

  @override
  String toString() => '[$ruleId ${confidence.label}] ${node.id}';
}

List<String> _canonicalIdentities(Iterable<String> values) {
  final canonical = values.toSet().toList()..sort();
  return List<String>.unmodifiable(canonical);
}
