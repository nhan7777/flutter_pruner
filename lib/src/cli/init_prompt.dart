import 'dart:io';

/// Terminal abstraction used by the interactive `init` wizard.
///
/// Tests inject a deterministic implementation so command tests never depend
/// on the host process terminal or block waiting for stdin.
abstract class InitPrompt {
  /// Whether this prompt is attached to an interactive terminal.
  bool get isInteractive;

  /// Writes text without appending a newline.
  void write(String value);

  /// Writes one line.
  void writeln([String value = '']);

  /// Reads one response, or `null` on EOF.
  String? readLine();
}

/// Production prompt backed by process stdin/stdout.
class StdioInitPrompt implements InitPrompt {
  /// Creates a stdio-backed prompt.
  const StdioInitPrompt();

  @override
  bool get isInteractive => stdin.hasTerminal && stdout.hasTerminal;

  @override
  String? readLine() => stdin.readLineSync();

  @override
  void write(String value) => stdout.write(value);

  @override
  void writeln([String value = '']) => stdout.writeln(value);
}

/// Reusable yes/no and default-value interaction rules.
class InitQuestions {
  /// Creates questions on [prompt].
  const InitQuestions(this.prompt);

  /// Terminal used for interaction.
  final InitPrompt prompt;

  /// Asks a yes/no question and repeats invalid input.
  bool yesNo(String question, {required bool defaultValue}) {
    final suffix = defaultValue ? '[Y/n]' : '[y/N]';
    while (true) {
      prompt.write('$question $suffix ');
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final normalized = response.trim().toLowerCase();
      if (normalized.isEmpty) return defaultValue;
      if (normalized == 'y' || normalized == 'yes') return true;
      if (normalized == 'n' || normalized == 'no') return false;
      prompt.writeln('Please answer yes or no.');
    }
  }

  /// Asks for a value, applying [validate] before returning it.
  String text(
    String label, {
    String? defaultValue,
    required String Function(String value) validate,
  }) {
    while (true) {
      final suffix = defaultValue == null ? '' : ' [$defaultValue]';
      prompt.write('$label$suffix: ');
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final candidate = response.trim().isEmpty
          ? defaultValue
          : response.trim();
      if (candidate == null || candidate.isEmpty) {
        prompt.writeln('A value is required.');
        continue;
      }
      try {
        return validate(candidate);
      } on FormatException catch (error) {
        prompt.writeln('Invalid value: ${error.message}');
      }
    }
  }

  /// Asks for an optional value; blank input returns [defaultValue].
  String? optionalText(
    String label, {
    String? defaultValue,
    String Function(String value)? validate,
  }) {
    while (true) {
      final shownDefault = defaultValue ?? 'none';
      prompt.write('$label [$shownDefault]: ');
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final normalized = response.trim();
      if (normalized.isEmpty) return defaultValue;
      if (normalized.toLowerCase() == 'none') return null;
      try {
        return validate == null ? normalized : validate(normalized);
      } on FormatException catch (error) {
        prompt.writeln('Invalid value: ${error.message}');
      }
    }
  }
}

/// The owner cancelled interactive initialization before any write.
class InitCancelledException implements Exception {
  /// Creates the cancellation signal.
  const InitCancelledException();
}
