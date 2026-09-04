import 'package:meta/meta.dart';

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';

/// L10n-specific action descriptor with family-level metadata.
@immutable
final class L10nActionDescriptor {
  const L10nActionDescriptor({
    required this.familyId,
    required this.selectedKeys,
    required this.footprint,
    required this.hasExternalConsumerExposure,
  });

  final String familyId;
  final Set<String> selectedKeys;
  final MutationFootprint footprint;
  final bool hasExternalConsumerExposure;

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
