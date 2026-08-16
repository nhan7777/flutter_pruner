import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:path/path.dart' as p;

import '../core/process/managed_process_runner.dart';

/// Runs `dart fix --apply` to clean up unused imports.
class ImportCleanupRunner {
  /// Creates an import cleanup runner.
  const ImportCleanupRunner({
    required this.projectRoot,
    this.timeout = defaultTimeout,
    this.maxOutputBytesPerStream = defaultMaxOutputBytesPerStream,
    this.dartExecutable = 'dart',
    this.dartArgumentPrefix = const [],
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
  }) : _processRunner = processRunner;

  /// Default deadline for each file-scoped `dart fix` invocation.
  static const Duration defaultTimeout = Duration(minutes: 5);

  /// Default amount retained from each output stream while fully draining it.
  static const int defaultMaxOutputBytesPerStream = 64 * 1024;

  /// Project root directory for running dart fix.
  final String projectRoot;

  /// Deadline for each file-scoped `dart fix` invocation.
  final Duration timeout;

  /// Maximum payload bytes retained independently from stdout and stderr.
  final int maxOutputBytesPerStream;

  /// Dart executable used for cleanup.
  final String dartExecutable;

  /// Arguments placed before `fix`; primarily useful for process fixtures.
  final List<String> dartArgumentPrefix;

  final ProcessExecutionRunner _processRunner;

  /// Removes the exact import/export directive that resolves to [targetPath].
  ///
  /// Conditional directives fail closed because removing the whole directive
  /// could also remove a live platform branch.
  Future<CleanupResult> removeDirectiveReferencing(
    String filePath,
    String targetPath,
  ) async {
    try {
      final file = File(filePath);
      final content = file.readAsStringSync();
      final unit = parseString(
        content: content,
        path: filePath,
        throwIfDiagnostics: false,
      ).unit;
      final edits = <({int start, int end})>[];

      for (final directive in unit.directives) {
        final String? uri;
        final int configurationCount;
        if (directive is ImportDirective) {
          uri = directive.uri.stringValue;
          configurationCount = directive.configurations.length;
        } else if (directive is ExportDirective) {
          uri = directive.uri.stringValue;
          configurationCount = directive.configurations.length;
        } else {
          continue;
        }
        if (uri == null || !_resolvesTo(uri, filePath, targetPath)) continue;
        if (configurationCount > 0) {
          return const CleanupResult(
            success: false,
            stderr: 'Refusing to remove a conditional import/export.',
          );
        }

        var end = directive.end;
        while (end < content.length &&
            (content.codeUnitAt(end) == 0x20 ||
                content.codeUnitAt(end) == 0x09)) {
          end++;
        }
        if (end < content.length && content.codeUnitAt(end) == 0x0d) end++;
        if (end < content.length && content.codeUnitAt(end) == 0x0a) end++;
        edits.add((start: directive.offset, end: end));
      }

      if (edits.isEmpty) {
        return const CleanupResult(
          success: false,
          stderr: 'No matching import/export directive was found.',
        );
      }
      var result = content;
      for (final edit in edits.reversed) {
        result = result.replaceRange(edit.start, edit.end, '');
      }
      file.writeAsStringSync(result);
      return const CleanupResult(success: true, stderr: '');
    } on FileSystemException catch (error) {
      return CleanupResult(success: false, stderr: error.toString());
    }
  }

  bool _resolvesTo(String uri, String importerPath, String targetPath) {
    String candidate;
    if (uri.startsWith('package:')) {
      final slash = uri.indexOf('/');
      if (slash < 0) return false;
      candidate = p.join(projectRoot, 'lib', uri.substring(slash + 1));
    } else {
      final parsed = Uri.tryParse(uri);
      if (parsed == null || parsed.hasScheme && !parsed.isScheme('file')) {
        return false;
      }
      candidate = parsed.isScheme('file')
          ? parsed.toFilePath()
          : p.join(p.dirname(importerPath), uri);
    }
    return p.equals(
      p.normalize(p.absolute(candidate)),
      p.normalize(targetPath),
    );
  }

  /// Runs cleanup on modified files.
  ///
  /// Returns success status and stderr for diagnostics.
  Future<CleanupResult> run(List<String> filePaths) async {
    if (filePaths.isEmpty) {
      return const CleanupResult(success: true, stderr: '');
    }

    try {
      // `dart fix` accepts exactly one path. Run it once per changed file so
      // cleanup cannot mutate unrelated user files outside the transaction.
      final requestedPaths = List<String>.unmodifiable(filePaths);
      for (final filePath in requestedPaths) {
        final result = await _processRunner.run(
          dartExecutable,
          [
            ...dartArgumentPrefix,
            'fix',
            '--apply',
            '--code=unused_import',
            filePath,
          ],
          workingDirectory: projectRoot,
          timeout: timeout,
          maxOutputBytesPerStream: maxOutputBytesPerStream,
        );
        if (result.timedOut || result.exitCode != 0) {
          return CleanupResult(
            success: false,
            stderr: _failureMessage(result),
            exitCode: result.exitCode,
            timedOut: result.timedOut,
          );
        }
      }

      return const CleanupResult(success: true, stderr: '', exitCode: 0);
    } on ProcessTerminationUnconfirmedException catch (error) {
      throw ImportCleanupRecoveryRequiredException(
        processId: error.processId,
        message:
            'Import cleanup process termination was not confirmed. '
            'Rollback is unsafe until the process tree is known to be '
            'stopped. ${error.message}',
      );
    } on ProcessException catch (e) {
      return CleanupResult(success: false, stderr: e.toString());
    }
  }

  String _failureMessage(ManagedProcessResult result) {
    final messages = <String>[];
    final stderr = result.stderr.text.trim();
    final stdout = result.stdout.text.trim();
    if (stderr.isNotEmpty) messages.add(stderr);
    if (stdout.isNotEmpty) messages.add('stdout:\n$stdout');
    if (result.timedOut) {
      messages.add(
        'dart fix timed out after ${timeout.inMilliseconds}ms; its observed '
        'process tree was terminated before cleanup returned.',
      );
    } else {
      messages.add('dart fix exited with code ${result.exitCode}.');
    }
    return messages.join('\n');
  }
}

/// Result of import cleanup operation.
class CleanupResult {
  /// Creates a cleanup result.
  const CleanupResult({
    required this.success,
    required this.stderr,
    this.exitCode,
    this.timedOut = false,
  });

  /// Whether cleanup succeeded (exit code 0).
  final bool success;

  /// Standard error output for diagnostics.
  final String stderr;

  /// Process exit code when cleanup launched a process.
  final int? exitCode;

  /// Whether cleanup reached its deadline after confirmed tree termination.
  final bool timedOut;
}

/// Signals that cleanup may still be mutating and rollback must not start.
class ImportCleanupRecoveryRequiredException implements Exception {
  /// Creates a recovery-required cleanup error.
  const ImportCleanupRecoveryRequiredException({
    required this.processId,
    required this.message,
  });

  /// Root process identifier whose tree could not be confirmed stopped.
  final int processId;

  /// Human-readable recovery detail.
  final String message;

  @override
  String toString() => message;
}
