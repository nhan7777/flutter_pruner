import 'dart:io';

import 'package:flutter_pruner/src/apply/apply_action_plan.dart';
import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late ProjectContext project;

  setUp(() {
    root = Directory.systemTemp.createTempSync('apply_action_plan_test_');
    project = _project(root);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'projects planner order, blocks, dependencies, and physical actions exactly',
    () {
      final consumerFile = _file(root, 'lib/consumer.dart', 'consumer\n');
      final targetFile = _file(root, 'lib/target.dart', 'target\n');
      final generatedFile = _file(root, 'lib/target.g.dart', 'generated\n');
      final retainedImporter = _file(root, 'lib/api.dart', 'api\n');
      final sharedFile = _file(root, 'lib/shared.dart', 'shared\n');
      final assetFile = _file(root, 'assets/icon.png', 'base\n');
      final assetVariant = _file(root, 'assets/2.0x/icon.png', 'variant\n');

      final consumer = _libraryFinding(
        'dart:app/lib/consumer.dart',
        consumerFile,
      );
      final target = _libraryFinding(
        'dart:app/lib/target.dart',
        targetFile,
        generatedPartPaths: [generatedFile.path],
      );
      final sharedB = _declarationFinding(
        'dart:app/lib/shared.dart#b',
        sharedFile,
      );
      final sharedA = _declarationFinding(
        'dart:app/lib/shared.dart#a',
        sharedFile,
      );
      final asset = _assetFinding(
        'asset:app/assets/icon.png',
        assetFile,
        variantPaths: [assetVariant.path],
      );
      final blockedZ = _declarationFinding(
        'dart:app/lib/z_blocked.dart#z',
        _file(root, 'lib/z_blocked.dart', 'z\n'),
      );
      final blockedA = _declarationFinding(
        'dart:app/lib/a_blocked.dart#a',
        _file(root, 'lib/a_blocked.dart', 'a\n'),
      );
      final retainedImporterNode = GraphNode(
        id: 'dart:app/lib/api.dart',
        kind: NodeKind.dartLibrary,
        origin: retainedImporter.uri,
      );
      final graph = ReachabilityGraph()
        ..addNode(consumer.node)
        ..addNode(target.node)
        ..addNode(sharedB.node)
        ..addNode(sharedA.node)
        ..addNode(asset.node)
        ..addNode(blockedZ.node)
        ..addNode(blockedA.node)
        ..addNode(retainedImporterNode)
        ..addEdge(_importEdge(consumer.node.id, target.node.id))
        ..addEdge(_importEdge(retainedImporterNode.id, target.node.id));
      final sharedFindings = <Finding>[sharedB, sharedA];
      final consumerDependencies = <String>['unit:target', 'unit:shared'];
      final units = <AtomicUnit>[
        AtomicUnit(
          id: 'unit:consumer',
          findings: [consumer],
          dependencyUnitIds: consumerDependencies,
        ),
        AtomicUnit(
          id: 'unit:target',
          findings: [target],
          dependencyUnitIds: const [],
        ),
        AtomicUnit(
          id: 'unit:shared',
          findings: sharedFindings,
          dependencyUnitIds: const [],
        ),
        AtomicUnit(
          id: 'unit:asset',
          findings: [asset],
          dependencyUnitIds: const [],
        ),
      ];
      final blocked = <BlockedFinding>[
        BlockedFinding(
          finding: blockedZ,
          reason: PlanBlockReason.blockedByRetainedDependency,
          blockedBy: consumer.node.id,
        ),
        BlockedFinding(
          finding: blockedA,
          reason: PlanBlockReason.retainedConsumer,
          blockedBy: retainedImporterNode.id,
        ),
      ];
      final selection = FindingSelection.fromCli(const []);

      final actionPlan =
          const ApplyActionPlanBuilder.forTesting(
            _CleanupTargetAliasActionBuilder(),
          ).build(
            removalPlan: RemovalPlan(units: units, blocked: blocked),
            graph: graph,
            project: project,
            selection: selection,
          );

      expect(ApplyActionPlan.canonicalVersion, 1);
      expect(actionPlan.units.map((unit) => unit.order), [0, 1, 2, 3]);
      expect(actionPlan.units.map((unit) => unit.id), [
        'unit:consumer',
        'unit:target',
        'unit:shared',
        'unit:asset',
      ]);
      expect(actionPlan.units[0].findingIds, [consumer.node.id]);
      expect(actionPlan.units[0].dependencyUnitIds, consumerDependencies);
      expect(actionPlan.units[2].findingIds, [
        sharedB.node.id,
        sharedA.node.id,
      ]);
      expect(
        actionPlan.blocked
            .map((item) => (item.findingId, item.reason, item.blockedBy))
            .toList(),
        [
          (
            blockedZ.node.id,
            PlanBlockReason.blockedByRetainedDependency,
            consumer.node.id,
          ),
          (
            blockedA.node.id,
            PlanBlockReason.retainedConsumer,
            retainedImporterNode.id,
          ),
        ],
      );

      expect(_actionProjection(actionPlan.actionsFor('unit:consumer')), [
        (
          consumer.node.id,
          consumer.node.id,
          FindingActionOperation.deleteFile,
          consumerFile.path,
          true,
          null,
        ),
      ]);
      expect(_actionProjection(actionPlan.actionsFor('unit:target')), [
        (
          target.node.id,
          '${target.node.id}@import:lib/api.dart',
          FindingActionOperation.cleanupImports,
          retainedImporter.path,
          false,
          p.join(root.path, 'lib', '..', 'lib', 'target.dart'),
        ),
        (
          target.node.id,
          '${target.node.id}@generated:lib/target.g.dart',
          FindingActionOperation.deleteFile,
          generatedFile.path,
          false,
          null,
        ),
        (
          target.node.id,
          target.node.id,
          FindingActionOperation.deleteFile,
          targetFile.path,
          true,
          null,
        ),
      ]);
      expect(_actionProjection(actionPlan.actionsFor('unit:shared')), [
        (
          sharedB.node.id,
          sharedB.node.id,
          FindingActionOperation.removeFinding,
          sharedFile.path,
          true,
          null,
        ),
        (
          sharedA.node.id,
          sharedA.node.id,
          FindingActionOperation.removeFinding,
          sharedFile.path,
          true,
          null,
        ),
      ]);
      expect(_actionProjection(actionPlan.actionsFor('unit:asset')), [
        (
          asset.node.id,
          '${asset.node.id}@variant:assets/2.0x/icon.png',
          FindingActionOperation.deleteFile,
          assetVariant.path,
          false,
          null,
        ),
        (
          asset.node.id,
          asset.node.id,
          FindingActionOperation.removeFinding,
          assetFile.path,
          true,
          null,
        ),
      ]);
      expect(
        actionPlan.actionsFor('unit:target').map((action) => action.file.path),
        isNot(contains(consumerFile.path)),
      );
      expect(
        actionPlan.planFingerprint,
        'd1e8bdfc22a70977712364504cf89022853b72ed2b1b9b15e609655154b0bca9',
      );

      units.clear();
      blocked.clear();
      sharedFindings.clear();
      consumerDependencies.clear();
      expect(actionPlan.units, hasLength(4));
      expect(actionPlan.blocked, hasLength(2));
      expect(actionPlan.units[2].findingIds, [
        sharedB.node.id,
        sharedA.node.id,
      ]);
      expect(actionPlan.units[0].dependencyUnitIds, [
        'unit:target',
        'unit:shared',
      ]);
      expect(() => actionPlan.units.clear(), throwsUnsupportedError);
      expect(
        () => actionPlan.units.first.findingIds.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => actionPlan.actionsFor('unit:target').clear(),
        throwsUnsupportedError,
      );
      expect(
        () => actionPlan.actionsFor('unit:missing'),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            'Frozen action plan has no atomic unit unit:missing.',
          ),
        ),
      );
    },
  );

  test('preserves planFingerprint v1 when only source bytes change', () {
    final source = _file(root, 'lib/dead.dart', 'before\n');
    final finding = _declarationFinding('dart:app/lib/dead.dart#dead', source);
    final graph = ReachabilityGraph()..addNode(finding.node);
    final removalPlan = RemovalPlan(
      units: [
        AtomicUnit(
          id: 'unit:fingerprint',
          findings: [finding],
          dependencyUnitIds: const [],
        ),
      ],
      blocked: const [],
    );
    final selection = FindingSelection.fromCli([finding.node.id]);
    const expected =
        '775ecbc8e7000beb73a67139efb225814d8218e3fe9ff0ec4e74b2482decab15';

    final before = const ApplyActionPlanBuilder().build(
      removalPlan: removalPlan,
      graph: graph,
      project: project,
      selection: selection,
    );
    source.writeAsStringSync('different source bytes\n');
    final after = const ApplyActionPlanBuilder().build(
      removalPlan: removalPlan,
      graph: graph,
      project: project,
      selection: selection,
    );

    expect(before.planFingerprint, expected);
    expect(after.planFingerprint, expected);
    source.writeAsStringSync('before\n');
    expect(source.readAsStringSync(), 'before\n');
  });

  test('blocked-only plan preserves blocks and has no fingerprint', () {
    final blockedFinding = _declarationFinding(
      'dart:app/lib/blocked.dart#blocked',
      _file(root, 'lib/blocked.dart', 'blocked\n'),
    );

    final actionPlan = const ApplyActionPlanBuilder().build(
      removalPlan: RemovalPlan(
        units: const [],
        blocked: [
          BlockedFinding(
            finding: blockedFinding,
            reason: PlanBlockReason.retainedConsumer,
            blockedBy: 'dart:app/lib/main.dart#main',
          ),
        ],
      ),
      graph: ReachabilityGraph()..addNode(blockedFinding.node),
      project: project,
      selection: FindingSelection.fromCli([blockedFinding.node.id]),
    );

    expect(actionPlan.units, isEmpty);
    expect(actionPlan.planFingerprint, isNull);
    expect(actionPlan.blocked.single.findingId, blockedFinding.node.id);
    expect(actionPlan.blocked.single.reason, PlanBlockReason.retainedConsumer);
    expect(actionPlan.blocked.single.blockedBy, 'dart:app/lib/main.dart#main');
  });

  test('fails closed on a duplicate atomic unit identity', () {
    final source = _file(root, 'lib/dead.dart', 'dead\n');
    final finding = _declarationFinding('dart:app/lib/dead.dart#dead', source);
    final duplicateUnit = AtomicUnit(
      id: 'unit:duplicate',
      findings: [finding],
      dependencyUnitIds: const [],
    );

    expect(
      () => const ApplyActionPlanBuilder().build(
        removalPlan: RemovalPlan(
          units: [duplicateUnit, duplicateUnit],
          blocked: const [],
        ),
        graph: ReachabilityGraph()..addNode(finding.node),
        project: project,
        selection: FindingSelection.fromCli([finding.node.id]),
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Removal plan repeated atomic unit ID unit:duplicate.',
        ),
      ),
    );
    expect(source.readAsStringSync(), 'dead\n');
  });

  test('fails closed on duplicate effective journal action identities', () {
    final source = _file(root, 'lib/dead.dart', 'dead\n');
    final companion = _file(root, 'lib/dead.g.dart', 'generated\n');
    final finding = _declarationFinding('dart:app/lib/dead.dart#dead', source);
    final descriptors = [
      FindingActionDescriptor(
        finding: finding,
        file: source,
        operation: FindingActionOperation.removeFinding,
        atomicGroup: 'unit:duplicate-action',
        findingId: 'journal:duplicate',
      ),
      FindingActionDescriptor(
        finding: finding,
        file: companion,
        operation: FindingActionOperation.deleteFile,
        atomicGroup: 'unit:duplicate-action',
        findingId: 'journal:duplicate',
        countsTowardSummary: false,
      ),
    ];

    expect(
      () => ApplyActionPlanBuilder.forTesting(_FixedActionBuilder(descriptors))
          .build(
            removalPlan: RemovalPlan(
              units: [
                AtomicUnit(
                  id: 'unit:duplicate-action',
                  findings: [finding],
                  dependencyUnitIds: const [],
                ),
              ],
              blocked: const [],
            ),
            graph: ReachabilityGraph()..addNode(finding.node),
            project: project,
            selection: FindingSelection.fromCli([finding.node.id]),
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('repeated effective journal action identity'),
        ),
      ),
    );
    expect(source.readAsStringSync(), 'dead\n');
    expect(companion.readAsStringSync(), 'generated\n');
  });

  test('fails closed on duplicate composite physical action identities', () {
    final source = _file(root, 'lib/dead.dart', 'dead\n');
    final finding = _declarationFinding('dart:app/lib/dead.dart#dead', source);
    final descriptors = [
      FindingActionDescriptor(
        finding: finding,
        file: source,
        operation: FindingActionOperation.removeFinding,
        atomicGroup: 'unit:duplicate-composite',
        findingId: 'journal:first',
      ),
      FindingActionDescriptor(
        finding: finding,
        file: source,
        operation: FindingActionOperation.removeFinding,
        atomicGroup: 'unit:duplicate-composite',
        findingId: 'journal:second',
      ),
    ];

    expect(
      () => ApplyActionPlanBuilder.forTesting(_FixedActionBuilder(descriptors))
          .build(
            removalPlan: RemovalPlan(
              units: [
                AtomicUnit(
                  id: 'unit:duplicate-composite',
                  findings: [finding],
                  dependencyUnitIds: const [],
                ),
              ],
              blocked: const [],
            ),
            graph: ReachabilityGraph()..addNode(finding.node),
            project: project,
            selection: FindingSelection.fromCli([finding.node.id]),
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('repeated composite physical action identity'),
        ),
      ),
    );
    expect(source.readAsStringSync(), 'dead\n');
  });

  test('fails closed on a non-authoritative Finding instance', () {
    final source = _file(root, 'lib/authorized.dart', 'authorized\n');
    final authoritative = _declarationFinding(
      'dart:app/lib/authorized.dart#authorized',
      source,
    );
    final alternate = Finding(
      ruleId: authoritative.ruleId,
      node: GraphNode(
        id: authoritative.node.id,
        kind: authoritative.node.kind,
        origin: authoritative.node.origin,
        metadata: const {'alternatePayload': true},
      ),
      confidence: authoritative.confidence,
      title: 'alternate payload with an authorized ID',
      predicates: authoritative.predicates,
      reportingAdapterId: authoritative.reportingAdapterId,
      proposedAction: authoritative.proposedAction,
    );

    expect(
      () =>
          ApplyActionPlanBuilder.forTesting(
            _FixedActionBuilder([
              FindingActionDescriptor(
                finding: alternate,
                file: source,
                operation: FindingActionOperation.removeFinding,
                atomicGroup: 'unit:authoritative-instance',
              ),
            ]),
          ).build(
            removalPlan: RemovalPlan(
              units: [
                AtomicUnit(
                  id: 'unit:authoritative-instance',
                  findings: [authoritative],
                  dependencyUnitIds: const [],
                ),
              ],
              blocked: const [],
            ),
            graph: ReachabilityGraph()..addNode(authoritative.node),
            project: project,
            selection: FindingSelection.fromCli([authoritative.node.id]),
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('does not use the authoritative Finding instance'),
        ),
      ),
    );
    expect(source.readAsStringSync(), 'authorized\n');
  });

  test('fails closed on an unrelated physical file and operation', () {
    final source = _file(root, 'lib/authorized.dart', 'authorized\n');
    final unrelated = _file(root, 'lib/unrelated.dart', 'unrelated\n');
    final authoritative = _declarationFinding(
      'dart:app/lib/authorized.dart#authorized',
      source,
    );

    expect(
      () =>
          ApplyActionPlanBuilder.forTesting(
            _FixedActionBuilder([
              FindingActionDescriptor(
                finding: authoritative,
                file: unrelated,
                operation: FindingActionOperation.deleteFile,
                atomicGroup: 'unit:physical-provenance',
              ),
            ]),
          ).build(
            removalPlan: RemovalPlan(
              units: [
                AtomicUnit(
                  id: 'unit:physical-provenance',
                  findings: [authoritative],
                  dependencyUnitIds: const [],
                ),
              ],
              blocked: const [],
            ),
            graph: ReachabilityGraph()..addNode(authoritative.node),
            project: project,
            selection: FindingSelection.fromCli([authoritative.node.id]),
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('does not match the core physical action projection'),
        ),
      ),
    );
    expect(source.readAsStringSync(), 'authorized\n');
    expect(unrelated.readAsStringSync(), 'unrelated\n');
  });

  test('fails closed when an authoritative finding has no physical action', () {
    final source = _file(root, 'lib/authorized.dart', 'authorized\n');
    final authoritative = _declarationFinding(
      'dart:app/lib/authorized.dart#authorized',
      source,
    );

    expect(
      () => const ApplyActionPlanBuilder.forTesting(_FixedActionBuilder([]))
          .build(
            removalPlan: RemovalPlan(
              units: [
                AtomicUnit(
                  id: 'unit:missing-coverage',
                  findings: [authoritative],
                  dependencyUnitIds: const [],
                ),
              ],
              blocked: const [],
            ),
            graph: ReachabilityGraph()..addNode(authoritative.node),
            project: project,
            selection: FindingSelection.fromCli([authoritative.node.id]),
          ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('did not project physical work for authoritative finding'),
        ),
      ),
    );
    expect(source.readAsStringSync(), 'authorized\n');
  });

  test(
    'fails closed when a physical action is projected into another unit',
    () {
      final authorizedSource = _file(
        root,
        'lib/authorized.dart',
        'authorized\n',
      );
      final foreignSource = _file(root, 'lib/foreign.dart', 'foreign\n');
      final authorized = _declarationFinding(
        'dart:app/lib/authorized.dart#authorized',
        authorizedSource,
      );
      final foreign = _declarationFinding(
        'dart:app/lib/foreign.dart#foreign',
        foreignSource,
      );
      final descriptor = FindingActionDescriptor(
        finding: foreign,
        file: foreignSource,
        operation: FindingActionOperation.removeFinding,
        atomicGroup: 'unit:authorized',
      );

      expect(
        () =>
            ApplyActionPlanBuilder.forTesting(
              _FixedActionBuilder([descriptor]),
            ).build(
              removalPlan: RemovalPlan(
                units: [
                  AtomicUnit(
                    id: 'unit:authorized',
                    findings: [authorized],
                    dependencyUnitIds: const [],
                  ),
                ],
                blocked: const [],
              ),
              graph: ReachabilityGraph()
                ..addNode(authorized.node)
                ..addNode(foreign.node),
              project: project,
              selection: FindingSelection.fromCli([authorized.node.id]),
            ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('does not belong to atomic unit unit:authorized'),
          ),
        ),
      );
      expect(authorizedSource.readAsStringSync(), 'authorized\n');
      expect(foreignSource.readAsStringSync(), 'foreign\n');
    },
  );
}

List<(String, String, FindingActionOperation, String, bool, String?)>
_actionProjection(List<FindingActionDescriptor> actions) => [
  for (final action in actions)
    (
      action.finding.node.id,
      action.findingId ?? action.finding.node.id,
      action.operation,
      action.file.path,
      action.countsTowardSummary,
      action.cleanupTargetPath,
    ),
];

File _file(Directory root, String relativePath, String contents) =>
    File(p.joinAll(<String>[root.path, ...p.posix.split(relativePath)]))
      ..createSync(recursive: true)
      ..writeAsStringSync(contents);

ProjectContext _project(Directory root) => ProjectContext(
  root: root,
  pubspec: const {},
  packageName: 'app',
  targets: [
    BuildTarget(
      name: 'android',
      platform: 'android',
      entrypoint: 'lib/main.dart',
    ),
  ],
);

Finding _libraryFinding(
  String id,
  File file, {
  List<String> generatedPartPaths = const [],
}) => Finding(
  ruleId: 'PRN-DART-002',
  node: GraphNode(
    id: id,
    kind: NodeKind.dartLibrary,
    origin: file.uri,
    metadata: {
      'declarationCount': 0,
      'directiveCount': 0,
      'generatedPartPaths': generatedPartPaths,
    },
  ),
  confidence: Confidence.safe,
  title: id,
  predicates: _safePredicates,
  reportingAdapterId: 'dart',
  proposedAction: 'Remove empty library and stale imports',
);

Finding _declarationFinding(String id, File file) => Finding(
  ruleId: 'PRN-DART-001',
  node: GraphNode(id: id, kind: NodeKind.declaration, origin: file.uri),
  confidence: Confidence.safe,
  title: id,
  predicates: _safePredicates,
  reportingAdapterId: 'dart',
  proposedAction: 'Remove declaration',
);

Finding _assetFinding(
  String id,
  File file, {
  required List<String> variantPaths,
}) => Finding(
  ruleId: 'PRN-ASSET-001',
  node: GraphNode(
    id: id,
    kind: NodeKind.asset,
    origin: file.uri,
    metadata: {'removalSupported': true, 'variantPaths': variantPaths},
  ),
  confidence: Confidence.safe,
  title: id,
  predicates: _safePredicates,
  reportingAdapterId: 'assets',
  proposedAction: 'Move to quarantine',
);

GraphEdge _importEdge(String from, String to) => GraphEdge(
  from: from,
  to: to,
  kind: EdgeKind.imports,
  evidence: const Evidence(
    kind: EvidenceKind.semanticReference,
    producer: 'dart',
    description: 'import directive',
    exact: true,
  ),
);

const _safePredicates = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  notRetained: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
);

final class _CleanupTargetAliasActionBuilder extends FindingActionBuilder {
  const _CleanupTargetAliasActionBuilder();

  @override
  List<FindingActionDescriptor> build({
    required List<Finding> findings,
    required ReachabilityGraph graph,
    required ProjectContext project,
    required String atomicGroup,
  }) => [
    for (final action in super.build(
      findings: findings,
      graph: graph,
      project: project,
      atomicGroup: atomicGroup,
    ))
      if (action.cleanupTargetPath == null)
        action
      else
        FindingActionDescriptor(
          finding: action.finding,
          file: action.file,
          operation: action.operation,
          atomicGroup: action.atomicGroup,
          label: action.label,
          findingId: action.findingId,
          countsTowardSummary: action.countsTowardSummary,
          cleanupTargetPath: p.join(
            p.dirname(action.cleanupTargetPath!),
            '..',
            p.basename(p.dirname(action.cleanupTargetPath!)),
            p.basename(action.cleanupTargetPath!),
          ),
        ),
  ];
}

final class _FixedActionBuilder extends FindingActionBuilder {
  const _FixedActionBuilder(this.actions);

  final List<FindingActionDescriptor> actions;

  @override
  List<FindingActionDescriptor> build({
    required List<Finding> findings,
    required ReachabilityGraph graph,
    required ProjectContext project,
    required String atomicGroup,
  }) => List.of(actions);
}
