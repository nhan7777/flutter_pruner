import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../analysis/analysis_snapshot.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_evidence_verdict.dart';
import 'l10n_family_preflight.dart';
import 'l10n_family_snapshot.dart';
import 'l10n_generation_config.dart';
import 'l10n_generator.dart';
import 'l10n_output_reconciler.dart';
import 'l10n_snapshot_revalidator.dart';
import 'l10n_stage_materializer.dart';
import 'l10n_stage_verifier.dart';
import 'l10n_toolchain.dart';

const _pipelineStage = 'evidence-pipeline';

/// Creates a toolchain-bound stage materializer after exact resolution.
typedef L10nStageMaterializerFactory =
    L10nStageMaterializer Function(L10nToolchainResolved toolchain);

/// Immutable request for one internal l10n mutation-evidence evaluation.
final class L10nEvidenceRequest {
  /// Freezes the scan, exact selection, SDK registry, and selection evidence.
  L10nEvidenceRequest({
    required this.analysis,
    required Iterable<String> selectedNodeIds,
    required this.sdkRegistry,
    required this.toolchainSelection,
    this.toolchainAuthorityRoot,
  }) : selectedNodeIds = List<String>.unmodifiable(selectedNodeIds);

  /// Unchanged completed analysis whose graph facts authorize the request.
  final AnalysisSnapshot analysis;

  /// Exact requested l10n node IDs in caller order.
  final List<String> selectedNodeIds;

  /// Provisioned SDK registry used for exact toolchain resolution.
  final L10nSdkRegistry sdkRegistry;

  /// Frozen selector or retained evidence used to choose the toolchain.
  final L10nToolchainSelection toolchainSelection;

  /// Repository authority containing project selectors for a nested package.
  ///
  /// When absent, the analyzed package root remains the selector authority.
  /// A supplied root must be the same directory or a canonical ancestor of
  /// [AnalysisSnapshot.project]'s root.
  final Directory? toolchainAuthorityRoot;
}

/// Runs the complete internal l10n mutation-evidence transaction.
final class L10nEvidencePipeline {
  /// Creates a pipeline with a fixed injected materializer.
  ///
  /// This constructor matches deterministic unit-test composition. Production
  /// should use [L10nEvidencePipeline.withMaterializerFactory] so staging is
  /// bound to the toolchain resolved for the request.
  L10nEvidencePipeline({
    required L10nToolchainResolver toolchainResolver,
    required L10nGenerationConfigLoader configLoader,
    required L10nFamilySnapshotter snapshotter,
    required L10nStageMaterializer materializer,
    required L10nGenerator generator,
    required L10nOutputReconciler reconciler,
    required L10nStageVerifier verifier,
    required L10nSnapshotRevalidator revalidator,
  }) : this.withMaterializerFactory(
         toolchainResolver: toolchainResolver,
         configLoader: configLoader,
         snapshotter: snapshotter,
         materializerFactory: (_) => materializer,
         generator: generator,
         reconciler: reconciler,
         verifier: verifier,
         revalidator: revalidator,
       );

  /// Creates a production-capable pipeline whose materializer is bound only
  /// after exact toolchain resolution.
  L10nEvidencePipeline.withMaterializerFactory({
    required L10nToolchainResolver toolchainResolver,
    required L10nGenerationConfigLoader configLoader,
    required L10nFamilySnapshotter snapshotter,
    required L10nStageMaterializerFactory materializerFactory,
    required L10nGenerator generator,
    required L10nOutputReconciler reconciler,
    required L10nStageVerifier verifier,
    required L10nSnapshotRevalidator revalidator,
  }) : _toolchainResolver = toolchainResolver,
       _configLoader = configLoader,
       _snapshotter = snapshotter,
       _materializerFactory = materializerFactory,
       _generator = generator,
       _reconciler = reconciler,
       _verifier = verifier,
       _revalidator = revalidator;

  final L10nToolchainResolver _toolchainResolver;
  final L10nGenerationConfigLoader _configLoader;
  final L10nFamilySnapshotter _snapshotter;
  final L10nStageMaterializerFactory _materializerFactory;
  final L10nGenerator _generator;
  final L10nOutputReconciler _reconciler;
  final L10nStageVerifier _verifier;
  final L10nSnapshotRevalidator _revalidator;

  /// Evaluates one request without mutating its original project tree.
  Future<L10nEvidenceEvaluation> evaluate(L10nEvidenceRequest request) async {
    final requestFailures = _validateRequest(request);
    if (requestFailures.isNotEmpty) {
      return _earlyRejection(requestFailures);
    }

    final state = _PipelineState(request);
    var boundary = 'toolchain-resolution';
    try {
      final resolution = await _toolchainResolver.resolve(
        originalProjectRoot: _toolchainAuthorityRoot(request),
        sdkRegistry: request.sdkRegistry,
        selection: request.toolchainSelection,
      );
      switch (resolution) {
        case L10nToolchainRejected(:final failure):
          state.failures.add(failure);
        case L10nToolchainResolved():
          state.toolchain = resolution;
          if (!_isSha256(resolution.identitySha256)) {
            state.failures.add(
              const L10nEvidenceFailure(
                code: L10nEvidenceRejectionCode.toolchainDrift,
                stage: 'toolchain-resolution',
                detailCode: 'resolved-toolchain-identity-invalid',
              ),
            );
          }
      }

      if (state.failures.isEmpty) {
        boundary = 'generation-config-load';
        final loaded = await _configLoader.load(
          project: request.analysis.project,
          toolchain: state.toolchain!.machineIdentity,
        );
        switch (loaded) {
          case L10nGenerationConfigRejected(:final failures):
            state.failures.addAll(failures);
          case L10nGenerationConfigReady(:final config):
            state.config = config;
        }
      }

      if (state.failures.isEmpty) {
        boundary = 'family-snapshot-capture';
        final captured = await _snapshotter.capture(
          analysis: request.analysis,
          selectedNodeIds: request.selectedNodeIds,
          config: state.config!,
          toolchain: state.toolchain!,
        );
        switch (captured) {
          case L10nFamilySnapshotRejected(:final failures):
            state.failures.addAll(failures);
          case L10nFamilySnapshotReady(:final snapshot):
            state.snapshot = snapshot;
        }
      }

      if (state.failures.isEmpty) {
        boundary = 'stage-materialization';
        state.materializer = _materializerFactory(state.toolchain!);
        final materialized = await state.materializer!.materialize(
          state.snapshot!,
        );
        state.cleanupLease = materialized.cleanupLease;
        state.pair = materialized.pair;
        state.failures.addAll(materialized.failures);
        if (!materialized.ready && materialized.failures.isEmpty) {
          state.failures.add(
            const L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.materializationFailed,
              stage: 'stage-materialization',
              detailCode: 'materialization-result-incomplete',
            ),
          );
        }
      }

      if (state.failures.isEmpty) {
        boundary = 'baseline-generation';
        state.baselineRun = await _generator.generate(
          stage: state.pair!.baseline,
          toolchain: state.toolchain!,
          phase: L10nGenerationPhase.baseline,
          outputPaths: state.pair!.baseline.generationOutputPaths,
        );
        state.failures.addAll(state.baselineRun!.failures);
      }

      if (state.failures.isEmpty) {
        boundary = 'candidate-arb-installation';
        state.failures.addAll(
          await state.materializer!.installCandidateArbs(
            state.pair!.candidate,
            state.snapshot!.mutationPlan.candidateArbBytes,
          ),
        );
      }

      if (state.failures.isEmpty) {
        boundary = 'candidate-generation';
        state.candidateRun = await _generator.generate(
          stage: state.pair!.candidate,
          toolchain: state.toolchain!,
          phase: L10nGenerationPhase.candidate,
          outputPaths: state.pair!.candidate.generationOutputPaths,
        );
        state.failures.addAll(state.candidateRun!.failures);
      }

      if (state.failures.isEmpty) {
        boundary = 'output-reconciliation';
        final reconciled = _reconciler.reconcile(
          liveSnapshot: state.snapshot!,
          allowlist: L10nGenerationAllowlist(
            replacementOutputPaths: state.snapshot!.expectedGeneratedPaths,
            untranslatedSidecarPath: state.snapshot!.optionalUntranslatedPath,
            provenUnrelatedSiblingPaths:
                state.snapshot!.provenUnrelatedOutputSiblings,
          ),
          baseline: state.baselineRun!,
          candidate: state.candidateRun!,
        );
        switch (reconciled) {
          case L10nReconciliationRejected(:final failures):
            state.failures.addAll(failures);
          case L10nReconciliationReady(:final changeSet):
            state.pendingChangeSet = changeSet;
        }
      }

      if (state.failures.isEmpty) {
        boundary = 'baseline-stage-verification';
        try {
          state.baselineVerification = await _verifier.verify(
            stage: state.pair!.baseline,
            snapshot: state.snapshot!,
            expectedRemovedKeys: const {},
            toolchain: state.toolchain!,
          );
          state.failures.addAll(state.baselineVerification!.failures);
        } on Object {
          state.failures.add(_unexpectedBoundaryFailure(boundary));
        }

        boundary = 'candidate-stage-verification';
        try {
          state.candidateVerification = await _verifier.verify(
            stage: state.pair!.candidate,
            snapshot: state.snapshot!,
            expectedRemovedKeys: state.snapshot!.selectedKeys,
            toolchain: state.toolchain!,
          );
          state.failures.addAll(state.candidateVerification!.failures);
        } on Object {
          state.failures.add(_unexpectedBoundaryFailure(boundary));
        }

        if (state.baselineVerification != null &&
            state.candidateVerification != null) {
          boundary = 'stage-verification-comparison';
          try {
            state.comparisonFailures = L10nStageVerificationComparator.compare(
              baseline: state.baselineVerification!,
              candidate: state.candidateVerification!,
            );
            state.failures.addAll(state.comparisonFailures);
          } on Object {
            state.failures.add(_unexpectedBoundaryFailure(boundary));
          }
        }
      }
    } on Object {
      state.failures.add(_unexpectedBoundaryFailure(boundary));
    } finally {
      await _revalidateOriginalAuthorities(state, _revalidator);
      await _cleanupStages(state);
    }

    if (state.failures.isEmpty && state.pendingChangeSet == null) {
      state.failures.add(
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.internalFailure,
          stage: _pipelineStage,
          detailCode: 'accepted-change-set-missing',
        ),
      );
    }
    return _finalize(state);
  }
}

final class _PipelineState {
  _PipelineState(this.request);

  final L10nEvidenceRequest request;
  final List<L10nEvidenceFailure> failures = [];
  L10nToolchainResolved? toolchain;
  L10nGenerationConfig? config;
  L10nFamilySnapshot? snapshot;
  L10nStageMaterializer? materializer;
  L10nStageCleanupLease? cleanupLease;
  L10nStagePair? pair;
  L10nGenerationRun? baselineRun;
  L10nGenerationRun? candidateRun;
  L10nWitnessedChangeSet? pendingChangeSet;
  L10nStageVerificationResult? baselineVerification;
  L10nStageVerificationResult? candidateVerification;
  List<L10nEvidenceFailure> comparisonFailures = const [];
  L10nSnapshotStillCurrent? revalidation;
  L10nStageCleanupResult? cleanup;
}

Future<void> _revalidateOriginalAuthorities(
  _PipelineState state,
  L10nSnapshotRevalidator revalidator,
) async {
  final snapshot = state.snapshot;
  final toolchain = state.toolchain;
  if (snapshot == null || toolchain == null) return;
  try {
    final result = await revalidator.revalidate(
      originalProjectRoot: state.request.analysis.project.root,
      toolchainAuthorityRoot: state.request.toolchainAuthorityRoot,
      snapshot: snapshot,
      toolchain: toolchain,
    );
    switch (result) {
      case L10nSnapshotDrifted(:final failures):
        state.failures.addAll(failures);
      case L10nSnapshotStillCurrent():
        var identitiesMatch = true;
        if (result.sourceIdentity !=
            const L10nSnapshotSourceIdentityProjector().project(snapshot)) {
          identitiesMatch = false;
          state.failures.add(
            const L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.sourceDrift,
              stage: 'snapshot-revalidation',
              detailCode: 'revalidated-source-identity-mismatch',
            ),
          );
        }
        if (result.packageResolutionIdentity !=
            snapshot.packageResolutionIdentity) {
          identitiesMatch = false;
          state.failures.add(
            const L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.packageResolutionDrift,
              stage: 'snapshot-revalidation',
              detailCode: 'revalidated-package-identity-mismatch',
            ),
          );
        }
        if (result.toolchainIdentity != snapshot.toolchainIdentity) {
          identitiesMatch = false;
          state.failures.add(
            const L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.toolchainDrift,
              stage: 'snapshot-revalidation',
              detailCode: 'revalidated-toolchain-identity-mismatch',
            ),
          );
        }
        if (identitiesMatch) state.revalidation = result;
    }
  } on Object {
    state.failures.add(
      const L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.internalFailure,
        stage: 'snapshot-revalidation',
        detailCode: 'revalidation-unexpected-failure',
      ),
    );
  }
}

Future<void> _cleanupStages(_PipelineState state) async {
  final lease = state.cleanupLease;
  final materializer = state.materializer;
  if (lease == null || materializer == null) return;
  final registeredRoles = lease.createdRoots.map((root) => root.role).toSet();
  final baselineRemovalRequired =
      state.pair != null || registeredRoles.contains(L10nStageRole.baseline);
  final candidateRemovalRequired =
      state.pair != null || registeredRoles.contains(L10nStageRole.candidate);
  try {
    state.cleanup = await materializer.cleanup(lease);
    state.failures.addAll(state.cleanup!.failures);
    if (state.cleanup!.failures.isEmpty &&
        ((baselineRemovalRequired && !state.cleanup!.baselineRemoved) ||
            (candidateRemovalRequired && !state.cleanup!.candidateRemoved))) {
      state.failures.add(
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.cleanupFailed,
          stage: 'stage-cleanup',
          detailCode: 'cleanup-result-incomplete',
        ),
      );
    }
  } on Object {
    state.failures.add(
      const L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.cleanupFailed,
        stage: 'stage-cleanup',
        detailCode: 'cleanup-unexpected-failure',
      ),
    );
  }
}

L10nEvidenceEvaluation _finalize(_PipelineState state) {
  try {
    final accepted = state.failures.isEmpty;
    final verdict = L10nEvidenceVerdict(
      status: accepted
          ? L10nEvidenceStatus.accepted
          : L10nEvidenceStatus.rejected,
      failures: state.failures,
      familyFingerprint: _safeIdentity(
        state.snapshot?.familyFingerprint,
        'family',
      ),
      selectionFingerprint: _safeIdentity(
        state.snapshot?.selectionFingerprint,
        'selection',
      ),
      configurationIdentity: _safeIdentity(
        state.snapshot?.configurationIdentity ??
            state.config?.configurationIdentity,
        'configuration',
      ),
      packageResolutionIdentity: _safeIdentity(
        state.snapshot?.packageResolutionIdentity,
        'packages',
      ),
      toolchainIdentity: _safeIdentity(
        state.toolchain?.identitySha256,
        'toolchain',
      ),
      baselineInventoryHashes: _inventoryHashes(state.baselineRun),
      candidateInventoryHashes: _inventoryHashes(state.candidateRun),
      mutationSummary: _mutationSummary(state),
      verificationSummary: _verificationSummary(state),
      timingAndResourceMetrics: _timingAndResourceMetrics(state),
    );
    return L10nEvidenceEvaluation(
      verdict: verdict,
      witnessedChangeSet: accepted ? state.pendingChangeSet : null,
    );
  } on Object {
    return _earlyRejection(const [
      L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.internalFailure,
        stage: _pipelineStage,
        detailCode: 'verdict-finalization-failed',
      ),
    ]);
  }
}

Map<String, String> _inventoryHashes(L10nGenerationRun? run) => run == null
    ? const {}
    : <String, String>{
        'after': run.after.fingerprint,
        'before': run.before.fingerprint,
      };

Map<String, Object?> _mutationSummary(_PipelineState state) {
  final snapshot = state.snapshot;
  if (snapshot == null) return const {};
  final changeSet = state.pendingChangeSet;
  return <String, Object?>{
    'generatedReplacementPaths': snapshot.expectedGeneratedPaths.toList(
      growable: false,
    ),
    'mutationFingerprint': snapshot.mutationPlan.mutationFingerprint,
    'removalsByPath': <String, Object?>{
      for (final entry in snapshot.mutationPlan.removalsByPath.entries)
        entry.key: <Object?>[
          for (final removal in entry.value)
            <String, Object?>{
              'decodedKey': removal.decodedKey,
              'endExclusive': removal.span.endExclusive,
              'kind': removal.decodedKey.startsWith('@')
                  ? 'companion'
                  : 'message',
              'start': removal.span.start,
            },
        ],
    },
    'selectedKeys': snapshot.selectedKeys.toList(growable: false),
    if (changeSet != null) ...<String, Object?>{
      'arbReplacementPaths': changeSet.arbReplacements.keys.toList(
        growable: false,
      ),
      'witnessedChangeSetFingerprint': changeSet.fingerprint,
    },
  };
}

Map<String, Object?> _verificationSummary(
  _PipelineState state,
) => <String, Object?>{
  if (state.baselineVerification case final result?)
    'baseline': _verificationProjection(result),
  if (state.candidateVerification case final result?)
    'candidate': _verificationProjection(result),
  'comparisonFailures': <Object?>[
    for (final failure in state.comparisonFailures) _failureProjection(failure),
  ],
  if (state.revalidation case final current?)
    'revalidation': <String, Object?>{
      'packageResolutionIdentity': current.packageResolutionIdentity,
      'sourceIdentity': current.sourceIdentity,
      'toolchainIdentity': current.toolchainIdentity,
    },
};

Map<String, Object?> _verificationProjection(
  L10nStageVerificationResult result,
) => <String, Object?>{
  'accepted': result.accepted,
  'analyzerRootIdentity': result.analyzerRootIdentity,
  'failures': <Object?>[
    for (final failure in result.failures) _failureProjection(failure),
  ],
  'packageResolutionIdentity': result.packageResolutionIdentity,
  'policyIdentity': result.policyIdentity,
  'publishableAfterIdentity': result.publishableAfterIdentity,
  'publishableBeforeIdentity': result.publishableBeforeIdentity,
  'summary': result.summary,
  'toolchainIdentity': result.toolchainIdentity,
};

Map<String, Object?> _failureProjection(L10nEvidenceFailure failure) =>
    <String, Object?>{
      'code': failure.code.name,
      'detailCode': failure.detailCode,
      if (failure.relativePath != null) 'relativePath': failure.relativePath,
      'stage': failure.stage,
    };

Map<String, Object?> _timingAndResourceMetrics(_PipelineState state) =>
    <String, Object?>{
      'analysisElapsedMicros': state.request.analysis.elapsedMicros,
      if (state.baselineRun case final run?)
        'baselineGeneration': run.toRedactedJson(),
      if (state.candidateRun case final run?)
        'candidateGeneration': run.toRedactedJson(),
      if (state.pair case final pair?) 'copiedBytes': pair.copiedBytes,
      if (state.cleanup case final cleanup?)
        'cleanup': <String, Object?>{
          'baselineRemoved': cleanup.baselineRemoved,
          'candidateRemoved': cleanup.candidateRemoved,
          'failureCount': cleanup.failures.length,
        },
    };

L10nEvidenceFailure _unexpectedBoundaryFailure(String boundary) =>
    L10nEvidenceFailure(
      code: L10nEvidenceRejectionCode.internalFailure,
      stage: boundary,
      detailCode: 'boundary-unexpected-failure',
    );

String _safeIdentity(String? value, String authority) =>
    value != null && _isSha256(value) ? value : _unavailableIdentity(authority);

List<L10nEvidenceFailure> _validateRequest(L10nEvidenceRequest request) {
  if (request.selectedNodeIds.isEmpty) {
    return const [
      L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.invalidSelection,
        stage: _pipelineStage,
        detailCode: 'selection-empty',
      ),
    ];
  }
  if (request.selectedNodeIds.toSet().length !=
      request.selectedNodeIds.length) {
    return const [
      L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.invalidSelection,
        stage: _pipelineStage,
        detailCode: 'selection-duplicate',
      ),
    ];
  }
  final authorityRoot = request.toolchainAuthorityRoot;
  if (authorityRoot != null) {
    try {
      final canonicalAuthority = p.normalize(
        authorityRoot.resolveSymbolicLinksSync(),
      );
      final canonicalProject = p.normalize(
        request.analysis.project.root.resolveSymbolicLinksSync(),
      );
      if (!p.equals(canonicalAuthority, canonicalProject) &&
          !p.isWithin(canonicalAuthority, canonicalProject)) {
        return const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.toolchainUnavailable,
            stage: _pipelineStage,
            detailCode: 'toolchain-authority-root-not-ancestor',
          ),
        ];
      }
    } on FileSystemException {
      return const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          stage: _pipelineStage,
          detailCode: 'toolchain-authority-root-unavailable',
        ),
      ];
    }
  }
  return const [];
}

Directory _toolchainAuthorityRoot(L10nEvidenceRequest request) =>
    request.toolchainAuthorityRoot ?? request.analysis.project.root;

L10nEvidenceEvaluation _earlyRejection(
  Iterable<L10nEvidenceFailure> failures,
) => L10nEvidenceEvaluation(
  verdict: L10nEvidenceVerdict(
    status: L10nEvidenceStatus.rejected,
    failures: failures,
    familyFingerprint: _unavailableIdentity('family'),
    selectionFingerprint: _unavailableIdentity('selection'),
    configurationIdentity: _unavailableIdentity('configuration'),
    packageResolutionIdentity: _unavailableIdentity('packages'),
    toolchainIdentity: _unavailableIdentity('toolchain'),
    baselineInventoryHashes: const {},
    candidateInventoryHashes: const {},
    mutationSummary: const {},
    verificationSummary: const {},
    timingAndResourceMetrics: const {},
  ),
);

String _unavailableIdentity(String authority) => sha256
    .convert(utf8.encode('l10n-evidence-unavailable:$authority'))
    .toString();

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
