import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

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
    if (libraryUri != goRouterLibraryUri) return null;
    final name = element.displayName;
    if (_pathNavigationMethods.contains(name) ||
        _namedNavigationMethods.contains(name)) {
      return name;
    }
    return null;
  }

  void _resolvePath(Expression argument, AstNode context) {
    if (argument is StringLiteral && argument.stringValue != null) {
      final nodeId = routeNodeId(
        packageName: _project.packageName,
        fullPath: argument.stringValue!,
      );
      if (resolver.inventory.byNodeId.containsKey(nodeId)) {
        resolver.references.add(
          RouteReference(
            routeNodeId: nodeId,
            callerId: _callerId(context),
            location: _location(argument),
            description: "navigates to '${argument.stringValue}'",
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
    if (argument is StringLiteral && argument.stringValue != null) {
      final key = routeNameKey(
        packageName: _project.packageName,
        name: argument.stringValue!,
      );
      final nodeId = resolver.inventory.nodeIdByNameKey[key];
      if (nodeId != null) {
        resolver.references.add(
          RouteReference(
            routeNodeId: nodeId,
            callerId: _callerId(context),
            location: _location(argument),
            description: "navigates to name '${argument.stringValue}'",
          ),
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

  String _location(AstNode node) {
    final position = unit.lineInfo.getLocation(node.offset);
    return '${_project.relative(unit.path)}:'
        '${position.lineNumber}:${position.columnNumber}';
  }

  String _callerId(AstNode node) {
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
