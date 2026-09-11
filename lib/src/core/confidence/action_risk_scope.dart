/// Action risk scope classification for removal actions.
///
/// Splits the overloaded "scope" concept into explicit risk boundaries.
enum ActionRiskScope {
  /// Single file/declaration, existing narrow actions.
  ///
  /// Example: removing one unused function in one file.
  boundedSingle,

  /// Family-level proven actions (l10n ARB family + generated outputs).
  ///
  /// Example: removing l10n keys across ARB files and their generated Dart.
  boundedFamily,

  /// Open-ended broad actions (existing broadRemovalScope behavior).
  ///
  /// Example: removing a widely-used base class affecting many files.
  openEnded;

  /// Whether this is a family-level scope.
  bool get isFamily => this == ActionRiskScope.boundedFamily;
}
