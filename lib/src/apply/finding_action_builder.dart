import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/confidence/action_capability.dart';
import '../core/confidence/finding.dart';
import '../core/graph/edge.dart';
import '../core/graph/node.dart';
import '../core/graph/reachability_graph.dart';
import '../core/project/project_context.dart';

/// Mechanical operation represented by one reversible file snapshot.
enum FindingActionOperation {
  /// Remove the finding represented by the source node.
  removeFinding,

  /// Remove one exact import or export directive.
  cleanupImports,

  /// Delete a whole source, asset, or generated companion file.
  deleteFile,
}

/// One physical operation required to apply an atomic finding unit.
class FindingActionDescriptor {
  /// Creates an immutable action descriptor.
  const FindingActionDescriptor({
    required this.finding,
    required this.file,
    required this.operation,
    required this.atomicGroup,
    this.label,
    this.findingId,
    this.countsTowardSummary = true,
    this.cleanupTargetPath,
  });

  /// Finding authorizing this operation.
  final Finding finding;

  /// Physical path snapshotted before mutation.
  final File file;

  /// Exact operation implemented by the executor.
  final FindingActionOperation operation;

  /// Planner SCC that owns this operation.
  final String atomicGroup;

  /// Optional operation-specific label.
  final String? label;

  /// Optional journal finding ID for auxiliary edits.
  final String? findingId;

  /// Whether this auxiliary operation counts as a removed finding.
  final bool countsTowardSummary;

  /// Library path referenced by an import/export cleanup.
  final String? cleanupTargetPath;
}

/// Converts classified findings into explicit reversible file operations.
class FindingActionBuilder {
  /// Creates the stateless builder.
  const FindingActionBuilder();

  /// Builds every operation owned by one planner atomic unit.
  List<FindingActionDescriptor> build({
    required List<Finding> findings,
    required ReachabilityGraph graph,
    required ProjectContext project,
    required String atomicGroup,
  }) {
    final actions = <FindingActionDescriptor>[];
    final scheduledLibraryPaths = findings
        .where((finding) => finding.node.kind == NodeKind.dartLibrary)
        .where((finding) => finding.node.origin.scheme == 'file')
        .map((finding) => p.normalize(finding.node.origin.toFilePath()))
        .toSet();

    for (final finding in findings) {
      final adapterId = finding.reportingAdapterId;
      if (adapterId == null) {
        throw StateError(
          'Finding has no reporting adapter identity: ${finding.node.id}',
        );
      }
      final capability = ActionCapability.forFinding(
        adapterId: adapterId,
        node: finding.node,
      );
      if (!capability.supported) {
        throw StateError(
          'Finding has no core-owned apply capability: '
          '$adapterId/${finding.ruleId}/${finding.node.kind.name}',
        );
      }
      if (finding.node.origin.scheme != 'file') {
        throw StateError('Finding has no physical file: ${finding.node.id}');
      }
      final sourceFile = File.fromUri(finding.node.origin);
      if (finding.node.kind == NodeKind.asset) {
        final variantPaths =
            finding.node.metadata['variantPaths'] as List<Object?>? ?? const [];
        for (final value in variantPaths) {
          if (value is! String) continue;
          final variantFile = File(value);
          if (!variantFile.existsSync()) continue;
          actions.add(
            FindingActionDescriptor(
              finding: finding,
              file: variantFile,
              operation: FindingActionOperation.deleteFile,
              atomicGroup: atomicGroup,
              label: 'resolution variant ${project.relative(value)}',
              findingId:
                  '${finding.node.id}@variant:${project.relative(value)}',
              countsTowardSummary: false,
            ),
          );
        }
        actions.add(
          FindingActionDescriptor(
            finding: finding,
            file: sourceFile,
            operation: FindingActionOperation.removeFinding,
            atomicGroup: atomicGroup,
          ),
        );
        continue;
      }
      if (finding.node.kind != NodeKind.dartLibrary) {
        actions.add(
          FindingActionDescriptor(
            finding: finding,
            file: sourceFile,
            operation: FindingActionOperation.removeFinding,
            atomicGroup: atomicGroup,
          ),
        );
        continue;
      }

      final importerPaths = <String>{};
      for (final edge in graph.incomingTo(finding.node.id)) {
        if (edge.kind != EdgeKind.imports ||
            (edge.evidence.description != 'import directive' &&
                edge.evidence.description != 'export directive')) {
          continue;
        }
        final importer = projectFileForLibrary(
          graph.node(edge.from),
          edge.from,
          project,
        );
        if (importer == null || !importer.existsSync()) continue;
        final normalized = p.normalize(importer.path);
        if (normalized == p.normalize(sourceFile.path) ||
            scheduledLibraryPaths.contains(normalized) ||
            !importerPaths.add(normalized)) {
          continue;
        }
        final directiveKind = edge.evidence.description.startsWith('export')
            ? 'export'
            : 'import';
        actions.add(
          FindingActionDescriptor(
            finding: finding,
            file: importer,
            operation: FindingActionOperation.cleanupImports,
            atomicGroup: atomicGroup,
            label: 'stale $directiveKind in ${project.relative(importer.path)}',
            findingId:
                '${finding.node.id}@$directiveKind:'
                '${project.relative(importer.path)}',
            countsTowardSummary: false,
            cleanupTargetPath: sourceFile.path,
          ),
        );
      }

      final generatedPaths =
          finding.node.metadata['generatedPartPaths'] as List<Object?>? ??
          const [];
      for (final value in generatedPaths) {
        if (value is! String) continue;
        final generatedFile = File(value);
        if (!generatedFile.existsSync()) continue;
        actions.add(
          FindingActionDescriptor(
            finding: finding,
            file: generatedFile,
            operation: FindingActionOperation.deleteFile,
            atomicGroup: atomicGroup,
            label: 'generated companion ${project.relative(value)}',
            findingId:
                '${finding.node.id}@generated:${project.relative(value)}',
            countsTowardSummary: false,
          ),
        );
      }

      actions.add(
        FindingActionDescriptor(
          finding: finding,
          file: sourceFile,
          operation: FindingActionOperation.deleteFile,
          atomicGroup: atomicGroup,
          label: project.relative(sourceFile.path),
        ),
      );
    }
    return actions;
  }

  /// Resolves a graph library ID back to an in-project physical file.
  static File? projectFileForLibrary(
    GraphNode? node,
    String nodeId,
    ProjectContext project,
  ) {
    if (node?.origin.scheme == 'file') return File.fromUri(node!.origin);

    final idPrefix = 'dart:${project.packageName}/';
    if (!nodeId.startsWith(idPrefix)) return null;
    final encodedPath = nodeId.substring(idPrefix.length);
    final packagePrefix = 'package:${project.packageName}/';
    if (encodedPath.startsWith(packagePrefix)) {
      final packagePath = encodedPath.substring(packagePrefix.length);
      return File(project.resolve(p.join('lib', packagePath)));
    }
    if (encodedPath.startsWith('lib/') ||
        encodedPath.startsWith('bin/') ||
        encodedPath.startsWith('test/')) {
      return File(project.resolve(encodedPath));
    }
    return null;
  }
}
