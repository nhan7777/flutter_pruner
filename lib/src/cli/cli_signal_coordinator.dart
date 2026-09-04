import 'dart:async';
import 'dart:io';

import '../core/process/managed_process_runner.dart';

/// Coordinates CLI presentation cleanup with owned managed-process trees.
abstract interface class CliSignalCoordinator {
  /// Replaces the one active animated-line clearer, or unregisters it.
  void setActiveLineClearer(void Function()? clearer);

  /// One-shot cancellation token shared by production managed runners.
  ManagedProcessCancellationController get processCancellation;

  /// Installs platform signal handling for the lifetime of [body].
  Future<T> guard<T>(Future<T> Function() body);
}

/// Creates the host's supported signal coordinator.
///
/// Windows deliberately uses the no-op coordinator. No ConPTY interrupted-line
/// or process-tree cleanup equivalence is claimed without hosted evidence.
CliSignalCoordinator createDefaultCliSignalCoordinator() {
  if (Platform.isLinux || Platform.isMacOS) {
    return PosixCliSignalCoordinator();
  }
  return NoopCliSignalCoordinator();
}

/// Signal stream boundary used by deterministic coordinator tests.
typedef CliSignalStream = Stream<ProcessSignal> Function(ProcessSignal signal);

/// Exact-signal re-delivery boundary used after subscriptions are detached.
typedef CliSignalRedeliver = void Function(ProcessSignal signal);

/// Conventional shell exit code for a safely unwound owned-process signal.
int conventionalSignalExitCode(ProcessSignal signal) =>
    128 + signal.signalNumber;

/// POSIX coordinator with first-signal recovery and second-signal hard stop.
final class PosixCliSignalCoordinator implements CliSignalCoordinator {
  /// Creates a coordinator.
  PosixCliSignalCoordinator({
    CliSignalStream? signalStream,
    CliSignalRedeliver? redeliver,
  }) : _signalStream = signalStream ?? _watchSignal,
       _redeliver = redeliver ?? _redeliverToCurrentProcess;

  final CliSignalStream _signalStream;
  final CliSignalRedeliver _redeliver;

  @override
  final ManagedProcessCancellationController processCancellation =
      ManagedProcessCancellationController();

  final List<StreamSubscription<ProcessSignal>> _subscriptions = [];
  void Function()? _activeLineClearer;
  Future<void>? _detachFuture;
  ProcessSignal? _firstSignal;
  var _guardActive = false;

  @override
  void setActiveLineClearer(void Function()? clearer) {
    _activeLineClearer = clearer;
  }

  @override
  Future<T> guard<T>(Future<T> Function() body) async {
    if (_guardActive) {
      throw StateError('CLI signal coordinator guard is already active.');
    }
    if (processCancellation.isRequested) {
      throw StateError(
        'A cancelled CLI signal coordinator cannot guard another invocation.',
      );
    }
    _guardActive = true;
    _detachFuture = null;
    _firstSignal = null;
    try {
      _subscriptions
        ..add(_signalStream(ProcessSignal.sigint).listen(_onSignal))
        ..add(_signalStream(ProcessSignal.sigterm).listen(_onSignal));
      return await body();
    } finally {
      _activeLineClearer = null;
      await _detach();
      _guardActive = false;
    }
  }

  void _onSignal(ProcessSignal signal) {
    unawaited(_handleSignal(signal));
  }

  Future<void> _handleSignal(ProcessSignal signal) async {
    if (_firstSignal != null) {
      final detached = _detach();
      _redeliver(signal);
      await detached;
      return;
    }
    _firstSignal = signal;

    final clearer = _activeLineClearer;
    _activeLineClearer = null;
    clearer?.call();

    if (processCancellation.pendingOrActiveTreeCount > 0) {
      processCancellation.requestCancellation(signal);
      return;
    }

    final detached = _detach();
    _redeliver(signal);
    await detached;
  }

  Future<void> _detach() {
    final existing = _detachFuture;
    if (existing != null) return existing;
    final subscriptions = List<StreamSubscription<ProcessSignal>>.from(
      _subscriptions,
    );
    _subscriptions.clear();
    return _detachFuture = Future.wait<void>([
      for (final subscription in subscriptions) subscription.cancel(),
    ]);
  }

  static Stream<ProcessSignal> _watchSignal(ProcessSignal signal) =>
      signal.watch();

  static void _redeliverToCurrentProcess(ProcessSignal signal) {
    Process.killPid(pid, signal);
  }
}

/// Default coordinator on hosts where an equivalent terminal/process contract
/// has not been proven.
final class NoopCliSignalCoordinator implements CliSignalCoordinator {
  @override
  final ManagedProcessCancellationController processCancellation =
      ManagedProcessCancellationController();

  @override
  Future<T> guard<T>(Future<T> Function() body) => body();

  @override
  void setActiveLineClearer(void Function()? clearer) {}
}
