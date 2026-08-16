import 'analyzer_adapter.dart';
import 'asset/asset_adapter.dart';
import 'dart/dart_adapter.dart';
import 'duplicate/duplicate_adapter.dart';

final Map<String, Type> _reservedAdapterTypes = {
  'assets': AssetAdapter,
  'duplicates': DuplicateAdapter,
  'dart': DartAdapter,
};

const Map<String, String> _reservedRuleOwners = {
  'PRN-ASSET-001': 'assets',
  'PRN-DUP-001': 'duplicates',
  'PRN-DART-001': 'dart',
  'PRN-DART-002': 'dart',
};

/// Resolves and orders the adapters a scan will run.
///
/// ## Adding an adapter
///
/// Add it to the [builtIn] initializer with a complete
/// [AnalyzerAdapter.reportDefinition].
/// The registry validates both contracts before it selects or orders adapters.
///
/// ```dart
/// static final List<AnalyzerAdapter> builtIn = List.unmodifiable([
///   const AssetAdapter(),
///   const MyNewAdapter(), // <- here
/// ]);
/// ```
class AdapterRegistry {
  AdapterRegistry._();

  /// Adapters shipped with the tool, in registration order.
  ///
  /// Phase 1A adds `AssetAdapter`; 1B adds duplicates and Dart; V2 adds routes,
  /// DI and localization — see ROADMAP.md.
  static final List<AnalyzerAdapter> builtIn = List.unmodifiable(
    const <AnalyzerAdapter>[AssetAdapter(), DuplicateAdapter(), DartAdapter()],
  );

  /// Adapters to run for a scan, topologically ordered by [AnalyzerAdapter.dependsOn].
  ///
  /// Pass [only] to restrict to specific ids, or [exclude] to drop some.
  /// Throws [StateError] on an unknown dependency or a dependency cycle.
  static List<AnalyzerAdapter> resolve({
    Set<String>? only,
    Set<String> exclude = const {},
    List<AnalyzerAdapter>? adapters,
  }) {
    final available = adapters ?? builtIn;
    _validateAvailable(available);

    if (only != null) {
      final availableIds = available.map((adapter) => adapter.id).toSet();
      final unknownIds = only.where((id) => !availableIds.contains(id)).toList()
        ..sort();
      if (unknownIds.isNotEmpty) {
        throw StateError(
          'Unknown adapter id${unknownIds.length == 1 ? '' : 's'} requested '
          'by --only: ${unknownIds.join(', ')}.',
        );
      }
    }

    final selected = available
        .where((a) {
          if (exclude.contains(a.id)) return false;
          if (only != null && !only.contains(a.id)) return false;
          return true;
        })
        .toList(growable: false);

    return _topologicalSort(selected);
  }

  static void _validateAvailable(List<AnalyzerAdapter> available) {
    final adapterIds = <String>{};
    final schemeOwners = <String, String>{};
    final ruleOwners = <String, String>{};

    for (final adapter in available) {
      if (!adapterIds.add(adapter.id)) {
        throw StateError('Duplicate adapter id "${adapter.id}" is registered.');
      }
      final reservedType = _reservedAdapterTypes[adapter.id];
      if (reservedType != null && adapter.runtimeType != reservedType) {
        throw StateError(
          'Adapter id "${adapter.id}" is reserved for the core '
          '$reservedType implementation.',
        );
      }

      final definition = adapter.reportDefinition;
      definition.validate(adapterId: adapter.id, displayName: adapter.name);

      for (final scheme in adapter.findingNodeSchemes) {
        final owner = schemeOwners[scheme];
        if (owner != null) {
          throw StateError(
            'Finding node scheme "$scheme" is claimed by both adapters '
            '"$owner" and "${adapter.id}".',
          );
        }
        schemeOwners[scheme] = adapter.id;
      }

      for (final finding in definition.findings) {
        final reservedOwner = _reservedRuleOwners[finding.ruleId];
        if (reservedOwner != null && adapter.id != reservedOwner) {
          throw StateError(
            'Rule id "${finding.ruleId}" is reserved for adapter '
            '"$reservedOwner".',
          );
        }
        final owner = ruleOwners[finding.ruleId];
        if (owner != null) {
          throw StateError(
            'Rule id "${finding.ruleId}" is owned by both adapters "$owner" '
            'and "${adapter.id}".',
          );
        }
        ruleOwners[finding.ruleId] = adapter.id;
      }
    }
  }

  static List<AnalyzerAdapter> _topologicalSort(List<AnalyzerAdapter> input) {
    final byId = {for (final a in input) a.id: a};
    final sorted = <AnalyzerAdapter>[];
    final visiting = <String>{};
    final visited = <String>{};

    void visit(AnalyzerAdapter adapter, List<String> path) {
      if (visited.contains(adapter.id)) return;
      if (!visiting.add(adapter.id)) {
        throw StateError(
          'Adapter dependency cycle: ${[...path, adapter.id].join(' -> ')}',
        );
      }

      for (final depId in adapter.dependsOn) {
        final dep = byId[depId];
        if (dep == null) {
          throw StateError(
            'Adapter "${adapter.id}" depends on "$depId", which is not '
            'registered or was excluded from this run.',
          );
        }
        visit(dep, [...path, adapter.id]);
      }

      visiting.remove(adapter.id);
      visited.add(adapter.id);
      sorted.add(adapter);
    }

    for (final adapter in input) {
      visit(adapter, const []);
    }

    return sorted;
  }
}
