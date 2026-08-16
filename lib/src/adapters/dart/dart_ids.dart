import 'package:analyzer/dart/element/element.dart';

import '../../core/project/project_context.dart';

/// Constructs stable node IDs for Dart elements.
///
/// Format: `dart:<package>/<rel-path>#<name>` for declarations,
/// `dart:<package>/<rel-path>` for libraries.
class DartIds {
  DartIds._();

  /// Whether [element] belongs to a source file modeled by the Dart adapter.
  static bool isModeledProjectLibrary(
    ProjectContext project,
    LibraryElement element,
  ) => isModeledProjectPath(project, element.firstFragment.source.fullName);

  /// Whether [fragment] belongs to a source file modeled by the Dart adapter.
  static bool isModeledProjectFragment(
    ProjectContext project,
    Fragment fragment,
  ) {
    final source = fragment.libraryFragment?.source;
    return source != null && isModeledProjectPath(project, source.fullName);
  }

  /// Whether [path] is an editable project source inventoried as graph nodes.
  static bool isModeledProjectPath(ProjectContext project, String path) {
    if (!_isProjectPath(project, path)) return false;
    if (project.pathPolicy.shouldExclude(path)) return false;
    return !isGeneratedPath(path);
  }

  /// Whether [path] is generated project source that can consume modeled code.
  static bool isGeneratedProjectPath(ProjectContext project, String path) {
    if (!_isProjectPath(project, path)) return false;
    if (project.pathPolicy.shouldExclude(path)) return false;
    return isGeneratedPath(path);
  }

  /// Whether [path] is generated Dart output outside the editable graph.
  static bool isGeneratedPath(String path) {
    final normalized = path.replaceAll(r'\', '/').toLowerCase();
    return normalized.contains('/.dart_tool/') ||
        normalized.contains('/build/') ||
        normalized.endsWith('.g.dart') ||
        normalized.endsWith('.freezed.dart') ||
        normalized.endsWith('.gen.dart') ||
        normalized.endsWith('.mocks.dart') ||
        normalized.endsWith('.gr.dart') ||
        normalized.contains('/generated/') ||
        normalized.contains('/gen/');
  }

  /// Library node ID from its element.
  static String library(ProjectContext project, LibraryElement element) {
    final path = _relativePathFromElement(project, element);
    return 'dart:${project.packageName}/$path';
  }

  /// Library node ID for a physical project file not modeled by analyzer.
  static String libraryPath(ProjectContext project, String filePath) =>
      'dart:${project.packageName}/${project.relative(filePath)}';

  /// Declaration node ID from its fragment.
  static String declaration(ProjectContext project, Fragment fragment) {
    final path = _relativePathFromFragment(project, fragment);
    final name = fragment.name ?? '<unnamed>';
    return 'dart:${project.packageName}/$path#$name';
  }

  /// Returns the modeled top-level declaration owning [element].
  ///
  /// Members and constructors resolve to their enclosing class. Synthetic
  /// accessors resolve to their inducing top-level variable.
  static Fragment? declarationFragment(Element element) {
    Element? current = element is PropertyAccessorElement
        ? element.variable
        : element;
    while (current != null && current is! LibraryElement) {
      if (current is ClassElement) return current.firstFragment;
      if (current is EnumElement) return current.firstFragment;
      if (current is ExtensionElement) return current.firstFragment;
      if (current is ExtensionTypeElement) return current.firstFragment;
      if (current is MixinElement) return current.firstFragment;
      if (current is TopLevelFunctionElement) return current.firstFragment;
      if (current is TopLevelVariableElement) return current.firstFragment;
      if (current is TypeAliasElement) return current.firstFragment;
      current = current.enclosingElement;
    }
    return null;
  }

  static String _relativePathFromElement(
    ProjectContext project,
    LibraryElement element,
  ) {
    final source = element.firstFragment.source;
    if (_isProjectPath(project, source.fullName)) {
      return project.relative(source.fullName);
    }
    final uri = source.uri;
    if (uri.isScheme('file')) {
      return project.relative(uri.toFilePath());
    }
    return uri.toString();
  }

  static String _relativePathFromFragment(
    ProjectContext project,
    Fragment fragment,
  ) {
    final libFragment = fragment.libraryFragment;
    if (libFragment == null) {
      return '<unknown>';
    }
    final source = libFragment.source;
    if (_isProjectPath(project, source.fullName)) {
      return project.relative(source.fullName);
    }
    final uri = source.uri;
    if (uri.isScheme('file')) {
      return project.relative(uri.toFilePath());
    }
    return uri.toString();
  }

  static bool _isProjectPath(ProjectContext project, String path) {
    final relative = project.relative(path);
    return relative != '..' && !relative.startsWith('../');
  }
}
