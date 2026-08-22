import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Writes a report's text tokens to [sink].
typedef ReportSinkCallback = void Function(StringSink sink);

/// The stable transaction phase in which report persistence failed.
enum ReportPersistencePhase {
  /// Resolving the requested destination to a canonical identity.
  resolveDestination,

  /// Discovering parents or transaction artifacts.
  discovery,

  /// Exclusively creating the stable destination lock.
  lock,

  /// Writing and rereading the complete lock owner token.
  writeLockOwner,

  /// Opening the same-directory temporary report.
  open,

  /// Writing report tokens to the temporary report.
  write,

  /// Flushing the temporary report.
  flush,

  /// Closing the temporary report.
  close,

  /// Moving the previous destination to its stable backup.
  movePrevious,

  /// Promoting the complete temporary report to the destination.
  promote,

  /// Restoring the previous destination before the promotion commit point.
  restore,

  /// Deleting the previous destination after committed promotion.
  deletePrevious,

  /// Comparing and deleting this writer's stable lock.
  releaseLock,

  /// Cleaning an uncommitted temporary report or unexpected residue.
  cleanup,
}

/// Base type for stable, content-sanitized report persistence failures.
sealed class ReportPersistenceException implements Exception {
  /// Creates a persistence failure for [phase].
  const ReportPersistenceException({
    required this.phase,
    required this.requestedDestination,
    required this.canonicalDestination,
    required this.artifacts,
    this.cause,
  });

  /// Transaction phase that failed.
  final ReportPersistencePhase phase;

  /// Absolute path requested by the caller, retained for user context.
  final String requestedDestination;

  /// Frozen canonical transaction path, or `null` when resolution failed.
  final String? canonicalDestination;

  /// Surviving canonical paths that require inspection or cleanup.
  final List<String> artifacts;

  /// Underlying failure, omitted from diagnostic text except for its category.
  final Object? cause;

  String get _summary => switch (this) {
    ReportPersistenceFailure() => 'Report persistence failed',
    ReportPersistenceRecoveryRequiredException() =>
      'Report persistence recovery required',
    ReportPersistenceCommittedCleanupRequiredException() =>
      'Report saved but persistence cleanup is required',
  };

  /// Returns stable diagnostics without including report contents or cause text.
  @override
  String toString() {
    final sortedArtifacts = artifacts.toList()..sort();
    final canonical = canonicalDestination == null
        ? '<unresolved>'
        : jsonEncode(canonicalDestination);
    return '$_summary; phase=${phase.name}; '
        'requested=${jsonEncode(requestedDestination)}; '
        'canonical=$canonical; artifacts=${jsonEncode(sortedArtifacts)}; '
        'cause=${_causeCategory(cause)}';
  }
}

/// A report was not committed and no recovery artifact remains.
final class ReportPersistenceFailure extends ReportPersistenceException {
  /// Creates a cleanly contained persistence failure.
  const ReportPersistenceFailure({
    required super.phase,
    required super.requestedDestination,
    required super.canonicalDestination,
    required super.artifacts,
    super.cause,
  });
}

/// A report was not committed and surviving artifacts require recovery.
final class ReportPersistenceRecoveryRequiredException
    extends ReportPersistenceException {
  /// Creates a pre-commit recovery-required failure.
  const ReportPersistenceRecoveryRequiredException({
    required super.phase,
    required super.requestedDestination,
    required super.canonicalDestination,
    required super.artifacts,
    super.cause,
  });
}

/// A complete report was committed but transaction cleanup remains.
final class ReportPersistenceCommittedCleanupRequiredException
    extends ReportPersistenceException {
  /// Creates a post-commit cleanup-required failure.
  const ReportPersistenceCommittedCleanupRequiredException({
    required super.phase,
    required super.requestedDestination,
    required super.canonicalDestination,
    required super.artifacts,
    super.cause,
  });
}

/// Frozen requested and canonical identities for one report destination.
final class ResolvedReportDestination {
  /// Creates a resolved destination identity.
  const ResolvedReportDestination({
    required this.requestedPath,
    required this.canonicalPath,
  });

  /// Absolute normalized path originally requested by the caller.
  final String requestedPath;

  /// Absolute canonical path used for every transaction operation.
  final String canonicalPath;
}

/// Injectable filesystem operations used by [RecoverableReportWriter].
abstract interface class ReportFileOperations {
  /// Resolves [requestedPath] without mutating the filesystem.
  Future<ResolvedReportDestination> resolveDestination(String requestedPath);

  /// Creates the canonical destination's parent directories.
  Future<void> createParent(String destination);

  /// Creates [path] atomically and fails when any entity already exists there.
  Future<void> createExclusive(String path);

  /// Writes, flushes, closes, rereads, and confirms [ownerToken] at [path].
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken);

  /// Returns whether any filesystem entity exists at [path] without following it.
  Future<bool> exists(String path);

  /// Renames [from] to [to] in the same directory.
  Future<void> rename(String from, String to);

  /// Deletes the file or link at [path].
  Future<void> delete(String path);

  /// Deletes [path] only when its complete contents equal [ownerToken].
  Future<bool> deleteOwnedLock(String path, String ownerToken);

  /// Lists every matching temporary file and stable previous-file artifact.
  ///
  /// The stable lock is deliberately excluded so a writer's confirmed lock is
  /// not mistaken for a stale artifact during the post-lock discovery pass.
  Future<List<String>> transactionArtifactsFor(String destination);
}

/// A string sink whose buffered bytes can be flushed and closed explicitly.
abstract interface class ReportOutputSink implements StringSink {
  /// Flushes every accepted token to the temporary file.
  Future<void> flush();

  /// Closes the temporary file sink.
  Future<void> close();
}

/// Opens a [ReportOutputSink] at a canonical same-directory temporary path.
typedef ReportSinkFactory = Future<ReportOutputSink> Function(String path);

/// Production [dart:io] implementation of report transaction operations.
final class IoReportFileOperations implements ReportFileOperations {
  /// Creates stateless production file operations.
  const IoReportFileOperations();

  @override
  Future<ResolvedReportDestination> resolveDestination(
    String requestedPath,
  ) async {
    final requested = p.normalize(p.absolute(requestedPath));
    final requestedType = FileSystemEntity.typeSync(
      requested,
      followLinks: false,
    );
    if (requestedType == FileSystemEntityType.file ||
        requestedType == FileSystemEntityType.link) {
      final canonical = p.normalize(File(requested).resolveSymbolicLinksSync());
      if (FileSystemEntity.typeSync(canonical, followLinks: false) !=
          FileSystemEntityType.file) {
        throw FileSystemException(
          'Report destination does not resolve to a regular file.',
          requested,
        );
      }
      return ResolvedReportDestination(
        requestedPath: requested,
        canonicalPath: canonical,
      );
    }
    if (requestedType != FileSystemEntityType.notFound) {
      throw FileSystemException(
        'Report destination is not a regular file.',
        requested,
      );
    }

    var existing = requested;
    final missingSegments = <String>[];
    while (FileSystemEntity.typeSync(existing, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final parent = p.dirname(existing);
      final segment = p.basename(existing);
      if (parent == existing ||
          segment.isEmpty ||
          segment == '.' ||
          segment == '..') {
        throw FileSystemException(
          'Report destination has an invalid missing path segment.',
          requested,
        );
      }
      missingSegments.add(segment);
      existing = parent;
    }

    final existingType = FileSystemEntity.typeSync(
      existing,
      followLinks: false,
    );
    if (existingType != FileSystemEntityType.directory &&
        existingType != FileSystemEntityType.link) {
      throw FileSystemException(
        'Report destination has a non-directory parent.',
        existing,
      );
    }
    final canonicalParent = p.normalize(
      Directory(existing).resolveSymbolicLinksSync(),
    );
    if (FileSystemEntity.typeSync(canonicalParent, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw FileSystemException(
        'Report destination parent does not resolve to a directory.',
        existing,
      );
    }
    final canonical = p.normalize(
      p.joinAll([canonicalParent, ...missingSegments.reversed]),
    );
    return ResolvedReportDestination(
      requestedPath: requested,
      canonicalPath: canonical,
    );
  }

  @override
  Future<void> createParent(String destination) =>
      Directory(p.dirname(destination)).create(recursive: true);

  @override
  Future<void> createExclusive(String path) async {
    await File(path).create(exclusive: true);
  }

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) async {
    RandomAccessFile? handle;
    Object? failure;
    StackTrace? failureStack;
    try {
      handle = await File(path).open(mode: FileMode.writeOnly);
      await handle.writeString(ownerToken);
      await handle.flush();
    } catch (error, stackTrace) {
      failure = error;
      failureStack = stackTrace;
    } finally {
      if (handle != null) {
        try {
          await handle.close();
        } catch (error, stackTrace) {
          failure = error;
          failureStack = stackTrace;
        }
      }
    }
    if (failure != null) {
      Error.throwWithStackTrace(failure, failureStack!);
    }
    final confirmed = await File(path).readAsString();
    if (confirmed != ownerToken) {
      throw StateError('Report lock owner token confirmation failed.');
    }
  }

  @override
  Future<bool> exists(String path) async =>
      FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.notFound;

  @override
  Future<void> rename(String from, String to) async {
    if (!p.equals(p.dirname(from), p.dirname(to))) {
      throw ArgumentError(
        'Report transaction renames must stay in one directory.',
      );
    }
    await File(from).rename(to);
  }

  @override
  Future<void> delete(String path) async {
    await File(path).delete();
  }

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) async {
    if (await File(path).readAsString() != ownerToken) return false;
    await File(path).delete();
    return true;
  }

  @override
  Future<List<String>> transactionArtifactsFor(String destination) async {
    final directory = Directory(p.dirname(destination));
    if (!directory.existsSync()) return const [];
    final basename = p.basename(destination);
    final prefix = '.$basename.flutter_pruner.';
    final previousName = '.$basename.flutter_pruner.previous';
    final artifacts =
        directory
            .listSync(followLinks: false)
            .where((entity) {
              final name = p.basename(entity.path);
              return name == previousName ||
                  (name.startsWith(prefix) && name.endsWith('.tmp'));
            })
            .map((entity) => p.normalize(p.absolute(entity.path)))
            .toList()
          ..sort();
    return artifacts;
  }
}

/// Opens a new exclusive temporary report file using [dart:io].
Future<ReportOutputSink> openIoReportOutputSink(String path) async {
  final file = File(path);
  await file.create(exclusive: true);
  return _IoReportOutputSink(file.openWrite(mode: FileMode.writeOnly));
}

/// Persists complete reports through a recoverable same-directory transaction.
///
/// This workflow handles reported operation failures. It does not promise
/// crash durability, parent-directory fsync, preservation of ownership, mode,
/// ACLs or extended attributes, or safety against non-cooperating processes
/// that swap path components after [resolve].
final class RecoverableReportWriter {
  /// Creates a writer with injectable filesystem and sink boundaries.
  const RecoverableReportWriter({
    this.operations = const IoReportFileOperations(),
    this.sinkFactory = openIoReportOutputSink,
  });

  /// Filesystem operations used by the transaction.
  final ReportFileOperations operations;

  /// Factory that exclusively creates the same-directory temporary report.
  final ReportSinkFactory sinkFactory;

  /// Resolves and freezes [requested]'s canonical identity without mutation.
  Future<ResolvedReportDestination> resolve(File requested) async {
    final requestedPath = p.normalize(p.absolute(requested.path));
    try {
      return await operations.resolveDestination(requestedPath);
    } catch (error) {
      if (error is ReportPersistenceException) rethrow;
      throw ReportPersistenceFailure(
        phase: ReportPersistencePhase.resolveDestination,
        requestedDestination: requestedPath,
        canonicalDestination: null,
        artifacts: const [],
        cause: error,
      );
    }
  }

  /// Writes a complete report and promotes it only after flush and close.
  ///
  /// Before the promotion commit point, the old destination remains
  /// authoritative and is restored when necessary. After a successful
  /// temporary-to-destination rename, the new destination is authoritative and
  /// is never overwritten by automatic recovery.
  Future<void> write(
    ResolvedReportDestination destination, {
    required String runId,
    required ReportSinkCallback writeTo,
  }) async {
    final requested = destination.requestedPath;
    final canonical = destination.canonicalPath;
    final _TransactionPaths paths;
    try {
      paths = _TransactionPaths(canonical, runId);
    } catch (error) {
      throw ReportPersistenceFailure(
        phase: ReportPersistencePhase.discovery,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: const [],
        cause: error,
      );
    }

    try {
      await operations.createParent(canonical);
    } catch (error) {
      throw ReportPersistenceFailure(
        phase: ReportPersistencePhase.discovery,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: const [],
        cause: error,
      );
    }

    final List<String> discovered;
    try {
      discovered = await operations.transactionArtifactsFor(canonical);
    } catch (error) {
      final artifacts = await _survivingArtifacts(paths);
      throw ReportPersistenceRecoveryRequiredException(
        phase: ReportPersistencePhase.discovery,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: artifacts,
        cause: error,
      );
    }
    if (discovered.isNotEmpty) {
      final artifacts = await _survivingArtifacts(paths, seed: discovered);
      throw ReportPersistenceRecoveryRequiredException(
        phase: ReportPersistencePhase.discovery,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: artifacts,
      );
    }

    try {
      await operations.createExclusive(paths.lock);
    } catch (error) {
      final artifacts = await _survivingArtifacts(paths);
      if (artifacts.isNotEmpty) {
        throw ReportPersistenceRecoveryRequiredException(
          phase: ReportPersistencePhase.lock,
          requestedDestination: requested,
          canonicalDestination: canonical,
          artifacts: artifacts,
          cause: error,
        );
      }
      throw ReportPersistenceFailure(
        phase: ReportPersistencePhase.lock,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: artifacts,
        cause: error,
      );
    }

    final ownerToken = jsonEncode({
      'pid': pid,
      'runId': runId,
      'acquiredAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
    try {
      await operations.writeAndConfirmLockOwner(paths.lock, ownerToken);
    } catch (error) {
      final artifacts = await _survivingArtifacts(paths);
      throw ReportPersistenceRecoveryRequiredException(
        phase: ReportPersistencePhase.writeLockOwner,
        requestedDestination: requested,
        canonicalDestination: canonical,
        artifacts: artifacts,
        cause: error,
      );
    }
    final ownerConfirmed = true;

    final List<String> rechecked;
    try {
      rechecked = await operations.transactionArtifactsFor(canonical);
    } catch (error) {
      await _throwAfterOwnedDiscoveryFailure(
        paths: paths,
        requested: requested,
        ownerToken: ownerToken,
        phase: ReportPersistencePhase.discovery,
        cause: error,
      );
    }
    if (rechecked.isNotEmpty) {
      await _throwAfterOwnedDiscoveryFailure(
        paths: paths,
        requested: requested,
        ownerToken: ownerToken,
        phase: ReportPersistencePhase.discovery,
        seedArtifacts: rechecked,
      );
    }

    ReportOutputSink? sink;
    _TransactionFailure? primaryFailure;
    try {
      sink = await sinkFactory(paths.temporary);
    } catch (error) {
      primaryFailure = _TransactionFailure(ReportPersistencePhase.open, error);
    }
    if (sink != null) {
      try {
        writeTo(sink);
      } catch (error) {
        primaryFailure = _TransactionFailure(
          ReportPersistencePhase.write,
          error,
        );
      }
      if (primaryFailure == null) {
        try {
          await sink.flush();
        } catch (error) {
          primaryFailure = _TransactionFailure(
            ReportPersistencePhase.flush,
            error,
          );
        }
      }
      try {
        await sink.close();
      } catch (error) {
        primaryFailure ??= _TransactionFailure(
          ReportPersistencePhase.close,
          error,
        );
      }
    }
    if (primaryFailure case final failure?) {
      await _throwPreCommit(
        paths: paths,
        requested: requested,
        ownerToken: ownerToken,
        ownerConfirmed: ownerConfirmed,
        failure: failure,
      );
    }

    final bool destinationExisted;
    try {
      destinationExisted = await operations.exists(canonical);
    } catch (error) {
      await _throwPreCommit(
        paths: paths,
        requested: requested,
        ownerToken: ownerToken,
        ownerConfirmed: ownerConfirmed,
        failure: _TransactionFailure(
          ReportPersistencePhase.movePrevious,
          error,
        ),
      );
    }

    var previousMoved = false;
    if (destinationExisted) {
      try {
        await operations.rename(canonical, paths.previous);
        previousMoved = true;
      } catch (error) {
        final restoreFailure = await _restorePreviousAuthority(paths);
        await _throwPreCommit(
          paths: paths,
          requested: requested,
          ownerToken: ownerToken,
          ownerConfirmed: ownerConfirmed,
          failure: _TransactionFailure(
            ReportPersistencePhase.movePrevious,
            error,
          ),
          recoveryFailure: restoreFailure,
        );
      }
    }

    var promotionCommitted = false;
    try {
      await operations.rename(paths.temporary, canonical);
      promotionCommitted = true;
    } catch (error) {
      _TransactionFailure? restoreFailure;
      if (previousMoved) {
        restoreFailure = await _restorePreviousAuthority(paths);
      } else if (!destinationExisted) {
        restoreFailure = await _removeUnconfirmedDestinationIfPresent(paths);
      }
      await _throwPreCommit(
        paths: paths,
        requested: requested,
        ownerToken: ownerToken,
        ownerConfirmed: ownerConfirmed,
        failure: _TransactionFailure(ReportPersistencePhase.promote, error),
        recoveryFailure: restoreFailure,
      );
    }

    _TransactionFailure? cleanupFailure;
    if (previousMoved) {
      try {
        await operations.delete(paths.previous);
      } catch (error) {
        cleanupFailure = _TransactionFailure(
          ReportPersistencePhase.deletePrevious,
          error,
        );
      }
    }
    final releaseFailure = await _releaseOwnedLock(paths.lock, ownerToken);
    cleanupFailure ??= releaseFailure;
    final artifacts = await _survivingArtifacts(paths);
    if (cleanupFailure != null || artifacts.isNotEmpty) {
      _throwCommittedCleanup(
        promotionCommitted: promotionCommitted,
        failure: cleanupFailure,
        requested: requested,
        canonical: canonical,
        artifacts: artifacts,
      );
    }
  }

  Never _throwCommittedCleanup({
    required bool promotionCommitted,
    required _TransactionFailure? failure,
    required String requested,
    required String canonical,
    required List<String> artifacts,
  }) {
    if (!promotionCommitted) {
      throw StateError('Committed cleanup reached before promotion.');
    }
    throw ReportPersistenceCommittedCleanupRequiredException(
      phase: failure?.phase ?? ReportPersistencePhase.cleanup,
      requestedDestination: requested,
      canonicalDestination: canonical,
      artifacts: artifacts,
      cause: failure?.cause,
    );
  }

  Future<Never> _throwAfterOwnedDiscoveryFailure({
    required _TransactionPaths paths,
    required String requested,
    required String ownerToken,
    required ReportPersistencePhase phase,
    Object? cause,
    List<String> seedArtifacts = const [],
  }) async {
    final releaseFailure = await _releaseOwnedLock(paths.lock, ownerToken);
    final artifacts = await _survivingArtifacts(paths, seed: seedArtifacts);
    throw ReportPersistenceRecoveryRequiredException(
      phase: releaseFailure?.phase ?? phase,
      requestedDestination: requested,
      canonicalDestination: paths.destination,
      artifacts: artifacts,
      cause: releaseFailure?.cause ?? cause,
    );
  }

  Future<Never> _throwPreCommit({
    required _TransactionPaths paths,
    required String requested,
    required String ownerToken,
    required bool ownerConfirmed,
    required _TransactionFailure failure,
    _TransactionFailure? recoveryFailure,
  }) async {
    _TransactionFailure? cleanupFailure;
    try {
      if (await operations.exists(paths.temporary)) {
        try {
          await operations.delete(paths.temporary);
        } catch (error) {
          var temporaryStillExists = true;
          try {
            temporaryStillExists = await operations.exists(paths.temporary);
          } catch (_) {
            // The failed observation leaves cleanup unconfirmed.
          }
          if (temporaryStillExists) {
            cleanupFailure = _TransactionFailure(
              ReportPersistencePhase.cleanup,
              error,
            );
          }
        }
      }
    } catch (error) {
      cleanupFailure = _TransactionFailure(
        ReportPersistencePhase.cleanup,
        error,
      );
    }

    var transactionArtifacts = const <String>[];
    try {
      transactionArtifacts = await operations.transactionArtifactsFor(
        paths.destination,
      );
    } catch (error) {
      cleanupFailure ??= _TransactionFailure(
        ReportPersistencePhase.cleanup,
        error,
      );
    }
    if (transactionArtifacts.isNotEmpty) {
      cleanupFailure ??= _TransactionFailure(
        ReportPersistencePhase.cleanup,
        StateError('Pre-commit transaction artifacts remain.'),
      );
    }
    if (!ownerConfirmed) {
      cleanupFailure ??= _TransactionFailure(
        ReportPersistencePhase.writeLockOwner,
        StateError('Report lock ownership was not confirmed.'),
      );
    }

    final recoveryReason = recoveryFailure ?? cleanupFailure;
    if (recoveryReason != null) {
      final artifacts = await _survivingArtifacts(
        paths,
        seed: [...transactionArtifacts, if (ownerConfirmed) paths.lock],
      );
      throw ReportPersistenceRecoveryRequiredException(
        phase: recoveryReason.phase,
        requestedDestination: requested,
        canonicalDestination: paths.destination,
        artifacts: artifacts,
        cause: recoveryReason.cause,
      );
    }

    final releaseFailure = await _releaseOwnedLock(paths.lock, ownerToken);
    if (releaseFailure != null) {
      final artifacts = await _survivingArtifacts(paths);
      throw ReportPersistenceRecoveryRequiredException(
        phase: releaseFailure.phase,
        requestedDestination: requested,
        canonicalDestination: paths.destination,
        artifacts: artifacts,
        cause: releaseFailure.cause,
      );
    }
    throw ReportPersistenceFailure(
      phase: failure.phase,
      requestedDestination: requested,
      canonicalDestination: paths.destination,
      artifacts: const [],
      cause: failure.cause,
    );
  }

  Future<_TransactionFailure?> _restorePreviousAuthority(
    _TransactionPaths paths,
  ) async {
    Object? renameFailure;
    try {
      if (await operations.exists(paths.previous)) {
        try {
          await operations.rename(paths.previous, paths.destination);
        } catch (error) {
          renameFailure = error;
        }
      }
    } catch (error) {
      return _TransactionFailure(ReportPersistencePhase.restore, error);
    }

    try {
      final destinationRestored = await operations.exists(paths.destination);
      final previousRemoved = !await operations.exists(paths.previous);
      if (!destinationRestored || !previousRemoved) {
        return _TransactionFailure(
          ReportPersistencePhase.restore,
          renameFailure ??
              StateError('Previous report authority could not be confirmed.'),
        );
      }
      return null;
    } catch (error) {
      return _TransactionFailure(
        ReportPersistencePhase.restore,
        renameFailure ?? error,
      );
    }
  }

  Future<_TransactionFailure?> _removeUnconfirmedDestinationIfPresent(
    _TransactionPaths paths,
  ) async {
    try {
      if (!await operations.exists(paths.destination)) return null;
    } catch (error) {
      return _TransactionFailure(ReportPersistencePhase.restore, error);
    }

    try {
      await operations.delete(paths.destination);
      return null;
    } catch (error) {
      try {
        if (!await operations.exists(paths.destination)) return null;
      } catch (_) {
        // The failed observation leaves restoration unconfirmed.
      }
      return _TransactionFailure(ReportPersistencePhase.restore, error);
    }
  }

  Future<_TransactionFailure?> _releaseOwnedLock(
    String lock,
    String ownerToken,
  ) async {
    try {
      final deleted = await operations.deleteOwnedLock(lock, ownerToken);
      if (!deleted) {
        return _TransactionFailure(
          ReportPersistencePhase.releaseLock,
          StateError('Report lock owner token changed.'),
        );
      }
      return null;
    } catch (error) {
      return _TransactionFailure(ReportPersistencePhase.releaseLock, error);
    }
  }

  Future<List<String>> _survivingArtifacts(
    _TransactionPaths paths, {
    List<String> seed = const [],
  }) async {
    final artifacts = <String>{...seed};
    try {
      artifacts.addAll(
        await operations.transactionArtifactsFor(paths.destination),
      );
    } catch (_) {
      for (final candidate in [paths.temporary, paths.previous]) {
        try {
          if (await operations.exists(candidate)) artifacts.add(candidate);
        } catch (_) {
          // Best-effort fallback after discovery itself failed.
        }
      }
    }
    try {
      if (await operations.exists(paths.lock)) artifacts.add(paths.lock);
    } catch (_) {
      // The primary filesystem failure remains authoritative.
    }
    final sorted = artifacts.toList()..sort();
    return List<String>.unmodifiable(sorted);
  }
}

final class _TransactionPaths {
  _TransactionPaths(this.destination, String runId) {
    if (!p.isAbsolute(destination) ||
        p.normalize(destination) != destination ||
        runId.isEmpty ||
        p.basename(runId) != runId ||
        runId == '.' ||
        runId == '..') {
      throw ArgumentError('Report transaction identity is not canonical.');
    }
    final directory = p.dirname(destination);
    final basename = p.basename(destination);
    lock = p.join(directory, '.$basename.flutter_pruner.lock');
    previous = p.join(directory, '.$basename.flutter_pruner.previous');
    temporary = p.join(directory, '.$basename.flutter_pruner.$runId.tmp');
    if (!p.equals(p.dirname(lock), directory) ||
        !p.equals(p.dirname(previous), directory) ||
        !p.equals(p.dirname(temporary), directory)) {
      throw ArgumentError('Report transaction paths must share one directory.');
    }
  }

  final String destination;
  late final String lock;
  late final String previous;
  late final String temporary;
}

final class _TransactionFailure {
  const _TransactionFailure(this.phase, this.cause);

  final ReportPersistencePhase phase;
  final Object? cause;
}

final class _IoReportOutputSink implements ReportOutputSink {
  _IoReportOutputSink(this._sink);

  final IOSink _sink;

  @override
  void write(Object? object) => _sink.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _sink.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _sink.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _sink.writeln(object);

  @override
  Future<void> flush() => _sink.flush();

  @override
  Future<void> close() => _sink.close();
}

String _causeCategory(Object? cause) => switch (cause) {
  null => 'none',
  FileSystemException() => 'filesystem',
  FormatException() => 'format',
  ArgumentError() => 'argument',
  StateError() => 'state',
  Exception() => 'exception',
  Error() => 'error',
  _ => 'object',
};
