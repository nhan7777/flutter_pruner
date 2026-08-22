import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../report_object_backend.dart';
import 'windows_bindings.dart';

const _maximumReadLength = 16 * 1024 * 1024;
const _statusObjectNameCollision = 0xc0000035;
const _statusObjectNameNotFound = 0xc0000034;
const _statusObjectPathNotFound = 0xc000003a;
const _statusFileIsADirectory = 0xc00000ba;
const _statusObjectTypeMismatch = 0xc0000024;

/// Direct system-DLL immutable report backend for Windows NTFS.
final class WindowsReportObjectBackend implements ReportObjectBackend {
  /// Creates a Windows backend or fails closed on every other platform.
  WindowsReportObjectBackend({
    WindowsReportBindings? bindings,
    String Function(Directory)? canonicalPathResolver,
  }) : _bindings = bindings ?? _loadBindings(),
       _canonicalPathResolver =
           canonicalPathResolver ?? _resolveCanonicalDirectoryPath;

  final WindowsReportBindings _bindings;
  final String Function(Directory) _canonicalPathResolver;

  static WindowsBindings _loadBindings() {
    if (!Platform.isWindows) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedPlatform,
        operation: 'load-windows-backend',
      );
    }
    try {
      return WindowsBindings.open();
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'load-windows-backend',
        cause: error,
      );
    }
  }

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async {
    String canonicalPath;
    try {
      canonicalPath = _canonicalPathResolver(directory);
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.invalidObject,
        operation: 'anchor-directory',
        cause: error,
      );
    }
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(canonicalPath)) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: 'anchor-directory-path',
      );
    }

    final handles = <Pointer<Void>>[];
    try {
      handles.addAll(_openCanonicalDirectoryChain(_bindings, canonicalPath));
      final directoryHandle = handles.last;
      _bindings.verifyNtfs(directoryHandle);
      final identity = _directoryIdentity(_bindings, directoryHandle);
      return _WindowsAnchoredReportDirectory(
        bindings: _bindings,
        canonicalPath: canonicalPath,
        handles: handles,
        identity: identity,
      );
    } on Object {
      _closeHandlesIgnoringFailures(_bindings, handles);
      rethrow;
    }
  }
}

final class _WindowsAnchoredReportDirectory implements AnchoredReportDirectory {
  _WindowsAnchoredReportDirectory({
    required WindowsReportBindings bindings,
    required this.canonicalPath,
    required List<Pointer<Void>> handles,
    required ReportObjectIdentity identity,
  }) : _bindings = bindings,
       _handles = handles,
       _identity = identity;

  final WindowsReportBindings _bindings;
  final List<Pointer<Void>> _handles;
  final ReportObjectIdentity _identity;
  var _closed = false;

  Pointer<Void> get _directoryHandle => _handles.last;

  @override
  final String canonicalPath;

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async {
    _ensureOpen('create-exclusive');
    validateReportObjectLeaf(leaf);
    Pointer<Void> handle;
    try {
      handle = _bindings.openRelative(_directoryHandle, leaf, create: true);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'create-exclusive', collision: true);
    }
    try {
      final identity = _bindings.identity(handle);
      if (identity.isDirectory ||
          identity.isReparsePoint ||
          identity.byteLength != 0) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'create-exclusive',
        );
      }
      return _WindowsExclusiveReportObject(_bindings, handle);
    } on Object {
      _closeHandleIgnoringFailure(_bindings, handle);
      rethrow;
    }
  }

  @override
  Future<ExistingReportObject> openExisting(String leaf) async {
    _ensureOpen('open-existing');
    validateReportObjectLeaf(leaf);
    Pointer<Void> handle;
    try {
      handle = _bindings.openRelative(_directoryHandle, leaf, create: false);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'open-existing');
    }
    try {
      final identity = _bindings.identity(handle);
      if (identity.isDirectory || identity.isReparsePoint) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'open-existing',
        );
      }
      return _WindowsExistingReportObject(_bindings, handle);
    } on Object {
      _closeHandleIgnoringFailure(_bindings, handle);
      rethrow;
    }
  }

  @override
  Future<void> verifyReachable() async {
    _ensureOpen('verify-reachable');
    final candidates = <Pointer<Void>>[];
    try {
      candidates.addAll(_openCanonicalDirectoryChain(_bindings, canonicalPath));
      final candidate = candidates.last;
      _bindings.verifyNtfs(candidate);
      if (!_directoryIdentity(_bindings, candidate).sameObjectAs(_identity)) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.unreachableDirectory,
          operation: 'verify-reachable',
        );
      }
    } on Object catch (error) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unreachableDirectory,
        operation: 'verify-reachable',
        cause: error,
      );
    } finally {
      _closeHandlesIgnoringFailures(_bindings, candidates);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final handle in _handles.reversed) {
      try {
        _bindings.close(handle);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        ReportObjectBackendException(
          category: ReportObjectBackendFailure.operationFailed,
          operation: 'close-directory',
          cause: firstError,
        ),
        firstStackTrace!,
      );
    }
  }

  void _ensureOpen(String operation) {
    if (_closed) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

abstract base class _WindowsObjectCapability {
  _WindowsObjectCapability(this._bindings, this._handle);

  final WindowsReportBindings _bindings;
  final Pointer<Void> _handle;
  var _closed = false;

  Future<void> rewind() async {
    _ensureOpen('rewind-object');
    try {
      _bindings.rewind(_handle);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'rewind-object');
    }
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
      final count = _bindings.read(_handle, pointer.cast<Void>(), maximumBytes);
      if (count < 0 || count > maximumBytes) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.unsupportedCapability,
          operation: 'read-object',
        );
      }
      return pointer.asTypedList(count).toList(growable: false);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'read-object');
    } finally {
      _bindings.release(pointer.cast<Void>());
    }
  }

  Future<ReportObjectIdentity> identity() async {
    _ensureOpen('identify-object');
    try {
      final identity = _bindings.identity(_handle);
      if (identity.isDirectory || identity.isReparsePoint) {
        throw const ReportObjectBackendException(
          category: ReportObjectBackendFailure.invalidObject,
          operation: 'identify-object',
        );
      }
      return _toReportIdentity(identity);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'identify-object');
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _bindings.close(_handle);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'close-object');
    }
  }

  void _ensureOpen(String operation) {
    if (_closed) {
      throw ReportObjectBackendException(
        category: ReportObjectBackendFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

final class _WindowsExclusiveReportObject extends _WindowsObjectCapability
    implements ExclusiveReportObject {
  _WindowsExclusiveReportObject(super.bindings, super.handle);

  @override
  Future<void> write(List<int> bytes) async {
    _ensureOpen('write-object');
    if (bytes.isEmpty) return;
    final pointer = _bindings.allocateBytes(bytes.length);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      await writeAllReportBytes(bytes.length, (offset, length) async {
        try {
          return _bindings.write(
            _handle,
            (pointer + offset).cast<Void>(),
            length,
          );
        } on WindowsNativeFailure catch (error) {
          throw _mapWindowsFailure(error, 'write-object');
        }
      });
    } finally {
      _bindings.release(pointer.cast<Void>());
    }
  }

  @override
  Future<void> flush() async {
    _ensureOpen('flush-object');
    try {
      _bindings.flush(_handle);
    } on WindowsNativeFailure catch (error) {
      throw _mapWindowsFailure(error, 'flush-object');
    }
  }
}

final class _WindowsExistingReportObject extends _WindowsObjectCapability
    implements ExistingReportObject {
  _WindowsExistingReportObject(super.bindings, super.handle);
}

ReportObjectIdentity _directoryIdentity(
  WindowsReportBindings bindings,
  Pointer<Void> handle,
) {
  final identity = bindings.identity(handle);
  if (!identity.isDirectory || identity.isReparsePoint) {
    throw const ReportObjectBackendException(
      category: ReportObjectBackendFailure.invalidObject,
      operation: 'identify-directory',
    );
  }
  return _toReportIdentity(identity);
}

ReportObjectIdentity _toReportIdentity(WindowsHandleIdentityData identity) {
  final fileId = identity.fileId
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
  return ReportObjectIdentity(
    storageId:
        'windows-volume:${identity.volumeSerial.toUnsigned(64).toRadixString(16)}',
    objectId: 'windows-file:$fileId',
    byteLength: identity.byteLength,
  );
}

ReportObjectBackendException _mapWindowsFailure(
  WindowsNativeFailure error,
  String operation, {
  bool collision = false,
}) {
  final isCollision =
      collision &&
      error.ntStatus &&
      (error.code.toUnsigned(32) == _statusObjectNameCollision ||
          error.code.toUnsigned(32) == _statusFileIsADirectory ||
          error.code.toUnsigned(32) == _statusObjectTypeMismatch);
  final status = error.code.toUnsigned(32);
  final isNotFound =
      error.ntStatus &&
      (status == _statusObjectNameNotFound ||
          status == _statusObjectPathNotFound);
  return ReportObjectBackendException(
    category: isCollision
        ? ReportObjectBackendFailure.collision
        : isNotFound
        ? ReportObjectBackendFailure.notFound
        : ReportObjectBackendFailure.operationFailed,
    operation: operation,
    cause: error,
  );
}

String _resolveCanonicalDirectoryPath(Directory directory) =>
    directory.absolute.resolveSymbolicLinksSync();

List<Pointer<Void>> _openCanonicalDirectoryChain(
  WindowsReportBindings bindings,
  String canonicalPath,
) {
  final windows = p.Context(style: p.Style.windows);
  final root = windows.rootPrefix(canonicalPath);
  final relative = windows.relative(canonicalPath, from: root);
  final handles = <Pointer<Void>>[];
  try {
    handles.add(
      _openValidatedWindowsDirectory(bindings, () {
        return bindings.openDirectory(root);
      }),
    );
    if (relative != '.') {
      for (final component in windows.split(relative)) {
        final parent = handles.last;
        handles.add(
          _openValidatedWindowsDirectory(bindings, () {
            return bindings.openRelativeDirectory(parent, component);
          }),
        );
      }
    }
    return handles;
  } on Object {
    _closeHandlesIgnoringFailures(bindings, handles);
    rethrow;
  }
}

Pointer<Void> _openValidatedWindowsDirectory(
  WindowsReportBindings bindings,
  Pointer<Void> Function() open,
) {
  Pointer<Void> handle;
  try {
    handle = open();
  } on WindowsNativeFailure catch (error) {
    throw _mapWindowsFailure(error, 'anchor-directory');
  }
  try {
    final identity = bindings.identity(handle);
    if (!identity.isDirectory || identity.isReparsePoint) {
      throw const ReportObjectBackendException(
        category: ReportObjectBackendFailure.invalidObject,
        operation: 'anchor-directory',
      );
    }
    return handle;
  } on Object {
    _closeHandleIgnoringFailure(bindings, handle);
    rethrow;
  }
}

void _closeHandleIgnoringFailure(
  WindowsReportBindings bindings,
  Pointer<Void> handle,
) {
  try {
    bindings.close(handle);
  } on Object {
    // The earlier capability failure remains primary.
  }
}

void _closeHandlesIgnoringFailures(
  WindowsReportBindings bindings,
  List<Pointer<Void>> handles,
) {
  for (final handle in handles.reversed) {
    _closeHandleIgnoringFailure(bindings, handle);
  }
}
