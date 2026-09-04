import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Immutable validated facts for one source in an apply preview.
final class ApplySourceSnapshot {
  /// Creates a source snapshot without retaining caller-owned collections.
  ApplySourceSnapshot({
    required String projectRelativePath,
    required String canonicalPath,
    required this.sha256,
    required this.sizeBytes,
    required this.posixMode,
  }) : projectRelativePath = normalizeProjectRelativePath(projectRelativePath),
       canonicalPath = validateCanonicalAbsolutePath(
         canonicalPath,
         label: 'Source canonical path',
       ) {
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw StateError('Source digest must be lowercase SHA-256.');
    }
    if (sizeBytes < 0) {
      throw StateError('Source size cannot be negative.');
    }
    final mode = posixMode;
    if (mode != null && (mode < 0 || mode > 0xfff)) {
      throw StateError('POSIX mode must fit the permission and special bits.');
    }
  }

  /// Canonical forward-slash path relative to the selected project root.
  final String projectRelativePath;

  /// Canonical absolute file path captured before mutation.
  final String canonicalPath;

  /// Lowercase SHA-256 of the complete source bytes.
  final String sha256;

  /// Exact source byte length. Zero-byte files are valid.
  final int sizeBytes;

  /// POSIX permission and special bits, or null on unsupported platforms.
  final int? posixMode;

  /// Normalizes and validates a project-relative source path.
  static String normalizeProjectRelativePath(String value) {
    if (value.isEmpty || _controlCharacterPattern.hasMatch(value)) {
      throw StateError('Project-relative paths must be non-empty text.');
    }
    if (p.posix.isAbsolute(value) ||
        p.windows.rootPrefix(value).isNotEmpty ||
        _windowsDrivePrefixPattern.hasMatch(value)) {
      throw StateError(
        'Project-relative paths cannot have an absolute or drive root.',
      );
    }
    final slashPath = value.replaceAll('\\', '/');
    if (slashPath.split('/').contains('..')) {
      throw StateError('Project-relative paths cannot traverse parents.');
    }
    final normalized = p.posix.normalize(slashPath);
    if (normalized == '.' || normalized != slashPath) {
      throw StateError('Project-relative paths must be normalized.');
    }
    return normalized;
  }

  /// Validates an absolute canonical path without consulting the filesystem.
  static String validateCanonicalAbsolutePath(
    String value, {
    required String label,
  }) => validateCanonicalAbsolutePathForHost(
    value,
    label: label,
    isWindowsHost: Platform.isWindows,
  );

  /// Pure host-specific validation seam for cross-platform tests.
  ///
  /// Production constructors always use [validateCanonicalAbsolutePath], which
  /// derives the host from [Platform.isWindows].
  static String validateCanonicalAbsolutePathForHost(
    String value, {
    required String label,
    required bool isWindowsHost,
  }) {
    if (value.isEmpty || _controlCharacterPattern.hasMatch(value)) {
      throw StateError('$label must be non-empty text.');
    }
    final isWindows = p.windows.isAbsolute(value);
    final isPosix = p.posix.isAbsolute(value);
    if (isWindowsHost) {
      if (!isWindows) {
        throw StateError('$label must be absolute.');
      }
      if (p.windows.isRootRelative(value)) {
        throw StateError('$label cannot depend on the current Windows drive.');
      }
      if (p.windows.normalize(value) != value) {
        throw StateError('$label must be normalized.');
      }
      return value;
    }
    if (!isWindows && !isPosix) {
      throw StateError('$label must be absolute.');
    }
    if (value.startsWith(r'\') && p.windows.isRootRelative(value)) {
      throw StateError('$label cannot depend on the current Windows drive.');
    }
    final context = isWindows && !isPosix ? p.windows : p.posix;
    if (context.normalize(value) != value) {
      throw StateError('$label must be normalized.');
    }
    return value;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplySourceSnapshot &&
          projectRelativePath == other.projectRelativePath &&
          canonicalPath == other.canonicalPath &&
          sha256 == other.sha256 &&
          sizeBytes == other.sizeBytes &&
          posixMode == other.posixMode;

  @override
  int get hashCode => Object.hash(
    projectRelativePath,
    canonicalPath,
    sha256,
    sizeBytes,
    posixMode,
  );
}

/// Immutable versioned evidence binding a plan to its source file states.
final class ApplyPreviewEvidence {
  /// Creates, validates, sorts, and fingerprints apply preview evidence.
  factory ApplyPreviewEvidence({
    required String canonicalProjectRoot,
    required String? planFingerprint,
    required Iterable<ApplySourceSnapshot> sources,
  }) {
    final root = ApplySourceSnapshot.validateCanonicalAbsolutePath(
      canonicalProjectRoot,
      label: 'Canonical project root',
    );
    if (planFingerprint != null && !_sha256Pattern.hasMatch(planFingerprint)) {
      throw StateError('Apply plan fingerprint must be lowercase SHA-256.');
    }
    final sourceSnapshot = _sortedUniqueSources(sources);
    if ((planFingerprint == null) != sourceSnapshot.isEmpty) {
      throw StateError(
        'Preview sources must exist exactly when an action plan exists.',
      );
    }
    for (final source in sourceSnapshot) {
      _validateSourceBelongsToProject(source, root);
    }
    final provisional = ApplyPreviewEvidence._(
      canonicalProjectRoot: root,
      planFingerprint: planFingerprint,
      sources: sourceSnapshot,
      fingerprint: '',
    );
    final fingerprint = const ApplyPreviewCanonicalEncoder().fingerprint(
      provisional,
    );
    return ApplyPreviewEvidence._(
      canonicalProjectRoot: root,
      planFingerprint: planFingerprint,
      sources: sourceSnapshot,
      fingerprint: fingerprint,
    );
  }

  const ApplyPreviewEvidence._({
    required this.canonicalProjectRoot,
    required this.planFingerprint,
    required this.sources,
    required this.fingerprint,
  });

  /// Version of the canonical preview token payload.
  static const int canonicalVersion = 1;

  /// Canonical absolute root whose file states were captured.
  final String canonicalProjectRoot;

  /// Unchanged v1 action-plan fingerprint, or null for an empty plan.
  final String? planFingerprint;

  /// Unique source snapshots in canonical path order.
  final List<ApplySourceSnapshot> sources;

  /// Full versioned preview token in `v1:<lowercase SHA-256>` form.
  final String fingerprint;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyPreviewEvidence &&
          canonicalProjectRoot == other.canonicalProjectRoot &&
          planFingerprint == other.planFingerprint &&
          fingerprint == other.fingerprint &&
          _listEquals(sources, other.sources);

  @override
  int get hashCode => Object.hash(
    canonicalProjectRoot,
    planFingerprint,
    fingerprint,
    Object.hashAll(sources),
  );
}

/// Stable JSON encoder for version 1 apply preview evidence.
final class ApplyPreviewCanonicalEncoder {
  /// Creates a stateless canonical encoder.
  const ApplyPreviewCanonicalEncoder();

  /// Encodes [evidence] with fixed keys and already canonical source order.
  String encode(ApplyPreviewEvidence evidence) => jsonEncode({
    'version': ApplyPreviewEvidence.canonicalVersion,
    'projectRoot': evidence.canonicalProjectRoot,
    'planFingerprint': evidence.planFingerprint,
    'sources': [
      for (final source in evidence.sources)
        {
          'projectRelativePath': source.projectRelativePath,
          'canonicalPath': source.canonicalPath,
          'sha256': source.sha256,
          'sizeBytes': source.sizeBytes,
          'posixMode': source.posixMode,
        },
    ],
  });

  /// Returns the full versioned token for [evidence].
  String fingerprint(ApplyPreviewEvidence evidence) =>
      'v1:${sha256.convert(utf8.encode(encode(evidence)))}';
}

/// Whether [value] is a complete version 1 apply preview token.
bool isValidApplyPreviewFingerprint(String value) =>
    _previewFingerprintPattern.hasMatch(value);

final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');
final RegExp _previewFingerprintPattern = RegExp(r'^v1:[0-9a-f]{64}$');
final RegExp _controlCharacterPattern = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _windowsDrivePrefixPattern = RegExp(r'^[A-Za-z]:');

List<ApplySourceSnapshot> _sortedUniqueSources(
  Iterable<ApplySourceSnapshot> sources,
) {
  final snapshot = List<ApplySourceSnapshot>.of(sources)
    ..sort((left, right) {
      final relative = left.projectRelativePath.compareTo(
        right.projectRelativePath,
      );
      return relative != 0
          ? relative
          : left.canonicalPath.compareTo(right.canonicalPath);
    });
  final relativePaths = <String>{};
  final canonicalPaths = <String>{};
  for (final source in snapshot) {
    if (!relativePaths.add(source.projectRelativePath) ||
        !canonicalPaths.add(_canonicalPathIdentity(source.canonicalPath))) {
      throw StateError('Apply preview sources must be unique.');
    }
  }
  return List<ApplySourceSnapshot>.unmodifiable(snapshot);
}

void _validateSourceBelongsToProject(
  ApplySourceSnapshot source,
  String canonicalProjectRoot,
) {
  final rootIsWindows = p.windows.isAbsolute(canonicalProjectRoot);
  final sourceIsWindows = p.windows.isAbsolute(source.canonicalPath);
  final rootIsPosix = p.posix.isAbsolute(canonicalProjectRoot);
  final sourceIsPosix = p.posix.isAbsolute(source.canonicalPath);
  if (rootIsWindows != sourceIsWindows || rootIsPosix != sourceIsPosix) {
    throw StateError('Preview source path style does not match project root.');
  }
  final context = rootIsWindows && !rootIsPosix ? p.windows : p.posix;
  if (!context.equals(canonicalProjectRoot, source.canonicalPath) &&
      !context.isWithin(canonicalProjectRoot, source.canonicalPath)) {
    throw StateError('Preview source resolves outside the project root.');
  }
  final relative = context
      .relative(source.canonicalPath, from: canonicalProjectRoot)
      .replaceAll('\\', '/');
  if (relative != source.projectRelativePath) {
    throw StateError(
      'Preview source relative and canonical paths identify different files.',
    );
  }
}

String _canonicalPathIdentity(String path) =>
    p.posix.isAbsolute(path) ? path : path.toLowerCase();

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
