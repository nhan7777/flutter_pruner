import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/graph/edge.dart';
import '../../core/graph/evidence.dart';
import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';
import '../dart/dart_analysis_workspace.dart';
import 'arb_inventory.dart';
import 'l10n_config.dart';
import 'l10n_usage_resolver.dart';

/// Analyzes current Flutter gen-l10n ARB declarations and semantic consumers.
///
/// Generated gen-l10n libraries remain protected because their source is
/// produced by Flutter rather than directly editable by Flutter Pruner.
class L10nAdapter extends AnalyzerAdapter {
  /// Creates a gen-l10n analyzer.
  const L10nAdapter();

  @override
  String get id => 'l10n';

  @override
  String get name => 'Localization analyzer (gen-l10n)';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'l10n',
    displayName: 'Localization analyzer (gen-l10n)',
    description:
        'Finds configured ARB messages without a resolved generated-member use.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.localizationKey,
        ruleId: 'PRN-L10N-001',
        title: 'Unused localization key',
        nodeLabel: 'Localization key',
        description:
            'A configured ARB message with no resolved generated-member use.',
        details: [
          AdapterReportDetailDefinition(
            key: 'key',
            label: 'ARB key',
            valueType: AdapterReportDetailValueType.text,
            description: 'Message key declared in the template ARB file.',
          ),
          AdapterReportDetailDefinition(
            key: 'memberKind',
            label: 'Generated member shape',
            valueType: AdapterReportDetailValueType.text,
            description: 'Whether gen-l10n exposes a getter or method.',
          ),
          AdapterReportDetailDefinition(
            key: 'hasPlaceholders',
            label: 'Has placeholders',
            valueType: AdapterReportDetailValueType.boolean,
            description: 'Whether the generated member accepts placeholders.',
          ),
          AdapterReportDetailDefinition(
            key: 'missingLocales',
            label: 'Missing locales',
            valueType: AdapterReportDetailValueType.text,
            description: 'Stable comma-separated locales missing this message.',
          ),
          AdapterReportDetailDefinition(
            key: 'declaredAt',
            label: 'Declared at',
            valueType: AdapterReportDetailValueType.text,
            description: 'Template ARB declaration location.',
          ),
        ],
      ),
    ],
  );

  @override
  Set<String> get findingNodeSchemes => const {'l10n'};

  @override
  List<String> get dependsOn => const ['dart'];

  @override
  bool appliesTo(ProjectContext project) =>
      L10nConfig.load(project).isApplicable;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) =>
      _analyze(project, graph, DartAnalysisWorkspace(project));

  @override
  Future<void> analyzeWithServices(
    ProjectContext project,
    GraphBuilder graph,
    AdapterServices services,
  ) => _analyze(
    project,
    graph,
    services.dartWorkspace ?? DartAnalysisWorkspace(project),
  );

  Future<void> _analyze(
    ProjectContext project,
    GraphBuilder graph,
    DartAnalysisWorkspace workspace,
  ) async {
    final configResult = L10nConfig.load(project);
    switch (configResult) {
      case L10nConfigAbsent():
        return;
      case L10nConfigInvalid(:final reason, :final location):
        graph.addBlocker(
          reason: reason,
          location: location,
          affectedNamespace: ArbInventory.namespaceFor(project),
        );
        graph.addBlocker(
          reason:
              'invalid gen-l10n configuration leaves generated Dart output unknown',
          location: location,
          affectedNamespace: 'dart:${project.packageName}/',
        );
        return;
      case L10nConfigValid(:final config):
        final inventory = ArbInventory.read(project, config);
        final resolver = L10nUsageResolver(project, config, inventory);
        await resolver.analyzeProject(workspace: workspace);

        for (final key in inventory.keys) {
          graph.addNode(
            GraphNode(
              id: key.nodeId,
              kind: NodeKind.localizationKey,
              origin: key.origin,
              displayName: key.key,
              metadata: {
                'key': key.key,
                'memberKind': key.memberKind.name,
                'hasPlaceholders': key.hasPlaceholders,
                'missingLocales': key.missingLocales,
                'declaredAt': key.location,
              },
            ),
          );
        }

        for (final reference in resolver.references) {
          graph.addReference(
            from: reference.callerId,
            to: reference.l10nNodeId,
            kind: EdgeKind.references,
            evidence: graph.evidence(
              kind: EvidenceKind.generatedAccessor,
              description: reference.description,
              exact: true,
              location: reference.location,
            ),
          );
        }

        for (final blocker in inventory.blockers) {
          graph.addBlocker(
            reason: blocker.reason,
            location: blocker.location,
            affectedNamespace: blocker.affectedNamespace,
            affectedNodeIds: blocker.affectedNodeIds,
          );
        }
        for (final blocker in resolver.blockers) {
          graph.addBlocker(
            reason: blocker.reason,
            location: blocker.location,
            sourceNodeId: blocker.sourceNodeId,
            affectedNamespace: blocker.affectedNamespace,
            affectedNodeIds: blocker.affectedNodeIds,
          );
        }
        final generatedOutput = _generatedOutputProtection(project, config);
        final generatedNamespaces = <String>{
          ...resolver.generatedDartNamespaces,
          ...generatedOutput.exactNamespaces,
        }.toList()..sort();
        for (final namespace in generatedNamespaces) {
          graph.addBlocker(
            reason: 'configured gen-l10n generated Dart output is not editable',
            location: namespace.substring(
              'dart:${project.packageName}/'.length,
            ),
            affectedNamespace: namespace,
          );
        }
        final familyNamespace = generatedOutput.familyNamespace;
        if (familyNamespace != null) {
          graph.addBlocker(
            reason: 'gen-l10n output family could not be enumerated completely',
            location: project.relative(config.outputDir),
            affectedNamespace: familyNamespace,
          );
        }
    }
  }
}

final class _GeneratedOutputProtection {
  const _GeneratedOutputProtection({
    required this.exactNamespaces,
    this.familyNamespace,
  });

  final Set<String> exactNamespaces;
  final String? familyNamespace;
}

final class _GeneratedOutputFamily {
  _GeneratedOutputFamily(String outputLocalizationFile)
    : stem = _stem(p.basename(outputLocalizationFile)),
      suffix = _suffix(p.basename(outputLocalizationFile));

  final String stem;
  final String suffix;

  static String _stem(String filename) {
    final firstDot = filename.indexOf('.');
    return firstDot > 0 ? filename.substring(0, firstDot) : filename;
  }

  static String _suffix(String filename) {
    final firstDot = filename.indexOf('.');
    return firstDot > 0 ? filename.substring(firstDot) : '.dart';
  }
}

_GeneratedOutputProtection _generatedOutputProtection(
  ProjectContext project,
  L10nConfig config,
) {
  final exactNamespaces = <String>{
    _dartNamespaceForPath(project, config.generatedLibraryPath),
  };
  final family = _GeneratedOutputFamily(config.outputLocalizationFile);
  final familyNamespace = _dartNamespaceForPath(
    project,
    p.join(config.outputDir, '${family.stem}_'),
  );
  var isIncomplete = false;
  final resolvedRoot = _tryCanonicalExistingPath(project.root.path);
  final canonicalRoot = resolvedRoot ?? _canonicalPath(project.root.path);
  if (resolvedRoot == null) isIncomplete = true;
  final outputDirectory = Directory(config.outputDir);

  try {
    if (FileSystemEntity.typeSync(outputDirectory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      isIncomplete = true;
    } else {
      for (final entity in outputDirectory.listSync(followLinks: false)) {
        final filename = p.basename(entity.path);
        if (!filename.startsWith('${family.stem}_') ||
            !filename.endsWith(family.suffix)) {
          continue;
        }
        if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
            FileSystemEntityType.file) {
          isIncomplete = true;
          continue;
        }
        final canonicalCandidate = _tryCanonicalExistingPath(entity.path);
        if (canonicalCandidate == null) {
          isIncomplete = true;
          continue;
        }
        if (!_isWithin(canonicalRoot, canonicalCandidate)) {
          isIncomplete = true;
          continue;
        }
        exactNamespaces.add(_dartNamespaceForPath(project, canonicalCandidate));
      }
    }
  } on FileSystemException {
    isIncomplete = true;
  }

  return _GeneratedOutputProtection(
    exactNamespaces: Set.unmodifiable(exactNamespaces),
    familyNamespace: isIncomplete ? familyNamespace : null,
  );
}

String _dartNamespaceForPath(ProjectContext project, String path) {
  final root = _canonicalPath(project.root.path);
  final candidate = _canonicalPath(path);
  final relative = p.relative(candidate, from: root).replaceAll(r'\', '/');
  return 'dart:${project.packageName}/$relative';
}

String _canonicalPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return p.normalize(p.absolute(path));
  }
}

String? _tryCanonicalExistingPath(String path) {
  try {
    return File(path).resolveSymbolicLinksSync();
  } on FileSystemException {
    return null;
  }
}

bool _isWithin(String root, String candidate) =>
    p.equals(root, candidate) || p.isWithin(root, candidate);
