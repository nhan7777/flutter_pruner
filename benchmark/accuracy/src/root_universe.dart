/// Analyzer-owned, scanner-independent root and closure reconstruction.
library;

import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context_collection.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import 'accuracy_model.dart';
import 'oracle_project_path.dart';
import 'project_manifest.dart';

/// Immutable source modes captured directly from one Git index.
final class OracleGitIndexInventory {
  OracleGitIndexInventory._({
    required this.projectRoot,
    required Map<String, String> modes,
    required Map<String, String> objectIds,
  }) : modes = Map.unmodifiable(Map<String, String>.from(modes)),
       objectIds = Map.unmodifiable(Map<String, String>.from(objectIds));

  /// Captures stage-zero paths below [projectRoot] without reading worktree
  /// file types. This preserves symlink evidence on Windows checkouts.
  static Future<OracleGitIndexInventory> capture(String projectRoot) async {
    final prefixResult = await Process.run('git', [
      '-C',
      projectRoot,
      'rev-parse',
      '--show-prefix',
    ]);
    if (prefixResult.exitCode != 0) {
      throw StateError('Git index prefix is unavailable');
    }
    final prefix = (prefixResult.stdout as String).trim().replaceAll('\\', '/');
    final indexResult = await Process.run('git', [
      '-C',
      projectRoot,
      'ls-files',
      '--stage',
      '-z',
      '--',
      '.',
    ], stdoutEncoding: null);
    if (indexResult.exitCode != 0) {
      throw StateError('Git index inventory is unavailable');
    }
    final raw = utf8.decode(indexResult.stdout as List<int>);
    final modes = <String, String>{};
    final objectIds = <String, String>{};
    for (final record
        in raw.split('\u0000').where((value) => value.isNotEmpty)) {
      final separator = record.indexOf('\t');
      final header = separator == -1 ? '' : record.substring(0, separator);
      final match = RegExp(
        r'^([0-9]{6}) ([0-9a-fA-F]+) ([0-3])$',
      ).firstMatch(header);
      if (match == null || match.group(3) != '0') {
        throw StateError('Git index contains an unsupported staged entry');
      }
      final repositoryPath = record
          .substring(separator + 1)
          .replaceAll('\\', '/');
      if (!repositoryPath.startsWith(prefix)) continue;
      final projectPath = repositoryPath.substring(prefix.length);
      if (!isCanonicalProjectRelativePosixPath(projectPath) ||
          modes.containsKey(projectPath)) {
        throw StateError('Git index contains an invalid project path');
      }
      modes[projectPath] = match.group(1)!;
      objectIds[projectPath] = match.group(2)!.toLowerCase();
    }
    if (modes.isEmpty) throw StateError('Git index inventory is empty');
    return OracleGitIndexInventory._(
      projectRoot: Directory(projectRoot).resolveSymbolicLinksSync(),
      modes: modes,
      objectIds: objectIds,
    );
  }

  /// Canonical root whose stage-zero index produced this inventory.
  final String projectRoot;

  /// Canonical project-relative path to six-digit Git file mode.
  final Map<String, String> modes;

  /// Canonical project-relative path to its exact stage-zero Git object ID.
  final Map<String, String> objectIds;

  /// Returns captured paths whose stage-zero mode or object ID has changed.
  Future<Set<String>> indexStateMismatches(Iterable<String> paths) async {
    final current = await OracleGitIndexInventory.capture(projectRoot);
    return {
      for (final path in paths)
        if (modes[path] != current.modes[path] ||
            objectIds[path] != current.objectIds[path])
          path,
    };
  }

  /// Returns tracked regular Dart sources whose current bytes differ from the index.
  Future<Set<String>> contentMismatches(Iterable<String> paths) async {
    final selected = paths
        .where(
          (path) =>
              path.endsWith('.dart') &&
              (modes[path] == '100644' || modes[path] == '100755'),
        )
        .toSet();
    if (selected.isEmpty) return const <String>{};
    final result = await Process.run('git', [
      '-C',
      projectRoot,
      'diff-files',
      '--relative',
      '--name-only',
      '-z',
      '--',
      '.',
    ], stdoutEncoding: null);
    if (result.exitCode != 0) {
      throw StateError('Git worktree content is unavailable');
    }
    final changed = utf8
        .decode(result.stdout as List<int>)
        .split('\u0000')
        .where((path) => path.isNotEmpty)
        .toSet();
    return {
      for (final path in selected)
        if (changed.contains(path)) path,
    };
  }
}

/// Ownership classification for every Dart source discovered under a project.
enum SourceBoundaryKind { modeled, generated, nestedPackageOwned, excluded }

/// One immutable ownership decision made before traversing a source file.
final class SourceBoundaryEntry {
  /// Creates an ownership record using a project-relative POSIX path.
  const SourceBoundaryEntry({
    required this.path,
    required this.kind,
    required this.owner,
    required this.reason,
  });

  /// Project-relative source path.
  final String path;

  /// Closed ownership category.
  final SourceBoundaryKind kind;

  /// Project or nested-package owner identifier.
  final String owner;

  /// Auditable reason for the ownership decision.
  final String reason;
}

/// Immutable complete source-ownership boundary.
final class OracleSourceBoundary {
  /// Creates a deeply immutable source-boundary index.
  OracleSourceBoundary({required Map<String, SourceBoundaryEntry> entries})
    : _entries = Map.unmodifiable(
        Map<String, SourceBoundaryEntry>.from(entries),
      );

  final Map<String, SourceBoundaryEntry> _entries;

  /// Ownership record by project-relative path.
  SourceBoundaryEntry? operator [](String path) => _entries[path];

  /// Immutable complete ownership index.
  Map<String, SourceBoundaryEntry> get entries => _entries;
}

/// Callback boundary families recognized by the independent root policy.
enum CallbackCapabilityKind {
  vmPragma,
  isolateSpawn,
  dartUiCallback,
  workmanagerInitialize,
  ffiNativeCallback,
  unknown,
}

/// Versioned capability table that gates compatible runtime target tuples.
final class CallbackCapabilityTable {
  /// Creates an immutable callback-capability table.
  const CallbackCapabilityTable({required this.version});

  /// Capability-table version.
  final int version;

  /// Returns whether [platform] is proven compatible with [kind].
  bool supports(CallbackCapabilityKind kind, String platform) {
    const vmNative = {'android', 'ios', 'linux', 'macos', 'windows', 'vm'};
    return switch (kind) {
      CallbackCapabilityKind.vmPragma ||
      CallbackCapabilityKind.isolateSpawn ||
      CallbackCapabilityKind.ffiNativeCallback => vmNative.contains(platform),
      CallbackCapabilityKind.dartUiCallback => {
        'android',
        'ios',
        'linux',
        'macos',
        'windows',
      }.contains(platform),
      CallbackCapabilityKind.workmanagerInitialize => {
        'android',
        'ios',
      }.contains(platform),
      CallbackCapabilityKind.unknown => false,
    };
  }
}

/// Immutable target environment used exclusively by the independent oracle.
final class RootExecutionTarget {
  /// Creates a configured execution target without a borrowed source tuple.
  factory RootExecutionTarget.configured(OracleTarget target) =>
      RootExecutionTarget._(
        id: target.executionContextId,
        domain: OracleRootDomain.configured,
        environmentValues: _targetEnvironment(target),
        environmentComplete: true,
        configuredTarget: target,
        sourceTarget: null,
        reason: 'configured target',
      );

  /// Creates an auxiliary target, allowing a source tuple only for runtime.
  factory RootExecutionTarget.auxiliary(
    OracleAuxiliaryExecutionTarget target, {
    OracleTarget? sourceTarget,
  }) {
    if (sourceTarget != null &&
        (target.domain != OracleAuxiliaryDomain.runtime ||
            !_sameTarget(target.sourceConfiguredTarget, sourceTarget))) {
      throw ArgumentError(
        'auxiliary execution cannot borrow an unrelated configured tuple',
      );
    }
    return RootExecutionTarget._(
      id: target.executionContextId,
      domain: switch (target.domain) {
        OracleAuxiliaryDomain.test => OracleRootDomain.test,
        OracleAuxiliaryDomain.runtime => OracleRootDomain.runtime,
        OracleAuxiliaryDomain.external => OracleRootDomain.external,
      },
      environmentValues: target.environmentValues,
      environmentComplete: target.environmentComplete,
      configuredTarget: null,
      sourceTarget: sourceTarget,
      reason: target.reason,
    );
  }

  RootExecutionTarget._({
    required this.id,
    required this.domain,
    required Map<String, String> environmentValues,
    required this.environmentComplete,
    required this.configuredTarget,
    required this.sourceTarget,
    required this.reason,
  }) : environmentValues = Map.unmodifiable(
         Map<String, String>.from(environmentValues),
       );

  /// Canonical `app:` or `aux:` execution-context identity.
  final String id;

  /// Root domain for this execution context.
  final OracleRootDomain domain;

  /// Full immutable environment values, never inferred from a scanner report.
  final Map<String, String> environmentValues;

  /// Whether exact conditional branch selection is justified.
  final bool environmentComplete;

  /// The configured tuple for an application target, if any.
  final OracleTarget? configuredTarget;

  /// The compatible configured tuple copied into a runtime target, if any.
  final OracleTarget? sourceTarget;

  /// Auditable target-origin reason.
  final String reason;
}

/// Immutable reconstructed root universe and context-specific closures.
final class RootUniverse {
  /// Creates a validated, deeply frozen root universe.
  RootUniverse({
    required this.rootPolicyVersion,
    required this.callbackCapabilities,
    required List<OracleRoot> roots,
    required List<RootExecutionTarget> executionTargets,
    required Map<String, Set<String>> exactClosureByExecutionTarget,
    required Map<String, Set<String>> retainedClosureByExecutionTarget,
    required this.sourceBoundary,
    required List<String> issues,
    required List<String> uncertainties,
  }) : roots = List.unmodifiable(List<OracleRoot>.from(roots)),
       executionTargets = List.unmodifiable(
         List<RootExecutionTarget>.from(executionTargets),
       ),
       exactClosureByExecutionTarget = _freezeClosureMap(
         exactClosureByExecutionTarget,
       ),
       retainedClosureByExecutionTarget = _freezeClosureMap(
         retainedClosureByExecutionTarget,
       ),
       issues = List.unmodifiable(List<String>.from(issues)..sort()),
       uncertainties = List.unmodifiable(
         List<String>.from(uncertainties)..sort(),
       ) {
    final ids = this.executionTargets.map((target) => target.id).toSet();
    if (ids.length != this.executionTargets.length) {
      throw ArgumentError('execution contexts must be unique');
    }
    if (!ids.every(_isContextId) ||
        !this.exactClosureByExecutionTarget.keys.toSet().containsAll(ids) ||
        !this.retainedClosureByExecutionTarget.keys.toSet().containsAll(ids) ||
        this.exactClosureByExecutionTarget.length != ids.length ||
        this.retainedClosureByExecutionTarget.length != ids.length) {
      throw ArgumentError(
        'closures must declare exactly every execution context',
      );
    }
    final rooted = <String>{};
    for (final root in this.roots) {
      if (!ids.containsAll(root.executionTargetIds)) {
        throw ArgumentError('root refers to an undeclared execution context');
      }
      rooted.addAll(root.executionTargetIds);
    }
    if (!rooted.containsAll(ids)) {
      throw ArgumentError(
        'every execution context must be referenced by a root',
      );
    }
    for (final id in ids) {
      if (!this.retainedClosureByExecutionTarget[id]!.containsAll(
        this.exactClosureByExecutionTarget[id]!,
      )) {
        throw ArgumentError('exact closure must be retained for $id');
      }
    }
  }

  /// Version of the independent root policy used for this reconstruction.
  final int rootPolicyVersion;

  /// Versioned callback target-compatibility table.
  final CallbackCapabilityTable callbackCapabilities;

  /// Immutable admitted roots.
  final List<OracleRoot> roots;

  /// Immutable configured and auxiliary context environments.
  final List<RootExecutionTarget> executionTargets;

  /// Exact closure by complete execution context.
  final Map<String, Set<String>> exactClosureByExecutionTarget;

  /// Conservative retained closure by execution context.
  final Map<String, Set<String>> retainedClosureByExecutionTarget;

  /// Immutable complete source-boundary inventory.
  final OracleSourceBoundary sourceBoundary;

  /// Non-silent construction failures.
  final List<String> issues;

  /// Retained uncertainty that cannot prove non-use.
  final List<String> uncertainties;

  /// Whether all source, resolution, and environment facts are complete.
  bool get complete =>
      issues.isEmpty &&
      uncertainties.isEmpty &&
      executionTargets.every((target) => target.environmentComplete);

  /// Deterministic repository-safe root-manifest bytes.
  String toRootManifestJson() {
    _assertCanonicalRootUniversePaths(this);
    final targets = executionTargets.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    final rootList = roots.toList()
      ..sort((a, b) => a.canonicalNodeId.compareTo(b.canonicalNodeId));
    final closures = <String, Object?>{};
    for (final id in exactClosureByExecutionTarget.keys.toList()..sort()) {
      closures[id] = {
        'exact': exactClosureByExecutionTarget[id]!.toList()..sort(),
        'retained': retainedClosureByExecutionTarget[id]!.toList()..sort(),
      };
    }
    final payload = {
      'rootPolicyVersion': rootPolicyVersion,
      'callbackCapabilityVersion': callbackCapabilities.version,
      'executionTargets': [
        for (final target in targets)
          {
            'id': target.id,
            'domain': target.domain.name,
            'environmentComplete': target.environmentComplete,
            'environmentValues': _sortedMap(target.environmentValues),
            if (target.sourceTarget != null)
              'sourceTarget': _targetJson(target.sourceTarget!),
          },
      ],
      'roots': [
        for (final root in rootList)
          {
            'kind': root.kind.name,
            'nodeId': root.canonicalNodeId,
            'sourcePath': root.sourcePath,
            'contexts': root.executionTargetIds.toList()..sort(),
            'reason': root.reason,
          },
      ],
      'closures': closures,
      'sourceBoundary': {
        for (final path in sourceBoundary.entries.keys.toList()..sort())
          path: {
            'kind': sourceBoundary.entries[path]!.kind.name,
            'owner': sourceBoundary.entries[path]!.owner,
            'reason': sourceBoundary.entries[path]!.reason,
          },
      },
      'issues': issues,
      'uncertainties': uncertainties,
    };
    _assertRootManifestPathSafe(payload);
    return jsonEncode(payload);
  }
}

void _assertCanonicalRootUniversePaths(RootUniverse universe) {
  for (final entry in universe.sourceBoundary.entries.entries) {
    if (entry.key != entry.value.path ||
        !isCanonicalProjectRelativePosixPath(entry.key)) {
      throw StateError('root manifest contains a non-canonical source path');
    }
  }
  for (final root in universe.roots) {
    if (!isCanonicalProjectRelativePosixPath(root.sourcePath) ||
        !_isCanonicalRootNodeId(root.canonicalNodeId)) {
      throw StateError('root manifest contains a non-canonical root path');
    }
  }
  for (final node in universe.exactClosureByExecutionTarget.values.expand(
    (nodes) => nodes,
  )) {
    if (!_isCanonicalRootNodeId(node)) {
      throw StateError('root manifest contains a non-canonical exact node');
    }
  }
  for (final node in universe.retainedClosureByExecutionTarget.values.expand(
    (nodes) => nodes,
  )) {
    if (!_isCanonicalRootNodeId(node)) {
      throw StateError('root manifest contains a non-canonical retained node');
    }
  }
}

bool _isCanonicalRootNodeId(String value) {
  if (value.startsWith('lib:')) {
    return isCanonicalProjectRelativePosixPath(value.substring(4));
  }
  if (!value.startsWith('decl:')) return false;
  final separator = value.indexOf('#', 5);
  if (separator == -1 || separator == value.length - 1) return false;
  final declaration = value.substring(separator + 1);
  return isCanonicalProjectRelativePosixPath(value.substring(5, separator)) &&
      !declaration.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
}

void _assertRootManifestPathSafe(Object? value) {
  if (value is String) {
    if (RegExp(r'(^|[^A-Za-z0-9_.:-])/(?:[^\s/]*)').hasMatch(value) ||
        RegExp(r'[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith(r'\\') ||
        value.contains(r'\\') ||
        value.contains('file:')) {
      throw StateError('root manifest contains a filesystem path');
    }
  } else if (value is Map<Object?, Object?>) {
    for (final entry in value.entries) {
      _assertRootManifestPathSafe(entry.key);
      _assertRootManifestPathSafe(entry.value);
    }
  } else if (value is Iterable<Object?>) {
    for (final item in value) {
      _assertRootManifestPathSafe(item);
    }
  }
}

/// Builds an independent root universe from resolved AST/package-config facts.
final class RootUniverseBuilder {
  /// Root-policy version implemented by this builder.
  static const int policyVersion = 2;

  /// Creates a builder for one frozen project manifest and controlled project copy.
  RootUniverseBuilder({
    required this.manifest,
    required String projectRoot,
    required String packageRoot,
    String? packageConfigPath,
    this.gitIndexInventory,
    CallbackCapabilityTable? callbackCapabilities,
  }) : projectRoot = Directory(projectRoot).resolveSymbolicLinksSync(),
       packageRoot = Directory(packageRoot).resolveSymbolicLinksSync(),
       packageConfigPath =
           packageConfigPath ??
           p.join(
             Directory(packageRoot).resolveSymbolicLinksSync(),
             '.dart_tool',
             'package_config.json',
           ),
       callbackCapabilities =
           callbackCapabilities ?? const CallbackCapabilityTable(version: 2);

  /// Frozen comparable input. Scanner observations are deliberately absent.
  final AccuracyProjectManifest manifest;

  /// Controlled project copy root; never emitted by [RootUniverse].
  final String projectRoot;

  /// Selected package root inside [projectRoot].
  final String packageRoot;

  /// Tracked package configuration used to resolve package URIs.
  final String packageConfigPath;

  /// Optional independently captured Git-index evidence for source modes.
  final OracleGitIndexInventory? gitIndexInventory;

  /// Versioned runtime callback capability policy.
  final CallbackCapabilityTable callbackCapabilities;

  /// Reconstructs ownership, roots, contexts, and exact/retained closures.
  Future<RootUniverse> build() async {
    final issues = <String>[];
    final uncertainties = <String>[];
    final canonicalProject = await Directory(
      projectRoot,
    ).resolveSymbolicLinks();
    final canonicalPackage = await Directory(
      packageRoot,
    ).resolveSymbolicLinks();
    if (!_isWithinOrEqual(canonicalProject, canonicalPackage)) {
      throw ArgumentError('selected package root escapes project root');
    }
    final inventory = gitIndexInventory;
    if (inventory != null && !p.equals(inventory.projectRoot, projectRoot)) {
      throw ArgumentError.value(
        inventory.projectRoot,
        'gitIndexInventory.projectRoot',
        'must match the root-universe project root',
      );
    }
    if (manifest.rootPolicyVersion != policyVersion) {
      throw ArgumentError.value(
        manifest.rootPolicyVersion,
        'manifest.rootPolicyVersion',
        'is incompatible with root policy $policyVersion',
      );
    }
    if (callbackCapabilities.version != 2) {
      throw ArgumentError.value(
        callbackCapabilities.version,
        'callbackCapabilities.version',
        'is incompatible with callback capability version 2',
      );
    }
    for (final target in manifest.targets) {
      final reserved = target.dartDefines.keys.where(
        (key) => key.startsWith('dart.library.'),
      );
      if (reserved.isNotEmpty) {
        throw ArgumentError.value(
          target.dartDefines,
          'target.dartDefines',
          'must not override reserved ${reserved.join(', ')}',
        );
      }
    }
    final config = await _readPackageConfig(issues);
    final boundary = await _sourceBoundary(config, issues);
    final modeled = boundary.entries.values
        .where((entry) => entry.kind == SourceBoundaryKind.modeled)
        .map((entry) => entry.path)
        .toSet();
    final traversableDependencies = await _localDependencyLibraries(
      config,
      boundary,
      issues,
    );
    final traversable = {...modeled, ...traversableDependencies};
    final libraries = <String, _LibraryInfo>{};
    final resolvedLibraries =
        <String, ({CompilationUnit unit, String source})>{};
    final invalidLibraries = <String>{};
    final indexMismatchIssues = <String>{};
    Future<void> rejectIndexContentMismatches() async {
      if (inventory == null) return;
      for (final path in await inventory.indexStateMismatches(traversable)) {
        invalidLibraries.add(path);
        final issue = '[source-index-object-mismatch] $path';
        if (indexMismatchIssues.add(issue)) issues.add(issue);
      }
      for (final path in await inventory.contentMismatches(traversable)) {
        invalidLibraries.add(path);
        final issue = '[source-index-content-mismatch] $path';
        if (indexMismatchIssues.add(issue)) issues.add(issue);
      }
    }

    await rejectIndexContentMismatches();
    final collection = AnalysisContextCollection(
      includedPaths: [packageRoot, ..._localPackageRoots(config)],
      excludedPaths: [
        for (final entry in boundary.entries.values)
          if (entry.kind == SourceBoundaryKind.excluded &&
              entry.reason.endsWith(
                'symlink source excluded without traversal',
              ))
            p.join(projectRoot, entry.path),
      ],
    );
    for (final relative in traversable) {
      final full = p.normalize(p.join(projectRoot, relative));
      try {
        final result = await collection
            .contextFor(full)
            .currentSession
            .getResolvedUnit(full);
        if (result is! ResolvedUnitResult) {
          issues.add('[analyzer-result-unavailable] $relative');
          invalidLibraries.add(relative);
          libraries[relative] = _LibraryInfo.fromSource(
            relative,
            File(full).readAsStringSync(),
          );
        } else {
          if (result.diagnostics.any(
            (diagnostic) => diagnostic.severity.name == 'error',
          )) {
            issues.add('[analyzer-diagnostic] $relative');
            invalidLibraries.add(relative);
          }
          resolvedLibraries[relative] = (
            unit: result.unit,
            source: File(full).readAsStringSync(),
          );
        }
      } catch (_) {
        issues.add('[analyzer-failure] $relative');
        invalidLibraries.add(relative);
      }
    }
    final unnamedExtensionIdentities = _UnnamedExtensionIdentityIndex.fromUnits(
      resolvedLibraries.values.map((resolved) => resolved.unit),
    );
    for (final entry in resolvedLibraries.entries) {
      try {
        libraries[entry.key] = _LibraryInfo.fromResolved(
          entry.key,
          entry.value.unit,
          entry.value.source,
          unnamedExtensionIdentities,
        );
      } catch (_) {
        issues.add('[callback-identity-unavailable] ${entry.key}');
        invalidLibraries.add(entry.key);
        libraries[entry.key] = _LibraryInfo.fromSource(
          entry.key,
          entry.value.source,
        );
      }
    }
    await rejectIndexContentMismatches();

    final targets = <RootExecutionTarget>[
      for (final target in manifest.targets)
        RootExecutionTarget.configured(target),
    ];
    final roots = <OracleRoot>[];
    final rootsByContext = <String, Set<String>>{};
    final rootNodesByContextAndPath = <String, Map<String, Set<String>>>{};
    void addRoot(OracleRoot root) {
      roots.add(root);
      for (final context in root.executionTargetIds) {
        rootsByContext
            .putIfAbsent(context, () => <String>{})
            .add(root.sourcePath);
        rootNodesByContextAndPath
            .putIfAbsent(context, () => <String, Set<String>>{})
            .putIfAbsent(root.sourcePath, () => <String>{})
            .add(root.canonicalNodeId);
      }
    }

    for (final target in manifest.targets) {
      final entrypoint = _selectedProjectPath(target.entrypoint);
      if (!modeled.contains(entrypoint)) {
        issues.add('[configured-entrypoint-unmodeled] ${target.entrypoint}');
        continue;
      }
      addRoot(
        OracleRoot(
          kind: OracleRootKind.configuredApplicationEntrypoint,
          canonicalNodeId: _libraryNode(entrypoint),
          sourcePath: entrypoint,
          executionTargetIds: {target.executionContextId},
          reason: 'configured application entrypoint',
        ),
      );
    }

    for (final testPath
        in modeled.where(_isSelectedTestPath).toList()..sort()) {
      final info = libraries[testPath];
      final testEnvironment = _testEnvironment(info?.source ?? '');
      final id = 'test:${_stableTestId(_selectedPackagePath(testPath))}';
      final target = OracleAuxiliaryExecutionTarget(
        id: id,
        domain: OracleAuxiliaryDomain.test,
        environmentValues: testEnvironment.values,
        environmentComplete: testEnvironment.complete,
        reason: testEnvironment.reason,
      );
      final execution = RootExecutionTarget.auxiliary(target);
      targets.add(execution);
      addRoot(
        OracleRoot(
          kind: OracleRootKind.testLibrary,
          canonicalNodeId: _libraryNode(testPath),
          sourcePath: testPath,
          executionTargetIds: {execution.id},
          reason: 'modeled test library',
        ),
      );
    }

    final callbackRoots = <_CallbackRoot>[];
    for (final info in libraries.values) {
      callbackRoots.addAll(info.callbacks);
      for (final unknown in {
        for (final callback in info.unknownCallbacks) callback.path,
      }) {
        uncertainties.add('[unknown-callback] $unknown');
        final target = OracleAuxiliaryExecutionTarget(
          id: 'runtime:unknown_${_reversibleId(unknown)}',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'unknown'},
          environmentComplete: false,
          reason: 'unresolved or same-named callback capability',
        );
        final execution = RootExecutionTarget.auxiliary(target);
        targets.add(execution);
        addRoot(
          OracleRoot(
            kind: OracleRootKind.nativeCallback,
            canonicalNodeId: _libraryNode(unknown),
            sourcePath: unknown,
            executionTargetIds: {execution.id},
            reason: 'unknown callback owner library',
          ),
        );
      }
    }
    final callbackFacts = <String>{};
    for (final callback in callbackRoots) {
      final callbackPath = _projectRelativeSourcePath(callback.path);
      if (callbackPath == null ||
          (!modeled.contains(callbackPath) &&
              !_isAllowedLocalDependencyPath(callbackPath, config))) {
        issues.add('[callback-declaration-outside-selected-package]');
        continue;
      }
      final callbackKey =
          '${callback.kind.name}\u0000$callbackPath\u0000${callback.name}';
      if (!callbackFacts.add(callbackKey)) continue;
      final compatible = manifest.targets
          .where(
            (target) =>
                callbackCapabilities.supports(callback.kind, target.platform),
          )
          .toList();
      final auxiliary = OracleAuxiliaryExecutionTarget(
        id: 'runtime:${_callbackTargetId(callback.kind, callbackPath, callback.name)}',
        domain: OracleAuxiliaryDomain.runtime,
        environmentValues: {
          'callback.kind': callback.kind.name,
          if (compatible.length == 1) ..._targetEnvironment(compatible.single),
        },
        environmentComplete: compatible.length == 1,
        reason: compatible.length == 1
            ? 'compatible ${callback.kind.name} target'
            : 'no unique compatible ${callback.kind.name} target',
        sourceConfiguredTarget: compatible.length == 1
            ? compatible.single
            : null,
      );
      final execution = RootExecutionTarget.auxiliary(
        auxiliary,
        sourceTarget: compatible.length == 1 ? compatible.single : null,
      );
      targets.add(execution);
      addRoot(
        OracleRoot(
          kind: callback.kind == CallbackCapabilityKind.vmPragma
              ? OracleRootKind.pragmaVmEntrypoint
              : OracleRootKind.nativeCallback,
          canonicalNodeId: _declarationNode(callbackPath, callback.name),
          sourcePath: callbackPath,
          executionTargetIds: {execution.id},
          reason: 'resolved ${callback.kind.name} callback declaration',
        ),
      );
      addRoot(
        OracleRoot(
          kind: callback.kind == CallbackCapabilityKind.vmPragma
              ? OracleRootKind.pragmaVmEntrypoint
              : OracleRootKind.nativeCallback,
          canonicalNodeId: _libraryNode(callbackPath),
          sourcePath: callbackPath,
          executionTargetIds: {execution.id},
          reason: 'callback owner library',
        ),
      );
    }

    if (manifest.expectedCoverage.publicEntrypoints.isNotEmpty) {
      final external = OracleAuxiliaryExecutionTarget(
        id: 'external:public-api',
        domain: OracleAuxiliaryDomain.external,
        environmentValues: const {'consumer': 'unknown'},
        environmentComplete: false,
        reason: 'open external consumer surface',
      );
      final execution = RootExecutionTarget.auxiliary(external);
      targets.add(execution);
      for (final entrypoint in manifest.expectedCoverage.publicEntrypoints) {
        final projectEntrypoint = _selectedProjectPath(entrypoint);
        if (!modeled.contains(projectEntrypoint)) {
          issues.add('[public-entrypoint-unmodeled] $entrypoint');
          continue;
        }
        addRoot(
          OracleRoot(
            kind: OracleRootKind.publicPackageEntrypoint,
            canonicalNodeId: _libraryNode(projectEntrypoint),
            sourcePath: projectEntrypoint,
            executionTargetIds: {execution.id},
            reason: 'declared package public entrypoint',
          ),
        );
      }
    }

    final duplicateContexts =
        targets.map((target) => target.id).toSet().length != targets.length;
    if (duplicateContexts) issues.add('[duplicate-execution-context]');
    final exact = <String, Set<String>>{
      for (final target in targets) target.id: <String>{},
    };
    final retained = <String, Set<String>>{
      for (final target in targets) target.id: <String>{},
    };
    for (final target in targets) {
      for (final path in rootsByContext[target.id] ?? const <String>{}) {
        final exactNodes = <String>{};
        final retainedNodes = <String>{};
        final traversal = _traverse(
          start: path,
          complete:
              target.environmentComplete ||
              target.domain == OracleRootDomain.external,
          target: target,
          libraries: libraries,
          invalidLibraries: invalidLibraries,
          modeled: modeled,
          config: config,
          exact: exactNodes,
          retained: retainedNodes,
          issues: issues,
          uncertainties: uncertainties,
          exportsOnly: target.domain == OracleRootDomain.external,
        );
        if (traversal.exactValid &&
            (target.environmentComplete ||
                target.domain == OracleRootDomain.external)) {
          exact[target.id]!.addAll(exactNodes);
          exact[target.id]!.addAll(
            rootNodesByContextAndPath[target.id]?[path] ?? const <String>{},
          );
        }
        retained[target.id]!.addAll(retainedNodes);
        retained[target.id]!.addAll(
          rootNodesByContextAndPath[target.id]?[path] ?? const <String>{},
        );
        if (target.domain == OracleRootDomain.external) {
          final surface = _externalPublicSurface(
            entrypoint: path,
            environment: target.environmentValues,
            libraries: libraries,
            modeled: modeled,
            config: config,
            invalidLibraries: invalidLibraries,
            issues: issues,
          );
          exact[target.id]!.addAll(surface.exact);
          retained[target.id]!.addAll(surface.retained);
          uncertainties.addAll(surface.uncertainties);
        }
      }
    }
    final derivedAuxiliary =
        targets
            .where((target) => target.domain != OracleRootDomain.configured)
            .map(_toAuxiliaryTarget)
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    final declaredAuxiliary = manifest.oracleAuxiliaryExecutionTargets.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (derivedAuxiliary.length != declaredAuxiliary.length ||
        !_sameAuxiliaryLists(derivedAuxiliary, declaredAuxiliary)) {
      throw ArgumentError(
        'manifest auxiliary execution targets do not match: '
        'derived=${derivedAuxiliary.map((target) => target.id).join(',')} '
        'declared=${declaredAuxiliary.map((target) => target.id).join(',')}',
      );
    }
    return RootUniverse(
      rootPolicyVersion: policyVersion,
      callbackCapabilities: callbackCapabilities,
      roots: roots,
      executionTargets: targets,
      exactClosureByExecutionTarget: exact,
      retainedClosureByExecutionTarget: retained,
      sourceBoundary: boundary,
      issues: issues,
      uncertainties: uncertainties,
    );
  }

  Future<_PackageConfig?> _readPackageConfig(List<String> issues) async {
    try {
      final canonicalProjectRoot = Directory(
        projectRoot,
      ).resolveSymbolicLinksSync();
      final canonicalSelectedPackageRoot = Directory(
        packageRoot,
      ).resolveSymbolicLinksSync();
      final json = jsonDecode(await File(packageConfigPath).readAsString());
      if (json is! Map<String, Object?> || json['packages'] is! List<Object?>) {
        throw const FormatException('packages missing');
      }
      final entries = <String, _PackageEntry>{};
      _PackageEntry? selected;
      for (final raw in json['packages']! as List<Object?>) {
        if (raw is! Map<String, Object?> ||
            raw['name'] is! String ||
            raw['rootUri'] is! String ||
            raw['packageUri'] is! String) {
          throw const FormatException('invalid package entry');
        }
        final rootUri = Uri.parse(raw['rootUri']! as String);
        final packageUri = Uri.parse(raw['packageUri']! as String);
        if (packageUri.isAbsolute || !packageUri.path.endsWith('/')) {
          throw const FormatException('packageUri must be a directory URI');
        }
        final configDirectory = Uri.file(
          '${p.normalize(p.dirname(packageConfigPath))}${p.separator}',
        );
        final resolvedRoot = _directoryUri(configDirectory.resolveUri(rootUri));
        final resolvedPackage = _directoryUri(
          resolvedRoot.resolveUri(packageUri),
        );
        if (resolvedRoot.scheme != 'file' || resolvedPackage.scheme != 'file') {
          throw const FormatException('package entry must resolve to file URI');
        }
        var directoryRoot = p.normalize(resolvedRoot.toFilePath());
        var packageDirectory = p.normalize(resolvedPackage.toFilePath());
        if (!_isWithinOrEqual(directoryRoot, packageDirectory)) {
          throw const FormatException('packageUri escapes rootUri');
        }
        if (Directory(directoryRoot).existsSync()) {
          directoryRoot = Directory(directoryRoot).resolveSymbolicLinksSync();
          if (Directory(packageDirectory).existsSync()) {
            packageDirectory = Directory(
              packageDirectory,
            ).resolveSymbolicLinksSync();
          }
          if (!_isWithinOrEqual(canonicalProjectRoot, directoryRoot)) {
            throw const FormatException(
              'package root escapes project via symlink',
            );
          }
        }
        final entry = _PackageEntry(
          name: raw['name']! as String,
          packageRoot: directoryRoot,
          packageDirectory: packageDirectory,
          localToProject: _isWithinOrEqual(canonicalProjectRoot, directoryRoot),
        );
        final name = raw['name']! as String;
        if (entries.containsKey(name)) {
          throw const FormatException('duplicate package entry');
        }
        entries[name] = entry;
        if (p.equals(directoryRoot, canonicalSelectedPackageRoot)) {
          selected = entry;
        }
      }
      if (selected == null) {
        throw const FormatException('selected package is absent');
      }
      return _PackageConfig(
        projectRoot: canonicalProjectRoot,
        packageRoot: selected.packageRoot,
        packageDirectory: selected.packageDirectory,
        selectedPackageName: selected.name,
        entries: entries,
      );
    } catch (error) {
      issues.add('[package-config-invalid]');
      return null;
    }
  }

  Future<OracleSourceBoundary> _sourceBoundary(
    _PackageConfig? config,
    List<String> issues,
  ) async {
    final indexedModes = gitIndexInventory?.modes;
    final selectedRoot = Directory(packageRoot).resolveSymbolicLinksSync();
    final owners = <({String root, String name})>[
      (root: selectedRoot, name: config?.selectedPackageName ?? manifest.label),
      if (config != null)
        for (final entry in config.entries.values)
          if (entry.localToProject &&
              !p.equals(entry.packageRoot, selectedRoot))
            (root: entry.packageRoot, name: entry.name),
    ];
    await for (final entity in Directory(
      selectedRoot,
    ).list(recursive: true, followLinks: false)) {
      if (entity is! File ||
          p.basename(entity.path) != 'pubspec.yaml' ||
          p.equals(p.dirname(entity.path), selectedRoot) ||
          owners.any((owner) => p.equals(owner.root, p.dirname(entity.path)))) {
        continue;
      }
      final packageName = _pubspecPackageName(entity);
      if (packageName == null) {
        issues.add(
          '[source-owner-invalid] '
          '${_relativeProjectPath(entity.path, projectRoot)}',
        );
      }
      owners.add((
        root: p.dirname(entity.path),
        name: packageName ?? 'invalid:${p.basename(entity.parent.path)}',
      ));
    }
    owners.sort((left, right) => right.root.length.compareTo(left.root.length));
    ({String root, String name})? ownerOf(String absolutePath) {
      for (final owner in owners) {
        if (_isWithinOrEqual(owner.root, absolutePath)) return owner;
      }
      return null;
    }

    final scanRoots = <String>{
      selectedRoot,
      if (config != null)
        for (final entry in config.entries.values)
          if (entry.localToProject) entry.packageRoot,
    };
    final entries = <String, SourceBoundaryEntry>{};
    if (indexedModes != null) {
      for (final indexed in indexedModes.entries) {
        final relative = indexed.key;
        final absolute = p.normalize(p.join(projectRoot, relative));
        final owner = ownerOf(absolute);
        if (owner == null ||
            !relative.endsWith('.dart') ||
            indexed.value != '120000') {
          continue;
        }
        issues.add('[source-symlink] $relative');
        entries[relative] = SourceBoundaryEntry(
          path: relative,
          kind: SourceBoundaryKind.excluded,
          owner: owner.name,
          reason: 'Git-index symlink source excluded without traversal',
        );
      }
    }
    for (final scanRoot in scanRoots) {
      if (!Directory(scanRoot).existsSync()) continue;
      await for (final entity in Directory(
        scanRoot,
      ).list(recursive: true, followLinks: false)) {
        final relative = _relativeProjectPath(entity.path, projectRoot);
        if (!relative.endsWith('.dart') || entries.containsKey(relative)) {
          continue;
        }
        final owner = ownerOf(entity.path);
        if (owner == null) continue;
        final indexedMode = indexedModes?[relative];
        if (indexedModes != null && indexedMode == null) {
          issues.add('[source-untracked] $relative');
          entries[relative] = SourceBoundaryEntry(
            path: relative,
            kind: SourceBoundaryKind.excluded,
            owner: owner.name,
            reason: 'untracked source excluded from Git-index oracle',
          );
          continue;
        }
        if (entity is Link) {
          if (indexedMode != null && indexedMode != '120000') {
            issues.add('[source-index-mode-mismatch] $relative');
          }
          issues.add('[source-symlink] $relative');
          entries[relative] = SourceBoundaryEntry(
            path: relative,
            kind: SourceBoundaryKind.excluded,
            owner: owner.name,
            reason: 'symbolic-link source excluded without traversal',
          );
          continue;
        }
        if (entity is! File) continue;
        if (indexedMode != null &&
            indexedMode != '100644' &&
            indexedMode != '100755') {
          issues.add('[source-index-mode-unsupported] $relative $indexedMode');
          entries[relative] = SourceBoundaryEntry(
            path: relative,
            kind: SourceBoundaryKind.excluded,
            owner: owner.name,
            reason: 'unsupported Git-index source mode',
          );
          continue;
        }
        final ownerRelative = _relativeProjectPath(entity.path, owner.root);
        final selectedOwner = p.equals(owner.root, selectedRoot);
        final kind = ownerRelative.startsWith('.dart_tool/')
            ? SourceBoundaryKind.excluded
            : !selectedOwner
            ? SourceBoundaryKind.nestedPackageOwned
            : _isGenerated(ownerRelative)
            ? SourceBoundaryKind.generated
            : SourceBoundaryKind.modeled;
        entries[relative] = SourceBoundaryEntry(
          path: relative,
          kind: kind,
          owner: owner.name,
          reason: switch (kind) {
            SourceBoundaryKind.modeled => 'selected package source',
            SourceBoundaryKind.generated =>
              'generated source excluded from oracle roots',
            SourceBoundaryKind.nestedPackageOwned =>
              'local package owns this source',
            SourceBoundaryKind.excluded => 'excluded build-tool source',
          },
        );
      }
    }
    if (indexedModes != null) {
      for (final indexed in indexedModes.entries) {
        final absolute = p.normalize(p.join(projectRoot, indexed.key));
        if (ownerOf(absolute) == null ||
            !indexed.key.endsWith('.dart') ||
            entries.containsKey(indexed.key)) {
          continue;
        }
        issues.add('[source-index-worktree-missing] ${indexed.key}');
        entries[indexed.key] = SourceBoundaryEntry(
          path: indexed.key,
          kind: SourceBoundaryKind.excluded,
          owner: ownerOf(absolute)!.name,
          reason: 'Git-index source is missing from controlled worktree',
        );
      }
    }
    if (entries.isEmpty) {
      issues.add('[source-inventory-empty]');
    }
    return OracleSourceBoundary(entries: Map.unmodifiable(entries));
  }

  Iterable<String> _localPackageRoots(_PackageConfig? config) sync* {
    if (config == null) return;
    for (final entry in config.entries.values) {
      if (!p.equals(entry.packageRoot, config.packageRoot) &&
          entry.localToProject) {
        yield entry.packageRoot;
      }
    }
  }

  Future<Set<String>> _localDependencyLibraries(
    _PackageConfig? config,
    OracleSourceBoundary boundary,
    List<String> issues,
  ) async {
    final result = <String>{};
    for (final root in _localPackageRoots(config)) {
      final libraryDirectory = Directory(p.join(root, 'lib'));
      if (!libraryDirectory.existsSync()) continue;
      await for (final entity in libraryDirectory.list(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final relative = _relativeProjectPath(
            entity.path,
            config!.projectRoot,
          );
          if (!isCanonicalProjectRelativePosixPath(relative)) {
            issues.add('[local-dependency-path-invalid]');
            continue;
          }
          if (gitIndexInventory != null &&
              boundary[relative]?.kind !=
                  SourceBoundaryKind.nestedPackageOwned) {
            continue;
          }
          result.add(relative);
        }
      }
    }
    return result;
  }

  String _selectedProjectPath(String packageRelativePath) =>
      _relativeProjectPath(
        p.normalize(p.join(packageRoot, packageRelativePath)),
        projectRoot,
      );

  String _selectedPackagePath(String projectRelativePath) =>
      _relativeProjectPath(
        p.normalize(p.join(projectRoot, projectRelativePath)),
        packageRoot,
      );

  bool _isSelectedTestPath(String projectRelativePath) {
    final absolute = p.normalize(p.join(projectRoot, projectRelativePath));
    return _isWithinOrEqual(packageRoot, absolute) &&
        _selectedPackagePath(projectRelativePath).startsWith('test/');
  }

  String? _projectRelativeSourcePath(String? path) {
    if (path == null || path.isEmpty) return null;
    if (!p.isAbsolute(path)) {
      return isCanonicalProjectRelativePosixPath(path) ? path : null;
    }
    if (!_isWithinOrEqual(projectRoot, path)) return null;
    return _relativeProjectPath(path, projectRoot);
  }
}

({bool exactValid}) _traverse({
  required String start,
  required bool complete,
  required RootExecutionTarget target,
  required Map<String, _LibraryInfo> libraries,
  required Set<String> invalidLibraries,
  required Set<String> modeled,
  required _PackageConfig? config,
  required Set<String> exact,
  required Set<String> retained,
  required List<String> issues,
  required List<String> uncertainties,
  required bool exportsOnly,
}) {
  final visitedStrength = <String, int>{};
  var exactValid = complete;
  void visit(String path, {required bool exactAllowed}) {
    final strength = exactAllowed ? 2 : 1;
    final previousStrength = visitedStrength[path] ?? 0;
    if (previousStrength >= strength) return;
    visitedStrength[path] = strength;
    final info = libraries[path];
    if (info == null) {
      if (_isAllowedLocalDependencyPath(path, config)) {
        retained.add(_libraryNode(path));
        return;
      }
      issues.add('[reachable-source-unresolved] $path');
      exactValid = false;
      return;
    }
    if (!modeled.contains(path) &&
        !_isAllowedLocalDependencyPath(path, config)) {
      issues.add('[reachable-source-outside-boundary] $path');
      exactValid = false;
      return;
    }
    retained.add(_libraryNode(path));
    if (exactAllowed) exact.add(_libraryNode(path));
    if (invalidLibraries.contains(path)) {
      issues.add('[reachable-analyzer-invalid] $path');
      exactValid = false;
    }
    for (final directive in info.directives) {
      if (exportsOnly && directive.kind == _DirectiveKind.import) {
        continue;
      }
      final selected = directive.branches.isEmpty
          ? (uri: directive.defaultUri, exact: true)
          : complete
          ? directive.selectedUri(target.environmentValues)
          : (uri: null, exact: false);
      final candidates = selected.exact ? [selected.uri] : directive.allUris;
      if (!selected.exact && directive.allUris.length > 1) {
        uncertainties.add(
          '[conditional-retained-only] $path ${directive.branches.map((branch) => branch.name).join(',')}',
        );
        if (target.domain != OracleRootDomain.external) exactValid = false;
      }
      for (final candidate in candidates.whereType<String>()) {
        final resolved = _resolveUri(candidate, path, config);
        if (resolved == null) {
          if (!candidate.startsWith('dart:') &&
              !_isAllowedExternalPackageUri(candidate, config)) {
            issues.add('[reachable-uri-unresolved] $path $candidate');
            exactValid = false;
          }
          continue;
        }
        visit(resolved, exactAllowed: exactAllowed && selected.exact);
      }
    }
  }

  visit(
    start,
    exactAllowed: complete || target.domain == OracleRootDomain.external,
  );
  if (!exactValid) exact.clear();
  return (exactValid: exactValid);
}

({Set<String> exact, Set<String> retained, Set<String> uncertainties})
_externalPublicSurface({
  required String entrypoint,
  required Map<String, String> environment,
  required Map<String, _LibraryInfo> libraries,
  required Set<String> modeled,
  required _PackageConfig? config,
  required Set<String> invalidLibraries,
  required List<String> issues,
}) {
  final exact = <String>{};
  final retained = <String>{};
  final uncertainties = <String>{};
  final visiting = <String>{};
  final publicIssues = <String>{};
  void addPublicIssue(String issue) {
    if (publicIssues.add(issue)) issues.add(issue);
  }

  Map<String, Set<_PublicDeclaration>> visit(
    String path, {
    required bool exactAllowed,
  }) {
    if (!visiting.add(path)) return const {};
    if (!modeled.contains(path) &&
        !_isAllowedLocalDependencyPath(path, config)) {
      addPublicIssue('[public-owner-unresolved] $path');
      return const {};
    }
    final info = libraries[path];
    if (info == null) {
      addPublicIssue('[public-owner-unresolved] $path');
      return const {};
    }
    if (invalidLibraries.contains(path)) {
      addPublicIssue('[public-owner-invalid] $path');
    }
    final pathExactAllowed = exactAllowed && !invalidLibraries.contains(path);
    final namespace = <String, Set<_PublicDeclaration>>{};
    void addDeclarations(String declarationPath, String owner) {
      final declarationInfo = libraries[declarationPath];
      if (declarationInfo == null) {
        addPublicIssue('[public-owner-unresolved] $declarationPath');
        return;
      }
      final invalidOwner = invalidLibraries.contains(owner);
      final invalidDeclaration = invalidLibraries.contains(declarationPath);
      if (invalidOwner || invalidDeclaration) {
        addPublicIssue('[public-owner-invalid] $declarationPath');
      }
      for (final declaration in declarationInfo.publicDeclarations) {
        _mergePublicDeclaration(
          namespace.putIfAbsent(declaration, () => <_PublicDeclaration>{}),
          _PublicDeclaration(
            declarationPath: declarationPath,
            ownerLibraryPath: owner,
            name: declaration,
            exact: pathExactAllowed && !invalidOwner && !invalidDeclaration,
          ),
        );
      }
    }

    addDeclarations(path, path);
    for (final directive in info.directives) {
      if (directive.kind == _DirectiveKind.part) {
        final part = _resolveUri(directive.defaultUri, path, config);
        if (part == null) {
          addPublicIssue(
            '[public-owner-unresolved] $path ${directive.defaultUri}',
          );
        } else {
          addDeclarations(part, path);
        }
        continue;
      }
      if (directive.kind != _DirectiveKind.export) continue;
      final selected = directive.selectedUri(environment);
      final exactBranch = selected.exact;
      final uris = exactBranch ? [selected.uri] : directive.allUris;
      for (final uri in uris.whereType<String>()) {
        final child = _resolveUri(uri, path, config);
        if (child == null) {
          if (!uri.startsWith('dart:')) {
            addPublicIssue('[public-owner-unresolved] $path $uri');
          }
          continue;
        }
        final childNamespace = visit(
          child,
          exactAllowed: pathExactAllowed && exactBranch,
        );
        for (final entry in childNamespace.entries) {
          if (_isExportedName(entry.key, directive.combinators)) {
            final declarations = namespace.putIfAbsent(
              entry.key,
              () => <_PublicDeclaration>{},
            );
            for (final declaration in entry.value) {
              _mergePublicDeclaration(
                declarations,
                declaration.withExact(pathExactAllowed && declaration.exact),
              );
            }
          }
        }
      }
    }
    visiting.remove(path);
    return namespace;
  }

  final namespace = visit(entrypoint, exactAllowed: true);
  for (final entry in namespace.entries) {
    for (final declaration in entry.value) {
      retained.add(declaration.node);
    }
    if (entry.value.length == 1 && entry.value.single.exact) {
      exact.add(entry.value.single.node);
    } else if (entry.value.length > 1) {
      uncertainties.add(
        '[public-namespace-ambiguous] $entrypoint ${entry.key}',
      );
    }
  }
  return (exact: exact, retained: retained, uncertainties: uncertainties);
}

bool _isExportedName(String name, List<_CombinatorOperation> operations) {
  var visible = true;
  for (final operation in operations) {
    if (operation.show) {
      visible = visible && operation.names.contains(name);
    } else if (operation.names.contains(name)) {
      visible = false;
    }
  }
  return visible;
}

void _mergePublicDeclaration(
  Set<_PublicDeclaration> declarations,
  _PublicDeclaration incoming,
) {
  final existing = declarations.lookup(incoming);
  if (existing == null) {
    declarations.add(incoming);
  } else if (!existing.exact && incoming.exact) {
    declarations
      ..remove(existing)
      ..add(existing.withExact(true));
  }
}

final class _PublicDeclaration {
  const _PublicDeclaration({
    required this.declarationPath,
    required this.ownerLibraryPath,
    required this.name,
    required this.exact,
  });

  final String declarationPath;
  final String ownerLibraryPath;
  final String name;
  final bool exact;

  String get node => _declarationNode(declarationPath, name);

  _PublicDeclaration withExact(bool exact) => _PublicDeclaration(
    declarationPath: declarationPath,
    ownerLibraryPath: ownerLibraryPath,
    name: name,
    exact: exact,
  );

  @override
  bool operator ==(Object other) =>
      other is _PublicDeclaration &&
      declarationPath == other.declarationPath &&
      ownerLibraryPath == other.ownerLibraryPath &&
      name == other.name;

  @override
  int get hashCode => Object.hash(declarationPath, ownerLibraryPath, name);
}

final class _PackageConfig {
  _PackageConfig({
    required this.projectRoot,
    required this.packageRoot,
    required this.packageDirectory,
    required this.selectedPackageName,
    required Map<String, _PackageEntry> entries,
  }) : entries = Map.unmodifiable(Map<String, _PackageEntry>.from(entries));

  final String projectRoot;
  final String packageRoot;
  final String packageDirectory;
  final String selectedPackageName;
  final Map<String, _PackageEntry> entries;
}

final class _PackageEntry {
  const _PackageEntry({
    required this.name,
    required this.packageRoot,
    required this.packageDirectory,
    required this.localToProject,
  });

  final String name;
  final String packageRoot;
  final String packageDirectory;
  final bool localToProject;
}

final class _LibraryInfo {
  _LibraryInfo({
    required this.path,
    required this.source,
    required this.directives,
    required this.publicDeclarations,
    required this.callbacks,
    required this.unknownCallbacks,
  });

  factory _LibraryInfo.fromResolved(
    String path,
    CompilationUnit unit,
    String source,
    _UnnamedExtensionIdentityIndex unnamedExtensionIdentities,
  ) => _LibraryInfo._fromResolved(
    path,
    source,
    unit,
    unnamedExtensionIdentities,
  );

  factory _LibraryInfo.fromSource(String path, String source) => _LibraryInfo(
    path: path,
    source: source,
    directives: const [],
    publicDeclarations: const {},
    callbacks: const [],
    unknownCallbacks: [_UnknownCallback(path, 'unresolved_source')],
  );

  factory _LibraryInfo._fromResolved(
    String path,
    String source,
    CompilationUnit unit,
    _UnnamedExtensionIdentityIndex unnamedExtensionIdentities,
  ) {
    final directives = <_DirectiveInfo>[];
    for (final directive in unit.directives) {
      if (directive is ImportDirective || directive is ExportDirective) {
        final namespace = directive as NamespaceDirective;
        final uri = namespace.uri.stringValue;
        if (uri == null) continue;
        directives.add(
          _DirectiveInfo(
            kind: directive is ExportDirective
                ? _DirectiveKind.export
                : _DirectiveKind.import,
            defaultUri: uri,
            branches: [
              for (final branch in namespace.configurations)
                if (branch.uri.stringValue case final branchUri?)
                  _ConditionalBranch(
                    name: branch.name.toSource(),
                    value: branch.value?.stringValue,
                    uri: branchUri,
                  ),
            ],
            combinators: [
              for (final combinator in namespace.combinators)
                _CombinatorOperation.fromAst(combinator),
            ],
          ),
        );
      } else if (directive is PartDirective) {
        final uri = directive.uri.stringValue;
        if (uri != null) {
          directives.add(
            _DirectiveInfo(
              kind: _DirectiveKind.part,
              defaultUri: uri,
              branches: const [],
              combinators: const [],
            ),
          );
        }
      }
    }
    final declarations = <String>{};
    final callbacks = <_CallbackRoot>[];
    for (final declaration in unit.declarations) {
      final name = _declarationName(declaration);
      declarations.addAll(_publicDeclarationNames(declaration));
      if (name != null && _isResolvedVmEntrypoint(declaration.metadata)) {
        callbacks.add(
          _CallbackRoot(path, name, CallbackCapabilityKind.vmPragma),
        );
      }
      if (name != null && _isResolvedNativeCallback(declaration.metadata)) {
        callbacks.add(
          _CallbackRoot(path, name, CallbackCapabilityKind.ffiNativeCallback),
        );
      }
    }
    final visitor = _ResolvedCallbackVisitor(path, unnamedExtensionIdentities);
    unit.accept(visitor);
    callbacks.addAll(visitor.callbacks);
    return _LibraryInfo(
      path: path,
      source: source,
      directives: directives,
      publicDeclarations: declarations,
      callbacks: callbacks,
      unknownCallbacks: visitor.unknownCallbacks,
    );
  }

  final String path;
  final String source;
  final List<_DirectiveInfo> directives;
  final Set<String> publicDeclarations;
  final List<_CallbackRoot> callbacks;
  final List<_UnknownCallback> unknownCallbacks;
}

final class _DirectiveInfo {
  _DirectiveInfo({
    required this.kind,
    required this.defaultUri,
    required List<_ConditionalBranch> branches,
    required List<_CombinatorOperation> combinators,
  }) : branches = List.unmodifiable(List<_ConditionalBranch>.from(branches)),
       combinators = List.unmodifiable(
         List<_CombinatorOperation>.from(combinators),
       );

  final _DirectiveKind kind;
  final String defaultUri;
  final List<_ConditionalBranch> branches;
  final List<_CombinatorOperation> combinators;

  List<String> get allUris => [
    defaultUri,
    ...branches.map((branch) => branch.uri),
  ];

  ({String? uri, bool exact}) selectedUri(Map<String, String> environment) {
    for (final branch in branches) {
      final actual = environment[branch.name];
      if (actual == null) return (uri: null, exact: false);
      final expected = branch.value ?? 'true';
      if (actual == expected) return (uri: branch.uri, exact: true);
    }
    return (uri: defaultUri, exact: true);
  }
}

final class _CombinatorOperation {
  const _CombinatorOperation(this.show, this.names);

  factory _CombinatorOperation.fromAst(
    Combinator combinator,
  ) => switch (combinator) {
    ShowCombinator() => _CombinatorOperation(
      true,
      Set.unmodifiable(combinator.shownNames.map((name) => name.name).toSet()),
    ),
    HideCombinator() => _CombinatorOperation(
      false,
      Set.unmodifiable(combinator.hiddenNames.map((name) => name.name).toSet()),
    ),
  };

  final bool show;
  final Set<String> names;
}

enum _DirectiveKind { import, export, part }

final class _ConditionalBranch {
  const _ConditionalBranch({
    required this.name,
    required this.value,
    required this.uri,
  });

  final String name;
  final String? value;
  final String uri;
}

final class _CallbackRoot {
  const _CallbackRoot(this.path, this.name, this.kind);

  final String path;
  final String name;
  final CallbackCapabilityKind kind;
}

String? _declarationName(CompilationUnitMember declaration) =>
    switch (declaration) {
      ClassDeclaration() => declaration.namePart.beginToken.lexeme,
      EnumDeclaration() => declaration.namePart.beginToken.lexeme,
      ExtensionDeclaration() => declaration.name?.lexeme,
      ExtensionTypeDeclaration() =>
        declaration.primaryConstructor.beginToken.lexeme,
      FunctionDeclaration() => declaration.name.lexeme,
      GenericTypeAlias() => declaration.name.lexeme,
      MixinDeclaration() => declaration.name.lexeme,
      TopLevelVariableDeclaration() =>
        declaration.variables.variables.length == 1
            ? declaration.variables.variables.single.name.lexeme
            : null,
      _ => null,
    };

Iterable<String> _publicDeclarationNames(CompilationUnitMember declaration) =>
    switch (declaration) {
      TopLevelVariableDeclaration() =>
        declaration.variables.variables
            .map((variable) => variable.name.lexeme)
            .where((name) => !name.startsWith('_')),
      _ => switch (_declarationName(declaration)) {
        final name? when !name.startsWith('_') => [name],
        _ => const <String>[],
      },
    };

bool _isResolvedVmEntrypoint(Iterable<Annotation> metadata) {
  for (final annotation in metadata) {
    if (annotation.element == null ||
        annotation.name.name != 'pragma' ||
        _elementLibraryUri(annotation.element) != 'dart:core') {
      continue;
    }
    final elementAnnotation = annotation.elementAnnotation;
    if (elementAnnotation == null ||
        elementAnnotation.constantEvaluationErrors?.isNotEmpty == true) {
      continue;
    }
    if (elementAnnotation
            .computeConstantValue()
            ?.getField('name')
            ?.toStringValue() ==
        'vm:entry-point') {
      return true;
    }
  }
  return false;
}

bool _isResolvedNativeCallback(Iterable<Annotation> metadata) => metadata.any(
  (annotation) =>
      annotation.element != null &&
      annotation.name.name == 'Native' &&
      _elementLibraryUri(annotation.element) == 'dart:ffi',
);

final class _ResolvedCallbackVisitor extends GeneralizingAstVisitor<void> {
  _ResolvedCallbackVisitor(this.path, this.unnamedExtensionIdentities);

  final String path;
  final _UnnamedExtensionIdentityIndex unnamedExtensionIdentities;
  final List<_CallbackRoot> callbacks = [];
  final List<_UnknownCallback> unknownCallbacks = [];

  @override
  void visitConstructorDeclaration(ConstructorDeclaration node) {
    if (_isResolvedVmEntrypoint(node.metadata)) {
      callbacks.add(
        _CallbackRoot(
          path,
          _constructorCanonicalName(node),
          CallbackCapabilityKind.vmPragma,
        ),
      );
    }
    if (_isResolvedNativeCallback(node.metadata)) {
      callbacks.add(
        _CallbackRoot(
          path,
          _constructorCanonicalName(node),
          CallbackCapabilityKind.ffiNativeCallback,
        ),
      );
    }
    super.visitConstructorDeclaration(node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    final name = _memberCanonicalName(node, unnamedExtensionIdentities);
    if (_isResolvedVmEntrypoint(node.metadata)) {
      callbacks.add(_CallbackRoot(path, name, CallbackCapabilityKind.vmPragma));
    }
    if (_isResolvedNativeCallback(node.metadata)) {
      callbacks.add(
        _CallbackRoot(path, name, CallbackCapabilityKind.ffiNativeCallback),
      );
    }
    super.visitMethodDeclaration(node);
  }

  @override
  void visitMethodInvocation(MethodInvocation node) {
    final name = node.methodName.name;
    final element = node.methodName.element;
    final libraryUri = _elementLibraryUri(element);
    final callback = _callbackArgument(node, path, unnamedExtensionIdentities);
    void unknown() {
      unknownCallbacks.add(_UnknownCallback(path, callback?.name ?? name));
    }

    if (name == 'spawn') {
      if (libraryUri == 'dart:isolate' && callback != null) {
        callbacks.add(
          _CallbackRoot(
            callback.path,
            callback.name,
            CallbackCapabilityKind.isolateSpawn,
          ),
        );
      } else {
        unknown();
      }
    }
    if (name == 'initialize') {
      if (libraryUri == 'package:workmanager/workmanager.dart' &&
          callback != null) {
        callbacks.add(
          _CallbackRoot(
            callback.path,
            callback.name,
            CallbackCapabilityKind.workmanagerInitialize,
          ),
        );
      } else {
        unknown();
      }
    }
    if (name == 'getCallbackHandle') {
      if (isExactDartUiCallbackLibraryUri(libraryUri) && callback != null) {
        callbacks.add(
          _CallbackRoot(
            callback.path,
            callback.name,
            CallbackCapabilityKind.dartUiCallback,
          ),
        );
      } else {
        unknown();
      }
    }
    super.visitMethodInvocation(node);
  }
}

String _memberCanonicalName(
  MethodDeclaration node,
  _UnnamedExtensionIdentityIndex unnamedExtensionIdentities,
) {
  final element = node.declaredFragment?.element;
  if (element != null) {
    return _elementCanonicalExecutableName(element, unnamedExtensionIdentities);
  }
  final chain = <String>[node.name.lexeme];
  AstNode? ancestor = node.parent;
  while (ancestor != null) {
    switch (ancestor) {
      case ClassDeclaration():
        chain.add(ancestor.namePart.beginToken.lexeme);
        return chain.reversed.join('.');
      case MixinDeclaration():
        chain.add(ancestor.name.lexeme);
        return chain.reversed.join('.');
      case ExtensionDeclaration():
        chain.add(
          ancestor.name?.lexeme ??
              unnamedExtensionIdentities.identityForNode(ancestor),
        );
        return chain.reversed.join('.');
      case EnumDeclaration():
        chain.add(ancestor.namePart.beginToken.lexeme);
        return chain.reversed.join('.');
      case ExtensionTypeDeclaration():
        chain.add(ancestor.primaryConstructor.beginToken.lexeme);
        return chain.reversed.join('.');
      default:
        ancestor = ancestor.parent;
    }
  }
  return chain.single;
}

String _constructorCanonicalName(ConstructorDeclaration node) {
  final element = node.declaredFragment?.element;
  if (element != null) return _elementCanonicalExecutableName(element);
  final suffix = node.name?.lexeme ?? 'new';
  final parent = node.parent;
  final owner = switch (parent) {
    ClassDeclaration() => parent.namePart.beginToken.lexeme,
    EnumDeclaration() => parent.namePart.beginToken.lexeme,
    ExtensionTypeDeclaration() => parent.primaryConstructor.beginToken.lexeme,
    _ => 'constructor@${node.offset}',
  };
  return '$owner.$suffix';
}

String? _elementLibraryUri(Element? element) =>
    element?.library?.uri.toString();

/// Pure production-policy classifier for the dart-ui callback-handle API.
///
/// It is intentionally URI exact, so fixture stubs cannot enable this policy.
bool isExactDartUiCallbackLibraryUri(String? libraryUri) =>
    libraryUri == 'dart:ui';

_CallbackDeclaration? _callbackArgument(
  MethodInvocation node,
  String fallback,
  _UnnamedExtensionIdentityIndex unnamedExtensionIdentities,
) {
  final argument = node.argumentList.arguments.firstOrNull;
  Element? element;
  switch (argument) {
    case SimpleIdentifier():
      element = argument.element;
    case PrefixedIdentifier():
      element = argument.identifier.element;
    case PropertyAccess():
      element = argument.propertyName.element;
    case FunctionReference():
      final function = argument.function;
      if (function is SimpleIdentifier) element = function.element;
      if (function is PrefixedIdentifier) element = function.identifier.element;
      if (function is PropertyAccess) element = function.propertyName.element;
  }
  final declaration = element?.nonSynthetic;
  if (declaration == null || declaration.displayName.isEmpty) return null;
  return _CallbackDeclaration(
    declaration.firstFragment.libraryFragment?.source.fullName ?? fallback,
    _elementCanonicalExecutableName(declaration, unnamedExtensionIdentities),
  );
}

String _elementCanonicalExecutableName(
  Element element, [
  _UnnamedExtensionIdentityIndex? unnamedExtensionIdentities,
]) {
  if (element is ConstructorElement) return element.displayName;
  final names = <String>[element.displayName];
  Element? parent = element.enclosingElement;
  while (parent != null && parent is! LibraryElement) {
    if (parent.displayName.isNotEmpty) {
      names.add(parent.displayName);
    } else if (parent is ExtensionElement) {
      final identities = unnamedExtensionIdentities;
      if (identities == null) {
        throw StateError('unnamed extension identity registry is unavailable');
      }
      names.add(identities.identityForElement(parent));
    }
    parent = parent.enclosingElement;
  }
  return names.reversed.join('.');
}

final class _UnnamedExtensionIdentityIndex {
  _UnnamedExtensionIdentityIndex._(this._identitiesBySource);

  factory _UnnamedExtensionIdentityIndex.fromUnits(
    Iterable<CompilationUnit> units,
  ) => _UnnamedExtensionIdentityIndex._({
    for (final unit in units)
      if (unit.declaredFragment?.source.fullName case final sourcePath?)
        sourcePath: _identitiesForUnit(unit),
  });

  final Map<String, Map<int, String>> _identitiesBySource;

  String identityForNode(ExtensionDeclaration node) {
    final locator = node.declaredFragment?.offset;
    if (locator == null) {
      throw StateError('unnamed extension AST fragment is unavailable');
    }
    final identity = _identitiesForUnit(node.root as CompilationUnit)[locator];
    if (identity == null) {
      throw StateError('unnamed extension AST fragment is not indexed');
    }
    return identity;
  }

  String identityForElement(ExtensionElement element) {
    final fragment = element.firstFragment;
    final sourcePath = fragment.libraryFragment.source.fullName;
    final identities = _identitiesBySource[sourcePath];
    if (identities == null) {
      throw StateError('unnamed extension source is outside the registry');
    }
    final identity = identities[fragment.offset];
    if (identity == null) {
      throw StateError('unnamed extension fragment is not indexed');
    }
    return identity;
  }

  static Map<int, String> _identitiesForUnit(CompilationUnit unit) {
    final declarations = <(ExtensionDeclaration, String)>[];
    final totals = <String, int>{};
    for (final extension
        in unit.declarations.whereType<ExtensionDeclaration>()) {
      if (extension.name != null) continue;
      final fingerprint = _extensionTokenFingerprint(extension);
      if (fingerprint == null) continue;
      declarations.add((extension, fingerprint));
      totals.update(fingerprint, (value) => value + 1, ifAbsent: () => 1);
    }
    final occurrences = <String, int>{};
    final identities = <int, String>{};
    for (final entry in declarations) {
      final extension = entry.$1;
      final fingerprint = entry.$2;
      final occurrence = occurrences.update(
        fingerprint,
        (value) => value + 1,
        ifAbsent: () => 1,
      );
      final suffix = totals[fingerprint]! > 1 ? '~$occurrence' : '';
      final locator = extension.declaredFragment?.offset;
      if (locator != null) {
        identities[locator] = 'unnamed-extension:$fingerprint$suffix';
      }
    }
    return identities;
  }
}

String? _extensionTokenFingerprint(ExtensionDeclaration extension) {
  final tokens = StringBuffer('unnamed-extension-owner-v1;');
  var token = extension.metadata.isNotEmpty
      ? extension.metadata.first.beginToken
      : extension.firstTokenAfterCommentAndMetadata;
  while (true) {
    if (token.isSynthetic) return null;
    tokens
      ..write(token.lexeme.length)
      ..write(':')
      ..write(token.lexeme)
      ..write(';');
    if (identical(token, extension.endToken)) break;
    token = token.next!;
  }
  return sha256.convert(utf8.encode(tokens.toString())).toString();
}

final class _CallbackDeclaration {
  const _CallbackDeclaration(this.path, this.name);

  final String path;
  final String name;
}

final class _UnknownCallback {
  const _UnknownCallback(this.path, this.declarationName);

  final String path;
  final String declarationName;
}

({bool complete, Map<String, String> values, String reason}) _testEnvironment(
  String source,
) {
  final match = RegExp(
    r'oracle-test-platforms:\s*(vm|browser)',
  ).firstMatch(source);
  if (match == null) {
    return (
      complete: false,
      values: const {'test.platform': 'unknown'},
      reason: 'unannotated test platform',
    );
  }
  final platform = match.group(1)!;
  return (
    complete: true,
    values: {
      'test.platform': platform,
      'dart.library.io': platform == 'vm' ? 'true' : 'false',
      'dart.library.html': platform == 'browser' ? 'true' : 'false',
    },
    reason: 'fixture test platform $platform',
  );
}

String? _resolveUri(String uri, String from, _PackageConfig? config) {
  if (uri.startsWith('dart:')) return null;
  final parsed = Uri.tryParse(uri);
  if (parsed?.scheme == 'file') {
    final candidate = p.normalize(parsed!.toFilePath());
    if (config == null || !_isWithinOrEqual(config.projectRoot, candidate)) {
      return null;
    }
    return _relativeProjectPath(candidate, config.projectRoot);
  }
  if (uri.startsWith('package:')) {
    if (config == null) return null;
    final rest = uri.substring('package:'.length);
    final slash = rest.indexOf('/');
    final name = slash == -1 ? rest : rest.substring(0, slash);
    final entry = config.entries[name];
    if (entry == null) {
      return null;
    }
    final candidate = p.normalize(
      p.join(
        entry.packageDirectory,
        slash == -1 ? '' : rest.substring(slash + 1),
      ),
    );
    if (!_isWithinOrEqual(entry.packageDirectory, candidate) ||
        !entry.localToProject) {
      return null;
    }
    return _relativeProjectPath(candidate, config.projectRoot);
  }
  if (config == null) {
    return p.posix.normalize(p.posix.join(p.posix.dirname(from), uri));
  }
  final fromAbsolute = p.normalize(p.join(config.projectRoot, from));
  final owner =
      config.entries.values
          .where((entry) => _isWithinOrEqual(entry.packageRoot, fromAbsolute))
          .toList()
        ..sort(
          (left, right) =>
              right.packageRoot.length.compareTo(left.packageRoot.length),
        );
  if (owner.isEmpty) return null;
  final candidate = p.normalize(p.join(p.dirname(fromAbsolute), uri));
  if (!_isWithinOrEqual(owner.first.packageRoot, candidate)) return null;
  return _relativeProjectPath(candidate, config.projectRoot);
}

Uri _directoryUri(Uri uri) {
  if (uri.scheme != 'file') return uri;
  final path = p.normalize(uri.toFilePath());
  return Uri.file('$path${p.separator}');
}

bool _isWithinOrEqual(String parent, String child) =>
    p.equals(parent, child) || p.isWithin(parent, child);

String _relativeProjectPath(String path, String root) =>
    p.posix.normalize(p.relative(path, from: root).replaceAll('\\', '/'));

bool _isAllowedExternalPackageUri(String uri, _PackageConfig? config) {
  if (!uri.startsWith('package:') || config == null) return false;
  final rest = uri.substring('package:'.length);
  final slash = rest.indexOf('/');
  final name = slash == -1 ? rest : rest.substring(0, slash);
  final entry = config.entries[name];
  return entry != null && !entry.localToProject;
}

bool _isAllowedLocalDependencyPath(String path, _PackageConfig? config) {
  if (config == null) return false;
  final absolute = p.normalize(p.join(config.projectRoot, path));
  return config.entries.values.any(
    (entry) =>
        !p.equals(entry.packageRoot, config.packageRoot) &&
        entry.localToProject &&
        _isWithinOrEqual(entry.packageRoot, absolute),
  );
}

String? _pubspecPackageName(File pubspec) {
  try {
    final yaml = loadYaml(pubspec.readAsStringSync());
    if (yaml is! YamlMap) return null;
    final name = yaml['name'];
    if (name is! String || !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name)) {
      return null;
    }
    return name;
  } on Object {
    return null;
  }
}

String _stableTestId(String path) => _reversibleId(
  p.posix.withoutExtension(
    (path.startsWith('test/') ? path.substring('test/'.length) : path)
        .replaceAll('\\', '/'),
  ),
);

String _callbackTargetId(
  CallbackCapabilityKind kind,
  String path,
  String declaration,
) => '${kind.name}.${_reversibleId(path)}.${_reversibleId(declaration)}';

String _reversibleId(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll('=', '');

Map<String, String> _targetEnvironment(OracleTarget target) =>
    Map.unmodifiable({
      'platform': target.platform,
      'entrypoint': target.entrypoint,
      if (target.flavor != null) 'flavor': target.flavor!,
      ...target.dartDefines,
      'dart.library.html': target.platform == 'web' ? 'true' : 'false',
      'dart.library.io': target.platform == 'web' ? 'false' : 'true',
    });

bool _sameTarget(OracleTarget? left, OracleTarget? right) =>
    (left == null || right == null)
    ? left == null && right == null
    : left.executionContextId == right.executionContextId &&
          left.platform == right.platform &&
          left.entrypoint == right.entrypoint &&
          left.flavor == right.flavor &&
          _mapEquals(left.dartDefines, right.dartDefines);

bool _mapEquals(Map<String, String> left, Map<String, String> right) =>
    left.length == right.length &&
    left.entries.every((entry) => right[entry.key] == entry.value);

OracleAuxiliaryExecutionTarget _toAuxiliaryTarget(RootExecutionTarget target) =>
    OracleAuxiliaryExecutionTarget(
      id: switch (target.domain) {
        OracleRootDomain.test => logicalAuxiliaryIdFromWire(
          target.id,
          OracleAuxiliaryDomain.test,
        ),
        OracleRootDomain.runtime => logicalAuxiliaryIdFromWire(
          target.id,
          OracleAuxiliaryDomain.runtime,
        ),
        OracleRootDomain.external => logicalAuxiliaryIdFromWire(
          target.id,
          OracleAuxiliaryDomain.external,
        ),
        OracleRootDomain.configured => throw ArgumentError(
          'configured target is not auxiliary',
        ),
      },
      domain: switch (target.domain) {
        OracleRootDomain.test => OracleAuxiliaryDomain.test,
        OracleRootDomain.runtime => OracleAuxiliaryDomain.runtime,
        OracleRootDomain.external => OracleAuxiliaryDomain.external,
        OracleRootDomain.configured => throw ArgumentError(
          'configured target is not auxiliary',
        ),
      },
      environmentValues: target.environmentValues,
      environmentComplete: target.environmentComplete,
      reason: target.reason,
      sourceConfiguredTarget: target.sourceTarget,
    );

bool _sameAuxiliaryLists(
  List<OracleAuxiliaryExecutionTarget> left,
  List<OracleAuxiliaryExecutionTarget> right,
) =>
    left.length == right.length &&
    Iterable<int>.generate(left.length).every(
      (index) =>
          left[index].id == right[index].id &&
          left[index].domain == right[index].domain &&
          _mapEquals(
            left[index].environmentValues,
            right[index].environmentValues,
          ) &&
          left[index].environmentComplete == right[index].environmentComplete &&
          left[index].reason == right[index].reason &&
          _sameTarget(
            left[index].sourceConfiguredTarget,
            right[index].sourceConfiguredTarget,
          ),
    );

bool _isGenerated(String path) =>
    path.endsWith('.g.dart') ||
    path.endsWith('.freezed.dart') ||
    path.contains('/generated/');

bool _isContextId(String id) => isCanonicalExecutionTargetId(id);

String _libraryNode(String path) => 'lib:$path';
String _declarationNode(String path, String name) => 'decl:$path#$name';

Map<String, Set<String>> _freezeClosureMap(Map<String, Set<String>> input) =>
    Map.unmodifiable(
      input.map(
        (key, value) =>
            MapEntry(key, Set.unmodifiable(Set<String>.from(value))),
      ),
    );

Map<String, String> _sortedMap(Map<String, String> input) => {
  for (final key in input.keys.toList()..sort()) key: input[key]!,
};

Map<String, Object?> _targetJson(OracleTarget target) => {
  'name': target.name,
  'platform': target.platform,
  'entrypoint': target.entrypoint,
  'flavor': target.flavor,
  'dartDefines': _sortedMap(target.dartDefines),
};
