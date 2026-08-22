import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_application_reachability.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_context_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_ids.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DartPackageOwnership package_config URI resolution', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('dart-ownership-uri-');
      _writePubspec(root, 'selected_app');
      _writeSource(root, 'lib/main.dart', 'void main() {}\n');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test('normalizes a relative rootUri without a trailing slash', () async {
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final project = await _loadProject(root);

      final owner = DartPackageOwnership.discover(
        project,
      ).ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(
        owner.ownership,
        DartSourceOwnership.selectedPackage,
        reason: owner.reason,
      );
      expect(owner.packageName, 'selected_app');
      expect(owner.packageRoot, p.normalize(root.resolveSymbolicLinksSync()));
    });

    test('normalizes a file rootUri without a trailing slash', () async {
      final rootUri = root.absolute.uri.toString().replaceFirst(
        RegExp(r'/$'),
        '',
      );
      _writePackageConfig(root, [_package('selected_app', rootUri)]);
      final project = await _loadProject(root);

      final owner = DartPackageOwnership.discover(
        project,
      ).ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(
        owner.ownership,
        DartSourceOwnership.selectedPackage,
        reason: owner.reason,
      );
      expect(owner.packageName, 'selected_app');
      expect(owner.packageRoot, p.normalize(root.resolveSymbolicLinksSync()));
    });

    test('uses the longest matching normalized package root', () async {
      final nested = Directory(p.join(root.path, 'packages', 'nested'));
      _writePubspec(nested, 'nested_pkg');
      _writeSource(nested, 'lib/nested.dart', 'void nested() {}\n');
      _writePackageConfig(root, [
        _package('selected_app', '..'),
        _package('nested_pkg', '../packages/nested'),
      ]);
      final project = await _loadProject(root);

      final ownership = DartPackageOwnership.discover(project);
      final selected = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));
      final external = ownership.ownerOf(
        p.join(nested.path, 'lib', 'nested.dart'),
      );

      expect(
        selected.ownership,
        DartSourceOwnership.selectedPackage,
        reason: selected.reason,
      );
      expect(external.ownership, DartSourceOwnership.externalPackage);
      expect(external.packageName, 'nested_pkg');
      expect(
        external.packageRoot,
        p.normalize(nested.resolveSymbolicLinksSync()),
      );
    });
  });

  group('DartPackageOwnership provenance', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp(
        'dart-ownership-provenance-',
      );
      _writePubspec(root, 'selected_app');
      _writeSource(root, 'lib/main.dart', 'void main() {}\n');
    });

    tearDown(() async {
      if (root.existsSync()) await root.delete(recursive: true);
    });

    test(
      'accepts matching nested package config and pubspec as external',
      () async {
        final nested = Directory(p.join(root.path, 'nested'));
        _writePubspec(nested, 'nested_pkg');
        _writeSource(nested, 'lib/api.dart', 'void api() {}\n');
        _writePackageConfig(root, [
          _package('selected_app', '..'),
          _package('nested_pkg', '../nested'),
        ]);
        final ownership = DartPackageOwnership.discover(
          await _loadProject(root),
        );

        final owner = ownership.ownerOf(p.join(nested.path, 'lib', 'api.dart'));

        expect(owner.ownership, DartSourceOwnership.externalPackage);
        expect(owner.packageName, 'nested_pkg');
      },
    );

    test('accepts an unclaimed nested pubspec as external', () async {
      final nested = Directory(p.join(root.path, 'nested'));
      _writePubspec(nested, 'nested_pkg');
      _writeSource(nested, 'lib/api.dart', 'void api() {}\n');
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(nested.path, 'lib', 'api.dart'));

      expect(owner.ownership, DartSourceOwnership.externalPackage);
      expect(owner.packageName, 'nested_pkg');
      expect(owner.reason, contains('unclaimed external package'));
    });

    test('rejects conflicting nested package config and pubspec', () async {
      final nested = Directory(p.join(root.path, 'nested'));
      _writePubspec(nested, 'nested_pkg');
      _writeSource(nested, 'lib/api.dart', 'void api() {}\n');
      _writePackageConfig(root, [
        _package('selected_app', '..'),
        _package('different_claim', '../nested'),
      ]);
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(nested.path, 'lib', 'api.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('conflicts'));
    });

    test('rejects malformed package configuration', () async {
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{not json');
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('malformed or unreadable'));
    });

    test('rejects missing package configuration', () async {
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, 'package configuration is missing');
    });

    test('rejects duplicate package roots', () async {
      _writePackageConfig(root, [
        _package('selected_app', '..'),
        _package('impostor', '..'),
      ]);
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('same package root'));
    });

    test('rejects a selected package with no physical pubspec', () {
      File(p.join(root.path, 'pubspec.yaml')).deleteSync();
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final ownership = DartPackageOwnership.discover(
        _manualProject(root, 'selected_app'),
      );

      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('no readable owning pubspec'));
    });

    test('rejects unreadable pubspec bytes', () {
      File(p.join(root.path, 'pubspec.yaml')).writeAsBytesSync([0xff]);
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final ownership = DartPackageOwnership.discover(
        _manualProject(root, 'selected_app'),
      );

      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('no readable owning pubspec'));
    });

    test('snapshots physical provenance for the project pass', () async {
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final project = await _loadProject(root);
      final ownership = DartPackageOwnership.discover(project);

      _writePubspec(root, 'changed_after_discovery');
      final owner = ownership.ownerOf(p.join(root.path, 'lib', 'main.dart'));

      expect(
        owner.ownership,
        DartSourceOwnership.selectedPackage,
        reason: owner.reason,
      );
      expect(owner.packageName, 'selected_app');
    });

    test('rejects a lexical path outside every configured owner', () async {
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final outside = await Directory.systemTemp.createTemp(
        'dart-ownership-outside-',
      );
      addTearDown(() => outside.delete(recursive: true));
      _writePubspec(outside, 'outside_pkg');
      _writeSource(outside, 'lib/outside.dart', 'void outside() {}\n');
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(
        p.join(
          root.path,
          '..',
          p.basename(outside.path),
          'lib',
          'outside.dart',
        ),
      );

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('outside every admitted package root'));
    });

    test('rejects a symlink escape from the selected root', () async {
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final outside = await Directory.systemTemp.createTemp(
        'dart-ownership-symlink-target-',
      );
      addTearDown(() => outside.delete(recursive: true));
      _writePubspec(outside, 'outside_pkg');
      _writeSource(outside, 'lib/outside.dart', 'void outside() {}\n');
      final link = Link(p.join(root.path, 'lib', 'escape.dart'));
      link.createSync(p.join(outside.path, 'lib', 'outside.dart'));
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(link.path);

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('symlink'));
    });

    test('rejects an outside symlink alias into the selected root', () async {
      _writePackageConfig(root, [_package('selected_app', '..')]);
      final outside = await Directory.systemTemp.createTemp(
        'dart-ownership-symlink-alias-',
      );
      addTearDown(() => outside.delete(recursive: true));
      final alias = Link(p.join(outside.path, 'selected_alias'));
      alias.createSync(root.path);
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(p.join(alias.path, 'lib', 'main.dart'));

      expect(owner.ownership, DartSourceOwnership.unknown);
      expect(owner.reason, contains('symlink'));
    });

    test('accepts a configured out-of-tree path package as external', () async {
      final outside = await Directory.systemTemp.createTemp(
        'dart-ownership-path-package-',
      );
      addTearDown(() => outside.delete(recursive: true));
      _writePubspec(outside, 'outside_pkg');
      _writeSource(outside, 'lib/outside.dart', 'void outside() {}\n');
      _writePackageConfig(root, [
        _package('selected_app', '..'),
        _package('outside_pkg', outside.absolute.uri.toString()),
      ]);
      final ownership = DartPackageOwnership.discover(await _loadProject(root));

      final owner = ownership.ownerOf(
        p.join(outside.path, 'lib', 'outside.dart'),
      );

      expect(owner.ownership, DartSourceOwnership.externalPackage);
      expect(owner.packageName, 'outside_pkg');
    });

    test(
      'keeps selected IDs stable and distinguishes generated sources',
      () async {
        _writeSource(root, 'lib/model.g.dart', 'void generated() {}\n');
        _writePackageConfig(root, [_package('selected_app', '..')]);
        final project = await _loadProject(root);
        final ownership = DartPackageOwnership.discover(project);
        final mainPath = p.join(root.path, 'lib', 'main.dart');
        final generatedPath = p.join(root.path, 'lib', 'model.g.dart');

        expect(ownership.isSelectedSource(mainPath), isTrue);
        expect(ownership.isSelectedGeneratedSource(mainPath), isFalse);
        expect(ownership.isSelectedSource(generatedPath), isFalse);
        expect(ownership.isSelectedGeneratedSource(generatedPath), isTrue);
        expect(
          DartIds.libraryPath(project, mainPath),
          'dart:selected_app/lib/main.dart',
        );
        final result = await DartAnalysisWorkspace(
          project,
        ).resolveLibrary(mainPath);
        expect(result, isA<ResolvedLibraryResult>());
        final library = (result as ResolvedLibraryResult).element;
        final entryPoint = library.entryPoint;
        expect(entryPoint, isNotNull);
        expect(
          DartIds.library(project, library),
          'dart:selected_app/lib/main.dart',
        );
        expect(
          DartIds.declaration(project, entryPoint!.firstFragment),
          'dart:selected_app/lib/main.dart#main',
        );
      },
    );

    test(
      'directory names alone do not establish generated provenance',
      () async {
        const handwrittenPaths = [
          'lib/gen/handwritten.dart',
          'lib/generated/handwritten.dart',
          'lib/genesis/handwritten.dart',
          'lib/regeneration/handwritten.dart',
        ];
        const generatedPaths = [
          'lib/gen/model.g.dart',
          'lib/generated/model.freezed.dart',
          'lib/generated/model.gen.dart',
          'lib/generated/model.mocks.dart',
          'lib/generated/model.gr.dart',
          'build/handwritten.dart',
          '.dart_tool/handwritten.dart',
        ];
        for (final path in [...handwrittenPaths, ...generatedPaths]) {
          _writeSource(root, path, 'void declaration() {}\n');
        }
        _writePackageConfig(root, [_package('selected_app', '..')]);
        final ownership = DartPackageOwnership.discover(
          await _loadProject(root),
        );

        for (final path in handwrittenPaths) {
          final absolutePath = p.join(root.path, path);
          expect(
            ownership.isSelectedSource(absolutePath),
            isTrue,
            reason: '$path is ordinary selected source',
          );
          expect(
            ownership.isSelectedGeneratedSource(absolutePath),
            isFalse,
            reason: '$path has no generated provenance',
          );
        }
        for (final path in generatedPaths) {
          final absolutePath = p.join(root.path, path);
          expect(
            ownership.isSelectedSource(absolutePath),
            isFalse,
            reason: '$path remains outside the editable graph',
          );
          expect(
            ownership.isSelectedGeneratedSource(absolutePath),
            isTrue,
            reason: '$path retains generated provenance',
          );
        }
        expect(DartIds.isGeneratedPath(r'lib\gen\handwritten.dart'), isFalse);
        expect(DartIds.isGeneratedPath('lib/generatedness/file.dart'), isFalse);
      },
    );

    test(
      'interleaved projects keep identity-bound ownership snapshots',
      () async {
        _writePackageConfig(root, [_package('selected_app', '..')]);
        final other = await Directory.systemTemp.createTemp(
          'dart-ownership-interleaved-',
        );
        addTearDown(() => other.delete(recursive: true));
        _writePubspec(other, 'other_app');
        _writeSource(other, 'lib/main.dart', 'void main() {}\n');
        _writePackageConfig(other, [_package('other_app', '..')]);
        final firstProject = await _loadProject(root);
        final secondProject = await _loadProject(other);
        final firstPath = p.join(root.path, 'lib', 'main.dart');
        final secondPath = p.join(other.path, 'lib', 'main.dart');

        final results = await Future.wait([
          for (var index = 0; index < 20; index++)
            Future<bool>(() {
              final first = DartPackageOwnership.discover(firstProject);
              final second = DartPackageOwnership.discover(secondProject);
              return identical(
                    first,
                    DartPackageOwnership.discover(firstProject),
                  ) &&
                  identical(
                    second,
                    DartPackageOwnership.discover(secondProject),
                  ) &&
                  !identical(first, second) &&
                  DartIds.isModeledProjectPath(firstProject, firstPath) &&
                  !DartIds.isModeledProjectPath(firstProject, secondPath) &&
                  DartIds.isModeledProjectPath(secondProject, secondPath) &&
                  !DartIds.isModeledProjectPath(secondProject, firstPath);
            }),
        ]);

        expect(results, everyElement(isTrue));
        expect(
          () => DartIds.libraryPath(firstProject, secondPath),
          throwsStateError,
        );
        expect(
          DartIds.libraryPath(secondProject, secondPath),
          'dart:other_app/lib/main.dart',
        );
      },
    );
  });

  group('DartApplicationReachability ownership boundary', () {
    test('does not traverse a known nested package as selected code', () async {
      final root = Directory(
        p.absolute('test/fixtures/dart_graph_correctness_test'),
      );
      final project = await ProjectContext.load(root);

      final reachability = await _applicationReachability(project);

      expect(
        reachability.unitPaths.map(project.relative),
        isNot(contains('nested/lib/nested_api.dart')),
      );
      expect(
        reachability.issues,
        isNot(contains(contains('ownership boundary'))),
      );
    });

    test('unknown imported ownership makes the closure incomplete', () async {
      final root = await Directory.systemTemp.createTemp(
        'dart-reachability-ownership-',
      );
      addTearDown(() => root.delete(recursive: true));
      _writePubspec(root, 'selected_app');
      _writeSource(root, 'lib/main.dart', '''
import '../nested/lib/api.dart';

void main() => api();
''');
      final nested = Directory(p.join(root.path, 'nested'));
      _writePubspec(nested, 'physical_nested');
      _writeSource(nested, 'lib/api.dart', 'void api() {}\n');
      _writePackageConfig(root, [
        _package('selected_app', '..'),
        _package('conflicting_claim', '../nested'),
      ]);
      final project = await _loadProject(root);

      final reachability = await _applicationReachability(project);

      expect(
        reachability.unitPaths.map(project.relative),
        isNot(contains('nested/lib/api.dart')),
      );
      expect(reachability.isComplete, isFalse);
      expect(
        reachability.issues,
        contains(contains('ownership boundary is unknown')),
      );
    });

    test(
      'external part makes selected application reachability incomplete',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'dart-reachability-external-part-',
        );
        addTearDown(() => root.delete(recursive: true));
        _writePubspec(root, 'selected_app');
        _writeSource(root, 'lib/main.dart', '''
part 'package:part_pkg/external_part.dart';

void main() {}
''');
        final nested = Directory(p.join(root.path, 'nested'));
        _writePubspec(nested, 'part_pkg');
        _writeSource(nested, 'lib/external_part.dart', '''
part of 'package:selected_app/main.dart';

void externalPartEntry() {}
''');
        _writePackageConfig(root, [
          _package('selected_app', '..'),
          _package('part_pkg', '../nested'),
        ]);
        final project = await _loadProject(root);

        final reachability = await _applicationReachability(project);

        expect(reachability.unitPaths.map(p.basename), contains('main.dart'));
        expect(
          reachability.unitPaths.map(p.basename),
          isNot(contains('external_part.dart')),
        );
        expect(reachability.isComplete, isFalse);
        expect(
          reachability.issues,
          contains(
            contains('selected Dart library includes a non-selected part'),
          ),
        );
      },
    );

    test(
      'unknown part makes selected application reachability incomplete',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'dart-reachability-unknown-part-',
        );
        addTearDown(() => root.delete(recursive: true));
        _writePubspec(root, 'selected_app');
        _writeSource(root, 'lib/main.dart', '''
part 'package:conflicting_part/unknown_part.dart';

void main() {}
''');
        final nested = Directory(p.join(root.path, 'nested'));
        _writePubspec(nested, 'actual_part');
        _writeSource(nested, 'lib/unknown_part.dart', '''
part of 'package:selected_app/main.dart';

void unknownPartEntry() {}
''');
        _writePackageConfig(root, [
          _package('selected_app', '..'),
          _package('conflicting_part', '../nested'),
        ]);
        final project = await _loadProject(root);

        final reachability = await _applicationReachability(project);

        expect(reachability.unitPaths.map(p.basename), contains('main.dart'));
        expect(
          reachability.unitPaths.map(p.basename),
          isNot(contains('unknown_part.dart')),
        );
        expect(reachability.isComplete, isFalse);
        expect(
          reachability.issues,
          contains(contains('part with unknown ownership')),
        );
      },
    );
  });
}

Future<ProjectContext> _loadProject(Directory root) => ProjectContext.load(
  root,
  targets: [
    BuildTarget(name: 'test', platform: 'vm', entrypoint: 'lib/main.dart'),
  ],
);

Future<DartApplicationReachability> _applicationReachability(
  ProjectContext project,
) async {
  final workspace = DartAnalysisWorkspace(project);
  final contexts = await DefaultDartExecutionContextService(
    workspace: workspace,
  ).resolve(project);
  final snapshot = await DefaultDartExecutionReachabilityService(
    workspace: workspace,
    contexts: contexts,
  ).resolve(project);
  return DartApplicationReachability.fromSnapshot(snapshot);
}

ProjectContext _manualProject(Directory root, String packageName) =>
    ProjectContext(
      root: root,
      pubspec: {'name': packageName},
      packageName: packageName,
      targets: [
        BuildTarget(name: 'test', platform: 'vm', entrypoint: 'lib/main.dart'),
      ],
    );

Map<String, Object?> _package(String name, String rootUri) => {
  'name': name,
  'rootUri': rootUri,
  'packageUri': 'lib/',
  'languageVersion': '3.9',
};

void _writePackageConfig(
  Directory selectedRoot,
  List<Map<String, Object?>> packages,
) {
  final file = File(
    p.join(selectedRoot.path, '.dart_tool', 'package_config.json'),
  )..createSync(recursive: true);
  file.writeAsStringSync(
    jsonEncode({'configVersion': 2, 'packages': packages}),
  );
}

void _writePubspec(Directory root, String packageName) {
  File(p.join(root.path, 'pubspec.yaml'))
    ..createSync(recursive: true)
    ..writeAsStringSync('''
name: $packageName
publish_to: none
environment:
  sdk: ^3.9.0
''');
}

void _writeSource(Directory root, String relativePath, String contents) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}
