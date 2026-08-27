import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Executes an argv-only process with bounded output and confirmed timeout
/// termination.
abstract interface class ProcessExecutionRunner {
  /// Runs [executable] directly without a shell.
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  });
}

/// Starts one process without invoking a shell.
///
/// The injectable boundary lets process-lifecycle tests hold a launch between
/// the OS spawn and the runner observing the returned [Process].
typedef ManagedProcessStarter =
    Future<Process> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
    });

/// One-shot cancellation authority shared by every production managed runner.
///
/// A launch reservation is created synchronously before [Process.start] is
/// awaited. This keeps the CLI in coordinated-cancellation mode while a spawn
/// is pending and prevents a signal from orphaning a child whose handle has not
/// yet reached [ManagedProcessRunner].
final class ManagedProcessCancellationController {
  final Completer<ProcessSignal> _request = Completer<ProcessSignal>();
  final Set<_ManagedProcessLaunchReservation> _reservations =
      <_ManagedProcessLaunchReservation>{};

  /// Completes with the first requested signal and never resets.
  Future<ProcessSignal> get requested => _request.future;

  /// Whether coordinated cancellation has been requested.
  bool get isRequested => _request.isCompleted;

  /// Number of process launches pending or process trees still being observed.
  int get pendingOrActiveTreeCount => _reservations.length;

  /// Requests cancellation using the first triggering signal.
  ///
  /// Returns `true` only for the first request. Later signals are handled by
  /// the CLI coordinator's hard-stop path rather than replacing this signal.
  bool requestCancellation(ProcessSignal signal) {
    if (_request.isCompleted) return false;
    _recordSignal(signal);
    _request.complete(signal);
    return true;
  }

  _ManagedProcessLaunchReservation _reserveLaunch() {
    if (_request.isCompleted) {
      throw ProcessCancellationBeforeLaunchException(_requestedSignal);
    }
    final reservation = _ManagedProcessLaunchReservation._(this);
    _reservations.add(reservation);
    return reservation;
  }

  ProcessSignal get _requestedSignal {
    if (!_request.isCompleted) {
      throw StateError('Managed process cancellation was not requested.');
    }
    return _completedRequestSignal!;
  }

  ProcessSignal? _completedRequestSignal;

  void _recordSignal(ProcessSignal signal) {
    _completedRequestSignal ??= signal;
  }

  void _release(_ManagedProcessLaunchReservation reservation) {
    _reservations.remove(reservation);
  }
}

final class _ManagedProcessLaunchReservation {
  _ManagedProcessLaunchReservation._(this._controller);

  final ManagedProcessCancellationController _controller;
  int? rootPid;
  var _released = false;

  void bind(int pid) {
    if (_released) {
      throw StateError('Cannot bind a released process launch reservation.');
    }
    rootPid = pid;
  }

  void release() {
    if (_released) return;
    _released = true;
    _controller._release(this);
  }
}

/// Default process executor used by mutating and verification workflows.
class ManagedProcessRunner implements ProcessExecutionRunner {
  /// Creates a managed process runner.
  const ManagedProcessRunner({
    this.cancellationController,
    ManagedProcessStarter? processStarter,
    ManagedProcessTreeTerminator? processTreeTerminator,
    ProcessIdentityInspector processIdentityInspector =
        const ManagedProcessIdentityInspector(),
  }) : _processStarter = processStarter,
       _processTreeTerminator = processTreeTerminator,
       _processIdentityInspector = processIdentityInspector;

  /// Shared cancellation authority, or `null` for embedding/tests that do not
  /// participate in CLI signal coordination.
  final ManagedProcessCancellationController? cancellationController;

  final ManagedProcessStarter? _processStarter;
  final ManagedProcessTreeTerminator? _processTreeTerminator;
  final ProcessIdentityInspector _processIdentityInspector;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }
    if (maxOutputBytesPerStream < 0) {
      throw ArgumentError.value(
        maxOutputBytesPerStream,
        'maxOutputBytesPerStream',
        'must not be negative',
      );
    }

    final reservation = cancellationController?._reserveLaunch();
    late final Process process;
    try {
      final immutableArguments = List<String>.unmodifiable(arguments);
      process =
          await (_processStarter?.call(
                executable,
                immutableArguments,
                workingDirectory: workingDirectory,
              ) ??
              Process.start(
                executable,
                immutableArguments,
                workingDirectory: workingDirectory,
                mode: ProcessStartMode.normal,
              ));
    } catch (_) {
      reservation?.release();
      final controller = cancellationController;
      if (controller != null && controller.isRequested) {
        throw ProcessCancellationBeforeLaunchException(
          controller._requestedSignal,
        );
      }
      rethrow;
    }
    reservation?.bind(process.pid);
    final exitCode = process.exitCode;
    final stdoutOutput = _collectBounded(
      process.stdout,
      maxOutputBytesPerStream,
    );
    final stderrOutput = _collectBounded(
      process.stderr,
      maxOutputBytesPerStream,
    );
    final observer = _ProcessTreeObserver(
      process.pid,
      identityInspector: _processIdentityInspector,
    );

    try {
      // Bind the PID above before this first await, then capture its first
      // observable start identity before racing completion and cancellation.
      await observer.captureInitialIdentityAndStart();
      final completion = Future.wait<Object>([
        exitCode,
        stdoutOutput,
        stderrOutput,
      ]);
      final outcome = await Future.any<_ManagedProcessOutcome>([
        completion.then(_ManagedProcessOutcome.completed),
        Future<void>.delayed(
          timeout,
        ).then((_) => const _ManagedProcessOutcome.timedOut()),
        if (cancellationController case final controller?)
          controller.requested.then(_ManagedProcessOutcome.cancelled),
      ]);

      late final bool observationReliable;
      if (outcome.signal == null && !outcome.timedOut) {
        observationReliable = await observer.stop();
        final controller = cancellationController;
        if (controller == null || !controller.isRequested) {
          final completed = outcome.completed!;
          return ManagedProcessResult(
            exitCode: completed[0] as int,
            stdout: completed[1] as BoundedProcessOutput,
            stderr: completed[2] as BoundedProcessOutput,
          );
        }
      } else {
        observationReliable = await observer.stop();
      }

      final terminationEvidence =
          await (_processTreeTerminator?.call(
                process,
                exitCode,
                observedProcesses: observer.observedProcesses,
                observationReliable: observationReliable,
              ) ??
              _terminateProcessTree(
                process,
                exitCode,
                observedProcesses: observer.observedProcesses,
                observationReliable: observationReliable,
                identityInspector: _processIdentityInspector,
              ));
      final cancellationSignal =
          outcome.signal ??
          (cancellationController?.isRequested ?? false
              ? cancellationController!._requestedSignal
              : null);
      if (!terminationEvidence.terminationConfirmed) {
        throw ProcessTerminationUnconfirmedException(
          processId: process.pid,
          triggerSignal: cancellationSignal,
          observedProcesses: terminationEvidence.observedProcesses,
          observationReliable:
              terminationEvidence.observationReliable &&
              terminationEvidence.observedProcesses.containsKey(process.pid),
          message:
              'Could not confirm termination of the process tree rooted at '
              'PID ${process.pid}.',
        );
      }

      try {
        final output = await Future.wait<BoundedProcessOutput>([
          stdoutOutput,
          stderrOutput,
        ]).timeout(_processTerminationTimeout);
        if (cancellationSignal != null) {
          throw ProcessCancellationConfirmedException(
            cancellationSignal,
            process.pid,
          );
        }
        return ManagedProcessResult(
          exitCode: -1,
          stdout: output[0],
          stderr: output[1],
          timedOut: true,
        );
      } on TimeoutException {
        throw ProcessTerminationUnconfirmedException(
          processId: process.pid,
          triggerSignal: cancellationSignal,
          observedProcesses: terminationEvidence.observedProcesses,
          observationReliable:
              terminationEvidence.observationReliable &&
              terminationEvidence.observedProcesses.containsKey(process.pid),
          message:
              'PID ${process.pid} and its observed descendants stopped, but '
              'their output streams did not close after termination.',
        );
      }
    } catch (_) {
      // Future.wait completes a non-eager error only after the root and both
      // streams complete. Stop the observer before propagating that already
      // rollback-safe infrastructure failure.
      await observer.stop();
      rethrow;
    } finally {
      reservation?.release();
    }
  }
}

/// Test seam for deterministically exercising confirmed and unconfirmed tree
/// termination without weakening the production identity-checked terminator.
typedef ManagedProcessTreeTerminator =
    Future<ManagedProcessTerminationEvidence> Function(
      Process process,
      Future<int> exitCode, {
      required Map<int, PosixProcessIdentity> observedProcesses,
      required bool observationReliable,
    });

/// Immutable final process-tree evidence produced by a termination attempt.
///
/// [observedProcesses] is the terminator's final identity set, including any
/// descendants discovered after the continuous observer stopped. A reliable
/// set proves that inspection remained complete through a frozen descendant
/// closure; it does not by itself claim that every recorded process exited.
final class ManagedProcessTerminationEvidence {
  /// Creates final termination evidence and freezes its identity map.
  ManagedProcessTerminationEvidence({
    required this.terminationConfirmed,
    required Map<int, PosixProcessIdentity> observedProcesses,
    required this.observationReliable,
  }) : observedProcesses = Map<int, PosixProcessIdentity>.unmodifiable(
         observedProcesses,
       );

  /// Whether the complete identity-checked tree was confirmed absent.
  final bool terminationConfirmed;

  /// Final root and descendant identities at the termination boundary.
  final Map<int, PosixProcessIdentity> observedProcesses;

  /// Whether inspection proved a complete frozen descendant closure.
  final bool observationReliable;
}

final class _ManagedProcessOutcome {
  const _ManagedProcessOutcome.completed(this.completed)
    : timedOut = false,
      signal = null;

  const _ManagedProcessOutcome.timedOut()
    : completed = null,
      timedOut = true,
      signal = null;

  const _ManagedProcessOutcome.cancelled(this.signal)
    : completed = null,
      timedOut = false;

  final List<Object>? completed;
  final bool timedOut;
  final ProcessSignal? signal;
}

/// A completed process execution.
class ManagedProcessResult {
  /// Creates a process result.
  const ManagedProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
  });

  /// Process exit code, or -1 for a confirmed timeout.
  final int exitCode;

  /// Bounded standard output.
  final BoundedProcessOutput stdout;

  /// Bounded standard error.
  final BoundedProcessOutput stderr;

  /// Whether the process hit the deadline and its observed tree was stopped.
  final bool timedOut;

  /// Whether either stream exceeded its configured capture limit.
  bool get outputTruncated => stdout.truncated || stderr.truncated;
}

/// Bounded output captured while the complete stream was drained.
class BoundedProcessOutput {
  /// Creates captured process output.
  const BoundedProcessOutput({
    required this.text,
    required this.capturedBytes,
    required this.omittedBytes,
  });

  /// Decoded captured prefix plus a truncation notice when applicable.
  final String text;

  /// Number of payload bytes retained in memory.
  final int capturedBytes;

  /// Number of payload bytes drained but not retained.
  final int omittedBytes;

  /// Whether any output bytes were omitted.
  bool get truncated => omittedBytes > 0;
}

/// Signals that rollback is unsafe because a timed-out tree may still mutate.
class ProcessTerminationUnconfirmedException implements Exception {
  /// Creates an unconfirmed-termination error.
  const ProcessTerminationUnconfirmedException({
    required this.processId,
    required this.message,
    this.triggerSignal,
    this.observedProcesses = const <int, PosixProcessIdentity>{},
    this.observationReliable = false,
  });

  /// Root process identifier.
  final int processId;

  /// Human-readable failure detail.
  final String message;

  /// Signal that triggered termination, or `null` for a timeout.
  final ProcessSignal? triggerSignal;

  /// Exact start-time identities observed for the root and descendants.
  final Map<int, PosixProcessIdentity> observedProcesses;

  /// Whether observation covered the root and complete discovered tree.
  final bool observationReliable;

  @override
  String toString() => message;
}

/// Cancellation was already requested before a later process could launch.
final class ProcessCancellationBeforeLaunchException implements Exception {
  /// Creates a before-launch cancellation outcome.
  const ProcessCancellationBeforeLaunchException(this.originalSignal);

  /// First signal that requested coordinated cancellation.
  final ProcessSignal originalSignal;

  @override
  String toString() =>
      'Process launch cancelled before start by $originalSignal.';
}

/// The complete observed process tree was confirmed stopped after a signal.
final class ProcessCancellationConfirmedException implements Exception {
  /// Creates a confirmed cancellation outcome for [rootPid].
  const ProcessCancellationConfirmedException(
    this.originalSignal,
    this.rootPid,
  );

  /// First signal that requested coordinated cancellation.
  final ProcessSignal originalSignal;

  /// Non-null root PID whose observed tree was confirmed stopped.
  final int rootPid;

  @override
  String toString() =>
      'Process tree rooted at PID $rootPid was cancelled by $originalSignal.';
}

const _processTerminationTimeout = Duration(seconds: 5);
const _processInspectionTimeout = Duration(seconds: 2);
const _processObservationInterval = Duration(milliseconds: 100);
const _inspectionOutputLimit = 4 * 1024 * 1024;

Future<BoundedProcessOutput> _collectBounded(
  Stream<List<int>> stream,
  int limit,
) async {
  final captured = BytesBuilder(copy: false);
  var totalBytes = 0;
  await for (final chunk in stream) {
    totalBytes += chunk.length;
    final remaining = limit - captured.length;
    if (remaining <= 0) continue;
    if (chunk.length <= remaining) {
      captured.add(chunk);
    } else {
      captured.add(chunk.sublist(0, remaining));
    }
  }
  final capturedBytes = captured.length;
  final omittedBytes = totalBytes - capturedBytes;
  final decoded = utf8.decode(captured.takeBytes(), allowMalformed: true);
  final text = omittedBytes == 0
      ? decoded
      : '$decoded\n...[output truncated; $omittedBytes bytes omitted]';
  return BoundedProcessOutput(
    text: text,
    capturedBytes: capturedBytes,
    omittedBytes: omittedBytes,
  );
}

class _ProcessTreeObserver {
  _ProcessTreeObserver(
    this.rootPid, {
    ProcessIdentityInspector identityInspector =
        const ManagedProcessIdentityInspector(),
  }) : _identityInspector = identityInspector;

  final int rootPid;
  final ProcessIdentityInspector _identityInspector;
  final Map<int, PosixProcessIdentity> _observedProcesses = {};
  var _inspectionReliable = true;
  var _capturedRootIdentity = false;
  var _stopping = false;
  Future<void>? _task;

  Map<int, PosixProcessIdentity> get observedProcesses =>
      Map.unmodifiable(_observedProcesses);

  Future<void> captureInitialIdentityAndStart() async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    await _observeOnce();
    if (!_stopping) _task = _observe();
  }

  Future<bool> stop() async {
    _stopping = true;
    await _task;
    return _inspectionReliable;
  }

  Future<void> _observe() async {
    while (!_stopping) {
      await _observeOnce();
      if (!_stopping) {
        await Future<void>.delayed(_processObservationInterval);
      }
    }
  }

  Future<void> _observeOnce() async {
    try {
      final processTable = await _identityInspector.snapshot();
      if (processTable == null) {
        _inspectionReliable = false;
        return;
      }
      final rootIdentity = processTable.identityFor(rootPid);
      if (rootIdentity != null) {
        final previousRoot = _observedProcesses[rootPid];
        if (previousRoot == null) {
          _observedProcesses[rootPid] = rootIdentity;
          _capturedRootIdentity = true;
        } else if (previousRoot != rootIdentity) {
          // Do not replace the original lifetime with a reused root PID. The
          // missing interval could also have hidden a detached descendant.
          _inspectionReliable = false;
        }
      } else if (!_capturedRootIdentity) {
        // Missing the root before its identity was captured leaves a gap in
        // which descendants could have detached unobserved.
        _inspectionReliable = false;
      }

      for (final identity in _observedProcesses.values) {
        if (!processTable.containsIdentity(identity)) {
          // Historical identities are monotonic evidence. Disappearance
          // between snapshots is an observation gap: the process may have
          // forked and reparented a child before exiting.
          _inspectionReliable = false;
        }
      }
      final liveRoots = processTable.matchingPids(_observedProcesses.values);
      for (final pid in processTable.descendantsOf(liveRoots)) {
        final identity = processTable.identityFor(pid);
        if (identity == null) {
          _inspectionReliable = false;
          continue;
        }
        final previousIdentity = _observedProcesses[pid];
        if (previousIdentity == null) {
          _observedProcesses[pid] = identity;
        } else if (previousIdentity != identity) {
          // A reused descendant PID cannot replace its historical identity or
          // become a traversal root for the new, unrelated lifetime.
          _inspectionReliable = false;
        }
      }
    } catch (_) {
      _inspectionReliable = false;
    }
  }
}

Future<ManagedProcessTerminationEvidence> _terminateProcessTree(
  Process process,
  Future<int> exitCode, {
  required Map<int, PosixProcessIdentity> observedProcesses,
  required bool observationReliable,
  required ProcessIdentityInspector identityInspector,
}) async {
  if (Platform.isWindows) {
    return _terminateWindowsProcessTree(process, exitCode);
  }
  if (Platform.isLinux || Platform.isMacOS) {
    return _terminatePosixProcessTree(
      process,
      exitCode,
      observedProcesses: observedProcesses,
      observationReliable: observationReliable,
      identityInspector: identityInspector,
    );
  }
  process.kill();
  await _waitForProcessExit(exitCode);
  return ManagedProcessTerminationEvidence(
    terminationConfirmed: false,
    observedProcesses: observedProcesses,
    observationReliable: false,
  );
}

Future<ManagedProcessTerminationEvidence> _terminateWindowsProcessTree(
  Process process,
  Future<int> exitCode,
) async {
  final result = await _runInspectionCommand('taskkill', [
    '/PID',
    '${process.pid}',
    '/T',
    '/F',
  ]);
  final rootExited = await _waitForProcessExit(exitCode);
  return ManagedProcessTerminationEvidence(
    terminationConfirmed: result != null && result.exitCode == 0 && rootExited,
    observedProcesses: const <int, PosixProcessIdentity>{},
    observationReliable: false,
  );
}

Future<ManagedProcessTerminationEvidence> _terminatePosixProcessTree(
  Process process,
  Future<int> exitCode, {
  required Map<int, PosixProcessIdentity> observedProcesses,
  required bool observationReliable,
  required ProcessIdentityInspector identityInspector,
}) async {
  // Freeze every process observed while the command was running, then close
  // the descendant set before killing it. A process that deliberately
  // detached and was reparented before any snapshot remains outside this
  // observable tree and is part of the trusted-command boundary.
  final trackedProcesses = Map<int, PosixProcessIdentity>.from(
    observedProcesses,
  );
  var inspectionReliable =
      observationReliable && trackedProcesses.containsKey(process.pid);
  var treeFrozen = false;
  final provenStopped = <PosixProcessIdentity>{};
  try {
    for (var pass = 0; pass < 6; pass++) {
      final processTable = await identityInspector.snapshot();
      if (processTable == null) {
        inspectionReliable = false;
        break;
      }

      for (final identity in trackedProcesses.values) {
        if (!processTable.containsIdentity(identity) &&
            !provenStopped.contains(identity)) {
          // A previously observed process disappeared before a snapshot proved
          // it stopped. It could have forked and reparented a descendant in
          // that gap, so the retained identity set is not exact.
          inspectionReliable = false;
        }
      }
      final livePids = processTable.matchingPids(trackedProcesses.values);
      final discovered = processTable.descendantsOf(livePids)
        ..removeAll(livePids);
      for (final pid in discovered) {
        final identity = processTable.identityFor(pid);
        if (identity == null) {
          inspectionReliable = false;
        } else {
          trackedProcesses[pid] = identity;
        }
      }

      final expandedLivePids = processTable.matchingPids(
        trackedProcesses.values,
      );
      for (final pid in expandedLivePids) {
        final identity = trackedProcesses[pid];
        if (identity != null && processTable.isStopped(pid)) {
          provenStopped.add(identity);
        }
      }
      final allStopped = expandedLivePids.every(processTable.isStopped);
      if (discovered.isEmpty && allStopped) {
        treeFrozen = true;
        break;
      }
      for (final pid in expandedLivePids) {
        final identity = trackedProcesses[pid];
        if (identity != null) {
          _trySignalIdentity(identity, processTable, ProcessSignal.sigstop);
        }
      }
    }

    if (!treeFrozen) inspectionReliable = false;

    final killedFrozenTree = await _killMatchingProcesses(
      trackedProcesses,
      rootPid: process.pid,
      requireStopped: true,
      identityInspector: identityInspector,
    );
    if (!killedFrozenTree) inspectionReliable = false;

    final rootExited = await _waitForProcessExit(exitCode);
    final exitEvidence = await _waitForProcessesToExit(
      trackedProcesses.values,
      identityInspector: identityInspector,
    );
    final finalEvidenceReliable =
        inspectionReliable && exitEvidence.inspectionReliable;
    return ManagedProcessTerminationEvidence(
      terminationConfirmed:
          finalEvidenceReliable && rootExited && exitEvidence.allAbsent,
      observedProcesses: trackedProcesses,
      observationReliable: finalEvidenceReliable,
    );
  } catch (_) {
    await _killMatchingProcesses(
      trackedProcesses,
      rootPid: process.pid,
      requireStopped: false,
      identityInspector: identityInspector,
    );
    await _waitForProcessExit(exitCode);
    return ManagedProcessTerminationEvidence(
      terminationConfirmed: false,
      observedProcesses: trackedProcesses,
      observationReliable: false,
    );
  }
}

void _trySignalIdentity(
  PosixProcessIdentity identity,
  PosixProcessTableSnapshot processTable,
  ProcessSignal signal,
) {
  if (!processTable.containsIdentity(identity)) return;
  try {
    Process.killPid(identity.pid, signal);
  } catch (_) {
    // Exit confirmation below remains authoritative.
  }
}

Future<bool> _killMatchingProcesses(
  Map<int, PosixProcessIdentity> trackedProcesses, {
  required int rootPid,
  required bool requireStopped,
  required ProcessIdentityInspector identityInspector,
}) async {
  final processTable = await identityInspector.snapshot();
  if (processTable == null) return false;
  final livePids = processTable.matchingPids(trackedProcesses.values);
  final allStopped = livePids.every(processTable.isStopped);
  for (final pid in livePids.where((pid) => pid != rootPid)) {
    final identity = trackedProcesses[pid];
    if (identity != null) {
      _trySignalIdentity(identity, processTable, ProcessSignal.sigkill);
    }
  }
  final rootIdentity = trackedProcesses[rootPid];
  if (rootIdentity != null) {
    _trySignalIdentity(rootIdentity, processTable, ProcessSignal.sigkill);
  }
  return !requireStopped || allStopped;
}

Future<bool> _waitForProcessExit(Future<int> exitCode) async {
  try {
    await exitCode.timeout(_processTerminationTimeout);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<_ProcessExitEvidence> _waitForProcessesToExit(
  Iterable<PosixProcessIdentity> identities, {
  required ProcessIdentityInspector identityInspector,
}) async {
  final expected = identities.toList(growable: false);
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < _processTerminationTimeout) {
    final processTable = await identityInspector.snapshot();
    if (processTable == null) {
      return const _ProcessExitEvidence(
        allAbsent: false,
        inspectionReliable: false,
      );
    }
    final livePids = processTable.matchingPids(expected);
    if (livePids.isEmpty) {
      return const _ProcessExitEvidence(
        allAbsent: true,
        inspectionReliable: true,
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  final finalSnapshot = await identityInspector.snapshot();
  if (finalSnapshot == null) {
    return const _ProcessExitEvidence(
      allAbsent: false,
      inspectionReliable: false,
    );
  }
  final livePids = finalSnapshot.matchingPids(expected);
  return _ProcessExitEvidence(
    allAbsent: livePids.isEmpty,
    inspectionReliable: true,
  );
}

class _ProcessExitEvidence {
  const _ProcessExitEvidence({
    required this.allAbsent,
    required this.inspectionReliable,
  });

  final bool allAbsent;
  final bool inspectionReliable;
}

Future<PosixProcessTableSnapshot?> _readPosixProcessTable() async {
  try {
    final result = await _runInspectionCommand('ps', const [
      '-axo',
      'pid=,ppid=,lstart=,state=',
    ]);
    if (result == null || result.exitCode != 0) return null;
    return PosixProcessTableSnapshot.parse(result.stdout);
  } catch (_) {
    return null;
  }
}

/// Reads exact POSIX process start identities for PID-reuse-safe decisions.
abstract interface class ProcessIdentityInspector {
  /// Returns a complete current snapshot, or `null` when inspection is not
  /// trustworthy on this host or invocation.
  Future<PosixProcessTableSnapshot?> snapshot();
}

/// Production identity inspector shared by process termination and retained
/// project-operation authority.
final class ManagedProcessIdentityInspector
    implements ProcessIdentityInspector {
  /// Creates the system inspector.
  const ManagedProcessIdentityInspector();

  @override
  Future<PosixProcessTableSnapshot?> snapshot() => _readPosixProcessTable();
}

Future<_InspectionResult?> _runInspectionCommand(
  String executable,
  List<String> arguments,
) async {
  Process process;
  try {
    process = await Process.start(executable, arguments);
  } catch (_) {
    return null;
  }
  final stdoutOutput = _collectBounded(process.stdout, _inspectionOutputLimit);
  final stderrOutput = _collectBounded(process.stderr, _inspectionOutputLimit);
  try {
    final completed = await Future.wait<Object>([
      process.exitCode,
      stdoutOutput,
      stderrOutput,
    ]).timeout(_processInspectionTimeout);
    final stdout = completed[1] as BoundedProcessOutput;
    final stderr = completed[2] as BoundedProcessOutput;
    if (stdout.truncated || stderr.truncated) return null;
    return _InspectionResult(
      exitCode: completed[0] as int,
      stdout: stdout.text,
    );
  } catch (_) {
    if (Platform.isWindows) {
      process.kill();
    } else {
      process.kill(ProcessSignal.sigkill);
    }
    await _waitForProcessExit(process.exitCode);
    return null;
  }
}

class _InspectionResult {
  const _InspectionResult({required this.exitCode, required this.stdout});

  final int exitCode;
  final String stdout;
}

/// Start-time identity used to distinguish a live process from PID reuse.
class PosixProcessIdentity {
  /// Creates a POSIX process identity.
  const PosixProcessIdentity({
    required this.pid,
    required this.startFingerprint,
  });

  /// Numeric process identifier.
  final int pid;

  /// Stable `ps lstart` value for this lifetime of [pid].
  final String startFingerprint;

  @override
  bool operator ==(Object other) =>
      other is PosixProcessIdentity &&
      other.pid == pid &&
      other.startFingerprint == startFingerprint;

  @override
  int get hashCode => Object.hash(pid, startFingerprint);
}

/// Parsed POSIX process table with identity-aware matching.
///
/// This type lives under `src` and is public only so PID-reuse behavior can be
/// tested deterministically without signaling real unrelated processes.
class PosixProcessTableSnapshot {
  PosixProcessTableSnapshot._(this._processes, this._childrenByParent);

  /// Creates an exact empty snapshot for deterministic absence evidence.
  const PosixProcessTableSnapshot.empty()
    : _processes = const <int, _PosixProcessRecord>{},
      _childrenByParent = const <int, Set<int>>{};

  /// Parses `ps -axo pid=,ppid=,lstart=,state=` output.
  factory PosixProcessTableSnapshot.parse(String output) {
    final processes = <int, _PosixProcessRecord>{};
    final childrenByParent = <int, Set<int>>{};
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$',
      ).firstMatch(line);
      if (match == null) {
        throw FormatException('Unrecognized POSIX process table row.');
      }
      final pid = int.parse(match.group(1)!);
      final parentPid = int.parse(match.group(2)!);
      final identity = PosixProcessIdentity(
        pid: pid,
        startFingerprint: [
          for (var group = 3; group <= 7; group++) match.group(group)!,
        ].join(' '),
      );
      processes[pid] = _PosixProcessRecord(
        identity: identity,
        state: match.group(8)!,
      );
      childrenByParent.putIfAbsent(parentPid, () => <int>{}).add(pid);
    }
    if (processes.isEmpty) {
      throw FormatException('POSIX process table was empty.');
    }
    return PosixProcessTableSnapshot._(processes, childrenByParent);
  }

  final Map<int, _PosixProcessRecord> _processes;
  final Map<int, Set<int>> _childrenByParent;

  /// Returns the current identity for [pid], if present.
  PosixProcessIdentity? identityFor(int pid) => _processes[pid]?.identity;

  /// Whether [identity] still names the same process lifetime.
  bool containsIdentity(PosixProcessIdentity identity) =>
      _processes[identity.pid]?.identity == identity;

  /// Current PIDs whose start identities match [identities].
  Set<int> matchingPids(Iterable<PosixProcessIdentity> identities) => {
    for (final identity in identities)
      if (containsIdentity(identity)) identity.pid,
  };

  /// Whether [pid] is stopped according to its current POSIX state.
  bool isStopped(int pid) =>
      _processes[pid]?.state.toUpperCase().contains('T') ?? false;

  /// Returns descendants of [roots] in this snapshot.
  Set<int> descendantsOf(Set<int> roots) {
    final descendants = <int>{};

    void visit(int parentPid) {
      for (final childPid in _childrenByParent[parentPid] ?? const <int>{}) {
        if (descendants.add(childPid)) visit(childPid);
      }
    }

    for (final rootPid in roots) {
      visit(rootPid);
    }
    return descendants;
  }
}

class _PosixProcessRecord {
  const _PosixProcessRecord({required this.identity, required this.state});

  final PosixProcessIdentity identity;
  final String state;
}
