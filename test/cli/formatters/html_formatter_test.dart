import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/cli/formatters/html_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  test(
    'renders an offline report with script-safe embedded schema v3 JSON',
    () {
      final output = const HtmlFormatter().format(_report());

      expect(output, startsWith('<!doctype html>'));
      expect(
        output,
        contains('<script id="report-data" type="application/json">'),
      );
      expect(output, contains('"version":3'));
      expect(output, contains(r'Closing \u003c/script\u003e \u0026 safe'));
      expect(output, isNot(contains('</script><img')));
      expect(output, contains('Copy command'));
      expect(output, contains('Copy path'));
      expect(output, contains('Download JSON'));
      expect(output, contains('Verification'));
      expect(output, contains('Apply summary'));
      expect(output, contains('summary-grid'));
      expect(output, contains('technical-grid'));
      expect(output, contains('disclosure'));
      expect(output, contains('[hidden]'));
      expect(output, contains('findingOutcomes'));
      expect(output, contains('textContent'));
      expect(output, contains('Content-Security-Policy'));
      expect(output, contains('id="render-fallback"'));
      expect(output, contains('Static audit summary'));
      expect(output, contains('Closing &lt;/script&gt; &amp; safe'));
      expect(output, contains("\$('render-fallback').hidden = true;"));
      expect(
        output,
        contains('main > :not(#render-fallback) { display:none!important; }'),
      );
      expect(output, contains('absolute local paths'));
      expect(output, contains('This package is audit-only'));
      expect(output, isNot(contains('innerHTML')));
      expect(output, isNot(contains('http://')));
      expect(output, isNot(contains('https://')));
    },
  );

  test('uses uppercase JSON tiers and automatic dry-run reports', () {
    final output = const HtmlFormatter().format(
      _report(confidence: Confidence.safe),
    );

    expect(output, contains('"confidence":"SAFE"'));
    expect(
      output,
      contains("const tiers = ['SAFE', 'HIGH', 'REVIEW', 'PROTECTED'];"),
    );
    expect(output, contains('normalizeTier(finding.confidence)'));
    expect(
      output,
      contains(
        r'flutter_pruner apply --project ${project} --dry-run${adapterArguments}',
      ),
    );
    expect(
      output,
      contains(
        r'flutter_pruner apply --project ${project} --dry-run${adapterArguments}',
      ),
    );
    expect(output, isNot(contains(r'--project ${project} --safe')));
    expect(output, isNot(contains(r'--project ${project} --high')));
    expect(output, isNot(contains('--report-output apply-preview.html')));
    expect(output, isNot(contains('--output rescan-report.html')));
    expect(
      output,
      contains('Transaction counters do not form a terminal partition'),
    );
    expect(output, contains('Source bytes removed (not app savings)'));
    expect(output, contains("['Confidence', snapshot.confidence]"));
    expect(output, contains('const analysisHealthy = finalPass !== null'));
    expect(output, contains('Final analysis graph has'));
    expect(
      output,
      contains('rerun the exact reviewed invocation from shell history'),
    );
    expect(
      output,
      contains(
        "const recoveryRequired = run.command === 'apply' && "
        "run.status === 'recoveryRequired'",
      ),
    );
    expect(output, contains('One or more transactions require recovery'));
    expect(output, contains('const adapterArguments ='));
    expect(output, contains("['Non-terminal', transactions.nonTerminal]"));
    expect(
      output,
      contains(
        "['Skipped because of a dependency', "
        'apply.findings && apply.findings.skippedDependency]',
      ),
    );
    expect(
      output,
      contains("['Declared', apply.actions && apply.actions.declared]"),
    );
    expect(
      output,
      contains("['Verification attempts', apply.verificationAttempts]"),
    );
    expect(output, contains('No — recovery required'));
    expect(output, contains('Finding audit detail'));
    expect(
      output,
      contains(
        "['Proposed action', labelFor('action', snapshot.proposedAction)]",
      ),
    );
    expect(output, contains("['Why not safe', snapshot.whyNotSafe]"));
    expect(
      output,
      contains('const domainRows = detailRows(snapshot.details, snapshot)'),
    );
    expect(output, contains('Domain details'));
    expect(output, contains("labelFor('nodeKind',"));
    expect(output, contains("labelFor('predicate', key)"));
    expect(output, contains("labelFor('classification', reason)"));
    expect(
      output,
      contains(
        'measurementLabel(adapterId || measurement.adapterId, '
        "measurement.kind || 'measurement')",
      ),
    );
    expect(output, contains("labelFor('detail', key)"));
    expect(output, contains('Duplicate files'));
    expect(output, contains('Rule supports automatic fixes'));
    expect(output, contains('Unreachable in every configured target'));
    expect(output, contains('Target coverage is incomplete'));
    expect(output, contains('Source size'));
    expect(output, contains('Base asset size'));
    expect(output, contains('Target configurations'));
    expect(output, contains('Dart defines'));
    expect(output, contains("['Reason code'"));
    expect(output, contains('--on-accent:#101827'));
    expect(output, contains('color:var(--on-accent)'));
    expect(output, isNot(contains('flutter_pruner rollback')));
  });

  test('uses a flat, theme-aware report header color', () {
    final output = const HtmlFormatter().format(_report());

    expect(output, contains('--hero-bg:#1e3a5f'));
    expect(output, contains('--hero-bg:#1e293b'));
    expect(output, contains('.hero { background:var(--hero-bg)'));
    expect(output, contains('color:var(--hero-text)'));
    expect(output, contains('color:var(--hero-muted)'));
    expect(output, contains('color:var(--hero-warning)'));
    expect(output, isNot(contains('linear-gradient(')));
  });

  test(
    'distinguishes verified safe stops from legacy uncertain apply evidence',
    () {
      final safeStop = const HtmlFormatter().format(
        _report(command: RunCommand.apply, status: RunStatus.safeStopped),
      );
      final historicalPartial = const HtmlFormatter().format(
        _report(
          command: RunCommand.apply,
          status: RunStatus.safeStopped,
          partialApplied: true,
        ),
      );

      expect(safeStop, contains('Stopped safely — no mutation retained'));
      expect(
        safeStop,
        contains(
          'No mutation from this run was retained after verified rollback',
        ),
      );
      expect(safeStop, contains('Working-copy evidence'));
      expect(
        historicalPartial,
        contains(
          'legacy partialApplied flag marks an uncertain working-copy state',
        ),
      );
      expect(
        historicalPartial,
        contains('Working-copy state needs recovery attention'),
      );
      expect(
        historicalPartial,
        isNot(contains('Partial apply — inspect current state')),
      );
      expect(
        historicalPartial,
        isNot(contains('Treat the project as changed.')),
      );
    },
  );

  test('treats dangling roots as unhealthy in interactive and fallback views', () {
    final output = const HtmlFormatter().format(_report(danglingRoots: 1));

    expect(output, contains('"danglingRoots":1'));
    expect(output, contains('danglingRoots === 0'));
    expect(
      output,
      contains(
        'Final analysis graph has \${number(danglingRoots)} dangling root(s).',
      ),
    );
    expect(
      output,
      contains(
        'The final graph contains unresolved roots; automatic guidance is unsafe.',
      ),
    );
    expect(output, contains("['Graph dangling roots',"));
  });

  test('uses adapter-scoped custom labels and typed detail presentation', () {
    final output = const HtmlFormatter().format(
      _report(
        adapterReportDefinitions: [_routesPresentation, _localesPresentation],
      ),
    );

    expect(output, contains('Route catalog'));
    expect(output, contains('Route payload bytes'));
    expect(output, contains('Locale plural forms'));
    expect(output, contains('Serialized route payload size.'));
    expect(output, contains('const adapterCatalog = new Map'));
    expect(output, contains('findingPresentationFor(finding)'));
    expect(
      output,
      contains('adapterFor(finding && finding.reportingAdapterId)'),
    );
    expect(output, contains('const detailDefinition = (finding, key)'));
    expect(output, contains('detailRows(finding.details, finding)'));
    expect(
      output,
      contains('measurementLabel(adapterId || measurement.adapterId'),
    );
    expect(output, contains("definition && definition.valueType === 'bytes'"));
  });

  test('renders the accessible safety decision and findings workbench', () {
    final output = const HtmlFormatter().format(_report());

    expect(output, contains('<html lang="en" class="report-pending">'));
    expect(output, contains('href="#report-main"'));
    expect(output, contains('id="decision-banner"'));
    expect(output, contains('id="recovery-section"'));
    expect(output, contains('id="search" type="search"'));
    expect(output, contains('id="adapter-filter"'));
    expect(output, contains('id="blocker-filter"'));
    expect(output, contains('id="outcome-filter"'));
    expect(output, contains('id="load-more"'));
    expect(output, contains("theme.id = 'theme-toggle'"));
    expect(output, contains('@media (prefers-reduced-motion:reduce)'));
    expect(output, contains('min-height:44px'));
    expect(output, contains('const runFailed = ['));
    expect(output, contains('else if (runFailed)'));
    expect(output, contains('const graphFact ='));
    expect(output, contains('adapter failure(s)'));
    expect(output, contains('requestedIndex >= visibleLimit'));
    expect(output, contains("addEventListener('hashchange'"));
    expect(output, contains('scrollIntoView({ block: \'start\' })'));
    expect(output, contains('Copy finding link'));
    expect(output, contains('Printed finding snapshot:'));
  });
}

RunReport _report({
  Confidence confidence = Confidence.review,
  List<AdapterReportDefinition> adapterReportDefinitions = const [],
  int danglingRoots = 0,
  RunCommand command = RunCommand.scan,
  RunStatus status = RunStatus.completed,
  bool partialApplied = false,
}) {
  final finding = Finding(
    ruleId: adapterReportDefinitions.isEmpty ? 'PRN-DART-001' : 'PRN-ROUTE-001',
    node: GraphNode(
      id: 'dart:test/lib/example.dart#symbol',
      kind: NodeKind.declaration,
      origin: Uri.file('/project/lib/example.dart'),
      displayName: 'example',
      metadata: const {'sharedDetail': 128},
    ),
    confidence: confidence,
    title: 'Closing </script> & safe',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
    ),
    reportingAdapterId: adapterReportDefinitions.isEmpty ? null : 'routes',
  );
  return RunReport(
    identity: RunIdentity(
      id: 'run-html-test',
      command: command,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: status,
    exitCode: status == RunStatus.safeStopped ? 2 : 0,
    partialApplied: partialApplied,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: adapterReportDefinitions.isEmpty
        ? const ['dart']
        : adapterReportDefinitions
              .map((definition) => definition.adapterId)
              .toList(),
    adapterReportDefinitions: adapterReportDefinitions,
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: danglingRoots == 0
        ? const []
        : [
            AnalysisPassReport(
              id: 'analysis-001',
              purpose: AnalysisPassPurpose.initial,
              elapsedMicros: 1,
              nodeCount: 1,
              edgeCount: 0,
              rootCount: 1,
              recordedBlockerCount: 0,
              danglingEdgeCount: 0,
              danglingRootCount: danglingRoots,
              adapterRuns: const [],
              findingStatistics: FindingStatistics.fromFindings([finding]),
              blockerStatistics: BlockerStatistics(
                recorded: 0,
                activeUnique: 0,
                affectedFindings: 0,
                byProducer: {},
              ),
              measurements: const [],
              exclusionPolicyVersion: 1,
              exclusionsByReason: const {},
            ),
          ],
    findings: [finding],
    diagnostics: const [],
  );
}

final _routesPresentation = AdapterReportDefinition(
  adapterId: 'routes',
  displayName: 'Route catalog',
  description: 'Route-specific report copy.',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.declaration,
      ruleId: 'PRN-ROUTE-001',
      title: 'Unlinked route callback',
      nodeLabel: 'Route callback',
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

final _localesPresentation = AdapterReportDefinition(
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
