import '../adapters/adapter_report_definition.dart';
import '../core/confidence/finding.dart';
import '../core/project/project_context.dart';
import 'reportable_command_failure.dart';
import 'run_clock.dart';
import 'run_id_generator.dart';
import 'run_report.dart';

/// Mutable lifecycle accumulator that finalizes into one immutable report.
class RunRecorder {
  /// Starts a run recorder.
  RunRecorder({
    required this.command,
    required this.requestedAdapters,
    required this.toolVersion,
    RunClock? clock,
    RunIdGenerator? idGenerator,
  }) : _clock = clock ?? SystemRunClock(),
       _idGenerator = idGenerator ?? SecureRunIdGenerator() {
    _startedAtUtc = _clock.nowUtc();
    _startedMicros = _clock.monotonicMicros();
    runId = _idGenerator.next(_startedAtUtc);
  }

  /// Command whose lifecycle is being recorded.
  final RunCommand command;

  /// Adapter IDs explicitly requested by the user, or every reporting adapter.
  final List<String> requestedAdapters;

  /// Flutter Pruner package version recorded in the report.
  final String toolVersion;
  final RunClock _clock;
  final RunIdGenerator _idGenerator;
  late final DateTime _startedAtUtc;
  late final int _startedMicros;

  /// Identifier shared by the report and apply quarantine.
  late final String runId;
  final List<AnalysisPassReport> _analysisPasses = [];
  final List<RunDiagnostic> _diagnostics = [];
  final List<VerificationAttemptReport> _verificationAttempts = [];
  final Map<String, ApplyFindingOutcome> _applyFindingOutcomes = {};
  final Map<String, AdapterReportDefinition> _adapterReportDefinitions = {};
  ApplySelectionReport? _applySelection;
  ApplyInitialPlanReport? _applyInitialPlan;
  List<String> _acceptedRiskCodes = const [];
  RiskAcceptanceSource _riskAcceptanceSource = RiskAcceptanceSource.notRequired;

  /// Records the explicit authorization used for allowlisted manual risks.
  void recordRiskAcceptance({
    required Iterable<String> riskCodes,
    required RiskAcceptanceSource source,
  }) {
    _acceptedRiskCodes = List.unmodifiable(riskCodes.toSet().toList()..sort());
    _riskAcceptanceSource = source;
  }

  /// Records or replaces the current immutable apply selection evidence.
  void recordApplySelection(ApplySelectionReport selection) {
    if (command != RunCommand.apply) {
      throw StateError('Finding selection evidence belongs only to apply.');
    }
    _applySelection = selection;
  }

  /// Records the immutable initial physical plan exactly once.
  ///
  /// Re-recording structurally equal evidence is idempotent. Any drift is a
  /// lifecycle error because formatters and authorization must share one plan.
  void recordApplyInitialPlan(ApplyInitialPlanReport initialPlan) {
    if (command != RunCommand.apply) {
      throw StateError('Initial physical plans belong only to apply.');
    }
    final recorded = _applyInitialPlan;
    if (recorded != null && recorded != initialPlan) {
      throw StateError('Initial physical plan changed during the run.');
    }
    _applyInitialPlan ??= initialPlan;
  }

  /// Registers the immutable presentation catalog used by every report pass.
  void registerAdapterReportDefinitions(
    Iterable<AdapterReportDefinition> definitions,
  ) {
    final incoming = <String, AdapterReportDefinition>{};
    for (final definition in definitions) {
      definition.validate();
      if (incoming.containsKey(definition.adapterId)) {
        throw StateError(
          'Duplicate adapter report definition: ${definition.adapterId}',
        );
      }
      incoming[definition.adapterId] = definition.snapshot();
    }
    if (_adapterReportDefinitions.isNotEmpty &&
        !_sameDefinitions(_adapterReportDefinitions, incoming)) {
      throw StateError('Adapter report definitions changed during the run.');
    }
    _adapterReportDefinitions
      ..clear()
      ..addAll(incoming);
  }

  /// Records a completed analysis pass.
  void addAnalysisPass(AnalysisPassReport pass) => _analysisPasses.add(pass);

  /// Records a sanitized diagnostic.
  void addDiagnostic(RunDiagnostic diagnostic) => _diagnostics.add(diagnostic);

  /// Records one baseline, candidate, or rollback verification attempt.
  void addVerificationAttempt(VerificationAttemptReport attempt) =>
      _verificationAttempts.add(attempt);

  /// Records or replaces the latest truthful disposition for one finding.
  void recordApplyFindingOutcome(ApplyFindingOutcome outcome) {
    outcome.validate();
    _applyFindingOutcomes[outcome.findingId] = outcome;
  }

  /// Records the latest dispositions for several findings.
  void recordApplyFindingOutcomes(Iterable<ApplyFindingOutcome> outcomes) {
    for (final outcome in outcomes) {
      recordApplyFindingOutcome(outcome);
    }
  }

  /// Finalizes the immutable report.
  RunReport finish({
    required ProjectContext project,
    required RunStatus status,
    required int exitCode,
    required List<Finding> findings,
    bool partialApplied = false,
    ApplyStatistics? applyStatistics,
    String? quarantinePath,
  }) {
    final finishedAt = _clock.nowUtc();
    final elapsed = _clock.monotonicMicros() - _startedMicros;
    final canonicalProjectRoot = _applyInitialPlan?.preview == null
        ? null
        : project.root.resolveSymbolicLinksSync();
    return RunReport(
      identity: RunIdentity(
        id: runId,
        command: command,
        toolVersion: toolVersion,
        startedAtUtc: _startedAtUtc,
        finishedAtUtc: finishedAt,
        elapsedMicros: elapsed < 0 ? 0 : elapsed,
      ),
      status: status,
      exitCode: exitCode,
      partialApplied: partialApplied,
      projectRoot: project.root.absolute.path,
      canonicalProjectRoot: canonicalProjectRoot,
      packageName: project.packageName,
      analysisMode: project.analysisMode,
      requestedAdapters: List.unmodifiable(requestedAdapters),
      adapterReportDefinitions: List.unmodifiable(
        _adapterReportDefinitions.values.toList()
          ..sort((left, right) => left.adapterId.compareTo(right.adapterId)),
      ),
      targetMatrix: project.targetMatrix,
      rootCoverage: project.rootCoverage,
      analysisPasses: List.unmodifiable(_analysisPasses),
      findings: List.unmodifiable(findings),
      diagnostics: List.unmodifiable(_diagnostics),
      verificationAttempts: List.unmodifiable(_verificationAttempts),
      applyFindingOutcomes: List.unmodifiable(
        _applyFindingOutcomes.values.toList()
          ..sort((left, right) => left.findingId.compareTo(right.findingId)),
      ),
      applySelection: _applySelection,
      applyInitialPlan: _applyInitialPlan,
      applyStatistics: applyStatistics,
      quarantinePath: quarantinePath,
      acceptedRiskCodes: _acceptedRiskCodes,
      riskAcceptanceSource: _riskAcceptanceSource,
    );
  }

  /// Finalizes an incomplete command as a zero-finding failed report.
  ///
  /// Arbitrary exceptions and stack traces never enter this boundary; callers
  /// must supply only a stable [ReportableCommandFailure].
  RunReport finishFailure({
    required ProjectContext project,
    required ReportableCommandFailure failure,
    List<Finding>? completedFindings,
    ApplyStatistics? applyStatistics,
  }) {
    if (_analysisPasses.isEmpty && completedFindings?.isNotEmpty == true) {
      throw StateError(
        'Incomplete-analysis failure reports cannot retain findings.',
      );
    }
    if (_analysisPasses.isNotEmpty && completedFindings == null) {
      throw StateError(
        'Completed analysis passes require their truthful finding snapshot.',
      );
    }
    addDiagnostic(
      RunDiagnostic(
        code: failure.code,
        phase: failure.phase,
        message: failure.message,
      ),
    );
    return finish(
      project: project,
      status: failure.status,
      exitCode: failure.exitCode,
      findings: completedFindings ?? const [],
      applyStatistics: applyStatistics,
    );
  }

  bool _sameDefinitions(
    Map<String, AdapterReportDefinition> left,
    Map<String, AdapterReportDefinition> right,
  ) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (entry.value != right[entry.key]) return false;
    }
    return true;
  }
}
