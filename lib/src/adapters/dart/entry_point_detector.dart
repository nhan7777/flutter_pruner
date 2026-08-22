import 'package:analyzer/dart/element/element.dart';

import '../../core/graph/execution_target.dart';

/// One resolved declaration entered by a reviewed runtime capability.
final class DetectedDartExecutionEntryPoint {
  /// Creates an immutable entry-point fact.
  const DetectedDartExecutionEntryPoint({
    required this.element,
    required this.capability,
    required this.reason,
  });

  /// Resolved declaration element.
  final Element element;

  /// Runtime capability that can invoke the declaration.
  final CallbackBoundaryCapability capability;

  /// Stable root explanation.
  final String reason;
}

/// Extracts runtime entry-point facts without mutating the graph.
final class EntryPointDetector {
  /// Finds VM pragma and FFI native entry points in [library].
  Iterable<DetectedDartExecutionEntryPoint> detectAnnotatedCallbacks(
    LibraryElement library,
  ) sync* {
    final elements = <Element>[
      ...library.topLevelFunctions,
      ...library.topLevelVariables,
      ...library.getters,
      ...library.setters,
    ];
    for (final instance in <InstanceElement>[
      ...library.classes,
      ...library.enums,
      ...library.mixins,
      ...library.extensions,
      ...library.extensionTypes,
    ]) {
      elements.add(instance);
      if (instance is InterfaceElement) elements.addAll(instance.constructors);
      elements
        ..addAll(instance.fields)
        ..addAll(instance.getters)
        ..addAll(instance.setters)
        ..addAll(instance.methods);
    }
    for (final element in elements) {
      for (final annotation in element.metadata.annotations) {
        if (_isVmEntryPoint(annotation)) {
          yield DetectedDartExecutionEntryPoint(
            element: element,
            capability: CallbackBoundaryCapability.dartVm,
            reason: "@pragma('vm:entry-point')",
          );
          break;
        }
        if (_isFfiNative(annotation)) {
          yield DetectedDartExecutionEntryPoint(
            element: element,
            capability: CallbackBoundaryCapability.ffiNative,
            reason: '@Native FFI entry point',
          );
          break;
        }
      }
    }
  }
}

bool _isVmEntryPoint(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element is! ConstructorElement ||
      element.enclosingElement.name != 'pragma') {
    return false;
  }
  return annotation.computeConstantValue()?.getField('name')?.toStringValue() ==
      'vm:entry-point';
}

bool _isFfiNative(ElementAnnotation annotation) {
  final element = annotation.element;
  if (element is! ConstructorElement ||
      element.enclosingElement.name != 'Native') {
    return false;
  }
  return element.library.firstFragment.source.uri.toString() == 'dart:ffi';
}
