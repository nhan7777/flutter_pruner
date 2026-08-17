import 'dart:io';

import 'package:flutter_pruner/src/apply/import_cleanup_runner.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('import_cleanup_test_');

    // Create minimal pubspec.yaml
    final pubspecFile = File(p.join(tempDir.path, 'pubspec.yaml'));
    pubspecFile.writeAsStringSync('''
name: test_app
version: 1.0.0
environment:
  sdk: ^3.9.0
''');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('runs dart fix successfully', () async {
    final file = File(p.join(tempDir.path, 'lib', 'main.dart'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('''
import 'dart:async';  // unused import

void main() {
  print('hello');
}
''');

    final runner = ImportCleanupRunner(projectRoot: tempDir.path);
    final result = await runner.run([file.path]);

    expect(result.success, isTrue);
  });

  test('does not fix files outside the requested paths', () async {
    final changedFile = File(p.join(tempDir.path, 'lib', 'changed.dart'));
    final unrelatedFile = File(p.join(tempDir.path, 'lib', 'unrelated.dart'));
    changedFile.parent.createSync(recursive: true);
    changedFile.writeAsStringSync("import 'dart:async';\nconst changed = 1;\n");
    const unrelatedSource = "import 'dart:async';\nconst unrelated = 1;\n";
    unrelatedFile.writeAsStringSync(unrelatedSource);

    final result = await ImportCleanupRunner(
      projectRoot: tempDir.path,
    ).run([changedFile.path]);

    expect(result.success, isTrue);
    expect(unrelatedFile.readAsStringSync(), unrelatedSource);
  });

  test('returns false on non-zero exit code', () async {
    final script = File(p.join(tempDir.path, 'nonzero.dart'));
    script.writeAsStringSync(r'''
import 'dart:io';

void main() {
  stdout.write('diagnostic output');
  stderr.write('cleanup failed');
  exitCode = 19;
}
''');

    final runner = ImportCleanupRunner(
      projectRoot: tempDir.path,
      dartExecutable: Platform.resolvedExecutable,
      dartArgumentPrefix: [script.path],
    );
    final result = await runner.run(['some_file.dart']);

    expect(result.success, isFalse);
    expect(result.exitCode, 19);
    expect(result.timedOut, isFalse);
    expect(result.stderr, contains('cleanup failed'));
    expect(result.stderr, contains('diagnostic output'));
  });

  test('timeout kills cleanup child and grandchild before returning', () async {
    final parentScript = File(p.join(tempDir.path, 'parent.dart'));
    final childScript = File(p.join(tempDir.path, 'child.dart'));
    final grandchildScript = File(p.join(tempDir.path, 'grandchild.dart'));
    final ready = File(p.join(tempDir.path, 'grandchild-ready'));
    final childSurvived = File(p.join(tempDir.path, 'child-survived'));
    final grandchildSurvived = File(
      p.join(tempDir.path, 'grandchild-survived'),
    );
    parentScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[1], arguments[2], arguments[3], arguments[4]],
  );
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
    childScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[3]],
  );
  File(arguments[1]).writeAsStringSync('ready');
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[2]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
    grandchildScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments.single).writeAsStringSync('survived');
}
''');

    final result = await ImportCleanupRunner(
      projectRoot: tempDir.path,
      timeout: const Duration(milliseconds: 1500),
      maxOutputBytesPerStream: 1024,
      dartExecutable: Platform.resolvedExecutable,
      dartArgumentPrefix: [
        parentScript.path,
        childScript.path,
        grandchildScript.path,
        ready.path,
        childSurvived.path,
        grandchildSurvived.path,
      ],
    ).run([p.join(tempDir.path, 'lib', 'main.dart')]);

    expect(result.success, isFalse);
    expect(result.timedOut, isTrue);
    expect(result.exitCode, -1);
    expect(result.stderr, contains('timed out after 1500ms'));
    expect(ready.existsSync(), isTrue);
    await Future<void>.delayed(const Duration(seconds: 3));
    expect(childSurvived.existsSync(), isFalse);
    expect(grandchildSurvived.existsSync(), isFalse);
  }, skip: !(Platform.isLinux || Platform.isMacOS || Platform.isWindows));

  test('maps unconfirmed termination to recovery-required exception', () {
    final runner = ImportCleanupRunner(
      projectRoot: tempDir.path,
      processRunner: const _UnconfirmedTerminationRunner(),
    );

    expect(
      () => runner.run(['some_file.dart']),
      throwsA(
        isA<ImportCleanupRecoveryRequiredException>()
            .having((error) => error.processId, 'processId', 4242)
            .having(
              (error) => error.message,
              'message',
              contains('Rollback is unsafe'),
            ),
      ),
    );
  });

  test('handles empty file list', () async {
    final runner = ImportCleanupRunner(projectRoot: tempDir.path);
    final result = await runner.run([]);

    expect(result.success, isTrue);
    expect(result.stderr, isEmpty);
  });

  test('removes only the import that references the target file', () async {
    final importer = File(p.join(tempDir.path, 'lib', 'main.dart'));
    final target = File(p.join(tempDir.path, 'lib', 'src', 'empty.dart'));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('');
    importer.writeAsStringSync('''
import 'dart:async';
import 'src/empty.dart';

void main() {}
''');

    final result = await ImportCleanupRunner(
      projectRoot: tempDir.path,
    ).removeDirectiveReferencing(importer.path, target.path);

    expect(result.success, isTrue);
    expect(importer.readAsStringSync(), contains("import 'dart:async';"));
    expect(importer.readAsStringSync(), isNot(contains('empty.dart')));
  });

  test('removes a package export that references the target file', () async {
    final barrel = File(p.join(tempDir.path, 'lib', 'entities.dart'));
    final target = File(p.join(tempDir.path, 'lib', 'src', 'empty.dart'));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('');
    barrel.writeAsStringSync('''
export 'package:test_app/src/empty.dart';
export 'src/live.dart';
''');

    final result = await ImportCleanupRunner(
      projectRoot: tempDir.path,
    ).removeDirectiveReferencing(barrel.path, target.path);

    expect(result.success, isTrue);
    expect(barrel.readAsStringSync(), isNot(contains('empty.dart')));
    expect(barrel.readAsStringSync(), contains("export 'src/live.dart';"));
  });

  test('refuses to remove a conditional directive', () async {
    final importer = File(p.join(tempDir.path, 'lib', 'main.dart'));
    final target = File(p.join(tempDir.path, 'lib', 'src', 'empty.dart'));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync('');
    const source = '''
import 'src/empty.dart'
    if (dart.library.io) 'src/io.dart';
''';
    importer.writeAsStringSync(source);

    final result = await ImportCleanupRunner(
      projectRoot: tempDir.path,
    ).removeDirectiveReferencing(importer.path, target.path);

    expect(result.success, isFalse);
    expect(importer.readAsStringSync(), source);
  });
}

class _UnconfirmedTerminationRunner implements ProcessExecutionRunner {
  const _UnconfirmedTerminationRunner();

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    throw const ProcessTerminationUnconfirmedException(
      processId: 4242,
      message: 'fixture could not inspect the process tree',
    );
  }
}
