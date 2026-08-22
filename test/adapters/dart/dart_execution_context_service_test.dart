import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/analyzer_diagnostic_collector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('G3 DartExecutionContextService', () {
    late Directory directory;
    late ProjectContext project;

    setUp(() async {
      directory = await Directory.systemTemp.createTemp('g3-context-');
      File(p.join(directory.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'name: context_test\nenvironment:\n  sdk: ^3.9.0\n',
        );
      File(p.join(directory.path, 'lib/main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'dart:ffi';
import 'dart:isolate';

void main() {
  Isolate.spawn(worker, null);
}
void worker(Object? message) {}
@Native<Void Function()>()
external void nativeFfiCallback();
@pragma('vm:entry-point')
void callback() {}
void sibling() {}
''');
      File(p.join(directory.path, 'test/vm_test.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync("@TestOn('vm')\nvoid main() {}\n");
      _writePackageConfig(directory, '''
{"configVersion":2,"packages":[
  {"name":"context_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      project = ProjectContext(
        root: directory,
        pubspec: const {'name': 'context_test'},
        packageName: 'context_test',
        targets: [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.applicationEntrypoints,
          internalBoundaryComplete: true,
          externalConsumersCovered: true,
          source: 'test',
        ),
      );
    });

    tearDown(() => directory.deleteSync(recursive: true));

    test('memoizes one future and deeply immutable snapshot', () async {
      final service = DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(project),
      );
      final firstFuture = service.resolve(project);
      final secondFuture = service.resolve(project);
      expect(identical(firstFuture, secondFuture), isTrue);

      final snapshot = await firstFuture;
      expect(identical(snapshot, await secondFuture), isTrue);
      expect(() => snapshot.configuredTargets.clear(), throwsUnsupportedError);
      expect(
        () => snapshot.auxiliaryExecutionTargets.clear(),
        throwsUnsupportedError,
      );
      expect(() => snapshot.roots.clear(), throwsUnsupportedError);
    });

    test(
      'maps each root to exactly one domain and roots callback owner once',
      () async {
        final snapshot = await DefaultDartExecutionContextService(
          workspace: DartAnalysisWorkspace(project),
        ).resolve(project);

        expect(
          snapshot.roots.every(
            (root) =>
                (root.configuredTarget != null) !=
                (root.auxiliaryExecutionTargetId != null),
          ),
          isTrue,
        );
        final callbackRoots = snapshot.roots
            .where((root) => root.reason.contains("@pragma('vm:entry-point')"))
            .toList();
        expect(callbackRoots, hasLength(2));
        expect(
          callbackRoots.map((root) => root.nodeId).toSet(),
          containsAll(<String>{
            'dart:context_test/lib/main.dart#callback',
            'dart:context_test/lib/main.dart',
          }),
        );
        expect(
          snapshot.roots.where((root) => root.nodeId.endsWith('#sibling')),
          isEmpty,
        );
        final nativeBoundaryRoots = snapshot.roots
            .where((root) => root.reason.contains('dart:isolate Isolate.spawn'))
            .toList();
        expect(nativeBoundaryRoots, hasLength(2));
        expect(nativeBoundaryRoots.map((root) => root.nodeId).toSet(), {
          'dart:context_test/lib/main.dart#worker',
          'dart:context_test/lib/main.dart',
        });
        final ffiRoots = snapshot.roots
            .where((root) => root.reason.contains('@Native FFI'))
            .toList();
        expect(ffiRoots, hasLength(2));
        expect(ffiRoots.map((root) => root.nodeId).toSet(), {
          'dart:context_test/lib/main.dart#nativeFfiCallback',
          'dart:context_test/lib/main.dart',
        });
      },
    );

    test('a new service creates a new pass snapshot', () async {
      final first = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(project),
      ).resolve(project);
      final second = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(project),
      ).resolve(project);

      expect(identical(first, second), isFalse);
      expect(first.roots, second.roots);
    });

    test(
      'external configured root creates no parent ID and fails closed',
      () async {
        final nested = Directory(p.join(directory.path, 'nested'));
        File(p.join(nested.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'name: nested_pkg\nenvironment:\n  sdk: ^3.9.0\n',
          );
        File(p.join(nested.path, 'lib/main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}\n');
        _writePackageConfig(directory, '''
{"configVersion":2,"packages":[
  {"name":"context_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"nested_pkg","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        final configuredProject = ProjectContext(
          root: directory,
          pubspec: const {'name': 'context_test'},
          packageName: 'context_test',
          targets: [
            BuildTarget(
              name: 'nested',
              platform: 'android',
              entrypoint: 'nested/lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final workspace = DartAnalysisWorkspace(configuredProject);
        final service = DefaultDartExecutionContextService(
          workspace: workspace,
        );

        final snapshot = await service.resolve(configuredProject);

        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(contains(contains('nested/lib/main.dart'))),
        );
        expect(
          snapshot.issues,
          contains(
            predicate<DartExecutionContextIssue>(
              (issue) =>
                  issue.code == 'dart-root-external-package' &&
                  issue.requiresGlobalBlocker,
            ),
          ),
        );

        final graph = ReachabilityGraph();
        await DartAdapter(
          collectAnalyzerDiagnostics: (_) async =>
              const AnalyzerDiagnosticCollection.skipped(),
        ).analyzeWithServices(
          configuredProject,
          GraphBuilder(graph, 'dart'),
          AdapterServices(
            dartWorkspace: workspace,
            dartExecutionContextService: service,
          ),
        );
        expect(
          graph.rootRecords.map((root) => root.nodeId),
          isNot(contains(contains('nested/lib/main.dart'))),
        );
        expect(
          graph.blockers,
          contains(
            predicate<Blocker>(
              (blocker) =>
                  blocker.isUnscoped &&
                  blocker.reason.startsWith('dart-root-external-package:'),
            ),
          ),
        );
      },
    );

    test('unknown public root creates no parent package ID', () async {
      final nested = Directory(p.join(directory.path, 'nested'));
      File(p.join(nested.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          'name: physical_nested\nenvironment:\n  sdk: ^3.9.0\n',
        );
      File(p.join(nested.path, 'lib/api.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void api() {}\n');
      _writePackageConfig(directory, '''
{"configVersion":2,"packages":[
  {"name":"context_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_claim","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      final publicProject = ProjectContext(
        root: directory,
        pubspec: const {'name': 'context_test'},
        packageName: 'context_test',
        analysisMode: AnalysisMode.package,
        targets: [
          BuildTarget(
            name: 'package',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.packagePublicApi,
          internalBoundaryComplete: true,
          externalConsumersCovered: true,
          source: 'test',
          publicEntrypoints: const ['nested/lib/api.dart'],
        ),
      );

      final snapshot = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(publicProject),
      ).resolve(publicProject);

      expect(
        snapshot.roots.map((root) => root.nodeId),
        isNot(contains(contains('nested/lib/api.dart'))),
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'dart-root-ownership-unknown' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test(
      'unresolved reviewed constructor callback fails closed end to end',
      () async {
        final callbackProjectRoot = await Directory.systemTemp.createTemp(
          'g3-workmanager-context-',
        );
        addTearDown(() => callbackProjectRoot.deleteSync(recursive: true));
        File(p.join(callbackProjectRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'name: workmanager_context\nenvironment:\n  sdk: ^3.9.0\n',
          );
        File(p.join(callbackProjectRoot.path, 'lib/main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
void main() {}
void backgroundCallback() {}
void definitelyUnused() {}

void unreachableRegistration() {
  Workmanager().initialize(backgroundCallback);
}
''');
        _writePackageConfig(callbackProjectRoot, '''
{"configVersion":2,"packages":[
  {"name":"workmanager_context","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        final callbackProject = ProjectContext(
          root: callbackProjectRoot,
          pubspec: const {'name': 'workmanager_context'},
          packageName: 'workmanager_context',
          targets: [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final callbackOwner = DartPackageOwnership.discover(
          callbackProject,
        ).ownerOf(p.join(callbackProjectRoot.path, 'lib/main.dart'));
        expect(
          callbackOwner.ownership,
          DartSourceOwnership.selectedPackage,
          reason: callbackOwner.reason,
        );

        final snapshot = await ProjectAnalyzer(
          project: callbackProject,
          only: {'dart'},
        ).analyze();
        final runtimeTargets = snapshot.graph.auxiliaryExecutionTargets
            .where(
              (target) => target.domain == AuxiliaryExecutionDomain.runtime,
            )
            .toList();
        final callbackId =
            'dart:workmanager_context/lib/main.dart#backgroundCallback';
        final ownerId = 'dart:workmanager_context/lib/main.dart';

        expect(runtimeTargets, hasLength(1));
        expect(runtimeTargets.single.environmentComplete, isFalse);
        expect(
          snapshot.graph.blockers.where((blocker) => blocker.isUnscoped),
          hasLength(greaterThanOrEqualTo(1)),
        );
        final blockerReasons = snapshot.graph.blockers
            .map((blocker) => blocker.reason)
            .toList();
        expect(
          blockerReasons.any(
            (reason) => reason.contains('runtime-capability-unknown'),
          ),
          isTrue,
        );
        expect(
          blockerReasons.any(
            (reason) => reason.contains('callback-target-incomplete'),
          ),
          isTrue,
        );
        expect(snapshot.graph.auxiliaryProven(), isNot(contains(callbackId)));
        expect(
          snapshot.graph.auxiliaryRetained(),
          containsAll({callbackId, ownerId}),
        );

        final unused = snapshot.findings.singleWhere(
          (finding) => finding.node.id.endsWith('#definitelyUnused'),
        );
        expect(unused.confidence, Confidence.review);
        expect(unused.proposedAction, isNull);
        expect(
          snapshot.findings.where(
            (finding) =>
                finding.confidence == Confidence.safe ||
                finding.confidence == Confidence.high,
          ),
          isEmpty,
        );
        final callbackFinding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == callbackId,
        );
        expect(callbackFinding.confidence, Confidence.review);
        expect(callbackFinding.proposedAction, isNull);
        expect(callbackFinding.predicates.unreachableAcrossAllTargets, isTrue);
        expect(callbackFinding.predicates.notRetained, isFalse);
        expect(callbackFinding.reachableIn, isEmpty);
        expect(callbackFinding.unreachableIn, ['android']);
        expect(callbackFinding.retainedIn, ['android']);
        expect(callbackFinding.auxiliaryRetainedIn, [runtimeTargets.single.id]);
      },
    );

    test(
      'part callback keeps its physical declaration and library owner',
      () async {
        final partProjectRoot = await Directory.systemTemp.createTemp(
          'g3-part-context-',
        );
        addTearDown(() => partProjectRoot.deleteSync(recursive: true));
        File(p.join(partProjectRoot.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            'name: part_context\nenvironment:\n  sdk: ^3.9.0\n',
          );
        File(p.join(partProjectRoot.path, 'lib/main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'dart:isolate';
part 'src/callback_part.dart';

void main() {}
void librarySibling() {}
''');
        File(p.join(partProjectRoot.path, 'lib/src/callback_part.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
part of '../main.dart';

void registerPartCallback() {
  Isolate.spawn(partWorker, null);
}
void partWorker(Object? message) {}
void partSibling() {}
''');
        _writePackageConfig(partProjectRoot, '''
{"configVersion":2,"packages":[
  {"name":"part_context","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        final partProject = ProjectContext(
          root: partProjectRoot,
          pubspec: const {'name': 'part_context'},
          packageName: 'part_context',
          targets: [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          rootCoverage: RootCoverage.applicationApi(),
        );
        final partOwner = DartPackageOwnership.discover(
          partProject,
        ).ownerOf(p.join(partProjectRoot.path, 'lib/main.dart'));
        expect(
          partOwner.ownership,
          DartSourceOwnership.selectedPackage,
          reason: partOwner.reason,
        );

        final snapshot = await DefaultDartExecutionContextService(
          workspace: DartAnalysisWorkspace(partProject),
        ).resolve(partProject);
        final callbackRoots = snapshot.roots
            .where((root) => root.reason.contains('dart:isolate Isolate.spawn'))
            .toList();
        const libraryId = 'dart:part_context/lib/main.dart';
        const physicalDeclarationId =
            'dart:part_context/lib/src/callback_part.dart#partWorker';

        expect(callbackRoots, hasLength(2));
        expect(callbackRoots.map((root) => root.nodeId).toSet(), {
          libraryId,
          physicalDeclarationId,
        });
        expect(
          callbackRoots.every((root) => root.owningLibraryId == libraryId),
          isTrue,
        );
        expect(
          callbackRoots.where(
            (root) =>
                root.nodeId == 'dart:part_context/lib/src/callback_part.dart',
          ),
          isEmpty,
        );
        expect(
          snapshot.roots.where(
            (root) =>
                root.nodeId.endsWith('#partSibling') ||
                root.nodeId.endsWith('#librarySibling'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'DartAdapter mirrors exactly the shared service root projection',
      () async {
        final workspace = DartAnalysisWorkspace(project);
        final service = DefaultDartExecutionContextService(
          workspace: workspace,
        );
        final snapshot = await service.resolve(project);
        final graph = ReachabilityGraph();

        await DartAdapter(
          collectAnalyzerDiagnostics: (_) async =>
              const AnalyzerDiagnosticCollection.skipped(),
        ).analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          AdapterServices(
            dartWorkspace: workspace,
            dartExecutionContextService: service,
          ),
        );

        String snapshotIdentity(DartExecutionRootFact root) => [
          root.domain.name,
          root.configuredTarget?.toString() ?? root.auxiliaryExecutionTargetId,
          root.nodeId,
          root.reason,
        ].join('|');
        String graphIdentity(GraphRootRecord root) => switch (root) {
          ConfiguredGraphRootRecord(:final condition) => [
            root.domain.name,
            condition.exactTargets.single.toString(),
            root.nodeId,
            root.reason,
          ].join('|'),
          AuxiliaryGraphRootRecord(:final executionTargetId) => [
            root.domain.name,
            executionTargetId,
            root.nodeId,
            root.reason,
          ].join('|'),
        };

        expect(
          graph.rootRecords.map(graphIdentity).toSet(),
          snapshot.roots.map(snapshotIdentity).toSet(),
          reason:
              'ReferenceCollector and DartAdapter must not add fallback roots',
        );
        expect(
          graph.auxiliaryExecutionTargets,
          snapshot.auxiliaryExecutionTargets,
        );
      },
    );

    test('typed root construction rejects mixed or missing identities', () {
      final target = project.targets.single;
      expect(
        () => DartExecutionRootFact(
          nodeId: 'node',
          owningLibraryId: 'library',
          subject: DartExecutionRootSubject.declaration,
          domain: RootDomain.configuredTarget,
          reason: 'invalid',
          configuredTarget: target,
          auxiliaryExecutionTargetId: 'aux:test:test.dart:vm',
        ),
        throwsArgumentError,
      );
      expect(
        () => DartExecutionRootFact(
          nodeId: 'node',
          owningLibraryId: 'library',
          subject: DartExecutionRootSubject.declaration,
          domain: RootDomain.auxiliary,
          reason: 'invalid',
        ),
        throwsArgumentError,
      );
    });
  });

  group('executable auxiliary roots', () {
    test(
      'integration_test and test_driver are explicit test-runner roots',
      () async {
        final fixture = await _createExecutionRootFixture({
          'integration_test/live_test.dart': 'void main() {}\n',
          'test_driver/driver.dart': 'void drive() {}\n',
        });
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        for (final path in const [
          'integration_test/live_test.dart',
          'test_driver/driver.dart',
        ]) {
          final libraryId = 'dart:execution_roots/$path';
          final roots = snapshot.roots.where(
            (root) => root.owningLibraryId == libraryId,
          );
          expect(
            roots.map((root) => root.nodeId),
            contains(libraryId),
            reason: path,
          );
          expect(
            roots.every(
              (root) =>
                  root.domain == RootDomain.auxiliary &&
                  root.auxiliaryExecutionTargetId!.startsWith('aux:test:'),
            ),
            isTrue,
            reason: path,
          );
        }
        expect(
          snapshot.roots.map((root) => root.nodeId),
          contains('dart:execution_roots/integration_test/live_test.dart#main'),
        );
        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(contains('dart:execution_roots/test_driver/driver.dart#main')),
        );
      },
    );

    test(
      'benchmark tool example and unconfigured bin mains are runtime roots',
      () async {
        final fixture = await _createExecutionRootFixture({
          'benchmark/run.dart': 'void main() {}\n',
          'benchmark/support.dart': 'void support() {}\n',
          'tool/run.dart': 'void main() {}\n',
          'example/run.dart': 'void main() {}\n',
          'bin/worker.dart': 'void main() {}\n',
        });
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        for (final path in const [
          'benchmark/run.dart',
          'tool/run.dart',
          'example/run.dart',
          'bin/worker.dart',
        ]) {
          final libraryId = 'dart:execution_roots/$path';
          final roots = snapshot.roots
              .where((root) => root.owningLibraryId == libraryId)
              .toList();
          expect(roots.map((root) => root.nodeId).toSet(), {
            libraryId,
            '$libraryId#main',
          }, reason: path);
          expect(
            roots.every(
              (root) =>
                  root.domain == RootDomain.auxiliary &&
                  root.auxiliaryExecutionTargetId!.startsWith('aux:runtime:'),
            ),
            isTrue,
            reason: path,
          );
        }
        expect(
          snapshot.roots.map((root) => root.owningLibraryId),
          isNot(contains('dart:execution_roots/benchmark/support.dart')),
        );
      },
    );

    test('sanitized executable path IDs cannot collide', () async {
      final fixture = await _createExecutionRootFixture({
        'tool/a b.dart': 'void main() {}\n',
        'tool/a_b.dart': 'void main() {}\n',
      });
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);
      final executableTargets = snapshot.auxiliaryExecutionTargets
          .where((target) => target.id.contains(':executable:tool/a_b.dart'))
          .toList();

      expect(executableTargets, hasLength(2));
      expect(
        executableTargets.map((target) => target.id).toSet(),
        hasLength(2),
      );
      expect(
        executableTargets.map((target) => target.id),
        contains('aux:runtime:executable:tool/a_b.dart:incomplete'),
      );
      expect(
        snapshot.roots
            .where(
              (root) =>
                  root.owningLibraryId.contains('tool/a b.dart') ||
                  root.owningLibraryId.contains('tool/a_b.dart'),
            )
            .map((root) => root.auxiliaryExecutionTargetId)
            .toSet(),
        hasLength(2),
      );
    });

    test('standard executable symlink fails closed globally', () async {
      final fixture = await _createExecutionRootFixture(const {});
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      final target = File(p.join(fixture.project.root.path, 'real-worker.txt'))
        ..writeAsStringSync('void main() {}\n');
      Link(
        p.join(fixture.project.root.path, 'tool', 'linked.dart'),
      ).createSync(target.path, recursive: true);

      final snapshot = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(fixture.project),
      ).resolve(fixture.project);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'standard-executable-symlink' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('non-Dart standard-surface symlink is ignored', () async {
      final fixture = await _createExecutionRootFixture(const {});
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      final target = File(p.join(fixture.project.root.path, 'notes.txt'))
        ..writeAsStringSync('not a Dart execution candidate\n');
      Link(
        p.join(fixture.project.root.path, 'tool', 'notes.link'),
      ).createSync(target.path, recursive: true);

      final snapshot = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(fixture.project),
      ).resolve(fixture.project);

      expect(
        snapshot.issues.where(
          (issue) => issue.code == 'standard-executable-symlink',
        ),
        isEmpty,
      );
    });

    test('Dart symlink inside a proven nested package is ignored', () async {
      final fixture = await _createExecutionRootFixture({
        'tool/nested/pubspec.yaml':
            'name: nested_tool\nenvironment:\n  sdk: ^3.9.0\n',
        'tool/nested/sub/real.dart': 'void main() {}\n',
      });
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      Link(
        p.join(
          fixture.project.root.path,
          'tool',
          'nested',
          'sub',
          'linked.dart',
        ),
      ).createSync('real.dart');
      _writePackageConfig(fixture.project.root, '''
{"configVersion":2,"packages":[
  {"name":"execution_roots","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"nested_tool","rootUri":"../tool/nested/","packageUri":"./","languageVersion":"3.9"}
]}
''');
      final project = ProjectContext(
        root: fixture.project.root,
        pubspec: const {'name': 'execution_roots'},
        packageName: 'execution_roots',
        targets: [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
        rootCoverage: RootCoverage.applicationApi(),
      );
      final lexicalOwner = DartPackageOwnership.discover(project).ownerOf(
        p.join(
          Directory(
            p.join(project.root.path, 'tool', 'nested', 'sub'),
          ).resolveSymbolicLinksSync(),
          '__flutter_pruner_ownership__.dart',
        ),
      );
      expect(
        lexicalOwner.ownership,
        DartSourceOwnership.externalPackage,
        reason: lexicalOwner.reason,
      );

      final snapshot = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(project),
      ).resolve(project);

      expect(
        snapshot.issues.where(
          (issue) => issue.code == 'standard-executable-symlink',
        ),
        isEmpty,
      );
      expect(
        snapshot.roots.map((root) => root.nodeId),
        isNot(contains(contains('tool/nested/'))),
      );
    });

    test('unknown-owned standard executable fails closed globally', () async {
      final fixture = await _createExecutionRootFixture({
        'tool/nested/pubspec.yaml':
            'name: physical_nested\nenvironment:\n  sdk: ^3.9.0\n',
        'tool/nested/unknown.dart': 'void main() {}\n',
      });
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      _writePackageConfig(fixture.project.root, '''
{"configVersion":2,"packages":[
  {"name":"execution_roots","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_claim","rootUri":"../tool/nested/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      final unknownProject = ProjectContext(
        root: fixture.project.root,
        pubspec: const {'name': 'execution_roots'},
        packageName: 'execution_roots',
        targets: [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
        rootCoverage: RootCoverage.applicationApi(),
      );

      final snapshot = await DefaultDartExecutionContextService(
        workspace: DartAnalysisWorkspace(unknownProject),
      ).resolve(unknownProject);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'standard-executable-ownership-unknown' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
      expect(
        snapshot.roots.map((root) => root.nodeId),
        isNot(contains(contains('tool/nested/unknown.dart'))),
      );
    });

    for (final excluded in const [false, true]) {
      test('${excluded ? 'analyzer-excluded' : 'visible'} generated standard '
          'executable uses a non-reportable root and scans spawnUri', () async {
        final fixture = await _createExecutionRootFixture(
          {
            'tool/generated_launcher.g.dart': '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(Uri.parse('../lib/worker.dart'), const [], null);
}
''',
            'lib/worker.dart': 'void main() {}\n',
          },
          analysisOptions: excluded
              ? '''
analyzer:
  exclude:
    - tool/**
'''
              : null,
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);
        const generatedId =
            'dart-generated:execution_roots/tool/generated_launcher.g.dart';

        expect(
          snapshot.roots.map((root) => root.nodeId),
          contains(generatedId),
        );
        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(
            contains(
              'dart:execution_roots/tool/generated_launcher.g.dart#main',
            ),
          ),
        );
        expect(
          snapshot.roots.map((root) => root.nodeId),
          contains('dart:execution_roots/lib/worker.dart'),
        );
        expect(
          snapshot.issues,
          contains(
            predicate<DartExecutionContextIssue>(
              (issue) => issue.code == 'generated-executable-main-incomplete',
            ),
          ),
        );
        if (excluded) {
          expect(
            snapshot.issues,
            contains(
              predicate<DartExecutionContextIssue>(
                (issue) =>
                    issue.code == 'standard-executable-analyzer-excluded' &&
                    issue.requiresGlobalBlocker,
              ),
            ),
          );
        }

        final analysis = await ProjectAnalyzer(
          project: fixture.project,
          only: const {'dart'},
        ).analyze();
        expect(
          analysis.graph.node(generatedId)?.kind,
          NodeKind.generatedArtifact,
        );
        expect(analysis.graphIntegrity.danglingEdges, isEmpty);
        expect(analysis.graphIntegrity.danglingRootIds, isEmpty);
        expect(analysis.graphIntegrity.auxiliaryRegistryIssues, isEmpty);
        expect(
          analysis.findings.map((finding) => finding.node.id),
          isNot(contains(generatedId)),
        );
        expect(
          analysis.graph.nodes.map((node) => node.id),
          isNot(
            contains(
              'dart:execution_roots/tool/generated_launcher.g.dart#main',
            ),
          ),
        );
      });
    }

    test(
      'configured generated entrypoint uses only a generated artifact root',
      () async {
        final target = BuildTarget(
          name: 'generated',
          platform: 'android',
          entrypoint: 'tool/configured_main.g.dart',
        );
        final fixture = await _createExecutionRootFixture(
          {'tool/configured_main.g.dart': 'void main() {}\n'},
          targets: [target],
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));
        const generatedId =
            'dart-generated:execution_roots/tool/configured_main.g.dart';
        const editableLibraryId =
            'dart:execution_roots/tool/configured_main.g.dart';

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);
        final configuredRoots = snapshot.roots
            .where((root) => root.configuredTarget == target)
            .toList();

        expect(configuredRoots.map((root) => root.nodeId).toSet(), {
          generatedId,
        });
        expect(
          configuredRoots.single.subject,
          DartExecutionRootSubject.generatedArtifact,
        );
        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(
            anyOf(
              contains(editableLibraryId),
              contains('$editableLibraryId#main'),
            ),
          ),
        );

        final analysis = await ProjectAnalyzer(
          project: fixture.project,
          only: const {'dart'},
        ).analyze();
        expect(
          analysis.graph.node(generatedId)?.kind,
          NodeKind.generatedArtifact,
        );
        expect(analysis.graphIntegrity.danglingEdges, isEmpty);
        expect(analysis.graphIntegrity.danglingRootIds, isEmpty);
        expect(
          analysis.findings.map((finding) => finding.node.id),
          isNot(contains(generatedId)),
        );
      },
    );

    for (final excluded in const [false, true]) {
      test(
        '${excluded ? 'analyzer-excluded' : 'visible'} configured generated '
        'entrypoint outside standard surfaces is inventoried exactly',
        () async {
          final target = BuildTarget(
            name: 'generated-script',
            platform: 'android',
            entrypoint: 'scripts/configured_main.g.dart',
          );
          final fixture = await _createExecutionRootFixture(
            {'scripts/configured_main.g.dart': 'void main() {}\n'},
            targets: [target],
            analysisOptions: excluded
                ? '''
analyzer:
  exclude:
    - scripts/**
'''
                : null,
          );
          addTearDown(() => fixture.project.root.deleteSync(recursive: true));
          final configuredPath = p.normalize(
            p.absolute(
              p.join(
                fixture.project.root.path,
                'scripts',
                'configured_main.g.dart',
              ),
            ),
          );
          const generatedId =
              'dart-generated:execution_roots/scripts/configured_main.g.dart';
          const editableLibraryId =
              'dart:execution_roots/scripts/configured_main.g.dart';

          expect(fixture.workspace.dartFiles, contains(configuredPath));

          final snapshot = await DefaultDartExecutionContextService(
            workspace: fixture.workspace,
          ).resolve(fixture.project);
          final configuredRoots = snapshot.roots
              .where((root) => root.configuredTarget == target)
              .toList();

          expect(configuredRoots.map((root) => root.nodeId).toSet(), {
            generatedId,
          });
          expect(
            configuredRoots.single.subject,
            DartExecutionRootSubject.generatedArtifact,
          );
          expect(
            snapshot.roots.map((root) => root.nodeId),
            isNot(
              anyOf(
                contains(editableLibraryId),
                contains('$editableLibraryId#main'),
              ),
            ),
          );

          final analysis = await ProjectAnalyzer(
            project: fixture.project,
            only: const {'dart'},
          ).analyze();
          expect(
            analysis.graph.node(generatedId)?.kind,
            NodeKind.generatedArtifact,
          );
          expect(analysis.graphIntegrity.danglingEdges, isEmpty);
          expect(analysis.graphIntegrity.danglingRootIds, isEmpty);
          expect(analysis.graphIntegrity.auxiliaryRegistryIssues, isEmpty);
          expect(
            analysis.graph.nodes.map((node) => node.id),
            isNot(
              anyOf(
                contains(editableLibraryId),
                contains('$editableLibraryId#main'),
              ),
            ),
          );
        },
      );
    }

    test('unknown selected main creates a stable global Dart issue', () async {
      final fixture = await _createExecutionRootFixture({
        'scripts/custom.dart': 'void main() {}\n',
      });
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.map((root) => root.nodeId),
        isNot(contains('dart:execution_roots/scripts/custom.dart')),
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'unclassified-dart-entrypoint' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('analyzer-excluded standard executable fails closed', () async {
      final fixture = await _createExecutionRootFixture(
        {'tool/excluded.dart': 'void main() {}\n'},
        analysisOptions: '''
analyzer:
  exclude:
    - tool/**
''',
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      expect(
        fixture.workspace.dartFiles.map(fixture.project.relative),
        isNot(contains('tool/excluded.dart')),
      );

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'standard-executable-analyzer-excluded' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('analyzer-excluded test-runner library fails closed', () async {
      final fixture = await _createExecutionRootFixture(
        {'integration_test/excluded_test.dart': 'void registerTest() {}\n'},
        analysisOptions: '''
analyzer:
  exclude:
    - integration_test/**
''',
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));
      expect(
        fixture.workspace.dartFiles.map(fixture.project.relative),
        isNot(contains('integration_test/excluded_test.dart')),
      );

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'standard-executable-analyzer-excluded' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test(
      'nested package executables are not selected roots or blockers',
      () async {
        final fixture = await _createExecutionRootFixture({
          'tool/run.dart': 'void main() {}\n',
          'nested/pubspec.yaml':
              'name: nested_owner\nenvironment:\n  sdk: ^3.9.0\n',
          'nested/tool/nested.dart': 'void main() {}\n',
        }, includeNestedPackage: true);
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(contains(contains('nested/tool/nested.dart'))),
        );
        expect(
          snapshot.issues.where(
            (issue) => issue.reason.contains('nested/tool/nested.dart'),
          ),
          isEmpty,
        );
      },
    );
  });

  group('Isolate.spawnUri execution roots', () {
    test('direct configured boundary also retains imported and auxiliary '
        'caller provenance', () async {
      final android = BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/android.dart',
      );
      final ios = BuildTarget(
        name: 'ios',
        platform: 'ios',
        entrypoint: 'lib/ios.dart',
      );
      final fixture = await _createExecutionRootFixture(
        {
          'lib/android.dart': '''
import 'dart:isolate';
void main() => launch();
void launch() {
  Isolate.spawnUri(Uri.parse('worker.dart'), const [], null);
}
''',
          'lib/ios.dart': '''
import 'android.dart';
void main() => launch();
''',
          'tool/launcher.dart': '''
import '../lib/android.dart';
void main() => launch();
''',
          'test/launcher_test.dart': '''
import '../lib/android.dart';
void exercise() => launch();
''',
          'bin/launcher.dart': '''
import '../lib/android.dart';
void main() => launch();
''',
          'lib/worker.dart': '''
import 'branch_default.dart'
  if (dart.library.html) 'branch_web.dart'
  if (dart.library.io) 'branch_io.dart';
void main() => selectedBranch();
''',
          'lib/branch_default.dart': 'void selectedBranch() {}\n',
          'lib/branch_web.dart': 'void selectedBranch() {}\n',
          'lib/branch_io.dart': 'void selectedBranch() {}\n',
        },
        targets: [android, ios],
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final analysis = await ProjectAnalyzer(
        project: fixture.project,
        only: const {'dart'},
      ).analyze();
      final spawnTargets = analysis.graph.auxiliaryExecutionTargets
          .where((target) => target.reason.contains('spawnUri'))
          .toList();

      expect(
        spawnTargets
            .map((target) => target.sourceConfiguredTarget)
            .whereType<BuildTarget>()
            .toSet(),
        {android, ios},
      );
      expect(
        spawnTargets,
        contains(
          predicate<AuxiliaryExecutionTarget>(
            (target) =>
                !target.environmentComplete &&
                target.sourceConfiguredTarget == null,
          ),
        ),
      );
      for (final branch in const [
        'branch_default.dart',
        'branch_web.dart',
        'branch_io.dart',
      ]) {
        final matching = analysis.findings.where(
          (finding) =>
              finding.node.id ==
              'dart:execution_roots/lib/$branch#selectedBranch',
        );
        if (matching.isEmpty) {
          expect(
            analysis.graph.node(
              'dart:execution_roots/lib/$branch#selectedBranch',
            ),
            isNotNull,
            reason: branch,
          );
          continue;
        }
        final finding = matching.single;
        expect(finding.confidence, Confidence.review, reason: branch);
        expect(finding.predicates.notRetained, isFalse, reason: branch);
        expect(finding.proposedAction, isNull, reason: branch);
      }
    });

    test(
      'finite local URI alternatives preserve every full source target',
      () async {
        final fixture = await _createSpawnUriFixture(
          mainSource: '''
import 'dart:isolate';

void main() {}

void launch(bool first) {
  Isolate.spawnUri(
    Uri.parse(first ? 'worker_a.dart' : 'worker_b.dart'),
    const [],
    null,
  );
}
''',
          workerSources: const {
            'lib/worker_a.dart': 'void main() {}\n',
            'lib/worker_b.dart': 'void main() {}\n',
          },
          targets: [
            BuildTarget(
              name: 'android-debug',
              platform: 'android',
              flavor: 'debug',
              entrypoint: 'lib/main.dart',
              dartDefines: const {'MODE': 'debug'},
            ),
            BuildTarget(
              name: 'windows-release',
              platform: 'windows',
              flavor: 'release',
              entrypoint: 'lib/main.dart',
              dartDefines: const {'MODE': 'release'},
            ),
          ],
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);
        final spawnTargets = snapshot.auxiliaryExecutionTargets
            .where((target) => target.reason.contains('spawnUri'))
            .toList();

        expect(spawnTargets, hasLength(6));
        expect(
          spawnTargets
              .map((target) => target.sourceConfiguredTarget)
              .whereType<BuildTarget>()
              .toSet(),
          fixture.project.targets.toSet(),
        );
        expect(
          spawnTargets
              .map((target) => target.sourceConfiguredTarget)
              .whereType<BuildTarget>()
              .map((target) => target.dartDefines['MODE']),
          containsAll({'debug', 'release'}),
        );
        for (final worker in const ['worker_a.dart', 'worker_b.dart']) {
          final libraryId = 'dart:spawn_uri/lib/$worker';
          final roots = snapshot.roots
              .where(
                (root) =>
                    root.owningLibraryId == libraryId &&
                    root.reason.contains('spawnUri'),
              )
              .toList();
          expect(roots, hasLength(6), reason: worker);
          expect(roots.map((root) => root.nodeId).toSet(), {
            libraryId,
            '$libraryId#main',
          }, reason: worker);
        }
        expect(
          snapshot.issues.where((issue) => issue.code.startsWith('spawn-uri-')),
          isEmpty,
        );
        expect(
          snapshot.issues.where(
            (issue) => issue.code == 'unclassified-dart-entrypoint',
          ),
          isEmpty,
        );
      },
    );

    test('dynamic URI fails closed without a guessed root', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {}
void launch(Uri target) {
  Isolate.spawnUri(target, const [], null);
}
''',
        workerSources: const {'lib/worker.dart': 'void main() {}\n'},
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.where((root) => root.reason.contains('spawnUri')),
        isEmpty,
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-dynamic' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('mutable Uri and String bindings never become proven roots', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  var uri = Uri.parse('worker_a.dart');
  uri = Uri.parse('worker_b.dart');
  Isolate.spawnUri(uri, const [], null);

  var path = 'worker_a.dart';
  path = 'worker_b.dart';
  Isolate.spawnUri(Uri.parse(path), const [], null);
}
''',
        workerSources: const {
          'lib/worker_a.dart': 'void main() {}\n',
          'lib/worker_b.dart': 'void main() {}\n',
        },
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.where((root) => root.reason.contains('spawnUri')),
        isEmpty,
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-dynamic' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('explicit Uri.file windows option fails closed', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(
    Uri.file('worker.dart', windows: false),
    const [],
    null,
  );
}
''',
        workerSources: const {'lib/worker.dart': 'void main() {}\n'},
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.where((root) => root.reason.contains('spawnUri')),
        isEmpty,
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) => issue.code == 'spawn-uri-dynamic',
          ),
        ),
      );
    });

    for (final caller in const {
      'tool': 'tool/launcher.dart',
      'test': 'test/launcher_test.dart',
      'bin': 'bin/launcher.dart',
    }.entries) {
      test('${caller.key} caller uses an incomplete provenance context that '
          'retains every worker branch', () async {
        final hasMain = caller.key != 'test';
        final fixture = await _createExecutionRootFixture({
          caller.value:
              '''
import 'dart:isolate';
${hasMain ? 'void main() => launch();' : ''}
void launch() {
  Isolate.spawnUri(Uri.parse('../lib/worker.dart'), const [], null);
}
''',
          'lib/worker.dart': '''
import 'branch_default.dart'
  if (dart.library.html) 'branch_web.dart'
  if (dart.library.io) 'branch_io.dart';
void main() => selectedBranch();
''',
          'lib/branch_default.dart': 'void selectedBranch() {}\n',
          'lib/branch_web.dart': 'void selectedBranch() {}\n',
          'lib/branch_io.dart': 'void selectedBranch() {}\n',
        });
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final analysis = await ProjectAnalyzer(
          project: fixture.project,
          only: const {'dart'},
        ).analyze();
        final spawnTargets = analysis.graph.auxiliaryExecutionTargets
            .where((target) => target.reason.contains('spawnUri'))
            .toList();

        expect(
          spawnTargets,
          contains(
            predicate<AuxiliaryExecutionTarget>(
              (target) =>
                  !target.environmentComplete &&
                  target.sourceConfiguredTarget == null,
            ),
          ),
        );
        for (final branch in const [
          'branch_default.dart',
          'branch_web.dart',
          'branch_io.dart',
        ]) {
          final matching = analysis.findings.where(
            (finding) =>
                finding.node.id ==
                'dart:execution_roots/lib/$branch#selectedBranch',
          );
          if (matching.isEmpty) {
            expect(
              analysis.graph.node(
                'dart:execution_roots/lib/$branch#selectedBranch',
              ),
              isNotNull,
              reason: branch,
            );
            continue;
          }
          final finding = matching.single;
          expect(finding.confidence, Confidence.review, reason: branch);
          expect(finding.predicates.notRetained, isFalse, reason: branch);
          expect(finding.proposedAction, isNull, reason: branch);
        }
      });
    }

    test('missing local URI target fails closed', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(Uri.parse('missing.dart'), const [], null);
}
''',
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-target-missing' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('URI escaping the selected package fails closed', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(Uri.parse('../../escape.dart'), const [], null);
}
''',
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-target-escape' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test('symlink URI target fails closed without alias roots', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(Uri.parse('alias.dart'), const [], null);
}
''',
        workerSources: const {'lib/worker.dart': 'void main() {}\n'},
      );
      Link(
        p.join(fixture.project.root.path, 'lib/alias.dart'),
      ).createSync(p.join(fixture.project.root.path, 'lib/worker.dart'));
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.map((root) => root.nodeId),
        isNot(contains(contains('lib/alias.dart'))),
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-target-symlink' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test(
      'nested external URI target fails closed without parent IDs',
      () async {
        final fixture = await _createSpawnUriFixture(
          mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(
    Uri.parse('../nested/lib/worker.dart'),
    const [],
    null,
  );
}
''',
          workerSources: const {
            'nested/pubspec.yaml':
                'name: nested_spawn\nenvironment:\n  sdk: ^3.9.0\n',
            'nested/lib/worker.dart': 'void main() {}\n',
          },
          includeNestedPackage: true,
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        expect(
          snapshot.roots.map((root) => root.nodeId),
          isNot(contains(contains('nested/lib/worker.dart'))),
        );
        expect(
          snapshot.issues,
          contains(
            predicate<DartExecutionContextIssue>(
              (issue) =>
                  issue.code == 'spawn-uri-target-external' &&
                  issue.requiresGlobalBlocker,
            ),
          ),
        );
      },
    );

    test('analyzer-excluded URI target fails closed', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(Uri.parse('worker.dart'), const [], null);
}
''',
        workerSources: const {'lib/worker.dart': 'void main() {}\n'},
        analysisOptions: '''
analyzer:
  exclude:
    - lib/worker.dart
''',
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.where((root) => root.reason.contains('spawnUri')),
        isEmpty,
      );
      expect(
        snapshot.issues,
        contains(
          predicate<DartExecutionContextIssue>(
            (issue) =>
                issue.code == 'spawn-uri-target-unresolved' &&
                issue.requiresGlobalBlocker,
          ),
        ),
      );
    });

    test(
      'resolved same-named local spawnUri is not an isolate boundary',
      () async {
        final fixture = await _createSpawnUriFixture(
          mainSource: '''
void main() {
  Isolate.spawnUri(Uri.parse('not-a-boundary.dart'), const [], null);
}
class Isolate {
  static void spawnUri(Uri uri, List<String> args, Object? message) {}
}
''',
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        expect(
          snapshot.auxiliaryExecutionTargets.where(
            (target) => target.reason.contains('spawnUri'),
          ),
          isEmpty,
        );
        expect(
          snapshot.issues.where((issue) => issue.code.startsWith('spawn-uri-')),
          isEmpty,
        );
      },
    );

    for (final option in const {
      'environment': "environment: const {'MODE': 'worker'}",
      'packageConfig':
          "packageConfig: Uri.parse('../.dart_tool/package_config.json')",
      'automaticPackageResolution': 'automaticPackageResolution: true',
    }.entries) {
      test('non-default ${option.key} fails closed', () async {
        final fixture = await _createSpawnUriFixture(
          mainSource:
              '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(
    Uri.parse('worker.dart'),
    const [],
    null,
    ${option.value},
  );
}
''',
          workerSources: const {'lib/worker.dart': 'void main() {}\n'},
        );
        addTearDown(() => fixture.project.root.deleteSync(recursive: true));

        final snapshot = await DefaultDartExecutionContextService(
          workspace: fixture.workspace,
        ).resolve(fixture.project);

        expect(
          snapshot.issues,
          contains(
            predicate<DartExecutionContextIssue>(
              (issue) =>
                  issue.code == 'spawn-uri-options-incomplete' &&
                  issue.requiresGlobalBlocker,
            ),
          ),
          reason: option.key,
        );
        expect(
          snapshot.roots.where((root) => root.reason.contains('spawnUri')),
          isEmpty,
          reason: option.key,
        );
      });
    }

    test('explicit inherited option defaults preserve a local root', () async {
      final fixture = await _createSpawnUriFixture(
        mainSource: '''
import 'dart:isolate';
void main() {
  Isolate.spawnUri(
    Uri.parse('worker.dart'),
    const [],
    null,
    environment: null,
    packageConfig: null,
    automaticPackageResolution: false,
  );
}
''',
        workerSources: const {'lib/worker.dart': 'void main() {}\n'},
      );
      addTearDown(() => fixture.project.root.deleteSync(recursive: true));

      final snapshot = await DefaultDartExecutionContextService(
        workspace: fixture.workspace,
      ).resolve(fixture.project);

      expect(
        snapshot.roots.map((root) => root.nodeId),
        contains('dart:spawn_uri/lib/worker.dart#main'),
      );
      expect(
        snapshot.issues.where(
          (issue) => issue.code == 'spawn-uri-options-incomplete',
        ),
        isEmpty,
      );
    });
  });
}

final class _ExecutionRootFixture {
  const _ExecutionRootFixture({required this.project, required this.workspace});

  final ProjectContext project;
  final DartAnalysisWorkspace workspace;
}

Future<_ExecutionRootFixture> _createExecutionRootFixture(
  Map<String, String> sources, {
  String? analysisOptions,
  bool includeNestedPackage = false,
  List<BuildTarget>? targets,
}) async {
  final root = await Directory.systemTemp.createTemp('execution-roots-');
  File(p.join(root.path, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('name: execution_roots\nenvironment:\n  sdk: ^3.9.0\n');
  File(p.join(root.path, 'lib/main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void main() {}\n');
  for (final entry in sources.entries) {
    File(p.join(root.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  if (analysisOptions != null) {
    File(
      p.join(root.path, 'analysis_options.yaml'),
    ).writeAsStringSync(analysisOptions);
  }
  _writePackageConfig(root, '''
{"configVersion":2,"packages":[
  {"name":"execution_roots","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}${includeNestedPackage ? ',\n  {"name":"nested_owner","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}' : ''}
]}
''');
  final project = ProjectContext(
    root: root,
    pubspec: const {'name': 'execution_roots'},
    packageName: 'execution_roots',
    targets:
        targets ??
        [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
    rootCoverage: RootCoverage.applicationApi(),
  );
  return _ExecutionRootFixture(
    project: project,
    workspace: DartAnalysisWorkspace(project),
  );
}

Future<_ExecutionRootFixture> _createSpawnUriFixture({
  required String mainSource,
  Map<String, String> workerSources = const {},
  List<BuildTarget>? targets,
  String? analysisOptions,
  bool includeNestedPackage = false,
}) async {
  final root = await Directory.systemTemp.createTemp('spawn-uri-');
  File(p.join(root.path, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('name: spawn_uri\nenvironment:\n  sdk: ^3.9.0\n');
  File(p.join(root.path, 'lib/main.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync(mainSource);
  for (final entry in workerSources.entries) {
    File(p.join(root.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  if (analysisOptions != null) {
    File(
      p.join(root.path, 'analysis_options.yaml'),
    ).writeAsStringSync(analysisOptions);
  }
  _writePackageConfig(root, '''
{"configVersion":2,"packages":[
  {"name":"spawn_uri","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}${includeNestedPackage ? ',\n  {"name":"nested_spawn","rootUri":"../nested/","packageUri":"lib/","languageVersion":"3.9"}' : ''}
]}
''');
  final project = ProjectContext(
    root: root,
    pubspec: const {'name': 'spawn_uri'},
    packageName: 'spawn_uri',
    targets:
        targets ??
        [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
        ],
    rootCoverage: RootCoverage.applicationApi(),
  );
  return _ExecutionRootFixture(
    project: project,
    workspace: DartAnalysisWorkspace(project),
  );
}

void _writePackageConfig(Directory root, String contents) {
  File(p.join(root.path, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
