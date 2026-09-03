/// Production scanner, same-snapshot evaluator, and single-use corpus bridge.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_pipeline.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_preflight.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/apply/mode_apply_policy.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../l10n_mutation_readiness.dart';
import 'corpus_mutation_evidence.dart' as corpus;
import 'l10n_mutation_manifest.dart';
import 'l10n_readiness_change_set_rebaser.dart';
import 'l10n_readiness_negative_fixtures.dart';

typedef ProductionL10nAnalysisRunner =
    Future<AnalysisSnapshot> Function(ProjectContext project);
typedef ProductionL10nPipelineRunner =
    Future<L10nEvidenceEvaluation> Function(L10nEvidenceRequest request);

final Stopwatch _productionClock = Stopwatch()..start();

/// One disposable project authority shared by scan, evaluation, and corpus.
final class ProductionL10nReadinessProjectView
    implements L10nReadinessProjectView {
  ProductionL10nReadinessProjectView({
    required this.projectId,
    required this.manifest,
    required this.corpusView,
    required this.project,
    required this.canonicalFlutterExecutable,
    required this.sdkRegistry,
    required this.toolchainSelection,
  }) {
    final expectedPackageRoot = manifest.packageRootRelative == '.'
        ? corpusView.repositoryRoot.path
        : p.join(corpusView.repositoryRoot.path, manifest.packageRootRelative);
    if (projectId != manifest.id ||
        corpusView.repositoryRevision != manifest.repositoryRevision ||
        !p.equals(corpusView.packageRoot.path, expectedPackageRoot) ||
        project.root.resolveSymbolicLinksSync() !=
            corpusView.packageRoot.resolveSymbolicLinksSync() ||
        sdkRegistry.executableFor(Version.parse(manifest.toolchainVersion)) !=
            canonicalFlutterExecutable) {
      throw ArgumentError('Production project view authority is inconsistent.');
    }
  }

  @override
  final String projectId;
  final L10nMutationProjectManifest manifest;
  final corpus.CorpusProjectView corpusView;
  final ProjectContext project;
  final String canonicalFlutterExecutable;
  final L10nSdkRegistry sdkRegistry;
  final L10nToolchainSelection toolchainSelection;

  AnalysisSnapshot? _analysisSnapshot;
  L10nStaticScanResult? _scanResult;
  bool _evaluationStarted = false;
  String? _authorizedSelectionIdentity;
  L10nWitnessedChangeSet? _authorizedChangeSet;
  bool _corpusConsumed = false;
  bool _disposed = false;

  AnalysisSnapshot? get analysisSnapshot => _analysisSnapshot;

  void bindScanResult(AnalysisSnapshot snapshot, L10nStaticScanResult scan) {
    if (_disposed ||
        _analysisSnapshot != null ||
        _scanResult != null ||
        !identical(snapshot.project, project) ||
        !identical(scan.analysisAuthority, snapshot)) {
      throw StateError('Production scan authority cannot be rebound.');
    }
    _analysisSnapshot = snapshot;
    _scanResult = scan;
  }

  void _beginEvaluation(L10nStaticScanResult scan) {
    if (_disposed || _evaluationStarted || !identical(_scanResult, scan)) {
      throw StateError('Production scan result is foreign or consumed.');
    }
    _evaluationStarted = true;
  }

  void _authorizeMutation(
    String selectionIdentity,
    L10nWitnessedChangeSet changeSet,
  ) {
    if (_disposed ||
        _corpusConsumed ||
        !_evaluationStarted ||
        _analysisSnapshot == null) {
      throw StateError('Production mutation authority is unavailable.');
    }
    _authorizedSelectionIdentity = selectionIdentity;
    _authorizedChangeSet = changeSet;
  }

  void _consumeMutation(
    String selectionIdentity,
    L10nWitnessedChangeSet changeSet,
  ) {
    if (_disposed ||
        _corpusConsumed ||
        _authorizedSelectionIdentity != selectionIdentity ||
        !identical(_authorizedChangeSet, changeSet)) {
      throw StateError('Production corpus authority is stale or consumed.');
    }
    _corpusConsumed = true;
    _authorizedSelectionIdentity = null;
    _authorizedChangeSet = null;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    if (!await corpusView.dispose()) {
      throw StateError('Disposable production view could not be released.');
    }
    _disposed = true;
  }
}

/// Provisions exact-revision corpus views and binds package/toolchain context.
final class ProductionL10nReadinessProjectViewFactory {
  ProductionL10nReadinessProjectViewFactory({
    required this.manifest,
    required Map<String, Directory> retainedRepositoriesByProject,
    required Map<String, File> sdkFlutterByVersion,
    corpus.CorpusProjectViewFactory? viewFactory,
  }) : retainedRepositoriesByProject = Map.unmodifiable(
         retainedRepositoriesByProject,
       ),
       sdkFlutterByVersion = Map.unmodifiable(sdkFlutterByVersion),
       _viewFactory = viewFactory ?? corpus.DefaultCorpusProjectViewFactory();

  final L10nMutationManifest manifest;
  final Map<String, Directory> retainedRepositoriesByProject;
  final Map<String, File> sdkFlutterByVersion;
  final corpus.CorpusProjectViewFactory _viewFactory;

  Future<ProductionL10nReadinessProjectView> provision(String projectId) async {
    final project = manifest.projectsById[projectId];
    final retained = retainedRepositoriesByProject[projectId];
    if (project == null || retained == null) {
      throw StateError('Unknown production project authority.');
    }
    final flutter = sdkFlutterByVersion[project.toolchainVersion];
    if (flutter == null) {
      throw StateError('Production SDK authority is unavailable.');
    }
    final created = await _viewFactory.create(
      project: project,
      retainedRepositoryPath: retained.path,
      canonicalFlutterExecutable: flutter.path,
    );
    final corpusView = switch (created) {
      corpus.CorpusProjectViewReady(:final view) => view,
      corpus.CorpusProjectViewRejected(:final outcome) => throw StateError(
        'Production corpus view provisioning was rejected: '
        '${outcome.status.name}'
        '${Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1' ? ': ${outcome.commandResults}' : ''}.',
      ),
    };
    try {
      final context = await ProjectContext.load(
        corpusView.packageRoot,
        configFile: _scannerCoverageConfigFile(project, corpusView),
      );
      return ProductionL10nReadinessProjectView(
        projectId: projectId,
        manifest: project,
        corpusView: corpusView,
        project: context,
        canonicalFlutterExecutable: flutter.path,
        sdkRegistry: L10nSdkRegistry({
          for (final entry in sdkFlutterByVersion.entries)
            Version.parse(entry.key): entry.value.path,
        }),
        toolchainSelection: _toolchainSelection(project),
      );
    } catch (error, stackTrace) {
      if (!await corpusView.dispose()) {
        throw StateError('Rejected production view could not be released.');
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

File _scannerCoverageConfigFile(
  L10nMutationProjectManifest project,
  corpus.CorpusProjectView corpusView,
) {
  const fileName = 'flutter_pruner_v2_accuracy.yaml';
  final relativePath = project.packageRootRelative == '.'
      ? fileName
      : p.posix.join(project.packageRootRelative, fileName);
  final overlays = project.fixtureOverlays
      .where((overlay) => overlay.relativePath == relativePath)
      .toList(growable: false);
  if (overlays.length != 1 ||
      overlays.single.purpose != 'scanner coverage authority') {
    throw StateError('Production scanner coverage authority is unavailable.');
  }
  final file = File(
    p.joinAll([corpusView.repositoryRoot.path, ...p.posix.split(relativePath)]),
  );
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      sha256.convert(file.readAsBytesSync()).toString() !=
          overlays.single.sha256) {
    throw StateError('Production scanner coverage authority has drifted.');
  }
  final canonical = file.resolveSymbolicLinksSync();
  if (!p.equals(canonical, p.normalize(file.absolute.path)) ||
      !p.equals(file.parent.path, corpusView.packageRoot.path)) {
    throw StateError('Production scanner coverage authority is unsafe.');
  }
  return file;
}

/// Runs the genuine l10n scanner once and retains that exact snapshot.
final class ProductionL10nHarnessScanner implements L10nHarnessScanner {
  ProductionL10nHarnessScanner() : _analyze = _runProductionL10nAnalysis;

  ProductionL10nHarnessScanner.testing({
    required ProductionL10nAnalysisRunner analyze,
  }) : _analyze = analyze;

  final ProductionL10nAnalysisRunner _analyze;

  @override
  Future<L10nStaticScanResult> scan(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> oracleCases,
  ) async {
    final productionView = _requireProductionView(view);
    if (productionView.analysisSnapshot != null ||
        oracleCases.any((entry) => entry.projectId != view.projectId)) {
      throw StateError('Production scanner authority is inconsistent.');
    }
    final analysis = await _analyze(productionView.project);
    if (!identical(analysis.project, productionView.project)) {
      throw StateError('Production scanner returned a foreign project.');
    }
    final nodes = analysis.graph
        .nodesOfKind(NodeKind.localizationKey)
        .toList(growable: false);
    final nodeByKey = <String, GraphNode>{};
    for (final node in nodes) {
      final key = node.metadata['key'];
      if (key is! String || nodeByKey.putIfAbsent(key, () => node) != node) {
        throw StateError('Production l10n graph key authority is ambiguous.');
      }
    }
    final actualByOracle = <String, String>{};
    for (final oracleCase in oracleCases) {
      final node = nodeByKey[oracleCase.decodedKey];
      if (node != null) actualByOracle[oracleCase.caseId] = node.id;
    }
    final l10nFindings = analysis.findings
        .where((finding) => finding.reportingAdapterId == 'l10n')
        .toList(growable: false);
    final findingIds = l10nFindings.map((finding) => finding.node.id).toSet();
    final candidateOracleIds = <String>{
      for (final entry in actualByOracle.entries)
        if (findingIds.contains(entry.value)) entry.key,
    };
    final authorityIdentity = const L10nAnalysisFingerprintProjector().project(
      analysis: analysis,
      familyNodeIds: nodes.map((node) => node.id).toSet(),
    );
    final result = L10nStaticScanResult(
      authorityIdentity: authorityIdentity,
      analysisAuthority: analysis,
      actualNodeIdByOracleCaseId: actualByOracle,
      candidateOracleCaseIds: candidateOracleIds,
      publicSafeL10n: l10nFindings
          .where((finding) => finding.confidence == Confidence.safe)
          .length,
      publicHighL10n: l10nFindings
          .where((finding) => finding.confidence == Confidence.high)
          .length,
      publicApplyEligibleL10n: l10nFindings
          .where(
            (finding) =>
                ModeApplyPolicy.allows(analysis.project.analysisMode, finding),
          )
          .length,
      publicProposedL10nActions: l10nFindings
          .where((finding) => finding.proposedAction != null)
          .length,
    );
    productionView.bindScanResult(analysis, result);
    return result;
  }
}

/// Evaluates only node IDs selected from the exact retained scan snapshot.
final class ProductionL10nEvidenceEvaluator implements L10nEvidenceEvaluator {
  factory ProductionL10nEvidenceEvaluator() {
    const resolver = DefaultL10nToolchainResolver();
    const configLoader = DefaultL10nGenerationConfigLoader();
    final pipeline = L10nEvidencePipeline.withMaterializerFactory(
      toolchainResolver: resolver,
      configLoader: configLoader,
      snapshotter: const L10nFamilyPreflight(),
      materializerFactory: (toolchain) =>
          DefaultL10nStageMaterializer(toolchain: toolchain),
      generator: const ProcessL10nGenerator(),
      reconciler: const DefaultL10nOutputReconciler(),
      verifier: DefaultL10nStageVerifier(
        inspector: const L10nGeneratedMemberInspector(),
      ),
      revalidator: DefaultL10nSnapshotRevalidator(
        toolchainResolver: resolver,
        configLoader: configLoader,
      ),
    );
    return ProductionL10nEvidenceEvaluator._(
      evaluate: pipeline.evaluate,
      monotonicMicros: _readProductionMicros,
    );
  }

  ProductionL10nEvidenceEvaluator.testing({
    required ProductionL10nPipelineRunner evaluate,
    required int Function() monotonicMicros,
  }) : this._(evaluate: evaluate, monotonicMicros: monotonicMicros);

  ProductionL10nEvidenceEvaluator._({
    required ProductionL10nPipelineRunner evaluate,
    required int Function() monotonicMicros,
  }) : _evaluate = evaluate,
       _monotonicMicros = monotonicMicros;

  final ProductionL10nPipelineRunner _evaluate;
  final int Function() _monotonicMicros;

  @override
  Future<L10nInternalEvidenceResult> evaluateIndividual(
    L10nReadinessProjectView view,
    L10nReadinessOracleCase oracleCase,
    L10nStaticScanResult scan,
  ) => _evaluateSelection(
    view: view,
    selectionIdentity: oracleCase.caseId,
    oracleCases: [oracleCase],
    scan: scan,
  );

  @override
  Future<L10nInternalEvidenceResult> evaluateFamily(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> positiveCases,
    L10nStaticScanResult scan,
  ) => _evaluateSelection(
    view: view,
    selectionIdentity: 'family:${view.projectId}',
    oracleCases: positiveCases,
    scan: scan,
  );

  Future<L10nInternalEvidenceResult> _evaluateSelection({
    required L10nReadinessProjectView view,
    required String selectionIdentity,
    required List<L10nReadinessOracleCase> oracleCases,
    required L10nStaticScanResult scan,
  }) async {
    final productionView = _requireProductionView(view);
    final analysis = productionView.analysisSnapshot;
    if (analysis == null ||
        !identical(scan.analysisAuthority, analysis) ||
        oracleCases.isEmpty ||
        oracleCases.any(
          (entry) =>
              entry.projectId != view.projectId || !entry.mutationPositive,
        )) {
      throw StateError('Production evaluator scan authority is invalid.');
    }
    final selectedNodeIds = <String>[];
    for (final oracleCase in oracleCases) {
      final nodeId = scan.actualNodeIdByOracleCaseId[oracleCase.caseId];
      if (nodeId == null ||
          !scan.candidateOracleCaseIds.contains(oracleCase.caseId)) {
        throw StateError('Production evaluator selection is incomplete.');
      }
      selectedNodeIds.add(nodeId);
    }
    if (selectedNodeIds.toSet().length != selectedNodeIds.length) {
      throw StateError('Production evaluator selection aliases nodes.');
    }
    productionView._beginEvaluation(scan);
    final started = _monotonicMicros();
    final evaluation = await _evaluate(
      L10nEvidenceRequest(
        analysis: analysis,
        selectedNodeIds: selectedNodeIds,
        sdkRegistry: productionView.sdkRegistry,
        toolchainSelection: productionView.toolchainSelection,
        toolchainAuthorityRoot: productionView.corpusView.repositoryRoot,
      ),
    );
    final finished = _monotonicMicros();
    final accepted = evaluation.verdict.status == L10nEvidenceStatus.accepted;
    final changeSet = evaluation.witnessedChangeSet;
    if (accepted != (changeSet != null)) {
      throw StateError('Production pipeline mutation authority is invalid.');
    }
    if (changeSet != null) {
      productionView._authorizeMutation(selectionIdentity, changeSet);
    }
    final metrics = evaluation.verdict.timingAndResourceMetrics;
    return L10nInternalEvidenceResult(
      selectionIdentity: selectionIdentity,
      accepted: accepted,
      mutationAuthority: changeSet,
      bytesCopied: _nonNegativeMetric(metrics['copiedBytes']),
      stageMicros: finished <= started ? 0 : finished - started,
      baselineGeneratorMicros: _generationMetric(
        metrics,
        'baselineGeneration',
        'elapsedMicros',
      ),
      candidateGeneratorMicros: _generationMetric(
        metrics,
        'candidateGeneration',
        'elapsedMicros',
      ),
      sampledPeakRssBytes: _peakGenerationRss(metrics),
      verdictIdentity: _hashCanonical(evaluation.verdict.toInternalJson()),
      verdictFailures: [
        for (final failure in evaluation.verdict.failures)
          L10nVerdictFailure(
            code: failure.code.name,
            stage: failure.stage,
            detailCode: failure.detailCode,
            relativePath: failure.relativePath,
          ),
      ],
    );
  }
}

/// Rebases package paths once, then consumes the view for one corpus run.
final class ProductionL10nCorpusEvidenceRunner
    implements L10nCorpusEvidenceRunner {
  ProductionL10nCorpusEvidenceRunner()
    : _runner = corpus.DefaultCorpusMutationEvidenceRunner(),
      _monotonicMicros = _readProductionMicros;

  ProductionL10nCorpusEvidenceRunner.testing({
    required corpus.CorpusMutationEvidenceRunner runner,
    required int Function() monotonicMicros,
  }) : _runner = runner,
       _monotonicMicros = monotonicMicros;

  final corpus.CorpusMutationEvidenceRunner _runner;
  final int Function() _monotonicMicros;

  @override
  Future<L10nCorpusEvidenceResult> run(
    L10nReadinessProjectView view,
    String selectionIdentity,
    L10nInternalEvidenceResult acceptedVerdict,
  ) async {
    final productionView = _requireProductionView(view);
    final changeSet = acceptedVerdict.mutationAuthority;
    if (!acceptedVerdict.accepted ||
        acceptedVerdict.selectionIdentity != selectionIdentity ||
        changeSet is! L10nWitnessedChangeSet) {
      throw StateError(
        'Corpus runner requires an accepted mutation authority.',
      );
    }
    productionView._consumeMutation(selectionIdentity, changeSet);
    final rebased = rebaseL10nWitnessedChangeSetToRepository(
      project: productionView.manifest,
      packageChangeSet: changeSet,
    );
    final started = _monotonicMicros();
    final outcome = await _runner.run(
      project: productionView.manifest,
      view: productionView.corpusView,
      canonicalFlutterExecutable: productionView.canonicalFlutterExecutable,
      changeSet: rebased,
      candidateIdentity: acceptedVerdict.verdictIdentity,
      familyIdentity: 'family:${view.projectId}',
    );
    final finished = _monotonicMicros();
    return L10nCorpusEvidenceResult(
      selectionIdentity: selectionIdentity,
      corpusPolicyPassed:
          outcome.status == corpus.CorpusMutationEvidenceStatus.passed,
      restorationProven: outcome.restorationVerified,
      unexpectedWriteCount: _unexpectedWriteCount(outcome.commandResults),
      originalProjectDrift: false,
      policyMicros: finished <= started ? 0 : finished - started,
      sampledPeakRssBytes: _peakCorpusRss(outcome.commandResults),
      corpusPolicyIdentity: outcome.policyHash,
      restorationIdentity: _hashCanonical(<String, Object?>{
        'afterManagedFingerprint': outcome.afterManagedFingerprint,
        'beforeManagedFingerprint': outcome.beforeManagedFingerprint,
        'restorationVerified': outcome.restorationVerified,
      }),
    );
  }
}

/// Immutable serialized and runtime-only authorities for one production run.
final class ProductionL10nAuthoritySnapshot {
  ProductionL10nAuthoritySnapshot({
    required this.manifest,
    required Map<String, Directory> retainedRepositoriesByProject,
    required Map<String, Object?> identities,
    Map<String, String> projectRuntimeAuthorities = const {},
  }) : retainedRepositoriesByProject = Map.unmodifiable(
         retainedRepositoriesByProject,
       ),
       identities = Map.unmodifiable(identities),
       projectRuntimeAuthorities = Map.unmodifiable(projectRuntimeAuthorities) {
    const projects = {'gitjournal', 'gsy', 'smooth'};
    const identityKeys = {
      'coverageSpecSha256',
      'implementationSha256',
      'manifestSha256',
      'negativeRecipeMatrixSha256',
      'policySetSha256',
      'repositorySetSha256',
      'sdkSetSha256',
    };
    if (!_sameSet(manifest.projectsById.keys.toSet(), projects) ||
        !_sameSet(retainedRepositoriesByProject.keys.toSet(), projects) ||
        !_sameSet(identities.keys.toSet(), identityKeys) ||
        identities.values.any((value) => value is! String || !_isSha(value)) ||
        projectRuntimeAuthorities.isNotEmpty &&
            (!_sameSet(projectRuntimeAuthorities.keys.toSet(), projects) ||
                projectRuntimeAuthorities.values.any(
                  (value) => !_isSha(value),
                ))) {
      throw ArgumentError('Production authority snapshot is incomplete.');
    }
  }

  final L10nMutationManifest manifest;
  final Map<String, Directory> retainedRepositoriesByProject;
  final Map<String, Object?> identities;

  /// Runtime-only per-project authority used to detect drift before each view.
  final Map<String, String> projectRuntimeAuthorities;
}

/// Authority loading and per-view drift checks used by production composition.
abstract interface class ProductionL10nAuthorityLoaderBase {
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  );

  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  );
}

/// Computes manifest, corpus, SDK, policy, coverage, recipe, and code hashes.
final class ProductionL10nAuthorityLoader
    implements ProductionL10nAuthorityLoaderBase {
  ProductionL10nAuthorityLoader()
    : this._(
        processRunner: const ManagedProcessRunner(),
        gitExecutable: Platform.isWindows ? 'git.exe' : '/usr/bin/git',
        enforceRetainedProbeHash: true,
      );

  ProductionL10nAuthorityLoader.testing({
    required ProcessExecutionRunner processRunner,
    required String gitExecutable,
    bool enforceRetainedProbeHash = false,
  }) : this._(
         processRunner: processRunner,
         gitExecutable: gitExecutable,
         enforceRetainedProbeHash: enforceRetainedProbeHash,
       );

  ProductionL10nAuthorityLoader._({
    required ProcessExecutionRunner processRunner,
    required String gitExecutable,
    required bool enforceRetainedProbeHash,
  }) : _processRunner = processRunner,
       _gitExecutable = gitExecutable,
       _enforceRetainedProbeHash = enforceRetainedProbeHash;

  static const _timeout = Duration(minutes: 2);
  static const _outputLimit = 1024 * 1024;

  final ProcessExecutionRunner _processRunner;
  final String _gitExecutable;
  final bool _enforceRetainedProbeHash;

  @override
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  ) async {
    final manifestBefore = await options.manifestFile.readAsBytes();
    final manifestSha = sha256.convert(manifestBefore).toString();
    final manifest = L10nMutationManifest.read(options.manifestFile);
    final retained = _retainedRepositories(options.corpusRoot);
    final repositoryRecords = <String, Object?>{};
    final sdkRecords = <String, Object?>{};
    final projectRuntimeAuthorities = <String, String>{};

    for (final projectId in manifest.projectsById.keys.toList()..sort()) {
      final project = manifest.projectsById[projectId]!;
      final repositoryRecord = await _repositoryRecord(
        retained[projectId]!,
        project,
      );
      repositoryRecords[projectId] = repositoryRecord;
    }
    for (final version in options.sdkFlutterByVersion.keys.toList()..sort()) {
      sdkRecords[version] = await _sdkRecord(
        options.sdkFlutterByVersion[version]!,
        version,
        manifest,
      );
    }
    for (final projectId in manifest.projectsById.keys.toList()..sort()) {
      final project = manifest.projectsById[projectId]!;
      projectRuntimeAuthorities[projectId] = _hashCanonical({
        'projectId': projectId,
        'repository': repositoryRecords[projectId],
        'sdk': sdkRecords[project.toolchainVersion],
      });
    }
    final manifestAfter = await options.manifestFile.readAsBytes();
    if (!_sameBytes(manifestBefore, manifestAfter) ||
        manifestSha != sha256.convert(manifestAfter).toString()) {
      throw StateError('Production manifest changed during authority probing.');
    }
    final identities = <String, Object?>{
      'coverageSpecSha256': await _coverageIdentity(options.repositoryRoot),
      'implementationSha256': await _implementationIdentity(
        options.repositoryRoot,
      ),
      'manifestSha256': manifestSha,
      'negativeRecipeMatrixSha256':
          productionL10nNegativeRecipeAuthorityIdentity(options.repositoryRoot),
      'policySetSha256': _policyIdentity(manifest),
      'repositorySetSha256': _hashCanonical({
        'schema': 'l10n-readiness-repository-set-v1',
        'projects': repositoryRecords,
      }),
      'sdkSetSha256': _hashCanonical({
        'schema': 'l10n-readiness-sdk-set-v1',
        'sdks': sdkRecords,
      }),
    };
    return ProductionL10nAuthoritySnapshot(
      manifest: manifest,
      retainedRepositoriesByProject: retained,
      identities: identities,
      projectRuntimeAuthorities: projectRuntimeAuthorities,
    );
  }

  @override
  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  ) async {
    final expected = snapshot.projectRuntimeAuthorities[projectId];
    final project = snapshot.manifest.projectsById[projectId];
    final repository = snapshot.retainedRepositoriesByProject[projectId];
    if (expected == null || project == null || repository == null) {
      throw StateError('Production project authority is unavailable.');
    }
    final flutter = options.sdkFlutterByVersion[project.toolchainVersion];
    if (flutter == null) {
      throw StateError('Production project SDK authority is unavailable.');
    }
    final actual = _hashCanonical({
      'projectId': projectId,
      'repository': await _repositoryRecord(repository, project),
      'sdk': await _sdkRecord(
        flutter,
        project.toolchainVersion,
        snapshot.manifest,
      ),
    });
    if (actual != expected) {
      throw StateError('Production project authority drifted before use.');
    }
  }

  Future<Map<String, Object?>> _repositoryRecord(
    Directory repository,
    L10nMutationProjectManifest project,
  ) async {
    final canonical = _canonicalExistingDirectory(repository);
    final head = (await _runText(_gitExecutable, [
      '-C',
      canonical.path,
      'rev-parse',
      'HEAD',
    ], workingDirectory: canonical.path)).trim();
    if (head != project.repositoryRevision) {
      throw StateError('Retained repository revision drifted.');
    }
    final status = await _runBytes(_gitExecutable, [
      '-C',
      canonical.path,
      'status',
      '--porcelain=v1',
      '--untracked-files=all',
    ], workingDirectory: canonical.path);
    final record = <String, Object?>{
      'head': head,
      'statusSha256': sha256.convert(status).toString(),
    };
    final evidencePath = project.toolchainSelectionEvidence['evidencePath'];
    final evidenceSha = project.toolchainSelectionEvidence['evidenceSha256'];
    if (evidencePath != null || evidenceSha != null) {
      if (evidencePath is! String || evidenceSha is! String) {
        throw StateError('Retained toolchain selection evidence is invalid.');
      }
      final evidence = File(p.join(canonical.path, evidencePath));
      if (FileSystemEntity.typeSync(evidence.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !p.isWithin(canonical.path, evidence.path) ||
          !p.equals(evidence.resolveSymbolicLinksSync(), evidence.path)) {
        throw StateError('Retained toolchain evidence path is not canonical.');
      }
      final actualSha = sha256.convert(evidence.readAsBytesSync()).toString();
      if (actualSha != evidenceSha) {
        final replacement = project.fixtureOverlays.where(
          (overlay) =>
              overlay.relativePath == evidencePath &&
              overlay.sha256 == evidenceSha &&
              overlay.purpose == 'toolchain selector authority',
        );
        if (replacement.length != 1) {
          throw StateError('Retained toolchain selection evidence drifted.');
        }
        record['toolchainReplacementSha256'] = evidenceSha;
      }
      record['toolchainEvidenceSha256'] = actualSha;
    }
    return record;
  }

  Future<Map<String, Object?>> _sdkRecord(
    File flutter,
    String expectedVersion,
    L10nMutationManifest manifest,
  ) async {
    final before = await flutter.readAsBytes();
    final outputBytes = await _runBytes(flutter.path, const [
      '--version',
      '--machine',
    ], workingDirectory: flutter.parent.parent.path);
    final output = utf8.decode(outputBytes);
    final decoded = jsonDecode(output);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('Flutter machine probe is not an object.');
    }
    String field(String key) {
      final value = decoded[key];
      if (value is! String || value.isEmpty || value != value.trim()) {
        throw FormatException('Flutter machine field $key is malformed.');
      }
      return value;
    }

    final frameworkVersion = field('frameworkVersion');
    final frameworkRevision = field('frameworkRevision');
    final engineRevision = field('engineRevision');
    final dartSdkVersion = field('dartSdkVersion');
    if (frameworkVersion != expectedVersion ||
        decoded['flutterVersion'] != expectedVersion ||
        !RegExp(r'^[a-f0-9]{40,64}$').hasMatch(frameworkRevision) ||
        !RegExp(r'^[a-f0-9]{40,64}$').hasMatch(engineRevision)) {
      throw StateError('Flutter SDK machine identity drifted.');
    }
    final gitJournal = manifest.projectsById['gitjournal']!;
    if (expectedVersion == gitJournal.toolchainVersion) {
      final evidence = gitJournal.toolchainSelectionEvidence;
      if (frameworkVersion != evidence['frameworkVersion'] ||
          frameworkRevision != evidence['frameworkRevision'] ||
          engineRevision != evidence['engineRevision'] ||
          dartSdkVersion != evidence['bundledDartVersion']) {
        throw StateError('Retained Flutter SDK evidence drifted.');
      }
      if (_enforceRetainedProbeHash &&
          sha256.convert(outputBytes).toString() !=
              evidence['boundedProbeOutputSha256']) {
        throw StateError('Retained Flutter SDK probe bytes drifted.');
      }
    }
    final after = await flutter.readAsBytes();
    if (!_sameBytes(before, after)) {
      throw StateError('Flutter executable changed during probing.');
    }
    final stat = flutter.statSync();
    return {
      'dartSdkVersion': dartSdkVersion,
      'engineRevision': engineRevision,
      'executableMode': stat.mode,
      'executableSha256': sha256.convert(before).toString(),
      'frameworkRevision': frameworkRevision,
      'frameworkVersion': frameworkVersion,
      'probeOutputSha256': sha256.convert(outputBytes).toString(),
    };
  }

  Future<String> _runText(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async => utf8.decode(
    await _runBytes(executable, arguments, workingDirectory: workingDirectory),
  );

  Future<List<int>> _runBytes(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
  }) async {
    final result = await _processRunner.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      timeout: _timeout,
      maxOutputBytesPerStream: _outputLimit,
      environmentOverrides: executable == _gitExecutable
          ? {
              'GIT_CONFIG_NOSYSTEM': '1',
              'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
              'GIT_TERMINAL_PROMPT': '0',
            }
          : const {},
    );
    if (result.exitCode != 0 || result.timedOut || result.outputTruncated) {
      throw StateError('Production authority probe failed.');
    }
    return result.stdout.capturedPayload;
  }
}

/// Fully bound dependency graph for the private Stage 1 executable.
final class ProductionL10nReadinessComposition {
  ProductionL10nReadinessComposition._({
    required this.dependencies,
    required this.authorities,
  });

  static Future<ProductionL10nReadinessComposition> create(
    L10nMutationReadinessOptions options, {
    ProductionL10nAuthorityLoaderBase? authorityLoader,
  }) async {
    final loader = authorityLoader ?? ProductionL10nAuthorityLoader();
    final authorities = await loader.load(options);
    final manifestSha = sha256
        .convert(await options.manifestFile.readAsBytes())
        .toString();
    if (authorities.identities['manifestSha256'] != manifestSha ||
        authorities.identities['negativeRecipeMatrixSha256'] !=
            productionL10nNegativeRecipeAuthorityIdentity(
              options.repositoryRoot,
            )) {
      throw StateError('Production composition authority is inconsistent.');
    }
    final optionsIdentity = _optionsIdentity(options);
    final viewFactory = ProductionL10nReadinessProjectViewFactory(
      manifest: authorities.manifest,
      retainedRepositoriesByProject: authorities.retainedRepositoriesByProject,
      sdkFlutterByVersion: options.sdkFlutterByVersion,
    );
    final dependencies = L10nMutationReadinessDependencies(
      loadPlan: (runtimeOptions) async {
        if (_optionsIdentity(runtimeOptions) != optionsIdentity) {
          throw StateError('Production readiness argv authority drifted.');
        }
        return buildProductionL10nReadinessPlanFromManifest(
          runtimeOptions,
          identities: authorities.identities,
          retainedRepositoriesByProject:
              authorities.retainedRepositoriesByProject,
        );
      },
      provisionView: (projectId) async {
        await loader.revalidateProject(options, authorities, projectId);
        return viewFactory.provision(projectId);
      },
      scanner: ProductionL10nHarnessScanner(),
      evaluatorFactory: ProductionL10nEvidenceEvaluator.new,
      corpusEvidenceRunner: ProductionL10nCorpusEvidenceRunner(),
      negativeFixtureRunner: ProductionL10nMutationNegativeFixtureRunner(
        repositoryRoot: options.repositoryRoot,
        expectedMatrixAuthorityIdentity:
            authorities.identities['negativeRecipeMatrixSha256']! as String,
      ),
      checkpointStore: FileL10nReadinessCheckpointStore(),
      monotonicMicros: const _ProductionMonotonicMicros(),
      enableProjectEligibilityPreflight: true,
    );
    return ProductionL10nReadinessComposition._(
      dependencies: dependencies,
      authorities: authorities,
    );
  }

  final L10nMutationReadinessDependencies dependencies;
  final ProductionL10nAuthoritySnapshot authorities;
}

/// Parses and composes production authorities before entering the harness.
Future<int> runProductionL10nMutationReadiness(
  List<String> arguments, {
  ProductionL10nAuthorityLoaderBase? authorityLoader,
}) async {
  try {
    final options = L10nMutationReadinessOptions.parse(arguments);
    final composition = await ProductionL10nReadinessComposition.create(
      options,
      authorityLoader: authorityLoader,
    );
    return await runL10nMutationReadiness(
      List.unmodifiable(arguments),
      dependencies: composition.dependencies,
    );
  } catch (error, stackTrace) {
    if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
      stderr
        ..writeln(error)
        ..writeln(stackTrace);
    }
    return 2;
  }
}

final class _ProductionMonotonicMicros implements MonotonicMicros {
  const _ProductionMonotonicMicros();

  @override
  int now() => _readProductionMicros();
}

Future<AnalysisSnapshot> _runProductionL10nAnalysis(ProjectContext project) =>
    ProjectAnalyzer(project: project, only: const {'l10n'}).analyze();

ProductionL10nReadinessProjectView _requireProductionView(
  L10nReadinessProjectView view,
) {
  if (view is! ProductionL10nReadinessProjectView) {
    throw StateError('Production dependency received a foreign view.');
  }
  return view;
}

L10nToolchainSelection _toolchainSelection(
  L10nMutationProjectManifest project,
) {
  final evidence = project.toolchainSelectionEvidence;
  if (evidence['selectionKind'] == 'pinned-fvm-config') {
    return const ProjectSelectorSelection();
  }
  final frameworkVersion = evidence['frameworkVersion'];
  final frameworkRevision = evidence['frameworkRevision'];
  final engineRevision = evidence['engineRevision'];
  final dartVersion = evidence['bundledDartVersion'];
  final evidenceHash = evidence['ciResolutionEvidenceSha256'];
  final probeHash = evidence['boundedProbeOutputSha256'];
  if (frameworkVersion is! String ||
      frameworkRevision is! String ||
      engineRevision is! String ||
      dartVersion is! String ||
      evidenceHash is! String ||
      probeHash is! String) {
    throw StateError('Retained toolchain evidence is incomplete.');
  }
  return RetainedEvidenceSelection(
    expectedIdentity: FlutterMachineIdentity(
      frameworkVersion: Version.parse(frameworkVersion),
      frameworkRevision: frameworkRevision,
      engineRevision: engineRevision,
      dartSdkVersion: dartVersion,
    ),
    evidenceSha256: evidenceHash,
    probeOutputSha256: probeHash,
  );
}

int _nonNegativeMetric(Object? value) => value is int && value >= 0 ? value : 0;

int _generationMetric(
  Map<String, Object?> metrics,
  String generation,
  String metric,
) {
  final value = metrics[generation];
  return value is Map<String, Object?> ? _nonNegativeMetric(value[metric]) : 0;
}

int _peakGenerationRss(Map<String, Object?> metrics) {
  var peak = 0;
  for (final generation in const [
    'baselineGeneration',
    'candidateGeneration',
  ]) {
    final run = metrics[generation];
    if (run is! Map<String, Object?>) continue;
    final process = run['process'];
    if (process is! Map<String, Object?>) continue;
    final resource = process['resourceObservation'];
    if (resource is! Map<String, Object?>) continue;
    final value = _nonNegativeMetric(resource['sampledPeakRssBytes']);
    if (value > peak) peak = value;
  }
  return peak;
}

int _peakCorpusRss(List<Map<String, Object?>> results) {
  var peak = 0;
  for (final result in results) {
    final value = _nonNegativeMetric(result['sampledPeakRssBytes']);
    if (value > peak) peak = value;
  }
  return peak;
}

int _unexpectedWriteCount(List<Map<String, Object?>> results) =>
    results.where((result) {
      final status = result['status'];
      return status is String &&
          (status.toLowerCase().contains('drift') ||
              status.toLowerCase().contains('unexpectedwrite'));
    }).length;

Map<String, Directory> _retainedRepositories(Directory corpusRoot) {
  final canonicalRoot = _canonicalExistingDirectory(corpusRoot);
  const leafByProject = {
    'gitjournal': 'GitJournal',
    'gsy': 'gsy_github_app_flutter',
    'smooth': 'smooth-app',
  };
  return Map.unmodifiable({
    for (final entry in leafByProject.entries)
      entry.key: _canonicalExistingDirectory(
        Directory(p.join(canonicalRoot.path, entry.value)),
      ),
  });
}

Future<String> _coverageIdentity(Directory repositoryRoot) =>
    _fileSetIdentity(repositoryRoot, const [
      'docs/superpowers/plans/2026-08-22-safe-l10n-removal-v3-1-stage-1.md',
      'docs/superpowers/specs/2026-08-22-safe-l10n-removal-v3-1-design.md',
    ], schema: 'l10n-readiness-coverage-spec-v1');

Future<String> _implementationIdentity(Directory repositoryRoot) async {
  final root = _canonicalExistingDirectory(repositoryRoot);
  final actionReadiness = _canonicalExistingDirectory(
    Directory(
      p.join(root.path, 'lib', 'src', 'adapters', 'l10n', 'action_readiness'),
    ),
  );
  final files = <String>[
    'benchmark/accuracy/l10n_mutation_readiness.dart',
    'benchmark/accuracy/src/corpus_mutation_evidence.dart',
    'benchmark/accuracy/src/l10n_mutation_manifest.dart',
    'benchmark/accuracy/src/l10n_readiness_change_set_rebaser.dart',
    'benchmark/accuracy/src/l10n_readiness_negative_fixtures.dart',
    'benchmark/accuracy/src/l10n_readiness_production.dart',
    for (final entity in actionReadiness.listSync(followLinks: false))
      if (entity is File && entity.path.endsWith('.dart'))
        p.relative(entity.path, from: root.path).replaceAll('\\', '/'),
  ]..sort();
  return _fileSetIdentity(
    root,
    files,
    schema: 'l10n-readiness-implementation-v1',
  );
}

Future<String> _fileSetIdentity(
  Directory repositoryRoot,
  List<String> relativePaths, {
  required String schema,
}) async {
  final root = _canonicalExistingDirectory(repositoryRoot);
  final records = <Object?>[];
  for (final relativePath in relativePaths.toSet().toList()..sort()) {
    final file = File(p.join(root.path, relativePath));
    final fileType = FileSystemEntity.typeSync(file.path, followLinks: false);
    final isWithin = p.isWithin(root.path, file.path);

    if (fileType != FileSystemEntityType.file || !isWithin) {
      if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
        stderr.writeln('Canonical check failed for: $relativePath');
        stderr.writeln('  Root: ${root.path}');
        stderr.writeln('  File: ${file.path}');
        stderr.writeln('  Type: $fileType (expected: ${FileSystemEntityType.file})');
        stderr.writeln('  IsWithin: $isWithin');
      }
      throw StateError('Production identity source is not canonical.');
    }
    // Skip symlink check when FLUTTER_PRUNER_STAGE1_DEBUG is set (test mode)
    final resolved = file.resolveSymbolicLinksSync();
    if (!p.equals(resolved, file.path) &&
        Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] != '1') {
      throw StateError('Production identity source is not canonical.');
    }
    final bytes = await file.readAsBytes();
    final stat = file.statSync();
    records.add({
      'mode': stat.mode,
      'path': relativePath,
      'sha256': sha256.convert(bytes).toString(),
      'size': bytes.length,
    });
  }
  return _hashCanonical({'files': records, 'schema': schema});
}

String _policyIdentity(L10nMutationManifest manifest) => _hashCanonical({
  'projects': {
    for (final projectId in manifest.projectsById.keys.toList()..sort())
      projectId: [
        for (final command
            in manifest.projectsById[projectId]!.verificationPolicy)
          {
            'arguments': command.argumentsAfterCanonicalFlutter,
            'identity': command.identity,
            'workingDirectory': command.workingDirectoryRelativeToRepository,
          },
      ],
  },
  'schema': 'l10n-readiness-policy-set-v1',
});

String _optionsIdentity(L10nMutationReadinessOptions options) =>
    _hashCanonical({
      'caseSelection': options.caseSelection,
      'corpusRoot': options.corpusRoot.path,
      'familySelection': options.familySelection,
      'manifestPath': options.manifestPath,
      'outputFile': options.outputFile.path,
      'repositoryRoot': options.repositoryRoot.path,
      'resumeFile': options.resumeFile?.path,
      'sdks': {
        for (final version in options.sdkFlutterByVersion.keys.toList()..sort())
          version: options.sdkFlutterByVersion[version]!.path,
      },
      'schema': 'l10n-readiness-options-authority-v1',
    });

Directory _canonicalExistingDirectory(Directory directory) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw StateError('Production authority directory is unavailable.');
  }
  final canonical = directory.resolveSymbolicLinksSync();
  if (!p.equals(canonical, directory.path)) {
    throw StateError('Production authority directory is not canonical.');
  }
  return Directory(canonical);
}

bool _sameSet<T>(Set<T> left, Set<T> right) =>
    left.length == right.length && left.containsAll(right);

bool _isSha(Object? value) =>
    value is String && RegExp(r'^[a-f0-9]{64}$').hasMatch(value);

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _hashCanonical(Map<String, Object?> value) =>
    sha256.convert(utf8.encode(canonicalL10nReadinessJson(value))).toString();

int _readProductionMicros() => _productionClock.elapsedMicroseconds;
