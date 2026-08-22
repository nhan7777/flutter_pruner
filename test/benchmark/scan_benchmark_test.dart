import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('redacts the project path while reporting execution phases', () async {
    final project = Directory.systemTemp.createTempSync(
      'scan_benchmark_private_',
    );
    try {
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: private_fixture_name
publish_to: none
environment:
  sdk: ^3.9.0
''');
      final packageConfig = File(
        p.join(project.path, '.dart_tool', 'package_config.json'),
      )..parent.createSync(recursive: true);
      packageConfig.writeAsStringSync('''
{
  "configVersion": 2,
  "packages": [
    {
      "name": "private_fixture_name",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
''');
      final mainFile = File(p.join(project.path, 'lib', 'main.dart'))
        ..parent.createSync(recursive: true);
      mainFile.writeAsStringSync('void main() {}\n');

      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          'run',
          'benchmark/scan_benchmark.dart',
          '--project',
          project.path,
          '--ignore-project-config',
          '--warmup',
          '0',
          '--iterations',
          '1',
          '--profile',
          '--max-report-overhead-percent',
          '100',
        ],
        workingDirectory: Directory.current.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      expect(result.stdout, isNot(contains(project.path)));
      expect(result.stdout, isNot(contains('private_fixture_name')));
      final output =
          jsonDecode(result.stdout as String) as Map<String, Object?>;
      expect(output['project'], '<redacted>');
      expect(output['projectPathIncluded'], isFalse);
      expect(output['medianReportOverheadPercent'], isA<num>());
      final sample = (output['samples'] as List).single as Map;
      expect(sample['reportElapsedMicros'], isA<int>());
      expect(sample['reportBytes'], greaterThan(0));
      expect(sample['reportOverheadPercent'], isA<num>());
      final dartProfile = sample['dartProfile'] as Map;
      expect(
        dartProfile,
        containsPair('executionContextDiscovery', {
          'elapsedMicros': isA<int>(),
          'invocations': 1,
        }),
      );
      expect(
        dartProfile,
        containsPair('directiveResolution', {
          'elapsedMicros': isA<int>(),
          'invocations': 1,
        }),
      );
      expect(
        dartProfile,
        containsPair('executionClosure', {
          'elapsedMicros': isA<int>(),
          'invocations': 4,
        }),
      );
      expect(
        dartProfile,
        containsPair('executionGraphEmission', {
          'elapsedMicros': isA<int>(),
          'invocations': 1,
        }),
      );
      expect(
        dartProfile['counters'],
        containsPair('executionClosureCandidateEdges', 0),
      );
    } finally {
      project.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 1)));
}
