import 'run_report.dart';

/// Stable, sanitized failure facts that may be persisted in a run report.
///
/// This value deliberately has no exception or stack-trace field. Callers must
/// translate arbitrary failures into bounded, user-safe facts before creating
/// it.
final class ReportableCommandFailure {
  /// Creates one report-safe command failure.
  ReportableCommandFailure({
    required String code,
    required String phase,
    required String message,
    required int exitCode,
    required RunStatus status,
  }) : code = _validateCode(code),
       phase = _validatePhase(phase),
       message = _validateMessage(message),
       exitCode = _validateExitCode(exitCode),
       status = _validateStatus(status);

  /// Stable machine-readable failure code.
  final String code;

  /// Stable lifecycle phase, optionally including bounded adapter context.
  final String phase;

  /// Sanitized user-facing failure message.
  final String message;

  /// CLI exit code retained by the failed report.
  final int exitCode;

  /// Terminal report status retained by the failed report.
  final RunStatus status;

  static String _validateCode(String value) {
    if (value.length > 64 || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(value)) {
      throw ArgumentError.value(
        value,
        'code',
        'must be a stable snake_case ID',
      );
    }
    return value;
  }

  static String _validatePhase(String value) {
    if (value.length > 128 ||
        !RegExp(r'^[a-z][A-Za-z0-9]*(?::[A-Za-z0-9_.-]+)*$').hasMatch(value)) {
      throw ArgumentError.value(value, 'phase', 'must be a stable phase ID');
    }
    return value;
  }

  static String _validateMessage(String value) {
    final unsafe = value.runes.any(
      (rune) =>
          rune < 0x20 ||
          (rune >= 0x7f && rune <= 0x9f) ||
          (rune >= 0x200b && rune <= 0x200f) ||
          rune == 0x2028 ||
          rune == 0x2029 ||
          (rune >= 0x202a && rune <= 0x202e) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          rune == 0xfeff,
    );
    if (value.isEmpty ||
        value.length > 512 ||
        value.trim() != value ||
        unsafe) {
      throw ArgumentError.value(
        value,
        'message',
        'must be one bounded control-free line',
      );
    }
    return value;
  }

  static int _validateExitCode(int value) {
    if (value <= 0 || value > 255) {
      throw ArgumentError.value(value, 'exitCode', 'must be between 1 and 255');
    }
    return value;
  }

  static RunStatus _validateStatus(RunStatus value) {
    if (value == RunStatus.completed ||
        value == RunStatus.noChanges ||
        value == RunStatus.dryRun) {
      throw ArgumentError.value(value, 'status', 'must represent failure');
    }
    return value;
  }
}
