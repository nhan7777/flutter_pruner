import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('scan_command_test_');
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: scan_test
environment:
  sdk: ^3.9.0
''');
    final main = File(p.join(project.path, 'lib', 'main.dart'));
    main.parent.createSync(recursive: true);
    main.writeAsStringSync('void main() {}\n');
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: false
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test(
    'requires init and suggests the short command from project cwd',
    () async {
      Directory(
        p.join(project.path, '.flutter_pruner'),
      ).deleteSync(recursive: true);

      final result = await Process.run(Platform.resolvedExecutable, [
        p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
        'scan',
      ], workingDirectory: project.path);

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('Run: flutter_pruner init'));
      expect(result.stderr, isNot(contains('--project')));
      expect(
        Directory(p.join(project.path, '.flutter_pruner')).existsSync(),
        isFalse,
      );
    },
  );

  test('always writes a unique HTML report with JSON v3 by default', () async {
    final runner = FlutterPrunerCommandRunner();

    expect(await runner.run(['scan', '--adapter', 'dart', project.path]), 0);
    expect(await runner.run(['scan', '--adapter', 'dart', project.path]), 0);

    final reports = Directory(
      p.join(project.path, '.flutter_pruner', 'reports'),
    ).listSync().whereType<File>().toList();
    expect(reports, hasLength(2));
    expect(
      reports.map((file) => p.basename(file.path)),
      everyElement(allOf(startsWith('scan-'), endsWith('.html'))),
    );
    expect(reports.map((file) => file.path).toSet(), hasLength(2));
    for (final reportFile in reports) {
      final html = reportFile.readAsStringSync();
      expect(html, startsWith('<!doctype html>'));
      final embedded = RegExp(
        r'<script id="report-data" type="application/json">(.*?)</script>',
        dotAll: true,
      ).firstMatch(html);
      expect(embedded, isNotNull);
      final report = jsonDecode(embedded!.group(1)!) as Map;
      expect(report['version'], 3);
      expect((report['run'] as Map)['command'], 'scan');
    }
  });

  test('JSON v3 records execution and excludes its own output', () async {
    final first = File(p.join(project.path, 'assets', 'first.txt'));
    first.parent.createSync(recursive: true);
    first.writeAsStringSync('duplicate bytes');
    File(
      p.join(project.path, 'assets', 'second.txt'),
    ).writeAsStringSync('duplicate bytes');
    final output = File(p.join(project.path, 'reports', 'scan.json'));
    output.parent.createSync(recursive: true);
    output.writeAsStringSync('duplicate bytes');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'duplicates',
      '--format',
      'json',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    expect(report['version'], 3);
    final presentation = report['presentation'] as Map;
    final definitions = presentation['adapters'] as List;
    expect(definitions, hasLength(1));
    final definition = definitions.single as Map;
    expect(definition['id'], 'duplicates');
    expect(definition['displayName'], 'Duplicate file detector');
    final findingDefinition = (definition['findings'] as List).single as Map;
    expect(findingDefinition['ruleId'], 'PRN-DUP-001');
    expect(findingDefinition['nodeLabel'], 'Duplicate files');
    final pass =
        ((report['execution'] as Map)['analysisPasses'] as List).single as Map;
    final adapter = (pass['adapters'] as List).single as Map;
    expect(adapter['id'], 'duplicates');
    final findings = report['findings'] as List;
    expect(findings, hasLength(1));
    final paths = ((findings.single as Map)['details'] as Map)['paths'] as List;
    expect(paths, ['assets/first.txt', 'assets/second.txt']);
    expect(paths, isNot(contains('reports/scan.json')));
    final statistics = report['statistics'] as Map;
    final measurements = statistics['measurements'] as List;
    expect(measurements, hasLength(1));
    expect(
      (measurements.single as Map)['kind'],
      'duplicate-potential-reclaimable-bytes',
    );
    expect((measurements.single as Map)['adapterId'], 'duplicates');
  });

  test('JSON v2 compatibility retains legacy summary fields', () async {
    final output = File(p.join(project.path, 'scan-v2.json'));
    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'dart',
      '--format',
      'json',
      '--json-version',
      '2',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    expect(report['version'], 2);
    expect((report['summary'] as Map).containsKey('safe'), isTrue);
    expect((report['summary'] as Map).containsKey('high'), isTrue);
  });

  test('rejects an unknown adapter before writing a report', () async {
    final output = File(p.join(project.path, 'reports', 'unknown.json'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'not_registered',
      '--format',
      'json',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 64);
    expect(output.existsSync(), isFalse);
  });

  test(
    'HTML export embeds the schema v3 report without remote assets',
    () async {
      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--project',
        project.path,
        '--adapter',
        'dart',
        '--format',
        'html',
        '--output',
        'scan.html',
      ]);

      expect(exitCode, 0);
      final output = File(
        p.join(project.path, '.flutter_pruner', 'reports', 'scan.html'),
      );
      final html = output.readAsStringSync();
      expect(html, startsWith('<!doctype html>'));
      expect(html, isNot(contains('https://')));
      final embedded = RegExp(
        r'<script id="report-data" type="application/json">(.*?)</script>',
        dotAll: true,
      ).firstMatch(html);
      expect(embedded, isNotNull);
      final report = jsonDecode(embedded!.group(1)!) as Map;
      expect(report['version'], 3);
      expect((report['run'] as Map)['command'], 'scan');
      expect((report['run'] as Map)['projectRoot'], project.path);
    },
  );

  test(
    'highlights the report path after the complete terminal report',
    () async {
      final output = File(p.join(project.path, 'reports', 'scan.html'));
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'scan',
          '--project',
          project.path,
          '--adapter',
          'duplicates',
          '--format',
          'html',
          '--output',
          output.path,
        ],
        workingDirectory: Directory.current.path,
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      );

      expect(result.exitCode, 0, reason: result.stderr as String);
      final progress = result.stderr as String;
      expect(progress, isNot(contains('Report destination:')));
      expect(progress, contains('Scanning Duplicate file detector'));
      expect(progress, contains('\x1B[3m'));
      expect(progress, contains('◆ PROJECT'));

      final terminal = result.stdout as String;
      final summaryIndex = terminal.indexOf('FLUTTER PRUNER');
      final reportIndex = terminal.indexOf('HTML REPORT READY');
      final warningIndex = terminal.indexOf('ANALYSIS LIMITED');
      expect(summaryIndex, greaterThanOrEqualTo(0));
      expect(reportIndex, greaterThan(summaryIndex));
      expect(warningIndex, greaterThanOrEqualTo(0));
      expect(reportIndex, greaterThan(warningIndex));
      expect(terminal, contains(output.path));
      expect(terminal, isNot(contains('Report written to')));
    },
  );

  test('relative config and report paths are anchored to --project', () async {
    final config = File(p.join(project.path, 'config', 'pruner.yaml'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--project',
      project.path,
      '--config',
      'config/pruner.yaml',
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      'scan.json',
    ]);

    expect(exitCode, 0);
    final output = File(
      p.join(project.path, '.flutter_pruner', 'reports', 'scan.json'),
    );
    expect(output.existsSync(), isTrue);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    final targetMatrix =
        (report['analysisCoverage'] as Map)['targetMatrix'] as Map;
    expect(targetMatrix['complete'], isTrue);
    expect(targetMatrix['source'], config.path);
    expect((report['run'] as Map)['projectRoot'], project.path);
  });

  test('rejects duplicate positional and --project selectors', () async {
    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--project',
      project.path,
      project.path,
    ]);

    expect(exitCode, 64);
  });

  test('complete target list cannot close package consumer coverage', () async {
    File(
      p.join(project.path, 'lib', 'scan_test.dart'),
    ).writeAsStringSync("export 'main.dart';\n");
    File(p.join(project.path, 'lib', 'src', 'consumer_only.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void consumerOnly() {}\n');
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: package
  public_entrypoints:
    - lib/scan_test.dart
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/scan_test.dart
''');
    final output = File(p.join(project.path, 'package-scan.json'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--project',
      project.path,
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      output.path,
    ]);

    expect(exitCode, 0);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    final coverage = report['analysisCoverage'] as Map;
    expect((coverage['targetMatrix'] as Map)['complete'], isTrue);
    expect((coverage['roots'] as Map)['complete'], isFalse);
    final tiers = (report['statistics'] as Map)['findings'] as Map;
    final byTier = tiers['byTier'] as Map;
    expect(byTier['SAFE'], 0);
    expect(byTier['HIGH'], 0);
    expect(byTier['REVIEW'], greaterThan(0));
  });

  test('package-internal JSON reports its distinct root mode', () async {
    File(
      p.join(project.path, 'lib', 'scan_test.dart'),
    ).writeAsStringSync("export 'main.dart';\n");
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    config.parent.createSync(recursive: true);
    config.writeAsStringSync('''
version: 1
analysis:
  mode: package-internal
  public_entrypoints:
    - lib/scan_test.dart
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/scan_test.dart
''');
    final output = File(p.join(project.path, 'package-internal-scan.json'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--project',
      project.path,
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      output.path,
    ]);

    expect(exitCode, 0);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    final coverage = report['analysisCoverage'] as Map;
    expect(coverage['analysisMode'], 'package-internal');
    expect((coverage['roots'] as Map)['mode'], 'packageInternal');
  });

  test('explicit human reports retain ANSI styling', () async {
    final output = File(p.join(project.path, 'scan.txt'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'dart',
      '--format',
      'human',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report = output.readAsStringSync();
    expect(report, contains('\x1B['));
    expect(report, contains('FLUTTER PRUNER'));
    expect(report, isNot(contains('Adapter       Role')));
    expect(report, isNot(contains('Measurements (rows are not additive)')));
    expect(report, isNot(contains('Run:')));
  });

  test('verbose human output includes diagnostics', () async {
    final output = File(p.join(project.path, 'scan-verbose.txt'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      '--verbose',
      'scan',
      '--adapter',
      'dart',
      '--format',
      'human',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report = output.readAsStringSync();
    expect(report, contains('DIAGNOSTICS'));
    expect(report, contains('Adapter       Role'));
    expect(report, contains('Measurements (rows are not additive)'));
    expect(report, contains('Run:'));
  });
}
