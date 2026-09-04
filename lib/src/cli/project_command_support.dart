import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

import '../core/project/tool_workspace.dart';
import 'formatters/quarantine_formatter.dart';
import 'suggested_command.dart';

/// Registers the project selector shared by every project lifecycle command.
void addProjectOption(ArgParser parser) {
  parser.addOption(
    'project',
    abbr: 'p',
    help: 'Dart or Flutter project root; defaults to current directory',
  );
}

/// Resolves one selected project from `--project`, a legacy positional path,
/// or the current directory.
ToolWorkspace resolveToolWorkspace(
  ArgResults args, {
  String? positionalProjectPath,
}) {
  final option = args.option('project');
  if (option != null && positionalProjectPath != null) {
    throw const ProjectSelectionException(
      'Pass the project once, using either --project or [project-path].',
    );
  }
  final selected = option ?? positionalProjectPath ?? '.';
  final normalized = p.normalize(p.absolute(selected));
  final directory = Directory(normalized);
  if (!directory.existsSync()) {
    throw ProjectSelectionException('Directory not found: $selected');
  }
  final workspace = ToolWorkspace(directory);
  try {
    workspace.validateManagedLayout();
  } on ToolWorkspaceException catch (error) {
    throw ProjectSelectionException(error.message);
  }
  return workspace;
}

/// Returns a copyable lifecycle command scoped to [workspace].
///
/// Commands targeting the current directory stay concise; external project
/// selections retain an explicit path so the suggestion works from here.
String projectCommandFor(ToolWorkspace workspace, String command) {
  final current = p.normalize(p.absolute(Directory.current.path));
  final arguments = p.equals(current, workspace.projectRoot.path)
      ? [command]
      : [command, '--project', workspace.projectRoot.path];
  return SuggestedCommand.flutterPruner(
    arguments,
  ).renderForTerminal(ShellDialect.host);
}

/// Requires a real project configuration before analysis or mutation starts.
///
/// An explicit `--config` remains authoritative. Without it, the preferred
/// project-local config and then the legacy root-level config are accepted.
File requireProjectConfig(ToolWorkspace workspace, File? explicitConfig) {
  final selected = explicitConfig ?? workspace.discoveredConfigFile;
  if (selected.existsSync()) return selected;
  if (explicitConfig != null) {
    throw ProjectConfigPreflightException(
      'Configuration file not found: ${selected.path}',
    );
  }
  throw ProjectConfigPreflightException(
    'Flutter Pruner is not initialized for '
    '${QuarantineFormatter.terminalSafe(workspace.projectRoot.path)}. '
    'Run: ${projectCommandFor(workspace, 'init')}',
  );
}

/// The CLI project selection is invalid.
class ProjectSelectionException implements Exception {
  /// Creates a user-facing selection error.
  const ProjectSelectionException(this.message);

  /// Actionable error text.
  final String message;

  @override
  String toString() => message;
}

/// A lifecycle command cannot proceed without its required configuration.
class ProjectConfigPreflightException implements Exception {
  /// Creates an actionable configuration preflight error.
  const ProjectConfigPreflightException(this.message);

  /// Explanation suitable for CLI stderr.
  final String message;

  @override
  String toString() => message;
}
