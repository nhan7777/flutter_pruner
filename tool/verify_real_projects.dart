import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addMultiOption(
      'project',
      abbr: 'p',
      help: 'Real project root. Pass at least three.',
    )
    ..addMultiOption(
      'config',
      help: 'Optional config path for the project at the same index.',
    )
    ..addOption('output-dir', mandatory: true)
    ..addOption('minimum-projects', defaultsTo: '3');
  final options = parser.parse(arguments);
  final projects = options.multiOption('project');
  final configs = options.multiOption('config');
  final minimumProjects = int.parse(options.option('minimum-projects')!);
  if (minimumProjects < 1 || projects.length < minimumProjects) {
    throw ArgumentError('Pass at least $minimumProjects --project values.');
  }
  if (configs.isNotEmpty && configs.length != projects.length) {
    throw ArgumentError('--config count must match --project count.');
  }

  final output = Directory(p.absolute(options.option('output-dir')!));
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError(
      'Output directory must be absent or empty: ${output.path}',
    );
  }
  await output.create(recursive: true);

  final results = <Map<String, Object?>>[];
  for (var index = 0; index < projects.length; index++) {
    final project = Directory(p.absolute(projects[index]));
    if (!project.existsSync()) {
      throw ArgumentError('Project directory not found at index ${index + 1}.');
    }
    final config = configs.isEmpty ? null : p.absolute(configs[index]);
    if (config != null && !File(config).existsSync()) {
      throw ArgumentError('Config file not found at index ${index + 1}.');
    }
    results.add(
      await _verifyProject(
        index: index,
        project: project,
        config: config,
        output: output,
      ),
    );
  }

  final passed = results.every((result) => result['passed'] == true);
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'projectCount': results.length,
      'minimumProjectCount': minimumProjects,
      'passed': passed,
      'projects': results,
    }),
  );
  if (!passed) exitCode = 1;
}

Future<Map<String, Object?>> _verifyProject({
  required int index,
  required Directory project,
  required String? config,
  required Directory output,
}) async {
  final beforeStatus = await _trackedStatus(project);
  final scanReport = File(
    p.join(output.path, 'project-${index + 1}-scan.json'),
  );
  final scan = await _runTool([
    'scan',
    '--project',
    project.path,
    if (config != null) ...['--config', config],
    '--format',
    'json',
    '--output',
    scanReport.path,
  ]);

  Map<String, Object?>? report;
  String? reportError;
  if (scan.exitCode == 0 && scanReport.existsSync()) {
    try {
      report =
          jsonDecode(await scanReport.readAsString()) as Map<String, Object?>;
    } on Object catch (error) {
      reportError = error.toString();
    }
  }

  final coverage = report?['analysisCoverage'] as Map<String, Object?>?;
  final targetMatrix = coverage?['targetMatrix'] as Map<String, Object?>?;
  final roots = coverage?['roots'] as Map<String, Object?>?;
  final statistics = report?['statistics'] as Map<String, Object?>?;
  final findingStatistics = statistics?['findings'] as Map<String, Object?>?;
  final tiers = findingStatistics?['byTier'] as Map<String, Object?>?;
  final analysisMode = coverage?['analysisMode'] as String?;
  final coverageComplete =
      targetMatrix?['complete'] == true &&
      roots?['internalBoundaryComplete'] == true;
  final safe = tiers?['SAFE'] as int?;
  final high = tiers?['HIGH'] as int?;
  final noActionableTiers = (safe ?? -1) == 0 && (high ?? -1) == 0;
  final failClosed = analysisMode == 'package'
      ? noActionableTiers
      : coverageComplete || noActionableTiers;

  final dryRunReport = File(
    p.join(output.path, 'project-${index + 1}-dry-run.json'),
  );
  final dryRun = await _runTool([
    'apply',
    '--dry-run',
    '--project',
    project.path,
    if (config != null) ...['--config', config],
    '--report-format',
    'json',
    '--report-output',
    dryRunReport.path,
  ]);
  final expectedDryRunExit =
      dryRun.exitCode == 0 ||
      (dryRun.exitCode == 1 &&
          (analysisMode == 'package' || !coverageComplete));
  final afterStatus = await _trackedStatus(project);
  final trackedTreeUnchanged =
      beforeStatus != null &&
      afterStatus != null &&
      beforeStatus == afterStatus;
  final passed =
      scan.exitCode == 0 &&
      report != null &&
      report['version'] == 3 &&
      (report['run'] as Map<String, Object?>?)?['status'] == 'completed' &&
      failClosed &&
      expectedDryRunExit &&
      trackedTreeUnchanged;

  return {
    'label': 'project-${index + 1}',
    'passed': passed,
    'scanExitCode': scan.exitCode,
    'dryRunExitCode': dryRun.exitCode,
    'analysisMode': analysisMode,
    'targetCoverageComplete': targetMatrix?['complete'],
    'rootCoverageComplete': roots?['complete'],
    'internalBoundaryComplete': roots?['internalBoundaryComplete'],
    'safe': safe,
    'high': high,
    'review': tiers?['REVIEW'],
    'protected': tiers?['PROTECTED'],
    'failClosed': failClosed,
    'trackedTreeUnchanged': trackedTreeUnchanged,
    if (reportError != null) 'reportError': reportError,
    if (scan.exitCode != 0) 'scanError': _lastLines(scan.stderr as String),
    if (!expectedDryRunExit) 'dryRunError': _lastLines(dryRun.stderr as String),
  };
}

Future<ProcessResult> _runTool(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', 'bin/flutter_pruner.dart', ...arguments],
  workingDirectory: Directory.current.path,
  stdoutEncoding: utf8,
  stderrEncoding: utf8,
);

Future<String?> _trackedStatus(Directory project) async {
  final result = await Process.run('git', [
    '-C',
    project.path,
    'status',
    '--porcelain=v1',
    '--untracked-files=no',
    '--',
    '.',
  ]);
  if (result.exitCode != 0) return null;
  return result.stdout as String;
}

String _lastLines(String value) {
  final lines = const LineSplitter().convert(value.trim());
  return lines.skip(lines.length > 5 ? lines.length - 5 : 0).join('\n');
}
