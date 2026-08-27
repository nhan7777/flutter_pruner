import 'dart:convert';

import 'package:flutter_pruner/src/cli/formatters/quarantine_formatter.dart';
import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/manifest_authority.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_executor.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_plan.dart';
import 'package:test/test.dart';

void main() {
  test('logical clean plan binds root identity and retained destination', () {
    final plan = QuarantineCleanPlan.fromEvidence(
      scope: CleanScope.targeted,
      canonicalBases: const <String>['/project/.flutter_pruner/quarantine'],
      targets: const <QuarantineCleanTarget>[
        QuarantineCleanTarget(
          runId: 'run-a',
          canonicalPath: '/project/.flutter_pruner/quarantine/run-a',
          layoutSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          journalRevision: 4,
          payloadSha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          authority: ManifestCandidateName.primary,
          repairAction: ManifestRepairAction.none,
          rootIdentity: CleanObjectIdentity(
            storageId: 'dev:1',
            objectId: 'ino:2',
            kind: CleanObjectKind.directory,
          ),
          retainedDestinationComponents: <String>[
            '.clean-retained',
            'v1',
            'operation-placeholder',
            'runs',
            'run-a',
          ],
        ),
      ],
      backend: CleanBackendDisclosure.recoverableLogicalMove,
    );

    expect(plan.fingerprint, matches(RegExp(r'^v2:[0-9a-f]{64}$')));
    expect(plan.backend.name, 'recoverableLogicalMove');
    expect(plan.backend.identityBoundDelete, isFalse);
    expect(plan.backend.identityBoundMove, isTrue);
    expect(plan.backend.physicalDelete, isFalse);
    expect(plan.backend.crashRecoverableReceipt, isTrue);
  });

  test('retained receipt cannot claim physical deletion', () {
    final result = QuarantineCleanResult(
      fingerprint: 'v2:${'c' * 64}',
      operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
      mutationAttempted: true,
      outcomes: const <QuarantineCleanTargetOutcome>[
        QuarantineCleanTargetOutcome(
          runId: 'run-a',
          canonicalPath: '/quarantine/run-a',
          retainedPath: '/quarantine/.clean-retained/v1/op/runs/run-a',
          state: QuarantineCleanTargetState.retained,
          physicalBytesRetained: true,
        ),
      ],
    );

    expect(result.mutationAttempted, isTrue);
    expect(result.outcomes.single.state, QuarantineCleanTargetState.retained);
    expect(result.outcomes.single.physicalBytesRetained, isTrue);
    expect(result.outcomes.single.retainedPath, contains('.clean-retained'));
  });

  test('retained receipt rejects a false disk-destruction claim', () {
    expect(
      () => QuarantineCleanResult(
        fingerprint: 'v2:${'c' * 64}',
        operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
        mutationAttempted: true,
        outcomes: const <QuarantineCleanTargetOutcome>[
          QuarantineCleanTargetOutcome(
            runId: 'run-a',
            canonicalPath: '/quarantine/run-a',
            retainedPath: '/quarantine/.clean-retained/v1/op/runs/run-a',
            state: QuarantineCleanTargetState.retained,
            physicalBytesRetained: false,
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test(
    'retained receipt human and JSON projections disclose retained bytes',
    () {
      final result = QuarantineCleanResult(
        fingerprint: 'v2:${'c' * 64}',
        operationId: 'clean-20260827T010203000000Z-a1b2c3d4',
        mutationAttempted: true,
        outcomes: const <QuarantineCleanTargetOutcome>[
          QuarantineCleanTargetOutcome(
            runId: 'run-a',
            canonicalPath: '/quarantine/run-a',
            retainedPath: '/quarantine/.clean-retained/v1/op/runs/run-a',
            state: QuarantineCleanTargetState.retained,
            physicalBytesRetained: true,
          ),
        ],
      );

      final human = QuarantineFormatter.formatCleanResultHuman(result);
      final json =
          jsonDecode(QuarantineFormatter.formatCleanResultJson(result))
              as Map<String, dynamic>;

      expect(human, contains('Retained: run-a'));
      expect(human, contains('Disk space: retained'));
      expect(human, contains('.clean-retained/v1/op/runs/run-a'));
      expect(human, isNot(contains('Deletion attempted')));
      expect(json['operationId'], result.operationId);
      expect(json['mutationAttempted'], isTrue);
      expect(json['physicalDelete'], isFalse);
      expect(json['receiptCrashDurable'], isTrue);
      expect(
        (json['outcomes'] as List).single,
        containsPair('state', 'retained'),
      );
    },
  );
}
