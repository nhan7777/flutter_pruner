/// Clock used for wall timestamps and monotonic elapsed time.
abstract interface class RunClock {
  /// Current UTC wall-clock time.
  DateTime nowUtc();

  /// Monotonic microseconds from an arbitrary origin.
  int monotonicMicros();
}

/// Production clock backed by a continuously running stopwatch.
class SystemRunClock implements RunClock {
  /// Creates and starts the monotonic clock.
  SystemRunClock() : _stopwatch = Stopwatch()..start();

  final Stopwatch _stopwatch;

  @override
  DateTime nowUtc() => DateTime.now().toUtc();

  @override
  int monotonicMicros() => _stopwatch.elapsedMicroseconds;
}
