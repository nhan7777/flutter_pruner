import 'dart:io';

import 'package:args/command_runner.dart';

import '../../analysis/analysis_snapshot.dart';
import '../../analysis/project_analyzer.dart';
import '../../core/process/managed_process_runner.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../reporting/immutable_report_store.dart';
import '../../reporting/io_report_object_backend.dart';
import '../../reporting/report_object_backend.dart';
import '../../reporting/report_output_identity.dart';
import '../../reporting/reportable_command_failure.dart';
import '../../reporting/run_recorder.dart';
import '../../reporting/run_report.dart';
import '../../version.dart';
import '../cli_exit_code.dart';
import '../cli_signal_coordinator.dart';
import '../formatters/html_formatter.dart';
import '../formatters/human_formatter.dart';
import '../formatters/json_formatter.dart';
import '../formatters/report_formatter.dart';
import '../project_command_support.dart';
import '../terminal_progress.dart';
import '../usage_error.dart';

/// Creates the JSON formatter selected by a scan invocation.
typedef JsonFormatterFactory = JsonFormatter Function(int version);

/// Creates the analyzer used by one scan invocation.
typedef ScanProjectAnalyzerFactory =
    ProjectAnalyzer Function(ProjectContext project, Set<String>? only);

/// Analyses a project and reports findings without modifying project sources.
///
/// Every completed scan writes a tool-owned report below `.flutter_pruner`.
/// Finding mutation remains structurally isolated in the apply command.
class ScanCommand extends Command<int> {
  /// Creates the scan command.
  ScanCommand({
    ReportObjectBackend? reportBackend,
    JsonFormatterFactory? jsonFormatterFactory,
    ScanProjectAnalyzerFactory? analyzerFactory,
    CliSignalCoordinator? signalCoordinator,
    ManagedProcessCancellationController? processCancellation,
    ManagedProcessStarter? analyzerProcessStarter,
    ManagedProcessTreeTerminator? analyzerProcessTreeTerminator,
  }) : _reportBackend = reportBackend,
       _signalCoordinator = signalCoordinator,
       _jsonFormatterFactory =
           jsonFormatterFactory ?? _defaultJsonFormatterFactory,
       _analyzerFactory =
           analyzerFactory ??
           ((project, only) => ProjectAnalyzer(
             project: project,
             only: only,
             analyzerDiagnosticProcessRunner: ManagedProcessRunner(
               cancellationController: processCancellation,
               processStarter: analyzerProcessStarter,
               processTreeTerminator: analyzerProcessTreeTerminator,
             ),
           )) {
    argParser
      ..addOption(
        'format',
        allowed: ['human', 'json', 'html'],
        defaultsTo: 'html',
        help:
            'Saved report format; defaults to self-contained interactive HTML',
      )
      ..addOption(
        'output',
        abbr: 'o',
        help:
            'Override automatic .flutter_pruner/reports destination; '
            'absolute paths remain supported',
      )
      ..addOption(
        'json-version',
        allowed: ['2', '3'],
        defaultsTo: '3',
        help: 'JSON report schema; version 2 is legacy',
      )
      ..addMultiOption(
        'adapter',
        help: 'Run only these adapter IDs; defaults to all registered',
      )
      ..addOption(
        'config',
        help: 'Configuration path; relative paths start at selected project',
      );
    addProjectOption(argParser);
  }

  final ReportObjectBackend? _reportBackend;
  final CliSignalCoordinator? _signalCoordinator;
  final JsonFormatterFactory _jsonFormatterFactory;
  final ScanProjectAnalyzerFactory _analyzerFactory;

  @override
  String get invocation => '${super.invocation} [project-path]';

  @override
  String get name => 'scan';

  @override
  String get description =>
      'Analyse without changing project sources; always saves a report';

  @override
  String get usageFooter => '''Examples:
  flutter_pruner scan
  flutter_pruner scan --format json --output scan.json
  flutter_pruner scan --project ./example

Scan may persist tool state and reports''';

  @override
  Future<int> run() async {
    final args = argResults!;
    final outputPath = args.option('output');
    final only = args.multiOption('adapter').toSet();

    if (args.wasParsed('json-version') && args.option('format') != 'json') {
      throw commandUsageError(this, '--json-version requires --format json.');
    }

    final rest = args.rest;
    if (rest.length > 1) {
      throw commandUsageError(this, 'Expected at most one project path.');
    }
    if (args.option('project') != null && rest.isNotEmpty) {
      throw commandUsageError(
        this,
        'Pass the project once, using either --project or [project-path].',
      );
    }
    try {
      validateRequestedAdapterIds(only);
    } on UnknownAdapterIdUsageException catch (e) {
      throw commandUsageError(this, e.message);
    }

    late final ToolWorkspace workspace;
    try {
      workspace = resolveToolWorkspace(
        args,
        positionalProjectPath: rest.isEmpty ? null : rest.single,
      );
    } on ProjectSelectionException catch (e) {
      stderr.writeln('Error: $e');
      return CliExitCode.operationalFailure;
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
      return CliExitCode.operationalFailure;
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
      signalCoordinator: _signalCoordinator,
    )..writeProject(project.root.path);
    if (project.analysisMode == AnalysisMode.packageInternal) {
      stderr.writeln(packageInternalWarning(project.packageName));
    }

    final verbose = globalResults?.flag('verbose') ?? false;
    final analyzer = _analyzerFactory(project, only.isEmpty ? null : only);

    if (analyzer.adapters.isEmpty) {
      throw StateError('No matching adapters were selected.');
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
    } on FileSystemException catch (error) {
      stderr.writeln('Error: report was not saved: $error');
      return 1;
    } on ReportObjectBackendException catch (error) {
      stderr.writeln('Error: report was not saved: $error');
      return 1;
    }
    late final ProjectOperationLock operationLock;
    try {
      operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'scan-analysis',
      );
    } on ProjectOperationLockException catch (error) {
      try {
        await preparedOutput.close();
      } on Object {
        // The retained process-authority failure remains primary.
      }
      stderr.writeln('Error: $error');
      return CliExitCode.operationalFailure;
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
    final writeContext = _ReportWriteContext();
    Object? primaryError;
    StackTrace? primaryStackTrace;
    int? failureExitCode;
    Object? reportPersistenceError;
    RunReport? completedReport;
    CommittedReport? committedReport;
    ReportableCommandFailure? commandFailure;
    Object? postCommitCloseError;
    try {
      late final AnalysisSnapshot snapshot;
      var analysisSucceeded = false;
      String? currentAdapterId;
      String? currentAdapterName;
      try {
        recorder.registerAdapterReportDefinitions(
          analyzer.adapterReportDefinitions,
        );
        snapshot = await operationLock.guardManagedProcessUncertainty(
          incidentId: recorder.runId,
          phase: 'analysis',
          body: () => analyzer.analyze(
            onAdapter: (adapter) {
              final context = _validatedAdapterContext(
                id: adapter.id,
                name: adapter.name,
              );
              currentAdapterId = context?.id;
              currentAdapterName = context?.name;
              progress.start(context?.name ?? 'adapter analysis');
            },
            onAdapterFinished: (adapter, status) {
              if (status == AdapterRunStatus.failed) return;
              currentAdapterId = null;
              currentAdapterName = null;
            },
          ),
        );
        analysisSucceeded = true;
      } on ProcessCancellationBeforeLaunchException catch (error) {
        commandFailure = _scanCancellationFailure(error.originalSignal);
      } on ProcessCancellationConfirmedException catch (error) {
        commandFailure = _scanCancellationFailure(error.originalSignal);
      } on ProcessTerminationUnconfirmedException catch (error) {
        commandFailure = _scanUnconfirmedProcessFailure(
          error,
          exactEvidenceRetained:
              operationLock.hasRetainedExactProcessIdentityEvidence,
        );
      } on Object {
        commandFailure = currentAdapterId == null
            ? ReportableCommandFailure(
                code: 'analysis_failed',
                phase: 'analysis',
                message: 'Project analysis did not complete.',
                exitCode: CliExitCode.internal,
                status: RunStatus.internalError,
              )
            : ReportableCommandFailure(
                code: 'adapter_analysis_failed',
                phase: 'analysis:adapter:$currentAdapterId',
                message:
                    'Analysis failed after adapter $currentAdapterName '
                    '($currentAdapterId) started.',
                exitCode: CliExitCode.internal,
                status: RunStatus.internalError,
              );
      } finally {
        try {
          progress.finish(succeeded: analysisSucceeded);
        } finally {
          await operationLock.release();
        }
      }
      if (commandFailure case final failure?) {
        completedReport = recorder.finishFailure(
          project: project,
          failure: failure,
        );
        stderr.writeln('Error: ${failure.message}');
      } else {
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
      }
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
      if (commandFailure != null &&
          formatter is JsonFormatter &&
          formatter.version == 2) {
        throw const _FailureReportCompatibilityException();
      }
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
      reportPersistenceError = error;
    } on ImmutableReportStoreException catch (error) {
      final formatterFailure = writeContext.formatterFailure(error);
      if (formatterFailure == null) {
        failureExitCode = 1;
        reportPersistenceError = error;
      } else {
        primaryError = formatterFailure.error;
        primaryStackTrace = formatterFailure.stackTrace;
        reportPersistenceError = formatterFailure.error;
      }
    } on Object catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
      reportPersistenceError = error;
    }

    try {
      await preparedOutput.close();
    } on Object catch (error, stackTrace) {
      if (committedReport != null) {
        postCommitCloseError = error;
      } else if (primaryError == null && failureExitCode == null) {
        primaryError = error;
        primaryStackTrace = stackTrace;
        reportPersistenceError = error;
      }
    }
    if (reportPersistenceError case final error?) {
      stderr.writeln('Error: report was not saved: $error');
    }
    if (commandFailure case final failure?) {
      if (reportPersistenceError != null) return failure.exitCode;
      final actualPath = committedReport!.actualObjectPaths['primary']!;
      if (postCommitCloseError case final error?) {
        stderr.writeln(
          'Error: report output close failed after commit: $error',
        );
      }
      stderr.writeln('Failure report saved: $actualPath');
      return failure.exitCode;
    }
    if (postCommitCloseError case final error?) {
      final actualPath = committedReport!.actualObjectPaths['primary']!;
      stderr.writeln('Error: report output close failed after commit: $error');
      stderr.writeln('Report saved: $actualPath');
      return CliExitCode.internal;
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
  var _writeStarted = false;

  void write(ReportFormatter formatter, RunReport report, StringSink sink) {
    if (_writeStarted) {
      throw StateError('A report formatter callback cannot be reused.');
    }
    _writeStarted = true;
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

ReportableCommandFailure _scanCancellationFailure(ProcessSignal signal) =>
    ReportableCommandFailure(
      code: 'process_cancelled_before_mutation',
      phase: 'analysis',
      message: 'Scan was interrupted while an owned process tree was active.',
      exitCode: conventionalSignalExitCode(signal),
      status: RunStatus.interrupted,
    );

ReportableCommandFailure _scanUnconfirmedProcessFailure(
  ProcessTerminationUnconfirmedException error, {
  required bool exactEvidenceRetained,
}) => ReportableCommandFailure(
  code: 'process_termination_unconfirmed',
  phase: 'analysis',
  message: exactEvidenceRetained
      ? 'An analyzer process rooted at PID ${error.processId} may still be '
            'running. Scan did not mutate project sources. Future mutating '
            'commands remain blocked until every exact recorded process '
            'identity is absent; rerun the command to recheck.'
      : 'An analyzer process rooted at PID ${error.processId} may still be '
            'running, and complete identity evidence was not retained. Scan '
            'did not mutate project sources. Future mutating commands remain '
            'blocked; preserve operation.lock and inspect the process before '
            'recovery.',
  exitCode: CliExitCode.operationalFailure,
  status: RunStatus.infrastructureFailure,
);

final class _FailureReportCompatibilityException implements Exception {
  const _FailureReportCompatibilityException();

  @override
  String toString() =>
      'JSON v2 cannot represent failed run reports. Use --json-version 3.';
}

({String id, String name})? _validatedAdapterContext({
  required String id,
  required String name,
}) {
  final stableId = id.length <= 64 && RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(id);
  final safeName =
      name.isNotEmpty &&
      name.length <= 128 &&
      name.trim() == name &&
      !name.runes.any(
        (rune) =>
            rune < 0x20 ||
            (rune >= 0x7f && rune <= 0x9f) ||
            (rune >= 0x200b && rune <= 0x200f) ||
            rune == 0x2028 ||
            rune == 0x2029 ||
            (rune >= 0x202a && rune <= 0x202e) ||
            (rune >= 0x2066 && rune <= 0x2069) ||
            rune == 0xfeff,
      );
  return stableId && safeName ? (id: id, name: name) : null;
}
