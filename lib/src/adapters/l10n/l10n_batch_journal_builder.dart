import 'package:crypto/crypto.dart';

import '../../quarantine/manifest.dart';
import 'l10n_mutation_expectation.dart';
import 'l10n_mutation_selection.dart';
import 'l10n_removal_batch.dart';

/// Converts L10nRemovalBatch to quarantine journal entries and expectations.
class L10nBatchJournalBuilder {
  /// Creates a batch journal builder.
  const L10nBatchJournalBuilder();

  /// Builds quarantine entries from batch.
  ///
  /// Returns baseline entries for quarantine journaling.
  /// These capture the state BEFORE mutation for rollback.
  List<QuarantineEntry> buildQuarantineEntries(L10nRemovalBatch batch) {
    batch.validate();

    final entries = <QuarantineEntry>[];

    // Journal ARB baseline state
    for (final arb in batch.arbMutations) {
      entries.add(
        QuarantineEntry(
          originalPath: arb.relativePath,
          sha256: arb.originalHash,
          sizeBytes: arb.originalBytes.length,
          posixMode: arb.mode != 0 ? arb.mode : null,
          operationType: QuarantineOperationType.file,
          wasAbsentBeforeTransaction: false,
        ),
      );
    }

    // Journal generated output baseline state
    for (final gen in batch.generatedOutputMutations) {
      final wasAbsent = gen.originalHash == null;
      entries.add(
        QuarantineEntry(
          originalPath: gen.relativePath,
          sha256: wasAbsent ? _emptyFileSha256 : gen.originalHash!,
          sizeBytes: wasAbsent ? 0 : gen.originalBytes!.length,
          posixMode: gen.mode != 0 ? gen.mode : null,
          operationType: QuarantineOperationType.file,
          wasAbsentBeforeTransaction: wasAbsent,
        ),
      );
    }

    return entries;
  }

  /// Builds mutation expectation from batch.
  ///
  /// This contains candidate hashes and full output inventory for verification.
  L10nMutationExpectation buildExpectation(L10nRemovalBatch batch) {
    batch.validate();

    final writeExpectations = <WriteExpectation>[];
    final generatedInventory = <GeneratedOutputEntry>[];

    // Build ARB write expectations
    for (final arb in batch.arbMutations) {
      writeExpectations.add(
        WriteExpectation(
          path: arb.relativePath,
          role: FileRole.arb,
          baselineHash: arb.originalHash,
          candidateHash: arb.candidateHash,
          expectedMode: arb.mode,
          wasAbsent: false,
        ),
      );
    }

    // Build generated output expectations
    for (final gen in batch.generatedOutputMutations) {
      final wasAbsent = gen.originalHash == null;

      writeExpectations.add(
        WriteExpectation(
          path: gen.relativePath,
          role: FileRole.generated,
          baselineHash: wasAbsent ? _emptyFileSha256 : gen.originalHash!,
          candidateHash: gen.candidateHash,
          expectedMode: gen.mode,
          wasAbsent: wasAbsent,
        ),
      );

      generatedInventory.add(
        GeneratedOutputEntry(
          path: gen.relativePath,
          expectedHash: gen.candidateHash,
          sizeBytes: gen.candidateBytes.length,
        ),
      );
    }

    // Compute selection fingerprint
    final selectionFingerprint = _computeSelectionFingerprint(batch.selection);

    final expectation = L10nMutationExpectation(
      familyId: batch.familyId,
      selectionFingerprint: selectionFingerprint,
      configurationFingerprint: batch.configurationFingerprint,
      packageResolutionFingerprint: batch.packageResolutionFingerprint,
      toolchainFingerprint: batch.toolchainFingerprint,
      writeExpectations: writeExpectations,
      generatedOutputInventory: generatedInventory,
    );

    expectation.validate();
    return expectation;
  }

  /// Computes fingerprint of selection for change detection.
  String _computeSelectionFingerprint(L10nMutationSelection selection) {
    // Sort for deterministic hash
    final requestedSorted = selection.requestedFindingIds.toList()..sort();
    final effectiveSorted = selection.effectiveFindingIds.toList()..sort();

    final content = [
      'requested:${requestedSorted.join(',')}',
      'effective:${effectiveSorted.join(',')}',
    ].join('|');

    return sha256.convert(content.codeUnits).toString();
  }

  /// SHA-256 of empty file (for absent files).
  static const String _emptyFileSha256 =
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855';
}
