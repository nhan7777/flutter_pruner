import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/asset/asset_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
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
      (path) => p.equals(path, mainFile.absolute.path),
    );

    final first = await workspace.resolveLibrary(path);
    final second = await workspace.resolveLibrary(path);

    expect(identical(first, second), isTrue);
    expect(workspace.resolutionCount, 1);
  });

  test('inventories an imported hidden selected-package library', () async {
    final root = await Directory.systemTemp.createTemp(
      'dart_workspace_hidden_',
    );
    addTearDown(() => root.deleteSync(recursive: true));
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: workspace_fixture
publish_to: none
environment:
  sdk: ^3.9.0
''');
    File(p.join(root.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    File(p.join(root.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'package:workspace_fixture/.env.dart';

void main() => Env.value;
''');
    final hidden = File(p.join(root.path, 'lib', '.env.dart'))
      ..writeAsStringSync('class Env { static const value = 1; }\n');
    final nestedHidden =
        File(p.join(root.path, 'lib', '.private', 'ignored.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('class Ignored {}\n');
    final project = await ProjectContext.load(root);
    final workspace = DartAnalysisWorkspace(project);
    final graph = ReachabilityGraph();

    await const DartAdapter().analyzeWithServices(
      project,
      GraphBuilder(graph, 'dart'),
      AdapterServices(dartWorkspace: workspace),
    );

    expect(workspace.dartFiles, contains(hidden.absolute.path));
    expect(workspace.dartFiles, isNot(contains(nestedHidden.absolute.path)));
    expect(graph.danglingEdges(), isEmpty);
  });

  test('Dart and asset adapters reuse resolved libraries', () async {
    final project = await ProjectContext.load(
      Directory('test/fixtures/asset_test').absolute,
    );
    final workspace = DartAnalysisWorkspace(project);
    final services = AdapterServices(dartWorkspace: workspace);
    final graph = ReachabilityGraph();
    final mainPath = p.join(project.root.path, 'lib', 'main.dart');
    final mainOwner = DartPackageOwnership.discover(project).ownerOf(mainPath);

    expect(
      mainOwner.ownership,
      DartSourceOwnership.selectedPackage,
      reason: mainOwner.reason,
    );

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

  test(
    'bounded external closure snapshot is pass-scoped and immutable',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dart_workspace_closure_test_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: workspace_fixture
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  external_pkg:
    path: nested
''');
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(root.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:external_pkg/external.dart';
export 'package:external_pkg/external.dart';

void main() => externalEntry();
''');
      File(p.join(root.path, 'lib', 'internal.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void branchEntry() {}\n');
      File(p.join(root.path, 'nested', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: external_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
      final conditionalPath = p.join(
        root.path,
        'nested',
        'lib',
        'external.dart',
      );
      File(conditionalPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'safe.dart'
    if (dart.library.html) 'package:workspace_fixture/internal.dart';

void externalEntry() => branchEntry();
''');
      File(p.join(root.path, 'nested', 'lib', 'safe.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void branchEntry() {}\n');
      final project = await ProjectContext.load(root);
      final workspace = DartAnalysisWorkspace(project);
      final graph = ReachabilityGraph();

      expect(
        (await DartAnalysisWorkspace(project).boundedClosureSnapshot()).issues,
        isEmpty,
      );
      await const DartAdapter().analyzeWithServices(
        project,
        GraphBuilder(graph, 'dart'),
        AdapterServices(dartWorkspace: workspace),
      );
      final snapshot = await workspace.boundedClosureSnapshot();

      expect(snapshot.isComplete, isFalse);
      expect(snapshot.issues, hasLength(1));
      expect(
        snapshot.issues.single.kind,
        DartBoundedClosureIssueKind.conditionalDirective,
      );
      expect(
        p.equals(
          snapshot.issues.single.location,
          File(conditionalPath).resolveSymbolicLinksSync(),
        ),
        isTrue,
      );
      expect(snapshot.libraries, hasLength(2));
      expect(() => snapshot.issues.clear(), throwsUnsupportedError);
      expect(() => snapshot.libraries.clear(), throwsUnsupportedError);
    },
  );

  test(
    'resolves an imported selected generated library excluded from analysis',
    () async {
      final fixture = await _createExcludedGeneratedFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final workspace = DartAnalysisWorkspace(fixture.project);

      final result = await workspace.resolveLibrary(fixture.generatedPath);

      expect(result, isA<ResolvedLibraryResult>());
    },
  );

  test('rejects an analyzer-excluded ordinary Dart library', () async {
    final fixture = await _createExcludedPathFixture(
      relativePath: p.join('lib', 'ordinary.dart'),
      analysisExclude: '**/ordinary.dart',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final workspace = DartAnalysisWorkspace(fixture.project);

    expect(workspace.dartFiles, isNot(contains(fixture.path)));
    expect(
      () => workspace.resolveLibrary(fixture.path),
      throwsA(isA<StateError>()),
    );
    expect(workspace.resolutionCount, 0);
  });

  test(
    'rejects an excluded generated library owned by another package',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dart_workspace_external_generated_test_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      _writeSelectedPackage(root, analysisExclude: '**/*.g.dart');
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_fixture","rootUri":"../external/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(root.path, 'external', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: external_fixture
publish_to: none
environment:
  sdk: ^3.9.0
''');
      final externalPath = p.normalize(
        p.absolute(p.join(root.path, 'external', 'lib', 'external.g.dart')),
      );
      File(externalPath)
        ..createSync(recursive: true)
        ..writeAsStringSync('void externalGenerated() {}\n');
      final workspace = DartAnalysisWorkspace(await ProjectContext.load(root));

      expect(workspace.dartFiles, isNot(contains(externalPath)));
      expect(
        () => workspace.resolveLibrary(externalPath),
        throwsA(isA<StateError>()),
      );
      expect(workspace.resolutionCount, 0);
    },
  );

  test('rejects an excluded generated leaf symlink', () async {
    final fixture = await _createExcludedPathFixture(
      relativePath: p.join('lib', 'real.g.dart'),
      analysisExclude: '**/*.g.dart',
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final linkPath = p.join(fixture.root.path, 'lib', 'alias.g.dart');
    Link(linkPath).createSync(fixture.path);
    final workspace = DartAnalysisWorkspace(fixture.project);

    expect(workspace.dartFiles, isNot(contains(linkPath)));
    expect(
      () => workspace.resolveLibrary(linkPath),
      throwsA(isA<StateError>()),
    );
    expect(workspace.resolutionCount, 0);
  });

  test('rejects a generated path excluded as run output', () async {
    final fixture = await _createExcludedPathFixture(
      relativePath: p.join('lib', 'scan-output.g.dart'),
      analysisExclude: '**/*.g.dart',
      excludeAsRunOutput: true,
    );
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final workspace = DartAnalysisWorkspace(fixture.project);

    expect(workspace.dartFiles, isNot(contains(fixture.path)));
    expect(
      () => workspace.resolveLibrary(fixture.path),
      throwsA(isA<StateError>()),
    );
    expect(workspace.resolutionCount, 0);
  });

  test(
    'rejects an excluded generated alias after caching the real path',
    () async {
      final fixture = await _createIntermediateSymlinkFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final workspace = DartAnalysisWorkspace(fixture.project);

      final realResult = await workspace.resolveLibrary(fixture.realPath);

      expect(realResult, isA<ResolvedLibraryResult>());
      expect(workspace.resolutionCount, 1);
      expect(workspace.dartFiles, isNot(contains(fixture.aliasPath)));
      expect(
        () => workspace.resolveLibrary(fixture.aliasPath),
        throwsA(isA<StateError>()),
      );
      expect(workspace.resolutionCount, 1);
    },
  );

  test(
    'rejected generated alias does not poison the real path cache',
    () async {
      final fixture = await _createIntermediateSymlinkFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      final workspace = DartAnalysisWorkspace(fixture.project);

      expect(
        () => workspace.resolveLibrary(fixture.aliasPath),
        throwsA(isA<StateError>()),
      );
      expect(workspace.resolutionCount, 0);

      final realResult = await workspace.resolveLibrary(fixture.realPath);

      expect(realResult, isA<ResolvedLibraryResult>());
      expect(workspace.resolutionCount, 1);
    },
  );

  test(
    'uses the deepest containing context for excluded generated code',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'dart_workspace_nested_context_test_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      _writeSelectedPackage(root);
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"choice","rootUri":"../deps/root_choice/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      _writeChoicePackage(root, p.join('deps', 'root_choice'));
      _writeChoicePackage(root, p.join('deps', 'nested_choice'));
      final nestedRoot = p.join(root.path, 'lib', 'nested_context');
      File(p.join(nestedRoot, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../../../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"choice","rootUri":"../../../deps/nested_choice/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(nestedRoot, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - "**/*.g.dart"
''');
      final generatedPath = p.normalize(
        p.absolute(p.join(nestedRoot, 'selected.g.dart')),
      );
      File(
        generatedPath,
      ).writeAsStringSync("import 'package:choice/choice.dart';\n");
      final workspace = DartAnalysisWorkspace(await ProjectContext.load(root));

      expect(
        workspace.collection.contexts.map(
          (context) => p.normalize(context.contextRoot.root.path),
        ),
        containsAll([p.normalize(root.path), p.normalize(nestedRoot)]),
      );
      final result = await workspace.resolveLibrary(generatedPath);

      expect(result, isA<ResolvedLibraryResult>());
      final importedPaths = (result as ResolvedLibraryResult)
          .element
          .firstFragment
          .importedLibraries
          .map((library) => p.normalize(library.firstFragment.source.fullName));
      expect(
        importedPaths,
        contains(
          p.join(root.path, 'deps', 'nested_choice', 'lib', 'choice.dart'),
        ),
      );
      expect(
        importedPaths,
        isNot(
          contains(
            p.join(root.path, 'deps', 'root_choice', 'lib', 'choice.dart'),
          ),
        ),
      );
    },
  );

  test('keeps excluded selected generated semantics fail-closed', () async {
    final fixture = await _createExcludedGeneratedFixture();
    addTearDown(() => fixture.root.deleteSync(recursive: true));
    final workspace = DartAnalysisWorkspace(fixture.project);
    final graph = ReachabilityGraph();

    await const DartAdapter().analyzeWithServices(
      fixture.project,
      GraphBuilder(graph, 'dart'),
      AdapterServices(dartWorkspace: workspace),
    );

    const generatedId =
        'dart-generated:workspace_fixture/lib/generated_registrar.g.dart';
    final generated = graph.nodes.singleWhere((node) => node.id == generatedId);
    final model = graph.nodes.singleWhere(
      (node) => node.id.endsWith('lib/model.dart#GeneratedModel'),
    );
    final findings = const FindingGenerator().generate(
      graph: graph,
      project: fixture.project,
      graphIntegrity: graph.integrityFor(fixture.project.targets),
      reportingNodeSchemes: const {'dart'},
    );

    expect(workspace.dartFiles, contains(fixture.generatedPath));
    expect(generated.kind, NodeKind.generatedArtifact);
    expect(generated.metadata['generated'], isTrue);
    expect(generated.metadata['removalSupported'], isFalse);
    expect(
      findings.where((finding) => finding.node.id == generatedId),
      isEmpty,
    );
    expect(
      graph.edges,
      contains(
        predicate<GraphEdge>(
          (edge) =>
              edge.from == generatedId &&
              edge.to == model.id &&
              edge.kind == EdgeKind.references &&
              edge.evidence.exact,
        ),
      ),
    );
    expect(
      graph.blockersFor(model.id),
      contains(
        predicate<Blocker>(
          (blocker) =>
              blocker.affectedNodeIds.contains(model.id) &&
              blocker.reason.contains('generated code references'),
        ),
      ),
    );
    expect(
      graph.nodes.map((node) => node.id),
      contains('dart-package:workspace_fixture/external_generated'),
    );
    expect(
      graph.nodes.map((node) => node.id),
      isNot(
        contains('dart-generated:workspace_fixture/nested/lib/external.g.dart'),
      ),
    );
    expect(
      graph.nodes.where(
        (node) => node.origin.path.endsWith('nested/lib/external.g.dart'),
      ),
      isEmpty,
    );
    expect(graph.danglingEdges(), isEmpty);
  });
}

Future<({Directory root, ProjectContext project, String path})>
_createExcludedPathFixture({
  required String relativePath,
  required String analysisExclude,
  bool excludeAsRunOutput = false,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'dart_workspace_excluded_path_test_',
  );
  _writeSelectedPackage(root, analysisExclude: analysisExclude);
  final path = p.normalize(p.absolute(p.join(root.path, relativePath)));
  File(path)
    ..createSync(recursive: true)
    ..writeAsStringSync('void libraryEntry() {}\n');
  return (
    root: root,
    project: await ProjectContext.load(
      root,
      additionalExcludedPaths: excludeAsRunOutput ? [path] : const [],
    ),
    path: path,
  );
}

void _writeSelectedPackage(Directory root, {String? analysisExclude}) {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: workspace_fixture
publish_to: none
environment:
  sdk: ^3.9.0
''');
  File(p.join(root.path, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
  if (analysisExclude != null) {
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - "$analysisExclude"
''');
  }
}

void _writeChoicePackage(Directory root, String relativeRoot) {
  final packageRoot = p.join(root.path, relativeRoot);
  File(p.join(packageRoot, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
name: choice
publish_to: none
environment:
  sdk: ^3.9.0
''');
  File(p.join(packageRoot, 'lib', 'choice.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('class Choice {}\n');
}

Future<
  ({Directory root, ProjectContext project, String realPath, String aliasPath})
>
_createIntermediateSymlinkFixture() async {
  final root = await Directory.systemTemp.createTemp(
    'dart_workspace_intermediate_symlink_test_',
  );
  _writeSelectedPackage(root, analysisExclude: '**/*.g.dart');
  final realPath = p.normalize(
    p.absolute(p.join(root.path, 'lib', 'real', 'selected.g.dart')),
  );
  File(realPath)
    ..createSync(recursive: true)
    ..writeAsStringSync('void generatedEntry() {}\n');
  Link(
    p.join(root.path, 'lib', 'alias'),
  ).createSync(p.join(root.path, 'lib', 'real'));
  return (
    root: root,
    project: await ProjectContext.load(root),
    realPath: realPath,
    aliasPath: p.normalize(
      p.absolute(p.join(root.path, 'lib', 'alias', 'selected.g.dart')),
    ),
  );
}

Future<({Directory root, ProjectContext project, String generatedPath})>
_createExcludedGeneratedFixture() async {
  final root = await Directory.systemTemp.createTemp(
    'dart_workspace_excluded_generated_test_',
  );
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: workspace_fixture
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  external_generated:
    path: nested
''');
  File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - "**/*.g.dart"
''');
  File(p.join(root.path, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"workspace_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_generated","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
  File(p.join(root.path, 'lib', 'main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
import 'generated_registrar.g.dart';
import 'package:external_generated/external.g.dart';

void main() {
  registerGenerated();
  externalGenerated();
}
''');
  File(p.join(root.path, 'lib', 'model.dart')).writeAsStringSync('''
class GeneratedModel {}
''');
  final generatedPath = p.normalize(
    p.absolute(p.join(root.path, 'lib', 'generated_registrar.g.dart')),
  );
  File(generatedPath).writeAsStringSync('''
import 'model.dart';

GeneratedModel registerGenerated() => GeneratedModel();
''');
  File(p.join(root.path, 'nested', 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
name: external_generated
publish_to: none
environment:
  sdk: ^3.9.0
''');
  File(p.join(root.path, 'nested', 'lib', 'external.g.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void externalGenerated() {}\n');
  return (
    root: root,
    project: await ProjectContext.load(root),
    generatedPath: generatedPath,
  );
}
