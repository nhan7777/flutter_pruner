import 'package:flutter_pruner/src/cli/formatters/human_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:test/test.dart';

void main() {
  group('HumanFormatter apply presentation', () {
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
            "flutter_pruner rollback --project '/project'\"'\"'s root' "
            "--quarantine '/project'\"'\"'s root/.flutter_pruner/quarantine' "
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
      expect(wide, contains('example_committed.dart'));
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
        expect(
          entry.value.split('\n').where((line) => line.isNotEmpty),
          everyElement(
            predicate<String>((line) => line.runes.length <= entry.key),
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
  });
}

RunReport _applyReport({
  RunStatus status = RunStatus.completed,
  bool partialApplied = false,
  String projectRoot = '/project',
  List<ApplyFindingOutcome> outcomes = const [],
  ApplyStatistics? statistics,
  List<VerificationAttemptReport> attempts = const [],
  String? quarantinePath,
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
  exitCode: status == RunStatus.completed ? 0 : 2,
  partialApplied: partialApplied,
  projectRoot: projectRoot,
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
  diagnostics: const [],
  verificationAttempts: attempts,
  applyFindingOutcomes: outcomes,
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
