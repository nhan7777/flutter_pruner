/// Strict, redaction-safe frozen inputs for the independent accuracy oracle.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'accuracy_model.dart';

const _supportedAdapterIds = <String>[
  'assets',
  'dart',
  'duplicates',
  'get_it',
  'go_router',
  'l10n',
];

const _recognizedIntegrityPassId = 'analysis-001';
const _recognizedDiagnosticCode = 'package-internal-boundary';
const _recognizedDiagnosticPhase = 'analysis';

/// Required graph-membership relationship for one frozen scanner scan.
enum ScannerGraphMembershipMode {
  /// The scanner observation must contain exactly the declared context IDs.
  exact,

  /// Graph membership is intentionally unavailable for a duplicates-only scan.
  notApplicable,
}

/// A frozen external graph-observation artifact and its capture identity.
final class FrozenScannerGraphArtifact {
  /// Creates an immutable graph-observation identity.
  FrozenScannerGraphArtifact({
    required this.rawObservationPath,
    required this.rawObservationSha256,
    required this.observationReportPath,
    required this.observationReportSha256,
    required List<String> captureArgv,
    required this.captureArgvSha256,
    required this.schemaVersion,
  }) : captureArgv = List.unmodifiable(List<String>.from(captureArgv));

  /// Absolute external raw-observation path.
  final String rawObservationPath;

  /// SHA-256 of the raw observation.
  final String rawObservationSha256;

  /// Absolute external normalized-observation path.
  final String observationReportPath;

  /// SHA-256 of the normalized observation.
  final String observationReportSha256;

  /// Exact non-shell argument vector used to capture the observation.
  final List<String> captureArgv;

  /// SHA-256 of the UTF-8 `jsonEncode` serialization of [captureArgv].
  final String captureArgvSha256;

  /// Version of the scanner-observation schema.
  final int schemaVersion;
}

/// One scanner report plus the registry and graph contract used to obtain it.
final class FrozenScanArtifact {
  /// Creates an immutable frozen scan artifact.
  FrozenScanArtifact({
    required this.rawReportPath,
    required this.rawReportSha256,
    required List<String> scannerArgv,
    required this.scannerArgvSha256,
    required this.jsonSchemaVersion,
    required List<String> requestedAdapters,
    required List<OracleAuxiliaryExecutionTarget>
    expectedAuxiliaryExecutionTargets,
    required this.graphMembershipMode,
    required List<String> expectedGraphMembershipContextIds,
    required this.graphObservation,
  }) : scannerArgv = List.unmodifiable(List<String>.from(scannerArgv)),
       requestedAdapters = List.unmodifiable(
         List<String>.from(requestedAdapters),
       ),
       expectedAuxiliaryExecutionTargets = List.unmodifiable(
         List<OracleAuxiliaryExecutionTarget>.from(
           expectedAuxiliaryExecutionTargets,
         ),
       ),
       expectedGraphMembershipContextIds = List.unmodifiable(
         List<String>.from(expectedGraphMembershipContextIds),
       );

  /// Absolute external raw scanner-report path.
  final String rawReportPath;

  /// SHA-256 of the raw scanner report.
  final String rawReportSha256;

  /// Exact non-shell scanner argument vector.
  final List<String> scannerArgv;

  /// SHA-256 of the UTF-8 `jsonEncode` serialization of [scannerArgv].
  final String scannerArgvSha256;

  /// Scanner JSON report schema version.
  final int jsonSchemaVersion;

  /// Requested adapter IDs expanded independently for this scan.
  final List<String> requestedAdapters;

  /// Exact auxiliary registry applicable to this scan only.
  final List<OracleAuxiliaryExecutionTarget> expectedAuxiliaryExecutionTargets;

  /// Whether graph membership is exact or deliberately not applicable.
  final ScannerGraphMembershipMode graphMembershipMode;

  /// Sorted context IDs expected in the captured graph observation.
  final List<String> expectedGraphMembershipContextIds;

  /// Independently captured graph-observation identity.
  final FrozenScannerGraphArtifact graphObservation;
}

/// An explicit auxiliary-target issue retained only in capture characterization.
final class AuxiliaryExecutionTargetIssue {
  /// Creates one immutable declared auxiliary-target issue.
  const AuxiliaryExecutionTargetIssue({
    required this.id,
    required this.acceptedDefinitionSha256,
    required this.rejectedDefinitionSha256,
    required this.reason,
  });

  /// Stable issue identity.
  final String id;

  /// SHA-256 of the accepted definition, if any.
  final String acceptedDefinitionSha256;

  /// SHA-256 of the rejected definition, if any.
  final String rejectedDefinitionSha256;

  /// Auditable capture-only characterization reason.
  final String reason;
}

/// Complete declared coverage state required to evaluate a frozen manifest.
final class ExpectedAnalysisCoverage {
  /// Creates an immutable coverage declaration.
  ExpectedAnalysisCoverage({
    required this.analysisMode,
    required this.auxiliaryExecutionTargetIssuesPresent,
    required List<AuxiliaryExecutionTargetIssue> auxiliaryExecutionTargetIssues,
    required this.targetMatrixStatus,
    required this.targetMatrixComplete,
    required this.targetMatrixSource,
    required List<String> targetMatrixIssues,
    required this.rootMode,
    required this.rootCoverageComplete,
    required this.internalBoundaryComplete,
    required this.externalConsumersCovered,
    required this.rootSource,
    required List<String> publicEntrypoints,
    required List<String> rootIssues,
  }) : auxiliaryExecutionTargetIssues = List.unmodifiable(
         List<AuxiliaryExecutionTargetIssue>.from(
           auxiliaryExecutionTargetIssues,
         ),
       ),
       targetMatrixIssues = List.unmodifiable(
         List<String>.from(targetMatrixIssues),
       ),
       publicEntrypoints = List.unmodifiable(
         List<String>.from(publicEntrypoints),
       ),
       rootIssues = List.unmodifiable(List<String>.from(rootIssues));

  /// `accepted` or `capture-only`, without inferred defaults.
  final String analysisMode;

  /// Whether the auxiliary issue field was explicitly emitted by capture.
  final bool auxiliaryExecutionTargetIssuesPresent;

  /// Declared auxiliary-registry issues, kept distinct from coverage issues.
  final List<AuxiliaryExecutionTargetIssue> auxiliaryExecutionTargetIssues;

  /// Explicit target-matrix state.
  final String targetMatrixStatus;

  /// Whether the target matrix is complete.
  final bool targetMatrixComplete;

  /// Exact external source that produced the target matrix.
  final String targetMatrixSource;

  /// Declared target-matrix issues.
  final List<String> targetMatrixIssues;

  /// Explicit root-universe state.
  final String rootMode;

  /// Whether root coverage is complete.
  final bool rootCoverageComplete;

  /// Whether the selected package's internal boundary is complete.
  final bool internalBoundaryComplete;

  /// Whether external consumers were explicitly covered.
  final bool externalConsumersCovered;

  /// Exact external source that produced root coverage.
  final String rootSource;

  /// Declared public package entrypoints.
  final List<String> publicEntrypoints;

  /// Declared root-universe issues.
  final List<String> rootIssues;
}

/// Capture-only analysis-health exception, with exact per-pass identities.
final class AnalysisHealthAllowance {
  /// Creates an immutable health allowance.
  AnalysisHealthAllowance({
    required this.policyVersion,
    required Map<String, int> diagnosticCountsByCodePhase,
    required Map<String, ({int edges, int roots})> danglingCountsByPassId,
    required Map<String, Map<String, ({int edges, int roots})>>
    danglingCountsByPassAndExecutionTargetId,
    required Set<String> passIdsWithIntegrityMapAbsent,
  }) : diagnosticCountsByCodePhase = Map.unmodifiable(
         Map<String, int>.from(diagnosticCountsByCodePhase),
       ),
       danglingCountsByPassId = Map.unmodifiable(
         Map<String, ({int edges, int roots})>.from(danglingCountsByPassId),
       ),
       danglingCountsByPassAndExecutionTargetId =
           Map<String, Map<String, ({int edges, int roots})>>.unmodifiable(
             danglingCountsByPassAndExecutionTargetId.map(
               (passId, counts) => MapEntry(
                 passId,
                 Map<String, ({int edges, int roots})>.unmodifiable(
                   Map<String, ({int edges, int roots})>.from(counts),
                 ),
               ),
             ),
           ),
       passIdsWithIntegrityMapAbsent = Set.unmodifiable(
         Set<String>.from(passIdsWithIntegrityMapAbsent),
       );

  /// Version of the health-allowance policy.
  final int policyVersion;

  /// Exact diagnostic counts keyed as `scanKey|code|phase`.
  final Map<String, int> diagnosticCountsByCodePhase;

  /// Exact aggregate dangling counts keyed as `scanKey|analysis-001`.
  final Map<String, ({int edges, int roots})> danglingCountsByPassId;

  /// Exact dangling counts by `scanKey|analysis-001` and execution target.
  final Map<String, Map<String, ({int edges, int roots})>>
  danglingCountsByPassAndExecutionTargetId;

  /// Legacy pass IDs for which the additive integrity map was absent.
  final Set<String> passIdsWithIntegrityMapAbsent;
}

/// Explicit canonical and alias roots used only for deterministic redaction.
final class ManifestRedactionRoots {
  /// Creates immutable category-specific redaction roots.
  ManifestRedactionRoots({required Map<String, RedactionRoot> roots})
    : _roots = Map.unmodifiable(Map<String, RedactionRoot>.from(roots));

  final Map<String, RedactionRoot> _roots;

  /// Returns the declared root identity for [category].
  RedactionRoot operator [](String category) => _roots[category]!;
}

/// One canonical root and its known symlink or platform aliases.
final class RedactionRoot {
  /// Creates an immutable root identity.
  RedactionRoot(this.canonicalPath, List<String> aliases)
    : aliases = List.unmodifiable(List<String>.from(aliases));

  /// Canonical absolute path for this category.
  final String canonicalPath;

  /// Absolute aliases resolving to the same category root.
  final List<String> aliases;
}

/// A strictly parsed resolved manifest whose redacted JSON is safe to commit.
final class AccuracyProjectManifest {
  /// Current resolved-manifest schema accepted by this oracle.
  static const int supportedManifestSchemaVersion = 1;

  /// Current root-policy version accepted by this oracle.
  static const int supportedRootPolicyVersion = 2;

  /// Current candidate-boundary policy version accepted by this oracle.
  static const int supportedCandidateBoundaryPolicyVersion = 1;

  /// Current finding-contract policy version accepted by this oracle.
  static const int supportedFindingContractPolicyVersion = 1;

  /// Current health-allowance policy version accepted by this oracle.
  static const int supportedHealthAllowancePolicyVersion = 1;

  /// Current independent graph-observation schema accepted by this oracle.
  static const int supportedGraphObservationSchemaVersion = 1;

  /// Creates an immutable resolved project manifest.
  AccuracyProjectManifest({
    required this.manifestSchemaVersion,
    required this.label,
    required this.projectRoot,
    required this.projectGitSha,
    required this.packageRoot,
    required this.flutterVersion,
    required this.dartVersion,
    required this.toolSha,
    required this.configSha256,
    required this.packageConfigSha256,
    required this.lockfileSha256,
    required this.toolPackageConfigSha256,
    required this.toolLockfileSha256,
    required this.originalManagedFingerprint,
    required this.worktreeManagedFingerprint,
    required this.rootPolicyVersion,
    required this.candidateBoundaryPolicyVersion,
    required this.findingContractPolicyVersion,
    required this.manifestValidationMode,
    required this.redactionRoots,
    required this.expectedCoverage,
    required List<OracleTarget> targets,
    required List<OracleAuxiliaryExecutionTarget>
    oracleAuxiliaryExecutionTargets,
    required Map<String, FrozenScanArtifact> scans,
    this.analysisHealthAllowance,
  }) : targets = List.unmodifiable(List<OracleTarget>.from(targets)),
       oracleAuxiliaryExecutionTargets = List.unmodifiable(
         List<OracleAuxiliaryExecutionTarget>.from(
           oracleAuxiliaryExecutionTargets,
         ),
       ),
       scans = Map.unmodifiable(Map<String, FrozenScanArtifact>.from(scans));

  /// Manifest schema version.
  final int manifestSchemaVersion;

  /// Stable, non-path project label.
  final String label;

  /// Exact resolved project root retained only in the external manifest.
  final String projectRoot;

  /// Pinned project Git revision identity.
  final String projectGitSha;

  /// Exact resolved package root retained only in the external manifest.
  final String packageRoot;

  /// Flutter toolchain identity.
  final String flutterVersion;

  /// Dart toolchain identity.
  final String dartVersion;

  /// Pinned Flutter Pruner source identity.
  final String toolSha;

  /// SHA-256 of the project configuration.
  final String configSha256;

  /// SHA-256 of the project package configuration.
  final String packageConfigSha256;

  /// SHA-256 of the project lockfile.
  final String lockfileSha256;

  /// SHA-256 of the tool package configuration.
  final String toolPackageConfigSha256;

  /// SHA-256 of the tool lockfile.
  final String toolLockfileSha256;

  /// Fingerprint of the original managed project state.
  final String originalManagedFingerprint;

  /// Fingerprint of the disposable worktree managed state.
  final String worktreeManagedFingerprint;

  /// Root-policy identity.
  final int rootPolicyVersion;

  /// Candidate-boundary-policy identity.
  final int candidateBoundaryPolicyVersion;

  /// Finding-contract-policy identity.
  final int findingContractPolicyVersion;

  /// Explicit `accepted` or `capture-only` validation mode.
  final String manifestValidationMode;

  /// Explicit category roots used by the separate redacted serialization.
  final ManifestRedactionRoots redactionRoots;

  /// Complete analysis coverage declaration.
  final ExpectedAnalysisCoverage expectedCoverage;

  /// Immutable configured application targets.
  final List<OracleTarget> targets;

  /// Immutable project-global auxiliary root-universe definition.
  final List<OracleAuxiliaryExecutionTarget> oracleAuxiliaryExecutionTargets;

  /// Immutable per-scan scanner artifacts.
  final Map<String, FrozenScanArtifact> scans;

  /// Optional, capture-only exact health characterization.
  final AnalysisHealthAllowance? analysisHealthAllowance;

  /// Parses and validates an exact external resolved manifest.
  static AccuracyProjectManifest fromJson(Map<String, Object?> json) {
    final reader = _ObjectReader(json, 'manifest');
    final manifestSchemaVersion = reader.intValue('manifestSchemaVersion');
    _expectVersion(
      'manifestSchemaVersion',
      manifestSchemaVersion,
      supportedManifestSchemaVersion,
    );
    final projectRoot = reader.absolutePath('projectRoot');
    final packageRoot = reader.absolutePath('packageRoot');
    final redactionRoots = _parseRedactionRoots(reader.map('redactionRoots'));
    final targets = reader
        .list('targets')
        .map(_parseTarget)
        .toList(growable: false);
    _sortedUnique(
      targets.map((target) => target.executionContextId),
      'configured execution context',
    );
    final auxiliaries = reader
        .list('oracleAuxiliaryExecutionTargets')
        .map((value) => _parseAuxiliary(value, targets))
        .toList(growable: false);
    _sortedUnique(
      auxiliaries.map((target) => target.id),
      'auxiliary target ID',
    );
    final coverage = _parseCoverage(reader.map('expectedCoverage'));
    final mode = reader.string('manifestValidationMode');
    if (mode != 'accepted' && mode != 'capture-only') {
      _invalid('unknown manifestValidationMode $mode');
    }
    final scans = <String, FrozenScanArtifact>{};
    for (final entry in reader.map('scans').entries) {
      if (entry.key.isEmpty) _invalid('scan name must not be empty');
      scans[entry.key] = _parseScan(
        entry.key,
        _asMap(entry.value, 'manifest.scans.${entry.key}'),
        targets,
        auxiliaries,
        packageRoot,
        redactionRoots['tool'].canonicalPath,
        coverage.targetMatrixSource,
      );
    }
    _validateRequiredScans(scans);
    _validateArtifactPaths(scans);
    final allowanceValue = reader.optional('analysisHealthAllowance');
    final allowance = allowanceValue == null
        ? null
        : _parseHealthAllowance(
            _asMap(allowanceValue, 'manifest.analysisHealthAllowance'),
            targets,
            scans,
          );
    _validateMode(mode, coverage, allowance);
    final manifest = AccuracyProjectManifest(
      manifestSchemaVersion: manifestSchemaVersion,
      label: reader.string('label'),
      projectRoot: projectRoot,
      projectGitSha: reader.sha('projectGitSha', git: true),
      packageRoot: packageRoot,
      flutterVersion: reader.string('flutterVersion'),
      dartVersion: reader.string('dartVersion'),
      toolSha: reader.sha('toolSha', git: true),
      configSha256: reader.sha('configSha256'),
      packageConfigSha256: reader.sha('packageConfigSha256'),
      lockfileSha256: reader.sha('lockfileSha256'),
      toolPackageConfigSha256: reader.sha('toolPackageConfigSha256'),
      toolLockfileSha256: reader.sha('toolLockfileSha256'),
      originalManagedFingerprint: reader.sha('originalManagedFingerprint'),
      worktreeManagedFingerprint: reader.sha('worktreeManagedFingerprint'),
      rootPolicyVersion: _version(
        'rootPolicyVersion',
        reader.intValue('rootPolicyVersion'),
        supportedRootPolicyVersion,
      ),
      candidateBoundaryPolicyVersion: _version(
        'candidateBoundaryPolicyVersion',
        reader.intValue('candidateBoundaryPolicyVersion'),
        supportedCandidateBoundaryPolicyVersion,
      ),
      findingContractPolicyVersion: _version(
        'findingContractPolicyVersion',
        reader.intValue('findingContractPolicyVersion'),
        supportedFindingContractPolicyVersion,
      ),
      manifestValidationMode: mode,
      redactionRoots: redactionRoots,
      expectedCoverage: coverage,
      targets: targets,
      oracleAuxiliaryExecutionTargets: auxiliaries,
      scans: scans,
      analysisHealthAllowance: allowance,
    );
    reader.finish();
    return manifest;
  }

  /// Produces an irreversible, path-safe JSON view suitable for the repository.
  Map<String, Object?> toRedactedJson() {
    final redacted = <String, Object?>{
      'manifestSchemaVersion': manifestSchemaVersion,
      'label': label,
      'projectRoot': _redactPath(projectRoot, 'projectRoot'),
      'projectGitSha': projectGitSha,
      'packageRoot': _redactPath(packageRoot, 'packageRoot'),
      'flutterVersion': flutterVersion,
      'dartVersion': dartVersion,
      'toolSha': toolSha,
      'configSha256': configSha256,
      'packageConfigSha256': packageConfigSha256,
      'lockfileSha256': lockfileSha256,
      'toolPackageConfigSha256': toolPackageConfigSha256,
      'toolLockfileSha256': toolLockfileSha256,
      'originalManagedFingerprint': originalManagedFingerprint,
      'worktreeManagedFingerprint': worktreeManagedFingerprint,
      'rootPolicyVersion': rootPolicyVersion,
      'candidateBoundaryPolicyVersion': candidateBoundaryPolicyVersion,
      'findingContractPolicyVersion': findingContractPolicyVersion,
      'manifestValidationMode': manifestValidationMode,
      'expectedCoverage': _redactedCoverage(),
      'targets': targets.map(_redactedTarget).toList(growable: false),
      'oracleAuxiliaryExecutionTargets': oracleAuxiliaryExecutionTargets
          .map(_redactedAuxiliary)
          .toList(growable: false),
      'scans': scans.map((name, scan) => MapEntry(name, _redactedScan(scan))),
      if (analysisHealthAllowance != null)
        'analysisHealthAllowance': _redactedAllowance(analysisHealthAllowance!),
    };
    assertRedactedJsonPathSafe(redacted);
    return redacted;
  }

  /// Throws when [json] recursively retains a POSIX, Windows, UNC, or file URI.
  static void assertRedactedJsonPathSafe(Object? json) {
    _walkJson(json, (value) {
      if (value is String && _containsAbsolutePath(value)) {
        throw StateError('redacted JSON leaks an absolute path');
      }
    });
  }

  Map<String, Object?> _redactedCoverage() => <String, Object?>{
    'analysisMode': expectedCoverage.analysisMode,
    'auxiliaryExecutionTargetIssuesPresent':
        expectedCoverage.auxiliaryExecutionTargetIssuesPresent,
    'auxiliaryExecutionTargetIssues': expectedCoverage
        .auxiliaryExecutionTargetIssues
        .map(
          (issue) => <String, Object?>{
            'id': issue.id,
            'acceptedDefinitionSha256': issue.acceptedDefinitionSha256,
            'rejectedDefinitionSha256': issue.rejectedDefinitionSha256,
            'reason': _redactIssue(issue.reason),
          },
        )
        .toList(growable: false),
    'targetMatrixStatus': expectedCoverage.targetMatrixStatus,
    'targetMatrixComplete': expectedCoverage.targetMatrixComplete,
    'targetMatrixSource': _redactPath(
      expectedCoverage.targetMatrixSource,
      'targetMatrixSource',
    ),
    'targetMatrixIssues': expectedCoverage.targetMatrixIssues
        .map(_redactIssue)
        .toList(growable: false),
    'rootMode': expectedCoverage.rootMode,
    'rootCoverageComplete': expectedCoverage.rootCoverageComplete,
    'internalBoundaryComplete': expectedCoverage.internalBoundaryComplete,
    'externalConsumersCovered': expectedCoverage.externalConsumersCovered,
    'rootSource': _redactPath(expectedCoverage.rootSource, 'rootSource'),
    'publicEntrypoints': expectedCoverage.publicEntrypoints,
    'rootIssues': expectedCoverage.rootIssues
        .map(_redactIssue)
        .toList(growable: false),
  };

  Map<String, Object?> _redactedTarget(OracleTarget target) =>
      <String, Object?>{
        'name': target.name,
        'platform': target.platform,
        'entrypoint': target.entrypoint,
        'flavor': target.flavor,
        'dartDefines': target.dartDefines,
      };

  Map<String, Object?> _redactedAuxiliary(
    OracleAuxiliaryExecutionTarget target,
  ) => <String, Object?>{
    'id': target.id,
    'domain': target.domain.name,
    'environmentValues': target.environmentValues,
    'environmentComplete': target.environmentComplete,
    'reason': _redactIssue(target.reason),
    'sourceConfiguredTarget': target.sourceConfiguredTarget == null
        ? null
        : _redactedTarget(target.sourceConfiguredTarget!),
  };

  Map<String, Object?> _redactedScan(
    FrozenScanArtifact scan,
  ) => <String, Object?>{
    'rawReportPath': _redactPath(scan.rawReportPath, 'rawReportPath'),
    'rawReportSha256': scan.rawReportSha256,
    'scannerArgvTemplate': _redactArgv(scan.scannerArgv),
    'scannerArgvSha256': scan.scannerArgvSha256,
    'jsonSchemaVersion': scan.jsonSchemaVersion,
    'requestedAdapters': scan.requestedAdapters,
    'expectedAuxiliaryExecutionTargets': scan.expectedAuxiliaryExecutionTargets
        .map(_redactedAuxiliary)
        .toList(growable: false),
    'graphMembershipMode': scan.graphMembershipMode.name,
    'expectedGraphMembershipContextIds': scan.expectedGraphMembershipContextIds,
    'graphObservation': <String, Object?>{
      'rawObservationPath': _redactPath(
        scan.graphObservation.rawObservationPath,
        'rawObservationPath',
      ),
      'rawObservationSha256': scan.graphObservation.rawObservationSha256,
      'observationReportPath': _redactPath(
        scan.graphObservation.observationReportPath,
        'observationReportPath',
      ),
      'observationReportSha256': scan.graphObservation.observationReportSha256,
      'captureArgvTemplate': _redactArgv(scan.graphObservation.captureArgv),
      'captureArgvSha256': scan.graphObservation.captureArgvSha256,
      'schemaVersion': scan.graphObservation.schemaVersion,
    },
  };

  Map<String, Object?> _redactedAllowance(AnalysisHealthAllowance allowance) =>
      <String, Object?>{
        'policyVersion': allowance.policyVersion,
        'diagnosticCountsByCodePhase': allowance.diagnosticCountsByCodePhase,
        'danglingCountsByPassId': allowance.danglingCountsByPassId.map(
          (passId, count) => MapEntry(passId, <String, Object?>{
            'edges': count.edges,
            'roots': count.roots,
          }),
        ),
        'danglingCountsByPassAndExecutionTargetId': allowance
            .danglingCountsByPassAndExecutionTargetId
            .map(
              (passId, byTarget) => MapEntry(
                passId,
                byTarget.map(
                  (targetId, count) => MapEntry(targetId, <String, Object?>{
                    'edges': count.edges,
                    'roots': count.roots,
                  }),
                ),
              ),
            ),
        'passIdsWithIntegrityMapAbsent':
            allowance.passIdsWithIntegrityMapAbsent.toList()..sort(),
      };

  Object _redactPath(String value, String category) {
    final normalized = _normalisePath(value);
    for (final entry in _knownRoots()) {
      if (_isWithin(normalized, entry.path)) {
        final suffix = normalized.substring(entry.path.length);
        return '${entry.placeholder}$suffix';
      }
    }
    return <String, Object?>{'category': category, 'sha256': _hash(value)};
  }

  List<String> _redactArgv(List<String> argv) => argv
      .map((argument) {
        final redacted = _replaceKnownRoots(argument);
        if (_containsAbsolutePath(redacted)) {
          return '<redacted:${_hash(argument)}>';
        }
        return redacted;
      })
      .toList(growable: false);

  Object _redactIssue(String issue) {
    final redacted = _replaceKnownRoots(issue);
    if (_containsAbsolutePath(redacted)) {
      return <String, Object?>{
        'category': 'unprovable-free-text',
        'sha256': _hash(issue),
      };
    }
    return redacted;
  }

  String _replaceKnownRoots(String value) {
    var normalized = _normaliseSeparators(value.replaceAll('file:///', '/'));
    for (final root in _knownRoots()) {
      normalized = normalized.replaceAllMapped(
        RegExp('${RegExp.escape(root.path)}(?=/|\\s|\$)'),
        (_) => root.placeholder,
      );
    }
    return normalized;
  }

  List<({String path, String placeholder})> _knownRoots() {
    final result = <({String path, String placeholder})>[];
    const categories = <String, String>{
      'project': r'$PROJECT',
      'worktree': r'$WORKTREE',
      'tool': r'$TOOL',
      'result': r'$RESULT',
    };
    for (final entry in categories.entries) {
      final root = redactionRoots[entry.key];
      result.add((
        path: _normalisePath(root.canonicalPath),
        placeholder: entry.value,
      ));
      for (final alias in root.aliases) {
        result.add((path: _normalisePath(alias), placeholder: entry.value));
      }
    }
    result.sort((left, right) => right.path.length.compareTo(left.path.length));
    return result;
  }
}

OracleTarget _parseTarget(Object? value) {
  final reader = _ObjectReader(_asMap(value, 'target'), 'target');
  final defines = reader
      .map('dartDefines')
      .map(
        (key, value) =>
            MapEntry(key, _asString(value, 'target.dartDefines.$key')),
      );
  final flavor = reader.nullable('flavor');
  if (flavor != null && flavor is! String) {
    _invalid('target.flavor must be string or null');
  }
  final target = OracleTarget(
    name: reader.string('name'),
    platform: reader.string('platform'),
    entrypoint: reader.relativePosixPath('entrypoint', requireDart: true),
    flavor: flavor as String?,
    dartDefines: defines,
  );
  try {
    target.executionContextId;
  } on StateError {
    _invalid('target.name must be a canonical configured execution context');
  }
  reader.finish();
  return target;
}

OracleAuxiliaryExecutionTarget _parseAuxiliary(
  Object? value,
  List<OracleTarget> configuredTargets,
) {
  final reader = _ObjectReader(
    _asMap(value, 'auxiliary target'),
    'auxiliary target',
  );
  final domainName = reader.string('domain');
  final domain = switch (domainName) {
    'test' => OracleAuxiliaryDomain.test,
    'runtime' => OracleAuxiliaryDomain.runtime,
    'external' => OracleAuxiliaryDomain.external,
    _ => throw FormatException('unknown auxiliary domain $domainName'),
  };
  final source = reader.nullable('sourceConfiguredTarget');
  final id = reader.string('id');
  if (!id.startsWith('${domain.name}:')) {
    _invalid('auxiliary target ID must begin with ${domain.name}:');
  }
  final sourceTarget = source == null ? null : _parseTarget(source);
  if (sourceTarget != null &&
      !configuredTargets.any((target) => _sameTarget(target, sourceTarget))) {
    _invalid('auxiliary sourceConfiguredTarget is not a declared target');
  }
  final target = OracleAuxiliaryExecutionTarget(
    id: id,
    domain: domain,
    environmentValues: reader
        .map('environmentValues')
        .map(
          (key, value) => MapEntry(
            key,
            _asString(value, 'auxiliary target.environmentValues.$key'),
          ),
        ),
    environmentComplete: reader.boolean('environmentComplete'),
    reason: reader.string('reason'),
    sourceConfiguredTarget: sourceTarget,
  );
  try {
    target.executionContextId;
  } on StateError {
    _invalid('target.id must produce a canonical auxiliary execution context');
  }
  reader.finish();
  return target;
}

ExpectedAnalysisCoverage _parseCoverage(Map<String, Object?> value) {
  final reader = _ObjectReader(value, 'expectedCoverage');
  final issueValues = reader.list('auxiliaryExecutionTargetIssues');
  final issues = issueValues
      .map((value) {
        final issue = _ObjectReader(
          _asMap(value, 'auxiliary issue'),
          'auxiliary issue',
        );
        final result = AuxiliaryExecutionTargetIssue(
          id: issue.string('id'),
          acceptedDefinitionSha256: issue.sha('acceptedDefinitionSha256'),
          rejectedDefinitionSha256: issue.sha('rejectedDefinitionSha256'),
          reason: issue.string('reason'),
        );
        issue.finish();
        return result;
      })
      .toList(growable: false);
  _unique(issues.map((issue) => issue.id), 'auxiliary issue ID');
  final analysisMode = reader.string('analysisMode');
  if (!const <String>{
    'application',
    'package',
    'package-internal',
  }.contains(analysisMode)) {
    _invalid('unknown analysisMode $analysisMode');
  }
  final targetMatrixStatus = reader.string('targetMatrixStatus');
  if (!const <String>{
    'declaredComplete',
    'declaredPartial',
    'inferredDefault',
  }.contains(targetMatrixStatus)) {
    _invalid('unknown targetMatrixStatus $targetMatrixStatus');
  }
  final rootMode = reader.string('rootMode');
  if (!const <String>{
    'applicationEntrypoints',
    'packagePublicApi',
    'packageInternal',
    'inferred',
  }.contains(rootMode)) {
    _invalid('unknown rootMode $rootMode');
  }
  final coverage = ExpectedAnalysisCoverage(
    analysisMode: analysisMode,
    auxiliaryExecutionTargetIssuesPresent: reader.boolean(
      'auxiliaryExecutionTargetIssuesPresent',
    ),
    auxiliaryExecutionTargetIssues: issues,
    targetMatrixStatus: targetMatrixStatus,
    targetMatrixComplete: reader.boolean('targetMatrixComplete'),
    targetMatrixSource: reader.absolutePath('targetMatrixSource'),
    targetMatrixIssues: reader.strings('targetMatrixIssues'),
    rootMode: rootMode,
    rootCoverageComplete: reader.boolean('rootCoverageComplete'),
    internalBoundaryComplete: reader.boolean('internalBoundaryComplete'),
    externalConsumersCovered: reader.boolean('externalConsumersCovered'),
    rootSource: reader.absolutePath('rootSource'),
    publicEntrypoints: reader.relativePosixPaths(
      'publicEntrypoints',
      requireDart: true,
    ),
    rootIssues: reader.strings('rootIssues'),
  );
  if (coverage.targetMatrixComplete !=
      (coverage.targetMatrixStatus == 'declaredComplete')) {
    _invalid('targetMatrixComplete disagrees with targetMatrixStatus');
  }
  if (coverage.rootCoverageComplete !=
      (coverage.internalBoundaryComplete &&
          coverage.externalConsumersCovered)) {
    _invalid('rootCoverageComplete disagrees with boundary coverage');
  }
  final allowedRootModes = switch (coverage.analysisMode) {
    'application' => const <String>{'applicationEntrypoints', 'inferred'},
    'package' => const <String>{'packagePublicApi', 'inferred'},
    'package-internal' => const <String>{'packageInternal', 'inferred'},
    _ => const <String>{},
  };
  if (!allowedRootModes.contains(coverage.rootMode)) {
    _invalid('rootMode is incompatible with analysisMode');
  }
  if (coverage.rootMode == 'inferred' && coverage.rootCoverageComplete) {
    _invalid('inferred rootMode cannot claim complete root coverage');
  }
  final requiresPublicEntrypoints =
      coverage.analysisMode == 'package' ||
      coverage.analysisMode == 'package-internal';
  if ((coverage.analysisMode == 'application' &&
          coverage.publicEntrypoints.isNotEmpty) ||
      (requiresPublicEntrypoints && coverage.publicEntrypoints.isEmpty)) {
    _invalid('publicEntrypoints are incompatible with analysisMode');
  }
  reader.finish();
  return coverage;
}

FrozenScanArtifact _parseScan(
  String scanKey,
  Map<String, Object?> value,
  List<OracleTarget> targets,
  List<OracleAuxiliaryExecutionTarget> projectAuxiliaries,
  String packageRoot,
  String toolRoot,
  String configPath,
) {
  final reader = _ObjectReader(value, 'scan');
  final requestedAdapters = reader.strings('requestedAdapters');
  if (requestedAdapters.isEmpty) {
    _invalid('scan requestedAdapters must not be empty');
  }
  _sortedUnique(requestedAdapters, 'requested adapter ID');
  if (requestedAdapters.any(
    (adapter) => !_supportedAdapterIds.contains(adapter),
  )) {
    _invalid('unknown requested adapter');
  }
  final scanAuxiliaries = reader
      .list('expectedAuxiliaryExecutionTargets')
      .map((value) => _parseAuxiliary(value, targets))
      .toList(growable: false);
  _sortedUnique(
    scanAuxiliaries.map((target) => target.id),
    'scan auxiliary target ID',
  );
  final globalById = <String, OracleAuxiliaryExecutionTarget>{
    for (final auxiliary in projectAuxiliaries) auxiliary.id: auxiliary,
  };
  final expectedScanAuxiliaries = scanKey == 'adapter:duplicates'
      ? const <OracleAuxiliaryExecutionTarget>[]
      : projectAuxiliaries;
  if (scanAuxiliaries.length != expectedScanAuxiliaries.length ||
      scanAuxiliaries.any((auxiliary) {
        final global = globalById[auxiliary.id];
        return global == null || !_sameAuxiliary(global, auxiliary);
      }) ||
      !_sameAuxiliaryLists(scanAuxiliaries, expectedScanAuxiliaries)) {
    _invalid('scan auxiliary registry is not the complete applicable universe');
  }
  final membershipName = reader.string('graphMembershipMode');
  final membership = switch (membershipName) {
    'exact' => ScannerGraphMembershipMode.exact,
    'notApplicable' => ScannerGraphMembershipMode.notApplicable,
    _ => throw FormatException('unknown graphMembershipMode $membershipName'),
  };
  final contextIds = reader.strings('expectedGraphMembershipContextIds');
  _validateScanMembership(
    requestedAdapters,
    scanAuxiliaries,
    membership,
    contextIds,
    targets,
  );
  final scannerArgv = _argv(reader.strings('scannerArgv'), 'scannerArgv');
  final scannerArgvSha256 = reader.sha('scannerArgvSha256');
  _validateArgvHash(scannerArgv, scannerArgvSha256, 'scannerArgv');
  final graph = _parseGraphObservation(reader.map('graphObservation'));
  _validateScannerCommand(
    scanKey,
    requestedAdapters,
    scannerArgv,
    packageRoot,
    toolRoot,
    configPath,
    reader.absolutePath('rawReportPath'),
  );
  _validateCaptureCommand(
    scanKey,
    requestedAdapters,
    graph.captureArgv,
    packageRoot,
    toolRoot,
    configPath,
    graph.observationReportPath,
    graph.rawObservationPath,
  );
  final scan = FrozenScanArtifact(
    rawReportPath: reader.absolutePath('rawReportPath'),
    rawReportSha256: reader.sha('rawReportSha256'),
    scannerArgv: scannerArgv,
    scannerArgvSha256: scannerArgvSha256,
    jsonSchemaVersion: _jsonSchemaVersion(reader.intValue('jsonSchemaVersion')),
    requestedAdapters: requestedAdapters,
    expectedAuxiliaryExecutionTargets: scanAuxiliaries,
    graphMembershipMode: membership,
    expectedGraphMembershipContextIds: contextIds,
    graphObservation: graph,
  );
  reader.finish();
  return scan;
}

FrozenScannerGraphArtifact _parseGraphObservation(Map<String, Object?> value) {
  final reader = _ObjectReader(value, 'graphObservation');
  final captureArgv = _argv(reader.strings('captureArgv'), 'captureArgv');
  final captureArgvSha256 = reader.sha('captureArgvSha256');
  _validateArgvHash(captureArgv, captureArgvSha256, 'captureArgv');
  final graph = FrozenScannerGraphArtifact(
    rawObservationPath: reader.absolutePath('rawObservationPath'),
    rawObservationSha256: reader.sha('rawObservationSha256'),
    observationReportPath: reader.absolutePath('observationReportPath'),
    observationReportSha256: reader.sha('observationReportSha256'),
    captureArgv: captureArgv,
    captureArgvSha256: captureArgvSha256,
    schemaVersion: _version(
      'graphObservation.schemaVersion',
      reader.intValue('schemaVersion'),
      AccuracyProjectManifest.supportedGraphObservationSchemaVersion,
    ),
  );
  reader.finish();
  return graph;
}

AnalysisHealthAllowance _parseHealthAllowance(
  Map<String, Object?> value,
  List<OracleTarget> targets,
  Map<String, FrozenScanArtifact> scans,
) {
  final reader = _ObjectReader(value, 'analysisHealthAllowance');
  final diagnostics = reader
      .map('diagnosticCountsByCodePhase')
      .map(
        (key, value) =>
            MapEntry(key, _nonNegativeInt(value, 'diagnostic $key')),
      );
  final aggregate = reader
      .map('danglingCountsByPassId')
      .map(
        (key, value) => MapEntry(key, _counts(value, 'aggregate pass $key')),
      );
  final perTarget = reader
      .map('danglingCountsByPassAndExecutionTargetId')
      .map(
        (passId, value) => MapEntry(
          passId,
          _asMap(value, 'integrity map $passId').map(
            (targetId, count) =>
                MapEntry(targetId, _counts(count, '$passId/$targetId')),
          ),
        ),
      );
  final absent = reader.strings('passIdsWithIntegrityMapAbsent').toSet();
  if (absent.length != reader.strings('passIdsWithIntegrityMapAbsent').length) {
    _invalid('duplicate absent integrity pass ID');
  }
  final expectedPassIds = <String>{
    for (final scanKey in scans.keys) '$scanKey|$_recognizedIntegrityPassId',
  };
  final expectedDiagnosticKeys = <String>{
    for (final scanKey in scans.keys)
      '$scanKey|$_recognizedDiagnosticCode|$_recognizedDiagnosticPhase',
  };
  if (!_setsEqual(aggregate.keys.toSet(), expectedPassIds) ||
      !_setsEqual(<String>{...perTarget.keys, ...absent}, expectedPassIds) ||
      !_setsEqual(diagnostics.keys.toSet(), expectedDiagnosticKeys) ||
      perTarget.keys.toSet().intersection(absent).isNotEmpty) {
    _invalid('health integrity-map presence drift');
  }
  for (final key in diagnostics.keys) {
    final parts = _splitBucket(key, 3, 'diagnostic');
    if (!scans.containsKey(parts[0]) ||
        parts[1] != _recognizedDiagnosticCode ||
        parts[2] != _recognizedDiagnosticPhase) {
      _invalid('unknown diagnostic bucket');
    }
  }
  for (final entry in perTarget.entries) {
    final parts = _splitBucket(entry.key, 2, 'integrity pass');
    if (!scans.containsKey(parts[0]) ||
        parts[1] != _recognizedIntegrityPassId) {
      _invalid('unknown integrity pass identity');
    }
    final scan = scans[parts[0]]!;
    final allowedContexts = <String>{
      ...targets.map((target) => target.executionContextId),
      ...scan.expectedAuxiliaryExecutionTargets.map(
        (target) => target.executionContextId,
      ),
      'unattributed',
    };
    if (entry.value.keys.toSet().length != entry.value.length ||
        !_setsEqual(entry.value.keys.toSet(), allowedContexts)) {
      _invalid('health integrity context map drift for ${entry.key}');
    }
    final sums = entry.value.values.fold(
      (edges: 0, roots: 0),
      (sum, count) =>
          (edges: sum.edges + count.edges, roots: sum.roots + count.roots),
    );
    if (sums != aggregate[entry.key]) {
      _invalid('health aggregate drift for ${entry.key}');
    }
  }
  final allowance = AnalysisHealthAllowance(
    policyVersion: _version(
      'analysisHealthAllowance.policyVersion',
      reader.intValue('policyVersion'),
      AccuracyProjectManifest.supportedHealthAllowancePolicyVersion,
    ),
    diagnosticCountsByCodePhase: diagnostics,
    danglingCountsByPassId: aggregate,
    danglingCountsByPassAndExecutionTargetId: perTarget,
    passIdsWithIntegrityMapAbsent: absent,
  );
  reader.finish();
  return allowance;
}

ManifestRedactionRoots _parseRedactionRoots(Map<String, Object?> value) {
  const categories = <String>['project', 'worktree', 'tool', 'result'];
  if (value.length != categories.length ||
      !value.keys.toSet().containsAll(categories)) {
    _invalid(
      'redactionRoots must declare exactly project/worktree/tool/result',
    );
  }
  final roots = <String, RedactionRoot>{};
  for (final category in categories) {
    final reader = _ObjectReader(
      _asMap(value[category], 'redactionRoots.$category'),
      'redactionRoots.$category',
    );
    final canonical = reader.absolutePath('canonicalPath');
    final aliases = reader.absolutePaths('aliases');
    _unique(
      <String>[canonical, ...aliases].map(_normalisePath),
      '$category root alias',
    );
    roots[category] = RedactionRoot(canonical, aliases);
    reader.finish();
  }
  return ManifestRedactionRoots(roots: roots);
}

void _validateMode(
  String mode,
  ExpectedAnalysisCoverage coverage,
  AnalysisHealthAllowance? allowance,
) {
  if (mode == 'accepted') {
    if (!coverage.auxiliaryExecutionTargetIssuesPresent ||
        coverage.auxiliaryExecutionTargetIssues.isNotEmpty ||
        coverage.targetMatrixStatus != 'declaredComplete' ||
        !coverage.targetMatrixComplete ||
        coverage.targetMatrixIssues.isNotEmpty ||
        !coverage.rootCoverageComplete ||
        !coverage.internalBoundaryComplete ||
        !coverage.externalConsumersCovered ||
        coverage.rootSource != coverage.targetMatrixSource ||
        coverage.rootIssues.isNotEmpty ||
        allowance != null) {
      _invalid('accepted manifest has incomplete coverage or allowance');
    }
    return;
  }
}

void _validateRequiredScans(Map<String, FrozenScanArtifact> scans) {
  final expected = <String>{
    'full',
    for (final adapter in _supportedAdapterIds) 'adapter:$adapter',
  };
  if (!_setsEqual(scans.keys.toSet(), expected)) {
    _invalid(
      'manifest scan inventory must be full plus every isolated adapter',
    );
  }
}

void _validateArtifactPaths(Map<String, FrozenScanArtifact> scans) {
  final artifactPaths = <String>{};
  for (final scan in scans.values) {
    if (!artifactPaths.add(_lexicalPath(scan.rawReportPath)) ||
        !artifactPaths.add(
          _lexicalPath(scan.graphObservation.rawObservationPath),
        ) ||
        !artifactPaths.add(
          _lexicalPath(scan.graphObservation.observationReportPath),
        )) {
      _invalid('raw report and graph-observation paths must be unique');
    }
  }
}

void _validateScanMembership(
  List<String> requestedAdapters,
  List<OracleAuxiliaryExecutionTarget> auxiliaries,
  ScannerGraphMembershipMode mode,
  List<String> contextIds,
  List<OracleTarget> targets,
) {
  final needsReachability = requestedAdapters.any(
    (adapter) => adapter != 'duplicates',
  );
  final expected = <String>[
    ...targets.map((target) => target.executionContextId),
    ...auxiliaries.map((target) => target.executionContextId),
  ]..sort();
  final sorted = List<String>.from(contextIds)..sort();
  if (contextIds.length != contextIds.toSet().length ||
      contextIds.join('\u0000') != sorted.join('\u0000')) {
    _invalid('graph membership context IDs must be unique and sorted');
  }
  if (mode == ScannerGraphMembershipMode.notApplicable) {
    if (needsReachability || auxiliaries.isNotEmpty || contextIds.isNotEmpty) {
      _invalid(
        'notApplicable graph membership is only valid for duplicates-only',
      );
    }
    return;
  }
  if (!needsReachability ||
      contextIds.join('\u0000') != expected.join('\u0000')) {
    _invalid(
      'exact graph membership must equal configured plus scan auxiliary IDs',
    );
  }
}

bool _sameAuxiliary(
  OracleAuxiliaryExecutionTarget left,
  OracleAuxiliaryExecutionTarget right,
) =>
    left.id == right.id &&
    left.domain == right.domain &&
    _mapsEqual(left.environmentValues, right.environmentValues) &&
    left.environmentComplete == right.environmentComplete &&
    left.reason == right.reason &&
    _sameTarget(left.sourceConfiguredTarget, right.sourceConfiguredTarget);

bool _sameTarget(OracleTarget? left, OracleTarget? right) =>
    left == null || right == null
    ? left == right
    : left.executionContextId == right.executionContextId &&
          left.platform == right.platform &&
          left.entrypoint == right.entrypoint &&
          left.flavor == right.flavor &&
          _mapsEqual(left.dartDefines, right.dartDefines);

bool _mapsEqual(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

bool _setsEqual(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _sameAuxiliaryLists(
  List<OracleAuxiliaryExecutionTarget> left,
  List<OracleAuxiliaryExecutionTarget> right,
) =>
    left.length == right.length &&
    left.indexed.every((entry) => _sameAuxiliary(entry.$2, right[entry.$1]));

List<String> _argv(List<String> value, String field) {
  const shells = <String>{'sh', 'bash', 'zsh', 'fish', 'cmd', 'powershell'};
  if (value.length < 2 ||
      value.any((argument) => argument.isEmpty) ||
      (shells.contains(value.first.split('/').last.toLowerCase()) &&
          value.length > 1 &&
          value[1] == '-c')) {
    _invalid('$field must be a non-shell argv vector');
  }
  return value;
}

void _validateArgvHash(List<String> argv, String hash, String field) {
  final actual = sha256.convert(utf8.encode(jsonEncode(argv))).toString();
  if (actual != hash) _invalid('$field SHA-256 does not match UTF-8 json argv');
}

List<String> _expectedAdaptersForScanKey(String scanKey) => switch (scanKey) {
  'full' => _supportedAdapterIds,
  _ when scanKey.startsWith('adapter:') => <String>[scanKey.substring(8)],
  _ => throw FormatException('unknown scan key $scanKey'),
};

void _validateScannerCommand(
  String scanKey,
  List<String> requestedAdapters,
  List<String> argv,
  String packageRoot,
  String toolRoot,
  String configPath,
  String rawReportPath,
) {
  final expectedAdapters = _expectedAdaptersForScanKey(scanKey);
  if (!_sameStringLists(requestedAdapters, expectedAdapters)) {
    _invalid('scan key and requestedAdapters disagree');
  }
  final expected = <String>[
    'run',
    _joinPath(toolRoot, 'bin/flutter_pruner.dart'),
    'scan',
    '--project',
    _lexicalPath(packageRoot),
    '--config',
    _lexicalPath(configPath),
    '--format',
    'json',
    '--json-version',
    '3',
    '--output',
    _lexicalPath(rawReportPath),
    if (scanKey != 'full') ...<String>['--adapter', expectedAdapters.single],
  ];
  if (!_hasDartRunPrefix(argv) ||
      !_sameNormalizedArgv(argv.skip(1).toList(growable: false), expected)) {
    _invalid('scanner argv is not the canonical v3 scan command');
  }
}

void _validateCaptureCommand(
  String scanKey,
  List<String> requestedAdapters,
  List<String> argv,
  String packageRoot,
  String toolRoot,
  String configPath,
  String observationReportPath,
  String rawObservationPath,
) {
  final expectedAdapters = _expectedAdaptersForScanKey(scanKey);
  if (!_sameStringLists(requestedAdapters, expectedAdapters)) {
    _invalid('scan key and requestedAdapters disagree');
  }
  final expected = <String>[
    'run',
    _joinPath(toolRoot, 'benchmark/accuracy/capture_scanner_graph.dart'),
    '--project',
    _lexicalPath(packageRoot),
    '--config',
    _lexicalPath(configPath),
    '--json-version',
    '3',
    '--report-output',
    _lexicalPath(observationReportPath),
    '--observation-output',
    _lexicalPath(rawObservationPath),
    if (scanKey != 'full') ...<String>['--adapter', expectedAdapters.single],
  ];
  if (!_hasDartRunPrefix(argv) ||
      !_sameNormalizedArgv(argv.skip(1).toList(growable: false), expected)) {
    _invalid('capture argv is not the canonical v3 graph-capture command');
  }
}

bool _hasDartRunPrefix(List<String> argv) =>
    argv.length >= 2 &&
    _isAbsolutePath(argv.first) &&
    p.posix.basename(_lexicalPath(argv.first)) == 'dart' &&
    argv[1] == 'run';

String _joinPath(String root, String child) =>
    p.posix.join(_lexicalPath(root), child);

String _lexicalPath(String value) => p.posix.normalize(_normalisePath(value));

bool _sameNormalizedArgv(List<String> actual, List<String> expected) =>
    actual.length == expected.length &&
    actual.indexed.every(
      (entry) =>
          _normaliseCommandToken(entry.$2) ==
          _normaliseCommandToken(expected[entry.$1]),
    );

String _normaliseCommandToken(String value) =>
    _isAbsolutePath(value) ? _lexicalPath(value) : value;

bool _sameStringLists(List<String> left, List<String> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => entry.$2 == right[entry.$1]);

List<String> _splitBucket(String value, int count, String context) {
  final parts = value.split('|');
  if (parts.length != count || parts.any((part) => part.isEmpty)) {
    _invalid('$context key has invalid identity convention');
  }
  return parts;
}

int _jsonSchemaVersion(int value) {
  if (value != 3) {
    _invalid('unknown scanner JSON schema version $value');
  }
  return value;
}

int _version(String field, int value, int supported) {
  _expectVersion(field, value, supported);
  return value;
}

void _expectVersion(String field, int value, int supported) {
  if (value != supported) _invalid('unknown $field $value');
}

({int edges, int roots}) _counts(Object? value, String context) {
  final reader = _ObjectReader(_asMap(value, context), context);
  final counts = (
    edges: _nonNegativeInt(reader.required('edges'), '$context.edges'),
    roots: _nonNegativeInt(reader.required('roots'), '$context.roots'),
  );
  reader.finish();
  return counts;
}

int _nonNegativeInt(Object? value, String field) {
  if (value is! int || value < 0) {
    _invalid('$field must be a non-negative integer');
  }
  return value;
}

void _unique(Iterable<String> values, String kind) {
  final list = values.toList(growable: false);
  if (list.any((value) => value.isEmpty) ||
      list.toSet().length != list.length) {
    _invalid('duplicate or empty $kind');
  }
}

void _sortedUnique(Iterable<String> values, String kind) {
  final list = values.toList(growable: false);
  _unique(list, kind);
  final sorted = List<String>.from(list)..sort();
  if (!_sameStringLists(list, sorted)) _invalid('$kind must be sorted');
}

Map<String, Object?> _asMap(Object? value, String context) {
  if (value is! Map) _invalid('$context must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) _invalid('$context has non-string key');
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _asString(Object? value, String context) {
  if (value is! String || value.isEmpty) {
    _invalid('$context must be a non-empty string');
  }
  return value;
}

Never _invalid(String message) => throw FormatException(message);

final class _ObjectReader {
  _ObjectReader(this._value, this._context);

  final Map<String, Object?> _value;
  final String _context;
  final Set<String> _used = <String>{};

  Object? required(String key) {
    _used.add(key);
    if (!_value.containsKey(key) || _value[key] == null) {
      _invalid('$_context.$key is required');
    }
    return _value[key];
  }

  Object? optional(String key) {
    if (_value.containsKey(key)) _used.add(key);
    return _value[key];
  }

  Object? nullable(String key) {
    _used.add(key);
    if (!_value.containsKey(key)) _invalid('$_context.$key is required');
    return _value[key];
  }

  String string(String key) => _asString(required(key), '$_context.$key');

  int intValue(String key) {
    final value = required(key);
    if (value is! int) _invalid('$_context.$key must be an integer');
    return value;
  }

  bool boolean(String key) {
    final value = required(key);
    if (value is! bool) _invalid('$_context.$key must be boolean');
    return value;
  }

  Map<String, Object?> map(String key) =>
      _asMap(required(key), '$_context.$key');

  List<Object?> list(String key) {
    final value = required(key);
    if (value is! List) _invalid('$_context.$key must be an array');
    return List<Object?>.from(value);
  }

  List<String> strings(String key) => list(key)
      .map((value) => _asString(value, '$_context.$key item'))
      .toList(growable: false);

  List<String> absolutePaths(String key) => strings(key)
      .map((value) {
        if (!_isAbsolutePath(value)) {
          _invalid('$_context.$key item must be absolute');
        }
        return value;
      })
      .toList(growable: false);

  String absolutePath(String key) {
    final value = string(key);
    if (!_isAbsolutePath(value)) _invalid('$_context.$key must be absolute');
    return value;
  }

  String relativePosixPath(String key, {required bool requireDart}) {
    final value = string(key);
    if (!_isCanonicalRelativePosixPath(value) ||
        (requireDart && !value.endsWith('.dart'))) {
      _invalid(
        '$_context.$key must be a canonical project-relative POSIX path',
      );
    }
    return value;
  }

  List<String> relativePosixPaths(
    String key, {
    required bool requireDart,
  }) => list(key)
      .map((value) => _asString(value, '$_context.$key item'))
      .map((value) {
        if (!_isCanonicalRelativePosixPath(value) ||
            (requireDart && !value.endsWith('.dart'))) {
          _invalid(
            '$_context.$key item must be a canonical project-relative POSIX path',
          );
        }
        return value;
      })
      .toList(growable: false);

  String sha(String key, {bool git = false}) {
    final value = string(key);
    final pattern = git
        ? RegExp(r'^[a-fA-F0-9]{40,64}$')
        : RegExp(r'^[a-fA-F0-9]{64}$');
    if (!pattern.hasMatch(value)) {
      _invalid('$_context.$key is not a SHA identity');
    }
    return value;
  }

  void finish() {
    final unknown = _value.keys.toSet().difference(_used);
    if (unknown.isNotEmpty) {
      _invalid('$_context has unrecognized fields: ${unknown.join(',')}');
    }
  }
}

bool _isAbsolutePath(String value) =>
    value.startsWith('/') ||
    RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(value) ||
    value.startsWith(r'\\');

bool _isCanonicalRelativePosixPath(String value) {
  if (value.isEmpty ||
      _isAbsolutePath(value) ||
      value.toLowerCase().startsWith('file:') ||
      value.contains('\\') ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('//')) {
    return false;
  }
  return value
      .split('/')
      .every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

String _normalisePath(String value) {
  var path = value;
  if (path.toLowerCase().startsWith('file:')) {
    final uri = Uri.tryParse(path);
    if (uri == null) _invalid('invalid file URI');
    if (uri.scheme.toLowerCase() != 'file') _invalid('invalid file URI');
    path = uri.toFilePath();
  }
  return _normaliseSeparators(path);
}

String _normaliseSeparators(String value) {
  var normalized = value.replaceAll('\\', '/');
  normalized = normalized.replaceAll(RegExp(r'/+'), '/');
  return normalized.length > 1 && normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
}

bool _isWithin(String value, String root) =>
    value == root || value.startsWith('$root/');

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

final _httpUriSchemePattern = RegExp(r'https?://', caseSensitive: false);

final _absoluteFilesystemPathPattern = RegExp(
  r'''(?:file:[/\\]+|[a-z]:[\\/]|\\\\|(?:^|[^A-Za-z0-9_./-])/)''',
  caseSensitive: false,
);

bool _containsAbsolutePath(String value) =>
    _absoluteFilesystemPathPattern.hasMatch(_maskValidatedHttpUris(value));

String _maskValidatedHttpUris(String value) {
  final masked = StringBuffer();
  var unmaskedStart = 0;
  for (final match in _httpUriSchemePattern.allMatches(value)) {
    if (match.start < unmaskedStart ||
        !_isHttpUriStartBoundary(value, match.start)) {
      continue;
    }
    final end = _httpUriCandidateEnd(value, match.start);
    final candidate = value.substring(match.start, end);
    if (!_isValidatedHttpUri(candidate)) continue;
    masked
      ..write(value.substring(unmaskedStart, match.start))
      ..write(' ');
    unmaskedStart = end;
  }
  if (unmaskedStart == 0) return value;
  return (masked..write(value.substring(unmaskedStart))).toString();
}

bool _isHttpUriStartBoundary(String value, int start) =>
    start == 0 || !_isUriTokenCodeUnit(value.codeUnitAt(start - 1));

int _httpUriCandidateEnd(String value, int start) {
  var end = start;
  while (end < value.length && !_isHttpUriSpanBoundary(value.codeUnitAt(end))) {
    end++;
  }
  return end;
}

bool _isUriTokenCodeUnit(int codeUnit) =>
    codeUnit >= 0x30 && codeUnit <= 0x39 ||
    codeUnit >= 0x41 && codeUnit <= 0x5a ||
    codeUnit >= 0x61 && codeUnit <= 0x7a ||
    codeUnit == 0x5f ||
    codeUnit == 0x2b ||
    codeUnit == 0x2e ||
    codeUnit == 0x2f ||
    codeUnit == 0x2d;

bool _isHttpUriSpanBoundary(int codeUnit) =>
    codeUnit == 0x20 ||
    codeUnit == 0x09 ||
    codeUnit == 0x0a ||
    codeUnit == 0x0d ||
    codeUnit == 0x22 ||
    codeUnit == 0x27 ||
    codeUnit == 0x28 ||
    codeUnit == 0x29 ||
    codeUnit == 0x3c ||
    codeUnit == 0x3e ||
    codeUnit == 0x7b ||
    codeUnit == 0x7d ||
    codeUnit == 0x7c ||
    codeUnit == 0x5c;

bool _isValidatedHttpUri(String candidate) {
  try {
    final uri = Uri.parse(candidate);
    final scheme = uri.scheme.toLowerCase();
    final host = uri.host;
    // Accessing port forces Uri to reject malformed explicit port text.
    final port = uri.port;
    if ((scheme != 'http' && scheme != 'https') ||
        !uri.hasAuthority ||
        host.isEmpty) {
      return false;
    }
    return port >= 0;
  } on FormatException {
    return false;
  }
}

void _walkJson(Object? value, void Function(Object? value) visit) {
  visit(value);
  if (value is Map) {
    for (final entry in value.entries) {
      _walkJson(entry.key, visit);
      _walkJson(entry.value, visit);
    }
  } else if (value is Iterable) {
    for (final element in value) {
      _walkJson(element, visit);
    }
  }
}
