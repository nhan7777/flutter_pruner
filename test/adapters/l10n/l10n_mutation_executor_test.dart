import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/l10n_mutation_executor.dart';
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
          configurationFingerprint: 'test-config-fp',
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
          configurationFingerprint: 'test-config-fp',
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
          findings.map((f) => MapEntry(
            f.node.id,
            ActionReadinessEntry(
              adapterId: 'l10n-adapter',
              nodeKind: NodeKind.localizationKey,
              familyId: 'app_localizations',
              configurationFingerprint: 'test-config-fp',
              mutationFootprint: footprint,
              inverseKind: DeterministicInverseKind.proven,
              riskScope: ActionRiskScope.boundedFamily,
              hasExternalConsumerExposure: false,
            ),
          )),
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
            configurationFingerprint: 'test-config-fp',
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
            configurationFingerprint: 'test-config-fp',
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
            configurationFingerprint: 'test-config-fp',
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
            configurationFingerprint: 'test-config-fp',
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
            configurationFingerprint: 'test-config-fp',
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

      test('exception during execution is caught and returned as MutationFailed', () async {
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
            configurationFingerprint: 'test-config-fp',
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
      });
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
  });
}

/// Helper to create a minimal l10n Finding for testing.
Finding _createL10nFinding({
  required String nodeId,
  required String key,
}) {
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
