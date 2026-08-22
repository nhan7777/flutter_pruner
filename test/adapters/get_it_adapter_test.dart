import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_execution_reachability_service.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_ids.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/adapters/get_it/di_inventory.dart';
import 'package:flutter_pruner/src/adapters/get_it/get_it_adapter.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/execution_context_identity.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> _loadCleanFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_adapter_clean_test')),
);

Future<ProjectContext> _loadCompleteCleanFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_adapter_clean_test')),
  targets: [
    BuildTarget(name: 'test', platform: 'android', entrypoint: 'lib/main.dart'),
  ],
);

Future<ProjectContext> _loadNamedFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/get_it_test')));

Future<ProjectContext> _loadGeneratedFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_generated_wiring_test')),
);

Future<ProjectContext> _loadDependsFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_adapter_depends_test')),
);

Future<ProjectContext> _loadResolutionFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_resolution_test')),
);

Future<ProjectContext> _loadFactoryFixture() => ProjectContext.load(
  Directory(p.absolute('test/fixtures/get_it_factory_resolution_test')),
  targets: [
    BuildTarget(name: 'test', platform: 'android', entrypoint: 'lib/main.dart'),
  ],
);

RunReport _reportFor(ProjectContext project, Finding finding) {
  final findings = [finding];
  return RunReport(
    identity: RunIdentity(
      id: 'get-it-domain-details',
      command: RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 18),
      finishedAtUtc: DateTime.utc(2026, 8, 18, 0, 0, 1),
      elapsedMicros: 1,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: project.root.path,
    packageName: project.packageName,
    requestedAdapters: const ['get_it'],
    adapterReportDefinitions: [const GetItAdapter().reportDefinition],
    targetMatrix: project.targetMatrix,
    rootCoverage: project.rootCoverage,
    analysisPasses: [
      AnalysisPassReport(
        id: 'get-it-domain-details-pass',
        purpose: AnalysisPassPurpose.initial,
        elapsedMicros: 1,
        nodeCount: 1,
        edgeCount: 0,
        rootCount: 0,
        recordedBlockerCount: 0,
        danglingEdgeCount: 0,
        integrityByExecutionTarget: {
          for (final target in project.targetMatrix.targets)
            configuredExecutionContextId(
              target.name,
            ): ExecutionTargetIntegrityReport(
              id: configuredExecutionContextId(target.name),
              domain: 'configuredTarget',
              complete: true,
              danglingEdgeCount: 0,
              danglingRootCount: 0,
            ),
        },
        adapterRuns: const [],
        findingStatistics: FindingStatistics.fromFindings(findings),
        blockerStatistics: BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: const {},
        ),
        measurements: const [],
        exclusionPolicyVersion: 1,
        exclusionsByReason: const {},
      ),
    ],
    findings: findings,
    diagnostics: const [],
  );
}

void main() {
  group('GetItAdapter', () {
    test(
      'models exact consumption as resolves edges without DI roots',
      () async {
        final project = await _loadCompleteCleanFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        final registrations = graph
            .nodesOfKind(NodeKind.diRegistration)
            .toList();
        expect(registrations, isNotEmpty);
        final used = registrations.singleWhere(
          (node) => node.metadata['sourceLocation'] == 'lib/main.dart:12:3',
        );
        final unused = registrations.singleWhere(
          (node) => node.metadata['sourceLocation'] == 'lib/main.dart:13:3',
        );

        expect(
          graph.incomingTo(used.id).map((edge) => edge.kind),
          contains(EdgeKind.resolves),
        );
        expect(graph.incomingTo(unused.id), isEmpty);
        expect(graph.rootIds, isNot(contains(used.id)));
        expect(graph.rootIds, isNot(contains(unused.id)));
        expect(
          graph.retainedFor(project.targets.single),
          isNot(contains(unused.id)),
        );
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
        expect(graph.danglingRootIdsFor(project.targets), isEmpty);
      },
    );

    test(
      'keeps complete unused registrations review-only without a DI blocker',
      () async {
        final project = await _loadCompleteCleanFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'di'},
        );
        final unused = findings.singleWhere(
          (finding) =>
              finding.node.metadata['sourceLocation'] == 'lib/main.dart:13:3',
        );

        expect(findings, isNotEmpty);
        expect(project.analysisCoverageComplete, isTrue);
        expect(unused.reportingAdapterId, 'get_it');
        expect(unused.ruleId, 'PRN-DI-001');
        expect(unused.confidence, Confidence.review);
        expect(unused.proposedAction, isNull);
        expect(graph.blockersFor(unused.node.id), isEmpty);
        expect(unused.classificationReasons, const [
          ClassificationReason.unsupportedAction,
          ClassificationReason.nonDeterministicInverse,
        ]);
      },
    );

    test(
      'serializes named GetIt metadata through typed domain details',
      () async {
        final project = await _loadNamedFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );
        final namedNode = graph
            .nodesOfKind(NodeKind.diRegistration)
            .firstWhere((node) => node.metadata['instanceName'] == 'duplicate');
        final namedFinding = (const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'di'},
          adapterReportDefinitions: {
            'get_it': const GetItAdapter().reportDefinition,
          },
        )).firstWhere((finding) => finding.node.id == namedNode.id);
        final report = _reportFor(project, namedFinding);
        final output = jsonDecode(const JsonFormatter().format(report)) as Map;
        final finding = (output['findings'] as List).single as Map;

        expect(finding['details'], containsPair('instanceName', 'duplicate'));
        expect(finding['details'], containsPair('environments', ''));
      },
    );

    test(
      'uses the supplied Dart workspace for all GetIt semantic passes',
      () async {
        final project = await _loadCleanFixture();
        final graph = ReachabilityGraph();
        final workspace = DartAnalysisWorkspace(project);

        await const DartAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'dart'),
          AdapterServices(dartWorkspace: workspace),
        );
        final resolutionCount = workspace.resolutionCount;
        await const GetItAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'get_it'),
          AdapterServices(dartWorkspace: workspace),
        );

        expect(workspace.resolutionCount, resolutionCount);
      },
    );

    test(
      'preserves duplicate occurrences and bounds non-unique dependsOn targets',
      () async {
        final project = await _loadDependsFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        final registrations = graph
            .nodesOfKind(NodeKind.diRegistration)
            .toList();
        final exactDependsOn = graph.edges.where(
          (edge) => edge.kind == EdgeKind.registers,
        );
        final bounded = graph.blockers.where(
          (blocker) => blocker.reason.contains('dependsOn cannot identify'),
        );
        final duplicates = registrations
            .where(
              (node) =>
                  node.metadata['sourceLocation'] == 'lib/main.dart:33:3' ||
                  node.metadata['sourceLocation'] == 'lib/main.dart:34:3',
            )
            .toList();

        expect(
          registrations.map((node) => node.id).toSet(),
          hasLength(registrations.length),
        );
        expect(duplicates.map((node) => node.id).toSet(), hasLength(2));
        expect(
          registrations.map((node) => node.metadata['environments']),
          everyElement(isA<String>()),
        );
        expect(exactDependsOn, hasLength(1));
        expect(bounded, hasLength(2));
        expect(
          bounded.every(
            (blocker) =>
                blocker.sourceNodeId != null &&
                blocker.affectedNodeIds.isNotEmpty,
          ),
          isTrue,
        );
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
        expect(graph.danglingRootIdsFor(project.targets), isEmpty);
      },
    );

    test(
      'keeps full selected-package GetIt analysis independent of target closure',
      () async {
        final project = await ProjectContext.load(
          Directory(p.absolute('test/fixtures/get_it_runtime_test')),
        );
        final graph = ReachabilityGraph();
        final reachability = _ThrowingReachabilityService();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyzeWithServices(
          project,
          GraphBuilder(graph, 'get_it'),
          AdapterServices(
            dartWorkspace: DartAnalysisWorkspace(project),
            dartExecutionReachabilityService: reachability,
          ),
        );

        final blockers = graph.blockers
            .where((blocker) => blocker.producer == 'get_it')
            .toList();
        expect(blockers, isNotEmpty);
        expect(
          blockers.every(
            (blocker) =>
                blocker.affectedNamespace != null ||
                blocker.affectedNodeIds.isNotEmpty,
          ),
          isTrue,
        );
        expect(
          blockers.where(
            (blocker) =>
                blocker.location?.startsWith('lib/unresolved.dart') ?? false,
          ),
          isNotEmpty,
          reason:
              'GetIt intentionally scans unreachable selected-package units',
        );
        expect(reachability.resolveCalls, 0);
      },
    );

    test(
      'adds resolver callers only when Dart contributes their graph nodes',
      () async {
        final project = await _loadResolutionFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        final resolves = graph.edges.where(
          (edge) => edge.kind == EdgeKind.resolves,
        );
        expect(resolves, isNotEmpty);
        expect(resolves.every((edge) => graph.hasNode(edge.from)), isTrue);
        expect(resolves.every((edge) => graph.hasNode(edge.to)), isTrue);
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
      },
    );

    test(
      'attributes factory closures to registrations without setup liveness',
      () async {
        final project = await _loadFactoryFixture();
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        final registrations = graph.nodesOfKind(NodeKind.diRegistration);
        final foo = registrations.singleWhere(
          (node) => node.metadata['sourceLocation'] == 'lib/main.dart:17:3',
        );
        final bar = registrations.singleWhere(
          (node) => node.metadata['sourceLocation'] == 'lib/main.dart:18:3',
        );
        final baz = registrations.singleWhere(
          (node) => node.metadata['sourceLocation'] == 'lib/main.dart:19:3',
        );
        final incoming = graph.incomingTo(foo.id).toList();

        expect(
          incoming
              .where((edge) => edge.kind == EdgeKind.resolves)
              .map((edge) => edge.from),
          containsAll(<String>[bar.id, baz.id]),
        );
        expect(
          incoming.map((edge) => edge.from),
          isNot(
            contains(
              'dart:get_it_factory_resolution_test/lib/main.dart#configure',
            ),
          ),
        );
        expect(graph.rootIds.where((id) => id.startsWith('di:')), isEmpty);
        expect(
          graph.retainedFor(project.targets.single),
          isNot(contains(bar.id)),
        );
        expect(
          graph.retainedFor(project.targets.single),
          isNot(contains(foo.id)),
        );
        expect(graph.danglingEdgesFor(project.targets), isEmpty);
        expect(graph.danglingRootIdsFor(project.targets), isEmpty);
      },
    );

    test(
      'blocks generated GetIt wiring and its exact Dart output namespaces',
      () async {
        final project = await _loadGeneratedFixture();
        final owner = DartPackageOwnership.discover(
          project,
        ).ownerOf(project.resolve('lib/injection.dart'));
        expect(
          owner.ownership,
          DartSourceOwnership.selectedPackage,
          reason: owner.reason,
        );
        final graph = ReachabilityGraph();

        await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
        await const GetItAdapter().analyze(
          project,
          GraphBuilder(graph, 'get_it'),
        );

        expect(
          graph.blockers.any(
            (blocker) =>
                blocker.affectedNamespace == DiInventory.namespaceFor(project),
          ),
          isTrue,
        );
        final generatedLibrary = DartIds.libraryPath(
          project,
          project.resolve('lib/injection.config.dart'),
        );
        final providerLibrary = DartIds.libraryPath(
          project,
          project.resolve('lib/injection.dart'),
        );
        final provider =
            'dart:get_it_generated_wiring_test/lib/injection.dart#FeatureService';
        expect(graph.hasNode(generatedLibrary), isTrue);
        expect(graph.blockersFor(generatedLibrary), isNotEmpty);
        expect(
          graph.outgoingFrom(generatedLibrary).map((edge) => edge.to),
          contains(providerLibrary),
        );
        final generatedDeclaration =
            '$generatedLibrary#configureGeneratedDependencies';
        expect(graph.blockersFor(generatedDeclaration), isNotEmpty);
        expect(
          graph.outgoingFrom(generatedDeclaration).map((edge) => edge.to),
          contains(provider),
        );
        expect(graph.retainedFor(project.targets.single), contains(provider));

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: graph.integrityFor(project.targets),
          reportingNodeSchemes: const {'dart'},
        );
        final generatedFindings = findings.where(
          (finding) => finding.node.id.startsWith(generatedLibrary),
        );
        expect(generatedFindings, isNotEmpty);
        expect(
          generatedFindings.every(
            (finding) =>
                finding.confidence != Confidence.safe &&
                finding.confidence != Confidence.high &&
                finding.proposedAction == null,
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) =>
                blocker.affectedNamespace ==
                'dart:get_it_generated_wiring_test/lib/injection.config.dart',
          ),
          isTrue,
        );
        expect(
          graph.blockers.any(
            (blocker) =>
                blocker.affectedNamespace ==
                'dart:get_it_generated_wiring_test/lib/z.config.dart',
          ),
          isTrue,
        );
      },
    );

    test(
      'has a complete report contract and applies only to direct GetIt projects',
      () async {
        final project = await _loadCleanFixture();

        expect(const GetItAdapter().id, 'get_it');
        expect(const GetItAdapter().findingNodeSchemes, const {'di'});
        expect(const GetItAdapter().dependsOn, const ['dart']);
        expect(const GetItAdapter().appliesTo(project), isTrue);
        expect(const GetItAdapter().reportDefinition.adapterId, 'get_it');
        expect(
          const GetItAdapter().reportDefinition.findings.single.ruleId,
          'PRN-DI-001',
        );
      },
    );

    test('GetIt-only analysis runs Dart as support end to end', () async {
      final project = await _loadCompleteCleanFixture();

      final snapshot = await ProjectAnalyzer(
        project: project,
        only: {'get_it'},
      ).analyze();

      expect(snapshot.adapterIds, ['dart', 'get_it']);
      expect(snapshot.graph.danglingEdgesFor(project.targets), isEmpty);
      expect(snapshot.graph.danglingRootIdsFor(project.targets), isEmpty);
      expect(snapshot.findings, isNotEmpty);
      expect(
        snapshot.findings.every(
          (finding) =>
              finding.node.kind == NodeKind.diRegistration &&
              finding.reportingAdapterId == 'get_it',
        ),
        isTrue,
      );
      expect(snapshot.adapterRuns.map((run) => '${run.id}:${run.role.name}'), [
        'dart:support',
        'get_it:reporting',
      ]);
    });
  });
}

final class _ThrowingReachabilityService
    implements DartExecutionReachabilityService {
  int resolveCalls = 0;

  @override
  Future<DartExecutionReachabilitySnapshot> resolve(
    ProjectContext project,
  ) async {
    resolveCalls++;
    throw StateError('GetIt must not consume target-specific reachability');
  }
}
