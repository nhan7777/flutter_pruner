import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'report_commit_validator.dart';

const _magic = 'flutter_pruner_report_commit';
const _schemaVersion = 1;
const _committedState = 'committed';
const _topLevelKeys = <String>[
  'magic',
  'schemaVersion',
  'runId',
  'sequence',
  'command',
  'state',
  'completedAtUtc',
  'objects',
  'payloadSha256',
];
const _objectKeys = <String>[
  'role',
  'relativePath',
  'format',
  'reportSchemaVersion',
  'byteLength',
  'sha256',
];

/// One immutable report object named by a commit record.
final class ReportObjectRecord {
  /// Creates and validates an object record.
  ReportObjectRecord({
    required this.role,
    required this.relativePath,
    required this.format,
    required this.reportSchemaVersion,
    required this.byteLength,
    required this.sha256,
  }) {
    validateReportObjectRecordFields(
      role: role,
      relativePath: relativePath,
      format: format,
      reportSchemaVersion: reportSchemaVersion,
      byteLength: byteLength,
      sha256: sha256,
    );
  }

  /// Unique role inside its commit, such as `primary` or `export`.
  final String role;

  /// Store-relative `objects/<leaf>` path.
  final String relativePath;

  /// `json`, `html`, or `text`.
  final String format;

  /// Schema version represented by this report object.
  final int reportSchemaVersion;

  /// Exact UTF-8 object byte length.
  final int byteLength;

  /// Exact lowercase SHA-256 of the object bytes.
  final String sha256;

  Map<String, Object?> _toJson() => {
    'role': role,
    'relativePath': relativePath,
    'format': format,
    'reportSchemaVersion': reportSchemaVersion,
    'byteLength': byteLength,
    'sha256': sha256,
  };

  @override
  String toString() =>
      'ReportObjectRecord(role=$role, relativePath=$relativePath, '
      'format=$format, reportSchemaVersion=$reportSchemaVersion, '
      'byteLength=$byteLength, sha256=$sha256)';
}

/// Immutable all-or-none authority for a set of report objects.
final class ReportCommit {
  /// Creates a canonical committed record.
  ReportCommit({
    required this.runId,
    required this.sequence,
    required this.command,
    required this.completedAtUtc,
    required List<ReportObjectRecord> objects,
  }) : objects = List.unmodifiable(
         objects.toList()..sort((left, right) {
           final role = left.role.compareTo(right.role);
           return role != 0
               ? role
               : left.relativePath.compareTo(right.relativePath);
         }),
       ) {
    validateReportCommitFields(
      runId: runId,
      sequence: sequence,
      command: command,
      completedAtUtc: completedAtUtc,
      objectIdentities: this.objects.map(
        (object) => (role: object.role, relativePath: object.relativePath),
      ),
    );
    payloadSha256 = sha256.convert(utf8.encode(canonicalPayload())).toString();
  }

  /// UTC-sortable secure run identity.
  final String runId;

  /// Monotonic immutable state sequence within [runId].
  final int sequence;

  /// `scan` or `apply`.
  final String command;

  /// Canonical UTC completion timestamp with six fractional digits.
  final String completedAtUtc;

  /// Canonically ordered immutable object set.
  final List<ReportObjectRecord> objects;

  /// SHA-256 of [canonicalPayload].
  late final String payloadSha256;

  /// Encodes every authenticated field in the schema-defined key order.
  String canonicalPayload() => jsonEncode({
    'magic': _magic,
    'schemaVersion': _schemaVersion,
    'runId': runId,
    'sequence': sequence,
    'command': command,
    'state': _committedState,
    'completedAtUtc': completedAtUtc,
    'objects': objects.map((object) => object._toJson()).toList(),
  });

  /// Encodes the complete canonical commit record.
  String encode() {
    final payload = jsonDecode(canonicalPayload()) as Map<String, Object?>;
    return jsonEncode({...payload, 'payloadSha256': payloadSha256});
  }

  /// Parses an exact canonical committed record.
  static ReportCommit parse(String source) {
    try {
      final decoded = jsonDecode(source);
      if (decoded is! Map<String, Object?> ||
          !_sameOrderedKeys(decoded.keys, _topLevelKeys)) {
        throw const FormatException('Invalid commit record keys.');
      }
      if (decoded['magic'] != _magic ||
          decoded['schemaVersion'] != _schemaVersion ||
          decoded['state'] != _committedState) {
        throw const FormatException('Invalid commit record header.');
      }
      final rawObjects = decoded['objects'];
      if (rawObjects is! List<Object?>) {
        throw const FormatException('Invalid commit object list.');
      }
      final objects = <ReportObjectRecord>[];
      for (final rawObject in rawObjects) {
        if (rawObject is! Map<String, Object?> ||
            !_sameOrderedKeys(rawObject.keys, _objectKeys)) {
          throw const FormatException('Invalid report object record keys.');
        }
        objects.add(
          ReportObjectRecord(
            role: _required<String>(rawObject, 'role'),
            relativePath: _required<String>(rawObject, 'relativePath'),
            format: _required<String>(rawObject, 'format'),
            reportSchemaVersion: _required<int>(
              rawObject,
              'reportSchemaVersion',
            ),
            byteLength: _required<int>(rawObject, 'byteLength'),
            sha256: _required<String>(rawObject, 'sha256'),
          ),
        );
      }
      final commit = ReportCommit(
        runId: _required<String>(decoded, 'runId'),
        sequence: _required<int>(decoded, 'sequence'),
        command: _required<String>(decoded, 'command'),
        completedAtUtc: _required<String>(decoded, 'completedAtUtc'),
        objects: objects,
      );
      if (_required<String>(decoded, 'payloadSha256') != commit.payloadSha256 ||
          commit.encode() != source) {
        throw const FormatException('Commit record is not canonical or valid.');
      }
      return commit;
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid report commit: $error');
    }
  }
}

T _required<T>(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! T) throw FormatException('Invalid $key.');
  return value;
}

bool _sameOrderedKeys(Iterable<String> actual, List<String> expected) {
  final values = actual.toList(growable: false);
  if (values.length != expected.length) return false;
  for (var index = 0; index < values.length; index++) {
    if (values[index] != expected[index]) return false;
  }
  return true;
}
