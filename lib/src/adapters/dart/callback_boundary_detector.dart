import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../core/graph/execution_target.dart';
import '../../core/project/project_context.dart';
import 'analyzer_ast_compat.dart';
import 'dart_ids.dart';

/// One resolved or conservatively incomplete native callback boundary.
final class DetectedCallbackBoundary {
  /// Creates an immutable callback fact.
  DetectedCallbackBoundary({
    required this.descriptor,
    required Set<String> callbackNodeIds,
    required this.owningLibraryId,
    required this.location,
    required this.unresolved,
  }) : callbackNodeIds = Set.unmodifiable(callbackNodeIds);

  /// Reviewed boundary identity and capability.
  final CallbackBoundaryDescriptor descriptor;

  /// Resolved callback declaration IDs.
  final Set<String> callbackNodeIds;

  /// Library containing the registration call.
  final String owningLibraryId;

  /// Project-relative source location.
  final String location;

  /// Whether identity or callback propagation was incomplete.
  final bool unresolved;
}

/// Immutable callback detection result for one library.
final class CallbackBoundaryDetection {
  /// Creates a detection snapshot.
  CallbackBoundaryDetection(List<DetectedCallbackBoundary> boundaries)
    : boundaries = List.unmodifiable(boundaries);

  /// Callback facts in deterministic source order.
  final List<DetectedCallbackBoundary> boundaries;
}

/// Extracts callback-boundary facts without mutating the graph.
final class CallbackBoundaryDetector {
  /// Creates a detector for [project].
  const CallbackBoundaryDetector(this.project);

  /// Project whose declarations may become callback roots.
  final ProjectContext project;

  /// Detects callback registrations in [result].
  CallbackBoundaryDetection detect(SomeResolvedLibraryResult result) {
    if (result is! ResolvedLibraryResult) {
      return CallbackBoundaryDetection(const []);
    }
    final resolver = _CallbackValueResolver();
    for (final unit in result.units) {
      resolver.indexUnit(unit.unit);
    }
    final boundaries = <DetectedCallbackBoundary>[];
    final ownerId = DartIds.library(project, result.element);
    for (final unit in result.units) {
      if (!DartIds.isModeledProjectPath(project, unit.path)) continue;
      unit.unit.accept(
        _CallbackInvocationVisitor(
          project: project,
          resolver: resolver,
          owningLibraryId: ownerId,
          location: project.relative(unit.path),
          boundaries: boundaries,
        ),
      );
    }
    return CallbackBoundaryDetection(boundaries);
  }
}

final class _CallbackInvocationVisitor extends RecursiveAstVisitor<void> {
  _CallbackInvocationVisitor({
    required this.project,
    required this.resolver,
    required this.owningLibraryId,
    required this.location,
    required this.boundaries,
  });

  final ProjectContext project;
  final _CallbackValueResolver resolver;
  final String owningLibraryId;
  final String location;
  final List<DetectedCallbackBoundary> boundaries;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final descriptor = _CallbackBoundaryRegistry.match(node);
    if (descriptor != null &&
        node.argumentList.arguments.length > descriptor.argumentIndex) {
      final argument = node.argumentList.arguments[descriptor.argumentIndex];
      final targets = resolver.resolve(
        analyzerArgumentExpression(argument),
        project,
      );
      boundaries.add(
        DetectedCallbackBoundary(
          descriptor: descriptor,
          callbackNodeIds: targets.nodeIds,
          owningLibraryId: owningLibraryId,
          location: location,
          unresolved:
              targets.unresolved ||
              descriptor.capability == CallbackBoundaryCapability.unknown,
        ),
      );
    }
    super.visitMethodInvocation(node);
  }
}

final class _CallbackBoundaryRegistry {
  static CallbackBoundaryDescriptor? match(MethodInvocation node) {
    final element = node.methodName.element;
    final executable = element is ExecutableElement ? element : null;
    final resolvedOwner = executable?.enclosingElement?.name;
    final resolvedMethod = executable?.displayName;
    final syntaxOwner = _targetName(node.target);
    final syntaxMethod = node.methodName.name;
    final library = executable?.library.firstFragment.source.uri.toString();

    bool matches(String owner, String method) =>
        (resolvedOwner == owner && resolvedMethod == method) ||
        (syntaxOwner == owner && syntaxMethod == method);

    if (matches('PluginUtilities', 'getCallbackHandle')) {
      final resolved =
          resolvedOwner == 'PluginUtilities' &&
          resolvedMethod == 'getCallbackHandle' &&
          library == 'dart:ui';
      return CallbackBoundaryDescriptor(
        argumentIndex: 0,
        description: resolved
            ? 'dart:ui PluginUtilities.getCallbackHandle'
            : 'same-named PluginUtilities.getCallbackHandle',
        capability: resolved
            ? CallbackBoundaryCapability.flutterEngineNative
            : CallbackBoundaryCapability.unknown,
      );
    }
    if (matches('Isolate', 'spawn')) {
      final resolved =
          resolvedOwner == 'Isolate' &&
          resolvedMethod == 'spawn' &&
          library == 'dart:isolate';
      return CallbackBoundaryDescriptor(
        argumentIndex: 0,
        description: resolved
            ? 'dart:isolate Isolate.spawn'
            : 'same-named Isolate.spawn',
        capability: resolved
            ? CallbackBoundaryCapability.dartVm
            : CallbackBoundaryCapability.unknown,
      );
    }
    if (matches('Workmanager', 'initialize')) {
      final resolved =
          resolvedOwner == 'Workmanager' &&
          resolvedMethod == 'initialize' &&
          library?.startsWith('package:workmanager/') == true;
      return CallbackBoundaryDescriptor(
        argumentIndex: 0,
        description: resolved
            ? 'package:workmanager Workmanager.initialize'
            : 'same-named Workmanager.initialize',
        capability: resolved
            ? CallbackBoundaryCapability.workmanagerMobile
            : CallbackBoundaryCapability.unknown,
      );
    }
    return null;
  }
}

String? _targetName(Expression? target) => switch (target) {
  SimpleIdentifier(:final name) => name,
  PrefixedIdentifier(:final identifier) => identifier.name,
  PropertyAccess(:final propertyName) => propertyName.name,
  InstanceCreationExpression(:final constructorName) =>
    constructorName.type.name.lexeme,
  MethodInvocation(target: null, :final methodName) => methodName.name,
  FunctionExpressionInvocation(:final function) => _targetName(function),
  ParenthesizedExpression(:final expression) => _targetName(expression),
  _ => null,
};

final class _CallbackValueResolver {
  static const int _maxDepth = 32;
  static const int _maxTargets = 64;

  final Map<Element, Expression> _variableInitializers = {};
  final Map<Element, Expression> _executableReturns = {};
  final Map<Element, List<Expression>> _parameterValues = {};

  void indexUnit(CompilationUnit unit) {
    unit.accept(
      _CallbackDefinitionCollector(
        variableInitializers: _variableInitializers,
        executableReturns: _executableReturns,
        parameterValues: _parameterValues,
      ),
    );
  }

  _CallbackTargets resolve(Expression expression, ProjectContext project) =>
      _resolve(expression, project, const {}, 0);

  _CallbackTargets _resolve(
    Expression expression,
    ProjectContext project,
    Set<Element> visiting,
    int depth,
  ) {
    if (depth >= _maxDepth) return const _CallbackTargets.unresolved();
    if (expression is ParenthesizedExpression) {
      return _resolve(expression.expression, project, visiting, depth + 1);
    }
    if (expression is AsExpression) {
      return _resolve(expression.expression, project, visiting, depth + 1);
    }
    if (expression is ConditionalExpression) {
      return _merge([
        _resolve(expression.thenExpression, project, visiting, depth + 1),
        _resolve(expression.elseExpression, project, visiting, depth + 1),
      ]);
    }
    if (expression is MethodInvocation) {
      return _resolveInvocation(
        expression.methodName.element,
        project,
        visiting,
        depth,
      );
    }
    if (expression is FunctionExpressionInvocation) {
      return _resolveInvocation(expression.element, project, visiting, depth);
    }
    if (expression is FunctionExpression) return const _CallbackTargets.known();

    final element = switch (expression) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    if (element == null) return const _CallbackTargets.unresolved();
    return _resolveElement(element, project, visiting, depth + 1);
  }

  _CallbackTargets _resolveInvocation(
    Element? element,
    ProjectContext project,
    Set<Element> visiting,
    int depth,
  ) {
    if (element == null) return const _CallbackTargets.unresolved();
    final base = element.baseElement;
    final expression = _executableReturns[base];
    if (expression == null || visiting.contains(base)) {
      return const _CallbackTargets.unresolved();
    }
    return _resolve(expression, project, {...visiting, base}, depth + 1);
  }

  _CallbackTargets _resolveElement(
    Element element,
    ProjectContext project,
    Set<Element> visiting,
    int depth,
  ) {
    final base = element.baseElement;
    final parameterValues = _parameterValues[base];
    if (parameterValues != null) {
      if (visiting.contains(base)) return const _CallbackTargets.unresolved();
      return _merge(
        parameterValues.map(
          (value) => _resolve(value, project, {...visiting, base}, depth + 1),
        ),
      );
    }
    final initializer = _variableInitializers[base];
    if (initializer != null) {
      if (visiting.contains(base)) return const _CallbackTargets.unresolved();
      return _resolve(initializer, project, {...visiting, base}, depth + 1);
    }
    final expression = _executableReturns[base];
    if (expression != null) {
      if (visiting.contains(base)) return const _CallbackTargets.unresolved();
      return _resolve(expression, project, {...visiting, base}, depth + 1);
    }

    final variable = base is PropertyAccessorElement ? base.variable : base;
    if (variable is VariableElement || base is FormalParameterElement) {
      return const _CallbackTargets.unresolved();
    }
    final fragment = DartIds.declarationFragment(base);
    if (fragment == null) {
      return base.library?.isInSdk == true
          ? const _CallbackTargets.known()
          : const _CallbackTargets.unresolved();
    }
    if (!DartIds.isModeledProjectFragment(project, fragment)) {
      return const _CallbackTargets.known();
    }
    return _CallbackTargets.known({DartIds.declaration(project, fragment)});
  }

  _CallbackTargets _merge(Iterable<_CallbackTargets> values) {
    final nodeIds = <String>{};
    var unresolved = false;
    for (final value in values) {
      nodeIds.addAll(value.nodeIds);
      unresolved = unresolved || value.unresolved;
      if (nodeIds.length > _maxTargets) {
        return _CallbackTargets(nodeIds: nodeIds, unresolved: true);
      }
    }
    return _CallbackTargets(nodeIds: nodeIds, unresolved: unresolved);
  }
}

final class _CallbackDefinitionCollector extends RecursiveAstVisitor<void> {
  _CallbackDefinitionCollector({
    required this.variableInitializers,
    required this.executableReturns,
    required this.parameterValues,
  });

  final Map<Element, Expression> variableInitializers;
  final Map<Element, Expression> executableReturns;
  final Map<Element, List<Expression>> parameterValues;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final fragment = node.declaredFragment;
    final initializer = node.initializer;
    if (fragment != null && initializer != null) {
      variableInitializers[fragment.element.baseElement] = initializer;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final fragment = node.declaredFragment;
    final body = node.functionExpression.body;
    if (fragment != null && body is ExpressionFunctionBody) {
      executableReturns[fragment.element.baseElement] = body.expression;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final fragment = node.declaredFragment;
    final body = node.body;
    if (fragment != null && body is ExpressionFunctionBody) {
      executableReturns[fragment.element.baseElement] = body.expression;
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    _recordArguments(
      element is ExecutableElement ? element : null,
      node.argumentList.arguments,
    );
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    _recordArguments(node.element, node.argumentList.arguments);
    super.visitFunctionExpressionInvocation(node);
  }

  void _recordArguments(
    ExecutableElement? executable,
    Iterable<AstNode> arguments,
  ) {
    if (executable == null) return;
    final parameters = executable.formalParameters;
    var positionalIndex = 0;
    for (final argument in arguments) {
      FormalParameterElement? parameter;
      final value = analyzerArgumentExpression(argument);
      final named = analyzerNamedArgumentName(argument);
      if (named != null) {
        for (final candidate in parameters) {
          if (candidate.isNamed && candidate.name == named) {
            parameter = candidate;
            break;
          }
        }
      } else {
        while (positionalIndex < parameters.length &&
            !parameters[positionalIndex].isPositional) {
          positionalIndex++;
        }
        if (positionalIndex < parameters.length) {
          parameter = parameters[positionalIndex++];
        }
      }
      if (parameter != null) {
        (parameterValues[parameter.baseElement] ??= []).add(value);
      }
    }
  }
}

final class _CallbackTargets {
  const _CallbackTargets({required this.nodeIds, required this.unresolved});
  const _CallbackTargets.known([this.nodeIds = const {}]) : unresolved = false;
  const _CallbackTargets.unresolved() : nodeIds = const {}, unresolved = true;

  final Set<String> nodeIds;
  final bool unresolved;
}
