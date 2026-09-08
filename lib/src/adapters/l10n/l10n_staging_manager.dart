import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import 'arb_inventory.dart';
import 'l10n_config.dart';

/// Manages isolated staging directory for safe l10n generation.
///
/// Staging provides isolation: gen-l10n runs here, not in live project.
class L10nStagingManager {
  /// Creates a staging manager.
  const L10nStagingManager();

  /// Staging directory name within quarantine.
  static const String stagingDirName = 'staging';

  /// Creates staging directory under [quarantineDir]/staging.
  Future<Directory> createStaging(Directory quarantineDir) async {
    final staging = Directory(p.join(quarantineDir.path, stagingDirName));
    if (staging.existsSync()) {
      throw L10nStagingException(
        'Staging directory already exists: ${staging.path}',
      );
    }
    await staging.create(recursive: true);
    return staging;
  }

  /// Materializes config and ARB files into staging.
  ///
  /// Copies:
  /// - l10n.yaml → staging/l10n.yaml
  /// - ARB files → staging/arb/
  /// - pubspec.yaml → staging/pubspec.yaml (for gen-l10n context)
  Future<void> materialize({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
  }) async {
    // Copy l10n.yaml
    final configPath = p.join(project.root.path, 'l10n.yaml');
    final configFile = File(configPath);
    if (!configFile.existsSync()) {
      throw L10nStagingException('l10n.yaml not found: $configPath');
    }
    final stagingConfigPath = p.join(staging.path, 'l10n.yaml');
    await configFile.copy(stagingConfigPath);

    // Copy pubspec.yaml (gen-l10n needs package context)
    final pubspecPath = p.join(project.root.path, 'pubspec.yaml');
    final pubspecFile = File(pubspecPath);
    if (!pubspecFile.existsSync()) {
      throw L10nStagingException('pubspec.yaml not found: $pubspecPath');
    }
    final stagingPubspecPath = p.join(staging.path, 'pubspec.yaml');
    await pubspecFile.copy(stagingPubspecPath);

    // Create the configured ARB directory relative to the staging root.
    final arbDirRelative = project.relative(config.arbDir);
    final stagingArbDir = Directory(p.join(staging.path, arbDirRelative));
    await stagingArbDir.create(recursive: true);

    // Copy ARB files
    final arbDir = Directory(config.arbDir);
    if (!arbDir.existsSync()) {
      throw L10nStagingException('ARB directory not found: ${arbDir.path}');
    }

    final arbFiles = arbDir
        .listSync()
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.arb')
        .toList();

    for (final arbFile in arbFiles) {
      final basename = p.basename(arbFile.path);
      final stagingArbPath = p.join(stagingArbDir.path, basename);
      await arbFile.copy(stagingArbPath);
    }
  }

  /// Mutates ARB files in staging by removing specified keys.
  Future<void> mutateArbFiles({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
    required List<ArbKey> keysToRemove,
  }) async {
    // Group keys by ARB basename
    final keysByBasename = <String, List<String>>{};
    for (final key in keysToRemove) {
      // Extract basename from location path
      final basename = p.basename(key.location);
      keysByBasename.putIfAbsent(basename, () => []).add(key.key);
    }

    // Edit each ARB file
    for (final entry in keysByBasename.entries) {
      final arbBasename = entry.key;
      final keysToRemoveFromFile = entry.value;

      // Resolve the ARB file path relative to the staging root.
      final stagingArbPath = p.join(
        staging.path,
        project.relative(config.arbDir),
        arbBasename,
      );
      final arbFile = File(stagingArbPath);

      if (!arbFile.existsSync()) {
        throw L10nStagingException(
          'ARB file not found in staging: $stagingArbPath',
        );
      }

      // Read, mutate, write
      final content = arbFile.readAsStringSync();
      final decoded = jsonDecode(content) as Map<String, dynamic>;

      for (final key in keysToRemoveFromFile) {
        decoded.remove(key);
        decoded.remove('@$key'); // Remove metadata companion
      }

      // Write back with consistent formatting
      arbFile.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(decoded),
      );
    }
  }

  /// Runs flutter gen-l10n in staging directory.
  Future<GenL10nResult> runGenL10nInStaging({
    required Directory staging,
  }) async {
    final result = await Process.run('flutter', [
      'gen-l10n',
    ], workingDirectory: staging.path);

    if (result.exitCode != 0) {
      return GenL10nResult.failed(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    }

    return GenL10nResult.success(
      stdout: result.stdout.toString(),
      stderr: result.stderr.toString(),
    );
  }

  /// Inspects generated outputs in staging and computes candidate hashes.
  Future<StagingInspectionResult> inspect({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
  }) async {
    final candidates = <GeneratedFileCandidate>[];
    final unexpectedFiles = <String>[];

    // Expected generated files: the primary library plus per-locale files.
    // gen-l10n creates <outputLocalizationFile>.dart and
    // <outputLocalizationFile>_<locale>.dart for each locale.
    final outputBaseName = p.basename(config.outputLocalizationFile);
    final expectedPrefix = p.basenameWithoutExtension(outputBaseName);

    // Inspect output directory relative to the staging root.
    final outputDir = Directory(
      p.join(staging.path, project.relative(config.outputDir)),
    );
    if (!outputDir.existsSync()) {
      throw L10nStagingException(
        'Generated output directory not found: ${outputDir.path}',
      );
    }

    // Scan all generated files
    final generatedFiles = outputDir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => p.extension(f.path) == '.dart')
        .toList();

    for (final file in generatedFiles) {
      final relativePath = p.relative(file.path, from: staging.path);
      final bytes = file.readAsBytesSync();
      final hash = sha256.convert(bytes);
      final stat = file.statSync();

      candidates.add(
        GeneratedFileCandidate(
          relativePath: relativePath,
          sha256: hash.toString(),
          sizeBytes: bytes.length,
          posixMode: Platform.isWindows ? null : stat.mode,
        ),
      );

      // Check if expected: basename must start with the expected prefix
      // (e.g. app_localizations from app_localizations.dart matches
      // app_localizations.dart, app_localizations_en.dart, etc.)
      final basename = p.basename(relativePath);
      if (!basename.startsWith(expectedPrefix)) {
        unexpectedFiles.add(relativePath);
      }
    }

    return StagingInspectionResult(
      candidates: candidates,
      unexpectedFiles: unexpectedFiles,
    );
  }

  /// Cleans up staging directory.
  Future<void> cleanupStaging(Directory staging) async {
    if (staging.existsSync()) {
      await staging.delete(recursive: true);
    }
  }
}

/// Result of staging inspection.
class StagingInspectionResult {
  /// Creates an inspection result.
  const StagingInspectionResult({
    required this.candidates,
    required this.unexpectedFiles,
  });

  /// Generated files with candidate hashes.
  final List<GeneratedFileCandidate> candidates;

  /// Files generated but not in expected output set.
  final List<String> unexpectedFiles;
}

/// Candidate file generated in staging.
class GeneratedFileCandidate {
  /// Creates a candidate file descriptor.
  const GeneratedFileCandidate({
    required this.relativePath,
    required this.sha256,
    required this.sizeBytes,
    required this.posixMode,
  });

  /// Path relative to staging root.
  final String relativePath;

  /// SHA256 hash of file content.
  final String sha256;

  /// Size in bytes.
  final int sizeBytes;

  /// POSIX file mode, null on Windows.
  final int? posixMode;
}

/// Result of gen-l10n execution in staging.
sealed class GenL10nResult {
  /// Creates a gen-l10n result.
  const GenL10nResult();

  /// Creates a success result.
  factory GenL10nResult.success({
    required String stdout,
    required String stderr,
  }) = GenL10nSuccess;

  /// Creates a failure result.
  factory GenL10nResult.failed({
    required int exitCode,
    required String stdout,
    required String stderr,
  }) = GenL10nFailure;
}

/// Successful gen-l10n execution.
final class GenL10nSuccess extends GenL10nResult {
  /// Creates a success result.
  const GenL10nSuccess({required this.stdout, required this.stderr});

  /// Standard output from gen-l10n.
  final String stdout;

  /// Standard error from gen-l10n.
  final String stderr;
}

/// Failed gen-l10n execution.
final class GenL10nFailure extends GenL10nResult {
  /// Creates a failure result.
  const GenL10nFailure({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  /// Exit code from flutter gen-l10n.
  final int exitCode;

  /// Standard output from gen-l10n.
  final String stdout;

  /// Standard error from gen-l10n.
  final String stderr;
}

/// Exception raised during staging operations.
class L10nStagingException implements Exception {
  /// Creates a staging exception.
  L10nStagingException(this.message);

  /// Human-readable error message.
  final String message;

  @override
  String toString() => 'L10nStagingException: $message';
}
