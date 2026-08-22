import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

void main() {
  group('public core value objects', () {
    test('GraphNode deep-snapshots JSON-like metadata', () {
      final flags = <Object?>[
        'original',
        <String, Object?>{'enabled': true},
      ];
      final nested = <String, Object?>{'flags': flags};
      final metadata = <String, Object?>{'nested': nested};

      final node = GraphNode(
        id: 'dart:app/lib/canary.dart#canary',
        kind: NodeKind.declaration,
        origin: Uri.file('/project/lib/canary.dart'),
        metadata: metadata,
      );

      flags
        ..clear()
        ..add('mutated');
      nested['late'] = true;
      metadata['late'] = true;

      final frozenNested = node.metadata['nested']! as Map<String, Object?>;
      final frozenFlags = frozenNested['flags']! as List<Object?>;
      expect(node.metadata.keys, ['nested']);
      expect(frozenFlags.first, 'original');
      expect(frozenFlags[1], {'enabled': true});
      expect(() => node.metadata['late'] = true, throwsUnsupportedError);
      expect(() => frozenNested['late'] = true, throwsUnsupportedError);
      expect(() => frozenFlags.add('late'), throwsUnsupportedError);
      expect(
        () => (frozenFlags[1]! as Map<String, Object?>)['enabled'] = false,
        throwsUnsupportedError,
      );
    });

    test('GraphNode rejects non-JSON metadata and cycles', () {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);

      expect(
        () => GraphNode(
          id: 'bad-set',
          kind: NodeKind.declaration,
          origin: Uri.file('/project/lib/bad.dart'),
          metadata: {
            'nested': <String>{'mutable'},
          },
        ),
        throwsArgumentError,
      );
      expect(
        () => GraphNode(
          id: 'bad-key',
          kind: NodeKind.declaration,
          origin: Uri.file('/project/lib/bad.dart'),
          metadata: {
            'nested': <Object?, Object?>{1: 'not-json'},
          },
        ),
        throwsArgumentError,
      );
      expect(
        () => GraphNode(
          id: 'cycle',
          kind: NodeKind.declaration,
          origin: Uri.file('/project/lib/bad.dart'),
          metadata: {'nested': cyclic},
        ),
        throwsArgumentError,
      );
    });

    test('Finding snapshots every collection input and getter', () {
      final evidence = [
        const Evidence(
          kind: EvidenceKind.semanticReference,
          producer: 'dart',
          description: 'original evidence',
        ),
      ];
      final blockers = [Blocker(producer: 'dart', reason: 'original blocker')];
      final protectionReasons = ['original protection'];
      final unreachableIn = ['web', 'android', 'web'];
      final reachableIn = ['ios', 'android', 'ios'];
      final retainedIn = ['web', 'android', 'web'];
      final auxiliaryRetainedIn = ['aux:test:z', 'aux:runtime:a', 'aux:test:z'];
      final classificationReasons = [
        ClassificationReason.incompleteTargetMatrix,
      ];
      final manualRisks = {ManualRisk.externalConsumersNotScanned};
      final finding = Finding(
        ruleId: 'PRN-DART-001',
        node: _node(),
        confidence: Confidence.review,
        title: 'Canary',
        predicates: _predicates(),
        evidence: evidence,
        blockers: blockers,
        protectionReasons: protectionReasons,
        unreachableIn: unreachableIn,
        reachableIn: reachableIn,
        retainedIn: retainedIn,
        auxiliaryRetainedIn: auxiliaryRetainedIn,
        classificationReasons: classificationReasons,
        manualRisks: manualRisks,
      );

      evidence.clear();
      blockers.clear();
      protectionReasons.clear();
      unreachableIn.clear();
      reachableIn.clear();
      retainedIn.clear();
      auxiliaryRetainedIn.clear();
      classificationReasons.clear();
      manualRisks.clear();

      expect(finding.evidence.single.description, 'original evidence');
      expect(finding.blockers.single.reason, 'original blocker');
      expect(finding.protectionReasons, ['original protection']);
      expect(finding.unreachableIn, ['android', 'web']);
      expect(finding.reachableIn, ['android', 'ios']);
      expect(finding.retainedIn, ['android', 'web']);
      expect(finding.auxiliaryRetainedIn, ['aux:runtime:a', 'aux:test:z']);
      expect(finding.classificationReasons, [
        ClassificationReason.incompleteTargetMatrix,
      ]);
      expect(finding.manualRisks, {ManualRisk.externalConsumersNotScanned});
      expect(() => finding.evidence.clear(), throwsUnsupportedError);
      expect(() => finding.blockers.clear(), throwsUnsupportedError);
      expect(() => finding.protectionReasons.clear(), throwsUnsupportedError);
      expect(() => finding.unreachableIn.clear(), throwsUnsupportedError);
      expect(() => finding.reachableIn.clear(), throwsUnsupportedError);
      expect(() => finding.retainedIn.clear(), throwsUnsupportedError);
      expect(() => finding.auxiliaryRetainedIn.clear(), throwsUnsupportedError);
      expect(
        () => finding.classificationReasons.clear(),
        throwsUnsupportedError,
      );
      expect(() => finding.manualRisks.clear(), throwsUnsupportedError);
    });

    test('FindingAssessment snapshots manual risks', () {
      final manualRisks = {ManualRisk.externalConsumersNotScanned};
      final assessment = FindingAssessment(
        node: _node(),
        predicates: _predicates(),
        actionCapability: const ActionCapability(
          supported: true,
          deterministicInverse: true,
          scope: ActionScope.narrow,
        ),
        isProtected: false,
        hasDynamicBlockers: false,
        manualRisks: manualRisks,
      );

      manualRisks.clear();

      expect(assessment.manualRisks, {ManualRisk.externalConsumersNotScanned});
      expect(() => assessment.manualRisks.clear(), throwsUnsupportedError);
    });

    test('PathExclusionSummary snapshots reason counts', () {
      final counts = <String, int>{'directory:build': 2};
      final summary = PathExclusionSummary(policyVersion: 2, byReason: counts);

      counts['directory:build'] = 99;
      counts['late'] = 1;

      expect(summary.byReason, {'directory:build': 2});
      expect(summary.total, 2);
      expect(
        () => summary.byReason['directory:build'] = 3,
        throwsUnsupportedError,
      );
    });

    test('reachability and integrity projections are deeply immutable', () {
      final target = BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      );
      final auxiliary = AuxiliaryExecutionTarget(
        id: 'aux:test:test/main_test.dart:vm',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'VM test',
      );
      final graph = ReachabilityGraph()
        ..addNode(_node())
        ..addRoot(
          _node().id,
          reason: 'configured root',
          condition: BuildCondition.forTarget(target),
        )
        ..addAuxiliaryRoot(
          _node().id,
          reason: 'test root',
          executionTarget: auxiliary,
        )
        ..addEdge(
          GraphEdge(
            from: _node().id,
            to: 'dart:app/lib/missing.dart#missing',
            kind: EdgeKind.references,
            condition: BuildCondition.forAuxiliaryTarget(auxiliary),
            evidence: const Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'test',
              description: 'missing auxiliary endpoint',
              exact: true,
            ),
          ),
        );

      final auxiliaryAnalysis = graph.analyzeAuxiliary();
      final integrity = graph.integrityFor([target]);
      final allReachable = graph.reachableForAll([target]);

      expect(() => graph.reachableFor(target).clear(), throwsUnsupportedError);
      expect(() => allReachable.clear(), throwsUnsupportedError);
      expect(() => allReachable.values.single.clear(), throwsUnsupportedError);
      expect(
        () => graph.unreachableAcrossAll([target]).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => auxiliaryAnalysis.provenByExecutionTarget.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => auxiliaryAnalysis.provenByExecutionTarget.values.single.clear(),
        throwsUnsupportedError,
      );
      expect(() => integrity.byExecutionTarget.clear(), throwsUnsupportedError);
      expect(() => integrity.danglingEdges.clear(), throwsUnsupportedError);
      expect(() => integrity.configuredTargets.clear(), throwsUnsupportedError);
    });

    test('VerificationPolicy snapshots commands and command arguments', () {
      final arguments = ['analyze', '--fatal-infos'];
      final command = VerificationCommand(
        id: 'analyze',
        executable: 'dart',
        arguments: arguments,
      );
      final commands = [command];
      final policy = VerificationPolicy(commands: commands);
      final originalHash = policy.hash;

      arguments
        ..[0] = 'test'
        ..add('--mutated');
      commands.clear();

      expect(policy.commands, hasLength(1));
      expect(policy.commands.single.arguments, ['analyze', '--fatal-infos']);
      expect(
        policy.commands.single.parserKind,
        VerificationOutputParserKind.humanAnalyzer,
      );
      expect(policy.hash, originalHash);
      expect(() => policy.commands.clear(), throwsUnsupportedError);
      expect(
        () => policy.commands.single.arguments.add('--late'),
        throwsUnsupportedError,
      );
      expect(() => policy.requiredStepIds.clear(), throwsUnsupportedError);
      expect(() => policy.requiredParserKinds.clear(), throwsUnsupportedError);
    });
  });
}

GraphNode _node() => GraphNode(
  id: 'dart:app/lib/canary.dart#canary',
  kind: NodeKind.declaration,
  origin: Uri.file('/project/lib/canary.dart'),
);

SafetyPredicates _predicates() => const SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
  notRetained: true,
);
