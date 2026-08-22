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

  test('application rejects SAFE when any shared hard gate is false', () {
    final failedHardGates = <String, SafetyPredicates>{
      'analysisCoverageComplete': _predicates(analysisCoverageComplete: false),
      'unreachableAcrossAllTargets': _predicates(
        unreachableAcrossAllTargets: false,
      ),
      'notRetained': _predicates(notRetained: false),
      'noDynamicBlockers': _predicates(noDynamicBlockers: false),
      'notProtected': _predicates(notProtected: false),
      'ruleAllowsAutoFix': _predicates(ruleAllowsAutoFix: false),
      'actionSupported': _predicates(actionSupported: false),
      'hasDeterministicInverse': _predicates(hasDeterministicInverse: false),
    };

    for (final entry in failedHardGates.entries) {
      expect(
        ModeApplyPolicy.allows(
          AnalysisMode.application,
          _finding(Confidence.safe, predicates: entry.value),
        ),
        isFalse,
        reason: '${entry.key} must remain an apply hard gate',
      );
    }
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
          predicates: _predicates(noPublicApiRisk: false),
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
          predicates: _predicates(noPublicApiRisk: false),
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

  test('package-internal rejects retained SAFE and acknowledged HIGH', () {
    final retained = _predicates(notRetained: false);

    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(Confidence.safe, predicates: retained),
      ),
      isFalse,
    );
    expect(
      ModeApplyPolicy.allows(
        AnalysisMode.packageInternal,
        _finding(
          Confidence.high,
          predicates: retained,
          risks: {ManualRisk.externalConsumersNotScanned},
        ),
      ),
      isFalse,
    );
  });
}

Finding _finding(
  Confidence confidence, {
  SafetyPredicates predicates = _allHardGates,
  Set<ManualRisk> risks = const {},
}) => Finding(
  ruleId: 'TEST',
  node: GraphNode(
    id: 'dart:test/lib/src/unused.dart#unused',
    kind: NodeKind.declaration,
    origin: Uri.file('/project/lib/src/unused.dart'),
  ),
  confidence: confidence,
  title: 'unused',
  predicates: predicates,
  proposedAction: 'Remove declaration',
  manualRisks: risks,
  reportingAdapterId: 'dart',
);

const _allHardGates = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  notRetained: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
  analysisCoverageComplete: true,
  actionSupported: true,
);

SafetyPredicates _predicates({
  bool ruleAllowsAutoFix = true,
  bool unreachableAcrossAllTargets = true,
  bool notRetained = true,
  bool noDynamicBlockers = true,
  bool notProtected = true,
  bool noPublicApiRisk = true,
  bool hasDeterministicInverse = true,
  bool analysisCoverageComplete = true,
  bool actionSupported = true,
}) => SafetyPredicates(
  ruleAllowsAutoFix: ruleAllowsAutoFix,
  unreachableAcrossAllTargets: unreachableAcrossAllTargets,
  notRetained: notRetained,
  noDynamicBlockers: noDynamicBlockers,
  notProtected: notProtected,
  noPublicApiRisk: noPublicApiRisk,
  hasDeterministicInverse: hasDeterministicInverse,
  analysisCoverageComplete: analysisCoverageComplete,
  actionSupported: actionSupported,
);
