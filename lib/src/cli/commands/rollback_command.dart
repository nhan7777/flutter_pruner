import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/process/managed_process_runner.dart';
import '../../core/project/project_context.dart';
import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../quarantine/manifest.dart';
import '../../quarantine/quarantine_manager.dart';
import '../../quarantine/recoverable_clean_store.dart';
import '../../quarantine/rollback_recovery.dart';
import '../../verification/verification_runner.dart';
import '../cli_exit_code.dart';
import '../formatters/quarantine_formatter.dart';
import '../project_command_support.dart';
import '../suggested_command.dart';
import '../terminal_text_metrics.dart';
import '../usage_error.dart';

/// Restores files from quarantine back to their original locations.
///
/// Restores quarantined regular-file bytes and POSIX modes where available;
/// success requires rollback verification.
class RollbackCommand extends Command<int> {
  /// Creates the rollback command.
  RollbackCommand({
    VerificationRunner Function(Directory)? verifierFactory,
    QuarantineManager Function(Directory)? quarantineManagerFactory,
    Map<String, String> Function()? environment,
    ManagedProcessCancellationController? processCancellation,
    RecoverableCleanStore Function(Directory)? cleanStoreFactory,
  }) : _verifierFactory =
           verifierFactory ??
           ((projectRoot) => VerificationRunner(
             projectRoot,
             processRunner: ManagedProcessRunner(
               cancellationController: processCancellation,
             ),
           )),
       _quarantineManagerFactory =
           quarantineManagerFactory ??
           ((projectRoot) => QuarantineManager(
             projectRoot,
             atomicPublishProcessRunner: ManagedProcessRunner(
               cancellationController: processCancellation,
             ),
             permissionProcessRunner: ManagedProcessRunner(
               cancellationController: processCancellation,
             ),
           )),
       _cleanStoreFactory =
           cleanStoreFactory ??
           ((projectRoot) => RecoverableCleanStore(projectRoot: projectRoot)),
       _environment = environment ?? (() => Platform.environment) {
    argParser
      ..addFlag(
        'clean',
        negatable: false,
        help:
            'Logically clean quarantine after a successful rollback; bytes remain retained',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory; defaults to .flutter_pruner/quarantine in '
            'the selected project',
      );
    addProjectOption(argParser);
  }

  final VerificationRunner Function(Directory) _verifierFactory;
  final QuarantineManager Function(Directory) _quarantineManagerFactory;
  final RecoverableCleanStore Function(Directory) _cleanStoreFactory;
  final Map<String, String> Function() _environment;

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'Restore files from quarantine and reverse an apply operation';

  @override
  String get usageFooter => '''Examples:
  flutter_pruner rollback RUN_ID
  flutter_pruner rollback --project ./example RUN_ID''';

  @override
  String get invocation => '${super.invocation} <run-id>';

  @override
  Future<int> run() async {
    final args = argResults!;
    final clean = args.flag('clean');

    if (args.rest.length != 1) {
      throw commandUsageError(this, 'A run ID is required.');
    }

    final runId = args.rest.first;
    try {
      QuarantineManager.validateRunId(runId);
    } on QuarantineException catch (error) {
      throw commandUsageError(this, _safe(error.message));
    }

    try {
      final workspace = resolveToolWorkspace(args);
      final quarantineDir = _locateQuarantine(
        workspace,
        args.option('quarantine'),
        runId,
      );
      final operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: clean ? 'rollback-clean' : 'rollback',
      );
      try {
        return await _runLocked(
          workspace: workspace,
          quarantineDir: quarantineDir,
          runId: runId,
          clean: clean,
        );
      } finally {
        await operationLock.release();
      }
    } on ProjectSelectionException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return CliExitCode.operationalFailure;
    } on ToolWorkspaceException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return CliExitCode.operationalFailure;
    } on RollbackRecoveryException catch (error) {
      _renderRecovery(error);
      return 1;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return 1;
    } on ProjectOperationLockException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return 1;
    }
  }

  Future<int> _runLocked({
    required ToolWorkspace workspace,
    required Directory quarantineDir,
    required String runId,
    required bool clean,
  }) async {
    final selectedProjectPath = p.normalize(
      p.absolute(workspace.projectRoot.path),
    );
    final provisionalIdentity = RollbackRunIdentity(
      runId: runId,
      projectPath: selectedProjectPath,
      quarantineBasePath: p.dirname(quarantineDir.path),
      quarantinePath: p.normalize(p.absolute(quarantineDir.path)),
    );
    final locator = _quarantineManagerFactory(workspace.projectRoot);
    late final QuarantineManifest manifest;
    try {
      manifest = await locator.readManifest(quarantineDir);
    } catch (error) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.manifestReadFailure,
        identity: provisionalIdentity,
        cleanRequested: clean,
        detail: '$error',
      );
    }
    late final Directory projectDir;
    try {
      projectDir = Directory(
        manifest.projectRoot ?? _inferProjectRoot(manifest),
      );
    } catch (error) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.manifestReadFailure,
        identity: provisionalIdentity,
        cleanRequested: clean,
        detail: '$error',
      );
    }
    final identity = RollbackRunIdentity(
      runId: runId,
      projectPath: selectedProjectPath,
      recordedProjectPath: p.normalize(p.absolute(projectDir.path)),
      quarantineBasePath: p.dirname(quarantineDir.path),
      quarantinePath: p.normalize(p.absolute(quarantineDir.path)),
    );
    try {
      _requireSelectedProject(workspace.projectRoot, projectDir);
    } on QuarantineException catch (error) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.projectMismatch,
        identity: identity,
        cleanRequested: clean,
        detail: error.message,
      );
    }
    final quarantineManager = _quarantineManagerFactory(projectDir);
    final restoredFileCount = _restoredFileCount(manifest);

    if (manifest.usesTransactionJournal) {
      await _restoreVerifiedV3(
        quarantineManager: quarantineManager,
        quarantineDir: quarantineDir,
        manifest: manifest,
        projectDir: projectDir,
        identity: identity,
        cleanRequested: clean,
      );
    } else {
      try {
        await quarantineManager.restoreForRollback(
          quarantineDir: quarantineDir,
          runId: runId,
          manifest: manifest,
        );
      } on RollbackRestorePhaseException catch (error) {
        throw _restoreRecovery(
          error: error,
          identity: identity,
          cleanRequested: clean,
        );
      }
    }

    if (clean) {
      try {
        final plan = await quarantineManager.planCleanQuarantine(
          runId: runId,
          quarantineBases: <Directory>[Directory(identity.quarantineBasePath)],
        );
        final result = await _cleanStoreFactory(projectDir).execute(
          plan: plan,
          quarantineBase: Directory(identity.quarantineBasePath),
        );
        if (!result.committed) {
          throw RollbackRecoveryException(
            kind: RollbackFailureKind.cleanRecoveryRequired,
            identity: identity,
            workingCopy: RollbackWorkingCopyState.originalBytesRestored,
            verification: RollbackVerificationState.verified,
            quarantine: RollbackQuarantineState.retained,
            clean: RollbackCleanState.recoveryRequired,
            nextAction: RollbackNextAction.listThenInspect(identity),
            detail: 'Retained clean journal requires recovery.',
          );
        }
        _writeHuman(stdout, 'ROLLBACK COMPLETE');
        _writeHuman(stdout, 'Rollback: verified');
        _writeHuman(stdout, 'Restored files: $restoredFileCount');
        _writeHuman(stdout, 'Quarantine clean: retained for recovery');
        _writeHuman(stdout, 'Operation ID: ${_safe(result.operationId)}');
        _writeHuman(stdout, 'Disk space: retained');
        for (final target in result.targets) {
          _writeHuman(stdout, 'Recovery copy: ${_safe(target.retainedPath)}');
        }
      } on RollbackRecoveryException {
        rethrow;
      } on RecoverableCleanStoreException catch (error) {
        throw RollbackRecoveryException(
          kind: RollbackFailureKind.cleanRecoveryRequired,
          identity: identity,
          workingCopy: RollbackWorkingCopyState.originalBytesRestored,
          verification: RollbackVerificationState.verified,
          quarantine: RollbackQuarantineState.preserved,
          clean: RollbackCleanState.validationFailedPreserved,
          nextAction: RollbackNextAction.listThenInspect(identity),
          detail: '$error',
        );
      } on QuarantineException catch (error) {
        throw RollbackRecoveryException(
          kind: RollbackFailureKind.cleanValidationFailed,
          identity: identity,
          workingCopy: RollbackWorkingCopyState.originalBytesRestored,
          verification: RollbackVerificationState.verified,
          quarantine: RollbackQuarantineState.preserved,
          clean: RollbackCleanState.validationFailedPreserved,
          nextAction: RollbackNextAction.listThenInspect(identity),
          detail: error.message,
        );
      }
    } else {
      _writeHuman(stdout, 'ROLLBACK COMPLETE');
      _writeHuman(stdout, 'Rollback: verified');
      _writeHuman(stdout, 'Restored files: $restoredFileCount');
      _writeHuman(
        stdout,
        'Quarantine: preserved at ${_safe(identity.quarantinePath)}',
      );
      _writeHuman(
        stdout,
        'Move verified quarantine evidence into retained recovery storage with:',
      );
      _writeSuggestedCommand(
        stdout,
        RollbackNextAction.targetedClean(identity).commands.single,
      );
    }

    return 0;
  }

  Future<void> _restoreVerifiedV3({
    required QuarantineManager quarantineManager,
    required Directory quarantineDir,
    required QuarantineManifest manifest,
    required Directory projectDir,
    required RollbackRunIdentity identity,
    required bool cleanRequested,
  }) async {
    final baseline = manifest.baselineVerification;
    late final ProjectContext project;
    try {
      project = await ProjectContext.load(projectDir);
    } catch (error) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.baselineEvidenceInvalid,
        identity: identity,
        cleanRequested: cleanRequested,
        detail: '$error',
      );
    }
    final expectedWorkingDirectory = p.normalize(p.absolute(projectDir.path));
    final comparisonBaseline = baseline?.comparisonBaseline;
    if (baseline == null ||
        !baseline.available ||
        baseline.passed == null ||
        comparisonBaseline == null ||
        !comparisonBaseline.isComplete ||
        baseline.policyHash != manifest.verificationPolicyHash ||
        baseline.policyHash != project.verificationPolicy.hash ||
        baseline.workingDirectory != expectedWorkingDirectory ||
        comparisonBaseline.policyHash != baseline.policyHash ||
        comparisonBaseline.workingDirectory != baseline.workingDirectory ||
        comparisonBaseline.toolchainIdentity != baseline.toolchainIdentity ||
        comparisonBaseline.steps.every((step) => step.passed) !=
            baseline.passed ||
        !_isCompleteStepEvidence(
          baseline.requiredStepIds,
          baseline.observedStepIds,
        ) ||
        !_sameStringSet(
          baseline.requiredStepIds,
          project.verificationPolicy.requiredStepIds,
        )) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.baselineEvidenceInvalid,
        identity: identity,
        cleanRequested: cleanRequested,
        detail: 'V3 rollback cannot prove its original verification baseline.',
      );
    }

    try {
      await quarantineManager.markRunRecoveryRequired(
        quarantineDir: quarantineDir,
        reason: 'Manual full-run rollback is in progress.',
      );
    } catch (error) {
      throw _preMutationRecovery(
        kind: RollbackFailureKind.restoreFailedBeforeMutation,
        identity: identity,
        cleanRequested: cleanRequested,
        detail: '$error',
      );
    }
    try {
      await quarantineManager.restoreRunBytesForRollback(
        quarantineDir: quarantineDir,
        manifest: manifest,
      );
    } on RollbackRestorePhaseException catch (error) {
      throw _restoreRecovery(
        error: error,
        identity: identity,
        cleanRequested: cleanRequested,
      );
    }

    late final VerificationResult restored;
    try {
      restored = await _verifierFactory(
        projectDir,
      ).verifyForRecovery(policy: project.verificationPolicy);
    } on ProcessCancellationBeforeLaunchException catch (error) {
      throw RollbackRecoveryException(
        kind: RollbackFailureKind.verifierException,
        identity: identity,
        workingCopy: RollbackWorkingCopyState.originalBytesRestored,
        verification: RollbackVerificationState.notStarted,
        quarantine: RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.inspect(identity),
        detail: '$error',
      );
    } on ProcessCancellationConfirmedException catch (error) {
      throw RollbackRecoveryException(
        kind: RollbackFailureKind.verifierException,
        identity: identity,
        workingCopy: RollbackWorkingCopyState.originalBytesRestored,
        verification: RollbackVerificationState.exception,
        quarantine: RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.inspect(identity),
        detail: '$error',
      );
    } on VerificationTerminationUnconfirmedException catch (error) {
      throw RollbackRecoveryException(
        kind: RollbackFailureKind.verifierTerminationUnconfirmed,
        identity: identity,
        workingCopy: RollbackWorkingCopyState.originalBytesRestored,
        verification: RollbackVerificationState.terminationUnconfirmed,
        quarantine: RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.confirmVerifierTerminationThenInspect(
          identity,
        ),
        detail: error.message,
      );
    } catch (error) {
      throw RollbackRecoveryException(
        kind: RollbackFailureKind.verifierException,
        identity: identity,
        workingCopy: RollbackWorkingCopyState.originalBytesRestored,
        verification: RollbackVerificationState.exception,
        quarantine: RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.inspect(identity),
        detail: '$error',
      );
    }
    final observedStepIds = restored.steps.map((step) => step.name).toList();
    final comparison = restored.compareToBaselineEvidence(comparisonBaseline);
    final evidenceMatches =
        restored.isComplete &&
        restored.isAvailable &&
        restored.policyHash == baseline.policyHash &&
        restored.workingDirectory == baseline.workingDirectory &&
        restored.toolchainIdentity == baseline.toolchainIdentity &&
        _sameStringSet(restored.requiredStepIds, baseline.requiredStepIds) &&
        _isCompleteStepEvidence(restored.requiredStepIds, observedStepIds) &&
        comparison.accepted;
    if (!evidenceMatches) {
      throw RollbackRecoveryException(
        kind: RollbackFailureKind.verificationFailed,
        identity: identity,
        workingCopy: RollbackWorkingCopyState.originalBytesRestored,
        verification: RollbackVerificationState.failed,
        quarantine: RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.inspect(identity),
        detail:
            'Restored verification did not reproduce the recorded baseline.',
      );
    }

    try {
      await quarantineManager.completeVerifiedFullRollback(
        quarantineDir: quarantineDir,
        reason: 'Manual full-run rollback verified.',
        verificationEvidence: QuarantineVerificationEvidence(
          policyHash: restored.policyHash,
          requiredStepIds: restored.requiredStepIds,
          observedStepIds: observedStepIds,
          workingDirectory: restored.workingDirectory,
          toolchainIdentity: restored.toolchainIdentity,
          available: restored.isAvailable,
          passed: restored.passed,
          comparisonBaseline: restored.toBaselineEvidence(),
        ),
        baselineEquivalent: true,
      );
    } on RollbackTerminalizationException catch (error) {
      final authorityRevalidationFailed =
          error.kind ==
          RollbackTerminalizationFailureKind
              .authoritySnapshotRevalidationFailed;
      final workingCopyRevalidationFailed =
          error.kind ==
          RollbackTerminalizationFailureKind.workingCopyRevalidationFailed;
      throw RollbackRecoveryException(
        kind: switch (error.kind) {
          RollbackTerminalizationFailureKind
              .authoritySnapshotRevalidationFailed =>
            RollbackFailureKind.authoritySnapshotRevalidationFailed,
          RollbackTerminalizationFailureKind.workingCopyRevalidationFailed =>
            RollbackFailureKind.workingCopyRevalidationFailed,
          RollbackTerminalizationFailureKind.preconditionRejected =>
            RollbackFailureKind.terminalizationPreconditionRejected,
          RollbackTerminalizationFailureKind.journalPersistenceFailed =>
            RollbackFailureKind.journalTerminalizationFailed,
        },
        identity: identity,
        workingCopy: authorityRevalidationFailed
            ? RollbackWorkingCopyState.notRevalidatedAfterAuthorityFailure
            : workingCopyRevalidationFailed
            ? RollbackWorkingCopyState.restoredStateInvalidated
            : RollbackWorkingCopyState.originalBytesRestored,
        verification: authorityRevalidationFailed
            ? RollbackVerificationState
                  .completedButCannotAuthorizeTerminalizationDueToAuthorityEvidenceFailure
            : workingCopyRevalidationFailed
            ? RollbackVerificationState.invalidatedByWorkingCopyRevalidation
            : RollbackVerificationState.verified,
        quarantine: authorityRevalidationFailed
            ? RollbackQuarantineState.authorityCorruptRecoveryRequired
            : RollbackQuarantineState.recoveryRequired,
        clean: cleanRequested
            ? RollbackCleanState.notAttempted
            : RollbackCleanState.notRequested,
        nextAction: RollbackNextAction.inspect(identity),
        detail: error.detail,
        observation: error.observation,
      );
    }
  }

  RollbackRecoveryException _preMutationRecovery({
    required RollbackFailureKind kind,
    required RollbackRunIdentity identity,
    required bool cleanRequested,
    required String detail,
  }) => RollbackRecoveryException(
    kind: kind,
    identity: identity,
    workingCopy: RollbackWorkingCopyState.unchanged,
    verification: RollbackVerificationState.notStarted,
    quarantine: RollbackQuarantineState.preserved,
    clean: cleanRequested
        ? RollbackCleanState.notAttempted
        : RollbackCleanState.notRequested,
    nextAction: RollbackNextAction.inspect(identity),
    detail: detail,
  );

  RollbackRecoveryException _restoreRecovery({
    required RollbackRestorePhaseException error,
    required RollbackRunIdentity identity,
    required bool cleanRequested,
  }) => RollbackRecoveryException(
    kind: switch (error.kind) {
      RollbackRestoreFailureKind.workingCopyConflict =>
        RollbackFailureKind.workingCopyConflict,
      RollbackRestoreFailureKind.failedBeforeMutation =>
        RollbackFailureKind.restoreFailedBeforeMutation,
      RollbackRestoreFailureKind.failedAfterMutation =>
        RollbackFailureKind.restoreFailedAfterMutation,
    },
    identity: identity,
    workingCopy: error.workingCopy,
    verification: RollbackVerificationState.notStarted,
    quarantine: RollbackQuarantineState.recoveryRequired,
    clean: cleanRequested
        ? RollbackCleanState.notAttempted
        : RollbackCleanState.notRequested,
    nextAction: RollbackNextAction.inspect(identity),
    detail: error.detail,
  );

  void _renderRecovery(RollbackRecoveryException recovery) {
    final identity = recovery.identity;
    if (recovery.kind == RollbackFailureKind.cleanValidationFailed ||
        recovery.kind == RollbackFailureKind.cleanRecoveryRequired ||
        recovery.kind == RollbackFailureKind.cleanOutcomeUnknown) {
      _writeHuman(stdout, 'ROLLBACK COMPLETE WITH CLEANUP FAILURE');
      _writeHuman(stdout, 'Rollback: verified');
      _writeHuman(
        stdout,
        recovery.clean == RollbackCleanState.validationFailedPreserved
            ? 'Quarantine clean: preserved'
            : 'Quarantine clean: recovery required',
      );
      _writeHuman(stdout, 'Path: ${_safe(identity.quarantinePath)}');
      _writeHuman(stdout, 'Backend: recoverableLogicalMove');
      _writeHuman(
        stderr,
        'Quarantine cleanup failed: ${_safe(recovery.detail)}',
      );
      for (final command in recovery.nextAction.commands) {
        _writeHuman(stderr, switch (command.kind) {
          RollbackSuggestedCommandKind.list =>
            'List surviving quarantine evidence:',
          RollbackSuggestedCommandKind.inspect =>
            'Inspect retained evidence before another action:',
          RollbackSuggestedCommandKind.clean =>
            'Move verified quarantine evidence into retained recovery storage with:',
        });
        _writeSuggestedCommand(stderr, command);
      }
      return;
    }
    _writeHuman(stderr, 'ROLLBACK RECOVERY REQUIRED');
    if (recovery.kind == RollbackFailureKind.manifestReadFailure) {
      _writeHuman(stderr, 'Failure: manifest could not be read.');
    }
    if (recovery.kind == RollbackFailureKind.projectMismatch) {
      _writeHuman(stderr, 'Selected project: ${_safe(identity.projectPath)}');
      _writeHuman(
        stderr,
        'Recorded project: ${_safe(identity.recordedProjectPath ?? 'unknown')}',
      );
    }
    if (recovery.kind == RollbackFailureKind.restoreFailedBeforeMutation) {
      _writeHuman(
        stderr,
        'Failure: restore stopped before project bytes changed.',
      );
    } else if (recovery.kind ==
        RollbackFailureKind.restoreFailedAfterMutation) {
      _writeHuman(
        stderr,
        'Failure: restore stopped after project bytes changed.',
      );
    }
    if (recovery.kind == RollbackFailureKind.workingCopyRevalidationFailed) {
      _writeHuman(
        stderr,
        'Failure: working-copy revalidation failed before journal terminalization.',
      );
    } else if (recovery.kind ==
        RollbackFailureKind.authoritySnapshotRevalidationFailed) {
      _writeHuman(
        stderr,
        'Failure: retained run-original authority failed revalidation before journal terminalization.',
      );
    } else if (recovery.kind ==
        RollbackFailureKind.terminalizationPreconditionRejected) {
      _writeHuman(
        stderr,
        'Failure: rollback terminalization evidence was rejected before journal persistence.',
      );
    } else if (recovery.kind ==
        RollbackFailureKind.journalTerminalizationFailed) {
      _writeHuman(
        stderr,
        'Failure: terminal journal persistence failed after restored state was revalidated.',
      );
    }
    _writeHuman(stderr, switch (recovery.workingCopy) {
      RollbackWorkingCopyState.unchanged =>
        'Working copy: no project bytes were changed.',
      RollbackWorkingCopyState.originalBytesRestored
          when recovery.verification ==
              RollbackVerificationState.terminationUnconfirmed =>
        'Working copy: original bytes were restored; verifier outcome is unconfirmed.',
      RollbackWorkingCopyState.originalBytesRestored =>
        'Working copy: original bytes were restored.',
      RollbackWorkingCopyState.outcomeUnknown =>
        'Working copy: restore outcome is unknown; project bytes may be partial.',
      RollbackWorkingCopyState.restoredStateInvalidated =>
        'Working copy: restored state was invalidated before journal terminalization.',
      RollbackWorkingCopyState.notRevalidatedAfterAuthorityFailure =>
        'Working copy: not revalidated after retained authority failure.',
    });
    _writeHuman(stderr, switch (recovery.verification) {
      RollbackVerificationState.notStarted => 'Verification: not started.',
      RollbackVerificationState.verified => 'Verification: verified.',
      RollbackVerificationState.failed =>
        'Verification: did not reproduce the recorded baseline.',
      RollbackVerificationState.exception =>
        'Verification: failed before complete evidence was returned.',
      RollbackVerificationState.terminationUnconfirmed =>
        'Verification: process termination could not be confirmed.',
      RollbackVerificationState.invalidatedByWorkingCopyRevalidation =>
        'Verification: prior result invalidated by working-copy revalidation.',
      RollbackVerificationState
          .completedButCannotAuthorizeTerminalizationDueToAuthorityEvidenceFailure =>
        'Verification: completed, but cannot authorize terminalization because retained authority evidence failed revalidation.',
    });
    if (recovery.observation case final observation?) {
      _writeHuman(
        stderr,
        'Observed role: ${switch (observation.role) {
          RollbackObservedPathRole.runOriginalSnapshot => 'run-original snapshot',
          RollbackObservedPathRole.workingCopy => 'working copy',
        }}.',
      );
      _writeHuman(
        stderr,
        'Observed state: ${switch (observation.state) {
          RollbackObservedState.missing => 'missing',
          RollbackObservedState.nonRegularFile => 'non-regular file',
          RollbackObservedState.byteMismatch => 'byte mismatch',
          RollbackObservedState.posixModeMismatch => 'POSIX mode mismatch',
        }}.',
      );
      _writeHuman(stderr, 'Observed path: ${_safe(observation.path)}');
      if (observation.state == RollbackObservedState.nonRegularFile) {
        _writeHuman(
          stderr,
          'Observed type: ${_safe(observation.observedType)}.',
        );
      }
      if (observation.observedSha256 case final observedSha256?) {
        _writeHuman(
          stderr,
          'Expected SHA-256: ${_safe(observation.expectedSha256)}',
        );
        _writeHuman(stderr, 'Observed SHA-256: ${_safe(observedSha256)}');
      }
      if (observation.expectedPosixMode case final expectedMode?) {
        _writeHuman(
          stderr,
          'Expected POSIX mode: ${_formatMode(expectedMode)}',
        );
      }
      if (observation.observedPosixMode case final observedMode?) {
        _writeHuman(
          stderr,
          'Observed POSIX mode: ${_formatMode(observedMode)}',
        );
      }
    }
    _writeHuman(stderr, switch (recovery.quarantine) {
      RollbackQuarantineState.preserved =>
        'Quarantine: preserved at ${_safe(identity.quarantinePath)}.',
      RollbackQuarantineState.recoveryRequired =>
        'Quarantine: recovery required at ${_safe(identity.quarantinePath)}.',
      RollbackQuarantineState.authorityCorruptRecoveryRequired =>
        'Quarantine: recovery required; run-original authority is corrupt at ${_safe(identity.quarantinePath)}.',
      RollbackQuarantineState.removed => 'Quarantine: removed.',
      RollbackQuarantineState.retained => 'Quarantine: retained for recovery.',
      RollbackQuarantineState.outcomeUnknown =>
        'Quarantine: outcome unknown at ${_safe(identity.quarantinePath)}.',
    });
    _writeHuman(stderr, switch (recovery.clean) {
      RollbackCleanState.notRequested => 'Clean: not requested.',
      RollbackCleanState.notAttempted => 'Clean: not attempted.',
      RollbackCleanState.validationFailedPreserved =>
        'Clean: validation failed before deletion; evidence was preserved.',
      RollbackCleanState.removed => 'Clean: evidence removed.',
      RollbackCleanState.retained => 'Clean: retained for recovery.',
      RollbackCleanState.recoveryRequired =>
        'Clean: retained journal recovery required.',
      RollbackCleanState.outcomeUnknown =>
        'Clean: outcome unknown; evidence may be partial.',
    });
    _writeHuman(stderr, 'Detail: ${_safe(recovery.detail)}');
    switch (recovery.nextAction.kind) {
      case RollbackNextActionKind.confirmVerifierTerminationThenInspect:
        _writeHuman(
          stderr,
          'Do not run apply, rollback, or clean while the verifier process tree may still be alive.',
        );
        _writeHuman(
          stderr,
          'After termination is independently confirmed, inspect:',
        );
        _writeSuggestedCommand(stderr, recovery.nextAction.commands.single);
      case RollbackNextActionKind.inspect:
        _writeHuman(
          stderr,
          'Inspect the retained quarantine before another action:',
        );
        _writeSuggestedCommand(stderr, recovery.nextAction.commands.single);
      case RollbackNextActionKind.listThenInspect:
        _writeHuman(stderr, 'List surviving quarantine evidence:');
        _writeSuggestedCommand(stderr, recovery.nextAction.commands.first);
        _writeHuman(stderr, 'Inspect the retained run if it is still present:');
        _writeSuggestedCommand(stderr, recovery.nextAction.commands.last);
      case RollbackNextActionKind.targetedClean:
        _writeHuman(
          stderr,
          'Move verified quarantine evidence into retained recovery storage with:',
        );
        _writeSuggestedCommand(stderr, recovery.nextAction.commands.single);
    }
  }

  String _safe(String value) => QuarantineFormatter.terminalSafe(value);

  void _writeSuggestedCommand(IOSink sink, RollbackSuggestedCommand command) {
    final lines = _suggestedCommand(
      command.argv,
    ).renderForTerminal(ShellDialect.host).split('\n');
    for (var index = 0; index < lines.length; index++) {
      // The no-shell JSON argv line is intentionally unwrapped: wrapping would
      // corrupt its directly decodable recovery instruction.
      if (index == 1 && lines.first.startsWith('Exact action argv')) {
        sink.writeln(lines[index]);
      } else {
        _writeHuman(sink, lines[index]);
      }
    }
  }

  void _writeHuman(IOSink sink, String value) {
    const metrics = TerminalTextMetrics();
    final configured = int.tryParse(_environment()['COLUMNS'] ?? '');
    var width = configured != null && configured >= 12 ? configured : null;
    if (width == null) {
      try {
        if (sink case final Stdout terminal) {
          if (terminal.hasTerminal) {
            final terminalColumns = terminal.terminalColumns;
            if (terminalColumns >= 12) {
              width = terminalColumns;
            }
          }
        }
      } on StdoutException {
        // A redirected human report falls back to the stable readable width.
      }
    }
    for (final line in metrics.wrap(
      QuarantineFormatter.terminalSafe(value),
      width: width ?? 160,
    )) {
      sink.writeln(line);
    }
  }

  SuggestedCommand _suggestedCommand(List<String> argv) {
    if (argv.isEmpty) {
      throw ArgumentError.value(argv, 'argv', 'must include an executable');
    }
    if (argv.first == 'flutter_pruner') {
      return SuggestedCommand.flutterPruner(argv.skip(1).toList());
    }
    return SuggestedCommand(argv.first, argv.skip(1).toList());
  }

  String _formatMode(int mode) => '0${mode.toRadixString(8)}';

  bool _isCompleteStepEvidence(List<String> required, List<String> observed) =>
      required.isNotEmpty && _sameStringSet(required, observed);

  bool _sameStringSet(List<String> left, List<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return left.length == leftSet.length &&
        right.length == rightSet.length &&
        leftSet.difference(rightSet).isEmpty &&
        rightSet.difference(leftSet).isEmpty;
  }

  Directory _locateQuarantine(
    ToolWorkspace workspace,
    String? explicitBase,
    String runId,
  ) {
    if (explicitBase != null) {
      return Directory(
        p.join(workspace.resolveQuarantineDirectory(explicitBase).path, runId),
      );
    }

    final matches = [
      for (final base in _defaultQuarantineBases(workspace))
        Directory(p.join(base.path, runId)),
    ].where((directory) => directory.existsSync()).toList();
    if (matches.length > 1) {
      throw QuarantineException(
        'Ambiguous quarantine run $runId found in both default locations. '
        'Pass --quarantine to select one.',
      );
    }
    return matches.isEmpty
        ? Directory(
            p.join(_defaultQuarantineBases(workspace).first.path, runId),
          )
        : matches.single;
  }

  List<Directory> _defaultQuarantineBases(ToolWorkspace workspace) => [
    workspace.resolveQuarantineDirectory(
      QuarantineManager.defaultQuarantineDir,
    ),
    workspace.resolveQuarantineDirectory(QuarantineManager.legacyQuarantineDir),
  ];

  void _requireSelectedProject(Directory selected, Directory recorded) {
    final selectedPath = _canonicalPath(selected);
    final recordedPath = _canonicalPath(recorded);
    if (p.equals(selectedPath, recordedPath)) return;
    throw QuarantineException(
      'Quarantine belongs to $recordedPath, not the selected project '
      '$selectedPath.',
    );
  }

  String _canonicalPath(Directory directory) {
    try {
      return p.normalize(directory.resolveSymbolicLinksSync());
    } on FileSystemException {
      return p.normalize(p.absolute(directory.path));
    }
  }

  String _inferProjectRoot(QuarantineManifest manifest) {
    final paths = [
      ...manifest.entries.map((entry) => entry.originalPath),
      ...manifest.cases.map((item) => item.entry.originalPath),
    ];
    if (paths.isEmpty) {
      throw QuarantineException(
        'Legacy manifest has no entries from which to infer the project root.',
      );
    }

    var current = File(paths.first).parent;
    while (true) {
      if (File(p.join(current.path, 'pubspec.yaml')).existsSync()) {
        return current.path;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    throw QuarantineException(
      'Cannot infer project root for legacy quarantine $name.',
    );
  }

  int _restoredFileCount(QuarantineManifest manifest) =>
      (manifest.usesCaseJournal
              ? manifest.cases.map((item) => item.entry.originalPath)
              : manifest.entries.map((item) => item.originalPath))
          .map((path) => p.normalize(p.absolute(path)))
          .toSet()
          .length;
}
