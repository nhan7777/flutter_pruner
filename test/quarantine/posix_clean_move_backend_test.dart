import 'dart:io';

import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:flutter_pruner/src/quarantine/native/posix_clean_move_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  if (!Platform.isLinux && !Platform.isMacOS) return;

  late Directory sandbox;
  late Directory base;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('posix_clean_move_');
    base = Directory(p.join(sandbox.path, 'quarantine'))..createSync();
  });

  tearDown(() {
    if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
  });

  test(
    'moves the inspected directory to an exclusive retained destination',
    () async {
      final run = Directory(p.join(base.path, 'run-a'))..createSync();
      File(
        p.join(run.path, 'manifest.json'),
      ).writeAsStringSync('exact evidence');
      final anchored = await PosixRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const <String>['run-a']);
      await anchored.ensureDirectory(const <String>[
        '.clean-retained',
        'v1',
        'op-a',
        'runs',
      ]);

      final outcome = await anchored.moveDirectoryNoReplace(
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
      await anchored.flushMetadata();

      expect(outcome.movedIdentity.sameObjectAs(expected), isTrue);
      expect(run.existsSync(), isFalse);
      expect(
        File(
          p.join(
            base.path,
            '.clean-retained',
            'v1',
            'op-a',
            'runs',
            'run-a',
            'manifest.json',
          ),
        ).readAsStringSync(),
        'exact evidence',
      );
    },
  );

  test(
    'destination collision preserves both source and foreign bytes',
    () async {
      final run = Directory(p.join(base.path, 'run-a'))..createSync();
      final source = File(p.join(run.path, 'source.txt'))
        ..writeAsStringSync('source');
      final destinationParent = Directory(
        p.join(base.path, '.clean-retained', 'v1', 'op-a', 'runs'),
      )..createSync(recursive: true);
      final collision = Directory(p.join(destinationParent.path, 'run-a'))
        ..createSync();
      final foreign = File(p.join(collision.path, 'foreign.txt'))
        ..writeAsStringSync('foreign');
      final anchored = await PosixRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const <String>['run-a']);

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
            CleanMoveFailure.collision,
          ),
        ),
      );

      expect(source.readAsStringSync(), 'source');
      expect(foreign.readAsStringSync(), 'foreign');
    },
  );

  test(
    'rejects a symlinked directory component without touching its target',
    () async {
      final outside = Directory(p.join(sandbox.path, 'outside'))..createSync();
      final foreign = File(p.join(outside.path, 'foreign.txt'))
        ..writeAsStringSync('foreign');
      Link(p.join(base.path, 'run-a')).createSync(outside.path);
      final anchored = await PosixRecoverableCleanMoveBackend().anchor(base);
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
      expect(foreign.readAsStringSync(), 'foreign');
    },
  );

  test(
    'base pathname replacement blocks the move and preserves both trees',
    () async {
      final run = Directory(p.join(base.path, 'run-a'))..createSync();
      final original = File(p.join(run.path, 'original.txt'))
        ..writeAsStringSync('original');
      final anchored = await PosixRecoverableCleanMoveBackend().anchor(base);
      addTearDown(anchored.close);
      final expected = await anchored.inspectDirectory(const <String>['run-a']);
      final movedBase = Directory(p.join(sandbox.path, 'moved-base'));
      base.renameSync(movedBase.path);
      base = Directory(p.join(sandbox.path, 'quarantine'))..createSync();
      final foreignRun = Directory(p.join(base.path, 'run-a'))..createSync();
      final foreign = File(p.join(foreignRun.path, 'foreign.txt'))
        ..writeAsStringSync('foreign');

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

      expect(
        File(
          p.join(movedBase.path, 'run-a', 'original.txt'),
        ).readAsStringSync(),
        'original',
      );
      expect(original.path, contains('/quarantine/'));
      expect(foreign.readAsStringSync(), 'foreign');
    },
  );

  test('close is idempotent and later operations fail closed', () async {
    final anchored = await PosixRecoverableCleanMoveBackend().anchor(base);

    await anchored.close();
    await anchored.close();

    await expectLater(
      () => anchored.inspectDirectory(const <String>['run-a']),
      throwsA(isA<CleanMoveException>()),
    );
  });
}
