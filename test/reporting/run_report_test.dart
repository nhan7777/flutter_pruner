import 'dart:io';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/reporting/run_clock.dart';
import 'package:flutter_pruner/src/reporting/run_id_generator.dart';
import 'package:flutter_pruner/src/reporting/run_recorder.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  test('finding statistics preserve ownership and null byte semantics', () {
    final statistics = FindingStatistics.fromFindings([
      _finding('asset:a', adapter: 'assets', confidence: Confidence.safe),
      _finding('dart:b', adapter: 'dart', confidence: Confidence.review),
    ]);

    expect(statistics.total, 2);
    expect(statistics.byTier['SAFE'], 1);
    expect(statistics.byTier['REVIEW'], 1);
    expect(statistics.byReportingAdapter, {'assets': 1, 'dart': 1});
    expect(statistics.byReportingAdapterAndTier['assets']?['SAFE'], 1);
  });

  test('apply transaction counters must form a terminal partition', () {
    expect(
      () => _applyStatistics(begun: 2, committed: 1).validate(),
      throwsStateError,
    );
    expect(
      () => _applyStatistics(begun: 2, committed: 1, rolledBack: 1).validate(),
      returnsNormally,
    );
  });

  test('apply outcome recovery claims require matching evidence', () {
    final finding = _finding(
      'dart:a',
      adapter: 'dart',
      confidence: Confidence.safe,
    );
    expect(
      () => ApplyFindingOutcome(
        finding: finding,
        status: ApplyFindingOutcomeStatus.rejectedRecovered,
        reasonCode: 'verification_regression',
        reason: 'Verification rejected the transaction.',
        transactionId: 'tx-1',
        rollbackVerified: false,
      ).validate(),
      throwsStateError,
    );
    expect(
      () => ApplyFindingOutcome(
        finding: finding,
        status: ApplyFindingOutcomeStatus.recoveryRequired,
        reasonCode: 'rollback_verification_failed',
        reason: 'Rollback could not be verified.',
        transactionId: 'tx-1',
        rollbackVerified: true,
      ).validate(),
      throwsStateError,
    );
  });

  test('apply selection snapshots scope and rejects expansion', () {
    final requested = <String>['finding-a'];
    final planned = <String>['finding-a'];
    final selection = ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: requested,
      plannedFindingIds: planned,
      planFingerprint: 'a' * 64,
    );

    requested.add('finding-b');
    planned.clear();

    expect(selection.requestedFindingIds, ['finding-a']);
    expect(selection.plannedFindingIds, ['finding-a']);
    expect(
      () => selection.requestedFindingIds.add('external'),
      throwsUnsupportedError,
    );
    expect(
      () => ApplySelectionReport(
        mode: FindingSelectionMode.exact,
        requestedFindingIds: const ['finding-a'],
        plannedFindingIds: const ['finding-b'],
        planFingerprint: 'b' * 64,
      ),
      throwsStateError,
    );
  });

  test(
    'run recorder uses monotonic elapsed time when wall clock moves back',
    () {
      final root = Directory.systemTemp.createTempSync('run_report_test_');
      addTearDown(() => root.deleteSync(recursive: true));
      final project = ProjectContext(
        root: root,
        pubspec: const {'name': 'test'},
        packageName: 'test',
        targets: [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
      );
      final clock = _FakeClock(
        times: [DateTime.utc(2026, 8, 14, 1), DateTime.utc(2026, 8, 14, 0)],
        monotonicValues: [100, 5100],
      );
      final recorder = RunRecorder(
        command: RunCommand.scan,
        requestedAdapters: const ['dart'],
        toolVersion: 'test',
        clock: clock,
        idGenerator: const _FixedIdGenerator(),
      );

      final report = recorder.finish(
        project: project,
        status: RunStatus.completed,
        exitCode: 0,
        findings: const [],
      );

      expect(report.identity.id, 'run-fixed');
      expect(report.identity.elapsedMicros, 5000);
      expect(
        report.identity.finishedAtUtc.isBefore(report.identity.startedAtUtc),
        isTrue,
      );
    },
  );

  test('run recorder snapshots adapter presentation at registration', () {
    final root = Directory.systemTemp.createTempSync('run_report_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final project = ProjectContext(
      root: root,
      pubspec: const {'name': 'test'},
      packageName: 'test',
      targets: [
        BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ],
    );
    final findingDefinitions = <AdapterFindingReportDefinition>[
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.route,
        ruleId: 'PRN-ROUTE-001',
        title: 'Unused route',
        nodeLabel: 'Route',
      ),
    ];
    final recorder = RunRecorder(
      command: RunCommand.scan,
      requestedAdapters: const ['routes'],
      toolVersion: 'test',
      clock: _FakeClock(
        times: [DateTime.utc(2026, 8, 14), DateTime.utc(2026, 8, 14, 0, 0, 1)],
        monotonicValues: [0, 1000000],
      ),
      idGenerator: const _FixedIdGenerator(),
    );

    recorder.registerAdapterReportDefinitions([
      AdapterReportDefinition(
        adapterId: 'routes',
        displayName: 'Route analyzer',
        findings: findingDefinitions,
      ),
    ]);
    findingDefinitions.clear();

    final report = recorder.finish(
      project: project,
      status: RunStatus.completed,
      exitCode: 0,
      findings: const [],
    );

    expect(report.adapterReportDefinitions.single.findings, hasLength(1));
    expect(
      report.adapterReportDefinitions.single.findings.single.ruleId,
      'PRN-ROUTE-001',
    );
  });

  test('analysis pass counts only target-applicable graph integrity gaps', () {
    final root = Directory.systemTemp.createTempSync('run_report_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final project = ProjectContext(
      root: root,
      pubspec: const {'name': 'test'},
      packageName: 'test',
      targets: [
        BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ],
    );
    final source = GraphNode(
      id: 'dart:test/lib/main.dart#main',
      kind: NodeKind.declaration,
      origin: Uri.file('${root.path}/lib/main.dart'),
    );
    final graph = ReachabilityGraph()
      ..addNode(source)
      ..addRoot(source.id, reason: 'entry point')
      ..addRoot(
        'dart:test/lib/web.dart#missingRoot',
        reason: 'web-only configured root',
        condition: BuildCondition(platforms: {'web'}),
      )
      ..addEdge(
        GraphEdge(
          from: source.id,
          to: 'dart:test/lib/web.dart#missing',
          kind: EdgeKind.references,
          condition: BuildCondition(platforms: {'web'}),
          evidence: const Evidence(
            kind: EvidenceKind.semanticReference,
            producer: 'dart',
            description: 'web-only unresolved graph node',
            exact: true,
          ),
        ),
      );
    final integrity = graph.integrityFor(project.targets);
    final snapshot = AnalysisSnapshot(
      project: project,
      graph: graph,
      graphIntegrity: integrity,
      findings: const [],
      adapterIds: const ['dart'],
      adapterRuns: const [],
      elapsedMicros: 1,
      exclusions: project.pathPolicy.snapshot(),
    );

    expect(graph.danglingEdges(), hasLength(1));
    expect(
      graph.danglingRootIdsFor([
        BuildTarget(name: 'web', platform: 'web', entrypoint: 'lib/main.dart'),
      ]),
      ['dart:test/lib/web.dart#missingRoot'],
    );
    final androidPass = snapshot.toPassReport(
      id: 'analysis-001',
      purpose: AnalysisPassPurpose.initial,
    );
    expect(androidPass.danglingEdgeCount, 1);
    expect(androidPass.danglingRootCount, 1);
    expect(
      androidPass.integrityByExecutionTarget.values.single.complete,
      isTrue,
    );
    expect(androidPass.unattributedIntegrity.complete, isFalse);
    expect(androidPass.unattributedIntegrity.danglingEdgeCount, 1);
    expect(androidPass.unattributedIntegrity.danglingRootCount, 1);

    graph.addRoot(
      'dart:test/lib/support.dart#missingRoot',
      reason: 'configured support root',
    );
    expect(
      snapshot
          .toPassReport(id: 'analysis-002', purpose: AnalysisPassPurpose.rescan)
          .danglingRootCount,
      1,
    );
  });
}

Finding _finding(
  String id, {
  required String adapter,
  required Confidence confidence,
}) => Finding(
  ruleId: 'TEST',
  node: GraphNode(
    id: id,
    kind: id.startsWith('asset:') ? NodeKind.asset : NodeKind.declaration,
    origin: Uri.file('/tmp/test'),
  ),
  confidence: confidence,
  title: id,
  predicates: const SafetyPredicates(
    ruleAllowsAutoFix: true,
    unreachableAcrossAllTargets: true,
    noDynamicBlockers: true,
    notProtected: true,
    noPublicApiRisk: true,
    hasDeterministicInverse: true,
  ),
  reportingAdapterId: adapter,
);

ApplyStatistics _applyStatistics({
  required int begun,
  int committed = 0,
  int rolledBack = 0,
}) => ApplyStatistics(
  rounds: 1,
  findingsCommitted: 0,
  findingsRejectedRecovered: 0,
  findingsBlocked: 0,
  findingsSkippedDependency: 0,
  findingsRemaining: 0,
  actionsDeclared: 0,
  actionsCommitted: 0,
  actionsRolledBack: 0,
  actionsFailedRecovered: 0,
  transactionsBegun: begun,
  transactionsCommitted: committed,
  transactionsRolledBackVerified: rolledBack,
  transactionsRecoveryRequired: 0,
  transactionsNonTerminal: 0,
  verificationAttempts: 0,
  sourceBytesRemoved: 0,
);

class _FakeClock implements RunClock {
  _FakeClock({required this.times, required this.monotonicValues});

  final List<DateTime> times;
  final List<int> monotonicValues;

  @override
  int monotonicMicros() => monotonicValues.removeAt(0);

  @override
  DateTime nowUtc() => times.removeAt(0);
}

class _FixedIdGenerator implements RunIdGenerator {
  const _FixedIdGenerator();

  @override
  String next(DateTime startedAtUtc) => 'run-fixed';
}
