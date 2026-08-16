import 'dart:convert';
import 'dart:io';

import 'tool_workspace.dart';

/// Exclusive project lock for commands that can mutate source or recovery data.
///
/// The lock file is intentionally retained after release. Deleting a locked
/// file would allow another process to lock a new inode at the same path while
/// the first process still owns the old one.
class ProjectOperationLock {
  ProjectOperationLock._(this._handle);

  final RandomAccessFile _handle;
  var _released = false;

  /// Acquires a non-blocking exclusive lock for [operation].
  ///
  /// A competing process fails closed instead of waiting while project bytes
  /// or quarantine authority may be changing.
  static Future<ProjectOperationLock> acquire({
    required ToolWorkspace workspace,
    required String operation,
  }) async {
    workspace.validateManagedLayout();
    await workspace.directory.create(recursive: true);
    final lockFile = workspace.operationLockFile;
    final RandomAccessFile handle;
    try {
      // Append mode creates the file without truncating the current owner's
      // diagnostic metadata before this process has acquired the OS lock.
      handle = await lockFile.open(mode: FileMode.append);
    } on FileSystemException catch (error) {
      throw ProjectOperationLockException(
        'Could not open the Flutter Pruner operation lock for '
        '${workspace.projectRoot.path}.',
        cause: error,
      );
    }
    try {
      await handle.lock(FileLock.exclusive);
    } on FileSystemException catch (error) {
      await handle.close();
      final owner = await _readOwner(lockFile);
      throw ProjectOperationLockException(
        'Another Flutter Pruner mutation is already active for '
        '${workspace.projectRoot.path}${owner == null ? '' : ': $owner'}.',
        cause: error,
      );
    }

    try {
      await handle.setPosition(0);
      await handle.truncate(0);
      await handle.writeString(
        jsonEncode({
          'pid': pid,
          'operation': operation,
          'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
          'projectRoot': workspace.projectRoot.path,
        }),
      );
      await handle.flush();
      return ProjectOperationLock._(handle);
    } catch (error) {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
      throw ProjectOperationLockException(
        'Could not record the Flutter Pruner operation lock for '
        '${workspace.projectRoot.path}.',
        cause: error,
      );
    }
  }

  /// Releases this lock. Repeated calls are harmless.
  Future<void> release() async {
    if (_released) return;
    _released = true;
    try {
      await _handle.unlock();
    } finally {
      await _handle.close();
    }
  }

  static Future<String?> _readOwner(File lockFile) async {
    try {
      final contents = await lockFile.readAsString();
      if (contents.trim().isEmpty) return null;
      final value = jsonDecode(contents);
      if (value is! Map<String, dynamic>) return null;
      final operation = value['operation'];
      final ownerPid = value['pid'];
      final startedAt = value['startedAtUtc'];
      return 'operation=$operation, pid=$ownerPid, startedAtUtc=$startedAt';
    } catch (_) {
      return null;
    }
  }
}

/// A project mutation lock could not be acquired or maintained.
class ProjectOperationLockException implements Exception {
  /// Creates an operation-lock failure with an optional underlying [cause].
  const ProjectOperationLockException(this.message, {this.cause});

  /// Actionable failure text.
  final String message;

  /// Underlying filesystem failure, when available.
  final Object? cause;

  @override
  String toString() => message;
}
