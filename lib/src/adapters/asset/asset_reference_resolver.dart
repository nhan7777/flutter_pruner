import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/evidence.dart';
import '../../core/project/project_context.dart';
import '../dart/analyzer_ast_compat.dart';
import '../dart/dart_analysis_workspace.dart';
import '../dart/dart_directive_resolver.dart';
import '../dart/dart_execution_reachability_service.dart';
import '../dart/dart_ids.dart';
import '../dart/dart_package_ownership.dart';
import 'asset_inventory.dart';
import 'asset_sink_registry.dart';
import 'asset_string_evaluator.dart';
import 'flutter_gen_index.dart';

/// Resolves asset references in Dart code through semantic analysis.
class AssetReferenceResolver {
  /// Creates a resolver for the given project and asset inventory.
  AssetReferenceResolver(
    this.project,
    this.inventory, {
    required this.ownership,
  });

  /// Project context.
  final ProjectContext project;

  /// Asset inventory to check references against.
  final AssetInventory inventory;

  /// Immutable ownership facts shared by this project analysis pass.
  final DartPackageOwnership ownership;

  /// Exact asset references resolved from const strings.
  final List<ResolvedReference> exactReferences = [];

  /// Blockers for unresolved dynamic constructs.
  final List<BlockerInfo> blockers = [];

  final FlutterGenIndex _flutterGen = FlutterGenIndex();
  static const AssetSinkRegistry _sinks = AssetSinkRegistry();

  /// Analyzes all Dart files in the project to find asset references.
  Future<void> analyzeProject({
    DartAnalysisWorkspace? workspace,
    DartExecutionReachabilitySnapshot? reachability,
  }) async {
    final analysisWorkspace = workspace ?? DartAnalysisWorkspace(project);
    final units = <String, ResolvedUnitResult>{};

    final selectedPaths =
        reachability?.globalUsageUnitPaths ?? analysisWorkspace.dartFiles;
    if (reachability != null) {
      for (final library in reachability.resolvedLibraries) {
        for (final unit in library.units) {
          if (selectedPaths.contains(_canonicalDartPath(unit.path))) {
            units[_canonicalDartPath(unit.path)] = unit;
          }
        }
      }
    }
    for (final filePath in selectedPaths) {
      if (units.containsKey(_canonicalDartPath(filePath))) continue;
      if (ownership.ownerOf(filePath).ownership !=
          DartSourceOwnership.selectedPackage) {
        continue;
      }
      if (project.pathPolicy.shouldExclude(filePath)) continue;
      try {
        final result = await analysisWorkspace.resolveLibrary(filePath);
        if (result is ResolvedLibraryResult) {
          for (final unit in result.units) {
            units[_canonicalDartPath(unit.path)] = unit;
          }
        } else if (result is! NotLibraryButPartResult) {
          blockers.add(
            BlockerInfo(
              reason: 'analyzer could not resolve an asset consumer library',
              location: project.relative(filePath),
              affectedNamespace: 'asset:${project.packageName}/',
              affectedNodeIds: const {},
            ),
          );
        }
      } catch (error) {
        blockers.add(
          BlockerInfo(
            reason: 'analyzer failed while resolving asset consumers',
            location: project.relative(filePath),
            affectedNamespace: 'asset:${project.packageName}/',
            affectedNodeIds: const {},
          ),
        );
      }
    }

    if (reachability != null) {
      final librariesByPath = {
        for (final library in reachability.resolvedLibraries)
          _canonicalDartPath(library.element.firstFragment.source.fullName):
              library.element,
      };
      final externalEdges =
          reachability.directives.edges
              .where((edge) => _edgeSourceIsRetained(reachability, edge))
              .where(
                (edge) =>
                    ownership.ownerOf(edge.targetPath).ownership ==
                    DartSourceOwnership.externalPackage,
              )
              .toList()
            ..sort((left, right) {
              final target = left.targetPath.compareTo(right.targetPath);
              return target != 0
                  ? target
                  : left.sourcePath.compareTo(right.sourcePath);
            });
      final inspectedTargets = <String>{};
      final pendingExternalLibraries = <String, LibraryElement>{};
      for (final edge in externalEdges) {
        final targetPath = edge.targetPath;
        if (!inspectedTargets.add(targetPath)) continue;
        final sourceLibrary =
            librariesByPath[_canonicalDartPath(edge.sourcePath)];
        if (sourceLibrary == null) {
          _blockUninspectableExternalTarget(targetPath);
          continue;
        }
        try {
          final result = await analysisWorkspace.resolveSelectedDirectiveTarget(
            targetPath,
            fromLibrary: sourceLibrary,
          );
          if (result is ResolvedLibraryResult) {
            pendingExternalLibraries[analysisWorkspace.libraryIdentity(
                  result.element,
                )] =
                result.element;
          } else {
            _blockUninspectableExternalTarget(targetPath);
          }
        } on Object {
          _blockUninspectableExternalTarget(targetPath);
        }
      }
      await _inspectExternalReachabilityClosure(
        analysisWorkspace,
        pendingExternalLibraries,
      );
      final hiddenConsumerIssue = reachability.issues
          .where(_canHideAssetConsumer)
          .firstOrNull;
      if (hiddenConsumerIssue != null) {
        blockers.add(
          BlockerInfo(
            reason: 'non-selected Dart source may address selected assets',
            location: hiddenConsumerIssue,
            affectedNamespace: 'asset:${project.packageName}/',
            affectedNodeIds: const {},
          ),
        );
      }
    }

    final boundedClosure = await analysisWorkspace.boundedClosureSnapshot();
    for (final result in boundedClosure.libraries) {
      for (final unit in result.units) {
        units[_canonicalDartPath(unit.path)] = unit;
      }
    }
    for (final issue in boundedClosure.issues) {
      blockers.add(
        BlockerInfo(
          reason: switch (issue.kind) {
            DartBoundedClosureIssueKind.uninspectable =>
              'external Dart closure could not be inspected for asset references',
            DartBoundedClosureIssueKind.conditionalDirective =>
              'conditional external Dart closure may address selected assets',
            DartBoundedClosureIssueKind.selectedConditionalDirective =>
              'conditional selected Dart import/export may address selected assets',
            DartBoundedClosureIssueKind.unknownOwnershipBoundary =>
              'unknown Dart ownership boundary may address selected assets',
          },
          location: issue.location,
          affectedNamespace: 'asset:${project.packageName}/',
          affectedNodeIds: const {},
        ),
      );
    }

    _flutterGen.indexUnits(
      units.values.where(
        (unit) =>
            ownership.ownerOf(unit.path).ownership ==
            DartSourceOwnership.selectedPackage,
      ),
      inventory,
    );
    final orderedUnits = units.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final unit in orderedUnits) {
      final unitOwnership = ownership.ownerOf(unit.path).ownership;
      if (unitOwnership == DartSourceOwnership.selectedPackage &&
          _flutterGen.isGeneratedPath(unit.path)) {
        continue;
      }
      _visitUnit(
        unit,
        canCreateCallerIds:
            unitOwnership == DartSourceOwnership.selectedPackage,
      );
    }
  }

  void _blockUninspectableExternalTarget(String targetPath) {
    blockers.add(
      BlockerInfo(
        reason:
            'execution-selected external Dart library could not be inspected for asset references',
        location: targetPath,
        affectedNamespace: 'asset:${project.packageName}/',
        affectedNodeIds: const {},
      ),
    );
  }

  Future<void> _inspectExternalReachabilityClosure(
    DartAnalysisWorkspace workspace,
    Map<String, LibraryElement> pending,
  ) async {
    final visited = <String>{};
    while (pending.isNotEmpty) {
      final identity = pending.keys.reduce(
        (left, right) => left.compareTo(right) <= 0 ? left : right,
      );
      final element = pending.remove(identity)!;
      if (!visited.add(identity)) continue;

      final SomeResolvedLibraryResult result;
      try {
        result = await workspace.resolveBoundedClosureLibrary(element);
      } on Object {
        workspace.recordBoundedClosureIssue(
          library: element,
          kind: DartBoundedClosureIssueKind.uninspectable,
          location: element.firstFragment.source.fullName,
        );
        continue;
      }
      if (result is! ResolvedLibraryResult) {
        workspace.recordBoundedClosureIssue(
          library: element,
          kind: DartBoundedClosureIssueKind.uninspectable,
          location: element.firstFragment.source.fullName,
        );
        continue;
      }
      if (result.units.any(
        (unit) => unit.diagnostics.any(
          (diagnostic) =>
              diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
        ),
      )) {
        workspace.recordBoundedClosureIssue(
          library: element,
          kind: DartBoundedClosureIssueKind.uninspectable,
          location: element.firstFragment.source.fullName,
        );
      }
      final conditionalPaths =
          result.units
              .where(
                (unit) => unit.unit.directives
                    .whereType<NamespaceDirective>()
                    .any((directive) => directive.configurations.isNotEmpty),
              )
              .map((unit) => unit.path)
              .toList()
            ..sort();
      if (conditionalPaths.isNotEmpty) {
        workspace.recordBoundedClosureIssue(
          library: element,
          kind: DartBoundedClosureIssueKind.conditionalDirective,
          location: conditionalPaths.first,
        );
      }

      for (final dependency in <LibraryElement>{
        ...result.element.firstFragment.importedLibraries,
        ...result.element.exportedLibraries,
      }) {
        final source = dependency.firstFragment.source;
        if (source.uri.isScheme('dart')) continue;
        switch (ownership.ownerOf(source.fullName).ownership) {
          case DartSourceOwnership.selectedPackage:
            blockers.add(
              BlockerInfo(
                reason:
                    'execution-selected external Dart closure may address selected asset consumers',
                location: source.fullName,
                affectedNamespace: 'asset:${project.packageName}/',
                affectedNodeIds: const {},
              ),
            );
          case DartSourceOwnership.externalPackage:
            final dependencyIdentity = workspace.libraryIdentity(dependency);
            if (!visited.contains(dependencyIdentity)) {
              pending.putIfAbsent(dependencyIdentity, () => dependency);
            }
          case DartSourceOwnership.unknown:
            workspace.recordUnknownOwnershipBoundary(source.fullName);
        }
      }
    }
  }

  void _visitUnit(ResolvedUnitResult unit, {required bool canCreateCallerIds}) {
    final evaluator = AssetStringEvaluator(_flutterGen)..indexUnit(unit.unit);
    final visitor = _AssetVisitor(
      this,
      unit,
      evaluator: evaluator,
      canCreateCallerIds: canCreateCallerIds,
    );
    unit.unit.accept(visitor);
  }
}

bool _edgeSourceIsRetained(
  DartExecutionReachabilitySnapshot reachability,
  DartDirectiveEdge edge,
) {
  for (final target in edge.condition.exactTargets) {
    if (reachability.configuredRetainedUnitPaths[target]?.contains(
          edge.sourcePath,
        ) ??
        false) {
      return true;
    }
  }
  for (final target in edge.condition.exactAuxiliaryTargets) {
    if (reachability.auxiliaryRetainedUnitPaths[target.id]?.contains(
          edge.sourcePath,
        ) ??
        false) {
      return true;
    }
  }
  return false;
}

String _canonicalDartPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

bool _canHideAssetConsumer(String issue) =>
    !issue.startsWith('test-environment-incomplete:') &&
    !issue.startsWith('callback-environment-incomplete:') &&
    !issue.startsWith('external-environment-incomplete:') &&
    !issue.startsWith(
      'conditional Dart directive environment is incomplete for this execution context:',
    ) &&
    issue !=
        'conditional Dart imports/exports are incomplete for at least one execution context';

/// AST visitor that finds asset-loading invocations.
class _AssetVisitor extends RecursiveAstVisitor<void> {
  _AssetVisitor(
    this.resolver,
    this.unit, {
    required this.evaluator,
    required this.canCreateCallerIds,
  });

  final AssetReferenceResolver resolver;
  final ResolvedUnitResult unit;
  final AssetStringEvaluator evaluator;
  final bool canCreateCallerIds;

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final logicalKeys = resolver._flutterGen.assetsForElement(node.element);
    if (logicalKeys.isNotEmpty) {
      final callerId = _getCallerId(node);
      final location = _formatLocation(node);
      for (final logicalKey in logicalKeys) {
        _addExactReference(
          logicalKey,
          callerId: callerId,
          location: location,
          evidenceKind: EvidenceKind.generatedAccessor,
          description: 'FlutterGen accessor resolved to $logicalKey',
        );
      }
    } else if (resolver._flutterGen.isUnresolvedGeneratedAccessor(
      node.element,
    )) {
      final callerId = _getCallerId(node);
      resolver.blockers.add(
        BlockerInfo(
          reason: callerId == null
              ? 'non-selected Dart source may address selected assets'
              : 'FlutterGen accessor could not be mapped to a declared asset',
          location: _formatLocation(node),
          affectedNamespace: 'asset:${resolver.project.packageName}/',
          affectedNodeIds: const {},
          sourceNodeId: callerId,
        ),
      );
    }
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    _checkAssetInvocation(node);
    super.visitMethodInvocation(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    _checkAssetConstructor(node);
    super.visitInstanceCreationExpression(node);
  }

  void _checkAssetInvocation(MethodInvocation node) {
    final arguments = node.argumentList.arguments;
    if (AssetReferenceResolver._sinks.isMethodInvocation(node)) {
      if (arguments.isNotEmpty) {
        _resolveAssetArgument(
          analyzerArgumentExpression(arguments.first),
          node,
        );
      }
      return;
    }
    _checkUnrecognizedAssetConsumer(
      arguments,
      node,
      looksLikeAssetConsumer: AssetReferenceResolver._sinks
          .isPotentialMethodInvocation(node),
    );
  }

  void _checkAssetConstructor(InstanceCreationExpression node) {
    final arguments = node.argumentList.arguments;
    if (AssetReferenceResolver._sinks.isInstanceCreation(node)) {
      if (arguments.isNotEmpty) {
        _resolveAssetArgument(
          analyzerArgumentExpression(arguments.first),
          node,
        );
      }
      return;
    }
    _checkUnrecognizedAssetConsumer(
      arguments,
      node,
      looksLikeAssetConsumer: AssetReferenceResolver._sinks
          .isPotentialInstanceCreation(node),
    );
  }

  void _checkUnrecognizedAssetConsumer(
    Iterable<AstNode> arguments,
    AstNode context, {
    required bool looksLikeAssetConsumer,
  }) {
    for (final argument in arguments) {
      final expression = analyzerArgumentExpression(argument);
      final provenance = evaluator.expressionProvenance(expression);
      if (!provenance.complete) {
        _blockUnknownAssetArgument(expression, context);
        continue;
      }
      final affectedNodeIds = <String>{};
      for (final expression in provenance.expressions) {
        final exactValues = evaluator.exactValues(expression);
        final possibleValues =
            exactValues ?? evaluator.possibleExactValues(expression);
        for (final value in possibleValues) {
          final logicalKey = _canonicalLogicalKey(value);
          final asset = resolver.inventory.assets[logicalKey];
          if (asset != null) affectedNodeIds.add(asset.nodeId);
        }
        affectedNodeIds.addAll(_matchingPatternNodeIds(expression));
      }
      if (affectedNodeIds.isNotEmpty) {
        _addUnrecognizedSinkBlocker(context, affectedNodeIds);
        continue;
      }
      if (looksLikeAssetConsumer) {
        _blockUnknownAssetArgument(expression, context);
      }
    }
  }

  void _addUnrecognizedSinkBlocker(
    AstNode context,
    Set<String> affectedNodeIds,
  ) {
    final callerId = _getCallerId(context);
    resolver.blockers.add(
      BlockerInfo(
        reason: callerId == null
            ? 'non-selected Dart source can address a selected asset'
            : 'asset reference passed to an unrecognized asset-loading API',
        location: _formatLocation(context),
        affectedNamespace: null,
        affectedNodeIds: affectedNodeIds,
        sourceNodeId: callerId,
      ),
    );
  }

  void _blockUnknownAssetArgument(Expression argument, AstNode context) {
    final callerId = _getCallerId(context);
    resolver.blockers.add(
      BlockerInfo(
        reason: callerId == null
            ? 'non-selected Dart source may address selected assets'
            : 'unrecognized asset-loading API has a non-constant path',
        location: _formatLocation(argument),
        affectedNamespace: 'asset:${resolver.project.packageName}/',
        affectedNodeIds: const {},
        sourceNodeId: callerId,
      ),
    );
  }

  Set<String> _matchingPatternNodeIds(Expression expression) {
    final pattern = evaluator.pattern(expression);
    if (pattern == null) return const {};
    return {
      for (final entry in resolver.inventory.assets.values)
        if (pattern.hasMatch(entry.logicalKey) ||
            pattern.hasMatch(
              'packages/${resolver.project.packageName}/${entry.logicalKey}',
            ))
          entry.nodeId,
    };
  }

  void _resolveAssetArgument(Expression arg, AstNode context) {
    final location = _formatLocation(arg);

    final constantValues = evaluator.exactValues(arg);
    if (constantValues != null) {
      final callerId = _getCallerId(context);
      final evidenceKind = constantValues.length == 1
          ? EvidenceKind.constString
          : EvidenceKind.finiteStringSet;
      for (final value in constantValues) {
        _addExactReference(
          value,
          callerId: callerId,
          location: location,
          evidenceKind: evidenceKind,
          description: 'resolved to $value',
        );
      }
      return;
    }

    final pattern = evaluator.pattern(arg);
    if (pattern != null) {
      final affectedNodeIds = <String>{};
      for (final entry in resolver.inventory.assets.values) {
        final packageKey =
            'packages/${resolver.project.packageName}/${entry.logicalKey}';
        if (pattern.hasMatch(entry.logicalKey) ||
            pattern.hasMatch(packageKey)) {
          affectedNodeIds.add(entry.nodeId);
        }
      }
      if (affectedNodeIds.isEmpty) return;
      final callerId = _getCallerId(context);
      resolver.blockers.add(
        BlockerInfo(
          reason: callerId == null
              ? 'non-selected Dart source may address selected assets'
              : 'asset path resolves to a dynamic pattern',
          location: location,
          affectedNamespace: callerId == null
              ? 'asset:${resolver.project.packageName}/'
              : null,
          affectedNodeIds: callerId == null ? const {} : affectedNodeIds,
          sourceNodeId: callerId,
        ),
      );
      return;
    }

    // Dynamic expression - scope to all assets in this package
    final callerId = _getCallerId(context);
    resolver.blockers.add(
      BlockerInfo(
        reason: callerId == null
            ? 'non-selected Dart source may address selected assets'
            : 'asset path is a non-constant expression',
        location: location,
        affectedNamespace: 'asset:${resolver.project.packageName}/',
        affectedNodeIds: {},
        sourceNodeId: callerId,
      ),
    );
  }

  void _addExactReference(
    String rawLogicalKey, {
    required String? callerId,
    required String location,
    required EvidenceKind evidenceKind,
    required String description,
  }) {
    final logicalKey = _canonicalLogicalKey(rawLogicalKey);
    final asset = resolver.inventory.assets[logicalKey];
    if (asset == null) return;
    if (callerId == null) {
      resolver.blockers.add(
        BlockerInfo(
          reason: 'non-selected Dart source can address a selected asset',
          location: location,
          affectedNamespace: null,
          affectedNodeIds: {asset.nodeId},
        ),
      );
      return;
    }
    resolver.exactReferences.add(
      ResolvedReference(
        logicalKey: logicalKey,
        isExact: true,
        location: location,
        evidenceKind: evidenceKind,
        description: description,
        callerId: callerId,
      ),
    );
  }

  String _canonicalLogicalKey(String value) {
    final packagePrefix = 'packages/${resolver.project.packageName}/';
    return value.startsWith(packagePrefix)
        ? value.substring(packagePrefix.length)
        : value;
  }

  String _formatLocation(AstNode node) {
    final lineInfo = unit.lineInfo;
    final offset = node.offset;
    final location = lineInfo.getLocation(offset);
    final filePath = resolver.project.relative(unit.path);
    return '$filePath:${location.lineNumber}:${location.columnNumber}';
  }

  String? _getCallerId(AstNode node) {
    if (!canCreateCallerIds) return null;
    if (DartIds.isGeneratedProjectPath(
      resolver.project,
      unit.path,
      ownership: resolver.ownership,
    )) {
      final libraryPath = unit.libraryElement.firstFragment.source.fullName;
      if (p.equals(p.normalize(unit.path), p.normalize(libraryPath))) {
        return DartIds.generatedArtifact(resolver.project, libraryPath);
      }
      return DartIds.library(
        resolver.project,
        unit.libraryElement,
        ownership: resolver.ownership,
      );
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
      if (fragment != null) {
        return DartIds.declaration(
          resolver.project,
          fragment,
          ownership: resolver.ownership,
        );
      }
      current = current.parent;
    }
    return DartIds.library(
      resolver.project,
      unit.libraryElement,
      ownership: resolver.ownership,
    );
  }
}

/// A resolved asset reference.
class ResolvedReference {
  /// Creates a resolved reference.
  ResolvedReference({
    required this.logicalKey,
    required this.isExact,
    required this.location,
    required this.evidenceKind,
    required this.description,
    required this.callerId,
  });

  /// Asset logical key (e.g., 'assets/logo.png').
  final String logicalKey;

  /// Whether this is an exact const string reference.
  final bool isExact;

  /// Source location in file:line:column format.
  final String location;

  /// Kind of evidence for this reference.
  final EvidenceKind evidenceKind;

  /// Human-readable description.
  final String description;

  /// Node ID of the referencing code.
  final String callerId;
}

/// A blocker for unresolved dynamic constructs.
class BlockerInfo {
  /// Creates a blocker.
  BlockerInfo({
    required this.reason,
    required this.location,
    required this.affectedNamespace,
    required this.affectedNodeIds,
    this.sourceNodeId,
  });

  /// Why the construct could not be resolved.
  final String reason;

  /// Source location, if known.
  final String? location;

  /// Namespace prefix this blocker affects (e.g., 'asset:app/assets/icons/').
  final String? affectedNamespace;

  /// Specific node IDs this blocker affects.
  final Set<String> affectedNodeIds;

  /// Reachable caller that makes this uncertainty relevant.
  final String? sourceNodeId;
}
