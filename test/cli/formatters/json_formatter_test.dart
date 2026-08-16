import 'dart:convert';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  test('v3 separates typed measurements and duplicate details', () {
    final rendered = const JsonFormatter().format(_report());
    expect(rendered, isNot(contains('\x1B[')));
    final output = jsonDecode(rendered) as Map;

    expect(output['version'], 3);
    final coverage = output['analysisCoverage'] as Map;
    expect(coverage['analysisMode'], 'application');
    expect((coverage['roots'] as Map)['internalBoundaryComplete'], isTrue);
    expect((coverage['roots'] as Map)['externalConsumersCovered'], isTrue);
    final graph =
        (((output['execution'] as Map)['analysisPasses'] as List).single
                as Map)['graph']
            as Map;
    expect(graph['danglingEdges'], 0);
    expect(graph['danglingRoots'], 2);
    expect(
      (output['statistics'] as Map).containsKey('totalSourceBytes'),
      isFalse,
    );
    final measurements = (output['statistics'] as Map)['measurements'] as List;
    expect((measurements.single as Map)['value'], 4);
    expect((measurements.single as Map)['adapterId'], 'duplicates');
    final finding = (output['findings'] as List).single as Map;
    expect(finding['reportingAdapterId'], 'duplicates');
    expect(finding['manualRiskCodes'], isEmpty);
    expect(finding['applyEligible'], isFalse);
    expect((finding['details'] as Map)['paths'], [
      'assets/a.png',
      'assets/b.png',
    ]);
  });

  test('v2 compatibility retains legacy selectors for one cycle', () {
    final output =
        jsonDecode(const JsonFormatter(version: 2).format(_report())) as Map;

    expect(output['version'], 2);
    final summary = output['summary'] as Map;
    expect(summary['safe'], 0);
    expect(summary['review'], 1);
    expect(summary['totalSourceBytes'], 4);
    expect(output.containsKey('presentation'), isFalse);
    expect(
      (output['analysisCoverage'] as Map).containsKey('analysisMode'),
      isFalse,
    );
  });

  test('v3 snapshots adapter-scoped typed presentation metadata', () {
    final output =
        jsonDecode(const JsonFormatter().format(_presentationReport()))
            as Map<String, Object?>;

    final presentation = output['presentation'] as Map<String, Object?>;
    final adapters = (presentation['adapters'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(adapters.map((adapter) => adapter['id']), ['locales', 'routes']);
    final routes = adapters.singleWhere((adapter) => adapter['id'] == 'routes');
    expect(routes['displayName'], 'Route catalog');
    expect(routes['description'], 'Route-specific report copy.');
    final routePresentation =
        (routes['findings'] as List<Object?>).single as Map<String, Object?>;
    expect(routePresentation['ruleId'], 'PRN-ROUTE-001');
    expect(routePresentation['title'], 'Unlinked destination');
    expect((routePresentation['details'] as List).single, {
      'key': 'sharedDetail',
      'label': 'Route payload bytes',
      'valueType': 'bytes',
      'description': 'Serialized route payload size.',
    });

    final findings = (output['findings'] as List<Object?>)
        .cast<Map<String, Object?>>();
    final routeFinding = findings.singleWhere(
      (finding) => finding['reportingAdapterId'] == 'routes',
    );
    final localeFinding = findings.singleWhere(
      (finding) => finding['reportingAdapterId'] == 'locales',
    );
    expect(routeFinding['details'], {'sharedDetail': 128});
    expect(localeFinding['details'], {'sharedDetail': 2});
    expect((routeFinding['measurements'] as List).single, {
      'kind': 'route-source-bytes',
      'status': 'measured',
      'unit': 'bytes',
      'value': 128,
    });
    final measurements = (output['statistics'] as Map)['measurements'] as List;
    expect((measurements.single as Map)['adapterId'], 'routes');

    final v2 =
        jsonDecode(
              const JsonFormatter(version: 2).format(_presentationReport()),
            )
            as Map;
    expect(v2.containsKey('presentation'), isFalse);
  });

  test('v3 preserves apply outcomes independently of final findings', () {
    final output =
        jsonDecode(
              const JsonFormatter().format(_report(withApplyOutcome: true)),
            )
            as Map;

    expect(output['findings'], isEmpty);
    final outcomes = (output['apply'] as Map)['findingOutcomes'] as List;
    expect((output['apply'] as Map)['authorization'], {
      'acceptedRiskCodes': ['external-consumers-not-scanned'],
      'source': 'yesFlag',
    });
    final outcome = outcomes.single as Map;
    expect(outcome['findingId'], 'duplicate:test:abc');
    expect(outcome['status'], 'blocked');
    expect(outcome['reasonCode'], 'retained_consumer');
    expect(outcome['rollbackVerified'], isNull);
    expect(outcome['relatedNodeIds'], ['consumer:a', 'consumer:z']);
    final finding = outcome['finding'] as Map;
    expect(finding['title'], 'duplicate');
    expect(((finding['node'] as Map)['projectRelativeOrigin']), 'assets/a.png');
  });
}

RunReport _report({bool withApplyOutcome = false}) {
  final finding = Finding(
    ruleId: 'PRN-DUP-001',
    node: GraphNode(
      id: 'duplicate:test:abc',
      kind: NodeKind.duplicateGroup,
      origin: Uri.file('/project/assets/a.png'),
      sizeBytes: 4,
      metadata: const {
        'paths': ['assets/b.png', 'assets/a.png'],
        'fileCount': 2,
        'sizePerFile': 4,
      },
    ),
    confidence: Confidence.review,
    title: 'duplicate',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
    ),
    reportingAdapterId: 'duplicates',
    sourceBytes: 4,
  );
  final statistics = FindingStatistics.fromFindings([finding]);
  final pass = AnalysisPassReport(
    id: 'analysis-001',
    purpose: AnalysisPassPurpose.initial,
    elapsedMicros: 10,
    nodeCount: 1,
    edgeCount: 0,
    rootCount: 0,
    recordedBlockerCount: 0,
    danglingEdgeCount: 0,
    danglingRootCount: 2,
    adapterRuns: const [
      AdapterRunReport(
        id: 'duplicates',
        name: 'Duplicate detector',
        role: AdapterRunRole.reporting,
        status: AdapterRunStatus.executed,
        elapsedMicros: 10,
        nodesAdded: 1,
        edgesAdded: 0,
        blockersAdded: 0,
      ),
    ],
    findingStatistics: statistics,
    blockerStatistics: BlockerStatistics(
      recorded: 0,
      activeUnique: 0,
      affectedFindings: 0,
      byProducer: {},
    ),
    measurements: const [
      RunMeasurement(
        kind: 'duplicate-potential-reclaimable-bytes',
        adapterId: 'duplicates',
        status: MeasurementStatus.measured,
        unit: 'bytes',
        scope: 'duplicate-inventory',
        aggregation: 'within-duplicate-groups-only',
        value: 4,
        knownCount: 1,
      ),
    ],
    exclusionPolicyVersion: 1,
    exclusionsByReason: const {},
  );
  return RunReport(
    identity: RunIdentity(
      id: 'run-test',
      command: withApplyOutcome ? RunCommand.apply : RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: const ['duplicates'],
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: [pass],
    findings: withApplyOutcome ? const [] : [finding],
    diagnostics: const [],
    acceptedRiskCodes: withApplyOutcome
        ? const ['external-consumers-not-scanned']
        : const [],
    riskAcceptanceSource: withApplyOutcome
        ? RiskAcceptanceSource.yesFlag
        : RiskAcceptanceSource.notRequired,
    applyFindingOutcomes: withApplyOutcome
        ? [
            ApplyFindingOutcome(
              finding: finding,
              status: ApplyFindingOutcomeStatus.blocked,
              reasonCode: 'retained_consumer',
              reason: 'A retained consumer still references this finding.',
              relatedNodeIds: const ['consumer:z', 'consumer:a'],
            ),
          ]
        : const [],
    applyStatistics: withApplyOutcome
        ? const ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: 1,
            findingsSkippedDependency: 0,
            findingsRemaining: 1,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: 0,
            sourceBytesRemoved: 0,
          )
        : null,
  );
}

RunReport _presentationReport() {
  final route = _presentationFinding(
    id: 'routes:test:/orphan',
    adapter: 'routes',
    kind: NodeKind.route,
    sourceBytes: 128,
    metadata: const {'sharedDetail': 128, 'notPresented': 'discarded'},
  );
  final locale = _presentationFinding(
    id: 'locales:test:orphan',
    adapter: 'locales',
    kind: NodeKind.localizationKey,
    sourceBytes: 2,
    metadata: const {'sharedDetail': 2},
  );
  final statistics = FindingStatistics.fromFindings([route, locale]);
  return RunReport(
    identity: RunIdentity(
      id: 'presentation-test',
      command: RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: const ['routes', 'locales'],
    adapterReportDefinitions: [_localesDefinition, _routesDefinition],
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: [
      AnalysisPassReport(
        id: 'presentation-pass',
        purpose: AnalysisPassPurpose.initial,
        elapsedMicros: 1,
        nodeCount: 2,
        edgeCount: 0,
        rootCount: 0,
        recordedBlockerCount: 0,
        danglingEdgeCount: 0,
        adapterRuns: const [],
        findingStatistics: statistics,
        blockerStatistics: BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: {},
        ),
        measurements: const [
          RunMeasurement(
            kind: 'route-source-bytes',
            adapterId: 'routes',
            status: MeasurementStatus.measured,
            unit: 'bytes',
            value: 128,
            scope: 'route-findings',
            aggregation: 'sum',
          ),
        ],
        exclusionPolicyVersion: 1,
        exclusionsByReason: const {},
      ),
    ],
    findings: [route, locale],
    diagnostics: const [],
  );
}

Finding _presentationFinding({
  required String id,
  required String adapter,
  required NodeKind kind,
  required int sourceBytes,
  required Map<String, Object?> metadata,
}) => Finding(
  ruleId: adapter == 'routes' ? 'PRN-ROUTE-001' : 'PRN-LOCALE-001',
  node: GraphNode(
    id: id,
    kind: kind,
    origin: Uri.file('/project/lib/example.dart'),
    metadata: metadata,
  ),
  confidence: Confidence.review,
  title: adapter == 'routes' ? 'Unlinked destination' : 'Orphan locale',
  predicates: const SafetyPredicates(
    ruleAllowsAutoFix: false,
    unreachableAcrossAllTargets: true,
    noDynamicBlockers: true,
    notProtected: true,
    noPublicApiRisk: true,
    hasDeterministicInverse: false,
  ),
  reportingAdapterId: adapter,
  sourceBytes: sourceBytes,
);

final _routesDefinition = AdapterReportDefinition(
  adapterId: 'routes',
  displayName: 'Route catalog',
  description: 'Route-specific report copy.',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.route,
      ruleId: 'PRN-ROUTE-001',
      title: 'Unlinked destination',
      nodeLabel: 'Destination',
      description: 'A route with no observed navigation.',
      measurementKind: 'route-source-bytes',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Route payload bytes',
          valueType: AdapterReportDetailValueType.bytes,
          description: 'Serialized route payload size.',
        ),
      ],
    ),
  ],
  measurements: [
    AdapterReportMeasurementDefinition(
      kind: 'route-source-bytes',
      label: 'Route source bytes',
      unit: 'bytes',
    ),
  ],
);

final _localesDefinition = AdapterReportDefinition(
  adapterId: 'locales',
  displayName: 'Locale catalog',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.localizationKey,
      ruleId: 'PRN-LOCALE-001',
      title: 'Orphan locale',
      nodeLabel: 'Locale key',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Locale plural forms',
          valueType: AdapterReportDetailValueType.integer,
        ),
      ],
    ),
  ],
);
