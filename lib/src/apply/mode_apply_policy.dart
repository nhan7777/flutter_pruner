import '../core/confidence/classification_reason.dart';
import '../core/confidence/confidence.dart';
import '../core/confidence/finding.dart';
import '../core/project/analysis_mode.dart';

/// Mode-specific authorization for reversible finding actions.
class ModeApplyPolicy {
  ModeApplyPolicy._();

  /// Whether [finding] may enter an apply plan in [mode].
  static bool allows(AnalysisMode mode, Finding finding) {
    if (!_hardGatesHold(finding)) return false;
    return switch (mode) {
      AnalysisMode.application => finding.confidence == Confidence.safe,
      AnalysisMode.package => false,
      AnalysisMode.packageInternal =>
        finding.confidence == Confidence.safe ||
            finding.confidence == Confidence.high &&
                finding.manualRisks.length == 1 &&
                finding.manualRisks.contains(
                  ManualRisk.externalConsumersNotScanned,
                ),
    };
  }

  /// Whether acting on [finding] requires explicit risk acknowledgement.
  static bool requiresExternalConsumerAcknowledgement(Finding finding) =>
      finding.confidence == Confidence.high &&
      finding.manualRisks.length == 1 &&
      finding.manualRisks.contains(ManualRisk.externalConsumersNotScanned);

  static bool _hardGatesHold(Finding finding) {
    final predicates = finding.predicates;
    return predicates.analysisCoverageComplete &&
        predicates.unreachableAcrossAllTargets &&
        predicates.notRetained &&
        predicates.noDynamicBlockers &&
        predicates.notProtected &&
        predicates.ruleAllowsAutoFix &&
        predicates.actionSupported &&
        predicates.hasDeterministicInverse;
  }
}
