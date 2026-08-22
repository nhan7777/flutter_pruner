import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/scan_command.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'report_output_collision_fixture.dart';

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
    final packageConfig = File(
      p.join(project.path, '.dart_tool', 'package_config.json'),
    );
    packageConfig.parent.createSync(recursive: true);
    packageConfig.writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"scan_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
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

  for (final variant in ReportOutputAliasVariant.values) {
    test(
      'scan rejects report collision through ${variant.name} identity',
      () async {
        final fixture = ReportOutputCollisionFixture.create(project, variant);
        addTearDown(fixture.dispose);

        final result = await _runCaptured(FlutterPrunerCommandRunner(), [
          'scan',
          '--adapter',
          'dart',
          '--format',
          'json',
          '--output',
          fixture.requestedOutputPath,
          fixture.projectSelectionPath,
        ]);

        expect(result.exitCode, 1);
        if (variant == ReportOutputAliasVariant.finalSymlink) {
          expect(result.stderr, contains('category=collision'));
        } else {
          expect(result.stderr, contains('excluded by project path policy'));
        }
        expect(result.stderr, isNot(contains('Scanning Dart')));
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('REPORT READY')),
        );
        fixture.expectRetained();
      },
    );
  }

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
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('always writes a unique HTML report with JSON v3 by default', () async {
    final context = await ProjectContext.load(project);
    final owner = DartPackageOwnership.discover(
      context,
    ).ownerOf(p.join(project.path, 'lib', 'main.dart'));
    expect(owner.ownership, DartSourceOwnership.selectedPackage);
    expect(owner.packageName, 'scan_test');
    expect(
      owner.packageRoot,
      p.normalize(Directory(project.path).resolveSymbolicLinksSync()),
    );
    final runner = FlutterPrunerCommandRunner();

    expect(await runner.run(['scan', '--adapter', 'dart', project.path]), 0);
    expect(await runner.run(['scan', '--adapter', 'dart', project.path]), 0);

    final reports = Directory(
      p.join(project.path, '.flutter_pruner', 'reports', 'store', 'objects'),
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
    expect(
      Directory(
        p.join(project.path, '.flutter_pruner', 'reports', 'store', 'commits'),
      ).listSync().whereType<File>(),
      hasLength(2),
    );
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

  test(
    'JSON v3 reports handwritten gen source and hides generated suffix',
    () async {
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
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
      File(p.join(project.path, 'lib', 'gen', 'unused.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void handwrittenCandidate() {}\n');
      File(p.join(project.path, 'lib', 'gen', 'actual.g.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('class GeneratedArtifact {}\n');
      final output = File(p.join(project.path, 'generated-path-scan.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      expect(report['version'], 3);
      final findings = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final handwritten = findings.singleWhere(
        (finding) =>
            ((finding['node']! as Map<String, Object?>)['id'] as String) ==
            'dart:scan_test/lib/gen/unused.dart#handwrittenCandidate',
      );
      expect(handwritten['reportingAdapterId'], 'dart');
      expect(handwritten['confidence'], 'SAFE');
      expect(handwritten['applyEligible'], isTrue);
      expect(handwritten['proposedAction'], 'Remove declaration');
      expect(handwritten['predicates'], {
        'ruleAllowsAutoFix': true,
        'unreachableAcrossAllTargets': true,
        'notRetained': true,
        'noDynamicBlockers': true,
        'notProtected': true,
        'noPublicApiRisk': true,
        'hasDeterministicInverse': true,
        'analysisCoverageComplete': true,
        'actionSupported': true,
      });
      expect(
        handwritten['node'],
        containsPair('projectRelativeOrigin', 'lib/gen/unused.dart'),
      );
      expect(
        findings.map(
          (finding) => (finding['node']! as Map<String, Object?>)['id'],
        ),
        isNot(contains('dart-generated:scan_test/lib/gen/actual.g.dart')),
      );
      expect(
        findings.map(
          (finding) =>
              (finding['node']!
                  as Map<String, Object?>)['projectRelativeOrigin'],
        ),
        isNot(contains('lib/gen/actual.g.dart')),
      );
      final execution = report['execution']! as Map<String, Object?>;
      final pass =
          (execution['analysisPasses']! as List<Object?>).single
              as Map<String, Object?>;
      final graph = pass['graph']! as Map<String, Object?>;
      expect(graph['danglingEdges'], 0);
      expect(graph['danglingRoots'], 0);
    },
  );

  test('JSON v3 fails closed for an auxiliary-only dangling root', () async {
    File(
      p.join(project.path, '.flutter_pruner', 'config.yaml'),
    ).writeAsStringSync('''
version: 1
analysis:
  mode: package-internal
  public_entrypoints:
    - lib/public.dart
target_matrix:
  complete: true
  targets:
    - name: package
      platform: android
      entrypoint: lib/public.dart
''');
    File(p.join(project.path, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - lib/public.dart
''');
    File(
      p.join(project.path, 'lib', 'public.dart'),
    ).writeAsStringSync("export 'unused.dart';\n");
    File(
      p.join(project.path, 'lib', 'unused.dart'),
    ).writeAsStringSync('void removalCandidate() {}\n');
    final output = File(p.join(project.path, 'aux-dangling.json'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report = jsonDecode(output.readAsStringSync()) as Map;
    final coverage = report['analysisCoverage'] as Map;
    final auxiliaryTargets = coverage['auxiliaryExecutionTargets'] as List;
    expect(auxiliaryTargets, hasLength(1));
    final auxiliaryId = (auxiliaryTargets.single as Map)['id'] as String;
    expect(auxiliaryId, startsWith('aux:external:'));
    final pass =
        ((report['execution'] as Map)['analysisPasses'] as List).single as Map;
    final graph = pass['graph'] as Map;
    expect(graph['danglingRoots'], greaterThan(0));
    final integrity = graph['integrityByExecutionTarget'] as Map;
    expect((integrity[auxiliaryId] as Map)['danglingRoots'], 1);
    final byTier =
        ((report['statistics'] as Map)['findings'] as Map)['byTier'] as Map;
    expect(byTier['SAFE'], 0);
    expect(byTier['HIGH'], 0);
  });

  test(
    'JSON v3 fails closed for a broken transitive out-of-tree dependency',
    () async {
      final externalRoot = Directory.systemTemp.createTempSync(
        'scan_external_closure_test_',
      );
      addTearDown(() => externalRoot.deleteSync(recursive: true));
      final directRoot = Directory(p.join(externalRoot.path, 'direct'));
      final indirectRoot = Directory(p.join(externalRoot.path, 'indirect'));
      File(p.join(directRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: direct_pkg
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  indirect_pkg:
    path: ${p.relative(indirectRoot.path, from: directRoot.path)}
''');
      File(p.join(directRoot.path, 'lib', 'direct.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:indirect_pkg/indirect.dart';

void callIndirect() => broken();
''');
      File(p.join(indirectRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: indirect_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(indirectRoot.path, 'lib', 'indirect.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void broken( {\n');
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: scan_test
environment:
  sdk: ^3.9.0
dependencies:
  direct_pkg:
    path: ${p.relative(directRoot.path, from: project.path)}
''');
      File(
        p.join(project.path, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"scan_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"direct_pkg","rootUri":"${directRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"indirect_pkg","rootUri":"${indirectRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(project.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'package:direct_pkg/direct.dart';

void main() => callIndirect();
''');
      File(
        p.join(project.path, 'lib', 'unused.dart'),
      ).writeAsStringSync('void removalCandidate() {}\n');
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
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
      final output = File(p.join(project.path, 'external-error.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      final blockers = (report['blockers']! as Map<String, Object?>).values
          .cast<Map<String, Object?>>();
      final blocker = blockers.singleWhere(
        (blocker) =>
            blocker['reason'] ==
            'external package closure could not be inspected',
      );
      expect(blocker.containsKey('sourceNodeId'), isFalse);
      expect(blocker['affectedNamespace'], 'dart:scan_test/');
      final statistics = report['statistics']! as Map<String, Object?>;
      final findingStatistics = statistics['findings']! as Map<String, Object?>;
      final byTier = findingStatistics['byTier']! as Map<String, Object?>;
      expect(byTier['SAFE'], 0);
      expect(byTier['HIGH'], 0);
      expect(byTier['REVIEW'], greaterThan(0));
    },
  );

  test(
    'asset scan keeps non-selected consumers source-less and blocked',
    () async {
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: scan_test
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/used.png
    - assets/unused.png
''');
      File(
        p.join(project.path, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"scan_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_asset_part","rootUri":"../nested_exact/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_asset_part","rootUri":"../nested_unknown/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
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
      File(p.join(project.path, 'lib', 'main.dart')).writeAsStringSync('''
import 'package:external_asset_part/exact.dart';
part 'package:conflicting_asset_part/dynamic.dart';

void main() {}
''');
      File(p.join(project.path, 'assets', 'used.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('used');
      File(p.join(project.path, 'assets', 'unused.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('unused');
      File(p.join(project.path, 'nested_exact', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: external_asset_part
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(project.path, 'nested_exact', 'lib', 'exact.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
abstract final class ExternalAssets {
  static void asset(String path) {}
}

void externalAssetConsumer() {
  ExternalAssets.asset('assets/used.png');
}
''');
      File(p.join(project.path, 'nested_unknown', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: actual_asset_part
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(project.path, 'nested_unknown', 'lib', 'dynamic.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
part of 'package:scan_test/main.dart';

void unknownAssetConsumer(String path) {
  Image.asset(path);
}
''');
      final output = File(p.join(project.path, 'asset-ownership.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'assets',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      final blockers = (report['blockers']! as Map<String, Object?>).values
          .cast<Map<String, Object?>>();
      final exactBlocker = blockers.singleWhere(
        (blocker) =>
            blocker['reason'] ==
            'non-selected Dart source can address a selected asset',
      );
      expect(exactBlocker.containsKey('sourceNodeId'), isFalse);
      expect(exactBlocker['affectedNodeIds'], [
        'asset:scan_test/assets/used.png',
      ]);
      final dynamicBlocker = blockers.singleWhere(
        (blocker) =>
            blocker['reason'] ==
            'non-selected Dart source may address selected assets',
      );
      expect(dynamicBlocker.containsKey('sourceNodeId'), isFalse);
      expect(dynamicBlocker['affectedNamespace'], 'asset:scan_test/');
      final statistics = report['statistics']! as Map<String, Object?>;
      final findingStatistics = statistics['findings']! as Map<String, Object?>;
      final byTier = findingStatistics['byTier']! as Map<String, Object?>;
      expect(byTier['SAFE'], 0);
      expect(byTier['HIGH'], 0);
      expect(byTier['REVIEW'], greaterThanOrEqualTo(2));
    },
  );

  test(
    'standard executable roots retain declaration and asset at command level',
    () async {
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: scan_test
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/root-only.png
''');
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
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
      File(p.join(project.path, 'lib', 'root_only.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
void onlyFromTool() {
  Image.asset('assets/root-only.png');
}
''');
      File(p.join(project.path, 'tool', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/root_only.dart';

void main() => onlyFromTool();
''');
      File(p.join(project.path, 'assets', 'root-only.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('root-only');
      final output = File(p.join(project.path, 'root-only.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'dart',
        '--adapter',
        'assets',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      final coverage = report['analysisCoverage']! as Map<String, Object?>;
      final auxiliaryTargets =
          (coverage['auxiliaryExecutionTargets']! as List<Object?>)
              .cast<Map<String, Object?>>();
      expect(
        auxiliaryTargets,
        contains(
          predicate<Map<String, Object?>>(
            (target) =>
                target['domain'] == 'runtime' &&
                (target['id'] as String).contains('tool/main.dart'),
          ),
        ),
      );
      final findings = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>();
      for (final nodeId in const [
        'dart:scan_test/lib/root_only.dart#onlyFromTool',
        'asset:scan_test/assets/root-only.png',
      ]) {
        final finding = findings.singleWhere(
          (finding) =>
              (finding['node']! as Map<String, Object?>)['id'] == nodeId,
        );
        expect(finding['confidence'], 'REVIEW', reason: nodeId);
        expect(finding['applyEligible'], isFalse, reason: nodeId);
        expect(finding.containsKey('proposedAction'), isFalse, reason: nodeId);
      }
      final dartFinding = findings.singleWhere(
        (finding) =>
            (finding['node']! as Map<String, Object?>)['id'] ==
            'dart:scan_test/lib/root_only.dart#onlyFromTool',
      );
      expect(
        (dartFinding['predicates']! as Map<String, Object?>)['notRetained'],
        isFalse,
      );
      expect(
        dartFinding['auxiliaryRetainedIn'],
        contains('aux:runtime:executable:tool/main.dart:incomplete'),
      );
      final pass =
          ((report['execution']! as Map<String, Object?>)['analysisPasses']!
                      as List<Object?>)
                  .single
              as Map<String, Object?>;
      final graph = pass['graph']! as Map<String, Object?>;
      expect(graph['danglingEdges'], 0);
      expect(graph['danglingRoots'], 0);
    },
  );

  test(
    'mixed spawnUri provenance retains every target and conditional branch',
    () async {
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/android.dart
    - name: ios
      platform: ios
      entrypoint: lib/ios.dart
''');
      File(p.join(project.path, 'lib', 'android.dart')).writeAsStringSync('''
import 'dart:isolate';
void main() => launch();
void launch() {
  Isolate.spawnUri(Uri.parse('worker.dart'), const [], null);
}
''');
      File(p.join(project.path, 'lib', 'ios.dart')).writeAsStringSync('''
import 'android.dart';
void main() => launch();
''');
      File(p.join(project.path, 'tool', 'launcher.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void main() => launch();
''');
      File(p.join(project.path, 'test', 'launcher_test.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void exercise() => launch();
''');
      File(p.join(project.path, 'bin', 'launcher.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import '../lib/android.dart';
void main() => launch();
''');
      File(p.join(project.path, 'lib', 'worker.dart')).writeAsStringSync('''
import 'branch_default.dart'
  if (dart.library.html) 'branch_web.dart'
  if (dart.library.io) 'branch_io.dart';
void main() => selectedBranch();
''');
      for (final branch in const [
        'branch_default.dart',
        'branch_web.dart',
        'branch_io.dart',
      ]) {
        File(
          p.join(project.path, 'lib', branch),
        ).writeAsStringSync('void selectedBranch() {}\n');
      }
      final output = File(p.join(project.path, 'mixed-provenance.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      final coverage = report['analysisCoverage']! as Map<String, Object?>;
      final spawnTargets =
          (coverage['auxiliaryExecutionTargets']! as List<Object?>)
              .cast<Map<String, Object?>>()
              .where(
                (target) => (target['reason'] as String).contains('spawnUri'),
              )
              .toList();
      expect(
        spawnTargets
            .map((target) => target['sourceConfiguredTarget'])
            .whereType<Map<String, Object?>>()
            .map((target) => target['name'])
            .toSet(),
        {'android', 'ios'},
      );
      expect(
        spawnTargets,
        contains(
          predicate<Map<String, Object?>>(
            (target) =>
                target['environmentComplete'] == false &&
                !target.containsKey('sourceConfiguredTarget'),
          ),
        ),
      );
      final findings = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>();
      for (final branch in const [
        'branch_default.dart',
        'branch_web.dart',
        'branch_io.dart',
      ]) {
        final id = 'dart:scan_test/lib/$branch#selectedBranch';
        final matching = findings.where(
          (finding) => (finding['node']! as Map<String, Object?>)['id'] == id,
        );
        if (matching.isEmpty) continue;
        final finding = matching.single;
        expect(finding['confidence'], 'REVIEW', reason: branch);
        expect(finding['applyEligible'], isFalse, reason: branch);
        expect(finding.containsKey('proposedAction'), isFalse, reason: branch);
        expect(
          (finding['predicates']! as Map<String, Object?>)['notRetained'],
          isFalse,
          reason: branch,
        );
      }
    },
  );

  test(
    'generated executable retains declaration and asset without dangling IDs',
    () async {
      File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: scan_test
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/generated-only.png
''');
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
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
      File(
        p.join(project.path, '.dart_tool', 'package_config.json'),
      ).writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"scan_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter","rootUri":"../flutter_stub/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(project.path, 'flutter_stub', 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('name: flutter\nenvironment:\n  sdk: ^3.9.0\n');
      File(p.join(project.path, 'flutter_stub', 'lib', 'widgets.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
class Image {
  const Image.asset(String path);
}
''');
      File(
        p.join(project.path, 'lib', 'generated_only.dart'),
      ).writeAsStringSync('void generatedOnly() {}\n');
      File(p.join(project.path, 'tool', 'launcher.g.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/widgets.dart';
import '../lib/generated_only.dart';
void main() {
  generatedOnly();
  Image.asset('assets/generated-only.png');
}
''');
      File(p.join(project.path, 'assets', 'generated-only.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('generated-only');
      final output = File(p.join(project.path, 'generated-executable.json'));

      final exitCode = await FlutterPrunerCommandRunner().run([
        'scan',
        '--adapter',
        'dart',
        '--adapter',
        'assets',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      expect(exitCode, 0);
      final report =
          jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
      final findings = (report['findings']! as List<Object?>)
          .cast<Map<String, Object?>>();
      for (final id in const [
        'dart:scan_test/lib/generated_only.dart#generatedOnly',
        'asset:scan_test/assets/generated-only.png',
      ]) {
        final finding = findings.singleWhere(
          (finding) => (finding['node']! as Map<String, Object?>)['id'] == id,
        );
        expect(finding['confidence'], 'REVIEW', reason: id);
        expect(finding['applyEligible'], isFalse, reason: id);
        expect(finding.containsKey('proposedAction'), isFalse, reason: id);
      }
      final pass =
          ((report['execution']! as Map<String, Object?>)['analysisPasses']!
                      as List<Object?>)
                  .single
              as Map<String, Object?>;
      final graph = pass['graph']! as Map<String, Object?>;
      expect(graph['danglingEdges'], 0);
      expect(graph['danglingRoots'], 0);
    },
  );

  test('analyzer-excluded configured generated entrypoint outside standard '
      'surfaces scans with zero dangling roots', () async {
    File(
      p.join(project.path, '.flutter_pruner', 'config.yaml'),
    ).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: generated
      platform: android
      entrypoint: scripts/configured_main.g.dart
''');
    File(p.join(project.path, 'analysis_options.yaml')).writeAsStringSync('''
analyzer:
  exclude:
    - scripts/**
''');
    File(p.join(project.path, 'scripts', 'configured_main.g.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    final output = File(p.join(project.path, 'configured-generated.json'));

    final exitCode = await FlutterPrunerCommandRunner().run([
      'scan',
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      output.path,
      project.path,
    ]);

    expect(exitCode, 0);
    final report =
        jsonDecode(output.readAsStringSync()) as Map<String, Object?>;
    final pass =
        ((report['execution']! as Map<String, Object?>)['analysisPasses']!
                    as List<Object?>)
                .single
            as Map<String, Object?>;
    final graph = pass['graph']! as Map<String, Object?>;
    expect(graph['danglingEdges'], 0);
    expect(graph['danglingRoots'], 0);
    expect(
      (report['findings']! as List<Object?>).cast<Map<String, Object?>>().map(
        (finding) => (finding['node']! as Map<String, Object?>)['id'],
      ),
      isNot(contains(contains('scripts/configured_main.g.dart'))),
    );
  });

  test(
    'configured generated report output is rejected before overwrite',
    () async {
      File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      ).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: generated
      platform: android
      entrypoint: scripts/report.g.dart
''');
      const original = 'void main() {}\n';
      final output = File(p.join(project.path, 'scripts', 'report.g.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(original);
      final originalBytes = output.readAsBytesSync();
      final originalMode = output.statSync().mode & 0xfff;
      final originalSha256 = sha256.convert(originalBytes).toString();

      final result = await _runCaptured(FlutterPrunerCommandRunner(), [
        'scan',
        '--adapter',
        'dart',
        '--format',
        'json',
        '--output',
        output.path,
        project.path,
      ]);

      final retainedBytes = output.readAsBytesSync();
      expect(retainedBytes, orderedEquals(originalBytes));
      expect(output.statSync().mode & 0xfff, originalMode);
      expect(sha256.convert(retainedBytes).toString(), originalSha256);
      expect(result.exitCode, 1);
      expect(result.stderr, contains('excluded by project path policy'));
      expect(result.stderr, isNot(contains('Scanning Dart')));
      expect(
        '${result.stdout}\n${result.stderr}',
        isNot(contains('REPORT READY')),
      );
      expect(_transactionArtifacts(output), isEmpty);
    },
  );

  test('JSON v2 compatibility retains legacy summary fields', () async {
    final output = File(p.join(project.path, 'scan-v2.json'));
    final events = <String>[];
    final formatter = _WriteToOnlyJsonFormatter(version: 2, events: events);
    final runner = FlutterPrunerCommandRunner(
      scanCommandFactory: () => ScanCommand(
        jsonFormatterFactory: (version) {
          expect(version, 2);
          return formatter;
        },
      ),
    );

    final exitCode = await runner.run([
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
    expect(DateTime.parse(report['timestamp'] as String).isUtc, isTrue);
    expect(
      ((report['analysisCoverage'] as Map)['targetMatrix'] as Map)['source'],
      p.join(project.path, '.flutter_pruner', 'config.yaml'),
    );
    expect(output.readAsBytesSync().last, isNot(0x0a));
    expect(formatter.formatCalls, 0);
    expect(formatter.writeToCalls, 1);
    expect(formatter.preflightCalls, 2);
    expect(_transactionArtifacts(output), isEmpty);
  });

  test(
    'v2 preflight rejects before staging and preserves existing bytes',
    () async {
      final output = File(p.join(project.path, 'scan-v2.json'));
      final formatter = _ControlledJsonFormatter(
        version: 2,
        preflightFailure: const JsonV2CompatibilityLimitException(
          limitName: 'maxBlockerReferences',
          limit: 0,
          observed: 1,
        ),
      );

      final result = await _runCaptured(
        _runnerWith(formatter: formatter),
        _jsonScanArgs(project, output, version: 2),
      );

      expect(result.exitCode, 1);
      expect(output.existsSync(), isFalse);
      expect(formatter.writeToCalls, 0);
      expect(result.stderr, contains('Use --json-version 3.'));
      expect(result.stdout, isNot(contains('REPORT READY')));
      expect(_transactionArtifacts(output), isEmpty);
    },
  );

  test(
    'formatter writeTo programming error exits 70 after clean recovery',
    () async {
      final output = File(p.join(project.path, 'scan-v2.json'));
      final formatter = _ControlledJsonFormatter(
        version: 2,
        writeFailure: StateError('formatter callback failed'),
      );

      final result = await _runCaptured(
        _runnerWith(formatter: formatter),
        _jsonScanArgs(project, output, version: 2),
      );

      expect(result.exitCode, 70);
      expect(output.existsSync(), isTrue);
      expect(output.lengthSync(), 0);
      expect(File('${output.path}.commit.json').existsSync(), isFalse);
      expect(formatter.preflightCalls, 1);
      expect(formatter.writeToCalls, 1);
      expect(result.stderr, contains('formatter callback failed'));
      expect(result.stderr, isNot(contains('report was not saved')));
      expect(result.stdout, isNot(contains('REPORT READY')));
      expect(_transactionArtifacts(output), isEmpty);
    },
  );

  test('output sink write failure remains persistence exit 1', () async {
    final output = File(p.join(project.path, 'scan-v2.json'));
    final formatter = _ControlledJsonFormatter(
      version: 2,
      payload: _completeReport,
    );

    final result = await _runCaptured(
      _runnerWith(
        formatter: formatter,
        reportBackend: _WriteFailingReportObjectBackend(
          createIoReportObjectBackend(),
        ),
      ),
      _jsonScanArgs(project, output, version: 2),
    );

    expect(result.exitCode, 1);
    expect(output.existsSync(), isTrue);
    expect(output.lengthSync(), 0);
    expect(formatter.preflightCalls, 1);
    expect(formatter.writeToCalls, 1);
    expect(result.stderr, contains('report was not saved'));
    expect(result.stderr, contains('phase=writeObject'));
    expect(result.stderr, isNot(contains('Internal error')));
    expect(result.stdout, isNot(contains('REPORT READY')));
    expect(File('${output.path}.commit.json').existsSync(), isFalse);
  });

  test(
    'formatter error remains primary when object close also fails',
    () async {
      final output = File(p.join(project.path, 'scan-v2.json'));
      final formatter = _ControlledJsonFormatter(
        version: 2,
        writeFailure: StateError('formatter callback failed'),
      );

      final result = await _runCaptured(
        _runnerWith(
          formatter: formatter,
          reportBackend: _CloseFailingReportObjectBackend(
            createIoReportObjectBackend(),
          ),
        ),
        _jsonScanArgs(project, output, version: 2),
      );

      expect(result.exitCode, 70);
      expect(result.stderr, contains('formatter callback failed'));
      expect(result.stderr, isNot(contains('close failure')));
      expect(result.stderr, isNot(contains('report was not saved')));
      expect(result.stdout, isNot(contains('REPORT READY')));
      expect(File('${output.path}.commit.json').existsSync(), isFalse);
    },
  );

  test(
    'blocked child process scan barrier preserves foreign destination',
    () async {
      final output = File(p.join(project.path, 'barrier-report.json'));
      const foreignBytes = <int>[0, 255, 1, 254, 2, 253];
      final barrierRoot = await Directory.systemTemp.createTemp(
        'flutter_pruner_scan_report_barrier_',
      );
      addTearDown(() async {
        if (barrierRoot.existsSync()) {
          await barrierRoot.delete(recursive: true);
        }
      });
      final ready = File(p.join(barrierRoot.path, 'ready.json'));
      final release = File(p.join(barrierRoot.path, 'release'));
      final helper = p.absolute('test/cli/report_persistence_race_child.dart');
      final child = await Process.start(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        helper,
        project.path,
        output.path,
        ready.path,
        release.path,
      ], workingDirectory: Directory.current.path);
      final childStdout = child.stdout.transform(utf8.decoder).join();
      final childStderr = child.stderr.transform(utf8.decoder).join();
      final childExit = child.exitCode;
      var childFinished = false;
      int? earlyExitCode;
      unawaited(
        childExit.then((code) {
          childFinished = true;
          earlyExitCode = code;
        }),
      );
      addTearDown(() async {
        if (!childFinished) child.kill();
        await childExit;
      });

      await _waitForBarrierFile(
        ready,
        childFinished: () => childFinished,
        earlyExitCode: () => earlyExitCode,
      );
      final barrier = jsonDecode(ready.readAsStringSync()) as Map;
      expect(barrier['phase'], 'create-exclusive');
      expect(
        p.basename(barrier['destination'] as String),
        output.uri.pathSegments.last,
      );
      output.writeAsBytesSync(foreignBytes);
      final foreignMode = output.statSync().mode & 0xfff;
      final foreignSha256 = sha256.convert(foreignBytes).toString();
      release.writeAsStringSync('continue', flush: true);

      final exitCode = await childExit.timeout(const Duration(seconds: 30));
      final stdout = await childStdout;
      final stderr = await childStderr;
      final retainedBytes = output.readAsBytesSync();

      expect(
        <String, Object?>{
          'exitCode': exitCode,
          'bytesRetained':
              base64Encode(retainedBytes) == base64Encode(foreignBytes),
          'sha256Retained':
              sha256.convert(retainedBytes).toString() == foreignSha256,
          'modeRetained': output.statSync().mode & 0xfff == foreignMode,
          'collision': stderr.contains('phase=createObject'),
          'reportedReady': stdout.contains('REPORT READY'),
        },
        <String, Object?>{
          'exitCode': 1,
          'bytesRetained': true,
          'sha256Retained': true,
          'modeRetained': true,
          'collision': true,
          'reportedReady': false,
        },
      );
    },
  );

  test('explicit resolve failure happens before project loading', () async {
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('not: [valid');
    final blockedParent = Link(p.join(project.path, 'blocked-output'))
      ..createSync(p.join(project.path, 'missing-target'));
    final output = File(p.join(blockedParent.path, 'scan-v2.json'));

    final result = await _runCaptured(
      _runnerWith(
        formatter: _ControlledJsonFormatter(
          version: 2,
          payload: _completeReport,
        ),
      ),
      _jsonScanArgs(project, output, version: 2),
    );

    expect(result.exitCode, 1);
    expect(output.existsSync(), isFalse);
    expect(result.stderr, contains('report was not saved'));
    expect(result.stderr, isNot(contains('Could not parse pubspec.yaml')));
    expect(result.stdout, isNot(contains('REPORT READY')));
  });

  test('unexpected formatter failure retains runner exit 70', () async {
    final output = File(p.join(project.path, 'scan-v2.json'));
    final formatter = _ControlledJsonFormatter(
      version: 2,
      preflightFailure: StateError('formatter programming failure'),
    );

    final result = await _runCaptured(
      _runnerWith(formatter: formatter),
      _jsonScanArgs(project, output, version: 2),
    );

    expect(result.exitCode, 70);
    expect(output.existsSync(), isFalse);
    expect(result.stderr, contains('formatter programming failure'));
    expect(result.stdout, isNot(contains('REPORT READY')));
  });

  test(
    'explicit regular-file symlink excludes alias and target then preserves link',
    () async {
      final source = File(p.join(project.path, 'assets', 'source.txt'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('duplicate candidate bytes');
      final target = File(p.join(project.path, 'assets', 'report.json'));
      target.writeAsStringSync('duplicate candidate bytes');
      final alias = Link(p.join(project.path, 'report-link.json'))
        ..createSync(target.path);

      final result = await _runCaptured(FlutterPrunerCommandRunner(), [
        'scan',
        '--adapter',
        'duplicates',
        '--format',
        'json',
        '--output',
        alias.path,
        project.path,
      ]);

      expect(result.exitCode, 1);
      expect(
        FileSystemEntity.typeSync(alias.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(
        alias.resolveSymbolicLinksSync(),
        target.resolveSymbolicLinksSync(),
      );
      expect(target.readAsStringSync(), 'duplicate candidate bytes');
      expect(result.stderr, contains('category=collision'));
      expect(result.stdout, isNot(contains('REPORT READY')));
    },
  );

  test('reserved managed report symlink remains rejected', () async {
    final outside = Directory.systemTemp.createTempSync(
      'scan_command_report_symlink_',
    );
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });
    Link(
      p.join(project.path, '.flutter_pruner', 'reports'),
    ).createSync(outside.path);

    final result = await _runCaptured(FlutterPrunerCommandRunner(), [
      'scan',
      '--adapter',
      'dart',
      '--format',
      'json',
      '--output',
      'scan.json',
      project.path,
    ]);

    expect(result.exitCode, 64);
    expect(result.stderr, contains('reports path contains a symlink'));
    expect(outside.listSync(), isEmpty);
    expect(result.stdout, isNot(contains('REPORT READY')));
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
      expect(output.existsSync(), isTrue);
      expect(_transactionArtifacts(output), isEmpty);
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

const String _completeReport = '{"complete":true}';

Future<void> _waitForBarrierFile(
  File readyFile, {
  required bool Function() childFinished,
  required int? Function() earlyExitCode,
}) async {
  final timeout = Stopwatch()..start();
  while (!readyFile.existsSync()) {
    if (childFinished()) {
      throw StateError(
        'Child process exited before the barrier: ${earlyExitCode()}.',
      );
    }
    if (timeout.elapsed >= const Duration(seconds: 30)) {
      throw TimeoutException('Timed out waiting for the child barrier.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

FlutterPrunerCommandRunner _runnerWith({
  required JsonFormatter formatter,
  ReportObjectBackend? reportBackend,
}) => FlutterPrunerCommandRunner(
  scanCommandFactory: () => ScanCommand(
    reportBackend: reportBackend,
    jsonFormatterFactory: (_) => formatter,
  ),
);

List<String> _jsonScanArgs(
  Directory project,
  File output, {
  required int version,
}) => [
  'scan',
  '--adapter',
  'dart',
  '--format',
  'json',
  '--json-version',
  '$version',
  '--output',
  output.path,
  project.path,
];

Future<_CapturedRun> _runCaptured(
  FlutterPrunerCommandRunner runner,
  List<String> arguments,
) async {
  final capturedStdout = _RecordingStdout();
  final capturedStderr = _RecordingStdout();
  final exitCode = await IOOverrides.runZoned(
    () => runner.run(arguments),
    stdout: () => capturedStdout,
    stderr: () => capturedStderr,
  );
  await capturedStdout.close();
  await capturedStderr.close();
  return _CapturedRun(
    exitCode: exitCode,
    stdout: capturedStdout.text,
    stderr: capturedStderr.text,
  );
}

List<String> _transactionArtifacts(File destination) {
  if (!destination.parent.existsSync()) return const [];
  final prefix = '.${p.basename(destination.path)}.flutter_pruner.';
  return destination.parent
      .listSync(followLinks: false)
      .where((entity) => p.basename(entity.path).startsWith(prefix))
      .map((entity) => p.normalize(entity.resolveSymbolicLinksSync()))
      .toList()
    ..sort();
}

final class _CapturedRun {
  const _CapturedRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

final class _WriteToOnlyJsonFormatter extends JsonFormatter {
  _WriteToOnlyJsonFormatter({required super.version, required this.events});

  final List<String> events;
  int formatCalls = 0;
  int writeToCalls = 0;
  int preflightCalls = 0;

  @override
  JsonV2ProjectionSize? preflight(RunReport report) {
    preflightCalls++;
    events.add('preflight');
    return super.preflight(report);
  }

  @override
  String format(RunReport report) {
    formatCalls++;
    throw StateError('scan persistence must not call format()');
  }

  @override
  void writeTo(RunReport report, StringSink sink) {
    writeToCalls++;
    events.add('writeTo');
    super.writeTo(report, sink);
  }
}

final class _ControlledJsonFormatter extends JsonFormatter {
  _ControlledJsonFormatter({
    required super.version,
    this.payload = _completeReport,
    this.preflightFailure,
    this.writeFailure,
  });

  final String payload;
  final Object? preflightFailure;
  final Object? writeFailure;
  int writeToCalls = 0;
  int preflightCalls = 0;

  @override
  JsonV2ProjectionSize? preflight(RunReport report) {
    preflightCalls++;
    if (preflightFailure case final failure?) _throwInjected(failure);
    return super.preflight(report);
  }

  @override
  String format(RunReport report) {
    throw StateError('scan persistence must not call format()');
  }

  @override
  void writeTo(RunReport report, StringSink sink) {
    writeToCalls++;
    if (writeFailure case final failure?) _throwInjected(failure);
    sink.write(payload);
  }
}

Never _throwInjected(Object failure) {
  if (failure is Exception) throw failure;
  if (failure is Error) throw failure;
  throw StateError('Injected failure must be an Exception or Error.');
}

final class _WriteFailingReportObjectBackend
    extends _WrappedReportObjectBackend {
  const _WriteFailingReportObjectBackend(super.delegate)
    : super(mode: _ObjectFailureMode.write);
}

final class _CloseFailingReportObjectBackend
    extends _WrappedReportObjectBackend {
  const _CloseFailingReportObjectBackend(super.delegate)
    : super(mode: _ObjectFailureMode.close);
}

enum _ObjectFailureMode { write, close }

class _WrappedReportObjectBackend implements ReportObjectBackend {
  const _WrappedReportObjectBackend(this.delegate, {required this.mode});

  final ReportObjectBackend delegate;
  final _ObjectFailureMode mode;

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async =>
      _WrappedAnchoredReportDirectory(await delegate.anchor(directory), mode);
}

final class _WrappedAnchoredReportDirectory implements AnchoredReportDirectory {
  const _WrappedAnchoredReportDirectory(this.delegate, this.mode);

  final AnchoredReportDirectory delegate;
  final _ObjectFailureMode mode;

  @override
  String get canonicalPath => delegate.canonicalPath;

  @override
  Future<void> close() => delegate.close();

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async =>
      _WrappedExclusiveReportObject(await delegate.createExclusive(leaf), mode);

  @override
  Future<ExistingReportObject> openExisting(String leaf) =>
      delegate.openExisting(leaf);

  @override
  Future<void> verifyReachable() => delegate.verifyReachable();
}

final class _WrappedExclusiveReportObject implements ExclusiveReportObject {
  const _WrappedExclusiveReportObject(this.delegate, this.mode);

  final ExclusiveReportObject delegate;
  final _ObjectFailureMode mode;

  @override
  Future<void> close() async {
    await delegate.close();
    if (mode == _ObjectFailureMode.close) {
      throw StateError('injected object close failure');
    }
  }

  @override
  Future<void> flush() => delegate.flush();

  @override
  Future<ReportObjectIdentity> identity() => delegate.identity();

  @override
  Future<List<int>> read(int maximumBytes) => delegate.read(maximumBytes);

  @override
  Future<void> rewind() => delegate.rewind();

  @override
  Future<void> write(List<int> bytes) {
    if (mode == _ObjectFailureMode.write) {
      throw StateError('injected object write failure');
    }
    return delegate.write(bytes);
  }
}

class _RecordingStdout implements Stdout {
  final _buffer = StringBuffer();

  String get text => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  bool get hasTerminal => false;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns => throw const StdoutException('not a terminal');

  @override
  int get terminalLines => throw const StdoutException('not a terminal');

  @override
  IOSink get nonBlocking => this;

  @override
  void add(List<int> data) => _buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _buffer.write(error);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) {
    _buffer
      ..write(object)
      ..write(lineTerminator);
  }
}
