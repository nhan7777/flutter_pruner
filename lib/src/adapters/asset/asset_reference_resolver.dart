import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/evidence.dart';
import '../../core/project/project_context.dart';
import '../dart/dart_ids.dart';
import 'asset_inventory.dart';
import 'asset_sink_registry.dart';
import 'asset_string_evaluator.dart';
import 'flutter_gen_index.dart';

/// Resolves asset references in Dart code through semantic analysis.
class AssetReferenceResolver {
  /// Creates a resolver for the given project and asset inventory.
  AssetReferenceResolver(this.project, this.inventory);

  /// Project context.
  final ProjectContext project;

  /// Asset inventory to check references against.
  final AssetInventory inventory;

  /// Exact asset references resolved from const strings.
  final List<ResolvedReference> exactReferences = [];

  /// Blockers for unresolved dynamic constructs.
  final List<BlockerInfo> blockers = [];

  final FlutterGenIndex _flutterGen = FlutterGenIndex();
  static const AssetSinkRegistry _sinks = AssetSinkRegistry();

  /// Analyzes all Dart files in the project to find asset references.
  Future<void> analyzeProject() async {
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(p.absolute(project.root.path))],
    );
    final units = <String, ResolvedUnitResult>{};

    for (final context in collection.contexts) {
      final analyzedFiles = context.contextRoot.analyzedFiles().toList()
        ..sort();
      for (final filePath in analyzedFiles) {
        if (!filePath.endsWith('.dart')) continue;
        if (project.pathPolicy.shouldExclude(filePath)) continue;
        try {
          final result = await context.currentSession.getResolvedLibrary(
            filePath,
          );
          if (result is ResolvedLibraryResult) {
            for (final unit in result.units) {
              units[unit.path] = unit;
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
    }

    _flutterGen.indexUnits(units.values, inventory);
    final orderedUnits = units.values.toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final unit in orderedUnits) {
      if (_flutterGen.isGeneratedPath(unit.path)) continue;
      _visitUnit(unit);
    }
  }

  void _visitUnit(ResolvedUnitResult unit) {
    final evaluator = AssetStringEvaluator(_flutterGen)..indexUnit(unit.unit);
    final visitor = _AssetVisitor(this, unit, evaluator: evaluator);
    unit.unit.accept(visitor);
  }
}

/// AST visitor that finds asset-loading invocations.
class _AssetVisitor extends RecursiveAstVisitor<void> {
  _AssetVisitor(this.resolver, this.unit, {required this.evaluator});

  final AssetReferenceResolver resolver;
  final ResolvedUnitResult unit;
  final AssetStringEvaluator evaluator;

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
      resolver.blockers.add(
        BlockerInfo(
          reason: 'FlutterGen accessor could not be mapped to a declared asset',
          location: _formatLocation(node),
          affectedNamespace: 'asset:${resolver.project.packageName}/',
          affectedNodeIds: const {},
          sourceNodeId: _getCallerId(node),
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
      if (arguments.isNotEmpty) _resolveAssetArgument(arguments.first, node);
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
      if (arguments.isNotEmpty) _resolveAssetArgument(arguments.first, node);
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
    NodeList<Expression> arguments,
    AstNode context, {
    required bool looksLikeAssetConsumer,
  }) {
    for (final argument in arguments) {
      final provenance = evaluator.expressionProvenance(argument);
      if (!provenance.complete) {
        _blockUnknownAssetArgument(argument, context);
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
        _blockUnknownAssetArgument(argument, context);
      }
    }
  }

  void _addUnrecognizedSinkBlocker(
    AstNode context,
    Set<String> affectedNodeIds,
  ) {
    resolver.blockers.add(
      BlockerInfo(
        reason: 'asset reference passed to an unrecognized asset-loading API',
        location: _formatLocation(context),
        affectedNamespace: null,
        affectedNodeIds: affectedNodeIds,
        sourceNodeId: _getCallerId(context),
      ),
    );
  }

  void _blockUnknownAssetArgument(Expression argument, AstNode context) {
    resolver.blockers.add(
      BlockerInfo(
        reason: 'unrecognized asset-loading API has a non-constant path',
        location: _formatLocation(argument),
        affectedNamespace: 'asset:${resolver.project.packageName}/',
        affectedNodeIds: const {},
        sourceNodeId: _getCallerId(context),
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
      resolver.blockers.add(
        BlockerInfo(
          reason: 'asset path resolves to a dynamic pattern',
          location: location,
          affectedNamespace: null,
          affectedNodeIds: affectedNodeIds,
          sourceNodeId: _getCallerId(context),
        ),
      );
      return;
    }

    // Dynamic expression - scope to all assets in this package
    resolver.blockers.add(
      BlockerInfo(
        reason: 'asset path is a non-constant expression',
        location: location,
        affectedNamespace: 'asset:${resolver.project.packageName}/',
        affectedNodeIds: {},
        sourceNodeId: _getCallerId(context),
      ),
    );
  }

  void _addExactReference(
    String rawLogicalKey, {
    required String callerId,
    required String location,
    required EvidenceKind evidenceKind,
    required String description,
  }) {
    final logicalKey = _canonicalLogicalKey(rawLogicalKey);
    if (!resolver.inventory.assets.containsKey(logicalKey)) return;
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

  String _getCallerId(AstNode node) {
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
        return DartIds.declaration(resolver.project, fragment);
      }
      current = current.parent;
    }
    return DartIds.library(resolver.project, unit.libraryElement);
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
