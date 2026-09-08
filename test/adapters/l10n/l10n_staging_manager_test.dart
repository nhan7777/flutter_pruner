import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_staging_manager.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('L10nStagingManager', () {
    late Directory tempDir;
    late Directory quarantineDir;
    late ProjectContext project;
    late L10nStagingManager stagingManager;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('staging_test_');
      quarantineDir = Directory(p.join(tempDir.path, 'quarantine'));
      await quarantineDir.create();

      // Load test fixture
      project = await ProjectContext.load(
        Directory(p.absolute('test/fixtures/l10n_test')),
      );
      stagingManager = const L10nStagingManager();
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('createStaging creates staging directory', () async {
      final staging = await stagingManager.createStaging(quarantineDir);

      expect(staging.existsSync(), isTrue);
      expect(staging.path, endsWith('quarantine/staging'));
    });

    test('createStaging throws if staging already exists', () async {
      await stagingManager.createStaging(quarantineDir);

      expect(
        () => stagingManager.createStaging(quarantineDir),
        throwsA(isA<L10nStagingException>()),
      );
    });

    test('materialize copies l10n.yaml', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      expect(configResult, isA<L10nConfigValid>());
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final stagingConfig = File(p.join(staging.path, 'l10n.yaml'));
      expect(stagingConfig.existsSync(), isTrue);

      final originalConfig = File(p.join(project.root.path, 'l10n.yaml'));
      expect(
        stagingConfig.readAsStringSync(),
        equals(originalConfig.readAsStringSync()),
      );
    });

    test('materialize copies pubspec.yaml', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final stagingPubspec = File(p.join(staging.path, 'pubspec.yaml'));
      expect(stagingPubspec.existsSync(), isTrue);
    });

    test('materialize copies ARB files', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final stagingArbDir = Directory(
        p.join(staging.path, project.relative(config.arbDir)),
      );
      expect(stagingArbDir.existsSync(), isTrue);

      final arbFiles = stagingArbDir
          .listSync()
          .whereType<File>()
          .where((f) => p.extension(f.path) == '.arb')
          .toList();

      expect(arbFiles, isNotEmpty);
      expect(arbFiles.any((f) => p.basename(f.path) == 'app_en.arb'), isTrue);
    });

    test('materialize throws if l10n.yaml not found', () async {
      final staging = await stagingManager.createStaging(quarantineDir);

      // Create empty project directory
      final emptyProjectDir = Directory(p.join(tempDir.path, 'empty'));
      await emptyProjectDir.create();

      // Create minimal pubspec.yaml
      final pubspec = File(p.join(emptyProjectDir.path, 'pubspec.yaml'));
      await pubspec.writeAsString('name: empty\n');

      final emptyProject = await ProjectContext.load(emptyProjectDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      expect(
        () => stagingManager.materialize(
          staging: staging,
          project: emptyProject,
          config: config,
        ),
        throwsA(isA<L10nStagingException>()),
      );
    });

    test('mutateArbFiles removes specified keys', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      // Create key to remove
      final keyToRemove = ArbKey(
        key: 'welcome',
        nodeId: 'l10n:l10n_test.welcome',
        origin: Uri.file('lib/l10n/app_en.arb'),
        location: 'lib/l10n/app_en.arb',
        memberKind: ArbGeneratedMemberKind.getter,
        missingLocales: '',
      );

      await stagingManager.mutateArbFiles(
        staging: staging,
        project: project,
        config: config,
        keysToRemove: [keyToRemove],
      );

      // Verify key removed in staging
      final stagingArbPath = p.join(
        staging.path,
        project.relative(config.arbDir),
        'app_en.arb',
      );
      final arbFile = File(stagingArbPath);
      final content = arbFile.readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;

      expect(decoded.containsKey('welcome'), isFalse);
      expect(decoded.containsKey('@welcome'), isFalse);
    });

    test('mutateArbFiles removes metadata companions', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final keyToRemove = ArbKey(
        key: 'welcome',
        nodeId: 'l10n:l10n_test.welcome',
        origin: Uri.file('lib/l10n/app_en.arb'),
        location: 'lib/l10n/app_en.arb',
        memberKind: ArbGeneratedMemberKind.getter,
        missingLocales: '',
      );

      await stagingManager.mutateArbFiles(
        staging: staging,
        project: project,
        config: config,
        keysToRemove: [keyToRemove],
      );

      final stagingArbPath = p.join(
        staging.path,
        project.relative(config.arbDir),
        'app_en.arb',
      );
      final arbFile = File(stagingArbPath);
      final decoded =
          jsonDecode(arbFile.readAsStringSync()) as Map<String, dynamic>;

      expect(decoded.containsKey('@welcome'), isFalse);
    });

    test('mutateArbFiles handles multiple keys from same file', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final keysToRemove = [
        ArbKey(
          key: 'welcome',
          nodeId: 'l10n:l10n_test.welcome',
          origin: Uri.file('lib/l10n/app_en.arb'),
          location: 'lib/l10n/app_en.arb',
          memberKind: ArbGeneratedMemberKind.getter,
          missingLocales: '',
        ),
        ArbKey(
          key: 'goodbye',
          nodeId: 'l10n:l10n_test.goodbye',
          origin: Uri.file('lib/l10n/app_en.arb'),
          location: 'lib/l10n/app_en.arb',
          memberKind: ArbGeneratedMemberKind.getter,
          missingLocales: '',
        ),
      ];

      await stagingManager.mutateArbFiles(
        staging: staging,
        project: project,
        config: config,
        keysToRemove: keysToRemove,
      );

      final stagingArbPath = p.join(
        staging.path,
        project.relative(config.arbDir),
        'app_en.arb',
      );
      final arbFile = File(stagingArbPath);
      final decoded =
          jsonDecode(arbFile.readAsStringSync()) as Map<String, dynamic>;

      expect(decoded.containsKey('welcome'), isFalse);
      expect(decoded.containsKey('goodbye'), isFalse);
    });

    test('runGenL10nInStaging executes flutter gen-l10n', () async {
      // Skip: gen-l10n requires full Flutter environment in staging
      // This will be tested in integration tests with proper setup
    }, skip: true);

    test('runGenL10nInStaging executes flutter gen-l10n (mock)', () async {
      // Verify method exists and returns proper result type
      final staging = await stagingManager.createStaging(quarantineDir);

      // Create minimal staging structure
      await File(p.join(staging.path, 'l10n.yaml')).writeAsString('');

      final result = await stagingManager.runGenL10nInStaging(staging: staging);

      // Should fail due to invalid config, but proves method works
      expect(result, isA<GenL10nFailure>());
      expect((result as GenL10nFailure).exitCode, isNot(0));
    });

    test('runGenL10nInStaging returns failure on invalid config', () async {
      final staging = await stagingManager.createStaging(quarantineDir);

      // Create invalid staging (no l10n.yaml)
      final invalidConfig = File(p.join(staging.path, 'l10n.yaml'));
      await invalidConfig.writeAsString('invalid: yaml: content:');

      final result = await stagingManager.runGenL10nInStaging(staging: staging);

      expect(result, isA<GenL10nFailure>());
      final failure = result as GenL10nFailure;
      expect(failure.exitCode, isNot(0));
    });

    test('inspect finds generated files', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final genResult = await stagingManager.runGenL10nInStaging(
        staging: staging,
      );
      expect(genResult, isA<GenL10nSuccess>());

      final inspection = await stagingManager.inspect(
        staging: staging,
        project: project,
        config: config,
      );

      expect(inspection.candidates, isNotEmpty);
      expect(
        inspection.candidates.any((c) => c.relativePath.endsWith('.dart')),
        isTrue,
      );
    });

    test('inspect finds generated files (mock)', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      // Create mock generated output
      final outputDir = Directory(
        p.join(staging.path, project.relative(config.outputDir)),
      );
      await outputDir.create(recursive: true);

      final mockGenerated = File(
        p.join(outputDir.path, 'app_localizations.dart'),
      );
      await mockGenerated.writeAsString('// Mock generated file');

      final inspection = await stagingManager.inspect(
        staging: staging,
        project: project,
        config: config,
      );

      expect(inspection.candidates, isNotEmpty);
      expect(
        inspection.candidates.any((c) => c.relativePath.endsWith('.dart')),
        isTrue,
      );
    });

    test('inspect computes sha256 hashes', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: config,
      );

      final genResult = await stagingManager.runGenL10nInStaging(
        staging: staging,
      );
      expect(genResult, isA<GenL10nSuccess>());

      final inspection = await stagingManager.inspect(
        staging: staging,
        project: project,
        config: config,
      );

      for (final candidate in inspection.candidates) {
        expect(candidate.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(candidate.sizeBytes, greaterThan(0));
      }
    });

    test('inspect computes sha256 hashes (mock)', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      final configResult = L10nConfig.load(project);
      final config = (configResult as L10nConfigValid).config;

      // Create mock generated output
      final outputDir = Directory(
        p.join(staging.path, project.relative(config.outputDir)),
      );
      await outputDir.create(recursive: true);

      final mockGenerated = File(
        p.join(outputDir.path, 'app_localizations.dart'),
      );
      await mockGenerated.writeAsString('// Mock generated file');

      final inspection = await stagingManager.inspect(
        staging: staging,
        project: project,
        config: config,
      );

      for (final candidate in inspection.candidates) {
        expect(candidate.sha256, matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(candidate.sizeBytes, greaterThan(0));
      }
    });

    test('cleanupStaging removes staging directory', () async {
      final staging = await stagingManager.createStaging(quarantineDir);
      expect(staging.existsSync(), isTrue);

      await stagingManager.cleanupStaging(staging);

      expect(staging.existsSync(), isFalse);
    });

    test('cleanupStaging succeeds when staging does not exist', () async {
      final staging = Directory(p.join(quarantineDir.path, 'staging'));
      expect(staging.existsSync(), isFalse);

      await stagingManager.cleanupStaging(staging);

      expect(staging.existsSync(), isFalse);
    });
  });
}
