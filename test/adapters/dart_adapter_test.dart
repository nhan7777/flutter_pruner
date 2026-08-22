import 'dart:io';

import 'package:crypto/crypto.dart';

import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:flutter_pruner/src/adapters/dart/analyzer_diagnostic_collector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_application_reachability.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_ids.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/apply/mode_apply_policy.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _g1FixtureSha256 = <String, String>{
  '.dart_tool/package_config.json':
      'e9f15dcd9d9ffccbb67e6b658fbacc0064dd7cba4a18b8f4591fa47e3863fe7b',
  'analysis_options.yaml':
      '234d28a1bad873cd9d07002238e77078b49bfe72f6e3af809c3777b372d065bf',
  'dart_test.yaml':
      '3d3e8d39d13413bf92869f7ee53e710c6a61764882eb493859caa9daf8313f69',
  'flutter_pruner.yaml':
      '9fb6e8dd83fd7d43f926f8da2ca6aaf01fce6471ff5507952eb690e94b9d4aa2',
  'lib/conditional.dart':
      '43c3ae18797d573082ddcef6923a73b8e729a6d290bd8832509c3d51be4262c4',
  'lib/conditional_io.dart':
      '3d90a98ffb3990ab0e690d90bab16bf44f83016f9a6d60c53e211a8d06b8cac0',
  'lib/conditional_web.dart':
      '3d90a98ffb3990ab0e690d90bab16bf44f83016f9a6d60c53e211a8d06b8cac0',
  'lib/generated_model.dart':
      'a129d9f951805d279c517c65a82cbee3cba441584e23355f89e829ff42895cd8',
  'lib/generated_registrar.g.dart':
      '576d0058ca731f2ac9e086c7ec1f16e1662bd16e30866f761530dc85f7742f3a',
  'lib/main.dart':
      'b3a9a4c1d0bac77aeb252daecc04e0c3e127b83bdc4afc08fa5dd5239486a1d4',
  'lib/reachable_empty.dart':
      '01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b',
  'nested/.dart_tool/package_config.json':
      'a11308c056c67fa55366752eb5c5597d365c14fd6c56e7191a918849a617883f',
  'nested/lib/nested_api.dart':
      'b385a915684e0b18e6292d25596ad192546bd82a15408579510c29fc65a3db4f',
  'nested/pubspec.yaml':
      '11bc0d4990bd6ad58140634a0a2b8dd4c49062da25d09e5cf7cdd4f10ccdb954',
  'pubspec.yaml':
      '5c6403e976894ee896a09fb8011aa75aae9bd63e522ddb6b26183da156d9313a',
  'test/support_test.dart':
      'fcbb53819006ae445c1c52044f46f2fecf833816dd529356c3874510f2529d51',
};

void main() {
  late Directory tempDir;
  late ProjectContext project;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('dart_adapter_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  });

  Future<void> createProject(Map<String, String> files) async {
    for (final entry in files.entries) {
      final file = File('${tempDir.path}/${entry.key}');
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(entry.value);
    }

    final packageConfig = File(
      p.join(tempDir.path, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfig.existsSync()) {
      packageConfig
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    }

    project = await ProjectContext.load(tempDir);
  }

  Future<({ReachabilityGraph graph, List<Finding> findings})>
  analyzeDeclaredCompleteApplication({
    String entrypoint = 'lib/main.dart',
  }) async {
    project = ProjectContext(
      root: tempDir,
      pubspec: const {'name': 'test_app'},
      packageName: 'test_app',
      targets: [
        BuildTarget(
          name: 'production',
          platform: 'android',
          entrypoint: entrypoint,
        ),
      ],
    );
    final graph = ReachabilityGraph();
    await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
    return (
      graph: graph,
      findings: const FindingGenerator().generate(
        graph: graph,
        project: project,
        graphIntegrity: graph.integrityFor(project.targets),
        reportingNodeSchemes: const {'dart'},
      ),
    );
  }

  void expectNoConditionalDirectiveBlocker(
    ReachabilityGraph graph, {
    required String pathSuffix,
  }) {
    final blockers = graph.blockers
        .where(
          (blocker) =>
              blocker.location != null &&
              p
                  .normalize(blocker.location!)
                  .endsWith(p.normalize(pathSuffix)) &&
              (blocker.reason.contains('Dart directive') ||
                  blocker.reason.contains('Dart imports/exports')),
        )
        .toList();
    expect(
      blockers,
      isEmpty,
      reason: 'a fully resolved context must not retain a blanket blocker',
    );
  }

  test('G1 fixture exists before freezing ServerBox graph disagreements', () {
    final fixture = Directory(
      p.absolute('test/fixtures/dart_graph_correctness_test'),
    );

    expect(fixture.existsSync(), isTrue);
  });

  group('G1 ServerBox graph disagreement characterization', () {
    const fixturePackage = 'dart_graph_correctness_test';

    String fixtureId(String path, [String? declaration]) =>
        'dart:$fixturePackage/$path${declaration == null ? '' : '#$declaration'}';

    Future<
      ({
        ProjectContext project,
        ReachabilityGraph graph,
        List<Finding> findings,
      })
    >
    analyzeFixture() async {
      final fixture = Directory(
        p.absolute('test/fixtures/dart_graph_correctness_test'),
      );
      final fixtureProject = await ProjectContext.load(fixture);
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(
        fixtureProject,
        GraphBuilder(graph, 'dart'),
      );
      return (
        project: fixtureProject,
        graph: graph,
        findings: const FindingGenerator().generate(
          graph: graph,
          project: fixtureProject,
          graphIntegrity: graph.integrityFor(fixtureProject.targets),
          reportingNodeSchemes: const {'dart'},
        ),
      );
    }

    test(
      'fixture target tuples and package-config inventory are exact',
      () async {
        final fixture = Directory(
          p.absolute('test/fixtures/dart_graph_correctness_test'),
        );
        final result = await analyzeFixture();
        final targets = {
          for (final target in result.project.targets) target.name: target,
        };

        expect(targets.keys, {'web', 'android-debug', 'android-release'});
        expect(targets['web']!.platform, 'web');
        expect(targets['web']!.flavor, isNull);
        expect(targets['web']!.entrypoint, 'lib/main.dart');
        expect(targets['web']!.dartDefines, isEmpty);
        expect(targets['android-debug']!.platform, 'android');
        expect(targets['android-debug']!.flavor, 'debug');
        expect(targets['android-debug']!.entrypoint, 'lib/main.dart');
        expect(targets['android-debug']!.dartDefines, {'MODE': 'debug'});
        expect(targets['android-release']!.platform, 'android');
        expect(targets['android-release']!.flavor, 'release');
        expect(targets['android-release']!.entrypoint, 'lib/main.dart');
        expect(targets['android-release']!.dartDefines, {'MODE': 'release'});

        final inventory = <String, String>{
          for (final file
              in fixture
                  .listSync(recursive: true, followLinks: false)
                  .whereType<File>())
            p.relative(file.path, from: fixture.path).replaceAll(r'\', '/'):
                sha256.convert(file.readAsBytesSync()).toString(),
        };
        expect(inventory, _g1FixtureSha256);
      },
    );

    test('web target follows only its exact conditional branch', () async {
      final result = await analyzeFixture();
      final web = result.project.targets.singleWhere(
        (target) => target.name == 'web',
      );
      final ioBranch = result.graph.nodes.singleWhere(
        (node) => node.id == fixtureId('lib/conditional_io.dart'),
      );
      final webBranch = result.graph.nodes.singleWhere(
        (node) => node.id == fixtureId('lib/conditional_web.dart'),
      );

      expect(
        result.graph.configuredProvenFor(web),
        isNot(contains(ioBranch.id)),
      );
      expect(result.graph.configuredProvenFor(web), contains(webBranch.id));
    });

    test(
      'explicit VM test root stays outside configured application closure',
      () async {
        final result = await analyzeFixture();
        final web = result.project.targets.singleWhere(
          (target) => target.name == 'web',
        );
        final testLibrary = result.graph.nodes.singleWhere(
          (node) => node.id == fixtureId('test/support_test.dart'),
        );

        expect(
          result.graph.configuredProvenFor(web),
          isNot(contains(testLibrary.id)),
        );
        expect(result.graph.auxiliaryProven(), contains(testLibrary.id));
      },
    );

    test(
      'generated standalone library is reached while source use stays retained',
      () async {
        final result = await analyzeFixture();
        final web = result.project.targets.singleWhere(
          (target) => target.name == 'web',
        );
        final model = result.graph.nodes.singleWhere(
          (node) =>
              node.id ==
              fixtureId('lib/generated_model.dart', 'GeneratedModel'),
        );
        const registrarId =
            'dart-generated:$fixturePackage/lib/generated_registrar.g.dart';
        final modelLibraryId = fixtureId('lib/generated_model.dart');

        final registrar = result.graph.nodes.singleWhere(
          (node) => node.id == registrarId,
        );
        expect(registrar.kind, NodeKind.generatedArtifact);
        expect(result.graph.isProtected(registrarId), isFalse);
        expect(result.graph.configuredProvenFor(web), contains(registrarId));
        expect(result.graph.configuredProvenFor(web), contains(modelLibraryId));
        expect(result.graph.reachableFor(web), contains(model.id));
        expect(result.graph.retainedFor(web), contains(model.id));
      },
    );

    test('reachable empty export is a fully resolved graph node', () async {
      final result = await analyzeFixture();
      final web = result.project.targets.singleWhere(
        (target) => target.name == 'web',
      );
      final emptyLibrary = result.graph.nodes.singleWhere(
        (node) => node.id == fixtureId('lib/reachable_empty.dart'),
      );

      expect(result.graph.reachableFor(web), contains(emptyLibrary.id));
      expect(
        result.findings.map((finding) => finding.node.id),
        isNot(contains(emptyLibrary.id)),
      );
      expect(result.graph.danglingEdges(), isEmpty);
      expect(result.graph.danglingRootIdsFor(result.project.targets), isEmpty);
    });

    test(
      'G5 excludes nested package candidates behind a package boundary',
      () async {
        final result = await analyzeFixture();
        const boundaryId =
            'dart-package:dart_graph_correctness_test/nested_fixture';

        expect(
          result.graph.nodes.map((node) => node.id),
          isNot(contains(fixtureId('nested/lib/nested_api.dart'))),
        );
        expect(
          result.graph.nodes.map((node) => node.id),
          isNot(contains(fixtureId('nested/lib/nested_api.dart', 'nestedApi'))),
        );
        expect(
          result.graph.nodes.where(
            (node) => node.origin.path.contains('/nested/lib/'),
          ),
          isEmpty,
        );
        expect(
          result.graph.nodes,
          contains(
            predicate<GraphNode>(
              (node) => node.id == boundaryId && node.kind == NodeKind.package,
            ),
          ),
        );
        expect(
          result.graph.edges,
          contains(
            predicate<GraphEdge>(
              (edge) =>
                  edge.kind == EdgeKind.imports &&
                  edge.from == fixtureId('lib/main.dart') &&
                  edge.to == boundaryId,
            ),
          ),
        );
        expect(result.graph.danglingEdges(), isEmpty);
        expect(
          result.graph.danglingRootIdsFor(result.project.targets),
          isEmpty,
        );
        expect(
          result.findings.where(
            (finding) =>
                finding.node.id.startsWith('dart:$fixturePackage/nested/'),
          ),
          isEmpty,
        );
        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          isNot(contains(contains('could not resolve'))),
        );
        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          isNot(contains('analyzer returned an unresolved semantic reference')),
        );
        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          isNot(contains(contains('ownership boundary is unknown'))),
        );
      },
    );

    test('G5 nested package analyzes independently with stable IDs', () async {
      final nestedRoot = Directory(
        p.absolute('test/fixtures/dart_graph_correctness_test/nested'),
      );
      final nestedProject = await ProjectContext.load(nestedRoot);
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(
        nestedProject,
        GraphBuilder(graph, 'dart'),
      );

      expect(
        graph.nodes.map((node) => node.id),
        containsAll({
          'dart:nested_fixture/lib/nested_api.dart',
          'dart:nested_fixture/lib/nested_api.dart#nestedApi',
        }),
      );
      expect(
        graph.nodes.map((node) => node.id),
        isNot(contains(startsWith('dart:dart_graph_correctness_test/'))),
      );
      expect(graph.danglingEdges(), isEmpty);
      expect(graph.danglingRootIdsFor(nestedProject.targets), isEmpty);
    });
  });

  group('DartAdapter', () {
    test('starts CLI diagnostics before semantic graph construction', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': 'void main() {}',
      });

      final graph = ReachabilityGraph();
      final adapter = DartAdapter(
        collectAnalyzerDiagnostics: (project) async {
          expect(graph.nodeCount, 0);
          return const AnalyzerDiagnosticCollection.skipped();
        },
      );

      await adapter.analyze(project, GraphBuilder(graph, 'dart'));

      expect(graph.nodeCount, greaterThan(0));
    });

    test(
      'shared reachability snapshot is the sole root and directive projection',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'src/default.dart'
    if (dart.library.io == 'true') 'src/io.dart'
    if (dart.library.html == 'true') 'src/web.dart';

void main() => activeValue();
''',
          'lib/src/default.dart': 'void activeValue() {}\n',
          'lib/src/io.dart': 'void activeValue() {}\n',
          'lib/src/web.dart': 'void activeValue() {}\n',
          'dart_test.yaml': 'platforms: [vm]\n',
          'test/smoke_test.dart': '''
import '../lib/src/default.dart';

void main() => activeValue();
''',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final workspace = DartAnalysisWorkspace(project);
        final contexts = await DefaultDartExecutionContextService(
          workspace: workspace,
        ).resolve(project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        ).resolve(project);
        final applicationReachability =
            DartApplicationReachability.fromSnapshot(snapshot);
        final fixedReachability = _FixedReachabilityService(snapshot);
        final throwingContexts = _ThrowingExecutionContextService();
        final resolutionCount = workspace.resolutionCount;
        final graph = ReachabilityGraph();

        await DartAdapter(
          collectAnalyzerDiagnostics: (_) async =>
              const AnalyzerDiagnosticCollection.skipped(),
        ).analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          AdapterServices(
            dartWorkspace: workspace,
            dartExecutionContextService: throwingContexts,
            dartExecutionReachabilityService: fixedReachability,
          ),
        );

        expect(fixedReachability.resolveCalls, 1);
        expect(identical(fixedReachability.resolvedSnapshot, snapshot), isTrue);
        expect(applicationReachability.unitPaths, {
          for (final paths in snapshot.configuredProvenUnitPaths.values)
            ...paths,
        });
        expect(applicationReachability.globalUsageUnitPaths, {
          for (final paths in snapshot.configuredRetainedUnitPaths.values)
            ...paths,
          for (final paths in snapshot.auxiliaryRetainedUnitPaths.values)
            ...paths,
        });
        final ownership = DartPackageOwnership.discover(project);
        final allFacadePaths = <String>{
          ...applicationReachability.unitPaths,
          ...applicationReachability.globalUsageUnitPaths,
          for (final paths
              in applicationReachability.configuredProvenUnitPaths.values)
            ...paths,
          for (final paths
              in applicationReachability.configuredRetainedUnitPaths.values)
            ...paths,
          for (final paths
              in applicationReachability.auxiliaryProvenUnitPaths.values)
            ...paths,
          for (final paths
              in applicationReachability.auxiliaryRetainedUnitPaths.values)
            ...paths,
        };
        expect(
          allFacadePaths.map((path) => ownership.ownerOf(path).ownership),
          everyElement(DartSourceOwnership.selectedPackage),
        );
        expect(
          () => applicationReachability.configuredProvenUnitPaths.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => applicationReachability.configuredRetainedUnitPaths.values.first
              .clear(),
          throwsUnsupportedError,
        );
        expect(
          () => applicationReachability.auxiliaryProvenUnitPaths.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => applicationReachability.auxiliaryRetainedUnitPaths.values.first
              .clear(),
          throwsUnsupportedError,
        );
        expect(
          () => applicationReachability.unitPaths.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => applicationReachability.globalUsageUnitPaths.clear(),
          throwsUnsupportedError,
        );
        expect(throwingContexts.resolveCalls, 0);
        expect(workspace.resolutionCount, resolutionCount);
        expect(
          graph.rootRecords.map(_graphRootFingerprint).toSet(),
          snapshot.contexts.roots.map(_snapshotRootFingerprint).toSet(),
        );
        final projectedDirectiveEdges = graph.edges
            .where(
              (edge) =>
                  edge.evidence.description ==
                  'execution-context import directive',
            )
            .toList();
        expect(
          projectedDirectiveEdges,
          hasLength(snapshot.directives.edges.length),
        );
        expect(
          projectedDirectiveEdges.every(
            (edge) =>
                graph.hasNode(edge.from) &&
                graph.hasNode(edge.to) &&
                snapshot.directives.edges.any(
                  (fact) =>
                      fact.condition == edge.condition &&
                      fact.exact == edge.evidence.exact,
                ),
          ),
          isTrue,
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test(
      'conditional imports and exports stay exact for a complete target',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'src/default.dart' if (dart.library.io) 'src/io.dart';
export 'src/export_default.dart' if (dart.library.html) 'src/export_web.dart';

void main() => activeValue();
''',
          'lib/src/default.dart': 'void activeValue() {}\n',
          'lib/src/io.dart': 'void activeValue() {}\n',
          'lib/src/export_default.dart': 'class DefaultExport {}\n',
          'lib/src/export_web.dart': 'class WebExport {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expect(project.analysisCoverageComplete, isTrue);
        expectNoConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/main.dart',
        );
        expect(candidate.confidence, Confidence.safe);
        expect(candidate.proposedAction, isNotNull);
      },
    );

    test(
      'conditional export in an unreachable library is resolved per target',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': 'void main() {}\n',
          'lib/src/conditional_export.dart': '''
export 'default.dart' if (dart.library.html) 'web.dart';
''',
          'lib/src/default.dart': 'class DefaultExport {}\n',
          'lib/src/web.dart': 'class WebExport {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expectNoConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/src/conditional_export.dart',
        );
        expect(candidate.confidence, Confidence.safe);
        expect(candidate.proposedAction, isNotNull);
      },
    );

    test(
      'conditional directive in an invalid part remains fail closed',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'feature_part.dart';

void main() {}
''',
          'lib/feature_part.dart': '''
part of 'main.dart';

import 'src/default.dart' if (dart.library.io) 'src/io.dart';
''',
          'lib/src/default.dart': 'void activeValue() {}\n',
          'lib/src/io.dart': 'void activeValue() {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expectNoConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/feature_part.dart',
        );
        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          contains('analyzer could not fully resolve this Dart unit'),
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional directive in an invalid generated part remains fail closed',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'model.g.dart';

void main() {}
''',
          'lib/model.g.dart': '''
part of 'main.dart';

export 'src/default.dart' if (dart.library.io) 'src/io.dart';
''',
          'lib/src/default.dart': 'class DefaultExport {}\n',
          'lib/src/io.dart': 'class IoExport {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expectNoConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/model.g.dart',
        );
        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          contains('analyzer could not fully resolve a generated Dart library'),
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional directive in an outside-lib entrypoint resolves exactly',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'tool/main.dart': '''
import '../lib/src/default.dart' if (dart.library.io) '../lib/src/io.dart';

void main() => activeValue();
''',
          'lib/src/default.dart': 'void activeValue() {}\n',
          'lib/src/io.dart': 'void activeValue() {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication(
          entrypoint: 'tool/main.dart',
        );
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expectNoConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'tool/main.dart',
        );
        expect(candidate.confidence, Confidence.safe);
        expect(candidate.proposedAction, isNotNull);
      },
    );

    test(
      'ordinary imports retain SAFE candidates under declared-complete coverage',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'src/used.dart';

void main() => activeValue();
''',
          'lib/src/used.dart': 'void activeValue() {}\n',
          'lib/src/unused.dart': 'void removeMe() {}\n',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final candidate = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('unused.dart#removeMe'),
        );

        expect(
          result.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            contains(
              'conditional Dart imports/exports are not modelled per target',
            ),
          ),
        );
        expect(
          candidate.confidence,
          Confidence.safe,
          reason:
              'whyNotSafe=${candidate.whyNotSafe}; '
              'blockers=${candidate.blockers.map((blocker) => blocker.reason).toList()}; '
              'retainedIn=${candidate.retainedIn}; '
              'auxiliaryRetainedIn=${candidate.auxiliaryRetainedIn}; '
              'danglingEdges=${result.graph.danglingEdges()}; '
              'danglingRoots=${result.graph.danglingRootIdsFor(project.targets)}',
        );
        expect(candidate.proposedAction, isNotNull);
      },
    );

    test('reports unreachable top-level function', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {
  print('hello');
}
''',
        'lib/unused.dart': '''
void unusedFunction() {
  print('never called');
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final nodes = graph.nodes;
      final unusedNode = nodes.firstWhere(
        (GraphNode n) => n.id.contains('unused.dart#unusedFunction'),
      );

      expect(unusedNode.kind, NodeKind.declaration);

      final target = project.targets.first;
      final reachable = graph.reachableFor(target);
      expect(reachable.contains(unusedNode.id), isFalse);
      expect(
        graph.danglingEdges(),
        isEmpty,
        reason: 'SDK imports and references are outside the project graph',
      );
    });

    test('does not report main()', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {
  print('hello');
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final mainNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('main.dart#main'),
      );

      final target = project.targets.first;
      final reachable = graph.reachableFor(target);
      expect(reachable.contains(mainNode.id), isTrue);
    });

    test(
      'configured roots preserve flavor and define tuple identity',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android-debug
      platform: android
      flavor: debug
      entrypoint: lib/main.dart
      dart_defines:
        MODE: debug
''',
          'lib/main.dart': 'void main() {}',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        final main = graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/main.dart#main'),
        );
        final undeclaredRelease = BuildTarget(
          name: 'android-release',
          platform: 'android',
          flavor: 'release',
          entrypoint: 'lib/main.dart',
          dartDefines: const {'MODE': 'release'},
        );

        expect(graph.reachableFor(project.targets.single), contains(main.id));
        expect(graph.reachableFor(undeclaredRelease), isNot(contains(main.id)));
      },
    );

    test('test main is an unconditional test-runner root', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': 'void main() {}\n',
        'test/widget_test.dart': '''
void main() {
  testHelper();
}

void testHelper() {}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      final helper = graph.nodes.singleWhere(
        (node) => node.id.endsWith('test/widget_test.dart#testHelper'),
      );
      final unrelatedTarget = BuildTarget(
        name: 'production',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      );

      expect(graph.reachableFor(unrelatedTarget), contains(helper.id));
    });

    test('does not report @pragma(\'vm:entry-point\')', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/native.dart': '''
@pragma('vm:entry-point')
void nativeCallback() {
  print('called from native');
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final callbackNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('native.dart#nativeCallback'),
      );

      expect(graph.rootIds.any((String r) => r == callbackNode.id), isTrue);
    });

    test(
      'retains background callbacks across native callback boundaries',
      () async {
        final fixtureDir = Directory(
          p.absolute('test/fixtures/callback_safety_test'),
        );
        final callbackProject = await ProjectContext.load(fixtureDir);
        final callbackOwner = DartPackageOwnership.discover(
          callbackProject,
        ).ownerOf(p.join(fixtureDir.path, 'lib', 'main.dart'));
        expect(
          callbackOwner.ownership,
          DartSourceOwnership.selectedPackage,
          reason: callbackOwner.reason,
        );
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(
          callbackProject,
          GraphBuilder(graph, 'dart'),
        );

        GraphNode declaration(String suffix) => graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/main.dart#$suffix'),
        );

        final reachable = graph.reachableFor(callbackProject.targets.single);
        expect(
          reachable,
          containsAll([
            declaration('workmanagerCallback').id,
            declaration('isolateCallback').id,
            declaration('helperCallback').id,
            declaration('persistedCallback').id,
            declaration('BackgroundCallbacks').id,
          ]),
        );
        expect(
          graph.rootIds,
          containsAll([
            declaration('workmanagerCallback').id,
            declaration('isolateCallback').id,
            declaration('helperCallback').id,
            declaration('persistedCallback').id,
            declaration('BackgroundCallbacks').id,
          ]),
          reason:
              'callback handles cross an opaque native and persisted boundary',
        );
        expect(
          graph.blockers.map((blocker) => blocker.reason),
          contains(
            contains(
              'callback target is incomplete for same-named Workmanager.initialize',
            ),
          ),
          reason:
              'a project-local same-named API is not a reviewed runtime boundary',
        );

        final unresolvedCandidate = declaration('UnresolvedCallbackCandidate');
        expect(
          graph
              .blockersFor(unresolvedCandidate.id)
              .map((blocker) => blocker.reason),
          contains(contains('callback-target-incomplete')),
        );
        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: callbackProject,
              graphIntegrity: graph.integrityFor(callbackProject.targets),
            )
            .singleWhere(
              (finding) => finding.node.id == unresolvedCandidate.id,
            );
        expect(finding.confidence, Confidence.review);
      },
    );

    test('treats pragma entry-point variables and fields as roots', () async {
      final fixtureDir = Directory(
        p.absolute('test/fixtures/callback_safety_test'),
      );
      final callbackProject = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(
        callbackProject,
        GraphBuilder(graph, 'dart'),
      );

      final topLevelToken = graph.nodes.singleWhere(
        (node) => node.id.endsWith('lib/main.dart#nativeTopLevelToken'),
      );
      final nativeFields = graph.nodes.singleWhere(
        (node) => node.id.endsWith('lib/main.dart#NativeFields'),
      );
      expect(graph.rootIds, containsAll([topLevelToken.id, nativeFields.id]));
    });

    test(
      'normalizes annotated methods and constructors to owning classes',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/native.dart': '''
class MethodBridge {
  @pragma('vm:entry-point')
  void callback() => methodHelper();
}

class ConstructorBridge {
  @pragma('vm:entry-point')
  ConstructorBridge() {
    constructorHelper();
  }
}

void methodHelper() {}
void constructorHelper() {}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final methodBridge = graph.nodes.singleWhere(
          (node) => node.id.endsWith('native.dart#MethodBridge'),
        );
        final constructorBridge = graph.nodes.singleWhere(
          (node) => node.id.endsWith('native.dart#ConstructorBridge'),
        );
        final methodHelper = graph.nodes.singleWhere(
          (node) => node.id.endsWith('native.dart#methodHelper'),
        );
        final constructorHelper = graph.nodes.singleWhere(
          (node) => node.id.endsWith('native.dart#constructorHelper'),
        );
        final reachable = graph.reachableFor(project.targets.single);

        expect(
          graph.rootIds,
          containsAll([methodBridge.id, constructorBridge.id]),
        );
        expect(graph.rootIds.where((id) => id.endsWith('#callback')), isEmpty);
        expect(reachable, containsAll([methodHelper.id, constructorHelper.id]));
        expect(graph.rootIds.every(graph.hasNode), isTrue);
      },
    );

    test('reports unreachable class', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/unused.dart': '''
class UnusedClass {
  void method() {}
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final unusedNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('unused.dart#UnusedClass'),
      );

      final target = project.targets.first;
      final reachable = graph.reachableFor(target);
      expect(reachable.contains(unusedNode.id), isFalse);
    });

    test('follows cross-file references', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
import 'helper.dart';

void main() {
  helperFunction();
}
''',
        'lib/helper.dart': '''
void helperFunction() {
  print('helper');
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final helperNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('helper.dart#helperFunction'),
      );

      final target = project.targets.first;
      final reachable = graph.reachableFor(target);
      expect(reachable.contains(helperNode.id), isTrue);
    });

    test('follows references between declarations in the same file', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {
  runApp();
}

void runApp() {
  final app = MyApp();
  print(app);
}

class MyApp {}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final reachable = graph.reachableFor(project.targets.first);
      final runApp = graph.nodes.firstWhere(
        (node) => node.id.endsWith('main.dart#runApp'),
      );
      final myApp = graph.nodes.firstWhere(
        (node) => node.id.endsWith('main.dart#MyApp'),
      );

      expect(reachable, contains(runApp.id));
      expect(reachable, contains(myApp.id));
    });

    test(
      'follows static type references from reachable declarations',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
void main() {
  print(Api().convert(const Input()));
}

class Api extends BaseApi {
  Result<Input> convert(Input value) => Result(value);
}

class BaseApi {}
class Input {
  const Input();
}
class Result<T> {
  const Result(this.value);
  final T value;
}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final reachable = graph.reachableFor(project.targets.first);
        for (final name in ['Api', 'BaseApi', 'Input', 'Result']) {
          final node = graph.nodes.firstWhere(
            (candidate) => candidate.id.endsWith('main.dart#$name'),
          );
          expect(reachable, contains(node.id), reason: '$name must stay alive');
        }
      },
    );

    test(
      'generated part references block independent declaration removal',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': 'void main() {}',
          'lib/model.dart': '''
part 'model.g.dart';

class GeneratedModel {
  GeneratedModel(this.id);
  final int id;
}
''',
          'lib/model.g.dart': '''
part of 'model.dart';

GeneratedModel generatedModelFromJson(Map<String, dynamic> json) =>
    GeneratedModel(json['id'] as int);
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final model = graph.nodes.firstWhere(
          (candidate) => candidate.id.endsWith('model.dart#GeneratedModel'),
        );
        final modelLibrary = graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('lib/model.dart'),
        );
        expect(
          graph.blockersFor(model.id),
          isNotEmpty,
          reason:
              'generated code would fail if its source declaration vanished',
        );
        expect(
          graph.edges,
          contains(
            predicate<GraphEdge>(
              (edge) =>
                  edge.from == modelLibrary.id &&
                  edge.to == model.id &&
                  edge.kind == EdgeKind.references &&
                  edge.evidence.exact,
            ),
          ),
          reason: 'a generated part uses its owning library as the caller',
        );
        expect(
          graph.nodes.where(
            (node) =>
                node.kind == NodeKind.generatedArtifact &&
                node.origin.path.endsWith('lib/model.g.dart'),
          ),
          isEmpty,
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test(
      'G7 imported standalone generated library has exact graph identity',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'router.g.dart';

void main() => createGeneratedModel();
''',
          'lib/generated_exports.dart': "export 'router.g.dart';",
          'lib/model.dart': 'class GeneratedModel {}',
          'lib/router.g.dart': '''
import 'model.dart';

GeneratedModel createGeneratedModel() => GeneratedModel();
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final model = graph.nodes.firstWhere(
          (candidate) => candidate.id.endsWith('model.dart#GeneratedModel'),
        );
        final mainLibrary = graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/main.dart'),
        );
        final exportLibrary = graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/generated_exports.dart'),
        );
        final modelLibrary = graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/model.dart'),
        );
        const generatedId = 'dart-generated:test_app/lib/router.g.dart';
        expect(graph.blockersFor(model.id), isNotEmpty);
        final generatedLibrary = graph.nodes.singleWhere(
          (node) => node.id == generatedId,
        );
        expect(generatedLibrary.kind, NodeKind.generatedArtifact);
        expect(generatedLibrary.metadata['generated'], isTrue);
        expect(generatedLibrary.metadata['removalSupported'], isFalse);
        expect(graph.isProtected(generatedLibrary.id), isFalse);
        expect(
          graph.nodes.map((node) => node.id),
          isNot(
            contains('dart:test_app/lib/router.g.dart#createGeneratedModel'),
          ),
          reason: 'a generated declaration caller must not be fabricated',
        );
        expect(
          graph.edges,
          containsAll([
            predicate<GraphEdge>(
              (edge) =>
                  edge.from == mainLibrary.id &&
                  edge.to == generatedId &&
                  edge.kind == EdgeKind.imports &&
                  edge.evidence.exact,
            ),
            predicate<GraphEdge>(
              (edge) =>
                  edge.from == generatedId &&
                  edge.to == modelLibrary.id &&
                  edge.kind == EdgeKind.imports &&
                  edge.evidence.exact,
            ),
            predicate<GraphEdge>(
              (edge) =>
                  edge.from == generatedId &&
                  edge.to == model.id &&
                  edge.kind == EdgeKind.references &&
                  edge.evidence.exact,
            ),
            predicate<GraphEdge>(
              (edge) =>
                  edge.from == exportLibrary.id &&
                  edge.to == generatedId &&
                  edge.kind == EdgeKind.imports &&
                  edge.evidence.description.contains('export directive') &&
                  edge.evidence.exact,
            ),
          ]),
        );
        expect(
          graph.configuredProvenFor(project.targets.single),
          containsAll([generatedId, modelLibrary.id, model.id]),
        );
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
        );
        expect(
          findings.where((finding) => finding.node.id == generatedId),
          isEmpty,
        );
        expect(
          graph.edges
              .where(
                (edge) => edge.from == generatedId || edge.to == generatedId,
              )
              .every(
                (edge) => graph.hasNode(edge.from) && graph.hasNode(edge.to),
              ),
          isTrue,
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test('G7 unimported standalone generated library is not a root', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': 'void main() {}',
        'lib/model.dart': 'class GeneratedModel {}',
        'lib/unimported.g.dart': '''
import 'model.dart';

GeneratedModel createGeneratedModel() => GeneratedModel();
''',
      });

      final result = await analyzeDeclaredCompleteApplication();
      const generatedId = 'dart-generated:test_app/lib/unimported.g.dart';
      final generated = result.graph.nodes.singleWhere(
        (node) => node.id == generatedId,
      );
      final model = result.graph.nodes.singleWhere(
        (node) => node.id.endsWith('model.dart#GeneratedModel'),
      );

      expect(generated.kind, NodeKind.generatedArtifact);
      expect(result.graph.rootIds, isNot(contains(generatedId)));
      expect(result.graph.isProtected(generatedId), isFalse);
      expect(
        result.graph.configuredProvenFor(project.targets.single),
        isNot(contains(generatedId)),
      );
      expect(
        result.graph.edges,
        contains(
          predicate<GraphEdge>(
            (edge) =>
                edge.from == generatedId &&
                edge.to == model.id &&
                edge.kind == EdgeKind.references,
          ),
        ),
      );
      expect(
        result.findings.where((finding) => finding.node.id == generatedId),
        isEmpty,
      );
      expect(result.graph.danglingEdges(), isEmpty);
    });

    test(
      'G7 generated unresolved callers block imported and unimported targets',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'imported.g.dart';

void main() => invokeImported(Object());
''',
          'lib/candidates.dart': '''
class ImportedCandidate {
  void importedGeneratedCall() {}
}

class UnimportedCandidate {
  void unimportedGeneratedCall() {}
}
''',
          'lib/imported.g.dart': '''
void invokeImported(dynamic value) => value.importedGeneratedCall();
''',
          'lib/unimported.g.dart': '''
void invokeUnimported(dynamic value) => value.unimportedGeneratedCall();
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        const importedArtifact = 'dart-generated:test_app/lib/imported.g.dart';
        const unimportedArtifact =
            'dart-generated:test_app/lib/unimported.g.dart';
        expect(
          result.graph.nodes,
          containsAll([
            predicate<GraphNode>(
              (node) =>
                  node.id == importedArtifact &&
                  node.kind == NodeKind.generatedArtifact,
            ),
            predicate<GraphNode>(
              (node) =>
                  node.id == unimportedArtifact &&
                  node.kind == NodeKind.generatedArtifact,
            ),
          ]),
        );
        expect(
          result.graph.configuredProvenFor(project.targets.single),
          contains(importedArtifact),
        );
        expect(
          result.graph.configuredProvenFor(project.targets.single),
          isNot(contains(unimportedArtifact)),
        );

        final addressedFindings = <Finding>[];
        for (final name in ['ImportedCandidate', 'UnimportedCandidate']) {
          final candidate = result.graph.nodes.singleWhere(
            (node) => node.id.endsWith('candidates.dart#$name'),
          );
          final blocker = result.graph
              .blockersFor(candidate.id)
              .singleWhere(
                (candidateBlocker) =>
                    candidateBlocker.reason.contains(
                      'unresolved semantic reference',
                    ) &&
                    candidateBlocker.affectedNodeIds.contains(candidate.id),
              );
          expect(blocker.sourceNodeId, isNull);
          expect(blocker.affectedNamespace, isNull);
          addressedFindings.add(
            result.findings.singleWhere(
              (finding) => finding.node.id == candidate.id,
            ),
          );
        }
        expect(
          addressedFindings.where(
            (finding) =>
                finding.confidence == Confidence.safe ||
                finding.confidence == Confidence.high,
          ),
          isEmpty,
        );
        expect(
          addressedFindings.where(
            (finding) =>
                finding.isAutoApplicable || finding.proposedAction != null,
          ),
          isEmpty,
        );
        expect(result.graph.danglingEdges(), isEmpty);
      },
    );

    test('G7 external generated source gets no parent-owned node ID', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_generated","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
        'lib/main.dart': '''
import 'package:external_generated/external.g.dart';

void main() => externalGenerated();
''',
        'nested/pubspec.yaml': '''
name: external_generated
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'nested/lib/external.g.dart': 'void externalGenerated() {}',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      const boundaryId = 'dart-package:test_app/external_generated';

      expect(graph.nodes.map((node) => node.id), contains(boundaryId));
      expect(
        graph.nodes.map((node) => node.id),
        isNot(contains('dart-generated:test_app/nested/lib/external.g.dart')),
      );
      expect(
        graph.nodes.where(
          (node) => node.origin.path.endsWith('nested/lib/external.g.dart'),
        ),
        isEmpty,
      );
      expect(
        () => DartIds.generatedArtifact(
          project,
          p.join(tempDir.path, 'nested', 'lib', 'external.g.dart'),
        ),
        throwsStateError,
      );
      expect(
        graph.edges.every(
          (edge) => graph.hasNode(edge.from) && graph.hasNode(edge.to),
        ),
        isTrue,
      );
      expect(graph.danglingEdges(), isEmpty);
    });

    test(
      'generated dynamic part retains matching member owners but not canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'generated.g.dart';

class FooOwner {
  void foo() {}
}

class DynamicFallback {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() => generated(Object());

void _uniqueCanary() {}
''',
          'lib/generated.g.dart': '''
part of 'main.dart';

void generated(dynamic value) => value.foo();
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in ['FooOwner', 'DynamicFallback']) {
          expect(result.graph.blockersFor(node(name).id), isNotEmpty);
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(
          canary.confidence,
          Confidence.safe,
          reason:
              'whyNotSafe=${canary.whyNotSafe}; '
              'blockers=${canary.blockers.map((blocker) => blocker.reason).toList()}; '
              'retainedIn=${canary.retainedIn}; '
              'auxiliaryRetainedIn=${canary.auxiliaryRetainedIn}; '
              'danglingEdges=${result.graph.danglingEdges()}; '
              'danglingRoots=${result.graph.danglingRootIdsFor(project.targets)}',
        );
      },
    );

    test(
      'standalone generated dynamic library retains matching owners not canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'generated.gr.dart';

class FooOwner {
  void foo() {}
}

class DynamicFallback {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() => generated(Object());

void _uniqueCanary() {}
''',
          'lib/generated.gr.dart': '''
void generated(dynamic value) => value.foo();
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in ['FooOwner', 'DynamicFallback']) {
          expect(result.graph.blockersFor(node(name).id), isNotEmpty);
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(
          canary.confidence,
          Confidence.safe,
          reason:
              'whyNotSafe=${canary.whyNotSafe}; '
              'blockers=${canary.blockers.map((blocker) => blocker.reason).toList()}; '
              'retainedIn=${canary.retainedIn}; '
              'auxiliaryRetainedIn=${canary.auxiliaryRetainedIn}; '
              'danglingEdges=${result.graph.danglingEdges()}; '
              'danglingRoots=${result.graph.danglingRootIdsFor(project.targets)}',
        );
      },
    );

    test(
      'generated operator reference retains its named extension owner',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'generated.g.dart';

class Box {
  const Box();
}

extension GeneratedOps on Box {
  Box operator +(int value) => this;
}

void main() => generated(const Box());
''',
          'lib/generated.g.dart': '''
part of 'main.dart';

Box generated(Box value) => value + 1;
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final extension = result.graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#GeneratedOps'),
        );
        expect(
          result.graph.blockersFor(extension.id),
          isNotEmpty,
          reason: 'generated operator code cannot survive extension removal',
        );
      },
    );

    test(
      'known missing class with no local match does not block unrelated canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': 'void main() {}',
          'lib/broken.dart': 'class Broken extends MissingBase {}',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final broken = graph.nodes.firstWhere(
          (candidate) => candidate.id.endsWith('broken.dart#Broken'),
        );
        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: project,
              graphIntegrity: graph.integrityFor(project.targets),
            )
            .singleWhere((finding) => finding.node.id == broken.id);
        expect(graph.blockersFor(broken.id), isEmpty);
        expect(finding.confidence, Confidence.review);
      },
    );

    test(
      'resolved plain assignments and built-in unary operators add no semantic blockers',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class Counter {
  int value = 0;
  bool enabled = true;

  void update() {
    var local = value;
    local = 1;
    value = local;
    enabled = !enabled;
    final negated = -value;
    final checked = negated!;
    value++;
  }
}

void main() => Counter().update();
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        expect(
          graph.blockers
              .where(
                (blocker) =>
                    blocker.reason ==
                    'analyzer returned an unresolved semantic reference',
              )
              .toList(),
          isEmpty,
        );
      },
    );

    test('library directive names do not create semantic blockers', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
library test_app.main;

void main() {}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(
        graph.blockers
            .where(
              (blocker) =>
                  blocker.reason ==
                  'analyzer returned an unresolved semantic reference',
            )
            .toList(),
        isEmpty,
      );
    });

    test('documentation references do not create runtime blockers', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
/// Decodes a flat payload such as {enabled, buttons[]}.
class DocumentedType {
  const DocumentedType();
}

void main() => const DocumentedType();
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(
        graph.blockers
            .where(
              (blocker) =>
                  blocker.reason ==
                  'analyzer returned an unresolved semantic reference',
            )
            .toList(),
        isEmpty,
      );
    });

    test(
      'active dynamic member reference retains matching owners but not unique canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class FirstOwner {
  void foo() {}
}

class SecondOwner {
  void foo() {}
}

class DynamicFallback {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main(dynamic value) => value.foo();

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );

        for (final name in ['FirstOwner', 'SecondOwner', 'DynamicFallback']) {
          expect(
            result.graph
                .blockersFor(node(name).id)
                .map((blocker) => blocker.affectedNodeIds),
            contains(contains(node(name).id)),
            reason: '$name can receive dynamic foo',
          );
        }
        expect(result.graph.blockersFor(node('_uniqueCanary').id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'implicit unresolved member names retain matching owners but not canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class MemberOwner {
  void foo() {}
  int get bar => 1;
  set baz(int value) {}
}

class Caller {
  void run() {
    foo();
    final value = bar;
    baz = value;
  }
}

void main() => Caller().run();

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final owner = result.graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#MemberOwner'),
        );
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('main.dart#_uniqueCanary'),
        );

        expect(
          result.graph
              .blockersFor(owner.id)
              .map((blocker) => blocker.affectedNodeIds),
          contains(contains(owner.id)),
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'dynamic operators and call retain matching owners but not canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class PlusOwner {
  PlusOwner operator +(Object other) => this;
}

class IndexOwner {
  Object operator [](int index) => index;
}

class UnaryOwner {
  UnaryOwner operator -() => this;
}

class CallOwner {
  void call() {}
}

class DynamicFallback {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main(dynamic value, dynamic other) {
  value + other;
  value[0];
  -value;
  value();
}

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in [
          'PlusOwner',
          'IndexOwner',
          'UnaryOwner',
          'CallOwner',
          'DynamicFallback',
        ]) {
          expect(
            result.graph.blockersFor(node(name).id),
            isNotEmpty,
            reason: name,
          );
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'dynamic index reads writes and compounds retain exact owners',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class IndexReadOwner {
  Object operator [](int index) => index;
}

class IndexWriteOwner {
  void operator []=(int index, Object value) {}
}

class PlusOwner {
  PlusOwner operator +(Object value) => this;
}

class DynamicFallback {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main(dynamic value) {
  value[0];
  value[1] = 2;
  value[2] += 3;
  value[3]++;
}

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in [
          'IndexReadOwner',
          'IndexWriteOwner',
          'PlusOwner',
          'DynamicFallback',
        ]) {
          expect(
            result.graph.blockersFor(node(name).id),
            isNotEmpty,
            reason: name,
          );
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'dynamic implicit protocols retain matching owners without namespace fallback',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class IteratorOwner {
  Object get iterator => this;
}

class MoveNextOwner {
  bool moveNext() => false;
}

class CurrentOwner {
  Object? get current => null;
}

class ListenOwner {
  void listen() {}
}

class PauseOwner {
  void pause() {}
}

class ResumeOwner {
  void resume() {}
}

class CancelOwner {
  void cancel() {}
}

class ThenOwner {
  void then() {}
}

class LengthOwner {
  int get length => 0;
}

class IndexOwner {
  Object operator [](Object key) => key;
}

class ContainsKeyOwner {
  bool containsKey(Object key) => false;
}

class ToStringOwner {
  @override
  String toString() => '';
}

Future<void> useDynamic(dynamic value) async {
  for (final item in value) {
    '\$item';
  }
  final values = [...value];
  '\$value';
  await value;
  switch (value) {
    case [var first]:
      '\$first';
    case {'key': var mapped}:
      '\$mapped';
  }
  values.toString();
}

Iterable<dynamic> useSyncYield(dynamic value) sync* {
  yield* value;
}

Stream<dynamic> useAsyncYield(dynamic value) async* {
  yield* value;
}

void main(dynamic value) {
  useDynamic(value);
  useSyncYield(value);
  useAsyncYield(value);
}

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        for (final name in [
          'IteratorOwner',
          'MoveNextOwner',
          'CurrentOwner',
          'ListenOwner',
          'PauseOwner',
          'ResumeOwner',
          'CancelOwner',
          'ThenOwner',
          'LengthOwner',
          'IndexOwner',
          'ContainsKeyOwner',
          'ToStringOwner',
        ]) {
          final owner = result.graph.nodes.singleWhere(
            (node) => node.id.endsWith('main.dart#$name'),
          );
          expect(result.graph.blockersFor(owner.id), isNotEmpty, reason: name);
        }
        expect(
          result.graph.blockers.where(
            (blocker) => blocker.affectedNamespace == 'dart:test_app/',
          ),
          isEmpty,
        );
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('main.dart#_uniqueCanary'),
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'ordinary typed implicit protocols do not add semantic fallback',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
Future<void> useTyped(List<int> values, Future<int> future) async {
  for (final item in values) {
    '\$item';
  }
  final copy = [...values];
  await future;
  switch (values) {
    case [var first]:
      '\$first';
  }
  copy.toString();
}

void useTypedMap(Map<String, int> values) {
  switch (values) {
    case {'key': var mapped}:
      '\$mapped';
  }
}

void main() {
  useTyped([1], Future.value(1));
  useTypedMap({'key': 1});
}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        expect(
          result.graph.blockers.where(
            (blocker) =>
                blocker.reason ==
                'analyzer returned an unresolved semantic reference',
          ),
          isEmpty,
        );
      },
    );

    test(
      'unresolved compound target retains matching getter and setter owner',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
void main() {
  unresolved.missing += 1;
}

class MemberOwner {
  int _value = 0;
  int get missing => _value;
  set missing(Object value) {}
}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        final candidate = graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#MemberOwner'),
        );
        expect(
          graph.blockersFor(candidate.id).map((blocker) => blocker.reason),
          contains('analyzer returned an unresolved semantic reference'),
        );
      },
    );

    test(
      'dynamic compound and inequality retain operator owners without canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
class PlusOwner {
  PlusOwner operator +(Object value) => this;
}

class MinusOwner {
  MinusOwner operator -(Object value) => this;
}

class EqualityOwner {
  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => 0;
}

class Holder {
  dynamic value;
}

void main(dynamic value) {
  dynamic local = value;
  local += 1;
  local++;
  final holder = Holder()..value = value;
  holder.value += 1;
  holder.value++;
  value - 1;
  value != 1;
  switch (value) {
    case == 2:
    case != 3:
      break;
  }
}

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in ['PlusOwner', 'MinusOwner', 'EqualityOwner']) {
          expect(
            result.graph.blockersFor(node(name).id),
            isNotEmpty,
            reason: name,
          );
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test(
      'generated dynamic compound and inequality retain operator owners',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'generated.g.dart';

class PlusOwner {
  PlusOwner operator +(Object value) => this;
}

class EqualityOwner {
  @override
  bool operator ==(Object other) => identical(this, other);

  @override
  int get hashCode => 0;
}

void main(dynamic value) => generated(value);

void _uniqueCanary() {}
''',
          'lib/generated.g.dart': '''
part of 'main.dart';

void generated(dynamic value) {
  dynamic local = value;
  local += 1;
  local++;
  value != 1;
  switch (value) {
    case == 2:
    case != 3:
      break;
  }
}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        GraphNode node(String name) => result.graph.nodes.singleWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        for (final name in ['PlusOwner', 'EqualityOwner']) {
          expect(
            result.graph.blockersFor(node(name).id),
            isNotEmpty,
            reason: name,
          );
        }
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id == node('_uniqueCanary').id,
        );
        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test('dynamic binary equality retains its equality owner', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
class BinaryEqualityOwner {
  @override
  bool operator ==(Object other) => identical(this, other);
  @override
  int get hashCode => 0;
}
void main(dynamic value) => value != 1;
void _uniqueCanary() {}
''',
      });
      final result = await analyzeDeclaredCompleteApplication();
      final owner = result.graph.nodes.singleWhere(
        (node) => node.id.endsWith('main.dart#BinaryEqualityOwner'),
      );
      expect(result.graph.blockersFor(owner.id), isNotEmpty);
    });

    test('dynamic relational equality retains its equality owner', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
class RelationalEqualityOwner {
  @override
  bool operator ==(Object other) => identical(this, other);
  @override
  int get hashCode => 0;
}
void main(dynamic value) {
  switch (value) {
    case == 1:
    case != 2:
      break;
  }
}
void _uniqueCanary() {}
''',
      });
      final result = await analyzeDeclaredCompleteApplication();
      final owner = result.graph.nodes.singleWhere(
        (node) => node.id.endsWith('main.dart#RelationalEqualityOwner'),
      );
      expect(result.graph.blockersFor(owner.id), isNotEmpty);
    });

    test('generated dynamic subtraction retains its operator owner', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
part 'generated.g.dart';
class MinusOwner { MinusOwner operator -(Object value) => this; }
void main(dynamic value) => generated(value);
void _uniqueCanary() {}
''',
        'lib/generated.g.dart': '''
part of 'main.dart';
void generated(dynamic value) => value - 1;
''',
      });
      final result = await analyzeDeclaredCompleteApplication();
      final owner = result.graph.nodes.singleWhere(
        (node) => node.id.endsWith('main.dart#MinusOwner'),
      );
      expect(result.graph.blockersFor(owner.id), isNotEmpty);
    });

    test(
      'generated dynamic interpolation retains its protocol owner',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'generated.g.dart';
class ToStringOwner { @override String toString() => ''; }
void main(dynamic value) => generated(value);
void _uniqueCanary() {}
''',
          'lib/generated.g.dart': '''
part of 'main.dart';
void generated(dynamic value) { '\$value'; }
''',
        });
        final result = await analyzeDeclaredCompleteApplication();
        final owner = result.graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#ToStringOwner'),
        );
        expect(result.graph.blockersFor(owner.id), isNotEmpty);
      },
    );

    test('unresolved increment retains target and operator owners', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {
  ++missing;
}

class GetterSetterOwner {
  int _value = 0;
  int get missing => _value;
  set missing(int value) => _value = value;
}

class IncrementOperatorOwner {
  IncrementOperatorOwner operator +(Object other) => this;
}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      for (final name in ['GetterSetterOwner', 'IncrementOperatorOwner']) {
        final candidate = graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#$name'),
        );
        expect(
          graph.blockersFor(candidate.id).map((blocker) => blocker.reason),
          contains('analyzer returned an unresolved semantic reference'),
          reason: name,
        );
      }
    });

    test(
      'known undefined function with a captured fact does not globally block canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
          'lib/main.dart': 'void main() => unresolvedCall();',
          'lib/candidate.dart': 'class RemovalCandidate {}',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final candidate = graph.nodes.singleWhere(
          (node) => node.id.endsWith('candidate.dart#RemovalCandidate'),
        );
        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: project,
              graphIntegrity: graph.integrityFor(project.targets),
            )
            .singleWhere((finding) => finding.node.id == candidate.id);
        expect(graph.blockersFor(candidate.id), isEmpty);
        expect(finding.confidence, Confidence.safe);
      },
    );

    test(
      'resolved named parameter diagnostic does not globally block canary',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
          'lib/main.dart': '''
void resolved() {}

void main(dynamic value) {
  value.foo();
  resolved(unknownNamedParameter: 1);
}

void _uniqueCanary() {}
''',
        });

        final result = await analyzeDeclaredCompleteApplication();
        final canary = result.findings.singleWhere(
          (finding) => finding.node.id.endsWith('main.dart#_uniqueCanary'),
        );

        expect(result.graph.blockersFor(canary.node.id), isEmpty);
        expect(canary.confidence, Confidence.safe);
      },
    );

    test('URI and parse errors keep namespace fallback', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': "import 'missing.dart';\nvoid main() {}\n",
        'lib/parse_error.dart': 'void malformed( {\n',
        'lib/candidate.dart': 'class RemovalCandidate {}\n',
      });

      final result = await analyzeDeclaredCompleteApplication();
      final candidate = result.graph.nodes.singleWhere(
        (node) => node.id.endsWith('candidate.dart#RemovalCandidate'),
      );

      expect(
        result.graph.blockersFor(candidate.id).map((blocker) => blocker.reason),
        contains('analyzer could not fully resolve this Dart unit'),
      );
    });

    test(
      'dynamic semantic references block false SAFE Dart candidates',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
          'lib/main.dart': '''
void main(dynamic receiver) {
  receiver.invoke();
}

class InvocationOwner {
  void invoke() {}
}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final candidate = graph.nodes.singleWhere(
          (node) => node.id.endsWith('main.dart#InvocationOwner'),
        );
        final blocker = graph
            .blockersFor(candidate.id)
            .firstWhere(
              (candidate) =>
                  candidate.reason ==
                  'analyzer returned an unresolved semantic reference',
            );
        expect(blocker.sourceNodeId, endsWith('lib/main.dart#main'));

        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: project,
              graphIntegrity: graph.integrityFor(project.targets),
            )
            .singleWhere((finding) => finding.node.id == candidate.id);
        expect(finding.confidence, Confidence.review);
      },
    );

    test('models typedef and extension type declarations', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
typedef Converter = String Function(int value);
extension type ProductId(String value) {}

void main() {
  Converter converter = (value) => value.toString();
  print(ProductId(converter(1)));
}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final reachable = graph.reachableFor(project.targets.first);
      for (final name in ['Converter', 'ProductId']) {
        final node = graph.nodes.firstWhere(
          (candidate) => candidate.id.endsWith('main.dart#$name'),
        );
        expect(reachable, contains(node.id));
      }
    });

    test(
      'does not model named local functions as top-level declarations',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
void main() {
  void localFunction() {}
  localFunction();
}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        expect(
          graph.nodes.where((node) => node.id.endsWith('#localFunction')),
          isEmpty,
        );
      },
    );

    test(
      'attributes local-function references to the top-level owner',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
void main() {
  void localCallback() {
    reachableHelper();
  }
  localCallback();
}

void reachableHelper() {}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        final helper = graph.nodes.singleWhere(
          (node) => node.id.endsWith('lib/main.dart#reachableHelper'),
        );

        expect(graph.reachableFor(project.targets.single), contains(helper.id));
      },
    );

    test('follows references to top-level variables', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
const packageValue = 'value';

void main() {
  print(packageValue);
}
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final valueNode = graph.nodes.firstWhere(
        (node) => node.id.endsWith('#packageValue'),
      );
      expect(graph.reachableFor(project.targets.first), contains(valueNode.id));
    });

    test(
      'uses stable declaration IDs across a library and its parts',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
part 'events.dart';

void main() => total = 1;
''',
          'lib/events.dart': '''
part of 'main.dart';

int total = 0;
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final total = graph.nodes.firstWhere(
          (candidate) => candidate.displayName == 'total',
        );
        expect(graph.reachableFor(project.targets.first), contains(total.id));
        expect(
          graph.danglingEdges().where((edge) => edge.to.endsWith('#total')),
          isEmpty,
        );
      },
    );

    test('treats test libraries as roots for dynamic test callbacks', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': 'void main() {}',
        'test/helper_test.dart': '''
const fixtureValue = 1;
''',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final testLibrary = graph.nodes.firstWhere(
        (node) =>
            node.id.contains('test/helper_test.dart') &&
            node.kind == NodeKind.dartLibrary,
      );
      expect(
        graph.reachableFor(project.targets.first),
        contains(testLibrary.id),
      );
    });

    test('creates library nodes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final libraryNodes = graph.nodes.where(
        (GraphNode n) =>
            n.kind == NodeKind.dartLibrary && n.id.contains('main.dart'),
      );

      expect(libraryNodes, isNotEmpty);
    });

    test(
      'surfaces analyzer unused diagnostics as non-editable nodes',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'helper.dart';

void main() {
  final unusedValue = 1;
  print('live');
}
''',
          'lib/helper.dart': 'void helper() {}\n',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final diagnostics = graph.nodesOfKind(NodeKind.analyzerDiagnostic);
        expect(
          diagnostics.map((node) => node.metadata['diagnosticCode']),
          containsAll(['unused_import', 'unused_local_variable']),
        );
        expect(
          diagnostics.every(
            (node) => node.metadata['removalSupported'] == false,
          ),
          isTrue,
        );

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'dart', 'dart-diagnostic'},
          adapterReportDefinitions: {'dart': DartAdapter().reportDefinition},
        );
        final diagnosticFindings = findings.where(
          (finding) => finding.ruleId == 'PRN-DART-003',
        );
        expect(diagnosticFindings, hasLength(2));
        expect(
          diagnosticFindings.every(
            (finding) =>
                finding.confidence == Confidence.review &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
      },
    );

    test(
      'includes lint-only unused diagnostics from analysis options',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'analysis_options.yaml': '''
linter:
  rules:
    - avoid_unused_constructor_parameters
''',
          'lib/main.dart': '''
class Example {
  Example({required int unused});
}

void main() {
  Example(unused: 1);
}
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        expect(
          graph
              .nodesOfKind(NodeKind.analyzerDiagnostic)
              .map((node) => node.metadata['diagnosticCode']),
          contains('avoid_unused_constructor_parameters'),
        );
        expect(graph.blockers, isEmpty);
      },
    );

    test('creates cleanup candidates for empty Dart files', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': 'void main() {}',
        'lib/src/empty.dart': '// obsolete library stub\n',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final emptyLibrary = graph.nodes.singleWhere(
        (node) => node.id.endsWith('lib/src/empty.dart'),
      );
      expect(emptyLibrary.kind, NodeKind.dartLibrary);
      expect(emptyLibrary.metadata['declarationCount'], 0);
      expect(
        graph.unreachableAcrossAll(project.targets),
        contains(emptyLibrary.id),
      );
    });

    test('creates import edges', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
import 'helper.dart';

void main() {}
''',
        'lib/helper.dart': '''
void helper() {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final importEdges = graph.edges.where(
        (GraphEdge e) => e.kind == EdgeKind.imports,
      );

      expect(importEdges, isNotEmpty);
    });

    test(
      'G5 omits an incoming external back-edge and blocks its selected namespace',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"nested_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
import 'package:nested_pkg/back_edge.dart';

void main() => callParent();
''',
          'lib/internal.dart': 'void internalApi() {}\n',
          'nested/pubspec.yaml': '''
name: nested_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'nested/.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"nested_pkg","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"test_app","rootUri":"../../","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'nested/lib/back_edge.dart': '''
import 'package:test_app/internal.dart';

void callParent() => internalApi();
''',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        const internalNamespace = 'dart:test_app/lib/internal.dart';
        expect(
          graph.nodes.map((node) => node.id),
          isNot(contains(contains('nested/lib/back_edge.dart'))),
        );
        expect(
          graph.edges.where(
            (edge) => edge.from.contains('nested/lib/back_edge.dart'),
          ),
          isEmpty,
        );
        final blocker = graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'external package can address selected Dart library',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, internalNamespace);
        expect(graph.danglingEdges(), isEmpty);
        expect(graph.danglingRootIdsFor(project.targets), isEmpty);

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'dart'},
        );
        final affected = findings.where(
          (finding) => finding.node.id.startsWith(internalNamespace),
        );
        expect(affected, isNotEmpty);
        expect(
          affected.every(
            (finding) =>
                finding.confidence != Confidence.safe &&
                finding.confidence != Confidence.high &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
      },
    );

    test(
      'G5 does not enumerate an unreferenced external package root',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"nested_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': 'void main() {}\n',
          'lib/unused.dart': 'void removalCandidate() {}\n',
          'nested/pubspec.yaml': '''
name: nested_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'nested/lib/broken.dart': 'void broken( {\n',
          'nested/lib/conditional.dart': '''
import 'safe.dart'
    if (dart.library.html) 'package:test_app/unused.dart';
''',
          'nested/lib/safe.dart': 'void safe() {}\n',
        });
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        expect(
          graph.blockers.map((blocker) => blocker.reason),
          isNot(contains('external package closure could not be inspected')),
        );
        expect(
          graph.blockers.map((blocker) => blocker.reason),
          isNot(
            contains(
              'conditional Dart imports/exports are not modelled per target',
            ),
          ),
        );
        expect(
          graph.nodes.map((node) => node.id),
          isNot(contains(contains('nested/lib/broken.dart'))),
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test(
      'G5 ProjectAnalyzer inspects a transitive out-of-tree external back-edge',
      () async {
        final externalRoot = await Directory.systemTemp.createTemp(
          'dart_external_closure_test_',
        );
        addTearDown(() => externalRoot.delete(recursive: true));
        final directRoot = Directory(p.join(externalRoot.path, 'direct'));
        final indirectRoot = Directory(p.join(externalRoot.path, 'indirect'));
        File(p.join(directRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: direct_pkg
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  indirect_pkg:
    path: ${p.relative(indirectRoot.path, from: directRoot.path)}
''');
        File(p.join(directRoot.path, 'lib', 'direct.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:indirect_pkg/indirect.dart';

void callIndirect() => callSelected();
''');
        File(p.join(indirectRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: indirect_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(indirectRoot.path, 'lib', 'indirect.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:test_app/internal.dart';

void callSelected() => internalApi();
''');
        await createProject({
          'pubspec.yaml':
              '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  direct_pkg:
    path: ${p.relative(directRoot.path, from: tempDir.path)}
''',
          '.dart_tool/package_config.json':
              '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"direct_pkg","rootUri":"${directRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"indirect_pkg","rootUri":"${indirectRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
import 'package:direct_pkg/direct.dart';

void main() => callIndirect();
''',
          'lib/internal.dart': 'void internalApi() {}\n',
          'lib/unused.dart': 'void removalCandidate() {}\n',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );

        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'dart'},
        ).analyze();

        const internalNamespace = 'dart:test_app/lib/internal.dart';
        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'external package can address selected Dart library',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, internalNamespace);
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          contains('dart-package:test_app/direct_pkg'),
        );
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          isNot(contains(contains('indirect_pkg'))),
        );
        expect(
          snapshot.graph.nodes.where(
            (node) => p.isWithin(externalRoot.path, node.origin.path),
          ),
          isEmpty,
        );
        expect(
          snapshot.graph.edges.where(
            (edge) =>
                edge.from.contains('direct_pkg') ||
                edge.from.contains('indirect_pkg'),
          ),
          isEmpty,
        );
        expect(snapshot.graph.danglingEdges(), isEmpty);
        final affected = snapshot.findings.where(
          (finding) => finding.node.id.startsWith(internalNamespace),
        );
        expect(affected, isNotEmpty);
        expect(
          affected.every(
            (finding) =>
                finding.confidence != Confidence.safe &&
                finding.confidence != Confidence.high &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
      },
    );

    test(
      'G6 ProjectAnalyzer inspects a Web-selected non-host external back-edge',
      () async {
        final externalRoot = await Directory.systemTemp.createTemp(
          'dart_target_selected_external_closure_test_',
        );
        addTearDown(() => externalRoot.delete(recursive: true));
        final vmRoot = Directory(p.join(externalRoot.path, 'vm_pkg'));
        final webRoot = Directory(p.join(externalRoot.path, 'web_pkg'));
        File(p.join(vmRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: vm_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(vmRoot.path, 'lib', 'platform.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void platformEntry() {}\n');
        File(p.join(webRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: web_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(webRoot.path, 'lib', 'platform.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:test_app/internal.dart';

void platformEntry() => selectedEntry();
''');
        await createProject({
          'pubspec.yaml':
              '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  vm_pkg:
    path: ${p.relative(vmRoot.path, from: tempDir.path)}
  web_pkg:
    path: ${p.relative(webRoot.path, from: tempDir.path)}
''',
          '.dart_tool/package_config.json':
              '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"vm_pkg","rootUri":"${vmRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"web_pkg","rootUri":"${webRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
import 'package:vm_pkg/platform.dart'
    if (dart.library.html) 'package:web_pkg/platform.dart';

void main() => platformEntry();
''',
          'lib/internal.dart': '''
void selectedEntry() {}
void removalCandidate() {}
''',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production-web',
              platform: 'web',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );

        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'dart'},
        ).analyze();

        const internalNamespace = 'dart:test_app/lib/internal.dart';
        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
                  'external package can address selected Dart library' &&
              blocker.affectedNamespace == internalNamespace,
        );
        expect(blocker.sourceNodeId, isNull);
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          contains('dart-package:test_app/web_pkg'),
        );
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          isNot(contains('dart-package:test_app/vm_pkg')),
        );
        expect(
          snapshot.graph.nodes.where(
            (node) => p.isWithin(externalRoot.path, node.origin.path),
          ),
          isEmpty,
        );
        expect(
          snapshot.graph.edges.where(
            (edge) =>
                edge.from.contains('vm_pkg') || edge.from.contains('web_pkg'),
          ),
          isEmpty,
        );
        expect(
          snapshot.graph.rootIds.where(
            (rootId) => rootId.contains('vm_pkg') || rootId.contains('web_pkg'),
          ),
          isEmpty,
        );
        expect(snapshot.graph.danglingEdges(), isEmpty);
        expect(snapshot.graph.danglingRootIdsFor(project.targets), isEmpty);

        final affected = snapshot.findings.where(
          (finding) => finding.node.id.startsWith(internalNamespace),
        );
        expect(affected, isNotEmpty);
        expect(
          affected.where(
            (finding) =>
                finding.confidence == Confidence.safe ||
                finding.confidence == Confidence.high,
          ),
          isEmpty,
        );
        expect(
          affected.where((finding) => finding.proposedAction != null),
          isEmpty,
        );
      },
    );

    test(
      'G5 conditional external closure blocks the selected Dart namespace',
      () async {
        final externalRoot = await Directory.systemTemp.createTemp(
          'dart_external_conditional_test_',
        );
        addTearDown(() => externalRoot.delete(recursive: true));
        File(p.join(externalRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: conditional_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
        final conditionalPath = p.join(
          externalRoot.path,
          'lib',
          'conditional.dart',
        );
        File(conditionalPath)
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'safe.dart'
    if (dart.library.html) 'package:test_app/internal.dart';

void externalEntry() => branchEntry();
''');
        File(p.join(externalRoot.path, 'lib', 'safe.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void branchEntry() {}\n');
        await createProject({
          'pubspec.yaml':
              '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  conditional_pkg:
    path: ${p.relative(externalRoot.path, from: tempDir.path)}
''',
          '.dart_tool/package_config.json':
              '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conditional_pkg","rootUri":"${externalRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
import 'package:conditional_pkg/conditional.dart';

void main() => externalEntry();
''',
          'lib/internal.dart': '''
void branchEntry() {}
void privateCandidate() {}
''',
          'lib/unused.dart': 'void removalCandidate() {}\n',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );

        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'dart'},
        ).analyze();

        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'conditional Dart imports/exports are not modelled per target',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, 'dart:test_app/');
        expect(p.equals(blocker.location!, conditionalPath), isTrue);
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(contains('external package can address selected Dart library')),
        );
        expect(
          snapshot.graph.nodes.where(
            (node) => p.isWithin(externalRoot.path, node.origin.path),
          ),
          isEmpty,
        );
        expect(
          snapshot.graph.edges.where(
            (edge) => edge.from.contains('conditional_pkg'),
          ),
          isEmpty,
        );
        expect(snapshot.graph.danglingEdges(), isEmpty);
        expect(snapshot.graph.danglingRootIdsFor(project.targets), isEmpty);
        expect(snapshot.findings, isNotEmpty);
        expect(
          snapshot.findings.every(
            (finding) =>
                finding.confidence != Confidence.safe &&
                finding.confidence != Confidence.high &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
      },
    );

    test('G5 unknown ownership blocks the selected Dart namespace', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_claim","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
        'lib/main.dart': '''
import '../nested/lib/api.dart';

void main() => api();
''',
        'lib/unused.dart': 'void unused() {}\n',
        'nested/pubspec.yaml': '''
name: actual_nested
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'nested/lib/api.dart': 'void api() {}\n',
      });
      project = ProjectContext(
        root: tempDir,
        pubspec: const {'name': 'test_app'},
        packageName: 'test_app',
        targets: [
          BuildTarget(
            name: 'production',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
        rootCoverage: RootCoverage.applicationApi(),
      );
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(
        graph.nodes.map((node) => node.id),
        isNot(contains(contains('nested/lib/api.dart'))),
      );
      final ownershipBlockers = graph.blockers
          .where(
            (blocker) =>
                blocker.reason.contains('ownership boundary is unknown'),
          )
          .toList();
      expect(ownershipBlockers, isNotEmpty);
      expect(
        ownershipBlockers.every(
          (blocker) => blocker.affectedNamespace == 'dart:test_app/',
        ),
        isTrue,
      );
      expect(graph.danglingEdges(), isEmpty);
      expect(graph.danglingRootIdsFor(project.targets), isEmpty);

      final findings = const FindingGenerator().generate(
        graph: graph,
        project: project,
        graphIntegrity: graph.integrityFor(project.targets),
        reportingNodeSchemes: const {'dart'},
      );
      expect(findings, isNotEmpty);
      expect(
        findings.every(
          (finding) =>
              finding.confidence != Confidence.safe &&
              finding.confidence != Confidence.high &&
              finding.proposedAction == null,
        ),
        isTrue,
      );
    });

    test(
      'G5 external part blocks its owning selected library without activation',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"part_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
part 'package:part_pkg/external_part.dart';

void main() => externalPartEntry();
void selectedCandidate() {}
''',
          'nested/pubspec.yaml': '''
name: part_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'nested/lib/external_part.dart': '''
part of 'package:test_app/main.dart';

@pragma('vm:entry-point')
void externalCallback() => selectedCandidate();

void externalPartEntry() {
  selectedCandidate();
  missingFromExternalPart();
}
''',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          targets: [
            BuildTarget(
              name: 'production',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        const libraryId = 'dart:test_app/lib/main.dart';
        final blocker = graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'selected Dart library includes a non-selected part',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, libraryId);
        expect(graph.blockersFor(libraryId), contains(blocker));
        expect(
          graph.blockersFor('$libraryId#selectedCandidate'),
          contains(blocker),
        );
        expect(
          graph.nodes.map((node) => node.id),
          isNot(contains(contains('external_part.dart'))),
        );
        expect(
          graph.nodes.map((node) => node.id),
          isNot(contains(contains('externalCallback'))),
        );
        expect(graph.rootIds, isNot(contains(contains('externalCallback'))));
        expect(
          graph.edges.where(
            (edge) =>
                edge.from.contains('external_part.dart') ||
                edge.to.contains('external_part.dart'),
          ),
          isEmpty,
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test('G5 unknown part blocks its owning selected library', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_part","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
        'lib/main.dart': '''
part 'package:conflicting_part/unknown_part.dart';

void main() {}
void selectedCandidate() {}
''',
        'nested/pubspec.yaml': '''
name: actual_part
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'nested/lib/unknown_part.dart': '''
part of 'package:test_app/main.dart';

void unknownPartEntry() => selectedCandidate();
''',
      });
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      const libraryId = 'dart:test_app/lib/main.dart';
      final blocker = graph.blockers.singleWhere(
        (blocker) =>
            blocker.reason ==
            'selected Dart library includes a part with unknown ownership',
      );
      expect(blocker.sourceNodeId, isNull);
      expect(blocker.affectedNamespace, libraryId);
      expect(
        graph.blockersFor('$libraryId#selectedCandidate'),
        contains(blocker),
      );
      expect(
        graph.nodes.map((node) => node.id),
        isNot(contains(contains('unknown_part.dart'))),
      );
      expect(graph.danglingEdges(), isEmpty);
    });

    test(
      'G5 incomplete external closure blocks the selected namespace',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          '.dart_tool/package_config.json': '''
{"configVersion":2,"packages":[
  {"name":"test_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"nested_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''',
          'lib/main.dart': '''
import 'package:nested_pkg/broken.dart';

void main() => broken();
''',
          'lib/unused.dart': 'void unused() {}\n',
          'nested/pubspec.yaml': '''
name: nested_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'nested/lib/broken.dart': 'void broken( {\n',
        });
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        expect(
          graph.nodes.map((node) => node.id),
          isNot(contains(contains('nested/lib/broken.dart'))),
        );
        final blocker = graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'external package closure could not be inspected',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, 'dart:test_app/');
      },
    );

    test('keeps public exports reachable in both package modes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/test_app.dart': "export 'src/public_api.dart';",
        'lib/src/public_api.dart': 'class PublicApi {}',
      });

      for (final mode in ['package', 'package-internal']) {
        File('${tempDir.path}/flutter_pruner.yaml').writeAsStringSync('''
version: 1
analysis:
  mode: $mode
  public_entrypoints:
    - lib/test_app.dart
target_matrix:
  complete: true
  targets:
    - name: package
      platform: android
      entrypoint: lib/test_app.dart
''');
        final configuredProject = await ProjectContext.load(tempDir);
        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(
          configuredProject,
          GraphBuilder(graph, 'dart'),
        );

        final publicApi = graph.nodes.firstWhere(
          (node) => node.id.endsWith('src/public_api.dart#PublicApi'),
        );
        expect(
          graph.reachableFor(configuredProject.targets.first),
          contains(publicApi.id),
          reason: mode,
        );
      }
    });

    test(
      'programmatic package-internal context without roots fails closed',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/test_app.dart': 'library;',
          'lib/other.dart': '''
int publicApi() => _privateHelper();
int _privateHelper() => 42;
''',
        });
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          analysisMode: AnalysisMode.packageInternal,
          targets: [
            BuildTarget(
              name: 'package',
              platform: 'android',
              entrypoint: 'lib/test_app.dart',
            ),
          ],
        );

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'dart'},
        );
        final helper = findings.singleWhere(
          (finding) => finding.node.id.endsWith('#_privateHelper'),
        );

        expect(project.analysisCoverageComplete, isFalse);
        expect(helper.confidence, Confidence.review);
        expect(helper.proposedAction, isNull);
        expect(
          helper.classificationReasons,
          contains(ClassificationReason.incompleteRootCoverage),
        );
      },
    );

    test(
      'caller mutation cannot remove a complete package public root',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/test_app.dart': "export 'src/public_api.dart';",
          'lib/src/public_api.dart': 'class PublicApi {}',
        });
        final publicEntrypoints = ['lib/test_app.dart'];
        final issues = ['external consumers are not scanned'];
        final targets = [
          BuildTarget(
            name: 'package',
            platform: 'android',
            entrypoint: 'lib/test_app.dart',
          ),
        ];
        project = ProjectContext(
          root: tempDir,
          pubspec: const {'name': 'test_app'},
          packageName: 'test_app',
          analysisMode: AnalysisMode.packageInternal,
          targets: targets,
          rootCoverage: RootCoverage(
            mode: RootCoverageMode.packageInternal,
            internalBoundaryComplete: true,
            externalConsumersCovered: false,
            source: 'test config',
            publicEntrypoints: publicEntrypoints,
            issues: issues,
          ),
        );

        publicEntrypoints.clear();
        issues.clear();
        targets.clear();

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        final publicApi = graph.nodes.singleWhere(
          (node) => node.id.endsWith('src/public_api.dart#PublicApi'),
        );
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'dart'},
        );

        expect(project.analysisCoverageComplete, isTrue);
        expect(project.rootCoverage.publicEntrypoints, ['lib/test_app.dart']);
        expect(project.targets, hasLength(1));
        expect(
          graph.reachableFor(project.targets.single),
          contains(publicApi.id),
        );
        final publicApiFinding = findings.singleWhere(
          (finding) => finding.node.id == publicApi.id,
        );
        expect(publicApiFinding.confidence, Confidence.review);
        expect(publicApiFinding.proposedAction, isNull);
        expect(publicApiFinding.predicates.unreachableAcrossAllTargets, isTrue);
        expect(publicApiFinding.predicates.notRetained, isFalse);
        expect(publicApiFinding.reachableIn, isEmpty);
        expect(publicApiFinding.unreachableIn, ['package']);
        expect(publicApiFinding.retainedIn, isEmpty);
        expect(publicApiFinding.auxiliaryRetainedIn, [
          'aux:external:lib/test_app.dart',
        ]);
        expect(
          publicApiFinding.classificationReasons,
          contains(ClassificationReason.retainedOnly),
        );
        expect(
          () => project.rootCoverage.publicEntrypoints.clear(),
          throwsUnsupportedError,
        );
      },
    );

    test('excluded configured application roots remain dangling', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'analysis_options.yaml': '''
analyzer:
  exclude:
    - lib/main.dart
''',
        'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
        'lib/main.dart': 'void main() {}',
        'lib/candidate.dart': 'class RemovalCandidate {}',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(
        graph.danglingRootIdsFor(project.targets),
        containsAll([
          'dart:test_app/lib/main.dart',
          'dart:test_app/lib/main.dart#main',
        ]),
      );
      final candidate = graph.nodes.singleWhere(
        (node) => node.id.endsWith('candidate.dart#RemovalCandidate'),
      );
      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: project,
            graphIntegrity: graph.integrityFor(project.targets),
          )
          .singleWhere((finding) => finding.node.id == candidate.id);
      expect(finding.confidence, Confidence.review);
    });

    test('configured roots match analyzer package-URI node IDs', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        '.dart_tool/package_config.json': '''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "test_app",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''',
        'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''',
        'lib/main.dart': 'void main() {}',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(graph.danglingRootIdsFor(project.targets), isEmpty);
      expect(graph.hasNode('dart:test_app/lib/main.dart'), isTrue);
      expect(graph.hasNode('dart:test_app/lib/main.dart#main'), isTrue);
    });

    test('excluded configured public roots remain dangling', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'analysis_options.yaml': '''
analyzer:
  exclude:
    - lib/test_app.dart
''',
        'flutter_pruner.yaml': '''
version: 1
analysis:
  mode: package-internal
  public_entrypoints:
    - lib/test_app.dart
target_matrix:
  complete: true
  targets:
    - name: package
      platform: android
      entrypoint: lib/test_app.dart
''',
        'lib/test_app.dart': "export 'src/api.dart';",
        'lib/src/api.dart': 'class RemovalCandidate {}',
      });

      final graph = ReachabilityGraph();
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      expect(
        graph.integrityFor(project.targets).danglingRootIds,
        contains('dart:test_app/lib/test_app.dart'),
      );
      final candidate = graph.nodes.singleWhere(
        (node) => node.id.endsWith('src/api.dart#RemovalCandidate'),
      );
      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: project,
            graphIntegrity: graph.integrityFor(project.targets),
          )
          .singleWhere((finding) => finding.node.id == candidate.id);
      expect(finding.confidence, Confidence.review);
    });

    test('handwritten gen directories keep editable IDs and findings', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
import 'gen/reachable.dart';

void main() => ReachableHandwritten().run();
''',
        'lib/gen/reachable.dart': '''
class ReachableHandwritten {
  void run() {}
}
''',
        'lib/generated/unreachable.dart': 'class UnreachableHandwritten {}',
        'lib/generated/actual.g.dart': 'class GeneratedArtifact {}',
      });

      final result = await analyzeDeclaredCompleteApplication();
      const reachableLibraryId = 'dart:test_app/lib/gen/reachable.dart';
      const reachableDeclarationId =
          'dart:test_app/lib/gen/reachable.dart#ReachableHandwritten';
      const unreachableLibraryId =
          'dart:test_app/lib/generated/unreachable.dart';
      const unreachableDeclarationId =
          'dart:test_app/lib/generated/unreachable.dart#UnreachableHandwritten';
      const generatedArtifactId =
          'dart-generated:test_app/lib/generated/actual.g.dart';

      expect(result.graph.node(reachableLibraryId)?.kind, NodeKind.dartLibrary);
      expect(
        result.graph.node(reachableDeclarationId)?.kind,
        NodeKind.declaration,
      );
      expect(
        result.graph.node(unreachableLibraryId)?.kind,
        NodeKind.dartLibrary,
      );
      expect(
        result.graph.node(unreachableDeclarationId)?.kind,
        NodeKind.declaration,
      );
      expect(
        result.graph.node(generatedArtifactId)?.kind,
        NodeKind.generatedArtifact,
      );

      final target = project.targets.single;
      expect(
        result.graph.configuredProvenFor(target),
        containsAll([reachableLibraryId, reachableDeclarationId]),
      );
      expect(
        result.graph.retainedFor(target),
        contains(reachableDeclarationId),
      );
      expect(
        result.findings.map((finding) => finding.node.id),
        isNot(contains(reachableDeclarationId)),
        reason: 'configured-proven declarations are retained, not findings',
      );

      final unreachableFinding = result.findings.singleWhere(
        (finding) => finding.node.id == unreachableDeclarationId,
      );
      expect(unreachableFinding.confidence, Confidence.safe);
      expect(unreachableFinding.proposedAction, 'Remove declaration');
      expect(unreachableFinding.manualRisks, isEmpty);
      expect(unreachableFinding.classificationReasons, isEmpty);
      expect(
        {
          'ruleAllowsAutoFix': unreachableFinding.predicates.ruleAllowsAutoFix,
          'unreachableAcrossAllTargets':
              unreachableFinding.predicates.unreachableAcrossAllTargets,
          'notRetained': unreachableFinding.predicates.notRetained,
          'noDynamicBlockers': unreachableFinding.predicates.noDynamicBlockers,
          'notProtected': unreachableFinding.predicates.notProtected,
          'noPublicApiRisk': unreachableFinding.predicates.noPublicApiRisk,
          'hasDeterministicInverse':
              unreachableFinding.predicates.hasDeterministicInverse,
          'analysisCoverageComplete':
              unreachableFinding.predicates.analysisCoverageComplete,
          'actionSupported': unreachableFinding.predicates.actionSupported,
        },
        const {
          'ruleAllowsAutoFix': true,
          'unreachableAcrossAllTargets': true,
          'notRetained': true,
          'noDynamicBlockers': true,
          'notProtected': true,
          'noPublicApiRisk': true,
          'hasDeterministicInverse': true,
          'analysisCoverageComplete': true,
          'actionSupported': true,
        },
      );
      expect(
        ModeApplyPolicy.allows(project.analysisMode, unreachableFinding),
        isTrue,
      );
      expect(
        result.findings.map((finding) => finding.node.id),
        isNot(contains(generatedArtifactId)),
      );
      expect(result.graph.danglingEdges(), isEmpty);
      expect(result.graph.danglingRootIdsFor(project.targets), isEmpty);
    });

    test('excludes declarations from generated part files', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/model.dart': '''
part 'model.g.dart';

class CartModel {
  final int id;
  CartModel(this.id);
}
''',
        'lib/model.g.dart': '''
part of 'model.dart';

// ignore: library_private_types_in_public_api
CartModel _\$CartModelFromJson(Map<String, dynamic> json) =>
    CartModel(json['id'] as int);

Map<String, dynamic> _\$CartModelToJson(CartModel instance) =>
    <String, dynamic>{'id': instance.id};
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      // Declarations from the .g.dart part file must not enter the graph.
      // If they did, they would show up as SAFE findings and be deleted.
      final generatedDecls = graph.nodes.where(
        (GraphNode n) =>
            n.kind == NodeKind.declaration &&
            (n.displayName?.startsWith(r'_$') ?? false),
      );

      expect(
        generatedDecls,
        isEmpty,
        reason: 'declarations from .g.dart part files must not enter the graph',
      );
    });

    test('protects DI module classes (*Module suffix)', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/di/cart_module.dart': '''
class CartModule {
  static void register() {}
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final moduleNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartModule'),
      );

      expect(
        graph.isProtected(moduleNode.id),
        isTrue,
        reason:
            'DI module classes must be PROTECTED — wired by the framework at runtime',
      );
    });

    test('protects router declaration classes (*Route suffix)', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/routes/cart_route.dart': '''
class CartRoute {
  static const String path = '/cart';
}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final routeNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartRoute'),
      );

      expect(
        graph.isProtected(routeNode.id),
        isTrue,
        reason:
            'router classes must be PROTECTED — referenced by the routing framework at runtime',
      );
    });

    test('does not protect ordinary unreachable class', () async {
      // Regression: protection patterns must not catch unrelated names.
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/unused.dart': '''
class DeadHelper {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final node = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('DeadHelper'),
      );

      expect(
        graph.isProtected(node.id),
        isFalse,
        reason: 'ordinary unused classes must not be protected',
      );
    });

    test('protects BLoC pattern classes (case-insensitive)', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/cart/cart_bloc.dart': '''
class CartBloc {}
class CartEvent {}
class CartState {}
''',
        'lib/user/user_cubit.dart': '''
class UserCubit {}
class UserState {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final blocNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartBloc'),
      );
      final eventNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartEvent'),
      );
      final stateNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartState'),
      );
      final cubitNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('UserCubit'),
      );

      expect(
        graph.isProtected(blocNode.id),
        isTrue,
        reason: 'BLoC classes are registered via BlocProvider',
      );
      expect(
        graph.isProtected(eventNode.id),
        isTrue,
        reason: 'Event classes are dispatched at runtime',
      );
      expect(
        graph.isProtected(stateNode.id),
        isTrue,
        reason: 'State classes are emitted by BLoC',
      );
      expect(
        graph.isProtected(cubitNode.id),
        isTrue,
        reason: 'Cubit classes are registered via BlocProvider',
      );
    });

    test('protects Clean Architecture pattern classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/domain/usecases/get_cart.dart': '''
class GetCartUseCase {}
''',
        'lib/domain/repositories/cart_repository.dart': '''
abstract class CartRepository {}
''',
        'lib/data/repositories/cart_repository_impl.dart': '''
class CartRepositoryImpl {}
''',
        'lib/data/datasources/cart_remote_datasource.dart': '''
class CartRemoteDataSource {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final useCaseNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('GetCartUseCase'),
      );
      final repositoryNode = graph.nodes.firstWhere(
        (GraphNode n) =>
            n.id.contains('CartRepository') && !n.id.contains('Impl'),
      );
      final repositoryImplNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartRepositoryImpl'),
      );
      final datasourceNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartRemoteDataSource'),
      );

      expect(
        graph.isProtected(useCaseNode.id),
        isTrue,
        reason: 'UseCase classes are invoked via DI',
      );
      expect(
        graph.isProtected(repositoryNode.id),
        isTrue,
        reason: 'Repository interfaces are injected via DI',
      );
      expect(
        graph.isProtected(repositoryImplNode.id),
        isTrue,
        reason: 'RepositoryImpl classes are injected via DI',
      );
      expect(
        graph.isProtected(datasourceNode.id),
        isTrue,
        reason: 'DataSource classes are injected via DI',
      );
    });

    test('protects GetX pattern classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/cart/cart_controller.dart': '''
class CartController {}
''',
        'lib/cart/cart_binding.dart': '''
class CartBinding {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final controllerNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartController'),
      );
      final bindingNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartBinding'),
      );

      expect(
        graph.isProtected(controllerNode.id),
        isTrue,
        reason: 'Controller classes are registered via Get.put()',
      );
      expect(
        graph.isProtected(bindingNode.id),
        isTrue,
        reason: 'Binding classes are wired by GetX routing',
      );
    });

    test('protects Riverpod pattern classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/cart/cart_provider.dart': '''
class CartProvider {}
''',
        'lib/cart/cart_notifier.dart': '''
class CartNotifier {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final providerNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartProvider'),
      );
      final notifierNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartNotifier'),
      );

      expect(
        graph.isProtected(providerNode.id),
        isTrue,
        reason: 'Provider classes are accessed via ref.watch()',
      );
      expect(
        graph.isProtected(notifierNode.id),
        isTrue,
        reason: 'Notifier classes are registered via StateNotifierProvider',
      );
    });

    test('protects routing destination classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/screens/cart_screen.dart': '''
class CartScreen {}
''',
        'lib/pages/checkout_page.dart': '''
class CheckoutPage {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final screenNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartScreen'),
      );
      final pageNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CheckoutPage'),
      );

      expect(
        graph.isProtected(screenNode.id),
        isTrue,
        reason: 'Screen classes are routing destinations',
      );
      expect(
        graph.isProtected(pageNode.id),
        isTrue,
        reason: 'Page classes are routing destinations',
      );
    });

    test('does not protect private StatefulWidget state classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/cart_widget.dart': '''
class CartWidget {}
class _CartWidgetState {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final stateNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('_CartWidgetState'),
      );

      expect(
        graph.isProtected(stateNode.id),
        isFalse,
        reason:
            'Private _*State classes are StatefulWidget states, not BLoC states',
      );
    });

    test('protects MVVM pattern classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/cart/cart_view_model.dart': '''
class CartViewModel {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final viewModelNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartViewModel'),
      );

      expect(
        graph.isProtected(viewModelNode.id),
        isTrue,
        reason: 'ViewModel classes are MVVM business logic layer',
      );
    });

    test('protects Redux pattern classes', () async {
      await createProject({
        'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
        'lib/main.dart': '''
void main() {}
''',
        'lib/redux/cart_actions.dart': '''
class AddToCartAction {}
''',
        'lib/redux/cart_reducer.dart': '''
class CartReducer {}
''',
        'lib/redux/logging_middleware.dart': '''
class LoggingMiddleware {}
''',
      });

      final adapter = const DartAdapter();
      final graph = ReachabilityGraph();
      final builder = GraphBuilder(graph, 'dart');

      await adapter.analyze(project, builder);

      final actionNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('AddToCartAction'),
      );
      final reducerNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('CartReducer'),
      );
      final middlewareNode = graph.nodes.firstWhere(
        (GraphNode n) => n.id.contains('LoggingMiddleware'),
      );

      expect(
        graph.isProtected(actionNode.id),
        isTrue,
        reason: 'Action classes are Redux action objects',
      );
      expect(
        graph.isProtected(reducerNode.id),
        isTrue,
        reason: 'Reducer classes are Redux state transformers',
      );
      expect(
        graph.isProtected(middlewareNode.id),
        isTrue,
        reason: 'Middleware classes intercept Redux actions',
      );
    });
  });
}

String _graphRootFingerprint(GraphRootRecord root) => switch (root) {
  ConfiguredGraphRootRecord() =>
    '${root.domain.name}|${root.nodeId}|${root.reason}|${root.condition}',
  AuxiliaryGraphRootRecord() =>
    '${root.domain.name}|${root.nodeId}|${root.reason}|${root.executionTargetId}',
};

String _snapshotRootFingerprint(DartExecutionRootFact root) =>
    '${root.domain.name}|${root.nodeId}|${root.reason}|'
    '${root.configuredTarget == null ? root.auxiliaryExecutionTargetId : BuildCondition.forTarget(root.configuredTarget!)}';

final class _FixedReachabilityService
    implements DartExecutionReachabilityService {
  _FixedReachabilityService(this.resolvedSnapshot);

  final DartExecutionReachabilitySnapshot resolvedSnapshot;
  int resolveCalls = 0;

  @override
  Future<DartExecutionReachabilitySnapshot> resolve(
    ProjectContext project,
  ) async {
    resolveCalls++;
    return resolvedSnapshot;
  }
}

final class _ThrowingExecutionContextService
    implements DartExecutionContextService {
  int resolveCalls = 0;

  @override
  Future<DartExecutionContextSnapshot> resolve(ProjectContext project) async {
    resolveCalls++;
    throw StateError('legacy context fallback must not run');
  }
}
