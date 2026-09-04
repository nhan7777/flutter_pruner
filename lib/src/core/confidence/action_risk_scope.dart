/// Classification of action risk boundary for confidence assessment.
///
/// Distinguishes single-file operations, family-level bounded operations, and
/// open-ended broad operations. Used to determine confidence levels and
/// verification requirements.
enum ActionRiskScope {
  /// Single file or declaration.
  ///
  /// Examples: removing one Dart declaration, deleting one asset file.
  /// Existing narrow actions fall into this category.
  boundedSingle,

  /// Family-level proven actions with bounded scope.
  ///
  /// Examples: l10n ARB family (template + locales + generated outputs).
  /// All mutations are proven deterministic and reversible at family boundary.
  boundedFamily,

  /// Open-ended broad actions requiring manual intervention.
  ///
  /// Examples: existing broadRemovalScope behavior where impact analysis
  /// cannot prove bounded scope. Requires explicit user acknowledgement.
  openEnded;

  /// Whether this scope represents a family-level action.
  bool get isFamily => this == ActionRiskScope.boundedFamily;
}
