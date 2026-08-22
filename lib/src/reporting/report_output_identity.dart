import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/project/tool_workspace.dart';
import 'immutable_report_store.dart';
import 'recoverable_report_writer.dart';
import 'report_object_backend.dart';

/// Immutable filesystem identities for one explicitly selected report output.
final class FrozenReportOutputIdentity {
  FrozenReportOutputIdentity._({
    required this.destination,
    required List<String> projectExclusions,
  }) : projectExclusions = List.unmodifiable(projectExclusions);

  /// Resolves the output once and freezes every selected-project spelling that
  /// must be excluded before analysis begins.
  static Future<FrozenReportOutputIdentity> resolve({
    RecoverableReportWriter? writer,
    required File requested,
    required Directory selectedProjectRoot,
  }) async {
    final destination = writer == null
        ? _resolveSingleAssignmentDestination(requested)
        : await writer.resolve(requested);
    final exclusions = <String>[];

    void addExclusion(String path) {
      if (exclusions.any((existing) => p.equals(existing, path))) return;
      exclusions.add(path);
    }

    addExclusion(destination.requestedPath);
    addExclusion(destination.canonicalPath);
    final adjacentCommitPath = _adjacentCommitPath(destination.canonicalPath);
    addExclusion(adjacentCommitPath);
    final requestedType = FileSystemEntity.typeSync(
      destination.requestedPath,
      followLinks: false,
    );
    if (requestedType != FileSystemEntityType.notFound) {
      try {
        addExclusion(
          File(destination.requestedPath).resolveSymbolicLinksSync(),
        );
      } on FileSystemException {
        // The later retained no-follow preflight owns the final decision.
      }
    }

    final canonicalProjectRoot = p.normalize(
      selectedProjectRoot.resolveSymbolicLinksSync(),
    );
    if (p.equals(canonicalProjectRoot, destination.canonicalPath) ||
        p.isWithin(canonicalProjectRoot, destination.canonicalPath)) {
      addExclusion(
        p.normalize(
          p.join(
            selectedProjectRoot.path,
            p.relative(destination.canonicalPath, from: canonicalProjectRoot),
          ),
        ),
      );
    }

    return FrozenReportOutputIdentity._(
      destination: destination,
      projectExclusions: exclusions,
    );
  }

  /// Requested and canonical transaction destination.
  final ResolvedReportDestination destination;

  /// Frozen aliases excluded from project source/configuration validation.
  final List<String> projectExclusions;

  /// Absolute normalized path requested by the user-facing command.
  String get requestedPath => destination.requestedPath;

  /// Canonical path used for persistence.
  String get canonicalPath => destination.canonicalPath;

  /// Anchors this exact output and proves object and adjacent commit absence.
  Future<PreparedReportOutput> prepare({
    required ReportObjectBackend backend,
    required ReportCommitIdentity identity,
  }) async {
    final parent = Directory(p.dirname(destination.canonicalPath));
    await parent.create(recursive: true);
    final objects = await backend.anchor(parent);
    AnchoredReportDirectory? commits;
    try {
      commits = await backend.anchor(parent);
      final objectLeaf = p.basename(destination.canonicalPath);
      final commitLeaf = p.basename(
        _adjacentCommitPath(destination.canonicalPath),
      );
      validateReportObjectLeaf(objectLeaf);
      validateReportObjectLeaf(commitLeaf);
      await _requireAbsent(objects, objectLeaf);
      await _requireAbsent(commits, commitLeaf);
      return PreparedReportOutput(
        store: ImmutableReportStore(
          objectsDirectory: objects,
          commitsDirectory: commits,
        ),
        objectLeafOverrides: {'primary': objectLeaf},
        commitLeafOverride: commitLeaf,
        recordPathPrefix: '',
      );
    } on Object {
      if (commits != null) await _closeIgnoringFailure(commits);
      await _closeIgnoringFailure(objects);
      rethrow;
    }
  }
}

/// Prepared immutable destination and its single-assignment naming profile.
final class PreparedReportOutput {
  /// Creates one prepared destination.
  PreparedReportOutput({
    required this.store,
    this.objectLeafOverrides = const {},
    this.commitLeafOverride,
    this.recordPathPrefix = 'objects',
  });

  /// Anchored immutable store.
  final ImmutableReportStore store;

  /// Exact object leaves keyed by role, empty for the managed store.
  final Map<String, String> objectLeafOverrides;

  /// Adjacent exact commit leaf, or `null` for managed storage.
  final String? commitLeafOverride;

  /// Commit-record path profile.
  final String recordPathPrefix;

  /// Writes through the prepared immutable naming profile.
  Future<CommittedReport> writeBatch({
    required ReportCommitIdentity identity,
    required List<ReportObjectWrite> objects,
  }) => store.writeBatch(
    identity: identity,
    objects: objects,
    objectLeafOverrides: objectLeafOverrides,
    commitLeafOverride: commitLeafOverride,
    recordPathPrefix: recordPathPrefix,
  );

  /// Releases the retained directory capabilities.
  Future<void> close() => store.close();
}

/// Creates and anchors the project-owned append-only managed report store.
Future<PreparedReportOutput> prepareManagedReportOutput({
  required ToolWorkspace workspace,
  required ReportObjectBackend backend,
  required ReportCommitIdentity identity,
  required String format,
}) async {
  await workspace.reportObjectsDirectory.create(recursive: true);
  await workspace.reportCommitsDirectory.create(recursive: true);
  final objectsPath = workspace.reportObjectsDirectory;
  final commitsPath = workspace.reportCommitsDirectory;
  final objects = await backend.anchor(objectsPath);
  AnchoredReportDirectory? commits;
  try {
    commits = await backend.anchor(commitsPath);
    final objectLeaf = buildReportObjectLeaf(
      identity,
      role: 'primary',
      format: format,
    );
    final commitLeaf = buildReportCommitLeaf(identity);
    await _requireAbsent(objects, objectLeaf);
    await _requireAbsent(commits, commitLeaf);
    return PreparedReportOutput(
      store: ImmutableReportStore(
        objectsDirectory: objects,
        commitsDirectory: commits,
      ),
      objectLeafOverrides: {'primary': objectLeaf},
    );
  } on Object {
    if (commits != null) await _closeIgnoringFailure(commits);
    await _closeIgnoringFailure(objects);
    rethrow;
  }
}

ResolvedReportDestination _resolveSingleAssignmentDestination(File requested) {
  final requestedPath = p.normalize(p.absolute(requested.path));
  final parent = _canonicalizePotentialDirectory(p.dirname(requestedPath));
  return ResolvedReportDestination(
    requestedPath: requestedPath,
    canonicalPath: p.join(parent, p.basename(requestedPath)),
  );
}

String _canonicalizePotentialDirectory(String path) {
  var existing = p.normalize(p.absolute(path));
  final missing = <String>[];
  while (FileSystemEntity.typeSync(existing, followLinks: false) ==
      FileSystemEntityType.notFound) {
    final parent = p.dirname(existing);
    if (parent == existing) break;
    missing.add(p.basename(existing));
    existing = parent;
  }
  final canonical = Directory(existing).resolveSymbolicLinksSync();
  return p.joinAll([canonical, ...missing.reversed]);
}

String _adjacentCommitPath(String outputPath) =>
    p.join(p.dirname(outputPath), '.${p.basename(outputPath)}.commit.json');

Future<void> _requireAbsent(
  AnchoredReportDirectory directory,
  String leaf,
) async {
  try {
    final existing = await directory.openExisting(leaf);
    await existing.close();
    throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.collision,
      operation: 'preflight-single-assignment',
    );
  } on ReportObjectBackendException catch (error) {
    if (error.category == ReportObjectBackendFailure.notFound) return;
    if (error.category == ReportObjectBackendFailure.invalidObject) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.collision,
        operation: 'preflight-single-assignment',
      );
    }
    rethrow;
  }
}

Future<void> _closeIgnoringFailure(Object capability) async {
  try {
    if (capability is AnchoredReportDirectory) await capability.close();
  } on Object {
    // The preparation failure remains primary.
  }
}
