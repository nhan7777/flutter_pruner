import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/constant/value.dart';
import 'package:analyzer/dart/element/element.dart';

import 'flutter_gen_index.dart';

/// Bounded exact/pattern evaluation for asset path expressions.
class AssetStringEvaluator {
  /// Creates an evaluator backed by the generated-accessor [index].
  AssetStringEvaluator(this.index);

  /// Generated FlutterGen field-to-asset mapping.
  final FlutterGenIndex index;

  static const int _maxValues = 64;
  static const int _maxProvenanceExpressions = 1024;
  final Map<Element, List<Expression>> _definitions = {};
  final Set<Element> _unboundedVariables = {};

  /// Indexes local/top-level assignments before evaluating sink arguments.
  ///
  /// This is deliberately flow-insensitive: every assignment is a possible
  /// value. Over-retention is acceptable, while considering only the lexical
  /// initializer can turn a later declared-asset assignment into false SAFE.
  void indexUnit(CompilationUnit unit) {
    unit.accept(
      _AssetDefinitionCollector(
        definitions: _definitions,
        unboundedVariables: _unboundedVariables,
      ),
    );
  }

  /// Evaluates [expression] to a finite exact set, or `null` when unbounded.
  Set<String>? exactValues(Expression expression) =>
      _exactValues(expression, const {});

  /// Returns exact string leaves that remain possible even when the complete
  /// value set is unbounded.
  ///
  /// This provenance view is used only to retain declared assets at opaque
  /// call boundaries. It must not be used as proof that an exact asset sink is
  /// fully resolved.
  Set<String> possibleExactValues(Expression expression) =>
      _possibleExactValues(expression, const {});

  /// Returns the bounded expression tree that can carry opaque-call payloads.
  ///
  /// Container literals and constructor arguments are not themselves string
  /// expressions, but their descendants can still cross a native or custom
  /// API boundary. Callers must fail closed when
  /// [AssetExpressionProvenance.complete] is false.
  AssetExpressionProvenance expressionProvenance(Expression expression) {
    final expressions = <Expression>[];
    final stack = <AstNode>[expression];
    final seen = <AstNode>{};
    while (stack.isNotEmpty) {
      final current = stack.removeLast();
      if (!seen.add(current)) continue;
      if (current is Expression) {
        expressions.add(current);
        if (expressions.length > _maxProvenanceExpressions) {
          return AssetExpressionProvenance(
            expressions: expressions.take(_maxProvenanceExpressions).toList(),
            complete: false,
          );
        }
      }
      // Nested calls and closures are visited independently by the asset AST
      // visitor. Descending through them here would make an outer widget or
      // helper call inherit unrelated asset references from its executable
      // subtree and create duplicate, misleading blockers.
      if (current is MethodInvocation ||
          current is FunctionExpressionInvocation ||
          current is InstanceCreationExpression ||
          current is FunctionExpression) {
        continue;
      }
      final children = current.childEntities.whereType<AstNode>().toList();
      stack.addAll(children.reversed);
    }
    return AssetExpressionProvenance(expressions: expressions, complete: true);
  }

  Set<String>? _exactValues(Expression expression, Set<Element> visiting) {
    if (expression is StringLiteral) {
      final value = expression.stringValue;
      return value == null ? null : {value};
    }
    if (expression is ParenthesizedExpression) {
      return _exactValues(expression.expression, visiting);
    }
    if (expression is SimpleIdentifier) {
      return _identifierValues(expression.element, visiting);
    }
    if (expression is PrefixedIdentifier) {
      final generated = index.assetsForElement(expression.identifier.element);
      if (generated.isNotEmpty) return generated;
      if (expression.identifier.name == 'path' ||
          expression.identifier.name == 'keyName') {
        return _exactValues(expression.prefix, visiting);
      }
      return _identifierValues(expression.identifier.element, visiting);
    }
    if (expression is PropertyAccess) {
      final generated = index.assetsForElement(expression.propertyName.element);
      if (generated.isNotEmpty) return generated;
      if (expression.propertyName.name == 'path' ||
          expression.propertyName.name == 'keyName') {
        final target = expression.realTarget;
        return _exactValues(target, visiting);
      }
      return _identifierValues(expression.propertyName.element, visiting);
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '+') {
      final left = _exactValues(expression.leftOperand, visiting);
      final right = _exactValues(expression.rightOperand, visiting);
      if (left == null ||
          right == null ||
          left.length * right.length > _maxValues) {
        return null;
      }
      return {
        for (final leftValue in left)
          for (final rightValue in right) '$leftValue$rightValue',
      };
    }
    if (expression is ConditionalExpression) {
      final thenValues = _exactValues(expression.thenExpression, visiting);
      final elseValues = _exactValues(expression.elseExpression, visiting);
      if (thenValues == null || elseValues == null) return null;
      return {...thenValues, ...elseValues};
    }
    if (expression is AdjacentStrings) {
      var values = <String>{''};
      for (final string in expression.strings) {
        final next = _exactValues(string, visiting);
        if (next == null || values.length * next.length > _maxValues) {
          return null;
        }
        values = {
          for (final prefix in values)
            for (final suffix in next) '$prefix$suffix',
        };
      }
      return values;
    }
    if (expression is StringInterpolation) {
      var values = <String>{''};
      for (final element in expression.elements) {
        final next = switch (element) {
          InterpolationString(:final value) => <String>{value},
          InterpolationExpression(:final expression) => _exactValues(
            expression,
            visiting,
          ),
        };
        if (next == null || values.length * next.length > _maxValues) {
          return null;
        }
        values = {
          for (final prefix in values)
            for (final suffix in next) '$prefix$suffix',
        };
      }
      return values;
    }
    return null;
  }

  Set<String> _possibleExactValues(
    Expression expression,
    Set<Element> visiting,
  ) {
    final exact = _exactValues(expression, visiting);
    if (exact != null) return exact;

    if (expression is ParenthesizedExpression) {
      return _possibleExactValues(expression.expression, visiting);
    }
    if (expression is ConditionalExpression) {
      return {
        ..._possibleExactValues(expression.thenExpression, visiting),
        ..._possibleExactValues(expression.elseExpression, visiting),
      };
    }
    if (expression is MethodInvocation ||
        expression is FunctionExpressionInvocation ||
        expression is InstanceCreationExpression ||
        expression is FunctionExpression) {
      return const {};
    }
    final element = switch (expression) {
      SimpleIdentifier(:final element) => element,
      PrefixedIdentifier(:final identifier) => identifier.element,
      PropertyAccess(:final propertyName) => propertyName.element,
      _ => null,
    };
    final base = element?.baseElement;
    final values = <String>{};
    if (base != null && !visiting.contains(base)) {
      final definitions = _definitions[base];
      if (definitions != null) {
        for (final definition in definitions) {
          values.addAll(_possibleExactValues(definition, {...visiting, base}));
        }
      }
    }
    for (final child in _directNestedExpressions(expression)) {
      values.addAll(_possibleExactValues(child, visiting));
    }
    return values;
  }

  /// Returns an anchored regular expression for a partially-known string.
  RegExp? pattern(Expression expression) {
    final source = _patternSource(expression, const {});
    if (source == null || source == '.*') return null;
    return RegExp('^$source\$');
  }

  Set<String>? _identifierValues(Element? element, Set<Element> visiting) {
    final generated = index.assetsForElement(element);
    if (generated.isNotEmpty) return generated;
    final base = element?.baseElement;
    if (base != null && _definitions.containsKey(base)) {
      if (_unboundedVariables.contains(base) || visiting.contains(base)) {
        return null;
      }
      final values = <String>{};
      for (final definition in _definitions[base]!) {
        final next = _exactValues(definition, {...visiting, base});
        if (next == null || values.length + next.length > _maxValues) {
          return null;
        }
        values.addAll(next);
      }
      return values;
    }
    final variable = base is PropertyAccessorElement ? base.variable : base;
    if (variable is! VariableElement) return null;
    final DartObject? value = variable.computeConstantValue();
    final string = value?.toStringValue();
    return string == null ? null : {string};
  }

  String? _patternSource(Expression expression, Set<Element> visiting) {
    final exact = _exactValues(expression, visiting);
    if (exact != null && exact.length == 1) {
      return RegExp.escape(exact.single);
    }
    if (expression is ParenthesizedExpression) {
      return _patternSource(expression.expression, visiting);
    }
    if (expression is BinaryExpression && expression.operator.lexeme == '+') {
      final left = _patternSource(expression.leftOperand, visiting) ?? '.*';
      final right = _patternSource(expression.rightOperand, visiting) ?? '.*';
      return '$left$right';
    }
    if (expression is StringInterpolation) {
      final buffer = StringBuffer();
      for (final element in expression.elements) {
        switch (element) {
          case InterpolationString(:final value):
            buffer.write(RegExp.escape(value));
          case InterpolationExpression(:final expression):
            buffer.write(_patternSource(expression, visiting) ?? '.*');
        }
      }
      return buffer.toString();
    }
    return null;
  }
}

/// Bounded expression provenance for one opaque-call argument.
class AssetExpressionProvenance {
  /// Creates immutable provenance.
  AssetExpressionProvenance({
    required List<Expression> expressions,
    required this.complete,
  }) : expressions = List.unmodifiable(expressions);

  /// Expressions that may contribute values to the payload.
  final List<Expression> expressions;

  /// Whether every expression was visited within the safety bound.
  final bool complete;
}

Iterable<Expression> _directNestedExpressions(AstNode node) sync* {
  for (final child in node.childEntities) {
    if (child is Expression) {
      yield child;
    } else if (child is AstNode) {
      yield* _directNestedExpressions(child);
    }
  }
}

final class _AssetDefinitionCollector extends RecursiveAstVisitor<void> {
  _AssetDefinitionCollector({
    required this.definitions,
    required this.unboundedVariables,
  });

  final Map<Element, List<Expression>> definitions;
  final Set<Element> unboundedVariables;

  @override
  void visitVariableDeclaration(VariableDeclaration node) {
    final fragment = node.declaredFragment;
    final initializer = node.initializer;
    if (fragment != null && initializer != null) {
      _add(fragment.element, initializer);
    }
    super.visitVariableDeclaration(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final element = _writtenElement(node.leftHandSide);
    if (element != null) {
      if (node.operator.lexeme == '=') {
        _add(element, node.rightHandSide);
      } else {
        unboundedVariables.add(element.baseElement);
      }
    }
    super.visitAssignmentExpression(node);
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    final element = _writtenElement(node.operand);
    if (element != null && const {'++', '--'}.contains(node.operator.lexeme)) {
      unboundedVariables.add(element.baseElement);
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    final element = _writtenElement(node.operand);
    if (element != null) unboundedVariables.add(element.baseElement);
    super.visitPostfixExpression(node);
  }

  void _add(Element element, Expression expression) {
    (definitions[element.baseElement] ??= []).add(expression);
  }

  Element? _writtenElement(Expression expression) => switch (expression) {
    SimpleIdentifier(:final element) => element,
    PrefixedIdentifier(:final identifier) => identifier.element,
    PropertyAccess(:final propertyName) => propertyName.element,
    _ => null,
  };
}
