import 'dart:io';

/// Stable fail-closed categories for native report object operations.
enum ReportObjectBackendFailure {
  /// A requested leaf cannot be represented safely on every supported host.
  invalidLeaf,

  /// The host platform is outside the supported production matrix.
  unsupportedPlatform,

  /// A required native capability is absent or returned an invalid result.
  unsupportedCapability,

  /// An immutable object already occupies the requested leaf.
  collision,

  /// The requested immutable object does not exist.
  notFound,

  /// A retained capability no longer identifies an acceptable regular object.
  invalidObject,

  /// A retained parent capability is no longer reachable by its frozen path.
  unreachableDirectory,

  /// A native read, write, flush, seek, identity, or close operation failed.
  operationFailed,
}

/// Sanitized failure at the report object capability boundary.
final class ReportObjectBackendException implements Exception {
  /// Creates a failure whose diagnostic excludes native paths and cause text.
  const ReportObjectBackendException({
    required this.category,
    required this.operation,
    this.cause,
  });

  /// Stable failure category used by callers and recovery diagnostics.
  final ReportObjectBackendFailure category;

  /// Stable operation token, never a user-controlled pathname.
  final String operation;

  /// Underlying error retained for debugging, but omitted from [toString].
  final Object? cause;

  @override
  String toString() =>
      'Report object capability failed; operation=$operation; '
      'category=${category.name}';
}

/// Stable identity and observed length of one retained regular object.
final class ReportObjectIdentity {
  /// Creates a validated cross-platform object identity.
  ReportObjectIdentity({
    required this.storageId,
    required this.objectId,
    required this.byteLength,
  }) {
    if (!_isIdentityToken(storageId)) {
      throw ArgumentError.value(storageId, 'storageId', 'Invalid identity.');
    }
    if (!_isIdentityToken(objectId)) {
      throw ArgumentError.value(objectId, 'objectId', 'Invalid identity.');
    }
    if (byteLength < 0) {
      throw ArgumentError.value(
        byteLength,
        'byteLength',
        'Cannot be negative.',
      );
    }
  }

  /// Filesystem or volume identity, encoded by the platform backend.
  final String storageId;

  /// Inode or file identity, encoded by the platform backend.
  final String objectId;

  /// Exact object length observed through the retained handle.
  final int byteLength;

  /// Whether both observations identify the same filesystem object.
  ///
  /// Length is deliberately excluded because regular objects grow while being
  /// written and directory metadata length changes as children are appended.
  bool sameObjectAs(ReportObjectIdentity other) =>
      other.storageId == storageId && other.objectId == objectId;

  @override
  bool operator ==(Object other) =>
      other is ReportObjectIdentity &&
      other.storageId == storageId &&
      other.objectId == objectId &&
      other.byteLength == byteLength;

  @override
  int get hashCode => Object.hash(storageId, objectId, byteLength);

  @override
  String toString() =>
      'ReportObjectIdentity(storageId=$storageId, objectId=$objectId, '
      'byteLength=$byteLength)';
}

/// Opens anchored report directories without exposing general path mutation.
abstract interface class ReportObjectBackend {
  /// Freezes and validates [directory] before report analysis or mutation.
  Future<AnchoredReportDirectory> anchor(Directory directory);
}

/// Retained capability for a validated report directory.
abstract interface class AnchoredReportDirectory {
  /// Frozen canonical path used only for diagnostics and reachability checks.
  String get canonicalPath;

  /// Exclusively creates one regular object and retains its new handle.
  Future<ExclusiveReportObject> createExclusive(String leaf);

  /// Opens one existing regular object without following its final link.
  Future<ExistingReportObject> openExisting(String leaf);

  /// Revalidates that the frozen path reaches this same directory capability.
  Future<void> verifyReachable();

  /// Releases the retained directory capability.
  Future<void> close();
}

/// Newly created immutable object capability used for write and read-back.
abstract interface class ExclusiveReportObject {
  /// Writes all [bytes] through this retained object capability.
  Future<void> write(List<int> bytes);

  /// Flushes object content through this retained capability.
  Future<void> flush();

  /// Rewinds this retained capability for exact read-back.
  Future<void> rewind();

  /// Reads at most [maximumBytes] from this retained capability.
  Future<List<int>> read(int maximumBytes);

  /// Returns the stable identity observed through this retained capability.
  Future<ReportObjectIdentity> identity();

  /// Releases this retained object capability.
  Future<void> close();
}

/// Read-only retained capability for an existing immutable object.
abstract interface class ExistingReportObject {
  /// Rewinds this retained capability for exact validation.
  Future<void> rewind();

  /// Reads at most [maximumBytes] from this retained capability.
  Future<List<int>> read(int maximumBytes);

  /// Returns the stable identity observed through this retained capability.
  Future<ReportObjectIdentity> identity();

  /// Releases this retained object capability.
  Future<void> close();
}

/// Validates one directory-relative object name before a native operation.
void validateReportObjectLeaf(String leaf) {
  final codeUnits = leaf.codeUnits;
  final hasControl = codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
  final baseName = leaf.split('.').first.toUpperCase();
  final reservedWindowsName =
      baseName == 'CON' ||
      baseName == 'PRN' ||
      baseName == 'AUX' ||
      baseName == 'NUL' ||
      RegExp(r'^(?:COM|LPT)[1-9]$').hasMatch(baseName);
  final invalid =
      leaf.isEmpty ||
      leaf == '.' ||
      leaf == '..' ||
      leaf.contains('/') ||
      leaf.contains(r'\') ||
      leaf.contains(':') ||
      hasControl ||
      leaf.endsWith('.') ||
      leaf.endsWith(' ') ||
      reservedWindowsName ||
      codeUnits.length > 240;
  if (invalid) {
    throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.invalidLeaf,
      operation: 'validate-leaf',
    );
  }
}

/// Completes a native write even when the primitive reports short progress.
Future<void> writeAllReportBytes(
  int byteLength,
  Future<int> Function(int offset, int length) writeChunk,
) async {
  if (byteLength < 0) {
    throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.unsupportedCapability,
      operation: 'write',
    );
  }
  var offset = 0;
  while (offset < byteLength) {
    final remaining = byteLength - offset;
    final written = await writeChunk(offset, remaining);
    if (written <= 0 || written > remaining) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'write',
      );
    }
    offset += written;
  }
}

/// Runs [body], always closes its capability, and preserves the first error.
Future<T> runWithReportCapability<T>({
  required Future<T> Function() body,
  required Future<void> Function() close,
}) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  T? result;
  try {
    result = await body();
  } on Object catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }

  try {
    await close();
  } on Object catch (error, stackTrace) {
    if (firstError == null) {
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
  return result as T;
}

bool _isIdentityToken(String value) =>
    value.isNotEmpty &&
    !value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
