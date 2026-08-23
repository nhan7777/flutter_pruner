import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'immutable_bytes.dart';

/// Filesystem entity kinds retained by a staged l10n inventory.
enum L10nStageEntryKind {
  /// A regular file whose stable content can be hashed.
  regularFile,

  /// A directory, recorded without recursively treating it as a file.
  directory,

  /// A symbolic link recorded without following its target.
  symbolicLink,

  /// A socket, FIFO, device, or another unsupported entity kind.
  other,
}

/// Deterministic test-only observation points during an inventory capture.
enum L10nStageInventoryOperation {
  /// The root was validated, before recursive enumeration starts.
  afterRootValidated,

  /// The initial unfollowed path enumeration completed.
  afterEnumeration,

  /// Immediately before one enumerated entry is inspected or read.
  beforeEntryRead,

  /// Immediately after one entry payload was inspected or read.
  afterEntryRead,
}

/// Test-only inventory observer and fault-injection seam.
typedef L10nStageInventoryOperationHook =
    Future<void> Function(
      L10nStageInventoryOperation operation,
      Directory root,
      String? relativePath,
    );

/// One unfollowed entry beneath a staged generation root.
final class L10nStageEntry {
  /// Creates an immutable inventory entry.
  L10nStageEntry({
    required this.relativePath,
    required this.kind,
    required this.sha256,
    required this.posixMode,
    this.authorityIdentity,
    required ImmutableBytes? capturedBytes,
  }) : capturedBytes = capturedBytes == null
           ? null
           : ImmutableBytes.copyOf(capturedBytes.copy()) {
    if (relativePath.isEmpty) {
      throw ArgumentError.value(relativePath, 'relativePath');
    }
    if (sha256 != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256!)) {
      throw ArgumentError.value(sha256, 'sha256');
    }
    if (posixMode != null && (posixMode! < 0 || posixMode! > 0xfff)) {
      throw ArgumentError.value(posixMode, 'posixMode');
    }
    if (authorityIdentity != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(authorityIdentity!)) {
      throw ArgumentError.value(authorityIdentity, 'authorityIdentity');
    }
    if (kind != L10nStageEntryKind.regularFile &&
        (sha256 != null || capturedBytes != null)) {
      throw ArgumentError('Only regular files may retain content evidence.');
    }
  }

  /// Project-relative POSIX path.
  final String relativePath;

  /// Unfollowed filesystem entity kind.
  final L10nStageEntryKind kind;

  /// Exact regular-file content hash, when a stable read succeeded.
  final String? sha256;

  /// Permission bits on POSIX, otherwise null. Links are never followed.
  final int? posixMode;

  /// SHA-256 of the committed physical file stamp for ABA detection.
  final String? authorityIdentity;

  /// Defensively copied bytes only for explicitly requested regular files.
  final ImmutableBytes? capturedBytes;
}

/// One stable, root-independent staged filesystem capture.
final class L10nStageInventoryCapture {
  /// Creates an immutable capture value.
  L10nStageInventoryCapture({
    required Map<String, L10nStageEntry> entries,
    required Iterable<String> invalidPaths,
    required this.fingerprint,
  }) : entries = UnmodifiableMapView(
         SplayTreeMap<String, L10nStageEntry>.of(entries),
       ),
       invalidPaths = List<String>.unmodifiable(
         SplayTreeSet<String>.of(invalidPaths),
       ) {
    for (final entry in this.entries.entries) {
      if (entry.key != entry.value.relativePath) {
        throw ArgumentError('Inventory entry key/path mismatch.');
      }
    }
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw ArgumentError.value(fingerprint, 'fingerprint');
    }
  }

  /// Entries in stable relative-POSIX order.
  final Map<String, L10nStageEntry> entries;

  /// Sorted relative paths that cannot be treated as authoritative.
  ///
  /// The sentinel `.` means the root or enumeration itself was unstable.
  final List<String> invalidPaths;

  /// Root- and capture-projection-independent SHA-256 identity.
  final String fingerprint;

  /// Whether every captured path is authoritative for later comparison.
  bool get valid => invalidPaths.isEmpty;

  /// Creates the diagnostic sentinel used when a tree must not be scanned.
  factory L10nStageInventoryCapture.unavailable() {
    const invalidPaths = <String>['.'];
    return L10nStageInventoryCapture(
      entries: const {},
      invalidPaths: invalidPaths,
      fingerprint: _fingerprint(const {}, invalidPaths),
    );
  }
}

/// Captures deterministic before/after inventories without following links.
final class L10nStageInventory {
  const L10nStageInventory._();

  /// Captures [root], retaining bytes only for [captureBytesFor].
  static Future<L10nStageInventoryCapture> capture(
    Directory root, {
    required Set<String> captureBytesFor,
  }) async {
    final frozenCapturePaths = _validatedCapturePaths(captureBytesFor);
    return await _capture(
      root,
      captureBytesFor: frozenCapturePaths,
      operationHook: null,
    );
  }

  /// Runs the production capture algorithm with deterministic test hooks.
  static Future<L10nStageInventoryCapture> captureForTesting(
    Directory root, {
    required Set<String> captureBytesFor,
    required L10nStageInventoryOperationHook operationHook,
  }) async {
    final frozenCapturePaths = _validatedCapturePaths(captureBytesFor);
    return await _capture(
      root,
      captureBytesFor: frozenCapturePaths,
      operationHook: operationHook,
    );
  }
}

Future<L10nStageInventoryCapture> _capture(
  Directory requestedRoot, {
  required Set<String> captureBytesFor,
  required L10nStageInventoryOperationHook? operationHook,
}) async {
  final root = _validatedRoot(requestedRoot);
  final initialRootIdentity = _rootIdentity(root);
  if (initialRootIdentity == null) {
    return L10nStageInventoryCapture.unavailable();
  }

  try {
    await operationHook?.call(
      L10nStageInventoryOperation.afterRootValidated,
      root,
      null,
    );
  } catch (_) {
    return L10nStageInventoryCapture.unavailable();
  }
  if (_rootIdentity(root) != initialRootIdentity) {
    return L10nStageInventoryCapture.unavailable();
  }

  final enumerated = _enumerate(root);
  if (enumerated == null) return L10nStageInventoryCapture.unavailable();
  try {
    await operationHook?.call(
      L10nStageInventoryOperation.afterEnumeration,
      root,
      null,
    );
  } catch (_) {
    return L10nStageInventoryCapture.unavailable();
  }
  if (_rootIdentity(root) != initialRootIdentity ||
      !_sameStringList(enumerated, _enumerate(root))) {
    return L10nStageInventoryCapture.unavailable();
  }

  final entries = SplayTreeMap<String, L10nStageEntry>();
  final invalidPaths = SplayTreeSet<String>();
  final committedStamps = <String, _EntityStamp>{};

  for (final relativePath in enumerated) {
    try {
      await operationHook?.call(
        L10nStageInventoryOperation.beforeEntryRead,
        root,
        relativePath,
      );
    } catch (_) {
      invalidPaths.add(relativePath);
      continue;
    }
    if (_rootIdentity(root) != initialRootIdentity) {
      return L10nStageInventoryCapture.unavailable();
    }

    final captured = await _captureEntry(
      root,
      relativePath,
      retainBytes: captureBytesFor.contains(relativePath),
      operationHook: operationHook,
    );
    entries[relativePath] = captured.entry;
    if (!captured.valid || !_isSafeRelativePosixPath(relativePath)) {
      invalidPaths.add(relativePath);
    }
    final stamp = captured.committedStamp;
    if (stamp != null) committedStamps[relativePath] = stamp;
  }

  final foldedPaths = <String, List<String>>{};
  for (final path in entries.keys) {
    foldedPaths.putIfAbsent(_asciiFold(path), () => <String>[]).add(path);
  }
  for (final collision in foldedPaths.values.where(
    (paths) => paths.length > 1,
  )) {
    invalidPaths.addAll(collision);
  }

  if (_rootIdentity(root) != initialRootIdentity ||
      !_sameStringList(enumerated, _enumerate(root))) {
    return L10nStageInventoryCapture.unavailable();
  }
  for (final entry in committedStamps.entries) {
    if (_entityStamp(root, entry.key) != entry.value) {
      invalidPaths.add(entry.key);
      final current = entries[entry.key]!;
      if (current.kind == L10nStageEntryKind.regularFile) {
        entries[entry.key] = L10nStageEntry(
          relativePath: entry.key,
          kind: current.kind,
          sha256: null,
          posixMode: current.posixMode,
          authorityIdentity: null,
          capturedBytes: null,
        );
      }
    }
  }

  final frozenEntries = Map<String, L10nStageEntry>.unmodifiable(entries);
  final frozenInvalidPaths = List<String>.unmodifiable(invalidPaths);
  return L10nStageInventoryCapture(
    entries: frozenEntries,
    invalidPaths: frozenInvalidPaths,
    fingerprint: _fingerprint(frozenEntries, frozenInvalidPaths),
  );
}

Future<_CapturedEntry> _captureEntry(
  Directory root,
  String relativePath, {
  required bool retainBytes,
  required L10nStageInventoryOperationHook? operationHook,
}) async {
  final absolutePath = _absolutePath(root, relativePath);
  final initialType = FileSystemEntity.typeSync(
    absolutePath,
    followLinks: false,
  );
  final initialKind = _kind(initialType);

  if (initialKind == L10nStageEntryKind.symbolicLink) {
    return _CapturedEntry(
      entry: L10nStageEntry(
        relativePath: relativePath,
        kind: initialKind,
        sha256: null,
        posixMode: null,
        authorityIdentity: null,
        capturedBytes: null,
      ),
      valid: false,
      committedStamp: null,
    );
  }

  if (initialKind == L10nStageEntryKind.other) {
    final stamp = _entityStamp(root, relativePath);
    return _CapturedEntry(
      entry: L10nStageEntry(
        relativePath: relativePath,
        kind: initialKind,
        sha256: null,
        posixMode: stamp?.posixMode,
        authorityIdentity: null,
        capturedBytes: null,
      ),
      valid: false,
      committedStamp: stamp,
    );
  }

  if (initialKind == L10nStageEntryKind.directory) {
    final before = _entityStamp(root, relativePath);
    try {
      await operationHook?.call(
        L10nStageInventoryOperation.afterEntryRead,
        root,
        relativePath,
      );
    } catch (_) {
      return _invalidEntry(relativePath, initialKind, before?.posixMode);
    }
    final after = _entityStamp(root, relativePath);
    final valid = before != null && before == after;
    return _CapturedEntry(
      entry: L10nStageEntry(
        relativePath: relativePath,
        kind: initialKind,
        sha256: null,
        posixMode: before?.posixMode,
        authorityIdentity: valid && after != null
            ? _authorityIdentity(relativePath, after)
            : null,
        capturedBytes: null,
      ),
      valid: valid,
      committedStamp: valid ? after : null,
    );
  }

  final before = _entityStamp(root, relativePath);
  if (before == null || before.kind != L10nStageEntryKind.regularFile) {
    return _invalidEntry(relativePath, initialKind, before?.posixMode);
  }
  ImmutableBytes? retained;
  String? contentHash;
  try {
    final file = File(absolutePath);
    if (retainBytes) {
      retained = ImmutableBytes.copyOf(await file.readAsBytes());
      contentHash = retained.sha256Hex;
    } else {
      contentHash = (await sha256.bind(file.openRead()).first).toString();
    }
    await operationHook?.call(
      L10nStageInventoryOperation.afterEntryRead,
      root,
      relativePath,
    );
  } catch (_) {
    return _invalidEntry(relativePath, initialKind, before.posixMode);
  }
  final after = _entityStamp(root, relativePath);
  if (after == null || before != after) {
    return _invalidEntry(relativePath, initialKind, before.posixMode);
  }
  return _CapturedEntry(
    entry: L10nStageEntry(
      relativePath: relativePath,
      kind: initialKind,
      sha256: contentHash,
      posixMode: before.posixMode,
      authorityIdentity: _authorityIdentity(relativePath, after),
      capturedBytes: retained,
    ),
    valid: true,
    committedStamp: after,
  );
}

_CapturedEntry _invalidEntry(
  String relativePath,
  L10nStageEntryKind kind,
  int? posixMode,
) => _CapturedEntry(
  entry: L10nStageEntry(
    relativePath: relativePath,
    kind: kind,
    sha256: null,
    posixMode: posixMode,
    authorityIdentity: null,
    capturedBytes: null,
  ),
  valid: false,
  committedStamp: null,
);

Directory _validatedRoot(Directory root) {
  final absolute = Directory(p.normalize(root.absolute.path));
  if (FileSystemEntity.typeSync(absolute.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw ArgumentError.value(root.path, 'root', 'must be a real directory');
  }
  late final String canonicalPath;
  try {
    canonicalPath = p.normalize(absolute.resolveSymbolicLinksSync());
  } on FileSystemException {
    throw ArgumentError.value(root.path, 'root', 'must be canonicalizable');
  }
  if (canonicalPath != absolute.path) {
    throw ArgumentError.value(root.path, 'root', 'must be canonical');
  }
  return absolute;
}

Set<String> _validatedCapturePaths(Set<String> source) {
  final frozen = SplayTreeSet<String>();
  final folded = <String, String>{};
  for (final path in List<String>.of(source)) {
    if (!_isSafeRelativePosixPath(path)) {
      throw ArgumentError.value(path, 'captureBytesFor');
    }
    final fold = _asciiFold(path);
    final prior = folded[fold];
    if (prior != null && prior != path) {
      throw ArgumentError.value(path, 'captureBytesFor');
    }
    folded[fold] = path;
    frozen.add(path);
  }
  return Set<String>.unmodifiable(frozen);
}

List<String>? _enumerate(Directory root) {
  try {
    final paths = <String>[];
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      final relative = p
          .relative(entity.path, from: root.path)
          .split(p.separator)
          .join('/');
      if (relative.isEmpty || relative == '.' || relative.startsWith('../')) {
        return null;
      }
      paths.add(relative);
    }
    paths.sort();
    return paths;
  } on FileSystemException {
    return null;
  }
}

String? _rootIdentity(Directory root) {
  try {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      return null;
    }
    final canonical = p.normalize(root.resolveSymbolicLinksSync());
    if (!Platform.isWindows) {
      final stat = File('/usr/bin/stat');
      if (stat.existsSync()) {
        final result = Process.runSync(
          stat.path,
          Platform.isMacOS
              ? ['-f', '%d:%i', canonical]
              : ['-c', '%d:%i', canonical],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        if (result.exitCode == 0) {
          return '$canonical\u0000${(result.stdout as String).trim()}';
        }
      }
    }
    final stat = root.statSync();
    return [
      canonical,
      stat.type.toString(),
      stat.mode.toRadixString(16),
      stat.changed.microsecondsSinceEpoch,
    ].join('\u0000');
  } on FileSystemException {
    return null;
  }
}

_EntityStamp? _entityStamp(Directory root, String relativePath) {
  final path = _absolutePath(root, relativePath);
  try {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    final kind = _kind(type);
    if (kind == L10nStageEntryKind.symbolicLink ||
        type == FileSystemEntityType.notFound) {
      return null;
    }
    final canonical = p.normalize(File(path).resolveSymbolicLinksSync());
    final canonicalRoot = p.normalize(root.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalRoot, canonical)) return null;
    final stat = FileStat.statSync(path);
    if (_kind(stat.type) != kind) return null;
    return _EntityStamp(
      kind: kind,
      canonicalPath: canonical,
      posixMode: Platform.isWindows ? null : stat.mode & 0xfff,
      size: stat.size,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
      changedMicros: stat.changed.microsecondsSinceEpoch,
    );
  } on FileSystemException {
    return null;
  }
}

L10nStageEntryKind _kind(FileSystemEntityType type) => switch (type) {
  FileSystemEntityType.file => L10nStageEntryKind.regularFile,
  FileSystemEntityType.directory => L10nStageEntryKind.directory,
  FileSystemEntityType.link => L10nStageEntryKind.symbolicLink,
  _ => L10nStageEntryKind.other,
};

String _absolutePath(Directory root, String relativePath) =>
    p.joinAll([root.path, ...relativePath.split('/')]);

bool _isSafeRelativePosixPath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains(':') ||
      value.contains('%') ||
      value.contains('?') ||
      value.contains('#') ||
      value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    return false;
  }
  final segments = value.split('/');
  return segments.every(
    (segment) =>
        segment.isNotEmpty &&
        segment != '.' &&
        segment != '..' &&
        RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
  );
}

String _asciiFold(String value) => String.fromCharCodes(
  value.codeUnits.map(
    (unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
  ),
);

bool _sameStringList(List<String> left, List<String>? right) {
  if (right == null || left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _fingerprint(
  Map<String, L10nStageEntry> entries,
  Iterable<String> invalidPaths,
) {
  final framed = BytesBuilder(copy: false);
  void add(String label, String value) {
    for (final part in [label, value]) {
      final bytes = utf8.encode(part);
      framed
        ..add(ascii.encode(bytes.length.toString()))
        ..addByte(0)
        ..add(bytes)
        ..addByte(0);
    }
  }

  add('schema', 'l10n-stage-inventory-v1');
  for (final entry in SplayTreeMap<String, L10nStageEntry>.of(
    entries,
  ).entries) {
    add('path', entry.key);
    add('kind', entry.value.kind.name);
    add('sha256', entry.value.sha256 ?? 'absent');
    add('posixMode', entry.value.posixMode?.toRadixString(8) ?? 'absent');
  }
  for (final path in SplayTreeSet<String>.of(invalidPaths)) {
    add('invalidPath', path);
  }
  return sha256.convert(framed.takeBytes()).toString();
}

String _authorityIdentity(String relativePath, _EntityStamp stamp) => sha256
    .convert(
      utf8.encode(
        jsonEncode(<Object?>[
          relativePath,
          stamp.kind.name,
          stamp.canonicalPath,
          stamp.posixMode,
          stamp.size,
          stamp.modifiedMicros,
          stamp.changedMicros,
        ]),
      ),
    )
    .toString();

final class _CapturedEntry {
  const _CapturedEntry({
    required this.entry,
    required this.valid,
    required this.committedStamp,
  });

  final L10nStageEntry entry;
  final bool valid;
  final _EntityStamp? committedStamp;
}

final class _EntityStamp {
  const _EntityStamp({
    required this.kind,
    required this.canonicalPath,
    required this.posixMode,
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
  });

  final L10nStageEntryKind kind;
  final String canonicalPath;
  final int? posixMode;
  final int size;
  final int modifiedMicros;
  final int changedMicros;

  @override
  bool operator ==(Object other) =>
      other is _EntityStamp &&
      other.kind == kind &&
      other.canonicalPath == canonicalPath &&
      other.posixMode == posixMode &&
      other.size == size &&
      other.modifiedMicros == modifiedMicros &&
      other.changedMicros == changedMicros;

  @override
  int get hashCode => Object.hash(
    kind,
    canonicalPath,
    posixMode,
    size,
    modifiedMicros,
    changedMicros,
  );
}
