import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/adapters/go_router/go_router_adapter.dart';
import 'package:flutter_pruner/src/adapters/go_router/route_inventory.dart';
import 'package:flutter_pruner/src/adapters/go_router/route_reference_resolver.dart';
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
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/go_router_test')));

void main() {
  group('RouteInventory', () {
    test(
      'discovers routes declared in a re-exported go_router sublibrary',
      () async {
        final project = await loadFixture();
        final inventory = await RouteInventory.discover(
          project,
          workspace: DartAnalysisWorkspace(project),
        );

        expect(inventory.byNodeId, contains('route:go_router_test:/settings'));
      },
    );

    test('composes full paths for nested and top-level routes', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      expect(inventory.byNodeId.values.map((entry) => entry.fullPath).toSet(), {
        '/',
        '/details',
        '/orphan',
        '/dead',
        '/settings',
        '/shell-child',
        '/flags/:code',
        '/duplicate-path',
        '/duplicate-name-one',
        '/duplicate-name-two',
        '/signup',
        '/search',
        '/guides',
        '/guides/faq',
        '/login',
      });
    });

    test('indexes routes that declare a name', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      expect(
        inventory.nodeIdByNameKey['route:go_router_test:#name=details'],
        'route:go_router_test:/details',
      );
      expect(
        inventory.nodeIdByNameKey.containsKey(
          'route:go_router_test:#name=orphan',
        ),
        isFalse,
      );
    });

    test('records a project-relative origin and location', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      final dead = inventory.byNodeId['route:go_router_test:/dead']!;
      expect(project.relative(dead.origin.toFilePath()), 'lib/main.dart');
      expect(dead.location, startsWith('lib/main.dart:'));
    });

    test(
      'preserves the first duplicate path and blocks the route namespace',
      () async {
        final project = await loadFixture();
        final inventory = await RouteInventory.discover(
          project,
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          inventory.byNodeId['route:go_router_test:/duplicate-path']!.name,
          'duplicatePathFirst',
        );
        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains('duplicate route path cannot be represented independently'),
        );
        expect(
          inventory.blockers
              .where(
                (blocker) =>
                    blocker.reason ==
                    'duplicate route path cannot be represented independently',
              )
              .single
              .affectedNamespace,
          'route:go_router_test:',
        );
      },
    );

    test('removes an ambiguous route name from the exact index', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      final duplicateNameKey = 'route:go_router_test:#name=duplicate';
      expect(inventory.nodeIdByNameKey, isNot(contains(duplicateNameKey)));
      final duplicateName = inventory.blockers.singleWhere(
        (blocker) => blocker.reason == 'duplicate route name is ambiguous',
      );
      expect(duplicateName.affectedNodeIds, {
        'route:go_router_test:/duplicate-name-one',
        'route:go_router_test:/duplicate-name-two',
      });
    });
  });

  group('RouteReferenceResolver', () {
    test(
      'resolves navigation declared in a re-exported go_router sublibrary',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        expect(
          resolver.references.map((reference) => reference.routeNodeId),
          contains('route:go_router_test:/settings'),
        );
      },
    );

    test('resolves a constant path to an exact reference', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      final settings = resolver.references.where(
        (reference) =>
            reference.routeNodeId == 'route:go_router_test:/settings',
      );
      expect(settings, hasLength(1));
      expect(settings.first.callerId, endsWith('lib/main.dart#openSettings'));
    });

    test('resolves named navigation through the name index', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.references.map((reference) => reference.routeNodeId),
        contains('route:go_router_test:/details'),
      );
    });

    test(
      'resolves query-bearing and parameterized constant locations',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        expect(
          resolver.references.map((reference) => reference.routeNodeId),
          containsAll({
            'route:go_router_test:/settings',
            'route:go_router_test:/flags/:code',
          }),
        );
      },
    );

    test('never reports a reference for an undeclared route', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.references.every(
          (reference) => inventory.byNodeId.containsKey(reference.routeNodeId),
        ),
        isTrue,
      );
    });

    test(
      'does not create an exact reference for an ambiguous route name',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        expect(
          resolver.references
              .map((reference) => reference.callerId)
              .where((callerId) => callerId.endsWith('#openAmbiguousName')),
          isEmpty,
        );
      },
    );

    test('scopes an interpolated location to matching routes', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      final scoped = resolver.blockers.singleWhere(
        (blocker) => blocker.reason.contains('partially known'),
      );
      expect(scoped.affectedNodeIds, {'route:go_router_test:/flags/:code'});
      expect(scoped.affectedNamespace, isNull);
    });

    test('an opaque location blocks the whole route namespace', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      final opaque = resolver.blockers.singleWhere(
        (blocker) => blocker.reason.contains('not a constant'),
      );
      expect(opaque.affectedNamespace, 'route:go_router_test:');
      expect(opaque.sourceNodeId, endsWith('lib/main.dart#openOpaque'));
    });

    test(
      'blocks navigation through a dynamic receiver without recording liveness',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        final dynamicPath = resolver.blockers.singleWhere(
          (blocker) =>
              blocker.sourceNodeId?.endsWith('lib/main.dart#openDynamicPath') ??
              false,
        );
        expect(dynamicPath.affectedNodeIds, {'route:go_router_test:/settings'});
        final dynamicName = resolver.blockers.singleWhere(
          (blocker) =>
              blocker.sourceNodeId?.endsWith('lib/main.dart#openDynamicName') ??
              false,
        );
        expect(dynamicName.affectedNodeIds, {'route:go_router_test:/details'});
        final dynamicOpaque = resolver.blockers.singleWhere(
          (blocker) =>
              blocker.sourceNodeId?.endsWith(
                'lib/main.dart#openDynamicOpaque',
              ) ??
              false,
        );
        expect(dynamicOpaque.affectedNamespace, 'route:go_router_test:');
        final dynamicCascade = resolver.blockers.singleWhere(
          (blocker) =>
              blocker.sourceNodeId?.endsWith(
                'lib/main.dart#openDynamicCascade',
              ) ??
              false,
        );
        expect(dynamicCascade.affectedNodeIds, {
          'route:go_router_test:/settings',
        });
        final dynamicNullShortingCascade = resolver.blockers.singleWhere(
          (blocker) =>
              blocker.sourceNodeId?.endsWith(
                'lib/main.dart#openDynamicNullShortingCascade',
              ) ??
              false,
        );
        expect(dynamicNullShortingCascade.affectedNodeIds, {
          'route:go_router_test:/details',
        });
        expect(
          resolver.references
              .map((reference) => reference.callerId)
              .where((callerId) => callerId.contains('#openDynamic')),
          isEmpty,
        );
      },
    );

    test(
      'ignores a resolved local API with a navigation method name',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        expect(
          resolver.references
              .map((reference) => reference.callerId)
              .where((callerId) => callerId.endsWith('#openLocalNavigation')),
          isEmpty,
        );
        expect(
          resolver.blockers
              .map((blocker) => blocker.sourceNodeId)
              .where(
                (callerId) =>
                    callerId?.endsWith('#openLocalNavigation') ?? false,
              ),
          isEmpty,
        );
      },
    );

    test(
      'traces a local wrapper parameter through static route producers',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);
        final inventory = await RouteInventory.discover(
          project,
          workspace: workspace,
        );
        final resolver = RouteReferenceResolver(project, inventory);

        await resolver.analyzeProject(workspace: workspace);

        final wrapperReferences = resolver.references
            .where(
              (reference) => reference.callerId.endsWith('#openThroughWrapper'),
            )
            .map((reference) => reference.routeNodeId)
            .toSet();
        expect(wrapperReferences, {
          'route:go_router_test:/signup',
          'route:go_router_test:/guides/faq',
          'route:go_router_test:/search',
        });
      },
    );

    test('resolves route paths returned from redirect callbacks', () async {
      final project = await loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await RouteInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = RouteReferenceResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.references
            .where(
              (reference) =>
                  reference.description.contains('redirects to') &&
                  reference.routeNodeId == 'route:go_router_test:/signup',
            )
            .length,
        1,
      );
    });
  });

  group('GoRouterAdapter', () {
    test('reports a route with no navigation call site', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(graph.hasNode('route:go_router_test:/dead'), isTrue);
      expect(graph.incomingTo('route:go_router_test:/dead'), isEmpty);
    });

    test('retains routes reached by constant navigation', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(graph.incomingTo('route:go_router_test:/settings'), isNotEmpty);
      expect(graph.incomingTo('route:go_router_test:/details'), isNotEmpty);
    });

    test('models navigation as an edge rather than a root', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(graph.rootIds, isNot(contains('route:go_router_test:/settings')));
    });

    test('keeps parent routes alive through a reachable child route', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(
        graph
            .outgoingFrom('route:go_router_test:/guides/faq')
            .map((edge) => edge.to),
        contains('route:go_router_test:/guides'),
      );
    });

    test('dynamic navigation blocks routes instead of deleting them', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(
        graph.blockersFor('route:go_router_test:/dead'),
        isNotEmpty,
        reason: 'an opaque navigation argument could address any route',
      );
      expect(
        graph.blockersFor('route:go_router_test:/flags/:code'),
        isNotEmpty,
      );
      expect(
        graph
            .blockersFor('route:go_router_test:/settings')
            .map((blocker) => blocker.reason),
        contains(
          'navigation receiver has dynamic type and cannot be resolved as '
          'go_router',
        ),
      );
    });

    test('route findings never reach SAFE or HIGH', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      final findings = const FindingGenerator().generate(
        graph: graph,
        project: project,
        graphIntegrity: graph.integrityFor(project.targets),
        reportingNodeSchemes: const {'route'},
      );

      expect(findings, isNotEmpty);
      expect(
        findings.every(
          (finding) =>
              finding.confidence == Confidence.review ||
              finding.confidence == Confidence.protected,
        ),
        isTrue,
      );
      expect(
        findings.every((finding) => finding.proposedAction == null),
        isTrue,
      );
      expect(
        findings.every(
          (finding) =>
              finding.reportingAdapterId == 'go_router' &&
              finding.ruleId == 'PRN-ROUTE-001',
        ),
        isTrue,
      );
    });

    test('adds no dangling edges that would downgrade other adapters', () async {
      final project = await loadFixture();
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      await const GoRouterAdapter().analyze(
        project,
        GraphBuilder(graph, 'go_router'),
      );

      expect(graph.danglingEdgesFor(project.targets), isEmpty);
      expect(
        graph
            .blockersFor('route:go_router_test:/dead')
            .map((blocker) => blocker.reason),
        contains(
          'navigation occurs in a source unit not modeled by the Dart adapter',
        ),
      );
    });

    test('applies only to projects that depend on go_router', () async {
      final project = await loadFixture();

      expect(const GoRouterAdapter().appliesTo(project), isTrue);
      expect(const GoRouterAdapter().dependsOn, ['dart']);
      expect(const GoRouterAdapter().reportDefinition.adapterId, 'go_router');
    });

    test(
      'shares Dart reachability and retains an exact auxiliary route use',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        final mainFile = File(p.join(root.path, 'lib/main.dart'));
        mainFile.writeAsStringSync(
          mainFile.readAsStringSync().replaceFirst(
            "    GoRoute(path: '/login'),",
            "    GoRoute(path: '/login'),\n"
                "    GoRoute(path: '/test-only'),",
          ),
        );
        File(
          p.join(root.path, 'dart_test.yaml'),
        ).writeAsStringSync('platforms: [vm]\n');
        final testFile = File(p.join(root.path, 'test/router_test.dart'));
        testFile.parent.createSync(recursive: true);
        testFile.writeAsStringSync('''
import 'package:go_router/go_router.dart';

void main() => const BuildContext().go('/test-only');
''');
        final project = await ProjectContext.load(
          root,
          targets: [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
        );
        final workspace = DartAnalysisWorkspace(project);
        final contexts = await DefaultDartExecutionContextService(
          workspace: workspace,
        ).resolve(project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        ).resolve(project);
        final reachability = _RecordingReachabilityService(snapshot);
        final throwingContexts = _ThrowingExecutionContextService();
        final services = AdapterServices(
          dartWorkspace: workspace,
          dartExecutionContextService: throwingContexts,
          dartExecutionReachabilityService: reachability,
        );
        final graph = ReachabilityGraph();

        await const DartAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          services,
        );
        final dartFingerprint = reachability.observed.single.fingerprint;
        await const GoRouterAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'go_router'),
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
            'app:android': RootDomain.configuredTarget,
            'aux:test:test/router_test.dart:vm': RootDomain.auxiliary,
          },
        );
        expect(
          graph
              .incomingTo('route:go_router_test:/test-only')
              .map((edge) => edge.from),
          contains('dart:go_router_test/test/router_test.dart#main'),
        );
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'route'},
          adapterReportDefinitions: {
            'go_router': const GoRouterAdapter().reportDefinition,
          },
        );
        expect(
          findings.map((finding) => finding.node.id),
          isNot(contains('route:go_router_test:/test-only')),
        );
      },
    );

    test('freezes target-matrix route references and isolated fingerprints', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await ProjectContext.load(
        root,
        targets: [
          BuildTarget(
            name: 'android-prod',
            platform: 'android',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'FLAVOR': 'prod'},
          ),
          BuildTarget(
            name: 'web-staging',
            platform: 'web',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'FLAVOR': 'staging'},
          ),
        ],
      );

      final full = await ProjectAnalyzer(project: project).analyze();
      final isolated = await ProjectAnalyzer(
        project: project,
        only: {'go_router'},
      ).analyze();

      const expectedNavigationTuples = <String>[
        'dart:go_router_test/lib/main.dart#openDetails\u0000route:go_router_test:/details\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openFlag\u0000route:go_router_test:/flags/:code\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openHome\u0000route:go_router_test:/\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openSettings\u0000route:go_router_test:/settings\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openThroughWrapper\u0000route:go_router_test:/guides/faq\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openThroughWrapper\u0000route:go_router_test:/search\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#openThroughWrapper\u0000route:go_router_test:/signup\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
        'dart:go_router_test/lib/main.dart#router\u0000route:go_router_test:/signup\u0000navigatesTo\u0000true\u0000BuildCondition(any)',
      ];
      const expectedRouteFingerprints = <String>[
        'route:go_router_test:/\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/dead\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/details\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/duplicate-name-one\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/duplicate-name-two\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/duplicate-path\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/flags/:code\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/guides\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/guides/faq\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/login\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/orphan\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/search\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/settings\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/shell-child\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
        'route:go_router_test:/signup\u0000go_router\u0000PRN-ROUTE-001\u0000REVIEW\u0000false',
      ];
      const expectedContexts = {
        'app:android-prod': RootDomain.configuredTarget,
        'app:web-staging': RootDomain.configuredTarget,
      };

      final navigation = full.graph.edges
          .where((edge) => edge.kind == EdgeKind.navigatesTo)
          .toList(growable: false);
      expect(_navigationEdgeTuples(full.graph), expectedNavigationTuples);
      expect(_navigationEdgeTuples(isolated.graph), expectedNavigationTuples);
      for (final target in project.targets) {
        expect(
          navigation.every((edge) => edge.condition.appliesTo(target)),
          isTrue,
          reason: target.name,
        );
      }
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
      expect(isolated.adapterIds, ['dart', 'go_router']);
      expect(isolated.findings, hasLength(expectedRouteFingerprints.length));
      expect(
        isolated.findings.every(
          (finding) => finding.reportingAdapterId == 'go_router',
        ),
        isTrue,
      );
      expect(
        _findingFingerprints(isolated.findings, project),
        expectedRouteFingerprints,
      );
      expect(
        _findingFingerprints(
          isolated.findings.where(
            (finding) => finding.reportingAdapterId == 'go_router',
          ),
          project,
        ),
        expectedRouteFingerprints,
      );
      expect(
        _findingFingerprints(
          full.findings.where(
            (finding) => finding.reportingAdapterId == 'go_router',
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
    });

    test(
      'scopes an incomplete auxiliary issue to its retained route',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        final mainFile = File(p.join(root.path, 'lib/main.dart'));
        mainFile.writeAsStringSync(
          mainFile.readAsStringSync().replaceFirst(
            "    GoRoute(path: '/login'),",
            "    GoRoute(path: '/login'),\n"
                "    GoRoute(path: '/test-only'),",
          ),
        );
        final testFile = File(p.join(root.path, 'test/router_test.dart'));
        testFile.parent.createSync(recursive: true);
        testFile.writeAsStringSync('''
import 'package:go_router/go_router.dart';

void main() => const BuildContext().go('/test-only');
''');
        final project = await ProjectContext.load(
          root,
          targets: [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
        );
        final workspace = DartAnalysisWorkspace(project);
        final contexts = await DefaultDartExecutionContextService(
          workspace: workspace,
        ).resolve(project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        ).resolve(project);
        final incompleteTest = contexts.auxiliaryExecutionTargets.singleWhere(
          (target) => target.id.contains('router_test'),
        );
        final graph = ReachabilityGraph();
        final services = AdapterServices(
          dartWorkspace: workspace,
          dartExecutionContextService: _ThrowingExecutionContextService(),
          dartExecutionReachabilityService: _RecordingReachabilityService(
            snapshot,
          ),
        );

        await const DartAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          services,
        );
        await const GoRouterAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'go_router'),
          services,
        );

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'route'},
          adapterReportDefinitions: {
            'go_router': const GoRouterAdapter().reportDefinition,
          },
        );
        final testOnly = findings.singleWhere(
          (finding) => finding.node.id == 'route:go_router_test:/test-only',
        );
        final dead = findings.singleWhere(
          (finding) => finding.node.id == 'route:go_router_test:/dead',
        );
        expect(incompleteTest.environmentComplete, isFalse);
        expect(testOnly.confidence, Confidence.review);
        expect(testOnly.proposedAction, isNull);
        expect(testOnly.predicates.notRetained, isFalse);
        expect(testOnly.auxiliaryRetainedIn, [incompleteTest.id]);
        expect(
          dead.blockers.map((blocker) => blocker.reason),
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
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
      },
    );

    test('route-only analysis runs Dart as support end to end', () async {
      final project = await loadFixture();

      final snapshot = await ProjectAnalyzer(
        project: project,
        only: {'go_router'},
      ).analyze();

      expect(snapshot.adapterIds, ['dart', 'go_router']);
      expect(snapshot.graph.danglingEdgesFor(project.targets), isEmpty);
      expect(snapshot.findings, isNotEmpty);
      expect(
        snapshot.findings.every(
          (finding) =>
              finding.node.kind == NodeKind.route &&
              finding.reportingAdapterId == 'go_router',
        ),
        isTrue,
      );
      expect(snapshot.adapterRuns.map((run) => '${run.id}:${run.role.name}'), [
        'dart:support',
        'go_router:reporting',
      ]);
    });

    test(
      'scan --adapter go_router expands Dart support and emits no actions',
      () async {
        final root = await _copyFixture();
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
        final output = File(p.join(root.path, 'go-router-scan.json'));

        final exitCode = await FlutterPrunerCommandRunner().run([
          'scan',
          '--adapter',
          'go_router',
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
        expect(adapters.map((adapter) => adapter['id']), ['dart', 'go_router']);
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
          'go_router',
        ]);
        final definition = definitions.singleWhere(
          (definition) => definition['id'] == 'go_router',
        );
        expect(definition['id'], 'go_router');
        final findingDefinition =
            (definition['findings'] as List<Object?>).single
                as Map<String, Object?>;
        expect(findingDefinition['ruleId'], 'PRN-ROUTE-001');
        final findings = (report['findings'] as List<Object?>)
            .cast<Map<String, Object?>>();
        expect(findings, isNotEmpty);
        expect(
          findings.every(
            (finding) =>
                finding['reportingAdapterId'] == 'go_router' &&
                finding['ruleId'] == 'PRN-ROUTE-001' &&
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

Future<Directory> _copyFixture() async {
  final source = Directory(p.absolute('test/fixtures/go_router_test'));
  final root = await Directory.systemTemp.createTemp('go_router_adapter_');
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
  return root;
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

List<String> _navigationEdgeTuples(ReachabilityGraph graph) =>
    graph.edges
        .where((edge) => edge.kind == EdgeKind.navigatesTo)
        .map(
          (edge) => [
            edge.from,
            edge.to,
            edge.kind.name,
            edge.isExact,
            edge.condition,
          ].join('\u0000'),
        )
        .toList()
      ..sort();
