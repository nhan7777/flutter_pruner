import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_preflight.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  test('L10nEvidenceRequest defensively freezes the requested selection', () {
    final selectedNodeIds = <String>['l10n:fixture:dead'];
    final request = L10nEvidenceRequest(
      analysis: _analysis(),
      selectedNodeIds: selectedNodeIds,
      sdkRegistry: L10nSdkRegistry({
        Version(3, 41, 5): '/fixture/flutter/bin/flutter',
      }),
      toolchainSelection: const ProjectSelectorSelection(),
    );

    selectedNodeIds.add('l10n:fixture:late');

    expect(request.selectedNodeIds, ['l10n:fixture:dead']);
    expect(
      () => request.selectedNodeIds.add('l10n:fixture:other'),
      throwsUnsupportedError,
    );
  });

  test('rejects an empty selection before invoking any boundary', () async {
    final boundaries = _NeverCalledBoundaries();
    final pipeline = L10nEvidencePipeline(
      toolchainResolver: _NeverCalledToolchainResolver(),
      configLoader: boundaries,
      snapshotter: boundaries,
      materializer: boundaries,
      generator: boundaries,
      reconciler: boundaries,
      verifier: boundaries,
      revalidator: _NeverCalledSnapshotRevalidator(),
    );

    final evaluation = await pipeline.evaluate(
      L10nEvidenceRequest(
        analysis: _analysis(),
        selectedNodeIds: const [],
        sdkRegistry: L10nSdkRegistry({
          Version(3, 41, 5): '/fixture/flutter/bin/flutter',
        }),
        toolchainSelection: const ProjectSelectorSelection(),
      ),
    );

    expect(evaluation.verdict.status, L10nEvidenceStatus.rejected);
    expect(evaluation.verdict.reasonCodes, [
      L10nEvidenceRejectionCode.invalidSelection,
    ]);
    expect(evaluation.verdict.failures.single.detailCode, 'selection-empty');
    expect(evaluation.witnessedChangeSet, isNull);
    expect(boundaries.callCount, 0);
  });

  test(
    'runs the exact transaction and cleans stages before acceptance',
    () async {
      final fixture = await _PipelineFixture.create();
      addTearDown(fixture.dispose);
      final originalBefore = await L10nStageInventory.capture(
        fixture.originalProject,
        captureBytesFor: const {},
      );

      final evaluation = await fixture.pipeline.evaluate(fixture.request);
      final originalAfter = await L10nStageInventory.capture(
        fixture.originalProject,
        captureBytesFor: const {},
      );

      expect(evaluation.verdict.status, L10nEvidenceStatus.accepted);
      expect(evaluation.verdict.failures, isEmpty);
      expect(
        evaluation.witnessedChangeSet?.fingerprint,
        fixture.changeSet.fingerprint,
      );
      expect(originalAfter.fingerprint, originalBefore.fingerprint);
      expect(fixture.cleanupLease?.consumed, isTrue);
      expect(fixture.log, [
        'resolve',
        'config',
        'snapshot',
        'materializerFactory',
        'materialize',
        'baselineGenerate',
        'installCandidateArbs',
        'candidateGenerate',
        'reconcile',
        'baselineVerify',
        'candidateVerify',
        'revalidate',
        'cleanup',
      ]);
      expect(fixture.baselineRemovedKeys, isEmpty);
      expect(fixture.candidateRemovedKeys, fixture.snapshot.selectedKeys);
      expect(
        fixture.baselineOutputPaths,
        fixture.pair?.baseline.generationOutputPaths,
      );
      expect(
        fixture.candidateOutputPaths,
        fixture.pair?.candidate.generationOutputPaths,
      );
      expect(evaluation.verdict.mutationSummary['selectedKeys'], ['dead']);
      expect(evaluation.verdict.mutationSummary['generatedReplacementPaths'], [
        'lib/generated/app.dart',
      ]);
      expect(evaluation.verdict.mutationSummary['removalsByPath'], {
        'lib/l10n/app_en.arb': [
          for (final removal
              in fixture
                  .snapshot
                  .mutationPlan
                  .removalsByPath['lib/l10n/app_en.arb']!)
            {
              'decodedKey': removal.decodedKey,
              'endExclusive': removal.span.endExclusive,
              'kind': removal.decodedKey.startsWith('@')
                  ? 'companion'
                  : 'message',
              'start': removal.span.start,
            },
        ],
      });
      expect(
        fixture.snapshot.mutationPlan.removalsByPath['lib/l10n/app_en.arb']!
            .map((removal) => removal.decodedKey),
        ['dead', '@dead'],
      );
      expect(
        evaluation.verdict.mutationSummary['witnessedChangeSetFingerprint'],
        fixture.changeSet.fingerprint,
      );
      final encoded = jsonEncode(evaluation.verdict.toInternalJson());
      expect(encoded, isNot(contains(fixture.originalProject.path)));
      expect(encoded, isNot(contains('raw-secret-output')));
    },
  );

  test(
    'cleanup failure rejects and never exposes the pending change set',
    () async {
      final fixture = await _PipelineFixture.create(cleanupFailure: true);
      addTearDown(fixture.dispose);

      final evaluation = await fixture.pipeline.evaluate(fixture.request);

      expect(evaluation.verdict.status, L10nEvidenceStatus.rejected);
      expect(
        evaluation.verdict.reasonCodes,
        contains(L10nEvidenceRejectionCode.cleanupFailed),
      );
      expect(evaluation.witnessedChangeSet, isNull);
      expect(
        evaluation.verdict.mutationSummary['witnessedChangeSetFingerprint'],
        fixture.changeSet.fingerprint,
      );
      expect(fixture.log.last, 'cleanup');
    },
  );

  for (final testCase in const <(_BoundaryFailure, L10nEvidenceRejectionCode)>[
    (_BoundaryFailure.resolve, L10nEvidenceRejectionCode.toolchainUnavailable),
    (
      _BoundaryFailure.config,
      L10nEvidenceRejectionCode.unsupportedConfiguration,
    ),
    (_BoundaryFailure.snapshot, L10nEvidenceRejectionCode.invalidSelection),
    (
      _BoundaryFailure.materialize,
      L10nEvidenceRejectionCode.materializationFailed,
    ),
    (
      _BoundaryFailure.partialMaterializeIncompleteCleanup,
      L10nEvidenceRejectionCode.materializationFailed,
    ),
    (
      _BoundaryFailure.baselineGenerate,
      L10nEvidenceRejectionCode.baselineGenerationFailed,
    ),
    (
      _BoundaryFailure.install,
      L10nEvidenceRejectionCode.editPostconditionFailed,
    ),
    (
      _BoundaryFailure.candidateGenerate,
      L10nEvidenceRejectionCode.candidateGenerationFailed,
    ),
    (
      _BoundaryFailure.reconcile,
      L10nEvidenceRejectionCode.outputFamilyAmbiguous,
    ),
    (
      _BoundaryFailure.baselineVerify,
      L10nEvidenceRejectionCode.candidateVerificationFailed,
    ),
    (
      _BoundaryFailure.candidateVerify,
      L10nEvidenceRejectionCode.candidateVerificationFailed,
    ),
    (_BoundaryFailure.revalidate, L10nEvidenceRejectionCode.sourceDrift),
    (_BoundaryFailure.cleanup, L10nEvidenceRejectionCode.cleanupFailed),
  ]) {
    test(
      'folds typed ${testCase.$1.name} failure and finalizes safely',
      () async {
        final fixture = await _PipelineFixture.create(failure: testCase.$1);
        addTearDown(fixture.dispose);
        final originalBefore = await L10nStageInventory.capture(
          fixture.originalProject,
          captureBytesFor: const {},
        );

        final evaluation = await fixture.pipeline.evaluate(fixture.request);
        final originalAfter = await L10nStageInventory.capture(
          fixture.originalProject,
          captureBytesFor: const {},
        );

        expect(
          evaluation.verdict.reasonCodes,
          contains(testCase.$2),
          reason: testCase.$1.name,
        );
        expect(evaluation.witnessedChangeSet, isNull);
        expect(
          originalAfter.fingerprint,
          originalBefore.fingerprint,
          reason: testCase.$1.name,
        );
        if (testCase.$1.index >= _BoundaryFailure.materialize.index) {
          expect(fixture.log.last, 'cleanup', reason: testCase.$1.name);
          expect(fixture.cleanupLease?.consumed, isTrue);
        } else {
          expect(fixture.log, isNot(contains('cleanup')));
        }
        if (testCase.$1 == _BoundaryFailure.baselineVerify) {
          expect(fixture.log, contains('candidateVerify'));
        }
      },
    );
  }

  test(
    'rejects incomplete cleanup evidence for a true one-root partial attempt',
    () async {
      final fixture = await _PipelineFixture.create(
        failure: _BoundaryFailure.partialMaterializeIncompleteCleanup,
      );
      addTearDown(fixture.dispose);

      final evaluation = await fixture.pipeline.evaluate(fixture.request);

      expect(fixture.cleanupLease?.createdRoots, hasLength(1));
      expect(
        fixture.cleanupLease?.createdRoots.single.role,
        L10nStageRole.baseline,
      );
      expect(
        evaluation.verdict.reasonCodes,
        contains(L10nEvidenceRejectionCode.cleanupFailed),
      );
      expect(evaluation.witnessedChangeSet, isNull);
    },
  );

  for (final testCase in const <(_BoundaryFailure, L10nEvidenceRejectionCode)>[
    (
      _BoundaryFailure.revalidateSourceMismatch,
      L10nEvidenceRejectionCode.sourceDrift,
    ),
    (
      _BoundaryFailure.revalidatePackageMismatch,
      L10nEvidenceRejectionCode.packageResolutionDrift,
    ),
    (
      _BoundaryFailure.revalidateToolchainMismatch,
      L10nEvidenceRejectionCode.toolchainDrift,
    ),
  ]) {
    test('rejects typed ${testCase.$1.name} identity drift', () async {
      final fixture = await _PipelineFixture.create(failure: testCase.$1);
      addTearDown(fixture.dispose);

      final evaluation = await fixture.pipeline.evaluate(fixture.request);

      expect(evaluation.verdict.reasonCodes, contains(testCase.$2));
      expect(evaluation.witnessedChangeSet, isNull);
      expect(
        evaluation.verdict.verificationSummary,
        isNot(contains('revalidation')),
      );
      expect(fixture.log.last, 'cleanup');
    });
  }

  for (final testCase in const <(_BoundaryFailure, L10nEvidenceRejectionCode)>[
    (
      _BoundaryFailure.candidateGenerateThrow,
      L10nEvidenceRejectionCode.internalFailure,
    ),
    (
      _BoundaryFailure.candidateVerifyThrow,
      L10nEvidenceRejectionCode.internalFailure,
    ),
    (
      _BoundaryFailure.revalidateThrow,
      L10nEvidenceRejectionCode.internalFailure,
    ),
    (_BoundaryFailure.cleanupThrow, L10nEvidenceRejectionCode.cleanupFailed),
  ]) {
    test(
      'redacts unexpected ${testCase.$1.name} failure and rejects safely',
      () async {
        final fixture = await _PipelineFixture.create(failure: testCase.$1);
        addTearDown(fixture.dispose);
        final originalBefore = await L10nStageInventory.capture(
          fixture.originalProject,
          captureBytesFor: const {},
        );

        final evaluation = await fixture.pipeline.evaluate(fixture.request);
        final originalAfter = await L10nStageInventory.capture(
          fixture.originalProject,
          captureBytesFor: const {},
        );
        final encoded = jsonEncode(evaluation.verdict.toInternalJson());

        expect(evaluation.verdict.reasonCodes, contains(testCase.$2));
        expect(evaluation.witnessedChangeSet, isNull);
        expect(originalAfter.fingerprint, originalBefore.fingerprint);
        expect(fixture.log.last, 'cleanup');
        expect(encoded, isNot(contains('raw-secret-output')));
        expect(encoded, isNot(contains('/private/tmp/owned-stage')));
        expect(encoded, isNot(contains('TOKEN=do-not-serialize')));
        if (testCase.$1 == _BoundaryFailure.candidateVerifyThrow) {
          expect(fixture.log, contains('baselineVerify'));
        }
      },
    );
  }
}

enum _BoundaryFailure {
  resolve,
  config,
  snapshot,
  materialize,
  partialMaterializeIncompleteCleanup,
  baselineGenerate,
  install,
  candidateGenerate,
  reconcile,
  baselineVerify,
  candidateVerify,
  revalidate,
  cleanup,
  revalidateSourceMismatch,
  revalidatePackageMismatch,
  revalidateToolchainMismatch,
  candidateGenerateThrow,
  candidateVerifyThrow,
  revalidateThrow,
  cleanupThrow,
}

final class _NeverCalledToolchainResolver implements L10nToolchainResolver {
  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) => throw StateError('toolchain resolver must not be called');

  @override
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  }) => throw StateError('toolchain revalidator must not be called');
}

final class _NeverCalledSnapshotRevalidator implements L10nSnapshotRevalidator {
  @override
  Future<L10nSnapshotRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nFamilySnapshot snapshot,
    required L10nToolchainResolved toolchain,
  }) => throw StateError('snapshot revalidator must not be called');
}

final class _NeverCalledBoundaries
    implements
        L10nGenerationConfigLoader,
        L10nFamilySnapshotter,
        L10nStageMaterializer,
        L10nGenerator,
        L10nOutputReconciler,
        L10nStageVerifier {
  var callCount = 0;

  Never _called() {
    callCount++;
    throw StateError('boundary must not be called');
  }

  @override
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  }) async => _called();

  @override
  Future<L10nFamilySnapshotResult> capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  }) async => _called();

  @override
  Future<L10nStageMaterializationResult> materialize(
    L10nFamilySnapshot snapshot,
  ) async => _called();

  @override
  Future<List<L10nEvidenceFailure>> installCandidateArbs(
    L10nStageRoot candidate,
    Map<String, ImmutableBytes> replacements,
  ) async => _called();

  @override
  Future<L10nStageCleanupResult> cleanup(L10nStageCleanupLease lease) async =>
      _called();

  @override
  Future<L10nGenerationRun> generate({
    required L10nStageRoot stage,
    required L10nToolchainResolved toolchain,
    required L10nGenerationPhase phase,
    required Set<String> outputPaths,
  }) async => _called();

  @override
  L10nReconciliationResult reconcile({
    required L10nFamilySnapshot liveSnapshot,
    required L10nGenerationAllowlist allowlist,
    required L10nGenerationRun baseline,
    required L10nGenerationRun candidate,
  }) => _called();

  @override
  Future<L10nStageVerificationResult> verify({
    required L10nStageRoot stage,
    required L10nFamilySnapshot snapshot,
    required Set<String> expectedRemovedKeys,
    required L10nToolchainResolved toolchain,
  }) async => _called();
}

final class _PipelineFixture {
  _PipelineFixture._({
    required this.scratch,
    required this.originalProject,
    required this.toolchain,
    required this.config,
    required this.snapshot,
    required this.changeSet,
    required this.request,
    required this.pipeline,
    required this.materializer,
    required this.scenario,
  });

  final Directory scratch;
  final Directory originalProject;
  final L10nToolchainResolved toolchain;
  final L10nGenerationConfig config;
  final L10nFamilySnapshot snapshot;
  final L10nWitnessedChangeSet changeSet;
  final L10nEvidenceRequest request;
  final L10nEvidencePipeline pipeline;
  final _RecordingMaterializer materializer;
  final _ScenarioBoundaries scenario;

  List<String> get log => scenario.log;
  L10nStageCleanupLease? get cleanupLease => materializer.cleanupLease;
  L10nStagePair? get pair => materializer.pair;
  Set<String>? get baselineRemovedKeys => scenario.baselineRemovedKeys;
  Set<String>? get candidateRemovedKeys => scenario.candidateRemovedKeys;
  Set<String>? get baselineOutputPaths => scenario.baselineOutputPaths;
  Set<String>? get candidateOutputPaths => scenario.candidateOutputPaths;

  static Future<_PipelineFixture> create({
    bool cleanupFailure = false,
    _BoundaryFailure? failure,
  }) async {
    final allocatedScratch = Directory.systemTemp.createTempSync(
      'l10n-evidence-pipeline-test-',
    );
    final scratch = Directory(allocatedScratch.resolveSymbolicLinksSync());
    final originalProject = Directory(p.join(scratch.path, 'project'))
      ..createSync(recursive: true);
    _writeProject(originalProject);
    final project = _project(originalProject);
    final analysis = _analysis(project: project);
    final toolchain = _toolchain(scratch);
    final loaded = await const DefaultL10nGenerationConfigLoader().load(
      project: project,
      toolchain: toolchain.machineIdentity,
    );
    if (loaded is! L10nGenerationConfigReady) {
      throw StateError('pipeline fixture config rejected');
    }
    final config = loaded.config;
    final snapshot = _snapshot(
      project: project,
      config: config,
      toolchain: toolchain,
    );
    final changeSet = _changeSet(snapshot);
    var stageIndex = 0;
    final delegate = DefaultL10nStageMaterializer.testing(
      expectedToolchainIdentity: toolchain.identitySha256,
      canonicalSystemTempRoot: Directory.systemTemp,
      canonicalOriginalProjectRoot: originalProject.resolveSymbolicLinksSync(),
      rootAllocator: () async {
        final index = stageIndex++;
        if (failure == _BoundaryFailure.partialMaterializeIncompleteCleanup &&
            index == 1) {
          throw const FileSystemException(
            'injected second root allocation failure',
          );
        }
        final directory = Directory(p.join(scratch.path, 'stage-$index'));
        directory.createSync();
        return directory;
      },
    );
    final log = <String>[];
    final materializer = _RecordingMaterializer(
      delegate: delegate,
      log: log,
      failure: cleanupFailure ? _BoundaryFailure.cleanup : failure,
    );
    final scenario = _ScenarioBoundaries(
      log: log,
      toolchain: toolchain,
      config: config,
      snapshot: snapshot,
      changeSet: changeSet,
      failure: failure,
    );
    final pipeline = L10nEvidencePipeline.withMaterializerFactory(
      toolchainResolver: _ScenarioToolchainResolver(
        log: log,
        toolchain: toolchain,
        failure: failure,
      ),
      configLoader: scenario,
      snapshotter: scenario,
      materializerFactory: (resolved) {
        log.add('materializerFactory');
        expect(identical(resolved, toolchain), isTrue);
        return materializer;
      },
      generator: scenario,
      reconciler: scenario,
      verifier: scenario,
      revalidator: scenario,
    );
    final request = L10nEvidenceRequest(
      analysis: analysis,
      selectedNodeIds: const ['l10n:fixture:dead'],
      sdkRegistry: L10nSdkRegistry({
        Version(3, 41, 5): toolchain.canonicalFlutterExecutable,
      }),
      toolchainSelection: const ProjectSelectorSelection(),
    );
    return _PipelineFixture._(
      scratch: scratch,
      originalProject: originalProject,
      toolchain: toolchain,
      config: config,
      snapshot: snapshot,
      changeSet: changeSet,
      request: request,
      pipeline: pipeline,
      materializer: materializer,
      scenario: scenario,
    );
  }

  Future<void> dispose() async {
    final lease = materializer.cleanupLease;
    if (lease != null && !lease.consumed) {
      await materializer.delegate.cleanup(lease);
    }
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

final class _ScenarioToolchainResolver implements L10nToolchainResolver {
  _ScenarioToolchainResolver({
    required this.log,
    required this.toolchain,
    required this.failure,
  });

  final List<String> log;
  final L10nToolchainResolved toolchain;
  final _BoundaryFailure? failure;

  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) async {
    log.add('resolve');
    if (failure == _BoundaryFailure.resolve) {
      return const L10nToolchainRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          stage: 'toolchain-resolution',
          detailCode: 'injected-resolve-failure',
        ),
      );
    }
    return toolchain;
  }

  @override
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  }) async => L10nToolchainStillMatches(expected.identitySha256);
}

final class _ScenarioBoundaries
    implements
        L10nGenerationConfigLoader,
        L10nFamilySnapshotter,
        L10nGenerator,
        L10nOutputReconciler,
        L10nStageVerifier,
        L10nSnapshotRevalidator {
  _ScenarioBoundaries({
    required this.log,
    required this.toolchain,
    required this.config,
    required this.snapshot,
    required this.changeSet,
    required this.failure,
  });

  final List<String> log;
  final L10nToolchainResolved toolchain;
  final L10nGenerationConfig config;
  final L10nFamilySnapshot snapshot;
  final L10nWitnessedChangeSet changeSet;
  final _BoundaryFailure? failure;
  Set<String>? baselineRemovedKeys;
  Set<String>? candidateRemovedKeys;
  Set<String>? baselineOutputPaths;
  Set<String>? candidateOutputPaths;

  @override
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  }) async {
    log.add('config');
    if (failure == _BoundaryFailure.config) {
      return L10nGenerationConfigRejected(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          stage: 'generation-config-load',
          detailCode: 'injected-config-failure',
        ),
      ]);
    }
    return L10nGenerationConfigReady(config);
  }

  @override
  Future<L10nFamilySnapshotResult> capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  }) async {
    log.add('snapshot');
    expect(selectedNodeIds, ['l10n:fixture:dead']);
    if (failure == _BoundaryFailure.snapshot) {
      return L10nFamilySnapshotRejected(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.invalidSelection,
          stage: 'family-preflight',
          detailCode: 'injected-snapshot-failure',
        ),
      ]);
    }
    return L10nFamilySnapshotReady(snapshot);
  }

  @override
  Future<L10nGenerationRun> generate({
    required L10nStageRoot stage,
    required L10nToolchainResolved toolchain,
    required L10nGenerationPhase phase,
    required Set<String> outputPaths,
  }) async {
    switch (phase) {
      case L10nGenerationPhase.baseline:
        log.add('baselineGenerate');
        baselineOutputPaths = Set.unmodifiable(outputPaths);
      case L10nGenerationPhase.candidate:
        log.add('candidateGenerate');
        candidateOutputPaths = Set.unmodifiable(outputPaths);
    }
    final injected = switch (phase) {
      L10nGenerationPhase.baseline
          when failure == _BoundaryFailure.baselineGenerate =>
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.baselineGenerationFailed,
          stage: 'baseline-generation',
          detailCode: 'injected-baseline-failure',
        ),
      L10nGenerationPhase.candidate
          when failure == _BoundaryFailure.candidateGenerate =>
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.candidateGenerationFailed,
          stage: 'candidate-generation',
          detailCode: 'injected-candidate-failure',
        ),
      _ => null,
    };
    if (phase == L10nGenerationPhase.candidate &&
        failure == _BoundaryFailure.candidateGenerateThrow) {
      throw StateError(_unexpectedSecret);
    }
    return _generationRun(phase, failure: injected);
  }

  @override
  L10nReconciliationResult reconcile({
    required L10nFamilySnapshot liveSnapshot,
    required L10nGenerationAllowlist allowlist,
    required L10nGenerationRun baseline,
    required L10nGenerationRun candidate,
  }) {
    log.add('reconcile');
    expect(allowlist.replacementOutputPaths, snapshot.expectedGeneratedPaths);
    if (failure == _BoundaryFailure.reconcile) {
      return L10nReconciliationRejected(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.outputFamilyAmbiguous,
          stage: 'output-reconciliation',
          detailCode: 'injected-reconcile-failure',
        ),
      ]);
    }
    return L10nReconciliationReady(changeSet);
  }

  @override
  Future<L10nStageVerificationResult> verify({
    required L10nStageRoot stage,
    required L10nFamilySnapshot snapshot,
    required Set<String> expectedRemovedKeys,
    required L10nToolchainResolved toolchain,
  }) async {
    if (stage.role == L10nStageRole.baseline) {
      log.add('baselineVerify');
      baselineRemovedKeys = Set.unmodifiable(expectedRemovedKeys);
    } else {
      log.add('candidateVerify');
      candidateRemovedKeys = Set.unmodifiable(expectedRemovedKeys);
    }
    if (stage.role == L10nStageRole.candidate &&
        failure == _BoundaryFailure.candidateVerifyThrow) {
      throw StateError(_unexpectedSecret);
    }
    if ((stage.role == L10nStageRole.baseline &&
            failure == _BoundaryFailure.baselineVerify) ||
        (stage.role == L10nStageRole.candidate &&
            failure == _BoundaryFailure.candidateVerify)) {
      return _verificationResult(
        snapshot,
        stage.role,
        failure: const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.candidateVerificationFailed,
          stage: 'stage-verification',
          detailCode: 'injected-verification-failure',
        ),
      );
    }
    return _verificationResult(snapshot, stage.role);
  }

  @override
  Future<L10nSnapshotRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nFamilySnapshot snapshot,
    required L10nToolchainResolved toolchain,
  }) async {
    log.add('revalidate');
    if (failure == _BoundaryFailure.revalidateThrow) {
      throw StateError(_unexpectedSecret);
    }
    if (failure == _BoundaryFailure.revalidate) {
      return L10nSnapshotDrifted(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.sourceDrift,
          stage: 'snapshot-revalidation',
          detailCode: 'injected-revalidation-failure',
        ),
      ]);
    }
    final sourceIdentity = failure == _BoundaryFailure.revalidateSourceMismatch
        ? _differentIdentity
        : const L10nSnapshotSourceIdentityProjector().project(snapshot);
    final packageIdentity =
        failure == _BoundaryFailure.revalidatePackageMismatch
        ? _differentIdentity
        : snapshot.packageResolutionIdentity;
    final toolchainIdentity =
        failure == _BoundaryFailure.revalidateToolchainMismatch
        ? _differentIdentity
        : toolchain.identitySha256;
    return L10nSnapshotStillCurrent(
      sourceIdentity: sourceIdentity,
      packageResolutionIdentity: packageIdentity,
      toolchainIdentity: toolchainIdentity,
    );
  }
}

final class _RecordingMaterializer implements L10nStageMaterializer {
  _RecordingMaterializer({
    required this.delegate,
    required this.log,
    required this.failure,
  });

  final DefaultL10nStageMaterializer delegate;
  final List<String> log;
  final _BoundaryFailure? failure;
  L10nStageCleanupLease? cleanupLease;
  L10nStagePair? pair;

  @override
  Future<L10nStageMaterializationResult> materialize(
    L10nFamilySnapshot snapshot,
  ) async {
    log.add('materialize');
    final result = await delegate.materialize(snapshot);
    cleanupLease = result.cleanupLease;
    pair = result.pair;
    if (failure == _BoundaryFailure.materialize) {
      return L10nStageMaterializationResult(
        pair: null,
        cleanupLease: result.cleanupLease,
        failures: const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.materializationFailed,
            stage: 'stage-materialization',
            detailCode: 'injected-materialization-failure',
          ),
        ],
      );
    }
    return result;
  }

  @override
  Future<List<L10nEvidenceFailure>> installCandidateArbs(
    L10nStageRoot candidate,
    Map<String, ImmutableBytes> replacements,
  ) async {
    log.add('installCandidateArbs');
    if (failure == _BoundaryFailure.install) {
      return const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.editPostconditionFailed,
          stage: 'candidate-arb-installation',
          detailCode: 'injected-install-failure',
        ),
      ];
    }
    return delegate.installCandidateArbs(candidate, replacements);
  }

  @override
  Future<L10nStageCleanupResult> cleanup(L10nStageCleanupLease lease) async {
    log.add('cleanup');
    if (failure == _BoundaryFailure.cleanupThrow) {
      throw StateError(_unexpectedSecret);
    }
    final result = await delegate.cleanup(lease);
    if (failure == _BoundaryFailure.partialMaterializeIncompleteCleanup) {
      return L10nStageCleanupResult(
        baselineRemoved: false,
        candidateRemoved: false,
        failures: const [],
      );
    }
    if (failure != _BoundaryFailure.cleanup) return result;
    return L10nStageCleanupResult(
      baselineRemoved: result.baselineRemoved,
      candidateRemoved: result.candidateRemoved,
      failures: const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.cleanupFailed,
          stage: 'stage-cleanup',
          detailCode: 'injected-cleanup-failure',
        ),
      ],
    );
  }
}

AnalysisSnapshot _analysis({ProjectContext? project}) {
  final selectedProject = project ?? _project(Directory.current);
  final graph = ReachabilityGraph();
  return AnalysisSnapshot(
    project: selectedProject,
    graph: graph,
    graphIntegrity: graph.integrityFor(selectedProject.targets),
    findings: const [],
    adapterIds: const ['dart', 'l10n'],
    adapterRuns: const [],
    elapsedMicros: 1,
    exclusions: selectedProject.pathPolicy.snapshot(),
  );
}

ProjectContext _project(Directory root) => ProjectContext(
  root: root,
  pubspec: _pubspec,
  packageName: 'fixture',
  analysisMode: AnalysisMode.application,
  targetMatrix: TargetMatrix.declared([
    BuildTarget(name: 'app', platform: 'android', entrypoint: 'lib/main.dart'),
  ]),
  rootCoverage: RootCoverage.applicationApi(),
);

void _writeProject(Directory root) {
  void write(String relativePath, String contents) {
    final file = File(p.join(root.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  write('pubspec.yaml', _pubspecSource);
  write('pubspec.lock', 'packages: {}\n');
  write('l10n.yaml', _l10nYamlSource);
  write('lib/main.dart', 'void main() {}\n');
  write('lib/l10n/app_en.arb', _arbSource);
}

L10nToolchainResolved _toolchain(Directory scratch) {
  final sdk = Directory(p.join(scratch.path, 'sdk'))..createSync();
  return L10nToolchainResolved(
    canonicalFlutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
    canonicalSdkRoot: sdk.resolveSymbolicLinksSync(),
    launch: L10nToolchainLaunch(
      canonicalDartExecutable: p.join(
        sdk.path,
        'bin',
        'cache',
        'dart-sdk',
        'bin',
        'dart',
      ),
      canonicalFlutterToolsPackageConfig: p.join(
        sdk.path,
        'packages',
        'flutter_tools',
        '.dart_tool',
        'package_config.json',
      ),
      canonicalFlutterToolsSnapshot: p.join(
        sdk.path,
        'bin',
        'cache',
        'flutter_tools.snapshot',
      ),
    ),
    selection: const ProjectSelectorSelection(),
    generationArgs: const ['gen-l10n'],
    directProbeArgs: const ['--version', '--machine'],
    environmentOverrides: const {},
    selectorHashesByRelativePath: const {},
    machineIdentity: FlutterMachineIdentity(
      frameworkVersion: Version(3, 41, 5),
      frameworkRevision: '1111111111111111111111111111111111111111',
      engineRevision: '2222222222222222222222222222222222222222',
      dartSdkVersion: '3.11.3',
    ),
    originalSelectionProbeSha256: _identity,
    identitySha256: _identity,
  );
}

L10nFamilySnapshot _snapshot({
  required ProjectContext project,
  required L10nGenerationConfig config,
  required L10nToolchainResolved toolchain,
}) {
  final arbBytes = ImmutableBytes.copyOf(utf8.encode(_arbSource));
  final pubspecBytes = ImmutableBytes.copyOf(utf8.encode(_pubspecSource));
  final l10nBytes = ImmutableBytes.copyOf(utf8.encode(_l10nYamlSource));
  final lockBytes = ImmutableBytes.copyOf(utf8.encode('packages: {}\n'));
  final mainBytes = ImmutableBytes.copyOf(utf8.encode('void main() {}\n'));
  final packageSource = ImmutableBytes.copyOf(const [9]);
  final packageStage = ImmutableBytes.copyOf(const [3]);
  final entries = <String, L10nSnapshotEntry>{
    'pubspec.yaml': _entry(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      pubspecBytes,
    ),
    'pubspec.lock': _entry(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      lockBytes,
    ),
    'l10n.yaml': _entry('l10n.yaml', L10nSnapshotRole.l10nConfig, l10nBytes),
    '.dart_tool/package_config.json': L10nSnapshotEntry(
      relativePosixPath: '.dart_tool/package_config.json',
      role: L10nSnapshotRole.packageConfig,
      state: L10nSnapshotPresent(
        sourceBytes: packageSource,
        stageBytes: packageStage,
        sourceSha256: packageSource.sha256Hex,
        posixMode: _mode(0x180),
      ),
    ),
    '.dart_tool/package_graph.json': _absent(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
    ),
    'analysis_options.yaml': _absent(
      'analysis_options.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'dart_test.yaml': _absent(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'lib/main.dart': _entry(
      'lib/main.dart',
      L10nSnapshotRole.analyzerSource,
      mainBytes,
    ),
    'lib/l10n/app_en.arb': _entry(
      'lib/l10n/app_en.arb',
      L10nSnapshotRole.arbTemplate,
      arbBytes,
    ),
    'lib/generated/app.dart': _absent(
      'lib/generated/app.dart',
      L10nSnapshotRole.generatedBase,
    ),
  };
  return L10nFamilySnapshot(
    entries: entries,
    mutationPlan: _mutationPlan(),
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {'dead'},
    expectedGeneratedMemberKindsByKey: const {
      'dead': ArbGeneratedMemberKind.getter,
    },
    expectedGeneratedPaths: const {'lib/generated/app.dart'},
    optionalUntranslatedPath: null,
    verificationClosure: L10nVerificationClosure(
      projectOwnedDartPaths: const {'lib/main.dart'},
      analyzerRootIdentity: _identity,
    ),
    analysisOptionsProjection: L10nAnalysisOptionsProjection(
      projectOwnedPaths: const {},
      externalAuthorities: const [],
      contextAuthorityIdentity: _identity,
    ),
    provenUnrelatedOutputSiblings: const {},
    familyFingerprint: _identity,
    selectionFingerprint: _identity,
    l10nAnalysisFingerprint: _identity,
    configurationIdentity: config.configurationIdentity,
    packageConfigProjectionIdentity: _identity,
    packageResolutionIdentity: _identity,
    toolchainIdentity: toolchain.identitySha256,
    projectSemantics: L10nProjectSemantics(
      pubspec: project.pubspec,
      packageName: project.packageName,
      analysisMode: project.analysisMode,
      targetMatrix: project.targetMatrix,
      rootCoverage: project.rootCoverage,
    ),
  );
}

L10nArbMutationPlan _mutationPlan() {
  final parsed = ArbDocument.parse(utf8.encode(_arbSource));
  return (L10nArbMutationPlanner.plan(
            templatePath: 'lib/l10n/app_en.arb',
            documentsByPath: {
              'lib/l10n/app_en.arb': (parsed as ArbParseSuccess).document,
            },
            selectedKeys: const ['dead'],
          )
          as L10nArbMutationPlanReady)
      .plan;
}

L10nWitnessedChangeSet _changeSet(L10nFamilySnapshot snapshot) {
  final original =
      (snapshot.entries['lib/l10n/app_en.arb']!.state as L10nSnapshotPresent);
  final candidate =
      snapshot.mutationPlan.candidateArbBytes['lib/l10n/app_en.arb']!;
  return L10nWitnessedChangeSet(
    arbReplacements: {
      'lib/l10n/app_en.arb': L10nFileReplacement(
        relativePath: 'lib/l10n/app_en.arb',
        beforeBytes: original.sourceBytes,
        afterBytes: candidate,
        beforeMode: original.posixMode,
        afterMode: original.posixMode,
      ),
    },
    generatedReplacements: {
      'lib/generated/app.dart': L10nFileReplacement(
        relativePath: 'lib/generated/app.dart',
        beforeBytes: ImmutableBytes.copyOf(utf8.encode('old generated\n')),
        afterBytes: ImmutableBytes.copyOf(utf8.encode('new generated\n')),
        beforeMode: _mode(0x1a4),
        afterMode: _mode(0x1a4),
      ),
    },
  );
}

L10nGenerationRun _generationRun(
  L10nGenerationPhase phase, {
  L10nEvidenceFailure? failure,
}) => L10nGenerationRun(
  phase: phase,
  before: L10nStageInventoryCapture.unavailable(),
  after: L10nStageInventoryCapture.unavailable(),
  processResult: null,
  failures: failure == null ? const [] : [failure],
  elapsedMicros: phase == L10nGenerationPhase.baseline ? 2 : 3,
  commandIdentity: phase == L10nGenerationPhase.baseline
      ? _baselineCommandIdentity
      : _candidateCommandIdentity,
);

L10nStageVerificationResult _verificationResult(
  L10nFamilySnapshot snapshot,
  L10nStageRole role, {
  L10nEvidenceFailure? failure,
}) => L10nStageVerificationResult(
  accepted: failure == null,
  failures: failure == null ? const [] : [failure],
  policyIdentity: const L10nStageVerificationPolicy().hash,
  analyzerRootIdentity: snapshot.verificationClosure.analyzerRootIdentity,
  packageResolutionIdentity: snapshot.packageResolutionIdentity,
  toolchainIdentity: snapshot.toolchainIdentity,
  publishableBeforeIdentity: _identity,
  publishableAfterIdentity: _identity,
  summary: {
    'retainedGeneratedMemberIdentity': _identity,
    'retainedL10nGraphIdentity': _identity,
    'stageRole': role.name,
  },
);

L10nSnapshotEntry _entry(
  String path,
  L10nSnapshotRole role,
  ImmutableBytes bytes,
) => L10nSnapshotEntry(
  relativePosixPath: path,
  role: role,
  state: L10nSnapshotPresent(
    sourceBytes: bytes,
    stageBytes: bytes,
    sourceSha256: bytes.sha256Hex,
    posixMode: _mode(0x1a4),
  ),
);

L10nSnapshotEntry _absent(String path, L10nSnapshotRole role) =>
    L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: const L10nSnapshotAbsent(),
    );

int? _mode(int value) => Platform.isWindows ? null : value;

const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _baselineCommandIdentity =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _candidateCommandIdentity =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _differentIdentity =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _unexpectedSecret =
    'raw-secret-output /private/tmp/owned-stage TOKEN=do-not-serialize';

const Map<String, Object?> _pubspec = {
  'name': 'fixture',
  'environment': {'sdk': '>=3.9.0 <4.0.0'},
  'dependencies': {
    'flutter': {'sdk': 'flutter'},
  },
  'flutter': {'generate': true},
};

const _pubspecSource = '''
name: fixture
environment:
  sdk: ">=3.9.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''';

const _l10nYamlSource = '''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-dir: lib/generated
output-localization-file: app.dart
output-class: AppLocalizations
nullable-getter: true
synthetic-package: false
''';

const _arbSource =
    '{"@@locale":"en","dead":"Dead","@dead":{"description":"D"}}\n';
