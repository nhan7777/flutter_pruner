import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_ids.dart';
import 'package:flutter_pruner/src/core/project/project_source_path.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('project_source_path_test_');
    File(p.join(root.path, 'lib', 'main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('normalizes an absolute source that remains inside the project', () {
    expect(
      ProjectSourcePath.validate(
        root,
        p.join(root.path, 'lib', 'main.dart'),
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
        allowAbsoluteInput: true,
      ),
      'lib/main.dart',
    );
  });

  test('rejects paths outside the selected project', () {
    final outside = File('${root.path}_outside.dart')
      ..writeAsStringSync('void main() {}\n');
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync();
    });

    expect(
      () => ProjectSourcePath.validate(
        root,
        outside.path,
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
        allowAbsoluteInput: true,
      ),
      throwsA(
        isA<ProjectSourcePathException>().having(
          (error) => error.message,
          'message',
          contains('escapes the project'),
        ),
      ),
    );
  });

  test('rejects a symlink source even when it points inside the project', () {
    final link = Link(p.join(root.path, 'lib', 'linked_main.dart'));
    link.createSync(p.join(root.path, 'lib', 'main.dart'));

    expect(
      () => ProjectSourcePath.validate(
        root,
        'lib/linked_main.dart',
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
      ),
      throwsA(
        isA<ProjectSourcePathException>().having(
          (error) => error.message,
          'message',
          contains('contains a symlink'),
        ),
      ),
    );
  });

  test('default validation rejects proven generated Dart output', () {
    for (final path in const [
      'lib/model.g.dart',
      'lib/model.freezed.dart',
      'lib/model.gen.dart',
      'lib/model.mocks.dart',
      'lib/routes.gr.dart',
      'lib/generated/model.g.dart',
      'lib/gen/model.freezed.dart',
      'build/main.dart',
      '.dart_tool/main.dart',
    ]) {
      final file = File(p.join(root.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');

      expect(DartIds.isGeneratedPath(file.path), isTrue, reason: path);
      expect(
        () => ProjectSourcePath.validate(
          root,
          path,
          field: 'entrypoint',
          kind: ProjectSourceKind.applicationEntrypoint,
        ),
        throwsA(
          isA<ProjectSourcePathException>().having(
            (error) => error.message,
            'message',
            contains('generated Dart output'),
          ),
        ),
        reason: path,
      );
    }
  });

  test('default validation accepts generated-like non-generated paths', () {
    for (final path in const [
      'lib/manual.dart',
      'lib/widget_g.dart',
      'lib/gr.dart',
      'builder/main.dart',
      'lib/generated_value.dart',
      'generated/main.dart',
      'gen/main.dart',
    ]) {
      final file = File(p.join(root.path, path))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');

      expect(DartIds.isGeneratedPath(file.path), isFalse, reason: path);
      expect(
        ProjectSourcePath.validate(
          root,
          path,
          field: 'entrypoint',
          kind: ProjectSourceKind.applicationEntrypoint,
        ),
        path,
        reason: path,
      );
    }
  });

  test('checks the semantic role and syntax of Dart sources', () {
    File(
      p.join(root.path, 'lib', 'not_main.dart'),
    ).writeAsStringSync('void helper() {}\n');
    File(p.join(root.path, 'lib', 'broken.dart')).writeAsStringSync('void {\n');

    expect(
      () => ProjectSourcePath.validate(
        root,
        'lib/not_main.dart',
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
      ),
      throwsA(
        isA<ProjectSourcePathException>().having(
          (error) => error.message,
          'message',
          contains('top-level main()'),
        ),
      ),
    );
    expect(
      () => ProjectSourcePath.validate(
        root,
        'lib/broken.dart',
        field: 'entrypoint',
        kind: ProjectSourceKind.dartFile,
      ),
      throwsA(
        isA<ProjectSourcePathException>().having(
          (error) => error.message,
          'message',
          contains('not valid Dart syntax'),
        ),
      ),
    );
  });

  test('accepts an entrypoint that declares a final parameter', () {
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: final_parameter_fixture
environment:
  sdk: ^3.12.0
''');
    File(p.join(root.path, 'lib', 'main.dart')).writeAsStringSync('''
void main() => run(name: 'world');

void run({required final String name}) => print(name);
''');

    expect(
      ProjectSourcePath.validate(
        root,
        'lib/main.dart',
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
      ),
      'lib/main.dart',
    );
  });

  test('rejects syntax newer than the declared project language version', () {
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: legacy_fixture
environment:
  sdk: ^2.19.0
''');
    File(p.join(root.path, 'lib', 'main.dart')).writeAsStringSync('''
void main() {
  final (first, second) = (1, 2);
  print(first + second);
}
''');

    expect(
      () => ProjectSourcePath.validate(
        root,
        'lib/main.dart',
        field: 'entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
      ),
      throwsA(
        isA<ProjectSourcePathException>().having(
          (error) => error.message,
          'message',
          contains('not valid Dart syntax'),
        ),
      ),
    );
  });
}
