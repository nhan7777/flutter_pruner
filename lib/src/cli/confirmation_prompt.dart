import 'dart:io';

/// Reads one explicit confirmation value from an interactive terminal.
abstract interface class ConfirmationPrompt {
  /// Whether this prompt is attached to an interactive terminal.
  bool get isInteractive;

  /// Writes [message] and returns one input line, or `null` on EOF.
  Future<String?> readLine(String message);
}

/// Standard-input confirmation used by the production CLI.
final class StdioConfirmationPrompt implements ConfirmationPrompt {
  /// Creates the standard terminal prompt.
  const StdioConfirmationPrompt();

  @override
  bool get isInteractive => stdin.hasTerminal;

  @override
  Future<String?> readLine(String message) async {
    stdout.write(message);
    return stdin.readLineSync();
  }
}

/// Parses the exact confirmation contract for all-target quarantine cleanup.
abstract final class CleanAllConfirmation {
  static final RegExp _fingerprint = RegExp(r'^v[1-9][0-9]*:[0-9a-f]{64}$');

  /// Returns whether [value] is one complete lowercase versioned fingerprint.
  static bool isValidFingerprint(String? value) =>
      value != null && _fingerprint.hasMatch(value);

  /// Builds the only accepted interactive phrase for this reviewed plan.
  static String requiredPhrase({
    required int targetCount,
    required String fingerprint,
  }) {
    if (targetCount < 0) {
      throw ArgumentError.value(targetCount, 'targetCount');
    }
    if (!isValidFingerprint(fingerprint)) {
      throw ArgumentError.value(fingerprint, 'fingerprint');
    }
    return 'clean-all $targetCount ${fingerprint.substring(3, 15)}';
  }

  /// Returns true only for an exact byte-for-byte phrase match.
  static bool matches({
    required String? input,
    required int targetCount,
    required String fingerprint,
  }) =>
      input != null &&
      input ==
          requiredPhrase(targetCount: targetCount, fingerprint: fingerprint);
}
