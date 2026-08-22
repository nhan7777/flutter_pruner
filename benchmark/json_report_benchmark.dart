import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('findings', defaultsTo: '500')
    ..addOption('blockers', defaultsTo: '1000')
    ..addOption('iterations', defaultsTo: '3')
    ..addOption('warmup', defaultsTo: '1')
    ..addOption('json-version', defaultsTo: '3')
    ..addOption('affected-node-ids-per-blocker', defaultsTo: '0')
    ..addFlag('expect-v2-preflight-rejection');
  final options = parser.parse(arguments);
  final findingCount = int.parse(options.option('findings')!);
  final blockerCount = int.parse(options.option('blockers')!);
  final iterations = int.parse(options.option('iterations')!);
  final warmup = int.parse(options.option('warmup')!);
  final jsonVersion = int.parse(options.option('json-version')!);
  final affectedNodeIdsPerBlocker = int.parse(
    options.option('affected-node-ids-per-blocker')!,
  );
  final expectV2PreflightRejection = options.flag(
    'expect-v2-preflight-rejection',
  );
  if (findingCount < 1 ||
      blockerCount < 1 ||
      iterations < 1 ||
      warmup < 0 ||
      affectedNodeIdsPerBlocker < 0) {
    throw ArgumentError(
      'findings, blockers, and iterations must be positive; warmup and '
      'affected-node-ids-per-blocker must be non-negative',
    );
  }
  if (jsonVersion != 2 && jsonVersion != 3) {
    throw ArgumentError('--json-version must be 2 or 3');
  }
  if (expectV2PreflightRejection && jsonVersion != 2) {
    throw ArgumentError(
      '--expect-v2-preflight-rejection requires --json-version 2',
    );
  }

  final report = _report(findingCount, blockerCount, affectedNodeIdsPerBlocker);
  final formatter = JsonFormatter(version: jsonVersion);
  final blockerFindingLinks = findingCount * blockerCount;
  final affectedNodeIdReferences =
      blockerFindingLinks * affectedNodeIdsPerBlocker;
  if (expectV2PreflightRejection) {
    try {
      formatter.preflight(report);
    } on JsonV2CompatibilityLimitException catch (error) {
      _writePreflightRejection(
        jsonVersion: jsonVersion,
        findingCount: findingCount,
        blockerCount: blockerCount,
        affectedNodeIdsPerBlocker: affectedNodeIdsPerBlocker,
        blockerFindingLinks: blockerFindingLinks,
        affectedNodeIdReferences: affectedNodeIdReferences,
        warmup: warmup,
        iterations: iterations,
        error: error,
      );
      return;
    }
    throw StateError('expected JSON v2 preflight rejection, but it succeeded');
  }
  for (var index = 0; index < warmup; index++) {
    _serializeAndCount(formatter, report);
  }

  final elapsedMicros = <int>[];
  var reportBytes = 0;
  for (var index = 0; index < iterations; index++) {
    final stopwatch = Stopwatch()..start();
    reportBytes = _serializeAndCount(formatter, report);
    stopwatch.stop();
    elapsedMicros.add(stopwatch.elapsedMicroseconds);
  }
  elapsedMicros.sort();

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'dartVersion': Platform.version,
      'processors': Platform.numberOfProcessors,
      'jsonVersion': jsonVersion,
      'findings': findingCount,
      'uniqueBlockers': blockerCount,
      'blockerFindingLinks': blockerFindingLinks,
      'affectedNodeIdsPerBlocker': affectedNodeIdsPerBlocker,
      'affectedNodeIdReferences': affectedNodeIdReferences,
      'preflightRejected': false,
      'warmup': warmup,
      'iterations': iterations,
      'completedIterations': iterations,
      'medianElapsedMicros': elapsedMicros[elapsedMicros.length ~/ 2],
      'minElapsedMicros': elapsedMicros.first,
      'maxElapsedMicros': elapsedMicros.last,
      'reportBytes': reportBytes,
      'samples': elapsedMicros,
    }),
  );
}

int _serializeAndCount(JsonFormatter formatter, RunReport report) {
  final sink = Utf8CountingSink();
  formatter.writeTo(report, sink);
  return sink.finish();
}

void _writePreflightRejection({
  required int jsonVersion,
  required int findingCount,
  required int blockerCount,
  required int affectedNodeIdsPerBlocker,
  required int blockerFindingLinks,
  required int affectedNodeIdReferences,
  required int warmup,
  required int iterations,
  required JsonV2CompatibilityLimitException error,
}) {
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'dartVersion': Platform.version,
      'processors': Platform.numberOfProcessors,
      'jsonVersion': jsonVersion,
      'findings': findingCount,
      'uniqueBlockers': blockerCount,
      'blockerFindingLinks': blockerFindingLinks,
      'affectedNodeIdsPerBlocker': affectedNodeIdsPerBlocker,
      'affectedNodeIdReferences': affectedNodeIdReferences,
      'preflightRejected': true,
      'rejectionLimit': {
        'name': error.limitName,
        'limit': error.limit,
        'observed': error.observed,
      },
      'requestedWarmup': warmup,
      'requestedIterations': iterations,
      'completedIterations': 0,
      'samples': const <int>[],
    }),
  );
}

/// Counts UTF-8 output incrementally without retaining report text.
///
/// A high surrogate can be the final code unit of one write and its matching
/// low surrogate the first code unit of the next. It is held only until the
/// next code unit so the pair is counted as one four-byte scalar.
final class Utf8CountingSink implements StringSink {
  int _byteLength = 0;
  int? _pendingHighSurrogate;
  bool _finished = false;

  /// Returns the complete byte count after flushing any unmatched surrogate.
  int finish() {
    if (!_finished) {
      _flushPendingHighSurrogate();
      _finished = true;
    }
    return _byteLength;
  }

  void _writeCodeUnit(int codeUnit) {
    final pendingHighSurrogate = _pendingHighSurrogate;
    if (pendingHighSurrogate != null) {
      if (codeUnit >= 0xdc00 && codeUnit <= 0xdfff) {
        _byteLength += 4;
        _pendingHighSurrogate = null;
        return;
      }
      _byteLength += 3;
      _pendingHighSurrogate = null;
    }
    if (codeUnit >= 0xd800 && codeUnit <= 0xdbff) {
      _pendingHighSurrogate = codeUnit;
    } else if (codeUnit <= 0x7f) {
      _byteLength++;
    } else if (codeUnit <= 0x7ff) {
      _byteLength += 2;
    } else {
      _byteLength += 3;
    }
  }

  void _flushPendingHighSurrogate() {
    if (_pendingHighSurrogate != null) {
      _byteLength += 3;
      _pendingHighSurrogate = null;
    }
  }

  @override
  void write(Object? object) {
    if (_finished) throw StateError('Cannot write after finish.');
    for (final codeUnit in object.toString().codeUnits) {
      _writeCodeUnit(codeUnit);
    }
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    if (_finished) throw StateError('Cannot write after finish.');
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      write(object);
      first = false;
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }
}

RunReport _report(
  int findingCount,
  int blockerCount,
  int affectedNodeIdsPerBlocker,
) {
  final blockers = List<Blocker>.generate(
    blockerCount,
    (index) => Blocker(
      producer: 'synthetic',
      reason: 'unresolved reference ${index.toString().padLeft(6, '0')}',
      location: 'lib/generated_fixture.dart',
      affectedNamespace: 'dart:synthetic/',
      affectedNodeIds: {
        for (var idIndex = 0; idIndex < affectedNodeIdsPerBlocker; idIndex++)
          'dart:synthetic/affected_${index.toString().padLeft(6, '0')}_'
              '${idIndex.toString().padLeft(6, '0')}',
      },
    ),
    growable: false,
  );
  final findings = List<Finding>.generate(
    findingCount,
    (index) => Finding(
      ruleId: 'PRN-SYNTHETIC-001',
      node: GraphNode(
        id: 'dart:synthetic/declaration_${index.toString().padLeft(6, '0')}',
        kind: NodeKind.declaration,
        origin: Uri.file('/synthetic/lib/generated_fixture.dart'),
      ),
      confidence: Confidence.review,
      title: 'Synthetic unresolved declaration',
      predicates: const SafetyPredicates(
        ruleAllowsAutoFix: true,
        unreachableAcrossAllTargets: true,
        noDynamicBlockers: false,
        notProtected: true,
        noPublicApiRisk: true,
        hasDeterministicInverse: true,
      ),
      blockers: blockers,
      reportingAdapterId: 'synthetic',
    ),
    growable: false,
  );
  final statistics = FindingStatistics.fromFindings(findings);
  final pass = AnalysisPassReport(
    id: 'analysis-001',
    purpose: AnalysisPassPurpose.initial,
    elapsedMicros: 1,
    nodeCount: findingCount,
    edgeCount: 0,
    rootCount: 0,
    recordedBlockerCount: blockerCount,
    danglingEdgeCount: 0,
    integrityByExecutionTarget: {
      'app:synthetic': ExecutionTargetIntegrityReport(
        id: 'app:synthetic',
        domain: 'configuredTarget',
        complete: true,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
      ),
    },
    adapterRuns: [
      AdapterRunReport(
        id: 'synthetic',
        name: 'Synthetic report benchmark',
        role: AdapterRunRole.reporting,
        status: AdapterRunStatus.executed,
        elapsedMicros: 1,
        nodesAdded: findingCount,
        edgesAdded: 0,
        blockersAdded: blockerCount,
      ),
    ],
    findingStatistics: statistics,
    blockerStatistics: BlockerStatistics(
      recorded: blockerCount,
      activeUnique: blockerCount,
      affectedFindings: findingCount,
      byProducer: {'synthetic': blockerCount},
    ),
    measurements: const [],
    exclusionPolicyVersion: 1,
    exclusionsByReason: const {},
  );
  return RunReport(
    identity: RunIdentity(
      id: 'synthetic-json-report',
      command: RunCommand.scan,
      toolVersion: 'benchmark',
      startedAtUtc: DateTime.utc(2026),
      finishedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/synthetic',
    packageName: 'synthetic',
    requestedAdapters: const ['synthetic'],
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'synthetic',
        platform: 'test',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: [pass],
    findings: findings,
    diagnostics: const [],
  );
}
