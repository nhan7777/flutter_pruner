import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_identity.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_inventory.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/get_it_test')));

Future<ProjectContext> loadRuntimeFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_runtime_test')),
);

Future<ProjectContext> loadMultiContainerFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_multi_container_test')),
);

Future<ProjectContext> loadDynamicReceiverFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_dynamic_receiver_test')),
);

Future<DiInventory> discover(
  ProjectContext project,
  DartAnalysisWorkspace workspace,
) => DiInventory.discover(project, workspace: workspace);

void main() {
  group('DiInventory', () {
    test(
      'discovers registrations through a re-exported GetIt sublibrary',
      () async {
        final project = await loadFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(inventory.byNodeId, isNotEmpty);
        expect(
          inventory.entries.map((entry) => entry.location),
          everyElement(startsWith('lib/main.dart:')),
        );
        expect(
          inventory.entries.map((entry) => entry.origin),
          everyElement(Uri.parse('package:get_it_test/main.dart')),
        );
      },
    );

    test(
      'uses inferred and explicit semantic types across registration families',
      () async {
        final project = await loadFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(
          inventory.entries.map((entry) => entry.apiName),
          orderedEquals(<String>[
            'registerSingleton',
            'registerSingleton',
            'registerSingleton',
            'registerSingleton',
            'registerSingleton',
            'registerSingleton',
            'registerSingleton',
            'registerFactory',
            'registerCachedFactory',
            'registerFactoryParam',
            'registerCachedFactoryParam',
            'registerFactoryAsync',
            'registerCachedFactoryAsync',
            'registerFactoryParamAsync',
            'registerCachedFactoryParamAsync',
            'registerSingletonIfAbsent',
            'registerSingletonWithDependencies',
            'registerSingletonAsync',
            'registerLazySingleton',
            'registerLazySingletonAsync',
            'registerSingleton',
          ]),
        );
        expect(
          inventory.entries.map((entry) => entry.type).toSet(),
          hasLength(4),
        );
        expect(
          inventory.entries
              .firstWhere((entry) => entry.apiName == 'registerFactory')
              .type,
          inventory.entries
              .firstWhere((entry) => entry.apiName == 'registerCachedFactory')
              .type,
        );
      },
    );

    test(
      'retains absent, constant empty, and dynamic instance-name states distinctly',
      () async {
        final project = await loadFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(
          inventory.entries.any(
            (entry) => entry.instanceName is DiAbsentInstanceName,
          ),
          isTrue,
        );
        expect(
          inventory.entries.any(
            (entry) =>
                entry.instanceName is DiConstantInstanceName &&
                (entry.instanceName as DiConstantInstanceName).value.isEmpty,
          ),
          isTrue,
        );
        final dynamicEntry = inventory.entries.singleWhere(
          (entry) => entry.instanceName is DiDynamicInstanceName,
        );
        expect(dynamicEntry.lookup, isNull);
        expect(
          inventory.blockers.any(
            (blocker) => blocker.affectedNodeIds.contains(dynamicEntry.nodeId),
          ),
          isTrue,
        );
      },
    );

    test(
      'preserves ordered exact duplicate candidates in a clean base scope',
      () async {
        final project = await loadFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        final duplicates = inventory.entries
            .where(
              (entry) =>
                  entry.instanceName is DiConstantInstanceName &&
                  (entry.instanceName as DiConstantInstanceName).value ==
                      'duplicate',
            )
            .toList();
        expect(duplicates, hasLength(2));
        expect(duplicates[0].nodeId, isNot(duplicates[1].nodeId));
        final lookup = duplicates.first.lookup!;
        expect(
          inventory.entriesFor(lookup).map((entry) => entry.nodeId),
          orderedEquals(<String>[duplicates[0].nodeId, duplicates[1].nodeId]),
        );
        expect(
          inventory.entries.every((entry) => entry.scope is DiBaseScope),
          isTrue,
        );
        expect(
          inventory.entries.every((entry) => entry.isExactBaseScope),
          isTrue,
        );
      },
    );

    test(
      'records exact and dynamic dependsOn constructs without guessing',
      () async {
        final project = await loadFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        final exact = inventory.entries.singleWhere(
          (entry) => entry.dependsOn.isNotEmpty,
        );
        expect(exact.dependsOn, hasLength(1));
        expect(
          inventory.blockers.any(
            (blocker) => blocker.reason.contains('dependsOn'),
          ),
          isTrue,
        );
      },
    );

    test('ignores foreign and in-package helper API collisions', () async {
      final project = await loadFixture();
      final inventory = await discover(project, DartAnalysisWorkspace(project));

      expect(
        inventory.entries.every(
          (entry) => entry.origin == Uri.parse('package:get_it_test/main.dart'),
        ),
        isTrue,
      );
      expect(inventory.entries, hasLength(21));
      expect(
        inventory.blockers,
        isNot(
          contains(
            predicate<DiBlocker>(
              (blocker) => blocker.reason.contains('GetIt API'),
            ),
          ),
        ),
      );
    });

    test(
      'excludes every candidate after resolved runtime state changes',
      () async {
        final project = await loadRuntimeFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(inventory.byLookup, isEmpty);
        expect(
          inventory.entries.every((entry) => entry.scope is DiDynamicScope),
          isTrue,
        );
        expect(
          inventory.entries.every((entry) => entry.isExactBaseScope),
          isFalse,
        );
        final runtimeBlockers = inventory.blockers
            .where((blocker) => blocker.reason.contains('GetIt API'))
            .toList();
        expect(
          runtimeBlockers.map((blocker) => blocker.reason),
          containsAll(<Matcher>[
            contains('pushNewScope'),
            contains('enableRegisteringMultipleInstancesOfOneType'),
            contains('allowReassignment'),
            contains('allowRegisterMultipleImplementationsOfoneType'),
            contains('skipDoubleRegistration'),
            contains('reset'),
          ]),
        );
        expect(
          inventory.blockers.every(
            (blocker) =>
                blocker.affectedNamespace != null ||
                blocker.affectedNodeIds.isNotEmpty,
          ),
          isTrue,
        );
        final namespace = runtimeBlockers.first.affectedNamespace!;
        final blocker = Blocker(
          producer: 'get_it',
          reason: 'test runtime state scope',
          affectedNamespace: namespace,
        );
        expect(
          inventory.entries.every(
            (entry) => blocker.couldAddress(entry.nodeId),
          ),
          isTrue,
        );
      },
    );

    test(
      'blocks a resolved GetIt.asNewInstance container without helper noise',
      () async {
        final project = await loadMultiContainerFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(inventory.entries, hasLength(1));
        final blockers = inventory.blockers
            .where((blocker) => blocker.reason.contains('asNewInstance'))
            .toList();
        expect(blockers, hasLength(1));
        expect(
          blockers.single.affectedNamespace,
          DiInventory.namespaceFor(project),
        );
        final blocker = Blocker(
          producer: 'get_it',
          reason: blockers.single.reason,
          affectedNamespace: blockers.single.affectedNamespace,
        );
        expect(blocker.couldAddress(inventory.entries.single.nodeId), isTrue);
      },
    );

    test('blocks a diagnostic-free dynamic registration receiver', () async {
      final project = await loadDynamicReceiverFixture();
      final inventory = await discover(project, DartAnalysisWorkspace(project));

      expect(inventory.entries, isEmpty);
      final blockers = inventory.blockers
          .where((blocker) => blocker.reason.contains('dynamic GetIt receiver'))
          .toList();
      expect(blockers, hasLength(2));
      expect(
        blockers.map((blocker) => blocker.affectedNamespace),
        orderedEquals([
          DiInventory.namespaceFor(project),
          DiInventory.namespaceFor(project),
        ]),
      );
      expect(
        blockers.map((blocker) => blocker.location),
        orderedEquals(['lib/main.dart:9:3', 'lib/main.dart:10:3']),
      );
    });

    test(
      'blocks unresolved GetIt aliases without inventing an entry',
      () async {
        final project = await loadRuntimeFixture();
        final inventory = await discover(
          project,
          DartAnalysisWorkspace(project),
        );

        expect(
          inventory.entries.every(
            (entry) => !entry.location.startsWith('lib/unresolved.dart:'),
          ),
          isTrue,
        );
        final unresolvedBlockers = inventory.blockers
            .where(
              (blocker) =>
                  blocker.reason.contains(
                    'analyzer errors prevent semantic GetIt',
                  ) &&
                  blocker.location!.startsWith('lib/unresolved.dart:'),
            )
            .toList();
        expect(unresolvedBlockers, hasLength(4));
        expect(
          unresolvedBlockers.map((blocker) => blocker.location),
          everyElement(startsWith('lib/unresolved.dart:')),
        );
      },
    );

    test(
      'keeps deterministic results and reuses workspace resolutions',
      () async {
        final project = await loadFixture();
        final workspace = DartAnalysisWorkspace(project);

        final first = await discover(project, workspace);
        final firstResolutionCount = workspace.resolutionCount;
        final second = await discover(project, workspace);

        expect(second.byNodeId.keys, orderedEquals(first.byNodeId.keys));
        expect(
          second.blockers.map((blocker) => blocker.reason),
          orderedEquals(first.blockers.map((blocker) => blocker.reason)),
        );
        expect(workspace.resolutionCount, firstResolutionCount);
      },
    );
  });
}
