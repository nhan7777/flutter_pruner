/// Strict v3 scanner-report observations for the independent accuracy oracle.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'accuracy_model.dart';
import 'oracle_project_path.dart';
import 'project_manifest.dart';

/// The validation posture for an observed scanner report.
enum ScannerReportValidation {
  /// A complete, diagnostic-free report eligible for an accepted baseline.
  accepted,

  /// A versioned capture characterization that cannot become a baseline.
  captureOnly,
}

/// Independently established upper bounds for one measured scanner inventory.
final class ScannerInventoryBound {
  /// Creates a count and byte bound that does not originate from the report.
  const ScannerInventoryBound({
    required this.maximumCount,
    required this.maximumValueBytes,
  });

  /// Maximum number of inventory entries admitted for the selected project.
  final int maximumCount;

  /// Maximum aggregate measured bytes admitted for the selected project.
  final int maximumValueBytes;
}

/// Immutable top-level run metadata emitted by the scanner.
final class ScannerRunObservation {
  ScannerRunObservation({
    required this.id,
    required this.command,
    required this.toolVersion,
    required this.status,
    required this.exitCode,
    required this.partialApplied,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.elapsedMicros,
    required this.projectRoot,
    required this.packageName,
  }) {
    if (id.isEmpty ||
        command.isEmpty ||
        toolVersion.isEmpty ||
        status.isEmpty ||
        projectRoot.isEmpty ||
        packageName.isEmpty ||
        exitCode < 0 ||
        elapsedMicros < 0) {
      throw ArgumentError('invalid scanner run observation');
    }
  }

  final String id;
  final String command;
  final String toolVersion;
  final String status;
  final int exitCode;
  final bool partialApplied;
  final String startedAtUtc;
  final String finishedAtUtc;
  final int elapsedMicros;
  final String projectRoot;
  final String packageName;
}

/// One immutable scanner diagnostic.
final class ScannerDiagnosticObservation {
  ScannerDiagnosticObservation({
    required this.code,
    required this.message,
    this.phase,
  }) {
    if (code.isEmpty || message.isEmpty) {
      throw ArgumentError('diagnostic code and message are required');
    }
  }
  final String code;
  final String message;
  final String? phase;
}

/// Exact scanner coverage facts, retained as observation rather than authority.
final class ScannerCoverageObservation {
  ScannerCoverageObservation({
    required this.analysisMode,
    required this.targetMatrixStatus,
    required this.targetMatrixComplete,
    required this.targetMatrixSource,
    required List<String> targetMatrixIssues,
    required List<OracleTarget> targets,
    required this.rootMode,
    required this.rootCoverageComplete,
    required this.internalBoundaryComplete,
    required this.externalConsumersCovered,
    required this.rootSource,
    required List<String> publicEntrypoints,
    required List<String> rootIssues,
    required this.auxiliaryExecutionTargetsPresent,
    required List<OracleAuxiliaryExecutionTarget> auxiliaryExecutionTargets,
    required this.auxiliaryExecutionTargetIssuesPresent,
    required List<String> auxiliaryExecutionTargetIssues,
  }) : targetMatrixIssues = List.unmodifiable(List.from(targetMatrixIssues)),
       targets = List.unmodifiable(List.from(targets)),
       publicEntrypoints = List.unmodifiable(List.from(publicEntrypoints)),
       rootIssues = List.unmodifiable(List.from(rootIssues)),
       auxiliaryExecutionTargets = List.unmodifiable(
         List.from(auxiliaryExecutionTargets),
       ),
       auxiliaryExecutionTargetIssues = List.unmodifiable(
         List.from(auxiliaryExecutionTargetIssues),
       );

  final String analysisMode;
  final String targetMatrixStatus;
  final bool targetMatrixComplete;
  final String targetMatrixSource;
  final List<String> targetMatrixIssues;
  final List<OracleTarget> targets;
  final String rootMode;
  final bool rootCoverageComplete;
  final bool internalBoundaryComplete;
  final bool externalConsumersCovered;
  final String rootSource;
  final List<String> publicEntrypoints;
  final List<String> rootIssues;
  final bool auxiliaryExecutionTargetsPresent;
  final List<OracleAuxiliaryExecutionTarget> auxiliaryExecutionTargets;
  final bool auxiliaryExecutionTargetIssuesPresent;
  final List<String> auxiliaryExecutionTargetIssues;
}

/// One per-context integrity aggregate from an analysis pass.
final class ScannerIntegrityCounts {
  ScannerIntegrityCounts({
    required this.id,
    required this.domain,
    required this.complete,
    required this.danglingEdges,
    required this.danglingRoots,
    required List<String> incompleteReasons,
  }) : incompleteReasons = List.unmodifiable(List.from(incompleteReasons));
  final String id;
  final String domain;
  final bool complete;
  final int danglingEdges;
  final int danglingRoots;
  final List<String> incompleteReasons;
}

/// One adapter execution emitted in an analysis pass.
final class ScannerAdapterExecution {
  ScannerAdapterExecution({
    required this.id,
    required this.name,
    required this.role,
    required this.status,
    required this.elapsedMicros,
    required this.nodesAdded,
    required this.edgesAdded,
    required this.blockersAdded,
    this.reason,
  }) {
    if (id.isEmpty ||
        name.isEmpty ||
        role.isEmpty ||
        status.isEmpty ||
        elapsedMicros < 0 ||
        nodesAdded < 0 ||
        edgesAdded < 0 ||
        blockersAdded < 0) {
      throw ArgumentError('invalid adapter execution');
    }
  }
  final String id;
  final String name;
  final String role;
  final String status;
  final int elapsedMicros;
  final int nodesAdded;
  final int edgesAdded;
  final int blockersAdded;
  final String? reason;
}

/// One immutable scanner analysis pass.
final class ScannerAnalysisPass {
  ScannerAnalysisPass({
    required this.id,
    required this.purpose,
    required this.round,
    required this.elapsedMicros,
    required this.nodeCount,
    required this.edgeCount,
    required this.rootCount,
    required this.blockersRecorded,
    required this.danglingEdges,
    required this.danglingRoots,
    required List<ScannerAdapterExecution> adapters,
    required Map<String, ScannerIntegrityCounts> integrityByExecutionTarget,
    required this.integrityByExecutionTargetPresent,
    required Map<String, Object?> findings,
  }) : adapters = List.unmodifiable(List.from(adapters)),
       integrityByExecutionTarget = Map.unmodifiable(
         Map.from(integrityByExecutionTarget),
       ),
       findings = _freezeJsonMap(findings);

  final String id;
  final String purpose;
  final int? round;
  final int elapsedMicros;
  final int nodeCount;
  final int edgeCount;
  final int rootCount;
  final int blockersRecorded;
  final int danglingEdges;
  final int danglingRoots;
  final List<ScannerAdapterExecution> adapters;
  final Map<String, ScannerIntegrityCounts> integrityByExecutionTarget;
  final bool integrityByExecutionTargetPresent;
  final Map<String, Object?> findings;
}

/// One scanner blocker with provenance and affected node identities.
final class ScannerBlockerObservation {
  ScannerBlockerObservation({
    required this.id,
    required this.producer,
    required this.reason,
    this.location,
    this.sourceNodeId,
    this.affectedNamespace,
    required List<String> affectedNodeIds,
  }) : affectedNodeIds = List.unmodifiable(List.from(affectedNodeIds));
  final String id;
  final String producer;
  final String reason;
  final String? location;
  final String? sourceNodeId;
  final String? affectedNamespace;
  final List<String> affectedNodeIds;
}

/// Scanner-supplied evidence; never scanner-supplied oracle evidence.
final class ScannerFindingEvidence {
  ScannerFindingEvidence({
    required this.kind,
    required this.producer,
    required this.description,
    required this.exact,
    this.location,
  });
  final String kind;
  final String producer;
  final String description;
  final bool exact;
  final String? location;
}

/// One parsed scanner finding with a reconstructed, exact candidate key.
final class ScannerFindingObservation {
  ScannerFindingObservation({
    required this.candidateKey,
    required this.ruleId,
    required this.reportingAdapterId,
    required this.confidence,
    required this.title,
    required this.nodeKind,
    required this.displayName,
    required this.origin,
    required this.projectRelativeOrigin,
    required Map<String, bool> predicates,
    required List<String> classificationReasons,
    required List<String> manualRiskCodes,
    required this.applyEligible,
    required List<String> unreachableIn,
    required List<String> reachableIn,
    required List<String> protectionReasons,
    required List<String> blockerIds,
    required List<ScannerFindingEvidence> evidence,
    this.proposedAction,
    required List<Object?> measurements,
    required Map<String, Object?> details,
    this.whyNotSafe,
    required this.retainedInPresent,
    required List<String> retainedIn,
    required this.auxiliaryRetainedInPresent,
    required List<String> auxiliaryRetainedIn,
  }) : predicates = Map.unmodifiable(Map.from(predicates)),
       classificationReasons = List.unmodifiable(
         List.from(classificationReasons),
       ),
       manualRiskCodes = List.unmodifiable(List.from(manualRiskCodes)),
       unreachableIn = List.unmodifiable(List.from(unreachableIn)),
       reachableIn = List.unmodifiable(List.from(reachableIn)),
       protectionReasons = List.unmodifiable(List.from(protectionReasons)),
       blockerIds = List.unmodifiable(List.from(blockerIds)),
       evidence = List.unmodifiable(List.from(evidence)),
       measurements = List.unmodifiable(measurements.map(_freezeJson).toList()),
       details = _freezeJsonMap(details),
       retainedIn = List.unmodifiable(List.from(retainedIn)),
       auxiliaryRetainedIn = List.unmodifiable(List.from(auxiliaryRetainedIn));

  final CandidateKey candidateKey;
  final String ruleId;
  final String reportingAdapterId;
  final String confidence;
  final String title;
  final String nodeKind;
  final String? displayName;
  final String origin;
  final String projectRelativeOrigin;
  final Map<String, bool> predicates;
  final List<String> classificationReasons;
  final List<String> manualRiskCodes;
  final bool applyEligible;
  final List<String> unreachableIn;
  final List<String> reachableIn;
  final List<String> protectionReasons;
  final List<String> blockerIds;
  final List<ScannerFindingEvidence> evidence;
  final String? proposedAction;
  final List<Object?> measurements;
  final Map<String, Object?> details;
  final String? whyNotSafe;
  final bool retainedInPresent;
  final List<String> retainedIn;
  final bool auxiliaryRetainedInPresent;
  final List<String> auxiliaryRetainedIn;
}

/// Strict v3 scanner report. It is an observation, never independent truth.
final class ScannerReport {
  factory ScannerReport.fromJson(Map<String, Object?> json) =>
      _ScannerReportReader(json).parse();

  factory ScannerReport.fromUtf8(List<int> bytes) {
    final decoded = jsonDecode(utf8.decode(bytes));
    return _ScannerReportReader(
      _asMap(decoded, 'scanner report'),
      rawSha256: sha256.convert(bytes).toString(),
    ).parse();
  }

  ScannerReport._({
    required this.version,
    required this.run,
    required this.coverage,
    required List<String> requestedAdapters,
    required List<ScannerAnalysisPass> analysisPasses,
    required Map<String, ScannerBlockerObservation> blockers,
    required List<ScannerDiagnosticObservation> diagnostics,
    required List<ScannerFindingObservation> findings,
    required this.presentation,
    required this.statistics,
    required this.verificationAttempts,
    this.rawSha256,
  }) : requestedAdapters = List.unmodifiable(List.from(requestedAdapters)),
       analysisPasses = List.unmodifiable(List.from(analysisPasses)),
       blockers = Map.unmodifiable(Map.from(blockers)),
       diagnostics = List.unmodifiable(List.from(diagnostics)),
       findings = List.unmodifiable(List.from(findings));

  final int version;
  final ScannerRunObservation run;
  final ScannerCoverageObservation coverage;
  final List<String> requestedAdapters;
  final List<ScannerAnalysisPass> analysisPasses;
  final Map<String, ScannerBlockerObservation> blockers;
  final List<ScannerDiagnosticObservation> diagnostics;
  final List<ScannerFindingObservation> findings;
  final Map<String, Object?> presentation;
  final Map<String, Object?> statistics;
  final List<Object?> verificationAttempts;
  final String? rawSha256;

  /// Binds the report to exactly one frozen scan and validation posture.
  void validateForArtifact({
    required AccuracyProjectManifest manifest,
    required String scanKey,
    required String expectedPackageName,
    required ScannerReportValidation validation,
    Map<String, ScannerInventoryBound> independentInventoryBounds = const {},
  }) {
    final scan = manifest.scans[scanKey];
    if (scan == null) throw FormatException('unknown frozen scan $scanKey');
    if (version != 3 ||
        scan.jsonSchemaVersion != 3 ||
        run.projectRoot != manifest.projectRoot ||
        run.packageName != expectedPackageName) {
      throw const FormatException(
        'report does not match selected project identity',
      );
    }
    final expectedMode = switch (validation) {
      ScannerReportValidation.accepted => 'accepted',
      ScannerReportValidation.captureOnly => 'capture-only',
    };
    if (manifest.manifestValidationMode != expectedMode) {
      throw const FormatException(
        'caller validation mode differs from manifest',
      );
    }
    if (run.command != 'scan' ||
        run.status != 'completed' ||
        run.exitCode != 0 ||
        run.partialApplied) {
      throw const FormatException(
        'accepted scanner run must be a completed non-mutating scan',
      );
    }
    if (rawSha256 == null || rawSha256 != scan.rawReportSha256) {
      throw const FormatException(
        'report SHA-256 differs from frozen artifact',
      );
    }
    if (!_sameStrings(requestedAdapters, scan.requestedAdapters) ||
        !_sameTargets(coverage.targets, manifest.targets) ||
        (coverage.auxiliaryExecutionTargetsPresent &&
            !_sameAuxiliaries(
              coverage.auxiliaryExecutionTargets,
              scan.expectedAuxiliaryExecutionTargets,
            ))) {
      throw const FormatException(
        'report scan inventory differs from selected artifact',
      );
    }
    if (findings.any(
      (finding) => !scan.requestedAdapters.contains(finding.reportingAdapterId),
    )) {
      throw const FormatException(
        'finding reporting adapter was not selected for this scan',
      );
    }
    _validateCoverage(
      coverage,
      manifest.expectedCoverage,
      requireAdditivePresence: validation == ScannerReportValidation.accepted,
    );
    final expectedContexts = <String>{
      ...manifest.targets.map((target) => target.executionContextId),
      ...scan.expectedAuxiliaryExecutionTargets.map(
        (target) => target.executionContextId,
      ),
      'unattributed',
    };
    final expectedDomains = <String, String>{
      for (final target in manifest.targets)
        target.executionContextId: 'configuredTarget',
      for (final target in scan.expectedAuxiliaryExecutionTargets)
        target.executionContextId: 'auxiliary',
      'unattributed': 'unattributed',
    };
    for (final pass in analysisPasses) {
      if (validation == ScannerReportValidation.accepted) {
        if (!pass.integrityByExecutionTargetPresent ||
            pass.danglingEdges != 0 ||
            pass.danglingRoots != 0 ||
            pass.integrityByExecutionTarget.keys.toSet().length !=
                expectedContexts.length ||
            !pass.integrityByExecutionTarget.keys.toSet().containsAll(
              expectedContexts,
            ) ||
            pass.integrityByExecutionTarget.entries.any(
              (entry) =>
                  entry.value.id != entry.key ||
                  entry.value.domain != expectedDomains[entry.key] ||
                  !entry.value.complete ||
                  entry.value.danglingEdges != 0 ||
                  entry.value.danglingRoots != 0 ||
                  entry.value.incompleteReasons.isNotEmpty,
            )) {
          throw const FormatException(
            'accepted report has incomplete or nonzero integrity',
          );
        }
      }
    }
    if (validation == ScannerReportValidation.accepted) {
      if (analysisPasses.length != 1 ||
          analysisPasses.single.id != 'analysis-001' ||
          analysisPasses.single.purpose != 'initial' ||
          analysisPasses.single.round != null) {
        throw const FormatException(
          'accepted report requires exactly the initial analysis pass',
        );
      }
      _validateAcceptedAdapterExecutions(
        analysisPasses.single.adapters,
        selected: requestedAdapters,
        findings: findings,
      );
      _validateIndependentInventoryBounds(
        selectedAdapters: requestedAdapters,
        statistics: statistics,
        bounds: independentInventoryBounds,
      );
      if (!coverage.auxiliaryExecutionTargetsPresent ||
          !coverage.auxiliaryExecutionTargetIssuesPresent ||
          diagnostics.isNotEmpty ||
          findings.any(
            (finding) =>
                !finding.retainedInPresent ||
                !finding.auxiliaryRetainedInPresent,
          )) {
        throw const FormatException(
          'accepted report omits required additive safety facts',
        );
      }
      return;
    }
    _validateCaptureAllowance(manifest, scanKey);
  }

  void _validateCaptureAllowance(
    AccuracyProjectManifest manifest,
    String scanKey,
  ) {
    final allowance = manifest.analysisHealthAllowance;
    if (allowance == null) {
      throw const FormatException(
        'capture-only report requires frozen health allowance',
      );
    }
    final diagnosticCounts = <String, int>{};
    for (final diagnostic in diagnostics) {
      final phase = diagnostic.phase;
      if (phase == null) {
        throw const FormatException('capture-only diagnostic requires a phase');
      }
      diagnosticCounts.update(
        '$scanKey|${diagnostic.code}|$phase',
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final expectedDiagnostics = Map<String, int>.fromEntries(
      allowance.diagnosticCountsByCodePhase.entries.where(
        (entry) => entry.key.startsWith('$scanKey|'),
      ),
    );
    if (diagnosticCounts.length != expectedDiagnostics.length ||
        !diagnosticCounts.entries.every(
          (entry) => expectedDiagnostics[entry.key] == entry.value,
        )) {
      throw const FormatException(
        'capture-only diagnostics differ from allowance',
      );
    }
    final expectedPasses = Map<String, ({int edges, int roots})>.fromEntries(
      allowance.danglingCountsByPassId.entries.where(
        (entry) => entry.key.startsWith('$scanKey|'),
      ),
    );
    final actualPasses = <String, ({int edges, int roots})>{
      for (final pass in analysisPasses)
        '$scanKey|${pass.id}': (
          edges: pass.danglingEdges,
          roots: pass.danglingRoots,
        ),
    };
    if (actualPasses.length != expectedPasses.length ||
        !actualPasses.entries.every(
          (entry) => expectedPasses[entry.key] == entry.value,
        )) {
      throw const FormatException(
        'capture-only integrity aggregates differ from allowance',
      );
    }
    for (final pass in analysisPasses) {
      final key = '$scanKey|${pass.id}';
      final expectsAbsent = allowance.passIdsWithIntegrityMapAbsent.contains(
        key,
      );
      if (!pass.integrityByExecutionTargetPresent) {
        if (!expectsAbsent) {
          throw const FormatException(
            'capture-only integrity map is absent without an exact allowance',
          );
        }
        continue;
      }
      if (expectsAbsent) {
        throw const FormatException(
          'capture-only integrity map is present against its exact allowance',
        );
      }
      final expectedContexts =
          allowance.danglingCountsByPassAndExecutionTargetId[key];
      if (expectedContexts == null ||
          pass.integrityByExecutionTarget.length != expectedContexts.length ||
          !pass.integrityByExecutionTarget.entries.every((entry) {
            final expected = expectedContexts[entry.key];
            return expected != null &&
                expected.edges == entry.value.danglingEdges &&
                expected.roots == entry.value.danglingRoots;
          })) {
        throw const FormatException(
          'capture-only integrity contexts differ from allowance',
        );
      }
    }
  }
}

void _validateIndependentInventoryBounds({
  required List<String> selectedAdapters,
  required Map<String, Object?> statistics,
  required Map<String, ScannerInventoryBound> bounds,
}) {
  const measuredAdapters = <String>{'assets', 'duplicates'};
  if (bounds.keys.any((adapter) => !measuredAdapters.contains(adapter)) ||
      bounds.values.any(
        (bound) => bound.maximumCount < 0 || bound.maximumValueBytes < 0,
      )) {
    throw const FormatException('invalid independent inventory bound');
  }
  final expected = selectedAdapters.where(measuredAdapters.contains).toSet();
  if (!bounds.keys.toSet().containsAll(expected)) {
    throw const FormatException(
      'accepted asset/duplicate scan requires independent inventory bounds',
    );
  }
  if (expected.isEmpty) return;

  final measurements = (statistics['measurements']! as List<Object?>)
      .cast<Map<String, Object?>>();
  for (final adapter in expected) {
    final measurement = measurements.singleWhere(
      (measurement) => measurement['adapterId'] == adapter,
    );
    final bound = bounds[adapter]!;
    final knownCount = measurement['knownCount'];
    final unknownCount = measurement['unknownCount'];
    final value = measurement['value'];
    if (measurement['status'] != 'measured' ||
        knownCount is! int ||
        unknownCount is! int ||
        value is! int ||
        unknownCount != 0 ||
        knownCount > bound.maximumCount ||
        value > bound.maximumValueBytes) {
      throw FormatException(
        '$adapter inventory exceeds independently established bounds',
      );
    }
  }
}

final class _ScannerReportReader {
  _ScannerReportReader(this.value, {this.rawSha256});
  final Map<String, Object?> value;
  final String? rawSha256;

  ScannerReport parse() {
    final reader = _Reader(value, 'scanner report');
    if (reader.integer('version') != 3) {
      throw const FormatException('only scanner report schema v3 is accepted');
    }
    final run = _run(reader.map('run'));
    final coverage = _coverage(reader.map('analysisCoverage'));
    final presentation = _freezeJsonMap(reader.map('presentation'));
    final execution = _Reader(reader.map('execution'), 'execution');
    final requestedAdapters = execution.strings('requestedAdapters');
    _unique(requestedAdapters, 'requested adapter');
    if (requestedAdapters.isEmpty ||
        requestedAdapters.any((value) => !_adapterIds.contains(value))) {
      throw const FormatException(
        'unknown or empty requested adapter inventory',
      );
    }
    final passes = execution
        .list('analysisPasses')
        .map(_pass)
        .toList(growable: false);
    _unique(passes.map((pass) => pass.id), 'analysis pass ID');
    execution.finish();
    final statistics = _freezeJsonMap(reader.map('statistics'));
    final blockers = _blockers(reader.map('blockers'));
    final diagnostics = reader
        .list('diagnostics')
        .map(_diagnostic)
        .toList(growable: false);
    final verification = List<Object?>.unmodifiable(
      reader.list('verificationAttempts').map(_freezeJson),
    );
    final findings = reader
        .list('findings')
        .map((value) => _finding(value, packageName: run.packageName))
        .toList(growable: false);
    _unique(
      findings.map(
        (finding) =>
            '${finding.candidateKey.canonicalId}\u0000${finding.reportingAdapterId}\u0000${finding.ruleId}',
      ),
      'finding identity',
    );
    for (final finding in findings) {
      if (!blockers.keys.toSet().containsAll(finding.blockerIds)) {
        throw const FormatException('finding references unknown blocker');
      }
    }
    _validateReportStatistics(
      statistics,
      findings,
      blockers: blockers,
      pass: passes.isEmpty ? null : passes.last,
      reportingAdapterIds: passes.isEmpty
          ? const <String>[]
          : passes.last.adapters
                .where((adapter) => adapter.role == 'reporting')
                .map((adapter) => adapter.id)
                .toList(growable: false),
    );
    for (final pass in passes) {
      _validateFindingStatistics(
        pass.findings,
        findings,
        reportingAdapterIds: pass.adapters
            .where((adapter) => adapter.role == 'reporting')
            .map((adapter) => adapter.id)
            .toList(growable: false),
      );
    }
    reader.finish();
    return ScannerReport._(
      version: 3,
      run: run,
      coverage: coverage,
      requestedAdapters: requestedAdapters,
      analysisPasses: passes,
      blockers: blockers,
      diagnostics: diagnostics,
      findings: findings,
      presentation: presentation,
      statistics: statistics,
      verificationAttempts: verification,
      rawSha256: rawSha256,
    );
  }
}

ScannerRunObservation _run(Map<String, Object?> value) {
  final reader = _Reader(value, 'run');
  final result = ScannerRunObservation(
    id: reader.string('id'),
    command: reader.string('command'),
    toolVersion: reader.string('toolVersion'),
    status: reader.string('status'),
    exitCode: reader.nonNegative('exitCode'),
    partialApplied: reader.boolean('partialApplied'),
    startedAtUtc: reader.string('startedAtUtc'),
    finishedAtUtc: reader.string('finishedAtUtc'),
    elapsedMicros: reader.nonNegative('elapsedMicros'),
    projectRoot: reader.string('projectRoot'),
    packageName: reader.string('packageName'),
  );
  reader.finish();
  return result;
}

ScannerCoverageObservation _coverage(Map<String, Object?> value) {
  final reader = _Reader(value, 'analysisCoverage');
  final matrix = _Reader(
    reader.map('targetMatrix'),
    'analysisCoverage.targetMatrix',
  );
  final roots = _Reader(reader.map('roots'), 'analysisCoverage.roots');
  final targets = matrix
      .list('targets')
      .map((value) => _target(value, 'coverage target'))
      .toList(growable: false);
  _unique(
    targets.map((target) => target.executionContextId),
    'coverage execution context',
  );
  final auxiliaryPresent = reader.present('auxiliaryExecutionTargets');
  final auxiliary = auxiliaryPresent
      ? reader
            .list('auxiliaryExecutionTargets')
            .map((value) => _auxiliary(value, targets))
            .toList(growable: false)
      : const <OracleAuxiliaryExecutionTarget>[];
  _unique(auxiliary.map((target) => target.id), 'coverage auxiliary target');
  final issuesPresent = reader.present('auxiliaryExecutionTargetIssues');
  final auxiliaryIssues = issuesPresent
      ? reader.strings('auxiliaryExecutionTargetIssues')
      : const <String>[];
  final publicEntrypoints = roots.strings('publicEntrypoints');
  if (publicEntrypoints.any(
    (path) => !isCanonicalProjectRelativePosixPath(path),
  )) {
    throw const FormatException('public entrypoint is not canonical');
  }
  final result = ScannerCoverageObservation(
    analysisMode: reader.string('analysisMode'),
    targetMatrixStatus: matrix.string('status'),
    targetMatrixComplete: matrix.boolean('complete'),
    targetMatrixSource: matrix.string('source'),
    targetMatrixIssues: matrix.strings('issues'),
    targets: targets,
    rootMode: roots.string('mode'),
    rootCoverageComplete: roots.boolean('complete'),
    internalBoundaryComplete: roots.boolean('internalBoundaryComplete'),
    externalConsumersCovered: roots.boolean('externalConsumersCovered'),
    rootSource: roots.string('source'),
    publicEntrypoints: publicEntrypoints,
    rootIssues: roots.strings('issues'),
    auxiliaryExecutionTargetsPresent: auxiliaryPresent,
    auxiliaryExecutionTargets: auxiliary,
    auxiliaryExecutionTargetIssuesPresent: issuesPresent,
    auxiliaryExecutionTargetIssues: auxiliaryIssues,
  );
  matrix.finish();
  roots.finish();
  reader.finish();
  return result;
}

ScannerAnalysisPass _pass(Object? value) {
  final reader = _Reader(_asMap(value, 'analysis pass'), 'analysis pass');
  final graph = _Reader(reader.map('graph'), 'analysis pass.graph');
  final present = graph.present('integrityByExecutionTarget');
  final integrity = <String, ScannerIntegrityCounts>{};
  if (present) {
    for (final entry in graph.map('integrityByExecutionTarget').entries) {
      if (!_context(entry.key)) {
        throw FormatException('noncanonical integrity context ${entry.key}');
      }
      final counts = _Reader(
        _asMap(entry.value, 'integrity count'),
        'integrity count',
      );
      final id = counts.string('id');
      final domain = counts.string('domain');
      final complete = counts.boolean('complete');
      final danglingEdges = counts.nonNegative('danglingEdges');
      final danglingRoots = counts.nonNegative('danglingRoots');
      final incompleteReasons = counts.strings('incompleteReasons');
      counts.finish();
      if (id != entry.key || domain != _integrityDomain(entry.key)) {
        throw FormatException('invalid integrity identity for ${entry.key}');
      }
      final sortedReasons = List<String>.from(incompleteReasons)..sort();
      if (incompleteReasons.toSet().length != incompleteReasons.length ||
          incompleteReasons.join('\u0000') != sortedReasons.join('\u0000') ||
          incompleteReasons.any(
            (reason) =>
                reason.isEmpty || _sanitizeIntegrityReason(reason) != reason,
          )) {
        throw FormatException('invalid incomplete reasons for ${entry.key}');
      }
      final expectedComplete =
          danglingEdges == 0 && danglingRoots == 0 && incompleteReasons.isEmpty;
      if (complete != expectedComplete) {
        throw FormatException(
          'inconsistent integrity completeness for ${entry.key}',
        );
      }
      integrity[entry.key] = ScannerIntegrityCounts(
        id: id,
        domain: domain,
        complete: complete,
        danglingEdges: danglingEdges,
        danglingRoots: danglingRoots,
        incompleteReasons: incompleteReasons,
      );
    }
  }
  final adapters = reader
      .list('adapters')
      .map((value) {
        final item = _Reader(
          _asMap(value, 'adapter execution'),
          'adapter execution',
        );
        final contributions = _Reader(
          item.map('contributions'),
          'adapter contributions',
        );
        final result = ScannerAdapterExecution(
          id: item.string('id'),
          name: item.string('name'),
          role: item.string('role'),
          status: item.string('status'),
          elapsedMicros: item.nonNegative('elapsedMicros'),
          nodesAdded: contributions.nonNegative('nodes'),
          edgesAdded: contributions.nonNegative('edges'),
          blockersAdded: contributions.nonNegative('blockers'),
          reason: item.optionalString('reason'),
        );
        contributions.finish();
        item.finish();
        return result;
      })
      .toList(growable: false);
  _unique(adapters.map((adapter) => adapter.id), 'adapter execution');
  final round = reader.optional('round');
  if (round != null && (round is! int || round < 0)) {
    throw const FormatException('analysis pass round must be non-negative int');
  }
  final danglingEdges = graph.nonNegative('danglingEdges');
  final danglingRoots = graph.nonNegative('danglingRoots');
  if (present &&
      (!_withinDeduplicatedUnionBounds(
            danglingEdges,
            unattributed: integrity['unattributed']?.danglingEdges ?? 0,
            attributed: integrity.entries
                .where((entry) => entry.key != 'unattributed')
                .map((entry) => entry.value.danglingEdges),
          ) ||
          !_withinDeduplicatedUnionBounds(
            danglingRoots,
            unattributed: integrity['unattributed']?.danglingRoots ?? 0,
            attributed: integrity.entries
                .where((entry) => entry.key != 'unattributed')
                .map((entry) => entry.value.danglingRoots),
          ))) {
    throw const FormatException(
      'integrity counts disagree with graph aggregate',
    );
  }
  final result = ScannerAnalysisPass(
    id: reader.string('id'),
    purpose: reader.string('purpose'),
    round: round as int?,
    elapsedMicros: reader.nonNegative('elapsedMicros'),
    nodeCount: graph.nonNegative('nodes'),
    edgeCount: graph.nonNegative('edges'),
    rootCount: graph.nonNegative('roots'),
    blockersRecorded: graph.nonNegative('blockersRecorded'),
    danglingEdges: danglingEdges,
    danglingRoots: danglingRoots,
    adapters: adapters,
    integrityByExecutionTarget: integrity,
    integrityByExecutionTargetPresent: present,
    findings: reader.map('findings'),
  );
  graph.finish();
  reader.finish();
  return result;
}

Map<String, ScannerBlockerObservation> _blockers(Map<String, Object?> value) {
  final result = <String, ScannerBlockerObservation>{};
  for (final entry in value.entries) {
    if (entry.key.isEmpty) throw const FormatException('empty blocker ID');
    final reader = _Reader(_asMap(entry.value, 'blocker'), 'blocker');
    final affected = reader.present('affectedNodeIds')
        ? reader.strings('affectedNodeIds')
        : const <String>[];
    _unique(affected, 'affected blocker node');
    final location = reader.optionalString('location');
    if (location != null &&
        !isCanonicalProjectRelativePosixLocation(location)) {
      throw const FormatException('blocker location is not canonical');
    }
    result[entry.key] = ScannerBlockerObservation(
      id: entry.key,
      producer: reader.string('producer'),
      reason: reader.string('reason'),
      location: location,
      sourceNodeId: reader.optionalString('sourceNodeId'),
      affectedNamespace: reader.optionalString('affectedNamespace'),
      affectedNodeIds: affected,
    );
    reader.finish();
  }
  return Map.unmodifiable(result);
}

ScannerDiagnosticObservation _diagnostic(Object? value) {
  final reader = _Reader(_asMap(value, 'diagnostic'), 'diagnostic');
  final result = ScannerDiagnosticObservation(
    code: reader.string('code'),
    message: reader.string('message'),
    phase: reader.optionalString('phase'),
  );
  reader.finish();
  return result;
}

ScannerFindingObservation _finding(
  Object? value, {
  required String packageName,
}) {
  final reader = _Reader(_asMap(value, 'finding'), 'finding');
  final node = _Reader(reader.map('node'), 'finding.node');
  final kind = _candidateKind(node.string('kind'));
  final nodeId = node.string('id');
  final key = CandidateKey(kind: kind, canonicalId: nodeId);
  final adapter = reader.string('reportingAdapterId');
  final rule = reader.string('ruleId');
  final expected = _ruleIdentity[kind]!;
  if (adapter != expected.adapter || rule != expected.rule) {
    throw const FormatException(
      'finding adapter/rule does not match exact candidate kind',
    );
  }
  final confidence = reader.string('confidence');
  if (!_tiers.contains(confidence)) {
    throw const FormatException('unknown confidence tier');
  }
  final predicates = <String, bool>{};
  final predicateReader = _Reader(
    reader.map('predicates'),
    'finding.predicates',
  );
  for (final name in _predicateNames) {
    predicates[name] = predicateReader.boolean(name);
  }
  predicateReader.finish();
  final action = reader.optionalString('proposedAction');
  if (_fixedReviewKinds.contains(kind) &&
      (confidence != 'REVIEW' ||
          reader.boolean('applyEligible') ||
          action != null)) {
    throw const FormatException('fixed review finding is not review-only');
  }
  final evidence = reader.present('evidence')
      ? reader
            .list('evidence')
            .map((value) {
              final item = _Reader(
                _asMap(value, 'finding evidence'),
                'finding evidence',
              );
              final location = item.optionalString('location');
              if (location != null &&
                  !isCanonicalProjectRelativePosixLocation(location)) {
                throw const FormatException(
                  'finding evidence location is not canonical',
                );
              }
              final result = ScannerFindingEvidence(
                kind: item.string('kind'),
                producer: item.string('producer'),
                description: item.string('description'),
                exact: item.boolean('exact'),
                location: location,
              );
              item.finish();
              return result;
            })
            .toList(growable: false)
      : const <ScannerFindingEvidence>[];
  final retainedPresent = reader.present('retainedIn');
  final retained = retainedPresent
      ? reader.strings('retainedIn')
      : const <String>[];
  final auxiliaryPresent = reader.present('auxiliaryRetainedIn');
  final auxiliary = auxiliaryPresent
      ? reader.strings('auxiliaryRetainedIn')
      : const <String>[];
  final measurements = reader.list('measurements');
  final expectedMeasurement = _measurementByKind[kind]!;
  if (measurements.length != 1) {
    throw const FormatException('every v3 finding has exactly one measurement');
  }
  for (final measurement in measurements) {
    _validateMeasurement(measurement, expected: expectedMeasurement);
  }
  final details = reader.present('details')
      ? reader.map('details')
      : const <String, Object?>{};
  _validateDetails(kind, details);
  final projectRelativeOrigin = node.string('projectRelativeOrigin');
  if (!isCanonicalProjectRelativePosixPath(projectRelativeOrigin)) {
    throw const FormatException('finding origin is not canonical');
  }
  _validateFindingDomainSemantics(
    kind,
    nodeId,
    details,
    measurements,
    packageName: packageName,
    projectRelativeOrigin: projectRelativeOrigin,
  );
  _validateCandidatePathIdentity(
    kind,
    nodeId,
    projectRelativeOrigin,
    details,
    packageName: packageName,
  );
  final result = ScannerFindingObservation(
    candidateKey: key,
    ruleId: rule,
    reportingAdapterId: adapter,
    confidence: confidence,
    title: reader.string('title'),
    nodeKind: node.string('kind'),
    displayName: node.optionalString('displayName'),
    origin: node.string('origin'),
    projectRelativeOrigin: projectRelativeOrigin,
    predicates: predicates,
    classificationReasons: reader.strings('classificationReasons'),
    manualRiskCodes: reader.strings('manualRiskCodes'),
    applyEligible: reader.boolean('applyEligible'),
    unreachableIn: reader.strings('unreachableIn'),
    reachableIn: reader.strings('reachableIn'),
    protectionReasons: reader.present('protectionReasons')
        ? reader.strings('protectionReasons')
        : const <String>[],
    blockerIds: reader.present('blockerIds')
        ? reader.strings('blockerIds')
        : const <String>[],
    evidence: evidence,
    proposedAction: action,
    measurements: measurements,
    details: details,
    whyNotSafe: reader.optionalString('whyNotSafe'),
    retainedInPresent: retainedPresent,
    retainedIn: retained,
    auxiliaryRetainedInPresent: auxiliaryPresent,
    auxiliaryRetainedIn: auxiliary,
  );
  node.finish();
  reader.finish();
  return result;
}

void _validateCoverage(
  ScannerCoverageObservation report,
  ExpectedAnalysisCoverage expected, {
  required bool requireAdditivePresence,
}) {
  if (report.analysisMode != expected.analysisMode ||
      report.targetMatrixStatus != expected.targetMatrixStatus ||
      report.targetMatrixComplete != expected.targetMatrixComplete ||
      report.targetMatrixSource != expected.targetMatrixSource ||
      !_sameStrings(report.targetMatrixIssues, expected.targetMatrixIssues) ||
      report.rootMode != expected.rootMode ||
      report.rootCoverageComplete != expected.rootCoverageComplete ||
      report.internalBoundaryComplete != expected.internalBoundaryComplete ||
      report.externalConsumersCovered != expected.externalConsumersCovered ||
      report.rootSource != expected.rootSource ||
      !_sameStrings(report.publicEntrypoints, expected.publicEntrypoints) ||
      !_sameStrings(report.rootIssues, expected.rootIssues) ||
      (requireAdditivePresence &&
          (!report.auxiliaryExecutionTargetsPresent ||
              !report.auxiliaryExecutionTargetIssuesPresent)) ||
      (report.auxiliaryExecutionTargetIssuesPresent &&
          (report.auxiliaryExecutionTargetIssuesPresent !=
                  expected.auxiliaryExecutionTargetIssuesPresent ||
              !_sameStrings(
                report.auxiliaryExecutionTargetIssues,
                expected.auxiliaryExecutionTargetIssues
                    .map((value) => value.id)
                    .toList(),
              )))) {
    throw const FormatException('report coverage differs from frozen manifest');
  }
}

const _adapterIds = <String>{
  'assets',
  'dart',
  'duplicates',
  'get_it',
  'go_router',
  'l10n',
};

const _allowedSupportAdapters = <String, Set<String>>{
  'assets': {'dart'},
  'dart': {},
  'duplicates': {},
  'get_it': {'dart'},
  'go_router': {'dart'},
  'l10n': {'dart'},
};

void _validateAcceptedAdapterExecutions(
  List<ScannerAdapterExecution> adapters, {
  required List<String> selected,
  required List<ScannerFindingObservation> findings,
}) {
  final allowedSupport = <String>{
    for (final adapter in selected) ..._allowedSupportAdapters[adapter]!,
  }..removeAll(selected);
  final reporting = <String, ScannerAdapterExecution>{};
  final support = <String, ScannerAdapterExecution>{};
  for (final adapter in adapters) {
    if (!_adapterIds.contains(adapter.id) || adapter.status == 'failed') {
      throw const FormatException(
        'accepted report has failed or unknown adapter',
      );
    }
    final validTerminal =
        adapter.status == 'executed' ||
        (adapter.status == 'notApplicable' &&
            adapter.reason != null &&
            adapter.reason!.isNotEmpty &&
            adapter.nodesAdded == 0 &&
            adapter.edgesAdded == 0 &&
            adapter.blockersAdded == 0);
    if (!validTerminal) {
      throw const FormatException(
        'adapter execution has invalid terminal state',
      );
    }
    switch (adapter.role) {
      case 'reporting':
        if (!selected.contains(adapter.id) ||
            reporting.containsKey(adapter.id)) {
          throw const FormatException(
            'reporting adapter is not selected exactly once',
          );
        }
        reporting[adapter.id] = adapter;
        break;
      case 'support':
        if (!allowedSupport.contains(adapter.id) ||
            support.containsKey(adapter.id)) {
          throw const FormatException(
            'support adapter is not a frozen dependency',
          );
        }
        support[adapter.id] = adapter;
        break;
      default:
        throw const FormatException(
          'accepted report has an unknown adapter role',
        );
    }
  }
  if (reporting.length != selected.length ||
      !reporting.keys.toSet().containsAll(selected)) {
    throw const FormatException(
      'accepted report has incomplete reporting adapter executions',
    );
  }
  if (support.length != allowedSupport.length ||
      !support.keys.toSet().containsAll(allowedSupport)) {
    throw const FormatException('support dependency executions are incomplete');
  }
  for (final finding in findings) {
    final execution = reporting[finding.reportingAdapterId];
    if (execution == null || execution.status != 'executed') {
      throw const FormatException(
        'notApplicable adapter execution cannot own a finding',
      );
    }
  }
}

const _tiers = <String>{'PROTECTED', 'REVIEW', 'HIGH', 'SAFE'};
const _predicateNames = <String>{
  'ruleAllowsAutoFix',
  'unreachableAcrossAllTargets',
  'notRetained',
  'noDynamicBlockers',
  'notProtected',
  'noPublicApiRisk',
  'hasDeterministicInverse',
  'analysisCoverageComplete',
  'actionSupported',
};
const _fixedReviewKinds = <OracleCandidateKind>{
  OracleCandidateKind.analyzerDiagnostic,
  OracleCandidateKind.duplicateGroup,
  OracleCandidateKind.getItRegistration,
  OracleCandidateKind.route,
  OracleCandidateKind.localizationKey,
};
const _ruleIdentity = <OracleCandidateKind, ({String adapter, String rule})>{
  OracleCandidateKind.dartDeclaration: (adapter: 'dart', rule: 'PRN-DART-001'),
  OracleCandidateKind.dartLibrary: (adapter: 'dart', rule: 'PRN-DART-002'),
  OracleCandidateKind.analyzerDiagnostic: (
    adapter: 'dart',
    rule: 'PRN-DART-003',
  ),
  OracleCandidateKind.asset: (adapter: 'assets', rule: 'PRN-ASSET-001'),
  OracleCandidateKind.duplicateGroup: (
    adapter: 'duplicates',
    rule: 'PRN-DUP-001',
  ),
  OracleCandidateKind.getItRegistration: (
    adapter: 'get_it',
    rule: 'PRN-DI-001',
  ),
  OracleCandidateKind.route: (adapter: 'go_router', rule: 'PRN-ROUTE-001'),
  OracleCandidateKind.localizationKey: (adapter: 'l10n', rule: 'PRN-L10N-001'),
};

OracleCandidateKind _candidateKind(String value) => switch (value) {
  'declaration' => OracleCandidateKind.dartDeclaration,
  'dartLibrary' => OracleCandidateKind.dartLibrary,
  'analyzerDiagnostic' => OracleCandidateKind.analyzerDiagnostic,
  'asset' => OracleCandidateKind.asset,
  'duplicateGroup' => OracleCandidateKind.duplicateGroup,
  'diRegistration' => OracleCandidateKind.getItRegistration,
  'route' => OracleCandidateKind.route,
  'localizationKey' => OracleCandidateKind.localizationKey,
  _ => throw FormatException('unknown scanner node kind $value'),
};

void _validateMeasurement(Object? value, {String? expected}) {
  final reader = _Reader(
    _asMap(value, 'finding measurement'),
    'finding measurement',
  );
  final kind = reader.string('kind');
  if (expected != null && kind != expected) {
    throw FormatException('finding measurement kind must be $expected');
  }
  final status = reader.string('status');
  if (!const <String>{
    'measured',
    'unknown',
    'notApplicable',
  }.contains(status)) {
    throw const FormatException('unknown finding measurement status');
  }
  if (reader.string('unit') != 'bytes') {
    throw const FormatException('finding measurement unit must be bytes');
  }
  if (!reader.present('value')) {
    throw const FormatException('finding measurement value is required');
  }
  final raw = reader.optional('value');
  if (status == 'measured') {
    if (raw is! int || raw < 0) {
      throw const FormatException(
        'measured finding value must be non-negative integer',
      );
    }
  } else if (raw != null) {
    throw const FormatException(
      'unavailable finding measurement value must be null',
    );
  }
  reader.finish();
}

void _validateDetails(OracleCandidateKind kind, Map<String, Object?> details) {
  final expected = _detailTypes[kind]!;
  final required = _requiredDetailKeys[kind]!;
  if (!details.keys.toSet().containsAll(required)) {
    throw FormatException('finding details omit required production keys');
  }
  if (!expected.keys.toSet().containsAll(details.keys)) {
    throw const FormatException(
      'finding details contain an unknown rule-specific key',
    );
  }
  for (final entry in details.entries) {
    final valid = switch (expected[entry.key]!) {
      _DetailType.text => entry.value is String,
      _DetailType.integer ||
      _DetailType.bytes => _nonNegativeInteger(entry.value),
      _DetailType.boolean => entry.value is bool,
      _DetailType.paths => _stringList(entry.value),
    };
    if (!valid) {
      throw FormatException('finding detail ${entry.key} has invalid type');
    }
  }
}

bool _nonNegativeInteger(Object? value) => value is int && value >= 0;

bool _stringList(Object? value) =>
    value is List && value.every((item) => item is String);

enum _DetailType { text, integer, bytes, boolean, paths }

const _detailTypes = <OracleCandidateKind, Map<String, _DetailType>>{
  OracleCandidateKind.dartDeclaration: {},
  OracleCandidateKind.dartLibrary: {},
  OracleCandidateKind.analyzerDiagnostic: {
    'diagnosticCode': _DetailType.text,
    'message': _DetailType.text,
    'line': _DetailType.integer,
    'column': _DetailType.integer,
  },
  OracleCandidateKind.asset: {
    'baseSizeBytes': _DetailType.bytes,
    'variantCount': _DetailType.integer,
    'variantSizeBytes': _DetailType.bytes,
    'hasTransformers': _DetailType.boolean,
  },
  OracleCandidateKind.duplicateGroup: {
    'paths': _DetailType.paths,
    'fileCount': _DetailType.integer,
    'sizePerFile': _DetailType.bytes,
    'groupSourceBytes': _DetailType.bytes,
    'potentialReclaimableBytes': _DetailType.bytes,
  },
  OracleCandidateKind.getItRegistration: {
    'canonicalType': _DetailType.text,
    'instanceNameState': _DetailType.text,
    'instanceName': _DetailType.text,
    'registrationApi': _DetailType.text,
    'scope': _DetailType.text,
    'environments': _DetailType.text,
    'sourceLocation': _DetailType.text,
    'generatedWiring': _DetailType.boolean,
  },
  OracleCandidateKind.route: {
    'path': _DetailType.text,
    'routeName': _DetailType.text,
    'declaredAt': _DetailType.text,
    'externallyAddressable': _DetailType.boolean,
  },
  OracleCandidateKind.localizationKey: {
    'key': _DetailType.text,
    'memberKind': _DetailType.text,
    'hasPlaceholders': _DetailType.boolean,
    'missingLocales': _DetailType.text,
    'declaredAt': _DetailType.text,
  },
};

const _measurementByKind = <OracleCandidateKind, String>{
  OracleCandidateKind.dartDeclaration: 'source-bytes',
  OracleCandidateKind.dartLibrary: 'source-bytes',
  OracleCandidateKind.analyzerDiagnostic: 'source-bytes',
  OracleCandidateKind.asset: 'asset-family-source-bytes',
  OracleCandidateKind.duplicateGroup: 'duplicate-potential-reclaimable-bytes',
  OracleCandidateKind.getItRegistration: 'source-bytes',
  OracleCandidateKind.route: 'source-bytes',
  OracleCandidateKind.localizationKey: 'source-bytes',
};

const _requiredDetailKeys = <OracleCandidateKind, Set<String>>{
  OracleCandidateKind.dartDeclaration: {},
  OracleCandidateKind.dartLibrary: {},
  OracleCandidateKind.analyzerDiagnostic: {
    'diagnosticCode',
    'message',
    'line',
    'column',
  },
  OracleCandidateKind.asset: {
    'baseSizeBytes',
    'variantCount',
    'variantSizeBytes',
    'hasTransformers',
  },
  OracleCandidateKind.duplicateGroup: {
    'paths',
    'fileCount',
    'sizePerFile',
    'groupSourceBytes',
    'potentialReclaimableBytes',
  },
  OracleCandidateKind.getItRegistration: {
    'canonicalType',
    'instanceNameState',
    'registrationApi',
    'scope',
    'environments',
    'sourceLocation',
    'generatedWiring',
  },
  OracleCandidateKind.route: {'path', 'declaredAt', 'externallyAddressable'},
  OracleCandidateKind.localizationKey: {
    'key',
    'memberKind',
    'hasPlaceholders',
    'missingLocales',
    'declaredAt',
  },
};

void _validateFindingDomainSemantics(
  OracleCandidateKind kind,
  String nodeId,
  Map<String, Object?> details,
  List<Object?> measurements, {
  required String packageName,
  required String projectRelativeOrigin,
}) {
  final measurement = _asMap(measurements.single, 'finding measurement');
  final status = measurement['status'];
  final value = measurement['value'];
  if (status == 'measured' && value is! int) {
    throw const FormatException(
      'measured finding must retain an integer value',
    );
  }
  if (kind == OracleCandidateKind.getItRegistration) {
    _validateDiIdentity(nodeId, details, packageName: packageName);
  }
  switch (kind) {
    case OracleCandidateKind.duplicateGroup:
      final paths = (details['paths']! as List<Object?>).cast<String>();
      if (paths.any((path) => !isCanonicalProjectRelativePosixPath(path))) {
        throw const FormatException('duplicate path is not canonical');
      }
    case OracleCandidateKind.route || OracleCandidateKind.localizationKey:
      if (!isCanonicalProjectRelativePosixLocation(
        details['declaredAt']! as String,
      )) {
        throw const FormatException('declaration location is not canonical');
      }
    default:
      break;
  }
  if ((kind == OracleCandidateKind.asset ||
          kind == OracleCandidateKind.duplicateGroup) &&
      status != 'measured') {
    throw const FormatException(
      'asset and duplicate finding bytes must be measured',
    );
  }
  if (kind != OracleCandidateKind.asset &&
      kind != OracleCandidateKind.duplicateGroup &&
      (status != 'unknown' || value != null)) {
    throw const FormatException(
      'current producer finding bytes must be unknown',
    );
  }
  if (status != 'measured') return;
  final bytes = value as int;
  switch (kind) {
    case OracleCandidateKind.asset:
      final base = details['baseSizeBytes']! as int;
      final variants = details['variantSizeBytes']! as int;
      if (bytes != base + variants) {
        throw const FormatException(
          'asset finding bytes differ from family sizes',
        );
      }
    case OracleCandidateKind.duplicateGroup:
      final paths = details['paths']! as List<Object?>;
      final count = details['fileCount']! as int;
      final perFile = details['sizePerFile']! as int;
      final group = details['groupSourceBytes']! as int;
      final reclaimable = details['potentialReclaimableBytes']! as int;
      final sortedPaths = paths.cast<String>().toList()..sort();
      if (paths.length < 2 ||
          paths.toSet().length != paths.length ||
          !_sameStrings(paths.cast<String>(), sortedPaths) ||
          paths.length != count ||
          group != count * perFile ||
          reclaimable != (count - 1) * perFile ||
          bytes != reclaimable) {
        throw const FormatException(
          'duplicate detail arithmetic is inconsistent',
        );
      }
    default:
      break;
  }
}

void _validateCandidatePathIdentity(
  OracleCandidateKind kind,
  String nodeId,
  String projectRelativeOrigin,
  Map<String, Object?> details, {
  required String packageName,
}) {
  String? identityPath;
  switch (kind) {
    case OracleCandidateKind.dartDeclaration:
      final prefix = 'dart:$packageName/';
      final separator = nodeId.lastIndexOf('#');
      if (!nodeId.startsWith(prefix) ||
          separator <= prefix.length ||
          separator == nodeId.length - 1) {
        throw const FormatException('invalid Dart declaration identity');
      }
      identityPath = nodeId.substring(prefix.length, separator);
    case OracleCandidateKind.dartLibrary:
      final prefix = 'dart:$packageName/';
      if (!nodeId.startsWith(prefix) || nodeId.contains('#')) {
        throw const FormatException('invalid Dart library identity');
      }
      identityPath = nodeId.substring(prefix.length);
    case OracleCandidateKind.analyzerDiagnostic:
      final prefix = 'dart-diagnostic:$packageName/';
      final codeSeparator = nodeId.lastIndexOf('#');
      final offsetSeparator = nodeId.lastIndexOf('@');
      if (!nodeId.startsWith(prefix) ||
          codeSeparator <= prefix.length ||
          offsetSeparator <= codeSeparator + 1 ||
          int.tryParse(nodeId.substring(offsetSeparator + 1)) == null) {
        throw const FormatException('invalid analyzer diagnostic identity');
      }
      identityPath = nodeId.substring(prefix.length, codeSeparator);
    case OracleCandidateKind.asset:
      final prefix = 'asset:$packageName/';
      if (!nodeId.startsWith(prefix)) {
        throw const FormatException('invalid asset identity');
      }
      identityPath = nodeId.substring(prefix.length);
    case OracleCandidateKind.duplicateGroup:
      identityPath = (details['paths']! as List<Object?>).first! as String;
    case OracleCandidateKind.getItRegistration:
      return;
    case OracleCandidateKind.route || OracleCandidateKind.localizationKey:
      identityPath = _pathFromLocation(details['declaredAt']! as String);
  }
  if (identityPath == null ||
      !isCanonicalProjectRelativePosixPath(identityPath) ||
      identityPath != projectRelativeOrigin) {
    throw const FormatException(
      'candidate identity path differs from its canonical project origin',
    );
  }
}

String? _pathFromLocation(String value) {
  final last = value.lastIndexOf(':');
  if (last < 1) return null;
  final preceding = value.lastIndexOf(':', last - 1);
  if (preceding >= 1 &&
      int.tryParse(value.substring(preceding + 1, last)) != null) {
    return value.substring(0, preceding);
  }
  return value.substring(0, last);
}

void _validateDiIdentity(
  String nodeId,
  Map<String, Object?> details, {
  required String packageName,
}) {
  if (!nodeId.startsWith('di:registration|')) {
    throw const FormatException('GetIt node is not a registration identity');
  }
  final parts = nodeId.split('|');
  if (parts.length < 7) {
    throw const FormatException('GetIt registration identity is incomplete');
  }
  String decode(String value) {
    try {
      return utf8.decode(base64Url.decode(base64Url.normalize(value)));
    } on FormatException {
      throw const FormatException(
        'GetIt registration identity is not base64url',
      );
    }
  }

  final package = decode(parts[1]);
  final type = decode(parts[2]);
  final instance = decode(parts[3]);
  final scope = decode(parts[4]);
  final environmentCount = int.tryParse(parts[5]);
  if (environmentCount == null ||
      environmentCount < 0 ||
      parts.length != 7 + environmentCount) {
    throw const FormatException(
      'GetIt registration environment identity is invalid',
    );
  }
  final environments = <String>[
    for (var index = 0; index < environmentCount; index++)
      decode(parts[6 + index]),
  ];
  final source = decode(parts.last);
  final expectedEnvironments = (details['environments']! as String).isEmpty
      ? const <String>[]
      : (details['environments']! as String).split(',');
  final state = details['instanceNameState']! as String;
  final instanceName = details['instanceName'];
  final detailScope = details['scope']! as String;
  if (detailScope != 'base' &&
      detailScope != 'dynamic' &&
      !RegExp(r'^named:.+$').hasMatch(detailScope)) {
    throw const FormatException('GetIt scope display is not production-shaped');
  }
  final expectedScope = detailScope.startsWith('named:')
      ? 'named|${base64UrlEncode(utf8.encode(detailScope.substring('named:'.length)))}'
      : detailScope;
  final instanceMatches = switch (state) {
    'absent' => instance == 'absent' && instanceName == null,
    'dynamic' => instance == 'dynamic' && instanceName == null,
    'constant' =>
      instanceName is String &&
          instance == 'constant|${base64UrlEncode(utf8.encode(instanceName))}',
    _ => false,
  };
  final sortedEnvironments = environments.toList()..sort();
  final sourceAt = source.lastIndexOf('@');
  final sourcePath = sourceAt < 1 ? null : source.substring(0, sourceAt);
  final sourceOffset = sourceAt < 1
      ? null
      : int.tryParse(source.substring(sourceAt + 1));
  final location = details['sourceLocation']! as String;
  final locationMatch = RegExp(
    r'^([^:]+):[1-9][0-9]*:[1-9][0-9]*$',
  ).firstMatch(location);
  if (package != packageName ||
      type != details['canonicalType'] ||
      !instanceMatches ||
      scope != expectedScope ||
      !_sameStrings(environments, expectedEnvironments) ||
      !_sameStrings(environments, sortedEnvironments) ||
      environments.toSet().length != environments.length ||
      sourcePath == null ||
      !isCanonicalProjectRelativePosixPath(sourcePath) ||
      sourceOffset == null ||
      sourceOffset < 0 ||
      locationMatch == null ||
      !isCanonicalProjectRelativePosixLocation(location, requireColumn: true) ||
      locationMatch.group(1) != sourcePath) {
    throw const FormatException(
      'GetIt details differ from registration identity',
    );
  }
}

void _validateReportStatistics(
  Map<String, Object?> statistics,
  List<ScannerFindingObservation> findings, {
  required Map<String, ScannerBlockerObservation> blockers,
  required ScannerAnalysisPass? pass,
  required List<String> reportingAdapterIds,
}) {
  final reader = _Reader(statistics, 'statistics');
  _validateFindingStatistics(
    reader.map('findings'),
    findings,
    reportingAdapterIds: reportingAdapterIds,
  );
  final measurements = reader.list('measurements');
  for (final value in measurements) {
    final item = _Reader(_asMap(value, 'run measurement'), 'run measurement');
    item.string('kind');
    item.optionalString('adapterId');
    final status = item.string('status');
    if (!item.present('value')) {
      throw const FormatException('run measurement value is required');
    }
    final measurementValue = item.optional('value');
    final known = item.nonNegative('knownCount');
    item.nonNegative('unknownCount');
    if (!const {'measured', 'unknown', 'notApplicable'}.contains(status) ||
        item.string('unit').isEmpty ||
        (status == 'measured' && measurementValue is! int) ||
        (status != 'measured' && measurementValue != null) ||
        item.string('scope').isEmpty ||
        item.string('aggregation').isEmpty ||
        (status == 'unknown' && known != 0)) {
      throw const FormatException('invalid run measurement');
    }
    item.finish();
  }
  _validateRunMeasurementInventory(measurements, pass, findings);
  final blockerStats = _Reader(reader.map('blockers'), 'statistics.blockers');
  final recorded = blockerStats.nonNegative('recorded');
  final active = blockerStats.nonNegative('activeUnique');
  final unbound = blockerStats.nonNegative('unboundUnique');
  final affected = blockerStats.nonNegative('affectedFindings');
  final byProducer = _nonNegativeCountMap(
    blockerStats.map('byProducer'),
    'statistics.blockers.byProducer',
  );
  final activeIds = <String>{
    for (final finding in findings) ...finding.blockerIds,
  };
  final expectedByProducer = <String, int>{};
  for (final id in activeIds) {
    final blocker = blockers[id];
    if (blocker == null) {
      throw const FormatException('active blocker is absent from registry');
    }
    expectedByProducer.update(
      blocker.producer,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  final expectedAffected = findings
      .where((finding) => finding.blockerIds.isNotEmpty)
      .length;
  if (active != activeIds.length ||
      affected != expectedAffected ||
      !_sameIntMaps(byProducer, expectedByProducer) ||
      pass?.blockersRecorded != recorded ||
      blockers.length != active + unbound ||
      recorded < blockers.length) {
    throw const FormatException('blocker statistics are inconsistent');
  }
  blockerStats.finish();
  final exclusions = _Reader(reader.map('exclusions'), 'statistics.exclusions');
  exclusions.nonNegative('policyVersion');
  final observed = exclusions.nonNegative('totalObserved');
  final byReason = _nonNegativeCountMap(
    exclusions.map('byReason'),
    'statistics.exclusions.byReason',
  );
  if (byReason.values.fold(0, (sum, value) => sum + value) != observed) {
    throw const FormatException(
      'exclusion statistics total differs from reasons',
    );
  }
  exclusions.finish();
  reader.finish();
}

bool _sameIntMaps(Map<String, int> left, Map<String, int> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

void _validateRunMeasurementInventory(
  List<Object?> values,
  ScannerAnalysisPass? pass,
  List<ScannerFindingObservation> findings,
) {
  final executed =
      pass?.adapters
          .where(
            (adapter) =>
                adapter.role == 'reporting' && adapter.status == 'executed',
          )
          .map((adapter) => adapter.id)
          .toSet() ??
      const <String>{};
  final expected = <String>[
    if (executed.contains('assets')) 'assets',
    if (executed.contains('duplicates')) 'duplicates',
    if (executed.contains('dart')) 'dart',
  ];
  if (values.length != expected.length) {
    throw const FormatException(
      'run measurement inventory differs from executed adapters',
    );
  }
  const contracts = <String, ({String kind, String scope, String aggregation})>{
    'assets': (
      kind: 'asset-family-source-bytes',
      scope: 'assets-inventory',
      aggregation: 'unique-asset-family-paths',
    ),
    'duplicates': (
      kind: 'duplicate-potential-reclaimable-bytes',
      scope: 'duplicate-inventory',
      aggregation: 'within-duplicate-groups-only',
    ),
    'dart': (
      kind: 'dart-finding-source-bytes',
      scope: 'dart-findings',
      aggregation: 'not-additive-with-file-inventory',
    ),
  };
  for (final entry in values.indexed) {
    final expectedAdapter = expected[entry.$1];
    final item = _Reader(
      _asMap(entry.$2, 'run measurement'),
      'run measurement',
    );
    final contract = contracts[expectedAdapter]!;
    if (item.string('kind') != contract.kind ||
        item.optionalString('adapterId') != expectedAdapter ||
        item.string('unit') != 'bytes' ||
        item.string('scope') != contract.scope ||
        item.string('aggregation') != contract.aggregation) {
      throw const FormatException(
        'run measurement contract differs from production',
      );
    }
    final status = item.string('status');
    if (!item.present('value')) {
      throw const FormatException(
        'run measurement must retain an explicit value',
      );
    }
    final value = item.optional('value');
    final known = item.nonNegative('knownCount');
    final unknown = item.nonNegative('unknownCount');
    if (expectedAdapter == 'assets' || expectedAdapter == 'duplicates') {
      if (status != 'measured' || value is! int || value < 0) {
        throw const FormatException(
          'asset/duplicate run measurement must be measured',
        );
      }
      final observed = findings
          .where(
            (finding) => expectedAdapter == 'assets'
                ? finding.candidateKey.kind == OracleCandidateKind.asset
                : finding.candidateKey.kind ==
                      OracleCandidateKind.duplicateGroup,
          )
          .length;
      if (known < observed || known + unknown < observed) {
        throw const FormatException(
          'asset/duplicate measurement counts omit findings',
        );
      }
    } else {
      final dartFindings = findings
          .where((finding) => finding.reportingAdapterId == 'dart')
          .toList(growable: false);
      final findingValues = dartFindings
          .map((finding) {
            final measurement = _asMap(
              finding.measurements.single,
              'Dart finding measurement',
            );
            return measurement['status'] == 'measured'
                ? measurement['value'] as int?
                : null;
          })
          .toList(growable: false);
      final expectedKnown = findingValues.whereType<int>().length;
      final expectedUnknown = findingValues.length - expectedKnown;
      final expectedValue = expectedKnown == 0
          ? (findingValues.isEmpty ? 0 : null)
          : findingValues.whereType<int>().fold<int>(
              0,
              (sum, item) => sum + item,
            );
      final expectedStatus = expectedValue == null ? 'unknown' : 'measured';
      if (status != expectedStatus ||
          value != expectedValue ||
          known != expectedKnown ||
          unknown != expectedUnknown) {
        throw const FormatException(
          'Dart run measurement differs from findings',
        );
      }
    }
    item.finish();
  }
}

void _validateFindingStatistics(
  Map<String, Object?> value,
  List<ScannerFindingObservation> findings, {
  required List<String> reportingAdapterIds,
}) {
  final reader = _Reader(value, 'finding statistics');
  if (reader.nonNegative('total') != findings.length) {
    throw const FormatException(
      'finding statistics total differs from findings',
    );
  }
  final byTier = <String, int>{for (final tier in _tiers) tier: 0};
  for (final finding in findings) {
    byTier.update(finding.confidence, (count) => count + 1);
  }
  _sameCountMap(reader.map('byTier'), byTier, 'byTier');
  final byAdapter = <String, int>{for (final id in reportingAdapterIds) id: 0};
  for (final finding in findings) {
    byAdapter.update(
      finding.reportingAdapterId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }
  _sameCountMap(
    reader.map('byReportingAdapter'),
    byAdapter,
    'byReportingAdapter',
  );
  final adapterTier = <String, Map<String, int>>{
    for (final id in reportingAdapterIds)
      id: <String, int>{for (final tier in _tiers) tier: 0},
  };
  for (final finding in findings) {
    final map = adapterTier.putIfAbsent(
      finding.reportingAdapterId,
      () => <String, int>{for (final tier in _tiers) tier: 0},
    );
    map.update(finding.confidence, (count) => count + 1, ifAbsent: () => 1);
  }
  final rawAdapterTier = reader.map('byReportingAdapterAndTier');
  if (rawAdapterTier.length != adapterTier.length) {
    throw const FormatException(
      'byReportingAdapterAndTier differs from findings',
    );
  }
  for (final entry in adapterTier.entries) {
    final raw = rawAdapterTier[entry.key];
    if (raw == null) {
      throw const FormatException('missing adapter tier statistics');
    }
    _sameCountMap(
      _asMap(raw, 'adapter tier statistics'),
      entry.value,
      'byReportingAdapterAndTier',
    );
  }
  _sameCountMap(
    reader.map('byRule'),
    _counts(findings, (f) => f.ruleId),
    'byRule',
  );
  _sameCountMap(
    reader.map('byNodeKind'),
    _counts(findings, (f) => f.nodeKind),
    'byNodeKind',
  );
  _sameCountMap(
    reader.map('byClassificationReason'),
    _countsMany(findings, (f) => f.classificationReasons),
    'byClassificationReason',
  );
  reader.finish();
}

Map<String, int> _counts(
  Iterable<ScannerFindingObservation> findings,
  String Function(ScannerFindingObservation) key,
) {
  final result = <String, int>{};
  for (final finding in findings) {
    result.update(key(finding), (count) => count + 1, ifAbsent: () => 1);
  }
  return result;
}

Map<String, int> _countsMany(
  Iterable<ScannerFindingObservation> findings,
  Iterable<String> Function(ScannerFindingObservation) keys,
) {
  final result = <String, int>{};
  for (final finding in findings) {
    for (final key in keys(finding)) {
      result.update(key, (count) => count + 1, ifAbsent: () => 1);
    }
  }
  return result;
}

void _sameCountMap(
  Map<String, Object?> raw,
  Map<String, int> expected,
  String context,
) {
  final actual = _nonNegativeCountMap(raw, context);
  if (actual.length != expected.length ||
      !actual.entries.every((entry) => expected[entry.key] == entry.value)) {
    throw FormatException('$context differs from findings');
  }
}

Map<String, int> _nonNegativeCountMap(
  Map<String, Object?> raw,
  String context,
) {
  final result = <String, int>{};
  for (final entry in raw.entries) {
    if (entry.key.isEmpty || entry.value is! int || (entry.value as int) < 0) {
      throw FormatException('$context contains an invalid count');
    }
    result[entry.key] = entry.value as int;
  }
  return result;
}

OracleTarget _target(Object? value, String context) {
  final reader = _Reader(_asMap(value, context), context);
  final flavor = reader.optional('flavor');
  if (flavor != null && flavor is! String) {
    throw const FormatException('target flavor must be string or null');
  }
  final target = OracleTarget(
    name: reader.string('name'),
    platform: reader.string('platform'),
    entrypoint: reader.string('entrypoint'),
    flavor: flavor as String?,
    dartDefines: reader
        .map('dartDefines')
        .map((key, value) => MapEntry(key, _string(value, 'dart define'))),
  );
  try {
    target.executionContextId;
  } on StateError {
    throw FormatException('$context is not a canonical configured target');
  }
  if (!_relative(target.entrypoint)) {
    throw FormatException(
      '$context entrypoint is not project-relative Dart path',
    );
  }
  reader.finish();
  return target;
}

OracleAuxiliaryExecutionTarget _auxiliary(
  Object? value,
  List<OracleTarget> targets,
) {
  final reader = _Reader(_asMap(value, 'auxiliary target'), 'auxiliary target');
  final domain = switch (reader.string('domain')) {
    'test' => OracleAuxiliaryDomain.test,
    'runtime' => OracleAuxiliaryDomain.runtime,
    'external' => OracleAuxiliaryDomain.external,
    _ => throw const FormatException('unknown auxiliary domain'),
  };
  final sourceValue = reader.optional('sourceConfiguredTarget');
  final source = sourceValue == null
      ? null
      : _target(sourceValue, 'auxiliary source target');
  if (source != null && !targets.any((target) => _sameTarget(target, source))) {
    throw const FormatException('unknown auxiliary source target');
  }
  final wireId = reader.string('id');
  String logicalId;
  try {
    logicalId = logicalAuxiliaryIdFromWire(wireId, domain);
  } on ArgumentError {
    throw const FormatException('invalid auxiliary execution target');
  }
  final result = OracleAuxiliaryExecutionTarget(
    id: logicalId,
    domain: domain,
    environmentValues: reader
        .map('environmentValues')
        .map(
          (key, value) =>
              MapEntry(key, _string(value, 'auxiliary environment')),
        ),
    environmentComplete: reader.boolean('environmentComplete'),
    reason: reader.string('reason'),
    sourceConfiguredTarget: source,
  );
  try {
    if (result.executionContextId != wireId) {
      throw StateError('auxiliary wire ID did not round-trip');
    }
  } on StateError {
    throw const FormatException('invalid auxiliary execution target');
  }
  reader.finish();
  return result;
}

bool _sameTargets(List<OracleTarget> left, List<OracleTarget> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => _sameTarget(entry.$2, right[entry.$1]));
bool _sameTarget(OracleTarget left, OracleTarget right) =>
    left.executionContextId == right.executionContextId &&
    left.platform == right.platform &&
    left.entrypoint == right.entrypoint &&
    left.flavor == right.flavor &&
    _sameStringMap(left.dartDefines, right.dartDefines);
bool _sameAuxiliaries(
  List<OracleAuxiliaryExecutionTarget> left,
  List<OracleAuxiliaryExecutionTarget> right,
) =>
    left.length == right.length &&
    left.indexed.every((entry) {
      final a = entry.$2;
      final b = right[entry.$1];
      return a.id == b.id &&
          a.domain == b.domain &&
          a.environmentComplete == b.environmentComplete &&
          a.reason == b.reason &&
          _sameStringMap(a.environmentValues, b.environmentValues) &&
          ((a.sourceConfiguredTarget == null &&
                  b.sourceConfiguredTarget == null) ||
              (a.sourceConfiguredTarget != null &&
                  b.sourceConfiguredTarget != null &&
                  _sameTarget(
                    a.sourceConfiguredTarget!,
                    b.sourceConfiguredTarget!,
                  )));
    });
bool _sameStringMap(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);
bool _sameStrings(List<String> left, List<String> right) =>
    left.length == right.length &&
    left.indexed.every((entry) => entry.$2 == right[entry.$1]);
bool _context(String value) =>
    isCanonicalExecutionTargetId(value) || value == 'unattributed';

String _integrityDomain(String contextId) => switch (contextId) {
  'unattributed' => 'unattributed',
  String _ when contextId.startsWith('app:') => 'configuredTarget',
  String _ when contextId.startsWith('aux:') => 'auxiliary',
  _ => throw ArgumentError.value(contextId, 'contextId'),
};

String _sanitizeIntegrityReason(String value) => value
    .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Checks the only count relation available without individual edge/root IDs.
/// Attributed contexts may overlap, but unattributed facts are disjoint from
/// every attributed context. The subtraction form proves the upper bound
/// without constructing a potentially overflowing sum.
bool _withinDeduplicatedUnionBounds(
  int aggregate, {
  required int unattributed,
  required Iterable<int> attributed,
}) {
  if (aggregate < unattributed) return false;
  final attributedAggregate = aggregate - unattributed;
  var maximum = 0;
  var remaining = attributedAggregate;
  for (final count in attributed) {
    if (count > maximum) maximum = count;
    if (remaining == 0) continue;
    if (count >= remaining) {
      remaining = 0;
    } else {
      remaining -= count;
    }
  }
  return attributedAggregate >= maximum && remaining == 0;
}

bool _relative(String value) =>
    value.endsWith('.dart') && isCanonicalProjectRelativePosixPath(value);
void _unique(Iterable<String> values, String field) {
  final list = values.toList(growable: false);
  if (list.any((value) => value.isEmpty) ||
      list.toSet().length != list.length) {
    throw FormatException('duplicate or empty $field');
  }
}

Object? _freezeJson(Object? value) {
  if (value is Map) return _freezeJsonMap(_asMap(value, 'JSON object'));
  if (value is List) return List<Object?>.unmodifiable(value.map(_freezeJson));
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw const FormatException('JSON observation has unsupported value');
}

Map<String, Object?> _freezeJsonMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(
      value.map((key, item) => MapEntry(key, _freezeJson(item))),
    );
Map<String, Object?> _asMap(Object? value, String context) {
  if (value is! Map) {
    throw FormatException('$context must be object');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$context has non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

String _string(Object? value, String context) {
  if (value is! String || value.isEmpty) {
    throw FormatException('$context must be non-empty string');
  }
  return value;
}

final class _Reader {
  _Reader(this.value, this.context);
  final Map<String, Object?> value;
  final String context;
  final Set<String> _used = <String>{};
  bool present(String key) => value.containsKey(key);
  Object? required(String key) {
    _used.add(key);
    if (!value.containsKey(key) || value[key] == null) {
      throw FormatException('$context.$key is required');
    }
    return value[key];
  }

  Object? optional(String key) {
    if (value.containsKey(key)) _used.add(key);
    return value[key];
  }

  String string(String key) => _string(required(key), '$context.$key');
  String? optionalString(String key) {
    final result = optional(key);
    if (result != null && result is! String) {
      throw FormatException('$context.$key must be string');
    }
    return result as String?;
  }

  bool boolean(String key) {
    final result = required(key);
    if (result is! bool) throw FormatException('$context.$key must be boolean');
    return result;
  }

  int integer(String key) {
    final result = required(key);
    if (result is! int) throw FormatException('$context.$key must be integer');
    return result;
  }

  int nonNegative(String key) {
    final result = integer(key);
    if (result < 0) throw FormatException('$context.$key must be non-negative');
    return result;
  }

  Map<String, Object?> map(String key) =>
      _asMap(required(key), '$context.$key');
  List<Object?> list(String key) {
    final result = required(key);
    if (result is! List) throw FormatException('$context.$key must be array');
    return List<Object?>.from(result);
  }

  List<String> strings(String key) => list(key)
      .map((value) => _string(value, '$context.$key item'))
      .toList(growable: false);
  void finish() {
    final unknown = value.keys.toSet().difference(_used);
    if (unknown.isNotEmpty) {
      throw FormatException(
        '$context has unknown fields: ${unknown.join(',')}',
      );
    }
  }
}
