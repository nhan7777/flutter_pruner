import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/build_condition.dart';
import '../../core/project/project_config.dart';
import '../../core/project/project_context.dart';
import 'dart_analysis_workspace.dart';
import 'dart_execution_context_service.dart';
import 'dart_package_ownership.dart';

/// Import or export directive semantics.
enum DartDirectiveKind {
  /// A Dart import directive.
  import,

  /// A Dart export directive.
  export,
}

/// One context-selected Dart library edge.
final class DartDirectiveEdge {
  /// Creates an immutable directive edge.
  const DartDirectiveEdge({
    required this.sourcePath,
    required this.targetPath,
    required this.kind,
    required this.condition,
    required this.exact,
  });

  /// Physical path of the library containing the directive.
  final String sourcePath;

  /// Physical path of the selected library.
  final String targetPath;

  /// Import or export.
  final DartDirectiveKind kind;

  /// Exact configured or auxiliary execution identity.
  final BuildCondition condition;

  /// Whether this branch is proven for the execution context.
  final bool exact;
}

/// One bounded directive-resolution failure.
final class DartDirectiveIssue {
  /// Creates a deeply immutable issue.
  DartDirectiveIssue({
    required this.sourcePath,
    required this.reason,
    Set<BuildTarget> affectedConfiguredTargets = const {},
    Set<String> affectedAuxiliaryTargetIds = const {},
  }) : affectedConfiguredTargets = Set.unmodifiable(
         affectedConfiguredTargets.map(BuildTarget.snapshot),
       ),
       affectedAuxiliaryTargetIds = Set.unmodifiable(
         affectedAuxiliaryTargetIds,
       );

  /// Physical source that contains the incomplete directive.
  final String sourcePath;

  /// Stable fail-closed reason.
  final String reason;

  /// Complete configured target identities affected by this issue.
  final Set<BuildTarget> affectedConfiguredTargets;

  /// Globally unique auxiliary target IDs affected by this issue.
  final Set<String> affectedAuxiliaryTargetIds;
}

/// Immutable result of selecting every directive per execution context.
final class DartDirectiveResolution {
  /// Creates an immutable resolution.
  DartDirectiveResolution({
    required List<DartDirectiveEdge> edges,
    required List<DartDirectiveIssue> issues,
  }) : edges = List.unmodifiable(edges),
       issues = List.unmodifiable(issues);

  /// Selected exact edges and bounded inexact alternatives.
  final List<DartDirectiveEdge> edges;

  /// Resolution facts that must become blockers.
  final List<DartDirectiveIssue> issues;
}

/// Resolves import/export branches independently for each execution context.
final class DartDirectiveResolver {
  /// Creates a resolver over one pass-shared analyzer snapshot.
  DartDirectiveResolver({
    required this.project,
    required this.workspace,
    required this.ownership,
    required this.contexts,
    required List<ResolvedLibraryResult> libraries,
  }) : libraries = List.unmodifiable(libraries);

  /// Selected project.
  final ProjectContext project;

  /// Pass-shared analyzer workspace.
  final DartAnalysisWorkspace workspace;

  /// Frozen package-ownership evidence.
  final DartPackageOwnership ownership;

  /// Frozen configured and auxiliary execution contexts.
  final DartExecutionContextSnapshot contexts;

  /// Resolved libraries from the pass traversal.
  final List<ResolvedLibraryResult> libraries;

  /// Resolves every directive without consulting the analyzer host branch.
  Future<DartDirectiveResolution> resolve() async {
    final edges = <DartDirectiveEdge>[];
    final edgeKeys = <String>{};
    final issues = <_MutableIssueKey, _MutableIssue>{};
    final knownLibraries = <String, ResolvedLibraryResult>{
      for (final library in libraries)
        _canonical(library.element.firstFragment.source.fullName): library,
    };

    void addIssue(
      String sourcePath,
      String reason, {
      BuildTarget? configuredTarget,
      String? auxiliaryTargetId,
    }) {
      final key = _MutableIssueKey(sourcePath, reason);
      final issue = issues.putIfAbsent(
        key,
        () => _MutableIssue(sourcePath: sourcePath, reason: reason),
      );
      if (configuredTarget != null) {
        issue.configuredTargets.add(BuildTarget.snapshot(configuredTarget));
      }
      if (auxiliaryTargetId != null) {
        issue.auxiliaryTargetIds.add(auxiliaryTargetId);
      }
    }

    void addEdge({
      required String sourcePath,
      required String targetPath,
      required DartDirectiveKind kind,
      required BuildCondition condition,
      required bool exact,
    }) {
      final key = [
        sourcePath,
        targetPath,
        kind.name,
        condition.toString(),
        exact,
      ].join('|');
      if (!edgeKeys.add(key)) return;
      edges.add(
        DartDirectiveEdge(
          sourcePath: sourcePath,
          targetPath: targetPath,
          kind: kind,
          condition: condition,
          exact: exact,
        ),
      );
    }

    for (final library in libraries) {
      final sourcePath = _canonical(
        library.element.firstFragment.source.fullName,
      );
      if (ownership.ownerOf(sourcePath).ownership !=
          DartSourceOwnership.selectedPackage) {
        continue;
      }
      for (final unit in library.units) {
        for (final directive
            in unit.unit.directives.whereType<NamespaceDirective>()) {
          final kind = directive is ImportDirective
              ? DartDirectiveKind.import
              : DartDirectiveKind.export;
          final alternatives = _alternatives(unit, directive);

          for (final target in contexts.configuredTargets) {
            final environment = _configuredEnvironment(target);
            await _resolveForContext(
              sourcePath: sourcePath,
              fromLibrary: library.element,
              directive: directive,
              alternatives: alternatives,
              environment: environment,
              condition: BuildCondition.forTarget(target),
              kind: kind,
              knownLibraries: knownLibraries,
              addEdge: addEdge,
              addIssue: (reason) =>
                  addIssue(unit.path, reason, configuredTarget: target),
            );
          }

          for (final target in contexts.auxiliaryExecutionTargets) {
            final environment = _Environment(
              values: target.environmentValues,
              complete: target.environmentComplete,
            );
            await _resolveForContext(
              sourcePath: sourcePath,
              fromLibrary: library.element,
              directive: directive,
              alternatives: alternatives,
              environment: environment,
              condition: BuildCondition.forAuxiliaryTarget(target),
              kind: kind,
              knownLibraries: knownLibraries,
              addEdge: addEdge,
              addIssue: (reason) =>
                  addIssue(unit.path, reason, auxiliaryTargetId: target.id),
            );
          }
        }
      }
    }

    edges.sort((left, right) {
      final source = left.sourcePath.compareTo(right.sourcePath);
      if (source != 0) return source;
      final target = left.targetPath.compareTo(right.targetPath);
      if (target != 0) return target;
      final kind = left.kind.index.compareTo(right.kind.index);
      if (kind != 0) return kind;
      return left.condition.toString().compareTo(right.condition.toString());
    });
    final frozenIssues =
        issues.values
            .map(
              (issue) => DartDirectiveIssue(
                sourcePath: issue.sourcePath,
                reason: issue.reason,
                affectedConfiguredTargets: issue.configuredTargets,
                affectedAuxiliaryTargetIds: issue.auxiliaryTargetIds,
              ),
            )
            .toList()
          ..sort((left, right) {
            final source = left.sourcePath.compareTo(right.sourcePath);
            return source != 0 ? source : left.reason.compareTo(right.reason);
          });
    return DartDirectiveResolution(edges: edges, issues: frozenIssues);
  }

  Future<void> _resolveForContext({
    required String sourcePath,
    required LibraryElement fromLibrary,
    required NamespaceDirective directive,
    required List<_DirectiveAlternative> alternatives,
    required _Environment environment,
    required BuildCondition condition,
    required DartDirectiveKind kind,
    required Map<String, ResolvedLibraryResult> knownLibraries,
    required void Function({
      required String sourcePath,
      required String targetPath,
      required DartDirectiveKind kind,
      required BuildCondition condition,
      required bool exact,
    })
    addEdge,
    required void Function(String reason) addIssue,
  }) async {
    if (alternatives.isEmpty) {
      addIssue('Dart directive has no resolvable URI alternative');
      return;
    }
    final hasConditions = directive.configurations.isNotEmpty;
    final evaluations = <_Truth>[];
    for (final configuration in directive.configurations) {
      final name = configuration.name.toSource();
      final expected = configuration.value?.stringValue ?? 'true';
      final actual = environment.values[name];
      evaluations.add(
        actual == null
            ? _Truth.unknown
            : actual == expected
            ? _Truth.yes
            : _Truth.no,
      );
    }
    final exact =
        !hasConditions ||
        environment.complete && !evaluations.contains(_Truth.unknown);
    final selected = exact
        ? [_firstTrueAlternative(alternatives, evaluations)]
        : _possibleAlternatives(alternatives, evaluations);
    if (!exact) {
      addIssue(
        'conditional Dart directive environment is incomplete for this execution context',
      );
    }
    for (final alternative in selected) {
      if (alternative.isSdk) continue;
      final targetPath = alternative.path;
      if (targetPath == null) {
        addIssue('Dart directive URI could not be resolved by the analyzer');
        continue;
      }
      final targetOwner = ownership.ownerOf(targetPath);
      if (targetOwner.ownership == DartSourceOwnership.unknown) {
        addIssue('Dart directive ownership boundary is unknown');
        continue;
      }
      if (!File(targetPath).existsSync()) {
        addIssue('Dart directive selected a missing library');
        continue;
      }
      if (targetOwner.ownership == DartSourceOwnership.selectedPackage) {
        var resolved = knownLibraries[targetPath];
        if (resolved == null) {
          final result = await workspace.resolveSelectedDirectiveTarget(
            targetPath,
            fromLibrary: fromLibrary,
          );
          if (result is ResolvedLibraryResult) {
            resolved = result;
            knownLibraries[targetPath] = result;
          }
        }
        if (resolved == null) {
          addIssue('Dart directive target is not a resolved library');
          continue;
        }
      }
      addEdge(
        sourcePath: sourcePath,
        targetPath: targetPath,
        kind: kind,
        condition: condition,
        exact: exact,
      );
    }
  }

  List<_DirectiveAlternative> _alternatives(
    ResolvedUnitResult unit,
    NamespaceDirective directive,
  ) {
    final defaultValue = directive.uri.stringValue;
    final result = <_DirectiveAlternative>[
      _DirectiveAlternative(
        _resolveUri(unit, defaultValue),
        isSdk: _isSdkUri(defaultValue),
      ),
    ];
    for (final configuration in directive.configurations) {
      final value = configuration.uri.stringValue;
      final resolvedUri = configuration.resolvedUri;
      final path = resolvedUri is DirectiveUriWithSource
          ? _canonical(resolvedUri.source.fullName)
          : _resolveUri(unit, value);
      result.add(_DirectiveAlternative(path, isSdk: _isSdkUri(value)));
    }
    return result;
  }

  String? _resolveUri(ResolvedUnitResult unit, String? value) {
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || uri.hasQuery || uri.hasFragment) return null;
    if (uri.scheme == 'dart') return null;
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

bool _isSdkUri(String? value) => Uri.tryParse(value ?? '')?.scheme == 'dart';

_DirectiveAlternative _firstTrueAlternative(
  List<_DirectiveAlternative> alternatives,
  List<_Truth> evaluations,
) {
  for (var index = 0; index < evaluations.length; index++) {
    if (evaluations[index] == _Truth.yes) return alternatives[index + 1];
  }
  return alternatives.first;
}

List<_DirectiveAlternative> _possibleAlternatives(
  List<_DirectiveAlternative> alternatives,
  List<_Truth> evaluations,
) {
  final possible = <_DirectiveAlternative>[];
  var earlierCanAllBeFalse = true;
  for (var index = 0; index < evaluations.length; index++) {
    final evaluation = evaluations[index];
    if (earlierCanAllBeFalse && evaluation != _Truth.no) {
      possible.add(alternatives[index + 1]);
    }
    if (evaluation == _Truth.yes) {
      earlierCanAllBeFalse = false;
      break;
    }
  }
  if (earlierCanAllBeFalse) possible.add(alternatives.first);
  return possible;
}

_Environment _configuredEnvironment(BuildTarget target) {
  final sdkEnvironment = dartSdkEnvironmentByPlatform[target.platform];
  final values = <String, String>{...?sdkEnvironment};
  for (final entry in target.dartDefines.entries) {
    if (dartSdkEnvironmentKeys.contains(entry.key)) continue;
    values[entry.key] = entry.value;
  }
  return _Environment(values: values, complete: sdkEnvironment != null);
}

String _canonical(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

enum _Truth { yes, no, unknown }

final class _Environment {
  const _Environment({required this.values, required this.complete});

  final Map<String, String> values;
  final bool complete;
}

final class _DirectiveAlternative {
  const _DirectiveAlternative(this.path, {this.isSdk = false});

  final String? path;
  final bool isSdk;
}

final class _MutableIssueKey {
  const _MutableIssueKey(this.sourcePath, this.reason);

  final String sourcePath;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is _MutableIssueKey &&
      other.sourcePath == sourcePath &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(sourcePath, reason);
}

final class _MutableIssue {
  _MutableIssue({required this.sourcePath, required this.reason});

  final String sourcePath;
  final String reason;
  final Set<BuildTarget> configuredTargets = {};
  final Set<String> auxiliaryTargetIds = {};
}
