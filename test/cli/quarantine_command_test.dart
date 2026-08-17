import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('clean rejects --all combined with a run ID before prompting', () async {
    final project = Directory.systemTemp.createTempSync(
      'quarantine_command_test_',
    );
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: quarantine_test\n');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'quarantine',
        'clean',
        '--project',
        project.path,
        '--all',
        'one-run',
      ]);

      expect(exitCode, 64);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'clean --all rejects an invalid raw run before deleting any sibling',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final manager = QuarantineManager(project);
        final cleanable = await manager.createQuarantine(
          runId: 'cleanable-run',
          entries: const [],
        );
        final invalid = Directory(
          p.join(
            project.path,
            QuarantineManager.defaultQuarantineDir,
            'invalid-run',
          ),
        )..createSync(recursive: true);
        File(
          p.join(invalid.path, 'manifest.json'),
        ).writeAsStringSync('{invalid');

        final process = await Process.start(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          '--all',
        ]);
        process.stdin.writeln('y');
        await process.stdin.close();
        final stderrText = await process.stderr
            .transform(systemEncoding.decoder)
            .join();
        await process.stdout.drain<void>();
        final exitCode = await process.exitCode;

        expect(exitCode, 1);
        expect(stderrText, contains('invalid-run'));
        expect(cleanable.existsSync(), isTrue);
        expect(invalid.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean preserves a quarantine whose manifest belongs to another project',
    () async {
      final selected = Directory.systemTemp.createTempSync(
        'quarantine_selected_',
      );
      final recorded = Directory.systemTemp.createTempSync(
        'quarantine_recorded_',
      );
      try {
        for (final project in [selected, recorded]) {
          File(
            p.join(project.path, 'pubspec.yaml'),
          ).writeAsStringSync('name: quarantine_test\n');
        }
        final quarantine = await QuarantineManager(recorded)
            .createCaseQuarantine(
              runId: 'foreign-run',
              quarantineBase: p.join(
                selected.path,
                QuarantineManager.defaultQuarantineDir,
              ),
            );

        final exitCode = await FlutterPrunerCommandRunner().run([
          'quarantine',
          'clean',
          '--project',
          selected.path,
          'foreign-run',
        ]);

        expect(exitCode, 1);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (selected.existsSync()) selected.deleteSync(recursive: true);
        if (recorded.existsSync()) recorded.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean refuses a pending transaction',
    () => _expectCleanRefusal(recoveryRequired: false),
  );

  test(
    'clean refuses a recovery-required transaction',
    () => _expectCleanRefusal(recoveryRequired: true),
  );

  test(
    'clean refuses a committed transaction that still owns rollback',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final source = File(p.join(project.path, 'lib', 'committed.dart'));
        source.parent.createSync(recursive: true);
        source.writeAsStringSync('void original() {}\n');
        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'committed-run',
          verificationPolicyHash: 'test-policy',
        );
        await manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          round: 1,
          componentId: 'component-1',
          findingIds: const ['finding-1'],
          caseIds: const ['case-1'],
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          transactionId: 'transaction-1',
        );
        source.writeAsStringSync('void committedMutation() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-1',
        );
        await manager.recordTransactionApplied(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          caseIds: const ['case-1'],
        );
        await manager.verifyTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          policyHash: 'test-policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        );
        await manager.commitTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
        );

        final result = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'committed-run',
        ]);

        expect(result.exitCode, 1);
        expect(result.stderr, contains('unrolled transactions'));
        expect(quarantine.existsSync(), isTrue);
        expect(source.readAsStringSync(), 'void committedMutation() {}\n');
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'clean accepts a failed case after verified transaction rollback',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'quarantine_command_test_',
      );
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: quarantine_test\n');
        final source = File(p.join(project.path, 'lib', 'restored.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        source.writeAsStringSync(original);
        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'verified-rollback',
          verificationPolicyHash: 'test-policy',
        );
        await manager.beginTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          round: 1,
          componentId: 'component-1',
          findingIds: const ['finding-1'],
          caseIds: const ['case-1'],
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          findingId: 'finding-1',
          file: source,
          operationType: QuarantineOperationType.declaration,
          transactionId: 'transaction-1',
        );
        source.writeAsStringSync('void partialMutation() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-1',
        );
        await manager.rollbackCase(
          quarantineDir: quarantine,
          caseId: 'case-1',
          reason: 'injected apply failure',
          failed: true,
        );
        await manager.rollbackTransaction(
          quarantineDir: quarantine,
          transactionId: 'transaction-1',
          reason: 'restored verification baseline',
          policyHash: 'test-policy',
          requiredStepIds: const ['analyze'],
          observedStepIds: const ['analyze'],
        );

        final result = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'verified-rollback',
        ]);

        expect(result.exitCode, 0);
        expect(source.readAsStringSync(), original);
        expect(quarantine.existsSync(), isFalse);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );
}

Future<void> _expectCleanRefusal({required bool recoveryRequired}) async {
  final project = Directory.systemTemp.createTempSync(
    'quarantine_command_test_',
  );
  try {
    File(
      p.join(project.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: quarantine_test\n');
    final manager = QuarantineManager(project);
    final suffix = recoveryRequired ? 'recovery' : 'pending';
    final runId = '$suffix-run';
    final caseId = '$suffix-case';
    final transactionId = '$suffix-transaction';
    final source = File(p.join(project.path, 'lib', '$suffix.dart'));
    source.parent.createSync(recursive: true);
    source.writeAsStringSync('void $suffix() {}\n');
    final quarantine = await manager.createCaseQuarantine(
      runId: runId,
      verificationPolicyHash: 'test-policy',
    );
    await manager.beginTransaction(
      quarantineDir: quarantine,
      transactionId: transactionId,
      round: 1,
      componentId: suffix,
      findingIds: ['$suffix-finding'],
      caseIds: [caseId],
    );
    await manager.beginCase(
      quarantineDir: quarantine,
      caseId: caseId,
      findingId: '$suffix-finding',
      file: source,
      operationType: QuarantineOperationType.declaration,
      transactionId: transactionId,
    );
    if (recoveryRequired) {
      await manager.requireTransactionRecovery(
        quarantineDir: quarantine,
        transactionId: transactionId,
        reason: 'injected interruption',
      );
    }

    final result = await Process.run(Platform.resolvedExecutable, [
      p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
      'quarantine',
      'clean',
      '--project',
      project.path,
      runId,
    ]);

    expect(result.exitCode, 1, reason: suffix);
    expect(result.stderr, contains('active, recovery-required, or unrolled'));
    expect(quarantine.existsSync(), isTrue);
  } finally {
    if (project.existsSync()) project.deleteSync(recursive: true);
  }
}
