import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_static_readiness_resolver.dart';
import 'package:flutter_pruner/src/core/confidence/action_readiness_index.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  late Directory project;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('l10n-resolver-test-');
    project = Directory(p.join(scratch.path, 'test_project'));
    project.createSync(recursive: true);
    _setupMinimalProject(project);
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('L10nStaticReadinessResolver', () {
    test('package mode returns empty index', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.package);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('no sdk registry returns empty index', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: null,
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('toolchain not resolved returns empty index', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: false),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('config rejected returns empty index', () async {
      // Remove pubspec to trigger config rejection
      File(p.join(project.path, 'pubspec.yaml')).deleteSync();

      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, isEmpty);
    });

    test('application mode creates entries for l10n nodes', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
        _createNode('l10n:app_localizations/farewell'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, hasLength(2));
      expect(index['l10n:app_localizations/greeting'], isNotNull);
      expect(index['l10n:app_localizations/farewell'], isNotNull);
    });

    test('entries have correct adapter and node kind', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.adapterId, equals('l10n'));
      expect(entry.nodeKind, equals(NodeKind.localizationKey));
    });

    test('entries have family ID from node ID', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.familyId, equals('app_localizations'));
    });

    test('entries have proven deterministic inverse', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.inverseKind, equals(DeterministicInverseKind.proven));
    });

    test('entries have bounded family risk scope', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.riskScope, equals(ActionRiskScope.boundedFamily));
    });

    test('application mode has no external exposure', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.hasExternalConsumerExposure, isFalse);
    });

    test('package-internal mode has external exposure', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.packageInternal);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(entry.hasExternalConsumerExposure, isTrue);
    });

    test('scoped blocker present skips node', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting', hasBlocker: true),
        _createNode('l10n:app_localizations/farewell'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      // Both nodes skipped because one has blocker (family-level check)
      expect(index.entries, isEmpty);
    });

    test('multiple families create separate entries', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
        _createNode('l10n:other_localizations/hello'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, hasLength(2));

      final entry1 = index['l10n:app_localizations/greeting']!;
      expect(entry1.familyId, equals('app_localizations'));

      final entry2 = index['l10n:other_localizations/hello']!;
      expect(entry2.familyId, equals('other_localizations'));
    });

    test('non-l10n nodes ignored', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
        GraphNode(
          id: 'dart:lib/main.dart/MyClass',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///test/lib/main.dart'),
          metadata: const {},
        ),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      expect(index.entries, hasLength(1));
      expect(index['l10n:app_localizations/greeting'], isNotNull);
    });

    test('mutation footprint includes finding IDs', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
        _createNode('l10n:app_localizations/farewell'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(
        entry.mutationFootprint.findingIds,
        containsAll([
          'l10n:app_localizations/greeting',
          'l10n:app_localizations/farewell',
        ]),
      );
    });

    test('mutation footprint includes physical paths', () async {
      final resolver = L10nStaticReadinessResolver(
        configLoader: const DefaultL10nGenerationConfigLoader(),
        toolchainResolver: _MockToolchainResolver(resolved: true),
        sdkRegistry: _MockSdkRegistry(),
      );

      final graph = _createGraph([
        _createNode('l10n:app_localizations/greeting'),
      ]);
      final projectContext = _createProject(project, mode: AnalysisMode.application);
      final integrity = _createIntegrity();

      final index = await resolver.resolve(
        graph: graph,
        project: projectContext,
        integrity: integrity,
      );

      final entry = index['l10n:app_localizations/greeting']!;
      expect(
        entry.mutationFootprint.physicalPaths,
        containsAll([
          'lib/l10n/app_en.arb',
          'lib/l10n/app_localizations.dart',
        ]),
      );
    });
  });
}

// Test helpers

GraphNode _createNode(String nodeId, {bool hasBlocker = false}) {
  return GraphNode(
    id: nodeId,
    kind: NodeKind.localizationKey,
    origin: Uri.parse('file:///test/lib/l10n/app_en.arb'),
    metadata: hasBlocker
        ? {
            'scopedBlockers': ['test-blocker']
          }
        : const {},
  );
}

ReachabilityGraph _createGraph(List<GraphNode> nodes) {
  final graph = ReachabilityGraph();
  for (final node in nodes) {
    graph.addNode(node);
  }
  return graph;
}

GraphIntegrity _createIntegrity() {
  return GraphIntegrity(
    configuredTargets: const {},
    byExecutionTarget: const {},
    unattributedDanglingEdges: const {},
    unattributedDanglingRootIds: const {},
    auxiliaryRegistryIssues: const [],
  );
}

// Mock implementations

final class _MockToolchainResolver implements L10nToolchainResolver {
  const _MockToolchainResolver({required this.resolved});

  final bool resolved;

  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) async {
    if (!resolved) {
      return const L10nToolchainRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          stage: 'test',
          detailCode: 'mock-rejection',
        ),
      );
    }

    return L10nToolchainResolved(
      canonicalFlutterExecutable: '/mock/flutter',
      canonicalSdkRoot: '/mock/sdk',
      launch: const L10nToolchainLaunch(
        canonicalDartExecutable: '/mock/dart',
        canonicalFlutterToolsPackageConfig: '/mock/.dart_tool/package_config.json',
        canonicalFlutterToolsSnapshot: '/mock/flutter_tools.snapshot',
      ),
      selection: const ProjectSelectorSelection(),
      generationArgs: const ['gen-l10n'],
      directProbeArgs: const ['--version', '--machine'],
      environmentOverrides: const {},
      selectorHashesByRelativePath: const {},
      machineIdentity: FlutterMachineIdentity(
        frameworkVersion: Version.parse('3.44.1'),
        frameworkRevision: 'abc123',
        engineRevision: 'def456',
        dartSdkVersion: '3.5.0',
      ),
      originalSelectionProbeSha256: 'a' * 64,
      identitySha256: 'b' * 64,
    );
  }

  @override
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  }) async {
    return L10nToolchainStillMatches(expected.identitySha256);
  }
}

L10nSdkRegistry _MockSdkRegistry() {
  return L10nSdkRegistry({
    Version.parse('3.44.1'): '/mock/sdk/flutter',
  });
}

void _setupMinimalProject(Directory project) {
  // Create pubspec.yaml with generate: true
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: test_app
environment:
  sdk: '>=3.0.0 <4.0.0'
flutter:
  generate: true
''');

  // Create l10n.yaml with minimal config
  File(p.join(project.path, 'l10n.yaml')).writeAsStringSync('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
''');

  // Create ARB directory and template file
  final arbDir = Directory(p.join(project.path, 'lib/l10n'))
    ..createSync(recursive: true);
  File(p.join(arbDir.path, 'app_en.arb')).writeAsStringSync('''
{
  "@@locale": "en",
  "greeting": "Hello",
  "farewell": "Goodbye"
}
''');
}

ProjectContext _createProject(Directory projectDir, {required AnalysisMode mode}) {
  return ProjectContext(
    root: projectDir,
    pubspec: const {'name': 'test_app'},
    packageName: 'test_app',
    analysisMode: mode,
    targets: const [],
  );
}

