import 'dart:io';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/error/error.dart';

import '../core/project/project_context.dart';

/// Removes specific declarations from Dart source files.
///
/// Uses analyzer AST to locate declarations, then removes them via
/// string splice (preserves formatting and comments).
class DeclarationRemover {
  /// Creates a declaration remover.
  const DeclarationRemover(this.project);

  /// Project context for path resolution.
  final ProjectContext project;

  /// Removes declarations from a file.
  ///
  /// Returns modified source string. Preserves all code, formatting, and
  /// comments outside the removed declarations.
  Future<String> removeDeclarations(
    String filePath,
    List<String> declarationIds,
  ) async {
    final file = File(filePath);
    final originalSource = file.readAsStringSync();
    final parsed = parseString(
      content: originalSource,
      path: filePath,
      throwIfDiagnostics: false,
    );
    final syntaxErrors = parsed.errors.where(
      (error) => error.diagnosticCode.severity == DiagnosticSeverity.ERROR,
    );
    if (syntaxErrors.isNotEmpty) {
      throw DeclarationRemovalException(
        'Cannot safely edit a file with syntax errors: $filePath',
      );
    }

    final spans = <_Span>[];
    final missingIds = <String>[];
    for (final declarationId in declarationIds) {
      final span = _findDeclarationSpan(parsed.unit, declarationId);
      if (span == null) {
        missingIds.add(declarationId);
      } else {
        spans.add(span);
      }
    }
    if (missingIds.isNotEmpty) {
      throw DeclarationRemovalException(
        'Declarations not found in $filePath: ${missingIds.join(', ')}',
      );
    }

    spans.sort((a, b) => b.offset.compareTo(a.offset));
    var modifiedSource = originalSource;
    for (final span in spans) {
      modifiedSource =
          modifiedSource.substring(0, span.offset) +
          modifiedSource.substring(span.offset + span.length);
    }
    if (modifiedSource == originalSource) {
      throw DeclarationRemovalException(
        'Declaration removal made no change: ${declarationIds.join(', ')}',
      );
    }
    return _normalizeTrailingNewline(modifiedSource);
  }

  String _normalizeTrailingNewline(String source) {
    final withoutTrailingWhitespace = source.trimRight();
    if (withoutTrailingWhitespace.isEmpty) return '';
    return '$withoutTrailingWhitespace\n';
  }

  _Span? _findDeclarationSpan(CompilationUnit unit, String declId) {
    // Extract declaration name from ID (format: dart:package/path#name)
    final hashIndex = declId.lastIndexOf('#');
    if (hashIndex == -1) return null;

    final declName = declId.substring(hashIndex + 1);

    final node = _findTopLevelDeclaration(unit, declName);
    if (node == null) return null;

    // Include declaration comments, but never consume a file header attached
    // lexically to the first declaration (`ignore_for_file`, license text,
    // coverage directives, and similar file-scoped metadata).
    var startOffset = node.offset;
    final documentationComment = node.documentationComment;
    if (documentationComment != null) {
      startOffset = documentationComment.offset;
    } else if (!identical(unit.declarations.firstOrNull, node)) {
      final firstToken = node.beginToken;
      dynamic commentToken = firstToken.precedingComments;
      while (commentToken != null) {
        // ignore: avoid_dynamic_calls
        startOffset = commentToken.offset as int;
        // ignore: avoid_dynamic_calls
        final next = commentToken.next;
        if (next == null || identical(next, commentToken)) break;
        commentToken = next;
      }
    }

    final endOffset = node.offset + node.length;
    return _Span(offset: startOffset, length: endOffset - startOffset);
  }

  CompilationUnitMember? _findTopLevelDeclaration(
    CompilationUnit unit,
    String targetName,
  ) {
    for (final declaration in unit.declarations) {
      if (declaration is FunctionDeclaration &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is ClassDeclaration &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is EnumDeclaration &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is MixinDeclaration &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is ExtensionDeclaration &&
          declaration.name?.lexeme == targetName) {
        return declaration;
      }
      if (declaration is ExtensionTypeDeclaration &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is GenericTypeAlias &&
          declaration.name.lexeme == targetName) {
        return declaration;
      }
      if (declaration is TopLevelVariableDeclaration) {
        final variables = declaration.variables.variables;
        if (variables.any((variable) => variable.name.lexeme == targetName)) {
          if (variables.length != 1) {
            throw DeclarationRemovalException(
              'Cannot remove $targetName without also removing sibling '
              'variables from the same declaration.',
            );
          }
          return declaration;
        }
      }
    }
    return null;
  }
}

class _Span {
  _Span({required this.offset, required this.length});
  final int offset;
  final int length;
}

/// Thrown when a declaration cannot be removed exactly as requested.
class DeclarationRemovalException implements Exception {
  /// Creates a removal failure.
  const DeclarationRemovalException(this.message);

  /// Human-readable safety failure.
  final String message;

  @override
  String toString() => message;
}
