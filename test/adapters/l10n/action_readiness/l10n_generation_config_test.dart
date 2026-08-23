import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_config.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _frameworkRevision38 = '3b62efc2a3da49882f43c372e0bc53daef7295a6';
const _frameworkRevision41 = '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa';
const _frameworkRevision44 = '924134a44c189315be2148659913dda1671cbe99';
const _engineRevision38 = '3838383838383838383838383838383838383838';
const _engineRevision41 = '4141414141414141414141414141414141414141';
const _engineRevision44 = '4444444444444444444444444444444444444444';

void main() {
  late Directory scratch;
  late Directory project;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('l10n-config-test-');
    project = Directory(p.join(scratch.path, 'project'));
    _copyTree(_fullFixture, project);
    _ensureDefaultInputs(project);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('exposes the strict production generation-config loader', () {
    expect(
      const DefaultL10nGenerationConfigLoader(),
      isA<L10nGenerationConfigLoader>(),
    );
  });

  group('versioned schema-v1 tables', () {
    for (final toolchainCase in _toolchainCases) {
      test('${toolchainCase.name} accepts every recognized option with exact '
          'effective values', () async {
        final config = _expectReady(
          await _load(project, toolchain: toolchainCase.identity),
        );

        expect(config.schemaVersion, toolchainCase.schemaVersion);
        expect(config.arbDirectory, 'lib/i18n');
        expect(config.templateArbPath, 'lib/i18n/app_en.arb');
        expect(config.outputDirectory, 'lib/generated');
        expect(config.baseOutputPath, 'lib/generated/strings.dart');
        expect(config.untranslatedMessagesPath, 'build/untranslated.json');
        expect(config.headerFilePath, 'lib/i18n/headers/banner.txt');
        expect(config.header, isNull);
        expect(config.outputClass, 'Strings');
        expect(config.preferredSupportedLocales, ['vi', 'en']);
        expect(config.useDeferredLoading, isTrue);
        expect(config.requiredResourceAttributes, isTrue);
        expect(config.nullableGetter, isFalse);
        expect(config.format, isFalse);
        expect(config.useEscaping, isTrue);
        expect(config.suppressWarnings, isTrue);
        expect(config.relaxSyntax, isTrue);
        expect(config.useNamedParameters, isTrue);
        expect(config.useCrLfOutputs, isFalse);
        expect(config.configurationIdentity, matches(_sha256Pattern));
        expect(
          config.pubspecBytes.contentEquals(
            ImmutableBytes.copyOf(
              File(p.join(project.path, 'pubspec.yaml')).readAsBytesSync(),
            ),
          ),
          isTrue,
        );
        expect(
          config.yamlBytes!.contentEquals(
            ImmutableBytes.copyOf(
              File(p.join(project.path, 'l10n.yaml')).readAsBytesSync(),
            ),
          ),
          isTrue,
        );
      });
    }

    test(
      'uses a distinct immutable table identity for every exact tag',
      () async {
        _writeYaml(project, ' \n');
        final configurations = <L10nGenerationConfig>[];
        for (final toolchainCase in _toolchainCases) {
          configurations.add(
            _expectReady(
              await _load(project, toolchain: toolchainCase.identity),
            ),
          );
        }

        expect(
          configurations.map((config) => config.schemaVersion).toSet(),
          L10nGenerationSchemaVersion.values.toSet(),
        );
        expect(
          configurations.map((config) => config.configurationIdentity).toSet(),
          hasLength(3),
        );
      },
    );

    for (final toolchainCase in _toolchainCases) {
      test('${toolchainCase.name} applies pinned YAML defaults', () async {
        _writeYaml(project, ' \n\t\n');

        final config = _expectReady(
          await _load(project, toolchain: toolchainCase.identity),
        );

        _expectCommonDefaults(config, format: true);
        expect(config.yamlBytes, isNotNull);
        expect(utf8.decode(config.yamlBytes!.copy()), ' \n\t\n');
      });
    }

    for (final toolchainCase in _toolchainCases) {
      test('${toolchainCase.name} uses command defaults when l10n.yaml is '
          'absent', () async {
        _deleteYaml(project);

        final config = _expectReady(
          await _load(project, toolchain: toolchainCase.identity),
        );

        _expectCommonDefaults(config, format: false);
        expect(config.schemaVersion, toolchainCase.schemaVersion);
        expect(config.yamlBytes, isNull);
      });
    }

    test('accepts scalar locale, empty header, and dotted output', () async {
      _writeYaml(
        project,
        _yaml({
          'preferred-supported-locales': 'vi',
          'header': '',
          'output-localization-file': 'app.bundle.dart',
        }),
      );

      final config = _expectReady(await _load(project));

      expect(config.preferredSupportedLocales, ['vi']);
      expect(config.header, '');
      expect(config.headerFilePath, isNull);
      expect(config.baseOutputPath, 'lib/l10n/app.bundle.dart');
    });

    for (final toolchainCase in _toolchainCases) {
      test(
        '${toolchainCase.name} recognizes a nonempty inline header',
        () async {
          _writeYaml(project, _yaml({'header': '// Keep exact header.\n'}));

          final config = _expectReady(
            await _load(project, toolchain: toolchainCase.identity),
          );

          expect(config.schemaVersion, toolchainCase.schemaVersion);
          expect(config.header, '// Keep exact header.\n');
          expect(config.headerFilePath, isNull);
        },
      );
    }

    for (final version in [
      '3.38.8',
      '3.38.7-0',
      '3.38.7+forged',
      '3.41.5-dev.1',
      '3.44.1+forged',
      '03.41.5',
      '3.041.5',
      '3.41.005',
    ]) {
      test('rejects unsupported literal Flutter version $version', () async {
        final result = await _load(
          project,
          toolchain: _machine(Version.parse(version)),
        );

        _expectRejected(
          result,
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'unsupported-flutter-version',
        );
      });
    }
  });

  group('strict l10n.yaml schema', () {
    test(
      'accepts empty and whitespace-only files as present defaults',
      () async {
        for (final contents in ['', '  \n\t\n']) {
          _writeYaml(project, contents);
          final config = _expectReady(await _load(project));
          _expectCommonDefaults(config, format: true);
          expect(config.yamlBytes, isNotNull);
          expect(config.yamlBytes!.copy(), utf8.encode(contents));
        }
      },
    );

    test('rejects a comment-only file as a non-map document', () async {
      _writeYaml(project, '# comment\n  # second\n');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-yaml-root-not-map',
      );
    });

    for (final contents in ['null\n', '~\n', 'NULL\n']) {
      test('rejects explicit null document ${jsonEncode(contents)}', () async {
        _writeYaml(project, contents);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'l10n-yaml-root-not-map',
        );
      });
    }

    for (final contents in ['value\n', '- arb-dir\n', 'true\n']) {
      test('rejects non-map root ${jsonEncode(contents)}', () async {
        _writeYaml(project, contents);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'l10n-yaml-root-not-map',
        );
      });
    }

    test('rejects invalid UTF-8', () async {
      _writeYamlBytes(project, [0xc3, 0x28]);
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-yaml-invalid-utf8',
      );
    });

    for (final contents in [
      'arb-dir: lib/l10n\narb-dir: lib/other\n',
      '{arb-dir: lib/l10n, arb-dir: lib/other}\n',
      'arb-dir: lib/l10n\n"arb-dir": lib/other\n',
      'arb-dir: lib/l10n\n---\noutput-dir: lib/generated\n',
    ]) {
      test('rejects duplicate or multiple-document YAML', () async {
        _writeYaml(project, contents);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'l10n-yaml-malformed',
        );
      });
    }

    test('rejects an unknown string key', () async {
      _writeYaml(project, 'future-option: true\n');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-option-unknown',
      );
    });

    test('rejects a non-string key', () async {
      _writeYaml(project, '1: true\n');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-option-key-not-string',
      );
    });

    for (final key in _schemaV1Keys) {
      test('rejects explicit null for $key', () async {
        _writeYaml(project, '$key: null\n');
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'l10n-option-null',
        );
      });
    }

    for (final fieldCase in _wrongTypeCases) {
      test('rejects wrong type for ${fieldCase.key}', () async {
        _writeYaml(project, _yaml({fieldCase.key: fieldCase.value}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'l10n-option-wrong-type',
        );
      });
    }

    test('rejects a non-string preferred locale list member', () async {
      _writeYaml(project, 'preferred-supported-locales: [en, 1]\n');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-option-wrong-type',
      );
    });

    for (final locale in ['', 'en_', '_US', 'en__US', 'en_US_POSIX_extra']) {
      test(
        'rejects unsafe preferred locale shape ${jsonEncode(locale)}',
        () async {
          _writeYaml(
            project,
            _yaml({
              'preferred-supported-locales': [locale],
            }),
          );
          _expectRejected(
            await _load(project),
            code: L10nEvidenceRejectionCode.unsupportedConfiguration,
            detailCode: 'l10n-option-invalid-value',
          );
        },
      );
    }

    test('accepts an empty preferred locale list', () async {
      _writeYaml(project, 'preferred-supported-locales: []\n');
      final config = _expectReady(await _load(project));
      expect(config.preferredSupportedLocales, isEmpty);
    });

    test('accepts synthetic-package false as a no-op', () async {
      _writeYaml(project, 'synthetic-package: false\n');
      _expectReady(await _load(project));
    });

    test('rejects synthetic-package true', () async {
      _writeYaml(project, 'synthetic-package: true\n');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'synthetic-package-enabled',
      );
    });

    for (final contents in [
      'header: ""\nheader-file: ""\n',
      'header: value\nheader-file: headers/banner.txt\n',
    ]) {
      test('rejects header/header-file by simultaneous key presence', () async {
        _writeYaml(project, contents);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'header-options-conflict',
        );
      });
    }
  });

  group('raw pubspec authority', () {
    for (final generateEntry in [
      'generate: false',
      'generate: null',
      'generate: "true"',
      '',
    ]) {
      test(
        'rejects non-exact true entry ${jsonEncode(generateEntry)}',
        () async {
          final context = await ProjectContext.load(project);
          _writePubspec(project, _pubspec(generateEntry: generateEntry));
          _expectRejected(
            await _load(project, context: context),
            code: L10nEvidenceRejectionCode.unsupportedConfiguration,
            detailCode: 'flutter-generate-not-true',
          );
        },
      );
    }

    test('uses raw pubspec instead of the ProjectContext snapshot', () async {
      final context = await ProjectContext.load(project);
      expect(context.flutterSection['generate'], isTrue);
      _writePubspec(project, _pubspec(generateEntry: 'generate: false'));
      _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'flutter-generate-not-true',
      );
    });

    for (final bytes in [
      utf8.encode(
        '${_pubspec(generateEntry: 'generate: true')}  generate: true\n',
      ),
      utf8.encode(
        'name: fixture\nname: duplicate\nflutter:\n  generate: true\n',
      ),
      [0xc3, 0x28],
    ]) {
      test('rejects malformed or duplicate raw pubspec', () async {
        final context = await ProjectContext.load(project);
        File(p.join(project.path, 'pubspec.yaml')).writeAsBytesSync(bytes);
        final detail = bytes.length == 2
            ? 'pubspec-yaml-invalid-utf8'
            : 'pubspec-yaml-malformed';
        _expectRejected(
          await _load(project, context: context),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: detail,
        );
      });
    }

    test('selects CRLF when any literal 0D0A pair exists', () async {
      final lf = _pubspec(generateEntry: 'generate: true');
      _writePubspecBytes(project, utf8.encode(lf.replaceFirst('\n', '\r\n')));
      final config = _expectReady(await _load(project));
      expect(config.useCrLfOutputs, isTrue);
    });

    test('does not select CRLF for lone carriage returns', () async {
      final lf = _pubspec(generateEntry: 'generate: true');
      _writePubspecBytes(project, utf8.encode(lf.replaceAll('\n', '\r')));
      final config = _expectReady(await _load(project));
      expect(config.useCrLfOutputs, isFalse);
    });

    test('retains exact pubspec bytes defensively', () async {
      final bytes = utf8.encode(
        _pubspec(generateEntry: 'generate: true').replaceFirst('\n', '\r\n'),
      );
      _writePubspecBytes(project, bytes);
      final config = _expectReady(await _load(project));
      final returned = config.pubspecBytes.copy();
      returned.fillRange(0, returned.length, 0);
      expect(config.pubspecBytes.copy(), bytes);
      expect(config.pubspecBytes.copy(), isNot(returned));
    });

    test('rejects missing and non-map raw pubspec authorities', () async {
      final context = await ProjectContext.load(project);
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      final missing = _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'required-file-missing',
      );
      expect(missing.relativePath, 'pubspec.yaml');

      _writePubspec(project, '[]\n');
      final nonMap = _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'pubspec-yaml-root-not-map',
      );
      expect(nonMap.relativePath, 'pubspec.yaml');
    });

    test(
      'keeps V2 applicability but strict readiness rejects disabled generation',
      () async {
        final context = await ProjectContext.load(project);
        _writePubspec(project, _pubspec(generateEntry: 'generate: false'));

        expect(L10nConfig.load(context).isApplicable, isTrue);
        final failure = _expectRejected(
          await _load(project, context: context),
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'flutter-generate-not-true',
        );
        expect(failure.relativePath, 'pubspec.yaml');
      },
    );

    test('rejects no-YAML generation outside raw V2 applicability', () async {
      _deleteYaml(project);
      _writePubspec(
        project,
        'name: l10n_config_fixture\n'
        'environment:\n'
        '  sdk: ^3.9.0\n'
        'flutter:\n'
        '  generate: true\n',
      );
      final context = await ProjectContext.load(project);

      expect(L10nConfig.load(context).isApplicable, isFalse);
      final failure = _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'l10n-generation-not-applicable',
      );
      expect(failure.relativePath, 'pubspec.yaml');
    });

    test(
      'keeps YAML projects applicable without a Flutter dependency',
      () async {
        _writeYaml(project, 'format: true\n');
        _writePubspec(
          project,
          'name: l10n_config_fixture\n'
          'environment:\n'
          '  sdk: ^3.9.0\n'
          'flutter:\n'
          '  generate: true\n',
        );
        final context = await ProjectContext.load(project);

        expect(L10nConfig.load(context).isApplicable, isTrue);
        _expectReady(await _load(project, context: context));
      },
    );
  });

  group('component-wise path safety', () {
    for (final pathCase in _invalidPathCases) {
      test('rejects ${pathCase.name} relative path grammar', () async {
        _writeYaml(project, _yaml({'arb-dir': pathCase.value}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-grammar-invalid',
        );
      });
    }

    for (final key in [
      'arb-dir',
      'output-dir',
      'template-arb-file',
      'output-localization-file',
      'untranslated-messages-file',
      'header-file',
    ]) {
      test('rejects parent traversal in $key', () async {
        final value = key == 'output-localization-file'
            ? '../escape.dart'
            : '../escape';
        _writeYaml(project, _yaml({key: value}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-grammar-invalid',
        );
      });
    }

    test('applies shared URI and byte grammar to every path key', () async {
      const invalidByKey = <String, List<String>>{
        'arb-dir': [
          '',
          'file:bad',
          r'bad\name',
          'bad%2Fname',
          'bad?x',
          'bad#x',
          'bäd',
        ],
        'output-dir': [
          '',
          'file:bad',
          r'bad\name',
          'bad%2Fname',
          'bad?x',
          'bad#x',
          'bäd',
        ],
        'template-arb-file': [
          '',
          'file:bad',
          r'bad\name',
          'bad%2Fname',
          'bad?x',
          'bad#x',
          'bäd',
        ],
        'output-localization-file': [
          '',
          'file:app.dart',
          r'bad\app.dart',
          'bad%2Fapp.dart',
          'app?.dart',
          'app#.dart',
          'äpp.dart',
        ],
        'untranslated-messages-file': [
          '',
          'file:bad',
          r'bad\name',
          'bad%2Fname',
          'bad?x',
          'bad#x',
          'bäd',
        ],
        'header-file': [
          '',
          'file:bad',
          r'bad\name',
          'bad%2Fname',
          'bad?x',
          'bad#x',
          'bäd',
        ],
      };

      for (final entry in invalidByKey.entries) {
        for (final value in entry.value) {
          _writeYaml(project, _yaml({entry.key: value}));
          _expectRejected(
            await _load(project),
            code: L10nEvidenceRejectionCode.invalidInputPath,
            detailCode: 'path-grammar-invalid',
          );
        }
      }
    });

    for (final value in [
      'nested/app.dart',
      'app',
      '.dart',
      'app.DART',
      'app.dart/',
    ]) {
      test('rejects unsafe output-localization-file $value', () async {
        _writeYaml(project, _yaml({'output-localization-file': value}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: value == 'app.dart/'
              ? 'path-grammar-invalid'
              : 'output-localization-file-invalid',
        );
      });
    }

    for (final value in [
      'foo-bar.dart',
      '1foo.dart',
      "foo'.dart",
      'foo\$.dart',
      'foo bar.dart',
    ]) {
      test('rejects generator-unsafe output filename $value', () async {
        _writeYaml(
          project,
          _yaml({
            'output-localization-file': value,
            'use-deferred-loading': true,
          }),
        );
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'output-localization-file-invalid',
        );
      });
    }

    test(
      'accepts nested absent outputs below a safe directory ancestor',
      () async {
        _writeYaml(
          project,
          _yaml({
            'output-dir': 'generated/deep/tree',
            'untranslated-messages-file': 'reports/deep/untranslated.json',
          }),
        );
        final config = _expectReady(await _load(project));
        expect(config.outputDirectory, 'generated/deep/tree');
        expect(
          config.baseOutputPath,
          'generated/deep/tree/app_localizations.dart',
        );
        expect(
          config.untranslatedMessagesPath,
          'reports/deep/untranslated.json',
        );
      },
    );

    test('rejects an output below an existing file ancestor', () async {
      File(p.join(project.path, 'blocked')).writeAsStringSync('file');
      _writeYaml(project, _yaml({'output-dir': 'blocked/deep'}));
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'path-ancestor-not-directory',
      );
    });

    test('requires arb-dir to be an existing directory', () async {
      File(p.join(project.path, 'arb-file')).writeAsStringSync('not a dir');
      for (final entry in [
        ('missing-arb-dir', 'required-directory-missing'),
        ('arb-file', 'required-directory-not-directory'),
      ]) {
        _writeYaml(project, _yaml({'arb-dir': entry.$1}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: entry.$2,
        );
      }
    });

    test('requires template and header inputs to be regular files', () async {
      Directory(p.join(project.path, 'lib/l10n/template-dir')).createSync();
      Directory(p.join(project.path, 'lib/l10n/header-dir')).createSync();
      for (final entry in [
        ('template-arb-file', 'missing.arb', 'required-file-missing'),
        ('template-arb-file', 'template-dir', 'required-file-not-regular'),
        ('header-file', 'missing.txt', 'required-file-missing'),
        ('header-file', 'header-dir', 'required-file-not-regular'),
      ]) {
        _writeYaml(project, _yaml({entry.$1: entry.$2}));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: entry.$3,
        );
      }
    });

    test('accepts existing regular optional outputs', () async {
      final output = Directory(p.join(project.path, 'generated'))..createSync();
      File(p.join(output.path, 'app_localizations.dart')).writeAsStringSync('');
      File(p.join(project.path, 'untranslated.json')).writeAsStringSync('{}');
      _writeYaml(
        project,
        _yaml({
          'output-dir': 'generated',
          'untranslated-messages-file': 'untranslated.json',
        }),
      );
      _expectReady(await _load(project));
    });

    test('rejects existing output leaves that are directories', () async {
      final base = Directory(
        p.join(project.path, 'lib/l10n/app_localizations.dart'),
      )..createSync();
      _writeYaml(project, '');
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'output-leaf-not-regular',
      );

      base.deleteSync();
      Directory(p.join(project.path, 'untranslated.json')).createSync();
      _writeYaml(
        project,
        _yaml({'untranslated-messages-file': 'untranslated.json'}),
      );
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'output-leaf-not-regular',
      );
    });

    test('rejects non-regular root configuration files', () async {
      final context = await ProjectContext.load(project);
      File(p.join(project.path, 'l10n.yaml')).deleteSync();
      Directory(p.join(project.path, 'l10n.yaml')).createSync();
      _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'l10n-config-not-regular',
      );

      Directory(p.join(project.path, 'l10n.yaml')).deleteSync();
      _writeYaml(project, '');
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();
      Directory(p.join(project.path, 'pubspec.yaml')).createSync();
      _expectRejected(
        await _load(project, context: context),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'pubspec-not-regular',
      );
    });

    test(
      'rejects symlinked config, input, and output components',
      () async {
        final cases = <void Function()>[
          () {
            final source = File(p.join(project.path, 'l10n.yaml'));
            source.renameSync(p.join(project.path, 'l10n-real.yaml'));
            Link(source.path).createSync('l10n-real.yaml');
          },
          () {
            Link(p.join(project.path, 'lib/arb-link')).createSync('l10n');
            _writeYaml(project, _yaml({'arb-dir': 'lib/arb-link'}));
          },
          () {
            Link(
              p.join(project.path, 'lib/l10n/template-link.arb'),
            ).createSync('app_en.arb');
            _writeYaml(
              project,
              _yaml({'template-arb-file': 'template-link.arb'}),
            );
          },
          () {
            File(
              p.join(project.path, 'lib/l10n/header-real.txt'),
            ).writeAsStringSync('header');
            Link(
              p.join(project.path, 'lib/l10n/header-link.txt'),
            ).createSync('header-real.txt');
            _writeYaml(project, _yaml({'header-file': 'header-link.txt'}));
          },
          () {
            Directory(p.join(project.path, 'output-real')).createSync();
            Link(p.join(project.path, 'output-link')).createSync('output-real');
            _writeYaml(project, _yaml({'output-dir': 'output-link/deep'}));
          },
        ];

        for (final arrange in cases) {
          _copyTree(_fullFixture, project, replace: true);
          _ensureDefaultInputs(project);
          arrange();
          _expectRejected(
            await _load(project),
            code: L10nEvidenceRejectionCode.invalidInputPath,
            detailCode: 'path-symlink-component',
          );
        }
      },
      skip: Platform.isWindows
          ? 'symlink creation is not portable on Windows'
          : false,
    );

    test(
      'rejects a raw pubspec symlink with retained ProjectContext',
      () async {
        final context = await ProjectContext.load(project);
        final source = File(p.join(project.path, 'pubspec.yaml'));
        source.renameSync(p.join(project.path, 'pubspec-real.yaml'));
        Link(source.path).createSync('pubspec-real.yaml');
        _expectRejected(
          await _load(project, context: context),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-symlink-component',
        );
      },
      skip: Platform.isWindows
          ? 'symlink creation is not portable on Windows'
          : false,
    );

    test(
      'rejects symlinked and dangling optional output leaves',
      () async {
        final realBase = File(p.join(project.path, 'base-real.dart'))
          ..writeAsStringSync('');
        Link(
          p.join(project.path, 'lib/l10n/app_localizations.dart'),
        ).createSync(realBase.path);
        _writeYaml(project, '');
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-symlink-component',
        );

        Link(
          p.join(project.path, 'lib/l10n/app_localizations.dart'),
        ).deleteSync();
        Link(
          p.join(project.path, 'untranslated.json'),
        ).createSync('missing-target.json');
        _writeYaml(
          project,
          _yaml({'untranslated-messages-file': 'untranslated.json'}),
        );
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-symlink-component',
        );
      },
      skip: Platform.isWindows
          ? 'symlink creation is not portable on Windows'
          : false,
    );

    test('reports only validated project-relative paths in failures', () async {
      _writeYaml(project, _yaml({'template-arb-file': 'missing.arb'}));
      final safeFailure = _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'required-file-missing',
      );
      expect(safeFailure.relativePath, 'lib/l10n/missing.arb');

      _writeYaml(project, _yaml({'arb-dir': '../unsafe'}));
      final unsafeFailure = _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'path-grammar-invalid',
      );
      expect(unsafeFailure.relativePath, isNull);
    });
  });

  group('portable case-fold and role collisions', () {
    test('rejects different spelling of an existing first component', () async {
      _writeYaml(project, _yaml({'arb-dir': 'LIB/l10n'}));
      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'path-case-fold-collision',
      );
    });

    test('rejects different spelling of intermediate and leaf names', () async {
      for (final yaml in [
        _yaml({'arb-dir': 'lib/L10N'}),
        _yaml({'template-arb-file': 'APP_EN.arb'}),
      ]) {
        _writeYaml(project, yaml);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-case-fold-collision',
        );
      }
    });

    test(
      'rejects output spelling colliding with an existing sibling',
      () async {
        final output = Directory(p.join(project.path, 'generated'))
          ..createSync();
        File(p.join(output.path, 'STRINGS.dart')).writeAsStringSync('');
        _writeYaml(
          project,
          _yaml({
            'output-dir': 'generated',
            'output-localization-file': 'strings.dart',
          }),
        );
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-case-fold-collision',
        );
      },
    );

    test('rejects exact distinct file-role collisions', () async {
      File(p.join(project.path, 'lib/l10n/app.dart')).writeAsStringSync('{}\n');
      for (final yaml in [
        _yaml({
          'output-dir': 'lib/l10n',
          'template-arb-file': 'app.dart',
          'output-localization-file': 'app.dart',
        }),
        _yaml({'untranslated-messages-file': 'pubspec.yaml'}),
        _yaml({'untranslated-messages-file': 'l10n.yaml'}),
        _yaml({'header-file': 'app_en.arb'}),
      ]) {
        _writeYaml(project, yaml);
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'configured-path-role-collision',
        );
      }
    });

    test(
      'rejects base output colliding with a configured header input',
      () async {
        File(
          p.join(project.path, 'lib/l10n/header.dart'),
        ).writeAsStringSync('// h\n');
        _writeYaml(
          project,
          _yaml({
            'header-file': 'header.dart',
            'output-localization-file': 'header.dart',
          }),
        );

        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'configured-path-role-collision',
        );
      },
    );

    test(
      'rejects folded base/sidecar output collisions before creation',
      () async {
        _writeYaml(
          project,
          _yaml({
            'output-dir': 'generated',
            'output-localization-file': 'strings.dart',
            'untranslated-messages-file': 'generated/STRINGS.dart',
          }),
        );
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-case-fold-collision',
        );
      },
    );

    test(
      'rejects configured file-prefix role collisions before creation',
      () async {
        for (final yaml in [
          _yaml({
            'output-dir': 'generated',
            'output-localization-file': 'strings.dart',
            'untranslated-messages-file': 'generated/strings.dart/report.json',
          }),
          _yaml({
            'output-dir': 'generated/strings.dart',
            'untranslated-messages-file': 'generated/strings.dart',
          }),
          _yaml({
            'output-dir': 'reports/root/deep',
            'untranslated-messages-file': 'reports/root',
          }),
        ]) {
          _writeYaml(project, yaml);
          _expectRejected(
            await _load(project),
            code: L10nEvidenceRejectionCode.invalidInputPath,
            detailCode: 'configured-path-role-collision',
          );
        }
      },
    );

    test('rejects configured component case aliases before creation', () async {
      _writeYaml(
        project,
        _yaml({
          'output-dir': 'gen/Foo',
          'untranslated-messages-file': 'gen/foo/report.json',
        }),
      );

      _expectRejected(
        await _load(project),
        code: L10nEvidenceRejectionCode.invalidInputPath,
        detailCode: 'path-case-fold-collision',
      );
    });

    test('allows output-dir to equal arb-dir', () async {
      _writeYaml(project, '');
      final config = _expectReady(await _load(project));
      expect(config.outputDirectory, config.arbDirectory);
    });

    test('allows normal configured directory ancestry', () async {
      for (final outputDirectory in ['lib', 'lib/l10n/generated']) {
        _writeYaml(project, _yaml({'output-dir': outputDirectory}));
        final config = _expectReady(await _load(project));
        expect(config.outputDirectory, outputDirectory);
      }
    });

    test(
      'rejects an alias resolved only by filesystem normalization',
      () async {
        final output = Directory(p.join(project.path, 'generated'))
          ..createSync();
        File(p.join(output.path, 'Keep.dart')).writeAsStringSync('');
        final aliasIsResolved = File(
          p.join(output.path, 'Keep.dart'),
        ).existsSync();
        _writeYaml(
          project,
          _yaml({
            'output-dir': 'generated',
            'output-localization-file': 'Keep.dart',
          }),
        );

        final result = await _load(project);
        if (aliasIsResolved) {
          _expectRejected(
            result,
            code: L10nEvidenceRejectionCode.invalidInputPath,
            detailCode: 'path-case-fold-collision',
          );
        } else {
          _expectReady(result);
        }
      },
    );

    test(
      'rejects case aliases for root pubspec and l10n authorities',
      () async {
        File(
          p.join(project.path, 'l10n.yaml'),
        ).renameSync(p.join(project.path, 'L10N.yaml'));
        _expectRejected(
          await _load(project),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-case-fold-collision',
        );

        File(
          p.join(project.path, 'L10N.yaml'),
        ).renameSync(p.join(project.path, 'l10n.yaml'));
        final context = await ProjectContext.load(project);
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).renameSync(p.join(project.path, 'PUBSPEC.yaml'));
        _expectRejected(
          await _load(project, context: context),
          code: L10nEvidenceRejectionCode.invalidInputPath,
          detailCode: 'path-case-fold-collision',
        );
      },
    );
  });

  group('configuration identity and immutability', () {
    test('is stable when the byte-identical project is relocated', () async {
      final second = Directory(p.join(scratch.path, 'relocated'));
      _copyTree(_fullFixture, second);
      _ensureDefaultInputs(second);
      final firstConfig = _expectReady(await _load(project));
      final secondConfig = _expectReady(await _load(second));
      expect(
        secondConfig.configurationIdentity,
        firstConfig.configurationIdentity,
      );
      expect(firstConfig.arbDirectory, 'lib/i18n');
      expect(secondConfig.arbDirectory, 'lib/i18n');
    });

    test('changes for raw YAML bytes with equal effective values', () async {
      _writeYaml(project, 'format: true\n');
      final first = _expectReady(await _load(project));
      _writeYaml(project, '# comment\nformat: true\n');
      final second = _expectReady(await _load(project));
      expect(second.configurationIdentity, isNot(first.configurationIdentity));
    });

    test('ignores LF-only pubspec prose outside framed facts', () async {
      _writeYaml(project, '');
      final first = _expectReady(await _load(project));
      final original = File(
        p.join(project.path, 'pubspec.yaml'),
      ).readAsStringSync();
      _writePubspec(project, '$original# unrelated LF comment\n');
      final second = _expectReady(await _load(project));
      expect(
        second.pubspecBytes.sha256Hex,
        isNot(first.pubspecBytes.sha256Hex),
      );
      expect(second.configurationIdentity, first.configurationIdentity);
    });

    test('changes when the raw pubspec CRLF fact changes', () async {
      _writeYaml(project, '');
      final first = _expectReady(await _load(project));
      final lf = File(p.join(project.path, 'pubspec.yaml')).readAsStringSync();
      _writePubspecBytes(project, utf8.encode(lf.replaceFirst('\n', '\r\n')));
      final second = _expectReady(await _load(project));
      expect(first.useCrLfOutputs, isFalse);
      expect(second.useCrLfOutputs, isTrue);
      expect(second.configurationIdentity, isNot(first.configurationIdentity));
    });

    test('binds every Flutter machine identity field', () async {
      final baseline = _expectReady(await _load(project));
      final variants = [
        _identity41.copyWith(frameworkRevision: 'revision-different'),
        _identity41.copyWith(engineRevision: 'engine-different'),
        _identity41.copyWith(dartSdkVersion: 'Dart 3.11.3 different'),
      ];
      for (final variant in variants) {
        final config = _expectReady(await _load(project, toolchain: variant));
        expect(
          config.configurationIdentity,
          isNot(baseline.configurationIdentity),
        );
      }
    });

    test('length-frames ambiguous adjacent machine fields', () async {
      final first = _expectReady(
        await _load(
          project,
          toolchain: _machine(
            Version(3, 41, 5),
            frameworkRevision: 'a',
            engineRevision: 'bc',
          ),
        ),
      );
      final second = _expectReady(
        await _load(
          project,
          toolchain: _machine(
            Version(3, 41, 5),
            frameworkRevision: 'ab',
            engineRevision: 'c',
          ),
        ),
      );
      expect(second.configurationIdentity, isNot(first.configurationIdentity));
    });

    test('binds preferred locale count and order', () async {
      _writeYaml(project, 'preferred-supported-locales: [vi, en]\n');
      final first = _expectReady(await _load(project));
      _writeYaml(project, 'preferred-supported-locales: [en, vi]\n');
      final second = _expectReady(await _load(project));
      expect(second.configurationIdentity, isNot(first.configurationIdentity));
    });

    test('returns immutable locale and rejection lists', () async {
      final config = _expectReady(await _load(project));
      expect(
        () => config.preferredSupportedLocales.add('fr'),
        throwsUnsupportedError,
      );
      _writeYaml(project, 'unknown: true\n');
      final rejected = await _load(project) as L10nGenerationConfigRejected;
      expect(() => rejected.failures.clear(), throwsUnsupportedError);
    });
  });
}

final _fullFixture = Directory(
  p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'l10n_action_readiness',
    'config',
    'full',
  ),
);

final _identity38 = _machine(
  Version(3, 38, 7),
  frameworkRevision: _frameworkRevision38,
  engineRevision: _engineRevision38,
  dartSdkVersion: '3.10.7',
);
final _identity41 = _machine(
  Version(3, 41, 5),
  frameworkRevision: _frameworkRevision41,
  engineRevision: _engineRevision41,
  dartSdkVersion: '3.11.3',
);
final _identity44 = _machine(
  Version(3, 44, 1),
  frameworkRevision: _frameworkRevision44,
  engineRevision: _engineRevision44,
  dartSdkVersion: '3.12.1',
);

final _toolchainCases = [
  (
    name: 'Flutter 3.38.7',
    identity: _identity38,
    schemaVersion: L10nGenerationSchemaVersion.flutter3387,
  ),
  (
    name: 'Flutter 3.41.5',
    identity: _identity41,
    schemaVersion: L10nGenerationSchemaVersion.flutter3415,
  ),
  (
    name: 'Flutter 3.44.1',
    identity: _identity44,
    schemaVersion: L10nGenerationSchemaVersion.flutter3441,
  ),
];

const _schemaV1Keys = [
  'arb-dir',
  'output-dir',
  'template-arb-file',
  'output-localization-file',
  'untranslated-messages-file',
  'output-class',
  'header',
  'header-file',
  'use-deferred-loading',
  'preferred-supported-locales',
  'required-resource-attributes',
  'nullable-getter',
  'format',
  'use-escaping',
  'suppress-warnings',
  'relax-syntax',
  'use-named-parameters',
  'synthetic-package',
];

const _wrongTypeCases = [
  (key: 'arb-dir', value: true),
  (key: 'output-dir', value: true),
  (key: 'template-arb-file', value: true),
  (key: 'output-localization-file', value: true),
  (key: 'untranslated-messages-file', value: true),
  (key: 'output-class', value: true),
  (key: 'header', value: true),
  (key: 'header-file', value: true),
  (key: 'use-deferred-loading', value: 'true'),
  (key: 'preferred-supported-locales', value: true),
  (key: 'required-resource-attributes', value: 'true'),
  (key: 'nullable-getter', value: 'true'),
  (key: 'format', value: 'true'),
  (key: 'use-escaping', value: 'true'),
  (key: 'suppress-warnings', value: 'true'),
  (key: 'relax-syntax', value: 'true'),
  (key: 'use-named-parameters', value: 'true'),
  (key: 'synthetic-package', value: 'false'),
];

const _invalidPathCases = [
  (name: 'empty', value: ''),
  (name: 'POSIX absolute', value: '/tmp/l10n'),
  (name: 'Windows drive absolute', value: 'C:/l10n'),
  (name: 'Windows backslash absolute', value: r'C:\l10n'),
  (name: 'URI scheme', value: 'file:lib/l10n'),
  (name: 'query ambiguity', value: 'lib/l10n?ignored'),
  (name: 'fragment ambiguity', value: 'lib/l10n#ignored'),
  (name: 'percent ambiguity', value: 'lib%2Fl10n'),
  (name: 'backslash ambiguity', value: r'lib\l10n'),
  (name: 'control character', value: 'lib/\u0001l10n'),
  (name: 'parent component', value: 'lib/../l10n'),
  (name: 'dot component', value: 'lib/./l10n'),
  (name: 'repeated separator', value: 'lib//l10n'),
  (name: 'trailing separator', value: 'lib/l10n/'),
  (name: 'non-ASCII component', value: 'lib/l10né'),
];

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

Future<L10nGenerationConfigLoadResult> _load(
  Directory project, {
  FlutterMachineIdentity? toolchain,
  ProjectContext? context,
}) async {
  return const DefaultL10nGenerationConfigLoader().load(
    project: context ?? await ProjectContext.load(project),
    toolchain: toolchain ?? _identity41,
  );
}

L10nGenerationConfig _expectReady(L10nGenerationConfigLoadResult result) {
  if (result case L10nGenerationConfigRejected(:final failures)) {
    fail(
      'unexpected config rejection: '
      '${failures.map((failure) => '${failure.code.name}/${failure.detailCode}').join(', ')}',
    );
  }
  return (result as L10nGenerationConfigReady).config;
}

L10nEvidenceFailure _expectRejected(
  L10nGenerationConfigLoadResult result, {
  required L10nEvidenceRejectionCode code,
  required String detailCode,
}) {
  expect(result, isA<L10nGenerationConfigRejected>());
  final failures = (result as L10nGenerationConfigRejected).failures;
  expect(failures, hasLength(1));
  final failure = failures.single;
  expect(failure.code, code);
  expect(failure.stage, 'generation-config-load');
  expect(failure.detailCode, detailCode);
  return failure;
}

void _expectCommonDefaults(
  L10nGenerationConfig config, {
  required bool format,
}) {
  expect(config.arbDirectory, 'lib/l10n');
  expect(config.templateArbPath, 'lib/l10n/app_en.arb');
  expect(config.outputDirectory, 'lib/l10n');
  expect(config.baseOutputPath, 'lib/l10n/app_localizations.dart');
  expect(config.untranslatedMessagesPath, isNull);
  expect(config.headerFilePath, isNull);
  expect(config.header, isNull);
  expect(config.outputClass, 'AppLocalizations');
  expect(config.preferredSupportedLocales, isEmpty);
  expect(config.useDeferredLoading, isFalse);
  expect(config.requiredResourceAttributes, isFalse);
  expect(config.nullableGetter, isTrue);
  expect(config.format, format);
  expect(config.useEscaping, isFalse);
  expect(config.suppressWarnings, isFalse);
  expect(config.relaxSyntax, isFalse);
  expect(config.useNamedParameters, isFalse);
}

FlutterMachineIdentity _machine(
  Version version, {
  String frameworkRevision = _frameworkRevision41,
  String engineRevision = _engineRevision41,
  String dartSdkVersion = '3.11.3',
}) => FlutterMachineIdentity(
  frameworkVersion: version,
  frameworkRevision: frameworkRevision,
  engineRevision: engineRevision,
  dartSdkVersion: dartSdkVersion,
);

extension on FlutterMachineIdentity {
  FlutterMachineIdentity copyWith({
    String? frameworkRevision,
    String? engineRevision,
    String? dartSdkVersion,
  }) => FlutterMachineIdentity(
    frameworkVersion: frameworkVersion,
    frameworkRevision: frameworkRevision ?? this.frameworkRevision,
    engineRevision: engineRevision ?? this.engineRevision,
    dartSdkVersion: dartSdkVersion ?? this.dartSdkVersion,
  );
}

void _ensureDefaultInputs(Directory project) {
  final arb = Directory(p.join(project.path, 'lib/l10n'))
    ..createSync(recursive: true);
  File(
    p.join(arb.path, 'app_en.arb'),
  ).writeAsStringSync('{"@@locale":"en","hello":"Hello"}\n');
}

void _writeYaml(Directory project, String contents) =>
    _writeYamlBytes(project, utf8.encode(contents));

void _writeYamlBytes(Directory project, List<int> bytes) =>
    File(p.join(project.path, 'l10n.yaml')).writeAsBytesSync(bytes);

void _deleteYaml(Directory project) {
  final file = File(p.join(project.path, 'l10n.yaml'));
  if (file.existsSync()) file.deleteSync();
}

void _writePubspec(Directory project, String contents) =>
    _writePubspecBytes(project, utf8.encode(contents));

void _writePubspecBytes(Directory project, List<int> bytes) =>
    File(p.join(project.path, 'pubspec.yaml')).writeAsBytesSync(bytes);

String _pubspec({required String generateEntry}) =>
    'name: l10n_config_fixture\n'
    'environment:\n'
    '  sdk: ^3.9.0\n'
    'dependencies:\n'
    '  flutter:\n'
    '    sdk: flutter\n'
    'flutter:\n'
    '${generateEntry.isEmpty ? '' : '  $generateEntry\n'}';

String _yaml(Map<String, Object?> values) =>
    '${values.entries.map((entry) => '${entry.key}: ${jsonEncode(entry.value)}').join('\n')}\n';

void _copyTree(
  Directory source,
  Directory destination, {
  bool replace = false,
}) {
  if (replace && destination.existsSync()) {
    destination.deleteSync(recursive: true);
  }
  destination.createSync(recursive: true);
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target)
        ..parent.createSync(recursive: true)
        ..writeAsBytesSync(entity.readAsBytesSync());
    }
  }
}
