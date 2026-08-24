import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _policy = VerificationPolicy(
  commands: [
    VerificationCommand(
      id: 'analyze',
      executable: 'dart',
      arguments: ['analyze'],
    ),
  ],
);

void main() {
  test('accepts existing analyzer failures with shifted line numbers', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:8:2 • old_error
1 issue found. (ran in 1.8s)
''',
    );

    expect(candidate.compareTo(baseline).accepted, isTrue);
  });

  test('accepts an unchanged parsed test failure', () {
    const testFailure = '''
00:00 +0 -1: test/widget_test.dart: smoke [E]
Some tests failed.
''';
    final baseline = _result(
      passed: false,
      output: testFailure,
      parserKind: VerificationOutputParserKind.compactTest,
    );
    final candidate = _result(
      passed: false,
      output: testFailure,
      parserKind: VerificationOutputParserKind.compactTest,
    );

    expect(candidate.compareTo(baseline).accepted, isTrue);
  });

  test('rejects matching empty nonzero exits as unavailable', () {
    final baseline = _result(passed: false, output: '');
    final candidate = _result(passed: false, output: '');

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
    expect(
      comparison.infrastructureFailures.single,
      contains('nonzero exit without stable diagnostic evidence'),
    );
  });

  test('rejects matching generic-only failures as unavailable', () {
    const genericOnly = 'Some tests failed.';
    final baseline = _result(passed: false, output: genericOnly);
    final candidate = _result(passed: false, output: genericOnly);

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
    expect(
      comparison.infrastructureFailures.single,
      contains('nonzero exit without stable diagnostic evidence'),
    );
  });

  test('rejects repeated infrastructure output without a diagnostic', () {
    const infrastructureFailure =
        'Build database lock is held by another process.';
    final baseline = _result(passed: false, output: infrastructureFailure);
    final candidate = _result(passed: false, output: infrastructureFailure);

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
    expect(
      comparison.infrastructureFailures.single,
      contains('nonzero exit without stable diagnostic evidence'),
    );
  });

  test('rejects diagnostic-only output without a completion marker', () {
    const diagnosticOnly =
        'error • Existing failure • lib/a.dart:10:2 • old_error';
    final baseline = _result(passed: false, output: diagnosticOnly);
    final candidate = _result(passed: false, output: diagnosticOnly);

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
  });

  test('rejects machine diagnostics without a true completion marker', () {
    const machineDiagnostic =
        'ERROR|COMPILE_TIME_ERROR|UNDEFINED_METHOD|file:///tmp/a.dart|1|1|1|1|missing';
    final baseline = _result(passed: false, output: machineDiagnostic);
    final candidate = _result(passed: false, output: machineDiagnostic);

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
  });

  test('rejects an analyzer-looking failure from a custom command', () async {
    final policy = VerificationPolicy(
      commands: [
        VerificationCommand(
          id: 'custom-check',
          executable: 'custom-check',
          arguments: [],
        ),
      ],
    );
    final result = await _verifyFailedOutput(policy, '''
error • Mimicked analyzer failure • lib/a.dart:1:1 • fake_error
1 issue found. (ran in 0.1s)
''');

    expect(result.steps.single.parserKind, VerificationOutputParserKind.opaque);
    expect(result.compareTo(result).unavailable, isTrue);
  });

  test(
    'accepts known fvm flutter analyze output with matching count',
    () async {
      final policy = VerificationPolicy(
        commands: [
          VerificationCommand(
            id: 'analyze',
            executable: 'fvm',
            arguments: ['flutter', 'analyze', '--fatal-infos'],
          ),
        ],
      );
      final result = await _verifyFailedOutput(policy, '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''');

      expect(
        result.steps.single.parserKind,
        VerificationOutputParserKind.humanAnalyzer,
      );
      expect(result.compareTo(result).accepted, isTrue);
    },
  );

  test('rejects analyzer output when summary count mismatches diagnostics', () {
    const countMismatch = '''
error • Existing failure • lib/a.dart:10:2 • old_error
error • Existing failure • lib/b.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''';
    final result = _result(passed: false, output: countMismatch);

    expect(result.compareTo(result).unavailable, isTrue);
  });

  test('accepts known flutter test compact output', () async {
    final policy = VerificationPolicy(
      commands: [
        VerificationCommand(
          id: 'test',
          executable: 'flutter',
          arguments: ['test'],
        ),
      ],
    );
    final result = await _verifyFailedOutput(policy, '''
00:00 +0 -1: test/widget_test.dart: smoke [E]
Some tests failed.
''');

    expect(
      result.steps.single.parserKind,
      VerificationOutputParserKind.compactTest,
    );
    expect(result.compareTo(result).accepted, isTrue);
  });

  test('rejects a partial diagnostic output after a complete baseline', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
error • Existing failure • lib/b.dart:10:2 • old_error
2 issues found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: 'error • Existing failure • lib/a.dart:8:2 • old_error',
    );

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
  });

  test('accepts a complete unchanged diagnostic multiset', () {
    const output = '''
error • Existing failure • lib/a.dart:10:2 • old_error
error • Existing failure • lib/b.dart:10:2 • old_error
2 issues found. (ran in 2.4s)
''';
    final baseline = _result(passed: false, output: output);
    final candidate = _result(passed: false, output: output);

    expect(candidate.compareTo(baseline).accepted, isTrue);
  });

  test('rejects a diagnostic introduced after one case', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:8:2 • old_error
error • New failure • lib/b.dart:3:1 • new_error
2 issues found. (ran in 2.4s)
''',
    );

    final comparison = candidate.compareTo(baseline);
    expect(comparison.accepted, isFalse);
    expect(comparison.newFailures.single, contains('new_error'));
  });

  test('rejects an additional occurrence of an existing diagnostic', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:8:2 • old_error
error • Existing failure • lib/a.dart:21:2 • old_error
2 issues found.
''',
    );

    final comparison = candidate.compareTo(baseline);
    expect(comparison.accepted, isFalse);
    expect(comparison.newFailures, hasLength(1));
    expect(comparison.newFailures.single, contains('old_error'));
  });

  test('round-trips sanitized baseline-red evidence without raw output', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );

    final encoded = jsonEncode(baseline.toBaselineEvidence().toJson());
    final restored = VerificationBaselineEvidence.fromJson(
      Map<String, Object?>.from(jsonDecode(encoded) as Map),
    );
    final step = restored.steps.single;

    expect(encoded, isNot(contains('Existing failure')));
    expect(step.fingerprintDigests.keys.single, hasLength(64));
    expect(
      () => step.fingerprintDigests['not-allowed'] = 1,
      throwsUnsupportedError,
    );
    expect(baseline.compareToBaselineEvidence(restored).accepted, isTrue);
  });

  test('accepted stored-baseline comparison carries canonical evidence', () {
    final baseline = _result(passed: true, output: '').toBaselineEvidence();
    final candidate = _result(passed: true, output: '');

    final comparison = candidate.compareToBaselineEvidence(baseline);
    final accepted = comparison.acceptedEvidence!;

    expect(comparison.accepted, isTrue);
    expect(
      accepted.comparisonBaselineSha256,
      sha256.convert(utf8.encode(jsonEncode(baseline.toJson()))).toString(),
    );
    expect(
      accepted.candidateEvidence.toJson(),
      candidate.toBaselineEvidence().toJson(),
    );
    expect(
      verificationBaselineEvidenceSha256(baseline),
      accepted.comparisonBaselineSha256,
    );
  });

  test('rejected stored-baseline comparison carries no accepted evidence', () {
    final baseline = _result(passed: true, output: '').toBaselineEvidence();
    final candidate = _result(
      passed: false,
      output: '''
error • New failure • lib/a.dart:10:2 • new_error
1 issue found.
''',
    );

    final comparison = candidate.compareToBaselineEvidence(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.acceptedEvidence, isNull);
  });

  test('accepts fewer completed baseline-red diagnostics from evidence', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
error • Existing failure • lib/b.dart:10:2 • old_error
2 issues found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:8:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );

    expect(
      candidate
          .compareToBaselineEvidence(baseline.toBaselineEvidence())
          .accepted,
      isTrue,
    );
  });

  test('rejects an added fingerprint occurrence from stored evidence', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );
    final candidate = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:8:2 • old_error
error • Existing failure • lib/a.dart:21:2 • old_error
2 issues found. (ran in 2.4s)
''',
    );

    final comparison = candidate.compareToBaselineEvidence(
      baseline.toBaselineEvidence(),
    );

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isFalse);
    expect(comparison.newFailures.single, contains('fingerprint'));
  });

  test(
    'rejects partial or missing candidate evidence against stored baseline',
    () {
      final baseline = _result(
        passed: false,
        output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
      ).toBaselineEvidence();
      final partial = _result(
        passed: false,
        output: 'error • Existing failure • lib/a.dart:8:2 • old_error',
      );
      final missing = VerificationResult(
        passed: false,
        steps: const [],
        failedStep: null,
        policyHash: _policy.hash,
        requiredStepIds: _policy.requiredStepIds,
        requiredParserKinds: _policy.requiredParserKinds,
        workingDirectory: '/workspace/test',
        toolchainIdentity: 'test-toolchain',
      );

      expect(partial.compareToBaselineEvidence(baseline).unavailable, isTrue);
      expect(missing.compareToBaselineEvidence(baseline).unavailable, isTrue);
    },
  );

  test('rejects parser mismatch against stored baseline evidence', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    ).toBaselineEvidence();
    final candidate = _result(
      passed: false,
      output: '''
00:00 +0 -1: test/widget_test.dart: smoke [E]
Some tests failed.
''',
      parserKind: VerificationOutputParserKind.compactTest,
    );

    final comparison = candidate.compareToBaselineEvidence(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
  });

  test('requires a current pass when stored baseline passed', () {
    final baseline = _result(passed: true, output: '').toBaselineEvidence();
    final candidate = _result(
      passed: false,
      output: '''
error • New failure • lib/a.dart:10:2 • new_error
1 issue found. (ran in 2.4s)
''',
    );

    final comparison = candidate.compareToBaselineEvidence(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isFalse);
    expect(
      comparison.newFailures,
      contains('analyze: command changed from pass to fail'),
    );
  });

  test(
    'timeout kills verifier child and grandchild before returning',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'verification_process_tree_',
      );
      try {
        final parentScript = File(p.join(project.path, 'parent.dart'));
        final childScript = File(p.join(project.path, 'child.dart'));
        final grandchildScript = File(p.join(project.path, 'grandchild.dart'));
        final ready = File(p.join(project.path, 'child-ready'));
        final childSurvived = File(p.join(project.path, 'child-survived'));
        final grandchildSurvived = File(
          p.join(project.path, 'grandchild-survived'),
        );
        parentScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [
      arguments[0],
      arguments[1],
      arguments[2],
      arguments[3],
      arguments[4],
    ],
  );
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
        childScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[3]],
  );
  File(arguments[1]).writeAsStringSync('ready');
  await Future<void>.delayed(const Duration(seconds: 6));
  File(arguments[2]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
        grandchildScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Future<void>.delayed(const Duration(seconds: 6));
  File(arguments.single).writeAsStringSync('survived');
}
''');
        final policy = VerificationPolicy(
          commands: [
            VerificationCommand(
              id: 'process-tree',
              executable: Platform.resolvedExecutable,
              arguments: [
                parentScript.path,
                childScript.path,
                grandchildScript.path,
                ready.path,
                childSurvived.path,
                grandchildSurvived.path,
              ],
            ),
          ],
        );

        final result = await VerificationRunner(
          project,
        ).verify(policy: policy, timeout: const Duration(seconds: 3));

        expect(result.passed, isFalse);
        expect(result.steps.single.exitCode, -1);
        expect(result.steps.single.stderr, contains('Timed out after 3000ms'));
        expect(ready.existsSync(), isTrue);
        await Future<void>.delayed(const Duration(seconds: 6));
        expect(childSurvived.existsSync(), isFalse);
        expect(grandchildSurvived.existsSync(), isFalse);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test('treats a verification process failure as unavailable', () {
    final baseline = _result(passed: true, output: '');
    final candidate = VerificationResult(
      passed: false,
      steps: const [
        VerificationStep(
          name: 'analyze',
          passed: false,
          exitCode: -1,
          stdout: '',
          stderr: 'Timed out',
          duration: Duration(seconds: 5),
        ),
      ],
      failedStep: 'analyze',
      policyHash: _policy.hash,
      requiredStepIds: _policy.requiredStepIds,
      workingDirectory: '/workspace/test',
      toolchainIdentity: 'test-toolchain',
    );

    expect(candidate.compareTo(baseline).unavailable, isTrue);
  });

  test('marks truncated verifier output as unavailable', () async {
    final project = Directory.systemTemp.createTempSync('verification_output_');
    try {
      final runner = VerificationRunner(
        project,
        processRunner: const _TruncatingRunner(),
      );

      final candidate = await runner.verify(policy: _policy);
      final baseline = _result(passed: true, output: '');

      expect(candidate.steps.single.exitCode, -1);
      expect(candidate.steps.single.stderr, contains('bounded capture limit'));
      expect(candidate.compareTo(baseline).unavailable, isTrue);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test('treats a missing required step as unavailable', () {
    final baseline = _result(passed: true, output: '');
    final candidate = VerificationResult(
      passed: true,
      steps: baseline.steps,
      failedStep: null,
      policyHash: baseline.policyHash,
      requiredStepIds: const ['analyze', 'test'],
      workingDirectory: baseline.workingDirectory,
      toolchainIdentity: baseline.toolchainIdentity,
    );

    expect(candidate.compareTo(baseline).unavailable, isTrue);
  });

  test('rejects policy, working-directory, and toolchain mismatches', () {
    final baseline = _result(passed: true, output: '');
    final candidate = VerificationResult(
      passed: true,
      steps: baseline.steps,
      failedStep: null,
      policyHash: 'different-policy',
      requiredStepIds: baseline.requiredStepIds,
      workingDirectory: '/different/project',
      toolchainIdentity: 'different-toolchain',
    );

    final comparison = candidate.compareTo(baseline);
    expect(comparison.unavailable, isTrue);
    expect(comparison.infrastructureFailures, hasLength(3));
  });

  test('re-probes toolchain identity for every verification attempt', () async {
    final project = Directory.systemTemp.createTempSync(
      'verification_toolchain_',
    );
    try {
      final processRunner = _ChangingVersionRunner();
      final runner = VerificationRunner(project, processRunner: processRunner);

      final baseline = await runner.verify(policy: _policy);
      final candidate = await runner.verify(policy: _policy);

      expect(processRunner.versionProbeCount, 2);
      expect(candidate.toolchainIdentity, isNot(baseline.toolchainIdentity));
      expect(candidate.compareTo(baseline).unavailable, isTrue);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test('rejects a changed parser contract for the same step ID', () {
    final baseline = _result(
      passed: false,
      output: '''
error • Existing failure • lib/a.dart:10:2 • old_error
1 issue found. (ran in 2.4s)
''',
    );
    final candidate = VerificationResult(
      passed: false,
      steps: baseline.steps,
      failedStep: baseline.failedStep,
      policyHash: baseline.policyHash,
      requiredStepIds: baseline.requiredStepIds,
      requiredParserKinds: const [VerificationOutputParserKind.opaque],
      workingDirectory: baseline.workingDirectory,
      toolchainIdentity: baseline.toolchainIdentity,
    );

    final comparison = candidate.compareTo(baseline);

    expect(comparison.accepted, isFalse);
    expect(comparison.unavailable, isTrue);
    expect(
      comparison.infrastructureFailures,
      contains('verification output parser contract does not match baseline'),
    );
  });
}

VerificationResult _result({
  required bool passed,
  required String output,
  VerificationOutputParserKind parserKind =
      VerificationOutputParserKind.humanAnalyzer,
}) {
  return VerificationResult(
    passed: passed,
    steps: [
      VerificationStep(
        name: 'analyze',
        parserKind: parserKind,
        passed: passed,
        exitCode: passed ? 0 : 1,
        stdout: output,
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    failedStep: passed ? null : 'analyze',
    policyHash: _policy.hash,
    requiredStepIds: _policy.requiredStepIds,
    requiredParserKinds: [parserKind],
    workingDirectory: '/workspace/test',
    toolchainIdentity: 'test-toolchain',
  );
}

class _TruncatingRunner implements ProcessExecutionRunner {
  const _TruncatingRunner();

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    final output = arguments.single == '--version'
        ? const BoundedProcessOutput(
            text: 'tool 1.0',
            capturedBytes: 8,
            omittedBytes: 0,
          )
        : const BoundedProcessOutput(
            text: 'partial failure',
            capturedBytes: 15,
            omittedBytes: 1,
          );
    return ManagedProcessResult(
      exitCode: arguments.single == '--version' ? 0 : 1,
      stdout: output,
      stderr: const BoundedProcessOutput(
        text: '',
        capturedBytes: 0,
        omittedBytes: 0,
      ),
    );
  }
}

Future<VerificationResult> _verifyFailedOutput(
  VerificationPolicy policy,
  String output,
) async {
  final project = Directory.systemTemp.createTempSync('verification_parser_');
  try {
    return await VerificationRunner(
      project,
      processRunner: _FixedOutputRunner(output),
    ).verify(policy: policy);
  } finally {
    if (project.existsSync()) project.deleteSync(recursive: true);
  }
}

class _FixedOutputRunner implements ProcessExecutionRunner {
  const _FixedOutputRunner(this.output);

  final String output;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    final isVersionProbe =
        arguments.length == 1 && arguments.single == '--version';
    final text = isVersionProbe ? 'tool 1.0' : output;
    return ManagedProcessResult(
      exitCode: isVersionProbe ? 0 : 1,
      stdout: BoundedProcessOutput(
        text: text,
        capturedBytes: text.length,
        omittedBytes: 0,
      ),
      stderr: const BoundedProcessOutput(
        text: '',
        capturedBytes: 0,
        omittedBytes: 0,
      ),
    );
  }
}

class _ChangingVersionRunner implements ProcessExecutionRunner {
  var versionProbeCount = 0;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    final isVersionProbe =
        arguments.length == 1 && arguments.single == '--version';
    final output = isVersionProbe
        ? 'tool ${++versionProbeCount}.0'
        : 'No issues found!';
    return ManagedProcessResult(
      exitCode: 0,
      stdout: BoundedProcessOutput(
        text: output,
        capturedBytes: output.length,
        omittedBytes: 0,
      ),
      stderr: const BoundedProcessOutput(
        text: '',
        capturedBytes: 0,
        omittedBytes: 0,
      ),
    );
  }
}
