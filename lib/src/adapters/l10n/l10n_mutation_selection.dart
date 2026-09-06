import 'package:meta/meta.dart';

/// Selection metadata for one l10n family mutation.
///
/// Tracks the distinction between user-requested findings and any
/// findings included for atomicity/dependency reasons.
@immutable
final class L10nMutationSelection {
  /// Creates a selection record for one family mutation.
  const L10nMutationSelection({
    required this.requestedFindingIds,
    required this.effectiveFindingIds,
    required this.findingIdToKey,
    this.expansionReasons = const {},
  }) : assert(
         requestedFindingIds.length <= effectiveFindingIds.length,
         'Requested findings must be subset of effective findings',
       );

  /// Finding IDs explicitly requested by the user.
  ///
  /// For exact selection mode: exactly what user specified.
  /// For allEligible mode: all eligible findings after analysis.
  final Set<String> requestedFindingIds;

  /// All finding IDs included in this mutation.
  ///
  /// For exact selection: should equal [requestedFindingIds].
  /// No automatic expansion unless planner determined dependency.
  final Set<String> effectiveFindingIds;

  /// Maps finding ID to the l10n key it represents.
  ///
  /// Example: 'l10n:app.oldTitle' → 'oldTitle'
  final Map<String, String> findingIdToKey;

  /// Explanation for why expanded findings were included.
  ///
  /// Keys are finding IDs in [expandedFindingIds].
  /// Empty for exact selections with no expansion.
  final Map<String, String> expansionReasons;

  /// Finding IDs that were added beyond user selection.
  Set<String> get expandedFindingIds =>
      effectiveFindingIds.difference(requestedFindingIds);

  /// l10n keys corresponding to user-requested findings.
  Set<String> get requestedKeys => requestedFindingIds
      .map((id) => findingIdToKey[id])
      .whereType<String>()
      .toSet();

  /// All l10n keys included in this mutation.
  Set<String> get effectiveKeys => effectiveFindingIds
      .map((id) => findingIdToKey[id])
      .whereType<String>()
      .toSet();

  /// Whether any findings were added beyond user selection.
  bool get hasExpansion => expandedFindingIds.isNotEmpty;

  /// Validates that this selection is consistent.
  void validate() {
    // All requested must be in effective
    if (!effectiveFindingIds.containsAll(requestedFindingIds)) {
      throw ArgumentError(
        'Requested findings must be subset of effective findings',
      );
    }

    // All effective must have key mapping
    for (final findingId in effectiveFindingIds) {
      if (!findingIdToKey.containsKey(findingId)) {
        throw ArgumentError('Missing key mapping for finding: $findingId');
      }
    }

    // Expansion reasons only for expanded findings
    for (final findingId in expansionReasons.keys) {
      if (!expandedFindingIds.contains(findingId)) {
        throw ArgumentError(
          'Expansion reason for non-expanded finding: $findingId',
        );
      }
    }

    // All expanded findings should have reason (if any expansion)
    if (hasExpansion) {
      for (final findingId in expandedFindingIds) {
        if (!expansionReasons.containsKey(findingId)) {
          throw ArgumentError(
            'Missing expansion reason for finding: $findingId',
          );
        }
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nMutationSelection &&
          runtimeType == other.runtimeType &&
          _setEquals(requestedFindingIds, other.requestedFindingIds) &&
          _setEquals(effectiveFindingIds, other.effectiveFindingIds) &&
          _mapEquals(findingIdToKey, other.findingIdToKey) &&
          _mapEquals(expansionReasons, other.expansionReasons);

  @override
  int get hashCode => Object.hash(
    Object.hashAll(requestedFindingIds),
    Object.hashAll(effectiveFindingIds),
    Object.hashAllUnordered(
      findingIdToKey.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(
      expansionReasons.entries.map((e) => Object.hash(e.key, e.value)),
    ),
  );

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }

  static bool _mapEquals<K, V>(Map<K, V> a, Map<K, V> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) || b[entry.key] != entry.value) {
        return false;
      }
    }
    return true;
  }
}
