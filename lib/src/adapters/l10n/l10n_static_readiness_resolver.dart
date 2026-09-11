import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/confidence/action_risk_scope.dart';
import '../../core/confidence/mutation_footprint.dart';
import '../../core/confidence/promotion_index.dart';
import '../../core/graph/node.dart';
import '../../core/graph/reachability_graph.dart';
import '../../core/graph/root.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import '../internal/resolver.dart';
import 'arb_inventory.dart';
import 'l10n_config.dart';

/// L10n static action readiness resolver performing bounded static analysis.
final class L10nStaticReadinessResolver implements ActionReadinessResolver {
  /// Creates a resolver for bounded l10n action readiness.
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
      (node) =>
          node.id.startsWith('l10n:') && node.kind == NodeKind.localizationKey,
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

    // Load l10n configuration
    final configResult = L10nConfig.load(project);

    // Handle config loading failures
    final String configFingerprint;
    final L10nConfig config;

    switch (configResult) {
      case L10nConfigAbsent():
        // No config = no l10n setup, skip all families
        return ActionReadinessIndex.empty;

      case L10nConfigInvalid():
        // Invalid config blocks all families - return empty index
        // (Blockers are not part of ActionReadinessIndex API)
        return ActionReadinessIndex.empty;

      case L10nConfigValid():
        // Compute SHA256 fingerprint of l10n.yaml content
        final configPath = p.join(project.root.path, 'l10n.yaml');
        final configFile = File(configPath);
        if (configFile.existsSync()) {
          final configBytes = configFile.readAsBytesSync();
          final hash = sha256.convert(configBytes);
          configFingerprint = 'sha256:${hash.toString()}';
        } else {
          configFingerprint = 'absent';
        }
        config = configResult.config;
    }

    // Read ARB inventory
    final arbInventory = ArbInventory.read(project, config);
    final arbKeys = arbInventory.keys;
    final arbBlockers = arbInventory.blockers;

    // If there are ARB blockers, return empty index (fail-closed)
    if (arbBlockers.isNotEmpty) {
      return ActionReadinessIndex.empty;
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

      // Compute complete mutation footprint
      final findingIds = nodes.map((n) => n.id).toSet();

      // Start with node origins (ARB files)
      final physicalPaths = nodes
          .map((n) => _pathFromOrigin(n.origin, project))
          .whereType<String>()
          .toSet();

      // Add ARB files from inventory (use location field which is project-relative)
      for (final arbKey in arbKeys) {
        physicalPaths.add(arbKey.location);
      }

      // Add generated output paths
      physicalPaths.add(config.generatedLibraryPath);
      physicalPaths.add(config.outputDir);

      // Add l10n.yaml config file
      physicalPaths.add('l10n.yaml');

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
          configurationFingerprint: configFingerprint,
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
      if (packageName == project.packageName &&
          origin.pathSegments.length > 1) {
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
      final scopedBlockers =
          (node.metadata['scopedBlockers'] as List<dynamic>?)?.cast<String>() ??
          <String>[];

      // Any non-external blocker prevents action
      final hasNonExternalBlockers = scopedBlockers.any(
        (blocker) => blocker != 'externalConsumersNotScanned',
      );

      if (hasNonExternalBlockers) return true;
    }

    return false;
  }
}
