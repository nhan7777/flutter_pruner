import 'dart:io';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/graph/root.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('FindingGenerator', () {
    test('G3 finding generation is graph-read-only after integrity', () {
      final target = _target('android');
      final auxiliary = AuxiliaryExecutionTarget(
        id: 'aux:test:test/support_test.dart:vm',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {
          'dart.library.io': 'true',
          'dart.library.html': 'false',
        },
        environmentComplete: true,
        reason: 'VM test',
      );
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/test/support_test.dart#main',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/test/support_test.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/conditional.dart#usedInTest',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/conditional.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/unused.dart#unused',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/unused.dart'),
          ),
        )
        ..addAuxiliaryRoot(
          'dart:app/test/support_test.dart#main',
          reason: 'test entry point',
          executionTarget: auxiliary,
        )
        ..addEdge(
          GraphEdge(
            from: 'dart:app/test/support_test.dart#main',
            to: 'dart:app/lib/conditional.dart#usedInTest',
            kind: EdgeKind.references,
            evidence: const Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'conditional test reference',
              exact: true,
            ),
            condition: BuildCondition(platforms: {'android'}),
          ),
        );

      final integrity = graph.integrityFor([target]);
      final roots = graph.rootRecords.toList();
      final edges = graph.edges.toSet();
      final blockers = graph.blockers.toList();

      expect(blockers, hasLength(1));
      const FindingGenerator().generate(
        graph: graph,
        project: _mockProject(targets: [target]),
        graphIntegrity: integrity,
      );

      expect(graph.rootRecords, roots);
      expect(graph.edges, edges);
      expect(graph.blockers, blockers);
      expect(identical(graph.integrityFor([target]), integrity), isTrue);
    });

    test('G3 consumes the supplied aggregate integrity snapshot', () {
      final target = BuildTarget(
        name: 'default',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      );
      final auxiliary = AuxiliaryExecutionTarget(
        id: 'aux:runtime:vm-callback',
        domain: AuxiliaryExecutionDomain.runtime,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'VM callback',
        sourceConfiguredTarget: target,
      );
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/unused.dart#unused',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/unused.dart'),
          ),
        )
        ..addAuxiliaryRoot(
          'missing_callback',
          reason: 'runtime callback',
          executionTarget: auxiliary,
        );
      final integrity = graph.integrityFor([target]);

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(targets: [target]),
            graphIntegrity: integrity,
          )
          .single;

      expect(integrity.complete, isFalse);
      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.noDynamicBlockers, isFalse);
      expect(
        finding.classificationReasons,
        contains(ClassificationReason.incompleteGraphIntegrity),
      );
    });

    test('G3 rejects integrity computed for a different full target tuple', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/unused.dart#unused',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/unused.dart'),
          ),
        );
      final intended = BuildTarget(
        name: 'default',
        platform: 'android',
        flavor: 'prod',
        entrypoint: 'lib/main.dart',
        dartDefines: const {'MODE': 'prod'},
      );
      final drifted = BuildTarget(
        name: 'default',
        platform: 'android',
        flavor: 'staging',
        entrypoint: 'lib/main.dart',
        dartDefines: const {'MODE': 'staging'},
      );

      expect(
        () => const FindingGenerator().generate(
          graph: graph,
          project: _mockProject(targets: [intended]),
          graphIntegrity: graph.integrityFor([drifted]),
        ),
        throwsStateError,
      );
    });

    test('G4 reports configured retained-only nodes as REVIEW', () {
      final target = _target('android');
      const rootId = 'dart:app/lib/main.dart#main';
      const candidateId = 'dart:app/lib/retained.dart#retained';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: rootId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/retained.dart'),
          ),
        )
        ..addRoot(rootId, reason: 'configured entry point')
        ..addEdge(
          const GraphEdge(
            from: rootId,
            to: candidateId,
            kind: EdgeKind.references,
            evidence: Evidence(
              kind: EvidenceKind.symbolicPattern,
              producer: 'dart',
              description: 'unresolved configured reference',
            ),
          ),
        );
      final integrity = graph.integrityFor([target]);

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(targets: [target]),
            graphIntegrity: integrity,
          )
          .single;

      expect(finding.node.id, candidateId);
      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.unreachableAcrossAllTargets, isTrue);
      expect(finding.predicates.notRetained, isFalse);
      expect(finding.reachableIn, isEmpty);
      expect(finding.unreachableIn, ['default']);
      expect(finding.retainedIn, ['default']);
      expect(finding.auxiliaryRetainedIn, isEmpty);
      expect(
        finding.classificationReasons,
        contains(ClassificationReason.retainedOnly),
      );
      expect(finding.proposedAction, isNull);
      expect(identical(graph.integrityFor([target]), integrity), isTrue);
    });

    test('G4 reports auxiliary retained-only nodes as REVIEW', () {
      final target = _target('android');
      final runtime = AuxiliaryExecutionTarget(
        id: 'aux:runtime:background-callback',
        domain: AuxiliaryExecutionDomain.runtime,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'background callback',
      );
      const rootId = 'dart:app/lib/background.dart#entry';
      const candidateId = 'dart:app/lib/background.dart#retained';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: rootId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/background.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/background.dart'),
          ),
        )
        ..addAuxiliaryRoot(
          rootId,
          reason: 'runtime callback',
          executionTarget: runtime,
        )
        ..addEdge(
          GraphEdge(
            from: rootId,
            to: candidateId,
            kind: EdgeKind.references,
            condition: BuildCondition.forAuxiliaryTarget(runtime),
            evidence: const Evidence(
              kind: EvidenceKind.symbolicPattern,
              producer: 'dart',
              description: 'unresolved callback reference',
            ),
          ),
        );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(targets: [target]),
            graphIntegrity: graph.integrityFor([target]),
          )
          .single;

      expect(finding.node.id, candidateId);
      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.unreachableAcrossAllTargets, isTrue);
      expect(finding.predicates.notRetained, isFalse);
      expect(finding.retainedIn, isEmpty);
      expect(finding.auxiliaryRetainedIn, [runtime.id]);
      expect(
        finding.classificationReasons,
        contains(ClassificationReason.retainedOnly),
      );
    });

    test('G4 exact configured, test, and external uses suppress findings', () {
      final target = _target('android');
      final testTarget = AuxiliaryExecutionTarget(
        id: 'aux:test:support-test-vm',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {'dart.library.io': 'true'},
        environmentComplete: true,
        reason: 'VM test',
      );
      final externalTarget = AuxiliaryExecutionTarget(
        id: 'aux:external:public-api',
        domain: AuxiliaryExecutionDomain.external,
        environmentValues: const {},
        environmentComplete: true,
        reason: 'public package API',
      );
      const configuredId = 'dart:app/lib/configured.dart#used';
      const testId = 'dart:app/test/support_test.dart#used';
      const publicId = 'dart:app/lib/public_api.dart#PublicApi';
      const unusedId = 'dart:app/lib/unused.dart#unused';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: configuredId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/configured.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: testId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/test/support_test.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: publicId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/public_api.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: unusedId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/unused.dart'),
          ),
        )
        ..addRoot(configuredId, reason: 'configured entry point')
        ..addAuxiliaryRoot(
          testId,
          reason: 'test entry point',
          executionTarget: testTarget,
        )
        ..addAuxiliaryRoot(
          publicId,
          reason: 'public package entry point',
          executionTarget: externalTarget,
        );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(targets: [target]),
            graphIntegrity: graph.integrityFor([target]),
          )
          .single;

      expect(finding.node.id, unusedId);
      expect(finding.confidence, Confidence.safe);
      expect(finding.predicates.notRetained, isTrue);
      expect(finding.reachableIn, isEmpty);
      expect(finding.unreachableIn, ['default']);
      expect(finding.retainedIn, isEmpty);
      expect(finding.auxiliaryRetainedIn, isEmpty);
    });

    test('G4 sorts configured and auxiliary retention identities', () {
      final zeta = BuildTarget(
        name: 'zeta',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      );
      final alpha = BuildTarget(
        name: 'alpha',
        platform: 'ios',
        entrypoint: 'lib/main.dart',
      );
      final zetaAuxiliary = AuxiliaryExecutionTarget(
        id: 'aux:test:zeta',
        domain: AuxiliaryExecutionDomain.test,
        environmentValues: const {},
        environmentComplete: true,
        reason: 'zeta test',
      );
      final alphaAuxiliary = AuxiliaryExecutionTarget(
        id: 'aux:runtime:alpha',
        domain: AuxiliaryExecutionDomain.runtime,
        environmentValues: const {},
        environmentComplete: true,
        reason: 'alpha runtime',
      );
      const candidateId = 'dart:app/lib/retained.dart#retained';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/retained.dart'),
          ),
        )
        ..addAuxiliaryExecutionTarget(zetaAuxiliary)
        ..addAuxiliaryExecutionTarget(alphaAuxiliary)
        ..protect(candidateId, reason: 'retention canary');

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(targets: [zeta, alpha]),
            graphIntegrity: graph.integrityFor([zeta, alpha]),
          )
          .single;

      expect(finding.confidence, Confidence.protected);
      expect(finding.unreachableIn, ['alpha', 'zeta']);
      expect(finding.reachableIn, isEmpty);
      expect(finding.retainedIn, ['alpha', 'zeta']);
      expect(finding.auxiliaryRetainedIn, [
        'aux:runtime:alpha',
        'aux:test:zeta',
      ]);
      expect(finding.predicates.notRetained, isFalse);
    });

    test('G4 retention blocks the package-internal HIGH path', () {
      const rootId = 'dart:app/lib/main.dart#main';
      const candidateId = 'dart:app/lib/public_api.dart#PublicApi';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: rootId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/public_api.dart'),
            metadata: const {'externallyAddressable': true},
          ),
        )
        ..addRoot(rootId, reason: 'configured entry point')
        ..addEdge(
          const GraphEdge(
            from: rootId,
            to: candidateId,
            kind: EdgeKind.references,
            evidence: Evidence(
              kind: EvidenceKind.symbolicPattern,
              producer: 'dart',
              description: 'unresolved generated consumer',
            ),
          ),
        );
      final project = _mockProject(
        analysisMode: AnalysisMode.packageInternal,
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.packageInternal,
          internalBoundaryComplete: true,
          externalConsumersCovered: false,
          source: 'test',
        ),
      );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: project,
            graphIntegrity: graph.integrityFor(project.targets),
          )
          .single;

      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.noPublicApiRisk, isFalse);
      expect(finding.predicates.notRetained, isFalse);
      expect(finding.proposedAction, isNull);
    });

    test('generates SAFE finding for unreachable node with no blockers', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/src/unused.dart#unusedFunction',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/src/unused.dart'),
        ),
      );

      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/main.dart#main',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/main.dart'),
        ),
      );

      graph.addRoot('dart:app/lib/main.dart#main', reason: 'entry point');

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      expect(findings, hasLength(1));
      expect(findings.first.confidence, Confidence.safe);
      expect(findings.first.predicates.allHold, isTrue);
    });

    test(
      'custom presentation changes only finding wire copy, not the verdict',
      () {
        final node = GraphNode(
          id: 'routes:app:/orphan',
          kind: NodeKind.route,
          origin: Uri.file('/project/lib/routes.dart'),
          displayName: '/orphan',
          metadata: const {'sharedDetail': 7},
        );
        final graph = ReachabilityGraph()..addNode(node, producer: 'routes');
        final generator = const FindingGenerator();

        final baseline = generator
            .generate(
              graph: graph,
              project: _mockProject(),
              graphIntegrity: _integrity(graph),
            )
            .single;
        final custom = generator
            .generate(
              graph: graph,
              project: _mockProject(),
              graphIntegrity: _integrity(graph),
              adapterReportDefinitions: {
                'routes': AdapterReportDefinition(
                  adapterId: 'routes',
                  displayName: 'Route catalog',
                  findings: [
                    AdapterFindingReportDefinition(
                      nodeKind: NodeKind.route,
                      ruleId: 'PRN-ROUTE-001',
                      title: 'Unlinked destination',
                      nodeLabel: 'Destination',
                      details: [
                        AdapterReportDetailDefinition(
                          key: 'sharedDetail',
                          label: 'Route count',
                          valueType: AdapterReportDetailValueType.integer,
                        ),
                      ],
                    ),
                  ],
                ),
              },
            )
            .single;

        expect(custom.ruleId, 'PRN-ROUTE-001');
        expect(custom.title, 'Unlinked destination: /orphan');
        expect(custom.reportingAdapterId, 'routes');
        expect(custom.confidence, baseline.confidence);
        expect(custom.predicates.allHold, baseline.predicates.allHold);
        expect(
          custom.classificationReasons.map((reason) => reason.code),
          baseline.classificationReasons.map((reason) => reason.code),
        );
        expect(custom.proposedAction, baseline.proposedAction);
      },
    );

    test('changing a built-in report rule cannot change core capability', () {
      final node = GraphNode(
        id: 'dart:app/lib/src/unused.dart#unusedFunction',
        kind: NodeKind.declaration,
        origin: Uri.file('/project/lib/src/unused.dart'),
        displayName: 'unusedFunction',
      );
      final graph = ReachabilityGraph()..addNode(node, producer: 'dart');
      final generator = const FindingGenerator();

      final baseline = generator
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
          )
          .single;
      final relabeled = generator
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
            adapterReportDefinitions: {
              'dart': AdapterReportDefinition(
                adapterId: 'dart',
                displayName: 'Relabeled Dart catalog',
                findings: [
                  AdapterFindingReportDefinition(
                    nodeKind: NodeKind.declaration,
                    ruleId: 'PRN-CUSTOM-999',
                    title: 'Relabeled finding',
                    nodeLabel: 'Relabeled declaration',
                  ),
                ],
              ),
            },
          )
          .single;

      expect(baseline.confidence, Confidence.safe);
      expect(relabeled.ruleId, 'PRN-CUSTOM-999');
      expect(relabeled.title, 'Relabeled finding: unusedFunction');
      expect(relabeled.confidence, baseline.confidence);
      expect(relabeled.predicates.allHold, baseline.predicates.allHold);
      expect(
        relabeled.predicates.failedPredicates,
        baseline.predicates.failedPredicates,
      );
      expect(relabeled.proposedAction, baseline.proposedAction);
    });

    test('a custom adapter cannot borrow the Dart declaration apply rule', () {
      final node = GraphNode(
        id: 'routes:app/lib/src/route_callback.dart#orphan',
        kind: NodeKind.declaration,
        origin: Uri.file('/project/lib/src/route_callback.dart'),
      );
      final graph = ReachabilityGraph()..addNode(node, producer: 'routes');

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
            adapterReportDefinitions: {
              'routes': AdapterReportDefinition(
                adapterId: 'routes',
                displayName: 'Route catalog',
                findings: [
                  AdapterFindingReportDefinition(
                    nodeKind: NodeKind.declaration,
                    ruleId: 'PRN-DART-001',
                    title: 'Pretend Dart finding',
                    nodeLabel: 'Pretend declaration',
                  ),
                ],
              ),
            },
          )
          .single;

      expect(finding.ruleId, 'PRN-DART-001');
      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.actionSupported, isFalse);
      expect(finding.predicates.ruleAllowsAutoFix, isFalse);
      expect(finding.proposedAction, isNull);
      expect(
        finding.classificationReasons,
        contains(ClassificationReason.unsupportedAction),
      );
    });

    test(
      'dangling graph facts fail closed before planning actionable units',
      () {
        const nodeId = 'dart:app/lib/src/unused.dart#unusedFunction';
        final graph = ReachabilityGraph()
          ..addNode(
            GraphNode(
              id: nodeId,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/src/unused.dart'),
            ),
          )
          ..addEdge(
            const GraphEdge(
              from: 'dart:app/lib/src/missing.dart#caller',
              to: nodeId,
              kind: EdgeKind.references,
              evidence: Evidence(
                kind: EvidenceKind.semanticReference,
                producer: 'dart',
                description: 'reference from a missing graph node',
                exact: true,
              ),
            ),
          );

        final project = _mockProject();
        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: _integrity(graph),
        );
        final finding = findings.single;
        final plan = const RemovalPlanner().build(
          findings: findings,
          graph: graph,
          project: project,
        );

        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.noDynamicBlockers, isFalse);
        expect(
          finding.classificationReasons,
          contains(ClassificationReason.incompleteGraphIntegrity),
        );
        expect(plan.units, isEmpty);
        expect(plan.blocked, isEmpty);
      },
    );

    test('an unrelated dangling target downgrades every candidate', () {
      const sourceId = 'dart:app/lib/main.dart#main';
      const candidateId = 'dart:app/lib/src/unused.dart#unusedFunction';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: sourceId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
          producer: 'dart',
        )
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/unused.dart'),
          ),
          producer: 'dart',
        )
        ..addRoot(sourceId, reason: 'entry point')
        ..addEdge(
          const GraphEdge(
            from: sourceId,
            to: 'dart:app/lib/src/unused.dart#misspelledFunction',
            kind: EdgeKind.references,
            evidence: Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'reference to an unresolved graph node',
              exact: true,
            ),
          ),
        );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
          )
          .single;

      expect(finding.node.id, candidateId);
      expect(finding.confidence, Confidence.review);
      expect(finding.predicates.noDynamicBlockers, isFalse);
      expect(
        finding.classificationReasons,
        contains(ClassificationReason.incompleteGraphIntegrity),
      );
    });

    test('G3 fails closed for a dangling edge with no registered context', () {
      const sourceId = 'dart:app/lib/main.dart#main';
      const candidateId = 'dart:app/lib/src/unused.dart#unusedFunction';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: sourceId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/unused.dart'),
          ),
        )
        ..addRoot(sourceId, reason: 'entry point')
        ..addEdge(
          GraphEdge(
            from: sourceId,
            to: 'dart:app/lib/src/unused.dart#misspelledFunction',
            kind: EdgeKind.references,
            condition: BuildCondition(platforms: {'web'}),
            evidence: Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'web-only unresolved graph node',
              exact: true,
            ),
          ),
        );

      final androidFinding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
          )
          .single;
      final webFinding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            targets: [
              BuildTarget(
                name: 'web',
                platform: 'web',
                entrypoint: 'lib/main.dart',
              ),
            ],
            graphIntegrity: _integrity(graph, [_target('web')]),
          )
          .single;

      expect(androidFinding.confidence, Confidence.review);
      expect(androidFinding.predicates.noDynamicBlockers, isFalse);
      expect(webFinding.confidence, Confidence.review);
      expect(webFinding.predicates.noDynamicBlockers, isFalse);
    });

    test(
      'downgrades an incomplete target override even when its slice is dead',
      () {
        final androidTarget = BuildTarget(
          name: 'android',
          platform: 'android',
          entrypoint: 'lib/main_android.dart',
        );
        final webTarget = BuildTarget(
          name: 'web',
          platform: 'web',
          entrypoint: 'lib/main_web.dart',
        );
        const androidRoot = 'dart:app/lib/main_android.dart#main';
        const webRoot = 'dart:app/lib/main_web.dart#main';
        const candidateId = 'dart:app/lib/src/web_only.dart#webOnly';
        final graph = ReachabilityGraph()
          ..addNode(
            GraphNode(
              id: androidRoot,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/main_android.dart'),
            ),
          )
          ..addNode(
            GraphNode(
              id: webRoot,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/main_web.dart'),
            ),
          )
          ..addNode(
            GraphNode(
              id: candidateId,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/src/web_only.dart'),
            ),
          )
          ..addRoot(
            androidRoot,
            reason: 'android entry point',
            condition: BuildCondition(platforms: {'android'}),
          )
          ..addRoot(
            webRoot,
            reason: 'web entry point',
            condition: BuildCondition(platforms: {'web'}),
          )
          ..addEdge(
            GraphEdge(
              from: webRoot,
              to: candidateId,
              kind: EdgeKind.references,
              condition: BuildCondition(platforms: {'web'}),
              evidence: Evidence(
                kind: EvidenceKind.semanticReference,
                producer: 'dart',
                description: 'web entrypoint invokes the declaration',
                exact: true,
              ),
            ),
          );
        final project = _mockProject(targets: [androidTarget, webTarget]);

        expect(
          const FindingGenerator().generate(
            graph: graph,
            project: project,
            graphIntegrity: _integrity(graph, project.targets),
          ),
          isEmpty,
        );

        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: project,
              targets: [androidTarget],
              graphIntegrity: _integrity(graph, [androidTarget]),
            )
            .singleWhere((finding) => finding.node.id == candidateId);

        expect(finding.node.id, candidateId);
        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.analysisCoverageComplete, isFalse);
        expect(finding.proposedAction, isNull);
        expect(
          finding.classificationReasons,
          contains(ClassificationReason.incompleteTargetMatrix),
        );
      },
    );

    test('G3 fails closed for an unattributed misspelled root', () {
      const candidateId = 'dart:app/lib/src/unused.dart#unusedFunction';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: candidateId,
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/unused.dart'),
          ),
        )
        ..addRoot(
          'dart:app/lib/support.dart#misspelledContributorRoot',
          reason: 'configured support root',
          condition: BuildCondition(platforms: {'web'}),
        );

      final androidFinding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
          )
          .single;
      final webFinding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            targets: [
              BuildTarget(
                name: 'web',
                platform: 'web',
                entrypoint: 'lib/main.dart',
              ),
            ],
            graphIntegrity: _integrity(graph, [_target('web')]),
          )
          .single;

      expect(androidFinding.confidence, Confidence.review);
      expect(androidFinding.predicates.noDynamicBlockers, isFalse);
      expect(webFinding.confidence, Confidence.review);
      expect(webFinding.predicates.noDynamicBlockers, isFalse);
      expect(
        webFinding.classificationReasons,
        contains(ClassificationReason.incompleteGraphIntegrity),
      );
    });

    test('generates PROTECTED finding for protected node', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/callback.dart#nativeCallback',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/callback.dart'),
        ),
      );

      graph.protect(
        'dart:app/lib/callback.dart#nativeCallback',
        reason: 'invoked by native code',
        producer: 'dart',
      );

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      expect(findings, hasLength(1));
      expect(findings.first.confidence, Confidence.protected);
      expect(
        findings.first.protectionReasons,
        contains('invoked by native code'),
      );
    });

    test('generates REVIEW finding when dynamic blocker exists', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'asset:app/assets/flag.png',
          kind: NodeKind.asset,
          origin: Uri.parse('file:///project/assets/flag.png'),
        ),
      );

      graph.addBlocker(
        Blocker(
          producer: 'assets',
          reason: 'path built from non-constant expression',
          affectedNamespace: 'asset:app/assets/',
        ),
      );

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      expect(findings, hasLength(1));
      expect(findings.first.confidence, Confidence.review);
      expect(findings.first.blockers, hasLength(1));
    });

    test(
      'retained generated blocker source keeps downstream asset blocker active',
      () {
        const sourceId = 'dart:app/lib/model.dart#GeneratedModel';
        const assetId = 'asset:app/assets/runtime/model.png';
        final retainsGenerated = Blocker(
          producer: 'dart',
          reason: 'generated code retains this declaration',
          affectedNodeIds: {sourceId},
        );
        final dynamicAsset = Blocker(
          producer: 'assets',
          reason: 'asset path comes from a dynamic generated member',
          sourceNodeId: sourceId,
          affectedNamespace: 'asset:app/assets/runtime/',
        );

        ReachabilityGraph build({required bool downstreamFirst}) {
          final graph = ReachabilityGraph()
            ..addNode(
              GraphNode(
                id: sourceId,
                kind: NodeKind.declaration,
                origin: Uri.file('/project/lib/model.dart'),
              ),
              producer: 'dart',
            )
            ..addNode(
              GraphNode(
                id: assetId,
                kind: NodeKind.asset,
                origin: Uri.file('/project/assets/runtime/model.png'),
              ),
              producer: 'assets',
            );
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
          final assetFinding = const FindingGenerator()
              .generate(
                graph: graph,
                project: _mockProject(),
                graphIntegrity: _integrity(graph),
              )
              .singleWhere((finding) => finding.node.id == assetId);

          expect(assetFinding.confidence, Confidence.review);
          expect(assetFinding.predicates.noDynamicBlockers, isFalse);
          expect(
            assetFinding.blockers.map((blocker) => blocker.reason),
            contains('asset path comes from a dynamic generated member'),
          );
          expect(assetFinding.proposedAction, isNull);
        }
      },
    );

    test(
      'never generates SAFE from a conflicting duplicate node definition',
      () {
        const nodeId = 'dart:app/lib/src/unused.dart#unusedFunction';
        final graph = ReachabilityGraph()
          ..addNode(
            GraphNode(
              id: nodeId,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/src/unused.dart'),
            ),
            producer: 'dart',
          )
          ..addNode(
            GraphNode(
              id: nodeId,
              kind: NodeKind.declaration,
              origin: Uri.file('/project/lib/src/other.dart'),
            ),
            producer: 'dart',
          );

        final finding = const FindingGenerator()
            .generate(
              graph: graph,
              project: _mockProject(),
              graphIntegrity: _integrity(graph),
            )
            .single;

        expect(finding.confidence, Confidence.review);
        expect(finding.predicates.noDynamicBlockers, isFalse);
      },
    );

    test('no findings for reachable nodes', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/main.dart#main',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/main.dart'),
        ),
      );

      graph.addRoot('dart:app/lib/main.dart#main', reason: 'entry point');

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      expect(findings, isEmpty);
    });

    test('does not report resolution variants independently', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'asset:app/assets/2.0x/icon.png',
          kind: NodeKind.assetVariant,
          origin: Uri.parse('file:///project/assets/2.0x/icon.png'),
        ),
      );

      final findings = const FindingGenerator().generate(
        graph: graph,
        project: _mockProject(),
        graphIntegrity: _integrity(graph),
      );

      expect(findings, isEmpty);
    });

    test('sorts findings by confidence tier', () {
      final graph = ReachabilityGraph();

      // SAFE node
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/safe.dart#safeFunc',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/src/safe.dart'),
        ),
      );

      // PROTECTED node
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/protected.dart#protectedFunc',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/src/protected.dart'),
        ),
      );
      graph.protect(
        'dart:app/lib/protected.dart#protectedFunc',
        reason: 'entry point',
      );

      // REVIEW node
      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/review.dart#reviewFunc',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/src/review.dart'),
        ),
      );
      graph.addBlocker(
        Blocker(
          producer: 'dart',
          reason: 'dynamic call',
          affectedNodeIds: {'dart:app/lib/review.dart#reviewFunc'},
        ),
      );

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      expect(findings, hasLength(3));
      expect(findings[0].confidence, Confidence.protected);
      expect(findings[1].confidence, Confidence.review);
      expect(findings[2].confidence, Confidence.safe);
    });

    test('captures evidence from incoming edges', () {
      final graph = ReachabilityGraph();

      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/used.dart#usedFunc',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/used.dart'),
        ),
      );

      graph.addNode(
        GraphNode(
          id: 'dart:app/lib/caller.dart#caller',
          kind: NodeKind.declaration,
          origin: Uri.parse('file:///project/lib/caller.dart'),
        ),
      );

      graph.addEdge(
        GraphEdge(
          from: 'dart:app/lib/caller.dart#caller',
          to: 'dart:app/lib/used.dart#usedFunc',
          kind: EdgeKind.references,
          evidence: Evidence(
            kind: EvidenceKind.semanticReference,
            producer: 'dart',
            description: 'called from caller',
            exact: true,
          ),
        ),
      );

      graph.addRoot('dart:app/lib/caller.dart#caller', reason: 'entry point');

      final project = _mockProject();
      final generator = const FindingGenerator();
      final findings = generator.generate(
        graph: graph,
        project: project,
        graphIntegrity: _integrity(graph, project.targets),
      );

      // usedFunc is reachable, so no finding
      expect(findings, isEmpty);
    });

    test(
      'uses complete project build targets for conditional reachability',
      () {
        final graph = ReachabilityGraph();
        const nodeId = 'dart:app/lib/web.dart#webMain';
        graph.addNode(
          GraphNode(
            id: nodeId,
            kind: NodeKind.declaration,
            origin: Uri.parse('file:///project/lib/web.dart'),
          ),
        );
        graph.addRoot(
          nodeId,
          reason: 'web entry point',
          condition: BuildCondition(platforms: {'web'}),
        );

        final project = ProjectContext(
          root: Directory('/project'),
          packageName: 'app',
          pubspec: const {},
          targets: [
            BuildTarget(
              name: 'web-prod',
              platform: 'web',
              entrypoint: 'lib/web.dart',
              flavor: 'prod',
              dartDefines: {'ENV': 'prod'},
            ),
          ],
        );

        final findings = const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: _integrity(graph, project.targets),
        );

        expect(findings, isEmpty);
      },
    );

    test('keeps duplicate groups in REVIEW with no automatic action', () {
      final graph = ReachabilityGraph();
      graph.addNode(
        GraphNode(
          id: 'duplicate:abc',
          kind: NodeKind.duplicateGroup,
          origin: Uri.parse('file:///project/assets/a.png'),
        ),
      );

      final findings = const FindingGenerator().generate(
        graph: graph,
        project: _mockProject(),
        graphIntegrity: _integrity(graph),
      );

      expect(findings.single.confidence, Confidence.review);
      expect(findings.single.predicates.ruleAllowsAutoFix, isFalse);
      expect(findings.single.predicates.hasDeterministicInverse, isFalse);
      expect(findings.single.proposedAction, isNull);
      expect(
        findings.single.classificationReasons,
        containsAll([
          ClassificationReason.duplicateCanonicalChoice,
          ClassificationReason.unsupportedAction,
          ClassificationReason.nonDeterministicInverse,
        ]),
      );
    });

    test('caps inferred target and root coverage at REVIEW', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/src/dead.dart#dead',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/dead.dart'),
          ),
        );
      final project = ProjectContext(
        root: Directory('/project'),
        packageName: 'app',
        pubspec: const {},
        targetMatrix: TargetMatrix(
          targets: [
            BuildTarget(
              name: 'default',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
          ],
          status: TargetMatrixStatus.inferredDefault,
          source: 'test inference',
        ),
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.inferred,
          complete: false,
          source: 'test inference',
        ),
      );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: project,
            graphIntegrity: _integrity(graph, project.targets),
          )
          .single;

      expect(finding.confidence, Confidence.review);
      expect(finding.proposedAction, isNull);
      expect(
        finding.classificationReasons,
        containsAll([
          ClassificationReason.incompleteTargetMatrix,
          ClassificationReason.incompleteRootCoverage,
        ]),
      );
    });

    test('promotes an empty internal Dart library to SAFE', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/src/empty.dart',
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/src/empty.dart'),
            metadata: const {'declarationCount': 0},
          ),
        );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(),
            graphIntegrity: _integrity(graph),
          )
          .single;

      expect(finding.confidence, Confidence.safe);
      expect(finding.proposedAction, 'Remove empty library and stale imports');
    });

    test('does not report a reachable empty library', () {
      const importerId = 'dart:app/lib/main.dart';
      const emptyId = 'dart:app/lib/src/empty.dart';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: importerId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/main.dart'),
            metadata: const {'declarationCount': 1, 'directiveCount': 1},
          ),
        )
        ..addNode(
          GraphNode(
            id: emptyId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/src/empty.dart'),
            metadata: const {'declarationCount': 0, 'directiveCount': 0},
          ),
        )
        ..addRoot(importerId, reason: 'entry point')
        ..addEdge(
          GraphEdge(
            from: importerId,
            to: emptyId,
            kind: EdgeKind.imports,
            evidence: Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'import directive',
              exact: true,
            ),
          ),
        );

      expect(
        const FindingGenerator().generate(
          graph: graph,
          project: _mockProject(),
          graphIntegrity: _integrity(graph),
        ),
        isEmpty,
      );
    });

    test('does not report an empty library live in one exact target', () {
      final android = BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      );
      final web = BuildTarget(
        name: 'web',
        platform: 'web',
        entrypoint: 'lib/main.dart',
      );
      const importerId = 'dart:app/lib/main.dart';
      const emptyId = 'dart:app/lib/src/web_empty.dart';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: importerId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: emptyId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/src/web_empty.dart'),
            metadata: const {'declarationCount': 0, 'directiveCount': 0},
          ),
        )
        ..addRoot(importerId, reason: 'entry point')
        ..addEdge(
          GraphEdge(
            from: importerId,
            to: emptyId,
            kind: EdgeKind.imports,
            condition: BuildCondition(exactTargets: {web}),
            evidence: Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'target-selected import directive',
              exact: true,
            ),
          ),
        );
      final project = _mockProject(targets: [android, web]);

      expect(graph.configuredProvenFor(android), isNot(contains(emptyId)));
      expect(graph.configuredProvenFor(web), contains(emptyId));
      expect(
        const FindingGenerator().generate(
          graph: graph,
          project: project,
          graphIntegrity: _integrity(graph, project.targets),
        ),
        isEmpty,
      );
    });

    test('does not ignore reachability for an import-only library', () {
      const importerId = 'dart:app/lib/main.dart';
      const importOnlyId = 'dart:app/lib/src/import_only.dart';
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: importerId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/main.dart'),
          ),
        )
        ..addNode(
          GraphNode(
            id: importOnlyId,
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/src/import_only.dart'),
            metadata: const {'declarationCount': 0, 'directiveCount': 1},
          ),
        )
        ..addRoot(importerId, reason: 'entry point')
        ..addEdge(
          GraphEdge(
            from: importerId,
            to: importOnlyId,
            kind: EdgeKind.imports,
            evidence: Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'dart',
              description: 'import directive',
              exact: true,
            ),
          ),
        );

      expect(
        const FindingGenerator().generate(
          graph: graph,
          project: _mockProject(),
          graphIntegrity: _integrity(graph),
        ),
        isEmpty,
      );
    });

    test('marks an externally addressable package library HIGH', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/empty.dart',
            kind: NodeKind.dartLibrary,
            origin: Uri.file('/project/lib/empty.dart'),
            metadata: const {
              'declarationCount': 0,
              'externallyAddressable': true,
            },
          ),
        );

      final finding = const FindingGenerator()
          .generate(
            graph: graph,
            project: _mockProject(
              analysisMode: AnalysisMode.packageInternal,
              rootCoverage: RootCoverage(
                mode: RootCoverageMode.packageInternal,
                internalBoundaryComplete: true,
                externalConsumersCovered: false,
                source: 'test',
              ),
            ),
            graphIntegrity: _integrity(graph),
          )
          .single;

      expect(finding.confidence, Confidence.high);
      expect(finding.predicates.noPublicApiRisk, isFalse);
    });

    test('package-internal distinguishes public, private, and asset risk', () {
      final graph = ReachabilityGraph()
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/src/api.dart#PublicApi',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/api.dart'),
            metadata: const {'externallyAddressable': true},
          ),
        )
        ..addNode(
          GraphNode(
            id: 'dart:app/lib/src/api.dart#_privateHelper',
            kind: NodeKind.declaration,
            origin: Uri.file('/project/lib/src/api.dart'),
            metadata: const {'externallyAddressable': false},
          ),
        )
        ..addNode(
          GraphNode(
            id: 'asset:app/assets/unused.png',
            kind: NodeKind.asset,
            origin: Uri.file('/project/assets/unused.png'),
            metadata: const {
              'externallyAddressable': true,
              'removalSupported': true,
            },
          ),
        );
      final findings = const FindingGenerator().generate(
        graph: graph,
        project: _mockProject(
          analysisMode: AnalysisMode.packageInternal,
          rootCoverage: RootCoverage(
            mode: RootCoverageMode.packageInternal,
            internalBoundaryComplete: true,
            externalConsumersCovered: false,
            source: 'test',
          ),
        ),
        graphIntegrity: _integrity(graph),
      );
      final byId = {for (final finding in findings) finding.node.id: finding};

      expect(
        byId['dart:app/lib/src/api.dart#PublicApi']!.confidence,
        Confidence.high,
      );
      expect(
        byId['dart:app/lib/src/api.dart#_privateHelper']!.confidence,
        Confidence.safe,
      );
      expect(byId['asset:app/assets/unused.png']!.confidence, Confidence.high);
      expect(
        byId['asset:app/assets/unused.png']!.manualRisks.map(
          (risk) => risk.code,
        ),
        ['external-consumers-not-scanned'],
      );
    });
  });
}

ProjectContext _mockProject({
  AnalysisMode analysisMode = AnalysisMode.application,
  RootCoverage? rootCoverage,
  List<BuildTarget>? targets,
}) {
  return ProjectContext(
    root: Directory('/project'),
    packageName: 'app',
    pubspec: const {},
    analysisMode: analysisMode,
    rootCoverage: rootCoverage ?? RootCoverage.applicationApi(),
    targets: targets ?? [_target('android')],
  );
}

BuildTarget _target(String platform) => BuildTarget(
  name: platform == 'android' ? 'default' : platform,
  platform: platform,
  entrypoint: 'lib/main.dart',
);

GraphIntegrity _integrity(
  ReachabilityGraph graph, [
  Iterable<BuildTarget>? targets,
]) => graph.integrityFor(targets ?? [_target('android')]);
