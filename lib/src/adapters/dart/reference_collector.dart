import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';

import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/project/project_context.dart';
import '../analyzer_adapter.dart';
import 'analyzer_ast_compat.dart';
import 'dart_ids.dart';
import 'unresolved_reference_index.dart';

/// Records `references` edges between declarations.
///
/// Every edge is resolved through the element model, so a name in a comment,
/// string or changelog is not a reference.
///
/// Edges are attributed to the nearest enclosing declaration. A reference from
/// top-level initialiser code is attributed to the library, which keeps the
/// target alive rather than dropping the edge.
class ReferenceCollector extends RecursiveAstVisitor<void> {
  /// Creates a collector writing into [graph].
  ReferenceCollector({
    required this.project,
    required this.graph,
    required this.libraryId,
    required this.location,
    this.recordReferences = true,
    this.collapseCallerToLibrary = false,
  });

  /// Project the analysis runs against.
  final ProjectContext project;

  /// Graph surface to write edges into.
  final GraphBuilder graph;

  /// Id of the library being visited.
  final String libraryId;

  /// Physical source path containing the reference.
  final String location;

  /// Whether resolved references should become graph edges.
  ///
  /// Generated units can disable this when only unresolved facts are needed.
  final bool recordReferences;

  /// Whether every reference is attributed to [libraryId].
  ///
  /// Generated declarations are not independently modeled. Their resolved and
  /// unresolved uses therefore collapse to the owning generated artifact or
  /// part library instead of fabricating declaration callers.
  final bool collapseCallerToLibrary;

  final Set<UnresolvedReferenceFact> _unresolvedReferences = {};

  /// Facts for references the analyzer could not resolve.
  Set<UnresolvedReferenceFact> get unresolvedReferences =>
      Set.unmodifiable(_unresolvedReferences);

  /// Visit a library unit and collect semantic references once.
  void visitLibrary(CompilationUnit unit) => unit.visitChildren(this);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    super.visitSimpleIdentifier(node);

    final parent = node.parent;
    final isNonRuntimeSyntax =
        node.thisOrAncestorOfType<LibraryDirective>() != null ||
        node.thisOrAncestorOfType<CommentReference>() != null;
    if (isNonRuntimeSyntax) return;

    final element = node.element;
    if (element == null) {
      final isHandledByParent =
          parent is NamedType ||
          parent is ConstructorName ||
          (parent is Label && isAnalyzerNamedArgument(parent.parent)) ||
          _isAssignmentTargetOwnedByParent(node);
      if (!node.inDeclarationContext() && !isHandledByParent) {
        _recordUnresolved(node);
      }
      return;
    }

    _addReference(node, element);
  }

  @override
  void visitNamedType(NamedType node) {
    final element = node.element;
    if (element == null) {
      if (!const {'void', 'dynamic'}.contains(node.name.lexeme)) {
        _recordUnresolved(node);
      }
    } else {
      _addReference(node, element);
    }
    super.visitNamedType(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element == null) {
      _recordUnresolved(node);
    } else {
      _addReference(node, element);
    }
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    if (node.operator.lexeme == '=') {
      _addPlainAssignmentReference(node);
    } else {
      _addCompoundReferences(node);
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    if (_isIncrementOrDecrement(node.operator.lexeme)) {
      _addCompoundReferences(node);
    } else if (node.operator.lexeme != '!' && node.element == null) {
      _recordOperatorUnresolved(node, node.operator.lexeme);
    } else if (node.element != null) {
      _addReference(node, node.element!);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    if (_isIncrementOrDecrement(node.operator.lexeme)) {
      _addCompoundReferences(node);
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final element = node.element;
    // `dynamic == value` and `dynamic != value` resolve to Object.== in the
    // static model, but can dispatch to an overriding implementation.
    final dynamicEquality =
        (node.operator.lexeme == '==' || node.operator.lexeme == '!=') &&
        _isDynamicOrUnknown(node.leftOperand.staticType);
    if (element == null || dynamicEquality) {
      _recordOperatorUnresolved(node, node.operator.lexeme);
    }
    if (element != null) {
      _addReference(node, element);
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    if (_isCompoundIndexTarget(node)) {
      // Compound reads and writes can dispatch to different extensions. The
      // enclosing compound expression records both `[]` and `[]=` plus its
      // arithmetic operator below.
      super.visitIndexExpression(node);
      return;
    }
    final element = node.element;
    if (element == null) {
      _recordUnresolved(
        node,
        nameOverride: node.inSetterContext() ? '[]=' : '[]',
        canDispatchToMemberOverride: true,
        useNameOverride: true,
      );
    } else {
      _addReference(node, element);
    }
    super.visitIndexExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final element = node.element;
    if (element == null) {
      _recordUnresolved(
        node,
        nameOverride: 'call',
        canDispatchToMemberOverride: true,
        useNameOverride: true,
      );
    } else {
      _addReference(node, element);
    }
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitImplicitCallReference(ImplicitCallReference node) {
    final element = node.element;
    if (element == null) {
      _recordUnresolved(
        node,
        nameOverride: 'call',
        canDispatchToMemberOverride: true,
        useNameOverride: true,
      );
    } else {
      _addReference(node, element);
    }
    super.visitImplicitCallReference(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    final element = node.element;
    final dynamicEquality =
        (node.operator.lexeme == '==' || node.operator.lexeme == '!=') &&
        _isDynamicOrUnknown(node.matchedValueType);
    if (element == null || dynamicEquality) {
      _recordOperatorUnresolved(node, node.operator.lexeme);
    }
    if (element != null) {
      _addReference(node, element);
    }
    super.visitRelationalPattern(node);
  }

  @override
  void visitInterpolationExpression(InterpolationExpression node) {
    _recordDynamicProtocol(node.expression, const ['toString']);
    super.visitInterpolationExpression(node);
  }

  @override
  void visitAwaitExpression(AwaitExpression node) {
    _recordDynamicProtocol(node.expression, const ['then']);
    super.visitAwaitExpression(node);
  }

  @override
  void visitForEachPartsWithDeclaration(ForEachPartsWithDeclaration node) {
    _recordIterationProtocols(node);
    super.visitForEachPartsWithDeclaration(node);
  }

  @override
  void visitForEachPartsWithIdentifier(ForEachPartsWithIdentifier node) {
    _recordIterationProtocols(node);
    super.visitForEachPartsWithIdentifier(node);
  }

  @override
  void visitForEachPartsWithPattern(ForEachPartsWithPattern node) {
    _recordIterationProtocols(node);
    super.visitForEachPartsWithPattern(node);
  }

  @override
  void visitSpreadElement(SpreadElement node) {
    _recordDynamicProtocol(node.expression, _syncIterationProtocols);
    super.visitSpreadElement(node);
  }

  @override
  void visitListPattern(ListPattern node) {
    if (_isDynamicOrUnknown(node.matchedValueType)) {
      _recordProtocolFacts(node, const ['length', '[]']);
    }
    super.visitListPattern(node);
  }

  @override
  void visitMapPattern(MapPattern node) {
    if (_isDynamicOrUnknown(node.matchedValueType)) {
      _recordProtocolFacts(node, const ['containsKey', '[]']);
    }
    super.visitMapPattern(node);
  }

  @override
  void visitYieldStatement(YieldStatement node) {
    if (node.star != null) {
      final body = node.thisOrAncestorOfType<FunctionBody>();
      _recordDynamicProtocol(
        node.expression,
        body?.isAsynchronous == true
            ? _asyncIterationProtocols
            : _syncIterationProtocols,
      );
    }
    super.visitYieldStatement(node);
  }

  void _recordIterationProtocols(ForEachParts node) {
    final names = node.parent.awaitKeyword == null
        ? _syncIterationProtocols
        : _asyncIterationProtocols;
    _recordDynamicProtocol(node.iterable, names);
  }

  static const _syncIterationProtocols = ['iterator', 'moveNext', 'current'];
  static const _asyncIterationProtocols = [
    'listen',
    'pause',
    'resume',
    'cancel',
  ];

  void _recordDynamicProtocol(Expression expression, List<String> names) {
    if (_isDynamicOrUnknown(expression.staticType)) {
      _recordProtocolFacts(expression, names);
    }
  }

  bool _isDynamicOrUnknown(DartType? type) =>
      type == null || type is DynamicType || type is InvalidType;

  void _recordProtocolFacts(AstNode node, List<String> names) {
    if (names.isEmpty) {
      _recordUnresolved(node, nameOverride: null, useNameOverride: true);
      return;
    }
    for (final name in names) {
      _recordUnresolved(
        node,
        nameOverride: name,
        canDispatchToMemberOverride: true,
        useNameOverride: true,
      );
    }
  }

  bool _isIncrementOrDecrement(String operator) =>
      operator == '++' || operator == '--';

  void _addPlainAssignmentReference(AssignmentExpression node) {
    final writeElement = node.writeElement;
    if (writeElement == null) {
      // IndexExpression owns its own `[]=` semantic lookup. Recording the
      // assignment node would have no token name and incorrectly widen the
      // whole Dart namespace despite an exact index fact being available.
      if (node.leftHandSide is! IndexExpression) _recordUnresolved(node);
      return;
    }
    _addReference(node, writeElement);
  }

  void _addCompoundReferences(CompoundAssignmentExpression node) {
    final readElement = node.readElement;
    final writeElement = node.writeElement;
    final operatorElement = _compoundOperatorElement(node);
    if (readElement == null || writeElement == null) {
      final target = _compoundTarget(node);
      if (target == null) {
        _recordUnresolved(node, nameOverride: null, useNameOverride: true);
      } else if (target is IndexExpression) {
        // `x[i] += value` (and `x[i]++`) performs an index getter followed by
        // an index setter. Extension dispatch can select separate owners.
        _recordIndexUnresolved(target, '[]');
        _recordIndexUnresolved(target, '[]=');
      } else {
        _recordUnresolved(target, canDispatchToMemberOverride: true);
      }
    }
    // Analyzer can resolve the property/local getter and setter but still
    // leave the compound operator unresolved when their value is dynamic.
    // That operator is independently dispatchable, including ++ and --.
    if (operatorElement == null) {
      _recordUnresolved(
        node,
        nameOverride: _compoundOperatorName(_compoundOperatorLexeme(node)),
        canDispatchToMemberOverride: true,
        useNameOverride: true,
      );
    }
    if (readElement != null) _addReference(node, readElement);
    if (writeElement != null && writeElement != readElement) {
      _addReference(node, writeElement);
    }
    if (operatorElement != null &&
        operatorElement != readElement &&
        operatorElement != writeElement) {
      _addReference(node, operatorElement);
    }
  }

  Element? _compoundOperatorElement(CompoundAssignmentExpression node) =>
      switch (node) {
        AssignmentExpression() => node.element,
        PrefixExpression() => node.element,
        PostfixExpression() => node.element,
        _ => null,
      };

  bool _isCompoundIndexTarget(IndexExpression node) {
    final parent = node.parent;
    if (parent is AssignmentExpression &&
        identical(parent.leftHandSide, node) &&
        parent.operator.lexeme != '=') {
      return true;
    }
    if (parent is PrefixExpression &&
        identical(parent.operand, node) &&
        _isIncrementOrDecrement(parent.operator.lexeme)) {
      return true;
    }
    return parent is PostfixExpression &&
        identical(parent.operand, node) &&
        _isIncrementOrDecrement(parent.operator.lexeme);
  }

  void _recordIndexUnresolved(IndexExpression node, String name) {
    _recordUnresolved(
      node,
      nameOverride: name,
      canDispatchToMemberOverride: true,
      useNameOverride: true,
    );
  }

  bool _isAssignmentTargetOwnedByParent(SimpleIdentifier node) {
    AstNode current = node;
    while (true) {
      final parent = current.parent;
      if (parent is PropertyAccess && identical(parent.propertyName, current)) {
        current = parent;
        continue;
      }
      if (parent is PrefixedIdentifier &&
          identical(parent.identifier, current)) {
        current = parent;
        continue;
      }
      if (parent is ParenthesizedExpression &&
          identical(parent.expression, current)) {
        current = parent;
        continue;
      }
      if (parent is AssignmentExpression &&
          identical(parent.leftHandSide, current)) {
        return true;
      }
      if (parent is PrefixExpression &&
          _isIncrementOrDecrement(parent.operator.lexeme)) {
        return true;
      }
      if (parent is PostfixExpression &&
          _isIncrementOrDecrement(parent.operator.lexeme)) {
        return true;
      }
      return false;
    }
  }

  String? _compoundOperatorName(String operator) {
    if (operator == '++') return '+';
    if (operator == '--') return '-';
    if (!operator.endsWith('=') || operator == '=') return null;
    return _normalizedOperatorName(operator.substring(0, operator.length - 1));
  }

  void _recordOperatorUnresolved(AstNode node, String operator) {
    final name = _normalizedOperatorName(
      operator,
      unaryMinus: node is PrefixExpression,
    );
    _recordUnresolved(
      node,
      nameOverride: name,
      canDispatchToMemberOverride: true,
      useNameOverride: true,
    );
  }

  String _normalizedOperatorName(String operator, {bool unaryMinus = false}) {
    if (operator == '!=') return '==';
    if (operator == '-' && unaryMinus) return 'unary-';
    return operator;
  }

  AstNode? _compoundTarget(CompoundAssignmentExpression node) => switch (node) {
    AssignmentExpression() => node.leftHandSide,
    PrefixExpression() => node.operand,
    PostfixExpression() => node.operand,
    _ => null,
  };

  String _compoundOperatorLexeme(CompoundAssignmentExpression node) =>
      switch (node) {
        AssignmentExpression() => node.operator.lexeme,
        PrefixExpression() => node.operator.lexeme,
        PostfixExpression() => node.operator.lexeme,
        _ => '',
      };

  void _recordUnresolved(
    AstNode node, {
    String? nameOverride,
    bool? canDispatchToMemberOverride,
    bool useNameOverride = false,
  }) {
    _unresolvedReferences.add(
      UnresolvedReferenceFact(
        callerId: _callerId(node),
        location: location,
        offset: node.offset,
        length: node.length,
        name: useNameOverride ? nameOverride : _symbolName(node),
        canDispatchToMember:
            canDispatchToMemberOverride ?? _canDispatchToMember(node),
      ),
    );
  }

  String? _symbolName(AstNode node) {
    if (node is SimpleIdentifier) return node.name;
    if (node is NamedType) return node.name.lexeme;
    if (node is InstanceCreationExpression) {
      return node.constructorName.type.name.lexeme;
    }
    if (node is AssignmentExpression) {
      return _symbolName(node.leftHandSide);
    }
    if (node is PrefixExpression) {
      return node.operator.lexeme;
    }
    if (node is PostfixExpression) {
      return node.operator.lexeme;
    }
    if (node is PropertyAccess) return node.propertyName.name;
    if (node is PrefixedIdentifier) return node.identifier.name;
    return null;
  }

  bool _canDispatchToMember(AstNode node) {
    if (node is PropertyAccess || node is PrefixedIdentifier) return true;
    if (node is AssignmentExpression) {
      return _canDispatchToMember(node.leftHandSide);
    }
    if (node is PrefixExpression || node is PostfixExpression) return true;
    if (node is SimpleIdentifier) {
      // An unqualified runtime use can target an implicit-this member, an
      // inherited member, or a getter/setter. The enclosing library scope is
      // not sufficient to prove otherwise after analyzer recovery.
      return true;
    }
    return false;
  }

  void _addReference(AstNode node, Element element) {
    if (!recordReferences) return;
    // Member references are represented by their owning top-level
    // declaration because member nodes are not part of the graph yet.
    final fragment = DartIds.declarationFragment(element);
    if (fragment == null ||
        !DartIds.isModeledProjectFragment(project, fragment)) {
      return;
    }

    final targetId = DartIds.declaration(project, fragment);
    final fromId = _callerId(node);
    if (fromId == targetId) return;

    graph.addEdge(
      GraphEdge(
        from: fromId,
        to: targetId,
        kind: EdgeKind.references,
        evidence: Evidence(
          kind: EvidenceKind.semanticReference,
          producer: 'dart',
          description: 'semantic reference',
          exact: true,
          location: location,
        ),
      ),
    );
  }

  String _callerId(AstNode node) {
    if (collapseCallerToLibrary) return libraryId;
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
    return libraryId;
  }
}

/// Finds source declarations referenced by generated part files.
///
/// Flutter Pruner does not edit generated output. A declaration referenced by
/// such output therefore cannot be removed independently, even when both the
/// source declaration and the generated helper are otherwise unreachable.
class GeneratedReferenceCollector extends RecursiveAstVisitor<void> {
  /// Creates a collector for generated-unit references into [project].
  GeneratedReferenceCollector({required this.project});

  /// Project being analyzed.
  final ProjectContext project;

  final Set<String> _affectedNodeIds = {};

  /// Project declaration IDs referenced by the generated unit.
  Set<String> get affectedNodeIds => Set.unmodifiable(_affectedNodeIds);

  /// Visits one generated compilation unit.
  void visitLibrary(CompilationUnit unit) => unit.visitChildren(this);

  @override
  void visitSimpleIdentifier(SimpleIdentifier node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitSimpleIdentifier(node);
  }

  @override
  void visitNamedType(NamedType node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitNamedType(node);
  }

  @override
  void visitInstanceCreationExpression(InstanceCreationExpression node) {
    final element = node.constructorName.element;
    if (element != null) _record(element);
    super.visitInstanceCreationExpression(node);
  }

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitBinaryExpression(node);
  }

  @override
  void visitIndexExpression(IndexExpression node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitIndexExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitPostfixExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitAssignmentExpression(node);
  }

  @override
  void visitFunctionExpressionInvocation(FunctionExpressionInvocation node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitFunctionExpressionInvocation(node);
  }

  @override
  void visitImplicitCallReference(ImplicitCallReference node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitImplicitCallReference(node);
  }

  @override
  void visitRelationalPattern(RelationalPattern node) {
    final element = node.element;
    if (element != null) _record(element);
    super.visitRelationalPattern(node);
  }

  void _record(Element element) {
    final fragment = DartIds.declarationFragment(element);
    if (fragment == null ||
        !DartIds.isModeledProjectFragment(project, fragment)) {
      return;
    }
    _affectedNodeIds.add(DartIds.declaration(project, fragment));
  }
}
