import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../core/project/project_context.dart';
import '../dart/analyzer_ast_compat.dart';
import '../dart/dart_analysis_workspace.dart';
import '../dart/dart_ids.dart';
import 'di_identity.dart';
import 'di_inventory.dart';

const Set<String> _singleLookupApis = {'get', 'getAsync', 'maybeGet', 'call'};
const Set<String> _allLookupApis = {'getAll', 'getAllAsync'};
const String _stateInspectionApi = 'isRegistered';

const Set<String> _registrationApis = {
  'registerFactory',
  'registerFactoryParam',
  'registerFactoryAsync',
  'registerFactoryParamAsync',
  'registerCachedFactory',
  'registerCachedFactoryParam',
  'registerCachedFactoryAsync',
  'registerCachedFactoryParamAsync',
  'registerSingleton',
  'registerSingletonAsync',
  'registerSingletonWithDependencies',
  'registerLazySingleton',
  'registerLazySingletonAsync',
  'registerSingletonIfAbsent',
};

const Set<String> _factoryRegistrationApis = {
  'registerFactory',
  'registerFactoryParam',
  'registerFactoryAsync',
  'registerFactoryParamAsync',
  'registerCachedFactory',
  'registerCachedFactoryParam',
  'registerCachedFactoryAsync',
  'registerCachedFactoryParamAsync',
  'registerLazySingleton',
  'registerLazySingletonAsync',
};

const Set<String> _unresolvedReachabilityApis = {
  'findAll',
  'findFirstObjectRegistration',
  'hasScope',
  'checkLazySingletonInstanceExists',
  'allReady',
  'allReadySync',
  'isReady',
  'isReadySync',
  'changeTypeInstanceName',
  'enableRegisteringMultipleInstancesOfOneType',
  'pushNewScope',
  'pushNewScopeAsync',
  'popScope',
  'popScopesTill',
  'dropScope',
  'reset',
  'resetLazySingleton',
  'resetLazySingletons',
  'resetScope',
  'unregister',
  'releaseInstance',
  'signalReady',
};

const Set<String> _runtimeStateProperties = {
  'allowReassignment',
  'allowRegisterMultipleImplementationsOfoneType',
  'skipDoubleRegistration',
};

/// A semantically exact GetIt consumer reference.
final class DiReference {
  /// Creates a reference from a modeled Dart owner to a DI occurrence.
  const DiReference({
    required this.diNodeId,
    required this.callerId,
    required this.location,
    required this.description,
  });

  /// Stable graph id of an existing [DiEntry].
  final String diNodeId;

  /// Stable Dart declaration or library graph id for the consumer.
  final String callerId;

  /// Project-relative `path:line:column` of the lookup.
  final String location;

  /// Human-readable semantic explanation for report output.
  final String description;
}

/// Resolves exact GetIt service-consumption sites against a DI inventory.
///
/// This resolver never treats registration setup or `isRegistered` inspection
/// as liveness. Any lookup that cannot be matched to a complete, bounded set
/// of registration occurrences becomes a scoped [DiBlocker].
final class DiResolutionResolver {
  /// Creates a resolver for [project] and its registration [inventory].
  DiResolutionResolver(this.project, this.inventory);

  /// Project being analyzed.
  final ProjectContext project;

  /// Occurrence-preserving registration inventory.
  final DiInventory inventory;

  final List<DiReference> _references = [];

  /// Exact consumer-to-registration references in deterministic order.
  List<DiReference> get references => List.unmodifiable(_references);

  final List<DiBlocker> _blockers = [];

  /// Scoped lookup and analyzer uncertainty in deterministic order.
  List<DiBlocker> get blockers => List.unmodifiable(_blockers);

  /// Resolves every project library through the shared [workspace].
  Future<void> analyzeProject({
    required DartAnalysisWorkspace workspace,
  }) async {
    final units = <String, ResolvedUnitResult>{};
    for (final filePath in workspace.dartFiles) {
      // Generated Dart callers are not modeled graph nodes, but an exact
      // lookup inside one must still lower confidence rather than disappear.
      if (project.pathPolicy.shouldExclude(filePath) &&
          !DartIds.isGeneratedPath(filePath)) {
        continue;
      }
      try {
        final result = await workspace.resolveLibrary(filePath);
        if (result is ResolvedLibraryResult) {
          for (final unit in result.units) {
            units[unit.path] = unit;
          }
        } else if (result is! NotLibraryButPartResult) {
          _blockers.add(
            DiBlocker(
              reason: 'analyzer could not resolve a GetIt consumer library',
              location: project.relative(filePath),
              affectedNamespace: DiInventory.namespaceFor(project),
            ),
          );
        }
      } catch (_) {
        _blockers.add(
          DiBlocker(
            reason: 'analyzer failed while resolving GetIt consumer call sites',
            location: project.relative(filePath),
            affectedNamespace: DiInventory.namespaceFor(project),
          ),
        );
      }
    }

    final orderedPaths = units.keys.toList()..sort();
    for (final path in orderedPaths) {
      final unit = units[path]!;
      final plausible = _PlausibleLookupErrorVisitor(
        hasGetItImport: unit.unit.directives.whereType<ImportDirective>().any(
          (directive) =>
              directive.uri.stringValue?.startsWith(getItPackageUriPrefix) ??
              false,
        ),
      );
      unit.unit.accept(plausible);
      for (final node in plausible.nodes) {
        _blockers.add(
          DiBlocker(
            reason: unit.diagnostics.isEmpty
                ? 'GetIt lookup receiver is dynamic or unresolved'
                : 'analyzer errors prevent semantic GetIt lookup classification',
            location: _location(project, unit, node),
            affectedNamespace: DiInventory.namespaceFor(project),
          ),
        );
      }
      unit.unit.accept(_ResolutionVisitor(this, unit));
    }
    _normalizeFindings();
  }

  void _normalizeFindings() {
    _deduplicateAndSort<DiReference>(
      _references,
      identity: (reference) =>
          '${reference.diNodeId}\u0000${reference.callerId}\u0000'
          '${reference.location}\u0000${reference.description}',
      compare: (left, right) =>
          '${left.location}\u0000${left.callerId}\u0000${left.diNodeId}'
              .compareTo(
                '${right.location}\u0000${right.callerId}\u0000${right.diNodeId}',
              ),
    );
    _deduplicateAndSort<DiBlocker>(
      _blockers,
      identity: (blocker) =>
          '${blocker.reason}\u0000${blocker.location ?? ''}\u0000'
          '${blocker.sourceNodeId ?? ''}\u0000${blocker.affectedNamespace ?? ''}\u0000'
          '${(blocker.affectedNodeIds.toList()..sort()).join('\u0001')}',
      compare: (left, right) =>
          '${left.location ?? ''}\u0000${left.reason}\u0000${left.sourceNodeId ?? ''}'
              .compareTo(
                '${right.location ?? ''}\u0000${right.reason}\u0000${right.sourceNodeId ?? ''}',
              ),
    );
  }

  void _deduplicateAndSort<T>(
    List<T> values, {
    required String Function(T value) identity,
    required int Function(T left, T right) compare,
  }) {
    final byIdentity = <String, T>{
      for (final value in values) identity(value): value,
    };
    final normalized = byIdentity.values.toList()..sort(compare);
    values
      ..clear()
      ..addAll(normalized);
  }
}

final class _ResolutionVisitor extends RecursiveAstVisitor<void> {
  _ResolutionVisitor(this.resolver, this.unit);

  final DiResolutionResolver resolver;
  final ResolvedUnitResult unit;

  ProjectContext get _project => resolver.project;

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (element is ExecutableElement && isGetItApiElement(element)) {
      final name = element.displayName;
      if (_singleLookupApis.contains(name)) {
        _resolve(node, api: name);
      } else if (_allLookupApis.contains(name)) {
        _resolve(node, api: name, resolvesAll: true, allowsTypeOverride: false);
      } else if (name != _stateInspectionApi &&
          !_registrationApis.contains(name)) {
        _addNamespaceBlocker(
          'resolved GetIt API $name can alter registration reachability',
          node,
        );
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final element = node.element;
    if (element != null && isGetItApiElement(element)) {
      if (element.displayName == 'call') {
        _resolve(node, api: 'call');
      } else {
        _addNamespaceBlocker(
          'resolved GetIt callable API ${element.displayName} is unsupported',
          node,
        );
      }
    }
    super.visitFunctionExpressionInvocation(node);
  }

  void _resolve(
    InvocationExpression node, {
    required String api,
    bool resolvesAll = false,
    bool allowsTypeOverride = true,
  }) {
    final typeResult = _lookupType(
      node,
      allowsTypeOverride: allowsTypeOverride,
    );
    if (typeResult.key == null) {
      _addNamespaceBlocker(typeResult.reason!, typeResult.node ?? node);
      return;
    }
    final type = typeResult.key!;

    if (resolvesAll) {
      _resolveAll(node, api: api, type: type);
      return;
    }

    final instanceName = diInstanceName(_namedArgument(node, 'instanceName'));
    if (instanceName is DiDynamicInstanceName) {
      _addTypeBlocker(
        'GetIt $api lookup has a dynamic instanceName',
        node,
        type,
      );
      return;
    }

    final lookup = DiLookupKey(type: type, instanceName: instanceName);
    final candidates = resolver.inventory.entriesFor(lookup);
    final uncertain = _uncertainTypeEntries(type);
    if (uncertain.isNotEmpty) {
      _addBlocker(
        reason:
            'GetIt $api lookup has registrations with an unknown name or scope',
        node: node,
        affectedNodeIds: {
          ...candidates.map((entry) => entry.nodeId),
          ...uncertain,
        },
      );
      return;
    }
    if (candidates.isEmpty) {
      _addNamespaceBlocker(
        'GetIt $api lookup does not match a registered service',
        node,
      );
      return;
    }
    if (candidates.length != 1) {
      _addBlocker(
        reason: 'GetIt $api lookup matches multiple registrations',
        node: node,
        affectedNodeIds: candidates.map((entry) => entry.nodeId).toSet(),
      );
      return;
    }
    _recordExact(candidates.single, node, api: api);
  }

  void _resolveAll(
    InvocationExpression node, {
    required String api,
    required DiTypeKey type,
  }) {
    final onlyInScope = _namedArgument(node, 'onlyInScope');
    if (onlyInScope != null) {
      _addTypeBlocker(
        'GetIt $api has an unmodeled onlyInScope scope request',
        node,
        type,
      );
      return;
    }
    final fromAllScopes = _namedArgument(node, 'fromAllScopes');
    if (fromAllScopes != null && _constantBool(fromAllScopes) != false) {
      _addTypeBlocker(
        'GetIt $api has a non-local fromAllScopes request',
        node,
        type,
      );
      return;
    }
    final entries = resolver.inventory.entries
        .where((entry) => entry.type == type)
        .toList(growable: false);
    final candidates = entries
        .where((entry) => entry.lookup != null && entry.isExactBaseScope)
        .toList(growable: false);
    final uncertain = entries
        .where((entry) => entry.lookup == null || !entry.isExactBaseScope)
        .map((entry) => entry.nodeId)
        .toSet();
    if (uncertain.isNotEmpty) {
      _addBlocker(
        reason: 'GetIt $api cannot prove the complete registration set',
        node: node,
        affectedNodeIds: {
          ...candidates.map((entry) => entry.nodeId),
          ...uncertain,
        },
      );
      return;
    }
    if (candidates.isEmpty) {
      _addNamespaceBlocker(
        'GetIt $api lookup does not match a registered service',
        node,
      );
      return;
    }
    for (final candidate in candidates) {
      _recordExact(candidate, node, api: api);
    }
  }

  Set<String> _uncertainTypeEntries(DiTypeKey type) => resolver
      .inventory
      .entries
      .where(
        (entry) =>
            entry.type == type &&
            (entry.lookup == null || !entry.isExactBaseScope),
      )
      .map((entry) => entry.nodeId)
      .toSet();

  _LookupType _lookupType(
    InvocationExpression node, {
    required bool allowsTypeOverride,
  }) {
    final override = _namedArgument(node, 'type');
    if (override != null) {
      if (!allowsTypeOverride) {
        return _LookupType.invalid(
          'GetIt getAll APIs do not support a type: override',
          override,
        );
      }
      final type = _constantType(override);
      final key = type == null ? null : diTypeKey(type);
      return key == null
          ? _LookupType.invalid(
              'GetIt type: override is not a constant canonical Type',
              override,
            )
          : _LookupType.exact(key);
    }

    final typeArguments = node.typeArgumentTypes;
    if (typeArguments == null || typeArguments.length != 1) {
      return _LookupType.invalid(
        'GetIt lookup has no resolved service type',
        node.typeArguments ?? node,
      );
    }
    final key = diTypeKey(typeArguments.single);
    return key == null
        ? _LookupType.invalid(
            'GetIt lookup uses a non-canonical service type',
            node.typeArguments ?? node,
          )
        : _LookupType.exact(key);
  }

  DartType? _constantType(Expression expression) {
    if (expression is TypeLiteral) return expression.type.type;
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
    DartObject? value;
    try {
      value = variable?.computeConstantValue();
    } on StateError {
      return null;
    }
    return value?.toTypeValue();
  }

  bool? _constantBool(Expression expression) {
    if (expression is BooleanLiteral) return expression.value;
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
    DartObject? value;
    try {
      value = variable?.computeConstantValue();
    } on StateError {
      return null;
    }
    return value?.toBoolValue();
  }

  Expression? _namedArgument(InvocationExpression node, String name) {
    for (final argument in node.argumentList.arguments) {
      if (analyzerNamedArgumentName(argument) == name) {
        return analyzerArgumentExpression(argument);
      }
    }
    return null;
  }

  void _recordExact(DiEntry entry, AstNode node, {required String api}) {
    if (!resolver.inventory.byNodeId.containsKey(entry.nodeId)) {
      _addNamespaceBlocker(
        'GetIt $api resolved an inventory entry that is no longer available',
        node,
      );
      return;
    }
    final factoryOwner = _factoryRegistrationOwner(node);
    if (factoryOwner case _UnboundFactoryRegistration()) {
      resolver._blockers.add(
        DiBlocker(
          reason:
              'GetIt factory closure lookup could not bind to one registration occurrence',
          location: _location(_project, unit, node),
          affectedNamespace: DiInventory.namespaceFor(_project),
          affectedNodeIds: factoryOwner.affectedNodeIds,
        ),
      );
      return;
    }
    final callerId = switch (factoryOwner) {
      _BoundFactoryRegistration(:final entry) => entry.nodeId,
      _NoFactoryRegistration() => _callerId(node),
      _ => null,
    };
    if (callerId == null) {
      _addBlocker(
        reason: 'GetIt $api lookup occurs in an unmodeled Dart source',
        node: node,
        affectedNodeIds: {entry.nodeId},
      );
      return;
    }
    resolver._references.add(
      DiReference(
        diNodeId: entry.nodeId,
        callerId: callerId,
        location: _location(_project, unit, node),
        description: 'resolves ${entry.type} through GetIt $api',
      ),
    );
  }

  _FactoryRegistrationOwner _factoryRegistrationOwner(AstNode node) {
    AstNode? current = node.parent;
    while (current != null) {
      if (current case MethodInvocation(
        :final methodName,
        :final argumentList,
      ) when methodName.element is ExecutableElement) {
        final method = methodName.element! as ExecutableElement;
        if (isGetItApiElement(method) &&
            _factoryRegistrationApis.contains(method.displayName) &&
            _isDirectFactoryClosure(node, argumentList)) {
          final path = _project.relative(unit.path);
          final candidates = resolver.inventory.entries
              .where(
                (entry) =>
                    entry.occurrence.source.path == path &&
                    entry.occurrence.source.offset == current!.offset,
              )
              .toList(growable: false);
          return switch (candidates.length) {
            1 => _BoundFactoryRegistration(candidates.single),
            _ => _UnboundFactoryRegistration(
              candidates.map((entry) => entry.nodeId).toSet(),
            ),
          };
        }
      }
      current = current.parent;
    }
    return const _NoFactoryRegistration();
  }

  bool _isDirectFactoryClosure(AstNode node, ArgumentList arguments) {
    if (arguments.arguments.isEmpty) return false;
    final expression = analyzerArgumentExpression(arguments.arguments.first);
    if (expression is! FunctionExpression) return false;
    return node.offset >= expression.offset && node.end <= expression.end;
  }

  void _addTypeBlocker(String reason, AstNode node, DiTypeKey type) {
    final affected = resolver.inventory.entries
        .where((entry) => entry.type == type)
        .map((entry) => entry.nodeId)
        .toSet();
    if (affected.isEmpty) {
      _addNamespaceBlocker(reason, node);
    } else {
      _addBlocker(reason: reason, node: node, affectedNodeIds: affected);
    }
  }

  void _addNamespaceBlocker(String reason, AstNode node) => _addBlocker(
    reason: reason,
    node: node,
    affectedNamespace: DiInventory.namespaceFor(_project),
  );

  void _addBlocker({
    required String reason,
    required AstNode node,
    String? affectedNamespace,
    Set<String> affectedNodeIds = const {},
  }) {
    final orderedIds = affectedNodeIds.toList()..sort();
    resolver._blockers.add(
      DiBlocker(
        reason: reason,
        location: _location(_project, unit, node),
        sourceNodeId: _callerId(node),
        affectedNamespace: affectedNamespace,
        affectedNodeIds: Set.unmodifiable(orderedIds.toSet()),
      ),
    );
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
      if (fragment != null) return DartIds.declaration(_project, fragment);
      current = current.parent;
    }
    return DartIds.library(_project, unit.libraryElement);
  }
}

final class _LookupType {
  const _LookupType.exact(this.key) : reason = null, node = null;

  const _LookupType.invalid(this.reason, this.node) : key = null;

  final DiTypeKey? key;
  final String? reason;
  final AstNode? node;
}

sealed class _FactoryRegistrationOwner {
  const _FactoryRegistrationOwner();
}

final class _NoFactoryRegistration extends _FactoryRegistrationOwner {
  const _NoFactoryRegistration();
}

final class _BoundFactoryRegistration extends _FactoryRegistrationOwner {
  const _BoundFactoryRegistration(this.entry);

  final DiEntry entry;
}

final class _UnboundFactoryRegistration extends _FactoryRegistrationOwner {
  const _UnboundFactoryRegistration(this.affectedNodeIds);

  final Set<String> affectedNodeIds;
}

final class _PlausibleLookupErrorVisitor extends RecursiveAstVisitor<void> {
  _PlausibleLookupErrorVisitor({required this.hasGetItImport});

  final bool hasGetItImport;

  final List<AstNode> nodes = [];

  @override
  void visitMethodInvocation(MethodInvocation node) {
    if (hasGetItImport &&
        {
          ..._singleLookupApis,
          ..._allLookupApis,
          _stateInspectionApi,
          ..._unresolvedReachabilityApis,
        }.contains(node.methodName.name) &&
        node.methodName.element == null) {
      nodes.add(node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final name = _assignmentName(node.leftHandSide);
    if (hasGetItImport &&
        name != null &&
        _runtimeStateProperties.contains(name) &&
        node.writeElement == null) {
      nodes.add(node);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final staticType = node.function.staticType;
    if (hasGetItImport &&
        node.element == null &&
        (staticType is DynamicType ||
            (staticType is InterfaceType &&
                staticType.element.name == 'GetIt' &&
                isGetItLibraryUri(
                  staticType.element.library.uri.toString(),
                )))) {
      nodes.add(node);
    }
    super.visitFunctionExpressionInvocation(node);
  }

  static String? _assignmentName(Expression expression) => switch (expression) {
    PropertyAccess(:final propertyName) => propertyName.name,
    PrefixedIdentifier(:final identifier) => identifier.name,
    SimpleIdentifier(:final name) => name,
    _ => null,
  };
}

String _location(
  ProjectContext project,
  ResolvedUnitResult unit,
  AstNode node,
) {
  final position = unit.lineInfo.getLocation(node.offset);
  return '${project.relative(unit.path)}:'
      '${position.lineNumber}:${position.columnNumber}';
}
