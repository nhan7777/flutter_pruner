import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';

/// One analyzer context and resolved-library cache shared by semantic adapters.
final class DartAnalysisWorkspace {
  /// Creates a workspace for one project analysis pass.
  DartAnalysisWorkspace(ProjectContext project)
    : collection = AnalysisContextCollection(
        includedPaths: [p.normalize(p.absolute(project.root.path))],
      );

  /// Analyzer contexts rooted at the selected project.
  final AnalysisContextCollection collection;

  final Map<String, Future<SomeResolvedLibraryResult>> _libraryCache = {};
  List<String>? _dartFiles;

  /// Number of analyzer resolution requests that missed the workspace cache.
  int get resolutionCount => _libraryCache.length;

  /// Dart paths known to the analyzer, sorted and de-duplicated.
  List<String> get dartFiles => _dartFiles ??= List<String>.unmodifiable(
    ({
      for (final context in collection.contexts)
        for (final path in context.contextRoot.analyzedFiles())
          if (path.endsWith('.dart')) path,
    }).toList()..sort(),
  );

  /// Resolves [path] at most once during this project analysis pass.
  Future<SomeResolvedLibraryResult> resolveLibrary(String path) =>
      _libraryCache.putIfAbsent(path, () {
        final context = collection.contextFor(path);
        return context.currentSession.getResolvedLibrary(path);
      });
}
