import 'dart:io';

import 'package:crypto/crypto.dart';

import '../../core/project/project_context.dart';
import 'l10n_mutation_expectation.dart';

/// Verifies that installed mutations match expectations from staging.
///
/// Compares observed file hashes against the candidate hashes witnessed
/// during staging to ensure installation reproduced exactly what was tested.
class L10nBatchVerifier {
  /// Verifies all mutations in [expectation] against [project] state.
  ///
  /// Returns verification result indicating success or specific mismatches.
  Future<VerificationResult> verify({
    required L10nMutationExpectation expectation,
    required ProjectContext project,
  }) async {
    expectation.validate();

    final mismatches = <VerificationMismatch>[];

    // Verify write expectations (ARB + generated files)
    for (final write in expectation.writeExpectations) {
      final file = File('${project.root.path}/${write.path}');

      if (!file.existsSync()) {
        if (!write.wasAbsent) {
          mismatches.add(
            VerificationMismatch(
              path: write.path,
              role: write.role,
              expected: write.candidateHash,
              observed: 'FILE_ABSENT',
              reason: 'Expected file to exist but it is absent',
            ),
          );
        }
        continue;
      }

      // File exists - verify hash
      final bytes = await file.readAsBytes();
      final observedHash = sha256.convert(bytes).toString();

      if (observedHash != write.candidateHash) {
        mismatches.add(
          VerificationMismatch(
            path: write.path,
            role: write.role,
            expected: write.candidateHash,
            observed: observedHash,
            reason:
                'Hash mismatch: installed file differs from staging candidate',
          ),
        );
      }
    }

    if (mismatches.isEmpty) {
      return VerificationResult.success(
        familyId: expectation.familyId,
        verifiedPaths: expectation.writeExpectations
            .map((e) => e.path)
            .toList(),
      );
    } else {
      return VerificationResult.failed(
        familyId: expectation.familyId,
        mismatches: mismatches,
      );
    }
  }
}

/// Result of verifying one mutation batch.
sealed class VerificationResult {
  const VerificationResult({required this.familyId});

  factory VerificationResult.success({
    required String familyId,
    required List<String> verifiedPaths,
  }) = VerificationSuccess;

  factory VerificationResult.failed({
    required String familyId,
    required List<VerificationMismatch> mismatches,
  }) = VerificationFailed;

  /// Identifier of the family that was verified.
  final String familyId;
}

/// Successful verification with list of verified paths.
final class VerificationSuccess extends VerificationResult {
  /// Creates a successful verification result.
  const VerificationSuccess({
    required super.familyId,
    required this.verifiedPaths,
  });

  /// Paths whose installed bytes matched the expected candidates.
  final List<String> verifiedPaths;
}

/// Failed verification with specific mismatches.
final class VerificationFailed extends VerificationResult {
  /// Creates a failed verification result.
  const VerificationFailed({required super.familyId, required this.mismatches});

  /// Mismatches found between expected and observed file state.
  final List<VerificationMismatch> mismatches;
}

/// One verification mismatch between expected and observed state.
final class VerificationMismatch {
  /// Creates one verification mismatch.
  const VerificationMismatch({
    required this.path,
    required this.role,
    required this.expected,
    required this.observed,
    required this.reason,
  });

  /// File path relative to project root.
  final String path;

  /// Role of the file (arb or generated).
  final FileRole role;

  /// Expected hash from staging candidate.
  final String expected;

  /// Observed hash in live project, or 'FILE_ABSENT'.
  final String observed;

  /// Human-readable reason for the mismatch.
  final String reason;

  @override
  String toString() =>
      '$path: $reason (expected: $expected, observed: $observed)';
}
