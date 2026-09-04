import 'package:meta/meta.dart';

import 'action_risk_scope.dart';

/// Exact logical findings and physical paths owned by an atomic mutation unit.
///
/// Separates the logical finding identity (what unused code was detected) from
/// the physical mutation footprint (which files will be edited). A single
/// logical finding may span multiple physical files when generated outputs are
/// included (e.g., l10n ARB family + generated Dart files).
@immutable
final class MutationFootprint {
  /// Logical finding IDs owned by this atomic unit.
  ///
  /// These are the canonical node IDs from the reachability graph that this
  /// mutation operation addresses. For family-level actions, multiple findings
  /// may be grouped into one atomic unit.
  final Set<String> findingIds;

  /// Physical file paths (relative to project root) that will be mutated.
  ///
  /// Includes both source files (ARB, Dart declarations) and any mechanically
  /// derived outputs (generated Dart files). The complete set must be
  /// enumerable at planning time.
  final Set<String> physicalPaths;

  /// Action risk scope classification.
  final ActionRiskScope riskScope;

  /// Family identifier for family-level actions.
  ///
  /// Required when [riskScope] is [ActionRiskScope.boundedFamily].
  /// Null for single-file or open-ended actions.
  final String? familyId;

  const MutationFootprint({
    required this.findingIds,
    required this.physicalPaths,
    required this.riskScope,
    this.familyId,
  });

  /// Validates the footprint constraints.
  ///
  /// Throws [ArgumentError] if:
  /// - [findingIds] is empty
  /// - [physicalPaths] is empty
  /// - [riskScope] is [ActionRiskScope.boundedFamily] but [familyId] is null
  /// - [riskScope] is [ActionRiskScope.boundedSingle] but [findingIds] has
  ///   more than one entry
  void validate() {
    if (findingIds.isEmpty) {
      throw ArgumentError('findingIds cannot be empty');
    }
    if (physicalPaths.isEmpty) {
      throw ArgumentError('physicalPaths cannot be empty');
    }

    switch (riskScope) {
      case ActionRiskScope.boundedFamily:
        if (familyId == null) {
          throw ArgumentError(
            'familyId is required for boundedFamily risk scope',
          );
        }
      case ActionRiskScope.boundedSingle:
        if (findingIds.length > 1) {
          throw ArgumentError(
            'boundedSingle scope must have exactly one finding ID, '
            'got ${findingIds.length}',
          );
        }
      case ActionRiskScope.openEnded:
        // No additional constraints for open-ended actions
        break;
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
  int get hashCode =>
      Object.hash(
        _setHashCode(findingIds),
        _setHashCode(physicalPaths),
        riskScope,
        familyId,
      );

  @override
  String toString() => 'MutationFootprint('
      'findings: ${findingIds.length}, '
      'paths: ${physicalPaths.length}, '
      'scope: $riskScope'
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
