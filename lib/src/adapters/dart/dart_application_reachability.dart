import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import 'dart_analysis_workspace.dart';

/// The project Dart units reachable from configured application entrypoints.
final class DartApplicationReachability {
  DartApplicationReachability._({
    required Set<String> unitPaths,
    required List<String> issues,
  }) : unitPaths = Set.unmodifiable(unitPaths),
       issues = List.unmodifiable(issues);

  /// Normalized absolute paths of reachable libraries and their part units.
  final Set<String> unitPaths;

  /// Conditions that prevented a complete import/export closure.
  final List<String> issues;

  /// Whether [unitPaths] is safe to use as an exclusion boundary.
  bool get isComplete => issues.isEmpty;

  /// Builds an analyzer-resolved import/export closure for [project].
  ///
  /// Analyzer library elements provide package-config-aware resolution, so no
  /// parallel URI resolver is maintained here. Traversal stays inside the
  /// selected project because dependencies cannot legally import their owner
  /// package through a cyclic package graph.
  static Future<DartApplicationReachability> discover(
    ProjectContext project, {
    required DartAnalysisWorkspace workspace,
  }) async {
    final reachableUnits = <String>{};
    final issues = <String>[];
    final visitedLibraries = <String>{};
    final workspacePathsByCanonical = <String, String>{
      for (final path in workspace.dartFiles) _normalize(path): path,
    };
    final pendingLibraries =
        project.targets
            .map(
              (target) =>
                  p.normalize(p.absolute(project.resolve(target.entrypoint))),
            )
            .toSet()
            .toList()
          ..sort();

    while (pendingLibraries.isNotEmpty) {
      final libraryPath = pendingLibraries.removeAt(0);
      final canonicalLibraryPath = _normalize(libraryPath);
      if (!visitedLibraries.add(canonicalLibraryPath)) continue;
      if (!_isInsideProject(project, libraryPath)) continue;
      if (!File(libraryPath).existsSync()) {
        issues.add(
          'configured application entrypoint or local Dart library is missing: '
          '${project.relative(libraryPath)}',
        );
        continue;
      }

      final SomeResolvedLibraryResult result;
      try {
        result = await workspace.resolveLibrary(libraryPath);
      } catch (_) {
        issues.add(
          'analyzer failed to resolve application library: '
          '${project.relative(libraryPath)}',
        );
        continue;
      }
      if (result is! ResolvedLibraryResult) {
        issues.add(
          'analyzer could not resolve application library: '
          '${project.relative(libraryPath)}',
        );
        continue;
      }

      for (final unit in result.units) {
        final unitPath = _normalize(unit.path);
        if (_isInsideProject(project, unitPath)) reachableUnits.add(unitPath);
        if (unit.unit.directives.any(_hasConditionalConfiguration)) {
          issues.add(
            'conditional Dart imports or exports prevent complete application '
            'reachability: ${project.relative(unit.path)}',
          );
        }
        for (final directive in unit.unit.directives) {
          final uri = _localDirectiveUri(directive);
          if (uri == null) continue;
          final expectedPath = _localDirectivePath(project, unit.path, uri);
          if (expectedPath != null && !File(expectedPath).existsSync()) {
            issues.add(
              'local Dart directive could not be resolved: '
              '${project.relative(unit.path)} -> $uri',
            );
          }
        }
      }

      final dependencies = <String>{
        for (final imported in result.element.firstFragment.importedLibraries)
          _normalize(imported.firstFragment.source.fullName),
        for (final exported in result.element.exportedLibraries)
          _normalize(exported.firstFragment.source.fullName),
      }.where((path) => _isInsideProject(project, path)).toList()..sort();
      for (final dependency in dependencies) {
        if (!visitedLibraries.contains(dependency)) {
          pendingLibraries.add(
            workspacePathsByCanonical[dependency] ?? dependency,
          );
        }
      }
    }

    return DartApplicationReachability._(
      unitPaths: reachableUnits,
      issues: issues.toSet().toList()..sort(),
    );
  }
}

bool _hasConditionalConfiguration(Directive directive) =>
    directive is ImportDirective && directive.configurations.isNotEmpty ||
    directive is ExportDirective && directive.configurations.isNotEmpty;

String? _localDirectiveUri(Directive directive) => switch (directive) {
  ImportDirective(:final uri) => uri.stringValue,
  ExportDirective(:final uri) => uri.stringValue,
  PartDirective(:final uri) => uri.stringValue,
  _ => null,
};

String? _localDirectivePath(
  ProjectContext project,
  String containingPath,
  String uri,
) {
  final parsed = Uri.tryParse(uri);
  if (parsed == null) return null;
  if (parsed.scheme.isEmpty) {
    return _normalize(p.join(p.dirname(containingPath), uri));
  }
  if (parsed.scheme == 'package' &&
      parsed.pathSegments.firstOrNull == project.packageName) {
    return _normalize(
      p.joinAll([project.root.path, 'lib', ...parsed.pathSegments.skip(1)]),
    );
  }
  return null;
}

bool _isInsideProject(ProjectContext project, String path) {
  final root = _normalize(project.root.path);
  final normalized = _normalize(path);
  return p.equals(root, normalized) || p.isWithin(root, normalized);
}

String _normalize(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}
