import '../../core/confidence/promotion_index.dart';
import '../../core/graph/reachability_graph.dart';
import '../../core/graph/root.dart';
import '../../core/project/project_context.dart';

/// Internal-only resolver for action readiness after adapters finish.
///
/// This interface lives in adapters/internal to maintain Stage 1 public
/// boundary constraints. Action readiness infrastructure is V3 Stage 2
/// implementation detail and must not leak into public production paths.
///
/// Implementations perform bounded static analysis to determine which graph
/// nodes are ready for safe actionable removal. Must NOT execute Flutter,
/// run staging pipelines, or perform unbounded filesystem traversal.
abstract interface class ActionReadinessResolver {
  /// Resolve action readiness for all actionable nodes in the graph.
  ///
  /// Returns an [ActionReadinessIndex] keyed by canonical node ID. Only nodes
  /// that pass all static checks appear in the index.
  ///
  /// Implementations must:
  /// - Perform only bounded static work (config loading, graph inspection)
  /// - Never execute Flutter or run staging pipelines
  /// - Never generate files or modify the project
  /// - Return an empty index on any blocking condition
  ///
  /// The [graph] contains all adapter-discovered nodes and edges.
  /// The [integrity] report captures any graph-level anomalies.
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  });
}

/// No-op resolver that returns an empty index.
///
/// Used as the default when no action readiness resolution is configured.
/// Ensures that projects without actionable adapters can still analyze.
final class NoOpActionReadinessResolver implements ActionReadinessResolver {
  /// Creates a no-op resolver.
  const NoOpActionReadinessResolver();

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async => ActionReadinessIndex.empty;
}
