const _sha256Pattern = r'^[0-9a-f]{64}$';
const _runIdPattern = r'^\d{8}T\d{6}(?:\.\d{3,6})?Z_[0-9a-f]{20}$';
const _completedAtPattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z$';
const _tokenPattern = r'^[a-z][a-z0-9-]*$';
const _formats = {'json', 'html', 'text'};

/// Validates the primitive fields of one immutable report object record.
void validateReportObjectRecordFields({
  required String role,
  required String relativePath,
  required String format,
  required int reportSchemaVersion,
  required int byteLength,
  required String sha256,
}) {
  if (!RegExp(_tokenPattern).hasMatch(role)) {
    throw ArgumentError.value(role, 'role', 'Expected a canonical role token.');
  }
  if (!_isConfinedObjectPath(relativePath)) {
    throw ArgumentError.value(
      relativePath,
      'relativePath',
      'Expected one objects/<leaf> path with no traversal.',
    );
  }
  if (!_formats.contains(format)) {
    throw ArgumentError.value(format, 'format', 'Unsupported report format.');
  }
  if (reportSchemaVersion <= 0) {
    throw ArgumentError.value(
      reportSchemaVersion,
      'reportSchemaVersion',
      'Expected a positive schema version.',
    );
  }
  if (byteLength < 0) {
    throw ArgumentError.value(byteLength, 'byteLength', 'Cannot be negative.');
  }
  if (!RegExp(_sha256Pattern).hasMatch(sha256)) {
    throw ArgumentError.value(sha256, 'sha256', 'Expected lowercase SHA-256.');
  }
}

/// Validates the primitive fields and aggregate identities of one commit.
void validateReportCommitFields({
  required String runId,
  required int sequence,
  required String command,
  required String completedAtUtc,
  required Iterable<({String role, String relativePath})> objectIdentities,
}) {
  if (!RegExp(_runIdPattern).hasMatch(runId)) {
    throw ArgumentError.value(runId, 'runId', 'Invalid report run ID.');
  }
  if (sequence < 1) {
    throw ArgumentError.value(sequence, 'sequence', 'Must be positive.');
  }
  if (command != 'scan' && command != 'apply') {
    throw ArgumentError.value(command, 'command', 'Expected scan or apply.');
  }
  if (!RegExp(_completedAtPattern).hasMatch(completedAtUtc)) {
    throw ArgumentError.value(
      completedAtUtc,
      'completedAtUtc',
      'Expected canonical UTC with six fractional digits.',
    );
  }
  final parsedTimestamp = DateTime.tryParse(completedAtUtc);
  if (parsedTimestamp == null ||
      !parsedTimestamp.isUtc ||
      _canonicalUtc(parsedTimestamp) != completedAtUtc) {
    throw ArgumentError.value(
      completedAtUtc,
      'completedAtUtc',
      'Expected a real UTC timestamp.',
    );
  }

  final roles = <String>{};
  final paths = <String>{};
  var count = 0;
  for (final identity in objectIdentities) {
    count++;
    if (!roles.add(identity.role)) {
      throw ArgumentError.value(identity.role, 'objects', 'Duplicate role.');
    }
    if (!paths.add(identity.relativePath)) {
      throw ArgumentError.value(
        identity.relativePath,
        'objects',
        'Duplicate relative path.',
      );
    }
  }
  if (count == 0) {
    throw ArgumentError.value(
      count,
      'objects',
      'Expected at least one object.',
    );
  }
}

String _canonicalUtc(DateTime value) {
  String digits(int number, int width) => number.toString().padLeft(width, '0');
  final fractionalMicros = value.millisecond * 1000 + value.microsecond;
  return '${digits(value.year, 4)}-${digits(value.month, 2)}-'
      '${digits(value.day, 2)}T${digits(value.hour, 2)}:'
      '${digits(value.minute, 2)}:${digits(value.second, 2)}.'
      '${digits(fractionalMicros, 6)}Z';
}

bool _isConfinedObjectPath(String value) {
  if (value.contains(r'\')) return false;
  final segments = value.split('/');
  if (segments.length > 2 || segments.any((segment) => segment.isEmpty)) {
    return false;
  }
  if (segments.length == 2 && !RegExp(_tokenPattern).hasMatch(segments.first)) {
    return false;
  }
  final leaf = segments.last;
  return leaf.isNotEmpty &&
      leaf != '.' &&
      leaf != '..' &&
      !leaf.contains(':') &&
      !leaf.endsWith('.') &&
      !leaf.endsWith(' ') &&
      !leaf.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}
