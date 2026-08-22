import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'report_commit.dart';
import 'report_object_backend.dart';

/// Stable phase of an immutable report-store failure.
enum ImmutableReportStorePhase {
  /// Inputs or generated identities failed before filesystem mutation.
  preflight,

  /// An immutable report object could not be exclusively created.
  createObject,

  /// Formatter output or native writes failed.
  writeObject,

  /// Object content could not be flushed.
  flushObject,

  /// Retained-handle read-back did not match exact written bytes.
  verifyObject,

  /// The immutable commit object could not be exclusively created.
  createCommit,

  /// Commit serialization or native writes failed.
  writeCommit,

  /// Commit content could not be flushed.
  flushCommit,

  /// Commit parse or retained object validation failed.
  verifyCommit,

  /// A retained object or commit capability could not be closed cleanly.
  closeCapability,

  /// A frozen directory path no longer reaches its retained capability.
  verifyReachability,

  /// Retained report directory capabilities could not be closed.
  closeStore,
}

/// Sanitized immutable report-store failure with surviving created artifacts.
final class ImmutableReportStoreException implements Exception {
  /// Creates a failure and snapshots [artifacts].
  ImmutableReportStoreException({
    required this.phase,
    required Iterable<String> artifacts,
    this.failedRole,
    this.cause,
  }) : artifacts = List.unmodifiable(artifacts.toSet().toList()..sort());

  /// Stable lifecycle phase.
  final ImmutableReportStorePhase phase;

  /// Paths successfully created by this failed batch. Nothing is removed.
  final List<String> artifacts;

  /// Object role active when an object-specific phase failed.
  ///
  /// This is `null` for preflight, commit, reachability, and store-close
  /// failures that cannot truthfully be attributed to one object.
  final String? failedRole;

  /// Underlying failure, omitted from [toString].
  final Object? cause;

  @override
  String toString() =>
      'Immutable report persistence failed; phase=${phase.name}; '
      'failedRole=${failedRole ?? 'none'}; '
      'artifacts=${jsonEncode(artifacts)}';
}

/// Immutable identity shared by one object batch and its commit record.
final class ReportCommitIdentity {
  /// Creates one proposed commit identity.
  const ReportCommitIdentity({
    required this.runId,
    required this.sequence,
    required this.command,
    required this.completedAtUtc,
  });

  /// Secure UTC-sortable run ID.
  final String runId;

  /// Monotonic state sequence within [runId].
  final int sequence;

  /// `scan` or `apply`.
  final String command;

  /// Canonical UTC timestamp with six fractional digits.
  final String completedAtUtc;
}

/// One formatter stream to persist as an immutable report object.
final class ReportObjectWrite {
  /// Creates one proposed object write.
  const ReportObjectWrite({
    required this.role,
    required this.format,
    required this.reportSchemaVersion,
    required this.writeTo,
  });

  /// Unique canonical role within the batch.
  final String role;

  /// `json`, `html`, or `text`.
  final String format;

  /// Report schema version represented by the output.
  final int reportSchemaVersion;

  /// Synchronously emits formatter tokens to a persistence-owned sink.
  final void Function(StringSink sink) writeTo;
}

/// A completely validated immutable report batch eligible for READY output.
final class CommittedReport {
  /// Creates a completed result after every retained capability is verified.
  CommittedReport({
    required this.commit,
    required this.commitPath,
    required Map<String, String> actualObjectPaths,
  }) : actualObjectPaths = Map.unmodifiable(actualObjectPaths);

  /// Parsed canonical authority record.
  final ReportCommit commit;

  /// Actual immutable commit path.
  final String commitPath;

  /// Actual immutable object path keyed by object role.
  final Map<String, String> actualObjectPaths;

  /// This type is constructed only after complete validation.
  bool get ready => true;
}

/// Appends report objects and their all-or-none immutable commit record.
final class ImmutableReportStore {
  /// Creates a store from pre-anchored object and commit directories.
  ImmutableReportStore({
    required this.objectsDirectory,
    required this.commitsDirectory,
  });

  /// Retained `objects/` directory capability.
  final AnchoredReportDirectory objectsDirectory;

  /// Retained `commits/` directory capability.
  final AnchoredReportDirectory commitsDirectory;

  var _closed = false;

  /// Writes one immutable object batch and its final authority record.
  Future<CommittedReport> writeBatch({
    required ReportCommitIdentity identity,
    required List<ReportObjectWrite> objects,
    Map<String, AnchoredReportDirectory> objectDirectoryOverrides = const {},
    Map<String, String> objectLeafOverrides = const {},
    Map<String, String> recordPathOverrides = const {},
    String? commitLeafOverride,
    String recordPathPrefix = 'objects',
  }) async {
    if (_closed) {
      throw ImmutableReportStoreException(
        phase: ImmutableReportStorePhase.preflight,
        artifacts: const [],
        cause: StateError('Store is closed.'),
      );
    }

    late final List<_PlannedObject> plannedObjects;
    late final String commitLeaf;
    try {
      plannedObjects = _preflight(
        identity,
        objects,
        defaultDirectory: objectsDirectory,
        objectDirectoryOverrides: objectDirectoryOverrides,
        objectLeafOverrides: objectLeafOverrides,
        recordPathOverrides: recordPathOverrides,
        recordPathPrefix: recordPathPrefix,
      );
      commitLeaf = commitLeafOverride ?? buildReportCommitLeaf(identity);
      validateReportObjectLeaf(commitLeaf);
    } on Object catch (error) {
      throw ImmutableReportStoreException(
        phase: ImmutableReportStorePhase.preflight,
        artifacts: const [],
        cause: error,
      );
    }

    final artifacts = <String>[];
    final openObjects = <ExclusiveReportObject>[];
    final openObjectsByRole = <String, ExclusiveReportObject>{};
    ExclusiveReportObject? commitObject;
    ReportCommit? completedCommit;
    final actualPaths = <String, String>{};
    Object? primaryError;
    StackTrace? primaryStackTrace;
    ImmutableReportStorePhase? primaryPhase;
    String? primaryFailedRole;

    try {
      final records = <ReportObjectRecord>[];
      for (final planned in plannedObjects) {
        final path = p.join(planned.directory.canonicalPath, planned.leaf);
        final ExclusiveReportObject object;
        try {
          object = await planned.directory.createExclusive(planned.leaf);
        } on Object catch (error) {
          throw _StorePhaseFailure(
            ImmutableReportStorePhase.createObject,
            error,
            failedRole: planned.write.role,
          );
        }
        openObjects.add(object);
        openObjectsByRole[planned.write.role] = object;
        artifacts.add(path);
        actualPaths[planned.write.role] = path;

        final _WrittenObject written;
        try {
          written = await _writeObject(object, planned.write);
        } on _StorePhaseFailure catch (failure) {
          throw _StorePhaseFailure(
            failure.phase,
            failure.cause,
            failedRole: planned.write.role,
          );
        } on Object catch (error) {
          throw _StorePhaseFailure(
            ImmutableReportStorePhase.writeObject,
            error,
            failedRole: planned.write.role,
          );
        }
        records.add(
          ReportObjectRecord(
            role: planned.write.role,
            relativePath: planned.relativePath,
            format: planned.write.format,
            reportSchemaVersion: planned.write.reportSchemaVersion,
            byteLength: written.byteLength,
            sha256: written.sha256,
          ),
        );
      }

      completedCommit = ReportCommit(
        runId: identity.runId,
        sequence: identity.sequence,
        command: identity.command,
        completedAtUtc: identity.completedAtUtc,
        objects: records,
      );
      final commitPath = p.join(commitsDirectory.canonicalPath, commitLeaf);
      try {
        commitObject = await commitsDirectory.createExclusive(commitLeaf);
      } on Object catch (error) {
        throw _StorePhaseFailure(ImmutableReportStorePhase.createCommit, error);
      }
      artifacts.add(commitPath);
      final commitBytes = utf8.encode(completedCommit.encode());
      try {
        await commitObject.write(commitBytes);
      } on Object catch (error) {
        throw _StorePhaseFailure(ImmutableReportStorePhase.writeCommit, error);
      }
      try {
        await commitObject.flush();
      } on Object catch (error) {
        throw _StorePhaseFailure(ImmutableReportStorePhase.flushCommit, error);
      }
      try {
        final readBack = await _readAll(commitObject);
        final parsed = ReportCommit.parse(utf8.decode(readBack));
        if (parsed.encode() != completedCommit.encode()) {
          throw const FormatException('Commit read-back changed.');
        }
        await _verifyCommittedObjects(openObjectsByRole, parsed.objects);
      } on Object catch (error) {
        throw _StorePhaseFailure(ImmutableReportStorePhase.verifyCommit, error);
      }
    } on _StorePhaseFailure catch (failure, stackTrace) {
      primaryError = failure.cause;
      primaryStackTrace = stackTrace;
      primaryPhase = failure.phase;
      primaryFailedRole = failure.failedRole;
    } on Object catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
      primaryPhase = ImmutableReportStorePhase.verifyCommit;
    }

    final capabilities = <ExclusiveReportObject>[
      ...openObjects,
      if (commitObject != null) commitObject,
    ];
    for (final capability in capabilities.reversed) {
      try {
        await capability.close();
      } on Object catch (error, stackTrace) {
        if (primaryError == null) {
          primaryError = error;
          primaryStackTrace = stackTrace;
          primaryPhase = ImmutableReportStorePhase.closeCapability;
        }
      }
    }

    if (primaryError == null) {
      try {
        for (final planned in plannedObjects) {
          await planned.directory.verifyReachable();
        }
        await commitsDirectory.verifyReachable();
      } on Object catch (error, stackTrace) {
        primaryError = error;
        primaryStackTrace = stackTrace;
        primaryPhase = ImmutableReportStorePhase.verifyReachability;
      }
    }

    if (primaryError != null) {
      Error.throwWithStackTrace(
        ImmutableReportStoreException(
          phase: primaryPhase!,
          artifacts: artifacts,
          failedRole: primaryFailedRole,
          cause: primaryError,
        ),
        primaryStackTrace!,
      );
    }

    return CommittedReport(
      commit: completedCommit!,
      commitPath: p.join(commitsDirectory.canonicalPath, commitLeaf),
      actualObjectPaths: actualPaths,
    );
  }

  /// Releases both retained directory capabilities with first-error priority.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    for (final directory in [commitsDirectory, objectsDirectory]) {
      try {
        await directory.close();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(
        ImmutableReportStoreException(
          phase: ImmutableReportStorePhase.closeStore,
          artifacts: const [],
          cause: firstError,
        ),
        firstStackTrace!,
      );
    }
  }
}

List<_PlannedObject> _preflight(
  ReportCommitIdentity identity,
  List<ReportObjectWrite> writes, {
  required AnchoredReportDirectory defaultDirectory,
  required Map<String, AnchoredReportDirectory> objectDirectoryOverrides,
  required Map<String, String> objectLeafOverrides,
  required Map<String, String> recordPathOverrides,
  required String recordPathPrefix,
}) {
  if (recordPathPrefix != 'objects' && recordPathPrefix.isNotEmpty) {
    throw ArgumentError.value(
      recordPathPrefix,
      'recordPathPrefix',
      'Expected objects or an adjacent-path profile.',
    );
  }
  final planned = <_PlannedObject>[];
  final records = <ReportObjectRecord>[];
  for (final write in writes) {
    final directory = objectDirectoryOverrides[write.role] ?? defaultDirectory;
    final leaf =
        objectLeafOverrides[write.role] ??
        buildReportObjectLeaf(identity, role: write.role, format: write.format);
    validateReportObjectLeaf(leaf);
    final relativePath =
        recordPathOverrides[write.role] ??
        (recordPathPrefix.isEmpty ? leaf : '$recordPathPrefix/$leaf');
    final record = ReportObjectRecord(
      role: write.role,
      relativePath: relativePath,
      format: write.format,
      reportSchemaVersion: write.reportSchemaVersion,
      byteLength: 0,
      sha256: '0' * 64,
    );
    records.add(record);
    planned.add(_PlannedObject(write, directory, leaf, relativePath));
  }
  final writeRoles = writes.map((write) => write.role).toSet();
  final unknownOverrideRoles = {
    ...objectDirectoryOverrides.keys,
    ...objectLeafOverrides.keys,
    ...recordPathOverrides.keys,
  }.difference(writeRoles);
  if (unknownOverrideRoles.isNotEmpty) {
    throw ArgumentError.value(
      unknownOverrideRoles,
      'overrides',
      'Override references an unknown role.',
    );
  }
  ReportCommit(
    runId: identity.runId,
    sequence: identity.sequence,
    command: identity.command,
    completedAtUtc: identity.completedAtUtc,
    objects: records,
  );
  return planned;
}

/// Builds the only accepted immutable object leaf for a role and format.
String buildReportObjectLeaf(
  ReportCommitIdentity identity, {
  required String role,
  required String format,
}) {
  final sequence = identity.command == 'apply' ? '-${identity.sequence}' : '';
  final roleSuffix = role == 'primary' ? '' : '-$role';
  return '${identity.command}-${identity.runId}$sequence$roleSuffix.$format';
}

/// Builds the only accepted immutable commit leaf for [identity].
String buildReportCommitLeaf(ReportCommitIdentity identity) =>
    '${identity.runId}-${identity.sequence}.commit.json';

/// Encodes a real UTC timestamp with exactly six fractional digits.
String canonicalReportTimestamp(DateTime value) {
  final utc = value.toUtc();
  String digits(int number, int width) => number.toString().padLeft(width, '0');
  final fractionalMicros = utc.millisecond * 1000 + utc.microsecond;
  return '${digits(utc.year, 4)}-${digits(utc.month, 2)}-'
      '${digits(utc.day, 2)}T${digits(utc.hour, 2)}:'
      '${digits(utc.minute, 2)}:${digits(utc.second, 2)}.'
      '${digits(fractionalMicros, 6)}Z';
}

Future<_WrittenObject> _writeObject(
  ExclusiveReportObject object,
  ReportObjectWrite write,
) async {
  final sink = _QueuedReportStringSink(object);
  Object? formatterError;
  StackTrace? formatterStackTrace;
  try {
    write.writeTo(sink);
  } on Object catch (error, stackTrace) {
    formatterError = error;
    formatterStackTrace = stackTrace;
  }

  _WrittenObject? written;
  Object? writeError;
  StackTrace? writeStackTrace;
  try {
    written = await sink.complete();
  } on Object catch (error, stackTrace) {
    writeError = error;
    writeStackTrace = stackTrace;
  }
  if (formatterError != null) {
    Error.throwWithStackTrace(formatterError, formatterStackTrace!);
  }
  if (writeError != null) {
    Error.throwWithStackTrace(writeError, writeStackTrace!);
  }

  try {
    await object.flush();
  } on Object catch (error) {
    throw _StorePhaseFailure(ImmutableReportStorePhase.flushObject, error);
  }
  try {
    final identity = await object.identity();
    final readBack = await _digestObject(object);
    if (identity.byteLength != written!.byteLength ||
        readBack.byteLength != written.byteLength ||
        readBack.sha256 != written.sha256) {
      throw const FormatException('Object read-back changed.');
    }
  } on Object catch (error) {
    throw _StorePhaseFailure(ImmutableReportStorePhase.verifyObject, error);
  }
  return written;
}

Future<void> _verifyCommittedObjects(
  Map<String, ExclusiveReportObject> objects,
  List<ReportObjectRecord> records,
) async {
  if (objects.length != records.length) {
    throw const FormatException('Commit object count changed.');
  }
  for (final record in records) {
    final object = objects[record.role];
    if (object == null) {
      throw const FormatException('Committed object role changed.');
    }
    final identity = await object.identity();
    final digest = await _digestObject(object);
    if (identity.byteLength != record.byteLength ||
        digest.byteLength != record.byteLength ||
        digest.sha256 != record.sha256) {
      throw const FormatException('Committed object validation failed.');
    }
  }
}

Future<_WrittenObject> _digestObject(ExclusiveReportObject object) async {
  await object.rewind();
  final accumulator = _DigestAccumulator();
  final digestSink = sha256.startChunkedConversion(accumulator);
  var byteLength = 0;
  while (true) {
    final chunk = await object.read(64 * 1024);
    if (chunk.isEmpty) break;
    byteLength += chunk.length;
    digestSink.add(chunk);
  }
  digestSink.close();
  return _WrittenObject(byteLength, accumulator.value.toString());
}

Future<List<int>> _readAll(ExclusiveReportObject object) async {
  await object.rewind();
  final bytes = BytesBuilder(copy: false);
  while (true) {
    final chunk = await object.read(64 * 1024);
    if (chunk.isEmpty) break;
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

final class _QueuedReportStringSink implements StringSink {
  _QueuedReportStringSink(this._object) {
    _digestSink = sha256.startChunkedConversion(_digest);
  }

  final ExclusiveReportObject _object;
  // Closed transitively when [_digestSink] is closed by [complete].
  // ignore: close_sinks
  final _DigestAccumulator _digest = _DigestAccumulator();
  late final ByteConversionSink _digestSink;
  Future<void> _pending = Future.value();
  var _byteLength = 0;
  var _closed = false;

  @override
  void write(Object? object) => _add(utf8.encode(object.toString()));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    var first = true;
    for (final object in objects) {
      if (!first) write(separator);
      first = false;
      write(object);
    }
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
    write('\n');
  }

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  void _add(List<int> bytes) {
    if (_closed) throw StateError('Report sink is closed.');
    if (bytes.isEmpty) return;
    _pending = _pending.then((_) async {
      await _object.write(bytes);
      _digestSink.add(bytes);
      _byteLength += bytes.length;
    });
  }

  Future<_WrittenObject> complete() async {
    if (_closed) throw StateError('Report sink is already closed.');
    _closed = true;
    await _pending;
    _digestSink.close();
    return _WrittenObject(_byteLength, _digest.value.toString());
  }
}

final class _DigestAccumulator implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Digest is incomplete.'));

  @override
  void add(Digest data) {
    if (_value != null) throw StateError('Digest already completed.');
    _value = data;
  }

  @override
  void close() {
    if (_value == null) throw StateError('Digest was not completed.');
  }
}

final class _PlannedObject {
  const _PlannedObject(
    this.write,
    this.directory,
    this.leaf,
    this.relativePath,
  );

  final ReportObjectWrite write;
  final AnchoredReportDirectory directory;
  final String leaf;
  final String relativePath;
}

final class _WrittenObject {
  const _WrittenObject(this.byteLength, this.sha256);

  final int byteLength;
  final String sha256;
}

final class _StorePhaseFailure implements Exception {
  const _StorePhaseFailure(this.phase, this.cause, {this.failedRole});

  final ImmutableReportStorePhase phase;
  final Object cause;
  final String? failedRole;
}
