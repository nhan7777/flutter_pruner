import 'dart:io';

import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'rejects a custom owner borrowing Dart apply identity before mutation',
    () {
      final root = Directory.systemTemp.createTempSync(
        'finding_action_builder_test_',
      );
      addTearDown(() => root.deleteSync(recursive: true));
      final source =
          File(p.join(root.path, 'lib', 'src', 'route_callback.dart'))
            ..createSync(recursive: true)
            ..writeAsStringSync('void routeCallback() {}\n');
      final originalBytes = source.readAsBytesSync();
      final project = _project(root);
      final node = GraphNode(
        id: 'routes:app/lib/src/route_callback.dart#routeCallback',
        kind: NodeKind.declaration,
        origin: source.uri,
      );
      final finding = Finding(
        ruleId: 'PRN-DART-001',
        node: node,
        confidence: Confidence.safe,
        title: 'Pretend Dart finding',
        predicates: _safePredicates,
        reportingAdapterId: 'routes',
        proposedAction: 'Remove declaration',
      );

      expect(
        () => const FindingActionBuilder().build(
          findings: [finding],
          graph: ReachabilityGraph()..addNode(node, producer: 'routes'),
          project: project,
          atomicGroup: 'custom-route',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('no core-owned apply capability'),
          ),
        ),
      );
      expect(source.readAsBytesSync(), originalBytes);
    },
  );

  test('builds one atomic asset-family removal with its variants', () {
    final root = Directory.systemTemp.createTempSync(
      'finding_action_builder_test_',
    );
    addTearDown(() => root.deleteSync(recursive: true));

    final base = File(p.join(root.path, 'assets', 'icon.png'))
      ..createSync(recursive: true)
      ..writeAsStringSync('base');
    final variant = File(p.join(root.path, 'assets', '2.0x', 'icon.png'))
      ..createSync(recursive: true)
      ..writeAsStringSync('variant');
    final project = _project(root);
    final node = GraphNode(
      id: 'asset:app/assets/icon.png',
      kind: NodeKind.asset,
      origin: base.uri,
      metadata: {
        'removalSupported': true,
        'variantPaths': [variant.path],
      },
    );
    final finding = Finding(
      ruleId: 'PRN-ASSET-001',
      node: node,
      confidence: Confidence.safe,
      title: 'Unused asset',
      predicates: _safePredicates,
      reportingAdapterId: 'assets',
      proposedAction: 'Move to quarantine',
    );

    final actions = const FindingActionBuilder().build(
      findings: [finding],
      graph: ReachabilityGraph()..addNode(node),
      project: project,
      atomicGroup: 'asset-family',
    );

    expect(actions, hasLength(2));
    expect(actions.map((action) => action.atomicGroup).toSet(), {
      'asset-family',
    });
    expect(
      actions.map((action) => action.file.path),
      containsAll([base.path, variant.path]),
    );
    expect(
      actions
          .singleWhere((action) => action.file.path == variant.path)
          .operation,
      FindingActionOperation.deleteFile,
    );
  });
}

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

const _safePredicates = SafetyPredicates(
  ruleAllowsAutoFix: true,
  unreachableAcrossAllTargets: true,
  noDynamicBlockers: true,
  notProtected: true,
  noPublicApiRisk: true,
  hasDeterministicInverse: true,
);
