import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../clean_move_backend.dart';
import 'posix_clean_move_bindings.dart';

const _interrupted = 4;
const _notFound = 2;
const _alreadyExists = 17;
const _crossDevice = 18;
const _notDirectory = 20;
const _linuxSymbolicLinkLoop = 40;
const _macosSymbolicLinkLoop = 62;
const _modeTypeMask = 0xF000;
const _modeDirectory = 0x4000;
const _statBufferLength = 256;
const _directoryMode = 0x1c0;

/// Retained-descriptor logical clean backend for Linux and macOS.
final class PosixRecoverableCleanMoveBackend
    implements RecoverableCleanMoveBackend {
  /// Creates a backend backed by the host system C library.
  PosixRecoverableCleanMoveBackend({PosixCleanMoveBindings? bindings})
    : _bindings = bindings ?? _loadBindings();

  final PosixCleanMoveBindings _bindings;

  static PosixCleanMoveBindings _loadBindings() {
    if (!Platform.isLinux && !Platform.isMacOS) {
      throw const CleanMoveException(
        category: CleanMoveFailure.unsupportedPlatform,
        operation: 'load-posix-backend',
      );
    }
    try {
      _PosixCleanStatLayout.current;
      return PosixCleanMoveBindings.open();
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: 'load-posix-backend',
        cause: error,
      );
    }
  }

  @override
  Future<AnchoredCleanBase> anchor(Directory quarantineBase) async {
    final rawType = FileSystemEntity.typeSync(
      quarantineBase.absolute.path,
      followLinks: false,
    );
    if (rawType != FileSystemEntityType.directory) {
      throw const CleanMoveException(
        category: CleanMoveFailure.invalidObject,
        operation: 'anchor-base',
      );
    }
    late final String canonicalPath;
    try {
      canonicalPath = quarantineBase.absolute.resolveSymbolicLinksSync();
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.invalidObject,
        operation: 'anchor-base',
        cause: error,
      );
    }
    final descriptor = _openAbsoluteDirectory(_bindings, canonicalPath);
    try {
      final stat = _readStat(_bindings, descriptor, 'anchor-base');
      if (!stat.isDirectory) {
        throw const CleanMoveException(
          category: CleanMoveFailure.invalidObject,
          operation: 'anchor-base',
        );
      }
      return _PosixAnchoredCleanBase(
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

final class _PosixAnchoredCleanBase implements AnchoredCleanBase {
  _PosixAnchoredCleanBase({
    required PosixCleanMoveBindings bindings,
    required this.canonicalPath,
    required int descriptor,
    required this.identity,
  }) : _bindings = bindings,
       _descriptor = descriptor;

  final PosixCleanMoveBindings _bindings;
  int _descriptor;

  @override
  final String canonicalPath;

  @override
  final CleanObjectIdentity identity;

  @override
  Future<CleanObjectIdentity> inspectDirectory(List<String> components) async {
    _ensureOpen('inspect-directory');
    _validateComponents(components);
    final descriptors = _openDirectoryChain(components, create: false);
    try {
      return _readDirectoryIdentity(
        _bindings,
        descriptors.last,
        'inspect-directory',
      );
    } finally {
      _closeAllIgnoringFailure(_bindings, descriptors);
    }
  }

  @override
  Future<CleanObjectIdentity> ensureDirectory(List<String> components) async {
    _ensureOpen('ensure-directory');
    _validateComponents(components);
    await _verifyReachable();
    final descriptors = _openDirectoryChain(components, create: true);
    try {
      for (final descriptor in descriptors) {
        _syncOrThrow(_bindings, descriptor, 'flush-created-directory');
      }
      _syncOrThrow(_bindings, _descriptor, 'flush-base');
      return _readDirectoryIdentity(
        _bindings,
        descriptors.last,
        'ensure-directory',
      );
    } finally {
      _closeAllIgnoringFailure(_bindings, descriptors);
    }
  }

  @override
  Future<CleanObjectIdentity> createDirectoryExclusive(
    List<String> components,
  ) async {
    _ensureOpen('create-directory-exclusive');
    _validateComponents(components);
    await _verifyReachable();
    final parents = _openDirectoryChain(
      components.take(components.length - 1).toList(growable: false),
      create: false,
      allowEmpty: true,
    );
    final parent = parents.isEmpty ? _descriptor : parents.last;
    var created = -1;
    try {
      final result = _bindings.withCString(
        components.last,
        (pointer) => _retryInterrupted(
          _bindings,
          () => _bindings.mkdirAt(parent, pointer, _directoryMode),
        ),
      );
      if (result != 0) {
        if (_bindings.errno == _alreadyExists) {
          throw const CleanMoveException(
            category: CleanMoveFailure.collision,
            operation: 'create-directory-exclusive',
          );
        }
        _throwOpenFailure(_bindings.errno, 'create-directory-exclusive');
      }
      created = _openRelativeDirectory(
        _bindings,
        parent,
        components.last,
        operation: 'open-exclusive-directory',
      );
      _syncOrThrow(_bindings, created, 'flush-exclusive-directory');
      _syncOrThrow(_bindings, parent, 'flush-exclusive-parent');
      _syncOrThrow(_bindings, _descriptor, 'flush-base');
      return _readDirectoryIdentity(
        _bindings,
        created,
        'identify-exclusive-directory',
      );
    } finally {
      _closeIgnoringFailure(_bindings, created);
      _closeAllIgnoringFailure(_bindings, parents);
    }
  }

  @override
  Future<void> flushDirectory(List<String> components) async {
    _ensureOpen('flush-directory');
    _validateComponents(components);
    await _verifyReachable();
    final descriptors = _openDirectoryChain(components, create: false);
    try {
      _syncOrThrow(_bindings, descriptors.last, 'flush-directory');
    } finally {
      _closeAllIgnoringFailure(_bindings, descriptors);
    }
  }

  @override
  Future<CleanMoveOutcome> moveDirectoryNoReplace({
    required List<String> source,
    required List<String> destination,
    required CleanObjectIdentity expectedIdentity,
  }) async {
    _ensureOpen('move-directory');
    _validateComponents(source);
    _validateComponents(destination);
    await _verifyReachable();

    final sourceParents = _openDirectoryChain(
      source.take(source.length - 1).toList(growable: false),
      create: false,
      allowEmpty: true,
    );
    final destinationParents = _openDirectoryChain(
      destination.take(destination.length - 1).toList(growable: false),
      create: false,
      allowEmpty: true,
    );
    final sourceParent = sourceParents.isEmpty
        ? _descriptor
        : sourceParents.last;
    final destinationParent = destinationParents.isEmpty
        ? _descriptor
        : destinationParents.last;
    var sourceDescriptor = -1;
    var destinationDescriptor = -1;
    try {
      sourceDescriptor = _openRelativeDirectory(
        _bindings,
        sourceParent,
        source.last,
        operation: 'open-source',
      );
      final sourceIdentity = _readDirectoryIdentity(
        _bindings,
        sourceDescriptor,
        'identify-source',
      );
      if (!sourceIdentity.sameObjectAs(expectedIdentity)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.identityDrift,
          operation: 'identify-source',
        );
      }

      final result = _bindings.withCString(
        source.last,
        (sourcePointer) => _bindings.withCString(
          destination.last,
          (destinationPointer) => _bindings.renameAtNoReplace(
            sourceParent,
            sourcePointer,
            destinationParent,
            destinationPointer,
            _renameNoReplaceFlags,
          ),
        ),
      );
      if (result != 0) {
        _throwRenameFailure(_bindings.errno);
      }

      destinationDescriptor = _openRelativeDirectory(
        _bindings,
        destinationParent,
        destination.last,
        operation: 'open-retained-destination',
      );
      final movedIdentity = _readDirectoryIdentity(
        _bindings,
        destinationDescriptor,
        'identify-retained-destination',
      );
      if (!movedIdentity.sameObjectAs(sourceIdentity)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.identityDrift,
          operation: 'verify-moved-identity',
        );
      }
      _syncOrThrow(_bindings, sourceParent, 'flush-source-parent');
      if (destinationParent != sourceParent) {
        _syncOrThrow(_bindings, destinationParent, 'flush-destination-parent');
      }
      _syncOrThrow(_bindings, _descriptor, 'flush-base');
      return CleanMoveOutcome(movedIdentity: movedIdentity);
    } finally {
      _closeIgnoringFailure(_bindings, destinationDescriptor);
      _closeIgnoringFailure(_bindings, sourceDescriptor);
      _closeAllIgnoringFailure(_bindings, destinationParents);
      _closeAllIgnoringFailure(_bindings, sourceParents);
    }
  }

  @override
  Future<void> flushMetadata() async {
    _ensureOpen('flush-metadata');
    _syncOrThrow(_bindings, _descriptor, 'flush-metadata');
  }

  @override
  Future<void> close() async {
    final descriptor = _descriptor;
    if (descriptor < 0) return;
    _descriptor = -1;
    if (_bindings.close(descriptor) != 0) {
      throw CleanMoveException(
        category: CleanMoveFailure.closeFailed,
        operation: 'close-base',
        cause: _PosixCleanErrno(_bindings.errno),
      );
    }
  }

  List<int> _openDirectoryChain(
    List<String> components, {
    required bool create,
    bool allowEmpty = false,
  }) {
    if (!allowEmpty) _validateComponents(components);
    if (components.isEmpty) return const <int>[];
    final opened = <int>[];
    var parent = _descriptor;
    try {
      for (final component in components) {
        if (create) {
          final createResult = _bindings.withCString(
            component,
            (pointer) => _retryInterrupted(
              _bindings,
              () => _bindings.mkdirAt(parent, pointer, _directoryMode),
            ),
          );
          if (createResult != 0 && _bindings.errno != _alreadyExists) {
            _throwOpenFailure(_bindings.errno, 'create-directory');
          }
        }
        final descriptor = _openRelativeDirectory(
          _bindings,
          parent,
          component,
          operation: create ? 'open-created-directory' : 'open-directory',
        );
        opened.add(descriptor);
        parent = descriptor;
      }
      return opened;
    } on Object {
      _closeAllIgnoringFailure(_bindings, opened);
      rethrow;
    }
  }

  Future<void> _verifyReachable() async {
    var candidate = -1;
    try {
      candidate = _openAbsoluteDirectory(_bindings, canonicalPath);
      final candidateIdentity = _readDirectoryIdentity(
        _bindings,
        candidate,
        'verify-base-reachability',
      );
      if (!candidateIdentity.sameObjectAs(identity)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.unreachableBase,
          operation: 'verify-base-reachability',
        );
      }
    } on CleanMoveException catch (error) {
      if (error.category == CleanMoveFailure.unreachableBase) rethrow;
      throw CleanMoveException(
        category: CleanMoveFailure.unreachableBase,
        operation: 'verify-base-reachability',
        cause: error,
      );
    } finally {
      _closeIgnoringFailure(_bindings, candidate);
    }
  }

  void _ensureOpen(String operation) {
    if (_descriptor < 0) {
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

int get _renameNoReplaceFlags =>
    Platform.isMacOS ? 0x00000004 | 0x00000010 | 0x00000020 : 0x00000001;

int _openAbsoluteDirectory(
  PosixCleanMoveBindings bindings,
  String canonicalPath,
) {
  final descriptor = bindings.withCString(
    canonicalPath,
    (pointer) => _retryInterrupted(
      bindings,
      () => bindings.openPath(pointer, _PosixCleanFlags.current.openDirectory),
    ),
  );
  if (descriptor < 0) {
    _throwOpenFailure(bindings.errno, 'anchor-base');
  }
  return descriptor;
}

int _openRelativeDirectory(
  PosixCleanMoveBindings bindings,
  int parent,
  String component, {
  required String operation,
}) {
  validateCleanPathComponent(component);
  final descriptor = bindings.withCString(
    component,
    (pointer) => _retryInterrupted(
      bindings,
      () => bindings.openAt(
        parent,
        pointer,
        _PosixCleanFlags.current.openDirectory,
      ),
    ),
  );
  if (descriptor < 0) _throwOpenFailure(bindings.errno, operation);
  final stat = _readStat(bindings, descriptor, operation);
  if (!stat.isDirectory) {
    _closeIgnoringFailure(bindings, descriptor);
    throw CleanMoveException(
      category: CleanMoveFailure.invalidObject,
      operation: operation,
    );
  }
  return descriptor;
}

CleanObjectIdentity _readDirectoryIdentity(
  PosixCleanMoveBindings bindings,
  int descriptor,
  String operation,
) {
  final stat = _readStat(bindings, descriptor, operation);
  if (!stat.isDirectory) {
    throw CleanMoveException(
      category: CleanMoveFailure.invalidObject,
      operation: operation,
    );
  }
  return stat.identity;
}

_PosixCleanStat _readStat(
  PosixCleanMoveBindings bindings,
  int descriptor,
  String operation,
) {
  final pointer = bindings.allocateBytes(_statBufferLength);
  try {
    pointer.asTypedList(_statBufferLength).fillRange(0, _statBufferLength, 0);
    final result = _retryInterrupted(
      bindings,
      () => bindings.stat(descriptor, pointer.cast<Void>()),
    );
    if (result != 0) {
      throw CleanMoveException(
        category: CleanMoveFailure.invalidObject,
        operation: operation,
        cause: _PosixCleanErrno(bindings.errno),
      );
    }
    return _PosixCleanStatLayout.current.read(pointer);
  } finally {
    bindings.release(pointer.cast<Void>());
  }
}

void _syncOrThrow(
  PosixCleanMoveBindings bindings,
  int descriptor,
  String operation,
) {
  final result = _retryInterrupted(bindings, () => bindings.sync(descriptor));
  if (result != 0) {
    throw CleanMoveException(
      category: CleanMoveFailure.flushFailed,
      operation: operation,
      cause: _PosixCleanErrno(bindings.errno),
    );
  }
}

Never _throwOpenFailure(int errno, String operation) {
  final symbolicLinkLoop = Platform.isMacOS
      ? _macosSymbolicLinkLoop
      : _linuxSymbolicLinkLoop;
  final category = errno == _notFound
      ? CleanMoveFailure.notFound
      : errno == symbolicLinkLoop || errno == _notDirectory
      ? CleanMoveFailure.invalidObject
      : errno == _crossDevice
      ? CleanMoveFailure.unsupportedCapability
      : CleanMoveFailure.unsupportedCapability;
  throw CleanMoveException(
    category: category,
    operation: operation,
    cause: _PosixCleanErrno(errno),
  );
}

Never _throwRenameFailure(int errno) {
  final symbolicLinkLoop = Platform.isMacOS
      ? _macosSymbolicLinkLoop
      : _linuxSymbolicLinkLoop;
  final category = errno == _alreadyExists
      ? CleanMoveFailure.collision
      : errno == _notFound
      ? CleanMoveFailure.notFound
      : errno == symbolicLinkLoop || errno == _notDirectory
      ? CleanMoveFailure.invalidObject
      : errno == _crossDevice
      ? CleanMoveFailure.unsupportedCapability
      : CleanMoveFailure.unconfirmedMove;
  throw CleanMoveException(
    category: category,
    operation: 'move-directory',
    cause: _PosixCleanErrno(errno),
  );
}

int _retryInterrupted(
  PosixCleanMoveBindings bindings,
  int Function() operation,
) {
  while (true) {
    final result = operation();
    if (result >= 0 || bindings.errno != _interrupted) return result;
  }
}

void _validateComponents(List<String> components) {
  if (components.isEmpty) {
    throw const CleanMoveException(
      category: CleanMoveFailure.invalidComponent,
      operation: 'validate-components',
    );
  }
  for (final component in components) {
    validateCleanPathComponent(component);
  }
}

void _closeAllIgnoringFailure(
  PosixCleanMoveBindings bindings,
  Iterable<int> descriptors,
) {
  for (final descriptor in descriptors.toList(growable: false).reversed) {
    _closeIgnoringFailure(bindings, descriptor);
  }
}

void _closeIgnoringFailure(PosixCleanMoveBindings bindings, int descriptor) {
  if (descriptor >= 0) bindings.close(descriptor);
}

final class _PosixCleanErrno {
  const _PosixCleanErrno(this.value);

  final int value;
}

final class _PosixCleanFlags {
  const _PosixCleanFlags({required this.openDirectory});

  final int openDirectory;

  static _PosixCleanFlags get current {
    if (Platform.isMacOS) {
      const noFollow = 0x00000100;
      const directory = 0x00100000;
      const closeOnExec = 0x01000000;
      return const _PosixCleanFlags(
        openDirectory: directory | closeOnExec | noFollow,
      );
    }
    if (Platform.isLinux) {
      const noFollow = 0x20000;
      const directory = 0x10000;
      const closeOnExec = 0x80000;
      return const _PosixCleanFlags(
        openDirectory: directory | closeOnExec | noFollow,
      );
    }
    throw const CleanMoveException(
      category: CleanMoveFailure.unsupportedPlatform,
      operation: 'select-posix-flags',
    );
  }
}

final class _PosixCleanStat {
  const _PosixCleanStat({
    required this.device,
    required this.inode,
    required this.mode,
  });

  final int device;
  final int inode;
  final int mode;

  bool get isDirectory => mode & _modeTypeMask == _modeDirectory;

  CleanObjectIdentity get identity => CleanObjectIdentity(
    storageId: 'posix-dev:${device.toUnsigned(64).toRadixString(16)}',
    objectId: 'posix-ino:${inode.toUnsigned(64).toRadixString(16)}',
    kind: CleanObjectKind.directory,
  );
}

final class _PosixCleanStatLayout {
  const _PosixCleanStatLayout({
    required this.deviceOffset,
    required this.deviceWidth,
    required this.inodeOffset,
    required this.modeOffset,
    required this.modeWidth,
  });

  final int deviceOffset;
  final int deviceWidth;
  final int inodeOffset;
  final int modeOffset;
  final int modeWidth;

  static _PosixCleanStatLayout get current => switch (Abi.current()) {
    Abi.macosArm64 || Abi.macosX64 => const _PosixCleanStatLayout(
      deviceOffset: 0,
      deviceWidth: 4,
      inodeOffset: 8,
      modeOffset: 4,
      modeWidth: 2,
    ),
    Abi.linuxX64 => const _PosixCleanStatLayout(
      deviceOffset: 0,
      deviceWidth: 8,
      inodeOffset: 8,
      modeOffset: 24,
      modeWidth: 4,
    ),
    Abi.linuxArm64 => const _PosixCleanStatLayout(
      deviceOffset: 0,
      deviceWidth: 8,
      inodeOffset: 8,
      modeOffset: 16,
      modeWidth: 4,
    ),
    _ => throw const CleanMoveException(
      category: CleanMoveFailure.unsupportedCapability,
      operation: 'select-posix-abi',
    ),
  };

  _PosixCleanStat read(Pointer<Uint8> pointer) {
    final bytes = pointer.asTypedList(_statBufferLength).buffer.asByteData();
    final device = deviceWidth == 4
        ? bytes.getUint32(deviceOffset, Endian.host)
        : bytes.getUint64(deviceOffset, Endian.host);
    final mode = modeWidth == 2
        ? bytes.getUint16(modeOffset, Endian.host)
        : bytes.getUint32(modeOffset, Endian.host);
    return _PosixCleanStat(
      device: device,
      inode: bytes.getUint64(inodeOffset, Endian.host),
      mode: mode,
    );
  }
}
