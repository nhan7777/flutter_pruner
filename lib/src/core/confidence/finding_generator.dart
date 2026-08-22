import '../../adapters/adapter_report_definition.dart';
import '../graph/build_condition.dart';
import '../graph/evidence.dart';
import '../graph/node.dart';
import '../graph/reachability_graph.dart';
import '../graph/root.dart';
import '../project/analysis_mode.dart';
import '../project/project_context.dart';
import 'action_capability.dart';
import 'classification_reason.dart';
import 'confidence.dart';
import 'confidence_classifier.dart';
import 'finding.dart';
import 'finding_assessment.dart';

/// Converts graph reachability results into actionable findings.
///
/// The engine asks one question: "what is unreachable?" This class asks the
/// follow-up: "how confident are we, and why?"
class FindingGenerator {
  /// Creates a finding generator.
  const FindingGenerator();

  /// Generates findings from [graph] for [project].
  ///
  /// Returns findings sorted by confidence (protected first, safe last) then
  /// by node id for stability.
  List<Finding> generate({
    required ReachabilityGraph graph,
    required ProjectContext project,
    required GraphIntegrity graphIntegrity,
    List<BuildTarget>? targets,
    Set<String>? reportingNodeSchemes,
    Map<String, AdapterReportDefinition> adapterReportDefinitions = const {},
  }) {
    final findings = <Finding>[];
    final effectiveTargets = targets ?? project.targets;
    if (effectiveTargets.isEmpty) {
      throw ArgumentError.value(
        effectiveTargets,
        'targets',
        'At least one configured build target is required.',
      );
    }
    final analysisCoverageComplete =
        project.analysisCoverageComplete &&
        _targetsExactlyEquivalent(effectiveTargets, project.targets);
    if (!_targetsExactlyEquivalent(
      effectiveTargets,
      graphIntegrity.configuredTargets.toList(),
    )) {
      throw StateError(
        'Graph integrity targets do not match the finding target matrix.',
      );
    }
    final graphIntegrityComplete = graphIntegrity.complete;

    final auxiliaryReachability = graph.analyzeAuxiliary();
    final reachability = _projectFindingReachability(
      nodes: graph.nodes,
      graphIntegrity: graphIntegrity,
      configured: [
        for (final target in effectiveTargets)
          _ConfiguredReachability(
            target: target,
            reachability: graph.analyzeFor(target),
          ),
      ],
      auxiliary: auxiliaryReachability,
    );

    for (final entry in reachability.candidates.entries) {
      final nodeId = entry.key;
      final node = graph.node(nodeId);
      if (node == null) continue;
      if (!_isReportable(node)) continue;
      if (reportingNodeSchemes != null &&
          !reportingNodeSchemes.contains(_nodeScheme(node))) {
        continue;
      }

      final finding = _createFinding(
        node: node,
        graph: graph,
        project: project,
        retainedAnywhere: reachability.retainedNodeIds,
        reachability: entry.value,
        adapterReportDefinitions: adapterReportDefinitions,
        graphIntegrityComplete: graphIntegrityComplete,
        analysisCoverageComplete: analysisCoverageComplete,
      );

      findings.add(finding);
    }

    // Sort: protected first, then review, high, safe
    // Within each tier, sort by node id for stability
    findings.sort((a, b) {
      final confCompare = a.confidence.index.compareTo(b.confidence.index);
      if (confCompare != 0) return confCompare;
      return a.node.id.compareTo(b.node.id);
    });

    return findings;
  }

  /// A target override can only preserve a complete-coverage assertion when
  /// it represents every declared target with the same build-defining fields.
  bool _targetsExactlyEquivalent(
    List<BuildTarget> effectiveTargets,
    List<BuildTarget> declaredTargets,
  ) {
    if (effectiveTargets.length != declaredTargets.length) return false;
    final unmatched = List<BuildTarget>.from(declaredTargets);
    for (final target in effectiveTargets) {
      final index = unmatched.indexWhere(
        (declared) => _sameTarget(target, declared),
      );
      if (index < 0) return false;
      unmatched.removeAt(index);
    }
    return unmatched.isEmpty;
  }

  bool _sameTarget(BuildTarget left, BuildTarget right) {
    if (left.name != right.name ||
        left.platform != right.platform ||
        left.entrypoint != right.entrypoint ||
        left.flavor != right.flavor ||
        left.dartDefines.length != right.dartDefines.length) {
      return false;
    }
    for (final define in left.dartDefines.entries) {
      if (right.dartDefines[define.key] != define.value) return false;
    }
    return true;
  }

  bool _isReportable(GraphNode node) =>
      node.kind != NodeKind.assetVariant &&
      node.kind != NodeKind.generatedArtifact &&
      node.kind != NodeKind.package &&
      node.kind != NodeKind.entrypoint;

  String _nodeScheme(GraphNode node) {
    final separator = node.id.indexOf(':');
    return separator < 0 ? node.id : node.id.substring(0, separator);
  }

  Finding _createFinding({
    required GraphNode node,
    required ReachabilityGraph graph,
    required ProjectContext project,
    required Set<String> retainedAnywhere,
    required _NodeFindingReachability reachability,
    required Map<String, AdapterReportDefinition> adapterReportDefinitions,
    required bool graphIntegrityComplete,
    required bool analysisCoverageComplete,
  }) {
    final protectionReasons = graph.protectionReasons(node.id);
    final isProtected = protectionReasons.isNotEmpty;

    // Collect blockers that affect this node
    final relevantBlockers = graph
        .blockersFor(node.id)
        .where((blocker) {
          final sourceNodeId = blocker.sourceNodeId;
          if (sourceNodeId == null || !graph.hasNode(sourceNodeId)) return true;
          return retainedAnywhere.contains(sourceNodeId);
        })
        .toList(growable: false);

    final hasDynamicBlockers =
        relevantBlockers.isNotEmpty || !graphIntegrityComplete;
    final reportingAdapterId =
        graph.nodeOwner(node.id) ?? _inferredAdapterId(node);
    final adapterDefinition = adapterReportDefinitions[reportingAdapterId];
    final findingDefinition = adapterDefinition?.findingFor(node.kind);
    final hasAdapterCatalog = adapterDefinition != null;
    final ruleId =
        findingDefinition?.ruleId ??
        (hasAdapterCatalog ? 'PRN-UNKNOWN-001' : _ruleIdFor(node));
    final capability = ActionCapability.forFinding(
      adapterId: reportingAdapterId,
      node: node,
    );

    // Gather evidence (incoming edges)
    final incomingEdges = graph.incomingTo(node.id);
    final evidence = incomingEdges.map((e) => e.evidence).toList();

    // Compute safety predicates
    final predicates = SafetyPredicates(
      ruleAllowsAutoFix: capability.supported,
      unreachableAcrossAllTargets: reachability.unreachableAcrossAllTargets,
      notRetained: reachability.notRetained,
      noDynamicBlockers: !hasDynamicBlockers,
      notProtected: !isProtected,
      noPublicApiRisk: !_hasExternalConsumerRisk(node, project),
      hasDeterministicInverse: capability.deterministicInverse,
      analysisCoverageComplete: analysisCoverageComplete,
      actionSupported: capability.supported,
    );

    final manualRisks = <ManualRisk>{
      if (!predicates.noPublicApiRisk) ManualRisk.externalConsumersNotScanned,
      if (capability.scope == ActionScope.broad && capability.supported)
        ManualRisk.broadRemovalScope,
    };
    final assessment = FindingAssessment(
      node: node,
      predicates: predicates,
      actionCapability: capability,
      isProtected: isProtected,
      hasDynamicBlockers: hasDynamicBlockers,
      manualRisks: manualRisks,
    );
    final classified = const ConfidenceClassifier().classify(assessment);
    final confidence =
        project.analysisMode == AnalysisMode.package &&
            classified != Confidence.protected
        ? Confidence.review
        : classified;
    final classificationReasons = _classificationReasons(
      node: node,
      project: project,
      blockers: relevantBlockers,
      capability: capability,
      manualRisks: manualRisks,
      graphIntegrityComplete: graphIntegrityComplete,
      analysisCoverageComplete: analysisCoverageComplete,
      retainedOnly:
          reachability.unreachableAcrossAllTargets && !reachability.notRetained,
    );

    return Finding(
      ruleId: ruleId,
      node: node,
      confidence: confidence,
      title: _titleFor(
        node,
        findingDefinition,
        useLegacyFallback: !hasAdapterCatalog,
      ),
      predicates: predicates,
      evidence: evidence,
      blockers: relevantBlockers,
      protectionReasons: protectionReasons,
      unreachableIn: reachability.unreachableIn,
      reachableIn: reachability.reachableIn,
      retainedIn: reachability.retainedIn,
      auxiliaryRetainedIn: reachability.auxiliaryRetainedIn,
      proposedAction:
          confidence == Confidence.safe || confidence == Confidence.high
          ? capability.proposedAction
          : null,
      sourceBytes: node.sizeBytes,
      classificationReasons: classificationReasons,
      manualRisks: Set.unmodifiable(manualRisks),
      reportingAdapterId: reportingAdapterId,
    );
  }

  List<ClassificationReason> _classificationReasons({
    required GraphNode node,
    required ProjectContext project,
    required List<Blocker> blockers,
    required ActionCapability capability,
    required Set<ManualRisk> manualRisks,
    required bool graphIntegrityComplete,
    required bool analysisCoverageComplete,
    required bool retainedOnly,
  }) {
    final reasons = <ClassificationReason>[];
    if (!project.targetMatrix.isComplete || !analysisCoverageComplete) {
      reasons.add(ClassificationReason.incompleteTargetMatrix);
    }
    if (!project.rootCoverage.internalBoundaryComplete) {
      reasons.add(ClassificationReason.incompleteRootCoverage);
    }
    if (project.analysisMode == AnalysisMode.package) {
      reasons.add(ClassificationReason.packageReviewOnly);
    }
    if (!graphIntegrityComplete) {
      reasons.add(ClassificationReason.incompleteGraphIntegrity);
    }
    if (retainedOnly) {
      reasons.add(ClassificationReason.retainedOnly);
    }
    if (node.kind == NodeKind.duplicateGroup) {
      reasons.add(ClassificationReason.duplicateCanonicalChoice);
    }
    if (blockers.isNotEmpty) {
      final generated = blockers.any(
        (blocker) => blocker.reason.toLowerCase().contains('generated'),
      );
      reasons.add(
        generated
            ? ClassificationReason.generatedCodeUncertainty
            : ClassificationReason.dynamicReference,
      );
    }
    if (!capability.supported) {
      reasons.add(ClassificationReason.unsupportedAction);
    }
    if (!capability.deterministicInverse) {
      reasons.add(ClassificationReason.nonDeterministicInverse);
    }
    if (manualRisks.contains(ManualRisk.externalConsumersNotScanned)) {
      reasons.add(ClassificationReason.externalConsumersNotScanned);
    }
    if (manualRisks.contains(ManualRisk.broadRemovalScope)) {
      reasons.add(ClassificationReason.broadRemovalScope);
    }
    return reasons;
  }

  bool _hasExternalConsumerRisk(GraphNode node, ProjectContext project) =>
      project.analysisMode == AnalysisMode.packageInternal &&
      node.metadata['externallyAddressable'] == true;

  String _ruleIdFor(GraphNode node) {
    return switch (node.kind) {
      NodeKind.asset => 'PRN-ASSET-001',
      NodeKind.duplicateGroup => 'PRN-DUP-001',
      NodeKind.declaration => 'PRN-DART-001',
      NodeKind.dartLibrary => 'PRN-DART-002',
      NodeKind.analyzerDiagnostic => 'PRN-DART-003',
      NodeKind.route => 'PRN-ROUTE-001',
      NodeKind.localizationKey => 'PRN-L10N-001',
      NodeKind.diRegistration => 'PRN-DI-001',
      _ => 'PRN-UNKNOWN-001',
    };
  }

  String _titleFor(
    GraphNode node,
    AdapterFindingReportDefinition? definition, {
    required bool useLegacyFallback,
  }) {
    final name = node.displayName ?? node.id;
    if (definition != null) return '${definition.title}: $name';
    if (!useLegacyFallback) return 'Unknown finding: $name';
    return switch (node.kind) {
      NodeKind.asset => 'Unused asset: $name',
      NodeKind.duplicateGroup => 'Duplicate file: $name',
      NodeKind.declaration => 'Unreachable declaration: $name',
      NodeKind.dartLibrary => 'Unreachable library: $name',
      NodeKind.analyzerDiagnostic => 'Analyzer unused diagnostic: $name',
      NodeKind.route => 'Unused route: $name',
      NodeKind.localizationKey => 'Unused localization key: $name',
      NodeKind.diRegistration => 'Unused DI registration: $name',
      _ => 'Unknown finding: $name',
    };
  }

  String _inferredAdapterId(GraphNode node) => switch (_nodeScheme(node)) {
    'asset' => 'assets',
    'duplicate' => 'duplicates',
    final scheme => scheme,
  };
}

final class _ConfiguredReachability {
  const _ConfiguredReachability({
    required this.target,
    required this.reachability,
  });

  final BuildTarget target;
  final TargetReachability reachability;
}

final class _NodeFindingReachability {
  _NodeFindingReachability({
    required Iterable<String> reachableIn,
    required Iterable<String> unreachableIn,
    required Iterable<String> retainedIn,
    required Iterable<String> auxiliaryRetainedIn,
    required this.unreachableAcrossAllTargets,
  }) : reachableIn = _sortedIdentities(reachableIn),
       unreachableIn = _sortedIdentities(unreachableIn),
       retainedIn = _sortedIdentities(retainedIn),
       auxiliaryRetainedIn = _sortedIdentities(auxiliaryRetainedIn);

  final List<String> reachableIn;
  final List<String> unreachableIn;
  final List<String> retainedIn;
  final List<String> auxiliaryRetainedIn;
  final bool unreachableAcrossAllTargets;

  bool get notRetained => retainedIn.isEmpty && auxiliaryRetainedIn.isEmpty;
}

final class _FindingReachabilityProjection {
  _FindingReachabilityProjection({
    required Map<String, _NodeFindingReachability> candidates,
    required Set<String> retainedNodeIds,
  }) : candidates = Map.unmodifiable(candidates),
       retainedNodeIds = Set.unmodifiable(retainedNodeIds);

  final Map<String, _NodeFindingReachability> candidates;
  final Set<String> retainedNodeIds;
}

_FindingReachabilityProjection _projectFindingReachability({
  required Iterable<GraphNode> nodes,
  required GraphIntegrity graphIntegrity,
  required List<_ConfiguredReachability> configured,
  required AuxiliaryReachability auxiliary,
}) {
  final configuredTargets = configured
      .map((entry) => BuildTarget.snapshot(entry.target))
      .toSet();
  if (configuredTargets.length != graphIntegrity.configuredTargets.length ||
      !configuredTargets.containsAll(graphIntegrity.configuredTargets)) {
    throw StateError(
      'Configured reachability does not match the graph integrity snapshot.',
    );
  }

  final retainedNodeIds = <String>{
    ...auxiliary.retained,
    for (final entry in configured) ...entry.reachability.configuredRetained,
  };
  final candidates = <String, _NodeFindingReachability>{};
  for (final node in nodes) {
    final reachableIn = <String>{
      for (final entry in configured)
        if (entry.reachability.configuredProven.contains(node.id))
          entry.target.name,
    };
    final auxiliaryProven = auxiliary.proven.contains(node.id);
    if (reachableIn.isNotEmpty || auxiliaryProven) {
      continue;
    }

    candidates[node.id] = _NodeFindingReachability(
      reachableIn: reachableIn,
      unreachableIn: {
        for (final entry in configured)
          if (!entry.reachability.configuredProven.contains(node.id))
            entry.target.name,
      },
      retainedIn: {
        for (final entry in configured)
          if (entry.reachability.configuredRetained.contains(node.id))
            entry.target.name,
      },
      auxiliaryRetainedIn: {
        for (final entry in auxiliary.retainedByExecutionTarget.entries)
          if (entry.value.contains(node.id)) entry.key,
      },
      unreachableAcrossAllTargets: reachableIn.isEmpty && !auxiliaryProven,
    );
  }
  return _FindingReachabilityProjection(
    candidates: candidates,
    retainedNodeIds: retainedNodeIds,
  );
}

List<String> _sortedIdentities(Iterable<String> values) {
  final sorted = values.toSet().toList()..sort();
  return List.unmodifiable(sorted);
}
