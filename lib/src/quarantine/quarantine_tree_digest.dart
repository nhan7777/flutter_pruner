import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Stable no-follow digest of one complete quarantine directory tree.
final class QuarantineTreeDigest {
  /// Creates verified canonical tree evidence.
  const QuarantineTreeDigest({
    required this.canonicalJson,
    required this.sha256,
  });

  /// Canonical JSON whose entry paths are relative and slash-normalized.
  final String canonicalJson;

  /// Lowercase SHA-256 of [canonicalJson].
  final String sha256;
}

/// Signals that exact tree evidence changed or contained an unsafe object.
final class QuarantineTreeDigestException implements Exception {
  /// Creates a sanitized tree-capture failure.
  const QuarantineTreeDigestException(this.code);

  /// Stable failure token without a filesystem path.
  final String code;

  @override
  String toString() => 'Quarantine tree evidence failed; code=$code';
}

/// Captures every regular file and directory without following links.
Future<QuarantineTreeDigest> captureQuarantineTreeDigest(Directory root) async {
  final canonicalRoot = p.normalize(root.absolute.resolveSymbolicLinksSync());
  final entries = <Map<String, Object?>>[];
  await _captureDirectory(
    directory: Directory(canonicalRoot),
    canonicalRoot: canonicalRoot,
    entries: entries,
  );
  entries.sort(
    (left, right) =>
        (left['path']! as String).compareTo(right['path']! as String),
  );
  final canonicalJson = jsonEncode(<String, Object?>{
    'version': 1,
    'entries': entries,
  });
  return QuarantineTreeDigest(
    canonicalJson: canonicalJson,
    sha256: sha256.convert(utf8.encode(canonicalJson)).toString(),
  );
}

Future<void> _captureDirectory({
  required Directory directory,
  required String canonicalRoot,
  required List<Map<String, Object?>> entries,
}) async {
  final path = p.normalize(p.absolute(directory.path));
  _requirePath(path, canonicalRoot: canonicalRoot, allowRoot: true);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const QuarantineTreeDigestException('directory-changed');
  }
  _requireResolved(
    directory.resolveSymbolicLinksSync(),
    expectedPath: path,
    canonicalRoot: canonicalRoot,
  );
  final before = directory.statSync();
  final children = await directory.list(followLinks: false).toList()
    ..sort((left, right) => left.path.compareTo(right.path));
  entries.add(
    _entry(
      path: _portablePath(path, canonicalRoot),
      type: 'directory',
      size: null,
      byteSha256: null,
      posixMode: _portableMode(before),
    ),
  );
  for (final child in children) {
    final childPath = p.normalize(p.absolute(child.path));
    _requirePath(childPath, canonicalRoot: canonicalRoot);
    switch (FileSystemEntity.typeSync(childPath, followLinks: false)) {
      case FileSystemEntityType.directory:
        await _captureDirectory(
          directory: Directory(childPath),
          canonicalRoot: canonicalRoot,
          entries: entries,
        );
      case FileSystemEntityType.file:
        entries.add(
          await _captureFile(File(childPath), canonicalRoot: canonicalRoot),
        );
      case FileSystemEntityType.link:
        throw const QuarantineTreeDigestException('symbolic-link');
      case FileSystemEntityType.pipe || FileSystemEntityType.unixDomainSock:
        throw const QuarantineTreeDigestException('special-entry');
      case FileSystemEntityType.notFound:
        throw const QuarantineTreeDigestException('entry-disappeared');
      default:
        throw const QuarantineTreeDigestException('unsupported-entry');
    }
  }
  final after = directory.statSync();
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !_sameStat(before, after)) {
    throw const QuarantineTreeDigestException('directory-drift');
  }
  _requireResolved(
    directory.resolveSymbolicLinksSync(),
    expectedPath: path,
    canonicalRoot: canonicalRoot,
  );
}

Future<Map<String, Object?>> _captureFile(
  File file, {
  required String canonicalRoot,
}) async {
  final path = p.normalize(p.absolute(file.path));
  _requirePath(path, canonicalRoot: canonicalRoot);
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const QuarantineTreeDigestException('file-changed');
  }
  _requireResolved(
    file.resolveSymbolicLinksSync(),
    expectedPath: path,
    canonicalRoot: canonicalRoot,
  );
  final before = file.statSync();
  final output = _DigestSink();
  final input = sha256.startChunkedConversion(output);
  var bytesRead = 0;
  final handle = await file.open();
  try {
    while (true) {
      final chunk = await handle.read(64 * 1024);
      if (chunk.isEmpty) break;
      bytesRead += chunk.length;
      input.add(chunk);
    }
  } finally {
    await handle.close();
  }
  input.close();
  final after = file.statSync();
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file ||
      bytesRead != before.size ||
      bytesRead != after.size ||
      !_sameStat(before, after)) {
    throw const QuarantineTreeDigestException('file-drift');
  }
  _requireResolved(
    file.resolveSymbolicLinksSync(),
    expectedPath: path,
    canonicalRoot: canonicalRoot,
  );
  return _entry(
    path: _portablePath(path, canonicalRoot),
    type: 'file',
    size: bytesRead,
    byteSha256: output.value.toString(),
    posixMode: _portableMode(before),
  );
}

void _requirePath(
  String path, {
  required String canonicalRoot,
  bool allowRoot = false,
}) {
  if (p.equals(path, canonicalRoot)) {
    if (allowRoot) return;
    throw const QuarantineTreeDigestException('root-alias');
  }
  if (!p.isWithin(canonicalRoot, path)) {
    throw const QuarantineTreeDigestException('path-escape');
  }
}

void _requireResolved(
  String resolved, {
  required String expectedPath,
  required String canonicalRoot,
}) {
  final normalized = p.normalize(resolved);
  if (!p.equals(normalized, expectedPath) ||
      (!p.equals(normalized, canonicalRoot) &&
          !p.isWithin(canonicalRoot, normalized))) {
    throw const QuarantineTreeDigestException('resolved-path-drift');
  }
}

String _portablePath(String path, String canonicalRoot) {
  if (p.equals(path, canonicalRoot)) return '.';
  final relative = p.relative(path, from: canonicalRoot);
  if (p.isAbsolute(relative) ||
      relative == '..' ||
      relative.startsWith('..${p.separator}')) {
    throw const QuarantineTreeDigestException('relative-path-escape');
  }
  return p.posix.joinAll(p.split(relative));
}

Map<String, Object?> _entry({
  required String path,
  required String type,
  required int? size,
  required String? byteSha256,
  required int? posixMode,
}) => <String, Object?>{
  'path': path,
  'type': type,
  'size': size,
  'byteSha256': byteSha256,
  'posixMode': posixMode,
};

int? _portableMode(FileStat stat) =>
    Platform.isLinux || Platform.isMacOS ? stat.mode & 0xfff : null;

bool _sameStat(FileStat left, FileStat right) =>
    left.type == right.type &&
    left.size == right.size &&
    left.modified == right.modified &&
    left.changed == right.changed &&
    _portableMode(left) == _portableMode(right);

final class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value =>
      _digest ?? (throw StateError('Digest was not completed.'));

  @override
  void add(Digest data) {
    if (_digest != null) throw StateError('Digest already completed.');
    _digest = data;
  }

  @override
  void close() {}
}
