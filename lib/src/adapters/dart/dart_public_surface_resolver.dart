import 'dart:collection';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/build_condition.dart';
import '../../core/graph/execution_target.dart';
import '../../core/project/project_context.dart';
import '../../core/project/target_matrix.dart';
import 'dart_directive_resolver.dart';
import 'dart_execution_context_service.dart';
import 'dart_ids.dart';
import 'dart_package_ownership.dart';

/// One declaration exposed through a public package entrypoint and context.
final class DartPublicSurfaceEdge {
  /// Creates an immutable public-surface edge.
  const DartPublicSurfaceEdge({
    required this.publicEntrypointLibraryId,
    required this.declarationId,
    required this.externalExecutionTargetId,
    required this.condition,
    required this.exact,
  });

  /// Public entrypoint that exposes [declarationId].
  final String publicEntrypointLibraryId;

  /// Canonical declaration ID, including a part file origin when applicable.
  final String declarationId;

  /// Globally unique external execution context.
  final String externalExecutionTargetId;

  /// Exact external target condition.
  final BuildCondition condition;

  /// Whether the complete export chain is proven in this context.
  final bool exact;
}

/// Immutable public namespace resolution.
final class DartPublicSurfaceResolution {
  /// Creates a deeply immutable result.
  DartPublicSurfaceResolution({
    required List<DartPublicSurfaceEdge> edges,
    required List<DartDirectiveIssue> issues,
  }) : edges = List.unmodifiable(edges),
       issues = List.unmodifiable(issues);

  /// Context-conditioned entrypoint-to-declaration edges.
  final List<DartPublicSurfaceEdge> edges;

  /// Namespace facts that must become blockers.
  final List<DartDirectiveIssue> issues;
}

/// Builds package public surfaces from source directives, never host namespace.
final class DartPublicSurfaceResolver {
  /// Creates a resolver over the pass-shared directive and analyzer snapshot.
  DartPublicSurfaceResolver({
    required this.project,
    required this.ownership,
    required this.contexts,
    required List<ResolvedLibraryResult> libraries,
    required this.directives,
  }) : libraries = List.unmodifiable(libraries);

  /// Selected project.
  final ProjectContext project;

  /// Frozen package ownership.
  final DartPackageOwnership ownership;

  /// Frozen configured and auxiliary contexts.
  final DartExecutionContextSnapshot contexts;

  /// Resolved libraries from the sole pass traversal.
  final List<ResolvedLibraryResult> libraries;

  /// Per-context directive selection.
  final DartDirectiveResolution directives;

  /// Resolves every declared package entrypoint for each external context.
  DartPublicSurfaceResolution resolve() {
    final librariesByPath = <String, ResolvedLibraryResult>{
      for (final library in libraries)
        _canonical(library.element.firstFragment.source.fullName): library,
    };
    final issues = <_IssueKey, _MutablePublicIssue>{};
    final edges = <_PublicEdgeKey, DartPublicSurfaceEdge>{};

    void addIssue(
      String sourcePath,
      String reason,
      AuxiliaryExecutionTarget target,
    ) {
      final key = _IssueKey(sourcePath, reason);
      final issue = issues.putIfAbsent(
        key,
        () => _MutablePublicIssue(sourcePath: sourcePath, reason: reason),
      );
      issue.auxiliaryTargetIds.add(target.id);
    }

    final entrypoints = <String>{...project.rootCoverage.publicEntrypoints};
    if (project.rootCoverage.mode == RootCoverageMode.inferred) {
      entrypoints.add('lib/${project.packageName}.dart');
    }
    final orderedEntrypoints = entrypoints.toList()..sort();
    final externalTargets = contexts.auxiliaryExecutionTargets.where(
      (target) => target.domain == AuxiliaryExecutionDomain.external,
    );
    for (final target in externalTargets) {
      final resolvedEntrypoints = <_ResolvedPublicEntrypoint>[];
      for (final relativeEntrypoint in orderedEntrypoints) {
        final entrypointPath = _canonical(project.resolve(relativeEntrypoint));
        final library = librariesByPath[entrypointPath];
        if (library == null) {
          addIssue(
            entrypointPath,
            'Dart public namespace entrypoint could not be resolved',
            target,
          );
          continue;
        }
        final owner = ownership.ownerOf(entrypointPath);
        if (owner.ownership != DartSourceOwnership.selectedPackage) {
          addIssue(
            entrypointPath,
            'Dart public namespace entrypoint ownership is ambiguous',
            target,
          );
          continue;
        }
        resolvedEntrypoints.add(
          _ResolvedPublicEntrypoint(
            path: entrypointPath,
            id: DartIds.library(project, library.element, ownership: ownership),
          ),
        );
      }
      final surfaces = _resolveSurfaces(
        target: target,
        entrypointPaths: {
          for (final entrypoint in resolvedEntrypoints) entrypoint.path,
        },
        librariesByPath: librariesByPath,
        addIssue: addIssue,
      );
      for (final entrypoint in resolvedEntrypoints) {
        final surface = surfaces[entrypoint.path] ?? const {};
        for (final declarations in surface.values) {
          for (final declaration in declarations) {
            final key = _PublicEdgeKey(
              entrypoint.id,
              declaration.id,
              target.id,
            );
            final candidate = DartPublicSurfaceEdge(
              publicEntrypointLibraryId: entrypoint.id,
              declarationId: declaration.id,
              externalExecutionTargetId: target.id,
              condition: BuildCondition.forAuxiliaryTarget(target),
              exact: declaration.exact,
            );
            final accepted = edges[key];
            if (accepted == null || !accepted.exact && candidate.exact) {
              edges[key] = candidate;
            }
          }
        }
      }
    }

    final frozenEdges = edges.values.toList()
      ..sort((left, right) {
        final entrypoint = left.publicEntrypointLibraryId.compareTo(
          right.publicEntrypointLibraryId,
        );
        if (entrypoint != 0) return entrypoint;
        final declaration = left.declarationId.compareTo(right.declarationId);
        if (declaration != 0) return declaration;
        return left.externalExecutionTargetId.compareTo(
          right.externalExecutionTargetId,
        );
      });
    final frozenIssues =
        issues.values
            .map(
              (issue) => DartDirectiveIssue(
                sourcePath: issue.sourcePath,
                reason: issue.reason,
                affectedAuxiliaryTargetIds: issue.auxiliaryTargetIds,
              ),
            )
            .toList()
          ..sort((left, right) {
            final source = left.sourcePath.compareTo(right.sourcePath);
            return source != 0 ? source : left.reason.compareTo(right.reason);
          });
    return DartPublicSurfaceResolution(
      edges: frozenEdges,
      issues: frozenIssues,
    );
  }

  Map<String, Map<String, List<_SurfaceDeclaration>>> _resolveSurfaces({
    required AuxiliaryExecutionTarget target,
    required Set<String> entrypointPaths,
    required Map<String, ResolvedLibraryResult> librariesByPath,
    required void Function(
      String sourcePath,
      String reason,
      AuxiliaryExecutionTarget target,
    )
    addIssue,
  }) {
    final surfaces = <String, Map<String, List<_SurfaceDeclaration>>>{};
    final exportsByLibrary = <String, List<_SurfaceExport>>{};

    bool addDeclaration(
      String libraryPath,
      Map<String, List<_SurfaceDeclaration>> surface,
      _SurfaceDeclaration declaration,
    ) {
      final sameName = surface.putIfAbsent(declaration.name, () => []);
      final existingIndex = sameName.indexWhere(
        (existing) => existing.id == declaration.id,
      );
      if (existingIndex >= 0) {
        final existing = sameName[existingIndex];
        if (!existing.exact && declaration.exact) {
          sameName[existingIndex] = declaration;
          return true;
        }
        return false;
      }
      if (sameName.isNotEmpty) {
        addIssue(
          libraryPath,
          'Dart public namespace contains an ambiguous duplicate name',
          target,
        );
      }
      sameName.add(declaration);
      return true;
    }

    final pending = SplayTreeSet<String>()..addAll(entrypointPaths);
    final inspected = <String>{};
    while (pending.isNotEmpty) {
      final libraryPath = pending.first;
      pending.remove(libraryPath);
      if (!inspected.add(libraryPath)) continue;
      final library = librariesByPath[libraryPath];
      if (library == null) {
        addIssue(
          libraryPath,
          'Dart public namespace library could not be resolved',
          target,
        );
        continue;
      }
      final surface = surfaces.putIfAbsent(libraryPath, () => {});
      for (final unit in library.units) {
        final unitOwner = ownership.ownerOf(unit.path);
        if (unitOwner.ownership != DartSourceOwnership.selectedPackage) {
          addIssue(
            unit.path,
            'Dart public namespace contains an unowned or ambiguous part',
            target,
          );
          continue;
        }
        if (unit.diagnostics.any(
          (diagnostic) =>
              diagnostic.diagnosticCode.severity == DiagnosticSeverity.ERROR,
        )) {
          addIssue(
            unit.path,
            'Dart public namespace unit could not be fully resolved',
            target,
          );
        }
        for (final fragment in _topLevelFragments(unit.unit.declaredFragment)) {
          final name = fragment.name;
          if (name == null || name.isEmpty || name.startsWith('_')) continue;
          if (!DartIds.isModeledProjectFragment(
            project,
            fragment,
            ownership: ownership,
          )) {
            addIssue(
              unit.path,
              'Dart public namespace declaration is outside selected ownership',
              target,
            );
            continue;
          }
          addDeclaration(
            libraryPath,
            surface,
            _SurfaceDeclaration(
              name: name,
              id: DartIds.declaration(project, fragment, ownership: ownership),
              exact: true,
            ),
          );
        }
      }

      final exports = exportsByLibrary.putIfAbsent(libraryPath, () => []);
      for (final unit in library.units) {
        for (final export
            in unit.unit.directives.whereType<ExportDirective>()) {
          final candidatePaths = _exportAlternativePaths(unit, export);
          final selectedEdges = directives.edges.where(
            (edge) =>
                edge.kind == DartDirectiveKind.export &&
                edge.sourcePath == libraryPath &&
                edge.condition.exactAuxiliaryTargets.contains(target) &&
                candidatePaths.contains(edge.targetPath),
          );
          var emitted = false;
          for (final edge in selectedEdges) {
            emitted = true;
            final exportedLibrary = librariesByPath[edge.targetPath];
            if (exportedLibrary == null ||
                ownership.ownerOf(edge.targetPath).ownership !=
                    DartSourceOwnership.selectedPackage) {
              addIssue(
                unit.path,
                'Dart public namespace export target could not be resolved',
                target,
              );
              continue;
            }
            exports.add(
              _SurfaceExport(
                targetPath: edge.targetPath,
                combinators: export.combinators,
                exact: edge.exact,
              ),
            );
            pending.add(edge.targetPath);
            if (!edge.exact) {
              addIssue(
                unit.path,
                'Dart public namespace is incomplete for a conditional export',
                target,
              );
            }
          }
          if (!emitted && _hasDirectiveIssue(unit.path, target.id)) {
            addIssue(
              unit.path,
              'Dart public namespace export target could not be resolved',
              target,
            );
          }
        }
      }
    }

    final orderedLibraries = surfaces.keys.toList()..sort();
    var changed = true;
    while (changed) {
      changed = false;
      for (final libraryPath in orderedLibraries) {
        final surface = surfaces[libraryPath]!;
        for (final export
            in exportsByLibrary[libraryPath] ?? const <_SurfaceExport>[]) {
          final exported = _applyCombinators(
            surfaces[export.targetPath] ?? const {},
            export.combinators,
          );
          for (final declarations in exported.values) {
            for (final declaration in declarations) {
              changed =
                  addDeclaration(
                    libraryPath,
                    surface,
                    _SurfaceDeclaration(
                      name: declaration.name,
                      id: declaration.id,
                      exact: export.exact && declaration.exact,
                    ),
                  ) ||
                  changed;
            }
          }
        }
      }
    }
    return surfaces;
  }

  bool _hasDirectiveIssue(String sourcePath, String targetId) =>
      directives.issues.any(
        (issue) =>
            _canonical(issue.sourcePath) == _canonical(sourcePath) &&
            issue.affectedAuxiliaryTargetIds.contains(targetId),
      );

  Set<String> _exportAlternativePaths(
    ResolvedUnitResult unit,
    ExportDirective directive,
  ) {
    final paths = <String>{};
    final defaultPath = _resolveUri(unit, directive.uri.stringValue);
    if (defaultPath != null) paths.add(defaultPath);
    for (final configuration in directive.configurations) {
      final resolved = configuration.resolvedUri;
      final path = resolved is DirectiveUriWithSource
          ? _canonical(resolved.source.fullName)
          : _resolveUri(unit, configuration.uri.stringValue);
      if (path != null) paths.add(path);
    }
    return paths;
  }

  String? _resolveUri(ResolvedUnitResult unit, String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
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
}

Iterable<Fragment> _topLevelFragments(LibraryFragment? fragment) sync* {
  if (fragment == null) return;
  yield* fragment.classes;
  yield* fragment.enums;
  yield* fragment.extensions;
  yield* fragment.extensionTypes;
  yield* fragment.functions;
  yield* fragment.getters;
  yield* fragment.mixins;
  yield* fragment.topLevelVariables;
  yield* fragment.typeAliases;
}

Map<String, List<_SurfaceDeclaration>> _applyCombinators(
  Map<String, List<_SurfaceDeclaration>> surface,
  Iterable<Combinator> combinators,
) {
  final result = Map<String, List<_SurfaceDeclaration>>.of(surface);
  for (final combinator in combinators) {
    if (combinator is ShowCombinator) {
      final shown = combinator.shownNames.map((name) => name.name).toSet();
      result.removeWhere((name, _) => !shown.contains(name));
    } else if (combinator is HideCombinator) {
      final hidden = combinator.hiddenNames.map((name) => name.name).toSet();
      result.removeWhere((name, _) => hidden.contains(name));
    }
  }
  return result;
}

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

final class _SurfaceDeclaration {
  const _SurfaceDeclaration({
    required this.name,
    required this.id,
    required this.exact,
  });

  final String name;
  final String id;
  final bool exact;
}

final class _SurfaceExport {
  _SurfaceExport({
    required this.targetPath,
    required Iterable<Combinator> combinators,
    required this.exact,
  }) : combinators = List.unmodifiable(combinators);

  final String targetPath;
  final List<Combinator> combinators;
  final bool exact;
}

final class _ResolvedPublicEntrypoint {
  const _ResolvedPublicEntrypoint({required this.path, required this.id});

  final String path;
  final String id;
}

final class _PublicEdgeKey {
  const _PublicEdgeKey(this.entrypointId, this.declarationId, this.targetId);

  final String entrypointId;
  final String declarationId;
  final String targetId;

  @override
  bool operator ==(Object other) =>
      other is _PublicEdgeKey &&
      other.entrypointId == entrypointId &&
      other.declarationId == declarationId &&
      other.targetId == targetId;

  @override
  int get hashCode => Object.hash(entrypointId, declarationId, targetId);
}

final class _IssueKey {
  const _IssueKey(this.sourcePath, this.reason);

  final String sourcePath;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is _IssueKey &&
      other.sourcePath == sourcePath &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(sourcePath, reason);
}

final class _MutablePublicIssue {
  _MutablePublicIssue({required this.sourcePath, required this.reason});

  final String sourcePath;
  final String reason;
  final Set<String> auxiliaryTargetIds = {};
}
