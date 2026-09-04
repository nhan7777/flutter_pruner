import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../quarantine/clean_move_backend.dart';
import '../../quarantine/quarantine_clean_executor.dart';
import '../../quarantine/quarantine_manager.dart';
import '../../quarantine/recoverable_clean_inspection.dart';
import '../../quarantine/recoverable_clean_store.dart';
import '../cli_exit_code.dart';
import '../confirmation_prompt.dart';
import '../formatters/quarantine_formatter.dart';
import '../project_command_support.dart';
import '../terminal_text_metrics.dart';
import '../usage_error.dart';

/// Manages quarantine directories.
///
/// Provides subcommands to list, inspect, and clean quarantines.
class QuarantineCommand extends Command<int> {
  /// Creates the quarantine command.
  QuarantineCommand({
    QuarantineManager Function(Directory)? managerFactory,
    QuarantineCleanExecutor? cleanExecutor,
    RecoverableCleanStore Function(Directory)? cleanStoreFactory,
    ConfirmationPrompt confirmationPrompt = const StdioConfirmationPrompt(),
  }) {
    final createManager = managerFactory ?? QuarantineManager.new;
    addSubcommand(_ListCommand(managerFactory: createManager));
    addSubcommand(
      _CleanCommand(
        managerFactory: createManager,
        cleanExecutor: cleanExecutor,
        cleanStoreFactory:
            cleanStoreFactory ??
            (projectRoot) => RecoverableCleanStore(projectRoot: projectRoot),
        confirmationPrompt: confirmationPrompt,
      ),
    );
    addSubcommand(_InspectCommand(managerFactory: createManager));
    addSubcommand(
      _RetainedCommand(
        cleanStoreFactory:
            cleanStoreFactory ??
            (projectRoot) => RecoverableCleanStore(projectRoot: projectRoot),
      ),
    );
  }

  @override
  String get name => 'quarantine';

  @override
  String get description => 'Manage quarantine directories (alias: q)';

  @override
  List<String> get aliases => ['q'];

  @override
  String get usageFooter => '''Examples:
  flutter_pruner quarantine list
  flutter_pruner quarantine inspect RUN_ID
  flutter_pruner quarantine clean RUN_ID --dry-run''';
}

class _RetainedCommand extends Command<int> {
  _RetainedCommand({
    required RecoverableCleanStore Function(Directory) cleanStoreFactory,
  }) {
    addSubcommand(_RetainedListCommand(cleanStoreFactory));
    addSubcommand(_RetainedInspectCommand(cleanStoreFactory));
    addSubcommand(_RetainedRestoreCommand(cleanStoreFactory));
  }

  @override
  String get name => 'retained';

  @override
  String get description => 'Inspect or restore logically cleaned quarantines';
}

abstract class _RetainedBaseCommand extends Command<int> {
  _RetainedBaseCommand(this.cleanStoreFactory) {
    argParser
      ..addOption(
        'format',
        allowed: const ['human', 'json'],
        defaultsTo: 'human',
        help: 'Output format',
      )
      ..addOption(
        'quarantine',
        help: 'Explicit quarantine base containing retained clean evidence',
      );
    addProjectOption(argParser);
  }

  final RecoverableCleanStore Function(Directory) cleanStoreFactory;

  List<Directory> selectedBases(ToolWorkspace workspace) {
    final explicit = argResults!.option('quarantine');
    return explicit == null
        ? _defaultQuarantineBases(workspace)
        : <Directory>[workspace.resolveQuarantineDirectory(explicit)];
  }
}

class _RetainedListCommand extends _RetainedBaseCommand {
  _RetainedListCommand(super.cleanStoreFactory);

  @override
  String get name => 'list';

  @override
  String get description => 'List retained clean operations';

  @override
  Future<int> run() async {
    if (argResults!.rest.isNotEmpty) {
      throw commandUsageError(this, 'Retained list accepts no arguments.');
    }
    final workspace = _resolveWorkspace(argResults!, command: this);
    if (workspace == null) return CliExitCode.operationalFailure;
    try {
      final inspections = await cleanStoreFactory(
        workspace.projectRoot,
      ).inspect(quarantineBases: selectedBases(workspace));
      if (argResults!.option('format') == 'json') {
        stdout.write(QuarantineFormatter.formatRetainedListJson(inspections));
      } else {
        stdout.write(
          QuarantineFormatter.formatRetainedListHuman(
            inspections,
            lineWidth: _humanLineWidth(),
          ),
        );
      }
      return inspections.any(
            (inspection) =>
                inspection.state ==
                RecoverableCleanInspectionState.recoveryRequired,
          )
          ? 1
          : 0;
    } on Object catch (error) {
      _writeHuman(
        stderr,
        'Error: ${QuarantineFormatter.terminalSafe('$error')}',
      );
      return 1;
    }
  }
}

class _RetainedInspectCommand extends _RetainedBaseCommand {
  _RetainedInspectCommand(super.cleanStoreFactory);

  @override
  String get name => 'inspect';

  @override
  String get description => 'Inspect one retained clean operation';

  @override
  Future<int> run() async {
    if (argResults!.rest.length != 1) {
      throw commandUsageError(this, 'One operation ID is required.');
    }
    final workspace = _resolveWorkspace(argResults!, command: this);
    if (workspace == null) return CliExitCode.operationalFailure;
    final operationId = argResults!.rest.single;
    try {
      validateCleanPathComponent(operationId);
      final matches =
          (await cleanStoreFactory(
                workspace.projectRoot,
              ).inspect(quarantineBases: selectedBases(workspace)))
              .where((inspection) => inspection.operationId == operationId)
              .toList(growable: false);
      if (matches.length != 1) {
        _writeHuman(
          stderr,
          'Error: retained operation is missing or ambiguous.',
        );
        return 1;
      }
      if (argResults!.option('format') == 'json') {
        stdout.write(QuarantineFormatter.formatRetainedListJson(matches));
      } else {
        stdout.write(
          QuarantineFormatter.formatRetainedListHuman(
            matches,
            lineWidth: _humanLineWidth(),
          ),
        );
      }
      return matches.single.state ==
              RecoverableCleanInspectionState.recoveryRequired
          ? 1
          : 0;
    } on Object catch (error) {
      _writeHuman(
        stderr,
        'Error: ${QuarantineFormatter.terminalSafe('$error')}',
      );
      return 1;
    }
  }
}

class _RetainedRestoreCommand extends _RetainedBaseCommand {
  _RetainedRestoreCommand(super.cleanStoreFactory);

  @override
  String get name => 'restore';

  @override
  String get description => 'Restore one retained run without replacement';

  @override
  Future<int> run() async {
    if (argResults!.rest.length != 2) {
      throw commandUsageError(this, 'Operation ID and run ID are required.');
    }
    final workspace = _resolveWorkspace(argResults!, command: this);
    if (workspace == null) return CliExitCode.operationalFailure;
    final operationId = argResults!.rest[0];
    final runId = argResults!.rest[1];
    ProjectOperationLock? lock;
    try {
      validateCleanPathComponent(operationId);
      QuarantineManager.validateRunId(runId);
      final store = cleanStoreFactory(workspace.projectRoot);
      final bases = selectedBases(workspace);
      final matches = (await store.inspect(quarantineBases: bases))
          .where((inspection) => inspection.operationId == operationId)
          .toList(growable: false);
      if (matches.length != 1) {
        _writeHuman(
          stderr,
          'Error: retained operation is missing or ambiguous.',
        );
        return 1;
      }
      lock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: 'quarantine-retained-restore',
      );
      final result = await store.restore(
        quarantineBase: Directory(matches.single.quarantineBasePath),
        operationId: operationId,
        runId: runId,
      );
      if (argResults!.option('format') == 'json') {
        stdout.write(QuarantineFormatter.formatRetainedRestoreJson(result));
      } else {
        stdout.write(
          QuarantineFormatter.formatRetainedRestoreHuman(
            result,
            lineWidth: _humanLineWidth(),
          ),
        );
      }
      return 0;
    } on Object catch (error) {
      _writeHuman(
        stderr,
        'Error: ${QuarantineFormatter.terminalSafe('$error')}',
      );
      return 1;
    } finally {
      await lock?.release();
    }
  }
}

class _ListCommand extends Command<int> {
  _ListCommand({required QuarantineManager Function(Directory) managerFactory})
    : _managerFactory = managerFactory {
    argParser
      ..addOption(
        'format',
        allowed: const ['human', 'json'],
        defaultsTo: 'human',
        help: 'Output format',
      )
      ..addOption(
        'limit',
        defaultsTo: '${QuarantineFormatter.defaultListLimit}',
        help: 'Maximum quarantine entries to show',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory; defaults to .flutter_pruner/quarantine in '
            'the selected project',
      );
    addProjectOption(argParser);
  }

  final QuarantineManager Function(Directory) _managerFactory;

  @override
  String get name => 'list';

  @override
  String get description => 'List quarantines';

  @override
  String get usageFooter => '''Examples:
  flutter_pruner quarantine list
  flutter_pruner quarantine list --format json''';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.isNotEmpty) {
      throw commandUsageError(
        this,
        'Quarantine list does not accept positional arguments.',
      );
    }
    final limit = _parsePositiveLimit(args.option('limit'));
    if (limit == null) {
      throw commandUsageError(this, '--limit must be a positive integer.');
    }
    final workspace = _resolveWorkspace(args, command: this);
    if (workspace == null) return CliExitCode.operationalFailure;
    final quarantineManager = _managerFactory(workspace.projectRoot);
    late final List<QuarantineInspection> quarantines;
    try {
      quarantines = await _inspectQuarantines(
        quarantineManager,
        workspace,
        args.option('quarantine'),
      );
    } on ToolWorkspaceException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return CliExitCode.operationalFailure;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return 1;
    } on FileSystemException catch (e) {
      _writeHuman(stderr, 'Error: Failed to inspect quarantine: $e');
      return 1;
    }

    final returned = quarantines.take(limit).toList(growable: false);
    if (args.option('format') == 'json') {
      stdout.write(
        QuarantineFormatter.formatListJson(
          projectRoot: workspace.projectRoot.path,
          items: returned,
          total: quarantines.length,
        ),
      );
    } else {
      stdout.write(
        QuarantineFormatter.formatListHuman(
          items: returned,
          total: quarantines.length,
          limit: limit,
          lineWidth: _humanLineWidth(),
        ),
      );
    }

    return 0;
  }
}

class _CleanCommand extends Command<int> {
  _CleanCommand({
    required QuarantineManager Function(Directory) managerFactory,
    required QuarantineCleanExecutor? cleanExecutor,
    required RecoverableCleanStore Function(Directory) cleanStoreFactory,
    required ConfirmationPrompt confirmationPrompt,
  }) : _managerFactory = managerFactory,
       _cleanExecutor = cleanExecutor,
       _cleanStoreFactory = cleanStoreFactory,
       _confirmationPrompt = confirmationPrompt {
    argParser
      ..addFlag(
        'all',
        negatable: false,
        help: 'Logically clean all quarantines',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Preview quarantine evidence without moving it',
      )
      ..addOption(
        'format',
        allowed: const ['human', 'json'],
        defaultsTo: 'human',
        help: 'Output format',
      )
      ..addOption(
        'confirm-clean-fingerprint',
        help: 'Confirm full reviewed fingerprint for --all execution',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory; defaults to .flutter_pruner/quarantine in '
            'the selected project',
      );
    addProjectOption(argParser);
  }

  final QuarantineManager Function(Directory) _managerFactory;
  final QuarantineCleanExecutor? _cleanExecutor;
  final RecoverableCleanStore Function(Directory) _cleanStoreFactory;
  final ConfirmationPrompt _confirmationPrompt;

  @override
  String get name => 'clean';

  @override
  String get description =>
      'Logically clean quarantines while retaining recovery bytes';

  @override
  String get usageFooter {
    const backend = CleanBackendDisclosure.recoverableLogicalMove;
    return '''Examples:
  flutter_pruner quarantine clean RUN_ID --dry-run
  flutter_pruner quarantine clean --all --dry-run
  flutter_pruner quarantine clean --all --confirm-clean-fingerprint v2:${'0' * 64}

Clean-all:
  --all moves only terminal cleanable evidence into retained storage
  Run --dry-run before supplying --confirm-clean-fingerprint
  Current backend: ${backend.name}
  Current backend is non-atomic, identity-bound, and crash-recoverable
  Physical bytes are retained; no disk space is reclaimed
  Release eligibility remains pending hosted evidence for ${backend.blockerCode}''';
  }

  @override
  String get invocation => '${super.invocation} [<run-id> | --all]';

  @override
  Future<int> run() async {
    final args = argResults!;
    final cleanAll = args.flag('all');
    final confirmationFingerprint = args.option('confirm-clean-fingerprint');
    if (cleanAll && args.rest.isNotEmpty) {
      throw commandUsageError(
        this,
        'Do not combine --all with a quarantine run ID.',
      );
    }
    if (!cleanAll && confirmationFingerprint != null) {
      throw commandUsageError(
        this,
        '--confirm-clean-fingerprint is valid only with --all.',
      );
    }
    if (confirmationFingerprint != null &&
        !CleanAllConfirmation.isValidFingerprint(confirmationFingerprint)) {
      throw commandUsageError(
        this,
        '--confirm-clean-fingerprint must be a versioned lowercase SHA-256 fingerprint.',
      );
    }
    if (!cleanAll && args.rest.length != 1) {
      throw commandUsageError(this, 'A run ID is required, or use --all.');
    }
    final workspace = _resolveWorkspace(
      args,
      command: this,
      terminalSafeErrors: true,
    );
    if (workspace == null) return CliExitCode.operationalFailure;
    final quarantineManager = _managerFactory(workspace.projectRoot);
    final explicitBase = args.option('quarantine');

    if (args.flag('dry-run')) {
      return _previewClean(
        quarantineManager: quarantineManager,
        workspace: workspace,
        explicitBase: explicitBase,
        runId: cleanAll ? null : args.rest.single,
        format: args.option('format')!,
      );
    }

    return _executeReviewedClean(
      quarantineManager: quarantineManager,
      workspace: workspace,
      explicitBase: explicitBase,
      runId: cleanAll ? null : args.rest.single,
      format: args.option('format')!,
      confirmationFingerprint: confirmationFingerprint,
    );
  }

  Future<int> _executeReviewedClean({
    required QuarantineManager quarantineManager,
    required ToolWorkspace workspace,
    required String? explicitBase,
    required String? runId,
    required String format,
    required String? confirmationFingerprint,
  }) async {
    final bases = explicitBase == null
        ? _defaultQuarantineBases(workspace)
        : <Directory>[workspace.resolveQuarantineDirectory(explicitBase)];
    late final QuarantineCleanPlan initialPlan;
    try {
      initialPlan = await _buildCleanPlanLocked(
        quarantineManager: quarantineManager,
        workspace: workspace,
        bases: bases,
        runId: runId,
        operation: runId == null
            ? 'quarantine-clean-all-preview'
            : 'quarantine-clean-preview',
      );
    } on ProjectOperationLockException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 1;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 1;
    } on FileSystemException catch (e) {
      _writeHuman(
        stderr,
        'Error: Failed to build quarantine clean plan: '
        '${QuarantineFormatter.terminalSafe('$e')}',
      );
      return 1;
    }

    if (initialPlan.targets.isEmpty) {
      if (format == 'json') {
        stdout.write(QuarantineFormatter.formatCleanPlanJson(initialPlan));
      } else {
        stdout.write(
          QuarantineFormatter.formatCleanPlanHuman(
            initialPlan,
            lineWidth: _humanLineWidth(),
          ),
        );
      }
      return 0;
    }

    if (runId == null) {
      final nonInteractive =
          format == 'json' || !_confirmationPrompt.isInteractive;
      if (nonInteractive) {
        if (confirmationFingerprint == null) {
          throw commandUsageError(
            this,
            'Non-interactive --all execution requires --confirm-clean-fingerprint.',
          );
        }
        if (confirmationFingerprint != initialPlan.fingerprint) {
          _writeHuman(
            stderr,
            'Error: quarantine clean evidence is stale; run --dry-run again.',
          );
          return 2;
        }
      } else {
        stdout.write(
          QuarantineFormatter.formatCleanPlanHuman(
            initialPlan,
            lineWidth: _humanLineWidth(),
          ),
        );
        final required = CleanAllConfirmation.requiredPhrase(
          targetCount: initialPlan.targets.length,
          fingerprint: initialPlan.fingerprint,
        );
        final response = await _confirmationPrompt.readLine(
          "Type '$required' to logically clean this quarantine evidence: ",
        );
        if (!CleanAllConfirmation.matches(
          input: response,
          targetCount: initialPlan.targets.length,
          fingerprint: initialPlan.fingerprint,
        )) {
          _writeHuman(stdout, 'Cancelled.');
          return 0;
        }
      }
    }

    late final ProjectOperationLock operationLock;
    try {
      operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: runId == null
            ? 'quarantine-clean-all-reviewed'
            : 'quarantine-clean-reviewed',
      );
    } on ProjectOperationLockException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 1;
    }

    try {
      final currentPlan = await quarantineManager.planCleanQuarantine(
        runId: runId,
        quarantineBases: bases,
      );
      if (currentPlan.fingerprint != initialPlan.fingerprint) {
        _writeHuman(
          stderr,
          'Error: quarantine clean evidence changed before the retained move; run --dry-run again.',
        );
        return 2;
      }
      if (_cleanExecutor != null) {
        return await _executeRevalidatedTargets(
          quarantineManager: quarantineManager,
          bases: bases,
          initialPlan: initialPlan,
          format: format,
        );
      }
      return await _executeRecoverableTargets(
        workspace: workspace,
        initialPlan: initialPlan,
        format: format,
      );
    } on QuarantineCleanPlanDriftException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 2;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 1;
    } on FileSystemException catch (e) {
      _writeHuman(
        stderr,
        'Error: Failed to revalidate quarantine clean: '
        '${QuarantineFormatter.terminalSafe('$e')}',
      );
      return 1;
    } finally {
      await operationLock.release();
    }
  }

  Future<int> _executeRecoverableTargets({
    required ToolWorkspace workspace,
    required QuarantineCleanPlan initialPlan,
    required String format,
  }) async {
    final targetsByBase = <String, List<QuarantineCleanTarget>>{};
    for (final target in initialPlan.targets) {
      targetsByBase
          .putIfAbsent(p.dirname(target.canonicalPath), () => [])
          .add(target);
    }
    final outcomes = <QuarantineCleanTargetOutcome>[];
    final operationIds = <String>{};
    final orderedGroups = targetsByBase.entries.toList()
      ..sort((left, right) => left.key.compareTo(right.key));
    for (var groupIndex = 0; groupIndex < orderedGroups.length; groupIndex++) {
      final group = orderedGroups[groupIndex];
      final groupPlan = QuarantineCleanPlan.fromEvidence(
        scope: initialPlan.scope,
        canonicalBases: <String>[group.key],
        targets: group.value,
        backend: CleanBackendDisclosure.recoverableLogicalMove,
      );
      late final RecoverableCleanExecutionResult execution;
      try {
        execution = await _cleanStoreFactory(
          workspace.projectRoot,
        ).execute(plan: groupPlan, quarantineBase: Directory(group.key));
      } on RecoverableCleanStoreException catch (error) {
        outcomes.addAll(
          group.value.map(
            (target) => QuarantineCleanTargetOutcome(
              runId: target.runId,
              canonicalPath: target.canonicalPath,
              state: QuarantineCleanTargetState.preserved,
              failureCode: error.category.name,
              failureMessage: '$error',
            ),
          ),
        );
        for (final remaining in orderedGroups.skip(groupIndex + 1)) {
          _appendNotAttempted(outcomes, remaining.value);
        }
        final result = QuarantineCleanResult(
          fingerprint: initialPlan.fingerprint,
          mutationAttempted: outcomes.any(
            (outcome) =>
                outcome.state == QuarantineCleanTargetState.retained ||
                outcome.state == QuarantineCleanTargetState.recoveryRequired,
          ),
          outcomes: outcomes,
          failureCode: error.category.name,
          failureMessage: '$error',
        );
        _writeCleanResult(result, format: format);
        _writeHuman(stderr, 'Error: recoverable quarantine clean failed.');
        return 1;
      }
      operationIds.add(execution.operationId);
      final retainedByRun = <String, RecoverableCleanExecutionTarget>{
        for (final target in execution.targets) target.runId: target,
      };
      for (final target in group.value) {
        final retained = retainedByRun[target.runId];
        outcomes.add(
          QuarantineCleanTargetOutcome(
            runId: target.runId,
            canonicalPath: target.canonicalPath,
            operationId: execution.operationId,
            retainedPath: retained?.retainedPath,
            state: retained != null && execution.committed
                ? QuarantineCleanTargetState.retained
                : QuarantineCleanTargetState.recoveryRequired,
            physicalBytesRetained: retained != null,
            failureCode: execution.recoveryRequired
                ? 'recovery_required'
                : null,
            failureMessage: execution.recoveryRequired
                ? 'Inspect retained clean journal before another mutation.'
                : null,
          ),
        );
      }
      if (!execution.committed) {
        for (final remaining in orderedGroups.skip(groupIndex + 1)) {
          _appendNotAttempted(outcomes, remaining.value);
        }
        final result = QuarantineCleanResult(
          fingerprint: initialPlan.fingerprint,
          operationId: operationIds.length == 1 ? operationIds.single : null,
          mutationAttempted: true,
          outcomes: outcomes,
          failureCode: 'recovery_required',
          failureMessage:
              'Inspect retained clean journal before another mutation.',
        );
        _writeCleanResult(result, format: format);
        _writeHuman(
          stderr,
          'Error: clean requires retained-journal recovery; do not retry blindly.',
        );
        return 1;
      }
    }
    final result = QuarantineCleanResult(
      fingerprint: initialPlan.fingerprint,
      operationId: operationIds.length == 1 ? operationIds.single : null,
      mutationAttempted: outcomes.isNotEmpty,
      outcomes: outcomes,
    );
    _writeCleanResult(result, format: format);
    return 0;
  }

  Future<int> _executeRevalidatedTargets({
    required QuarantineManager quarantineManager,
    required List<Directory> bases,
    required QuarantineCleanPlan initialPlan,
    required String format,
  }) async {
    final outcomes = <QuarantineCleanTargetOutcome>[];
    var deletionAttempted = false;
    for (var index = 0; index < initialPlan.targets.length; index++) {
      final expected = initialPlan.targets[index];
      late final QuarantineCleanTarget revalidated;
      try {
        if (initialPlan.scope == CleanScope.all) {
          final suffixPlan = await quarantineManager.planCleanQuarantine(
            quarantineBases: bases,
          );
          final expectedSuffix = initialPlan.targets
              .skip(index)
              .toList(growable: false);
          if (!_sameCleanTargetLists(suffixPlan.targets, expectedSuffix)) {
            throw QuarantineCleanPlanDriftException(
              'Quarantine clean target set changed before ${expected.runId}.',
            );
          }
          revalidated = suffixPlan.targets.first;
        } else {
          final targetPlan = await quarantineManager.planCleanQuarantine(
            runId: expected.runId,
            quarantineBases: bases,
          );
          if (targetPlan.targets.length != 1 ||
              !_sameCleanTargetEvidence(targetPlan.targets.single, expected)) {
            throw QuarantineCleanPlanDriftException(
              'Quarantine clean target changed: ${expected.runId}.',
            );
          }
          revalidated = targetPlan.targets.single;
        }
      } on QuarantineCleanPlanDriftException catch (error) {
        return _handleCleanRevalidationFailure(
          error: error,
          expected: expected,
          remaining: initialPlan.targets.skip(index + 1),
          fingerprint: initialPlan.fingerprint,
          outcomes: outcomes,
          deletionAttempted: deletionAttempted,
          format: format,
          failureCode: 'target_drift',
          preBoundaryExitCode: 2,
          partialError:
              'Error: quarantine clean stopped after a target changed. Inspect the receipt before another action.',
        );
      } on QuarantineException catch (error) {
        return _handleCleanRevalidationFailure(
          error: error,
          expected: expected,
          remaining: initialPlan.targets.skip(index + 1),
          fingerprint: initialPlan.fingerprint,
          outcomes: outcomes,
          deletionAttempted: deletionAttempted,
          format: format,
          failureCode: 'validation_failed',
          preBoundaryExitCode: 1,
          partialError:
              'Error: quarantine clean stopped after validation failed. Inspect the receipt before another action.',
        );
      } on FileSystemException catch (error) {
        return _handleCleanRevalidationFailure(
          error: error,
          expected: expected,
          remaining: initialPlan.targets.skip(index + 1),
          fingerprint: initialPlan.fingerprint,
          outcomes: outcomes,
          deletionAttempted: deletionAttempted,
          format: format,
          failureCode: 'validation_failed',
          preBoundaryExitCode: 1,
          partialError:
              'Error: quarantine clean stopped after validation failed. Inspect the receipt before another action.',
        );
      } catch (error) {
        if (!deletionAttempted) rethrow;
        return _handleCleanRevalidationFailure(
          error: error,
          expected: expected,
          remaining: initialPlan.targets.skip(index + 1),
          fingerprint: initialPlan.fingerprint,
          outcomes: outcomes,
          deletionAttempted: true,
          format: format,
          failureCode: 'internal_revalidation_failed',
          failureMessage:
              'Quarantine clean stopped after an internal revalidation failure.',
          preBoundaryExitCode: 70,
          partialExitCode: 70,
          partialError:
              'Internal error: quarantine clean stopped after an internal revalidation failure. Inspect the partial receipt before another action.',
        );
      }

      deletionAttempted = true;
      try {
        await _cleanExecutor!.delete(
          QuarantineCleanDeleteRequest(
            runId: revalidated.runId,
            canonicalPath: revalidated.canonicalPath,
          ),
        );
        outcomes.add(
          QuarantineCleanTargetOutcome(
            runId: revalidated.runId,
            canonicalPath: revalidated.canonicalPath,
            state: QuarantineCleanTargetState.removed,
          ),
        );
      } on Object catch (error) {
        final message = _cleanFailureMessage(error);
        outcomes.add(
          QuarantineCleanTargetOutcome(
            runId: revalidated.runId,
            canonicalPath: revalidated.canonicalPath,
            state: QuarantineCleanTargetState.outcomeUnknown,
            failureCode: 'delete_failed',
            failureMessage: message,
          ),
        );
        _appendNotAttempted(outcomes, initialPlan.targets.skip(index + 1));
        final result = QuarantineCleanResult(
          fingerprint: initialPlan.fingerprint,
          deletionAttempted: true,
          outcomes: outcomes,
          failureCode: 'delete_failed',
          failureMessage: message,
        );
        _writeCleanResult(result, format: format);
        _writeHuman(
          stderr,
          'Error: quarantine deletion outcome is unknown. Inspect surviving evidence before another action.',
        );
        return 1;
      }
    }

    final result = QuarantineCleanResult(
      fingerprint: initialPlan.fingerprint,
      deletionAttempted: deletionAttempted,
      outcomes: outcomes,
    );
    _writeCleanResult(result, format: format);
    return 0;
  }

  int _handleCleanRevalidationFailure({
    required Object error,
    required QuarantineCleanTarget expected,
    required Iterable<QuarantineCleanTarget> remaining,
    required String fingerprint,
    required List<QuarantineCleanTargetOutcome> outcomes,
    required bool deletionAttempted,
    required String format,
    required String failureCode,
    String? failureMessage,
    required int preBoundaryExitCode,
    int partialExitCode = 1,
    required String partialError,
  }) {
    final message = failureMessage ?? _cleanFailureMessage(error);
    outcomes.add(
      QuarantineCleanTargetOutcome(
        runId: expected.runId,
        canonicalPath: expected.canonicalPath,
        state: QuarantineCleanTargetState.preserved,
        failureCode: failureCode,
        failureMessage: message,
      ),
    );
    _appendNotAttempted(outcomes, remaining);
    if (!deletionAttempted) {
      _writeHuman(
        stderr,
        'Error: ${QuarantineFormatter.terminalSafe(message)}',
      );
      return preBoundaryExitCode;
    }
    final result = QuarantineCleanResult(
      fingerprint: fingerprint,
      deletionAttempted: true,
      outcomes: outcomes,
      failureCode: failureCode,
      failureMessage: message,
    );
    _writeCleanResult(result, format: format);
    _writeHuman(stderr, partialError);
    return partialExitCode;
  }

  Future<QuarantineCleanPlan> _buildCleanPlanLocked({
    required QuarantineManager quarantineManager,
    required ToolWorkspace workspace,
    required List<Directory> bases,
    required String? runId,
    required String operation,
  }) async {
    final lock = await ProjectOperationLock.acquire(
      workspace: workspace,
      operation: operation,
    );
    try {
      return await quarantineManager.planCleanQuarantine(
        runId: runId,
        quarantineBases: bases,
      );
    } finally {
      await lock.release();
    }
  }

  void _writeCleanResult(
    QuarantineCleanResult result, {
    required String format,
  }) {
    if (format == 'json') {
      stdout.write(QuarantineFormatter.formatCleanResultJson(result));
    } else {
      stdout.write(
        QuarantineFormatter.formatCleanResultHuman(
          result,
          lineWidth: _humanLineWidth(),
        ),
      );
    }
  }

  void _appendNotAttempted(
    List<QuarantineCleanTargetOutcome> outcomes,
    Iterable<QuarantineCleanTarget> targets,
  ) {
    outcomes.addAll(
      targets.map(
        (target) => QuarantineCleanTargetOutcome(
          runId: target.runId,
          canonicalPath: target.canonicalPath,
          state: QuarantineCleanTargetState.notAttempted,
        ),
      ),
    );
  }

  bool _sameCleanTargetEvidence(
    QuarantineCleanTarget current,
    QuarantineCleanTarget expected,
  ) =>
      current.runId == expected.runId &&
      current.canonicalPath == expected.canonicalPath &&
      current.layoutSha256 == expected.layoutSha256 &&
      current.journalRevision == expected.journalRevision &&
      current.payloadSha256 == expected.payloadSha256 &&
      current.authority == expected.authority &&
      current.repairAction == expected.repairAction;

  bool _sameCleanTargetLists(
    List<QuarantineCleanTarget> current,
    List<QuarantineCleanTarget> expected,
  ) {
    if (current.length != expected.length) return false;
    for (var index = 0; index < current.length; index++) {
      if (!_sameCleanTargetEvidence(current[index], expected[index])) {
        return false;
      }
    }
    return true;
  }

  String _cleanFailureMessage(Object error) => switch (error) {
    QuarantineException(:final message) => message,
    FileSystemException(:final message) => message,
    _ => 'Quarantine clean failed after revalidation.',
  };

  Future<int> _previewClean({
    required QuarantineManager quarantineManager,
    required ToolWorkspace workspace,
    required String? explicitBase,
    required String? runId,
    required String format,
  }) async {
    try {
      final bases = explicitBase == null
          ? _defaultQuarantineBases(workspace)
          : [workspace.resolveQuarantineDirectory(explicitBase)];
      final plan = await quarantineManager.planCleanQuarantine(
        runId: runId,
        quarantineBases: bases,
      );
      if (format == 'json') {
        stdout.write(QuarantineFormatter.formatCleanPlanJson(plan));
      } else {
        stdout.write(
          QuarantineFormatter.formatCleanPlanHuman(
            plan,
            lineWidth: _humanLineWidth(),
          ),
        );
      }
      return 0;
    } on ToolWorkspaceException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return CliExitCode.operationalFailure;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: ${QuarantineFormatter.terminalSafe('$e')}');
      return 1;
    } on FileSystemException catch (e) {
      _writeHuman(
        stderr,
        'Error: Failed to preview quarantine clean: '
        '${QuarantineFormatter.terminalSafe('$e')}',
      );
      return 1;
    }
  }
}

class _InspectCommand extends Command<int> {
  _InspectCommand({
    required QuarantineManager Function(Directory) managerFactory,
  }) : _managerFactory = managerFactory {
    argParser
      ..addOption(
        'format',
        allowed: const ['human', 'json'],
        defaultsTo: 'human',
        help: 'Output format',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory; defaults to .flutter_pruner/quarantine in '
            'the selected project',
      );
    addProjectOption(argParser);
  }

  final QuarantineManager Function(Directory) _managerFactory;

  @override
  String get name => 'inspect';

  @override
  String get description => 'Show quarantine manifest details';

  @override
  String get usageFooter => '''Examples:
  flutter_pruner quarantine inspect RUN_ID
  flutter_pruner quarantine inspect RUN_ID --format json''';

  @override
  String get invocation => '${super.invocation} <run-id>';

  @override
  Future<int> run() async {
    final args = argResults!;

    if (args.rest.length != 1) {
      throw commandUsageError(this, 'A run ID is required.');
    }

    final runId = args.rest.first;
    try {
      QuarantineManager.validateRunId(runId);
    } on QuarantineException catch (e) {
      throw commandUsageError(this, e.message);
    }
    final workspace = _resolveWorkspace(args, command: this);
    if (workspace == null) return CliExitCode.operationalFailure;
    late final Directory quarantineDir;
    late final ValidQuarantineInspection inspection;
    try {
      quarantineDir = _locateQuarantine(
        workspace,
        args.option('quarantine'),
        runId,
      );
    } on ToolWorkspaceException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return CliExitCode.operationalFailure;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return 1;
    }

    if (!quarantineDir.existsSync()) {
      _writeHuman(stderr, 'Error: Quarantine not found: $runId');
      return 1;
    }
    try {
      final manager = _managerFactory(workspace.projectRoot);
      final entries = await _inspectQuarantines(
        manager,
        workspace,
        args.option('quarantine'),
      );
      final matching = entries.where(
        (entry) =>
            p.normalize(p.absolute(entry.path)) ==
            p.normalize(p.absolute(quarantineDir.path)),
      );
      if (matching.length != 1 ||
          matching.single is! ValidQuarantineInspection) {
        final error = matching.isEmpty
            ? 'Quarantine changed during inspection.'
            : switch (matching.single) {
                InvalidQuarantineInspection(:final errorCode) =>
                  'Quarantine evidence is invalid: $errorCode.',
                _ => 'Quarantine evidence is ambiguous.',
              };
        _writeHuman(stderr, 'Error: $error');
        return 1;
      }
      inspection = matching.single as ValidQuarantineInspection;
    } on ToolWorkspaceException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return CliExitCode.operationalFailure;
    } on QuarantineException catch (e) {
      _writeHuman(stderr, 'Error: $e');
      return 1;
    } on FileSystemException catch (e) {
      _writeHuman(stderr, 'Error: Failed to inspect quarantine: $e');
      return 1;
    }

    if (args.option('format') == 'json') {
      stdout.write(
        QuarantineFormatter.formatInspectJson(
          projectRoot: workspace.projectRoot.path,
          inspection: inspection,
        ),
      );
    } else {
      stdout.write(
        QuarantineFormatter.formatInspectHuman(
          inspection,
          lineWidth: _humanLineWidth(),
        ),
      );
    }

    return 0;
  }
}

ToolWorkspace? _resolveWorkspace(
  ArgResults args, {
  required Command<int> command,
  bool terminalSafeErrors = false,
}) {
  try {
    final workspace = resolveToolWorkspace(args);
    final explicitBase = args.option('quarantine');
    if (explicitBase != null) {
      workspace.resolveQuarantineDirectory(explicitBase);
    }
    return workspace;
  } on ProjectSelectionException catch (e) {
    final message = terminalSafeErrors
        ? QuarantineFormatter.terminalSafe('$e')
        : '$e';
    _writeHuman(stderr, 'Error: $message');
    return null;
  } on ToolWorkspaceException catch (e) {
    final message = terminalSafeErrors
        ? QuarantineFormatter.terminalSafe('$e')
        : '$e';
    throw commandUsageError(command, message);
  }
}

int _humanLineWidth() {
  return _defaultTerminalHumanOutput.lineWidth(stdout);
}

void _writeHuman(IOSink sink, String value) {
  _defaultTerminalHumanOutput.write(sink, value);
}

final _defaultTerminalHumanOutput = TerminalHumanOutput();

/// Resolves and wraps a human terminal row for its actual output sink.
///
/// A valid COLUMNS value takes precedence. Otherwise a terminal sink's
/// width is used; redirected output keeps the stable readable fallback.
final class TerminalHumanOutput {
  /// Creates a writer using the process environment by default.
  TerminalHumanOutput({Map<String, String> Function()? environment})
    : _environment = environment ?? (() => Platform.environment);

  final Map<String, String> Function() _environment;

  /// Resolves the display-cell width for [sink].
  int lineWidth(IOSink sink) {
    final configured = int.tryParse(_environment()['COLUMNS'] ?? '');
    if (configured != null && configured >= 12) return configured;
    try {
      if (sink is Stdout && sink.hasTerminal) {
        final columns = sink.terminalColumns;
        if (columns >= 12) return columns;
      }
    } on StdoutException {
      // A redirected human report falls back to the stable readable width.
    }
    return 160;
  }

  /// Wraps [value] for [sink] without terminal control effects.
  List<String> wrap(IOSink sink, String value) {
    const metrics = TerminalTextMetrics();
    return metrics.wrap(
      QuarantineFormatter.terminalSafe(value),
      width: lineWidth(sink),
    );
  }

  /// Writes the wrapped human text to [sink].
  void write(IOSink sink, String value) {
    for (final line in wrap(sink, value)) {
      sink.writeln(line);
    }
  }
}

List<Directory> _defaultQuarantineBases(ToolWorkspace workspace) => [
  workspace.resolveQuarantineDirectory(QuarantineManager.defaultQuarantineDir),
  workspace.resolveQuarantineDirectory(QuarantineManager.legacyQuarantineDir),
];

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
      ? Directory(p.join(_defaultQuarantineBases(workspace).first.path, runId))
      : matches.single;
}

Future<List<QuarantineInspection>> _inspectQuarantines(
  QuarantineManager manager,
  ToolWorkspace workspace,
  String? explicitBase,
) {
  final bases = explicitBase == null
      ? _defaultQuarantineBases(workspace)
      : [workspace.resolveQuarantineDirectory(explicitBase)];
  return manager.inspectQuarantines(quarantineBases: bases);
}

int? _parsePositiveLimit(String? raw) {
  final parsed = raw == null ? null : int.tryParse(raw);
  return parsed == null || parsed <= 0 ? null : parsed;
}
