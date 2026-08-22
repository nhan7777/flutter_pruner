import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('edge benchmark reports the measured graph sizes', () async {
    final result = await _runBenchmark([
      '--small',
      '32',
      '--large',
      '64',
      '--warmup',
      '0',
      '--iterations',
      '1',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(output['schemaVersion'], 1);
    expect(output['smallEdgeCount'], 32);
    expect(output['largeEdgeCount'], 64);
    expect(output['warmup'], 0);
    expect(output['iterations'], 1);
    expect(output['medianSmallMicros'], isA<int>());
    expect(output['medianLargeMicros'], isA<int>());
    expect(output['medianGrowthRatio'], isA<num>());
    expect(output['samples'], hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('edge benchmark returns non-zero when its growth gate fails', () async {
    final result = await _runBenchmark([
      '--small',
      '32',
      '--large',
      '64',
      '--warmup',
      '0',
      '--iterations',
      '1',
      '--max-growth-ratio',
      '0',
    ]);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Edge insertion growth'));
    expect(
      jsonDecode(result.stdout as String),
      containsPair('largeEdgeCount', 64),
    );
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<ProcessResult> _runBenchmark(List<String> arguments) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      p.join('benchmark', 'reachability_graph_edge_benchmark.dart'),
      ...arguments,
    ], workingDirectory: Directory.current.path);
