import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import '../../../benchmark/accuracy/l10n_mutation_readiness.dart';
import '../../../benchmark/accuracy/src/corpus_mutation_evidence.dart';
import '../../../benchmark/accuracy/src/l10n_mutation_manifest.dart';
import '../../../benchmark/accuracy/src/l10n_readiness_negative_fixtures.dart';
import '../../../benchmark/accuracy/src/l10n_readiness_production.dart';

const _sha = '0000000000000000000000000000000000000000000000000000000000000000';
const _gitSha = '0000000000000000000000000000000000000000';
const _productionManifestSha =
    '6c64080eb30fd59ad55db439ddaf17cc8340785828df31a53d0433669032387a';

void main() {
  group('production scanner', () {
    test(
      'binds the exact analysis snapshot and maps oracle identities',
      () async {
        final fixture = await _copyFixture();
        addTearDown(() => fixture.delete(recursive: true));
        final project = await ProjectContext.load(fixture);
        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'l10n'},
        ).analyze();
        final view = _productionView(
          project: project,
          manifest: _projectManifest(),
        );
        var analysisRuns = 0;
        final scanner = ProductionL10nHarnessScanner.testing(
          analyze: (_) async {
            analysisRuns++;
            return snapshot;
          },
        );
        final findingIds = snapshot.findings
            .map((finding) => finding.node.id)
            .toSet();
        final cases = snapshot.graph
            .nodesOfKind(NodeKind.localizationKey)
            .map(
              (node) => L10nReadinessOracleCase(
                caseId: 'alpha:l10n:${node.metadata['key']}',
                projectId: 'alpha',
                decodedKey: node.metadata['key']! as String,
                mutationPositive: findingIds.contains(node.id),
                expectedScannerPresence: findingIds.contains(node.id),
              ),
            )
            .toList(growable: false);

        final result = await scanner.scan(view, cases);

        expect(analysisRuns, 1);
        expect(result.analysisAuthority, same(snapshot));
        expect(view.analysisSnapshot, same(snapshot));
        expect(result.actualNodeIdByOracleCaseId, hasLength(cases.length));
        expect(
          result.candidateOracleCaseIds,
          cases
              .where((entry) => entry.mutationPositive)
              .map((entry) => entry.caseId)
              .toSet(),
        );
        expect(result.publicSafeL10n, 0);
        expect(result.publicHighL10n, 0);
        expect(result.publicApplyEligibleL10n, 0);
        expect(result.publicProposedL10nActions, 0);
      },
    );
  });

  group('production evaluator', () {
    test('rejects a scan not backed by the view snapshot', () async {
      final fixture = await _copyFixture();
      addTearDown(() => fixture.delete(recursive: true));
      final project = await ProjectContext.load(fixture);
      final snapshot = await ProjectAnalyzer(
        project: project,
        only: const {'l10n'},
      ).analyze();
      final view = _productionView(
        project: project,
        manifest: _projectManifest(),
      );
      var pipelineCalls = 0;
      final evaluator = ProductionL10nEvidenceEvaluator.testing(
        evaluate: (_) async {
          pipelineCalls++;
          return _acceptedEvaluation(_packageChangeSet());
        },
        monotonicMicros: _clock([10, 20]),
      );
      const oracle = L10nReadinessOracleCase(
        caseId: 'alpha:l10n:welcome',
        projectId: 'alpha',
        decodedKey: 'welcome',
        mutationPositive: true,
        expectedScannerPresence: true,
      );
      final actualNode = snapshot.graph
          .nodesOfKind(NodeKind.localizationKey)
          .singleWhere((node) => node.metadata['key'] == 'welcome');
      final foreignScan = L10nStaticScanResult(
        authorityIdentity: _sha,
        analysisAuthority: Object(),
        actualNodeIdByOracleCaseId: {oracle.caseId: actualNode.id},
        candidateOracleCaseIds: {oracle.caseId},
        publicSafeL10n: 0,
        publicHighL10n: 0,
        publicApplyEligibleL10n: 0,
        publicProposedL10nActions: 0,
      );
      final ownedScan = L10nStaticScanResult(
        authorityIdentity: _sha,
        analysisAuthority: snapshot,
        actualNodeIdByOracleCaseId: {oracle.caseId: actualNode.id},
        candidateOracleCaseIds: {oracle.caseId},
        publicSafeL10n: 0,
        publicHighL10n: 0,
        publicApplyEligibleL10n: 0,
        publicProposedL10nActions: 0,
      );
      view.bindScanResult(snapshot, ownedScan);

      await expectLater(
        evaluator.evaluateIndividual(view, oracle, foreignScan),
        throwsStateError,
      );
      expect(pipelineCalls, 0);
    });

    test(
      'passes exact scanner node ids and retains only accepted change set',
      () async {
        final fixture = await _copyFixture();
        addTearDown(() => fixture.delete(recursive: true));
        final project = await ProjectContext.load(fixture);
        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'l10n'},
        ).analyze();
        final view = _productionView(
          project: project,
          manifest: _projectManifest(),
        );
        final changeSet = _packageChangeSet();
        L10nEvidenceRequest? captured;
        final evaluator = ProductionL10nEvidenceEvaluator.testing(
          evaluate: (request) async {
            captured = request;
            return _acceptedEvaluation(changeSet);
          },
          monotonicMicros: _clock([100, 145]),
        );
        const oracle = L10nReadinessOracleCase(
          caseId: 'alpha:l10n:welcome',
          projectId: 'alpha',
          decodedKey: 'welcome',
          mutationPositive: true,
          expectedScannerPresence: true,
        );
        final actualNode = snapshot.graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'welcome');
        final scan = L10nStaticScanResult(
          authorityIdentity: _sha,
          analysisAuthority: snapshot,
          actualNodeIdByOracleCaseId: {oracle.caseId: actualNode.id},
          candidateOracleCaseIds: {oracle.caseId},
          publicSafeL10n: 0,
          publicHighL10n: 0,
          publicApplyEligibleL10n: 0,
          publicProposedL10nActions: 0,
        );
        view.bindScanResult(snapshot, scan);

        final result = await evaluator.evaluateIndividual(view, oracle, scan);

        expect(captured!.analysis, same(snapshot));
        expect(captured!.selectedNodeIds, [actualNode.id]);
        expect(result.accepted, isTrue);
        expect(result.mutationAuthority, same(changeSet));
        expect(result.bytesCopied, 17);
        expect(result.baselineGeneratorMicros, 11);
        expect(result.candidateGeneratorMicros, 13);
        expect(result.stageMicros, 45);
        expect(result.sampledPeakRssBytes, 2048);
      },
    );

    test(
      'projects rejected verdict failures without raw process output',
      () async {
        final fixture = await _copyFixture();
        addTearDown(() => fixture.delete(recursive: true));
        final project = await ProjectContext.load(fixture);
        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'l10n'},
        ).analyze();
        final view = _productionView(
          project: project,
          manifest: _projectManifest(),
        );
        final evaluator = ProductionL10nEvidenceEvaluator.testing(
          evaluate: (_) async => _rejectedEvaluation(),
          monotonicMicros: _clock([100, 145]),
        );
        const oracle = L10nReadinessOracleCase(
          caseId: 'alpha:l10n:welcome',
          projectId: 'alpha',
          decodedKey: 'welcome',
          mutationPositive: true,
          expectedScannerPresence: true,
        );
        final actualNode = snapshot.graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'welcome');
        final scan = L10nStaticScanResult(
          authorityIdentity: _sha,
          analysisAuthority: snapshot,
          actualNodeIdByOracleCaseId: {oracle.caseId: actualNode.id},
          candidateOracleCaseIds: {oracle.caseId},
          publicSafeL10n: 0,
          publicHighL10n: 0,
          publicApplyEligibleL10n: 0,
          publicProposedL10nActions: 0,
        );
        view.bindScanResult(snapshot, scan);

        final result = await evaluator.evaluateIndividual(view, oracle, scan);

        expect(result.accepted, isFalse);
        expect(result.mutationAuthority, isNull);
        expect(result.verdictFailures.map((failure) => failure.toJson()), [
          {
            'code': 'scanBlockerPresent',
            'detailCode': 'selected-node-retained',
            'relativePath': 'lib/l10n/app_en.arb',
            'stage': 'family-preflight',
          },
        ]);
      },
    );
  });

  group('production corpus adapter', () {
    test(
      'rebases once and consumes an accepted view before execution',
      () async {
        final fixture = await _copyFixture(packageRoot: 'packages/app');
        addTearDown(() => fixture.parent.parent.delete(recursive: true));
        final project = await ProjectContext.load(fixture);
        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'l10n'},
        ).analyze();
        final manifest = _projectManifest(packageRoot: 'packages/app');
        final view = _productionView(project: project, manifest: manifest);
        final changeSet = _packageChangeSet();
        final evaluator = ProductionL10nEvidenceEvaluator.testing(
          evaluate: (_) async => _acceptedEvaluation(changeSet),
          monotonicMicros: _clock([0, 1]),
        );
        const oracle = L10nReadinessOracleCase(
          caseId: 'alpha:l10n:welcome',
          projectId: 'alpha',
          decodedKey: 'welcome',
          mutationPositive: true,
          expectedScannerPresence: true,
        );
        final actualNode = snapshot.graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'welcome');
        final scan = L10nStaticScanResult(
          authorityIdentity: _sha,
          analysisAuthority: snapshot,
          actualNodeIdByOracleCaseId: {oracle.caseId: actualNode.id},
          candidateOracleCaseIds: {oracle.caseId},
          publicSafeL10n: 0,
          publicHighL10n: 0,
          publicApplyEligibleL10n: 0,
          publicProposedL10nActions: 0,
        );
        view.bindScanResult(snapshot, scan);
        final verdict = await evaluator.evaluateIndividual(view, oracle, scan);
        final runner = _RecordingCorpusRunner();
        final adapter = ProductionL10nCorpusEvidenceRunner.testing(
          runner: runner,
          monotonicMicros: _clock([40, 90]),
        );

        final result = await adapter.run(view, oracle.caseId, verdict);

        expect(runner.changeSet!.arbReplacements.keys, [
          'packages/app/lib/l10n/app_en.arb',
        ]);
        expect(result.corpusPolicyPassed, isTrue);
        expect(result.restorationProven, isTrue);
        expect(result.policyMicros, 50);
        expect(result.sampledPeakRssBytes, 4096);
        await expectLater(
          adapter.run(view, oracle.caseId, verdict),
          throwsStateError,
        );
        expect(runner.calls, 1);
      },
    );
  });

  group('production negative fixtures', () {
    test('freezes the same fixture IDs and reasons as the manifest', () {
      final manifest = L10nMutationManifest.read(
        File('benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json'),
      );

      expect({
        for (final entry in productionL10nNegativeRecipes.entries)
          entry.key: [entry.value.observedReason],
      }, manifest.mutationNegativeReasons);
    });

    test(
      'executes one real frozen selector and parses exact test evidence',
      () async {
        final runner = ProductionL10nMutationNegativeFixtureRunner(
          repositoryRoot: Directory.current,
        );

        final result = await runner.run('pseudo-key-selection', const [
          'invalidSelection',
        ]);

        expect(result.rejected, isTrue);
        expect(result.observedReason, 'invalidSelection');
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'runs the frozen recipe once and returns bound rejection evidence',
      () async {
        final repository = await Directory.systemTemp.createTemp(
          'l10n-negative-recipe-',
        );
        addTearDown(() => repository.delete(recursive: true));
        final testFile = File(
          p.join(repository.path, 'test', 'recipe_test.dart'),
        );
        await testFile.parent.create(recursive: true);
        await testFile.writeAsString('void main() {}\n');
        final process = _RecordingProcessRunner(_successfulProcessResult());
        final runner = ProductionL10nMutationNegativeFixtureRunner.testing(
          repositoryRoot: repository,
          dartExecutable: '/sdk/bin/dart',
          processRunner: process,
          recipes: const {
            'malformed-arb': ProductionL10nNegativeRecipe(
              observedReason: 'arbParseFailure',
              testPath: 'test/recipe_test.dart',
              testName: 'rejects malformed ARB bytes',
            ),
          },
        );

        final result = await runner.run('malformed-arb', const [
          'arbParseFailure',
        ]);

        expect(result.rejected, isTrue);
        expect(result.observedReason, 'arbParseFailure');
        expect(result.evidenceIdentity, hasLength(64));
        expect(process.calls, 1);
        expect(process.executable, '/sdk/bin/dart');
        expect(process.arguments, [
          'test',
          'test/recipe_test.dart',
          '--name',
          'rejects malformed ARB bytes',
          '--reporter',
          'json',
        ]);
        await expectLater(
          runner.run('malformed-arb', const ['arbParseFailure']),
          throwsStateError,
        );
        expect(process.calls, 1);
      },
    );

    test(
      'fails closed before execution for foreign recipe authority',
      () async {
        final repository = await Directory.systemTemp.createTemp(
          'l10n-negative-authority-',
        );
        addTearDown(() => repository.delete(recursive: true));
        final testFile = File(
          p.join(repository.path, 'test', 'recipe_test.dart'),
        );
        await testFile.parent.create(recursive: true);
        await testFile.writeAsString('void main() {}\n');
        final process = _RecordingProcessRunner(_successfulProcessResult());
        final runner = ProductionL10nMutationNegativeFixtureRunner.testing(
          repositoryRoot: repository,
          dartExecutable: '/sdk/bin/dart',
          processRunner: process,
          recipes: const {
            'malformed-arb': ProductionL10nNegativeRecipe(
              observedReason: 'arbParseFailure',
              testPath: 'test/recipe_test.dart',
              testName: 'rejects malformed ARB bytes',
            ),
          },
        );

        await expectLater(
          runner.run('unknown', const ['arbParseFailure']),
          throwsStateError,
        );
        await expectLater(
          runner.run('malformed-arb', const ['invalidSelection']),
          throwsStateError,
        );
        expect(process.calls, 0);
      },
    );

    test('rejects recipe source drift across the process boundary', () async {
      final repository = await Directory.systemTemp.createTemp(
        'l10n-negative-drift-',
      );
      addTearDown(() => repository.delete(recursive: true));
      final testFile = File(
        p.join(repository.path, 'test', 'recipe_test.dart'),
      );
      await testFile.parent.create(recursive: true);
      await testFile.writeAsString('void main() {}\n');
      final process = _RecordingProcessRunner(
        _successfulProcessResult(),
        onRun: () => testFile.writeAsStringSync('void main() { throw 1; }\n'),
      );
      final runner = ProductionL10nMutationNegativeFixtureRunner.testing(
        repositoryRoot: repository,
        dartExecutable: '/sdk/bin/dart',
        processRunner: process,
        recipes: const {
          'malformed-arb': ProductionL10nNegativeRecipe(
            observedReason: 'arbParseFailure',
            testPath: 'test/recipe_test.dart',
            testName: 'rejects malformed ARB bytes',
          ),
        },
      );

      await expectLater(
        runner.run('malformed-arb', const ['arbParseFailure']),
        throwsStateError,
      );
      expect(process.calls, 1);
    });

    test(
      'does not accept a successful process that ran no recipe test',
      () async {
        final repository = await Directory.systemTemp.createTemp(
          'l10n-negative-empty-',
        );
        addTearDown(() => repository.delete(recursive: true));
        final testFile = File(
          p.join(repository.path, 'test', 'recipe_test.dart'),
        );
        await testFile.parent.create(recursive: true);
        await testFile.writeAsString('void main() {}\n');
        final runner = ProductionL10nMutationNegativeFixtureRunner.testing(
          repositoryRoot: repository,
          dartExecutable: '/sdk/bin/dart',
          processRunner: _RecordingProcessRunner(
            _emptySuccessfulProcessResult(),
          ),
          recipes: const {
            'malformed-arb': ProductionL10nNegativeRecipe(
              observedReason: 'arbParseFailure',
              testPath: 'test/recipe_test.dart',
              testName: 'rejects malformed ARB bytes',
            ),
          },
        );

        final result = await runner.run('malformed-arb', const [
          'arbParseFailure',
        ]);

        expect(result.rejected, isFalse);
      },
    );

    test(
      'does not accept a successful process that ran an extra recipe test',
      () async {
        final repository = await Directory.systemTemp.createTemp(
          'l10n-negative-extra-',
        );
        addTearDown(() => repository.delete(recursive: true));
        final testFile = File(
          p.join(repository.path, 'test', 'recipe_test.dart'),
        );
        await testFile.parent.create(recursive: true);
        await testFile.writeAsString('void main() {}\n');
        final runner = ProductionL10nMutationNegativeFixtureRunner.testing(
          repositoryRoot: repository,
          dartExecutable: '/sdk/bin/dart',
          processRunner: _RecordingProcessRunner(
            _successfulProcessResultWithExtraTest(),
          ),
          recipes: const {
            'malformed-arb': ProductionL10nNegativeRecipe(
              observedReason: 'arbParseFailure',
              testPath: 'test/recipe_test.dart',
              testName: 'rejects malformed ARB bytes',
            ),
          },
        );

        final result = await runner.run('malformed-arb', const [
          'arbParseFailure',
        ]);

        expect(result.rejected, isFalse);
      },
    );
  });

  group('production composition', () {
    test('loads the exact Smooth scanner coverage authority', () async {
      const config = '''version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android-google-play
      platform: android
      entrypoint: lib/entrypoints/android/main_google_play.dart
    - name: android-fdroid
      platform: android
      entrypoint: lib/entrypoints/android/main_fdroid.dart
    - name: ios-app-store
      platform: ios
      entrypoint: lib/entrypoints/ios/main_ios.dart
    - name: macos-app-store
      platform: macos
      entrypoint: lib/entrypoints/ios/main_ios.dart
  excluded_entrypoints:
    - path: lib/main.dart
      reason: launcher guard terminates and is not a supported launch target
    - path: lib/entrypoints/android/main_samsung_gallery.dart
      reason: tracked dormant stub throws and has no retained launch or release invocation
''';
      final createdRepository = await Directory.systemTemp.createTemp(
        'l10n-production-smooth-coverage-',
      );
      final repository = Directory(
        createdRepository.resolveSymbolicLinksSync(),
      );
      addTearDown(() => repository.delete(recursive: true));
      final packageRoot = await Directory(
        p.join(repository.path, 'packages', 'smooth_app'),
      ).create(recursive: true);
      await File(p.join(packageRoot.path, 'pubspec.yaml')).writeAsString(
        'name: smooth_coverage_fixture\nenvironment:\n  sdk: ^3.11.0\n',
      );
      for (final relativePath in const [
        'lib/entrypoints/android/main_google_play.dart',
        'lib/entrypoints/android/main_fdroid.dart',
        'lib/entrypoints/ios/main_ios.dart',
        'lib/main.dart',
        'lib/entrypoints/android/main_samsung_gallery.dart',
      ]) {
        final file = File(
          p.joinAll([packageRoot.path, ...p.posix.split(relativePath)]),
        );
        await file.parent.create(recursive: true);
        await file.writeAsString('void main() {}\n', flush: true);
      }
      await File(
        p.join(packageRoot.path, 'flutter_pruner_v2_accuracy.yaml'),
      ).writeAsString(config, flush: true);
      expect(
        sha256.convert(utf8.encode(config)).toString(),
        '9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527',
      );
      final manifest = L10nMutationManifest.read(
        File('benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json'),
      );
      final factory = ProductionL10nReadinessProjectViewFactory(
        manifest: manifest,
        retainedRepositoriesByProject: {'smooth': repository},
        sdkFlutterByVersion: {'3.44.9': File('/opt/flutter/bin/flutter')},
        viewFactory: _ReadyCorpusViewFactory(
          repository,
          packageRoot: packageRoot,
        ),
      );

      final view = await factory.provision('smooth');

      final targets = view.project.targets;
      expect(
        targets
            .map(
              (target) => (
                name: target.name,
                platform: target.platform,
                entrypoint: target.entrypoint,
              ),
            )
            .toList(growable: false),
        const [
          (
            name: 'android-google-play',
            platform: 'android',
            entrypoint: 'lib/entrypoints/android/main_google_play.dart',
          ),
          (
            name: 'android-fdroid',
            platform: 'android',
            entrypoint: 'lib/entrypoints/android/main_fdroid.dart',
          ),
          (
            name: 'ios-app-store',
            platform: 'ios',
            entrypoint: 'lib/entrypoints/ios/main_ios.dart',
          ),
          (
            name: 'macos-app-store',
            platform: 'macos',
            entrypoint: 'lib/entrypoints/ios/main_ios.dart',
          ),
        ],
      );
      expect(targets.every((target) => target.flavor == null), isTrue);
      expect(targets.every((target) => target.dartDefines.isEmpty), isTrue);
      expect(view.project.targetMatrix.excludedEntrypoints, const [
        ExcludedApplicationEntrypoint(
          path: 'lib/main.dart',
          reason:
              'launcher guard terminates and is not a supported launch target',
        ),
        ExcludedApplicationEntrypoint(
          path: 'lib/entrypoints/android/main_samsung_gallery.dart',
          reason:
              'tracked dormant stub throws and has no retained launch or release invocation',
        ),
      ]);
      expect(view.project.analysisCoverageComplete, isTrue);
    });

    test('loads the manifest-bound scanner coverage configuration', () async {
      const config = '''version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android-default
      platform: android
      entrypoint: lib/main.dart
    - name: ios-default
      platform: ios
      entrypoint: lib/main.dart
    - name: linux-default
      platform: linux
      entrypoint: lib/main.dart
    - name: macos-default
      platform: macos
      entrypoint: lib/main.dart
    - name: web-default
      platform: web
      entrypoint: lib/main.dart
    - name: widgetbook
      platform: macos
      entrypoint: lib/main.widgetbook.dart
    - name: script-convert-arb-keys
      platform: linux
      entrypoint: scripts/convert_arb_keys.dart
    - name: script-setup-env
      platform: linux
      entrypoint: scripts/setup_env.dart
    - name: test-driver-android
      platform: android
      entrypoint: test_driver/main.dart
    - name: test-driver-ios
      platform: ios
      entrypoint: test_driver/main.dart
    - name: test-driver-linux
      platform: linux
      entrypoint: test_driver/main.dart
    - name: test-driver-macos
      platform: macos
      entrypoint: test_driver/main.dart
    - name: test-driver-web
      platform: web
      entrypoint: test_driver/main.dart
''';
      final createdRepository = await Directory.systemTemp.createTemp(
        'l10n-production-coverage-',
      );
      final repository = Directory(
        createdRepository.resolveSymbolicLinksSync(),
      );
      addTearDown(() => repository.delete(recursive: true));
      await File(
        p.join(repository.path, 'pubspec.yaml'),
      ).writeAsString('name: coverage_fixture\nenvironment:\n  sdk: ^3.11.0\n');
      await Directory(p.join(repository.path, 'lib')).create();
      await File(
        p.join(repository.path, 'lib', 'main.dart'),
      ).writeAsString('void main() {}\n', flush: true);
      await File(
        p.join(repository.path, 'lib', 'main.widgetbook.dart'),
      ).writeAsString('void main() {}\n', flush: true);
      await Directory(p.join(repository.path, 'scripts')).create();
      await File(
        p.join(repository.path, 'scripts', 'convert_arb_keys.dart'),
      ).writeAsString('void main() {}\n', flush: true);
      await File(
        p.join(repository.path, 'scripts', 'setup_env.dart'),
      ).writeAsString('void main() {}\n', flush: true);
      await Directory(p.join(repository.path, 'test_driver')).create();
      await File(
        p.join(repository.path, 'test_driver', 'main.dart'),
      ).writeAsString('void main() {}\n', flush: true);
      await File(
        p.join(repository.path, 'flutter_pruner_v2_accuracy.yaml'),
      ).writeAsString(config);
      expect(
        sha256.convert(utf8.encode(config)).toString(),
        '4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05',
      );
      final manifest = L10nMutationManifest.read(
        File('benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json'),
      );
      final factory = ProductionL10nReadinessProjectViewFactory(
        manifest: manifest,
        retainedRepositoriesByProject: {'gitjournal': repository},
        sdkFlutterByVersion: {'3.41.5': File('/opt/flutter/bin/flutter')},
        viewFactory: _ReadyCorpusViewFactory(repository),
      );

      final view = await factory.provision('gitjournal');

      expect(view.project.targets.map((target) => target.name), [
        'android-default',
        'ios-default',
        'linux-default',
        'macos-default',
        'web-default',
        'widgetbook',
        'script-convert-arb-keys',
        'script-setup-env',
        'test-driver-android',
        'test-driver-ios',
        'test-driver-linux',
        'test-driver-macos',
        'test-driver-web',
      ]);
      expect(view.project.analysisCoverageComplete, isTrue);
    });

    test('binds probed authorities into every production dependency', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'l10n-production-composition-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final options = _productionOptions(sandbox);
      final manifest = L10nMutationManifest.read(options.manifestFile);
      final retained = _retainedRepositories(options.corpusRoot);
      final identities = {
        'coverageSpecSha256': _sha,
        'implementationSha256': _sha,
        'manifestSha256': _productionManifestSha,
        'negativeRecipeMatrixSha256':
            productionL10nNegativeRecipeAuthorityIdentity(Directory.current),
        'policySetSha256': _sha,
        'repositorySetSha256': _sha,
        'sdkSetSha256': _sha,
      };
      final loader = _FakeAuthorityLoader(
        ProductionL10nAuthoritySnapshot(
          manifest: manifest,
          retainedRepositoriesByProject: retained,
          identities: identities,
        ),
      );

      final composition = await ProductionL10nReadinessComposition.create(
        options,
        authorityLoader: loader,
      );
      final plan = await composition.dependencies.loadPlan(options);

      expect(loader.calls, 1);
      expect(plan.profile, L10nReadinessProfile.productionStage1);
      expect(plan.identities, identities);
      expect(
        composition.dependencies.scanner,
        isA<ProductionL10nHarnessScanner>(),
      );
      expect(
        composition.dependencies.evaluatorFactory(),
        isA<ProductionL10nEvidenceEvaluator>(),
      );
      expect(
        composition.dependencies.corpusEvidenceRunner,
        isA<ProductionL10nCorpusEvidenceRunner>(),
      );
      expect(
        composition.dependencies.negativeFixtureRunner,
        isA<ProductionL10nMutationNegativeFixtureRunner>(),
      );
      expect(
        composition.dependencies.checkpointStore,
        isA<FileL10nReadinessCheckpointStore>(),
      );
    });

    test('rejects runtime argv drift before loading a plan', () async {
      final sandbox = await Directory.systemTemp.createTemp(
        'l10n-production-options-',
      );
      addTearDown(() => sandbox.delete(recursive: true));
      final options = _productionOptions(sandbox);
      final manifest = L10nMutationManifest.read(options.manifestFile);
      final composition = await ProductionL10nReadinessComposition.create(
        options,
        authorityLoader: _FakeAuthorityLoader(
          ProductionL10nAuthoritySnapshot(
            manifest: manifest,
            retainedRepositoriesByProject: _retainedRepositories(
              options.corpusRoot,
            ),
            identities: {
              'coverageSpecSha256': _sha,
              'implementationSha256': _sha,
              'manifestSha256': _productionManifestSha,
              'negativeRecipeMatrixSha256':
                  productionL10nNegativeRecipeAuthorityIdentity(
                    Directory.current,
                  ),
              'policySetSha256': _sha,
              'repositorySetSha256': _sha,
              'sdkSetSha256': _sha,
            },
          ),
        ),
      );
      final drifted = _productionOptions(sandbox, outputName: 'drifted.json');

      await expectLater(
        composition.dependencies.loadPlan(drifted),
        throwsStateError,
      );
    });

    test(
      'probes exact repository and SDK authorities into seven hashes',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'l10n-production-authorities-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final options = _productionOptions(sandbox);
        final process = _AuthorityProcessRunner();
        final loader = ProductionL10nAuthorityLoader.testing(
          processRunner: process,
          gitExecutable: '/usr/bin/git',
        );

        final snapshot = await loader.load(options);
        await loader.revalidateProject(options, snapshot, 'smooth');

        expect(snapshot.manifest.oracleVersion, 'l10n-mutation-readiness-v2');
        expect(snapshot.retainedRepositoriesByProject.keys.toSet(), {
          'gitjournal',
          'gsy',
          'smooth',
        });
        expect(snapshot.identities.keys.toSet(), {
          'coverageSpecSha256',
          'implementationSha256',
          'manifestSha256',
          'negativeRecipeMatrixSha256',
          'policySetSha256',
          'repositorySetSha256',
          'sdkSetSha256',
        });
        expect(
          snapshot.identities.values,
          everyElement(matches(RegExp(r'^[a-f0-9]{64}$'))),
        );
        expect(
          snapshot.identities['negativeRecipeMatrixSha256'],
          productionL10nNegativeRecipeAuthorityIdentity(Directory.current),
        );
        expect(process.gitHeadCalls, 4);
        expect(process.gitStatusCalls, 4);
        expect(process.flutterProbeCalls, 4);
      },
    );

    test(
      'returns invocation failure when authority composition fails',
      () async {
        final sandbox = await Directory.systemTemp.createTemp(
          'l10n-production-failure-',
        );
        addTearDown(() => sandbox.delete(recursive: true));
        final options = _productionOptions(sandbox);

        final result = await runProductionL10nMutationReadiness(
          _argvFor(options),
          authorityLoader: _ThrowingAuthorityLoader(),
        );

        expect(result, 2);
      },
    );
  });
}

ProductionL10nReadinessProjectView _productionView({
  required ProjectContext project,
  required L10nMutationProjectManifest manifest,
}) {
  final corpus = CorpusProjectView(
    repositoryRoot: _repositoryRoot(project.root, manifest.packageRootRelative),
    packageRoot: project.root,
    repositoryRevision: _gitSha,
    provisionedBaselineFingerprint: _sha,
    baselineGitStatusIdentity: _sha,
  );
  return ProductionL10nReadinessProjectView(
    projectId: 'alpha',
    manifest: manifest,
    corpusView: corpus,
    project: project,
    canonicalFlutterExecutable: '/opt/flutter/bin/flutter',
    sdkRegistry: L10nSdkRegistry({
      Version.parse('3.41.5'): '/opt/flutter/bin/flutter',
    }),
    toolchainSelection: const ProjectSelectorSelection(),
  );
}

L10nMutationProjectManifest _projectManifest({
  String packageRoot = '.',
  List<L10nFixtureOverlay> fixtureOverlays = const [],
}) {
  final prefix = packageRoot == '.' ? '' : '$packageRoot/';
  return L10nMutationProjectManifest(
    id: 'alpha',
    repositoryRevision: _gitSha,
    packageRootRelative: packageRoot,
    toolchainVersion: '3.41.5',
    verificationPolicy: [
      CorpusVerificationCommand(
        workingDirectoryRelativeToRepository: '.',
        argumentsAfterCanonicalFlutter: const ['analyze', '--no-pub'],
      ),
    ],
    arbDirectoryRelative: '${prefix}lib/l10n',
    templateArbPathRelative: '${prefix}lib/l10n/app_en.arb',
    arbPathsRelative: ['${prefix}lib/l10n/app_en.arb'],
    fixtureOverlays: fixtureOverlays,
  );
}

L10nWitnessedChangeSet _packageChangeSet() => L10nWitnessedChangeSet(
  arbReplacements: {
    'lib/l10n/app_en.arb': L10nFileReplacement(
      relativePath: 'lib/l10n/app_en.arb',
      beforeBytes: ImmutableBytes.copyOf([1]),
      afterBytes: ImmutableBytes.copyOf([2]),
      beforeMode: 0x1a4,
      afterMode: 0x1a4,
    ),
  },
  generatedReplacements: const {},
);

L10nEvidenceEvaluation _acceptedEvaluation(L10nWitnessedChangeSet changeSet) =>
    L10nEvidenceEvaluation(
      verdict: L10nEvidenceVerdict(
        status: L10nEvidenceStatus.accepted,
        failures: const [],
        familyFingerprint: _sha,
        selectionFingerprint: _sha,
        configurationIdentity: _sha,
        packageResolutionIdentity: _sha,
        toolchainIdentity: _sha,
        baselineInventoryHashes: const {},
        candidateInventoryHashes: const {},
        mutationSummary: const {},
        verificationSummary: const {},
        timingAndResourceMetrics: const {
          'copiedBytes': 17,
          'baselineGeneration': {
            'elapsedMicros': 11,
            'process': {
              'resourceObservation': {'sampledPeakRssBytes': 1024},
            },
          },
          'candidateGeneration': {
            'elapsedMicros': 13,
            'process': {
              'resourceObservation': {'sampledPeakRssBytes': 2048},
            },
          },
        },
      ),
      witnessedChangeSet: changeSet,
    );

L10nEvidenceEvaluation _rejectedEvaluation() => L10nEvidenceEvaluation(
  verdict: L10nEvidenceVerdict(
    status: L10nEvidenceStatus.rejected,
    failures: const [
      L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.scanBlockerPresent,
        stage: 'family-preflight',
        detailCode: 'selected-node-retained',
        relativePath: 'lib/l10n/app_en.arb',
      ),
    ],
    familyFingerprint: _sha,
    selectionFingerprint: _sha,
    configurationIdentity: _sha,
    packageResolutionIdentity: _sha,
    toolchainIdentity: _sha,
    baselineInventoryHashes: const {},
    candidateInventoryHashes: const {},
    mutationSummary: const {},
    verificationSummary: const {},
    timingAndResourceMetrics: const {},
  ),
);

int Function() _clock(List<int> values) {
  var index = 0;
  return () => values[index++];
}

final class _RecordingCorpusRunner implements CorpusMutationEvidenceRunner {
  int calls = 0;
  L10nWitnessedChangeSet? changeSet;

  @override
  Future<CorpusMutationEvidenceOutcome> run({
    required L10nMutationProjectManifest project,
    required CorpusProjectView view,
    required String canonicalFlutterExecutable,
    required L10nWitnessedChangeSet changeSet,
    required String candidateIdentity,
    required String familyIdentity,
  }) async {
    calls++;
    this.changeSet = changeSet;
    return CorpusMutationEvidenceOutcome(
      status: CorpusMutationEvidenceStatus.passed,
      candidateIdentity: candidateIdentity,
      familyIdentity: familyIdentity,
      installedChangeSetHash: changeSet.fingerprint,
      policyHash: _sha,
      commandResults: const [
        {
          'identity': _sha,
          'status': 'passed',
          'exitCode': 0,
          'timedOut': false,
          'outputTruncated': false,
          'stdoutSha256': _sha,
          'stdoutCapturedBytes': 0,
          'stdoutOmittedBytes': 0,
          'stderrSha256': _sha,
          'stderrCapturedBytes': 0,
          'stderrOmittedBytes': 0,
          'resourceStatus': 'measured',
          'resourceSampleCount': 1,
          'sampledPeakRssBytes': 4096,
        },
      ],
      beforeManagedFingerprint: _sha,
      afterManagedFingerprint: _sha,
      restorationVerified: true,
    );
  }
}

final class _RecordingProcessRunner implements ProcessExecutionRunner {
  _RecordingProcessRunner(this.result, {this.onRun});

  final ManagedProcessResult result;
  final void Function()? onRun;
  int calls = 0;
  String? executable;
  List<String>? arguments;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  }) async {
    calls++;
    this.executable = executable;
    this.arguments = [...arguments];
    onRun?.call();
    return result;
  }
}

final class _FakeAuthorityLoader implements ProductionL10nAuthorityLoaderBase {
  _FakeAuthorityLoader(this.snapshot);

  final ProductionL10nAuthoritySnapshot snapshot;
  int calls = 0;

  @override
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  ) async {
    calls++;
    return snapshot;
  }

  @override
  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  ) async {}
}

final class _ThrowingAuthorityLoader
    implements ProductionL10nAuthorityLoaderBase {
  @override
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  ) async => throw StateError('authority unavailable');

  @override
  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  ) async {}
}

final class _AuthorityProcessRunner implements ProcessExecutionRunner {
  int gitHeadCalls = 0;
  int gitStatusCalls = 0;
  int flutterProbeCalls = 0;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  }) async {
    if (executable == '/usr/bin/git') {
      if (arguments.contains('rev-parse')) {
        gitHeadCalls++;
        final repository = p.basename(arguments[1]);
        final revision = switch (repository) {
          'GitJournal' => 'c8a67e098db06335762f822d7733c330f4bd0d6b',
          'gsy_github_app_flutter' =>
            '2b6c49008afc44b90fee869dedf8e59a86482953',
          'smooth-app' => 'bac71afd115f72e379c0b501b95e5ede20ecd636',
          _ => throw StateError('unknown retained repository'),
        };
        return _processResult('$revision\n');
      }
      gitStatusCalls++;
      return _processResult('');
    }
    flutterProbeCalls++;
    final version = p.basename(p.dirname(p.dirname(executable))).substring(4);
    final machine = <String, Object?>{
      'frameworkVersion': version,
      'flutterVersion': version,
      'frameworkRevision': version == '3.41.5'
          ? '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa'
          : _gitSha,
      'engineRevision': version == '3.41.5'
          ? '052f31d115eceda8cbff1b3481fcde4330c4ae12'
          : _gitSha,
      'dartSdkVersion': version == '3.41.5' ? '3.11.3' : 'test-$version',
    };
    return _processResult('${jsonEncode(machine)}\n');
  }
}

ManagedProcessResult _processResult(String stdout) => ManagedProcessResult(
  exitCode: 0,
  stdout: BoundedProcessOutput(
    capturedPayload: utf8.encode(stdout),
    omittedBytes: 0,
  ),
  stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
);

ManagedProcessResult _successfulProcessResult() => ManagedProcessResult(
  exitCode: 0,
  stdout: BoundedProcessOutput(
    capturedPayload: utf8.encode(
      '${jsonEncode({
        'type': 'testStart',
        'test': {'id': 1, 'name': 'rejects malformed ARB bytes'},
      })}\n'
      '${jsonEncode({'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': false, 'hidden': false})}\n'
      '${jsonEncode({'type': 'done', 'success': true})}\n',
    ),
    omittedBytes: 0,
  ),
  stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
);

ManagedProcessResult _emptySuccessfulProcessResult() => ManagedProcessResult(
  exitCode: 0,
  stdout: BoundedProcessOutput(
    capturedPayload: utf8.encode(
      '${jsonEncode({'type': 'done', 'success': true})}\n',
    ),
    omittedBytes: 0,
  ),
  stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
);

ManagedProcessResult
_successfulProcessResultWithExtraTest() => ManagedProcessResult(
  exitCode: 0,
  stdout: BoundedProcessOutput(
    capturedPayload: utf8.encode(
      '${jsonEncode({
        'type': 'testStart',
        'test': {'id': 1, 'name': 'rejects malformed ARB bytes'},
      })}\n'
      '${jsonEncode({
        'type': 'testStart',
        'test': {'id': 2, 'name': 'passes another test'},
      })}\n'
      '${jsonEncode({'type': 'testDone', 'testID': 1, 'result': 'success', 'skipped': false, 'hidden': false})}\n'
      '${jsonEncode({'type': 'testDone', 'testID': 2, 'result': 'success', 'skipped': false, 'hidden': false})}\n'
      '${jsonEncode({'type': 'done', 'success': true})}\n',
    ),
    omittedBytes: 0,
  ),
  stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
);

L10nMutationReadinessOptions _productionOptions(
  Directory sandbox, {
  String outputName = 'result.json',
}) {
  final root = Directory(sandbox.resolveSymbolicLinksSync());
  final corpusRoot = Directory(p.join(root.path, 'corpus'))
    ..createSync(recursive: true);
  Directory(p.join(corpusRoot.path, 'results')).createSync(recursive: true);
  for (final leaf in const [
    'GitJournal',
    'gsy_github_app_flutter',
    'smooth-app',
  ]) {
    Directory(p.join(corpusRoot.path, leaf)).createSync(recursive: true);
  }
  File(
    p.join(corpusRoot.path, 'gsy_github_app_flutter', '.fvmrc'),
  ).writeAsStringSync('{\n  "flutter": "3.44.1"\n}');
  File(
    p.join(corpusRoot.path, 'smooth-app', '.fvmrc'),
  ).writeAsStringSync('{\n  "flutter": "3.44.9"\n}');
  final arguments = <String>[
    '--manifest',
    'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
    '--corpus-root',
    corpusRoot.path,
  ];
  for (final version in const ['3.41.5', '3.44.1', '3.44.9']) {
    final flutter = File(p.join(root.path, 'sdk-$version', 'bin', 'flutter'));
    flutter.parent.createSync(recursive: true);
    flutter.writeAsStringSync('#!/bin/sh\n');
    arguments.addAll(['--sdk', '$version=${flutter.path}']);
  }
  arguments.addAll([
    '--output',
    p.join(corpusRoot.path, 'results', outputName),
  ]);
  return L10nMutationReadinessOptions.parse(arguments);
}

Map<String, Directory> _retainedRepositories(Directory corpusRoot) => {
  'gitjournal': Directory(p.join(corpusRoot.path, 'GitJournal')),
  'gsy': Directory(p.join(corpusRoot.path, 'gsy_github_app_flutter')),
  'smooth': Directory(p.join(corpusRoot.path, 'smooth-app')),
};

List<String> _argvFor(L10nMutationReadinessOptions options) => [
  '--manifest',
  options.manifestPath,
  '--corpus-root',
  options.corpusRoot.path,
  for (final entry in options.sdkFlutterByVersion.entries) ...[
    '--sdk',
    '${entry.key}=${entry.value.path}',
  ],
  '--output',
  options.outputFile.path,
];

Future<Directory> _copyFixture({String packageRoot = '.'}) async {
  final source = Directory(p.absolute('test/fixtures/l10n_test'));
  final base = await Directory.systemTemp.createTemp('l10n-production-');
  final target = packageRoot == '.'
      ? base
      : await Directory(p.join(base.path, packageRoot)).create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(target.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
  return target;
}

Directory _repositoryRoot(Directory packageRoot, String relativePackageRoot) {
  var result = packageRoot;
  if (relativePackageRoot != '.') {
    for (final _ in relativePackageRoot.split('/')) {
      result = result.parent;
    }
  }
  return result;
}

final class _ReadyCorpusViewFactory implements CorpusProjectViewFactory {
  const _ReadyCorpusViewFactory(this.repository, {Directory? packageRoot})
    : packageRoot = packageRoot ?? repository;

  final Directory repository;
  final Directory packageRoot;

  @override
  Future<CorpusProjectViewCreationResult> create({
    required L10nMutationProjectManifest project,
    required String retainedRepositoryPath,
    required String canonicalFlutterExecutable,
  }) async => CorpusProjectViewReady(
    CorpusProjectView(
      repositoryRoot: repository,
      packageRoot: packageRoot,
      repositoryRevision: project.repositoryRevision,
      provisionedBaselineFingerprint: _sha,
      baselineGitStatusIdentity: _sha,
      cleanupLease: const _SuccessfulCorpusViewLease(),
    ),
  );
}

final class _SuccessfulCorpusViewLease implements CorpusProjectViewLease {
  const _SuccessfulCorpusViewLease();

  @override
  Future<bool> dispose() async => true;
}
