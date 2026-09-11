import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';

/// L10n-specific action descriptor with family-level metadata.
@immutable
final class L10nActionDescriptor {
  /// Creates an action descriptor for one l10n family.
  const L10nActionDescriptor({
    required this.familyId,
    required this.selectedKeys,
    required this.footprint,
    required this.hasExternalConsumerExposure,
  });

  /// Identifier of the l10n family being mutated.
  final String familyId;

  /// Localization keys selected for removal.
  final Set<String> selectedKeys;

  /// Complete logical and physical scope of the mutation.
  final MutationFootprint footprint;

  /// Whether consumers outside the analyzed project may depend on the family.
  final bool hasExternalConsumerExposure;

  /// Risk scope assigned to this family-level action.
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
    Object.hashAll(selectedKeys),
    footprint,
    hasExternalConsumerExposure,
  );

  static bool _setEquals<T>(Set<T> a, Set<T> b) {
    if (a.length != b.length) return false;
    return a.every(b.contains);
  }
}
