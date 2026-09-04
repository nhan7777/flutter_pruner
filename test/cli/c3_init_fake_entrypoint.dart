import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/init_prompt.dart';

/// Test-only process entrypoint for deterministic interactive-init transcripts.
///
/// The production prompt correctly rejects pipe-backed stdin as non-interactive;
/// this keeps a real process while making the prompt boundary explicit.
Future<void> main(List<String> arguments) async {
  final prompt = _DeterministicInitPrompt(
    Platform.environment['C3_INIT_MODE'] == 'cancel'
        ? const <String?>[null]
        : const <String?>['', '', '', '', '', ''],
  );
  exit(await FlutterPrunerCommandRunner(initPrompt: prompt).run(arguments));
}

final class _DeterministicInitPrompt implements InitPrompt {
  _DeterministicInitPrompt(List<String?> responses)
    : _responses = List<String?>.of(responses);

  final List<String?> _responses;

  @override
  bool get isInteractive => true;

  @override
  String? readLine() => _responses.isEmpty ? null : _responses.removeAt(0);

  @override
  void write(String value) => stdout.write(value);

  @override
  void writeln([String value = '']) => stdout.writeln(value);
}
