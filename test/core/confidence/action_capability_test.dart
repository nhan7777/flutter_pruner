import 'dart:io';

import 'package:flutter_pruner/src/core/confidence/action_capability.dart';
import 'package:flutter_pruner/src/core/confidence/promotion_index.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('ActionCapability.forFinding', () {
    test('delegates to l10n capability for l10n nodes with readiness entry', () {
      final project = ProjectContext(
        root: Directory('/test/project'),
        pubspec: {'name': 'test_package'},
        packageName: 'test_package',
        analysisMode: AnalysisMode.application,
        targetMatrix: TargetMatrix.declared([]),
      );

      final node = GraphNode(
        id: 'l10n:app.key1',
        kind: NodeKind.localizationKey,
        origin: Uri.parse('package:test_package/l10n/app_en.arb'),
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'config-fp',
        mutationFootprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedFamily,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({node.id: entry});

      final capability = ActionCapability.forFinding(
        adapterId: 'l10n',
        node: node,
        actionReadinessIndex: index,
        project: project,
      );

      expect(capability.supported, isTrue);
      expect(capability.proposedAction, 'Remove l10n key');
      expect(capability.actionDescriptor, isNotNull);
    });

    test('throws when l10n node has readiness entry but no project', () {
      final node = GraphNode(
        id: 'l10n:app.key1',
        kind: NodeKind.localizationKey,
        origin: Uri.parse('package:test_package/l10n/app_en.arb'),
      );

      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'config-fp',
        mutationFootprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
          familyId: 'family1',
        ),
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedFamily,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({node.id: entry});

      expect(
        () => ActionCapability.forFinding(
          adapterId: 'l10n',
          node: node,
          actionReadinessIndex: index,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('project is required for l10n action capability resolution'),
        )),
      );
    });

    test('uses generic capability for non-l10n adapters with readiness entry', () {
      final node = GraphNode(
        id: 'custom:asset1',
        kind: NodeKind.asset,
        origin: Uri.parse('package:test_package/assets/image.png'),
      );

      final entry = ActionReadinessEntry(
        adapterId: 'custom',
        nodeKind: NodeKind.asset,
        familyId: 'family1',
        configurationFingerprint: 'config-fp',
        mutationFootprint: const MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'assets/image.png'},
          riskScope: ActionRiskScope.boundedSingle,
        ),
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedSingle,
        hasExternalConsumerExposure: false,
      );

      final index = ActionReadinessIndex({node.id: entry});

      final capability = ActionCapability.forFinding(
        adapterId: 'custom',
        node: node,
        actionReadinessIndex: index,
      );

      expect(capability.supported, isTrue);
      expect(capability.scope, ActionScope.narrow);
      expect(capability.proposedAction, isNull); // custom adapter has no description
    });

    test('falls back to core allowlist when no readiness entry', () {
      final node = GraphNode(
        id: 'assets:image.png',
        kind: NodeKind.asset,
        origin: Uri.parse('package:test_package/assets/image.png'),
      );

      final capability = ActionCapability.forFinding(
        adapterId: 'assets',
        node: node,
      );

      expect(capability.supported, isTrue);
      expect(capability.proposedAction, 'Move to quarantine');
    });

    test('falls back to core allowlist when readiness index is empty', () {
      final node = GraphNode(
        id: 'dart:declaration:MyClass',
        kind: NodeKind.declaration,
        origin: Uri.parse('package:test_package/lib/my_class.dart'),
      );

      final capability = ActionCapability.forFinding(
        adapterId: 'dart',
        node: node,
        actionReadinessIndex: ActionReadinessIndex.empty,
      );

      expect(capability.supported, isTrue);
      expect(capability.proposedAction, 'Remove declaration');
    });

    test('returns unsupported for unknown adapter+kind combination', () {
      final node = GraphNode(
        id: 'unknown:thing',
        kind: NodeKind.declaration,
        origin: Uri.parse('package:test_package/lib/thing.dart'),
      );

      final capability = ActionCapability.forFinding(
        adapterId: 'unknown',
        node: node,
      );

      expect(capability.supported, isFalse);
    });

    test('l10n nodes without readiness entry fall back to unsupported', () {
      final node = GraphNode(
        id: 'l10n:app.key1',
        kind: NodeKind.localizationKey,
        origin: Uri.parse('package:test_package/l10n/app_en.arb'),
      );

      final capability = ActionCapability.forFinding(
        adapterId: 'l10n',
        node: node,
      );

      expect(capability.supported, isFalse);
    });
  });
}
