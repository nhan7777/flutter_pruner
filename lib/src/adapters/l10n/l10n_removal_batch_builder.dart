import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/confidence/mutation_footprint.dart';
import '../../core/project/project_context.dart';
import 'action_readiness/immutable_bytes.dart';
import 'l10n_config.dart';
import 'l10n_mutation_selection.dart';
import 'l10n_removal_batch.dart';
import 'l10n_staging_manager.dart';

/// Builds L10nRemovalBatch from staging evidence.
///
/// Converts witnessed staging results into a validated removal batch
/// with baseline and candidate hashes.
class L10nRemovalBatchBuilder {
  /// Creates a batch builder.
  const L10nRemovalBatchBuilder();

  /// Builds a removal batch from staging evidence.
  ///
  /// Validates:
  /// - Candidate hashes match witnessed bytes
  /// - Paths are within project (no traversal)
  /// - No duplicate paths
  /// - Footprint matches write set
  Future<L10nRemovalBatch> build({
    required String familyId,
    required L10nMutationSelection selection,
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
    required String configFingerprint,
    required MutationFootprint footprint,
    required Map<String, String> arbBaselineHashes,
    required StagingInspectionResult inspection,
  }) async {
    // Validate selection
    selection.validate();

    // Capture baseline ARB files from the pre-mutation snapshot
    final arbMutations = await _buildArbMutations(
      staging: staging,
      project: project,
      config: config,
      keys: selection.effectiveKeys,
      baselineHashes: arbBaselineHashes,
    );

    // Build generated output mutations from the passed inspection result
    // (avoids duplicate StagingManager instantiation + inspection)
    final generatedMutations = await _buildGeneratedMutations(
      staging: staging,
      project: project,
      config: config,
      candidates: inspection.candidates,
    );

    // Validate paths within project
    _validatePaths(
      arbMutations: arbMutations,
      generatedMutations: generatedMutations,
      project: project,
    );

    // Build batch
    final batch = L10nRemovalBatch(
      familyId: familyId,
      selection: selection,
      arbMutations: arbMutations,
      generatedOutputMutations: generatedMutations,
      configurationFingerprint: configFingerprint,
      packageResolutionFingerprint: 'flutter-sdk', // TODO: proper fingerprint
      toolchainFingerprint: 'flutter-gen-l10n', // TODO: proper fingerprint
      footprint: footprint,
    );

    // Validate batch
    batch.validate();

    return batch;
  }

  Future<List<L10nArbMutation>> _buildArbMutations({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
    required Set<String> keys,
    required Map<String, String> baselineHashes,
  }) async {
    final mutations = <L10nArbMutation>[];
    final arbDirRelative = project.relative(config.arbDir);
    final arbDir = Directory(p.join(staging.path, arbDirRelative));

    if (!arbDir.existsSync()) {
      throw StateError('ARB directory not found in staging: ${arbDir.path}');
    }

    final arbFiles = arbDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.arb')
        .toList();

    for (final stagingArbFile in arbFiles) {
      final basename = p.basename(stagingArbFile.path);
      final relativePath = p.join(arbDirRelative, basename);

      // Read baseline from the live project, but verify it still matches the
      // pre-mutation snapshot captured by the executor. Any drift between
      // preflight and batch-build fails closed (TOCTOU protection).
      final projectArbFile = File(p.join(project.root.path, relativePath));
      if (!projectArbFile.existsSync()) {
        throw StateError('Baseline ARB not found: $relativePath');
      }
      final originalBytes = projectArbFile.readAsBytesSync();
      final originalHash = sha256.convert(originalBytes).toString();
      final expectedBaselineHash = baselineHashes[relativePath];
      if (expectedBaselineHash == null) {
        throw StateError(
          'Baseline ARB not captured at preflight: $relativePath',
        );
      }
      if (originalHash != expectedBaselineHash) {
        throw StateError(
          'ARB baseline drift for $relativePath: '
          'expected $expectedBaselineHash, found $originalHash',
        );
      }

      // Read candidate from staging
      final candidateBytes = stagingArbFile.readAsBytesSync();
      final candidateHash = sha256.convert(candidateBytes).toString();

      final stat = projectArbFile.statSync();
      final mode = Platform.isWindows ? 0 : stat.mode;

      mutations.add(
        L10nArbMutation(
          relativePath: relativePath,
          originalBytes: ImmutableBytes.copyOf(originalBytes),
          originalHash: originalHash,
          candidateBytes: ImmutableBytes.copyOf(candidateBytes),
          candidateHash: candidateHash,
          mode: mode,
        ),
      );
    }

    if (mutations.isEmpty) {
      throw StateError('No ARB mutations found in staging');
    }

    return mutations;
  }

  Future<List<L10nGeneratedOutputMutation>> _buildGeneratedMutations({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
    required List<GeneratedFileCandidate> candidates,
  }) async {
    final mutations = <L10nGeneratedOutputMutation>[];

    for (final candidate in candidates) {
      // candidate.relativePath is relative to staging
      // Need to make it relative to project root
      final relativePath = candidate.relativePath;

      // Read candidate bytes from staging
      final stagingFile = File(p.join(staging.path, relativePath));
      if (!stagingFile.existsSync()) {
        throw StateError('Candidate file not found in staging: $relativePath');
      }

      final candidateBytes = stagingFile.readAsBytesSync();
      final computedHash = sha256.convert(candidateBytes).toString();

      // Verify candidate hash matches inspection
      if (computedHash != candidate.sha256) {
        throw StateError(
          'Candidate hash mismatch for $relativePath: '
          'expected ${candidate.sha256}, got $computedHash',
        );
      }

      // Check if file exists in project (baseline)
      final projectFile = File(p.join(project.root.path, relativePath));
      final ImmutableBytes? originalBytes;
      final String? originalHash;

      if (projectFile.existsSync()) {
        final bytes = projectFile.readAsBytesSync();
        originalBytes = ImmutableBytes.copyOf(bytes);
        originalHash = sha256.convert(bytes).toString();
      } else {
        originalBytes = null;
        originalHash = null;
      }

      mutations.add(
        L10nGeneratedOutputMutation(
          relativePath: relativePath,
          originalBytes: originalBytes,
          originalHash: originalHash,
          candidateBytes: ImmutableBytes.copyOf(candidateBytes),
          candidateHash: candidate.sha256,
          mode: candidate.posixMode ?? 0,
        ),
      );
    }

    return mutations;
  }

  void _validatePaths({
    required List<L10nArbMutation> arbMutations,
    required List<L10nGeneratedOutputMutation> generatedMutations,
    required ProjectContext project,
  }) {
    final allPaths = <String>{};

    for (final arb in arbMutations) {
      _validateSinglePath(arb.relativePath, project);
      if (!allPaths.add(arb.relativePath)) {
        throw ArgumentError('Duplicate path: ${arb.relativePath}');
      }
    }

    for (final gen in generatedMutations) {
      _validateSinglePath(gen.relativePath, project);
      if (!allPaths.add(gen.relativePath)) {
        throw ArgumentError('Duplicate path: ${gen.relativePath}');
      }
    }
  }

  void _validateSinglePath(String relativePath, ProjectContext project) {
    // Must be relative
    if (relativePath.startsWith('/') || relativePath.startsWith('\\')) {
      throw ArgumentError('Path must be relative: $relativePath');
    }

    // No parent directory traversal
    if (relativePath.contains('..')) {
      throw ArgumentError('Path traversal not allowed: $relativePath');
    }

    // Normalize and check it's within project
    final normalized = p.normalize(relativePath);
    final absolute = p.join(project.root.path, normalized);
    final canonical = p.normalize(absolute);

    if (!p.isWithin(project.root.path, canonical)) {
      throw ArgumentError('Path must be within project: $relativePath');
    }
  }
}
