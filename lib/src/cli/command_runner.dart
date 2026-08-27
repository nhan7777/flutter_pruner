import 'dart:io';

import 'package:args/command_runner.dart';

import '../core/process/managed_process_runner.dart';
import '../verification/verification_runner.dart';
import '../version.dart';
import 'cli_exit_code.dart';
import 'cli_signal_coordinator.dart';
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
    CliSignalCoordinator? signalCoordinator,
    VerificationRunner Function(Directory)? verifierFactory,
    InitPrompt initPrompt = const StdioInitPrompt(),
    InitPrompt? applyPrompt,
    ScanCommand Function()? scanCommandFactory,
    ApplyCommand Function()? applyCommandFactory,
    QuarantineCommand Function()? quarantineCommandFactory,
    ManagedProcessStarter? analyzerProcessStarter,
    ManagedProcessTreeTerminator? analyzerProcessTreeTerminator,
  }) : _signalCoordinator =
           signalCoordinator ?? createDefaultCliSignalCoordinator(),
       super(
         'flutter_pruner',
         'Find unused assets, duplicate files and unreachable code in '
             'Flutter/Dart projects',
       ) {
    argParser
      ..addFlag(
        'verbose',
        abbr: 'v',
        negatable: false,
        help: 'Show diagnostic output, including per-adapter timings',
      )
      ..addFlag(
        'version',
        negatable: false,
        help: 'Print tool version and exit',
      );

    final processCancellation = _signalCoordinator.processCancellation;
    addCommand(InitCommand(prompt: initPrompt));
    addCommand(
      (scanCommandFactory ??
          () => ScanCommand(
            signalCoordinator: _signalCoordinator,
            processCancellation: processCancellation,
            analyzerProcessStarter: analyzerProcessStarter,
            analyzerProcessTreeTerminator: analyzerProcessTreeTerminator,
          ))(),
    );
    addCommand(
      (applyCommandFactory ??
          () => ApplyCommand(
            verifierFactory: verifierFactory,
            prompt: applyPrompt ?? const StdioInitPrompt(),
            signalCoordinator: _signalCoordinator,
            processCancellation: processCancellation,
            analyzerProcessStarter: analyzerProcessStarter,
            analyzerProcessTreeTerminator: analyzerProcessTreeTerminator,
          ))(),
    );
    addCommand(
      RollbackCommand(
        verifierFactory: verifierFactory,
        processCancellation: processCancellation,
      ),
    );
    addCommand((quarantineCommandFactory ?? QuarantineCommand.new)());
  }

  final CliSignalCoordinator _signalCoordinator;

  @override
  String get usageFooter => '''Examples:
  flutter_pruner init
  flutter_pruner scan
  flutter_pruner scan --format json --output scan.json
  flutter_pruner apply --dry-run
  flutter_pruner quarantine list

Filesystem effects:
  init writes configuration and .gitignore
  scan and apply --dry-run may persist tool state or reports
  Only help and version are filesystem-read-only''';

  @override
  Future<int> run(Iterable<String> args) =>
      _signalCoordinator.guard(() => _runGuarded(args));

  Future<int> _runGuarded(Iterable<String> args) async {
    try {
      final rawArgs = args.toList(growable: false);
      final requestedHelp = _requestedHelp(rawArgs);
      if (requestedHelp != null) {
        stdout.writeln(_wrapHelpForColumns(requestedHelp));
        return CliExitCode.success;
      }
      final results = parse(rawArgs);
      if (results.flag('version')) {
        // ignore: avoid_print
        print('flutter_pruner $packageVersion');
        return CliExitCode.success;
      }
      return await runCommand(results) ?? CliExitCode.success;
    } on UsageException catch (e) {
      // Usage problems go to stderr with exit code 64 (EX_USAGE), so scripts
      // can tell "you invoked me wrong" apart from "the scan found problems".
      stderr.writeln('Error: ${e.message}\n\n${e.usage}');
      return CliExitCode.usage;
    } catch (error) {
      stderr.writeln('Internal error: $error');
      return CliExitCode.internal;
    }
  }

  String? _requestedHelp(List<String> args) {
    if (args.isEmpty ||
        (args.length == 1 &&
            (args.single == '--help' || args.single == '-h'))) {
      return usage;
    }
    if (args.first == 'help') {
      return _usageForPath(args.skip(1).toList(growable: false));
    }
    if (args.last == '--help' || args.last == '-h') {
      return _usageForPath(args.sublist(0, args.length - 1));
    }
    if (args.length == 1 &&
        (args.single == 'quarantine' || args.single == 'q')) {
      return commands['quarantine']!.usage;
    }
    return null;
  }

  String? _usageForPath(List<String> path) {
    if (path.isEmpty) return usage;
    final first = commands[path.first];
    if (first == null) return null;
    Command<int> command = first;
    for (final segment in path.skip(1)) {
      final child = command.subcommands[segment];
      if (child == null) return null;
      command = child;
    }
    return command.usage;
  }

  String _wrapHelpForColumns(String usage) {
    final columns = int.tryParse(Platform.environment['COLUMNS'] ?? '');
    if (columns == null || columns < 20) return usage;
    return usage
        .split('\n')
        .expand((line) => _wrapHelpLine(line, columns))
        .join('\n');
  }

  Iterable<String> _wrapHelpLine(String line, int columns) sync* {
    if (line.runes.length <= columns || line.trim().isEmpty) {
      yield line;
      return;
    }
    if (line.trim().runes.length <= columns) {
      yield line.trim();
      return;
    }
    final sourceIndentation = RegExp(r'^\s*').firstMatch(line)!.group(0)!;
    final indentation = sourceIndentation.runes.length >= columns
        ? '  '
        : sourceIndentation;
    final words = line.trim().split(RegExp(r'\s+'));
    var current = indentation;
    for (final word in words) {
      final candidate = current.trim().isEmpty
          ? '$indentation$word'
          : '$current $word';
      if (current.trim().isEmpty && candidate.runes.length > columns) {
        current = word;
        continue;
      }
      if (current.trim().isNotEmpty && candidate.runes.length > columns) {
        yield current;
        current = '$indentation$word';
      } else {
        current = candidate;
      }
    }
    yield current;
  }
}
