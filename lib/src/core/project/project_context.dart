import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../verification/verification_policy.dart';
import '../graph/build_condition.dart';
import 'analysis_mode.dart';
import 'project_config.dart';
import 'project_language_version.dart';
import 'project_path_policy.dart';
import 'target_matrix.dart';
import 'tool_workspace.dart';

/// Everything an adapter needs to know about the project under analysis.
///
/// Loaded once by the engine and shared by every adapter, so expensive setup —
/// notably the analyzer's resolved unit cache — happens a single time.
class ProjectContext {
  /// Creates a project context.
  ProjectContext({
    required this.root,
    required Map<dynamic, dynamic> pubspec,
    required this.packageName,
    this.analysisMode = AnalysisMode.application,
    List<BuildTarget>? targets,
    TargetMatrix? targetMatrix,
    RootCoverage? rootCoverage,
    ProjectPathPolicy? pathPolicy,
    VerificationPolicy verificationPolicy = VerificationPolicy.flutterDefault,
  }) : assert(targets != null || targetMatrix != null),
       pubspec = _snapshotMap(pubspec),
       targetMatrix = targetMatrix ?? TargetMatrix.declared(targets!),
       rootCoverage = _normalizeRootCoverage(analysisMode, rootCoverage),
       verificationPolicy = _snapshotVerificationPolicy(verificationPolicy),
       pathPolicy = pathPolicy ?? ProjectPathPolicy(root: root);

  /// Loads the project rooted at [directory].
  ///
  /// Throws [ProjectLoadException] when there is no readable `pubspec.yaml`,
  /// since every later step depends on it.
  static Future<ProjectContext> load(
    Directory directory, {
    List<BuildTarget>? targets,
    File? configFile,
    Iterable<String> additionalExcludedPaths = const [],
  }) async {
    final pubspecFile = File(p.join(directory.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) {
      throw ProjectLoadException(
        'No pubspec.yaml found in ${directory.path}. '
        'Run this command from the root of a Dart or Flutter package.',
      );
    }

    final Object? parsed;
    try {
      parsed = loadYaml(await pubspecFile.readAsString());
    } on YamlException catch (e) {
      throw ProjectLoadException('Could not parse pubspec.yaml: $e');
    }

    if (parsed is! Map) {
      throw ProjectLoadException(
        'pubspec.yaml does not contain a YAML mapping.',
      );
    }

    final name = parsed['name'];
    if (name is! String || name.isEmpty) {
      throw ProjectLoadException('pubspec.yaml is missing a "name" field.');
    }

    if (targets != null && configFile != null) {
      throw ProjectLoadException(
        'Pass either explicit targets or a configuration file, not both.',
      );
    }

    final workspace = ToolWorkspace(directory);
    final discoveredConfig = configFile ?? workspace.discoveredConfigFile;
    final ProjectConfig? projectConfig;
    if (discoveredConfig.existsSync()) {
      try {
        projectConfig = await ProjectConfig.load(
          discoveredConfig,
          projectRoot: directory,
        );
      } on ProjectConfigException catch (error) {
        throw ProjectLoadException(error.message);
      }
    } else if (configFile != null) {
      throw ProjectLoadException(
        'Configuration file not found: ${configFile.path}',
      );
    } else {
      projectConfig = null;
    }

    final inferredEntrypoints = <String>[];
    final conventionalPackageEntry = 'lib/$name.dart';
    if (File(p.join(directory.path, conventionalPackageEntry)).existsSync()) {
      inferredEntrypoints.add(conventionalPackageEntry);
    }

    return ProjectContext(
      root: directory,
      pubspec: parsed,
      packageName: name,
      analysisMode: projectConfig?.analysisMode ?? AnalysisMode.application,
      // A default single target keeps first-run usable. Real projects should
      // declare their matrix in configuration: a resource unreachable in prod
      // but reachable in staging is not dead.
      targetMatrix:
          projectConfig?.targetMatrix ??
          (targets != null
              ? TargetMatrix.declared(targets)
              : TargetMatrix(
                  targets: [
                    BuildTarget(
                      name: 'default',
                      platform: 'android',
                      entrypoint: 'lib/main.dart',
                    ),
                  ],
                  status: TargetMatrixStatus.inferredDefault,
                  source: 'built-in default',
                  issues: [
                    'build targets were inferred; run flutter_pruner init',
                  ],
                )),
      rootCoverage:
          projectConfig?.rootCoverage ??
          (targets != null
              ? RootCoverage.applicationApi()
              : RootCoverage(
                  mode: RootCoverageMode.inferred,
                  internalBoundaryComplete: false,
                  externalConsumersCovered: false,
                  source: 'built-in inference',
                  publicEntrypoints: inferredEntrypoints,
                  issues: const [
                    'entry roots were inferred; run flutter_pruner init',
                  ],
                )),
      verificationPolicy:
          projectConfig?.verificationPolicy ??
          VerificationPolicy.flutterDefault,
      pathPolicy: ProjectPathPolicy(
        root: directory,
        additionalExcludedPaths: additionalExcludedPaths,
      ),
    );
  }

  /// Package root directory.
  final Directory root;

  /// Parsed `pubspec.yaml` contents.
  final Map<dynamic, dynamic> pubspec;

  /// Package name from `pubspec.yaml`.
  final String packageName;

  /// Feature set used to parse this project's own Dart sources.
  late final FeatureSet dartFeatureSet =
      ProjectLanguageVersion.featureSetForPubspec(pubspec);

  /// Selected analysis boundary and action policy.
  final AnalysisMode analysisMode;

  /// Build targets and the provenance of their completeness assertion.
  final TargetMatrix targetMatrix;

  /// Roots and the provenance of their completeness assertion.
  final RootCoverage rootCoverage;

  /// Exact verification commands required before committing mutations.
  final VerificationPolicy verificationPolicy;

  /// Canonical filesystem boundary and tool-owned path exclusions.
  final ProjectPathPolicy pathPolicy;

  /// Build targets reachability is evaluated against.
  List<BuildTarget> get targets => targetMatrix.targets;

  /// Whether targets and externally addressable roots are explicitly complete.
  bool get analysisCoverageComplete =>
      targetMatrix.isComplete && rootCoverage.internalBoundaryComplete;

  /// Whether this package depends on Flutter.
  bool get isFlutterPackage {
    final deps = pubspec['dependencies'];
    return deps is Map && deps.containsKey('flutter');
  }

  /// The `flutter:` section, or an empty map when absent.
  Map<dynamic, dynamic> get flutterSection {
    final section = pubspec['flutter'];
    return section is Map ? section : const {};
  }

  /// Direct dependency names.
  Set<String> get dependencies {
    final deps = pubspec['dependencies'];
    return deps is Map
        ? Set<String>.unmodifiable(deps.keys.whereType<String>())
        : const {};
  }

  /// Whether the project directly depends on [packageName].
  ///
  /// Adapters use this in their `appliesTo` check to skip cheaply.
  bool hasDependency(String packageName) => dependencies.contains(packageName);

  /// Resolves [relativePath] against the project root.
  String resolve(String relativePath) => p.join(root.path, relativePath);

  /// Path relative to the project root, using forward slashes.
  ///
  /// Node ids must be stable across machines and operating systems, so always
  /// use this rather than an absolute path when constructing an id.
  String relative(String absolutePath) =>
      p.relative(absolutePath, from: root.path).replaceAll(r'\', '/');

  /// Dart files under `lib/`, `bin/` and `test/`.
  ///
  /// Skips generated `.g.dart`/`.freezed.dart` output and hidden directories.
  List<File> get dartFiles {
    final result = <File>[];
    for (final dir in const ['lib', 'bin', 'test']) {
      final directory = Directory(resolve(dir));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        if (pathPolicy.shouldExcludeTraversalEntry(entity)) continue;
        if (!entity.path.endsWith('.dart')) continue;
        if (p.split(entity.path).any((s) => s.startsWith('.'))) continue;
        result.add(entity);
      }
    }
    return result;
  }
}

RootCoverage _normalizeRootCoverage(
  AnalysisMode analysisMode,
  RootCoverage? coverage,
) {
  if (coverage == null && analysisMode == AnalysisMode.application) {
    return RootCoverage.applicationApi();
  }
  final expectedMode = switch (analysisMode) {
    AnalysisMode.application => RootCoverageMode.applicationEntrypoints,
    AnalysisMode.package => RootCoverageMode.packagePublicApi,
    AnalysisMode.packageInternal => RootCoverageMode.packageInternal,
  };
  if (coverage != null &&
      (coverage.mode == expectedMode ||
          (coverage.mode == RootCoverageMode.inferred &&
              !coverage.internalBoundaryComplete))) {
    return coverage;
  }
  return RootCoverage(
    mode: RootCoverageMode.inferred,
    internalBoundaryComplete: false,
    externalConsumersCovered: false,
    source: coverage?.source ?? 'api inference',
    publicEntrypoints: coverage?.publicEntrypoints ?? const [],
    issues: [
      ...?coverage?.issues,
      coverage == null
          ? 'root coverage must be declared explicitly for ${analysisMode.name}'
          : 'root coverage mode ${coverage.mode.name} is incompatible with '
                'analysis mode ${analysisMode.name}',
    ],
  );
}

Map<dynamic, dynamic> _snapshotMap(Map<dynamic, dynamic> source) =>
    Map<dynamic, dynamic>.unmodifiable({
      for (final entry in source.entries)
        _snapshotValue(entry.key): _snapshotValue(entry.value),
    });

Object? _snapshotValue(Object? value) {
  if (value is Map) {
    return Map<dynamic, dynamic>.unmodifiable({
      for (final entry in value.entries)
        _snapshotValue(entry.key): _snapshotValue(entry.value),
    });
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_snapshotValue));
  }
  if (value is Set) {
    return Set<Object?>.unmodifiable(value.map(_snapshotValue));
  }
  return value;
}

VerificationPolicy _snapshotVerificationPolicy(VerificationPolicy policy) =>
    VerificationPolicy(
      commands: List<VerificationCommand>.unmodifiable(
        policy.commands.map(
          (command) => VerificationCommand(
            id: command.id,
            executable: command.executable,
            arguments: List<String>.unmodifiable(command.arguments),
          ),
        ),
      ),
    );

/// Thrown when a project cannot be loaded.
class ProjectLoadException implements Exception {
  /// Creates the exception with a user-facing [message].
  ProjectLoadException(this.message);

  /// Message shown to the user. Should be actionable.
  final String message;

  @override
  String toString() => message;
}
