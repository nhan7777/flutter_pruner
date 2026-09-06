import 'package:meta/meta.dart';

import '../graph/node.dart';
import 'action_risk_scope.dart';
import 'finding_generator.dart' show FindingGenerator;
import 'mutation_footprint.dart';

/// Deterministic inverse kind for action operations.
///
/// Describes whether an action has a well-defined, mechanical inverse operation
/// that can restore the exact prior state.
enum DeterministicInverseKind {
  /// The action has a proven deterministic inverse.
  ///
  /// Example: ARB byte-edit has exact restoration from journaled bytes.
  proven,

  /// The action's inverse exists but requires regeneration or is not byte-exact.
  ///
  /// Example: Deleting generated code can be reversed by re-running the
  /// generator, but the output may differ cosmetically.
  generative,

  /// The action has no reliable inverse operation.
  ///
  /// Example: Deleting a hand-written file with no backup.
  none;

  /// Whether this inverse kind is deterministic (proven or generative).
  bool get isDeterministic => this != DeterministicInverseKind.none;
}

/// Per-node action readiness metadata computed during static analysis.
///
/// Captures family-level capability information that cannot be derived from
/// a single [GraphNode] alone. Populated by the static action-readiness
/// resolver
/// after adapters finish but before finding generation.
@immutable
final class ActionReadinessEntry {
  /// Adapter that owns this node.
  final String adapterId;

  /// Node kind from the graph.
  final NodeKind nodeKind;

  /// Family identifier grouping related nodes into atomic units.
  ///
  /// For l10n: the family ID (e.g., 'app_localizations').
  /// For single-file actions: typically the node ID itself.
  final String familyId;

  /// Configuration fingerprint for this family.
  ///
  /// Used to detect drift between static analysis and runtime preflight.
  final String configurationFingerprint;

  /// Mutation footprint for this action.
  final MutationFootprint mutationFootprint;

  /// Deterministic inverse kind.
  final DeterministicInverseKind inverseKind;

  /// Action risk scope.
  final ActionRiskScope riskScope;

  /// Whether this node has external consumer exposure.
  ///
  /// True for package-internal mode where external dependents exist,
  /// false for application mode (closed world).
  final bool hasExternalConsumerExposure;

  /// Creates readiness metadata for one graph node.
  const ActionReadinessEntry({
    required this.adapterId,
    required this.nodeKind,
    required this.familyId,
    required this.configurationFingerprint,
    required this.mutationFootprint,
    required this.inverseKind,
    required this.riskScope,
    required this.hasExternalConsumerExposure,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionReadinessEntry &&
          runtimeType == other.runtimeType &&
          adapterId == other.adapterId &&
          nodeKind == other.nodeKind &&
          familyId == other.familyId &&
          configurationFingerprint == other.configurationFingerprint &&
          mutationFootprint == other.mutationFootprint &&
          inverseKind == other.inverseKind &&
          riskScope == other.riskScope &&
          hasExternalConsumerExposure == other.hasExternalConsumerExposure;

  @override
  int get hashCode => Object.hash(
    adapterId,
    nodeKind,
    familyId,
    configurationFingerprint,
    mutationFootprint,
    inverseKind,
    riskScope,
    hasExternalConsumerExposure,
  );

  @override
  String toString() =>
      'ActionReadinessEntry('
      'adapter: $adapterId, '
      'kind: $nodeKind, '
      'family: $familyId, '
      'scope: $riskScope'
      ')';
}

/// Immutable index of action readiness entries keyed by canonical node ID.
///
/// Returned by the static action-readiness resolver and consumed by
/// [FindingGenerator] to determine family-level action capabilities.
@immutable
final class ActionReadinessIndex {
  final Map<String, ActionReadinessEntry> _entries;

  const ActionReadinessIndex._(this._entries);

  /// Creates an index from a map of node ID to readiness entry.
  ///
  /// The map is copied and made unmodifiable.
  ActionReadinessIndex(Map<String, ActionReadinessEntry> entries)
    : _entries = Map.unmodifiable(entries);

  /// Looks up the readiness entry for a node ID.
  ///
  /// Returns null if the node has no readiness entry.
  ActionReadinessEntry? operator [](String nodeId) => _entries[nodeId];

  /// Checks if a node ID has a readiness entry.
  bool containsNode(String nodeId) => _entries.containsKey(nodeId);

  /// All readiness entries in this index.
  Iterable<ActionReadinessEntry> get entries => _entries.values;

  /// Number of entries in this index.
  int get length => _entries.length;

  /// Whether this index is empty.
  bool get isEmpty => _entries.isEmpty;

  /// Whether this index is not empty.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// An empty action readiness index (no entries).
  static const ActionReadinessIndex empty = ActionReadinessIndex._({});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ActionReadinessIndex &&
          runtimeType == other.runtimeType &&
          _mapEquals(_entries, other._entries);

  @override
  int get hashCode =>
      Object.hashAll(_entries.entries.map((e) => Object.hash(e.key, e.value)));

  @override
  String toString() => 'ActionReadinessIndex(entries: ${_entries.length})';

  static bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || a[key] != b[key]) return false;
    }
    return true;
  }
}
