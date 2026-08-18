import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_adapter.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('L10nAdapter', () {
    test(
      'adds ARB nodes and exact semantic use edges without l10n roots',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        final welcome = graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'welcome');
        final cartItem = graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'cartItem');
        expect(graph.nodesOfKind(NodeKind.localizationKey), hasLength(3));
        expect(
          graph.incomingTo(welcome.id).map((edge) => edge.kind),
          contains(EdgeKind.references),
        );
        expect(
          graph.incomingTo(cartItem.id).map((edge) => edge.kind),
          contains(EdgeKind.references),
        );
        expect(graph.rootIds, isNot(contains(welcome.id)));
        final l10nReferences = graph.edges.where(
          (edge) => graph.node(edge.to)?.kind == NodeKind.localizationKey,
        );
        expect(l10nReferences, isNotEmpty);
        expect(
          l10nReferences.every(
            (edge) => graph.hasNode(edge.from) && graph.hasNode(edge.to),
          ),
          isTrue,
        );
        expect(
          graph.blockers
              .where((blocker) => blocker.producer == 'l10n')
              .every((blocker) => !blocker.isUnscoped),
          isTrue,
        );
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
        expect(graph.danglingRootIdsFor(project.targets), isEmpty);
      },
    );

    test(
      'blocks every configured generated output library and preserves closure',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        const primary = 'dart:l10n_test/lib/l10n/app_localizations.dart';
        const sibling = 'dart:l10n_test/lib/l10n/app_localizations_en.dart';
        expect(
          graph.blockers.any((blocker) => blocker.affectedNamespace == primary),
          isTrue,
        );
        expect(
          graph.blockers.any((blocker) => blocker.affectedNamespace == sibling),
          isTrue,
        );
        expect(graph.retainedFor(project.targets.single), contains(primary));
        expect(
          graph.outgoingFrom(primary).map((edge) => edge.to),
          contains(sibling),
        );
        expect(graph.retainedFor(project.targets.single), contains(sibling));
        expect(
          graph.retainedFor(project.targets.single),
          contains(
            'dart:l10n_test/lib/l10n/app_localizations.dart#AppLocalizations',
          ),
        );
        final generatedFindings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          reportingNodeSchemes: const {'dart'},
        );
        final generated = generatedFindings
            .where((finding) => finding.node.id.startsWith(primary))
            .toList(growable: false);
        expect(generated, isNotEmpty);
        expect(
          generated.every(
            (finding) =>
                finding.confidence != Confidence.safe &&
                finding.confidence != Confidence.high &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
      },
    );

    test('blocks an unimported stale generated locale sibling', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      await File(
        p.join(root.path, 'lib/l10n/app_localizations.dart'),
      ).writeAsString('''
class AppLocalizations {
  String get welcome => 'Welcome';
  String greeting(String name) => name;
  String cartItem(int count) => '\$count';
}
''');
      await File(
        p.join(root.path, 'lib/l10n/app_localizations_fr.dart'),
      ).writeAsString('''
class StaleFrenchLocalizations {
  String get welcome => 'Bonjour';
}
''');
      final project = await _loadCompleteProject(root);
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

      await _expectBlockedGeneratedDart(
        graph: graph,
        project: project,
        namespace: 'dart:l10n_test/lib/l10n/app_localizations_fr.dart',
      );
    });

    test(
      'blocks generated siblings when the configured primary cannot resolve',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(
          p.join(root.path, 'lib/l10n/app_localizations.dart'),
        ).delete();
        await File(
          p.join(root.path, 'lib/l10n/app_localizations_fr.dart'),
        ).writeAsString('''
class StaleFrenchLocalizations {
  String get welcome => 'Bonjour';
}
''');
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        await _expectBlockedGeneratedDart(
          graph: graph,
          project: project,
          namespace: 'dart:l10n_test/lib/l10n/app_localizations_fr.dart',
        );
      },
    );

    test(
      'blocks multi-dot generated siblings when the configured primary is missing',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'l10n.yaml')).writeAsString('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app.localizations.dart
''');
        await File(
          p.join(root.path, 'lib/l10n/app_en.localizations.dart'),
        ).writeAsString('''
class StaleEnglishLocalizations {
  String get welcome => 'Welcome';
}
''');
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        await _expectBlockedGeneratedDart(
          graph: graph,
          project: project,
          namespace: 'dart:l10n_test/lib/l10n/app_en.localizations.dart',
        );
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
      },
    );

    test(
      'uses a bounded family blocker when a sibling is not a regular file',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        Directory(
          p.join(root.path, 'lib/l10n/app_localizations_es.dart'),
        ).createSync();
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        expect(
          graph.blockers.any(
            (blocker) =>
                blocker.affectedNamespace ==
                'dart:l10n_test/lib/l10n/app_localizations_',
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) => blocker.affectedNamespace == 'dart:l10n_test/lib/',
          ),
          isFalse,
        );
      },
    );

    test(
      'keeps invalid configuration applicable with l10n and Dart blockers',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'l10n.yaml')).writeAsString('arb-dir: []');
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        expect(const L10nAdapter().appliesTo(project), isTrue);
        expect(
          graph.blockers.any(
            (blocker) => blocker.affectedNamespace == 'l10n:l10n_test:',
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) => blocker.affectedNamespace == 'dart:l10n_test/',
          ),
          isTrue,
        );
        expect(graph.nodesOfKind(NodeKind.localizationKey), isEmpty);
      },
    );

    test(
      'keeps valid ARB keys when inventory or member resolution is partial',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'lib/l10n/app_vi.arb')).writeAsString('''
{
  "@@locale": "vi",
  "welcome": "Chao mung",
  "greeting": "Xin chao {name}",
  "extra": "Them"
}
''');
        await File(
          p.join(root.path, 'lib/l10n/app_localizations.dart'),
        ).writeAsString('''
class AppLocalizations {
  String get welcome => 'Welcome';
  String greeting(String name) => name;
}
''');
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        expect(
          graph
              .nodesOfKind(NodeKind.localizationKey)
              .map((node) => node.metadata['key']),
          containsAll(<String>['welcome', 'greeting', 'cartItem']),
        );
        expect(
          graph.blockers.any(
            (blocker) =>
                blocker.affectedNodeIds.contains('l10n:l10n_test:cartItem'),
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) => blocker.affectedNamespace == 'l10n:l10n_test:',
          ),
          isTrue,
        );
      },
    );

    test(
      'keeps a complete unused key REVIEW-only without an l10n blocker',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'lib/custom_lookup.dart')).delete();
        await File(p.join(root.path, 'lib/consumer.dart')).delete();
        await File(p.join(root.path, 'lib/l10n/app_vi.arb')).writeAsString('''
{
  "@@locale": "vi",
  "welcome": "Chao mung",
  "cartItem": "{count, plural, =0{Khong co} other{{count} muc}}",
  "greeting": "Xin chao {name}",
  "@greeting": {"placeholders": {"name": {"type": "String"}}}
}
''');
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          reportingNodeSchemes: const {'l10n'},
        );
        final unused = findings.singleWhere(
          (finding) => finding.node.metadata['key'] == 'cartItem',
        );
        expect(graph.incomingTo(unused.node.id), isEmpty);
        expect(graph.blockersFor(unused.node.id), isEmpty);
        expect(unused.confidence, Confidence.review);
        expect(unused.proposedAction, isNull);
      },
    );

    test('reuses the supplied Dart analysis workspace', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);
      final graph = ReachabilityGraph();
      final workspace = DartAnalysisWorkspace(project);

      await const DartAdapter().analyzeWithServices(
        project,
        GraphBuilder(graph, 'dart'),
        AdapterServices(dartWorkspace: workspace),
      );
      final resolutions = workspace.resolutionCount;
      await const L10nAdapter().analyzeWithServices(
        project,
        GraphBuilder(graph, 'l10n'),
        AdapterServices(dartWorkspace: workspace),
      );

      expect(workspace.resolutionCount, resolutions);
    });

    test('declares its stable contract', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);

      expect(const L10nAdapter().id, 'l10n');
      expect(const L10nAdapter().findingNodeSchemes, const {'l10n'});
      expect(const L10nAdapter().dependsOn, const ['dart']);
      expect(const L10nAdapter().appliesTo(project), isTrue);
      expect(
        const L10nAdapter().reportDefinition.findings.single.ruleId,
        'PRN-L10N-001',
      );
    });
  });
}

Future<ProjectContext> _loadCompleteProject(Directory root) async {
  final inferred = await ProjectContext.load(root);
  return ProjectContext(
    root: root,
    pubspec: inferred.pubspec,
    packageName: inferred.packageName,
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'test',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
  );
}

Future<Directory> _copyFixture() async {
  final source = Directory(p.absolute('test/fixtures/l10n_test'));
  final root = await Directory.systemTemp.createTemp('l10n_adapter_');
  await for (final entity in source.list(recursive: true)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(root.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
  await File(
    p.join(root.path, 'lib/main.dart'),
  ).writeAsString('void main() {}');
  return root;
}

Future<void> _expectBlockedGeneratedDart({
  required ReachabilityGraph graph,
  required ProjectContext project,
  required String namespace,
}) async {
  expect(
    graph.blockers.any((blocker) => blocker.affectedNamespace == namespace),
    isTrue,
  );
  final findings = const FindingGenerator().generate(
    graph: graph,
    project: project,
    reportingNodeSchemes: const {'dart'},
  );
  final generated = findings
      .where((finding) => finding.node.id.startsWith(namespace))
      .toList(growable: false);
  expect(generated, isNotEmpty);
  expect(
    generated.every(
      (finding) =>
          finding.confidence != Confidence.safe &&
          finding.confidence != Confidence.high &&
          finding.proposedAction == null,
    ),
    isTrue,
  );
}
