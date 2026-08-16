import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/error/error.dart';
import 'package:path/path.dart' as p;

import '../core/project/project_context.dart';

/// Decides whether to delete files that become empty after declaration removal.
class FileLifecycleManager {
  /// Creates a file lifecycle manager.
  const FileLifecycleManager(this.project);

  /// Project context, used to resolve paths relative to the project root.
  final ProjectContext project;

  /// Returns true if the file should be deleted.
  ///
  /// A file should be deleted only if:
  /// 1. It contains no declarations and no directives (whitespace and comments
  ///    only), and
  /// 2. It is not a public API entry point (under `lib/`, outside `lib/src/`),
  ///    and
  /// 3. It lies inside the project root.
  ///
  /// Emptiness is decided by parsing, never by scanning source text: a comment
  /// and a declaration can share a line, so a line-prefix test cannot tell them
  /// apart. Anything undecidable resolves to "keep the file" — a missed cleanup
  /// is recoverable, deleting live code is not.
  bool shouldDelete(
    String filePath,
    String content, {
    bool hasExistingImporters = false,
  }) {
    if (!_isInsideProject(filePath)) return false;
    if (_isPublicApi(filePath)) return false;
    if (hasExistingImporters) return false;
    if (!_isEmpty(content)) return false;
    return true;
  }

  /// True when [content] parses cleanly and holds no declarations or directives.
  ///
  /// A `part of` or `library` directive counts as content, so a part file is
  /// never considered empty. Content that fails to parse is never considered
  /// empty either, because an unparseable file may still hold live code.
  bool _isEmpty(String content) {
    final result = parseString(content: content, throwIfDiagnostics: false);
    final hasSyntaxError = result.errors.any(
      (d) => d.diagnosticCode.severity == DiagnosticSeverity.ERROR,
    );
    if (hasSyntaxError) return false;

    return result.unit.declarations.isEmpty && result.unit.directives.isEmpty;
  }

  /// True when [filePath] is a public API entry point: under `lib/` but outside
  /// `lib/src/`. Such a file may be imported by an external consumer, so it must
  /// survive even when empty.
  bool _isPublicApi(String filePath) {
    final relative = project.relative(filePath);
    if (!relative.startsWith('lib/')) return false;
    if (relative.startsWith('lib/src/')) return false;
    return true;
  }

  /// True when [filePath] resolves inside the project root. A path that escapes
  /// the root is never deleted.
  bool _isInsideProject(String filePath) {
    final relative = project.relative(filePath);
    return !relative.startsWith('..') && !p.isAbsolute(relative);
  }
}
