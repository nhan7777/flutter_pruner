import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'rejects evidence labelled with a commit other than repository HEAD',
    () async {
      final output = Directory.systemTemp.createTempSync(
        'clean_blocker_evidence_generator_',
      );
      addTearDown(() {
        if (output.existsSync()) output.deleteSync(recursive: true);
      });

      final result = await Process.run(Platform.resolvedExecutable, [
        'run',
        'tool/generate_clean_blocker_evidence.dart',
        '--output',
        output.path,
        '--commit',
        '0123456789abcdef0123456789abcdef01234567',
      ], workingDirectory: Directory.current.path);

      expect(result.exitCode, 2);
      expect(
        result.stderr,
        contains(
          'Hosted clean evidence commit does not match repository HEAD.',
        ),
      );
      expect(
        File(
          p.join(
            output.path,
            'clean-path-replacement-toctou-${_platformName()}.json',
          ),
        ).existsSync(),
        isFalse,
      );
    },
  );
}

String _platformName() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  return 'unsupported';
}
