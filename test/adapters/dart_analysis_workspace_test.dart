import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/asset/asset_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('resolves each library at most once per workspace', () async {
    final root = await Directory.systemTemp.createTemp('dart_workspace_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: workspace_fixture
publish_to: none
environment:
  sdk: ^3.9.0
''');
    final mainFile = File(p.join(root.path, 'lib', 'main.dart'));
    await mainFile.parent.create(recursive: true);
    await mainFile.writeAsString('void main() {}\n');

    final project = await ProjectContext.load(root);
    final workspace = DartAnalysisWorkspace(project);
    final path = workspace.dartFiles.singleWhere(
      (path) => path.endsWith('/lib/main.dart'),
    );

    final first = await workspace.resolveLibrary(path);
    final second = await workspace.resolveLibrary(path);

    expect(identical(first, second), isTrue);
    expect(workspace.resolutionCount, 1);
  });

  test('Dart and asset adapters reuse resolved libraries', () async {
    final project = await ProjectContext.load(
      Directory('test/fixtures/asset_test').absolute,
    );
    final workspace = DartAnalysisWorkspace(project);
    final services = AdapterServices(dartWorkspace: workspace);
    final graph = ReachabilityGraph();

    await const DartAdapter().analyzeWithServices(
      project,
      GraphBuilder(graph, 'dart'),
      services,
    );
    final resolutionsAfterDart = workspace.resolutionCount;
    await const AssetAdapter().analyzeWithServices(
      project,
      GraphBuilder(graph, 'assets'),
      services,
    );

    expect(resolutionsAfterDart, greaterThan(0));
    expect(workspace.resolutionCount, resolutionsAfterDart);
  });
}
