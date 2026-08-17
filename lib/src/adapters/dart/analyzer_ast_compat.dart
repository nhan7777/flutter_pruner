import 'package:analyzer/dart/ast/ast.dart';

/// Whether [node] is the named form of an invocation argument.
///
/// Analyzer 14 replaced `NamedExpression` with a non-expression
/// `NamedArgument`. This keeps argument handling on the shared public AST
/// surface while the package supports both analyzer 12 and 14.
bool isAnalyzerNamedArgument(AstNode? node) {
  if (node == null || node.parent is! ArgumentList) return false;
  if (node is! Expression) return true;
  return node.childEntities.any((entity) => entity is Label);
}

/// Returns the value expression carried by an invocation argument.
Expression analyzerArgumentExpression(AstNode argument) {
  if (!isAnalyzerNamedArgument(argument) && argument is Expression) {
    return argument;
  }
  final expressions = argument.childEntities
      .whereType<Expression>()
      .where((child) => identical(child.parent, argument))
      .toList(growable: false);
  if (expressions.length == 1) return expressions.single;
  throw StateError(
    'Unsupported analyzer argument shape: ${argument.runtimeType}',
  );
}

/// Returns the source name of a named argument, or `null` when positional.
String? analyzerNamedArgumentName(AstNode argument) =>
    isAnalyzerNamedArgument(argument) ? argument.beginToken.lexeme : null;

/// Returns an extension type's declared name across analyzer 12–14.
String analyzerExtensionTypeName(ExtensionTypeDeclaration declaration) {
  // Analyzer 14 exposes namePart but keeps this analyzer 12 API as deprecated.
  // ignore: deprecated_member_use
  return declaration.primaryConstructor.typeName.lexeme;
}
