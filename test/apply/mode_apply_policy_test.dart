import 'package:flutter_pruner/src/apply/mode_apply_policy.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:test/test.dart';

void main() {
  test('application allows SAFE only', () {
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.application,
        _finding(Confidence.safe),
      ),
      isTrue,
    );
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.application,
        _finding(Confidence.high),
      ),
      isFalse,
    );
  });

  test('package is always review-only', () {
    for (final confidence in Confidence.values) {
      expect(
        ModeApplyPolicy.allows(AnalysisMode.package, _finding(confidence)),
        isFalse,
      );
    }
  });

  test('package-internal accepts only exact external-consumer HIGH risk', () {
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(
          Confidence.high,
          risks: {ManualRisk.externalConsumersNotScanned},
        ),
      ),
      isTrue,
    );
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(
          Confidence.high,
          risks: {
            ManualRisk.externalConsumersNotScanned,
            ManualRisk.broadRemovalScope,
          },
        ),
      ),
      isFalse,
    );
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(Confidence.review),
      ),
      isFalse,
    );
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(Confidence.protected),
      ),
      isFalse,
    );
  });
}

Finding _finding(Confidence confidence, {Set<ManualRisk> risks = const {}}) =>
    Finding(
      ruleId: 'TEST',
      node: GraphNode(
        id: 'dart:test/lib/src/unused.dart#unused',
        kind: NodeKind.declaration,
        origin: Uri.file('/project/lib/src/unused.dart'),
      ),
      confidence: confidence,
      title: 'unused',
      predicates: const SafetyPredicates(
        ruleAllowsAutoFix: true,
        unreachableAcrossAllTargets: true,
        noDynamicBlockers: true,
        notProtected: true,
        noPublicApiRisk: true,
        hasDeterministicInverse: true,
      ),
      proposedAction: 'Remove declaration',
      manualRisks: risks,
      reportingAdapterId: 'dart',
    );
