import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/graph/node.dart';
import '../../core/project/project_context.dart';
import '../adapter_report_definition.dart';
import '../analyzer_adapter.dart';

/// Computes a stable content digest for one file.
typedef FileDigestComputer = Future<String> Function(File file);

/// Detects byte-identical files by SHA-256 hash.
///
/// The simplest complete adapter. Groups files by content hash and reports
/// duplicate groups where N>1 identical files exist. Choosing which copy to
/// keep is a human decision, so findings are always `Confidence.review`.
///
/// ## What it reports
///
/// One node per duplicate group (not per file), with all paths in metadata.
/// The reported size is waste: (N-1) × fileSize, since keeping one copy is
/// necessary.
///
/// ## Why this is never SAFE
///
/// All copies are semantically equivalent, but they may serve different
/// purposes:
/// - One in `assets/`, one in `lib/images/`
/// - One referenced by code, one not
/// - One for iOS, one for Android (even if identical)
///
/// The user must decide which to keep. `ruleAllowsAutoFix` fails.
///
/// Detects and reports duplicate files in the project by content hash.
class DuplicateAdapter extends AnalyzerAdapter {
  /// Creates a duplicate file detector adapter.
  const DuplicateAdapter({FileDigestComputer? fileDigestComputer})
    : _fileDigestComputer = fileDigestComputer;

  final FileDigestComputer? _fileDigestComputer;

  @override
  String get id => 'duplicates';

  @override
  String get name => 'Duplicate file detector';

  @override
  AdapterReportDefinition get reportDefinition => AdapterReportDefinition(
    adapterId: 'duplicates',
    displayName: 'Duplicate file detector',
    description:
        'Groups byte-identical files so a user can choose a canonical copy.',
    findings: [
      AdapterFindingReportDefinition(
        nodeKind: NodeKind.duplicateGroup,
        ruleId: 'PRN-DUP-001',
        title: 'Duplicate file',
        nodeLabel: 'Duplicate files',
        description:
            'A group of byte-identical files that needs a canonical choice.',
        measurementKind: 'duplicate-potential-reclaimable-bytes',
        details: [
          AdapterReportDetailDefinition(
            key: 'paths',
            label: 'Files',
            valueType: AdapterReportDetailValueType.paths,
            description:
                'Project-relative paths of identical files in this group.',
          ),
          AdapterReportDetailDefinition(
            key: 'fileCount',
            label: 'Files',
            valueType: AdapterReportDetailValueType.integer,
            description: 'Number of identical files in the group.',
          ),
          AdapterReportDetailDefinition(
            key: 'sizePerFile',
            label: 'Size per file',
            valueType: AdapterReportDetailValueType.bytes,
            description: 'Source bytes in each identical file.',
          ),
          AdapterReportDetailDefinition(
            key: 'groupSourceBytes',
            label: 'Duplicate group size',
            valueType: AdapterReportDetailValueType.bytes,
            description: 'Combined source bytes of every file in the group.',
          ),
          AdapterReportDetailDefinition(
            key: 'potentialReclaimableBytes',
            label: 'Potential savings',
            valueType: AdapterReportDetailValueType.bytes,
            description:
                'Source bytes reclaimable after retaining one canonical file.',
          ),
        ],
      ),
    ],
    measurements: [
      AdapterReportMeasurementDefinition(
        kind: 'duplicate-potential-reclaimable-bytes',
        label: 'Potential duplicate savings',
        unit: 'bytes',
        description:
            'Total source bytes reclaimable within detected duplicate groups.',
      ),
    ],
  );

  @override
  Set<String> get findingNodeSchemes => const {'duplicate'};

  @override
  bool appliesTo(ProjectContext project) => true;

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    final candidates = await _collectCandidateFiles(project);
    final byHash = await _groupByHash(candidates);

    for (final entry in byHash.entries) {
      if (entry.value.length < 2) continue;

      final hash = entry.key;
      final files = entry.value;
      final sizePerFile = await files.first.length();
      final waste = sizePerFile * (files.length - 1);

      final paths = files.map((f) => project.relative(f.path)).toList()..sort();

      final nodeId =
          'duplicate:${project.packageName}:${hash.substring(0, 12)}';

      graph.addNode(
        GraphNode(
          id: nodeId,
          kind: NodeKind.duplicateGroup,
          origin: files.first.uri,
          sizeBytes: waste,
          sha256: hash,
          displayName: '${files.length} identical files',
          metadata: {
            'paths': paths,
            'fileCount': files.length,
            'sizePerFile': sizePerFile,
            'groupSourceBytes': sizePerFile * files.length,
            'potentialReclaimableBytes': waste,
          },
        ),
      );

      if (_hasPackageOwnedFile(files)) {
        graph.protect(
          nodeId,
          reason: 'at least one copy is owned by a dependency package',
        );
      }
    }
  }

  Future<List<File>> _collectCandidateFiles(ProjectContext project) async {
    final candidates = <File>[];
    final root = Directory(project.root.path);

    final pending = <Directory>[root];
    while (pending.isNotEmpty) {
      final directory = pending.removeLast();
      await for (final entity in directory.list(followLinks: false)) {
        if (project.pathPolicy.shouldExcludeTraversalEntry(entity)) continue;
        if (entity is Directory) {
          pending.add(entity);
        } else if (entity is File && !_shouldExcludeFile(entity.path)) {
          candidates.add(entity);
        }
      }
    }

    return candidates;
  }

  bool _shouldExcludeFile(String path) {
    final normalized = path.replaceAll(r'\', '/');

    final basename = normalized.split('/').last;

    if (basename.startsWith('.')) return true;
    if (basename == 'pubspec.lock') return true;
    if (basename == 'Thumbs.db') return true;
    if (basename == '.DS_Store') return true;

    if (basename.endsWith('.g.dart')) return true;
    if (basename.endsWith('.freezed.dart')) return true;
    if (basename.endsWith('.gr.dart')) return true;

    return false;
  }

  Future<Map<String, List<File>>> _groupByHash(List<File> files) async {
    final bySize = <int, List<File>>{};
    for (final file in files) {
      try {
        final size = await file.length();
        (bySize[size] ??= []).add(file);
      } on FileSystemException {
        continue;
      }
    }

    final byHash = <String, List<File>>{};
    for (final sameSizeFiles in bySize.values) {
      if (sameSizeFiles.length < 2) continue;
      for (final file in sameSizeFiles) {
        try {
          final hash = await _computeSha256(file);
          (byHash[hash] ??= []).add(file);
        } on FileSystemException {
          continue;
        }
      }
    }

    return byHash;
  }

  Future<String> _computeSha256(File file) async =>
      _fileDigestComputer?.call(file) ??
      (await sha256.bind(file.openRead()).first).toString();

  bool _hasPackageOwnedFile(List<File> files) {
    return files.any((f) => f.path.contains('/.pub-cache/'));
  }
}
