import '../graph/node.dart';
import 'action_capability.dart';
import 'classification_reason.dart';
import 'confidence.dart';

/// Facts consumed by the pure confidence classifier.
class FindingAssessment {
  /// Creates a candidate assessment.
  factory FindingAssessment({
    required GraphNode node,
    required SafetyPredicates predicates,
    required ActionCapability actionCapability,
    required bool isProtected,
    required bool hasDynamicBlockers,
    required Set<ManualRisk> manualRisks,
  }) => FindingAssessment._(
    node: node,
    predicates: predicates,
    actionCapability: actionCapability,
    isProtected: isProtected,
    hasDynamicBlockers: hasDynamicBlockers,
    manualRisks: Set<ManualRisk>.unmodifiable(manualRisks),
  );

  const FindingAssessment._({
    required this.node,
    required this.predicates,
    required this.actionCapability,
    required this.isProtected,
    required this.hasDynamicBlockers,
    required this.manualRisks,
  });

  /// Candidate graph node.
  final GraphNode node;

  /// Named hard gates and public API predicate.
  final SafetyPredicates predicates;

  /// Preflighted operation support and inverse semantics.
  final ActionCapability actionCapability;

  /// Whether a protection rule covers this node.
  final bool isProtected;

  /// Whether an unresolved construct could address the node.
  final bool hasDynamicBlockers;

  /// Explicit risks eligible for manual HIGH opt-in.
  final Set<ManualRisk> manualRisks;

  /// Hard gates shared by SAFE and HIGH.
  bool get hardGatesHold =>
      predicates.analysisCoverageComplete &&
      predicates.unreachableAcrossAllTargets &&
      predicates.noDynamicBlockers &&
      predicates.notProtected &&
      predicates.ruleAllowsAutoFix &&
      predicates.actionSupported &&
      predicates.hasDeterministicInverse;
}
