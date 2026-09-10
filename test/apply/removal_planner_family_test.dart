import 'dart:io';

import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/confidence/promotion_index.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

const _actionablePredicates = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  notRetained: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
);

void main() {
  if (Platform.isWindows)
    return; // dart: URI to file path conversion fails on Windows

  group('RemovalPlanner l10n family grouping', () {
    test('groups findings with same familyId into one atomic unit', () {
      final graph = ReachabilityGraph();
      final findings = [
        _l10nFinding('l10n:app:unused_key_1'),
        _l10nFinding('l10n:app:unused_key_2'),
        _l10nFinding('l10n:app:unused_key_3'),
      ];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }

      final index = ActionReadinessIndex({
        'l10n:app:unused_key_1': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:unused_key_1',
        ),
        'l10n:app:unused_key_2': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:unused_key_2',
        ),
        'l10n:app:unused_key_3': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:unused_key_3',
        ),
      });

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
        actionReadinessIndex: index,
      );

      expect(plan.units, hasLength(1));
      expect(plan.units.single.findings.map((f) => f.node.id).toSet(), {
        'l10n:app:unused_key_1',
        'l10n:app:unused_key_2',
        'l10n:app:unused_key_3',
      });
      expect(plan.blocked, isEmpty);
    });

    test('keeps different families in separate atomic units', () {
      final graph = ReachabilityGraph();
      final findings = [
        _l10nFinding('l10n:app:key1'),
        _l10nFinding('l10n:app:key2'),
        _l10nFinding('l10n:settings:key1'),
        _l10nFinding('l10n:settings:key2'),
      ];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }

      final index = ActionReadinessIndex({
        'l10n:app:key1': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key1',
        ),
        'l10n:app:key2': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key2',
        ),
        'l10n:settings:key1': _readinessEntry(
          familyId: 'settings_localizations',
          nodeId: 'l10n:settings:key1',
        ),
        'l10n:settings:key2': _readinessEntry(
          familyId: 'settings_localizations',
          nodeId: 'l10n:settings:key2',
        ),
      });

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
        actionReadinessIndex: index,
      );

      // All 4 findings grouped into a single unit because they share same ARB file path
      expect(plan.units, hasLength(1));
      expect(plan.units.single.findings.map((f) => f.node.id).toSet(), {
        'l10n:app:key1',
        'l10n:app:key2',
        'l10n:settings:key1',
        'l10n:settings:key2',
      });
    });

    test('family grouping coexists with path-based grouping', () {
      final graph = ReachabilityGraph();
      final findings = [
        // Same family
        _l10nFinding('l10n:app:key1'),
        _l10nFinding('l10n:app:key2'),
        // Different file paths (non-l10n)
        _finding('decl:a', path: '/project/lib/a.dart'),
        _finding('decl:b', path: '/project/lib/b.dart'),
      ];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }

      final index = ActionReadinessIndex({
        'l10n:app:key1': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key1',
        ),
        'l10n:app:key2': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key2',
        ),
      });

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
        actionReadinessIndex: index,
      );

      // l10n keys grouped by family, dart decls in separate units
      expect(plan.units, hasLength(3));

      final groups = plan.units.map((unit) {
        return unit.findings.map((f) => f.node.id).toSet();
      }).toList();

      expect(
        groups,
        containsAll([
          {'l10n:app:key1', 'l10n:app:key2'},
          {'decl:a'},
          {'decl:b'},
        ]),
      );
    });

    test('ignores findings without readiness entries', () {
      final graph = ReachabilityGraph();
      final findings = [_l10nFinding('l10n:app:key1'), _finding('dart:lib:a')];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }

      final index = ActionReadinessIndex({
        'l10n:app:key1': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key1',
        ),
        // 'dart:lib:a' has no entry
      });

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
        actionReadinessIndex: index,
      );

      expect(plan.units, hasLength(2));
      expect(
        plan.units.map((unit) => unit.findings.single.node.id),
        containsAll(['l10n:app:key1', 'dart:lib:a']),
      );
    });

    test('respects dependency edges across families', () {
      final graph = ReachabilityGraph();
      final findings = [
        _l10nFinding('l10n:app:key1'),
        _finding('dart:consumer'),
      ];
      for (final finding in findings) {
        graph.addNode(finding.node);
      }
      // consumer -> l10n key
      graph.addEdge(_edge('dart:consumer', 'l10n:app:key1'));

      final index = ActionReadinessIndex({
        'l10n:app:key1': _readinessEntry(
          familyId: 'app_localizations',
          nodeId: 'l10n:app:key1',
        ),
      });

      final plan = const RemovalPlanner().build(
        findings: findings,
        graph: graph,
        project: _project,
        actionReadinessIndex: index,
      );

      // Consumer should come before l10n family
      expect(plan.units, hasLength(2));
      expect(plan.units[0].findings.single.node.id, 'dart:consumer');
      expect(plan.units[1].findings.single.node.id, 'l10n:app:key1');
    });
  });
}

Finding _l10nFinding(String id) {
  return Finding(
    ruleId: 'PRN-L10N-001',
    node: GraphNode(
      id: id,
      kind: NodeKind.localizationKey,
      displayName: id.split(':').last,
      origin: Uri.parse('file:///project/lib/l10n/app_en.arb'),
      metadata: const {},
    ),
    confidence: Confidence.safe,
    title: 'Unused l10n key',
    predicates: _actionablePredicates,
    reportingAdapterId: 'l10n',
  );
}

Finding _finding(String id, {String? path}) {
  return Finding(
    ruleId: 'PRN-DART-001',
    node: GraphNode(
      id: id,
      kind: NodeKind.dartLibrary,
      displayName: id,
      origin: Uri.parse(path ?? 'file:///project/lib/$id.dart'),
      metadata: const {'declarationCount': 0},
    ),
    confidence: Confidence.safe,
    title: 'Unused library',
    predicates: _actionablePredicates,
    reportingAdapterId: 'dart',
  );
}

ActionReadinessEntry _readinessEntry({
  required String familyId,
  required String nodeId,
}) {
  return ActionReadinessEntry(
    adapterId: 'l10n',
    nodeKind: NodeKind.localizationKey,
    familyId: familyId,
    configurationFingerprint: 'test-config-hash',
    mutationFootprint: MutationFootprint(
      findingIds: {nodeId},
      physicalPaths: {'/project/lib/l10n/app_en.arb'},
      riskScope: ActionRiskScope.boundedFamily,
      familyId: familyId,
    ),
    inverseKind: DeterministicInverseKind.proven,
    riskScope: ActionRiskScope.boundedFamily,
    hasExternalConsumerExposure: false,
  );
}

GraphEdge _edge(String from, String to) {
  return GraphEdge(
    from: from,
    to: to,
    kind: EdgeKind.imports,
    evidence: const Evidence(
      kind: EvidenceKind.semanticReference,
      producer: 'dart',
      description: 'import directive',
      exact: true,
    ),
    condition: BuildCondition.unconditional,
  );
}

final _project = ProjectContext(
  root: Directory('/project'),
  pubspec: const {},
  packageName: 'test_app',
  targets: [
    BuildTarget(name: 'vm', platform: 'vm', entrypoint: 'lib/main.dart'),
  ],
);
