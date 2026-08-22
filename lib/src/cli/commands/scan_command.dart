import 'dart:io';

import 'package:args/command_runner.dart';

import '../../analysis/analysis_snapshot.dart';
import '../../analysis/project_analyzer.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import '../../core/project/tool_workspace.dart';
import '../../reporting/immutable_report_store.dart';
import '../../reporting/io_report_object_backend.dart';
import '../../reporting/report_object_backend.dart';
import '../../reporting/report_output_identity.dart';
import '../../reporting/run_recorder.dart';
import '../../reporting/run_report.dart';
import '../../version.dart';
import '../formatters/html_formatter.dart';
import '../formatters/human_formatter.dart';
import '../formatters/json_formatter.dart';
import '../formatters/report_formatter.dart';
import '../project_command_support.dart';
import '../terminal_progress.dart';

/// Creates the JSON formatter selected by a scan invocation.
typedef JsonFormatterFactory = JsonFormatter Function(int version);

/// Analyses a project and reports findings without modifying project sources.
///
/// Every completed scan writes a tool-owned report below `.flutter_pruner`.
/// Finding mutation remains structurally isolated in the apply command.
class ScanCommand extends Command<int> {
  /// Creates the scan command.
  ScanCommand({
    ReportObjectBackend? reportBackend,
    JsonFormatterFactory? jsonFormatterFactory,
  }) : _reportBackend = reportBackend,
       _jsonFormatterFactory =
           jsonFormatterFactory ?? _defaultJsonFormatterFactory {
    argParser
      ..addOption(
        'format',
        allowed: ['human', 'json', 'html'],
        defaultsTo: 'html',
        help:
            'Saved report format. Defaults to self-contained interactive HTML.',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help:
            'Override the automatic .flutter_pruner/reports destination. '
            'Absolute paths remain supported.',
      )
      ..addOption(
        'json-version',
        allowed: ['2', '3'],
        defaultsTo: '3',
        help: 'JSON report schema. Version 2 is compatibility-only.',
      )
      ..addMultiOption(
        'adapter',
        help: 'Only run these adapters, by id. Defaults to all registered.',
      )
      ..addOption(
        'config',
        help:
            'Configuration path. Relative paths start at the selected project.',
      );
    addProjectOption(argParser);
  }

  final ReportObjectBackend? _reportBackend;
  final JsonFormatterFactory _jsonFormatterFactory;

  @override
  String get invocation => '${super.invocation} [project-path]';

  @override
  String get name => 'scan';

  @override
  String get description =>
      'Analyse without changing project sources. Always saves a report.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final outputPath = args.option('output');

    final rest = args.rest;
    if (rest.length > 1) {
      stderr.writeln('Error: expected at most one project path.');
      return 64;
    }

    late final ToolWorkspace workspace;
    try {
      workspace = resolveToolWorkspace(
        args,
        positionalProjectPath: rest.isEmpty ? null : rest.single,
      );
    } on ProjectSelectionException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    }
    final targetDir = workspace.projectRoot;
    late final File? requestedOutputFile;
    late final File configFile;
    try {
      requestedOutputFile = outputPath == null
          ? null
          : workspace.resolveReportFile(outputPath);
      final configPath = args.option('config');
      final explicitConfig = configPath == null
          ? null
          : workspace.resolveConfigFile(configPath);
      configFile = requireProjectConfig(workspace, explicitConfig);
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on ProjectConfigPreflightException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }

    final FrozenReportOutputIdentity? requestedOutputIdentity;
    try {
      requestedOutputIdentity = requestedOutputFile == null
          ? null
          : await FrozenReportOutputIdentity.resolve(
              requested: requestedOutputFile,
              selectedProjectRoot: targetDir,
            );
    } on FileSystemException catch (e) {
      stderr.writeln('Error: report was not saved: $e');
      return 1;
    }

    final ProjectContext project;
    try {
      project = await ProjectContext.load(
        targetDir,
        additionalExcludedPaths: [
          if (requestedOutputIdentity != null)
            ...requestedOutputIdentity.projectExclusions,
        ],
        configFile: configFile,
      );
    } on ProjectLoadException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }

    final progress = TerminalProgress(
      sink: stderr,
      animated: stderr.hasTerminal,
    )..writeProject(project.root.path);
    if (project.analysisMode == AnalysisMode.packageInternal) {
      stderr.writeln(packageInternalWarning(project.packageName));
    }

    final only = args.multiOption('adapter').toSet();
    final verbose = globalResults?.flag('verbose') ?? false;
    late final ProjectAnalyzer analyzer;
    try {
      analyzer = ProjectAnalyzer(
        project: project,
        only: only.isEmpty ? null : only,
      );
    } on StateError catch (e) {
      stderr.writeln('Error: ${e.message}');
      return 64;
    }

    if (analyzer.adapters.isEmpty) {
      stderr.writeln('Error: no matching adapters were selected.');
      return 64;
    }

    final recorder = RunRecorder(
      command: RunCommand.scan,
      requestedAdapters:
          only.isEmpty
                ? analyzer.adapters.map((adapter) => adapter.id).toList()
                : only.toList()
            ..sort(),
      toolVersion: packageVersion,
    );
    final format = args.option('format')!;
    final reportFormat = format == 'human' ? 'text' : format;
    final extension = _reportExtension(format);
    final provisionalIdentity = ReportCommitIdentity(
      runId: recorder.runId,
      sequence: 1,
      command: 'scan',
      completedAtUtc: canonicalReportTimestamp(DateTime.now().toUtc()),
    );
    late final PreparedReportOutput preparedOutput;
    try {
      final backend = _reportBackend ?? createIoReportObjectBackend();
      preparedOutput = requestedOutputIdentity == null
          ? await prepareManagedReportOutput(
              workspace: workspace,
              backend: backend,
              identity: provisionalIdentity,
              format: extension,
            )
          : await requestedOutputIdentity.prepare(
              backend: backend,
              identity: provisionalIdentity,
            );
    } on Object catch (error) {
      stderr.writeln('Error: report was not saved: $error');
      return 1;
    }
    if (project.analysisMode == AnalysisMode.packageInternal) {
      recorder.addDiagnostic(
        const RunDiagnostic(
          code: 'package-internal-boundary',
          phase: 'analysis',
          message:
              'Only package-local references were analysed; external '
              'consumers were not scanned.',
        ),
      );
    }
    recorder.registerAdapterReportDefinitions(
      analyzer.adapterReportDefinitions,
    );
    final writeContext = _ReportWriteContext();
    Object? primaryError;
    StackTrace? primaryStackTrace;
    int? failureExitCode;
    RunReport? completedReport;
    CommittedReport? committedReport;
    try {
      late final AnalysisSnapshot snapshot;
      var analysisSucceeded = false;
      try {
        snapshot = await analyzer.analyze(
          onAdapter: (adapter) => progress.start(adapter.name),
        );
        analysisSucceeded = true;
      } finally {
        progress.finish(succeeded: analysisSucceeded);
      }
      recorder.addAnalysisPass(
        snapshot.toPassReport(
          id: 'analysis-001',
          purpose: AnalysisPassPurpose.initial,
        ),
      );

      if (verbose) {
        stderr.writeln(
          'Graph: ${snapshot.graph.nodeCount} nodes, '
          '${snapshot.graph.edgeCount} edges, '
          '${snapshot.graph.blockers.length} blockers.',
        );
      }

      completedReport = recorder.finish(
        project: project,
        status: RunStatus.completed,
        exitCode: 0,
        findings: snapshot.findings,
      );
      final ReportFormatter formatter = switch (format) {
        'json' => _jsonFormatterFactory(
          int.parse(args.option('json-version')!),
        ),
        'html' => const HtmlFormatter(),
        _ => HumanFormatter(
          verbose: verbose,
          lineWidth: _humanLineWidth(writesToFile: true),
        ),
      };
      if (formatter is JsonFormatter) formatter.preflight(completedReport);
      committedReport = await preparedOutput.writeBatch(
        identity: ReportCommitIdentity(
          runId: completedReport.identity.id,
          sequence: 1,
          command: 'scan',
          completedAtUtc: canonicalReportTimestamp(
            completedReport.identity.finishedAtUtc,
          ),
        ),
        objects: [
          ReportObjectWrite(
            role: 'primary',
            format: reportFormat,
            reportSchemaVersion: format == 'json'
                ? int.parse(args.option('json-version')!)
                : format == 'html'
                ? 3
                : 1,
            writeTo: (sink) =>
                writeContext.write(formatter, completedReport!, sink),
          ),
        ],
      );
    } on JsonV2CompatibilityLimitException catch (error) {
      stderr.writeln('Error: $error');
      failureExitCode = 1;
    } on ImmutableReportStoreException catch (error) {
      final formatterFailure = writeContext.formatterFailure(error);
      if (formatterFailure == null) {
        stderr.writeln('Error: report was not saved: $error');
        failureExitCode = 1;
      } else {
        primaryError = formatterFailure.error;
        primaryStackTrace = formatterFailure.stackTrace;
      }
    } on Object catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
    }

    try {
      await preparedOutput.close();
    } on Object catch (error, stackTrace) {
      if (primaryError == null && failureExitCode == null) {
        primaryError = error;
        primaryStackTrace = stackTrace;
        stderr.writeln('Error: report was not saved: $error');
        failureExitCode = 1;
      }
    }
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStackTrace!);
    }
    if (failureExitCode != null) return failureExitCode;

    final actualPath = committedReport!.actualObjectPaths['primary']!;
    stdout.writeln(
      HumanFormatter(
        verbose: verbose,
        lineWidth: _humanLineWidth(writesToFile: false),
        reportPath: actualPath,
        reportFormat: format,
      ).format(completedReport!),
    );

    return 0;
  }

  int _humanLineWidth({required bool writesToFile}) {
    if (writesToFile || !stdout.hasTerminal) return 160;
    try {
      return stdout.terminalColumns;
    } on StdoutException {
      return 160;
    }
  }

  String _reportExtension(String format) => switch (format) {
    'human' => 'txt',
    'html' => 'html',
    _ => 'json',
  };
}

final class _ReportWriteContext {
  final Set<Object> _sinkFailures = Set<Object>.identity();
  final Map<Object, StackTrace> _formatterFailures =
      Map<Object, StackTrace>.identity();

  void write(ReportFormatter formatter, RunReport report, StringSink sink) {
    try {
      formatter.writeTo(
        report,
        _SinkFailureTrackingStringSink(sink, _sinkFailures),
      );
    } catch (error, stackTrace) {
      if (!_sinkFailures.contains(error)) {
        _formatterFailures[error] = stackTrace;
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  _FormatterFailure? formatterFailure(ImmutableReportStoreException failure) {
    final cause = failure.cause;
    if (failure.phase != ImmutableReportStorePhase.writeObject ||
        cause == null) {
      return null;
    }
    final stackTrace = _formatterFailures[cause];
    return stackTrace == null ? null : _FormatterFailure(cause, stackTrace);
  }
}

final class _FormatterFailure {
  const _FormatterFailure(this.error, this.stackTrace);

  final Object error;
  final StackTrace stackTrace;
}

final class _SinkFailureTrackingStringSink implements StringSink {
  const _SinkFailureTrackingStringSink(this._sink, this._failures);

  final StringSink _sink;
  final Set<Object> _failures;

  @override
  void write(Object? object) => _guard(() => _sink.write(object));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _guard(() => _sink.writeAll(objects, separator));

  @override
  void writeCharCode(int charCode) =>
      _guard(() => _sink.writeCharCode(charCode));

  @override
  void writeln([Object? object = '']) => _guard(() => _sink.writeln(object));

  void _guard(void Function() operation) {
    try {
      operation();
    } catch (error, stackTrace) {
      _failures.add(error);
      Error.throwWithStackTrace(error, stackTrace);
    }
  }
}

JsonFormatter _defaultJsonFormatterFactory(int version) =>
    JsonFormatter(version: version);
