import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_identity.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_inventory.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_resolution_resolver.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> _loadFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_resolution_test')),
);

Future<ProjectContext> _loadRuntimeFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_runtime_test')),
);

Future<ProjectContext> _loadErrorFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_resolution_error_test')),
);

Future<ProjectContext> _loadFactoryFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_factory_resolution_test')),
);

Future<ProjectContext> _loadImmediateFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_immediate_resolution_test')),
);

Future<ProjectContext> _loadDynamicLookupFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_dynamic_lookup_test')),
);

Future<({DiInventory inventory, DiResolutionResolver resolver})> _resolve(
  ProjectContext project, {
  DartAnalysisWorkspace? workspace,
}) async {
  final sharedWorkspace = workspace ?? DartAnalysisWorkspace(project);
  final inventory = await DiInventory.discover(
    project,
    workspace: sharedWorkspace,
  );
  final resolver = DiResolutionResolver(project, inventory);
  await resolver.analyzeProject(workspace: sharedWorkspace);
  return (inventory: inventory, resolver: resolver);
}

void main() {
  group('DiResolutionResolver', () {
    test(
      'resolves exact method, async, nullable, callable, and type lookups',
      () async {
        final project = await _loadFixture();
        final result = await _resolve(project);
        final resolver = result.resolver;

        expect(resolver.references, hasLength(13));
        expect(
          resolver.references.map((reference) => reference.callerId),
          containsAll(<String>[
            'dart:get_it_resolution_test/lib/main.dart#topLevelService',
            'dart:get_it_resolution_test/lib/main.dart#inferredService',
            'dart:get_it_resolution_test/lib/main.dart#resolveTopLevel',
            'dart:get_it_resolution_test/lib/main.dart#Consumer',
            'dart:get_it_resolution_test/lib/main.dart#nestedNonRegistrationClosure',
          ]),
        );
        expect(
          resolver.references.every(
            (reference) =>
                result.inventory.byNodeId.containsKey(reference.diNodeId),
          ),
          isTrue,
        );
      },
    );

    test('resolves the complete named and unnamed getAll set', () async {
      final project = await _loadFixture();
      final result = await _resolve(project);
      final allReferences = result.resolver.references
          .where((reference) => reference.description.contains('getAll'))
          .toList();

      expect(allReferences, hasLength(4));
      expect(
        allReferences.map((reference) => reference.diNodeId).toSet(),
        hasLength(2),
      );
      final names = allReferences
          .map(
            (reference) =>
                result.inventory.byNodeId[reference.diNodeId]!.instanceName,
          )
          .toSet();
      expect(names, contains(isA<DiAbsentInstanceName>()));
      expect(
        names,
        contains(
          predicate<DiInstanceName>(
            (name) =>
                name is DiConstantInstanceName && name.value == 'all-named',
          ),
        ),
      );
    });

    test(
      'blocks unknown, dynamic, ambiguous, and runtime lookup forms',
      () async {
        final project = await _loadFixture();
        final result = await _resolve(project);
        final blockers = result.resolver.blockers;

        expect(
          blockers.map((blocker) => blocker.reason),
          containsAll(<Matcher>[
            contains('non-canonical service type'),
            contains('dynamic instanceName'),
            contains('constant canonical Type'),
            contains('multiple registrations'),
            contains('unknown name or scope'),
            contains('does not match a registered service'),
            contains('non-local fromAllScopes request'),
            contains('do not support a type: override'),
          ]),
        );
        expect(
          blockers.where((blocker) => blocker.reason.contains('multiple')),
          everyElement(
            predicate<DiBlocker>(
              (blocker) => blocker.affectedNodeIds.length == 2,
            ),
          ),
        );
        expect(
          blockers.where(
            (blocker) => blocker.reason.contains('does not match'),
          ),
          everyElement(
            predicate<DiBlocker>(
              (blocker) =>
                  blocker.affectedNamespace ==
                  DiInventory.namespaceFor(project),
            ),
          ),
        );
        expect(
          blockers.where((blocker) => blocker.reason.contains('fromAllScopes')),
          everyElement(
            predicate<DiBlocker>(
              (blocker) => blocker.affectedNodeIds.length == 2,
            ),
          ),
        );
        expect(
          blockers.where((blocker) => blocker.reason.contains('onlyInScope')),
          everyElement(
            predicate<DiBlocker>(
              (blocker) => blocker.affectedNodeIds.length == 2,
            ),
          ),
        );
      },
    );

    test(
      'onlyInScope wins over fromAllScopes and never resolves base entries',
      () async {
        final project = await _loadFixture();
        final result = await _resolve(project);
        final blockers = result.resolver.blockers
            .where((blocker) => blocker.reason.contains('onlyInScope'))
            .toList();

        expect(blockers, hasLength(2));
        expect(
          result.resolver.references.where(
            (reference) => reference.location.contains('main.dart:68:'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'does not turn isRegistered or foreign lookups into liveness',
      () async {
        final project = await _loadFixture();
        final result = await _resolve(project);

        expect(
          result.resolver.references.map((reference) => reference.callerId),
          isNot(
            contains('dart:get_it_resolution_test/lib/main.dart#foreignLookup'),
          ),
        );
      },
    );

    test(
      'blocks generated consumers instead of making dangling references',
      () async {
        final project = await _loadFixture();
        final result = await _resolve(project);
        final generated = result.resolver.blockers.where(
          (blocker) => blocker.reason.contains('unmodeled Dart source'),
        );

        expect(generated, hasLength(1));
        expect(
          generated.single.location,
          startsWith('lib/generated/consumer.dart:'),
        );
        expect(generated.single.sourceNodeId, isNull);
        expect(generated.single.affectedNodeIds, hasLength(1));
      },
    );

    test('shares analyzer resolutions with registration inventory', () async {
      final project = await _loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await DiInventory.discover(
        project,
        workspace: workspace,
      );
      final resolutionCount = workspace.resolutionCount;
      final resolver = DiResolutionResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);

      expect(workspace.resolutionCount, resolutionCount);
    });

    test('exposes deterministic de-duplicated immutable findings', () async {
      final project = await _loadFixture();
      final workspace = DartAnalysisWorkspace(project);
      final inventory = await DiInventory.discover(
        project,
        workspace: workspace,
      );
      final resolver = DiResolutionResolver(project, inventory);

      await resolver.analyzeProject(workspace: workspace);
      final firstReferences = resolver.references;
      final firstBlockers = resolver.blockers;
      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.references
            .map((reference) => '${reference.location}:${reference.diNodeId}')
            .toList(),
        orderedEquals(
          firstReferences
              .map((reference) => '${reference.location}:${reference.diNodeId}')
              .toList(),
        ),
      );
      expect(
        resolver.blockers
            .map((blocker) => '${blocker.location}:${blocker.reason}')
            .toList(),
        orderedEquals(
          firstBlockers
              .map((blocker) => '${blocker.location}:${blocker.reason}')
              .toList(),
        ),
      );
      expect(
        () => resolver.references.add(firstReferences.first),
        throwsUnsupportedError,
      );
      expect(
        () => resolver.blockers.add(firstBlockers.first),
        throwsUnsupportedError,
      );
    });

    test('does not classify foreign callable APIs as GetIt', () async {
      final project = await _loadFixture();
      final result = await _resolve(project);

      expect(
        result.resolver.references.where(
          (reference) => reference.callerId.endsWith('#foreignLookup'),
        ),
        isEmpty,
      );
    });

    test(
      'blocks lookups when scope or multiple registration state is unknown',
      () async {
        final project = await _loadRuntimeFixture();
        final result = await _resolve(project);

        expect(result.resolver.references, isEmpty);
        expect(
          result.resolver.blockers.map((blocker) => blocker.reason),
          containsAll(<Matcher>[
            contains('unknown name or scope'),
            contains('complete registration set'),
          ]),
        );
      },
    );

    test(
      'attributes factory closure lookups to their registration occurrence',
      () async {
        final project = await _loadFactoryFixture();
        final result = await _resolve(project);
        final bar = result.inventory.entries.singleWhere(
          (entry) => entry.location.startsWith('lib/main.dart:18:'),
        );
        final baz = result.inventory.entries.singleWhere(
          (entry) => entry.location.startsWith('lib/main.dart:19:'),
        );
        final factoryReferences = result.resolver.references
            .where(
              (reference) => reference.location.startsWith('lib/main.dart:'),
            )
            .toList();

        expect(
          factoryReferences.map((reference) => reference.callerId),
          containsAll(<String>[bar.nodeId, baz.nodeId]),
        );
        expect(
          factoryReferences.map((reference) => reference.callerId),
          isNot(
            contains(
              'dart:get_it_factory_resolution_test/lib/main.dart#configure',
            ),
          ),
        );
      },
    );

    test('keeps immediate factory lookups owned by setup code', () async {
      final project = await _loadImmediateFixture();
      final result = await _resolve(project);

      expect(result.resolver.references, hasLength(1));
      expect(
        result.resolver.references.single.callerId,
        'dart:get_it_immediate_resolution_test/lib/main.dart#configure',
      );
      expect(result.resolver.blockers, isEmpty);
    });

    test(
      'blocks unresolved lifecycle and readiness aliases but ignores helpers',
      () async {
        final project = await _loadErrorFixture();
        final result = await _resolve(project);
        final aliasBlockers = result.resolver.blockers
            .where(
              (blocker) =>
                  blocker.reason.contains('analyzer errors prevent semantic') &&
                  blocker.location?.startsWith('lib/main.dart:') == true,
            )
            .toList();

        expect(result.resolver.references, isEmpty);
        expect(aliasBlockers, hasLength(12));
        expect(
          aliasBlockers.every(
            (blocker) =>
                blocker.affectedNamespace ==
                    DiInventory.namespaceFor(project) &&
                blocker.sourceNodeId == null,
          ),
          isTrue,
        );
      },
    );

    test(
      'blocks diagnostic-free dynamic GetIt access without an edge',
      () async {
        final project = await _loadDynamicLookupFixture();
        final result = await _resolve(project);
        final blockers = result.resolver.blockers;

        expect(blockers, hasLength(3));
        expect(
          blockers.map((blocker) => blocker.location),
          everyElement(startsWith('lib/main.dart:')),
        );
        expect(
          blockers.every(
            (blocker) =>
                blocker.reason.contains('dynamic or unresolved') &&
                blocker.sourceNodeId == null &&
                blocker.affectedNamespace == DiInventory.namespaceFor(project),
          ),
          isTrue,
        );
        expect(result.resolver.references, isEmpty);
      },
    );
  });
}
