import 'dart:ffi';

import '../../reporting/native/windows_bindings.dart';
import '../clean_move_backend.dart';
import 'windows_clean_open_mode.dart';

export 'windows_clean_open_mode.dart' show WindowsCleanDirectoryOpenMode;

const _statusObjectNameCollision = 0xc0000035;
const _statusObjectNameNotFound = 0xc0000034;
const _statusObjectPathNotFound = 0xc000003a;

/// Stable identity and type evidence read from a retained Windows handle.
final class WindowsCleanIdentityData {
  /// Creates one native identity observation.
  const WindowsCleanIdentityData({
    required this.volumeSerial,
    required this.fileIdHex,
    required this.isDirectory,
    required this.isReparsePoint,
  });

  /// Volume identity reported by Windows.
  final int volumeSerial;

  /// Full file ID encoded as lowercase hexadecimal.
  final String fileIdHex;

  /// Whether the handle identifies a directory.
  final bool isDirectory;

  /// Whether the object is a reparse point.
  final bool isReparsePoint;
}

/// Injectable Windows primitive boundary for recoverable logical clean.
abstract interface class WindowsCleanMoveBindings {
  /// Opens one canonical directory without following its final reparse point.
  Pointer<Void> openDirectory(String path);

  /// Opens or creates one child directory relative to [parent] with [mode].
  Pointer<Void> openRelativeDirectory(
    Pointer<Void> parent,
    String leaf, {
    required WindowsCleanDirectoryOpenMode mode,
  });

  /// Reads stable file identity and reparse state through [handle].
  WindowsCleanIdentityData identity(Pointer<Void> handle);

  /// Renames the exact open [source] into an absent destination leaf.
  void renameNoReplace(
    Pointer<Void> source,
    Pointer<Void> destinationParent,
    String destinationLeaf,
  );

  /// Fails unless [handle] belongs to an accepted NTFS volume.
  void verifyNtfs(Pointer<Void> handle);

  /// Flushes object or directory metadata through [handle].
  void flush(Pointer<Void> handle);

  /// Closes one acquired handle exactly once.
  void close(Pointer<Void> handle);
}

/// System adapter for handle-bound, no-replace Windows clean mutation.
final class WindowsSystemCleanMoveBindings implements WindowsCleanMoveBindings {
  WindowsSystemCleanMoveBindings._(this._delegate);

  /// Loads Windows system bindings.
  factory WindowsSystemCleanMoveBindings.open() =>
      WindowsSystemCleanMoveBindings._(WindowsBindings.open());

  final WindowsBindings _delegate;

  @override
  Pointer<Void> openDirectory(String path) =>
      _delegate.openDirectoryForClean(path);

  @override
  Pointer<Void> openRelativeDirectory(
    Pointer<Void> parent,
    String leaf, {
    required WindowsCleanDirectoryOpenMode mode,
  }) {
    try {
      return _delegate.openRelativeDirectoryForClean(parent, leaf, mode: mode);
    } on WindowsNativeFailure catch (error) {
      final status = error.code.toUnsigned(32);
      if (error.ntStatus &&
          (status == _statusObjectNameNotFound ||
              status == _statusObjectPathNotFound)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.notFound,
          operation: 'open-directory-relative',
        );
      }
      if (mode == WindowsCleanDirectoryOpenMode.createExclusive &&
          error.ntStatus &&
          status == _statusObjectNameCollision) {
        throw const CleanMoveException(
          category: CleanMoveFailure.collision,
          operation: 'create-directory-exclusive',
        );
      }
      rethrow;
    }
  }

  @override
  WindowsCleanIdentityData identity(Pointer<Void> handle) {
    final value = _delegate.identity(handle);
    return WindowsCleanIdentityData(
      volumeSerial: value.volumeSerial,
      fileIdHex: value.fileId
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join(),
      isDirectory: value.isDirectory,
      isReparsePoint: value.isReparsePoint,
    );
  }

  @override
  void renameNoReplace(
    Pointer<Void> source,
    Pointer<Void> destinationParent,
    String destinationLeaf,
  ) {
    try {
      _delegate.renameDirectoryNoReplace(
        source,
        destinationParent,
        destinationLeaf,
      );
    } on WindowsNativeFailure catch (error) {
      if (error.code == 80 ||
          error.code == 183 ||
          (error.ntStatus &&
              error.code.toUnsigned(32) == _statusObjectNameCollision)) {
        throw const CleanMoveException(
          category: CleanMoveFailure.collision,
          operation: 'move-directory',
        );
      }
      throw CleanMoveException(
        category: CleanMoveFailure.unconfirmedMove,
        operation: 'move-directory',
        cause: error,
      );
    }
  }

  @override
  void verifyNtfs(Pointer<Void> handle) => _delegate.verifyNtfs(handle);

  @override
  void flush(Pointer<Void> handle) => _delegate.flush(handle);

  @override
  void close(Pointer<Void> handle) => _delegate.close(handle);
}
