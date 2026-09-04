/// Action risk scope classification for mutation operations.
///
/// Splits the overloaded "scope" concept into explicit categories based on
/// the provable mutation breadth and deterministic inverse properties.
enum ActionRiskScope {
  /// Single file or declaration with narrow, proven impact.
  ///
  /// Existing narrow actions (single file edits, single declaration removals)
  /// map to this scope. No additional manual risk from breadth.
  boundedSingle,

  /// Family-level proven actions with mechanically derived breadth.
  ///
  /// Multiple files are touched, but the complete set is enumerated and proven
  /// deterministic. L10n ARB family + generated outputs map to this scope.
  /// Does not add `broadRemovalScope` manual risk.
  boundedFamily,

  /// Open-ended broad actions with unpredictable impact.
  ///
  /// Existing broad actions where the complete mutation set cannot be
  /// mechanically proven. Preserves current `broadRemovalScope` manual risk.
  openEnded,
}
