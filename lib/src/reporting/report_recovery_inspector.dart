import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'immutable_report_store.dart';
import 'report_commit.dart';
import 'report_object_backend.dart';

/// Minimal expected identity needed to bind a commit record to generated names.
typedef ExpectedReportObject = ({
  String role,
  String format,
  int reportSchemaVersion,
});

/// Read-only recovery classification for one proposed immutable batch.
enum ReportRecoveryClassification {
  /// Exact commit, exact objects, and reachable directories all validate.
  committed,

  /// Expected objects exist without a valid commit authority.
  orphaned,

  /// An owned commit prefix exists but did not finish as canonical JSON.
  partial,

  /// A canonical owned commit references missing or changed object bytes.
  corrupt,

  /// The occupied commit path does not belong to this batch identity.
  foreign,

  /// A native capability or frozen directory reachability check failed.
  unreachable,
}

/// Immutable result of read-only recovery inspection.
final class ReportRecoveryInspection {
  /// Creates and snapshots one inspection result.
  ReportRecoveryInspection({
    required this.classification,
    required Iterable<String> artifactPaths,
    this.commit,
  }) : artifactPaths = List.unmodifiable(
         artifactPaths.toSet().toList()..sort(),
       );

  /// Conservative recovery class.
  final ReportRecoveryClassification classification;

  /// Existing artifacts observed through retained no-follow capabilities.
  final List<String> artifactPaths;

  /// Parsed exact commit only when one canonical record was available.
  final ReportCommit? commit;

  /// Whether terminal output may emit READY.
  bool get ready => classification == ReportRecoveryClassification.committed;
}

/// Classifies immutable report artifacts without exposing any mutation method.
final class ReportRecoveryInspector {
  /// Creates an inspector from independently retained directory capabilities.
  ReportRecoveryInspector({
    required this.objectsDirectory,
    required this.commitsDirectory,
  });

  /// Retained `objects/` capability.
  final AnchoredReportDirectory objectsDirectory;

  /// Retained `commits/` capability.
  final AnchoredReportDirectory commitsDirectory;

  var _closed = false;

  /// Inspects one exact generated batch identity without changing any path.
  Future<ReportRecoveryInspection> inspect({
    required ReportCommitIdentity identity,
    required List<ExpectedReportObject> expectedObjects,
  }) async {
    if (_closed) {
      return ReportRecoveryInspection(
        classification: ReportRecoveryClassification.unreachable,
        artifactPaths: const [],
      );
    }
    final expected = _expectedRecords(identity, expectedObjects);
    final artifacts = <String>[];
    final openCapabilities = <ExistingReportObject>[];
    ReportCommit? parsedCommit;
    var classification = ReportRecoveryClassification.orphaned;

    final commitLeaf = buildReportCommitLeaf(identity);
    ExistingReportObject? commitObject;
    try {
      commitObject = await commitsDirectory.openExisting(commitLeaf);
      openCapabilities.add(commitObject);
      artifacts.add(p.join(commitsDirectory.canonicalPath, commitLeaf));
    } on ReportObjectBackendException catch (error) {
      if (error.category != ReportObjectBackendFailure.notFound) {
        classification =
            error.category == ReportObjectBackendFailure.invalidObject
            ? ReportRecoveryClassification.foreign
            : ReportRecoveryClassification.unreachable;
      }
    } on Object {
      classification = ReportRecoveryClassification.unreachable;
    }

    if (commitObject == null &&
        classification == ReportRecoveryClassification.orphaned) {
      for (final entry in expected.entries) {
        try {
          final object = await objectsDirectory.openExisting(entry.value.leaf);
          openCapabilities.add(object);
          artifacts.add(
            p.join(objectsDirectory.canonicalPath, entry.value.leaf),
          );
        } on ReportObjectBackendException catch (error) {
          if (error.category != ReportObjectBackendFailure.notFound) {
            classification = ReportRecoveryClassification.unreachable;
            break;
          }
        } on Object {
          classification = ReportRecoveryClassification.unreachable;
          break;
        }
      }
    }

    if (commitObject != null) {
      List<int>? commitBytes;
      try {
        commitBytes = await _readBounded(commitObject, 4 * 1024 * 1024);
        parsedCommit = ReportCommit.parse(utf8.decode(commitBytes));
      } on Object {
        final prefix = commitBytes == null
            ? ''
            : utf8.decode(commitBytes, allowMalformed: true);
        classification = _invalidCommitClassification(prefix);
      }

      if (parsedCommit != null) {
        if (!_matchesExpectedCommit(parsedCommit, identity, expected)) {
          classification = ReportRecoveryClassification.foreign;
        } else {
          classification = ReportRecoveryClassification.committed;
          for (final record in parsedCommit.objects) {
            final expectedObject = expected[record.role]!;
            try {
              final object = await objectsDirectory.openExisting(
                expectedObject.leaf,
              );
              openCapabilities.add(object);
              artifacts.add(
                p.join(objectsDirectory.canonicalPath, expectedObject.leaf),
              );
              final identity = await object.identity();
              final digest = await _digestExisting(object);
              if (identity.byteLength != record.byteLength ||
                  digest.byteLength != record.byteLength ||
                  digest.sha256 != record.sha256) {
                classification = ReportRecoveryClassification.corrupt;
                break;
              }
            } on ReportObjectBackendException catch (error) {
              classification =
                  error.category == ReportObjectBackendFailure.notFound ||
                      error.category == ReportObjectBackendFailure.invalidObject
                  ? ReportRecoveryClassification.corrupt
                  : ReportRecoveryClassification.unreachable;
              break;
            } on Object {
              classification = ReportRecoveryClassification.unreachable;
              break;
            }
          }
        }
      }
    }

    for (final capability in openCapabilities.reversed) {
      try {
        await capability.close();
      } on Object {
        classification = ReportRecoveryClassification.unreachable;
      }
    }
    try {
      await objectsDirectory.verifyReachable();
      await commitsDirectory.verifyReachable();
    } on Object {
      classification = ReportRecoveryClassification.unreachable;
    }

    return ReportRecoveryInspection(
      classification: classification,
      artifactPaths: artifacts,
      commit: parsedCommit,
    );
  }

  /// Releases retained directory capabilities without mutating artifacts.
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
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}

ReportRecoveryClassification _invalidCommitClassification(String source) {
  final ownedPrefix = source.startsWith(
    '{"magic":"flutter_pruner_report_commit"',
  );
  if (!ownedPrefix) return ReportRecoveryClassification.foreign;
  try {
    final decoded = jsonDecode(source);
    if (decoded is Map<String, Object?> &&
        decoded['magic'] == 'flutter_pruner_report_commit') {
      return ReportRecoveryClassification.corrupt;
    }
  } on FormatException {
    return ReportRecoveryClassification.partial;
  }
  return ReportRecoveryClassification.corrupt;
}

Map<String, ({String leaf, ExpectedReportObject object})> _expectedRecords(
  ReportCommitIdentity identity,
  List<ExpectedReportObject> expectedObjects,
) {
  final result = <String, ({String leaf, ExpectedReportObject object})>{};
  for (final object in expectedObjects) {
    final leaf = buildReportObjectLeaf(
      identity,
      role: object.role,
      format: object.format,
    );
    validateReportObjectLeaf(leaf);
    if (result.containsKey(object.role)) {
      throw ArgumentError.value(
        object.role,
        'expectedObjects',
        'Duplicate role.',
      );
    }
    result[object.role] = (leaf: leaf, object: object);
  }
  if (result.isEmpty) {
    throw ArgumentError.value(result, 'expectedObjects', 'Cannot be empty.');
  }
  return result;
}

bool _matchesExpectedCommit(
  ReportCommit commit,
  ReportCommitIdentity identity,
  Map<String, ({String leaf, ExpectedReportObject object})> expected,
) {
  if (commit.runId != identity.runId ||
      commit.sequence != identity.sequence ||
      commit.command != identity.command ||
      commit.completedAtUtc != identity.completedAtUtc ||
      commit.objects.length != expected.length) {
    return false;
  }
  for (final record in commit.objects) {
    final expectedRecord = expected[record.role];
    if (expectedRecord == null ||
        record.relativePath != 'objects/${expectedRecord.leaf}' ||
        record.format != expectedRecord.object.format ||
        record.reportSchemaVersion !=
            expectedRecord.object.reportSchemaVersion) {
      return false;
    }
  }
  return true;
}

Future<List<int>> _readBounded(
  ExistingReportObject object,
  int maximumLength,
) async {
  await object.rewind();
  final bytes = BytesBuilder(copy: false);
  while (true) {
    final chunk = await object.read(64 * 1024);
    if (chunk.isEmpty) break;
    if (bytes.length + chunk.length > maximumLength) {
      throw const FormatException('Commit exceeds recovery inspection bound.');
    }
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

Future<_RecoveredDigest> _digestExisting(ExistingReportObject object) async {
  await object.rewind();
  final accumulator = _RecoveryDigestAccumulator();
  final sink = sha256.startChunkedConversion(accumulator);
  var byteLength = 0;
  while (true) {
    final chunk = await object.read(64 * 1024);
    if (chunk.isEmpty) break;
    byteLength += chunk.length;
    sink.add(chunk);
  }
  sink.close();
  return _RecoveredDigest(byteLength, accumulator.value.toString());
}

final class _RecoveryDigestAccumulator implements Sink<Digest> {
  Digest? _value;

  Digest get value => _value ?? (throw StateError('Digest is incomplete.'));

  @override
  void add(Digest data) => _value = data;

  @override
  void close() {
    if (_value == null) throw StateError('Digest was not completed.');
  }
}

final class _RecoveredDigest {
  const _RecoveredDigest(this.byteLength, this.sha256);

  final int byteLength;
  final String sha256;
}
