import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import 'project_language_version.dart';

/// The semantic role expected from a project-owned Dart source path.
enum ProjectSourceKind {
  /// A runnable application entrypoint with a top-level `main()` function.
  applicationEntrypoint,

  /// A package library that external consumers may import.
  publicLibrary,

  /// A Dart source file without an additional library-role constraint.
  dartFile,
}

/// Validates and normalizes source paths owned by a selected project.
///
/// This belongs below the CLI so hand-edited YAML and scripted `init` calls
/// cannot bypass the same project-boundary checks used by the interactive
/// wizard.
class ProjectSourcePath {
  /// Validates [input] and returns a normalized project-relative POSIX path.
  static String validate(
    Directory projectRoot,
    String input, {
    required String field,
    required ProjectSourceKind kind,
    bool allowAbsoluteInput = false,
  }) {
    if (input.trim().isEmpty) {
      throw ProjectSourcePathException('$field must not be empty.');
    }
    if (_containsControlCharacter(input)) {
      throw ProjectSourcePathException(
        '$field contains an unsupported control character.',
      );
    }

    final absoluteRoot = p.normalize(p.absolute(projectRoot.path));
    final canonicalRoot = _canonicalDirectory(projectRoot, field: field);
    final absoluteCandidate = p.normalize(
      p.isAbsolute(input) ? input : p.join(absoluteRoot, input),
    );
    if (p.isAbsolute(input) && !allowAbsoluteInput) {
      throw ProjectSourcePathException('$field must be relative: $input.');
    }
    if (!_isWithin(absoluteRoot, absoluteCandidate)) {
      throw ProjectSourcePathException('$field escapes the project: $input.');
    }

    final relative = p.relative(absoluteCandidate, from: absoluteRoot);
    _rejectSymlinkComponents(absoluteRoot, relative, field: field);
    final type = FileSystemEntity.typeSync(
      absoluteCandidate,
      followLinks: false,
    );
    if (type != FileSystemEntityType.file) {
      final suffix = type == FileSystemEntityType.notFound
          ? 'does not exist'
          : 'must be a regular file';
      throw ProjectSourcePathException('$field $suffix: $input.');
    }

    final canonicalFile = _canonicalFile(File(absoluteCandidate), field: field);
    if (!_isWithin(canonicalRoot, canonicalFile)) {
      throw ProjectSourcePathException(
        '$field resolves outside the project: $input.',
      );
    }
    if (!absoluteCandidate.endsWith('.dart')) {
      throw ProjectSourcePathException('$field must be a Dart file: $input.');
    }

    final normalized = relative.replaceAll(r'\', '/');
    if (_isGenerated(normalized)) {
      throw ProjectSourcePathException(
        '$field must not point at generated Dart output: $input.',
      );
    }
    _validateDartRole(
      absoluteCandidate,
      normalized,
      field: field,
      kind: kind,
      featureSet: ProjectLanguageVersion.featureSetFor(projectRoot),
    );
    return normalized;
  }

  static void _validateDartRole(
    String absolutePath,
    String relativePath, {
    required String field,
    required ProjectSourceKind kind,
    required FeatureSet featureSet,
  }) {
    late final CompilationUnit unit;
    try {
      final result = parseFile(
        path: absolutePath,
        featureSet: featureSet,
        throwIfDiagnostics: false,
      );
      if (result.errors.isNotEmpty) {
        throw ProjectSourcePathException(
          '$field is not valid Dart syntax: $relativePath.',
        );
      }
      unit = result.unit;
    } on ArgumentError {
      throw ProjectSourcePathException(
        '$field is not valid Dart syntax: $relativePath.',
      );
    } on FileSystemException {
      throw ProjectSourcePathException(
        '$field is not readable: $relativePath.',
      );
    }
    if (unit.directives.any((directive) => directive is PartOfDirective)) {
      throw ProjectSourcePathException(
        '$field must be a Dart library, not a part file: $relativePath.',
      );
    }
    switch (kind) {
      case ProjectSourceKind.applicationEntrypoint:
        final hasMain = unit.declarations.whereType<FunctionDeclaration>().any(
          (declaration) => declaration.name.lexeme == 'main',
        );
        if (!hasMain) {
          throw ProjectSourcePathException(
            '$field must declare a top-level main(): $relativePath.',
          );
        }
      case ProjectSourceKind.publicLibrary:
        if (relativePath != 'lib' && !p.posix.isWithin('lib', relativePath)) {
          throw ProjectSourcePathException(
            '$field must be under lib/: $relativePath.',
          );
        }
      case ProjectSourceKind.dartFile:
        break;
    }
  }

  static void _rejectSymlinkComponents(
    String absoluteRoot,
    String relativePath, {
    required String field,
  }) {
    var current = absoluteRoot;
    for (final segment in p.split(relativePath)) {
      current = p.join(current, segment);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.link) {
        throw ProjectSourcePathException(
          '$field contains a symlink: $current.',
        );
      }
      if (type == FileSystemEntityType.notFound) return;
    }
  }

  static String _canonicalDirectory(
    Directory directory, {
    required String field,
  }) {
    try {
      return p.normalize(directory.resolveSymbolicLinksSync());
    } on FileSystemException {
      throw ProjectSourcePathException(
        'Could not resolve the project root while validating $field.',
      );
    }
  }

  static String _canonicalFile(File file, {required String field}) {
    try {
      return p.normalize(file.resolveSymbolicLinksSync());
    } on FileSystemException {
      throw ProjectSourcePathException('$field is not readable: ${file.path}.');
    }
  }

  static bool _isWithin(String root, String path) =>
      p.equals(root, path) || p.isWithin(root, path);

  static bool _containsControlCharacter(String value) =>
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f);

  static bool _isGenerated(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.g.dart') ||
        lower.endsWith('.freezed.dart') ||
        lower.endsWith('.gen.dart') ||
        lower.endsWith('.mocks.dart') ||
        lower.contains('/generated/') ||
        lower.contains('/gen/');
  }
}

/// A project-owned source path violates the analysis boundary or role.
class ProjectSourcePathException implements Exception {
  /// Creates a validation error with a user-facing [message].
  const ProjectSourcePathException(this.message);

  /// Explanation suitable for CLI output.
  final String message;

  @override
  String toString() => message;
}
