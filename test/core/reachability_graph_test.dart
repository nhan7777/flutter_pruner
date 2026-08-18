import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

/// Builds a node with the boilerplate filled in.
GraphNode _node(String id, {NodeKind kind = NodeKind.declaration}) =>
    GraphNode(id: id, kind: kind, origin: Uri.parse('file:///$id'));

Evidence _evidence({bool exact = true}) => Evidence(
  kind: EvidenceKind.semanticReference,
  producer: 'test',
  description: 'test edge',
  exact: exact,
);

GraphEdge _edge(
  String from,
  String to, {
  EdgeKind kind = EdgeKind.references,
  BuildCondition condition = BuildCondition.unconditional,
}) => GraphEdge(
  from: from,
  to: to,
  kind: kind,
  evidence: _evidence(),
  condition: condition,
);

final BuildTarget _android = BuildTarget(
  name: 'android',
  platform: 'android',
  entrypoint: 'lib/main.dart',
);

final BuildTarget _web = BuildTarget(
  name: 'web',
  platform: 'web',
  entrypoint: 'lib/main.dart',
);

void main() {
  group('node registration', () {
    test('adding the same id twice keeps one node', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('a'));

      expect(graph.nodeCount, 1);
    });

    test('nodesOfKind filters by kind', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('asset:logo', kind: NodeKind.asset))
        ..addNode(_node('dart:main', kind: NodeKind.declaration));

      expect(
        graph.nodesOfKind(NodeKind.asset).map((n) => n.id),
        equals(['asset:logo']),
      );
    });

    test('duplicate edges collapse', () {
      final graph = ReachabilityGraph()
        ..addEdge(_edge('a', 'b'))
        ..addEdge(_edge('a', 'b'));

      expect(graph.edgeCount, 1);
    });

    test(
      'conflicting duplicate definitions are order-independent and blocked',
      () {
        final declaration = GraphNode(
          id: 'shared',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///lib/shared.dart'),
          metadata: const {'removalSupported': true, 'protection': 'none'},
        );
        final asset = GraphNode(
          id: 'shared',
          kind: NodeKind.asset,
          origin: Uri.parse('file:///assets/shared.png'),
          metadata: const {'removalSupported': false, 'protection': 'keep'},
        );

        final declarationFirst = ReachabilityGraph()
          ..addNode(declaration, producer: 'dart')
          ..addNode(asset, producer: 'assets');
        final assetFirst = ReachabilityGraph()
          ..addNode(asset, producer: 'assets')
          ..addNode(declaration, producer: 'dart');

        // The canonical stored node and the fail-closed blocker do not depend on
        // the order in which adapters happened to run.
        expect(declarationFirst.node('shared')!.kind, NodeKind.declaration);
        expect(assetFirst.node('shared')!.kind, NodeKind.declaration);
        expect(
          declarationFirst.node('shared')!.origin,
          Uri.parse('file:///lib/shared.dart'),
        );
        expect(assetFirst.node('shared')!.metadata, const {
          'removalSupported': true,
          'protection': 'none',
        });

        for (final graph in [declarationFirst, assetFirst]) {
          final blockers = graph.blockersFor('shared');
          expect(blockers, hasLength(1));
          expect(blockers.single.producer, 'graph');
          expect(
            blockers.single.reason,
            'conflicting node definition for duplicate id',
          );
        }
      },
    );

    test('metadata-only duplicate conflicts are blocked', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'shared',
            kind: NodeKind.declaration,
            origin: Uri.parse('file:///lib/shared.dart'),
            metadata: const {'removalSupported': true},
          ),
        )
        ..addNode(
          GraphNode(
            id: 'shared',
            kind: NodeKind.declaration,
            origin: Uri.parse('file:///lib/shared.dart'),
            metadata: const {'removalSupported': false},
          ),
        );

      // Action and protection metadata are part of the definition too. A
      // conflict must never be silently treated as a duplicate discovery.
      expect(graph.blockersFor('shared'), hasLength(1));
    });
  });

  group('reachability', () {
    test('follows a transitive chain from a root', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('b'))
        ..addNode(_node('c'))
        ..addEdge(_edge('a', 'b'))
        ..addEdge(_edge('b', 'c'))
        ..addRoot('a', reason: 'entrypoint');

      expect(graph.reachableFor(_android), equals({'a', 'b', 'c'}));
    });

    test('a node with no path from any root is unreachable', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('orphan'))
        ..addRoot('a', reason: 'entrypoint');

      expect(graph.reachableFor(_android), equals({'a'}));
      expect(graph.unreachableAcrossAll([_android]), equals({'orphan'}));
    });

    test('cycles terminate', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('b'))
        ..addEdge(_edge('a', 'b'))
        ..addEdge(_edge('b', 'a'))
        ..addRoot('a', reason: 'entrypoint');

      expect(graph.reachableFor(_android), equals({'a', 'b'}));
    });

    test('edges are directed, so a referrer is not reached via its target', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('caller'))
        ..addNode(_node('callee'))
        ..addEdge(_edge('caller', 'callee'))
        ..addRoot('callee', reason: 'only the callee is a root');

      expect(graph.reachableFor(_android), equals({'callee'}));
    });
  });

  group('conditional reachability', () {
    test('an edge only applies to matching platforms', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('web_only'))
        ..addEdge(
          _edge('a', 'web_only', condition: BuildCondition(platforms: {'web'})),
        )
        ..addRoot('a', reason: 'entrypoint');

      expect(graph.reachableFor(_web), contains('web_only'));
      expect(graph.reachableFor(_android), isNot(contains('web_only')));
    });

    test('a node live in any single target is not globally dead', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('web_only'))
        ..addEdge(
          _edge('a', 'web_only', condition: BuildCondition(platforms: {'web'})),
        )
        ..addRoot('a', reason: 'entrypoint');

      // This is the central safety property: unreachable on android alone is
      // not grounds for deletion.
      expect(graph.unreachableAcrossAll([_android]), contains('web_only'));
      expect(
        graph.unreachableAcrossAll([_android, _web]),
        isNot(contains('web_only')),
      );
    });

    test('a dart-define gated edge is dead without the define', () {
      final beta = BuildTarget(
        name: 'beta',
        platform: 'android',
        entrypoint: 'lib/main.dart',
        dartDefines: {'ENABLE_BETA': 'true'},
      );

      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addNode(_node('beta_feature'))
        ..addEdge(
          _edge(
            'a',
            'beta_feature',
            condition: BuildCondition(dartDefines: {'ENABLE_BETA': 'true'}),
          ),
        )
        ..addRoot('a', reason: 'entrypoint');

      expect(graph.reachableFor(beta), contains('beta_feature'));
      expect(graph.reachableFor(_android), isNot(contains('beta_feature')));
      expect(
        graph.unreachableAcrossAll([_android, beta]),
        isNot(contains('beta_feature')),
      );
    });

    test('a conditional root only seeds matching targets', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('web_entry'))
        ..addRoot(
          'web_entry',
          reason: 'web entrypoint',
          condition: BuildCondition(platforms: {'web'}),
        );

      expect(graph.reachableFor(_web), equals({'web_entry'}));
      expect(graph.reachableFor(_android), isEmpty);
    });

    test('one node retains multiple conditional roots with OR semantics', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('shared'))
        ..addRoot(
          'shared',
          reason: 'web entrypoint',
          condition: BuildCondition(platforms: {'web'}),
        )
        ..addRoot(
          'shared',
          reason: 'android entrypoint',
          condition: BuildCondition(platforms: {'android'}),
        );

      expect(graph.reachableFor(_web), contains('shared'));
      expect(graph.reachableFor(_android), contains('shared'));
    });

    test('reachableForAll rejects duplicate target names', () {
      final graph = ReachabilityGraph()..addNode(_node('a'));

      expect(
        () => graph.reachableForAll([
          _android,
          BuildTarget(
            name: 'android',
            platform: 'web',
            entrypoint: 'lib/main.dart',
          ),
        ]),
        throwsArgumentError,
      );
    });

    test('an empty target list is rejected rather than answered', () {
      final graph = ReachabilityGraph()..addNode(_node('a'));

      // Returning "everything is dead" here would be maximally dangerous and
      // fully confident, so it must throw instead.
      expect(
        () => graph.unreachableAcrossAll(const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('reachableForAll keys results by target name', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addRoot('a', reason: 'entrypoint');

      expect(
        graph.reachableForAll([_android, _web]),
        equals({
          'android': {'a'},
          'web': {'a'},
        }),
      );
    });
  });

  group('protection', () {
    test('protection is independent of reachability', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('public_api'))
        ..protect('public_api', reason: 'public API of a published package');

      expect(graph.isProtected('public_api'), isTrue);
      // Unreferenced and protected at the same time is a valid, reportable
      // state — not a suppressed finding.
      expect(graph.unreachableAcrossAll([_android]), contains('public_api'));
    });

    test('dependencies of a protected node remain reachable', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('framework_entry'))
        ..addNode(_node('helper'))
        ..addEdge(_edge('framework_entry', 'helper'))
        ..protect('framework_entry', reason: 'invoked by a framework');

      expect(
        graph.unreachableAcrossAll([_android]),
        contains('framework_entry'),
      );
      expect(graph.reachableFor(_android), contains('helper'));
    });

    test('multiple protection reasons accumulate', () {
      final graph = ReachabilityGraph()
        ..protect('n', reason: 'first reason')
        ..protect('n', reason: 'second reason');

      expect(graph.protectionReasons('n'), hasLength(2));
    });

    test('an unprotected node reports no reasons', () {
      final graph = ReachabilityGraph()..addNode(_node('n'));

      expect(graph.isProtected('n'), isFalse);
      expect(graph.protectionReasons('n'), isEmpty);
    });
  });

  group('blockers', () {
    test('reports whether a recorded blocker addresses any graph node', () {
      final bound = Blocker(
        producer: 'l10n',
        reason: 'bounded parse issue',
        affectedNamespace: 'l10n:app:',
      );
      final unbound = Blocker(
        producer: 'l10n',
        reason: 'empty inventory parse issue',
        affectedNamespace: 'l10n:empty:',
      );
      final graph = ReachabilityGraph()
        ..addBlocker(bound)
        ..addBlocker(unbound)
        ..addNode(_node('l10n:app:title'));

      expect(graph.blockerAddressesAnyNode(bound), isTrue);
      expect(graph.blockerAddressesAnyNode(unbound), isFalse);
    });

    test('a namespace blocker covers nodes under that namespace only', () {
      final graph = ReachabilityGraph()
        ..addBlocker(
          Blocker(
            producer: 'assets',
            reason: 'interpolated asset path',
            location: 'lib/ui/icon.dart:42',
            affectedNamespace: 'assets/icons/',
          ),
        );

      expect(
        graph.blockersFor('asset:app/assets/icons/home.png'),
        hasLength(1),
      );
      expect(graph.blockersFor('asset:app/assets/photos/hero.jpg'), isEmpty);
    });

    test('a namespace blocker matches only at a path boundary', () {
      final graph = ReachabilityGraph()
        ..addBlocker(
          Blocker(
            producer: 'assets',
            reason: 'interpolated asset path',
            affectedNamespace: 'assets/icons/',
          ),
        );

      expect(graph.blockersFor('asset:app/old_assets/icons/home.png'), isEmpty);
    });

    test('an id-scoped blocker covers only the listed ids', () {
      final graph = ReachabilityGraph()
        ..addBlocker(
          Blocker(
            producer: 'di',
            reason: 'runtime instanceName',
            affectedNodeIds: {'di:app:Api@mock'},
          ),
        );

      expect(graph.blockersFor('di:app:Api@mock'), hasLength(1));
      expect(graph.blockersFor('di:app:Api@real'), isEmpty);
    });

    test('exact duplicate blockers collapse before graph indexing', () {
      final first = Blocker(
        producer: 'dart',
        reason: 'unresolved semantic reference',
        location: 'lib/example.dart',
        affectedNodeIds: {'candidate_b', 'candidate_a'},
      );
      final graph = ReachabilityGraph()
        ..addNode(_node('candidate_a'))
        ..addNode(_node('candidate_b'))
        ..addBlocker(first)
        ..addBlocker(
          Blocker(
            producer: 'dart',
            reason: 'unresolved semantic reference',
            location: 'lib/example.dart',
            affectedNodeIds: {'candidate_a', 'candidate_b'},
          ),
        );

      expect(graph.blockers, [same(first)]);
      expect(graph.blockersFor('candidate_a'), [same(first)]);
      expect(
        graph.retainedFor(_android),
        containsAll({'candidate_a', 'candidate_b'}),
      );
    });

    test('dedup identity cannot confuse node ids containing commas', () {
      final graph = ReachabilityGraph()
        ..addBlocker(
          Blocker(
            producer: 'dart',
            reason: 'unresolved semantic reference',
            affectedNodeIds: {'a,b', 'c'},
          ),
        )
        ..addBlocker(
          Blocker(
            producer: 'dart',
            reason: 'unresolved semantic reference',
            affectedNodeIds: {'a', 'b,c'},
          ),
        );

      expect(graph.blockers, hasLength(2));
    });

    test('snapshots id scope before caller mutation', () {
      final affectedNodeIds = <String>{'blocked_candidate'};
      final blocker = Blocker(
        producer: 'test',
        reason: 'dynamic lookup',
        affectedNodeIds: affectedNodeIds,
      );
      final graph = ReachabilityGraph()
        ..addNode(_node('blocked_candidate'))
        ..addBlocker(blocker);

      affectedNodeIds.clear();

      expect(blocker.affectedNodeIds, {'blocked_candidate'});
      expect(() => blocker.affectedNodeIds.clear(), throwsUnsupportedError);
      expect(graph.blockersFor('blocked_candidate'), [same(blocker)]);
      expect(graph.retainedFor(_android), contains('blocked_candidate'));
    });

    test('public collection views cannot mutate graph safety state', () {
      final edge = _edge('source', 'blocked_candidate');
      final graph = ReachabilityGraph()
        ..addNode(_node('source'))
        ..addNode(_node('blocked_candidate'))
        ..addEdge(edge)
        ..addBlocker(
          Blocker(
            producer: 'test',
            reason: 'dynamic lookup',
            affectedNodeIds: {'blocked_candidate'},
          ),
        );

      expect(
        () => (graph.blockers as List<Blocker>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (graph.edges as Set<GraphEdge>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (graph.outgoingFrom('source') as Set<GraphEdge>).clear(),
        throwsUnsupportedError,
      );
      expect(graph.blockersFor('blocked_candidate'), hasLength(1));
      expect(graph.edges, contains(edge));
      expect(graph.outgoingFrom('source'), contains(edge));
    });

    test('an unscoped blocker covers everything', () {
      final graph = ReachabilityGraph()
        ..addBlocker(
          Blocker(producer: 'x', reason: 'could not parse a source file'),
        );

      // Deliberately fail loud rather than fail silent: an author who forgets
      // to scope a blocker must notice, not silently get zero protection.
      expect(graph.blockersFor('anything:at:all'), hasLength(1));
    });

    test('blockers do not affect reachability', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addRoot('a', reason: 'entrypoint')
        ..addBlocker(Blocker(producer: 'x', reason: 'unresolved'));

      expect(graph.reachableFor(_android), equals({'a'}));
    });

    test('dependencies of a blocked node remain reachable', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('generated_model'))
        ..addNode(_node('base_entity'))
        ..addEdge(_edge('generated_model', 'base_entity'))
        ..addBlocker(
          Blocker(
            producer: 'dart',
            reason: 'generated code retains this declaration',
            affectedNodeIds: {'generated_model'},
          ),
        );

      expect(
        graph.unreachableAcrossAll([_android]),
        contains('generated_model'),
      );
      expect(graph.reachableFor(_android), contains('base_entity'));
    });

    test('blocker retention reaches a fixed point independent of order', () {
      ReachabilityGraph build({required bool downstreamFirst}) {
        final retainsGenerated = Blocker(
          producer: 'dart',
          reason: 'generated code retains this declaration',
          affectedNodeIds: {'generated_model'},
        );
        final dynamicAsset = Blocker(
          producer: 'assets',
          reason: 'dynamic asset path',
          sourceNodeId: 'generated_model',
          affectedNamespace: 'asset:app/assets/runtime/',
        );
        final graph = ReachabilityGraph()
          ..addNode(_node('generated_model'))
          ..addNode(_node('asset:app/assets/runtime/icon.png'));
        if (downstreamFirst) {
          graph
            ..addBlocker(dynamicAsset)
            ..addBlocker(retainsGenerated);
        } else {
          graph
            ..addBlocker(retainsGenerated)
            ..addBlocker(dynamicAsset);
        }
        return graph;
      }

      for (final graph in [
        build(downstreamFirst: true),
        build(downstreamFirst: false),
      ]) {
        expect(
          graph.retainedFor(_android),
          containsAll({'generated_model', 'asset:app/assets/runtime/icon.png'}),
        );
      }
    });

    test('blocker sourced only from a removable node stays inactive', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('dead_source'))
        ..addNode(_node('blocked_candidate'))
        ..addNode(_node('candidate_dependency'))
        ..addEdge(_edge('blocked_candidate', 'candidate_dependency'))
        ..addBlocker(
          Blocker(
            producer: 'test',
            reason: 'dynamic lookup in dead source',
            sourceNodeId: 'dead_source',
            affectedNodeIds: {'blocked_candidate'},
          ),
        );

      expect(graph.retainedFor(_android), isEmpty);
      expect(graph.reachableFor(_android), isEmpty);
      expect(
        graph.unreachableAcrossAll([_android]),
        containsAll({
          'dead_source',
          'blocked_candidate',
          'candidate_dependency',
        }),
      );
    });

    test('blocker source retention respects the full build target', () {
      const sourceId = 'dart:app/lib/web.dart#loadDynamicAsset';
      const candidateId = 'asset:app/assets/runtime/web.png';
      final graph = ReachabilityGraph()
        ..addNode(_node(sourceId))
        ..addNode(_node(candidateId, kind: NodeKind.asset))
        ..addRoot(
          sourceId,
          reason: 'web production entry point',
          condition: BuildCondition(
            platforms: {'web'},
            flavors: {'prod'},
            entrypoints: {'lib/web.dart'},
            dartDefines: {'ENV': 'prod'},
          ),
        )
        ..addBlocker(
          Blocker(
            producer: 'assets',
            reason: 'dynamic web asset path',
            sourceNodeId: sourceId,
            affectedNodeIds: {candidateId},
          ),
        );
      final webProd = BuildTarget(
        name: 'web-prod',
        platform: 'web',
        flavor: 'prod',
        entrypoint: 'lib/web.dart',
        dartDefines: {'ENV': 'prod'},
      );
      final webUat = BuildTarget(
        name: 'web-uat',
        platform: 'web',
        flavor: 'uat',
        entrypoint: 'lib/web.dart',
        dartDefines: {'ENV': 'uat'},
      );

      expect(graph.retainedFor(webProd), contains(candidateId));
      expect(graph.retainedFor(webUat), isNot(contains(candidateId)));
    });
  });

  group('diagnostics', () {
    test('danglingEdges reports edges with unregistered endpoints', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('a'))
        ..addEdge(_edge('a', 'never_registered'));

      expect(graph.danglingEdges(), hasLength(1));
    });

    test('danglingRootIdsFor preserves target conditions', () {
      final graph = ReachabilityGraph()
        ..addRoot(
          'missing_web_root',
          reason: 'configured support root',
          condition: BuildCondition(platforms: {'web'}),
        );

      expect(graph.danglingRootIdsFor([_android]), isEmpty);
      expect(graph.danglingRootIdsFor([_web]), ['missing_web_root']);

      graph.addNode(_node('missing_web_root'));
      expect(graph.danglingRootIdsFor([_web]), isEmpty);
    });

    test(
      'an edge added before its endpoints is not dangling once they land',
      () {
        final graph = ReachabilityGraph()
          ..addEdge(_edge('a', 'b'))
          ..addNode(_node('a'))
          ..addNode(_node('b'));

        // Adapters run in arbitrary order, so this must be legal.
        expect(graph.danglingEdges(), isEmpty);
        graph.addRoot('a', reason: 'entrypoint');
        expect(graph.reachableFor(_android), equals({'a', 'b'}));
      },
    );

    test('incomingTo finds referrers', () {
      final graph = ReachabilityGraph()
        ..addEdge(_edge('caller_one', 'target'))
        ..addEdge(_edge('caller_two', 'target'))
        ..addEdge(_edge('caller_one', 'other'));

      expect(graph.incomingTo('target'), hasLength(2));
      expect(graph.outgoingFrom('caller_one'), hasLength(2));
    });

    test('cached target analysis is invalidated by graph mutations', () {
      final graph = ReachabilityGraph()
        ..addNode(_node('root'))
        ..addNode(_node('first'))
        ..addNode(_node('second'))
        ..addRoot('root', reason: 'entrypoint')
        ..addEdge(_edge('root', 'first'));

      expect(graph.reachableFor(_android), equals({'root', 'first'}));
      expect(graph.retainedFor(_android), equals({'root', 'first'}));

      graph.addEdge(_edge('first', 'second'));

      expect(graph.reachableFor(_android), equals({'root', 'first', 'second'}));
      expect(graph.retainedFor(_android), equals({'root', 'first', 'second'}));
    });
  });
}
