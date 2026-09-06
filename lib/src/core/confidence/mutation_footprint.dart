import 'action_risk_scope.dart';

/// Exact logical findings + physical paths owned by an atomic mutation unit.
///
/// Captures the complete scope of changes a mutation will make, including
/// both the logical findings being addressed and the physical files affected.
final class MutationFootprint {
  /// Logical finding IDs owned by this atomic unit.
  final Set<String> findingIds;

  /// Physical file paths that will be mutated (relative to project root).
  final Set<String> physicalPaths;

  /// Action risk scope classification.
  final ActionRiskScope riskScope;

  /// Family identifier for family-level actions (null for single actions).
  final String? familyId;

  /// Creates a mutation footprint with its complete scope.
  const MutationFootprint({
    required this.findingIds,
    required this.physicalPaths,
    required this.riskScope,
    this.familyId,
  });

  /// Validates footprint constraints based on risk scope.
  void validate() {
    if (findingIds.isEmpty) {
      throw ArgumentError(
        'MutationFootprint must have at least one finding ID',
      );
    }

    if (physicalPaths.isEmpty) {
      throw ArgumentError(
        'MutationFootprint must have at least one physical path',
      );
    }

    switch (riskScope) {
      case ActionRiskScope.boundedFamily:
        if (familyId == null) {
          throw ArgumentError('boundedFamily scope requires non-null familyId');
        }
      case ActionRiskScope.boundedSingle:
        if (findingIds.length != 1) {
          throw ArgumentError(
            'boundedSingle scope requires exactly one finding ID, got ${findingIds.length}',
          );
        }
      case ActionRiskScope.openEnded:
        // No additional constraints for open-ended scope
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
  int get hashCode => Object.hash(
    _setHashCode(findingIds),
    _setHashCode(physicalPaths),
    riskScope,
    familyId,
  );

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  static int _setHashCode<T>(Set<T> set) {
    return set.fold(0, (hash, element) => hash ^ element.hashCode);
  }
}
