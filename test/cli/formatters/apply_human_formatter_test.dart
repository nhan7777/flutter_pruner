import 'dart:io';

import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/cli/formatters/human_formatter.dart';
import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  group('HumanFormatter apply presentation', () {
    test('renders a pre-transaction command failure without success copy', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.internalError,
            exitCode: 70,
            diagnostics: [
              RunDiagnostic(
                code: 'adapter_analysis_failed',
                phase: 'analysis:adapter:dart',
                message:
                    'Analysis failed after adapter Dart declaration analyzer '
                    '(dart) started.',
              ),
            ],
          ),
        ),
      );

      expect(output, contains('✕ APPLY FAILED'));
      expect(output, contains('status internalError'));
      expect(output, contains('exit 70'));
      expect(output, contains('adapter_analysis_failed'));
      expect(output, contains('analysis:adapter:dart'));
      expect(
        output,
        contains(
          'Analysis failed after adapter Dart declaration analyzer (dart) '
          'started.',
        ),
      );
      expect(output, isNot(contains('✓')));
      expect(output, isNot(contains('APPLY COMPLETED')));
      expect(output, isNot(contains('No finding outcomes')));
    });

    test('labels every terminal state without claiming success', () {
      final cases = <RunStatus, String>{
        RunStatus.completed: 'APPLY COMPLETED',
        RunStatus.noChanges: 'APPLY NO CHANGES',
        RunStatus.dryRun: 'APPLY PREVIEW READY · NO FILES CHANGED',
        RunStatus.safeStopped: 'APPLY STOPPED SAFELY',
        RunStatus.infrastructureFailure:
            'APPLY BLOCKED · INFRASTRUCTURE FAILURE',
        RunStatus.recoveryRequired: 'APPLY RECOVERY REQUIRED',
        RunStatus.internalError: 'APPLY INTERNAL ERROR',
        RunStatus.interrupted: 'APPLY INTERRUPTED',
      };

      for (final entry in cases.entries) {
        final output = _plain(
          const HumanFormatter(lineWidth: 160).format(
            _applyReport(
              status: entry.key,
              outcomes: entry.key == RunStatus.dryRun
                  ? [_outcome(ApplyFindingOutcomeStatus.remaining)]
                  : const [],
            ),
          ),
        );
        expect(output, contains(entry.value), reason: entry.key.name);
      }
    });

    test('gives recovery evidence priority and never suggests rollback', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.completed,
            partialApplied: true,
            quarantinePath: '/project/.flutter_pruner/quarantine/run-1',
            outcomes: [_outcome(ApplyFindingOutcomeStatus.recoveryRequired)],
            statistics: _statistics(
              recoveryRequired: 1,
              committed: 1,
              begun: 2,
            ),
          ),
        ),
      );

      expect(output, contains('APPLY RECOVERY REQUIRED'));
      expect(output, contains('RECOVERY'));
      expect(output, contains('Inspect the quarantine manifest'));
      expect(output, contains('manifest.json'));
      expect(output, contains('Do not rerun apply'));
      expect(output, isNot(contains('flutter_pruner rollback')));
    });

    test('surfaces a non-terminal transaction even without a finding lane', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.internalError,
            quarantinePath: '/project/.flutter_pruner/quarantine/run-1',
            statistics: _statistics(nonTerminal: 1, begun: 1),
          ),
        ),
      );

      expect(output, contains('APPLY RECOVERY REQUIRED'));
      expect(output, contains('1 recovery attention'));
      expect(output, isNot(contains('flutter_pruner rollback')));
    });

    test('treats historical partialApplied as uncertain recovery evidence', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.safeStopped,
            partialApplied: true,
            quarantinePath: '/project/.flutter_pruner/quarantine/apply-test',
            outcomes: [_outcome(ApplyFindingOutcomeStatus.rejectedRecovered)],
            statistics: _statistics(restored: 1, begun: 1),
          ),
        ),
      );

      expect(output, contains('APPLY SAFE STOP · RECOVERY ATTENTION'));
      expect(output, contains('RECOVERY ATTENTION'));
      expect(output, contains('compatibility partialApplied flag'));
      expect(output, contains('uncertain working-copy state'));
      expect(output, isNot(contains('flutter_pruner rollback')));
      expect(output, isNot(contains('APPLY PARTIAL · STOPPED SAFELY')));
    });

    test('labels a verified safe stop as no mutation retained', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.safeStopped,
            quarantinePath: '/project/.flutter_pruner/quarantine/apply-test',
            outcomes: [_outcome(ApplyFindingOutcomeStatus.rejectedRecovered)],
            statistics: _statistics(restored: 1, begun: 1),
          ),
        ),
      );

      expect(output, contains('APPLY STOPPED SAFELY · NO MUTATION RETAINED'));
      expect(output, contains('ROLLBACK VERIFIED'));
      expect(output, contains('No mutation from this run was retained'));
      expect(output, isNot(contains('flutter_pruner rollback')));
      expect(output, isNot(contains('APPLY RECOVERY REQUIRED')));
    });

    test('never lets partial progress hide an internal error', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.internalError,
            partialApplied: true,
            quarantinePath: '/project/.flutter_pruner/quarantine/apply-test',
            outcomes: [_outcome(ApplyFindingOutcomeStatus.committed)],
          ),
        ),
      );

      expect(output, contains('APPLY INTERNAL ERROR'));
      expect(
        output,
        contains('Inspect the terminal diagnostics and quarantine'),
      );
      expect(output, isNot(contains('Inspect the report and diagnostics')));
      expect(output, isNot(contains('APPLY PARTIAL · STOPPED SAFELY')));
    });

    test('uses mutually exclusive outcome counts in the summary', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            outcomes: [
              _outcome(ApplyFindingOutcomeStatus.committed),
              _outcome(ApplyFindingOutcomeStatus.rejectedRecovered),
              _outcome(ApplyFindingOutcomeStatus.remaining),
            ],
            statistics: _statistics(
              committed: 1,
              restored: 1,
              remaining: 3,
              begun: 2,
            ),
          ),
        ),
      );

      expect(
        output,
        contains(
          '1 committed · 1 restored · 1 not applied · 0 recovery attention',
        ),
      );
      expect(output, isNot(contains('3 not applied')));
    });

    test('makes preview readiness and zero mutations explicit', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.dryRun,
            outcomes: [
              _outcome(ApplyFindingOutcomeStatus.remaining),
              _outcome(ApplyFindingOutcomeStatus.blocked),
            ],
          ),
        ),
      );

      expect(
        output,
        contains(
          '1 ready · 1 blocked or retained · 0 files changed · '
          '0 recovery attention',
        ),
      );
      expect(output, contains('READY / BLOCKED (2) · 1 ready · 1 blocked'));
    });

    test('does not call an entirely blocked preview ready', () {
      final output = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.blocked)],
          ),
        ),
      );

      expect(output, contains('APPLY PREVIEW BLOCKED · NO FILES CHANGED'));
      expect(output, isNot(contains('APPLY PREVIEW READY')));
      expect(output, contains('READY / BLOCKED (1) · 1 blocked or retained'));
      expect(
        output,
        contains(
          'Resolve blocked or retained findings before attempting apply.',
        ),
      );
      expect(output, isNot(contains('rerun the reviewed invocation')));
    });

    test(
      'shows a quoted rollback command only for terminal reversible runs',
      () {
        const projectRoot = "/project's root";
        const quarantine = "/project's root/.flutter_pruner/quarantine/run-1";
        final output = _plain(
          const HumanFormatter(lineWidth: 200).format(
            _applyReport(
              projectRoot: projectRoot,
              quarantinePath: quarantine,
              outcomes: [_outcome(ApplyFindingOutcomeStatus.committed)],
              statistics: _statistics(committed: 1, begun: 1),
            ),
          ),
        );

        expect(output, contains('REVERSIBILITY'));
        expect(
          output,
          contains(
            "flutter_pruner 'rollback' '--project' '/project'\"'\"'s root' "
            "'--quarantine' '/project'\"'\"'s root/.flutter_pruner/quarantine' "
            "'apply-test'",
          ),
        );
      },
    );

    test('summarizes verification attempts and preview/no-change evidence', () {
      final verified = _plain(
        const HumanFormatter(lineWidth: 160).format(
          _applyReport(
            attempts: [
              VerificationAttemptReport(
                purpose: VerificationAttemptPurpose.baseline,
                complete: true,
                available: true,
                accepted: true,
                policyHash: 'policy',
                requiredStepIds: ['analyze'],
                observedStepIds: ['analyze'],
                workingDirectory: '/project',
                toolchainIdentity: 'dart',
                steps: [],
                newFailureCount: 0,
                infrastructureFailureCount: 0,
              ),
              VerificationAttemptReport(
                purpose: VerificationAttemptPurpose.candidate,
                round: 1,
                waveId: 'wave-r001',
                transactionId: 'tx-r001-a',
                transactionIds: const ['tx-r001-a'],
                complete: true,
                available: true,
                accepted: false,
                policyHash: 'policy',
                requiredStepIds: ['analyze'],
                observedStepIds: ['analyze'],
                workingDirectory: '/project',
                toolchainIdentity: 'dart',
                steps: [],
                newFailureCount: 1,
                infrastructureFailureCount: 0,
              ),
              VerificationAttemptReport(
                purpose: VerificationAttemptPurpose.rollback,
                complete: false,
                available: false,
                accepted: false,
                policyHash: 'policy',
                requiredStepIds: ['analyze'],
                observedStepIds: [],
                workingDirectory: '/project',
                toolchainIdentity: 'dart',
                steps: [],
                newFailureCount: 0,
                infrastructureFailureCount: 1,
              ),
            ],
          ),
        ),
      );
      final preview = _plain(
        const HumanFormatter().format(_applyReport(status: RunStatus.dryRun)),
      );

      expect(verified, contains('Baseline'));
      expect(verified, contains('Candidate'));
      expect(
        verified,
        contains('wave-r001 · round 1 · 1 transaction(s) · REJECTED'),
      );
      expect(verified, contains('Rollback'));
      expect(verified, contains('APPLY VERIFICATION UNAVAILABLE'));
      expect(verified, contains('ACCEPTED'));
      expect(verified, contains('REJECTED'));
      expect(verified, contains('UNAVAILABLE'));
      expect(
        verified,
        contains(
          'Rollback     UNAVAILABLE · 1 attempted · 0 accepted · '
          '0 rejected · 1 unavailable',
        ),
      );
      expect(preview, contains('Preview only · no verification was run.'));
    });

    test('uses 4, 2, 1 and compact outcome layouts without overflow', () {
      final report = _applyReport(
        status: RunStatus.dryRun,
        outcomes: [
          _outcome(ApplyFindingOutcomeStatus.committed),
          _outcome(ApplyFindingOutcomeStatus.rejectedRecovered),
          _outcome(ApplyFindingOutcomeStatus.remaining),
          _outcome(ApplyFindingOutcomeStatus.recoveryRequired),
        ],
        statistics: _statistics(
          committed: 1,
          restored: 1,
          remaining: 1,
          recoveryRequired: 1,
          begun: 3,
        ),
      );

      final wide = _plain(const HumanFormatter(lineWidth: 200).format(report));
      final medium = _plain(
        const HumanFormatter(lineWidth: 160).format(report),
      );
      final narrow = _plain(const HumanFormatter(lineWidth: 80).format(report));
      final compact = _plain(
        const HumanFormatter(lineWidth: 50).format(report),
      );

      final wideHeader = wide
          .split('\n')
          .firstWhere((line) => line.contains('COMMITTED (1)'));
      expect(wideHeader, contains('RESTORED (1)'));
      expect(wideHeader, contains('READY / BLOCKED (1)'));
      expect(wideHeader, contains('RECOVERY (1)'));
      expect(wide, contains('example_com'));
      expect(wide, contains('mitted.dart'));
      expect(wide, isNot(contains('/project/lib')));
      expect(
        medium.split('\n'),
        contains(
          predicate<String>(
            (line) =>
                line.contains('COMMITTED (1)') && line.contains('RESTORED (1)'),
          ),
        ),
      );
      final narrowHeader = narrow
          .split('\n')
          .firstWhere((line) => line.contains('COMMITTED (1)'));
      expect(narrowHeader, isNot(contains('RESTORED (1)')));
      expect(compact, isNot(contains('┌')));
      expect(compact, contains('READY · PREVIEW ONLY'));

      for (final entry in <int, String>{
        200: wide,
        160: medium,
        80: narrow,
        50: compact,
      }.entries) {
        const metrics = TerminalTextMetrics();
        expect(
          entry.value.split('\n').where((line) => line.isNotEmpty),
          everyElement(
            predicate<String>(
              (line) => metrics.visibleWidth(line) <= entry.key,
            ),
          ),
          reason: 'width ${entry.key}',
        );
      }
    });

    test('keeps the final report callout and exact path on its own line', () {
      const path = '/project/.flutter_pruner/reports/apply report.html';
      final output = _plain(
        const HumanFormatter(
          lineWidth: 50,
          reportPath: path,
          reportFormat: 'html',
        ).format(_applyReport()),
      );

      expect(output, contains('HTML REPORT READY'));
      expect(output.split('\n'), contains(path));
    });

    test('renders no-change outcomes as a concise empty state', () {
      final output = _plain(
        const HumanFormatter(
          lineWidth: 80,
        ).format(_applyReport(status: RunStatus.noChanges)),
      );

      expect(output, contains('No actionable findings were found.'));
      expect(output, isNot(contains('┌')));
    });

    test(
      'renders the initial physical plan and exact preview next command',
      () {
        final output = _plain(
          const _PosixHumanFormatter(lineWidth: 200).format(
            _applyReport(
              status: RunStatus.dryRun,
              outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
              selection: _exactSelection(),
              initialPlan: _initialPhysicalPlan(),
            ),
          ),
        );

        expect(output, contains('INITIAL PHYSICAL PLAN'));
        expect(output, contains('Complete exact selection'));
        expect(output, contains('4 affected files'));
        expect(output, contains('snapshotted before mutation'));
        expect(output, contains('Unit 1 · unit-a'));
        expect(output, contains('Unit 2 · unit-b'));
        expect(
          output.indexOf('Unit 1 · unit-a'),
          lessThan(output.indexOf('Unit 2 · unit-b')),
        );
        expect(output, contains('Clean up import'));
        expect(output, contains('lib/importer.dart'));
        expect(output, contains('lib/dead.dart'));
        expect(output, contains('Delete file'));
        expect(output, contains('resolution variant assets/dead@2x.png'));
        expect(output, contains('generated companion lib/dead.g.dart'));
        expect(output, contains('Remove finding'));
        expect(
          output,
          contains('edit the declaration or delete an empty file'),
        );
        expect(output, contains('BLOCKED · retainedConsumer'));
        expect(output, contains(_exactSelection().actualPreviewFingerprint!));
        expect(
          output,
          contains(
            "flutter_pruner 'apply' '--project' '/project' '--finding-id' "
            "'finding-a' '--finding-id' 'finding-b' "
            "'--expect-preview-fingerprint' "
            "'${_exactSelection().actualPreviewFingerprint}'",
          ),
        );
      },
    );

    test('marks all-eligible plans as initial-round-only without binding', () {
      final output = _plain(
        const _PosixHumanFormatter(lineWidth: 200).format(
          _applyReport(
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
            selection: _allEligibleSelection(),
            initialPlan: _initialPhysicalPlan(
              scope: ApplyInitialPlanScope.initialRoundOnly,
            ),
          ),
        ),
      );

      expect(output, contains('Initial round only'));
      expect(output, contains('later rounds may discover additional work'));
      expect(output, isNot(contains('--expect-preview-fingerprint')));
    });

    test('locks the complete initial physical plan transcript order', () {
      final plan = _initialPhysicalPlan();
      final output = _plain(
        const _PosixHumanFormatter(lineWidth: 200).format(
          _applyReport(
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
            selection: _exactSelection(),
            initialPlan: plan,
          ),
        ),
      );

      expect(
        _initialPlanSection(output),
        'INITIAL PHYSICAL PLAN\n'
        'Complete exact selection · this plan covers the requested batch.\n'
        '4 affected files · sources snapshotted before mutation.\n'
        '\n'
        'Unit 1 · unit-a\n'
        'Clean up import · lib/importer.dart → lib/dead.dart · '
        'stale import in lib/importer.dart\n'
        '\n'
        'Unit 2 · unit-b\n'
        'Depends on unit-a.\n'
        'Delete file · assets/dead@2x.png · '
        'resolution variant assets/dead@2x.png\n'
        'Remove finding · lib/dead.dart · edit the declaration or delete an '
        'empty file only if no retained importer prevents deletion\n'
        'Delete file · lib/dead.g.dart · generated companion lib/dead.g.dart\n'
        '\n'
        'BLOCKED\n'
        'BLOCKED · retainedConsumer · finding-c ← dart:consumer\n'
        'BLOCKED · blockedByRetainedDependency · finding-d ← '
        'dart:lib/retained.dart#consumer\n'
        '\n'
        'PREVIEW FINGERPRINT\n'
        '${plan.preview!.fingerprint}\n'
        '\n'
        'Apply this exact batch only after reviewing the fingerprint:\n'
        'POSIX shell exact batch:\n'
        "flutter_pruner 'apply' '--project' '/project' '--finding-id' "
        "'finding-a' '--finding-id' 'finding-b' "
        "'--expect-preview-fingerprint' '${plan.preview!.fingerprint}'",
      );
    });

    test('uses singular affected-file copy', () {
      final plan = _singleFileInitialPlan();
      final output = _plain(
        const _PosixHumanFormatter(lineWidth: 200).format(
          _applyReport(
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
            selection: _singleFileSelection(plan),
            initialPlan: plan,
          ),
        ),
      );

      expect(output, contains('1 affected file · sources snapshotted'));
      expect(output, isNot(contains('1 affected files')));
    });

    test('labels and quotes hostile exact commands for POSIX shells', () {
      const projectRoot = r"/project & O'Reilly $HOME %PATH%";
      final plan = _initialPhysicalPlan(canonicalProjectRoot: projectRoot);
      final output = _plain(
        const _PosixHumanFormatter(lineWidth: 200).format(
          _applyReport(
            projectRoot: projectRoot,
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
            selection: _exactSelection(plan),
            initialPlan: plan,
          ),
        ),
      );

      expect(output, contains('POSIX shell exact batch:'));
      expect(
        output,
        contains("'--project' '/project & O'\"'\"'Reilly \$HOME %PATH%'"),
      );
      expect(output, isNot(contains('PowerShell exact batch:')));
    });

    test('labels and quotes hostile exact commands for PowerShell', () {
      const projectRoot = r"/project & O'Reilly $HOME %PATH%";
      final plan = _initialPhysicalPlan(canonicalProjectRoot: projectRoot);
      final output = _plain(
        const _WindowsHumanFormatter(lineWidth: 200).format(
          _applyReport(
            projectRoot: projectRoot,
            status: RunStatus.dryRun,
            outcomes: [_outcome(ApplyFindingOutcomeStatus.remaining)],
            selection: _exactSelection(plan),
            initialPlan: plan,
          ),
        ),
      );

      expect(output, contains('PowerShell exact batch:'));
      expect(
        output,
        contains("'--project' '/project & O''Reilly \$HOME %PATH%'"),
      );
      expect(output, isNot(contains('POSIX shell exact batch:')));
    });

    test('uses the real host shell semantics outside the test seam', () {
      expect(const HumanFormatter().usesWindowsShell, Platform.isWindows);
    });
  });
}

RunReport _applyReport({
  RunStatus status = RunStatus.completed,
  int? exitCode,
  bool partialApplied = false,
  String projectRoot = '/project',
  List<ApplyFindingOutcome> outcomes = const [],
  ApplyStatistics? statistics,
  List<VerificationAttemptReport> attempts = const [],
  String? quarantinePath,
  ApplySelectionReport? selection,
  ApplyInitialPlanReport? initialPlan,
  List<RunDiagnostic> diagnostics = const [],
}) => RunReport(
  identity: RunIdentity(
    id: 'apply-test',
    command: RunCommand.apply,
    toolVersion: 'test',
    startedAtUtc: DateTime.utc(2026, 8, 17),
    finishedAtUtc: DateTime.utc(2026, 8, 17, 0, 0, 1),
    elapsedMicros: 1000000,
  ),
  status: status,
  exitCode: exitCode ?? (status == RunStatus.completed ? 0 : 2),
  partialApplied: partialApplied,
  projectRoot: projectRoot,
  canonicalProjectRoot: initialPlan?.preview?.canonicalProjectRoot,
  packageName: 'test',
  requestedAdapters: const ['dart'],
  targetMatrix: TargetMatrix.declared([
    BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    ),
  ]),
  rootCoverage: RootCoverage.applicationApi(),
  analysisPasses: const [],
  findings: outcomes.map((outcome) => outcome.finding).toList(),
  diagnostics: diagnostics,
  verificationAttempts: attempts,
  applyFindingOutcomes: outcomes,
  applySelection: selection,
  applyInitialPlan: initialPlan,
  applyStatistics: statistics ?? ApplyStatistics.empty,
  quarantinePath: quarantinePath,
);

ApplyFindingOutcome _outcome(
  ApplyFindingOutcomeStatus status,
) => ApplyFindingOutcome(
  finding: Finding(
    ruleId: 'PRN-DART-001',
    node: GraphNode(
      id: 'dart:test/lib/src/features/very_long_folder/example.dart#${status.name}',
      kind: NodeKind.declaration,
      origin: Uri.file(
        '/project/lib/src/features/very_long_folder/example_${status.name}.dart',
      ),
      displayName: 'example',
    ),
    confidence: Confidence.safe,
    title: 'Example ${status.name}',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: true,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: true,
    ),
  ),
  status: status,
  reasonCode: status.name,
  reason: 'Outcome reason for ${status.name}.',
  transactionId: switch (status) {
    ApplyFindingOutcomeStatus.committed ||
    ApplyFindingOutcomeStatus.rejectedRecovered ||
    ApplyFindingOutcomeStatus.recoveryRequired => 'transaction-1',
    _ => null,
  },
  rollbackVerified: status == ApplyFindingOutcomeStatus.rejectedRecovered
      ? true
      : null,
);

ApplyStatistics _statistics({
  int committed = 0,
  int restored = 0,
  int blocked = 0,
  int skipped = 0,
  int remaining = 0,
  int recoveryRequired = 0,
  int nonTerminal = 0,
  int begun = 0,
}) => ApplyStatistics(
  rounds: 1,
  findingsCommitted: committed,
  findingsRejectedRecovered: restored,
  findingsBlocked: blocked,
  findingsSkippedDependency: skipped,
  findingsRemaining: remaining,
  actionsDeclared: begun,
  actionsCommitted: committed,
  actionsRolledBack: restored,
  actionsFailedRecovered: restored,
  transactionsBegun: begun,
  transactionsCommitted: committed,
  transactionsRolledBackVerified: restored,
  transactionsRecoveryRequired: recoveryRequired,
  transactionsNonTerminal: nonTerminal,
  verificationAttempts: 0,
  sourceBytesRemoved: 0,
);

String _plain(String value) => value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');

ApplySelectionReport _exactSelection([ApplyInitialPlanReport? plan]) {
  final preview = (plan ?? _initialPhysicalPlan()).preview!;
  return ApplySelectionReport(
    mode: FindingSelectionMode.exact,
    requestedFindingIds: const ['finding-a', 'finding-b'],
    plannedFindingIds: const ['finding-a', 'finding-b'],
    planFingerprint: 'a' * 64,
    actualPreviewFingerprint: preview.fingerprint,
  );
}

ApplySelectionReport _allEligibleSelection() {
  final preview = _initialPhysicalPlan().preview!;
  return ApplySelectionReport(
    mode: FindingSelectionMode.allEligible,
    requestedFindingIds: const [],
    plannedFindingIds: const ['finding-a', 'finding-b'],
    planFingerprint: 'a' * 64,
    actualPreviewFingerprint: preview.fingerprint,
  );
}

ApplyInitialPlanReport _initialPhysicalPlan({
  ApplyInitialPlanScope scope = ApplyInitialPlanScope.completeExactSelection,
  String canonicalProjectRoot = '/project',
}) => ApplyInitialPlanReport(
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
          journalFindingId: 'finding-a@cleanup',
          operation: FindingActionOperation.cleanupImports,
          projectRelativePath: 'lib/importer.dart',
          label: 'stale import in lib/importer.dart',
          countsTowardSummary: false,
          cleanupTargetPath: 'lib/dead.dart',
        ),
      ],
    ),
    ApplyPlanUnitReport(
      order: 1,
      id: 'unit-b',
      findingIds: const ['finding-b'],
      dependencyUnitIds: const ['unit-a'],
      actions: [
        ApplyPlanActionReport(
          order: 0,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b@variant',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'assets/dead@2x.png',
          label: 'resolution variant assets/dead@2x.png',
          countsTowardSummary: false,
        ),
        ApplyPlanActionReport(
          order: 1,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b',
          operation: FindingActionOperation.removeFinding,
          projectRelativePath: 'lib/dead.dart',
          countsTowardSummary: true,
        ),
        ApplyPlanActionReport(
          order: 2,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b@generated',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'lib/dead.g.dart',
          label: 'generated companion lib/dead.g.dart',
          countsTowardSummary: false,
        ),
      ],
    ),
  ],
  blocked: [
    ApplyPlanBlockReport(
      findingId: 'finding-c',
      reason: PlanBlockReason.retainedConsumer,
      blockedBy: 'dart:consumer',
    ),
    ApplyPlanBlockReport(
      findingId: 'finding-d',
      reason: PlanBlockReason.blockedByRetainedDependency,
      blockedBy: 'dart:lib/retained.dart#consumer',
    ),
  ],
  preview: ApplyPreviewReport(
    version: 1,
    canonicalProjectRoot: canonicalProjectRoot,
    planFingerprint: 'a' * 64,
    sources: [
      ApplySourceSnapshotReport(
        projectRelativePath: 'assets/dead@2x.png',
        canonicalPath: '$canonicalProjectRoot/assets/dead@2x.png',
        sha256: '1' * 64,
        sizeBytes: 3,
        posixMode: 420,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/dead.dart',
        canonicalPath: '$canonicalProjectRoot/lib/dead.dart',
        sha256: '2' * 64,
        sizeBytes: 0,
        posixMode: null,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/dead.g.dart',
        canonicalPath: '$canonicalProjectRoot/lib/dead.g.dart',
        sha256: '3' * 64,
        sizeBytes: 9,
        posixMode: 384,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/importer.dart',
        canonicalPath: '$canonicalProjectRoot/lib/importer.dart',
        sha256: '4' * 64,
        sizeBytes: 1,
        posixMode: 420,
      ),
    ],
  ),
);

ApplyInitialPlanReport _singleFileInitialPlan() => ApplyInitialPlanReport(
  canonicalVersion: 1,
  scope: ApplyInitialPlanScope.completeExactSelection,
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
  preview: ApplyPreviewReport(
    version: 1,
    canonicalProjectRoot: '/project',
    planFingerprint: 'a' * 64,
    sources: [
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/a.dart',
        canonicalPath: '/project/lib/a.dart',
        sha256: '1' * 64,
        sizeBytes: 0,
        posixMode: null,
      ),
    ],
  ),
);

ApplySelectionReport _singleFileSelection(ApplyInitialPlanReport plan) =>
    ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a'],
      plannedFindingIds: const ['finding-a'],
      planFingerprint: 'a' * 64,
      actualPreviewFingerprint: plan.preview!.fingerprint,
    );

String _initialPlanSection(String output) {
  const heading = 'INITIAL PHYSICAL PLAN';
  final start = output.indexOf(heading);
  final end = output.indexOf('\nOUTCOMES', start);
  return output.substring(start, end).trimRight();
}

final class _WindowsHumanFormatter extends HumanFormatter {
  const _WindowsHumanFormatter({super.lineWidth});

  @override
  bool get usesWindowsShell => true;
}

final class _PosixHumanFormatter extends HumanFormatter {
  const _PosixHumanFormatter({super.lineWidth});

  @override
  bool get usesWindowsShell => false;
}
