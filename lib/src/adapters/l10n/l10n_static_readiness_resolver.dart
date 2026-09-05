import 'package:path/path.dart' as p;

import '../internal/resolver.dart';
import '../../core/confidence/promotion_index.dart';
import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import '../../core/graph/node.dart';
import '../../core/graph/reachability_graph.dart';
import '../../core/graph/root.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';

/// L10n static action readiness resolver performing bounded static analysis.
final class L10nStaticReadinessResolver implements ActionReadinessResolver {
  const L10nStaticReadinessResolver();

  @override
  Future<ActionReadinessIndex> resolve({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity integrity,
  }) async {
    // Package mode → scan-only, no actionable mutations
    if (project.analysisMode == AnalysisMode.package) {
      return ActionReadinessIndex.empty;
    }

    // Find all l10n nodes in graph
    final l10nNodes = graph.nodes.where(
      (node) => node.id.startsWith('l10n:') && node.kind == NodeKind.localizationKey,
    );

    if (l10nNodes.isEmpty) {
      return ActionReadinessIndex.empty;
    }

    // Group nodes by family (extract from node ID: l10n:familyId.key)
    final familyGroups = <String, List<GraphNode>>{};
    for (final node in l10nNodes) {
      final familyId = _extractFamilyId(node.id);
      if (familyId != null) {
        familyGroups.putIfAbsent(familyId, () => []).add(node);
      }
    }

    // Build readiness entries per family
    final entries = <String, ActionReadinessEntry>{};

    for (final entry in familyGroups.entries) {
      final familyId = entry.key;
      final nodes = entry.value;

      // Check for scoped blockers from graph integrity
      final hasBlockers = _hasIntegrityBlockers(nodes);
      if (hasBlockers) {
        continue; // Skip family with blockers
      }

      // Compute mutation footprint (simplified - use node origins as paths)
      final findingIds = nodes.map((n) => n.id).toSet();
      final physicalPaths = nodes
          .map((n) => _pathFromOrigin(n.origin, project))
          .whereType<String>()
          .toSet();

      if (physicalPaths.isEmpty) {
        continue; // Skip if no valid paths
      }

      final footprint = MutationFootprint(
        findingIds: findingIds,
        physicalPaths: physicalPaths,
        riskScope: ActionRiskScope.boundedFamily,
        familyId: familyId,
      );

      // Determine external consumer exposure
      final hasExternalConsumerExposure =
          project.analysisMode == AnalysisMode.packageInternal;

      // Create entry for each node in family
      for (final node in nodes) {
        entries[node.id] = ActionReadinessEntry(
          adapterId: 'l10n',
          nodeKind: NodeKind.localizationKey,
          familyId: familyId,
          configurationFingerprint: 'static-resolver-v1',
          mutationFootprint: footprint,
          inverseKind: DeterministicInverseKind.proven, // ARB byte-edit proven
          riskScope: ActionRiskScope.boundedFamily,
          hasExternalConsumerExposure: hasExternalConsumerExposure,
        );
      }
    }

    return ActionReadinessIndex(entries);
  }

  String? _extractFamilyId(String nodeId) {
    // Extract family from node ID format: l10n:familyId.key
    final parts = nodeId.split(':');
    if (parts.length < 2) return null;

    final familyAndKey = parts[1];
    final dotIndex = familyAndKey.indexOf('.');
    if (dotIndex == -1) return null;

    return familyAndKey.substring(0, dotIndex);
  }

  String? _pathFromOrigin(Uri origin, ProjectContext project) {
    // Convert URI to relative path
    if (origin.scheme == 'package') {
      final packageName = origin.pathSegments.firstOrNull;
      if (packageName == project.packageName && origin.pathSegments.length > 1) {
        // Own package - extract relative path
        return p.joinAll(origin.pathSegments.skip(1));
      }
    } else if (origin.scheme == 'file') {
      // File URI - make relative to project root
      final filePath = origin.toFilePath();
      final projectPath = project.root.path;
      if (p.isWithin(projectPath, filePath)) {
        return p.relative(filePath, from: projectPath);
      }
    }
    return null;
  }

  bool _hasIntegrityBlockers(List<GraphNode> nodes) {
    // Check if any node has integrity issues that would block action
    for (final node in nodes) {
      final scopedBlockers = (node.metadata['scopedBlockers'] as List<dynamic>?)
          ?.cast<String>() ?? <String>[];

      // Any non-external blocker prevents action
      final hasNonExternalBlockers = scopedBlockers.any(
        (blocker) => blocker != 'externalConsumersNotScanned',
      );

      if (hasNonExternalBlockers) return true;
    }

    return false;
  }
}
