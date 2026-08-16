import 'dart:io';
import 'package:flutter_pruner/src/apply/declaration_remover.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ProjectContext project;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('declaration_remover_test_');

    // Create minimal pubspec.yaml
    final pubspecFile = File(p.join(tempDir.path, 'pubspec.yaml'));
    pubspecFile.writeAsStringSync('''
name: test_app
version: 1.0.0
environment:
  sdk: ^3.9.0
''');

    project = await ProjectContext.load(tempDir);
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test(
    'removes single function from file with multiple declarations',
    () async {
      final file = File(p.join(tempDir.path, 'lib', 'utils.dart'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('''
void usedFunction() {
  print('used');
}

void unusedFunction() {
  print('unused');
}

void anotherUsedFunction() {
  print('also used');
}
''');

      final remover = DeclarationRemover(project);
      final declId = 'dart:test_app/lib/utils.dart#unusedFunction';

      final result = await remover.removeDeclarations(file.path, [declId]);

      expect(result, contains('usedFunction'));
      expect(result, contains('anotherUsedFunction'));
      expect(result, isNot(contains('unusedFunction')));
      expect(result, contains("print('used')"));
      expect(result, contains("print('also used')"));
    },
  );

  test('removes class declaration', () async {
    final file = File(p.join(tempDir.path, 'lib', 'models.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
class UsedModel {
  final String name;
  UsedModel(this.name);
}

class UnusedModel {
  final int id;
  UnusedModel(this.id);
}
''');

    final remover = DeclarationRemover(project);
    final declId = 'dart:test_app/lib/models.dart#UnusedModel';

    final result = await remover.removeDeclarations(file.path, [declId]);

    expect(result, contains('UsedModel'));
    expect(result, isNot(contains('UnusedModel')));
  });

  test('removes multiple declarations from same file', () async {
    final file = File(p.join(tempDir.path, 'lib', 'helpers.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
void helper1() {}

void unused1() {}

void helper2() {}

void unused2() {}

void helper3() {}
''');

    final remover = DeclarationRemover(project);
    final declIds = [
      'dart:test_app/lib/helpers.dart#unused1',
      'dart:test_app/lib/helpers.dart#unused2',
    ];

    final result = await remover.removeDeclarations(file.path, declIds);

    expect(result, contains('helper1'));
    expect(result, contains('helper2'));
    expect(result, contains('helper3'));
    expect(result, isNot(contains('unused1')));
    expect(result, isNot(contains('unused2')));
  });

  test('preserves formatting and comments', () async {
    final file = File(p.join(tempDir.path, 'lib', 'documented.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
// This is the used function
void usedFunction() {
  print('used');
}

// This is unused
void unusedFunction() {
  print('unused');
}

/// Documentation for another function
/// Multiple lines
void anotherFunction() {
  // Internal comment
  print('another');
}
''');

    final remover = DeclarationRemover(project);
    final declId = 'dart:test_app/lib/documented.dart#unusedFunction';

    final result = await remover.removeDeclarations(file.path, [declId]);

    expect(result, contains('// This is the used function'));
    expect(result, contains('/// Documentation for another function'));
    expect(result, contains('// Internal comment'));
    expect(result, isNot(contains('This is unused')));
  });

  test('preserves file header when removing the first declaration', () async {
    final file = File(p.join(tempDir.path, 'lib', 'header.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
// ignore_for_file: sort_constructors_first
// Copyright 2026 Example

class Removed {
  final int value = 0;
  const Removed();
}

class Kept {
  final int value = 0;
  const Kept();
}
''');

    final result = await DeclarationRemover(
      project,
    ).removeDeclarations(file.path, ['dart:test_app/lib/header.dart#Removed']);

    expect(result, startsWith('// ignore_for_file: sort_constructors_first'));
    expect(result, contains('// Copyright 2026 Example'));
    expect(result, isNot(contains('class Removed')));
    expect(result, contains('class Kept'));
  });

  test('fails when the requested declaration is not present', () async {
    final file = File(p.join(tempDir.path, 'lib', 'missing.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('void existing() {}\n');

    final remover = DeclarationRemover(project);

    await expectLater(
      remover.removeDeclarations(file.path, [
        'dart:test_app/lib/missing.dart#notThere',
      ]),
      throwsA(isA<DeclarationRemovalException>()),
    );
    expect(file.readAsStringSync(), 'void existing() {}\n');
  });

  test(
    'normalizes declaration output to exactly one trailing newline',
    () async {
      final file = File(p.join(tempDir.path, 'lib', 'trailing.dart'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('void kept() {}\n\nvoid removed() {}\n\n');

      final result = await DeclarationRemover(project).removeDeclarations(
        file.path,
        ['dart:test_app/lib/trailing.dart#removed'],
      );

      expect(result, 'void kept() {}\n');
    },
  );

  test(
    'fails closed for one variable in a multi-variable declaration',
    () async {
      final file = File(p.join(tempDir.path, 'lib', 'variables.dart'));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('const unused = 1, live = 2;\n');

      final remover = DeclarationRemover(project);

      await expectLater(
        remover.removeDeclarations(file.path, [
          'dart:test_app/lib/variables.dart#unused',
        ]),
        throwsA(isA<DeclarationRemovalException>()),
      );
    },
  );
}
