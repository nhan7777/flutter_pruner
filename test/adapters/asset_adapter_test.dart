import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/asset/asset_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/registry.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('AssetAdapter', () {
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
        expect(unused.predicates.noDynamicBlockers, isTrue);
        expect(
          snapshot.adapterRuns.map((run) => '${run.id}:${run.role.name}'),
          ['dart:support', 'assets:reporting'],
        );
      },
    );
  });
}
