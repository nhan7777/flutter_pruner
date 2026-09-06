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
    final configFingerprint = _computeConfigFingerprint(l10nConfig);

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

      // Step 7: Build batch from staging evidence
      final batchBuilder = const L10nRemovalBatchBuilder();
      final batch = await batchBuilder.build(
        familyId: family.familyId,
        selection: selection,
        staging: staging,
        project: project,
        config: l10nConfig,
        configFingerprint: configFingerprint,
        footprint: family.footprint,
      );

      // Step 8: Build journal entries and expectation
      final journalBuilder = const L10nBatchJournalBuilder();
      final entries = journalBuilder.buildQuarantineEntries(batch);
      final expectation = journalBuilder.buildExpectation(batch);

      // Step 9: Create actual quarantine with journaled entries
      final quarantineDir = await quarantine.createCaseQuarantine(
        runId:
            'l10n-${family.familyId}-${DateTime.now().millisecondsSinceEpoch}',
        verificationPolicyHash: family.verificationPolicyHash,
        analysisMode: project.analysisMode.name,
      );

      // Manually write entries to quarantine manifest
      await _writeQuarantineEntries(quarantineDir, entries);

      // Step 10: Begin transaction
      final transaction = await quarantine.beginTransaction(
        quarantineDir: quarantineDir,
        transactionId: family.familyId,
        round: 1,
        componentId: 'l10n-adapter',
        findingIds: family.findingIds,
        caseIds: family.caseIds,
      );

      // Step 11: Install candidate bytes from staging
      final installer = L10nBatchInstaller();
      final writtenPaths = await installer.install(
        batch: batch,
        project: project,
      );

      // Step 12: Record all cases as applied
      for (final caseId in family.caseIds) {
        await quarantine.recordCaseApplied(
          quarantineDir: quarantineDir,
          caseId: caseId,
        );
      }

      // Step 13: Verify installed bytes match expectations
      final verifier = L10nBatchVerifier();
      final verifyResult = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      // Step 14: Account per-finding outcomes
      final accountant = const L10nOutcomeAccountant();
      final accounting = accountant.account(
        familyId: family.familyId,
        selection: selection,
        expectation: expectation,
        verificationResult: verifyResult,
      );

      // Step 15: Handle verification result
      if (verifyResult is VerificationSuccess) {
        // Success: commit transaction
        return MutationResult.applied(
          familyId: family.familyId,
          transactionId: transaction.transactionId,
          quarantineDir: quarantineDir,
          affectedFiles: writtenPaths,
          expectation: expectation,
          accounting: accounting,
        );
      } else {
        // Failure: rollback atomically
        final failed = verifyResult as VerificationFailed;
        await quarantine.rollbackCasesAtomically(
          quarantineDir: quarantineDir,
          caseIds: family.caseIds,
          reason: 'Verification failed: ${failed.mismatches.length} mismatches',
        );
        return MutationResult.failed(
          familyId: family.familyId,
          error: 'Verification failed: ${failed.mismatches.length} mismatches',
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

  String _computeConfigFingerprint(L10nConfig config) {
    // Compute stable hash of l10n configuration
    final buffer = StringBuffer()
      ..write(config.arbDir)
      ..write(config.templateArbFile)
      ..write(config.outputLocalizationFile)
      ..write(config.outputClass)
      ..write(config.nullableGetter ? 'nullable' : 'nonnullable');
    return _computeSha256(utf8.encode(buffer.toString()));
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

  String _computeSha256(List<int> bytes) {
    if (bytes.isEmpty) return '';
    return sha256.convert(bytes).toString();
  }

  String? _computeVerificationPolicyHash(ProjectContext project) {
    // Compute stable hash of verification commands
    // For now, return null to use default verification without policy tracking
    // TODO: Wire up when project context exposes verification config
    return null;
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
