import 'dart:io';

import 'package:flutter_pruner/src/reporting/immutable_report_store.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_commit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory sandbox;
  late Directory objectsDirectory;
  late Directory commitsDirectory;
  late ImmutableReportStore store;

  setUp(() async {
    sandbox = Directory.systemTemp.createTempSync('immutable_report_store_');
    objectsDirectory = Directory(p.join(sandbox.path, 'objects'))..createSync();
    commitsDirectory = Directory(p.join(sandbox.path, 'commits'))..createSync();
    final backend = createIoReportObjectBackend();
    store = ImmutableReportStore(
      objectsDirectory: await backend.anchor(objectsDirectory),
      commitsDirectory: await backend.anchor(commitsDirectory),
    );
  });

  tearDown(() async {
    await store.close();
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test('valid batch becomes READY only through an exact commit', () async {
    final committed = await store.writeBatch(
      identity: _identity(),
      objects: [
        ReportObjectWrite(
          role: 'primary',
          format: 'json',
          reportSchemaVersion: 3,
          writeTo: (sink) {
            sink.write('{"schemaVersion":3');
            sink.writeln(',"safe":true}');
          },
        ),
      ],
    );

    expect(committed.ready, isTrue);
    expect(committed.actualObjectPaths.keys, ['primary']);
    final object = File(committed.actualObjectPaths['primary']!);
    expect(object.readAsStringSync(), '{"schemaVersion":3,"safe":true}\n');
    final commitSource = File(committed.commitPath).readAsStringSync();
    final commit = ReportCommit.parse(commitSource);
    expect(commit.runId, _runId);
    expect(commit.sequence, 1);
    expect(commit.objects.single.byteLength, object.lengthSync());
    expect(
      commit.objects.single.relativePath,
      'objects/${p.basename(object.path)}',
    );
  });

  test('formatter failure leaves a partial orphan and no commit', () async {
    final error = StateError('formatter failed');

    await expectLater(
      store.writeBatch(
        identity: _identity(),
        objects: [
          ReportObjectWrite(
            role: 'primary',
            format: 'json',
            reportSchemaVersion: 3,
            writeTo: (sink) {
              sink.write('partial');
              throw error;
            },
          ),
        ],
      ),
      throwsA(
        isA<ImmutableReportStoreException>()
            .having(
              (failure) => failure.phase,
              'phase',
              ImmutableReportStorePhase.writeObject,
            )
            .having((failure) => failure.cause, 'cause', same(error)),
      ),
    );

    expect(objectsDirectory.listSync(), hasLength(1));
    expect(
      File((objectsDirectory.listSync().single).path).readAsStringSync(),
      'partial',
    );
    expect(commitsDirectory.listSync(), isEmpty);
  });

  test(
    'foreign object collision is byte and type exact with no commit',
    () async {
      final leaf = 'scan-$_runId.json';
      final foreign = File(p.join(objectsDirectory.path, leaf))
        ..writeAsBytesSync(const [0, 255, 3, 252]);
      final before = foreign.statSync();

      await expectLater(
        store.writeBatch(
          identity: _identity(),
          objects: [_primary('new bytes')],
        ),
        throwsA(
          isA<ImmutableReportStoreException>().having(
            (failure) => failure.phase,
            'phase',
            ImmutableReportStorePhase.createObject,
          ),
        ),
      );

      expect(foreign.readAsBytesSync(), const [0, 255, 3, 252]);
      expect(foreign.statSync().type, before.type);
      expect(foreign.statSync().mode, before.mode);
      expect(commitsDirectory.listSync(), isEmpty);
    },
  );

  test('multi-object failure never creates an all-or-none commit', () async {
    final foreignLeaf = 'scan-$_runId-export.html';
    final foreign = File(p.join(objectsDirectory.path, foreignLeaf))
      ..writeAsStringSync('foreign export');

    await expectLater(
      store.writeBatch(
        identity: _identity(),
        objects: [
          _primary('primary bytes'),
          ReportObjectWrite(
            role: 'export',
            format: 'html',
            reportSchemaVersion: 1,
            writeTo: (sink) => sink.write('new export'),
          ),
        ],
      ),
      throwsA(
        isA<ImmutableReportStoreException>()
            .having(
              (failure) => failure.phase,
              'phase',
              ImmutableReportStorePhase.createObject,
            )
            .having((failure) => failure.failedRole, 'failedRole', 'export'),
      ),
    );

    expect(
      File(
        p.join(objectsDirectory.path, 'scan-$_runId.json'),
      ).readAsStringSync(),
      'primary bytes',
    );
    expect(foreign.readAsStringSync(), 'foreign export');
    expect(commitsDirectory.listSync(), isEmpty);
  });

  test(
    'valid multi-object commit is role-bound independent of input order',
    () async {
      final committed = await store.writeBatch(
        identity: _identity(),
        objects: [
          _primary('primary bytes'),
          ReportObjectWrite(
            role: 'export',
            format: 'html',
            reportSchemaVersion: 1,
            writeTo: (sink) => sink.write('export bytes'),
          ),
        ],
      );

      expect(committed.commit.objects.map((object) => object.role), [
        'export',
        'primary',
      ]);
      expect(
        File(committed.actualObjectPaths['primary']!).readAsStringSync(),
        'primary bytes',
      );
      expect(
        File(committed.actualObjectPaths['export']!).readAsStringSync(),
        'export bytes',
      );
    },
  );

  test(
    'one commit can authorize objects in separately anchored stores',
    () async {
      final externalDirectory = Directory(p.join(sandbox.path, 'external'))
        ..createSync();
      final external = await createIoReportObjectBackend().anchor(
        externalDirectory,
      );
      addTearDown(external.close);

      final committed = await store.writeBatch(
        identity: _identity(),
        objects: [
          _primary('canonical bytes'),
          ReportObjectWrite(
            role: 'export',
            format: 'html',
            reportSchemaVersion: 3,
            writeTo: (sink) => sink.write('external bytes'),
          ),
        ],
        objectDirectoryOverrides: {'export': external},
        objectLeafOverrides: {'export': 'requested-output.html'},
        recordPathOverrides: {
          'primary': 'quarantine/run-report-000001.json',
          'export': 'external/requested-output.html',
        },
      );

      expect(
        File(committed.actualObjectPaths['primary']!).readAsStringSync(),
        'canonical bytes',
      );
      expect(
        File(committed.actualObjectPaths['export']!).readAsStringSync(),
        'external bytes',
      );
      expect(committed.commit.objects.map((object) => object.relativePath), [
        'external/requested-output.html',
        'quarantine/run-report-000001.json',
      ]);
    },
  );

  test(
    'foreign commit collision retains both foreign commit and orphan',
    () async {
      final commit = File(
        p.join(commitsDirectory.path, '$_runId-1.commit.json'),
      )..writeAsBytesSync(const [7, 0, 7]);

      await expectLater(
        store.writeBatch(identity: _identity(), objects: [_primary('orphan')]),
        throwsA(
          isA<ImmutableReportStoreException>().having(
            (failure) => failure.phase,
            'phase',
            ImmutableReportStorePhase.createCommit,
          ),
        ),
      );

      expect(commit.readAsBytesSync(), const [7, 0, 7]);
      expect(objectsDirectory.listSync(), hasLength(1));
    },
  );

  test(
    'same identity is single-assignment even after a valid commit',
    () async {
      await store.writeBatch(
        identity: _identity(),
        objects: [_primary('first')],
      );

      await expectLater(
        store.writeBatch(identity: _identity(), objects: [_primary('second')]),
        throwsA(
          isA<ImmutableReportStoreException>().having(
            (failure) => failure.phase,
            'phase',
            ImmutableReportStorePhase.createObject,
          ),
        ),
      );
      expect(
        File(
          p.join(objectsDirectory.path, 'scan-$_runId.json'),
        ).readAsStringSync(),
        'first',
      );
    },
  );

  test('adjacent explicit profile writes the exact selected leaf', () async {
    final adjacentStore = ImmutableReportStore(
      objectsDirectory: await createIoReportObjectBackend().anchor(sandbox),
      commitsDirectory: await createIoReportObjectBackend().anchor(sandbox),
    );
    addTearDown(adjacentStore.close);

    final committed = await adjacentStore.writeBatch(
      identity: _identity(),
      objects: [_primary('explicit bytes')],
      objectLeafOverrides: const {'primary': 'Selected report.json'},
      commitLeafOverride: '.flutter-pruner-explicit.commit.json',
      recordPathPrefix: '',
    );

    expect(
      File(p.join(sandbox.path, 'Selected report.json')).readAsStringSync(),
      'explicit bytes',
    );
    expect(
      committed.commit.objects.single.relativePath,
      'Selected report.json',
    );
    expect(
      p.basename(committed.commitPath),
      '.flutter-pruner-explicit.commit.json',
    );
  });
}

const _runId = '20260822T000000.000000Z_0123456789abcdefabcd';

ReportCommitIdentity _identity() => const ReportCommitIdentity(
  runId: _runId,
  sequence: 1,
  command: 'scan',
  completedAtUtc: '2026-08-22T00:00:00.000000Z',
);

ReportObjectWrite _primary(String contents) => ReportObjectWrite(
  role: 'primary',
  format: 'json',
  reportSchemaVersion: 3,
  writeTo: (sink) => sink.write(contents),
);
