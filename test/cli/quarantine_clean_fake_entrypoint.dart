import 'dart:async';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/quarantine_command.dart';
import 'package:flutter_pruner/src/cli/confirmation_prompt.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_clean_executor.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';

Future<void> main(List<String> arguments) async {
  final environment = Platform.environment;
  final prompt = _FixtureConfirmationPrompt(
    interactive: environment['FLUTTER_PRUNER_TEST_CLEAN_TTY'] == '1',
    readyFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PROMPT_READY'],
    ),
    releaseFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PROMPT_RELEASE'],
    ),
  );
  final executor = _FixtureCleanExecutor(
    scenario: environment['FLUTTER_PRUNER_TEST_CLEAN_SCENARIO'] ?? 'success',
    failRunId: environment['FLUTTER_PRUNER_TEST_CLEAN_FAIL_RUN_ID'],
    eventsFile: _optionalFile(environment['FLUTTER_PRUNER_TEST_CLEAN_EVENTS']),
    readyFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_READY'],
    ),
    releaseFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_EXECUTOR_RELEASE'],
    ),
  );
  final cleanPlanHook = _FixtureCleanPlanHook(
    pauseCall: _optionalPositiveInt(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PLAN_PAUSE_CALL'],
    ),
    throwCall: _optionalPositiveInt(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_CALL'],
    ),
    throwKind: environment['FLUTTER_PRUNER_TEST_CLEAN_PLAN_THROW_KIND'],
    readyFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PLAN_READY'],
    ),
    releaseFile: _optionalFile(
      environment['FLUTTER_PRUNER_TEST_CLEAN_PLAN_RELEASE'],
    ),
  );
  final runner = FlutterPrunerCommandRunner(
    quarantineCommandFactory: () => QuarantineCommand(
      managerFactory: (projectRoot) => QuarantineManager(
        projectRoot,
        cleanPlanSnapshotHook: cleanPlanHook.onSnapshot,
      ),
      cleanExecutor: executor,
      confirmationPrompt: prompt,
    ),
  );
  exitCode = await runner.run(arguments);
}

File? _optionalFile(String? path) =>
    path == null || path.isEmpty ? null : File(path);

int? _optionalPositiveInt(String? value) {
  if (value == null || value.isEmpty) return null;
  final parsed = int.tryParse(value);
  if (parsed == null || parsed < 1) {
    throw FormatException('Expected a positive fixture call number.', value);
  }
  return parsed;
}

final class _FixtureCleanPlanHook {
  _FixtureCleanPlanHook({
    required this.pauseCall,
    required this.throwCall,
    required this.throwKind,
    required this.readyFile,
    required this.releaseFile,
  });

  final int? pauseCall;
  final int? throwCall;
  final String? throwKind;
  final File? readyFile;
  final File? releaseFile;
  var _call = 0;

  Future<void> onSnapshot(QuarantineCleanPlanSnapshotPoint point) async {
    _call++;
    if (_call == throwCall) {
      switch (throwKind) {
        case 'state_error':
          throw StateError('Injected clean-plan programmer error.');
        case 'format_exception':
          throw const FormatException('Injected clean-plan exception.');
        default:
          throw StateError('Unknown clean-plan throw fixture: $throwKind');
      }
    }
    if (_call == pauseCall) {
      readyFile?.writeAsStringSync('ready', flush: true);
      await _waitForRelease(releaseFile);
    }
  }
}

final class _FixtureConfirmationPrompt implements ConfirmationPrompt {
  const _FixtureConfirmationPrompt({
    required this.interactive,
    required this.readyFile,
    required this.releaseFile,
  });

  final bool interactive;
  final File? readyFile;
  final File? releaseFile;

  @override
  bool get isInteractive => interactive;

  @override
  Future<String?> readLine(String message) async {
    stdout.write(message);
    readyFile?.writeAsStringSync('ready', flush: true);
    await _waitForRelease(releaseFile);
    return stdin.readLineSync();
  }
}

final class _FixtureCleanExecutor implements QuarantineCleanExecutor {
  _FixtureCleanExecutor({
    required this.scenario,
    required this.failRunId,
    required this.eventsFile,
    required this.readyFile,
    required this.releaseFile,
  });

  final String scenario;
  final String? failRunId;
  final File? eventsFile;
  final File? readyFile;
  final File? releaseFile;
  var _attempt = 0;

  @override
  Future<void> delete(QuarantineCleanDeleteRequest request) async {
    _attempt++;
    _record('boundary:${request.runId}');
    if (scenario == 'pause_at_boundary') {
      readyFile?.writeAsStringSync('ready', flush: true);
      await _waitForRelease(releaseFile);
    }
    final mustFail = failRunId == null || failRunId == request.runId;
    if (scenario == 'throw' && mustFail) {
      throw FileSystemException(
        'Injected delete failure.',
        request.canonicalPath,
      );
    }
    if (scenario == 'mutate_then_throw' && mustFail) {
      final target = Directory(request.canonicalPath);
      final children = target.listSync(followLinks: false);
      if (children.isNotEmpty) {
        final child = children.first;
        if (child is File) {
          child.deleteSync();
        } else if (child is Directory) {
          child.deleteSync(recursive: true);
        }
      }
      throw FileSystemException(
        'Injected failure after fixture mutation.',
        request.canonicalPath,
      );
    }

    await Directory(request.canonicalPath).delete(recursive: true);
    _record('removed:${request.runId}');
    if (scenario == 'pause_after_first' && _attempt == 1) {
      readyFile?.writeAsStringSync('ready', flush: true);
      await _waitForRelease(releaseFile);
    }
  }

  void _record(String event) {
    eventsFile?.writeAsStringSync(
      '$event\n',
      mode: FileMode.append,
      flush: true,
    );
  }
}

Future<void> _waitForRelease(File? releaseFile) async {
  if (releaseFile == null) return;
  while (!releaseFile.existsSync()) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
