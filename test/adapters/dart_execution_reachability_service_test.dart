import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_application_reachability.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
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
  });
}

void _write(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
