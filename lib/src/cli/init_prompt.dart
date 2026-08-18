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

/// Optional capability for prompts that can render semantic ANSI styling.
abstract interface class AnsiInitPrompt {
  /// Whether ANSI color and text-weight escapes can be rendered.
  bool get supportsAnsiEscapes;
}

/// Production prompt backed by process stdin/stdout.
class StdioInitPrompt implements InitPrompt, AnsiInitPrompt {
  /// Creates a stdio-backed prompt.
  const StdioInitPrompt();

  @override
  bool get isInteractive => stdin.hasTerminal && stdout.hasTerminal;

  @override
  bool get supportsAnsiEscapes => stdout.supportsAnsiEscapes;

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
  const InitQuestions(this.prompt, {this.styled = false});

  /// Terminal used for interaction.
  final InitPrompt prompt;

  /// Whether to apply the interactive wizard's semantic ANSI hierarchy.
  final bool styled;

  /// Asks a yes/no question and repeats invalid input.
  bool yesNo(String question, {required bool defaultValue}) {
    final suffix = defaultValue ? '[Y/n]' : '[y/N]';
    while (true) {
      _writeQuestion(question, ' $suffix');
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final normalized = response.trim().toLowerCase();
      if (normalized.isEmpty) return defaultValue;
      if (normalized == 'y' || normalized == 'yes') return true;
      if (normalized == 'n' || normalized == 'no') return false;
      _writeError('Please answer yes or no.');
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
      _writeQuestion(label, suffix, colon: true);
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final candidate = response.trim().isEmpty
          ? defaultValue
          : response.trim();
      if (candidate == null || candidate.isEmpty) {
        _writeError('A value is required.');
        continue;
      }
      try {
        return validate(candidate);
      } on FormatException catch (error) {
        _writeError('Invalid value: ${error.message}');
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
      _writeQuestion(label, ' [$shownDefault]', colon: true);
      final response = prompt.readLine();
      if (response == null) throw const InitCancelledException();
      final normalized = response.trim();
      if (normalized.isEmpty) return defaultValue;
      if (normalized.toLowerCase() == 'none') return null;
      try {
        return validate == null ? normalized : validate(normalized);
      } on FormatException catch (error) {
        _writeError('Invalid value: ${error.message}');
      }
    }
  }

  void _writeQuestion(String label, String suffix, {bool colon = false}) {
    if (!styled) {
      prompt.write('$label$suffix${colon ? ':' : ''} ');
      return;
    }
    final marker = _style('◇', _cyan);
    final styledLabel = _style(label, _bold);
    final styledSuffix = _style(suffix, _dim);
    prompt.write('$marker $styledLabel$styledSuffix${colon ? ':' : ''} ');
  }

  void _writeError(String message) {
    if (!styled) {
      prompt.writeln(message);
      return;
    }
    final marker = _style('!', '$_bold$_yellow');
    prompt.writeln('$marker ${_style(message, _yellow)}');
  }

  String _style(String value, String style) {
    final supportsAnsi =
        prompt is AnsiInitPrompt &&
        (prompt as AnsiInitPrompt).supportsAnsiEscapes;
    return styled && supportsAnsi ? '$style$value$_reset' : value;
  }
}

/// The owner cancelled interactive initialization before any write.
class InitCancelledException implements Exception {
  /// Creates the cancellation signal.
  const InitCancelledException();
}

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _dim = '\x1B[2m';
const _yellow = '\x1B[33m';
const _cyan = '\x1B[36m';
