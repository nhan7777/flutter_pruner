import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/nullability_suffix.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_identity.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late ResolvedLibraryResult library;

  setUpAll(() async {
    final root = Directory(
      p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'get_it_identity_test',
      ),
    );
    final mainPath = p.join(root.path, 'lib', 'main.dart');
    final collection = AnalysisContextCollection(includedPaths: [root.path]);
    final result = await collection
        .contextFor(mainPath)
        .currentSession
        .getResolvedLibrary(mainPath);
    library = result as ResolvedLibraryResult;
  });

  test('canonicalizes resolved types by defining library and arguments', () {
    final fromA = diTypeKey(_variableType(library, 'fromA'));
    final fromB = diTypeKey(_variableType(library, 'fromB'));
    final users = diTypeKey(_variableType(library, 'users'));
    final orders = diTypeKey(_variableType(library, 'orders'));

    expect(fromA, isNotNull);
    expect(fromB, isNotNull);
    expect(fromA, isNot(fromB));
    expect(users, isNotNull);
    expect(orders, isNotNull);
    expect(users, isNot(orders));
  });

  test('canonicalizes nested generic nullability deterministically', () {
    final type = _variableType(library, 'nested');
    final nonNullableType = _variableType(library, 'nonNullableNested');

    expect(diTypeKey(type), diTypeKey(type));
    expect(diTypeKey(type), isNot(diTypeKey(nonNullableType)));
  });

  test('refuses dynamic, invalid, and type-parameter types', () {
    final typeParameter = library.element
        .getTopLevelFunction('typeParameter')!
        .typeParameters
        .single
        .instantiate(nullabilitySuffix: NullabilitySuffix.none);

    expect(diTypeKey(_variableType(library, 'dynamicValue')), isNull);
    expect(diTypeKey(_variableType(library, 'invalidValue')), isNull);
    expect(diTypeKey(typeParameter), isNull);
  });

  test('preserves absent, constant, and dynamic instance-name states', () {
    final expressions = _instanceNameExpressions(library);
    final absent = diInstanceName(null);
    final empty = diInstanceName(expressions[0]);
    final named = diInstanceName(expressions[1]);
    final dynamic = diInstanceName(expressions[2]);

    expect(absent, isA<DiAbsentInstanceName>());
    expect(empty, isA<DiConstantInstanceName>());
    expect((empty as DiConstantInstanceName).value, '');
    expect(named, isA<DiConstantInstanceName>());
    expect((named as DiConstantInstanceName).value, 'named:@,% <value>');
    expect(dynamic, isA<DiDynamicInstanceName>());
    expect({absent, empty, named, dynamic}, hasLength(4));
  });

  test('encodes lookup and occurrence ids without punctuation collisions', () {
    final type = diTypeKey(_variableType(library, 'users'))!;
    final firstLookup = DiLookupKey(
      type: type,
      instanceName: diInstanceName(null),
    );
    final secondLookup = DiLookupKey(
      type: type,
      instanceName: const DiConstantInstanceName(':@,% <value>'),
    );

    expect(
      firstLookup.graphId(package: 'pkg:@,% <a>'),
      isNot(secondLookup.graphId(package: 'pkg:@,% <a>')),
    );
    expect(
      DiRegistrationOccurrence(
        package: 'pkg:@,% <a>',
        lookup: firstLookup,
        scope: const DiNamedScope('scope:@,% <a>'),
        environments: {'dev:@,% <a>', 'prod'},
        source: DiSourceOccurrence(path: 'lib/a.dart', offset: 12),
      ).graphId,
      isNot(
        DiRegistrationOccurrence(
          package: 'pkg:@,% <a>',
          lookup: firstLookup,
          scope: const DiNamedScope('scope:@,% <a>'),
          environments: {'prod', 'dev:@,% <a>'},
          source: DiSourceOccurrence(path: 'lib/a.dart', offset: 13),
        ).graphId,
      ),
    );
  });

  test('normalizes environments but keeps scope and occurrence distinct', () {
    final lookup = DiLookupKey(
      type: diTypeKey(_variableType(library, 'users'))!,
      instanceName: diInstanceName(null),
    );
    final first = DiRegistrationOccurrence(
      package: 'fixture',
      lookup: lookup,
      source: DiSourceOccurrence(path: 'lib/main.dart', offset: 1),
    );
    final sameEnvironmentsDifferentOrder = DiRegistrationOccurrence(
      package: 'fixture',
      lookup: lookup,
      environments: {'prod', 'dev'},
      source: DiSourceOccurrence(path: 'lib/main.dart', offset: 1),
    );
    final reorderedEnvironments = DiRegistrationOccurrence(
      package: 'fixture',
      lookup: lookup,
      environments: {'dev', 'prod'},
      source: DiSourceOccurrence(path: 'lib/main.dart', offset: 1),
    );
    final differentScope = DiRegistrationOccurrence(
      package: 'fixture',
      lookup: lookup,
      scope: const DiNamedScope('feature'),
      environments: {'dev', 'prod'},
      source: DiSourceOccurrence(path: 'lib/main.dart', offset: 1),
    );
    final differentOccurrence = DiRegistrationOccurrence(
      package: 'fixture',
      lookup: lookup,
      environments: {'dev', 'prod'},
      source: DiSourceOccurrence(path: 'lib/main.dart', offset: 2),
    );

    expect(first.graphId, isNot(sameEnvironmentsDifferentOrder.graphId));
    expect(
      sameEnvironmentsDifferentOrder.graphId,
      reorderedEnvironments.graphId,
    );
    expect(reorderedEnvironments.graphId, isNot(differentScope.graphId));
    expect(reorderedEnvironments.graphId, isNot(differentOccurrence.graphId));
  });

  test(
    'rejects dynamic names as exact lookups but preserves blocked identity',
    () {
      final type = diTypeKey(_variableType(library, 'users'))!;

      expect(
        () => DiLookupKey(
          type: type,
          instanceName: const DiDynamicInstanceName(),
        ),
        throwsArgumentError,
      );

      final first = DiRegistrationOccurrence.withDynamicInstanceName(
        package: 'fixture',
        type: type,
        source: DiSourceOccurrence(path: 'lib/main.dart', offset: 1),
      );
      final second = DiRegistrationOccurrence.withDynamicInstanceName(
        package: 'fixture',
        type: type,
        source: DiSourceOccurrence(path: 'lib/main.dart', offset: 2),
      );

      expect(first.lookup, isNull);
      expect(first.graphId, isNot(second.graphId));
    },
  );

  test('keeps base, named, and dynamic scopes distinct', () {
    final lookup = DiLookupKey(
      type: diTypeKey(_variableType(library, 'users'))!,
      instanceName: diInstanceName(null),
    );
    final source = DiSourceOccurrence(path: 'lib/main.dart', offset: 1);
    const base = DiBaseScope();
    const namedBase = DiNamedScope('base');
    const dynamic = DiDynamicScope();

    expect(base, isNot(namedBase));
    expect(base, isNot(dynamic));
    expect(namedBase, isNot(dynamic));
    expect(
      DiRegistrationOccurrence(
        package: 'fixture',
        lookup: lookup,
        source: source,
        scope: base,
      ).graphId,
      isNot(
        DiRegistrationOccurrence(
          package: 'fixture',
          lookup: lookup,
          source: source,
          scope: namedBase,
        ).graphId,
      ),
    );
  });

  test('normalizes stable project-relative source occurrences', () {
    final windows = DiSourceOccurrence(
      path: r'lib\feature\service.dart',
      offset: 7,
    );
    final posix = DiSourceOccurrence(
      path: 'lib/feature/service.dart',
      offset: 7,
    );

    expect(windows, posix);
    expect(windows.path, 'lib/feature/service.dart');
    expect(
      () => DiSourceOccurrence(path: '/tmp/service.dart', offset: 0),
      throwsArgumentError,
    );
    expect(
      () => DiSourceOccurrence(path: r'C:\tmp\service.dart', offset: 0),
      throwsArgumentError,
    );
    expect(
      () => DiSourceOccurrence(path: '../service.dart', offset: 0),
      throwsArgumentError,
    );
    expect(
      () => DiSourceOccurrence(path: 'lib/../service.dart', offset: 0),
      throwsArgumentError,
    );
    expect(
      () => DiSourceOccurrence(path: 'lib/service.dart', offset: -1),
      throwsArgumentError,
    );
  });
}

DartType _variableType(ResolvedLibraryResult library, String name) =>
    library.element.getTopLevelVariable(name)!.type;

List<Expression> _instanceNameExpressions(ResolvedLibraryResult library) {
  final visitor = _InstanceNameVisitor();
  for (final unit in library.units) {
    unit.unit.accept(visitor);
  }
  return visitor.expressions;
}

class _InstanceNameVisitor extends RecursiveAstVisitor<void> {
  final expressions = <Expression>[];

  @override
  void visitNamedExpression(NamedExpression node) {
    if (node.name.label.name == 'instanceName') {
      expressions.add(node.expression);
    }
    super.visitNamedExpression(node);
  }
}
