import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_static_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('L10nStaticReadinessResolver', () {
    ProjectContext createProject(AnalysisMode mode) {
      return ProjectContext(
        root: Directory('/test/project'),
        pubspec: {'name': 'test_package'},
        packageName: 'test_package',
        analysisMode: mode,
        targetMatrix: TargetMatrix.declared([]),
      );
    }

    GraphIntegrity createIntegrity() {
      return GraphIntegrity(
        configuredTargets: const {},
        byExecutionTarget: const {},
        unattributedDanglingEdges: const {},
        unattributedDanglingRootIds: const {},
        auxiliaryRegistryIssues: const [],
      );
    }

    ReachabilityGraph createGraph(List<GraphNode> nodes) {
      final graph = ReachabilityGraph();
      for (final node in nodes) {
        graph.addNode(node);
      }
      return graph;
    }

    test('returns empty index for package mode', () async {
      final project = createProject(AnalysisMode.package);
      final graph = createGraph([]);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('returns empty index when no l10n nodes', () async {
      final project = createProject(AnalysisMode.application);
      final graph = createGraph([
        GraphNode(
          id: 'dart:MyClass',
          kind: NodeKind.declaration,
          origin: Uri.parse('package:test/lib.dart'),
        ),
      ]);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('creates entries for l10n nodes in application mode', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:app.key2',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries.length, 2);
      expect(index.containsNode('l10n:app.key1'), isTrue);
      expect(index.containsNode('l10n:app.key2'), isTrue);

      final entry = index['l10n:app.key1']!;
      expect(entry.adapterId, 'l10n');
      expect(entry.nodeKind, NodeKind.localizationKey);
      expect(entry.familyId, 'app');
      expect(entry.hasExternalConsumerExposure, isFalse);
      expect(entry.inverseKind.isDeterministic, isTrue);
    });

    test('sets external exposure in package-internal mode', () async {
      final project = createProject(AnalysisMode.packageInternal);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      final entry = index['l10n:app.key1']!;
      expect(entry.hasExternalConsumerExposure, isTrue);
    });

    test('skips nodes with scoped blockers', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
          metadata: {
            'scopedBlockers': ['someBlocker'],
          },
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('allows externalConsumersNotScanned blocker', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
          metadata: {
            'scopedBlockers': ['externalConsumersNotScanned'],
          },
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries.length, 1);
      expect(index.containsNode('l10n:app.key1'), isTrue);
    });

    test('groups nodes by family', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:app.key2',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:settings.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/settings_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries.length, 3);

      final entry1 = index['l10n:app.key1']!;
      final entry2 = index['l10n:app.key2']!;
      final entry3 = index['l10n:settings.key1']!;

      expect(entry1.familyId, 'app');
      expect(entry2.familyId, 'app');
      expect(entry3.familyId, 'settings');
    });

    test('skips nodes with invalid origins', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:other_package/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('performs bounded static analysis', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      // No Flutter execution, just static graph analysis
      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.entries.length, 1);
    });

    test('mutation footprint contains physical paths', () async {
      final project = createProject(AnalysisMode.application);
      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      final entry = index['l10n:app.key1']!;
      expect(entry.mutationFootprint.physicalPaths, isNotEmpty);
      expect(entry.mutationFootprint.riskScope.isFamily, isTrue);
    });
  });
}

