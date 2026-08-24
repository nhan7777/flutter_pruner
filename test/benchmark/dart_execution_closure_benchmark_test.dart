import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('closure benchmark reports deterministic semantic counts', () async {
    final result = await _runBenchmark([
      '--small-contexts',
      '2',
      '--large-contexts',
      '4',
      '--libraries',
      '3',
      '--warmup',
      '0',
      '--iterations',
      '1',
    ]);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(output['schemaVersion'], 1);
    expect(output['smallContextCount'], 2);
    expect(output['largeContextCount'], 4);
    expect(output['libraryCount'], 3);
    expect(output['smallDirectiveEdgeCount'], 4);
    expect(output['largeDirectiveEdgeCount'], 8);
    expect(output['smallCandidateEdgeCount'], isA<int>());
    expect(output['largeCandidateEdgeCount'], isA<int>());
    expect(output['candidateGrowthRatio'], isA<num>());
    expect(output['medianSmallMicros'], isA<int>());
    expect(output['medianLargeMicros'], isA<int>());
    expect(output['samples'], hasLength(1));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test(
    'closure benchmark returns non-zero when candidate gate fails',
    () async {
      final result = await _runBenchmark([
        '--small-contexts',
        '2',
        '--large-contexts',
        '4',
        '--libraries',
        '3',
        '--warmup',
        '0',
        '--iterations',
        '1',
        '--max-candidate-growth-ratio',
        '0',
      ]);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('Closure candidate growth'));
      expect(
        jsonDecode(result.stdout as String),
        containsPair('largeContextCount', 4),
      );
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

Future<ProcessResult> _runBenchmark(List<String> arguments) =>
    Process.run(Platform.resolvedExecutable, [
      'run',
      p.join('benchmark', 'dart_execution_closure_benchmark.dart'),
      ...arguments,
    ], workingDirectory: Directory.current.path);
