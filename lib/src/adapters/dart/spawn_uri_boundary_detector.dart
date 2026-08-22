import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../core/project/project_context.dart';
import 'analyzer_ast_compat.dart';
import 'dart_ids.dart';

/// One resolved or fail-closed `dart:isolate Isolate.spawnUri` boundary.
final class DetectedSpawnUriBoundary {
  /// Creates an immutable boundary fact.
  DetectedSpawnUriBoundary({
    required this.identity,
    required this.location,
    required Set<Uri> uriAlternatives,
    required this.uriComplete,
    required this.optionsComplete,
    required this.identityResolved,
  }) : uriAlternatives = Set.unmodifiable(uriAlternatives);

  /// Stable source-location identity for auxiliary target IDs.
  final String identity;

  /// Project-relative source location.
  final String location;

  /// Finite, syntax-proven URI values.
  final Set<Uri> uriAlternatives;

  /// Whether [uriAlternatives] completely represent the URI expression.
  final bool uriComplete;

  /// Whether package and environment options retain inherited defaults.
  final bool optionsComplete;

  /// Whether the invoked method is analyzer-resolved to `dart:isolate`.
  final bool identityResolved;
}

/// Immutable `spawnUri` detection for one resolved library.
final class SpawnUriBoundaryDetection {
  /// Creates an ordered immutable result.
  SpawnUriBoundaryDetection(List<DetectedSpawnUriBoundary> boundaries)
    : boundaries = List.unmodifiable(boundaries);

  /// Boundaries in deterministic compilation-unit/source order.
  final List<DetectedSpawnUriBoundary> boundaries;
}

/// Detects only analyzer-resolved `dart:isolate Isolate.spawnUri` calls.
final class SpawnUriBoundaryDetector {
  /// Creates a detector for selected sources in [project].
  const SpawnUriBoundaryDetector(this.project);

  /// Project whose source locations are admitted.
  final ProjectContext project;

  /// Detects URI execution boundaries in [result].
  SpawnUriBoundaryDetection detect(SomeResolvedLibraryResult result) {
    if (result is! ResolvedLibraryResult) {
      return SpawnUriBoundaryDetection(const []);
    }
    final resolver = _SpawnUriValueResolver();
    for (final unit in result.units) {
      resolver.indexUnit(unit.unit);
    }
    final boundaries = <DetectedSpawnUriBoundary>[];
    for (final unit in result.units) {
      if (!DartIds.isModeledProjectPath(project, unit.path) &&
          !DartIds.isGeneratedProjectPath(project, unit.path)) {
        continue;
      }
      unit.unit.accept(
        _SpawnUriInvocationVisitor(
          project: project,
          resolver: resolver,
          location: project.relative(unit.path),
          boundaries: boundaries,
        ),
      );
    }
    return SpawnUriBoundaryDetection(boundaries);
  }
}

final class _SpawnUriInvocationVisitor extends RecursiveAstVisitor<void> {
  _SpawnUriInvocationVisitor({
    required this.project,
    required this.resolver,
    required this.location,
    required this.boundaries,
  });

  final ProjectContext project;
  final _SpawnUriValueResolver resolver;
  final String location;
  final List<DetectedSpawnUriBoundary> boundaries;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (node.methodName.name != 'spawnUri') {
      super.visitMethodInvocation(node);
      return;
    }
    final executable = node.methodName.element;
    final resolved = executable is ExecutableElement
        ? _isDartIsolateSpawnUri(executable)
        : false;
    if (executable != null && !resolved) {
      super.visitMethodInvocation(node);
      return;
    }
    if (!resolved && _targetName(node.target) != 'Isolate') {
      super.visitMethodInvocation(node);
      return;
    }

    final arguments = node.argumentList.arguments;
    final positional = [
      for (final argument in arguments)
        if (analyzerNamedArgumentName(argument) == null)
          analyzerArgumentExpression(argument),
    ];
    final values = positional.isEmpty
        ? const _UriValues.unresolved()
        : resolver.resolveUri(positional.first);
    boundaries.add(
      DetectedSpawnUriBoundary(
        identity: '$location:${node.offset}',
        location: location,
        uriAlternatives: values.values,
        uriComplete: values.complete,
        optionsComplete: _hasDefaultResolutionOptions(arguments),
        identityResolved: resolved,
      ),
    );
    super.visitMethodInvocation(node);
  }
}

bool _isDartIsolateSpawnUri(ExecutableElement element) =>
    element.displayName == 'spawnUri' &&
    element.enclosingElement?.name == 'Isolate' &&
    element.library.firstFragment.source.uri.toString() == 'dart:isolate';

bool _hasDefaultResolutionOptions(Iterable<AstNode> arguments) {
  for (final argument in arguments) {
    final name = analyzerNamedArgumentName(argument);
    if (name == null) continue;
    final value = analyzerArgumentExpression(argument);
    if (const {'environment', 'packageConfig', 'packageRoot'}.contains(name)) {
      if (value is! NullLiteral) return false;
    } else if (name == 'automaticPackageResolution') {
      if (value is! BooleanLiteral || value.value) return false;
    }
  }
  return true;
}

String? _targetName(Expression? target) => switch (target) {
  SimpleIdentifier(:final name) => name,
  PrefixedIdentifier(:final identifier) => identifier.name,
  PropertyAccess(:final propertyName) => propertyName.name,
  ParenthesizedExpression(:final expression) => _targetName(expression),
  _ => null,
};

final class _SpawnUriValueResolver {
  static const int _maxDepth = 32;
  static const int _maxValues = 64;

  final Map<Element, Expression> _variableInitializers = {};

  void indexUnit(CompilationUnit unit) {
    unit.accept(_SpawnUriDefinitionCollector(_variableInitializers));
  }

  _UriValues resolveUri(Expression expression) =>
      _resolveUri(expression, const {}, 0);

  _UriValues _resolveUri(
    Expression expression,
    Set<Element> visiting,
    int depth,
  ) {
    if (depth >= _maxDepth) return const _UriValues.unresolved();
    if (expression is ParenthesizedExpression) {
      return _resolveUri(expression.expression, visiting, depth + 1);
    }
    if (expression is AsExpression) {
      return _resolveUri(expression.expression, visiting, depth + 1);
    }
    if (expression is ConditionalExpression) {
      return _mergeUri([
        _resolveUri(expression.thenExpression, visiting, depth + 1),
        _resolveUri(expression.elseExpression, visiting, depth + 1),
      ]);
    }
    if (expression is MethodInvocation &&
        _isCoreUriMember(expression.methodName.element, 'parse')) {
      final positional = [
        for (final argument in expression.argumentList.arguments)
          if (analyzerNamedArgumentName(argument) == null)
            analyzerArgumentExpression(argument),
      ];
      if (positional.length != 1) return const _UriValues.unresolved();
      final strings = _resolveString(positional.single, visiting, depth + 1);
      if (!strings.complete) return const _UriValues.unresolved();
      try {
        return _UriValues.known(strings.values.map(Uri.parse).toSet());
      } on FormatException {
        return const _UriValues.unresolved();
      }
    }
    if (expression is InstanceCreationExpression) {
      final constructor = expression.constructorName.element;
      if (constructor is ConstructorElement &&
          constructor.name == 'file' &&
          constructor.enclosingElement.name == 'Uri' &&
          constructor.library.firstFragment.source.uri.toString() ==
              'dart:core') {
        if (expression.argumentList.arguments.any(
          (argument) => analyzerNamedArgumentName(argument) == 'windows',
        )) {
          return const _UriValues.unresolved();
        }
        final positional = [
          for (final argument in expression.argumentList.arguments)
            if (analyzerNamedArgumentName(argument) == null)
              analyzerArgumentExpression(argument),
        ];
        if (positional.length != 1) return const _UriValues.unresolved();
        final strings = _resolveString(positional.single, visiting, depth + 1);
        if (!strings.complete) return const _UriValues.unresolved();
        return _UriValues.known(
          strings.values.map((value) => Uri.file(value)).toSet(),
        );
      }
    }
    final element = _expressionElement(expression);
    if (element == null) return const _UriValues.unresolved();
    final base = element.baseElement;
    final initializer = _variableInitializers[base];
    if (initializer == null || visiting.contains(base)) {
      return const _UriValues.unresolved();
    }
    return _resolveUri(initializer, {...visiting, base}, depth + 1);
  }

  _StringValues _resolveString(
    Expression expression,
    Set<Element> visiting,
    int depth,
  ) {
    if (depth >= _maxDepth) return const _StringValues.unresolved();
    if (expression is SimpleStringLiteral) {
      return _StringValues.known({expression.value});
    }
    if (expression is ParenthesizedExpression) {
      return _resolveString(expression.expression, visiting, depth + 1);
    }
    if (expression is AsExpression) {
      return _resolveString(expression.expression, visiting, depth + 1);
    }
    if (expression is ConditionalExpression) {
      return _mergeString([
        _resolveString(expression.thenExpression, visiting, depth + 1),
        _resolveString(expression.elseExpression, visiting, depth + 1),
      ]);
    }
    final element = _expressionElement(expression);
    if (element == null) return const _StringValues.unresolved();
    final base = element.baseElement;
    final initializer = _variableInitializers[base];
    if (initializer == null || visiting.contains(base)) {
      return const _StringValues.unresolved();
    }
    return _resolveString(initializer, {...visiting, base}, depth + 1);
  }

  _UriValues _mergeUri(Iterable<_UriValues> alternatives) {
    final values = <Uri>{};
    for (final alternative in alternatives) {
      if (!alternative.complete) return const _UriValues.unresolved();
      values.addAll(alternative.values);
      if (values.length > _maxValues) return const _UriValues.unresolved();
    }
    return _UriValues.known(values);
  }

  _StringValues _mergeString(Iterable<_StringValues> alternatives) {
    final values = <String>{};
    for (final alternative in alternatives) {
      if (!alternative.complete) return const _StringValues.unresolved();
      values.addAll(alternative.values);
      if (values.length > _maxValues) return const _StringValues.unresolved();
    }
    return _StringValues.known(values);
  }
}

bool _isCoreUriMember(Element? element, String name) =>
    element is ExecutableElement &&
    element.displayName == name &&
    element.enclosingElement?.name == 'Uri' &&
    element.library.firstFragment.source.uri.toString() == 'dart:core';

Element? _expressionElement(Expression expression) => switch (expression) {
  SimpleIdentifier(:final element) => element,
  PrefixedIdentifier(:final identifier) => identifier.element,
  PropertyAccess(:final propertyName) => propertyName.element,
  _ => null,
};

final class _SpawnUriDefinitionCollector extends RecursiveAstVisitor<void> {
  _SpawnUriDefinitionCollector(this.variableInitializers);

  final Map<Element, Expression> variableInitializers;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final declarationList = node.parent;
    final fragment = node.declaredFragment;
    final initializer = node.initializer;
    if (declarationList is VariableDeclarationList &&
        (declarationList.isConst || declarationList.isFinal) &&
        fragment != null &&
        initializer != null) {
      variableInitializers[fragment.element.baseElement] = initializer;
    }
    super.visitVariableDeclaration(node);
  }
}

final class _UriValues {
  const _UriValues._({required this.values, required this.complete});
  const _UriValues.known(Set<Uri> values)
    : this._(values: values, complete: true);
  const _UriValues.unresolved() : this._(values: const {}, complete: false);

  final Set<Uri> values;
  final bool complete;
}

final class _StringValues {
  const _StringValues._({required this.values, required this.complete});
  const _StringValues.known(Set<String> values)
    : this._(values: values, complete: true);
  const _StringValues.unresolved() : this._(values: const {}, complete: false);

  final Set<String> values;
  final bool complete;
}
