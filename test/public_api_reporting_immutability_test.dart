import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

void main() {
  test('reporting DTOs snapshot and freeze caller-owned collections', () {
    final detailDefinitions = <AdapterReportDetailDefinition>[
      const AdapterReportDetailDefinition(
        key: 'path',
        label: 'Path',
        valueType: AdapterReportDetailValueType.path,
      ),
    ];
    final findingDefinitions = <AdapterFindingReportDefinition>[
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.asset,
        ruleId: 'PRN-ASSET-001',
        title: 'Unused asset',
        nodeLabel: 'Asset',
        details: detailDefinitions,
      ),
    ];
    final measurementDefinitions = <AdapterReportMeasurementDefinition>[
      const AdapterReportMeasurementDefinition(
        kind: 'asset-family-source-bytes',
        label: 'Asset family size',
        unit: 'bytes',
      ),
    ];
    final definitions = <AdapterReportDefinition>[
      AdapterReportDefinition(
        adapterId: 'assets',
        displayName: 'Asset analyzer',
        findings: findingDefinitions,
        measurements: measurementDefinitions,
      ),
    ];
    final requestedAdapters = <String>['assets'];
    final tiers = <String, int>{'SAFE': 1};
    final adapterTiers = <String, Map<String, int>>{'assets': tiers};
    final passRuns = <AdapterRunReport>[];
    final measurements = <RunMeasurement>[];
    final exclusions = <String, int>{'directory:.dart_tool': 1};
    final requiredStepIds = <String>['analyze'];
    final observedStepIds = <String>['analyze'];
    final steps = <VerificationStepReport>[
      const VerificationStepReport(
        id: 'analyze',
        passed: true,
        available: true,
        exitCode: 0,
        elapsedMicros: 1,
      ),
    ];
    final verificationAttempts = <VerificationAttemptReport>[
      VerificationAttemptReport(
        purpose: VerificationAttemptPurpose.baseline,
        complete: true,
        available: true,
        accepted: true,
        policyHash: 'policy',
        requiredStepIds: requiredStepIds,
        observedStepIds: observedStepIds,
        workingDirectory: '/tmp/project',
        toolchainIdentity: 'dart',
        steps: steps,
        newFailureCount: 0,
        infrastructureFailureCount: 0,
      ),
    ];
    final passes = <AnalysisPassReport>[
      AnalysisPassReport(
        id: 'analysis-001',
        purpose: AnalysisPassPurpose.initial,
        elapsedMicros: 1,
        nodeCount: 1,
        edgeCount: 0,
        rootCount: 1,
        recordedBlockerCount: 0,
        danglingEdgeCount: 0,
        adapterRuns: passRuns,
        findingStatistics: FindingStatistics(
          total: 1,
          byTier: tiers,
          byReportingAdapter: const {'assets': 1},
          byReportingAdapterAndTier: adapterTiers,
          byRule: const {'PRN-ASSET-001': 1},
          byNodeKind: const {'asset': 1},
          byClassificationReason: const {},
        ),
        blockerStatistics: BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: const {},
        ),
        measurements: measurements,
        exclusionPolicyVersion: 2,
        exclusionsByReason: exclusions,
      ),
    ];
    final diagnostics = <RunDiagnostic>[];
    final findings = <Finding>[];
    final applyFindingOutcomes = <ApplyFindingOutcome>[
      ApplyFindingOutcome(
        finding: _finding(),
        status: ApplyFindingOutcomeStatus.remaining,
        reasonCode: 'still_reachable',
        reason: 'The finding remains reachable.',
      ),
    ];
    final acceptedRiskCodes = <String>['external-consumers-not-scanned'];

    final report = RunReport(
      identity: RunIdentity(
        id: 'run-1',
        command: RunCommand.scan,
        toolVersion: 'test',
        startedAtUtc: DateTime.utc(2026),
        finishedAtUtc: DateTime.utc(2026),
        elapsedMicros: 0,
      ),
      status: RunStatus.completed,
      exitCode: 0,
      partialApplied: false,
      projectRoot: '/tmp/project',
      packageName: 'project',
      requestedAdapters: requestedAdapters,
      adapterReportDefinitions: definitions,
      targetMatrix: TargetMatrix.declared(const []),
      rootCoverage: RootCoverage.applicationApi(),
      analysisPasses: passes,
      findings: findings,
      diagnostics: diagnostics,
      verificationAttempts: verificationAttempts,
      applyFindingOutcomes: applyFindingOutcomes,
      acceptedRiskCodes: acceptedRiskCodes,
    );

    requestedAdapters.add('dart');
    definitions.clear();
    findingDefinitions.clear();
    detailDefinitions.clear();
    measurementDefinitions.clear();
    tiers['SAFE'] = 2;
    adapterTiers['dart'] = {'HIGH': 1};
    passRuns.add(_adapterRun());
    measurements.add(_measurement());
    exclusions.clear();
    requiredStepIds.add('test');
    observedStepIds.clear();
    steps.clear();
    verificationAttempts.clear();
    passes.clear();
    findings.add(_finding());
    diagnostics.add(const RunDiagnostic(code: 'late', message: 'late'));
    applyFindingOutcomes.add(
      ApplyFindingOutcome(
        finding: _finding(),
        status: ApplyFindingOutcomeStatus.rejectedRecovered,
        reasonCode: 'late_invalid_outcome',
        reason: 'This invalid duplicate was added after report validation.',
      ),
    );
    acceptedRiskCodes.clear();

    expect(report.requestedAdapters, ['assets']);
    expect(report.adapterReportDefinitions.single.findings, hasLength(1));
    expect(report.adapterReportDefinitions.single.measurements, hasLength(1));
    expect(
      report.adapterReportDefinitions.single.findings.single.details,
      hasLength(1),
    );
    expect(report.analysisPasses.single.findingStatistics.byTier['SAFE'], 1);
    expect(
      report.analysisPasses.single.findingStatistics.byReportingAdapterAndTier,
      {
        'assets': {'SAFE': 1},
      },
    );
    expect(report.analysisPasses.single.adapterRuns, isEmpty);
    expect(report.analysisPasses.single.measurements, isEmpty);
    expect(report.analysisPasses.single.exclusionsByReason, {
      'directory:.dart_tool': 1,
    });
    expect(report.verificationAttempts.single.requiredStepIds, ['analyze']);
    expect(report.verificationAttempts.single.observedStepIds, ['analyze']);
    expect(report.verificationAttempts.single.steps, hasLength(1));
    expect(report.analysisPasses, hasLength(1));
    expect(report.findings, isEmpty);
    expect(report.diagnostics, isEmpty);
    expect(report.applyFindingOutcomes, hasLength(1));
    expect(report.acceptedRiskCodes, ['external-consumers-not-scanned']);

    expect(() => report.requestedAdapters.add('dart'), throwsUnsupportedError);
    expect(
      () => report.adapterReportDefinitions.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => report.adapterReportDefinitions.single.findings.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => report.analysisPasses.single.findingStatistics.byTier['SAFE'] = 2,
      throwsUnsupportedError,
    );
    expect(
      () =>
          report
                  .analysisPasses
                  .single
                  .findingStatistics
                  .byReportingAdapterAndTier['assets']!['SAFE'] =
              2,
      throwsUnsupportedError,
    );
    expect(
      () =>
          report.analysisPasses.single.blockerStatistics.byProducer['assets'] =
              1,
      throwsUnsupportedError,
    );
    expect(
      () => report.verificationAttempts.single.steps.clear(),
      throwsUnsupportedError,
    );
    expect(() => report.applyFindingOutcomes.clear(), throwsUnsupportedError);
  });

  test('apply outcome snapshots related node ids', () {
    final relatedNodeIds = <String>['dart:project/lib/main.dart#main'];
    final outcome = ApplyFindingOutcome(
      finding: _finding(),
      status: ApplyFindingOutcomeStatus.remaining,
      reasonCode: 'still_reachable',
      reason: 'The finding remains reachable.',
      relatedNodeIds: relatedNodeIds,
    );

    relatedNodeIds.clear();

    expect(outcome.relatedNodeIds, ['dart:project/lib/main.dart#main']);
    expect(() => outcome.relatedNodeIds.clear(), throwsUnsupportedError);
  });

  test('apply selection snapshots and freezes exact finding ids', () {
    final cliValues = <String>['dart:project/lib/main.dart#unused'];
    final selection = FindingSelection.fromCli(cliValues);
    final requested = <String>['dart:project/lib/main.dart#unused'];
    final planned = <String>['dart:project/lib/main.dart#unused'];
    final report = ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: requested,
      plannedFindingIds: planned,
      planFingerprint: 'a' * 64,
    );

    cliValues.clear();
    requested.clear();
    planned.clear();

    expect(selection.requestedFindingIds, [
      'dart:project/lib/main.dart#unused',
    ]);
    expect(report.requestedFindingIds, ['dart:project/lib/main.dart#unused']);
    expect(report.plannedFindingIds, ['dart:project/lib/main.dart#unused']);
    expect(() => selection.requestedFindingIds.clear(), throwsUnsupportedError);
    expect(() => report.requestedFindingIds.clear(), throwsUnsupportedError);
    expect(() => report.plannedFindingIds.clear(), throwsUnsupportedError);
  });
}

AdapterRunReport _adapterRun() => AdapterRunReport(
  id: 'assets',
  name: 'Asset analyzer',
  role: AdapterRunRole.reporting,
  status: AdapterRunStatus.executed,
  elapsedMicros: 1,
  nodesAdded: 1,
  edgesAdded: 0,
  blockersAdded: 0,
);

RunMeasurement _measurement() => const RunMeasurement(
  kind: 'asset-family-source-bytes',
  status: MeasurementStatus.measured,
  unit: 'bytes',
  scope: 'assets-inventory',
  aggregation: 'families',
  value: 1,
);

Finding _finding() => Finding(
  ruleId: 'PRN-ASSET-001',
  node: GraphNode(
    id: 'asset:project/assets/example.json',
    kind: NodeKind.asset,
    origin: Uri.file('/tmp/project/assets/example.json'),
  ),
  confidence: Confidence.review,
  title: 'Unused asset',
  predicates: const SafetyPredicates(
    ruleAllowsAutoFix: true,
    unreachableAcrossAllTargets: true,
    noDynamicBlockers: true,
    notProtected: true,
    noPublicApiRisk: true,
    hasDeterministicInverse: true,
  ),
  reportingAdapterId: 'assets',
);
