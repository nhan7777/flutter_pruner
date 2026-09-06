import 'dart:io';

import '../../core/project/project_context.dart';
import 'l10n_removal_batch.dart';

/// Installs candidate bytes from staging into the live project atomically.
///
/// Takes witnessed candidate bytes from [L10nRemovalBatch] and writes them
/// to the live project. Does NOT regenerate - uses exactly what was captured
/// from staging to maintain the three-hash verification model.
class L10nBatchInstaller {
  /// Installs all mutations in [batch] into [project].
  ///
  /// Writes ARB files and generated outputs atomically. All writes succeed
  /// or all fail (no partial application).
  ///
  /// Returns the list of relative paths that were written.
  Future<List<String>> install({
    required L10nRemovalBatch batch,
    required ProjectContext project,
  }) async {
    batch.validate();

    final writtenPaths = <String>[];

    try {
      // Install ARB mutations
      for (final arb in batch.arbMutations) {
        await _installFile(
          relativePath: arb.relativePath,
          bytes: arb.candidateBytes.copy(),
          mode: arb.mode,
          project: project,
        );
        writtenPaths.add(arb.relativePath);
      }

      // Install generated output mutations
      for (final gen in batch.generatedOutputMutations) {
        await _installFile(
          relativePath: gen.relativePath,
          bytes: gen.candidateBytes.copy(),
          mode: gen.mode,
          project: project,
        );
        writtenPaths.add(gen.relativePath);
      }

      return writtenPaths;
    } catch (e) {
      // On any failure, report which paths were already written
      // (caller can use quarantine to roll back)
      throw InstallationFailure(
        message: 'Failed to install batch: $e',
        partiallyWrittenPaths: writtenPaths,
        originalError: e,
      );
    }
  }

  Future<void> _installFile({
    required String relativePath,
    required List<int> bytes,
    required int mode,
    required ProjectContext project,
  }) async {
    // Security: validate path
    if (relativePath.isEmpty) {
      throw ArgumentError('relativePath cannot be empty');
    }
    if (relativePath.startsWith('/')) {
      throw ArgumentError('relativePath must be relative: $relativePath');
    }
    if (relativePath.contains('..')) {
      throw ArgumentError('relativePath cannot contain ..: $relativePath');
    }

    final file = File('${project.root.path}/$relativePath');

    // Ensure parent directory exists
    final parent = file.parent;
    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }

    // Write bytes atomically
    await file.writeAsBytes(bytes, flush: true);

    // Set mode if non-zero (skip mode 0 as it's invalid)
    if (mode > 0 && (Platform.isLinux || Platform.isMacOS)) {
      // Set file permissions on Unix-like systems
      await Process.run('chmod', [mode.toRadixString(8), file.path]);
    }
  }
}

/// Exception thrown when installation fails partway through.
class InstallationFailure implements Exception {
  /// Creates an installation failure with the paths written before the error.
  const InstallationFailure({
    required this.message,
    required this.partiallyWrittenPaths,
    required this.originalError,
  });

  /// Human-readable description of the installation error.
  final String message;

  /// Paths written before installation failed.
  final List<String> partiallyWrittenPaths;

  /// The original error raised while installing the batch.
  final Object originalError;

  @override
  String toString() =>
      '$message (${partiallyWrittenPaths.length} files written before failure)';
}
