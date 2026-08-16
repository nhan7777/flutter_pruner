import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The only verifier output formats whose nonzero exits can be compared.
enum VerificationOutputParserKind {
  /// No trustworthy, command-bound completion contract is available.
  opaque,

  /// Flutter or Dart's standard human-readable analyzer output.
  humanAnalyzer,

  /// Flutter or Dart's compact test progress output.
  compactTest,
}

/// One required verifier process, represented without shell interpolation.
class VerificationCommand {
  /// Creates a verifier command.
  factory VerificationCommand({
    required String id,
    required String executable,
    required List<String> arguments,
  }) => VerificationCommand._(
    id: id,
    executable: executable,
    arguments: List<String>.unmodifiable(arguments),
  );

  const VerificationCommand._({
    required this.id,
    required this.executable,
    required this.arguments,
  });

  /// Stable identifier used to compare baseline and candidate results.
  final String id;

  /// Executable passed directly to `Process.run`.
  final String executable;

  /// Arguments passed directly to `Process.run`.
  final List<String> arguments;

  /// Output contract derived from this exact executable and argv shape.
  VerificationOutputParserKind get parserKind {
    final executableName = executable
        .replaceAll('\\', '/')
        .split('/')
        .last
        .toLowerCase()
        .replaceFirst(RegExp(r'\.(?:exe|bat|cmd)$'), '');
    final commandIndex = switch (executableName) {
      'dart' || 'flutter' => 0,
      'fvm'
          when arguments.isNotEmpty &&
              const {'dart', 'flutter'}.contains(arguments.first) =>
        1,
      _ => -1,
    };
    if (commandIndex < 0 || arguments.length <= commandIndex) {
      return VerificationOutputParserKind.opaque;
    }
    return switch (arguments[commandIndex]) {
      'analyze' => VerificationOutputParserKind.humanAnalyzer,
      'test' => VerificationOutputParserKind.compactTest,
      _ => VerificationOutputParserKind.opaque,
    };
  }
}

/// Exact set of commands every mutation transaction must pass.
class VerificationPolicy {
  /// Creates a verification policy.
  factory VerificationPolicy({required List<VerificationCommand> commands}) =>
      VerificationPolicy._(
        commands: List<VerificationCommand>.unmodifiable(commands),
      );

  const VerificationPolicy._({required this.commands});

  /// Default Flutter package verification used when no project override exists.
  static const flutterDefault = VerificationPolicy._(
    commands: [
      VerificationCommand._(
        id: 'flutter-analyze',
        executable: 'flutter',
        arguments: ['analyze', '--fatal-infos'],
      ),
      VerificationCommand._(
        id: 'flutter-test',
        executable: 'flutter',
        arguments: ['test'],
      ),
    ],
  );

  /// Required commands in execution order.
  final List<VerificationCommand> commands;

  /// Stable IDs required in every baseline/candidate/rollback result.
  List<String> get requiredStepIds =>
      List.unmodifiable(commands.map((command) => command.id));

  /// Parser contracts for [requiredStepIds], in the same order.
  List<VerificationOutputParserKind> get requiredParserKinds =>
      List.unmodifiable(commands.map((command) => command.parserKind));

  /// Content-derived identity used to reject mismatched verification runs.
  String get hash {
    final canonical = commands
        .map(
          (command) => {
            'id': command.id,
            'executable': command.executable,
            'arguments': command.arguments,
            'parserKind': command.parserKind.name,
          },
        )
        .toList();
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }
}
