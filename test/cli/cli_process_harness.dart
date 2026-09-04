import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pruner/src/core/process/managed_process_runner.dart'
    show PosixProcessIdentity, PosixProcessTableSnapshot;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Reads a POSIX process table for the test-only tree lifecycle.
typedef PosixProcessTableReader = Future<PosixProcessTableSnapshot?> Function();

/// Sends one signal after the process identity has been revalidated.
typedef PosixIdentitySignalSender =
    void Function(PosixProcessIdentity identity, ProcessSignal signal);

/// States whether this host can safely track a fixture process tree.
typedef TrackedProcessTreeSupport = bool Function();

/// Observes bounded cleanup episodes in deterministic harness tests.
typedef CleanupAttemptObserver = void Function(int episode, int attempt);

/// Invoked only by a deterministic test that replaces the acknowledgement
/// pathname after its exclusive descriptor has been opened.
typedef AcknowledgementExclusiveOpenObserver = void Function(File file);

/// Observes the mode applied by exclusive open before fchmod defense-in-depth.
typedef AcknowledgementExclusiveOpenModeObserver = void Function(File file);

typedef _NativeOpen = Int32 Function(Pointer<Uint8>, Int32, VarArgs<(Int32,)>);

/// Test-only ownership protocol for one fixture child that may outlive its
/// parent. Both files must be absent before the root launches.
class TrackedChildRegistration {
  const TrackedChildRegistration({
    required this.pidFile,
    required this.acknowledgementFile,
    required this.token,
  });

  final File pidFile;
  final File acknowledgementFile;
  final String token;

  String get acknowledgementText => 'registered:$token\n';
}

/// Raised when fixture-process cleanup cannot be confirmed.
class CliProcessTerminationUnconfirmedException implements Exception {
  const CliProcessTerminationUnconfirmedException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Runs the public CLI as a real Dart process.
///
/// This intentionally lives under `test/`: callers must opt in to every
/// injected entrypoint, environment value, stream, and lifecycle barrier.
class CliProcessHarness {
  CliProcessHarness({
    required this.repositoryRoot,
    Duration defaultTimeout = const Duration(seconds: 45),
    PosixProcessTableReader? posixProcessTableReader,
    PosixIdentitySignalSender? posixIdentitySignalSender,
    TrackedProcessTreeSupport? trackedProcessTreeSupport,
    CleanupAttemptObserver? cleanupAttemptObserver,
    AcknowledgementExclusiveOpenObserver? acknowledgementExclusiveOpenObserver,
    AcknowledgementExclusiveOpenModeObserver?
    acknowledgementExclusiveOpenModeObserver,
  }) : _defaultTimeout = defaultTimeout,
       _posixProcessTableReader =
           posixProcessTableReader ?? _readPosixProcessTable,
       _posixIdentitySignalSender =
           posixIdentitySignalSender ?? _sendPosixIdentitySignal,
       _trackedProcessTreeSupport =
           trackedProcessTreeSupport ?? _hostSupportsTrackedProcessTrees,
       _cleanupAttemptObserver = cleanupAttemptObserver,
       _acknowledgementExclusiveOpenObserver =
           acknowledgementExclusiveOpenObserver,
       _acknowledgementExclusiveOpenModeObserver =
           acknowledgementExclusiveOpenModeObserver {
    if (defaultTimeout <= Duration.zero) {
      throw ArgumentError.value(defaultTimeout, 'defaultTimeout');
    }
    if (!File(
      p.join(repositoryRoot.path, 'bin', 'flutter_pruner.dart'),
    ).existsSync()) {
      throw ArgumentError.value(repositoryRoot, 'repositoryRoot');
    }
    if (!File(
      p.join(repositoryRoot.path, '.dart_tool', 'package_config.json'),
    ).existsSync()) {
      throw ArgumentError('Repository package configuration is required.');
    }
  }

  factory CliProcessHarness.repository({
    Directory? repositoryRoot,
    Duration defaultTimeout = const Duration(seconds: 45),
    PosixProcessTableReader? posixProcessTableReader,
    PosixIdentitySignalSender? posixIdentitySignalSender,
    TrackedProcessTreeSupport? trackedProcessTreeSupport,
    CleanupAttemptObserver? cleanupAttemptObserver,
    AcknowledgementExclusiveOpenObserver? acknowledgementExclusiveOpenObserver,
    AcknowledgementExclusiveOpenModeObserver?
    acknowledgementExclusiveOpenModeObserver,
  }) => CliProcessHarness(
    repositoryRoot: repositoryRoot ?? _findRepositoryRoot(Directory.current),
    defaultTimeout: defaultTimeout,
    posixProcessTableReader: posixProcessTableReader,
    posixIdentitySignalSender: posixIdentitySignalSender,
    trackedProcessTreeSupport: trackedProcessTreeSupport,
    cleanupAttemptObserver: cleanupAttemptObserver,
    acknowledgementExclusiveOpenObserver: acknowledgementExclusiveOpenObserver,
    acknowledgementExclusiveOpenModeObserver:
        acknowledgementExclusiveOpenModeObserver,
  );

  final Directory repositoryRoot;
  final Duration _defaultTimeout;
  final PosixProcessTableReader _posixProcessTableReader;
  final PosixIdentitySignalSender _posixIdentitySignalSender;
  final TrackedProcessTreeSupport _trackedProcessTreeSupport;
  final CleanupAttemptObserver? _cleanupAttemptObserver;
  final AcknowledgementExclusiveOpenObserver?
  _acknowledgementExclusiveOpenObserver;
  final AcknowledgementExclusiveOpenModeObserver?
  _acknowledgementExclusiveOpenModeObserver;
  final Set<_ActiveCliProcess> _launched = <_ActiveCliProcess>{};

  /// Dedicated test-only clean entrypoint; never used by the production bin.
  File get quarantineCleanFakeEntrypoint => File(
    p.join(
      repositoryRoot.path,
      'test',
      'cli',
      'quarantine_clean_fake_entrypoint.dart',
    ),
  );

  /// Test-only visibility for proving that unconfirmed cleanup remains
  /// retryable through [close].
  int get activeInvocationCount => _launched.length;

  /// Starts a process while retaining its lifecycle for explicit teardown.
  ///
  /// On POSIX hosts with identity-aware process inspection, process-tree
  /// tracking is automatic. Set [trackProcessTree] to `false` only in a test
  /// that intentionally characterizes root-only behavior. Hosts without that
  /// capability run ordinary commands without making a tree-cleanup claim.
  Future<CliProcessInvocation> start(
    List<String> argv, {
    Directory? workingDirectory,
    Map<String, String> environmentAdditions = const <String, String>{},
    Set<String> environmentRemovals = const <String>{},
    String? stdinText,
    List<int>? stdinBytes,
    File? readyFile,
    File? releaseFile,
    TrackedChildRegistration? trackedChildRegistration,
    File? entrypointOverride,
    Duration? timeout,
    Duration? timeoutAfterReady,
    bool? trackProcessTree,
  }) async {
    if (stdinText != null && stdinBytes != null) {
      throw ArgumentError('Provide stdinText or stdinBytes, not both.');
    }
    if (trackedChildRegistration != null) {
      _validateTrackedChildRegistration(trackedChildRegistration);
    }
    final treeTrackingSupported = _trackedProcessTreeSupport();
    final shouldTrackProcessTree = trackProcessTree ?? treeTrackingSupported;
    if (!shouldTrackProcessTree && trackedChildRegistration != null) {
      throw ArgumentError(
        'trackedChildRegistration requires trackProcessTree.',
      );
    }
    if (shouldTrackProcessTree && !treeTrackingSupported) {
      throw UnsupportedError(
        'Tracked fixture-process cleanup is supported only on POSIX hosts with identity-aware process inspection.',
      );
    }
    final boundedTimeout = timeout ?? _defaultTimeout;
    if (boundedTimeout <= Duration.zero) {
      throw ArgumentError.value(boundedTimeout, 'timeout');
    }
    if (timeoutAfterReady != null && timeoutAfterReady <= Duration.zero) {
      throw ArgumentError.value(timeoutAfterReady, 'timeoutAfterReady');
    }
    if (timeoutAfterReady != null && readyFile == null) {
      throw ArgumentError('timeoutAfterReady requires readyFile.');
    }
    final packageConfig = File(
      p.join(repositoryRoot.path, '.dart_tool', 'package_config.json'),
    );
    final entrypoint =
        entrypointOverride ??
        File(p.join(repositoryRoot.path, 'bin', 'flutter_pruner.dart'));
    if (!packageConfig.existsSync() || !entrypoint.existsSync()) {
      throw StateError('CLI package configuration or entrypoint is missing.');
    }

    final environment = Map<String, String>.from(Platform.environment)
      ..addAll(environmentAdditions);
    for (final name in environmentRemovals) {
      environment.remove(name);
    }
    final process = await Process.start(
      Platform.resolvedExecutable,
      <String>['--packages=${packageConfig.path}', entrypoint.path, ...argv],
      workingDirectory: (workingDirectory ?? repositoryRoot).path,
      environment: environment,
    );
    final active = _ActiveCliProcess(
      process: process,
      argv: argv,
      readyFile: readyFile,
      releaseFile: releaseFile,
      trackedChildRegistration: trackedChildRegistration,
      timeout: boundedTimeout,
      timeoutAfterReady: timeoutAfterReady,
      trackProcessTree: shouldTrackProcessTree,
      posixProcessTableReader: _posixProcessTableReader,
      posixIdentitySignalSender: _posixIdentitySignalSender,
      cleanupAttemptObserver: _cleanupAttemptObserver,
      acknowledgementExclusiveOpenObserver:
          _acknowledgementExclusiveOpenObserver,
      acknowledgementExclusiveOpenModeObserver:
          _acknowledgementExclusiveOpenModeObserver,
    );
    _launched.add(active);

    try {
      await active.initialize();
      final input =
          stdinBytes ?? (stdinText == null ? null : utf8.encode(stdinText));
      if (input != null) process.stdin.add(input);
      await process.stdin.close();
      active.beginCompletion();
      unawaited(
        active.completion.then<void>(
          (_) => _launched.remove(active),
          onError: (_, __) {
            if (active.cleanupConfirmed) _launched.remove(active);
          },
        ),
      );
    } catch (_) {
      try {
        await active.terminate();
        _launched.remove(active);
      } on CliProcessTerminationUnconfirmedException {
        // Keep this lifecycle entry so explicit harness teardown can retry.
      }
      rethrow;
    }
    return CliProcessInvocation._(active);
  }

  static void _validateTrackedChildRegistration(
    TrackedChildRegistration registration,
  ) {
    if (registration.token.isEmpty || registration.token.contains('\n')) {
      throw ArgumentError.value(registration.token, 'registration.token');
    }
    final pidPath = p.normalize(registration.pidFile.absolute.path);
    final ackPath = p.normalize(registration.acknowledgementFile.absolute.path);
    if (pidPath == ackPath || p.dirname(pidPath) != p.dirname(ackPath)) {
      throw StateError(
        'Tracked-child PID and acknowledgement paths must be distinct siblings.',
      );
    }
    final parentType = FileSystemEntity.typeSync(
      p.dirname(pidPath),
      followLinks: false,
    );
    if (parentType != FileSystemEntityType.directory) {
      throw StateError(
        'Tracked-child registration parent must be a directory.',
      );
    }
    for (final path in [pidPath, ackPath]) {
      if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw StateError(
          'Tracked-child PID and acknowledgement files must be absent before launch.',
        );
      }
    }
  }

  /// Launches and waits for one CLI invocation.
  Future<CliProcessResult> run(
    List<String> argv, {
    Directory? workingDirectory,
    Map<String, String> environmentAdditions = const <String, String>{},
    Set<String> environmentRemovals = const <String>{},
    String? stdinText,
    List<int>? stdinBytes,
    File? readyFile,
    File? releaseFile,
    TrackedChildRegistration? trackedChildRegistration,
    File? entrypointOverride,
    Duration? timeout,
    Duration? timeoutAfterReady,
    bool? trackProcessTree,
  }) async {
    final invocation = await start(
      argv,
      workingDirectory: workingDirectory,
      environmentAdditions: environmentAdditions,
      environmentRemovals: environmentRemovals,
      stdinText: stdinText,
      stdinBytes: stdinBytes,
      readyFile: readyFile,
      releaseFile: releaseFile,
      trackedChildRegistration: trackedChildRegistration,
      entrypointOverride: entrypointOverride,
      timeout: timeout,
      timeoutAfterReady: timeoutAfterReady,
      trackProcessTree: trackProcessTree,
    );
    return invocation.result;
  }

  /// Runs a public quarantine command with the explicit root-only contract.
  ///
  /// Quarantine list, inspect, and clean do not start child processes; unlike
  /// scan, apply, and rollback, their root process is the complete process set
  /// the test needs to bound and confirm. Keep this opt-out local to the
  /// quarantine command tests instead of weakening automatic tracking.
  Future<CliProcessResult> runQuarantineOnly(
    List<String> argv, {
    Directory? workingDirectory,
    Map<String, String> environmentAdditions = const <String, String>{},
    Set<String> environmentRemovals = const <String>{},
    String? stdinText,
    List<int>? stdinBytes,
    File? readyFile,
    File? releaseFile,
    Duration? timeout,
    Duration? timeoutAfterReady,
  }) async {
    _validateQuarantineOnlyArgv(argv);
    return run(
      argv,
      workingDirectory: workingDirectory,
      environmentAdditions: environmentAdditions,
      environmentRemovals: environmentRemovals,
      stdinText: stdinText,
      stdinBytes: stdinBytes,
      readyFile: readyFile,
      releaseFile: releaseFile,
      timeout: timeout,
      timeoutAfterReady: timeoutAfterReady,
      trackProcessTree: false,
    );
  }

  /// Launches the real command runner with the explicit test-only clean fake.
  ///
  /// The fake executes its reviewed deletion seam in-process and never starts
  /// a descendant process, so its bounded root lifecycle is the truthful test
  /// contract. Keep general CLI invocations on automatic tree tracking.
  Future<CliProcessResult> runQuarantineCleanFake(
    List<String> argv, {
    Directory? workingDirectory,
    Map<String, String> environmentAdditions = const <String, String>{},
    String? stdinText,
    File? readyFile,
    File? releaseFile,
    Duration? timeout,
    Duration? timeoutAfterReady,
  }) async {
    _validateQuarantineCleanFakeArgv(argv);
    return run(
      argv,
      workingDirectory: workingDirectory,
      environmentAdditions: environmentAdditions,
      stdinText: stdinText,
      readyFile: readyFile,
      releaseFile: releaseFile,
      entrypointOverride: quarantineCleanFakeEntrypoint,
      timeout: timeout,
      timeoutAfterReady: timeoutAfterReady,
      trackProcessTree: false,
    );
  }

  /// Starts the explicit clean fake so a test can coordinate its barriers.
  ///
  /// See [runQuarantineCleanFake] for the explicit root-only rationale.
  Future<CliProcessInvocation> startQuarantineCleanFake(
    List<String> argv, {
    Directory? workingDirectory,
    Map<String, String> environmentAdditions = const <String, String>{},
    String? stdinText,
    File? readyFile,
    File? releaseFile,
    Duration? timeout,
    Duration? timeoutAfterReady,
  }) {
    _validateQuarantineCleanFakeArgv(argv);
    return start(
      argv,
      workingDirectory: workingDirectory,
      environmentAdditions: environmentAdditions,
      stdinText: stdinText,
      readyFile: readyFile,
      releaseFile: releaseFile,
      entrypointOverride: quarantineCleanFakeEntrypoint,
      timeout: timeout,
      timeoutAfterReady: timeoutAfterReady,
      trackProcessTree: false,
    );
  }

  static void _validateQuarantineOnlyArgv(List<String> argv) {
    if (argv.isEmpty || argv.first != 'quarantine') {
      throw ArgumentError.value(
        argv,
        'argv',
        'runQuarantineOnly accepts only quarantine commands.',
      );
    }
  }

  static void _validateQuarantineCleanFakeArgv(List<String> argv) {
    _validateQuarantineOnlyArgv(argv);
    if (argv.length < 2 || argv[1] != 'clean') {
      throw ArgumentError.value(
        argv,
        'argv',
        'The quarantine clean fake accepts only quarantine clean commands.',
      );
    }
  }

  /// Bounded teardown for tests that fail while invocations are still active.
  Future<void> close() async {
    final active = List<_ActiveCliProcess>.of(_launched);
    await Future.wait(
      active.map((process) async {
        await process.terminate();
        _launched.remove(process);
      }),
    );
  }

  static Directory _findRepositoryRoot(Directory start) {
    var candidate = start.absolute;
    while (true) {
      if (File(
            p.join(candidate.path, 'bin', 'flutter_pruner.dart'),
          ).existsSync() &&
          File(
            p.join(candidate.path, '.dart_tool', 'package_config.json'),
          ).existsSync()) {
        return candidate;
      }
      final parent = candidate.parent;
      if (parent.path == candidate.path) {
        throw StateError('Could not find the flutter_pruner repository root.');
      }
      candidate = parent;
    }
  }
}

bool _hostSupportsTrackedProcessTrees() => Platform.isLinux || Platform.isMacOS;

/// POSIX-only create-new acknowledgement writer.
///
/// Dart's [File.createSync] closes its exclusive descriptor before returning,
/// while reopening a [File] by pathname is vulnerable to unlink/replace. This
/// test harness therefore uses the same O_CREAT|O_EXCL descriptor for write,
/// flush, and close. It deliberately performs no pathname cleanup on failure:
/// a replaced pathname is not safe to delete.
class _PosixExclusiveAcknowledgementWriter {
  static final DynamicLibrary _libc = DynamicLibrary.process();
  static final _malloc = _libc
      .lookupFunction<
        Pointer<Void> Function(IntPtr),
        Pointer<Void> Function(int)
      >('malloc');
  static final _free = _libc
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('free');
  static final int Function(Pointer<Uint8>, int, int) _open = _libc
      .lookup<NativeFunction<_NativeOpen>>('open')
      .asFunction();
  static final _write = _libc
      .lookupFunction<
        IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
        int Function(int, Pointer<Uint8>, int)
      >('write');
  static final _fchmod = _libc
      .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
        'fchmod',
      );
  static final _fsync = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('fsync');
  static final _ftruncate = _libc
      .lookupFunction<Int32 Function(Int32, IntPtr), int Function(int, int)>(
        'ftruncate',
      );
  static final _close = _libc
      .lookupFunction<Int32 Function(Int32), int Function(int)>('close');

  static const _oWriteOnly = 1;
  static const _oCreateLinux = 0x40;
  static const _oExclusiveLinux = 0x80;
  static const _oCreateMacOS = 0x0200;
  static const _oExclusiveMacOS = 0x0800;
  static const _ownerReadWrite = 0x0180;

  static void write(
    File file,
    String contents, {
    AcknowledgementExclusiveOpenModeObserver? afterExclusiveOpenBeforeFchmod,
    AcknowledgementExclusiveOpenObserver? afterExclusiveOpen,
  }) {
    final path = _allocateUtf8(file.path, nulTerminate: true);
    Pointer<Uint8>? bytes;
    var descriptor = -1;
    var flushed = false;
    try {
      final contentsBytes = _allocateUtf8(contents);
      bytes = contentsBytes;
      final create = Platform.isMacOS ? _oCreateMacOS : _oCreateLinux;
      final exclusive = Platform.isMacOS ? _oExclusiveMacOS : _oExclusiveLinux;
      descriptor = _open(
        path,
        _oWriteOnly | create | exclusive,
        _ownerReadWrite,
      );
      if (descriptor < 0) {
        throw FileSystemException(
          'Could not exclusively create acknowledgement.',
          file.path,
        );
      }
      afterExclusiveOpenBeforeFchmod?.call(file);
      if (_fchmod(descriptor, _ownerReadWrite) != 0) {
        throw FileSystemException(
          'Could not set acknowledgement permissions through its exclusive descriptor.',
          file.path,
        );
      }
      afterExclusiveOpen?.call(file);

      var offset = 0;
      final length = utf8.encode(contents).length;
      while (offset < length) {
        final written = _write(
          descriptor,
          contentsBytes + offset,
          length - offset,
        );
        if (written <= 0) {
          throw FileSystemException(
            'Could not write acknowledgement through its exclusive descriptor.',
            file.path,
          );
        }
        offset += written;
      }
      if (_fsync(descriptor) != 0) {
        throw FileSystemException(
          'Could not flush acknowledgement through its exclusive descriptor.',
          file.path,
        );
      }
      flushed = true;
    } finally {
      if (descriptor >= 0) {
        if (!flushed) {
          // Do not leave a partial or unflushed record that a fixture could
          // mistake for proof of registration. This acts on the descriptor,
          // never the potentially replaced pathname.
          _ftruncate(descriptor, 0);
          _fsync(descriptor);
        }
        _close(descriptor);
      }
      if (bytes != null) _free(bytes.cast<Void>());
      _free(path.cast<Void>());
    }
  }

  static Pointer<Uint8> _allocateUtf8(
    String value, {
    bool nulTerminate = false,
  }) {
    final encoded = utf8.encode(value);
    final pointer = _malloc(
      encoded.length + (nulTerminate ? 1 : 0),
    ).cast<Uint8>();
    if (pointer.address == 0) {
      throw FileSystemException('Could not allocate acknowledgement buffer.');
    }
    pointer.asTypedList(encoded.length).setAll(0, encoded);
    if (nulTerminate) pointer[encoded.length] = 0;
    return pointer;
  }
}

/// A started invocation kept alive until the root and both output streams end.
class CliProcessInvocation {
  const CliProcessInvocation._(this._active);

  final _ActiveCliProcess _active;

  /// Completion includes raw stream closure, not merely root exit.
  Future<CliProcessResult> get result => _active.completion;

  /// Terminates the tracked root/tree and confirms its disappearance.
  Future<void> close() => _active.terminate();
}

class _ActiveCliProcess {
  _ActiveCliProcess({
    required this.process,
    required List<String> argv,
    required this.readyFile,
    required this.releaseFile,
    required this.trackedChildRegistration,
    required this.timeout,
    required this.timeoutAfterReady,
    required this.trackProcessTree,
    required PosixProcessTableReader posixProcessTableReader,
    required PosixIdentitySignalSender posixIdentitySignalSender,
    required this.cleanupAttemptObserver,
    required this.acknowledgementExclusiveOpenObserver,
    required this.acknowledgementExclusiveOpenModeObserver,
  }) : argv = List<String>.unmodifiable(argv),
       _posixProcessTableReader = posixProcessTableReader,
       _posixIdentitySignalSender = posixIdentitySignalSender,
       _stopwatch = Stopwatch()..start(),
       _stdout = _collectBytes(process.stdout),
       _stderr = _collectBytes(process.stderr),
       _exitCode = process.exitCode;

  static const _cleanupTimeout = Duration(seconds: 8);
  static const _observationInterval = Duration(milliseconds: 100);

  final Process process;
  final List<String> argv;
  final File? readyFile;
  final File? releaseFile;
  final TrackedChildRegistration? trackedChildRegistration;
  final Duration timeout;
  final Duration? timeoutAfterReady;
  final bool trackProcessTree;
  final PosixProcessTableReader _posixProcessTableReader;
  final PosixIdentitySignalSender _posixIdentitySignalSender;
  final CleanupAttemptObserver? cleanupAttemptObserver;
  final AcknowledgementExclusiveOpenObserver?
  acknowledgementExclusiveOpenObserver;
  final AcknowledgementExclusiveOpenModeObserver?
  acknowledgementExclusiveOpenModeObserver;
  final Stopwatch _stopwatch;
  final Future<List<int>> _stdout;
  final Future<List<int>> _stderr;
  final Future<int> _exitCode;
  late final Future<CliProcessResult> _completion;
  _PosixProcessTreeObserver? _observer;
  Future<_CleanupDeadline>? _cleanup;
  var _initialized = false;
  var _completionBegun = false;
  var _cleanupConfirmed = false;
  var _nextCleanupEpisode = 0;

  bool get cleanupConfirmed => _cleanupConfirmed;

  Future<CliProcessResult> get completion {
    if (!_completionBegun) {
      throw StateError('Invocation completion was read before initialization.');
    }
    return _completion;
  }

  void beginCompletion() {
    if (_completionBegun) return;
    _completionBegun = true;
    _completion = _complete();
  }

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    if (trackProcessTree && (Platform.isLinux || Platform.isMacOS)) {
      final observer = _PosixProcessTreeObserver(
        rootPid: process.pid,
        reader: _posixProcessTableReader,
        signalSender: _posixIdentitySignalSender,
        observationInterval: _observationInterval,
        trackedChildRegistration: trackedChildRegistration,
        acknowledgementExclusiveOpenObserver:
            acknowledgementExclusiveOpenObserver,
        acknowledgementExclusiveOpenModeObserver:
            acknowledgementExclusiveOpenModeObserver,
      );
      _observer = observer;
      final captured = await observer.start();
      if (!captured) {
        throw const CliProcessTerminationUnconfirmedException(
          'Could not capture a stable root process identity for tracked fixture cleanup.',
        );
      }
    }
  }

  Future<CliProcessResult> _complete() async {
    var timedOut = false;
    try {
      if (readyFile != null) {
        await _waitForReadyFileOrExit(readyFile!);
      }
      final remaining = timeoutAfterReady ?? _remaining;
      if (remaining <= Duration.zero) {
        throw TimeoutException('CLI invocation timed out.');
      }
      if (_observer != null) {
        // A tracked child can deliberately inherit the root's output handles.
        // Once the identity-authorized root has exited, close the observed tree
        // before awaiting those handles, rather than misclassifying success as
        // a timeout solely because the child still owns a pipe.
        final exitCode = await _exitCode.timeout(remaining);
        await _finalizeSuccessfulTrackedLifecycle();
        final output = await Future.wait<List<int>>([
          _stdout,
          _stderr,
        ]).timeout(_remaining);
        _stopwatch.stop();
        return CliProcessResult(
          argv: argv,
          processId: process.pid,
          exitCode: exitCode,
          timedOut: false,
          elapsed: _stopwatch.elapsed,
          stdoutBytes: output[0],
          stderrBytes: output[1],
          readyFile: readyFile,
          releaseFile: releaseFile,
        );
      }
      final completed = await Future.wait<Object>([
        _exitCode,
        _stdout,
        _stderr,
      ]).timeout(remaining);
      await _finalizeSuccessfulTrackedLifecycle();
      _stopwatch.stop();
      return CliProcessResult(
        argv: argv,
        processId: process.pid,
        exitCode: completed[0] as int,
        timedOut: false,
        elapsed: _stopwatch.elapsed,
        stdoutBytes: completed[1] as List<int>,
        stderrBytes: completed[2] as List<int>,
        readyFile: readyFile,
        releaseFile: releaseFile,
      );
    } on TimeoutException {
      timedOut = true;
    } on CliProcessTerminationUnconfirmedException {
      rethrow;
    } catch (_) {
      await terminate();
      rethrow;
    }

    final cleanupDeadline = await _cleanupWithOneRetry();
    try {
      final completed = await Future.wait<Object>([
        _exitCode,
        _stdout,
        _stderr,
      ]).timeout(cleanupDeadline.remaining);
      _stopwatch.stop();
      return CliProcessResult(
        argv: argv,
        processId: process.pid,
        exitCode: completed[0] as int,
        timedOut: timedOut,
        elapsed: _stopwatch.elapsed,
        stdoutBytes: completed[1] as List<int>,
        stderrBytes: completed[2] as List<int>,
        readyFile: readyFile,
        releaseFile: releaseFile,
      );
    } on TimeoutException {
      throw CliProcessTerminationUnconfirmedException(
        'PID ${process.pid} stopped but stdout or stderr did not close.',
      );
    }
  }

  Duration get _remaining => timeout - _stopwatch.elapsed;

  Future<void> _waitForReadyFileOrExit(File file) async {
    while (!file.existsSync()) {
      final remaining = _remaining;
      if (remaining <= Duration.zero) {
        throw TimeoutException('CLI invocation timed out.');
      }
      final exited = await Future.any<bool>([
        _exitCode.then((_) => true),
        Future<bool>.delayed(
          remaining < const Duration(milliseconds: 20)
              ? remaining
              : const Duration(milliseconds: 20),
          () => false,
        ),
      ]);
      if (exited) {
        throw StateError(
          'Process ${process.pid} exited before ready file ${file.path}.',
        );
      }
    }
  }

  Future<void> terminate() async {
    await _cleanupTrackedOrRoot();
  }

  Future<void> _finalizeSuccessfulTrackedLifecycle() async {
    if (_observer == null) return;
    await _cleanupWithOneRetry(rootAlreadyExited: true);
  }

  Future<_CleanupDeadline> _cleanupWithOneRetry({
    bool rootAlreadyExited = false,
  }) async {
    final deadline = _CleanupDeadline(_cleanupTimeout);
    final episode = ++_nextCleanupEpisode;
    try {
      return await _cleanupTrackedOrRoot(
        deadline: deadline,
        episode: episode,
        attempt: 1,
        rootAlreadyExited: rootAlreadyExited,
      );
    } on CliProcessTerminationUnconfirmedException {
      // A transient inspection failure gets one bounded retry, but both
      // attempts share the same lifecycle cleanup deadline.
      return _cleanupTrackedOrRoot(
        deadline: deadline,
        episode: episode,
        attempt: 2,
        rootAlreadyExited: rootAlreadyExited,
      );
    }
  }

  Future<_CleanupDeadline> _cleanupTrackedOrRoot({
    _CleanupDeadline? deadline,
    int? episode,
    int attempt = 1,
    bool rootAlreadyExited = false,
  }) {
    final existing = _cleanup;
    if (existing != null) return existing;
    final activeDeadline = deadline ?? _CleanupDeadline(_cleanupTimeout);
    final activeEpisode = episode ?? ++_nextCleanupEpisode;
    final cleanup = _performCleanup(
      activeDeadline,
      activeEpisode,
      attempt,
      rootAlreadyExited: rootAlreadyExited,
    );
    _cleanup = cleanup;
    return cleanup;
  }

  Future<_CleanupDeadline> _performCleanup(
    _CleanupDeadline deadline,
    int episode,
    int attempt, {
    required bool rootAlreadyExited,
  }) async {
    cleanupAttemptObserver?.call(episode, attempt);
    try {
      final observer = _observer;
      if (observer != null) {
        final reliable = await observer.stop(deadline);
        final terminated = await observer.terminate(
          process,
          _exitCode,
          reliable,
          deadline,
          rootAlreadyExited: rootAlreadyExited,
        );
        if (!terminated) {
          throw CliProcessTerminationUnconfirmedException(
            'Could not confirm termination of tracked fixture tree rooted at PID ${process.pid}.',
          );
        }
        _cleanupConfirmed = true;
        return deadline;
      }
      process.kill(ProcessSignal.sigkill);
      if (!await _waitForExit(_exitCode, deadline)) {
        throw CliProcessTerminationUnconfirmedException(
          'Could not confirm termination of PID ${process.pid}.',
        );
      }
      _cleanupConfirmed = true;
      return deadline;
    } catch (_) {
      // A failed inspection must not make cleanup permanently non-retryable.
      // The root Process handle is still safe to signal even if descendants
      // cannot be proven gone; the error remains fail-closed.
      process.kill(ProcessSignal.sigkill);
      await _waitForExit(_exitCode, deadline);
      _cleanup = null;
      rethrow;
    }
  }
}

class _PosixProcessTreeObserver {
  _PosixProcessTreeObserver({
    required this.rootPid,
    required this.reader,
    required this.signalSender,
    required this.observationInterval,
    required this.trackedChildRegistration,
    required this.acknowledgementExclusiveOpenObserver,
    required this.acknowledgementExclusiveOpenModeObserver,
  });

  final int rootPid;
  final PosixProcessTableReader reader;
  final PosixIdentitySignalSender signalSender;
  final Duration observationInterval;
  final TrackedChildRegistration? trackedChildRegistration;
  final AcknowledgementExclusiveOpenObserver?
  acknowledgementExclusiveOpenObserver;
  final AcknowledgementExclusiveOpenModeObserver?
  acknowledgementExclusiveOpenModeObserver;
  final Map<int, PosixProcessIdentity> _observed = {};
  var _reliable = true;
  var _stopping = false;
  Future<void>? _task;

  Future<bool> start() async {
    await _observeOnce(requireRoot: true);
    if (!_reliable) return false;
    _task = _observe();
    return true;
  }

  Future<bool> stop(_CleanupDeadline deadline) async {
    _stopping = true;
    if (_task != null) await deadline.waitFor(_task!);
    return _reliable;
  }

  Future<void> _observe() async {
    while (!_stopping) {
      await Future<void>.delayed(observationInterval);
      if (!_stopping) await _observeOnce();
    }
  }

  Future<void> _observeOnce({bool requireRoot = false}) async {
    try {
      final table = await reader();
      if (table == null) {
        _reliable = false;
        return;
      }
      final root = table.identityFor(rootPid);
      if (root == null) {
        if (requireRoot || !_observed.containsKey(rootPid)) _reliable = false;
        return;
      }
      if (_observed[rootPid] case final previous? when previous != root) {
        _reliable = false;
        return;
      }
      _observed[rootPid] = root;
      final liveRoots = table.matchingPids(_observed.values);
      for (final pid in table.descendantsOf(liveRoots)) {
        final identity = table.identityFor(pid);
        if (identity != null) _observed[pid] = identity;
      }
      _tryRegisterTrackedChild(table, liveRoots);
    } catch (_) {
      _reliable = false;
    }
  }

  void _tryRegisterTrackedChild(
    PosixProcessTableSnapshot table,
    Set<int> liveRoots,
  ) {
    final registration = trackedChildRegistration;
    if (registration == null) return;
    if (FileSystemEntity.typeSync(
          registration.acknowledgementFile.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      return;
    }
    if (FileSystemEntity.typeSync(
          registration.pidFile.path,
          followLinks: false,
        ) !=
        FileSystemEntityType.file) {
      return;
    }
    final pid = int.tryParse(registration.pidFile.readAsStringSync().trim());
    if (pid == null) return;
    final identity = table.identityFor(pid);
    final descendants = table.descendantsOf(liveRoots);
    if (identity == null || !descendants.contains(pid)) return;
    _observed[pid] = identity;
    try {
      // Keep the descriptor returned by O_CREAT|O_EXCL open for the complete
      // record. Reopening this pathname would let an unlink/replace race
      // redirect or truncate another file.
      _PosixExclusiveAcknowledgementWriter.write(
        registration.acknowledgementFile,
        registration.acknowledgementText,
        afterExclusiveOpenBeforeFchmod:
            acknowledgementExclusiveOpenModeObserver,
        afterExclusiveOpen: acknowledgementExclusiveOpenObserver,
      );
    } on FileSystemException {
      // A raced entity is never followed, overwritten, or treated as our ack.
    }
  }

  Future<bool> terminate(
    Process root,
    Future<int> exitCode,
    bool observationReliable,
    _CleanupDeadline deadline, {
    required bool rootAlreadyExited,
  }) async {
    final tracked = Map<int, PosixProcessIdentity>.from(_observed);
    var reliable = observationReliable && tracked.containsKey(rootPid);
    if (rootAlreadyExited) tracked.remove(rootPid);
    var frozen = false;
    try {
      if (!reliable) {
        root.kill(ProcessSignal.sigkill);
        await _waitForExit(root.exitCode, deadline);
        return false;
      }
      for (var pass = 0; pass < 6; pass++) {
        final table = await _readWithinDeadline(deadline);
        if (table == null) {
          reliable = false;
          break;
        }
        final live = table.matchingPids(tracked.values);
        final discovered = table.descendantsOf(live)..removeAll(live);
        for (final pid in discovered) {
          final identity = table.identityFor(pid);
          if (identity != null) tracked[pid] = identity;
        }
        final expanded = table.matchingPids(tracked.values);
        if (discovered.isEmpty && expanded.every(table.isStopped)) {
          frozen = true;
          break;
        }
        for (final pid in _childrenBeforeRoot(table, expanded, rootPid)) {
          final identity = tracked[pid];
          if (identity != null) {
            PosixProcessTreeSafety.signalIfIdentityCurrent(
              identity: identity,
              table: table,
              signal: ProcessSignal.sigstop,
              signalSender: signalSender,
            );
          }
        }
      }
      final killed = await _killTracked(
        tracked,
        requireStopped: true,
        deadline: deadline,
      );
      final rootExited = await _waitForExit(exitCode, deadline);
      final descendantsGone = await _waitForTrackedToDisappear(
        tracked.values,
        deadline,
      );
      return reliable && frozen && killed && rootExited && descendantsGone;
    } catch (_) {
      // The Process handle is still safe to kill even when process-table
      // inspection has failed; the false result keeps the caller fail-closed.
      root.kill(ProcessSignal.sigkill);
      await _waitForExit(root.exitCode, deadline);
      return false;
    }
  }

  Future<bool> _killTracked(
    Map<int, PosixProcessIdentity> tracked, {
    required bool requireStopped,
    required _CleanupDeadline deadline,
  }) async {
    final table = await _readWithinDeadline(deadline);
    if (table == null) return false;
    final live = table.matchingPids(tracked.values);
    final allStopped = live.every(table.isStopped);
    for (final pid in _childrenBeforeRoot(table, live, rootPid)) {
      final identity = tracked[pid];
      if (identity != null) {
        PosixProcessTreeSafety.signalIfIdentityCurrent(
          identity: identity,
          table: table,
          signal: ProcessSignal.sigkill,
          signalSender: signalSender,
        );
      }
    }
    return !requireStopped || allStopped;
  }

  Future<bool> _waitForTrackedToDisappear(
    Iterable<PosixProcessIdentity> identities,
    _CleanupDeadline deadline,
  ) async {
    while (!deadline.expired) {
      final table = await _readWithinDeadline(deadline);
      if (table == null) return false;
      if (table.matchingPids(identities).isEmpty) return true;
      await deadline.delay(const Duration(milliseconds: 25));
    }
    return false;
  }

  Future<PosixProcessTableSnapshot?> _readWithinDeadline(
    _CleanupDeadline deadline,
  ) async {
    try {
      return await deadline.waitFor(reader());
    } on TimeoutException {
      return null;
    }
  }
}

/// The identity gate used before a test harness sends a POSIX signal.
///
/// It is public solely to give deterministic tests a PID-reuse seam without
/// ever signalling a real unrelated PID.
class PosixProcessTreeSafety {
  /// Returns a dependency-safe signal order: deepest descendants first, root
  /// last. This is public only for deterministic harness tests.
  static List<int> childBeforeParentOrder({
    required PosixProcessTableSnapshot table,
    required Set<int> live,
    required int rootPid,
  }) => _childrenBeforeRoot(table, live, rootPid);

  static bool signalIfIdentityCurrent({
    required PosixProcessIdentity identity,
    required PosixProcessTableSnapshot table,
    required ProcessSignal signal,
    required PosixIdentitySignalSender signalSender,
  }) {
    if (!table.containsIdentity(identity)) return false;
    try {
      signalSender(identity, signal);
      return true;
    } on ProcessException {
      return false;
    }
  }
}

List<int> _childrenBeforeRoot(
  PosixProcessTableSnapshot table,
  Set<int> live,
  int rootPid,
) {
  final children = live.where((pid) => pid != rootPid).toList()
    ..sort((left, right) {
      final leftDepth = table.descendantsOf({left}).length;
      final rightDepth = table.descendantsOf({right}).length;
      return leftDepth.compareTo(rightDepth);
    });
  if (live.contains(rootPid)) children.add(rootPid);
  return children;
}

class _CleanupDeadline {
  _CleanupDeadline(this.limit) : _stopwatch = Stopwatch()..start();

  final Duration limit;
  final Stopwatch _stopwatch;

  Duration get remaining {
    final value = limit - _stopwatch.elapsed;
    return value.isNegative ? Duration.zero : value;
  }

  bool get expired => remaining <= Duration.zero;

  Future<T> waitFor<T>(Future<T> future) {
    final duration = remaining;
    if (duration <= Duration.zero) {
      return Future<T>.error(TimeoutException('Cleanup deadline expired.'));
    }
    return future.timeout(duration);
  }

  Future<void> delay(Duration value) {
    final duration = remaining < value ? remaining : value;
    if (duration <= Duration.zero) {
      return Future<void>.error(TimeoutException('Cleanup deadline expired.'));
    }
    return Future<void>.delayed(duration);
  }
}

Future<bool> _waitForExit(
  Future<int> exitCode,
  _CleanupDeadline deadline,
) async {
  try {
    await deadline.waitFor(exitCode);
    return true;
  } on TimeoutException {
    return false;
  }
}

Future<List<int>> _collectBytes(Stream<List<int>> stream) async {
  final chunks = await stream.toList();
  return <int>[for (final chunk in chunks) ...chunk];
}

Future<PosixProcessTableSnapshot?> _readPosixProcessTable() async {
  try {
    final result = await Process.run('ps', const [
      '-axo',
      'pid=,ppid=,lstart=,state=',
    ]).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return null;
    return PosixProcessTableSnapshot.parse(result.stdout as String);
  } catch (_) {
    return null;
  }
}

void _sendPosixIdentitySignal(
  PosixProcessIdentity identity,
  ProcessSignal signal,
) {
  Process.killPid(identity.pid, signal);
}

class CliProcessResult {
  const CliProcessResult({
    required this.argv,
    required this.processId,
    required this.exitCode,
    required this.timedOut,
    required this.elapsed,
    required this.stdoutBytes,
    required this.stderrBytes,
    required this.readyFile,
    required this.releaseFile,
  });

  final List<String> argv;
  final int processId;
  final int exitCode;
  final bool timedOut;
  final Duration elapsed;
  final List<int> stdoutBytes;
  final List<int> stderrBytes;
  final File? readyFile;
  final File? releaseFile;

  String get stdoutText => utf8.decode(stdoutBytes, allowMalformed: false);
  String get stderrText => utf8.decode(stderrBytes, allowMalformed: false);
}

/// Ensures stdout is exactly one JSON value; no leading/trailing bytes hide
/// human-output contamination.
void expectJsonStdout(CliProcessResult result, Matcher matcher) {
  final text = result.stdoutText;
  expect(text, isNotEmpty, reason: 'Expected one JSON stdout value.');
  if (text.trim() != text) {
    fail('stdout contained leading or trailing bytes outside the JSON value.');
  }
  Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    fail('stdout was not exactly one JSON value: $error\n$text');
  }
  expect(decoded, matcher);
}

/// Rejects every ANSI introducer, including incomplete CSI, OSC and DCS.
///
/// It works on strictly decoded Unicode text, so a UTF-8 continuation byte is
/// never mistaken for legacy 8-bit ANSI control input.
void expectNoAnsi(CliProcessResult result) {
  final output = '${result.stdoutText}${result.stderrText}';
  final ansiIntroducer = RegExp(r'[\x1b\x90\x98\x9b\x9d-\x9f]');
  expect(output, isNot(contains(ansiIntroducer)));
}

/// Waits for a test fixture barrier without an unbounded polling loop.
Future<void> waitForReadyFile(
  File readyFile, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!readyFile.existsSync()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Timed out waiting for ${readyFile.path}.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// A deterministic disposable project fixture for CLI subprocess tests.
class CliFixture {
  CliFixture._(this.root);

  factory CliFixture.create({String prefix = 'flutter_pruner cli '}) {
    return CliFixture._(Directory.systemTemp.createTempSync(prefix));
  }

  final Directory root;

  File file(String relativePath) {
    if (p.isAbsolute(relativePath)) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    final candidate = p.normalize(p.join(root.path, relativePath));
    final normalizedRoot = p.normalize(root.path);
    if (candidate != normalizedRoot && !p.isWithin(normalizedRoot, candidate)) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    return File(candidate);
  }

  Future<void> writeBytes(Map<String, List<int>> files) async {
    for (final path in files.keys.toList()..sort()) {
      final target = file(path);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(files[path]!);
    }
  }

  Future<void> writeText(Map<String, String> files) {
    return writeBytes(
      files.map((path, text) => MapEntry(path, utf8.encode(text))),
    );
  }

  Future<void> dispose() async {
    if (root.existsSync()) await root.delete(recursive: true);
  }
}
