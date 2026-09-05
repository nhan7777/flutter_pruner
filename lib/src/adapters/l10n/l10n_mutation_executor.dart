import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/confidence/finding.dart';
import '../../core/confidence/promotion_index.dart';
import '../../core/project/project_context.dart';
import '../../quarantine/manifest.dart';
import '../../quarantine/quarantine_manager.dart';
import 'arb_inventory.dart';
import 'l10n_config.dart';

/// Executes l10n key removal mutations with quarantine protection.
///
/// Uses direct in-place mutation: edits ARB files, runs gen-l10n, then relies
/// on existing quarantine rollback if verification fails.
class L10nMutationExecutor {
  /// Creates an executor with quarantine support.
  const L10nMutationExecutor({
    required this.quarantine,
  });

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
    // 1. Create quarantine with all affected files
    final entries = await _buildEntries(family, project);
    final quarantineDir = await quarantine.createCaseQuarantine(
      runId: 'l10n-${family.familyId}-${DateTime.now().millisecondsSinceEpoch}',
      verificationPolicyHash: family.verificationPolicyHash,
      analysisMode: project.analysisMode.name,
    );

    // 2. Begin transaction
    final transaction = await quarantine.beginTransaction(
      quarantineDir: quarantineDir,
      transactionId: family.familyId,
      round: 1,
      componentId: 'l10n-adapter',
      findingIds: family.findingIds,
      caseIds: family.caseIds,
    );

    try {
      // 3. Edit ARB files in place
      await _editArbFiles(family, project);

      // 4. Run gen-l10n
      await _runGenL10n(family, project);

      // 5. Record all cases as applied
      for (final caseId in family.caseIds) {
        await quarantine.recordCaseApplied(
          quarantineDir: quarantineDir,
          caseId: caseId,
        );
      }

      // 6. Verification happens externally, then either:
      //    - commitTransaction() if verify passes
      //    - rollbackCasesAtomically() if verify fails
      return MutationResult.applied(
        familyId: family.familyId,
        transactionId: transaction.transactionId,
        quarantineDir: quarantineDir,
        affectedFiles: entries.map((e) => e.originalPath).toList(),
      );
    } catch (error, stack) {
      // Immediate rollback on execution failure
      await quarantine.rollbackCasesAtomically(
        quarantineDir: quarantineDir,
        caseIds: family.caseIds,
        reason: 'L10n mutation execution failed: $error',
      );
      return MutationResult.failed(
        familyId: family.familyId,
        error: error.toString(),
        stackTrace: stack.toString(),
      );
    }
  }

  Future<List<QuarantineEntry>> _buildEntries(
    L10nFamily family,
    ProjectContext project,
  ) async {
    final entries = <QuarantineEntry>[];
    final configResult = L10nConfig.load(project);
    if (configResult is! L10nConfigValid) {
      throw L10nGenerationException('L10n config not valid');
    }
    final l10nConfig = configResult.config;
    final arbDir = Directory(l10nConfig.arbDir);

    // ARB files
    final arbFiles = arbDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.arb')
        .toList();

    for (final arbFile in arbFiles) {
      final relativePath = p.relative(arbFile.path, from: project.root.path);
      final bytes = arbFile.readAsBytesSync();
      final stat = arbFile.statSync();

      entries.add(QuarantineEntry(
        originalPath: relativePath,
        sha256: _computeSha256(bytes),
        sizeBytes: bytes.length,
        posixMode: Platform.isWindows ? null : stat.mode,
        wasAbsentBeforeTransaction: false,
      ));
    }

    // Generated outputs (may not exist)
    for (final outputPath in family.generatedOutputPaths) {
      final outputFile = File(p.join(project.root.path, outputPath));
      if (outputFile.existsSync()) {
        final bytes = outputFile.readAsBytesSync();
        final stat = outputFile.statSync();
        entries.add(QuarantineEntry(
          originalPath: outputPath,
          sha256: _computeSha256(bytes),
          sizeBytes: bytes.length,
          posixMode: Platform.isWindows ? null : stat.mode,
          wasAbsentBeforeTransaction: false,
        ));
      } else {
        entries.add(QuarantineEntry(
          originalPath: outputPath,
          sha256: '',
          sizeBytes: 0,
          posixMode: null,
          wasAbsentBeforeTransaction: true,
        ));
      }
    }

    return entries;
  }

  Future<void> _editArbFiles(
    L10nFamily family,
    ProjectContext project,
  ) async {
    for (final key in family.keysToRemove) {
      // Find ARB file for this key
      final arbPath = key.origin.toFilePath();
      final arbFile = File(arbPath);
      final content = arbFile.readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;

      // Remove key and its metadata
      decoded.remove(key.key);
      decoded.remove('@${key.key}');

      // Write back
      arbFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(decoded),
      );
    }
  }

  Future<void> _runGenL10n(
    L10nFamily family,
    ProjectContext project,
  ) async {
    // Run flutter gen-l10n
    final result = await Process.run(
      'flutter',
      ['gen-l10n'],
      workingDirectory: project.root.path,
    );

    if (result.exitCode != 0) {
      throw L10nGenerationException(
        'flutter gen-l10n failed with exit code ${result.exitCode}\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }
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
        // Extract output paths from mutation footprint
        final outputPaths = entry.mutationFootprint.physicalPaths.toSet();

        families[familyId] = L10nFamily(
          familyId: familyId,
          findingIds: [],
          caseIds: [],
          keysToRemove: [],
          generatedOutputPaths: outputPaths,
          verificationPolicyHash: _computeVerificationPolicyHash(project),
        );
      }

      families[familyId]!.findingIds.add(finding.node.id);
      families[familyId]!.caseIds.add('case-${finding.node.id}');

      // Extract ARB key from node metadata
      final key = finding.node.metadata['key'] as String?;
      if (key != null) {
        families[familyId]!.keysToRemove.add(
          ArbKey(
            key: key,
            nodeId: finding.node.id,
            origin: finding.node.origin,
            location: finding.node.metadata['declaredAt'] as String? ?? '',
            memberKind: _parseMemberKind(
              finding.node.metadata['memberKind'] as String?,
            ),
            missingLocales: finding.node.metadata['missingLocales'] as String? ?? '',
          ),
        );
      }
    }

    return families;
  }

  ArbGeneratedMemberKind _parseMemberKind(String? kind) {
    if (kind == null) return ArbGeneratedMemberKind.getter;
    return ArbGeneratedMemberKind.values.firstWhere(
      (e) => e.name == kind,
      orElse: () => ArbGeneratedMemberKind.getter,
    );
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
  L10nFamily({
    required this.familyId,
    required this.findingIds,
    required this.caseIds,
    required this.keysToRemove,
    required this.generatedOutputPaths,
    required this.verificationPolicyHash,
  });

  final String familyId;
  final List<String> findingIds;
  final List<String> caseIds;
  final List<ArbKey> keysToRemove;
  final Set<String> generatedOutputPaths;
  final String? verificationPolicyHash;
}

/// Mutation execution result.
sealed class MutationResult {
  const MutationResult({required this.familyId});

  factory MutationResult.applied({
    required String familyId,
    required String transactionId,
    required Directory quarantineDir,
    required List<String> affectedFiles,
  }) = MutationApplied;

  factory MutationResult.failed({
    required String familyId,
    required String error,
    required String stackTrace,
  }) = MutationFailed;

  final String familyId;
}

final class MutationApplied extends MutationResult {
  const MutationApplied({
    required super.familyId,
    required this.transactionId,
    required this.quarantineDir,
    required this.affectedFiles,
  });

  final String transactionId;
  final Directory quarantineDir;
  final List<String> affectedFiles;
}

final class MutationFailed extends MutationResult {
  const MutationFailed({
    required super.familyId,
    required this.error,
    required this.stackTrace,
  });

  final String error;
  final String stackTrace;
}

class L10nGenerationException implements Exception {
  L10nGenerationException(this.message);

  final String message;

  @override
  String toString() => 'L10nGenerationException: $message';
}
