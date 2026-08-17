/// Fine-grained timings for one Dart adapter benchmark run.
///
/// Profiling is opt-in so normal scans do not pay stopwatch or bookkeeping
/// overhead. Phase durations are cumulative when a phase runs once per file.
final class DartAdapterProfile {
  final Map<String, int> _elapsedMicros = {};
  final Map<String, int> _invocations = {};

  /// Measures one synchronous [operation] under [phase].
  T measure<T>(String phase, T Function() operation) {
    final stopwatch = Stopwatch()..start();
    try {
      return operation();
    } finally {
      stopwatch.stop();
      _record(phase, stopwatch.elapsedMicroseconds);
    }
  }

  /// Measures one asynchronous [operation] under [phase].
  Future<T> measureAsync<T>(
    String phase,
    Future<T> Function() operation,
  ) async {
    final stopwatch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      stopwatch.stop();
      _record(phase, stopwatch.elapsedMicroseconds);
    }
  }

  /// Returns a stable JSON-compatible snapshot sorted by phase name.
  Map<String, Object> snapshot() => {
    for (final phase in _elapsedMicros.keys.toList()..sort())
      phase: {
        'elapsedMicros': _elapsedMicros[phase]!,
        'invocations': _invocations[phase]!,
      },
  };

  void _record(String phase, int elapsedMicros) {
    _elapsedMicros.update(
      phase,
      (current) => current + elapsedMicros,
      ifAbsent: () => elapsedMicros,
    );
    _invocations.update(phase, (current) => current + 1, ifAbsent: () => 1);
  }
}
