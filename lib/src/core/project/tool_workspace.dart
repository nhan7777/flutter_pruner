import 'dart:io';

import 'package:path/path.dart' as p;

/// Project-local paths owned or consumed by Flutter Pruner.
///
/// A single workspace keeps generated state out of the project's source tree
/// while still making it easy to inspect, archive, or remove as one unit.
class ToolWorkspace {
  /// Creates a workspace anchored to [projectRoot].
  ToolWorkspace(Directory projectRoot)
    : projectRoot = Directory(p.normalize(p.absolute(projectRoot.path))),
      _canonicalProjectRoot = _canonicalDirectory(projectRoot);

  /// Directory that contains the Dart or Flutter package being operated on.
  final Directory projectRoot;
  final String _canonicalProjectRoot;

  /// Tool-owned directory within the selected project.
  static const String directoryName = '.flutter_pruner';

  /// Default project configuration path relative to the project root.
  static const String configRelativePath = '$directoryName/config.yaml';

  /// Legacy configuration path retained for read compatibility.
  static const String legacyConfigRelativePath = 'flutter_pruner.yaml';

  /// Default quarantine path relative to the project root.
  static const String quarantineRelativePath = '$directoryName/quarantine';

  /// Legacy quarantine path retained for recovery compatibility.
  static const String legacyQuarantineRelativePath =
      '.flutter_pruner_quarantine';

  /// Default report directory relative to the project root.
  static const String reportsRelativePath = '$directoryName/reports';

  /// Project-local advisory lock used by source-mutating commands.
  static const String operationLockRelativePath =
      '$directoryName/operation.lock';

  /// Root directory for all generated Flutter Pruner state.
  Directory get directory => Directory(
    _resolveManagedRelativePath(directoryName, kind: 'tool workspace'),
  );

  /// Preferred project configuration file.
  File get configFile => File(
    _resolveManagedRelativePath(configRelativePath, kind: 'configuration'),
  );

  /// Previous root-level configuration file.
  File get legacyConfigFile =>
      File(p.join(projectRoot.path, legacyConfigRelativePath));

  /// Preferred quarantine directory.
  Directory get quarantineDirectory => Directory(
    _resolveManagedRelativePath(quarantineRelativePath, kind: 'quarantine'),
  );

  /// Previous quarantine directory.
  Directory get legacyQuarantineDirectory => Directory(
    _resolveManagedRelativePath(
      legacyQuarantineRelativePath,
      kind: 'legacy quarantine',
    ),
  );

  /// Directory used for explicitly requested relative reports.
  Directory get reportsDirectory => Directory(
    _resolveManagedRelativePath(reportsRelativePath, kind: 'reports'),
  );

  /// Lock file shared by apply, rollback, and destructive quarantine commands.
  File get operationLockFile => File(
    _resolveManagedRelativePath(
      operationLockRelativePath,
      kind: 'operation lock',
    ),
  );

  /// Validates default generated and recovery paths before a command starts.
  void validateManagedLayout() {
    directory.path;
    quarantineDirectory.path;
    reportsDirectory.path;
    operationLockFile.path;
    legacyQuarantineDirectory.path;
  }

  /// Discovers the preferred configuration, then the legacy configuration.
  ///
  /// Returns the preferred path when neither file exists so error messages and
  /// init guidance consistently point at the new layout.
  File get discoveredConfigFile {
    if (configFile.existsSync()) return configFile;
    if (legacyConfigFile.existsSync()) return legacyConfigFile;
    return configFile;
  }

  /// Resolves a project-owned path.
  ///
  /// Absolute paths remain absolute for explicit compatibility overrides;
  /// relative paths are always anchored to the selected project, never the
  /// directory from which the tool binary happened to be launched.
  String resolveProjectPath(String path) =>
      p.normalize(p.isAbsolute(path) ? path : p.join(projectRoot.path, path));

  /// Resolves an explicit configuration path relative to the project root.
  File resolveConfigFile(String path) =>
      File(_resolveSelectedPath(path, kind: 'configuration'));

  /// Resolves an explicitly requested report destination.
  ///
  /// Relative reports are contained below `.flutter_pruner/reports`. Absolute
  /// paths remain supported for CI jobs that publish reports elsewhere.
  File resolveReportFile(String path) {
    if (p.isAbsolute(path)) return File(p.normalize(path));
    final normalized = p.normalize(path);
    final segments = p.split(normalized);
    if (normalized == '..' || (segments.isNotEmpty && segments.first == '..')) {
      throw ToolWorkspaceException(
        'Relative report path escapes $reportsRelativePath: $path',
      );
    }
    return File(
      _resolveManagedRelativePath(
        p.join(reportsRelativePath, normalized),
        kind: 'report',
      ),
    );
  }

  /// Resolves the quarantine base selected by the user.
  Directory resolveQuarantineDirectory(String? path) {
    if (path == null || p.normalize(path) == quarantineRelativePath) {
      return quarantineDirectory;
    }
    if (p.normalize(path) == legacyQuarantineRelativePath) {
      return legacyQuarantineDirectory;
    }
    if (p.isAbsolute(path)) {
      return Directory(_canonicalizeDirectoryPath(path));
    }
    final normalized = p.normalize(path);
    if (!_isRelativeQuarantinePath(normalized)) {
      throw ToolWorkspaceException(
        'Relative quarantine path must stay within $directoryName or '
        '$legacyQuarantineRelativePath: $path',
      );
    }
    return Directory(
      _resolveManagedRelativePath(normalized, kind: 'quarantine'),
    );
  }

  bool _isRelativeQuarantinePath(String path) =>
      path == directoryName ||
      path == legacyQuarantineRelativePath ||
      p.isWithin(directoryName, path) ||
      p.isWithin(legacyQuarantineRelativePath, path);

  String _resolveSelectedPath(String path, {required String kind}) {
    if (p.isAbsolute(path)) return p.normalize(path);
    return _resolveManagedRelativePath(path, kind: kind);
  }

  String _resolveManagedRelativePath(
    String relativePath, {
    required String kind,
  }) {
    final normalized = p.normalize(relativePath);
    if (p.isAbsolute(normalized) ||
        normalized == '..' ||
        normalized.startsWith('../')) {
      throw ToolWorkspaceException(
        'Relative $kind path escapes the selected project: $relativePath',
      );
    }

    var current = projectRoot.path;
    final segments = p.split(normalized);
    for (var index = 0; index < segments.length; index++) {
      current = p.join(current, segments[index]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) break;
      if (type == FileSystemEntityType.link) {
        throw ToolWorkspaceException('$kind path contains a symlink: $current');
      }
      if (index < segments.length - 1 &&
          type != FileSystemEntityType.directory) {
        throw ToolWorkspaceException(
          '$kind path has a non-directory parent: $current',
        );
      }
      final canonical = type == FileSystemEntityType.directory
          ? Directory(current).resolveSymbolicLinksSync()
          : File(current).resolveSymbolicLinksSync();
      if (!_isWithinCanonicalProject(canonical)) {
        throw ToolWorkspaceException(
          '$kind path resolves outside the selected project: $current',
        );
      }
    }
    return p.join(projectRoot.path, normalized);
  }

  String _canonicalizeDirectoryPath(String path) {
    final normalized = p.normalize(p.absolute(path));
    var existing = normalized;
    final missingSegments = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      if (parent == existing) break;
      missingSegments.add(p.basename(existing));
      existing = parent;
    }
    final type = FileSystemEntity.typeSync(existing, followLinks: false);
    if (type != FileSystemEntityType.directory &&
        type != FileSystemEntityType.link) {
      throw ToolWorkspaceException(
        'Quarantine base is not a directory: $existing',
      );
    }
    final canonical = Directory(existing).resolveSymbolicLinksSync();
    return p.joinAll([canonical, ...missingSegments.reversed]);
  }

  bool _isWithinCanonicalProject(String path) =>
      p.equals(path, _canonicalProjectRoot) ||
      p.isWithin(_canonicalProjectRoot, path);

  static String _canonicalDirectory(Directory directory) {
    final absolute = p.normalize(p.absolute(directory.path));
    try {
      return p.normalize(directory.resolveSymbolicLinksSync());
    } on FileSystemException {
      return absolute;
    }
  }
}

/// A project-local workspace path is invalid.
class ToolWorkspaceException implements Exception {
  /// Creates a user-facing path error.
  const ToolWorkspaceException(this.message);

  /// Actionable error text.
  final String message;

  @override
  String toString() => message;
}
