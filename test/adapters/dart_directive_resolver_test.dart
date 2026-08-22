import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_directive_resolver.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DartDirectiveResolver', () {
    late Directory root;
    late ProjectContext project;
    late DartAnalysisWorkspace workspace;
    late List<ResolvedLibraryResult> libraries;

    final web = BuildTarget(
      name: 'web',
      platform: 'web',
      entrypoint: 'lib/main.dart',
    );
    final androidDebug = BuildTarget(
      name: 'android-debug',
      platform: 'android',
      flavor: 'debug',
      entrypoint: 'lib/main.dart',
      dartDefines: const {'MODE': 'debug', 'dart.library.html': 'true'},
    );
    final androidRelease = BuildTarget(
      name: 'android-release',
      platform: 'android',
      flavor: 'release',
      entrypoint: 'lib/main.dart',
      dartDefines: const {'MODE': 'release'},
    );
    final unknownExternal = AuxiliaryExecutionTarget(
      id: 'aux:external:unknown-consumer',
      domain: AuxiliaryExecutionDomain.external,
      environmentValues: const {},
      environmentComplete: false,
      reason: 'unknown external consumer environment',
    );

    setUp(() async {
      root = await Directory.systemTemp.createTemp('g6-directives-');
      _write(root, 'pubspec.yaml', '''
name: directive_test
environment:
  sdk: ^3.9.0
''');
      _write(root, '.dart_tool/package_config.json', '''
{"configVersion":2,"packages":[
  {"name":"directive_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      _write(root, 'lib/main.dart', '''
import 'src/default.dart'
    if (dart.library.io == 'true') 'src/io.dart'
    if (dart.library.html == 'true') 'src/web.dart';
export 'src/false_default.dart'
    if (dart.library.html == 'false') 'package:directive_test/src/not_web.dart';

void main() {}
''');
      for (final name in ['default', 'io', 'web', 'false_default', 'not_web']) {
        _write(root, 'lib/src/$name.dart', 'void ${name}Value() {}\n');
      }
      project = ProjectContext(
        root: root,
        pubspec: const {'name': 'directive_test'},
        packageName: 'directive_test',
        targets: [web, androidDebug, androidRelease],
        rootCoverage: RootCoverage.applicationApi(),
      );
      workspace = DartAnalysisWorkspace(project);
      libraries = await _resolvedLibraries(workspace);
    });

    tearDown(() => root.deleteSync(recursive: true));

    test(
      'selects first true branch per full target with exact SDK-owned values',
      () async {
        final resolution = await DartDirectiveResolver(
          project: project,
          workspace: workspace,
          ownership: DartPackageOwnership.discover(project),
          contexts: DartExecutionContextSnapshot(
            configuredTargets: [web, androidDebug, androidRelease],
            auxiliaryExecutionTargets: const [],
            roots: const [],
            issues: const [],
          ),
          libraries: libraries,
        ).resolve();

        String selectedFor(BuildTarget target, DartDirectiveKind kind) {
          final edge = resolution.edges.singleWhere(
            (edge) =>
                edge.kind == kind &&
                edge.condition.exactTargets.single == target,
          );
          expect(edge.exact, isTrue);
          return p.basename(edge.targetPath);
        }

        expect(selectedFor(web, DartDirectiveKind.import), 'web.dart');
        expect(selectedFor(androidDebug, DartDirectiveKind.import), 'io.dart');
        expect(
          selectedFor(androidRelease, DartDirectiveKind.import),
          'io.dart',
        );
        expect(
          selectedFor(web, DartDirectiveKind.export),
          'false_default.dart',
        );
        expect(
          selectedFor(androidDebug, DartDirectiveKind.export),
          'not_web.dart',
        );
        expect(
          selectedFor(androidRelease, DartDirectiveKind.export),
          'not_web.dart',
        );
        expect(resolution.issues, isEmpty);
      },
    );

    test(
      'retains bounded unknown auxiliary alternatives inexactly with an issue',
      () async {
        final resolution = await DartDirectiveResolver(
          project: project,
          workspace: workspace,
          ownership: DartPackageOwnership.discover(project),
          contexts: DartExecutionContextSnapshot(
            configuredTargets: [web],
            auxiliaryExecutionTargets: [unknownExternal],
            roots: const [],
            issues: const [],
          ),
          libraries: libraries,
        ).resolve();

        final auxiliaryImports = resolution.edges
            .where(
              (edge) =>
                  edge.kind == DartDirectiveKind.import &&
                  edge.condition.exactAuxiliaryTargets.contains(
                    unknownExternal,
                  ),
            )
            .toList();
        expect(auxiliaryImports, hasLength(3));
        expect(
          auxiliaryImports.map((edge) => p.basename(edge.targetPath)).toSet(),
          {'default.dart', 'io.dart', 'web.dart'},
        );
        expect(auxiliaryImports.every((edge) => !edge.exact), isTrue);
        expect(
          resolution.issues,
          contains(
            predicate<DartDirectiveIssue>(
              (issue) =>
                  issue.affectedConfiguredTargets.isEmpty &&
                  issue.affectedAuxiliaryTargetIds.length == 1 &&
                  issue.affectedAuxiliaryTargetIds.contains(unknownExternal.id),
            ),
          ),
        );
      },
    );

    test('does not collapse same URI selected by distinct targets', () async {
      final resolution = await DartDirectiveResolver(
        project: project,
        workspace: workspace,
        ownership: DartPackageOwnership.discover(project),
        contexts: DartExecutionContextSnapshot(
          configuredTargets: [androidDebug, androidRelease],
          auxiliaryExecutionTargets: const [],
          roots: const [],
          issues: const [],
        ),
        libraries: libraries,
      ).resolve();

      final ioEdges = resolution.edges
          .where((edge) => p.basename(edge.targetPath) == 'io.dart')
          .toList();
      expect(ioEdges, hasLength(2));
      expect(
        ioEdges
            .expand((edge) => edge.condition.exactTargets)
            .map((target) => '${target.flavor}|${target.dartDefines['MODE']}')
            .toSet(),
        {'debug|debug', 'release|release'},
      );
    });

    test('ignores SDK library directives without issues', () async {
      _write(root, 'lib/sdk_directives.dart', '''
import 'dart:async';
export 'dart:collection';
''');
      final sdkWorkspace = DartAnalysisWorkspace(project);
      final resolution = await DartDirectiveResolver(
        project: project,
        workspace: sdkWorkspace,
        ownership: DartPackageOwnership.discover(project),
        contexts: DartExecutionContextSnapshot(
          configuredTargets: [web],
          auxiliaryExecutionTargets: const [],
          roots: const [],
          issues: const [],
        ),
        libraries: await _resolvedLibraries(sdkWorkspace),
      ).resolve();

      expect(resolution.issues, isEmpty);
      expect(
        resolution.edges.any(
          (edge) => p.basename(edge.sourcePath) == 'sdk_directives.dart',
        ),
        isFalse,
      );
    });
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
