import 'dart:io';

import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:flutter_pruner/src/adapters/dart/analyzer_diagnostic_collector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

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
        reportingNodeSchemes: const {'dart'},
      ),
    );
  }

  void expectConditionalDirectiveBlocker(
    ReachabilityGraph graph, {
    required String pathSuffix,
  }) {
    final blockers = graph.blockers
        .where(
          (blocker) =>
              blocker.reason ==
              'conditional Dart imports/exports are not modelled per target',
        )
        .toList();
    expect(blockers, hasLength(1), reason: 'one blocker per source unit');
    final blocker = blockers.single;
    expect(blocker.sourceNodeId, isNull);
    expect(blocker.affectedNamespace, 'dart:test_app/');
    expect(p.normalize(blocker.location!), endsWith(p.normalize(pathSuffix)));
  }

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
      'conditional imports and exports downgrade a declared-complete project',
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
        expectConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/main.dart',
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional export in an unreachable library still blocks SAFE',
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

        expectConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/src/conditional_export.dart',
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional directive in a non-first part downgrades candidates',
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

        expectConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/feature_part.dart',
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional directive in a generated part downgrades candidates',
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

        expectConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'lib/model.g.dart',
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
      },
    );

    test(
      'conditional directive in an outside-lib configured entrypoint downgrades candidates',
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

        expectConditionalDirectiveBlocker(
          result.graph,
          pathSuffix: 'tool/main.dart',
        );
        expect(candidate.confidence, Confidence.review);
        expect(candidate.proposedAction, isNull);
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
        expect(candidate.confidence, Confidence.safe);
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
          isNot(contains(contains('Workmanager.initialize'))),
          reason:
              'bounded parameter/local propagation should resolve the wrapper',
        );

        final unresolvedCandidate = declaration('UnresolvedCallbackCandidate');
        expect(
          graph
              .blockersFor(unresolvedCandidate.id)
              .map((blocker) => blocker.reason),
          contains(
            contains(
              'native callback boundary has an unresolved callback target',
            ),
          ),
        );
        final finding = const FindingGenerator()
            .generate(graph: graph, project: callbackProject)
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
        expect(
          graph.blockersFor(model.id),
          isNotEmpty,
          reason:
              'generated code would fail if its source declaration vanished',
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

    test(
      'standalone generated libraries block referenced source declarations',
      () async {
        await createProject({
          'pubspec.yaml': '''
name: test_app
publish_to: none
environment:
  sdk: ^3.9.0
''',
          'lib/main.dart': '''
import 'router.gr.dart';

void main() => createGeneratedModel();
''',
          'lib/model.dart': 'class GeneratedModel {}',
          'lib/router.gr.dart': '''
import 'model.dart';

GeneratedModel createGeneratedModel() => GeneratedModel();
''',
        });

        final graph = ReachabilityGraph();
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final model = graph.nodes.firstWhere(
          (candidate) => candidate.id.endsWith('model.dart#GeneratedModel'),
        );
        expect(graph.blockersFor(model.id), isNotEmpty);
        expect(
          graph.nodes.where((node) => node.id.contains('router.gr.dart')),
          isEmpty,
          reason:
              'generated declarations must stay outside the candidate graph',
        );
        expect(graph.danglingEdges(), isEmpty);
      },
    );

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
        expect(canary.confidence, Confidence.safe);
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
        expect(canary.confidence, Confidence.safe);
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
            .generate(graph: graph, project: project)
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
            .generate(graph: graph, project: project)
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
            .generate(graph: graph, project: project)
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
          reportingNodeSchemes: const {'dart'},
        );

        expect(project.analysisCoverageComplete, isTrue);
        expect(project.rootCoverage.publicEntrypoints, ['lib/test_app.dart']);
        expect(project.targets, hasLength(1));
        expect(
          graph.reachableFor(project.targets.single),
          contains(publicApi.id),
        );
        expect(
          findings.where((finding) => finding.node.id == publicApi.id),
          isEmpty,
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
          .generate(graph: graph, project: project)
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
        graph.danglingRootIdsFor(project.targets),
        contains('dart:test_app/lib/test_app.dart'),
      );
      final candidate = graph.nodes.singleWhere(
        (node) => node.id.endsWith('src/api.dart#RemovalCandidate'),
      );
      final finding = const FindingGenerator()
          .generate(graph: graph, project: project)
          .singleWhere((finding) => finding.node.id == candidate.id);
      expect(finding.confidence, Confidence.review);
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
