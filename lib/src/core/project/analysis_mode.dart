/// Analysis boundary selected by the project owner.
enum AnalysisMode {
  /// Treat the configured application entrypoints as a closed world.
  application('application'),

  /// Audit a reusable package conservatively; findings are review-only.
  package('package'),

  /// Analyse only the package-local boundary and warn about external consumers.
  packageInternal('package-internal');

  const AnalysisMode(this.wireName);

  /// Stable YAML and report value.
  final String wireName;

  /// Parses the exact v1 wire value.
  static AnalysisMode parse(String value) {
    for (final mode in values) {
      if (mode.wireName == value) return mode;
    }
    throw FormatException(
      'Unsupported analysis.mode: $value. Use application, package, or '
      'package-internal.',
    );
  }

  /// Whether public package entry libraries must be declared.
  bool get requiresPublicEntrypoints => this != AnalysisMode.application;
}
