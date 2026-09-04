import 'package:flutter_pruner/src/cli/confirmation_prompt.dart';
import 'package:flutter_pruner/src/cli/formatters/quarantine_formatter.dart';
import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_executor.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:test/test.dart';

void main() {
  group('CleanAllConfirmation', () {
    const fingerprint =
        'v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

    test(
      'requires the exact target count and first 12 digest hex characters',
      () {
        expect(
          CleanAllConfirmation.requiredPhrase(
            targetCount: 3,
            fingerprint: fingerprint,
          ),
          'clean-all 3 0123456789ab',
        );
        expect(
          CleanAllConfirmation.matches(
            input: 'clean-all 3 0123456789ab',
            targetCount: 3,
            fingerprint: fingerprint,
          ),
          isTrue,
        );
      },
    );

    test(
      'rejects generic assent, whitespace changes, blank input, and EOF',
      () {
        for (final input in <String?>[
          'y',
          'yes',
          '',
          null,
          ' clean-all 3 0123456789ab',
          'clean-all 3 0123456789ab ',
          'clean-all 2 0123456789ab',
          'clean-all 3 0123456789ac',
        ]) {
          expect(
            CleanAllConfirmation.matches(
              input: input,
              targetCount: 3,
              fingerprint: fingerprint,
            ),
            isFalse,
            reason: '$input',
          );
        }
      },
    );

    test('accepts complete lowercase versioned fingerprint proof tokens', () {
      expect(CleanAllConfirmation.isValidFingerprint(fingerprint), isTrue);
      expect(
        CleanAllConfirmation.isValidFingerprint(
          'v2:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        ),
        isTrue,
      );
      for (final value in <String?>[
        null,
        '',
        'v1:0123456789ab',
        'v0:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        'v1:0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef',
        'v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdeg',
      ]) {
        expect(
          CleanAllConfirmation.isValidFingerprint(value),
          isFalse,
          reason: '$value',
        );
      }
    });
  });

  test('clean result retains an immutable ordered current-process receipt', () {
    final source = <QuarantineCleanTargetOutcome>[
      const QuarantineCleanTargetOutcome(
        runId: 'removed-run',
        canonicalPath: '/quarantine/removed-run',
        state: QuarantineCleanTargetState.removed,
      ),
      const QuarantineCleanTargetOutcome(
        runId: 'unknown-run',
        canonicalPath: '/quarantine/unknown-run',
        state: QuarantineCleanTargetState.outcomeUnknown,
        failureCode: 'delete_failed',
        failureMessage: 'Delete failed after the deletion boundary.',
      ),
      const QuarantineCleanTargetOutcome(
        runId: 'remaining-run',
        canonicalPath: '/quarantine/remaining-run',
        state: QuarantineCleanTargetState.notAttempted,
      ),
    ];
    final result = QuarantineCleanResult(
      fingerprint:
          'v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      deletionAttempted: true,
      outcomes: source,
      failureCode: 'delete_failed',
      failureMessage: 'The receipt is incomplete.',
    );

    source.clear();
    expect(
      result.outcomes.map((outcome) => outcome.state),
      <QuarantineCleanTargetState>[
        QuarantineCleanTargetState.removed,
        QuarantineCleanTargetState.outcomeUnknown,
        QuarantineCleanTargetState.notAttempted,
      ],
    );
    expect(
      () => result.outcomes.add(
        const QuarantineCleanTargetOutcome(
          runId: 'forged',
          canonicalPath: '/forged',
          state: QuarantineCleanTargetState.removed,
        ),
      ),
      throwsUnsupportedError,
    );
  });

  test('clean result rejects false deletion-boundary claims', () {
    const fingerprint =
        'v1:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
    const removed = QuarantineCleanTargetOutcome(
      runId: 'removed',
      canonicalPath: '/removed',
      state: QuarantineCleanTargetState.removed,
    );
    const unknown = QuarantineCleanTargetOutcome(
      runId: 'unknown',
      canonicalPath: '/unknown',
      state: QuarantineCleanTargetState.outcomeUnknown,
      failureCode: 'delete_failed',
      failureMessage: 'Delete failed.',
    );
    const preserved = QuarantineCleanTargetOutcome(
      runId: 'preserved',
      canonicalPath: '/preserved',
      state: QuarantineCleanTargetState.preserved,
      failureCode: 'validation_failed',
      failureMessage: 'Validation failed.',
    );

    expect(
      () => QuarantineCleanResult(
        fingerprint: fingerprint,
        deletionAttempted: false,
        outcomes: const [removed],
      ),
      throwsArgumentError,
    );
    expect(
      () => QuarantineCleanResult(
        fingerprint: fingerprint,
        deletionAttempted: false,
        outcomes: const [unknown],
        failureCode: 'delete_failed',
        failureMessage: 'Delete failed.',
      ),
      throwsArgumentError,
    );
    expect(
      () => QuarantineCleanResult(
        fingerprint: fingerprint,
        deletionAttempted: true,
        outcomes: const [preserved],
        failureCode: 'validation_failed',
        failureMessage: 'Validation failed.',
      ),
      throwsArgumentError,
    );
  });

  test('clean human projections escape every untrusted text field in full', () {
    const hostileSuffix = '\x1b[31m\x1b[2J\u009b31m\u202e\u2028';
    const visibleSuffix = r'\x1B[31m\x1B[2J\u009B31m\u202E\u2028';
    const planBase = 'plan-base$hostileSuffix';
    const planBackend = 'plan-backend$hostileSuffix';
    const planBlocker = 'plan-blocker$hostileSuffix';
    const planRunId = 'plan-run-id$hostileSuffix';
    const planPath = 'plan-path$hostileSuffix';
    const resultRunId = 'result-run-id$hostileSuffix';
    const resultPath = 'result-path$hostileSuffix';
    const resultFailureCode = 'result-failure-code$hostileSuffix';
    const resultFailureMessage = 'result-failure-message$hostileSuffix';
    const resultFingerprint = 'result-fingerprint$hostileSuffix';
    final unsafe = RegExp(
      r'[\x00-\x09\x0B-\x1F\x7F-\x9F\u061C\u200E\u200F\u2028\u2029\u202A-\u202E\u2066-\u2069]',
    );
    final plan = QuarantineCleanPlan.fromEvidence(
      scope: CleanScope.all,
      canonicalBases: const <String>[planBase],
      targets: const <QuarantineCleanTarget>[
        QuarantineCleanTarget(
          runId: planRunId,
          canonicalPath: planPath,
          layoutSha256: 'layout',
          journalRevision: 1,
          payloadSha256: 'payload',
          authority: ManifestCandidateName.primary,
          repairAction: ManifestRepairAction.none,
        ),
      ],
      backend: const CleanBackendDisclosure(
        name: planBackend,
        batchAtomic: false,
        identityBoundDelete: false,
        crashRecoverableReceipt: false,
        releaseEligible: false,
        blockerCode: planBlocker,
      ),
    );
    final result = QuarantineCleanResult(
      fingerprint: resultFingerprint,
      deletionAttempted: false,
      outcomes: const <QuarantineCleanTargetOutcome>[
        QuarantineCleanTargetOutcome(
          runId: resultRunId,
          canonicalPath: resultPath,
          state: QuarantineCleanTargetState.preserved,
          failureCode: resultFailureCode,
          failureMessage: resultFailureMessage,
        ),
      ],
    );

    final planHuman = QuarantineFormatter.formatCleanPlanHuman(plan);
    final resultHuman = QuarantineFormatter.formatCleanResultHuman(result);

    const metrics = TerminalTextMetrics();
    final renderedPlan = _stripAnsi(planHuman);
    final renderedResult = _stripAnsi(resultHuman);
    for (final raw in <String>[
      planBase,
      planBackend,
      planBlocker,
      planRunId,
      planPath,
    ]) {
      expect(planHuman, isNot(contains(raw)), reason: raw);
    }
    for (final raw in <String>[
      resultRunId,
      resultPath,
      resultFailureCode,
      resultFailureMessage,
      resultFingerprint,
    ]) {
      expect(resultHuman, isNot(contains(raw)), reason: raw);
    }
    for (final raw in <String>[planHuman, resultHuman]) {
      // Formatter-owned styles are allowed, but untrusted valid SGR/CSI/C1
      // sequences must be escaped before ANSI is stripped for assertions.
      expect(raw, isNot(contains('\x1b[31m')));
      expect(raw, isNot(contains('\x1b[2J')));
      expect(raw, isNot(contains('\u009b31m')));
    }
    for (final rendered in <String>[renderedPlan, renderedResult]) {
      expect(rendered, isNot(contains(unsafe)));
      expect(
        rendered.split('\n').where((line) => line.isNotEmpty),
        everyElement(
          predicate<String>((line) => metrics.visibleWidth(line) <= 160),
        ),
      );
    }
    final logicalPlan = renderedPlan.replaceAll('\n', '');
    final logicalResult = renderedResult.replaceAll('\n', '');
    _expectExactlyOnce(
      logicalPlan,
      '  Canonical base: plan-base$visibleSuffix',
      'canonical base',
    );
    _expectExactlyOnce(
      logicalPlan,
      '  Backend: plan-backend$visibleSuffix',
      'backend',
    );
    _expectExactlyOnce(
      logicalPlan,
      '! Blocker: plan-blocker$visibleSuffix',
      'blocker',
    );
    _expectExactlyOnce(logicalPlan, '  1. plan-run-id$visibleSuffix', 'run ID');
    _expectExactlyOnce(
      logicalPlan,
      '     Path: plan-path$visibleSuffix',
      'target path',
    );
    _expectExactlyOnce(
      logicalResult,
      '  Preserved: result-run-id$visibleSuffix',
      'outcome run ID',
    );
    _expectExactlyOnce(
      logicalResult,
      '  Path: result-path$visibleSuffix',
      'outcome path',
    );
    _expectExactlyOnce(
      logicalResult,
      '  Failure: result-failure-code$visibleSuffix — '
          'result-failure-message$visibleSuffix',
      'outcome failure',
    );
    _expectExactlyOnce(
      logicalResult,
      '  Fingerprint: result-fingerprint$visibleSuffix',
      'fingerprint',
    );
  });
}

void _expectExactlyOnce(String rendered, String value, String lane) {
  expect(
    RegExp(RegExp.escape(value)).allMatches(rendered),
    hasLength(1),
    reason: '$lane must retain its own complete terminal-safe value once',
  );
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '');
