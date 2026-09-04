import '../graph/reachability_graph.dart';
import '../graph/root.dart';
import '../project/project_context.dart';
import 'action_readiness_index.dart';

/// Resolves action readiness after adapters finish, before finding generation.
///
/// Implementations perform bounded static analysis to determine which graph
/// nodes are ready for safe actionable removal. Must NOT execute Flutter,
/// run staging pipelines, or perform unbounded filesystem traversal.
///
/// The resolver runs as a core-owned step in [ProjectAnalyzer], after all
/// adapters complete but before [FindingGenerator] runs. This allows adapters
/// to remain pure graph builders while action readiness becomes a separate
/// concern.
abstract interface class StaticActionReadinessResolver {
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
/// Ensures that projects without actionable adapters (or with resolution
/// disabled) can still analyze successfully.
final class NoOpActionReadinessResolver
    implements StaticActionReadinessResolver {
  /// Creates a no-op resolver.
  const NoOpActionReadinessResolver();

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async =>
      ActionReadinessIndex.empty;
}
