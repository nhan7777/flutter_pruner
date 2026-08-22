import 'package:collection/collection.dart';

import 'execution_target.dart';

export 'execution_target.dart' show BuildTarget;

/// The build configurations under which an edge or root applies.
///
/// Reachability is **not** a single global question. The same source can have
/// different reachable sets per platform, flavor, entrypoint and set of
/// `--dart-define` values, because `bool.fromEnvironment` and
/// `String.fromEnvironment` are const: the compiler folds them and drops
/// const-false branches *before* tree shaking runs.
///
/// A node is only globally dead when it is unreachable under **every**
/// configured target. Getting this wrong is the main route to a false `SAFE`.
///
/// An empty condition means "applies to all targets" — the common case for
/// ordinary Dart references.
///
/// See also: https://api.dart.dev/stable/dart-core/bool/bool.fromEnvironment.html
class BuildCondition {
  /// Creates a build condition. Empty sets mean "unconstrained".
  ///
  /// The supplied collections are snapshotted. Conditions are used as part of
  /// edge equality and hash codes, so retaining a caller-owned mutable
  /// collection here could corrupt the graph's edge set after insertion.
  factory BuildCondition({
    Set<String> platforms = const {},
    Set<String> flavors = const {},
    Set<String> entrypoints = const {},
    Map<String, String> dartDefines = const {},
    Set<BuildTarget> exactTargets = const {},
    Set<AuxiliaryExecutionTarget> exactAuxiliaryTargets = const {},
  }) => BuildCondition._(
    platforms: Set<String>.unmodifiable(platforms),
    flavors: Set<String>.unmodifiable(flavors),
    entrypoints: Set<String>.unmodifiable(entrypoints),
    dartDefines: Map<String, String>.unmodifiable(dartDefines),
    exactTargets: Set<BuildTarget>.unmodifiable(
      exactTargets.map(BuildTarget.snapshot),
    ),
    exactAuxiliaryTargets: Set<AuxiliaryExecutionTarget>.unmodifiable(
      exactAuxiliaryTargets,
    ),
  );

  /// Creates a condition for one complete configured target identity.
  factory BuildCondition.forTarget(BuildTarget target) =>
      BuildCondition(exactTargets: {target});

  /// Creates a condition for one complete auxiliary target identity.
  factory BuildCondition.forAuxiliaryTarget(AuxiliaryExecutionTarget target) =>
      BuildCondition(exactAuxiliaryTargets: {target});

  const BuildCondition._({
    required this.platforms,
    required this.flavors,
    required this.entrypoints,
    required this.dartDefines,
    required this.exactTargets,
    required this.exactAuxiliaryTargets,
  });

  /// A condition that holds for every target.
  static const BuildCondition unconditional = BuildCondition._(
    platforms: <String>{},
    flavors: <String>{},
    entrypoints: <String>{},
    dartDefines: <String, String>{},
    exactTargets: <BuildTarget>{},
    exactAuxiliaryTargets: <AuxiliaryExecutionTarget>{},
  );

  /// Platforms this applies to (`android`, `ios`, `web`, ...). Empty means all.
  final Set<String> platforms;

  /// Flavors this applies to. Empty means all.
  final Set<String> flavors;

  /// Entrypoint paths this applies to. Empty means all.
  final Set<String> entrypoints;

  /// Required `--dart-define` key/value pairs.
  ///
  /// The condition only holds for targets whose defines match every entry.
  final Map<String, String> dartDefines;

  /// Exact configured execution targets this condition applies to.
  final Set<BuildTarget> exactTargets;

  /// Exact auxiliary execution targets this condition applies to.
  final Set<AuxiliaryExecutionTarget> exactAuxiliaryTargets;

  /// Whether this condition places no restriction at all.
  bool get isUnconditional =>
      platforms.isEmpty &&
      flavors.isEmpty &&
      entrypoints.isEmpty &&
      dartDefines.isEmpty &&
      exactTargets.isEmpty &&
      exactAuxiliaryTargets.isEmpty;

  /// Whether this condition holds for [target].
  bool appliesTo(BuildTarget target) {
    if (exactTargets.isNotEmpty) {
      return exactTargets.contains(BuildTarget.snapshot(target));
    }
    if (exactAuxiliaryTargets.isNotEmpty) return false;
    if (platforms.isNotEmpty && !platforms.contains(target.platform)) {
      return false;
    }
    if (flavors.isNotEmpty && !flavors.contains(target.flavor)) {
      return false;
    }
    if (entrypoints.isNotEmpty && !entrypoints.contains(target.entrypoint)) {
      return false;
    }
    for (final entry in dartDefines.entries) {
      if (target.dartDefines[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Whether this condition can be proven to apply to [target].
  ///
  /// Legacy broad conditions are defined only for configured application
  /// targets. They cannot prove an auxiliary context absent an exact auxiliary
  /// identity, so they remain [ConditionApplicability.unknown].
  ConditionApplicability applicabilityToAuxiliaryTarget(
    AuxiliaryExecutionTarget target,
  ) {
    if (exactAuxiliaryTargets.contains(target)) {
      return ConditionApplicability.applies;
    }
    if (exactTargets.isNotEmpty || exactAuxiliaryTargets.isNotEmpty) {
      return ConditionApplicability.doesNotApply;
    }
    if (isUnconditional) return ConditionApplicability.applies;
    return ConditionApplicability.unknown;
  }

  @override
  bool operator ==(Object other) =>
      other is BuildCondition &&
      const SetEquality<String>().equals(platforms, other.platforms) &&
      const SetEquality<String>().equals(flavors, other.flavors) &&
      const SetEquality<String>().equals(entrypoints, other.entrypoints) &&
      const MapEquality<String, String>().equals(
        dartDefines,
        other.dartDefines,
      ) &&
      const SetEquality<BuildTarget>().equals(
        exactTargets,
        other.exactTargets,
      ) &&
      const SetEquality<AuxiliaryExecutionTarget>().equals(
        exactAuxiliaryTargets,
        other.exactAuxiliaryTargets,
      );

  @override
  int get hashCode => Object.hash(
    const SetEquality<String>().hash(platforms),
    const SetEquality<String>().hash(flavors),
    const SetEquality<String>().hash(entrypoints),
    const MapEquality<String, String>().hash(dartDefines),
    const SetEquality<BuildTarget>().hash(exactTargets),
    const SetEquality<AuxiliaryExecutionTarget>().hash(exactAuxiliaryTargets),
  );

  @override
  String toString() {
    if (isUnconditional) return 'BuildCondition(any)';
    final parts = <String>[
      if (platforms.isNotEmpty) 'platforms=${_sortedValues(platforms)}',
      if (flavors.isNotEmpty) 'flavors=${_sortedValues(flavors)}',
      if (entrypoints.isNotEmpty) 'entrypoints=${_sortedValues(entrypoints)}',
      if (dartDefines.isNotEmpty) 'defines=${_sortedMapString(dartDefines)}',
      if (exactTargets.isNotEmpty)
        'exactTargets=${_sortedValues(exactTargets)}',
      if (exactAuxiliaryTargets.isNotEmpty)
        'exactAuxiliaryTargets=${_sortedValues(exactAuxiliaryTargets)}',
    ];
    return 'BuildCondition(${parts.join(', ')})';
  }
}

String _sortedMapString(Map<String, String> values) {
  final entries = values.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return '{${entries.map((entry) => '${entry.key}: ${entry.value}').join(', ')}}';
}

String _sortedValues(Iterable<Object> values) {
  final sorted = values.map((value) => value.toString()).toList()..sort();
  return '{${sorted.join(', ')}}';
}
