import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_config.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/l10n_test')));

void main() {
  group('ArbInventory', () {
    test(
      'inventories sorted template keys with stable origins and ids',
      () async {
        final project = await loadFixture();
        final config = (L10nConfig.load(project) as L10nConfigValid).config;

        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys.map((key) => key.key), [
          'cartItem',
          'greeting',
          'welcome',
        ]);
        expect(inventory.keys.map((key) => key.nodeId), [
          'l10n:l10n_test:cartItem',
          'l10n:l10n_test:greeting',
          'l10n:l10n_test:welcome',
        ]);
        expect(
          inventory.keys.every(
            (key) =>
                project.relative(key.origin.toFilePath()) ==
                'lib/l10n/app_en.arb',
          ),
          isTrue,
        );
        expect(inventory.blockers, isEmpty);
      },
    );

    test('distinguishes getters from placeholder and plural methods', () async {
      final project = await loadFixture();
      final config = (L10nConfig.load(project) as L10nConfigValid).config;

      final inventory = ArbInventory.read(project, config);

      final byKey = {for (final key in inventory.keys) key.key: key};
      expect(byKey['welcome']!.memberKind, ArbGeneratedMemberKind.getter);
      expect(byKey['greeting']!.memberKind, ArbGeneratedMemberKind.method);
      expect(byKey['cartItem']!.memberKind, ArbGeneratedMemberKind.method);
      expect(byKey['greeting']!.hasPlaceholders, isTrue);
    });

    test('reports missing locales as stable joined text', () async {
      final project = await loadFixture();
      final config = (L10nConfig.load(project) as L10nConfigValid).config;

      final inventory = ArbInventory.read(project, config);

      expect(
        inventory.keys
            .singleWhere((key) => key.key == 'cartItem')
            .missingLocales,
        'vi',
      );
      expect(
        inventory.keys
            .singleWhere((key) => key.key == 'welcome')
            .missingLocales,
        isEmpty,
      );
    });

    test('does not throw and scopes every malformed input blocker', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final arbDir = Directory(p.join(root.path, 'lib', 'l10n'));
      File(p.join(arbDir.path, 'app_en.arb')).writeAsStringSync('{');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;

      final inventory = ArbInventory.read(project, config);

      expect(inventory.keys, isEmpty);
      expect(inventory.blockers, isNotEmpty);
      expect(
        inventory.blockers.every(
          (blocker) =>
              blocker.affectedNamespace != null ||
              blocker.affectedNodeIds.isNotEmpty,
        ),
        isTrue,
      );
    });

    test(
      'reports a missing template without treating it as empty JSON',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).delete();

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys, isEmpty);
        expect(inventory.blockers.single.reason, contains('missing'));
        expect(inventory.blockers.single.affectedNamespace, isNotNull);
      },
    );

    test('keeps valid template keys and blocks malformed locales', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      File(
        p.join(root.path, 'lib', 'l10n', 'app_vi.arb'),
      ).writeAsStringSync('{');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;

      final inventory = ArbInventory.read(project, config);

      expect(inventory.keys, hasLength(3));
      expect(inventory.blockers, isNotEmpty);
    });

    test(
      'blocks duplicate JSON keys without collapsing them in jsonDecode',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync(
          '{"@@locale":"en","welcome":"first","welcome":"second"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys, isEmpty);
        expect(
          inventory.blockers.single.reason,
          contains('duplicate top-level key'),
        );
      },
    );

    test('scans escaped JSON keys and values before decoding them', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      File(
        p.join(root.path, 'lib', 'l10n', 'app_en.arb'),
      ).writeAsStringSync(r'{"@@locale":"en","slash\\key":"line\nvalue"}');
      File(
        p.join(root.path, 'lib', 'l10n', 'app_vi.arb'),
      ).writeAsStringSync(r'{"@@locale":"vi","slash\\key":"dong\ngia tri"}');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final inventory = ArbInventory.read(project, config);

      expect(inventory.keys.single.key, 'slash\\key');
      expect(inventory.blockers, isEmpty);
    });

    test(
      'blocks duplicate decoded keys that use distinct JSON escapes',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync(
          r'{"@@locale":"en","slash\\key":"first","slash\u005Ckey":"second"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys, isEmpty);
        expect(
          inventory.blockers.single.reason,
          contains('duplicate top-level key'),
        );
      },
    );

    test(
      'blocks non-string messages and malformed placeholder metadata',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync(
          '''
{
  "@@locale": "en",
  "valid": "Valid",
  "badValue": 2,
  "broken": "Broken {name}",
  "@broken": {"placeholders": {"name": "not a map"}}
}
''',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys.map((key) => key.key), ['valid']);
        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          containsAll([
            contains('message badValue must have a string value'),
            contains(
              'metadata placeholders for broken must map names to objects',
            ),
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
      },
    );

    test(
      'blocks locale-only keys without expanding the template inventory',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_vi.arb')).writeAsStringSync(
          '''
{"@@locale":"vi","welcome":"Chao mung","greeting":"Xin chao {name}","extra":"Them"}
''',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys.map((key) => key.key), [
          'cartItem',
          'greeting',
          'welcome',
        ]);
        expect(
          inventory.blockers.single.reason,
          contains('locale-only message key'),
        );
      },
    );

    test(
      'blocks an unsupported locale name instead of guessing its coverage',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_vi.arb')).writeAsStringSync(
          '{"@@locale":"vi-Hant-US-extra","welcome":"Chao mung"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(inventory.keys, hasLength(3));
        expect(
          inventory.blockers.single.reason,
          contains('@@locale must be a non-empty supported locale'),
        );
        expect(inventory.blockers.single.affectedNamespace, isNotNull);
      },
    );

    test(
      'normalizes script locales and blocks filename metadata mismatches',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'app_zh_hant_tw.arb'),
        ).writeAsStringSync(
          '{"@@locale":"zh-Hant-TW","welcome":"Huanying","greeting":"Ni hao {name}"}',
        );
        File(
          p.join(root.path, 'lib', 'l10n', 'app_fr_CA.arb'),
        ).writeAsStringSync(
          '{"@@locale":"fr_FR","welcome":"Bonjour","greeting":"Bonjour {name}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.keys
              .singleWhere((key) => key.key == 'cartItem')
              .missingLocales,
          'vi,zh_Hant_TW',
        );
        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains('ARB filename locale fr_CA differs from @@locale fr_FR'),
        );
      },
    );

    test(
      'blocks non-regular ARB candidates and incompatible inferred placeholders',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        Link(
          p.join(root.path, 'lib', 'l10n', 'app_de.arb'),
        ).createSync(p.join(root.path, 'missing.arb'));
        File(p.join(root.path, 'lib', 'l10n', 'app_vi.arb')).writeAsStringSync(
          '{"@@locale":"vi","welcome":"Chao mung","greeting":"Xin chao {other}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          containsAll([
            contains('not a regular file'),
            contains(
              'locale placeholders for greeting differ from the template',
            ),
          ]),
        );
      },
    );

    test('validates documented placeholder attributes', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync('''
{
  "@@locale":"en",
  "valid":"Valid",
  "badExample":"{name}",
  "@badExample":{"placeholders":{"name":{"example":1}}},
  "badType":"{count}",
  "@badType":{"placeholders":{"count":{"type":""}}},
  "badDate":"{when}",
  "@badDate":{"placeholders":{"when":{"isCustomDateFormat":"maybe"}}},
  "badOptional":"{value}",
  "@badOptional":{"placeholders":{"value":{"optionalParameters":[]}}}
}
''');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final inventory = ArbInventory.read(project, config);

      expect(inventory.keys.map((key) => key.key), ['valid']);
      expect(
        inventory.blockers.map((blocker) => blocker.reason),
        containsAll([
          contains('example for badExample.name'),
          contains('type for badType.count'),
          contains('isCustomDateFormat for badDate.when'),
          contains('optionalParameters for badOptional.value'),
        ]),
      );
    });

    test('validates template filename and @@locale identity too', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      File(
        p.join(root.path, 'lib', 'l10n', 'app_en.arb'),
      ).writeAsStringSync('{"@@locale":"fr","welcome":"Bienvenue"}');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final inventory = ArbInventory.read(project, config);

      expect(
        inventory.blockers.map((blocker) => blocker.reason),
        contains('ARB filename locale en differs from @@locale fr'),
      );
    });

    test(
      'accepts a declared locale from a valid ARB file with a different stem',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'translations.arb'),
        ).writeAsStringSync(
          '{"@@locale":"de","welcome":"Willkommen","greeting":"Hallo {name}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.keys
              .singleWhere((key) => key.key == 'cartItem')
              .missingLocales,
          'de,vi',
        );
        expect(inventory.blockers, isEmpty);
      },
    );

    test(
      'accepts a syntactically valid declared locale outside filename list',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'translations.arb'),
        ).writeAsStringSync(
          '{"@@locale":"haw","welcome":"Aloha","greeting":"Aloha {name}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.keys
              .singleWhere((key) => key.key == 'cartItem')
              .missingLocales,
          'haw,vi',
        );
        expect(inventory.blockers, isEmpty);
      },
    );

    test(
      'uses hyphens only for a whole filename locale, not suffix inference',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'translations-en.arb'),
        ).writeAsStringSync(
          '{"@@locale":"fr","welcome":"Bonjour","greeting":"Bonjour {name}"}',
        );
        File(p.join(root.path, 'lib', 'l10n', 'de-EN.arb')).writeAsStringSync(
          '{"welcome":"Willkommen","greeting":"Hallo {name}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.keys
              .singleWhere((key) => key.key == 'cartItem')
              .missingLocales,
          'de_EN,fr,vi',
        );
        expect(inventory.blockers, isEmpty);
      },
    );

    test(
      'does not let matching locale metadata mask message placeholders',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_vi.arb')).writeAsStringSync(
          '''
{
  "@@locale":"vi",
  "welcome":"Chao mung",
  "greeting":"Xin chao {other}",
  "@greeting":{"placeholders":{"name":{}}}
}
''',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains('locale placeholders for greeting differ from the template'),
        );
      },
    );

    test('rejects null optional parameter values', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync('''
{
  "@@locale":"en",
  "valid":"Valid",
  "bad":"{name}",
  "@bad":{"placeholders":{"name":{"optionalParameters":{"style":null}}}}
}
''');

      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final inventory = ArbInventory.read(project, config);

      expect(inventory.keys.map((key) => key.key), ['valid']);
      expect(
        inventory.blockers.map((blocker) => blocker.reason),
        contains(
          'optionalParameters for bad.name must not contain null values',
        ),
      );
    });

    test(
      'uses the first parsable filename suffix instead of a later match',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'foo_de_en.arb'),
        ).writeAsStringSync(
          '{"@@locale":"en","welcome":"Willkommen","greeting":"Hallo {name}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains('ARB filename locale de_EN differs from @@locale en'),
        );
      },
    );

    test(
      'uses a normalized whole basename before looking at suffixes',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(
          p.join(root.path, 'lib', 'l10n', 'zh_Hant_TW.arb'),
        ).writeAsStringSync(
          '{"welcome":"Huanying","greeting":"Ni hao {name}"}',
        );
        File(p.join(root.path, 'lib', 'l10n', 'de_en.arb')).writeAsStringSync(
          '{"welcome":"Willkommen","greeting":"Hallo {name}"}',
        );
        File(p.join(root.path, 'lib', 'l10n', 'fil_PH.arb')).writeAsStringSync(
          '{"welcome":"Mabuhay","greeting":"Kumusta {name}"}',
        );
        File(
          p.join(root.path, 'lib', 'l10n', 'gsw_CH.arb'),
        ).writeAsStringSync('{"welcome":"Gruezi","greeting":"Hoi {name}"}');

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.keys
              .singleWhere((key) => key.key == 'cartItem')
              .missingLocales,
          'de_EN,fil_PH,gsw_CH,vi,zh_Hant_TW',
        );
        expect(inventory.blockers, isEmpty);
      },
    );

    test(
      'derives template placeholders without metadata and compares locales',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync(
          '{"@@locale":"en","count":"{count, plural, other{{count} items}}"}',
        );
        File(p.join(root.path, 'lib', 'l10n', 'app_vi.arb')).writeAsStringSync(
          '{"@@locale":"vi","count":"{other, plural, other{{other} muc}}"}',
        );

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains('locale placeholders for count differ from the template'),
        );
      },
    );

    test(
      'blocks template metadata that masks its message placeholders',
      () async {
        final root = await _copyFixture();
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'lib', 'l10n', 'app_en.arb')).writeAsStringSync(
          '''
{
  "@@locale":"en",
  "greeting":"Hello {actual}",
  "@greeting":{"placeholders":{"metadata":{}}}
}
''',
        );
        File(
          p.join(root.path, 'lib', 'l10n', 'app_vi.arb'),
        ).writeAsStringSync('{"@@locale":"vi","greeting":"Xin chao {actual}"}');

        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final inventory = ArbInventory.read(project, config);

        expect(
          inventory.blockers.map((blocker) => blocker.reason),
          contains(
            'template placeholders for greeting differ from its metadata',
          ),
        );
      },
    );
  });
}

Future<Directory> _copyFixture() async {
  final source = Directory(p.absolute('test/fixtures/l10n_test'));
  final root = await Directory.systemTemp.createTemp('flutter_pruner_l10n_');
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(root.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
  return root;
}
