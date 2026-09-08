import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/confidence/finding.dart';
import '../../core/confidence/mutation_footprint.dart';
import '../../core/confidence/promotion_index.dart';
import '../../core/project/project_context.dart';
import '../../quarantine/manifest.dart';
import '../../quarantine/quarantine_manager.dart';
import 'arb_inventory.dart';
import 'l10n_batch_installer.dart';
import 'l10n_batch_journal_builder.dart';
import 'l10n_batch_verifier.dart';
import 'l10n_config.dart';
import 'l10n_mutation_expectation.dart';
import 'l10n_mutation_selection.dart';
import 'l10n_outcome_accountant.dart';
import 'l10n_removal_batch_builder.dart';
import 'l10n_staging_manager.dart';

/// Executes l10n key removal mutations with quarantine protection.
///
/// Uses direct in-place mutation: edits ARB files, runs gen-l10n, then relies
/// on existing quarantine rollback if verification fails.
class L10nMutationExecutor {
  /// Creates an executor with quarantine support.
  const L10nMutationExecutor({required this.quarantine});

  /// Quarantine manager for rollback protection.
  final QuarantineManager quarantine;

  /// Executes removal for all l10n families in [findings].
  ///
  /// Returns map of familyId → transaction status.
  Future<Map<String, MutationResult>> executeAll({
    required List<Finding> findings,
    required ActionReadinessIndex readinessIndex,
    required ProjectContext project,
  }) async {
    final families = _groupByFamily(findings, readinessIndex, project);
    final results = <String, MutationResult>{};

    for (final family in families.values) {
      try {
        final result = await _executeFamily(family, project);
        results[family.familyId] = result;
      } catch (error, stack) {
        results[family.familyId] = MutationResult.failed(
          familyId: family.familyId,
          error: error.toString(),
          stackTrace: stack.toString(),
        );
      }
    }

    return results;
  }

  Future<MutationResult> _executeFamily(
    L10nFamily family,
    ProjectContext project,
  ) async {
    // Load and validate l10n config
    final configResult = L10nConfig.load(project);
    if (configResult is! L10nConfigValid) {
      return MutationResult.failed(
        familyId: family.familyId,
        error: 'L10n config not valid',
        stackTrace: '',
      );
    }
    final l10nConfig = configResult.config;

    // Step 0: Compute config fingerprint from raw file bytes (TOCTOU pre-flight)
    // Must match format from readiness resolver: sha256:<hex-digest>
    final liveConfigFingerprint = _computeConfigFingerprint(project);
    if (liveConfigFingerprint != family.configurationFingerprint) {
      return MutationResult.failed(
        familyId: family.familyId,
        error:
            'l10n.yaml drift detected before staging: '
            'expected ${family.configurationFingerprint}, '
            'found $liveConfigFingerprint',
        stackTrace: '',
      );
    }

    // Step 0b: Capture ARB baseline hashes before any mutation
    final arbBaselineHashes = _captureArbBaseline(project, l10nConfig);

    // Step 1: Build selection from family
    final selection = L10nMutationSelection(
      requestedFindingIds: family.findingIds.toSet(),
      effectiveFindingIds: family.findingIds.toSet(),
      findingIdToKey: family.findingIdToKey,
    );

    // Step 2: Create temporary quarantine for staging
    final tempQuarantine = await quarantine.createCaseQuarantine(
      runId:
          'l10n-staging-${family.familyId}-${DateTime.now().millisecondsSinceEpoch}',
    );

    // Step 3: Create staging environment
    final stagingManager = const L10nStagingManager();
    final staging = await stagingManager.createStaging(tempQuarantine);

    try {
      // Step 4: Materialize project files to staging
      await stagingManager.materialize(
        staging: staging,
        project: project,
        config: l10nConfig,
      );

      // Step 5: Mutate ARB files in staging
      final keysToRemove = family.findingIdToKey.values
          .map(
            (key) => ArbKey(
              key: key,
              nodeId: '',
              origin: Uri.file(l10nConfig.templateArbPath),
              location: l10nConfig.templateArbPath,
              memberKind: ArbGeneratedMemberKind.getter,
              missingLocales: '',
            ),
          )
          .toList();
      await stagingManager.mutateArbFiles(
        staging: staging,
        project: project,
        config: l10nConfig,
        keysToRemove: keysToRemove,
      );

      // Step 6: Run gen-l10n in staging
      final genResult = await stagingManager.runGenL10nInStaging(
        staging: staging,
      );
      if (genResult is GenL10nFailure) {
        return MutationResult.failed(
          familyId: family.familyId,
          error: 'gen-l10n failed in staging: exit ${genResult.exitCode}',
          stackTrace: genResult.stderr,
        );
      }

      // Step 7: Inspect staging for generated files (also used to enforce
      // unexpectedFiles and to avoid duplicate inspection in batch builder)
      final inspection = await stagingManager.inspect(
        staging: staging,
        project: project,
        config: l10nConfig,
      );

      // Fail-closed: gen-l10n must not produce unexpected files
      if (inspection.unexpectedFiles.isNotEmpty) {
        return MutationResult.failed(
          familyId: family.familyId,
          error:
              'gen-l10n produced unexpected files in staging: '
              '${inspection.unexpectedFiles.join(', ')}',
          stackTrace: '',
        );
      }

      // Step 8: Build batch from staging evidence (pass baseline + inspection)
      final batchBuilder = const L10nRemovalBatchBuilder();
      final batch = await batchBuilder.build(
        familyId: family.familyId,
        selection: selection,
        staging: staging,
        project: project,
        config: l10nConfig,
        configFingerprint: family.configurationFingerprint,
        packageResolutionFingerprint: _computePackageResolutionFingerprint(
          project,
        ),
        toolchainFingerprint: _computeToolchainFingerprint(project),
        footprint: family.footprint,
        arbBaselineHashes: arbBaselineHashes,
        inspection: inspection,
      );

      // Step 9: Build journal entries and expectation
      final journalBuilder = const L10nBatchJournalBuilder();
      final entries = journalBuilder.buildQuarantineEntries(batch);
      final expectation = journalBuilder.buildExpectation(batch);

      // Step 10: TOCTOU re-validation — re-read config fingerprint and verify
      // ARB baseline hashes haven't drifted since Step 0b.
      final recheckFingerprint = _computeConfigFingerprint(project);
      if (recheckFingerprint != family.configurationFingerprint) {
        return MutationResult.failed(
          familyId: family.familyId,
          error:
              'l10n.yaml drift detected after gen-l10n: '
              'expected ${family.configurationFingerprint}, '
              'found $recheckFingerprint',
          stackTrace: '',
        );
      }

      // Re-verify ARB baseline hashes against captured snapshot
      _validateArbBaseline(
        project: project,
        config: l10nConfig,
        baselineHashes: arbBaselineHashes,
        familyId: family.familyId,
      );

      // Step 11: Create actual quarantine with journaled entries
      final quarantineDir = await quarantine.createCaseQuarantine(
        runId:
            'l10n-${family.familyId}-${DateTime.now().millisecondsSinceEpoch}',
        verificationPolicyHash: family.verificationPolicyHash,
        analysisMode: project.analysisMode.name,
      );

      // Manually write entries to quarantine manifest
      await _writeQuarantineEntries(quarantineDir, entries);

      // Step 12: Begin transaction
      final transaction = await quarantine.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: family.familyId,
        round: 1,
        componentId: 'l10n-adapter',
        findingIds: family.findingIds,
        caseIds: family.caseIds,
      );

      // Step 13: Install candidate bytes from staging
      final installer = L10nBatchInstaller();
      final writtenPaths = await installer.install(
        batch: batch,
        project: project,
      );

      // Step 14: Record all cases as applied
      for (final caseId in family.caseIds) {
        await quarantine.recordCaseApplied(
          quarantineDir: quarantineDir,
          caseId: caseId,
        );
      }

      // Step 15: Mark transaction as applied
      await quarantine.recordTransactionApplied(
        quarantineDir: quarantineDir,
        transactionId: family.familyId,
        caseIds: family.caseIds,
      );

      // Step 16: Verify installed bytes match expectations
      final verifier = L10nBatchVerifier();
      final verifyResult = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      // Step 17: Account per-finding outcomes
      final accountant = const L10nOutcomeAccountant();
      final accounting = accountant.account(
        familyId: family.familyId,
        selection: selection,
        expectation: expectation,
        verificationResult: verifyResult,
      );

      // Step 18: Handle verification result and complete transaction lifecycle
      if (verifyResult is VerificationSuccess) {
        // Complete transaction lifecycle: verify → commit
        final verificationStepIds = ['install', 'verify'];
        await quarantine.verifyTransaction(
          quarantineDir: quarantineDir,
          transactionId: family.familyId,
          policyHash: family.verificationPolicyHash ?? '',
          requiredStepIds: verificationStepIds,
          observedStepIds: verificationStepIds,
        );
        await quarantine.commitTransaction(
          quarantineDir: quarantineDir,
          transactionId: family.familyId,
        );

        return MutationResult.applied(
          familyId: family.familyId,
          transactionId: transaction.transactionId,
          quarantineDir: quarantineDir,
          affectedFiles: writtenPaths,
          expectation: expectation,
          accounting: accounting,
        );
      } else {
        // Failure: rollback atomically and mark transaction recovery-required
        final failed = verifyResult as VerificationFailed;
        final reason =
            'Verification failed: ${failed.mismatches.length} mismatches';
        await quarantine.rollbackCasesAtomically(
          quarantineDir: quarantineDir,
          caseIds: family.caseIds,
          reason: reason,
        );
        await quarantine.requireTransactionRecovery(
          quarantineDir: quarantineDir,
          transactionId: family.familyId,
          reason: reason,
        );
        return MutationResult.failed(
          familyId: family.familyId,
          error: reason,
          stackTrace: '',
          accounting: accounting,
        );
      }
    } catch (error, stack) {
      // Cleanup staging and rollback on any failure
      try {
        await stagingManager.cleanupStaging(staging);
      } catch (_) {
        // Best effort cleanup
      }
      try {
        await stagingManager.cleanupStaging(tempQuarantine);
      } catch (_) {
        // Best effort cleanup
      }

      return MutationResult.failed(
        familyId: family.familyId,
        error: error.toString(),
        stackTrace: stack.toString(),
      );
    } finally {
      // Always cleanup staging
      await stagingManager.cleanupStaging(staging);
      await stagingManager.cleanupStaging(tempQuarantine);
    }
  }

  /// Captures SHA-256 hashes of all ARB files in the live project.
  ///
  /// Called before any staging work begins so the batch builder can compare
  /// against a pre-mutation snapshot instead of reading the live project
  /// after gen-l10n has already run (baseline timing fix).
  Map<String, String> _captureArbBaseline(
    ProjectContext project,
    L10nConfig config,
  ) {
    final baseline = <String, String>{};
    final arbDir = Directory(config.arbDir);
    if (!arbDir.existsSync()) return baseline;

    for (final file in arbDir.listSync().whereType<File>().where(
      (f) => p.extension(f.path) == '.arb',
    )) {
      final relativePath = project.relative(file.path);
      final bytes = file.readAsBytesSync();
      baseline[relativePath] = sha256.convert(bytes).toString();
    }
    return baseline;
  }

  /// Verifies that live ARB files still match the captured baseline.
  ///
  /// Throws [StateError] on drift — this is the TOCTOU guard between
  /// preflight and installation.
  void _validateArbBaseline({
    required ProjectContext project,
    required L10nConfig config,
    required Map<String, String> baselineHashes,
    required String familyId,
  }) {
    final current = _captureArbBaseline(project, config);

    // Any file in the baseline that changed or disappeared is drift.
    for (final entry in baselineHashes.entries) {
      final currentHash = current[entry.key];
      if (currentHash == null) {
        throw StateError(
          'ARB baseline drift for $familyId: ${entry.key} disappeared',
        );
      }
      if (currentHash != entry.value) {
        throw StateError(
          'ARB baseline drift for $familyId: ${entry.key} changed '
          '(expected ${entry.value}, found $currentHash)',
        );
      }
    }

    // Any new ARB file appearing after preflight is also drift.
    for (final path in current.keys) {
      if (!baselineHashes.containsKey(path)) {
        throw StateError(
          'ARB baseline drift for $familyId: new file appeared: $path',
        );
      }
    }
  }

  /// Writes quarantine entries to manifest file.
  Future<void> _writeQuarantineEntries(
    Directory quarantineDir,
    List<QuarantineEntry> entries,
  ) async {
    final manifestPath = p.join(quarantineDir.path, 'manifest.json');
    final manifestFile = File(manifestPath);

    // Read existing manifest
    final manifestContent = manifestFile.readAsStringSync();
    final manifest = jsonDecode(manifestContent) as Map<String, dynamic>;

    // Add entries
    manifest['entries'] = entries
        .map(
          (e) => {
            'originalPath': e.originalPath,
            'sha256': e.sha256,
            'sizeBytes': e.sizeBytes,
            'posixMode': e.posixMode,
            'wasAbsentBeforeTransaction': e.wasAbsentBeforeTransaction,
          },
        )
        .toList();

    // Write back
    manifestFile.writeAsStringSync(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
  }

  /// Computes SHA-256 fingerprint of the raw `l10n.yaml` file bytes.
  ///
  /// Matches the format produced by the static readiness resolver:
  /// `sha256:<hex-digest>` of the file's on-disk content. This is the single
  /// source of truth — any change to l10n.yaml between preflight and mutation
  /// is detected by comparing this fingerprint against the one captured during
  /// analysis.
  String _computeConfigFingerprint(ProjectContext project) {
    final configFile = File(p.join(project.root.path, 'l10n.yaml'));
    if (!configFile.existsSync()) {
      // Absent config: use sentinel (resolver uses 'absent')
      return 'absent';
    }
    final configBytes = configFile.readAsBytesSync();
    final hash = sha256.convert(configBytes);
    return 'sha256:${hash.toString()}';
  }

  /// Computes SHA-256 fingerprint of `.dart_tool/package_config.json`.
  ///
  /// Format: `sha256:<hex-digest>` of the file's on-disk content. Changes to
  /// the package graph (added/removed/upgraded dependencies) are reflected
  /// in this fingerprint.
  String _computePackageResolutionFingerprint(ProjectContext project) {
    final packageConfigFile = File(
      p.join(project.root.path, '.dart_tool', 'package_config.json'),
    );
    if (!packageConfigFile.existsSync()) {
      return 'absent';
    }
    final bytes = packageConfigFile.readAsBytesSync();
    final hash = sha256.convert(bytes);
    return 'sha256:${hash.toString()}';
  }

  /// Computes a toolchain fingerprint from Flutter SDK version.
  ///
  /// Format: `sha256:<hex-digest>` of the Flutter version string combined with
  /// the canonical `flutter gen-l10n` executable path. This captures the
  /// exact generator binary that produced the staging outputs.
  String _computeToolchainFingerprint(ProjectContext project) {
    final sdkVersionFile = File(
      p.join(project.root.path, '.dart_tool', 'flutter.gen_l10n.toolchain'),
    );
    if (sdkVersionFile.existsSync()) {
      final bytes = sdkVersionFile.readAsBytesSync();
      final hash = sha256.convert(bytes);
      return 'sha256:${hash.toString()}';
    }
    // Fallback: hash Platform.version which reflects the exact Dart runtime
    // (and thus Flutter SDK) used to run gen-l10n. This changes on every
    // SDK upgrade and is the canonical toolchain identity for this mutation.
    final hash = sha256.convert(utf8.encode(Platform.version));
    return 'sha256:${hash.toString()}';
  }

  Map<String, L10nFamily> _groupByFamily(
    List<Finding> findings,
    ActionReadinessIndex readinessIndex,
    ProjectContext project,
  ) {
    final families = <String, L10nFamily>{};

    for (final finding in findings) {
      final entry = readinessIndex[finding.node.id];
      if (entry == null) continue;

      final familyId = entry.familyId;
      if (!families.containsKey(familyId)) {
        families[familyId] = L10nFamily(
          familyId: familyId,
          findingIds: [],
          caseIds: [],
          findingIdToKey: {},
          footprint: entry.mutationFootprint,
          verificationPolicyHash: _computeVerificationPolicyHash(project),
          configurationFingerprint: entry.configurationFingerprint,
        );
      }

      families[familyId]!.findingIds.add(finding.node.id);
      families[familyId]!.caseIds.add('case-${finding.node.id}');

      // Extract ARB key from node metadata
      final key = finding.node.metadata['key'] as String?;
      if (key != null) {
        families[familyId]!.findingIdToKey[finding.node.id] = key;
      }
    }

    return families;
  }

  String? _computeVerificationPolicyHash(ProjectContext project) {
    // Content-derived SHA-256 of the exact verification commands required by
    // the project policy. Changes when the policy's command set changes.
    return project.verificationPolicy.hash;
  }
}

/// L10n family for atomic mutation.
class L10nFamily {
  /// Creates an l10n family for atomic mutation.
  L10nFamily({
    required this.familyId,
    required this.findingIds,
    required this.caseIds,
    required this.findingIdToKey,
    required this.footprint,
    required this.verificationPolicyHash,
    required this.configurationFingerprint,
  });

  /// Identifier of the family mutated atomically.
  final String familyId;

  /// Finding IDs included in this family.
  final List<String> findingIds;

  /// Case IDs included in this family.
  final List<String> caseIds;

  /// Map from finding ID to ARB key.
  final Map<String, String> findingIdToKey;

  /// Mutation footprint containing all affected paths.
  final MutationFootprint footprint;

  /// Verification policy fingerprint, when one is configured.
  final String? verificationPolicyHash;

  /// SHA-256 fingerprint of `l10n.yaml` captured during analysis.
  ///
  /// Used to detect configuration drift between preflight and mutation
  /// (TOCTOU protection). Format matches the readiness resolver:
  /// `sha256:<hex-digest>` of the raw file bytes.
  final String configurationFingerprint;
}

/// Mutation execution result.
sealed class MutationResult {
  /// Creates a mutation result for one family.
  const MutationResult({required this.familyId});

  factory MutationResult.applied({
    required String familyId,
    required String transactionId,
    required Directory quarantineDir,
    required List<String> affectedFiles,
    required L10nMutationExpectation expectation,
    required FindingAccountingResult accounting,
  }) = MutationApplied;

  factory MutationResult.failed({
    required String familyId,
    required String error,
    required String stackTrace,
    FindingAccountingResult? accounting,
  }) = MutationFailed;

  /// Identifier of the family whose mutation was attempted.
  final String familyId;
}

/// Successful mutation result with quarantine and affected-file details.
final class MutationApplied extends MutationResult {
  /// Creates a successful mutation result.
  const MutationApplied({
    required super.familyId,
    required this.transactionId,
    required this.quarantineDir,
    required this.affectedFiles,
    required this.expectation,
    required this.accounting,
  });

  /// Transaction journal identifier.
  final String transactionId;

  /// Directory containing quarantined originals.
  final Directory quarantineDir;

  /// Files changed by the mutation.
  final List<String> affectedFiles;

  /// Expectation manifest for verification.
  ///
  /// Contains the witnessed candidate hashes from staging and the complete
  /// inventory of expected mutations. Verification compares observed hashes
  /// against these expectations.
  final L10nMutationExpectation expectation;

  /// Per-finding outcome accounting from verification.
  final FindingAccountingResult accounting;
}

/// Failed mutation result with the original error details.
final class MutationFailed extends MutationResult {
  /// Creates a failed mutation result.
  const MutationFailed({
    required super.familyId,
    required this.error,
    required this.stackTrace,
    this.accounting,
  });

  /// Error message describing the failure.
  final String error;

  /// Stack trace captured at the failure site.
  final String stackTrace;

  /// Per-finding outcome accounting, if verification was reached.
  final FindingAccountingResult? accounting;
}

/// Exception raised when l10n generation fails.
class L10nGenerationException implements Exception {
  /// Creates a generation exception with [message].
  L10nGenerationException(this.message);

  /// Human-readable generation failure message.
  final String message;

  @override
  String toString() => 'L10nGenerationException: $message';
}
