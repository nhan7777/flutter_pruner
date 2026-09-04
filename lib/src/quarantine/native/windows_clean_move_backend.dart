import 'dart:ffi';
import 'dart:io';

import '../clean_move_backend.dart';
import 'windows_clean_move_bindings.dart';

/// Retained-handle logical clean backend for Windows NTFS.
final class WindowsRecoverableCleanMoveBackend
    implements RecoverableCleanMoveBackend {
  /// Creates a backend with an injectable native boundary.
  WindowsRecoverableCleanMoveBackend({
    WindowsCleanMoveBindings? bindings,
    String Function(Directory)? canonicalPathResolver,
  }) : _bindings = bindings ?? _loadBindings(),
       _canonicalPathResolver =
           canonicalPathResolver ?? _resolveCanonicalDirectoryPath;

  final WindowsCleanMoveBindings _bindings;
  final String Function(Directory) _canonicalPathResolver;

  static WindowsCleanMoveBindings _loadBindings() {
    if (!Platform.isWindows) {
      throw const CleanMoveException(
        category: CleanMoveFailure.unsupportedPlatform,
        operation: 'load-windows-backend',
      );
    }
    try {
      return WindowsSystemCleanMoveBindings.open();
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: 'load-windows-backend',
        cause: error,
      );
    }
  }

  @override
  Future<AnchoredCleanBase> anchor(Directory quarantineBase) async {
    late final String canonicalPath;
    try {
      canonicalPath = _canonicalPathResolver(quarantineBase);
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.invalidObject,
        operation: 'anchor-base',
        cause: error,
      );
    }
    Pointer<Void>? handle;
    try {
      handle = _bindings.openDirectory(canonicalPath);
      _bindings.verifyNtfs(handle);
      final identity = _identity(_bindings, handle, 'anchor-base');
      return _WindowsAnchoredCleanBase(
        bindings: _bindings,
        canonicalPath: canonicalPath,
        handle: handle,
        identity: identity,
      );
    } on CleanMoveException {
      if (handle != null) _closeIgnoringFailure(_bindings, handle);
      rethrow;
    } on Object catch (error) {
      if (handle != null) _closeIgnoringFailure(_bindings, handle);
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: 'anchor-base',
        cause: error,
      );
    }
  }
}

final class _WindowsAnchoredCleanBase implements AnchoredCleanBase {
  _WindowsAnchoredCleanBase({
    required WindowsCleanMoveBindings bindings,
    required this.canonicalPath,
    required Pointer<Void> handle,
    required this.identity,
  }) : _bindings = bindings,
       _handle = handle;

  final WindowsCleanMoveBindings _bindings;
  Pointer<Void> _handle;

  @override
  final String canonicalPath;

  @override
  final CleanObjectIdentity identity;

  bool get _closed => _handle.address == 0;

  @override
  Future<CleanObjectIdentity> inspectDirectory(List<String> components) async {
    _ensureOpen('inspect-directory');
    _validateComponents(components);
    final handles = _openChain(
      components,
      mode: WindowsCleanDirectoryOpenMode.inspect,
    );
    try {
      return _identity(_bindings, handles.last, 'inspect-directory');
    } finally {
      _closeAllIgnoringFailures(_bindings, handles);
    }
  }

  @override
  Future<CleanObjectIdentity> ensureDirectory(List<String> components) async {
    _ensureOpen('ensure-directory');
    _validateComponents(components);
    await _verifyReachable();
    final handles = _openChain(
      components,
      mode: WindowsCleanDirectoryOpenMode.ensureWritable,
    );
    try {
      for (final handle in handles) {
        _flush(_bindings, handle, 'flush-created-directory');
      }
      _flush(_bindings, _handle, 'flush-base');
      return _identity(_bindings, handles.last, 'ensure-directory');
    } finally {
      _closeAllIgnoringFailures(_bindings, handles);
    }
  }

  @override
  Future<CleanObjectIdentity> createDirectoryExclusive(
    List<String> components,
  ) async {
    _ensureOpen('create-directory-exclusive');
    _validateComponents(components);
    await _verifyReachable();
    final parents = _openChain(
      components.take(components.length - 1).toList(growable: false),
      mode: WindowsCleanDirectoryOpenMode.openWritable,
      allowEmpty: true,
    );
    final parent = parents.isEmpty ? _handle : parents.last;
    Pointer<Void>? created;
    try {
      created = _openRelative(
        parent,
        components.last,
        mode: WindowsCleanDirectoryOpenMode.createExclusive,
        operation: 'create-directory-exclusive',
      );
      _flush(_bindings, created, 'flush-exclusive-directory');
      _flush(_bindings, parent, 'flush-exclusive-parent');
      _flush(_bindings, _handle, 'flush-base');
      return _identity(_bindings, created, 'identify-exclusive-directory');
    } finally {
      if (created != null) _closeIgnoringFailure(_bindings, created);
      _closeAllIgnoringFailures(_bindings, parents);
    }
  }

  @override
  Future<void> flushDirectory(List<String> components) async {
    _ensureOpen('flush-directory');
    _validateComponents(components);
    await _verifyReachable();
    final handles = _openChain(
      components,
      mode: WindowsCleanDirectoryOpenMode.openWritable,
    );
    try {
      _flush(_bindings, handles.last, 'flush-directory');
    } finally {
      _closeAllIgnoringFailures(_bindings, handles);
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
    final sourceParents = _openChain(
      source.take(source.length - 1).toList(growable: false),
      mode: WindowsCleanDirectoryOpenMode.openWritable,
      allowEmpty: true,
    );
    final destinationParents = _openChain(
      destination.take(destination.length - 1).toList(growable: false),
      mode: WindowsCleanDirectoryOpenMode.openWritable,
      allowEmpty: true,
    );
    final sourceParent = sourceParents.isEmpty ? _handle : sourceParents.last;
    final destinationParent = destinationParents.isEmpty
        ? _handle
        : destinationParents.last;
    Pointer<Void>? sourceHandle;
    Pointer<Void>? retainedHandle;
    try {
      sourceHandle = _openRelative(
        sourceParent,
        source.last,
        mode: WindowsCleanDirectoryOpenMode.renameSource,
        operation: 'open-source',
      );
      final sourceIdentity = _identity(
        _bindings,
        sourceHandle,
        'identify-source',
      );
      if (!sourceIdentity.sameObjectAs(expectedIdentity)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.identityDrift,
          operation: 'identify-source',
        );
      }
      try {
        _bindings.renameNoReplace(
          sourceHandle,
          destinationParent,
          destination.last,
        );
      } on CleanMoveException {
        rethrow;
      } on Object catch (error) {
        throw CleanMoveException(
          category: CleanMoveFailure.unconfirmedMove,
          operation: 'move-directory',
          cause: error,
        );
      }
      retainedHandle = _openRelative(
        destinationParent,
        destination.last,
        mode: WindowsCleanDirectoryOpenMode.inspect,
        operation: 'open-retained-destination',
      );
      final movedIdentity = _identity(
        _bindings,
        retainedHandle,
        'identify-retained-destination',
      );
      if (!movedIdentity.sameObjectAs(sourceIdentity)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.identityDrift,
          operation: 'verify-moved-identity',
        );
      }
      _flush(_bindings, sourceParent, 'flush-source-parent');
      if (destinationParent != sourceParent) {
        _flush(_bindings, destinationParent, 'flush-destination-parent');
      }
      _flush(_bindings, _handle, 'flush-base');
      return CleanMoveOutcome(movedIdentity: movedIdentity);
    } finally {
      if (retainedHandle != null) {
        _closeIgnoringFailure(_bindings, retainedHandle);
      }
      if (sourceHandle != null) _closeIgnoringFailure(_bindings, sourceHandle);
      _closeAllIgnoringFailures(_bindings, destinationParents);
      _closeAllIgnoringFailures(_bindings, sourceParents);
    }
  }

  @override
  Future<void> flushMetadata() async {
    _ensureOpen('flush-metadata');
    _flush(_bindings, _handle, 'flush-metadata');
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    final handle = _handle;
    _handle = nullptr;
    try {
      _bindings.close(handle);
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.closeFailed,
        operation: 'close-base',
        cause: error,
      );
    }
  }

  List<Pointer<Void>> _openChain(
    List<String> components, {
    required WindowsCleanDirectoryOpenMode mode,
    bool allowEmpty = false,
  }) {
    if (!allowEmpty) _validateComponents(components);
    if (components.isEmpty) return const <Pointer<Void>>[];
    final handles = <Pointer<Void>>[];
    var parent = _handle;
    try {
      for (final component in components) {
        final handle = _openRelative(
          parent,
          component,
          mode: mode,
          operation: mode == WindowsCleanDirectoryOpenMode.ensureWritable
              ? 'ensure-directory'
              : 'open-directory',
        );
        handles.add(handle);
        parent = handle;
      }
      return handles;
    } on Object {
      _closeAllIgnoringFailures(_bindings, handles);
      rethrow;
    }
  }

  Pointer<Void> _openRelative(
    Pointer<Void> parent,
    String component, {
    required WindowsCleanDirectoryOpenMode mode,
    required String operation,
  }) {
    validateCleanPathComponent(component);
    try {
      final handle = _bindings.openRelativeDirectory(
        parent,
        component,
        mode: mode,
      );
      _identity(_bindings, handle, operation);
      return handle;
    } on CleanMoveException {
      rethrow;
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: operation,
        cause: error,
      );
    }
  }

  Future<void> _verifyReachable() async {
    Pointer<Void>? candidate;
    try {
      candidate = _bindings.openDirectory(canonicalPath);
      _bindings.verifyNtfs(candidate);
      final candidateIdentity = _identity(
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
    } on Object catch (error) {
      throw CleanMoveException(
        category: CleanMoveFailure.unreachableBase,
        operation: 'verify-base-reachability',
        cause: error,
      );
    } finally {
      if (candidate != null) _closeIgnoringFailure(_bindings, candidate);
    }
  }

  void _ensureOpen(String operation) {
    if (_closed) {
      throw CleanMoveException(
        category: CleanMoveFailure.unsupportedCapability,
        operation: operation,
      );
    }
  }
}

CleanObjectIdentity _identity(
  WindowsCleanMoveBindings bindings,
  Pointer<Void> handle,
  String operation,
) {
  late final WindowsCleanIdentityData value;
  try {
    value = bindings.identity(handle);
  } on Object catch (error) {
    throw CleanMoveException(
      category: CleanMoveFailure.invalidObject,
      operation: operation,
      cause: error,
    );
  }
  if (!value.isDirectory || value.isReparsePoint) {
    throw CleanMoveException(
      category: CleanMoveFailure.invalidObject,
      operation: operation,
    );
  }
  return CleanObjectIdentity(
    storageId: 'win-volume:${value.volumeSerial.toRadixString(16)}',
    objectId: 'win-file:${value.fileIdHex.toLowerCase()}',
    kind: CleanObjectKind.directory,
  );
}

void _flush(
  WindowsCleanMoveBindings bindings,
  Pointer<Void> handle,
  String operation,
) {
  try {
    bindings.flush(handle);
  } on Object catch (error) {
    throw CleanMoveException(
      category: CleanMoveFailure.flushFailed,
      operation: operation,
      cause: error,
    );
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

void _closeAllIgnoringFailures(
  WindowsCleanMoveBindings bindings,
  Iterable<Pointer<Void>> handles,
) {
  for (final handle in handles.toList(growable: false).reversed) {
    _closeIgnoringFailure(bindings, handle);
  }
}

void _closeIgnoringFailure(
  WindowsCleanMoveBindings bindings,
  Pointer<Void> handle,
) {
  try {
    bindings.close(handle);
  } on Object {
    // The primary failure remains authoritative. Every acquired handle is
    // nevertheless offered to CloseHandle exactly once.
  }
}

String _resolveCanonicalDirectoryPath(Directory directory) {
  final resolved = directory.absolute.resolveSymbolicLinksSync();
  if (!RegExp(r'^[A-Za-z]:\\').hasMatch(resolved)) {
    throw const FormatException('Expected canonical Windows drive path.');
  }
  return resolved;
}
