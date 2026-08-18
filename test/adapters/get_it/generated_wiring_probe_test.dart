import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_ids.dart';
import 'package:flutter_pruner/src/adapters/get_it/generated_wiring_probe.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> _fixtureProject() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_generated_wiring_test')),
);

void main() {
  group('GeneratedWiringProbe', () {
    test(
      'detects standard config output missed by the general generated heuristic',
      () async {
        final project = await _fixtureProject();
        final evidence = GeneratedWiringProbe.detect(project);

        final output = evidence.outputs.singleWhere(
          (output) => output.path == 'lib/injection.config.dart',
        );
        expect(DartIds.isGeneratedPath(project.resolve(output.path)), isFalse);
        expect(
          output.dartNamespace,
          'dart:get_it_generated_wiring_test/lib/injection.config.dart',
        );
        expect(evidence.hasGeneratedWiring, isTrue);
      },
    );

    test(
      'keeps dependency, import, and annotation evidence without inventing output paths',
      () async {
        final project = await _fixtureProject();
        final evidence = GeneratedWiringProbe.detect(
          project,
          files: (_) => <File>[
            File(project.resolve('lib/injection.dart')),
            File(project.resolve('lib/public.dart')),
          ],
        );

        expect(evidence.outputs, isEmpty);
        expect(
          evidence.uncertainties.map((uncertainty) => uncertainty.source),
          containsAll(<String?>['pubspec.yaml', 'lib/injection.dart']),
        );
        expect(evidence.dartNamespaces, isEmpty);
        expect(evidence.hasGeneratedWiring, isTrue);
      },
    );

    test(
      'treats injectable_generator in dev_dependencies as wiring uncertainty',
      () async {
        final project = await _fixtureProject();
        final evidence = GeneratedWiringProbe.detect(
          project,
          files: (_) => const <File>[],
        );

        expect(
          evidence.uncertainties.map((uncertainty) => uncertainty.reason),
          contains(
            'direct injectable_generator dev dependency may generate GetIt wiring',
          ),
        );
      },
    );

    test(
      'is negative for an ordinary project without DI generation signals',
      () async {
        final root = await Directory.systemTemp.createTemp('wiring_probe_');
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: ordinary_project
environment:
  sdk: ^3.9.0
''');
        await Directory(p.join(root.path, 'lib')).create();
        await File(
          p.join(root.path, 'lib', 'main.dart'),
        ).writeAsString('void main() {}');

        final evidence = GeneratedWiringProbe.detect(
          await ProjectContext.load(root),
        );

        expect(evidence.hasGeneratedWiring, isFalse);
        expect(evidence.sources, isEmpty);
        expect(evidence.dartNamespaces, isEmpty);
      },
    );

    test(
      'retains unreadable and listing uncertainty without throwing',
      () async {
        final project = await _fixtureProject();
        final candidate = File(project.resolve('lib/injection.config.dart'));
        final unreadable = GeneratedWiringProbe.detect(
          project,
          files: (_) => [candidate],
          readFile: (_) => throw FileSystemException('denied'),
        );
        final listingFailure = GeneratedWiringProbe.detect(
          project,
          files: (_) => throw FileSystemException('listing denied'),
        );

        expect(unreadable.outputs.single.path, 'lib/injection.config.dart');
        expect(unreadable.outputs.single.reason, contains('unreadable'));
        expect(listingFailure.hasGeneratedWiring, isTrue);
        final listing = listingFailure.uncertainties.singleWhere(
          (uncertainty) => uncertainty.source == null,
        );
        expect(listing.reason, contains('list'));

        final lazyListingFailure = GeneratedWiringProbe.detect(
          project,
          files: (_) sync* {
            yield candidate;
            throw FileSystemException('late listing failure');
          },
        );
        expect(
          lazyListingFailure.uncertainties.any(
            (uncertainty) => uncertainty.source == null,
          ),
          isTrue,
        );
      },
    );

    test(
      'does not treat comments, strings, or unrelated annotations as Injectable evidence',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'wiring_probe_false_',
        );
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: false_signals
environment:
  sdk: ^3.9.0
''');
        await Directory(p.join(root.path, 'lib')).create();
        await File(p.join(root.path, 'lib', 'main.dart')).writeAsString(r'''
// import 'package:injectable/injectable.dart';
const text = "@injectable import 'package:injectable/injectable.dart'";

class singleton {
  const singleton();
}

@singleton()
class Unrelated {}
''');

        final evidence = GeneratedWiringProbe.detect(
          await ProjectContext.load(root),
        );

        expect(evidence.hasGeneratedWiring, isFalse);
        expect(evidence.sources, isEmpty);
      },
    );

    test(
      'keeps report-facing output fields stable, unique, relative, and sorted',
      () async {
        final project = await _fixtureProject();
        final first = File(project.resolve('lib/injection.config.dart'));
        final second = File(project.resolve('lib/z.config.dart'));
        final evidence = GeneratedWiringProbe.detect(
          project,
          files: (_) => [second, first, first],
        );

        expect(
          evidence.outputs.map((output) => output.path),
          orderedEquals(<String>[
            'lib/injection.config.dart',
            'lib/z.config.dart',
          ]),
        );
        expect(
          evidence.sources,
          orderedEquals(evidence.sources.toSet().toList()..sort()),
        );
        expect(
          evidence.sources,
          everyElement(isNot(contains(project.root.path))),
        );
        expect(
          evidence.dartNamespaces,
          everyElement(startsWith('dart:get_it_generated_wiring_test/')),
        );
      },
    );
  });
}
