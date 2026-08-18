import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'JSON report benchmark emits reproducible aggregate metrics',
    () async {
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
      final output =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(output['schemaVersion'], 1);
      expect(output['findings'], 5);
      expect(output['uniqueBlockers'], 10);
      expect(output['blockerFindingLinks'], 50);
      expect(output['medianElapsedMicros'], isA<int>());
      expect(output['reportBytes'], greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
