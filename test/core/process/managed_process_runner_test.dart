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

  test('inherits the parent environment by default', () async {
    final script = _writeScript(tempDir, 'environment.dart', r'''
import 'dart:io';

void main(List<String> arguments) {
  stdout.write(Platform.environment[arguments.single] ?? '<missing>');
}
''');
    final inheritedPath = Platform.environment['PATH'];
    expect(inheritedPath, isNotNull);

    final result = await const ManagedProcessRunner().run(
      Platform.resolvedExecutable,
      [script.path, 'PATH'],
      workingDirectory: tempDir.path,
      timeout: const Duration(seconds: 5),
      maxOutputBytesPerStream: 4096,
    );

    expect(result.exitCode, 0);
    expect(result.stdout.text, inheritedPath);
  });

  test('uses a copied explicit environment override', () async {
    final script = _writeScript(tempDir, 'environment_override.dart', r'''
import 'dart:io';

void main(List<String> arguments) {
  stdout.write(Platform.environment[arguments.single] ?? '<missing>');
}
''');
    const variableName = 'FLUTTER_PRUNER_MANAGED_PROCESS_TEST';
    final environmentOverrides = <String, String>{
      variableName: 'captured-before-call-returned',
    };

    final resultFuture = const ManagedProcessRunner().run(
      Platform.resolvedExecutable,
      [script.path, variableName],
      workingDirectory: tempDir.path,
      timeout: const Duration(seconds: 5),
      maxOutputBytesPerStream: 4096,
      environmentOverrides: environmentOverrides,
    );
    environmentOverrides[variableName] = 'mutated-after-call';
    final result = await resultFuture;

    expect(result.exitCode, 0);
    expect(result.stdout.text, 'captured-before-call-returned');
  });

  test(
    'can exclude the parent environment while preserving overrides',
    () async {
      final script = _writeScript(tempDir, 'isolated_environment.dart', r'''
import 'dart:io';

void main(List<String> arguments) {
  for (final name in arguments) {
    stdout.writeln(Platform.environment[name] ?? '<missing>');
  }
}
''');
      const variableName = 'FLUTTER_PRUNER_MANAGED_PROCESS_TEST';

      final result = await const ManagedProcessRunner().run(
        Platform.resolvedExecutable,
        [script.path, 'PATH', variableName],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 5),
        maxOutputBytesPerStream: 4096,
        environmentOverrides: const {variableName: 'explicit-only'},
        includeParentEnvironment: false,
      );

      expect(result.exitCode, 0);
      expect(result.stdout.text, '<missing>\nexplicit-only\n');
    },
    skip: Platform.isWindows
        ? 'Windows may provide required system environment entries.'
        : false,
  );

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

  test('captures exact payload bytes including malformed UTF-8', () async {
    final script = _writeScript(tempDir, 'malformed_output.dart', r'''
import 'dart:io';

void main() {
  stdout.add(const [0x66, 0x80, 0x67, 0xff]);
}
''');

    final result = await const ManagedProcessRunner().run(
      Platform.resolvedExecutable,
      [script.path],
      workingDirectory: tempDir.path,
      timeout: const Duration(seconds: 5),
      maxOutputBytesPerStream: 3,
    );

    expect(result.exitCode, 0);
    expect(result.stdout.capturedPayload, [0x66, 0x80, 0x67]);
    expect(result.stdout.capturedBytes, 3);
    expect(result.stdout.omittedBytes, 1);
    expect(
      result.stdout.text,
      'f\ufffdg\n...[output truncated; 1 bytes omitted]',
    );
  });

  test('payload input and returned payload are defensive copies', () {
    final source = <int>[0x61, 0xff, 0x62];
    final output = BoundedProcessOutput(
      capturedPayload: source,
      omittedBytes: 2,
    );

    source[0] = 0x7a;
    final returned = output.capturedPayload;
    returned[2] = 0x7a;

    expect(output.capturedPayload, [0x61, 0xff, 0x62]);
    expect(output.capturedBytes, 3);
    expect(output.omittedBytes, 2);
    expect(output.truncated, isTrue);
    expect(output.text, 'a\ufffdb\n...[output truncated; 2 bytes omitted]');
  });

  test('result construction defaults resource evidence to unsupported', () {
    final result = ManagedProcessResult(
      exitCode: 0,
      stdout: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
      stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
    );

    expect(
      result.resourceObservation,
      same(ProcessTreeResourceObservation.unsupported),
    );
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
      '42 1 Sun Aug 16 10:00:00 2026 S 128\n',
    ).identityFor(42)!;
    final reused = PosixProcessTableSnapshot.parse(
      '42 1 Sun Aug 16 10:00:01 2026 S 256\n',
    );

    expect(reused.containsIdentity(observed), isFalse);
    expect(reused.matchingPids([observed]), isEmpty);
  });

  test('parses and sums RSS for a tracked root and descendants', () {
    final snapshot = PosixProcessTableSnapshot.parse('''
10 1 Sun Aug 16 10:00:00 2026 S 100
11 10 Sun Aug 16 10:00:01 2026 S 200
12 11 Sun Aug 16 10:00:02 2026 S 300
99 1 Sun Aug 16 10:00:03 2026 S 400
''');
    final trackedPids = <int>{10}..addAll(snapshot.descendantsOf({10}));
    final trackedIdentities = trackedPids.map(snapshot.identityFor).nonNulls;

    expect(snapshot.sumRssBytes(trackedIdentities), 600 * 1024);
  });

  test(
    'POSIX observer default does not execute a PATH ps shim',
    () async {
      final marker = File(p.join(tempDir.path, 'path-ps-shim-executed'));
      expect(marker.path, isNot(contains("'")));
      final shimDirectory = Directory(p.join(tempDir.path, 'path-shim'))
        ..createSync();
      final psShim = _writeScript(shimDirectory, 'ps', '''#!/bin/sh
: > '${marker.path}'
exec /bin/ps "\$@"
''');
      final chmod = await Process.run(
        '/bin/chmod',
        ['755', psShim.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

      final workload = _writeScript(
        tempDir,
        'default_observer_workload.dart',
        r'''
import 'dart:async';

Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 2));
}
''',
      );
      final helper = _writeScript(tempDir, 'default_observer_helper.dart', r'''
import 'dart:io';

import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';

Future<void> main(List<String> arguments) async {
  final result = await const ManagedProcessRunner().run(
    Platform.resolvedExecutable,
    [arguments[0]],
    workingDirectory: arguments[1],
    timeout: const Duration(seconds: 5),
    maxOutputBytesPerStream: 4096,
    includeParentEnvironment: false,
  );
  stdout.write(result.resourceObservation.sampleCount);
}
''');
      final packageConfig = p.join(
        Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );

      final helperResult = await Process.run(
        Platform.resolvedExecutable,
        ['--packages=$packageConfig', helper.path, workload.path, tempDir.path],
        environment: {'PATH': shimDirectory.path},
      );

      expect(helperResult.exitCode, 0, reason: '${helperResult.stderr}');
      expect(int.parse('${helperResult.stdout}'), greaterThan(0));
      expect(marker.existsSync(), isFalse);
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'POSIX process observation is supported only on Linux and macOS.'
        : false,
  );

  test(
    'POSIX observer launches its inspector with an isolated environment',
    () async {
      final marker = File(p.join(tempDir.path, 'inspection-environment'));
      expect(marker.path, isNot(contains("'")));
      final inspector = _writeScript(tempDir, 'controlled_ps', '''#!/bin/sh
/usr/bin/env > '${marker.path}'
exec /bin/ps "\$@"
''');
      final chmod = await Process.run(
        '/bin/chmod',
        ['755', inspector.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');

      final workload = _writeScript(tempDir, 'observer_workload.dart', r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (File(arguments[0]).existsSync()) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  throw StateError('The process observer did not launch its inspector.');
}
''');
      final helper = _writeScript(tempDir, 'observer_helper.dart', r'''
import 'dart:io';

import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';

Future<void> main(List<String> arguments) async {
  final result = await ManagedProcessRunner(
    posixProcessTableExecutable: arguments[2],
  ).run(
    Platform.resolvedExecutable,
    [arguments[0], arguments[3]],
    workingDirectory: arguments[1],
    timeout: const Duration(seconds: 5),
    maxOutputBytesPerStream: 4096,
    includeParentEnvironment: false,
  );
  stdout.write(result.exitCode);
}
''');
      final packageConfig = p.join(
        Directory.current.path,
        '.dart_tool',
        'package_config.json',
      );

      final helperResult = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=$packageConfig',
          helper.path,
          workload.path,
          tempDir.path,
          inspector.path,
          marker.path,
        ],
        environment: {
          'PATH': tempDir.path,
          'LANG': 'hostile-locale',
          'LC_ALL': 'hostile-locale',
          'LD_LIBRARY_PATH': tempDir.path,
          'DYLD_LIBRARY_PATH': tempDir.path,
          'FLUTTER_PRUNER_PARENT_SENTINEL': 'must-not-be-inherited',
        },
      );

      expect(helperResult.exitCode, 0, reason: '${helperResult.stderr}');
      expect(helperResult.stdout, '0');
      expect(marker.existsSync(), isTrue);
      final inspectorEnvironment = marker.readAsLinesSync().toSet();
      expect(inspectorEnvironment, containsAll(const ['LANG=C', 'LC_ALL=C']));
      for (final inheritedValue in <String>[
        'PATH=${tempDir.path}',
        'LD_LIBRARY_PATH=${tempDir.path}',
        'DYLD_LIBRARY_PATH=${tempDir.path}',
        'FLUTTER_PRUNER_PARENT_SENTINEL=must-not-be-inherited',
      ]) {
        expect(inspectorEnvironment, isNot(contains(inheritedValue)));
      }
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'POSIX process observation is supported only on Linux and macOS.'
        : false,
  );

  test(
    'measures RSS for a live POSIX parent and child process',
    () async {
      final child = _writeScript(tempDir, 'rss_child.dart', r'''
import 'dart:async';
import 'dart:typed_data';

Future<void> main() async {
  final allocation = Uint8List(4 * 1024 * 1024);
  for (var index = 0; index < allocation.length; index += 4096) {
    allocation[index] = 1;
  }
  await Future<void>.delayed(const Duration(milliseconds: 900));
  if (allocation.last == 255) throw StateError('unreachable');
}
''');
      final parent = _writeScript(tempDir, 'rss_parent.dart', r'''
import 'dart:io';
import 'dart:typed_data';

Future<void> main(List<String> arguments) async {
  final allocation = Uint8List(4 * 1024 * 1024);
  for (var index = 0; index < allocation.length; index += 4096) {
    allocation[index] = 1;
  }
  final child = await Process.start(Platform.resolvedExecutable, arguments);
  await Future.wait<dynamic>([
    child.exitCode,
    child.stdout.drain<void>(),
    child.stderr.drain<void>(),
  ]);
  if (allocation.last == 255) throw StateError('unreachable');
}
''');

      final result = await const ManagedProcessRunner().run(
        Platform.resolvedExecutable,
        [parent.path, child.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 5),
        maxOutputBytesPerStream: 4096,
      );

      expect(result.exitCode, 0);
      expect(
        result.resourceObservation.status,
        ProcessResourceObservationStatus.measured,
      );
      expect(result.resourceObservation.sampleCount, greaterThan(0));
      expect(result.resourceObservation.sampledPeakRssBytes, greaterThan(0));
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'Process-tree RSS sampling is supported only on POSIX hosts.'
        : false,
  );

  test(
    'confirmed POSIX timeout retains collected RSS samples',
    () async {
      final child = _writeScript(tempDir, 'timeout_child.dart', r'''
import 'dart:async';

Future<void> main() async {
  await Future<void>.delayed(const Duration(seconds: 30));
}
''');
      final parent = _writeScript(tempDir, 'timeout_parent.dart', r'''
import 'dart:async';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final child = await Process.start(Platform.resolvedExecutable, arguments);
  await Future.wait<dynamic>([
    child.exitCode,
    child.stdout.drain<void>(),
    child.stderr.drain<void>(),
  ]);
}
''');

      final result = await const ManagedProcessRunner().run(
        Platform.resolvedExecutable,
        [parent.path, child.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(milliseconds: 800),
        maxOutputBytesPerStream: 4096,
      );

      expect(result.exitCode, -1);
      expect(result.timedOut, isTrue);
      expect(
        result.resourceObservation.status,
        ProcessResourceObservationStatus.measured,
      );
      expect(result.resourceObservation.sampleCount, greaterThan(0));
      expect(result.resourceObservation.sampledPeakRssBytes, greaterThan(0));
    },
    skip: !Platform.isLinux && !Platform.isMacOS
        ? 'Confirmed process-tree termination is POSIX-specific.'
        : false,
  );
}

File _writeScript(Directory directory, String name, String content) {
  return File(p.join(directory.path, name))..writeAsStringSync(content);
}
