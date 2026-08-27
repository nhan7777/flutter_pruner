import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/apply_command.dart';

/// Test-only process entrypoint for the existing ApplyCommand backend seam.
///
/// It exercises the production runner's internal-error rendering without
/// manufacturing a transcript or changing production command wiring.
Future<void> main(List<String> arguments) async {
  exit(
    await FlutterPrunerCommandRunner(
      applyCommandFactory: () => ApplyCommand(
        projectLoader:
            (
              directory, {
              configFile,
              additionalExcludedPaths = const <String>[],
            }) async => throw StateError('C3 injected apply loader failure'),
      ),
    ).run(arguments),
  );
}
