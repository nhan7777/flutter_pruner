import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_static_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/promotion_index.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Integration tests for L10nStaticReadinessResolver Phase C implementation.
///
/// These tests verify the complete pipeline from config loading through
/// ARB inventory to footprint computation.
void main() {
  group('L10nStaticReadinessResolver Integration (Phase C)', () {
    Future<ProjectContext> loadFixture() =>
        ProjectContext.load(Directory(p.absolute('test/fixtures/l10n_test')));

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

    test('complete valid config produces ready families', () async {
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

      // Both nodes should be ready
      expect(index.entries.length, 2);
      expect(index.containsNode('l10n:l10n_test.welcome'), isTrue);
      expect(index.containsNode('l10n:l10n_test.greeting'), isTrue);

      // Verify entries have correct metadata
      final entry = index['l10n:l10n_test.welcome']!;
      expect(entry.adapterId, 'l10n');
      expect(entry.familyId, 'l10n_test');
      expect(entry.nodeKind, NodeKind.localizationKey);
      expect(entry.riskScope.isFamily, isTrue);
      expect(entry.inverseKind.isDeterministic, isTrue);
    });

    test('config fingerprint has correct format', () async {
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
      final fingerprint = entry.configurationFingerprint;

      // Should be sha256:<64-hex-chars>
      expect(fingerprint, startsWith('sha256:'));
      final hash = fingerprint.substring('sha256:'.length);
      expect(hash.length, 64);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(hash), isTrue);
    });

    test('mutation footprint includes all expected files', () async {
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
      final paths = entry.mutationFootprint.physicalPaths;

      // Should include ARB files
      expect(
        paths.any((p) => p.contains('.arb')),
        isTrue,
        reason: 'Should include ARB files',
      );

      // Should include config file
      expect(
        paths.contains('l10n.yaml'),
        isTrue,
        reason: 'Should include l10n.yaml',
      );

      // Should include generated library path
      expect(
        paths.any((p) => p.contains('lib/l10n/') || p.contains('.dart_tool/')),
        isTrue,
        reason: 'Should include generated output paths',
      );

      // Footprint should have family ID
      expect(entry.mutationFootprint.familyId, 'l10n_test');
    });

    test('nodes in same family share mutation footprint', () async {
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

      // All nodes should share the same footprint
      final footprint1 = index['l10n:l10n_test.welcome']!.mutationFootprint;
      final footprint2 = index['l10n:l10n_test.greeting']!.mutationFootprint;
      final footprint3 = index['l10n:l10n_test.cartItem']!.mutationFootprint;

      expect(footprint1, equals(footprint2));
      expect(footprint2, equals(footprint3));
      expect(footprint1.physicalPaths, equals(footprint2.physicalPaths));
      expect(footprint1.familyId, equals(footprint2.familyId));
    });

    test('missing config returns empty index', () async {
      // Create project context without l10n.yaml
      final project = ProjectContext(
        root: Directory('/nonexistent'),
        pubspec: {'name': 'test_package'},
        packageName: 'test_package',
        analysisMode: AnalysisMode.application,
        targetMatrix: TargetMatrix.declared([]),
      );

      final nodes = [
        GraphNode(
          id: 'l10n:app.key1',
          kind: NodeKind.localizationKey,
          origin: Uri.parse('package:test_package/lib/l10n/app_en.arb'),
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

      // Fail-closed: no config means no entries
      expect(index.entries, isEmpty);
    });

    test('package mode returns empty index', () async {
      final project = await loadFixture();
      // Override to package mode
      final packageProject = ProjectContext(
        root: project.root,
        pubspec: project.pubspec,
        packageName: project.packageName,
        analysisMode: AnalysisMode.package,
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
        project: packageProject,
        integrity: integrity,
      );

      // Package mode → scan-only, no actionable mutations
      expect(index.entries, isEmpty);
    });

    test('scoped blocker excludes family', () async {
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
        GraphNode(
          id: 'l10n:l10n_test.greeting',
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

      // Nodes with blockers are excluded
      expect(index.entries, isEmpty);
    });

    test('externalConsumersNotScanned blocker is allowed', () async {
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

      // externalConsumersNotScanned is not a hard blocker
      expect(index.entries.length, 1);
      expect(index.containsNode('l10n:l10n_test.welcome'), isTrue);
    });

    test('package-internal mode sets external exposure flag', () async {
      final project = await loadFixture();
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

    test('application mode does not set external exposure flag', () async {
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
      expect(entry.hasExternalConsumerExposure, isFalse);
    });

    test('footprint risk scope is boundedFamily', () async {
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
      expect(entry.riskScope, ActionRiskScope.boundedFamily);
      expect(entry.mutationFootprint.riskScope, ActionRiskScope.boundedFamily);
      expect(entry.riskScope.isFamily, isTrue);
    });

    test('inverse kind is proven for ARB byte-edit', () async {
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
      expect(entry.inverseKind, DeterministicInverseKind.proven);
      expect(entry.inverseKind.isDeterministic, isTrue);
    });
  });
}
