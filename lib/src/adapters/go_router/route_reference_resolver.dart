import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import '../dart/analyzer_ast_compat.dart';
import '../dart/dart_analysis_workspace.dart';
import '../dart/dart_ids.dart';
import 'route_inventory.dart';
import 'route_path.dart';

const Set<String> _pathNavigationMethods = {
  'go',
  'push',
  'replace',
  'pushReplacement',
};

const Set<String> _namedNavigationMethods = {
  'goNamed',
  'pushNamed',
  'replaceNamed',
  'pushReplacementNamed',
  'namedLocation',
};

/// One resolved navigation reference.
class RouteReference {
  /// Creates a reference record.
  RouteReference({
    required this.routeNodeId,
    required this.callerId,
    required this.location,
    required this.description,
  });

  /// Route kept alive by this reference.
  final String routeNodeId;

  /// Declaration that performs the navigation.
  final String callerId;

  /// `path:line:column` of the call site.
  final String location;

  /// Human-readable explanation for report output.
  final String description;
}

/// Resolves go_router navigation call sites against a route inventory.
class RouteReferenceResolver {
  /// Creates a resolver for [project] and [inventory].
  RouteReferenceResolver(this.project, this.inventory);

  /// Project under analysis.
  final ProjectContext project;

  /// Routes this resolver can address.
  final RouteInventory inventory;

  /// Exact references resolved from constant arguments.
  final List<RouteReference> references = [];

  /// Unresolved navigation constructs.
  final List<RouteBlocker> blockers = [];

  /// Visits every project library and collects navigation facts.
  Future<void> analyzeProject({
    required DartAnalysisWorkspace workspace,
    Set<String>? includedUnitPaths,
  }) async {
    final units = <String, ResolvedUnitResult>{};
    for (final filePath in workspace.dartFiles) {
      if (project.pathPolicy.shouldExclude(filePath)) continue;
      if (includedUnitPaths != null &&
          !includedUnitPaths.contains(_normalizedPath(filePath))) {
        continue;
      }
      try {
        final result = await workspace.resolveLibrary(filePath);
        if (result is ResolvedLibraryResult) {
          for (final unit in result.units) {
            units[unit.path] = unit;
          }
        } else if (result is! NotLibraryButPartResult) {
          blockers.add(
            RouteBlocker(
              reason: 'analyzer could not resolve a navigation library',
              location: project.relative(filePath),
              affectedNamespace: RouteInventory.namespaceFor(project),
            ),
          );
        }
      } catch (_) {
        blockers.add(
          RouteBlocker(
            reason: 'analyzer failed while resolving navigation call sites',
            location: project.relative(filePath),
            affectedNamespace: RouteInventory.namespaceFor(project),
          ),
        );
      }
    }

    final orderedPaths = units.keys.toList()..sort();
    final semanticIndex = _RouteSemanticIndex();
    for (final path in orderedPaths) {
      final unit = units[path]!;
      if (includedUnitPaths != null &&
          !includedUnitPaths.contains(_normalizedPath(unit.path))) {
        continue;
      }
      unit.unit.accept(_RouteSemanticCollector(semanticIndex));
    }
    for (final path in orderedPaths) {
      final unit = units[path]!;
      if (includedUnitPaths != null &&
          !includedUnitPaths.contains(_normalizedPath(unit.path))) {
        continue;
      }
      unit.unit.accept(_NavigationVisitor(this, unit, semanticIndex));
    }
  }
}

class _NavigationVisitor extends RecursiveAstVisitor<void> {
  _NavigationVisitor(this.resolver, this.unit, this.semanticIndex);

  final RouteReferenceResolver resolver;
  final ResolvedUnitResult unit;
  final _RouteSemanticIndex semanticIndex;

  ProjectContext get _project => resolver.project;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (semanticIndex.forwardingInvocations.contains(node)) {
      super.visitMethodInvocation(node);
      return;
    }

    final method = _resolvedNavigationMethod(node);
    if (method == null) {
      final element = node.methodName.element;
      final wrapperParameterIndex = element is ExecutableElement
          ? semanticIndex.wrapperPathParameterIndex[element.baseElement]
          : null;
      if (element is ExecutableElement && wrapperParameterIndex != null) {
        final argument = _argumentForParameter(
          node.argumentList.arguments,
          element,
          wrapperParameterIndex,
        );
        if (argument != null) {
          _resolvePath(argument, node);
        }
        super.visitMethodInvocation(node);
        return;
      }
      final dynamicMethod = _dynamicNavigationMethod(node);
      if (dynamicMethod != null && node.argumentList.arguments.isNotEmpty) {
        _blockDynamicNavigation(
          method: dynamicMethod,
          argument: analyzerArgumentExpression(
            node.argumentList.arguments.first,
          ),
          context: node,
        );
      }
      super.visitMethodInvocation(node);
      return;
    }

    final arguments = node.argumentList.arguments;
    if (arguments.isEmpty) {
      super.visitMethodInvocation(node);
      return;
    }
    final first = analyzerArgumentExpression(arguments.first);

    if (_namedNavigationMethods.contains(method)) {
      _resolveNamed(first, node);
    } else {
      _resolvePath(first, node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {
    if (_isRedirectCallback(node) && node.body is ExpressionFunctionBody) {
      _resolvePath(
        (node.body as ExpressionFunctionBody).expression,
        node,
        action: 'redirects to',
      );
    }
    super.visitFunctionExpression(node);
  }

  @override
  void visitReturnStatement(ReturnStatement node) {
    final expression = node.expression;
    if (expression != null && _isInsideRedirectCallback(node)) {
      _resolvePath(expression, node, action: 'redirects to');
    }
    super.visitReturnStatement(node);
  }

  String? _resolvedNavigationMethod(MethodInvocation node) {
    final element = node.methodName.element;
    if (element is! ExecutableElement) return null;
    final libraryUri = element.library.firstFragment.source.uri.toString();
    if (!isGoRouterLibraryUri(libraryUri)) return null;
    final name = element.displayName;
    if (_pathNavigationMethods.contains(name) ||
        _namedNavigationMethods.contains(name)) {
      return name;
    }
    return null;
  }

  String? _dynamicNavigationMethod(MethodInvocation node) {
    if (node.realTarget?.staticType is! DynamicType) return null;
    final name = node.methodName.name;
    if (_pathNavigationMethods.contains(name) ||
        _namedNavigationMethods.contains(name)) {
      return name;
    }
    return null;
  }

  void _blockDynamicNavigation({
    required String method,
    required Expression argument,
    required AstNode context,
  }) {
    final affectedNodeIds = _namedNavigationMethods.contains(method)
        ? _dynamicNamedCandidates(argument)
        : _dynamicPathCandidates(argument);
    resolver.blockers.add(
      RouteBlocker(
        reason:
            'navigation receiver has dynamic type and cannot be resolved as '
            'go_router',
        location: _location(argument),
        sourceNodeId: _callerId(context),
        affectedNamespace: affectedNodeIds.isEmpty
            ? RouteInventory.namespaceFor(_project)
            : null,
        affectedNodeIds: affectedNodeIds,
      ),
    );
  }

  Set<String> _dynamicNamedCandidates(Expression argument) {
    final routeName = _constantString(argument);
    if (routeName == null) return const {};
    final nodeId =
        resolver.inventory.nodeIdByNameKey[routeNameKey(
          packageName: _project.packageName,
          name: routeName,
        )];
    return nodeId == null ? const {} : {nodeId};
  }

  Set<String> _dynamicPathCandidates(Expression argument) {
    final location = _constantString(argument);
    if (location != null) {
      final uri = Uri.tryParse(location);
      final path = uri?.path;
      if (path == null || !path.startsWith('/')) return const {};
      final canonicalPath = path.length > 1 && path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path;
      final exactNodeId = routeNodeId(
        packageName: _project.packageName,
        fullPath: canonicalPath,
      );
      if (resolver.inventory.byNodeId.containsKey(exactNodeId)) {
        return {exactNodeId};
      }
      return {
        for (final entry in resolver.inventory.byNodeId.values)
          if (_couldMatchConcretePath(entry.fullPath, canonicalPath))
            entry.nodeId,
      };
    }

    final prefix = semanticIndex.resolve(argument)?.prefix;
    if (prefix == null || prefix.isEmpty) return const {};
    return {
      for (final entry in resolver.inventory.byNodeId.values)
        if (_couldMatchPrefix(entry.fullPath, prefix)) entry.nodeId,
    };
  }

  void _resolvePath(
    Expression argument,
    AstNode context, {
    String action = 'navigates to',
  }) {
    final staticValue = semanticIndex.resolve(argument);
    if (staticValue?.exact case final location?) {
      final uri = Uri.tryParse(location);
      final path = uri?.path;
      if (path == null || !path.startsWith('/')) {
        resolver.blockers.add(
          RouteBlocker(
            reason: 'navigation location requires runtime-relative resolution',
            location: _location(argument),
            sourceNodeId: _callerId(context),
            affectedNamespace: RouteInventory.namespaceFor(_project),
          ),
        );
        return;
      }

      final canonicalPath = path.length > 1 && path.endsWith('/')
          ? path.substring(0, path.length - 1)
          : path;
      final nodeId = routeNodeId(
        packageName: _project.packageName,
        fullPath: canonicalPath,
      );
      if (resolver.inventory.byNodeId.containsKey(nodeId)) {
        _recordExactReference(
          routeNodeId: nodeId,
          context: context,
          argument: argument,
          description: "$action '$location'",
        );
        return;
      }

      final candidates = <String>{
        for (final entry in resolver.inventory.byNodeId.values)
          if (_couldMatchConcretePath(entry.fullPath, canonicalPath))
            entry.nodeId,
      };
      if (candidates.length == 1) {
        _recordExactReference(
          routeNodeId: candidates.single,
          context: context,
          argument: argument,
          description: "$action '$location'",
        );
      } else {
        resolver.blockers.add(
          RouteBlocker(
            reason: candidates.isEmpty
                ? 'constant navigation location did not resolve to a declared route'
                : 'constant navigation location matches multiple route patterns',
            location: _location(argument),
            sourceNodeId: _callerId(context),
            affectedNamespace: candidates.isEmpty
                ? RouteInventory.namespaceFor(_project)
                : null,
            affectedNodeIds: candidates,
          ),
        );
      }
      return;
    }

    final prefix = staticValue?.prefix;
    if (prefix != null && prefix.isNotEmpty) {
      final queryIndex = prefix.indexOf('?');
      final knownPath = queryIndex < 0 ? null : prefix.substring(0, queryIndex);
      if (knownPath != null && knownPath.startsWith('/')) {
        final nodeId = routeNodeId(
          packageName: _project.packageName,
          fullPath: knownPath,
        );
        if (resolver.inventory.byNodeId.containsKey(nodeId)) {
          _recordExactReference(
            routeNodeId: nodeId,
            context: context,
            argument: argument,
            description: "$action route path '$knownPath'",
          );
          return;
        }
      }
      final affected = <String>{
        for (final entry in resolver.inventory.byNodeId.values)
          if (_couldMatchPrefix(entry.fullPath, prefix)) entry.nodeId,
      };
      if (affected.isNotEmpty) {
        resolver.blockers.add(
          RouteBlocker(
            reason: 'navigation location is only partially known',
            location: _location(argument),
            sourceNodeId: _callerId(context),
            affectedNodeIds: affected,
          ),
        );
        return;
      }
    }

    resolver.blockers.add(
      RouteBlocker(
        reason: 'navigation location is not a constant string',
        location: _location(argument),
        sourceNodeId: _callerId(context),
        affectedNamespace: RouteInventory.namespaceFor(_project),
      ),
    );
  }

  void _resolveNamed(Expression argument, AstNode context) {
    if (semanticIndex.resolve(argument)?.exact case final routeName?) {
      final key = routeNameKey(
        packageName: _project.packageName,
        name: routeName,
      );
      final nodeId = resolver.inventory.nodeIdByNameKey[key];
      if (nodeId != null) {
        _recordExactReference(
          routeNodeId: nodeId,
          context: context,
          argument: argument,
          description: "navigates to name '$routeName'",
        );
      }
      return;
    }

    resolver.blockers.add(
      RouteBlocker(
        reason: 'navigation route name is not a constant string',
        location: _location(argument),
        sourceNodeId: _callerId(context),
        affectedNamespace: RouteInventory.namespaceFor(_project),
      ),
    );
  }

  String? _constantString(Expression expression) {
    return semanticIndex.resolve(expression)?.exact;
  }

  bool _isRedirectCallback(FunctionExpression node) {
    AstNode? argument = node.parent;
    while (argument != null && argument.parent is! ArgumentList) {
      argument = argument.parent;
    }
    if (argument == null || analyzerNamedArgumentName(argument) != 'redirect') {
      return false;
    }
    final owner = argument.parent?.parent;
    if (owner is! InstanceCreationExpression) return false;
    final constructor = owner.constructorName.element;
    if (constructor is! ConstructorElement) return false;
    return const {
          'GoRoute',
          'GoRouter',
        }.contains(constructor.enclosingElement.name) &&
        isGoRouterLibraryUri(
          constructor.library.firstFragment.source.uri.toString(),
        );
  }

  bool _isInsideRedirectCallback(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      if (current is FunctionExpression) return _isRedirectCallback(current);
      current = current.parent;
    }
    return false;
  }

  void _recordExactReference({
    required String routeNodeId,
    required AstNode context,
    required AstNode argument,
    required String description,
  }) {
    final callerId = _callerId(context);
    if (callerId == null) {
      resolver.blockers.add(
        RouteBlocker(
          reason:
              'navigation occurs in a source unit not modeled by the Dart '
              'adapter',
          location: _location(argument),
          affectedNodeIds: {routeNodeId},
        ),
      );
      return;
    }
    resolver.references.add(
      RouteReference(
        routeNodeId: routeNodeId,
        callerId: callerId,
        location: _location(argument),
        description: description,
      ),
    );
  }

  bool _couldMatchPrefix(String fullPath, String prefix) {
    final pathSegments = fullPath.split('/');
    final prefixSegments = prefix.split('/');
    if (prefixSegments.isNotEmpty && prefixSegments.last.isEmpty) {
      prefixSegments.removeLast();
    }
    if (prefixSegments.length > pathSegments.length) return false;
    for (var index = 0; index < prefixSegments.length; index++) {
      final pathSegment = pathSegments[index];
      if (pathSegment.startsWith(':')) continue;
      if (pathSegment != prefixSegments[index]) return false;
    }
    return true;
  }

  bool _couldMatchConcretePath(String routePattern, String locationPath) {
    final patternSegments = routePattern.split('/');
    final locationSegments = locationPath.split('/');
    if (patternSegments.length != locationSegments.length) return false;
    for (var index = 0; index < patternSegments.length; index++) {
      final patternSegment = patternSegments[index];
      if (patternSegment.startsWith(':')) {
        if (locationSegments[index].isEmpty) return false;
        continue;
      }
      if (patternSegment != locationSegments[index]) return false;
    }
    return true;
  }

  String _location(AstNode node) {
    final position = unit.lineInfo.getLocation(node.offset);
    return '${_project.relative(unit.path)}:'
        '${position.lineNumber}:${position.columnNumber}';
  }

  String? _callerId(AstNode node) {
    if (!DartIds.isModeledProjectPath(_project, unit.path)) return null;
    AstNode? current = node.parent;
    while (current != null) {
      final fragment = switch (current) {
        FunctionDeclaration(:final declaredFragment)
            when current.parent is CompilationUnit =>
          declaredFragment,
        ClassDeclaration(:final declaredFragment) => declaredFragment,
        EnumDeclaration(:final declaredFragment) => declaredFragment,
        MixinDeclaration(:final declaredFragment) => declaredFragment,
        ExtensionDeclaration(:final declaredFragment) => declaredFragment,
        ExtensionTypeDeclaration(:final declaredFragment) => declaredFragment,
        VariableDeclaration(:final declaredFragment)
            when current.parent?.parent is TopLevelVariableDeclaration =>
          declaredFragment,
        _ => null,
      };
      if (fragment != null) {
        return DartIds.declaration(_project, fragment);
      }
      current = current.parent;
    }
    return DartIds.library(_project, unit.libraryElement);
  }
}

final class _RouteSemanticIndex {
  final Map<Element, Expression> variableInitializers = {};
  final Map<Element, Expression> executableReturns = {};
  final Map<Element, int> wrapperPathParameterIndex = {};
  final Set<MethodInvocation> forwardingInvocations = {};

  _StaticString? resolve(Expression expression) =>
      _resolve(expression, const <Element, Expression>{}, <Element>{}, 0);

  _StaticString? _resolve(
    Expression expression,
    Map<Element, Expression> bindings,
    Set<Element> seen,
    int depth,
  ) {
    if (depth > 24) return null;
    if (expression is ParenthesizedExpression) {
      return _resolve(expression.expression, bindings, seen, depth + 1);
    }
    if (expression is StringInterpolation) {
      var prefix = '';
      for (final element in expression.elements) {
        if (element is InterpolationString) {
          prefix += element.value;
          continue;
        }
        if (element is InterpolationExpression) {
          final value = _resolve(element.expression, bindings, seen, depth + 1);
          if (value?.exact case final exact?) {
            prefix += exact;
            continue;
          }
          return _StaticString.partial('$prefix${value?.prefix ?? ''}');
        }
      }
      return _StaticString.exact(prefix);
    }
    if (expression is StringLiteral) {
      final value = expression.stringValue;
      return value == null ? null : _StaticString.exact(value);
    }
    if (expression is AdjacentStrings) {
      var prefix = '';
      for (final string in expression.strings) {
        final value = _resolve(string, bindings, seen, depth + 1);
        if (value?.exact case final exact?) {
          prefix += exact;
          continue;
        }
        return _StaticString.partial('$prefix${value?.prefix ?? ''}');
      }
      return _StaticString.exact(prefix);
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '+') {
      final left = _resolve(expression.leftOperand, bindings, seen, depth + 1);
      if (left == null) return null;
      if (left.exact == null) return left;
      final right = _resolve(
        expression.rightOperand,
        bindings,
        seen,
        depth + 1,
      );
      if (right?.exact case final exact?) {
        return _StaticString.exact('${left.exact}$exact');
      }
      return _StaticString.partial('${left.exact}${right?.prefix ?? ''}');
    }

    final element = switch (expression) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    if (element != null) {
      return _resolveElement(element, bindings, seen, depth + 1);
    }

    if (expression is MethodInvocation) {
      final executable = expression.methodName.element;
      if (executable is! ExecutableElement) return null;
      final key = executable.baseElement;
      final returned = executableReturns[key];
      if (returned == null || !seen.add(key)) return null;
      final nextBindings = <Element, Expression>{...bindings};
      for (var index = 0; index < executable.formalParameters.length; index++) {
        final argument = _argumentForParameter(
          expression.argumentList.arguments,
          executable,
          index,
        );
        if (argument != null) {
          nextBindings[executable.formalParameters[index].baseElement] =
              argument;
        }
      }
      final value = _resolve(returned, nextBindings, seen, depth + 1);
      seen.remove(key);
      return value;
    }
    return null;
  }

  _StaticString? _resolveElement(
    Element element,
    Map<Element, Expression> bindings,
    Set<Element> seen,
    int depth,
  ) {
    final key = element.baseElement;
    final binding = bindings[key];
    if (binding != null) return _resolve(binding, bindings, seen, depth + 1);

    final variable = switch (key) {
      PropertyAccessorElement(:final variable) => variable,
      VariableElement() => key,
      _ => null,
    };
    try {
      final constant = variable?.computeConstantValue()?.toStringValue();
      if (constant != null) return _StaticString.exact(constant);
    } on StateError {
      // Fall through to source expressions when constant evaluation is absent.
    }

    final source = variableInitializers[key] ?? executableReturns[key];
    if (source == null || !seen.add(key)) return null;
    final value = _resolve(source, bindings, seen, depth + 1);
    seen.remove(key);
    return value;
  }
}

final class _RouteSemanticCollector extends RecursiveAstVisitor<void> {
  _RouteSemanticCollector(this.index);

  final _RouteSemanticIndex index;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final fragment = node.declaredFragment;
    final initializer = node.initializer;
    if (fragment != null && initializer != null) {
      index.variableInitializers[fragment.element.baseElement] = initializer;
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    final fragment = node.declaredFragment;
    final body = node.functionExpression.body;
    if (fragment != null && body is ExpressionFunctionBody) {
      index.executableReturns[fragment.element.baseElement] = body.expression;
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final fragment = node.declaredFragment;
    final body = node.body;
    if (fragment != null && body is ExpressionFunctionBody) {
      index.executableReturns[fragment.element.baseElement] = body.expression;
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (_resolvedGoRouterNavigationMethod(node) == null ||
        node.argumentList.arguments.isEmpty) {
      super.visitMethodInvocation(node);
      return;
    }
    final argument = analyzerArgumentExpression(
      node.argumentList.arguments.first,
    );
    final parameter = argument is SimpleIdentifier
        ? argument.element?.baseElement
        : null;
    if (parameter is! FormalParameterElement) {
      super.visitMethodInvocation(node);
      return;
    }

    final declaration = node.thisOrAncestorOfType<MethodDeclaration>();
    final executable = declaration?.declaredFragment?.element;
    if (executable != null) {
      final parameterIndex = executable.formalParameters.indexWhere(
        (candidate) => candidate.baseElement == parameter,
      );
      if (parameterIndex >= 0) {
        index.wrapperPathParameterIndex[executable.baseElement] =
            parameterIndex;
        index.forwardingInvocations.add(node);
      }
    }
    super.visitMethodInvocation(node);
  }
}

final class _StaticString {
  const _StaticString._({required this.exact, required this.prefix});

  factory _StaticString.exact(String value) =>
      _StaticString._(exact: value, prefix: value);

  factory _StaticString.partial(String prefix) =>
      _StaticString._(exact: null, prefix: prefix);

  final String? exact;
  final String prefix;
}

Expression? _argumentForParameter(
  Iterable<AstNode> arguments,
  ExecutableElement executable,
  int parameterIndex,
) {
  if (parameterIndex < 0 ||
      parameterIndex >= executable.formalParameters.length) {
    return null;
  }
  final target = executable.formalParameters[parameterIndex];
  var positionalIndex = 0;
  for (final argument in arguments) {
    final named = analyzerNamedArgumentName(argument);
    if (named != null) {
      if (target.isNamed && target.name == named) {
        return analyzerArgumentExpression(argument);
      }
      continue;
    }
    while (positionalIndex < executable.formalParameters.length &&
        !executable.formalParameters[positionalIndex].isPositional) {
      positionalIndex++;
    }
    if (positionalIndex >= executable.formalParameters.length) return null;
    if (positionalIndex == parameterIndex) {
      return analyzerArgumentExpression(argument);
    }
    positionalIndex++;
  }
  return null;
}

String? _resolvedGoRouterNavigationMethod(MethodInvocation node) {
  final element = node.methodName.element;
  if (element is! ExecutableElement) return null;
  final libraryUri = element.library.firstFragment.source.uri.toString();
  if (!isGoRouterLibraryUri(libraryUri)) return null;
  final name = element.displayName;
  return _pathNavigationMethods.contains(name) ||
          _namedNavigationMethods.contains(name)
      ? name
      : null;
}

String _normalizedPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}
