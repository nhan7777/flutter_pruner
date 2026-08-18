import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

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
  }) async {
    final units = <String, ResolvedUnitResult>{};
    for (final filePath in workspace.dartFiles) {
      if (project.pathPolicy.shouldExclude(filePath)) continue;
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
    for (final path in orderedPaths) {
      units[path]!.unit.accept(_NavigationVisitor(this, units[path]!));
    }
  }
}

class _NavigationVisitor extends RecursiveAstVisitor<void> {
  _NavigationVisitor(this.resolver, this.unit);

  final RouteReferenceResolver resolver;
  final ResolvedUnitResult unit;

  ProjectContext get _project => resolver.project;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = _resolvedNavigationMethod(node);
    if (method == null) {
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

    final prefix = _constantPrefix(argument);
    if (prefix == null || prefix.isEmpty) return const {};
    return {
      for (final entry in resolver.inventory.byNodeId.values)
        if (_couldMatchPrefix(entry.fullPath, prefix)) entry.nodeId,
    };
  }

  void _resolvePath(Expression argument, AstNode context) {
    if (_constantString(argument) case final location?) {
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
          description: "navigates to '$location'",
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
          description: "navigates to '$location'",
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

    final prefix = _constantPrefix(argument);
    if (prefix != null && prefix.isNotEmpty) {
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
    if (_constantString(argument) case final routeName?) {
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

  String? _constantPrefix(Expression expression) {
    if (expression is! StringInterpolation) return null;
    final first = expression.elements.first;
    return first is InterpolationString ? first.value : null;
  }

  String? _constantString(Expression expression) {
    if (expression is StringLiteral) return expression.stringValue;
    final element = switch (expression) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    final variable = switch (element) {
      PropertyAccessorElement(:final variable) => variable,
      VariableElement() => element,
      _ => null,
    };
    try {
      return variable?.computeConstantValue()?.toStringValue();
    } on StateError {
      return null;
    }
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
