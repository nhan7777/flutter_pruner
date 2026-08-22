import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/asset/asset_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/adapters/registry.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AssetAdapter', () {
    Future<AnalysisSnapshot> analyzeExternalClosureFixture({
      required String externalSource,
      required bool referenced,
    }) async {
      final root = await Directory.systemTemp.createTemp(
        'asset_external_closure_test_',
      );
      final externalRoot = await Directory.systemTemp.createTemp(
        'asset_external_package_test_',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => externalRoot.delete(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: asset_owner
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  external_asset_pkg:
    path: ${p.relative(externalRoot.path, from: root.path)}
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/unused.png
''');
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"asset_owner","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_asset_pkg","rootUri":"${externalRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(root.path, '.flutter_pruner', 'config.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
      File(p.join(root.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          referenced
              ? '''
import 'package:external_asset_pkg/external.dart';

void main() => externalEntry();
'''
              : 'void main() {}\n',
        );
      File(p.join(root.path, 'lib', 'internal.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void branchEntry() {}\n');
      File(p.join(root.path, 'assets', 'unused.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('unused');
      File(p.join(externalRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: external_asset_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(externalRoot.path, 'lib', 'external.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(externalSource);
      File(p.join(externalRoot.path, 'lib', 'safe.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void branchEntry() {}\n');

      return ProjectAnalyzer(
        project: await ProjectContext.load(root),
        only: const {'assets'},
      ).analyze();
    }

    Future<AnalysisSnapshot> analyzeSelectedImportFixture({
      required bool conditional,
    }) async {
      final root = await Directory.systemTemp.createTemp(
        'asset_selected_conditional_test_',
      );
      final externalRoot = await Directory.systemTemp.createTemp(
        'asset_selected_conditional_external_',
      );
      final flutterRoot = await Directory.systemTemp.createTemp(
        'asset_selected_conditional_flutter_',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => externalRoot.delete(recursive: true));
      addTearDown(() => flutterRoot.delete(recursive: true));
      File(p.join(root.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: asset_owner
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  external_asset_pkg:
    path: ${p.relative(externalRoot.path, from: root.path)}
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/
''');
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"asset_owner","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_asset_pkg","rootUri":"${externalRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter","rootUri":"${flutterRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(root.path, '.flutter_pruner', 'config.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: web
      platform: web
      entrypoint: lib/main.dart
''');
      File(p.join(root.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          conditional
              ? '''
import 'local_safe.dart'
    if (dart.library.html) 'package:external_asset_pkg/consumer.dart';

void main() => selectedEntry();
'''
              : '''
import 'local_safe.dart';

void main() => selectedEntry();
''',
        );
      File(p.join(root.path, 'lib', 'local_safe.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void selectedEntry() {}\n');
      File(p.join(root.path, 'assets', 'hidden.png'))
        ..createSync(recursive: true)
        ..writeAsStringSync('hidden');
      File(p.join(externalRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: external_asset_pkg
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
''');
      File(p.join(externalRoot.path, 'lib', 'consumer.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
import 'package:flutter/widgets.dart';

void selectedEntry() {
  Image.asset('assets/hidden.png');
}
''');
      File(p.join(flutterRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: flutter
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(flutterRoot.path, 'lib', 'widgets.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
class Image {
  const Image.asset(String path);
}
''');

      final loaded = await ProjectContext.load(root);
      return ProjectAnalyzer(
        project: ProjectContext(
          root: root,
          pubspec: loaded.pubspec,
          packageName: loaded.packageName,
          targets: [
            BuildTarget(
              name: 'web',
              platform: 'web',
              entrypoint: 'lib/main.dart',
            ),
          ],
        ),
        only: const {'assets'},
      ).analyze();
    }

    Future<AnalysisSnapshot> analyzeOwnershipBoundaryFixture({
      required bool referenced,
      required bool conflictingOwnership,
    }) async {
      final root = await Directory.systemTemp.createTemp(
        'asset_ownership_closure_test_',
      );
      final externalRoot = await Directory.systemTemp.createTemp(
        'asset_ownership_closure_external_',
      );
      final flutterRoot = await Directory.systemTemp.createTemp(
        'asset_ownership_closure_flutter_',
      );
      addTearDown(() => root.delete(recursive: true));
      addTearDown(() => externalRoot.delete(recursive: true));
      addTearDown(() => flutterRoot.delete(recursive: true));
      final assetName = conflictingOwnership ? 'unknown.png' : 'generated.png';
      final importedPath = conflictingOwnership
          ? 'consumer.dart'
          : 'consumer.g.dart';
      File(p.join(root.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: asset_owner
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  external_asset_pkg:
    path: ${p.relative(externalRoot.path, from: root.path)}
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/
''');
      File(p.join(root.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"asset_owner","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_asset_pkg","rootUri":"${externalRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter","rootUri":"${flutterRoot.absolute.uri}","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(root.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          referenced
              ? '''
import 'package:external_asset_pkg/$importedPath';

void main() => externalEntry();
'''
              : 'void main() {}\n',
        );
      File(p.join(root.path, 'assets', assetName))
        ..createSync(recursive: true)
        ..writeAsStringSync(assetName);
      File(p.join(externalRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: ${conflictingOwnership ? 'actual_asset_pkg' : 'external_asset_pkg'}
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
''');
      if (conflictingOwnership) {
        File(p.join(externalRoot.path, 'lib', importedPath))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:flutter/widgets.dart';

void externalEntry() {
  Image.asset('assets/$assetName');
}
''');
      } else {
        File(p.join(externalRoot.path, 'lib', importedPath))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
export 'consumer.gen.dart';
''');
        File(p.join(externalRoot.path, 'lib', 'consumer.gen.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:flutter/widgets.dart';

// Marks this as FlutterGen-style generated output.
final class AssetGenImage {}

void externalEntry() {
  Image.asset('assets/$assetName');
}
''');
      }
      File(p.join(flutterRoot.path, 'pubspec.yaml'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
name: flutter
publish_to: none
environment:
  sdk: ^3.9.0
''');
      File(p.join(flutterRoot.path, 'lib', 'widgets.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
class Image {
  const Image.asset(String path);
}
''');

      final loaded = await ProjectContext.load(root);
      return ProjectAnalyzer(
        project: ProjectContext(
          root: root,
          pubspec: loaded.pubspec,
          packageName: loaded.packageName,
          targets: [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
        ),
        only: const {'assets'},
      ).analyze();
    }

    test('discovers assets from pubspec.yaml', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();
      final adapter = const AssetAdapter();

      await adapter.analyze(project, GraphBuilder(graph, adapter.id));

      // Should find both used and unused assets
      final assetNodes = graph.nodesOfKind(NodeKind.asset);
      expect(assetNodes.length, greaterThanOrEqualTo(2));

      final usedAsset = graph.node('asset:asset_test/assets/used.png');
      expect(usedAsset, isNotNull);

      final unusedAsset = graph.node('asset:asset_test/assets/unused.png');
      expect(unusedAsset, isNotNull);
    });

    test('resolves exact asset references', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();
      final adapter = const AssetAdapter();

      await adapter.analyze(project, GraphBuilder(graph, adapter.id));

      // Should have edge to used.png
      final usedAssetId = 'asset:asset_test/assets/used.png';
      final incomingEdges = graph.incomingTo(usedAssetId);

      expect(
        incomingEdges,
        isNotEmpty,
        reason: 'used.png should have incoming reference from main.dart',
      );
    });

    test('keeps an asset loaded from a reachable class method alive', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();

      await const AssetAdapter().analyze(
        project,
        GraphBuilder(graph, 'assets'),
      );
      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

      final reachable = graph.reachableFor(project.targets.first);
      expect(reachable, contains('asset:asset_test/assets/used.png'));
    });

    test('models exact asset references as edges instead of roots', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();

      await const AssetAdapter().analyze(
        project,
        GraphBuilder(graph, 'assets'),
      );

      final incoming = graph
          .incomingTo('asset:asset_test/assets/used.png')
          .map((edge) => edge.from)
          .toSet();
      expect(incoming, isNotEmpty);
      expect(
        graph.rootIds,
        isNot(contains('asset:asset_test/assets/used.png')),
      );
    });

    test('scopes blockers for interpolated paths to matching assets', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();
      final adapter = const AssetAdapter();

      await adapter.analyze(project, GraphBuilder(graph, adapter.id));

      // Should have blocker for 'assets/icons/$name.png'
      final blockers = graph.blockers;
      expect(blockers, isNotEmpty);

      final iconBlocker = blockers.firstWhere(
        (b) => b.reason.contains('dynamic pattern'),
        orElse: () => throw StateError('Expected interpolation blocker'),
      );

      expect(iconBlocker.affectedNamespace, isNull);
      expect(
        iconBlocker.affectedNodeIds,
        contains('asset:asset_test/assets/icons/home.png'),
      );
      expect(graph.blockersFor('asset:asset_test/assets/unused.png'), isEmpty);
    });

    test(
      'resolves a used FlutterGen field without generated blockers',
      () async {
        final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
        final project = await ProjectContext.load(fixtureDir);
        final graph = ReachabilityGraph();

        await const AssetAdapter().analyze(
          project,
          GraphBuilder(graph, 'assets'),
        );

        final generatedId = 'asset:asset_test/assets/generated.png';
        expect(graph.incomingTo(generatedId), isNotEmpty);
        expect(graph.blockersFor(generatedId), isEmpty);
        expect(
          graph.blockers.where(
            (blocker) => blocker.reason.contains('loadProducts'),
          ),
          isEmpty,
        );
      },
    );

    test(
      'fails closed for unrecognized asset APIs and FlutterGen mapping drift',
      () async {
        final fixtureDir = Directory(
          p.absolute('test/fixtures/asset_safety_test'),
        );
        final project = await ProjectContext.load(fixtureDir);
        final owner = DartPackageOwnership.discover(
          project,
        ).ownerOf(p.join(fixtureDir.path, 'lib', 'main.dart'));
        expect(
          owner.ownership,
          DartSourceOwnership.selectedPackage,
          reason: owner.reason,
        );
        final graph = ReachabilityGraph();

        await const AssetAdapter().analyze(
          project,
          GraphBuilder(graph, 'assets'),
        );

        final getterDrift = 'asset:asset_safety_test/assets/getter_drift.png';
        final wrapperDrift = 'asset:asset_safety_test/assets/wrapper_drift.png';
        final unknownSink = 'asset:asset_safety_test/assets/unknown_sink.riv';
        final dynamicSink =
            'asset:asset_safety_test/assets/dynamic_unhinted.png';
        final unresolved = 'asset:asset_safety_test/assets/unresolved.png';
        final rawGetter = 'asset:asset_safety_test/assets/raw_getter.png';
        final opaqueVariable =
            'asset:asset_safety_test/assets/opaque_variable.png';
        final nestedPayload =
            'asset:asset_safety_test/assets/nested_payload.mp3';
        final namedPayload = 'asset:asset_safety_test/assets/named_payload.png';

        expect(
          graph.incomingTo(getterDrift),
          isNotEmpty,
          reason: 'a direct FlutterGen getter must retain its declared asset',
        );
        expect(
          graph.incomingTo(wrapperDrift),
          isNotEmpty,
          reason: 'a generated wrapper getter must resolve through its target',
        );
        expect(
          graph.blockersFor(unknownSink),
          isNotEmpty,
          reason: 'an external asset constructor must not be silently ignored',
        );
        expect(
          graph.blockersFor(unresolved),
          isNotEmpty,
          reason: 'an unmapped generated accessor must block asset deletion',
        );
        expect(
          graph.blockersFor(dynamicSink),
          isNotEmpty,
          reason:
              'an unhinted dynamic call must not silently discard its pattern',
        );
        expect(
          graph.blockersFor(rawGetter),
          isNotEmpty,
          reason:
              'a changed FlutterGen getter type must block until it is mapped',
        );
        expect(
          graph.blockers.where(
            (blocker) =>
                blocker.reason ==
                    'asset reference passed to an unrecognized asset-loading API' &&
                blocker.affectedNodeIds.contains(opaqueVariable),
          ),
          isNotEmpty,
          reason:
              'a declared asset passed through a mutable local variable to an '
              'opaque API must retain its provenance',
        );
        expect(
          graph.blockers.where(
            (blocker) => blocker.affectedNodeIds.contains(nestedPayload),
          ),
          isNotEmpty,
          reason:
              'a declared asset nested in an opaque map payload must retain '
              'its provenance',
        );
        expect(
          graph.blockers.where(
            (blocker) => blocker.affectedNodeIds.contains(namedPayload),
          ),
          isNotEmpty,
          reason:
              'a declared asset in an opaque named argument must retain its '
              'provenance',
        );
        expect(
          graph.blockers.any(
            (blocker) => blocker.reason.contains('unrecognized asset-loading'),
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) => blocker.reason.contains('FlutterGen accessor'),
          ),
          isTrue,
        );
      },
    );

    test(
      'retains a dynamic asset blocker sourced from a generated-retained class',
      () async {
        final fixtureDir = Directory(
          p.absolute('test/fixtures/asset_safety_test'),
        );
        final project = await ProjectContext.load(fixtureDir);
        final graph = ReachabilityGraph();

        await const AssetAdapter().analyze(
          project,
          GraphBuilder(graph, 'assets'),
        );
        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));

        final source = graph.nodes.firstWhere(
          (node) => node.id.endsWith('model.dart#GeneratedModel'),
        );
        final sourceBlockers = graph.blockersFor(source.id);
        expect(
          sourceBlockers.any(
            (blocker) => blocker.reason.contains('generated code references'),
          ),
          isTrue,
        );

        const assetId = 'asset:asset_safety_test/assets/generated_dynamic.png';
        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: project,
              graphIntegrity: graph.integrityFor(project.targets),
              reportingNodeSchemes: const {'asset'},
            )
            .singleWhere((candidate) => candidate.node.id == assetId);

        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.noDynamicBlockers, isFalse);
        expect(
          finding.blockers.any(
            (blocker) =>
                blocker.sourceNodeId == source.id &&
                blocker.affectedNamespace == 'asset:asset_safety_test/' &&
                blocker.reason.contains('non-constant'),
          ),
          isTrue,
        );
        expect(finding.proposedAction, isNull);
      },
    );

    test('discovers resolution variants', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final graph = ReachabilityGraph();
      final adapter = const AssetAdapter();

      await adapter.analyze(project, GraphBuilder(graph, adapter.id));

      // Should find 2.0x variant
      final variantNodes = graph.nodesOfKind(NodeKind.assetVariant);
      expect(variantNodes, isNotEmpty);

      final homeIcon2x = graph.node(
        'asset:asset_test/assets/icons/2.0x/home.png',
      );
      expect(homeIcon2x, isNotNull);

      final homeIcon = graph.node('asset:asset_test/assets/icons/home.png');
      expect(homeIcon, isNotNull);
      expect(
        homeIcon!.sizeBytes,
        File.fromUri(homeIcon.origin).lengthSync() +
            File.fromUri(homeIcon2x!.origin).lengthSync(),
      );
      expect(
        homeIcon.metadata['variantPaths'],
        contains(homeIcon2x.origin.toFilePath()),
      );
    });

    test('applies to Flutter packages only', () async {
      final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
      final project = await ProjectContext.load(fixtureDir);
      final adapter = const AssetAdapter();

      expect(adapter.appliesTo(project), isTrue);
    });

    test('is registered in AdapterRegistry', () {
      final adapters = AdapterRegistry.builtIn;
      final assetAdapter = adapters.whereType<AssetAdapter>();

      expect(assetAdapter, isNotEmpty);
    });

    test('requires Dart reachability before classifying assets', () {
      expect(const AssetAdapter().dependsOn, equals(['dart']));
      expect(
        () => AdapterRegistry.resolve(only: {'assets'}),
        throwsA(isA<StateError>()),
      );
      expect(
        AdapterRegistry.resolve(only: {'assets', 'dart'}).map((a) => a.id),
        equals(['dart', 'assets']),
      );
    });

    test(
      'asset-only analysis runs Dart as support without Dart findings',
      () async {
        final fixtureDir = Directory(p.absolute('test/fixtures/asset_test'));
        final project = await ProjectContext.load(fixtureDir);
        final analyzer = ProjectAnalyzer(project: project, only: {'assets'});

        final snapshot = await analyzer.analyze();

        expect(snapshot.adapterIds, equals(['dart', 'assets']));
        expect(
          snapshot.graph.danglingEdges(),
          isEmpty,
          reason: 'generated Dart boundaries are outside the modeled graph',
        );
        expect(snapshot.findings, isNotEmpty);
        expect(
          snapshot.findings.every(
            (finding) => finding.node.kind == NodeKind.asset,
          ),
          isTrue,
        );
        expect(
          snapshot.findings.map((finding) => finding.node.id),
          isNot(contains('asset:asset_test/assets/generated.png')),
        );
        expect(
          snapshot.findings.map((finding) => finding.node.id),
          isNot(contains('asset:asset_test/assets/used.png')),
        );
        final unused = snapshot.findings.singleWhere(
          (finding) => finding.node.id == 'asset:asset_test/assets/unused.png',
        );
        expect(unused.predicates.noDynamicBlockers, isFalse);
        expect(unused.confidence, Confidence.review);
        expect(unused.proposedAction, isNull);
        final incompleteDartBlocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.producer == 'assets' &&
              blocker.reason ==
                  'non-selected Dart source may address selected assets' &&
              blocker.affectedNamespace == 'asset:asset_test/',
        );
        expect(incompleteDartBlocker.sourceNodeId, isNull);
        expect(
          snapshot.adapterRuns.map((run) => '${run.id}:${run.role.name}'),
          ['dart:support', 'assets:reporting'],
        );
      },
    );

    test(
      'generated executable uses artifact provenance for an exact asset edge',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'generated_executable_asset_',
        );
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: generated_asset_owner
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/generated-only.png
''');
        File(p.join(root.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"generated_asset_owner","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter","rootUri":"../flutter_stub/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        File(p.join(root.path, '.flutter_pruner', 'config.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
        File(p.join(root.path, 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void main() {}\n');
        File(p.join(root.path, 'lib', 'generated_only.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('void generatedOnly() {}\n');
        File(p.join(root.path, 'tool', 'launcher.g.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:flutter/widgets.dart';
import '../lib/generated_only.dart';
void main() {
  generatedOnly();
  Image.asset('assets/generated-only.png');
}
''');
        File(p.join(root.path, 'assets', 'generated-only.png'))
          ..createSync(recursive: true)
          ..writeAsStringSync('generated-only');
        File(p.join(root.path, 'flutter_stub', 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('name: flutter\nenvironment:\n  sdk: ^3.9.0\n');
        File(p.join(root.path, 'flutter_stub', 'lib', 'widgets.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
class Image {
  const Image.asset(String path);
}
''');

        final snapshot = await ProjectAnalyzer(
          project: await ProjectContext.load(root),
          only: const {'assets'},
        ).analyze();
        const artifactId =
            'dart-generated:generated_asset_owner/tool/launcher.g.dart';
        const assetId = 'asset:generated_asset_owner/assets/generated-only.png';
        const declarationId =
            'dart:generated_asset_owner/lib/generated_only.dart#generatedOnly';

        expect(
          snapshot.graph.node(artifactId)?.kind,
          NodeKind.generatedArtifact,
        );
        expect(
          snapshot.graph.incomingTo(assetId).map((edge) => edge.from),
          contains(artifactId),
        );
        expect(snapshot.graphIntegrity.danglingEdges, isEmpty);
        expect(snapshot.graphIntegrity.danglingRootIds, isEmpty);
        for (final id in [assetId, declarationId]) {
          final matching = snapshot.findings.where(
            (finding) => finding.node.id == id,
          );
          if (matching.isEmpty) {
            expect(snapshot.graph.node(id), isNotNull);
            continue;
          }
          final finding = matching.single;
          expect(finding.confidence, Confidence.review);
          expect(finding.proposedAction, isNull);
        }
      },
    );

    test(
      'ProjectAnalyzer keeps non-selected asset consumers source-less and blocked',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'asset_ownership_boundary_test_',
        );
        addTearDown(() => root.delete(recursive: true));
        File(p.join(root.path, 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: asset_owner
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
flutter:
  assets:
    - assets/used.png
    - assets/unused.png
''');
        File(p.join(root.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"asset_owner","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_asset_part","rootUri":"../nested_exact/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"conflicting_asset_part","rootUri":"../nested_unknown/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"unreferenced_asset_pkg","rootUri":"../unreferenced/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        File(p.join(root.path, '.flutter_pruner', 'config.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');
        File(p.join(root.path, 'lib', 'main.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
import 'package:external_asset_part/exact.dart';
part 'package:conflicting_asset_part/dynamic.dart';

void main() {}
''');
        File(p.join(root.path, 'assets', 'used.png'))
          ..createSync(recursive: true)
          ..writeAsStringSync('used');
        File(p.join(root.path, 'assets', 'unused.png'))
          ..createSync(recursive: true)
          ..writeAsStringSync('unused');
        File(p.join(root.path, 'nested_exact', 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: external_asset_part
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(root.path, 'nested_exact', 'lib', 'exact.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
abstract final class ExternalAssets {
  static void asset(String path) {}
}

void externalAssetConsumer() {
  ExternalAssets.asset('assets/used.png');
}
''');
        File(p.join(root.path, 'nested_unknown', 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: actual_asset_part
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(root.path, 'nested_unknown', 'lib', 'dynamic.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
part of 'package:asset_owner/main.dart';

void unknownAssetConsumer(String path) {
  Image.asset(path);
}
''');
        File(p.join(root.path, 'unreferenced', 'pubspec.yaml'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
name: unreferenced_asset_pkg
publish_to: none
environment:
  sdk: ^3.9.0
''');
        File(p.join(root.path, 'unreferenced', 'lib', 'unused_consumer.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync('''
void unreferencedAssetConsumer(String path) {
  Image.asset(path);
}
''');
        final project = await ProjectContext.load(root);

        final snapshot = await ProjectAnalyzer(
          project: project,
          only: const {'assets'},
        ).analyze();

        const usedId = 'asset:asset_owner/assets/used.png';
        const unusedId = 'asset:asset_owner/assets/unused.png';
        final exactBlocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
                  'non-selected Dart source can address a selected asset' &&
              blocker.affectedNodeIds.contains(usedId),
        );
        expect(exactBlocker.sourceNodeId, isNull);
        expect(exactBlocker.affectedNamespace, isNull);
        final dynamicBlockers = snapshot.graph.blockers
            .where(
              (blocker) =>
                  blocker.reason ==
                  'non-selected Dart source may address selected assets',
            )
            .toList();
        expect(
          dynamicBlockers,
          hasLength(1),
          reason: snapshot.graph.blockers
              .map((blocker) => '${blocker.producer}: ${blocker.reason}')
              .join('\n'),
        );
        final dynamicBlocker = dynamicBlockers.single;
        expect(dynamicBlocker.sourceNodeId, isNull);
        expect(dynamicBlocker.affectedNamespace, 'asset:asset_owner/');
        expect(
          snapshot.graph.blockers.where(
            (blocker) =>
                blocker.location?.contains('unused_consumer.dart') ?? false,
          ),
          isEmpty,
        );
        expect(snapshot.graph.incomingTo(usedId), isEmpty);
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          isNot(
            anyOf(
              contains(contains('externalAssetConsumer')),
              contains(contains('unknownAssetConsumer')),
            ),
          ),
        );
        final findings = {
          for (final finding in snapshot.findings) finding.node.id: finding,
        };
        for (final id in [usedId, unusedId]) {
          expect(findings[id], isNotNull);
          expect(findings[id]!.confidence, Confidence.review);
          expect(findings[id]!.proposedAction, isNull);
        }
      },
    );

    test(
      'referenced broken external closure blocks the selected asset namespace',
      () async {
        final snapshot = await analyzeExternalClosureFixture(
          referenced: true,
          externalSource: 'void externalEntry( {\n',
        );

        const assetId = 'asset:asset_owner/assets/unused.png';
        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'external Dart closure could not be inspected for asset references',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, 'asset:asset_owner/');
        expect(blocker.affectedNodeIds, isEmpty);
        expect(snapshot.graph.blockersFor(assetId), contains(blocker));
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.review);
        expect(finding.proposedAction, isNull);
      },
    );

    test(
      'selected conditional import blocks assets hidden in a non-host external branch',
      () async {
        final snapshot = await analyzeSelectedImportFixture(conditional: true);

        const assetId = 'asset:asset_owner/assets/hidden.png';
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.noDynamicBlockers, isFalse);
        expect(finding.proposedAction, isNull);
        expect(
          snapshot.findings.where(
            (finding) =>
                finding.confidence == Confidence.safe ||
                finding.confidence == Confidence.high,
          ),
          isEmpty,
        );
        final sourceLessAssetBlockers = snapshot.graph
            .blockersFor(assetId)
            .where((blocker) => blocker.sourceNodeId == null)
            .toList();
        expect(
          sourceLessAssetBlockers,
          hasLength(1),
          reason: sourceLessAssetBlockers
              .map((blocker) => blocker.reason)
              .join('\n'),
        );
        final assetBlocker = sourceLessAssetBlockers.single;
        expect(
          assetBlocker.reason,
          'non-selected Dart source can address a selected asset',
        );
        expect(assetBlocker.sourceNodeId, isNull);
        expect(assetBlocker.affectedNamespace, isNull);
        expect(assetBlocker.affectedNodeIds, {assetId});
        expect(snapshot.graph.blockersFor(assetId), contains(assetBlocker));
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            anyOf(
              contains(
                'conditional selected Dart import/export may address selected assets',
              ),
              contains(
                'conditional Dart imports/exports are not modelled per target',
              ),
            ),
          ),
        );
        expect(snapshot.graph.incomingTo(assetId), isEmpty);
      },
    );

    test(
      'ordinary selected import creates no conditional asset blocker',
      () async {
        final snapshot = await analyzeSelectedImportFixture(conditional: false);

        const assetId = 'asset:asset_owner/assets/hidden.png';
        expect(
          snapshot.graph
              .blockersFor(assetId)
              .where((blocker) => blocker.producer == 'assets'),
          isEmpty,
        );
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            contains(
              'conditional selected Dart import/export may address selected assets',
            ),
          ),
        );
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.safe);
        expect(finding.predicates.noDynamicBlockers, isTrue);
        expect(finding.proposedAction, 'Move to quarantine');
      },
    );

    test(
      'referenced conditional external closure blocks the selected asset namespace',
      () async {
        final snapshot = await analyzeExternalClosureFixture(
          referenced: true,
          externalSource: '''
import 'safe.dart'
    if (dart.library.html) 'package:asset_owner/internal.dart';

void externalEntry() => branchEntry();
''',
        );

        const assetId = 'asset:asset_owner/assets/unused.png';
        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'conditional external Dart closure may address selected assets',
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, 'asset:asset_owner/');
        expect(blocker.affectedNodeIds, isEmpty);
        expect(snapshot.graph.blockersFor(assetId), contains(blocker));
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.review);
        expect(finding.proposedAction, isNull);
      },
    );

    test(
      'unreferenced broken external package creates no asset blocker',
      () async {
        final snapshot = await analyzeExternalClosureFixture(
          referenced: false,
          externalSource: 'void externalEntry( {\n',
        );

        const assetId = 'asset:asset_owner/assets/unused.png';
        expect(
          snapshot.graph
              .blockersFor(assetId)
              .where((blocker) => blocker.producer == 'assets'),
          isEmpty,
        );
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            anyOf(
              contains(
                'external Dart closure could not be inspected for asset references',
              ),
              contains(
                'conditional external Dart closure may address selected assets',
              ),
            ),
          ),
        );
      },
    );

    test(
      'unreferenced conditional external package creates no asset blocker',
      () async {
        final snapshot = await analyzeExternalClosureFixture(
          referenced: false,
          externalSource: '''
import 'safe.dart'
    if (dart.library.html) 'package:asset_owner/internal.dart';
''',
        );

        const assetId = 'asset:asset_owner/assets/unused.png';
        expect(
          snapshot.graph
              .blockersFor(assetId)
              .where((blocker) => blocker.producer == 'assets'),
          isEmpty,
        );
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            contains(
              'conditional external Dart closure may address selected assets',
            ),
          ),
        );
      },
    );

    test(
      'referenced external generated consumer blocks its exact selected asset',
      () async {
        final snapshot = await analyzeOwnershipBoundaryFixture(
          referenced: true,
          conflictingOwnership: false,
        );

        const assetId = 'asset:asset_owner/assets/generated.png';
        final blocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
                  'non-selected Dart source can address a selected asset' &&
              blocker.location?.contains('consumer.gen.dart') == true,
        );
        expect(blocker.sourceNodeId, isNull);
        expect(blocker.affectedNamespace, isNull);
        expect(blocker.affectedNodeIds, {assetId});
        expect(snapshot.graph.incomingTo(assetId), isEmpty);
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          isNot(contains(contains('externalEntry'))),
        );
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.review);
        expect(finding.proposedAction, isNull);
      },
    );

    test(
      'unreferenced external generated consumer creates no asset blocker',
      () async {
        final snapshot = await analyzeOwnershipBoundaryFixture(
          referenced: false,
          conflictingOwnership: false,
        );

        const assetId = 'asset:asset_owner/assets/generated.png';
        expect(
          snapshot.graph
              .blockersFor(assetId)
              .where((blocker) => blocker.producer == 'assets'),
          isEmpty,
        );
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.safe);
        expect(finding.proposedAction, 'Move to quarantine');
      },
    );

    test(
      'referenced unknown ownership boundary blocks the selected asset namespace',
      () async {
        final snapshot = await analyzeOwnershipBoundaryFixture(
          referenced: true,
          conflictingOwnership: true,
        );

        const assetId = 'asset:asset_owner/assets/unknown.png';
        final assetBlocker = snapshot.graph.blockers.singleWhere(
          (blocker) =>
              blocker.reason ==
              'unknown Dart ownership boundary may address selected assets',
        );
        expect(assetBlocker.sourceNodeId, isNull);
        expect(assetBlocker.affectedNamespace, 'asset:asset_owner/');
        expect(assetBlocker.affectedNodeIds, isEmpty);
        expect(snapshot.graph.blockersFor(assetId), contains(assetBlocker));
        expect(
          snapshot.graph.blockers.any(
            (blocker) =>
                blocker.reason == 'Dart ownership boundary is unknown' &&
                blocker.affectedNamespace == 'dart:asset_owner/',
          ),
          isTrue,
        );
        expect(snapshot.graph.incomingTo(assetId), isEmpty);
        expect(
          snapshot.graph.nodes.map((node) => node.id),
          isNot(contains(contains('externalEntry'))),
        );
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.noDynamicBlockers, isFalse);
        expect(finding.proposedAction, isNull);
        expect(
          snapshot.findings.where(
            (finding) =>
                finding.confidence == Confidence.safe ||
                finding.confidence == Confidence.high,
          ),
          isEmpty,
        );
      },
    );

    test(
      'unreferenced unknown ownership package creates no asset blocker',
      () async {
        final snapshot = await analyzeOwnershipBoundaryFixture(
          referenced: false,
          conflictingOwnership: true,
        );

        const assetId = 'asset:asset_owner/assets/unknown.png';
        expect(
          snapshot.graph
              .blockersFor(assetId)
              .where((blocker) => blocker.producer == 'assets'),
          isEmpty,
        );
        expect(
          snapshot.graph.blockers.map((blocker) => blocker.reason),
          isNot(
            contains(
              'unknown Dart ownership boundary may address selected assets',
            ),
          ),
        );
        final finding = snapshot.findings.singleWhere(
          (finding) => finding.node.id == assetId,
        );
        expect(finding.confidence, Confidence.safe);
        expect(finding.proposedAction, 'Move to quarantine');
      },
    );
  });
}
