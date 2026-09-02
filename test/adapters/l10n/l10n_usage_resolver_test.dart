import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter_profile.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_usage_resolver.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<Directory> _resolverFixture() async {
  final root = await _copyFixture();
  await File(p.join(root.path, 'lib/l10n/app_en.arb')).writeAsString('''
{
  "@@locale": "en",
  "welcome": "Welcome",
  "cartItem": "{count, plural, =0{No items} other{{count} items}}",
  "selection": "{gender, select, female{Female} male{Male} other{Other}}",
  "greeting": "Hello {name}",
  "@greeting": {"placeholders": {"name": {"type": "String"}}}
}
''');
  await File(p.join(root.path, 'lib/l10n/app_vi.arb')).writeAsString('''
{
  "@@locale": "vi",
  "welcome": "Chao mung",
  "greeting": "Xin chao {name}",
  "selection": "{gender, select, female{Female} male{Male} other{Other}}"
}
''');
  return root;
}

void main() {
  group('L10nUsageResolver', () {
    test('resolves semantic generated getter and method consumers', () async {
      final root = await _resolverFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await ProjectContext.load(root);
      final owner = DartPackageOwnership.discover(
        project,
      ).ownerOf(p.join(root.path, 'lib', 'consumer.dart'));
      expect(owner.ownership, DartSourceOwnership.selectedPackage);
      expect(owner.packageName, 'l10n_test');
      expect(
        owner.packageRoot,
        p.normalize(Directory(root.path).resolveSymbolicLinksSync()),
      );
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final inventory = ArbInventory.read(project, config);
      final workspace = DartAnalysisWorkspace(project);
      final resolver = L10nUsageResolver(project, config, inventory);

      await resolver.analyzeProject(workspace: workspace);

      expect(
        inventory.blockers,
        isEmpty,
        reason: inventory.blockers.map((blocker) => blocker.reason).join(', '),
      );
      expect(
        resolver.references.map((reference) => reference.l10nNodeId).toSet(),
        containsAll(<String>[
          'l10n:l10n_test:welcome',
          'l10n:l10n_test:greeting',
          'l10n:l10n_test:cartItem',
          'l10n:l10n_test:selection',
        ]),
      );
      expect(
        resolver.references.map((reference) => reference.callerId),
        everyElement(startsWith('dart:l10n_test/')),
      );
      expect(
        resolver.references.every(
          (reference) =>
              inventory.keys.any((key) => key.nodeId == reference.l10nNodeId),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) => reference.callerId.endsWith('consumer.dart#Localizer'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) =>
              reference.callerId.endsWith('consumer.dart#LocalizationsX'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) =>
              reference.callerId.endsWith('consumer.dart#BareLocalizationsX') &&
              reference.l10nNodeId.endsWith(':welcome'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) =>
              reference.callerId.endsWith(
                'constructor_consumer.dart#ConstructsLocalizations',
              ) &&
              reference.l10nNodeId.endsWith(':welcome'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) =>
              reference.callerId.endsWith('consumer.dart#topLevelWelcome'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) =>
              reference.callerId.endsWith('consumer.dart#throughCascade') &&
              reference.l10nNodeId.endsWith(':greeting'),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) => reference.callerId.endsWith(
            'reexport_consumer.dart#throughExport',
          ),
        ),
        isTrue,
      );
      expect(
        resolver.references.any(
          (reference) => reference.callerId.contains('app_localizations.dart'),
        ),
        isFalse,
      );
      expect(
        resolver.references.where(
          (reference) => reference.callerId.endsWith('other.dart#Other'),
        ),
        isEmpty,
      );
      expect(
        resolver.references.where(
          (reference) =>
              reference.callerId.endsWith('other.dart#unrelatedWelcome'),
        ),
        isEmpty,
      );
      expect(
        resolver.references.where(
          (reference) => reference.callerId.endsWith('other.dart#localWelcome'),
        ),
        isEmpty,
      );
      expect(
        resolver.references.where(
          (reference) =>
              reference.callerId.endsWith('consumer.dart#dynamicReceiver'),
        ),
        isEmpty,
      );
      expect(
        resolver.blockers.any(
          (blocker) =>
              blocker.reason ==
                  'dynamic localization member access cannot be resolved' &&
              blocker.affectedNodeIds.contains('l10n:l10n_test:welcome'),
        ),
        isTrue,
      );
      expect(
        resolver.references.where(
          (reference) => reference.callerId.endsWith(
            'consumer.dart#dynamicMethodReceiver',
          ),
        ),
        isEmpty,
      );
      expect(
        resolver.blockers.any(
          (blocker) =>
              blocker.reason ==
                  'dynamic localization member access cannot be resolved' &&
              blocker.affectedNodeIds.contains('l10n:l10n_test:greeting'),
        ),
        isTrue,
      );
      expect(
        resolver.blockers.any(
          (blocker) =>
              blocker.reason == 'dynamic localization API cannot be resolved' &&
              blocker.affectedNamespace == ArbInventory.namespaceFor(project),
        ),
        isTrue,
      );
      expect(
        resolver.blockers.map((blocker) => blocker.reason),
        contains('custom localization lookup has a dynamic key'),
      );
      expect(
        resolver.references.any(
          (reference) => reference.callerId.contains('custom_lookup.dart'),
        ),
        isFalse,
      );
      expect(
        workspace.resolutionCount,
        lessThanOrEqualTo(workspace.dartFiles.length),
      );
      expect(
        resolver.generatedDartNamespaces,
        containsAll(<String>[
          'dart:l10n_test/lib/l10n/app_localizations.dart',
          'dart:l10n_test/lib/l10n/app_localizations_en.dart',
        ]),
      );
      final firstReferences = resolver.references
          .map((reference) => '${reference.callerId}:${reference.l10nNodeId}')
          .toList(growable: false);
      final resolutions = workspace.resolutionCount;
      await resolver.analyzeProject(workspace: workspace);
      expect(workspace.resolutionCount, resolutions);
      expect(
        resolver.references
            .map((reference) => '${reference.callerId}:${reference.l10nNodeId}')
            .toList(growable: false),
        firstReferences,
      );
    });

    test(
      'ignores qualified and cascade pure writes that match an ARB key',
      () async {
        final root = await _resolverFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(
          p.join(root.path, 'lib/non_l10n_write.dart'),
        ).writeAsString('''
class Product {
  String? welcome;
}

Product qualifiedWrite(Product product) {
  product.welcome = 'qualified';
  return product;
}

Product cascadeWrite() => Product()..welcome = 'cascade';
''');
        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final resolver = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );

        await resolver.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          resolver.references.where(
            (reference) =>
                reference.location.contains('non_l10n_write.dart'),
          ),
          isEmpty,
        );
        expect(
          resolver.blockers.where(
            (blocker) =>
                blocker.reason ==
                    'dynamic localization member access cannot be resolved' &&
                (blocker.location?.contains('non_l10n_write.dart') ?? false),
          ),
          isEmpty,
        );
      },
    );

    test(
      'blocks missing configured output and missing member shapes',
      () async {
        final root = await _resolverFixture();
        addTearDown(() => root.delete(recursive: true));
        final output = File(
          p.join(root.path, 'lib/l10n/app_localizations.dart'),
        );
        await output.delete();
        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final resolver = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );

        await resolver.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(resolver.references, isEmpty);
        expect(
          resolver.blockers.any(
            (blocker) =>
                blocker.affectedNamespace == ArbInventory.namespaceFor(project),
          ),
          isTrue,
        );
        expect(
          resolver.generatedDartNamespaces,
          contains('dart:l10n_test/lib/l10n/app_localizations.dart'),
        );
      },
    );

    test(
      'blocks unconfigured custom key APIs without inferring liveness',
      () async {
        final root = await _resolverFixture();
        addTearDown(() => root.delete(recursive: true));
        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final resolver = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );

        await resolver.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          resolver.references.any(
            (reference) => reference.callerId.contains('custom_lookup.dart'),
          ),
          isFalse,
        );
        expect(
          resolver.blockers.where(
            (blocker) =>
                blocker.reason ==
                'unconfigured custom localization API has a constant ARB key',
          ),
          hasLength(3),
        );
        expect(
          resolver.blockers.any(
            (blocker) =>
                blocker.reason ==
                    'custom localization lookup has a dynamic key' &&
                blocker.affectedNamespace == ArbInventory.namespaceFor(project),
          ),
          isTrue,
        );
        expect(
          resolver.blockers.any(
            (blocker) =>
                blocker.reason ==
                'custom localization lookup names no declared ARB key',
          ),
          isTrue,
        );
      },
    );

    test(
      'blocks missing output class and member shape without dangling uses',
      () async {
        final root = await _resolverFixture();
        addTearDown(() => root.delete(recursive: true));
        final output = File(
          p.join(root.path, 'lib/l10n/app_localizations.dart'),
        );
        final part = File(
          p.join(root.path, 'lib/l10n/app_localizations_en.dart'),
        );
        await part.delete();
        await output.writeAsString('class DifferentLocalizations {}');
        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final missingClass = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );

        await missingClass.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(missingClass.references, isEmpty);
        expect(
          missingClass.blockers.map((blocker) => blocker.reason),
          contains('configured localization output class is missing'),
        );

        await output.writeAsString('''
class AppLocalizations {
  String get welcome => 'Welcome';
  String greeting(String name) => name;
  String cartItem(int count) => '\$count';
}
''');
        final missingMember = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );
        await missingMember.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          missingMember.blockers.where(
            (blocker) =>
                blocker.affectedNodeIds.contains('l10n:l10n_test:selection'),
          ),
          isNotEmpty,
        );

        await output.writeAsString('''
class AppLocalizations {
  String get welcome => 'Welcome';
  String get greeting => 'wrong shape';
  String cartItem(int count) => '\$count';
  String selection(String gender) => gender;
}
''');
        final wrongShape = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );
        await wrongShape.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          wrongShape.blockers.where(
            (blocker) =>
                blocker.affectedNodeIds.contains('l10n:l10n_test:greeting'),
          ),
          isNotEmpty,
        );
        expect(
          wrongShape.references.any(
            (reference) => reference.l10nNodeId.endsWith(':greeting'),
          ),
          isFalse,
        );
      },
    );

    test(
      'blocks generated callers and skips generated output-family self use',
      () async {
        final root = await _resolverFixture();
        addTearDown(() => root.delete(recursive: true));
        await File(
          p.join(root.path, 'lib/generated_consumer.g.dart'),
        ).writeAsString('''
import 'l10n/app_localizations.dart';
String generatedUse(AppLocalizations value) => value.welcome;
''');
        final project = await ProjectContext.load(root);
        final config = (L10nConfig.load(project) as L10nConfigValid).config;
        final resolver = L10nUsageResolver(
          project,
          config,
          ArbInventory.read(project, config),
        );

        await resolver.analyzeProject(
          workspace: DartAnalysisWorkspace(project),
        );

        expect(
          resolver.references.any(
            (reference) =>
                reference.callerId.contains('generated_consumer.g.dart'),
          ),
          isFalse,
        );
        expect(
          resolver.blockers.any(
            (blocker) =>
                blocker.reason.contains('unmodeled or generated Dart source'),
          ),
          isTrue,
        );
        expect(
          resolver.references.any(
            (reference) =>
                reference.callerId.contains('app_localizations_en.dart'),
          ),
          isFalse,
        );
      },
    );
  });

  test(
    'blocks consumer analyzer errors without inventing a safe result',
    () async {
      final root = await _resolverFixture();
      addTearDown(() => root.delete(recursive: true));
      await File(p.join(root.path, 'lib/broken_consumer.dart')).writeAsString(
        '''
import 'l10n/app_localizations.dart';
String broken(AppLocalizations localizations) =>
    localizations.welcome + missingValue;
''',
      );
      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final resolver = L10nUsageResolver(
        project,
        config,
        ArbInventory.read(project, config),
      );

      await resolver.analyzeProject(workspace: DartAnalysisWorkspace(project));

      expect(
        resolver.blockers.any(
          (blocker) =>
              blocker.reason ==
                  'analyzer errors prevent semantic localization usage classification' &&
              blocker.affectedNamespace == ArbInventory.namespaceFor(project),
        ),
        isTrue,
      );
    },
  );

  test('does not promote a non-error analyzer diagnostic to a blocker', () async {
    final root = await _resolverFixture();
    addTearDown(() => root.delete(recursive: true));
    await File(p.join(root.path, 'lib/warned_consumer.dart')).writeAsString('''
import 'l10n/app_localizations.dart';
String warned(AppLocalizations localizations) {
  final unused = localizations;
  return localizations.welcome;
}
''');
    final project = await ProjectContext.load(root);
    final config = (L10nConfig.load(project) as L10nConfigValid).config;
    final resolver = L10nUsageResolver(
      project,
      config,
      ArbInventory.read(project, config),
    );

    await resolver.analyzeProject(workspace: DartAnalysisWorkspace(project));

    expect(
      resolver.blockers.where(
        (blocker) =>
            blocker.reason ==
                'analyzer errors prevent semantic localization usage classification' &&
            (blocker.location?.contains('warned_consumer.dart') ?? false),
      ),
      isEmpty,
    );
  });

  test(
    'does not promote a proven external conditional issue to an app blocker',
    () async {
      final root = await _resolverFixture();
      addTearDown(() => root.delete(recursive: true));
      final external = Directory(p.join(root.path, 'external_pkg'));
      await File(p.join(external.path, 'pubspec.yaml')).create(recursive: true);
      await File(p.join(external.path, 'pubspec.yaml')).writeAsString('''
name: external_pkg
environment:
  sdk: ^3.9.0
''');
      await File(
        p.join(external.path, 'lib', 'external.dart'),
      ).create(recursive: true);
      await File(p.join(external.path, 'lib', 'external.dart')).writeAsString(
        '''
import 'safe.dart' if (dart.library.html) 'web.dart';
void externalEntry() => branchEntry();
''',
      );
      await File(
        p.join(external.path, 'lib', 'safe.dart'),
      ).writeAsString('void branchEntry() {}\n');
      await File(
        p.join(external.path, 'lib', 'web.dart'),
      ).writeAsString('void branchEntry() {}\n');
      await File(p.join(root.path, 'lib', 'main.dart')).writeAsString('''
import 'package:external_pkg/external.dart';
void main() => externalEntry();
''');
      await File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).writeAsString('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_pkg","rootUri":"../external_pkg/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      final project = await ProjectContext.load(root);
      final workspace = DartAnalysisWorkspace(project);
      await const DartAdapter().analyzeWithServices(
        project,
        GraphBuilder(ReachabilityGraph(), 'dart'),
        AdapterServices(dartWorkspace: workspace),
      );
      expect((await workspace.boundedClosureSnapshot()).issues, isNotEmpty);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final resolver = L10nUsageResolver(
        project,
        config,
        ArbInventory.read(project, config),
      );

      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.blockers.map((blocker) => blocker.reason),
        isNot(
          contains(
            'conditional external Dart closure may use configured localization members',
          ),
        ),
      );
    },
  );

  test(
    'does not promote a proven external dynamic call to an app blocker',
    () async {
      final root = await _resolverFixture();
      addTearDown(() => root.delete(recursive: true));
      final external = Directory(p.join(root.path, 'external_pkg'));
      await File(p.join(external.path, 'pubspec.yaml')).create(recursive: true);
      await File(p.join(external.path, 'pubspec.yaml')).writeAsString('''
name: external_pkg
environment:
  sdk: ^3.9.0
''');
      await File(
        p.join(external.path, 'lib', 'external.dart'),
      ).create(recursive: true);
      await File(p.join(external.path, 'lib', 'external.dart')).writeAsString(
        '''
dynamic dependencyValue;
void externalEntry() => dependencyValue.perform();
''',
      );
      await File(p.join(root.path, 'lib', 'main.dart')).writeAsString('''
import 'package:external_pkg/external.dart';
void main() => externalEntry();
''');
      await File(
        p.join(root.path, '.dart_tool', 'package_config.json'),
      ).writeAsString('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_pkg","rootUri":"../external_pkg/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      final project = await ProjectContext.load(root);
      final workspace = DartAnalysisWorkspace(project);
      await const DartAdapter().analyzeWithServices(
        project,
        GraphBuilder(ReachabilityGraph(), 'dart'),
        AdapterServices(dartWorkspace: workspace),
      );
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final resolver = L10nUsageResolver(
        project,
        config,
        ArbInventory.read(project, config),
      );

      await resolver.analyzeProject(workspace: workspace);

      expect(
        resolver.blockers.where(
          (blocker) =>
              blocker.reason == 'dynamic localization API cannot be resolved' &&
              (blocker.location?.contains('external_pkg') ?? false),
        ),
        isEmpty,
      );
    },
  );

  test('bounds execution-selected external worklist selection cost', () async {
    final root = await _resolverFixture();
    addTearDown(() => root.delete(recursive: true));
    final external = Directory(p.join(root.path, 'external_pkg'));
    await File(p.join(external.path, 'pubspec.yaml')).create(recursive: true);
    await File(p.join(external.path, 'pubspec.yaml')).writeAsString('''
name: external_pkg
environment:
  sdk: ^3.9.0
''');
    final imports = <String>[];
    for (var index = 0; index < 16; index++) {
      final name = 'dependency_$index.dart';
      imports.add("import '$name';");
      await File(p.join(external.path, 'lib', name)).create(recursive: true);
      await File(
        p.join(external.path, 'lib', name),
      ).writeAsString('void dependency$index() {}\n');
    }
    await File(p.join(external.path, 'lib', 'external.dart')).writeAsString('''
${imports.join('\n')}
void externalEntry() => dependency0();
''');
    await File(p.join(root.path, 'lib', 'main.dart')).writeAsString('''
import 'package:external_pkg/external.dart';
void main() => externalEntry();
''');
    await File(
      p.join(root.path, '.dart_tool', 'package_config.json'),
    ).writeAsString('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_pkg","rootUri":"../external_pkg/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    final project = await ProjectContext.load(root);
    final profile = DartAdapterProfile();

    await ProjectAnalyzer(
      project: project,
      only: const {'l10n'},
      dartProfile: profile,
    ).analyze();

    final counters = profile.snapshot()['counters']! as Map;
    final admitted = counters['l10nExternalLibrariesAdmitted'] as int;
    final comparisons =
        counters['l10nExternalWorklistSelectionComparisons'] as int;
    expect(admitted, greaterThan(10));
    expect(comparisons, lessThanOrEqualTo(admitted * 2));
  });

  test('does not treat an unrelated local dynamic call as l10n', () async {
    final root = await _resolverFixture();
    addTearDown(() => root.delete(recursive: true));
    await File(
      p.join(root.path, 'lib', 'unrelated_dynamic.dart'),
    ).writeAsString('''
dynamic dependencyValue;
void invokeDependency() => dependencyValue.perform();
''');
    final project = await ProjectContext.load(root);
    final config = (L10nConfig.load(project) as L10nConfigValid).config;
    final resolver = L10nUsageResolver(
      project,
      config,
      ArbInventory.read(project, config),
    );

    await resolver.analyzeProject(workspace: DartAnalysisWorkspace(project));

    expect(
      resolver.blockers.where(
        (blocker) =>
            blocker.reason == 'dynamic localization API cannot be resolved' &&
            (blocker.location?.contains('unrelated_dynamic.dart') ?? false),
      ),
      isEmpty,
    );
    expect(
      resolver.blockers.where(
        (blocker) =>
            blocker.reason == 'dynamic localization API cannot be resolved' &&
            (blocker.location?.contains('consumer.dart') ?? false),
      ),
      isNotEmpty,
    );
  });

  test('blocks a diagnostic configured output class', () async {
    final root = await _resolverFixture();
    addTearDown(() => root.delete(recursive: true));
    await File(
      p.join(root.path, 'lib/l10n/app_localizations.dart'),
    ).writeAsString('''
class AppLocalizations {
  String get welcome => ;
}
''');
    final project = await ProjectContext.load(root);
    final config = (L10nConfig.load(project) as L10nConfigValid).config;
    final resolver = L10nUsageResolver(
      project,
      config,
      ArbInventory.read(project, config),
    );

    await resolver.analyzeProject(workspace: DartAnalysisWorkspace(project));

    expect(resolver.references, isEmpty);
    expect(
      resolver.blockers.map((blocker) => blocker.reason),
      contains(
        'analyzer errors prevent configured localization output resolution',
      ),
    );
  });

  test(
    'recognizes a multi-dot generated output sibling by Flutter filename shape',
    () async {
      final root = await _resolverFixture();
      addTearDown(() => root.delete(recursive: true));
      await File(p.join(root.path, 'l10n.yaml')).writeAsString('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app.localizations.dart
''');
      await File(
        p.join(root.path, 'lib/l10n/app.localizations.dart'),
      ).writeAsString('''
import 'app_en.localizations.dart';

class AppLocalizations {
  String get welcome => 'Welcome';
  String greeting(String name) => name;
  String cartItem(int count) => '\$count';
  String selection(String gender) => gender;
}

final generatedEnglish = AppLocalizationsEn();
''');
      await File(
        p.join(root.path, 'lib/l10n/app_en.localizations.dart'),
      ).writeAsString('''
import 'app.localizations.dart';

class AppLocalizationsEn extends AppLocalizations {}
''');
      final project = await ProjectContext.load(root);
      final config = (L10nConfig.load(project) as L10nConfigValid).config;
      final resolver = L10nUsageResolver(
        project,
        config,
        ArbInventory.read(project, config),
      );

      await resolver.analyzeProject(workspace: DartAnalysisWorkspace(project));

      expect(
        resolver.generatedDartNamespaces,
        containsAll(<String>[
          'dart:l10n_test/lib/l10n/app.localizations.dart',
          'dart:l10n_test/lib/l10n/app_en.localizations.dart',
        ]),
      );
    },
  );
}

Future<Directory> _copyFixture() async {
  final source = Directory(p.absolute('test/fixtures/l10n_test'));
  final root = await Directory.systemTemp.createTemp('l10n_resolver_');
  await for (final entity in source.list(recursive: true)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(root.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
  final packageConfig = File(
    p.join(root.path, '.dart_tool', 'package_config.json'),
  );
  await packageConfig.parent.create(recursive: true);
  await packageConfig.writeAsString('''
{"configVersion":2,"packages":[
  {"name":"l10n_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
  return root;
}
