import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../report_object_backend.dart';
import 'posix_bindings.dart';

const _interrupted = 4;
const _notFound = 2;
const _alreadyExists = 17;
const _notDirectory = 20;
const _linuxSymbolicLinkLoop = 40;
const _macosSymbolicLinkLoop = 62;
const _seekStart = 0;
const _modeTypeMask = 0xF000;
const _modeDirectory = 0x4000;
const _modeRegular = 0x8000;
const _creationMode = 0x180;
const _statBufferLength = 256;
const _fileSystemBufferLength = 4096;
const _maximumReadLength = 16 * 1024 * 1024;

/// Direct-FFI immutable report backend for Linux and macOS.
final class PosixReportObjectBackend implements ReportObjectBackend {
  /// Creates a backend backed only by the system C library.
  PosixReportObjectBackend({PosixBindings? bindings})
    : _bindings = bindings ?? _loadBindings();

  final PosixBindings _bindings;

  static PosixBindings _loadBindings() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedPlatform,
        operation: 'load-posix-backend',
      );
    }
    try {
      _PosixStatLayout.current;
      return PosixBindings.open();
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'load-posix-backend',
        cause: error,
      );
    }
  }

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async {
    String canonicalPath;
    try {
      canonicalPath = directory.absolute.resolveSymbolicLinksSync();
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.invalidObject,
        operation: 'anchor-directory',
        cause: error,
      );
    }

    final descriptor = _openDirectory(_bindings, canonicalPath);
    try {
      final stat = _readStat(_bindings, descriptor, 'anchor-directory');
      if (!stat.isDirectory) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'anchor-directory',
        );
      }
      _verifyAcceptedFileSystem(_bindings, descriptor);
      return _PosixAnchoredReportDirectory(
        bindings: _bindings,
        canonicalPath: canonicalPath,
        descriptor: descriptor,
        identity: stat.identity,
      );
    } on Object {
      _closeIgnoringFailure(_bindings, descriptor);
      rethrow;
    }
  }
}

final class _PosixAnchoredReportDirectory implements AnchoredReportDirectory {
  _PosixAnchoredReportDirectory({
    required PosixBindings bindings,
    required this.canonicalPath,
    required int descriptor,
    required ReportObjectIdentity identity,
  }) : _bindings = bindings,
       _descriptor = descriptor,
       _identity = identity;

  final PosixBindings _bindings;
  final ReportObjectIdentity _identity;
  int _descriptor;

  @override
  final String canonicalPath;

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async {
    _ensureOpen('create-exclusive');
    validateReportObjectLeaf(leaf);
    final flags = _PosixFlags.current.createExclusive;
    final descriptor = _bindings.withCString(
      leaf,
      (pointer) => _retryInterrupted(
        _bindings,
        () =>
            _bindings.openAtCreate(_descriptor, pointer, flags, _creationMode),
      ),
    );
    if (descriptor < 0) {
      _throwOpenFailure(_bindings.errno, 'create-exclusive', collision: true);
    }
    try {
      final stat = _readStat(_bindings, descriptor, 'create-exclusive');
      if (!stat.isRegular || stat.identity.byteLength != 0) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'create-exclusive',
        );
      }
      return _PosixExclusiveReportObject(_bindings, descriptor);
    } on Object {
      _closeIgnoringFailure(_bindings, descriptor);
      rethrow;
    }
  }

  @override
  Future<ExistingReportObject> openExisting(String leaf) async {
    _ensureOpen('open-existing');
    validateReportObjectLeaf(leaf);
    final descriptor = _bindings.withCString(
      leaf,
      (pointer) => _retryInterrupted(
        _bindings,
        () => _bindings.openAtExisting(
          _descriptor,
          pointer,
          _PosixFlags.current.openExisting,
        ),
      ),
    );
    if (descriptor < 0) {
      _throwOpenFailure(_bindings.errno, 'open-existing');
    }
    try {
      final stat = _readStat(_bindings, descriptor, 'open-existing');
      if (!stat.isRegular) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'open-existing',
        );
      }
      return _PosixExistingReportObject(_bindings, descriptor);
    } on Object {
      _closeIgnoringFailure(_bindings, descriptor);
      rethrow;
    }
  }

  @override
  Future<void> verifyReachable() async {
    _ensureOpen('verify-reachable');
    int candidate;
    try {
      candidate = _openDirectory(_bindings, canonicalPath);
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unreachableDirectory,
        operation: 'verify-reachable',
        cause: error,
      );
    }
    try {
      final stat = _readStat(_bindings, candidate, 'verify-reachable');
      _verifyAcceptedFileSystem(_bindings, candidate);
      if (!stat.isDirectory || !stat.identity.sameObjectAs(_identity)) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.unreachableDirectory,
          operation: 'verify-reachable',
        );
      }
    } on ReportObjectBackendException catch (error) {
      if (error.category == ReportObjectBackendFailure.unreachableDirectory) {
        rethrow;
      }
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unreachableDirectory,
        operation: 'verify-reachable',
        cause: error,
      );
    } finally {
      _closeIgnoringFailure(_bindings, candidate);
    }
  }

  @override
  Future<void> close() async {
    final descriptor = _descriptor;
    if (descriptor < 0) return;
    _descriptor = -1;
    if (_bindings.closeDescriptor(descriptor) != 0) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.operationFailed,
        operation: 'close-directory',
        cause: _PosixErrno(_bindings.errno),
      );
    }
  }

  void _ensureOpen(String operation) {
    if (_descriptor < 0) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

abstract base class _PosixObjectCapability {
  _PosixObjectCapability(this._bindings, this._descriptor);

  final PosixBindings _bindings;
  int _descriptor;

  Future<void> rewind() async {
    _ensureOpen('rewind-object');
    final result = _retryInterrupted(
      _bindings,
      () => _bindings.seek(_descriptor, 0, _seekStart),
    );
    if (result != 0) _throwOperation(_bindings, 'rewind-object');
  }

  Future<List<int>> read(int maximumBytes) async {
    _ensureOpen('read-object');
    if (maximumBytes <= 0 || maximumBytes > _maximumReadLength) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'read-object',
      );
    }
    final pointer = _bindings.allocateBytes(maximumBytes);
    try {
      final count = _retryInterrupted(
        _bindings,
        () => _bindings.read(_descriptor, pointer.cast<Void>(), maximumBytes),
      );
      if (count < 0 || count > maximumBytes) {
        _throwOperation(_bindings, 'read-object');
      }
      return pointer.asTypedList(count).toList(growable: false);
    } finally {
      _bindings.release(pointer.cast<Void>());
    }
  }

  Future<ReportObjectIdentity> identity() async {
    _ensureOpen('identify-object');
    final stat = _readStat(_bindings, _descriptor, 'identify-object');
    if (!stat.isRegular) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.invalidObject,
        operation: 'identify-object',
      );
    }
    return stat.identity;
  }

  Future<void> close() async {
    final descriptor = _descriptor;
    if (descriptor < 0) return;
    _descriptor = -1;
    if (_bindings.closeDescriptor(descriptor) != 0) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.operationFailed,
        operation: 'close-object',
        cause: _PosixErrno(_bindings.errno),
      );
    }
  }

  void _ensureOpen(String operation) {
    if (_descriptor < 0) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

final class _PosixExclusiveReportObject extends _PosixObjectCapability
    implements ExclusiveReportObject {
  _PosixExclusiveReportObject(super.bindings, super.descriptor);

  @override
  Future<void> write(List<int> bytes) async {
    _ensureOpen('write-object');
    if (bytes.isEmpty) return;
    final pointer = _bindings.allocateBytes(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      await writeAllReportBytes(bytes.length, (offset, length) async {
        final count = _retryInterrupted(
          _bindings,
          () => _bindings.write(
            _descriptor,
            (pointer + offset).cast<Void>(),
            length,
          ),
        );
        if (count < 0) _throwOperation(_bindings, 'write-object');
        return count;
      });
    } finally {
      _bindings.release(pointer.cast<Void>());
    }
  }

  @override
  Future<void> flush() async {
    _ensureOpen('flush-object');
    final result = _retryInterrupted(
      _bindings,
      () => _bindings.sync(_descriptor),
    );
    if (result != 0) _throwOperation(_bindings, 'flush-object');
  }
}

final class _PosixExistingReportObject extends _PosixObjectCapability
    implements ExistingReportObject {
  _PosixExistingReportObject(super.bindings, super.descriptor);
}

int _openDirectory(PosixBindings bindings, String canonicalPath) {
  final descriptor = bindings.withCString(
    canonicalPath,
    (pointer) => _retryInterrupted(
      bindings,
      () => bindings.openPath(pointer, _PosixFlags.current.openDirectory),
    ),
  );
  if (descriptor < 0) {
    _throwOpenFailure(bindings.errno, 'anchor-directory');
  }
  return descriptor;
}

_PosixStat _readStat(PosixBindings bindings, int descriptor, String operation) {
  final pointer = bindings.allocateBytes(_statBufferLength);
  try {
    pointer.asTypedList(_statBufferLength).fillRange(0, _statBufferLength, 0);
    final result = _retryInterrupted(
      bindings,
      () => bindings.stat(descriptor, pointer.cast<Void>()),
    );
    if (result != 0) _throwOperation(bindings, operation);
    return _PosixStatLayout.current.read(pointer);
  } finally {
    bindings.release(pointer.cast<Void>());
  }
}

void _verifyAcceptedFileSystem(PosixBindings bindings, int descriptor) {
  final pointer = bindings.allocateBytes(_fileSystemBufferLength);
  try {
    pointer
        .asTypedList(_fileSystemBufferLength)
        .fillRange(0, _fileSystemBufferLength, 0);
    final result = _retryInterrupted(
      bindings,
      () => bindings.statFileSystem(descriptor, pointer.cast<Void>()),
    );
    if (result != 0) _throwOperation(bindings, 'identify-filesystem');
    if (!_PosixStatLayout.current.isAcceptedFileSystem(pointer)) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'identify-filesystem',
      );
    }
  } finally {
    bindings.release(pointer.cast<Void>());
  }
}

Never _throwOpenFailure(int errno, String operation, {bool collision = false}) {
  final symbolicLinkLoop = Platform.isMacOS
      ? _macosSymbolicLinkLoop
      : _linuxSymbolicLinkLoop;
  final category = collision && errno == _alreadyExists
      ? ReportObjectBackendFailure.collision
      : errno == _notFound
      ? ReportObjectBackendFailure.notFound
      : errno == symbolicLinkLoop || errno == _notDirectory
      ? ReportObjectBackendFailure.invalidObject
      : ReportObjectBackendFailure.operationFailed;
  throw ReportObjectBackendException(
    category: category,
    operation: operation,
    cause: _PosixErrno(errno),
  );
}

Never _throwOperation(PosixBindings bindings, String operation) {
  throw ReportObjectBackendException(
    category: ReportObjectBackendFailure.operationFailed,
    operation: operation,
    cause: _PosixErrno(bindings.errno),
  );
}

int _retryInterrupted(PosixBindings bindings, int Function() operation) {
  while (true) {
    final result = operation();
    if (result >= 0 || bindings.errno != _interrupted) return result;
  }
}

void _closeIgnoringFailure(PosixBindings bindings, int descriptor) {
  if (descriptor >= 0) bindings.closeDescriptor(descriptor);
}

final class _PosixErrno {
  const _PosixErrno(this.value);

  final int value;
}

final class _PosixFlags {
  const _PosixFlags({
    required this.openDirectory,
    required this.createExclusive,
    required this.openExisting,
  });

  final int openDirectory;
  final int createExclusive;
  final int openExisting;

  static _PosixFlags get current {
    if (Platform.isMacOS) {
      const noFollow = 0x00000100;
      const create = 0x00000200;
      const exclusive = 0x00000800;
      const directory = 0x00100000;
      const closeOnExec = 0x01000000;
      const readWrite = 0x0002;
      return const _PosixFlags(
        openDirectory: directory | closeOnExec | noFollow,
        createExclusive:
            readWrite | create | exclusive | noFollow | closeOnExec,
        openExisting: noFollow | closeOnExec,
      );
    }
    if (Platform.isLinux) {
      const noFollow = 0x20000;
      const create = 0x40;
      const exclusive = 0x80;
      const directory = 0x10000;
      const closeOnExec = 0x80000;
      const readWrite = 0x0002;
      return const _PosixFlags(
        openDirectory: directory | closeOnExec | noFollow,
        createExclusive:
            readWrite | create | exclusive | noFollow | closeOnExec,
        openExisting: noFollow | closeOnExec,
      );
    }
    throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.unsupportedPlatform,
      operation: 'select-posix-flags',
    );
  }
}

final class _PosixStat {
  const _PosixStat({
    required this.device,
    required this.inode,
    required this.mode,
    required this.byteLength,
  });

  final int device;
  final int inode;
  final int mode;
  final int byteLength;

  bool get isDirectory => mode & _modeTypeMask == _modeDirectory;
  bool get isRegular => mode & _modeTypeMask == _modeRegular;

  ReportObjectIdentity get identity => ReportObjectIdentity(
    storageId: 'posix-dev:${device.toUnsigned(64).toRadixString(16)}',
    objectId: 'posix-ino:${inode.toUnsigned(64).toRadixString(16)}',
    byteLength: byteLength,
  );
}

final class _PosixStatLayout {
  const _PosixStatLayout({
    required this.deviceOffset,
    required this.deviceWidth,
    required this.inodeOffset,
    required this.modeOffset,
    required this.modeWidth,
    required this.sizeOffset,
    required this.fileSystemKind,
  });

  final int deviceOffset;
  final int deviceWidth;
  final int inodeOffset;
  final int modeOffset;
  final int modeWidth;
  final int sizeOffset;
  final _PosixFileSystemKind fileSystemKind;

  static _PosixStatLayout get current => switch (Abi.current()) {
    Abi.macosArm64 || Abi.macosX64 => const _PosixStatLayout(
      deviceOffset: 0,
      deviceWidth: 4,
      inodeOffset: 8,
      modeOffset: 4,
      modeWidth: 2,
      sizeOffset: 96,
      fileSystemKind: _PosixFileSystemKind.macos,
    ),
    Abi.linuxX64 => const _PosixStatLayout(
      deviceOffset: 0,
      deviceWidth: 8,
      inodeOffset: 8,
      modeOffset: 24,
      modeWidth: 4,
      sizeOffset: 48,
      fileSystemKind: _PosixFileSystemKind.linux,
    ),
    Abi.linuxArm64 => const _PosixStatLayout(
      deviceOffset: 0,
      deviceWidth: 8,
      inodeOffset: 8,
      modeOffset: 16,
      modeWidth: 4,
      sizeOffset: 48,
      fileSystemKind: _PosixFileSystemKind.linux,
    ),
    _ => throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.unsupportedCapability,
      operation: 'select-posix-abi',
    ),
  };

  _PosixStat read(Pointer<Uint8> pointer) {
    final bytes = pointer.asTypedList(_statBufferLength).buffer.asByteData();
    final device = deviceWidth == 4
        ? bytes.getUint32(deviceOffset, Endian.host)
        : bytes.getUint64(deviceOffset, Endian.host);
    final mode = modeWidth == 2
        ? bytes.getUint16(modeOffset, Endian.host)
        : bytes.getUint32(modeOffset, Endian.host);
    final byteLength = bytes.getInt64(sizeOffset, Endian.host);
    if (byteLength < 0) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.invalidObject,
        operation: 'read-stat',
      );
    }
    return _PosixStat(
      device: device,
      inode: bytes.getUint64(inodeOffset, Endian.host),
      mode: mode,
      byteLength: byteLength,
    );
  }

  bool isAcceptedFileSystem(Pointer<Uint8> pointer) {
    final bytes = pointer
        .asTypedList(_fileSystemBufferLength)
        .buffer
        .asByteData();
    return switch (fileSystemKind) {
      _PosixFileSystemKind.macos =>
        _readFixedCString(pointer, 72, 16) == 'apfs',
      _PosixFileSystemKind.linux =>
        bytes.getUint64(0, Endian.host) == 0xEF53 ||
            bytes.getUint64(0, Endian.host) == 0x01021994,
    };
  }
}

enum _PosixFileSystemKind { macos, linux }

String _readFixedCString(Pointer<Uint8> pointer, int offset, int length) {
  final values = (pointer + offset).asTypedList(length);
  final end = values.indexOf(0);
  return String.fromCharCodes(end < 0 ? values : values.sublist(0, end));
}
