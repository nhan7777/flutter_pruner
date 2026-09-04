import 'dart:io';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/apply/apply_preview_evidence.dart';
import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_clock.dart';
import 'package:flutter_pruner/src/reporting/run_id_generator.dart';
import 'package:flutter_pruner/src/reporting/run_recorder.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('verification wave identity enforces attempt cardinality', () {
    expect(
      () => _verificationAttempt(
        purpose: VerificationAttemptPurpose.baseline,
        waveId: 'wave-r001',
        transactionIds: const ['tx-a'],
      ),
      throwsStateError,
    );
    expect(
      () => _verificationAttempt(
        purpose: VerificationAttemptPurpose.candidate,
        waveId: 'wave-r001',
        transactionId: 'tx-a',
        transactionIds: const ['tx-a', 'tx-b'],
      ),
      throwsStateError,
    );
    final single = _verificationAttempt(
      purpose: VerificationAttemptPurpose.candidate,
      waveId: 'wave-r001',
      transactionId: 'tx-a',
      transactionIds: const ['tx-a'],
    );
    expect(single.transactionIds, ['tx-a']);
    expect(() => single.transactionIds.add('external'), throwsUnsupportedError);
  });

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

  test('preview evidence locks canonical v1 ordering and digest', () {
    final sources = <ApplySourceSnapshot>[
      ApplySourceSnapshot(
        projectRelativePath: 'lib/z.dart',
        canonicalPath: _canonicalTestPath('lib/z.dart'),
        sha256: '2' * 64,
        sizeBytes: 42,
        posixMode: 420,
      ),
      ApplySourceSnapshot(
        projectRelativePath: 'lib/a.dart',
        canonicalPath: _canonicalTestPath('lib/a.dart'),
        sha256: '1' * 64,
        sizeBytes: 0,
        posixMode: null,
      ),
    ];

    final evidence = ApplyPreviewEvidence(
      canonicalProjectRoot: _canonicalTestRoot(),
      planFingerprint: 'a' * 64,
      sources: sources,
    );
    sources.clear();

    expect(ApplyPreviewEvidence.canonicalVersion, 1);
    expect(
      const ApplyPreviewCanonicalEncoder().encode(evidence),
      _expectedCanonicalV1Payload,
    );
    expect(evidence.fingerprint, _expectedCanonicalV1Fingerprint);
    expect(evidence.sources.map((source) => source.projectRelativePath), [
      'lib/a.dart',
      'lib/z.dart',
    ]);
    expect(evidence.sources.first.sizeBytes, 0);
    expect(evidence.sources.first.posixMode, isNull);
    expect(() => evidence.sources.clear(), throwsUnsupportedError);
  });

  test('source snapshots reject ambiguous paths and invalid file facts', () {
    ApplySourceSnapshot snapshot({
      String projectRelativePath = 'lib/a.dart',
      String? canonicalPath,
      String? digest,
      int sizeBytes = 1,
      int? posixMode = 420,
    }) => ApplySourceSnapshot(
      projectRelativePath: projectRelativePath,
      canonicalPath: canonicalPath ?? _canonicalTestPath('lib/a.dart'),
      sha256: digest ?? 'a' * 64,
      sizeBytes: sizeBytes,
      posixMode: posixMode,
    );

    expect(
      () => snapshot(projectRelativePath: '/lib/a.dart'),
      throwsStateError,
    );
    expect(
      () => snapshot(projectRelativePath: r'C:\project\lib\a.dart'),
      throwsStateError,
    );
    expect(
      () => snapshot(projectRelativePath: r'C:lib\a.dart'),
      throwsStateError,
    );
    expect(
      () => snapshot(projectRelativePath: 'lib/../secret.dart'),
      throwsStateError,
    );
    expect(() => snapshot(canonicalPath: 'lib/a.dart'), throwsStateError);
    expect(
      () => snapshot(canonicalPath: r'\project\lib\a.dart'),
      throwsStateError,
    );
    expect(() => snapshot(digest: 'A' * 64), throwsStateError);
    expect(() => snapshot(digest: 'a' * 63), throwsStateError);
    expect(() => snapshot(sizeBytes: -1), throwsStateError);
    expect(() => snapshot(posixMode: -1), throwsStateError);
    expect(() => snapshot(posixMode: 4096), throwsStateError);
  });

  test('host validation requires drive-qualified or UNC Windows paths', () {
    String validate(String value, {required bool isWindowsHost}) =>
        ApplySourceSnapshot.validateCanonicalAbsolutePathForHost(
          value,
          label: 'Canonical test path',
          isWindowsHost: isWindowsHost,
        );

    expect(() => validate('/project', isWindowsHost: true), throwsStateError);
    expect(
      () => validate('/project/lib/a.dart', isWindowsHost: true),
      throwsStateError,
    );
    expect(validate(r'C:\project', isWindowsHost: true), r'C:\project');
    expect(
      validate(r'\\server\share\project', isWindowsHost: true),
      r'\\server\share\project',
    );
    expect(validate('/project', isWindowsHost: false), '/project');
    expect(
      validate('/project/lib/a.dart', isWindowsHost: false),
      '/project/lib/a.dart',
    );
  });

  test('A2 fixtures use canonical paths for the current host', () {
    final context = Platform.isWindows ? p.windows : p.posix;
    final root = _canonicalTestRoot();
    final sourcePath = _canonicalTestPath('lib/a.dart');

    expect(context.isAbsolute(root), isTrue);
    expect(context.isRootRelative(root), isFalse);
    expect(context.normalize(root), root);
    expect(context.isAbsolute(sourcePath), isTrue);
    expect(context.isRootRelative(sourcePath), isFalse);
    expect(context.normalize(sourcePath), sourcePath);

    final plan = _initialPlan();
    final report = _runReport(
      selection: _selection(
        actualPreviewFingerprint: plan.preview!.fingerprint,
      ),
      initialPlan: plan,
    );
    expect(report.canonicalProjectRoot, root);
  });

  test('preview evidence rejects ambiguous roots, plans, and sources', () {
    final source = _sourceSnapshot();

    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: 'project',
        planFingerprint: 'a' * 64,
        sources: [source],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: r'\project',
        planFingerprint: 'a' * 64,
        sources: [
          ApplySourceSnapshot(
            projectRelativePath: 'lib/a.dart',
            canonicalPath: r'\project\lib\a.dart',
            sha256: 'a' * 64,
            sizeBytes: 1,
            posixMode: null,
          ),
        ],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'A' * 64,
        sources: [source],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'a' * 64,
        sources: [source, source],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'a' * 64,
        sources: [
          source,
          ApplySourceSnapshot(
            projectRelativePath: 'lib/b.dart',
            canonicalPath: source.canonicalPath,
            sha256: 'b' * 64,
            sizeBytes: 1,
            posixMode: 420,
          ),
        ],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: null,
        sources: [source],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewEvidence(
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'a' * 64,
        sources: const [],
      ),
      throwsStateError,
    );

    final empty = ApplyPreviewEvidence(
      canonicalProjectRoot: _canonicalTestRoot(),
      planFingerprint: null,
      sources: const [],
    );
    expect(empty.fingerprint, _emptyPreviewFingerprint);
  });

  test('preview report requires canonical sorted unique snapshots', () {
    final first = ApplySourceSnapshotReport(
      projectRelativePath: 'lib/a.dart',
      canonicalPath: r'C:\Project\lib\a.dart',
      sha256: 'a' * 64,
      sizeBytes: 1,
      posixMode: null,
    );
    final second = ApplySourceSnapshotReport(
      projectRelativePath: 'lib/b.dart',
      canonicalPath: r'c:\project\LIB\A.DART',
      sha256: 'b' * 64,
      sizeBytes: 1,
      posixMode: null,
    );

    expect(
      () => ApplyPreviewReport(
        version: 1,
        canonicalProjectRoot: r'C:\Project',
        planFingerprint: 'a' * 64,
        sources: [first, second],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewReport(
        version: 1,
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'a' * 64,
        sources: [
          _sourceReport(projectRelativePath: 'lib/z.dart'),
          first,
        ],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewReport(
        version: 2,
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: null,
        sources: const [],
      ),
      throwsStateError,
    );
    expect(
      () => ApplyPreviewReport(
        version: 1,
        canonicalProjectRoot: _canonicalTestRoot(),
        planFingerprint: 'A' * 64,
        sources: [_sourceReport()],
      ),
      throwsStateError,
    );
  });

  test(
    'initial plan preserves physical order and distinct auxiliary actions',
    () {
      final findingIds = <String>['finding-a'];
      final dependencyIds = <String>['unit-dependency'];
      final actions = <ApplyPlanActionReport>[
        _planAction(
          order: 0,
          journalFindingId: 'finding-a@import:lib/importer.dart',
          operation: FindingActionOperation.cleanupImports,
          projectRelativePath: 'lib/importer.dart',
          cleanupTargetPath: 'lib/dead.dart',
          countsTowardSummary: false,
        ),
        _planAction(
          order: 1,
          journalFindingId: 'finding-a@generated:lib/dead.g.dart',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'lib/dead.g.dart',
          countsTowardSummary: false,
        ),
        _planAction(
          order: 2,
          journalFindingId: 'finding-a',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'lib/dead.dart',
        ),
      ];
      final units = <ApplyPlanUnitReport>[
        ApplyPlanUnitReport(
          order: 0,
          id: 'unit-a',
          findingIds: findingIds,
          dependencyUnitIds: dependencyIds,
          actions: actions,
        ),
        ApplyPlanUnitReport(
          order: 1,
          id: 'unit-dependency',
          findingIds: const ['finding-b'],
          dependencyUnitIds: const [],
          actions: [
            _planAction(
              order: 0,
              logicalFindingId: 'finding-b',
              journalFindingId: 'finding-b',
              operation: FindingActionOperation.removeFinding,
              projectRelativePath: 'lib/value.dart',
            ),
          ],
        ),
      ];
      final blocked = <ApplyPlanBlockReport>[
        ApplyPlanBlockReport(
          findingId: 'finding-c',
          reason: PlanBlockReason.retainedConsumer,
          blockedBy: 'finding-retained',
        ),
      ];

      final plan = ApplyInitialPlanReport(
        canonicalVersion: 1,
        scope: ApplyInitialPlanScope.completeExactSelection,
        planFingerprint: 'a' * 64,
        units: units,
        blocked: blocked,
      );
      findingIds.clear();
      dependencyIds.clear();
      actions.clear();
      units.clear();
      blocked.clear();

      expect(plan.units.map((unit) => unit.id), ['unit-a', 'unit-dependency']);
      expect(
        plan.units.first.actions.map((action) => action.journalFindingId),
        [
          'finding-a@import:lib/importer.dart',
          'finding-a@generated:lib/dead.g.dart',
          'finding-a',
        ],
      );
      expect(
        plan.units.first.actions.map((action) => action.logicalFindingId),
        everyElement('finding-a'),
      );
      expect(plan.blocked.single.findingId, 'finding-c');
      expect(() => plan.units.clear(), throwsUnsupportedError);
      expect(() => plan.units.first.actions.clear(), throwsUnsupportedError);
      expect(() => plan.blocked.clear(), throwsUnsupportedError);
    },
  );

  test('initial plan rejects duplicate or ambiguous action identities', () {
    ApplyInitialPlanReport planWith(List<ApplyPlanUnitReport> units) =>
        ApplyInitialPlanReport(
          canonicalVersion: 1,
          scope: ApplyInitialPlanScope.completeExactSelection,
          planFingerprint: 'a' * 64,
          units: units,
          blocked: const [],
        );

    expect(
      () => planWith([_planUnit(), _planUnit(order: 1)]),
      throwsStateError,
    );
    expect(
      () => planWith([
        _planUnit(
          actions: [
            _planAction(order: 0, journalFindingId: 'journal-a'),
            _planAction(
              order: 1,
              journalFindingId: 'journal-a',
              projectRelativePath: 'lib/b.dart',
            ),
          ],
        ),
      ]),
      throwsStateError,
    );
    expect(
      () => planWith([
        _planUnit(
          actions: [
            _planAction(order: 0, journalFindingId: 'journal-a'),
            _planAction(order: 1, journalFindingId: 'journal-b'),
          ],
        ),
      ]),
      throwsStateError,
    );
    expect(() => planWith([_planUnit(order: 1)]), throwsStateError);
  });

  test('selection derives and validates preview comparison', () {
    final actual = 'v1:${'1' * 64}';
    final expected = 'v1:${'2' * 64}';

    expect(
      _selection(actualPreviewFingerprint: actual).previewComparison,
      ApplyPreviewComparison.notRequested,
    );
    expect(
      _selection(
        actualPreviewFingerprint: actual,
        expectedPreviewFingerprint: actual,
      ).previewComparison,
      ApplyPreviewComparison.matched,
    );
    final mismatch = _selection(
      actualPreviewFingerprint: actual,
      expectedPreviewFingerprint: expected,
    );
    expect(mismatch.previewComparison, ApplyPreviewComparison.mismatched);
    expect(mismatch.actualPreviewFingerprint, actual);
    expect(mismatch.expectedPreviewFingerprint, expected);
    final emptyPlan = ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      plannedFindingIds: const [],
      actualPreviewFingerprint: actual,
      expectedPreviewFingerprint: actual,
    );
    expect(emptyPlan.actualPreviewFingerprint, actual);
    expect(emptyPlan.expectedPreviewFingerprint, actual);
    expect(emptyPlan.previewComparison, ApplyPreviewComparison.mismatched);
    expect(
      () => ApplySelectionReport(
        mode: FindingSelectionMode.exact,
        requestedFindingIds: const ['finding-a'],
        plannedFindingIds: const [],
        actualPreviewFingerprint: actual,
        expectedPreviewFingerprint: actual,
        previewComparison: ApplyPreviewComparison.matched,
      ),
      throwsStateError,
    );
    expect(
      () => _selection(expectedPreviewFingerprint: expected),
      throwsStateError,
    );
    expect(
      () => _selection(
        actualPreviewFingerprint: actual,
        expectedPreviewFingerprint: expected,
        previewComparison: ApplyPreviewComparison.matched,
      ),
      throwsStateError,
    );
    expect(
      () => _selection(actualPreviewFingerprint: '1' * 64),
      throwsStateError,
    );
  });

  test('preview evidence cannot be spliced across action plans', () {
    final projectRootB = _canonicalTestRoot('project-b');
    final evidenceForPlanB = ApplyPreviewEvidence(
      canonicalProjectRoot: projectRootB,
      planFingerprint: 'b' * 64,
      sources: [
        ApplySourceSnapshot(
          projectRelativePath: 'lib/a.dart',
          canonicalPath: _canonicalTestPath(
            'lib/a.dart',
            canonicalProjectRoot: projectRootB,
          ),
          sha256: 'a' * 64,
          sizeBytes: 1,
          posixMode: 420,
        ),
      ],
    );
    final previewForPlanB = ApplyPreviewReport.fromEvidence(evidenceForPlanB);
    final selectionForPlanA = ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      plannedFindingIds: const ['finding-a'],
      planFingerprint: 'a' * 64,
      actualPreviewFingerprint: previewForPlanB.fingerprint,
      expectedPreviewFingerprint: previewForPlanB.fingerprint,
    );

    expect(selectionForPlanA.previewComparison, ApplyPreviewComparison.matched);
    expect(
      () => ApplyInitialPlanReport(
        canonicalVersion: 1,
        scope: ApplyInitialPlanScope.completeExactSelection,
        planFingerprint: 'a' * 64,
        units: [_planUnit()],
        blocked: const [],
        preview: previewForPlanB,
      ),
      throwsStateError,
    );
  });

  test('run report rejects preview evidence captured for another root', () {
    final projectRootB = _canonicalTestRoot('project-b');
    final evidenceForRootB = ApplyPreviewEvidence(
      canonicalProjectRoot: projectRootB,
      planFingerprint: 'a' * 64,
      sources: [
        ApplySourceSnapshot(
          projectRelativePath: 'lib/a.dart',
          canonicalPath: _canonicalTestPath(
            'lib/a.dart',
            canonicalProjectRoot: projectRootB,
          ),
          sha256: 'a' * 64,
          sizeBytes: 1,
          posixMode: 420,
        ),
      ],
    );
    final previewForRootB = ApplyPreviewReport.fromEvidence(evidenceForRootB);
    final selectionForRootA = ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      plannedFindingIds: const ['finding-a'],
      planFingerprint: 'a' * 64,
      actualPreviewFingerprint: previewForRootB.fingerprint,
      expectedPreviewFingerprint: previewForRootB.fingerprint,
    );
    final planForRootA = ApplyInitialPlanReport(
      canonicalVersion: 1,
      scope: ApplyInitialPlanScope.completeExactSelection,
      planFingerprint: 'a' * 64,
      units: [_planUnit()],
      blocked: const [],
      preview: previewForRootB,
    );

    expect(selectionForRootA.previewComparison, ApplyPreviewComparison.matched);
    expect(
      () => _runReport(
        projectRoot: _canonicalTestRoot('project-a'),
        selection: selectionForRootA,
        initialPlan: planForRootA,
      ),
      throwsStateError,
    );
  });

  test('run report enforces initial-plan selection consistency', () {
    final exactSelection = _selection(actualPreviewFingerprint: _previewToken);
    final exactPlan = _initialPlan();

    expect(
      _runReport(
        selection: exactSelection,
        initialPlan: exactPlan,
      ).applyInitialPlan,
      same(exactPlan),
    );
    expect(
      _runReport(
        selection: ApplySelectionReport(
          mode: FindingSelectionMode.allEligible,
          requestedFindingIds: const [],
          plannedFindingIds: const ['finding-a'],
          planFingerprint: 'a' * 64,
          actualPreviewFingerprint: _previewToken,
        ),
        initialPlan: _initialPlan(
          scope: ApplyInitialPlanScope.initialRoundOnly,
        ),
      ).applyInitialPlan?.scope,
      ApplyInitialPlanScope.initialRoundOnly,
    );
    expect(
      () => _runReport(
        command: RunCommand.scan,
        selection: exactSelection,
        initialPlan: exactPlan,
      ),
      throwsStateError,
    );
    expect(
      () => _runReport(
        selection: exactSelection,
        initialPlan: _initialPlan(
          scope: ApplyInitialPlanScope.initialRoundOnly,
        ),
      ),
      throwsStateError,
    );
    expect(
      () => _runReport(
        selection: exactSelection,
        initialPlan: _initialPlan(planFingerprint: 'b' * 64),
      ),
      throwsStateError,
    );
    expect(
      () => _runReport(
        selection: ApplySelectionReport(
          mode: FindingSelectionMode.exact,
          requestedFindingIds: const ['finding-a', 'finding-b'],
          plannedFindingIds: const ['finding-a', 'finding-b'],
          planFingerprint: 'a' * 64,
          actualPreviewFingerprint: _previewToken,
        ),
        initialPlan: exactPlan,
      ),
      throwsStateError,
    );
    expect(
      () => _runReport(
        selection: _selection(actualPreviewFingerprint: 'v1:${'3' * 64}'),
        initialPlan: exactPlan,
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

VerificationAttemptReport _verificationAttempt({
  required VerificationAttemptPurpose purpose,
  String? waveId,
  String? transactionId,
  List<String> transactionIds = const [],
}) => VerificationAttemptReport(
  purpose: purpose,
  complete: true,
  available: true,
  accepted: true,
  policyHash: 'policy',
  requiredStepIds: const ['analyze'],
  observedStepIds: const ['analyze'],
  workingDirectory: _canonicalTestRoot('workspace'),
  toolchainIdentity: 'toolchain',
  steps: const [
    VerificationStepReport(
      id: 'analyze',
      passed: true,
      available: true,
      exitCode: 0,
      elapsedMicros: 1,
    ),
  ],
  newFailureCount: 0,
  infrastructureFailureCount: 0,
  waveId: waveId,
  transactionId: transactionId,
  transactionIds: transactionIds,
);

Finding _finding(
  String id, {
  required String adapter,
  required Confidence confidence,
}) => Finding(
  ruleId: 'TEST',
  node: GraphNode(
    id: id,
    kind: id.startsWith('asset:') ? NodeKind.asset : NodeKind.declaration,
    origin: Uri.file(
      _canonicalTestPath(
        'test',
        canonicalProjectRoot: _canonicalTestRoot('tmp'),
      ),
    ),
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

String _canonicalTestRoot([String name = 'project']) =>
    Platform.isWindows ? 'C:\\$name' : '/$name';

String _canonicalTestPath(
  String projectRelativePath, {
  String? canonicalProjectRoot,
}) => p.joinAll([
  canonicalProjectRoot ?? _canonicalTestRoot(),
  ...p.posix.split(projectRelativePath),
]);

String get _expectedCanonicalV1Payload => Platform.isWindows
    ? r'{"version":1,"projectRoot":"C:\\project",'
          '"planFingerprint":"${'a' * 64}","sources":['
          r'{"projectRelativePath":"lib/a.dart",'
          r'"canonicalPath":"C:\\project\\lib\\a.dart",'
          '"sha256":"${'1' * 64}","sizeBytes":0,"posixMode":null},'
          r'{"projectRelativePath":"lib/z.dart",'
          r'"canonicalPath":"C:\\project\\lib\\z.dart",'
          '"sha256":"${'2' * 64}","sizeBytes":42,"posixMode":420}]}'
    : '{"version":1,"projectRoot":"/project",'
          '"planFingerprint":"${'a' * 64}","sources":['
          '{"projectRelativePath":"lib/a.dart",'
          '"canonicalPath":"/project/lib/a.dart",'
          '"sha256":"${'1' * 64}","sizeBytes":0,"posixMode":null},'
          '{"projectRelativePath":"lib/z.dart",'
          '"canonicalPath":"/project/lib/z.dart",'
          '"sha256":"${'2' * 64}","sizeBytes":42,"posixMode":420}]}';

String get _expectedCanonicalV1Fingerprint => Platform.isWindows
    ? 'v1:db44c930a37f54f21c266e508dbbbb5abad63f8f3aa69b24b72d0c38b5b541e5'
    : 'v1:02ea4157eeb5b1fb23bbbf8024e72808789d92b181253d3bff1ebe49cb425715';

String get _emptyPreviewFingerprint => Platform.isWindows
    ? 'v1:2891ae93bae00ccef68a73312ed341dcacafb372eba126140bb097d9d8c60212'
    : 'v1:64b5563a69c87d5b4899138a5ace151a20f0924e0968f73f4423551c195ea248';

String get _previewToken => Platform.isWindows
    ? 'v1:74d3db3e0c40fd6a116655dd94cc6bdef75e15032cc6d20444586b5bbb1b4fad'
    : 'v1:04b3cbc466bf49e125554a07597130e282ac5a8d67d1b3c16045d8af70c5ec8e';

ApplySourceSnapshot _sourceSnapshot() => ApplySourceSnapshot(
  projectRelativePath: 'lib/a.dart',
  canonicalPath: _canonicalTestPath('lib/a.dart'),
  sha256: 'a' * 64,
  sizeBytes: 1,
  posixMode: 420,
);

ApplySourceSnapshotReport _sourceReport({
  String projectRelativePath = 'lib/a.dart',
  String? canonicalPath,
}) => ApplySourceSnapshotReport(
  projectRelativePath: projectRelativePath,
  canonicalPath: canonicalPath ?? _canonicalTestPath('lib/a.dart'),
  sha256: 'a' * 64,
  sizeBytes: 1,
  posixMode: 420,
);

ApplyPreviewReport _previewReport() => ApplyPreviewReport(
  version: 1,
  canonicalProjectRoot: _canonicalTestRoot(),
  planFingerprint: 'a' * 64,
  sources: [_sourceReport()],
);

ApplyPlanActionReport _planAction({
  required int order,
  String logicalFindingId = 'finding-a',
  String journalFindingId = 'finding-a',
  FindingActionOperation operation = FindingActionOperation.removeFinding,
  String projectRelativePath = 'lib/a.dart',
  String? label,
  bool countsTowardSummary = true,
  String? cleanupTargetPath,
}) => ApplyPlanActionReport(
  order: order,
  logicalFindingId: logicalFindingId,
  journalFindingId: journalFindingId,
  operation: operation,
  projectRelativePath: projectRelativePath,
  label: label,
  countsTowardSummary: countsTowardSummary,
  cleanupTargetPath: cleanupTargetPath,
);

ApplyPlanUnitReport _planUnit({
  int order = 0,
  String id = 'unit-a',
  List<String> findingIds = const ['finding-a'],
  List<String> dependencyUnitIds = const [],
  List<ApplyPlanActionReport>? actions,
}) => ApplyPlanUnitReport(
  order: order,
  id: id,
  findingIds: findingIds,
  dependencyUnitIds: dependencyUnitIds,
  actions: actions ?? [_planAction(order: 0)],
);

ApplyInitialPlanReport _initialPlan({
  ApplyInitialPlanScope scope = ApplyInitialPlanScope.completeExactSelection,
  String? planFingerprint,
  ApplyPreviewReport? preview,
}) => ApplyInitialPlanReport(
  canonicalVersion: 1,
  scope: scope,
  planFingerprint: planFingerprint ?? 'a' * 64,
  units: [_planUnit()],
  blocked: const [],
  preview: preview ?? _previewReport(),
);

ApplySelectionReport _selection({
  String? actualPreviewFingerprint,
  String? expectedPreviewFingerprint,
  ApplyPreviewComparison? previewComparison,
}) => ApplySelectionReport(
  mode: FindingSelectionMode.exact,
  requestedFindingIds: const ['finding-a'],
  plannedFindingIds: const ['finding-a'],
  planFingerprint: 'a' * 64,
  actualPreviewFingerprint: actualPreviewFingerprint,
  expectedPreviewFingerprint: expectedPreviewFingerprint,
  previewComparison: previewComparison,
);

RunReport _runReport({
  RunCommand command = RunCommand.apply,
  String? projectRoot,
  ApplySelectionReport? selection,
  ApplyInitialPlanReport? initialPlan,
}) {
  final resolvedProjectRoot = projectRoot ?? _canonicalTestRoot();
  return RunReport(
    identity: RunIdentity(
      id: 'run-report-test',
      command: command,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 25),
      finishedAtUtc: DateTime.utc(2026, 8, 25, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.dryRun,
    exitCode: 0,
    partialApplied: false,
    projectRoot: resolvedProjectRoot,
    canonicalProjectRoot: initialPlan?.preview == null
        ? null
        : resolvedProjectRoot,
    packageName: 'project',
    requestedAdapters: const ['dart'],
    targetMatrix: TargetMatrix.declared(const []),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: const [],
    findings: const [],
    diagnostics: const [],
    applySelection: selection,
    applyInitialPlan: initialPlan,
    applyStatistics: command == RunCommand.apply ? ApplyStatistics.empty : null,
  );
}

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
