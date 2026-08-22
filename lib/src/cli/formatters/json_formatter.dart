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
import '../../core/graph/execution_context_identity.dart';
import '../../core/graph/execution_target.dart';
import '../../core/graph/node.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_path_policy.dart';
import '../../core/project/target_matrix.dart';
import '../../reporting/run_report.dart';
import 'report_formatter.dart';

/// Bounds the legacy JSON v2 compatibility projection before serialization.
final class JsonV2SerializationLimits {
  /// Creates limits for the legacy JSON v2 compatibility projection.
  JsonV2SerializationLimits({
    this.maxBlockerReferences = 250000,
    this.maxAffectedNodeIdReferences = 2000000,
    this.maxAffectedNodeIdsPerBlocker = 100000,
  }) {
    if (maxBlockerReferences < 0) {
      throw ArgumentError.value(maxBlockerReferences, 'maxBlockerReferences');
    }
    if (maxAffectedNodeIdReferences < 0) {
      throw ArgumentError.value(
        maxAffectedNodeIdReferences,
        'maxAffectedNodeIdReferences',
      );
    }
    if (maxAffectedNodeIdsPerBlocker < 0) {
      throw ArgumentError.value(
        maxAffectedNodeIdsPerBlocker,
        'maxAffectedNodeIdsPerBlocker',
      );
    }
  }

  /// Default bounds for compatibility serialization.
  static const defaults = JsonV2SerializationLimits._unchecked(
    maxBlockerReferences: 250000,
    maxAffectedNodeIdReferences: 2000000,
    maxAffectedNodeIdsPerBlocker: 100000,
  );

  const JsonV2SerializationLimits._unchecked({
    required this.maxBlockerReferences,
    required this.maxAffectedNodeIdReferences,
    required this.maxAffectedNodeIdsPerBlocker,
  });

  /// Maximum blocker occurrences serialized across all findings.
  final int maxBlockerReferences;

  /// Maximum affected-node ID occurrences serialized across all blockers.
  final int maxAffectedNodeIdReferences;

  /// Maximum affected-node IDs serialized for one blocker occurrence.
  final int maxAffectedNodeIdsPerBlocker;
}

/// Indicates that the legacy JSON v2 compatibility projection exceeds a bound.
final class JsonV2CompatibilityLimitException implements Exception {
  /// Creates a compatibility-projection limit exception.
  const JsonV2CompatibilityLimitException({
    required this.limitName,
    required this.limit,
    required this.observed,
  });

  /// Name of the exceeded bound.
  final String limitName;

  /// Configured maximum for [limitName].
  final int limit;

  /// First observed count above [limit].
  final int observed;

  @override
  String toString() =>
      'JSON v2 compatibility projection exceeds $limitName '
      '($observed > $limit). Use --json-version 3.';
}

/// Completed size of the legacy JSON v2 compatibility projection.
final class JsonV2ProjectionSize {
  /// Creates the completed projection size.
  const JsonV2ProjectionSize({
    required this.blockerReferences,
    required this.affectedNodeIdReferences,
    required this.largestAffectedNodeIdsPerBlocker,
  });

  /// Number of blocker occurrences serialized across all findings.
  final int blockerReferences;

  /// Number of affected-node ID occurrences serialized across all blockers.
  final int affectedNodeIdReferences;

  /// Largest affected-node ID occurrence count for one blocker.
  final int largestAffectedNodeIdsPerBlocker;
}

/// Formats a complete run report as stable machine-readable JSON.
class JsonFormatter implements ReportFormatter {
  /// Creates a JSON formatter for schema [version].
  const JsonFormatter({
    this.version = RunReport.schemaVersion,
    JsonV2SerializationLimits v2Limits = JsonV2SerializationLimits.defaults,
  }) : _v2Limits = v2Limits;

  /// Requested schema version. Version 2 is compatibility-only.
  final int version;

  final JsonV2SerializationLimits _v2Limits;

  /// Counts the legacy v2 projection or returns `null` for schema version 3.
  ///
  /// Throws [JsonV2CompatibilityLimitException] at the first occurrence that
  /// exceeds a configured v2 compatibility bound.
  JsonV2ProjectionSize? preflight(RunReport report) {
    if (version != 2) return null;

    var blockerReferences = 0;
    var affectedNodeIdReferences = 0;
    var largestAffectedNodeIdsPerBlocker = 0;
    for (final finding in report.findings) {
      for (final blocker in finding.blockers) {
        blockerReferences++;
        if (blockerReferences > _v2Limits.maxBlockerReferences) {
          throw JsonV2CompatibilityLimitException(
            limitName: 'maxBlockerReferences',
            limit: _v2Limits.maxBlockerReferences,
            observed: blockerReferences,
          );
        }

        final affectedNodeIds = blocker.affectedNodeIds.length;
        if (affectedNodeIds > _v2Limits.maxAffectedNodeIdsPerBlocker) {
          throw JsonV2CompatibilityLimitException(
            limitName: 'maxAffectedNodeIdsPerBlocker',
            limit: _v2Limits.maxAffectedNodeIdsPerBlocker,
            observed: affectedNodeIds,
          );
        }

        affectedNodeIdReferences += affectedNodeIds;
        if (affectedNodeIdReferences > _v2Limits.maxAffectedNodeIdReferences) {
          throw JsonV2CompatibilityLimitException(
            limitName: 'maxAffectedNodeIdReferences',
            limit: _v2Limits.maxAffectedNodeIdReferences,
            observed: affectedNodeIdReferences,
          );
        }
        if (affectedNodeIds > largestAffectedNodeIdsPerBlocker) {
          largestAffectedNodeIdsPerBlocker = affectedNodeIds;
        }
      }
    }

    return JsonV2ProjectionSize(
      blockerReferences: blockerReferences,
      affectedNodeIdReferences: affectedNodeIdReferences,
      largestAffectedNodeIdsPerBlocker: largestAffectedNodeIdsPerBlocker,
    );
  }

  @override
  String format(RunReport report) {
    final buffer = StringBuffer();
    writeTo(report, buffer);
    return buffer.toString();
  }

  /// Writes compact JSON directly to [sink] without first creating one large
  /// intermediate string.
  @override
  void writeTo(RunReport report, StringSink sink) {
    preflight(report);
    if (version == 2) {
      _writeV2(report, sink);
      return;
    }

    final output = _serializeV3(report);
    final encoder = const JsonEncoder().startChunkedConversion(
      StringConversionSink.fromStringSink(sink),
    );
    encoder
      ..add(output)
      ..close();
  }

  Map<String, Object?> _serializeV3(RunReport report) {
    _preflightV3Contexts(report);
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
        auxiliaryExecutionTargets: report.auxiliaryExecutionTargets,
        auxiliaryExecutionTargetIssues: report.auxiliaryExecutionTargetIssues,
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

  void _writeV2(RunReport report, StringSink sink) {
    final writer = _CompactJsonWriter(sink);
    final findings = report.findings;
    var safe = 0;
    var high = 0;
    var review = 0;
    var protected = 0;
    var totalSourceBytes = 0;
    for (final finding in findings) {
      switch (finding.confidence) {
        case Confidence.safe:
          safe++;
        case Confidence.high:
          high++;
        case Confidence.review:
          review++;
        case Confidence.protected:
          protected++;
      }
      totalSourceBytes += finding.sourceBytes ?? 0;
    }

    writer
      ..beginObject()
      ..key('version')
      ..scalar(2)
      ..comma()
      ..key('timestamp')
      ..scalar(report.identity.finishedAtUtc.toIso8601String())
      ..comma()
      ..key('analysisCoverage');
    _writeV2Coverage(writer, report.targetMatrix, report.rootCoverage);
    writer
      ..comma()
      ..key('summary')
      ..beginObject()
      ..key('total')
      ..scalar(findings.length)
      ..comma()
      ..key('safe')
      ..scalar(safe)
      ..comma()
      ..key('high')
      ..scalar(high)
      ..comma()
      ..key('review')
      ..scalar(review)
      ..comma()
      ..key('protected')
      ..scalar(protected)
      ..comma()
      ..key('totalSourceBytes')
      ..scalar(totalSourceBytes)
      ..endObject()
      ..comma()
      ..key('findings')
      ..beginArray();
    for (var index = 0; index < findings.length; index++) {
      if (index > 0) writer.comma();
      _writeV2Finding(writer, findings[index]);
    }
    writer
      ..endArray()
      ..endObject();
  }

  void _writeV2Coverage(
    _CompactJsonWriter writer,
    TargetMatrix targetMatrix,
    RootCoverage rootCoverage,
  ) {
    writer
      ..beginObject()
      ..key('targetMatrix')
      ..beginObject()
      ..key('status')
      ..scalar(targetMatrix.status.name)
      ..comma()
      ..key('complete')
      ..scalar(targetMatrix.isComplete)
      ..comma()
      ..key('source')
      ..scalar(targetMatrix.source)
      ..comma()
      ..key('issues');
    _writeV2Strings(writer, targetMatrix.issues);
    writer
      ..comma()
      ..key('targets')
      ..beginArray();
    for (var index = 0; index < targetMatrix.targets.length; index++) {
      if (index > 0) writer.comma();
      final target = targetMatrix.targets[index];
      writer
        ..beginObject()
        ..key('name')
        ..scalar(target.name)
        ..comma()
        ..key('platform')
        ..scalar(target.platform)
        ..comma()
        ..key('entrypoint')
        ..scalar(target.entrypoint);
      if (target.flavor != null) {
        writer
          ..comma()
          ..key('flavor')
          ..scalar(target.flavor);
      }
      writer
        ..comma()
        ..key('dartDefines')
        ..beginObject();
      var firstDefine = true;
      for (final entry in target.dartDefines.entries) {
        if (!firstDefine) writer.comma();
        firstDefine = false;
        writer
          ..key(entry.key)
          ..scalar(entry.value);
      }
      writer
        ..endObject()
        ..endObject();
    }
    writer
      ..endArray()
      ..endObject()
      ..comma()
      ..key('roots')
      ..beginObject()
      ..key('mode')
      ..scalar(rootCoverage.mode.name)
      ..comma()
      ..key('complete')
      ..scalar(rootCoverage.complete)
      ..comma()
      ..key('source')
      ..scalar(rootCoverage.source)
      ..comma()
      ..key('publicEntrypoints');
    _writeV2Strings(writer, rootCoverage.publicEntrypoints);
    writer
      ..comma()
      ..key('issues');
    _writeV2Strings(writer, rootCoverage.issues);
    writer
      ..endObject()
      ..endObject();
  }

  void _writeV2Finding(_CompactJsonWriter writer, Finding finding) {
    final node = finding.node;
    final whyNotSafe = _v2WhyNotSafe(finding);
    writer
      ..beginObject()
      ..key('ruleId')
      ..scalar(finding.ruleId)
      ..comma()
      ..key('confidence')
      ..scalar(finding.confidence.label)
      ..comma()
      ..key('title')
      ..scalar(finding.title)
      ..comma()
      ..key('node')
      ..beginObject()
      ..key('id')
      ..scalar(node.id)
      ..comma()
      ..key('kind')
      ..scalar(node.kind.name)
      ..comma()
      ..key('displayName')
      ..scalar(node.displayName)
      ..comma()
      ..key('origin')
      ..scalar(node.origin.toString())
      ..endObject()
      ..comma()
      ..key('predicates');
    _writeV2Predicates(writer, finding);
    writer
      ..comma()
      ..key('classificationReasons');
    _writeV2Strings(
      writer,
      finding.classificationReasons.map((reason) => reason.code),
    );
    writer
      ..comma()
      ..key('unreachableIn');
    _writeV2Strings(writer, finding.unreachableIn);
    writer
      ..comma()
      ..key('reachableIn');
    _writeV2Strings(writer, finding.reachableIn);
    if (finding.protectionReasons.isNotEmpty) {
      writer
        ..comma()
        ..key('protectionReasons');
      _writeV2Strings(writer, finding.protectionReasons);
    }
    if (finding.blockers.isNotEmpty) {
      writer
        ..comma()
        ..key('blockers')
        ..beginArray();
      for (var index = 0; index < finding.blockers.length; index++) {
        if (index > 0) writer.comma();
        _writeV2Blocker(writer, finding.blockers[index]);
      }
      writer.endArray();
    }
    if (finding.evidence.isNotEmpty) {
      writer
        ..comma()
        ..key('evidence')
        ..beginArray();
      for (var index = 0; index < finding.evidence.length; index++) {
        if (index > 0) writer.comma();
        _writeV2Evidence(writer, finding.evidence[index]);
      }
      writer.endArray();
    }
    if (finding.proposedAction != null) {
      writer
        ..comma()
        ..key('proposedAction')
        ..scalar(finding.proposedAction);
    }
    if (finding.sourceBytes != null) {
      writer
        ..comma()
        ..key('sourceBytes')
        ..scalar(finding.sourceBytes);
    }
    if (whyNotSafe != null) {
      writer
        ..comma()
        ..key('whyNotSafe')
        ..scalar(whyNotSafe);
    }
    writer.endObject();
  }

  void _writeV2Predicates(_CompactJsonWriter writer, Finding finding) {
    final predicates = finding.predicates;
    writer
      ..beginObject()
      ..key('ruleAllowsAutoFix')
      ..scalar(predicates.ruleAllowsAutoFix)
      ..comma()
      ..key('unreachableAcrossAllTargets')
      ..scalar(predicates.unreachableAcrossAllTargets)
      ..comma()
      ..key('noDynamicBlockers')
      ..scalar(predicates.noDynamicBlockers)
      ..comma()
      ..key('notProtected')
      ..scalar(predicates.notProtected)
      ..comma()
      ..key('noPublicApiRisk')
      ..scalar(predicates.noPublicApiRisk)
      ..comma()
      ..key('hasDeterministicInverse')
      ..scalar(predicates.hasDeterministicInverse)
      ..comma()
      ..key('analysisCoverageComplete')
      ..scalar(predicates.analysisCoverageComplete)
      ..comma()
      ..key('actionSupported')
      ..scalar(predicates.actionSupported)
      ..endObject();
  }

  void _writeV2Blocker(_CompactJsonWriter writer, Blocker blocker) {
    writer
      ..beginObject()
      ..key('producer')
      ..scalar(blocker.producer)
      ..comma()
      ..key('reason')
      ..scalar(blocker.reason);
    if (blocker.location != null) {
      writer
        ..comma()
        ..key('location')
        ..scalar(blocker.location);
    }
    if (blocker.sourceNodeId != null) {
      writer
        ..comma()
        ..key('sourceNodeId')
        ..scalar(blocker.sourceNodeId);
    }
    if (blocker.affectedNamespace != null) {
      writer
        ..comma()
        ..key('affectedNamespace')
        ..scalar(blocker.affectedNamespace);
    }
    if (blocker.affectedNodeIds.isNotEmpty) {
      final affectedNodeIds = blocker.affectedNodeIds.toList()..sort();
      writer
        ..comma()
        ..key('affectedNodeIds');
      _writeV2Strings(writer, affectedNodeIds);
    }
    writer.endObject();
  }

  void _writeV2Evidence(_CompactJsonWriter writer, Evidence evidence) {
    writer
      ..beginObject()
      ..key('kind')
      ..scalar(evidence.kind.name)
      ..comma()
      ..key('producer')
      ..scalar(evidence.producer)
      ..comma()
      ..key('description')
      ..scalar(evidence.description)
      ..comma()
      ..key('exact')
      ..scalar(evidence.exact);
    if (evidence.location != null) {
      writer
        ..comma()
        ..key('location')
        ..scalar(evidence.location);
    }
    writer.endObject();
  }

  void _writeV2Strings(_CompactJsonWriter writer, Iterable<String> values) {
    writer.beginArray();
    var first = true;
    for (final value in values) {
      if (!first) writer.comma();
      first = false;
      writer.scalar(value);
    }
    writer.endArray();
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
      'integrityByExecutionTarget': {
        for (final entry
            in (pass.integrityByExecutionTarget.entries.toList()
              ..sort((left, right) => left.key.compareTo(right.key))))
          entry.key: _serializeExecutionTargetIntegrity(
            entry.value,
            contextId: entry.key,
          ),
        'unattributed': _serializeExecutionTargetIntegrity(
          pass.unattributedIntegrity,
          contextId: 'unattributed',
        ),
      },
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

  void _preflightV3Contexts(RunReport report) {
    final configuredIds = <String>{};
    for (final target in report.targetMatrix.targets) {
      final id = configuredExecutionContextId(target.name);
      if (!configuredIds.add(id)) {
        throw StateError('duplicate JSON v3 configured execution context: $id');
      }
    }

    for (final pass in report.analysisPasses) {
      final expectedIds = <String>{...configuredIds};
      for (final target in pass.auxiliaryExecutionTargets) {
        validateAuxiliaryExecutionContextId(target.id, target.domain);
        if (!expectedIds.add(target.id)) {
          throw StateError(
            'duplicate JSON v3 auxiliary execution context: ${target.id}',
          );
        }
      }
      final observedIds = pass.integrityByExecutionTarget.keys.toSet();
      if (observedIds.contains('unattributed') ||
          observedIds.length != pass.integrityByExecutionTarget.length ||
          !_sameStrings(observedIds, expectedIds)) {
        throw StateError('incomplete JSON v3 execution-context inventory');
      }
    }
  }

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
        'predicates': _serializePredicatesV3(finding),
        'classificationReasons': finding.classificationReasons
            .map((reason) => reason.code)
            .toList(),
        'unreachableIn': finding.unreachableIn,
        'reachableIn': finding.reachableIn,
        'retainedIn': finding.retainedIn,
        'auxiliaryRetainedIn': finding.auxiliaryRetainedIn,
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
    List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets = const [],
    List<AuxiliaryExecutionTargetRegistryIssue> auxiliaryExecutionTargetIssues =
        const [],
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
    'auxiliaryExecutionTargets':
        (auxiliaryExecutionTargets.toList()
              ..sort((left, right) => left.id.compareTo(right.id)))
            .map(_serializeAuxiliaryExecutionTarget)
            .toList(),
    'auxiliaryExecutionTargetIssues':
        (auxiliaryExecutionTargetIssues.toList()..sort((left, right) {
              final id = left.id.compareTo(right.id);
              if (id != 0) return id;
              final accepted = left.acceptedDefinitionSha256.compareTo(
                right.acceptedDefinitionSha256,
              );
              return accepted != 0
                  ? accepted
                  : left.rejectedDefinitionSha256.compareTo(
                      right.rejectedDefinitionSha256,
                    );
            }))
            .map(
              (issue) => {
                'id': issue.id,
                'acceptedDefinitionSha256': issue.acceptedDefinitionSha256,
                'rejectedDefinitionSha256': issue.rejectedDefinitionSha256,
                'reason': _sanitizeReportReason(issue.reason),
              },
            )
            .toList(),
  };

  Map<String, Object?> _serializeAuxiliaryExecutionTarget(
    AuxiliaryExecutionTarget target,
  ) => {
    'id': target.id,
    'domain': target.domain.name,
    'environmentValues': _sortedMap(target.environmentValues),
    'environmentComplete': target.environmentComplete,
    'reason': _sanitizeReportReason(target.reason),
    if (target.sourceConfiguredTarget case final sourceTarget?)
      'sourceConfiguredTarget': {
        'name': sourceTarget.name,
        'platform': sourceTarget.platform,
        'entrypoint': sourceTarget.entrypoint,
        if (sourceTarget.flavor != null) 'flavor': sourceTarget.flavor,
        'dartDefines': _sortedMap(sourceTarget.dartDefines),
      },
  };

  Map<String, Object?> _serializeExecutionTargetIntegrity(
    ExecutionTargetIntegrityReport integrity, {
    required String contextId,
  }) {
    final incompleteReasons =
        integrity.incompleteReasons
            .map(_sanitizeReportReason)
            .where((reason) => reason.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    final expectedDomain = _integrityDomainFor(contextId);
    final expectedComplete =
        integrity.danglingEdgeCount == 0 &&
        integrity.danglingRootCount == 0 &&
        incompleteReasons.isEmpty;
    if (integrity.id != contextId ||
        integrity.domain != expectedDomain ||
        integrity.danglingEdgeCount < 0 ||
        integrity.danglingRootCount < 0 ||
        incompleteReasons.length != integrity.incompleteReasons.length ||
        integrity.incompleteReasons.any(
          (reason) => _sanitizeReportReason(reason).isEmpty,
        ) ||
        integrity.complete != expectedComplete) {
      throw StateError('invalid JSON v3 execution-target integrity record');
    }
    return {
      'id': integrity.id,
      'domain': integrity.domain,
      'complete': integrity.complete,
      'danglingEdges': integrity.danglingEdgeCount,
      'danglingRoots': integrity.danglingRootCount,
      'incompleteReasons': incompleteReasons,
    };
  }

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
      'predicates': _serializePredicatesV3(finding),
      'classificationReasons': finding.classificationReasons
          .map((reason) => reason.code)
          .toList(),
      'manualRiskCodes': finding.manualRisks.map((risk) => risk.code).toList()
        ..sort(),
      'applyEligible': ModeApplyPolicy.allows(analysisMode, finding),
      'unreachableIn': finding.unreachableIn,
      'reachableIn': finding.reachableIn,
      'retainedIn': finding.retainedIn,
      'auxiliaryRetainedIn': finding.auxiliaryRetainedIn,
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

  Map<String, bool> _serializePredicatesV3(Finding finding) => {
    'ruleAllowsAutoFix': finding.predicates.ruleAllowsAutoFix,
    'unreachableAcrossAllTargets':
        finding.predicates.unreachableAcrossAllTargets,
    'notRetained': finding.predicates.notRetained,
    'noDynamicBlockers': finding.predicates.noDynamicBlockers,
    'notProtected': finding.predicates.notProtected,
    'noPublicApiRisk': finding.predicates.noPublicApiRisk,
    'hasDeterministicInverse': finding.predicates.hasDeterministicInverse,
    'analysisCoverageComplete': finding.predicates.analysisCoverageComplete,
    'actionSupported': finding.predicates.actionSupported,
  };

  String? _v2WhyNotSafe(Finding finding) {
    if (finding.confidence == Confidence.safe) return null;
    final predicates = finding.predicates;
    final failed = <String>[
      if (!predicates.ruleAllowsAutoFix) 'rule not on auto-fix allowlist',
      if (!predicates.unreachableAcrossAllTargets)
        'reachable in at least one target',
      if (!predicates.noDynamicBlockers)
        'an unresolved dynamic construct could match',
      if (!predicates.notProtected) 'node is protected',
      if (!predicates.noPublicApiRisk)
        'node may be part of a public API surface',
      if (!predicates.hasDeterministicInverse)
        'edit is not reversibly invertible',
      if (!predicates.analysisCoverageComplete)
        'analysis target/root coverage is incomplete',
      if (!predicates.actionSupported) 'no supported apply action exists',
    ];
    return failed.isEmpty ? null : failed.join('; ');
  }

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

  String _sanitizeReportReason(String value) => value
      .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  String _integrityDomainFor(String contextId) {
    try {
      return executionContextDomain(contextId, allowUnattributed: true);
    } on ArgumentError {
      throw StateError('invalid JSON v3 execution-target integrity context');
    }
  }

  bool _sameStrings(Set<String> left, Set<String> right) =>
      left.length == right.length && left.containsAll(right);

  Map<String, T> _sortedMap<T>(Map<String, T> input) => Map.fromEntries(
    input.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
}

final class _CompactJsonWriter {
  _CompactJsonWriter(this.sink);

  final StringSink sink;

  void beginObject() => sink.write('{');

  void endObject() => sink.write('}');

  void beginArray() => sink.write('[');

  void endArray() => sink.write(']');

  void comma() => sink.write(',');

  void colon() => sink.write(':');

  void scalar(Object? value) => sink.write(jsonEncode(value));

  void key(String value) {
    scalar(value);
    colon();
  }
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
