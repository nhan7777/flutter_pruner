import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../../core/process/managed_process_runner.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_stage_inventory.dart';
import 'l10n_stage_materializer.dart';
import 'l10n_toolchain.dart';

const _defaultTimeout = Duration(minutes: 2);
const _defaultMaxOutputBytesPerStream = 1024 * 1024;
const _unsafeWritableModeMask = 0x12;
final Stopwatch _productionClock = Stopwatch()..start();

/// The materialized root used by one generator invocation.
enum L10nGenerationPhase {
  /// Generate from the frozen, unedited inputs.
  baseline,

  /// Generate from the exact witnessed candidate ARB mutation.
  candidate,
}

/// Generates one l10n output family inside an owned stage root.
abstract interface class L10nGenerator {
  /// Runs one exact generation phase and returns redacted evidence.
  Future<L10nGenerationRun> generate({
    required L10nStageRoot stage,
    required L10nToolchainResolved toolchain,
    required L10nGenerationPhase phase,
    required Set<String> outputPaths,
  });
}

/// Immutable evidence retained for one generator invocation.
final class L10nGenerationRun {
  /// Creates one generation evidence value.
  L10nGenerationRun({
    required this.phase,
    required this.before,
    required this.after,
    required this.processResult,
    required List<L10nEvidenceFailure> failures,
    required this.elapsedMicros,
    required this.commandIdentity,
  }) : failures = List<L10nEvidenceFailure>.unmodifiable(
         List<L10nEvidenceFailure>.of(failures)..sort(_compareFailure),
       ) {
    if (elapsedMicros < 0) {
      throw ArgumentError.value(elapsedMicros, 'elapsedMicros');
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(commandIdentity)) {
      throw ArgumentError.value(commandIdentity, 'commandIdentity');
    }
  }

  /// Whether the baseline or candidate root was invoked.
  final L10nGenerationPhase phase;

  /// Stable inventory immediately before the launch capability was consumed.
  final L10nStageInventoryCapture before;

  /// Stable post-run inventory, or the unavailable sentinel when scanning is
  /// unsafe after unconfirmed process termination.
  final L10nStageInventoryCapture after;

  /// Bounded process evidence, when process termination was confirmed.
  final ManagedProcessResult? processResult;

  /// Stable fail-closed rejection identities.
  final List<L10nEvidenceFailure> failures;

  /// Monotonic elapsed duration in microseconds.
  final int elapsedMicros;

  /// SHA-256 identity of the exact bound command, policy, and stage authority.
  final String commandIdentity;

  /// Projects evidence without raw process output or filesystem paths.
  Map<String, Object?> toRedactedJson() => <String, Object?>{
    'phase': phase.name,
    'beforeFingerprint': before.fingerprint,
    'afterFingerprint': after.fingerprint,
    'process': _redactedProcess(processResult),
    'failures': <Object?>[
      for (final failure in failures)
        <String, Object?>{
          'code': failure.code.name,
          'stage': failure.stage,
          'detailCode': failure.detailCode,
          if (failure.relativePath != null)
            'relativePath': failure.relativePath,
        },
    ],
    'elapsedMicros': elapsedMicros,
    'commandIdentity': commandIdentity,
  };
}

/// Production generator backed only by a resolver-bound launch authority.
final class ProcessL10nGenerator implements L10nGenerator {
  /// Creates a generator with bounded process policy.
  const ProcessL10nGenerator({
    this.timeout = _defaultTimeout,
    this.maxOutputBytesPerStream = _defaultMaxOutputBytesPerStream,
  }) : _monotonicMicros = _readProductionMicros;

  /// Creates a generator with a deterministic monotonic clock for tests.
  ProcessL10nGenerator.testing({
    required int Function() monotonicMicros,
    this.timeout = _defaultTimeout,
    this.maxOutputBytesPerStream = _defaultMaxOutputBytesPerStream,
  }) : _monotonicMicros = monotonicMicros;

  /// Confirmed process-tree termination deadline.
  final Duration timeout;

  /// Maximum retained prefix per stdout/stderr stream.
  final int maxOutputBytesPerStream;

  final int Function() _monotonicMicros;

  @override
  Future<L10nGenerationRun> generate({
    required L10nStageRoot stage,
    required L10nToolchainResolved toolchain,
    required L10nGenerationPhase phase,
    required Set<String> outputPaths,
  }) async {
    _requireRole(stage, phase);
    final frozenOutputPaths = _freezeOutputPaths(stage, outputPaths);
    if (timeout <= Duration.zero || maxOutputBytesPerStream < 0) {
      throw ArgumentError('Generator process policy must be bounded.');
    }

    final startedMicros = _monotonicMicros();
    final stageName = '${phase.name}-generation';
    final commandIdentity = _commandIdentity(
      stage: stage,
      toolchain: toolchain,
      phase: phase,
      outputPaths: frozenOutputPaths,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
    );

    late final L10nStageInventoryCapture before;
    try {
      before = await L10nStageInventory.capture(
        stage.directory,
        captureBytesFor: frozenOutputPaths,
      );
    } catch (_) {
      stage.markUnsafeToDelete();
      final unavailable = L10nStageInventoryCapture.unavailable();
      return _finish(
        phase: phase,
        before: unavailable,
        after: unavailable,
        processResult: null,
        failures: [
          _failure(
            L10nEvidenceRejectionCode.unexpectedStageWrite,
            stageName,
            'pre-generation-inventory-invalid',
            relativePath: '.',
          ),
        ],
        startedMicros: startedMicros,
        commandIdentity: commandIdentity,
      );
    }

    if (before.invalidPaths.isNotEmpty) {
      stage.markUnsafeToDelete();
      return _finish(
        phase: phase,
        before: before,
        after: before,
        processResult: null,
        failures: [
          for (final path in before.invalidPaths)
            _failure(
              L10nEvidenceRejectionCode.unexpectedStageWrite,
              stageName,
              'pre-generation-inventory-invalid',
              relativePath: path,
            ),
        ],
        startedMicros: startedMicros,
        commandIdentity: commandIdentity,
      );
    }

    if (stage.toolchainIdentity != toolchain.identitySha256) {
      return _finish(
        phase: phase,
        before: before,
        after: before,
        processResult: null,
        failures: [
          _failure(
            L10nEvidenceRejectionCode.toolchainDrift,
            stageName,
            'stage-toolchain-identity-mismatch',
          ),
        ],
        startedMicros: startedMicros,
        commandIdentity: commandIdentity,
      );
    }

    late final L10nGenerationWorkingRoot workingRoot;
    try {
      workingRoot = stage.sealForGeneration();
    } on StateError catch (error) {
      final after = await _captureAfter(stage, frozenOutputPaths);
      return _finish(
        phase: phase,
        before: before,
        after: after,
        processResult: null,
        failures: [
          _failure(
            _phaseFailureCode(phase),
            stageName,
            _stageSealDetail(error),
          ),
        ],
        startedMicros: startedMicros,
        commandIdentity: commandIdentity,
      );
    } on L10nToolchainLaunchException catch (error) {
      final after = await _captureAfter(stage, frozenOutputPaths);
      return _finish(
        phase: phase,
        before: before,
        after: after,
        processResult: null,
        failures: [
          _failure(
            _launchFailureCode(error.detailCode, phase),
            stageName,
            error.detailCode,
          ),
        ],
        startedMicros: startedMicros,
        commandIdentity: commandIdentity,
      );
    }

    ManagedProcessResult? processResult;
    final failures = <L10nEvidenceFailure>[];
    try {
      processResult = await toolchain.launch.runGeneration(
        workingRoot: workingRoot,
        expected: toolchain,
        logicalArguments: toolchain.generationArgs,
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
      );
    } on L10nToolchainLaunchException catch (error) {
      if (error.detailCode == 'generation-run-termination-unconfirmed') {
        stage.markUnsafeToDelete();
        return _finish(
          phase: phase,
          before: before,
          after: L10nStageInventoryCapture.unavailable(),
          processResult: null,
          failures: [
            _failure(
              L10nEvidenceRejectionCode.generatorTerminationUnconfirmed,
              stageName,
              'generator-termination-unconfirmed',
            ),
          ],
          startedMicros: startedMicros,
          commandIdentity: commandIdentity,
        );
      }
      failures.add(
        _failure(
          _launchFailureCode(error.detailCode, phase),
          stageName,
          error.detailCode,
        ),
      );
    }

    final after = await _captureAfter(stage, frozenOutputPaths);
    if (after.invalidPaths.isNotEmpty) stage.markUnsafeToDelete();

    if (processResult case final result?) {
      if (result.timedOut) {
        failures.add(
          _failure(
            _phaseFailureCode(phase),
            stageName,
            'generation-process-timeout',
          ),
        );
      } else if (result.exitCode != 0) {
        failures.add(
          _failure(
            _phaseFailureCode(phase),
            stageName,
            'generation-process-nonzero-exit',
          ),
        );
      }
      if (result.outputTruncated) {
        failures.add(
          _failure(
            L10nEvidenceRejectionCode.generatorOutputTruncated,
            stageName,
            'generator-output-truncated',
          ),
        );
      }
    }

    failures.addAll(
      _unexpectedWrites(
        before: before,
        after: after,
        outputPaths: frozenOutputPaths,
        stageName: stageName,
      ),
    );
    return _finish(
      phase: phase,
      before: before,
      after: after,
      processResult: processResult,
      failures: failures,
      startedMicros: startedMicros,
      commandIdentity: commandIdentity,
    );
  }

  L10nGenerationRun _finish({
    required L10nGenerationPhase phase,
    required L10nStageInventoryCapture before,
    required L10nStageInventoryCapture after,
    required ManagedProcessResult? processResult,
    required List<L10nEvidenceFailure> failures,
    required int startedMicros,
    required String commandIdentity,
  }) {
    final finishedMicros = _monotonicMicros();
    return L10nGenerationRun(
      phase: phase,
      before: before,
      after: after,
      processResult: processResult,
      failures: failures,
      elapsedMicros: finishedMicros <= startedMicros
          ? 0
          : finishedMicros - startedMicros,
      commandIdentity: commandIdentity,
    );
  }
}

void _requireRole(L10nStageRoot stage, L10nGenerationPhase phase) {
  final expected = switch (phase) {
    L10nGenerationPhase.baseline => L10nStageRole.baseline,
    L10nGenerationPhase.candidate => L10nStageRole.candidate,
  };
  if (stage.role != expected) {
    throw ArgumentError.value(stage.role, 'stage', 'Stage role mismatch.');
  }
}

Set<String> _freezeOutputPaths(L10nStageRoot stage, Set<String> requested) {
  final frozen = SplayTreeSet<String>.of(requested);
  for (final path in frozen) {
    if (!_isPortableRelativePath(path)) {
      throw ArgumentError.value(path, 'outputPaths');
    }
  }
  final folded = <String, String>{};
  for (final path in frozen) {
    final previous = folded[_asciiFold(path)];
    if (previous != null && previous != path) {
      throw ArgumentError.value(path, 'outputPaths');
    }
    folded[_asciiFold(path)] = path;
  }
  if (!_sameStrings(frozen, stage.generationOutputPaths)) {
    throw ArgumentError.value(requested, 'outputPaths', 'Allowlist mismatch.');
  }
  return Set<String>.unmodifiable(frozen);
}

bool _isPortableRelativePath(String value) {
  if (value.isEmpty || value.startsWith('/') || value.endsWith('/')) {
    return false;
  }
  if (!RegExp(r'^[A-Za-z0-9._/-]+$').hasMatch(value)) return false;
  final parts = value.split('/');
  return parts.every((part) => part.isNotEmpty && part != '.' && part != '..');
}

String _asciiFold(String value) {
  final units = value.codeUnits;
  return String.fromCharCodes([
    for (final unit in units) unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
  ]);
}

bool _sameStrings(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

Future<L10nStageInventoryCapture> _captureAfter(
  L10nStageRoot stage,
  Set<String> outputPaths,
) async {
  if (!stage.safeToDelete) return L10nStageInventoryCapture.unavailable();
  try {
    return await L10nStageInventory.capture(
      stage.directory,
      captureBytesFor: outputPaths,
    );
  } catch (_) {
    stage.markUnsafeToDelete();
    return L10nStageInventoryCapture.unavailable();
  }
}

List<L10nEvidenceFailure> _unexpectedWrites({
  required L10nStageInventoryCapture before,
  required L10nStageInventoryCapture after,
  required Set<String> outputPaths,
  required String stageName,
}) {
  if (after.entries.isEmpty &&
      after.invalidPaths.length == 1 &&
      after.invalidPaths.single == '.') {
    return List<L10nEvidenceFailure>.unmodifiable([
      _failure(
        L10nEvidenceRejectionCode.unexpectedStageWrite,
        stageName,
        'unexpected-stage-write',
        relativePath: '.',
      ),
    ]);
  }
  final changed = SplayTreeSet<String>();
  final allPaths = SplayTreeSet<String>.of(before.entries.keys)
    ..addAll(after.entries.keys)
    ..addAll(after.invalidPaths);
  final structuralParents = <String>{
    for (final outputPath in outputPaths) ..._parentsOf(outputPath),
  };

  for (final path in allPaths) {
    final beforeEntry = before.entries[path];
    final afterEntry = after.entries[path];
    if (_sameEntry(beforeEntry, afterEntry) &&
        !after.invalidPaths.contains(path)) {
      continue;
    }
    if (!after.invalidPaths.contains(path) && outputPaths.contains(path)) {
      // Task 11 classifies required-output deletion and optional-sidecar
      // absence. Task 10 only accepts a present output when its inventory is
      // stable, regular, captured, and safe for the owned cleanup authority.
      if (afterEntry == null || _isSafeOutputEntry(afterEntry)) {
        continue;
      }
    }
    if (!after.invalidPaths.contains(path) &&
        structuralParents.contains(path) &&
        beforeEntry == null &&
        afterEntry?.kind == L10nStageEntryKind.directory) {
      continue;
    }
    changed.add(path);
  }

  return List<L10nEvidenceFailure>.unmodifiable([
    for (final path in changed)
      _failure(
        L10nEvidenceRejectionCode.unexpectedStageWrite,
        stageName,
        'unexpected-stage-write',
        relativePath: path,
      ),
  ]);
}

Iterable<String> _parentsOf(String path) sync* {
  final parts = path.split('/');
  for (var length = 1; length < parts.length; length++) {
    yield parts.take(length).join('/');
  }
}

bool _sameEntry(L10nStageEntry? left, L10nStageEntry? right) =>
    identical(left, right) ||
    (left != null &&
        right != null &&
        left.relativePath == right.relativePath &&
        left.kind == right.kind &&
        left.sha256 == right.sha256 &&
        left.posixMode == right.posixMode);

bool _isSafeOutputEntry(L10nStageEntry entry) =>
    entry.kind == L10nStageEntryKind.regularFile &&
    entry.sha256 != null &&
    entry.capturedBytes != null &&
    (Platform.isWindows ||
        (entry.posixMode != null &&
            entry.posixMode! & 0x100 != 0 &&
            entry.posixMode! & _unsafeWritableModeMask == 0));

int _compareFailure(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  var comparison = left.code.index.compareTo(right.code.index);
  if (comparison != 0) return comparison;
  comparison = left.stage.compareTo(right.stage);
  if (comparison != 0) return comparison;
  comparison = _compareNullableString(left.relativePath, right.relativePath);
  if (comparison != 0) return comparison;
  return left.detailCode.compareTo(right.detailCode);
}

int _compareNullableString(String? left, String? right) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return left.compareTo(right);
}

L10nEvidenceFailure _failure(
  L10nEvidenceRejectionCode code,
  String stage,
  String detailCode, {
  String? relativePath,
}) => L10nEvidenceFailure(
  code: code,
  stage: stage,
  detailCode: detailCode,
  relativePath: relativePath,
);

L10nEvidenceRejectionCode _phaseFailureCode(L10nGenerationPhase phase) =>
    switch (phase) {
      L10nGenerationPhase.baseline =>
        L10nEvidenceRejectionCode.baselineGenerationFailed,
      L10nGenerationPhase.candidate =>
        L10nEvidenceRejectionCode.candidateGenerationFailed,
    };

L10nEvidenceRejectionCode _launchFailureCode(
  String detailCode,
  L10nGenerationPhase phase,
) {
  if (detailCode == 'generation-toolchain-drift' ||
      detailCode == 'frozen-command-drift' ||
      detailCode == 'frozen-launch-drift' ||
      detailCode == 'generation-working-root-authority-drift') {
    return L10nEvidenceRejectionCode.toolchainDrift;
  }
  return _phaseFailureCode(phase);
}

String _stageSealDetail(StateError error) {
  final detail = error.message.toString();
  return switch (detail) {
    'stage-root-generation-capability-consumed' ||
    'stage-root-unsafe-for-generation' ||
    'candidate-arbs-not-installed' ||
    'stage-root-verification-failed' ||
    'testing-stage-root-has-no-generation-capability' => detail,
    _ => 'stage-root-generation-capability-unavailable',
  };
}

String _commandIdentity({
  required L10nStageRoot stage,
  required L10nToolchainResolved toolchain,
  required L10nGenerationPhase phase,
  required Set<String> outputPaths,
  required Duration timeout,
  required int maxOutputBytesPerStream,
}) {
  final fields = <String>[
    'flutter-pruner-l10n-command-v1',
    phase.name,
    stage.role.name,
    stage.identity,
    stage.toolchainIdentity,
    toolchain.identitySha256,
    toolchain.launch.canonicalDartExecutable,
    toolchain.launch.canonicalFlutterToolsPackageConfig,
    toolchain.launch.canonicalFlutterToolsSnapshot,
    toolchain.launch.canonicalOriginalProjectRoot ?? '',
    timeout.inMicroseconds.toString(),
    maxOutputBytesPerStream.toString(),
    ...toolchain.generationArgs,
    ...outputPaths,
    for (final entry in (SplayTreeMap<String, String>.of(
      toolchain.environmentOverrides,
    )).entries) ...[entry.key, entry.value],
  ];
  final sink = StringBuffer();
  for (final field in fields) {
    sink
      ..write(utf8.encode(field).length)
      ..write(':')
      ..write(field)
      ..write('\u0000');
  }
  return sha256.convert(utf8.encode(sink.toString())).toString();
}

Map<String, Object?>? _redactedProcess(ManagedProcessResult? result) {
  if (result == null) return null;
  Map<String, Object?> output(BoundedProcessOutput stream) => <String, Object?>{
    'sha256': sha256.convert(stream.capturedPayload).toString(),
    'capturedBytes': stream.capturedBytes,
    'omittedBytes': stream.omittedBytes,
    'truncated': stream.truncated,
  };

  final resource = result.resourceObservation;
  return <String, Object?>{
    'exitCode': result.exitCode,
    'timedOut': result.timedOut,
    'stdout': output(result.stdout),
    'stderr': output(result.stderr),
    'resourceObservation': <String, Object?>{
      'status': resource.status.name,
      'sampleCount': resource.sampleCount,
      'sampledPeakRssBytes': resource.sampledPeakRssBytes,
    },
  };
}

int _readProductionMicros() => _productionClock.elapsedMicroseconds;
