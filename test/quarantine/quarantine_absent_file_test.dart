import 'dart:io';

import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late Directory project;
  late QuarantineManager manager;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('quarantine-absent-test-');
    project = Directory(p.join(scratch.path, 'project'));
    project.createSync(recursive: true);
    manager = QuarantineManager(project);
  });

  tearDown(() {
    if (scratch.existsSync()) {
      scratch.deleteSync(recursive: true);
    }
  });

  group('QuarantineManager absent file support', () {
    test('beginAbsentCase journals absent file with empty hash', () async {
      final quarantineDir = await manager.createQuarantine(
        runId: 'test-run',
        entries: [],
        transactionJournal: true,
      );

      final transaction = await manager.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        round: 1,
        componentId: 'l10n',
        findingIds: ['finding-1'],
        caseIds: ['case-1'],
      );

      expect(transaction.transactionId, equals('txn-1'));

      final absentCase = await manager.beginAbsentCase(
        quarantineDir: quarantineDir,
        caseId: 'case-1',
        findingId: 'finding-1',
        relativePath: 'lib/generated/l10n.dart',
        operationType: QuarantineOperationType.file,
        transactionId: 'txn-1',
      );

      expect(absentCase.caseId, equals('case-1'));
      expect(absentCase.entry.wasAbsentBeforeTransaction, isTrue);
      expect(
        absentCase.entry.sha256,
        equals(
          'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        ),
      );
      expect(absentCase.entry.sizeBytes, equals(0));
      expect(absentCase.status, equals(QuarantineCaseStatus.backedUp));
    });

    test('beginAbsentCase rejects existing file', () async {
      final existingFile = File(p.join(project.path, 'lib/existing.dart'));
      existingFile.createSync(recursive: true);
      existingFile.writeAsStringSync('content');

      final quarantineDir = await manager.createQuarantine(
        runId: 'test-run',
        entries: [],
        transactionJournal: true,
      );

      await manager.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        round: 1,
        componentId: 'l10n',
        findingIds: ['finding-1'],
        caseIds: ['case-1'],
      );

      expect(
        () => manager.beginAbsentCase(
          quarantineDir: quarantineDir,
          caseId: 'case-1',
          findingId: 'finding-1',
          relativePath: 'lib/existing.dart',
          operationType: QuarantineOperationType.file,
          transactionId: 'txn-1',
        ),
        throwsA(
          isA<QuarantineException>().having(
            (e) => e.toString(),
            'message',
            contains('Cannot journal absent case for existing file'),
          ),
        ),
      );
    });

    test('beginAbsentCase requires V3 transaction journal', () async {
      final quarantineDir = await manager.createQuarantine(
        runId: 'test-run',
        entries: [],
        transactionJournal: false,
      );

      expect(
        () => manager.beginAbsentCase(
          quarantineDir: quarantineDir,
          caseId: 'case-1',
          findingId: 'finding-1',
          relativePath: 'lib/generated/l10n.dart',
          operationType: QuarantineOperationType.file,
          transactionId: 'txn-1',
        ),
        throwsA(
          isA<QuarantineException>().having(
            (e) => e.toString(),
            'message',
            contains('Absent case journaling requires V3 transaction journal'),
          ),
        ),
      );
    });

    test('rollbackCasesAtomically deletes absent-before file', () async {
      final quarantineDir = await manager.createQuarantine(
        runId: 'test-run',
        entries: [],
        transactionJournal: true,
      );

      await manager.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        round: 1,
        componentId: 'l10n',
        findingIds: ['finding-1'],
        caseIds: ['case-1'],
      );

      await manager.beginAbsentCase(
        quarantineDir: quarantineDir,
        caseId: 'case-1',
        findingId: 'finding-1',
        relativePath: 'lib/generated/l10n.dart',
        operationType: QuarantineOperationType.file,
        transactionId: 'txn-1',
      );

      // Simulate file creation during transaction
      final generatedFile = File(
        p.join(project.path, 'lib/generated/l10n.dart'),
      );
      generatedFile.createSync(recursive: true);
      generatedFile.writeAsStringSync('// Generated');

      // Record applied state with candidate hash
      await manager.recordCaseApplied(
        quarantineDir: quarantineDir,
        caseId: 'case-1',
      );

      // Mark transaction applied
      await manager.recordTransactionApplied(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        caseIds: ['case-1'],
      );

      expect(generatedFile.existsSync(), isTrue);

      // Rollback should delete the file
      await manager.rollbackCasesAtomically(
        quarantineDir: quarantineDir,
        caseIds: ['case-1'],
        reason: 'test rollback',
      );

      expect(generatedFile.existsSync(), isFalse);
    });

    test('rollbackCasesAtomically preserves existing files', () async {
      final existingFile = File(p.join(project.path, 'lib/existing.dart'));
      existingFile.createSync(recursive: true);
      existingFile.writeAsStringSync('original');

      final quarantineDir = await manager.createQuarantine(
        runId: 'test-run',
        entries: [],
        transactionJournal: true,
      );

      await manager.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        round: 1,
        componentId: 'l10n',
        findingIds: ['finding-1'],
        caseIds: ['case-1'],
      );

      await manager.beginCase(
        quarantineDir: quarantineDir,
        caseId: 'case-1',
        findingId: 'finding-1',
        file: existingFile,
        operationType: QuarantineOperationType.file,
        transactionId: 'txn-1',
      );

      existingFile.writeAsStringSync('modified');

      await manager.recordCaseApplied(
        quarantineDir: quarantineDir,
        caseId: 'case-1',
      );

      await manager.recordTransactionApplied(
        quarantineDir: quarantineDir,
        transactionId: 'txn-1',
        caseIds: ['case-1'],
      );

      await manager.rollbackCasesAtomically(
        quarantineDir: quarantineDir,
        caseIds: ['case-1'],
        reason: 'test rollback',
      );

      expect(existingFile.existsSync(), isTrue);
      expect(existingFile.readAsStringSync(), equals('original'));
    });

    test(
      'QuarantineEntry serialization preserves wasAbsentBeforeTransaction',
      () {
        final entry = QuarantineEntry(
          originalPath: '/project/lib/generated/l10n.dart',
          sha256:
              'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
          sizeBytes: 0,
          wasAbsentBeforeTransaction: true,
          operationType: QuarantineOperationType.file,
        );

        final json = entry.toJson();
        expect(json['wasAbsentBeforeTransaction'], isTrue);

        final deserialized = QuarantineEntry.fromJson(json);
        expect(deserialized.wasAbsentBeforeTransaction, isTrue);
        expect(deserialized.sha256, equals(entry.sha256));
        expect(deserialized.sizeBytes, equals(0));
      },
    );

    test('QuarantineEntry defaults wasAbsentBeforeTransaction to false', () {
      final entry = QuarantineEntry(
        originalPath: '/project/lib/existing.dart',
        sha256: 'abc123',
        sizeBytes: 100,
        operationType: QuarantineOperationType.file,
      );

      expect(entry.wasAbsentBeforeTransaction, isFalse);

      final json = entry.toJson();
      expect(json.containsKey('wasAbsentBeforeTransaction'), isFalse);

      final deserialized = QuarantineEntry.fromJson(json);
      expect(deserialized.wasAbsentBeforeTransaction, isFalse);
    });
  });
}
