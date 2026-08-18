import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_config.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('L10nConfig', () {
    test('loads explicit real-source output paths', () async {
      final root = await _createProject(
        flutter: true,
        l10nYaml: '''
arb-dir: lib/translations
template-arb-file: strings_en.arb
output-dir: lib/generated/l10n
output-localization-file: strings.dart
output-class: Strings
nullable-getter: false
''',
      );
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigValid>());
      final config = (result as L10nConfigValid).config;
      expect(config.arbDir, _projectPath(root, ['lib', 'translations']));
      expect(config.templateArbPath, p.join(config.arbDir, 'strings_en.arb'));
      expect(
        config.outputDir,
        _projectPath(root, ['lib', 'generated', 'l10n']),
      );
      expect(
        config.generatedLibraryPath,
        p.join(config.outputDir, 'strings.dart'),
      );
      expect(config.outputClass, 'Strings');
      expect(config.nullableGetter, isFalse);
    });

    test(
      'uses current Flutter defaults when generate is true without YAML',
      () async {
        final root = await _createProject(flutter: true);
        addTearDown(() => root.delete(recursive: true));

        final result = L10nConfig.load(await ProjectContext.load(root));

        expect(result, isA<L10nConfigValid>());
        final config = (result as L10nConfigValid).config;
        expect(config.arbDir, _projectPath(root, ['lib', 'l10n']));
        expect(config.templateArbFile, 'app_en.arb');
        expect(config.outputLocalizationFile, 'app_localizations.dart');
        expect(config.outputClass, 'AppLocalizations');
        expect(config.nullableGetter, isTrue);
        expect(config.outputDir, config.arbDir);
        expect(
          config.generatedLibraryPath,
          p.join(config.arbDir, 'app_localizations.dart'),
        );
      },
    );

    test('is absent without l10n.yaml or Flutter generation', () async {
      final root = await _createProject();
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigAbsent>());
    });

    test('reports malformed YAML as invalid instead of absent', () async {
      final root = await _createProject(l10nYaml: 'arb-dir: [');
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      final invalid = result as L10nConfigInvalid;
      expect(invalid.reason, contains('could not parse'));
      expect(invalid.location, 'l10n.yaml');
    });

    test('reports wrong modeled scalar types as invalid', () async {
      final root = await _createProject(l10nYaml: 'nullable-getter: nope');
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      expect(
        (result as L10nConfigInvalid).reason,
        'nullable-getter must be a bool.',
      );
    });

    test(
      'does not treat an explicit null modeled field as a default',
      () async {
        final root = await _createProject(l10nYaml: 'arb-dir:');
        addTearDown(() => root.delete(recursive: true));

        final result = L10nConfig.load(await ProjectContext.load(root));

        expect(result, isA<L10nConfigInvalid>());
        expect(
          (result as L10nConfigInvalid).reason,
          'arb-dir must be a string.',
        );
      },
    );

    test('rejects the removed synthetic-package option', () async {
      final root = await _createProject(l10nYaml: 'synthetic-package: true');
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      expect(
        (result as L10nConfigInvalid).reason,
        'synthetic-package is no longer supported.',
      );
    });

    test('accepts migrated real-source synthetic-package false', () async {
      final root = await _createProject(l10nYaml: 'synthetic-package: false');
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigValid>());
      expect(
        (result as L10nConfigValid).config.generatedLibraryPath,
        _projectPath(root, ['lib', 'l10n', 'app_localizations.dart']),
      );
    });

    test('rejects output and ARB paths that escape the project', () async {
      final arbRoot = await _createProject(l10nYaml: 'arb-dir: ../../outside');
      final outputRoot = await _createProject(
        l10nYaml: 'output-dir: /tmp/flutter_pruner_outside',
      );
      final templateRoot = await _createProject(
        l10nYaml: 'template-arb-file: ../../../outside.arb',
      );
      final outputFileRoot = await _createProject(
        l10nYaml: 'output-localization-file: ../../../outside.dart',
      );
      addTearDown(() => arbRoot.delete(recursive: true));
      addTearDown(() => outputRoot.delete(recursive: true));
      addTearDown(() => templateRoot.delete(recursive: true));
      addTearDown(() => outputFileRoot.delete(recursive: true));

      final arbResult = L10nConfig.load(await ProjectContext.load(arbRoot));
      final outputResult = L10nConfig.load(
        await ProjectContext.load(outputRoot),
      );
      final templateResult = L10nConfig.load(
        await ProjectContext.load(templateRoot),
      );
      final outputFileResult = L10nConfig.load(
        await ProjectContext.load(outputFileRoot),
      );

      expect(arbResult, isA<L10nConfigInvalid>());
      expect((arbResult as L10nConfigInvalid).reason, contains('arb-dir'));
      expect(outputResult, isA<L10nConfigInvalid>());
      expect(
        (outputResult as L10nConfigInvalid).reason,
        contains('output-dir'),
      );
      expect(templateResult, isA<L10nConfigInvalid>());
      expect(
        (templateResult as L10nConfigInvalid).reason,
        contains('template-arb-file'),
      );
      expect(outputFileResult, isA<L10nConfigInvalid>());
      expect(
        (outputFileResult as L10nConfigInvalid).reason,
        contains('output-localization-file'),
      );
    });

    test('does not require the generated output to exist', () async {
      final root = await _createProject(l10nYaml: 'output-dir: lib/generated');
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigValid>());
      expect(
        File(
          (result as L10nConfigValid).config.generatedLibraryPath,
        ).existsSync(),
        isFalse,
      );
    });

    test('reports a l10n.yaml directory as invalid', () async {
      final root = await _createProject();
      await Directory(p.join(root.path, 'l10n.yaml')).create();
      addTearDown(() => root.delete(recursive: true));

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      expect(
        (result as L10nConfigInvalid).reason,
        'l10n.yaml must be a regular file.',
      );
    });

    test('reports a broken l10n.yaml symlink as invalid', () async {
      final root = await _createProject();
      addTearDown(() => root.delete(recursive: true));
      final link = Link(p.join(root.path, 'l10n.yaml'));
      if (!await _createLink(link, 'missing_l10n.yaml')) return;

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      expect(
        (result as L10nConfigInvalid).reason,
        'l10n.yaml must resolve to a regular file.',
      );
    });

    test('reports an outside-project l10n.yaml symlink as invalid', () async {
      final root = await _createProject();
      final outside = await Directory.systemTemp.createTemp('l10n_outside_');
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => outside.delete(recursive: true));
      await File(p.join(outside.path, 'config.yaml')).writeAsString('');
      final link = Link(p.join(root.path, 'l10n.yaml'));
      if (!await _createLink(link, p.join(outside.path, 'config.yaml'))) return;

      final result = L10nConfig.load(await ProjectContext.load(root));

      expect(result, isA<L10nConfigInvalid>());
      expect(
        (result as L10nConfigInvalid).reason,
        'l10n.yaml resolves outside the project.',
      );
    });

    test(
      'returns canonical generated paths through an in-project symlink',
      () async {
        final root = await _createProject(
          l10nYaml: 'output-dir: lib/generated',
        );
        addTearDown(() => root.delete(recursive: true));
        final realOutput = Directory(
          p.join(root.path, 'lib', 'real_generated'),
        );
        await realOutput.create(recursive: true);
        final link = Link(p.join(root.path, 'lib', 'generated'));
        if (!await _createLink(link, realOutput.path)) return;

        final result = L10nConfig.load(await ProjectContext.load(root));

        expect(result, isA<L10nConfigValid>());
        expect(
          (result as L10nConfigValid).config.generatedLibraryPath,
          p.join(
            realOutput.resolveSymbolicLinksSync(),
            'app_localizations.dart',
          ),
        );
      },
    );
  });
}

Future<Directory> _createProject({
  bool flutter = false,
  String? l10nYaml,
}) async {
  final root = await Directory.systemTemp.createTemp('l10n_config_test_');
  await File(p.join(root.path, 'pubspec.yaml')).writeAsString('''
name: l10n_config_test
publish_to: none
environment:
  sdk: ^3.9.0
${flutter ? '''dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''' : ''}''');
  if (l10nYaml != null) {
    await File(p.join(root.path, 'l10n.yaml')).writeAsString(l10nYaml);
  }
  return root;
}

Future<bool> _createLink(Link link, String target) async {
  try {
    await link.create(target);
    return true;
  } on FileSystemException {
    markTestSkipped('symlink creation is not supported in this environment');
    return false;
  }
}

String _projectPath(Directory root, List<String> segments) =>
    p.joinAll([root.resolveSymbolicLinksSync(), ...segments]);
