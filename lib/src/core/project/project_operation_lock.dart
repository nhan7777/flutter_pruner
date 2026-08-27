import 'dart:convert';
import 'dart:io';

import '../process/managed_process_runner.dart';
import 'tool_workspace.dart';

/// Exclusive project lock for commands that can mutate source or recovery data.
///
/// The lock file is intentionally retained after release. Deleting a locked
/// file would allow another process to lock a new inode at the same path while
/// the first process still owns the old one.
class ProjectOperationLock {
  ProjectOperationLock._(this._handle, this._lockFile);

  final RandomAccessFile _handle;
  final File _lockFile;
  var _released = false;
  String? _activeUncertaintyIncident;
  var _hasRetainedExactProcessIdentityEvidence = false;

  /// Whether the most recent unconfirmed managed-process failure was flushed
  /// with complete, exact root and observed-descendant identity evidence.
  bool get hasRetainedExactProcessIdentityEvidence =>
      _hasRetainedExactProcessIdentityEvidence;

  /// Acquires a non-blocking exclusive lock for [operation].
  ///
  /// A competing process fails closed instead of waiting while project bytes
  /// or quarantine authority may be changing.
  static Future<ProjectOperationLock> acquire({
    required ToolWorkspace workspace,
    required String operation,
    ProcessIdentityInspector identityInspector =
        const ManagedProcessIdentityInspector(),
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
      final journal = await _OperationLockJournal.read(handle);
      if (journal.corrupt) {
        throw ProjectOperationLockException(
          _corruptUncertaintyMessage(
            workspace.projectRoot.path,
            journal.guidancePids,
          ),
        );
      }
      if (journal.unresolved case final unresolved?) {
        if (!unresolved.hasCompleteIdentityEvidence) {
          throw ProjectOperationLockException(
            _corruptUncertaintyMessage(
              workspace.projectRoot.path,
              unresolved.guidancePids,
            ),
          );
        }
        PosixProcessTableSnapshot? snapshot;
        try {
          snapshot = await identityInspector.snapshot();
        } on Object {
          snapshot = null;
        }
        if (snapshot == null) {
          throw ProjectOperationLockException(
            _inspectionUnavailableMessage(
              workspace.projectRoot.path,
              unresolved.guidancePids,
            ),
          );
        }
        final activePids =
            snapshot
                .matchingPids(unresolved.identities.values)
                .toList(growable: false)
              ..sort();
        if (activePids.isNotEmpty) {
          throw ProjectOperationLockException(
            _activeUncertaintyMessage(workspace.projectRoot.path, activePids),
          );
        }
      }

      await _writeOwner(
        handle,
        operation: operation,
        projectRoot: workspace.projectRoot.path,
      );
      return ProjectOperationLock._(handle, lockFile);
    } on ProjectOperationLockException {
      try {
        await handle.unlock();
      } finally {
        await handle.close();
      }
      rethrow;
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

  /// Runs one managed-process region under crash-durable project authority.
  ///
  /// The armed record is flushed before [body] can launch a process. Safe
  /// completion appends a cleared record. Unconfirmed termination instead
  /// retains the exact observed root and descendant start identities so the
  /// next mutating command can proceed only after every exact lifetime is
  /// definitively absent.
  Future<T> guardManagedProcessUncertainty<T>({
    required String incidentId,
    required String phase,
    required Future<T> Function() body,
  }) async {
    if (_released) {
      throw StateError('Cannot guard managed work after lock release.');
    }
    if (_activeUncertaintyIncident != null) {
      throw StateError('Managed process uncertainty guards cannot be nested.');
    }
    _validateJournalValue(incidentId, 'incidentId');
    _validateJournalValue(phase, 'phase');
    _activeUncertaintyIncident = incidentId;
    _hasRetainedExactProcessIdentityEvidence = false;
    var armed = false;
    var bodyCompleted = false;

    try {
      await _appendJournalRecord(<String, Object?>{
        'recordType': _processUncertaintyRecordType,
        'version': 1,
        'incidentId': incidentId,
        'phase': phase,
        'state': 'armed',
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
      });
      armed = true;
      final result = await body();
      bodyCompleted = true;
      await _appendCleared(incidentId, phase);
      return result;
    } on ProcessTerminationUnconfirmedException catch (error, stackTrace) {
      try {
        final identities = error.observedProcesses.values.toList(
          growable: false,
        )..sort((left, right) => left.pid.compareTo(right.pid));
        await _appendJournalRecord(<String, Object?>{
          'recordType': _processUncertaintyRecordType,
          'version': 1,
          'incidentId': incidentId,
          'phase': phase,
          'state': 'unconfirmed',
          'failureType': 'ProcessTerminationUnconfirmedException',
          'rootPid': error.processId,
          'trigger': _triggerName(error.triggerSignal),
          'observationReliable': error.observationReliable,
          'identities': <Map<String, Object?>>[
            for (final identity in identities)
              <String, Object?>{
                'pid': identity.pid,
                'startFingerprint': identity.startFingerprint,
              },
          ],
          'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
        });
        _hasRetainedExactProcessIdentityEvidence =
            error.observationReliable &&
            error.observedProcesses.containsKey(error.processId);
      } on Object {
        // The already-flushed armed record remains an authoritative blocker.
      }
      Error.throwWithStackTrace(error, stackTrace);
    } on Object catch (error, stackTrace) {
      if (armed && !bodyCompleted) {
        try {
          await _appendCleared(incidentId, phase);
        } on Object {
          // Preserve the original failure. The retained armed record fails closed.
        }
      }
      Error.throwWithStackTrace(error, stackTrace);
    } finally {
      _activeUncertaintyIncident = null;
    }
  }

  Future<void> _appendCleared(String incidentId, String phase) =>
      _appendJournalRecord(<String, Object?>{
        'recordType': _processUncertaintyRecordType,
        'version': 1,
        'incidentId': incidentId,
        'phase': phase,
        'state': 'cleared',
        'recordedAtUtc': DateTime.now().toUtc().toIso8601String(),
      });

  Future<void> _appendJournalRecord(Map<String, Object?> record) async {
    final encoded = utf8.encode('\n${jsonEncode(record)}\n');
    if (encoded.length > _maxJournalRecordBytes) {
      throw ProjectOperationLockException(
        'Managed process uncertainty evidence exceeded the retained lock '
        'record limit for ${_lockFile.path}.',
      );
    }
    await _handle.setPosition(await _handle.length());
    await _handle.writeFrom(encoded);
    await _handle.flush();
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
      final firstLine = const LineSplitter()
          .convert(contents)
          .firstWhere((line) => line.trim().isNotEmpty);
      final value = jsonDecode(firstLine);
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

const _processUncertaintyRecordType = 'processUncertainty';
const _maxOperationLockBytes = 1024 * 1024;
const _maxJournalRecordBytes = 512 * 1024;
const _maxGuidancePids = 8;

Future<void> _writeOwner(
  RandomAccessFile handle, {
  required String operation,
  required String projectRoot,
}) async {
  await handle.setPosition(0);
  await handle.truncate(0);
  await handle.writeString(
    jsonEncode(<String, Object?>{
      'recordType': 'owner',
      'version': 1,
      'pid': pid,
      'operation': operation,
      'startedAtUtc': DateTime.now().toUtc().toIso8601String(),
      'projectRoot': projectRoot,
    }),
  );
  await handle.flush();
}

void _validateJournalValue(String value, String name) {
  if (value.isEmpty ||
      value.length > 160 ||
      value.runes.any((rune) => rune < 0x20 || rune == 0x7f)) {
    throw ArgumentError.value(value, name, 'must be bounded printable text');
  }
}

String _triggerName(ProcessSignal? signal) {
  if (signal == null) return 'timeout';
  if (signal == ProcessSignal.sigint) return 'sigint';
  if (signal == ProcessSignal.sigterm) return 'sigterm';
  return signal.toString().split('.').last.toLowerCase();
}

String _renderPids(Iterable<int> pids) {
  final bounded = pids.toSet().toList(growable: false)..sort();
  final visible = bounded.take(_maxGuidancePids).map((pid) => 'PID $pid');
  final omitted = bounded.length - _maxGuidancePids;
  return '${visible.join(', ')}${omitted > 0 ? ', and $omitted more' : ''}';
}

String _activeUncertaintyMessage(String projectRoot, Iterable<int> pids) =>
    'A previously observed Flutter Pruner process may still be running for '
    '$projectRoot: ${_renderPids(pids)}. No mutation was attempted. Wait for '
    'every recorded process to exit, then rerun; exact process identities are '
    'checked automatically.';

String _inspectionUnavailableMessage(String projectRoot, Iterable<int> pids) =>
    'Previously observed Flutter Pruner process identities could not be '
    'inspected for $projectRoot${pids.isEmpty ? '' : ': ${_renderPids(pids)}'}. '
    'No mutation was attempted. Restore process inspection and rerun.';

String _corruptUncertaintyMessage(String projectRoot, Iterable<int> pids) =>
    'Flutter Pruner process uncertainty evidence is corrupt for '
    '$projectRoot${pids.isEmpty ? '' : ': ${_renderPids(pids)}'}. No mutation '
    'was attempted. Preserve operation.lock and inspect the recorded processes '
    'before recovery.';

final class _OperationLockJournal {
  const _OperationLockJournal({
    required this.unresolved,
    required this.corrupt,
    required this.guidancePids,
  });

  final _UnresolvedProcessUncertainty? unresolved;
  final bool corrupt;
  final List<int> guidancePids;

  static Future<_OperationLockJournal> read(RandomAccessFile handle) async {
    final length = await handle.length();
    if (length == 0) {
      return const _OperationLockJournal(
        unresolved: null,
        corrupt: false,
        guidancePids: <int>[],
      );
    }
    final boundedLength = length > _maxOperationLockBytes
        ? _maxOperationLockBytes
        : length;
    await handle.setPosition(0);
    final bytes = await handle.read(boundedLength);
    String contents;
    try {
      contents = utf8.decode(bytes, allowMalformed: false);
    } on FormatException {
      return const _OperationLockJournal(
        unresolved: null,
        corrupt: true,
        guidancePids: <int>[],
      );
    }
    var corrupt = length > _maxOperationLockBytes;
    _UnresolvedProcessUncertainty? active;
    final guidancePids = <int>{};
    final lines = const LineSplitter().convert(contents);
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index].trim();
      if (line.isEmpty) continue;
      Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        if (index > 0 ||
            active != null ||
            line.contains(_processUncertaintyRecordType)) {
          corrupt = true;
        }
        continue;
      }
      if (decoded is! Map<String, dynamic>) {
        if (index > 0) corrupt = true;
        continue;
      }
      if (decoded['recordType'] != _processUncertaintyRecordType) continue;
      final incidentId = decoded['incidentId'];
      final phase = decoded['phase'];
      final state = decoded['state'];
      if (decoded['version'] != 1 ||
          incidentId is! String ||
          phase is! String ||
          state is! String) {
        corrupt = true;
        continue;
      }
      switch (state) {
        case 'armed':
          if (active != null) corrupt = true;
          active = _UnresolvedProcessUncertainty.armed(
            incidentId: incidentId,
            phase: phase,
          );
        case 'unconfirmed':
          if (active == null || active.incidentId != incidentId) {
            corrupt = true;
            continue;
          }
          final parsed = _UnresolvedProcessUncertainty.fromUnconfirmed(decoded);
          guidancePids.addAll(parsed.guidancePids);
          if (!parsed.valid) corrupt = true;
          active = parsed;
        case 'cleared':
          if (active == null || active.incidentId != incidentId) {
            corrupt = true;
          } else {
            active = null;
          }
        default:
          corrupt = true;
      }
    }
    if (active case final unresolved?) {
      guidancePids.addAll(unresolved.guidancePids);
    }
    return _OperationLockJournal(
      unresolved: active,
      corrupt: corrupt,
      guidancePids: guidancePids.toList(growable: false)..sort(),
    );
  }
}

final class _UnresolvedProcessUncertainty {
  const _UnresolvedProcessUncertainty._({
    required this.incidentId,
    required this.phase,
    required this.rootPid,
    required this.identities,
    required this.observationReliable,
    required this.valid,
  });

  const _UnresolvedProcessUncertainty.armed({
    required String incidentId,
    required String phase,
  }) : this._(
         incidentId: incidentId,
         phase: phase,
         rootPid: null,
         identities: const <int, PosixProcessIdentity>{},
         observationReliable: false,
         valid: true,
       );

  factory _UnresolvedProcessUncertainty.fromUnconfirmed(
    Map<String, dynamic> record,
  ) {
    final incidentId = record['incidentId'] as String;
    final phase = record['phase'] as String;
    final rootPid = record['rootPid'];
    final failureType = record['failureType'];
    final observationReliable = record['observationReliable'] == true;
    final rawIdentities = record['identities'];
    final identities = <int, PosixProcessIdentity>{};
    var valid =
        failureType == 'ProcessTerminationUnconfirmedException' &&
        rootPid is int &&
        rootPid > 0 &&
        rawIdentities is List;
    if (rawIdentities is List) {
      for (final rawIdentity in rawIdentities) {
        if (rawIdentity is! Map<String, dynamic>) {
          valid = false;
          continue;
        }
        final processId = rawIdentity['pid'];
        final startFingerprint = rawIdentity['startFingerprint'];
        if (processId is! int ||
            processId <= 0 ||
            startFingerprint is! String ||
            startFingerprint.isEmpty ||
            startFingerprint.length > 128 ||
            identities.containsKey(processId)) {
          valid = false;
          continue;
        }
        identities[processId] = PosixProcessIdentity(
          pid: processId,
          startFingerprint: startFingerprint,
        );
      }
    }
    if (!observationReliable ||
        rootPid is! int ||
        !identities.containsKey(rootPid)) {
      valid = false;
    }
    return _UnresolvedProcessUncertainty._(
      incidentId: incidentId,
      phase: phase,
      rootPid: rootPid is int ? rootPid : null,
      identities: Map.unmodifiable(identities),
      observationReliable: observationReliable,
      valid: valid,
    );
  }

  final String incidentId;
  final String phase;
  final int? rootPid;
  final Map<int, PosixProcessIdentity> identities;
  final bool observationReliable;
  final bool valid;

  bool get hasCompleteIdentityEvidence =>
      valid &&
      observationReliable &&
      rootPid != null &&
      identities.containsKey(rootPid);

  List<int> get guidancePids => identities.keys.toList(growable: false)..sort();
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
