import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:test/test.dart';

/// A no-op adapter used to exercise selection and ordering.
class _FakeAdapter extends AnalyzerAdapter {
  const _FakeAdapter(
    this.id, {
    this.dependsOn = const [],
    this.findingNodeSchemesOverride,
    this.definition,
    bool applies = true,
  }) : _applies = applies;

  @override
  final String id;

  @override
  final List<String> dependsOn;

  final Set<String>? findingNodeSchemesOverride;
  final AdapterReportDefinition? definition;
  final bool _applies;

  @override
  String get name => 'fake $id';

  @override
  Set<String> get findingNodeSchemes =>
      findingNodeSchemesOverride ?? super.findingNodeSchemes;

  @override
  AdapterReportDefinition get reportDefinition =>
      definition ?? super.reportDefinition;

  @override
  bool appliesTo(ProjectContext project) => _applies;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {}
}

class _RouteImpersonator extends AnalyzerAdapter {
  const _RouteImpersonator();

  @override
  String get id => 'contributor_routes';

  @override
  String get name => 'Contributor routes';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'contributor_routes',
    displayName: 'Contributor routes',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.route,
        ruleId: 'PRN-ROUTE-001',
        title: 'Unused route',
        nodeLabel: 'Route',
      ),
    ],
  );

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {}
}

List<String> _ids(List<AnalyzerAdapter> adapters) =>
    adapters.map((a) => a.id).toList();

void main() {
  group('selection', () {
    test('resolves all adapters when unfiltered', () {
      final resolved = AdapterRegistry.resolve(
        adapters: const [_FakeAdapter('a'), _FakeAdapter('b')],
      );

      expect(_ids(resolved), equals(['a', 'b']));
    });

    test('only restricts to the named ids', () {
      final resolved = AdapterRegistry.resolve(
        only: {'b'},
        adapters: const [_FakeAdapter('a'), _FakeAdapter('b')],
      );

      expect(_ids(resolved), equals(['b']));
    });

    test('exclude drops the named ids', () {
      final resolved = AdapterRegistry.resolve(
        exclude: {'a'},
        adapters: const [_FakeAdapter('a'), _FakeAdapter('b')],
      );

      expect(_ids(resolved), equals(['b']));
    });

    test('exclude wins over only for the same id', () {
      final resolved = AdapterRegistry.resolve(
        only: {'a'},
        exclude: {'a'},
        adapters: const [_FakeAdapter('a')],
      );

      expect(resolved, isEmpty);
    });

    test(
      'rejects an unknown requested adapter rather than silently scanning nothing',
      () {
        expect(
          () => AdapterRegistry.resolve(
            only: {'nonexistent'},
            adapters: const [_FakeAdapter('a')],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              contains('nonexistent'),
            ),
          ),
        );
      },
    );

    test('builtIn contains every shipped adapter', () {
      // Phase 1A: AssetAdapter
      // Phase 1B: DuplicateAdapter, DartAdapter
      expect(AdapterRegistry.builtIn, hasLength(4));
      expect(
        AdapterRegistry.builtIn.map((a) => a.id).toList(),
        equals(['assets', 'duplicates', 'dart', 'go_router']),
      );
    });

    test('builtIn cannot be mutated by an exported caller', () {
      final builtIn = AdapterRegistry.builtIn;

      expect(
        () => builtIn.add(const _FakeAdapter('contributor')),
        throwsUnsupportedError,
      );
      expect(() => builtIn.clear(), throwsUnsupportedError);
      expect(
        () => builtIn[0] = const _FakeAdapter('replacement'),
        throwsUnsupportedError,
      );
      expect(
        AdapterRegistry.builtIn.map((adapter) => adapter.id),
        orderedEquals(['assets', 'duplicates', 'dart', 'go_router']),
      );
    });

    test('built-ins expose complete, stable report definitions', () {
      final definitions = {
        for (final adapter in AdapterRegistry.builtIn)
          adapter.id: adapter.reportDefinition,
      };

      expect(
        definitions.keys,
        containsAll(['assets', 'duplicates', 'dart', 'go_router']),
      );
      expect(
        definitions['assets']!.findingFor(NodeKind.asset)!.ruleId,
        'PRN-ASSET-001',
      );
      expect(
        definitions['duplicates']!
            .findingFor(NodeKind.duplicateGroup)!
            .measurementKind,
        'duplicate-potential-reclaimable-bytes',
      );
      expect(
        definitions['dart']!.findingFor(NodeKind.declaration)!.ruleId,
        'PRN-DART-001',
      );
      expect(
        definitions['go_router']!.findingFor(NodeKind.route)!.ruleId,
        'PRN-ROUTE-001',
      );
      expect(
        definitions.values.every(
          (definition) => definition.description.isNotEmpty,
        ),
        isTrue,
      );
    });

    test(
      'a contributor receives a valid empty presentation catalog by default',
      () {
        const adapter = _FakeAdapter('contributor');

        final definition = adapter.reportDefinition;
        expect(definition.adapterId, 'contributor');
        expect(definition.displayName, 'fake contributor');
        expect(definition.findings, isEmpty);
        expect(definition.measurements, isEmpty);
        expect(
          AdapterRegistry.resolve(adapters: const [adapter]).single,
          same(adapter),
        );
      },
    );

    test('detail keys are scoped to each finding definition', () {
      final definition = AdapterReportDefinition(
        adapterId: 'catalog',
        displayName: 'Catalog analyzer',
        findings: [
          AdapterFindingReportDefinition(
            nodeKind: NodeKind.route,
            ruleId: 'PRN-CATALOG-001',
            title: 'Unused route',
            nodeLabel: 'Route',
            details: [
              AdapterReportDetailDefinition(
                key: 'sourcePath',
                label: 'Route source',
                valueType: AdapterReportDetailValueType.path,
              ),
            ],
          ),
          AdapterFindingReportDefinition(
            nodeKind: NodeKind.localizationKey,
            ruleId: 'PRN-CATALOG-002',
            title: 'Unused localization key',
            nodeLabel: 'Localization key',
            details: [
              AdapterReportDetailDefinition(
                key: 'sourcePath',
                label: 'Localization source',
                valueType: AdapterReportDetailValueType.path,
              ),
            ],
          ),
        ],
      );

      expect(() => definition.validate(), returnsNormally);
    });
  });

  group('ordering', () {
    test('go_router resolves after its dart dependency', () {
      expect(
        AdapterRegistry.resolve(
          only: {'go_router', 'dart'},
        ).map((adapter) => adapter.id),
        equals(['dart', 'go_router']),
      );
      expect(
        () => AdapterRegistry.resolve(only: {'go_router'}),
        throwsA(isA<StateError>()),
      );
    });

    test('a dependency runs before its dependent', () {
      final resolved = AdapterRegistry.resolve(
        adapters: const [
          _FakeAdapter('dependent', dependsOn: ['base']),
          _FakeAdapter('base'),
        ],
      );

      expect(_ids(resolved), equals(['base', 'dependent']));
    });

    test('a transitive chain is fully ordered', () {
      final resolved = AdapterRegistry.resolve(
        adapters: const [
          _FakeAdapter('c', dependsOn: ['b']),
          _FakeAdapter('b', dependsOn: ['a']),
          _FakeAdapter('a'),
        ],
      );

      expect(_ids(resolved), equals(['a', 'b', 'c']));
    });

    test('a diamond emits each adapter exactly once', () {
      final resolved = AdapterRegistry.resolve(
        adapters: const [
          _FakeAdapter('top', dependsOn: ['left', 'right']),
          _FakeAdapter('left', dependsOn: ['base']),
          _FakeAdapter('right', dependsOn: ['base']),
          _FakeAdapter('base'),
        ],
      );

      expect(resolved, hasLength(4));
      expect(_ids(resolved).indexOf('base'), 0);
      expect(_ids(resolved).last, 'top');
    });

    test('independent adapters keep registration order', () {
      final resolved = AdapterRegistry.resolve(
        adapters: const [
          _FakeAdapter('x'),
          _FakeAdapter('y'),
          _FakeAdapter('z'),
        ],
      );

      expect(_ids(resolved), equals(['x', 'y', 'z']));
    });
  });

  group('failure modes', () {
    test('a contributor cannot claim the route rule', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: [const _RouteImpersonator(), ...AdapterRegistry.builtIn],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects a contributor impersonating a reserved adapter id', () {
      expect(
        () => AdapterRegistry.resolve(adapters: const [_FakeAdapter('dart')]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('reserved for the core'),
          ),
        ),
      );
    });

    test('rejects a contributor claiming a reserved core rule id', () {
      final adapter = _FakeAdapter(
        'routes',
        definition: AdapterReportDefinition(
          adapterId: 'routes',
          displayName: 'fake routes',
          findings: [
            AdapterFindingReportDefinition(
              nodeKind: NodeKind.route,
              ruleId: 'PRN-DART-001',
              title: 'Pretend Dart rule',
              nodeLabel: 'Route',
            ),
          ],
        ),
      );

      expect(
        () => AdapterRegistry.resolve(adapters: [adapter]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('reserved for adapter "dart"'),
          ),
        ),
      );
    });

    test('rejects a report definition owned by a different adapter', () {
      final adapter = _FakeAdapter(
        'routes',
        definition: AdapterReportDefinition(
          adapterId: 'other',
          displayName: 'fake routes',
        ),
      );

      expect(
        () => AdapterRegistry.resolve(adapters: [adapter]),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('does not match'),
          ),
        ),
      );
    });

    test('rejects duplicate adapter ids before resolving dependencies', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: const [_FakeAdapter('same'), _FakeAdapter('same')],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Duplicate adapter id'),
          ),
        ),
      );
    });

    test('rejects two adapters claiming the same finding node scheme', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: [
            _FakeAdapter('first', findingNodeSchemesOverride: {'shared'}),
            _FakeAdapter('second', findingNodeSchemesOverride: {'shared'}),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Finding node scheme "shared"'),
          ),
        ),
      );
    });

    test('rejects two adapters claiming the same report rule id', () {
      const duplicateRule = 'PRN-CUSTOM-001';
      expect(
        () => AdapterRegistry.resolve(
          adapters: [
            _FakeAdapter(
              'first',
              definition: AdapterReportDefinition(
                adapterId: 'first',
                displayName: 'fake first',
                findings: [
                  AdapterFindingReportDefinition(
                    nodeKind: NodeKind.route,
                    ruleId: duplicateRule,
                    title: 'First route',
                    nodeLabel: 'Route',
                  ),
                ],
              ),
            ),
            _FakeAdapter(
              'second',
              definition: AdapterReportDefinition(
                adapterId: 'second',
                displayName: 'fake second',
                findings: [
                  AdapterFindingReportDefinition(
                    nodeKind: NodeKind.localizationKey,
                    ruleId: duplicateRule,
                    title: 'Second key',
                    nodeLabel: 'Key',
                  ),
                ],
              ),
            ),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Rule id "PRN-CUSTOM-001"'),
          ),
        ),
      );
    });

    test('a dependency cycle throws with the path in the message', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: const [
            _FakeAdapter('a', dependsOn: ['b']),
            _FakeAdapter('b', dependsOn: ['a']),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('cycle'), contains('a'), contains('b')),
          ),
        ),
      );
    });

    test('a self-dependency is a cycle', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: const [
            _FakeAdapter('a', dependsOn: ['a']),
          ],
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('an unknown dependency throws rather than running incomplete', () {
      expect(
        () => AdapterRegistry.resolve(
          adapters: const [
            _FakeAdapter('a', dependsOn: ['missing']),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing'),
          ),
        ),
      );
    });

    test('excluding a needed dependency is reported clearly', () {
      // Silently running the dependent without its dependency would produce
      // wrong findings, so this must fail loudly.
      expect(
        () => AdapterRegistry.resolve(
          exclude: {'base'},
          adapters: const [
            _FakeAdapter('dependent', dependsOn: ['base']),
            _FakeAdapter('base'),
          ],
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('excluded'),
          ),
        ),
      );
    });
  });
}
