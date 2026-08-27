import 'dart:io';

import 'formatters/quarantine_formatter.dart';

/// Shell syntax used only to display an already-structured argv command.
enum ShellDialect {
  /// POSIX-compatible shells such as zsh.
  posix,

  /// PowerShell.
  powerShell;

  /// The host shell convention used for human-facing suggestions.
  static ShellDialect get host =>
      Platform.isWindows ? ShellDialect.powerShell : ShellDialect.posix;
}

/// An immutable exact command that can be rendered for one supported shell.
///
/// The command stores raw argv first. Rendering is deliberately a final display
/// operation so untrusted values never become an interpolated shell command.
final class SuggestedCommand {
  /// Creates a command with a dynamically supplied executable.
  SuggestedCommand(String executable, List<String> arguments)
    : _isFixedProductExecutable = false,
      executable = _validated(executable, 'executable'),
      arguments = List<String>.unmodifiable(
        arguments.map((argument) => _validated(argument, 'argument')),
      );

  SuggestedCommand._flutterPruner(List<String> arguments)
    : _isFixedProductExecutable = true,
      executable = _flutterPrunerExecutable,
      arguments = List<String>.unmodifiable(
        arguments.map((argument) => _validated(argument, 'argument')),
      );

  /// Creates a command for the fixed Flutter Pruner executable.
  ///
  /// This is the only explicitly encoded executable rendered without shell
  /// quotes. Every dynamic executable uses the same quoting as an argument.
  factory SuggestedCommand.flutterPruner(List<String> arguments) =>
      SuggestedCommand._flutterPruner(arguments);

  static const _flutterPrunerExecutable = 'flutter_pruner';

  final bool _isFixedProductExecutable;

  /// Exact executable argv element.
  final String executable;

  /// Immutable exact argument elements, excluding [executable].
  final List<String> arguments;

  /// Immutable raw argv including the executable as element zero.
  List<String> get argv =>
      List<String>.unmodifiable([executable, ...arguments]);

  /// Whether every argv element can appear in a terminal command line.
  ///
  /// Callers must fall back to a terminal-safe JSON argv document when false.
  bool get isTerminalSafe => argv.every(_isTerminalSafe);

  /// Renders the exact argv for [dialect].
  String render(ShellDialect dialect) {
    final executable = _isFixedProductExecutable
        ? this.executable
        : _quote(this.executable, dialect);
    final invocation =
        !_isFixedProductExecutable && dialect == ShellDialect.powerShell
        ? ['&', executable]
        : [executable];
    return [
      ...invocation,
      for (final argument in arguments) _quote(argument, dialect),
    ].join(' ');
  }

  /// Renders a shell command when it is terminal-safe, otherwise one exact
  /// JSON argv document that must be invoked without a shell.
  String renderForTerminal(ShellDialect dialect) {
    if (isTerminalSafe) return render(dialect);
    return 'Exact action argv (JSON; invoke without a shell):\n'
        '${QuarantineFormatter.formatExactArgvJson(argv)}';
  }

  static String _validated(String value, String name) {
    if (value.contains('\u0000')) {
      throw ArgumentError.value(value, name, 'must not contain NUL');
    }
    return value;
  }

  static String _quote(String value, ShellDialect dialect) => switch (dialect) {
    ShellDialect.posix => "'${value.replaceAll("'", "'\"'\"'")}'",
    ShellDialect.powerShell => "'${value.replaceAll("'", "''")}'",
  };

  static bool _isTerminalSafe(String value) {
    for (final rune in value.runes) {
      if (rune <= 0x1f ||
          rune == 0x7f ||
          (rune >= 0x80 && rune <= 0x9f) ||
          rune == 0x061c ||
          rune == 0x200e ||
          rune == 0x200f ||
          rune == 0x2028 ||
          rune == 0x2029 ||
          (rune >= 0x202a && rune <= 0x202e) ||
          (rune >= 0x2066 && rune <= 0x2069)) {
        return false;
      }
    }
    return true;
  }
}
