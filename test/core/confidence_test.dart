import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

/// All predicates holding — the only configuration that may be `SAFE`.
const SafetyPredicates _allHold = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
);

GraphNode _node(String id) =>
    GraphNode(id: id, kind: NodeKind.asset, origin: Uri.parse('file:///$id'));

Finding _finding({
  required Confidence confidence,
  SafetyPredicates predicates = _allHold,
}) => Finding(
  ruleId: 'PRN-TEST-001',
  node: _node('asset:app/assets/logo.png'),
  confidence: confidence,
  title: 'unused asset',
  predicates: predicates,
);

void main() {
  group('tier semantics', () {
    test('only SAFE is auto-applicable', () {
      expect(Confidence.safe.isAutoApplicable, isTrue);
      expect(Confidence.high.isAutoApplicable, isFalse);
      expect(Confidence.review.isAutoApplicable, isFalse);
      expect(Confidence.protected.isAutoApplicable, isFalse);
    });

    test('opt-in covers SAFE and HIGH only', () {
      expect(Confidence.safe.isApplicableWithOptIn, isTrue);
      expect(Confidence.high.isApplicableWithOptIn, isTrue);
      expect(Confidence.review.isApplicableWithOptIn, isFalse);
      expect(Confidence.protected.isApplicableWithOptIn, isFalse);
    });

    test('PROTECTED is never applicable under any flag', () {
      // Protection outranks everything, including a total absence of
      // references. There is no flag that may override it.
      expect(Confidence.protected.isAutoApplicable, isFalse);
      expect(Confidence.protected.isApplicableWithOptIn, isFalse);
    });

    test('labels are stable report output', () {
      expect(Confidence.safe.label, 'SAFE');
      expect(Confidence.high.label, 'HIGH');
      expect(Confidence.review.label, 'REVIEW');
      expect(Confidence.protected.label, 'PROTECTED');
    });

    test('tiers order from least to most confident', () {
      expect(
        Confidence.values,
        equals([
          Confidence.protected,
          Confidence.review,
          Confidence.high,
          Confidence.safe,
        ]),
      );
    });
  });

  group('explicit confidence classifier', () {
    FindingAssessment assessment({
      GraphNode? node,
      SafetyPredicates predicates = _allHold,
      ActionCapability capability = const ActionCapability(
        supported: true,
        deterministicInverse: true,
        scope: ActionScope.narrow,
        proposedAction: 'Remove',
      ),
      Set<ManualRisk> risks = const {},
      bool protected = false,
      bool blocked = false,
    }) => FindingAssessment(
      node: node ?? _node('asset:app/assets/logo.png'),
      predicates: predicates,
      actionCapability: capability,
      isProtected: protected,
      hasDynamicBlockers: blocked,
      manualRisks: risks,
    );

    test('all hard gates and no manual risk produce SAFE', () {
      expect(
        const ConfidenceClassifier().classify(assessment()),
        Confidence.safe,
      );
    });

    test('exactly one explicitly allowlisted manual risk produces HIGH', () {
      const allowlisted = {
        ManualRisk.externalConsumersNotScanned,
        ManualRisk.broadRemovalScope,
      };
      for (final risk in allowlisted) {
        expect(
          const ConfidenceClassifier().classify(assessment(risks: {risk})),
          Confidence.high,
          reason: risk.code,
        );
      }
    });

    test('two simultaneous manual risks produce REVIEW', () {
      expect(
        const ConfidenceClassifier().classify(
          assessment(
            risks: {
              ManualRisk.externalConsumersNotScanned,
              ManualRisk.broadRemovalScope,
            },
          ),
        ),
        Confidence.review,
      );
    });

    test('unsupported action produces REVIEW rather than fallback HIGH', () {
      expect(
        const ConfidenceClassifier().classify(
          assessment(
            predicates: const SafetyPredicates(
              ruleAllowsAutoFix: false,
              unreachableAcrossAllTargets: true,
              noDynamicBlockers: true,
              notProtected: true,
              noPublicApiRisk: true,
              hasDeterministicInverse: false,
              actionSupported: false,
            ),
            capability: const ActionCapability(
              supported: false,
              deterministicInverse: false,
              scope: ActionScope.broad,
            ),
          ),
        ),
        Confidence.review,
      );
    });

    test('incomplete coverage produces REVIEW', () {
      expect(
        const ConfidenceClassifier().classify(
          assessment(
            predicates: const SafetyPredicates(
              ruleAllowsAutoFix: true,
              unreachableAcrossAllTargets: true,
              noDynamicBlockers: true,
              notProtected: true,
              noPublicApiRisk: true,
              hasDeterministicInverse: true,
              analysisCoverageComplete: false,
            ),
          ),
        ),
        Confidence.review,
      );
    });

    test('duplicate groups remain REVIEW even with HIGH risk', () {
      final duplicate = GraphNode(
        id: 'dup:app:abc',
        kind: NodeKind.duplicateGroup,
        origin: Uri.file('/project/a.png'),
      );
      expect(
        const ConfidenceClassifier().classify(
          assessment(node: duplicate, risks: {ManualRisk.broadRemovalScope}),
        ),
        Confidence.review,
      );
    });

    test('protection has absolute precedence', () {
      expect(
        const ConfidenceClassifier().classify(assessment(protected: true)),
        Confidence.protected,
      );
    });
  });

  group('safety predicates', () {
    test('all six holding is the only way allHold is true', () {
      expect(_allHold.allHold, isTrue);
      expect(_allHold.failedPredicates, isEmpty);
    });

    test('every single predicate failing alone defeats allHold', () {
      final variants = <String, SafetyPredicates>{
        'ruleAllowsAutoFix': const SafetyPredicates(
          ruleAllowsAutoFix: false,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: true,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
        'unreachableAcrossAllTargets': const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: false,
          noDynamicBlockers: true,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
        'noDynamicBlockers': const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: false,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
        'notProtected': const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: true,
          notProtected: false,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
        'noPublicApiRisk': const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: true,
          notProtected: true,
          noPublicApiRisk: false,
          hasDeterministicInverse: true,
        ),
        'hasDeterministicInverse': const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: true,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: false,
        ),
      };

      for (final entry in variants.entries) {
        expect(
          entry.value.allHold,
          isFalse,
          reason: '${entry.key} = false must defeat allHold',
        );
        expect(
          entry.value.failedPredicates,
          hasLength(1),
          reason: 'only ${entry.key} should be reported as failed',
        );
      }
    });

    test('failedPredicates names every failure, not just the first', () {
      const none = SafetyPredicates(
        ruleAllowsAutoFix: false,
        unreachableAcrossAllTargets: false,
        noDynamicBlockers: false,
        notProtected: false,
        noPublicApiRisk: false,
        hasDeterministicInverse: false,
      );

      expect(none.allHold, isFalse);
      expect(none.failedPredicates, hasLength(6));
    });

    test('failure reasons are human-readable, not identifiers', () {
      const blocked = SafetyPredicates(
        ruleAllowsAutoFix: true,
        unreachableAcrossAllTargets: true,
        noDynamicBlockers: false,
        notProtected: true,
        noPublicApiRisk: true,
        hasDeterministicInverse: true,
      );

      // The explanation is the product for a tool that deletes code, so this
      // must read as a sentence rather than a field name.
      expect(
        blocked.failedPredicates.single,
        'an unresolved dynamic construct could match',
      );
    });
  });

  group('finding', () {
    test('a SAFE finding has no whyNotSafe explanation', () {
      final finding = _finding(confidence: Confidence.safe);

      expect(finding.isAutoApplicable, isTrue);
      expect(finding.whyNotSafe, isNull);
    });

    test('a downgraded finding explains which predicate failed', () {
      final finding = _finding(
        confidence: Confidence.review,
        predicates: const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: true,
          noDynamicBlockers: false,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
      );

      expect(finding.isAutoApplicable, isFalse);
      expect(finding.whyNotSafe, contains('unresolved dynamic construct'));
    });

    test('multiple failures are joined into one explanation', () {
      final finding = _finding(
        confidence: Confidence.review,
        predicates: const SafetyPredicates(
          ruleAllowsAutoFix: true,
          unreachableAcrossAllTargets: false,
          noDynamicBlockers: false,
          notProtected: true,
          noPublicApiRisk: true,
          hasDeterministicInverse: true,
        ),
      );

      expect(finding.whyNotSafe, contains(';'));
    });

    test('sourceBytes is optional and carries no binary-size claim', () {
      final finding = Finding(
        ruleId: 'PRN-TEST-002',
        node: _node('asset:app/assets/logo.png'),
        confidence: Confidence.safe,
        title: 'unused asset',
        predicates: _allHold,
        sourceBytes: 384 * 1024,
      );

      expect(finding.sourceBytes, 384 * 1024);
      expect(_finding(confidence: Confidence.safe).sourceBytes, isNull);
    });

    test('toString is scannable in logs', () {
      expect(
        _finding(confidence: Confidence.safe).toString(),
        '[PRN-TEST-001 SAFE] asset:app/assets/logo.png',
      );
    });
  });
}
