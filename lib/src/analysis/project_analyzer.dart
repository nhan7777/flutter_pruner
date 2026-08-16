import '../adapters/adapter_report_definition.dart';
import '../adapters/analyzer_adapter.dart';
import '../adapters/registry.dart';
import '../core/confidence/finding_generator.dart';
import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';
import '../reporting/run_report.dart';
import 'analysis_snapshot.dart';

/// Builds one graph and finding set for both scan and apply.
class ProjectAnalyzer {
  /// Creates an analyzer for [project] and an optional adapter filter.
  ProjectAnalyzer({required this.project, Set<String>? only})
    : _requestedAdapterIds = only,
      _reportingNodeSchemes = _reportingSchemes(only),
      adapters = AdapterRegistry.resolve(
        only: only == null ? null : _withDependencies(only),
      ) {
    adapterReportDefinitions = List.unmodifiable(
      adapters.map((adapter) => adapter.reportDefinition.snapshot()),
    );
  }

  /// Loaded project and declared analysis coverage.
  final ProjectContext project;

  /// Resolved adapters in dependency order.
  final List<AnalyzerAdapter> adapters;

  /// Presentation metadata snapshotted into reports for the resolved adapters.
  late final List<AdapterReportDefinition> adapterReportDefinitions;

  /// Domains requested by the user. Supporting adapters contribute graph
  /// facts, but their own findings are not reported or applied.
  final Set<String>? _reportingNodeSchemes;
  final Set<String>? _requestedAdapterIds;

  /// Runs every applicable adapter and classifies the resulting graph.
  Future<AnalysisSnapshot> analyze({
    void Function(AnalyzerAdapter adapter)? onAdapter,
  }) async {
    project.pathPolicy.resetObservations();
    final analysisStopwatch = Stopwatch()..start();
    final graph = ReachabilityGraph();
    final adapterRuns = <AdapterRunReport>[];
    for (final adapter in adapters) {
      final role =
          _requestedAdapterIds == null ||
              _requestedAdapterIds.contains(adapter.id)
          ? AdapterRunRole.reporting
          : AdapterRunRole.support;
      if (!adapter.appliesTo(project)) {
        adapterRuns.add(
          AdapterRunReport(
            id: adapter.id,
            name: adapter.name,
            role: role,
            status: AdapterRunStatus.notApplicable,
            elapsedMicros: 0,
            nodesAdded: 0,
            edgesAdded: 0,
            blockersAdded: 0,
            reason: 'adapter does not apply to this project',
          ),
        );
        continue;
      }
      onAdapter?.call(adapter);
      final nodeCount = graph.nodeCount;
      final edgeCount = graph.edgeCount;
      final blockerCount = graph.blockers.length;
      final stopwatch = Stopwatch()..start();
      try {
        await adapter.analyze(project, GraphBuilder(graph, adapter.id));
        stopwatch.stop();
        adapterRuns.add(
          AdapterRunReport(
            id: adapter.id,
            name: adapter.name,
            role: role,
            status: AdapterRunStatus.executed,
            elapsedMicros: stopwatch.elapsedMicroseconds,
            nodesAdded: graph.nodeCount - nodeCount,
            edgesAdded: graph.edgeCount - edgeCount,
            blockersAdded: graph.blockers.length - blockerCount,
          ),
        );
      } catch (_) {
        stopwatch.stop();
        adapterRuns.add(
          AdapterRunReport(
            id: adapter.id,
            name: adapter.name,
            role: role,
            status: AdapterRunStatus.failed,
            elapsedMicros: stopwatch.elapsedMicroseconds,
            nodesAdded: graph.nodeCount - nodeCount,
            edgesAdded: graph.edgeCount - edgeCount,
            blockersAdded: graph.blockers.length - blockerCount,
            reason: 'adapter analysis failed',
          ),
        );
        rethrow;
      }
    }
    final findings = const FindingGenerator().generate(
      graph: graph,
      project: project,
      reportingNodeSchemes: _reportingNodeSchemes,
      adapterReportDefinitions: {
        for (final definition in adapterReportDefinitions)
          definition.adapterId: definition,
      },
    );
    analysisStopwatch.stop();
    return AnalysisSnapshot(
      project: project,
      graph: graph,
      findings: findings,
      adapterIds: List.unmodifiable(adapters.map((adapter) => adapter.id)),
      adapterRuns: List.unmodifiable(adapterRuns),
      elapsedMicros: analysisStopwatch.elapsedMicroseconds,
      exclusions: project.pathPolicy.snapshot(),
    );
  }

  static Set<String> _withDependencies(Set<String> requested) {
    final byId = {
      for (final adapter in AdapterRegistry.builtIn) adapter.id: adapter,
    };
    final expanded = <String>{};

    void add(String id) {
      if (!expanded.add(id)) return;
      final adapter = byId[id];
      if (adapter == null) return;
      for (final dependency in adapter.dependsOn) {
        add(dependency);
      }
    }

    for (final id in requested) {
      add(id);
    }
    return expanded;
  }

  static Set<String>? _reportingSchemes(Set<String>? requested) {
    if (requested == null) return null;
    return {
      for (final adapter in AdapterRegistry.builtIn)
        if (requested.contains(adapter.id)) ...adapter.findingNodeSchemes,
    };
  }
}
