import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/reporting/native/posix_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  if (!Platform.isLinux && !Platform.isMacOS) {
    test('POSIX backend is unavailable outside Linux and macOS', () {
      expect(
        () => PosixReportObjectBackend(),
        throwsA(isA<ReportObjectBackendException>()),
      );
    });
    return;
  }

  late Directory sandbox;
  late Directory reportDirectory;
  late PosixReportObjectBackend backend;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('report_object_posix_');
    reportDirectory = Directory(p.join(sandbox.path, 'reports'))..createSync();
    backend = PosixReportObjectBackend();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'creates, writes, flushes, and rereads one retained regular FD',
    () async {
      final directory = await backend.anchor(reportDirectory);
      final object = await directory.createExclusive('report.json');
      addTearDown(object.close);
      addTearDown(directory.close);
      final bytes = utf8.encode('{"safe":true}\n');

      await object.write(bytes.sublist(0, 4));
      await object.write(bytes.sublist(4));
      await object.flush();
      final writtenIdentity = await object.identity();
      await object.rewind();

      expect(await object.read(3), bytes.sublist(0, 3));
      expect(await object.read(1024), bytes.sublist(3));
      expect(await object.read(1024), isEmpty);
      expect(writtenIdentity.byteLength, bytes.length);
      expect(
        FileStat.statSync(p.join(reportDirectory.path, 'report.json')).type,
        FileSystemEntityType.file,
      );
      expect(
        FileStat.statSync(p.join(reportDirectory.path, 'report.json')).mode &
            0x1ff,
        0x180,
      );
    },
  );

  test(
    'existing regular and empty collisions retain exact foreign state',
    () async {
      for (final entry in <({String leaf, List<int> bytes, int mode})>[
        (leaf: 'nonempty.json', bytes: const [9, 8, 7], mode: 0x180),
        (leaf: 'empty.json', bytes: const [], mode: 0x100),
      ]) {
        final path = p.join(reportDirectory.path, entry.leaf);
        final foreign = File(path)..writeAsBytesSync(entry.bytes);
        await Process.run('chmod', [entry.mode.toRadixString(8), path]);
        final before = foreign.statSync();
        final directory = await backend.anchor(reportDirectory);

        await expectLater(
          directory.createExclusive(entry.leaf),
          throwsA(
            isA<ReportObjectBackendException>().having(
              (error) => error.category,
              'category',
              ReportObjectBackendFailure.collision,
            ),
          ),
        );

        final after = foreign.statSync();
        expect(foreign.readAsBytesSync(), entry.bytes);
        expect(after.mode, before.mode);
        expect(after.type, before.type);
        await directory.close();
      }
    },
  );

  test('final symlink collision is never followed or modified', () async {
    final foreign = File(p.join(sandbox.path, 'foreign.json'))
      ..writeAsBytesSync(const [4, 5, 6]);
    final link = Link(p.join(reportDirectory.path, 'report.json'))
      ..createSync(foreign.path);
    final directory = await backend.anchor(reportDirectory);

    await expectLater(
      directory.createExclusive('report.json'),
      throwsA(
        isA<ReportObjectBackendException>().having(
          (error) => error.category,
          'category',
          ReportObjectBackendFailure.collision,
        ),
      ),
    );

    expect(link.targetSync(), foreign.path);
    expect(foreign.readAsBytesSync(), const [4, 5, 6]);
    await directory.close();
  });

  test(
    'retained directory FD cannot be redirected by parent replacement',
    () async {
      final directory = await backend.anchor(reportDirectory);
      final moved = Directory(p.join(sandbox.path, 'original-reports'));
      reportDirectory.renameSync(moved.path);
      final attacker = Directory(reportDirectory.path)..createSync();
      final foreign = File(p.join(attacker.path, 'foreign.txt'))
        ..writeAsStringSync('foreign');

      final object = await directory.createExclusive('report.json');
      await object.write(const [1, 2, 3]);
      await object.flush();

      final movedObject = File(p.join(moved.path, 'report.json'));
      expect(movedObject.existsSync(), isTrue);
      expect(movedObject.statSync().mode & 0x1ff, 0x180);
      await object.rewind();
      expect(await object.read(32), [1, 2, 3]);
      expect(File(p.join(attacker.path, 'report.json')).existsSync(), isFalse);
      expect(foreign.readAsStringSync(), 'foreign');
      await expectLater(
        directory.verifyReachable(),
        throwsA(
          isA<ReportObjectBackendException>().having(
            (error) => error.category,
            'category',
            ReportObjectBackendFailure.unreachableDirectory,
          ),
        ),
      );

      await object.close();
      await directory.close();
    },
  );

  test('object read-back never reopens a replaced pathname', () async {
    final directory = await backend.anchor(reportDirectory);
    final object = await directory.createExclusive('report.json');
    await object.write(const [1, 3, 5, 7]);
    await object.flush();
    final retainedIdentity = await object.identity();
    final originalPath = p.join(reportDirectory.path, 'report.json');
    final displacedPath = p.join(reportDirectory.path, 'displaced.json');
    File(originalPath).renameSync(displacedPath);
    File(originalPath).writeAsBytesSync(const [2, 4, 6]);

    await object.rewind();
    expect(await object.read(32), const [1, 3, 5, 7]);
    expect(await object.identity(), retainedIdentity);
    expect(File(originalPath).readAsBytesSync(), const [2, 4, 6]);

    final foreign = await directory.openExisting('report.json');
    expect(await foreign.identity(), isNot(retainedIdentity));
    await foreign.close();
    await object.close();
    await directory.close();
  });

  test('openExisting rejects final links and non-regular objects', () async {
    final directory = await backend.anchor(reportDirectory);
    Directory(p.join(reportDirectory.path, 'nested')).createSync();
    Link(p.join(reportDirectory.path, 'link')).createSync('nested');

    for (final leaf in ['nested', 'link']) {
      await expectLater(
        directory.openExisting(leaf),
        throwsA(
          isA<ReportObjectBackendException>().having(
            (error) => error.category,
            'category',
            ReportObjectBackendFailure.invalidObject,
          ),
        ),
      );
    }
    await directory.close();
  });

  test('openExisting reports a stable not-found category', () async {
    final directory = await backend.anchor(reportDirectory);

    await expectLater(
      directory.openExisting('missing.json'),
      throwsA(
        isA<ReportObjectBackendException>().having(
          (error) => error.category,
          'category',
          ReportObjectBackendFailure.notFound,
        ),
      ),
    );
    await directory.close();
  });

  test(
    'closed capabilities fail without touching a later path occupant',
    () async {
      final directory = await backend.anchor(reportDirectory);
      await directory.close();
      final sentinel = File(p.join(reportDirectory.path, 'sentinel'))
        ..writeAsStringSync('sentinel');

      await expectLater(
        directory.createExclusive('report.json'),
        throwsA(isA<ReportObjectBackendException>()),
      );
      expect(sentinel.readAsStringSync(), 'sentinel');
      expect(
        File(p.join(reportDirectory.path, 'report.json')).existsSync(),
        isFalse,
      );
    },
  );

  test('native binding source contains no path mutation symbol lookup', () {
    final source = File(
      p.join(
        Directory.current.path,
        'lib',
        'src',
        'reporting',
        'native',
        'posix_bindings.dart',
      ),
    ).readAsStringSync();

    expect(
      source,
      isNot(
        matches(RegExp(r'''['"](?:unlink|unlinkat|rename|renameat)['"]''')),
      ),
    );
  });

  test(
    'child process keeps anchored parent across hostile path swap',
    () async {
      final ready = File(p.join(sandbox.path, 'ready'));
      final release = File(p.join(sandbox.path, 'release'));
      final process = await _startRaceChild(
        'parent-swap',
        reportDirectory,
        ready,
        release,
      );
      await _waitForBarrier(ready, process);
      final moved = Directory(p.join(sandbox.path, 'moved-reports'));
      reportDirectory.renameSync(moved.path);
      final attacker = Directory(reportDirectory.path)..createSync();
      final foreign = File(p.join(attacker.path, 'foreign'))
        ..writeAsBytesSync(const [8, 8, 8]);
      release.writeAsStringSync('continue', flush: true);

      final result = await _collectRaceChild(process);

      expect(result.exitCode, 0, reason: result.stderrText);
      expect(result.payload['bytes'], [1, 2, 3]);
      expect(
        result.payload['reachabilityFailure'],
        ReportObjectBackendFailure.unreachableDirectory.name,
      );
      expect(File(p.join(moved.path, 'report.json')).readAsBytesSync(), [
        1,
        2,
        3,
      ]);
      expect(File(p.join(attacker.path, 'report.json')).existsSync(), isFalse);
      expect(foreign.readAsBytesSync(), const [8, 8, 8]);
    },
  );

  test('child process read-back keeps created FD across object swap', () async {
    final ready = File(p.join(sandbox.path, 'ready'));
    final release = File(p.join(sandbox.path, 'release'));
    final process = await _startRaceChild(
      'object-swap',
      reportDirectory,
      ready,
      release,
    );
    await _waitForBarrier(ready, process);
    final objectPath = p.join(reportDirectory.path, 'report.json');
    File(objectPath).renameSync(p.join(reportDirectory.path, 'displaced.json'));
    final foreign = File(objectPath)..writeAsBytesSync(const [2, 4, 6]);
    release.writeAsStringSync('continue', flush: true);

    final result = await _collectRaceChild(process);

    expect(result.exitCode, 0, reason: result.stderrText);
    expect(result.payload['bytes'], [1, 3, 5, 7]);
    expect(result.payload['sameIdentity'], isTrue);
    expect(foreign.readAsBytesSync(), const [2, 4, 6]);
  });
}

Future<Process> _startRaceChild(
  String mode,
  Directory reportDirectory,
  File ready,
  File release,
) => Process.start(Platform.resolvedExecutable, [
  'run',
  p.join('test', 'reporting', 'posix_report_object_race_child.dart'),
  mode,
  reportDirectory.path,
  ready.path,
  release.path,
]);

Future<void> _waitForBarrier(File ready, Process process) async {
  final timeout = Stopwatch()..start();
  while (!ready.existsSync()) {
    if (timeout.elapsed >= const Duration(seconds: 30)) {
      process.kill();
      throw TimeoutException('Timed out waiting for child process barrier.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<_RaceChildResult> _collectRaceChild(Process process) async {
  final stdoutFuture = utf8.decodeStream(process.stdout);
  final stderrFuture = utf8.decodeStream(process.stderr);
  final exitCode = await process.exitCode;
  final stdoutText = await stdoutFuture;
  final stderrText = await stderrFuture;
  final decoded = stdoutText.isEmpty
      ? <String, Object?>{}
      : jsonDecode(stdoutText) as Map<String, Object?>;
  return _RaceChildResult(exitCode, decoded, stderrText);
}

final class _RaceChildResult {
  const _RaceChildResult(this.exitCode, this.payload, this.stderrText);

  final int exitCode;
  final Map<String, Object?> payload;
  final String stderrText;
}
