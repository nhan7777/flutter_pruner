/// Independent canonical-path grammar used by accuracy observation readers.
library;

/// Whether [value] is one normalized project-relative POSIX path.
///
/// This validator is deliberately implemented in the oracle and imports no
/// production path or project-boundary helper.
bool isCanonicalProjectRelativePosixPath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.contains(r'\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f)) {
    return false;
  }
  final segments = value.split('/');
  return segments.every(
    (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
  );
}

/// Whether [value] is a canonical relative path plus positive line/column.
bool isCanonicalProjectRelativePosixLocation(
  String value, {
  bool requireColumn = false,
}) {
  final lastSeparator = value.lastIndexOf(':');
  if (lastSeparator < 1 ||
      !_isPositiveDecimal(value.substring(lastSeparator + 1))) {
    return false;
  }
  var pathEnd = lastSeparator;
  final precedingSeparator = value.lastIndexOf(':', lastSeparator - 1);
  final hasColumn =
      precedingSeparator >= 1 &&
      _isPositiveDecimal(
        value.substring(precedingSeparator + 1, lastSeparator),
      );
  if (hasColumn) pathEnd = precedingSeparator;
  if (requireColumn && !hasColumn) return false;
  return isCanonicalProjectRelativePosixPath(value.substring(0, pathEnd));
}

bool _isPositiveDecimal(String value) =>
    RegExp(r'^[1-9][0-9]*$').hasMatch(value);
