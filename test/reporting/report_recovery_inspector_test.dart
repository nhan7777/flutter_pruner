import 'dart:io';

import 'package:flutter_pruner/src/reporting/immutable_report_store.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_recovery_inspector.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory objectsDirectory;
  late Directory commitsDirectory;
  late ImmutableReportStore store;
  late ReportRecoveryInspector inspector;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('report_recovery_');
    objectsDirectory = Directory(p.join(sandbox.path, 'objects'))..createSync();
    commitsDirectory = Directory(p.join(sandbox.path, 'commits'))..createSync();
    final backend = createIoReportObjectBackend();
    store = ImmutableReportStore(
      objectsDirectory: await backend.anchor(objectsDirectory),
      commitsDirectory: await backend.anchor(commitsDirectory),
    );
    inspector = ReportRecoveryInspector(
      objectsDirectory: await backend.anchor(objectsDirectory),
      commitsDirectory: await backend.anchor(commitsDirectory),
    );
  });

  tearDown(() async {
    await inspector.close();
    await store.close();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('classifies an exact valid authority as committed', () async {
    await _writeValid(store);

    final result = await inspector.inspect(
      identity: _identity,
      expectedObjects: _expected,
    );

    expect(result.classification, ReportRecoveryClassification.committed);
    expect(result.commit, isNotNull);
    expect(result.artifactPaths, hasLength(2));
    expect(result.ready, isTrue);
  });

  test('classifies an object without a commit as orphaned', () async {
    File(
      p.join(objectsDirectory.path, 'scan-${_identity.runId}.json'),
    ).writeAsStringSync('complete but unauthoritative');

    final result = await inspector.inspect(
      identity: _identity,
      expectedObjects: _expected,
    );

    expect(result.classification, ReportRecoveryClassification.orphaned);
    expect(result.artifactPaths, hasLength(1));
    expect(result.ready, isFalse);
  });

  test('classifies a truncated owned commit as partial', () async {
    File(
      p.join(commitsDirectory.path, '${_identity.runId}-1.commit.json'),
    ).writeAsStringSync('{"magic":"flutter_pruner_report_commit"');

    final result = await inspector.inspect(
      identity: _identity,
      expectedObjects: _expected,
    );

    expect(result.classification, ReportRecoveryClassification.partial);
    expect(result.ready, isFalse);
  });

  test('classifies unrelated commit bytes as foreign', () async {
    final foreign = File(
      p.join(commitsDirectory.path, '${_identity.runId}-1.commit.json'),
    )..writeAsBytesSync(const [0, 255, 1, 254]);

    final result = await inspector.inspect(
      identity: _identity,
      expectedObjects: _expected,
    );

    expect(result.classification, ReportRecoveryClassification.foreign);
    expect(foreign.readAsBytesSync(), const [0, 255, 1, 254]);
  });

  test('classifies post-commit object hash mismatch as corrupt', () async {
    final committed = await _writeValid(store);
    File(committed.actualObjectPaths['primary']!).writeAsStringSync('tampered');

    final result = await inspector.inspect(
      identity: _identity,
      expectedObjects: _expected,
    );

    expect(result.classification, ReportRecoveryClassification.corrupt);
    expect(result.ready, isFalse);
  });

  test(
    'classifies canonical JSON with a changed commit digest as corrupt',
    () async {
      final committed = await _writeValid(store);
      final commit = File(committed.commitPath);
      final source = commit.readAsStringSync();
      final marker = source.lastIndexOf('"payloadSha256":"');
      final digestStart = marker + '"payloadSha256":"'.length;
      final replacement = source[digestStart] == '0' ? '1' : '0';
      commit.writeAsStringSync(
        source.replaceRange(digestStart, digestStart + 1, replacement),
      );

      final result = await inspector.inspect(
        identity: _identity,
        expectedObjects: _expected,
      );

      expect(result.classification, ReportRecoveryClassification.corrupt);
      expect(result.ready, isFalse);
    },
  );

  test(
    'retained directory capabilities prevent authority substitution',
    () async {
      await _writeValid(store);
      try {
        objectsDirectory.renameSync(p.join(sandbox.path, 'moved-objects'));
      } on FileSystemException {
        final result = await inspector.inspect(
          identity: _identity,
          expectedObjects: _expected,
        );

        expect(result.classification, ReportRecoveryClassification.committed);
        expect(result.ready, isTrue);
        return;
      }

      Directory(objectsDirectory.path).createSync();

      final result = await inspector.inspect(
        identity: _identity,
        expectedObjects: _expected,
      );

      expect(result.classification, ReportRecoveryClassification.unreachable);
      expect(result.ready, isFalse);
    },
  );

  test('inspection never changes artifact names or bytes', () async {
    final object = File(
      p.join(objectsDirectory.path, 'scan-${_identity.runId}.json'),
    )..writeAsBytesSync(const [9, 0, 8]);
    final beforeNames = _allNames(objectsDirectory, commitsDirectory);

    await inspector.inspect(identity: _identity, expectedObjects: _expected);

    expect(_allNames(objectsDirectory, commitsDirectory), beforeNames);
    expect(object.readAsBytesSync(), const [9, 0, 8]);
  });
}

List<String> _allNames(Directory objects, Directory commits) => [
  ...objects.listSync().map((entry) => p.basename(entry.path)),
  ...commits.listSync().map((entry) => p.basename(entry.path)),
]..sort();

const _identity = ReportCommitIdentity(
  runId: '20260822T010000.000000Z_abcdef0123456789abcd',
  sequence: 1,
  command: 'scan',
  completedAtUtc: '2026-08-22T01:00:00.000000Z',
);
const _expected = <ExpectedReportObject>[
  (role: 'primary', format: 'json', reportSchemaVersion: 3),
];

Future<CommittedReport> _writeValid(ImmutableReportStore store) =>
    store.writeBatch(
      identity: _identity,
      objects: [
        ReportObjectWrite(
          role: 'primary',
          format: 'json',
          reportSchemaVersion: 3,
          writeTo: (sink) => sink.write('{"valid":true}'),
        ),
      ],
    );
