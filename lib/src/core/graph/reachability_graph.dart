import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';

import 'blocker_identity.dart';
import 'build_condition.dart';
import 'edge.dart';
import 'evidence.dart';
import 'execution_context_identity.dart';
import 'execution_target.dart';
import 'node.dart';
import 'root.dart';

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
  final Map<String, List<GraphRootRecord>> _roots = {};
  final Map<String, AuxiliaryExecutionTarget> _auxiliaryExecutionTargets = {};
  final List<AuxiliaryExecutionTargetRegistryIssue>
  _auxiliaryExecutionTargetIssues = [];
  final Set<String> _auxiliaryConflictFingerprints = {};
  final Map<String, List<_Protection>> _protections = {};
  final List<Blocker> _blockers = [];
  final Set<BlockerIdentity> _blockerIdentities = {};
  final Map<String, List<Blocker>> _blockersByNode = {};
  final Map<String, List<Blocker>> _blockersBySourceNode = {};
  final Map<Blocker, Set<String>> _nodesByBlocker = {};
  final Set<String> _conflictingNodeIds = {};
  final Map<String, _CachedTargetAnalysis> _targetAnalysisCache = {};
  _CachedAuxiliaryAnalysis? _auxiliaryAnalysisCache;
  final Map<String, _CachedGraphIntegrity> _graphIntegrityCache = {};
  int _mutationVersion = 0;

  /// All nodes, in insertion order.
  Iterable<GraphNode> get nodes => UnmodifiableMapView(_nodes).values;

  /// All edges.
  Iterable<GraphEdge> get edges => UnmodifiableSetView(_edges);

  /// All recorded blockers.
  Iterable<Blocker> get blockers => UnmodifiableListView(_blockers);

  /// Node ids registered as roots.
  Iterable<String> get rootIds => UnmodifiableMapView(_roots).keys;

  /// Immutable configured and auxiliary root facts in insertion order.
  List<GraphRootRecord> get rootRecords =>
      List.unmodifiable(_roots.values.expand((records) => records));

  /// Registered auxiliary execution targets in stable ID order.
  List<AuxiliaryExecutionTarget> get auxiliaryExecutionTargets =>
      List.unmodifiable(
        _auxiliaryExecutionTargets.values.toList()
          ..sort((left, right) => left.id.compareTo(right.id)),
      );

  /// Rejected conflicting auxiliary definitions in observation order.
  List<AuxiliaryExecutionTargetRegistryIssue>
  get auxiliaryExecutionTargetIssues =>
      List.unmodifiable(_auxiliaryExecutionTargetIssues);

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
    final existing = _edges.lookup(edge);
    if (existing == null) {
      _edges.add(edge);
      (_outgoing[edge.from] ??= {}).add(edge);
      (_incoming[edge.to] ??= {}).add(edge);
      _markMutated();
      return;
    }
    if (!_preferEdge(edge, existing)) return;
    _edges
      ..remove(existing)
      ..add(edge);
    _outgoing[edge.from]!
      ..remove(existing)
      ..add(edge);
    _incoming[edge.to]!
      ..remove(existing)
      ..add(edge);
    _markMutated();
  }

  bool _preferEdge(GraphEdge candidate, GraphEdge accepted) {
    if (candidate.isExact != accepted.isExact) return candidate.isExact;
    return _evidenceFingerprint(
          candidate.evidence,
        ).compareTo(_evidenceFingerprint(accepted.evidence)) <
        0;
  }

  String _evidenceFingerprint(Evidence evidence) => _joinFingerprintParts([
    evidence.kind.name,
    evidence.producer,
    evidence.description,
    evidence.exact.toString(),
    evidence.location ?? '',
  ]);

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
    final record = ConfiguredGraphRootRecord(
      nodeId: nodeId,
      reason: reason,
      condition: condition,
    );
    if (!records.contains(record)) {
      records.add(record);
      _markMutated();
    }
  }

  /// Registers an immutable auxiliary target definition.
  void addAuxiliaryExecutionTarget(AuxiliaryExecutionTarget target) {
    _registerAuxiliaryExecutionTarget(target);
  }

  bool _registerAuxiliaryExecutionTarget(AuxiliaryExecutionTarget target) {
    final frozen = AuxiliaryExecutionTarget(
      id: target.id,
      domain: target.domain,
      environmentValues: target.environmentValues,
      environmentComplete: target.environmentComplete,
      reason: target.reason,
      sourceConfiguredTarget: target.sourceConfiguredTarget,
    );
    final accepted = _auxiliaryExecutionTargets[frozen.id];
    if (accepted == null) {
      _auxiliaryExecutionTargets[frozen.id] = frozen;
      _markMutated();
      return true;
    }
    if (accepted == frozen) return true;

    final acceptedHash = _auxiliaryDefinitionSha256(accepted);
    final rejectedHash = _auxiliaryDefinitionSha256(frozen);
    final conflictKey = '$acceptedHash:$rejectedHash';
    if (_auxiliaryConflictFingerprints.add(conflictKey)) {
      _auxiliaryExecutionTargetIssues.add(
        AuxiliaryExecutionTargetRegistryIssue(
          id: frozen.id,
          acceptedDefinitionSha256: acceptedHash,
          rejectedDefinitionSha256: rejectedHash,
          reason: 'conflicting auxiliary execution target definition',
        ),
      );
      addBlocker(
        Blocker(
          producer: 'graph',
          reason:
              'conflicting auxiliary execution target definition for ${frozen.id}',
        ),
      );
      _markMutated();
    }
    return false;
  }

  /// Atomically registers [executionTarget] and adds an exact auxiliary root.
  void addAuxiliaryRoot(
    String nodeId, {
    required String reason,
    required AuxiliaryExecutionTarget executionTarget,
  }) {
    if (!_registerAuxiliaryExecutionTarget(executionTarget)) return;
    final accepted = _auxiliaryExecutionTargets[executionTarget.id]!;
    final records = _roots.putIfAbsent(nodeId, () => []);
    final record = AuxiliaryGraphRootRecord(
      nodeId: nodeId,
      reason: reason,
      executionTargetId: accepted.id,
    );
    if (!records.contains(record)) {
      records.add(record);
      _markMutated();
    }
  }

  String _auxiliaryDefinitionSha256(AuxiliaryExecutionTarget target) {
    final environment = target.environmentValues.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    final source = target.sourceConfiguredTarget;
    final sourceDefines = source?.dartDefines.entries.toList()
      ?..sort((left, right) => left.key.compareTo(right.key));
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'id': target.id,
              'domain': target.domain.name,
              'environmentValues': {
                for (final entry in environment) entry.key: entry.value,
              },
              'environmentComplete': target.environmentComplete,
              'reason': target.reason,
              'sourceConfiguredTarget': source == null
                  ? null
                  : {
                      'name': source.name,
                      'platform': source.platform,
                      'entrypoint': source.entrypoint,
                      'flavor': source.flavor,
                      'dartDefines': {
                        for (final entry in sourceDefines!)
                          entry.key: entry.value,
                      },
                    },
            }),
          ),
        )
        .toString();
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
    final identity = BlockerIdentity(blocker);
    if (!_blockerIdentities.add(identity)) return;
    _blockers.add(blocker);
    final sourceNodeId = blocker.sourceNodeId;
    if (sourceNodeId != null) {
      (_blockersBySourceNode[sourceNodeId] ??= []).add(blocker);
    }
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
  List<String> protectionReasons(String nodeId) => List.unmodifiable(
    _protections[nodeId]?.map((p) => p.reason) ?? const <String>[],
  );

  /// Whether [nodeId] is protected.
  bool isProtected(String nodeId) => _protections.containsKey(nodeId);

  /// Blockers that could plausibly address [nodeId].
  List<Blocker> blockersFor(String nodeId) {
    if (_nodes.containsKey(nodeId)) {
      return List<Blocker>.unmodifiable(_blockersByNode[nodeId] ?? const []);
    }
    return List.unmodifiable(
      _blockers.where((blocker) => blocker.couldAddress(nodeId)),
    );
  }

  /// Whether a recorded [blocker] addresses at least one registered node.
  ///
  /// Uses the blocker-to-node index maintained during graph construction, so
  /// report projections do not need to rescan the complete node inventory.
  bool blockerAddressesAnyNode(Blocker blocker) =>
      _nodesByBlocker[blocker]?.isNotEmpty ?? false;

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
                (record) =>
                    record is ConfiguredGraphRootRecord &&
                    targetList.any(record.condition.appliesTo),
              ),
        )
        .map((entry) => entry.key);
  }

  /// Computes the set of node ids reachable for [target].
  ///
  /// Traverses breadth-first from the roots that apply to [target], following
  /// only edges whose condition applies to [target].
  Set<String> reachableFor(BuildTarget target) {
    return Set<String>.unmodifiable(analyzeFor(target).legacyReachable);
  }

  /// Computes all configured, auxiliary, proven and retained projections.
  TargetReachability analyzeFor(BuildTarget target) {
    final frozenTarget = BuildTarget.snapshot(target);
    final key = _targetKey(frozenTarget);
    final cached = _targetAnalysisCache[key];
    if (cached != null && cached.mutationVersion == _mutationVersion) {
      return cached.analysis;
    }

    final auxiliary = analyzeAuxiliary();
    final configuredProven = _computeConfiguredProven(frozenTarget);
    final configuredRetained = _computeConfiguredRetained(frozenTarget);
    final provenReachable = <String>{...configuredProven, ...auxiliary.proven};
    final retained = <String>{...configuredRetained, ...auxiliary.retained};
    final analysis = TargetReachability(
      configuredProven: configuredProven,
      configuredRetained: configuredRetained,
      auxiliaryProven: auxiliary.proven,
      auxiliaryRetained: auxiliary.retained,
      provenReachable: provenReachable,
      retained: retained,
      legacyReachable: _computeLegacyReachable(
        frozenTarget,
        configuredRetained,
        auxiliary.retained,
      ),
    );
    _targetAnalysisCache[key] = _CachedTargetAnalysis(
      mutationVersion: _mutationVersion,
      analysis: analysis,
    );
    return analysis;
  }

  /// Computes and caches every registered auxiliary closure.
  AuxiliaryReachability analyzeAuxiliary() {
    _materializeAuxiliaryConditionBlockers();
    final cached = _auxiliaryAnalysisCache;
    if (cached != null && cached.mutationVersion == _mutationVersion) {
      return cached.analysis;
    }

    final provenByTarget = <String, Set<String>>{};
    final retainedByTarget = <String, Set<String>>{};
    final proven = <String>{};
    final retained = <String>{};
    final incomplete = <String>{};
    for (final target in auxiliaryExecutionTargets) {
      final targetProven = _computeAuxiliaryProven(target);
      final targetRetained = _computeAuxiliaryRetained(target);
      provenByTarget[target.id] = targetProven;
      retainedByTarget[target.id] = targetRetained;
      proven.addAll(targetProven);
      retained.addAll(targetRetained);
      if (!target.environmentComplete ||
          _edges.any(
            (edge) =>
                edge.condition.applicabilityToAuxiliaryTarget(target) ==
                ConditionApplicability.unknown,
          )) {
        incomplete.add(target.id);
      }
    }
    final analysis = AuxiliaryReachability(
      provenByExecutionTarget: provenByTarget,
      retainedByExecutionTarget: retainedByTarget,
      proven: proven,
      retained: retained,
      incompleteExecutionTargetIds: incomplete,
      registryIssues: _auxiliaryExecutionTargetIssues,
    );
    _auxiliaryAnalysisCache = _CachedAuxiliaryAnalysis(
      mutationVersion: _mutationVersion,
      analysis: analysis,
    );
    return analysis;
  }

  void _materializeAuxiliaryConditionBlockers() {
    final facts = <({AuxiliaryExecutionTarget target, GraphEdge edge})>[];
    for (final target in _auxiliaryExecutionTargets.values) {
      for (final edge in _edges) {
        if (edge.condition.applicabilityToAuxiliaryTarget(target) ==
            ConditionApplicability.unknown) {
          facts.add((target: target, edge: edge));
        }
      }
    }
    for (final fact in facts) {
      addBlocker(
        Blocker(
          producer: 'graph',
          reason:
              'condition applicability is incomplete for ${fact.target.id}: '
              '${fact.edge.from} -> ${fact.edge.to}',
          affectedNodeIds: {fact.edge.to},
        ),
      );
    }
  }

  Set<String> _computeConfiguredProven(BuildTarget target) {
    final seeds = <String>{
      for (final entry in _roots.entries)
        if (entry.value.any(
          (record) =>
              record is ConfiguredGraphRootRecord &&
              record.condition.appliesTo(target),
        ))
          entry.key,
    };
    return _traverse(seeds, (edge) {
      return edge.isExact && edge.condition.appliesTo(target);
    });
  }

  Set<String> _computeAuxiliaryProven(AuxiliaryExecutionTarget target) {
    if (!target.environmentComplete) return const <String>{};
    final seeds = <String>{
      for (final entry in _roots.entries)
        if (entry.value.any(
          (record) =>
              record is AuxiliaryGraphRootRecord &&
              record.executionTargetId == target.id,
        ))
          entry.key,
    };
    return _traverse(seeds, (edge) {
      return edge.isExact &&
          edge.condition.applicabilityToAuxiliaryTarget(target) ==
              ConditionApplicability.applies;
    });
  }

  Set<String> _traverse(
    Iterable<String> seeds,
    bool Function(GraphEdge edge) follows,
  ) {
    final reached = <String>{};
    final queue = <String>[];
    for (final seed in seeds) {
      if (reached.add(seed)) queue.add(seed);
    }
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in _outgoing[current] ?? const <GraphEdge>{}) {
        if (!follows(edge)) continue;
        if (reached.add(edge.to)) queue.add(edge.to);
      }
    }
    return reached;
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
  Set<String> retainedFor(BuildTarget target) => analyzeFor(target).retained;

  /// Configured-target retention excluding every auxiliary context.
  Set<String> configuredRetainedFor(BuildTarget target) =>
      analyzeFor(target).configuredRetained;

  /// Exact configured-target closure excluding every auxiliary context.
  Set<String> configuredProvenFor(BuildTarget target) =>
      analyzeFor(target).configuredProven;

  /// Union of configured and auxiliary exact closures.
  Set<String> provenReachableFor(BuildTarget target) =>
      analyzeFor(target).provenReachable;

  /// Union of exact closures for every registered auxiliary target.
  Set<String> auxiliaryProven() => analyzeAuxiliary().proven;

  /// Union of fail-closed retention for every auxiliary target.
  Set<String> auxiliaryRetained() => analyzeAuxiliary().retained;

  Set<String> _computeConfiguredRetained(BuildTarget target) =>
      _computeRetained(
        rootApplies: (record) =>
            record is ConfiguredGraphRootRecord &&
            record.condition.appliesTo(target),
        edgeApplies: (edge) => edge.condition.appliesTo(target),
      );

  Set<String> _computeAuxiliaryRetained(AuxiliaryExecutionTarget target) =>
      _computeRetained(
        rootApplies: (record) =>
            record is AuxiliaryGraphRootRecord &&
            record.executionTargetId == target.id,
        edgeApplies: (edge) =>
            edge.condition.applicabilityToAuxiliaryTarget(target) !=
            ConditionApplicability.doesNotApply,
      );

  Set<String> _computeRetained({
    required bool Function(GraphRootRecord record) rootApplies,
    required bool Function(GraphEdge edge) edgeApplies,
  }) {
    final retained = <String>{};
    final queue = <String>[];
    final activatedBlockers = <Blocker>{};

    void retain(String nodeId) {
      if (retained.add(nodeId)) queue.add(nodeId);
    }

    void activate(Blocker blocker) {
      if (!activatedBlockers.add(blocker)) return;
      for (final nodeId in _nodesByBlocker[blocker] ?? const <String>{}) {
        retain(nodeId);
      }
    }

    for (final entry in _roots.entries) {
      if (entry.value.any(rootApplies)) {
        retain(entry.key);
      }
    }
    for (final nodeId in _protections.keys) {
      retain(nodeId);
    }

    for (final blocker in _blockers) {
      final sourceNodeId = blocker.sourceNodeId;
      if (sourceNodeId == null || !_nodes.containsKey(sourceNodeId)) {
        activate(blocker);
      }
    }

    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in outgoingFrom(current)) {
        if (!edgeApplies(edge)) continue;
        retain(edge.to);
      }
      for (final blocker
          in _blockersBySourceNode[current] ?? const <Blocker>[]) {
        activate(blocker);
      }
    }

    return retained;
  }

  Set<String> _computeLegacyReachable(
    BuildTarget target,
    Set<String> configuredRetained,
    Set<String> auxiliaryRetained,
  ) {
    bool edgeApplies(GraphEdge edge) {
      if (edge.condition.appliesTo(target)) return true;
      return _auxiliaryExecutionTargets.values.any(
        (auxiliary) =>
            edge.condition.applicabilityToAuxiliaryTarget(auxiliary) !=
            ConditionApplicability.doesNotApply,
      );
    }

    final reached = <String>{
      for (final entry in _roots.entries)
        if (entry.value.any(
          (record) =>
              record is AuxiliaryGraphRootRecord ||
              (record is ConfiguredGraphRootRecord &&
                  record.condition.appliesTo(target)),
        ))
          entry.key,
    };
    final queue = reached.toList();
    for (final seed in {...configuredRetained, ...auxiliaryRetained}) {
      for (final edge in _outgoing[seed] ?? const <GraphEdge>{}) {
        if (!edgeApplies(edge)) continue;
        if (reached.add(edge.to)) queue.add(edge.to);
      }
    }
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      for (final edge in _outgoing[current] ?? const <GraphEdge>{}) {
        if (!edgeApplies(edge)) continue;
        if (reached.add(edge.to)) queue.add(edge.to);
      }
    }
    return reached;
  }

  /// Computes one immutable integrity snapshot over every execution context.
  GraphIntegrity integrityFor(Iterable<BuildTarget> configuredTargets) {
    // Integrity is the graph's final preparation boundary. Condition facts
    // must exist before the immutable snapshot is cached so later reachability
    // and finding reads cannot invalidate the instance consumed by reports.
    _materializeAuxiliaryConditionBlockers();
    final targets = configuredTargets.map(BuildTarget.snapshot).toList();
    if (targets.map((target) => target.name).toSet().length != targets.length) {
      throw ArgumentError.value(
        configuredTargets,
        'configuredTargets',
        'Build target names must be unique.',
      );
    }
    final executionTargetIds = targets
        .map(_configuredExecutionTargetId)
        .toList(growable: false);
    if (executionTargetIds.toSet().length != executionTargetIds.length) {
      throw ArgumentError.value(
        configuredTargets,
        'configuredTargets',
        'Build targets must produce unique app execution-context IDs.',
      );
    }
    final targetKey = targets.map(_targetKey).toList()..sort();
    final cacheKey = targetKey.join('||');
    final cached = _graphIntegrityCache[cacheKey];
    if (cached != null && cached.mutationVersion == _mutationVersion) {
      return cached.integrity;
    }

    final dangling = danglingEdges().toSet();
    final byTarget = <String, ExecutionTargetIntegrity>{};
    for (final target in targets) {
      final danglingRoots = <String>{
        for (final entry in _roots.entries)
          if (!_nodes.containsKey(entry.key) &&
              entry.value.any(
                (record) =>
                    record is ConfiguredGraphRootRecord &&
                    record.condition.appliesTo(target),
              ))
            entry.key,
      };
      final executionTargetId = _configuredExecutionTargetId(target);
      byTarget[executionTargetId] = ExecutionTargetIntegrity(
        id: executionTargetId,
        domain: RootDomain.configuredTarget,
        danglingEdges: {
          for (final edge in dangling)
            if (edge.condition.appliesTo(target)) edge,
        },
        danglingRootIds: danglingRoots,
      );
    }

    for (final target in auxiliaryExecutionTargets) {
      final unknownEdges = <GraphEdge>{
        for (final edge in _edges)
          if (edge.condition.applicabilityToAuxiliaryTarget(target) ==
              ConditionApplicability.unknown)
            edge,
      };
      byTarget[target.id] = ExecutionTargetIntegrity(
        id: target.id,
        domain: RootDomain.auxiliary,
        danglingEdges: {
          for (final edge in dangling)
            if (edge.condition.applicabilityToAuxiliaryTarget(target) !=
                ConditionApplicability.doesNotApply)
              edge,
        },
        danglingRootIds: {
          for (final entry in _roots.entries)
            if (!_nodes.containsKey(entry.key) &&
                entry.value.any(
                  (record) =>
                      record is AuxiliaryGraphRootRecord &&
                      record.executionTargetId == target.id,
                ))
              entry.key,
        },
        incompleteReasons: {
          if (unknownEdges.isNotEmpty) 'condition-applicability-unknown',
        },
      );
    }

    bool edgeHasContext(GraphEdge edge) =>
        targets.any(edge.condition.appliesTo) ||
        _auxiliaryExecutionTargets.values.any(
          (target) =>
              edge.condition.applicabilityToAuxiliaryTarget(target) !=
              ConditionApplicability.doesNotApply,
        );
    final unattributedEdges = {
      for (final edge in dangling)
        if (!edgeHasContext(edge)) edge,
    };
    final unattributedRoots = <String>{};
    for (final entry in _roots.entries) {
      if (_nodes.containsKey(entry.key)) continue;
      for (final record in entry.value) {
        final attributed = switch (record) {
          ConfiguredGraphRootRecord() => targets.any(
            record.condition.appliesTo,
          ),
          AuxiliaryGraphRootRecord() => _auxiliaryExecutionTargets.containsKey(
            record.executionTargetId,
          ),
        };
        if (!attributed) unattributedRoots.add(entry.key);
      }
    }
    final integrity = GraphIntegrity(
      configuredTargets: targets.toSet(),
      byExecutionTarget: byTarget,
      unattributedDanglingEdges: unattributedEdges,
      unattributedDanglingRootIds: unattributedRoots,
      auxiliaryRegistryIssues: _auxiliaryExecutionTargetIssues,
    );
    _graphIntegrityCache[cacheKey] = _CachedGraphIntegrity(
      mutationVersion: _mutationVersion,
      integrity: integrity,
    );
    return integrity;
  }

  static String _configuredExecutionTargetId(BuildTarget target) =>
      configuredExecutionContextId(target.name);

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
    _auxiliaryAnalysisCache = null;
    _graphIntegrityCache.clear();
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
    return Map.unmodifiable(result);
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

    return Set.unmodifiable(
      _nodes.keys.where((id) => !reachableAnywhere.contains(id)),
    );
  }
}

class _Protection {
  const _Protection(this.reason, this.producer);

  final String reason;
  final String? producer;
}

class _CachedTargetAnalysis {
  const _CachedTargetAnalysis({
    required this.mutationVersion,
    required this.analysis,
  });

  final int mutationVersion;
  final TargetReachability analysis;
}

class _CachedAuxiliaryAnalysis {
  const _CachedAuxiliaryAnalysis({
    required this.mutationVersion,
    required this.analysis,
  });

  final int mutationVersion;
  final AuxiliaryReachability analysis;
}

class _CachedGraphIntegrity {
  const _CachedGraphIntegrity({
    required this.mutationVersion,
    required this.integrity,
  });

  final int mutationVersion;
  final GraphIntegrity integrity;
}
