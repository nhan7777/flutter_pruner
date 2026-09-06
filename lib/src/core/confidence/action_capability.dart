import '../../adapters/l10n/l10n_action_capability.dart';
import '../graph/node.dart';
import '../project/project_context.dart';
import 'action_risk_scope.dart';
import 'promotion_index.dart';

/// Physical scope of the edit required to apply a finding.
enum ActionScope {
  /// One asset, declaration, or structurally empty library.
  narrow,

  /// A whole library, feature closure, or other multi-node removal.
  broad,
}

/// A preflighted mechanical action and its rollback properties.
class ActionCapability {
  /// Creates an action capability.
  const ActionCapability({
    required this.supported,
    required this.deterministicInverse,
    required this.scope,
    this.proposedAction,
    this.actionDescriptor,
  });

  /// Resolves the core-owned action allowlist for one finding identity.
  ///
  /// Rule IDs and all other adapter report metadata are intentionally absent
  /// from this decision. A custom adapter reusing a built-in [NodeKind]
  /// therefore remains unsupported.
  ///
  /// If [actionReadinessIndex] is provided and contains an entry for this node,
  /// adapter-specific capability logic may be invoked (e.g., l10n family-level
  /// actions). If null or empty, falls back to the core allowlist.
  ///
  /// [project] is required when [actionReadinessIndex] is provided, as
  /// adapter-specific capabilities need project context (e.g., analysis mode).
  factory ActionCapability.forFinding({
    required String adapterId,
    required GraphNode node,
    ActionReadinessIndex? actionReadinessIndex,
    ProjectContext? project,
  }) {
    // Check ActionReadinessIndex first for adapter-specific capabilities
    if (actionReadinessIndex != null) {
      final entry = actionReadinessIndex[node.id];
      if (entry != null) {
        // Delegate to adapter-specific capability logic
        if (adapterId == 'l10n' && node.kind == NodeKind.localizationKey) {
          if (project == null) {
            throw ArgumentError(
              'project is required for l10n action capability resolution',
            );
          }
          return L10nActionCapability.forLocalizationKey(
            node: node,
            readinessEntry: entry,
            project: project,
          );
        }

        // Generic adapter-specific capability (no custom logic)
        return ActionCapability(
          supported: true,
          deterministicInverse: entry.inverseKind.isDeterministic,
          scope: entry.riskScope == ActionRiskScope.boundedSingle
              ? ActionScope.narrow
              : ActionScope.broad,
          proposedAction: _actionDescriptionForAdapter(adapterId, node.kind),
        );
      }
    }

    // Fall back to core allowlist for built-in adapters
    return switch ((adapterId, node.kind)) {
      ('assets', NodeKind.asset)
          when node.metadata['removalSupported'] != false =>
        const ActionCapability(
          supported: true,
          deterministicInverse: true,
          scope: ActionScope.narrow,
          proposedAction: 'Move to quarantine',
        ),
      ('dart', NodeKind.declaration)
          when node.metadata['removalSupported'] != false =>
        const ActionCapability(
          supported: true,
          deterministicInverse: true,
          scope: ActionScope.narrow,
          proposedAction: 'Remove declaration',
        ),
      ('dart', NodeKind.dartLibrary)
          when node.metadata['declarationCount'] == 0 =>
        const ActionCapability(
          supported: true,
          deterministicInverse: true,
          scope: ActionScope.narrow,
          proposedAction: 'Remove empty library and stale imports',
        ),
      _ => const ActionCapability(
        supported: false,
        deterministicInverse: false,
        scope: ActionScope.broad,
      ),
    };
  }

  static String? _actionDescriptionForAdapter(String adapterId, NodeKind kind) {
    return switch ((adapterId, kind)) {
      ('l10n', NodeKind.localizationKey) => 'Remove l10n key',
      ('assets', NodeKind.asset) => 'Move to quarantine',
      ('dart', NodeKind.declaration) => 'Remove declaration',
      ('dart', NodeKind.dartLibrary) => 'Remove empty library',
      _ => null,
    };
  }

  /// Whether production apply code implements this operation.
  final bool supported;

  /// Whether quarantine can restore the exact pre-edit bytes.
  final bool deterministicInverse;

  /// Whether the edit is narrow enough for SAFE or requires manual opt-in.
  final ActionScope scope;

  /// User-facing operation, present only for supported actions.
  final String? proposedAction;

  /// Adapter-specific action descriptor with mutation details.
  ///
  /// Present for adapter-specific actions that need custom metadata
  /// (e.g., L10nActionDescriptor for l10n family-level mutations).
  final Object? actionDescriptor;
}
