import 'package:collection/collection.dart';

import 'evidence.dart';

/// Value identity for exact blocker deduplication.
final class BlockerIdentity {
  /// Snapshots the fields that determine whether two blockers are identical.
  BlockerIdentity(Blocker blocker)
    : _producer = blocker.producer,
      _reason = blocker.reason,
      _location = blocker.location,
      _sourceNodeId = blocker.sourceNodeId,
      _affectedNamespace = blocker.affectedNamespace,
      _affectedNodeIds = blocker.affectedNodeIds;

  static const _setEquality = SetEquality<String>();

  final String _producer;
  final String _reason;
  final String? _location;
  final String? _sourceNodeId;
  final String? _affectedNamespace;
  final Set<String> _affectedNodeIds;

  @override
  bool operator ==(Object other) =>
      other is BlockerIdentity &&
      _producer == other._producer &&
      _reason == other._reason &&
      _location == other._location &&
      _sourceNodeId == other._sourceNodeId &&
      _affectedNamespace == other._affectedNamespace &&
      _setEquality.equals(_affectedNodeIds, other._affectedNodeIds);

  @override
  int get hashCode => Object.hash(
    _producer,
    _reason,
    _location,
    _sourceNodeId,
    _affectedNamespace,
    _setEquality.hash(_affectedNodeIds),
  );
}

/// Returns the legacy canonical text used by stable JSON blocker IDs.
String blockerCanonicalKey(Blocker blocker) {
  final affectedIds = blocker.affectedNodeIds.toList()..sort();
  return [
    blocker.producer,
    blocker.reason,
    blocker.location ?? '',
    blocker.sourceNodeId ?? '',
    blocker.affectedNamespace ?? '',
    affectedIds.join(','),
  ].join('\u0000');
}
