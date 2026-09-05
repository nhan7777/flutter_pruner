import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_action_capability.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_action_descriptor.dart';
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
  group('L10nActionCapability', () {
    ProjectContext createProject(AnalysisMode mode) {
      return ProjectContext(
        root: Directory('/test/project'),
        pubspec: {'name': 'test_package'},
        packageName: 'test_package',
        analysisMode: mode,
        targetMatrix: TargetMatrix.declared([]),
      );
    }

    GraphNode createNode({
      NodeKind kind = NodeKind.localizationKey,
      Map<String, dynamic>? metadata,
    }) {
      return GraphNode(
        id: 'l10n:app.key1',
        kind: kind,
        origin: Uri.parse('package:test_package/l10n/app_en.arb'),
        metadata: metadata ?? {},
      );
    }

    ActionReadinessEntry createEntry({
      bool hasExternalConsumerExposure = false,
      ActionRiskScope riskScope = ActionRiskScope.boundedFamily,
      DeterministicInverseKind inverseKind = DeterministicInverseKind.proven,
    }) {
      return ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: 'family1',
        configurationFingerprint: 'config-fp',
        mutationFootprint: MutationFootprint(
          findingIds: {'finding1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: riskScope,
          familyId: 'family1',
        ),
        inverseKind: inverseKind,
        riskScope: riskScope,
        hasExternalConsumerExposure: hasExternalConsumerExposure,
      );
    }

    test('throws when node is not localizationKey', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode(kind: NodeKind.asset);
      final entry = createEntry();

      expect(
        () => L10nActionCapability.forLocalizationKey(
          node: node,
          readinessEntry: entry,
          project: project,
        ),
        throwsA(isA<ArgumentError>().having(
          (e) => e.message,
          'message',
          contains('Node must be localizationKey'),
        )),
      );
    });

    test('application mode returns SAFE capability', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode();
      final entry = createEntry();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isTrue);
      expect(capability.deterministicInverse, isTrue);
      expect(capability.scope, ActionScope.broad);
      expect(capability.proposedAction, 'Remove l10n key');
      expect(capability.actionDescriptor, isA<L10nActionDescriptor>());

      final descriptor = capability.actionDescriptor as L10nActionDescriptor;
      expect(descriptor.familyId, 'family1');
      expect(descriptor.selectedKeys, {'l10n:app.key1'});
      expect(descriptor.hasExternalConsumerExposure, isFalse);
    });

    test('application mode with boundedSingle has narrow scope', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode();
      final entry = createEntry(riskScope: ActionRiskScope.boundedSingle);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.scope, ActionScope.narrow);
    });

    test('package-internal mode returns HIGH capability with manual risk', () {
      final project = createProject(AnalysisMode.packageInternal);
      final node = createNode(metadata: {
        'scopedBlockers': ['externalConsumersNotScanned'],
      });
      final entry = createEntry(hasExternalConsumerExposure: true);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isTrue);
      expect(capability.deterministicInverse, isTrue);
      expect(capability.scope, ActionScope.broad);
      expect(
        capability.proposedAction,
        'Remove l10n key (external consumers not scanned)',
      );

      final descriptor = capability.actionDescriptor as L10nActionDescriptor;
      expect(descriptor.hasExternalConsumerExposure, isTrue);
    });

    test('package mode returns unsupported', () {
      final project = createProject(AnalysisMode.package);
      final node = createNode();
      final entry = createEntry();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isFalse);
      expect(capability.deterministicInverse, isFalse);
      expect(capability.scope, ActionScope.broad);
    });

    test('scoped blocker present returns unsupported', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode(metadata: {
        'scopedBlockers': ['someOtherBlocker', 'externalConsumersNotScanned'],
      });
      final entry = createEntry();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isFalse);
      expect(capability.deterministicInverse, isFalse);
      expect(capability.scope, ActionScope.broad);
    });

    test('externalConsumersNotScanned alone does not block application mode', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode(metadata: {
        'scopedBlockers': ['externalConsumersNotScanned'],
      });
      final entry = createEntry(hasExternalConsumerExposure: true);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isTrue);
    });

    test('no scopedBlockers metadata is treated as empty list', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode(); // No metadata
      final entry = createEntry();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.supported, isTrue);
    });

    test('generative inverse kind is preserved', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode();
      final entry = createEntry(inverseKind: DeterministicInverseKind.generative);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.deterministicInverse, isTrue);
    });

    test('none inverse kind returns non-deterministic', () {
      final project = createProject(AnalysisMode.application);
      final node = createNode();
      final entry = createEntry(inverseKind: DeterministicInverseKind.none);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability.deterministicInverse, isFalse);
    });
  });
}
