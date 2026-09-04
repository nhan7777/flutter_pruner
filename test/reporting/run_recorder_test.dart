import 'dart:io';

import 'package:flutter_pruner/src/apply/apply_preview_evidence.dart';
import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/reporting/reportable_command_failure.dart';
import 'package:flutter_pruner/src/reporting/run_clock.dart';
import 'package:flutter_pruner/src/reporting/run_id_generator.dart';
import 'package:flutter_pruner/src/reporting/run_recorder.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('recorder finalizes one sanitized zero-finding failure report', () {
    final project = _project();
    addTearDown(() => project.root.deleteSync(recursive: true));
    final recorder = _recorder(RunCommand.scan);
    final failure = ReportableCommandFailure(
      code: 'adapter_analysis_failed',
      phase: 'analysis:adapter:dart',
      message: 'Analysis failed while running the Dart adapter (dart).',
      exitCode: 70,
      status: RunStatus.internalError,
    );

    final report = recorder.finishFailure(project: project, failure: failure);

    expect(report.status, RunStatus.internalError);
    expect(report.exitCode, 70);
    expect(report.analysisPasses, isEmpty);
    expect(report.findings, isEmpty);
    expect(report.diagnostics, hasLength(1));
    expect(report.diagnostics.single.code, 'adapter_analysis_failed');
    expect(report.diagnostics.single.phase, 'analysis:adapter:dart');
    expect(
      report.diagnostics.single.message,
      'Analysis failed while running the Dart adapter (dart).',
    );
  });

  test('recorder retains completed-pass findings in a later failure', () {
    final project = _project();
    addTearDown(() => project.root.deleteSync(recursive: true));
    final finding = _finding(project.root);
    final recorder = _recorder(RunCommand.apply)
      ..addAnalysisPass(_analysisPass([finding]));
    final failure = ReportableCommandFailure(
      code: 'apply_planning_failed',
      phase: 'applyPlanning',
      message: 'Apply planning failed after analysis completed.',
      exitCode: 70,
      status: RunStatus.internalError,
    );

    final report = recorder.finishFailure(
      project: project,
      failure: failure,
      completedFindings: [finding],
      applyStatistics: ApplyStatistics.empty,
    );

    expect(report.analysisPasses, hasLength(1));
    expect(report.findings, [same(finding)]);
    expect(report.finalFindingStatistics.total, 1);
    expect(report.diagnostics.single.code, 'apply_planning_failed');
  });

  test('reportable failure rejects unstable or terminal-success facts', () {
    expect(
      () => ReportableCommandFailure(
        code: 'Not Stable',
        phase: 'analysis',
        message: 'Analysis failed.',
        exitCode: 70,
        status: RunStatus.internalError,
      ),
      throwsArgumentError,
    );
    expect(
      () => ReportableCommandFailure(
        code: 'analysis_failed',
        phase: 'analysis\nsecret',
        message: 'Analysis failed.',
        exitCode: 70,
        status: RunStatus.internalError,
      ),
      throwsArgumentError,
    );
    expect(
      () => ReportableCommandFailure(
        code: 'analysis_failed',
        phase: 'analysis',
        message: 'raw failure\nprivate stack',
        exitCode: 70,
        status: RunStatus.internalError,
      ),
      throwsArgumentError,
    );
    for (final separator in const ['\u2028', '\u2029']) {
      expect(
        () => ReportableCommandFailure(
          code: 'analysis_failed',
          phase: 'analysis',
          message: 'raw failure${separator}private stack',
          exitCode: 70,
          status: RunStatus.internalError,
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => ReportableCommandFailure(
        code: 'analysis_failed',
        phase: 'analysis',
        message: 'Analysis failed.',
        exitCode: 0,
        status: RunStatus.completed,
      ),
      throwsArgumentError,
    );
  });

  test('recorder retains one equal immutable initial-plan snapshot', () {
    final project = _project();
    addTearDown(() => project.root.deleteSync(recursive: true));
    final recorder = _recorder(RunCommand.apply);
    final canonicalProjectRoot = project.root.resolveSymbolicLinksSync();
    final initialPlan = _initialPlan(
      canonicalProjectRoot: canonicalProjectRoot,
    );
    final selection = _selection(initialPlan.preview!.fingerprint);

    recorder.recordApplySelection(selection);
    recorder.recordApplyInitialPlan(initialPlan);
    recorder.recordApplyInitialPlan(
      _initialPlan(canonicalProjectRoot: canonicalProjectRoot),
    );

    final report = recorder.finish(
      project: project,
      status: RunStatus.dryRun,
      exitCode: 0,
      findings: const [],
      applyStatistics: ApplyStatistics.empty,
    );

    expect(report.applyInitialPlan, same(initialPlan));
    expect(
      report.applyInitialPlan,
      _initialPlan(canonicalProjectRoot: canonicalProjectRoot),
    );
  });

  test('recorder rejects unequal or non-apply initial-plan evidence', () {
    final applyRecorder = _recorder(RunCommand.apply)
      ..recordApplyInitialPlan(_initialPlan());

    expect(
      () => applyRecorder.recordApplyInitialPlan(
        _initialPlan(scope: ApplyInitialPlanScope.initialRoundOnly),
      ),
      throwsStateError,
    );
    expect(
      () => _recorder(RunCommand.scan).recordApplyInitialPlan(_initialPlan()),
      throwsStateError,
    );
  });
}

ProjectContext _project() {
  final root = Directory.systemTemp.createTempSync('run_recorder_test_');
  return ProjectContext(
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
}

Finding _finding(Directory root) => Finding(
  ruleId: 'TEST-001',
  node: GraphNode(
    id: 'dart:test/lib/main.dart#unused',
    kind: NodeKind.declaration,
    origin: File(p.join(root.path, 'lib', 'main.dart')).uri,
  ),
  confidence: Confidence.review,
  title: 'Test finding',
  predicates: const SafetyPredicates(
    ruleAllowsAutoFix: false,
    unreachableAcrossAllTargets: false,
    noDynamicBlockers: true,
    notProtected: true,
    noPublicApiRisk: true,
    hasDeterministicInverse: false,
  ),
  reportingAdapterId: 'dart',
);

AnalysisPassReport _analysisPass(List<Finding> findings) => AnalysisPassReport(
  id: 'analysis-001',
  purpose: AnalysisPassPurpose.initial,
  elapsedMicros: 1,
  nodeCount: 1,
  edgeCount: 0,
  rootCount: 0,
  recordedBlockerCount: 0,
  danglingEdgeCount: 0,
  adapterRuns: const [],
  findingStatistics: FindingStatistics.fromFindings(findings),
  blockerStatistics: BlockerStatistics(
    recorded: 0,
    activeUnique: 0,
    affectedFindings: 0,
    byProducer: const {},
  ),
  measurements: const [],
  exclusionPolicyVersion: 1,
  exclusionsByReason: const {},
);

RunRecorder _recorder(RunCommand command) => RunRecorder(
  command: command,
  requestedAdapters: const ['dart'],
  toolVersion: 'test',
  clock: _FakeClock(),
  idGenerator: const _FixedIdGenerator(),
);

ApplySelectionReport _selection(String actualPreviewFingerprint) =>
    ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      plannedFindingIds: const ['finding-a'],
      planFingerprint: 'a' * 64,
      actualPreviewFingerprint: actualPreviewFingerprint,
    );

ApplyInitialPlanReport _initialPlan({
  String? canonicalProjectRoot,
  ApplyInitialPlanScope scope = ApplyInitialPlanScope.completeExactSelection,
}) {
  final resolvedProjectRoot = canonicalProjectRoot ?? _canonicalTestRoot();
  return ApplyInitialPlanReport(
    canonicalVersion: 1,
    scope: scope,
    planFingerprint: 'a' * 64,
    units: [
      ApplyPlanUnitReport(
        order: 0,
        id: 'unit-a',
        findingIds: const ['finding-a'],
        dependencyUnitIds: const [],
        actions: [
          ApplyPlanActionReport(
            order: 0,
            logicalFindingId: 'finding-a',
            journalFindingId: 'finding-a',
            operation: FindingActionOperation.removeFinding,
            projectRelativePath: 'lib/a.dart',
            countsTowardSummary: true,
          ),
        ],
      ),
    ],
    blocked: const [],
    preview: ApplyPreviewReport.fromEvidence(
      ApplyPreviewEvidence(
        canonicalProjectRoot: resolvedProjectRoot,
        planFingerprint: 'a' * 64,
        sources: [
          ApplySourceSnapshot(
            projectRelativePath: 'lib/a.dart',
            canonicalPath: _canonicalTestPath(
              'lib/a.dart',
              canonicalProjectRoot: resolvedProjectRoot,
            ),
            sha256: 'b' * 64,
            sizeBytes: 0,
            posixMode: null,
          ),
        ],
      ),
    ),
  );
}

String _canonicalTestRoot([String name = 'project']) =>
    Platform.isWindows ? 'C:\\$name' : '/$name';

String _canonicalTestPath(
  String projectRelativePath, {
  required String canonicalProjectRoot,
}) => p.joinAll([canonicalProjectRoot, ...p.posix.split(projectRelativePath)]);

final class _FakeClock implements RunClock {
  var _timeCalls = 0;
  var _monotonicCalls = 0;

  @override
  int monotonicMicros() => _monotonicCalls++ == 0 ? 0 : 1000;

  @override
  DateTime nowUtc() => DateTime.utc(2026, 8, 25, 0, 0, _timeCalls++);
}

final class _FixedIdGenerator implements RunIdGenerator {
  const _FixedIdGenerator();

  @override
  String next(DateTime startedAtUtc) => 'run-recorder-test';
}
