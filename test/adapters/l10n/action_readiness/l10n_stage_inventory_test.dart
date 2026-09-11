import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('L10nStageInventory', () {
    late Directory scratch;
    late Directory root;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('l10n-inventory-test-');
      final createdRoot = Directory(p.join(scratch.path, 'stage'))
        ..createSync();
      root = Directory(createdRoot.resolveSymbolicLinksSync());
    });

    tearDown(() {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    });

    test(
      'sorts relative POSIX entries and selectively captures immutable bytes',
      () async {
        File(p.join(root.path, 'z.txt')).writeAsStringSync('zeta');
        File(p.join(root.path, 'a/b.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('bravo');
        File(p.join(root.path, 'a/private.txt')).writeAsStringSync('private');
        Directory(p.join(root.path, 'empty')).createSync();

        final capture = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'z.txt', 'a/b.txt'},
        );

        expect(capture.entries.keys.toList(), [
          'a',
          'a/b.txt',
          'a/private.txt',
          'empty',
          'z.txt',
        ]);
        expect(capture.invalidPaths, isEmpty);
        expect(capture.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(capture.entries['a']!.kind, L10nStageEntryKind.directory);
        expect(capture.entries['empty']!.kind, L10nStageEntryKind.directory);
        expect(
          capture.entries['a/b.txt']!.kind,
          L10nStageEntryKind.regularFile,
        );
        expect(
          capture.entries['a/b.txt']!.capturedBytes!.copy(),
          'bravo'.codeUnits,
        );
        expect(
          capture.entries['z.txt']!.capturedBytes!.copy(),
          'zeta'.codeUnits,
        );
        expect(capture.entries['a/private.txt']!.capturedBytes, isNull);
        expect(capture.entries['a/private.txt']!.sha256, isNotNull);
        expect(capture.entries['a']!.sha256, isNull);
        expect(capture.entries['a']!.capturedBytes, isNull);

        final leaked = capture.entries['a/b.txt']!.capturedBytes!.copy();
        leaked[0] = 0;
        expect(
          capture.entries['a/b.txt']!.capturedBytes!.copy(),
          'bravo'.codeUnits,
        );
        expect(() => capture.entries.clear(), throwsUnsupportedError);
        expect(() => capture.invalidPaths.add('later'), throwsUnsupportedError);

        final reordered = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'a/b.txt', 'z.txt'},
        );
        expect(reordered.fingerprint, capture.fingerprint);
        expect(reordered.entries.keys.toList(), capture.entries.keys.toList());

        final noCapturedBytes = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {},
        );
        expect(noCapturedBytes.fingerprint, capture.fingerprint);
        expect(noCapturedBytes.entries['a/b.txt']!.capturedBytes, isNull);

        final callerOwned = <String>{'z.txt'};
        final pending = L10nStageInventory.capture(
          root,
          captureBytesFor: callerOwned,
        );
        callerOwned
          ..clear()
          ..add('a/private.txt');
        final frozenRequest = await pending;
        expect(frozenRequest.entries['z.txt']!.capturedBytes, isNotNull);
        expect(frozenRequest.entries['a/private.txt']!.capturedBytes, isNull);

        final createdMirror = Directory(p.join(scratch.path, 'mirror'))
          ..createSync();
        final mirror = Directory(createdMirror.resolveSymbolicLinksSync());
        File(p.join(mirror.path, 'z.txt')).writeAsStringSync('zeta');
        File(p.join(mirror.path, 'a/b.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('bravo');
        File(p.join(mirror.path, 'a/private.txt')).writeAsStringSync('private');
        Directory(p.join(mirror.path, 'empty')).createSync();
        final relocated = await L10nStageInventory.capture(
          mirror,
          captureBytesFor: const {'a/private.txt'},
        );
        expect(relocated.fingerprint, capture.fingerprint);
      },
    );

    test(
      'fingerprints exact content and supported POSIX mode changes',
      () async {
        final file = File(p.join(root.path, 'value.txt'))
          ..writeAsStringSync('before');
        if (!Platform.isWindows) _chmod(file.path, 0x1a4);

        final before = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'value.txt'},
        );
        file.writeAsStringSync('after!');
        final contentChanged = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'value.txt'},
        );

        expect(
          contentChanged.entries['value.txt']!.sha256,
          isNot(before.entries['value.txt']!.sha256),
        );
        expect(contentChanged.fingerprint, isNot(before.fingerprint));
        expect(
          contentChanged.entries['value.txt']!.capturedBytes!.copy(),
          'after!'.codeUnits,
        );

        if (!Platform.isWindows) {
          _chmod(file.path, 0x180);
          final modeChanged = await L10nStageInventory.capture(
            root,
            captureBytesFor: const {'value.txt'},
          );
          expect(modeChanged.entries['value.txt']!.posixMode, 0x180);
          expect(
            modeChanged.entries['value.txt']!.sha256,
            contentChanged.entries['value.txt']!.sha256,
          );
          expect(modeChanged.fingerprint, isNot(contentChanged.fingerprint));
        } else {
          expect(before.entries['value.txt']!.posixMode, isNull);
        }

        file.deleteSync();
        Directory(file.path).createSync();
        final typeChanged = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'value.txt'},
        );
        expect(
          typeChanged.entries['value.txt']!.kind,
          L10nStageEntryKind.directory,
        );
        expect(typeChanged.entries['value.txt']!.sha256, isNull);
        expect(typeChanged.entries['value.txt']!.capturedBytes, isNull);
        expect(typeChanged.fingerprint, isNot(contentChanged.fingerprint));
      },
    );

    test('fingerprints exact directory mode changes on POSIX', () async {
      if (Platform.isWindows) {
        markTestSkipped('POSIX directory mode contract.');
        return;
      }
      final directory = Directory(p.join(root.path, 'nested'))..createSync();
      _chmod(directory.path, 0x1ed);
      final before = await L10nStageInventory.capture(
        root,
        captureBytesFor: const {},
      );

      _chmod(directory.path, 0x1c0);
      final after = await L10nStageInventory.capture(
        root,
        captureBytesFor: const {},
      );

      expect(before.entries['nested']!.posixMode, 0x1ed);
      expect(after.entries['nested']!.posixMode, 0x1c0);
      expect(after.fingerprint, isNot(before.fingerprint));
    });

    test(
      'records links and other types without following a canonical escape',
      () async {
        if (Platform.isWindows) {
          markTestSkipped(
            'Link and FIFO inventory contract is POSIX-specific.',
          );
          return;
        }
        final regular = File(p.join(root.path, 'regular.txt'))
          ..writeAsStringSync('inside');
        Link(p.join(root.path, 'inside-link')).createSync(regular.path);
        final outside = Directory(p.join(scratch.path, 'outside'))
          ..createSync();
        File(p.join(outside.path, 'secret.txt')).writeAsStringSync('secret');
        Link(p.join(root.path, 'escape')).createSync(outside.path);
        Link(p.join(root.path, 'escape-chain')).createSync('escape');
        Link(p.join(root.path, 'dangling')).createSync('missing-target');
        final fifoPath = p.join(root.path, 'events.pipe');
        final fifo = Process.runSync('/usr/bin/mkfifo', [fifoPath]);
        expect(fifo.exitCode, 0, reason: '${fifo.stderr}');

        final capture = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {'regular.txt', 'inside-link', 'events.pipe'},
        ).timeout(const Duration(seconds: 2));

        expect(
          capture.entries['regular.txt']!.kind,
          L10nStageEntryKind.regularFile,
        );
        expect(
          capture.entries['inside-link']!.kind,
          L10nStageEntryKind.symbolicLink,
        );
        expect(
          capture.entries['escape']!.kind,
          L10nStageEntryKind.symbolicLink,
        );
        expect(
          capture.entries['escape-chain']!.kind,
          L10nStageEntryKind.symbolicLink,
        );
        expect(
          capture.entries['dangling']!.kind,
          L10nStageEntryKind.symbolicLink,
        );
        expect(capture.entries['events.pipe']!.kind, L10nStageEntryKind.other);
        expect(capture.entries['inside-link']!.sha256, isNull);
        expect(capture.entries['escape']!.capturedBytes, isNull);
        expect(capture.entries['events.pipe']!.capturedBytes, isNull);
        expect(capture.entries, isNot(contains('escape/secret.txt')));
        expect(capture.invalidPaths, [
          'dangling',
          'escape',
          'escape-chain',
          'events.pipe',
          'inside-link',
        ]);
      },
    );

    test('reports unportable names created by the filesystem', () async {
      if (Platform.isWindows) {
        markTestSkipped('Windows does not permit the same filename matrix.');
        return;
      }
      File(p.join(root.path, 'bad%name.txt')).writeAsStringSync('percent');
      File(p.join(root.path, r'bad\name.txt')).writeAsStringSync('slash');
      File(p.join(root.path, 'bad\nname.txt')).writeAsStringSync('control');

      final capture = await L10nStageInventory.capture(
        root,
        captureBytesFor: const {},
      );

      expect(capture.invalidPaths, [
        'bad\nname.txt',
        'bad%name.txt',
        r'bad\name.txt',
      ]);
      expect(capture.entries.keys, containsAll(capture.invalidPaths));
      expect(capture.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
    });

    test(
      'returns an unavailable sentinel when the root changes mid-scan',
      () async {
        final moved = Directory(p.join(scratch.path, 'moved-stage'));
        var swapped = false;

        final capture = await L10nStageInventory.captureForTesting(
          root,
          captureBytesFor: const {},
          operationHook: (operation, directory, relativePath) async {
            if (!swapped &&
                operation == L10nStageInventoryOperation.afterRootValidated) {
              swapped = true;
              directory.renameSync(moved.path);
              Directory(directory.path).createSync();
            }
          },
        );

        expect(capture.entries, isEmpty);
        expect(capture.invalidPaths, ['.']);
        expect(capture.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
      },
    );

    test(
      'returns an unavailable sentinel when enumeration changes before commit',
      () async {
        File(p.join(root.path, 'first.txt')).writeAsStringSync('first');
        var mutated = false;

        final capture = await L10nStageInventory.captureForTesting(
          root,
          captureBytesFor: const {},
          operationHook: (operation, directory, relativePath) async {
            if (!mutated &&
                operation == L10nStageInventoryOperation.afterEnumeration) {
              mutated = true;
              File(
                p.join(directory.path, 'late.txt'),
              ).writeAsStringSync('late');
            }
          },
        );

        expect(capture.entries, isEmpty);
        expect(capture.invalidPaths, ['.']);
      },
    );

    test(
      'does not publish bytes from a file that changes during its read',
      () async {
        final file = File(p.join(root.path, 'value.txt'))
          ..writeAsStringSync('before');
        var mutated = false;

        final capture = await L10nStageInventory.captureForTesting(
          root,
          captureBytesFor: const {'value.txt'},
          operationHook: (operation, directory, relativePath) async {
            if (!mutated &&
                operation == L10nStageInventoryOperation.afterEntryRead &&
                relativePath == 'value.txt') {
              mutated = true;
              file.writeAsStringSync('after!');
            }
          },
        );

        expect(capture.invalidPaths, ['value.txt']);
        expect(
          capture.entries['value.txt']!.kind,
          L10nStageEntryKind.regularFile,
        );
        expect(capture.entries['value.txt']!.sha256, isNull);
        expect(capture.entries['value.txt']!.capturedBytes, isNull);
      },
    );

    test('does not follow a file replaced by a link before reading', () async {
      if (Platform.isWindows) {
        markTestSkipped('Symlink race contract is POSIX-specific.');
        return;
      }
      final file = File(p.join(root.path, 'value.txt'))
        ..writeAsStringSync('inside');
      final outside = File(p.join(scratch.path, 'outside.txt'))
        ..writeAsStringSync('outside-secret');
      var replaced = false;

      final capture = await L10nStageInventory.captureForTesting(
        root,
        captureBytesFor: const {'value.txt'},
        operationHook: (operation, directory, relativePath) async {
          if (!replaced &&
              operation == L10nStageInventoryOperation.beforeEntryRead &&
              relativePath == 'value.txt') {
            replaced = true;
            file.deleteSync();
            Link(file.path).createSync(outside.path);
          }
        },
      );

      expect(capture.invalidPaths, ['value.txt']);
      expect(
        capture.entries['value.txt']!.kind,
        L10nStageEntryKind.symbolicLink,
      );
      expect(capture.entries['value.txt']!.sha256, isNull);
      expect(capture.entries['value.txt']!.capturedBytes, isNull);
      expect(outside.readAsStringSync(), 'outside-secret');
    });

    test(
      'allows requested publishable paths that are initially absent',
      () async {
        final capture = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {
            'lib/generated/app.dart',
            'build/untranslated.json',
          },
        );

        expect(capture.entries, isEmpty);
        expect(capture.invalidPaths, isEmpty);
        expect(capture.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
      },
    );

    test('rejects non-portable byte-capture paths before scanning', () async {
      File(p.join(root.path, 'sentinel.txt')).writeAsStringSync('unchanged');
      for (final invalid in <Set<String>>[
        {p.join(root.path, 'absolute.txt')},
        const {'../escape.txt'},
        const {'nested\\windows.txt'},
        const {'with%escape.txt'},
        const {'with:scheme.txt'},
        const {'with?query.txt'},
        const {'with#fragment.txt'},
        const {'nested//empty.txt'},
        const {'nested/./dot.txt'},
        const {'control\u0000.txt'},
        const {'non-ascii-é.txt'},
        const {'A.txt', 'a.txt'},
        const {''},
      ]) {
        await expectLater(
          L10nStageInventory.capture(root, captureBytesFor: invalid),
          throwsArgumentError,
          reason: '$invalid',
        );
      }
      expect(
        File(p.join(root.path, 'sentinel.txt')).readAsStringSync(),
        'unchanged',
      );
    });

    test('rejects a non-directory or aliased inventory root', () async {
      final file = File(p.join(scratch.path, 'not-a-root'))
        ..writeAsStringSync('file');
      await expectLater(
        L10nStageInventory.capture(
          Directory(file.path),
          captureBytesFor: const {},
        ),
        throwsArgumentError,
      );

      if (!Platform.isWindows) {
        final alias = Link(p.join(scratch.path, 'root-alias'))
          ..createSync(root.path);
        await expectLater(
          L10nStageInventory.capture(
            Directory(alias.path),
            captureBytesFor: const {},
          ),
          throwsArgumentError,
        );

        final createdParent = Directory(
          p.join(scratch.path, 'canonical-parent'),
        )..createSync();
        final canonicalParent = Directory(
          createdParent.resolveSymbolicLinksSync(),
        );
        Directory(p.join(canonicalParent.path, 'nested-root')).createSync();
        final parentAlias = Link(p.join(scratch.path, 'parent-alias'))
          ..createSync(canonicalParent.path);
        await expectLater(
          L10nStageInventory.capture(
            Directory(p.join(parentAlias.path, 'nested-root')),
            captureBytesFor: const {},
          ),
          throwsArgumentError,
        );
      }
    });

    test(
      'reports ASCII-folded filesystem collisions deterministically',
      () async {
        final upper = File(p.join(root.path, 'Case.txt'))
          ..writeAsStringSync('upper');
        final lower = File(p.join(root.path, 'case.txt'))
          ..writeAsStringSync('lower');
        if (upper.readAsStringSync() == lower.readAsStringSync()) {
          markTestSkipped('Host filesystem is case-insensitive.');
          return;
        }

        final capture = await L10nStageInventory.capture(
          root,
          captureBytesFor: const {},
        );

        expect(capture.invalidPaths, ['Case.txt', 'case.txt']);
        expect(capture.entries.keys.toList(), ['Case.txt', 'case.txt']);
      },
    );
  });
}

void _chmod(String path, int mode) {
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8).padLeft(4, '0'),
    path,
  ]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
}
