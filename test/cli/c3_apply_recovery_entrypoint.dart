import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/apply_command.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';

/// Test-only process entrypoint for real ApplyCommand recovery rendering.
///
/// The queued verifier supplies coherent baseline/candidate/rollback evidence;
/// ApplyCommand still owns mutation, rollback journaling, and terminal copy.
Future<void> main(List<String> arguments) async {
  exit(
    await FlutterPrunerCommandRunner(
      applyCommandFactory: () =>
          ApplyCommand(verifierFactory: (project) => _QueuedVerifier(project)),
    ).run(arguments),
  );
}

final class _QueuedVerifier extends VerificationRunner {
  _QueuedVerifier(super.projectRoot);

  var _index = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    final passed = _index++ == 0;
    return VerificationResult(
      passed: passed,
      steps: <VerificationStep>[
        VerificationStep(
          name: 'flutter-analyze',
          parserKind: VerificationOutputParserKind.humanAnalyzer,
          passed: passed,
          exitCode: passed ? 0 : 1,
          stdout: passed
              ? ''
              : 'error: C3 recovery verifier failure\n1 issue found.',
          stderr: '',
          duration: Duration.zero,
        ),
        const VerificationStep(
          name: 'flutter-test',
          parserKind: VerificationOutputParserKind.compactTest,
          passed: true,
          exitCode: 0,
          stdout: '',
          stderr: '',
          duration: Duration.zero,
        ),
      ],
      failedStep: passed ? null : 'flutter-analyze',
      policyHash: VerificationPolicy.flutterDefault.hash,
      requiredStepIds: VerificationPolicy.flutterDefault.requiredStepIds,
      requiredParserKinds:
          VerificationPolicy.flutterDefault.requiredParserKinds,
      workingDirectory: projectRoot.absolute.path,
      toolchainIdentity: 'c3-test-toolchain',
    );
  }
}
