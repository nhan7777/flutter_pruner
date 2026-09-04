import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_action_capability.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_action_descriptor.dart';
import 'package:flutter_pruner/src/core/confidence/action_capability.dart';
import 'package:flutter_pruner/src/core/confidence/action_readiness_index.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

void main() {
  group('L10nActionCapability', () {
    test('returns null for non-localization key node', () {
      final node = _createNode(kind: NodeKind.declaration);
      final entry = _createReadinessEntry();
      final project = _createProjectContext();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNull);
    });

    test('returns null for wrong adapter', () {
      final node = _createNode(kind: NodeKind.localizationKey);
      final entry = _createReadinessEntry(adapterId: 'other');
      final project = _createProjectContext();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNull);
    });

    test('returns null when scoped blockers present', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        metadata: {
          'scopedBlockers': ['test-blocker'],
        },
      );
      final entry = _createReadinessEntry();
      final project = _createProjectContext();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNull);
    });

    test('returns unsupported for package mode', () {
      final node = _createNode(kind: NodeKind.localizationKey);
      final entry = _createReadinessEntry();
      final project = _createProjectContext(mode: AnalysisMode.package);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNotNull);
      expect(capability!.supported, isFalse);
      expect(capability.deterministicInverse, isFalse);
      expect(capability.scope, equals(ActionScope.broad));
    });

    test('application mode creates supported capability', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        nodeId: 'l10n:app_localizations/greeting',
      );
      final entry = _createReadinessEntry(
        familyId: 'app_localizations',
        hasExternalConsumerExposure: false,
      );
      final project = _createProjectContext(mode: AnalysisMode.application);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNotNull);
      expect(capability!.supported, isTrue);
      expect(capability.deterministicInverse, isTrue);
      expect(capability.scope, equals(ActionScope.broad));
      expect(
        capability.proposedAction,
        equals('Remove localization key from ARB family'),
      );
    });

    test('package-internal mode creates supported capability', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        nodeId: 'l10n:app_localizations/greeting',
      );
      final entry = _createReadinessEntry(
        familyId: 'app_localizations',
        hasExternalConsumerExposure: true,
      );
      final project = _createProjectContext(mode: AnalysisMode.packageInternal);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability, isNotNull);
      expect(capability!.supported, isTrue);
      expect(capability.deterministicInverse, isTrue);
      expect(capability.scope, equals(ActionScope.broad));
    });

    test('capability includes l10n descriptor', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        nodeId: 'l10n:app_localizations/greeting',
      );
      final entry = _createReadinessEntry(familyId: 'app_localizations');
      final project = _createProjectContext();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      expect(capability!.actionDescriptor, isNotNull);
      expect(capability.actionDescriptor, isA<L10nActionDescriptor>());

      final descriptor = capability.actionDescriptor as L10nActionDescriptor;
      expect(descriptor.familyId, equals('app_localizations'));
      expect(descriptor.selectedKeys, equals({'greeting'}));
    });

    test('extracts key name from node ID', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        nodeId: 'l10n:app_localizations/farewell',
      );
      final entry = _createReadinessEntry(familyId: 'app_localizations');
      final project = _createProjectContext();

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      final descriptor = capability!.actionDescriptor as L10nActionDescriptor;
      expect(descriptor.selectedKeys, equals({'farewell'}));
    });

    test('external exposure propagates to descriptor', () {
      final node = _createNode(
        kind: NodeKind.localizationKey,
        nodeId: 'l10n:app_localizations/greeting',
      );
      final entry = _createReadinessEntry(
        familyId: 'app_localizations',
        hasExternalConsumerExposure: true,
      );
      final project = _createProjectContext(mode: AnalysisMode.packageInternal);

      final capability = L10nActionCapability.forLocalizationKey(
        node: node,
        readinessEntry: entry,
        project: project,
      );

      final descriptor = capability!.actionDescriptor as L10nActionDescriptor;
      expect(descriptor.hasExternalConsumerExposure, isTrue);
    });
  });
}

// Test helpers

GraphNode _createNode({
  required NodeKind kind,
  String nodeId = 'l10n:app_localizations/greeting',
  Map<String, Object?> metadata = const {},
}) {
  return GraphNode(
    id: nodeId,
    kind: kind,
    origin: Uri.parse('file:///test/lib/l10n/app_en.arb'),
    metadata: metadata,
  );
}

ActionReadinessEntry _createReadinessEntry({
  String adapterId = 'l10n',
  String familyId = 'app_localizations',
  bool hasExternalConsumerExposure = false,
}) {
  final footprint = MutationFootprint(
    findingIds: {'l10n:$familyId/greeting'},
    physicalPaths: {'lib/l10n/app_en.arb', 'lib/generated/l10n.dart'},
    riskScope: ActionRiskScope.boundedFamily,
    familyId: familyId,
  );

  return ActionReadinessEntry(
    adapterId: adapterId,
    nodeKind: NodeKind.localizationKey,
    familyId: familyId,
    configurationFingerprint: 'sha256:test',
    mutationFootprint: footprint,
    inverseKind: DeterministicInverseKind.proven,
    riskScope: ActionRiskScope.boundedFamily,
    hasExternalConsumerExposure: hasExternalConsumerExposure,
  );
}

ProjectContext _createProjectContext({
  AnalysisMode mode = AnalysisMode.application,
}) {
  return ProjectContext(
    root: Directory.current,
    pubspec: {'name': 'test_app'},
    packageName: 'test_app',
    analysisMode: mode,
    targets: [],
  );
}
