import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/analyzer_diagnostic_collector.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProjectContext project;

  setUp(() async {
    root = await Directory.systemTemp.createTemp(
      'analyzer_diagnostic_collector_',
    );
    addTearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: analyzer_diagnostic_collector_test
environment:
  sdk: ^3.9.0
''');
    final packageConfig = File(
      p.join(root.path, '.dart_tool', 'package_config.json'),
    );
    packageConfig.parent.createSync(recursive: true);
    packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "analyzer_diagnostic_collector_test",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
    final mainFile = File(p.join(root.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('void unusedFunction() {}\n');
    project = ProjectContext(
      root: root,
      pubspec: const <String, Object?>{
        'name': 'analyzer_diagnostic_collector_test',
      },
      packageName: 'analyzer_diagnostic_collector_test',
      targets: <BuildTarget>[
        BuildTarget(name: 'vm', platform: 'vm', entrypoint: 'lib/main.dart'),
      ],
    );
  });

  test('skips launch when analysis_options.yaml is absent', () async {
    final runner = _RecordingProcessRunner();

    final result = await AnalyzerDiagnosticCollector(
      processRunner: runner,
    ).collect(project);

    expect(result.attempted, isFalse);
    expect(result.available, isTrue);
    expect(runner.invocations, 0);
  });

  test(
    'uses bounded managed execution and parses analyzer machine output',
    () async {
      File(
        p.join(root.path, 'analysis_options.yaml'),
      ).writeAsStringSync('{}\n');
      final source = File(p.join(root.path, 'lib', 'main.dart'));
      final runner = _RecordingProcessRunner(
        result: _managedResult(
          stdout:
              'INFO|LINT|UNUSED_ELEMENT|${source.path}|1|1|4|Unused element\n',
        ),
      );

      final result = await AnalyzerDiagnosticCollector(
        processRunner: runner,
        maxOutputBytesPerStream: 1234,
      ).collect(project);

      expect(result.available, isTrue);
      expect(result.diagnostics, hasLength(1));
      expect(result.diagnostics.single.code, 'unused_element');
      expect(runner.invocations, 1);
      expect(runner.executable, isNotEmpty);
      expect(runner.arguments, ['analyze', '--format=machine', root.path]);
      expect(runner.workingDirectory, root.path);
      expect(runner.timeout, AnalyzerDiagnosticCollector.timeout);
      expect(runner.maxOutputBytesPerStream, 1234);
    },
  );

  test('fails closed when managed analyzer output is truncated', () async {
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync('{}\n');
    final runner = _RecordingProcessRunner(
      result: ManagedProcessResult(
        exitCode: 0,
        stdout: const BoundedProcessOutput(
          text: 'partial analyzer output',
          capturedBytes: 23,
          omittedBytes: 7,
        ),
        stderr: _emptyOutput,
      ),
    );

    final result = await AnalyzerDiagnosticCollector(
      processRunner: runner,
    ).collect(project);

    expect(result.available, isFalse);
    expect(result.failure, contains('output exceeded'));
  });

  test('maps a confirmed managed timeout to unavailable', () async {
    File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync('{}\n');
    final runner = _RecordingProcessRunner(
      result: _managedResult(timedOut: true, exitCode: -1),
    );

    final result = await AnalyzerDiagnosticCollector(
      processRunner: runner,
    ).collect(project);

    expect(result.available, isFalse);
    expect(result.failure, contains('timed out'));
  });

  for (final error in <Exception>[
    const ProcessCancellationBeforeLaunchException(ProcessSignal.sigint),
    const ProcessCancellationConfirmedException(ProcessSignal.sigterm, 4101),
    const ProcessTerminationUnconfirmedException(
      processId: 4102,
      message: 'analyzer tree may still be alive',
      triggerSignal: ProcessSignal.sigint,
    ),
  ]) {
    test('preserves typed managed failure ${error.runtimeType}', () async {
      File(
        p.join(root.path, 'analysis_options.yaml'),
      ).writeAsStringSync('{}\n');
      final runner = _RecordingProcessRunner(error: error);

      await expectLater(
        AnalyzerDiagnosticCollector(processRunner: runner).collect(project),
        throwsA(same(error)),
      );
    });
  }
}

const _emptyOutput = BoundedProcessOutput(
  text: '',
  capturedBytes: 0,
  omittedBytes: 0,
);

ManagedProcessResult _managedResult({
  String stdout = '',
  String stderr = '',
  int exitCode = 0,
  bool timedOut = false,
}) => ManagedProcessResult(
  exitCode: exitCode,
  stdout: BoundedProcessOutput(
    text: stdout,
    capturedBytes: stdout.length,
    omittedBytes: 0,
  ),
  stderr: BoundedProcessOutput(
    text: stderr,
    capturedBytes: stderr.length,
    omittedBytes: 0,
  ),
  timedOut: timedOut,
);

final class _RecordingProcessRunner implements ProcessExecutionRunner {
  _RecordingProcessRunner({
    this.result = const ManagedProcessResult(
      exitCode: 0,
      stdout: _emptyOutput,
      stderr: _emptyOutput,
    ),
    this.error,
  });

  final ManagedProcessResult result;
  final Exception? error;
  var invocations = 0;
  String executable = '';
  List<String> arguments = const [];
  String workingDirectory = '';
  Duration timeout = Duration.zero;
  int maxOutputBytesPerStream = -1;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    invocations++;
    this.executable = executable;
    this.arguments = List.unmodifiable(arguments);
    this.workingDirectory = workingDirectory;
    this.timeout = timeout;
    this.maxOutputBytesPerStream = maxOutputBytesPerStream;
    if (error case final error?) throw error;
    return result;
  }
}
