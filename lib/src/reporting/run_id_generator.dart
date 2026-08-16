import 'dart:math';

/// Generates stable-safe identifiers for scan and apply invocations.
abstract interface class RunIdGenerator {
  /// Creates the next identifier for a run starting at [startedAtUtc].
  String next(DateTime startedAtUtc);
}

/// UTC-sortable identifier with 80 bits of secure random entropy.
class SecureRunIdGenerator implements RunIdGenerator {
  /// Creates a secure generator.
  SecureRunIdGenerator() : _random = Random.secure();

  final Random _random;

  @override
  String next(DateTime startedAtUtc) {
    final utc = startedAtUtc.toUtc();
    final timestamp = utc.toIso8601String().replaceAll(RegExp(r'[-:]'), '');
    final entropy = List<int>.generate(
      10,
      (_) => _random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${timestamp}_$entropy';
  }
}
