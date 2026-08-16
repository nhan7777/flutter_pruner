import 'dart:io';

import 'package:args/command_runner.dart';

import '../verification/verification_runner.dart';
import '../version.dart';
import 'commands/apply_command.dart';
import 'commands/init_command.dart';
import 'commands/quarantine_command.dart';
import 'commands/rollback_command.dart';
import 'commands/scan_command.dart';
import 'init_prompt.dart';

/// Entry point for the `flutter_pruner` CLI.
class FlutterPrunerCommandRunner extends CommandRunner<int> {
  /// Creates the runner and registers all commands.
  FlutterPrunerCommandRunner({
    VerificationRunner Function(Directory)? verifierFactory,
    InitPrompt initPrompt = const StdioInitPrompt(),
    InitPrompt? applyPrompt,
  }) : super(
         'flutter_pruner',
         'Find unused assets, duplicate files and unreachable code in '
             'Flutter/Dart projects.',
       ) {
    argParser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show diagnostic output, including per-adapter timings.',
      )
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print the tool version and exit.',
      );

    addCommand(InitCommand(prompt: initPrompt));
    addCommand(ScanCommand());
    addCommand(
      ApplyCommand(
        verifierFactory: verifierFactory,
        prompt: applyPrompt ?? const StdioInitPrompt(),
      ),
    );
    addCommand(RollbackCommand(verifierFactory: verifierFactory));
    addCommand(QuarantineCommand());
  }

  @override
  Future<int> run(Iterable<String> args) async {
    try {
      final results = parse(args);
      if (results.flag('version')) {
        // ignore: avoid_print
        print('flutter_pruner $packageVersion');
        return 0;
      }
      return await runCommand(results) ?? 0;
    } on UsageException catch (e) {
      // Usage problems go to stderr with exit code 64 (EX_USAGE), so scripts
      // can tell "you invoked me wrong" apart from "the scan found problems".
      stderr.writeln(e);
      return 64;
    } catch (error) {
      stderr.writeln('Internal error: $error');
      return 70;
    }
  }
}
