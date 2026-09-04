import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/manifest_authority.dart';
import 'package:flutter_pruner/src/quarantine/native/posix_clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/native/windows_clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_plan.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_tree_digest.dart';
import 'package:flutter_pruner/src/quarantine/recoverable_clean_inspection.dart';
import 'package:flutter_pruner/src/quarantine/recoverable_clean_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;
  late Directory base;

  setUp(() {
    project = Directory.systemTemp.createTempSync('recoverable_clean_store_');
    base = Directory(p.join(project.path, '.flutter_pruner', 'quarantine'))
      ..createSync(recursive: true);
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test(
    'logical clean retains exact bytes and commits a durable journal',
    () async {
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => 'clean-20260827T010203000000Z-deadbeef',
      );

      final result = await store.execute(plan: plan, quarantineBase: base);

      expect(result.committed, isTrue);
      expect(Directory(p.join(base.path, 'run-a')).existsSync(), isFalse);
      final retained = File(
        p.join(
          base.path,
          '.clean-retained',
          'v1',
          result.operationId,
          'runs',
          'run-a',
          'payload.txt',
        ),
      );
      expect(retained.readAsStringSync(), 'alpha');

      final inspections = await store.inspect(quarantineBases: [base]);
      expect(inspections, hasLength(1));
      expect(
        inspections.single.state,
        RecoverableCleanInspectionState.retained,
      );
    },
  );

  test(
    'restore uses no-replace move and never overwrites an active run',
    () async {
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => 'clean-20260827T010203000000Z-feedface',
      );
      final result = await store.execute(plan: plan, quarantineBase: base);
      final collision = Directory(p.join(base.path, 'run-a'))..createSync();
      File(p.join(collision.path, 'foreign.txt')).writeAsStringSync('foreign');

      await expectLater(
        () => store.restore(
          quarantineBase: base,
          operationId: result.operationId,
          runId: 'run-a',
        ),
        throwsA(isA<RecoverableCleanStoreException>()),
      );
      expect(
        File(p.join(collision.path, 'foreign.txt')).readAsStringSync(),
        'foreign',
      );
      expect(
        File(
          p.join(
            base.path,
            '.clean-retained',
            'v1',
            result.operationId,
            'runs',
            'run-a',
            'payload.txt',
          ),
        ).readAsStringSync(),
        'alpha',
      );
    },
  );

  test(
    'operation collision stops before journal intent or source move',
    () async {
      const operationId = 'clean-20260827T010203000000Z-0badcafe';
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final collision = Directory(
        p.join(base.path, '.clean-retained', 'v1', operationId),
      )..createSync(recursive: true);
      File(p.join(collision.path, 'foreign.txt')).writeAsStringSync('foreign');
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => operationId,
      );

      await expectLater(
        () => store.execute(plan: plan, quarantineBase: base),
        throwsA(isA<RecoverableCleanStoreException>()),
      );
      expect(
        File(p.join(base.path, 'run-a', 'payload.txt')).readAsStringSync(),
        'alpha',
      );
      expect(
        File(p.join(collision.path, 'foreign.txt')).readAsStringSync(),
        'foreign',
      );
    },
  );

  test('post-move interruption is reported as recovery required', () async {
    final plan = await _plan(project, base, 'run-a', 'alpha');
    final store = RecoverableCleanStore(
      projectRoot: project,
      operationIdFactory: () => 'clean-20260827T010203000000Z-cafebabe',
      protocolHook: (point) {
        if (point == RecoverableCleanProtocolPoint.afterMove) {
          throw StateError('injected interruption');
        }
      },
    );

    final result = await store.execute(plan: plan, quarantineBase: base);

    expect(result.committed, isFalse);
    expect(result.recoveryRequired, isTrue);
    final fresh = RecoverableCleanStore(projectRoot: project);
    final inspections = await fresh.inspect(quarantineBases: [base]);
    expect(
      inspections.single.state,
      RecoverableCleanInspectionState.recoveryRequired,
    );
    expect(inspections.single.observationCode, 'retained-uncommitted');
  });

  test(
    'a fresh execution reconciles an exact post-move interruption',
    () async {
      const firstOperation = 'clean-20260827T010203000000Z-a11ce001';
      const secondOperation = 'clean-20260827T010203000000Z-a11ce002';
      final firstPlan = await _plan(project, base, 'run-a', 'alpha');
      final interrupted = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => firstOperation,
        protocolHook: (point) {
          if (point == RecoverableCleanProtocolPoint.afterMove) {
            throw StateError('injected interruption');
          }
        },
      );
      final first = await interrupted.execute(
        plan: firstPlan,
        quarantineBase: base,
      );
      expect(first.recoveryRequired, isTrue);

      final secondPlan = await _plan(project, base, 'run-b', 'beta');
      final fresh = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => secondOperation,
      );
      final second = await fresh.execute(
        plan: secondPlan,
        quarantineBase: base,
      );

      expect(second.committed, isTrue);
      final inspections = await fresh.inspect(quarantineBases: [base]);
      expect(inspections, hasLength(2));
      expect(
        inspections.map((item) => item.state),
        everyElement(RecoverableCleanInspectionState.retained),
      );
      expect(
        File(
          p.join(
            base.path,
            '.clean-retained',
            'v1',
            firstOperation,
            'runs',
            'run-a',
            'payload.txt',
          ),
        ).readAsStringSync(),
        'alpha',
      );
    },
  );

  test(
    'a fresh execution aborts exact durable intent that never moved',
    () async {
      const firstOperation = 'clean-20260827T010203000000Z-b0b00001';
      const secondOperation = 'clean-20260827T010203000000Z-b0b00002';
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final interrupted = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => firstOperation,
        protocolHook: (point) {
          if (point == RecoverableCleanProtocolPoint.intentFlushed) {
            throw StateError('injected interruption');
          }
        },
      );
      final first = await interrupted.execute(plan: plan, quarantineBase: base);
      expect(first.recoveryRequired, isTrue);
      expect(Directory(p.join(base.path, 'run-a')).existsSync(), isTrue);

      final fresh = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => secondOperation,
      );
      final second = await fresh.execute(plan: plan, quarantineBase: base);

      expect(second.committed, isTrue);
      final inspections = await fresh.inspect(quarantineBases: [base]);
      expect(
        inspections.map((item) => item.state),
        containsAll(<RecoverableCleanInspectionState>[
          RecoverableCleanInspectionState.aborted,
          RecoverableCleanInspectionState.retained,
        ]),
      );
    },
  );

  test('retained content drift cannot become committed success', () async {
    const operationId = 'clean-20260827T010203000000Z-1234abcd';
    final plan = await _plan(project, base, 'run-a', 'alpha');
    final store = RecoverableCleanStore(
      projectRoot: project,
      operationIdFactory: () => operationId,
      protocolHook: (point) {
        if (point == RecoverableCleanProtocolPoint.afterMove) {
          File(
            p.join(
              base.path,
              '.clean-retained',
              'v1',
              operationId,
              'runs',
              'run-a',
              'payload.txt',
            ),
          ).writeAsStringSync('changed', flush: true);
        }
      },
    );

    final result = await store.execute(plan: plan, quarantineBase: base);

    expect(result.committed, isFalse);
    expect(result.recoveryRequired, isTrue);
    expect(Directory(p.join(base.path, 'run-a')).existsSync(), isFalse);
    expect(
      File(
        p.join(
          base.path,
          '.clean-retained',
          'v1',
          operationId,
          'runs',
          'run-a',
          'payload.txt',
        ),
      ).readAsStringSync(),
      'changed',
    );
    final nextPlan = await _plan(project, base, 'run-b', 'beta');
    await expectLater(
      () => RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => 'clean-20260827T010203000000Z-1234abce',
      ).execute(plan: nextPlan, quarantineBase: base),
      throwsA(
        isA<RecoverableCleanStoreException>().having(
          (error) => error.category,
          'category',
          RecoverableCleanStoreFailure.recoveryRequired,
        ),
      ),
    );
  });

  test(
    'restore refuses retained tree drift and preserves both names',
    () async {
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => 'clean-20260827T010203000000Z-d12f7001',
      );
      final result = await store.execute(plan: plan, quarantineBase: base);
      final retainedPayload = File(
        p.join(
          base.path,
          '.clean-retained',
          'v1',
          result.operationId,
          'runs',
          'run-a',
          'payload.txt',
        ),
      )..writeAsStringSync('drift', flush: true);

      await expectLater(
        () => store.restore(
          quarantineBase: base,
          operationId: result.operationId,
          runId: 'run-a',
        ),
        throwsA(
          isA<RecoverableCleanStoreException>().having(
            (error) => error.category,
            'category',
            RecoverableCleanStoreFailure.recoveryRequired,
          ),
        ),
      );
      expect(Directory(p.join(base.path, 'run-a')).existsSync(), isFalse);
      expect(retainedPayload.readAsStringSync(), 'drift');
    },
  );

  test(
    'an appended journal cannot replace immutable project authority',
    () async {
      const operationId = 'clean-20260827T010203000000Z-1a2b3c4d';
      final plan = await _plan(project, base, 'run-a', 'alpha');
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => operationId,
      );
      await store.execute(plan: plan, quarantineBase: base);
      final operation = Directory(
        p.join(base.path, '.clean-retained', 'v1', operationId),
      );
      final journals =
          operation
              .listSync(followLinks: false)
              .whereType<File>()
              .toList(growable: false)
            ..sort((left, right) => left.path.compareTo(right.path));
      final tampered =
          jsonDecode(journals.last.readAsStringSync()) as Map<String, dynamic>;
      tampered['projectPath'] = p.join(project.parent.path, 'foreign-project');
      tampered.remove('checksumSha256');
      tampered['checksumSha256'] = sha256
          .convert(utf8.encode(jsonEncode(tampered)))
          .toString();
      File(
        p.join(
          operation.path,
          'journal-${journals.length.toString().padLeft(6, '0')}.json',
        ),
      ).writeAsStringSync(jsonEncode(tampered), flush: true);

      final inspection = (await store.inspect(
        quarantineBases: <Directory>[base],
      )).single;
      expect(
        inspection.state,
        RecoverableCleanInspectionState.recoveryRequired,
      );
      expect(inspection.observationCode, 'invalid-journal-authority');
      expect(
        File(
          p.join(operation.path, 'runs', 'run-a', 'payload.txt'),
        ).readAsStringSync(),
        'alpha',
      );
    },
  );

  test(
    'multi-target restores remain durable after each no-replace move',
    () async {
      final first = await _target(base, 'run-a', 'alpha');
      final second = await _target(base, 'run-b', 'beta');
      final plan = QuarantineCleanPlan.fromEvidence(
        scope: CleanScope.all,
        canonicalBases: [base.resolveSymbolicLinksSync()],
        backend: CleanBackendDisclosure.recoverableLogicalMove,
        targets: [first, second],
      );
      final store = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () => 'clean-20260827T010203000000Z-abcd1234',
      );
      final result = await store.execute(plan: plan, quarantineBase: base);

      await store.restore(
        quarantineBase: base,
        operationId: result.operationId,
        runId: 'run-a',
      );
      var inspection = (await store.inspect(quarantineBases: [base])).single;
      expect(
        inspection.state,
        RecoverableCleanInspectionState.partiallyRestored,
      );
      await store.restore(
        quarantineBase: base,
        operationId: result.operationId,
        runId: 'run-b',
      );
      inspection = (await store.inspect(quarantineBases: [base])).single;
      expect(inspection.state, RecoverableCleanInspectionState.restored);
      expect(
        File(p.join(base.path, 'run-a', 'payload.txt')).readAsStringSync(),
        'alpha',
      );
      expect(
        File(p.join(base.path, 'run-b', 'payload.txt')).readAsStringSync(),
        'beta',
      );
    },
  );
}

Future<QuarantineCleanPlan> _plan(
  Directory project,
  Directory base,
  String runId,
  String content,
) async {
  final target = await _target(base, runId, content);
  return QuarantineCleanPlan.fromEvidence(
    scope: CleanScope.targeted,
    canonicalBases: [base.resolveSymbolicLinksSync()],
    backend: CleanBackendDisclosure.recoverableLogicalMove,
    targets: [target],
  );
}

Future<QuarantineCleanTarget> _target(
  Directory base,
  String runId,
  String content,
) async {
  final run = Directory(p.join(base.path, runId))..createSync();
  final bytes = content.codeUnits;
  File(p.join(run.path, 'payload.txt')).writeAsBytesSync(bytes);
  final layout = await captureQuarantineTreeDigest(run);
  final backend = _platformBackend();
  final anchored = await backend.anchor(base);
  final identity = await anchored.inspectDirectory([runId]);
  await anchored.close();
  return QuarantineCleanTarget(
    runId: runId,
    canonicalPath: run.resolveSymbolicLinksSync(),
    layoutSha256: layout.sha256,
    journalRevision: 1,
    payloadSha256: sha256.convert(bytes).toString(),
    authority: ManifestCandidateName.primary,
    repairAction: ManifestRepairAction.none,
    rootIdentity: identity,
    retainedDestinationComponents: [
      '.clean-retained',
      'v1',
      'operation-placeholder',
      'runs',
      runId,
    ],
  );
}

RecoverableCleanMoveBackend _platformBackend() {
  if (Platform.isWindows) return WindowsRecoverableCleanMoveBackend();
  return PosixRecoverableCleanMoveBackend();
}
