import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/reporting/report_commit.dart';
import 'package:test/test.dart';

const _runId = '20260822T010203.123456Z_0123456789abcdefabcd';
const _objectSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _uppercaseSha =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _zeroSha =
    '0000000000000000000000000000000000000000000000000000000000000000';
const _payloadBody =
    '{"magic":"flutter_pruner_report_commit","schemaVersion":1,'
    '"runId":"$_runId","sequence":1,"command":"scan",'
    '"state":"committed",'
    '"completedAtUtc":"2026-08-22T01:02:04.123456Z","objects":['
    '{"role":"primary","relativePath":"objects/scan-$_runId.json",'
    '"format":"json","reportSchemaVersion":3,"byteLength":17,'
    '"sha256":"$_objectSha"}]';
const _payload = '$_payloadBody}';
const _payloadSha =
    'e018868f454f1ba722b8d36944e656835556cb5d294eda06b8bd96aef94da3fd';
const _encoded = '$_payloadBody,"payloadSha256":"$_payloadSha"}';

void main() {
  test('parses and re-encodes the literal canonical commit record', () {
    final commit = ReportCommit.parse(_encoded);

    expect(commit.runId, _runId);
    expect(commit.sequence, 1);
    expect(commit.command, 'scan');
    expect(commit.completedAtUtc, '2026-08-22T01:02:04.123456Z');
    expect(commit.objects.single.role, 'primary');
    expect(commit.payloadSha256, _payloadSha);
    expect(commit.canonicalPayload(), _payload);
    expect(commit.encode(), _encoded);
  });

  test('snapshots object records and exposes an immutable list', () {
    final objects = [_record()];
    final commit = _commit(objects: objects);
    objects
      ..clear()
      ..add(_record(role: 'replacement'));

    expect(commit.objects.map((record) => record.role), ['primary']);
    expect(() => commit.objects.clear(), throwsUnsupportedError);
  });

  test('rejects invalid run sequence command state and timestamp', () {
    for (final mutation in <void Function(Map<String, Object?>)>[
      (value) => value['runId'] = '../escape',
      (value) => value['sequence'] = 0,
      (value) => value['command'] = 'delete',
      (value) => value['state'] = 'pending',
      (value) => value['completedAtUtc'] = '2026-08-22T01:02:04Z',
      (value) => value['completedAtUtc'] = '2026-02-31T01:02:04.123456Z',
      (value) => value['objects'] = <Object?>[],
    ]) {
      final payload = _decodedPayload();
      mutation(payload);
      expect(
        () => ReportCommit.parse(_encodePayload(payload)),
        throwsFormatException,
      );
    }
  });

  test('rejects duplicate object roles and paths', () {
    expect(
      () => _commit(
        objects: [
          _record(),
          _record(relativePath: 'objects/b'),
        ],
      ),
      throwsArgumentError,
    );
    expect(
      () => _commit(
        objects: [
          _record(),
          _record(role: 'export'),
        ],
      ),
      throwsArgumentError,
    );
  });

  test('rejects escaping paths invalid hashes and invalid measurements', () {
    for (final create in <ReportObjectRecord Function()>[
      () => _record(relativePath: '../report.json'),
      () => _record(relativePath: 'objects/nested/report.json'),
      () => _record(relativePath: r'objects\report.json'),
      () => _record(sha256: _uppercaseSha),
      () => _record(byteLength: -1),
      () => _record(reportSchemaVersion: 0),
      () => _record(format: 'binary'),
      () => _record(role: 'Primary'),
    ]) {
      expect(create, throwsArgumentError);
    }
  });

  test('accepts one confined adjacent explicit-output leaf', () {
    expect(
      ReportObjectRecord(
        role: 'primary',
        relativePath: 'My report.json',
        format: 'json',
        reportSchemaVersion: 3,
        byteLength: 0,
        sha256: '0' * 64,
      ).relativePath,
      'My report.json',
    );
  });

  test('accepts one confined virtual storage namespace and leaf', () {
    expect(
      _record(relativePath: 'external/apply-report.html').relativePath,
      'external/apply-report.html',
    );
    expect(
      _record(relativePath: 'quarantine/run-report-000001.json').relativePath,
      'quarantine/run-report-000001.json',
    );
  });

  test('rejects partial extra missing noncanonical and corrupt records', () {
    expect(
      () => ReportCommit.parse('$_encoded trailing'),
      throwsFormatException,
    );
    expect(
      () => ReportCommit.parse(_encoded.replaceFirst(_payloadSha, _zeroSha)),
      throwsFormatException,
    );

    final extra = _decodedPayload()..['extra'] = true;
    expect(
      () => ReportCommit.parse(_encodePayload(extra)),
      throwsFormatException,
    );
    final missing = _decodedPayload()..remove('command');
    expect(
      () => ReportCommit.parse(_encodePayload(missing)),
      throwsFormatException,
    );
    final invalidHeader = _decodedPayload()..['schemaVersion'] = 2;
    expect(
      () => ReportCommit.parse(_encodePayload(invalidHeader)),
      throwsFormatException,
    );
    final invalidObjectKeys = _decodedPayload();
    ((invalidObjectKeys['objects']! as List<Object?>).single!
            as Map<String, Object?>)['extra'] =
        true;
    expect(
      () => ReportCommit.parse(_encodePayload(invalidObjectKeys)),
      throwsFormatException,
    );
    expect(
      () => ReportCommit.parse(' ${_encodePayload(_decodedPayload())}'),
      throwsFormatException,
    );
  });

  test(
    'parser rejects duplicate object roles after a valid payload digest',
    () {
      final payload = _decodedPayload();
      final objects = (payload['objects']! as List<Object?>);
      objects.add(Map<String, Object?>.from(objects.single! as Map));

      expect(
        () => ReportCommit.parse(_encodePayload(payload)),
        throwsFormatException,
      );
    },
  );
}

ReportCommit _commit({required List<ReportObjectRecord> objects}) =>
    ReportCommit(
      runId: _runId,
      sequence: 1,
      command: 'scan',
      completedAtUtc: '2026-08-22T01:02:04.123456Z',
      objects: objects,
    );

ReportObjectRecord _record({
  String role = 'primary',
  String relativePath = 'objects/scan-$_runId.json',
  String format = 'json',
  int reportSchemaVersion = 3,
  int byteLength = 17,
  String sha256 = _objectSha,
}) => ReportObjectRecord(
  role: role,
  relativePath: relativePath,
  format: format,
  reportSchemaVersion: reportSchemaVersion,
  byteLength: byteLength,
  sha256: sha256,
);

Map<String, Object?> _decodedPayload() =>
    Map<String, Object?>.from(jsonDecode(_payload) as Map);

String _encodePayload(Map<String, Object?> payload) {
  final canonicalPayload = jsonEncode(payload);
  final digest = sha256.convert(utf8.encode(canonicalPayload)).toString();
  return jsonEncode({...payload, 'payloadSha256': digest});
}
