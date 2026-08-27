import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/cli_signal_coordinator.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'cli_process_harness.dart';

void main() {
  test(
    'one active clearer is replaced, cleared, and disposed with guard',
    () async {
      final signals = _FakeSignalStreams();
      final redelivered = <ProcessSignal>[];
      final coordinator = PosixCliSignalCoordinator(
        signalStream: signals.watch,
        redeliver: redelivered.add,
      );
      final bodyRelease = Completer<void>();
      var firstClears = 0;
      var replacementClears = 0;

      final guarded = coordinator.guard(() async {
        coordinator.setActiveLineClearer(() => firstClears++);
        coordinator.setActiveLineClearer(() => replacementClears++);
        await bodyRelease.future;
      });
      await signals.subscribed;

      signals.send(ProcessSignal.sigterm);
      await signals.delivered;

      expect(firstClears, 0);
      expect(replacementClears, 1);
      expect(redelivered, [ProcessSignal.sigterm]);
      bodyRelease.complete();
      await guarded;

      signals.send(ProcessSignal.sigint);
      await Future<void>.delayed(Duration.zero);
      expect(replacementClears, 1);
      expect(redelivered, [ProcessSignal.sigterm]);
      await signals.close();
    },
  );

  test(
    'first signal coordinates pending launch and second hard-stops',
    () async {
      final signals = _FakeSignalStreams();
      final redelivered = <ProcessSignal>[];
      final coordinator = PosixCliSignalCoordinator(
        signalStream: signals.watch,
        redeliver: redelivered.add,
      );
      final launchEntered = Completer<void>();
      final releaseLaunch = Completer<void>();

      final guarded = coordinator.guard(() async {
        final runner = ManagedProcessRunner(
          cancellationController: coordinator.processCancellation,
          processStarter:
              (executable, arguments, {required workingDirectory}) async {
                launchEntered.complete();
                await releaseLaunch.future;
                throw const ProcessException('fixture', <String>[]);
              },
        );
        await runner.run(
          Platform.resolvedExecutable,
          const ['--version'],
          workingDirectory: Directory.current.path,
          timeout: const Duration(seconds: 5),
          maxOutputBytesPerStream: 1024,
        );
      });
      await signals.subscribed;
      await launchEntered.future;
      expect(coordinator.processCancellation.pendingOrActiveTreeCount, 1);

      signals.send(ProcessSignal.sigint);
      await signals.delivered;
      expect(coordinator.processCancellation.isRequested, isTrue);
      expect(redelivered, isEmpty);

      signals.resetDelivery();
      signals.send(ProcessSignal.sigterm);
      await signals.delivered;
      expect(redelivered, [ProcessSignal.sigterm]);

      releaseLaunch.complete();
      await expectLater(
        guarded,
        throwsA(
          isA<ProcessCancellationBeforeLaunchException>().having(
            (error) => error.originalSignal,
            'originalSignal',
            ProcessSignal.sigint,
          ),
        ),
      );
      expect(coordinator.processCancellation.pendingOrActiveTreeCount, 0);
      await signals.close();
    },
  );

  test(
    'no-op coordinator does not install a platform signal contract',
    () async {
      final coordinator = NoopCliSignalCoordinator();
      var clearerCalled = false;
      coordinator.setActiveLineClearer(() => clearerCalled = true);

      final value = await coordinator.guard(() async => 42);

      expect(value, 42);
      expect(clearerCalled, isFalse);
      expect(coordinator.processCancellation.isRequested, isFalse);
    },
  );

  test('command runner guards every invocation with one coordinator', () async {
    final coordinator = _GuardCountingCoordinator();
    final runner = FlutterPrunerCommandRunner(signalCoordinator: coordinator);

    expect(await runner.run(const ['--version']), 0);
    expect(await runner.run(const ['--version']), 0);

    expect(coordinator.guardCalls, 2);
  });

  test(
    'scan analysis-options collector coordinates its real root and descendant',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'terminal_signal_analyzer_scan_',
      );
      final fixture = Directory.systemTemp.createTempSync(
        'terminal_signal_analyzer_tree_',
      );
      final ready = File(p.join(fixture.path, 'ready.json'));
      final childPidFile = File(p.join(fixture.path, 'child.pid'));
      final rootSurvived = File(p.join(fixture.path, 'root-survived'));
      final childSurvived = File(p.join(fixture.path, 'child-survived'));
      final report = File(p.join(project.path, 'interrupted.json'));
      final scripts = _writeAnalyzerTreeScripts(
        fixture,
        ready: ready,
        childPidFile: childPidFile,
        rootSurvived: rootSurvived,
        childSurvived: childSurvived,
      );
      _writeAnalyzerSignalProject(project);
      final signals = _FakeSignalStreams();
      final coordinator = PosixCliSignalCoordinator(
        signalStream: signals.watch,
        redeliver: (_) {
          throw StateError(
            'Analyzer launch must keep the signal in coordinated mode.',
          );
        },
      );
      String? requestedExecutable;
      List<String>? requestedArguments;
      final runner = FlutterPrunerCommandRunner(
        signalCoordinator: coordinator,
        analyzerProcessStarter:
            (executable, arguments, {required workingDirectory}) {
              requestedExecutable = executable;
              requestedArguments = List.unmodifiable(arguments);
              return Process.start(Platform.resolvedExecutable, [
                scripts.root.path,
                scripts.child.path,
                childPidFile.path,
                childSurvived.path,
                ready.path,
                rootSurvived.path,
              ], workingDirectory: workingDirectory);
            },
      );
      final completion = runner.run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        report.path,
        project.path,
      ]);
      Map<String, Object?>? pids;
      try {
        await signals.subscribed;
        pids = await _waitForAnalyzerReadyOrCommandExit(ready, completion);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        signals.send(ProcessSignal.sigint);
        await signals.delivered;
        final exitCode = await completion;

        expect(exitCode, conventionalSignalExitCode(ProcessSignal.sigint));
        expect(requestedExecutable, isNotEmpty);
        expect(requestedArguments, [
          'analyze',
          '--format=machine',
          project.path,
        ]);
        expect(report.existsSync(), isTrue);
        final saved = jsonDecode(report.readAsStringSync()) as Map;
        expect((saved['run'] as Map)['status'], 'interrupted');
        expect(await _waitForPidToDisappear(pids['rootPid']! as int), isTrue);
        expect(await _waitForPidToDisappear(pids['childPid']! as int), isTrue);
        expect(rootSurvived.existsSync(), isFalse);
        expect(childSurvived.existsSync(), isFalse);
      } finally {
        if (pids != null) {
          Process.killPid(pids['rootPid']! as int, ProcessSignal.sigkill);
          Process.killPid(pids['childPid']! as int, ProcessSignal.sigkill);
        }
        await signals.close();
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'apply analysis-options collector coordinates its real root and descendant',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'terminal_signal_analyzer_apply_',
      );
      final fixture = Directory.systemTemp.createTempSync(
        'terminal_signal_apply_analyzer_tree_',
      );
      final ready = File(p.join(fixture.path, 'ready.json'));
      final childPidFile = File(p.join(fixture.path, 'child.pid'));
      final rootSurvived = File(p.join(fixture.path, 'root-survived'));
      final childSurvived = File(p.join(fixture.path, 'child-survived'));
      final report = File(p.join(project.path, 'interrupted.json'));
      final scripts = _writeAnalyzerTreeScripts(
        fixture,
        ready: ready,
        childPidFile: childPidFile,
        rootSurvived: rootSurvived,
        childSurvived: childSurvived,
      );
      _writeAnalyzerSignalProject(project);
      final signals = _FakeSignalStreams();
      final coordinator = PosixCliSignalCoordinator(
        signalStream: signals.watch,
        redeliver: (_) {
          throw StateError(
            'Analyzer launch must keep the signal in coordinated mode.',
          );
        },
      );
      final runner = FlutterPrunerCommandRunner(
        signalCoordinator: coordinator,
        analyzerProcessStarter:
            (executable, arguments, {required workingDirectory}) =>
                Process.start(Platform.resolvedExecutable, [
                  scripts.root.path,
                  scripts.child.path,
                  childPidFile.path,
                  childSurvived.path,
                  ready.path,
                  rootSurvived.path,
                ], workingDirectory: workingDirectory),
      );
      final completion = runner.run([
        'apply',
        '--dry-run',
        '--yes',
        '--adapter',
        'dart',
        '--report-format',
        'json',
        '--report-output',
        report.path,
        project.path,
      ]);
      Map<String, Object?>? pids;
      try {
        await signals.subscribed;
        pids = await _waitForAnalyzerReadyOrCommandExit(ready, completion);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        signals.send(ProcessSignal.sigterm);
        await signals.delivered;
        final exitCode = await completion;

        expect(exitCode, conventionalSignalExitCode(ProcessSignal.sigterm));
        expect(report.existsSync(), isTrue);
        final saved = jsonDecode(report.readAsStringSync()) as Map;
        expect((saved['run'] as Map)['status'], 'interrupted');
        expect(await _waitForPidToDisappear(pids['rootPid']! as int), isTrue);
        expect(await _waitForPidToDisappear(pids['childPid']! as int), isTrue);
        expect(rootSurvived.existsSync(), isFalse);
        expect(childSurvived.existsSync(), isFalse);
      } finally {
        if (pids != null) {
          Process.killPid(pids['rootPid']! as int, ProcessSignal.sigkill);
          Process.killPid(pids['childPid']! as int, ProcessSignal.sigkill);
        }
        await signals.close();
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'unconfirmed scan analyzer tree retains exact authority until absent',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'terminal_signal_analyzer_unconfirmed_',
      );
      final fixture = Directory.systemTemp.createTempSync(
        'terminal_signal_unconfirmed_tree_',
      );
      final ready = File(p.join(fixture.path, 'ready.json'));
      final childPidFile = File(p.join(fixture.path, 'child.pid'));
      final rootSurvived = File(p.join(fixture.path, 'root-survived'));
      final childSurvived = File(p.join(fixture.path, 'child-survived'));
      final report = File(p.join(project.path, 'unconfirmed.json'));
      final scripts = _writeAnalyzerTreeScripts(
        fixture,
        ready: ready,
        childPidFile: childPidFile,
        rootSurvived: rootSurvived,
        childSurvived: childSurvived,
      );
      _writeAnalyzerSignalProject(project);
      final signals = _FakeSignalStreams();
      final coordinator = PosixCliSignalCoordinator(
        signalStream: signals.watch,
        redeliver: (_) {
          throw StateError(
            'Analyzer launch must keep the signal in coordinated mode.',
          );
        },
      );
      final runner = FlutterPrunerCommandRunner(
        signalCoordinator: coordinator,
        analyzerProcessStarter:
            (executable, arguments, {required workingDirectory}) =>
                Process.start(Platform.resolvedExecutable, [
                  scripts.root.path,
                  scripts.child.path,
                  childPidFile.path,
                  childSurvived.path,
                  ready.path,
                  rootSurvived.path,
                ], workingDirectory: workingDirectory),
        analyzerProcessTreeTerminator:
            (
              process,
              exitCode, {
              required observedProcesses,
              required observationReliable,
            }) async => ManagedProcessTerminationEvidence(
              terminationConfirmed: false,
              observedProcesses: observedProcesses,
              observationReliable: observationReliable,
            ),
      );
      final completion = runner.run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        report.path,
        project.path,
      ]);
      Map<String, Object?>? pids;
      try {
        await signals.subscribed;
        pids = await _waitForAnalyzerReadyOrCommandExit(ready, completion);
        await Future<void>.delayed(const Duration(milliseconds: 250));

        signals.send(ProcessSignal.sigterm);
        await signals.delivered;
        expect(await completion, 1);

        final saved = jsonDecode(report.readAsStringSync()) as Map;
        expect((saved['run'] as Map)['status'], 'infrastructureFailure');
        expect(
          ((saved['diagnostics'] as List).single as Map)['code'],
          'process_termination_unconfirmed',
        );
        final journal = File(
          p.join(project.path, '.flutter_pruner', 'operation.lock'),
        ).readAsStringSync();
        expect(journal, contains('"state":"unconfirmed"'));
        expect(journal, contains('"pid":${pids['rootPid']}'));
        expect(journal, contains('"pid":${pids['childPid']}'));

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

        Process.killPid(pids['rootPid']! as int, ProcessSignal.sigkill);
        Process.killPid(pids['childPid']! as int, ProcessSignal.sigkill);
        expect(await _waitForPidToDisappear(pids['rootPid']! as int), isTrue);
        expect(await _waitForPidToDisappear(pids['childPid']! as int), isTrue);
        expect(
          await FlutterPrunerCommandRunner().run([
            'scan',
            '--adapter',
            'duplicates',
            '--project',
            project.path,
          ]),
          0,
        );
      } finally {
        if (pids != null) {
          Process.killPid(pids['rootPid']! as int, ProcessSignal.sigkill);
          Process.killPid(pids['childPid']! as int, ProcessSignal.sigkill);
        }
        await signals.close();
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'POSIX no-child signal clears the animated line before default exit',
    () async {
      final fixture = Directory.systemTemp.createTempSync(
        'terminal_signal_no_child_',
      );
      final ready = File(p.join(fixture.path, 'ready'));
      final entrypoint = File(p.join(fixture.path, 'entrypoint.dart'));
      entrypoint.writeAsStringSync(r'''
import 'dart:async';
import 'dart:io';

import 'package:flutter_pruner/src/cli/cli_signal_coordinator.dart';
import 'package:flutter_pruner/src/cli/terminal_progress.dart';

Future<void> main(List<String> arguments) async {
  final coordinator = PosixCliSignalCoordinator();
  await coordinator.guard(() async {
    TerminalProgress(
      sink: stderr,
      animated: true,
      signalCoordinator: coordinator,
    ).start('no-child fixture');
    File(arguments.single).writeAsStringSync('$pid');
    await Completer<void>().future;
  });
}
''');
      final harness = CliProcessHarness.repository(
        defaultTimeout: const Duration(seconds: 15),
      );
      final fixtureCommand = <String>[
        Platform.resolvedExecutable,
        '--packages=${p.join(harness.repositoryRoot.path, '.dart_tool', 'package_config.json')}',
        entrypoint.path,
        ready.path,
      ];
      try {
        final invocation = await harness.start([
          ready.path,
        ], entrypointOverride: entrypoint);
        final completion = invocation.result;
        final processId = await _waitForPidReadyOrEarlyExit(
          ready,
          completion,
          fixtureCommand: fixtureCommand,
        );

        Process.killPid(processId, ProcessSignal.sigint);
        final result = await completion;

        expect(
          result.exitCode,
          anyOf(
            -ProcessSignal.sigint.signalNumber,
            conventionalSignalExitCode(ProcessSignal.sigint),
          ),
        );
        expect(result.stderrText, contains('\r\x1B[2K\n'));
        expect(result.stderrText, endsWith('\n'));
        expect(result.stderrText, isNot(contains('✓')));
      } finally {
        await harness.close();
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
  );

  test(
    'real apply baseline SIGTERM confirms its managed tree before exit 143',
    () async {
      final project = Directory.systemTemp.createTempSync(
        'terminal_signal_apply_',
      );
      final fixture = Directory.systemTemp.createTempSync(
        'terminal_signal_process_fixture_',
      );
      final ready = File(p.join(fixture.path, 'ready.json'));
      final childPidFile = File(p.join(fixture.path, 'child.pid'));
      final rootSurvived = File(p.join(fixture.path, 'root-survived'));
      final childSurvived = File(p.join(fixture.path, 'child-survived'));
      final report = File(p.join(project.path, 'interrupted.json'));
      final childScript = File(p.join(fixture.path, 'child.dart'));
      final rootScript = File(p.join(fixture.path, 'root.dart'));
      childScript.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid');
  await Future<void>.delayed(const Duration(seconds: 5));
  File(arguments[1]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      rootScript.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[1], arguments[2]],
  );
  final childPid = File(arguments[1]);
  while (!childPid.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final parent = Process.runSync('ps', ['-o', 'ppid=', '-p', '$pid']);
  if (parent.exitCode != 0) {
    throw StateError('could not resolve CLI parent PID: ${parent.stderr}');
  }
  File(arguments[3]).writeAsStringSync(jsonEncode({
    'cliPid': int.parse((parent.stdout as String).trim()),
    'rootPid': pid,
    'childPid': int.parse(childPid.readAsStringSync()),
  }));
  await Future<void>.delayed(const Duration(seconds: 5));
  File(arguments[4]).writeAsStringSync('survived');
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
      _writeSignalApplyProject(
        project,
        rootScript: rootScript,
        childScript: childScript,
        ready: ready,
        childPid: childPidFile,
        childSurvived: childSurvived,
        rootSurvived: rootSurvived,
      );
      final harness = CliProcessHarness.repository(
        defaultTimeout: const Duration(seconds: 60),
      );
      try {
        final invocation = await harness.start(
          [
            'apply',
            '--adapter',
            'dart',
            '--yes',
            '--report-format',
            'json',
            '--report-output',
            report.path,
            project.path,
          ],
          workingDirectory: project,
          timeout: const Duration(seconds: 60),
        );
        final completion = invocation.result;
        await _waitForReadyOrEarlyExit(
          ready,
          completion,
          timeout: const Duration(seconds: 45),
        );
        final pids = jsonDecode(ready.readAsStringSync()) as Map;

        Process.killPid(pids['cliPid'] as int, ProcessSignal.sigterm);
        final result = await completion;

        expect(result.exitCode, 143);
        expect(report.existsSync(), isTrue);
        final saved = jsonDecode(report.readAsStringSync()) as Map;
        expect((saved['run'] as Map)['status'], 'interrupted');
        expect((saved['run'] as Map)['exitCode'], 143);
        expect(
          Directory(
            p.join(project.path, '.flutter_pruner', 'quarantine'),
          ).existsSync(),
          isFalse,
        );
        await Future<void>.delayed(const Duration(seconds: 5));
        expect(rootSurvived.existsSync(), isFalse);
        expect(childSurvived.existsSync(), isFalse);

        final second = await harness.run([
          'apply',
          '--adapter',
          'dart',
          '--yes',
          '--dry-run',
          '--report-output',
          p.join(project.path, 'second.html'),
          project.path,
        ], workingDirectory: project);
        expect(second.exitCode, 0);
      } finally {
        await harness.close();
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (fixture.existsSync()) fixture.deleteSync(recursive: true);
      }
    },
    skip: !(Platform.isLinux || Platform.isMacOS),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Future<int> _waitForPidReadyOrEarlyExit(
  File ready,
  Future<CliProcessResult> completion, {
  required List<String> fixtureCommand,
  Duration timeout = const Duration(seconds: 15),
}) {
  final renderedCommand = fixtureCommand.map(jsonEncode).join(' ');
  return Future.any<int>([
    () async {
      final deadline = DateTime.now().add(timeout);
      Object? lastParseFailure;
      while (DateTime.now().isBefore(deadline)) {
        if (ready.existsSync()) {
          try {
            final processId = int.parse(ready.readAsStringSync().trim());
            if (processId > 0) return processId;
            lastParseFailure = StateError(
              'ready PID must be positive, got $processId',
            );
          } on Object catch (error) {
            lastParseFailure = error;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      throw TimeoutException(
        'Fixture did not publish a parseable PID within '
        '${timeout.inSeconds}s: command=$renderedCommand, '
        'ready=${_describeReadyFile(ready)}, '
        'lastParseFailure=$lastParseFailure',
      );
    }(),
    completion.then<int>((result) {
      throw StateError(
        'Fixture exited before publishing a parseable PID: '
        'command=$renderedCommand, processId=${result.processId}, '
        'exitCode=${result.exitCode}, timedOut=${result.timedOut}, '
        'stdout=${jsonEncode(result.stdoutText)}, '
        'stderr=${jsonEncode(result.stderrText)}, '
        'ready=${_describeReadyFile(ready)}',
      );
    }),
  ]);
}

String _describeReadyFile(File ready) {
  if (!ready.existsSync()) return '${ready.path} (missing)';
  try {
    return '${ready.path} (${jsonEncode(ready.readAsStringSync())})';
  } on FileSystemException catch (error) {
    return '${ready.path} (unreadable: $error)';
  }
}

Future<void> _waitForReadyOrEarlyExit(
  File ready,
  Future<CliProcessResult> completion, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  await Future.any<void>([
    () async {
      final deadline = DateTime.now().add(timeout);
      while (!ready.existsSync()) {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException('Fixture did not create ${ready.path}.');
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }(),
    completion.then<void>((result) {
      throw StateError(
        'CLI exited ${result.exitCode} before ready: '
        '${result.stderrText}${result.stdoutText}',
      );
    }),
  ]);
}

void _writeSignalApplyProject(
  Directory project, {
  required File rootScript,
  required File childScript,
  required File ready,
  required File childPid,
  required File childSurvived,
  required File rootSurvived,
}) {
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: terminal_signal_apply
publish_to: none
environment:
  sdk: ^3.9.0
''');
  final packageConfig = File(
    p.join(project.path, '.dart_tool', 'package_config.json'),
  );
  packageConfig.parent.createSync(recursive: true);
  packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "terminal_signal_apply",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
  final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
  mainFile.parent.createSync(recursive: true);
  mainFile.writeAsStringSync('''
import 'src/helper.dart';

void main() {
  usedFunction();
}
''');
  final helper = File(p.join(project.path, 'lib', 'src', 'helper.dart'));
  helper.parent.createSync(recursive: true);
  helper.writeAsStringSync('''
void usedFunction() {}

void unusedFunction() {}
''');
  File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: package-internal
  public_entrypoints:
    - lib/main.dart
target_matrix:
  complete: true
  targets:
    - name: vm
      platform: android
      entrypoint: lib/main.dart
verification:
  steps:
    - id: signal-fixture
      argv:
        - ${jsonEncode(Platform.resolvedExecutable)}
        - ${jsonEncode(rootScript.path)}
        - ${jsonEncode(childScript.path)}
        - ${jsonEncode(childPid.path)}
        - ${jsonEncode(childSurvived.path)}
        - ${jsonEncode(ready.path)}
        - ${jsonEncode(rootSurvived.path)}
''');
}

({File root, File child}) _writeAnalyzerTreeScripts(
  Directory fixture, {
  required File ready,
  required File childPidFile,
  required File rootSurvived,
  required File childSurvived,
}) {
  final child = File(p.join(fixture.path, 'analyzer_child.dart'));
  final root = File(p.join(fixture.path, 'analyzer_root.dart'));
  child.writeAsStringSync(r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  File(arguments[0]).writeAsStringSync('$pid', flush: true);
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[1]).writeAsStringSync('survived', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
  root.writeAsStringSync(r'''
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> arguments) async {
  await Process.start(
    Platform.resolvedExecutable,
    [arguments[0], arguments[1], arguments[2]],
  );
  final childPid = File(arguments[1]);
  while (!childPid.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  File(arguments[3]).writeAsStringSync(jsonEncode({
    'rootPid': pid,
    'childPid': int.parse(childPid.readAsStringSync()),
  }), flush: true);
  await Future<void>.delayed(const Duration(seconds: 3));
  File(arguments[4]).writeAsStringSync('survived', flush: true);
  await Future<void>.delayed(const Duration(minutes: 1));
}
''');
  return (root: root, child: child);
}

void _writeAnalyzerSignalProject(Directory project) {
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: terminal_signal_analyzer
publish_to: none
environment:
  sdk: ^3.9.0
''');
  final packageConfig = File(
    p.join(project.path, '.dart_tool', 'package_config.json'),
  );
  packageConfig.parent.createSync(recursive: true);
  packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "terminal_signal_analyzer",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
  final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
  mainFile.parent.createSync(recursive: true);
  mainFile.writeAsStringSync('void main() {}\n');
  File(p.join(project.path, 'analysis_options.yaml')).writeAsStringSync('{}\n');
  File(p.join(project.path, '.flutter_pruner', 'config.yaml'))
    ..parent.createSync(recursive: true)
    ..writeAsStringSync('''
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
}

Future<Map<String, Object?>> _waitForAnalyzerReadyOrCommandExit(
  File ready,
  Future<int> completion, {
  Duration timeout = const Duration(seconds: 45),
}) => Future.any<Map<String, Object?>>([
  () async {
    final deadline = DateTime.now().add(timeout);
    Object? lastFailure;
    while (DateTime.now().isBefore(deadline)) {
      if (ready.existsSync()) {
        try {
          final decoded = jsonDecode(ready.readAsStringSync());
          if (decoded case <String, Object?>{
            'rootPid': final int rootPid,
            'childPid': final int childPid,
          } when rootPid > 0 && childPid > 0) {
            return decoded;
          }
          lastFailure = StateError('ready payload lacks positive PIDs');
        } on Object catch (error) {
          lastFailure = error;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException(
      'Analyzer fixture did not publish complete PID evidence at '
      '${ready.path}: $lastFailure',
    );
  }(),
  completion.then<Map<String, Object?>>((exitCode) {
    throw StateError(
      'Command exited $exitCode before analyzer fixture readiness at '
      '${ready.path}.',
    );
  }),
]);

Future<bool> _waitForPidToDisappear(int processId) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (DateTime.now().isBefore(deadline)) {
    final result = await Process.run('/bin/ps', [
      '-p',
      '$processId',
      '-o',
      'pid=',
    ]);
    if (result.exitCode != 0 || (result.stdout as String).trim().isEmpty) {
      return true;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  return false;
}

final class _GuardCountingCoordinator implements CliSignalCoordinator {
  @override
  final ManagedProcessCancellationController processCancellation =
      ManagedProcessCancellationController();

  var guardCalls = 0;

  @override
  Future<T> guard<T>(Future<T> Function() body) {
    guardCalls++;
    return body();
  }

  @override
  void setActiveLineClearer(void Function()? clearer) {}
}

final class _FakeSignalStreams {
  final Map<ProcessSignal, StreamController<ProcessSignal>> _controllers = {
    ProcessSignal.sigint: StreamController<ProcessSignal>.broadcast(),
    ProcessSignal.sigterm: StreamController<ProcessSignal>.broadcast(),
  };
  final Completer<void> _subscribed = Completer<void>();
  Completer<void> _delivered = Completer<void>();
  var _watchCalls = 0;

  Future<void> get subscribed => _subscribed.future;

  Future<void> get delivered => _delivered.future;

  Stream<ProcessSignal> watch(ProcessSignal signal) {
    _watchCalls++;
    if (!_subscribed.isCompleted && _watchCalls == _controllers.length) {
      _subscribed.complete();
    }
    return _controllers[signal]!.stream.transform(
      StreamTransformer<ProcessSignal, ProcessSignal>.fromHandlers(
        handleData: (value, sink) {
          sink.add(value);
          if (!_delivered.isCompleted) _delivered.complete();
        },
      ),
    );
  }

  void send(ProcessSignal signal) {
    _controllers[signal]!.add(signal);
  }

  void resetDelivery() {
    _delivered = Completer<void>();
  }

  Future<void> close() async {
    for (final controller in _controllers.values) {
      await controller.close();
    }
  }
}
