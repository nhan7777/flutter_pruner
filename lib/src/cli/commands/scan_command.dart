import 'dart:io';

import 'package:args/command_runner.dart';

import '../../analysis/analysis_snapshot.dart';
import '../../analysis/project_analyzer.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import '../../core/project/tool_workspace.dart';
import '../../reporting/run_recorder.dart';
import '../../reporting/run_report.dart';
import '../../version.dart';
import '../formatters/html_formatter.dart';
import '../formatters/human_formatter.dart';
import '../formatters/json_formatter.dart';
import '../formatters/report_formatter.dart';
import '../project_command_support.dart';
import '../terminal_progress.dart';

/// Analyses a project and reports findings without modifying project sources.
///
/// Every completed scan writes a tool-owned report below `.flutter_pruner`.
/// Finding mutation remains structurally isolated in the apply command.
class ScanCommand extends Command<int> {
  /// Creates the scan command.
  ScanCommand() {
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

    final ProjectContext project;
    try {
      project = await ProjectContext.load(
        targetDir,
        additionalExcludedPaths: [
          if (requestedOutputFile != null) requestedOutputFile.path,
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
    late final File outputFile;
    try {
      outputFile =
          requestedOutputFile ??
          workspace.resolveReportFile(
            'scan-${recorder.runId}.${_reportExtension(format)}',
          );
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
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

    final findings = snapshot.findings;
    final report = recorder.finish(
      project: project,
      status: RunStatus.completed,
      exitCode: 0,
      findings: findings,
    );

    // Format the persisted report.
    final ReportFormatter formatter = switch (format) {
      'json' => JsonFormatter(version: int.parse(args.option('json-version')!)),
      'html' => const HtmlFormatter(),
      _ => HumanFormatter(
        verbose: verbose,
        lineWidth: _humanLineWidth(writesToFile: true),
      ),
    };

    final renderedReport = formatter.format(report);

    await outputFile.parent.create(recursive: true);
    await outputFile.writeAsString(renderedReport);
    final terminalReport = HumanFormatter(
      verbose: verbose,
      lineWidth: _humanLineWidth(writesToFile: false),
      reportPath: outputFile.path,
      reportFormat: format,
    ).format(report);
    stdout.writeln(terminalReport);

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
