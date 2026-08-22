import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'rejects evidence labelled with a commit other than repository HEAD',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'windows_blocker_evidence_',
      );
      addTearDown(() {
        if (output.existsSync()) output.deleteSync(recursive: true);
      });

      final result = await Process.run(Platform.resolvedExecutable, [
        p.join('tool', 'generate_windows_blocker_evidence.dart'),
        '--output',
        output.path,
        '--commit',
        '0' * 40,
        Directory.current.path,
      ]);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('does not match repository HEAD'));
      expect(output.listSync(), isEmpty);
    },
  );
}
