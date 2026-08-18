import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/go_router/go_router_adapter.dart';
import 'package:flutter_pruner/src/adapters/go_router/route_inventory.dart';
import 'package:flutter_pruner/src/adapters/go_router/route_reference_resolver.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/go_router_test')));

void main() {
  group('RouteInventory', () {
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
  });

  group('RouteReferenceResolver', () {
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
      expect(findings.first.ruleId, 'PRN-ROUTE-001');
    });

    test(
      'adds no dangling edges that would downgrade other adapters',
      () async {
        final project = await loadFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GoRouterAdapter().analyze(
          project,
          GraphBuilder(graph, 'go_router'),
        );

        expect(graph.danglingEdgesFor(project.targets), isEmpty);
      },
    );

    test('applies only to projects that depend on go_router', () async {
      final project = await loadFixture();

      expect(const GoRouterAdapter().appliesTo(project), isTrue);
      expect(const GoRouterAdapter().dependsOn, ['dart']);
    });
  });
}
