import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../core/project/project_context.dart';
import '../dart/analyzer_ast_compat.dart';
import '../dart/dart_analysis_workspace.dart';
import 'route_path.dart';

/// Package URI namespace that owns the route API this adapter understands.
const String goRouterPackageUriPrefix = 'package:go_router/';

/// Whether a resolved declaration belongs to the go_router package.
bool isGoRouterLibraryUri(String libraryUri) =>
    libraryUri.startsWith(goRouterPackageUriPrefix);

/// One declared route.
class RouteEntry {
  /// Creates a route entry.
  RouteEntry({
    required this.nodeId,
    required this.fullPath,
    required this.parentNodeId,
    required this.name,
    required this.origin,
    required this.location,
  });

  /// Stable graph id, `route:<package>:<fullPath>`.
  final String nodeId;

  /// Path composed from every enclosing route.
  final String fullPath;

  /// Enclosing route kept alive whenever this child route is reachable.
  final String? parentNodeId;

  /// Declared `name:` value, when it is a constant string.
  final String? name;

  /// File that declares this route.
  final Uri origin;

  /// `path:line:column` of the declaration.
  final String location;
}

/// An unresolved route construct that must lower confidence.
class RouteBlocker {
  /// Creates a blocker record.
  RouteBlocker({
    required this.reason,
    this.location,
    this.sourceNodeId,
    this.affectedNamespace,
    this.affectedNodeIds = const {},
  });

  /// Why the construct could not be resolved.
  final String reason;

  /// Where it occurs, when known.
  final String? location;

  /// Caller whose reachability activates this blocker.
  final String? sourceNodeId;

  /// Namespace prefix this blocker could address.
  final String? affectedNamespace;

  /// Specific nodes this blocker could address.
  final Set<String> affectedNodeIds;
}

/// Every route declared in the analyzed project.
class RouteInventory {
  RouteInventory._({
    required this.byNodeId,
    required this.nodeIdByNameKey,
    required this.blockers,
  });

  /// Routes keyed by their stable graph id.
  final Map<String, RouteEntry> byNodeId;

  /// Route ids keyed by [routeNameKey], for named navigation.
  final Map<String, String> nodeIdByNameKey;

  /// Declaration-side constructs that could not be resolved.
  final List<RouteBlocker> blockers;

  /// Namespace covering every route in this package.
  static String namespaceFor(ProjectContext project) =>
      'route:${project.packageName}:';

  /// Discovers routes by resolving every project library.
  static Future<RouteInventory> discover(
    ProjectContext project, {
    required DartAnalysisWorkspace workspace,
  }) async {
    final byNodeId = <String, RouteEntry>{};
    final nodeIdByNameKey = <String, String>{};
    final nodeIdsByNameKey = <String, Set<String>>{};
    final blockers = <RouteBlocker>[];
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
              reason: 'analyzer could not resolve a route declaration library',
              location: project.relative(filePath),
              affectedNamespace: namespaceFor(project),
            ),
          );
        }
      } catch (_) {
        blockers.add(
          RouteBlocker(
            reason: 'analyzer failed while resolving route declarations',
            location: project.relative(filePath),
            affectedNamespace: namespaceFor(project),
          ),
        );
      }
    }

    final orderedPaths = units.keys.toList()..sort();
    for (final path in orderedPaths) {
      final unit = units[path]!;
      unit.unit.accept(
        _RouteDeclarationVisitor(
          project: project,
          unit: unit,
          byNodeId: byNodeId,
          nodeIdByNameKey: nodeIdByNameKey,
          nodeIdsByNameKey: nodeIdsByNameKey,
          blockers: blockers,
        ),
      );
    }

    return RouteInventory._(
      byNodeId: Map.unmodifiable(byNodeId),
      nodeIdByNameKey: Map.unmodifiable(nodeIdByNameKey),
      blockers: List.unmodifiable(blockers),
    );
  }
}

class _RouteDeclarationVisitor extends RecursiveAstVisitor<void> {
  _RouteDeclarationVisitor({
    required this.project,
    required this.unit,
    required this.byNodeId,
    required this.nodeIdByNameKey,
    required this.nodeIdsByNameKey,
    required this.blockers,
  });

  final ProjectContext project;
  final ResolvedUnitResult unit;
  final Map<String, RouteEntry> byNodeId;
  final Map<String, String> nodeIdByNameKey;
  final Map<String, Set<String>> nodeIdsByNameKey;
  final List<RouteBlocker> blockers;
  final List<String> _parentPaths = [];

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final owner = _resolvedGoRouterOwner(node);
    if (owner != 'GoRoute') {
      super.visitInstanceCreationExpression(node);
      return;
    }

    final pathExpression = _namedArgument(node, 'path');
    final rawPath = _constantString(pathExpression);

    if (rawPath == null) {
      blockers.add(
        RouteBlocker(
          reason: 'route path is not a constant string',
          location: _location(pathExpression ?? node),
          affectedNamespace: RouteInventory.namespaceFor(project),
        ),
      );
      super.visitInstanceCreationExpression(node);
      return;
    }

    final parentPath = _parentPaths.isEmpty ? '' : _parentPaths.last;
    final fullPath = composeRoutePath(parentPath, rawPath);
    final nodeId = routeNodeId(
      packageName: project.packageName,
      fullPath: fullPath,
    );

    final nameExpression = _namedArgument(node, 'name');
    final String? name;
    if (nameExpression == null) {
      name = null;
    } else if (_constantString(nameExpression) case final constantName?) {
      name = constantName;
    } else {
      name = null;
      blockers.add(
        RouteBlocker(
          reason: 'route name is not a constant string',
          location: _location(nameExpression),
          affectedNodeIds: {nodeId},
        ),
      );
    }

    final entry = RouteEntry(
      nodeId: nodeId,
      fullPath: fullPath,
      parentNodeId: _parentPaths.isEmpty
          ? null
          : routeNodeId(
              packageName: project.packageName,
              fullPath: _parentPaths.last,
            ),
      name: name,
      origin: Uri.file(unit.path),
      location: _location(node),
    );
    if (byNodeId.containsKey(nodeId)) {
      blockers.add(
        RouteBlocker(
          reason: 'duplicate route path cannot be represented independently',
          location: entry.location,
          affectedNamespace: RouteInventory.namespaceFor(project),
        ),
      );
    } else {
      byNodeId[nodeId] = entry;
      if (name != null) _indexRouteName(name, nodeId, entry.location);
    }

    _parentPaths.add(fullPath);
    super.visitInstanceCreationExpression(node);
    _parentPaths.removeLast();
  }

  void _indexRouteName(String name, String nodeId, String location) {
    final key = routeNameKey(packageName: project.packageName, name: name);
    final nodeIds = nodeIdsByNameKey.putIfAbsent(key, () => <String>{});
    nodeIds.add(nodeId);
    if (nodeIds.length == 1) {
      nodeIdByNameKey[key] = nodeId;
      return;
    }

    nodeIdByNameKey.remove(key);
    blockers.add(
      RouteBlocker(
        reason: 'duplicate route name is ambiguous',
        location: location,
        affectedNodeIds: {...nodeIds},
      ),
    );
  }

  String? _resolvedGoRouterOwner(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element is! ConstructorElement) return null;
    final libraryUri = element.library.firstFragment.source.uri.toString();
    if (!isGoRouterLibraryUri(libraryUri)) return null;
    return element.enclosingElement.name;
  }

  Expression? _namedArgument(InstanceCreationExpression node, String name) {
    for (final argument in node.argumentList.arguments) {
      if (analyzerNamedArgumentName(argument) != name) continue;
      return analyzerArgumentExpression(argument);
    }
    return null;
  }

  String? _constantString(Expression? expression) {
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

  String _location(AstNode node) {
    final position = unit.lineInfo.getLocation(node.offset);
    return '${project.relative(unit.path)}:'
        '${position.lineNumber}:${position.columnNumber}';
  }
}
