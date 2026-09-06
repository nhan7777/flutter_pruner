import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_expectation.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

void main() {
  group('L10nBatchVerifier', () {
    late Directory tempDir;
    late ProjectContext project;
    late L10nBatchVerifier verifier;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('verifier_test_');

      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_project
environment:
  sdk: '>=3.0.0 <4.0.0'
''');

      project = await ProjectContext.load(tempDir);
      verifier = L10nBatchVerifier();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('succeeds when all files match expectations', () async {
      // Create files with expected content
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.create(recursive: true);
      await arbFile.writeAsBytes([1, 2, 3]);

      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      await genFile.create(recursive: true);
      await genFile.writeAsBytes([4, 5, 6]);

      final expectation = _createExpectation(
        arbHash:
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
        genHash:
            '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
      );

      final result = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(result, isA<VerificationSuccess>());
      final success = result as VerificationSuccess;
      expect(success.verifiedPaths, hasLength(2));
    });

    test('fails when file hash does not match', () async {
      // Create ARB with wrong content
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.create(recursive: true);
      await arbFile.writeAsBytes([99, 99, 99]); // Wrong bytes

      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      await genFile.create(recursive: true);
      await genFile.writeAsBytes([4, 5, 6]);

      final expectation = _createExpectation(
        arbHash:
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
        genHash:
            '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
      );

      final result = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(result, isA<VerificationFailed>());
      final failed = result as VerificationFailed;
      expect(failed.mismatches, hasLength(1));
      expect(failed.mismatches.first.path, 'lib/l10n/app_en.arb');
      expect(failed.mismatches.first.role, FileRole.arb);
    });

    test('fails when expected file is absent', () async {
      // Create only generated file, skip ARB
      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      await genFile.create(recursive: true);
      await genFile.writeAsBytes([4, 5, 6]);

      final expectation = _createExpectation(
        arbHash:
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
        genHash:
            '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
      );

      final result = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(result, isA<VerificationFailed>());
      final failed = result as VerificationFailed;
      expect(failed.mismatches, hasLength(1));
      expect(failed.mismatches.first.path, 'lib/l10n/app_en.arb');
      expect(failed.mismatches.first.observed, 'FILE_ABSENT');
    });

    test('succeeds when absent file was expected to be absent', () async {
      // Don't create ARB file
      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      await genFile.create(recursive: true);
      await genFile.writeAsBytes([4, 5, 6]);

      final expectation = _createExpectation(
        arbHash: '',
        arbWasAbsent: true,
        genHash:
            '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
      );

      final result = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(result, isA<VerificationSuccess>());
    });

    test('fails when multiple files mismatch', () async {
      // Create both files with wrong content
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.create(recursive: true);
      await arbFile.writeAsBytes([99, 99, 99]);

      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      await genFile.create(recursive: true);
      await genFile.writeAsBytes([88, 88, 88]);

      final expectation = _createExpectation(
        arbHash:
            '039058c6f2c0cb492c533b0a4d14ef77cc0f78abccced5287d84a1a2011cfb81',
        genHash:
            '787c798e39a5bc1910355bae6d0cd87a36b2e10fd0202a83e3bb6b005da83472',
      );

      final result = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(result, isA<VerificationFailed>());
      final failed = result as VerificationFailed;
      expect(failed.mismatches, hasLength(2));
    });

    test('validates expectation before verifying', () async {
      final invalidExpectation = L10nMutationExpectation(
        familyId: 'test-family',
        selectionFingerprint: 'sel-fp',
        configurationFingerprint: 'cfg-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        writeExpectations: [], // Invalid: empty
        generatedOutputInventory: [],
      );

      expect(
        () =>
            verifier.verify(expectation: invalidExpectation, project: project),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

L10nMutationExpectation _createExpectation({
  required String arbHash,
  bool arbWasAbsent = false,
  required String genHash,
}) {
  return L10nMutationExpectation(
    familyId: 'test-family',
    selectionFingerprint: 'sel-fp',
    configurationFingerprint: 'cfg-fp',
    packageResolutionFingerprint: 'pkg-fp',
    toolchainFingerprint: 'tool-fp',
    writeExpectations: [
      WriteExpectation(
        path: 'lib/l10n/app_en.arb',
        role: FileRole.arb,
        baselineHash: 'baseline-arb',
        candidateHash: arbHash,
        expectedMode: 420,
        wasAbsent: arbWasAbsent,
      ),
      WriteExpectation(
        path: 'lib/l10n/app_localizations.dart',
        role: FileRole.generated,
        baselineHash: 'baseline-gen',
        candidateHash: genHash,
        expectedMode: 420,
        wasAbsent: false,
      ),
    ],
    generatedOutputInventory: [
      GeneratedOutputEntry(
        path: 'lib/l10n/app_localizations.dart',
        expectedHash: genHash,
        sizeBytes: 3,
      ),
    ],
  );
}
