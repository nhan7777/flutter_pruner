import '../core/confidence/confidence.dart';
import '../core/confidence/finding.dart';
import '../core/graph/node.dart';
import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';
import '../core/project/project_path_policy.dart';
import '../reporting/run_report.dart';

/// Immutable result of one complete adapter and confidence pass.
class AnalysisSnapshot {
  /// Creates an analysis snapshot.
  const AnalysisSnapshot({
    required this.project,
    required this.graph,
    required this.findings,
    required this.adapterIds,
    required this.adapterRuns,
    required this.elapsedMicros,
    required this.exclusions,
  });

  /// Project and declared coverage used for this pass.
  final ProjectContext project;

  /// Complete cross-adapter graph.
  final ReachabilityGraph graph;

  /// Stable confidence-sorted findings derived from [graph].
  final List<Finding> findings;

  /// Adapters selected for this pass, in execution order.
  final List<String> adapterIds;

  /// Actual adapter attempts, including support-only and not-applicable runs.
  final List<AdapterRunReport> adapterRuns;

  /// Total wall duration measured with a monotonic stopwatch.
  final int elapsedMicros;

  /// Tool-owned and out-of-bound paths observed during this pass.
  final PathExclusionSummary exclusions;

  /// Builds the stable reporting projection for this analysis pass.
  AnalysisPassReport toPassReport({
    required String id,
    required AnalysisPassPurpose purpose,
    int? round,
  }) {
    final activeBlockers = <String, String>{};
    final affectedFindingIds = <String>{};
    for (final finding in findings) {
      if (finding.blockers.isNotEmpty) affectedFindingIds.add(finding.node.id);
      for (final blocker in finding.blockers) {
        final affectedIds = blocker.affectedNodeIds.toList()..sort();
        final key = [
          blocker.producer,
          blocker.reason,
          blocker.location ?? '',
          blocker.sourceNodeId ?? '',
          blocker.affectedNamespace ?? '',
          affectedIds.join(','),
        ].join('\u0000');
        activeBlockers[key] = blocker.producer;
      }
    }
    final blockersByProducer = <String, int>{};
    for (final producer in activeBlockers.values) {
      blockersByProducer.update(
        producer,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }

    final measurements = <RunMeasurement>[];
    final reportingAdapters = adapterRuns
        .where(
          (run) =>
              run.role == AdapterRunRole.reporting &&
              run.status == AdapterRunStatus.executed,
        )
        .map((run) => run.id)
        .toSet();
    if (reportingAdapters.contains('assets')) {
      final assets = graph.nodesOfKind(NodeKind.asset).toList();
      measurements.add(
        RunMeasurement(
          kind: 'asset-family-source-bytes',
          adapterId: 'assets',
          status: MeasurementStatus.measured,
          unit: 'bytes',
          value: assets.fold<int>(
            0,
            (total, node) => total + (node.sizeBytes ?? 0),
          ),
          knownCount: assets.where((node) => node.sizeBytes != null).length,
          unknownCount: assets.where((node) => node.sizeBytes == null).length,
          scope: 'assets-inventory',
          aggregation: 'unique-asset-family-paths',
        ),
      );
    }
    if (reportingAdapters.contains('duplicates')) {
      final groups = graph.nodesOfKind(NodeKind.duplicateGroup).toList();
      measurements.add(
        RunMeasurement(
          kind: 'duplicate-potential-reclaimable-bytes',
          adapterId: 'duplicates',
          status: MeasurementStatus.measured,
          unit: 'bytes',
          value: groups.fold<int>(
            0,
            (total, node) => total + (node.sizeBytes ?? 0),
          ),
          knownCount: groups.where((node) => node.sizeBytes != null).length,
          unknownCount: groups.where((node) => node.sizeBytes == null).length,
          scope: 'duplicate-inventory',
          aggregation: 'within-duplicate-groups-only',
        ),
      );
    }
    if (reportingAdapters.contains('dart')) {
      final dartFindings = findings
          .where((finding) => finding.reportingAdapterId == 'dart')
          .toList();
      final hasNoFindings = dartFindings.isEmpty;
      final allSizesUnknown =
          !hasNoFindings &&
          dartFindings.every((finding) => finding.sourceBytes == null);
      measurements.add(
        RunMeasurement(
          kind: 'dart-finding-source-bytes',
          adapterId: 'dart',
          status: allSizesUnknown
              ? MeasurementStatus.unknown
              : MeasurementStatus.measured,
          unit: 'bytes',
          value: allSizesUnknown
              ? null
              : hasNoFindings
              ? 0
              : dartFindings.fold<int>(
                  0,
                  (total, finding) => total + (finding.sourceBytes ?? 0),
                ),
          knownCount: dartFindings
              .where((finding) => finding.sourceBytes != null)
              .length,
          unknownCount: dartFindings
              .where((finding) => finding.sourceBytes == null)
              .length,
          scope: 'dart-findings',
          aggregation: 'not-additive-with-file-inventory',
        ),
      );
    }

    final findingStatistics = FindingStatistics.fromFindings(findings);
    final countsByAdapter = <String, int>{
      for (final run in adapterRuns)
        if (run.role == AdapterRunRole.reporting)
          run.id: findingStatistics.byReportingAdapter[run.id] ?? 0,
      ...findingStatistics.byReportingAdapter,
    };
    final tiersByAdapter = <String, Map<String, int>>{
      for (final run in adapterRuns)
        if (run.role == AdapterRunRole.reporting)
          run.id:
              findingStatistics.byReportingAdapterAndTier[run.id] ??
              {for (final tier in Confidence.values) tier.label: 0},
      ...findingStatistics.byReportingAdapterAndTier,
    };

    return AnalysisPassReport(
      id: id,
      purpose: purpose,
      round: round,
      elapsedMicros: elapsedMicros,
      nodeCount: graph.nodeCount,
      edgeCount: graph.edgeCount,
      rootCount: graph.rootCount,
      recordedBlockerCount: graph.blockers.length,
      danglingEdgeCount: graph.danglingEdgesFor(project.targets).length,
      danglingRootCount: graph.danglingRootIdsFor(project.targets).length,
      adapterRuns: adapterRuns,
      findingStatistics: FindingStatistics(
        total: findingStatistics.total,
        byTier: findingStatistics.byTier,
        byReportingAdapter: Map.unmodifiable(countsByAdapter),
        byReportingAdapterAndTier: Map.unmodifiable(tiersByAdapter),
        byRule: findingStatistics.byRule,
        byNodeKind: findingStatistics.byNodeKind,
        byClassificationReason: findingStatistics.byClassificationReason,
      ),
      blockerStatistics: BlockerStatistics(
        recorded: graph.blockers.length,
        activeUnique: activeBlockers.length,
        affectedFindings: affectedFindingIds.length,
        byProducer: Map.unmodifiable(blockersByProducer),
      ),
      measurements: List.unmodifiable(measurements),
      exclusionPolicyVersion: exclusions.policyVersion,
      exclusionsByReason: exclusions.byReason,
    );
  }
}
