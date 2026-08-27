import 'dart:convert';

import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/recoverable_clean_transaction.dart';
import 'package:test/test.dart';

void main() {
  test('transaction emits canonical versioned authority evidence', () {
    final transaction = _transaction();

    final json = transaction.toJson();

    expect(json['version'], 1);
    expect(json['operationId'], 'clean-20260827T010203000000Z-a1b2c3d4');
    expect(json['state'], 'active');
    expect(json['scope'], 'targeted');
    expect(json['createdAtUtc'], '2026-08-27T01:02:03.000Z');
    expect(json['updatedAtUtc'], '2026-08-27T01:02:03.000Z');
    expect(json['checksumSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(json['targets'], <Object?>[
      <String, Object?>{
        'runId': 'run-a',
        'sourceComponents': <String>['run-a'],
        'destinationComponents': <String>[
          '.clean-retained',
          'v1',
          'clean-20260827T010203000000Z-a1b2c3d4',
          'runs',
          'run-a',
        ],
        'identity': <String, Object?>{
          'storageId': 'dev:1',
          'objectId': 'ino:2',
          'kind': 'directory',
        },
        'layoutSha256': 'a' * 64,
        'journalRevision': 7,
        'payloadSha256': 'b' * 64,
        'phase': 'planned',
      },
    ]);
  });

  test('transaction round-trips without losing typed state', () {
    final original = _transaction();

    final decoded = RecoverableCleanTransaction.fromJson(
      jsonDecode(jsonEncode(original.toJson())) as Map<String, dynamic>,
    );

    expect(decoded.operationId, original.operationId);
    expect(decoded.state, CleanTransactionState.active);
    expect(decoded.targets.single.phase, CleanTargetPhase.planned);
    expect(
      decoded.targets.single.identity.sameObjectAs(
        original.targets.single.identity,
      ),
      isTrue,
    );
    expect(decoded.toJson(), original.toJson());
  });

  test('transaction rejects checksum drift and unknown authority values', () {
    final valid = _transaction().toJson();
    final tampered = jsonDecode(jsonEncode(valid)) as Map<String, dynamic>;
    final targets = tampered['targets'] as List<dynamic>;
    (targets.single as Map<String, dynamic>)['runId'] = 'replacement';

    expect(
      () => RecoverableCleanTransaction.fromJson(tampered),
      throwsFormatException,
    );
    expect(
      () => RecoverableCleanTransaction.fromJson(<String, dynamic>{
        ...valid,
        'version': 99,
      }),
      throwsFormatException,
    );
    expect(
      () => RecoverableCleanTransaction.fromJson(<String, dynamic>{
        ...valid,
        'state': 'finishedMaybe',
      }),
      throwsFormatException,
    );
  });

  test('transaction rejects duplicate or noncanonical target order', () {
    final targetA = _target('run-a');
    final targetB = _target('run-b');

    expect(
      () => RecoverableCleanTransaction.create(
        operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
        projectPath: '/project',
        quarantineBasePath: '/project/.flutter_pruner/quarantine',
        quarantineBaseIdentity: const CleanObjectIdentity(
          storageId: 'dev:1',
          objectId: 'ino:1',
          kind: CleanObjectKind.directory,
        ),
        planFingerprint: 'v2:${'c' * 64}',
        scope: 'all',
        targets: <RecoverableCleanTargetRecord>[targetB, targetA],
        state: CleanTransactionState.active,
        createdAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
        updatedAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
      ),
      throwsArgumentError,
    );
    expect(
      () => RecoverableCleanTransaction.create(
        operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
        projectPath: '/project',
        quarantineBasePath: '/project/.flutter_pruner/quarantine',
        quarantineBaseIdentity: const CleanObjectIdentity(
          storageId: 'dev:1',
          objectId: 'ino:1',
          kind: CleanObjectKind.directory,
        ),
        planFingerprint: 'v2:${'c' * 64}',
        scope: 'all',
        targets: <RecoverableCleanTargetRecord>[targetA, targetA],
        state: CleanTransactionState.active,
        createdAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
        updatedAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
      ),
      throwsArgumentError,
    );
  });
}

RecoverableCleanTransaction _transaction() =>
    RecoverableCleanTransaction.create(
      operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
      projectPath: '/project',
      quarantineBasePath: '/project/.flutter_pruner/quarantine',
      quarantineBaseIdentity: const CleanObjectIdentity(
        storageId: 'dev:1',
        objectId: 'ino:1',
        kind: CleanObjectKind.directory,
      ),
      planFingerprint: 'v2:${'c' * 64}',
      scope: 'targeted',
      targets: <RecoverableCleanTargetRecord>[_target('run-a')],
      state: CleanTransactionState.active,
      createdAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
      updatedAtUtc: DateTime.utc(2026, 8, 27, 1, 2, 3),
    );

RecoverableCleanTargetRecord _target(String runId) =>
    RecoverableCleanTargetRecord(
      runId: runId,
      sourceComponents: <String>[runId],
      destinationComponents: <String>[
        '.clean-retained',
        'v1',
        'clean-20260827T010203000000Z-a1b2c3d4',
        'runs',
        runId,
      ],
      identity: const CleanObjectIdentity(
        storageId: 'dev:1',
        objectId: 'ino:2',
        kind: CleanObjectKind.directory,
      ),
      layoutSha256: 'a' * 64,
      journalRevision: 7,
      payloadSha256: 'b' * 64,
      phase: CleanTargetPhase.planned,
    );
