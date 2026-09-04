import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import '../../core/graph/execution_target.dart';
import '../../core/project/project_context.dart';
import '../../core/project/target_matrix.dart';
import 'auxiliary_execution_target_detector.dart';
import 'callback_boundary_detector.dart';
import 'dart_analysis_workspace.dart';
import 'dart_ids.dart';
import 'dart_package_ownership.dart';
import 'entry_point_detector.dart';
import 'spawn_uri_boundary_detector.dart';

/// Whether a typed Dart root names a library or declaration.
enum DartExecutionRootSubject {
  /// A Dart library graph node.
  library,

  /// A Dart declaration graph node.
  declaration,

  /// A non-reportable selected generated library artifact.
  generatedArtifact,
}

/// One root with exactly one configured or auxiliary execution identity.
final class DartExecutionRootFact {
  /// Creates and validates a typed root fact.
  factory DartExecutionRootFact({
    required String nodeId,
    required String owningLibraryId,
    required DartExecutionRootSubject subject,
    required RootDomain domain,
    required String reason,
    BuildTarget? configuredTarget,
    String? auxiliaryExecutionTargetId,
  }) {
    final configured = configuredTarget != null;
    final auxiliary = auxiliaryExecutionTargetId != null;
    if (configured == auxiliary ||
        (domain == RootDomain.configuredTarget && !configured) ||
        (domain == RootDomain.auxiliary && !auxiliary)) {
      throw ArgumentError(
        'A Dart execution root must have exactly one matching domain identity.',
      );
    }
    if (subject == DartExecutionRootSubject.library &&
        nodeId != owningLibraryId) {
      throw ArgumentError('Library root node and owner IDs must match.');
    }
    return DartExecutionRootFact._(
      nodeId: nodeId,
      owningLibraryId: owningLibraryId,
      subject: subject,
      domain: domain,
      reason: reason,
      configuredTarget: configuredTarget == null
          ? null
          : BuildTarget.snapshot(configuredTarget),
      auxiliaryExecutionTargetId: auxiliaryExecutionTargetId,
    );
  }

  const DartExecutionRootFact._({
    required this.nodeId,
    required this.owningLibraryId,
    required this.subject,
    required this.domain,
    required this.reason,
    required this.configuredTarget,
    required this.auxiliaryExecutionTargetId,
  });

  /// Root node ID.
  final String nodeId;

  /// Owning Dart library ID.
  final String owningLibraryId;

  /// Root subject kind.
  final DartExecutionRootSubject subject;

  /// Configured or auxiliary root domain.
  final RootDomain domain;

  /// Stable explanation.
  final String reason;

  /// Full configured target identity, when [domain] is configured.
  final BuildTarget? configuredTarget;

  /// Registered auxiliary ID, when [domain] is auxiliary.
  final String? auxiliaryExecutionTargetId;

  @override
  bool operator ==(Object other) =>
      other is DartExecutionRootFact &&
      other.nodeId == nodeId &&
      other.owningLibraryId == owningLibraryId &&
      other.subject == subject &&
      other.domain == domain &&
      other.reason == reason &&
      other.configuredTarget == configuredTarget &&
      other.auxiliaryExecutionTargetId == auxiliaryExecutionTargetId;

  @override
  int get hashCode => Object.hash(
    nodeId,
    owningLibraryId,
    subject,
    domain,
    reason,
    configuredTarget,
    auxiliaryExecutionTargetId,
  );
}

/// One stable failure or incompleteness fact from context discovery.
final class DartExecutionContextIssue {
  /// Creates a context issue.
  const DartExecutionContextIssue({
    required this.code,
    required this.reason,
    required this.requiresGlobalBlocker,
  });

  /// Stable machine-readable code.
  final String code;

  /// Sanitized reason.
  final String reason;

  /// Whether the Dart namespace must be globally blocked.
  final bool requiresGlobalBlocker;

  @override
  bool operator ==(Object other) =>
      other is DartExecutionContextIssue &&
      other.code == code &&
      other.reason == reason &&
      other.requiresGlobalBlocker == requiresGlobalBlocker;

  @override
  int get hashCode => Object.hash(code, reason, requiresGlobalBlocker);
}

/// Deeply immutable execution-context snapshot for one analysis pass.
final class DartExecutionContextSnapshot {
  /// Creates a context snapshot.
  DartExecutionContextSnapshot({
    required List<BuildTarget> configuredTargets,
    required List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets,
    required List<DartExecutionRootFact> roots,
    required List<DartExecutionContextIssue> issues,
  }) : configuredTargets = List.unmodifiable(
         configuredTargets.map(BuildTarget.snapshot),
       ),
       auxiliaryExecutionTargets = List.unmodifiable(auxiliaryExecutionTargets),
       roots = List.unmodifiable(roots),
       issues = List.unmodifiable(issues);

  /// Full configured build-target tuples.
  final List<BuildTarget> configuredTargets;

  /// Explicit auxiliary execution targets.
  final List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets;

  /// Typed configured and auxiliary root facts.
  final List<DartExecutionRootFact> roots;

  /// Fail-closed discovery issues.
  final List<DartExecutionContextIssue> issues;
}

/// Lazily resolves Dart execution contexts once per analyzer pass.
abstract interface class DartExecutionContextService {
  /// Resolves the deeply immutable pass snapshot.
  Future<DartExecutionContextSnapshot> resolve(ProjectContext project);
}

/// Production memoized execution-context service.
final class DefaultDartExecutionContextService
    implements DartExecutionContextService {
  /// Creates a service backed by the pass-shared analyzer [workspace].
  DefaultDartExecutionContextService({required this.workspace});

  /// Shared analyzer resolution cache.
  final DartAnalysisWorkspace workspace;

  Future<DartExecutionContextSnapshot>? _snapshotFuture;
  ProjectContext? _project;

  @override
  Future<DartExecutionContextSnapshot> resolve(ProjectContext project) {
    final acceptedProject = _project;
    if (acceptedProject != null && !identical(acceptedProject, project)) {
      throw StateError('A Dart execution-context service is pass-scoped.');
    }
    _project = project;
    return _snapshotFuture ??= _build(project);
  }

  Future<DartExecutionContextSnapshot> _build(ProjectContext project) async {
    final ownership = DartPackageOwnership.discover(project);
    final detector = AuxiliaryExecutionTargetDetector(project);
    final targets = <String, AuxiliaryExecutionTarget>{};
    final rootsByIdentity = <String, DartExecutionRootFact>{};
    final issues = <DartExecutionContextIssue>{};
    final potentialUnclassifiedEntrypoints = <String>{};
    final spawnUriEntrypoints = <String>{};
    final excludedEntrypointPaths = <String>{
      for (final exclusion in project.targetMatrix.excludedEntrypoints)
        p.normalize(p.absolute(project.resolve(exclusion.path))),
    };
    final matchedExcludedEntrypoints = <String>{};
    final configuredEntrypointPaths = <String>{
      for (final target in project.targets)
        p.normalize(p.absolute(project.resolve(target.entrypoint))),
    };

    void addIssue(AuxiliaryExecutionTargetDetectionIssue issue) {
      issues.add(
        DartExecutionContextIssue(
          code: issue.code,
          reason: issue.reason,
          requiresGlobalBlocker: issue.requiresGlobalBlocker,
        ),
      );
    }

    void addRoot(DartExecutionRootFact root) {
      final identity = [
        root.domain.name,
        root.configuredTarget?.toString() ?? root.auxiliaryExecutionTargetId,
        root.nodeId,
      ].join('|');
      rootsByIdentity.putIfAbsent(identity, () => root);
    }

    void addGlobalIssue(String code, String reason) {
      issues.add(
        DartExecutionContextIssue(
          code: code,
          reason: reason,
          requiresGlobalBlocker: true,
        ),
      );
    }

    void addTarget(AuxiliaryExecutionTarget target) {
      final accepted = targets[target.id];
      if (accepted == null) {
        targets[target.id] = target;
      } else if (accepted != target) {
        addGlobalIssue(
          'auxiliary-target-definition-conflict',
          'an auxiliary execution target ID has conflicting definitions',
        );
      }
    }

    void addRootOwnershipIssue(DartSourceOwner owner) {
      final external = owner.ownership == DartSourceOwnership.externalPackage;
      issues.add(
        DartExecutionContextIssue(
          code: external
              ? 'dart-root-external-package'
              : 'dart-root-ownership-unknown',
          reason: external
              ? 'a declared Dart execution root belongs to an external package'
              : 'a declared Dart execution root has unknown package ownership',
          requiresGlobalBlocker: true,
        ),
      );
    }

    if (project.rootCoverage.mode == RootCoverageMode.applicationEntrypoints &&
        project.targetMatrix.status != TargetMatrixStatus.inferredDefault) {
      for (final target in project.targets) {
        final entrypointPath = project.resolve(target.entrypoint);
        final owner = ownership.ownerOf(entrypointPath);
        if (owner.ownership != DartSourceOwnership.selectedPackage) {
          addRootOwnershipIssue(owner);
          continue;
        }
        final libraryId = DartIds.libraryPath(
          project,
          entrypointPath,
          ownership: ownership,
        );
        if (DartIds.isGeneratedProjectPath(
          project,
          entrypointPath,
          ownership: ownership,
        )) {
          addRoot(
            DartExecutionRootFact(
              nodeId: DartIds.generatedArtifact(project, entrypointPath),
              owningLibraryId: libraryId,
              subject: DartExecutionRootSubject.generatedArtifact,
              domain: RootDomain.configuredTarget,
              reason: 'configured generated application entrypoint',
              configuredTarget: target,
            ),
          );
          continue;
        }
        addRoot(
          DartExecutionRootFact(
            nodeId: libraryId,
            owningLibraryId: libraryId,
            subject: DartExecutionRootSubject.library,
            domain: RootDomain.configuredTarget,
            reason: 'contains main() entry point',
            configuredTarget: target,
          ),
        );
        addRoot(
          DartExecutionRootFact(
            nodeId: '$libraryId#main',
            owningLibraryId: libraryId,
            subject: DartExecutionRootSubject.declaration,
            domain: RootDomain.configuredTarget,
            reason: 'main() entry point',
            configuredTarget: target,
          ),
        );
      }
    }

    final publicEntrypoints = <String>{
      ...project.rootCoverage.publicEntrypoints,
      if (project.rootCoverage.mode == RootCoverageMode.inferred &&
          File(project.resolve('lib/${project.packageName}.dart')).existsSync())
        'lib/${project.packageName}.dart',
    };
    for (final relativePath in publicEntrypoints) {
      final file = project.resolve(relativePath);
      final owner = ownership.ownerOf(file);
      if (owner.ownership != DartSourceOwnership.selectedPackage) {
        addRootOwnershipIssue(owner);
        continue;
      }
      final detection = detector.detectExternal(relativePath);
      addTarget(detection.target);
      detection.issues.forEach(addIssue);
      final libraryId = DartIds.libraryPath(
        project,
        file,
        ownership: ownership,
      );
      addRoot(
        DartExecutionRootFact(
          nodeId: libraryId,
          owningLibraryId: libraryId,
          subject: DartExecutionRootSubject.library,
          domain: RootDomain.auxiliary,
          reason: 'public package entry library imported by external consumers',
          auxiliaryExecutionTargetId: detection.target.id,
        ),
      );
    }

    final workspaceDartFiles = workspace.dartFiles;
    final visiblePaths = {
      for (final context in workspace.collection.contexts)
        for (final path in context.contextRoot.analyzedFiles())
          if (path.endsWith('.dart')) p.normalize(p.absolute(path)),
    };
    final standardExecutablePaths = _standardExecutableEntrypoints(
      project,
      ownership,
      addGlobalIssue: addGlobalIssue,
    ).toList();
    for (final path in standardExecutablePaths) {
      if (!visiblePaths.contains(p.normalize(p.absolute(path)))) {
        issues.add(
          DartExecutionContextIssue(
            code: 'standard-executable-analyzer-excluded',
            reason:
                'analyzer excluded a selected standard executable: '
                '${project.relative(path)}',
            requiresGlobalBlocker: true,
          ),
        );
      }
    }

    for (final path in workspaceDartFiles) {
      final modeledPath = DartIds.isModeledProjectPath(
        project,
        path,
        ownership: ownership,
      );
      final generatedPath = DartIds.isGeneratedProjectPath(
        project,
        path,
        ownership: ownership,
      );
      if (!modeledPath && !generatedPath) {
        continue;
      }
      final result = await workspace.resolveLibrary(path);
      if (result is NotLibraryButPartResult) continue;
      if (result is! ResolvedLibraryResult) {
        issues.add(
          const DartExecutionContextIssue(
            code: 'dart-context-resolution-failed',
            reason: 'analyzer could not resolve a Dart execution context',
            requiresGlobalBlocker: true,
          ),
        );
        continue;
      }
      final relativePath = project.relative(
        result.element.firstFragment.source.fullName,
      );
      final canonicalLibraryPath = p.normalize(
        p.absolute(result.element.firstFragment.source.fullName),
      );
      final libraryId = DartIds.library(
        project,
        result.element,
        ownership: ownership,
      );
      final generatedArtifactId = generatedPath
          ? DartIds.generatedArtifact(
              project,
              result.element.firstFragment.source.fullName,
            )
          : null;

      final testRunnerSurface =
          _isTestRunnerSurface(relativePath) &&
          !configuredEntrypointPaths.contains(canonicalLibraryPath);
      if (testRunnerSurface) {
        final detection = detector.detectTest(
          relativePath: relativePath,
          library: result,
        );
        final executionTargets = [
          for (final target in detection.targets)
            if (generatedPath)
              _forceIncompleteRuntimeTarget(target)
            else
              target,
        ];
        for (final target in executionTargets) {
          addTarget(target);
        }
        detection.issues.forEach(addIssue);
        if (generatedPath) {
          addIssue(_generatedExecutableMainIssue);
        }
        final entryPoint = result.element.entryPoint;
        for (final executionTarget in executionTargets) {
          if (generatedPath) {
            _addGeneratedArtifactRoot(
              addRoot: addRoot,
              artifactId: generatedArtifactId!,
              owningLibraryId: libraryId,
              targetId: executionTarget.id,
              reason: 'generated test library invoked by the test runner',
            );
            continue;
          }
          addRoot(
            DartExecutionRootFact(
              nodeId: libraryId,
              owningLibraryId: libraryId,
              subject: DartExecutionRootSubject.library,
              domain: RootDomain.auxiliary,
              reason: 'test library invoked dynamically by the test runner',
              auxiliaryExecutionTargetId: executionTarget.id,
            ),
          );
          if (entryPoint == null) continue;
          final declarationId = DartIds.declaration(
            project,
            entryPoint.firstFragment,
            ownership: ownership,
          );
          addRoot(
            DartExecutionRootFact(
              nodeId: declarationId,
              owningLibraryId: libraryId,
              subject: DartExecutionRootSubject.declaration,
              domain: RootDomain.auxiliary,
              reason: 'test main() entry point',
              auxiliaryExecutionTargetId: executionTarget.id,
            ),
          );
        }
      }

      final entryPoint = result.element.entryPoint;
      if (!testRunnerSurface && entryPoint != null) {
        final configuredTargets = project.targets
            .where((target) => target.entrypoint == relativePath)
            .toList();
        for (final target in configuredTargets) {
          if (generatedPath) {
            addRoot(
              DartExecutionRootFact(
                nodeId: generatedArtifactId!,
                owningLibraryId: libraryId,
                subject: DartExecutionRootSubject.generatedArtifact,
                domain: RootDomain.configuredTarget,
                reason: 'configured generated application entrypoint',
                configuredTarget: target,
              ),
            );
            continue;
          }
          addRoot(
            DartExecutionRootFact(
              nodeId: libraryId,
              owningLibraryId: libraryId,
              subject: DartExecutionRootSubject.library,
              domain: RootDomain.configuredTarget,
              reason: 'contains main() entry point',
              configuredTarget: target,
            ),
          );
          addRoot(
            DartExecutionRootFact(
              nodeId: DartIds.declaration(
                project,
                entryPoint.firstFragment,
                ownership: ownership,
              ),
              owningLibraryId: libraryId,
              subject: DartExecutionRootSubject.declaration,
              domain: RootDomain.configuredTarget,
              reason: 'main() entry point',
              configuredTarget: target,
            ),
          );
        }
        final excludedEntrypoint =
            configuredTargets.isEmpty &&
            !generatedPath &&
            excludedEntrypointPaths.contains(canonicalLibraryPath) &&
            DartIds.isModeledProjectLibrary(
              project,
              result.element,
              ownership: ownership,
            );
        if (configuredTargets.isEmpty &&
            _isStandaloneExecutableSurface(relativePath)) {
          final detection = detector.detectExecutable(relativePath);
          final executionTarget = generatedPath
              ? _forceIncompleteRuntimeTarget(detection.target)
              : detection.target;
          addTarget(executionTarget);
          detection.issues.forEach(addIssue);
          if (generatedPath) {
            addIssue(_generatedExecutableMainIssue);
            _addGeneratedArtifactRoot(
              addRoot: addRoot,
              artifactId: generatedArtifactId!,
              owningLibraryId: libraryId,
              targetId: executionTarget.id,
              reason: 'generated standalone executable library',
            );
          } else {
            _addExecutableRootPair(
              addRoot: addRoot,
              libraryId: libraryId,
              declarationId: DartIds.declaration(
                project,
                entryPoint.firstFragment,
                ownership: ownership,
              ),
              targetId: executionTarget.id,
            );
          }
        } else if (excludedEntrypoint) {
          matchedExcludedEntrypoints.add(canonicalLibraryPath);
        } else if (configuredTargets.isEmpty && !generatedPath) {
          potentialUnclassifiedEntrypoints.add(canonicalLibraryPath);
        }
      }

      if (!generatedPath) {
        for (final callback in EntryPointDetector().detectAnnotatedCallbacks(
          result.element,
        )) {
          final fragment = DartIds.declarationFragment(callback.element);
          if (fragment == null ||
              !DartIds.isModeledProjectFragment(
                project,
                fragment,
                ownership: ownership,
              )) {
            continue;
          }
          final nodeId = DartIds.declaration(
            project,
            fragment,
            ownership: ownership,
          );
          final detection = detector.detectRuntime(
            callbackIdentity: nodeId,
            capability: callback.capability,
          );
          detection.issues.forEach(addIssue);
          for (final target in detection.targets) {
            addTarget(target);
            _addCallbackRootPair(
              addRoot: addRoot,
              nodeId: nodeId,
              libraryId: libraryId,
              targetId: target.id,
              reason: callback.reason,
            );
          }
        }

        final boundaryDetection = CallbackBoundaryDetector(
          project,
        ).detect(result);
        for (final boundary in boundaryDetection.boundaries) {
          final identities = boundary.callbackNodeIds.isEmpty
              ? {'${boundary.owningLibraryId}#unresolved-callback'}
              : boundary.callbackNodeIds;
          for (final identity in identities) {
            final detection = detector.detectRuntime(
              callbackIdentity: identity,
              capability: boundary.descriptor.capability,
            );
            detection.issues.forEach(addIssue);
            if (boundary.unresolved) {
              issues.add(
                DartExecutionContextIssue(
                  code: 'callback-target-incomplete',
                  reason:
                      'callback target is incomplete for ${boundary.descriptor.description}',
                  requiresGlobalBlocker: true,
                ),
              );
            }
            for (final target in detection.targets) {
              addTarget(target);
              if (boundary.callbackNodeIds.contains(identity)) {
                _addCallbackRootPair(
                  addRoot: addRoot,
                  nodeId: identity,
                  libraryId: boundary.owningLibraryId,
                  targetId: target.id,
                  reason:
                      'native callback boundary: ${boundary.descriptor.description}',
                );
              }
            }
          }
        }
      }

      final spawnUriDetection = SpawnUriBoundaryDetector(
        project,
      ).detect(result);
      for (final boundary in spawnUriDetection.boundaries) {
        if (!boundary.identityResolved) {
          addGlobalIssue(
            'spawn-uri-identity-unresolved',
            'an Isolate.spawnUri-shaped invocation was not analyzer-resolved',
          );
          continue;
        }
        if (!boundary.optionsComplete) {
          addGlobalIssue(
            'spawn-uri-options-incomplete',
            'spawnUri package or environment options do not preserve inherited defaults',
          );
          continue;
        }
        if (!boundary.uriComplete || boundary.uriAlternatives.isEmpty) {
          addGlobalIssue(
            'spawn-uri-dynamic',
            'spawnUri entrypoint URI is not a finite proven constant set',
          );
          continue;
        }
        for (final uri in boundary.uriAlternatives) {
          final callbackIdentity = '${boundary.identity}:${uri.toString()}';
          final runtime = detector.detectRuntime(
            callbackIdentity: callbackIdentity,
            capability: CallbackBoundaryCapability.dartVm,
          );
          runtime.issues.forEach(addIssue);
          final launchContexts = <_SpawnUriLaunchContext>[
            for (final runtimeTarget in runtime.targets)
              if (runtimeTarget.sourceConfiguredTarget case final sourceTarget?)
                _SpawnUriLaunchContext(
                  target: _spawnUriTarget(runtimeTarget),
                  rootEntrypoint: sourceTarget.entrypoint,
                ),
          ];
          final incomplete = detector.detectIncompleteRuntime(
            boundaryIdentity: callbackIdentity,
          );
          incomplete.issues.forEach(addIssue);
          final incompleteTarget = _spawnUriTarget(incomplete.target);
          final possibleEntrypoints = {
            relativePath,
            for (final configured in project.targets) configured.entrypoint,
          };
          for (final rootEntrypoint in possibleEntrypoints) {
            launchContexts.add(
              _SpawnUriLaunchContext(
                target: incompleteTarget,
                rootEntrypoint: rootEntrypoint,
              ),
            );
          }
          for (final launchContext in launchContexts) {
            final target = launchContext.target;
            final resolution = await _resolveSpawnUriTarget(
              project: project,
              workspace: workspace,
              ownership: ownership,
              rootEntrypoint: launchContext.rootEntrypoint,
              uri: uri,
            );
            final resolutionIssue = resolution.issue;
            if (resolutionIssue != null) {
              addTarget(target);
              addGlobalIssue(resolutionIssue.code, resolutionIssue.reason);
              continue;
            }
            final library = resolution.library!;
            final entryPoint = library.element.entryPoint!;
            final targetPath = library.element.firstFragment.source.fullName;
            final generatedTarget = DartIds.isGeneratedProjectPath(
              project,
              targetPath,
              ownership: ownership,
            );
            final effectiveTarget = generatedTarget
                ? _forceIncompleteRuntimeTarget(target)
                : target;
            addTarget(effectiveTarget);
            final libraryId = DartIds.library(
              project,
              library.element,
              ownership: ownership,
            );
            spawnUriEntrypoints.add(
              p.normalize(
                p.absolute(library.element.firstFragment.source.fullName),
              ),
            );
            if (generatedTarget) {
              addIssue(_generatedExecutableMainIssue);
              _addGeneratedArtifactRoot(
                addRoot: addRoot,
                artifactId: DartIds.generatedArtifact(project, targetPath),
                owningLibraryId: libraryId,
                targetId: effectiveTarget.id,
                reason: 'generated dart:isolate Isolate.spawnUri entrypoint',
              );
            } else {
              _addSpawnUriRootPair(
                addRoot: addRoot,
                libraryId: libraryId,
                declarationId: DartIds.declaration(
                  project,
                  entryPoint.firstFragment,
                  ownership: ownership,
                ),
                targetId: effectiveTarget.id,
              );
            }
          }
        }
      }
    }

    final unmatchedExcludedEntrypoints =
        excludedEntrypointPaths.difference(matchedExcludedEntrypoints).toList()
          ..sort();
    if (unmatchedExcludedEntrypoints.isNotEmpty) {
      addGlobalIssue(
        'excluded-dart-entrypoint-unresolved',
        'a declared excluded entrypoint did not resolve to a project-owned non-generated main()',
      );
    }

    final unclassifiedEntrypoints =
        potentialUnclassifiedEntrypoints
            .where((path) => !spawnUriEntrypoints.contains(path))
            .toList()
          ..sort();
    if (unclassifiedEntrypoints.isNotEmpty) {
      addGlobalIssue(
        'unclassified-dart-entrypoint',
        'a selected main() is outside configured and recognized execution surfaces',
      );
    }

    final auxiliaryTargets = targets.values.toList()
      ..sort((left, right) => left.id.compareTo(right.id));
    final roots = rootsByIdentity.values.toList()
      ..sort((left, right) {
        final domain = left.domain.index.compareTo(right.domain.index);
        if (domain != 0) return domain;
        final context =
            (left.configuredTarget?.toString() ??
                    left.auxiliaryExecutionTargetId!)
                .compareTo(
                  right.configuredTarget?.toString() ??
                      right.auxiliaryExecutionTargetId!,
                );
        if (context != 0) return context;
        return left.nodeId.compareTo(right.nodeId);
      });
    final orderedIssues = issues.toList()
      ..sort((left, right) {
        final code = left.code.compareTo(right.code);
        return code != 0 ? code : left.reason.compareTo(right.reason);
      });
    return DartExecutionContextSnapshot(
      configuredTargets: project.targets,
      auxiliaryExecutionTargets: auxiliaryTargets,
      roots: roots,
      issues: orderedIssues,
    );
  }
}

final class _SpawnUriResolutionIssue {
  const _SpawnUriResolutionIssue(this.code, this.reason);

  final String code;
  final String reason;
}

final class _SpawnUriResolution {
  const _SpawnUriResolution.resolved(this.library) : issue = null;
  const _SpawnUriResolution.failed(this.issue) : library = null;

  final ResolvedLibraryResult? library;
  final _SpawnUriResolutionIssue? issue;
}

final class _SpawnUriLaunchContext {
  const _SpawnUriLaunchContext({
    required this.target,
    required this.rootEntrypoint,
  });

  final AuxiliaryExecutionTarget target;
  final String rootEntrypoint;
}

Future<_SpawnUriResolution> _resolveSpawnUriTarget({
  required ProjectContext project,
  required DartAnalysisWorkspace workspace,
  required DartPackageOwnership ownership,
  required String rootEntrypoint,
  required Uri uri,
}) async {
  final resolvedUri = Uri.file(project.resolve(rootEntrypoint)).resolveUri(uri);
  if (!resolvedUri.isScheme('file') ||
      resolvedUri.hasQuery ||
      resolvedUri.hasFragment) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-escape',
        'spawnUri entrypoint is not an unambiguous local file URI',
      ),
    );
  }

  final root = p.normalize(p.absolute(project.root.path));
  final path = p.normalize(p.absolute(resolvedUri.toFilePath()));
  if (!_containsPath(root, path)) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-escape',
        'spawnUri entrypoint escapes the selected package',
      ),
    );
  }
  if (_hasSymlinkComponent(root, path)) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-symlink',
        'spawnUri entrypoint contains a symlink boundary',
      ),
    );
  }
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-missing',
        'spawnUri entrypoint does not name an existing regular file',
      ),
    );
  }
  if (project.pathPolicy.shouldExclude(path)) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-excluded',
        'spawnUri entrypoint is excluded from selected analysis',
      ),
    );
  }
  final owner = ownership.ownerOf(path);
  if (owner.ownership != DartSourceOwnership.selectedPackage) {
    return _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        owner.ownership == DartSourceOwnership.externalPackage
            ? 'spawn-uri-target-external'
            : 'spawn-uri-target-ownership-unknown',
        owner.ownership == DartSourceOwnership.externalPackage
            ? 'spawnUri entrypoint belongs to an external package'
            : 'spawnUri entrypoint ownership is ambiguous',
      ),
    );
  }

  final SomeResolvedLibraryResult result;
  try {
    result = await workspace.resolveLibrary(path);
  } on Object {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-unresolved',
        'analyzer could not resolve the spawnUri entrypoint',
      ),
    );
  }
  if (result is! ResolvedLibraryResult || result.element.entryPoint == null) {
    return const _SpawnUriResolution.failed(
      _SpawnUriResolutionIssue(
        'spawn-uri-target-not-entrypoint',
        'spawnUri target is not a resolved library with main()',
      ),
    );
  }
  return _SpawnUriResolution.resolved(result);
}

AuxiliaryExecutionTarget _spawnUriTarget(
  AuxiliaryExecutionTarget runtimeTarget,
) => AuxiliaryExecutionTarget(
  id: runtimeTarget.id,
  domain: runtimeTarget.domain,
  environmentValues: runtimeTarget.environmentValues,
  environmentComplete: runtimeTarget.environmentComplete,
  reason: runtimeTarget.environmentComplete
      ? 'dart:isolate Isolate.spawnUri copied from a configured target'
      : 'dart:isolate Isolate.spawnUri environment is incomplete',
  sourceConfiguredTarget: runtimeTarget.sourceConfiguredTarget,
);

AuxiliaryExecutionTarget _forceIncompleteRuntimeTarget(
  AuxiliaryExecutionTarget target,
) => AuxiliaryExecutionTarget(
  id: target.id,
  domain: target.domain,
  environmentValues: target.environmentValues,
  environmentComplete: false,
  reason: '${target.reason}; generated executable semantics are incomplete',
  sourceConfiguredTarget: target.sourceConfiguredTarget,
);

const _generatedExecutableMainIssue = AuxiliaryExecutionTargetDetectionIssue(
  code: 'generated-executable-main-incomplete',
  reason:
      'generated executable main declarations are not independently modeled',
  requiresGlobalBlocker: false,
);

bool _containsPath(String root, String path) =>
    p.equals(root, path) || p.isWithin(root, path);

bool _hasSymlinkComponent(String root, String path) {
  var current = root;
  for (final segment in p.split(p.relative(path, from: root))) {
    current = p.join(current, segment);
    if (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.link) {
      return true;
    }
  }
  return false;
}

const _testRunnerDirectories = {
  'test',
  'integration_test',
  'patrol_test',
  'test_driver',
};
const _standaloneExecutableDirectories = {'benchmark', 'tool', 'example'};

bool _isTestRunnerSurface(String relativePath) =>
    _testRunnerDirectories.contains(_firstPathSegment(relativePath));

bool _isStandaloneExecutableSurface(String relativePath) {
  final segment = _firstPathSegment(relativePath);
  return segment == 'bin' || _standaloneExecutableDirectories.contains(segment);
}

String _firstPathSegment(String relativePath) =>
    relativePath.replaceAll('\\', '/').split('/').first;

Iterable<String> _standardExecutableEntrypoints(
  ProjectContext project,
  DartPackageOwnership ownership, {
  required void Function(String code, String reason) addGlobalIssue,
}) sync* {
  for (final directoryName in {
    ..._testRunnerDirectories,
    ..._standaloneExecutableDirectories,
    'bin',
  }) {
    final directory = Directory(project.resolve(directoryName));
    if (!directory.existsSync()) continue;
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is Link) {
        if (!entity.path.endsWith('.dart')) continue;
        final lexicalParent = p.normalize(
          Directory(p.dirname(entity.path)).resolveSymbolicLinksSync(),
        );
        final lexicalOwner = ownership.ownerOf(
          p.join(lexicalParent, '__flutter_pruner_ownership__.dart'),
        );
        if (lexicalOwner.ownership == DartSourceOwnership.externalPackage) {
          continue;
        }
        addGlobalIssue(
          'standard-executable-symlink',
          'a standard executable path contains a symlink boundary: '
              '${project.relative(entity.path)}',
        );
        continue;
      }
      if (project.pathPolicy.shouldExcludeTraversalEntry(entity)) continue;
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final owner = ownership.ownerOf(entity.path);
      switch (owner.ownership) {
        case DartSourceOwnership.externalPackage:
          continue;
        case DartSourceOwnership.unknown:
          addGlobalIssue(
            'standard-executable-ownership-unknown',
            'a standard executable path has ambiguous package ownership: '
                '${project.relative(entity.path)}',
          );
          continue;
        case DartSourceOwnership.selectedPackage:
          break;
      }
      if (_testRunnerDirectories.contains(directoryName) ||
          ownership.isSelectedGeneratedSource(entity.path)) {
        yield entity.path;
        continue;
      }
      try {
        final parsed = parseFile(
          path: entity.path,
          featureSet: project.dartFeatureSet,
          throwIfDiagnostics: false,
        );
        final hasMain = parsed.unit.declarations
            .whereType<FunctionDeclaration>()
            .any((declaration) => declaration.name.lexeme == 'main');
        if (hasMain || parsed.errors.isNotEmpty) yield entity.path;
      } on Object {
        yield entity.path;
      }
    }
  }
}

void _addExecutableRootPair({
  required void Function(DartExecutionRootFact fact) addRoot,
  required String libraryId,
  required String declarationId,
  required String targetId,
}) {
  addRoot(
    DartExecutionRootFact(
      nodeId: libraryId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.library,
      domain: RootDomain.auxiliary,
      reason: 'standalone executable library',
      auxiliaryExecutionTargetId: targetId,
    ),
  );
  addRoot(
    DartExecutionRootFact(
      nodeId: declarationId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.declaration,
      domain: RootDomain.auxiliary,
      reason: 'standalone executable main() entry point',
      auxiliaryExecutionTargetId: targetId,
    ),
  );
}

void _addGeneratedArtifactRoot({
  required void Function(DartExecutionRootFact fact) addRoot,
  required String artifactId,
  required String owningLibraryId,
  required String targetId,
  required String reason,
}) {
  addRoot(
    DartExecutionRootFact(
      nodeId: artifactId,
      owningLibraryId: owningLibraryId,
      subject: DartExecutionRootSubject.generatedArtifact,
      domain: RootDomain.auxiliary,
      reason: reason,
      auxiliaryExecutionTargetId: targetId,
    ),
  );
}

void _addSpawnUriRootPair({
  required void Function(DartExecutionRootFact fact) addRoot,
  required String libraryId,
  required String declarationId,
  required String targetId,
}) {
  addRoot(
    DartExecutionRootFact(
      nodeId: libraryId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.library,
      domain: RootDomain.auxiliary,
      reason: 'dart:isolate Isolate.spawnUri entrypoint library',
      auxiliaryExecutionTargetId: targetId,
    ),
  );
  addRoot(
    DartExecutionRootFact(
      nodeId: declarationId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.declaration,
      domain: RootDomain.auxiliary,
      reason: 'dart:isolate Isolate.spawnUri main() entry point',
      auxiliaryExecutionTargetId: targetId,
    ),
  );
}

void _addCallbackRootPair({
  required void Function(DartExecutionRootFact fact) addRoot,
  required String nodeId,
  required String libraryId,
  required String targetId,
  required String reason,
}) {
  addRoot(
    DartExecutionRootFact(
      nodeId: nodeId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.declaration,
      domain: RootDomain.auxiliary,
      reason: reason,
      auxiliaryExecutionTargetId: targetId,
    ),
  );
  addRoot(
    DartExecutionRootFact(
      nodeId: libraryId,
      owningLibraryId: libraryId,
      subject: DartExecutionRootSubject.library,
      domain: RootDomain.auxiliary,
      reason: '$reason (owning library)',
      auxiliaryExecutionTargetId: targetId,
    ),
  );
}
