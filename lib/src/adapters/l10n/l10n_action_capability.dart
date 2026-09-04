import '../../core/confidence/action_capability.dart';
import '../../core/confidence/action_readiness_index.dart';
import '../../core/graph/node.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import 'l10n_action_descriptor.dart';

/// Factory for creating l10n-specific action capabilities.
///
/// Determines action support and proposed action based on project mode,
/// blockers, and external consumer exposure. Returns updated ActionCapability
/// with l10n-specific metadata.
final class L10nActionCapability {
  const L10nActionCapability._();

  /// Creates action capability for a localization key node.
  ///
  /// Returns null if:
  /// - Node is not a localization key
  /// - No readiness entry exists
  /// - Scoped blockers prevent action
  /// - Package mode (scan-only)
  ///
  /// Supported actions:
  /// - Application mode: supported with deterministic inverse
  /// - Package-internal mode: supported with deterministic inverse
  /// - Package mode: not supported (scan-only)
  static ActionCapability? forLocalizationKey({
    required GraphNode node,
    required ActionReadinessEntry readinessEntry,
    required ProjectContext project,
  }) {
    // Verify node is localization key
    if (node.kind != NodeKind.localizationKey) {
      return null;
    }

    // Verify adapter ownership
    if (readinessEntry.adapterId != 'l10n') {
      return null;
    }

    // Check for scoped blockers in metadata
    final scopedBlockers = node.metadata['scopedBlockers'] as List<Object?>?;
    if (scopedBlockers != null && scopedBlockers.isNotEmpty) {
      return null;
    }

    // Package mode is scan-only
    if (project.analysisMode == AnalysisMode.package) {
      return const ActionCapability(
        supported: false,
        deterministicInverse: false,
        scope: ActionScope.broad,
      );
    }

    // Create l10n descriptor for supported modes
    final descriptor = L10nActionDescriptor(
      familyId: readinessEntry.familyId,
      selectedKeys: {_extractKeyFromNodeId(node.id)},
      footprint: readinessEntry.mutationFootprint,
      hasExternalConsumerExposure: readinessEntry.hasExternalConsumerExposure,
    );

    // L10n actions are supported in application and package-internal modes
    // Family-level mutations use ActionScope.broad since they touch multiple files
    return ActionCapability(
      supported: true,
      deterministicInverse: true,
      scope: ActionScope.broad,
      proposedAction: 'Remove localization key from ARB family',
      actionDescriptor: descriptor,
    );
  }

  /// Extracts the key name from a localization key node ID.
  ///
  /// Node IDs follow format: 'l10n:familyId/keyName'
  static String _extractKeyFromNodeId(String nodeId) {
    final parts = nodeId.split('/');
    if (parts.length != 2) {
      throw ArgumentError('Invalid localization key node ID: $nodeId');
    }
    return parts[1];
  }
}
