import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';

/// L10n-specific action descriptor for family-level mutations.
///
/// Captures the l10n family identity, selected keys, and mutation footprint
/// for one atomic l10n removal batch. Always operates at family scope with
/// deterministic inverse proof.
@immutable
final class L10nActionDescriptor {
  const L10nActionDescriptor({
    required this.familyId,
    required this.selectedKeys,
    required this.footprint,
    required this.hasExternalConsumerExposure,
  });

  /// L10n family identifier (e.g., 'app_localizations').
  final String familyId;

  /// Localization keys being removed in this action.
  final Set<String> selectedKeys;

  /// Complete mutation footprint (ARB files + generated outputs).
  final MutationFootprint footprint;

  /// Whether external consumers might depend on these keys.
  ///
  /// - Application mode: always false (closed world)
  /// - Package-internal mode: true if package has external dependents
  /// - Package mode: true (open world, scan-only)
  final bool hasExternalConsumerExposure;

  /// L10n actions are always family-level bounded scope.
  ActionRiskScope get riskScope => ActionRiskScope.boundedFamily;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nActionDescriptor &&
          runtimeType == other.runtimeType &&
          familyId == other.familyId &&
          _setEquals(selectedKeys, other.selectedKeys) &&
          footprint == other.footprint &&
          hasExternalConsumerExposure == other.hasExternalConsumerExposure;

  @override
  int get hashCode => Object.hash(
        familyId,
        _setHashCode(selectedKeys),
        footprint,
        hasExternalConsumerExposure,
      );

  @override
  String toString() => 'L10nActionDescriptor('
      'family: $familyId, '
      'keys: ${selectedKeys.length}, '
      'externalExposure: $hasExternalConsumerExposure'
      ')';

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }

  static int _setHashCode<T>(Set<T> set) {
    return set.fold(0, (hash, element) => hash ^ element.hashCode);
  }
}
