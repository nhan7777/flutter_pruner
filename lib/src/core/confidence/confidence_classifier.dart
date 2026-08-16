import '../graph/node.dart';
import 'confidence.dart';
import 'finding_assessment.dart';

/// Assigns a tier from explicit positive eligibility rules.
class ConfidenceClassifier {
  /// Creates the stateless classifier.
  const ConfidenceClassifier();

  /// Classifies [assessment] without a catch-all HIGH branch.
  Confidence classify(FindingAssessment assessment) {
    if (assessment.isProtected) return Confidence.protected;
    if (assessment.node.kind == NodeKind.duplicateGroup) {
      return Confidence.review;
    }
    if (!assessment.hardGatesHold) return Confidence.review;
    if (assessment.manualRisks.isEmpty) return Confidence.safe;
    if (assessment.manualRisks.length == 1) return Confidence.high;
    return Confidence.review;
  }
}
