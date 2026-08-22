import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_directive_resolver.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_public_surface_resolver.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DartPublicSurfaceResolver', () {
    late Directory root;
    late ProjectContext project;
    late DartAnalysisWorkspace workspace;
    late DartPackageOwnership ownership;
    late List<ResolvedLibraryResult> libraries;

    final webConsumer = AuxiliaryExecutionTarget(
      id: 'aux:external:web-consumer',
      domain: AuxiliaryExecutionDomain.external,
      environmentValues: const {
        'dart.library.io': 'false',
        'dart.library.html': 'true',
        'dart.library.js_interop': 'true',
      },
      environmentComplete: true,
      reason: 'known web consumer',
    );
    final unknownConsumer = AuxiliaryExecutionTarget(
      id: 'aux:external:unknown-consumer',
      domain: AuxiliaryExecutionDomain.external,
      environmentValues: const {},
      environmentComplete: false,
      reason: 'unknown external consumer',
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('g6-public-surface-');
      _write(root, 'pubspec.yaml', '''
name: public_surface_test
environment:
  sdk: ^3.9.0
''');
      _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"public_surface_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      _write(root, 'lib/api.dart', '''
part 'src/api_part.dart';

export 'src/cycle_a.dart';
export 'src/combinators.dart' show Visible, AlsoVisible;
export 'src/combinators.dart' hide Hidden;
export 'src/conditional_default.dart'
    if (dart.library.html == 'true') 'src/conditional_web.dart';
export 'src/missing.dart';

class DirectPublic {}
class _DirectPrivate {}
''');
      _write(root, 'lib/src/api_part.dart', '''
part of '../api.dart';

class PartPublic {}
class _PartPrivate {}
''');
      _write(root, 'lib/src/cycle_a.dart', '''
export 'cycle_b.dart';
class CycleA {}
''');
      _write(root, 'lib/src/cycle_b.dart', '''
export 'cycle_a.dart';
class CycleB {}
''');
      _write(root, 'lib/src/combinators.dart', '''
class Visible {}
class AlsoVisible {}
class Hidden {}
''');
      _write(
        root,
        'lib/src/conditional_default.dart',
        'class DefaultOnly {}\n',
      );
      _write(root, 'lib/src/conditional_web.dart', 'class WebOnly {}\n');
      _write(root, 'lib/part_owner.dart', '''
part 'src/reexport_part.dart';
''');
      _write(root, 'lib/src/reexport_part.dart', '''
part of '../part_owner.dart';
class ReexportedPartPublic {}
class _ReexportedPartPrivate {}
''');
      _write(root, 'lib/reexport_api.dart', "export 'part_owner.dart';\n");
      _write(root, 'lib/cycle_entry_a.dart', '''
export 'cycle_entry_b.dart' show FromB;

class FromA {}
class VisibleThroughCycle {}
''');
      _write(root, 'lib/cycle_entry_b.dart', '''
export 'cycle_entry_a.dart' hide FromA;

class FromB {}
''');

      project = ProjectContext(
        root: root,
        pubspec: const {'name': 'public_surface_test'},
        packageName: 'public_surface_test',
        analysisMode: AnalysisMode.package,
        targets: [
          BuildTarget(
            name: 'package',
            platform: 'web',
            entrypoint: 'lib/api.dart',
          ),
        ],
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.packagePublicApi,
          internalBoundaryComplete: true,
          externalConsumersCovered: false,
          source: 'test',
          publicEntrypoints: const [
            'lib/api.dart',
            'lib/reexport_api.dart',
            'lib/cycle_entry_a.dart',
            'lib/cycle_entry_b.dart',
          ],
        ),
      );
      workspace = DartAnalysisWorkspace(project);
      ownership = DartPackageOwnership.discover(project);
      libraries = await _resolvedLibraries(workspace);
    });

    tearDown(() => root.deleteSync(recursive: true));

    Future<DartPublicSurfaceResolution> resolve(
      List<AuxiliaryExecutionTarget> consumers,
    ) async {
      final contexts = DartExecutionContextSnapshot(
        configuredTargets: project.targets,
        auxiliaryExecutionTargets: consumers,
        roots: const [],
        issues: const [],
      );
      final directives = await DartDirectiveResolver(
        project: project,
        workspace: workspace,
        ownership: ownership,
        contexts: contexts,
        libraries: libraries,
      ).resolve();
      return DartPublicSurfaceResolver(
        project: project,
        ownership: ownership,
        contexts: contexts,
        libraries: libraries,
        directives: directives,
      ).resolve();
    }

    test(
      'exposes direct and part declarations with physical canonical IDs',
      () async {
        final resolution = await resolve([webConsumer]);
        final apiEdges = resolution.edges.where(
          (edge) => edge.publicEntrypointLibraryId.endsWith('/lib/api.dart'),
        );
        final ids = apiEdges.map((edge) => edge.declarationId).toSet();

        expect(
          ids,
          containsAll({
            'dart:public_surface_test/lib/api.dart#DirectPublic',
            'dart:public_surface_test/lib/src/api_part.dart#PartPublic',
          }),
        );
        expect(ids, isNot(contains(contains('#_DirectPrivate'))));
        expect(ids, isNot(contains(contains('#_PartPrivate'))));
        expect(
          apiEdges
              .where(
                (edge) =>
                    edge.declarationId.endsWith('#DirectPublic') ||
                    edge.declarationId.endsWith('#PartPublic'),
              )
              .every((edge) => edge.exact),
          isTrue,
        );
      },
    );

    test(
      'resolves re-exports, cycles, show and hide without host namespace edges',
      () async {
        final resolution = await resolve([webConsumer]);
        final apiIds = resolution.edges
            .where(
              (edge) =>
                  edge.publicEntrypointLibraryId.endsWith('/lib/api.dart'),
            )
            .map((edge) => edge.declarationId)
            .toSet();
        final reexportIds = resolution.edges
            .where(
              (edge) => edge.publicEntrypointLibraryId.endsWith(
                '/lib/reexport_api.dart',
              ),
            )
            .map((edge) => edge.declarationId)
            .toSet();

        expect(
          apiIds,
          containsAll({
            'dart:public_surface_test/lib/src/cycle_a.dart#CycleA',
            'dart:public_surface_test/lib/src/cycle_b.dart#CycleB',
            'dart:public_surface_test/lib/src/combinators.dart#Visible',
            'dart:public_surface_test/lib/src/combinators.dart#AlsoVisible',
          }),
        );
        expect(apiIds, isNot(contains(contains('#Hidden'))));
        expect(
          reexportIds,
          contains(
            'dart:public_surface_test/lib/src/reexport_part.dart#ReexportedPartPublic',
          ),
        );
        expect(
          reexportIds,
          isNot(contains(contains('#_ReexportedPartPrivate'))),
        );
      },
    );

    test(
      'keeps asymmetric export-cycle surfaces complete per entrypoint',
      () async {
        final resolution = await resolve([webConsumer]);
        Set<String> idsFor(String entrypoint) => resolution.edges
            .where(
              (edge) => edge.publicEntrypointLibraryId.endsWith(entrypoint),
            )
            .map((edge) => edge.declarationId)
            .toSet();

        final fromA = idsFor('/lib/cycle_entry_a.dart');
        final fromB = idsFor('/lib/cycle_entry_b.dart');

        expect(
          fromA,
          containsAll({
            'dart:public_surface_test/lib/cycle_entry_a.dart#FromA',
            'dart:public_surface_test/lib/cycle_entry_a.dart#VisibleThroughCycle',
            'dart:public_surface_test/lib/cycle_entry_b.dart#FromB',
          }),
        );
        expect(
          fromB,
          containsAll({
            'dart:public_surface_test/lib/cycle_entry_a.dart#VisibleThroughCycle',
            'dart:public_surface_test/lib/cycle_entry_b.dart#FromB',
          }),
        );
        expect(fromB, isNot(contains(contains('#FromA'))));
        expect(
          resolution.issues.where(
            (issue) => issue.sourcePath.contains('cycle_entry_'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'resolves a linear diamond chain within a bounded operation budget',
      () async {
        final diamondRoot = await Directory.systemTemp.createTemp(
          'g6-public-surface-diamonds-',
        );
        addTearDown(() => diamondRoot.delete(recursive: true));
        _write(diamondRoot, 'pubspec.yaml', '''
name: diamond_surface_test
environment:
  sdk: ^3.9.0
''');
        _write(diamondRoot, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"diamond_surface_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        const layerCount = 16;
        for (var layer = 0; layer < layerCount; layer++) {
          final suffix = layer.toString().padLeft(2, '0');
          final nextSuffix = (layer + 1).toString().padLeft(2, '0');
          _write(diamondRoot, 'lib/diamond_$suffix.dart', '''
export 'left_$suffix.dart';
export 'right_$suffix.dart';
''');
          _write(
            diamondRoot,
            'lib/left_$suffix.dart',
            "export 'diamond_$nextSuffix.dart';\n",
          );
          _write(
            diamondRoot,
            'lib/right_$suffix.dart',
            "export 'diamond_$nextSuffix.dart';\n",
          );
        }
        _write(diamondRoot, 'lib/diamond_16.dart', 'class DiamondLeaf {}\n');
        final diamondProject = ProjectContext(
          root: diamondRoot,
          pubspec: const {'name': 'diamond_surface_test'},
          packageName: 'diamond_surface_test',
          analysisMode: AnalysisMode.package,
          targets: [
            BuildTarget(
              name: 'package',
              platform: 'web',
              entrypoint: 'lib/diamond_00.dart',
            ),
          ],
          rootCoverage: RootCoverage(
            mode: RootCoverageMode.packagePublicApi,
            internalBoundaryComplete: true,
            externalConsumersCovered: false,
            source: 'test',
            publicEntrypoints: const ['lib/diamond_00.dart'],
          ),
        );
        final diamondWorkspace = DartAnalysisWorkspace(diamondProject);
        final diamondOwnership = DartPackageOwnership.discover(diamondProject);
        final diamondLibraries = await _resolvedLibraries(diamondWorkspace);
        final diamondContexts = DartExecutionContextSnapshot(
          configuredTargets: diamondProject.targets,
          auxiliaryExecutionTargets: [webConsumer],
          roots: const [],
          issues: const [],
        );
        final diamondDirectives = await DartDirectiveResolver(
          project: diamondProject,
          workspace: diamondWorkspace,
          ownership: diamondOwnership,
          contexts: diamondContexts,
          libraries: diamondLibraries,
        ).resolve();
        final stopwatch = Stopwatch()..start();
        final resolution = DartPublicSurfaceResolver(
          project: diamondProject,
          ownership: diamondOwnership,
          contexts: diamondContexts,
          libraries: diamondLibraries,
          directives: diamondDirectives,
        ).resolve();
        stopwatch.stop();

        expect(
          resolution.edges.map((edge) => edge.declarationId),
          contains('dart:diamond_surface_test/lib/diamond_16.dart#DiamondLeaf'),
        );
        expect(
          stopwatch.elapsed,
          lessThan(const Duration(seconds: 5)),
          reason:
              'a linear-size diamond graph must not enumerate its 2^16 export paths',
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'proves known conditional surface and only retains incomplete union',
      () async {
        final resolution = await resolve([webConsumer, unknownConsumer]);
        final conditional = resolution.edges.where(
          (edge) =>
              edge.declarationId.endsWith('#DefaultOnly') ||
              edge.declarationId.endsWith('#WebOnly'),
        );
        final webEdges = conditional
            .where((edge) => edge.externalExecutionTargetId == webConsumer.id)
            .toList();
        final unknownEdges = conditional
            .where(
              (edge) => edge.externalExecutionTargetId == unknownConsumer.id,
            )
            .toList();

        expect(webEdges, hasLength(1));
        expect(webEdges.single.declarationId, endsWith('#WebOnly'));
        expect(webEdges.single.exact, isTrue);
        expect(
          unknownEdges.map((edge) => edge.declarationId),
          containsAll([endsWith('#DefaultOnly'), endsWith('#WebOnly')]),
        );
        expect(unknownEdges.every((edge) => !edge.exact), isTrue);
        expect(
          resolution.issues,
          contains(
            predicate<DartDirectiveIssue>(
              (issue) =>
                  issue.affectedAuxiliaryTargetIds.contains(
                    unknownConsumer.id,
                  ) &&
                  issue.reason.contains('namespace'),
            ),
          ),
        );
        expect(
          resolution.issues,
          contains(
            predicate<DartDirectiveIssue>(
              (issue) => issue.reason.contains('could not be resolved'),
            ),
          ),
        );
      },
    );
  });
}

Future<List<ResolvedLibraryResult>> _resolvedLibraries(
  DartAnalysisWorkspace workspace,
) async {
  final byPath = <String, ResolvedLibraryResult>{};
  for (final path in workspace.dartFiles) {
    final result = await workspace.resolveLibrary(path);
    if (result is ResolvedLibraryResult) {
      byPath[result.element.firstFragment.source.fullName] = result;
    }
  }
  return byPath.values.toList();
}

void _write(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
