import '../graph/reachability_graph.dart';
import '../graph/root.dart';
import '../project/project_context.dart';
import 'action_readiness_index.dart';

/// Resolves action readiness after all adapters finish, before finding generation.
///
/// Performs bounded static work to determine family-level action capabilities.
/// Must NOT execute Flutter, run staging, or perform unbounded analysis.
///
/// Returns an immutable index keyed by canonical node ID. The core verifies
/// adapter ownership and node kind before an entry can override the existing
/// core allowlist, so custom adapters cannot gain mutation authority by
/// copying metadata.
abstract interface class StaticActionReadinessResolver {
  /// Resolves action readiness for all eligible nodes in the graph.
  ///
  /// Called by [ProjectAnalyzer] after all adapters complete and graph
  /// integrity is computed, but before finding generation.
  ///
  /// The returned index is passed to [FindingGenerator] to determine
  /// family-level action capabilities during finding classification.
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  });
}

/// No-op resolver that returns an empty index.
///
/// Used as the default when no action readiness resolution is configured.
/// Preserves existing behavior where all findings remain REVIEW-only.
final class NoOpActionReadinessResolver
    implements StaticActionReadinessResolver {
  const NoOpActionReadinessResolver();

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async =>
      ActionReadinessIndex.empty;
}
