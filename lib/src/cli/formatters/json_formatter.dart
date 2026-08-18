import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../adapters/adapter_report_definition.dart';
import '../../apply/mode_apply_policy.dart';
import '../../core/confidence/confidence.dart';
import '../../core/confidence/finding.dart';
import '../../core/graph/blocker_identity.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_path_policy.dart';
import '../../core/project/target_matrix.dart';
import '../../reporting/run_report.dart';
import 'report_formatter.dart';

/// Formats a complete run report as stable machine-readable JSON.
class JsonFormatter implements ReportFormatter {
  /// Creates a JSON formatter for schema [version].
  const JsonFormatter({this.version = RunReport.schemaVersion});

  /// Requested schema version. Version 2 is compatibility-only.
  final int version;

  @override
  String format(RunReport report) {
    final buffer = StringBuffer();
    writeTo(report, buffer);
    return buffer.toString();
  }

  /// Writes compact JSON directly to [sink] without first creating one large
  /// intermediate string.
  void writeTo(RunReport report, StringSink sink) {
    final output = version == 2 ? _serializeV2(report) : _serializeV3(report);
    final encoder = const JsonEncoder().startChunkedConversion(
      StringConversionSink.fromStringSink(sink),
    );
    encoder
      ..add(output)
      ..close();
  }

  Map<String, Object?> _serializeV3(RunReport report) {
    final adapterDefinitions = {
      for (final definition in report.adapterReportDefinitions)
        definition.adapterId: definition,
    };
    final blockerIdsByObject = Map<Blocker, String>.identity();
    final blockerIdsByCanonicalKey = <String, String>{};
    final blockerRegistry = <String, Blocker>{};
    void registerBlocker(Blocker blocker) {
      final cachedId = blockerIdsByObject[blocker];
      if (cachedId != null) return;
      final canonicalKey = blockerCanonicalKey(blocker);
      final id = blockerIdsByCanonicalKey.putIfAbsent(
        canonicalKey,
        () => _blockerId(canonicalKey),
      );
      blockerIdsByObject[blocker] = id;
      blockerRegistry.putIfAbsent(id, () => blocker);
    }

    if (report.analysisPasses.isNotEmpty) {
      for (final blocker in report.analysisPasses.last.unboundBlockers) {
        registerBlocker(blocker);
      }
    }
    for (final finding in report.findings) {
      for (final blocker in finding.blockers) {
        registerBlocker(blocker);
      }
    }
    final sortedBlockerIds = blockerRegistry.keys.toList()..sort();

    List<String> blockerIdsFor(Finding finding) {
      final ids = <String>[];
      final seen = <String>{};
      for (final blocker in finding.blockers) {
        final id = blockerIdsByObject[blocker]!;
        if (seen.add(id)) ids.add(id);
      }
      return ids;
    }

    return {
      'version': RunReport.schemaVersion,
      'run': {
        'id': report.identity.id,
        'command': report.identity.command.name,
        'toolVersion': report.identity.toolVersion,
        'status': report.status.name,
        'exitCode': report.exitCode,
        'partialApplied': report.partialApplied,
        'startedAtUtc': report.identity.startedAtUtc.toIso8601String(),
        'finishedAtUtc': report.identity.finishedAtUtc.toIso8601String(),
        'elapsedMicros': report.identity.elapsedMicros,
        'projectRoot': report.projectRoot,
        'packageName': report.packageName,
      },
      'analysisCoverage': _serializeCoverage(
        report.targetMatrix,
        report.rootCoverage,
        analysisMode: report.analysisMode,
        includeModeFacts: true,
      ),
      'presentation': {
        'adapters':
            (report.adapterReportDefinitions.toList()..sort(
                  (left, right) => left.adapterId.compareTo(right.adapterId),
                ))
                .map(_serializeAdapterReportDefinition)
                .toList(),
      },
      'execution': {
        'requestedAdapters': report.requestedAdapters,
        'analysisPasses': report.analysisPasses
            .map(_serializeAnalysisPass)
            .toList(),
      },
      'statistics': {
        'findings': _serializeFindingStatistics(report.finalFindingStatistics),
        'measurements': report.analysisPasses.isEmpty
            ? const <Object?>[]
            : report.analysisPasses.last.measurements
                  .map(_serializeMeasurement)
                  .toList(),
        'blockers': report.analysisPasses.isEmpty
            ? {
                'recorded': 0,
                'activeUnique': 0,
                'unboundUnique': 0,
                'affectedFindings': 0,
                'byProducer': const <String, int>{},
              }
            : _serializeBlockerStatistics(
                report.analysisPasses.last.blockerStatistics,
              ),
        'exclusions': report.analysisPasses.isEmpty
            ? {
                'policyVersion': ProjectPathPolicy.version,
                'totalObserved': 0,
                'byReason': const <String, int>{},
              }
            : _serializeExclusions(report.analysisPasses.last),
      },
      'blockers': _LazyJsonMap(sortedBlockerIds, (id) {
        final blocker = blockerRegistry[id];
        return blocker == null ? null : _serializeBlocker(blocker);
      }),
      'diagnostics': report.diagnostics
          .map(
            (diagnostic) => {
              'code': diagnostic.code,
              'message': diagnostic.message,
              if (diagnostic.phase != null) 'phase': diagnostic.phase,
            },
          )
          .toList(),
      'verificationAttempts': report.verificationAttempts
          .map(_serializeVerificationAttempt)
          .toList(),
      if (report.applyStatistics != null)
        'apply': {
          ..._serializeApply(
            report.applyStatistics!,
            report.applyFindingOutcomes,
            report.applySelection,
            report.projectRoot,
            adapterDefinitions,
          ),
          'authorization': {
            'acceptedRiskCodes': report.acceptedRiskCodes,
            'source': report.riskAcceptanceSource.name,
          },
        },
      if (report.quarantinePath != null)
        'quarantine': {'path': report.quarantinePath},
      'findings': _LazyJsonList<Map<String, Object?>>(report.findings.length, (
        index,
      ) {
        final finding = report.findings[index];
        return _serializeFindingV3(
          finding,
          report.projectRoot,
          blockerIdsFor(finding),
          adapterDefinitions[finding.reportingAdapterId],
          report.analysisMode,
        );
      }),
    };
  }

  Map<String, Object?> _serializeV2(RunReport report) {
    final findings = report.findings;
    return {
      'version': 2,
      'timestamp': report.identity.finishedAtUtc.toIso8601String(),
      'analysisCoverage': _serializeCoverage(
        report.targetMatrix,
        report.rootCoverage,
      ),
      'summary': {
        'total': findings.length,
        'safe': findings
            .where((finding) => finding.confidence == Confidence.safe)
            .length,
        'high': findings
            .where((finding) => finding.confidence == Confidence.high)
            .length,
        'review': findings
            .where((finding) => finding.confidence == Confidence.review)
            .length,
        'protected': findings
            .where((finding) => finding.confidence == Confidence.protected)
            .length,
        'totalSourceBytes': findings.fold<int>(
          0,
          (sum, finding) => sum + (finding.sourceBytes ?? 0),
        ),
      },
      'findings': findings.map(_serializeFindingV2).toList(),
    };
  }

  Map<String, Object?> _serializeAdapterReportDefinition(
    AdapterReportDefinition definition,
  ) => {
    'id': definition.adapterId,
    'displayName': definition.displayName,
    if (definition.description.isNotEmpty)
      'description': definition.description,
    'findings': definition.findings
        .map(
          (finding) => {
            'nodeKind': finding.nodeKind.name,
            'ruleId': finding.ruleId,
            'title': finding.title,
            'nodeLabel': finding.nodeLabel,
            if (finding.description.isNotEmpty)
              'description': finding.description,
            if (finding.measurementKind != null)
              'measurementKind': finding.measurementKind,
            'details': finding.details
                .map(
                  (detail) => {
                    'key': detail.key,
                    'label': detail.label,
                    'valueType': detail.valueType.name,
                    if (detail.description.isNotEmpty)
                      'description': detail.description,
                  },
                )
                .toList(),
          },
        )
        .toList(),
    'measurements': definition.measurements
        .map(
          (measurement) => {
            'kind': measurement.kind,
            'label': measurement.label,
            'unit': measurement.unit,
            if (measurement.description.isNotEmpty)
              'description': measurement.description,
          },
        )
        .toList(),
  };

  Map<String, Object?> _serializeAnalysisPass(AnalysisPassReport pass) => {
    'id': pass.id,
    'purpose': pass.purpose.name,
    if (pass.round != null) 'round': pass.round,
    'elapsedMicros': pass.elapsedMicros,
    'graph': {
      'nodes': pass.nodeCount,
      'edges': pass.edgeCount,
      'roots': pass.rootCount,
      'blockersRecorded': pass.recordedBlockerCount,
      'danglingEdges': pass.danglingEdgeCount,
      'danglingRoots': pass.danglingRootCount,
    },
    'adapters': pass.adapterRuns
        .map(
          (adapter) => {
            'id': adapter.id,
            'name': adapter.name,
            'role': adapter.role.name,
            'status': adapter.status.name,
            'elapsedMicros': adapter.elapsedMicros,
            'contributions': {
              'nodes': adapter.nodesAdded,
              'edges': adapter.edgesAdded,
              'blockers': adapter.blockersAdded,
            },
            if (adapter.reason != null) 'reason': adapter.reason,
          },
        )
        .toList(),
    'findings': _serializeFindingStatistics(pass.findingStatistics),
  };

  Map<String, Object?> _serializeFindingStatistics(
    FindingStatistics statistics,
  ) => {
    'total': statistics.total,
    'byTier': _sortedMap(statistics.byTier),
    'byReportingAdapter': _sortedMap(statistics.byReportingAdapter),
    'byReportingAdapterAndTier': Map.fromEntries(
      statistics.byReportingAdapterAndTier.entries
          .map((entry) => MapEntry(entry.key, _sortedMap(entry.value)))
          .toList()
        ..sort((a, b) => a.key.compareTo(b.key)),
    ),
    'byRule': _sortedMap(statistics.byRule),
    'byNodeKind': _sortedMap(statistics.byNodeKind),
    'byClassificationReason': _sortedMap(statistics.byClassificationReason),
  };

  Map<String, Object?> _serializeMeasurement(RunMeasurement measurement) => {
    'kind': measurement.kind,
    if (measurement.adapterId != null) 'adapterId': measurement.adapterId,
    'status': measurement.status.name,
    'unit': measurement.unit,
    'value': measurement.value,
    'scope': measurement.scope,
    'aggregation': measurement.aggregation,
    'knownCount': measurement.knownCount,
    'unknownCount': measurement.unknownCount,
  };

  Map<String, Object?> _serializeBlockerStatistics(
    BlockerStatistics statistics,
  ) => {
    'recorded': statistics.recorded,
    'activeUnique': statistics.activeUnique,
    'unboundUnique': statistics.unboundUnique,
    'affectedFindings': statistics.affectedFindings,
    'byProducer': _sortedMap(statistics.byProducer),
  };

  Map<String, Object?> _serializeExclusions(AnalysisPassReport pass) => {
    'policyVersion': pass.exclusionPolicyVersion,
    'totalObserved': pass.exclusionsByReason.values.fold<int>(
      0,
      (sum, count) => sum + count,
    ),
    'byReason': _sortedMap(pass.exclusionsByReason),
  };

  Map<String, Object?> _serializeApply(
    ApplyStatistics statistics,
    List<ApplyFindingOutcome> outcomes,
    ApplySelectionReport? selection,
    String projectRoot,
    Map<String, AdapterReportDefinition> adapterDefinitions,
  ) => {
    if (selection != null)
      'selection': {
        'mode': selection.mode.name,
        'requestedFindingIds': selection.requestedFindingIds,
        'plannedFindingIds': selection.plannedFindingIds,
        'planFingerprint': selection.planFingerprint,
      },
    'rounds': statistics.rounds,
    'findings': {
      'committed': statistics.findingsCommitted,
      'rejectedRecovered': statistics.findingsRejectedRecovered,
      'blocked': statistics.findingsBlocked,
      'skippedDependency': statistics.findingsSkippedDependency,
      'remaining': statistics.findingsRemaining,
    },
    'actions': {
      'declared': statistics.actionsDeclared,
      'committed': statistics.actionsCommitted,
      'rolledBack': statistics.actionsRolledBack,
      'failedRecovered': statistics.actionsFailedRecovered,
    },
    'transactions': {
      'begun': statistics.transactionsBegun,
      'committed': statistics.transactionsCommitted,
      'rolledBackVerified': statistics.transactionsRolledBackVerified,
      'recoveryRequired': statistics.transactionsRecoveryRequired,
      'nonTerminal': statistics.transactionsNonTerminal,
    },
    'verificationAttempts': statistics.verificationAttempts,
    'sourceBytesRemoved': statistics.sourceBytesRemoved,
    'findingOutcomes': outcomes
        .map(
          (outcome) => _serializeApplyFindingOutcome(
            outcome,
            projectRoot,
            adapterDefinitions[outcome.finding.reportingAdapterId],
          ),
        )
        .toList(),
  };

  Map<String, Object?> _serializeApplyFindingOutcome(
    ApplyFindingOutcome outcome,
    String projectRoot,
    AdapterReportDefinition? adapterDefinition,
  ) {
    final finding = outcome.finding;
    final node = finding.node;
    final relatedNodeIds = outcome.relatedNodeIds.toList()..sort();
    return {
      'findingId': outcome.findingId,
      'status': outcome.status.name,
      'reasonCode': outcome.reasonCode,
      'reason': outcome.reason,
      if (outcome.round != null) 'round': outcome.round,
      if (outcome.transactionId != null) 'transactionId': outcome.transactionId,
      'rollbackVerified': outcome.rollbackVerified,
      'relatedNodeIds': relatedNodeIds,
      'finding': {
        'ruleId': finding.ruleId,
        'reportingAdapterId': finding.reportingAdapterId,
        'confidence': finding.confidence.label,
        'title': finding.title,
        'node': {
          'id': node.id,
          'kind': node.kind.name,
          'displayName': node.displayName,
          'origin': node.origin.toString(),
          'projectRelativeOrigin': _relativeOrigin(node.origin, projectRoot),
        },
        'predicates': _serializePredicates(finding),
        'classificationReasons': finding.classificationReasons
            .map((reason) => reason.code)
            .toList(),
        'unreachableIn': finding.unreachableIn,
        'reachableIn': finding.reachableIn,
        if (finding.protectionReasons.isNotEmpty)
          'protectionReasons': finding.protectionReasons,
        if (finding.blockers.isNotEmpty)
          'blockers': finding.blockers.map(_serializeBlocker).toList(),
        if (finding.evidence.isNotEmpty)
          'evidence': finding.evidence.map(_serializeEvidence).toList(),
        if (finding.proposedAction != null)
          'proposedAction': finding.proposedAction,
        'measurements': _findingMeasurements(finding, adapterDefinition),
        if (_domainDetails(node, adapterDefinition) case final details?)
          'details': details,
        if (finding.whyNotSafe != null) 'whyNotSafe': finding.whyNotSafe,
      },
    };
  }

  Map<String, Object?> _serializeVerificationAttempt(
    VerificationAttemptReport attempt,
  ) => {
    'purpose': attempt.purpose.name,
    if (attempt.round != null) 'round': attempt.round,
    if (attempt.transactionId != null) 'transactionId': attempt.transactionId,
    'complete': attempt.complete,
    'available': attempt.available,
    'accepted': attempt.accepted,
    'policyHash': attempt.policyHash,
    'requiredStepIds': attempt.requiredStepIds,
    'observedStepIds': attempt.observedStepIds,
    'workingDirectory': attempt.workingDirectory,
    'toolchainIdentity': attempt.toolchainIdentity,
    'newFailureCount': attempt.newFailureCount,
    'infrastructureFailureCount': attempt.infrastructureFailureCount,
    'steps': attempt.steps
        .map(
          (step) => {
            'id': step.id,
            'passed': step.passed,
            'available': step.available,
            'exitCode': step.exitCode,
            'elapsedMicros': step.elapsedMicros,
          },
        )
        .toList(),
  };

  Map<String, Object?> _serializeCoverage(
    TargetMatrix targetMatrix,
    RootCoverage rootCoverage, {
    AnalysisMode? analysisMode,
    bool includeModeFacts = false,
  }) => {
    if (includeModeFacts) 'analysisMode': analysisMode!.wireName,
    'targetMatrix': {
      'status': targetMatrix.status.name,
      'complete': targetMatrix.isComplete,
      'source': targetMatrix.source,
      'issues': targetMatrix.issues,
      'targets': targetMatrix.targets
          .map(
            (target) => {
              'name': target.name,
              'platform': target.platform,
              'entrypoint': target.entrypoint,
              if (target.flavor != null) 'flavor': target.flavor,
              'dartDefines': target.dartDefines,
            },
          )
          .toList(),
    },
    'roots': {
      'mode': rootCoverage.mode.name,
      'complete': rootCoverage.complete,
      if (includeModeFacts)
        'internalBoundaryComplete': rootCoverage.internalBoundaryComplete,
      if (includeModeFacts)
        'externalConsumersCovered': rootCoverage.externalConsumersCovered,
      'source': rootCoverage.source,
      'publicEntrypoints': rootCoverage.publicEntrypoints,
      'issues': rootCoverage.issues,
    },
  };

  Map<String, Object?> _serializeFindingV3(
    Finding finding,
    String projectRoot,
    List<String> blockerIds,
    AdapterReportDefinition? adapterDefinition,
    AnalysisMode analysisMode,
  ) {
    final node = finding.node;
    return {
      'ruleId': finding.ruleId,
      'reportingAdapterId': finding.reportingAdapterId,
      'confidence': finding.confidence.label,
      'title': finding.title,
      'node': {
        'id': node.id,
        'kind': node.kind.name,
        'displayName': node.displayName,
        'origin': node.origin.toString(),
        'projectRelativeOrigin': _relativeOrigin(node.origin, projectRoot),
      },
      'predicates': _serializePredicates(finding),
      'classificationReasons': finding.classificationReasons
          .map((reason) => reason.code)
          .toList(),
      'manualRiskCodes': finding.manualRisks.map((risk) => risk.code).toList()
        ..sort(),
      'applyEligible': ModeApplyPolicy.allows(analysisMode, finding),
      'unreachableIn': finding.unreachableIn,
      'reachableIn': finding.reachableIn,
      if (finding.protectionReasons.isNotEmpty)
        'protectionReasons': finding.protectionReasons,
      if (blockerIds.isNotEmpty) 'blockerIds': blockerIds,
      if (finding.evidence.isNotEmpty)
        'evidence': finding.evidence.map(_serializeEvidence).toList(),
      if (finding.proposedAction != null)
        'proposedAction': finding.proposedAction,
      'measurements': _findingMeasurements(finding, adapterDefinition),
      if (_domainDetails(node, adapterDefinition) case final details?)
        'details': details,
      if (finding.whyNotSafe != null) 'whyNotSafe': finding.whyNotSafe,
    };
  }

  Map<String, Object?> _serializeFindingV2(Finding finding) => {
    'ruleId': finding.ruleId,
    'confidence': finding.confidence.label,
    'title': finding.title,
    'node': {
      'id': finding.node.id,
      'kind': finding.node.kind.name,
      'displayName': finding.node.displayName,
      'origin': finding.node.origin.toString(),
    },
    'predicates': _serializePredicates(finding),
    'classificationReasons': finding.classificationReasons
        .map((reason) => reason.code)
        .toList(),
    'unreachableIn': finding.unreachableIn,
    'reachableIn': finding.reachableIn,
    if (finding.protectionReasons.isNotEmpty)
      'protectionReasons': finding.protectionReasons,
    if (finding.blockers.isNotEmpty)
      'blockers': finding.blockers.map(_serializeBlocker).toList(),
    if (finding.evidence.isNotEmpty)
      'evidence': finding.evidence.map(_serializeEvidence).toList(),
    if (finding.proposedAction != null)
      'proposedAction': finding.proposedAction,
    if (finding.sourceBytes != null) 'sourceBytes': finding.sourceBytes,
    if (finding.whyNotSafe != null) 'whyNotSafe': finding.whyNotSafe,
  };

  Map<String, bool> _serializePredicates(Finding finding) => {
    'ruleAllowsAutoFix': finding.predicates.ruleAllowsAutoFix,
    'unreachableAcrossAllTargets':
        finding.predicates.unreachableAcrossAllTargets,
    'noDynamicBlockers': finding.predicates.noDynamicBlockers,
    'notProtected': finding.predicates.notProtected,
    'noPublicApiRisk': finding.predicates.noPublicApiRisk,
    'hasDeterministicInverse': finding.predicates.hasDeterministicInverse,
    'analysisCoverageComplete': finding.predicates.analysisCoverageComplete,
    'actionSupported': finding.predicates.actionSupported,
  };

  Map<String, Object?> _serializeBlocker(Blocker blocker) => {
    'producer': blocker.producer,
    'reason': blocker.reason,
    if (blocker.location != null) 'location': blocker.location,
    if (blocker.sourceNodeId != null) 'sourceNodeId': blocker.sourceNodeId,
    if (blocker.affectedNamespace != null)
      'affectedNamespace': blocker.affectedNamespace,
    if (blocker.affectedNodeIds.isNotEmpty)
      'affectedNodeIds': blocker.affectedNodeIds.toList()..sort(),
  };

  Map<String, Object?> _serializeEvidence(Evidence evidence) => {
    'kind': evidence.kind.name,
    'producer': evidence.producer,
    'description': evidence.description,
    'exact': evidence.exact,
    if (evidence.location != null) 'location': evidence.location,
  };

  List<Map<String, Object?>> _findingMeasurements(
    Finding finding,
    AdapterReportDefinition? adapterDefinition,
  ) {
    final bytes = finding.sourceBytes;
    final findingDefinition = adapterDefinition?.findingFor(finding.node.kind);
    final measurementKind = findingDefinition?.measurementKind;
    if (measurementKind != null) {
      final measurement = adapterDefinition?.measurementFor(measurementKind);
      return [
        {
          'kind': measurementKind,
          'status': bytes == null ? 'unknown' : 'measured',
          'unit': measurement?.unit ?? 'bytes',
          'value': bytes,
        },
      ];
    }
    if (adapterDefinition != null) {
      return [
        {
          'kind': 'source-bytes',
          'status': bytes == null ? 'unknown' : 'measured',
          'unit': 'bytes',
          'value': bytes,
        },
      ];
    }
    return switch (finding.node.kind) {
      NodeKind.asset => [
        {
          'kind': 'asset-family-source-bytes',
          'status': bytes == null ? 'unknown' : 'measured',
          'unit': 'bytes',
          'value': bytes,
        },
      ],
      NodeKind.duplicateGroup => [
        {
          'kind': 'duplicate-potential-reclaimable-bytes',
          'status': bytes == null ? 'unknown' : 'measured',
          'unit': 'bytes',
          'value': bytes,
        },
      ],
      _ => [
        {
          'kind': 'source-bytes',
          'status': bytes == null ? 'unknown' : 'measured',
          'unit': 'bytes',
          'value': bytes,
        },
      ],
    };
  }

  Map<String, Object?>? _domainDetails(
    GraphNode node,
    AdapterReportDefinition? adapterDefinition,
  ) {
    final configured = adapterDefinition?.findingFor(node.kind);
    if (adapterDefinition != null) {
      if (configured == null) return null;
      final details = <String, Object?>{};
      for (final definition in configured.details) {
        final raw = node.metadata[definition.key];
        final projected = _typedDetailValue(raw, definition.valueType);
        if (projected != null) details[definition.key] = projected;
      }
      return details.isEmpty ? null : details;
    }
    if (node.kind == NodeKind.asset) {
      return {
        'baseSizeBytes': node.metadata['baseSizeBytes'],
        'variantCount': node.metadata['variantCount'],
        'variantSizeBytes': node.metadata['variantSizeBytes'],
        'hasTransformers': node.metadata['hasTransformers'],
      };
    }
    if (node.kind == NodeKind.duplicateGroup) {
      final paths =
          (node.metadata['paths'] as List<Object?>? ?? const [])
              .whereType<String>()
              .toList()
            ..sort();
      final fileCount = node.metadata['fileCount'] as int? ?? paths.length;
      final sizePerFile = node.metadata['sizePerFile'] as int?;
      return {
        'paths': paths,
        'fileCount': fileCount,
        'sizePerFile': sizePerFile,
        if (sizePerFile != null) 'groupSourceBytes': sizePerFile * fileCount,
        'potentialReclaimableBytes': node.sizeBytes,
      };
    }
    return null;
  }

  Object? _typedDetailValue(Object? value, AdapterReportDetailValueType type) {
    return switch (type) {
      AdapterReportDetailValueType.text ||
      AdapterReportDetailValueType.path => value is String ? value : null,
      AdapterReportDetailValueType.integer => value is int ? value : null,
      AdapterReportDetailValueType.boolean => value is bool ? value : null,
      AdapterReportDetailValueType.bytes =>
        value is int && value >= 0 ? value : null,
      AdapterReportDetailValueType.paths =>
        value is List<Object?>
            ? (value.whereType<String>().toList()..sort())
            : null,
    };
  }

  String _relativeOrigin(Uri origin, String projectRoot) {
    if (origin.scheme != 'file') return origin.toString();
    final path = origin.toFilePath();
    if (path == projectRoot || p.isWithin(projectRoot, path)) {
      return p.relative(path, from: projectRoot).replaceAll(r'\', '/');
    }
    return origin.toString();
  }

  String _blockerId(String canonicalKey) =>
      'blocker-${sha256.convert(utf8.encode(canonicalKey)).toString().substring(0, 16)}';

  Map<String, int> _sortedMap(Map<String, int> input) => Map.fromEntries(
    input.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

final class _LazyJsonList<E> extends ListBase<E> {
  _LazyJsonList(this._length, this._valueAt);

  final int _length;
  final E Function(int index) _valueAt;

  @override
  int get length => _length;

  @override
  set length(int value) => throw UnsupportedError('immutable JSON projection');

  @override
  E operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return _valueAt(index);
  }

  @override
  void operator []=(int index, E value) {
    throw UnsupportedError('immutable JSON projection');
  }
}

final class _LazyJsonMap extends MapBase<String, Object?> {
  _LazyJsonMap(this._keys, this._valueForKey);

  final List<String> _keys;
  final Object? Function(String key) _valueForKey;

  @override
  Object? operator [](Object? key) => key is String ? _valueForKey(key) : null;

  @override
  void operator []=(String key, Object? value) {
    throw UnsupportedError('immutable JSON projection');
  }

  @override
  void clear() => throw UnsupportedError('immutable JSON projection');

  @override
  Iterable<String> get keys => _keys;

  @override
  Object? remove(Object? key) {
    throw UnsupportedError('immutable JSON projection');
  }
}
