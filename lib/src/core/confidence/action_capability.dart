import '../graph/node.dart';

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
  });

  /// Resolves the core-owned action allowlist for one finding identity.
  ///
  /// Rule IDs and all other adapter report metadata are intentionally absent
  /// from this decision. A custom adapter reusing a built-in [NodeKind]
  /// therefore remains unsupported.
  factory ActionCapability.forFinding({
    required String adapterId,
    required GraphNode node,
  }) {
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

  /// Whether production apply code implements this operation.
  final bool supported;

  /// Whether quarantine can restore the exact pre-edit bytes.
  final bool deterministicInverse;

  /// Whether the edit is narrow enough for SAFE or requires manual opt-in.
  final ActionScope scope;

  /// User-facing operation, present only for supported actions.
  final String? proposedAction;
}
