import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../core/project/project_context.dart';

const String _defaultArbDir = 'lib/l10n';
const String _defaultTemplateArbFile = 'app_en.arb';
const String _defaultOutputLocalizationFile = 'app_localizations.dart';
const String _defaultOutputClass = 'AppLocalizations';
const bool _defaultNullableGetter = true;

/// The result of loading a project's current gen-l10n configuration.
sealed class L10nConfigLoadResult {
  /// Creates a configuration-loading result.
  const L10nConfigLoadResult();

  /// Whether this project has l10n configuration that an adapter must handle.
  bool get isApplicable;
}

/// No gen-l10n configuration applies to this project.
final class L10nConfigAbsent extends L10nConfigLoadResult {
  /// Creates an absent configuration result.
  const L10nConfigAbsent();

  @override
  bool get isApplicable => false;
}

/// A valid, current real-source gen-l10n configuration.
final class L10nConfigValid extends L10nConfigLoadResult {
  /// Creates a valid configuration result.
  const L10nConfigValid(this.config);

  /// The parsed configuration.
  final L10nConfig config;

  @override
  bool get isApplicable => true;
}

/// An applicable l10n configuration could not be interpreted safely.
final class L10nConfigInvalid extends L10nConfigLoadResult {
  /// Creates an invalid configuration result.
  const L10nConfigInvalid({required this.reason, required this.location});

  /// Stable explanation for the adapter's scoped confidence blocker.
  final String reason;

  /// Project-relative configuration location.
  final String location;

  @override
  bool get isApplicable => true;
}

/// Current Flutter gen-l10n configuration with project-contained I/O paths.
class L10nConfig {
  L10nConfig._({
    required this.arbDir,
    required this.templateArbFile,
    required this.templateArbPath,
    required this.outputDir,
    required this.outputLocalizationFile,
    required this.generatedLibraryPath,
    required this.outputClass,
    required this.nullableGetter,
  });

  /// Absolute normalized directory containing ARB input files.
  final String arbDir;

  /// Configured ARB template filename, relative to [arbDir].
  final String templateArbFile;

  /// Absolute normalized path to the configured template ARB file.
  final String templateArbPath;

  /// Absolute normalized directory receiving generated l10n Dart files.
  final String outputDir;

  /// Configured generated localization filename, relative to [outputDir].
  final String outputLocalizationFile;

  /// Absolute normalized path to the primary generated localization library.
  final String generatedLibraryPath;

  /// Generated localizations class name.
  final String outputClass;

  /// Whether Flutter generates a nullable localization getter.
  final bool nullableGetter;

  /// Loads typed current gen-l10n configuration for [project].
  ///
  /// Configuration applies when `l10n.yaml` exists or a Flutter package has
  /// `flutter: generate: true`. Invalid applicable configuration is never
  /// collapsed into an absent result, so callers can add a scoped blocker.
  static L10nConfigLoadResult load(ProjectContext project) {
    final configFile = File(p.join(project.root.path, 'l10n.yaml'));
    final location = project.relative(configFile.path);
    final FileSystemEntityType configType;
    try {
      configType = FileSystemEntity.typeSync(
        configFile.path,
        followLinks: false,
      );
    } on FileSystemException {
      return L10nConfigInvalid(
        reason: 'l10n.yaml could not be inspected.',
        location: location,
      );
    }
    if (configType == FileSystemEntityType.notFound &&
        !_usesFlutterGeneration(project)) {
      return const L10nConfigAbsent();
    }

    Map<dynamic, dynamic> values = const {};
    if (configType != FileSystemEntityType.notFound) {
      try {
        final canonicalConfigPath = _configFilePath(project, configFile.path);
        final contents = File(canonicalConfigPath).readAsStringSync();
        if (contents.trim().isNotEmpty) {
          final parsed = loadYaml(contents);
          if (parsed is! Map) {
            return L10nConfigInvalid(
              reason: 'l10n.yaml must contain a YAML mapping.',
              location: location,
            );
          }
          values = parsed;
        }
      } on _L10nConfigException catch (error) {
        return L10nConfigInvalid(reason: error.message, location: location);
      } on YamlException {
        return L10nConfigInvalid(
          reason: 'l10n.yaml could not parse as YAML.',
          location: location,
        );
      } on FileSystemException {
        return L10nConfigInvalid(
          reason: 'l10n.yaml could not be read.',
          location: location,
        );
      }
    }

    try {
      final syntheticPackage = _bool(values, 'synthetic-package');
      if (syntheticPackage == true) {
        throw const _L10nConfigException(
          'synthetic-package is no longer supported.',
        );
      }

      final arbDir = _projectPath(
        project,
        _string(values, 'arb-dir') ?? _defaultArbDir,
        field: 'arb-dir',
        basePath: project.root.path,
      );
      final templateArbFile =
          _string(values, 'template-arb-file') ?? _defaultTemplateArbFile;
      final templateArbPath = _projectPath(
        project,
        templateArbFile,
        field: 'template-arb-file',
        basePath: arbDir,
      );
      final outputDirValue = _string(values, 'output-dir');
      final outputDir = outputDirValue == null
          ? arbDir
          : _projectPath(
              project,
              outputDirValue,
              field: 'output-dir',
              basePath: project.root.path,
            );
      final outputLocalizationFile =
          _string(values, 'output-localization-file') ??
          _defaultOutputLocalizationFile;
      final generatedLibraryPath = _projectPath(
        project,
        outputLocalizationFile,
        field: 'output-localization-file',
        basePath: outputDir,
      );
      final outputClass =
          _string(values, 'output-class') ?? _defaultOutputClass;
      final nullableGetter =
          _bool(values, 'nullable-getter') ?? _defaultNullableGetter;

      return L10nConfigValid(
        L10nConfig._(
          arbDir: arbDir,
          templateArbFile: templateArbFile,
          templateArbPath: templateArbPath,
          outputDir: outputDir,
          outputLocalizationFile: outputLocalizationFile,
          generatedLibraryPath: generatedLibraryPath,
          outputClass: outputClass,
          nullableGetter: nullableGetter,
        ),
      );
    } on _L10nConfigException catch (error) {
      return L10nConfigInvalid(reason: error.message, location: location);
    } on FileSystemException {
      return L10nConfigInvalid(
        reason: 'l10n configuration paths could not be resolved.',
        location: location,
      );
    }
  }
}

bool _usesFlutterGeneration(ProjectContext project) =>
    project.isFlutterPackage && project.flutterSection['generate'] == true;

String? _string(Map<dynamic, dynamic> values, String field) {
  if (!values.containsKey(field)) return null;
  final value = values[field];
  if (value is! String) {
    throw _L10nConfigException('$field must be a string.');
  }
  if (value.trim().isEmpty) {
    throw _L10nConfigException('$field must not be empty.');
  }
  return value;
}

bool? _bool(Map<dynamic, dynamic> values, String field) {
  if (!values.containsKey(field)) return null;
  final value = values[field];
  if (value is! bool) {
    throw _L10nConfigException('$field must be a bool.');
  }
  return value;
}

String _projectPath(
  ProjectContext project,
  String input, {
  required String field,
  required String basePath,
}) {
  final candidate = p.normalize(
    p.isAbsolute(input) ? input : p.join(basePath, input),
  );
  final canonicalRoot = _resolveExistingPath(project.root.path);
  final canonicalCandidate = _resolveCandidatePath(candidate);
  if (!_isWithin(canonicalRoot, canonicalCandidate)) {
    throw _L10nConfigException('$field escapes the project.');
  }
  return canonicalCandidate;
}

String _configFilePath(ProjectContext project, String configPath) {
  final targetType = FileSystemEntity.typeSync(configPath);
  if (targetType != FileSystemEntityType.file) {
    final linkType = FileSystemEntity.typeSync(configPath, followLinks: false);
    if (linkType == FileSystemEntityType.directory) {
      throw const _L10nConfigException('l10n.yaml must be a regular file.');
    }
    throw const _L10nConfigException(
      'l10n.yaml must resolve to a regular file.',
    );
  }

  final canonicalRoot = _resolveExistingPath(project.root.path);
  final canonicalConfigPath = _resolveExistingPath(configPath);
  if (!_isWithin(canonicalRoot, canonicalConfigPath)) {
    throw const _L10nConfigException('l10n.yaml resolves outside the project.');
  }
  return canonicalConfigPath;
}

String _resolveCandidatePath(String candidate) {
  final missingSegments = <String>[];
  var existingPath = candidate;
  while (FileSystemEntity.typeSync(existingPath, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(existingPath);
    if (parent == existingPath) return candidate;
    missingSegments.add(p.basename(existingPath));
    existingPath = parent;
  }
  return p.normalize(
    p.joinAll([
      _resolveExistingPath(existingPath),
      ...missingSegments.reversed,
    ]),
  );
}

String _resolveExistingPath(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  final entity = type == FileSystemEntityType.directory
      ? Directory(path)
      : File(path);
  return p.normalize(entity.resolveSymbolicLinksSync());
}

bool _isWithin(String root, String candidate) =>
    p.equals(root, candidate) || p.isWithin(root, candidate);

class _L10nConfigException implements Exception {
  const _L10nConfigException(this.message);

  final String message;
}
