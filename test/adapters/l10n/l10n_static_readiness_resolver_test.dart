import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_static_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/l10n_test')));

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
      final project = await loadFixture();
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

    test('returns empty index when config is absent', () async {
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

      // Without valid l10n.yaml, resolver returns empty (fail-closed)
      expect(index.entries, isEmpty);
    });

    test('creates entries for l10n nodes in application mode', () async {
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:l10n_test.greeting',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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
      expect(index.containsNode('l10n:l10n_test.welcome'), isTrue);
      expect(index.containsNode('l10n:l10n_test.greeting'), isTrue);

      final entry = index['l10n:l10n_test.welcome']!;
      expect(entry.adapterId, 'l10n');
      expect(entry.nodeKind, NodeKind.localizationKey);
      expect(entry.familyId, 'l10n_test');
      expect(entry.hasExternalConsumerExposure, isFalse);
      expect(entry.inverseKind.isDeterministic, isTrue);
      // Verify config fingerprint is computed
      expect(entry.configurationFingerprint, startsWith('sha256:'));
    });

    test('sets external exposure in package-internal mode', () async {
      final project = await loadFixture();
      // Override analysis mode to package-internal
      final packageInternalProject = ProjectContext(
        root: project.root,
        pubspec: project.pubspec,
        packageName: project.packageName,
        analysisMode: AnalysisMode.packageInternal,
        targetMatrix: project.targetMatrix,
      );

      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
        ),
      ];
      final graph = createGraph(nodes);
      final integrity = createIntegrity();

      const resolver = L10nStaticReadinessResolver();

      final index = await resolver.resolve(
        graph: graph,
        project: packageInternalProject,
        integrity: integrity,
      );

      final entry = index['l10n:l10n_test.welcome']!;
      expect(entry.hasExternalConsumerExposure, isTrue);
    });

    test('skips nodes with scoped blockers', () async {
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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
      expect(index.containsNode('l10n:l10n_test.welcome'), isTrue);
    });

    test('groups nodes by family', () async {
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:l10n_test.greeting',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
        ),
        GraphNode(
          id: 'l10n:l10n_test.cartItem',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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

      // All nodes should have the same family ID
      final families = index.entries.map((e) => e.familyId).toSet();
      expect(families, {'l10n_test'});

      // All nodes should share the same mutation footprint
      final footprints = index.entries.map((e) => e.mutationFootprint).toSet();
      expect(footprints.length, 1);
    });

    test('handles nodes with different package origins', () async {
      final project = await loadFixture();
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

      // Nodes from other packages still create entries if config is valid
      // The path extraction handles cross-package origins gracefully
      expect(index.entries.length, 1);
    });

    test('performs bounded static analysis', () async {
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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
      final project = await loadFixture();
      final nodes = [
        GraphNode(
          id: 'l10n:l10n_test.welcome',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:l10n_test/lib/l10n/app_en.arb'),
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

      final entry = index['l10n:l10n_test.welcome']!;
      expect(entry.mutationFootprint.physicalPaths, isNotEmpty);
      expect(entry.mutationFootprint.riskScope.isFamily, isTrue);

      // Verify footprint includes expected paths
      final paths = entry.mutationFootprint.physicalPaths;
      expect(paths.any((p) => p.contains('.arb')), isTrue); // ARB files
      expect(paths.any((p) => p == 'l10n.yaml'), isTrue); // Config file
    });
  });
}
