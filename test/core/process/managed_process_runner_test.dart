import 'dart:async';
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

  test('cancellation requested before launch never starts a process', () async {
    final cancellation = ManagedProcessCancellationController()
      ..requestCancellation(ProcessSignal.sigint);
    var startCalled = false;
    final runner = ManagedProcessRunner(
      cancellationController: cancellation,
      processStarter:
          (executable, arguments, {required workingDirectory}) async {
            startCalled = true;
            return Process.start(
              executable,
              arguments,
              workingDirectory: workingDirectory,
            );
          },
    );

    await expectLater(
      runner.run(
        Platform.resolvedExecutable,
        const ['--version'],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 5),
        maxOutputBytesPerStream: 1024,
      ),
      throwsA(
        isA<ProcessCancellationBeforeLaunchException>().having(
          (error) => error.originalSignal,
          'originalSignal',
          ProcessSignal.sigint,
        ),
      ),
    );
    expect(startCalled, isFalse);
    expect(cancellation.pendingOrActiveTreeCount, 0);
  });

  test(
    'signal during pending launch terminates the spawned process tree',
    () async {
      final ready = File(p.join(tempDir.path, 'tree-ready'));
      final rootPid = File(p.join(tempDir.path, 'root-pid'));
      final childPid = File(p.join(tempDir.path, 'child-pid'));
      final rootSurvived = File(p.join(tempDir.path, 'root-survived'));
      final childSurvived = File(p.join(tempDir.path, 'child-survived'));
      final childScript = _writeScript(tempDir, 'pending_child.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid');
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[1]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final rootScript = _writeScript(tempDir, 'pending_root.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid');
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[1], arguments[2], arguments[3]],
  );
  final childPid = File(arguments[2]);
  while (!childPid.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(arguments[4]).writeAsStringSync('ready');
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[5]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final launchPending = Completer<void>();
      final releaseLaunch = Completer<void>();
      final cancellation = ManagedProcessCancellationController();
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              final process = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
              );
              while (!ready.existsSync()) {
                await Future<void>.delayed(const Duration(milliseconds: 10));
              }
              launchPending.complete();
              await releaseLaunch.future;
              return process;
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [
          rootScript.path,
          rootPid.path,
          childScript.path,
          childPid.path,
          childSurvived.path,
          ready.path,
          rootSurvived.path,
        ],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 60),
        maxOutputBytesPerStream: 1024,
      );
      await launchPending.future.timeout(const Duration(seconds: 45));
      expect(cancellation.pendingOrActiveTreeCount, 1);

      cancellation.requestCancellation(ProcessSignal.sigterm);
      releaseLaunch.complete();

      await expectLater(
        execution,
        throwsA(
          isA<ProcessCancellationConfirmedException>()
              .having(
                (error) => error.originalSignal,
                'originalSignal',
                ProcessSignal.sigterm,
              )
              .having(
                (error) => error.rootPid,
                'rootPid',
                int.parse(rootPid.readAsStringSync()),
              ),
        ),
      );
      expect(cancellation.pendingOrActiveTreeCount, 0);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(rootSurvived.existsSync(), isFalse);
      expect(childSurvived.existsSync(), isFalse);
      expect(childPid.existsSync(), isTrue);
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'unconfirmed signal termination retains its trigger and root PID',
    () async {
      final ready = File(p.join(tempDir.path, 'unconfirmed-ready'));
      final script = _writeScript(tempDir, 'unconfirmed.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final cancellation = ManagedProcessCancellationController();
      int? launchedPid;
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processTreeTerminator:
            (
              process,
              exitCode, {
              required observedProcesses,
              required observationReliable,
            }) async {
              launchedPid = process.pid;
              process.kill(ProcessSignal.sigkill);
              await exitCode;
              return ManagedProcessTerminationEvidence(
                terminationConfirmed: false,
                observedProcesses: observedProcesses,
                observationReliable: observationReliable,
              );
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [script.path, ready.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytesPerStream: 1024,
      );
      int? rootPid;
      while (rootPid == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (ready.existsSync()) {
          rootPid = int.tryParse(ready.readAsStringSync().trim());
        }
      }

      cancellation.requestCancellation(ProcessSignal.sigterm);

      Object? failure;
      try {
        await execution;
      } on Object catch (error) {
        failure = error;
      }
      expect(launchedPid, isNotNull);
      expect(
        failure,
        isA<ProcessTerminationUnconfirmedException>()
            .having((error) => error.processId, 'processId', launchedPid)
            .having(
              (error) => error.triggerSignal,
              'triggerSignal',
              ProcessSignal.sigterm,
            ),
      );
      expect(cancellation.pendingOrActiveTreeCount, 0);
    },
  );

  test(
    'unconfirmed termination retains final identities discovered after observer stop',
    () async {
      final ready = File(p.join(tempDir.path, 'late-descendant-ready'));
      final script = _writeScript(tempDir, 'late_descendant_root.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      const lateDescendant = PosixProcessIdentity(
        pid: 987654,
        startFingerprint: 'Thu Aug 27 12:00:01 2026',
      );
      final cancellation = ManagedProcessCancellationController();
      Process? startedProcess;
      addTearDown(() async {
        final process = startedProcess;
        if (process == null) return;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              return startedProcess = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
              );
            },
        processTreeTerminator:
            (
              process,
              exitCode, {
              required observedProcesses,
              required observationReliable,
            }) async {
              expect(observationReliable, isTrue);
              expect(observedProcesses.keys, unorderedEquals([process.pid]));
              final finalIdentities = <int, PosixProcessIdentity>{
                ...observedProcesses,
                lateDescendant.pid: lateDescendant,
              };
              process.kill(ProcessSignal.sigkill);
              await exitCode;
              return ManagedProcessTerminationEvidence(
                terminationConfirmed: false,
                observedProcesses: finalIdentities,
                observationReliable: true,
              );
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [script.path, ready.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytesPerStream: 1024,
      );
      await _waitForPidFile(ready);
      cancellation.requestCancellation(ProcessSignal.sigterm);

      ProcessTerminationUnconfirmedException? captured;
      try {
        await execution;
        fail('Expected unconfirmed termination.');
      } on ProcessTerminationUnconfirmedException catch (error) {
        captured = error;
      }
      final ProcessTerminationUnconfirmedException capturedError = captured;

      expect(
        capturedError.observedProcesses.keys,
        unorderedEquals([startedProcess!.pid, lateDescendant.pid]),
      );
      expect(
        capturedError.observedProcesses[lateDescendant.pid],
        lateDescendant,
      );
      expect(capturedError.observationReliable, isTrue);
      expect(
        () => capturedError.observedProcesses[lateDescendant.pid] =
            capturedError.observedProcesses[startedProcess!.pid]!,
        throwsUnsupportedError,
      );
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );

  test(
    'root loss before the freeze boundary makes final identity evidence unreliable',
    () async {
      final ready = File(p.join(tempDir.path, 'freeze-gap-ready'));
      final script = _writeScript(tempDir, 'freeze_gap_root.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final cancellation = ManagedProcessCancellationController();
      final inspector = _MutableIdentityInspector();
      Process? startedProcess;
      addTearDown(() async {
        final process = startedProcess;
        if (process == null) return;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processIdentityInspector: inspector,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              final process = startedProcess = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
              );
              inspector.snapshotValue = await _waitForIdentitySnapshot(
                process.pid,
              );
              return process;
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [script.path, ready.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytesPerStream: 1024,
      );
      await _waitForPidFile(ready);
      inspector.snapshotValue = const PosixProcessTableSnapshot.empty();
      cancellation.requestCancellation(ProcessSignal.sigterm);
      startedProcess!.kill(ProcessSignal.sigkill);

      await expectLater(
        execution,
        throwsA(
          isA<ProcessTerminationUnconfirmedException>()
              .having(
                (error) => error.observationReliable,
                'observationReliable',
                isFalse,
              )
              .having(
                (error) => error.observedProcesses.keys,
                'observedProcesses',
                contains(startedProcess!.pid),
              ),
        ),
      );
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );

  test(
    'observer retains a disappeared descendant and marks the hand-off unreliable',
    () async {
      final ready = File(p.join(tempDir.path, 'observer-gap-ready'));
      final script = _writeScript(tempDir, 'observer_gap_root.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      const disappearedDescendant = PosixProcessIdentity(
        pid: 987653,
        startFingerprint: 'Thu Aug 27 12:00:02 2026',
      );
      final cancellation = ManagedProcessCancellationController();
      final inspector = _ScriptedIdentityInspector();
      Process? startedProcess;
      addTearDown(() async {
        final process = startedProcess;
        if (process == null) return;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processIdentityInspector: inspector,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              final process = startedProcess = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
              );
              final actual = await _waitForIdentitySnapshot(process.pid);
              final rootIdentity = actual.identityFor(process.pid)!;
              final rootOnly = _snapshotWithChildren(rootIdentity);
              inspector.configure(
                script: <PosixProcessTableSnapshot>[
                  _snapshotWithChildren(
                    rootIdentity,
                    children: const <PosixProcessIdentity>[
                      disappearedDescendant,
                    ],
                  ),
                  rootOnly,
                ],
                fallback: _FixedIdentityInspector(rootOnly),
              );
              return process;
            },
        processTreeTerminator:
            (
              process,
              exitCode, {
              required observedProcesses,
              required observationReliable,
            }) async {
              process.kill(ProcessSignal.sigkill);
              await exitCode;
              return ManagedProcessTerminationEvidence(
                terminationConfirmed: false,
                observedProcesses: observedProcesses,
                observationReliable: observationReliable,
              );
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [script.path, ready.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytesPerStream: 1024,
      );
      await _waitForPidFile(ready);
      await inspector.scriptConsumed.timeout(const Duration(seconds: 10));
      cancellation.requestCancellation(ProcessSignal.sigterm);

      await expectLater(
        execution,
        throwsA(
          isA<ProcessTerminationUnconfirmedException>()
              .having(
                (error) => error.observedProcesses.keys,
                'historical identities',
                unorderedEquals(<int>[
                  startedProcess!.pid,
                  disappearedDescendant.pid,
                ]),
              )
              .having(
                (error) => error.observedProcesses[disappearedDescendant.pid],
                'disappeared descendant identity',
                disappearedDescendant,
              )
              .having(
                (error) => error.observationReliable,
                'observationReliable',
                isFalse,
              ),
        ),
      );
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );

  test(
    'production termination cannot confirm a tree after descendant disappearance',
    () async {
      final rootReady = File(p.join(tempDir.path, 'gap-root.pid'));
      final childReady = File(p.join(tempDir.path, 'gap-child.pid'));
      final childScript = _writeScript(tempDir, 'gap_child.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final rootScript = _writeScript(tempDir, 'gap_parent.dart', r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid', flush: true);
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[1], arguments[2]],
  );
  while (!File(arguments[2]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      final cancellation = ManagedProcessCancellationController();
      final inspector = _ScriptedIdentityInspector();
      Process? startedProcess;
      PosixProcessIdentity? rootIdentity;
      PosixProcessIdentity? childIdentity;
      addTearDown(() async {
        final child = childIdentity;
        if (child != null) await _terminateExactTestProcess(child);
        final root = rootIdentity;
        if (root != null) await _terminateExactTestProcess(root);
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processIdentityInspector: inspector,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              final process = startedProcess = await Process.start(
                executable,
                arguments,
                workingDirectory: workingDirectory,
              );
              final childPid = await _waitForPidFile(childReady);
              final actual = await _waitForIdentitySnapshot(
                process.pid,
                additionalProcessId: childPid,
              );
              rootIdentity = actual.identityFor(process.pid)!;
              childIdentity = actual.identityFor(childPid)!;
              inspector.configure(
                script: <PosixProcessTableSnapshot>[
                  _snapshotWithChildren(
                    rootIdentity!,
                    children: <PosixProcessIdentity>[childIdentity!],
                  ),
                  _snapshotWithChildren(rootIdentity!),
                ],
                fallback: const ManagedProcessIdentityInspector(),
              );
              return process;
            },
      );

      final execution = runner.run(
        Platform.resolvedExecutable,
        [rootScript.path, rootReady.path, childScript.path, childReady.path],
        workingDirectory: tempDir.path,
        timeout: const Duration(seconds: 30),
        maxOutputBytesPerStream: 1024,
      );
      await _waitForPidFile(rootReady);
      await inspector.scriptConsumed.timeout(const Duration(seconds: 10));
      await _stopExactTestProcess(childIdentity!);
      await _stopExactTestProcess(rootIdentity!);
      await _waitForStoppedIdentities(<PosixProcessIdentity>[
        rootIdentity!,
        childIdentity!,
      ]);
      cancellation.requestCancellation(ProcessSignal.sigterm);

      await expectLater(
        execution,
        throwsA(
          isA<ProcessTerminationUnconfirmedException>()
              .having(
                (error) => error.observationReliable,
                'observationReliable',
                isFalse,
              )
              .having(
                (error) => error.observedProcesses.values,
                'known root and descendant identities',
                containsAll(<PosixProcessIdentity>[
                  rootIdentity!,
                  childIdentity!,
                ]),
              ),
        ),
      );
      expect(startedProcess, isNotNull);
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

File _writeScript(Directory directory, String name, String content) {
  return File(p.join(directory.path, name))..writeAsStringSync(content);
}

Future<int> _waitForPidFile(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    if (file.existsSync()) {
      final parsed = int.tryParse(file.readAsStringSync().trim());
      if (parsed != null) return parsed;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Timed out waiting for PID evidence at ${file.path}.');
}

Future<PosixProcessTableSnapshot> _waitForIdentitySnapshot(
  int processId, {
  int? additionalProcessId,
}) async {
  final inspector = const ManagedProcessIdentityInspector();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await inspector.snapshot();
    if (snapshot?.identityFor(processId) != null &&
        (additionalProcessId == null ||
            snapshot!.identityFor(additionalProcessId) != null)) {
      return snapshot!;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Timed out waiting for identity of PID $processId.');
}

PosixProcessTableSnapshot _snapshotWithChildren(
  PosixProcessIdentity rootIdentity, {
  List<PosixProcessIdentity> children = const <PosixProcessIdentity>[],
}) => PosixProcessTableSnapshot.parse(
  <String>[
    '${rootIdentity.pid} 1 ${rootIdentity.startFingerprint} S',
    for (final child in children)
      '${child.pid} ${rootIdentity.pid} ${child.startFingerprint} S',
  ].join('\n'),
);

Future<void> _stopExactTestProcess(PosixProcessIdentity identity) async {
  final snapshot = await const ManagedProcessIdentityInspector().snapshot();
  if (snapshot == null || !snapshot.containsIdentity(identity)) {
    throw StateError('Owned test process PID ${identity.pid} disappeared.');
  }
  Process.killPid(identity.pid, ProcessSignal.sigstop);
}

Future<void> _waitForStoppedIdentities(
  Iterable<PosixProcessIdentity> identities,
) async {
  final expected = identities.toList(growable: false);
  final inspector = const ManagedProcessIdentityInspector();
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await inspector.snapshot();
    if (snapshot != null &&
        expected.every(
          (identity) =>
              snapshot.containsIdentity(identity) &&
              snapshot.isStopped(identity.pid),
        )) {
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Timed out waiting for owned test processes to stop.');
}

Future<void> _terminateExactTestProcess(PosixProcessIdentity identity) async {
  final inspector = const ManagedProcessIdentityInspector();
  final before = await inspector.snapshot();
  if (before?.containsIdentity(identity) ?? false) {
    Process.killPid(identity.pid, ProcessSignal.sigkill);
  }
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final current = await inspector.snapshot();
    if (current != null && !current.containsIdentity(identity)) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException(
    'Owned test process PID ${identity.pid} did not exit after SIGKILL.',
  );
}

final class _MutableIdentityInspector implements ProcessIdentityInspector {
  PosixProcessTableSnapshot? snapshotValue;

  @override
  Future<PosixProcessTableSnapshot?> snapshot() async => snapshotValue;
}

final class _FixedIdentityInspector implements ProcessIdentityInspector {
  const _FixedIdentityInspector(this.snapshotValue);

  final PosixProcessTableSnapshot snapshotValue;

  @override
  Future<PosixProcessTableSnapshot?> snapshot() async => snapshotValue;
}

final class _ScriptedIdentityInspector implements ProcessIdentityInspector {
  List<PosixProcessTableSnapshot>? _script;
  ProcessIdentityInspector? _fallback;
  var _index = 0;
  final Completer<void> _scriptConsumed = Completer<void>();

  Future<void> get scriptConsumed => _scriptConsumed.future;

  void configure({
    required List<PosixProcessTableSnapshot> script,
    required ProcessIdentityInspector fallback,
  }) {
    if (_script != null || script.isEmpty) {
      throw StateError(
        'Identity script must be configured once and non-empty.',
      );
    }
    _script = List<PosixProcessTableSnapshot>.unmodifiable(script);
    _fallback = fallback;
  }

  @override
  Future<PosixProcessTableSnapshot?> snapshot() async {
    final script = _script;
    final fallback = _fallback;
    if (script == null || fallback == null) {
      throw StateError('Identity script was not configured before inspection.');
    }
    if (_index < script.length) {
      final snapshot = script[_index++];
      if (_index == script.length && !_scriptConsumed.isCompleted) {
        _scriptConsumed.complete();
      }
      return snapshot;
    }
    return fallback.snapshot();
  }
}
