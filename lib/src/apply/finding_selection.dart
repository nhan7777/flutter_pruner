/// How an apply invocation chooses its logical findings.
enum FindingSelectionMode {
  /// Preserve the historical behavior of considering every eligible finding.
  allEligible,

  /// Consider only the exact, case-sensitive IDs requested by the user.
  exact,
}

/// Immutable finding allowlist for one apply invocation.
class FindingSelection {
  /// Parses repeatable `--finding-id` values.
  factory FindingSelection.fromCli(List<String> values) {
    if (values.isEmpty) return const FindingSelection._allEligible();
    if (values.any((value) => value.isEmpty)) {
      throw const FindingSelectionException(
        'Finding IDs must be non-empty exact values.',
      );
    }
    if (values.toSet().length != values.length) {
      throw const FindingSelectionException(
        'Duplicate --finding-id values are not allowed.',
      );
    }
    final requested = values.toList()..sort();
    return FindingSelection._(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: List<String>.unmodifiable(requested),
    );
  }

  const FindingSelection._allEligible()
    : mode = FindingSelectionMode.allEligible,
      requestedFindingIds = const [];

  const FindingSelection._({
    required this.mode,
    required this.requestedFindingIds,
  });

  /// Selection mode for this invocation.
  final FindingSelectionMode mode;

  /// Sorted exact IDs requested by the user.
  final List<String> requestedFindingIds;

  /// Whether this invocation uses an explicit hard allowlist.
  bool get isExact => mode == FindingSelectionMode.exact;

  /// Whether [findingId] is authorized by an exact selection.
  bool contains(String findingId) => requestedFindingIds.contains(findingId);
}

/// Invalid exact-selection CLI input.
class FindingSelectionException implements Exception {
  /// Creates a selection error safe to show as CLI usage guidance.
  const FindingSelectionException(this.message);

  /// User-facing explanation.
  final String message;

  @override
  String toString() => message;
}
