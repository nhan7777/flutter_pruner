import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import '../dart/dart_analysis_workspace.dart';
import '../dart/dart_application_reachability.dart';
import '../dart/dart_execution_context_service.dart';
import '../dart/dart_execution_reachability_service.dart';
import 'deep_link_probe.dart';
import 'route_inventory.dart';
import 'route_reference_resolver.dart';

/// Analyzes `go_router` route declarations and navigation.
///
/// Dynamic locations and external entry channels produce scoped blockers.
/// Route removal has no mechanical inverse, so route findings remain
/// review-only.
class GoRouterAdapter extends AnalyzerAdapter {
  /// Creates a go_router adapter.
  const GoRouterAdapter();

  @override
  String get id => 'go_router';

  @override
  String get name => 'Route analyzer (go_router)';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'go_router',
    displayName: 'Route analyzer (go_router)',
    description:
        'Finds declared go_router routes with no observed navigation path.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.route,
        ruleId: 'PRN-ROUTE-001',
        title: 'Unused route',
        nodeLabel: 'Route',
        description:
            'A declared route with no resolved navigation from the roots.',
        details: [
          AdapterReportDetailDefinition(
            key: 'path',
            label: 'Route path',
            valueType: AdapterReportDetailValueType.text,
            description: 'Full path composed from every enclosing route.',
          ),
          AdapterReportDetailDefinition(
            key: 'routeName',
            label: 'Route name',
            valueType: AdapterReportDetailValueType.text,
            description: 'Declared name used by named navigation.',
          ),
          AdapterReportDetailDefinition(
            key: 'declaredAt',
            label: 'Declared at',
            valueType: AdapterReportDetailValueType.text,
            description: 'Source location of the route declaration.',
          ),
          AdapterReportDetailDefinition(
            key: 'externallyAddressable',
            label: 'Reachable externally',
            valueType: AdapterReportDetailValueType.boolean,
            description:
                'Whether a platform or web channel can deliver a route URI.',
          ),
        ],
      ),
    ],
  );

  @override
  Set<String> get findingNodeSchemes => const {'route'};

  @override
  List<String> get dependsOn => const ['dart'];

  @override
  bool appliesTo(ProjectContext project) => project.hasDependency('go_router');

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    final workspace = DartAnalysisWorkspace(project);
    final contexts = await DefaultDartExecutionContextService(
      workspace: workspace,
    ).resolve(project);
    await _analyze(
      project,
      graph,
      workspace,
      DefaultDartExecutionReachabilityService(
        workspace: workspace,
        contexts: contexts,
      ),
    );
  }

  @override
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) async {
    final workspace = services.dartWorkspace ?? DartAnalysisWorkspace(project);
    final reachabilityService =
        services.dartExecutionReachabilityService ??
        DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts:
              await (services.dartExecutionContextService ??
                      DefaultDartExecutionContextService(workspace: workspace))
                  .resolve(project),
        );
    await _analyze(project, graph, workspace, reachabilityService);
  }

  Future<void> _analyze(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
    DartExecutionReachabilityService reachabilityService,
  ) async {
    final inventory = await RouteInventory.discover(
      project,
      workspace: workspace,
    );
    final applicationReachability = DartApplicationReachability.fromSnapshot(
      await reachabilityService.resolve(project),
    );
    final resolver = RouteReferenceResolver(project, inventory);
    await resolver.analyzeProject(
      workspace: workspace,
      includedUnitPaths: applicationReachability.globalUsageUnitPaths,
    );
    final deepLinks = DeepLinkProbe.detect(project);

    for (final entry in inventory.byNodeId.values) {
      graph.addNode(
        GraphNode(
          id: entry.nodeId,
          kind: NodeKind.route,
          origin: entry.origin,
          displayName: entry.fullPath,
          metadata: {
            'path': entry.fullPath,
            if (entry.name != null) 'routeName': entry.name,
            'declaredAt': entry.location,
            'externallyAddressable': deepLinks.enabled,
          },
        ),
      );
    }

    for (final reference in resolver.references) {
      graph.addReference(
        from: reference.callerId,
        to: reference.routeNodeId,
        kind: EdgeKind.navigatesTo,
        evidence: graph.evidence(
          kind: EvidenceKind.constString,
          description: reference.description,
          exact: true,
          location: reference.location,
        ),
      );
      final sourcePath = _sourcePathFromLocation(project, reference.location);
      if (sourcePath == null) continue;
      for (final entry
          in applicationReachability.auxiliaryContextIssues.entries) {
        final retained =
            applicationReachability.auxiliaryRetainedUnitPaths[entry.key];
        final proven =
            applicationReachability.auxiliaryProvenUnitPaths[entry.key];
        if (retained == null ||
            !retained.contains(sourcePath) ||
            (proven?.contains(sourcePath) ?? false)) {
          continue;
        }
        for (final issue in entry.value) {
          graph.addBlocker(
            reason: '${issue.code} [${entry.key}]: ${issue.reason}',
            location: reference.location,
            sourceNodeId: reference.callerId,
            affectedNodeIds: {reference.routeNodeId},
          );
        }
      }
    }

    for (final entry in inventory.byNodeId.values) {
      final parentNodeId = entry.parentNodeId;
      if (parentNodeId == null) continue;
      graph.addReference(
        from: entry.nodeId,
        to: parentNodeId,
        kind: EdgeKind.references,
        evidence: graph.evidence(
          kind: EvidenceKind.configuration,
          description: 'child route requires its enclosing route',
          exact: true,
          location: entry.location,
        ),
      );
    }

    for (final blocker in [...inventory.blockers, ...resolver.blockers]) {
      graph.addBlocker(
        reason: blocker.reason,
        location: blocker.location,
        sourceNodeId: blocker.sourceNodeId,
        affectedNamespace: blocker.affectedNamespace,
        affectedNodeIds: blocker.affectedNodeIds,
      );
    }
    for (final issue in applicationReachability.issues) {
      graph.addBlocker(
        reason: issue,
        affectedNamespace: RouteInventory.namespaceFor(project),
      );
    }

    if (deepLinks.enabled) {
      graph.addBlocker(
        reason:
            'an external route channel can activate any route without an '
            'in-app caller',
        location: deepLinks.sources.first,
        affectedNamespace: RouteInventory.namespaceFor(project),
      );
    }
  }
}

String? _sourcePathFromLocation(ProjectContext project, String location) {
  final columnSeparator = location.lastIndexOf(':');
  final lineSeparator = columnSeparator <= 0
      ? -1
      : location.lastIndexOf(':', columnSeparator - 1);
  if (lineSeparator <= 0) return null;
  final source = project.resolve(location.substring(0, lineSeparator));
  final absolute = p.normalize(p.absolute(source));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}
