import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../reporting/io_report_object_backend.dart';
import '../reporting/report_object_backend.dart';
import 'clean_move_backend.dart';
import 'native/posix_clean_move_backend.dart';
import 'native/windows_clean_move_backend.dart';
import 'quarantine_clean_plan.dart';
import 'quarantine_tree_digest.dart';
import 'recoverable_clean_inspection.dart';
import 'recoverable_clean_transaction.dart';

/// Named durable protocol boundaries exposed only through constructor injection.
enum RecoverableCleanProtocolPoint {
  /// Initial transaction intent is flushed and read back.
  intentFlushed,

  /// The next target has not crossed its move boundary.
  beforeMove,

  /// The native move returned but is not yet journal-committed.
  afterMove,

  /// Namespace metadata required by the move was flushed.
  metadataFlushed,

  /// The retained destination has the planned object identity.
  retainedVerified,

  /// The retained-committed journal revision was flushed and read back.
  committedJournalFlushed,
}

/// Stable recoverable-clean store failure categories.
enum RecoverableCleanStoreFailure {
  /// Reviewed authority is incomplete or does not match the selected base.
  invalidPlan,

  /// A no-replace destination already exists.
  collision,

  /// Durable journal authority is corrupt, ambiguous, or incomplete.
  journalInvalid,

  /// Exact filesystem state cannot be reconciled automatically.
  recoveryRequired,

  /// The host cannot provide the required native capability.
  unsupportedCapability,
}

/// Sanitized failure from retained-clean persistence or recovery.
final class RecoverableCleanStoreException implements Exception {
  /// Creates a stable failure without exposing native paths or causes.
  const RecoverableCleanStoreException({
    required this.category,
    required this.operation,
    this.cause,
  });

  /// Stable failure category.
  final RecoverableCleanStoreFailure category;

  /// Stable operation token without a native path.
  final String operation;

  /// Original error retained for typed callers but omitted from [toString].
  final Object? cause;

  @override
  String toString() =>
      'Recoverable clean failed; category=${category.name}; '
      'operation=$operation';
}

/// One confirmed retained target returned by logical-clean execution.
final class RecoverableCleanExecutionTarget {
  /// Creates one confirmed retained target receipt.
  const RecoverableCleanExecutionTarget({
    required this.runId,
    required this.retainedPath,
  });

  /// Logical quarantine run identifier.
  final String runId;

  /// Canonical retained recovery path.
  final String retainedPath;
}

/// Current-process execution receipt backed by the durable journal.
final class RecoverableCleanExecutionResult {
  /// Creates an immutable execution receipt.
  RecoverableCleanExecutionResult({
    required this.operationId,
    required this.committed,
    required this.recoveryRequired,
    required List<RecoverableCleanExecutionTarget> targets,
  }) : targets = List.unmodifiable(targets);

  /// Durable operation identifier.
  final String operationId;

  /// Whether every selected target is durably retained-committed.
  final bool committed;

  /// Whether the operator must inspect durable recovery evidence.
  final bool recoveryRequired;

  /// Targets confirmed retained during this process.
  final List<RecoverableCleanExecutionTarget> targets;
}

/// Result of a no-replace retained restore.
final class RecoverableCleanRestoreResult {
  /// Creates a confirmed retained restore receipt.
  const RecoverableCleanRestoreResult({
    required this.operationId,
    required this.runId,
    required this.activePath,
  });

  /// Durable operation that owned the retained run.
  final String operationId;

  /// Restored logical run identifier.
  final String runId;

  /// Canonical active quarantine path after restoration.
  final String activePath;
}

/// Test-only observer for deterministic protocol fault injection.
typedef RecoverableCleanProtocolHook =
    void Function(RecoverableCleanProtocolPoint point);

/// Durable authority and orchestration for recoverable logical clean.
final class RecoverableCleanStore {
  /// Creates a base-local durable logical-clean store.
  RecoverableCleanStore({
    required Directory projectRoot,
    RecoverableCleanMoveBackend? moveBackend,
    ReportObjectBackend? journalBackend,
    String Function()? operationIdFactory,
    DateTime Function()? now,
    this.protocolHook,
  }) : _projectRoot = _canonicalOrAbsolute(projectRoot),
       _moveBackend = moveBackend ?? _createMoveBackend(),
       _journalBackend = journalBackend ?? createIoReportObjectBackend(),
       _operationIdFactory = operationIdFactory ?? _newOperationId,
       _now = now ?? DateTime.now;

  /// Reserved base-relative retained store root.
  static const retainedRootComponents = <String>['.clean-retained', 'v1'];
  static const _maximumJournalBytes = 1024 * 1024;

  final String _projectRoot;
  final RecoverableCleanMoveBackend _moveBackend;
  final ReportObjectBackend _journalBackend;
  final String Function() _operationIdFactory;
  final DateTime Function() _now;

  /// Optional deterministic test observer; production does not configure it.
  final RecoverableCleanProtocolHook? protocolHook;

  /// Executes one base-local logical-clean transaction.
  Future<RecoverableCleanExecutionResult> execute({
    required QuarantineCleanPlan plan,
    required Directory quarantineBase,
  }) async {
    if (plan.backend.name !=
            CleanBackendDisclosure.recoverableLogicalMove.name ||
        plan.targets.isEmpty) {
      throw const RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.invalidPlan,
        operation: 'preflight',
      );
    }
    await _reconcileIncompleteOperations(quarantineBase);
    final pending = await inspect(quarantineBases: <Directory>[quarantineBase]);
    if (pending.any(
      (inspection) =>
          inspection.state == RecoverableCleanInspectionState.active ||
          inspection.state == RecoverableCleanInspectionState.recoveryRequired,
    )) {
      throw const RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.recoveryRequired,
        operation: 'pending-operation',
      );
    }
    final operationId = _operationIdFactory();
    validateCleanPathComponent(operationId);
    AnchoredCleanBase? anchored;
    var intentDurable = false;
    var nextRevision = 0;
    late RecoverableCleanTransaction transaction;
    final retainedTargets = <RecoverableCleanExecutionTarget>[];
    try {
      anchored = await _moveBackend.anchor(quarantineBase);
      _validatePlanBase(plan, anchored.canonicalPath);
      final records =
          plan.targets
              .map((target) {
                final identity = target.rootIdentity;
                if (identity == null) {
                  throw const RecoverableCleanStoreException(
                    category: RecoverableCleanStoreFailure.invalidPlan,
                    operation: 'target-identity',
                  );
                }
                final destination = _destinationFor(
                  target.retainedDestinationComponents,
                  operationId,
                  target.runId,
                );
                return RecoverableCleanTargetRecord(
                  runId: target.runId,
                  sourceComponents: <String>[target.runId],
                  destinationComponents: destination,
                  identity: identity,
                  layoutSha256: target.layoutSha256,
                  journalRevision: target.journalRevision,
                  payloadSha256: target.payloadSha256,
                  phase: CleanTargetPhase.planned,
                );
              })
              .toList(growable: false)
            ..sort((a, b) => a.runId.compareTo(b.runId));
      final operationComponents = <String>[
        ...retainedRootComponents,
        operationId,
      ];
      await anchored.ensureDirectory(retainedRootComponents);
      await anchored.createDirectoryExclusive(operationComponents);
      await anchored.ensureDirectory(<String>[...operationComponents, 'runs']);
      final now = _now().toUtc();
      transaction = RecoverableCleanTransaction.create(
        operationId: operationId,
        projectPath: _projectRoot,
        quarantineBasePath: anchored.canonicalPath,
        quarantineBaseIdentity: anchored.identity,
        planFingerprint: plan.fingerprint,
        scope: plan.scope.name,
        targets: records,
        state: CleanTransactionState.active,
        createdAtUtc: now,
        updatedAtUtc: now,
      );
      await _publishRevision(
        anchored,
        operationComponents,
        nextRevision++,
        transaction,
      );
      intentDurable = true;
      protocolHook?.call(RecoverableCleanProtocolPoint.intentFlushed);

      var working = records;
      for (var index = 0; index < working.length; index++) {
        protocolHook?.call(RecoverableCleanProtocolPoint.beforeMove);
        final target = working[index];
        await anchored.moveDirectoryNoReplace(
          source: target.sourceComponents,
          destination: target.destinationComponents,
          expectedIdentity: target.identity,
        );
        working = _replaceTarget(
          working,
          index,
          _copyTarget(target, phase: CleanTargetPhase.moved),
        );
        protocolHook?.call(RecoverableCleanProtocolPoint.afterMove);
        transaction = _copyTransaction(
          transaction,
          targets: working,
          state: CleanTransactionState.active,
          updatedAtUtc: _now(),
        );
        await _publishRevision(
          anchored,
          operationComponents,
          nextRevision++,
          transaction,
        );
        protocolHook?.call(RecoverableCleanProtocolPoint.metadataFlushed);
        final retainedIdentity = await anchored.inspectDirectory(
          target.destinationComponents,
        );
        if (!retainedIdentity.sameObjectAs(target.identity)) {
          throw const RecoverableCleanStoreException(
            category: RecoverableCleanStoreFailure.recoveryRequired,
            operation: 'verify-retained-identity',
          );
        }
        final retainedPath = p.joinAll(<String>[
          anchored.canonicalPath,
          ...target.destinationComponents,
        ]);
        final retainedDigest = await captureQuarantineTreeDigest(
          Directory(retainedPath),
        );
        final postDigestIdentity = await anchored.inspectDirectory(
          target.destinationComponents,
        );
        if (retainedDigest.sha256 != target.layoutSha256 ||
            !postDigestIdentity.sameObjectAs(target.identity)) {
          throw const RecoverableCleanStoreException(
            category: RecoverableCleanStoreFailure.recoveryRequired,
            operation: 'verify-retained-tree',
          );
        }
        protocolHook?.call(RecoverableCleanProtocolPoint.retainedVerified);
        working = _replaceTarget(
          working,
          index,
          _copyTarget(target, phase: CleanTargetPhase.retainedCommitted),
        );
        final allCommitted = working.every(
          (item) => item.phase == CleanTargetPhase.retainedCommitted,
        );
        transaction = _copyTransaction(
          transaction,
          targets: working,
          state: allCommitted
              ? CleanTransactionState.committed
              : CleanTransactionState.active,
          updatedAtUtc: _now(),
        );
        await _publishRevision(
          anchored,
          operationComponents,
          nextRevision++,
          transaction,
        );
        protocolHook?.call(
          RecoverableCleanProtocolPoint.committedJournalFlushed,
        );
        retainedTargets.add(
          RecoverableCleanExecutionTarget(
            runId: target.runId,
            retainedPath: retainedPath,
          ),
        );
      }
      return RecoverableCleanExecutionResult(
        operationId: operationId,
        committed: true,
        recoveryRequired: false,
        targets: retainedTargets,
      );
    } on Object catch (error) {
      if (!intentDurable) {
        if (error is RecoverableCleanStoreException) rethrow;
        throw RecoverableCleanStoreException(
          category: RecoverableCleanStoreFailure.unsupportedCapability,
          operation: 'execute-before-intent',
          cause: error,
        );
      }
      if (anchored != null) {
        try {
          final observed = await _recoveryRecords(
            anchored,
            transaction.targets,
          );
          transaction = _copyTransaction(
            transaction,
            targets: observed,
            state: CleanTransactionState.recoveryRequired,
            updatedAtUtc: _now(),
          );
          await _publishRevision(
            anchored,
            <String>[...retainedRootComponents, operationId],
            nextRevision,
            transaction,
          );
        } on Object {
          // The already durable intent remains the recovery authority.
        }
      }
      return RecoverableCleanExecutionResult(
        operationId: operationId,
        committed: false,
        recoveryRequired: true,
        targets: retainedTargets,
      );
    } finally {
      if (anchored != null) {
        try {
          await anchored.close();
        } on Object {
          // A prior durable result remains authoritative.
        }
      }
    }
  }

  /// Inspects retained operations without changing their journal authority.
  Future<List<RecoverableCleanInspection>> inspect({
    required Iterable<Directory> quarantineBases,
  }) async {
    final result = <RecoverableCleanInspection>[];
    for (final base in quarantineBases) {
      if (!base.existsSync()) continue;
      AnchoredCleanBase? anchored;
      try {
        anchored = await _moveBackend.anchor(base);
        final retainedRoot = Directory(
          p.joinAll(<String>[
            anchored.canonicalPath,
            ...retainedRootComponents,
          ]),
        );
        if (!retainedRoot.existsSync()) continue;
        final entries = retainedRoot.listSync(followLinks: false)
          ..sort((a, b) => a.path.compareTo(b.path));
        for (final entry in entries) {
          final operationId = p.basename(entry.path);
          final type = FileSystemEntity.typeSync(
            entry.path,
            followLinks: false,
          );
          if (type != FileSystemEntityType.directory) {
            result.add(
              RecoverableCleanInspection(
                operationId: operationId,
                quarantineBasePath: anchored.canonicalPath,
                state: RecoverableCleanInspectionState.recoveryRequired,
                observationCode: 'invalid-operation-entry',
              ),
            );
            continue;
          }
          result.add(await _inspectOperation(anchored, operationId));
        }
      } on Object {
        result.add(
          RecoverableCleanInspection(
            operationId: 'unreadable-retained-store',
            quarantineBasePath: p.normalize(p.absolute(base.path)),
            state: RecoverableCleanInspectionState.recoveryRequired,
            observationCode: 'unreadable-retained-store',
          ),
        );
      } finally {
        if (anchored != null) {
          try {
            await anchored.close();
          } on Object {
            // Inspection is already conservative.
          }
        }
      }
    }
    return List.unmodifiable(result);
  }

  /// Restores one committed retained run through the same no-replace backend.
  Future<RecoverableCleanRestoreResult> restore({
    required Directory quarantineBase,
    required String operationId,
    required String runId,
  }) async {
    validateCleanPathComponent(operationId);
    validateCleanPathComponent(runId);
    AnchoredCleanBase? anchored;
    try {
      anchored = await _moveBackend.anchor(quarantineBase);
      final loaded = await _loadOperation(anchored, operationId);
      final transaction = loaded.transaction;
      if (transaction.state != CleanTransactionState.committed &&
          transaction.state != CleanTransactionState.partiallyRestored) {
        throw const RecoverableCleanStoreException(
          category: RecoverableCleanStoreFailure.recoveryRequired,
          operation: 'restore-preflight',
        );
      }
      final index = transaction.targets.indexWhere(
        (target) => target.runId == runId,
      );
      if (index < 0 ||
          transaction.targets[index].phase !=
              CleanTargetPhase.retainedCommitted) {
        throw const RecoverableCleanStoreException(
          category: RecoverableCleanStoreFailure.invalidPlan,
          operation: 'restore-target',
        );
      }
      final target = transaction.targets[index];
      await _verifyExactTree(
        anchored,
        target.destinationComponents,
        target,
        operation: 'restore-tree',
      );
      await anchored.moveDirectoryNoReplace(
        source: target.destinationComponents,
        destination: target.sourceComponents,
        expectedIdentity: target.identity,
      );
      final targets = _replaceTarget(
        transaction.targets,
        index,
        _copyTarget(target, phase: CleanTargetPhase.restoredCommitted),
      );
      final allRestored = targets.every(
        (item) => item.phase == CleanTargetPhase.restoredCommitted,
      );
      final updated = _copyTransaction(
        transaction,
        targets: targets,
        state: allRestored
            ? CleanTransactionState.restored
            : CleanTransactionState.partiallyRestored,
        updatedAtUtc: _now(),
      );
      await _publishRevision(
        anchored,
        <String>[...retainedRootComponents, operationId],
        loaded.nextRevision,
        updated,
      );
      return RecoverableCleanRestoreResult(
        operationId: operationId,
        runId: runId,
        activePath: p.join(anchored.canonicalPath, runId),
      );
    } on RecoverableCleanStoreException {
      rethrow;
    } on CleanMoveException catch (error) {
      throw RecoverableCleanStoreException(
        category: error.category == CleanMoveFailure.collision
            ? RecoverableCleanStoreFailure.collision
            : RecoverableCleanStoreFailure.recoveryRequired,
        operation: 'restore-move',
        cause: error,
      );
    } on Object catch (error) {
      throw RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.recoveryRequired,
        operation: 'restore',
        cause: error,
      );
    } finally {
      if (anchored != null) {
        try {
          await anchored.close();
        } on Object {
          // Restore journal or error remains authoritative.
        }
      }
    }
  }

  Future<void> _publishRevision(
    AnchoredCleanBase anchored,
    List<String> operationComponents,
    int revision,
    RecoverableCleanTransaction transaction,
  ) async {
    final operationDirectory = Directory(
      p.joinAll(<String>[anchored.canonicalPath, ...operationComponents]),
    );
    final directory = await _journalBackend.anchor(operationDirectory);
    await runWithReportCapability<void>(
      body: () async {
        final leaf = 'journal-${revision.toString().padLeft(6, '0')}.json';
        final object = await directory.createExclusive(leaf);
        await runWithReportCapability<void>(
          body: () async {
            final bytes = utf8.encode(jsonEncode(transaction.toJson()));
            if (bytes.length > _maximumJournalBytes) {
              throw const RecoverableCleanStoreException(
                category: RecoverableCleanStoreFailure.journalInvalid,
                operation: 'journal-size',
              );
            }
            await object.write(bytes);
            await object.flush();
            await object.rewind();
            final readBack = await object.read(_maximumJournalBytes + 1);
            if (!_sameBytes(bytes, readBack)) {
              throw const RecoverableCleanStoreException(
                category: RecoverableCleanStoreFailure.journalInvalid,
                operation: 'journal-readback',
              );
            }
            RecoverableCleanTransaction.fromJson(_decodeObject(readBack));
            await directory.verifyReachable();
            await anchored.flushDirectory(operationComponents);
          },
          close: object.close,
        );
      },
      close: directory.close,
    );
  }

  Future<RecoverableCleanInspection> _inspectOperation(
    AnchoredCleanBase anchored,
    String operationId,
  ) async {
    try {
      final loaded = await _loadOperation(anchored, operationId);
      final transaction = loaded.transaction;
      if (!_matchesSelectedAuthority(transaction, anchored)) {
        throw const FormatException('Base identity mismatch.');
      }
      if (transaction.state == CleanTransactionState.aborted) {
        return RecoverableCleanInspection(
          operationId: operationId,
          quarantineBasePath: anchored.canonicalPath,
          state: RecoverableCleanInspectionState.aborted,
          observationCode: 'intent-aborted',
          transaction: transaction,
        );
      }
      var sourceExpected = 0;
      var destinationExpected = 0;
      var treeMismatch = false;
      for (final target in transaction.targets) {
        final sourceMatches = await _hasIdentity(
          anchored,
          target.sourceComponents,
          target.identity,
        );
        if (sourceMatches) {
          sourceExpected++;
          treeMismatch |= !await _treeMatches(
            anchored,
            target.sourceComponents,
            target,
          );
        }
        final destinationMatches = await _hasIdentity(
          anchored,
          target.destinationComponents,
          target.identity,
        );
        if (destinationMatches) {
          destinationExpected++;
          treeMismatch |= !await _treeMatches(
            anchored,
            target.destinationComponents,
            target,
          );
        }
      }
      final count = transaction.targets.length;
      if (transaction.state == CleanTransactionState.committed &&
          sourceExpected == 0 &&
          destinationExpected == count &&
          !treeMismatch) {
        return RecoverableCleanInspection(
          operationId: operationId,
          quarantineBasePath: anchored.canonicalPath,
          state: RecoverableCleanInspectionState.retained,
          observationCode: 'retained-committed',
          transaction: transaction,
        );
      }
      if (transaction.state == CleanTransactionState.restored &&
          sourceExpected == count &&
          destinationExpected == 0 &&
          !treeMismatch) {
        return RecoverableCleanInspection(
          operationId: operationId,
          quarantineBasePath: anchored.canonicalPath,
          state: RecoverableCleanInspectionState.restored,
          observationCode: 'restored-committed',
          transaction: transaction,
        );
      }
      if (transaction.state == CleanTransactionState.partiallyRestored &&
          sourceExpected > 0 &&
          destinationExpected > 0 &&
          sourceExpected + destinationExpected == count &&
          !treeMismatch) {
        return RecoverableCleanInspection(
          operationId: operationId,
          quarantineBasePath: anchored.canonicalPath,
          state: RecoverableCleanInspectionState.partiallyRestored,
          observationCode: 'partially-restored-committed',
          transaction: transaction,
        );
      }
      if (transaction.state == CleanTransactionState.active &&
          sourceExpected == count &&
          destinationExpected == 0 &&
          !treeMismatch) {
        return RecoverableCleanInspection(
          operationId: operationId,
          quarantineBasePath: anchored.canonicalPath,
          state: RecoverableCleanInspectionState.active,
          observationCode: 'intent-active',
          transaction: transaction,
        );
      }
      final retainedUncommitted =
          sourceExpected == 0 && destinationExpected == count && !treeMismatch;
      return RecoverableCleanInspection(
        operationId: operationId,
        quarantineBasePath: anchored.canonicalPath,
        state: RecoverableCleanInspectionState.recoveryRequired,
        observationCode: retainedUncommitted
            ? 'retained-uncommitted'
            : treeMismatch
            ? 'tree-evidence-drift'
            : 'ambiguous-object-state',
        transaction: transaction,
      );
    } on Object {
      return RecoverableCleanInspection(
        operationId: operationId,
        quarantineBasePath: anchored.canonicalPath,
        state: RecoverableCleanInspectionState.recoveryRequired,
        observationCode: 'invalid-journal-authority',
      );
    }
  }

  Future<_LoadedOperation> _loadOperation(
    AnchoredCleanBase anchored,
    String operationId,
  ) async {
    validateCleanPathComponent(operationId);
    final operationPath = p.joinAll(<String>[
      anchored.canonicalPath,
      ...retainedRootComponents,
      operationId,
    ]);
    final rawType = FileSystemEntity.typeSync(
      operationPath,
      followLinks: false,
    );
    if (rawType != FileSystemEntityType.directory) {
      throw const RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.journalInvalid,
        operation: 'load-operation',
      );
    }
    final rawEntries = Directory(operationPath).listSync(followLinks: false);
    final journalEntries = <FileSystemEntity>[];
    for (final entry in rawEntries) {
      final name = p.basename(entry.path);
      if (name == 'runs' &&
          FileSystemEntity.typeSync(entry.path, followLinks: false) ==
              FileSystemEntityType.directory) {
        continue;
      }
      if (!RegExp(r'^journal-[0-9]{6}\.json$').hasMatch(name) ||
          FileSystemEntity.typeSync(entry.path, followLinks: false) !=
              FileSystemEntityType.file) {
        throw const RecoverableCleanStoreException(
          category: RecoverableCleanStoreFailure.journalInvalid,
          operation: 'load-operation-entries',
        );
      }
      journalEntries.add(entry);
    }
    journalEntries.sort((a, b) => a.path.compareTo(b.path));
    if (journalEntries.isEmpty) {
      throw const RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.journalInvalid,
        operation: 'load-journal',
      );
    }
    final directory = await _journalBackend.anchor(Directory(operationPath));
    try {
      RecoverableCleanTransaction? latest;
      for (var index = 0; index < journalEntries.length; index++) {
        final expected = 'journal-${index.toString().padLeft(6, '0')}.json';
        final leaf = p.basename(journalEntries[index].path);
        if (leaf != expected) {
          throw const RecoverableCleanStoreException(
            category: RecoverableCleanStoreFailure.journalInvalid,
            operation: 'journal-revision-gap',
          );
        }
        final object = await directory.openExisting(leaf);
        try {
          final identity = await object.identity();
          if (identity.byteLength > _maximumJournalBytes) {
            throw const FormatException('Journal too large.');
          }
          await object.rewind();
          final bytes = await object.read(_maximumJournalBytes + 1);
          if (bytes.length != identity.byteLength) {
            throw const FormatException('Journal length changed.');
          }
          final parsed = RecoverableCleanTransaction.fromJson(
            _decodeObject(bytes),
          );
          if (parsed.operationId != operationId ||
              (latest != null &&
                  (!_sameImmutableTransactionEvidence(latest, parsed) ||
                      parsed.updatedAtUtc.isBefore(latest.updatedAtUtc)))) {
            throw const FormatException('Journal authority changed.');
          }
          latest = parsed;
        } finally {
          await object.close();
        }
      }
      await directory.verifyReachable();
      return _LoadedOperation(
        transaction: latest!,
        nextRevision: journalEntries.length,
      );
    } finally {
      await directory.close();
    }
  }

  Future<List<RecoverableCleanTargetRecord>> _recoveryRecords(
    AnchoredCleanBase anchored,
    List<RecoverableCleanTargetRecord> records,
  ) async {
    final result = <RecoverableCleanTargetRecord>[];
    for (final target in records) {
      final source = await _hasIdentity(
        anchored,
        target.sourceComponents,
        target.identity,
      );
      final destination = await _hasIdentity(
        anchored,
        target.destinationComponents,
        target.identity,
      );
      result.add(
        _copyTarget(
          target,
          phase: CleanTargetPhase.recoveryRequired,
          observationCode: !source && destination
              ? 'retained-uncommitted'
              : source && !destination
              ? 'source-still-active'
              : 'ambiguous-object-state',
        ),
      );
    }
    return result;
  }

  Future<void> _reconcileIncompleteOperations(Directory quarantineBase) async {
    if (!quarantineBase.existsSync()) return;
    AnchoredCleanBase? anchored;
    try {
      anchored = await _moveBackend.anchor(quarantineBase);
      final retainedRoot = Directory(
        p.joinAll(<String>[anchored.canonicalPath, ...retainedRootComponents]),
      );
      if (!retainedRoot.existsSync()) return;
      final entries = retainedRoot.listSync(followLinks: false)
        ..sort((left, right) => left.path.compareTo(right.path));
      for (final entry in entries) {
        if (FileSystemEntity.typeSync(entry.path, followLinks: false) !=
            FileSystemEntityType.directory) {
          continue;
        }
        final operationId = p.basename(entry.path);
        try {
          validateCleanPathComponent(operationId);
          final loaded = await _loadOperation(anchored, operationId);
          if (!_matchesSelectedAuthority(loaded.transaction, anchored)) {
            continue;
          }
          await _reconcileOperation(anchored, loaded);
        } on Object {
          // Read-only inspection below exposes invalid or ambiguous authority.
        }
      }
    } finally {
      if (anchored != null) {
        try {
          await anchored.close();
        } on Object {
          // The next conservative inspection remains authoritative.
        }
      }
    }
  }

  Future<void> _reconcileOperation(
    AnchoredCleanBase anchored,
    _LoadedOperation loaded,
  ) async {
    final transaction = loaded.transaction;
    final reconciled = <RecoverableCleanTargetRecord>[];
    for (final target in transaction.targets) {
      final source = await _observeIdentity(
        anchored,
        target.sourceComponents,
        target.identity,
      );
      final destination = await _observeIdentity(
        anchored,
        target.destinationComponents,
        target.identity,
      );
      if (source == _CleanObjectObservation.expected &&
          destination == _CleanObjectObservation.absent &&
          await _treeMatches(anchored, target.sourceComponents, target)) {
        final restored =
            transaction.state == CleanTransactionState.committed ||
            transaction.state == CleanTransactionState.partiallyRestored ||
            target.phase == CleanTargetPhase.restoredCommitted;
        reconciled.add(
          _copyTarget(
            target,
            phase: restored
                ? CleanTargetPhase.restoredCommitted
                : CleanTargetPhase.abortedCommitted,
            observationCode: restored
                ? 'reconciled-restored'
                : 'reconciled-aborted',
          ),
        );
        continue;
      }
      if (source == _CleanObjectObservation.absent &&
          destination == _CleanObjectObservation.expected &&
          await _treeMatches(anchored, target.destinationComponents, target)) {
        reconciled.add(
          _copyTarget(
            target,
            phase: CleanTargetPhase.retainedCommitted,
            observationCode: 'reconciled-retained',
          ),
        );
        continue;
      }
      reconciled.add(
        _copyTarget(
          target,
          phase: CleanTargetPhase.recoveryRequired,
          observationCode: _recoveryObservation(source, destination),
        ),
      );
    }
    final state =
        reconciled.every(
          (target) => target.phase == CleanTargetPhase.retainedCommitted,
        )
        ? CleanTransactionState.committed
        : reconciled.every(
            (target) => target.phase == CleanTargetPhase.restoredCommitted,
          )
        ? CleanTransactionState.restored
        : reconciled.every(
            (target) => target.phase == CleanTargetPhase.abortedCommitted,
          )
        ? CleanTransactionState.aborted
        : reconciled.every(
            (target) =>
                target.phase == CleanTargetPhase.retainedCommitted ||
                target.phase == CleanTargetPhase.restoredCommitted ||
                target.phase == CleanTargetPhase.abortedCommitted,
          )
        ? CleanTransactionState.partiallyRestored
        : CleanTransactionState.recoveryRequired;
    if (_sameReconciledAuthority(transaction, reconciled, state)) return;
    final updated = _copyTransaction(
      transaction,
      targets: reconciled,
      state: state,
      updatedAtUtc: _now(),
    );
    await _publishRevision(
      anchored,
      <String>[...retainedRootComponents, transaction.operationId],
      loaded.nextRevision,
      updated,
    );
  }

  Future<void> _verifyExactTree(
    AnchoredCleanBase anchored,
    List<String> components,
    RecoverableCleanTargetRecord target, {
    required String operation,
  }) async {
    if (!await _treeMatches(anchored, components, target)) {
      throw RecoverableCleanStoreException(
        category: RecoverableCleanStoreFailure.recoveryRequired,
        operation: operation,
      );
    }
  }

  Future<bool> _treeMatches(
    AnchoredCleanBase anchored,
    List<String> components,
    RecoverableCleanTargetRecord target,
  ) async {
    try {
      final before = await anchored.inspectDirectory(components);
      if (!before.sameObjectAs(target.identity)) return false;
      final digest = await captureQuarantineTreeDigest(
        Directory(p.joinAll(<String>[anchored.canonicalPath, ...components])),
      );
      final after = await anchored.inspectDirectory(components);
      return after.sameObjectAs(target.identity) &&
          digest.sha256 == target.layoutSha256;
    } on Object {
      return false;
    }
  }

  bool _matchesSelectedAuthority(
    RecoverableCleanTransaction transaction,
    AnchoredCleanBase anchored,
  ) =>
      p.equals(transaction.projectPath, _projectRoot) &&
      p.equals(transaction.quarantineBasePath, anchored.canonicalPath) &&
      transaction.quarantineBaseIdentity.sameObjectAs(anchored.identity);
}

final class _LoadedOperation {
  const _LoadedOperation({
    required this.transaction,
    required this.nextRevision,
  });

  final RecoverableCleanTransaction transaction;
  final int nextRevision;
}

RecoverableCleanMoveBackend _createMoveBackend() {
  if (Platform.isLinux || Platform.isMacOS) {
    return PosixRecoverableCleanMoveBackend();
  }
  if (Platform.isWindows) return WindowsRecoverableCleanMoveBackend();
  throw const RecoverableCleanStoreException(
    category: RecoverableCleanStoreFailure.unsupportedCapability,
    operation: 'select-move-backend',
  );
}

String _newOperationId() {
  final now = DateTime.now().toUtc();
  String two(int value) => value.toString().padLeft(2, '0');
  final fraction = (now.microsecondsSinceEpoch % 1000000).toString().padLeft(
    6,
    '0',
  );
  final random = Random.secure();
  final suffix = List<int>.generate(
    8,
    (_) => random.nextInt(256),
  ).map((value) => value.toRadixString(16).padLeft(2, '0')).join();
  return 'clean-${now.year.toString().padLeft(4, '0')}'
      '${two(now.month)}${two(now.day)}T${two(now.hour)}${two(now.minute)}'
      '${two(now.second)}${fraction}Z-$suffix';
}

String _canonicalOrAbsolute(Directory directory) {
  try {
    return p.normalize(directory.absolute.resolveSymbolicLinksSync());
  } on FileSystemException {
    return p.normalize(directory.absolute.path);
  }
}

void _validatePlanBase(QuarantineCleanPlan plan, String canonicalBase) {
  if (!plan.canonicalBases.any((base) => p.equals(base, canonicalBase)) ||
      plan.targets.any(
        (target) => !p.equals(p.dirname(target.canonicalPath), canonicalBase),
      )) {
    throw const RecoverableCleanStoreException(
      category: RecoverableCleanStoreFailure.invalidPlan,
      operation: 'plan-base',
    );
  }
}

List<String> _destinationFor(
  List<String> reviewed,
  String operationId,
  String runId,
) {
  if (reviewed.length != 5 ||
      reviewed[0] != '.clean-retained' ||
      reviewed[1] != 'v1' ||
      reviewed[3] != 'runs' ||
      reviewed[4] != runId) {
    throw const RecoverableCleanStoreException(
      category: RecoverableCleanStoreFailure.invalidPlan,
      operation: 'retained-destination',
    );
  }
  return <String>['.clean-retained', 'v1', operationId, 'runs', runId];
}

RecoverableCleanTargetRecord _copyTarget(
  RecoverableCleanTargetRecord value, {
  required CleanTargetPhase phase,
  String? observationCode,
}) => RecoverableCleanTargetRecord(
  runId: value.runId,
  sourceComponents: value.sourceComponents,
  destinationComponents: value.destinationComponents,
  identity: value.identity,
  layoutSha256: value.layoutSha256,
  journalRevision: value.journalRevision,
  payloadSha256: value.payloadSha256,
  phase: phase,
  observationCode: observationCode,
);

List<RecoverableCleanTargetRecord> _replaceTarget(
  List<RecoverableCleanTargetRecord> values,
  int index,
  RecoverableCleanTargetRecord replacement,
) {
  final result = List<RecoverableCleanTargetRecord>.of(values);
  result[index] = replacement;
  return result;
}

RecoverableCleanTransaction _copyTransaction(
  RecoverableCleanTransaction value, {
  required List<RecoverableCleanTargetRecord> targets,
  required CleanTransactionState state,
  required DateTime updatedAtUtc,
}) => RecoverableCleanTransaction.create(
  operationId: value.operationId,
  projectPath: value.projectPath,
  quarantineBasePath: value.quarantineBasePath,
  quarantineBaseIdentity: value.quarantineBaseIdentity,
  planFingerprint: value.planFingerprint,
  scope: value.scope,
  targets: targets,
  state: state,
  createdAtUtc: value.createdAtUtc,
  updatedAtUtc: updatedAtUtc,
);

Future<bool> _hasIdentity(
  AnchoredCleanBase anchored,
  List<String> components,
  CleanObjectIdentity expected,
) async {
  try {
    final actual = await anchored.inspectDirectory(components);
    return actual.sameObjectAs(expected);
  } on CleanMoveException catch (error) {
    if (error.category == CleanMoveFailure.notFound) return false;
    rethrow;
  }
}

enum _CleanObjectObservation { absent, expected, different }

Future<_CleanObjectObservation> _observeIdentity(
  AnchoredCleanBase anchored,
  List<String> components,
  CleanObjectIdentity expected,
) async {
  try {
    final actual = await anchored.inspectDirectory(components);
    return actual.sameObjectAs(expected)
        ? _CleanObjectObservation.expected
        : _CleanObjectObservation.different;
  } on CleanMoveException catch (error) {
    if (error.category == CleanMoveFailure.notFound) {
      return _CleanObjectObservation.absent;
    }
    rethrow;
  }
}

String _recoveryObservation(
  _CleanObjectObservation source,
  _CleanObjectObservation destination,
) {
  if (source == _CleanObjectObservation.expected &&
      destination == _CleanObjectObservation.expected) {
    return 'both-locations-present';
  }
  if (source == _CleanObjectObservation.absent &&
      destination == _CleanObjectObservation.absent) {
    return 'both-locations-absent';
  }
  if (source == _CleanObjectObservation.different) {
    return 'active-name-reused';
  }
  if (destination == _CleanObjectObservation.different) {
    return 'retained-name-collision';
  }
  return 'tree-evidence-drift';
}

bool _sameReconciledAuthority(
  RecoverableCleanTransaction current,
  List<RecoverableCleanTargetRecord> targets,
  CleanTransactionState state,
) {
  if (current.state != state || current.targets.length != targets.length) {
    return false;
  }
  for (var index = 0; index < targets.length; index++) {
    final left = current.targets[index];
    final right = targets[index];
    if (left.phase != right.phase ||
        left.observationCode != right.observationCode) {
      return false;
    }
  }
  return true;
}

bool _sameImmutableTransactionEvidence(
  RecoverableCleanTransaction left,
  RecoverableCleanTransaction right,
) {
  if (left.operationId != right.operationId ||
      left.projectPath != right.projectPath ||
      left.quarantineBasePath != right.quarantineBasePath ||
      !left.quarantineBaseIdentity.sameObjectAs(right.quarantineBaseIdentity) ||
      left.planFingerprint != right.planFingerprint ||
      left.scope != right.scope ||
      left.createdAtUtc != right.createdAtUtc ||
      left.targets.length != right.targets.length) {
    return false;
  }
  for (var index = 0; index < left.targets.length; index++) {
    final first = left.targets[index];
    final second = right.targets[index];
    if (first.runId != second.runId ||
        !_sameStrings(first.sourceComponents, second.sourceComponents) ||
        !_sameStrings(
          first.destinationComponents,
          second.destinationComponents,
        ) ||
        !first.identity.sameObjectAs(second.identity) ||
        first.layoutSha256 != second.layoutSha256 ||
        first.journalRevision != second.journalRevision ||
        first.payloadSha256 != second.payloadSha256) {
      return false;
    }
  }
  return true;
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, dynamic> _decodeObject(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map) throw const FormatException('Expected JSON object.');
  return decoded.map((key, value) => MapEntry(key as String, value));
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
