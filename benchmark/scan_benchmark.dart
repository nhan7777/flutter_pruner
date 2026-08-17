import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter_profile.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
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

  for (var index = 0; index < warmup; index++) {
    await ProjectAnalyzer(project: project, only: only).analyze();
  }

  final samples = <Map<String, Object?>>[];
  for (var index = 0; index < iterations; index++) {
    final dartProfile = profile ? DartAdapterProfile() : null;
    final snapshot = await ProjectAnalyzer(
      project: project,
      only: only,
      dartProfile: dartProfile,
    ).analyze();
    samples.add({
      'elapsedMicros': snapshot.elapsedMicros,
      'findingElapsedMicros': snapshot.findingElapsedMicros,
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
      'samples': samples,
    }),
  );
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
