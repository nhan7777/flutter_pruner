import 'package:flutter_pruner/src/quarantine/clean_move_backend.dart';
import 'package:test/test.dart';

void main() {
  test('stable clean object identity matches only the same directory', () {
    const baseline = CleanObjectIdentity(
      storageId: 'dev:1',
      objectId: 'ino:2',
      kind: CleanObjectKind.directory,
    );

    expect(
      baseline.sameObjectAs(
        const CleanObjectIdentity(
          storageId: 'dev:1',
          objectId: 'ino:2',
          kind: CleanObjectKind.directory,
        ),
      ),
      isTrue,
    );
    expect(
      baseline.sameObjectAs(
        const CleanObjectIdentity(
          storageId: 'dev:1',
          objectId: 'ino:3',
          kind: CleanObjectKind.directory,
        ),
      ),
      isFalse,
    );
  });

  test('clean path components reject ambiguous or unsafe names', () {
    for (final value in <String>[
      '',
      '.',
      '..',
      'a/b',
      r'a\b',
      'a:b',
      'line\nfeed',
      'nul\u0000byte',
      'trailing.',
      'trailing ',
      'CON',
    ]) {
      expect(
        () => validateCleanPathComponent(value),
        throwsA(
          isA<CleanMoveException>().having(
            (error) => error.category,
            'category',
            CleanMoveFailure.invalidComponent,
          ),
        ),
        reason: value,
      );
    }
  });

  test('clean path components accept portable opaque leaves', () {
    for (final value in <String>[
      'run-20260827',
      '.clean-retained',
      'v1',
      'évidence-文件',
    ]) {
      expect(validateCleanPathComponent(value), value);
    }
  });

  test('clean move failures omit native causes from rendered diagnostics', () {
    const error = CleanMoveException(
      category: CleanMoveFailure.identityDrift,
      operation: 'move-directory',
      cause: 'secret/native/path',
    );

    expect(error.toString(), contains('operation=move-directory'));
    expect(error.toString(), contains('category=identityDrift'));
    expect(error.toString(), isNot(contains('secret/native/path')));
  });
}
