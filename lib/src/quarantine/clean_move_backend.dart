import 'dart:io';

/// Stable fail-closed categories at the recoverable clean move boundary.
enum CleanMoveFailure {
  /// A relative path component is ambiguous or unsafe on a supported host.
  invalidComponent,

  /// The current host has no reviewed clean-move backend.
  unsupportedPlatform,

  /// The filesystem cannot provide the required identity or move semantics.
  unsupportedCapability,

  /// An object already occupies an exclusive destination.
  collision,

  /// A required source or retained object does not exist.
  notFound,

  /// An observed object is a link, reparse point, or non-directory.
  invalidObject,

  /// The source no longer has the identity authorized by the clean plan.
  identityDrift,

  /// The frozen pathname no longer reaches the retained base capability.
  unreachableBase,

  /// A move crossed its mutation boundary without a confirmed outcome.
  unconfirmedMove,

  /// Required filesystem metadata could not be flushed durably.
  flushFailed,

  /// A retained native capability could not be released cleanly.
  closeFailed,
}

/// Sanitized failure from a platform clean-move capability.
final class CleanMoveException implements Exception {
  /// Creates a failure whose rendered form excludes [cause].
  const CleanMoveException({
    required this.category,
    required this.operation,
    this.cause,
  });

  /// Stable failure category for recovery and CLI classification.
  final CleanMoveFailure category;

  /// Stable operation token that contains no user-controlled path.
  final String operation;

  /// Underlying failure retained for debugging but omitted from [toString].
  final Object? cause;

  @override
  String toString() =>
      'Clean move capability failed; operation=$operation; '
      'category=${category.name}';
}

/// Filesystem object types accepted by recoverable clean.
enum CleanObjectKind {
  /// A real directory, never a link or reparse point.
  directory,
}

/// Stable filesystem identity captured through a retained native capability.
final class CleanObjectIdentity {
  /// Creates identity evidence for one filesystem object.
  const CleanObjectIdentity({
    required this.storageId,
    required this.objectId,
    required this.kind,
  });

  /// Filesystem or volume identity encoded by the platform backend.
  final String storageId;

  /// Inode or file identity encoded by the platform backend.
  final String objectId;

  /// Validated object type.
  final CleanObjectKind kind;

  /// Whether [other] represents the same stable filesystem object.
  bool sameObjectAs(CleanObjectIdentity other) =>
      storageId == other.storageId &&
      objectId == other.objectId &&
      kind == other.kind;

  /// Stable JSON projection used by clean-plan and transaction fingerprints.
  Map<String, Object?> toJson() => <String, Object?>{
    'storageId': storageId,
    'objectId': objectId,
    'kind': kind.name,
  };
}

/// Confirmed result of one no-replace logical-clean move.
final class CleanMoveOutcome {
  /// Creates confirmed move evidence.
  const CleanMoveOutcome({required this.movedIdentity});

  /// Identity observed through the retained destination after the move.
  final CleanObjectIdentity movedIdentity;
}

/// Opens a quarantine base as a retained filesystem capability.
abstract interface class RecoverableCleanMoveBackend {
  /// Anchors [quarantineBase] without following a final link or reparse point.
  Future<AnchoredCleanBase> anchor(Directory quarantineBase);
}

/// Retained authority for one validated quarantine base.
abstract interface class AnchoredCleanBase {
  /// Canonical path frozen for diagnostics and reachability checks only.
  String get canonicalPath;

  /// Stable identity of the retained base directory.
  CleanObjectIdentity get identity;

  /// Inspects one descendant directory without following links.
  Future<CleanObjectIdentity> inspectDirectory(List<String> components);

  /// Creates or validates a directory chain beneath this retained base.
  Future<CleanObjectIdentity> ensureDirectory(List<String> components);

  /// Exclusively creates the final directory below existing parents.
  Future<CleanObjectIdentity> createDirectoryExclusive(List<String> components);

  /// Flushes metadata for one exact descendant directory capability.
  Future<void> flushDirectory(List<String> components);

  /// Moves the exact authorized directory to an absent retained destination.
  Future<CleanMoveOutcome> moveDirectoryNoReplace({
    required List<String> source,
    required List<String> destination,
    required CleanObjectIdentity expectedIdentity,
  });

  /// Flushes retained directory metadata required by the last operation.
  Future<void> flushMetadata();

  /// Releases every retained native capability.
  Future<void> close();
}

/// Validates one portable opaque relative path component.
String validateCleanPathComponent(String component) {
  final codeUnits = component.codeUnits;
  final hasControl = codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
  final baseName = component.split('.').first.toUpperCase();
  final reservedWindowsName =
      baseName == 'CON' ||
      baseName == 'PRN' ||
      baseName == 'AUX' ||
      baseName == 'NUL' ||
      RegExp(r'^(?:COM|LPT)[1-9]$').hasMatch(baseName);
  final invalid =
      component.isEmpty ||
      component == '.' ||
      component == '..' ||
      component.contains('/') ||
      component.contains(r'\') ||
      component.contains(':') ||
      hasControl ||
      component.endsWith('.') ||
      component.endsWith(' ') ||
      reservedWindowsName ||
      codeUnits.length > 240;
  if (invalid) {
    throw const CleanMoveException(
      category: CleanMoveFailure.invalidComponent,
      operation: 'validate-component',
    );
  }
  return component;
}
