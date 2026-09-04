import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/apply_command.dart';

/// Test-only process entrypoint that drives ApplyCommand's existing snapshot
/// drift seam; the command and its safe-stop renderer remain production code.
Future<void> main(List<String> arguments) async {
  var deleted = false;
  exit(
    await FlutterPrunerCommandRunner(
      applyCommandFactory: () => ApplyCommand(
        sourceSnapshotFirstReadHookForTesting: (source) {
          if (deleted || source.uri.pathSegments.last != 'helper.dart') return;
          deleted = true;
          source.deleteSync();
        },
      ),
    ).run(arguments),
  );
}
