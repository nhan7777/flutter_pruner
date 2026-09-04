import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'immutable_bytes.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_family_snapshot.dart';
import 'l10n_toolchain.dart';

const _materializationStage = 'stage-materialization';
const _candidateInstallStage = 'candidate-arb-installation';
const _cleanupStage = 'stage-cleanup';
const _unsafeWritableModeMask = 0x12;

/// Allocates one fresh stage directory.
typedef L10nStageDirectoryAllocator = Future<Directory> Function();

/// The immutable generation role assigned to one owned stage root.
enum L10nStageRole {
  /// Frozen unedited inputs used as the comparison baseline.
  baseline,

  /// Inputs after the exact witnessed candidate ARB mutation.
  candidate,
}

/// An observable filesystem operation used only by deterministic tests.
enum L10nStageOperation {
  /// A root has been validated and registered for cleanup.
  afterRootRegistered,

  /// Immediately before one frozen file is written.
  beforeFileWrite,

  /// Immediately after one frozen file is written and its mode is restored.
  afterFileWrite,

  /// Immediately before one witnessed candidate ARB is overwritten.
  beforeCandidateArbWrite,

  /// Immediately after one candidate ARB is overwritten and verified.
  afterCandidateArbWrite,

  /// Immediately before an owned root authority is asked to delete its root.
  beforeCleanupDelete,

  /// Immediately after an owned root authority reports deletion.
  afterCleanupDelete,
}

/// Test-only operation observer and fault-injection seam.
typedef L10nStageOperationHook =
    Future<void> Function(
      L10nStageOperation operation,
      Directory root,
      String? relativePath,
    );

/// One independently owned materialized filesystem root.
final class L10nStageRoot {
  L10nStageRoot._({
    required this.directory,
    required this.identity,
    required this.role,
    required this.toolchainIdentity,
    required Set<String> publishablePaths,
    required Set<String> generationOutputPaths,
    required _StageRootAuthority authority,
    required Object owner,
    required Map<String, _ExpectedStageFile> expectedFiles,
    required Set<String> absentPaths,
    required Map<String, ImmutableBytes> expectedCandidateArbs,
    required L10nStageOperationHook? operationHook,
  }) : publishablePaths = Set<String>.unmodifiable(
         SplayTreeSet<String>.of(publishablePaths),
       ),
       generationOutputPaths = Set<String>.unmodifiable(
         SplayTreeSet<String>.of(generationOutputPaths),
       ),
       _authority = authority,
       _owner = owner,
       _expectedFiles = Map<String, _ExpectedStageFile>.of(expectedFiles),
       _absentPaths = Set<String>.unmodifiable(absentPaths),
       _expectedCandidateArbs = Map<String, ImmutableBytes>.unmodifiable({
         for (final entry in expectedCandidateArbs.entries)
           entry.key: ImmutableBytes.copyOf(entry.value.copy()),
       }),
       _operationHook = operationHook;

  /// Canonical stage directory.
  final Directory directory;

  /// SHA-256 identity of the canonical root path and physical filesystem node.
  final String identity;

  /// Generation role bound by the materializer.
  final L10nStageRole role;

  /// Toolchain identity witnessed by the frozen family snapshot.
  final String toolchainIdentity;

  /// Paths that may later be published after all evidence succeeds.
  final Set<String> publishablePaths;

  /// Exact generated-output allowlist for this stage.
  final Set<String> generationOutputPaths;

  final _StageRootAuthority _authority;
  final Object _owner;
  final Map<String, _ExpectedStageFile> _expectedFiles;
  final Set<String> _absentPaths;
  final Map<String, ImmutableBytes> _expectedCandidateArbs;
  final L10nStageOperationHook? _operationHook;
  bool _candidateArbsInstallAttempted = false;
  bool _candidateArbsInstalled = false;
  bool _sealedForGeneration = false;

  /// Whether cleanup may still remove this exact owned root.
  bool get safeToDelete => _authority.safeToDelete;

  /// Revalidates the exact physical root allocated by this materializer.
  /// Identity drift permanently revokes cleanup authority.
  bool revalidateIdentity() {
    if (!safeToDelete) return false;
    try {
      _requireRootIdentity(this);
      return true;
    } on Object {
      markUnsafeToDelete();
      return false;
    }
  }

  /// Retains the root as diagnostic residue after process uncertainty.
  void markUnsafeToDelete() {
    _authority.markUnsafeToDelete();
  }

  /// Seals a genuine production lease for one canonical generator run.
  ///
  /// Testing roots intentionally have no process-launch capability.
  L10nGenerationWorkingRoot sealForGeneration() {
    if (_sealedForGeneration) {
      throw StateError('stage-root-generation-capability-consumed');
    }
    if (!safeToDelete) {
      throw StateError('stage-root-unsafe-for-generation');
    }
    if (role == L10nStageRole.candidate && !_candidateArbsInstalled) {
      throw StateError('candidate-arbs-not-installed');
    }
    try {
      _verifyCompleteRoot(this);
    } on _StageSignal catch (signal) {
      if (signal.detailCode == 'stage-root-identity-drift') {
        markUnsafeToDelete();
      }
      throw StateError('stage-root-verification-failed');
    } catch (_) {
      throw StateError('stage-root-verification-failed');
    }
    _sealedForGeneration = true;
    return _authority.sealForGeneration();
  }
}

/// Independent baseline and candidate roots for one evidence request.
final class L10nStagePair {
  /// Creates an immutable pair.
  const L10nStagePair({
    required this.baseline,
    required this.candidate,
    required this.copiedBytes,
  });

  /// Frozen unedited root.
  final L10nStageRoot baseline;

  /// Root that may receive the exact witnessed ARB mutation.
  final L10nStageRoot candidate;

  /// Total frozen bytes copied across both roots.
  final int copiedBytes;
}

/// Single-use cleanup ownership for every successfully registered root.
final class L10nStageCleanupLease {
  L10nStageCleanupLease._() : _createdRoots = <L10nStageRoot>[] {
    createdRoots = UnmodifiableListView(_createdRoots);
  }

  final List<L10nStageRoot> _createdRoots;

  /// Roots registered before their first child write.
  late final List<L10nStageRoot> createdRoots;

  bool _consumed = false;

  /// Whether cleanup has already been attempted.
  bool get consumed => _consumed;

  void _register(L10nStageRoot root) {
    if (_consumed) throw StateError('cleanup-lease-consumed');
    _createdRoots.add(root);
  }

  bool _consume() {
    if (_consumed) return false;
    _consumed = true;
    return true;
  }
}

/// Outcome of materializing a frozen family snapshot.
final class L10nStageMaterializationResult {
  /// Creates an immutable materialization result.
  L10nStageMaterializationResult({
    required this.pair,
    required this.cleanupLease,
    required List<L10nEvidenceFailure> failures,
  }) : failures = List<L10nEvidenceFailure>.unmodifiable(failures);

  /// Complete pair, or null when any stage invariant failed.
  final L10nStagePair? pair;

  /// Cleanup ownership, including roots from a partial attempt.
  final L10nStageCleanupLease cleanupLease;

  /// Stable fail-closed rejections.
  final List<L10nEvidenceFailure> failures;

  /// Whether both roots are complete and verified.
  bool get ready => pair != null && failures.isEmpty;
}

/// Outcome of a single cleanup attempt.
final class L10nStageCleanupResult {
  /// Creates an immutable cleanup result.
  L10nStageCleanupResult({
    required this.baselineRemoved,
    required this.candidateRemoved,
    required List<L10nEvidenceFailure> failures,
  }) : failures = List<L10nEvidenceFailure>.unmodifiable(failures);

  /// Whether the registered baseline root was confirmed absent.
  final bool baselineRemoved;

  /// Whether the registered candidate root was confirmed absent.
  final bool candidateRemoved;

  /// Stable cleanup failures.
  final List<L10nEvidenceFailure> failures;
}

/// Materializes and cleans isolated l10n evidence roots.
abstract interface class L10nStageMaterializer {
  /// Copies only immutable snapshot bytes into two independent roots.
  Future<L10nStageMaterializationResult> materialize(
    L10nFamilySnapshot snapshot,
  );

  /// Installs the complete, byte-exact witnessed ARB edit in [candidate].
  Future<List<L10nEvidenceFailure>> installCandidateArbs(
    L10nStageRoot candidate,
    Map<String, ImmutableBytes> replacements,
  );

  /// Consumes [lease] and attempts every registered root exactly once.
  Future<L10nStageCleanupResult> cleanup(L10nStageCleanupLease lease);
}

/// Filesystem-backed, fail-closed stage materializer.
final class DefaultL10nStageMaterializer implements L10nStageMaterializer {
  /// Binds staging to the genuine root leases of [toolchain].
  factory DefaultL10nStageMaterializer({
    required L10nToolchainResolved toolchain,
  }) {
    final originalProjectRoot = toolchain.launch.canonicalOriginalProjectRoot;
    return DefaultL10nStageMaterializer._(
      expectedToolchainIdentity: toolchain.identitySha256,
      canonicalSystemTempRoot: _canonicalDirectory(Directory.systemTemp),
      canonicalOriginalProjectRoot: originalProjectRoot == null
          ? null
          : _canonicalPath(originalProjectRoot),
      rootAllocator: () async {
        final lease = toolchain.launch.createGenerationRootLease();
        return _AllocatedStageRoot(
          directory: lease.directory,
          authority: _GenerationLeaseAuthority(lease),
        );
      },
      operationHook: null,
    );
  }

  /// Creates an injectable directory-only authority for unit tests.
  DefaultL10nStageMaterializer.testing({
    required String expectedToolchainIdentity,
    required Directory canonicalSystemTempRoot,
    required String canonicalOriginalProjectRoot,
    required L10nStageDirectoryAllocator rootAllocator,
    L10nStageOperationHook? operationHook,
  }) : this._(
         expectedToolchainIdentity: expectedToolchainIdentity,
         canonicalSystemTempRoot: _canonicalDirectory(canonicalSystemTempRoot),
         canonicalOriginalProjectRoot: _canonicalPath(
           canonicalOriginalProjectRoot,
         ),
         rootAllocator: () async {
           final directory = await rootAllocator();
           return _AllocatedStageRoot(
             directory: directory,
             authority: _TestingDirectoryAuthority(directory),
           );
         },
         operationHook: operationHook,
       );

  DefaultL10nStageMaterializer._({
    required String expectedToolchainIdentity,
    required String canonicalSystemTempRoot,
    required String? canonicalOriginalProjectRoot,
    required Future<_AllocatedStageRoot> Function() rootAllocator,
    required L10nStageOperationHook? operationHook,
  }) : _expectedToolchainIdentity = expectedToolchainIdentity,
       _canonicalSystemTempRoot = canonicalSystemTempRoot,
       _canonicalOriginalProjectRoot = canonicalOriginalProjectRoot,
       _rootAllocator = rootAllocator,
       _operationHook = operationHook;

  final String _expectedToolchainIdentity;
  final String _canonicalSystemTempRoot;
  final String? _canonicalOriginalProjectRoot;
  final Future<_AllocatedStageRoot> Function() _rootAllocator;
  final L10nStageOperationHook? _operationHook;
  final Object _owner = Object();

  @override
  Future<L10nStageMaterializationResult> materialize(
    L10nFamilySnapshot snapshot,
  ) async {
    final cleanupLease = L10nStageCleanupLease._();
    try {
      final blueprint = _StageBlueprint.fromSnapshot(
        snapshot,
        expectedToolchainIdentity: _expectedToolchainIdentity,
      );
      final baseline = await _allocateAndRegister(
        cleanupLease,
        blueprint,
        L10nStageRole.baseline,
      );
      final candidate = await _allocateAndRegister(
        cleanupLease,
        blueprint,
        L10nStageRole.candidate,
      );
      if (_rootsOverlap(baseline.directory.path, candidate.directory.path)) {
        baseline.markUnsafeToDelete();
        candidate.markUnsafeToDelete();
        throw const _StageSignal('stage-roots-not-independent');
      }

      await _copyBlueprint(baseline, blueprint);
      await _copyBlueprint(candidate, blueprint);
      return L10nStageMaterializationResult(
        pair: L10nStagePair(
          baseline: baseline,
          candidate: candidate,
          copiedBytes: blueprint.presentByteCount * 2,
        ),
        cleanupLease: cleanupLease,
        failures: const [],
      );
    } on _StageSignal catch (signal) {
      return _materializationRejected(cleanupLease, signal);
    } catch (_) {
      return _materializationRejected(
        cleanupLease,
        const _StageSignal('stage-file-write-failed'),
      );
    }
  }

  Future<L10nStageRoot> _allocateAndRegister(
    L10nStageCleanupLease cleanupLease,
    _StageBlueprint blueprint,
    L10nStageRole role,
  ) async {
    late final _AllocatedStageRoot allocated;
    try {
      allocated = await _rootAllocator();
    } catch (_) {
      throw const _StageSignal('stage-root-create-failed');
    }
    late final Directory canonicalDirectory;
    late final String rawIdentity;
    try {
      final type = FileSystemEntity.typeSync(
        allocated.directory.path,
        followLinks: false,
      );
      if (type != FileSystemEntityType.directory) {
        throw const _StageSignal('stage-root-create-failed');
      }
      canonicalDirectory = Directory(
        allocated.directory.resolveSymbolicLinksSync(),
      );
      rawIdentity = _captureRootIdentity(canonicalDirectory.path);
    } on _StageSignal {
      _registerUnsafeDiagnosticRoot(cleanupLease, allocated, blueprint, role);
      rethrow;
    } catch (_) {
      _registerUnsafeDiagnosticRoot(cleanupLease, allocated, blueprint, role);
      throw const _StageSignal('stage-root-create-failed');
    }

    final root = L10nStageRoot._(
      directory: canonicalDirectory,
      identity: sha256.convert(utf8.encode(rawIdentity)).toString(),
      role: role,
      toolchainIdentity: blueprint.toolchainIdentity,
      publishablePaths: blueprint.publishablePaths,
      generationOutputPaths: blueprint.generationOutputPaths,
      authority: allocated.authority,
      owner: _owner,
      expectedFiles: blueprint.expectedFiles,
      absentPaths: blueprint.absentPaths,
      expectedCandidateArbs: blueprint.expectedCandidateArbs,
      operationHook: _operationHook,
    );
    cleanupLease._register(root);
    final originalProjectRoot = _canonicalOriginalProjectRoot;
    if (!p.isWithin(_canonicalSystemTempRoot, canonicalDirectory.path) ||
        (originalProjectRoot != null &&
            _rootsOverlap(canonicalDirectory.path, originalProjectRoot))) {
      root.markUnsafeToDelete();
      throw const _StageSignal('stage-root-location-unsupported');
    }
    try {
      await root._operationHook?.call(
        L10nStageOperation.afterRootRegistered,
        root.directory,
        null,
      );
    } catch (_) {
      root.markUnsafeToDelete();
      throw const _StageSignal('stage-root-create-failed');
    }
    return root;
  }

  void _registerUnsafeDiagnosticRoot(
    L10nStageCleanupLease cleanupLease,
    _AllocatedStageRoot allocated,
    _StageBlueprint blueprint,
    L10nStageRole role,
  ) {
    String diagnosticPath;
    try {
      diagnosticPath = p.normalize(p.absolute(allocated.directory.path));
    } catch (_) {
      diagnosticPath = _canonicalSystemTempRoot;
    }
    final diagnostic = L10nStageRoot._(
      directory: Directory(diagnosticPath),
      identity: sha256
          .convert(
            utf8.encode(
              'unproven\u0000$diagnosticPath\u0000'
              '${identityHashCode(allocated.authority)}',
            ),
          )
          .toString(),
      role: role,
      toolchainIdentity: blueprint.toolchainIdentity,
      publishablePaths: blueprint.publishablePaths,
      generationOutputPaths: blueprint.generationOutputPaths,
      authority: allocated.authority,
      owner: _owner,
      expectedFiles: blueprint.expectedFiles,
      absentPaths: blueprint.absentPaths,
      expectedCandidateArbs: blueprint.expectedCandidateArbs,
      operationHook: _operationHook,
    );
    diagnostic.markUnsafeToDelete();
    cleanupLease._register(diagnostic);
  }

  Future<void> _copyBlueprint(
    L10nStageRoot root,
    _StageBlueprint blueprint,
  ) async {
    for (final expected in blueprint.expectedFiles.values) {
      try {
        _requireRootIdentity(root);
        final target = _prepareNewFile(root, expected.relativePath);
        await root._operationHook?.call(
          L10nStageOperation.beforeFileWrite,
          root.directory,
          expected.relativePath,
        );
        _requireRootIdentity(root);
        _requirePreparedTarget(root, expected.relativePath);
        await target.writeAsBytes(expected.bytes.copy(), flush: true);
        await _restoreMode(target, expected.posixMode);
        await root._operationHook?.call(
          L10nStageOperation.afterFileWrite,
          root.directory,
          expected.relativePath,
        );
        _verifyFile(root, expected);
      } on _StageSignal {
        rethrow;
      } catch (_) {
        throw _StageSignal(
          'stage-file-write-failed',
          relativePath: expected.relativePath,
        );
      }
    }
    _verifyCompleteRoot(root);
  }

  @override
  Future<List<L10nEvidenceFailure>> installCandidateArbs(
    L10nStageRoot candidate,
    Map<String, ImmutableBytes> replacements,
  ) async {
    L10nEvidenceFailure reject(String detailCode, {String? relativePath}) =>
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.editPostconditionFailed,
          stage: _candidateInstallStage,
          detailCode: detailCode,
          relativePath: relativePath,
        );

    if (!identical(candidate._owner, _owner) ||
        candidate.role != L10nStageRole.candidate ||
        !candidate.safeToDelete ||
        candidate._sealedForGeneration) {
      return List.unmodifiable([reject('candidate-root-invalid')]);
    }
    if (candidate._candidateArbsInstallAttempted) {
      return List.unmodifiable([reject('candidate-arbs-already-installed')]);
    }

    final frozen = <String, ImmutableBytes>{
      for (final entry in replacements.entries)
        entry.key: ImmutableBytes.copyOf(entry.value.copy()),
    };
    final expected = candidate._expectedCandidateArbs;
    if (!_sameStringSet(frozen.keys.toSet(), expected.keys.toSet())) {
      return List.unmodifiable([
        reject('candidate-arb-replacement-set-mismatch'),
      ]);
    }
    for (final path in expected.keys) {
      if (!expected[path]!.contentEquals(frozen[path]!)) {
        return List.unmodifiable([
          reject(
            'candidate-arb-replacement-bytes-mismatch',
            relativePath: path,
          ),
        ]);
      }
    }

    candidate._candidateArbsInstallAttempted = true;
    try {
      _requireRootIdentity(candidate);
      _verifyCompleteRoot(candidate);
      for (final path in expected.keys.toList()..sort()) {
        final current = candidate._expectedFiles[path];
        if (current == null) {
          throw _StageSignal(
            'candidate-arb-replacement-set-mismatch',
            relativePath: path,
          );
        }
        final file = File(_stagePath(candidate.directory.path, path));
        final authorityBeforeHook = _captureStageFileAuthority(file.path);
        await candidate._operationHook?.call(
          L10nStageOperation.beforeCandidateArbWrite,
          candidate.directory,
          path,
        );
        _requireCandidateSafe(candidate, path);
        _requireRootIdentity(candidate);
        _verifyCompleteRoot(candidate);
        if (_captureStageFileAuthority(file.path) != authorityBeforeHook) {
          candidate.markUnsafeToDelete();
          throw _StageSignal(
            'candidate-arb-path-identity-drift',
            relativePath: path,
          );
        }
        file.deleteSync();
        final freshFile = _prepareNewFile(candidate, path);
        await freshFile.writeAsBytes(frozen[path]!.copy(), flush: true);
        await _restoreMode(freshFile, current.posixMode);
        final installed = _ExpectedStageFile(
          relativePath: path,
          bytes: frozen[path]!,
          posixMode: current.posixMode,
        );
        _verifyFile(candidate, installed);
        candidate._expectedFiles[path] = installed;
        final installedAuthority = _captureStageFileAuthority(freshFile.path);
        await candidate._operationHook?.call(
          L10nStageOperation.afterCandidateArbWrite,
          candidate.directory,
          path,
        );
        _requireCandidateSafe(candidate, path);
        _requireRootIdentity(candidate);
        _verifyCompleteRoot(candidate);
        if (_captureStageFileAuthority(freshFile.path) != installedAuthority) {
          candidate.markUnsafeToDelete();
          throw _StageSignal(
            'candidate-arb-path-identity-drift',
            relativePath: path,
          );
        }
      }
      _verifyCompleteRoot(candidate);
      candidate._candidateArbsInstalled = true;
      return const [];
    } on _StageSignal catch (signal) {
      return List.unmodifiable([
        reject(
          signal.detailCode == 'candidate-arb-replacement-set-mismatch'
              ? signal.detailCode
              : 'candidate-arb-installation-failed',
          relativePath: signal.relativePath,
        ),
      ]);
    } catch (_) {
      return List.unmodifiable([reject('candidate-arb-installation-failed')]);
    }
  }

  @override
  Future<L10nStageCleanupResult> cleanup(L10nStageCleanupLease lease) async {
    if (!lease._consume()) {
      return L10nStageCleanupResult(
        baselineRemoved: false,
        candidateRemoved: false,
        failures: const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.cleanupFailed,
            stage: _cleanupStage,
            detailCode: 'cleanup-lease-consumed',
          ),
        ],
      );
    }

    var baselineRemoved = false;
    var candidateRemoved = false;
    final failures = <L10nEvidenceFailure>[];
    for (final root in lease._createdRoots.reversed) {
      final label = root.role == L10nStageRole.baseline
          ? 'baseline'
          : 'candidate';
      final outcome = await _cleanupRoot(root, label);
      if (root.role == L10nStageRole.baseline) {
        baselineRemoved = outcome.removed;
      } else {
        candidateRemoved = outcome.removed;
      }
      if (outcome.failure != null) failures.add(outcome.failure!);
    }
    return L10nStageCleanupResult(
      baselineRemoved: baselineRemoved,
      candidateRemoved: candidateRemoved,
      failures: failures,
    );
  }

  Future<_CleanupOutcome> _cleanupRoot(L10nStageRoot root, String label) async {
    L10nEvidenceFailure failure(String detailCode) => L10nEvidenceFailure(
      code: L10nEvidenceRejectionCode.cleanupFailed,
      stage: _cleanupStage,
      detailCode: detailCode,
    );

    if (!root.safeToDelete) {
      return _CleanupOutcome(
        removed: false,
        failure: failure('$label-root-unsafe-to-delete'),
      );
    }
    try {
      _requireRootIdentity(root);
    } catch (_) {
      root.markUnsafeToDelete();
      return _CleanupOutcome(
        removed: false,
        failure: failure('$label-root-identity-drift'),
      );
    }

    try {
      await root._operationHook?.call(
        L10nStageOperation.beforeCleanupDelete,
        root.directory,
        null,
      );
      _requireRootIdentity(root);
      await root._authority.delete();
    } catch (_) {
      root.markUnsafeToDelete();
      return _CleanupOutcome(
        removed: false,
        failure: failure('$label-root-delete-failed'),
      );
    }

    try {
      await root._operationHook?.call(
        L10nStageOperation.afterCleanupDelete,
        root.directory,
        null,
      );
      if (FileSystemEntity.typeSync(root.directory.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        root.markUnsafeToDelete();
        return _CleanupOutcome(
          removed: false,
          failure: failure('$label-root-deletion-unconfirmed'),
        );
      }
    } catch (_) {
      root.markUnsafeToDelete();
      return _CleanupOutcome(
        removed: false,
        failure: failure('$label-root-deletion-unconfirmed'),
      );
    }
    return const _CleanupOutcome(removed: true, failure: null);
  }
}

void _requireCandidateSafe(L10nStageRoot candidate, String relativePath) {
  if (!candidate.safeToDelete) {
    throw _StageSignal('candidate-root-unsafe', relativePath: relativePath);
  }
}

L10nStageMaterializationResult _materializationRejected(
  L10nStageCleanupLease lease,
  _StageSignal signal,
) => L10nStageMaterializationResult(
  pair: null,
  cleanupLease: lease,
  failures: [
    L10nEvidenceFailure(
      code: signal.code,
      stage: _materializationStage,
      detailCode: signal.detailCode,
      relativePath: signal.relativePath,
    ),
  ],
);

final class _StageBlueprint {
  _StageBlueprint({
    required this.expectedFiles,
    required this.absentPaths,
    required this.expectedCandidateArbs,
    required this.publishablePaths,
    required this.generationOutputPaths,
    required this.toolchainIdentity,
    required this.presentByteCount,
  });

  factory _StageBlueprint.fromSnapshot(
    L10nFamilySnapshot snapshot, {
    required String expectedToolchainIdentity,
  }) {
    if (snapshot.toolchainIdentity != expectedToolchainIdentity) {
      throw const _StageSignal(
        'stage-toolchain-identity-mismatch',
        code: L10nEvidenceRejectionCode.toolchainDrift,
      );
    }
    final expectedFiles = SplayTreeMap<String, _ExpectedStageFile>();
    final absentPaths = SplayTreeSet<String>();
    final folded = <String, String>{};
    var byteCount = 0;
    for (final entry in snapshot.entries.values) {
      final path = entry.relativePosixPath;
      final previous = folded[path.toLowerCase()];
      if (previous != null && previous != path) {
        throw _StageSignal('stage-path-casefold-collision', relativePath: path);
      }
      folded[path.toLowerCase()] = path;
      switch (entry.state) {
        case L10nSnapshotAbsent():
          absentPaths.add(path);
        case L10nSnapshotPresent(:final stageBytes, :final posixMode):
          if (!Platform.isWindows &&
              (posixMode == null ||
                  posixMode & 0x100 == 0 ||
                  posixMode & _unsafeWritableModeMask != 0)) {
            throw _StageSignal(
              'stage-file-mode-unsupported',
              relativePath: path,
            );
          }
          final frozenBytes = ImmutableBytes.copyOf(stageBytes.copy());
          expectedFiles[path] = _ExpectedStageFile(
            relativePath: path,
            bytes: frozenBytes,
            posixMode: posixMode,
          );
          byteCount += frozenBytes.length;
      }
    }

    final arbPaths = <String>{
      for (final entry in snapshot.entries.values)
        if (entry.role == L10nSnapshotRole.arbTemplate ||
            entry.role == L10nSnapshotRole.arbLocale)
          entry.relativePosixPath,
    };
    final candidateArbs = <String, ImmutableBytes>{
      for (final entry in snapshot.mutationPlan.candidateArbBytes.entries)
        entry.key: ImmutableBytes.copyOf(entry.value.copy()),
    };
    if (!_sameStringSet(arbPaths, candidateArbs.keys.toSet()) ||
        !candidateArbs.keys.every(expectedFiles.containsKey)) {
      throw const _StageSignal('candidate-arb-replacement-set-mismatch');
    }
    final publishable = <String>{
      ...arbPaths,
      ...snapshot.expectedGeneratedPaths,
      if (snapshot.optionalUntranslatedPath case final path?) path,
    };
    final generationOutputPaths = <String>{
      ...snapshot.expectedGeneratedPaths,
      if (snapshot.optionalUntranslatedPath case final path?) path,
    };
    return _StageBlueprint(
      expectedFiles: Map.unmodifiable(expectedFiles),
      absentPaths: Set.unmodifiable(absentPaths),
      expectedCandidateArbs: Map.unmodifiable(candidateArbs),
      publishablePaths: Set.unmodifiable(publishable),
      generationOutputPaths: Set.unmodifiable(generationOutputPaths),
      toolchainIdentity: snapshot.toolchainIdentity,
      presentByteCount: byteCount,
    );
  }

  final Map<String, _ExpectedStageFile> expectedFiles;
  final Set<String> absentPaths;
  final Map<String, ImmutableBytes> expectedCandidateArbs;
  final Set<String> publishablePaths;
  final Set<String> generationOutputPaths;
  final String toolchainIdentity;
  final int presentByteCount;
}

final class _ExpectedStageFile {
  const _ExpectedStageFile({
    required this.relativePath,
    required this.bytes,
    required this.posixMode,
  });

  final String relativePath;
  final ImmutableBytes bytes;
  final int? posixMode;
}

final class _AllocatedStageRoot {
  const _AllocatedStageRoot({required this.directory, required this.authority});

  final Directory directory;
  final _StageRootAuthority authority;
}

abstract interface class _StageRootAuthority {
  bool get safeToDelete;
  void markUnsafeToDelete();
  Future<void> delete();
  L10nGenerationWorkingRoot sealForGeneration();
}

final class _GenerationLeaseAuthority implements _StageRootAuthority {
  const _GenerationLeaseAuthority(this._lease);

  final L10nGenerationRootLease _lease;

  @override
  bool get safeToDelete => _lease.safeToDelete;

  @override
  void markUnsafeToDelete() => _lease.markUnsafeToDelete();

  @override
  Future<void> delete() async => _lease.cleanup();

  @override
  L10nGenerationWorkingRoot sealForGeneration() => _lease.seal();
}

final class _TestingDirectoryAuthority implements _StageRootAuthority {
  _TestingDirectoryAuthority(this._directory);

  final Directory _directory;
  bool _safeToDelete = true;
  bool _deleteConsumed = false;

  @override
  bool get safeToDelete => _safeToDelete;

  @override
  void markUnsafeToDelete() {
    _safeToDelete = false;
  }

  @override
  Future<void> delete() async {
    if (_deleteConsumed || !_safeToDelete) {
      throw const FileSystemException('stage root deletion unavailable');
    }
    _deleteConsumed = true;
    _directory.deleteSync(recursive: true);
  }

  @override
  L10nGenerationWorkingRoot sealForGeneration() {
    throw StateError('testing-stage-root-has-no-generation-capability');
  }
}

final class _CleanupOutcome {
  const _CleanupOutcome({required this.removed, required this.failure});
  final bool removed;
  final L10nEvidenceFailure? failure;
}

final class _StageSignal implements Exception {
  const _StageSignal(
    this.detailCode, {
    this.relativePath,
    this.code = L10nEvidenceRejectionCode.materializationFailed,
  });
  final String detailCode;
  final String? relativePath;
  final L10nEvidenceRejectionCode code;
}

File _prepareNewFile(L10nStageRoot root, String relativePath) {
  _requireRootIdentity(root);
  final parts = relativePath.split('/');
  var parent = root.directory.path;
  for (final part in parts.take(parts.length - 1)) {
    _requireExactNameAvailable(parent, part, relativePath);
    final child = p.join(parent, part);
    final type = FileSystemEntity.typeSync(child, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      Directory(child).createSync();
    } else if (type == FileSystemEntityType.link) {
      _throwLinkSignal(root, child, relativePath);
    } else if (type != FileSystemEntityType.directory) {
      throw _StageSignal(
        'stage-parent-not-directory',
        relativePath: relativePath,
      );
    }
    _normalizeStageDirectoryMode(child, relativePath);
    _requireContainedDirectory(root, child, relativePath);
    parent = child;
  }
  _requireExactNameAvailable(parent, parts.last, relativePath);
  final target = _stagePath(root.directory.path, relativePath);
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw _StageSignal('stage-file-write-failed', relativePath: relativePath);
  }
  return File(target);
}

void _requirePreparedTarget(L10nStageRoot root, String relativePath) {
  _requireRootIdentity(root);
  final parts = relativePath.split('/');
  var parent = root.directory.path;
  for (final part in parts.take(parts.length - 1)) {
    final child = p.join(parent, part);
    final type = FileSystemEntity.typeSync(child, followLinks: false);
    if (type == FileSystemEntityType.link) {
      _throwLinkSignal(root, child, relativePath);
    }
    if (type != FileSystemEntityType.directory) {
      throw _StageSignal(
        'stage-parent-not-directory',
        relativePath: relativePath,
      );
    }
    _requireStageDirectoryMode(child, relativePath);
    _requireContainedDirectory(root, child, relativePath);
    parent = child;
  }
  final target = _stagePath(root.directory.path, relativePath);
  if (FileSystemEntity.typeSync(target, followLinks: false) !=
      FileSystemEntityType.notFound) {
    throw _StageSignal('stage-file-write-failed', relativePath: relativePath);
  }
}

void _requireExactNameAvailable(
  String parent,
  String expectedName,
  String relativePath,
) {
  final type = FileSystemEntity.typeSync(parent, followLinks: false);
  if (type != FileSystemEntityType.directory) {
    throw _StageSignal(
      'stage-parent-not-directory',
      relativePath: relativePath,
    );
  }
  for (final entity in Directory(parent).listSync(followLinks: false)) {
    final actual = p.basename(entity.path);
    if (actual != expectedName &&
        actual.toLowerCase() == expectedName.toLowerCase()) {
      throw _StageSignal(
        'stage-path-casefold-collision',
        relativePath: relativePath,
      );
    }
  }
}

Never _throwLinkSignal(
  L10nStageRoot root,
  String linkPath,
  String relativePath,
) {
  root.markUnsafeToDelete();
  try {
    final resolved = Link(linkPath).resolveSymbolicLinksSync();
    if (!_isWithinOrEqual(root.directory.path, resolved)) {
      throw _StageSignal('stage-path-escape', relativePath: relativePath);
    }
  } on _StageSignal {
    rethrow;
  } catch (_) {
    // A dangling or unreadable link is still an unsupported staged parent.
  }
  throw _StageSignal('stage-link-unsupported', relativePath: relativePath);
}

void _requireContainedDirectory(
  L10nStageRoot root,
  String path,
  String relativePath,
) {
  try {
    final resolved = Directory(path).resolveSymbolicLinksSync();
    if (!_isWithinOrEqual(root.directory.path, resolved)) {
      throw _StageSignal('stage-path-escape', relativePath: relativePath);
    }
  } on _StageSignal {
    rethrow;
  } catch (_) {
    throw _StageSignal(
      'stage-parent-not-directory',
      relativePath: relativePath,
    );
  }
}

void _normalizeStageDirectoryMode(String path, String relativePath) {
  if (Platform.isWindows) return;
  final result = Process.runSync(_chmodExecutable(), ['0700', path]);
  if (result.exitCode != 0) {
    throw _StageSignal(
      'stage-parent-mode-unsupported',
      relativePath: relativePath,
    );
  }
  _requireStageDirectoryMode(path, relativePath);
}

void _requireStageDirectoryMode(String path, String relativePath) {
  if (Platform.isWindows) return;
  final stat = Directory(path).statSync();
  if (stat.type != FileSystemEntityType.directory ||
      stat.mode & 0xfff != 0x1c0) {
    throw _StageSignal(
      'stage-parent-mode-unsupported',
      relativePath: relativePath,
    );
  }
}

Future<void> _restoreMode(File file, int? mode) async {
  if (Platform.isWindows || mode == null) return;
  if (mode & _unsafeWritableModeMask != 0) {
    throw const _StageSignal('stage-file-mode-unsupported');
  }
  final result = await Process.run(_chmodExecutable(), [
    mode.toRadixString(8).padLeft(4, '0'),
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw const _StageSignal('stage-file-write-failed');
  }
}

String _chmodExecutable() =>
    File('/bin/chmod').existsSync() ? '/bin/chmod' : '/usr/bin/chmod';

void _verifyCompleteRoot(L10nStageRoot root) {
  _requireRootIdentity(root);
  final expectedDirectories = <String>{};
  for (final path in root._expectedFiles.keys) {
    final parts = path.split('/');
    for (var count = 1; count < parts.length; count++) {
      expectedDirectories.add(parts.take(count).join('/'));
    }
  }
  final seenFiles = <String>{};
  for (final entity in root.directory.listSync(
    recursive: true,
    followLinks: false,
  )) {
    final relative = _relativePosix(entity.path, root.directory.path);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      _throwLinkSignal(root, entity.path, relative);
    }
    if (type == FileSystemEntityType.directory) {
      if (!expectedDirectories.contains(relative)) {
        throw _StageSignal('stage-unexpected-entry', relativePath: relative);
      }
      _requireStageDirectoryMode(entity.path, relative);
      _requireContainedDirectory(root, entity.path, relative);
      continue;
    }
    if (type != FileSystemEntityType.file ||
        !root._expectedFiles.containsKey(relative)) {
      throw _StageSignal('stage-unexpected-entry', relativePath: relative);
    }
    seenFiles.add(relative);
  }
  if (!_sameStringSet(seenFiles, root._expectedFiles.keys.toSet())) {
    throw const _StageSignal('stage-file-verification-failed');
  }
  for (final expected in root._expectedFiles.values) {
    _verifyFile(root, expected);
  }
  for (final path in root._absentPaths) {
    if (FileSystemEntity.typeSync(
          _stagePath(root.directory.path, path),
          followLinks: false,
        ) !=
        FileSystemEntityType.notFound) {
      throw _StageSignal(
        'stage-absence-verification-failed',
        relativePath: path,
      );
    }
  }
}

void _verifyFile(L10nStageRoot root, _ExpectedStageFile expected) {
  _requireRootIdentity(root);
  final path = _stagePath(root.directory.path, expected.relativePath);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw _StageSignal(
      'stage-file-verification-failed',
      relativePath: expected.relativePath,
    );
  }
  final file = File(path);
  final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
  final stat = file.statSync();
  if (!bytes.contentEquals(expected.bytes) ||
      (!Platform.isWindows &&
          expected.posixMode != null &&
          stat.mode & 0xfff != expected.posixMode)) {
    throw _StageSignal(
      'stage-file-verification-failed',
      relativePath: expected.relativePath,
    );
  }
}

void _requireRootIdentity(L10nStageRoot root) {
  final type = FileSystemEntity.typeSync(
    root.directory.path,
    followLinks: false,
  );
  if (type != FileSystemEntityType.directory) {
    throw const _StageSignal('stage-root-identity-drift');
  }
  final raw = _captureRootIdentity(root.directory.path);
  final current = sha256.convert(utf8.encode(raw)).toString();
  if (current != root.identity) {
    throw const _StageSignal('stage-root-identity-drift');
  }
}

String _captureStageFileAuthority(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _StageSignal('stage-file-verification-failed');
  }
  if (!Platform.isWindows) {
    final result = Process.runSync(
      '/usr/bin/stat',
      Platform.isMacOS ? ['-f', '%d:%i:%l', path] : ['-c', '%d:%i:%h', path],
    );
    if (result.exitCode != 0) {
      throw const _StageSignal('stage-file-verification-failed');
    }
    return (result.stdout as String).trim();
  }
  final stat = File(path).statSync();
  return [
    p.normalize(p.absolute(path)),
    stat.type.toString(),
    stat.size.toString(),
    stat.changed.microsecondsSinceEpoch.toString(),
    stat.modified.microsecondsSinceEpoch.toString(),
  ].join('\u0000');
}

String _captureRootIdentity(String path) {
  final canonical = Directory(path).resolveSymbolicLinksSync();
  if (!Platform.isWindows) {
    final executable = Platform.isMacOS ? '/usr/bin/stat' : '/usr/bin/stat';
    if (File(executable).existsSync()) {
      final result = Process.runSync(
        executable,
        Platform.isMacOS
            ? ['-f', '%d:%i', canonical]
            : ['-c', '%d:%i', canonical],
      );
      if (result.exitCode == 0) {
        return '$canonical\u0000${(result.stdout as String).trim()}';
      }
    }
  }
  final stat = Directory(canonical).statSync();
  // Dart exposes the Windows creation-time authority through `changed`.
  // Directory size and modified time are deliberately excluded because child
  // materialization changes them while the physical root remains the same.
  return [
    canonical,
    stat.type.toString(),
    stat.mode.toRadixString(16),
    stat.changed.microsecondsSinceEpoch.toString(),
  ].join('\u0000');
}

String _canonicalDirectory(Directory directory) =>
    directory.resolveSymbolicLinksSync();

String _canonicalPath(String path) =>
    Directory(path).resolveSymbolicLinksSync();

String _stagePath(String root, String relativePosixPath) =>
    p.joinAll([root, ...relativePosixPath.split('/')]);

String _relativePosix(String path, String root) =>
    p.relative(path, from: root).split(p.separator).join('/');

bool _rootsOverlap(String left, String right) =>
    _isWithinOrEqual(left, right) || _isWithinOrEqual(right, left);

bool _isWithinOrEqual(String root, String path) =>
    p.equals(root, path) || p.isWithin(root, path);

bool _sameStringSet(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);
