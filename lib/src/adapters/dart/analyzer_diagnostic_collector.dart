import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:analyzer/source/line_info.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import 'dart_ids.dart';

/// Collects analyzer/linter unused diagnostics from the Dart CLI.
///
/// The analyzer package does not register SDK lint implementations for direct
/// API consumers. `dart analyze --format=machine` supplies those additional
/// lint results using the project's own analysis-options and package config.
final class AnalyzerDiagnosticCollector {
  /// Stable unused-diagnostic codes surfaced as review-only findings.
  static const supportedCodes = {
    'avoid_unused_constructor_parameters',
    'unused_element',
    'unused_element_parameter',
    'unused_field',
    'unused_import',
    'unused_local_variable',
  };

  /// Maximum wall time for the one project-level analyzer invocation.
  static const timeout = Duration(minutes: 2);

  /// Removes analyzer code-family prefixes and normalizes the wire value.
  static String normalizeCode(String value) {
    final normalized = value.toLowerCase();
    final separator = normalized.lastIndexOf('.');
    return separator == -1 ? normalized : normalized.substring(separator + 1);
  }

  /// Returns lint-inclusive diagnostics, or an unavailable result.
  Future<AnalyzerDiagnosticCollection> collect(ProjectContext project) async {
    final optionsFile = File(
      p.join(project.root.path, 'analysis_options.yaml'),
    );
    if (!optionsFile.existsSync()) {
      return const AnalyzerDiagnosticCollection.skipped();
    }

    final resolvedExecutable = Platform.resolvedExecutable;
    final executable = p.basenameWithoutExtension(resolvedExecutable) == 'dart'
        ? resolvedExecutable
        : 'dart';
    Process process;
    try {
      process = await Process.start(
        executable,
        ['analyze', '--format=machine', project.root.path],
        workingDirectory: project.root.path,
        runInShell: false,
      );
    } on ProcessException catch (error) {
      return AnalyzerDiagnosticCollection.unavailable(error.message);
    }

    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    int exitCode;
    try {
      exitCode = await process.exitCode.timeout(timeout);
    } on TimeoutException {
      process.kill();
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
        await Future.wait([
          stdoutFuture,
          stderrFuture,
        ]).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
      return const AnalyzerDiagnosticCollection.unavailable(
        'dart analyze timed out while collecting lint diagnostics',
      );
    }
    final output = await stdoutFuture;
    final errorOutput = await stderrFuture;
    if (exitCode < 0 || exitCode > 3) {
      final detail = errorOutput.trim();
      return AnalyzerDiagnosticCollection.unavailable(
        detail.isEmpty
            ? 'dart analyze exited with code $exitCode'
            : 'dart analyze exited with code $exitCode: $detail',
      );
    }

    final diagnostics = <AnalyzerUnusedDiagnostic>[];
    for (final line in const LineSplitter().convert(output)) {
      final parsed = _parseMachineLine(line, project);
      if (parsed != null) diagnostics.add(parsed);
    }
    return AnalyzerDiagnosticCollection.available(diagnostics);
  }

  AnalyzerUnusedDiagnostic? _parseMachineLine(
    String line,
    ProjectContext project,
  ) {
    final fields = line.split('|');
    if (fields.length < 8) return null;
    final code = normalizeCode(fields[2]);
    if (!supportedCodes.contains(code)) return null;
    final path = _modeledPath(project, fields[3]);
    if (path == null) return null;
    final lineNumber = int.tryParse(fields[4]);
    final columnNumber = int.tryParse(fields[5]);
    final length = int.tryParse(fields[6]);
    if (lineNumber == null ||
        columnNumber == null ||
        length == null ||
        lineNumber < 1 ||
        columnNumber < 1 ||
        length < 0) {
      return null;
    }
    final file = File(path);
    if (!file.existsSync()) return null;
    final content = file.readAsStringSync();
    final lineInfo = LineInfo.fromContent(content);
    if (lineNumber > lineInfo.lineCount) return null;
    final offset = lineInfo.getOffsetOfLine(lineNumber - 1) + columnNumber - 1;
    if (offset < 0 || offset > content.length) return null;
    return AnalyzerUnusedDiagnostic(
      path: path,
      code: code,
      message: fields.sublist(7).join('|'),
      line: lineNumber,
      column: columnNumber,
      length: length,
      offset: offset,
    );
  }

  String? _modeledPath(ProjectContext project, String rawPath) {
    final path = p.normalize(p.absolute(rawPath));
    if (DartIds.isModeledProjectPath(project, path)) return path;

    // The Dart CLI resolves symlinked roots (including macOS /var ->
    // /private/var) before emitting machine diagnostics. Map that canonical
    // path back to the selected root before enforcing the project boundary.
    late final String canonicalRoot;
    try {
      canonicalRoot = p.normalize(project.root.resolveSymbolicLinksSync());
    } on FileSystemException {
      return null;
    }
    if (path != canonicalRoot && !p.isWithin(canonicalRoot, path)) return null;
    final selectedPath = p.normalize(
      p.join(project.root.absolute.path, p.relative(path, from: canonicalRoot)),
    );
    return DartIds.isModeledProjectPath(project, selectedPath)
        ? selectedPath
        : null;
  }
}

/// Outcome of the optional lint-inclusive Dart CLI collection.
final class AnalyzerDiagnosticCollection {
  /// Creates an available collection.
  const AnalyzerDiagnosticCollection.available(this.diagnostics)
    : attempted = true,
      available = true,
      failure = null;

  /// Creates a skipped collection when no project analysis options exist.
  const AnalyzerDiagnosticCollection.skipped()
    : attempted = false,
      available = true,
      diagnostics = const [],
      failure = null;

  /// Creates a failed collection that must lower confidence.
  const AnalyzerDiagnosticCollection.unavailable(this.failure)
    : attempted = true,
      available = false,
      diagnostics = const [];

  /// Whether the external analyzer was required and started.
  final bool attempted;

  /// Whether lint diagnostics were collected reliably.
  final bool available;

  /// Selected unused diagnostics.
  final List<AnalyzerUnusedDiagnostic> diagnostics;

  /// Stable failure detail for blocker reporting.
  final String? failure;
}

/// One normalized analyzer machine-output row.
final class AnalyzerUnusedDiagnostic {
  /// Creates one normalized diagnostic.
  const AnalyzerUnusedDiagnostic({
    required this.path,
    required this.code,
    required this.message,
    required this.line,
    required this.column,
    required this.length,
    required this.offset,
  });

  /// Absolute normalized source path.
  final String path;

  /// Stable lowercase diagnostic code.
  final String code;

  /// Analyzer message.
  final String message;

  /// One-based source line.
  final int line;

  /// One-based source column.
  final int column;

  /// Diagnostic source length.
  final int length;

  /// Zero-based source offset.
  final int offset;
}
