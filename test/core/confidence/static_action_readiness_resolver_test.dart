import 'dart:io';

import 'package:flutter_pruner/src/core/confidence/action_readiness_index.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/confidence/static_action_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('resolver_test_');
    // Create minimal project structure
    File(p.join(tempDir.path, 'pubspec.yaml')).writeAsStringSync('''
name: test_project
environment:
  sdk: ^3.9.0
''');
    final mainFile = File(p.join(tempDir.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('void main() {}\n');
  });

  tearDown(() {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  group('NoOpActionReadinessResolver', () {
    test('returns empty index', () async {
      final resolver = NoOpActionReadinessResolver();
      final graph = ReachabilityGraph();
      final project = await ProjectContext.load(tempDir);
      final integrity = graph.integrityFor([]);

      final index = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(index, equals(ActionReadinessIndex.empty));
      expect(index.isEmpty, isTrue);
    });

    test('const constructor allows reuse', () {
      final resolver1 = const NoOpActionReadinessResolver();
      final resolver2 = const NoOpActionReadinessResolver();

      expect(identical(resolver1, resolver2), isTrue);
    });
  });

  group('StaticActionReadinessResolver', () {
    test('interface can be implemented', () {
      final resolver = _FakeResolver(ActionReadinessIndex.empty);

      expect(resolver, isA<StaticActionReadinessResolver>());
    });

    test('custom resolver can return entries', () async {
      final index = ActionReadinessIndex({
        'test:node1': _createMockEntry(),
      });
      final resolver = _FakeResolver(index);
      final graph = ReachabilityGraph();
      final project = await ProjectContext.load(tempDir);
      final integrity = graph.integrityFor([]);

      final result = await resolver.resolve(
        graph: graph,
        project: project,
        integrity: integrity,
      );

      expect(result, equals(index));
      expect(result.length, equals(1));
      expect(result.containsNode('test:node1'), isTrue);
    });
  });
}

// Mock helpers

ActionReadinessEntry _createMockEntry() {
  return ActionReadinessEntry(
    adapterId: 'test',
    nodeKind: NodeKind.declaration,
    familyId: 'test_family',
    configurationFingerprint: 'sha256:test',
    mutationFootprint: MutationFootprint(
      findingIds: {'test:node1'},
      physicalPaths: {'lib/test.dart'},
      riskScope: ActionRiskScope.boundedSingle,
    ),
    inverseKind: DeterministicInverseKind.proven,
    riskScope: ActionRiskScope.boundedSingle,
    hasExternalConsumerExposure: false,
  );
}

// Fake resolver for testing
class _FakeResolver implements StaticActionReadinessResolver {
  _FakeResolver(this._index);

  final ActionReadinessIndex _index;

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async =>
      _index;
}
