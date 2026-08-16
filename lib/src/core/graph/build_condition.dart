import 'package:collection/collection.dart';

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
  }) => BuildCondition._(
    platforms: Set<String>.unmodifiable(platforms),
    flavors: Set<String>.unmodifiable(flavors),
    entrypoints: Set<String>.unmodifiable(entrypoints),
    dartDefines: Map<String, String>.unmodifiable(dartDefines),
  );

  const BuildCondition._({
    required this.platforms,
    required this.flavors,
    required this.entrypoints,
    required this.dartDefines,
  });

  /// A condition that holds for every target.
  static const BuildCondition unconditional = BuildCondition._(
    platforms: <String>{},
    flavors: <String>{},
    entrypoints: <String>{},
    dartDefines: <String, String>{},
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

  /// Whether this condition places no restriction at all.
  bool get isUnconditional =>
      platforms.isEmpty &&
      flavors.isEmpty &&
      entrypoints.isEmpty &&
      dartDefines.isEmpty;

  /// Whether this condition holds for [target].
  bool appliesTo(BuildTarget target) {
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

  @override
  bool operator ==(Object other) =>
      other is BuildCondition &&
      const SetEquality<String>().equals(platforms, other.platforms) &&
      const SetEquality<String>().equals(flavors, other.flavors) &&
      const SetEquality<String>().equals(entrypoints, other.entrypoints) &&
      const MapEquality<String, String>().equals(
        dartDefines,
        other.dartDefines,
      );

  @override
  int get hashCode => Object.hash(
    const SetEquality<String>().hash(platforms),
    const SetEquality<String>().hash(flavors),
    const SetEquality<String>().hash(entrypoints),
    const MapEquality<String, String>().hash(dartDefines),
  );

  @override
  String toString() {
    if (isUnconditional) return 'BuildCondition(any)';
    final parts = <String>[
      if (platforms.isNotEmpty) 'platforms=$platforms',
      if (flavors.isNotEmpty) 'flavors=$flavors',
      if (entrypoints.isNotEmpty) 'entrypoints=$entrypoints',
      if (dartDefines.isNotEmpty) 'defines=$dartDefines',
    ];
    return 'BuildCondition(${parts.join(', ')})';
  }
}

/// One concrete build configuration the project supports.
///
/// Targets are declared explicitly in configuration rather than inferred: a
/// resource unreachable in `prod` but reachable in `staging` is not dead.
class BuildTarget {
  /// Creates a build target.
  ///
  /// The supplied defines are snapshotted because target conditions may be
  /// evaluated repeatedly across graph passes. Later caller mutation must not
  /// change which nodes are reachable.
  factory BuildTarget({
    required String name,
    required String platform,
    required String entrypoint,
    String? flavor,
    Map<String, String> dartDefines = const {},
  }) => BuildTarget._(
    name: name,
    platform: platform,
    entrypoint: entrypoint,
    flavor: flavor,
    dartDefines: Map<String, String>.unmodifiable(dartDefines),
  );

  const BuildTarget._({
    required this.name,
    required this.platform,
    required this.entrypoint,
    required this.flavor,
    required this.dartDefines,
  });

  /// Unique name, for example `android-prod`.
  final String name;

  /// Target platform: `android`, `ios`, `web`, `macos`, `linux`, `windows`.
  final String platform;

  /// Entrypoint path, for example `lib/main_prod.dart`.
  final String entrypoint;

  /// Optional flavor name.
  final String? flavor;

  /// `--dart-define` values used for this target.
  final Map<String, String> dartDefines;

  @override
  String toString() => 'BuildTarget($name)';
}
