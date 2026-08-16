import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../core/confidence/action_capability.dart';
import '../core/confidence/finding.dart';
import '../core/graph/edge.dart';
import '../core/graph/node.dart';
import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';
import 'mode_apply_policy.dart';

/// Why an otherwise applicable finding cannot enter the current removal plan.
enum PlanBlockReason {
  /// A consumer remains in the working tree and its edge is not rewritten.
  retainedConsumer,

  /// A retained upstream action prevents removal of this dependency.
  blockedByRetainedDependency,
}

/// A finding excluded from a removal plan and its precise dependency reason.
class BlockedFinding {
  /// Creates a blocked finding record.
  const BlockedFinding({
    required this.finding,
    required this.reason,
    required this.blockedBy,
  });

  /// Finding that may not be removed in this plan.
  final Finding finding;

  /// Stable category explaining the exclusion.
  final PlanBlockReason reason;

  /// Graph node that remains and keeps [finding] alive.
  final String blockedBy;
}

/// Smallest set of findings that may be committed or rolled back together.
class AtomicUnit {
  /// Creates an atomic unit.
  const AtomicUnit({
    required this.id,
    required this.findings,
    required this.dependencyUnitIds,
  });

  /// Stable content-derived identifier.
  final String id;

  /// SCC members in stable node-id order.
  final List<Finding> findings;

  /// Units downstream from this consumer in the condensation DAG.
  final List<String> dependencyUnitIds;
}

/// Deterministic consumer-first plan for one analysis snapshot.
class RemovalPlan {
  /// Creates a removal plan.
  const RemovalPlan({required this.units, required this.blocked});

  /// Atomic units in consumer-first topological order.
  final List<AtomicUnit> units;

  /// Findings excluded because their removal closure is incomplete.
  final List<BlockedFinding> blocked;
}

/// Plans dependency-closed mode-authorized removals using Tarjan SCCs.
class RemovalPlanner {
  /// Creates the stateless planner.
  const RemovalPlanner();

  /// Builds a deterministic plan from [findings] and [graph].
  RemovalPlan build({
    required List<Finding> findings,
    required ReachabilityGraph graph,
    required ProjectContext project,
  }) {
    final selected = <String, Finding>{
      for (final finding in findings)
        if (_isSelected(finding, project)) finding.node.id: finding,
    };
    if (selected.isEmpty) {
      return const RemovalPlan(units: [], blocked: []);
    }

    final outgoing = {for (final id in selected.keys) id: <String>{}};
    final incomingExternal = {for (final id in selected.keys) id: <String>{}};
    for (final edge in graph.edges) {
      if (!_appliesToAnyTarget(edge, project)) continue;
      final target = selected[edge.to];
      if (target == null) continue;
      if (selected.containsKey(edge.from)) {
        if (edge.from != edge.to) outgoing[edge.from]!.add(edge.to);
      } else if (!_isNeutralizedByAction(edge, target)) {
        incomingExternal[edge.to]!.add(edge.from);
      }
    }

    _joinSharedPaths(selected, outgoing);

    final blockedBy = <String, String>{};
    final pending = <String>[];
    for (final entry in incomingExternal.entries) {
      if (entry.value.isEmpty) continue;
      final consumers = entry.value.toList()..sort();
      blockedBy[entry.key] = consumers.first;
      pending.add(entry.key);
    }
    while (pending.isNotEmpty) {
      final retained = pending.removeLast();
      for (final dependency in outgoing[retained]!) {
        if (blockedBy.containsKey(dependency)) continue;
        blockedBy[dependency] = retained;
        pending.add(dependency);
      }
    }

    final active = selected.keys
        .where((id) => !blockedBy.containsKey(id))
        .toSet();
    final components = _tarjan(active, outgoing);
    final componentByNode = <String, int>{};
    for (var index = 0; index < components.length; index++) {
      for (final nodeId in components[index]) {
        componentByNode[nodeId] = index;
      }
    }

    final componentOutgoing = {
      for (var index = 0; index < components.length; index++) index: <int>{},
    };
    final indegree = {
      for (var index = 0; index < components.length; index++) index: 0,
    };
    for (final from in active) {
      final fromComponent = componentByNode[from]!;
      for (final to in outgoing[from]!.where(active.contains)) {
        final toComponent = componentByNode[to]!;
        if (fromComponent == toComponent) continue;
        if (componentOutgoing[fromComponent]!.add(toComponent)) {
          indegree[toComponent] = indegree[toComponent]! + 1;
        }
      }
    }

    String componentKey(int index) => components[index].first;
    final ready =
        indegree.entries
            .where((entry) => entry.value == 0)
            .map((entry) => entry.key)
            .toList()
          ..sort(
            (left, right) => componentKey(left).compareTo(componentKey(right)),
          );
    final unitIdByComponent = {
      for (var index = 0; index < components.length; index++)
        index: _unitId(components[index]),
    };
    final units = <AtomicUnit>[];
    while (ready.isNotEmpty) {
      final componentIndex = ready.removeAt(0);
      final nodeIds = components[componentIndex];
      units.add(
        AtomicUnit(
          id: unitIdByComponent[componentIndex]!,
          findings: List.unmodifiable(nodeIds.map((id) => selected[id]!)),
          dependencyUnitIds: List.unmodifiable(
            componentOutgoing[componentIndex]!
                .map((index) => unitIdByComponent[index]!)
                .toList()
              ..sort(),
          ),
        ),
      );
      final dependencies = componentOutgoing[componentIndex]!.toList()
        ..sort(
          (left, right) => componentKey(left).compareTo(componentKey(right)),
        );
      for (final dependency in dependencies) {
        indegree[dependency] = indegree[dependency]! - 1;
        if (indegree[dependency] == 0) {
          ready.add(dependency);
          ready.sort(
            (left, right) => componentKey(left).compareTo(componentKey(right)),
          );
        }
      }
    }

    final blocked =
        blockedBy.entries.map((entry) {
          final external = incomingExternal[entry.key]!.contains(entry.value);
          return BlockedFinding(
            finding: selected[entry.key]!,
            reason: external
                ? PlanBlockReason.retainedConsumer
                : PlanBlockReason.blockedByRetainedDependency,
            blockedBy: entry.value,
          );
        }).toList()..sort(
          (left, right) =>
              left.finding.node.id.compareTo(right.finding.node.id),
        );

    return RemovalPlan(units: units, blocked: blocked);
  }

  bool _isSelected(Finding finding, ProjectContext project) {
    final adapterId = finding.reportingAdapterId;
    if (adapterId == null) return false;
    final capability = ActionCapability.forFinding(
      adapterId: adapterId,
      node: finding.node,
    );
    if (!capability.supported) return false;
    return ModeApplyPolicy.allows(project.analysisMode, finding);
  }

  bool _appliesToAnyTarget(GraphEdge edge, ProjectContext project) =>
      project.targets.any(edge.condition.appliesTo);

  bool _isNeutralizedByAction(GraphEdge edge, Finding target) =>
      target.node.kind == NodeKind.dartLibrary &&
      target.node.metadata['declarationCount'] == 0 &&
      edge.kind == EdgeKind.imports &&
      edge.isExact &&
      edge.condition.isUnconditional &&
      (edge.evidence.description == 'import directive' ||
          edge.evidence.description == 'export directive');

  void _joinSharedPaths(
    Map<String, Finding> selected,
    Map<String, Set<String>> outgoing,
  ) {
    final byPath = <String, List<String>>{};
    for (final entry in selected.entries) {
      final origin = entry.value.node.origin;
      if (origin.scheme != 'file') continue;
      byPath.putIfAbsent(origin.toFilePath(), () => []).add(entry.key);
    }
    for (final ids in byPath.values) {
      if (ids.length < 2) continue;
      for (final from in ids) {
        outgoing[from]!.addAll(ids.where((to) => to != from));
      }
    }
  }

  List<List<String>> _tarjan(
    Set<String> active,
    Map<String, Set<String>> outgoing,
  ) {
    var nextIndex = 0;
    final indexes = <String, int>{};
    final lowLinks = <String, int>{};
    final stack = <String>[];
    final onStack = <String>{};
    final components = <List<String>>[];

    void visit(String node) {
      indexes[node] = nextIndex;
      lowLinks[node] = nextIndex;
      nextIndex++;
      stack.add(node);
      onStack.add(node);

      final dependencies = outgoing[node]!.where(active.contains).toList()
        ..sort();
      for (final dependency in dependencies) {
        if (!indexes.containsKey(dependency)) {
          visit(dependency);
          final dependencyLow = lowLinks[dependency]!;
          if (dependencyLow < lowLinks[node]!) {
            lowLinks[node] = dependencyLow;
          }
        } else if (onStack.contains(dependency)) {
          final dependencyIndex = indexes[dependency]!;
          if (dependencyIndex < lowLinks[node]!) {
            lowLinks[node] = dependencyIndex;
          }
        }
      }

      if (lowLinks[node] != indexes[node]) return;
      final component = <String>[];
      while (true) {
        final member = stack.removeLast();
        onStack.remove(member);
        component.add(member);
        if (member == node) break;
      }
      component.sort();
      components.add(component);
    }

    final stableNodes = active.toList()..sort();
    for (final node in stableNodes) {
      if (!indexes.containsKey(node)) visit(node);
    }
    components.sort((left, right) => left.first.compareTo(right.first));
    return components;
  }

  String _unitId(List<String> nodeIds) {
    final digest = sha256
        .convert(utf8.encode(nodeIds.join('\u0000')))
        .toString();
    return 'unit:${digest.substring(0, 16)}';
  }
}
