import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_installer.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_journal_builder.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_outcome_accountant.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:test/test.dart';

/// Integration tests for the unified staging → batch → install → verify flow.
///
/// These tests verify the complete data flow through all Phase 2 components:
/// 1. Selection normalization
/// 2. Batch creation with baseline + candidate hashes
/// 3. Journal building with expectation manifest
/// 4. Atomic installation
/// 5. Hash-based verification
/// 6. Per-finding outcome accounting
void main() {
  group('L10n Unified Flow Integration', () {
    late Directory tempDir;
    late ProjectContext project;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('l10n_flow_test_');

      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_project
environment:
  sdk: '>=3.0.0 <4.0.0'
''');

      project = await ProjectContext.load(tempDir);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('full happy path: staging → install → verify → account', () async {
      // Step 1: Selection normalization
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.title', 'l10n:app.subtitle'},
        effectiveFindingIds: {'l10n:app.title', 'l10n:app.subtitle'},
        findingIdToKey: {
          'l10n:app.title': 'title',
          'l10n:app.subtitle': 'subtitle',
        },
      );

      // Step 2: Create batch with baseline + candidate
      final baselineArbBytes = utf8.encode(
        '{"title": "Old", "subtitle": "Sub"}',
      );
      final candidateArbBytes = utf8.encode('{}');
      final baselineGenBytes = utf8.encode('class Old {}');
      final candidateGenBytes = utf8.encode('class New {}');

      final batch = L10nRemovalBatch(
        familyId: 'app',
        selection: selection,
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.copyOf(baselineArbBytes),
            originalHash: sha256.convert(baselineArbBytes).toString(),
            candidateBytes: ImmutableBytes.copyOf(candidateArbBytes),
            candidateHash: sha256.convert(candidateArbBytes).toString(),
            mode: 420,
          ),
        ],
        generatedOutputMutations: [
          L10nGeneratedOutputMutation(
            relativePath: 'lib/l10n/app_localizations.dart',
            originalBytes: ImmutableBytes.copyOf(baselineGenBytes),
            originalHash: sha256.convert(baselineGenBytes).toString(),
            candidateBytes: ImmutableBytes.copyOf(candidateGenBytes),
            candidateHash: sha256.convert(candidateGenBytes).toString(),
            mode: 420,
          ),
        ],
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        footprint: MutationFootprint(
          familyId: 'app',
          findingIds: {'l10n:app.title', 'l10n:app.subtitle'},
          physicalPaths: {
            'lib/l10n/app_en.arb',
            'lib/l10n/app_localizations.dart',
          },
          riskScope: ActionRiskScope.boundedFamily,
        ),
      );

      // Step 3: Build journal with expectation manifest
      final journalBuilder = L10nBatchJournalBuilder();
      final quarantineEntries = journalBuilder.buildQuarantineEntries(batch);
      final expectation = journalBuilder.buildExpectation(batch);

      expect(expectation.familyId, 'app');
      expect(expectation.writeExpectations.length, 2);
      expect(quarantineEntries.length, 2);

      // Step 4: Install candidate bytes atomically
      final installer = L10nBatchInstaller();
      final writtenPaths = await installer.install(
        batch: batch,
        project: project,
      );

      expect(writtenPaths.length, 2);
      expect(writtenPaths, contains('lib/l10n/app_en.arb'));
      expect(writtenPaths, contains('lib/l10n/app_localizations.dart'));

      // Step 5: Verify installed files match expectations
      final verifier = L10nBatchVerifier();
      final verifyResult = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(verifyResult, isA<VerificationSuccess>());
      final success = verifyResult as VerificationSuccess;
      expect(success.verifiedPaths.length, 2);

      // Step 6: Account per-finding outcomes
      final accountant = L10nOutcomeAccountant();
      final accounting = accountant.account(
        familyId: 'app',
        selection: selection,
        expectation: expectation,
        verificationResult: verifyResult,
      );

      expect(accounting.allApplied, true);
      expect(accounting.appliedCount, 2);
      expect(accounting.failedCount, 0);
      expect(accounting.outcomes['l10n:app.title'], FindingOutcome.applied);
      expect(accounting.outcomes['l10n:app.subtitle'], FindingOutcome.applied);
    });

    test('verification failure propagates to per-finding accounting', () async {
      final selection = L10nMutationSelection(
        requestedFindingIds: {'l10n:app.key1'},
        effectiveFindingIds: {'l10n:app.key1'},
        findingIdToKey: {'l10n:app.key1': 'key1'},
      );

      final candidateArbBytes = utf8.encode('{}');
      final batch = L10nRemovalBatch(
        familyId: 'app',
        selection: selection,
        arbMutations: [
          L10nArbMutation(
            relativePath: 'lib/l10n/app_en.arb',
            originalBytes: ImmutableBytes.copyOf(utf8.encode('{}')),
            originalHash: sha256.convert(utf8.encode('{}')).toString(),
            candidateBytes: ImmutableBytes.copyOf(candidateArbBytes),
            candidateHash: sha256.convert(candidateArbBytes).toString(),
            mode: 420,
          ),
        ],
        generatedOutputMutations: [],
        configurationFingerprint: 'config-fp',
        packageResolutionFingerprint: 'pkg-fp',
        toolchainFingerprint: 'tool-fp',
        footprint: MutationFootprint(
          familyId: 'app',
          findingIds: {'l10n:app.key1'},
          physicalPaths: {'lib/l10n/app_en.arb'},
          riskScope: ActionRiskScope.boundedFamily,
        ),
      );

      final journalBuilder = L10nBatchJournalBuilder();
      final expectation = journalBuilder.buildExpectation(batch);

      final installer = L10nBatchInstaller();
      await installer.install(batch: batch, project: project);

      // Tamper with installed file to trigger verification failure
      final arbFile = File('${project.root.path}/lib/l10n/app_en.arb');
      await arbFile.writeAsString('{"tampered": true}');

      final verifier = L10nBatchVerifier();
      final verifyResult = await verifier.verify(
        expectation: expectation,
        project: project,
      );

      expect(verifyResult, isA<VerificationFailed>());
      final failed = verifyResult as VerificationFailed;
      expect(failed.mismatches.length, 1);

      final accountant = L10nOutcomeAccountant();
      final accounting = accountant.account(
        familyId: 'app',
        selection: selection,
        expectation: expectation,
        verificationResult: verifyResult,
      );

      expect(accounting.allApplied, false);
      expect(accounting.anyFailed, true);
      expect(accounting.failedCount, 1);

      final outcome = accounting.outcomes['l10n:app.key1'];
      expect(outcome, isA<FindingOutcomeFailed>());
      final failedOutcome = outcome as FindingOutcomeFailed;
      expect(failedOutcome.reason, contains('Verification failed'));
      expect(failedOutcome.verificationMismatches.length, 1);
    });

    test(
      'expanded findings: all effective findings tracked in outcomes',
      () async {
        final selection = L10nMutationSelection(
          requestedFindingIds: {'l10n:app.key1'},
          effectiveFindingIds: {'l10n:app.key1', 'l10n:app.key2'},
          findingIdToKey: {'l10n:app.key1': 'key1', 'l10n:app.key2': 'key2'},
          expansionReasons: {'l10n:app.key2': 'Dependency of key1'},
        );

        final candidateBytes = utf8.encode('{}');
        final batch = L10nRemovalBatch(
          familyId: 'app',
          selection: selection,
          arbMutations: [
            L10nArbMutation(
              relativePath: 'lib/l10n/app_en.arb',
              originalBytes: ImmutableBytes.copyOf(utf8.encode('{}')),
              originalHash: sha256.convert(utf8.encode('{}')).toString(),
              candidateBytes: ImmutableBytes.copyOf(candidateBytes),
              candidateHash: sha256.convert(candidateBytes).toString(),
              mode: 420,
            ),
          ],
          generatedOutputMutations: [],
          configurationFingerprint: 'config-fp',
          packageResolutionFingerprint: 'pkg-fp',
          toolchainFingerprint: 'tool-fp',
          footprint: MutationFootprint(
            familyId: 'app',
            findingIds: {'l10n:app.key1', 'l10n:app.key2'},
            physicalPaths: {'lib/l10n/app_en.arb'},
            riskScope: ActionRiskScope.boundedFamily,
          ),
        );

        final journalBuilder = L10nBatchJournalBuilder();
        final expectation = journalBuilder.buildExpectation(batch);

        final installer = L10nBatchInstaller();
        await installer.install(batch: batch, project: project);

        final verifier = L10nBatchVerifier();
        final verifyResult = await verifier.verify(
          expectation: expectation,
          project: project,
        );

        final accountant = L10nOutcomeAccountant();
        final accounting = accountant.account(
          familyId: 'app',
          selection: selection,
          expectation: expectation,
          verificationResult: verifyResult,
        );

        expect(accounting.outcomes.keys.length, 2);
        expect(accounting.outcomes.keys, contains('l10n:app.key1'));
        expect(accounting.outcomes.keys, contains('l10n:app.key2'));
        expect(accounting.requestedFindingIds.length, 1);
        expect(accounting.effectiveFindingIds.length, 2);
      },
    );

    test('hash computation consistency', () {
      final bytes = utf8.encode('{"test": "data"}');
      final hash1 = sha256.convert(bytes).toString();
      final hash2 = sha256.convert(bytes).toString();

      expect(hash1, hash2);
      expect(hash1.length, 64);
    });
  });
}
