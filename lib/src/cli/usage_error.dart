import 'package:args/command_runner.dart';

import '../adapters/registry.dart';

/// Builds a usage error from the command that received the invalid argv.
///
/// Rendering remains owned by the command runner, which keeps every
/// usage failure on stderr with the same exit code and the command's actual
/// invocation and options.
UsageException commandUsageError(Command<int> command, String message) =>
    UsageException(message, command.usage);

/// Rejects unknown adapter ids without loading a project or creating a report.
void validateRequestedAdapterIds(Set<String> requestedIds) {
  if (requestedIds.isEmpty) return;
  final knownIds = AdapterRegistry.builtIn.map((adapter) => adapter.id).toSet();
  final unknownIds = requestedIds.where((id) => !knownIds.contains(id)).toList()
    ..sort();
  if (unknownIds.isNotEmpty) {
    throw UnknownAdapterIdUsageException(unknownIds);
  }
}

/// A user-requested adapter id is not registered by this CLI build.
final class UnknownAdapterIdUsageException implements Exception {
  /// Creates an error for the rejected ids.
  const UnknownAdapterIdUsageException(this.ids);

  /// Unknown ids in deterministic order.
  final List<String> ids;

  /// Public wording names the actual adapter-selection option.
  String get message =>
      'Unknown adapter id${ids.length == 1 ? '' : 's'} requested by --adapter: '
      '${ids.join(', ')}.';
}
