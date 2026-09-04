import 'package:meta/meta.dart';

import 'action_risk_scope.dart';

/// Complete mutation footprint for one atomic action unit.
///
/// Captures logical finding IDs, physical file paths, risk scope classification,
/// and optional family identity for family-level actions. Used to assess
/// confidence and coordinate reversible transactions.
@immutable
final class MutationFootprint {
  /// Creates an immutable mutation footprint.
  const MutationFootprint({
    required this.findingIds,
    required this.physicalPaths,
    required this.riskScope,
    this.familyId,
  });

  /// Logical finding IDs owned by this atomic unit.
  ///
  /// These are canonical node IDs from the reachability graph.
  final Set<String> findingIds;

  /// Physical file paths that will be mutated.
  ///
  /// Includes source files, generated outputs, and any companion files.
  /// Paths are relative to project root.
  final Set<String> physicalPaths;

  /// Action risk scope classification.
  final ActionRiskScope riskScope;

  /// Family identifier for family-level actions.
  ///
  /// Required when [riskScope] is [ActionRiskScope.boundedFamily].
  /// Null for single-file and open-ended actions.
  final String? familyId;

  /// Validates footprint constraints.
  ///
  /// Throws [ArgumentError] if:
  /// - [riskScope] is [ActionRiskScope.boundedFamily] but [familyId] is null
  /// - [riskScope] is not [ActionRiskScope.boundedFamily] but [familyId] is non-null
  /// - [riskScope] is [ActionRiskScope.boundedSingle] but [findingIds] has more than one entry
  /// - [findingIds] is empty
  /// - [physicalPaths] is empty
  void validate() {
    if (findingIds.isEmpty) {
      throw ArgumentError('findingIds cannot be empty');
    }
    if (physicalPaths.isEmpty) {
      throw ArgumentError('physicalPaths cannot be empty');
    }
    if (riskScope == ActionRiskScope.boundedFamily && familyId == null) {
      throw ArgumentError(
        'familyId is required when riskScope is boundedFamily',
      );
    }
    if (riskScope != ActionRiskScope.boundedFamily && familyId != null) {
      throw ArgumentError(
        'familyId must be null when riskScope is not boundedFamily',
      );
    }
    if (riskScope == ActionRiskScope.boundedSingle && findingIds.length > 1) {
      throw ArgumentError(
        'boundedSingle scope must have exactly one finding ID, '
        'got ${findingIds.length}',
      );
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MutationFootprint &&
          runtimeType == other.runtimeType &&
          _setEquals(findingIds, other.findingIds) &&
          _setEquals(physicalPaths, other.physicalPaths) &&
          riskScope == other.riskScope &&
          familyId == other.familyId;

  @override
  int get hashCode => Object.hash(
        _setHashCode(findingIds),
        _setHashCode(physicalPaths),
        riskScope,
        familyId,
      );

  @override
  String toString() => 'MutationFootprint('
      'scope: ${riskScope.name}, '
      'findings: ${findingIds.length}, '
      'paths: ${physicalPaths.length}'
      '${familyId != null ? ', family: $familyId' : ''}'
      ')';

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  static int _setHashCode<T>(Set<T> set) {
    return set.fold(0, (hash, element) => hash ^ element.hashCode);
  }
}
