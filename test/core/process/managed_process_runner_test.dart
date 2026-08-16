import 'dart:io';

import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('managed_process_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('preserves argv boundaries and reports a successful process', () async {
    final unexpectedMarker = File(p.join(tempDir.path, 'shell-expanded'));
    final script = _writeScript(tempDir, 'argv.dart', r'''
import 'dart:io';

void main(List<String> arguments) {
  stdout.write(arguments.single);
}
''');
    final literalArgument = 'value; touch ${unexpectedMarker.path}';

    final result = await const ManagedProcessRunner().run(
      Platform.resolvedExecutable,
      [script.path, literalArgument],
      workingDirectory: tempDir.path,
      timeout: const Duration(seconds: 5),
      maxOutputBytesPerStream: 1024,
    );

    expect(result.exitCode, 0);
    expect(result.timedOut, isFalse);
    expect(result.stdout.text, literalArgument);
    expect(result.outputTruncated, isFalse);
    expect(unexpectedMarker.existsSync(), isFalse);
  });

  test('drains but bounds both streams for a non-zero process', () async {
    final script = _writeScript(tempDir, 'large_output.dart', r'''
import 'dart:io';

void main() {
  stdout.write(List<String>.filled(200000, 'o').join());
  stderr.write(List<String>.filled(200000, 'e').join());
  exitCode = 23;
}
''');

    final result = await const ManagedProcessRunner().run(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: tempDir.path,
      timeout: const Duration(seconds: 5),
      maxOutputBytesPerStream: 1024,
    );

    expect(result.exitCode, 23);
    expect(result.timedOut, isFalse);
    expect(result.stdout.capturedBytes, 1024);
    expect(result.stderr.capturedBytes, 1024);
    expect(result.stdout.omittedBytes, greaterThan(0));
    expect(result.stderr.omittedBytes, greaterThan(0));
    expect(result.stdout.text, contains('output truncated'));
    expect(result.stderr.text, contains('output truncated'));
  });

  test('rejects non-positive timeouts before spawning', () async {
    expect(
      () => const ManagedProcessRunner().run(
        Platform.resolvedExecutable,
        const ['--version'],
        workingDirectory: tempDir.path,
        timeout: Duration.zero,
        maxOutputBytesPerStream: 1024,
      ),
      throwsArgumentError,
    );
  });

  test('does not match an unrelated process that reused a PID', () {
    final observed = PosixProcessTableSnapshot.parse(
      '42 1 Sun Aug 16 10:00:00 2026 S\n',
    ).identityFor(42)!;
    final reused = PosixProcessTableSnapshot.parse(
      '42 1 Sun Aug 16 10:00:01 2026 S\n',
    );

    expect(reused.containsIdentity(observed), isFalse);
    expect(reused.matchingPids([observed]), isEmpty);
  });
}

File _writeScript(Directory directory, String name, String content) {
  return File(p.join(directory.path, name))..writeAsStringSync(content);
}
