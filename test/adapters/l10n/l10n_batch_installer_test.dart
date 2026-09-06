import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_installer.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

void main() {
  group('L10nBatchInstaller', () {
    late Directory tempDir;
    late ProjectContext project;
    late L10nBatchInstaller installer;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('installer_test_');

      // Create minimal pubspec.yaml for ProjectContext.load
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_project
environment:
  sdk: '>=3.0.0 <4.0.0'
''');

      project = await ProjectContext.load(tempDir);
      installer = L10nBatchInstaller();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('installs ARB and generated files', () async {
      final batch = _createTestBatch(arbBytes: [1, 2, 3], genBytes: [4, 5, 6]);

      final written = await installer.install(batch: batch, project: project);

      expect(written, hasLength(2));
      expect(written, contains('lib/l10n/app_en.arb'));
      expect(written, contains('lib/l10n/app_localizations.dart'));

      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');

      expect(arbFile.existsSync(), isTrue);
      expect(genFile.existsSync(), isTrue);
      expect(await arbFile.readAsBytes(), equals([1, 2, 3]));
      expect(await genFile.readAsBytes(), equals([4, 5, 6]));
    });

    test('creates parent directories if missing', () async {
      final batch = _createTestBatch(
        arbPath: 'deep/nested/path/app_en.arb',
        arbBytes: [1, 2, 3],
        genBytes: [4, 5, 6],
      );

      await installer.install(batch: batch, project: project);

      final arbFile = File('${tempDir.path}/deep/nested/path/app_en.arb');
      expect(arbFile.existsSync(), isTrue);
      expect(await arbFile.readAsBytes(), equals([1, 2, 3]));
    });

    test('overwrites existing files', () async {
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.create(recursive: true);
      await arbFile.writeAsBytes([99, 99, 99]);

      final batch = _createTestBatch(arbBytes: [1, 2, 3], genBytes: [4, 5, 6]);

      await installer.install(batch: batch, project: project);

      expect(await arbFile.readAsBytes(), equals([1, 2, 3]));
    });

    test('rejects absolute paths', () async {
      final batch = _createTestBatch(
        arbPath: '/etc/passwd',
        arbBytes: [1, 2, 3],
        genBytes: [4, 5, 6],
      );

      expect(
        () => installer.install(batch: batch, project: project),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects paths with traversal', () async {
      final batch = _createTestBatch(
        arbPath: '../../../etc/passwd',
        arbBytes: [1, 2, 3],
        genBytes: [4, 5, 6],
      );

      expect(
        () => installer.install(batch: batch, project: project),
        throwsA(isA<InstallationFailure>()),
      );
    });

    test('throws InstallationFailure with partial paths on error', () async {
      // Create a scenario where write will fail after first file succeeds
      final batch = _createTestBatch(arbBytes: [1, 2, 3], genBytes: [4, 5, 6]);

      // Make ARB directory writable but generated directory fail
      // by creating generated file path as a directory that can't be overwritten
      final arbDir = Directory('${tempDir.path}/lib/l10n');
      await arbDir.create(recursive: true);

      final genFile = File('${tempDir.path}/lib/l10n/app_localizations.dart');
      final blocker = Directory(genFile.path);
      await blocker.create(recursive: true);
      // Make it read-only on Unix to force write failure
      if (Platform.isLinux || Platform.isMacOS) {
        await Process.run('chmod', ['444', blocker.path]);
      }

      try {
        await installer.install(batch: batch, project: project);
        fail('Should have thrown InstallationFailure');
      } on InstallationFailure catch (e) {
        // ARB file should have been written before gen file failed
        expect(e.partiallyWrittenPaths, contains('lib/l10n/app_en.arb'));
        expect(e.message, contains('Failed to install batch'));
      }
    });

    test('validates batch before installing', () async {
      final batch = _createInvalidBatch();

      expect(
        () => installer.install(batch: batch, project: project),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}

L10nRemovalBatch _createTestBatch({
  String arbPath = 'lib/l10n/app_en.arb',
  required List<int> arbBytes,
  required List<int> genBytes,
}) {
  final selection = L10nMutationSelection(
    requestedFindingIds: {'l10n:test.key1'},
    effectiveFindingIds: {'l10n:test.key1'},
    findingIdToKey: {'l10n:test.key1': 'key1'},
  );

  return L10nRemovalBatch(
    familyId: 'test-family',
    selection: selection,
    arbMutations: [
      L10nArbMutation(
        relativePath: arbPath,
        originalBytes: ImmutableBytes.copyOf([0]),
        originalHash: 'baseline-hash',
        candidateBytes: ImmutableBytes.copyOf(arbBytes),
        candidateHash: 'candidate-hash',
        mode: 420, // 0o644
      ),
    ],
    generatedOutputMutations: [
      L10nGeneratedOutputMutation(
        relativePath: 'lib/l10n/app_localizations.dart',
        originalBytes: ImmutableBytes.copyOf([0]),
        originalHash: 'baseline-gen-hash',
        candidateBytes: ImmutableBytes.copyOf(genBytes),
        candidateHash: 'candidate-gen-hash',
        mode: 420, // 0o644
      ),
    ],
    configurationFingerprint: 'config-fp',
    packageResolutionFingerprint: 'pkg-fp',
    toolchainFingerprint: 'tool-fp',
    footprint: MutationFootprint(
      familyId: 'test-family',
      findingIds: {'l10n:test.key1'},
      physicalPaths: {arbPath, 'lib/l10n/app_localizations.dart'},
      riskScope: ActionRiskScope.boundedFamily,
    ),
  );
}

L10nRemovalBatch _createInvalidBatch() {
  final selection = L10nMutationSelection(
    requestedFindingIds: {'l10n:test.key1'},
    effectiveFindingIds: {'l10n:test.key1'},
    findingIdToKey: {'l10n:test.key1': 'key1'},
  );

  // Invalid: empty arbMutations
  return L10nRemovalBatch(
    familyId: 'test-family',
    selection: selection,
    arbMutations: [], // Invalid!
    generatedOutputMutations: [],
    configurationFingerprint: 'config-fp',
    packageResolutionFingerprint: 'pkg-fp',
    toolchainFingerprint: 'tool-fp',
    footprint: MutationFootprint(
      familyId: 'test-family',
      findingIds: {'l10n:test.key1'},
      physicalPaths: {'lib/l10n/app_en.arb'},
      riskScope: ActionRiskScope.boundedFamily,
    ),
  );
}
