import 'dart:ffi';
import 'dart:io';

import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/native/windows_clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/native/windows_clean_move_bindings.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Windows NTFS moves the exact directory into an absent retained leaf',
    () async {
      if (!Platform.isWindows) return;
      final root = Directory.systemTemp.createTempSync('windows_clean_move_');
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final base = Directory('${root.path}\\quarantine')..createSync();
      final source = Directory('${base.path}\\run-a')..createSync();
      File('${source.path}\\payload.txt').writeAsStringSync('exact');
      final anchored = await WindowsRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const ['run-a']);
      await anchored.ensureDirectory(const [
        '.clean-retained',
        'v1',
        'operation-a',
        'runs',
      ]);

      final moved = await anchored.moveDirectoryNoReplace(
        source: const ['run-a'],
        destination: const [
          '.clean-retained',
          'v1',
          'operation-a',
          'runs',
          'run-a',
        ],
        expectedIdentity: expected,
      );

      expect(moved.movedIdentity.sameObjectAs(expected), isTrue);
      expect(source.existsSync(), isFalse);
      expect(
        File(
          '${base.path}\\.clean-retained\\v1\\operation-a\\runs\\run-a\\payload.txt',
        ).readAsStringSync(),
        'exact',
      );
    },
  );

  test(
    'Windows NTFS no-replace collision preserves both directory trees',
    () async {
      if (!Platform.isWindows) return;
      final root = Directory.systemTemp.createTempSync(
        'windows_clean_collision_',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final base = Directory('${root.path}\\quarantine')..createSync();
      final source = Directory('${base.path}\\run-a')..createSync();
      File('${source.path}\\source.txt').writeAsStringSync('source');
      final destination = Directory(
        '${base.path}\\.clean-retained\\v1\\operation-a\\runs\\run-a',
      )..createSync(recursive: true);
      File('${destination.path}\\foreign.txt').writeAsStringSync('foreign');
      final anchored = await WindowsRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const ['run-a']);

      await expectLater(
        () => anchored.moveDirectoryNoReplace(
          source: const ['run-a'],
          destination: const [
            '.clean-retained',
            'v1',
            'operation-a',
            'runs',
            'run-a',
          ],
          expectedIdentity: expected,
        ),
        throwsA(
          isA<CleanMoveException>().having(
            (error) => error.category,
            'category',
            CleanMoveFailure.collision,
          ),
        ),
      );
      expect(File('${source.path}\\source.txt').readAsStringSync(), 'source');
      expect(
        File('${destination.path}\\foreign.txt').readAsStringSync(),
        'foreign',
      );
    },
  );

  test(
    'Windows NTFS reports an absent relative directory as not found',
    () async {
      if (!Platform.isWindows) return;
      final root = Directory.systemTemp.createTempSync(
        'windows_clean_missing_',
      );
      addTearDown(() {
        if (root.existsSync()) root.deleteSync(recursive: true);
      });
      final base = Directory('${root.path}\\quarantine')..createSync();
      final anchored = await WindowsRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);

      await expectLater(
        () => anchored.inspectDirectory(const ['missing-run']),
        throwsA(
          isA<CleanMoveException>().having(
            (error) => error.category,
            'category',
            CleanMoveFailure.notFound,
          ),
        ),
      );
    },
  );

  test(
    'renames the exact expected source handle without replacement',
    () async {
      final bindings = _FakeWindowsCleanMoveBindings();
      final backend = WindowsRecoverableCleanMoveBackend(
        bindings: bindings,
        canonicalPathResolver: (_) => r'C:\project\.flutter_pruner\quarantine',
      );
      final anchored = await backend.anchor(Directory('ignored'));
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const <String>['run-a']);
      await anchored.ensureDirectory(const <String>[
        '.clean-retained',
        'v1',
        'op-a',
        'runs',
      ]);

      final result = await anchored.moveDirectoryNoReplace(
        source: const <String>['run-a'],
        destination: const <String>[
          '.clean-retained',
          'v1',
          'op-a',
          'runs',
          'run-a',
        ],
        expectedIdentity: expected,
      );

      expect(result.movedIdentity.sameObjectAs(expected), isTrue);
      expect(bindings.renamedSource, bindings.sourceHandle);
      expect(bindings.renameCount, 1);
      expect(bindings.flushCount, greaterThanOrEqualTo(2));
      expect(
        bindings.openModes,
        containsAll(<WindowsCleanDirectoryOpenMode>{
          WindowsCleanDirectoryOpenMode.inspect,
          WindowsCleanDirectoryOpenMode.ensureWritable,
          WindowsCleanDirectoryOpenMode.openWritable,
          WindowsCleanDirectoryOpenMode.renameSource,
        }),
      );
    },
  );

  test('identity drift fails before the rename boundary', () async {
    final bindings = _FakeWindowsCleanMoveBindings();
    final backend = WindowsRecoverableCleanMoveBackend(
      bindings: bindings,
      canonicalPathResolver: (_) => r'C:\project\.flutter_pruner\quarantine',
    );
    final anchored = await backend.anchor(Directory('ignored'));
    addTearDown(anchored.close);
    await anchored.ensureDirectory(const <String>[
      '.clean-retained',
      'v1',
      'op-a',
      'runs',
    ]);

    await expectLater(
      () => anchored.moveDirectoryNoReplace(
        source: const <String>['run-a'],
        destination: const <String>[
          '.clean-retained',
          'v1',
          'op-a',
          'runs',
          'run-a',
        ],
        expectedIdentity: const CleanObjectIdentity(
          storageId: 'win-volume:1',
          objectId: 'win-file:999',
          kind: CleanObjectKind.directory,
        ),
      ),
      throwsA(
        isA<CleanMoveException>().having(
          (error) => error.category,
          'category',
          CleanMoveFailure.identityDrift,
        ),
      ),
    );
    expect(bindings.renameCount, 0);
  });

  test('reparse directories are rejected without a rename', () async {
    final bindings = _FakeWindowsCleanMoveBindings(reparseSource: true);
    final backend = WindowsRecoverableCleanMoveBackend(
      bindings: bindings,
      canonicalPathResolver: (_) => r'C:\project\.flutter_pruner\quarantine',
    );
    final anchored = await backend.anchor(Directory('ignored'));
    addTearDown(anchored.close);

    await expectLater(
      () => anchored.inspectDirectory(const <String>['run-a']),
      throwsA(
        isA<CleanMoveException>().having(
          (error) => error.category,
          'category',
          CleanMoveFailure.invalidObject,
        ),
      ),
    );
    expect(bindings.renameCount, 0);
  });

  test('base identity replacement blocks the move', () async {
    final bindings = _FakeWindowsCleanMoveBindings();
    final backend = WindowsRecoverableCleanMoveBackend(
      bindings: bindings,
      canonicalPathResolver: (_) => r'C:\project\.flutter_pruner\quarantine',
    );
    final anchored = await backend.anchor(Directory('ignored'));
    addTearDown(anchored.close);
    final expected = await anchored.inspectDirectory(const <String>['run-a']);
    await anchored.ensureDirectory(const <String>[
      '.clean-retained',
      'v1',
      'op-a',
      'runs',
    ]);
    bindings.replacementBase = true;

    await expectLater(
      () => anchored.moveDirectoryNoReplace(
        source: const <String>['run-a'],
        destination: const <String>[
          '.clean-retained',
          'v1',
          'op-a',
          'runs',
          'run-a',
        ],
        expectedIdentity: expected,
      ),
      throwsA(
        isA<CleanMoveException>().having(
          (error) => error.category,
          'category',
          CleanMoveFailure.unreachableBase,
        ),
      ),
    );
    expect(bindings.renameCount, 0);
  });

  test('all acquired handles close exactly once', () async {
    final bindings = _FakeWindowsCleanMoveBindings();
    final backend = WindowsRecoverableCleanMoveBackend(
      bindings: bindings,
      canonicalPathResolver: (_) => r'C:\project\.flutter_pruner\quarantine',
    );
    final anchored = await backend.anchor(Directory('ignored'));
    await anchored.inspectDirectory(const <String>['run-a']);

    await anchored.close();
    await anchored.close();

    expect(bindings.closeCounts.values, everyElement(1));
  });
}

final class _FakeWindowsCleanMoveBindings implements WindowsCleanMoveBindings {
  _FakeWindowsCleanMoveBindings({this.reparseSource = false});

  final bool reparseSource;
  final Pointer<Void> baseHandle = Pointer<Void>.fromAddress(1);
  final Pointer<Void> replacementBaseHandle = Pointer<Void>.fromAddress(2);
  final Pointer<Void> sourceHandle = Pointer<Void>.fromAddress(3);
  final Pointer<Void> retainedHandle = Pointer<Void>.fromAddress(4);
  final Map<String, Pointer<Void>> _directories = <String, Pointer<Void>>{};
  final Map<int, int> closeCounts = <int, int>{};
  final Set<WindowsCleanDirectoryOpenMode> openModes =
      <WindowsCleanDirectoryOpenMode>{};
  var replacementBase = false;
  var renameCount = 0;
  var flushCount = 0;
  Pointer<Void>? renamedSource;
  var _nextAddress = 10;

  @override
  void close(Pointer<Void> handle) {
    closeCounts.update(handle.address, (value) => value + 1, ifAbsent: () => 1);
  }

  @override
  void flush(Pointer<Void> handle) {
    flushCount++;
  }

  @override
  WindowsCleanIdentityData identity(Pointer<Void> handle) {
    if (handle == replacementBaseHandle) {
      return const WindowsCleanIdentityData(
        volumeSerial: 1,
        fileIdHex: '999',
        isDirectory: true,
        isReparsePoint: false,
      );
    }
    if (handle == sourceHandle || handle == retainedHandle) {
      return WindowsCleanIdentityData(
        volumeSerial: 1,
        fileIdHex: '2',
        isDirectory: true,
        isReparsePoint: reparseSource,
      );
    }
    return const WindowsCleanIdentityData(
      volumeSerial: 1,
      fileIdHex: '1',
      isDirectory: true,
      isReparsePoint: false,
    );
  }

  @override
  Pointer<Void> openDirectory(String path) =>
      replacementBase ? replacementBaseHandle : baseHandle;

  @override
  Pointer<Void> openRelativeDirectory(
    Pointer<Void> parent,
    String leaf, {
    required WindowsCleanDirectoryOpenMode mode,
  }) {
    openModes.add(mode);
    if (leaf == 'run-a' && mode == WindowsCleanDirectoryOpenMode.renameSource) {
      return sourceHandle;
    }
    if (leaf == 'run-a' && renamedSource != null) return retainedHandle;
    if (leaf == 'run-a') return sourceHandle;
    final key = '${parent.address}:$leaf';
    return _directories.putIfAbsent(
      key,
      () => Pointer<Void>.fromAddress(_nextAddress++),
    );
  }

  @override
  void renameNoReplace(
    Pointer<Void> source,
    Pointer<Void> destinationParent,
    String destinationLeaf,
  ) {
    renameCount++;
    renamedSource = source;
  }

  @override
  void verifyNtfs(Pointer<Void> handle) {}
}
