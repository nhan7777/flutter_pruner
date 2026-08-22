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
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  });
}

/// Default process executor used by mutating and verification workflows.
class ManagedProcessRunner implements ProcessExecutionRunner {
  /// Creates a managed process runner.
  const ManagedProcessRunner();

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
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
    final environment = Map<String, String>.unmodifiable(
      Map<String, String>.of(environmentOverrides),
    );

    final process = await Process.start(
      executable,
      List<String>.unmodifiable(arguments),
      workingDirectory: workingDirectory,
      environment: environment,
      includeParentEnvironment: includeParentEnvironment,
      mode: ProcessStartMode.normal,
    );
    final exitCode = process.exitCode;
    final stdoutOutput = _collectBounded(
      process.stdout,
      maxOutputBytesPerStream,
    );
    final stderrOutput = _collectBounded(
      process.stderr,
      maxOutputBytesPerStream,
    );
    final observer = _ProcessTreeObserver(process.pid)..start();

    try {
      final completed = await Future.wait<Object>([
        exitCode,
        stdoutOutput,
        stderrOutput,
      ]).timeout(timeout);
      await observer.stop();
      return ManagedProcessResult(
        exitCode: completed[0] as int,
        stdout: completed[1] as BoundedProcessOutput,
        stderr: completed[2] as BoundedProcessOutput,
        resourceObservation: observer.resourceObservation,
      );
    } on TimeoutException {
      final observationReliable = await observer.stop();
      final terminated = await _terminateProcessTree(
        process,
        exitCode,
        observedProcesses: observer.observedProcesses,
        observationReliable: observationReliable,
      );
      if (!terminated) {
        throw ProcessTerminationUnconfirmedException(
          processId: process.pid,
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
        return ManagedProcessResult(
          exitCode: -1,
          stdout: output[0],
          stderr: output[1],
          timedOut: true,
          resourceObservation: observer.resourceObservation,
        );
      } on TimeoutException {
        throw ProcessTerminationUnconfirmedException(
          processId: process.pid,
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
    }
  }
}

/// A completed process execution.
class ManagedProcessResult {
  /// Creates a process result.
  const ManagedProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this.timedOut = false,
    this.resourceObservation = ProcessTreeResourceObservation.unsupported,
  });

  /// Process exit code, or -1 for a confirmed timeout.
  final int exitCode;

  /// Bounded standard output.
  final BoundedProcessOutput stdout;

  /// Bounded standard error.
  final BoundedProcessOutput stderr;

  /// Whether the process hit the deadline and its observed tree was stopped.
  final bool timedOut;

  /// Best-effort process-tree resource evidence collected while running.
  final ProcessTreeResourceObservation resourceObservation;

  /// Whether either stream exceeded its configured capture limit.
  bool get outputTruncated => stdout.truncated || stderr.truncated;
}

/// Bounded output captured while the complete stream was drained.
class BoundedProcessOutput {
  /// Creates captured process output.
  BoundedProcessOutput({
    required List<int> capturedPayload,
    required this.omittedBytes,
  }) : _capturedPayload = Uint8List.fromList(capturedPayload);

  final Uint8List _capturedPayload;

  /// Exact payload prefix retained in memory.
  Uint8List get capturedPayload => Uint8List.fromList(_capturedPayload);

  /// Decoded captured prefix plus a truncation notice when applicable.
  String get text {
    final decoded = utf8.decode(_capturedPayload, allowMalformed: true);
    return omittedBytes == 0
        ? decoded
        : '$decoded\n...[output truncated; $omittedBytes bytes omitted]';
  }

  /// Number of payload bytes retained in memory.
  int get capturedBytes => _capturedPayload.length;

  /// Number of payload bytes drained but not retained.
  final int omittedBytes;

  /// Whether any output bytes were omitted.
  bool get truncated => omittedBytes > 0;
}

/// Reliability of process-tree resource sampling.
enum ProcessResourceObservationStatus {
  /// Process-tree samples were collected successfully.
  measured,

  /// Process-tree sampling is unavailable on this platform.
  unsupported,

  /// An inspection or sampling attempt failed.
  unreliable,
}

/// Best-effort resource evidence observed for a managed process tree.
final class ProcessTreeResourceObservation {
  /// Creates process-tree resource evidence.
  const ProcessTreeResourceObservation({
    required this.status,
    required this.sampleCount,
    this.sampledPeakRssBytes,
  });

  /// Evidence used when process-tree sampling is unavailable.
  static const unsupported = ProcessTreeResourceObservation(
    status: ProcessResourceObservationStatus.unsupported,
    sampleCount: 0,
  );

  /// Whether samples were measured, unsupported, or unreliable.
  final ProcessResourceObservationStatus status;

  /// Number of valid live-tree samples collected.
  final int sampleCount;

  /// Highest sampled sum of live tree RSS, in bytes.
  final int? sampledPeakRssBytes;
}

/// Signals that rollback is unsafe because a timed-out tree may still mutate.
class ProcessTerminationUnconfirmedException implements Exception {
  /// Creates an unconfirmed-termination error.
  const ProcessTerminationUnconfirmedException({
    required this.processId,
    required this.message,
  });

  /// Root process identifier.
  final int processId;

  /// Human-readable failure detail.
  final String message;

  @override
  String toString() => message;
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
  return BoundedProcessOutput(
    capturedPayload: captured.takeBytes(),
    omittedBytes: omittedBytes,
  );
}

class _ProcessTreeObserver {
  _ProcessTreeObserver(this.rootPid);

  final int rootPid;
  final Map<int, PosixProcessIdentity> _observedProcesses = {};
  var _inspectionReliable = true;
  var _capturedRootIdentity = false;
  var _stopping = false;
  var _sampleCount = 0;
  int? _sampledPeakRssBytes;
  Future<void>? _task;

  Map<int, PosixProcessIdentity> get observedProcesses =>
      Map.unmodifiable(_observedProcesses);

  ProcessTreeResourceObservation get resourceObservation {
    if (!Platform.isLinux && !Platform.isMacOS) {
      return ProcessTreeResourceObservation.unsupported;
    }
    return ProcessTreeResourceObservation(
      status: _inspectionReliable
          ? ProcessResourceObservationStatus.measured
          : ProcessResourceObservationStatus.unreliable,
      sampleCount: _sampleCount,
      sampledPeakRssBytes: _sampledPeakRssBytes,
    );
  }

  void start() {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    _task = _observe();
  }

  Future<bool> stop() async {
    _stopping = true;
    await _task;
    return _inspectionReliable;
  }

  Future<void> _observe() async {
    while (!_stopping) {
      try {
        final processTable = await _readPosixProcessTable();
        if (processTable == null) {
          _inspectionReliable = false;
        } else {
          final rootIdentity = processTable.identityFor(rootPid);
          if (rootIdentity != null) {
            final previousRoot = _observedProcesses[rootPid];
            if (previousRoot != null && previousRoot != rootIdentity) {
              _inspectionReliable = false;
            } else {
              _observedProcesses[rootPid] = rootIdentity;
              _capturedRootIdentity = true;
            }
          } else if (!_capturedRootIdentity) {
            // Missing the root before its identity was captured leaves a gap
            // in which descendants could have detached unobserved.
            _inspectionReliable = false;
          }

          _observedProcesses.removeWhere(
            (pid, identity) =>
                pid != rootPid && !processTable.containsIdentity(identity),
          );
          final liveRoots = processTable.matchingPids(
            _observedProcesses.values,
          );
          for (final pid in processTable.descendantsOf(liveRoots)) {
            final identity = processTable.identityFor(pid);
            if (identity != null) _observedProcesses[pid] = identity;
          }
          final liveTrackedProcesses = _observedProcesses.values.where(
            processTable.containsIdentity,
          );
          if (liveTrackedProcesses.isNotEmpty) {
            final rssBytes = processTable.sumRssBytes(liveTrackedProcesses);
            _sampleCount++;
            if (_sampledPeakRssBytes == null ||
                rssBytes > _sampledPeakRssBytes!) {
              _sampledPeakRssBytes = rssBytes;
            }
          }
        }
      } catch (_) {
        _inspectionReliable = false;
      }
      if (!_stopping) {
        await Future<void>.delayed(_processObservationInterval);
      }
    }
  }
}

Future<bool> _terminateProcessTree(
  Process process,
  Future<int> exitCode, {
  required Map<int, PosixProcessIdentity> observedProcesses,
  required bool observationReliable,
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
    );
  }
  process.kill();
  await _waitForProcessExit(exitCode);
  return false;
}

Future<bool> _terminateWindowsProcessTree(
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
  return result != null && result.exitCode == 0 && rootExited;
}

Future<bool> _terminatePosixProcessTree(
  Process process,
  Future<int> exitCode, {
  required Map<int, PosixProcessIdentity> observedProcesses,
  required bool observationReliable,
}) async {
  // Freeze every process observed while the command was running, then close
  // the descendant set before killing it. A process that deliberately
  // detached and was reparented before any snapshot remains outside this
  // observable tree and is part of the trusted-command boundary.
  final trackedProcesses = Map<int, PosixProcessIdentity>.from(
    observedProcesses,
  );
  var inspectionReliable = observationReliable;
  var treeFrozen = false;
  try {
    for (var pass = 0; pass < 6; pass++) {
      final processTable = await _readPosixProcessTable();
      if (processTable == null) {
        inspectionReliable = false;
        break;
      }

      final livePids = processTable.matchingPids(trackedProcesses.values);
      final discovered = processTable.descendantsOf(livePids)
        ..removeAll(livePids);
      for (final pid in discovered) {
        final identity = processTable.identityFor(pid);
        if (identity != null) trackedProcesses[pid] = identity;
      }

      final expandedLivePids = processTable.matchingPids(
        trackedProcesses.values,
      );
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

    final killedFrozenTree = await _killMatchingProcesses(
      trackedProcesses,
      rootPid: process.pid,
      requireStopped: true,
    );

    final rootExited = await _waitForProcessExit(exitCode);
    if (!rootExited) return false;
    final trackedExited = await _waitForProcessesToExit(
      trackedProcesses.values,
    );
    return inspectionReliable &&
        treeFrozen &&
        killedFrozenTree &&
        trackedExited;
  } catch (_) {
    await _killMatchingProcesses(
      trackedProcesses,
      rootPid: process.pid,
      requireStopped: false,
    );
    await _waitForProcessExit(exitCode);
    return false;
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
}) async {
  final processTable = await _readPosixProcessTable();
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

Future<bool> _waitForProcessesToExit(
  Iterable<PosixProcessIdentity> identities,
) async {
  final expected = identities.toList(growable: false);
  final stopwatch = Stopwatch()..start();
  while (stopwatch.elapsed < _processTerminationTimeout) {
    final processTable = await _readPosixProcessTable();
    if (processTable == null) return false;
    if (processTable.matchingPids(expected).isEmpty) return true;
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

Future<PosixProcessTableSnapshot?> _readPosixProcessTable() async {
  try {
    final result = await _runInspectionCommand('ps', const [
      '-axo',
      'pid=,ppid=,lstart=,state=,rss=',
    ]);
    if (result == null || result.exitCode != 0) return null;
    return PosixProcessTableSnapshot.parse(result.stdout);
  } catch (_) {
    return null;
  }
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

  /// Parses `ps -axo pid=,ppid=,lstart=,state=,rss=` output.
  factory PosixProcessTableSnapshot.parse(String output) {
    final processes = <int, _PosixProcessRecord>{};
    final childrenByParent = <int, Set<int>>{};
    for (final rawLine in output.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final match = RegExp(
        r'^(\d+)\s+(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)$',
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
        rssKiB: int.parse(match.group(9)!),
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

  /// Sums RSS for identities that are still live in this snapshot.
  int sumRssBytes(Iterable<PosixProcessIdentity> identities) {
    var rssKiB = 0;
    for (final pid in matchingPids(identities)) {
      rssKiB += _processes[pid]!.rssKiB;
    }
    return rssKiB * 1024;
  }

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
  const _PosixProcessRecord({
    required this.identity,
    required this.state,
    required this.rssKiB,
  });

  final PosixProcessIdentity identity;
  final String state;
  final int rssKiB;
}
