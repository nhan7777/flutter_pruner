import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('excludes another process and can be acquired after release', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter_pruner_operation_lock_',
    );
    addTearDown(() async {
      if (project.existsSync()) await project.delete(recursive: true);
    });

    final process = await Process.start(Platform.resolvedExecutable, [
      'test/fixtures/project_operation_lock_holder.dart',
      project.path,
    ], workingDirectory: Directory.current.path);
    addTearDown(() {
      if (process.kill()) return process.exitCode;
      return Future<void>.value();
    });
    final locked = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(locked, 'LOCKED');

    final workspace = ToolWorkspace(project);
    final contentionMessage = Platform.isWindows
        ? contains('Another Flutter Pruner mutation is already active')
        : allOf(contains('operation=holder'), contains('pid='));
    await expectLater(
      ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'contender',
      ),
      throwsA(
        isA<ProjectOperationLockException>().having(
          (error) => error.message,
          'message',
          contentionMessage,
        ),
      ),
    );

    process.stdin.writeln('release');
    await process.stdin.close();
    expect(await process.exitCode, 0);

    final acquired = await ProjectOperationLock.acquire(
      workspace: workspace,
      operation: 'after-release',
    );
    await acquired.release();
    await acquired.release();
  });

  test('apply, rollback, and quarantine clean honor the shared lock', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter_pruner_command_lock_',
    );
    addTearDown(() async {
      if (project.existsSync()) await project.delete(recursive: true);
    });
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: lock_test
publish_to: none
environment:
  sdk: ^3.9.0
''');
    final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('void main() {}\n');
    final config = File(p.join(project.path, ToolWorkspace.configRelativePath));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
verification:
  steps:
    - id: noop
      argv: [dart, --version]
''');

    final process = await Process.start(Platform.resolvedExecutable, [
      'test/fixtures/project_operation_lock_holder.dart',
      project.path,
    ], workingDirectory: Directory.current.path);
    addTearDown(() {
      if (process.kill()) return process.exitCode;
      return Future<void>.value();
    });
    expect(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first,
      'LOCKED',
    );

    expect(
      await FlutterPrunerCommandRunner().run([
        'apply',
        '--dry-run',
        '--project',
        project.path,
      ]),
      1,
    );
    expect(
      await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'missing-run',
      ]),
      1,
    );
    expect(
      await FlutterPrunerCommandRunner().run([
        'quarantine',
        'clean',
        '--project',
        project.path,
        'missing-run',
      ]),
      1,
    );
    expect(mainFile.readAsStringSync(), 'void main() {}\n');

    process.stdin.writeln('release');
    await process.stdin.close();
    expect(await process.exitCode, 0);
  });
}
