import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter_profile.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('small-contexts', defaultsTo: '4')
    ..addOption('large-contexts', defaultsTo: '16')
    ..addOption('libraries', defaultsTo: '12')
    ..addOption('warmup', defaultsTo: '1')
    ..addOption('iterations', defaultsTo: '3')
    ..addOption('max-candidate-growth-ratio');
  final options = parser.parse(arguments);
  final smallContexts = int.parse(options.option('small-contexts')!);
  final largeContexts = int.parse(options.option('large-contexts')!);
  final libraryCount = int.parse(options.option('libraries')!);
  final warmup = int.parse(options.option('warmup')!);
  final iterations = int.parse(options.option('iterations')!);
  final maxCandidateGrowthRatio = switch (options.option(
    'max-candidate-growth-ratio',
  )) {
    final String value => double.parse(value),
    null => null,
  };
  if (smallContexts < 1 ||
      largeContexts <= smallContexts ||
      libraryCount < 2 ||
      warmup < 0 ||
      iterations < 1) {
    throw ArgumentError(
      'small contexts must be positive, large contexts must exceed small, '
      'libraries must be at least two, warmup must be non-negative, and '
      'iterations must be positive',
    );
  }
  if (maxCandidateGrowthRatio != null &&
      (!maxCandidateGrowthRatio.isFinite || maxCandidateGrowthRatio < 0)) {
    throw ArgumentError(
      'max candidate growth ratio must be finite and non-negative',
    );
  }

  for (var index = 0; index < warmup; index++) {
    await _measure(smallContexts, libraryCount);
    await _measure(largeContexts, libraryCount);
  }

  final samples = <Map<String, Object?>>[];
  final smallElapsed = <int>[];
  final largeElapsed = <int>[];
  int? smallCandidateEdges;
  int? largeCandidateEdges;
  int? smallDirectiveEdges;
  int? largeDirectiveEdges;
  for (var index = 0; index < iterations; index++) {
    final small = await _measure(smallContexts, libraryCount);
    final large = await _measure(largeContexts, libraryCount);
    smallElapsed.add(small.elapsedMicros);
    largeElapsed.add(large.elapsedMicros);
    smallCandidateEdges ??= small.candidateEdges;
    largeCandidateEdges ??= large.candidateEdges;
    smallDirectiveEdges ??= small.directiveEdges;
    largeDirectiveEdges ??= large.directiveEdges;
    if (smallCandidateEdges != small.candidateEdges ||
        largeCandidateEdges != large.candidateEdges ||
        smallDirectiveEdges != small.directiveEdges ||
        largeDirectiveEdges != large.directiveEdges) {
      throw StateError('Deterministic closure counts changed between samples.');
    }
    samples.add({
      'smallElapsedMicros': small.elapsedMicros,
      'largeElapsedMicros': large.elapsedMicros,
      'smallFingerprint': small.fingerprint,
      'largeFingerprint': large.fingerprint,
    });
  }
  smallElapsed.sort();
  largeElapsed.sort();
  final candidateGrowthRatio = largeCandidateEdges! / smallCandidateEdges!;
  final result = {
    'schemaVersion': 1,
    'dartVersion': Platform.version,
    'processors': Platform.numberOfProcessors,
    'smallContextCount': smallContexts,
    'largeContextCount': largeContexts,
    'libraryCount': libraryCount,
    'smallDirectiveEdgeCount': smallDirectiveEdges,
    'largeDirectiveEdgeCount': largeDirectiveEdges,
    'smallCandidateEdgeCount': smallCandidateEdges,
    'largeCandidateEdgeCount': largeCandidateEdges,
    'candidateGrowthRatio': candidateGrowthRatio,
    'warmup': warmup,
    'iterations': iterations,
    'medianSmallMicros': smallElapsed[smallElapsed.length ~/ 2],
    'medianLargeMicros': largeElapsed[largeElapsed.length ~/ 2],
    'samples': samples,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  if (maxCandidateGrowthRatio != null &&
      candidateGrowthRatio > maxCandidateGrowthRatio) {
    stderr.writeln(
      'Closure candidate growth ${candidateGrowthRatio.toStringAsFixed(2)}x '
      'exceeds ${maxCandidateGrowthRatio.toStringAsFixed(2)}x.',
    );
    exitCode = 2;
  }
}

Future<
  ({
    int elapsedMicros,
    int candidateEdges,
    int directiveEdges,
    String fingerprint,
  })
>
_measure(int contextCount, int libraryCount) async {
  final root = await Directory.systemTemp.createTemp('closure-benchmark-');
  try {
    _write(root, 'pubspec.yaml', '''
name: closure_benchmark
environment:
  sdk: ^3.9.0
''');
    _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"closure_benchmark","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    for (var index = 0; index < libraryCount; index++) {
      final nextImport = index + 1 < libraryCount
          ? "import 'library_${index + 1}.dart';\n"
          : '';
      final declaration = index == 0
          ? 'void main() {}\n'
          : 'class Library$index {}\n';
      _write(
        root,
        index == 0 ? 'lib/main.dart' : 'lib/library_$index.dart',
        '$nextImport$declaration',
      );
    }
    final targets = [
      for (var index = 0; index < contextCount; index++)
        BuildTarget(
          name: 'web-$index',
          platform: 'web',
          entrypoint: 'lib/main.dart',
        ),
    ];
    final project = ProjectContext(
      root: root,
      pubspec: const {'name': 'closure_benchmark'},
      packageName: 'closure_benchmark',
      targets: targets,
      rootCoverage: RootCoverage.applicationApi(),
    );
    const rootLibraryId = 'dart:closure_benchmark/lib/main.dart';
    final contexts = DartExecutionContextSnapshot(
      configuredTargets: targets,
      auxiliaryExecutionTargets: const [],
      roots: [
        for (final target in targets)
          DartExecutionRootFact(
            nodeId: rootLibraryId,
            owningLibraryId: rootLibraryId,
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.configuredTarget,
            reason: 'synthetic configured entrypoint',
            configuredTarget: target,
          ),
      ],
      issues: const [],
    );
    final profile = DartAdapterProfile();
    final stopwatch = Stopwatch()..start();
    final snapshot = await DefaultDartExecutionReachabilityService(
      workspace: DartAnalysisWorkspace(project),
      contexts: contexts,
      profile: profile,
    ).resolve(project);
    stopwatch.stop();
    for (final paths in snapshot.configuredProvenUnitPaths.values) {
      if (paths.length != libraryCount) {
        throw StateError(
          'Expected $libraryCount reached units, found ${paths.length}.',
        );
      }
    }
    final counters = profile.snapshot()['counters']! as Map<String, Object>;
    return (
      elapsedMicros: stopwatch.elapsedMicroseconds,
      candidateEdges: counters['executionClosureCandidateEdges']! as int,
      directiveEdges: snapshot.directives.edges.length,
      fingerprint: snapshot.fingerprint,
    );
  } finally {
    root.deleteSync(recursive: true);
  }
}

void _write(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
