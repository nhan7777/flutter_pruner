import 'package:meta/meta.dart';

import '../../core/confidence/action_capability.dart';
import '../../core/confidence/promotion_index.dart';
import '../../core/confidence/action_risk_scope.dart';
import '../../core/graph/node.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import 'l10n_action_descriptor.dart';

/// Factory for l10n-specific action capabilities.
@immutable
final class L10nActionCapability {
  const L10nActionCapability._();

  /// Creates an ActionCapability for a localization key node.
  ///
  /// Confidence rules:
  /// - **Application mode**: SAFE when complete closure + no blockers + action supported
  /// - **Package-internal mode**: HIGH max, externalConsumersNotScanned manual risk
  /// - **Package mode**: unsupported (scan-only)
  static ActionCapability forLocalizationKey({
    required GraphNode node,
    required ActionReadinessEntry readinessEntry,
    required ProjectContext project,
  }) {
    // Validate node kind
    if (node.kind != NodeKind.localizationKey) {
      throw ArgumentError('Node must be localizationKey, got ${node.kind}');
    }

    // Check for scoped blockers (other than externalConsumersNotScanned)
    final scopedBlockers = (node.metadata['scopedBlockers'] as List<dynamic>?)
        ?.cast<String>() ?? <String>[];
    final hasNonExternalBlockers = scopedBlockers.any(
      (blocker) => blocker != 'externalConsumersNotScanned',
    );

    if (hasNonExternalBlockers) {
      // Other scoped blockers → unsupported
      return const ActionCapability(
        supported: false,
        deterministicInverse: false,
        scope: ActionScope.broad,
      );
    }

    // Package mode → scan-only, unsupported
    if (project.analysisMode == AnalysisMode.package) {
      return const ActionCapability(
        supported: false,
        deterministicInverse: false,
        scope: ActionScope.broad,
      );
    }

    // Create descriptor
    final descriptor = L10nActionDescriptor(
      familyId: readinessEntry.familyId,
      selectedKeys: {node.id}, // Single key for now
      footprint: readinessEntry.mutationFootprint,
      hasExternalConsumerExposure: readinessEntry.hasExternalConsumerExposure,
    );

    // Application mode → SAFE if conditions met
    if (project.analysisMode == AnalysisMode.application) {
      return ActionCapability(
        supported: true,
        deterministicInverse: readinessEntry.inverseKind.isDeterministic,
        scope: readinessEntry.riskScope == ActionRiskScope.boundedSingle
            ? ActionScope.narrow
            : ActionScope.broad,
        proposedAction: 'Remove l10n key',
        actionDescriptor: descriptor,
      );
    }

    // Package-internal mode → HIGH max with manual risk
    // (externalConsumersNotScanned preserved as manual risk)
    return ActionCapability(
      supported: true,
      deterministicInverse: readinessEntry.inverseKind.isDeterministic,
      scope: ActionScope.broad, // Broad to signal manual review needed
      proposedAction: 'Remove l10n key (external consumers not scanned)',
      actionDescriptor: descriptor,
    );
  }
}
