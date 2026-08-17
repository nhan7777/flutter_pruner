// ignore_for_file: public_member_api_docs

import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';

import '../../core/project/project_context.dart';
import 'analyzer_ast_compat.dart';
import 'dart_ids.dart';

/// A conservative project-wide symbol index for unresolved references.
///
/// It deliberately ignores import visibility. A name may be available through
/// an export, prefix, conditional branch, or an analyzer recovery path that is
/// not represented by the resolved element. Retaining every same-named local
/// declaration is broader than necessary, but never permits a false SAFE.
final class UnresolvedReferenceIndex {
  UnresolvedReferenceIndex(this.project);

  final ProjectContext project;
  final Map<String, Set<String>> _topLevelByName = {};
  final Map<String, Set<String>> _memberOwnersByName = {};
  final Set<String> _noSuchMethodOwners = {};
  final Set<String> _indexedPaths = {};

  void indexUnit(CompilationUnit unit, String path) {
    if (!_indexedPaths.add(path)) return;
    unit.accept(_UnresolvedReferenceIndexVisitor(this));
  }

  Set<String> candidatesFor(UnresolvedReferenceFact fact) {
    final name = fact.name;
    if (name == null || name.isEmpty) return const {};
    final candidates = <String>{
      ...?_topLevelByName[name],
      ...?_memberOwnersByName[name],
      if (fact.canDispatchToMember) ..._noSuchMethodOwners,
    };
    return Set.unmodifiable(candidates);
  }

  void addTopLevel(String name, Fragment? fragment) {
    if (fragment == null || name.isEmpty) return;
    _add(_topLevelByName, name, DartIds.declaration(project, fragment));
  }

  void addMemberOwner(String name, Fragment? owner) {
    if (owner == null || name.isEmpty) return;
    final ownerId = DartIds.declaration(project, owner);
    _add(_memberOwnersByName, name, ownerId);
    if (name == 'noSuchMethod') _noSuchMethodOwners.add(ownerId);
  }

  void _add(Map<String, Set<String>> target, String name, String id) {
    (target[name] ??= {}).add(id);
  }
}

/// An unresolved use together with the smallest syntax-derived lookup shape.
///
/// [name] is intentionally nullable: parser recovery can produce syntax that
/// has no reliable symbol token. Those facts must retain the namespace fallback
/// instead of pretending the empty candidate set is proof of safety.
final class UnresolvedReferenceFact {
  const UnresolvedReferenceFact({
    required this.callerId,
    required this.location,
    required this.offset,
    required this.length,
    required this.name,
    required this.canDispatchToMember,
  });

  final String callerId;
  final String location;
  final int offset;
  final int length;
  final String? name;
  final bool canDispatchToMember;

  @override
  bool operator ==(Object other) =>
      other is UnresolvedReferenceFact &&
      callerId == other.callerId &&
      location == other.location &&
      offset == other.offset &&
      length == other.length &&
      name == other.name &&
      canDispatchToMember == other.canDispatchToMember;

  @override
  int get hashCode => Object.hash(
    callerId,
    location,
    offset,
    length,
    name,
    canDispatchToMember,
  );
}

final class _UnresolvedReferenceIndexVisitor extends RecursiveAstVisitor<void> {
  _UnresolvedReferenceIndexVisitor(this.index);

  final UnresolvedReferenceIndex index;

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (node.parent is CompilationUnit) {
      index.addTopLevel(node.name.lexeme, node.declaredFragment);
    }
    super.visitFunctionDeclaration(node);
  }

  @override
  void visitTopLevelVariableDeclaration(TopLevelVariableDeclaration node) {
    for (final variable in node.variables.variables) {
      index.addTopLevel(variable.name.lexeme, variable.declaredFragment);
    }
    super.visitTopLevelVariableDeclaration(node);
  }

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    _indexType(
      node.namePart.typeName.lexeme,
      node.declaredFragment,
      node.body.members,
    );
    super.visitClassDeclaration(node);
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    _indexType(
      node.namePart.typeName.lexeme,
      node.declaredFragment,
      node.body.members,
    );
    super.visitEnumDeclaration(node);
  }

  @override
  void visitEnumConstantDeclaration(EnumConstantDeclaration node) {
    final enclosingEnum = node.thisOrAncestorOfType<EnumDeclaration>();
    index.addMemberOwner(node.name.lexeme, enclosingEnum?.declaredFragment);
    super.visitEnumConstantDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    _indexType(node.name.lexeme, node.declaredFragment, node.body.members);
    super.visitMixinDeclaration(node);
  }

  @override
  void visitExtensionTypeDeclaration(ExtensionTypeDeclaration node) {
    _indexType(
      analyzerExtensionTypeName(node),
      node.declaredFragment,
      node.body.members,
    );
    super.visitExtensionTypeDeclaration(node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name?.lexeme;
    if (name != null) {
      _indexType(name, node.declaredFragment, node.body.members);
    }
    super.visitExtensionDeclaration(node);
  }

  @override
  void visitGenericTypeAlias(GenericTypeAlias node) {
    index.addTopLevel(node.name.lexeme, node.declaredFragment);
    super.visitGenericTypeAlias(node);
  }

  void _indexType(String name, Fragment? owner, List<ClassMember> members) {
    index.addTopLevel(name, owner);
    for (final member in members) {
      if (member is MethodDeclaration) {
        index.addMemberOwner(member.name.lexeme, owner);
        if (member.isOperator &&
            member.name.lexeme == '-' &&
            (member.parameters?.parameters.isEmpty ?? false)) {
          index.addMemberOwner('unary-', owner);
        }
      } else if (member is FieldDeclaration) {
        for (final variable in member.fields.variables) {
          index.addMemberOwner(variable.name.lexeme, owner);
        }
      } else if (member is ConstructorDeclaration) {
        index.addMemberOwner(name, owner);
      }
    }
  }
}
