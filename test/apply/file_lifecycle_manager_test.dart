import 'dart:io';
import 'package:flutter_pruner/src/apply/file_lifecycle_manager.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ProjectContext project;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('file_lifecycle_test_');

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

  test('empty file under lib/src/ should be deleted', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'utils.dart');
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(filePath, ''), isTrue);
    expect(manager.shouldDelete(filePath, '   \n\n  '), isTrue);
    expect(manager.shouldDelete(filePath, '// comment only\n'), isTrue);
  });

  test('empty imported library is preserved as a URI stub', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'model.dart');
    final manager = FileLifecycleManager(project);

    expect(
      manager.shouldDelete(filePath, '', hasExistingImporters: true),
      isFalse,
    );
  });

  test('empty file under lib/ (public API) should NOT be deleted', () {
    final filePath = p.join(tempDir.path, 'lib', 'api.dart');
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(filePath, ''), isFalse);
    expect(manager.shouldDelete(filePath, '   \n'), isFalse);
  });

  test('non-empty file should NOT be deleted', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'utils.dart');
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(filePath, 'void main() {}'), isFalse);
  });

  test('file outside lib/ should be deleted if empty', () {
    final filePath = p.join(tempDir.path, 'test', 'helper.dart');
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(filePath, ''), isTrue);
  });

  test('declaration sharing a line with a block comment is not empty', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'utils.dart');
    final manager = FileLifecycleManager(project);

    // A line-prefix scan reads this as a comment line and deletes live code.
    expect(
      manager.shouldDelete(filePath, '/* keep me */ void stillUsed() {}'),
      isFalse,
    );
    expect(
      manager.shouldDelete(filePath, '/* doc */ class Kept {} // trailing'),
      isFalse,
    );
  });

  test('block comment with unprefixed interior lines counts as empty', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'utils.dart');
    final manager = FileLifecycleManager(project);

    expect(
      manager.shouldDelete(filePath, '/*\nplain interior line\n*/\n'),
      isTrue,
    );
    expect(manager.shouldDelete(filePath, '/// doc comment only\n'), isTrue);
  });

  test('directive-only file is never empty', () {
    final manager = FileLifecycleManager(project);

    expect(
      manager.shouldDelete(
        p.join(tempDir.path, 'lib', 'src', 'part.dart'),
        "part of 'parent.dart';\n",
      ),
      isFalse,
    );
    expect(
      manager.shouldDelete(
        p.join(tempDir.path, 'lib', 'src', 'exports.dart'),
        "export 'other.dart';\n",
      ),
      isFalse,
    );
  });

  test('unparseable content is never empty', () {
    final filePath = p.join(tempDir.path, 'lib', 'src', 'broken.dart');
    final manager = FileLifecycleManager(project);

    expect(manager.shouldDelete(filePath, 'class Broken {'), isFalse);
  });

  test('project root containing lib/ does not misclassify paths', () async {
    // Absolute-path substring matching breaks when the root itself sits under a
    // directory named lib/.
    final nestedRoot = Directory(p.join(tempDir.path, 'lib', 'nested_app'))
      ..createSync(recursive: true);
    File(p.join(nestedRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: nested_app
environment:
  sdk: ^3.9.0
''');
    final nestedProject = await ProjectContext.load(nestedRoot);
    final manager = FileLifecycleManager(nestedProject);

    expect(
      manager.shouldDelete(p.join(nestedRoot.path, 'test', 'helper.dart'), ''),
      isTrue,
    );
    expect(
      manager.shouldDelete(
        p.join(nestedRoot.path, 'lib', 'src', 'utils.dart'),
        '',
      ),
      isTrue,
    );
    expect(
      manager.shouldDelete(p.join(nestedRoot.path, 'lib', 'api.dart'), ''),
      isFalse,
    );
  });

  test('path outside the project root is never deleted', () {
    final manager = FileLifecycleManager(project);
    final outside = p.join(tempDir.parent.path, 'elsewhere', 'stray.dart');

    expect(manager.shouldDelete(outside, ''), isFalse);
  });
}
