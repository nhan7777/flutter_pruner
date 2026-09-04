import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_application_reachability.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_directive_resolver.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DartExecutionReachabilityService', () {
    late Directory root;
    late ProjectContext project;
    late DartAnalysisWorkspace workspace;
    late BuildTarget web;
    late BuildTarget android;
    late AuxiliaryExecutionTarget vmTest;
    late AuxiliaryExecutionTarget unknownExternal;
    late DartExecutionContextSnapshot contexts;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('g6-reachability-');
      _write(root, 'pubspec.yaml', '''
name: reachability_test
environment:
  sdk: ^3.9.0
''');
      _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"reachability_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      _write(root, 'lib/main.dart', '''
import 'conditional.dart';
import 'owner.dart';
import 'standalone.g.dart';
void main() {}
''');
      _write(root, 'lib/conditional.dart', '''
export 'default.dart'
    if (dart.library.io == 'true') 'io.dart'
    if (dart.library.html == 'true') 'web.dart';
''');
      _write(root, 'lib/default.dart', 'class DefaultBranch {}\n');
      _write(root, 'lib/io.dart', 'class IoBranch {}\n');
      _write(root, 'lib/web.dart', 'class WebBranch {}\n');
      _write(root, 'lib/owner.dart', "part 'owner.g.dart';\nclass Owner {}\n");
      _write(
        root,
        'lib/owner.g.dart',
        "part of 'owner.dart';\nclass PartGenerated {}\n",
      );
      _write(root, 'lib/standalone.g.dart', 'class StandaloneGenerated {}\n');
      _write(root, 'test/vm_test.dart', '''
import 'package:reachability_test/conditional.dart';
void main() {}
''');

      web = BuildTarget(
        name: 'web',
        platform: 'web',
        entrypoint: 'lib/main.dart',
      );
      android = BuildTarget(
        name: 'android-debug',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main.dart',
        dartDefines: const {'MODE': 'debug'},
      );
      vmTest = AuxiliaryExecutionTarget(
        id: 'aux:test:test/vm_test.dart#vm',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {
          'dart.library.io': 'true',
          'dart.library.html': 'false',
          'dart.library.js_interop': 'false',
        },
        environmentComplete: true,
        reason: 'VM test',
      );
      unknownExternal = AuxiliaryExecutionTarget(
        id: 'aux:external:unknown',
        domain: AuxiliaryExecutionDomain.external,
        environmentValues: const {},
        environmentComplete: false,
        reason: 'unknown consumer',
      );
      project = ProjectContext(
        root: root,
        pubspec: const {'name': 'reachability_test'},
        packageName: 'reachability_test',
        targets: [web, android],
        rootCoverage: RootCoverage.applicationApi(),
      );
      contexts = DartExecutionContextSnapshot(
        configuredTargets: [web, android],
        auxiliaryExecutionTargets: [vmTest, unknownExternal],
        roots: [
          DartExecutionRootFact(
            nodeId: 'dart:reachability_test/lib/main.dart',
            owningLibraryId: 'dart:reachability_test/lib/main.dart',
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.configuredTarget,
            reason: 'web main',
            configuredTarget: web,
          ),
          DartExecutionRootFact(
            nodeId: 'dart:reachability_test/lib/main.dart',
            owningLibraryId: 'dart:reachability_test/lib/main.dart',
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.configuredTarget,
            reason: 'android main',
            configuredTarget: android,
          ),
          DartExecutionRootFact(
            nodeId: 'dart:reachability_test/test/vm_test.dart',
            owningLibraryId: 'dart:reachability_test/test/vm_test.dart',
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.auxiliary,
            reason: 'VM test root',
            auxiliaryExecutionTargetId: vmTest.id,
          ),
          DartExecutionRootFact(
            nodeId: 'dart:reachability_test/lib/conditional.dart',
            owningLibraryId: 'dart:reachability_test/lib/conditional.dart',
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.auxiliary,
            reason: 'external package API',
            auxiliaryExecutionTargetId: unknownExternal.id,
          ),
        ],
        issues: const [],
      );
      workspace = DartAnalysisWorkspace(project);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test(
      'memoizes one immutable snapshot embedding the exact contexts',
      () async {
        final service = DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        );

        final firstFuture = service.resolve(project);
        final secondFuture = service.resolve(project);
        expect(identical(firstFuture, secondFuture), isTrue);
        final snapshot = await firstFuture;
        expect(identical(snapshot, await secondFuture), isTrue);
        expect(identical(snapshot.contexts, contexts), isTrue);
        final resolutionCount = workspace.resolutionCount;
        await service.resolve(project);
        expect(workspace.resolutionCount, resolutionCount);
        expect(
          () => snapshot.configuredProvenUnitPaths[web]!.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => snapshot.auxiliaryRetainedUnitPaths.clear(),
          throwsUnsupportedError,
        );
        expect(snapshot.fingerprint, isNotEmpty);
      },
    );

    test(
      'separates configured and auxiliary proven versus retained closure',
      () async {
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        ).resolve(project);

        final canonicalRoot = root.resolveSymbolicLinksSync();
        Set<String> relative(Set<String> paths) => paths
            .map(
              (path) =>
                  p.relative(path, from: canonicalRoot).replaceAll(r'\', '/'),
            )
            .toSet();
        final webProven = relative(snapshot.configuredProvenUnitPaths[web]!);
        final androidProven = relative(
          snapshot.configuredProvenUnitPaths[android]!,
        );
        final vmProven = relative(
          snapshot.auxiliaryProvenUnitPaths[vmTest.id]!,
        );
        final unknownProven = relative(
          snapshot.auxiliaryProvenUnitPaths[unknownExternal.id]!,
        );
        final unknownRetained = relative(
          snapshot.auxiliaryRetainedUnitPaths[unknownExternal.id]!,
        );

        expect(webProven, contains('lib/web.dart'));
        expect(webProven, isNot(contains('lib/io.dart')));
        expect(androidProven, contains('lib/io.dart'));
        expect(androidProven, isNot(contains('lib/web.dart')));
        expect(vmProven, contains('lib/io.dart'));
        expect(unknownProven, isEmpty);
        expect(
          unknownRetained,
          containsAll({'lib/default.dart', 'lib/io.dart', 'lib/web.dart'}),
        );
        expect(
          relative(snapshot.globalUsageUnitPaths),
          containsAll({
            'lib/web.dart',
            'lib/io.dart',
            'lib/default.dart',
            'lib/owner.g.dart',
            'lib/standalone.g.dart',
            'test/vm_test.dart',
          }),
        );
        expect(
          snapshot.issues,
          contains(
            'conditional Dart imports/exports are incomplete for at least one execution context',
          ),
        );
      },
    );

    test(
      'fromSnapshot facade keeps legacy configured-proven union only',
      () async {
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: contexts,
        ).resolve(project);

        final reachability = DartApplicationReachability.fromSnapshot(snapshot);

        expect(
          reachability.unitPaths,
          equals({
            ...snapshot.configuredProvenUnitPaths[web]!,
            ...snapshot.configuredProvenUnitPaths[android]!,
          }),
        );
        expect(
          reachability.globalUsageUnitPaths,
          snapshot.globalUsageUnitPaths,
        );
      },
    );

    test(
      'keeps scoped context narratives out of pass-level blockers',
      () async {
        final scopedIssue = DartExecutionContextIssue(
          code: 'scoped-context-note',
          reason: unknownExternal.reason,
          requiresGlobalBlocker: false,
        );
        final scopedContexts = DartExecutionContextSnapshot(
          configuredTargets: contexts.configuredTargets,
          auxiliaryExecutionTargets: contexts.auxiliaryExecutionTargets,
          roots: contexts.roots,
          issues: [
            scopedIssue,
            const DartExecutionContextIssue(
              code: 'global-context-failure',
              reason: 'root discovery is incomplete',
              requiresGlobalBlocker: true,
            ),
          ],
        );

        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: scopedContexts,
        ).resolve(project);

        expect(
          snapshot.issues,
          contains('global-context-failure: root discovery is incomplete'),
        );
        expect(
          snapshot.issues,
          isNot(contains('scoped-context-note: ${unknownExternal.reason}')),
        );
        final reachability = DartApplicationReachability.fromSnapshot(snapshot);
        expect(
          reachability.issues,
          contains('global-context-failure: root discovery is incomplete'),
        );
        expect(
          reachability.issues,
          isNot(contains('scoped-context-note: ${unknownExternal.reason}')),
        );
        expect(reachability.contextIssues, scopedContexts.issues);
        expect(reachability.auxiliaryContextIssues.keys, {unknownExternal.id});
        expect(reachability.auxiliaryContextIssues[unknownExternal.id], [
          scopedIssue,
        ]);
        expect(
          () =>
              reachability.auxiliaryContextIssues[unknownExternal.id]!.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => reachability.auxiliaryContextIssues.clear(),
          throwsUnsupportedError,
        );
      },
    );

    test(
      'excluded main is not rooted while its ordinary imports stay reachable',
      () async {
        final fixture = await _createExcludedEntrypointReachabilityFixture();
        addTearDown(() => fixture.root.deleteSync(recursive: true));
        final workspace = DartAnalysisWorkspace(fixture.project);
        final resolvedContexts = await DefaultDartExecutionContextService(
          workspace: workspace,
        ).resolve(fixture.project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: workspace,
          contexts: resolvedContexts,
        ).resolve(fixture.project);

        const guardLibraryId = 'dart:reachability_test/scripts/guard.dart';
        expect(
          resolvedContexts.roots.map((root) => root.nodeId),
          isNot(
            anyOf(contains(guardLibraryId), contains('$guardLibraryId#main')),
          ),
        );
        expect(
          _relativePaths(
            fixture.root,
            snapshot.configuredProvenUnitPaths[fixture.target]!,
          ),
          containsAll({'scripts/guard.dart', 'lib/live.dart'}),
        );

        final analysis = await ProjectAnalyzer(
          project: fixture.project,
          only: const {'dart'},
        ).analyze();
        expect(analysis.graphIntegrity.complete, isTrue);
        expect(
          analysis.graph.blockers.where(
            (blocker) =>
                blocker.sourceNodeId == null &&
                blocker.reason.contains('excluded-dart-entrypoint'),
          ),
          isEmpty,
        );
      },
    );

    test('stale exclusion projects a source-less global blocker', () async {
      final fixture = await _createExcludedEntrypointReachabilityFixture();
      addTearDown(() => fixture.root.deleteSync(recursive: true));
      File(fixture.project.resolve('scripts/guard.dart')).writeAsStringSync(
        "import '../lib/live.dart';\nvoid guard() => live();\n",
      );

      final analysis = await ProjectAnalyzer(
        project: fixture.project,
        only: const {'dart'},
      ).analyze();

      final blockers = analysis.graph.blockers.where(
        (blocker) =>
            blocker.reason.startsWith('excluded-dart-entrypoint-unresolved:'),
      );
      expect(blockers, isNotEmpty);
      expect(blockers.every((blocker) => blocker.sourceNodeId == null), isTrue);
    });

    test(
      'recognized Flutter auxiliary targets keep exact branch selection without conditional incompleteness',
      () async {
        final fixture = await _createFlutterAuxiliaryReachabilityFixture(
          includeUnrecognizedControl: false,
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final resolvedContexts = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: fixture.workspace,
          contexts: resolvedContexts,
        ).resolve(fixture.project);

        Set<String> relative(Set<String> paths) => paths
            .map(
              (path) => p
                  .relative(path, from: fixture.rootPath)
                  .replaceAll(r'\', '/'),
            )
            .toSet();

        final integrationTargets = resolvedContexts.auxiliaryExecutionTargets
            .where(
              (target) => target.id.startsWith(
                'aux:test:integration_test/live_test.dart:integration-',
              ),
            )
            .toList();
        expect(integrationTargets, hasLength(3));
        expect(
          integrationTargets.every((target) => target.environmentComplete),
          isTrue,
        );

        final driverTarget = resolvedContexts.auxiliaryExecutionTargets
            .singleWhere(
              (target) =>
                  target.id ==
                  'aux:test:test_driver/screenshot_driver.dart:driver-vm',
            );
        expect(driverTarget.environmentComplete, isTrue);
        expect(
          resolvedContexts.auxiliaryExecutionTargets.where(
            (target) =>
                target.id ==
                'aux:test:integration_test/unrecognized_control.dart:incomplete',
          ),
          isEmpty,
        );

        expect(
          snapshot.issues,
          isNot(
            contains(
              'conditional Dart imports/exports are incomplete for at least one execution context',
            ),
          ),
        );
        expect(
          snapshot.directives.issues.where(
            (issue) =>
                issue.reason ==
                    'conditional Dart directive environment is incomplete for this execution context' &&
                relative({
                  issue.sourcePath,
                }).contains('lib/platform_value.dart'),
          ),
          isEmpty,
        );
        expect(
          snapshot.issues.where(
            (issue) =>
                issue ==
                'conditional Dart directive environment is incomplete for this execution context: lib/platform_value.dart',
          ),
          isEmpty,
        );

        for (final target in integrationTargets.where(
          (target) => const {
            'android',
            'ios',
          }.contains(target.sourceConfiguredTarget!.platform),
        )) {
          final proven = relative(
            snapshot.auxiliaryProvenUnitPaths[target.id]!,
          );
          final retained = relative(
            snapshot.auxiliaryRetainedUnitPaths[target.id]!,
          );
          expect(proven, contains('lib/platform_native.dart'));
          expect(proven, isNot(contains('lib/platform_web.dart')));
          expect(retained, contains('lib/platform_native.dart'));
          expect(retained, isNot(contains('lib/platform_web.dart')));
        }

        final webTarget = integrationTargets.singleWhere(
          (target) => target.sourceConfiguredTarget!.platform == 'web',
        );
        final webProven = relative(
          snapshot.auxiliaryProvenUnitPaths[webTarget.id]!,
        );
        final webRetained = relative(
          snapshot.auxiliaryRetainedUnitPaths[webTarget.id]!,
        );
        expect(webProven, contains('lib/platform_web.dart'));
        expect(webProven, isNot(contains('lib/platform_native.dart')));
        expect(webRetained, contains('lib/platform_web.dart'));
        expect(webRetained, isNot(contains('lib/platform_native.dart')));

        final driverProven = relative(
          snapshot.auxiliaryProvenUnitPaths[driverTarget.id]!,
        );
        final driverRetained = relative(
          snapshot.auxiliaryRetainedUnitPaths[driverTarget.id]!,
        );
        expect(driverProven, contains('lib/platform_native.dart'));
        expect(driverProven, isNot(contains('lib/platform_web.dart')));
        expect(driverRetained, contains('lib/platform_native.dart'));
        expect(driverRetained, isNot(contains('lib/platform_web.dart')));
      },
    );

    test(
      'unrecognized integration control stays incomplete and retains both conditional branches',
      () async {
        final fixture = await _createFlutterAuxiliaryReachabilityFixture(
          includeUnrecognizedControl: true,
          includeRecognizedSurfaces: false,
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final resolvedContexts = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);
        final snapshot = await DefaultDartExecutionReachabilityService(
          workspace: fixture.workspace,
          contexts: resolvedContexts,
        ).resolve(fixture.project);

        Set<String> relative(Set<String> paths) => paths
            .map(
              (path) => p
                  .relative(path, from: fixture.rootPath)
                  .replaceAll(r'\', '/'),
            )
            .toSet();

        final unrecognizedTarget = resolvedContexts.auxiliaryExecutionTargets
            .singleWhere(
              (target) =>
                  target.id ==
                  'aux:test:integration_test/unrecognized_control.dart:incomplete',
            );
        expect(unrecognizedTarget.environmentComplete, isFalse);
        expect(
          snapshot.auxiliaryProvenUnitPaths[unrecognizedTarget.id]!,
          isEmpty,
        );
        expect(
          relative(snapshot.auxiliaryRetainedUnitPaths[unrecognizedTarget.id]!),
          containsAll({'lib/platform_native.dart', 'lib/platform_web.dart'}),
        );
        expect(
          snapshot.directives.issues,
          contains(
            predicate<DartDirectiveIssue>(
              (issue) =>
                  issue.reason ==
                      'conditional Dart directive environment is incomplete for this execution context' &&
                  issue.affectedAuxiliaryTargetIds.contains(
                    unrecognizedTarget.id,
                  ),
            ),
          ),
        );
        expect(
          snapshot.issues,
          contains(
            'conditional Dart directive environment is incomplete for this execution context: lib/platform_value.dart',
          ),
        );
        expect(
          snapshot.issues,
          contains(
            'conditional Dart imports/exports are incomplete for at least one execution context',
          ),
        );
      },
    );
  });
}

void _write(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

Set<String> _relativePaths(Directory root, Set<String> paths) => paths
    .map(
      (path) => p
          .relative(path, from: root.resolveSymbolicLinksSync())
          .replaceAll(r'\', '/'),
    )
    .toSet();

final class _ExcludedEntrypointReachabilityFixture {
  const _ExcludedEntrypointReachabilityFixture({
    required this.root,
    required this.project,
    required this.target,
  });

  final Directory root;
  final ProjectContext project;
  final BuildTarget target;
}

Future<_ExcludedEntrypointReachabilityFixture>
_createExcludedEntrypointReachabilityFixture() async {
  final root = await Directory.systemTemp.createTemp(
    'excluded-entrypoint-reachability-',
  );
  _write(root, 'pubspec.yaml', '''
name: reachability_test
environment:
  sdk: ^3.9.0
''');
  _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"reachability_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
  _write(root, 'lib/main.dart', '''
import '../scripts/guard.dart';

void main() => guard();
''');
  _write(root, 'scripts/guard.dart', '''
import '../lib/live.dart';

void main() => live();
void guard() => live();
''');
  _write(root, 'lib/live.dart', 'void live() {}\n');
  final target = BuildTarget(
    name: 'android',
    platform: 'android',
    entrypoint: 'lib/main.dart',
  );
  final project = ProjectContext(
    root: root,
    pubspec: const {'name': 'reachability_test'},
    packageName: 'reachability_test',
    targetMatrix: TargetMatrix(
      targets: [target],
      status: TargetMatrixStatus.declaredComplete,
      source: 'fixture',
      excludedEntrypoints: const [
        ExcludedApplicationEntrypoint(
          path: 'scripts/guard.dart',
          reason: 'tracked guard is not launchable',
        ),
      ],
    ),
    rootCoverage: RootCoverage.applicationApi(),
  );
  return _ExcludedEntrypointReachabilityFixture(
    root: root,
    project: project,
    target: target,
  );
}

final class _FlutterAuxiliaryReachabilityFixture {
  const _FlutterAuxiliaryReachabilityFixture({
    required this.project,
    required this.workspace,
    required this.rootPath,
  });

  final ProjectContext project;
  final DartAnalysisWorkspace workspace;
  final String rootPath;
}

Future<_FlutterAuxiliaryReachabilityFixture>
_createFlutterAuxiliaryReachabilityFixture({
  bool includeRecognizedSurfaces = true,
  bool includeUnrecognizedControl = true,
}) async {
  final root = await Directory.systemTemp.createTemp(
    'flutter-aux-reachability-',
  );
  _write(root, 'pubspec.yaml', '''
name: reachability_test
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  integration_test:
    sdk: flutter
''');
  _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"reachability_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"integration_test","rootUri":"../fake_packages/integration_test/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter_driver","rootUri":"../fake_packages/flutter_driver/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
  final sources = <String, String>{
    'lib/main.dart': '''
import 'platform_value.dart';

void main() {
  platformValue;
}
''',
    'lib/platform_value.dart': '''
export 'platform_native.dart'
    if (dart.library.html) 'platform_web.dart';
''',
    'lib/platform_native.dart': "const String platformValue = 'native';\n",
    'lib/platform_web.dart': "const String platformValue = 'web';\n",
    if (includeRecognizedSurfaces)
      'integration_test/live_test.dart': '''
import 'package:integration_test/integration_test.dart';
import 'package:reachability_test/platform_value.dart';

void main() {
  platformValue;
}
''',
    if (includeUnrecognizedControl)
      'integration_test/unrecognized_control.dart': '''
import 'package:reachability_test/platform_value.dart';

void main() {
  platformValue;
}
''',
    if (includeRecognizedSurfaces)
      'test_driver/screenshot_driver.dart': '''
import 'package:flutter_driver/flutter_driver.dart';
import 'package:reachability_test/platform_value.dart';

void drive() {
  platformValue;
}
''',
    'fake_packages/integration_test/lib/integration_test.dart':
        'void integrationTestBinding() {}\n',
    'fake_packages/integration_test/pubspec.yaml': '''
name: integration_test
environment:
  sdk: ^3.9.0
''',
    'fake_packages/integration_test/lib/integration_test_driver.dart':
        'void integrationTestDriver() {}\n',
    'fake_packages/integration_test/lib/integration_test_driver_extended.dart':
        'void integrationTestDriverExtended() {}\n',
    'fake_packages/flutter_driver/lib/flutter_driver.dart':
        'void flutterDriverBinding() {}\n',
    'fake_packages/flutter_driver/pubspec.yaml': '''
name: flutter_driver
environment:
  sdk: ^3.9.0
''',
  };
  for (final entry in sources.entries) {
    _write(root, entry.key, entry.value);
  }

  final project = ProjectContext(
    root: root,
    pubspec: const {
      'name': 'reachability_test',
      'dependencies': {
        'flutter': {'sdk': 'flutter'},
      },
      'dev_dependencies': {
        'integration_test': {'sdk': 'flutter'},
      },
    },
    packageName: 'reachability_test',
    targetMatrix: TargetMatrix(
      targets: [
        BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
        BuildTarget(name: 'ios', platform: 'ios', entrypoint: 'lib/main.dart'),
        BuildTarget(name: 'web', platform: 'web', entrypoint: 'lib/main.dart'),
      ],
      status: TargetMatrixStatus.declaredComplete,
      source: 'fixture',
    ),
    rootCoverage: RootCoverage.applicationApi(),
  );
  final canonicalRoot = root.resolveSymbolicLinksSync();
  return _FlutterAuxiliaryReachabilityFixture(
    project: project,
    workspace: DartAnalysisWorkspace(project),
    rootPath: canonicalRoot,
  );
}
