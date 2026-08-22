import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pruner/src/reporting/native/windows_bindings.dart';
import 'package:flutter_pruner/src/reporting/native/windows_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('Windows bindings expose required capability symbols but no mutators', () {
    final source = File(
      p.join(
        Directory.current.path,
        'lib',
        'src',
        'reporting',
        'native',
        'windows_bindings.dart',
      ),
    ).readAsStringSync();

    for (final symbol in const [
      'CreateFileW',
      'NtCreateFile',
      'WriteFile',
      'ReadFile',
      'FlushFileBuffers',
      'SetFilePointerEx',
      'GetFileInformationByHandleEx',
      'GetVolumeInformationByHandleW',
      'CloseHandle',
    ]) {
      expect(source, contains("'$symbol'"), reason: symbol);
    }
    expect(
      source,
      isNot(
        matches(
          RegExp(
            r'''['"](?:DeleteFileW|MoveFileW|MoveFileExW|ReplaceFileW|RemoveDirectoryW)['"]''',
          ),
        ),
      ),
    );
  });

  test(
    'walks every directory suffix relative to its retained parent',
    () async {
      final bindings = _RecordingWindowsReportBindings();
      final backend = WindowsReportObjectBackend(
        bindings: bindings,
        canonicalPathResolver: (_) => r'C:\workspace\reports',
      );

      final directory = await backend.anchor(Directory('ignored'));

      expect(bindings.absoluteDirectoryOpens, [r'C:\']);
      expect(bindings.relativeDirectoryOpens, <(int, String)>[
        (1, 'workspace'),
        (2, 'reports'),
      ]);
      await directory.close();
    },
  );

  test('maps an existing directory leaf to a collision', () async {
    final bindings = _RecordingWindowsReportBindings(
      openRelativeFailure: const WindowsNativeFailure(
        'create-exclusive',
        0xc00000ba,
        ntStatus: true,
      ),
    );
    final backend = WindowsReportObjectBackend(
      bindings: bindings,
      canonicalPathResolver: (_) => r'C:\workspace\reports',
    );
    final directory = await backend.anchor(Directory('ignored'));

    await expectLater(
      directory.createExclusive('existing-directory'),
      throwsA(
        isA<ReportObjectBackendException>().having(
          (error) => error.category,
          'category',
          ReportObjectBackendFailure.collision,
        ),
      ),
    );
    await directory.close();
  });

  if (!Platform.isWindows) {
    test('Windows backend fails closed outside Windows', () {
      expect(
        WindowsReportObjectBackend.new,
        throwsA(
          isA<ReportObjectBackendException>().having(
            (error) => error.category,
            'category',
            ReportObjectBackendFailure.unsupportedPlatform,
          ),
        ),
      );
    });
    return;
  }

  late Directory sandbox;
  late Directory reportDirectory;
  late WindowsReportObjectBackend backend;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('report_object_windows_');
    reportDirectory = Directory(p.join(sandbox.path, 'reports'))..createSync();
    backend = WindowsReportObjectBackend();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'creates and rereads bytes through one retained Windows handle',
    () async {
      final directory = await backend.anchor(reportDirectory);
      final object = await directory.createExclusive('report.json');
      final bytes = utf8.encode('{"windows":true}\n');

      await object.write(bytes);
      await object.flush();
      final before = await object.identity();
      await object.rewind();

      expect(await object.read(1024), bytes);
      expect(await object.identity(), before);
      expect(before.byteLength, bytes.length);
      await object.close();
      await directory.close();
    },
  );

  test('foreign regular and empty collisions remain byte exact', () async {
    for (final entry in <({String leaf, List<int> bytes})>[
      (leaf: 'foreign.json', bytes: const [9, 7, 5]),
      (leaf: 'empty.json', bytes: const []),
    ]) {
      final foreign = File(p.join(reportDirectory.path, entry.leaf))
        ..writeAsBytesSync(entry.bytes);
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

      expect(foreign.readAsBytesSync(), entry.bytes);
      expect(foreign.statSync().type, before.type);
      await directory.close();
    }
  });

  test('missing existing object reports a stable not-found category', () async {
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
    'retained parent stays object-bound across hostile directory rename',
    () async {
      final directory = await backend.anchor(reportDirectory);
      final moved = p.join(sandbox.path, 'moved');

      reportDirectory.renameSync(moved);
      Directory(reportDirectory.path).createSync();
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
      final object = await directory.createExclusive('anchored.json');
      await object.write(const [8, 6, 7]);
      await object.flush();
      expect(File(p.join(moved, 'anchored.json')).readAsBytesSync(), const [
        8,
        6,
        7,
      ]);
      expect(
        File(p.join(reportDirectory.path, 'anchored.json')).existsSync(),
        isFalse,
      );
      await object.close();
      await directory.close();
    },
  );

  test('retained object handle denies pathname replacement', () async {
    final directory = await backend.anchor(reportDirectory);
    final object = await directory.createExclusive('report.json');
    await object.write(const [1, 3, 5]);
    await object.flush();
    final path = p.join(reportDirectory.path, 'report.json');

    expect(
      () => File(path).renameSync(p.join(reportDirectory.path, 'moved.json')),
      throwsA(isA<FileSystemException>()),
    );
    await object.rewind();
    expect(await object.read(32), const [1, 3, 5]);
    await object.close();
    await directory.close();
  });

  test('final reparse collision is not followed or modified', () async {
    final foreignDirectory = Directory(p.join(sandbox.path, 'foreign'))
      ..createSync();
    final foreign = File(p.join(foreignDirectory.path, 'sentinel.json'))
      ..writeAsBytesSync(const [4, 2, 1]);
    final linkPath = p.join(reportDirectory.path, 'report.json');
    final junction = await Process.run('cmd', [
      '/c',
      'mklink',
      '/J',
      linkPath,
      foreignDirectory.path,
    ]);
    expect(
      junction.exitCode,
      0,
      reason: '${junction.stdout}${junction.stderr}',
    );
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

    expect(foreign.readAsBytesSync(), const [4, 2, 1]);
    expect(Directory(linkPath).existsSync(), isTrue);
    await directory.close();
  });
}

final class _RecordingWindowsReportBindings implements WindowsReportBindings {
  _RecordingWindowsReportBindings({this.openRelativeFailure});

  final WindowsNativeFailure? openRelativeFailure;
  final List<String> absoluteDirectoryOpens = [];
  final List<(int, String)> relativeDirectoryOpens = [];
  var _nextAddress = 1;

  @override
  Pointer<Void> openDirectory(String path) {
    absoluteDirectoryOpens.add(path);
    return Pointer<Void>.fromAddress(_nextAddress++);
  }

  @override
  Pointer<Void> openRelativeDirectory(Pointer<Void> parent, String component) {
    relativeDirectoryOpens.add((parent.address, component));
    return Pointer<Void>.fromAddress(_nextAddress++);
  }

  @override
  Pointer<Void> openRelative(
    Pointer<Void> parent,
    String leaf, {
    required bool create,
  }) {
    final failure = openRelativeFailure;
    if (failure != null) throw failure;
    return Pointer<Void>.fromAddress(_nextAddress++);
  }

  @override
  WindowsHandleIdentityData identity(Pointer<Void> handle) =>
      WindowsHandleIdentityData(
        volumeSerial: 7,
        fileId: List<int>.filled(16, handle.address),
        byteLength: 0,
        isDirectory: true,
        isReparsePoint: false,
      );

  @override
  void verifyNtfs(Pointer<Void> directory) {}

  @override
  void close(Pointer<Void> handle) {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
