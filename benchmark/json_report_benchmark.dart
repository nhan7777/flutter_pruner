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
    ..addOption('warmup', defaultsTo: '1');
  final options = parser.parse(arguments);
  final findingCount = int.parse(options.option('findings')!);
  final blockerCount = int.parse(options.option('blockers')!);
  final iterations = int.parse(options.option('iterations')!);
  final warmup = int.parse(options.option('warmup')!);
  if (findingCount < 1 || blockerCount < 1 || iterations < 1 || warmup < 0) {
    throw ArgumentError(
      'findings, blockers, and iterations must be positive; warmup must be '
      'non-negative',
    );
  }

  final report = _report(findingCount, blockerCount);
  for (var index = 0; index < warmup; index++) {
    const JsonFormatter().format(report);
  }

  final elapsedMicros = <int>[];
  var reportBytes = 0;
  for (var index = 0; index < iterations; index++) {
    final stopwatch = Stopwatch()..start();
    final rendered = const JsonFormatter().format(report);
    stopwatch.stop();
    elapsedMicros.add(stopwatch.elapsedMicroseconds);
    reportBytes = utf8.encode(rendered).length;
  }
  elapsedMicros.sort();

  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'dartVersion': Platform.version,
      'processors': Platform.numberOfProcessors,
      'findings': findingCount,
      'uniqueBlockers': blockerCount,
      'blockerFindingLinks': findingCount * blockerCount,
      'warmup': warmup,
      'iterations': iterations,
      'medianElapsedMicros': elapsedMicros[elapsedMicros.length ~/ 2],
      'minElapsedMicros': elapsedMicros.first,
      'maxElapsedMicros': elapsedMicros.last,
      'reportBytes': reportBytes,
      'samples': elapsedMicros,
    }),
  );
}

RunReport _report(int findingCount, int blockerCount) {
  final blockers = List<Blocker>.generate(
    blockerCount,
    (index) => Blocker(
      producer: 'synthetic',
      reason: 'unresolved reference ${index.toString().padLeft(6, '0')}',
      location: 'lib/generated_fixture.dart',
      affectedNamespace: 'dart:synthetic/',
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
