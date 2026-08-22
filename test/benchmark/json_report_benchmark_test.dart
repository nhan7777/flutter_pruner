import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../benchmark/json_report_benchmark.dart' as benchmark;

void main() {
  test('JSON report benchmark emits reproducible aggregate metrics', () async {
    final result = await Process.run(Platform.resolvedExecutable, [
      'run',
      p.join('benchmark', 'json_report_benchmark.dart'),
      '--findings',
      '5',
      '--blockers',
      '10',
      '--warmup',
      '0',
      '--iterations',
      '1',
    ], workingDirectory: Directory.current.path);

    expect(result.exitCode, 0, reason: result.stderr as String);
    final output = jsonDecode(result.stdout as String) as Map<String, Object?>;
    expect(output['schemaVersion'], 1);
    expect(output['findings'], 5);
    expect(output['uniqueBlockers'], 10);
    expect(output['blockerFindingLinks'], 50);
    expect(output['jsonVersion'], 3);
    expect(output['affectedNodeIdsPerBlocker'], 0);
    expect(output['affectedNodeIdReferences'], 0);
    expect(output['preflightRejected'], isFalse);
    expect(output['completedIterations'], 1);
    expect(output['medianElapsedMicros'], isA<int>());
    expect(output['reportBytes'], greaterThan(0));
  }, timeout: const Timeout(Duration(minutes: 1)));

  test('counting sink counts a surrogate pair split across writes', () {
    // Catches a writer that encodes each sink write independently and counts
    // two replacement characters instead of the single scalar U+1F600.
    final sink = benchmark.Utf8CountingSink();

    sink
      ..write(String.fromCharCodes([0x41, 0xd83d]))
      ..write(String.fromCharCodes([0xde00, 0x42]));

    expect(sink.finish(), 6); // A (1) + 😀 (4) + B (1).
  });

  test('counting sink rejects every write entry point after finish', () {
    // Catches a terminal sink that guards only non-empty writes, letting an
    // empty writeAll silently accept output after the benchmark is finalized.
    final sink = benchmark.Utf8CountingSink()..write('ok');

    expect(sink.finish(), 2);
    expect(sink.finish(), 2, reason: 'finish is idempotent');
    expect(() => sink.write('later'), throwsStateError);
    expect(() => sink.writeAll(const []), throwsStateError);
    expect(() => sink.writeAll(['later'], ','), throwsStateError);
    expect(() => sink.writeln('later'), throwsStateError);
    expect(() => sink.writeCharCode(0x61), throwsStateError);
  });

  test('counting sink counts writeAll separators without retaining output', () {
    final sink = benchmark.Utf8CountingSink();

    sink.writeAll(['é', 'A', '😀'], '|');

    expect(sink.finish(), 9); // 2 + 1 + 1 + 1 + 4.
  });

  test(
    'v2 success records bounded-projection aggregates and output bytes',
    () async {
      final result = await _runBenchmark([
        '--json-version',
        '2',
        '--findings',
        '2',
        '--blockers',
        '3',
        '--affected-node-ids-per-blocker',
        '2',
        '--warmup',
        '0',
        '--iterations',
        '1',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final output =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(output, containsPair('jsonVersion', 2));
      expect(output, containsPair('affectedNodeIdsPerBlocker', 2));
      expect(output, containsPair('blockerFindingLinks', 6));
      expect(output, containsPair('affectedNodeIdReferences', 12));
      expect(output, containsPair('preflightRejected', isFalse));
      expect(output, containsPair('completedIterations', 1));
      expect(output['reportBytes'], isA<int>());
      expect(output['samples'], hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test(
    'v2 expected preflight rejection emits no fabricated sample metrics',
    () async {
      final result = await _runBenchmark([
        '--json-version',
        '2',
        '--findings',
        '251',
        '--blockers',
        '1000',
        '--expect-v2-preflight-rejection',
        '--warmup',
        '0',
        '--iterations',
        '1',
      ]);

      expect(result.exitCode, 0, reason: result.stderr as String);
      final output =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(output, containsPair('jsonVersion', 2));
      expect(output, containsPair('preflightRejected', isTrue));
      expect(output, containsPair('requestedWarmup', 0));
      expect(output, containsPair('requestedIterations', 1));
      expect(output, containsPair('completedIterations', 0));
      expect(output, containsPair('samples', isEmpty));
      expect(output['rejectionLimit'], isA<Map<String, Object?>>());
      expect(output.containsKey('medianElapsedMicros'), isFalse);
      expect(output.containsKey('minElapsedMicros'), isFalse);
      expect(output.containsKey('maxElapsedMicros'), isFalse);
      expect(output.containsKey('reportBytes'), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('rejects invalid v2 rejection expectation combinations', () async {
    final v3 = await _runBenchmark([
      '--json-version',
      '3',
      '--expect-v2-preflight-rejection',
    ]);
    final acceptedV2 = await _runBenchmark([
      '--json-version',
      '2',
      '--findings',
      '1',
      '--blockers',
      '1',
      '--expect-v2-preflight-rejection',
    ]);
    final negativeIds = await _runBenchmark([
      '--affected-node-ids-per-blocker',
      '-1',
    ]);

    expect(v3.exitCode, isNonZero);
    expect(v3.stderr, contains('--expect-v2-preflight-rejection'));
    expect(acceptedV2.exitCode, isNonZero);
    expect(acceptedV2.stderr, contains('expected JSON v2 preflight rejection'));
    expect(negativeIds.exitCode, isNonZero);
    expect(negativeIds.stderr, contains('affected-node-ids-per-blocker'));
  }, timeout: const Timeout(Duration(minutes: 1)));
}

Future<ProcessResult> _runBenchmark(List<String> arguments) => Process.run(
  Platform.resolvedExecutable,
  ['run', p.join('benchmark', 'json_report_benchmark.dart'), ...arguments],
  workingDirectory: Directory.current.path,
);
