import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../verification/verification_policy.dart';
import '../graph/build_condition.dart';
import 'analysis_mode.dart';
import 'project_source_path.dart';
import 'target_matrix.dart';

/// Validated project-local configuration used by scan and apply.
class ProjectConfig {
  /// Creates a validated configuration.
  const ProjectConfig({
    required this.analysisMode,
    required this.targetMatrix,
    required this.rootCoverage,
    required this.source,
    required this.verificationPolicy,
  });

  /// Selected analysis boundary and action policy.
  final AnalysisMode analysisMode;

  /// Build target coverage declared by the project owner.
  final TargetMatrix targetMatrix;

  /// Application/package root coverage declared by the project owner.
  final RootCoverage rootCoverage;

  /// Absolute configuration file path.
  final String source;

  /// Exact verifier commands required for every mutation transaction.
  final VerificationPolicy verificationPolicy;

  /// Parses and validates [file] for a project rooted at [projectRoot].
  static Future<ProjectConfig> load(
    File file, {
    required Directory projectRoot,
  }) async {
    final Object? parsed;
    try {
      parsed = loadYaml(await file.readAsString());
    } on YamlException catch (error) {
      throw ProjectConfigException('Could not parse ${file.path}: $error');
    }
    if (parsed is! Map<Object?, Object?>) {
      throw ProjectConfigException('${file.path} must contain a YAML mapping.');
    }

    _rejectUnknownKeys(parsed, const {
      'version',
      'analysis',
      'target_matrix',
      'verification',
    }, 'root');
    if (parsed['version'] != 1) {
      throw ProjectConfigException(
        '${file.path} must declare the supported configuration version 1.',
      );
    }

    final analysis = _mapping(parsed['analysis'], 'analysis');
    if (analysis.containsKey('root_coverage')) {
      throw ProjectConfigException(
        'analysis.root_coverage was removed from config v1. Delete it; '
        'analysis.mode now controls the root strategy.',
      );
    }
    _rejectUnknownKeys(analysis, const {
      'mode',
      'public_entrypoints',
    }, 'analysis');
    final modeName = _requiredString(analysis['mode'], 'analysis.mode');
    final AnalysisMode mode;
    try {
      mode = AnalysisMode.parse(modeName);
    } on FormatException catch (error) {
      throw ProjectConfigException(error.message);
    }
    final publicEntrypoints = _stringList(
      analysis['public_entrypoints'],
      'analysis.public_entrypoints',
    );
    final rootCoverage = _parseRootCoverage(
      mode: mode,
      publicEntrypoints: publicEntrypoints,
      projectRoot: projectRoot,
      source: file.path,
    );

    final targetSection = _mapping(parsed['target_matrix'], 'target_matrix');
    _rejectUnknownKeys(targetSection, const {
      'complete',
      'targets',
    }, 'target_matrix');
    final completeValue = targetSection['complete'];
    if (completeValue is! bool) {
      throw ProjectConfigException('target_matrix.complete must be a boolean.');
    }
    final targetsValue = targetSection['targets'];
    if (targetsValue is! List<Object?> || targetsValue.isEmpty) {
      throw ProjectConfigException(
        'target_matrix.targets must be a non-empty list.',
      );
    }

    final targets = <BuildTarget>[];
    final names = <String>{};
    final targetSignatures = <String>{};
    for (var index = 0; index < targetsValue.length; index++) {
      final target = _parseTarget(
        targetsValue[index],
        index: index,
        projectRoot: projectRoot,
        sourceKind: mode == AnalysisMode.application
            ? ProjectSourceKind.applicationEntrypoint
            : ProjectSourceKind.dartFile,
      );
      if (!names.add(target.name)) {
        throw ProjectConfigException(
          'target_matrix target names must be unique: ${target.name}.',
        );
      }
      final signature = [
        target.platform,
        target.flavor ?? '',
        target.entrypoint,
        for (final entry
            in target.dartDefines.entries.toList()
              ..sort((left, right) => left.key.compareTo(right.key)))
          '${entry.key}=${entry.value}',
      ].join('\u0000');
      if (!targetSignatures.add(signature)) {
        throw ProjectConfigException(
          'target_matrix contains duplicate target conditions: ${target.name}.',
        );
      }
      targets.add(target);
    }

    final hasConditionalSources = _hasConditionalSources(
      projectRoot,
      additionalEntrypointPaths: mode == AnalysisMode.application
          ? targets.map((target) => target.entrypoint)
          : const [],
    );
    final effectiveComplete = completeValue && !hasConditionalSources;
    final issues = <String>[
      if (!completeValue) 'the configuration declares a partial target matrix',
      if (hasConditionalSources)
        'conditional Dart imports/exports are not modelled per target',
    ];
    return ProjectConfig(
      analysisMode: mode,
      targetMatrix: TargetMatrix(
        targets: List.unmodifiable(targets),
        status: effectiveComplete
            ? TargetMatrixStatus.declaredComplete
            : TargetMatrixStatus.declaredPartial,
        source: file.path,
        issues: issues,
      ),
      rootCoverage: rootCoverage,
      source: file.path,
      verificationPolicy: _parseVerification(parsed['verification']),
    );
  }

  static VerificationPolicy _parseVerification(Object? value) {
    if (value == null) return VerificationPolicy.flutterDefault;
    final section = _mapping(value, 'verification');
    _rejectUnknownKeys(section, const {'steps'}, 'verification');
    final stepsValue = section['steps'];
    if (stepsValue is! List<Object?> || stepsValue.isEmpty) {
      throw ProjectConfigException(
        'verification.steps must be a non-empty list.',
      );
    }
    final ids = <String>{};
    final commands = <VerificationCommand>[];
    for (var index = 0; index < stepsValue.length; index++) {
      final step = _mapping(stepsValue[index], 'verification.steps[$index]');
      _rejectUnknownKeys(step, const {
        'id',
        'argv',
      }, 'verification.steps[$index]');
      final id = _requiredString(step['id'], 'verification step id');
      if (!ids.add(id)) {
        throw ProjectConfigException(
          'verification step IDs must be unique: $id.',
        );
      }
      final argv = _stringList(step['argv'], 'verification.steps[$index].argv');
      if (argv.isEmpty || argv.any((argument) => argument.isEmpty)) {
        throw ProjectConfigException(
          'verification.steps[$index].argv must contain non-empty strings.',
        );
      }
      commands.add(
        VerificationCommand(
          id: id,
          executable: argv.first,
          arguments: List.unmodifiable(argv.skip(1)),
        ),
      );
    }
    return VerificationPolicy(commands: List.unmodifiable(commands));
  }

  static bool _hasConditionalSources(
    Directory projectRoot, {
    Iterable<String> additionalEntrypointPaths = const [],
  }) {
    final lib = Directory('${projectRoot.path}${Platform.pathSeparator}lib');
    final pendingPaths = <String>[];
    if (lib.existsSync()) {
      final List<FileSystemEntity> entities;
      try {
        entities = lib.listSync(recursive: true, followLinks: false);
      } on FileSystemException {
        return true;
      }
      pendingPaths.addAll(
        entities
            .whereType<File>()
            .where((entity) => entity.path.endsWith('.dart'))
            .map((entity) => entity.path),
      );
    }
    for (final relativeEntrypointPath in additionalEntrypointPaths.toSet()) {
      pendingPaths.add(
        p.normalize(p.join(projectRoot.path, relativeEntrypointPath)),
      );
    }

    final visitedPaths = <String>{};
    while (pendingPaths.isNotEmpty) {
      final sourcePath = p.normalize(pendingPaths.removeLast());
      if (!visitedPaths.add(sourcePath)) continue;
      try {
        final result = parseFile(
          path: sourcePath,
          featureSet: FeatureSet.latestLanguageVersion(),
        );
        final unit = result.unit;
        if (unit.directives.any(
          (directive) =>
              (directive is ImportDirective &&
                  directive.configurations.isNotEmpty) ||
              (directive is ExportDirective &&
                  directive.configurations.isNotEmpty),
        )) {
          return true;
        }

        // A configured entrypoint can legally import project-local Dart files
        // outside both lib/ and its own directory. Walk that semantic source
        // closure instead of assuming a directory layout; otherwise a
        // conditional import in a sibling such as shared/ would be invisible
        // and a declared-complete target matrix could authorize false SAFE.
        for (final directive in unit.directives) {
          final uri = switch (directive) {
            ImportDirective(:final uri) => uri.stringValue,
            ExportDirective(:final uri) => uri.stringValue,
            PartDirective(:final uri) => uri.stringValue,
            _ => null,
          };
          if (uri == null || Uri.tryParse(uri)?.hasScheme == true) continue;
          final referencedPath = p.normalize(
            p.join(File(sourcePath).parent.path, uri),
          );
          final relativePath = p.relative(
            referencedPath,
            from: projectRoot.path,
          );
          final isProjectLocal =
              relativePath != '..' && !relativePath.startsWith('../');
          final isIgnored = p
              .split(relativePath)
              .any(
                const {
                  '.dart_tool',
                  '.flutter_pruner',
                  '.git',
                  'build',
                  'tool',
                }.contains,
              );
          if (isProjectLocal &&
              !isIgnored &&
              referencedPath.endsWith('.dart') &&
              File(referencedPath).existsSync()) {
            pendingPaths.add(referencedPath);
          }
        }
      } on FileSystemException {
        return true;
      }
    }
    return false;
  }

  static RootCoverage _parseRootCoverage({
    required AnalysisMode mode,
    required List<String> publicEntrypoints,
    required Directory projectRoot,
    required String source,
  }) {
    switch (mode) {
      case AnalysisMode.application:
        if (publicEntrypoints.isNotEmpty) {
          throw ProjectConfigException(
            'analysis.public_entrypoints is only valid in package mode.',
          );
        }
        return RootCoverage(
          mode: RootCoverageMode.applicationEntrypoints,
          internalBoundaryComplete: true,
          externalConsumersCovered: true,
          source: source,
        );
      case AnalysisMode.package:
      case AnalysisMode.packageInternal:
        if (publicEntrypoints.isEmpty) {
          throw ProjectConfigException(
            'Package mode requires analysis.public_entrypoints.',
          );
        }
        final normalizedEntrypoints = publicEntrypoints
            .map(
              (entrypoint) => _validateProjectFile(
                projectRoot,
                entrypoint,
                'analysis.public_entrypoints',
                kind: ProjectSourceKind.publicLibrary,
              ),
            )
            .toList(growable: false);
        if (normalizedEntrypoints.toSet().length !=
            normalizedEntrypoints.length) {
          throw ProjectConfigException(
            'analysis.public_entrypoints contains duplicate paths.',
          );
        }
        return RootCoverage(
          mode: mode == AnalysisMode.package
              ? RootCoverageMode.packagePublicApi
              : RootCoverageMode.packageInternal,
          internalBoundaryComplete: true,
          externalConsumersCovered: false,
          source: source,
          publicEntrypoints: List.unmodifiable(normalizedEntrypoints),
          issues: [
            mode == AnalysisMode.package
                ? 'package consumers are open-world; findings are review-only'
                : 'external consumers are not scanned in package-internal mode',
          ],
        );
    }
  }

  static BuildTarget _parseTarget(
    Object? value, {
    required int index,
    required Directory projectRoot,
    required ProjectSourceKind sourceKind,
  }) {
    final mapping = _mapping(value, 'target_matrix.targets[$index]');
    _rejectUnknownKeys(mapping, const {
      'name',
      'platform',
      'entrypoint',
      'flavor',
      'dart_defines',
    }, 'target_matrix.targets[$index]');
    final name = _requiredString(mapping['name'], 'target name');
    final platform = _requiredString(mapping['platform'], 'target platform');
    const supportedPlatforms = {
      'android',
      'ios',
      'web',
      'macos',
      'linux',
      'windows',
    };
    if (!supportedPlatforms.contains(platform)) {
      throw ProjectConfigException('Unsupported target platform: $platform.');
    }
    final entrypoint = _validateProjectFile(
      projectRoot,
      _requiredString(mapping['entrypoint'], 'target entrypoint'),
      'target entrypoint',
      kind: sourceKind,
    );
    final flavorValue = mapping['flavor'];
    if (flavorValue != null && flavorValue is! String) {
      throw ProjectConfigException('target flavor must be a string.');
    }
    final defines = _stringMap(mapping['dart_defines'], 'target dart_defines');
    return BuildTarget(
      name: name,
      platform: platform,
      entrypoint: entrypoint,
      flavor: flavorValue as String?,
      dartDefines: defines,
    );
  }

  static String _validateProjectFile(
    Directory projectRoot,
    String relativePath,
    String field, {
    required ProjectSourceKind kind,
  }) {
    try {
      return ProjectSourcePath.validate(
        projectRoot,
        relativePath,
        field: field,
        kind: kind,
      );
    } on ProjectSourcePathException catch (error) {
      throw ProjectConfigException(error.message);
    }
  }

  static Map<Object?, Object?> _mapping(Object? value, String field) {
    if (value is! Map<Object?, Object?>) {
      throw ProjectConfigException('$field must be a mapping.');
    }
    return value;
  }

  static String _requiredString(Object? value, String field) {
    if (value is! String || value.isEmpty) {
      throw ProjectConfigException('$field must be a non-empty string.');
    }
    return value;
  }

  static List<String> _stringList(Object? value, String field) {
    if (value == null) return const [];
    if (value is! List<Object?> || value.any((item) => item is! String)) {
      throw ProjectConfigException('$field must be a list of strings.');
    }
    return value.cast<String>();
  }

  static Map<String, String> _stringMap(Object? value, String field) {
    if (value == null) return const {};
    if (value is! Map<Object?, Object?>) {
      throw ProjectConfigException('$field must be a string mapping.');
    }
    final result = <String, String>{};
    for (final entry in value.entries) {
      if (entry.key is! String || entry.value is! String) {
        throw ProjectConfigException('$field must contain only string values.');
      }
      result[entry.key! as String] = entry.value! as String;
    }
    return result;
  }

  static void _rejectUnknownKeys(
    Map<Object?, Object?> mapping,
    Set<String> allowed,
    String field,
  ) {
    for (final key in mapping.keys) {
      if (key is! String || !allowed.contains(key)) {
        throw ProjectConfigException('$field contains an unknown key: $key.');
      }
    }
  }
}

/// Thrown when the project config is missing required safety information.
class ProjectConfigException implements Exception {
  /// Creates a user-facing configuration error.
  ProjectConfigException(this.message);

  /// Actionable error text.
  final String message;

  @override
  String toString() => message;
}
