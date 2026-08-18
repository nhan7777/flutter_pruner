import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../core/project/project_context.dart';
import '../dart/analyzer_ast_compat.dart';
import '../dart/dart_analysis_workspace.dart';
import 'di_identity.dart';

/// Package URI namespace that owns the GetIt API this adapter understands.
const String getItPackageUriPrefix = 'package:get_it/';

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

/// APIs whose lookup semantics are intentionally handled by Task 9.
const Set<String> _deferredLookupApis = {
  'call',
  'get',
  'getAsync',
  'maybeGet',
  'getAll',
  'getAllAsync',
  'isRegistered',
};

const Set<String> _runtimeStateProperties = {
  'allowReassignment',
  'allowRegisterMultipleImplementationsOfoneType',
  'skipDoubleRegistration',
};

const Set<String> _lifecycleAndStateApis = {
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

/// Whether [libraryUri] is owned by the GetIt package.
bool isGetItLibraryUri(String libraryUri) =>
    libraryUri.startsWith(getItPackageUriPrefix);

/// Whether a resolved member is declared directly on GetIt's base interface.
///
/// Package ownership alone is not enough: a package may export helper classes
/// whose method names overlap with GetIt lifecycle or registration APIs.
bool isGetItApiElement(Element element) {
  final owner = element.enclosingElement;
  if (owner is! InterfaceElement || owner.name != 'GetIt') return false;
  return isGetItLibraryUri(owner.library.uri.toString());
}

/// Whether [element] is GetIt's public multiple-container factory.
bool isGetItAsNewInstance(ConstructorElement element) =>
    element.name == 'asNewInstance' && isGetItApiElement(element);

/// A source registration that can later become a DI graph node.
final class DiEntry {
  /// Creates a resolved GetIt registration entry.
  DiEntry({
    required this.occurrence,
    required this.apiName,
    required this.origin,
    required this.location,
    this.dependsOn = const [],
  });

  /// Unique declaration occurrence, including duplicate registrations.
  final DiRegistrationOccurrence occurrence;

  /// Resolved GetIt registration API name.
  final String apiName;

  /// Library source declaring this registration.
  final Uri origin;

  /// Project-relative `path:line:column` declaration location.
  final String location;

  /// Exact dependencies declared through a statically-known `dependsOn` list.
  final List<DiLookupKey> dependsOn;

  /// Stable graph id for this declaration occurrence.
  String get nodeId => occurrence.graphId;

  /// Canonical service type identity.
  DiTypeKey get type => occurrence.type;

  /// Exact lookup identity, omitted for dynamic instance names.
  DiLookupKey? get lookup => occurrence.lookup;

  /// Declared instance-name state.
  DiInstanceName get instanceName => occurrence.instanceName;

  /// Registration scope inferred by the inventory.
  DiScopeIdentity get scope => occurrence.scope;

  /// Whether this entry can be offered as an exact base-scope candidate.
  bool get isExactBaseScope => scope is DiBaseScope;
}

/// An unresolved DI construct that must lower confidence.
final class DiBlocker {
  /// Creates a scoped DI uncertainty record.
  DiBlocker({
    required this.reason,
    this.location,
    this.sourceNodeId,
    this.affectedNamespace,
    this.affectedNodeIds = const {},
  }) : assert(affectedNamespace != null || affectedNodeIds.isNotEmpty);

  /// Explanation of the unresolved construct.
  final String reason;

  /// Project-relative source location, where available.
  final String? location;

  /// Modeled Dart caller, if a later adapter can establish one.
  final String? sourceNodeId;

  /// Bounded DI namespace that may be affected.
  final String? affectedNamespace;

  /// Exact DI declaration occurrences that may be affected.
  final Set<String> affectedNodeIds;
}

/// Deterministic inventory of GetIt registrations in a project.
final class DiInventory {
  DiInventory._({
    required this.byNodeId,
    required this.byLookup,
    required this.blockers,
  });

  /// Registration occurrences keyed by their unique stable graph ids.
  final Map<String, DiEntry> byNodeId;

  /// Exact lookup key to source-ordered candidate registrations.
  final Map<DiLookupKey, List<DiEntry>> byLookup;

  /// Scoped uncertainty observed while collecting registrations.
  final List<DiBlocker> blockers;

  /// Entries in deterministic declaration order.
  Iterable<DiEntry> get entries => byNodeId.values;

  /// Exact candidates for [lookup], in deterministic declaration order.
  List<DiEntry> entriesFor(DiLookupKey lookup) => byLookup[lookup] ?? const [];

  /// Namespace covering all GetIt registrations in [project].
  static String namespaceFor(ProjectContext project) =>
      diRegistrationNamespace(package: project.packageName);

  /// Discovers semantically resolved GetIt registrations.
  static Future<DiInventory> discover(
    ProjectContext project, {
    required DartAnalysisWorkspace workspace,
  }) async {
    final byNodeId = <String, DiEntry>{};
    final byLookup = <DiLookupKey, List<DiEntry>>{};
    final blockers = <DiBlocker>[];
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
            DiBlocker(
              reason: 'analyzer could not resolve a GetIt registration library',
              location: project.relative(filePath),
              affectedNamespace: namespaceFor(project),
            ),
          );
        }
      } catch (_) {
        blockers.add(
          DiBlocker(
            reason: 'analyzer failed while resolving GetIt registrations',
            location: project.relative(filePath),
            affectedNamespace: namespaceFor(project),
          ),
        );
      }
    }

    final orderedPaths = units.keys.toList()..sort();
    for (final path in orderedPaths) {
      final unit = units[path]!;
      final plausibleCalls = _PlausibleGetItErrorVisitor(
        hasDiagnostics: unit.diagnostics.isNotEmpty,
        hasGetItImport: unit.unit.directives.whereType<ImportDirective>().any(
          (directive) =>
              directive.uri.stringValue?.startsWith(getItPackageUriPrefix) ??
              false,
        ),
      );
      unit.unit.accept(plausibleCalls);
      for (final node in plausibleCalls.nodes) {
        final position = unit.lineInfo.getLocation(node.offset);
        blockers.add(
          DiBlocker(
            reason: plausibleCalls.dynamicReceiverNodes.contains(node)
                ? 'dynamic GetIt receiver cannot be resolved semantically'
                : 'analyzer errors prevent semantic GetIt classification',
            location:
                '${project.relative(unit.path)}:'
                '${position.lineNumber}:${position.columnNumber}',
            affectedNamespace: namespaceFor(project),
          ),
        );
      }
    }
    final runtimeState = _GetItRuntimeStateVisitor();
    for (final path in orderedPaths) {
      units[path]!.unit.accept(runtimeState);
    }
    final registrationScope = runtimeState.hasMutation
        ? const DiDynamicScope()
        : const DiBaseScope();
    for (final path in orderedPaths) {
      final visitor = _DiRegistrationVisitor(
        project: project,
        unit: units[path]!,
        byNodeId: byNodeId,
        byLookup: byLookup,
        blockers: blockers,
        registrationScope: registrationScope,
      );
      units[path]!.unit.accept(visitor);
    }

    final immutableByLookup = <DiLookupKey, List<DiEntry>>{
      for (final entry in byLookup.entries)
        entry.key: List<DiEntry>.unmodifiable(entry.value),
    };
    return DiInventory._(
      byNodeId: Map.unmodifiable(byNodeId),
      byLookup: Map.unmodifiable(immutableByLookup),
      blockers: List.unmodifiable(blockers),
    );
  }
}

class _DiRegistrationVisitor extends RecursiveAstVisitor<void> {
  _DiRegistrationVisitor({
    required this.project,
    required this.unit,
    required this.byNodeId,
    required this.byLookup,
    required this.blockers,
    required this.registrationScope,
  });

  final ProjectContext project;
  final ResolvedUnitResult unit;
  final Map<String, DiEntry> byNodeId;
  final Map<DiLookupKey, List<DiEntry>> byLookup;
  final List<DiBlocker> blockers;
  final DiScopeIdentity registrationScope;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element is ConstructorElement && isGetItAsNewInstance(element)) {
      _addNamespaceBlocker(
        'GetIt.asNewInstance creates an additional DI container',
        node,
      );
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final method = _getItMethod(node);
    if (method == null) {
      super.visitMethodInvocation(node);
      return;
    }

    if (_registrationApis.contains(method.name)) {
      _recordRegistration(node, method.name);
    } else if (!_deferredLookupApis.contains(method.name)) {
      _addNamespaceBlocker(
        'resolved GetIt API ${method.name} is outside the modeled registration subset',
        node,
      );
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final element = node.writeElement;
    if (element != null &&
        _runtimeStateProperties.contains(_propertyName(element.displayName)) &&
        _isGetItElement(element)) {
      _addNamespaceBlocker(
        'resolved GetIt API ${_propertyName(element.displayName)} '
        'changes registration semantics',
        node,
      );
    }
    super.visitAssignmentExpression(node);
  }

  void _recordRegistration(MethodInvocation node, String apiName) {
    final type = _registeredType(node);
    if (type == null) {
      _addNamespaceBlocker(
        'GetIt registration has no canonical resolved service type',
        node,
      );
      return;
    }

    final source = DiSourceOccurrence(
      path: project.relative(unit.path),
      offset: node.offset,
    );
    final instanceName = diInstanceName(_namedArgument(node, 'instanceName'));
    final occurrence = switch (instanceName) {
      DiDynamicInstanceName() =>
        DiRegistrationOccurrence.withDynamicInstanceName(
          package: project.packageName,
          type: type,
          source: source,
          scope: registrationScope,
        ),
      _ => DiRegistrationOccurrence(
        package: project.packageName,
        lookup: DiLookupKey(type: type, instanceName: instanceName),
        source: source,
        scope: registrationScope,
      ),
    };
    final dependsOn = _dependsOn(node, occurrence.graphId);
    final entry = DiEntry(
      occurrence: occurrence,
      apiName: apiName,
      origin: _origin(),
      location: _location(node),
      dependsOn: dependsOn,
    );
    byNodeId[entry.nodeId] = entry;
    final lookup = entry.lookup;
    if (lookup != null && entry.isExactBaseScope) {
      (byLookup[lookup] ??= []).add(entry);
    } else if (lookup == null) {
      blockers.add(
        DiBlocker(
          reason: 'GetIt registration has a dynamic instanceName',
          location: entry.location,
          affectedNodeIds: {entry.nodeId},
        ),
      );
    }
  }

  DiTypeKey? _registeredType(MethodInvocation node) {
    final typeArguments = node.typeArgumentTypes;
    if (typeArguments == null || typeArguments.isEmpty) return null;
    // Parameterized factory APIs have additional P1/P2 invocation arguments;
    // their first instantiated generic parameter is still the registered T.
    return diTypeKey(typeArguments.first);
  }

  List<DiLookupKey> _dependsOn(MethodInvocation node, String occurrenceId) {
    final expression = _namedArgument(node, 'dependsOn');
    if (expression == null) return const [];
    if (expression is! ListLiteral) {
      _addOccurrenceBlocker(
        'GetIt registration dependsOn is not a constant type list',
        expression,
        occurrenceId,
      );
      return const [];
    }

    final keys = <DiLookupKey>[];
    for (final element in expression.elements) {
      if (element is! TypeLiteral) {
        _addOccurrenceBlocker(
          'GetIt registration dependsOn contains a dynamic dependency',
          element,
          occurrenceId,
        );
        return const [];
      }
      final type = element.type.type;
      final key = type == null ? null : diTypeKey(type);
      if (key == null) {
        _addOccurrenceBlocker(
          'GetIt registration dependsOn contains an unresolved type',
          element,
          occurrenceId,
        );
        return const [];
      }
      keys.add(
        DiLookupKey(type: key, instanceName: const DiAbsentInstanceName()),
      );
    }
    return List.unmodifiable(keys);
  }

  _GetItMethod? _getItMethod(MethodInvocation node) {
    final element = node.methodName.element;
    if (element is! ExecutableElement || !_isGetItElement(element)) return null;
    return _GetItMethod(element.displayName);
  }

  bool _isGetItElement(Element element) =>
      isGetItLibraryUri(
        element.library?.firstFragment.source.uri.toString() ?? '',
      ) &&
      isGetItApiElement(element);

  String _propertyName(String name) =>
      name.endsWith('=') ? name.substring(0, name.length - 1) : name;

  Uri _origin() {
    final relativePath = project.relative(unit.path);
    if (relativePath.startsWith('lib/')) {
      return Uri.parse(
        'package:${project.packageName}/${relativePath.substring('lib/'.length)}',
      );
    }
    return Uri(path: relativePath);
  }

  Expression? _namedArgument(MethodInvocation node, String name) {
    for (final argument in node.argumentList.arguments) {
      if (analyzerNamedArgumentName(argument) == name) {
        return analyzerArgumentExpression(argument);
      }
    }
    return null;
  }

  void _addNamespaceBlocker(String reason, AstNode node) {
    blockers.add(
      DiBlocker(
        reason: reason,
        location: _location(node),
        affectedNamespace: DiInventory.namespaceFor(project),
      ),
    );
  }

  void _addOccurrenceBlocker(String reason, AstNode node, String occurrenceId) {
    blockers.add(
      DiBlocker(
        reason: reason,
        location: _location(node),
        affectedNodeIds: {occurrenceId},
      ),
    );
  }

  String _location(AstNode node) {
    final position = unit.lineInfo.getLocation(node.offset);
    return '${project.relative(unit.path)}:'
        '${position.lineNumber}:${position.columnNumber}';
  }
}

final class _GetItMethod {
  const _GetItMethod(this.name);

  final String name;
}

/// Finds GetIt operations that make direct base-scope registration semantics
/// unknowable anywhere in this project analysis pass.
final class _GetItRuntimeStateVisitor extends RecursiveAstVisitor<void> {
  bool hasMutation = false;

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element is ConstructorElement && isGetItAsNewInstance(element)) {
      hasMutation = true;
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (element is ExecutableElement && _isGetItElement(element)) {
      final name = element.displayName;
      if (!_registrationApis.contains(name) &&
          !_deferredLookupApis.contains(name)) {
        hasMutation = true;
      }
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final element = node.writeElement;
    if (element != null &&
        _isGetItElement(element) &&
        _runtimeStateProperties.contains(_propertyName(element.displayName))) {
      hasMutation = true;
    }
    super.visitAssignmentExpression(node);
  }

  static bool _isGetItElement(Element element) => isGetItApiElement(element);

  static String _propertyName(String name) =>
      name.endsWith('=') ? name.substring(0, name.length - 1) : name;
}

/// Records syntactically plausible calls only when analyzer errors prevent
/// their semantic classification. It never creates an exact registration.
final class _PlausibleGetItErrorVisitor extends RecursiveAstVisitor<void> {
  _PlausibleGetItErrorVisitor({
    required this.hasDiagnostics,
    required this.hasGetItImport,
  });

  final bool hasDiagnostics;
  final bool hasGetItImport;
  final List<AstNode> nodes = [];
  final Set<AstNode> dynamicReceiverNodes = {};

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final dynamicReceiver = _isDynamicReceiver(node.realTarget);
    if (_relevantMethodNames.contains(node.methodName.name) &&
        !_isProvenNonGetIt(node.methodName.element) &&
        (hasDiagnostics || (dynamicReceiver && hasGetItImport))) {
      nodes.add(node);
      if (dynamicReceiver) dynamicReceiverNodes.add(node);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final name = _assignmentName(node.leftHandSide);
    final dynamicReceiver = _isDynamicReceiver(
      _assignmentTarget(node.leftHandSide),
    );
    if (name != null &&
        _runtimeStateProperties.contains(name) &&
        !_isProvenNonGetIt(node.writeElement) &&
        (hasDiagnostics || (dynamicReceiver && hasGetItImport))) {
      nodes.add(node);
      if (dynamicReceiver) dynamicReceiverNodes.add(node);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (node.constructorName.name?.name == 'asNewInstance' &&
        element == null &&
        hasDiagnostics) {
      nodes.add(node);
    }
    super.visitInstanceCreationExpression(node);
  }

  static bool _isProvenNonGetIt(Element? element) =>
      element != null && !isGetItApiElement(element);

  static String? _assignmentName(Expression expression) => switch (expression) {
    PropertyAccess(:final propertyName) => propertyName.name,
    PrefixedIdentifier(:final identifier) => identifier.name,
    SimpleIdentifier(:final name) => name,
    _ => null,
  };

  static Expression? _assignmentTarget(Expression expression) =>
      switch (expression) {
        PropertyAccess(:final target) => target,
        PrefixedIdentifier(:final prefix) => prefix,
        _ => null,
      };

  static bool _isDynamicReceiver(Expression? expression) =>
      expression?.staticType is DynamicType;

  static const Set<String> _relevantMethodNames = {
    ..._registrationApis,
    ..._lifecycleAndStateApis,
  };
}
