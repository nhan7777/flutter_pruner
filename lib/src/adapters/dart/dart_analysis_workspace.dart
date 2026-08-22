import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import 'dart_package_ownership.dart';

/// Why a pass-scoped Dart semantic closure is incomplete.
enum DartBoundedClosureIssueKind {
  /// Analyzer resolution failed or did not produce a resolved library.
  uninspectable,

  /// A conditional import/export has target branches not modelled by the graph.
  conditionalDirective,

  /// Selected code has conditional branches not modelled by semantic adapters.
  selectedConditionalDirective,

  /// A referenced import/export has contradictory or missing ownership facts.
  unknownOwnershipBoundary,
}

/// One immutable issue in selected semantics or their bounded external closure.
final class DartBoundedClosureIssue {
  const DartBoundedClosureIssue._({
    required this.kind,
    required this.sourceIdentity,
    required this.location,
  });

  /// Incompleteness category.
  final DartBoundedClosureIssueKind kind;

  /// Canonical physical source identity used to de-duplicate this issue.
  final String sourceIdentity;

  /// Canonical physical source location that exposed the issue.
  final String location;
}

/// Immutable view of selected semantics and their bounded external closure.
final class DartBoundedClosureSnapshot {
  DartBoundedClosureSnapshot._({
    required List<ResolvedLibraryResult> libraries,
    required List<DartBoundedClosureIssue> issues,
  }) : libraries = List<ResolvedLibraryResult>.unmodifiable(libraries),
       issues = List<DartBoundedClosureIssue>.unmodifiable(issues);

  /// Successfully inspected external libraries in canonical identity order.
  final List<ResolvedLibraryResult> libraries;

  /// Canonical, de-duplicated incompleteness issues.
  final List<DartBoundedClosureIssue> issues;

  /// Whether every selected-seeded external library was inspectable and
  /// unconditional.
  bool get isComplete => issues.isEmpty;
}

/// One analyzer context and resolved-library cache shared by semantic adapters.
final class DartAnalysisWorkspace {
  /// Creates a workspace for one project analysis pass.
  DartAnalysisWorkspace(ProjectContext project)
    : _project = project,
      _ownership = DartPackageOwnership.discover(project),
      collection = AnalysisContextCollection(
        includedPaths: [p.normalize(p.absolute(project.root.path))],
      );

  final ProjectContext _project;
  final DartPackageOwnership _ownership;

  /// Analyzer contexts rooted at the selected project.
  final AnalysisContextCollection collection;

  final Map<String, Future<SomeResolvedLibraryResult>> _libraryCache = {};
  final Set<String> _boundedClosureLibraryKeys = {};
  final Map<String, DartBoundedClosureIssue> _boundedClosureIssues = {};
  List<String>? _dartFiles;

  /// Number of analyzer resolution requests that missed the workspace cache.
  int get resolutionCount => _libraryCache.length;

  /// Dart paths known to the analyzer, sorted and de-duplicated.
  List<String> get dartFiles => _dartFiles ??= List<String>.unmodifiable(
    ({
      for (final context in collection.contexts)
        for (final path in context.contextRoot.analyzedFiles())
          if (path.endsWith('.dart')) path,
      for (final file in _project.dartFiles)
        if (_isAdmissibleExcludedGeneratedPath(file.path))
          p.normalize(p.absolute(file.path)),
      for (final target in _project.targets)
        if (_isAdmissibleExcludedGeneratedPath(
          _project.resolve(target.entrypoint),
        ))
          p.normalize(p.absolute(_project.resolve(target.entrypoint))),
    }).toList()..sort(),
  );

  /// Resolves [path] at most once during this project analysis pass.
  Future<SomeResolvedLibraryResult> resolveLibrary(String path) {
    final normalizedPath = p.normalize(p.absolute(path));
    if (_hasSymlinkComponent(normalizedPath)) {
      throw StateError('Dart library path contains a symlink component.');
    }
    return _libraryCache.putIfAbsent(_canonicalPath(normalizedPath), () {
      return _analysisSessionFor(
        normalizedPath,
      ).getResolvedLibrary(normalizedPath);
    });
  }

  /// Resolves a directive target in the originating selected library session.
  ///
  /// A target-aware directive can select a package dependency that is outside
  /// the collection's analyzed-file roots. Keeping the originating session
  /// avoids creating a second context while still sharing the pass cache.
  Future<SomeResolvedLibraryResult> resolveSelectedDirectiveTarget(
    String path, {
    required LibraryElement fromLibrary,
  }) async {
    final result = await _libraryCache.putIfAbsent(_canonicalPath(path), () {
      final normalizedPath = p.normalize(p.absolute(path));
      return fromLibrary.session.getResolvedLibrary(normalizedPath);
    });
    if (result is ResolvedLibraryResult) {
      _boundedClosureLibraryKeys.add(libraryIdentity(result.element));
    }
    return result;
  }

  /// Resolves a selected-seeded external [element] in its originating session.
  ///
  /// This is the bounded path for dependencies outside [dartFiles]. It never
  /// creates another analyzer context or enumerates package roots.
  Future<SomeResolvedLibraryResult> resolveBoundedClosureLibrary(
    LibraryElement element,
  ) {
    final identity = libraryIdentity(element);
    _boundedClosureLibraryKeys.add(identity);
    return _libraryCache.putIfAbsent(identity, () {
      return element.session.getResolvedLibraryByElement(element);
    });
  }

  /// Records one fail-closed issue for an admitted bounded closure library.
  ///
  /// Calling this for an element that was not first admitted through
  /// [resolveBoundedClosureLibrary] is a programming error. That guard keeps
  /// unrelated package roots out of the shared snapshot.
  void recordBoundedClosureIssue({
    required LibraryElement library,
    required DartBoundedClosureIssueKind kind,
    required String location,
  }) {
    final identity = libraryIdentity(library);
    if (!_boundedClosureLibraryKeys.contains(identity)) {
      throw StateError(
        'Cannot record an issue outside the selected-seeded Dart closure.',
      );
    }
    final issue = DartBoundedClosureIssue._(
      kind: kind,
      sourceIdentity: identity,
      location: _canonicalPath(location),
    );
    _boundedClosureIssues.putIfAbsent('${kind.name}:$identity', () => issue);
  }

  /// Records a conditional directive in a caller-proven selected source.
  void recordSelectedConditionalDirective(String location) {
    final identity = _canonicalPath(location);
    const kind = DartBoundedClosureIssueKind.selectedConditionalDirective;
    _boundedClosureIssues.putIfAbsent(
      '${kind.name}:$identity',
      () => DartBoundedClosureIssue._(
        kind: kind,
        sourceIdentity: identity,
        location: identity,
      ),
    );
  }

  /// Records an ownership boundary reached from selected Dart semantics.
  ///
  /// Callers must only publish paths reached by a selected import/export or by
  /// an already admitted bounded-closure library. This keeps unrelated package
  /// roots out of the pass-scoped snapshot.
  void recordUnknownOwnershipBoundary(String location) {
    final identity = _canonicalPath(location);
    const kind = DartBoundedClosureIssueKind.unknownOwnershipBoundary;
    _boundedClosureIssues.putIfAbsent(
      '${kind.name}:$identity',
      () => DartBoundedClosureIssue._(
        kind: kind,
        sourceIdentity: identity,
        location: identity,
      ),
    );
  }

  /// Snapshots successful libraries and every known bounded-closure issue.
  ///
  /// Only libraries admitted through [resolveBoundedClosureLibrary] appear.
  /// An unexpected failed/non-resolved future without a recorded issue is
  /// rethrown rather than silently converted into a complete snapshot.
  Future<DartBoundedClosureSnapshot> boundedClosureSnapshot() async {
    final identities = _boundedClosureLibraryKeys.toList()..sort();
    final libraries = <ResolvedLibraryResult>[];
    for (final identity in identities) {
      final future = _libraryCache[identity];
      if (future == null) {
        throw StateError('Bounded Dart closure cache entry is missing.');
      }
      final SomeResolvedLibraryResult result;
      try {
        result = await future;
      } catch (error, stackTrace) {
        if (!_hasBoundedClosureIssue(identity)) {
          Error.throwWithStackTrace(error, stackTrace);
        }
        continue;
      }
      if (result is ResolvedLibraryResult) {
        libraries.add(result);
      } else if (!_hasBoundedClosureIssue(identity)) {
        throw StateError(
          'Non-resolved bounded Dart closure entry has no integrity issue.',
        );
      }
    }
    final issues = _boundedClosureIssues.values.toList()
      ..sort((left, right) {
        final identityOrder = left.sourceIdentity.compareTo(
          right.sourceIdentity,
        );
        if (identityOrder != 0) return identityOrder;
        return left.kind.index.compareTo(right.kind.index);
      });
    return DartBoundedClosureSnapshot._(libraries: libraries, issues: issues);
  }

  /// Canonical identity used to de-duplicate one resolved library worklist.
  String libraryIdentity(LibraryElement element) =>
      _canonicalPath(element.firstFragment.source.fullName);

  bool _hasBoundedClosureIssue(String libraryIdentity) => _boundedClosureIssues
      .values
      .any((issue) => issue.sourceIdentity == libraryIdentity);

  AnalysisSession _analysisSessionFor(String path) {
    try {
      return collection.contextFor(path).currentSession;
    } on StateError {
      if (!_isAdmissibleExcludedGeneratedPath(path)) rethrow;
      final canonicalPath = _canonicalPath(path);
      final containingContexts =
          collection.contexts.where((context) {
            final root = context.contextRoot.root.path;
            return _contains(root, path) ||
                _contains(_canonicalDirectoryPath(root), canonicalPath);
          }).toList()..sort((left, right) {
            final leftRoot = _canonicalDirectoryPath(
              left.contextRoot.root.path,
            );
            final rightRoot = _canonicalDirectoryPath(
              right.contextRoot.root.path,
            );
            final depth = rightRoot.length.compareTo(leftRoot.length);
            return depth != 0 ? depth : leftRoot.compareTo(rightRoot);
          });
      if (containingContexts.isEmpty) rethrow;
      return containingContexts.first.currentSession;
    }
  }

  bool _isAdmissibleExcludedGeneratedPath(String path) {
    final normalizedPath = p.normalize(p.absolute(path));
    return FileSystemEntity.typeSync(normalizedPath, followLinks: false) ==
            FileSystemEntityType.file &&
        !_project.pathPolicy.shouldExclude(normalizedPath) &&
        !_hasSymlinkComponent(normalizedPath) &&
        _ownership.isSelectedGeneratedSource(normalizedPath);
  }

  bool _hasSymlinkComponent(String path) {
    final root = p.normalize(p.absolute(_project.root.path));
    if (!_contains(root, path)) return true;
    var current = root;
    for (final segment in p.split(p.relative(path, from: root))) {
      current = p.join(current, segment);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        return true;
      }
    }
    return false;
  }
}

String _canonicalPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

String _canonicalDirectoryPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

bool _contains(String root, String path) =>
    p.equals(root, path) || p.isWithin(root, path);
