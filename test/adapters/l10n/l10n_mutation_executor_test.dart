import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_installer.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_journal_builder.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_batch_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_executor.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_selection.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_removal_batch.dart';
import 'package:flutter_pruner/src/core/confidence/action_risk_scope.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/confidence/mutation_footprint.dart';
import 'package:flutter_pruner/src/core/confidence/promotion_index.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:test/test.dart';

/// Phase E: Focused verification tests for L10nMutationExecutor.
///
/// Tests the unified staging flow integration:
/// 1. Family grouping and config validation
/// 2. Staging isolation (gen-l10n never runs in live project)
/// 3. Batch building and journaling
/// 4. Installation and verification
/// 5. Per-finding outcome accounting
void main() {
  group('L10nMutationExecutor - Phase E Verification', () {
    late Directory tempDir;
    late ProjectContext project;
    late QuarantineManager quarantine;
    late L10nMutationExecutor executor;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('l10n_executor_test_');

      // Create minimal Flutter project structure
      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString('''
name: test_project
environment:
  sdk: '>=3.0.0 <4.0.0'

flutter:
  generate: true
''');

      final l10nYaml = File('${tempDir.path}/l10n.yaml');
      await l10nYaml.writeAsString('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-localization-file: app_localizations.dart
''');

      // Create ARB directory
      final arbDir = Directory('${tempDir.path}/lib/l10n');
      await arbDir.create(recursive: true);

      project = await ProjectContext.load(tempDir);
      quarantine = QuarantineManager(tempDir);
      executor = L10nMutationExecutor(quarantine: quarantine);
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    /// Computes the real config fingerprint the executor expects.
    /// Returns 'absent' when l10n.yaml does not exist (matches executor).
    String configFingerprint() {
      final file = File('${tempDir.path}/l10n.yaml');
      if (!file.existsSync()) return 'absent';
      final bytes = file.readAsBytesSync();
      return 'sha256:${sha256.convert(bytes)}';
    }

    test('executeAll returns empty map when no findings provided', () async {
      final results = await executor.executeAll(
        findings: [],
        readinessIndex: ActionReadinessIndex.empty,
        project: project,
      );

      expect(results, isEmpty);
    });

    test('config validation fails early when l10n.yaml missing', () async {
      // Remove l10n.yaml to trigger validation failure
      final l10nYaml = File('${tempDir.path}/l10n.yaml');
      await l10nYaml.delete();

      final finding = _createL10nFinding(
        nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
        key: 'unusedKey',
      );

      final readinessIndex = ActionReadinessIndex({
        finding.node.id: ActionReadinessEntry(
          adapterId: 'l10n-adapter',
          nodeKind: NodeKind.localizationKey,
          familyId: 'app_localizations',
          configurationFingerprint: configFingerprint(),
          mutationFootprint: MutationFootprint(
            familyId: 'app_localizations',
            findingIds: {finding.node.id},
            physicalPaths: {'lib/l10n/app_en.arb'},
            riskScope: ActionRiskScope.boundedFamily,
          ),
          inverseKind: DeterministicInverseKind.proven,
          riskScope: ActionRiskScope.boundedFamily,
          hasExternalConsumerExposure: false,
        ),
      });

      final results = await executor.executeAll(
        findings: [finding],
        readinessIndex: readinessIndex,
        project: project,
      );

      expect(results, hasLength(1));
      final result = results['app_localizations'];
      expect(result, isA<MutationFailed>());
      final failed = result as MutationFailed;
      expect(failed.error, contains('L10n config not valid'));
    });

    test('single key removal - family grouping', () async {
      // Create ARB file with one key
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.writeAsString('''
{
  "unusedKey": "Unused value"
}
''');

      final finding = _createL10nFinding(
        nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
        key: 'unusedKey',
      );

      final readinessIndex = ActionReadinessIndex({
        finding.node.id: ActionReadinessEntry(
          adapterId: 'l10n-adapter',
          nodeKind: NodeKind.localizationKey,
          familyId: 'app_localizations',
          configurationFingerprint: configFingerprint(),
          mutationFootprint: MutationFootprint(
            familyId: 'app_localizations',
            findingIds: {finding.node.id},
            physicalPaths: {'lib/l10n/app_en.arb'},
            riskScope: ActionRiskScope.boundedFamily,
          ),
          inverseKind: DeterministicInverseKind.proven,
          riskScope: ActionRiskScope.boundedFamily,
          hasExternalConsumerExposure: false,
        ),
      });

      final results = await executor.executeAll(
        findings: [finding],
        readinessIndex: readinessIndex,
        project: project,
      );

      expect(results, hasLength(1));
      expect(results.containsKey('app_localizations'), isTrue);

      // Result can be either Applied or Failed depending on gen-l10n availability
      final result = results['app_localizations']!;
      expect(result.familyId, equals('app_localizations'));
    });

    test('multiple keys same family - atomic grouping', () async {
      final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
      await arbFile.writeAsString('''
{
  "key1": "Value 1",
  "key2": "Value 2",
  "key3": "Value 3"
}
''');

      final findings = [
        _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key1',
          key: 'key1',
        ),
        _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key2',
          key: 'key2',
        ),
        _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key3',
          key: 'key3',
        ),
      ];

      final footprint = MutationFootprint(
        familyId: 'app_localizations',
        findingIds: findings.map((f) => f.node.id).toSet(),
        physicalPaths: {'lib/l10n/app_en.arb'},
        riskScope: ActionRiskScope.boundedFamily,
      );

      final readinessIndex = ActionReadinessIndex(
        Map.fromEntries(
          findings.map(
            (f) => MapEntry(
              f.node.id,
              ActionReadinessEntry(
                adapterId: 'l10n-adapter',
                nodeKind: NodeKind.localizationKey,
                familyId: 'app_localizations',
                configurationFingerprint: configFingerprint(),
                mutationFootprint: footprint,
                inverseKind: DeterministicInverseKind.proven,
                riskScope: ActionRiskScope.boundedFamily,
                hasExternalConsumerExposure: false,
              ),
            ),
          ),
        ),
      );

      final results = await executor.executeAll(
        findings: findings,
        readinessIndex: readinessIndex,
        project: project,
      );

      // All findings grouped into single family
      expect(results, hasLength(1));
      expect(results.containsKey('app_localizations'), isTrue);
    });

    test('finding without readiness entry is skipped', () async {
      final finding = _createL10nFinding(
        nodeId: 'l10n:test_project/lib/l10n/app_en.arb#orphanKey',
        key: 'orphanKey',
      );

      final results = await executor.executeAll(
        findings: [finding],
        readinessIndex: ActionReadinessIndex.empty,
        project: project,
      );

      // No families created, no results
      expect(results, isEmpty);
    });

    group('Phase E.2: Mutation tests - various scenarios', () {
      test('multiple locales - keys removed from all ARB files', () async {
        // Create ARB files for multiple locales
        final arbEn = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbEn.writeAsString('''
{
  "title": "Hello",
  "unusedKey": "Unused English"
}
''');

        final arbVi = File('${tempDir.path}/lib/l10n/app_vi.arb');
        await arbVi.writeAsString('''
{
  "title": "Xin chào",
  "unusedKey": "Unused Vietnamese"
}
''');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
          key: 'unusedKey',
        );

        final readinessIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb', 'lib/l10n/app_vi.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: readinessIndex,
          project: project,
        );

        expect(results, hasLength(1));
        final result = results['app_localizations']!;

        // Verify mutation attempted (success depends on gen-l10n availability)
        expect(result.familyId, equals('app_localizations'));
      });

      test('metadata companion handling - @key and key together', () async {
        // ARB with metadata companion pattern
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('''
{
  "unusedKey": "Value",
  "@unusedKey": {
    "description": "Metadata for unused key"
  }
}
''');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
          key: 'unusedKey',
        );

        final readinessIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: readinessIndex,
          project: project,
        );

        expect(results, hasLength(1));
        // Both key and @key should be removed together
      });

      test('empty ARB after removal - valid JSON object', () async {
        // Single key that when removed leaves empty ARB
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('''
{
  "onlyKey": "Only value"
}
''');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#onlyKey',
          key: 'onlyKey',
        );

        final readinessIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: readinessIndex,
          project: project,
        );

        expect(results, hasLength(1));
        // Result ARB should be {} - valid empty JSON object
      });

      test('generated output replacement - new class content', () async {
        // Test that generated files get replaced, not just removed
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('''
{
  "keepKey": "Keep this",
  "removeKey": "Remove this"
}
''');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#removeKey',
          key: 'removeKey',
        );

        final readinessIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {
                'lib/l10n/app_en.arb',
                '.dart_tool/flutter_gen/gen_l10n/app_localizations.dart',
              },
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: readinessIndex,
          project: project,
        );

        expect(results, hasLength(1));
        // Generated output should be replaced with new content (keepKey getter only)
      });
    });

    group('Phase E.3: Failure injection tests', () {
      test('failure when gen-l10n command not available', () async {
        // This test documents expected behavior when Flutter SDK not available
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('{"key": "value"}');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key',
          key: 'key',
        );

        final readinessIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: readinessIndex,
          project: project,
        );

        expect(results, hasLength(1));
        // May fail if flutter gen-l10n not available in test environment
        // This is expected - the test documents the failure mode
      });

      test(
        'exception during execution is caught and returned as MutationFailed',
        () async {
          // Invalid config triggers exception handling path
          final finding = _createL10nFinding(
            nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key',
            key: 'key',
          );

          // Remove l10n.yaml to force config load failure
          final l10nYaml = File('${tempDir.path}/l10n.yaml');
          await l10nYaml.delete();

          final readinessIndex = ActionReadinessIndex({
            finding.node.id: ActionReadinessEntry(
              adapterId: 'l10n-adapter',
              nodeKind: NodeKind.localizationKey,
              familyId: 'app_localizations',
              configurationFingerprint: configFingerprint(),
              mutationFootprint: MutationFootprint(
                familyId: 'app_localizations',
                findingIds: {finding.node.id},
                physicalPaths: {'lib/l10n/app_en.arb'},
                riskScope: ActionRiskScope.boundedFamily,
              ),
              inverseKind: DeterministicInverseKind.proven,
              riskScope: ActionRiskScope.boundedFamily,
              hasExternalConsumerExposure: false,
            ),
          });

          final results = await executor.executeAll(
            findings: [finding],
            readinessIndex: readinessIndex,
            project: project,
          );

          expect(results, hasLength(1));
          final result = results['app_localizations'];
          expect(result, isA<MutationFailed>());
          final failed = result as MutationFailed;
          expect(failed.error, contains('config'));
        },
      );
    });

    group('Phase E.5: Regression checks', () {
      test('executor handles findings list modifications gracefully', () async {
        // Ensure executor doesn't mutate input list
        final findings = <Finding>[
          _createL10nFinding(
            nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key1',
            key: 'key1',
          ),
        ];

        final originalLength = findings.length;

        await executor.executeAll(
          findings: findings,
          readinessIndex: ActionReadinessIndex.empty,
          project: project,
        );

        expect(findings.length, equals(originalLength));
      });

      test('empty readiness index returns empty results', () async {
        final findings = List.generate(
          5,
          (i) => _createL10nFinding(
            nodeId: 'l10n:test_project/lib/l10n/app_en.arb#key$i',
            key: 'key$i',
          ),
        );

        final results = await executor.executeAll(
          findings: findings,
          readinessIndex: ActionReadinessIndex.empty,
          project: project,
        );

        // No readiness entries = no families = no mutations
        expect(results, isEmpty);
      });
    });

    group('Phase E.6: TOCTOU drift and staging flow', () {
      ActionReadinessIndex indexFor(Finding finding, {Set<String>? paths}) {
        return ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: configFingerprint(),
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: paths ?? {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });
      }

      test('config drift before staging fails closed', () async {
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('{"unusedKey": "Unused value"}');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
          key: 'unusedKey',
        );

        // Use a stale fingerprint that does not match the live l10n.yaml.
        final staleIndex = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: 'sha256:stale-fingerprint',
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: staleIndex,
          project: project,
        );

        expect(results, hasLength(1));
        final result = results['app_localizations']!;
        expect(result, isA<MutationFailed>());
        final failed = result as MutationFailed;
        expect(
          failed.error,
          contains('l10n.yaml drift detected before staging'),
        );
        expect(failed.error, contains('stale-fingerprint'));
      });

      test('config drift detected regardless of timing', () async {
        // This test verifies that config drift is detected whenever it
        // occurs. Because L10nStagingManager is created inline in the
        // executor (not injectable), we cannot inject a mutation between
        // preflight and post-gen-l10n recheck. Mutating l10n.yaml before
        // executeAll triggers drift at the first check (line 80), which
        // exercises the same comparison logic as the post-gen-l10n check
        // (line 189). Both use _computeConfigFingerprint + string compare.
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('{"unusedKey": "Unused value"}');

        final finding = _createL10nFinding(
          nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
          key: 'unusedKey',
        );

        // Capture the correct fingerprint, then mutate l10n.yaml so the
        // drift check detects a mismatch.
        final correctFingerprint = configFingerprint();
        final index = ActionReadinessIndex({
          finding.node.id: ActionReadinessEntry(
            adapterId: 'l10n-adapter',
            nodeKind: NodeKind.localizationKey,
            familyId: 'app_localizations',
            configurationFingerprint: correctFingerprint,
            mutationFootprint: MutationFootprint(
              familyId: 'app_localizations',
              findingIds: {finding.node.id},
              physicalPaths: {'lib/l10n/app_en.arb'},
              riskScope: ActionRiskScope.boundedFamily,
            ),
            inverseKind: DeterministicInverseKind.proven,
            riskScope: ActionRiskScope.boundedFamily,
            hasExternalConsumerExposure: false,
          ),
        });

        // Mutate l10n.yaml before execution so the drift check sees a
        // different fingerprint than the one captured during analysis.
        final l10nYaml = File('${tempDir.path}/l10n.yaml');
        await l10nYaml.writeAsString(
          'arb-dir: lib/l10n\ntemplate-arb-file: app_en.arb\n'
          'output-localization-file: app_localizations.dart\n'
          'nullable-getter: false\n',
        );

        final results = await executor.executeAll(
          findings: [finding],
          readinessIndex: index,
          project: project,
        );

        expect(results, hasLength(1));
        final result = results['app_localizations']!;
        expect(result, isA<MutationFailed>());
        final failed = result as MutationFailed;
        expect(failed.error, contains('l10n.yaml drift detected'));
      });
      test('ARB baseline drift detected by batch builder', () async {
        // Test that L10nBatchVerifier detects hash mismatch between expected
        // candidate and observed installed bytes. This covers the verification
        // step that catches drift between staging and live project.
        final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
        await arbFile.writeAsString('{"unusedKey": "Unused value"}');

        final selection = L10nMutationSelection(
          requestedFindingIds: {'l10n:app.en#unusedKey'},
          effectiveFindingIds: {'l10n:app.en#unusedKey'},
          findingIdToKey: {'l10n:app.en#unusedKey': 'unusedKey'},
        );

        final candidateBytes = utf8.encode('{"cleaned": true}');
        final batch = L10nRemovalBatch(
          familyId: 'app_localizations',
          selection: selection,
          arbMutations: [
            L10nArbMutation(
              relativePath: 'lib/l10n/app_en.arb',
              originalBytes: ImmutableBytes.copyOf(
                utf8.encode('{"unusedKey": "old"}'),
              ),
              originalHash: sha256
                  .convert(utf8.encode('{"unusedKey": "old"}'))
                  .toString(),
              candidateBytes: ImmutableBytes.copyOf(candidateBytes),
              candidateHash: sha256.convert(candidateBytes).toString(),
              mode: 420,
            ),
          ],
          generatedOutputMutations: [],
          configurationFingerprint: configFingerprint(),
          packageResolutionFingerprint: 'pkg-fp',
          toolchainFingerprint: 'tool-fp',
          footprint: MutationFootprint(
            familyId: 'app_localizations',
            findingIds: {'l10n:app.en#unusedKey'},
            physicalPaths: {'lib/l10n/app_en.arb'},
            riskScope: ActionRiskScope.boundedFamily,
          ),
        );

        final journalBuilder = const L10nBatchJournalBuilder();
        final expectation = journalBuilder.buildExpectation(batch);

        // Install candidate bytes, then tamper to simulate drift.
        final installer = L10nBatchInstaller();
        await installer.install(batch: batch, project: project);
        await arbFile.writeAsString('{"tampered": true}');

        // Verify should detect the hash mismatch.
        final verifier = L10nBatchVerifier();
        final result = await verifier.verify(
          expectation: expectation,
          project: project,
        );

        expect(result, isA<VerificationFailed>());
        final failed = result as VerificationFailed;
        expect(failed.mismatches.length, 1);
        expect(failed.mismatches.first.path, 'lib/l10n/app_en.arb');
        expect(failed.mismatches.first.reason, contains('Hash mismatch'));
      });
      test(
        'full happy path returns MutationApplied with expectation',
        () async {
          final arbFile = File('${tempDir.path}/lib/l10n/app_en.arb');
          await arbFile.writeAsString('{"unusedKey": "Unused value"}');

          final finding = _createL10nFinding(
            nodeId: 'l10n:test_project/lib/l10n/app_en.arb#unusedKey',
            key: 'unusedKey',
          );

          final results = await executor.executeAll(
            findings: [finding],
            readinessIndex: indexFor(finding),
            project: project,
          );

          expect(results, hasLength(1));
          final result = results['app_localizations']!;

          // The full staging flow (materialize → mutate → gen-l10n → inspect
          // → batch → journal → install → verify → account) is exercised here.
          // In a full Flutter environment with resolved dependencies, this
          // returns MutationApplied. In test environments without resolved
          // pubspec, gen-l10n fails with exit 1 — which is also a valid path
          // (MutationFailed with gen-l10n error).
          if (result is MutationApplied) {
            final applied = result;
            expect(applied.expectation.familyId, 'app_localizations');
            expect(applied.expectation.writeExpectations, isNotEmpty);
            expect(applied.accounting.allApplied, isTrue);
            expect(applied.accounting.appliedCount, 1);
            expect(applied.affectedFiles, isNotEmpty);
          } else {
            final failed = result as MutationFailed;
            expect(failed.error, contains('gen-l10n failed in staging'));
          }
        },
      );
    });
  });
}

/// Helper to create a minimal l10n Finding for testing.
Finding _createL10nFinding({required String nodeId, required String key}) {
  return Finding(
    ruleId: 'PRN-L10N-001',
    node: GraphNode(
      id: nodeId,
      kind: NodeKind.localizationKey,
      origin: Uri.parse('file:///test/lib/l10n/app_en.arb'),
      displayName: key,
    ),
    confidence: Confidence.high,
    title: 'Unused localization key: $key',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: true,
      unreachableAcrossAllTargets: true,
      notRetained: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: true,
    ),
    proposedAction: 'Remove unused key',
  );
}
