import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../quarantine/quarantine_manager.dart';
import '../project_command_support.dart';

/// Manages quarantine directories.
///
/// Provides subcommands to list, inspect, and clean quarantines.
class QuarantineCommand extends Command<int> {
  /// Creates the quarantine command.
  QuarantineCommand() {
    addSubcommand(_ListCommand());
    addSubcommand(_CleanCommand());
    addSubcommand(_InspectCommand());
  }

  @override
  String get name => 'quarantine';

  @override
  String get description => 'Manage quarantine directories.';

  @override
  List<String> get aliases => ['q'];
}

class _ListCommand extends Command<int> {
  _ListCommand() {
    argParser.addOption(
      'quarantine',
      help:
          'Quarantine directory. Defaults to .flutter_pruner/quarantine in '
          'the selected project.',
    );
    addProjectOption(argParser);
  }

  @override
  String get name => 'list';

  @override
  String get description => 'List all quarantines.';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isNotEmpty) {
      stderr.writeln('Error: quarantine list does not accept positional args.');
      return 64;
    }
    final workspace = _resolveWorkspace(args);
    if (workspace == null) return 64;
    final quarantineManager = QuarantineManager(workspace.projectRoot);
    late final List<QuarantineInfo> quarantines;
    try {
      quarantines = await _listQuarantines(
        quarantineManager,
        workspace,
        args.option('quarantine'),
      );
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    }

    if (quarantines.isEmpty) {
      stdout.writeln('No quarantines found.');
      return 0;
    }

    stdout.writeln('Quarantines (${quarantines.length}):');
    stdout.writeln('');

    for (final q in quarantines) {
      stdout.writeln('  ${q.runId}');
      stdout.writeln('    Created: ${_formatTimestamp(q.timestamp)}');
      stdout.writeln('    Entries: ${q.entryCount}');
      stdout.writeln('    Path: ${q.path}');
      stdout.writeln('');
    }

    return 0;
  }

  String _formatTimestamp(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }
}

class _CleanCommand extends Command<int> {
  _CleanCommand() {
    argParser
      ..addFlag('all', negatable: false, help: 'Remove all quarantines.')
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory. Defaults to .flutter_pruner/quarantine in '
            'the selected project.',
      );
    addProjectOption(argParser);
  }

  @override
  String get name => 'clean';

  @override
  String get description => 'Remove quarantine directories.';

  @override
  String get invocation => '${super.invocation} [<run-id> | --all]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final cleanAll = args.flag('all');
    final workspace = _resolveWorkspace(args);
    if (workspace == null) return 64;
    final quarantineManager = QuarantineManager(workspace.projectRoot);
    final explicitBase = args.option('quarantine');

    if (cleanAll) {
      if (args.rest.isNotEmpty) {
        stderr.writeln('Error: do not combine --all with a quarantine run ID.');
        return 64;
      }
      // Confirm before deleting all
      stdout.write('Remove all quarantines? (y/N): ');
      final response = stdin.readLineSync();
      if (response?.toLowerCase() != 'y') {
        stdout.writeln('Cancelled.');
        return 0;
      }
    } else if (args.rest.length != 1) {
      stderr.writeln('Error: run-id required, or use --all.');
      stderr.writeln('');
      stderr.writeln('Usage: $invocation');
      return 1;
    }

    late final ProjectOperationLock operationLock;
    try {
      operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: cleanAll ? 'quarantine-clean-all' : 'quarantine-clean',
      );
    } on ProjectOperationLockException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }
    try {
      if (cleanAll) {
        return await _cleanAllLocked(
          quarantineManager: quarantineManager,
          workspace: workspace,
          explicitBase: explicitBase,
        );
      }
      return await _cleanOneLocked(
        quarantineManager: quarantineManager,
        workspace: workspace,
        explicitBase: explicitBase,
        runId: args.rest.first,
      );
    } finally {
      await operationLock.release();
    }
  }

  Future<int> _cleanAllLocked({
    required QuarantineManager quarantineManager,
    required ToolWorkspace workspace,
    required String? explicitBase,
  }) async {
    late final List<QuarantineInfo> quarantines;
    try {
      final bases = explicitBase == null
          ? _defaultQuarantineBases(workspace)
          : [workspace.resolveQuarantineDirectory(explicitBase)];
      quarantines = await quarantineManager.validateAndListCleanableQuarantines(
        quarantineBases: bases,
      );
      for (final quarantine in quarantines) {
        await quarantineManager.cleanQuarantine(
          runId: quarantine.runId,
          quarantineBase: p.dirname(quarantine.path),
        );
        stdout.writeln('Removed: ${quarantine.runId}');
      }
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on QuarantineException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }

    stdout.writeln('✓ Removed ${quarantines.length} quarantines.');
    return 0;
  }

  Future<int> _cleanOneLocked({
    required QuarantineManager quarantineManager,
    required ToolWorkspace workspace,
    required String? explicitBase,
    required String runId,
  }) async {
    try {
      QuarantineManager.validateRunId(runId);
      final quarantineDir = _locateQuarantine(workspace, explicitBase, runId);
      await quarantineManager.cleanQuarantine(
        runId: runId,
        quarantineBase: p.dirname(quarantineDir.path),
      );
      stdout.writeln('✓ Removed quarantine: $runId');
      return 0;
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on QuarantineException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }
  }
}

class _InspectCommand extends Command<int> {
  _InspectCommand() {
    argParser.addOption(
      'quarantine',
      help:
          'Quarantine directory. Defaults to .flutter_pruner/quarantine in '
          'the selected project.',
    );
    addProjectOption(argParser);
  }

  @override
  String get name => 'inspect';

  @override
  String get description => 'Show quarantine manifest details.';

  @override
  String get invocation => '${super.invocation} <run-id>';

  @override
  Future<int> run() async {
    final args = argResults!;

    if (args.rest.length != 1) {
      stderr.writeln('Error: run-id required.');
      stderr.writeln('');
      stderr.writeln('Usage: $invocation');
      return 1;
    }

    final runId = args.rest.first;
    final workspace = _resolveWorkspace(args);
    if (workspace == null) return 64;
    late final Directory quarantineDir;
    try {
      QuarantineManager.validateRunId(runId);
      quarantineDir = _locateQuarantine(
        workspace,
        args.option('quarantine'),
        runId,
      );
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on QuarantineException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }

    if (!quarantineDir.existsSync()) {
      stderr.writeln('Error: Quarantine not found: $runId');
      return 1;
    }

    // Read manifest
    final manifestFile = File(p.join(quarantineDir.path, 'manifest.json'));

    if (!manifestFile.existsSync()) {
      stderr.writeln('Error: Manifest not found in quarantine.');
      return 1;
    }

    final manifestContent = await manifestFile.readAsString();
    stdout.writeln('Quarantine: $runId');
    stdout.writeln('');
    stdout.writeln(manifestContent);

    return 0;
  }
}

ToolWorkspace? _resolveWorkspace(ArgResults args) {
  try {
    final workspace = resolveToolWorkspace(args);
    final explicitBase = args.option('quarantine');
    if (explicitBase != null) {
      workspace.resolveQuarantineDirectory(explicitBase);
    }
    return workspace;
  } on ProjectSelectionException catch (e) {
    stderr.writeln('Error: $e');
    return null;
  } on ToolWorkspaceException catch (e) {
    stderr.writeln('Error: $e');
    return null;
  }
}

List<Directory> _defaultQuarantineBases(ToolWorkspace workspace) => [
  workspace.resolveQuarantineDirectory(QuarantineManager.defaultQuarantineDir),
  workspace.resolveQuarantineDirectory(QuarantineManager.legacyQuarantineDir),
];

Directory _locateQuarantine(
  ToolWorkspace workspace,
  String? explicitBase,
  String runId,
) {
  if (explicitBase != null) {
    return Directory(
      p.join(workspace.resolveQuarantineDirectory(explicitBase).path, runId),
    );
  }

  final matches = [
    for (final base in _defaultQuarantineBases(workspace))
      Directory(p.join(base.path, runId)),
  ].where((directory) => directory.existsSync()).toList();
  if (matches.length > 1) {
    throw QuarantineException(
      'Ambiguous quarantine run $runId found in both default locations. '
      'Pass --quarantine to select one.',
    );
  }
  return matches.isEmpty
      ? Directory(p.join(_defaultQuarantineBases(workspace).first.path, runId))
      : matches.single;
}

Future<List<QuarantineInfo>> _listQuarantines(
  QuarantineManager manager,
  ToolWorkspace workspace,
  String? explicitBase,
) async {
  final bases = explicitBase == null
      ? _defaultQuarantineBases(workspace)
      : [workspace.resolveQuarantineDirectory(explicitBase)];
  final quarantines = <QuarantineInfo>[];
  for (final base in bases) {
    quarantines.addAll(
      await manager.listQuarantines(quarantineBase: base.path),
    );
  }
  quarantines.sort((a, b) => b.timestamp.compareTo(a.timestamp));
  return quarantines;
}
