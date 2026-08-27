import 'dart:async';
import 'dart:convert';
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

  test(
    'signal cancellation stops cleanup root and descendant before unwinding',
    () async {
      final fixture = _startImportSignalFixture(tempDir);
      try {
        final processTree = await _waitForSignalTreeOrEarlyExit(
          ready: fixture.ready,
          childPidFile: fixture.childPid,
          cleanup: fixture.cleanup,
          timeout: const Duration(seconds: 45),
        );

        fixture.cancellation.requestCancellation(ProcessSignal.sigint);

        await expectLater(
          fixture.cleanup,
          throwsA(
            isA<ProcessCancellationConfirmedException>()
                .having(
                  (error) => error.originalSignal,
                  'originalSignal',
                  ProcessSignal.sigint,
                )
                .having(
                  (error) => error.rootPid,
                  'rootPid',
                  processTree.rootPid,
                ),
          ),
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(fixture.rootSurvived.existsSync(), isFalse);
        expect(fixture.childSurvived.existsSync(), isFalse);
      } finally {
        await _settleImportSignalFixture(fixture);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'readiness failure cancels and settles cleanup root and descendant',
    () async {
      final fixture = _startImportSignalFixture(tempDir);
      ({int rootPid, int childPid})? observedTree;
      try {
        await expectLater(
          _waitForSignalTreeOrEarlyExit(
            ready: fixture.ready,
            childPidFile: fixture.childPid,
            cleanup: fixture.cleanup,
            timeout: const Duration(seconds: 45),
            readBarrier: (processTree) {
              observedTree = processTree;
              throw StateError('forced readiness failure');
            },
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'forced readiness failure',
            ),
          ),
        );
      } finally {
        await _settleImportSignalFixture(fixture);
      }

      expect(observedTree, isNotNull);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(fixture.rootSurvived.existsSync(), isFalse);
      expect(fixture.childSurvived.existsSync(), isFalse);
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

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

_ImportSignalFixture _startImportSignalFixture(Directory tempDir) {
  final childScript = File(p.join(tempDir.path, 'signal_child.dart'));
  final rootScript = File(p.join(tempDir.path, 'signal_root.dart'));
  final childPid = File(p.join(tempDir.path, 'signal_child.pid'));
  final ready = File(p.join(tempDir.path, 'signal_ready'));
  final childSurvived = File(p.join(tempDir.path, 'child_survived'));
  final rootSurvived = File(p.join(tempDir.path, 'root_survived'));
  childScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid');
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[1]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
  rootScript.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[1], arguments[2]],
  );
  final childPidFile = File(arguments[1]);
  int? childPid;
  while (childPid == null) {
    if (childPidFile.existsSync()) {
      childPid = int.tryParse(childPidFile.readAsStringSync().trim());
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(arguments[3]).writeAsStringSync(jsonEncode({
    'rootPid': pid,
    'childPid': childPid,
  }));
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[4]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
  final cancellation = ManagedProcessCancellationController();
  final cleanup = ImportCleanupRunner(
    projectRoot: tempDir.path,
    dartExecutable: Platform.resolvedExecutable,
    dartArgumentPrefix: [
      rootScript.path,
      childScript.path,
      childPid.path,
      childSurvived.path,
      ready.path,
      rootSurvived.path,
    ],
    processRunner: ManagedProcessRunner(cancellationController: cancellation),
  ).run([p.join(tempDir.path, 'lib', 'main.dart')]);
  return _ImportSignalFixture(
    cancellation: cancellation,
    cleanup: cleanup,
    ready: ready,
    childPid: childPid,
    rootSurvived: rootSurvived,
    childSurvived: childSurvived,
  );
}

Future<void> _settleImportSignalFixture(_ImportSignalFixture fixture) async {
  if (!fixture.cancellation.isRequested) {
    fixture.cancellation.requestCancellation(ProcessSignal.sigterm);
  }
  try {
    await fixture.cleanup;
  } on ProcessCancellationBeforeLaunchException {
    // Expected if fixture setup fails before Process.start completes.
  } on ProcessCancellationConfirmedException {
    // Expected after either the asserted SIGINT or cleanup SIGTERM.
  }
}

typedef _SignalTreeReadBarrier =
    void Function(({int rootPid, int childPid}) processTree);

Future<({int rootPid, int childPid})> _waitForSignalTreeOrEarlyExit({
  required File ready,
  required File childPidFile,
  required Future<CleanupResult> cleanup,
  required Duration timeout,
  _SignalTreeReadBarrier? readBarrier,
}) {
  return Future.any<({int rootPid, int childPid})>([
    _readSignalTreeEvidence(
      ready: ready,
      childPidFile: childPidFile,
      timeout: timeout,
      readBarrier: readBarrier,
    ),
    cleanup.then<({int rootPid, int childPid})>(
      (result) {
        throw StateError(
          'Import cleanup exited before the managed process tree was ready: '
          'success=${result.success}, exitCode=${result.exitCode}, '
          'stderr=${result.stderr}',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        Error.throwWithStackTrace(
          StateError(
            'Import cleanup failed before the managed process tree was ready: '
            '$error',
          ),
          stackTrace,
        );
      },
    ),
  ]);
}

Future<({int rootPid, int childPid})> _readSignalTreeEvidence({
  required File ready,
  required File childPidFile,
  required Duration timeout,
  _SignalTreeReadBarrier? readBarrier,
}) async {
  final deadline = DateTime.now().add(timeout);
  Object? lastParseFailure;

  while (DateTime.now().isBefore(deadline)) {
    if (ready.existsSync() && childPidFile.existsSync()) {
      ({int rootPid, int childPid})? processTree;
      try {
        final decoded = jsonDecode(ready.readAsStringSync());
        final childPid = int.parse(childPidFile.readAsStringSync().trim());
        if (decoded is Map &&
            decoded['rootPid'] is int &&
            decoded['childPid'] == childPid) {
          processTree = (
            rootPid: decoded['rootPid'] as int,
            childPid: childPid,
          );
        } else {
          lastParseFailure = StateError(
            'ready evidence did not match descendant PID: $decoded, '
            'childPid=$childPid',
          );
        }
      } on Object catch (error) {
        lastParseFailure = error;
      }
      if (processTree != null) {
        readBarrier?.call(processTree);
        return processTree;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }

  throw TimeoutException(
    'Fixture did not publish parseable managed process-tree evidence within '
    '${timeout.inSeconds}s. ready=${_describeFixtureFile(ready)}, '
    'childPid=${_describeFixtureFile(childPidFile)}, '
    'lastParseFailure=$lastParseFailure',
  );
}

final class _ImportSignalFixture {
  const _ImportSignalFixture({
    required this.cancellation,
    required this.cleanup,
    required this.ready,
    required this.childPid,
    required this.rootSurvived,
    required this.childSurvived,
  });

  final ManagedProcessCancellationController cancellation;
  final Future<CleanupResult> cleanup;
  final File ready;
  final File childPid;
  final File rootSurvived;
  final File childSurvived;
}

String _describeFixtureFile(File file) {
  if (!file.existsSync()) return '${file.path} (missing)';
  try {
    return '${file.path} (${file.readAsStringSync()})';
  } on FileSystemException catch (error) {
    return '${file.path} (unreadable: $error)';
  }
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
