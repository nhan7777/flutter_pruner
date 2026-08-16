import 'dart:io';

import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

const predicates = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
);

void main() {
  group('RemovalPlanner', () {
    test('orders a consumer dependency chain consumer-first', () {
      final graph = ReachabilityGraph();
      final findings = [_finding('a'), _finding('b'), _finding('c')];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }
      graph
        ..addEdge(_edge('a', 'b'))
        ..addEdge(_edge('b', 'c'));

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
      );

      expect(plan.units.map((unit) => unit.findings.single.node.id), [
        'a',
        'b',
        'c',
      ]);
      expect(plan.blocked, isEmpty);
    });

    test('keeps a dependency cycle in one atomic unit', () {
      final graph = ReachabilityGraph();
      final findings = [_finding('a'), _finding('b')];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }
      graph
        ..addEdge(_edge('a', 'b'))
        ..addEdge(_edge('b', 'a'));

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
      );

      expect(plan.units, hasLength(1));
      expect(plan.units.single.findings.map((finding) => finding.node.id), [
        'a',
        'b',
      ]);
    });

    test('coalesces declarations touching the same physical file', () {
      final graph = ReachabilityGraph();
      final findings = [
        _finding('a', path: '/project/lib/src/shared.dart'),
        _finding('b', path: '/project/lib/src/shared.dart'),
      ];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
      );

      expect(plan.units, hasLength(1));
      expect(plan.units.single.findings, hasLength(2));
    });

    test('retained consumer blocks its target and downstream dependencies', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('retained'))
        ..addNode(_node('a'))
        ..addNode(_node('b'))
        ..addEdge(_edge('retained', 'a'))
        ..addEdge(_edge('a', 'b'));

      final plan = const RemovalPlanner().build(
        findings: [_finding('a'), _finding('b')],
        graph: graph,
        project: _project,
      );

      expect(plan.units, isEmpty);
      expect(plan.blocked.map((item) => item.finding.node.id), ['a', 'b']);
      expect(plan.blocked.first.reason, PlanBlockReason.retainedConsumer);
      expect(
        plan.blocked.last.reason,
        PlanBlockReason.blockedByRetainedDependency,
      );
    });

    test('exact stale import cleanup closes an empty-library boundary', () {
      final empty = _emptyLibraryFinding('empty');
      final graph = ReachabilityGraph()
        ..addNode(_node('importer'))
        ..addNode(empty.node)
        ..addEdge(
          GraphEdge(
            from: 'importer',
            to: 'empty',
            kind: EdgeKind.imports,
            evidence: const Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'import directive',
              exact: true,
            ),
          ),
        );

      final plan = const RemovalPlanner().build(
        findings: [empty],
        graph: graph,
        project: _project,
      );

      expect(plan.units, hasLength(1));
      expect(plan.blocked, isEmpty);
    });

    test('plan order and IDs are stable across finding insertion order', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('b'));
      final forward = const RemovalPlanner().build(
        findings: [_finding('a'), _finding('b')],
        graph: graph,
        project: _project,
      );
      final reverse = const RemovalPlanner().build(
        findings: [_finding('b'), _finding('a')],
        graph: graph,
        project: _project,
      );

      expect(
        reverse.units.map((unit) => unit.id),
        forward.units.map((unit) => unit.id),
      );
      expect(
        reverse.units.map((unit) => unit.findings.single.node.id),
        forward.units.map((unit) => unit.findings.single.node.id),
      );
    });
  });
}

final ProjectContext _project = ProjectContext(
  root: Directory('/project'),
  pubspec: const {},
  packageName: 'app',
  targets: [
    BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    ),
  ],
);

Finding _finding(String id, {String? path}) => Finding(
  ruleId: 'PRN-DART-001',
  node: _node(id, path: path),
  confidence: Confidence.safe,
  title: id,
  predicates: predicates,
  proposedAction: 'Remove declaration',
  reportingAdapterId: 'dart',
);

Finding _emptyLibraryFinding(String id) => Finding(
  ruleId: 'PRN-DART-002',
  node: GraphNode(
    id: id,
    kind: NodeKind.dartLibrary,
    origin: Uri.file('/project/lib/src/$id.dart'),
    metadata: const {'declarationCount': 0, 'directiveCount': 0},
  ),
  confidence: Confidence.safe,
  title: id,
  predicates: predicates,
  proposedAction: 'Remove empty library and stale imports',
  reportingAdapterId: 'dart',
);

GraphNode _node(String id, {String? path}) => GraphNode(
  id: id,
  kind: NodeKind.declaration,
  origin: Uri.file(path ?? '/project/lib/src/$id.dart'),
);

GraphEdge _edge(String from, String to) => GraphEdge(
  from: from,
  to: to,
  kind: EdgeKind.references,
  evidence: const Evidence(
    kind: EvidenceKind.semanticReference,
    producer: 'dart',
    description: 'reference',
    exact: true,
  ),
);
