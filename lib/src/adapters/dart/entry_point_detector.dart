import 'package:analyzer/dart/element/element.dart';

import '../../core/graph/build_condition.dart';
import '../../core/project/project_context.dart';
import '../analyzer_adapter.dart';
import 'dart_ids.dart';

/// Detects entry points: main(), @pragma('vm:entry-point'), callback handles.
class EntryPointDetector {
  /// Creates a detector registering roots into [graph].
  EntryPointDetector({required this.project, required this.graph});

  /// Project the analysis runs against.
  final ProjectContext project;

  /// Graph surface to register roots into.
  final GraphBuilder graph;

  /// Check library for entry points and register roots.
  void detectInLibrary(LibraryElement library) {
    final libraryId = DartIds.library(project, library);

    // Check for main() function
    final entryPoint = library.entryPoint;
    if (entryPoint != null) {
      final fragment = entryPoint.firstFragment;
      final declId = DartIds.declaration(project, fragment);
      final relativePath = project.relative(
        library.firstFragment.source.fullName,
      );
      final condition = relativePath.startsWith('test/')
          ? BuildCondition.unconditional
          : BuildCondition(entrypoints: {relativePath});
      graph.addRoot(declId, reason: 'main() entry point', condition: condition);
      graph.addRoot(
        libraryId,
        reason: 'contains main() entry point',
        condition: condition,
      );
    }

    // Native entry-point pragmas are valid on functions, variables, accessors,
    // fields, and members. Every modeled owner must become a root: the native
    // caller is intentionally absent from the Dart reference graph.
    for (final function in library.topLevelFunctions) {
      _checkElement(function);
    }
    for (final variable in library.topLevelVariables) {
      _checkElement(variable);
    }
    for (final getter in library.getters) {
      _checkElement(getter);
    }
    for (final setter in library.setters) {
      _checkElement(setter);
    }

    final instanceElements = <InstanceElement>[
      ...library.classes,
      ...library.enums,
      ...library.mixins,
      ...library.extensions,
      ...library.extensionTypes,
    ];
    for (final instance in instanceElements) {
      _checkElement(instance);
      if (instance is InterfaceElement) {
        for (final constructor in instance.constructors) {
          _checkElement(constructor);
        }
      }
      for (final field in instance.fields) {
        _checkElement(field);
      }
      for (final getter in instance.getters) {
        _checkElement(getter);
      }
      for (final setter in instance.setters) {
        _checkElement(setter);
      }
      for (final method in instance.methods) {
        _checkElement(method);
      }
    }
  }

  void _checkElement(Element element) {
    // Check for @pragma('vm:entry-point')
    for (final annotation in element.metadata.annotations) {
      if (_isPragmaEntryPoint(annotation)) {
        final fragment = DartIds.declarationFragment(element);
        if (fragment != null &&
            DartIds.isModeledProjectFragment(project, fragment)) {
          final declId = DartIds.declaration(project, fragment);
          graph.addRoot(declId, reason: "@pragma('vm:entry-point')");
        }
        return;
      }
    }
  }

  bool _isPragmaEntryPoint(ElementAnnotation annotation) {
    final element = annotation.element;
    if (element is! ConstructorElement) return false;
    if (element.enclosingElement.name != 'pragma') return false;

    // Check if the argument is 'vm:entry-point'
    final value = annotation.computeConstantValue();
    if (value == null) return false;

    final nameField = value.getField('name');
    return nameField?.toStringValue() == 'vm:entry-point';
  }
}
