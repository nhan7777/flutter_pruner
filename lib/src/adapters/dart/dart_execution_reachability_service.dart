import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/execution_target.dart';
import '../../core/project/project_context.dart';
import 'dart_analysis_workspace.dart';
import 'dart_directive_resolver.dart';
import 'dart_execution_context_service.dart';
import 'dart_ids.dart';
import 'dart_package_ownership.dart';
import 'dart_public_surface_resolver.dart';

/// Immutable Dart closure used by every semantic adapter in one pass.
final class DartExecutionReachabilitySnapshot {
  /// Creates a deeply immutable pass snapshot.
  DartExecutionReachabilitySnapshot({
    required this.contexts,
    required this.directives,
    required this.publicSurface,
    required Map<BuildTarget, Set<String>> configuredProvenUnitPaths,
    required Map<BuildTarget, Set<String>> configuredRetainedUnitPaths,
    required Map<String, Set<String>> auxiliaryProvenUnitPaths,
    required Map<String, Set<String>> auxiliaryRetainedUnitPaths,
    required Set<String> globalUsageUnitPaths,
    required List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets,
    required List<String> issues,
    required List<ResolvedLibraryResult> resolvedLibraries,
  }) : configuredProvenUnitPaths = _freezeConfiguredMap(
         configuredProvenUnitPaths,
       ),
       configuredRetainedUnitPaths = _freezeConfiguredMap(
         configuredRetainedUnitPaths,
       ),
       auxiliaryProvenUnitPaths = _freezeAuxiliaryMap(auxiliaryProvenUnitPaths),
       auxiliaryRetainedUnitPaths = _freezeAuxiliaryMap(
         auxiliaryRetainedUnitPaths,
       ),
       globalUsageUnitPaths = Set.unmodifiable(globalUsageUnitPaths),
       auxiliaryExecutionTargets = List.unmodifiable(auxiliaryExecutionTargets),
       issues = List.unmodifiable(issues),
       resolvedLibraries = List.unmodifiable(resolvedLibraries) {
    fingerprint = _fingerprint(this);
  }

  /// Exact execution-context object used to derive this snapshot.
  final DartExecutionContextSnapshot contexts;

  /// Complete per-context import/export selection.
  final DartDirectiveResolution directives;

  /// Complete per-external-context public namespace projection.
  final DartPublicSurfaceResolution publicSurface;

  /// Exact configured closure keyed by the complete target tuple.
  final Map<BuildTarget, Set<String>> configuredProvenUnitPaths;

  /// Fail-closed configured retention keyed by the complete target tuple.
  final Map<BuildTarget, Set<String>> configuredRetainedUnitPaths;

  /// Exact auxiliary closure keyed by globally unique auxiliary ID.
  final Map<String, Set<String>> auxiliaryProvenUnitPaths;

  /// Fail-closed auxiliary retention keyed by globally unique auxiliary ID.
  final Map<String, Set<String>> auxiliaryRetainedUnitPaths;

  /// Union of every configured and auxiliary retained unit path.
  final Set<String> globalUsageUnitPaths;

  /// Frozen auxiliary target registry used by the closure maps.
  final List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets;

  /// Pass-level fail-closed issues.
  final List<String> issues;

  /// Analyzer results from the sole pass traversal.
  final List<ResolvedLibraryResult> resolvedLibraries;

  /// Stable content fingerprint for same-pass consumer assertions.
  late final String fingerprint;
}

/// Resolves one Dart execution-reachability snapshot per analysis pass.
abstract interface class DartExecutionReachabilityService {
  /// Returns the cached immutable snapshot for [project].
  Future<DartExecutionReachabilitySnapshot> resolve(ProjectContext project);
}

/// Production reachability service over a shared analyzer/context snapshot.
final class DefaultDartExecutionReachabilityService
    implements DartExecutionReachabilityService {
  /// Creates a pass-scoped service.
  DefaultDartExecutionReachabilityService({
    required this.workspace,
    required this.contexts,
  });

  /// Pass-shared analyzer workspace.
  final DartAnalysisWorkspace workspace;

  /// Exact immutable context object established for this pass.
  final DartExecutionContextSnapshot contexts;

  Future<DartExecutionReachabilitySnapshot>? _snapshotFuture;
  ProjectContext? _project;

  @override
  Future<DartExecutionReachabilitySnapshot> resolve(ProjectContext project) {
    final accepted = _project;
    if (accepted != null && !identical(accepted, project)) {
      throw StateError('A Dart execution-reachability service is pass-scoped.');
    }
    _project = project;
    return _snapshotFuture ??= _build(project);
  }

  Future<DartExecutionReachabilitySnapshot> _build(
    ProjectContext project,
  ) async {
    final ownership = DartPackageOwnership.discover(project);
    final issues = <String>{};
    final librariesByPath = <String, ResolvedLibraryResult>{};
    for (final path in workspace.dartFiles) {
      final owner = ownership.ownerOf(path);
      if (owner.ownership != DartSourceOwnership.selectedPackage) continue;
      final SomeResolvedLibraryResult result;
      try {
        result = await workspace.resolveLibrary(path);
      } on Object {
        issues.add(
          'analyzer could not resolve selected Dart library: '
          '${project.relative(path)}',
        );
        continue;
      }
      if (result is NotLibraryButPartResult) continue;
      if (result is! ResolvedLibraryResult) {
        issues.add(
          'analyzer could not resolve selected Dart library: '
          '${project.relative(path)}',
        );
        continue;
      }
      final resolvedLibrary = result;
      final libraryPath = _canonical(
        resolvedLibrary.element.firstFragment.source.fullName,
      );
      librariesByPath.putIfAbsent(libraryPath, () => resolvedLibrary);
    }
    final libraries = librariesByPath.values.toList()
      ..sort(
        (left, right) => left.element.firstFragment.source.fullName.compareTo(
          right.element.firstFragment.source.fullName,
        ),
      );
    final directives = await DartDirectiveResolver(
      project: project,
      workspace: workspace,
      ownership: ownership,
      contexts: contexts,
      libraries: libraries,
    ).resolve();
    final publicSurface = DartPublicSurfaceResolver(
      project: project,
      ownership: ownership,
      contexts: contexts,
      libraries: libraries,
      directives: directives,
    ).resolve();

    for (final issue in contexts.issues.where(
      (issue) => issue.requiresGlobalBlocker,
    )) {
      issues.add('${issue.code}: ${issue.reason}');
    }
    for (final issue in directives.issues) {
      issues.add('${issue.reason}: ${project.relative(issue.sourcePath)}');
    }
    for (final issue in publicSurface.issues) {
      issues.add('${issue.reason}: ${project.relative(issue.sourcePath)}');
    }
    if (directives.issues.isNotEmpty) {
      issues.add(
        'conditional Dart imports/exports are incomplete for at least one execution context',
      );
    }

    final libraryPathById = <String, String>{};
    final unitPathsByLibraryPath = <String, Set<String>>{};
    for (final entry in librariesByPath.entries) {
      final library = entry.value;
      final libraryId = DartIds.library(
        project,
        library.element,
        ownership: ownership,
      );
      libraryPathById[libraryId] = entry.key;
      unitPathsByLibraryPath[entry.key] = {
        for (final unit in library.units)
          if (ownership.ownerOf(unit.path).ownership ==
              DartSourceOwnership.selectedPackage)
            _canonical(unit.path),
      };
      for (final unit in library.units) {
        final owner = ownership.ownerOf(unit.path);
        if (owner.ownership == DartSourceOwnership.unknown) {
          issues.add(
            'selected Dart library includes a part with ambiguous ownership: '
            '${project.relative(unit.path)}',
          );
        } else if (owner.ownership == DartSourceOwnership.externalPackage) {
          issues.add(
            'selected Dart library includes a non-selected part: '
            '${project.relative(unit.path)}',
          );
        }
        for (final directive
            in unit.unit.directives.whereType<PartDirective>()) {
          final partPath = _partPath(unit, directive);
          if (partPath == null || !File(partPath).existsSync()) {
            issues.add(
              'selected Dart library contains an unresolved part: '
              '${project.relative(unit.path)}',
            );
            continue;
          }
          final partOwner = ownership.ownerOf(partPath);
          if (partOwner.ownership == DartSourceOwnership.unknown) {
            issues.add(
              'selected Dart library includes a part with unknown ownership: '
              '${project.relative(partPath)}',
            );
          } else if (partOwner.ownership ==
              DartSourceOwnership.externalPackage) {
            issues.add(
              'selected Dart library includes a non-selected part: '
              '${project.relative(partPath)}',
            );
          } else if (!(unitPathsByLibraryPath[entry.key] ?? const {}).contains(
            _canonical(partPath),
          )) {
            issues.add(
              'selected Dart library contains an unresolved part: '
              '${project.relative(partPath)}',
            );
          }
        }
      }
    }
    final outgoing = <String, List<DartDirectiveEdge>>{};
    for (final edge in directives.edges) {
      (outgoing[edge.sourcePath] ??= []).add(edge);
    }

    Set<String> closure({
      required Iterable<String> rootLibraryIds,
      required bool Function(DartDirectiveEdge edge) follows,
      required bool contextComplete,
      required bool proven,
    }) {
      if (proven && !contextComplete) return const {};
      final reachedLibraries = <String>{};
      final reachedUnits = <String>{};
      final pending = <String>[];
      for (final rootId in rootLibraryIds) {
        final path = libraryPathById[rootId];
        if (path == null) {
          issues.add(
            'Dart execution root has no resolved owning library: $rootId',
          );
          continue;
        }
        if (reachedLibraries.add(path)) pending.add(path);
      }
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        reachedUnits.addAll(unitPathsByLibraryPath[current] ?? const {});
        for (final edge in outgoing[current] ?? const <DartDirectiveEdge>[]) {
          if (!follows(edge)) continue;
          if (!librariesByPath.containsKey(edge.targetPath)) continue;
          if (reachedLibraries.add(edge.targetPath)) {
            pending.add(edge.targetPath);
          }
        }
      }
      return Set.unmodifiable(reachedUnits);
    }

    final configuredProven = <BuildTarget, Set<String>>{};
    final configuredRetained = <BuildTarget, Set<String>>{};
    for (final target in contexts.configuredTargets) {
      final roots = contexts.roots
          .where((root) => root.configuredTarget == target)
          .map((root) => root.owningLibraryId)
          .toSet();
      bool applies(DartDirectiveEdge edge) => edge.condition.appliesTo(target);
      configuredProven[BuildTarget.snapshot(target)] = closure(
        rootLibraryIds: roots,
        follows: (edge) => edge.exact && applies(edge),
        contextComplete: true,
        proven: true,
      );
      configuredRetained[BuildTarget.snapshot(target)] = closure(
        rootLibraryIds: roots,
        follows: applies,
        contextComplete: true,
        proven: false,
      );
    }

    final auxiliaryProven = <String, Set<String>>{};
    final auxiliaryRetained = <String, Set<String>>{};
    for (final target in contexts.auxiliaryExecutionTargets) {
      final roots = contexts.roots
          .where((root) => root.auxiliaryExecutionTargetId == target.id)
          .map((root) => root.owningLibraryId)
          .toSet();
      bool applies(DartDirectiveEdge edge) =>
          edge.condition.exactAuxiliaryTargets.contains(target);
      auxiliaryProven[target.id] = closure(
        rootLibraryIds: roots,
        follows: (edge) => edge.exact && applies(edge),
        contextComplete: target.environmentComplete,
        proven: true,
      );
      auxiliaryRetained[target.id] = closure(
        rootLibraryIds: roots,
        follows: applies,
        contextComplete: true,
        proven: false,
      );
    }

    final globalUsage = <String>{
      for (final paths in configuredRetained.values) ...paths,
      for (final paths in auxiliaryRetained.values) ...paths,
    };
    final orderedIssues = issues.toList()..sort();
    return DartExecutionReachabilitySnapshot(
      contexts: contexts,
      directives: directives,
      publicSurface: publicSurface,
      configuredProvenUnitPaths: configuredProven,
      configuredRetainedUnitPaths: configuredRetained,
      auxiliaryProvenUnitPaths: auxiliaryProven,
      auxiliaryRetainedUnitPaths: auxiliaryRetained,
      globalUsageUnitPaths: globalUsage,
      auxiliaryExecutionTargets: contexts.auxiliaryExecutionTargets,
      issues: orderedIssues,
      resolvedLibraries: libraries,
    );
  }
}

Map<BuildTarget, Set<String>> _freezeConfiguredMap(
  Map<BuildTarget, Set<String>> source,
) => Map.unmodifiable({
  for (final entry in source.entries)
    BuildTarget.snapshot(entry.key): Set.unmodifiable(entry.value),
});

Map<String, Set<String>> _freezeAuxiliaryMap(Map<String, Set<String>> source) =>
    Map.unmodifiable({
      for (final entry in source.entries)
        entry.key: Set.unmodifiable(entry.value),
    });

String _fingerprint(DartExecutionReachabilitySnapshot snapshot) {
  List<String> sortedPaths(Set<String> paths) => paths.toList()..sort();
  final configuredProven = snapshot.configuredProvenUnitPaths.entries.toList()
    ..sort(
      (left, right) => left.key.toString().compareTo(right.key.toString()),
    );
  final configuredRetained =
      snapshot.configuredRetainedUnitPaths.entries.toList()..sort(
        (left, right) => left.key.toString().compareTo(right.key.toString()),
      );
  final auxiliaryProven = snapshot.auxiliaryProvenUnitPaths.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  final auxiliaryRetained = snapshot.auxiliaryRetainedUnitPaths.entries.toList()
    ..sort((left, right) => left.key.compareTo(right.key));
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'contexts': {
              'configured': snapshot.contexts.configuredTargets
                  .map((target) => target.toString())
                  .toList(),
              'auxiliary': snapshot.contexts.auxiliaryExecutionTargets
                  .map((target) => target.toString())
                  .toList(),
              'roots': snapshot.contexts.roots
                  .map(
                    (root) => [
                      root.nodeId,
                      root.owningLibraryId,
                      root.domain.name,
                      root.configuredTarget?.toString(),
                      root.auxiliaryExecutionTargetId,
                    ],
                  )
                  .toList(),
            },
            'directives': snapshot.directives.edges
                .map(
                  (edge) => [
                    edge.sourcePath,
                    edge.targetPath,
                    edge.kind.name,
                    edge.condition.toString(),
                    edge.exact,
                  ],
                )
                .toList(),
            'publicSurface': snapshot.publicSurface.edges
                .map(
                  (edge) => [
                    edge.publicEntrypointLibraryId,
                    edge.declarationId,
                    edge.externalExecutionTargetId,
                    edge.condition.toString(),
                    edge.exact,
                  ],
                )
                .toList(),
            'configuredProven': {
              for (final entry in configuredProven)
                entry.key.toString(): sortedPaths(entry.value),
            },
            'configuredRetained': {
              for (final entry in configuredRetained)
                entry.key.toString(): sortedPaths(entry.value),
            },
            'auxiliaryProven': {
              for (final entry in auxiliaryProven)
                entry.key: sortedPaths(entry.value),
            },
            'auxiliaryRetained': {
              for (final entry in auxiliaryRetained)
                entry.key: sortedPaths(entry.value),
            },
            'issues': snapshot.issues,
          }),
        ),
      )
      .toString();
}

String? _partPath(ResolvedUnitResult unit, PartDirective directive) {
  final resolved = directive.uri.stringValue;
  if (resolved == null || resolved.isEmpty) return null;
  final uri = Uri.tryParse(resolved);
  if (uri == null || uri.hasQuery || uri.hasFragment) return null;
  if (uri.scheme.isEmpty) {
    return _canonical(p.join(p.dirname(unit.path), uri.toFilePath()));
  }
  if (uri.scheme == 'file') return _canonical(uri.toFilePath());
  if (uri.scheme == 'package') {
    final path = unit.session.uriConverter.uriToPath(uri);
    return path == null ? null : _canonical(path);
  }
  return null;
}

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}
