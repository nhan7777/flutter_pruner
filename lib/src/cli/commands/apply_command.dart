import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../analysis/analysis_snapshot.dart';
import '../../analysis/project_analyzer.dart';
import '../../apply/declaration_remover.dart';
import '../../apply/file_lifecycle_manager.dart';
import '../../apply/finding_action_builder.dart';
import '../../apply/finding_selection.dart';
import '../../apply/import_cleanup_runner.dart';
import '../../apply/mode_apply_policy.dart';
import '../../apply/removal_planner.dart';
import '../../core/confidence/confidence.dart';
import '../../core/confidence/finding.dart';
import '../../core/graph/edge.dart';
import '../../core/graph/node.dart';
import '../../core/graph/reachability_graph.dart';
import '../../core/process/managed_process_runner.dart';
import '../../core/project/analysis_mode.dart';
import '../../core/project/project_context.dart';
import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../quarantine/manifest.dart';
import '../../quarantine/quarantine_manager.dart';
import '../../reporting/immutable_report_store.dart';
import '../../reporting/io_report_object_backend.dart';
import '../../reporting/report_object_backend.dart';
import '../../reporting/report_output_identity.dart';
import '../../reporting/run_recorder.dart';
import '../../reporting/run_report.dart';
import '../../verification/verification_runner.dart';
import '../../version.dart';
import '../formatters/html_formatter.dart';
import '../formatters/human_formatter.dart';
import '../formatters/json_formatter.dart';
import '../init_prompt.dart';
import '../project_command_support.dart';
import '../terminal_progress.dart';
import '../terminal_workflow.dart';

/// Applies findings by moving files to quarantine.
///
/// Rollback restores quarantined regular-file bytes and POSIX modes where
/// available, subject to verification.
class ApplyCommand extends Command<int> {
  /// Creates the apply command.
  ApplyCommand({
    VerificationRunner Function(Directory)? verifierFactory,
    ProjectAnalyzer Function(ProjectContext, Set<String>?)? analyzerFactory,
    ImportCleanupRunner Function(Directory)? cleanupRunnerFactory,
    QuarantineManager Function(Directory)? quarantineManagerFactory,
    ReportObjectBackend? reportBackend,
    FutureOr<void> Function(Directory)? lifecycleCompletedHook,
    InitPrompt prompt = const StdioInitPrompt(),
  }) : _verifierFactory = verifierFactory ?? VerificationRunner.new,
       _analyzerFactory =
           analyzerFactory ??
           ((project, only) => ProjectAnalyzer(project: project, only: only)),
       _cleanupRunnerFactory =
           cleanupRunnerFactory ??
           ((projectRoot) =>
               ImportCleanupRunner(projectRoot: projectRoot.path)),
       _quarantineManagerFactory =
           quarantineManagerFactory ?? QuarantineManager.new,
       _reportBackend = reportBackend ?? createIoReportObjectBackend(),
       _lifecycleCompletedHook = lifecycleCompletedHook,
       _prompt = prompt {
    argParser
      ..addFlag(
        'dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Preview the dependency-closed plan without changing files.',
      )
      ..addFlag(
        'yes',
        negatable: false,
        help:
            'Accept package-internal external-consumer risk without prompting.',
      )
      ..addMultiOption(
        'adapter',
        help: 'Only run these adapters, by id. Defaults to all registered.',
      )
      ..addMultiOption(
        'finding-id',
        splitCommas: false,
        help:
            'Apply only this exact, case-sensitive finding ID. Repeat for an '
            'atomic batch.',
      )
      ..addOption(
        'config',
        help:
            'Configuration path. Relative paths start at the selected project.',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory. Defaults to .flutter_pruner/quarantine in '
            'the selected project.',
      )
      ..addOption(
        'report-output',
        help:
            'Override the automatic .flutter_pruner/reports destination. '
            'Absolute paths remain supported.',
      )
      ..addOption(
        'report-format',
        allowed: const ['json', 'html'],
        defaultsTo: 'html',
        help:
            'Saved report format. Defaults to HTML; quarantine also keeps '
            'canonical JSON.',
      );
    addProjectOption(argParser);
  }

  final VerificationRunner Function(Directory) _verifierFactory;
  final ProjectAnalyzer Function(ProjectContext, Set<String>?) _analyzerFactory;
  final ImportCleanupRunner Function(Directory) _cleanupRunnerFactory;
  final QuarantineManager Function(Directory) _quarantineManagerFactory;
  final ReportObjectBackend _reportBackend;
  final FutureOr<void> Function(Directory)? _lifecycleCompletedHook;
  final InitPrompt _prompt;
  _ApplyReportPersistence? _activeReportPersistence;

  @override
  String get invocation => '${super.invocation} [project-path]';

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Apply findings. Rollback restores quarantined regular-file bytes and '
      'POSIX modes where available, subject to verification.';

  @override
  Future<int> run() async {
    final args = argResults!;
    final dryRun = args.flag('dry-run');
    final assumeYes = args.flag('yes');
    final reportFormat = _ReportOutputFormat.values.byName(
      args.option('report-format')!,
    );
    final only = args.multiOption('adapter').toSet();
    final FindingSelection findingSelection;
    try {
      findingSelection = FindingSelection.fromCli(
        args.multiOption('finding-id'),
      );
    } on FindingSelectionException catch (error) {
      stderr.writeln('Error: ${error.message}');
      return 64;
    }
    final recorder = RunRecorder(
      command: RunCommand.apply,
      requestedAdapters: only.toList()..sort(),
      toolVersion: packageVersion,
    );
    final rest = args.rest;
    if (rest.length > 1) {
      stderr.writeln('Error: expected at most one project path.');
      return 64;
    }

    late final ToolWorkspace workspace;
    try {
      workspace = resolveToolWorkspace(
        args,
        positionalProjectPath: rest.isEmpty ? null : rest.single,
      );
    } on ProjectSelectionException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    }
    late final Directory quarantineBaseDir;
    late final FrozenReportOutputIdentity reportOutput;
    late final File configFile;
    try {
      quarantineBaseDir = workspace.resolveQuarantineDirectory(
        args.option('quarantine'),
      );
      final reportOption = args.option('report-output');
      final requestedReportOutput = reportOption == null
          ? workspace.resolveReportFile(
              'apply-${recorder.runId}.${reportFormat.name}',
            )
          : workspace.resolveReportFile(reportOption);
      reportOutput = await FrozenReportOutputIdentity.resolve(
        requested: requestedReportOutput,
        selectedProjectRoot: workspace.projectRoot,
      );
      final configPath = args.option('config');
      final explicitConfig = configPath == null
          ? null
          : workspace.resolveConfigFile(configPath);
      configFile = requireProjectConfig(workspace, explicitConfig);
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on ProjectConfigPreflightException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    }

    try {
      await _loadProjectForApply(
        workspace: workspace,
        quarantineBaseDir: quarantineBaseDir,
        reportOutput: reportOutput,
        configFile: configFile,
      );
    } on _ApplyProjectPreflightException catch (e) {
      stderr.writeln(e.message);
      return 1;
    }

    late final _ApplyReportPersistence reportPersistence;
    try {
      final externalOutput = await reportOutput.prepare(
        backend: _reportBackend,
        identity: _reportCommitIdentity(recorder.runId, 1),
      );
      reportPersistence = _ApplyReportPersistence(
        runId: recorder.runId,
        backend: _reportBackend,
        externalOutput: externalOutput,
      );
      _activeReportPersistence = reportPersistence;
    } on Object catch (error) {
      stderr.writeln('Error: report output could not be prepared: $error');
      return 1;
    }

    late final ProjectOperationLock operationLock;
    try {
      operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: dryRun ? 'apply-dry-run' : 'apply',
      );
    } on ProjectOperationLockException catch (e) {
      await reportPersistence.close();
      _activeReportPersistence = null;
      stderr.writeln('Error: $e');
      return 1;
    }
    try {
      return await _runLocked(
        workspace: workspace,
        quarantineBaseDir: quarantineBaseDir,
        reportOutput: reportOutput,
        reportPersistence: reportPersistence,
        configFile: configFile,
        dryRun: dryRun,
        assumeYes: assumeYes,
        reportFormat: reportFormat,
        only: only,
        findingSelection: findingSelection,
        recorder: recorder,
      );
    } finally {
      try {
        await reportPersistence.close();
      } finally {
        _activeReportPersistence = null;
        await operationLock.release();
      }
    }
  }

  Future<int> _runLocked({
    required ToolWorkspace workspace,
    required Directory quarantineBaseDir,
    required FrozenReportOutputIdentity reportOutput,
    required _ApplyReportPersistence reportPersistence,
    required File configFile,
    required bool dryRun,
    required bool assumeYes,
    required _ReportOutputFormat reportFormat,
    required Set<String> only,
    required FindingSelection findingSelection,
    required RunRecorder recorder,
  }) async {
    final ProjectContext project;
    try {
      project = await _loadProjectForApply(
        workspace: workspace,
        quarantineBaseDir: quarantineBaseDir,
        reportOutput: reportOutput,
        configFile: configFile,
      );
    } on _ApplyProjectPreflightException catch (e) {
      stderr.writeln(e.message);
      return 1;
    }

    recorder.recordApplySelection(
      ApplySelectionReport(
        mode: findingSelection.mode,
        requestedFindingIds: findingSelection.requestedFindingIds,
        plannedFindingIds: const [],
      ),
    );

    final lineWidth = _terminalLineWidth(stderr);
    final progress = TerminalProgress(
      sink: stderr,
      animated: stderr.hasTerminal,
    )..writeProject(project.root.path);
    final workflow = TerminalWorkflow(sink: stderr, lineWidth: lineWidth);
    final quarantineManager = _quarantineManagerFactory(project.root);
    if (!dryRun) {
      try {
        await quarantineManager.ensureNoBlockingHistoricalQuarantines(
          quarantineBases: {
            quarantineBaseDir,
            workspace.quarantineDirectory,
            workspace.legacyQuarantineDirectory,
          },
        );
      } on QuarantineException catch (error) {
        workflow.recovery(
          'APPLY BLOCKED',
          'Existing quarantine state requires recovery.',
          detail: error.toString(),
        );
        return 1;
      }
    }
    if (project.analysisMode == AnalysisMode.packageInternal) {
      _printPackageInternalWarning(project);
      recorder.addDiagnostic(
        const RunDiagnostic(
          code: 'package-internal-boundary',
          phase: 'analysis',
          message:
              'Only package-local references were analysed; external '
              'consumers were not scanned.',
        ),
      );
    }

    late final ProjectAnalyzer analyzer;
    try {
      analyzer = _analyzerFactory(project, only.isEmpty ? null : only);
    } on StateError catch (e) {
      stderr.writeln('Error: ${e.message}');
      return 64;
    }

    if (analyzer.adapters.isEmpty) {
      stderr.writeln('Error: no matching adapters were selected.');
      return 64;
    }
    recorder.registerAdapterReportDefinitions(
      analyzer.adapterReportDefinitions,
    );

    late AnalysisSnapshot snapshot;
    var analysisSucceeded = false;
    try {
      snapshot = await analyzer.analyze(
        onAdapter: (adapter) => progress.start(adapter.name),
      );
      analysisSucceeded = true;
    } finally {
      progress.finish(succeeded: analysisSucceeded);
    }
    var analysisPassIndex = 1;
    recorder.addAnalysisPass(
      snapshot.toPassReport(
        id: 'analysis-${analysisPassIndex.toString().padLeft(3, '0')}',
        purpose: AnalysisPassPurpose.initial,
      ),
    );
    Future<int> stopForSelectionPreflight({
      required String code,
      required String message,
      required int exitCode,
      required RunStatus status,
      ApplyStatistics applyStatistics = ApplyStatistics.empty,
    }) async {
      recorder.addDiagnostic(
        RunDiagnostic(code: code, phase: 'selection', message: message),
      );
      if (status == RunStatus.internalError) {
        workflow.failure('SELECTION', message);
      } else {
        workflow.warning('SAFE STOP', message);
      }
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: status,
          exitCode: exitCode,
          findings: snapshot.findings,
          applyStatistics: applyStatistics,
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return exitCode;
    }

    late final Map<String, Finding> findingsById;
    try {
      findingsById = _indexUniqueFindings(snapshot.findings);
    } on _FindingSelectionIntegrityException catch (error) {
      return stopForSelectionPreflight(
        code: 'finding_selection_snapshot_integrity',
        message: error.message,
        exitCode: 70,
        status: RunStatus.internalError,
      );
    }
    final allApplicableFindings = _applicableFindings(
      snapshot.findings,
      project: project,
    );
    final applicableById = {
      for (final finding in allApplicableFindings) finding.node.id: finding,
    };
    late final List<Finding> applicableFindings;
    if (findingSelection.isExact) {
      final requested = findingSelection.requestedFindingIds.toSet();
      final unknown = requested.difference(findingsById.keys.toSet()).toList()
        ..sort();
      final nonActionable =
          requested
              .intersection(findingsById.keys.toSet())
              .difference(applicableById.keys.toSet())
              .toList()
            ..sort();
      if (unknown.isNotEmpty || nonActionable.isNotEmpty) {
        final knownRequestedFindings = findingSelection.requestedFindingIds
            .map((findingId) => findingsById[findingId])
            .whereType<Finding>()
            .toList(growable: false);
        final details = <String>[
          if (unknown.isNotEmpty) 'unknown: ${unknown.join(', ')}',
          if (nonActionable.isNotEmpty)
            'not apply-eligible: ${nonActionable.join(', ')}',
        ];
        recorder.recordApplyFindingOutcomes(
          knownRequestedFindings.map(
            (finding) => ApplyFindingOutcome(
              finding: finding,
              status: ApplyFindingOutcomeStatus.remaining,
              reasonCode: 'not_attempted_batch_invalid',
              reason:
                  'The exact batch contained an unknown or non-actionable '
                  'finding; no mutation was attempted.',
            ),
          ),
        );
        return stopForSelectionPreflight(
          code: 'finding_selection_invalid',
          message:
              'The exact finding selection was rejected (${details.join('; ')}). '
              'No verification or mutation was attempted.',
          exitCode: 2,
          status: RunStatus.safeStopped,
          applyStatistics: _preMutationApplyStatistics(
            findingsRemaining: knownRequestedFindings.length,
          ),
        );
      }
      applicableFindings = findingSelection.requestedFindingIds
          .map((findingId) => applicableById[findingId]!)
          .toList(growable: false);
    } else {
      applicableFindings = allApplicableFindings;
    }

    if (applicableFindings.isEmpty) {
      workflow.success(
        'NO CHANGES',
        'No findings are actionable in ${project.analysisMode.wireName}.',
      );
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.noChanges,
          exitCode: 0,
          findings: snapshot.findings,
          applyStatistics: ApplyStatistics.empty,
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return 0;
    }

    final planner = const RemovalPlanner();
    var plan = planner.build(
      findings: applicableFindings,
      graph: snapshot.graph,
      project: project,
    );
    final plannedFindings = plan.units
        .expand((unit) => unit.findings)
        .toList(growable: false);
    final plannedFindingIds = plannedFindings
        .map((finding) => finding.node.id)
        .toList();
    final plannedIdSet = plannedFindingIds.toSet();
    if (plannedIdSet.length != plannedFindingIds.length) {
      return stopForSelectionPreflight(
        code: 'finding_selection_plan_integrity',
        message:
            'The initial removal plan repeated a logical finding ID. No '
            'verification or mutation was attempted.',
        exitCode: 70,
        status: RunStatus.internalError,
      );
    }
    plannedFindingIds.sort();
    if (findingSelection.isExact) {
      final unauthorized = plannedIdSet.difference(
        findingSelection.requestedFindingIds.toSet(),
      );
      if (unauthorized.isNotEmpty) {
        return stopForSelectionPreflight(
          code: 'finding_selection_plan_expanded',
          message:
              'The initial removal plan expanded beyond the exact selection: '
              '${(unauthorized.toList()..sort()).join(', ')}. No verification '
              'or mutation was attempted.',
          exitCode: 70,
          status: RunStatus.internalError,
        );
      }
    }
    var actionPlan = _freezeActionPlan(
      plan,
      graph: snapshot.graph,
      project: project,
    );
    final planFingerprint = plan.units.isEmpty
        ? null
        : _planFingerprint(
            plan,
            actionPlan: actionPlan,
            project: project,
            selection: findingSelection,
          );
    recorder.recordApplySelection(
      ApplySelectionReport(
        mode: findingSelection.mode,
        requestedFindingIds: findingSelection.requestedFindingIds,
        plannedFindingIds: plannedFindingIds,
        planFingerprint: planFingerprint,
      ),
    );

    void recordRemainingOutcomes(
      Iterable<Finding> findings, {
      required String reasonCode,
      required String reason,
    }) {
      recorder.recordApplyFindingOutcomes(
        findings.map(
          (finding) => ApplyFindingOutcome(
            finding: finding,
            status: ApplyFindingOutcomeStatus.remaining,
            reasonCode: reasonCode,
            reason: reason,
          ),
        ),
      );
    }

    void recordBlockedOutcomes(Iterable<BlockedFinding> blocked, {int? round}) {
      recorder.recordApplyFindingOutcomes(
        blocked.map(
          (item) => ApplyFindingOutcome(
            finding: item.finding,
            status: ApplyFindingOutcomeStatus.blocked,
            reasonCode: item.reason == PlanBlockReason.retainedConsumer
                ? 'retained_consumer'
                : 'blocked_by_retained_dependency',
            reason: item.reason == PlanBlockReason.retainedConsumer
                ? 'A retained consumer still references this finding.'
                : 'A retained finding prevents removal of this dependency.',
            round: round,
            relatedNodeIds: [item.blockedBy],
          ),
        ),
      );
    }

    if (findingSelection.isExact) {
      final missing =
          findingSelection.requestedFindingIds
              .toSet()
              .difference(plannedIdSet)
              .toList()
            ..sort();
      if (plan.blocked.isNotEmpty || missing.isNotEmpty) {
        final blockedIds = plan.blocked
            .map((item) => item.finding.node.id)
            .toSet();
        recordBlockedOutcomes(plan.blocked);
        recordRemainingOutcomes(
          applicableFindings.where(
            (finding) => !blockedIds.contains(finding.node.id),
          ),
          reasonCode: 'not_attempted_batch_blocked',
          reason:
              'The exact batch was rejected atomically because at least one '
              'requested finding was blocked.',
        );
        final blockers = plan.blocked
            .map(
              (item) => '${item.finding.node.id} retained by ${item.blockedBy}',
            )
            .toList();
        return stopForSelectionPreflight(
          code: 'finding_selection_not_dependency_closed',
          message:
              'The exact finding batch is not dependency-closed. '
              '${[if (missing.isNotEmpty) 'not planned: ${missing.join(', ')}', if (blockers.isNotEmpty) 'blocked: ${blockers.join('; ')}'].join('. ')}. No verification or mutation was attempted.',
          exitCode: 2,
          status: RunStatus.safeStopped,
          applyStatistics: ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: plan.blocked.length,
            findingsSkippedDependency: 0,
            findingsRemaining: applicableFindings.length,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: 0,
            sourceBytesRemoved: 0,
          ),
        );
      }
    }

    final initiallyBlockedIds = plan.blocked
        .map((item) => item.finding.node.id)
        .toSet();
    recordRemainingOutcomes(
      applicableFindings.where(
        (finding) => !initiallyBlockedIds.contains(finding.node.id),
      ),
      reasonCode: 'not_attempted',
      reason: 'No mutation was attempted for this finding.',
    );
    recordBlockedOutcomes(plan.blocked);

    if (dryRun) {
      recordRemainingOutcomes(
        applicableFindings.where(
          (finding) => !initiallyBlockedIds.contains(finding.node.id),
        ),
        reasonCode: 'dry_run',
        reason: 'Dry run preview; no mutation was attempted.',
      );
      workflow.section(
        'DRY RUN · NO FILES WILL BE CHANGED',
        detail:
            '${plannedFindings.length} '
            '${plannedFindings.length == 1 ? 'finding' : 'findings'} ready in '
            '${plan.units.length} atomic '
            '${plan.units.length == 1 ? 'transaction' : 'transactions'}.',
      );
      _printPlannedFindings(plannedFindings, project, workflow);
      if (plan.blocked.isNotEmpty) {
        workflow.warning(
          'BLOCKED',
          '${plan.blocked.length} '
              '${plan.blocked.length == 1 ? 'finding is' : 'findings are'} blocked.',
        );
        _printBlocked(plan.blocked, project, workflow);
      }
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.dryRun,
          exitCode: 0,
          findings: snapshot.findings,
          applyStatistics: ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: plan.blocked.length,
            findingsSkippedDependency: 0,
            findingsRemaining: applicableFindings.length,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: 0,
            sourceBytesRemoved: 0,
          ),
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return 0;
    }

    if (plan.units.isEmpty) {
      recordRemainingOutcomes(
        applicableFindings.where(
          (finding) => !initiallyBlockedIds.contains(finding.node.id),
        ),
        reasonCode: 'no_dependency_closed_plan',
        reason: 'No dependency-closed transaction could be planned.',
      );
      _printBlocked(plan.blocked, project, workflow);
      workflow.warning(
        'SAFE STOP',
        'No dependency-closed transaction can be applied.',
      );
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.safeStopped,
          exitCode: 2,
          findings: snapshot.findings,
          applyStatistics: ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: plan.blocked.length,
            findingsSkippedDependency: 0,
            findingsRemaining: applicableFindings.length,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: 0,
            sourceBytesRemoved: 0,
          ),
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return 2;
    }

    Future<int> stopForStaleAnalysis(
      _StaleAnalysisSnapshotException error, {
      required int verificationAttempts,
    }) async {
      recordRemainingOutcomes(
        applicableFindings.where(
          (finding) => !initiallyBlockedIds.contains(finding.node.id),
        ),
        reasonCode: 'analysis_snapshot_stale',
        reason: error.message,
      );
      workflow.warning(
        'SAFE STOP',
        'A planned file changed after analysis; no source mutation was attempted.',
        detail: error.message,
      );
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.safeStopped,
          exitCode: 2,
          findings: snapshot.findings,
          applyStatistics: ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: plan.blocked.length,
            findingsSkippedDependency: 0,
            findingsRemaining: applicableFindings.length,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: verificationAttempts,
            sourceBytesRemoved: 0,
          ),
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return 2;
    }

    late Map<String, _AnalysisFileSnapshot> planFileSnapshots;
    try {
      planFileSnapshots = _capturePlanFileSnapshots(
        actionPlan,
        project: project,
      );
    } on _StaleAnalysisSnapshotException catch (error) {
      return stopForStaleAnalysis(error, verificationAttempts: 0);
    }

    workflow.section(
      'PLAN READY',
      detail:
          '${plannedFindings.length} '
          '${plannedFindings.length == 1 ? 'finding' : 'findings'} ready in '
          '${plan.units.length} atomic '
          '${plan.units.length == 1 ? 'transaction' : 'transactions'}.',
    );
    _printPlannedFindings(plannedFindings, project, workflow);

    final acknowledgedFindings = plannedFindings
        .where(ModeApplyPolicy.requiresExternalConsumerAcknowledgement)
        .toList(growable: false);
    var riskAcceptanceSource = RiskAcceptanceSource.notRequired;
    if (acknowledgedFindings.isNotEmpty && !assumeYes) {
      var accepted = false;
      if (_prompt.isInteractive) {
        try {
          accepted = InitQuestions(_prompt).yesNo(
            'Apply ${acknowledgedFindings.length} HIGH '
            '${acknowledgedFindings.length == 1 ? 'finding' : 'findings'} '
            'that may still be used by external consumers?',
            defaultValue: false,
          );
        } on InitCancelledException {
          accepted = false;
        }
      } else {
        workflow.warning(
          'CONFIRMATION',
          'External-consumer risk acknowledgement is required.',
          detail: 'Re-run with --yes in CI/non-interactive environments.',
        );
      }
      if (!accepted) {
        workflow.warning(
          'SAFE STOP',
          'External-consumer risk was not accepted; no files were changed.',
        );
        recordRemainingOutcomes(
          applicableFindings.where(
            (finding) => !initiallyBlockedIds.contains(finding.node.id),
          ),
          reasonCode: 'external_consumer_risk_not_accepted',
          reason:
              'Package-internal external-consumer risk was not accepted; no '
              'mutation was attempted.',
        );
        await _writeRunReport(
          recorder.finish(
            project: project,
            status: RunStatus.safeStopped,
            exitCode: 2,
            findings: snapshot.findings,
            applyStatistics: ApplyStatistics(
              rounds: 0,
              findingsCommitted: 0,
              findingsRejectedRecovered: 0,
              findingsBlocked: plan.blocked.length,
              findingsSkippedDependency: 0,
              findingsRemaining: applicableFindings.length,
              actionsDeclared: 0,
              actionsCommitted: 0,
              actionsRolledBack: 0,
              actionsFailedRecovered: 0,
              transactionsBegun: 0,
              transactionsCommitted: 0,
              transactionsRolledBackVerified: 0,
              transactionsRecoveryRequired: 0,
              transactionsNonTerminal: 0,
              verificationAttempts: 0,
              sourceBytesRemoved: 0,
            ),
          ),
          outputIdentity: reportOutput,
          outputFormat: reportFormat,
        );
        return 2;
      }
      riskAcceptanceSource = RiskAcceptanceSource.interactive;
    } else if (acknowledgedFindings.isNotEmpty) {
      riskAcceptanceSource = RiskAcceptanceSource.yesFlag;
    }
    final acceptedRiskCodes =
        acknowledgedFindings
            .expand((finding) => finding.manualRisks)
            .map((risk) => risk.code)
            .toSet()
            .toList()
          ..sort();
    recorder.recordRiskAcceptance(
      riskCodes: acceptedRiskCodes,
      source: riskAcceptanceSource,
    );

    try {
      _validatePlanFileSnapshots(planFileSnapshots, project: project);
    } on _StaleAnalysisSnapshotException catch (error) {
      return stopForStaleAnalysis(error, verificationAttempts: 0);
    }

    final expectedSha256ByPath = <String, String?>{
      for (final entry in planFileSnapshots.entries)
        entry.key: entry.value.sha256,
    };
    VerificationResult? baseline;
    final verifier = _verifierFactory(project.root);
    final verificationPolicy = project.verificationPolicy;
    var verificationAttemptCount = 1;
    progress.start('verification baseline', activity: 'Capturing');
    try {
      baseline = await verifier.verify(policy: verificationPolicy);
    } catch (_) {
      progress.finish(succeeded: false);
      rethrow;
    }
    final baselineEvidence = baseline.toBaselineEvidence();
    final baselineAdmissible =
        baseline.isAvailable && baselineEvidence.isComplete;
    progress.finish(succeeded: baselineAdmissible);
    recorder.addVerificationAttempt(
      _verificationAttemptReport(
        purpose: VerificationAttemptPurpose.baseline,
        result: baseline,
        accepted: baselineAdmissible,
      ),
    );
    _printVerification(baseline, workflow);
    try {
      _validatePlanFileSnapshots(planFileSnapshots, project: project);
    } on _StaleAnalysisSnapshotException catch (error) {
      return stopForStaleAnalysis(
        error,
        verificationAttempts: verificationAttemptCount,
      );
    }
    if (!baselineAdmissible) {
      recordRemainingOutcomes(
        applicableFindings.where(
          (finding) => !initiallyBlockedIds.contains(finding.node.id),
        ),
        reasonCode: 'verification_baseline_unavailable',
        reason:
            'Verification baseline was unavailable or lacked complete '
            'parser-bound evidence; no mutation was attempted.',
      );
      workflow.failure(
        'VERIFICATION',
        'Baseline is unavailable or incomplete.',
        detail: 'No changes were made.',
      );
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.infrastructureFailure,
          exitCode: 1,
          findings: snapshot.findings,
          applyStatistics: ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: plan.blocked.length,
            findingsSkippedDependency: 0,
            findingsRemaining: applicableFindings.length,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: verificationAttemptCount,
            sourceBytesRemoved: 0,
          ),
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
      );
      return 1;
    }
    final originalBaseline = baseline;
    var rollingBaseline = originalBaseline;

    final runId = recorder.runId;
    workflow.section(
      'REVERSIBLE APPLY',
      detail: 'Creating the quarantine journal before any mutation.',
    );
    workflow.info('RUN ID', runId);
    final quarantineDir = await quarantineManager.createCaseQuarantine(
      runId: runId,
      quarantineBase: quarantineBaseDir.path,
      verificationPolicyHash: verificationPolicy.hash,
      baselineVerification: QuarantineVerificationEvidence(
        policyHash: baseline.policyHash,
        requiredStepIds: baseline.requiredStepIds,
        observedStepIds: baseline.steps.map((step) => step.name).toList(),
        workingDirectory: baseline.workingDirectory,
        toolchainIdentity: baseline.toolchainIdentity,
        available: baseline.isAvailable,
        passed: baseline.passed,
        comparisonBaseline: baselineEvidence,
      ),
      analysisMode: project.analysisMode.wireName,
      acceptedRiskCodes: acceptedRiskCodes,
      riskAcceptanceSource: riskAcceptanceSource.name,
      selection: QuarantineSelectionEvidence(
        mode: findingSelection.mode,
        requestedFindingIds: findingSelection.requestedFindingIds,
        planFingerprint: planFingerprint!,
      ),
    );
    final remover = DeclarationRemover(project);
    final cleanupRunner = _cleanupRunnerFactory(project.root);
    final lifecycleManager = FileLifecycleManager(project);
    var appliedCount = 0;
    var rolledBackCount = 0;
    var failedCount = 0;
    var actionsDeclaredCount = 0;
    var actionsCommittedCount = 0;
    var actionsRolledBackCount = 0;
    var actionsFailedRecoveredCount = 0;
    final begunTransactionIds = <String>{};
    final committedTransactionIds = <String>{};
    final rolledBackVerifiedTransactionIds = <String>{};
    final recoveryRequiredTransactionIds = <String>{};
    var verificationUnavailable = false;
    var roundCount = 0;
    var nextCaseIndex = 0;
    final excludedFindingIds = <String>{};
    final reportedBlockedIds = <String>{};
    final committedFindingIds = <String>{};
    final rejectedFindingIds = <String>{};
    final skippedDependencyFindingIds = <String>{};
    final recoveryRequiredFindingIds = <String>{};
    final initialSizeByPath = <String, int>{};
    final applyFailureReasonByTransactionId = <String, String>{};
    final attemptedFindingsById = <String, Finding>{};
    AtomicUnit? activeUnit;
    String? activeTransactionId;
    var currentGraph = snapshot.graph;

    List<Finding> selectedApplicableFindings(List<Finding> findings) {
      _indexUniqueFindings(findings);
      final eligible = _applicableFindings(findings, project: project);
      if (!findingSelection.isExact) return eligible;
      return eligible
          .where((finding) => findingSelection.contains(finding.node.id))
          .toList(growable: false);
    }

    List<Finding> selectedRemainingFindings(List<Finding> findings) {
      final indexed = _indexUniqueFindings(findings);
      if (!findingSelection.isExact) {
        return _applicableFindings(findings, project: project);
      }
      return findingSelection.requestedFindingIds
          .map((findingId) => indexed[findingId])
          .whereType<Finding>()
          .toList(growable: false);
    }

    List<Finding> selectionBoundFindingsForError(List<Finding> findings) {
      if (findingSelection.isExact) {
        return findings
            .where((finding) => findingSelection.contains(finding.node.id))
            .toList(growable: false);
      }
      return _applicableFindings(findings, project: project);
    }

    Iterable<Finding> undispositioned(Iterable<Finding> findings) =>
        findings.where((finding) {
          final id = finding.node.id;
          return !committedFindingIds.contains(id) &&
              !rejectedFindingIds.contains(id) &&
              !reportedBlockedIds.contains(id) &&
              !skippedDependencyFindingIds.contains(id) &&
              !recoveryRequiredFindingIds.contains(id);
        });

    int sourceBytesRemoved() =>
        initialSizeByPath.entries.fold<int>(0, (total, entry) {
          final file = File(entry.key);
          final finalSize = file.existsSync() ? file.lengthSync() : 0;
          final removed = entry.value - finalSize;
          return total + (removed > 0 ? removed : 0);
        });

    ApplyStatistics buildApplyStatistics({required int remaining}) {
      final terminalTransactionIds = <String>{
        ...committedTransactionIds,
        ...rolledBackVerifiedTransactionIds,
        ...recoveryRequiredTransactionIds,
      };
      return ApplyStatistics(
        rounds: roundCount,
        findingsCommitted: committedFindingIds.length,
        findingsRejectedRecovered: rejectedFindingIds.length,
        findingsBlocked: reportedBlockedIds.length,
        findingsSkippedDependency: skippedDependencyFindingIds.length,
        findingsRemaining: remaining,
        actionsDeclared: actionsDeclaredCount,
        actionsCommitted: actionsCommittedCount,
        actionsRolledBack: actionsRolledBackCount,
        actionsFailedRecovered: actionsFailedRecoveredCount,
        transactionsBegun: begunTransactionIds.length,
        transactionsCommitted: committedTransactionIds.length,
        transactionsRolledBackVerified: rolledBackVerifiedTransactionIds.length,
        transactionsRecoveryRequired: recoveryRequiredTransactionIds.length,
        transactionsNonTerminal: begunTransactionIds
            .difference(terminalTransactionIds)
            .length,
        verificationAttempts: verificationAttemptCount,
        sourceBytesRemoved: sourceBytesRemoved(),
      );
    }

    Future<_AppliedFinding?> applyOne(_FindingCase item) async {
      final finding = item.finding;
      workflow.info(
        item.caseId,
        'Applying ${finding.confidence.label} · ${item.effectiveLabel}',
        detail: project.relative(item.file.path),
      );

      final file = item.file;
      var caseStarted = false;
      try {
        final prepared = await quarantineManager.beginDisplacedCase(
          quarantineDir: quarantineDir,
          caseId: item.caseId,
          findingId: item.effectiveFindingId,
          file: file,
          operationType:
              item.operation == _ApplyOperation.deleteFile ||
                  finding.node.kind == NodeKind.asset
              ? QuarantineOperationType.file
              : QuarantineOperationType.declaration,
          declarationIds:
              item.operation == _ApplyOperation.removeFinding &&
                  finding.node.kind == NodeKind.declaration
              ? [finding.node.id]
              : null,
          expectedSha256: expectedSha256ByPath[file.path]!,
          expectedPosixMode: planFileSnapshots[file.path]!.posixMode,
          transactionId: item.transactionId,
        );
        caseStarted = true;
        final candidate = prepared.candidate;

        switch (item.operation) {
          case _ApplyOperation.deleteFile:
            candidate.deleteSync();
          case _ApplyOperation.cleanupImports:
            final cleanupResult = await cleanupRunner
                .removeDirectiveReferencing(
                  candidate.path,
                  item.cleanupTargetPath!,
                );
            if (!cleanupResult.success) {
              throw StateError(
                'Import cleanup failed: ${cleanupResult.stderr}',
              );
            }
          case _ApplyOperation.removeFinding:
            if (finding.node.kind == NodeKind.asset) {
              candidate.deleteSync();
            } else {
              final modifiedContent = await remover.removeDeclarations(
                candidate.path,
                [finding.node.id],
              );
              candidate.writeAsStringSync(modifiedContent, flush: true);

              final cleanupResult = await cleanupRunner.run([candidate.path]);
              if (!cleanupResult.success) {
                throw StateError(
                  'Import cleanup failed: ${cleanupResult.stderr}',
                );
              }

              if (candidate.existsSync() &&
                  lifecycleManager.shouldDelete(
                    file.path,
                    candidate.readAsStringSync(),
                    hasExistingImporters: _hasExistingImporters(
                      currentGraph,
                      finding,
                      project,
                    ),
                  )) {
                workflow.info(
                  'EMPTY FILE',
                  'Deleting ${project.relative(file.path)}',
                );
                candidate.deleteSync();
              }
            }
        }

        final appliedCase = await quarantineManager.recordCaseApplied(
          quarantineDir: quarantineDir,
          caseId: item.caseId,
        );
        expectedSha256ByPath[file.path] = appliedCase.entry.modifiedSha256;
        return _AppliedFinding(
          item: item,
          file: file,
          appliedSha256: appliedCase.entry.modifiedSha256,
        );
      } on ImportCleanupRecoveryRequiredException {
        // A still-live cleanup process may continue mutating this working
        // copy. Do not inspect, journal, verify, or restore bytes until its
        // process tree is independently known to be stopped.
        rethrow;
      } on QuarantineDisplacementRecoveryRequiredException {
        // Source ownership became ambiguous. The promoted backup, candidate,
        // and any recreated source must remain untouched for manual recovery.
        rethrow;
      } catch (error) {
        workflow.failure(
          'APPLY FAILED',
          item.effectiveLabel,
          detail: error.toString(),
        );
        if (item.transactionId != null) {
          applyFailureReasonByTransactionId[item.transactionId!] = error
              .toString();
        }
        if (caseStarted) {
          try {
            await quarantineManager.recordCaseApplied(
              quarantineDir: quarantineDir,
              caseId: item.caseId,
            );
            await quarantineManager.rollbackCase(
              quarantineDir: quarantineDir,
              caseId: item.caseId,
              reason: error.toString(),
              failed: true,
            );
            expectedSha256ByPath[file.path] = _sha256For(file);
          } catch (rollbackError) {
            if (rollbackError
                is QuarantineDisplacementRecoveryRequiredException) {
              rethrow;
            }
            throw StateError('Fatal case rollback failure: $rollbackError');
          }
        }
        failedCount++;
        actionsFailedRecoveredCount++;
        return null;
      }
    }

    Future<void> keepApplied(
      List<_AppliedFinding> applied,
      VerificationResult? candidate,
      String transactionId,
    ) async {
      await quarantineManager.commitTransaction(
        quarantineDir: quarantineDir,
        transactionId: transactionId,
      );
      committedTransactionIds.add(transactionId);
      actionsCommittedCount += applied.length;
      for (final item in applied) {
        expectedSha256ByPath[item.file.path] = item.appliedSha256;
        workflow.success(
          'COMMITTED',
          item.item.caseId,
          detail: item.item.effectiveLabel,
        );
        if (item.item.countsTowardSummary) {
          appliedCount++;
          committedFindingIds.add(item.item.finding.node.id);
          recorder.recordApplyFindingOutcome(
            ApplyFindingOutcome(
              finding: item.item.finding,
              status: ApplyFindingOutcomeStatus.committed,
              reasonCode: 'verification_accepted',
              reason: 'The transaction passed verification and was committed.',
              round: roundCount,
              transactionId: transactionId,
            ),
          );
        }
      }
      if (candidate != null) rollingBaseline = candidate;
    }

    Future<_VerificationAttempt> verifyApplied(
      List<_AppliedFinding> applied,
      String scope,
    ) async {
      if (applied.isEmpty) {
        throw StateError('Cannot verify an empty mutation transaction.');
      }
      progress.start(scope, activity: 'Verifying');
      verificationAttemptCount++;
      late final VerificationResult candidate;
      try {
        candidate = await verifier.verify(policy: verificationPolicy);
      } catch (_) {
        progress.finish(succeeded: false);
        rethrow;
      }
      final comparison = candidate.compareTo(rollingBaseline);
      progress.finish(succeeded: comparison.accepted);
      recorder.addVerificationAttempt(
        _verificationAttemptReport(
          purpose: VerificationAttemptPurpose.candidate,
          result: candidate,
          accepted: comparison.accepted,
          round: roundCount,
          transactionId: applied.first.item.transactionId,
          comparison: comparison,
        ),
      );
      if (comparison.accepted) {
        workflow.success(
          'VERIFIED',
          '$scope accepted',
          detail:
              '${applied.length} '
              '${applied.length == 1 ? 'finding' : 'findings'} checked.',
        );
        return _VerificationAttempt.accepted(candidate);
      }
      final reasons = comparison.unavailable
          ? comparison.infrastructureFailures
          : comparison.newFailures;
      final reason = reasons.join('\n');
      if (comparison.unavailable) {
        workflow.failure('VERIFY', 'Verification unavailable', detail: reason);
      } else {
        workflow.warning(
          'REGRESSION',
          'Candidate verification rejected the transaction',
          detail: reason,
        );
      }
      return _VerificationAttempt.rejected(
        reason: reason,
        unavailable: comparison.unavailable,
      );
    }

    Future<VerificationResult> verifyRestored(
      String scope, {
      String? transactionId,
    }) async {
      progress.start(scope, activity: 'Verifying rollback for');
      verificationAttemptCount++;
      late final VerificationResult restored;
      try {
        restored = await verifier.verify(policy: verificationPolicy);
      } catch (_) {
        progress.finish(succeeded: false);
        rethrow;
      }
      final comparison = restored.compareTo(originalBaseline);
      progress.finish(succeeded: comparison.accepted);
      recorder.addVerificationAttempt(
        _verificationAttemptReport(
          purpose: VerificationAttemptPurpose.rollback,
          result: restored,
          accepted: comparison.accepted,
          round: roundCount,
          transactionId: transactionId,
          comparison: comparison,
        ),
      );
      if (comparison.accepted) {
        workflow.success(
          'RESTORED',
          'Rollback restored the verified baseline',
          detail: scope,
        );
        return restored;
      }
      final reasons = comparison.unavailable
          ? comparison.infrastructureFailures
          : comparison.newFailures;
      throw StateError(
        'Rollback verification failed for $scope: ${reasons.join('\n')}',
      );
    }

    Future<_RunRecoveryResult> recoverWholeRun(
      Object failure, {
      required String reasonCode,
      bool unsafeMutationProcess = false,
    }) async {
      final reason = failure.toString();
      Object? recoveryError;
      try {
        await quarantineManager.markRunRecoveryRequired(
          quarantineDir: quarantineDir,
          reason: reason,
        );
      } catch (error) {
        recoveryError = error;
      }

      VerificationResult? restored;
      if (!unsafeMutationProcess && recoveryError == null) {
        try {
          await quarantineManager.restoreRunBytes(quarantineDir: quarantineDir);
          restored = await verifyRestored('whole apply run');
          await quarantineManager.verifyRunOriginalBytes(
            quarantineDir: quarantineDir,
          );
          await quarantineManager.completeVerifiedFullRollback(
            quarantineDir: quarantineDir,
            reason: reason,
            verificationEvidence: QuarantineVerificationEvidence(
              policyHash: restored.policyHash,
              requiredStepIds: restored.requiredStepIds,
              observedStepIds: restored.steps.map((step) => step.name).toList(),
              workingDirectory: restored.workingDirectory,
              toolchainIdentity: restored.toolchainIdentity,
              available: restored.isAvailable,
              passed: restored.passed,
              comparisonBaseline: restored.toBaselineEvidence(),
            ),
            baselineEquivalent: true,
          );
        } catch (error) {
          recoveryError = error;
        }
      } else if (unsafeMutationProcess && recoveryError == null) {
        recoveryError = failure;
      }

      QuarantineManifest? manifest;
      try {
        manifest = await quarantineManager.readManifest(quarantineDir);
      } catch (error) {
        recoveryError ??= error;
      }
      final transactionByFindingId = <String, QuarantineTransaction>{};
      for (final transaction
          in manifest?.transactions ?? const <QuarantineTransaction>[]) {
        for (final findingId in transaction.findingIds) {
          transactionByFindingId[findingId] = transaction;
        }
      }

      committedTransactionIds.clear();
      committedFindingIds.clear();
      actionsCommittedCount = 0;
      appliedCount = 0;
      final recoveryVerified = recoveryError == null;
      if (recoveryVerified) {
        recoveryRequiredTransactionIds.clear();
        recoveryRequiredFindingIds.clear();
        rolledBackVerifiedTransactionIds
          ..clear()
          ..addAll(
            manifest?.transactions.map((item) => item.transactionId) ??
                const <String>[],
          );
        rejectedFindingIds.addAll(attemptedFindingsById.keys);
        rolledBackCount = attemptedFindingsById.length;
        actionsRolledBackCount = manifest?.cases.length ?? 0;
        recorder.recordApplyFindingOutcomes(
          attemptedFindingsById.values.map((finding) {
            final transaction = transactionByFindingId[finding.node.id];
            return ApplyFindingOutcome(
              finding: finding,
              status: ApplyFindingOutcomeStatus.rejectedRecovered,
              reasonCode: reasonCode,
              reason: reason,
              round: transaction?.round,
              transactionId: transaction?.transactionId,
              rollbackVerified: true,
            );
          }),
        );
        return const _RunRecoveryResult.verified();
      }

      rolledBackVerifiedTransactionIds.clear();
      recoveryRequiredTransactionIds
        ..clear()
        ..addAll(
          manifest?.transactions.map((item) => item.transactionId) ??
              begunTransactionIds,
        );
      rejectedFindingIds.removeAll(attemptedFindingsById.keys);
      recoveryRequiredFindingIds.addAll(attemptedFindingsById.keys);
      final recoveryReason =
          '$reason; recovery could not be proven: $recoveryError';
      recorder.recordApplyFindingOutcomes(
        attemptedFindingsById.values.map((finding) {
          final transaction = transactionByFindingId[finding.node.id];
          return ApplyFindingOutcome(
            finding: finding,
            status: ApplyFindingOutcomeStatus.recoveryRequired,
            reasonCode: unsafeMutationProcess
                ? 'mutation_process_termination_unconfirmed'
                : 'rollback_verification_failed',
            reason: recoveryReason,
            round: transaction?.round,
            transactionId: transaction?.transactionId,
            rollbackVerified: false,
          );
        }),
      );
      return _RunRecoveryResult.required(recoveryReason);
    }

    Future<_UnitOutcome> processAtomicUnit(
      AtomicUnit unit,
      List<_FindingCase> group,
      String transactionId,
    ) async {
      final applied = <_AppliedFinding>[];
      for (final item in group) {
        final result = await applyOne(item);
        if (result == null) {
          return _UnitOutcome.rejected;
        }
        applied.add(result);
      }

      await quarantineManager.recordTransactionApplied(
        quarantineDir: quarantineDir,
        transactionId: transactionId,
        caseIds: group.map((item) => item.caseId).toList(),
      );

      final attempt = await verifyApplied(applied, 'atomic unit ${unit.id}');
      if (attempt.accepted) {
        final candidate = attempt.candidate!;
        await quarantineManager.verifyTransaction(
          quarantineDir: quarantineDir,
          transactionId: transactionId,
          policyHash: candidate.policyHash,
          requiredStepIds: candidate.requiredStepIds,
          observedStepIds: candidate.steps.map((step) => step.name).toList(),
        );
        await keepApplied(applied, attempt.candidate, transactionId);
        return _UnitOutcome.kept;
      }
      if (attempt.unavailable) {
        verificationUnavailable = true;
        return _UnitOutcome.unavailable;
      }
      return _UnitOutcome.rejected;
    }

    try {
      await reportPersistence.prepareMutation(quarantineDir);
      while (plan.units.isNotEmpty) {
        roundCount++;
        workflow.section(
          'ROUND $roundCount',
          detail:
              '${plan.units.length} atomic '
              '${plan.units.length == 1 ? 'transaction' : 'transactions'}',
        );
        recordBlockedOutcomes(plan.blocked, round: roundCount);
        for (final blocked in plan.blocked) {
          if (reportedBlockedIds.add(blocked.finding.node.id)) {
            _printBlocked([blocked], project, workflow);
          }
        }
        var roundProgress = false;
        final unitsById = {for (final unit in plan.units) unit.id: unit};
        final skippedUnitIds = <String>{};
        for (final unit in plan.units) {
          if (skippedUnitIds.contains(unit.id)) continue;
          final transactionId =
              'tx-r${roundCount.toString().padLeft(3, '0')}-'
              '${unit.id.substring('unit:'.length)}';
          final cases = _buildCases(
            actionPlan.actionsFor(unit.id),
            startIndex: nextCaseIndex,
            transactionId: transactionId,
          );
          nextCaseIndex += cases.length;
          for (final item in cases) {
            final expectedSha256 = expectedSha256ByPath[item.file.path];
            final analysisFile = planFileSnapshots[item.file.path];
            if (!expectedSha256ByPath.containsKey(item.file.path) ||
                expectedSha256 == null ||
                analysisFile == null) {
              throw _StaleAnalysisSnapshotException(
                'Action ${item.effectiveLabel} was not bound to the current '
                'analysis snapshot: ${item.file.path}',
              );
            }
            _validateExpectedFileState(
              item.file,
              expectedSha256: expectedSha256,
              expectedCanonicalPath: analysisFile.canonicalPath,
              expectedPosixMode: analysisFile.posixMode,
              project: project,
            );
            initialSizeByPath.putIfAbsent(
              item.file.path,
              () => analysisFile.sizeBytes,
            );
          }
          activeUnit = unit;
          activeTransactionId = transactionId;
          for (final finding in unit.findings) {
            attemptedFindingsById[finding.node.id] = finding;
          }
          await quarantineManager.beginTransaction(
            quarantineDir: quarantineDir,
            transactionId: transactionId,
            round: roundCount,
            componentId: unit.id,
            findingIds: unit.findings
                .map((finding) => finding.node.id)
                .toList(),
            caseIds: cases.map((item) => item.caseId).toList(),
          );
          begunTransactionIds.add(transactionId);
          actionsDeclaredCount += cases.length;

          final outcome = await processAtomicUnit(unit, cases, transactionId);
          activeUnit = null;
          activeTransactionId = null;
          if (outcome == _UnitOutcome.kept) {
            roundProgress = true;
            continue;
          }
          excludedFindingIds.addAll(
            unit.findings.map((finding) => finding.node.id),
          );
          rejectedFindingIds.addAll(
            unit.findings.map((finding) => finding.node.id),
          );
          final descendants = _dependencyClosure(unit, unitsById);
          skippedUnitIds.addAll(descendants);
          for (final descendantId in descendants) {
            final descendant = unitsById[descendantId]!;
            excludedFindingIds.addAll(
              descendant.findings.map((finding) => finding.node.id),
            );
            skippedDependencyFindingIds.addAll(
              descendant.findings.map((finding) => finding.node.id),
            );
            recorder.recordApplyFindingOutcomes(
              descendant.findings.map(
                (finding) => ApplyFindingOutcome(
                  finding: finding,
                  status: ApplyFindingOutcomeStatus.skippedDependency,
                  reasonCode: 'dependency_transaction_rejected',
                  reason:
                      'A dependency transaction was not attempted because '
                      '$transactionId was rejected.',
                  round: roundCount,
                  relatedNodeIds: unit.findings
                      .map((finding) => finding.node.id)
                      .toList(),
                ),
              ),
            );
          }
          throw _ApplyRunAbort(
            reason: outcome == _UnitOutcome.unavailable
                ? 'Verification became unavailable for $transactionId.'
                : 'Atomic transaction $transactionId was rejected.',
            reasonCode: outcome == _UnitOutcome.unavailable
                ? 'verification_unavailable'
                : applyFailureReasonByTransactionId.containsKey(transactionId)
                ? 'apply_failed'
                : 'verification_regression',
            status: outcome == _UnitOutcome.unavailable
                ? RunStatus.infrastructureFailure
                : RunStatus.safeStopped,
            exitCode: outcome == _UnitOutcome.unavailable ? 1 : 2,
          );
        }
        if (verificationUnavailable) break;

        if (!roundProgress) break;
        progress.start(
          'project after round $roundCount',
          activity: 'Rescanning',
        );
        try {
          snapshot = await analyzer.analyze();
        } catch (_) {
          progress.finish(succeeded: false);
          rethrow;
        }
        progress.finish(succeeded: true);
        analysisPassIndex++;
        recorder.addAnalysisPass(
          snapshot.toPassReport(
            id: 'analysis-${analysisPassIndex.toString().padLeft(3, '0')}',
            purpose: AnalysisPassPurpose.rescan,
            round: roundCount,
          ),
        );
        currentGraph = snapshot.graph;
        final nextFindings = selectedApplicableFindings(snapshot.findings)
            .where(
              (finding) =>
                  !excludedFindingIds.contains(finding.node.id) &&
                  !committedFindingIds.contains(finding.node.id),
            );
        plan = planner.build(
          findings: nextFindings.toList(),
          graph: currentGraph,
          project: project,
        );
        actionPlan = _freezeActionPlan(
          plan,
          graph: currentGraph,
          project: project,
        );
        planFileSnapshots = _capturePlanFileSnapshots(
          actionPlan,
          project: project,
        );
        for (final entry in planFileSnapshots.entries) {
          expectedSha256ByPath[entry.key] = entry.value.sha256;
        }
        recordBlockedOutcomes(plan.blocked, round: roundCount);
        if (plan.units.isEmpty) {
          for (final blocked in plan.blocked) {
            if (reportedBlockedIds.add(blocked.finding.node.id)) {
              _printBlocked([blocked], project, workflow);
            }
          }
        }
      }

      if (!verificationUnavailable && appliedCount > 0) {
        progress.start('project convergence', activity: 'Scanning final');
        try {
          snapshot = await analyzer.analyze();
        } catch (_) {
          progress.finish(succeeded: false);
          rethrow;
        }
        progress.finish(succeeded: true);
        analysisPassIndex++;
        recorder.addAnalysisPass(
          snapshot.toPassReport(
            id: 'analysis-${analysisPassIndex.toString().padLeft(3, '0')}',
            purpose: AnalysisPassPurpose.finalScan,
            round: roundCount,
          ),
        );
        _indexUniqueFindings(snapshot.findings);
      }
    } catch (error) {
      final abort = error is _ApplyRunAbort ? error : null;
      final runRecovery = await recoverWholeRun(
        error,
        reasonCode: abort?.reasonCode ?? 'whole_run_internal_error',
        unsafeMutationProcess:
            error is ImportCleanupRecoveryRequiredException ||
            error is ProcessTerminationUnconfirmedException ||
            error is QuarantineDisplacementRecoveryRequiredException,
      );
      if (!runRecovery.verified) {
        workflow.recovery(
          'RECOVERY',
          'Whole-run rollback could not be proven.',
          detail: runRecovery.reason,
        );
      }
      final interruptedUnit = activeUnit;
      final interruptedTransactionId = activeTransactionId;
      var recoveryRequired = recoveryRequiredTransactionIds.isNotEmpty;
      if (interruptedUnit != null && interruptedTransactionId != null) {
        QuarantineTransaction? journalTransaction;
        Object? journalError;
        try {
          final manifest = await quarantineManager.readManifest(quarantineDir);
          for (final transaction in manifest.transactions) {
            if (transaction.transactionId == interruptedTransactionId) {
              journalTransaction = transaction;
              break;
            }
          }
        } catch (manifestError) {
          journalError = manifestError;
        }

        final findingIds = interruptedUnit.findings
            .map((finding) => finding.node.id)
            .toSet();
        final transaction = journalTransaction;
        if (transaction != null) {
          begunTransactionIds.add(interruptedTransactionId);
          switch (transaction.status) {
            case QuarantineTransactionStatus.pending:
            case QuarantineTransactionStatus.applied:
            case QuarantineTransactionStatus.verified:
              try {
                await quarantineManager.requireTransactionRecovery(
                  quarantineDir: quarantineDir,
                  transactionId: interruptedTransactionId,
                  reason: error.toString(),
                );
                recoveryRequiredTransactionIds.add(interruptedTransactionId);
              } catch (recoveryError) {
                journalError = recoveryError;
              }
              recoveryRequired = true;
              recoveryRequiredFindingIds.addAll(findingIds);
              recorder.recordApplyFindingOutcomes(
                interruptedUnit.findings.map(
                  (finding) => ApplyFindingOutcome(
                    finding: finding,
                    status: ApplyFindingOutcomeStatus.recoveryRequired,
                    reasonCode: 'transaction_non_terminal',
                    reason: journalError == null
                        ? error.toString()
                        : '$error; recovery journal error: $journalError',
                    round: transaction.round,
                    transactionId: interruptedTransactionId,
                    rollbackVerified: false,
                  ),
                ),
              );
            case QuarantineTransactionStatus.recoveryRequired:
              recoveryRequired = true;
              recoveryRequiredTransactionIds.add(interruptedTransactionId);
              final newlyRecoveryRequiredFindings = interruptedUnit.findings
                  .where(
                    (finding) =>
                        !recoveryRequiredFindingIds.contains(finding.node.id),
                  )
                  .toList();
              recoveryRequiredFindingIds.addAll(findingIds);
              recorder.recordApplyFindingOutcomes(
                newlyRecoveryRequiredFindings.map(
                  (finding) => ApplyFindingOutcome(
                    finding: finding,
                    status: ApplyFindingOutcomeStatus.recoveryRequired,
                    reasonCode: 'recovery_required',
                    reason: transaction.failureReason ?? error.toString(),
                    round: transaction.round,
                    transactionId: interruptedTransactionId,
                    rollbackVerified: false,
                  ),
                ),
              );
            case QuarantineTransactionStatus.committed:
              if (committedTransactionIds.add(interruptedTransactionId)) {
                actionsCommittedCount += transaction.caseIds.length;
              }
              committedFindingIds.addAll(findingIds);
              recoveryRequiredFindingIds.removeAll(findingIds);
              recorder.recordApplyFindingOutcomes(
                interruptedUnit.findings.map(
                  (finding) => ApplyFindingOutcome(
                    finding: finding,
                    status: ApplyFindingOutcomeStatus.committed,
                    reasonCode: 'journal_committed',
                    reason:
                        'The manifest confirms that the transaction committed.',
                    round: transaction.round,
                    transactionId: interruptedTransactionId,
                  ),
                ),
              );
            case QuarantineTransactionStatus.rolledBackVerified:
              if (rolledBackVerifiedTransactionIds.add(
                interruptedTransactionId,
              )) {
                actionsRolledBackCount += transaction.caseIds.length;
              }
              rejectedFindingIds.addAll(findingIds);
              recoveryRequiredFindingIds.removeAll(findingIds);
              recorder.recordApplyFindingOutcomes(
                interruptedUnit.findings.map(
                  (finding) => ApplyFindingOutcome(
                    finding: finding,
                    status: ApplyFindingOutcomeStatus.rejectedRecovered,
                    reasonCode: 'journal_rolled_back_verified',
                    reason:
                        transaction.failureReason ??
                        'The manifest confirms verified rollback.',
                    round: transaction.round,
                    transactionId: interruptedTransactionId,
                    rollbackVerified: true,
                  ),
                ),
              );
          }
        } else if (journalError != null) {
          recoveryRequired = true;
          recoveryRequiredFindingIds.addAll(findingIds);
          recorder.recordApplyFindingOutcomes(
            interruptedUnit.findings.map(
              (finding) => ApplyFindingOutcome(
                finding: finding,
                status: ApplyFindingOutcomeStatus.recoveryRequired,
                reasonCode: 'recovery_journal_unavailable',
                reason: '$error; recovery journal error: $journalError',
                round: roundCount,
                transactionId: interruptedTransactionId,
                rollbackVerified: false,
              ),
            ),
          );
        }
      }
      final reportRemaining = selectionBoundFindingsForError(snapshot.findings);
      recordRemainingOutcomes(
        undispositioned(reportRemaining),
        reasonCode: 'apply_stopped_internal_error',
        reason: 'Apply stopped before this finding could be attempted: $error',
      );
      final exitCode = recoveryRequired ? 1 : abort?.exitCode ?? 70;
      if (recoveryRequired) {
        workflow.recovery(
          'RECOVERY',
          'The apply transaction requires manual recovery.',
          detail: error.toString(),
        );
      } else if (abort != null) {
        workflow.warning(
          'SAFE STOP',
          'The whole apply run was restored.',
          detail: abort.reason,
        );
      } else {
        workflow.failure(
          'APPLY FAILED',
          'The apply transaction stopped on an internal error.',
          detail: error.toString(),
        );
      }
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: recoveryRequired
              ? RunStatus.recoveryRequired
              : abort?.status ?? RunStatus.internalError,
          exitCode: exitCode,
          findings: snapshot.findings,
          partialApplied: recoveryRequired && initialSizeByPath.isNotEmpty,
          applyStatistics: buildApplyStatistics(
            remaining: reportRemaining
                .map((item) => item.node.id)
                .toSet()
                .length,
          ),
          quarantinePath: quarantineDir.path,
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
        quarantineDir: quarantineDir,
      );
      return exitCode;
    }

    if (verificationUnavailable) {
      final reportRemaining = selectionBoundFindingsForError(snapshot.findings);
      recordRemainingOutcomes(
        undispositioned(reportRemaining),
        reasonCode: 'apply_stopped_verification_unavailable',
        reason:
            'Apply stopped before this finding could be attempted because '
            'verification became unavailable.',
      );
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: RunStatus.infrastructureFailure,
          exitCode: 1,
          findings: snapshot.findings,
          partialApplied: committedFindingIds.isNotEmpty,
          applyStatistics: buildApplyStatistics(
            remaining: reportRemaining
                .map((item) => item.node.id)
                .toSet()
                .length,
          ),
          quarantinePath: quarantineDir.path,
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
        quarantineDir: quarantineDir,
      );
      return 1;
    }

    final remaining = selectedRemainingFindings(snapshot.findings);
    final missingCommitted = findingSelection.isExact
        ? findingSelection.requestedFindingIds.toSet().difference(
            committedFindingIds,
          )
        : const <String>{};
    final unexpectedCommitted = findingSelection.isExact
        ? committedFindingIds.difference(
            findingSelection.requestedFindingIds.toSet(),
          )
        : const <String>{};
    final convergenceFailed =
        remaining.isNotEmpty ||
        missingCommitted.isNotEmpty ||
        unexpectedCommitted.isNotEmpty;
    if (convergenceFailed && begunTransactionIds.isNotEmpty) {
      final details = <String>[
        if (remaining.isNotEmpty)
          '${remaining.length} requested finding(s) remain at some tier',
        if (missingCommitted.isNotEmpty)
          'not committed: ${(missingCommitted.toList()..sort()).join(', ')}',
        if (unexpectedCommitted.isNotEmpty)
          'outside selection: '
              '${(unexpectedCommitted.toList()..sort()).join(', ')}',
      ];
      final abort = _ApplyRunAbort(
        reason: findingSelection.isExact
            ? 'Final exact-selection convergence failed: '
                  '${details.join('; ')}.'
            : 'Final analysis still contained ${remaining.length} actionable '
                  '${remaining.length == 1 ? 'finding' : 'findings'}.',
        reasonCode: 'convergence_remaining',
        status: RunStatus.safeStopped,
        exitCode: 2,
      );
      final recovery = await recoverWholeRun(
        abort,
        reasonCode: abort.reasonCode,
      );
      recordRemainingOutcomes(
        undispositioned(remaining),
        reasonCode: 'convergence_remaining',
        reason: abort.reason,
      );
      final recoveryRequired = !recovery.verified;
      await _writeRunReport(
        recorder.finish(
          project: project,
          status: recoveryRequired
              ? RunStatus.recoveryRequired
              : RunStatus.safeStopped,
          exitCode: recoveryRequired ? 1 : 2,
          findings: snapshot.findings,
          partialApplied: recoveryRequired,
          applyStatistics: buildApplyStatistics(remaining: remaining.length),
          quarantinePath: quarantineDir.path,
        ),
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
        quarantineDir: quarantineDir,
      );
      return recoveryRequired ? 1 : 2;
    }
    recordRemainingOutcomes(
      undispositioned(remaining),
      reasonCode: 'convergence_remaining',
      reason: 'The finding was still applicable after the final scan.',
    );
    if (remaining.isNotEmpty) {
      for (final finding in remaining) {
        workflow.warning(
          'REMAINING',
          '${finding.confidence.label} · '
              '${finding.node.displayName ?? finding.node.id}',
          detail: finding.node.origin.toString(),
        );
      }
    }
    final safelyStopped =
        convergenceFailed || rolledBackCount > 0 || failedCount > 0;
    final exitCode = safelyStopped ? 2 : 0;
    final provisionalReport = recorder.finish(
      project: project,
      status: RunStatus.interrupted,
      exitCode: 1,
      findings: snapshot.findings,
      partialApplied: committedFindingIds.isNotEmpty,
      applyStatistics: buildApplyStatistics(remaining: remaining.length),
      quarantinePath: quarantineDir.path,
    );
    try {
      await _writeRunReport(
        provisionalReport,
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
        quarantineDir: quarantineDir,
        printTerminal: false,
      );
      await quarantineManager.completeApplyRun(quarantineDir: quarantineDir);
      await _lifecycleCompletedHook?.call(quarantineDir);
      final finalReport = recorder.finish(
        project: project,
        status: safelyStopped ? RunStatus.safeStopped : RunStatus.completed,
        exitCode: exitCode,
        findings: snapshot.findings,
        partialApplied: committedFindingIds.isNotEmpty && safelyStopped,
        applyStatistics: buildApplyStatistics(remaining: remaining.length),
        quarantinePath: quarantineDir.path,
      );
      await _writeRunReport(
        finalReport,
        outputIdentity: reportOutput,
        outputFormat: reportFormat,
        quarantineDir: quarantineDir,
      );
    } catch (error) {
      final recovery = await recoverWholeRun(
        error,
        reasonCode: 'canonical_report_write_failed',
      );
      final recoveryRequired = !recovery.verified;
      final recoveryReport = recorder.finish(
        project: project,
        status: recoveryRequired
            ? RunStatus.recoveryRequired
            : RunStatus.internalError,
        exitCode: recoveryRequired ? 1 : 70,
        findings: snapshot.findings,
        partialApplied: recoveryRequired,
        applyStatistics: buildApplyStatistics(remaining: remaining.length),
        quarantinePath: quarantineDir.path,
      );
      try {
        await _writeRunReport(
          recoveryReport,
          outputIdentity: reportOutput,
          outputFormat: reportFormat,
          quarantineDir: quarantineDir,
        );
      } catch (_) {
        _printTerminalSummarySafely(recoveryReport);
      }
      return recoveryRequired ? 1 : 70;
    }
    return exitCode;
  }

  Future<ProjectContext> _loadProjectForApply({
    required ToolWorkspace workspace,
    required Directory quarantineBaseDir,
    required FrozenReportOutputIdentity reportOutput,
    required File configFile,
  }) async {
    final ProjectContext project;
    try {
      project = await ProjectContext.load(
        workspace.projectRoot,
        additionalExcludedPaths: [
          quarantineBaseDir.path,
          ...reportOutput.projectExclusions,
        ],
        configFile: configFile,
      );
    } catch (error) {
      throw _ApplyProjectPreflightException('Error loading project: $error');
    }
    if (project.analysisMode == AnalysisMode.package) {
      throw const _ApplyProjectPreflightException(
        'Error: analysis.mode package is scan-only. Use scan to review '
        'findings, or explicitly choose package-internal after accepting its '
        'external-consumer warning.',
      );
    }
    if (!project.analysisCoverageComplete) {
      throw _ApplyProjectPreflightException(
        'Error: apply requires complete coverage inside the selected mode. '
        'Review ${configFile.path} and declare every target before setting '
        'target_matrix.complete: true.',
      );
    }
    return project;
  }

  void _printVerification(
    VerificationResult result,
    TerminalWorkflow workflow,
  ) {
    for (final step in result.steps) {
      final elapsed = '${step.duration.inSeconds}s';
      if (step.exitCode < 0) {
        workflow.failure(
          'UNAVAILABLE',
          '${step.name} · $elapsed',
          detail: step.stderr,
        );
      } else if (step.passed) {
        workflow.success('VERIFIED', '${step.name} · $elapsed');
      } else {
        workflow.warning('BASELINE', '${step.name} failed · $elapsed');
      }
    }
  }

  void _printPackageInternalWarning(ProjectContext project) {
    stderr.writeln(packageInternalWarning(project.packageName));
  }

  VerificationAttemptReport _verificationAttemptReport({
    required VerificationAttemptPurpose purpose,
    required VerificationResult result,
    required bool accepted,
    int? round,
    String? transactionId,
    VerificationComparison? comparison,
  }) => VerificationAttemptReport(
    purpose: purpose,
    round: round,
    transactionId: transactionId,
    complete: result.isComplete,
    available: result.isAvailable,
    accepted: accepted,
    policyHash: result.policyHash,
    requiredStepIds: result.requiredStepIds,
    observedStepIds: result.steps.map((step) => step.name).toList(),
    workingDirectory: result.workingDirectory,
    toolchainIdentity: result.toolchainIdentity,
    steps: result.steps
        .map(
          (step) => VerificationStepReport(
            id: step.name,
            passed: step.passed,
            available: step.exitCode >= 0,
            exitCode: step.exitCode,
            elapsedMicros: step.duration.inMicroseconds,
          ),
        )
        .toList(),
    newFailureCount: comparison?.newFailures.length ?? 0,
    infrastructureFailureCount:
        comparison?.infrastructureFailures.length ??
        (result.isAvailable ? 0 : 1),
  );

  List<_FindingCase> _buildCases(
    List<FindingActionDescriptor> descriptors, {
    required int startIndex,
    required String transactionId,
  }) => [
    for (var offset = 0; offset < descriptors.length; offset++)
      _FindingCase.fromDescriptor(
        index: startIndex + offset,
        descriptor: descriptors[offset],
        transactionId: transactionId,
      ),
  ];

  _FrozenActionPlan _freezeActionPlan(
    RemovalPlan plan, {
    required ReachabilityGraph graph,
    required ProjectContext project,
  }) {
    final rawActionsByUnitId = <String, List<FindingActionDescriptor>>{};
    for (final unit in plan.units) {
      if (rawActionsByUnitId.containsKey(unit.id)) {
        throw StateError('Removal plan repeated atomic unit ID ${unit.id}.');
      }
      rawActionsByUnitId[unit.id] = const FindingActionBuilder().build(
        findings: unit.findings,
        graph: graph,
        project: project,
        atomicGroup: unit.id,
      );
    }
    // Consumer-first library units can delete an importer before a dependency
    // unit runs. Bind that redundancy now; never rediscover it from existsSync
    // while executing the later unit.
    final wholeFileRemovalOrder = <String, int>{};
    for (var unitIndex = 0; unitIndex < plan.units.length; unitIndex++) {
      for (final action in rawActionsByUnitId[plan.units[unitIndex].id]!) {
        if (action.countsTowardSummary &&
            action.operation == FindingActionOperation.deleteFile) {
          wholeFileRemovalOrder[p.normalize(p.absolute(action.file.path))] =
              unitIndex;
        }
      }
    }
    final actionsByUnitId = {
      for (var unitIndex = 0; unitIndex < plan.units.length; unitIndex++)
        plan.units[unitIndex].id: rawActionsByUnitId[plan.units[unitIndex].id]!
            .where((action) {
              if (action.operation != FindingActionOperation.cleanupImports) {
                return true;
              }
              final removalOrder =
                  wholeFileRemovalOrder[p.normalize(
                    p.absolute(action.file.path),
                  )];
              return removalOrder == null || removalOrder > unitIndex;
            })
            .toList(growable: false),
    };
    return _FrozenActionPlan(actionsByUnitId);
  }

  String? _sha256For(File file) {
    if (!file.existsSync()) return null;
    return sha256.convert(file.readAsBytesSync()).toString();
  }

  Map<String, _AnalysisFileSnapshot> _capturePlanFileSnapshots(
    _FrozenActionPlan actionPlan, {
    required ProjectContext project,
  }) {
    final snapshots = <String, _AnalysisFileSnapshot>{};
    for (final actions in actionPlan.actionsByUnitId.values) {
      for (final action in actions) {
        snapshots.putIfAbsent(
          action.file.path,
          () => _captureAnalysisFileSnapshot(action.file, project: project),
        );
      }
    }
    return snapshots;
  }

  _AnalysisFileSnapshot _captureAnalysisFileSnapshot(
    File file, {
    required ProjectContext project,
  }) {
    final canonicalPath = _validateRegularProjectFile(file, project: project);
    final posixMode = _readPosixMode(file);
    final bytes = file.readAsBytesSync();
    final sha = sha256.convert(bytes).toString();
    final afterCanonical = _validateRegularProjectFile(file, project: project);
    if (canonicalPath != afterCanonical ||
        _readPosixMode(file) != posixMode ||
        sha256.convert(file.readAsBytesSync()).toString() != sha) {
      throw _StaleAnalysisSnapshotException(
        'Planned file changed while the analysis snapshot was captured: '
        '${file.path}',
      );
    }
    return _AnalysisFileSnapshot(
      sha256: sha,
      canonicalPath: canonicalPath,
      sizeBytes: bytes.length,
      posixMode: posixMode,
    );
  }

  void _validatePlanFileSnapshots(
    Map<String, _AnalysisFileSnapshot> snapshots, {
    required ProjectContext project,
  }) {
    for (final entry in snapshots.entries) {
      _validateExpectedFileState(
        File(entry.key),
        expectedSha256: entry.value.sha256,
        expectedCanonicalPath: entry.value.canonicalPath,
        expectedPosixMode: entry.value.posixMode,
        project: project,
      );
    }
  }

  void _validateExpectedFileState(
    File file, {
    required String expectedSha256,
    required String expectedCanonicalPath,
    required int? expectedPosixMode,
    required ProjectContext project,
  }) {
    final canonicalPath = _validateRegularProjectFile(file, project: project);
    final actualSha256 = sha256.convert(file.readAsBytesSync()).toString();
    final actualPosixMode = _readPosixMode(file);
    if (canonicalPath != expectedCanonicalPath ||
        actualSha256 != expectedSha256 ||
        actualPosixMode != expectedPosixMode) {
      throw _StaleAnalysisSnapshotException(
        'File changed since the analysis snapshot: ${file.path}\n'
        'Expected SHA-256: $expectedSha256\n'
        'Actual SHA-256: $actualSha256\n'
        'Expected POSIX mode: ${_formatPosixMode(expectedPosixMode)}\n'
        'Actual POSIX mode: ${_formatPosixMode(actualPosixMode)}',
      );
    }
  }

  int? _readPosixMode(File file) => Platform.isLinux || Platform.isMacOS
      ? file.statSync().mode & 0xfff
      : null;

  String _formatPosixMode(int? mode) =>
      mode == null ? 'not-recorded' : mode.toRadixString(8).padLeft(4, '0');

  String _validateRegularProjectFile(
    File file, {
    required ProjectContext project,
  }) {
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      throw _StaleAnalysisSnapshotException(
        'Planned file no longer exists: ${file.path}',
      );
    }
    if (type != FileSystemEntityType.file) {
      throw _StaleAnalysisSnapshotException(
        'Planned path is no longer a regular file: ${file.path}',
      );
    }
    final canonicalRoot = p.normalize(project.root.resolveSymbolicLinksSync());
    final canonicalPath = p.normalize(file.resolveSymbolicLinksSync());
    if (!p.equals(canonicalRoot, canonicalPath) &&
        !p.isWithin(canonicalRoot, canonicalPath)) {
      throw _StaleAnalysisSnapshotException(
        'Planned file resolves outside the project root: ${file.path}',
      );
    }
    return canonicalPath;
  }

  Map<String, Finding> _indexUniqueFindings(List<Finding> findings) {
    final indexed = <String, Finding>{};
    for (final finding in findings) {
      final findingId = finding.node.id;
      if (findingId.isEmpty) {
        throw const _FindingSelectionIntegrityException(
          'Analysis emitted an empty finding ID.',
        );
      }
      if (indexed.containsKey(findingId)) {
        throw _FindingSelectionIntegrityException(
          'Analysis emitted duplicate finding ID: $findingId.',
        );
      }
      indexed[findingId] = finding;
    }
    return indexed;
  }

  String _planFingerprint(
    RemovalPlan plan, {
    required _FrozenActionPlan actionPlan,
    required ProjectContext project,
    required FindingSelection selection,
  }) {
    String relativePath(String path) =>
        project.relative(p.normalize(p.absolute(path))).replaceAll('\\', '/');

    final units = <Map<String, Object?>>[];
    for (var unitIndex = 0; unitIndex < plan.units.length; unitIndex++) {
      final unit = plan.units[unitIndex];
      final findingIds =
          unit.findings.map((finding) => finding.node.id).toList()..sort();
      final dependencies = unit.dependencyUnitIds.toList()..sort();
      final actions = actionPlan.actionsFor(unit.id);
      units.add({
        'order': unitIndex,
        'id': unit.id,
        'findingIds': findingIds,
        'dependencyUnitIds': dependencies,
        'actions': [
          for (var actionIndex = 0; actionIndex < actions.length; actionIndex++)
            {
              'order': actionIndex,
              'logicalFindingId': actions[actionIndex].finding.node.id,
              'journalFindingId':
                  actions[actionIndex].findingId ??
                  actions[actionIndex].finding.node.id,
              'operation': actions[actionIndex].operation.name,
              'path': relativePath(actions[actionIndex].file.path),
              'countsTowardSummary': actions[actionIndex].countsTowardSummary,
              if (actions[actionIndex].cleanupTargetPath != null)
                'cleanupTargetPath': relativePath(
                  actions[actionIndex].cleanupTargetPath!,
                ),
            },
        ],
      });
    }
    final blocked =
        plan.blocked
            .map(
              (item) => {
                'findingId': item.finding.node.id,
                'reason': item.reason.name,
                'blockedBy': item.blockedBy,
              },
            )
            .toList()
          ..sort(
            (left, right) => (left['findingId'] as String).compareTo(
              right['findingId'] as String,
            ),
          );
    final payload = <String, Object?>{
      'version': 1,
      'selectionMode': selection.mode.name,
      'requestedFindingIds': selection.requestedFindingIds,
      'units': units,
      'blocked': blocked,
    };
    return sha256.convert(utf8.encode(jsonEncode(payload))).toString();
  }

  List<Finding> _applicableFindings(
    List<Finding> findings, {
    required ProjectContext project,
  }) => findings.where((finding) {
    if (finding.node.kind != NodeKind.asset &&
        finding.node.kind != NodeKind.declaration &&
        finding.node.kind != NodeKind.dartLibrary) {
      return false;
    }
    return ModeApplyPolicy.allows(project.analysisMode, finding);
  }).toList();

  ApplyStatistics _preMutationApplyStatistics({
    required int findingsRemaining,
  }) => ApplyStatistics(
    rounds: 0,
    findingsCommitted: 0,
    findingsRejectedRecovered: 0,
    findingsBlocked: 0,
    findingsSkippedDependency: 0,
    findingsRemaining: findingsRemaining,
    actionsDeclared: 0,
    actionsCommitted: 0,
    actionsRolledBack: 0,
    actionsFailedRecovered: 0,
    transactionsBegun: 0,
    transactionsCommitted: 0,
    transactionsRolledBackVerified: 0,
    transactionsRecoveryRequired: 0,
    transactionsNonTerminal: 0,
    verificationAttempts: 0,
    sourceBytesRemoved: 0,
  );

  Set<String> _dependencyClosure(
    AtomicUnit unit,
    Map<String, AtomicUnit> unitsById,
  ) {
    final result = <String>{};
    final pending = [...unit.dependencyUnitIds];
    while (pending.isNotEmpty) {
      final current = pending.removeLast();
      if (!result.add(current)) continue;
      pending.addAll(unitsById[current]?.dependencyUnitIds ?? const []);
    }
    return result;
  }

  void _printPlannedFindings(
    Iterable<Finding> findings,
    ProjectContext project,
    TerminalWorkflow workflow,
  ) {
    for (final finding in findings) {
      final label = finding.title;
      final path = finding.node.origin.scheme == 'file'
          ? project.relative(finding.node.origin.toFilePath())
          : finding.node.origin.toString();
      if (finding.confidence == Confidence.safe) {
        workflow.info('SAFE', label, detail: path);
      } else {
        workflow.warning(finding.confidence.label, label, detail: path);
      }
    }
  }

  void _printBlocked(
    Iterable<BlockedFinding> blocked,
    ProjectContext project,
    TerminalWorkflow workflow,
  ) {
    for (final item in blocked) {
      final label = item.finding.node.origin.scheme == 'file'
          ? project.relative(item.finding.node.origin.toFilePath())
          : item.finding.node.displayName ?? item.finding.node.id;
      final reason = switch (item.reason) {
        PlanBlockReason.retainedConsumer => 'still has a retained consumer',
        PlanBlockReason.blockedByRetainedDependency =>
          'depends on another retained finding',
      };
      workflow.warning(
        'BLOCKED',
        label,
        detail: '$reason · Retained by: ${item.blockedBy}',
      );
    }
  }

  bool _hasExistingImporters(
    ReachabilityGraph graph,
    Finding finding,
    ProjectContext project,
  ) {
    final separator = finding.node.id.lastIndexOf('#');
    if (separator < 0) return false;
    final libraryId = finding.node.id.substring(0, separator);

    for (final edge in graph.incomingTo(libraryId)) {
      if (edge.kind != EdgeKind.imports) continue;
      final importer = graph.node(edge.from);
      final importerFile = FindingActionBuilder.projectFileForLibrary(
        importer,
        edge.from,
        project,
      );
      if (importerFile == null) continue;
      if (importerFile.existsSync()) return true;
    }
    return false;
  }

  Future<void> _writeRunReport(
    RunReport report, {
    FrozenReportOutputIdentity? outputIdentity,
    _ReportOutputFormat outputFormat = _ReportOutputFormat.json,
    Directory? quarantineDir,
    bool printTerminal = true,
  }) async {
    final persistence = _activeReportPersistence;
    if (persistence == null || outputIdentity == null) {
      throw StateError('Apply report persistence was not prepared.');
    }

    CommittedReport committed;
    var terminalReport = report;
    var terminalFormat = outputFormat;
    try {
      committed = await persistence.write(
        report,
        outputFormat: outputFormat,
        mutation: quarantineDir != null,
        publishExternal: printTerminal,
      );
    } on Object catch (error, stackTrace) {
      if (quarantineDir == null || !printTerminal) {
        if (quarantineDir != null) {
          _printCanonicalReportFailureSafely(quarantineDir.path, error);
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
      terminalReport = switch (error) {
        ImmutableReportStoreException(failedRole: 'export') =>
          _withExternalReportFailure(
            report,
            outputFormat: outputFormat,
            outputPath: outputIdentity.requestedPath,
            error: error,
          ),
        _ => _withReportBatchFailure(report, error: error),
      };
      terminalFormat = _ReportOutputFormat.json;
      try {
        committed = await persistence.write(
          terminalReport,
          outputFormat: _ReportOutputFormat.json,
          mutation: true,
          publishExternal: false,
        );
      } on Object catch (canonicalError, canonicalStackTrace) {
        _printCanonicalReportFailureSafely(quarantineDir.path, canonicalError);
        Error.throwWithStackTrace(canonicalError, canonicalStackTrace);
      }
    }

    if (!printTerminal) return;
    await persistence.close();
    final terminalPath =
        committed.actualObjectPaths['export'] ??
        committed.actualObjectPaths['primary'] ??
        committed.actualObjectPaths['canonical']!;
    try {
      _printTerminalReport(
        terminalReport,
        reportPath: terminalPath,
        reportFormat: terminalFormat,
      );
    } on Object {
      _printTerminalSummarySafely(terminalReport);
    }
  }

  void _printCanonicalReportFailureSafely(String path, Object error) {
    try {
      TerminalWorkflow(
        sink: stderr,
        lineWidth: _terminalLineWidth(stderr),
      ).failure(
        'REPORT NOT SAVED',
        'The canonical run report could not be persisted.',
        detail: '$path · $error',
      );
    } catch (_) {
      // Keep the original persistence exception authoritative.
    }
  }

  void _printTerminalSummarySafely(RunReport report) {
    try {
      stdout.writeln(
        HumanFormatter(
          verbose: globalResults?.flag('verbose') ?? false,
          lineWidth: _humanLineWidth(),
        ).format(report),
      );
    } catch (_) {
      // Preserve the report persistence exception and its established exit
      // semantics even if the best-effort terminal fallback is unavailable.
    }
  }

  void _printTerminalReport(
    RunReport report, {
    required String reportPath,
    required _ReportOutputFormat reportFormat,
  }) {
    stdout.writeln(
      HumanFormatter(
        verbose: globalResults?.flag('verbose') ?? false,
        lineWidth: _humanLineWidth(),
        reportPath: reportPath,
        reportFormat: reportFormat.name,
      ).format(report),
    );
  }

  int _humanLineWidth() {
    return _terminalLineWidth(stdout);
  }

  int _terminalLineWidth(Stdout output) {
    if (!output.hasTerminal) return 160;
    try {
      return output.terminalColumns;
    } on StdoutException {
      return 160;
    }
  }

  RunReport _withExternalReportFailure(
    RunReport report, {
    required _ReportOutputFormat outputFormat,
    required String outputPath,
    required Object error,
  }) => _withAdditionalDiagnostic(
    report,
    RunDiagnostic(
      code: 'external_report_export_failed',
      message:
          'Failed to export the requested ${outputFormat.name.toUpperCase()} '
          'report to $outputPath: $error',
      phase: 'reportExport',
    ),
  );

  RunReport _withReportBatchFailure(
    RunReport report, {
    required Object error,
  }) => _withAdditionalDiagnostic(
    report,
    RunDiagnostic(
      code: 'report_batch_persistence_failed',
      message:
          'The terminal canonical/export report batch was not committed: '
          '$error',
      phase: 'reportPersistence',
    ),
  );

  RunReport _withAdditionalDiagnostic(
    RunReport report,
    RunDiagnostic diagnostic,
  ) => RunReport(
    identity: report.identity,
    status: report.status,
    exitCode: report.exitCode,
    partialApplied: report.partialApplied,
    projectRoot: report.projectRoot,
    packageName: report.packageName,
    analysisMode: report.analysisMode,
    requestedAdapters: report.requestedAdapters,
    targetMatrix: report.targetMatrix,
    rootCoverage: report.rootCoverage,
    analysisPasses: report.analysisPasses,
    findings: report.findings,
    diagnostics: List.unmodifiable([...report.diagnostics, diagnostic]),
    verificationAttempts: report.verificationAttempts,
    applyFindingOutcomes: report.applyFindingOutcomes,
    applySelection: report.applySelection,
    applyStatistics: report.applyStatistics,
    quarantinePath: report.quarantinePath,
    acceptedRiskCodes: report.acceptedRiskCodes,
    riskAcceptanceSource: report.riskAcceptanceSource,
  );
}

final class _ApplyReportPersistence {
  _ApplyReportPersistence({
    required this.runId,
    required this.backend,
    required this.externalOutput,
  });

  final String runId;
  final ReportObjectBackend backend;
  final PreparedReportOutput externalOutput;

  ImmutableReportStore? _mutationStore;
  var _sequence = 0;
  var _externalAttempted = false;
  var _closed = false;

  Future<void> prepareMutation(Directory quarantineDirectory) async {
    if (_closed) throw StateError('Apply report persistence is closed.');
    if (_mutationStore != null) return;
    final reportRoot = Directory(p.join(quarantineDirectory.path, 'reports'));
    final objectsDirectory = Directory(p.join(reportRoot.path, 'objects'));
    final commitsDirectory = Directory(p.join(reportRoot.path, 'commits'));
    await objectsDirectory.create(recursive: true);
    await commitsDirectory.create(recursive: true);
    final objects = await backend.anchor(objectsDirectory);
    AnchoredReportDirectory? commits;
    try {
      commits = await backend.anchor(commitsDirectory);
      _mutationStore = ImmutableReportStore(
        objectsDirectory: objects,
        commitsDirectory: commits,
      );
    } on Object {
      if (commits != null) await commits.close();
      await objects.close();
      rethrow;
    }
  }

  Future<CommittedReport> write(
    RunReport report, {
    required _ReportOutputFormat outputFormat,
    required bool mutation,
    required bool publishExternal,
  }) async {
    if (_closed) throw StateError('Apply report persistence is closed.');
    final sequence = ++_sequence;
    final identity = _reportCommitIdentity(
      runId,
      sequence,
      completedAtUtc: report.identity.finishedAtUtc,
    );

    if (!mutation) {
      _externalAttempted = true;
      return externalOutput.writeBatch(
        identity: identity,
        objects: [
          ReportObjectWrite(
            role: 'primary',
            format: outputFormat.name,
            reportSchemaVersion: 3,
            writeTo: (sink) => _writeFormattedReport(
              report,
              outputFormat: outputFormat,
              sink: sink,
            ),
          ),
        ],
      );
    }

    final mutationStore = _mutationStore;
    if (mutationStore == null) {
      throw StateError('Mutation report persistence was not prepared.');
    }
    final canonicalLeaf =
        'run-report-${sequence.toString().padLeft(6, '0')}.json';
    final canonicalWrite = ReportObjectWrite(
      role: 'canonical',
      format: 'json',
      reportSchemaVersion: 3,
      writeTo: (sink) => const JsonFormatter().writeTo(report, sink),
    );

    if (!publishExternal || _externalAttempted) {
      return mutationStore.writeBatch(
        identity: identity,
        objects: [canonicalWrite],
        objectLeafOverrides: {'canonical': canonicalLeaf},
        recordPathOverrides: {'canonical': 'quarantine/$canonicalLeaf'},
      );
    }

    _externalAttempted = true;
    final externalLeaf = externalOutput.objectLeafOverrides['primary'];
    final adjacentCommitLeaf = externalOutput.commitLeafOverride;
    if (externalLeaf == null || adjacentCommitLeaf == null) {
      throw StateError('External apply output is not an exact-path profile.');
    }
    return externalOutput.store.writeBatch(
      identity: identity,
      objects: [
        canonicalWrite,
        ReportObjectWrite(
          role: 'export',
          format: outputFormat.name,
          reportSchemaVersion: 3,
          writeTo: (sink) => _writeFormattedReport(
            report,
            outputFormat: outputFormat,
            sink: sink,
          ),
        ),
      ],
      objectDirectoryOverrides: {'canonical': mutationStore.objectsDirectory},
      objectLeafOverrides: {'canonical': canonicalLeaf, 'export': externalLeaf},
      recordPathOverrides: {
        'canonical': 'quarantine/$canonicalLeaf',
        'export': 'external/$externalLeaf',
      },
      commitLeafOverride: adjacentCommitLeaf,
    );
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? firstError;
    StackTrace? firstStackTrace;
    final mutationStore = _mutationStore;
    if (mutationStore != null) {
      try {
        await mutationStore.close();
      } on Object catch (error, stackTrace) {
        firstError = error;
        firstStackTrace = stackTrace;
      }
    }
    try {
      await externalOutput.close();
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }
}

ReportCommitIdentity _reportCommitIdentity(
  String runId,
  int sequence, {
  DateTime? completedAtUtc,
}) => ReportCommitIdentity(
  runId: runId,
  sequence: sequence,
  command: 'apply',
  completedAtUtc: canonicalReportTimestamp(completedAtUtc ?? DateTime.now()),
);

void _writeFormattedReport(
  RunReport report, {
  required _ReportOutputFormat outputFormat,
  required StringSink sink,
}) {
  switch (outputFormat) {
    case _ReportOutputFormat.json:
      const JsonFormatter().writeTo(report, sink);
    case _ReportOutputFormat.html:
      const HtmlFormatter().writeTo(report, sink);
  }
}

class _FrozenActionPlan {
  _FrozenActionPlan(Map<String, List<FindingActionDescriptor>> actionsByUnitId)
    : actionsByUnitId = Map.unmodifiable({
        for (final entry in actionsByUnitId.entries)
          entry.key: List<FindingActionDescriptor>.unmodifiable(entry.value),
      });

  final Map<String, List<FindingActionDescriptor>> actionsByUnitId;

  List<FindingActionDescriptor> actionsFor(String unitId) {
    final actions = actionsByUnitId[unitId];
    if (actions == null) {
      throw StateError('Frozen action plan has no atomic unit $unitId.');
    }
    return actions;
  }
}

class _FindingCase {
  const _FindingCase({
    required this.index,
    required this.finding,
    required this.file,
    required this.operation,
    this.atomicGroup,
    this.transactionId,
    this.label,
    this.findingId,
    this.countsTowardSummary = true,
    this.cleanupTargetPath,
  });

  factory _FindingCase.fromDescriptor({
    required int index,
    required FindingActionDescriptor descriptor,
    required String transactionId,
  }) => _FindingCase(
    index: index,
    finding: descriptor.finding,
    file: descriptor.file,
    operation: switch (descriptor.operation) {
      FindingActionOperation.removeFinding => _ApplyOperation.removeFinding,
      FindingActionOperation.cleanupImports => _ApplyOperation.cleanupImports,
      FindingActionOperation.deleteFile => _ApplyOperation.deleteFile,
    },
    atomicGroup: descriptor.atomicGroup,
    transactionId: transactionId,
    label: descriptor.label,
    findingId: descriptor.findingId,
    countsTowardSummary: descriptor.countsTowardSummary,
    cleanupTargetPath: descriptor.cleanupTargetPath,
  );

  final int index;
  final Finding finding;
  final File file;
  final _ApplyOperation operation;
  final String? atomicGroup;
  final String? transactionId;
  final String? label;
  final String? findingId;
  final bool countsTowardSummary;
  final String? cleanupTargetPath;

  String get caseId => 'case-${(index + 1).toString().padLeft(4, '0')}';

  String get effectiveLabel =>
      label ?? finding.node.displayName ?? finding.node.id;

  String get effectiveFindingId => findingId ?? finding.node.id;
}

enum _ApplyOperation { removeFinding, cleanupImports, deleteFile }

enum _ReportOutputFormat { json, html }

enum _UnitOutcome { kept, rejected, unavailable }

class _ApplyRunAbort implements Exception {
  const _ApplyRunAbort({
    required this.reason,
    required this.reasonCode,
    required this.status,
    required this.exitCode,
  });

  final String reason;
  final String reasonCode;
  final RunStatus status;
  final int exitCode;

  @override
  String toString() => reason;
}

class _RunRecoveryResult {
  const _RunRecoveryResult.verified() : verified = true, reason = null;

  const _RunRecoveryResult.required(this.reason) : verified = false;

  final bool verified;
  final String? reason;
}

class _AnalysisFileSnapshot {
  const _AnalysisFileSnapshot({
    required this.sha256,
    required this.canonicalPath,
    required this.sizeBytes,
    required this.posixMode,
  });

  final String sha256;
  final String canonicalPath;
  final int sizeBytes;
  final int? posixMode;
}

class _StaleAnalysisSnapshotException implements Exception {
  const _StaleAnalysisSnapshotException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _FindingSelectionIntegrityException implements Exception {
  const _FindingSelectionIntegrityException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _ApplyProjectPreflightException implements Exception {
  const _ApplyProjectPreflightException(this.message);

  final String message;
}

class _AppliedFinding {
  const _AppliedFinding({
    required this.item,
    required this.file,
    required this.appliedSha256,
  });

  final _FindingCase item;
  final File file;
  final String? appliedSha256;
}

class _VerificationAttempt {
  const _VerificationAttempt._({
    required this.accepted,
    required this.unavailable,
    required this.reason,
    this.candidate,
  });

  factory _VerificationAttempt.accepted(VerificationResult candidate) =>
      _VerificationAttempt._(
        accepted: true,
        unavailable: false,
        reason: '',
        candidate: candidate,
      );

  factory _VerificationAttempt.rejected({
    required String reason,
    required bool unavailable,
  }) => _VerificationAttempt._(
    accepted: false,
    unavailable: unavailable,
    reason: reason,
  );

  final bool accepted;
  final bool unavailable;
  final String reason;
  final VerificationResult? candidate;
}
