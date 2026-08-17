import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import 'asset_inventory.dart';

/// Maps resolved FlutterGen fields and collections to physical asset keys.
///
/// Generated implementations are provenance, not runtime roots. Callers keep
/// an asset alive only when they reference the exact generated field/getter.
class FlutterGenIndex {
  final Map<String, Set<String>> _assetsByElement = {};
  final Set<String> _generatedAccessorKeys = {};
  final Set<String> _generatedPaths = {};

  /// Whether [path] was recognized as FlutterGen asset output.
  bool isGeneratedPath(String path) =>
      _generatedPaths.contains(p.normalize(path));

  /// Asset logical keys represented by [element].
  Set<String> assetsForElement(Element? element) {
    final key = _elementKey(element);
    if (key == null) return const {};
    return _assetsByElement[key] ?? const {};
  }

  /// Whether [element] is a generated accessor whose physical asset mapping
  /// could not be established.
  bool isUnresolvedGeneratedAccessor(Element? element) {
    final key = _elementKey(element);
    return key != null &&
        _generatedAccessorKeys.contains(key) &&
        !_assetsByElement.containsKey(key);
  }

  /// Indexes every recognized generated unit in two deterministic passes.
  void indexUnits(
    Iterable<ResolvedUnitResult> units,
    AssetInventory inventory,
  ) {
    final generatedUnits =
        units
            .where((unit) => _looksLikeFlutterGen(unit.path))
            .toList(growable: false)
          ..sort((a, b) => a.path.compareTo(b.path));

    for (final unit in generatedUnits) {
      _generatedPaths.add(p.normalize(unit.path));
      unit.unit.accept(
        _FlutterGenFieldVisitor(
          path: unit.path,
          inventory: inventory,
          add: _add,
          registerAccessor: _generatedAccessorKeys.add,
        ),
      );
    }

    // Wrappers such as `Assets.foo => _Assets.foo` can nest several levels.
    // Resolve to a fixed point after direct fields/getters have been indexed.
    for (var pass = 0; pass < 64; pass++) {
      var changed = false;
      for (final unit in generatedUnits) {
        final visitor = _FlutterGenCollectionVisitor(
          path: unit.path,
          assetsForElement: assetsForElement,
          add: _add,
        );
        unit.unit.accept(visitor);
        changed = changed || visitor.changed;
      }
      if (!changed) break;
    }
  }

  bool _add(String key, Iterable<String> logicalKeys) {
    final values = _assetsByElement.putIfAbsent(key, () => {});
    final before = values.length;
    values.addAll(logicalKeys);
    return values.length != before;
  }

  bool _looksLikeFlutterGen(String path) {
    final normalized = p.normalize(path);
    final basename = p.basename(normalized);
    if (!basename.endsWith('.dart')) return false;
    final file = File(normalized);
    if (!file.existsSync()) return false;
    try {
      final content = file.readAsStringSync();
      final hasAssetTypes =
          content.contains('AssetGenImage') ||
          content.contains('SvgGenImage') ||
          content.contains('LottieGenImage');
      final conventionalGeneratedName =
          basename.endsWith('.gen.dart') && content.contains('class Assets');
      return (hasAssetTypes && basename.endsWith('.gen.dart')) ||
          (content.contains('FlutterGen') && conventionalGeneratedName);
    } on FileSystemException {
      return false;
    }
  }

  static String? _elementKey(Element? element) {
    if (element == null) return null;
    final base = element.baseElement;
    final normalized = base is PropertyAccessorElement ? base.variable : base;
    final owner = normalized.enclosingElement;
    final ownerName = owner?.name;
    final name = normalized.name;
    final source = normalized.library?.firstFragment.source.fullName;
    if (ownerName == null || name == null || source == null) return null;
    return '${p.normalize(source)}#$ownerName#$name';
  }

  static String _astKey(String path, String owner, String name) =>
      '${p.normalize(path)}#$owner#$name';
}

class _FlutterGenFieldVisitor extends RecursiveAstVisitor<void> {
  _FlutterGenFieldVisitor({
    required this.path,
    required this.inventory,
    required this.add,
    required this.registerAccessor,
  });

  final String path;
  final AssetInventory inventory;
  final bool Function(String, Iterable<String>) add;
  final void Function(String) registerAccessor;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    if (owner != null && _isAssetContainer(owner)) {
      registerAccessor(
        FlutterGenIndex._astKey(
          path,
          owner.namePart.typeName.lexeme,
          node.name.lexeme,
        ),
      );
    }
    final logicalKey = _assetLiteral(node.initializer);
    if (owner != null &&
        logicalKey != null &&
        inventory.assets.containsKey(logicalKey)) {
      add(
        FlutterGenIndex._astKey(
          path,
          owner.namePart.typeName.lexeme,
          node.name.lexeme,
        ),
        [logicalKey],
      );
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isGetter) {
      super.visitMethodDeclaration(node);
      return;
    }

    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    if (owner != null && _isAssetContainer(owner)) {
      final key = FlutterGenIndex._astKey(
        path,
        owner.namePart.typeName.lexeme,
        node.name.lexeme,
      );
      registerAccessor(key);
      final collector = _AssetLiteralCollector(inventory);
      node.body.accept(collector);
      if (collector.logicalKeys.isNotEmpty) add(key, collector.logicalKeys);
    }
    super.visitMethodDeclaration(node);
  }

  String? _assetLiteral(Expression? expression) {
    if (expression is! InstanceCreationExpression) return null;
    final typeName = expression.constructorName.type.name.lexeme;
    if (typeName != 'AssetGenImage' &&
        typeName != 'SvgGenImage' &&
        typeName != 'LottieGenImage') {
      return null;
    }
    final arguments = expression.argumentList.arguments;
    if (arguments.isEmpty) return null;
    final first = arguments.first;
    if (first is! StringLiteral) return null;
    return first.stringValue;
  }

  bool _isAssetContainer(ClassDeclaration owner) =>
      owner.namePart.typeName.lexeme.contains('Assets');
}

class _AssetLiteralCollector extends RecursiveAstVisitor<void> {
  _AssetLiteralCollector(this.inventory);

  final AssetInventory inventory;
  final Set<String> logicalKeys = {};

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final typeName = node.constructorName.type.name.lexeme;
    if (typeName == 'AssetGenImage' ||
        typeName == 'SvgGenImage' ||
        typeName == 'LottieGenImage') {
      final arguments = node.argumentList.arguments;
      if (arguments.isNotEmpty && arguments.first is StringLiteral) {
        final logicalKey = (arguments.first as StringLiteral).stringValue;
        if (logicalKey != null && inventory.assets.containsKey(logicalKey)) {
          logicalKeys.add(logicalKey);
        }
      }
    }
    super.visitInstanceCreationExpression(node);
  }
}

class _FlutterGenCollectionVisitor extends RecursiveAstVisitor<void> {
  _FlutterGenCollectionVisitor({
    required this.path,
    required this.assetsForElement,
    required this.add,
  });

  final String path;
  final Set<String> Function(Element? element) assetsForElement;
  final bool Function(String, Iterable<String>) add;
  bool changed = false;

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (!node.isGetter) {
      super.visitMethodDeclaration(node);
      return;
    }
    final owner = node.thisOrAncestorOfType<ClassDeclaration>();
    if (owner == null) {
      super.visitMethodDeclaration(node);
      return;
    }
    final collector = _ReferencedGeneratedAssets(assetsForElement);
    node.body.accept(collector);
    if (collector.logicalKeys.isNotEmpty) {
      changed =
          add(
            FlutterGenIndex._astKey(
              path,
              owner.namePart.typeName.lexeme,
              node.name.lexeme,
            ),
            collector.logicalKeys,
          ) ||
          changed;
    }
    super.visitMethodDeclaration(node);
  }
}

class _ReferencedGeneratedAssets extends RecursiveAstVisitor<void> {
  _ReferencedGeneratedAssets(this.assetsForElement);

  final Set<String> Function(Element? element) assetsForElement;
  final Set<String> logicalKeys = {};

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    logicalKeys.addAll(assetsForElement(node.element));
    super.visitSimpleIdentifier(node);
  }
}
