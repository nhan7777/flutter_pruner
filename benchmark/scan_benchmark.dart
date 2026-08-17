import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter_profile.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/reporting/run_recorder.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:flutter_pruner/src/version.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('project', defaultsTo: '.')
    ..addOption('iterations', defaultsTo: '3')
    ..addOption('warmup', defaultsTo: '1')
    ..addFlag('ignore-project-config', negatable: false)
    ..addFlag('include-project-path', negatable: false)
    ..addFlag('profile', negatable: false)
    ..addOption('max-report-overhead-percent')
    ..addMultiOption('only');
  final options = parser.parse(arguments);
  final iterations = int.parse(options.option('iterations')!);
  final warmup = int.parse(options.option('warmup')!);
  if (iterations < 1 || warmup < 0) {
    throw ArgumentError('iterations must be positive and warmup non-negative');
  }

  final ignoreProjectConfig = options.flag('ignore-project-config');
  final includeProjectPath = options.flag('include-project-path');
  final project = await _loadProject(
    Directory(options.option('project')!).absolute,
    ignoreProjectConfig: ignoreProjectConfig,
  );
  final onlyValues = options.multiOption('only');
  final only = onlyValues.isEmpty ? null : onlyValues.toSet();
  final profile = options.flag('profile');
  final maxReportOverheadPercent = switch (options.option(
    'max-report-overhead-percent',
  )) {
    final String value => double.parse(value),
    null => null,
  };
  if (maxReportOverheadPercent != null &&
      (!maxReportOverheadPercent.isFinite || maxReportOverheadPercent < 0)) {
    throw ArgumentError('max report overhead percent must be non-negative');
  }

  for (var index = 0; index < warmup; index++) {
    await ProjectAnalyzer(project: project, only: only).analyze();
  }

  final samples = <Map<String, Object?>>[];
  for (var index = 0; index < iterations; index++) {
    final dartProfile = profile ? DartAdapterProfile() : null;
    final analyzer = ProjectAnalyzer(
      project: project,
      only: only,
      dartProfile: dartProfile,
    );
    final snapshot = await analyzer.analyze();
    final reportStopwatch = Stopwatch()..start();
    final recorder = RunRecorder(
      command: RunCommand.scan,
      requestedAdapters: snapshot.adapterIds,
      toolVersion: packageVersion,
    )..registerAdapterReportDefinitions(analyzer.adapterReportDefinitions);
    recorder.addAnalysisPass(
      snapshot.toPassReport(
        id: 'analysis-001',
        purpose: AnalysisPassPurpose.initial,
      ),
    );
    final report = recorder.finish(
      project: project,
      status: RunStatus.completed,
      exitCode: 0,
      findings: snapshot.findings,
    );
    final renderedReport = const JsonFormatter().format(report);
    reportStopwatch.stop();
    final reportOverheadPercent = snapshot.elapsedMicros == 0
        ? 0.0
        : reportStopwatch.elapsedMicroseconds * 100 / snapshot.elapsedMicros;
    samples.add({
      'elapsedMicros': snapshot.elapsedMicros,
      'findingElapsedMicros': snapshot.findingElapsedMicros,
      'reportElapsedMicros': reportStopwatch.elapsedMicroseconds,
      'reportBytes': utf8.encode(renderedReport).length,
      'reportOverheadPercent': reportOverheadPercent,
      'nodes': snapshot.graph.nodeCount,
      'edges': snapshot.graph.edgeCount,
      'blockers': snapshot.graph.blockers.length,
      'findings': snapshot.findings.length,
      if (dartProfile != null) 'dartProfile': dartProfile.snapshot(),
      'adapters': [
        for (final run in snapshot.adapterRuns)
          {
            'id': run.id,
            'status': run.status.name,
            'elapsedMicros': run.elapsedMicros,
            'nodesAdded': run.nodesAdded,
            'edgesAdded': run.edgesAdded,
            'blockersAdded': run.blockersAdded,
          },
      ],
    });
  }

  final elapsed =
      samples.map((sample) => sample['elapsedMicros']! as int).toList()..sort();
  final reportOverhead =
      samples
          .map((sample) => sample['reportOverheadPercent']! as double)
          .toList()
        ..sort();
  final medianReportOverheadPercent =
      reportOverhead[reportOverhead.length ~/ 2];
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': 1,
      'project': includeProjectPath ? project.root.path : '<redacted>',
      'projectPathIncluded': includeProjectPath,
      'ignoredProjectConfig': ignoreProjectConfig,
      'dartVersion': Platform.version,
      'processors': Platform.numberOfProcessors,
      'warmup': warmup,
      'iterations': iterations,
      'profile': profile,
      'medianElapsedMicros': elapsed[elapsed.length ~/ 2],
      'minElapsedMicros': elapsed.first,
      'maxElapsedMicros': elapsed.last,
      'medianReportOverheadPercent': medianReportOverheadPercent,
      'maxReportOverheadPercent': reportOverhead.last,
      'samples': samples,
    }),
  );
  if (maxReportOverheadPercent != null &&
      medianReportOverheadPercent > maxReportOverheadPercent) {
    stderr.writeln(
      'Report overhead ${medianReportOverheadPercent.toStringAsFixed(2)}% '
      'exceeds ${maxReportOverheadPercent.toStringAsFixed(2)}%.',
    );
    exitCode = 2;
  }
}

Future<ProjectContext> _loadProject(
  Directory root, {
  required bool ignoreProjectConfig,
}) async {
  if (!ignoreProjectConfig) return ProjectContext.load(root);

  final parsed = loadYaml(
    await File(p.join(root.path, 'pubspec.yaml')).readAsString(),
  );
  if (parsed is! Map || parsed['name'] is! String) {
    throw StateError('pubspec.yaml must contain a package name');
  }
  return ProjectContext(
    root: root,
    pubspec: parsed,
    packageName: parsed['name'] as String,
    targets: [
      BuildTarget(
        name: 'benchmark-android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
      BuildTarget(
        name: 'benchmark-ios',
        platform: 'ios',
        entrypoint: 'lib/main.dart',
      ),
    ],
  );
}
