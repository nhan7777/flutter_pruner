import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../apply/finding_selection.dart';
import '../core/process/managed_process_runner.dart';
import '../core/project/tool_workspace.dart';
import 'manifest.dart';

/// Manages quarantine directories for reversible file operations.
///
/// V1 moves whole files, V2 adds case snapshots, and V3 journals atomic
/// transactions with mandatory verification evidence.
class QuarantineManager {
  /// Creates a quarantine manager for [projectRoot].
  QuarantineManager(
    this.projectRoot, {
    QuarantineDisplacementHook? displacementHook,
    QuarantineRestoreHook? restoreHook,
    QuarantineSourceRenamer? sourceRenamer,
    ProcessExecutionRunner atomicPublishProcessRunner =
        const ManagedProcessRunner(),
    ProcessExecutionRunner permissionProcessRunner =
        const ManagedProcessRunner(),
  }) : _displacementHook = displacementHook,
       _restoreHook = restoreHook,
       _sourceRenamer = sourceRenamer ?? _renameSource,
       _atomicPublishProcessRunner = atomicPublishProcessRunner,
       _permissionProcessRunner = permissionProcessRunner;

  /// Project root directory.
  final Directory projectRoot;

  final QuarantineDisplacementHook? _displacementHook;
  final QuarantineRestoreHook? _restoreHook;
  final QuarantineSourceRenamer _sourceRenamer;
  final ProcessExecutionRunner _atomicPublishProcessRunner;
  final ProcessExecutionRunner _permissionProcessRunner;

  static Future<File> _renameSource(File source, String destination) =>
      source.rename(destination);

  /// Default quarantine base directory.
  static const String defaultQuarantineDir =
      ToolWorkspace.quarantineRelativePath;

  /// Previous default retained so recovery commands can find older runs.
  static const String legacyQuarantineDir =
      ToolWorkspace.legacyQuarantineRelativePath;

  /// Creates a new quarantine for the given run ID and entries.
  ///
  /// Returns the quarantine directory. Throws if quarantine already exists.
  Future<Directory> createQuarantine({
    required String runId,
    required List<QuarantineEntry> entries,
    String quarantineBase = defaultQuarantineDir,
    bool caseJournal = false,
    bool transactionJournal = false,
    String? verificationPolicyHash,
    QuarantineVerificationEvidence? baselineVerification,
    String? analysisMode,
    List<String> acceptedRiskCodes = const [],
    String? riskAcceptanceSource,
    QuarantineSelectionEvidence? selection,
  }) async {
    if (selection != null && !transactionJournal) {
      throw QuarantineException(
        'Apply selection evidence requires a V3 transaction journal.',
      );
    }
    validateRunId(runId);
    final quarantineDir = Directory(
      p.join(_resolveQuarantineBase(quarantineBase), runId),
    );

    if (quarantineDir.existsSync()) {
      throw QuarantineException(
        'Quarantine already exists: ${quarantineDir.path}',
      );
    }

    await quarantineDir.create(recursive: true);

    // Create manifest
    final manifest = QuarantineManifest(
      runId: runId,
      timestamp: DateTime.now(),
      projectRoot: p.normalize(p.absolute(projectRoot.path)),
      entries: entries,
      caseJournal: caseJournal,
      transactionJournal: transactionJournal,
      verificationPolicyHash: verificationPolicyHash,
      baselineVerification: baselineVerification,
      analysisMode: analysisMode,
      acceptedRiskCodes: List.unmodifiable(acceptedRiskCodes),
      riskAcceptanceSource: riskAcceptanceSource,
      selection: selection,
    );

    await _writeManifest(
      quarantineDir,
      manifest,
      runLifecycleState: transactionJournal
          ? QuarantineRunLifecycleState.active
          : null,
    );

    return quarantineDir;
  }

  /// Creates an empty V2/V3 quarantine populated by cases and transactions.
  Future<Directory> createCaseQuarantine({
    required String runId,
    String quarantineBase = defaultQuarantineDir,
    String? verificationPolicyHash,
    QuarantineVerificationEvidence? baselineVerification,
    String? analysisMode,
    List<String> acceptedRiskCodes = const [],
    String? riskAcceptanceSource,
    QuarantineSelectionEvidence? selection,
  }) => createQuarantine(
    runId: runId,
    entries: const [],
    quarantineBase: quarantineBase,
    caseJournal: true,
    transactionJournal: verificationPolicyHash != null,
    verificationPolicyHash: verificationPolicyHash,
    baselineVerification: baselineVerification,
    analysisMode: analysisMode,
    acceptedRiskCodes: acceptedRiskCodes,
    riskAcceptanceSource: riskAcceptanceSource,
    selection: selection,
  );

  /// Declares a V3 transaction before any owned case mutates the project.
  Future<QuarantineTransaction> beginTransaction({
    required Directory quarantineDir,
    required String transactionId,
    required int round,
    required String componentId,
    required List<String> findingIds,
    required List<String> caseIds,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(transactionId)) {
      throw QuarantineException('Invalid transaction ID: $transactionId');
    }
    if (findingIds.isEmpty ||
        caseIds.isEmpty ||
        findingIds.toSet().length != findingIds.length ||
        caseIds.toSet().length != caseIds.length) {
      throw QuarantineException(
        'Transaction $transactionId must declare unique findings and cases.',
      );
    }
    final manifest = await _readManifest(quarantineDir);
    final selection = manifest.selection;
    if (selection?.mode == FindingSelectionMode.exact) {
      final unauthorized = findingIds.toSet().difference(
        selection!.requestedFindingIds.toSet(),
      );
      if (unauthorized.isNotEmpty) {
        throw QuarantineException(
          'Transaction $transactionId contains finding IDs outside the '
          'persisted exact selection: ${unauthorized.toList()..sort()}.',
        );
      }
    }
    if (manifest.transactions.any(
      (item) => item.transactionId == transactionId,
    )) {
      throw QuarantineException('Transaction already exists: $transactionId');
    }
    final ownedFindingIds = manifest.transactions
        .expand((transaction) => transaction.findingIds)
        .toSet();
    final duplicateFindingOwnership = findingIds.toSet().intersection(
      ownedFindingIds,
    );
    if (duplicateFindingOwnership.isNotEmpty) {
      throw QuarantineException(
        'Findings already owned by another transaction: '
        '${duplicateFindingOwnership.toList()..sort()}.',
      );
    }
    final ownedCaseIds = manifest.transactions
        .expand((transaction) => transaction.caseIds)
        .toSet();
    final duplicateOwnership = caseIds.toSet().intersection(ownedCaseIds);
    if (duplicateOwnership.isNotEmpty) {
      throw QuarantineException(
        'Cases already owned by another transaction: '
        '${duplicateOwnership.join(', ')}',
      );
    }
    final transaction = QuarantineTransaction(
      transactionId: transactionId,
      round: round,
      componentId: componentId,
      findingIds: List.unmodifiable(findingIds),
      caseIds: List.unmodifiable(caseIds),
      status: QuarantineTransactionStatus.pending,
      verificationPolicyHash: manifest.verificationPolicyHash,
    );
    await _writeManifest(
      quarantineDir,
      _copyManifest(
        manifest,
        transactions: [...manifest.transactions, transaction],
      ),
    );
    return transaction;
  }

  /// Records that every case in a V3 transaction has been applied.
  Future<QuarantineTransaction> recordTransactionApplied({
    required Directory quarantineDir,
    required String transactionId,
    required List<String> caseIds,
  }) async {
    final manifest = await _readManifest(quarantineDir);
    final transaction = _transactionById(manifest, transactionId);
    _requireTransactionStatus(transaction, const {
      QuarantineTransactionStatus.pending,
    });
    if (caseIds.toSet().length != caseIds.length ||
        transaction.caseIds.toSet().difference(caseIds.toSet()).isNotEmpty ||
        caseIds.toSet().difference(transaction.caseIds.toSet()).isNotEmpty) {
      throw QuarantineException(
        'Applied cases do not match transaction $transactionId.',
      );
    }
    final casesById = {for (final item in manifest.cases) item.caseId: item};
    for (final caseId in caseIds) {
      if (casesById[caseId]?.status != QuarantineCaseStatus.applied) {
        throw QuarantineException(
          'Transaction $transactionId contains a case that is not applied: '
          '$caseId',
        );
      }
    }
    return _updateTransaction(
      quarantineDir,
      transactionId,
      (item) => item.withState(status: QuarantineTransactionStatus.applied),
    );
  }

  /// Records complete verification evidence for an accepted transaction.
  Future<QuarantineTransaction> verifyTransaction({
    required Directory quarantineDir,
    required String transactionId,
    required String policyHash,
    required List<String> requiredStepIds,
    required List<String> observedStepIds,
  }) => _updateTransaction(quarantineDir, transactionId, (transaction) {
    _requireTransactionStatus(transaction, const {
      QuarantineTransactionStatus.applied,
    });
    _validateVerificationEvidence(
      transaction: transaction,
      policyHash: policyHash,
      requiredStepIds: requiredStepIds,
      observedStepIds: observedStepIds,
    );
    return transaction.withState(
      status: QuarantineTransactionStatus.verified,
      verificationPolicyHash: policyHash,
      requiredStepIds: List.unmodifiable(requiredStepIds),
      observedStepIds: List.unmodifiable(observedStepIds),
    );
  });

  /// Atomically commits a verified transaction and all of its case states.
  Future<QuarantineTransaction> commitTransaction({
    required Directory quarantineDir,
    required String transactionId,
  }) async {
    final document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    _requireV3PosixModeEvidence(manifest);
    final transactionIndex = manifest.transactions.indexWhere(
      (transaction) => transaction.transactionId == transactionId,
    );
    if (transactionIndex == -1) {
      throw QuarantineException('Transaction not found: $transactionId');
    }
    final transaction = manifest.transactions[transactionIndex];
    if (transaction.status != QuarantineTransactionStatus.verified) {
      throw QuarantineException(
        'Cannot commit transaction $transactionId from state '
        '${transaction.status.name}',
      );
    }
    final ownedCaseIds = transaction.caseIds.toSet();
    final casesById = {for (final item in manifest.cases) item.caseId: item};
    final lastOwnedCaseByPath = <String, String>{};
    for (final applyCase in manifest.cases) {
      if (ownedCaseIds.contains(applyCase.caseId)) {
        lastOwnedCaseByPath[applyCase.entry.originalPath] = applyCase.caseId;
      }
    }
    for (final displacement in document.caseDisplacements.where(
      (item) => ownedCaseIds.contains(item.caseId),
    )) {
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null) {
        throw QuarantineException(
          'Displacement references a missing case: ${displacement.caseId}.',
        );
      }
      await _validateDisplacedAppliedCase(
        quarantineDir: quarantineDir,
        applyCase: applyCase,
        displacement: displacement,
        validateOutput:
            lastOwnedCaseByPath[applyCase.entry.originalPath] ==
            applyCase.caseId,
      );
    }
    final cases = manifest.cases.map((applyCase) {
      if (!ownedCaseIds.contains(applyCase.caseId)) return applyCase;
      if (applyCase.status != QuarantineCaseStatus.applied) {
        throw QuarantineException(
          'Cannot commit case ${applyCase.caseId} from state '
          '${applyCase.status.name}',
        );
      }
      return applyCase.withStatus(QuarantineCaseStatus.kept);
    }).toList();
    if (cases.where((item) => ownedCaseIds.contains(item.caseId)).length !=
        ownedCaseIds.length) {
      throw QuarantineException(
        'Transaction $transactionId references a missing case.',
      );
    }
    final committed = transaction.withState(
      status: QuarantineTransactionStatus.committed,
    );
    final transactions = [...manifest.transactions];
    transactions[transactionIndex] = committed;
    final displacements = document.caseDisplacements.map((item) {
      if (!ownedCaseIds.contains(item.caseId)) return item;
      return item.withState(_CaseDisplacementState.committed);
    }).toList();
    await _writeManifest(
      quarantineDir,
      _copyManifest(manifest, cases: cases, transactions: transactions),
      caseDisplacements: displacements,
    );
    return committed;
  }

  /// Records that an atomic transaction was restored and re-verified.
  Future<QuarantineTransaction> rollbackTransaction({
    required Directory quarantineDir,
    required String transactionId,
    required String reason,
    required String policyHash,
    required List<String> requiredStepIds,
    required List<String> observedStepIds,
  }) => _updateTransaction(quarantineDir, transactionId, (transaction) {
    _requireTransactionStatus(transaction, const {
      QuarantineTransactionStatus.pending,
      QuarantineTransactionStatus.applied,
      QuarantineTransactionStatus.verified,
    });
    _validateVerificationEvidence(
      transaction: transaction,
      policyHash: policyHash,
      requiredStepIds: requiredStepIds,
      observedStepIds: observedStepIds,
    );
    return transaction.withState(
      status: QuarantineTransactionStatus.rolledBackVerified,
      verificationPolicyHash: policyHash,
      requiredStepIds: List.unmodifiable(requiredStepIds),
      observedStepIds: List.unmodifiable(observedStepIds),
      rollbackVerified: true,
      failureReason: reason,
    );
  });

  /// Marks a transaction whose bytes or verification could not be recovered.
  Future<QuarantineTransaction> requireTransactionRecovery({
    required Directory quarantineDir,
    required String transactionId,
    required String reason,
  }) => _updateTransaction(quarantineDir, transactionId, (transaction) {
    _requireTransactionStatus(transaction, const {
      QuarantineTransactionStatus.pending,
      QuarantineTransactionStatus.applied,
      QuarantineTransactionStatus.verified,
    });
    return transaction.withState(
      status: QuarantineTransactionStatus.recoveryRequired,
      failureReason: reason,
    );
  });

  /// Snapshots the current file state and journals one apply case.
  Future<QuarantineCase> beginCase({
    required Directory quarantineDir,
    required String caseId,
    required String findingId,
    required File file,
    required QuarantineOperationType operationType,
    List<String>? declarationIds,
    String? expectedSha256,
    int? expectedPosixMode,
    bool restart = false,
    String? transactionId,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(caseId)) {
      throw QuarantineException('Invalid case ID: $caseId');
    }
    _validateSnapshotSource(file);

    final relativePath = _relativeProjectPath(file.path);
    final beforeSha256 = await _computeSha256(file);
    final beforePosixMode = _readPosixMode(file);
    if (expectedSha256 != null &&
        expectedSha256.isNotEmpty &&
        expectedSha256 != beforeSha256) {
      throw QuarantineException(
        'File changed since scan: ${file.path}\n'
        'Expected SHA-256: $expectedSha256\n'
        'Actual SHA-256: $beforeSha256',
      );
    }
    if (expectedPosixMode != null && expectedPosixMode != beforePosixMode) {
      throw QuarantineException(
        'File permissions changed since scan: ${file.path}\n'
        'Expected POSIX mode: ${_formatPosixMode(expectedPosixMode)}\n'
        'Actual POSIX mode: ${_formatPosixMode(beforePosixMode)}',
      );
    }

    final manifest = await _readManifest(quarantineDir);
    if (manifest.usesTransactionJournal && transactionId == null) {
      throw QuarantineException(
        'A V3 case must be owned by a declared transaction.',
      );
    }
    if (transactionId != null) {
      final transaction = _transactionById(manifest, transactionId);
      _requireTransactionStatus(transaction, const {
        QuarantineTransactionStatus.pending,
      });
      if (!transaction.caseIds.contains(caseId)) {
        throw QuarantineException(
          'Case $caseId is not declared by transaction $transactionId.',
        );
      }
    }
    final existingIndex = manifest.cases.indexWhere(
      (item) => item.caseId == caseId,
    );
    if (existingIndex != -1 && !restart) {
      throw QuarantineException('Case already exists: $caseId');
    }
    if (existingIndex != -1 &&
        manifest.cases[existingIndex].status !=
            QuarantineCaseStatus.rolledBack &&
        manifest.cases[existingIndex].status != QuarantineCaseStatus.failed) {
      throw QuarantineException(
        'Cannot restart case $caseId from state '
        '${manifest.cases[existingIndex].status.name}',
      );
    }

    final snapshot = _caseSnapshotFile(quarantineDir, caseId, relativePath);
    await snapshot.parent.create(recursive: true);
    await _copyFileFlushed(
      file,
      snapshot,
      exclusive: true,
      expectedPosixMode: beforePosixMode,
    );
    if (await _computeSha256(snapshot) != beforeSha256 ||
        _readPosixMode(snapshot) != beforePosixMode) {
      throw QuarantineException('Case snapshot corrupted: ${snapshot.path}');
    }
    _validateSnapshotSource(file);
    if (await _computeSha256(file) != beforeSha256 ||
        _readPosixMode(file) != beforePosixMode) {
      throw QuarantineException(
        'File changed while its snapshot was being persisted: ${file.path}',
      );
    }

    final applyCase = QuarantineCase(
      caseId: caseId,
      findingId: findingId,
      entry: QuarantineEntry(
        originalPath: file.path,
        sha256: beforeSha256,
        sizeBytes: file.lengthSync(),
        posixMode: beforePosixMode,
        operationType: operationType,
        declarationIds: declarationIds,
      ),
      status: QuarantineCaseStatus.backedUp,
      transactionId: transactionId,
    );
    final cases = [...manifest.cases];
    if (existingIndex == -1) {
      cases.add(applyCase);
    } else {
      cases[existingIndex] = applyCase;
    }
    await _writeManifest(quarantineDir, _copyManifest(manifest, cases: cases));
    return applyCase;
  }

  /// Journals and atomically displaces one source before candidate mutation.
  ///
  /// The source inode itself becomes the authoritative case backup. Candidate
  /// edits happen at a separate tool-owned path and are installed only through
  /// an exclusive create, so a recreated project path is never overwritten.
  Future<QuarantinePreparedCase> beginDisplacedCase({
    required Directory quarantineDir,
    required String caseId,
    required String findingId,
    required File file,
    required QuarantineOperationType operationType,
    required String expectedSha256,
    int? expectedPosixMode,
    List<String>? declarationIds,
    String? transactionId,
  }) async {
    if (expectedSha256.isEmpty) {
      throw QuarantineException(
        'Atomic displacement requires an analysis-bound SHA-256.',
      );
    }
    final applyCase = await beginCase(
      quarantineDir: quarantineDir,
      caseId: caseId,
      findingId: findingId,
      file: file,
      operationType: operationType,
      declarationIds: declarationIds,
      expectedSha256: expectedSha256,
      expectedPosixMode: expectedPosixMode,
      transactionId: transactionId,
    );
    final promotedBackup = _caseSnapshotFor(quarantineDir, applyCase);
    final safetyCopy = _caseSafetyFile(quarantineDir, applyCase);
    final candidate = _caseCandidateFile(
      applyCase,
      runId: (await _readManifest(quarantineDir)).runId,
    );
    _requireAbsentPath(safetyCopy.path, label: 'case safety copy');
    _requireAbsentPath(candidate.path, label: 'case candidate');

    var document = await _resolveManifestDocument(quarantineDir);
    if (document.caseDisplacements.any((item) => item.caseId == caseId)) {
      throw QuarantineException('Case displacement already exists: $caseId');
    }
    final intent = _CaseDisplacementDocument(
      caseId: caseId,
      expectedSha256: expectedSha256,
      state: _CaseDisplacementState.intent,
    );
    await _writeManifest(
      quarantineDir,
      document.manifest,
      caseDisplacements: [...document.caseDisplacements, intent],
    );

    await safetyCopy.parent.create(recursive: true);
    try {
      await promotedBackup.rename(safetyCopy.path);
    } on FileSystemException catch (error) {
      await _markDisplacementRecoveryRequired(quarantineDir, caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Could not stage the immutable pre-displacement copy for $caseId: '
        '$error',
      );
    }

    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.beforeSourceRename,
      caseId: caseId,
      source: file,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    try {
      await _sourceRenamer(file, promotedBackup.path);
    } on FileSystemException catch (error) {
      await _markDisplacementRecoveryRequired(quarantineDir, caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Atomic source displacement failed for ${file.path}; no copy-delete '
        'fallback was attempted. $error',
      );
    }

    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.afterSourceRename,
      caseId: caseId,
      source: file,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    final sourceType = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (sourceType != FileSystemEntityType.notFound) {
      await _markDisplacementRecoveryRequired(quarantineDir, caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'The source path was recreated during displacement: ${file.path}. '
        'Both copies were preserved.',
      );
    }
    final promotedHash = await _hashRequiredRegularFile(
      promotedBackup,
      label: 'promoted backup',
    );
    final promotedPosixMode = _readPosixMode(promotedBackup);
    if (promotedHash != expectedSha256 ||
        promotedPosixMode != applyCase.entry.posixMode) {
      await _preserveMismatchedPromotedBackup(
        quarantineDir: quarantineDir,
        applyCase: applyCase,
        promotedBackup: promotedBackup,
        source: file,
      );
      await _markDisplacementRecoveryRequired(quarantineDir, caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Source bytes changed before atomic displacement: ${file.path}. '
        'The changed bytes and permissions were preserved without overwriting '
        'the source.',
      );
    }

    await _replaceDisplacement(
      quarantineDir,
      intent.withState(_CaseDisplacementState.promoted),
    );
    await _copyFileFlushed(
      promotedBackup,
      candidate,
      exclusive: true,
      expectedPosixMode: applyCase.entry.posixMode,
    );
    if (await _computeSha256(candidate) != expectedSha256 ||
        _readPosixMode(candidate) != applyCase.entry.posixMode) {
      await _markDisplacementRecoveryRequired(quarantineDir, caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Candidate preparation hash mismatch for ${file.path}.',
      );
    }
    await _replaceDisplacement(
      quarantineDir,
      intent.withState(_CaseDisplacementState.candidatePrepared),
    );
    document = await _resolveManifestDocument(quarantineDir);
    final currentCase = document.manifest.cases.firstWhere(
      (item) => item.caseId == caseId,
    );
    return QuarantinePreparedCase(
      applyCase: currentCase,
      candidate: candidate,
      promotedBackup: promotedBackup,
    );
  }

  /// Returns the authoritative promoted backup for a displaced case.
  Future<File?> promotedBackupForCase({
    required Directory quarantineDir,
    required String caseId,
  }) async {
    final document = await _resolveManifestDocument(quarantineDir);
    final hasDisplacement = document.caseDisplacements.any(
      (item) => item.caseId == caseId,
    );
    if (!hasDisplacement) return null;
    final applyCase = document.manifest.cases.firstWhere(
      (item) => item.caseId == caseId,
    );
    return _caseSnapshotFor(quarantineDir, applyCase);
  }

  /// Records the exact working-copy state produced by one case.
  Future<QuarantineCase> recordCaseApplied({
    required Directory quarantineDir,
    required String caseId,
  }) async {
    final document = await _resolveManifestDocument(quarantineDir);
    final applyCase = document.manifest.cases.firstWhere(
      (item) => item.caseId == caseId,
      orElse: () => throw QuarantineException('Case not found: $caseId'),
    );
    _CaseDisplacementDocument? displacement;
    for (final item in document.caseDisplacements) {
      if (item.caseId == caseId) {
        displacement = item;
        break;
      }
    }
    if (displacement != null) {
      return _installDisplacedCandidate(
        quarantineDir: quarantineDir,
        document: document,
        applyCase: applyCase,
        displacement: displacement,
      );
    }
    final target = File(applyCase.entry.originalPath);
    final afterSha256 = target.existsSync()
        ? await _computeSha256(target)
        : null;
    return _replaceCase(quarantineDir, applyCase.withAppliedHash(afterSha256));
  }

  Future<QuarantineCase> _installDisplacedCandidate({
    required Directory quarantineDir,
    required _ManifestDocument document,
    required QuarantineCase applyCase,
    required _CaseDisplacementDocument displacement,
  }) async {
    if (displacement.state != _CaseDisplacementState.candidatePrepared) {
      throw QuarantineException(
        'Cannot install displaced case ${applyCase.caseId} from state '
        '${displacement.state.name}.',
      );
    }
    final promotedBackup = _caseSnapshotFor(quarantineDir, applyCase);
    await _requirePromotedBackupHash(
      promotedBackup,
      displacement,
      expectedPosixMode: applyCase.entry.posixMode,
    );
    final candidate = _caseCandidateFile(
      applyCase,
      runId: document.manifest.runId,
    );
    final candidateType = FileSystemEntity.typeSync(
      candidate.path,
      followLinks: false,
    );
    if (candidateType != FileSystemEntityType.notFound &&
        candidateType != FileSystemEntityType.file) {
      await _markDisplacementRecoveryRequired(quarantineDir, applyCase.caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Case candidate is no longer a regular file: ${candidate.path}.',
      );
    }
    if (candidateType == FileSystemEntityType.file) {
      await _setAndVerifyPosixMode(candidate, applyCase.entry.posixMode);
    }
    final candidateSha256 = candidateType == FileSystemEntityType.file
        ? await _computeSha256(candidate)
        : null;
    final installing = displacement.withState(
      _CaseDisplacementState.installing,
      candidateSha256: candidateSha256,
    );
    await _replaceDisplacement(quarantineDir, installing);

    final target = File(applyCase.entry.originalPath);
    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.beforeCandidateInstall,
      caseId: applyCase.caseId,
      source: target,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    final targetType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.notFound) {
      await _markDisplacementRecoveryRequired(quarantineDir, applyCase.caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'The source path was recreated before candidate installation: '
        '${target.path}. The recreated source and promoted backup were '
        'preserved.',
      );
    }
    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.afterCandidateTargetPreflight,
      caseId: applyCase.caseId,
      source: target,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    if (candidateSha256 != null) {
      try {
        await _publishFileNoReplace(
          prepared: candidate,
          target: target,
          expectedSha256: candidateSha256,
          expectedPosixMode: applyCase.entry.posixMode,
        );
      } on _AtomicPublishException catch (error) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          applyCase.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Atomic no-replace candidate installation failed for '
          '${target.path}. The prepared inode and every observed target were '
          'preserved. $error',
        );
      }
    }
    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.afterCandidateInstall,
      caseId: applyCase.caseId,
      source: target,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    final installedType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    final installedSha256 = installedType == FileSystemEntityType.file
        ? await _computeSha256(target)
        : null;
    final installedPosixMode = installedType == FileSystemEntityType.file
        ? _readPosixMode(target)
        : null;
    final installedShapeMatches = candidateSha256 == null
        ? installedType == FileSystemEntityType.notFound
        : installedType == FileSystemEntityType.file;
    if (!installedShapeMatches ||
        installedSha256 != candidateSha256 ||
        (candidateSha256 != null &&
            installedPosixMode != applyCase.entry.posixMode)) {
      await _markDisplacementRecoveryRequired(quarantineDir, applyCase.caseId);
      throw QuarantineDisplacementRecoveryRequiredException(
        'Installed candidate changed concurrently: ${target.path}. '
        'Automatic rollback was not attempted.',
      );
    }
    await _requirePromotedBackupHash(
      promotedBackup,
      displacement,
      expectedPosixMode: applyCase.entry.posixMode,
    );

    final applied = applyCase.withAppliedHash(candidateSha256);
    await _replaceCaseAndDisplacement(
      quarantineDir,
      replacementCase: applied,
      replacementDisplacement: installing.withState(
        _CaseDisplacementState.installed,
      ),
    );
    await _invokeDisplacementHook(
      QuarantineDisplacementPoint.afterCandidateJournal,
      caseId: applyCase.caseId,
      source: target,
      promotedBackup: promotedBackup,
      candidate: candidate,
    );
    if (candidate.existsSync()) {
      if (await _computeSha256(candidate) != candidateSha256 ||
          _readPosixMode(candidate) != applyCase.entry.posixMode) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          applyCase.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Candidate changed before cleanup: ${candidate.path}.',
        );
      }
      try {
        await candidate.delete();
      } on FileSystemException catch (error) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          applyCase.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Installed candidate staging could not be removed: $error',
        );
      }
    }
    return applied;
  }

  /// Marks a successfully verified case as kept.
  Future<QuarantineCase> keepCase({
    required Directory quarantineDir,
    required String caseId,
  }) async {
    final applyCase = await _caseById(quarantineDir, caseId);
    if (applyCase.status != QuarantineCaseStatus.applied) {
      throw QuarantineException(
        'Cannot keep case $caseId from state ${applyCase.status.name}',
      );
    }
    return _replaceCase(
      quarantineDir,
      applyCase.withStatus(QuarantineCaseStatus.kept),
    );
  }

  /// Restores only one case to the state captured immediately before it.
  Future<QuarantineCase> rollbackCase({
    required Directory quarantineDir,
    required String caseId,
    required String reason,
    bool failed = false,
  }) async {
    var document = await _resolveManifestDocument(quarantineDir);
    _requireV3PosixModeEvidence(document.manifest);
    await _prepareDisplacementsForRestore(
      quarantineDir,
      document,
      onlyCaseIds: {caseId},
    );
    document = await _resolveManifestDocument(quarantineDir);
    final applyCase = document.manifest.cases.firstWhere(
      (item) => item.caseId == caseId,
      orElse: () => throw QuarantineException('Case not found: $caseId'),
    );
    final entry = applyCase.entry;
    final snapshot = _caseSnapshotFor(quarantineDir, applyCase);
    if (!snapshot.existsSync() ||
        await _computeSha256(snapshot) != entry.sha256) {
      throw QuarantineException(
        'Valid snapshot missing for case $caseId: ${snapshot.path}',
      );
    }

    final target = File(entry.originalPath);
    await _verifyCaseWorkingCopy(quarantineDir, applyCase, target, snapshot);
    final expectedTargetSha256 = target.existsSync()
        ? await _computeSha256(target)
        : null;
    final expectedTargetPosixMode = target.existsSync()
        ? entry.posixMode
        : null;
    await _restoreSnapshot(
      quarantineDir: quarantineDir,
      snapshot: snapshot,
      target: target,
      caseId: caseId,
      expectedTargetSha256: expectedTargetSha256,
      originalPosixMode: entry.posixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
      allowedExpectedTargetSha256s: {entry.sha256, entry.modifiedSha256},
    );

    final replacement = applyCase.withStatus(
      failed ? QuarantineCaseStatus.failed : QuarantineCaseStatus.rolledBack,
      failureReason: reason,
    );
    final displacement = document.caseDisplacements
        .where((item) => item.caseId == caseId)
        .toList();
    final result = displacement.isEmpty
        ? await _replaceCase(quarantineDir, replacement)
        : await (() async {
            await _replaceCaseAndDisplacement(
              quarantineDir,
              replacementCase: replacement,
              replacementDisplacement: displacement.single.withState(
                _CaseDisplacementState.restored,
              ),
            );
            return replacement;
          })();
    await _cleanupVerifiedRestoreStaging(
      quarantineDir: quarantineDir,
      snapshot: snapshot,
      target: target,
      caseId: caseId,
    );
    return result;
  }

  /// Restores all [caseIds] to their pre-transaction bytes, then journals the
  /// case-state transition in one manifest write.
  ///
  /// If a crash occurs after byte restoration but before the manifest write,
  /// calling this method again recognizes the first snapshot hash and safely
  /// completes the journal transition.
  Future<void> rollbackCasesAtomically({
    required Directory quarantineDir,
    required List<String> caseIds,
    required String reason,
  }) async {
    if (caseIds.isEmpty) return;
    var document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    _requireV3PosixModeEvidence(manifest);
    final requested = caseIds.toSet();
    final selected = manifest.cases
        .where((applyCase) => requested.contains(applyCase.caseId))
        .toList();
    if (selected.length != requested.length) {
      throw QuarantineException('Atomic rollback references a missing case.');
    }

    await _prepareDisplacementsForRestore(
      quarantineDir,
      document,
      onlyCaseIds: requested,
    );
    document = await _resolveManifestDocument(quarantineDir);

    final byPath = <String, List<QuarantineCase>>{};
    for (final applyCase in selected) {
      final snapshot = _caseSnapshotFor(quarantineDir, applyCase);
      if (!snapshot.existsSync() ||
          await _computeSha256(snapshot) != applyCase.entry.sha256) {
        throw QuarantineException(
          'Valid snapshot missing for case ${applyCase.caseId}: '
          '${snapshot.path}',
        );
      }
      byPath.putIfAbsent(applyCase.entry.originalPath, () => []).add(applyCase);
    }

    for (final pathCases in byPath.values) {
      final first = pathCases.first;
      final last = pathCases.last;
      final target = File(first.entry.originalPath);
      final targetHash = target.existsSync()
          ? await _computeSha256(target)
          : null;
      final targetMode = target.existsSync() ? _readPosixMode(target) : null;
      final targetIsOriginal =
          targetHash == first.entry.sha256 &&
          targetMode == first.entry.posixMode;
      if (!targetIsOriginal) {
        if (targetHash != last.entry.modifiedSha256 ||
            (targetHash != null && targetMode != last.entry.posixMode)) {
          throw QuarantineException(
            'Transaction output bytes or permissions changed after apply: '
            '${target.path}\n'
            'Refusing to overwrite user changes.',
          );
        }
        await _restoreSnapshot(
          quarantineDir: quarantineDir,
          snapshot: _caseSnapshotFor(quarantineDir, first),
          target: target,
          caseId: first.caseId,
          expectedTargetSha256: targetHash,
          originalPosixMode: first.entry.posixMode,
          expectedTargetPosixMode: targetMode,
          allowedExpectedTargetSha256s: {
            first.entry.sha256,
            last.entry.modifiedSha256,
          },
        );
      }
      if (!target.existsSync() ||
          await _computeSha256(target) != first.entry.sha256 ||
          _readPosixMode(target) != first.entry.posixMode) {
        throw QuarantineException(
          'Atomic rollback bytes or permissions mismatch: ${target.path}',
        );
      }
    }

    final cases = document.manifest.cases.map((applyCase) {
      if (!requested.contains(applyCase.caseId)) return applyCase;
      return applyCase.withStatus(
        QuarantineCaseStatus.rolledBack,
        failureReason: reason,
      );
    }).toList();
    final displacements = document.caseDisplacements.map((displacement) {
      if (!requested.contains(displacement.caseId)) return displacement;
      return displacement.withState(_CaseDisplacementState.restored);
    }).toList();
    await _writeManifest(
      quarantineDir,
      _copyManifest(document.manifest, cases: cases),
      caseDisplacements: displacements,
    );
    for (final pathCases in byPath.values) {
      final first = pathCases.first;
      await _cleanupVerifiedRestoreStaging(
        quarantineDir: quarantineDir,
        snapshot: _caseSnapshotFor(quarantineDir, first),
        target: File(first.entry.originalPath),
        caseId: first.caseId,
      );
    }
  }

  /// Reads a quarantine manifest for diagnostics and tests.
  Future<QuarantineManifest> readManifest(Directory quarantineDir) {
    return _readManifest(quarantineDir);
  }

  /// Fails closed when an older quarantine could still own project bytes.
  ///
  /// This deliberately inspects every directory entry instead of relying on
  /// [listQuarantines], whose user-facing listing skips invalid ledgers.
  Future<void> ensureNoBlockingHistoricalQuarantines({
    required Iterable<Directory> quarantineBases,
  }) async {
    final seen = <String>{};
    for (final requestedBase in quarantineBases) {
      final basePath = p.normalize(p.absolute(requestedBase.path));
      if (!seen.add(basePath)) continue;
      final baseType = FileSystemEntity.typeSync(basePath, followLinks: false);
      if (baseType == FileSystemEntityType.notFound) continue;
      if (baseType != FileSystemEntityType.directory) {
        throw QuarantineException(
          'Quarantine base is not a real directory: $basePath. Resolve this '
          'path before applying changes.',
        );
      }

      final children =
          await Directory(basePath).list(followLinks: false).toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        final childType = FileSystemEntity.typeSync(
          child.path,
          followLinks: false,
        );
        if (childType != FileSystemEntityType.directory) {
          throw QuarantineException(
            'Unexpected entry in quarantine base: ${child.path}. Move it out '
            'or resolve it before applying changes.',
          );
        }
        final quarantineDir = Directory(child.path);
        late final _ManifestDocument document;
        try {
          document = await _resolveManifestDocument(quarantineDir);
          final manifest = document.manifest;
          if (manifest.runId != p.basename(quarantineDir.path)) {
            throw QuarantineException(
              'Run ID ${manifest.runId} does not match directory '
              '${p.basename(quarantineDir.path)}.',
            );
          }
          _validateManifestProject(manifest);
          await _requireHistoricalRunTerminal(quarantineDir, document);
        } catch (error) {
          throw QuarantineException(
            'Apply is blocked by quarantine ${quarantineDir.path}: $error '
            'Inspect and recover or rollback this run before retrying.',
          );
        }
      }
    }

    final restoreRoot = Directory(
      p.join(ToolWorkspace(projectRoot).directory.path, 'tmp', 'restore'),
    );
    if (restoreRoot.existsSync() &&
        !await restoreRoot.list(followLinks: false).isEmpty) {
      throw QuarantineException(
        'Apply is blocked by interrupted restore artifacts in '
        '${restoreRoot.path}. Complete recovery before retrying.',
      );
    }
  }

  /// Marks every mutation-bearing transaction as requiring recovery.
  ///
  /// This is persisted before a whole-run restore so a crash during recovery
  /// cannot leave a previously committed transaction looking safe to reuse.
  Future<void> markRunRecoveryRequired({
    required Directory quarantineDir,
    required String reason,
  }) async {
    final manifest = await _readManifest(quarantineDir);
    final transactions = manifest.transactions.map((transaction) {
      if (transaction.status ==
          QuarantineTransactionStatus.rolledBackVerified) {
        return transaction;
      }
      return transaction.withState(
        status: QuarantineTransactionStatus.recoveryRequired,
        rollbackVerified: false,
        failureReason: reason,
      );
    }).toList();
    await _writeManifest(
      quarantineDir,
      _copyManifest(manifest, transactions: transactions),
      runLifecycleState: QuarantineRunLifecycleState.recoveryRequired,
    );
  }

  /// Marks a fully successful V3 apply run terminal.
  ///
  /// Individual committed transactions are not sufficient: a process can
  /// crash after one or more commits but before convergence and reporting
  /// finish. This marker is journaled only after the command completes those
  /// run-level obligations.
  Future<void> completeApplyRun({required Directory quarantineDir}) async {
    final document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    _validateManifestProject(manifest);
    _requireV3PosixModeEvidence(manifest);
    if (!manifest.usesTransactionJournal || manifest.transactions.isEmpty) {
      throw QuarantineException(
        'Run completion requires a non-empty V3 transaction journal.',
      );
    }
    if (document.runLifecycle?.state != QuarantineRunLifecycleState.active) {
      throw QuarantineException(
        'Run ${manifest.runId} cannot complete from lifecycle '
        '${document.runLifecycle?.state.name ?? 'missing'}.',
      );
    }
    _validateCompletedTransactionJournal(manifest);
    _validateSelectionTransactions(manifest, requireExactCoverage: true);
    final casesById = {for (final item in manifest.cases) item.caseId: item};
    final lastDisplacedCaseByPath = <String, String>{};
    final displacedCaseIds = document.caseDisplacements
        .map((item) => item.caseId)
        .toSet();
    for (final applyCase in manifest.cases) {
      if (displacedCaseIds.contains(applyCase.caseId)) {
        lastDisplacedCaseByPath[applyCase.entry.originalPath] =
            applyCase.caseId;
      }
    }
    for (final displacement in document.caseDisplacements) {
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null ||
          displacement.state != _CaseDisplacementState.committed) {
        throw QuarantineException(
          'Run ${manifest.runId} has a non-terminal case displacement: '
          '${displacement.caseId}:${displacement.state.name}.',
        );
      }
      await _validateDisplacedAppliedCase(
        quarantineDir: quarantineDir,
        applyCase: applyCase,
        displacement: displacement,
        validateOutput:
            lastDisplacedCaseByPath[applyCase.entry.originalPath] ==
            applyCase.caseId,
      );
    }
    await _writeManifest(
      quarantineDir,
      manifest,
      runLifecycleState: QuarantineRunLifecycleState.completed,
    );
  }

  /// Reads the V3 run-level lifecycle marker for diagnostics and tests.
  Future<QuarantineRunLifecycleState?> readRunLifecycleState(
    Directory quarantineDir,
  ) async =>
      (await _resolveManifestDocument(quarantineDir)).runLifecycle?.state;

  /// Restores all paths to their first snapshot without claiming completion.
  Future<void> restoreRunBytes({required Directory quarantineDir}) async {
    var document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    _validateManifestProject(manifest);
    _requireV3PosixModeEvidence(manifest);
    if (!manifest.usesCaseJournal) {
      throw QuarantineException(
        'Whole-run apply recovery requires a case journal.',
      );
    }
    await _prepareDisplacementsForRestore(quarantineDir, document);
    document = await _resolveManifestDocument(quarantineDir);
    await _restoreCaseJournal(quarantineDir, document);
    final firstByPath = <String, QuarantineCase>{};
    for (final applyCase in document.manifest.cases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
    }
    for (final applyCase in firstByPath.values) {
      await _cleanupVerifiedRestoreStaging(
        quarantineDir: quarantineDir,
        snapshot: _caseSnapshotFor(quarantineDir, applyCase),
        target: File(applyCase.entry.originalPath),
        caseId: applyCase.caseId,
      );
    }
    await _markDisplacementsRestored(quarantineDir);
    for (final applyCase in firstByPath.values) {
      await _cleanupRestorePublishAnchor(
        snapshot: _caseSnapshotFor(quarantineDir, applyCase),
        target: File(applyCase.entry.originalPath),
        caseId: applyCase.caseId,
        expectedSha256: applyCase.entry.sha256,
        expectedPosixMode: applyCase.entry.posixMode,
      );
    }
  }

  /// Rechecks that every project path matches the run-original snapshot.
  Future<void> verifyRunOriginalBytes({
    required Directory quarantineDir,
  }) async {
    final manifest = await _readManifest(quarantineDir);
    _requireV3PosixModeEvidence(manifest);
    final firstByPath = <String, QuarantineCase>{};
    for (final applyCase in manifest.cases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
    }
    for (final first in firstByPath.values) {
      final snapshot = _caseSnapshotFor(quarantineDir, first);
      if (!snapshot.existsSync() ||
          await _computeSha256(snapshot) != first.entry.sha256 ||
          _readPosixMode(snapshot) != first.entry.posixMode) {
        throw QuarantineException(
          'Run-original snapshot bytes or permissions are missing or '
          'corrupted: ${snapshot.path}',
        );
      }
      final target = File(first.entry.originalPath);
      if (!target.existsSync() ||
          await _computeSha256(target) != first.entry.sha256 ||
          _readPosixMode(target) != first.entry.posixMode) {
        throw QuarantineException(
          'Run-original bytes or permissions verification failed: '
          '${target.path}',
        );
      }
    }
  }

  /// Finalizes a whole-run rollback only after byte and verifier checks pass.
  Future<void> completeVerifiedFullRollback({
    required Directory quarantineDir,
    required String reason,
    required QuarantineVerificationEvidence verificationEvidence,
    required bool baselineEquivalent,
  }) async {
    await verifyRunOriginalBytes(quarantineDir: quarantineDir);
    final document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    final baseline = manifest.baselineVerification;
    if (!manifest.usesTransactionJournal ||
        baseline == null ||
        !baselineEquivalent ||
        !_isCompleteVerificationEvidence(baseline) ||
        !_isCompleteVerificationEvidence(verificationEvidence) ||
        verificationEvidence.policyHash != manifest.verificationPolicyHash ||
        baseline.policyHash != manifest.verificationPolicyHash ||
        verificationEvidence.policyHash != baseline.policyHash ||
        verificationEvidence.workingDirectory != baseline.workingDirectory ||
        verificationEvidence.toolchainIdentity != baseline.toolchainIdentity ||
        !_sameStringSet(
          verificationEvidence.requiredStepIds,
          baseline.requiredStepIds,
        )) {
      throw QuarantineException(
        'Whole-run rollback verification evidence is incomplete.',
      );
    }
    await _requireNoRecoveryArtifacts(quarantineDir, document);
    await verifyRunOriginalBytes(quarantineDir: quarantineDir);
    final policyHash = verificationEvidence.policyHash;
    final requiredStepIds = verificationEvidence.requiredStepIds;
    final observedStepIds = verificationEvidence.observedStepIds;
    final cases = manifest.cases
        .map(
          (applyCase) => applyCase.withStatus(
            QuarantineCaseStatus.rolledBack,
            failureReason: reason,
          ),
        )
        .toList();
    final transactions = manifest.transactions
        .map(
          (transaction) => transaction.withState(
            status: QuarantineTransactionStatus.rolledBackVerified,
            verificationPolicyHash: policyHash,
            requiredStepIds: List.unmodifiable(requiredStepIds),
            observedStepIds: List.unmodifiable(observedStepIds),
            rollbackVerified: true,
            failureReason: reason,
          ),
        )
        .toList();
    await _writeManifest(
      quarantineDir,
      _copyManifest(
        manifest,
        cases: cases,
        transactions: transactions,
        fullRollbackAtUtc: DateTime.now().toUtc(),
        fullRollbackVerified: true,
      ),
      runLifecycleState: QuarantineRunLifecycleState.rolledBackVerified,
    );
  }

  bool _isCompleteVerificationEvidence(
    QuarantineVerificationEvidence evidence,
  ) {
    final required = evidence.requiredStepIds.toSet();
    final observed = evidence.observedStepIds.toSet();
    final comparisonBaseline = evidence.comparisonBaseline;
    return evidence.available &&
        evidence.passed != null &&
        comparisonBaseline != null &&
        comparisonBaseline.isComplete &&
        comparisonBaseline.policyHash == evidence.policyHash &&
        comparisonBaseline.workingDirectory == evidence.workingDirectory &&
        comparisonBaseline.toolchainIdentity == evidence.toolchainIdentity &&
        _sameStringSet(
          comparisonBaseline.requiredStepIds,
          evidence.requiredStepIds,
        ) &&
        comparisonBaseline.steps.every((step) => step.exitCode >= 0) &&
        comparisonBaseline.steps.every((step) => step.passed) ==
            evidence.passed &&
        evidence.policyHash.isNotEmpty &&
        evidence.workingDirectory.isNotEmpty &&
        evidence.toolchainIdentity.isNotEmpty &&
        evidence.requiredStepIds.isNotEmpty &&
        required.length == evidence.requiredStepIds.length &&
        observed.length == evidence.observedStepIds.length &&
        required.difference(observed).isEmpty &&
        observed.difference(required).isEmpty;
  }

  bool _sameStringSet(List<String> left, List<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return left.length == leftSet.length &&
        right.length == rightSet.length &&
        leftSet.difference(rightSet).isEmpty &&
        rightSet.difference(leftSet).isEmpty;
  }

  void _requireV3PosixModeEvidence(QuarantineManifest manifest) {
    if (!_supportsPosixModes || !manifest.usesTransactionJournal) return;
    final missingCaseIds = manifest.cases
        .where((applyCase) => applyCase.entry.posixMode == null)
        .map((applyCase) => applyCase.caseId)
        .toList();
    if (missingCaseIds.isEmpty) return;
    throw QuarantineException(
      'V3 quarantine ${manifest.runId} has no recorded POSIX permission '
      'evidence for ${missingCaseIds.join(', ')}. Automatic mutation, restore, '
      'or cleanup is disabled.',
    );
  }

  Future<void> _requireNoRecoveryArtifacts(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    final recovery = Directory(p.join(quarantineDir.path, 'recovery'));
    if (recovery.existsSync() &&
        !await recovery.list(followLinks: false).isEmpty) {
      throw QuarantineException(
        'Whole-run rollback retains recovery artifacts in ${recovery.path}.',
      );
    }
    final restoreRoot = Directory(
      p.join(ToolWorkspace(projectRoot).directory.path, 'tmp', 'restore'),
    );
    if (restoreRoot.existsSync() &&
        !await restoreRoot.list(followLinks: false).isEmpty) {
      throw QuarantineException(
        'Whole-run rollback retains restore staging in ${restoreRoot.path}.',
      );
    }
    await _validateRestoredDisplacements(quarantineDir, document);
  }

  /// Moves [file] to quarantine atomically.
  ///
  /// Verifies SHA-256 hash matches [expectedSha256] before moving.
  /// Returns the quarantine file location.
  Future<File> quarantineFile({
    required File file,
    required String expectedSha256,
    required Directory quarantineDir,
    required String originalPath,
  }) async {
    // Verify file hasn't changed since scan
    if (!file.existsSync()) {
      throw QuarantineException('File no longer exists: ${file.path}');
    }

    final actualSha256 = await _computeSha256(file);
    final originalPosixMode = _readPosixMode(file);
    if (actualSha256 != expectedSha256) {
      throw QuarantineException(
        'File changed since scan: ${file.path}\n'
        'Expected SHA-256: $expectedSha256\n'
        'Actual SHA-256: $actualSha256',
      );
    }

    // Preserve directory structure in quarantine
    final relativePath = p.relative(originalPath, from: projectRoot.path);
    final quarantineFile = File(p.join(quarantineDir.path, relativePath));

    await quarantineFile.parent.create(recursive: true);

    // Move the source inode atomically. A copy-delete fallback would reopen a
    // CAS gap in which a concurrent writer could lose bytes or permissions.
    try {
      await file.rename(quarantineFile.path);
    } on FileSystemException catch (error) {
      throw QuarantineException(
        'Atomic quarantine move failed for ${file.path}; no copy-delete '
        'fallback was attempted. $error',
      );
    }
    if (await _computeSha256(quarantineFile) != expectedSha256 ||
        _readPosixMode(quarantineFile) != originalPosixMode) {
      throw QuarantineException(
        'Quarantined source bytes or permissions changed during the atomic '
        'move: ${quarantineFile.path}.',
      );
    }

    return quarantineFile;
  }

  /// Copies a quarantined original back into the project as a working copy.
  ///
  /// Declaration-level apply uses this only after every original has been
  /// quarantined successfully. The backup remains untouched for rollback.
  Future<File> createWorkingCopy({
    required QuarantineEntry entry,
    required Directory quarantineDir,
  }) async {
    final quarantineFile = _quarantineFileFor(
      quarantineDir,
      entry.originalPath,
    );
    if (!quarantineFile.existsSync()) {
      throw QuarantineException(
        'Quarantined file missing: ${quarantineFile.path}',
      );
    }

    final actualSha256 = await _computeSha256(quarantineFile);
    final originalPosixMode = entry.posixMode ?? _readPosixMode(quarantineFile);
    if (actualSha256 != entry.sha256 ||
        _readPosixMode(quarantineFile) != originalPosixMode) {
      throw QuarantineException(
        'Quarantined file bytes or permissions changed: '
        '${quarantineFile.path}',
      );
    }

    final target = File(entry.originalPath);
    if (target.existsSync()) {
      throw QuarantineException(
        'Target file already exists: ${entry.originalPath}',
      );
    }
    await target.parent.create(recursive: true);
    await _copyFileFlushed(
      quarantineFile,
      target,
      exclusive: true,
      expectedPosixMode: originalPosixMode,
    );
    return target;
  }

  /// Records hashes of final declaration working copies in the manifest.
  ///
  /// Rollback uses these hashes to avoid overwriting user edits made after an
  /// apply. A missing file is represented by a null hash.
  Future<void> recordModifiedFiles({
    required Directory quarantineDir,
    required Map<String, String?> modifiedSha256ByPath,
  }) async {
    final manifest = await _readManifest(quarantineDir);
    final entries = manifest.entries.map((entry) {
      if (entry.operationType != QuarantineOperationType.declaration) {
        return entry;
      }
      if (!modifiedSha256ByPath.containsKey(entry.originalPath)) return entry;
      return entry.withModifiedSha256(modifiedSha256ByPath[entry.originalPath]);
    }).toList();

    await _writeManifest(
      quarantineDir,
      _copyManifest(manifest, entries: entries),
    );
  }

  /// Restores all files from [quarantineDir] back to their original locations.
  ///
  /// Verifies SHA-256 hashes and performs atomic restoration.
  Future<void> restore({
    required Directory quarantineDir,
    required String runId,
  }) async {
    if (!quarantineDir.existsSync()) {
      throw QuarantineException('Quarantine not found: ${quarantineDir.path}');
    }

    // Read manifest
    final manifest = await _readManifest(quarantineDir);
    if (manifest.runId != runId) {
      throw QuarantineException(
        'Run ID mismatch: expected $runId, got ${manifest.runId}',
      );
    }
    _validateManifestProject(manifest);

    if (manifest.usesCaseJournal) {
      if (manifest.usesTransactionJournal) {
        await markRunRecoveryRequired(
          quarantineDir: quarantineDir,
          reason:
              'Byte restoration started without attached verifier evidence.',
        );
        await restoreRunBytes(quarantineDir: quarantineDir);
        return;
      }
      await restoreRunBytes(quarantineDir: quarantineDir);
      await _recordFullRollback(quarantineDir);
      return;
    }

    // Verify all quarantined files exist and have correct hashes
    final filesToRestore = <_V1RestoreFile>[];
    final alreadyRestored = <_V1RestoreFile>[];
    for (final entry in manifest.entries) {
      final relativePath = _relativeProjectPath(entry.originalPath);
      final quarantineFile = File(p.join(quarantineDir.path, relativePath));
      final targetFile = File(p.join(projectRoot.path, relativePath));

      if (!quarantineFile.existsSync()) {
        // During a failed multi-file quarantine, later entries may never have
        // moved. If the verified original is still in place, there is nothing
        // to restore for this entry.
        if (targetFile.existsSync() &&
            await _computeSha256(targetFile) == entry.sha256 &&
            (entry.posixMode == null ||
                _readPosixMode(targetFile) == entry.posixMode)) {
          continue;
        }
        throw QuarantineException(
          'Quarantined file missing: ${quarantineFile.path}',
        );
      }

      final actualSha256 = await _computeSha256(quarantineFile);
      final originalPosixMode =
          entry.posixMode ?? _readPosixMode(quarantineFile);
      if (actualSha256 != entry.sha256 ||
          _readPosixMode(quarantineFile) != originalPosixMode) {
        throw QuarantineException(
          'Quarantined file bytes or permissions changed: '
          '${quarantineFile.path}\n'
          'Expected SHA-256: ${entry.sha256}\n'
          'Actual SHA-256: $actualSha256',
        );
      }

      final expectedTargetPosixMode = _expectedRestoreTargetPosixMode(
        snapshot: quarantineFile,
        target: targetFile,
        caseId: _v1RestoreCaseId(runId),
        recordedMode: originalPosixMode,
      );

      await _recoverInterruptedRestore(
        quarantineDir: quarantineDir,
        snapshot: quarantineFile,
        target: targetFile,
        caseId: _v1RestoreCaseId(runId),
        allowedExpectedTargetSha256s: {entry.sha256, entry.modifiedSha256},
        originalPosixMode: originalPosixMode,
        expectedTargetPosixMode: expectedTargetPosixMode,
      );

      // Check if target location is now occupied
      if (targetFile.existsSync()) {
        final targetSha256 = await _computeSha256(targetFile);
        if (targetSha256 == entry.sha256 &&
            _readPosixMode(targetFile) == originalPosixMode) {
          alreadyRestored.add(
            _V1RestoreFile(
              entry: entry,
              quarantineFile: quarantineFile,
              targetFile: targetFile,
            ),
          );
          continue;
        }
        if (entry.operationType != QuarantineOperationType.declaration ||
            entry.modifiedSha256 == null) {
          throw QuarantineException(
            'Target file already exists: ${entry.originalPath}\n'
            'Cannot restore without overwriting.',
          );
        }
        if (targetSha256 != entry.modifiedSha256) {
          throw QuarantineException(
            'Modified file changed after apply: ${entry.originalPath}\n'
            'Refusing to overwrite user changes.',
          );
        }
        if (_readPosixMode(targetFile) != originalPosixMode) {
          throw QuarantineException(
            'Modified file permissions changed after apply: '
            '${entry.originalPath}\nRefusing to overwrite user changes.',
          );
        }
      }

      filesToRestore.add(
        _V1RestoreFile(
          entry: entry,
          quarantineFile: quarantineFile,
          targetFile: targetFile,
        ),
      );
    }

    // V1 restores use the same project-local staged recovery protocol as V2.
    // The original remains quarantined until the target hash is verified.
    for (final restore in filesToRestore) {
      final expectedTargetSha256 = restore.targetFile.existsSync()
          ? await _computeSha256(restore.targetFile)
          : null;
      final originalPosixMode =
          restore.entry.posixMode ?? _readPosixMode(restore.quarantineFile);
      final expectedTargetPosixMode = restore.targetFile.existsSync()
          ? originalPosixMode
          : null;
      await _restoreSnapshot(
        quarantineDir: quarantineDir,
        snapshot: restore.quarantineFile,
        target: restore.targetFile,
        caseId: _v1RestoreCaseId(runId),
        expectedTargetSha256: expectedTargetSha256,
        originalPosixMode: originalPosixMode,
        expectedTargetPosixMode: expectedTargetPosixMode,
        allowedExpectedTargetSha256s: {
          restore.entry.sha256,
          restore.entry.modifiedSha256,
        },
      );
      if (await _computeSha256(restore.targetFile) != restore.entry.sha256 ||
          _readPosixMode(restore.targetFile) != originalPosixMode) {
        throw QuarantineException(
          'Restored file bytes or permissions mismatch: '
          '${restore.targetFile.path}',
        );
      }
    }

    // Staging directories and adjacent hard-link anchors are recovery
    // evidence. Validate and remove all of them before deleting authoritative
    // snapshots or recording a terminal rollback.
    for (final restore in [...filesToRestore, ...alreadyRestored]) {
      final originalPosixMode =
          restore.entry.posixMode ?? _readPosixMode(restore.quarantineFile);
      await _cleanupVerifiedRestoreStaging(
        quarantineDir: quarantineDir,
        snapshot: restore.quarantineFile,
        target: restore.targetFile,
        caseId: _v1RestoreCaseId(runId),
      );
      await _cleanupRestorePublishAnchor(
        snapshot: restore.quarantineFile,
        target: restore.targetFile,
        caseId: _v1RestoreCaseId(runId),
        expectedSha256: restore.entry.sha256,
        expectedPosixMode: originalPosixMode,
      );
    }
    for (final restore in [...filesToRestore, ...alreadyRestored]) {
      final originalPosixMode =
          restore.entry.posixMode ?? _readPosixMode(restore.quarantineFile);
      if (!restore.targetFile.existsSync() ||
          await _computeSha256(restore.targetFile) != restore.entry.sha256 ||
          _readPosixMode(restore.targetFile) != originalPosixMode ||
          !restore.quarantineFile.existsSync() ||
          await _computeSha256(restore.quarantineFile) !=
              restore.entry.sha256 ||
          _readPosixMode(restore.quarantineFile) != originalPosixMode) {
        throw QuarantineException(
          'V1 rollback evidence changed before terminalization: '
          '${restore.targetFile.path}.',
        );
      }
      await restore.quarantineFile.delete();
    }
    await _recordFullRollback(quarantineDir);
  }

  /// Lists all quarantines in the project.
  Future<List<QuarantineInfo>> listQuarantines({
    String quarantineBase = defaultQuarantineDir,
  }) async {
    final baseDir = Directory(_resolveQuarantineBase(quarantineBase));

    if (!baseDir.existsSync()) {
      return [];
    }

    final quarantines = <QuarantineInfo>[];

    await for (final entity in baseDir.list()) {
      if (entity is! Directory) continue;

      try {
        final manifest = await _readManifest(entity);
        quarantines.add(
          QuarantineInfo(
            runId: manifest.runId,
            timestamp: manifest.timestamp,
            entryCount: manifest.usesCaseJournal
                ? manifest.cases.length
                : manifest.entries.length,
            path: entity.path,
          ),
        );
      } catch (e) {
        // Skip invalid quarantines
      }
    }

    // Sort by timestamp, newest first
    quarantines.sort((a, b) => b.timestamp.compareTo(a.timestamp));

    return quarantines;
  }

  /// Strictly enumerates and validates every raw run directory before a batch
  /// clean. Unlike [listQuarantines], invalid ledgers are never skipped.
  Future<List<QuarantineInfo>> validateAndListCleanableQuarantines({
    required Iterable<Directory> quarantineBases,
  }) async {
    final quarantines = <QuarantineInfo>[];
    final seenBases = <String>{};
    final runPathsById = <String, String>{};
    for (final requestedBase in quarantineBases) {
      final basePath = p.normalize(p.absolute(requestedBase.path));
      if (!seenBases.add(basePath)) continue;
      final baseType = FileSystemEntity.typeSync(basePath, followLinks: false);
      if (baseType == FileSystemEntityType.notFound) continue;
      if (baseType != FileSystemEntityType.directory) {
        throw QuarantineException(
          'Quarantine base is not a real directory: $basePath.',
        );
      }
      final canonicalBase = Directory(basePath).resolveSymbolicLinksSync();
      final children =
          await Directory(basePath).list(followLinks: false).toList()
            ..sort((left, right) => left.path.compareTo(right.path));
      for (final child in children) {
        final childType = FileSystemEntity.typeSync(
          child.path,
          followLinks: false,
        );
        if (childType != FileSystemEntityType.directory) {
          throw QuarantineException(
            'Unexpected entry in quarantine base: ${child.path}. '
            'No quarantines were removed.',
          );
        }
        final quarantineDir = Directory(child.path);
        final canonicalTarget = quarantineDir.resolveSymbolicLinksSync();
        if (!p.isWithin(canonicalBase, canonicalTarget)) {
          throw QuarantineException(
            'Quarantine is outside its canonical base: $canonicalTarget',
          );
        }
        final directoryRunId = p.basename(quarantineDir.path);
        try {
          validateRunId(directoryRunId);
          final document = await _resolveManifestDocument(quarantineDir);
          final manifest = document.manifest;
          if (manifest.runId != directoryRunId) {
            throw QuarantineException(
              'Run ID mismatch: directory $directoryRunId contains '
              '${manifest.runId}.',
            );
          }
          _validateManifestProject(manifest);
          await _requireCleanableState(quarantineDir, document);
          final previousPath = runPathsById[manifest.runId];
          if (previousPath != null && !p.equals(previousPath, child.path)) {
            throw QuarantineException(
              'Ambiguous quarantine run ${manifest.runId} exists at '
              '$previousPath and ${child.path}. No quarantines were removed.',
            );
          }
          runPathsById[manifest.runId] = child.path;
          quarantines.add(
            QuarantineInfo(
              runId: manifest.runId,
              timestamp: manifest.timestamp,
              entryCount: manifest.usesCaseJournal
                  ? manifest.cases.length
                  : manifest.entries.length,
              path: child.path,
            ),
          );
        } catch (error) {
          throw QuarantineException(
            'Cannot clean quarantine ${quarantineDir.path}: $error',
          );
        }
      }
    }
    quarantines.sort((a, b) => b.timestamp.compareTo(a.timestamp));
    return quarantines;
  }

  /// Deletes the quarantine directory for [runId].
  Future<void> cleanQuarantine({
    required String runId,
    String quarantineBase = defaultQuarantineDir,
  }) async {
    final quarantineDir = await _validateCleanTarget(
      runId: runId,
      quarantineBase: quarantineBase,
    );
    await quarantineDir.delete(recursive: true);
  }

  /// Verifies that cleaning [runId] cannot discard active or recovery state.
  Future<void> validateCleanQuarantine({
    required String runId,
    String quarantineBase = defaultQuarantineDir,
  }) async {
    await _validateCleanTarget(runId: runId, quarantineBase: quarantineBase);
  }

  Future<Directory> _validateCleanTarget({
    required String runId,
    required String quarantineBase,
  }) async {
    validateRunId(runId);
    final basePath = _resolveQuarantineBase(quarantineBase);
    final quarantineDir = Directory(p.join(basePath, runId));

    if (!quarantineDir.existsSync()) {
      throw QuarantineException('Quarantine not found: ${quarantineDir.path}');
    }

    final baseType = FileSystemEntity.typeSync(basePath, followLinks: false);
    final quarantineType = FileSystemEntity.typeSync(
      quarantineDir.path,
      followLinks: false,
    );
    if (baseType == FileSystemEntityType.link ||
        quarantineType == FileSystemEntityType.link) {
      throw QuarantineException(
        'Refusing to clean a symlinked quarantine path: '
        '${quarantineDir.path}',
      );
    }
    final canonicalBase = Directory(basePath).resolveSymbolicLinksSync();
    final canonicalTarget = quarantineDir.resolveSymbolicLinksSync();
    if (!p.isWithin(canonicalBase, canonicalTarget)) {
      throw QuarantineException(
        'Quarantine is outside its canonical base: $canonicalTarget',
      );
    }

    final document = await _resolveManifestDocument(quarantineDir);
    final manifest = document.manifest;
    if (manifest.runId != runId) {
      throw QuarantineException(
        'Run ID mismatch: expected $runId, got ${manifest.runId}',
      );
    }
    _validateManifestProject(manifest);
    await _requireCleanableState(quarantineDir, document);

    return quarantineDir;
  }

  Future<void> _requireCleanableState(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    final manifest = document.manifest;
    _requireV3PosixModeEvidence(manifest);
    final recoveryPath = p.join(quarantineDir.path, 'recovery');
    final recoveryType = FileSystemEntity.typeSync(
      recoveryPath,
      followLinks: false,
    );
    if (recoveryType == FileSystemEntityType.link ||
        recoveryType == FileSystemEntityType.file) {
      throw QuarantineException(
        'Quarantine ${manifest.runId} contains recovery artifacts. '
        'Copy or resolve them before cleaning.',
      );
    }
    if (recoveryType == FileSystemEntityType.directory &&
        !await Directory(recoveryPath).list(followLinks: false).isEmpty) {
      throw QuarantineException(
        'Quarantine ${manifest.runId} contains recovery artifacts. '
        'Copy or resolve them before cleaning.',
      );
    }

    final blockedTransactions = manifest.transactions.where(
      (transaction) => switch (transaction.status) {
        QuarantineTransactionStatus.rolledBackVerified => false,
        QuarantineTransactionStatus.committed => !manifest.fullRollbackVerified,
        QuarantineTransactionStatus.pending ||
        QuarantineTransactionStatus.applied ||
        QuarantineTransactionStatus.verified ||
        QuarantineTransactionStatus.recoveryRequired => true,
      },
    );
    if (blockedTransactions.isNotEmpty) {
      final states = blockedTransactions
          .map(
            (transaction) =>
                '${transaction.transactionId}:${transaction.status.name}',
          )
          .join(', ');
      throw QuarantineException(
        'Quarantine ${manifest.runId} has active, recovery-required, or '
        'unrolled transactions: $states. Rollback or recover them before '
        'cleaning.',
      );
    }

    final blockedCases = manifest.cases.where(
      (applyCase) => switch (applyCase.status) {
        QuarantineCaseStatus.rolledBack || QuarantineCaseStatus.failed => false,
        QuarantineCaseStatus.kept => !manifest.fullRollbackVerified,
        QuarantineCaseStatus.backedUp || QuarantineCaseStatus.applied => true,
      },
    );
    if (blockedCases.isNotEmpty) {
      final states = blockedCases
          .map((applyCase) => '${applyCase.caseId}:${applyCase.status.name}')
          .join(', ');
      throw QuarantineException(
        'Quarantine ${manifest.runId} has unrolled cases: $states. '
        'Rollback or recover them before cleaning.',
      );
    }

    if (!manifest.usesCaseJournal && !manifest.fullRollbackVerified) {
      final retainedEntries = manifest.entries.where(
        (entry) =>
            _quarantineFileFor(quarantineDir, entry.originalPath).existsSync(),
      );
      if (retainedEntries.isNotEmpty) {
        throw QuarantineException(
          'Quarantine ${manifest.runId} still contains original file backups. '
          'Rollback them before cleaning.',
        );
      }
    }
    await _validateRestoredDisplacements(quarantineDir, document);
  }

  Future<void> _requireHistoricalRunTerminal(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    final manifest = document.manifest;
    _requireV3PosixModeEvidence(manifest);
    final recoveryPath = p.join(quarantineDir.path, 'recovery');
    final recoveryType = FileSystemEntity.typeSync(
      recoveryPath,
      followLinks: false,
    );
    if (recoveryType == FileSystemEntityType.link ||
        recoveryType == FileSystemEntityType.file ||
        (recoveryType == FileSystemEntityType.directory &&
            !await Directory(recoveryPath).list(followLinks: false).isEmpty)) {
      throw QuarantineException('Recovery artifacts are still present.');
    }

    if (!manifest.usesTransactionJournal) {
      if (!manifest.fullRollbackVerified) {
        throw QuarantineException(
          'Legacy ledger has no verified terminal transaction state.',
        );
      }
      return;
    }

    final lifecycle = document.runLifecycle?.state;
    if (lifecycle == null) {
      // Pre-marker V3 ledgers remain readable and recoverable. A verified
      // full rollback is an older, equivalent terminal proof; committed
      // transactions alone are ambiguous with a crash between transaction
      // commit and run completion, so migration fails closed for that state.
      if (!manifest.fullRollbackVerified) {
        throw QuarantineException(
          'V3 ledger has no run-level completion marker.',
        );
      }
      _validateRolledBackTransactionJournal(manifest);
      _validateSelectionTransactions(manifest, requireExactCoverage: false);
      await _validateRestoredDisplacements(quarantineDir, document);
      return;
    }
    switch (lifecycle) {
      case QuarantineRunLifecycleState.active:
        throw QuarantineException(
          'Run ${manifest.runId} has no completion marker; lifecycle is active.',
        );
      case QuarantineRunLifecycleState.recoveryRequired:
        throw QuarantineException('Run ${manifest.runId} requires recovery.');
      case QuarantineRunLifecycleState.completed:
        _validateCompletedTransactionJournal(manifest);
        _validateSelectionTransactions(manifest, requireExactCoverage: true);
        await _validateCompletedDisplacements(quarantineDir, document);
      case QuarantineRunLifecycleState.rolledBackVerified:
        _validateRolledBackTransactionJournal(manifest);
        _validateSelectionTransactions(manifest, requireExactCoverage: false);
        await _validateRestoredDisplacements(quarantineDir, document);
    }
  }

  Future<void> _validateCompletedDisplacements(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    final casesById = {
      for (final applyCase in document.manifest.cases)
        applyCase.caseId: applyCase,
    };
    final displacedIds = document.caseDisplacements
        .map((item) => item.caseId)
        .toSet();
    final lastByPath = <String, String>{};
    for (final applyCase in document.manifest.cases) {
      if (displacedIds.contains(applyCase.caseId)) {
        lastByPath[applyCase.entry.originalPath] = applyCase.caseId;
      }
    }
    for (final displacement in document.caseDisplacements) {
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null ||
          displacement.state != _CaseDisplacementState.committed) {
        throw QuarantineException(
          'Completed run has a non-committed displacement: '
          '${displacement.caseId}:${displacement.state.name}.',
        );
      }
      await _validateDisplacedAppliedCase(
        quarantineDir: quarantineDir,
        applyCase: applyCase,
        displacement: displacement,
        validateOutput:
            lastByPath[applyCase.entry.originalPath] == applyCase.caseId,
      );
    }
  }

  Future<void> _validateRestoredDisplacements(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    if (document.caseDisplacements.isEmpty) return;
    final casesById = {
      for (final applyCase in document.manifest.cases)
        applyCase.caseId: applyCase,
    };
    final firstByPath = <String, QuarantineCase>{};
    for (final applyCase in document.manifest.cases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
    }
    for (final displacement in document.caseDisplacements) {
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null ||
          displacement.state != _CaseDisplacementState.restored) {
        throw QuarantineException(
          'Rolled-back run has a non-restored displacement: '
          '${displacement.caseId}:${displacement.state.name}.',
        );
      }
      await _requirePromotedBackupHash(
        _caseSnapshotFor(quarantineDir, applyCase),
        displacement,
        expectedPosixMode: applyCase.entry.posixMode,
      );
      final safetyHash = await _hashRequiredRegularFile(
        _caseSafetyFile(quarantineDir, applyCase),
        label: 'Pre-displacement safety copy',
      );
      final safetyMode = _readPosixMode(
        _caseSafetyFile(quarantineDir, applyCase),
      );
      if (safetyHash != displacement.expectedSha256 ||
          safetyMode != applyCase.entry.posixMode) {
        throw QuarantineException(
          'Pre-displacement safety copy bytes or permissions drifted for '
          '${displacement.caseId}.',
        );
      }
      final candidate = _caseCandidateFile(
        applyCase,
        runId: document.manifest.runId,
      );
      if (FileSystemEntity.typeSync(candidate.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw QuarantineException(
          'Live candidate remains after rollback: ${candidate.path}.',
        );
      }
      final target = File(applyCase.entry.originalPath);
      final restoreAnchor = _restorePublishAnchor(
        _caseSnapshotFor(quarantineDir, applyCase),
        target,
        applyCase.caseId,
      );
      if (FileSystemEntity.typeSync(restoreAnchor.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw QuarantineException(
          'Restore publish anchor remains after rollback: '
          '${restoreAnchor.path}.',
        );
      }
    }
    for (final first in firstByPath.values) {
      final target = File(first.entry.originalPath);
      if (!target.existsSync() ||
          await _computeSha256(target) != first.entry.sha256 ||
          _readPosixMode(target) != first.entry.posixMode) {
        throw QuarantineException(
          'Rolled-back source no longer matches original bytes or '
          'permissions: '
          '${target.path}.',
        );
      }
    }
  }

  void _validateCompletedTransactionJournal(QuarantineManifest manifest) {
    if (manifest.fullRollbackVerified) {
      throw QuarantineException(
        'Completed run ${manifest.runId} also claims a full rollback.',
      );
    }
    _validateTransactionOwnership(
      manifest,
      expectedTransactionStatus: QuarantineTransactionStatus.committed,
      validCaseStatuses: const {QuarantineCaseStatus.kept},
      requireRollbackEvidence: false,
    );
  }

  void _validateRolledBackTransactionJournal(QuarantineManifest manifest) {
    if (!manifest.fullRollbackVerified) {
      throw QuarantineException(
        'Rolled-back run ${manifest.runId} lacks full-run verification.',
      );
    }
    _validateTransactionOwnership(
      manifest,
      expectedTransactionStatus: QuarantineTransactionStatus.rolledBackVerified,
      validCaseStatuses: const {
        QuarantineCaseStatus.rolledBack,
        QuarantineCaseStatus.failed,
      },
      requireRollbackEvidence: true,
    );
  }

  void _validateSelectionTransactions(
    QuarantineManifest manifest, {
    required bool requireExactCoverage,
  }) {
    final selection = manifest.selection;
    if (selection == null) return;

    final observed = <String>{};
    for (final transaction in manifest.transactions) {
      for (final findingId in transaction.findingIds) {
        if (!observed.add(findingId)) {
          throw QuarantineException(
            'Finding $findingId appears in multiple transactions.',
          );
        }
      }
    }
    if (selection.mode != FindingSelectionMode.exact) return;

    final requested = selection.requestedFindingIds.toSet();
    final unauthorized = observed.difference(requested);
    if (unauthorized.isNotEmpty) {
      throw QuarantineException(
        'Transaction journal contains findings outside the exact selection: '
        '${unauthorized.toList()..sort()}.',
      );
    }
    if (requireExactCoverage) {
      final missing = requested.difference(observed);
      if (missing.isNotEmpty) {
        throw QuarantineException(
          'Completed transaction journal is missing selected findings: '
          '${missing.toList()..sort()}.',
        );
      }
    }
  }

  void _validateTransactionOwnership(
    QuarantineManifest manifest, {
    required QuarantineTransactionStatus expectedTransactionStatus,
    required Set<QuarantineCaseStatus> validCaseStatuses,
    required bool requireRollbackEvidence,
  }) {
    final casesById = <String, QuarantineCase>{};
    for (final applyCase in manifest.cases) {
      if (casesById.containsKey(applyCase.caseId)) {
        throw QuarantineException('Duplicate case ID: ${applyCase.caseId}.');
      }
      casesById[applyCase.caseId] = applyCase;
    }
    final ownedCaseIds = <String>{};
    for (final transaction in manifest.transactions) {
      if (transaction.status != expectedTransactionStatus) {
        throw QuarantineException(
          'Transaction ${transaction.transactionId} is '
          '${transaction.status.name}, expected '
          '${expectedTransactionStatus.name}.',
        );
      }
      if (requireRollbackEvidence && !transaction.rollbackVerified) {
        throw QuarantineException(
          'Rolled-back transaction lacks verification evidence: '
          '${transaction.transactionId}.',
        );
      }
      for (final caseId in transaction.caseIds) {
        if (!ownedCaseIds.add(caseId)) {
          throw QuarantineException('Case $caseId has multiple owners.');
        }
        final applyCase = casesById[caseId];
        if (applyCase == null ||
            applyCase.transactionId != transaction.transactionId) {
          throw QuarantineException(
            'Transaction ${transaction.transactionId} references an invalid '
            'case: $caseId.',
          );
        }
        if (!validCaseStatuses.contains(applyCase.status)) {
          throw QuarantineException(
            'Case $caseId is ${applyCase.status.name}, inconsistent with '
            '${expectedTransactionStatus.name}.',
          );
        }
      }
    }
    final orphaned = casesById.keys.toSet().difference(ownedCaseIds);
    if (orphaned.isNotEmpty) {
      throw QuarantineException(
        'Cases have no transaction owner: ${orphaned.join(', ')}.',
      );
    }
  }

  Future<void> _writeManifest(
    Directory quarantineDir,
    QuarantineManifest manifest, {
    QuarantineRunLifecycleState? runLifecycleState,
    List<_CaseDisplacementDocument>? caseDisplacements,
  }) async {
    final manifestFile = File(p.join(quarantineDir.path, 'manifest.json'));
    final temporaryFile = File('${manifestFile.path}.tmp');
    final previousFile = File('${manifestFile.path}.previous');

    _ManifestDocument? current;
    if (manifestFile.existsSync() ||
        temporaryFile.existsSync() ||
        previousFile.existsSync()) {
      current = await _resolveManifestDocument(quarantineDir);
    }
    final revision = (current?.revision ?? 0) + 1;
    final lifecycle = runLifecycleState == null
        ? current?.runLifecycle
        : _RunLifecycleDocument(runLifecycleState);
    final displacements =
        caseDisplacements ??
        current?.caseDisplacements ??
        const <_CaseDisplacementDocument>[];
    final payload = <String, dynamic>{
      ...manifest.toJson(),
      if (lifecycle != null) '_runLifecycle': lifecycle.toJson(),
      if (displacements.isNotEmpty)
        '_caseDisplacements': displacements
            .map((item) => item.toJson())
            .toList(),
    };
    final payloadSha256 = sha256
        .convert(utf8.encode(jsonEncode(payload)))
        .toString();
    final document = <String, dynamic>{
      ...payload,
      '_journal': <String, dynamic>{
        'revision': revision,
        'payloadSha256': payloadSha256,
      },
    };
    await _writeFlushed(
      temporaryFile,
      '${const JsonEncoder.withIndent('  ').convert(document)}\n',
    );
    await _readManifestCandidate(temporaryFile);

    if (!manifestFile.existsSync()) {
      await temporaryFile.rename(manifestFile.path);
      return;
    }
    if (previousFile.existsSync()) await previousFile.delete();
    await manifestFile.rename(previousFile.path);
    try {
      await temporaryFile.rename(manifestFile.path);
    } on FileSystemException {
      // The previous authoritative document and the fully flushed next
      // document remain side by side. The reader deterministically completes
      // this transition on the next access.
      rethrow;
    }
  }

  String _resolveQuarantineBase(String quarantineBase) => ToolWorkspace(
    projectRoot,
  ).resolveQuarantineDirectory(quarantineBase).path;

  /// Rejects path-like or otherwise unsafe user-supplied run identifiers.
  static void validateRunId(String runId) {
    if (!RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(runId) ||
        runId == '.' ||
        runId == '..') {
      throw QuarantineException('Invalid run ID: $runId');
    }
  }

  Future<QuarantineManifest> _readManifest(Directory quarantineDir) async {
    return (await _resolveManifestDocument(quarantineDir)).manifest;
  }

  Future<_ManifestDocument> _resolveManifestDocument(
    Directory quarantineDir,
  ) async {
    final manifestFile = File(p.join(quarantineDir.path, 'manifest.json'));
    final temporaryFile = File('${manifestFile.path}.tmp');
    final previousFile = File('${manifestFile.path}.previous');

    Future<_ManifestDocument?> load(File file) async {
      if (!file.existsSync()) return null;
      return _readManifestCandidate(file);
    }

    final primary = await load(manifestFile);
    final temporary = await load(temporaryFile);
    final previous = await load(previousFile);

    if (primary != null) {
      if (temporary != null) {
        final stagedNext = temporary.revision == primary.revision + 1;
        final duplicate =
            temporary.revision == primary.revision &&
            temporary.payloadSha256 == primary.payloadSha256;
        if (!stagedNext && !duplicate) {
          throw QuarantineException(
            'Ambiguous manifest transition in ${quarantineDir.path}.',
          );
        }
        await temporaryFile.delete();
      }
      if (previous != null) {
        final validPrevious =
            (primary.revision == previous.revision + 1) ||
            (primary.revision == previous.revision &&
                primary.payloadSha256 == previous.payloadSha256);
        if (!validPrevious) {
          throw QuarantineException(
            'Ambiguous previous manifest in ${quarantineDir.path}.',
          );
        }
      }
      return primary;
    }

    if (temporary != null && previous != null) {
      if (temporary.revision != previous.revision + 1) {
        throw QuarantineException(
          'Ambiguous interrupted manifest replacement in '
          '${quarantineDir.path}.',
        );
      }
      await temporaryFile.rename(manifestFile.path);
      return temporary;
    }
    if (temporary != null) {
      if (temporary.revision != 1) {
        throw QuarantineException(
          'Manifest staging file has no authoritative predecessor: '
          '${temporaryFile.path}.',
        );
      }
      await temporaryFile.rename(manifestFile.path);
      return temporary;
    }
    if (previous != null) {
      await _writeFlushed(manifestFile, previous.contents);
      return previous;
    }
    throw QuarantineException('Manifest not found: ${manifestFile.path}');
  }

  Future<_ManifestDocument> _readManifestCandidate(File file) async {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw QuarantineException(
        'Manifest candidate is not a real file: ${file.path}',
      );
    }
    try {
      final contents = await file.readAsString();
      final decoded = jsonDecode(contents);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('root must be a JSON object');
      }
      final payload = Map<String, dynamic>.from(decoded)..remove('_journal');
      final journal = decoded['_journal'];
      var revision = 0;
      late final String payloadSha256;
      if (journal == null) {
        payloadSha256 = sha256
            .convert(utf8.encode(jsonEncode(payload)))
            .toString();
      } else {
        if (journal is! Map<String, dynamic> ||
            journal['revision'] is! int ||
            (journal['revision'] as int) < 1 ||
            journal['payloadSha256'] is! String) {
          throw const FormatException('invalid manifest journal metadata');
        }
        revision = journal['revision'] as int;
        payloadSha256 = journal['payloadSha256'] as String;
        final actual = sha256
            .convert(utf8.encode(jsonEncode(payload)))
            .toString();
        if (actual != payloadSha256) {
          throw const FormatException('manifest payload checksum mismatch');
        }
      }
      final runLifecycle = switch (payload['_runLifecycle']) {
        null => null,
        final Map<String, dynamic> value => _RunLifecycleDocument.fromJson(
          value,
        ),
        _ => throw const FormatException('invalid run lifecycle marker'),
      };
      final caseDisplacements = switch (payload['_caseDisplacements']) {
        null => const <_CaseDisplacementDocument>[],
        final List<dynamic> value =>
          value
              .map(
                (item) => _CaseDisplacementDocument.fromJson(
                  item as Map<String, dynamic>,
                ),
              )
              .toList(growable: false),
        _ => throw const FormatException('invalid case displacement journal'),
      };
      if (caseDisplacements.map((item) => item.caseId).toSet().length !=
          caseDisplacements.length) {
        throw const FormatException('duplicate case displacement journal');
      }
      return _ManifestDocument(
        manifest: QuarantineManifest.fromJson(payload),
        revision: revision,
        payloadSha256: payloadSha256,
        contents: contents,
        runLifecycle: runLifecycle,
        caseDisplacements: caseDisplacements,
      );
    } on QuarantineException {
      rethrow;
    } catch (error) {
      throw QuarantineException(
        'Invalid quarantine manifest: ${file.path} ($error)',
      );
    }
  }

  Future<void> _writeFlushed(File file, String contents) async {
    final output = await file.open(mode: FileMode.write);
    try {
      await output.writeFrom(utf8.encode(contents));
      await output.flush();
    } finally {
      await output.close();
    }
  }

  Future<String> _computeSha256(File file) async {
    return (await sha256.bind(file.openRead()).first).toString();
  }

  File _quarantineFileFor(Directory quarantineDir, String originalPath) {
    final relativePath = _relativeProjectPath(originalPath);
    return File(p.join(quarantineDir.path, relativePath));
  }

  void _validateManifestProject(QuarantineManifest manifest) {
    final recordedRoot = manifest.projectRoot;
    if (recordedRoot != null) {
      if (!_sameProjectRoot(recordedRoot)) {
        throw QuarantineException(
          'Quarantine belongs to $recordedRoot, not project ${projectRoot.path}.',
        );
      }
      return;
    }

    final originalPaths = [
      ...manifest.entries.map((entry) => entry.originalPath),
      ...manifest.cases.map((applyCase) => applyCase.entry.originalPath),
    ];
    if (originalPaths.isEmpty) {
      throw QuarantineException(
        'Legacy manifest has no entries from which to verify the project.',
      );
    }
    for (final originalPath in originalPaths) {
      _relativeProjectPath(originalPath);
    }
  }

  bool _sameProjectRoot(String recordedRoot) {
    final selected = _canonicalDirectoryPath(projectRoot.path);
    final recorded = _canonicalDirectoryPath(recordedRoot);
    return p.equals(selected, recorded);
  }

  String _canonicalDirectoryPath(String path) {
    final normalized = p.normalize(p.absolute(path));
    try {
      return p.normalize(Directory(normalized).resolveSymbolicLinksSync());
    } on FileSystemException {
      return normalized;
    }
  }

  String _v1RestoreCaseId(String runId) => 'v1-$runId';

  Future<void> _invokeDisplacementHook(
    QuarantineDisplacementPoint point, {
    required String caseId,
    required File source,
    required File promotedBackup,
    required File candidate,
  }) async {
    final hook = _displacementHook;
    if (hook == null) return;
    await hook(
      QuarantineDisplacementContext(
        point: point,
        caseId: caseId,
        source: source,
        promotedBackup: promotedBackup,
        candidate: candidate,
      ),
    );
  }

  Future<void> _invokeRestoreHook(
    QuarantineRestorePoint point, {
    required String caseId,
    required File target,
    required File stagedOriginal,
    required File displacedTarget,
  }) async {
    final hook = _restoreHook;
    if (hook == null) return;
    await hook(
      QuarantineRestoreContext(
        point: point,
        caseId: caseId,
        target: target,
        stagedOriginal: stagedOriginal,
        displacedTarget: displacedTarget,
      ),
    );
  }

  Future<void> _replaceDisplacement(
    Directory quarantineDir,
    _CaseDisplacementDocument replacement,
  ) async {
    final document = await _resolveManifestDocument(quarantineDir);
    var found = false;
    final displacements = document.caseDisplacements.map((item) {
      if (item.caseId != replacement.caseId) return item;
      found = true;
      return replacement;
    }).toList();
    if (!found) {
      throw QuarantineException(
        'Case displacement not found: ${replacement.caseId}',
      );
    }
    await _writeManifest(
      quarantineDir,
      document.manifest,
      caseDisplacements: displacements,
    );
  }

  Future<void> _replaceCaseAndDisplacement(
    Directory quarantineDir, {
    required QuarantineCase replacementCase,
    required _CaseDisplacementDocument replacementDisplacement,
  }) async {
    final document = await _resolveManifestDocument(quarantineDir);
    var foundCase = false;
    final cases = document.manifest.cases.map((item) {
      if (item.caseId != replacementCase.caseId) return item;
      foundCase = true;
      return replacementCase;
    }).toList();
    var foundDisplacement = false;
    final displacements = document.caseDisplacements.map((item) {
      if (item.caseId != replacementDisplacement.caseId) return item;
      foundDisplacement = true;
      return replacementDisplacement;
    }).toList();
    if (!foundCase || !foundDisplacement) {
      throw QuarantineException(
        'Case displacement journal is incomplete: ${replacementCase.caseId}',
      );
    }
    await _writeManifest(
      quarantineDir,
      _copyManifest(document.manifest, cases: cases),
      caseDisplacements: displacements,
    );
  }

  Future<void> _markDisplacementRecoveryRequired(
    Directory quarantineDir,
    String caseId,
  ) async {
    final document = await _resolveManifestDocument(quarantineDir);
    var found = false;
    final displacements = document.caseDisplacements.map((item) {
      if (item.caseId != caseId) return item;
      found = true;
      return item.withState(_CaseDisplacementState.recoveryRequired);
    }).toList();
    if (!found) return;
    await _writeManifest(
      quarantineDir,
      document.manifest,
      caseDisplacements: displacements,
      runLifecycleState: document.manifest.usesTransactionJournal
          ? QuarantineRunLifecycleState.recoveryRequired
          : null,
    );
  }

  Future<void> _copyFileFlushed(
    File source,
    File destination, {
    required bool exclusive,
    int? expectedPosixMode,
  }) async {
    final sourcePosixMode = _readPosixMode(source);
    final publishPosixMode = expectedPosixMode ?? sourcePosixMode;
    if (expectedPosixMode != null && sourcePosixMode != expectedPosixMode) {
      throw QuarantineException(
        'Copy source permissions changed: ${source.path}. Expected '
        '${_formatPosixMode(expectedPosixMode)}, observed '
        '${_formatPosixMode(sourcePosixMode)}.',
      );
    }
    await destination.parent.create(recursive: true);
    if (!exclusive) {
      final input = await source.open();
      RandomAccessFile? output;
      try {
        output = await destination.open(mode: FileMode.writeOnly);
        while (true) {
          final bytes = await input.read(64 * 1024);
          if (bytes.isEmpty) break;
          await output.writeFrom(bytes);
        }
        await output.flush();
      } finally {
        await input.close();
        await output?.close();
      }
      await _setAndVerifyPosixMode(destination, publishPosixMode);
      return;
    }

    _atomicPublishExecutable();
    final sourceSha256 = await _hashRequiredRegularFile(
      source,
      label: 'Copy source',
    );
    final stagingDirectory = await destination.parent.createTemp(
      '.flutter_pruner-copy-',
    );
    final prepared = File(p.join(stagingDirectory.path, 'prepared'));
    final input = await source.open();
    RandomAccessFile? output;
    try {
      output = await prepared.open(mode: FileMode.writeOnly);
      while (true) {
        final bytes = await input.read(64 * 1024);
        if (bytes.isEmpty) break;
        await output.writeFrom(bytes);
      }
      await output.flush();
    } finally {
      await input.close();
      await output?.close();
    }
    await _setAndVerifyPosixMode(prepared, publishPosixMode);
    if (await _computeSha256(prepared) != sourceSha256 ||
        await _computeSha256(source) != sourceSha256 ||
        _readPosixMode(prepared) != publishPosixMode ||
        _readPosixMode(source) != sourcePosixMode) {
      throw QuarantineException(
        'Copy source or prepared bytes or permissions changed while staging '
        '${destination.path}. The prepared bytes were preserved at '
        '${prepared.path}.',
      );
    }
    await _publishFileNoReplace(
      prepared: prepared,
      target: destination,
      expectedSha256: sourceSha256,
      expectedPosixMode: publishPosixMode,
    );
    if (await _computeSha256(prepared) != sourceSha256 ||
        await _computeSha256(destination) != sourceSha256 ||
        _readPosixMode(prepared) != publishPosixMode ||
        _readPosixMode(destination) != publishPosixMode) {
      throw QuarantineException(
        'Published copy bytes or permissions changed before staging cleanup: '
        '${destination.path}. '
        'The linked prepared inode was preserved at ${prepared.path}.',
      );
    }
    await prepared.delete();
    await stagingDirectory.delete();
  }

  Future<void> _publishFileNoReplace({
    required File prepared,
    required File target,
    required String expectedSha256,
    int? expectedPosixMode,
  }) async {
    final executable = _atomicPublishExecutable();
    if (FileSystemEntity.typeSync(prepared.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await _computeSha256(prepared) != expectedSha256 ||
        _readPosixMode(prepared) != expectedPosixMode) {
      throw _AtomicPublishException(
        'Prepared publish inode is missing or changed: ${prepared.path}.',
      );
    }
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw _AtomicPublishException(
        'Publish target already exists: ${target.path}.',
      );
    }

    final arguments = Platform.isWindows
        ? ['hardlink', 'create', target.path, prepared.path]
        : [prepared.path, target.path];
    ManagedProcessResult result;
    try {
      result = await _atomicPublishProcessRunner.run(
        executable,
        arguments,
        workingDirectory: target.parent.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytesPerStream: 64 * 1024,
      );
    } on ProcessTerminationUnconfirmedException catch (error) {
      final state = await _describeAtomicPublishState(prepared, target);
      throw _AtomicPublishException(
        'Atomic link process termination was not confirmed: $error. $state',
      );
    } catch (error) {
      final state = await _describeAtomicPublishState(prepared, target);
      throw _AtomicPublishException(
        'Atomic link process could not be started: $error. $state',
      );
    }

    if (result.timedOut || result.exitCode != 0) {
      final state = await _describeAtomicPublishState(prepared, target);
      final stderrText = result.stderr.text.trim();
      throw _AtomicPublishException(
        'Atomic link process did not complete successfully '
        '(exit ${result.exitCode}${result.timedOut ? ', timed out' : ''})'
        '${stderrText.isEmpty ? '' : ': $stderrText'}. $state',
      );
    }
    final targetType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    if (targetType != FileSystemEntityType.file ||
        await _computeSha256(target) != expectedSha256 ||
        await _computeSha256(prepared) != expectedSha256 ||
        _readPosixMode(target) != expectedPosixMode ||
        _readPosixMode(prepared) != expectedPosixMode) {
      final state = await _describeAtomicPublishState(prepared, target);
      throw _AtomicPublishException(
        'Atomic link reported success without byte-exact linked paths. $state',
      );
    }
  }

  Future<void> _setAndVerifyPosixMode(File file, int? expectedMode) async {
    if (expectedMode == null) return;
    if (!_supportsPosixModes || expectedMode < 0 || expectedMode > 0xfff) {
      throw QuarantineException(
        'Cannot preserve POSIX mode ${_formatPosixMode(expectedMode)} for '
        '${file.path} on ${Platform.operatingSystem}.',
      );
    }
    final executable = _permissionExecutable();
    if (_readPosixMode(file) == expectedMode) return;

    final result = await _permissionProcessRunner.run(
      executable,
      [expectedMode.toRadixString(8), file.path],
      workingDirectory: file.parent.path,
      timeout: const Duration(seconds: 10),
      maxOutputBytesPerStream: 64 * 1024,
    );
    if (result.timedOut || result.exitCode != 0) {
      final stderrText = result.stderr.text.trim();
      throw QuarantineException(
        'POSIX permission update did not complete successfully for '
        '${file.path} (exit ${result.exitCode}'
        '${result.timedOut ? ', timed out' : ''})'
        '${stderrText.isEmpty ? '' : ': $stderrText'}.',
      );
    }
    final actualMode = _readPosixMode(file);
    if (actualMode != expectedMode) {
      throw QuarantineException(
        'POSIX permission verification failed for ${file.path}. Expected '
        '${_formatPosixMode(expectedMode)}, observed '
        '${_formatPosixMode(actualMode)}.',
      );
    }
  }

  String _permissionExecutable() {
    if (!_supportsPosixModes) {
      throw QuarantineException(
        'POSIX permission preservation is unavailable on '
        '${Platform.operatingSystem}.',
      );
    }
    const executable = '/bin/chmod';
    if (FileSystemEntity.typeSync(executable, followLinks: true) !=
        FileSystemEntityType.file) {
      throw QuarantineException(
        'POSIX permission helper is unavailable: /bin/chmod.',
      );
    }
    return executable;
  }

  bool get _supportsPosixModes => Platform.isLinux || Platform.isMacOS;

  int? _readPosixMode(File file) =>
      _supportsPosixModes ? file.statSync().mode & 0xfff : null;

  String _formatPosixMode(int? mode) =>
      mode == null ? 'not-recorded' : mode.toRadixString(8).padLeft(4, '0');

  String _atomicPublishExecutable() {
    late final String executable;
    if (Platform.isLinux || Platform.isMacOS) {
      executable = '/bin/ln';
    } else if (Platform.isWindows) {
      final systemRoot = Platform.environment['SystemRoot'];
      if (systemRoot == null || systemRoot.isEmpty) {
        throw QuarantineException(
          'Atomic no-replace publish is unavailable: SystemRoot is missing.',
        );
      }
      executable = p.join(systemRoot, 'System32', 'fsutil.exe');
    } else {
      throw QuarantineException(
        'Atomic no-replace publish is unsupported on '
        '${Platform.operatingSystem}.',
      );
    }
    if (FileSystemEntity.typeSync(executable, followLinks: true) !=
        FileSystemEntityType.file) {
      throw QuarantineException(
        'Atomic no-replace publish helper is unavailable: $executable.',
      );
    }
    return executable;
  }

  Future<String> _describeAtomicPublishState(File prepared, File target) async {
    Future<String> describe(File file) async {
      final type = FileSystemEntity.typeSync(file.path, followLinks: false);
      if (type != FileSystemEntityType.file) return '$type';
      try {
        return 'file:${await _computeSha256(file)}';
      } catch (error) {
        return 'file:unreadable:$error';
      }
    }

    return 'Observed prepared=${await describe(prepared)}, '
        'target=${await describe(target)}; neither path was removed.';
  }

  void _requireAbsentPath(String path, {required String label}) {
    final type = FileSystemEntity.typeSync(path, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      throw QuarantineException('$label already exists: $path');
    }
  }

  Future<String> _hashRequiredRegularFile(
    File file, {
    required String label,
  }) async {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type != FileSystemEntityType.file) {
      throw QuarantineDisplacementRecoveryRequiredException(
        '$label is missing or not a regular file: ${file.path}.',
      );
    }
    return _computeSha256(file);
  }

  Future<void> _requirePromotedBackupHash(
    File promotedBackup,
    _CaseDisplacementDocument displacement, {
    required int? expectedPosixMode,
  }) async {
    final actual = await _hashRequiredRegularFile(
      promotedBackup,
      label: 'Promoted case backup',
    );
    final actualPosixMode = _readPosixMode(promotedBackup);
    if (actual != displacement.expectedSha256 ||
        actualPosixMode != expectedPosixMode) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Promoted case backup bytes or permissions changed after source '
        'displacement: '
        '${promotedBackup.path}\nExpected SHA-256: '
        '${displacement.expectedSha256}\nActual SHA-256: $actual\n'
        'Expected POSIX mode: ${_formatPosixMode(expectedPosixMode)}\n'
        'Actual POSIX mode: ${_formatPosixMode(actualPosixMode)}',
      );
    }
  }

  Future<void> _validateDisplacedAppliedCase({
    required Directory quarantineDir,
    required QuarantineCase applyCase,
    required _CaseDisplacementDocument displacement,
    bool validateOutput = true,
  }) async {
    if (displacement.state != _CaseDisplacementState.installed &&
        displacement.state != _CaseDisplacementState.committed) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Case ${applyCase.caseId} has non-terminal displacement state '
        '${displacement.state.name}.',
      );
    }
    final promotedBackup = _caseSnapshotFor(quarantineDir, applyCase);
    await _requirePromotedBackupHash(
      promotedBackup,
      displacement,
      expectedPosixMode: applyCase.entry.posixMode,
    );
    final safetyCopy = _caseSafetyFile(quarantineDir, applyCase);
    final safetyHash = await _hashRequiredRegularFile(
      safetyCopy,
      label: 'Pre-displacement safety copy',
    );
    if (safetyHash != displacement.expectedSha256 ||
        _readPosixMode(safetyCopy) != applyCase.entry.posixMode) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Pre-displacement safety copy bytes or permissions changed: '
        '${safetyCopy.path}.',
      );
    }
    if (!validateOutput) return;

    final target = File(applyCase.entry.originalPath);
    final targetType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    final expectedOutput = applyCase.entry.modifiedSha256;
    if (expectedOutput == null) {
      if (targetType != FileSystemEntityType.notFound) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'A deleted case path was recreated: ${target.path}.',
        );
      }
      return;
    }
    if (targetType != FileSystemEntityType.file) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Case output is missing or not a regular file: ${target.path}.',
      );
    }
    final actualOutput = await _computeSha256(target);
    if (actualOutput != expectedOutput ||
        _readPosixMode(target) != applyCase.entry.posixMode) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Case output bytes or permissions changed after candidate '
        'installation: ${target.path}.',
      );
    }
  }

  Future<void> _preserveMismatchedPromotedBackup({
    required Directory quarantineDir,
    required QuarantineCase applyCase,
    required File promotedBackup,
    required File source,
  }) async {
    final recoveryFile = _caseDisplacementRecoveryFile(
      quarantineDir,
      applyCase,
    );
    if (!recoveryFile.existsSync()) {
      await _copyFileFlushed(promotedBackup, recoveryFile, exclusive: true);
    }
    final promotedHash = await _computeSha256(promotedBackup);
    if (await _computeSha256(recoveryFile) != promotedHash) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Could not preserve concurrently changed bytes: '
        '${promotedBackup.path}.',
      );
    }
    final sourceType = FileSystemEntity.typeSync(
      source.path,
      followLinks: false,
    );
    if (sourceType == FileSystemEntityType.notFound) {
      _validateRestoreTarget(source);
      try {
        await _copyFileFlushed(promotedBackup, source, exclusive: true);
      } on QuarantineException {
        // A concurrent recreation wins. Never replace it; the promoted inode
        // and recovery copy retain the displaced bytes for manual recovery.
      }
    }
  }

  Future<void> _prepareDisplacementsForRestore(
    Directory quarantineDir,
    _ManifestDocument document, {
    Set<String>? onlyCaseIds,
  }) async {
    _requireV3PosixModeEvidence(document.manifest);
    final selectedCases = document.manifest.cases
        .where(
          (applyCase) =>
              onlyCaseIds == null || onlyCaseIds.contains(applyCase.caseId),
        )
        .toList();
    final selectedCaseIds = selectedCases.map((item) => item.caseId).toSet();
    final displacements = document.caseDisplacements
        .where((item) => selectedCaseIds.contains(item.caseId))
        .toList();
    if (displacements.isEmpty) return;
    _atomicPublishExecutable();

    final casesById = {for (final item in selectedCases) item.caseId: item};
    final firstByPath = <String, QuarantineCase>{};
    final lastByPath = <String, QuarantineCase>{};
    for (final applyCase in selectedCases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
      lastByPath[applyCase.entry.originalPath] = applyCase;
    }
    for (final entry in firstByPath.entries) {
      final modes = selectedCases
          .where((item) => item.entry.originalPath == entry.key)
          .map((item) => item.entry.posixMode)
          .toSet();
      if (modes.length != 1) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Case journal contains conflicting POSIX modes for ${entry.key}.',
        );
      }
    }

    final targetHashes = <String, String?>{};
    for (final entry in firstByPath.entries) {
      final target = File(entry.key);
      final restoreDisplaced = File(
        p.join(
          _restoreStagingDirectory(
            _caseSnapshotFor(quarantineDir, entry.value),
            entry.value.caseId,
          ).path,
          'displaced',
        ),
      );
      final targetExistsBeforeRecovery =
          FileSystemEntity.typeSync(target.path, followLinks: false) ==
          FileSystemEntityType.file;
      final displacedExistsBeforeRecovery =
          FileSystemEntity.typeSync(
            restoreDisplaced.path,
            followLinks: false,
          ) ==
          FileSystemEntityType.file;
      await _recoverInterruptedRestore(
        quarantineDir: quarantineDir,
        snapshot: _caseSnapshotFor(quarantineDir, entry.value),
        target: target,
        caseId: entry.value.caseId,
        allowedExpectedTargetSha256s: {
          entry.value.entry.sha256,
          lastByPath[entry.key]!.entry.modifiedSha256,
          ...displacements
              .where(
                (item) =>
                    casesById[item.caseId]!.entry.originalPath == entry.key,
              )
              .map((item) => item.candidateSha256),
        },
        originalPosixMode: entry.value.entry.posixMode,
        expectedTargetPosixMode:
            targetExistsBeforeRecovery || displacedExistsBeforeRecovery
            ? entry.value.entry.posixMode
            : null,
      );
      final targetType = FileSystemEntity.typeSync(
        target.path,
        followLinks: false,
      );
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.file) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Restore target is neither absent nor a regular file: '
          '${target.path}. No project bytes were changed.',
        );
      }
      final targetHash = targetType == FileSystemEntityType.file
          ? await _computeSha256(target)
          : null;
      final targetMode = targetType == FileSystemEntityType.file
          ? _readPosixMode(target)
          : null;
      final firstHash = entry.value.entry.sha256;
      final finalHash = lastByPath[entry.key]!.entry.modifiedSha256;
      final journaledInstallHashes = displacements
          .where(
            (item) =>
                casesById[item.caseId]!.entry.originalPath == entry.key &&
                (item.state == _CaseDisplacementState.installing ||
                    item.state == _CaseDisplacementState.installed ||
                    item.state == _CaseDisplacementState.committed),
          )
          .map((item) => item.candidateSha256)
          .whereType<String>()
          .toSet();
      if (targetHash != firstHash &&
          targetHash != finalHash &&
          !journaledInstallHashes.contains(targetHash)) {
        for (final displacement in displacements.where(
          (item) => casesById[item.caseId]!.entry.originalPath == entry.key,
        )) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            displacement.caseId,
          );
        }
        throw QuarantineDisplacementRecoveryRequiredException(
          'Restore target has bytes outside the journal: ${target.path}. '
          'The project path and all quarantine copies were preserved.',
        );
      }
      if (targetHash != null && targetMode != entry.value.entry.posixMode) {
        for (final displacement in displacements.where(
          (item) => casesById[item.caseId]!.entry.originalPath == entry.key,
        )) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            displacement.caseId,
          );
        }
        throw QuarantineDisplacementRecoveryRequiredException(
          'Restore target permissions are outside the journal: '
          '${target.path}. The project path and all quarantine copies were '
          'preserved.',
        );
      }
      targetHashes[entry.key] = targetHash;
    }

    final plans = <_DisplacementRestorePlan>[];
    for (final displacement in displacements) {
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null ||
          displacement.expectedSha256 != applyCase.entry.sha256) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Case displacement journal does not match its case snapshot: '
          '${displacement.caseId}.',
        );
      }
      if (displacement.state == _CaseDisplacementState.recoveryRequired) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Case ${displacement.caseId} is marked recovery-required. '
          'Automatic restore is disabled so recovery bytes remain untouched.',
        );
      }

      final promotedBackup = _caseSnapshotFor(quarantineDir, applyCase);
      final safetyCopy = _caseSafetyFile(quarantineDir, applyCase);
      final safetyHash = await _hashRequiredRegularFile(
        safetyCopy,
        label: 'Pre-displacement safety copy',
      );
      if (safetyHash != displacement.expectedSha256 ||
          _readPosixMode(safetyCopy) != applyCase.entry.posixMode) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Pre-displacement safety copy bytes or permissions changed: '
          '${safetyCopy.path}.',
        );
      }

      final promotedType = FileSystemEntity.typeSync(
        promotedBackup.path,
        followLinks: false,
      );
      var reconstructPromoted = false;
      if (promotedType == FileSystemEntityType.file) {
        final promotedHash = await _computeSha256(promotedBackup);
        if (promotedHash != displacement.expectedSha256 ||
            _readPosixMode(promotedBackup) != applyCase.entry.posixMode) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            displacement.caseId,
          );
          throw QuarantineDisplacementRecoveryRequiredException(
            'Promoted case backup bytes or permissions drifted after '
            'displacement: '
            '${promotedBackup.path}. The drifted bytes were preserved.',
          );
        }
      } else if (promotedType == FileSystemEntityType.notFound &&
          displacement.state == _CaseDisplacementState.intent &&
          targetHashes[applyCase.entry.originalPath] ==
              displacement.expectedSha256) {
        // A crash before the source rename leaves the source and immutable
        // safety copy intact. Recreate only the quarantine-side snapshot;
        // the project path is not mutated during this preparation phase.
        reconstructPromoted = true;
      } else {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Authoritative promoted backup is missing or ambiguous for case '
          '${displacement.caseId}. No project bytes were changed.',
        );
      }

      final candidate = _caseCandidateFile(
        applyCase,
        runId: document.manifest.runId,
      );
      final candidateType = FileSystemEntity.typeSync(
        candidate.path,
        followLinks: false,
      );
      if (candidateType != FileSystemEntityType.notFound &&
          candidateType != FileSystemEntityType.file) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Case candidate is neither absent nor a regular file: '
          '${candidate.path}.',
        );
      }
      final candidateRecovery = _caseCandidateRecoveryFile(
        quarantineDir,
        applyCase,
      );
      final candidateRecoveryType = FileSystemEntity.typeSync(
        candidateRecovery.path,
        followLinks: false,
      );
      if (candidateType == FileSystemEntityType.file &&
          candidateRecoveryType != FileSystemEntityType.notFound) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Both live and recovery candidates exist for case '
          '${displacement.caseId}; both were preserved.',
        );
      }
      if (candidateRecoveryType != FileSystemEntityType.notFound &&
          candidateRecoveryType != FileSystemEntityType.file) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Candidate recovery path is not a regular file: '
          '${candidateRecovery.path}.',
        );
      }
      final candidateHash = candidateType == FileSystemEntityType.file
          ? await _computeSha256(candidate)
          : null;
      final candidateMode = candidateType == FileSystemEntityType.file
          ? _readPosixMode(candidate)
          : null;
      final candidateIsJournaled =
          candidateHash != null &&
          candidateMode == applyCase.entry.posixMode &&
          displacement.candidateSha256 != null &&
          candidateHash == displacement.candidateSha256 &&
          (displacement.state == _CaseDisplacementState.installing ||
              displacement.state == _CaseDisplacementState.installed ||
              displacement.state == _CaseDisplacementState.committed);
      if (candidateType == FileSystemEntityType.file &&
          displacement.candidateSha256 != null &&
          !candidateIsJournaled) {
        await _markDisplacementRecoveryRequired(
          quarantineDir,
          displacement.caseId,
        );
        throw QuarantineDisplacementRecoveryRequiredException(
          'Journaled candidate bytes changed for case '
          '${displacement.caseId}. The candidate and project path were '
          'preserved.',
        );
      }
      plans.add(
        _DisplacementRestorePlan(
          applyCase: applyCase,
          displacement: displacement,
          promotedBackup: promotedBackup,
          safetyCopy: safetyCopy,
          candidate: candidate,
          candidateRecovery: candidateRecovery,
          reconstructPromoted: reconstructPromoted,
          preserveCandidate:
              candidateType == FileSystemEntityType.file &&
              !candidateIsJournaled,
        ),
      );
    }

    // No project path is changed above. Execute quarantine-only recovery work
    // only after every selected path and case passed the read-only preflight.
    for (final plan in plans) {
      if (plan.preserveCandidate) {
        await plan.candidateRecovery.parent.create(recursive: true);
        try {
          await plan.candidate.rename(plan.candidateRecovery.path);
        } on FileSystemException catch (error) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            plan.displacement.caseId,
          );
          throw QuarantineDisplacementRecoveryRequiredException(
            'Could not atomically preserve the interrupted candidate for '
            '${plan.displacement.caseId}: $error',
          );
        }
      }
      if (plan.reconstructPromoted) {
        await _copyFileFlushed(
          plan.safetyCopy,
          plan.promotedBackup,
          exclusive: true,
          expectedPosixMode: plan.applyCase.entry.posixMode,
        );
        if (await _computeSha256(plan.promotedBackup) !=
                plan.displacement.expectedSha256 ||
            _readPosixMode(plan.promotedBackup) !=
                plan.applyCase.entry.posixMode) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            plan.displacement.caseId,
          );
          throw QuarantineDisplacementRecoveryRequiredException(
            'Reconstructed promoted backup hash mismatch for '
            '${plan.displacement.caseId}.',
          );
        }
        final target = File(plan.applyCase.entry.originalPath);
        if (!target.existsSync() ||
            await _computeSha256(target) != plan.displacement.expectedSha256 ||
            _readPosixMode(target) != plan.applyCase.entry.posixMode) {
          await _markDisplacementRecoveryRequired(
            quarantineDir,
            plan.displacement.caseId,
          );
          throw QuarantineDisplacementRecoveryRequiredException(
            'Source changed while recovering a pre-rename crash: '
            '${target.path}. The source was not overwritten.',
          );
        }
      }
    }
  }

  Future<void> _markDisplacementsRestored(
    Directory quarantineDir, {
    Set<String>? onlyCaseIds,
  }) async {
    final document = await _resolveManifestDocument(quarantineDir);
    if (document.caseDisplacements.isEmpty) return;
    final casesById = {
      for (final applyCase in document.manifest.cases)
        applyCase.caseId: applyCase,
    };
    final firstByPath = <String, QuarantineCase>{};
    for (final applyCase in document.manifest.cases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
    }
    for (final displacement in document.caseDisplacements) {
      if (onlyCaseIds != null && !onlyCaseIds.contains(displacement.caseId)) {
        continue;
      }
      final applyCase = casesById[displacement.caseId];
      if (applyCase == null) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Displacement references missing case ${displacement.caseId}.',
        );
      }
      await _requirePromotedBackupHash(
        _caseSnapshotFor(quarantineDir, applyCase),
        displacement,
        expectedPosixMode: applyCase.entry.posixMode,
      );
      final safetyHash = await _hashRequiredRegularFile(
        _caseSafetyFile(quarantineDir, applyCase),
        label: 'Pre-displacement safety copy',
      );
      final safetyMode = _readPosixMode(
        _caseSafetyFile(quarantineDir, applyCase),
      );
      if (safetyHash != displacement.expectedSha256 ||
          safetyMode != applyCase.entry.posixMode) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Pre-displacement safety copy bytes or permissions drifted for '
          '${displacement.caseId}.',
        );
      }
      final first = firstByPath[applyCase.entry.originalPath]!;
      final target = File(first.entry.originalPath);
      if (!target.existsSync() ||
          await _computeSha256(target) != first.entry.sha256 ||
          _readPosixMode(target) != first.entry.posixMode) {
        throw QuarantineDisplacementRecoveryRequiredException(
          'Restored source bytes or permissions no longer match the '
          'run-original snapshot: '
          '${target.path}.',
        );
      }
      final candidate = _caseCandidateFile(
        applyCase,
        runId: document.manifest.runId,
      );
      final candidateType = FileSystemEntity.typeSync(
        candidate.path,
        followLinks: false,
      );
      if (candidateType != FileSystemEntityType.notFound) {
        if (candidateType != FileSystemEntityType.file ||
            displacement.candidateSha256 == null ||
            await _computeSha256(candidate) != displacement.candidateSha256 ||
            _readPosixMode(candidate) != applyCase.entry.posixMode) {
          throw QuarantineDisplacementRecoveryRequiredException(
            'Live candidate remains with unverified bytes after restore: '
            '${candidate.path}.',
          );
        }
        await candidate.delete();
      }
    }
    final replacements = document.caseDisplacements.map((displacement) {
      if (onlyCaseIds != null && !onlyCaseIds.contains(displacement.caseId)) {
        return displacement;
      }
      return displacement.withState(_CaseDisplacementState.restored);
    }).toList();
    await _writeManifest(
      quarantineDir,
      document.manifest,
      caseDisplacements: replacements,
    );
  }

  Future<QuarantineCase> _caseById(
    Directory quarantineDir,
    String caseId,
  ) async {
    final manifest = await _readManifest(quarantineDir);
    try {
      return manifest.cases.firstWhere((item) => item.caseId == caseId);
    } on StateError {
      throw QuarantineException('Case not found: $caseId');
    }
  }

  Future<QuarantineCase> _replaceCase(
    Directory quarantineDir,
    QuarantineCase replacement,
  ) async {
    final manifest = await _readManifest(quarantineDir);
    var found = false;
    final cases = manifest.cases.map((item) {
      if (item.caseId != replacement.caseId) return item;
      found = true;
      return replacement;
    }).toList();
    if (!found) {
      throw QuarantineException('Case not found: ${replacement.caseId}');
    }
    await _writeManifest(quarantineDir, _copyManifest(manifest, cases: cases));
    return replacement;
  }

  Future<QuarantineTransaction> _updateTransaction(
    Directory quarantineDir,
    String transactionId,
    QuarantineTransaction Function(QuarantineTransaction) update,
  ) async {
    final manifest = await _readManifest(quarantineDir);
    QuarantineTransaction? replacement;
    final transactions = manifest.transactions.map((transaction) {
      if (transaction.transactionId != transactionId) return transaction;
      replacement = update(transaction);
      return replacement!;
    }).toList();
    if (replacement == null) {
      throw QuarantineException('Transaction not found: $transactionId');
    }
    await _writeManifest(
      quarantineDir,
      _copyManifest(manifest, transactions: transactions),
    );
    return replacement!;
  }

  QuarantineTransaction _transactionById(
    QuarantineManifest manifest,
    String transactionId,
  ) {
    try {
      return manifest.transactions.firstWhere(
        (transaction) => transaction.transactionId == transactionId,
      );
    } on StateError {
      throw QuarantineException('Transaction not found: $transactionId');
    }
  }

  void _requireTransactionStatus(
    QuarantineTransaction transaction,
    Set<QuarantineTransactionStatus> allowed,
  ) {
    if (allowed.contains(transaction.status)) return;
    throw QuarantineException(
      'Illegal transaction transition from ${transaction.status.name}: '
      '${transaction.transactionId}',
    );
  }

  void _validateVerificationEvidence({
    required QuarantineTransaction transaction,
    required String policyHash,
    required List<String> requiredStepIds,
    required List<String> observedStepIds,
  }) {
    final expectedPolicyHash = transaction.verificationPolicyHash;
    if (expectedPolicyHash != null && expectedPolicyHash != policyHash) {
      throw QuarantineException(
        'Verification policy mismatch for ${transaction.transactionId}.',
      );
    }
    final required = requiredStepIds.toSet();
    final observed = observedStepIds.toSet();
    if (requiredStepIds.isEmpty ||
        required.length != requiredStepIds.length ||
        observed.length != observedStepIds.length ||
        required.difference(observed).isNotEmpty ||
        observed.difference(required).isNotEmpty) {
      throw QuarantineException(
        'Verification steps are incomplete for ${transaction.transactionId}.',
      );
    }
  }

  QuarantineManifest _copyManifest(
    QuarantineManifest manifest, {
    List<QuarantineEntry>? entries,
    List<QuarantineCase>? cases,
    List<QuarantineTransaction>? transactions,
    DateTime? fullRollbackAtUtc,
    bool? fullRollbackVerified,
  }) => QuarantineManifest(
    runId: manifest.runId,
    timestamp: manifest.timestamp,
    projectRoot: manifest.projectRoot,
    entries: entries ?? manifest.entries,
    cases: cases ?? manifest.cases,
    transactions: transactions ?? manifest.transactions,
    caseJournal: manifest.caseJournal,
    transactionJournal: manifest.transactionJournal,
    verificationPolicyHash: manifest.verificationPolicyHash,
    baselineVerification: manifest.baselineVerification,
    analysisMode: manifest.analysisMode,
    acceptedRiskCodes: manifest.acceptedRiskCodes,
    riskAcceptanceSource: manifest.riskAcceptanceSource,
    selection: manifest.selection,
    fullRollbackAtUtc: fullRollbackAtUtc ?? manifest.fullRollbackAtUtc,
    fullRollbackVerified: fullRollbackVerified ?? manifest.fullRollbackVerified,
  );

  Future<void> _recordFullRollback(Directory quarantineDir) async {
    final manifest = await _readManifest(quarantineDir);
    final cases = manifest.cases
        .map(
          (applyCase) => applyCase.withStatus(
            QuarantineCaseStatus.rolledBack,
            failureReason: 'restored by full rollback',
          ),
        )
        .toList();
    final transactions = manifest.transactions
        .map(
          (transaction) => transaction.withState(
            status: QuarantineTransactionStatus.rolledBackVerified,
            rollbackVerified: true,
            failureReason: 'restored by full rollback',
          ),
        )
        .toList();
    await _writeManifest(
      quarantineDir,
      _copyManifest(
        manifest,
        cases: cases,
        transactions: transactions,
        fullRollbackAtUtc: manifest.fullRollbackAtUtc ?? DateTime.now().toUtc(),
        fullRollbackVerified: true,
      ),
      runLifecycleState: manifest.usesTransactionJournal
          ? QuarantineRunLifecycleState.rolledBackVerified
          : null,
    );
  }

  void _validateSnapshotSource(File file) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw QuarantineException('File no longer exists: ${file.path}');
    }
    if (type != FileSystemEntityType.file) {
      throw QuarantineException(
        'Snapshot source is not a regular file: ${file.path}',
      );
    }
    final canonicalRoot = _canonicalDirectoryPath(projectRoot.path);
    final canonicalFile = p.normalize(file.resolveSymbolicLinksSync());
    if (!p.equals(canonicalRoot, canonicalFile) &&
        !p.isWithin(canonicalRoot, canonicalFile)) {
      throw QuarantineException(
        'Snapshot source resolves outside project root: ${file.path}',
      );
    }
  }

  Future<void> _verifyCaseWorkingCopy(
    Directory quarantineDir,
    QuarantineCase applyCase,
    File target,
    File snapshot,
  ) async {
    final expectedTargetPosixMode = _expectedRestoreTargetPosixMode(
      snapshot: snapshot,
      target: target,
      caseId: applyCase.caseId,
      recordedMode: applyCase.entry.posixMode,
    );
    await _recoverInterruptedRestore(
      quarantineDir: quarantineDir,
      snapshot: snapshot,
      target: target,
      caseId: applyCase.caseId,
      allowedExpectedTargetSha256s: {
        applyCase.entry.sha256,
        applyCase.entry.modifiedSha256,
      },
      originalPosixMode: applyCase.entry.posixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
    );
    final currentSha256 = target.existsSync()
        ? await _computeSha256(target)
        : null;
    final currentPosixMode = target.existsSync()
        ? _readPosixMode(target)
        : null;
    if (currentSha256 == applyCase.entry.sha256 &&
        currentPosixMode == applyCase.entry.posixMode) {
      return;
    }
    final afterSha256 = applyCase.entry.modifiedSha256;
    if (applyCase.status == QuarantineCaseStatus.backedUp) {
      throw QuarantineException(
        'Case ${applyCase.caseId} has an unrecorded working-copy state.',
      );
    }
    if (afterSha256 == null) {
      if (!target.existsSync()) return;
      throw QuarantineException(
        'Case output unexpectedly exists: ${target.path}',
      );
    }
    if (currentSha256 != afterSha256 ||
        currentPosixMode != applyCase.entry.posixMode) {
      throw QuarantineException(
        'Case output bytes or permissions changed after apply: '
        '${target.path}\n'
        'Refusing to overwrite user changes.',
      );
    }
  }

  Future<void> _restoreCaseJournal(
    Directory quarantineDir,
    _ManifestDocument document,
  ) async {
    final manifest = document.manifest;
    final journalCases = manifest.cases;
    if (journalCases.isEmpty) return;
    final journalCasesById = {
      for (final applyCase in journalCases) applyCase.caseId: applyCase,
    };

    final firstByPath = <String, QuarantineCase>{};
    final lastByPath = <String, QuarantineCase>{};
    for (final applyCase in journalCases) {
      firstByPath.putIfAbsent(applyCase.entry.originalPath, () => applyCase);
      lastByPath[applyCase.entry.originalPath] = applyCase;

      final snapshot = _caseSnapshotFor(quarantineDir, applyCase);
      if (!snapshot.existsSync() ||
          await _computeSha256(snapshot) != applyCase.entry.sha256) {
        throw QuarantineException(
          'Valid snapshot missing for case ${applyCase.caseId}: '
          '${snapshot.path}',
        );
      }
    }

    final interruptedPaths = <String>{};
    for (final applyCase in journalCases) {
      if (applyCase.status == QuarantineCaseStatus.backedUp) {
        interruptedPaths.add(applyCase.entry.originalPath);
      }
    }

    for (final applyCase in lastByPath.values) {
      final target = File(applyCase.entry.originalPath);
      final firstCase = firstByPath[applyCase.entry.originalPath]!;
      final expectedTargetPosixMode = _expectedRestoreTargetPosixMode(
        snapshot: _caseSnapshotFor(quarantineDir, firstCase),
        target: target,
        caseId: firstCase.caseId,
        recordedMode: firstCase.entry.posixMode,
      );
      await _recoverInterruptedRestore(
        quarantineDir: quarantineDir,
        snapshot: _caseSnapshotFor(quarantineDir, firstCase),
        target: target,
        caseId: firstCase.caseId,
        allowedExpectedTargetSha256s: {
          firstCase.entry.sha256,
          ...journalCases
              .where(
                (item) =>
                    item.entry.originalPath == applyCase.entry.originalPath,
              )
              .map((item) => item.entry.modifiedSha256),
          ...document.caseDisplacements
              .where(
                (item) =>
                    journalCasesById[item.caseId]?.entry.originalPath ==
                    applyCase.entry.originalPath,
              )
              .map((item) => item.candidateSha256),
        },
        originalPosixMode: firstCase.entry.posixMode,
        expectedTargetPosixMode: expectedTargetPosixMode,
      );
      if (interruptedPaths.contains(applyCase.entry.originalPath)) {
        final targetSha256 = target.existsSync()
            ? await _computeSha256(target)
            : null;
        final journalOwnsTarget =
            (await _resolveManifestDocument(
              quarantineDir,
            )).caseDisplacements.any(
              (item) =>
                  item.caseId == applyCase.caseId &&
                  item.candidateSha256 != null &&
                  item.candidateSha256 == targetSha256 &&
                  (item.state == _CaseDisplacementState.installing ||
                      item.state == _CaseDisplacementState.installed ||
                      item.state == _CaseDisplacementState.committed),
            );
        if (!journalOwnsTarget) {
          await _preserveInterruptedWorkingCopy(
            quarantineDir: quarantineDir,
            applyCase: applyCase,
            target: target,
          );
        }
      } else {
        final currentSha256 = target.existsSync()
            ? await _computeSha256(target)
            : null;
        final currentPosixMode = target.existsSync()
            ? _readPosixMode(target)
            : null;
        // A crash may happen after all original bytes were restored but
        // before the manifest journal was updated. Accept only the verified
        // first snapshot hash as that idempotent recovery state.
        if (currentSha256 != firstCase.entry.sha256 ||
            currentPosixMode != firstCase.entry.posixMode) {
          final expectedJournalHashes = journalCases
              .where(
                (item) =>
                    item.entry.originalPath == applyCase.entry.originalPath,
              )
              .map((item) => item.entry.modifiedSha256)
              .toSet();
          if (!expectedJournalHashes.contains(currentSha256) ||
              (currentSha256 != null &&
                  currentPosixMode != applyCase.entry.posixMode)) {
            throw QuarantineException(
              'Case output bytes or permissions changed after apply: '
              '${target.path}\n'
              'Refusing to overwrite user changes.',
            );
          }
        }
      }
    }

    for (final applyCase in firstByPath.values) {
      final target = File(applyCase.entry.originalPath);
      final expectedTargetSha256 = target.existsSync()
          ? await _computeSha256(target)
          : null;
      final expectedTargetPosixMode = target.existsSync()
          ? applyCase.entry.posixMode
          : null;
      await _restoreSnapshot(
        quarantineDir: quarantineDir,
        snapshot: _caseSnapshotFor(quarantineDir, applyCase),
        target: target,
        caseId: applyCase.caseId,
        expectedTargetSha256: expectedTargetSha256,
        originalPosixMode: applyCase.entry.posixMode,
        expectedTargetPosixMode: expectedTargetPosixMode,
        allowedExpectedTargetSha256s: {
          applyCase.entry.sha256,
          ...journalCases
              .where(
                (item) =>
                    item.entry.originalPath == applyCase.entry.originalPath,
              )
              .map((item) => item.entry.modifiedSha256),
          ...document.caseDisplacements
              .where(
                (item) =>
                    journalCasesById[item.caseId]?.entry.originalPath ==
                    applyCase.entry.originalPath,
              )
              .map((item) => item.candidateSha256),
        },
      );
      if (!target.existsSync() ||
          await _computeSha256(target) != applyCase.entry.sha256 ||
          _readPosixMode(target) != applyCase.entry.posixMode) {
        throw QuarantineException(
          'Full rollback bytes or permissions mismatch: ${target.path}',
        );
      }
    }
  }

  Future<void> _preserveInterruptedWorkingCopy({
    required Directory quarantineDir,
    required QuarantineCase applyCase,
    required File target,
  }) async {
    if (!target.existsSync()) return;
    if (await _computeSha256(target) == applyCase.entry.sha256 &&
        _readPosixMode(target) == applyCase.entry.posixMode) {
      return;
    }

    final relativePath = _relativeProjectPath(target.path);
    final recoveryFile = File(
      p.join(quarantineDir.path, 'recovery', applyCase.caseId, relativePath),
    );
    await _copyFileFlushed(target, recoveryFile, exclusive: true);
  }

  Future<void> _restoreSnapshot({
    required Directory quarantineDir,
    required File snapshot,
    required File target,
    required String caseId,
    required String? expectedTargetSha256,
    required int? originalPosixMode,
    required int? expectedTargetPosixMode,
    Set<String?>? allowedExpectedTargetSha256s,
  }) async {
    _atomicPublishExecutable();
    _validateRestoreTarget(target);
    final allowedTargetHashes =
        allowedExpectedTargetSha256s ?? {expectedTargetSha256};
    final expectedModeMatchesJournal = expectedTargetSha256 == null
        ? expectedTargetPosixMode == null
        : expectedTargetPosixMode == originalPosixMode;
    if (!allowedTargetHashes.contains(expectedTargetSha256) ||
        !expectedModeMatchesJournal) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore preflight expected bytes or permissions are outside '
            'the journal for ${target.path}.',
      );
    }
    final originalSha256 = await _computeSha256(snapshot);
    final snapshotPosixMode = _readPosixMode(snapshot);
    if (snapshotPosixMode != originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore snapshot permissions do not match the journal: '
            '${snapshot.path}.',
      );
    }
    if (await _recoverInterruptedRestore(
      quarantineDir: quarantineDir,
      snapshot: snapshot,
      target: target,
      caseId: caseId,
      allowedExpectedTargetSha256s: allowedTargetHashes,
      originalPosixMode: originalPosixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
    )) {
      return;
    }
    _validateRestoreTarget(target);
    final preflightTargetSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final preflightTargetPosixMode = preflightTargetSha256 == null
        ? null
        : _readPosixMode(target);
    if (preflightTargetSha256 == originalSha256 &&
        preflightTargetPosixMode == originalPosixMode) {
      return;
    }
    if (preflightTargetSha256 != expectedTargetSha256 ||
        preflightTargetPosixMode != expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore target bytes or permissions changed before staging: '
            '${target.path}. '
            'No project path was overwritten.',
      );
    }
    await target.parent.create(recursive: true);
    final stagingDirectory = _restoreStagingDirectory(snapshot, caseId);
    final staged = File(p.join(stagingDirectory.path, 'restored'));
    final displaced = File(p.join(stagingDirectory.path, 'displaced'));
    final intent = await _prepareRestoreIntent(
      quarantineDir: quarantineDir,
      snapshot: snapshot,
      target: target,
      caseId: caseId,
      expectedTargetSha256: expectedTargetSha256,
      originalSha256: originalSha256,
      originalPosixMode: originalPosixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
    );

    final currentTargetSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final currentTargetPosixMode = currentTargetSha256 == null
        ? null
        : _readPosixMode(target);
    if (currentTargetSha256 == originalSha256 &&
        currentTargetPosixMode == originalPosixMode) {
      return;
    }
    if (currentTargetSha256 != intent.expectedTargetSha256 ||
        currentTargetPosixMode != intent.expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore target bytes or permissions changed after preflight: '
            '${target.path}. '
            'The target and staged original were preserved.',
      );
    }

    await _invokeRestoreHook(
      QuarantineRestorePoint.beforeTargetDisplacement,
      caseId: caseId,
      target: target,
      stagedOriginal: staged,
      displacedTarget: displaced,
    );
    if (currentTargetSha256 != null) {
      _requireAbsentPath(displaced.path, label: 'restore displaced target');
      try {
        await target.rename(displaced.path);
      } on FileSystemException catch (error) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Could not atomically preserve the restore target '
              '${target.path}: $error',
        );
      }
      final displacedSha256 = await _restoreRequiredFileSha256(
        displaced,
        quarantineDir: quarantineDir,
        caseId: caseId,
        label: 'Restore displaced target',
      );
      final displacedPosixMode = _readPosixMode(displaced);
      if (displacedSha256 != intent.expectedTargetSha256 ||
          displacedPosixMode != intent.expectedTargetPosixMode) {
        await _restoreDisplacedWithoutOverwrite(
          displaced: displaced,
          target: target,
        );
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Restore target changed while it was being displaced: '
              '${target.path}. Both observed copies and the staged original '
              'were preserved.',
        );
      }
    }

    await _invokeRestoreHook(
      QuarantineRestorePoint.beforeOriginalInstall,
      caseId: caseId,
      target: target,
      stagedOriginal: staged,
      displacedTarget: displaced,
    );
    try {
      await _publishRestoreOriginal(
        snapshot: snapshot,
        staged: staged,
        target: target,
        caseId: caseId,
        expectedSha256: originalSha256,
        expectedPosixMode: originalPosixMode,
      );
    } on _AtomicPublishException catch (error) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Atomic no-replace restore installation failed for '
            '${target.path}. The target and every staged path were '
            'preserved. $error',
      );
    }
    await _invokeRestoreHook(
      QuarantineRestorePoint.afterOriginalInstall,
      caseId: caseId,
      target: target,
      stagedOriginal: staged,
      displacedTarget: displaced,
    );
    final installedSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final installedPosixMode = installedSha256 == null
        ? null
        : _readPosixMode(target);
    if (installedSha256 != originalSha256 ||
        installedPosixMode != originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restored target bytes or permissions changed during '
            'installation: '
            '${target.path}. The target, staged original, and displaced '
            'target were preserved.',
      );
    }
  }

  Future<bool> _recoverInterruptedRestore({
    required Directory quarantineDir,
    required File snapshot,
    required File target,
    required String caseId,
    required Set<String?> allowedExpectedTargetSha256s,
    required int? originalPosixMode,
    required int? expectedTargetPosixMode,
  }) async {
    _validateRestoreTarget(target);
    final stagingDirectory = _restoreStagingDirectory(snapshot, caseId);
    final stagingType = FileSystemEntity.typeSync(
      stagingDirectory.path,
      followLinks: false,
    );
    if (stagingType == FileSystemEntityType.notFound) return false;
    if (stagingType != FileSystemEntityType.directory) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore staging path is not a real directory: '
            '${stagingDirectory.path}.',
      );
    }
    final staged = File(p.join(stagingDirectory.path, 'restored'));
    final displaced = File(p.join(stagingDirectory.path, 'displaced'));
    final originalSha256 = await _computeSha256(snapshot);
    if (_readPosixMode(snapshot) != originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore snapshot permissions no longer match the journal: '
            '${snapshot.path}.',
      );
    }
    final intent = await _resolveRestoreIntent(
      stagingDirectory: stagingDirectory,
      snapshot: snapshot,
      target: target,
      quarantineDir: quarantineDir,
      caseId: caseId,
      allowedExpectedTargetSha256s: allowedExpectedTargetSha256s,
      originalPosixMode: originalPosixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
    );
    if (intent.targetPath != p.normalize(p.absolute(target.path)) ||
        intent.originalSha256 != originalSha256 ||
        !allowedExpectedTargetSha256s.contains(intent.expectedTargetSha256) ||
        intent.originalPosixMode != originalPosixMode ||
        intent.expectedTargetPosixMode != expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore intent does not match its target or snapshot: '
            '${stagingDirectory.path}.',
      );
    }

    final displacedType = FileSystemEntity.typeSync(
      displaced.path,
      followLinks: false,
    );
    if (displacedType != FileSystemEntityType.notFound &&
        displacedType != FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore displaced path is not a regular file: '
            '${displaced.path}.',
      );
    }
    final stagedType = FileSystemEntity.typeSync(
      staged.path,
      followLinks: false,
    );
    if (stagedType == FileSystemEntityType.notFound &&
        displacedType == FileSystemEntityType.notFound) {
      final targetSha256 = await _restoreTargetSha256(
        target,
        quarantineDir: quarantineDir,
        caseId: caseId,
      );
      final targetPosixMode = targetSha256 == null
          ? null
          : _readPosixMode(target);
      if (targetSha256 != intent.expectedTargetSha256 ||
          targetPosixMode != intent.expectedTargetPosixMode) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Restore crashed before staging and the target changed: '
              '${target.path}.',
        );
      }
      await _copyFileFlushed(
        snapshot,
        staged,
        exclusive: true,
        expectedPosixMode: intent.originalPosixMode,
      );
    } else if (stagedType != FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore staged original is missing or not a regular file: '
            '${staged.path}.',
      );
    }
    if (await _computeSha256(staged) != originalSha256 ||
        _readPosixMode(staged) != intent.originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message: 'Restore staged original is corrupted: ${staged.path}.',
      );
    }

    final targetSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final targetPosixMode = targetSha256 == null
        ? null
        : _readPosixMode(target);
    if (targetSha256 == originalSha256 &&
        targetPosixMode == intent.originalPosixMode) {
      return true;
    }

    if (displacedType == FileSystemEntityType.notFound) {
      if (targetSha256 == intent.expectedTargetSha256 &&
          targetPosixMode == intent.expectedTargetPosixMode) {
        return false;
      }
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore target and prepared intent are ambiguous: '
            '${target.path}. No path was overwritten.',
      );
    }

    final displacedSha256 = await _computeSha256(displaced);
    if (displacedSha256 != intent.expectedTargetSha256 ||
        _readPosixMode(displaced) != intent.expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Interrupted restore displaced bytes no longer match the '
            'flushed intent: ${displaced.path}.',
      );
    }
    if (targetSha256 != null) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Both a restore target and displaced target exist: '
            '${target.path}. Both were preserved.',
      );
    }
    await _invokeRestoreHook(
      QuarantineRestorePoint.beforeOriginalInstall,
      caseId: caseId,
      target: target,
      stagedOriginal: staged,
      displacedTarget: displaced,
    );
    try {
      await _publishRestoreOriginal(
        snapshot: snapshot,
        staged: staged,
        target: target,
        caseId: caseId,
        expectedSha256: originalSha256,
        expectedPosixMode: intent.originalPosixMode,
      );
    } on _AtomicPublishException catch (error) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Interrupted restore could not atomically publish the staged '
            'original at ${target.path}: $error',
      );
    }
    await _invokeRestoreHook(
      QuarantineRestorePoint.afterOriginalInstall,
      caseId: caseId,
      target: target,
      stagedOriginal: staged,
      displacedTarget: displaced,
    );
    final installedSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    if (installedSha256 != originalSha256 ||
        _readPosixMode(target) != intent.originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Interrupted restore produced non-original bytes at '
            '${target.path}. All recovery paths were preserved.',
      );
    }
    return true;
  }

  Future<void> _publishRestoreOriginal({
    required File snapshot,
    required File staged,
    required File target,
    required String caseId,
    required String expectedSha256,
    required int? expectedPosixMode,
  }) async {
    final anchor = _restorePublishAnchor(snapshot, target, caseId);
    final anchorType = FileSystemEntity.typeSync(
      anchor.path,
      followLinks: false,
    );
    if (anchorType == FileSystemEntityType.notFound) {
      await _copyFileFlushed(
        staged,
        anchor,
        exclusive: true,
        expectedPosixMode: expectedPosixMode,
      );
    } else if (anchorType != FileSystemEntityType.file ||
        await _computeSha256(anchor) != expectedSha256 ||
        _readPosixMode(anchor) != expectedPosixMode) {
      throw _AtomicPublishException(
        'Restore publish anchor bytes or permissions changed: '
        '${anchor.path}.',
      );
    }
    await _publishFileNoReplace(
      prepared: anchor,
      target: target,
      expectedSha256: expectedSha256,
      expectedPosixMode: expectedPosixMode,
    );
  }

  File _restorePublishAnchor(File snapshot, File target, String caseId) {
    final token = sha256
        .convert(
          utf8.encode(
            '$caseId\u0000${p.normalize(p.absolute(snapshot.path))}\u0000'
            '${p.normalize(p.absolute(target.path))}',
          ),
        )
        .toString()
        .substring(0, 16);
    final anchor = File(
      p.join(
        target.parent.path,
        '.flutter_pruner-restore-$token-${p.basename(target.path)}',
      ),
    );
    _validateRestoreTarget(anchor);
    return anchor;
  }

  Future<void> _cleanupRestorePublishAnchor({
    required File snapshot,
    required File target,
    required String caseId,
    required String expectedSha256,
    required int? expectedPosixMode,
  }) async {
    final anchor = _restorePublishAnchor(snapshot, target, caseId);
    final type = FileSystemEntity.typeSync(anchor.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return;
    if (type != FileSystemEntityType.file ||
        await _computeSha256(anchor) != expectedSha256 ||
        _readPosixMode(anchor) != expectedPosixMode ||
        FileSystemEntity.typeSync(target.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await _computeSha256(target) != expectedSha256 ||
        _readPosixMode(target) != expectedPosixMode) {
      throw QuarantineDisplacementRecoveryRequiredException(
        'Restore publish anchor cannot be safely removed: ${anchor.path}.',
      );
    }
    await anchor.delete();
  }

  Future<_RestoreIntentDocument> _resolveRestoreIntent({
    required Directory stagingDirectory,
    required File snapshot,
    required File target,
    required Directory quarantineDir,
    required String caseId,
    required Set<String?> allowedExpectedTargetSha256s,
    required int? originalPosixMode,
    required int? expectedTargetPosixMode,
  }) async {
    final intentFile = File(p.join(stagingDirectory.path, 'intent.json'));
    final intentType = FileSystemEntity.typeSync(
      intentFile.path,
      followLinks: false,
    );
    if (intentType == FileSystemEntityType.file) {
      return _readRestoreIntent(
        stagingDirectory,
        quarantineDir: quarantineDir,
        caseId: caseId,
      );
    }
    if (intentType != FileSystemEntityType.notFound) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore intent path is not a regular file: '
            '${intentFile.path}.',
      );
    }

    // Older releases inferred restore progress from these two paths. Migrate
    // only the byte-exact states that protocol could have produced, before
    // performing any project mutation.
    final staged = File(p.join(stagingDirectory.path, 'restored'));
    final displaced = File(p.join(stagingDirectory.path, 'displaced'));
    final originalSha256 = await _computeSha256(snapshot);
    if (FileSystemEntity.typeSync(staged.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await _computeSha256(staged) != originalSha256 ||
        _readPosixMode(staged) != originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Legacy restore staging has no byte-exact original: '
            '${stagingDirectory.path}.',
      );
    }
    final displacedType = FileSystemEntity.typeSync(
      displaced.path,
      followLinks: false,
    );
    if (displacedType != FileSystemEntityType.notFound &&
        displacedType != FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Legacy restore displaced path is not a regular file: '
            '${displaced.path}.',
      );
    }
    final targetSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final targetPosixMode = targetSha256 == null
        ? null
        : _readPosixMode(target);
    if (displacedType == FileSystemEntityType.file &&
        targetSha256 != null &&
        (targetSha256 != originalSha256 ||
            targetPosixMode != originalPosixMode)) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Legacy restore has both a non-original target and displaced '
            'bytes: ${target.path}. Both were preserved.',
      );
    }
    final displacedPosixMode = displacedType == FileSystemEntityType.file
        ? _readPosixMode(displaced)
        : null;
    if (displacedType == FileSystemEntityType.file &&
        displacedPosixMode != expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Legacy restore displaced permissions do not match the '
            'journal: ${displaced.path}.',
      );
    }
    final migratedExpectedTargetSha256 =
        displacedType == FileSystemEntityType.file
        ? await _computeSha256(displaced)
        : targetSha256;
    final migratedExpectedTargetPosixMode =
        displacedType == FileSystemEntityType.file
        ? displacedPosixMode
        : targetPosixMode;
    if (!allowedExpectedTargetSha256s.contains(migratedExpectedTargetSha256) ||
        migratedExpectedTargetPosixMode != expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Legacy restore target bytes or permissions are outside the '
            'journal: ${target.path}. Every observed path was preserved.',
      );
    }
    final migrated = _RestoreIntentDocument(
      targetPath: p.normalize(p.absolute(target.path)),
      originalSha256: originalSha256,
      expectedTargetSha256: migratedExpectedTargetSha256,
      originalPosixMode: originalPosixMode,
      expectedTargetPosixMode: migratedExpectedTargetPosixMode,
    );
    await intentFile.create(exclusive: true);
    await _writeFlushed(intentFile, migrated.encode());
    return migrated;
  }

  Future<_RestoreIntentDocument> _prepareRestoreIntent({
    required Directory quarantineDir,
    required File snapshot,
    required File target,
    required String caseId,
    required String? expectedTargetSha256,
    required String originalSha256,
    required int? originalPosixMode,
    required int? expectedTargetPosixMode,
  }) async {
    final stagingDirectory = _restoreStagingDirectory(snapshot, caseId);
    final staged = File(p.join(stagingDirectory.path, 'restored'));
    final displaced = File(p.join(stagingDirectory.path, 'displaced'));
    final intentFile = File(p.join(stagingDirectory.path, 'intent.json'));
    _validateRestoreTarget(staged);
    await stagingDirectory.create(recursive: true);

    final expectedIntent = _RestoreIntentDocument(
      targetPath: p.normalize(p.absolute(target.path)),
      originalSha256: originalSha256,
      expectedTargetSha256: expectedTargetSha256,
      originalPosixMode: originalPosixMode,
      expectedTargetPosixMode: expectedTargetPosixMode,
    );
    final intentType = FileSystemEntity.typeSync(
      intentFile.path,
      followLinks: false,
    );
    late final _RestoreIntentDocument intent;
    if (intentType == FileSystemEntityType.notFound) {
      if (FileSystemEntity.typeSync(staged.path, followLinks: false) !=
              FileSystemEntityType.notFound ||
          FileSystemEntity.typeSync(displaced.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Restore artifacts exist without a flushed intent: '
              '${stagingDirectory.path}.',
        );
      }
      await intentFile.create(exclusive: true);
      await _writeFlushed(intentFile, expectedIntent.encode());
      intent = expectedIntent;
    } else if (intentType == FileSystemEntityType.file) {
      intent = await _readRestoreIntent(
        stagingDirectory,
        quarantineDir: quarantineDir,
        caseId: caseId,
      );
      if (intent != expectedIntent) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Existing restore intent conflicts with the current '
              'preflight for ${target.path}.',
        );
      }
    } else {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore intent path is not a regular file: '
            '${intentFile.path}.',
      );
    }

    final stagedType = FileSystemEntity.typeSync(
      staged.path,
      followLinks: false,
    );
    if (stagedType == FileSystemEntityType.notFound) {
      if (FileSystemEntity.typeSync(displaced.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Restore displaced target exists without its staged '
              'original: ${displaced.path}.',
        );
      }
      await _copyFileFlushed(
        snapshot,
        staged,
        exclusive: true,
        expectedPosixMode: originalPosixMode,
      );
    } else if (stagedType != FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message: 'Restore staged path is not a regular file: ${staged.path}.',
      );
    }
    if (await _computeSha256(staged) != originalSha256 ||
        _readPosixMode(staged) != originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message: 'Restore staging copy is corrupted: ${staged.path}.',
      );
    }
    return intent;
  }

  Future<_RestoreIntentDocument> _readRestoreIntent(
    Directory stagingDirectory, {
    required Directory quarantineDir,
    required String caseId,
  }) async {
    final intentFile = File(p.join(stagingDirectory.path, 'intent.json'));
    try {
      if (FileSystemEntity.typeSync(intentFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('intent is missing or not a real file');
      }
      return _RestoreIntentDocument.decode(await intentFile.readAsString());
    } catch (error) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message: 'Invalid restore intent ${intentFile.path}: $error',
      );
    }
  }

  Future<String?> _restoreTargetSha256(
    File target, {
    required Directory quarantineDir,
    required String caseId,
  }) async {
    _validateRestoreTarget(target);
    final type = FileSystemEntity.typeSync(target.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore target is not an absent or regular file: '
            '${target.path}.',
      );
    }
    return _computeSha256(target);
  }

  Future<String> _restoreRequiredFileSha256(
    File file, {
    required Directory quarantineDir,
    required String caseId,
    required String label,
  }) async {
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message: '$label is missing or not a regular file: ${file.path}.',
      );
    }
    return _computeSha256(file);
  }

  Future<void> _restoreDisplacedWithoutOverwrite({
    required File displaced,
    required File target,
  }) async {
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    try {
      await _copyFileFlushed(displaced, target, exclusive: true);
    } on QuarantineException {
      // A concurrent creator wins. Both its target and the displaced bytes
      // remain available; recovery must be manual.
    }
  }

  Future<Never> _failRestoreRecovery({
    required Directory quarantineDir,
    required String caseId,
    required String message,
  }) async {
    await _markDisplacementRecoveryRequired(quarantineDir, caseId);
    throw QuarantineDisplacementRecoveryRequiredException(message);
  }

  Future<void> _cleanupVerifiedRestoreStaging({
    required Directory quarantineDir,
    required File snapshot,
    required File target,
    required String caseId,
  }) async {
    final stagingDirectory = _restoreStagingDirectory(snapshot, caseId);
    if (FileSystemEntity.typeSync(stagingDirectory.path, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return;
    }
    final intent = await _readRestoreIntent(
      stagingDirectory,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final staged = File(p.join(stagingDirectory.path, 'restored'));
    final displaced = File(p.join(stagingDirectory.path, 'displaced'));
    final targetSha256 = await _restoreTargetSha256(
      target,
      quarantineDir: quarantineDir,
      caseId: caseId,
    );
    final targetPosixMode = targetSha256 == null
        ? null
        : _readPosixMode(target);
    if (targetSha256 != intent.originalSha256 ||
        targetPosixMode != intent.originalPosixMode ||
        await _restoreRequiredFileSha256(
              staged,
              quarantineDir: quarantineDir,
              caseId: caseId,
              label: 'Restore staged original',
            ) !=
            intent.originalSha256 ||
        _readPosixMode(staged) != intent.originalPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore journal cannot be finalized because the target or '
            'staged original changed for ${target.path}.',
      );
    }
    final displacedType = FileSystemEntity.typeSync(
      displaced.path,
      followLinks: false,
    );
    if (intent.expectedTargetSha256 == null) {
      if (displacedType != FileSystemEntityType.notFound) {
        await _failRestoreRecovery(
          quarantineDir: quarantineDir,
          caseId: caseId,
          message:
              'Unexpected displaced bytes remain for an absent restore '
              'target: ${displaced.path}.',
        );
      }
    } else if (displacedType != FileSystemEntityType.file ||
        await _computeSha256(displaced) != intent.expectedTargetSha256 ||
        _readPosixMode(displaced) != intent.expectedTargetPosixMode) {
      await _failRestoreRecovery(
        quarantineDir: quarantineDir,
        caseId: caseId,
        message:
            'Restore displaced bytes changed before journal '
            'finalization: ${displaced.path}. They were preserved.',
      );
    }
    await stagingDirectory.delete(recursive: true);
  }

  Directory _restoreStagingDirectory(File snapshot, String caseId) {
    final token = sha256
        .convert(utf8.encode(p.normalize(p.absolute(snapshot.path))))
        .toString()
        .substring(0, 16);
    return Directory(
      p.join(
        ToolWorkspace(projectRoot).directory.path,
        'tmp',
        'restore',
        '$caseId-$token',
      ),
    );
  }

  int? _expectedRestoreTargetPosixMode({
    required File snapshot,
    required File target,
    required String caseId,
    required int? recordedMode,
  }) {
    if (!_supportsPosixModes) return null;
    final displaced = File(
      p.join(_restoreStagingDirectory(snapshot, caseId).path, 'displaced'),
    );
    final targetType = FileSystemEntity.typeSync(
      target.path,
      followLinks: false,
    );
    final displacedType = FileSystemEntity.typeSync(
      displaced.path,
      followLinks: false,
    );
    return targetType == FileSystemEntityType.file ||
            displacedType == FileSystemEntityType.file
        ? recordedMode
        : null;
  }

  void _validateRestoreTarget(File target) {
    final selectedRoot = p.normalize(p.absolute(projectRoot.path));
    final canonicalRoot = _canonicalDirectoryPath(selectedRoot);
    final targetPath = p.normalize(p.absolute(target.path));
    var traversalRoot = selectedRoot;
    var relativePath = p.relative(targetPath, from: traversalRoot);
    if (_isOutsideRelativePath(relativePath)) {
      traversalRoot = canonicalRoot;
      relativePath = p.relative(targetPath, from: traversalRoot);
    }
    if (_isOutsideRelativePath(relativePath)) {
      throw QuarantineException(
        'Restore target is outside project root: ${target.path}',
      );
    }

    var current = traversalRoot;
    final segments = p.split(relativePath);
    for (var index = 0; index < segments.length; index++) {
      current = p.join(current, segments[index]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) break;
      if (type == FileSystemEntityType.link) {
        throw QuarantineException(
          'Restore target contains a symlink: $current',
        );
      }
      if (index < segments.length - 1 &&
          type != FileSystemEntityType.directory) {
        throw QuarantineException(
          'Restore target has a non-directory parent: $current',
        );
      }
      if (type == FileSystemEntityType.directory) {
        final canonical = p.normalize(
          Directory(current).resolveSymbolicLinksSync(),
        );
        if (!p.equals(canonical, canonicalRoot) &&
            !p.isWithin(canonicalRoot, canonical)) {
          throw QuarantineException(
            'Restore target resolves outside project root: $current',
          );
        }
      }
    }
  }

  bool _isOutsideRelativePath(String path) =>
      p.isAbsolute(path) ||
      path == '..' ||
      path.startsWith('${p.separator}..') ||
      path.startsWith('..${p.separator}');

  File _caseSnapshotFor(Directory quarantineDir, QuarantineCase applyCase) {
    final relativePath = _relativeProjectPath(applyCase.entry.originalPath);
    return _caseSnapshotFile(quarantineDir, applyCase.caseId, relativePath);
  }

  File _caseSnapshotFile(
    Directory quarantineDir,
    String caseId,
    String relativePath,
  ) {
    return File(p.join(quarantineDir.path, 'cases', caseId, relativePath));
  }

  File _caseSafetyFile(Directory quarantineDir, QuarantineCase applyCase) {
    final relativePath = _relativeProjectPath(applyCase.entry.originalPath);
    return File(
      p.join(quarantineDir.path, 'safety', applyCase.caseId, relativePath),
    );
  }

  File _caseDisplacementRecoveryFile(
    Directory quarantineDir,
    QuarantineCase applyCase,
  ) {
    final relativePath = _relativeProjectPath(applyCase.entry.originalPath);
    return File(
      p.join(
        quarantineDir.path,
        'recovery',
        'displacement',
        applyCase.caseId,
        relativePath,
      ),
    );
  }

  File _caseCandidateRecoveryFile(
    Directory quarantineDir,
    QuarantineCase applyCase,
  ) {
    final relativePath = _relativeProjectPath(applyCase.entry.originalPath);
    return File(
      p.join(
        quarantineDir.path,
        'recovery',
        'candidate',
        applyCase.caseId,
        relativePath,
      ),
    );
  }

  File _caseCandidateFile(QuarantineCase applyCase, {required String runId}) {
    final original = p.normalize(p.absolute(applyCase.entry.originalPath));
    final token = sha256
        .convert(utf8.encode('$runId\u0000${applyCase.caseId}\u0000$original'))
        .toString()
        .substring(0, 16);
    final candidate = File(
      p.join(
        p.dirname(original),
        '.flutter_pruner-$token-${p.basename(original)}',
      ),
    );
    _validateRestoreTarget(candidate);
    if (p.equals(candidate.path, original) ||
        !p.equals(p.dirname(candidate.path), p.dirname(original))) {
      throw QuarantineException(
        'Invalid case candidate path: ${candidate.path}',
      );
    }
    return candidate;
  }

  String _relativeProjectPath(String originalPath) {
    final relativePath = p.relative(originalPath, from: projectRoot.path);
    if (p.isAbsolute(relativePath) ||
        relativePath == '..' ||
        relativePath.startsWith('${p.separator}..') ||
        relativePath.startsWith('..${p.separator}')) {
      throw QuarantineException('File is outside project root: $originalPath');
    }
    return relativePath;
  }
}

/// Metadata about a quarantine.
class QuarantineInfo {
  /// Creates quarantine info.
  const QuarantineInfo({
    required this.runId,
    required this.timestamp,
    required this.entryCount,
    required this.path,
  });

  /// Run ID.
  final String runId;

  /// When the quarantine was created.
  final DateTime timestamp;

  /// Number of quarantined files.
  final int entryCount;

  /// Quarantine directory path.
  final String path;
}

class _V1RestoreFile {
  const _V1RestoreFile({
    required this.entry,
    required this.quarantineFile,
    required this.targetFile,
  });

  final QuarantineEntry entry;
  final File quarantineFile;
  final File targetFile;
}

class _DisplacementRestorePlan {
  const _DisplacementRestorePlan({
    required this.applyCase,
    required this.displacement,
    required this.promotedBackup,
    required this.safetyCopy,
    required this.candidate,
    required this.candidateRecovery,
    required this.reconstructPromoted,
    required this.preserveCandidate,
  });

  final QuarantineCase applyCase;
  final _CaseDisplacementDocument displacement;
  final File promotedBackup;
  final File safetyCopy;
  final File candidate;
  final File candidateRecovery;
  final bool reconstructPromoted;
  final bool preserveCandidate;
}

class _RestoreIntentDocument {
  const _RestoreIntentDocument({
    required this.targetPath,
    required this.originalSha256,
    required this.expectedTargetSha256,
    required this.originalPosixMode,
    required this.expectedTargetPosixMode,
  });

  factory _RestoreIntentDocument.decode(String contents) {
    final decoded = jsonDecode(contents);
    final version = decoded is Map<String, dynamic> ? decoded['version'] : null;
    if (decoded is! Map<String, dynamic> ||
        (version != 1 && version != 2) ||
        decoded['targetPath'] is! String ||
        decoded['originalSha256'] is! String ||
        !decoded.containsKey('expectedTargetSha256') ||
        (decoded['expectedTargetSha256'] != null &&
            decoded['expectedTargetSha256'] is! String) ||
        (version == 2 &&
            (!decoded.containsKey('originalPosixMode') ||
                !_isValidNullablePosixMode(decoded['originalPosixMode']) ||
                !decoded.containsKey('expectedTargetPosixMode') ||
                !_isValidNullablePosixMode(
                  decoded['expectedTargetPosixMode'],
                ))) ||
        decoded['payloadSha256'] is! String) {
      throw const FormatException('invalid restore intent');
    }
    final payload = Map<String, dynamic>.from(decoded)..remove('payloadSha256');
    final actual = sha256.convert(utf8.encode(jsonEncode(payload))).toString();
    if (actual != decoded['payloadSha256']) {
      throw const FormatException('restore intent checksum mismatch');
    }
    return _RestoreIntentDocument(
      targetPath: decoded['targetPath'] as String,
      originalSha256: decoded['originalSha256'] as String,
      expectedTargetSha256: decoded['expectedTargetSha256'] as String?,
      originalPosixMode: version == 2
          ? decoded['originalPosixMode'] as int?
          : null,
      expectedTargetPosixMode: version == 2
          ? decoded['expectedTargetPosixMode'] as int?
          : null,
    );
  }

  final String targetPath;
  final String originalSha256;
  final String? expectedTargetSha256;
  final int? originalPosixMode;
  final int? expectedTargetPosixMode;

  String encode() {
    final payload = <String, dynamic>{
      'version': 2,
      'targetPath': targetPath,
      'originalSha256': originalSha256,
      'expectedTargetSha256': expectedTargetSha256,
      'originalPosixMode': originalPosixMode,
      'expectedTargetPosixMode': expectedTargetPosixMode,
    };
    return jsonEncode({
      ...payload,
      'payloadSha256': sha256
          .convert(utf8.encode(jsonEncode(payload)))
          .toString(),
    });
  }

  @override
  bool operator ==(Object other) =>
      other is _RestoreIntentDocument &&
      other.targetPath == targetPath &&
      other.originalSha256 == originalSha256 &&
      other.expectedTargetSha256 == expectedTargetSha256 &&
      other.originalPosixMode == originalPosixMode &&
      other.expectedTargetPosixMode == expectedTargetPosixMode;

  @override
  int get hashCode => Object.hash(
    targetPath,
    originalSha256,
    expectedTargetSha256,
    originalPosixMode,
    expectedTargetPosixMode,
  );

  static bool _isValidNullablePosixMode(Object? value) =>
      value == null || (value is int && value >= 0 && value <= 0xfff);
}

class _ManifestDocument {
  const _ManifestDocument({
    required this.manifest,
    required this.revision,
    required this.payloadSha256,
    required this.contents,
    required this.runLifecycle,
    required this.caseDisplacements,
  });

  final QuarantineManifest manifest;
  final int revision;
  final String payloadSha256;
  final String contents;
  final _RunLifecycleDocument? runLifecycle;
  final List<_CaseDisplacementDocument> caseDisplacements;
}

class _CaseDisplacementDocument {
  const _CaseDisplacementDocument({
    required this.caseId,
    required this.expectedSha256,
    required this.state,
    this.candidateSha256,
  });

  factory _CaseDisplacementDocument.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 ||
        json['caseId'] is! String ||
        json['expectedSha256'] is! String ||
        json['state'] is! String ||
        (json['candidateSha256'] != null &&
            json['candidateSha256'] is! String)) {
      throw const FormatException('invalid case displacement journal');
    }
    try {
      return _CaseDisplacementDocument(
        caseId: json['caseId'] as String,
        expectedSha256: json['expectedSha256'] as String,
        state: _CaseDisplacementState.values.byName(json['state'] as String),
        candidateSha256: json['candidateSha256'] as String?,
      );
    } on ArgumentError {
      throw const FormatException('unknown case displacement state');
    }
  }

  final String caseId;
  final String expectedSha256;
  final _CaseDisplacementState state;
  final String? candidateSha256;

  _CaseDisplacementDocument withState(
    _CaseDisplacementState value, {
    String? candidateSha256,
  }) => _CaseDisplacementDocument(
    caseId: caseId,
    expectedSha256: expectedSha256,
    state: value,
    candidateSha256: candidateSha256 ?? this.candidateSha256,
  );

  Map<String, dynamic> toJson() => {
    'version': 1,
    'caseId': caseId,
    'expectedSha256': expectedSha256,
    'state': state.name,
    if (candidateSha256 != null) 'candidateSha256': candidateSha256,
  };
}

enum _CaseDisplacementState {
  intent,
  promoted,
  candidatePrepared,
  installing,
  installed,
  committed,
  restored,
  recoveryRequired,
}

class _RunLifecycleDocument {
  const _RunLifecycleDocument(this.state);

  factory _RunLifecycleDocument.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1 || json['state'] is! String) {
      throw const FormatException('invalid run lifecycle marker');
    }
    try {
      return _RunLifecycleDocument(
        QuarantineRunLifecycleState.values.byName(json['state'] as String),
      );
    } on ArgumentError {
      throw const FormatException('unknown run lifecycle state');
    }
  }

  final QuarantineRunLifecycleState state;

  Map<String, dynamic> toJson() => {'version': 1, 'state': state.name};
}

/// Run-level lifecycle persisted alongside the transaction journal.
enum QuarantineRunLifecycleState {
  /// The command may still add transactions or perform convergence checks.
  active,

  /// Every transaction committed and all run-level obligations completed.
  completed,

  /// A process or recovery failure left project bytes unsafe to touch.
  recoveryRequired,

  /// The whole run was restored and verified against its original baseline.
  rolledBackVerified,
}

/// Observable points in the atomic source-displacement protocol.
enum QuarantineDisplacementPoint {
  /// The flushed intent exists, but the source has not been renamed yet.
  beforeSourceRename,

  /// The source inode has been promoted into the quarantine backup path.
  afterSourceRename,

  /// The candidate is ready and the original project path must still be free.
  beforeCandidateInstall,

  /// The project path was observed absent immediately before no-replace link.
  afterCandidateTargetPreflight,

  /// Candidate bytes were installed and are about to be re-hashed.
  afterCandidateInstall,

  /// Installed bytes and their hash are journaled; staging still exists.
  afterCandidateJournal,
}

/// Context passed to a displacement observer, primarily for fault injection.
class QuarantineDisplacementContext {
  /// Creates a displacement context.
  const QuarantineDisplacementContext({
    required this.point,
    required this.caseId,
    required this.source,
    required this.promotedBackup,
    required this.candidate,
  });

  /// Current protocol checkpoint.
  final QuarantineDisplacementPoint point;

  /// Case whose path is being displaced.
  final String caseId;

  /// Original project path.
  final File source;

  /// Authoritative promoted backup path in the run quarantine.
  final File promotedBackup;

  /// Tool-owned candidate path adjacent to [source].
  final File candidate;
}

/// Tool-owned candidate and authoritative backup for one displaced case.
class QuarantinePreparedCase {
  /// Creates a prepared case result.
  const QuarantinePreparedCase({
    required this.applyCase,
    required this.candidate,
    required this.promotedBackup,
  });

  /// Persisted case journal entry.
  final QuarantineCase applyCase;

  /// Candidate path to mutate while the project source path is absent.
  final File candidate;

  /// Original source inode promoted into the quarantine.
  final File promotedBackup;
}

/// Fault-observer invoked at deterministic displacement checkpoints.
typedef QuarantineDisplacementHook =
    FutureOr<void> Function(QuarantineDisplacementContext context);

/// Observable points in the exclusive restore protocol.
enum QuarantineRestorePoint {
  /// The target passed read-only preflight but has not been displaced yet.
  beforeTargetDisplacement,

  /// The prior target is preserved and the original is not installed yet.
  beforeOriginalInstall,

  /// Original bytes were installed and are about to be re-hashed.
  afterOriginalInstall,
}

/// Context passed to a restore observer, primarily for fault injection.
class QuarantineRestoreContext {
  /// Creates a restore context.
  const QuarantineRestoreContext({
    required this.point,
    required this.caseId,
    required this.target,
    required this.stagedOriginal,
    required this.displacedTarget,
  });

  /// Current protocol checkpoint.
  final QuarantineRestorePoint point;

  /// Case whose project path is being restored.
  final String caseId;

  /// Original project path.
  final File target;

  /// Flushed immutable copy used for exclusive installation.
  final File stagedOriginal;

  /// Same-filesystem preservation of the pre-restore target.
  final File displacedTarget;
}

/// Fault-observer invoked at deterministic restore checkpoints.
typedef QuarantineRestoreHook =
    FutureOr<void> Function(QuarantineRestoreContext context);

/// Rename primitive used for atomic source displacement.
typedef QuarantineSourceRenamer =
    Future<File> Function(File source, String destination);

class _AtomicPublishException extends QuarantineException {
  _AtomicPublishException(super.message);
}

/// Signals path ambiguity that must not trigger automatic working-copy writes.
class QuarantineDisplacementRecoveryRequiredException
    extends QuarantineException {
  /// Creates a recovery-required displacement failure.
  QuarantineDisplacementRecoveryRequiredException(super.message);
}

/// Thrown when a quarantine operation fails.
class QuarantineException implements Exception {
  /// Creates the exception with [message].
  QuarantineException(this.message);

  /// User-facing error message.
  final String message;

  @override
  String toString() => message;
}
