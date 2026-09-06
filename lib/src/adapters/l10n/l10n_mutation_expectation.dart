import 'package:meta/meta.dart';

/// L10n mutation expectation manifest for verification.
///
/// Single source of truth for what the mutation should produce.
/// Contains baseline state, expected candidate state, and write inventory.
@immutable
final class L10nMutationExpectation {
  /// Creates a mutation expectation manifest.
  const L10nMutationExpectation({
    required this.familyId,
    required this.selectionFingerprint,
    required this.configurationFingerprint,
    required this.packageResolutionFingerprint,
    required this.toolchainFingerprint,
    required this.writeExpectations,
    required this.generatedOutputInventory,
  });

  /// Identifier of the family being mutated.
  final String familyId;

  /// Fingerprint of the selection (requested + effective findings).
  final String selectionFingerprint;

  /// Fingerprint of l10n.yaml used to build this mutation.
  final String configurationFingerprint;

  /// Fingerprint of package resolution used.
  final String packageResolutionFingerprint;

  /// Fingerprint of the toolchain (flutter gen-l10n version).
  final String toolchainFingerprint;

  /// Files that will be written (ARB + generated outputs).
  final List<WriteExpectation> writeExpectations;

  /// Complete inventory of generated outputs witnessed in staging.
  ///
  /// Includes files that were unchanged (not in writeExpectations).
  /// Allows detecting unexpected outputs or missing expected outputs.
  final List<GeneratedOutputEntry> generatedOutputInventory;

  /// All file paths that will be modified.
  Set<String> get affectedPaths => writeExpectations.map((e) => e.path).toSet();

  /// Validates this expectation is consistent.
  void validate() {
    if (writeExpectations.isEmpty) {
      throw ArgumentError('At least one write expectation required');
    }

    // No duplicate paths in writeExpectations
    final writePaths = <String>{};
    for (final expectation in writeExpectations) {
      if (!writePaths.add(expectation.path)) {
        throw ArgumentError('Duplicate write path: ${expectation.path}');
      }
    }

    // No duplicate paths in inventory
    final inventoryPaths = <String>{};
    for (final entry in generatedOutputInventory) {
      if (!inventoryPaths.add(entry.path)) {
        throw ArgumentError('Duplicate inventory path: ${entry.path}');
      }
    }

    // All write expectations for generated outputs must be in inventory
    for (final expectation in writeExpectations) {
      if (expectation.role == FileRole.generated) {
        if (!inventoryPaths.contains(expectation.path)) {
          throw ArgumentError(
            'Generated write expectation not in inventory: ${expectation.path}',
          );
        }
      }
    }
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is L10nMutationExpectation &&
          runtimeType == other.runtimeType &&
          familyId == other.familyId &&
          selectionFingerprint == other.selectionFingerprint &&
          configurationFingerprint == other.configurationFingerprint &&
          packageResolutionFingerprint == other.packageResolutionFingerprint &&
          toolchainFingerprint == other.toolchainFingerprint &&
          _listEquals(writeExpectations, other.writeExpectations) &&
          _listEquals(generatedOutputInventory, other.generatedOutputInventory);

  @override
  int get hashCode => Object.hash(
    familyId,
    selectionFingerprint,
    configurationFingerprint,
    packageResolutionFingerprint,
    toolchainFingerprint,
    Object.hashAll(writeExpectations),
    Object.hashAll(generatedOutputInventory),
  );

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// Role of a file in the mutation.
enum FileRole {
  /// ARB source file (input).
  arb,

  /// Generated Dart output file.
  generated,
}

/// Expectation for one file write.
@immutable
final class WriteExpectation {
  /// Creates a write expectation for one file.
  const WriteExpectation({
    required this.path,
    required this.role,
    required this.baselineHash,
    required this.candidateHash,
    required this.expectedMode,
    required this.wasAbsent,
  });

  /// Path relative to project root.
  final String path;

  /// Role of this file (arb or generated).
  final FileRole role;

  /// SHA-256 hash of baseline content (before mutation).
  ///
  /// Empty string if file was absent.
  final String baselineHash;

  /// SHA-256 hash of expected candidate content (after mutation).
  final String candidateHash;

  /// Expected POSIX file mode bits (0 on Windows).
  final int expectedMode;

  /// Whether this file was absent before mutation.
  ///
  /// If true, verification expects file to be created.
  /// If false, verification expects file to be modified.
  final bool wasAbsent;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WriteExpectation &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          role == other.role &&
          baselineHash == other.baselineHash &&
          candidateHash == other.candidateHash &&
          expectedMode == other.expectedMode &&
          wasAbsent == other.wasAbsent;

  @override
  int get hashCode => Object.hash(
    path,
    role,
    baselineHash,
    candidateHash,
    expectedMode,
    wasAbsent,
  );
}

/// Entry in generated output inventory.
@immutable
final class GeneratedOutputEntry {
  /// Creates a generated output inventory entry.
  const GeneratedOutputEntry({
    required this.path,
    required this.expectedHash,
    required this.sizeBytes,
  });

  /// Path relative to project root.
  final String path;

  /// Expected SHA-256 hash after generation.
  final String expectedHash;

  /// Expected size in bytes.
  final int sizeBytes;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeneratedOutputEntry &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          expectedHash == other.expectedHash &&
          sizeBytes == other.sizeBytes;

  @override
  int get hashCode => Object.hash(path, expectedHash, sizeBytes);
}
