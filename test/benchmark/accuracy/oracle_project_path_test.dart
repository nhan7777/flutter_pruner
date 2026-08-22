import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/oracle_project_path.dart';

void main() {
  test('accepts only canonical project-relative POSIX paths', () {
    for (final value in const <String>[
      'lib/main.dart',
      'assets/icons/a..b.png',
      'test/space name.dart',
    ]) {
      expect(isCanonicalProjectRelativePosixPath(value), isTrue, reason: value);
    }

    for (final value in const <String>[
      '',
      '/lib/main.dart',
      r'C:/lib/main.dart',
      r'lib\main.dart',
      'lib//main.dart',
      'lib/./main.dart',
      'lib/../main.dart',
      '../lib/main.dart',
      'lib/main.dart/',
      'lib/\u0000main.dart',
      'lib/main\u007f.dart',
    ]) {
      expect(
        isCanonicalProjectRelativePosixPath(value),
        isFalse,
        reason: value,
      );
    }
  });

  test(
    'validates project-relative source locations through the same grammar',
    () {
      expect(
        isCanonicalProjectRelativePosixLocation('lib/main.dart:7'),
        isTrue,
      );
      expect(
        isCanonicalProjectRelativePosixLocation(
          'lib/main.dart:7:3',
          requireColumn: true,
        ),
        isTrue,
      );
      for (final value in const <String>[
        'lib//main.dart:7',
        'lib/main.dart:0',
        'lib/main.dart:7:0',
        '/lib/main.dart:7',
        'lib/main.dart',
      ]) {
        expect(
          isCanonicalProjectRelativePosixLocation(value),
          isFalse,
          reason: value,
        );
      }
    },
  );
}
