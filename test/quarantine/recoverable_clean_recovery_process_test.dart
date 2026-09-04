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
  for (final point in RecoverableCleanProtocolPoint.values) {
    test('restart reconciles a hard process exit at ${point.name}', () async {
      final project = Directory.systemTemp.createTempSync(
        'recoverable_clean_process_',
      );
      addTearDown(() {
        if (project.existsSync()) project.deleteSync(recursive: true);
      });
      final base = Directory(
        p.join(project.path, '.flutter_pruner', 'quarantine'),
      )..createSync(recursive: true);
      final run = Directory(p.join(base.path, 'run-a'))..createSync();
      File(p.join(run.path, 'payload.txt')).writeAsStringSync('alpha');
      final operationId =
          'clean-20260827T010203000000Z-${point.index.toRadixString(16).padLeft(8, '0')}';

      final child = await Process.run(Platform.resolvedExecutable, <String>[
        'run',
        'test/cli/quarantine_clean_recovery_entrypoint.dart',
        project.path,
        base.path,
        'run-a',
        operationId,
        point.name,
      ], workingDirectory: Directory.current.path);

      expect(child.exitCode, 91, reason: '${child.stdout}\n${child.stderr}');
      final originalPayload = File(p.join(base.path, 'run-a', 'payload.txt'));
      final retainedPayload = File(
        p.join(
          base.path,
          '.clean-retained',
          'v1',
          operationId,
          'runs',
          'run-a',
          'payload.txt',
        ),
      );
      expect(
        originalPayload.existsSync() || retainedPayload.existsSync(),
        isTrue,
      );
      expect(
        originalPayload.existsSync()
            ? originalPayload.readAsStringSync()
            : retainedPayload.readAsStringSync(),
        'alpha',
      );

      final secondRun = Directory(p.join(base.path, 'run-b'))..createSync();
      File(p.join(secondRun.path, 'payload.txt')).writeAsStringSync('beta');
      final fresh = RecoverableCleanStore(
        projectRoot: project,
        operationIdFactory: () =>
            'clean-20260827T010203000000Z-${(point.index + 16).toRadixString(16).padLeft(8, '0')}',
      );
      final next = await fresh.execute(
        plan: await _plan(base, 'run-b'),
        quarantineBase: base,
      );
      expect(next.committed, isTrue);

      final inspections = await fresh.inspect(
        quarantineBases: <Directory>[base],
      );
      final interrupted = inspections.singleWhere(
        (item) => item.operationId == operationId,
      );
      final expectedState = switch (point) {
        RecoverableCleanProtocolPoint.intentFlushed ||
        RecoverableCleanProtocolPoint.beforeMove =>
          RecoverableCleanInspectionState.aborted,
        RecoverableCleanProtocolPoint.afterMove ||
        RecoverableCleanProtocolPoint.metadataFlushed ||
        RecoverableCleanProtocolPoint.retainedVerified ||
        RecoverableCleanProtocolPoint.committedJournalFlushed =>
          RecoverableCleanInspectionState.retained,
      };
      expect(interrupted.state, expectedState);
      expect(
        originalPayload.existsSync()
            ? originalPayload.readAsStringSync()
            : retainedPayload.readAsStringSync(),
        'alpha',
      );
    });
  }
}

Future<QuarantineCleanPlan> _plan(Directory base, String runId) async {
  final run = Directory(p.join(base.path, runId));
  final payload = File(p.join(run.path, 'payload.txt')).readAsBytesSync();
  final layout = await captureQuarantineTreeDigest(run);
  final backend = _platformBackend();
  final anchored = await backend.anchor(base);
  try {
    final identity = await anchored.inspectDirectory(<String>[runId]);
    return QuarantineCleanPlan.fromEvidence(
      scope: CleanScope.targeted,
      canonicalBases: <String>[base.resolveSymbolicLinksSync()],
      backend: CleanBackendDisclosure.recoverableLogicalMove,
      targets: <QuarantineCleanTarget>[
        QuarantineCleanTarget(
          runId: runId,
          canonicalPath: run.resolveSymbolicLinksSync(),
          layoutSha256: layout.sha256,
          journalRevision: 1,
          payloadSha256: sha256.convert(payload).toString(),
          authority: ManifestCandidateName.primary,
          repairAction: ManifestRepairAction.none,
          rootIdentity: identity,
          retainedDestinationComponents: <String>[
            '.clean-retained',
            'v1',
            'operation-placeholder',
            'runs',
            runId,
          ],
        ),
      ],
    );
  } finally {
    await anchored.close();
  }
}

RecoverableCleanMoveBackend _platformBackend() {
  if (Platform.isWindows) return WindowsRecoverableCleanMoveBackend();
  return PosixRecoverableCleanMoveBackend();
}
