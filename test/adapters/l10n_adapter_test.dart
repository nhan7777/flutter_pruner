import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_application_reachability.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_adapter.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/apply/mode_apply_policy.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
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
          graphIntegrity: graph.integrityFor(project.targets),
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
        await File(p.join(root.path, 'lib/main.dart')).writeAsString('''
import 'constructor_consumer.dart';
import 'l10n/app_localizations.dart';
import 'reexport_consumer.dart';

void main() {
  ConstructsLocalizations();
  throughExport(const AppLocalizations());
}
''');
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
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'l10n'},
        );
        final unused = findings.singleWhere(
          (finding) => finding.node.metadata['key'] == 'cartItem',
        );
        expect(graph.incomingTo(unused.node.id), isEmpty);
        expect(graph.blockersFor(unused.node.id), isEmpty);
        expect(unused.reportingAdapterId, 'l10n');
        expect(unused.ruleId, 'PRN-L10N-001');
        expect(unused.confidence, Confidence.review);
        expect(unused.proposedAction, isNull);
      },
    );

    test(
      'shares Dart reachability and retains an exact auxiliary l10n use',
      () async {
        final root = await _createReachabilityFixture(
          completeTestEnvironment: true,
        );
        addTearDown(() => root.delete(recursive: true));
        final project = await _loadCompleteProject(root);
        final graph = ReachabilityGraph();
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
        final reachability = _RecordingReachabilityService(snapshot);
        final throwingContexts = _ThrowingExecutionContextService();
        final services = AdapterServices(
          dartWorkspace: workspace,
          dartExecutionContextService: throwingContexts,
          dartExecutionReachabilityService: reachability,
        );

        expect(applicationReachability.issues, isEmpty);
        expect(
          applicationReachability.unitPaths.map(p.basename),
          isNot(contains('unreachable.dart')),
        );
        expect(
          applicationReachability.unitPaths.map(p.basename),
          isNot(contains('localizations_test.dart')),
        );
        expect(
          applicationReachability.globalUsageUnitPaths.map(p.basename),
          contains('localizations_test.dart'),
        );

        await const DartAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          services,
        );
        final dartFingerprint = reachability.observed.single.fingerprint;
        await const L10nAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'l10n'),
          services,
        );

        expect(reachability.resolveCalls, 2);
        expect(
          reachability.observed.every(
            (observed) => identical(observed, snapshot),
          ),
          isTrue,
        );
        expect(
          reachability.observed.map((observed) => observed.fingerprint).toSet(),
          {dartFingerprint},
        );
        expect(throwingContexts.resolveCalls, 0);
        _expectNoDanglingEndpointsForEveryExecutionContext(
          graph,
          project,
          expectedContexts: const {
            'app:test': RootDomain.configuredTarget,
            'aux:test:test/localizations_test.dart:vm': RootDomain.auxiliary,
          },
        );
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'l10n'},
          adapterReportDefinitions: {
            'l10n': const L10nAdapter().reportDefinition,
          },
        );
        expect(
          findings.map((finding) => finding.node.metadata['key']),
          contains('deadOnly'),
        );
        expect(
          findings.map((finding) => finding.node.metadata['key']),
          isNot(contains('live')),
        );
        expect(
          findings.map((finding) => finding.node.metadata['key']),
          isNot(contains('testOnly')),
        );
        expect(
          graph
              .incomingTo('l10n:l10n_test:deadOnly')
              .where((edge) => edge.kind == EdgeKind.references),
          isEmpty,
        );
        expect(
          graph
              .incomingTo('l10n:l10n_test:testOnly')
              .where((edge) => edge.kind == EdgeKind.references),
          isNotEmpty,
        );
      },
    );

    test(
      'freezes l10n isolated fingerprints against the full adapter subset',
      () async {
        final root = await _createReachabilityFixture(
          completeTestEnvironment: true,
        );
        addTearDown(() => root.delete(recursive: true));
        final project = await _loadCompleteProject(root);

        final full = await ProjectAnalyzer(project: project).analyze();
        final isolated = await ProjectAnalyzer(
          project: project,
          only: {'l10n'},
        ).analyze();

        const expectedFingerprints = <String>[
          'l10n:l10n_test:deadOnly\u0000l10n\u0000PRN-L10N-001\u0000REVIEW\u0000false',
        ];
        const expectedContexts = {
          'app:test': RootDomain.configuredTarget,
          'aux:test:test/localizations_test.dart:vm': RootDomain.auxiliary,
        };

        _expectNoDanglingEndpointsForEveryExecutionContext(
          full.graph,
          project,
          expectedContexts: expectedContexts,
        );
        _expectNoDanglingEndpointsForEveryExecutionContext(
          isolated.graph,
          project,
          expectedContexts: expectedContexts,
        );
        expect(isolated.adapterIds, ['dart', 'l10n']);
        expect(isolated.findings, hasLength(expectedFingerprints.length));
        expect(
          isolated.findings.every(
            (finding) => finding.reportingAdapterId == 'l10n',
          ),
          isTrue,
        );
        expect(
          _findingFingerprints(isolated.findings, project),
          expectedFingerprints,
        );
        expect(
          _findingFingerprints(
            isolated.findings.where(
              (finding) => finding.reportingAdapterId == 'l10n',
            ),
            project,
          ),
          expectedFingerprints,
        );
        expect(
          _findingFingerprints(
            full.findings.where(
              (finding) => finding.reportingAdapterId == 'l10n',
            ),
            project,
          ),
          _findingFingerprints(isolated.findings, project),
        );
        expect(
          isolated.findings.every(
            (finding) =>
                finding.confidence == Confidence.review &&
                finding.proposedAction == null &&
                !ModeApplyPolicy.allows(project.analysisMode, finding),
          ),
          isTrue,
        );
      },
    );

    test('blocks an inexact auxiliary l10n usage scope', () async {
      final root = await _createReachabilityFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);
      final workspace = DartAnalysisWorkspace(project);
      final contexts = await DefaultDartExecutionContextService(
        workspace: workspace,
      ).resolve(project);
      final snapshot = await DefaultDartExecutionReachabilityService(
        workspace: workspace,
        contexts: contexts,
      ).resolve(project);
      final incompleteTest = contexts.auxiliaryExecutionTargets.singleWhere(
        (target) => target.id.contains('test'),
      );
      final graph = ReachabilityGraph();
      final services = AdapterServices(
        dartWorkspace: workspace,
        dartExecutionContextService: _ThrowingExecutionContextService(),
        dartExecutionReachabilityService: _RecordingReachabilityService(
          snapshot,
        ),
      );

      expect(incompleteTest.environmentComplete, isFalse);
      expect(snapshot.auxiliaryProvenUnitPaths[incompleteTest.id], isEmpty);
      expect(
        snapshot.auxiliaryRetainedUnitPaths[incompleteTest.id]!.map(p.basename),
        contains('localizations_test.dart'),
      );

      await const DartAdapter().analyzeWithServices(
        project,
        GraphBuilder(graph, 'dart'),
        services,
      );
      await const L10nAdapter().analyzeWithServices(
        project,
        GraphBuilder(graph, 'l10n'),
        services,
      );

      expect(
        graph.blockers
            .where((blocker) => blocker.producer == 'l10n')
            .map((blocker) => blocker.reason),
        contains(contains('test-environment-incomplete')),
      );
      final findings = const FindingGenerator().generate(
        graph: graph,
        project: project,
        graphIntegrity: graph.integrityFor(project.targets),
        reportingNodeSchemes: const {'l10n'},
        adapterReportDefinitions: {
          'l10n': const L10nAdapter().reportDefinition,
        },
      );
      final testOnly = findings.singleWhere(
        (finding) => finding.node.metadata['key'] == 'testOnly',
      );
      final deadOnly = findings.singleWhere(
        (finding) => finding.node.metadata['key'] == 'deadOnly',
      );
      expect(testOnly.confidence, Confidence.review);
      expect(testOnly.proposedAction, isNull);
      expect(testOnly.predicates.notRetained, isFalse);
      expect(testOnly.auxiliaryRetainedIn, [incompleteTest.id]);
      expect(
        deadOnly.blockers.map((blocker) => blocker.reason),
        isNot(contains(contains('test-environment-incomplete'))),
      );
      expect(
        testOnly.blockers.map((blocker) => blocker.reason),
        contains(
          allOf(
            contains('test-environment-incomplete'),
            contains(incompleteTest.id),
          ),
        ),
      );
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
      expect(const L10nAdapter().reportDefinition.adapterId, 'l10n');
      expect(
        const L10nAdapter().reportDefinition.findings.single.ruleId,
        'PRN-L10N-001',
      );
    });

    test('l10n-only analysis shares Dart support end to end', () async {
      final root = await _createReachabilityFixture(
        completeTestEnvironment: true,
      );
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);

      final snapshot = await ProjectAnalyzer(
        project: project,
        only: {'l10n'},
      ).analyze();

      expect(snapshot.adapterIds, ['dart', 'l10n']);
      expect(snapshot.graph.danglingEdgesFor(project.targets), isEmpty);
      expect(snapshot.graph.danglingRootIdsFor(project.targets), isEmpty);
      expect(snapshot.findings, isNotEmpty);
      expect(
        snapshot.findings.every(
          (finding) =>
              finding.node.kind == NodeKind.localizationKey &&
              finding.reportingAdapterId == 'l10n' &&
              finding.ruleId == 'PRN-L10N-001' &&
              finding.confidence != Confidence.safe &&
              finding.confidence != Confidence.high &&
              finding.proposedAction == null,
        ),
        isTrue,
      );
      expect(snapshot.adapterRuns.map((run) => '${run.id}:${run.role.name}'), [
        'dart:support',
        'l10n:reporting',
      ]);
    });

    test(
      'scan --adapter l10n expands Dart support and emits no actions',
      () async {
        final root = await _createReachabilityFixture(
          completeTestEnvironment: true,
        );
        addTearDown(() => root.delete(recursive: true));
        final config = File(
          p.join(root.path, '.flutter_pruner', 'config.yaml'),
        );
        config.parent.createSync(recursive: true);
        config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
        final output = File(p.join(root.path, 'l10n-scan.json'));

        final exitCode = await FlutterPrunerCommandRunner().run([
          'scan',
          '--adapter',
          'l10n',
          '--format',
          'json',
          '--output',
          output.path,
          root.path,
        ]);

        expect(exitCode, 0);
        final report =
            jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
        final execution = report['execution'] as Map<String, Object?>;
        final pass =
            (execution['analysisPasses'] as List<Object?>).single
                as Map<String, Object?>;
        final adapters = (pass['adapters'] as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(adapters.map((adapter) => adapter['id']), ['dart', 'l10n']);
        expect(adapters.map((adapter) => adapter['role']), [
          'support',
          'reporting',
        ]);
        expect(
          adapters.map((adapter) => adapter['id']),
          isNot(contains('get_it')),
        );
        final graph = pass['graph'] as Map<String, Object?>;
        expect(graph['danglingEdges'], 0);
        expect(graph['danglingRoots'], 0);
        final presentation = report['presentation'] as Map<String, Object?>;
        final definitions = (presentation['adapters'] as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(definitions.map((definition) => definition['id']), [
          'dart',
          'l10n',
        ]);
        final definition = definitions.singleWhere(
          (definition) => definition['id'] == 'l10n',
        );
        expect(definition['id'], 'l10n');
        final findingDefinition =
            (definition['findings'] as List<Object?>).single
                as Map<String, Object?>;
        expect(findingDefinition['ruleId'], 'PRN-L10N-001');
        final findings = (report['findings'] as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(findings, isNotEmpty);
        expect(
          findings.every(
            (finding) =>
                finding['reportingAdapterId'] == 'l10n' &&
                finding['ruleId'] == 'PRN-L10N-001' &&
                finding['confidence'] == 'REVIEW' &&
                finding['applyEligible'] == false &&
                !finding.containsKey('proposedAction'),
          ),
          isTrue,
        );
      },
    );
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
  await File(p.join(root.path, 'lib/main.dart')).writeAsString('''
import 'constructor_consumer.dart';
import 'consumer.dart';
import 'custom_lookup.dart';
import 'l10n/app_localizations.dart';
import 'reexport_consumer.dart';

void main() {
  Localizer(const AppLocalizations()).direct();
  ConstructsLocalizations();
  constantLookup(const AppLocalizations());
  throughExport(const AppLocalizations());
}
''');
  await _writePackageConfig(root);
  return root;
}

Future<Directory> _createReachabilityFixture({
  bool completeTestEnvironment = false,
}) async {
  final root = await Directory.systemTemp.createTemp('l10n_reachability_');
  await Directory(p.join(root.path, 'lib/l10n')).create(recursive: true);
  await Directory(p.join(root.path, 'test')).create(recursive: true);
  await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: l10n_test
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''');
  await File(p.join(root.path, 'l10n.yaml')).writeAsString('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
''');
  if (completeTestEnvironment) {
    await File(
      p.join(root.path, 'dart_test.yaml'),
    ).writeAsString('platforms: [vm]\n');
  }
  for (final locale in const ['en', 'vi']) {
    await File(p.join(root.path, 'lib/l10n/app_$locale.arb')).writeAsString('''
{
  "@@locale": "$locale",
  "live": "Live",
  "deadOnly": "Dead",
  "testOnly": "Test"
}
''');
  }
  await File(
    p.join(root.path, 'lib/l10n/app_localizations.dart'),
  ).writeAsString('''
class AppLocalizations {
  const AppLocalizations();

  String get live => 'Live';
  String get deadOnly => 'Dead';
  String get testOnly => 'Test';
}
''');
  await File(p.join(root.path, 'lib/main.dart')).writeAsString('''
import 'reachable.dart';

void main() => useLive();
''');
  await File(p.join(root.path, 'lib/reachable.dart')).writeAsString('''
import 'l10n/app_localizations.dart';

String useLive() => const AppLocalizations().live;
''');
  await File(p.join(root.path, 'lib/unreachable.dart')).writeAsString('''
import 'l10n/app_localizations.dart';

String useDead(AppLocalizations localizations) => localizations.deadOnly;
''');
  await File(p.join(root.path, 'test/localizations_test.dart')).writeAsString(
    '''
import '../lib/l10n/app_localizations.dart';

void main() {
  const AppLocalizations().testOnly;
}
''',
  );
  await _writePackageConfig(root);
  return root;
}

Future<void> _writePackageConfig(Directory root) async {
  final file = File(p.join(root.path, '.dart_tool', 'package_config.json'));
  await file.parent.create(recursive: true);
  await file.writeAsString('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
}

final class _RecordingReachabilityService
    implements DartExecutionReachabilityService {
  _RecordingReachabilityService(this.snapshot);

  final DartExecutionReachabilitySnapshot snapshot;
  final List<DartExecutionReachabilitySnapshot> observed = [];
  int resolveCalls = 0;

  @override
  Future<DartExecutionReachabilitySnapshot> resolve(
    ProjectContext project,
  ) async {
    resolveCalls++;
    observed.add(snapshot);
    return snapshot;
  }
}

final class _ThrowingExecutionContextService
    implements DartExecutionContextService {
  int resolveCalls = 0;

  @override
  Future<DartExecutionContextSnapshot> resolve(ProjectContext project) async {
    resolveCalls++;
    throw StateError('independent execution-context discovery must not run');
  }
}

void _expectNoDanglingEndpointsForEveryExecutionContext(
  ReachabilityGraph graph,
  ProjectContext project, {
  required Map<String, RootDomain> expectedContexts,
}) {
  final integrity = graph.integrityFor(project.targets);
  expect({
    for (final entry in integrity.byExecutionTarget.entries)
      entry.key: entry.value.domain,
  }, expectedContexts);
  expect(integrity.danglingEdges, isEmpty);
  expect(integrity.danglingRootIds, isEmpty);
  expect(integrity.unattributedDanglingEdges, isEmpty);
  expect(integrity.unattributedDanglingRootIds, isEmpty);
  for (final context in integrity.byExecutionTarget.values) {
    expect(context.danglingEdges, isEmpty, reason: context.id);
    expect(context.danglingRootIds, isEmpty, reason: context.id);
  }
}

List<String> _findingFingerprints(
  Iterable<Finding> findings,
  ProjectContext project,
) =>
    findings
        .map(
          (finding) => [
            finding.node.id,
            finding.reportingAdapterId,
            finding.ruleId,
            finding.confidence.label,
            ModeApplyPolicy.allows(project.analysisMode, finding),
          ].join('\u0000'),
        )
        .toList()
      ..sort();

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
    graphIntegrity: graph.integrityFor(project.targets),
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
