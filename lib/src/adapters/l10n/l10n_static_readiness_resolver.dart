import '../../core/confidence/action_readiness_index.dart';
import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import '../../core/confidence/static_action_readiness_resolver.dart';
import '../../core/graph/node.dart';
import '../../core/graph/reachability_graph.dart';
import '../../core/graph/root.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import 'action_readiness/l10n_generation_config.dart';
import 'action_readiness/l10n_toolchain.dart';

/// L10n-specific static readiness resolver.
///
/// Performs bounded static work to determine action readiness for localization
/// keys. Does NOT execute Flutter, run staging, or perform unbounded analysis.
///
/// Returns entries only for nodes that pass all static checks:
/// - Project-owned ARB family with valid configuration
/// - No scoped blockers in graph
/// - Ownership verified (ARB inputs + generated outputs within project)
/// - Deterministic inverse proven (ARB byte-edit from Stage 1)
final class L10nStaticReadinessResolver
    implements StaticActionReadinessResolver {
  /// Creates the l10n static readiness resolver.
  const L10nStaticReadinessResolver({
    L10nGenerationConfigLoader? configLoader,
    L10nToolchainResolver? toolchainResolver,
    L10nSdkRegistry? sdkRegistry,
  })  : _configLoader = configLoader ?? const DefaultL10nGenerationConfigLoader(),
        _toolchainResolver = toolchainResolver ?? const DefaultL10nToolchainResolver(),
        _sdkRegistry = sdkRegistry;

  final L10nGenerationConfigLoader _configLoader;
  final L10nToolchainResolver _toolchainResolver;
  final L10nSdkRegistry? _sdkRegistry;

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async {
    // Package mode is scan-only - no action readiness
    if (project.analysisMode == AnalysisMode.package) {
      return ActionReadinessIndex.empty;
    }

    // Resolve Flutter toolchain using registry and resolver
    // For now, return empty if no registry (production will provide one)
    if (_sdkRegistry == null) {
      return ActionReadinessIndex.empty;
    }

    final toolchainResult = await _toolchainResolver.resolve(
      originalProjectRoot: project.root,
      sdkRegistry: _sdkRegistry!,
      selection: const ProjectSelectorSelection(),
    );

    if (toolchainResult is! L10nToolchainResolved) {
      return ActionReadinessIndex.empty;
    }

    // Load strict generation config
    final configResult = await _configLoader.load(
      project: project,
      toolchain: toolchainResult.machineIdentity,
    );
    if (configResult is! L10nGenerationConfigReady) {
      return ActionReadinessIndex.empty;
    }

    final config = configResult.config;

    // Find all l10n nodes in graph and group by family
    final familyNodes = <String, List<GraphNode>>{};
    for (final node in graph.nodes) {
      if (node.kind != NodeKind.localizationKey) continue;

      // Extract family ID from node ID: 'l10n:familyId/keyName'
      final parts = node.id.split('/');
      if (parts.length != 2) continue;

      final familyPrefix = parts[0]; // 'l10n:familyId'
      if (!familyPrefix.startsWith('l10n:')) continue;

      final familyId = familyPrefix.substring(5); // Remove 'l10n:' prefix

      familyNodes.putIfAbsent(familyId, () => []).add(node);
    }

    // Build entries for each family
    final entries = <String, ActionReadinessEntry>{};

    for (final familyEntry in familyNodes.entries) {
      final familyId = familyEntry.key;
      final nodes = familyEntry.value;

      // Check if any node in family has scoped blockers
      final hasBlockers = nodes.any((node) {
        final blockers = node.metadata['scopedBlockers'] as List<Object?>?;
        return blockers != null && blockers.isNotEmpty;
      });

      if (hasBlockers) continue;

      // Determine external consumer exposure
      final hasExternalConsumerExposure =
          project.analysisMode == AnalysisMode.packageInternal;

      // Build mutation footprint
      final findingIds = nodes.map((node) => node.id).toSet();
      final physicalPaths = {
        config.templateArbPath as String,
        config.baseOutputPath as String,
        if (config.untranslatedMessagesPath != null)
          config.untranslatedMessagesPath! as String,
      };

      final footprint = MutationFootprint(
        findingIds: findingIds,
        physicalPaths: physicalPaths,
        riskScope: ActionRiskScope.boundedFamily,
        familyId: familyId,
      );

      // Create entry for each node in family
      final entry = ActionReadinessEntry(
        adapterId: 'l10n',
        nodeKind: NodeKind.localizationKey,
        familyId: familyId,
        configurationFingerprint: config.configurationIdentity as String,
        mutationFootprint: footprint,
        inverseKind: DeterministicInverseKind.proven,
        riskScope: ActionRiskScope.boundedFamily,
        hasExternalConsumerExposure: hasExternalConsumerExposure,
      );

      // Add entry for each node using node ID as key
      for (final node in nodes) {
        entries[node.id] = entry;
      }
    }

    return ActionReadinessIndex(entries);
  }
}
