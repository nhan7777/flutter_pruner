import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../../analysis/analysis_snapshot.dart';
import '../../../analysis/project_analyzer.dart';
import '../../../core/confidence/classification_reason.dart';
import '../../../core/confidence/finding.dart';
import '../../../core/graph/build_condition.dart';
import '../../../core/graph/edge.dart';
import '../../../core/graph/evidence.dart';
import '../../../core/graph/execution_target.dart';
import '../../../core/graph/node.dart';
import '../../../core/graph/reachability_graph.dart';
import '../../../core/project/analysis_mode.dart';
import '../../../core/project/project_context.dart';
import '../../../core/project/target_matrix.dart';
import '../../../reporting/run_report.dart';
import '../../dart/dart_analysis_workspace.dart';
import '../arb_inventory.dart';
import '../l10n_config.dart';
import 'arb_document.dart';
import 'immutable_bytes.dart';
import 'l10n_arb_mutation_planner.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_family_snapshot.dart';
import 'l10n_generation_config.dart';
import 'l10n_toolchain.dart';

const _preflightStage = 'family-preflight';
const _captureStage = 'family-snapshot-capture';
const _packageStage = 'package-resolution-capture';

/// Outcome of capturing one immutable l10n family authority.
sealed class L10nFamilySnapshotResult {
  const L10nFamilySnapshotResult();
}

/// A family whose complete mutation evidence is frozen and ready.
final class L10nFamilySnapshotReady extends L10nFamilySnapshotResult {
  /// Creates a ready result around [snapshot].
  const L10nFamilySnapshotReady(this.snapshot);

  /// Complete immutable family authority.
  final L10nFamilySnapshot snapshot;
}

/// A fail-closed family capture rejection.
final class L10nFamilySnapshotRejected extends L10nFamilySnapshotResult {
  /// Creates a deterministically ordered rejection result.
  L10nFamilySnapshotRejected(Iterable<L10nEvidenceFailure> failures)
    : failures = List<L10nEvidenceFailure>.unmodifiable(
        failures.toList()..sort(_compareFailures),
      );

  /// Stable deterministic rejection facts.
  final List<L10nEvidenceFailure> failures;
}

/// Captures a family without mutating the selected project.
abstract interface class L10nFamilySnapshotter {
  /// Captures one complete family authority or returns stable rejections.
  Future<L10nFamilySnapshotResult> capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  });
}

/// Reconstructs the immediate l10n-only analysis used as a drift barrier.
abstract interface class L10nAnalysisRerunner {
  /// Runs a fresh l10n-only analysis for [project].
  Future<AnalysisSnapshot> rerun(ProjectContext project);
}

final class _DefaultL10nAnalysisRerunner implements L10nAnalysisRerunner {
  const _DefaultL10nAnalysisRerunner();

  @override
  Future<AnalysisSnapshot> rerun(ProjectContext project) =>
      ProjectAnalyzer(project: project, only: const {'l10n'}).analyze();
}

/// Stable identity of analyzer contexts and their package/options authorities.
final class L10nAnalyzerContextAuthorityProjection {
  /// Creates a validated context-authority projection.
  const L10nAnalyzerContextAuthorityProjection(this.identity);

  /// Canonical project-relative context mapping SHA-256.
  final String identity;
}

/// Typed result of rediscovering analyzer context authorities.
sealed class L10nAnalyzerContextAuthorityProjectionResult {
  const L10nAnalyzerContextAuthorityProjectionResult();
}

/// Analyzer context authorities were finite and project-root bounded.
final class L10nAnalyzerContextAuthorityProjectionReady
    extends L10nAnalyzerContextAuthorityProjectionResult {
  /// Creates a ready projection.
  const L10nAnalyzerContextAuthorityProjectionReady(this.projection);

  /// Reusable context authority identity.
  final L10nAnalyzerContextAuthorityProjection projection;
}

/// Analyzer context authorities were inherited, nested, or otherwise unsafe.
final class L10nAnalyzerContextAuthorityProjectionRejected
    extends L10nAnalyzerContextAuthorityProjectionResult {
  /// Creates a typed rejection.
  const L10nAnalyzerContextAuthorityProjectionRejected(this.failure);

  /// Stable failure identity.
  final L10nEvidenceFailure failure;
}

/// Rediscoverable analyzer-context authority seam consumed again by Task 13.
final class L10nAnalyzerContextAuthorityProjector {
  /// Creates the stateless authority projector.
  const L10nAnalyzerContextAuthorityProjector();

  /// Discovers context/package/options authorities without analyzing code.
  L10nAnalyzerContextAuthorityProjectionResult project(
    ProjectContext project, {
    Set<String> nestedAuthorityPaths = const {},
  }) {
    try {
      final canonicalRoot = _canonicalDirectory(project.root.path);
      if (p.normalize(p.absolute(project.root.path)) != canonicalRoot) {
        throw const _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'project-root-not-canonical',
        );
      }
      final probe = _probeAnalyzerContextAuthorities(
        project,
        canonicalRoot,
        nestedAuthorityPaths: nestedAuthorityPaths,
      );
      return L10nAnalyzerContextAuthorityProjectionReady(
        L10nAnalyzerContextAuthorityProjection(probe.identity),
      );
    } on _Problem catch (problem) {
      return L10nAnalyzerContextAuthorityProjectionRejected(problem.failure);
    } on Object {
      return const L10nAnalyzerContextAuthorityProjectionRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.invalidInputPath,
          stage: _captureStage,
          detailCode: 'analyzer-context-authority-probe-failed',
        ),
      );
    }
  }
}

/// Strict, reusable package-config projection consumed again by Task 13.
final class L10nPackageConfigProjection {
  L10nPackageConfigProjection._({
    required ImmutableBytes sourceBytes,
    required ImmutableBytes stageBytes,
    required this.identity,
    required this.authorityIdentity,
    required Map<String, String> canonicalRootsByPackage,
    required Map<String, String> projectOwnedRootsByPackage,
    required List<_ExternalPackageAuthority> externalAuthorities,
    required List<_ProjectOwnedPackageAuthority> projectOwnedAuthorities,
  }) : sourceBytes = ImmutableBytes.copyOf(sourceBytes.copy()),
       stageBytes = ImmutableBytes.copyOf(stageBytes.copy()),
       canonicalRootsByPackage = Map<String, String>.unmodifiable(
         SplayTreeMap<String, String>.of(canonicalRootsByPackage),
       ),
       projectOwnedRootsByPackage = Map<String, String>.unmodifiable(
         SplayTreeMap<String, String>.of(projectOwnedRootsByPackage),
       ),
       _externalAuthorities = List.unmodifiable(externalAuthorities),
       _projectOwnedAuthorities = List.unmodifiable(projectOwnedAuthorities);

  /// Exact live package-config bytes.
  final ImmutableBytes sourceBytes;

  /// Byte-spliced stage projection; only package rootUri tokens differ.
  final ImmutableBytes stageBytes;

  /// Identity of source/stage bytes and every physical package authority.
  final String identity;

  /// Stage-root-independent identity of package resolution and every external
  /// physical authority.
  final String authorityIdentity;

  /// Canonical physical package roots by logical package name.
  final Map<String, String> canonicalRootsByPackage;

  /// Stage-relative roots for strict descendants owned by this project.
  final Map<String, String> projectOwnedRootsByPackage;

  final List<_ExternalPackageAuthority> _externalAuthorities;
  final List<_ProjectOwnedPackageAuthority> _projectOwnedAuthorities;
}

/// Typed outcome of strict package-config validation and projection.
sealed class L10nPackageConfigProjectionResult {
  const L10nPackageConfigProjectionResult();
}

/// A validated package-config projection ready for snapshot capture.
final class L10nPackageConfigProjectionReady
    extends L10nPackageConfigProjectionResult {
  /// Creates a ready result for [projection].
  const L10nPackageConfigProjectionReady(this.projection);

  /// Strict source/stage package authority.
  final L10nPackageConfigProjection projection;
}

/// A stable package-config projection rejection.
final class L10nPackageConfigProjectionRejected
    extends L10nPackageConfigProjectionResult {
  /// Creates a rejected result for [failure].
  const L10nPackageConfigProjectionRejected(this.failure);

  /// Stable reason projection could not be proven safe.
  final L10nEvidenceFailure failure;
}

/// Duplicate-safe byte projector for `.dart_tool/package_config.json`.
final class L10nPackageConfigProjector {
  /// Creates the stateless duplicate-safe projector.
  const L10nPackageConfigProjector();

  /// Validates and projects one package resolution authority.
  L10nPackageConfigProjectionResult project({
    required List<int> sourceBytes,
    required String canonicalProjectRoot,
    required String selectedPackageName,
    required L10nToolchainResolved toolchain,
  }) {
    try {
      return L10nPackageConfigProjectionReady(
        _projectPackageConfig(
          sourceBytes: sourceBytes,
          canonicalProjectRoot: canonicalProjectRoot,
          selectedPackageName: selectedPackageName,
          toolchain: toolchain,
        ),
      );
    } on _Problem catch (problem) {
      return L10nPackageConfigProjectionRejected(problem.failure);
    } on Object {
      return const L10nPackageConfigProjectionRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.packageResolutionDrift,
          stage: _packageStage,
          detailCode: 'package-config-invalid',
          relativePath: '.dart_tool/package_config.json',
        ),
      );
    }
  }
}

/// Root-independent semantic projection of one exact l10n graph family.
final class L10nAnalysisFingerprintProjector {
  /// Creates the stateless projector shared by snapshot and stage evidence.
  const L10nAnalysisFingerprintProjector();

  /// Fingerprints nodes, incident edges/evidence, blockers, findings, target
  /// reachability, auxiliary state, ownership, and protection facts.
  String project({
    required AnalysisSnapshot analysis,
    required Set<String> familyNodeIds,
  }) => _l10nAnalysisFingerprintForIds(analysis, familyNodeIds);
}

/// Default fail-closed family preflight.
final class L10nFamilyPreflight implements L10nFamilySnapshotter {
  /// Creates the production implementation.
  const L10nFamilyPreflight()
    : _analysisRerunner = null,
      _beforeSecondRead = null;

  /// Creates deterministic test seams without exposing them to production.
  const L10nFamilyPreflight.testing({
    L10nAnalysisRerunner? analysisRerunner,
    Future<void> Function()? beforeSecondRead,
  }) : _analysisRerunner = analysisRerunner,
       _beforeSecondRead = beforeSecondRead;

  final L10nAnalysisRerunner? _analysisRerunner;
  final Future<void> Function()? _beforeSecondRead;

  @override
  Future<L10nFamilySnapshotResult> capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  }) async {
    try {
      return await _capture(
        analysis: analysis,
        selectedNodeIds: selectedNodeIds,
        config: config,
        toolchain: toolchain,
      );
    } on _Problem catch (problem) {
      return L10nFamilySnapshotRejected([problem.failure]);
    } on FileSystemException {
      return L10nFamilySnapshotRejected(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.sourceDrift,
          stage: _captureStage,
          detailCode: 'snapshot-filesystem-drift',
        ),
      ]);
    } on Object {
      return L10nFamilySnapshotRejected(const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.internalFailure,
          stage: _captureStage,
          detailCode: 'snapshot-internal-failure',
        ),
      ]);
    }
  }

  Future<L10nFamilySnapshotResult> _capture({
    required AnalysisSnapshot analysis,
    required Iterable<String> selectedNodeIds,
    required L10nGenerationConfig config,
    required L10nToolchainResolved toolchain,
  }) async {
    final selectedIdsInOriginalOrder = selectedNodeIds.toList(growable: false);
    if (selectedIdsInOriginalOrder.isEmpty) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidSelection,
        _preflightStage,
        'selection-empty',
      );
    }
    _requireCompletedAnalysis(analysis);

    final canonicalRoot = _canonicalDirectory(analysis.project.root.path);
    if (p.normalize(p.absolute(analysis.project.root.path)) != canonicalRoot) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'project-root-not-canonical',
      );
    }
    final v2Config = _loadV2Config(analysis.project);
    _requireConfigAgreement(
      project: analysis.project,
      v2: v2Config,
      strict: config,
      toolchain: toolchain,
    );
    final inventory = ArbInventory.read(analysis.project, v2Config);
    if (inventory.blockers.isNotEmpty) {
      throw const _Problem(
        L10nEvidenceRejectionCode.arbFamilyIncomplete,
        _captureStage,
        'arb-inventory-blocked',
      );
    }

    final selectedKeysInOriginalOrder = _validateSelection(
      analysis: analysis,
      inventory: inventory,
      selectedNodeIds: selectedIdsInOriginalOrder,
      templatePath: config.templateArbPath,
    );
    _validateSelectedGraphSafety(analysis, selectedIdsInOriginalOrder.toSet());
    _validateFullFamilyGraph(analysis, inventory);
    _validateFamilyGraphSafety(
      analysis,
      inventory,
      selectedIdsInOriginalOrder.toSet(),
    );

    final capture = _CaptureSet(canonicalRoot);
    final pubspec = capture.add(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      required: true,
    );
    if (!_sameBytes(pubspec.bytes!, config.pubspecBytes.copy())) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'generation-config-pubspec-drift',
        'pubspec.yaml',
      );
    }
    _requireLivePubspecAgreement(pubspec.bytes!, analysis.project);
    final lockfile = capture.add(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      required: true,
    );
    final liveYaml = capture.add(
      'l10n.yaml',
      L10nSnapshotRole.l10nConfig,
      required: false,
    );
    final strictYaml = config.yamlBytes?.copy();
    if ((liveYaml.bytes == null) != (strictYaml == null) ||
        (liveYaml.bytes != null && !_sameBytes(liveYaml.bytes!, strictYaml!))) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'generation-config-yaml-drift',
        'l10n.yaml',
      );
    }

    final arbPaths = _enumerateArbPaths(canonicalRoot, config.arbDirectory);
    final documents = SplayTreeMap<String, ArbDocument>();
    final languages = SplayTreeSet<String>();
    for (final path in arbPaths) {
      final role = path == config.templateArbPath
          ? L10nSnapshotRole.arbTemplate
          : L10nSnapshotRole.arbLocale;
      final file = capture.add(path, role, required: true);
      final parsed = ArbDocument.parse(file.bytes!);
      if (parsed is! ArbParseSuccess) {
        throw _Problem(
          L10nEvidenceRejectionCode.arbParseFailure,
          _captureStage,
          'arb-byte-parse-failed',
          path,
        );
      }
      documents[path] = parsed.document;
      final declaredLocale = parsed.document.member('@@locale')?.decodedValue;
      if (declaredLocale != null && declaredLocale is! String) {
        throw _Problem(
          L10nEvidenceRejectionCode.arbFamilyIncomplete,
          _captureStage,
          'arb-locale-invalid',
          path,
        );
      }
      final locale = _arbLocaleForPath(path, declaredLocale as String?);
      if (locale == null) {
        throw _Problem(
          L10nEvidenceRejectionCode.arbFamilyIncomplete,
          _captureStage,
          'arb-locale-invalid',
          path,
        );
      }
      languages.add(_baseLanguage(locale));
    }
    if (!documents.containsKey(config.templateArbPath)) {
      throw _Problem(
        L10nEvidenceRejectionCode.arbFamilyIncomplete,
        _captureStage,
        'template-document-missing',
        config.templateArbPath,
      );
    }
    _compareByteAndSemanticInventory(
      inventory: inventory,
      template: documents[config.templateArbPath]!,
    );

    final mutation = L10nArbMutationPlanner.plan(
      templatePath: config.templateArbPath,
      documentsByPath: documents,
      selectedKeys: selectedKeysInOriginalOrder,
    );
    if (mutation is L10nArbMutationPlanRejected) {
      return L10nFamilySnapshotRejected(mutation.failures);
    }
    final mutationPlan = (mutation as L10nArbMutationPlanReady).plan;

    if (config.headerFilePath case final header?) {
      capture.add(header, L10nSnapshotRole.header, required: true);
    }
    final outputFamily = _outputFamily(config, languages);
    final declaredRoots = <String>{
      for (final target in analysis.project.targets) target.entrypoint,
      ...analysis.project.rootCoverage.publicEntrypoints,
    };
    if (outputFamily.any(declaredRoots.contains)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'output-family-declared-root-collision',
      );
    }
    _rejectOutputFamilyCasefoldCollisions(
      canonicalRoot,
      config.outputDirectory,
      outputFamily,
    );
    for (final path in outputFamily) {
      capture.add(
        path,
        path == config.baseOutputPath
            ? L10nSnapshotRole.generatedBase
            : L10nSnapshotRole.generatedLanguage,
        required: false,
      );
    }
    final untranslated = config.untranslatedMessagesPath;
    if (untranslated != null) {
      capture.add(
        untranslated,
        L10nSnapshotRole.untranslatedSidecar,
        required: false,
      );
    }
    capture.add(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
      required: false,
    );
    capture.add(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
      required: false,
    );
    final packageCapture = capture.add(
      '.dart_tool/package_config.json',
      L10nSnapshotRole.packageConfig,
      required: true,
    );
    final projectedPackages = const L10nPackageConfigProjector().project(
      sourceBytes: packageCapture.bytes!,
      canonicalProjectRoot: canonicalRoot,
      selectedPackageName: analysis.project.packageName,
      toolchain: toolchain,
    );
    if (projectedPackages is L10nPackageConfigProjectionRejected) {
      final failure = projectedPackages.failure;
      throw _Problem(
        failure.code,
        failure.stage,
        failure.detailCode,
        failure.relativePath,
      );
    }
    final packageProjection =
        (projectedPackages as L10nPackageConfigProjectionReady).projection;
    capture.replaceStageBytes(
      '.dart_tool/package_config.json',
      packageProjection.stageBytes.copy(),
    );
    final nestedOptionsPaths = <String>{
      for (final relativeRoot
          in packageProjection.projectOwnedRootsByPackage.values)
        '$relativeRoot/analysis_options.yaml',
    };
    _prevalidateAnalysisOptionsPlacement(
      canonicalRoot,
      nestedAuthorityPaths: nestedOptionsPaths,
    );
    final capturedOptions = _captureAnalysisOptions(
      capture,
      packageProjection,
      analysis.project.pubspec,
      lockfile.bytes!,
    );
    final contextProbeBefore = _probeAnalyzerContextAuthorities(
      analysis.project,
      canonicalRoot,
      nestedAuthorityPaths: nestedOptionsPaths,
    );
    final optionsAuthority = L10nAnalysisOptionsProjection(
      projectOwnedPaths: capturedOptions.projectOwnedPaths,
      nestedAuthorityPaths: capturedOptions.nestedAuthorityPaths,
      externalAuthorities: capturedOptions.externalAuthorities,
      contextAuthorityIdentity: contextProbeBefore.identity,
    );
    final workspaceBefore = contextProbeBefore.workspace;
    final optionsClosure = optionsAuthority.projectOwnedPaths.toList();
    final packageResolutionIdentity = _hashCanonical({
      'projection': packageProjection.identity,
      'packageConfig': _entryIdentity(
        capture.entries['.dart_tool/package_config.json']!,
      ),
      'lockfile': _entryIdentity(capture.entries['pubspec.lock']!),
      'packageGraph': _entryIdentity(
        capture.entries['.dart_tool/package_graph.json']!,
      ),
      'externalAnalysisOptions': optionsAuthority.identity,
    });

    final analyzerClosureBefore = _captureAnalyzerClosure(
      analysis.project,
      canonicalRoot,
      capture,
      outputFamily,
      workspaceBefore,
    );
    final projectOwnedPackagePaths = <String>{
      for (final authority in packageProjection._projectOwnedAuthorities)
        ...authority.relativeFilePaths,
    };
    for (final path in projectOwnedPackagePaths.toList()..sort()) {
      if (capture.entries.containsKey(path)) continue;
      capture.add(path, L10nSnapshotRole.verificationInput, required: true);
    }
    final closureBefore = <String>{
      ...analyzerClosureBefore,
      ...projectOwnedPackagePaths.where((path) => path.endsWith('.dart')),
    }.toList()..sort();
    final unrelatedSiblings = _captureOutputSiblings(
      capture: capture,
      outputDirectory: config.outputDirectory,
      outputFamily: outputFamily,
      baseOutputPath: config.baseOutputPath,
      arbPaths: arbPaths,
    );

    final l10nFingerprint = _l10nAnalysisFingerprint(analysis, inventory);
    final rerun =
        await (_analysisRerunner ?? const _DefaultL10nAnalysisRerunner()).rerun(
          analysis.project,
        );
    _requireCompletedAnalysis(rerun);
    final rerunInventory = ArbInventory.read(analysis.project, v2Config);
    if (rerunInventory.blockers.isNotEmpty ||
        _l10nAnalysisFingerprint(rerun, rerunInventory) != l10nFingerprint) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'l10n-rerun-fingerprint-drift',
      );
    }
    final contextProbeAfterRerun = _probeAnalyzerContextAuthoritiesForDrift(
      analysis.project,
      canonicalRoot,
      nestedAuthorityPaths: nestedOptionsPaths,
    );
    if (contextProbeAfterRerun.identity != contextProbeBefore.identity) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'analyzer-context-authority-drift',
      );
    }
    final closureAfterRerun = <String>{
      ..._rediscoverMembershipForDrift(
        () => _enumerateAnalyzerClosure(
          analysis.project,
          canonicalRoot,
          contextProbeAfterRerun.workspace,
        ),
      ),
      ...projectOwnedPackagePaths.where((path) => path.endsWith('.dart')),
    }.toList()..sort();
    if (!_sameStrings(closureBefore, closureAfterRerun)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'analyzer-closure-drift',
      );
    }

    await _beforeSecondRead?.call();
    final contextProbeFinal = _probeAnalyzerContextAuthoritiesForDrift(
      analysis.project,
      canonicalRoot,
      nestedAuthorityPaths: nestedOptionsPaths,
    );
    if (contextProbeFinal.identity != contextProbeBefore.identity) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'analyzer-context-authority-drift',
      );
    }
    capture.verifySecondRead();
    final optionsRevalidation = optionsAuthority.revalidate();
    if (optionsRevalidation is L10nAnalysisOptionsRevalidationRejected) {
      final failure = optionsRevalidation.failure;
      throw _Problem(
        failure.code,
        failure.stage,
        failure.detailCode,
        failure.relativePath,
      );
    }
    final secondPackageProjectionResult = const L10nPackageConfigProjector()
        .project(
          sourceBytes: packageCapture.bytes!,
          canonicalProjectRoot: canonicalRoot,
          selectedPackageName: analysis.project.packageName,
          toolchain: toolchain,
        );
    if (secondPackageProjectionResult is! L10nPackageConfigProjectionReady ||
        secondPackageProjectionResult.projection.identity !=
            packageProjection.identity ||
        !_sameBytes(
          secondPackageProjectionResult.projection.stageBytes.copy(),
          packageProjection.stageBytes.copy(),
        ) ||
        _hashCanonical(
              secondPackageProjectionResult.projection.canonicalRootsByPackage,
            ) !=
            _hashCanonical(packageProjection.canonicalRootsByPackage)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-projection-second-read-drift',
        '.dart_tool/package_config.json',
      );
    }
    packageProjection._verifyExternalAuthorities();
    final finalArbPaths = _rediscoverMembershipForDrift(
      () => _enumerateArbPaths(canonicalRoot, config.arbDirectory),
    );
    final finalAnalyzerClosure = _rediscoverMembershipForDrift(
      () => _enumerateAnalyzerClosure(
        analysis.project,
        canonicalRoot,
        contextProbeFinal.workspace,
      ),
    );
    final finalProjectOwnedPackagePaths = <String>{
      for (final authority
          in secondPackageProjectionResult.projection._projectOwnedAuthorities)
        ...authority.relativeFilePaths,
    };
    final finalClosure = <String>{
      ...finalAnalyzerClosure,
      ...finalProjectOwnedPackagePaths.where((path) => path.endsWith('.dart')),
    }.toList()..sort();
    final finalOutputSiblings = _rediscoverMembershipForDrift(
      () => _enumerateOutputSiblings(
        canonicalRoot: canonicalRoot,
        outputDirectory: config.outputDirectory,
        outputFamily: outputFamily,
        baseOutputPath: config.baseOutputPath,
        arbPaths: finalArbPaths,
      ),
    );
    if (!_sameStrings(arbPaths, finalArbPaths) ||
        !_sameStrings(closureBefore, finalClosure) ||
        !_sameStrings(
          projectOwnedPackagePaths.toList()..sort(),
          finalProjectOwnedPackagePaths.toList()..sort(),
        ) ||
        !_sameStrings(unrelatedSiblings, finalOutputSiblings)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'snapshot-membership-drift',
      );
    }

    final analyzerIdentity = _hashCanonical({
      'paths': [
        for (final path in closureBefore)
          _entryIdentity(capture.entries[path]!),
      ],
      'options': [
        for (final path in optionsClosure)
          _entryIdentity(capture.entries[path]!),
      ],
      'externalOptions': optionsAuthority.identity,
    });
    final verificationClosure = L10nVerificationClosure(
      projectOwnedDartPaths: closureBefore.toSet(),
      analyzerRootIdentity: analyzerIdentity,
    );
    final memberKinds = <String, ArbGeneratedMemberKind>{
      for (final key in inventory.keys) key.key: key.memberKind,
    };
    final familyFingerprint = _hashCanonical({
      'entries': [
        for (final entry in capture.entries.values) _entryIdentity(entry),
      ],
      'generatedPaths': outputFamily,
      'memberKinds': {
        for (final entry
            in (memberKinds.entries.toList()
              ..sort((left, right) => left.key.compareTo(right.key))))
          entry.key: entry.value.name,
      },
      'optionalUntranslated': untranslated,
      'project': _projectIdentity(analysis.project),
      'configuration': config.configurationIdentity,
      'packages': packageResolutionIdentity,
      'toolchain': toolchain.identitySha256,
      'analyzer': analyzerIdentity,
      'analyzerClosurePaths': closureBefore,
      'l10nAnalysis': l10nFingerprint,
      'unrelatedOutputSiblings': unrelatedSiblings,
    });
    final selectionFingerprint = _hashCanonical({
      'family': familyFingerprint,
      'nodeIds': [...selectedIdsInOriginalOrder]..sort(),
      'keys': [...selectedKeysInOriginalOrder]..sort(),
      'mutation': mutationPlan.mutationFingerprint,
    });
    return L10nFamilySnapshotReady(
      L10nFamilySnapshot(
        entries: capture.entries,
        mutationPlan: mutationPlan,
        selectedNodeIds: selectedIdsInOriginalOrder.toSet(),
        selectedKeys: selectedKeysInOriginalOrder.toSet(),
        expectedGeneratedMemberKindsByKey: memberKinds,
        expectedGeneratedPaths: outputFamily.toSet(),
        optionalUntranslatedPath: untranslated,
        verificationClosure: verificationClosure,
        analysisOptionsProjection: optionsAuthority,
        provenUnrelatedOutputSiblings: unrelatedSiblings.toSet(),
        familyFingerprint: familyFingerprint,
        selectionFingerprint: selectionFingerprint,
        l10nAnalysisFingerprint: l10nFingerprint,
        configurationIdentity: config.configurationIdentity,
        packageConfigProjectionIdentity: packageProjection.authorityIdentity,
        packageResolutionIdentity: packageResolutionIdentity,
        toolchainIdentity: toolchain.identitySha256,
        projectSemantics: L10nProjectSemantics(
          pubspec: analysis.project.pubspec,
          packageName: analysis.project.packageName,
          analysisMode: analysis.project.analysisMode,
          targetMatrix: analysis.project.targetMatrix,
          rootCoverage: analysis.project.rootCoverage,
        ),
      ),
    );
  }
}

T _rediscoverMembershipForDrift<T>(T Function() discover) {
  try {
    return discover();
  } on Object {
    throw const _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'snapshot-membership-drift',
    );
  }
}

void _rejectOutputFamilyCasefoldCollisions(
  String canonicalRoot,
  String outputDirectory,
  List<String> outputFamily,
) {
  final absolute = p.join(canonicalRoot, p.fromUri(outputDirectory));
  final type = FileSystemEntity.typeSync(absolute, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type != FileSystemEntityType.directory) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'output-directory-not-regular-directory',
      outputDirectory,
    );
  }
  final expected = <String, String>{
    for (final path in outputFamily) _asciiFold(path): path,
  };
  for (final entity in Directory(absolute).listSync(followLinks: false)) {
    final relative = _relative(canonicalRoot, entity.path);
    final expectedPath = expected[_asciiFold(relative)];
    if (expectedPath != null && relative != expectedPath) {
      throw _Problem(
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        _captureStage,
        'output-family-casefold-collision',
        relative,
      );
    }
  }
}

void _validateSelectedGraphSafety(
  AnalysisSnapshot analysis,
  Set<String> selectedIds,
) {
  final targets = analysis.project.targets;
  final auxiliaryProven = analysis.graph.auxiliaryProven();
  final auxiliaryRetained = analysis.graph.auxiliaryRetained();
  for (final id in selectedIds) {
    if (analysis.graph.isProtected(id) ||
        auxiliaryProven.contains(id) ||
        targets.any(
          (target) => analysis.graph.configuredProvenFor(target).contains(id),
        )) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidSelection,
        _preflightStage,
        'selected-node-reachable-or-protected',
      );
    }
    if (auxiliaryRetained.contains(id) ||
        targets.any(
          (target) => analysis.graph.configuredRetainedFor(target).contains(id),
        )) {
      throw const _Problem(
        L10nEvidenceRejectionCode.scanBlockerPresent,
        _preflightStage,
        'selected-node-retained',
      );
    }
  }
}

void _requireCompletedAnalysis(AnalysisSnapshot analysis) {
  final l10nRuns = analysis.adapterRuns
      .where((run) => run.id == 'l10n' && run.role == AdapterRunRole.reporting)
      .toList(growable: false);
  if (l10nRuns.isEmpty) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'l10n-adapter-run-missing',
    );
  }
  if (l10nRuns.length != 1 ||
      l10nRuns.single.status != AdapterRunStatus.executed) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'l10n-adapter-run-not-executed',
    );
  }
  final dartRuns = analysis.adapterRuns
      .where((run) => run.id == 'dart')
      .toList(growable: false);
  if (dartRuns.length != 1 ||
      dartRuns.single.status != AdapterRunStatus.executed) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'dart-support-run-not-executed',
    );
  }
  if (!analysis.project.targetMatrix.isComplete ||
      analysis.project.targets.isEmpty ||
      !analysis.project.rootCoverage.internalBoundaryComplete ||
      !_compatibleRootCoverage(analysis.project) ||
      (analysis.project.analysisMode.requiresPublicEntrypoints &&
          analysis.project.rootCoverage.publicEntrypoints.isEmpty)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'analysis-coverage-incomplete',
    );
  }
  final currentIntegrity = analysis.graph.integrityFor(
    analysis.project.targets,
  );
  if (!analysis.graphIntegrity.complete || !currentIntegrity.complete) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'graph-integrity-incomplete',
    );
  }
}

void _requireLivePubspecAgreement(List<int> liveBytes, ProjectContext project) {
  final Object? decoded;
  try {
    decoded = loadYaml(utf8.decode(liveBytes));
  } on Object {
    throw const _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'project-pubspec-semantic-drift',
      'pubspec.yaml',
    );
  }
  if (decoded is! Map ||
      decoded['name'] != project.packageName ||
      _hashCanonical(decoded) != _hashCanonical(project.pubspec)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'project-pubspec-semantic-drift',
      'pubspec.yaml',
    );
  }
}

bool _compatibleRootCoverage(ProjectContext project) {
  final expected = switch (project.analysisMode) {
    AnalysisMode.application => RootCoverageMode.applicationEntrypoints,
    AnalysisMode.package => RootCoverageMode.packagePublicApi,
    AnalysisMode.packageInternal => RootCoverageMode.packageInternal,
  };
  return project.rootCoverage.mode == expected;
}

L10nConfig _loadV2Config(ProjectContext project) {
  final loaded = L10nConfig.load(project);
  if (loaded is! L10nConfigValid) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'l10n-config-not-valid',
    );
  }
  return loaded.config;
}

void _requireConfigAgreement({
  required ProjectContext project,
  required L10nConfig v2,
  required L10nGenerationConfig strict,
  required L10nToolchainResolved toolchain,
}) {
  final canonicalRoot = _canonicalDirectory(project.root.path);
  final expectedSchema =
      switch ('${toolchain.machineIdentity.frameworkVersion.major}.'
      '${toolchain.machineIdentity.frameworkVersion.minor}.'
      '${toolchain.machineIdentity.frameworkVersion.patch}') {
        '3.38.7' => L10nGenerationSchemaVersion.flutter3387,
        '3.41.5' => L10nGenerationSchemaVersion.flutter3415,
        '3.44.1' => L10nGenerationSchemaVersion.flutter3441,
        '3.44.9' => L10nGenerationSchemaVersion.flutter3449,
        _ => null,
      };
  if (expectedSchema == null || strict.schemaVersion != expectedSchema) {
    throw const _Problem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      _captureStage,
      'generation-config-schema-mismatch',
    );
  }
  final checks = <(bool, String)>[
    (
      _samePhysical(v2.arbDir, p.join(canonicalRoot, strict.arbDirectory)),
      'generation-config-arb-directory-disagreement',
    ),
    (
      _samePhysicalFile(
        v2.templateArbPath,
        p.join(canonicalRoot, strict.templateArbPath),
      ),
      'generation-config-template-disagreement',
    ),
    (
      _samePhysicalCandidate(
        v2.outputDir,
        p.join(canonicalRoot, strict.outputDirectory),
      ),
      'generation-config-output-directory-disagreement',
    ),
    (
      _samePhysicalCandidate(
        v2.generatedLibraryPath,
        p.join(canonicalRoot, strict.baseOutputPath),
      ),
      'generation-config-base-output-disagreement',
    ),
    (
      v2.outputClass == strict.outputClass,
      'generation-config-output-class-disagreement',
    ),
    (
      v2.nullableGetter == strict.nullableGetter,
      'generation-config-nullable-getter-disagreement',
    ),
    (
      strict.configurationIdentity.isNotEmpty,
      'generation-config-identity-empty',
    ),
  ];
  final failed = checks.where((check) => !check.$1).toList(growable: false);
  if (failed.isNotEmpty) {
    throw _Problem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      _captureStage,
      failed.first.$2,
    );
  }
}

List<String> _validateSelection({
  required AnalysisSnapshot analysis,
  required ArbInventory inventory,
  required List<String> selectedNodeIds,
  required String templatePath,
}) {
  final keysById = {for (final key in inventory.keys) key.nodeId: key};
  final selectedKeys = <String>[];
  for (final id in selectedNodeIds) {
    final key = keysById[id];
    final findings = analysis.findings
        .where((finding) => finding.node.id == id)
        .toList(growable: false);
    final node = analysis.graph.node(id);
    if (key == null ||
        key.key.startsWith('@') ||
        findings.length != 1 ||
        node == null ||
        !_validFamilyNode(
          node,
          key,
          owner: analysis.graph.nodeOwner(id),
          templatePath: templatePath,
        )) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidSelection,
        _preflightStage,
        'selection-node-invalid',
      );
    }
    final finding = findings.single;
    if (finding.reportingAdapterId != 'l10n' ||
        finding.ruleId != 'PRN-L10N-001' ||
        finding.node.id != node.id ||
        !_sameNodeFacts(finding.node, node)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidSelection,
        _preflightStage,
        'selection-finding-invalid',
      );
    }
    selectedKeys.add(key.key);
  }
  return selectedKeys;
}

void _validateFullFamilyGraph(
  AnalysisSnapshot analysis,
  ArbInventory inventory,
) {
  final expected = {for (final key in inventory.keys) key.nodeId: key};
  final actual = analysis.graph.nodesOfKind(NodeKind.localizationKey).toList();
  if (actual.length != expected.length ||
      actual.any((node) {
        final key = expected[node.id];
        return key == null ||
            !_validFamilyNode(
              node,
              key,
              owner: analysis.graph.nodeOwner(node.id),
              templatePath: key.location,
            );
      })) {
    throw const _Problem(
      L10nEvidenceRejectionCode.scanBlockerPresent,
      _preflightStage,
      'l10n-family-graph-disagreement',
    );
  }
}

bool _validFamilyNode(
  GraphNode node,
  ArbKey key, {
  required String? owner,
  required String templatePath,
}) {
  final metadata = node.metadata;
  return node.kind == NodeKind.localizationKey &&
      owner == 'l10n' &&
      node.id == key.nodeId &&
      node.displayName == key.key &&
      _sameOrigin(node.origin, key.origin) &&
      metadata.length == 5 &&
      metadata['key'] == key.key &&
      metadata['memberKind'] == key.memberKind.name &&
      metadata['hasPlaceholders'] == key.hasPlaceholders &&
      metadata['missingLocales'] == key.missingLocales &&
      metadata['declaredAt'] == key.location &&
      metadata['key'] is String &&
      metadata['memberKind'] is String &&
      metadata['hasPlaceholders'] is bool &&
      metadata['missingLocales'] is String &&
      metadata['declaredAt'] is String;
}

void _validateFamilyGraphSafety(
  AnalysisSnapshot analysis,
  ArbInventory inventory,
  Set<String> selectedIds,
) {
  final familyIds = inventory.keys.map((key) => key.nodeId).toSet();
  final targets = analysis.project.targets;
  final auxiliaryProven = analysis.graph.auxiliaryProven();
  final auxiliaryRetained = analysis.graph.auxiliaryRetained();
  for (final id in familyIds) {
    if (selectedIds.contains(id) &&
        (analysis.graph.isProtected(id) ||
            auxiliaryProven.contains(id) ||
            auxiliaryRetained.contains(id) ||
            targets.any(
              (target) =>
                  analysis.graph.configuredProvenFor(target).contains(id) ||
                  analysis.graph.configuredRetainedFor(target).contains(id),
            ))) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidSelection,
        _preflightStage,
        'family-node-not-removable',
      );
    }
    for (final blocker in analysis.graph.blockersFor(id)) {
      if (_isActiveBlocker(analysis.graph, targets, blocker)) {
        throw _Problem(
          L10nEvidenceRejectionCode.scanBlockerPresent,
          _preflightStage,
          'active-family-blocker',
          _blockerRelativePath(blocker),
        );
      }
    }
  }
}

String? _blockerRelativePath(Blocker blocker) {
  final location = blocker.location;
  if (location == null) return null;
  final path = _normalizeRelative(
    location.replaceFirst(RegExp(r':\d+:\d+(?:-\d+:\d+)?$'), ''),
  );
  return _isSafeRelative(path) ? path : null;
}

bool _isActiveBlocker(
  ReachabilityGraph graph,
  List<BuildTarget> targets,
  Blocker blocker,
) {
  final source = blocker.sourceNodeId;
  if (source == null || !graph.hasNode(source)) return true;
  if (graph.auxiliaryRetained().contains(source)) return true;
  return targets.any(
    (target) => graph.configuredRetainedFor(target).contains(source),
  );
}

void _compareByteAndSemanticInventory({
  required ArbInventory inventory,
  required ArbDocument template,
}) {
  final byteKeys = template.members
      .map((member) => member.decodedKey)
      .where((key) => !key.startsWith('@'))
      .toSet();
  final semanticKeys = inventory.keys.map((key) => key.key).toSet();
  if (!_sameStrings(byteKeys, semanticKeys)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.arbFamilyIncomplete,
      _captureStage,
      'arb-byte-semantic-disagreement',
    );
  }
}

List<String> _outputFamily(
  L10nGenerationConfig config,
  Iterable<String> languages,
) {
  final base = p.posix.basename(config.baseOutputPath);
  final dot = base.indexOf('.');
  if (dot <= 0) {
    throw _Problem(
      L10nEvidenceRejectionCode.unsupportedConfiguration,
      _captureStage,
      'base-output-name-invalid',
      config.baseOutputPath,
    );
  }
  final stem = base.substring(0, dot);
  final suffix = base.substring(dot);
  String languageName(String language) => switch (config.schemaVersion) {
    L10nGenerationSchemaVersion.flutter3387 => '${stem}_$language$suffix',
    L10nGenerationSchemaVersion.flutter3415 => '${stem}_$language$suffix',
    L10nGenerationSchemaVersion.flutter3441 => '${stem}_$language$suffix',
    L10nGenerationSchemaVersion.flutter3449 => '${stem}_$language$suffix',
  };
  return [
    config.baseOutputPath,
    for (final language in (languages.toSet().toList()..sort()))
      p.posix.join(config.outputDirectory, languageName(language)),
  ]..sort();
}

List<String> _captureAnalyzerClosure(
  ProjectContext project,
  String canonicalRoot,
  _CaptureSet capture,
  List<String> outputFamily,
  DartAnalysisWorkspace workspace,
) {
  final paths = _enumerateAnalyzerClosure(project, canonicalRoot, workspace);
  final requiredRoots = {
    for (final target in project.targets) _normalizeRelative(target.entrypoint),
    for (final path in project.rootCoverage.publicEntrypoints)
      _normalizeRelative(path),
    for (final file in project.dartFiles)
      _projectOwnedDartRelative(canonicalRoot, file.path),
  };
  if (!paths.toSet().containsAll(requiredRoots)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analyzer-root-file-missing',
    );
  }
  for (final path in paths) {
    final existing = capture.entries[path];
    if (existing != null && outputFamily.contains(path)) {
      if (existing.state is! L10nSnapshotPresent) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'analyzer-root-file-missing',
          path,
        );
      }
      continue;
    }
    capture.add(path, L10nSnapshotRole.analyzerSource, required: true);
  }
  return paths;
}

String _projectOwnedDartRelative(String canonicalRoot, String input) {
  final absolute = p.normalize(p.absolute(input));
  if (!_within(canonicalRoot, absolute)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analyzer-root-file-outside-project',
    );
  }
  final requestedRelative = _relative(canonicalRoot, absolute);
  _rejectLinkComponents(canonicalRoot, absolute, requestedRelative);
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analyzer-root-file-not-regular',
    );
  }
  final canonical = p.normalize(File(absolute).resolveSymbolicLinksSync());
  if (canonical != absolute || !_within(canonicalRoot, canonical)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analyzer-root-file-outside-project',
    );
  }
  return _relative(canonicalRoot, canonical);
}

List<String> _enumerateAnalyzerClosure(
  ProjectContext project,
  String canonicalRoot,
  DartAnalysisWorkspace workspace,
) {
  _rejectProjectDartLinks(canonicalRoot);
  final paths = <String>[];
  final folded = <String, String>{};
  for (final absolute in workspace.dartFiles) {
    final normalized = p.normalize(p.absolute(absolute));
    if (!_within(canonicalRoot, normalized)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-root-file-outside-project',
      );
    }
    final requestedRelative = _relative(canonicalRoot, normalized);
    _rejectLinkComponents(canonicalRoot, normalized, requestedRelative);
    final type = FileSystemEntity.typeSync(normalized, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-root-file-not-regular',
      );
    }
    final canonical = p.normalize(File(normalized).resolveSymbolicLinksSync());
    if (canonical != normalized || !_within(canonicalRoot, canonical)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-root-file-outside-project',
      );
    }
    final relative = _relative(canonicalRoot, canonical);
    final fold = _asciiFold(relative);
    if (folded.putIfAbsent(fold, () => relative) != relative) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-root-casefold-collision',
      );
    }
    paths.add(relative);
  }
  paths.sort();
  return List.unmodifiable(paths);
}

void _rejectProjectDartLinks(String canonicalRoot) {
  for (final entity in Directory(
    canonicalRoot,
  ).listSync(recursive: true, followLinks: false)) {
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) ==
            FileSystemEntityType.link &&
        p.extension(entity.path).toLowerCase() == '.dart') {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-root-file-symlink',
        _relative(canonicalRoot, entity.path),
      );
    }
  }
}

List<String> _captureOutputSiblings({
  required _CaptureSet capture,
  required String outputDirectory,
  required List<String> outputFamily,
  required String baseOutputPath,
  required List<String> arbPaths,
}) {
  final siblings = _enumerateOutputSiblings(
    canonicalRoot: capture.canonicalRoot,
    outputDirectory: outputDirectory,
    outputFamily: outputFamily,
    baseOutputPath: baseOutputPath,
    arbPaths: arbPaths,
  );
  for (final path in siblings) {
    final existing = capture.entries[path];
    if (existing != null) {
      if (existing.state is! L10nSnapshotPresent) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'output-sibling-not-present',
          path,
        );
      }
      continue;
    }
    capture.add(path, L10nSnapshotRole.verificationInput, required: true);
  }
  return siblings;
}

List<String> _enumerateOutputSiblings({
  required String canonicalRoot,
  required String outputDirectory,
  required List<String> outputFamily,
  required String baseOutputPath,
  required List<String> arbPaths,
}) {
  final directory = Directory(
    p.join(canonicalRoot, p.fromUri(outputDirectory)),
  );
  final type = FileSystemEntity.typeSync(directory.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return const [];
  if (type != FileSystemEntityType.directory) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'output-directory-not-regular-directory',
      outputDirectory,
    );
  }
  final expectedByFold = <String, String>{
    for (final path in outputFamily) _asciiFold(path): path,
  };
  final arbPathSet = arbPaths.toSet();
  final base = p.posix.basename(baseOutputPath);
  final dot = base.indexOf('.');
  final stem = _asciiFold(base.substring(0, dot));
  final suffix = _asciiFold(base.substring(dot));
  final siblings = <String>[];
  for (final entity in directory.listSync(followLinks: false)) {
    final relative = _relative(canonicalRoot, entity.path);
    final entityType = FileSystemEntity.typeSync(
      entity.path,
      followLinks: false,
    );
    if (entityType == FileSystemEntityType.directory) continue;
    if (entityType != FileSystemEntityType.file) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'output-sibling-not-regular',
        relative,
      );
    }
    final expectedSpelling = expectedByFold[_asciiFold(relative)];
    if (expectedSpelling != null) {
      if (expectedSpelling != relative) {
        throw _Problem(
          L10nEvidenceRejectionCode.outputFamilyAmbiguous,
          _captureStage,
          'output-family-casefold-collision',
          relative,
        );
      }
      continue;
    }
    if (arbPathSet.contains(relative)) continue;
    final name = _asciiFold(p.posix.basename(relative));
    if (name.startsWith('${stem}_') && name.endsWith(suffix)) {
      throw _Problem(
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        _captureStage,
        'unowned-output-family-sibling',
        relative,
      );
    }
    siblings.add(relative);
  }
  siblings.sort();
  return List.unmodifiable(siblings);
}

void _prevalidateAnalysisOptionsPlacement(
  String canonicalRoot, {
  Set<String> nestedAuthorityPaths = const {},
}) {
  final rootOptions = p.join(canonicalRoot, 'analysis_options.yaml');
  final rootType = FileSystemEntity.typeSync(rootOptions, followLinks: false);
  if (rootType != FileSystemEntityType.notFound &&
      rootType != FileSystemEntityType.file) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analysis-options-include-invalid',
      'analysis_options.yaml',
    );
  }
  if (rootType == FileSystemEntityType.notFound) {
    var ancestor = p.dirname(canonicalRoot);
    while (true) {
      final candidate = p.join(ancestor, 'analysis_options.yaml');
      if (FileSystemEntity.typeSync(candidate, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'analysis-options-inherited-unsupported',
        );
      }
      final parent = p.dirname(ancestor);
      if (parent == ancestor) break;
      ancestor = parent;
    }
  }
  for (final entity in Directory(
    canonicalRoot,
  ).listSync(recursive: true, followLinks: false)) {
    if (p.basename(entity.path) == 'analysis_options.yaml' &&
        p.normalize(entity.path) != p.normalize(rootOptions) &&
        !nestedAuthorityPaths.contains(
          _relative(canonicalRoot, p.normalize(entity.path)),
        )) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-nested-unsupported',
      );
    }
  }
}

void _validateAnalyzerContextAuthorities(
  DartAnalysisWorkspace workspace,
  String canonicalRoot,
  bool hasRootOptions,
) {
  final expectedPackageConfig = p.normalize(
    p.join(canonicalRoot, '.dart_tool/package_config.json'),
  );
  final expectedOptions = hasRootOptions
      ? p.normalize(p.join(canonicalRoot, 'analysis_options.yaml'))
      : null;
  final contexts = workspace.collection.contexts;
  if (contexts.length != 1 ||
      p.normalize(contexts.single.contextRoot.root.path) != canonicalRoot ||
      p.normalize(contexts.single.contextRoot.workspace.root) !=
          canonicalRoot) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analyzer-context-root-unsupported',
    );
  }
  for (final context in contexts) {
    final packagesFile = context.contextRoot.packagesFile;
    if (packagesFile == null ||
        FileSystemEntity.typeSync(packagesFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        p.normalize(File(packagesFile.path).resolveSymbolicLinksSync()) !=
            expectedPackageConfig) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analyzer-nested-package-config-unsupported',
      );
    }
    final optionsFile = context.contextRoot.optionsFile;
    if ((optionsFile == null) != (expectedOptions == null) ||
        (optionsFile != null &&
            (FileSystemEntity.typeSync(optionsFile.path, followLinks: false) !=
                    FileSystemEntityType.file ||
                p.normalize(
                      File(optionsFile.path).resolveSymbolicLinksSync(),
                    ) !=
                    expectedOptions))) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-inherited-unsupported',
      );
    }
  }
}

final class _AnalyzerContextAuthorityProbe {
  const _AnalyzerContextAuthorityProbe({
    required this.workspace,
    required this.identity,
  });

  final DartAnalysisWorkspace workspace;
  final String identity;
}

_AnalyzerContextAuthorityProbe _probeAnalyzerContextAuthorities(
  ProjectContext project,
  String canonicalRoot, {
  Set<String> nestedAuthorityPaths = const {},
}) {
  _prevalidateAnalysisOptionsPlacement(
    canonicalRoot,
    nestedAuthorityPaths: nestedAuthorityPaths,
  );
  final workspace = DartAnalysisWorkspace(project);
  final hasRootOptions =
      FileSystemEntity.typeSync(
        p.join(canonicalRoot, 'analysis_options.yaml'),
        followLinks: false,
      ) ==
      FileSystemEntityType.file;
  _validateAnalyzerContextAuthorities(workspace, canonicalRoot, hasRootOptions);
  final contexts = <Map<String, Object?>>[
    for (final context in workspace.collection.contexts)
      {
        'root': _relative(canonicalRoot, context.contextRoot.root.path),
        'packages': '.dart_tool/package_config.json',
        'options': hasRootOptions ? 'analysis_options.yaml' : null,
        'nestedOptions': nestedAuthorityPaths.toList()..sort(),
      },
  ]..sort(_compareCanonicalMaps);
  return _AnalyzerContextAuthorityProbe(
    workspace: workspace,
    identity: _hashCanonical({'contexts': contexts}),
  );
}

_AnalyzerContextAuthorityProbe _probeAnalyzerContextAuthoritiesForDrift(
  ProjectContext project,
  String canonicalRoot, {
  Set<String> nestedAuthorityPaths = const {},
}) {
  try {
    return _probeAnalyzerContextAuthorities(
      project,
      canonicalRoot,
      nestedAuthorityPaths: nestedAuthorityPaths,
    );
  } on Object {
    throw const _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'analyzer-context-authority-drift',
    );
  }
}

final class _CapturedAnalysisOptions {
  const _CapturedAnalysisOptions({
    required this.projectOwnedPaths,
    required this.nestedAuthorityPaths,
    required this.externalAuthorities,
  });

  final List<String> projectOwnedPaths;
  final Set<String> nestedAuthorityPaths;
  final List<L10nExternalAnalysisOptionsAuthority> externalAuthorities;
}

_CapturedAnalysisOptions _captureAnalysisOptions(
  _CaptureSet capture,
  L10nPackageConfigProjection packages,
  Map<dynamic, dynamic> projectPubspec,
  List<int> lockfileBytes,
) {
  const rootPath = 'analysis_options.yaml';
  final rootAbsolute = p.join(capture.canonicalRoot, rootPath);
  final rootType = FileSystemEntity.typeSync(rootAbsolute, followLinks: false);
  if (rootType == FileSystemEntityType.notFound) {
    capture.add(rootPath, L10nSnapshotRole.verificationInput, required: false);
  } else if (rootType != FileSystemEntityType.file) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analysis-options-include-invalid',
      rootPath,
    );
  }

  final projectPaths = <String>{};
  final external = <L10nExternalAnalysisOptionsAuthority>[];
  final active = <String>{};
  final complete = <String>{};

  void visit({required String absolute, required String authorityRoot}) {
    final normalized = p.normalize(p.absolute(absolute));
    if (!_within(authorityRoot, normalized) ||
        FileSystemEntity.typeSync(normalized, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-include-invalid',
      );
    }
    final canonical = p.normalize(File(normalized).resolveSymbolicLinksSync());
    if (canonical != normalized || !_within(authorityRoot, canonical)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-include-unsafe',
      );
    }
    if (!active.add(canonical)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-include-cycle',
      );
    }
    if (complete.contains(canonical)) {
      active.remove(canonical);
      return;
    }

    final bool projectOwned = _within(capture.canonicalRoot, canonical);
    final List<int> bytes;
    final String displayPath;
    if (projectOwned) {
      displayPath = _relative(capture.canonicalRoot, canonical);
      if (!_isSafeRelative(displayPath)) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'analysis-options-include-invalid',
          displayPath,
        );
      }
      final captured = capture.add(
        displayPath,
        L10nSnapshotRole.verificationInput,
        required: true,
      );
      bytes = captured.bytes!;
      projectPaths.add(displayPath);
    } else {
      final captured = _captureExternalOptionsFile(canonical, authorityRoot);
      external.add(captured);
      bytes = captured.sourceBytes.copy();
      displayPath = canonical;
    }

    final Object? yaml;
    try {
      yaml = loadYaml(utf8.decode(bytes));
    } on Object {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-yaml-invalid',
        projectOwned ? displayPath : null,
      );
    }
    if (yaml != null && yaml is! Map) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-root-invalid',
        projectOwned ? displayPath : null,
      );
    }
    final map = yaml is Map ? yaml : const <Object?, Object?>{};
    if (map.containsKey('plugins') && map['plugins'] != null) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-plugins-unsupported',
        projectOwned ? displayPath : null,
      );
    }
    final analyzer = map['analyzer'];
    if (analyzer is Map &&
        analyzer.containsKey('plugins') &&
        analyzer['plugins'] != null &&
        !_legacyAnalyzerPluginsAreInert(
          analyzer['plugins'],
          packages: packages,
          projectPubspec: projectPubspec,
          lockfileBytes: lockfileBytes,
        )) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-plugins-unsupported',
        projectOwned ? displayPath : null,
      );
    }
    final include = map['include'];
    if (include != null) {
      final includes = include is String
          ? <Object?>[include]
          : include is List
          ? include.cast<Object?>()
          : const <Object?>[];
      if (includes.isEmpty ||
          includes.any((value) => value is! String || value.isEmpty)) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'analysis-options-include-invalid',
          projectOwned ? displayPath : null,
        );
      }
      for (final value in includes.cast<String>()) {
        if (value.startsWith('package:')) {
          final match = RegExp(
            r'^package:([a-z_][a-z0-9_]*)/(.+)$',
          ).firstMatch(value);
          if (match == null) {
            throw const _Problem(
              L10nEvidenceRejectionCode.invalidInputPath,
              _captureStage,
              'analysis-options-package-include-invalid',
            );
          }
          final packageName = match.group(1)!;
          final packagePath = _normalizeRelative(match.group(2)!);
          final packageRoot = packages.canonicalRootsByPackage[packageName];
          if (packageRoot == null || !_isSafeRelative(packagePath)) {
            throw const _Problem(
              L10nEvidenceRejectionCode.invalidInputPath,
              _captureStage,
              'analysis-options-package-include-unresolved',
            );
          }
          visit(
            absolute: p.join(packageRoot, 'lib', p.fromUri(packagePath)),
            authorityRoot: packageRoot,
          );
        } else {
          if (!_isSafeAnalysisOptionsInclude(value)) {
            throw const _Problem(
              L10nEvidenceRejectionCode.invalidInputPath,
              _captureStage,
              'analysis-options-include-escape',
            );
          }
          final child = p.normalize(
            p.join(p.dirname(canonical), p.fromUri(value)),
          );
          if (!_within(authorityRoot, child)) {
            throw const _Problem(
              L10nEvidenceRejectionCode.invalidInputPath,
              _captureStage,
              'analysis-options-include-escape',
            );
          }
          visit(absolute: child, authorityRoot: authorityRoot);
        }
      }
    }
    active.remove(canonical);
    complete.add(canonical);
  }

  if (rootType == FileSystemEntityType.file) {
    visit(absolute: rootAbsolute, authorityRoot: capture.canonicalRoot);
  }
  final nestedAuthorityPaths = <String>{};
  final packageRoots = packages.projectOwnedRootsByPackage.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  for (final package in packageRoots) {
    final relative = '${package.value}/analysis_options.yaml';
    final absolute = p.join(capture.canonicalRoot, p.fromUri(relative));
    final type = FileSystemEntity.typeSync(absolute, followLinks: false);
    nestedAuthorityPaths.add(relative);
    projectPaths.add(relative);
    if (type == FileSystemEntityType.notFound) {
      capture.add(
        relative,
        L10nSnapshotRole.verificationInput,
        required: false,
      );
    } else if (type == FileSystemEntityType.file) {
      visit(
        absolute: absolute,
        authorityRoot: packages.canonicalRootsByPackage[package.key]!,
      );
    } else {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'analysis-options-include-invalid',
        relative,
      );
    }
  }
  final sortedProject = projectPaths.toList()..sort();
  external.sort(
    (left, right) => left.canonicalPath.compareTo(right.canonicalPath),
  );
  return _CapturedAnalysisOptions(
    projectOwnedPaths: sortedProject,
    nestedAuthorityPaths: Set.unmodifiable(nestedAuthorityPaths),
    externalAuthorities: external,
  );
}

bool _legacyAnalyzerPluginsAreInert(
  Object? rawPlugins, {
  required L10nPackageConfigProjection packages,
  required Map<dynamic, dynamic> projectPubspec,
  required List<int> lockfileBytes,
}) {
  if (rawPlugins is! List) return false;
  final pluginNames = <String>{};
  for (final rawPlugin in rawPlugins) {
    if (rawPlugin is! String ||
        !_validPackageName(rawPlugin) ||
        !pluginNames.add(rawPlugin)) {
      return false;
    }
  }
  if (pluginNames.isEmpty) return true;
  if (pluginNames.any(packages.canonicalRootsByPackage.containsKey)) {
    return false;
  }
  for (final sectionName in const {
    'dependencies',
    'dev_dependencies',
    'dependency_overrides',
  }) {
    final section = projectPubspec[sectionName];
    if (section is Map && pluginNames.any(section.containsKey)) return false;
  }
  try {
    final lockfile = loadYaml(utf8.decode(lockfileBytes));
    if (lockfile is! Map || lockfile['packages'] is! Map) return false;
    final lockedPackages = lockfile['packages']! as Map;
    if (lockedPackages.keys.any((key) => key is! String)) return false;
    return pluginNames.every(
      (pluginName) => !lockedPackages.containsKey(pluginName),
    );
  } on Object {
    return false;
  }
}

bool _isSafeAnalysisOptionsInclude(String value) {
  if (value.isEmpty ||
      p.posix.isAbsolute(value) ||
      value.contains('\\') ||
      value.contains(':') ||
      value.contains('%') ||
      value.contains('?') ||
      value.contains('#')) {
    return false;
  }
  for (final codeUnit in value.codeUnits) {
    if (codeUnit < 0x20 || codeUnit > 0x7e) return false;
  }
  return value
      .split('/')
      .every(
        (segment) =>
            segment == '.' ||
            segment == '..' ||
            RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(segment),
      );
}

L10nExternalAnalysisOptionsAuthority _captureExternalOptionsFile(
  String path,
  String authorityRoot,
) {
  final normalized = p.normalize(p.absolute(path));
  if (!_within(authorityRoot, normalized) ||
      FileSystemEntity.typeSync(normalized, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'analysis-options-external-invalid',
    );
  }
  final file = File(normalized);
  final canonicalBefore = p.normalize(file.resolveSymbolicLinksSync());
  final before = file.statSync();
  final bytes = file.readAsBytesSync();
  final after = file.statSync();
  final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
  final mode = Platform.isWindows ? null : before.mode & 0xfff;
  if (canonicalBefore != normalized ||
      canonicalAfter != canonicalBefore ||
      !_sameFileStat(before, after) ||
      (mode != null && (mode & 0x12) != 0)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'analysis-options-external-drift',
    );
  }
  return L10nExternalAnalysisOptionsAuthority(
    canonicalPath: canonicalBefore,
    authorityRoot: authorityRoot,
    sourceBytes: ImmutableBytes.copyOf(bytes),
    posixMode: mode,
    size: before.size,
    modifiedMicros: before.modified.microsecondsSinceEpoch,
    changedMicros: before.changed.microsecondsSinceEpoch,
  );
}

List<String> _enumerateArbPaths(String canonicalRoot, String arbDirectory) {
  final absolute = p.join(canonicalRoot, p.fromUri(arbDirectory));
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'arb-directory-invalid',
      arbDirectory,
    );
  }
  final paths = <String>[];
  for (final entity in Directory(absolute).listSync(followLinks: false)) {
    if (p.extension(entity.path).toLowerCase() != '.arb') continue;
    final relative = _relative(canonicalRoot, entity.path);
    if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'arb-file-not-regular',
        relative,
      );
    }
    paths.add(relative);
  }
  paths.sort();
  return List.unmodifiable(paths);
}

final class _CaptureSet {
  _CaptureSet(this.canonicalRoot);

  final String canonicalRoot;
  final SplayTreeMap<String, L10nSnapshotEntry> entries = SplayTreeMap();
  final Map<String, _CapturedPath> _captured = {};
  final Map<String, String> _foldedPaths = {};

  _CapturedPath add(
    String input,
    L10nSnapshotRole role, {
    required bool required,
  }) {
    final relative = _normalizeRelative(input);
    if (!_isSafeRelative(relative)) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'snapshot-path-invalid',
        input,
      );
    }
    final fold = _asciiFold(relative);
    final foldedPrior = _foldedPaths.putIfAbsent(fold, () => relative);
    if (foldedPrior != relative) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'snapshot-path-casefold-collision',
        relative,
      );
    }
    final prior = entries[relative];
    if (prior != null) {
      if (prior.role != role) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'role-path-collision',
          relative,
        );
      }
      return _captured[relative]!;
    }
    _checkAncestorFileConflicts(relative);
    final captured = _capturePath(canonicalRoot, relative, required: required);
    final state = captured.bytes == null
        ? const L10nSnapshotAbsent()
        : L10nSnapshotPresent(
            sourceBytes: ImmutableBytes.copyOf(captured.bytes!),
            stageBytes: ImmutableBytes.copyOf(captured.bytes!),
            sourceSha256: sha256.convert(captured.bytes!).toString(),
            posixMode: captured.mode,
          );
    entries[relative] = L10nSnapshotEntry(
      relativePosixPath: relative,
      role: role,
      state: state,
    );
    _captured[relative] = captured;
    return captured;
  }

  void replaceStageBytes(String path, List<int> bytes) {
    final entry = entries[path]!;
    final present = entry.state as L10nSnapshotPresent;
    entries[path] = L10nSnapshotEntry(
      relativePosixPath: path,
      role: entry.role,
      state: L10nSnapshotPresent(
        sourceBytes: present.sourceBytes,
        stageBytes: ImmutableBytes.copyOf(bytes),
        sourceSha256: present.sourceSha256,
        posixMode: present.posixMode,
      ),
    );
  }

  void verifySecondRead() {
    for (final entry in _captured.entries) {
      try {
        final current = _capturePath(
          canonicalRoot,
          entry.key,
          required: entry.value.bytes != null,
        );
        if (entry.value.sameAs(current)) continue;
      } on Object {
        // Every verification-time transition is source drift, even when the
        // resulting state would be an invalid initial authority.
      }
      throw _Problem(
        L10nEvidenceRejectionCode.sourceDrift,
        _captureStage,
        'snapshot-source-drift',
        entry.key,
      );
    }
  }

  void _checkAncestorFileConflicts(String relative) {
    var ancestor = p.posix.dirname(relative);
    while (ancestor != '.') {
      if (entries.containsKey(ancestor)) {
        throw _Problem(
          L10nEvidenceRejectionCode.invalidInputPath,
          _captureStage,
          'snapshot-ancestor-file-collision',
          relative,
        );
      }
      ancestor = p.posix.dirname(ancestor);
    }
    if (entries.keys.any((path) => path.startsWith('$relative/'))) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'snapshot-ancestor-file-collision',
        relative,
      );
    }
  }
}

final class _CapturedPath {
  const _CapturedPath({
    required this.absolutePath,
    required this.canonicalPath,
    required this.bytes,
    required this.mode,
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
  });

  final String absolutePath;
  final String? canonicalPath;
  final List<int>? bytes;
  final int? mode;
  final int? size;
  final int? modifiedMicros;
  final int? changedMicros;

  bool sameAs(_CapturedPath other) =>
      absolutePath == other.absolutePath &&
      canonicalPath == other.canonicalPath &&
      mode == other.mode &&
      size == other.size &&
      modifiedMicros == other.modifiedMicros &&
      changedMicros == other.changedMicros &&
      ((bytes == null && other.bytes == null) ||
          (bytes != null &&
              other.bytes != null &&
              _sameBytes(bytes!, other.bytes!)));
}

_CapturedPath _capturePath(
  String canonicalRoot,
  String relative, {
  required bool required,
}) {
  final absolute = p.normalize(p.join(canonicalRoot, p.fromUri(relative)));
  if (!_within(canonicalRoot, absolute)) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'snapshot-path-escape',
      relative,
    );
  }
  _rejectLinkComponents(canonicalRoot, absolute, relative);
  final type = FileSystemEntity.typeSync(absolute, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    if (required) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'required-input-missing',
        relative,
      );
    }
    return _CapturedPath(
      absolutePath: absolute,
      canonicalPath: null,
      bytes: null,
      mode: null,
      size: null,
      modifiedMicros: null,
      changedMicros: null,
    );
  }
  if (type != FileSystemEntityType.file) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'input-not-regular-file',
      relative,
    );
  }
  final file = File(absolute);
  final canonicalBefore = p.normalize(file.resolveSymbolicLinksSync());
  if (!_within(canonicalRoot, canonicalBefore) || canonicalBefore != absolute) {
    throw _Problem(
      L10nEvidenceRejectionCode.invalidInputPath,
      _captureStage,
      'input-canonical-path-invalid',
      relative,
    );
  }
  final before = file.statSync();
  final bytes = file.readAsBytesSync();
  final after = file.statSync();
  final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
  if (!_sameFileStat(before, after) || canonicalBefore != canonicalAfter) {
    throw _Problem(
      L10nEvidenceRejectionCode.sourceDrift,
      _captureStage,
      'snapshot-source-drift',
      relative,
    );
  }
  return _CapturedPath(
    absolutePath: absolute,
    canonicalPath: canonicalBefore,
    bytes: List<int>.unmodifiable(bytes),
    mode: Platform.isWindows ? null : before.mode & 0xfff,
    size: before.size,
    modifiedMicros: before.modified.microsecondsSinceEpoch,
    changedMicros: before.changed.microsecondsSinceEpoch,
  );
}

void _rejectLinkComponents(
  String canonicalRoot,
  String absolute,
  String relative,
) {
  var current = canonicalRoot;
  final remainder = p.relative(absolute, from: canonicalRoot);
  for (final segment in p.split(remainder)) {
    current = p.join(current, segment);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw _Problem(
        L10nEvidenceRejectionCode.invalidInputPath,
        _captureStage,
        'input-symlink-component',
        relative,
      );
    }
    if (type == FileSystemEntityType.notFound) break;
  }
}

L10nPackageConfigProjection _projectPackageConfig({
  required List<int> sourceBytes,
  required String canonicalProjectRoot,
  required String selectedPackageName,
  required L10nToolchainResolved toolchain,
}) {
  final source = ImmutableBytes.copyOf(sourceBytes);
  final parsed = ArbDocument.parse(sourceBytes);
  if (parsed is! ArbParseSuccess) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-config-json-invalid',
      '.dart_tool/package_config.json',
    );
  }
  final document = parsed.document;
  const knownTop = {
    'configVersion',
    'packages',
    'generator',
    'generatorVersion',
    'pubCache',
    'flutterRoot',
    'flutterVersion',
  };
  final configVersion = document.member('configVersion')?.decodedValue;
  if (document.members.any((member) => !knownTop.contains(member.decodedKey)) ||
      configVersion is! int ||
      configVersion != 2 ||
      document.member('packages')?.decodedValue is! List) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-config-schema-invalid',
      '.dart_tool/package_config.json',
    );
  }
  final packagesMember = document.member('packages')!;
  final spans = _arrayObjectSpans(sourceBytes, packagesMember.valueSpan);
  final decodedPackages = packagesMember.decodedValue! as List<Object?>;
  if (spans.length != decodedPackages.length) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-record-json-invalid',
      '.dart_tool/package_config.json',
    );
  }
  final configUri = File(
    p.join(canonicalProjectRoot, '.dart_tool/package_config.json'),
  ).uri;
  final records = <_PackageRecord>[];
  final names = <String>{};
  final roots = <String>{};
  final replacements = <_ByteReplacement>[];
  final externalAuthorities = <_ExternalPackageAuthority>[];
  final projectOwnedAuthorities = <_ProjectOwnedPackageAuthority>[];
  final projectOwnedRootsByPackage = <String, String>{};
  var selectedCount = 0;
  for (var index = 0; index < spans.length; index++) {
    final span = spans[index];
    final recordBytes = sourceBytes.sublist(span.start, span.endExclusive);
    final recordParse = ArbDocument.parse(recordBytes);
    if (recordParse is! ArbParseSuccess) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-record-json-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final recordDocument = recordParse.document;
    const recordKeys = {'name', 'rootUri', 'packageUri', 'languageVersion'};
    if (recordDocument.members.length != recordKeys.length ||
        recordDocument.members.any(
          (member) => !recordKeys.contains(member.decodedKey),
        )) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-record-fields-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final name = recordDocument.member('name')?.decodedValue;
    final rootUriText = recordDocument.member('rootUri')?.decodedValue;
    final packageUri = recordDocument.member('packageUri')?.decodedValue;
    final languageVersion = recordDocument
        .member('languageVersion')
        ?.decodedValue;
    if (name is! String ||
        !_validPackageName(name) ||
        rootUriText is! String ||
        packageUri != 'lib/' ||
        languageVersion is! String ||
        !RegExp(
          r'^(2|[3-9][0-9]*)\.(0|[1-9][0-9]*)$',
        ).hasMatch(languageVersion) ||
        !names.add(name)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-record-values-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final rootUri = Uri.tryParse(rootUriText);
    if (rootUri == null ||
        rootUri.hasQuery ||
        rootUri.hasFragment ||
        (rootUri.hasScheme && rootUri.scheme != 'file') ||
        (rootUri.hasScheme && rootUri.host.isNotEmpty) ||
        (!rootUri.hasScheme && rootUri.hasAuthority)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-root-uri-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final resolvedUri = rootUri.hasScheme
        ? rootUri
        : configUri.resolveUri(rootUri);
    final requestedRoot = p.normalize(p.fromUri(resolvedUri));
    if (FileSystemEntity.typeSync(requestedRoot, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-root-not-directory',
        '.dart_tool/package_config.json',
      );
    }
    final canonicalRoot = _canonicalDirectory(requestedRoot);
    final packageLib = p.normalize(p.join(canonicalRoot, 'lib'));
    final packageLibType = FileSystemEntity.typeSync(
      packageLib,
      followLinks: false,
    );
    if ((packageLibType != FileSystemEntityType.notFound &&
            (packageLibType != FileSystemEntityType.directory ||
                _canonicalDirectory(packageLib) != packageLib)) ||
        !_within(canonicalRoot, packageLib)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-lib-root-invalid',
        '.dart_tool/package_config.json',
      );
    }
    if (!roots.add(_asciiFold(canonicalRoot))) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-canonical-root-duplicate',
        '.dart_tool/package_config.json',
      );
    }
    final selected = name == selectedPackageName;
    if (selected) {
      selectedCount++;
      if (canonicalRoot != canonicalProjectRoot) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'selected-package-root-mismatch',
          '.dart_tool/package_config.json',
        );
      }
    } else if (_within(canonicalProjectRoot, canonicalRoot)) {
      if (requestedRoot != canonicalRoot) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'project-package-root-invalid',
          '.dart_tool/package_config.json',
        );
      }
      final relativeRoot = _relative(canonicalProjectRoot, canonicalRoot);
      if (!_isSafeRelative(relativeRoot)) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'project-package-root-invalid',
          '.dart_tool/package_config.json',
        );
      }
      projectOwnedRootsByPackage[name] = relativeRoot;
      projectOwnedAuthorities.add(
        _captureProjectOwnedPackage(
          name,
          canonicalProjectRoot,
          canonicalRoot,
          relativeRoot,
        ),
      );
    } else {
      if (_within(canonicalRoot, canonicalProjectRoot)) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-overlaps-project',
          '.dart_tool/package_config.json',
        );
      }
      externalAuthorities.add(_captureExternalPackage(name, canonicalRoot));
    }
    final rootToken = recordDocument.member('rootUri')!.valueSpan;
    final projectOwnedRelative = projectOwnedRootsByPackage[name];
    final projectedRoot = selected
        ? '../'
        : projectOwnedRelative != null
        ? '../$projectOwnedRelative/'
        : Directory(canonicalRoot).uri.toString();
    replacements.add(
      _ByteReplacement(
        start: span.start + rootToken.start,
        end: span.start + rootToken.endExclusive,
        bytes: utf8.encode(jsonEncode(projectedRoot)),
      ),
    );
    records.add(
      _PackageRecord(
        name: name,
        canonicalRoot: canonicalRoot,
        languageVersion: languageVersion,
      ),
    );
  }
  if (selectedCount == 0) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'selected-package-entry-missing',
      '.dart_tool/package_config.json',
    );
  }
  if (selectedCount != 1) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'selected-package-entry-ambiguous',
      '.dart_tool/package_config.json',
    );
  }
  _validatePackageToolchain(document, records, toolchain);
  final stageBytes = _splice(sourceBytes, replacements);
  _validateProjectedPackageBytes(
    stageBytes,
    canonicalProjectRoot,
    selectedPackageName,
    records,
    projectOwnedRootsByPackage,
  );
  records.sort((left, right) => left.name.compareTo(right.name));
  externalAuthorities.sort((left, right) => left.name.compareTo(right.name));
  projectOwnedAuthorities.sort(
    (left, right) => left.name.compareTo(right.name),
  );
  final identity = _hashCanonical({
    'sourceSha256': source.sha256Hex,
    'stageSha256': sha256.convert(stageBytes).toString(),
    'records': [for (final record in records) record.identity],
    'external': [
      for (final authority in externalAuthorities) authority.identity,
    ],
    'projectOwned': [
      for (final authority in projectOwnedAuthorities) authority.identity,
    ],
  });
  final authorityIdentity = _hashCanonical({
    'stageSha256': sha256.convert(stageBytes).toString(),
    'records': [
      for (final record in records)
        {
          ...record.identity,
          if (record.name == selectedPackageName)
            'root': 'selected-project-root',
          if (projectOwnedRootsByPackage[record.name] case final relative?)
            'root': 'project-owned:$relative',
        },
    ],
    'external': [
      for (final authority in externalAuthorities) authority.identity,
    ],
    'projectOwned': [
      for (final authority in projectOwnedAuthorities) authority.identity,
    ],
  });
  return L10nPackageConfigProjection._(
    sourceBytes: source,
    stageBytes: ImmutableBytes.copyOf(stageBytes),
    identity: identity,
    authorityIdentity: authorityIdentity,
    canonicalRootsByPackage: {
      for (final record in records) record.name: record.canonicalRoot,
    },
    projectOwnedRootsByPackage: projectOwnedRootsByPackage,
    externalAuthorities: externalAuthorities,
    projectOwnedAuthorities: projectOwnedAuthorities,
  );
}

void _validatePackageToolchain(
  ArbDocument document,
  List<_PackageRecord> records,
  L10nToolchainResolved toolchain,
) {
  if (document.member('generator')?.decodedValue != 'pub' ||
      document.member('flutterRoot') == null ||
      document.member('flutterVersion') == null ||
      document.member('generatorVersion') == null) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-toolchain-binding-incomplete',
      '.dart_tool/package_config.json',
    );
  }
  final flutterRoot = document.member('flutterRoot')?.decodedValue;
  final uri = flutterRoot is String ? Uri.tryParse(flutterRoot) : null;
  if (uri == null ||
      uri.scheme != 'file' ||
      uri.host.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-flutter-root-mismatch',
      '.dart_tool/package_config.json',
    );
  }
  final canonical = _canonicalDirectory(p.fromUri(uri));
  final canonicalFileUri = Uri.file(canonical).toString();
  final canonicalDirectoryUri = Directory(canonical).uri.toString();
  if (canonical != toolchain.canonicalSdkRoot ||
      (flutterRoot != canonicalFileUri &&
          flutterRoot != canonicalDirectoryUri)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-flutter-root-mismatch',
      '.dart_tool/package_config.json',
    );
  }
  final flutterVersion = document.member('flutterVersion')?.decodedValue;
  if (flutterVersion is! String ||
      flutterVersion != '${toolchain.machineIdentity.frameworkVersion}') {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-flutter-version-mismatch',
      '.dart_tool/package_config.json',
    );
  }
  final generatorVersion = document.member('generatorVersion')?.decodedValue;
  if (generatorVersion is! String ||
      generatorVersion != toolchain.machineIdentity.dartSdkVersion) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-generator-version-mismatch',
      '.dart_tool/package_config.json',
    );
  }
  final dartMatch = RegExp(
    r'^(\d+)\.(\d+)',
  ).firstMatch(toolchain.machineIdentity.dartSdkVersion);
  if (dartMatch == null) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-dart-version-invalid',
      '.dart_tool/package_config.json',
    );
  }
  final dartMajor = int.parse(dartMatch.group(1)!);
  final dartMinor = int.parse(dartMatch.group(2)!);
  for (final record in records) {
    final segments = record.languageVersion.split('.');
    final major = int.parse(segments[0]);
    final minor = int.parse(segments[1]);
    if (major > dartMajor || (major == dartMajor && minor > dartMinor)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-language-version-unsupported',
        '.dart_tool/package_config.json',
      );
    }
  }
  final flutter = records.where((record) => record.name == 'flutter').toList();
  if (flutter.length != 1 ||
      flutter.single.canonicalRoot !=
          p.normalize(p.join(toolchain.canonicalSdkRoot, 'packages/flutter'))) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'package-flutter-record-mismatch',
      '.dart_tool/package_config.json',
    );
  }
  final sdkPackageRoots = <String, String>{
    for (final name in const {
      'flutter',
      'flutter_driver',
      'flutter_goldens',
      'flutter_localizations',
      'flutter_test',
      'flutter_tools',
      'flutter_web_plugins',
      'fuchsia_remote_debug_protocol',
      'integration_test',
    })
      name: p.normalize(p.join(toolchain.canonicalSdkRoot, 'packages', name)),
    for (final name in const {'flutter_gpu', 'sky_engine'})
      name: p.normalize(
        p.join(toolchain.canonicalSdkRoot, 'bin/cache/pkg', name),
      ),
  };
  for (final record in records.where(
    (record) => sdkPackageRoots.containsKey(record.name),
  )) {
    if (record.canonicalRoot != sdkPackageRoots[record.name]) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'package-sdk-record-mismatch',
        '.dart_tool/package_config.json',
      );
    }
  }
}

void _validateProjectedPackageBytes(
  List<int> bytes,
  String canonicalProjectRoot,
  String selectedPackageName,
  List<_PackageRecord> records,
  Map<String, String> projectOwnedRootsByPackage,
) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, Object?> || decoded['packages'] is! List) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'projected-package-config-invalid',
      '.dart_tool/package_config.json',
    );
  }
  final byName = {for (final record in records) record.name: record};
  for (final value in decoded['packages']! as List<Object?>) {
    if (value is! Map<String, Object?>) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'projected-package-config-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final name = value['name']! as String;
    final root = value['rootUri']! as String;
    if (name == selectedPackageName) {
      if (root != '../') {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'projected-selected-root-invalid',
          '.dart_tool/package_config.json',
        );
      }
    } else if (projectOwnedRootsByPackage[name] case final relative?) {
      if (root != '../$relative/') {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'projected-project-root-invalid',
          '.dart_tool/package_config.json',
        );
      }
    } else if (root != Directory(byName[name]!.canonicalRoot).uri.toString()) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'projected-external-root-invalid',
        '.dart_tool/package_config.json',
      );
    }
  }
}

final class _PackageRecord {
  const _PackageRecord({
    required this.name,
    required this.canonicalRoot,
    required this.languageVersion,
  });
  final String name;
  final String canonicalRoot;
  final String languageVersion;
  Map<String, Object?> get identity => {
    'name': name,
    'root': canonicalRoot,
    'languageVersion': languageVersion,
    'packageUri': 'lib/',
  };
}

final class _ProjectOwnedPackageAuthority {
  const _ProjectOwnedPackageAuthority({
    required this.name,
    required this.relativeRoot,
    required this.relativeFilePaths,
    required this.identity,
  });

  final String name;
  final String relativeRoot;
  final List<String> relativeFilePaths;
  final Map<String, Object?> identity;
}

_ProjectOwnedPackageAuthority _captureProjectOwnedPackage(
  String name,
  String canonicalProjectRoot,
  String packageRoot,
  String relativeRoot,
) {
  if (!_within(canonicalProjectRoot, packageRoot) ||
      packageRoot == canonicalProjectRoot ||
      _canonicalDirectory(packageRoot) != packageRoot) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'project-package-root-invalid',
      '.dart_tool/package_config.json',
    );
  }

  final files = <Map<String, Object?>>[];
  final relativeFilePaths = <String>[];
  final folded = <String, String>{};

  void captureFile(String absolute, String packageRelative) {
    final projectRelative = _relative(canonicalProjectRoot, absolute);
    if (!_isSafeRelative(projectRelative) ||
        !_isSafeRelative(packageRelative) ||
        !_within(packageRoot, absolute) ||
        FileSystemEntity.typeSync(absolute, followLinks: false) !=
            FileSystemEntityType.file ||
        p.normalize(File(absolute).resolveSymbolicLinksSync()) != absolute) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'project-package-file-invalid',
        '.dart_tool/package_config.json',
      );
    }
    final fold = _asciiFold(packageRelative);
    final prior = folded.putIfAbsent(fold, () => packageRelative);
    if (prior != packageRelative) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'project-package-casefold-collision',
        '.dart_tool/package_config.json',
      );
    }
    final file = File(absolute);
    final before = file.statSync();
    final bytes = file.readAsBytesSync();
    final after = file.statSync();
    if (!_sameFileStat(before, after)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'project-package-file-drift',
        '.dart_tool/package_config.json',
      );
    }
    relativeFilePaths.add(projectRelative);
    files.add({
      'path': packageRelative,
      'sha256': sha256.convert(bytes).toString(),
      'mode': Platform.isWindows ? null : before.mode & 0xfff,
    });
  }

  final pubspecPath = p.normalize(p.join(packageRoot, 'pubspec.yaml'));
  captureFile(pubspecPath, 'pubspec.yaml');
  final pubspec = loadYaml(File(pubspecPath).readAsStringSync());
  if (pubspec is! Map || pubspec['name'] != name) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'project-package-name-mismatch',
      '.dart_tool/package_config.json',
    );
  }

  final optionsPath = p.normalize(p.join(packageRoot, 'analysis_options.yaml'));
  final optionsType = FileSystemEntity.typeSync(
    optionsPath,
    followLinks: false,
  );
  if (optionsType == FileSystemEntityType.file) {
    captureFile(optionsPath, 'analysis_options.yaml');
  } else if (optionsType == FileSystemEntityType.notFound) {
    files.add({'path': 'analysis_options.yaml', 'present': false});
  } else {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'project-package-options-invalid',
      '.dart_tool/package_config.json',
    );
  }

  final libRoot = p.normalize(p.join(packageRoot, 'lib'));
  final libType = FileSystemEntity.typeSync(libRoot, followLinks: false);
  if (libType == FileSystemEntityType.directory) {
    final entities = Directory(libRoot).listSync(
      recursive: true,
      followLinks: false,
    )..sort((left, right) => left.path.compareTo(right.path));
    for (final entity in entities) {
      final absolute = p.normalize(p.absolute(entity.path));
      final packageRelative = _relative(packageRoot, absolute);
      if (!_isSafeRelative(packageRelative) || !_within(libRoot, absolute)) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'project-package-lib-invalid',
          '.dart_tool/package_config.json',
        );
      }
      final type = FileSystemEntity.typeSync(absolute, followLinks: false);
      if (type == FileSystemEntityType.file) {
        captureFile(absolute, packageRelative);
      } else if (type != FileSystemEntityType.directory ||
          p.normalize(Directory(absolute).resolveSymbolicLinksSync()) !=
              absolute) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'project-package-lib-invalid',
          '.dart_tool/package_config.json',
        );
      }
    }
  } else if (libType != FileSystemEntityType.notFound) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'project-package-lib-invalid',
      '.dart_tool/package_config.json',
    );
  }

  return _ProjectOwnedPackageAuthority(
    name: name,
    relativeRoot: relativeRoot,
    relativeFilePaths: List.unmodifiable(relativeFilePaths..sort()),
    identity: {
      'name': name,
      'root': relativeRoot,
      'files': files
        ..sort(
          (left, right) => '${left['path']}'.compareTo('${right['path']}'),
        ),
    },
  );
}

final class _ExternalPackageAuthority {
  const _ExternalPackageAuthority({
    required this.name,
    required this.root,
    required this.rootMode,
    required this.pubspecBytes,
    required this.pubspecMode,
    required this.pubspecSize,
    required this.pubspecModifiedMicros,
    required this.pubspecChangedMicros,
    required this.rootModifiedMicros,
    required this.rootChangedMicros,
    required this.libIdentity,
  });
  final String name;
  final String root;
  final int? rootMode;
  final List<int> pubspecBytes;
  final int? pubspecMode;
  final int pubspecSize;
  final int pubspecModifiedMicros;
  final int pubspecChangedMicros;
  final int rootModifiedMicros;
  final int rootChangedMicros;
  final String libIdentity;
  Map<String, Object?> get identity => {
    'name': name,
    'root': root,
    'rootMode': rootMode,
    'rootModifiedMicros': rootModifiedMicros,
    'rootChangedMicros': rootChangedMicros,
    'pubspecSha256': sha256.convert(pubspecBytes).toString(),
    'pubspecMode': pubspecMode,
    'pubspecSize': pubspecSize,
    'pubspecModifiedMicros': pubspecModifiedMicros,
    'pubspecChangedMicros': pubspecChangedMicros,
    'libIdentity': libIdentity,
  };

  void verify() {
    try {
      final current = _captureExternalPackage(name, root);
      if (_hashCanonical(identity) == _hashCanonical(current.identity)) {
        return;
      }
    } on Object {
      // Verification-time failures are all authority drift, regardless of the
      // initial-capture rejection that the same filesystem state would cause.
    }
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-authority-drift',
    );
  }
}

extension on L10nPackageConfigProjection {
  void _verifyExternalAuthorities() {
    for (final authority in _externalAuthorities) {
      authority.verify();
    }
  }
}

_ExternalPackageAuthority _captureExternalPackage(String name, String root) {
  if (_canonicalDirectory(root) != root) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-root-drift',
    );
  }
  final rootStat = Directory(root).statSync();
  final rootMode = Platform.isWindows ? null : rootStat.mode & 0xfff;
  if (rootMode != null && (rootMode & 0x12) != 0) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-root-writable',
    );
  }
  final pubspecPath = p.join(root, 'pubspec.yaml');
  if (FileSystemEntity.typeSync(pubspecPath, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-pubspec-invalid',
    );
  }
  final file = File(pubspecPath);
  if (p.normalize(file.resolveSymbolicLinksSync()) !=
      p.normalize(pubspecPath)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-pubspec-invalid',
    );
  }
  final before = file.statSync();
  final bytes = file.readAsBytesSync();
  final after = file.statSync();
  final pubspecMode = Platform.isWindows ? null : before.mode & 0xfff;
  if (!_sameFileStat(before, after) ||
      (pubspecMode != null && (pubspecMode & 0x12) != 0)) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-pubspec-drift',
    );
  }
  final parsed = loadYaml(utf8.decode(bytes));
  if (parsed is! Map || parsed['name'] != name) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-name-mismatch',
    );
  }
  final libIdentity = _captureExternalLibIdentity(root);
  return _ExternalPackageAuthority(
    name: name,
    root: root,
    rootMode: rootMode,
    pubspecBytes: List.unmodifiable(bytes),
    pubspecMode: pubspecMode,
    pubspecSize: before.size,
    pubspecModifiedMicros: before.modified.microsecondsSinceEpoch,
    pubspecChangedMicros: before.changed.microsecondsSinceEpoch,
    rootModifiedMicros: rootStat.modified.microsecondsSinceEpoch,
    rootChangedMicros: rootStat.changed.microsecondsSinceEpoch,
    libIdentity: libIdentity,
  );
}

String _captureExternalLibIdentity(String packageRoot) {
  final libPath = p.normalize(p.join(packageRoot, 'lib'));
  final type = FileSystemEntity.typeSync(libPath, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return _hashCanonical(const {'state': 'absent'});
  }
  if (type != FileSystemEntityType.directory) {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-lib-invalid',
    );
  }
  try {
    final directory = Directory(libPath);
    if (p.normalize(directory.resolveSymbolicLinksSync()) != libPath) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'external-package-lib-invalid',
      );
    }
    final beforeRoot = directory.statSync();
    final rootMode = Platform.isWindows ? null : beforeRoot.mode & 0xfff;
    if (rootMode != null && (rootMode & 0x12) != 0) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'external-package-lib-writable',
      );
    }
    final entities = directory.listSync(recursive: true, followLinks: false)
      ..sort((left, right) => left.path.compareTo(right.path));
    final foldedPaths = <String, String>{};
    final entries = <Map<String, Object?>>[];
    for (final entity in entities) {
      final absolute = p.normalize(p.absolute(entity.path));
      final relative = _relative(libPath, absolute);
      if (!_isSafeRelative(relative) || !_within(libPath, absolute)) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-lib-invalid',
        );
      }
      final folded = _asciiFold(relative);
      final prior = foldedPaths[folded];
      if (prior != null && prior != relative) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-lib-casefold-collision',
        );
      }
      foldedPaths[folded] = relative;
      final entityType = FileSystemEntity.typeSync(
        absolute,
        followLinks: false,
      );
      if (entityType != FileSystemEntityType.file &&
          entityType != FileSystemEntityType.directory) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-lib-invalid',
        );
      }
      final canonical = entityType == FileSystemEntityType.file
          ? File(absolute).resolveSymbolicLinksSync()
          : Directory(absolute).resolveSymbolicLinksSync();
      if (p.normalize(canonical) != absolute) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-lib-invalid',
        );
      }
      final before = FileStat.statSync(absolute);
      final mode = Platform.isWindows ? null : before.mode & 0xfff;
      if (mode != null && (mode & 0x12) != 0) {
        throw const _Problem(
          L10nEvidenceRejectionCode.packageResolutionDrift,
          _packageStage,
          'external-package-lib-writable',
        );
      }
      if (entityType == FileSystemEntityType.file) {
        final fileBytes = File(absolute).readAsBytesSync();
        final after = FileStat.statSync(absolute);
        if (!_sameFileStat(before, after)) {
          throw const _Problem(
            L10nEvidenceRejectionCode.packageResolutionDrift,
            _packageStage,
            'external-package-lib-drift',
          );
        }
        entries.add({
          'path': relative,
          'kind': 'file',
          'mode': mode,
          'size': before.size,
          'modifiedMicros': before.modified.microsecondsSinceEpoch,
          'changedMicros': before.changed.microsecondsSinceEpoch,
          'sha256': sha256.convert(fileBytes).toString(),
        });
      } else {
        entries.add({
          'path': relative,
          'kind': 'directory',
          'mode': mode,
          'size': before.size,
          'modifiedMicros': before.modified.microsecondsSinceEpoch,
          'changedMicros': before.changed.microsecondsSinceEpoch,
        });
      }
    }
    final afterRoot = directory.statSync();
    if (!_sameFileStat(beforeRoot, afterRoot)) {
      throw const _Problem(
        L10nEvidenceRejectionCode.packageResolutionDrift,
        _packageStage,
        'external-package-lib-drift',
      );
    }
    return _hashCanonical({
      'state': 'present',
      'mode': rootMode,
      'size': beforeRoot.size,
      'modifiedMicros': beforeRoot.modified.microsecondsSinceEpoch,
      'changedMicros': beforeRoot.changed.microsecondsSinceEpoch,
      'entries': entries,
    });
  } on _Problem {
    rethrow;
  } on Object {
    throw const _Problem(
      L10nEvidenceRejectionCode.packageResolutionDrift,
      _packageStage,
      'external-package-lib-drift',
    );
  }
}

List<ByteSpan> _arrayObjectSpans(List<int> bytes, ByteSpan arraySpan) {
  final spans = <ByteSpan>[];
  var cursor = arraySpan.start + 1;
  final end = arraySpan.endExclusive - 1;
  while (cursor < end) {
    while (cursor < end && _jsonWhitespace(bytes[cursor])) {
      cursor++;
    }
    if (cursor >= end) break;
    if (bytes[cursor] != 0x7b) return const [];
    final start = cursor;
    var depth = 0;
    var inString = false;
    var escaped = false;
    while (cursor < end) {
      final byte = bytes[cursor++];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (byte == 0x5c) {
          escaped = true;
        } else if (byte == 0x22) {
          inString = false;
        }
        continue;
      }
      if (byte == 0x22) {
        inString = true;
      } else if (byte == 0x7b || byte == 0x5b) {
        depth++;
      } else if (byte == 0x7d || byte == 0x5d) {
        depth--;
        if (depth == 0) break;
      }
    }
    if (depth != 0 || inString) return const [];
    spans.add(ByteSpan(start, cursor));
    while (cursor < end && _jsonWhitespace(bytes[cursor])) {
      cursor++;
    }
    if (cursor < end) {
      if (bytes[cursor] != 0x2c) return const [];
      cursor++;
    }
  }
  return spans;
}

final class _ByteReplacement {
  const _ByteReplacement({
    required this.start,
    required this.end,
    required this.bytes,
  });
  final int start;
  final int end;
  final List<int> bytes;
}

List<int> _splice(List<int> source, List<_ByteReplacement> replacements) {
  final sorted = [...replacements]
    ..sort((left, right) => right.start.compareTo(left.start));
  final result = List<int>.of(source);
  for (final replacement in sorted) {
    result.replaceRange(replacement.start, replacement.end, replacement.bytes);
  }
  return List.unmodifiable(result);
}

String _l10nAnalysisFingerprint(
  AnalysisSnapshot analysis,
  ArbInventory inventory,
) => _l10nAnalysisFingerprintForIds(
  analysis,
  inventory.keys.map((key) => key.nodeId).toSet(),
);

String _l10nAnalysisFingerprintForIds(
  AnalysisSnapshot analysis,
  Set<String> familyIds,
) {
  final frozenFamilyIds = SplayTreeSet<String>.of(familyIds);
  final relevantNodeIds = <String>{...frozenFamilyIds};
  final edges = analysis.graph.edges
      .where(
        (edge) =>
            frozenFamilyIds.contains(edge.to) ||
            frozenFamilyIds.contains(edge.from),
      )
      .toList();
  for (final edge in edges) {
    relevantNodeIds.add(edge.from);
    relevantNodeIds.add(edge.to);
  }
  for (final blocker in analysis.graph.blockers) {
    if (frozenFamilyIds.any(blocker.couldAddress) &&
        blocker.sourceNodeId != null) {
      relevantNodeIds.add(blocker.sourceNodeId!);
    }
  }
  final nodes = [
    for (final id in relevantNodeIds)
      if (analysis.graph.node(id) case final node?)
        {
          'id': node.id,
          'kind': node.kind.name,
          'origin': _nodeOriginIdentity(analysis.project, node.origin),
          'displayName': node.displayName,
          'sizeBytes': node.sizeBytes,
          'sha256': node.sha256,
          'metadata': _canonicalValue(node.metadata),
          'owner': analysis.graph.nodeOwner(id),
          'contributors': [...analysis.graph.nodeContributors(id)]..sort(),
          'protection': [...analysis.graph.protectionReasons(id)]..sort(),
        },
  ]..sort((left, right) => '${left['id']}'.compareTo('${right['id']}'));
  final edgeFacts = [
    for (final edge in edges) _edgeIdentity(edge, analysis.project),
  ]..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
  final blockerFacts = [
    for (final blocker in analysis.graph.blockers)
      if (frozenFamilyIds.any(blocker.couldAddress))
        _blockerIdentity(blocker, analysis.project),
  ]..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
  final findings = [
    for (final finding in analysis.findings)
      if (frozenFamilyIds.contains(finding.node.id) &&
          finding.reportingAdapterId == 'l10n')
        _findingIdentity(finding, analysis.project),
  ]..sort(_compareCanonicalMaps);
  final targets = [...analysis.project.targets]
    ..sort(
      (left, right) =>
          _compareCanonicalMaps(_targetIdentity(left), _targetIdentity(right)),
    );
  final auxiliary = analysis.graph.analyzeAuxiliary();
  final auxiliaryTargets = [
    for (final target in analysis.graph.auxiliaryExecutionTargets)
      _auxiliaryTargetIdentity(target),
  ]..sort(_compareCanonicalMaps);
  return _hashCanonical({
    'nodes': nodes,
    'edges': edgeFacts,
    'blockers': blockerFacts,
    'findings': findings,
    'targets': [
      for (final target in targets)
        {
          'target': _targetIdentity(target),
          'configuredProven': [
            for (final id in frozenFamilyIds)
              if (analysis.graph.configuredProvenFor(target).contains(id)) id,
          ]..sort(),
          'configuredRetained': [
            for (final id in frozenFamilyIds)
              if (analysis.graph.configuredRetainedFor(target).contains(id)) id,
          ]..sort(),
        },
    ],
    'auxiliaryProven': [
      for (final id in frozenFamilyIds)
        if (auxiliary.proven.contains(id)) id,
    ]..sort(),
    'auxiliaryRetained': [
      for (final id in frozenFamilyIds)
        if (auxiliary.retained.contains(id)) id,
    ]..sort(),
    'auxiliaryTargets': auxiliaryTargets,
    'auxiliaryIncompleteExecutionTargetIds': [
      ...auxiliary.incompleteExecutionTargetIds,
    ]..sort(),
    'auxiliaryRegistryIssues': [
      for (final issue in auxiliary.registryIssues)
        {
          'id': issue.id,
          'acceptedDefinitionSha256': issue.acceptedDefinitionSha256,
          'rejectedDefinitionSha256': issue.rejectedDefinitionSha256,
          'reason': issue.reason,
        },
    ]..sort(_compareCanonicalMaps),
  });
}

int _compareCanonicalMaps(
  Map<String, Object?> left,
  Map<String, Object?> right,
) => jsonEncode(
  _typedCanonical(left),
).compareTo(jsonEncode(_typedCanonical(right)));

Map<String, Object?> _findingIdentity(Finding finding, ProjectContext project) {
  const ignoredReasons = {
    ClassificationReason.unsupportedAction,
    ClassificationReason.nonDeterministicInverse,
    ClassificationReason.broadRemovalScope,
  };
  return {
    'nodeId': finding.node.id,
    'ruleId': finding.ruleId,
    'reportingAdapterId': finding.reportingAdapterId,
    'confidence': finding.confidence.name,
    'title': finding.title,
    'proposedAction': finding.proposedAction,
    'sourceBytes': finding.sourceBytes,
    'predicates': {
      'ruleAllowsAutoFix': finding.predicates.ruleAllowsAutoFix,
      'unreachableAcrossAllTargets':
          finding.predicates.unreachableAcrossAllTargets,
      'notRetained': finding.predicates.notRetained,
      'noDynamicBlockers': finding.predicates.noDynamicBlockers,
      'notProtected': finding.predicates.notProtected,
      'noPublicApiRisk': finding.predicates.noPublicApiRisk,
      'analysisCoverageComplete': finding.predicates.analysisCoverageComplete,
    },
    'evidence': [
      for (final evidence in finding.evidence)
        _evidenceIdentity(evidence, project),
    ]..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right))),
    'blockers': [
      for (final blocker in finding.blockers)
        _blockerIdentity(blocker, project),
    ]..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right))),
    'protection': [...finding.protectionReasons]..sort(),
    'unreachableIn': [...finding.unreachableIn]..sort(),
    'reachableIn': [...finding.reachableIn]..sort(),
    'retainedIn': [...finding.retainedIn]..sort(),
    'auxiliaryRetainedIn': [...finding.auxiliaryRetainedIn]..sort(),
    'classificationReasons': [
      for (final reason in finding.classificationReasons)
        if (!ignoredReasons.contains(reason)) reason.name,
    ]..sort(),
    'manualRisks': finding.manualRisks.map((risk) => risk.name).toList()
      ..sort(),
  };
}

Map<String, Object?> _edgeIdentity(GraphEdge edge, ProjectContext project) => {
  'from': edge.from,
  'to': edge.to,
  'kind': edge.kind.name,
  'condition': _conditionIdentity(edge.condition),
  'evidence': _evidenceIdentity(edge.evidence, project),
};

Map<String, Object?> _conditionIdentity(BuildCondition condition) => {
  'platforms': [...condition.platforms]..sort(),
  'flavors': [...condition.flavors]..sort(),
  'entrypoints': [...condition.entrypoints]..sort(),
  'dartDefines': SplayTreeMap<String, String>.of(condition.dartDefines),
  'exactTargets': condition.exactTargets.map(_targetIdentity).toList()
    ..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right))),
  'exactAuxiliaryTargets':
      condition.exactAuxiliaryTargets.map(_auxiliaryTargetIdentity).toList()
        ..sort((left, right) => '${left['id']}'.compareTo('${right['id']}')),
};

Map<String, Object?> _evidenceIdentity(
  Evidence evidence,
  ProjectContext project,
) => {
  'kind': evidence.kind.name,
  'producer': evidence.producer,
  'description': evidence.description,
  'exact': evidence.exact,
  'location': _locationIdentity(project, evidence.location),
};

Map<String, Object?> _blockerIdentity(
  Blocker blocker,
  ProjectContext project,
) => {
  'producer': blocker.producer,
  'reason': blocker.reason,
  'location': _locationIdentity(project, blocker.location),
  'sourceNodeId': blocker.sourceNodeId,
  'affectedNamespace': blocker.affectedNamespace,
  'affectedNodeIds': [...blocker.affectedNodeIds]..sort(),
};

Map<String, Object?> _auxiliaryTargetIdentity(
  AuxiliaryExecutionTarget target,
) => {
  'id': target.id,
  'domain': target.domain.name,
  'environmentValues': SplayTreeMap<String, String>.of(
    target.environmentValues,
  ),
  'environmentComplete': target.environmentComplete,
  'reason': target.reason,
  'sourceConfiguredTarget': target.sourceConfiguredTarget == null
      ? null
      : _targetIdentity(target.sourceConfiguredTarget!),
};

String _nodeOriginIdentity(ProjectContext project, Uri origin) {
  if (origin.scheme != 'file') return origin.toString();
  final root = p.normalize(project.root.resolveSymbolicLinksSync());
  final requested = p.normalize(p.fromUri(origin));
  final absolute =
      FileSystemEntity.typeSync(requested, followLinks: false) ==
          FileSystemEntityType.file
      ? p.normalize(File(requested).resolveSymbolicLinksSync())
      : requested;
  if (_within(root, absolute)) return _relative(root, absolute);
  return origin.toString();
}

String? _locationIdentity(ProjectContext project, String? location) {
  if (location == null) return null;
  final canonicalRoot = p.normalize(project.root.resolveSymbolicLinksSync());
  final requestedRoot = p.normalize(p.absolute(project.root.path));
  return location
      .replaceAll(canonicalRoot, '<project>')
      .replaceAll(requestedRoot, '<project>');
}

Map<String, Object?> _targetIdentity(BuildTarget target) => {
  'name': target.name,
  'platform': target.platform,
  'entrypoint': target.entrypoint,
  'flavor': target.flavor,
  'dartDefines': SplayTreeMap<String, String>.of(target.dartDefines),
};

Map<String, Object?> _projectIdentity(ProjectContext project) {
  final targets = project.targets.map(_targetIdentity).toList()
    ..sort(
      (left, right) => jsonEncode(
        _typedCanonical(left),
      ).compareTo(jsonEncode(_typedCanonical(right))),
    );
  return {
    'packageName': project.packageName,
    'analysisMode': project.analysisMode.name,
    'targetMatrix': {
      'status': project.targetMatrix.status.name,
      'source': project.targetMatrix.source,
      'issues': [...project.targetMatrix.issues]..sort(),
      'targets': targets,
    },
    'rootCoverage': {
      'mode': project.rootCoverage.mode.name,
      'internalBoundaryComplete': project.rootCoverage.internalBoundaryComplete,
      'externalConsumersCovered': project.rootCoverage.externalConsumersCovered,
      'source': project.rootCoverage.source,
      'publicEntrypoints': [...project.rootCoverage.publicEntrypoints]..sort(),
      'issues': [...project.rootCoverage.issues]..sort(),
    },
    'pubspec': project.pubspec,
  };
}

Map<String, Object?> _entryIdentity(L10nSnapshotEntry entry) {
  final state = entry.state;
  return {
    'path': entry.relativePosixPath,
    'role': entry.role.name,
    if (state is L10nSnapshotPresent) ...{
      'present': true,
      'sourceSha256': state.sourceSha256,
      'stageSha256': state.stageBytes.sha256Hex,
      'mode': state.posixMode,
    } else
      'present': false,
  };
}

Object? _canonicalValue(Object? value) {
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
    return <String, Object?>{
      for (final entry in entries) '${entry.key}': _canonicalValue(entry.value),
    };
  }
  if (value is Iterable) return value.map(_canonicalValue).toList();
  return value;
}

String _hashCanonical(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_typedCanonical(value)))).toString();

Object? _typedCanonical(Object? value) {
  if (value == null) return const ['null'];
  if (value is bool) return ['bool', value];
  if (value is String) return ['string', value];
  if (value is int) return ['int', '$value'];
  if (value is double) {
    if (!value.isFinite) {
      throw ArgumentError.value(value, 'value', 'must be finite');
    }
    return ['double', value.toString()];
  }
  if (value is Map) {
    final entries =
        [
          for (final entry in value.entries)
            [_typedCanonical(entry.key), _typedCanonical(entry.value)],
        ]..sort(
          (left, right) =>
              jsonEncode(left.first).compareTo(jsonEncode(right.first)),
        );
    return ['map', entries];
  }
  if (value is Set) {
    final values = value.map(_typedCanonical).toList()
      ..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
    return ['set', values];
  }
  if (value is Iterable) {
    return ['list', value.map(_typedCanonical).toList()];
  }
  return ['object', value.runtimeType.toString(), '$value'];
}

bool _sameNodeFacts(GraphNode left, GraphNode right) =>
    left.kind == right.kind &&
    left.origin == right.origin &&
    left.displayName == right.displayName &&
    left.sizeBytes == right.sizeBytes &&
    left.sha256 == right.sha256 &&
    jsonEncode(_canonicalValue(left.metadata)) ==
        jsonEncode(_canonicalValue(right.metadata));

bool _sameOrigin(Uri left, Uri right) {
  if (left.scheme != 'file' || right.scheme != 'file') return left == right;
  return p.normalize(p.fromUri(left)) == p.normalize(p.fromUri(right));
}

bool _samePhysical(String left, String right) {
  try {
    return _canonicalDirectory(left) == _canonicalDirectory(right);
  } on Object {
    return false;
  }
}

bool _samePhysicalFile(String left, String right) {
  try {
    final leftFile = File(p.normalize(p.absolute(left)));
    final rightFile = File(p.normalize(p.absolute(right)));
    if (FileSystemEntity.typeSync(leftFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        FileSystemEntity.typeSync(rightFile.path, followLinks: false) !=
            FileSystemEntityType.file) {
      return false;
    }
    return p.normalize(leftFile.resolveSymbolicLinksSync()) ==
        p.normalize(rightFile.resolveSymbolicLinksSync());
  } on Object {
    return false;
  }
}

bool _samePhysicalCandidate(String left, String right) =>
    p.normalize(p.absolute(left)) == p.normalize(p.absolute(right));

bool _sameFileStat(FileStat left, FileStat right) =>
    left.type == right.type &&
    left.size == right.size &&
    left.mode == right.mode &&
    left.modified == right.modified &&
    left.changed == right.changed;

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameStrings(Iterable<String> left, Iterable<String> right) {
  final leftList = left.toList()..sort();
  final rightList = right.toList()..sort();
  return leftList.length == rightList.length &&
      leftList.asMap().entries.every(
        (entry) => entry.value == rightList[entry.key],
      );
}

String _canonicalDirectory(String path) {
  final absolute = p.normalize(p.absolute(path));
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FileSystemException('directory authority unavailable');
  }
  return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
}

bool _within(String root, String candidate) {
  final relative = p.relative(candidate, from: root);
  return relative == '.' ||
      (!p.isAbsolute(relative) &&
          relative != '..' &&
          !relative.startsWith('..${p.separator}'));
}

String _relative(String root, String absolute) =>
    p.relative(absolute, from: root).replaceAll('\\', '/');

String _normalizeRelative(String value) =>
    p.posix.normalize(value.replaceAll('\\', '/'));

bool _isSafeRelative(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    !value.startsWith('/') &&
    !value.endsWith('/') &&
    !value.contains('\\') &&
    !value.contains(':') &&
    !value.contains('%') &&
    !value.contains('?') &&
    !value.contains('#') &&
    value
        .split('/')
        .every(
          (segment) =>
              segment.isNotEmpty &&
              segment != '.' &&
              segment != '..' &&
              RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
        ) &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e);

String _asciiFold(String value) => String.fromCharCodes(
  value.codeUnits.map(
    (unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
  ),
);

String? _arbLocaleForPath(String path, String? declaredLocale) {
  final basename = p.posix.basenameWithoutExtension(path);
  final filenameLocale = _filenameLocale(basename);
  if (declaredLocale != null) {
    final normalized = _normalizeLocaleSyntax(declaredLocale.trim());
    if (normalized == null ||
        (filenameLocale != null && filenameLocale != normalized)) {
      return null;
    }
    return normalized;
  }
  return filenameLocale;
}

String? _filenameLocale(String basename) {
  final whole = _normalizeSupportedFilenameLocale(basename);
  if (whole != null) return whole;
  for (final separator in RegExp('_').allMatches(basename)) {
    final locale = _normalizeSupportedFilenameLocale(
      basename.substring(separator.end),
    );
    if (locale != null) return locale;
  }
  return null;
}

String? _normalizeSupportedFilenameLocale(String value) {
  final locale = _normalizeLocaleSyntax(value);
  if (locale == null ||
      !_supportedLanguageCodes.contains(locale.split('_').first)) {
    return null;
  }
  return locale;
}

String? _normalizeLocaleSyntax(String value) {
  final segments = value.split(RegExp('[-_]'));
  if (segments.isEmpty || segments.length > 3) return null;
  final language = segments.first.toLowerCase();
  if (!RegExp(r'^[a-z]{2,3}$').hasMatch(language)) return null;
  String? script;
  String? region;
  if (segments.length >= 2) {
    final second = segments[1];
    if (RegExp(r'^[A-Za-z]{4}$').hasMatch(second)) {
      script = '${second[0].toUpperCase()}${second.substring(1).toLowerCase()}';
    } else if (RegExp(r'^[A-Za-z]{2}$').hasMatch(second)) {
      region = second.toUpperCase();
    } else if (RegExp(r'^\d{3}$').hasMatch(second)) {
      region = second;
    } else {
      return null;
    }
  }
  if (segments.length == 3) {
    if (script == null) return null;
    final third = segments[2];
    if (RegExp(r'^[A-Za-z]{2}$').hasMatch(third)) {
      region = third.toUpperCase();
    } else if (RegExp(r'^\d{3}$').hasMatch(third)) {
      region = third;
    } else {
      return null;
    }
  }
  return [
    language,
    if (script != null) script,
    if (region != null) region,
  ].join('_');
}

String _baseLanguage(String locale) =>
    locale.split(RegExp('[_-]')).first.toLowerCase();

const _supportedLanguageCodes = <String>{
  'aa',
  'ab',
  'ae',
  'af',
  'ak',
  'am',
  'an',
  'ar',
  'as',
  'av',
  'ay',
  'az',
  'ba',
  'be',
  'bg',
  'bh',
  'bi',
  'bm',
  'bn',
  'bo',
  'br',
  'bs',
  'ca',
  'ce',
  'ch',
  'co',
  'cr',
  'cs',
  'cu',
  'cv',
  'cy',
  'da',
  'de',
  'dv',
  'dz',
  'ee',
  'el',
  'en',
  'eo',
  'es',
  'et',
  'eu',
  'fa',
  'ff',
  'fi',
  'fil',
  'fj',
  'fo',
  'fr',
  'fy',
  'ga',
  'gd',
  'gl',
  'gn',
  'gsw',
  'gu',
  'gv',
  'ha',
  'he',
  'hi',
  'ho',
  'hr',
  'ht',
  'hu',
  'hy',
  'hz',
  'ia',
  'id',
  'ie',
  'ig',
  'ii',
  'ik',
  'io',
  'is',
  'it',
  'iu',
  'ja',
  'jv',
  'ka',
  'kg',
  'ki',
  'kj',
  'kk',
  'kl',
  'km',
  'kn',
  'ko',
  'kr',
  'ks',
  'ku',
  'kv',
  'kw',
  'ky',
  'la',
  'lb',
  'lg',
  'li',
  'ln',
  'lo',
  'lt',
  'lu',
  'lv',
  'mg',
  'mh',
  'mi',
  'mk',
  'ml',
  'mn',
  'mr',
  'ms',
  'mt',
  'my',
  'na',
  'nb',
  'nd',
  'ne',
  'ng',
  'nl',
  'nn',
  'no',
  'nr',
  'nv',
  'ny',
  'oc',
  'oj',
  'om',
  'or',
  'os',
  'pa',
  'pi',
  'pl',
  'ps',
  'pt',
  'qu',
  'rm',
  'rn',
  'ro',
  'ru',
  'rw',
  'sa',
  'sc',
  'sd',
  'se',
  'sg',
  'si',
  'sk',
  'sl',
  'sm',
  'sn',
  'so',
  'sq',
  'sr',
  'ss',
  'st',
  'su',
  'sv',
  'sw',
  'ta',
  'te',
  'tg',
  'th',
  'ti',
  'tk',
  'tl',
  'tn',
  'to',
  'tr',
  'ts',
  'tt',
  'tw',
  'ty',
  'ug',
  'uk',
  'ur',
  'uz',
  've',
  'vi',
  'vo',
  'wa',
  'wo',
  'xh',
  'yi',
  'yo',
  'za',
  'zh',
  'zu',
};

bool _validPackageName(String value) =>
    RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(value);

bool _jsonWhitespace(int byte) =>
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d;

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  var comparison = left.code.index.compareTo(right.code.index);
  if (comparison != 0) return comparison;
  comparison = left.stage.compareTo(right.stage);
  if (comparison != 0) return comparison;
  comparison = (left.relativePath ?? '').compareTo(right.relativePath ?? '');
  if (comparison != 0) return comparison;
  return left.detailCode.compareTo(right.detailCode);
}

final class _Problem implements Exception {
  const _Problem(this.code, this.stage, this.detailCode, [this.relativePath]);

  final L10nEvidenceRejectionCode code;
  final String stage;
  final String detailCode;
  final String? relativePath;

  L10nEvidenceFailure get failure => L10nEvidenceFailure(
    code: code,
    stage: stage,
    detailCode: detailCode,
    relativePath: relativePath,
  );
}
