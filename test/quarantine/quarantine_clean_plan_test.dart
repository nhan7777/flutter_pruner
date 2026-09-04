import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;
  late QuarantineManager manager;

  setUp(() {
    project = Directory.systemTemp.createTempSync(
      'quarantine_clean_plan_test_',
    );
    manager = QuarantineManager(project);
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test(
    'targeted preview binds the cleanable run without deleting it',
    () async {
      final quarantine = await manager.createQuarantine(
        runId: 'targeted-run',
        entries: const [],
      );
      final before = _snapshotTree(quarantine);

      final plan = await manager.planCleanQuarantine(runId: 'targeted-run');

      expect(plan.scope, CleanScope.targeted);
      expect(plan.fingerprint, matches(RegExp(r'^v2:[0-9a-f]{64}$')));
      expect(plan.targets, hasLength(1));
      expect(plan.targets.single.runId, 'targeted-run');
      expect(
        plan.targets.single.canonicalPath,
        quarantine.resolveSymbolicLinksSync(),
      );
      expect(
        plan.targets.single.layoutSha256,
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(plan.targets.single.journalRevision, 1);
      expect(
        plan.targets.single.payloadSha256,
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(plan.targets.single.authority, ManifestCandidateName.primary);
      expect(plan.targets.single.repairAction, ManifestRepairAction.none);
      expect(plan.backend.name, 'recoverableLogicalMove');
      expect(plan.backend.batchAtomic, isFalse);
      expect(plan.backend.identityBoundDelete, isFalse);
      expect(plan.backend.identityBoundMove, isTrue);
      expect(plan.backend.physicalDelete, isFalse);
      expect(plan.backend.crashRecoverableReceipt, isTrue);
      expect(plan.backend.releaseEligible, isFalse);
      expect(plan.backend.blockerCode, 'CLEAN-TOCTOU-1');
      expect(() => plan.canonicalBases.add('/other'), throwsUnsupportedError);
      expect(() => plan.targets.clear(), throwsUnsupportedError);
      expect(_snapshotTree(quarantine), before);
    },
  );

  test(
    'all preview spans current and legacy bases in stable run order',
    () async {
      final legacy = await manager.createQuarantine(
        runId: 'run-z',
        entries: const [],
        quarantineBase: QuarantineManager.legacyQuarantineDir,
      );
      final current = await manager.createQuarantine(
        runId: 'run-a',
        entries: const [],
      );
      final before = <String, Map<String, String>>{
        current.path: _snapshotTree(current),
        legacy.path: _snapshotTree(legacy),
      };

      final first = await manager.planCleanQuarantine();
      final second = await manager.planCleanQuarantine();
      final targetedLegacy = await manager.planCleanQuarantine(runId: 'run-z');

      expect(first.scope, CleanScope.all);
      expect(first.targets.map((target) => target.runId), ['run-a', 'run-z']);
      expect(
        first.canonicalBases,
        [
          current.parent.resolveSymbolicLinksSync(),
          legacy.parent.resolveSymbolicLinksSync(),
        ]..sort(),
      );
      expect(second.fingerprint, first.fingerprint);
      expect(
        second.targets.map((target) => target.layoutSha256),
        first.targets.map((target) => target.layoutSha256),
      );
      expect(_snapshotTree(current), before[current.path]);
      expect(_snapshotTree(legacy), before[legacy.path]);
      expect(targetedLegacy.scope, CleanScope.targeted);
      expect(
        targetedLegacy.targets.single.canonicalPath,
        legacy.resolveSymbolicLinksSync(),
      );
    },
  );

  test(
    'explicit custom base is canonical and an empty scope is stable',
    () async {
      final custom = Directory(p.join(project.path, 'custom', 'quarantine'))
        ..createSync(recursive: true);
      final quarantine = await manager.createQuarantine(
        runId: 'custom-run',
        entries: const [],
        quarantineBase: custom.path,
      );

      final targeted = await manager.planCleanQuarantine(
        runId: 'custom-run',
        quarantineBases: [custom],
      );
      expect(targeted.canonicalBases, [custom.resolveSymbolicLinksSync()]);
      expect(
        targeted.targets.single.canonicalPath,
        quarantine.resolveSymbolicLinksSync(),
      );

      final emptyBase = Directory(p.join(project.path, 'empty-quarantine'))
        ..createSync();
      final first = await manager.planCleanQuarantine(
        quarantineBases: [emptyBase, emptyBase],
      );
      final second = await manager.planCleanQuarantine(
        quarantineBases: [emptyBase],
      );
      expect(first.scope, CleanScope.all);
      expect(first.canonicalBases, [emptyBase.resolveSymbolicLinksSync()]);
      expect(first.targets, isEmpty);
      expect(first.fingerprint, second.fingerprint);
    },
  );

  test('fingerprint binds every target and backend field', () {
    QuarantineCleanPlan build({
      CleanScope scope = CleanScope.targeted,
      String path = '/base/run',
      String layout =
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      int revision = 7,
      String payload =
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ManifestCandidateName authority = ManifestCandidateName.primary,
      ManifestRepairAction repair = ManifestRepairAction.none,
      CleanBackendDisclosure backend =
          CleanBackendDisclosure.currentRecursiveDelete,
    }) => QuarantineCleanPlan.fromEvidence(
      scope: scope,
      canonicalBases: const ['/base'],
      targets: [
        QuarantineCleanTarget(
          runId: 'run',
          canonicalPath: path,
          layoutSha256: layout,
          journalRevision: revision,
          payloadSha256: payload,
          authority: authority,
          repairAction: repair,
        ),
      ],
      backend: backend,
    );

    final baseline = build();
    expect(
      baseline.fingerprint,
      'v1:b0cfa443c3e07fb54d044188f8ba09201cd5f22a3c4a85c0698bb990c01f397d',
    );
    expect(
      build(scope: CleanScope.all).fingerprint,
      isNot(baseline.fingerprint),
    );
    expect(build(path: '/base/other').fingerprint, isNot(baseline.fingerprint));
    expect(build(layout: 'c' * 64).fingerprint, isNot(baseline.fingerprint));
    expect(build(revision: 8).fingerprint, isNot(baseline.fingerprint));
    expect(build(payload: 'd' * 64).fingerprint, isNot(baseline.fingerprint));
    expect(
      build(authority: ManifestCandidateName.temporary).fingerprint,
      isNot(baseline.fingerprint),
    );
    expect(
      build(repair: ManifestRepairAction.promoteTemporary).fingerprint,
      isNot(baseline.fingerprint),
    );
    expect(
      build(
        backend: const CleanBackendDisclosure(
          name: 'futureIdentityBoundDelete',
          batchAtomic: true,
          identityBoundDelete: true,
          crashRecoverableReceipt: true,
          releaseEligible: true,
          blockerCode: null,
        ),
      ).fingerprint,
      isNot(baseline.fingerprint),
    );
  });

  test('plan construction canonicalizes base and target ordering', () {
    QuarantineCleanTarget target(String runId, String path) =>
        QuarantineCleanTarget(
          runId: runId,
          canonicalPath: path,
          layoutSha256: 'a' * 64,
          journalRevision: 1,
          payloadSha256: 'b' * 64,
          authority: ManifestCandidateName.primary,
          repairAction: ManifestRepairAction.none,
        );
    final reversed = QuarantineCleanPlan.fromEvidence(
      scope: CleanScope.all,
      canonicalBases: const ['/z', '/a', '/a'],
      targets: [target('run-z', '/z/run-z'), target('run-a', '/a/run-a')],
    );
    final canonical = QuarantineCleanPlan.fromEvidence(
      scope: CleanScope.all,
      canonicalBases: const ['/a', '/z'],
      targets: [target('run-a', '/a/run-a'), target('run-z', '/z/run-z')],
    );

    expect(reversed.canonicalBases, ['/a', '/z']);
    expect(reversed.targets.map((target) => target.runId), ['run-a', 'run-z']);
    expect(reversed.fingerprint, canonical.fingerprint);
  });

  test(
    'duplicate run IDs and invalid siblings block targeted planning',
    () async {
      final current = await manager.createQuarantine(
        runId: 'duplicate-run',
        entries: const [],
      );
      final legacy = await manager.createQuarantine(
        runId: 'duplicate-run',
        entries: const [],
        quarantineBase: QuarantineManager.legacyQuarantineDir,
      );
      final duplicateBefore = <String, Map<String, String>>{
        current.path: _snapshotTree(current),
        legacy.path: _snapshotTree(legacy),
      };

      await expectLater(
        manager.planCleanQuarantine(runId: 'duplicate-run'),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.message,
            'message',
            contains('duplicate_run_id'),
          ),
        ),
      );
      expect(_snapshotTree(current), duplicateBefore[current.path]);
      expect(_snapshotTree(legacy), duplicateBefore[legacy.path]);

      legacy.deleteSync(recursive: true);
      final sibling = File(p.join(current.parent.path, 'unexpected'))
        ..writeAsBytesSync([0, 1, 2]);
      final siblingBytes = sibling.readAsBytesSync();
      await expectLater(
        manager.planCleanQuarantine(runId: 'duplicate-run'),
        throwsA(
          isA<QuarantineException>().having(
            (error) => error.message,
            'message',
            contains('unexpected_entry'),
          ),
        ),
      );
      expect(sibling.readAsBytesSync(), siblingBytes);
      expect(_snapshotTree(current), duplicateBefore[current.path]);
    },
  );

  test('an active sibling blocks even a different targeted run', () async {
    final cleanable = await manager.createQuarantine(
      runId: 'cleanable-run',
      entries: const [],
    );
    final active = await manager.createCaseQuarantine(
      runId: 'active-run',
      verificationPolicyHash: 'policy',
    );
    final before = <String, Map<String, String>>{
      cleanable.path: _snapshotTree(cleanable),
      active.path: _snapshotTree(active),
    };

    await expectLater(
      manager.planCleanQuarantine(runId: 'cleanable-run'),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.message,
          'message',
          contains('active-run'),
        ),
      ),
    );
    expect(_snapshotTree(cleanable), before[cleanable.path]);
    expect(_snapshotTree(active), before[active.path]);
  });

  test('foreign-project quarantine cannot enter a clean plan', () async {
    final externalBase = Directory.systemTemp.createTempSync(
      'quarantine_clean_foreign_base_',
    );
    final otherProject = Directory.systemTemp.createTempSync(
      'quarantine_clean_foreign_project_',
    );
    addTearDown(() {
      if (externalBase.existsSync()) externalBase.deleteSync(recursive: true);
      if (otherProject.existsSync()) otherProject.deleteSync(recursive: true);
    });
    final foreign = await manager.createQuarantine(
      runId: 'foreign-run',
      entries: const [],
      quarantineBase: externalBase.path,
    );
    final before = _snapshotTree(foreign);

    await expectLater(
      QuarantineManager(
        otherProject,
      ).planCleanQuarantine(quarantineBases: [externalBase]),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.message,
          'message',
          contains('foreign_project'),
        ),
      ),
    );
    expect(_snapshotTree(foreign), before);
  });

  test('symlinks and paths escaping a canonical base are rejected', () async {
    if (Platform.isWindows) return;
    final quarantine = await manager.createQuarantine(
      runId: 'linked-tree',
      entries: const [],
    );
    final outside = File(p.join(project.path, 'outside.txt'))
      ..writeAsStringSync('outside');
    final link = Link(p.join(quarantine.path, 'escape-link'))
      ..createSync(outside.path);

    await expectLater(
      manager.planCleanQuarantine(runId: 'linked-tree'),
      throwsA(isA<QuarantineException>()),
    );
    expect(link.existsSync(), isTrue);
    expect(outside.readAsStringSync(), 'outside');

    link.deleteSync();
    final base = quarantine.parent;
    quarantine.deleteSync(recursive: true);
    final externalRun = Directory.systemTemp.createTempSync('escaped-run-');
    addTearDown(() {
      if (externalRun.existsSync()) externalRun.deleteSync(recursive: true);
    });
    Link(p.join(base.path, 'linked-tree')).createSync(externalRun.path);
    await expectLater(
      manager.planCleanQuarantine(runId: 'linked-tree'),
      throwsA(
        isA<QuarantineException>().having(
          (error) => error.message,
          'message',
          contains('symlink_entry'),
        ),
      ),
    );
  });

  test('special and unreadable tree entries are rejected', () async {
    final quarantine = await manager.createQuarantine(
      runId: 'unsafe-tree',
      entries: const [],
    );
    if (!Platform.isWindows) {
      final pipePath = p.join(quarantine.path, 'pipe');
      final created = Process.runSync('/usr/bin/mkfifo', [pipePath]);
      expect(created.exitCode, 0, reason: '${created.stderr}');
      await expectLater(
        manager.planCleanQuarantine(runId: 'unsafe-tree'),
        throwsA(isA<QuarantineException>()),
      );
      File(pipePath).deleteSync();
    }

    if (Platform.isLinux || Platform.isMacOS) {
      final unreadable = File(p.join(quarantine.path, 'unreadable'))
        ..writeAsStringSync('private');
      Process.runSync('/bin/chmod', ['000', unreadable.path]);
      var trulyUnreadable = false;
      try {
        unreadable.readAsBytesSync();
      } on FileSystemException {
        trulyUnreadable = true;
      }
      if (trulyUnreadable) {
        await expectLater(
          manager.planCleanQuarantine(runId: 'unsafe-tree'),
          throwsA(isA<QuarantineException>()),
        );
      }
      Process.runSync('/bin/chmod', ['600', unreadable.path]);
    }
  });

  test(
    'portable POSIX mode changes alter layout and plan fingerprints',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final quarantine = await manager.createQuarantine(
        runId: 'mode-evidence',
        entries: const [],
      );
      final evidence = File(p.join(quarantine.path, 'evidence'))
        ..writeAsStringSync('same bytes');
      Process.runSync('/bin/chmod', ['600', evidence.path]);
      final before = await manager.planCleanQuarantine(runId: 'mode-evidence');

      Process.runSync('/bin/chmod', ['640', evidence.path]);
      final after = await manager.planCleanQuarantine(runId: 'mode-evidence');

      expect(
        after.targets.single.layoutSha256,
        isNot(before.targets.single.layoutSha256),
      );
      expect(after.fingerprint, isNot(before.fingerprint));
    },
  );

  test(
    'empty and same-size file bytes are bound into the tree digest',
    () async {
      final quarantine = await manager.createQuarantine(
        runId: 'file-content-evidence',
        entries: const [],
      );
      final evidence = File(p.join(quarantine.path, 'evidence'))
        ..writeAsBytesSync(const []);
      final empty = await manager.planCleanQuarantine(
        runId: 'file-content-evidence',
      );

      evidence.writeAsBytesSync(const [65], flush: true);
      final first = await manager.planCleanQuarantine(
        runId: 'file-content-evidence',
      );
      evidence.writeAsBytesSync(const [66], flush: true);
      final second = await manager.planCleanQuarantine(
        runId: 'file-content-evidence',
      );

      expect(
        first.targets.single.layoutSha256,
        isNot(empty.targets.single.layoutSha256),
      );
      expect(
        second.targets.single.layoutSha256,
        isNot(first.targets.single.layoutSha256),
      );
    },
  );

  test(
    'planning interruption preserves every observed byte and path',
    () async {
      final quarantine = await manager.createQuarantine(
        runId: 'planning-interruption',
        entries: const [],
      );
      File(p.join(quarantine.path, 'empty')).writeAsBytesSync(const []);
      final before = _snapshotTree(quarantine);
      manager = _managerWithSnapshotHook(
        project,
        () => throw StateError('injected interruption'),
      );

      await expectLater(
        manager.planCleanQuarantine(runId: 'planning-interruption'),
        throwsStateError,
      );
      expect(_snapshotTree(quarantine), before);
    },
  );

  test('tree layout drift between complete snapshots is typed', () async {
    final quarantine = await manager.createQuarantine(
      runId: 'layout-drift',
      entries: const [],
    );
    manager = _managerWithSnapshotHook(project, () {
      File(p.join(quarantine.path, 'appeared')).writeAsStringSync('new');
    });

    await expectLater(
      manager.planCleanQuarantine(runId: 'layout-drift'),
      throwsA(isA<QuarantineCleanPlanDriftException>()),
    );
    expect(quarantine.existsSync(), isTrue);
  });

  for (final drift in ['revision', 'checksum', 'candidate']) {
    test('manifest $drift drift between snapshots is typed', () async {
      final quarantine = await manager.createQuarantine(
        runId: 'manifest-$drift',
        entries: const [],
      );
      final manifest = File(p.join(quarantine.path, 'manifest.json'));
      manager = _managerWithSnapshotHook(project, () {
        switch (drift) {
          case 'revision':
            _rewriteManifest(manifest, (payload) {
              payload['timestamp'] = '2026-08-26T00:00:00.000Z';
            });
          case 'checksum':
            _rewriteManifest(manifest, (payload) {
              payload['timestamp'] = '2026-08-26T00:00:00.000Z';
            }, validChecksum: false);
          case 'candidate':
            final temporary = File('${manifest.path}.tmp');
            _rewriteManifest(manifest, (payload) {
              payload['timestamp'] = '2026-08-26T00:00:00.000Z';
            }, destination: temporary);
        }
      });

      await expectLater(
        manager.planCleanQuarantine(runId: 'manifest-$drift'),
        throwsA(isA<QuarantineCleanPlanDriftException>()),
      );
      expect(quarantine.existsSync(), isTrue);
    });
  }

  test('lifecycle drift between snapshots is typed', () async {
    final quarantine = await _createRolledBackV3(
      manager,
      project,
      'lifecycle-drift',
    );
    final manifest = File(p.join(quarantine.path, 'manifest.json'));
    manager = _managerWithSnapshotHook(project, () {
      _rewriteManifest(manifest, (payload) {
        payload['_runLifecycle'] = <String, Object?>{
          'version': 1,
          'state': 'recoveryRequired',
        };
      });
    });

    await expectLater(
      manager.planCleanQuarantine(runId: 'lifecycle-drift'),
      throwsA(isA<QuarantineCleanPlanDriftException>()),
    );
    expect(quarantine.existsSync(), isTrue);
  });
}

QuarantineManager _managerWithSnapshotHook(
  Directory project,
  FutureOr<void> Function() hook,
) => QuarantineManager(project, cleanPlanSnapshotHook: (_) => hook());

Future<Directory> _createRolledBackV3(
  QuarantineManager manager,
  Directory project,
  String runId,
) async {
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    verificationPolicyHash: 'policy',
  );
  final source = File(p.join(project.path, '$runId.dart'))
    ..writeAsStringSync('const value = 1;\n');
  final entry = QuarantineEntry(
    originalPath: source.path,
    sha256: sha256.convert(source.readAsBytesSync()).toString(),
    sizeBytes: source.lengthSync(),
    posixMode: Platform.isLinux || Platform.isMacOS
        ? source.statSync().mode & 0xfff
        : null,
    operationType: QuarantineOperationType.declaration,
  );
  final manifest = File(p.join(quarantine.path, 'manifest.json'));
  _rewriteManifest(manifest, (payload) {
    payload['cases'] = [
      QuarantineCase(
        caseId: 'case-1',
        findingId: 'finding-1',
        entry: entry,
        status: QuarantineCaseStatus.rolledBack,
        transactionId: 'tx-1',
      ).toJson(),
    ];
    payload['transactions'] = [
      const QuarantineTransaction(
        transactionId: 'tx-1',
        round: 1,
        componentId: 'unit:test',
        findingIds: ['finding-1'],
        caseIds: ['case-1'],
        status: QuarantineTransactionStatus.rolledBackVerified,
        verificationPolicyHash: 'policy',
        requiredStepIds: ['analyze'],
        observedStepIds: ['analyze'],
        rollbackVerified: true,
      ).toJson(),
    ];
    payload['fullRollback'] = <String, Object?>{
      'status': 'restored',
      'verified': true,
      'restoredAtUtc': '2026-08-26T00:00:00.000Z',
    };
    payload['_runLifecycle'] = <String, Object?>{
      'version': 1,
      'state': 'rolledBackVerified',
    };
  });
  return quarantine;
}

void _rewriteManifest(
  File source,
  void Function(Map<String, dynamic> payload) mutate, {
  File? destination,
  bool validChecksum = true,
}) {
  final document =
      jsonDecode(source.readAsStringSync()) as Map<String, dynamic>;
  final priorJournal = document.remove('_journal') as Map<String, dynamic>;
  mutate(document);
  final payloadSha256 = validChecksum
      ? sha256.convert(utf8.encode(jsonEncode(document))).toString()
      : '0' * 64;
  final next = <String, dynamic>{
    ...document,
    '_journal': <String, dynamic>{
      'revision': (priorJournal['revision'] as int) + 1,
      'payloadSha256': payloadSha256,
    },
  };
  (destination ?? source).writeAsStringSync(jsonEncode(next), flush: true);
}

Map<String, String> _snapshotTree(Directory root) {
  final snapshot = <String, String>{};
  final entities = <FileSystemEntity>[root];
  if (root.existsSync()) {
    entities.addAll(root.listSync(recursive: true, followLinks: false));
  }
  entities.sort((left, right) => left.path.compareTo(right.path));
  for (final entity in entities) {
    final relative = p.relative(entity.path, from: root.path);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    snapshot[relative] = switch (type) {
      FileSystemEntityType.file =>
        'file:${base64Encode(File(entity.path).readAsBytesSync())}',
      FileSystemEntityType.directory => 'directory',
      FileSystemEntityType.link => 'link:${Link(entity.path).targetSync()}',
      FileSystemEntityType.pipe => 'pipe',
      FileSystemEntityType.unixDomainSock => 'unixDomainSock',
      FileSystemEntityType.notFound => 'notFound',
      _ => 'other',
    };
  }
  return snapshot;
}
