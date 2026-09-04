import 'dart:io';

import 'package:flutter_pruner/src/core/confidence/action_readiness_index.dart';
import 'package:flutter_pruner/src/core/confidence/static_action_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('NoOpActionReadinessResolver', () {
    test('returns empty index', () async {
      const resolver = NoOpActionReadinessResolver();
      final graph = ReachabilityGraph();
      final project = _createProject();
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index, equals(ActionReadinessIndex.empty));
      expect(index.isEmpty, isTrue);
      expect(index.length, 0);
    });

    test('const constructor works', () {
      const resolver1 = NoOpActionReadinessResolver();
      const resolver2 = NoOpActionReadinessResolver();
      expect(identical(resolver1, resolver2), isTrue);
    });
  });

  group('StaticActionReadinessResolver interface', () {
    test('can be implemented by custom resolvers', () async {
      final resolver = _FakeResolver();
      final graph = ReachabilityGraph();
      final project = _createProject();
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index.isEmpty, isTrue);
    });
  });
}

ProjectContext _createProject() {
  return ProjectContext(
    root: Directory('/test/project'),
    pubspec: {'name': 'test_package'},
    packageName: 'test_package',
    analysisMode: AnalysisMode.application,
    targetMatrix: TargetMatrix.declared([]),
  );
}

GraphIntegrity _createIntegrity() {
  return GraphIntegrity(
    configuredTargets: const {},
    byExecutionTarget: const {},
    unattributedDanglingEdges: const {},
    unattributedDanglingRootIds: const {},
    auxiliaryRegistryIssues: const [],
  );
}

/// Fake resolver for interface verification.
final class _FakeResolver implements StaticActionReadinessResolver {
  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async =>
      ActionReadinessIndex.empty;
}
