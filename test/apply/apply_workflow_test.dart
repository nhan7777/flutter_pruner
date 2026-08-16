import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/apply/declaration_remover.dart';
import 'package:flutter_pruner/src/apply/file_lifecycle_manager.dart';
import 'package:flutter_pruner/src/apply/import_cleanup_runner.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ProjectContext project;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('workflow_test_');

    final pubspecFile = File(p.join(tempDir.path, 'pubspec.yaml'));
    pubspecFile.writeAsStringSync('''
name: test_app
version: 1.0.0
environment:
  sdk: ^3.9.0
''');

    project = await ProjectContext.load(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'full workflow: remove declaration, cleanup imports, verify rollback',
    () async {
      // Setup: file with unused declaration
      final file = File(p.join(tempDir.path, 'lib', 'utils.dart'));
      file.parent.createSync(recursive: true);
      final originalContent = '''
import 'dart:async';  // will become unused

void usedFunction() {
  print('used');
}

void unusedFunction() async {
  await Future.delayed(Duration(seconds: 1));
}
''';
      file.writeAsStringSync(originalContent);

      // Step 1: Remove declaration
      final remover = DeclarationRemover(project);
      final declId = 'dart:test_app/lib/utils.dart#unusedFunction';
      final modifiedContent = await remover.removeDeclarations(file.path, [
        declId,
      ]);

      expect(modifiedContent, contains('usedFunction'));
      expect(modifiedContent, isNot(contains('unusedFunction')));

      file.writeAsStringSync(modifiedContent);

      // Step 2: Cleanup imports
      final cleanupRunner = ImportCleanupRunner(projectRoot: project.root.path);
      final cleanupResult = await cleanupRunner.run([file.path]);

      expect(cleanupResult.success, isTrue);

      // Step 3: Verify import was removed
      final afterCleanup = file.readAsStringSync();
      expect(afterCleanup, isNot(contains('dart:async')));

      // Step 4: Create quarantine and test rollback
      final manager = QuarantineManager(tempDir);

      // Compute actual SHA-256
      final originalHash = sha256
          .convert(utf8.encode(originalContent))
          .toString();

      // ApplyCommand quarantines the untouched original before recreating a
      // working copy for declaration edits.
      file.writeAsStringSync(originalContent);

      final entry = QuarantineEntry(
        originalPath: file.path,
        sha256: originalHash,
        sizeBytes: originalContent.length,
        operationType: QuarantineOperationType.declaration,
        declarationIds: [declId],
      );
      final createdQuarantine = await manager.createQuarantine(
        runId: 'test-run',
        entries: [entry],
        quarantineBase: '.flutter_pruner/quarantine-test',
      );
      await manager.quarantineFile(
        file: file,
        expectedSha256: originalHash,
        quarantineDir: createdQuarantine,
        originalPath: file.path,
      );
      await manager.createWorkingCopy(
        entry: entry,
        quarantineDir: createdQuarantine,
      );
      file.writeAsStringSync(afterCleanup);
      await manager.recordModifiedFiles(
        quarantineDir: createdQuarantine,
        modifiedSha256ByPath: {
          file.path: sha256.convert(file.readAsBytesSync()).toString(),
        },
      );

      // Step 5: Rollback
      await manager.restore(
        quarantineDir: createdQuarantine,
        runId: 'test-run',
      );

      // Step 6: Verify original restored
      final restoredContent = file.readAsStringSync();
      expect(restoredContent, equals(originalContent));
      expect(restoredContent, contains('unusedFunction'));
      expect(restoredContent, contains('dart:async'));
    },
  );

  test('empty file lifecycle: delete internal file, keep public API', () async {
    // Internal file (lib/src/)
    final internalFile = File(
      p.join(tempDir.path, 'lib', 'src', 'internal.dart'),
    );
    internalFile.parent.createSync(recursive: true);
    internalFile.writeAsStringSync('void onlyFunction() {}');

    // Public file (lib/)
    final publicFile = File(p.join(tempDir.path, 'lib', 'public.dart'));
    publicFile.parent.createSync(recursive: true);
    publicFile.writeAsStringSync('void onlyFunction() {}');

    // Remove all declarations
    final remover = DeclarationRemover(project);

    final internalModified = await remover.removeDeclarations(
      internalFile.path,
      ['dart:test_app/lib/src/internal.dart#onlyFunction'],
    );
    final publicModified = await remover.removeDeclarations(publicFile.path, [
      'dart:test_app/lib/public.dart#onlyFunction',
    ]);

    internalFile.writeAsStringSync(internalModified);
    publicFile.writeAsStringSync(publicModified);

    // Check lifecycle
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(internalFile.path, internalModified), isTrue);
    expect(manager.shouldDelete(publicFile.path, publicModified), isFalse);
  });

  test('rollback refuses to overwrite edits made after apply', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'value.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const value = 1;\n';
    file.writeAsStringSync(original);

    final originalHash = sha256.convert(file.readAsBytesSync()).toString();
    final entry = QuarantineEntry(
      originalPath: file.path,
      sha256: originalHash,
      sizeBytes: file.lengthSync(),
      operationType: QuarantineOperationType.declaration,
    );
    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createQuarantine(
      runId: 'changed-after-apply',
      entries: [entry],
    );
    await manager.quarantineFile(
      file: file,
      expectedSha256: originalHash,
      quarantineDir: quarantine,
      originalPath: file.path,
    );
    await manager.createWorkingCopy(entry: entry, quarantineDir: quarantine);
    file.writeAsStringSync('const value = 2;\n');
    await manager.recordModifiedFiles(
      quarantineDir: quarantine,
      modifiedSha256ByPath: {
        file.path: sha256.convert(file.readAsBytesSync()).toString(),
      },
    );

    file.writeAsStringSync('const value = 3; // user edit\n');

    await expectLater(
      manager.restore(quarantineDir: quarantine, runId: 'changed-after-apply'),
      throwsA(isA<QuarantineException>()),
    );
    expect(file.readAsStringSync(), contains('user edit'));
  });

  test('rollback tolerates entries that were never quarantined', () async {
    final moved = File(p.join(tempDir.path, 'lib', 'src', 'moved.dart'));
    final untouched = File(
      p.join(tempDir.path, 'lib', 'src', 'untouched.dart'),
    );
    moved.parent.createSync(recursive: true);
    moved.writeAsStringSync('const moved = true;\n');
    untouched.writeAsStringSync('const untouched = true;\n');

    QuarantineEntry entryFor(File file) => QuarantineEntry(
      originalPath: file.path,
      sha256: sha256.convert(file.readAsBytesSync()).toString(),
      sizeBytes: file.lengthSync(),
    );

    final movedEntry = entryFor(moved);
    final untouchedEntry = entryFor(untouched);
    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createQuarantine(
      runId: 'partial-move',
      entries: [movedEntry, untouchedEntry],
    );
    await manager.quarantineFile(
      file: moved,
      expectedSha256: movedEntry.sha256,
      quarantineDir: quarantine,
      originalPath: moved.path,
    );

    await manager.restore(quarantineDir: quarantine, runId: 'partial-move');

    expect(moved.readAsStringSync(), 'const moved = true;\n');
    expect(untouched.readAsStringSync(), 'const untouched = true;\n');
  });

  test('case rollback preserves an earlier case on the same file', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'values.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const first = 1;\nconst second = 2;\n';
    const afterFirst = 'const second = 2;\n';
    const afterSecond = '// invalid candidate\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'cases');

    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'first',
      file: file,
      operationType: QuarantineOperationType.declaration,
      declarationIds: const ['first'],
    );
    file.writeAsStringSync(afterFirst);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0002',
      findingId: 'second',
      file: file,
      operationType: QuarantineOperationType.declaration,
      declarationIds: const ['second'],
    );
    file.writeAsStringSync(afterSecond);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0002',
    );
    await manager.rollbackCase(
      quarantineDir: quarantine,
      caseId: 'case-0002',
      reason: 'verification regression',
    );

    expect(file.readAsStringSync(), afterFirst);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.cases[0].status, QuarantineCaseStatus.kept);
    expect(manifest.cases[1].status, QuarantineCaseStatus.rolledBack);

    await manager.restore(quarantineDir: quarantine, runId: 'cases');
    expect(file.readAsStringSync(), original);
  });

  test('atomic case rollback is byte-exact and idempotent', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'atomic.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const first = 1;\nconst second = 2;\n';
    const afterFirst = 'const second = 2;\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'atomic');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'first',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync(afterFirst);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0002',
      findingId: 'second',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync('');
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0002',
    );

    const caseIds = ['case-0001', 'case-0002'];
    await manager.rollbackCasesAtomically(
      quarantineDir: quarantine,
      caseIds: caseIds,
      reason: 'regression',
    );
    expect(file.readAsStringSync(), original);

    await manager.rollbackCasesAtomically(
      quarantineDir: quarantine,
      caseIds: caseIds,
      reason: 'recovery replay',
    );
    expect(file.readAsStringSync(), original);
    final manifest = await manager.readManifest(quarantine);
    expect(
      manifest.cases.map((item) => item.status),
      everyElement(QuarantineCaseStatus.rolledBack),
    );
  });

  test('full rollback journals a multi-case path already restored', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'replayed.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const first = 1;\nconst second = 2;\n';
    const afterFirst = 'const second = 2;\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'replayed');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'first',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync(afterFirst);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0002',
      findingId: 'second',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.deleteSync();
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0002',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0002');

    // Simulate a crash after byte restoration but before journal persistence.
    file.writeAsStringSync(original);
    await manager.restore(quarantineDir: quarantine, runId: 'replayed');

    expect(file.readAsStringSync(), original);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.fullRollbackVerified, isTrue);
    expect(
      manifest.cases.map((item) => item.status),
      everyElement(QuarantineCaseStatus.rolledBack),
    );
  });

  test('case rollback refuses to overwrite later user edits', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'guarded.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('const value = 1;\n');

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'guarded');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'value',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync('const value = 2;\n');
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

    file.writeAsStringSync('const value = 3; // user edit\n');

    await expectLater(
      manager.rollbackCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        reason: 'manual test',
      ),
      throwsA(isA<QuarantineException>()),
    );
    expect(file.readAsStringSync(), contains('user edit'));
  });

  test('full run rollback restores a file-level deletion', () async {
    final asset = File(p.join(tempDir.path, 'assets', 'unused.png'));
    asset.parent.createSync(recursive: true);
    final originalBytes = List<int>.generate(32, (index) => index);
    asset.writeAsBytesSync(originalBytes);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'asset');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'asset:unused.png',
      file: asset,
      operationType: QuarantineOperationType.file,
    );
    asset.deleteSync();
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

    await manager.restore(quarantineDir: quarantine, runId: 'asset');

    expect(asset.readAsBytesSync(), originalBytes);
  });

  test(
    'direct V3 byte restore remains recovery-required without verifier proof',
    () async {
      final file = File(p.join(tempDir.path, 'lib', 'src', 'v3.dart'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('const original = true;\n');
      final manager = QuarantineManager(tempDir);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'v3-restore',
        verificationPolicyHash: 'policy',
      );
      await manager.beginTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-r001-restore',
        round: 1,
        componentId: 'unit:restore',
        findingIds: const ['dart:test_app/lib/src/v3.dart#original'],
        caseIds: const ['case-0001'],
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'dart:test_app/lib/src/v3.dart#original',
        file: file,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-r001-restore',
      );
      file.writeAsStringSync('const applied = true;\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.recordTransactionApplied(
        quarantineDir: quarantine,
        transactionId: 'tx-r001-restore',
        caseIds: const ['case-0001'],
      );
      await manager.verifyTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-r001-restore',
        policyHash: 'policy',
        requiredStepIds: const ['analyze'],
        observedStepIds: const ['analyze'],
      );
      await manager.commitTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-r001-restore',
      );

      await manager.restore(quarantineDir: quarantine, runId: 'v3-restore');

      final manifest = await manager.readManifest(quarantine);
      expect(file.readAsStringSync(), 'const original = true;\n');
      expect(manifest.fullRollbackVerified, isFalse);
      expect(manifest.fullRollbackAtUtc, isNull);
      expect(manifest.cases.single.status, QuarantineCaseStatus.kept);
      expect(
        manifest.transactions.single.status,
        QuarantineTransactionStatus.recoveryRequired,
      );
      expect(manifest.transactions.single.rollbackVerified, isFalse);
      expect(
        await manager.readRunLifecycleState(quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      await expectLater(
        manager.validateCleanQuarantine(runId: 'v3-restore'),
        throwsA(isA<QuarantineException>()),
      );
    },
  );

  test('full rollback resumes an interrupted atomic restore', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'retry.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const value = 1;\n';
    const applied = 'const value = 2;\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'retry');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'value',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync(applied);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

    final snapshot = File(
      p.join(quarantine.path, 'cases', 'case-0001', 'lib', 'src', 'retry.dart'),
    );
    final token = sha256
        .convert(utf8.encode(p.normalize(p.absolute(snapshot.path))))
        .toString()
        .substring(0, 16);
    final staging = Directory(
      p.join(
        tempDir.path,
        '.flutter_pruner',
        'tmp',
        'restore',
        'case-0001-$token',
      ),
    )..createSync(recursive: true);
    snapshot.copySync(p.join(staging.path, 'restored'));
    file.renameSync(p.join(staging.path, 'displaced'));
    expect(file.existsSync(), isFalse);

    await manager.restore(quarantineDir: quarantine, runId: 'retry');

    expect(file.readAsStringSync(), original);
    expect(staging.existsSync(), isFalse);
  });

  test('full rollback refuses an interrupted unrecorded case', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'interrupted.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const before = true;\n';
    const interrupted = 'const partiallyWritten = true;\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(runId: 'interrupted');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'before',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync(interrupted);

    await expectLater(
      manager.restore(quarantineDir: quarantine, runId: 'interrupted'),
      throwsA(isA<QuarantineException>()),
    );

    expect(file.readAsStringSync(), interrupted);
    final snapshot = File(
      p.join(
        quarantine.path,
        'cases',
        'case-0001',
        'lib',
        'src',
        'interrupted.dart',
      ),
    );
    expect(snapshot.readAsStringSync(), original);
    final recovery = File(
      p.join(
        quarantine.path,
        'recovery',
        'case-0001',
        'lib',
        'src',
        'interrupted.dart',
      ),
    );
    expect(recovery.readAsStringSync(), interrupted);
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.fullRollbackVerified, isFalse);
    expect(manifest.cases.single.status, QuarantineCaseStatus.backedUp);
    await expectLater(
      manager.validateCleanQuarantine(runId: 'interrupted'),
      throwsA(isA<QuarantineException>()),
    );
  });

  test('full rollback refuses an unrecorded shared-file write', () async {
    final file = File(p.join(tempDir.path, 'lib', 'src', 'shared_crash.dart'));
    file.parent.createSync(recursive: true);
    const original = 'const first = 1;\nconst second = 2;\n';
    const afterFirst = 'const second = 2;\n';
    file.writeAsStringSync(original);

    final manager = QuarantineManager(tempDir);
    final quarantine = await manager.createCaseQuarantine(
      runId: 'shared-crash',
    );
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0001',
      findingId: 'first',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync(afterFirst);
    await manager.recordCaseApplied(
      quarantineDir: quarantine,
      caseId: 'case-0001',
    );
    await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: 'case-0002',
      findingId: 'second',
      file: file,
      operationType: QuarantineOperationType.declaration,
    );
    file.writeAsStringSync('// interrupted write\n');

    await expectLater(
      manager.restore(quarantineDir: quarantine, runId: 'shared-crash'),
      throwsA(isA<QuarantineException>()),
    );

    expect(file.readAsStringSync(), '// interrupted write\n');
    final firstSnapshot = File(
      p.join(
        quarantine.path,
        'cases',
        'case-0001',
        'lib',
        'src',
        'shared_crash.dart',
      ),
    );
    final secondSnapshot = File(
      p.join(
        quarantine.path,
        'cases',
        'case-0002',
        'lib',
        'src',
        'shared_crash.dart',
      ),
    );
    expect(firstSnapshot.readAsStringSync(), original);
    expect(secondSnapshot.readAsStringSync(), afterFirst);
    final recovery = File(
      p.join(
        quarantine.path,
        'recovery',
        'case-0002',
        'lib',
        'src',
        'shared_crash.dart',
      ),
    );
    expect(recovery.readAsStringSync(), '// interrupted write\n');
    final manifest = await manager.readManifest(quarantine);
    expect(manifest.fullRollbackVerified, isFalse);
    expect(manifest.cases.map((item) => item.status), [
      QuarantineCaseStatus.kept,
      QuarantineCaseStatus.backedUp,
    ]);
    await expectLater(
      manager.validateCleanQuarantine(runId: 'shared-crash'),
      throwsA(isA<QuarantineException>()),
    );
  });

  test(
    'transaction journal rejects illegal states and undeclared cases',
    () async {
      final file = File(p.join(tempDir.path, 'lib', 'state.dart'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('const value = 1;\n');
      final manager = QuarantineManager(tempDir);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'state-machine',
        verificationPolicyHash: 'policy',
      );
      await expectLater(
        manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'tx-duplicate-cases',
          round: 1,
          componentId: 'unit:duplicate',
          findingIds: const ['value'],
          caseIds: const ['case-0001', 'case-0001'],
        ),
        throwsA(isA<QuarantineException>()),
      );
      await expectLater(
        manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-unowned',
          findingId: 'value',
          file: file,
          operationType: QuarantineOperationType.declaration,
        ),
        throwsA(isA<QuarantineException>()),
      );
      await manager.beginTransaction(
        quarantineDir: quarantine,
        transactionId: 'tx-1',
        round: 1,
        componentId: 'unit:1',
        findingIds: const ['value'],
        caseIds: const ['case-0001'],
      );

      await expectLater(
        manager.verifyTransaction(
          quarantineDir: quarantine,
          transactionId: 'tx-1',
          policyHash: 'policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        ),
        throwsA(isA<QuarantineException>()),
      );
      await expectLater(
        manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-unknown',
          findingId: 'value',
          file: file,
          operationType: QuarantineOperationType.declaration,
          transactionId: 'tx-1',
        ),
        throwsA(isA<QuarantineException>()),
      );

      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'value',
        file: file,
        operationType: QuarantineOperationType.declaration,
        transactionId: 'tx-1',
      );
      file.writeAsStringSync('const value = 2;\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.recordTransactionApplied(
        quarantineDir: quarantine,
        transactionId: 'tx-1',
        caseIds: const ['case-0001'],
      );
      await expectLater(
        manager.verifyTransaction(
          quarantineDir: quarantine,
          transactionId: 'tx-1',
          policyHash: 'wrong-policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        ),
        throwsA(isA<QuarantineException>()),
      );
      await expectLater(
        manager.verifyTransaction(
          quarantineDir: quarantine,
          transactionId: 'tx-1',
          policyHash: 'policy',
          requiredStepIds: const ['analyze', 'test'],
          observedStepIds: const ['analyze'],
        ),
        throwsA(isA<QuarantineException>()),
      );
    },
  );
}
