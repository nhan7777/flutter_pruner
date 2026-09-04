import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../core/process/managed_process_runner.dart';
import 'verification_policy.dart';

/// Runs verification steps after applying changes.
///
/// Executes the project's argv-only policy. Apply compares each complete result
/// to an accumulated baseline and rolls back the entire atomic unit on failure.
class VerificationRunner {
  /// Creates a verification runner for [projectRoot].
  VerificationRunner(
    this.projectRoot, {
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
  }) : _processRunner = processRunner;

  /// Project root directory.
  final Directory projectRoot;

  /// Default timeout for each verification step.
  static const Duration defaultTimeout = Duration(minutes: 5);

  static const int _maxOutputBytesPerStream = 4 * 1024 * 1024;

  final ProcessExecutionRunner _processRunner;

  /// Runs every command required by [policy].
  ///
  /// Returns [VerificationResult] indicating success or failure.
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = defaultTimeout,
  }) async {
    final steps = <VerificationStep>[];
    for (final command in policy.commands) {
      steps.add(await _runCommand(command, timeout));
    }

    final failedSteps = steps.where((step) => !step.passed);
    final workingDirectory = p.normalize(p.absolute(projectRoot.path));
    final toolchainIdentity = await _resolveToolchainIdentity(policy);
    return VerificationResult(
      passed: failedSteps.isEmpty,
      steps: steps,
      failedStep: failedSteps.isEmpty ? null : failedSteps.first.name,
      policyHash: policy.hash,
      requiredStepIds: policy.requiredStepIds,
      requiredParserKinds: policy.requiredParserKinds,
      workingDirectory: workingDirectory,
      toolchainIdentity: toolchainIdentity,
    );
  }

  /// Runs verification for recovery workflows and preserves an unconfirmed
  /// process-tree outcome as a distinct, non-retryable failure.
  Future<VerificationResult> verifyForRecovery({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = defaultTimeout,
  }) async {
    try {
      return await verify(policy: policy, timeout: timeout);
    } on ProcessTerminationUnconfirmedException catch (error) {
      throw VerificationTerminationUnconfirmedException(
        processId: error.processId,
        message: error.message,
      );
    }
  }

  Future<String> _resolveToolchainIdentity(VerificationPolicy policy) async {
    final evidence = <String>[];
    for (final executable
        in policy.commands.map((command) => command.executable).toSet()) {
      try {
        final result = await _executeProcess(executable, const [
          '--version',
        ], timeout: defaultTimeout);
        evidence.add(
          '$executable\u0000${result.exitCode}\u0000'
          '${result.stdout.text}\u0000${result.stderr.text}',
        );
      } on ProcessCancellationBeforeLaunchException {
        rethrow;
      } on ProcessCancellationConfirmedException {
        rethrow;
      } on ProcessTerminationUnconfirmedException {
        rethrow;
      } catch (error) {
        evidence.add('$executable\u0000unavailable\u0000$error');
      }
    }
    evidence.sort();
    return sha256.convert(evidence.join('\u0001').codeUnits).toString();
  }

  Future<VerificationStep> _runCommand(
    VerificationCommand command,
    Duration timeout,
  ) async {
    final stopwatch = Stopwatch()..start();

    try {
      final result = await _executeProcess(
        command.executable,
        command.arguments,
        timeout: timeout,
      );

      return VerificationStep(
        name: command.id,
        parserKind: command.parserKind,
        passed:
            !result.timedOut && !result.outputTruncated && result.exitCode == 0,
        exitCode: result.outputTruncated ? -1 : result.exitCode,
        stdout: result.stdout.text,
        stderr: result.outputTruncated
            ? [
                result.stderr.text.trim(),
                'Verification output exceeded the bounded capture limit.',
              ].where((line) => line.isNotEmpty).join('\n')
            : result.timedOut
            ? [
                result.stderr.text.trim(),
                'Timed out after ${timeout.inMilliseconds}ms',
              ].where((line) => line.isNotEmpty).join('\n')
            : result.stderr.text,
        duration: stopwatch.elapsed,
      );
    } on ProcessCancellationBeforeLaunchException {
      rethrow;
    } on ProcessCancellationConfirmedException {
      rethrow;
    } on ProcessTerminationUnconfirmedException {
      rethrow;
    } catch (e) {
      return VerificationStep(
        name: command.id,
        parserKind: command.parserKind,
        passed: false,
        exitCode: -1,
        stdout: '',
        stderr: 'Failed to run: $e',
        duration: stopwatch.elapsed,
      );
    }
  }

  /// Checks if Flutter CLI is available.
  Future<bool> isFlutterAvailable() async {
    try {
      final result = await _executeProcess('flutter', const [
        '--version',
      ], timeout: defaultTimeout);
      return !result.timedOut &&
          !result.outputTruncated &&
          result.exitCode == 0;
    } on ProcessCancellationBeforeLaunchException {
      rethrow;
    } on ProcessCancellationConfirmedException {
      rethrow;
    } on ProcessTerminationUnconfirmedException {
      rethrow;
    } catch (e) {
      return false;
    }
  }

  Future<ManagedProcessResult> _executeProcess(
    String executable,
    List<String> arguments, {
    required Duration timeout,
  }) {
    return _processRunner.run(
      executable,
      arguments,
      workingDirectory: projectRoot.path,
      timeout: timeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
    );
  }
}

/// Signals that a recovery verifier process tree may still be alive.
final class VerificationTerminationUnconfirmedException implements Exception {
  /// Creates an unconfirmed recovery-verifier outcome.
  const VerificationTerminationUnconfirmedException({
    required this.processId,
    required this.message,
  });

  /// Root verifier process identifier.
  final int processId;

  /// Sanitized diagnostic supplied by the managed process runner.
  final String message;

  @override
  String toString() => message;
}

/// Result of running verification steps.
class VerificationResult {
  /// Creates a verification result.
  const VerificationResult({
    required this.passed,
    required this.steps,
    required this.failedStep,
    required this.policyHash,
    required this.requiredStepIds,
    this.requiredParserKinds = const [],
    required this.workingDirectory,
    required this.toolchainIdentity,
  });

  /// Whether all steps passed.
  final bool passed;

  /// Individual verification steps.
  final List<VerificationStep> steps;

  /// Name of first failed step, or null if all passed.
  final String? failedStep;

  /// Hash of the exact command policy used for this result.
  final String policyHash;

  /// Stable command IDs that were required to run.
  final List<String> requiredStepIds;

  /// Parser contracts expected for [requiredStepIds], in the same order.
  ///
  /// Empty is retained for direct test construction; production results always
  /// receive this from [VerificationPolicy].
  final List<VerificationOutputParserKind> requiredParserKinds;

  /// Normalized directory in which every verifier command ran.
  final String workingDirectory;

  /// Hash of executable version probes for this verifier session.
  final String toolchainIdentity;

  /// Total duration of all steps.
  Duration get totalDuration =>
      steps.fold(Duration.zero, (sum, step) => sum + step.duration);

  /// Whether every verification process executed and returned an exit code.
  bool get isComplete {
    if (requiredStepIds.isEmpty || steps.length != requiredStepIds.length) {
      return false;
    }
    if (requiredStepIds.toSet().length != requiredStepIds.length) return false;
    final actual = steps.map((step) => step.name).toList();
    if (actual.toSet().length != actual.length ||
        !actual.toSet().containsAll(requiredStepIds) ||
        !requiredStepIds.toSet().containsAll(actual)) {
      return false;
    }
    final expectedParserKinds = requiredParserKinds.isEmpty
        ? steps.map((step) => step.parserKind).toList(growable: false)
        : requiredParserKinds;
    if (expectedParserKinds.length != requiredStepIds.length) return false;
    final parserKindByStep = {
      for (final step in steps) step.name: step.parserKind,
    };
    for (var index = 0; index < requiredStepIds.length; index++) {
      if (parserKindByStep[requiredStepIds[index]] !=
          expectedParserKinds[index]) {
        return false;
      }
    }
    return true;
  }

  /// Whether every required process ran and returned an exit code.
  bool get isAvailable =>
      isComplete && steps.every((step) => step.exitCode >= 0);

  /// Produces immutable, serializable baseline evidence without raw verifier
  /// output. Persist this instead of stdout/stderr for a later rollback check.
  VerificationBaselineEvidence toBaselineEvidence() {
    final parserKinds = _effectiveParserKinds;
    return VerificationBaselineEvidence(
      policyHash: policyHash,
      requiredStepIds: requiredStepIds,
      requiredParserKinds: parserKinds,
      workingDirectory: workingDirectory,
      toolchainIdentity: toolchainIdentity,
      steps: steps.map((step) => step.toBaselineEvidence()).toList(),
    );
  }

  /// Compares this verifier result with sanitized persisted [baseline].
  ///
  /// Existing baseline-red diagnostics may disappear, but new digest entries,
  /// parser mismatches, incomplete output, and invalid stored evidence are
  /// rejected fail-closed.
  VerificationComparison compareToBaselineEvidence(
    VerificationBaselineEvidence baseline,
  ) {
    final infrastructureFailures = <String>[];
    final newFailures = <String>[];
    if (!isComplete) {
      infrastructureFailures.add('candidate verification steps are incomplete');
    }
    if (!baseline.isComplete) {
      infrastructureFailures.add('stored verification evidence is incomplete');
    }
    if (policyHash != baseline.policyHash ||
        !_sameOrderedStrings(requiredStepIds, baseline.requiredStepIds)) {
      infrastructureFailures.add('verification policy does not match baseline');
    }
    if (!_sameParserKindLists(
      _effectiveParserKinds,
      baseline.requiredParserKinds,
    )) {
      infrastructureFailures.add(
        'verification output parser contract does not match baseline',
      );
    }
    if (workingDirectory != baseline.workingDirectory) {
      infrastructureFailures.add(
        'verification working directory does not match baseline',
      );
    }
    if (toolchainIdentity != baseline.toolchainIdentity) {
      infrastructureFailures.add(
        'verification toolchain does not match baseline',
      );
    }

    final baselineByName = {for (final step in baseline.steps) step.name: step};
    for (final candidate in steps) {
      final previous = baselineByName[candidate.name];
      if (candidate.exitCode < 0) {
        infrastructureFailures.add(
          '${candidate.name}: ${candidate.stderr.trim()}',
        );
        continue;
      }
      if (previous == null) {
        infrastructureFailures.add(
          '${candidate.name}: missing stored baseline step',
        );
        continue;
      }
      if (candidate.parserKind != previous.parserKind) {
        infrastructureFailures.add(
          '${candidate.name}: parser kind does not match stored baseline',
        );
        continue;
      }
      if (previous.passed) {
        if (!candidate.passed) {
          if (!candidate._hasStableFailureEvidence) {
            infrastructureFailures.add(
              '${candidate.name}: nonzero exit without stable diagnostic evidence',
            );
          } else {
            newFailures.add(
              '${candidate.name}: command changed from pass to fail',
            );
          }
        }
        continue;
      }
      if (!candidate.passed && !candidate._hasStableFailureEvidence) {
        infrastructureFailures.add(
          '${candidate.name}: nonzero exit without stable diagnostic evidence',
        );
        continue;
      }
      if (candidate.passed) continue;

      final candidateFailures = candidate._failureFingerprintDigestCounts;
      for (final failure in candidateFailures.entries) {
        final count =
            failure.value - (previous.fingerprintDigests[failure.key] ?? 0);
        for (var index = 0; index < count; index++) {
          newFailures.add('${candidate.name}: fingerprint $failure');
        }
      }
    }

    final accepted = infrastructureFailures.isEmpty && newFailures.isEmpty;
    return VerificationComparison._(
      candidate: this,
      newFailures: newFailures,
      infrastructureFailures: infrastructureFailures,
      acceptedEvidence: accepted
          ? AcceptedVerificationEvidence._(
              comparisonBaselineSha256: verificationBaselineEvidenceSha256(
                baseline,
              ),
              candidateEvidence: toBaselineEvidence(),
            )
          : null,
    );
  }

  /// Finds failures introduced relative to an accumulated [baseline].
  VerificationComparison compareTo(VerificationResult baseline) {
    final infrastructureFailures = <String>[];
    final newFailures = <String>[];
    if (!isComplete) {
      infrastructureFailures.add('candidate verification steps are incomplete');
    }
    if (!baseline.isComplete) {
      infrastructureFailures.add('baseline verification steps are incomplete');
    }
    if (policyHash != baseline.policyHash ||
        requiredStepIds
            .toSet()
            .difference(baseline.requiredStepIds.toSet())
            .isNotEmpty ||
        baseline.requiredStepIds
            .toSet()
            .difference(requiredStepIds.toSet())
            .isNotEmpty) {
      infrastructureFailures.add('verification policy does not match baseline');
    }
    if (!_sameParserKinds(baseline)) {
      infrastructureFailures.add(
        'verification output parser contract does not match baseline',
      );
    }
    if (workingDirectory != baseline.workingDirectory) {
      infrastructureFailures.add(
        'verification working directory does not match baseline',
      );
    }
    if (toolchainIdentity != baseline.toolchainIdentity) {
      infrastructureFailures.add(
        'verification toolchain does not match baseline',
      );
    }
    final baselineByName = {for (final step in baseline.steps) step.name: step};

    for (final candidate in steps) {
      if (candidate.exitCode < 0) {
        infrastructureFailures.add(
          '${candidate.name}: ${candidate.stderr.trim()}',
        );
        continue;
      }

      final previous = baselineByName[candidate.name];
      if (!candidate.passed && !candidate._hasStableFailureEvidence) {
        infrastructureFailures.add(
          '${candidate.name}: nonzero exit without stable diagnostic evidence',
        );
        continue;
      }
      if (!candidate.passed &&
          previous != null &&
          !previous.passed &&
          !previous._hasStableFailureEvidence) {
        infrastructureFailures.add(
          '${candidate.name}: baseline failure lacks stable diagnostic evidence',
        );
        continue;
      }
      final previousFailures =
          previous?._failureFingerprintCounts ?? const <String, int>{};
      final candidateFailures = candidate._failureFingerprintCounts;
      var introducedCount = 0;
      for (final failure in candidateFailures.entries) {
        final count = failure.value - (previousFailures[failure.key] ?? 0);
        for (var index = 0; index < count; index++) {
          newFailures.add('${candidate.name}: ${failure.key}');
          introducedCount++;
        }
      }

      if (!candidate.passed &&
          (previous == null || previous.passed) &&
          introducedCount == 0) {
        newFailures.add('${candidate.name}: command changed from pass to fail');
      }
    }

    return VerificationComparison._(
      candidate: this,
      newFailures: newFailures,
      infrastructureFailures: infrastructureFailures,
    );
  }

  bool _sameParserKinds(VerificationResult baseline) {
    return _sameParserKindLists(
      _effectiveParserKinds,
      baseline._effectiveParserKinds,
    );
  }

  List<VerificationOutputParserKind> get _effectiveParserKinds =>
      requiredParserKinds.isEmpty
      ? List.unmodifiable(steps.map((step) => step.parserKind))
      : requiredParserKinds;
}

bool _sameOrderedStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameParserKindLists(
  List<VerificationOutputParserKind> left,
  List<VerificationOutputParserKind> right,
) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Delta between a candidate verification and its accumulated baseline.
class VerificationComparison {
  const VerificationComparison._({
    required this.candidate,
    required this.newFailures,
    required this.infrastructureFailures,
    this.acceptedEvidence,
  });

  /// Verification output after applying the current case.
  final VerificationResult candidate;

  /// Diagnostics or test failures not present in the baseline.
  final List<String> newFailures;

  /// Process failures that make verification unavailable.
  final List<String> infrastructureFailures;

  /// Sanitized authority for an accepted stored-baseline comparison.
  final AcceptedVerificationEvidence? acceptedEvidence;

  /// Whether the candidate can safely become the next baseline.
  bool get accepted => infrastructureFailures.isEmpty && newFailures.isEmpty;

  /// Whether verification itself failed to execute reliably.
  bool get unavailable => infrastructureFailures.isNotEmpty;
}

/// Sanitized authority produced only by an accepted stored-baseline
/// comparison.
final class AcceptedVerificationEvidence {
  AcceptedVerificationEvidence._({
    required this.comparisonBaselineSha256,
    required this.candidateEvidence,
  });

  /// Canonical digest of the exact rolling baseline used for comparison.
  final String comparisonBaselineSha256;

  /// Complete sanitized evidence for the accepted candidate.
  final VerificationBaselineEvidence candidateEvidence;
}

/// Returns the canonical SHA-256 digest of sanitized verification evidence.
String verificationBaselineEvidenceSha256(
  VerificationBaselineEvidence evidence,
) => sha256.convert(utf8.encode(jsonEncode(evidence.toJson()))).toString();

/// Whether sanitized [candidate] evidence is an accepted continuation of
/// sanitized [baseline] evidence.
///
/// This replays the persisted subset of [VerificationResult]
/// comparison semantics without reconstructing raw verifier output.
bool verificationBaselineEvidenceAcceptsCandidate({
  required VerificationBaselineEvidence baseline,
  required VerificationBaselineEvidence candidate,
}) {
  if (!baseline.isComplete || !candidate.isComplete) return false;
  if (candidate.policyHash != baseline.policyHash ||
      !_sameOrderedStrings(
        candidate.requiredStepIds,
        baseline.requiredStepIds,
      ) ||
      !_sameParserKindLists(
        candidate.requiredParserKinds,
        baseline.requiredParserKinds,
      ) ||
      candidate.workingDirectory != baseline.workingDirectory ||
      candidate.toolchainIdentity != baseline.toolchainIdentity) {
    return false;
  }

  final baselineByName = {for (final step in baseline.steps) step.name: step};
  for (final candidateStep in candidate.steps) {
    final baselineStep = baselineByName[candidateStep.name];
    if (baselineStep == null ||
        candidateStep.parserKind != baselineStep.parserKind) {
      return false;
    }
    if (baselineStep.passed) {
      if (!candidateStep.passed) return false;
      continue;
    }
    if (candidateStep.passed) continue;
    for (final failure in candidateStep.fingerprintDigests.entries) {
      if (failure.value > (baselineStep.fingerprintDigests[failure.key] ?? 0)) {
        return false;
      }
    }
  }
  return true;
}

/// Sanitized, immutable verification baseline suitable for a quarantine
/// manifest. It intentionally retains no verifier stdout or stderr.
class VerificationBaselineEvidence {
  /// Creates validated, immutable baseline evidence.
  VerificationBaselineEvidence({
    required this.policyHash,
    required List<String> requiredStepIds,
    required List<VerificationOutputParserKind> requiredParserKinds,
    required this.workingDirectory,
    required this.toolchainIdentity,
    required List<VerificationStepBaselineEvidence> steps,
  }) : requiredStepIds = List.unmodifiable(requiredStepIds),
       requiredParserKinds = List.unmodifiable(requiredParserKinds),
       steps = List.unmodifiable(steps);

  /// Restores evidence from [toJson] output.
  factory VerificationBaselineEvidence.fromJson(Map<String, Object?> json) {
    return VerificationBaselineEvidence(
      policyHash: _jsonString(json, 'policyHash'),
      requiredStepIds: _jsonStringList(json, 'requiredStepIds'),
      requiredParserKinds: _jsonStringList(
        json,
        'requiredParserKinds',
      ).map(VerificationOutputParserKind.values.byName).toList(),
      workingDirectory: _jsonString(json, 'workingDirectory'),
      toolchainIdentity: _jsonString(json, 'toolchainIdentity'),
      steps: _jsonObjectList(
        json,
        'steps',
      ).map(VerificationStepBaselineEvidence.fromJson).toList(),
    );
  }

  /// Command policy identity captured with the baseline.
  final String policyHash;

  /// Stable verifier step IDs, in policy order.
  final List<String> requiredStepIds;

  /// Parser contracts for [requiredStepIds], in the same order.
  final List<VerificationOutputParserKind> requiredParserKinds;

  /// Normalized verifier working directory.
  final String workingDirectory;

  /// Toolchain version-probe hash.
  final String toolchainIdentity;

  /// Sanitized evidence for each required verifier step.
  final List<VerificationStepBaselineEvidence> steps;

  /// Whether the persisted evidence is internally complete and safe to use.
  bool get isComplete {
    if (requiredStepIds.isEmpty ||
        steps.length != requiredStepIds.length ||
        requiredParserKinds.length != requiredStepIds.length ||
        requiredStepIds.toSet().length != requiredStepIds.length) {
      return false;
    }
    final stepsByName = {for (final step in steps) step.name: step};
    if (stepsByName.length != steps.length) return false;
    for (var index = 0; index < requiredStepIds.length; index++) {
      final step = stepsByName[requiredStepIds[index]];
      if (step == null ||
          step.parserKind != requiredParserKinds[index] ||
          !step.isComplete) {
        return false;
      }
    }
    return true;
  }

  /// JSON-safe representation containing only metadata and digests.
  Map<String, Object?> toJson() => Map.unmodifiable({
    'policyHash': policyHash,
    'requiredStepIds': requiredStepIds,
    'requiredParserKinds': requiredParserKinds
        .map((kind) => kind.name)
        .toList(),
    'workingDirectory': workingDirectory,
    'toolchainIdentity': toolchainIdentity,
    'steps': steps.map((step) => step.toJson()).toList(),
  });
}

/// One sanitized verifier step in [VerificationBaselineEvidence].
class VerificationStepBaselineEvidence {
  /// Creates immutable verifier-step evidence.
  VerificationStepBaselineEvidence({
    required this.name,
    required this.parserKind,
    required this.passed,
    required this.exitCode,
    required this.failureEvidenceComplete,
    required this.reportedFailureCount,
    required this.fingerprintCount,
    required Map<String, int> fingerprintDigests,
  }) : fingerprintDigests = Map.unmodifiable(
         Map.fromEntries(
           fingerprintDigests.entries.toList()
             ..sort((left, right) => left.key.compareTo(right.key)),
         ),
       );

  /// Restores a sanitized step from [toJson] output.
  factory VerificationStepBaselineEvidence.fromJson(Map<String, Object?> json) {
    final reportedFailureCount = json['reportedFailureCount'];
    if (reportedFailureCount != null && reportedFailureCount is! int) {
      throw FormatException('reportedFailureCount must be an int or null');
    }
    return VerificationStepBaselineEvidence(
      name: _jsonString(json, 'name'),
      parserKind: VerificationOutputParserKind.values.byName(
        _jsonString(json, 'parserKind'),
      ),
      passed: _jsonBool(json, 'passed'),
      exitCode: _jsonInt(json, 'exitCode'),
      failureEvidenceComplete: _jsonBool(json, 'failureEvidenceComplete'),
      reportedFailureCount: reportedFailureCount as int?,
      fingerprintCount: _jsonInt(json, 'fingerprintCount'),
      fingerprintDigests: _jsonIntMap(json, 'fingerprintDigests'),
    );
  }

  /// Stable step ID.
  final String name;

  /// Parser contract used for this step.
  final VerificationOutputParserKind parserKind;

  /// Whether the process succeeded.
  final bool passed;

  /// Completed process exit code; a negative code is unavailable.
  final int exitCode;

  /// Whether a nonzero exit had parser-bound terminal evidence.
  final bool failureEvidenceComplete;

  /// Human analyzer's terminal issue count, when applicable.
  final int? reportedFailureCount;

  /// Total normalized fingerprint occurrences before hashing.
  final int fingerprintCount;

  /// SHA-256 digest to occurrence count; never contains raw output.
  final Map<String, int> fingerprintDigests;

  /// Whether this step's persisted evidence can safely establish a baseline.
  bool get isComplete {
    final digestCount = fingerprintDigests.values.fold(
      0,
      (sum, count) => sum + count,
    );
    if (fingerprintCount < 0 || digestCount != fingerprintCount) return false;
    if (fingerprintDigests.entries.any(
      (entry) =>
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.key) || entry.value <= 0,
    )) {
      return false;
    }
    if (passed) {
      return exitCode == 0 &&
          !failureEvidenceComplete &&
          reportedFailureCount == null &&
          fingerprintCount == 0;
    }
    if (exitCode < 0 ||
        parserKind == VerificationOutputParserKind.opaque ||
        !failureEvidenceComplete ||
        fingerprintCount == 0) {
      return false;
    }
    return switch (parserKind) {
      VerificationOutputParserKind.humanAnalyzer =>
        reportedFailureCount == fingerprintCount,
      VerificationOutputParserKind.compactTest => reportedFailureCount == null,
      VerificationOutputParserKind.opaque => false,
    };
  }

  /// JSON-safe map for persistence.
  Map<String, Object?> toJson() => Map.unmodifiable({
    'name': name,
    'parserKind': parserKind.name,
    'passed': passed,
    'exitCode': exitCode,
    'failureEvidenceComplete': failureEvidenceComplete,
    'reportedFailureCount': reportedFailureCount,
    'fingerprintCount': fingerprintCount,
    'fingerprintDigests': fingerprintDigests,
  });
}

String _jsonString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String) return value;
  throw FormatException('$key must be a string');
}

bool _jsonBool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a bool');
}

int _jsonInt(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is int) return value;
  throw FormatException('$key must be an int');
}

List<String> _jsonStringList(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! List<Object?> || value.any((item) => item is! String)) {
    throw FormatException('$key must be a string list');
  }
  return List<String>.from(value);
}

List<Map<String, Object?>> _jsonObjectList(
  Map<String, Object?> json,
  String key,
) {
  final value = json[key];
  if (value is! List<Object?> ||
      value.any((item) => item is! Map<Object?, Object?>)) {
    throw FormatException('$key must be an object list');
  }
  return value
      .map((item) => Map<String, Object?>.from(item as Map<Object?, Object?>))
      .toList();
}

Map<String, int> _jsonIntMap(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! Map<Object?, Object?> ||
      value.entries.any(
        (entry) => entry.key is! String || entry.value is! int,
      )) {
    throw FormatException('$key must be a string-to-int map');
  }
  return Map<String, int>.from(value);
}

/// A single verification step result.
class VerificationStep {
  /// Creates a verification step.
  const VerificationStep({
    required this.name,
    this.parserKind = VerificationOutputParserKind.opaque,
    required this.passed,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.duration,
  });

  /// Step name (e.g., 'flutter analyze').
  final String name;

  /// Output parser authorized by the command's argv shape.
  final VerificationOutputParserKind parserKind;

  /// Whether the step passed.
  final bool passed;

  /// Process exit code.
  final int exitCode;

  /// Standard output.
  final String stdout;

  /// Standard error.
  final String stderr;

  /// How long the step took.
  final Duration duration;

  Map<String, int> get _failureFingerprintCounts {
    final fingerprints = <String, int>{};

    void addFingerprint(String fingerprint) {
      fingerprints.update(fingerprint, (count) => count + 1, ifAbsent: () => 1);
    }

    final lines = '$stdout\n$stderr'.split('\n');
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final analyzerParts = line.split(' • ');
      if (analyzerParts.length >= 4) {
        final location = analyzerParts[2].replaceFirst(
          RegExp(r':\d+:\d+$'),
          '',
        );
        addFingerprint(
          '${analyzerParts.first}|$location|${analyzerParts.last}|'
          '${analyzerParts.sublist(1, analyzerParts.length - 2).join(' • ')}',
        );
        continue;
      }

      final machineParts = line.split('|');
      if (machineParts.length >= 8 &&
          const {'ERROR', 'WARNING', 'INFO'}.contains(machineParts.first)) {
        addFingerprint(
          '${machineParts[0]}|${machineParts[3]}|${machineParts[2]}|'
          '${machineParts.sublist(7).join('|')}',
        );
        continue;
      }

      final compilerMatch = RegExp(
        r'^(.+?):\d+:\d+:\s*(Error|Warning):\s*(.+)$',
      ).firstMatch(line);
      if (compilerMatch != null) {
        addFingerprint(
          '${compilerMatch.group(2)}|${compilerMatch.group(1)}|'
          '${compilerMatch.group(3)}',
        );
        continue;
      }

      if (line.endsWith('[E]')) {
        final testFailure = line.replaceFirst(
          RegExp(r'^\d\d:\d\d\s+\+\d+(?:\s+-\d+)?:\s*'),
          '',
        );
        addFingerprint(testFailure);
      }
    }
    return fingerprints;
  }

  Map<String, int> get _failureFingerprintDigestCounts {
    final digests = <String, int>{};
    for (final fingerprint in _failureFingerprintCounts.entries) {
      final digest = sha256.convert(utf8.encode(fingerprint.key)).toString();
      digests[digest] = fingerprint.value;
    }
    return digests;
  }

  /// Sanitizes this step for persistence in a rollback baseline.
  VerificationStepBaselineEvidence toBaselineEvidence() {
    final fingerprints = passed
        ? const <String, int>{}
        : _failureFingerprintDigestCounts;
    return VerificationStepBaselineEvidence(
      name: name,
      parserKind: parserKind,
      passed: passed,
      exitCode: exitCode,
      failureEvidenceComplete: !passed && _hasStableFailureEvidence,
      reportedFailureCount: passed ? null : _reportedFailureCount,
      fingerprintCount: fingerprints.values.fold(
        0,
        (sum, count) => sum + count,
      ),
      fingerprintDigests: fingerprints,
    );
  }

  int? get _reportedFailureCount {
    if (parserKind != VerificationOutputParserKind.humanAnalyzer) return null;
    final summaryPattern = RegExp(
      r'^(\d+) issues? found\.(?: \(ran in .+\))?$',
    );
    for (final rawLine in '$stdout\n$stderr'.split('\n')) {
      final match = summaryPattern.firstMatch(rawLine.trim());
      if (match != null) return int.tryParse(match.group(1) ?? '');
    }
    return null;
  }

  /// A failing exit is comparable only when recognized failure records and
  /// their human-output completion marker are both present. A process can
  /// print a diagnostic and then crash before it finishes analyzing or
  /// testing, so diagnostic fingerprints alone are not sufficient evidence.
  bool get _hasStableFailureEvidence {
    if (parserKind == VerificationOutputParserKind.opaque) return false;
    final lines = '$stdout\n$stderr'
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList(growable: false);
    switch (parserKind) {
      case VerificationOutputParserKind.humanAnalyzer:
        final humanAnalyzerDiagnostics = lines.where(
          (line) => line.split(' • ').length >= 4,
        );
        final summaryCount = _reportedFailureCount;
        if (humanAnalyzerDiagnostics.isEmpty || summaryCount == null) {
          return false;
        }
        return summaryCount ==
            _failureFingerprintCounts.values.fold(
              0,
              (sum, count) => sum + count,
            );
      case VerificationOutputParserKind.compactTest:
        return lines.any((line) => line.endsWith('[E]')) &&
            lines.contains('Some tests failed.');
      case VerificationOutputParserKind.opaque:
        return false;
    }
  }
}
