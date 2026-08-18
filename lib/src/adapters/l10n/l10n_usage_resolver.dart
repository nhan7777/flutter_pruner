import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import '../dart/dart_analysis_workspace.dart';
import '../dart/dart_ids.dart';
import 'arb_inventory.dart';
import 'l10n_config.dart';

/// An exact semantic use of one configured ARB message.
final class L10nReference {
  /// Creates a reference from a modeled Dart declaration to an ARB key.
  const L10nReference({
    required this.l10nNodeId,
    required this.callerId,
    required this.location,
    required this.description,
  });

  /// Stable graph id of an existing [ArbKey].
  final String l10nNodeId;

  /// Stable modeled Dart owner of the consumer expression.
  final String callerId;

  /// Project-relative source location.
  final String location;

  /// Report-facing explanation of the resolved member use.
  final String description;
}

/// A bounded l10n uncertainty that an adapter must turn into a graph blocker.
final class L10nBlocker {
  /// Creates a deterministic, source- or domain-scoped blocker.
  L10nBlocker({
    required this.reason,
    this.location,
    this.sourceNodeId,
    this.affectedNamespace,
    Set<String> affectedNodeIds = const {},
  }) : affectedNodeIds = Set.unmodifiable(affectedNodeIds),
       assert(affectedNamespace != null || affectedNodeIds.isNotEmpty);

  /// Why the localization relation could not be proven.
  final String reason;

  /// Project-relative source location when available.
  final String? location;

  /// Modeled Dart owner when the uncertain source is modeled.
  final String? sourceNodeId;

  /// Bounded localization namespace when no exact key is known.
  final String? affectedNamespace;

  /// Existing ARB node ids affected by this uncertainty.
  final Set<String> affectedNodeIds;
}

/// Resolves configured gen-l10n members by analyzer element identity.
///
/// The resolver only accepts members declared by the exact configured output
/// library and output class. It never treats a matching spelling in another
/// class or library as localization usage.
final class L10nUsageResolver {
  /// Creates a resolver for one valid l10n [config] and ARB [inventory].
  L10nUsageResolver(this.project, this.config, this.inventory);

  /// Project being inspected.
  final ProjectContext project;

  /// Current real-source gen-l10n output configuration.
  final L10nConfig config;

  /// Existing localization nodes that may be referenced.
  final ArbInventory inventory;

  /// Exact modeled caller-to-ARB references.
  final List<L10nReference> _references = [];

  /// Immutable exact modeled caller-to-ARB references.
  List<L10nReference> get references => List.unmodifiable(_references);

  /// Bounded configuration, generated-output, and consumer uncertainty.
  final List<L10nBlocker> _blockers = [];

  /// Immutable bounded configuration and consumer uncertainty.
  List<L10nBlocker> get blockers => List.unmodifiable(_blockers);

  /// Normalized configured output units, including parts, when resolved.
  final Set<String> _generatedOutputPaths = <String>{};

  /// Immutable normalized configured output paths, including siblings.
  Set<String> get generatedOutputPaths =>
      Set.unmodifiable(_generatedOutputPaths);

  /// Exact Dart namespaces that must be protected for generated output.
  final Set<String> _generatedDartNamespaces = <String>{};

  /// Immutable exact Dart namespaces for generated output protection.
  Set<String> get generatedDartNamespaces =>
      Set.unmodifiable(_generatedDartNamespaces);

  /// Resolves the configured output once, then visits consumer libraries using
  /// the same shared [workspace] cache.
  Future<void> analyzeProject({
    required DartAnalysisWorkspace workspace,
    Set<String>? includedUnitPaths,
  }) async {
    _generatedDartNamespaces.add(
      _dartNamespaceFor(project, config.generatedLibraryPath),
    );
    final index = await _loadExpectedMembers(workspace);
    if (index == null) {
      _sortAndDedupe();
      return;
    }

    final units = <String, ResolvedUnitResult>{};
    for (final path in workspace.dartFiles) {
      if (project.pathPolicy.shouldExclude(path)) continue;
      if (includedUnitPaths != null &&
          !includedUnitPaths.contains(_normalizedPath(path))) {
        continue;
      }
      try {
        final result = await workspace.resolveLibrary(path);
        if (result is ResolvedLibraryResult) {
          for (final unit in result.units) {
            units[_normalizedPath(unit.path)] = unit;
          }
        } else if (result is! NotLibraryButPartResult) {
          _addNamespaceBlocker(
            'analyzer could not resolve a localization consumer library',
            location: project.relative(path),
          );
        }
      } catch (_) {
        _addNamespaceBlocker(
          'analyzer failed while resolving localization consumer libraries',
          location: project.relative(path),
        );
      }
    }

    final paths = units.keys.toList()..sort();
    for (final path in paths) {
      final unit = units[path]!;
      if (_generatedOutputPaths.contains(path)) continue;
      if (includedUnitPaths != null && !includedUnitPaths.contains(path)) {
        continue;
      }
      if (unit.diagnostics.isNotEmpty) {
        _addNamespaceBlocker(
          'analyzer errors prevent semantic localization usage classification',
          location: project.relative(unit.path),
        );
      }
      unit.unit.accept(_L10nUseVisitor(this, index, unit));
    }
    _sortAndDedupe();
  }

  Future<_MemberIndex?> _loadExpectedMembers(
    DartAnalysisWorkspace workspace,
  ) async {
    final outputPath = _normalizedPath(config.generatedLibraryPath);
    final ResolvedLibraryResult output;
    try {
      final workspacePath = workspace.dartFiles
          .where((path) => _normalizedPath(path) == outputPath)
          .firstOrNull;
      if (workspacePath == null) {
        _addNamespaceBlocker(
          'configured generated localization output is missing or not analyzed',
          location: project.relative(config.generatedLibraryPath),
        );
        return null;
      }
      final result = await workspace.resolveLibrary(workspacePath);
      if (result is! ResolvedLibraryResult) {
        _addNamespaceBlocker(
          'configured generated localization output is missing or not a library',
          location: project.relative(config.generatedLibraryPath),
        );
        return null;
      }
      output = result;
    } catch (_) {
      _addNamespaceBlocker(
        'analyzer failed to resolve configured generated localization output',
        location: project.relative(config.generatedLibraryPath),
      );
      return null;
    }

    for (final unit in output.units) {
      _addGeneratedOutputPath(unit.path);
    }
    _addGeneratedOutputPath(outputPath);
    for (final imported in output.element.firstFragment.importedLibraries) {
      final source = imported.firstFragment.source;
      if (_isOutputFamilyPath(source.fullName)) {
        _addGeneratedOutputPath(source.fullName);
      }
    }
    if (output.units.any((unit) => unit.diagnostics.isNotEmpty)) {
      _addNamespaceBlocker(
        'analyzer errors prevent configured localization output resolution',
        location: project.relative(config.generatedLibraryPath),
      );
      return null;
    }

    final classes = output.element.classes
        .where((element) => element.name == config.outputClass)
        .toList(growable: false);
    if (classes.length != 1) {
      _addNamespaceBlocker(
        classes.isEmpty
            ? 'configured localization output class is missing'
            : 'configured localization output class is ambiguous',
        location: project.relative(config.generatedLibraryPath),
      );
      return null;
    }

    final members = <_MemberIdentity, ArbKey>{};
    final classElement = classes.single;
    for (final key in inventory.keys) {
      final candidates = switch (key.memberKind) {
        ArbGeneratedMemberKind.getter =>
          classElement.getters
              .where((member) => member.name == key.key)
              .cast<ExecutableElement>(),
        ArbGeneratedMemberKind.method =>
          classElement.methods
              .where((member) => member.name == key.key)
              .cast<ExecutableElement>(),
      }.toList(growable: false);
      final wrongShape = switch (key.memberKind) {
        ArbGeneratedMemberKind.getter => classElement.methods.any(
          (member) => member.name == key.key,
        ),
        ArbGeneratedMemberKind.method => classElement.getters.any(
          (member) => member.name == key.key,
        ),
      };
      if (candidates.length != 1 || wrongShape) {
        _blockers.add(
          L10nBlocker(
            reason: candidates.isEmpty
                ? 'generated localization member is missing or has the wrong shape'
                : 'generated localization member is ambiguous',
            location: key.location,
            affectedNodeIds: {key.nodeId},
          ),
        );
        continue;
      }
      final identity = _MemberIdentity.from(candidates.single);
      if (!identity.isDeclaredBy(classElement, outputPath)) {
        _blockers.add(
          L10nBlocker(
            reason:
                'generated localization member is not declared by configured output',
            location: key.location,
            affectedNodeIds: {key.nodeId},
          ),
        );
        continue;
      }
      final previous = members[identity];
      if (previous != null) {
        _blockers.add(
          L10nBlocker(
            reason: 'generated localization member identity is ambiguous',
            location: key.location,
            affectedNodeIds: {previous.nodeId, key.nodeId},
          ),
        );
        members.remove(identity);
      } else {
        members[identity] = key;
      }
    }
    return _MemberIndex(
      members: members,
      outputClass: classElement,
      outputPath: outputPath,
    );
  }

  void _addGeneratedOutputPath(String path) {
    final normalized = _normalizedPath(path);
    _generatedOutputPaths.add(normalized);
    _generatedDartNamespaces.add(_dartNamespaceFor(project, normalized));
  }

  bool _blockUnresolvedMemberName(
    String name,
    AstNode node,
    ResolvedUnitResult unit,
  ) {
    final matches = inventory.keys
        .where((key) => key.key == name)
        .toList(growable: false);
    if (matches.length != 1) return false;
    _addBlocker(
      reason: 'dynamic localization member access cannot be resolved',
      node: node,
      unit: unit,
      affectedNodeIds: {matches.single.nodeId},
    );
    return true;
  }

  bool _isOutputFamilyPath(String path) {
    final normalized = _normalizedPath(path);
    final outputDir = _normalizedPath(config.outputDir);
    if (p.dirname(normalized) != outputDir) return false;
    final family = _GeneratedOutputFamily(config.outputLocalizationFile);
    final candidate = p.basename(normalized);
    return candidate == family.primary ||
        (candidate.startsWith('${family.stem}_') &&
            candidate.endsWith(family.suffix));
  }

  void _recordCustomLookup(
    _MemberIndex index,
    MethodInvocation node,
    ResolvedUnitResult unit,
  ) {
    if (_normalizedPath(unit.path) == index.outputPath ||
        _generatedOutputPaths.contains(_normalizedPath(unit.path))) {
      return;
    }
    final arguments = node.argumentList.arguments;
    if (arguments.length != 1) {
      _addNamespaceBlocker(
        'custom localization lookup has an unknown key shape',
        node: node,
        unit: unit,
      );
      return;
    }
    final value = _constantString(arguments.single);
    if (value == null) {
      _addNamespaceBlocker(
        'custom localization lookup has a dynamic key',
        node: node,
        unit: unit,
      );
      return;
    }
    final key = inventory.keys.where((candidate) => candidate.key == value);
    if (key.length != 1) {
      _addNamespaceBlocker(
        'custom localization lookup names no declared ARB key',
        node: node,
        unit: unit,
      );
      return;
    }
    _addBlocker(
      reason: 'unconfigured custom localization API has a constant ARB key',
      node: node,
      unit: unit,
      affectedNodeIds: {key.single.nodeId},
    );
  }

  void _addNamespaceBlocker(
    String reason, {
    String? location,
    AstNode? node,
    ResolvedUnitResult? unit,
  }) => _blockers.add(
    L10nBlocker(
      reason: reason,
      location:
          location ??
          (node == null || unit == null
              ? null
              : _location(project, unit, node)),
      sourceNodeId: node == null || unit == null
          ? null
          : _callerId(node, null, unit: unit),
      affectedNamespace: ArbInventory.namespaceFor(project),
    ),
  );

  void _addBlocker({
    required String reason,
    required AstNode node,
    required ResolvedUnitResult unit,
    required Set<String> affectedNodeIds,
  }) {
    _blockers.add(
      L10nBlocker(
        reason: reason,
        location: _location(project, unit, node),
        sourceNodeId: _callerId(node, null, unit: unit),
        affectedNodeIds: Set.unmodifiable(affectedNodeIds),
      ),
    );
  }

  String? _callerId(
    AstNode node,
    String? outputPath, {
    required ResolvedUnitResult unit,
  }) {
    final currentUnit = unit;
    final normalized = _normalizedPath(currentUnit.path);
    if (outputPath != null && normalized == outputPath) return null;
    if (_generatedOutputPaths.contains(normalized) ||
        !DartIds.isModeledProjectPath(project, currentUnit.path)) {
      return null;
    }
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
      if (fragment != null) return DartIds.declaration(project, fragment);
      current = current.parent;
    }
    return DartIds.library(project, currentUnit.libraryElement);
  }

  void _sortAndDedupe() {
    final referenceKeys = <String>{};
    _references.removeWhere(
      (reference) => !referenceKeys.add(
        '${reference.callerId}\u0000${reference.l10nNodeId}\u0000${reference.location}',
      ),
    );
    _references.sort(
      (left, right) => '${left.location}\u0000${left.l10nNodeId}'.compareTo(
        '${right.location}\u0000${right.l10nNodeId}',
      ),
    );
    final blockerKeys = <String>{};
    _blockers.removeWhere(
      (blocker) => !blockerKeys.add(
        '${blocker.reason}\u0000${blocker.location}\u0000${blocker.sourceNodeId}\u0000'
        '${blocker.affectedNamespace}\u0000${(blocker.affectedNodeIds.toList()..sort()).join(',')}',
      ),
    );
    _blockers.sort(
      (left, right) => '${left.location}\u0000${left.reason}'.compareTo(
        '${right.location}\u0000${right.reason}',
      ),
    );
  }
}

final class _GeneratedOutputFamily {
  _GeneratedOutputFamily(String outputLocalizationFile)
    : primary = p.basename(outputLocalizationFile),
      stem = _stem(p.basename(outputLocalizationFile)),
      suffix = _suffix(p.basename(outputLocalizationFile));

  final String primary;
  final String stem;
  final String suffix;

  static String _stem(String filename) {
    final firstDot = filename.indexOf('.');
    return firstDot > 0 ? filename.substring(0, firstDot) : filename;
  }

  static String _suffix(String filename) {
    final firstDot = filename.indexOf('.');
    return firstDot > 0 ? filename.substring(firstDot) : '.dart';
  }
}

final class _MemberIndex {
  const _MemberIndex({
    required this.members,
    required this.outputClass,
    required this.outputPath,
  });

  final Map<_MemberIdentity, ArbKey> members;
  final InterfaceElement outputClass;
  final String outputPath;
}

final class _MemberIdentity {
  const _MemberIdentity({
    required this.libraryPath,
    required this.ownerName,
    required this.kind,
    required this.name,
  });

  factory _MemberIdentity.from(Element element) {
    final base = element.baseElement;
    final owner = _interfaceOwner(base);
    final library = base.library;
    return _MemberIdentity(
      libraryPath: library == null
          ? '<unknown>'
          : _normalizedPath(library.firstFragment.source.fullName),
      ownerName: owner?.name ?? '<unknown>',
      kind: base is PropertyAccessorElement ? 'getter' : 'method',
      name: base.displayName,
    );
  }

  final String libraryPath;
  final String ownerName;
  final String kind;
  final String name;

  bool isDeclaredBy(InterfaceElement owner, String outputPath) =>
      libraryPath == outputPath && ownerName == owner.name;

  @override
  bool operator ==(Object other) =>
      other is _MemberIdentity &&
      libraryPath == other.libraryPath &&
      ownerName == other.ownerName &&
      kind == other.kind &&
      name == other.name;

  @override
  int get hashCode => Object.hash(libraryPath, ownerName, kind, name);
}

final class _L10nUseVisitor extends RecursiveAstVisitor<void> {
  _L10nUseVisitor(this.resolver, this.index, this.unit);

  final L10nUsageResolver resolver;
  final _MemberIndex index;
  final ResolvedUnitResult unit;

  @override
  void visitPropertyAccess(PropertyAccess node) {
    final element = node.propertyName.element;
    if (element == null) {
      resolver._blockUnresolvedMemberName(node.propertyName.name, node, unit);
    } else {
      resolver._recordInUnit(index, element, node, unit);
    }
    super.visitPropertyAccess(node);
  }

  @override
  void visitPrefixedIdentifier(PrefixedIdentifier node) {
    final element = node.identifier.element;
    if (element == null) {
      resolver._blockUnresolvedMemberName(node.identifier.name, node, unit);
    } else {
      resolver._recordInUnit(index, element, node, unit);
    }
    super.visitPrefixedIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final element = node.methodName.element;
    if (element == null) {
      final blockedKey = resolver._blockUnresolvedMemberName(
        node.methodName.name,
        node,
        unit,
      );
      if (!blockedKey && node.target?.staticType is DynamicType) {
        resolver._addNamespaceBlocker(
          'dynamic localization API cannot be resolved',
          node: node,
          unit: unit,
        );
      }
    } else {
      resolver._recordInUnit(index, element, node, unit);
    }
    if (element is ExecutableElement &&
        _isCustomStringLookup(element, index) &&
        !index.members.containsKey(_MemberIdentity.from(element))) {
      resolver._recordCustomLookup(index, node, unit);
    }
    super.visitMethodInvocation(node);
  }

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    if (!_isHandledQualifiedOrInvocationName(node)) {
      resolver._recordInUnit(index, node.element, node, unit);
    }
    super.visitSimpleIdentifier(node);
  }

  bool _isHandledQualifiedOrInvocationName(SimpleIdentifier node) {
    final parent = node.parent;
    return parent is PropertyAccess && identical(parent.propertyName, node) ||
        parent is PrefixedIdentifier && identical(parent.identifier, node) ||
        parent is MethodInvocation && identical(parent.methodName, node);
  }
}

extension on L10nUsageResolver {
  void _recordInUnit(
    _MemberIndex index,
    Element? element,
    AstNode node,
    ResolvedUnitResult unit,
  ) {
    if (_generatedOutputPaths.contains(_normalizedPath(unit.path))) return;
    final key = element == null
        ? null
        : index.members[_MemberIdentity.from(element)];
    if (key == null) return;
    final callerId = _callerId(node, index.outputPath, unit: unit);
    if (callerId == null) {
      _addBlocker(
        reason:
            'localization use occurs in an unmodeled or generated Dart source',
        node: node,
        unit: unit,
        affectedNodeIds: {key.nodeId},
      );
      return;
    }
    _references.add(
      L10nReference(
        l10nNodeId: key.nodeId,
        callerId: callerId,
        location: _location(project, unit, node),
        description: 'uses generated localization member ${key.key}',
      ),
    );
  }
}

InterfaceElement? _interfaceOwner(Element element) {
  Element? current = element;
  while (current != null && current is! InterfaceElement) {
    current = current.enclosingElement;
  }
  return current as InterfaceElement?;
}

bool _belongsTo(ExecutableElement element, InterfaceElement owner) =>
    _interfaceOwner(element.baseElement) == owner;

String? _constantString(AstNode node) {
  if (node is StringLiteral) return node.stringValue;
  final element = switch (node) {
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
  return value?.toStringValue();
}

bool _isCustomStringLookup(ExecutableElement element, _MemberIndex index) {
  if (!_belongsTo(element, index.outputClass) ||
      _MemberIdentity.from(element).libraryPath != index.outputPath) {
    return false;
  }
  if (element.formalParameters.length != 1 ||
      !element.formalParameters.single.type.isDartCoreString) {
    return false;
  }
  return element.returnType.isDartCoreString;
}

String _normalizedPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

String _dartNamespaceFor(ProjectContext project, String path) {
  final root = project.root.resolveSymbolicLinksSync();
  return 'dart:${project.packageName}/${p.relative(_normalizedPath(path), from: root).replaceAll(r'\', '/')}';
}

String _location(
  ProjectContext project,
  ResolvedUnitResult unit,
  AstNode node,
) {
  final position = unit.lineInfo.getLocation(node.offset);
  return '${project.relative(unit.path)}:${position.lineNumber}:${position.columnNumber}';
}
