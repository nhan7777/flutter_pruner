import 'package:collection/collection.dart';

import 'execution_context_identity.dart';

/// The execution domain that owns a reachability root.
enum RootDomain {
  /// A configured application build target.
  configuredTarget,

  /// A non-application execution environment.
  auxiliary,
}

/// A non-application execution environment that can use project code.
enum AuxiliaryExecutionDomain {
  /// The Dart or Flutter test runner.
  test,

  /// A runtime callback entered outside ordinary application startup.
  runtime,

  /// A consumer outside the selected package.
  external,
}

/// Whether a condition applies to an auxiliary execution target.
enum ConditionApplicability {
  /// The condition explicitly applies.
  applies,

  /// The condition explicitly does not apply.
  doesNotApply,

  /// The condition cannot prove applicability for this auxiliary target.
  unknown,
}

/// The capability that crosses a callback boundary into Dart code.
enum CallbackBoundaryCapability {
  /// A Dart VM callback.
  dartVm,

  /// A Flutter engine or native callback.
  flutterEngineNative,

  /// A mobile WorkManager callback.
  workmanagerMobile,

  /// A native FFI callback.
  ffiNative,

  /// A callback mechanism the adapter cannot classify.
  unknown,
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
  }) {
    configuredExecutionContextId(name);
    return BuildTarget._(
      name: name,
      platform: platform,
      entrypoint: entrypoint,
      flavor: flavor,
      dartDefines: Map<String, String>.unmodifiable(dartDefines),
    );
  }

  /// Creates a canonical immutable snapshot of [target].
  ///
  /// [BuildTarget] is a long-standing open type, so callers may supply an
  /// implementation with mutable getters. Graph value objects must never keep
  /// such an implementation as an equality/hash key.
  factory BuildTarget.snapshot(BuildTarget target) => BuildTarget(
    name: target.name,
    platform: target.platform,
    entrypoint: target.entrypoint,
    flavor: target.flavor,
    dartDefines: target.dartDefines,
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
  bool operator ==(Object other) =>
      other is BuildTarget &&
      other.name == name &&
      other.platform == platform &&
      other.flavor == flavor &&
      other.entrypoint == entrypoint &&
      const MapEquality<String, String>().equals(
        other.dartDefines,
        dartDefines,
      );

  @override
  int get hashCode => Object.hash(
    name,
    platform,
    flavor,
    entrypoint,
    const MapEquality<String, String>().hash(dartDefines),
  );

  @override
  String toString() =>
      'BuildTarget(name=$name, platform=$platform, flavor=$flavor, '
      'entrypoint=$entrypoint, dartDefines=${_sortedMapString(dartDefines)})';
}

/// An execution target outside the configured application build matrix.
final class AuxiliaryExecutionTarget {
  /// Creates an auxiliary execution target with a stable domain-qualified ID.
  factory AuxiliaryExecutionTarget({
    required String id,
    required AuxiliaryExecutionDomain domain,
    required Map<String, String> environmentValues,
    required bool environmentComplete,
    required String reason,
    BuildTarget? sourceConfiguredTarget,
  }) {
    validateAuxiliaryExecutionContextId(id, domain);
    return AuxiliaryExecutionTarget._(
      id: id,
      domain: domain,
      environmentValues: Map<String, String>.unmodifiable(environmentValues),
      environmentComplete: environmentComplete,
      reason: reason,
      sourceConfiguredTarget: sourceConfiguredTarget == null
          ? null
          : BuildTarget.snapshot(sourceConfiguredTarget),
    );
  }

  const AuxiliaryExecutionTarget._({
    required this.id,
    required this.domain,
    required this.environmentValues,
    required this.environmentComplete,
    required this.reason,
    required this.sourceConfiguredTarget,
  });

  /// Globally unique `aux:<domain>:<id>` identity.
  final String id;

  /// Domain whose execution facts this target represents.
  final AuxiliaryExecutionDomain domain;

  /// Environment values known for this execution target.
  final Map<String, String> environmentValues;

  /// Whether [environmentValues] cover the entire execution environment.
  final bool environmentComplete;

  /// Why this execution target is present.
  final String reason;

  /// Configured application target this auxiliary target originated from.
  final BuildTarget? sourceConfiguredTarget;

  @override
  bool operator ==(Object other) =>
      other is AuxiliaryExecutionTarget &&
      other.id == id &&
      other.domain == domain &&
      other.environmentComplete == environmentComplete &&
      other.reason == reason &&
      other.sourceConfiguredTarget == sourceConfiguredTarget &&
      const MapEquality<String, String>().equals(
        other.environmentValues,
        environmentValues,
      );

  @override
  int get hashCode => Object.hash(
    id,
    domain,
    const MapEquality<String, String>().hash(environmentValues),
    environmentComplete,
    reason,
    sourceConfiguredTarget,
  );

  @override
  String toString() =>
      'AuxiliaryExecutionTarget(id=$id, domain=${domain.name}, '
      'environmentValues=${_sortedMapString(environmentValues)}, '
      'environmentComplete=$environmentComplete, reason=$reason, '
      'sourceConfiguredTarget=$sourceConfiguredTarget)';
}

/// Describes a callback parameter that crosses into an auxiliary context.
final class CallbackBoundaryDescriptor {
  /// Creates a callback-boundary descriptor.
  const CallbackBoundaryDescriptor({
    required this.argumentIndex,
    required this.description,
    required this.capability,
  });

  /// Zero-based argument index of the callback.
  final int argumentIndex;

  /// User-facing description of the boundary.
  final String description;

  /// Capability that invokes the callback.
  final CallbackBoundaryCapability capability;

  @override
  bool operator ==(Object other) =>
      other is CallbackBoundaryDescriptor &&
      other.argumentIndex == argumentIndex &&
      other.description == description &&
      other.capability == capability;

  @override
  int get hashCode => Object.hash(argumentIndex, description, capability);

  @override
  String toString() =>
      'CallbackBoundaryDescriptor(argumentIndex=$argumentIndex, '
      'description=$description, capability=${capability.name})';
}

/// A conflicting reuse of an auxiliary execution-target identity.
final class AuxiliaryExecutionTargetRegistryIssue {
  /// Creates an immutable record of a rejected auxiliary target definition.
  const AuxiliaryExecutionTargetRegistryIssue({
    required this.id,
    required this.acceptedDefinitionSha256,
    required this.rejectedDefinitionSha256,
    required this.reason,
  });

  /// The conflicting auxiliary execution-target ID.
  final String id;

  /// Stable digest of the accepted target definition.
  final String acceptedDefinitionSha256;

  /// Stable digest of the rejected target definition.
  final String rejectedDefinitionSha256;

  /// Explanation of the conflict.
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is AuxiliaryExecutionTargetRegistryIssue &&
      other.id == id &&
      other.acceptedDefinitionSha256 == acceptedDefinitionSha256 &&
      other.rejectedDefinitionSha256 == rejectedDefinitionSha256 &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(
    id,
    acceptedDefinitionSha256,
    rejectedDefinitionSha256,
    reason,
  );

  @override
  String toString() =>
      'AuxiliaryExecutionTargetRegistryIssue(id=$id, '
      'acceptedDefinitionSha256=$acceptedDefinitionSha256, '
      'rejectedDefinitionSha256=$rejectedDefinitionSha256, reason=$reason)';
}

String _sortedMapString(Map<String, String> values) {
  final entries = values.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return '{${entries.map((entry) => '${entry.key}: ${entry.value}').join(', ')}}';
}
