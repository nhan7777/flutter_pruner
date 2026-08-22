import '../../core/graph/execution_target.dart';
import 'dart_execution_context_service.dart';
import 'dart_execution_reachability_service.dart';

/// Immutable compatibility facade over a pass reachability snapshot.
final class DartApplicationReachability {
  DartApplicationReachability._({
    required this.configuredProvenUnitPaths,
    required this.configuredRetainedUnitPaths,
    required this.auxiliaryProvenUnitPaths,
    required this.auxiliaryRetainedUnitPaths,
    required this.globalUsageUnitPaths,
    required this.unitPaths,
    required this.issues,
    required this.contextIssues,
    required this.auxiliaryContextIssues,
  });

  /// Creates a facade without another analyzer traversal.
  factory DartApplicationReachability.fromSnapshot(
    DartExecutionReachabilitySnapshot snapshot,
  ) {
    final configuredProvenUnion = <String>{
      for (final paths in snapshot.configuredProvenUnitPaths.values) ...paths,
    };
    final auxiliaryContextIssues = <String, List<DartExecutionContextIssue>>{};
    for (final target in snapshot.auxiliaryExecutionTargets) {
      if (target.environmentComplete) continue;
      final scoped = snapshot.contexts.issues
          .where(
            (issue) =>
                !issue.requiresGlobalBlocker && issue.reason == target.reason,
          )
          .toList(growable: false);
      if (scoped.isNotEmpty) {
        auxiliaryContextIssues[target.id] = List.unmodifiable(scoped);
      }
    }
    return DartApplicationReachability._(
      configuredProvenUnitPaths: snapshot.configuredProvenUnitPaths,
      configuredRetainedUnitPaths: snapshot.configuredRetainedUnitPaths,
      auxiliaryProvenUnitPaths: snapshot.auxiliaryProvenUnitPaths,
      auxiliaryRetainedUnitPaths: snapshot.auxiliaryRetainedUnitPaths,
      globalUsageUnitPaths: snapshot.globalUsageUnitPaths,
      unitPaths: Set.unmodifiable(configuredProvenUnion),
      issues: snapshot.issues,
      contextIssues: snapshot.contexts.issues,
      auxiliaryContextIssues: Map.unmodifiable(auxiliaryContextIssues),
    );
  }

  /// Exact configured closure keyed by the full immutable target tuple.
  final Map<BuildTarget, Set<String>> configuredProvenUnitPaths;

  /// Configured fail-closed retention keyed by the full target tuple.
  final Map<BuildTarget, Set<String>> configuredRetainedUnitPaths;

  /// Exact auxiliary closure keyed by global auxiliary ID.
  final Map<String, Set<String>> auxiliaryProvenUnitPaths;

  /// Auxiliary fail-closed retention keyed by global auxiliary ID.
  final Map<String, Set<String>> auxiliaryRetainedUnitPaths;

  /// Union of every configured and auxiliary retained set.
  final Set<String> globalUsageUnitPaths;

  /// Legacy union of configured exact closures.
  final Set<String> unitPaths;

  /// Conditions that prevent complete semantic coverage.
  final List<String> issues;

  /// Typed context facts, including scoped issues that are not global blockers.
  final List<DartExecutionContextIssue> contextIssues;

  /// Non-global context issues keyed by their exact auxiliary context ID.
  final Map<String, List<DartExecutionContextIssue>> auxiliaryContextIssues;

  /// Whether no pass-level or globally blocking closure issue was recorded.
  bool get isComplete => issues.isEmpty;
}
