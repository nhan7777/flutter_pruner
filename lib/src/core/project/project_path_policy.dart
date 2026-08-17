import 'dart:io';

import 'package:path/path.dart' as p;

/// Why a path was excluded from project analysis.
class PathExclusionSummary {
  /// Creates an immutable exclusion summary.
  factory PathExclusionSummary({
    required int policyVersion,
    required Map<String, int> byReason,
  }) => PathExclusionSummary._(
    policyVersion: policyVersion,
    byReason: Map<String, int>.unmodifiable(byReason),
  );

  const PathExclusionSummary._({
    required this.policyVersion,
    required this.byReason,
  });

  /// Version of the matching rules used for this scan.
  final int policyVersion;

  /// Unique paths observed for each exclusion reason.
  final Map<String, int> byReason;

  /// Number of unique excluded paths observed by the policy.
  int get total => byReason.values.fold(0, (sum, count) => sum + count);
}

/// Central path boundary shared by project discovery and every adapter.
///
/// The policy prevents the tool from analysing its own quarantine, reports,
/// caches, or editor/agent state. It also rejects symlinks and paths outside
/// the canonical project root.
class ProjectPathPolicy {
  /// Creates a policy rooted at [root].
  ProjectPathPolicy({
    required Directory root,
    Iterable<String> additionalExcludedPaths = const [],
  }) : _rootPath = p.normalize(p.absolute(root.path)),
       _canonicalRootPath = _canonicalDirectory(root),
       _additionalExcludedPaths = additionalExcludedPaths
           .map((path) => p.normalize(p.absolute(path)))
           .toSet();

  /// Current exclusion rule version exposed in run reports.
  static const int version = 2;

  static const Set<String> _excludedDirectoryNames = {
    '.agent',
    '.agents',
    '.claude',
    '.codex',
    '.dart_tool',
    '.fvm',
    '.git',
    '.gradle',
    '.idea',
    '.vscode',
    '.flutter_pruner',
    '.flutter_pruner_quarantine',
    'Pods',
    'build',
    'coverage',
    'node_modules',
  };

  static const Set<String> _excludedFileNames = {
    '.DS_Store',
    'Thumbs.db',
    'flutter_pruner.yaml',
  };

  final String _rootPath;
  final String _canonicalRootPath;
  final Set<String> _additionalExcludedPaths;
  final Map<String, Set<String>> _observedByReason = {};

  /// Whether [path] is outside the declared analysis boundary.
  bool shouldExclude(String path) {
    final normalized = p.normalize(p.absolute(path));
    final reason = _reasonFor(normalized);
    return _record(normalized, reason);
  }

  /// Fast path for entries produced by a traversal using `followLinks: false`.
  ///
  /// The traversal already supplies the entity type and cannot descend through
  /// a symlink, so repeating `typeSync` and canonical resolution for every
  /// ordinary file would add syscalls without strengthening the boundary.
  bool shouldExcludeTraversalEntry(FileSystemEntity entity) {
    final normalized = p.normalize(p.absolute(entity.path));
    final lexicalReason = _lexicalReason(normalized);
    if (lexicalReason != null) return _record(normalized, lexicalReason);
    if (entity is Link) return _record(normalized, 'symlink');
    if (entity is Directory &&
        _excludedDirectoryNames.contains(p.basename(normalized))) {
      return _record(normalized, 'directory:${p.basename(normalized)}');
    }
    return false;
  }

  /// Clears observations before a fresh analysis pass.
  void resetObservations() => _observedByReason.clear();

  /// Returns immutable counts for the current analysis pass.
  PathExclusionSummary snapshot() {
    final counts = <String, int>{
      for (final entry in _observedByReason.entries)
        entry.key: entry.value.length,
    };
    return PathExclusionSummary(
      policyVersion: version,
      byReason: Map.unmodifiable(counts),
    );
  }

  String? _reasonFor(String normalized) {
    final lexicalReason = _lexicalReason(normalized);
    if (lexicalReason != null) return lexicalReason;

    final type = FileSystemEntity.typeSync(normalized, followLinks: false);
    if (type == FileSystemEntityType.link) return 'symlink';
    if (type != FileSystemEntityType.notFound) {
      try {
        final resolved = switch (type) {
          FileSystemEntityType.directory => Directory(
            normalized,
          ).resolveSymbolicLinksSync(),
          _ => File(normalized).resolveSymbolicLinksSync(),
        };
        if (!_isWithinCanonicalRoot(resolved)) return 'symlink-escape';
      } on FileSystemException {
        return 'unreadable-path';
      }
    }

    final basename = p.basename(normalized);
    if (_excludedDirectoryNames.contains(basename) &&
        type == FileSystemEntityType.directory) {
      return 'directory:$basename';
    }
    return null;
  }

  String? _lexicalReason(String normalized) {
    if (!_isWithinRoot(normalized)) return 'outside-project';

    for (final excluded in _additionalExcludedPaths) {
      if (normalized == excluded || p.isWithin(excluded, normalized)) {
        return 'run-output';
      }
    }

    final relative = p.relative(normalized, from: _rootPath);
    final segments = p.split(relative);
    for (final segment in segments.take(segments.length - 1)) {
      if (_excludedDirectoryNames.contains(segment)) {
        return 'directory:$segment';
      }
    }

    final basename = p.basename(normalized);
    if (_excludedFileNames.contains(basename)) return 'tool-file:$basename';
    if (basename.startsWith('.flutter_pruner') &&
        !_excludedDirectoryNames.contains(basename)) {
      return 'tool-file:flutter-pruner';
    }
    return null;
  }

  bool _record(String normalized, String? reason) {
    if (reason == null) return false;
    (_observedByReason[reason] ??= {}).add(normalized);
    return true;
  }

  bool _isWithinRoot(String path) =>
      path == _rootPath || p.isWithin(_rootPath, path);

  bool _isWithinCanonicalRoot(String path) =>
      path == _canonicalRootPath || p.isWithin(_canonicalRootPath, path);

  static String _canonicalDirectory(Directory directory) {
    final absolute = p.normalize(p.absolute(directory.path));
    try {
      return directory.resolveSymbolicLinksSync();
    } on FileSystemException {
      return absolute;
    }
  }
}
