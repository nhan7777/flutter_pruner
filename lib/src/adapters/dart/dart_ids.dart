import 'package:analyzer/dart/element/element.dart';

import '../../core/project/generated_dart_path.dart';
import '../../core/project/project_context.dart';
import 'dart_package_ownership.dart';

/// Constructs stable node IDs for Dart elements.
///
/// Format: `dart:<package>/<rel-path>#<name>` for declarations,
/// `dart:<package>/<rel-path>` for libraries.
class DartIds {
  DartIds._();

  /// Whether [element] belongs to a source file modeled by the Dart adapter.
  static bool isModeledProjectLibrary(
    ProjectContext project,
    LibraryElement element, {
    DartPackageOwnership? ownership,
  }) => isModeledProjectPath(
    project,
    element.firstFragment.source.fullName,
    ownership: ownership,
  );

  /// Whether [fragment] belongs to a source file modeled by the Dart adapter.
  static bool isModeledProjectFragment(
    ProjectContext project,
    Fragment fragment, {
    DartPackageOwnership? ownership,
  }) {
    final source = fragment.libraryFragment?.source;
    return source != null &&
        isModeledProjectPath(project, source.fullName, ownership: ownership);
  }

  /// Whether [path] is an editable project source inventoried as graph nodes.
  static bool isModeledProjectPath(
    ProjectContext project,
    String path, {
    DartPackageOwnership? ownership,
  }) {
    final effectiveOwnership =
        ownership ?? DartPackageOwnership.discover(project);
    if (!effectiveOwnership.isSelectedSource(path)) return false;
    if (project.pathPolicy.shouldExclude(path)) return false;
    return true;
  }

  /// Whether [path] is generated project source that can consume modeled code.
  static bool isGeneratedProjectPath(
    ProjectContext project,
    String path, {
    DartPackageOwnership? ownership,
  }) {
    final effectiveOwnership =
        ownership ?? DartPackageOwnership.discover(project);
    if (!effectiveOwnership.isSelectedGeneratedSource(path)) return false;
    if (project.pathPolicy.shouldExclude(path)) return false;
    return true;
  }

  /// Whether [path] is generated Dart output outside the editable graph.
  static bool isGeneratedPath(String path) => isGeneratedDartPath(path);

  /// Library node ID from its element.
  static String library(
    ProjectContext project,
    LibraryElement element, {
    DartPackageOwnership? ownership,
  }) {
    final path = _relativePathFromElement(
      project,
      element,
      ownership: ownership,
    );
    return 'dart:${project.packageName}/$path';
  }

  /// Library node ID for a physical project file not modeled by analyzer.
  static String libraryPath(
    ProjectContext project,
    String filePath, {
    DartPackageOwnership? ownership,
  }) {
    _requireSelectedOwnership(project, filePath, ownership: ownership);
    return 'dart:${project.packageName}/${project.relative(filePath)}';
  }

  /// Stable non-reportable node ID for selected standalone generated output.
  static String generatedArtifact(ProjectContext project, String filePath) {
    final ownership = DartPackageOwnership.discover(project);
    if (!ownership.isSelectedGeneratedSource(filePath)) {
      throw StateError(
        'Cannot create a selected-package generated artifact ID for '
        '${ownership.ownerOf(filePath).ownership.name} source.',
      );
    }
    return 'dart-generated:${project.packageName}/${project.relative(filePath)}';
  }

  /// Stable non-reportable node ID for an external package dependency.
  static String packageBoundary(ProjectContext project, String packageName) =>
      'dart-package:${project.packageName}/$packageName';

  /// Declaration node ID from its fragment.
  static String declaration(
    ProjectContext project,
    Fragment fragment, {
    DartPackageOwnership? ownership,
  }) {
    final path = _relativePathFromFragment(
      project,
      fragment,
      ownership: ownership,
    );
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
    LibraryElement element, {
    DartPackageOwnership? ownership,
  }) {
    final source = element.firstFragment.source;
    _requireSelectedOwnership(project, source.fullName, ownership: ownership);
    return project.relative(source.fullName);
  }

  static String _relativePathFromFragment(
    ProjectContext project,
    Fragment fragment, {
    DartPackageOwnership? ownership,
  }) {
    final libFragment = fragment.libraryFragment;
    if (libFragment == null) {
      throw StateError(
        'Cannot create a selected-package Dart ID without an owning library.',
      );
    }
    final source = libFragment.source;
    _requireSelectedOwnership(project, source.fullName, ownership: ownership);
    return project.relative(source.fullName);
  }

  static void _requireSelectedOwnership(
    ProjectContext project,
    String path, {
    DartPackageOwnership? ownership,
  }) {
    final owner = (ownership ?? DartPackageOwnership.discover(project)).ownerOf(
      path,
    );
    if (owner.ownership != DartSourceOwnership.selectedPackage) {
      throw StateError(
        'Cannot create a selected-package Dart ID for ${owner.ownership.name} source.',
      );
    }
  }
}
