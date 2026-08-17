import 'package:collection/collection.dart';

import 'build_condition.dart';
import 'edge.dart';
import 'evidence.dart';
import 'node.dart';

/// The cross-domain reachability graph.
///
/// This is the heart of the tool and deliberately domain-agnostic: it knows
/// about nodes, edges, roots and blockers, but nothing about assets, routes or
/// dependency injection. Adapters supply that meaning.
///
/// The key design decision is that reachability is computed **per build
/// target**, not once globally:
///
/// ```text
/// R(target) = reachable(roots(target), edges where condition.appliesTo(target))
/// ```
///
/// A node is only globally dead when it is absent from `R(target)` for every
/// configured target.
class ReachabilityGraph {
  final Map<String, GraphNode> _nodes = {};
  final Map<String, String> _nodeOwners = {};
  final Map<String, Set<String>> _nodeContributors = {};
  final Set<GraphEdge> _edges = {};
  final Map<String, Set<GraphEdge>> _outgoing = {};
  final Map<String, Set<GraphEdge>> _incoming = {};
  final Map<String, List<_RootRecord>> _roots = {};
  final Map<String, List<_Protection>> _protections = {};
  final List<Blocker> _blockers = [];
  final Map<String, List<Blocker>> _blockersByNode = {};
  final Map<Blocker, Set<String>> _nodesByBlocker = {};
  final Set<String> _conflictingNodeIds = {};
  final Map<String, _CachedTargetAnalysis> _targetAnalysisCache = {};
  int _mutationVersion = 0;

  /// All nodes, in insertion order.
  Iterable<GraphNode> get nodes => UnmodifiableMapView(_nodes).values;

  /// All edges.
  Iterable<GraphEdge> get edges => UnmodifiableSetView(_edges);

  /// All recorded blockers.
  Iterable<Blocker> get blockers => UnmodifiableListView(_blockers);

  /// Node ids registered as roots.
  Iterable<String> get rootIds => UnmodifiableMapView(_roots).keys;

  /// Number of root node IDs registered in the graph.
  int get rootCount => _roots.length;

  /// Number of nodes.
  int get nodeCount => _nodes.length;

  /// Number of edges.
  int get edgeCount => _edges.length;

  /// Adds [node].
  ///
  /// Idempotence matters because several adapters may legitimately discover the
  /// same node — for example both the asset adapter and a FlutterGen adapter
  /// referring to one asset. A duplicate whose full metadata conflicts is a
  /// graph-integrity failure: it is retained deterministically and receives a
  /// node-scoped blocker, so it can never produce a `SAFE` finding.
  void addNode(GraphNode node, {String? producer}) {
    final frozenNode = _freezeNode(node);
    final existing = _nodes[node.id];
    if (existing == null) {
      _nodes[node.id] = frozenNode;
      for (final blocker in _blockers) {
        if (blocker.couldAddress(node.id)) {
          (_blockersByNode[node.id] ??= []).add(blocker);
          (_nodesByBlocker[blocker] ??= {}).add(node.id);
        }
      }
      _markMutated();
    } else if (!_sameNodeDefinition(existing, frozenNode)) {
      if (_nodeFingerprint(frozenNode).compareTo(_nodeFingerprint(existing)) <
          0) {
        _nodes[node.id] = frozenNode;
      }
      _recordNodeConflict(node.id);
      _markMutated();
    }
    if (producer != null) {
      _nodeOwners.putIfAbsent(node.id, () => producer);
      (_nodeContributors[node.id] ??= {}).add(producer);
    }
  }

  void _recordNodeConflict(String nodeId) {
    if (!_conflictingNodeIds.add(nodeId)) return;
    addBlocker(
      Blocker(
        producer: 'graph',
        reason: 'conflicting node definition for duplicate id',
        affectedNodeIds: {nodeId},
      ),
    );
  }

  GraphNode _freezeNode(GraphNode node) => GraphNode(
    id: node.id,
    kind: node.kind,
    origin: node.origin,
    sizeBytes: node.sizeBytes,
    sha256: node.sha256,
    displayName: node.displayName,
    metadata: Map<String, Object?>.unmodifiable({
      for (final entry in node.metadata.entries)
        entry.key: _freezeMetadataValue(entry.value),
    }),
  );

  Object? _freezeMetadataValue(Object? value) {
    if (value is Map) {
      return Map<Object?, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key: _freezeMetadataValue(entry.value),
      });
    }
    if (value is List) {
      return List<Object?>.unmodifiable(
        value.map<Object?>(_freezeMetadataValue),
      );
    }
    if (value is Set) {
      return Set<Object?>.unmodifiable(
        value.map<Object?>(_freezeMetadataValue),
      );
    }
    return value;
  }

  bool _sameNodeDefinition(GraphNode left, GraphNode right) =>
      left.kind == right.kind &&
      left.origin == right.origin &&
      left.sizeBytes == right.sizeBytes &&
      left.sha256 == right.sha256 &&
      left.displayName == right.displayName &&
      const DeepCollectionEquality().equals(left.metadata, right.metadata);

  String _nodeFingerprint(GraphNode node) => _joinFingerprintParts([
    node.kind.name,
    node.origin.toString(),
    node.sizeBytes?.toString() ?? '',
    node.sha256 ?? '',
    node.displayName ?? '',
    _metadataFingerprint(node.metadata),
  ]);

  String _metadataFingerprint(Map<String, Object?> metadata) {
    final entries = metadata.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return _joinFingerprintParts(
      entries.map(
        (entry) => _joinFingerprintParts([
          entry.key,
          _metadataValueFingerprint(entry.value),
        ]),
      ),
    );
  }

  String _metadataValueFingerprint(Object? value) {
    if (value == null) return 'null';
    if (value is String) return _joinFingerprintParts(['string', value]);
    if (value is num || value is bool) {
      return _joinFingerprintParts([value.runtimeType.toString(), '$value']);
    }
    if (value is Map) {
      final entries = value.entries.toList()
        ..sort(
          (left, right) => _metadataValueFingerprint(
            left.key,
          ).compareTo(_metadataValueFingerprint(right.key)),
        );
      return _joinFingerprintParts([
        'map',
        ...entries.map(
          (entry) => _joinFingerprintParts([
            _metadataValueFingerprint(entry.key),
            _metadataValueFingerprint(entry.value),
          ]),
        ),
      ]);
    }
    if (value is List) {
      return _joinFingerprintParts([
        'list',
        ...value.map(_metadataValueFingerprint),
      ]);
    }
    if (value is Set) {
      final items = value.map(_metadataValueFingerprint).toList()..sort();
      return _joinFingerprintParts(['set', ...items]);
    }
    return _joinFingerprintParts([value.runtimeType.toString(), '$value']);
  }

  String _joinFingerprintParts(Iterable<String> parts) =>
      parts.map((part) => '${part.length}:$part').join('|');

  /// Adapter that first inventoried [nodeId].
  String? nodeOwner(String nodeId) => _nodeOwners[nodeId];

  /// Every adapter that contributed the node itself.
  Set<String> nodeContributors(String nodeId) =>
      Set.unmodifiable(_nodeContributors[nodeId] ?? const {});

  /// Adds [edge].
  ///
  /// Endpoints do not need to exist yet; adapters run in an arbitrary order and
  /// may reference nodes another adapter contributes. Call [danglingEdges] after
  /// all adapters have run to audit unresolved endpoints.
  void addEdge(GraphEdge edge) {
    if (_edges.add(edge)) {
      (_outgoing[edge.from] ??= {}).add(edge);
      (_incoming[edge.to] ??= {}).add(edge);
      _markMutated();
    }
  }

  /// Looks up a node by id.
  GraphNode? node(String id) => _nodes[id];

  /// Whether a node with [id] exists.
  bool hasNode(String id) => _nodes.containsKey(id);

  /// Nodes of a given [kind].
  Iterable<GraphNode> nodesOfKind(NodeKind kind) =>
      _nodes.values.where((n) => n.kind == kind);

  /// Marks [nodeId] as a root: an entry point reachability starts from.
  ///
  /// Roots are far broader than `main()`. They include `@pragma('vm:entry-point')`
  /// functions, plugin background handlers invoked by native code, externally
  /// addressable deep links and user keep rules. Missing a root is what turns
  /// into a production-breaking false positive.
  void addRoot(
    String nodeId, {
    required String reason,
    BuildCondition condition = BuildCondition.unconditional,
  }) {
    final records = _roots.putIfAbsent(nodeId, () => []);
    final duplicate = records.any(
      (record) => record.reason == reason && record.condition == condition,
    );
    if (!duplicate) {
      records.add(_RootRecord(reason, condition));
      _markMutated();
    }
  }

  /// Marks [nodeId] as protected — never eligible for automatic removal.
  ///
  /// Protection is absolute and beats every other rule. Use it for entry points,
  /// native callbacks, security-sensitive resources and explicit keep rules.
  void protect(String nodeId, {required String reason, String? producer}) {
    (_protections[nodeId] ??= []).add(_Protection(reason, producer));
    _markMutated();
  }

  /// Records an unresolved dynamic construct.
  ///
  /// Blockers never delete anything; they only lower confidence. This asymmetry
  /// is intentional.
  void addBlocker(Blocker blocker) {
    _blockers.add(blocker);
    final addressedNodeIds = <String>{};
    for (final nodeId in _nodes.keys) {
      if (!blocker.couldAddress(nodeId)) continue;
      addressedNodeIds.add(nodeId);
      (_blockersByNode[nodeId] ??= []).add(blocker);
    }
    _nodesByBlocker[blocker] = addressedNodeIds;
    _markMutated();
  }

  /// Reasons [nodeId] is protected, empty when it is not.
  List<String> protectionReasons(String nodeId) =>
      _protections[nodeId]?.map((p) => p.reason).toList(growable: false) ??
      const [];

  /// Whether [nodeId] is protected.
  bool isProtected(String nodeId) => _protections.containsKey(nodeId);

  /// Blockers that could plausibly address [nodeId].
  List<Blocker> blockersFor(String nodeId) {
    if (_nodes.containsKey(nodeId)) {
      return List<Blocker>.unmodifiable(_blockersByNode[nodeId] ?? const []);
    }
    return _blockers
        .where((blocker) => blocker.couldAddress(nodeId))
        .toList(growable: false);
  }

  /// Edges leaving [nodeId].
  Iterable<GraphEdge> outgoingFrom(String nodeId) =>
      UnmodifiableSetView(_outgoing[nodeId] ?? const {});

  /// Edges entering [nodeId].
  /// Uses the incoming-edge index and is linear only in the node's in-degree.
  Iterable<GraphEdge> incomingTo(String nodeId) =>
      UnmodifiableSetView(_incoming[nodeId] ?? const {});

  /// Edges whose endpoints are not registered nodes.
  ///
  /// A non-empty result usually means an adapter emitted a malformed node id.
  /// Surface this in `--verbose` output rather than failing silently.
  Iterable<GraphEdge> danglingEdges() => _edges.where(
    (e) => !_nodes.containsKey(e.from) || !_nodes.containsKey(e.to),
  );

  /// Dangling edges that can participate in at least one configured target.
  Iterable<GraphEdge> danglingEdgesFor(Iterable<BuildTarget> targets) {
    final targetList = targets.toList(growable: false);
    return danglingEdges().where(
      (edge) => targetList.any(edge.condition.appliesTo),
    );
  }

  /// Root IDs without registered nodes that apply to a configured target.
  Iterable<String> danglingRootIdsFor(Iterable<BuildTarget> targets) {
    final targetList = targets.toList(growable: false);
    return _roots.entries
        .where(
          (entry) =>
              !_nodes.containsKey(entry.key) &&
              entry.value.any(
                (record) => targetList.any(record.condition.appliesTo),
              ),
        )
        .map((entry) => entry.key);
  }

  /// Computes the set of node ids reachable for [target].
  ///
  /// Traverses breadth-first from the roots that apply to [target], following
  /// only edges whose condition applies to [target].
  Set<String> reachableFor(BuildTarget target) {
    return Set<String>.of(_analyzeTarget(target).reachable);
  }

  _CachedTargetAnalysis _analyzeTarget(BuildTarget target) {
    final key = _targetKey(target);
    final cached = _targetAnalysisCache[key];
    if (cached != null && cached.mutationVersion == _mutationVersion) {
      return cached;
    }

    final retained = _computeRetained(target);
    final reached = <String>{};
    final queue = <String>[];

    for (final entry in _roots.entries) {
      if (entry.value.any((record) => record.condition.appliesTo(target))) {
        if (reached.add(entry.key)) queue.add(entry.key);
      }
    }

    // Protected and actively blocked nodes remain reportable in their own
    // confidence tiers, but their dependencies cannot be deleted
    // independently. Seed traversal from the full retention closure without
    // marking each retained seed itself reachable.
    for (final seed in retained) {
      for (final edge in outgoingFrom(seed)) {
        if (!edge.condition.appliesTo(target)) continue;
        if (reached.add(edge.to)) queue.add(edge.to);
      }
    }

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in outgoingFrom(current)) {
        if (!edge.condition.appliesTo(target)) continue;
        if (reached.add(edge.to)) queue.add(edge.to);
      }
    }

    final analysis = _CachedTargetAnalysis(
      mutationVersion: _mutationVersion,
      retained: Set<String>.unmodifiable(retained),
      reachable: Set<String>.unmodifiable(reached),
    );
    _targetAnalysisCache[key] = analysis;
    return analysis;
  }

  /// Computes nodes that must be retained for [target].
  ///
  /// Retention is broader than reachability: protected nodes and nodes covered
  /// by active blockers must survive even when no root reaches them. A blocker
  /// with a known source is active only while that source is itself retained.
  /// Missing or source-less blockers remain active so incomplete analysis fails
  /// closed.
  ///
  /// The least fixed point prevents both unsafe under-propagation (a blocker
  /// sourced from a blocked node remains active) and needless over-propagation
  /// (a blocker sourced only from a removable node stays inactive).
  Set<String> retainedFor(BuildTarget target) =>
      Set<String>.of(_analyzeTarget(target).retained);

  Set<String> _computeRetained(BuildTarget target) {
    final retained = <String>{};
    final queue = <String>[];

    void retain(String nodeId) {
      if (retained.add(nodeId)) queue.add(nodeId);
    }

    for (final entry in _roots.entries) {
      if (entry.value.any((record) => record.condition.appliesTo(target))) {
        retain(entry.key);
      }
    }
    for (final nodeId in _protections.keys) {
      retain(nodeId);
    }

    var changed = true;
    while (changed) {
      changed = false;

      while (queue.isNotEmpty) {
        final current = queue.removeLast();
        for (final edge in outgoingFrom(current)) {
          if (!edge.condition.appliesTo(target)) continue;
          if (retained.add(edge.to)) {
            queue.add(edge.to);
            changed = true;
          }
        }
      }

      for (final blocker in _blockers) {
        final sourceNodeId = blocker.sourceNodeId;
        final sourceIsRetained =
            sourceNodeId == null ||
            !_nodes.containsKey(sourceNodeId) ||
            retained.contains(sourceNodeId);
        if (!sourceIsRetained) continue;

        for (final nodeId in _nodesByBlocker[blocker] ?? const <String>{}) {
          if (retained.add(nodeId)) {
            queue.add(nodeId);
            changed = true;
          }
        }
      }
    }

    return retained;
  }

  String _targetKey(BuildTarget target) {
    final defines = target.dartDefines.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    return _joinFingerprintParts([
      target.name,
      target.platform,
      target.entrypoint,
      target.flavor ?? '',
      ...defines.map(
        (entry) => _joinFingerprintParts([entry.key, entry.value]),
      ),
    ]);
  }

  void _markMutated() {
    _mutationVersion++;
    _targetAnalysisCache.clear();
  }

  /// Computes reachability across [targets], keyed by target name.
  Map<String, Set<String>> reachableForAll(Iterable<BuildTarget> targets) {
    final result = <String, Set<String>>{};
    for (final target in targets) {
      if (result.containsKey(target.name)) {
        throw ArgumentError.value(
          target.name,
          'targets',
          'Build target names must be unique.',
        );
      }
      result[target.name] = reachableFor(target);
    }
    return result;
  }

  /// Node ids unreachable under **every** target in [targets].
  ///
  /// This is the only correct basis for a dead-node claim. Passing an
  /// incomplete target list is a correctness bug, not a tuning choice: it is
  /// how something reachable only in `staging` gets reported as dead.
  Set<String> unreachableAcrossAll(Iterable<BuildTarget> targets) {
    final targetList = targets.toList(growable: false);
    if (targetList.isEmpty) {
      throw ArgumentError.value(
        targets,
        'targets',
        'At least one build target is required. Without a target list every '
            'node would appear unreachable.',
      );
    }

    final reachableAnywhere = <String>{};
    for (final target in targetList) {
      reachableAnywhere.addAll(reachableFor(target));
    }

    return _nodes.keys.where((id) => !reachableAnywhere.contains(id)).toSet();
  }
}

class _RootRecord {
  const _RootRecord(this.reason, this.condition);

  final String reason;
  final BuildCondition condition;
}

class _Protection {
  const _Protection(this.reason, this.producer);

  final String reason;
  final String? producer;
}

class _CachedTargetAnalysis {
  const _CachedTargetAnalysis({
    required this.mutationVersion,
    required this.retained,
    required this.reachable,
  });

  final int mutationVersion;
  final Set<String> retained;
  final Set<String> reachable;
}
