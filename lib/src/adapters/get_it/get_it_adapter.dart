import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import '../dart/dart_analysis_workspace.dart';
import 'di_identity.dart';
import 'di_inventory.dart';
import 'di_resolution_resolver.dart';
import 'generated_wiring_probe.dart';

/// Contributes conservative GetIt registration and consumption facts.
///
/// Registration setup alone is deliberately not liveness evidence. Only an
/// exact semantic lookup may keep a registration reachable; generated wiring
/// and runtime container behavior instead lower confidence through blockers.
class GetItAdapter extends AnalyzerAdapter {
  /// Creates a GetIt adapter.
  const GetItAdapter();

  @override
  String get id => 'get_it';

  @override
  String get name => 'Dependency injection analyzer (GetIt)';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: id,
    displayName: name,
    description:
        'Finds GetIt registrations with no exact observed service consumption.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.diRegistration,
        ruleId: 'PRN-DI-001',
        title: 'Unused DI registration',
        nodeLabel: 'DI registration',
        description:
            'A GetIt registration with no exact semantic lookup from reachable code.',
        details: [
          AdapterReportDetailDefinition(
            key: 'canonicalType',
            label: 'Service type',
            valueType: AdapterReportDetailValueType.text,
            description: 'Canonical analyzer-derived service type identity.',
          ),
          AdapterReportDetailDefinition(
            key: 'instanceNameState',
            label: 'Instance-name state',
            valueType: AdapterReportDetailValueType.text,
            description:
                'Whether the GetIt instance name is absent, constant, or dynamic.',
          ),
          AdapterReportDetailDefinition(
            key: 'instanceName',
            label: 'Instance name',
            valueType: AdapterReportDetailValueType.text,
            description: 'Constant GetIt instance name when one is declared.',
          ),
          AdapterReportDetailDefinition(
            key: 'registrationApi',
            label: 'Registration API',
            valueType: AdapterReportDetailValueType.text,
            description: 'Resolved GetIt registration API.',
          ),
          AdapterReportDetailDefinition(
            key: 'scope',
            label: 'Scope',
            valueType: AdapterReportDetailValueType.text,
            description: 'Observed GetIt scope identity.',
          ),
          AdapterReportDetailDefinition(
            key: 'environments',
            label: 'Environments',
            valueType: AdapterReportDetailValueType.text,
            description:
                'Sorted comma-separated injectable environment names when known.',
          ),
          AdapterReportDetailDefinition(
            key: 'sourceLocation',
            label: 'Source location',
            valueType: AdapterReportDetailValueType.text,
            description: 'Project-relative registration location.',
          ),
          AdapterReportDetailDefinition(
            key: 'generatedWiring',
            label: 'Generated wiring observed',
            valueType: AdapterReportDetailValueType.boolean,
            description:
                'Whether generated Injectable/GetIt wiring was observed in the project.',
          ),
        ],
      ),
    ],
  );

  @override
  Set<String> get findingNodeSchemes => const {'di'};

  @override
  List<String> get dependsOn => const ['dart'];

  @override
  bool appliesTo(ProjectContext project) => project.hasDependency('get_it');

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) =>
      _analyze(project, graph, DartAnalysisWorkspace(project));

  @override
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) async {
    await services.dartExecutionContextService?.resolve(project);
    await _analyze(
      project,
      graph,
      services.dartWorkspace ?? DartAnalysisWorkspace(project),
    );
  }

  Future<void> _analyze(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
  ) async {
    final inventory = await DiInventory.discover(project, workspace: workspace);
    final resolver = DiResolutionResolver(project, inventory);
    await resolver.analyzeProject(workspace: workspace);
    final generatedWiring = GeneratedWiringProbe.detect(project);

    for (final entry in inventory.entries) {
      graph.addNode(
        GraphNode(
          id: entry.nodeId,
          kind: NodeKind.diRegistration,
          origin: entry.origin,
          displayName: '${entry.apiName}<${entry.type}>',
          metadata: {
            'canonicalType': entry.type.value,
            'instanceNameState': _instanceNameState(entry.instanceName),
            if (entry.instanceName case DiConstantInstanceName(:final value))
              'instanceName': value,
            'registrationApi': entry.apiName,
            'scope': _scope(entry.scope),
            'environments': entry.occurrence.environments.join(','),
            'sourceLocation': entry.location,
            'generatedWiring': generatedWiring.hasGeneratedWiring,
          },
        ),
      );
    }

    for (final reference in resolver.references) {
      if (!inventory.byNodeId.containsKey(reference.diNodeId)) {
        graph.addBlocker(
          reason: 'GetIt resolver emitted a registration outside the inventory',
          location: reference.location,
          affectedNamespace: DiInventory.namespaceFor(project),
        );
        continue;
      }
      graph.addReference(
        from: reference.callerId,
        to: reference.diNodeId,
        kind: EdgeKind.resolves,
        evidence: graph.evidence(
          kind: EvidenceKind.semanticReference,
          description: reference.description,
          exact: true,
          location: reference.location,
        ),
      );
    }

    _addDependsOnEdges(project, graph, inventory);
    _addBlockers(graph, [...inventory.blockers, ...resolver.blockers]);
    _addGeneratedWiringBlockers(project, graph, generatedWiring);
  }

  void _addDependsOnEdges(
    ProjectContext project,
    GraphBuilder graph,
    DiInventory inventory,
  ) {
    for (final entry in inventory.entries) {
      for (final dependency in entry.dependsOn) {
        final candidates = inventory.entriesFor(dependency);
        final uncertain = inventory.entries
            .where(
              (candidate) =>
                  candidate.type == dependency.type &&
                  (candidate.lookup == null || !candidate.isExactBaseScope),
            )
            .map((candidate) => candidate.nodeId)
            .toSet();
        if (candidates.length == 1 && uncertain.isEmpty) {
          graph.addReference(
            from: entry.nodeId,
            to: candidates.single.nodeId,
            kind: EdgeKind.registers,
            evidence: graph.evidence(
              kind: EvidenceKind.configuration,
              description:
                  'GetIt ${entry.apiName} declares dependsOn<$dependency>',
              exact: true,
              location: entry.location,
            ),
          );
          continue;
        }

        graph.addBlocker(
          reason: 'GetIt dependsOn cannot identify one complete registration',
          location: entry.location,
          sourceNodeId: entry.nodeId,
          affectedNodeIds: {
            entry.nodeId,
            ...candidates.map((candidate) => candidate.nodeId),
            ...uncertain,
          },
        );
      }
    }
  }

  void _addBlockers(GraphBuilder graph, Iterable<DiBlocker> blockers) {
    for (final blocker in blockers) {
      graph.addBlocker(
        reason: blocker.reason,
        location: blocker.location,
        sourceNodeId: blocker.sourceNodeId,
        affectedNamespace: blocker.affectedNamespace,
        affectedNodeIds: blocker.affectedNodeIds,
      );
    }
  }

  void _addGeneratedWiringBlockers(
    ProjectContext project,
    GraphBuilder graph,
    GeneratedWiringEvidence evidence,
  ) {
    if (!evidence.hasGeneratedWiring) return;

    graph.addBlocker(
      reason:
          'generated Injectable/GetIt wiring may register services at runtime',
      affectedNamespace: DiInventory.namespaceFor(project),
    );
    for (final output in evidence.outputs) {
      graph.addBlocker(
        reason: output.reason,
        affectedNamespace: output.dartNamespace,
      );
    }
  }

  String _instanceNameState(DiInstanceName name) => switch (name) {
    DiAbsentInstanceName() => 'absent',
    DiConstantInstanceName() => 'constant',
    DiDynamicInstanceName() => 'dynamic',
  };

  String _scope(DiScopeIdentity scope) => switch (scope) {
    DiBaseScope() => 'base',
    DiNamedScope(:final value) => 'named:$value',
    DiDynamicScope() => 'dynamic',
  };
}
