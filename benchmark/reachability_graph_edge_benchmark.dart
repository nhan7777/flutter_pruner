import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('small', defaultsTo: '10000')
    ..addOption('large', defaultsTo: '20000')
    ..addOption('warmup', defaultsTo: '1')
    ..addOption('iterations', defaultsTo: '3')
    ..addOption('max-growth-ratio');
  final options = parser.parse(arguments);
  final small = int.parse(options.option('small')!);
  final large = int.parse(options.option('large')!);
  final warmup = int.parse(options.option('warmup')!);
  final iterations = int.parse(options.option('iterations')!);
  final maxGrowthRatio = switch (options.option('max-growth-ratio')) {
    final String value => double.parse(value),
    null => null,
  };
  if (small < 1 || large <= small || warmup < 0 || iterations < 1) {
    throw ArgumentError(
      'small must be positive, large must exceed small, warmup must be '
      'non-negative, and iterations must be positive',
    );
  }
  if (maxGrowthRatio != null &&
      (!maxGrowthRatio.isFinite || maxGrowthRatio < 0)) {
    throw ArgumentError('max growth ratio must be finite and non-negative');
  }

  for (var index = 0; index < warmup; index++) {
    _measureInsertion(small);
    _measureInsertion(large);
  }

  final samples = <Map<String, Object?>>[];
  final smallSamples = <int>[];
  final largeSamples = <int>[];
  for (var index = 0; index < iterations; index++) {
    final smallElapsedMicros = _measureInsertion(small);
    final largeElapsedMicros = _measureInsertion(large);
    smallSamples.add(smallElapsedMicros);
    largeSamples.add(largeElapsedMicros);
    samples.add({
      'smallElapsedMicros': smallElapsedMicros,
      'largeElapsedMicros': largeElapsedMicros,
    });
  }
  smallSamples.sort();
  largeSamples.sort();
  final medianSmallMicros = smallSamples[smallSamples.length ~/ 2];
  final medianLargeMicros = largeSamples[largeSamples.length ~/ 2];
  final medianGrowthRatio = medianSmallMicros == 0
      ? double.infinity
      : medianLargeMicros / medianSmallMicros;
  final result = {
    'schemaVersion': 1,
    'dartVersion': Platform.version,
    'processors': Platform.numberOfProcessors,
    'smallEdgeCount': small,
    'largeEdgeCount': large,
    'warmup': warmup,
    'iterations': iterations,
    'medianSmallMicros': medianSmallMicros,
    'medianLargeMicros': medianLargeMicros,
    'medianGrowthRatio': medianGrowthRatio,
    'samples': samples,
  };
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(result));
  if (maxGrowthRatio != null && medianGrowthRatio > maxGrowthRatio) {
    stderr.writeln(
      'Edge insertion growth ${medianGrowthRatio.toStringAsFixed(2)}x '
      'exceeds ${maxGrowthRatio.toStringAsFixed(2)}x.',
    );
    exitCode = 2;
  }
}

int _measureInsertion(int edgeCount) {
  final graph = ReachabilityGraph();
  final stopwatch = Stopwatch()..start();
  for (var index = 0; index < edgeCount; index++) {
    graph.addEdge(
      GraphEdge(
        from: 'source:$index',
        to: 'target:$index',
        kind: EdgeKind.references,
        evidence: const Evidence(
          kind: EvidenceKind.semanticReference,
          producer: 'benchmark',
          description: 'unique synthetic edge',
          exact: true,
        ),
      ),
    );
  }
  stopwatch.stop();
  if (graph.edgeCount != edgeCount) {
    throw StateError(
      'Expected $edgeCount unique edges, found ${graph.edgeCount}.',
    );
  }
  return stopwatch.elapsedMicroseconds;
}
