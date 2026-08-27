import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/manifest_authority.dart';
import 'package:flutter_pruner/src/quarantine/native/posix_clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/native/windows_clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_plan.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_tree_digest.dart';
import 'package:flutter_pruner/src/quarantine/recoverable_clean_store.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  if (arguments.length != 5) exit(64);
  final project = Directory(arguments[0]);
  final base = Directory(arguments[1]);
  final runId = arguments[2];
  final operationId = arguments[3];
  final point = RecoverableCleanProtocolPoint.values.byName(arguments[4]);
  final plan = await _plan(base, runId);
  final store = RecoverableCleanStore(
    projectRoot: project,
    operationIdFactory: () => operationId,
    protocolHook: (observed) {
      if (observed == point) exit(91);
    },
  );
  await store.execute(plan: plan, quarantineBase: base);
  exit(92);
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
