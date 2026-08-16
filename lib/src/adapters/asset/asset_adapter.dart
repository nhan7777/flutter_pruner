import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import 'asset_inventory.dart';
import 'asset_reference_resolver.dart';

/// Analyzes Flutter assets and contributes nodes and edges to the graph.
///
/// This adapter discovers assets from `pubspec.yaml` declarations (including
/// package dependencies), finds resolution variants on disk, and semantically
/// resolves asset references through the Dart analyzer.
///
/// What it can see:
/// - `Image.asset('path')` with const string arguments
/// - `AssetImage('path')` constructor calls
/// - `rootBundle.load*('path')` method calls
/// - FlutterGen generated accessors (`.g.dart` files)
///
/// What it cannot see (produces blockers):
/// - Interpolated paths: `'assets/flags/$code.png'`
/// - Dynamic variables: `Image.asset(pathFromServer)`
/// - Complex runtime computation
class AssetAdapter extends AnalyzerAdapter {
  /// Creates an asset adapter.
  const AssetAdapter();

  @override
  String get id => 'assets';

  @override
  String get name => 'Asset analyzer';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'assets',
    displayName: 'Asset analyzer',
    description:
        'Finds Flutter asset families and reports those without an observed live reference.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.asset,
        ruleId: 'PRN-ASSET-001',
        title: 'Unused asset',
        nodeLabel: 'Asset',
        description: 'A declared Flutter asset family that appears unused.',
        measurementKind: 'asset-family-source-bytes',
        details: [
          AdapterReportDetailDefinition(
            key: 'baseSizeBytes',
            label: 'Base asset size',
            valueType: AdapterReportDetailValueType.bytes,
            description:
                'Source bytes in the asset file before resolution variants.',
          ),
          AdapterReportDetailDefinition(
            key: 'variantCount',
            label: 'Variants',
            valueType: AdapterReportDetailValueType.integer,
            description:
                'Number of resolution variants bundled with the asset.',
          ),
          AdapterReportDetailDefinition(
            key: 'variantSizeBytes',
            label: 'Variant size',
            valueType: AdapterReportDetailValueType.bytes,
            description: 'Combined source bytes in all resolution variants.',
          ),
          AdapterReportDetailDefinition(
            key: 'hasTransformers',
            label: 'Asset transformers',
            valueType: AdapterReportDetailValueType.boolean,
            description:
                'Whether Flutter build-time asset transformers are configured.',
          ),
        ],
      ),
    ],
    measurements: [
      AdapterReportMeasurementDefinition(
        kind: 'asset-family-source-bytes',
        label: 'Asset family size',
        unit: 'bytes',
        description: 'Total source bytes across discovered asset families.',
      ),
    ],
  );

  @override
  Set<String> get findingNodeSchemes => const {'asset'};

  @override
  List<String> get dependsOn => const ['dart'];

  @override
  bool appliesTo(ProjectContext project) => project.isFlutterPackage;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    // Phase 1: Discover all assets from pubspecs and disk
    final inventory = await AssetInventory.discover(project);

    // Phase 2: Resolve asset references through analyzer
    final resolver = AssetReferenceResolver(project, inventory);
    await resolver.analyzeProject();

    // Phase 3: Build graph nodes, edges, and blockers
    _buildGraph(project, graph, inventory, resolver);
  }

  void _buildGraph(
    ProjectContext project,
    GraphBuilder graph,
    AssetInventory inventory,
    AssetReferenceResolver resolver,
  ) {
    // 1. Add asset nodes and their resolution variants
    for (final entry in inventory.assets.values) {
      final nodeId = entry.nodeId;

      graph.addNode(
        GraphNode(
          id: nodeId,
          kind: NodeKind.asset,
          origin: entry.sourceUri,
          sizeBytes: entry.familySizeBytes,
          sha256: entry.sha256,
          displayName: entry.logicalKey,
          metadata: {
            'package': entry.package,
            'externallyAddressable': entry.package == project.packageName,
            'baseSizeBytes': entry.sizeBytes,
            'variantCount': entry.variants.length,
            'variantSizeBytes': entry.variants.fold<int>(
              0,
              (total, variant) => total + variant.sizeBytes,
            ),
            'hasTransformers': entry.hasTransformers,
            'declaredByDirectory': entry.declaredByDirectory,
            'removalSupported':
                entry.declaredByDirectory && !entry.hasTransformers,
            'variantPaths': entry.variants
                .map((variant) => variant.sourceUri.toFilePath())
                .toList(),
          },
        ),
      );

      // Add variant nodes and link them to parent
      for (final variant in entry.variants) {
        final variantNodeId = variant.nodeId(entry);

        graph.addNode(
          GraphNode(
            id: variantNodeId,
            kind: NodeKind.assetVariant,
            origin: variant.sourceUri,
            sizeBytes: variant.sizeBytes,
            sha256: variant.sha256,
            displayName: '${variant.ratio}x variant of ${entry.logicalKey}',
          ),
        );

        // Parent asset bundles this variant
        graph.addReference(
          from: nodeId,
          to: variantNodeId,
          kind: EdgeKind.bundlesVariant,
          evidence: graph.evidence(
            kind: EvidenceKind.configuration,
            description: '${variant.ratio}x resolution variant',
            exact: true,
          ),
        );
      }
    }

    // 2. Protect package assets (owned by dependencies)
    for (final pkgAsset in inventory.packageAssets) {
      graph.protect(
        pkgAsset.nodeId,
        reason: 'owned by package ${pkgAsset.package}',
      );
    }

    // 3. Add reference edges from Dart code to assets
    for (final ref in resolver.exactReferences) {
      final assetNodeId = 'asset:${project.packageName}/${ref.logicalKey}';

      // Only add edge if asset exists in inventory
      if (inventory.assets.containsKey(ref.logicalKey)) {
        graph.addReference(
          from: ref.callerId,
          to: assetNodeId,
          kind: EdgeKind.loadsAsset,
          evidence: graph.evidence(
            kind: ref.evidenceKind,
            description: ref.description,
            exact: ref.isExact,
            location: ref.location,
          ),
        );
      }
    }

    // 4. Add blockers for unresolved dynamic constructs
    for (final blocker in resolver.blockers) {
      graph.addBlocker(
        reason: blocker.reason,
        location: blocker.location,
        sourceNodeId: blocker.sourceNodeId,
        affectedNamespace: blocker.affectedNamespace,
        affectedNodeIds: blocker.affectedNodeIds,
      );
    }
  }
}
