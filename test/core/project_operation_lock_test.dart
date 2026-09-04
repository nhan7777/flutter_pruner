import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../cli/cli_process_harness.dart';

void main() {
  test('excludes another process and can be acquired after release', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter_pruner_operation_lock_',
    );
    addTearDown(() async {
      if (project.existsSync()) await project.delete(recursive: true);
    });

    final process = await Process.start(Platform.resolvedExecutable, [
      'test/fixtures/project_operation_lock_holder.dart',
      project.path,
    ], workingDirectory: Directory.current.path);
    addTearDown(() {
      if (process.kill()) return process.exitCode;
      return Future<void>.value();
    });
    final locked = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first;
    expect(locked, 'LOCKED');

    final workspace = ToolWorkspace(project);
    final contentionMessage = Platform.isWindows
        ? contains('Another Flutter Pruner mutation is already active')
        : allOf(contains('operation=holder'), contains('pid='));
    await expectLater(
      ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'contender',
      ),
      throwsA(
        isA<ProjectOperationLockException>().having(
          (error) => error.message,
          'message',
          contentionMessage,
        ),
      ),
    );

    process.stdin.writeln('release');
    await process.stdin.close();
    expect(await process.exitCode, 0);

    final acquired = await ProjectOperationLock.acquire(
      workspace: workspace,
      operation: 'after-release',
    );
    await acquired.release();
    await acquired.release();
  });

  test('apply, rollback, and quarantine clean honor the shared lock', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter_pruner_command_lock_',
    );
    addTearDown(() async {
      if (project.existsSync()) await project.delete(recursive: true);
    });
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: lock_test
publish_to: none
environment:
  sdk: ^3.9.0
''');
    final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('void main() {}\n');
    final config = File(p.join(project.path, ToolWorkspace.configRelativePath));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
verification:
  steps:
    - id: noop
      argv: [dart, --version]
''');

    final process = await Process.start(Platform.resolvedExecutable, [
      'test/fixtures/project_operation_lock_holder.dart',
      project.path,
    ], workingDirectory: Directory.current.path);
    addTearDown(() {
      if (process.kill()) return process.exitCode;
      return Future<void>.value();
    });
    expect(
      await process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first,
      'LOCKED',
    );

    expect(
      await FlutterPrunerCommandRunner().run([
        'apply',
        '--dry-run',
        '--project',
        project.path,
      ]),
      1,
    );
    expect(
      await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'missing-run',
      ]),
      1,
    );
    expect(
      await FlutterPrunerCommandRunner().run([
        'quarantine',
        'clean',
        '--project',
        project.path,
        'missing-run',
      ]),
      1,
    );
    expect(mainFile.readAsStringSync(), 'void main() {}\n');

    process.stdin.writeln('release');
    await process.stdin.close();
    expect(await process.exitCode, 0);
  });

  test(
    'retains exact root and descendant identities after unconfirmed termination',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_uncertainty_journal_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      final workspace = ToolWorkspace(project);
      const rootIdentity = PosixProcessIdentity(
        pid: 5101,
        startFingerprint: 'Mon Aug 27 10:00:00 2026',
      );
      const childIdentity = PosixProcessIdentity(
        pid: 5102,
        startFingerprint: 'Mon Aug 27 10:00:01 2026',
      );
      final error = ProcessTerminationUnconfirmedException(
        processId: rootIdentity.pid,
        message: 'fixture process tree may still be active',
        triggerSignal: ProcessSignal.sigterm,
        observationReliable: true,
        observedProcesses: const <int, PosixProcessIdentity>{
          5101: rootIdentity,
          5102: childIdentity,
        },
      );
      final lock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'scan',
        identityInspector: const _FixedIdentityInspector.absent(),
      );

      await expectLater(
        lock.guardManagedProcessUncertainty<void>(
          incidentId: 'scan-run-1',
          phase: 'analysis',
          body: () async => throw error,
        ),
        throwsA(same(error)),
      );
      expect(lock.hasRetainedExactProcessIdentityEvidence, isTrue);
      await lock.release();

      final journal = workspace.operationLockFile.readAsStringSync();
      expect(journal, contains('"state":"unconfirmed"'));
      expect(
        journal,
        contains('"failureType":"ProcessTerminationUnconfirmedException"'),
      );
      expect(journal, contains('"trigger":"sigterm"'));
      expect(journal, contains('"pid":5101'));
      expect(journal, contains('"pid":5102'));
      expect(journal, contains(rootIdentity.startFingerprint));
      expect(journal, contains(childIdentity.startFingerprint));
    },
  );

  test(
    'runner hand-off blocks on a late descendant after the root exits until exact absence',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_late_descendant_handoff_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      final workspace = ToolWorkspace(project);
      final rootReady = File(p.join(project.path, 'root.pid'));
      final spawnRequest = File(p.join(project.path, 'spawn.request'));
      final childPidFile = File(p.join(project.path, 'child.pid'));
      final childScript = File(p.join(project.path, 'late_child.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 5));
}
''');
      final rootScript = File(p.join(project.path, 'late_root.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  final spawnRequest = File(arguments[1]);
  File(arguments[0]).writeAsStringSync('$pid', flush: true);
  while (!spawnRequest.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[2], arguments[3]],
  );
  while (!File(arguments[3]).existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  await Future<void>.delayed(const Duration(minutes: 5));
}
''');
      final cancellation = ManagedProcessCancellationController();
      Process? rootProcess;
      PosixProcessIdentity? childIdentity;
      addTearDown(() async {
        rootProcess?.kill(ProcessSignal.sigkill);
        final identity = childIdentity;
        if (identity != null) await _terminateExactTestProcess(identity);
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processStarter:
            (executable, arguments, {required workingDirectory}) async {
              return rootProcess = await Process.start(
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
              spawnRequest.writeAsStringSync('spawn', flush: true);
              final childPid = await _waitForPidEvidence(childPidFile);
              final finalSnapshot = await _waitForProcessIdentities(
                rootPid: process.pid,
                childPid: childPid,
              );
              final rootIdentity = finalSnapshot.identityFor(process.pid)!;
              childIdentity = finalSnapshot.identityFor(childPid)!;
              expect(observedProcesses[process.pid], rootIdentity);
              expect(
                finalSnapshot.descendantsOf(<int>{process.pid}),
                contains(childPid),
              );
              process.kill(ProcessSignal.sigkill);
              await exitCode;
              return ManagedProcessTerminationEvidence(
                terminationConfirmed: false,
                observedProcesses: <int, PosixProcessIdentity>{
                  process.pid: rootIdentity,
                  childPid: childIdentity!,
                },
                observationReliable: true,
              );
            },
      );
      final lock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'late-descendant-analysis',
      );
      final guarded = lock.guardManagedProcessUncertainty<ManagedProcessResult>(
        incidentId: 'late-descendant-analysis-1',
        phase: 'analysis',
        body: () => runner.run(
          Platform.resolvedExecutable,
          [
            rootScript.path,
            rootReady.path,
            spawnRequest.path,
            childScript.path,
            childPidFile.path,
          ],
          workingDirectory: project.path,
          timeout: const Duration(seconds: 30),
          maxOutputBytesPerStream: 1024,
        ),
      );
      await _waitForPidEvidence(rootReady);
      cancellation.requestCancellation(ProcessSignal.sigterm);

      ProcessTerminationUnconfirmedException? captured;
      try {
        await guarded;
        fail('Expected the late-descendant termination to be unconfirmed.');
      } on ProcessTerminationUnconfirmedException catch (error) {
        captured = error;
      } finally {
        await lock.release();
      }

      final lateIdentity = childIdentity!;
      expect(captured.observedProcesses[lateIdentity.pid], lateIdentity);
      final afterRootExit = await const ManagedProcessIdentityInspector()
          .snapshot();
      expect(afterRootExit, isNotNull);
      expect(
        afterRootExit!.containsIdentity(
          captured.observedProcesses[captured.processId]!,
        ),
        isFalse,
      );
      expect(afterRootExit.containsIdentity(lateIdentity), isTrue);
      await expectLater(
        ProjectOperationLock.acquire(
          workspace: workspace,
          operation: 'blocked-by-late-descendant',
        ),
        throwsA(
          isA<ProjectOperationLockException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('may still be running'),
              contains('${lateIdentity.pid}'),
            ),
          ),
        ),
      );

      await _terminateExactTestProcess(lateIdentity);
      final resolved = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'after-late-descendant-exit',
      );
      await resolved.release();
      expect(
        workspace.operationLockFile.readAsStringSync(),
        isNot(contains('"state":"unconfirmed"')),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'runner disappearance gap stays fail closed after every known identity is absent',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_observer_gap_handoff_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      final workspace = ToolWorkspace(project);
      final ready = File(p.join(project.path, 'observer-gap-root.pid'));
      final script = File(p.join(project.path, 'observer_gap_root.dart'))
        ..writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments.single).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(minutes: 5));
}
''');
      final cancellation = ManagedProcessCancellationController();
      final inspector = _ScriptedIdentityInspector();
      Process? rootProcess;
      addTearDown(() async {
        final process = rootProcess;
        if (process == null) return;
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 5));
      });
      final runner = ManagedProcessRunner(
        cancellationController: cancellation,
        processIdentityInspector: inspector,
        processStarter: (executable, arguments, {required workingDirectory}) async {
          final process = rootProcess = await Process.start(
            executable,
            arguments,
            workingDirectory: workingDirectory,
          );
          final actual = await _waitForRootIdentity(process.pid);
          final rootIdentity = actual.identityFor(process.pid)!;
          final disappearedDescendants = <PosixProcessIdentity>[
            for (var index = 0; index < 10; index++)
              PosixProcessIdentity(
                pid: 987600 + index,
                startFingerprint:
                    'Thu Aug 27 12:01:${index.toString().padLeft(2, '0')} 2026',
              ),
          ];
          final rootOnly = _snapshotWithChildren(rootIdentity);
          inspector.configure(
            script: <PosixProcessTableSnapshot>[
              _snapshotWithChildren(
                rootIdentity,
                children: disappearedDescendants,
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
      final lock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'observer-gap-analysis',
      );
      final guarded = lock.guardManagedProcessUncertainty<ManagedProcessResult>(
        incidentId: 'observer-gap-analysis-1',
        phase: 'analysis',
        body: () => runner.run(
          Platform.resolvedExecutable,
          [script.path, ready.path],
          workingDirectory: project.path,
          timeout: const Duration(seconds: 30),
          maxOutputBytesPerStream: 1024,
        ),
      );
      await _waitForPidEvidence(ready);
      await inspector.scriptConsumed.timeout(const Duration(seconds: 10));
      cancellation.requestCancellation(ProcessSignal.sigterm);

      ProcessTerminationUnconfirmedException? captured;
      try {
        await guarded;
        fail('Expected the disappearance-gap termination to be unconfirmed.');
      } on ProcessTerminationUnconfirmedException catch (error) {
        captured = error;
      } finally {
        await lock.release();
      }

      final capturedError = captured;
      ProjectOperationLockException? blocker;
      ProjectOperationLock? unexpectedlyAcquired;
      try {
        unexpectedlyAcquired = await ProjectOperationLock.acquire(
          workspace: workspace,
          operation: 'blocked-by-observer-gap',
          identityInspector: const _FixedIdentityInspector.absent(),
        );
      } on ProjectOperationLockException catch (error) {
        blocker = error;
      } finally {
        await unexpectedlyAcquired?.release();
      }

      expect(
        blocker?.message,
        allOf(
          contains('uncertainty evidence is corrupt'),
          contains('PID ${capturedError.processId}'),
          contains('and 3 more'),
        ),
      );
      expect(capturedError.observationReliable, isFalse);
      expect(capturedError.observedProcesses, hasLength(11));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('PID reuse does not keep an exact old identity active', () async {
    final project = await Directory.systemTemp.createTemp(
      'flutter_pruner_pid_reuse_',
    );
    addTearDown(() async {
      if (project.existsSync()) await project.delete(recursive: true);
    });
    final workspace = ToolWorkspace(project);
    const oldIdentity = PosixProcessIdentity(
      pid: 5201,
      startFingerprint: 'Mon Aug 27 10:01:00 2026',
    );
    await _recordUnconfirmedIdentities(
      workspace,
      const <int, PosixProcessIdentity>{5201: oldIdentity},
    );
    final reusedSnapshot = PosixProcessTableSnapshot.parse(
      '5201 1 Mon Aug 27 10:02:00 2026 S\n',
    );

    final acquired = await ProjectOperationLock.acquire(
      workspace: workspace,
      operation: 'after-pid-reuse',
      identityInspector: _FixedIdentityInspector(reusedSnapshot),
    );

    await acquired.release();
    expect(
      workspace.operationLockFile.readAsStringSync(),
      isNot(contains('"state":"unconfirmed"')),
    );
  });

  test(
    'a descendant-only exact survivor keeps every mutation blocked',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_descendant_survivor_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      final workspace = ToolWorkspace(project);
      const rootIdentity = PosixProcessIdentity(
        pid: 5301,
        startFingerprint: 'Mon Aug 27 10:03:00 2026',
      );
      const childIdentity = PosixProcessIdentity(
        pid: 5302,
        startFingerprint: 'Mon Aug 27 10:03:01 2026',
      );
      await _recordUnconfirmedIdentities(
        workspace,
        const <int, PosixProcessIdentity>{
          5301: rootIdentity,
          5302: childIdentity,
        },
      );
      final childOnly = PosixProcessTableSnapshot.parse(
        '5302 1 Mon Aug 27 10:03:01 2026 S\n',
      );

      await expectLater(
        ProjectOperationLock.acquire(
          workspace: workspace,
          operation: 'blocked-by-descendant',
          identityInspector: _FixedIdentityInspector(childOnly),
        ),
        throwsA(
          isA<ProjectOperationLockException>()
              .having((error) => error.message, 'message', contains('PID 5302'))
              .having(
                (error) => error.message,
                'message',
                contains('may still be running'),
              ),
        ),
      );
    },
  );

  test(
    'inspection unavailable and corrupt uncertainty stay fail closed',
    () async {
      final unavailableProject = await Directory.systemTemp.createTemp(
        'flutter_pruner_inspection_unavailable_',
      );
      final corruptProject = await Directory.systemTemp.createTemp(
        'flutter_pruner_uncertainty_corrupt_',
      );
      addTearDown(() async {
        for (final project in <Directory>[unavailableProject, corruptProject]) {
          if (project.existsSync()) await project.delete(recursive: true);
        }
      });
      final unavailableWorkspace = ToolWorkspace(unavailableProject);
      const identity = PosixProcessIdentity(
        pid: 5401,
        startFingerprint: 'Mon Aug 27 10:04:00 2026',
      );
      await _recordUnconfirmedIdentities(
        unavailableWorkspace,
        const <int, PosixProcessIdentity>{5401: identity},
      );

      await expectLater(
        ProjectOperationLock.acquire(
          workspace: unavailableWorkspace,
          operation: 'inspection-unavailable',
          identityInspector: const _FixedIdentityInspector.unavailable(),
        ),
        throwsA(
          isA<ProjectOperationLockException>().having(
            (error) => error.message,
            'message',
            allOf(contains('could not be inspected'), contains('PID 5401')),
          ),
        ),
      );

      final corruptWorkspace = ToolWorkspace(corruptProject);
      const corruptGuidanceIdentity = PosixProcessIdentity(
        pid: 5402,
        startFingerprint: 'Mon Aug 27 10:04:01 2026',
      );
      await _recordUnconfirmedIdentities(
        corruptWorkspace,
        const <int, PosixProcessIdentity>{5402: corruptGuidanceIdentity},
      );
      corruptWorkspace.operationLockFile.writeAsStringSync(
        '\n{"recordType":"processUncertainty","state":"unconfirmed"',
        mode: FileMode.append,
        flush: true,
      );

      await expectLater(
        ProjectOperationLock.acquire(
          workspace: corruptWorkspace,
          operation: 'corrupt-blocked',
          identityInspector: const _FixedIdentityInspector.absent(),
        ),
        throwsA(
          isA<ProjectOperationLockException>().having(
            (error) => error.message,
            'message',
            allOf(
              contains('uncertainty evidence is corrupt'),
              contains('PID 5402'),
            ),
          ),
        ),
      );
    },
  );

  test(
    'normal managed completion clears armed uncertainty before release',
    () async {
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_uncertainty_clear_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      final workspace = ToolWorkspace(project);
      final first = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'normal-scan',
        identityInspector: const _FixedIdentityInspector.absent(),
      );

      expect(
        await first.guardManagedProcessUncertainty<int>(
          incidentId: 'normal-scan-1',
          phase: 'analysis',
          body: () async => 42,
        ),
        42,
      );
      await first.release();

      final second = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'after-normal-scan',
        identityInspector: const _FixedIdentityInspector.unavailable(),
      );
      await second.release();
    },
  );

  test(
    'retained exact identity blocks scan apply rollback and clean admission',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final project = await Directory.systemTemp.createTemp(
        'flutter_pruner_uncertainty_commands_',
      );
      addTearDown(() async {
        if (project.existsSync()) await project.delete(recursive: true);
      });
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: uncertainty_commands
publish_to: none
environment:
  sdk: ^3.9.0
''');
      final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
      mainFile.parent.createSync(recursive: true);
      const originalBytes = 'void main() {}\n';
      mainFile.writeAsStringSync(originalBytes);
      final config = File(
        p.join(project.path, ToolWorkspace.configRelativePath),
      );
      config.parent.createSync(recursive: true);
      config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: vm
      platform: android
      entrypoint: lib/main.dart
verification:
  steps:
    - id: noop
      argv: [dart, --version]
''');
      final workspace = ToolWorkspace(project);
      final snapshot = await const ManagedProcessIdentityInspector().snapshot();
      final rootIdentity = snapshot?.identityFor(pid);
      expect(rootIdentity, isNotNull);
      await _recordUnconfirmedIdentities(workspace, <int, PosixProcessIdentity>{
        pid: rootIdentity!,
      });

      expect(
        await FlutterPrunerCommandRunner().run([
          'scan',
          '--adapter',
          'duplicates',
          '--project',
          project.path,
        ]),
        1,
      );
      expect(
        await FlutterPrunerCommandRunner().run([
          'apply',
          '--dry-run',
          '--adapter',
          'duplicates',
          '--project',
          project.path,
        ]),
        1,
      );
      expect(
        await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'missing-run',
        ]),
        1,
      );
      expect(
        await FlutterPrunerCommandRunner().run([
          'quarantine',
          'clean',
          '--project',
          project.path,
          'missing-run',
        ]),
        1,
      );
      expect(mainFile.readAsStringSync(), originalBytes);

      final resolution = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'auto-clear-after-exact-absence',
        identityInspector: const _FixedIdentityInspector.absent(),
      );
      await resolution.release();
      expect(
        await FlutterPrunerCommandRunner().run([
          'apply',
          '--dry-run',
          '--adapter',
          'duplicates',
          '--project',
          project.path,
        ]),
        0,
      );
      final afterResolution = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'after-resolution',
        identityInspector: const _FixedIdentityInspector.unavailable(),
      );
      await afterResolution.release();
      expect(
        workspace.operationLockFile.readAsStringSync(),
        isNot(contains('"state":"unconfirmed"')),
      );
    },
  );

  test(
    'test-only reviewed clean cannot cross its delete boundary while the project lock is held',
    () async {
      final fixture = CliFixture.create(prefix: 'quarantine clean held lock ');
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_held_lock\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'held-lock-run',
        entries: const <QuarantineEntry>[],
      );
      final events = fixture.file('delete.events');
      final lock = await ProjectOperationLock.acquire(
        workspace: ToolWorkspace(fixture.root),
        operation: 'q5-held-lock',
      );
      addTearDown(lock.release);
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);

      final result = await harness.runQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          'held-lock-run',
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_EVENTS': events.path,
        },
      );

      expect(result.exitCode, 1);
      expect(result.stdoutBytes, isEmpty);
      expect(result.stderrText, contains('mutation is already active'));
      expect(events.existsSync(), isFalse);
      expect(quarantine.existsSync(), isTrue);
    },
  );

  test(
    'reviewed clean retains the project lock across the fake deletion future',
    () async {
      final fixture = CliFixture.create(
        prefix: 'quarantine clean delete lock ',
      );
      addTearDown(fixture.dispose);
      await fixture.writeText(<String, String>{
        'pubspec.yaml': 'name: quarantine_clean_delete_lock\n',
      });
      final quarantine = await QuarantineManager(fixture.root).createQuarantine(
        runId: 'delete-lock-run',
        entries: const <QuarantineEntry>[],
      );
      final executorReady = fixture.file('executor.ready');
      final executorRelease = fixture.file('executor.release');
      final harness = CliProcessHarness.repository();
      addTearDown(harness.close);
      final invocation = await harness.startQuarantineCleanFake(
        [
          'quarantine',
          'clean',
          '--project',
          fixture.root.path,
          'delete-lock-run',
        ],
        environmentAdditions: <String, String>{
          'FLUTTER_PRUNER_TEST_CLEAN_SCENARIO': 'pause_at_boundary',
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY': executorReady.path,
          'FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE': executorRelease.path,
        },
      );
      final completion = invocation.result;
      await _waitForCompleteReadyOrEarlyExit(executorReady, completion);

      await expectLater(
        ProjectOperationLock.acquire(
          workspace: ToolWorkspace(fixture.root),
          operation: 'q5-delete-contender',
        ),
        throwsA(isA<ProjectOperationLockException>()),
      );
      executorRelease.writeAsStringSync('release', flush: true);
      final result = await completion;

      expect(result.exitCode, 0);
      expect(quarantine.existsSync(), isFalse);
      expect(harness.activeInvocationCount, 0);
      final after = await ProjectOperationLock.acquire(
        workspace: ToolWorkspace(fixture.root),
        operation: 'q5-delete-after',
      );
      await after.release();
    },
  );
}

/// A fixture barrier is usable only after its entire sentinel payload exists.
///
/// Race the complete payload against CLI completion so a startup/configuration
/// failure reports its real stdout/stderr instead of becoming an opaque polling
/// timeout under a loaded test suite.
Future<void> _waitForCompleteReadyOrEarlyExit(
  File readyFile,
  Future<CliProcessResult> completion, {
  Duration timeout = const Duration(seconds: 45),
}) async {
  await Future.any<void>(<Future<void>>[
    _waitForExactReadyPayload(readyFile, timeout: timeout),
    completion.then<void>((result) {
      final status = result.timedOut
          ? 'timed out'
          : 'exited ${result.exitCode}';
      throw StateError(
        'CLI $status before complete ready evidence at ${readyFile.path}.\n'
        'stderr:\n${result.stderrText}\n'
        'stdout:\n${result.stdoutText}',
      );
    }),
  ]);
}

Future<void> _waitForExactReadyPayload(
  File readyFile, {
  required Duration timeout,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    if (readyFile.existsSync()) {
      final bytes = await readyFile.readAsBytes();
      final payload = utf8.decode(bytes, allowMalformed: false);
      if (payload == 'ready') return;
    }
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException(
        'Timed out waiting for complete ready evidence at ${readyFile.path}.',
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

Future<int> _waitForPidEvidence(File file) async {
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

Future<PosixProcessTableSnapshot> _waitForProcessIdentities({
  required int rootPid,
  required int childPid,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await const ManagedProcessIdentityInspector().snapshot();
    if (snapshot != null &&
        snapshot.identityFor(rootPid) != null &&
        snapshot.identityFor(childPid) != null) {
      return snapshot;
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException(
    'Timed out waiting for root PID $rootPid and child PID $childPid.',
  );
}

Future<PosixProcessTableSnapshot> _waitForRootIdentity(int rootPid) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (DateTime.now().isBefore(deadline)) {
    final snapshot = await const ManagedProcessIdentityInspector().snapshot();
    if (snapshot?.identityFor(rootPid) != null) return snapshot!;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw TimeoutException('Timed out waiting for root PID $rootPid.');
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

Future<void> _recordUnconfirmedIdentities(
  ToolWorkspace workspace,
  Map<int, PosixProcessIdentity> identities,
) async {
  final root = identities.values.reduce(
    (left, right) => left.pid < right.pid ? left : right,
  );
  final lock = await ProjectOperationLock.acquire(
    workspace: workspace,
    operation: 'uncertainty-fixture',
    identityInspector: const _FixedIdentityInspector.absent(),
  );
  try {
    await lock.guardManagedProcessUncertainty<void>(
      incidentId: 'fixture-${root.pid}',
      phase: 'verificationBaseline',
      body: () async => throw ProcessTerminationUnconfirmedException(
        processId: root.pid,
        message: 'fixture termination was not confirmed',
        triggerSignal: ProcessSignal.sigint,
        observationReliable: true,
        observedProcesses: identities,
      ),
    );
  } on ProcessTerminationUnconfirmedException {
    // Expected fixture outcome; the retained journal is the assertion input.
  } finally {
    await lock.release();
  }
}

final class _FixedIdentityInspector implements ProcessIdentityInspector {
  const _FixedIdentityInspector(this._snapshot);

  const _FixedIdentityInspector.absent()
    : _snapshot = const PosixProcessTableSnapshot.empty();

  const _FixedIdentityInspector.unavailable() : _snapshot = null;

  final PosixProcessTableSnapshot? _snapshot;

  @override
  Future<PosixProcessTableSnapshot?> snapshot() async => _snapshot;
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
