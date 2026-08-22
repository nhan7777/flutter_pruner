import 'build_condition.dart';
import 'edge.dart';
import 'execution_target.dart';

/// One immutable root fact in the reachability graph.
sealed class GraphRootRecord {
  const GraphRootRecord({required this.nodeId, required this.reason});

  /// Node from which traversal starts.
  final String nodeId;

  /// Stable explanation for the root fact.
  final String reason;

  /// Execution domain that owns this root.
  RootDomain get domain;
}

/// A root evaluated against configured application targets.
final class ConfiguredGraphRootRecord extends GraphRootRecord {
  /// Creates a configured root record.
  const ConfiguredGraphRootRecord({
    required super.nodeId,
    required super.reason,
    required this.condition,
  });

  /// Configured-target condition for this root.
  final BuildCondition condition;

  @override
  RootDomain get domain => RootDomain.configuredTarget;

  @override
  bool operator ==(Object other) =>
      other is ConfiguredGraphRootRecord &&
      other.nodeId == nodeId &&
      other.reason == reason &&
      other.condition == condition;

  @override
  int get hashCode => Object.hash(nodeId, reason, condition, domain);
}

/// A root evaluated only in one registered auxiliary execution target.
final class AuxiliaryGraphRootRecord extends GraphRootRecord {
  /// Creates an auxiliary root record.
  const AuxiliaryGraphRootRecord({
    required super.nodeId,
    required super.reason,
    required this.executionTargetId,
  });

  /// Full `aux:<domain>:<id>` registry identity.
  final String executionTargetId;

  @override
  RootDomain get domain => RootDomain.auxiliary;

  @override
  bool operator ==(Object other) =>
      other is AuxiliaryGraphRootRecord &&
      other.nodeId == nodeId &&
      other.reason == reason &&
      other.executionTargetId == executionTargetId;

  @override
  int get hashCode => Object.hash(nodeId, reason, executionTargetId, domain);
}

/// Cached reachability across every registered auxiliary execution target.
final class AuxiliaryReachability {
  /// Creates an immutable auxiliary reachability snapshot.
  AuxiliaryReachability({
    required Map<String, Set<String>> provenByExecutionTarget,
    required Map<String, Set<String>> retainedByExecutionTarget,
    required Set<String> proven,
    required Set<String> retained,
    required Set<String> incompleteExecutionTargetIds,
    required List<AuxiliaryExecutionTargetRegistryIssue> registryIssues,
  }) : provenByExecutionTarget = _freezeSetMap(provenByExecutionTarget),
       retainedByExecutionTarget = _freezeSetMap(retainedByExecutionTarget),
       proven = Set.unmodifiable(proven),
       retained = Set.unmodifiable(retained),
       incompleteExecutionTargetIds = Set.unmodifiable(
         incompleteExecutionTargetIds,
       ),
       registryIssues = List.unmodifiable(registryIssues);

  /// Proven exact closure keyed by auxiliary target ID.
  final Map<String, Set<String>> provenByExecutionTarget;

  /// Fail-closed retention closure keyed by auxiliary target ID.
  final Map<String, Set<String>> retainedByExecutionTarget;

  /// Union of every auxiliary proven closure.
  final Set<String> proven;

  /// Union of every auxiliary retained closure.
  final Set<String> retained;

  /// Contexts whose environment or condition applicability is incomplete.
  final Set<String> incompleteExecutionTargetIds;

  /// Auxiliary registry conflicts observed by the graph.
  final List<AuxiliaryExecutionTargetRegistryIssue> registryIssues;
}

/// One configured target combined with the global auxiliary snapshot.
final class TargetReachability {
  /// Creates an immutable target reachability snapshot.
  TargetReachability({
    required Set<String> configuredProven,
    required Set<String> configuredRetained,
    required Set<String> auxiliaryProven,
    required Set<String> auxiliaryRetained,
    required Set<String> provenReachable,
    required Set<String> retained,
    required Set<String> legacyReachable,
  }) : configuredProven = Set.unmodifiable(configuredProven),
       configuredRetained = Set.unmodifiable(configuredRetained),
       auxiliaryProven = Set.unmodifiable(auxiliaryProven),
       auxiliaryRetained = Set.unmodifiable(auxiliaryRetained),
       provenReachable = Set.unmodifiable(provenReachable),
       retained = Set.unmodifiable(retained),
       legacyReachable = Set.unmodifiable(legacyReachable) {
    if (!this.configuredRetained.containsAll(this.configuredProven) ||
        !this.auxiliaryRetained.containsAll(this.auxiliaryProven) ||
        !this.provenReachable.containsAll(this.configuredProven) ||
        !this.provenReachable.containsAll(this.auxiliaryProven) ||
        !this.retained.containsAll(this.provenReachable)) {
      throw StateError('Reachability snapshot invariants were violated.');
    }
  }

  /// Exact configured closure.
  final Set<String> configuredProven;

  /// Configured fail-closed retention closure.
  final Set<String> configuredRetained;

  /// Union of exact auxiliary closures.
  final Set<String> auxiliaryProven;

  /// Union of auxiliary retention closures.
  final Set<String> auxiliaryRetained;

  /// [configuredProven] union [auxiliaryProven].
  final Set<String> provenReachable;

  /// [configuredRetained] union [auxiliaryRetained].
  final Set<String> retained;

  /// Frozen compatibility projection used until finding migration in G4.
  final Set<String> legacyReachable;
}

/// Dangling graph facts and completeness for one execution target.
final class ExecutionTargetIntegrity {
  /// Creates an immutable per-context integrity snapshot.
  ExecutionTargetIntegrity({
    required this.id,
    required this.domain,
    required Set<GraphEdge> danglingEdges,
    required Set<String> danglingRootIds,
    Set<String> incompleteReasons = const {},
  }) : danglingEdges = Set.unmodifiable(danglingEdges),
       danglingRootIds = Set.unmodifiable(danglingRootIds),
       incompleteReasons = Set.unmodifiable(incompleteReasons);

  /// Stable `app:<name>` or auxiliary target ID.
  final String id;

  /// Root domain represented by this record.
  final RootDomain domain;

  /// Dangling edges applicable or indeterminate in this context.
  final Set<GraphEdge> danglingEdges;

  /// Dangling root node IDs in this context.
  final Set<String> danglingRootIds;

  /// Stable reasons this context could not be completely evaluated.
  final Set<String> incompleteReasons;

  /// Whether this context is internally complete.
  bool get complete =>
      danglingEdges.isEmpty &&
      danglingRootIds.isEmpty &&
      incompleteReasons.isEmpty;
}

/// One aggregate, immutable graph-health snapshot for an analysis pass.
final class GraphIntegrity {
  /// Creates an aggregate integrity snapshot.
  GraphIntegrity({
    required Set<BuildTarget> configuredTargets,
    required Map<String, ExecutionTargetIntegrity> byExecutionTarget,
    required Set<GraphEdge> unattributedDanglingEdges,
    required Set<String> unattributedDanglingRootIds,
    required List<AuxiliaryExecutionTargetRegistryIssue>
    auxiliaryRegistryIssues,
  }) : configuredTargets = Set.unmodifiable(
         configuredTargets.map(BuildTarget.snapshot),
       ),
       byExecutionTarget = Map.unmodifiable(byExecutionTarget),
       unattributedDanglingEdges = Set.unmodifiable(unattributedDanglingEdges),
       unattributedDanglingRootIds = Set.unmodifiable(
         unattributedDanglingRootIds,
       ),
       auxiliaryRegistryIssues = List.unmodifiable(auxiliaryRegistryIssues),
       _danglingEdges = Set.unmodifiable({
         ...unattributedDanglingEdges,
         for (final integrity in byExecutionTarget.values)
           ...integrity.danglingEdges,
       }),
       _danglingRootIds = Set.unmodifiable({
         ...unattributedDanglingRootIds,
         for (final integrity in byExecutionTarget.values)
           ...integrity.danglingRootIds,
       });

  /// Exact configured target tuples evaluated by this snapshot.
  final Set<BuildTarget> configuredTargets;

  /// Configured and auxiliary context health keyed by stable context ID.
  final Map<String, ExecutionTargetIntegrity> byExecutionTarget;

  /// Dangling edges whose conditions match no registered execution context.
  final Set<GraphEdge> unattributedDanglingEdges;

  /// Dangling roots whose conditions match no registered execution context.
  final Set<String> unattributedDanglingRootIds;

  /// Auxiliary registry conflicts.
  final List<AuxiliaryExecutionTargetRegistryIssue> auxiliaryRegistryIssues;

  final Set<GraphEdge> _danglingEdges;
  final Set<String> _danglingRootIds;

  /// Deduplicated dangling-edge union across every context.
  Set<GraphEdge> get danglingEdges => _danglingEdges;

  /// Deduplicated dangling-root union across every context.
  Set<String> get danglingRootIds => _danglingRootIds;

  /// Whether every registered execution context and graph endpoint is complete.
  bool get complete =>
      auxiliaryRegistryIssues.isEmpty &&
      unattributedDanglingEdges.isEmpty &&
      unattributedDanglingRootIds.isEmpty &&
      byExecutionTarget.values.every((integrity) => integrity.complete);
}

Map<String, Set<String>> _freezeSetMap(Map<String, Set<String>> source) =>
    Map.unmodifiable({
      for (final entry in source.entries)
        entry.key: Set<String>.unmodifiable(entry.value),
    });
