// ignore_for_file: public_member_api_docs

import '../adapters/adapter_report_definition.dart';
import '../apply/finding_selection.dart';
import '../core/confidence/confidence.dart';
import '../core/confidence/finding.dart';
import '../core/graph/evidence.dart';
import '../core/project/analysis_mode.dart';
import '../core/project/target_matrix.dart';

/// Command represented by a run report.
enum RunCommand { scan, apply }

/// Terminal outcome of one CLI invocation.
enum RunStatus {
  completed,
  noChanges,
  dryRun,
  safeStopped,
  infrastructureFailure,
  recoveryRequired,
  internalError,
  interrupted,
}

/// How an apply run accepted findings exposed to external consumers.
enum RiskAcceptanceSource { interactive, yesFlag, notRequired }

/// Why an adapter participated in an analysis pass.
enum AdapterRunRole { reporting, support }

/// Terminal status of an adapter attempt.
enum AdapterRunStatus { executed, notApplicable, failed }

/// Purpose of one analysis pass in the run lifecycle.
enum AnalysisPassPurpose { initial, rescan, finalScan }

/// Measurement availability.
enum MeasurementStatus { measured, unknown, notApplicable }

/// Role of a verifier invocation in an apply transaction.
enum VerificationAttemptPurpose { baseline, candidate, rollback }

/// Sanitized verification step evidence.
class VerificationStepReport {
  const VerificationStepReport({
    required this.id,
    required this.passed,
    required this.available,
    required this.exitCode,
    required this.elapsedMicros,
  });

  final String id;
  final bool passed;
  final bool available;
  final int exitCode;
  final int elapsedMicros;
}

/// Sanitized evidence for one complete verifier invocation.
class VerificationAttemptReport {
  VerificationAttemptReport({
    required this.purpose,
    required this.complete,
    required this.available,
    required this.accepted,
    required this.policyHash,
    required List<String> requiredStepIds,
    required List<String> observedStepIds,
    required this.workingDirectory,
    required this.toolchainIdentity,
    required List<VerificationStepReport> steps,
    required this.newFailureCount,
    required this.infrastructureFailureCount,
    this.round,
    this.transactionId,
  }) : requiredStepIds = List.unmodifiable(requiredStepIds),
       observedStepIds = List.unmodifiable(observedStepIds),
       steps = List.unmodifiable(steps);

  final VerificationAttemptPurpose purpose;
  final int? round;
  final String? transactionId;
  final bool complete;
  final bool available;
  final bool accepted;
  final String policyHash;
  final List<String> requiredStepIds;
  final List<String> observedStepIds;
  final String workingDirectory;
  final String toolchainIdentity;
  final List<VerificationStepReport> steps;
  final int newFailureCount;
  final int infrastructureFailureCount;
}

/// Immutable identity and timing for one invocation.
class RunIdentity {
  /// Creates run identity metadata.
  const RunIdentity({
    required this.id,
    required this.command,
    required this.toolVersion,
    required this.startedAtUtc,
    required this.finishedAtUtc,
    required this.elapsedMicros,
  });

  final String id;
  final RunCommand command;
  final String toolVersion;
  final DateTime startedAtUtc;
  final DateTime finishedAtUtc;
  final int elapsedMicros;
}

/// Execution facts for one adapter in one analysis pass.
class AdapterRunReport {
  /// Creates an adapter execution record.
  const AdapterRunReport({
    required this.id,
    required this.name,
    required this.role,
    required this.status,
    required this.elapsedMicros,
    required this.nodesAdded,
    required this.edgesAdded,
    required this.blockersAdded,
    this.reason,
  });

  final String id;
  final String name;
  final AdapterRunRole role;
  final AdapterRunStatus status;
  final int elapsedMicros;
  final int nodesAdded;
  final int edgesAdded;
  final int blockersAdded;
  final String? reason;
}

/// A typed quantity whose semantics forbid accidental cross-domain totals.
class RunMeasurement {
  /// Creates a report measurement.
  const RunMeasurement({
    required this.kind,
    required this.status,
    required this.unit,
    required this.scope,
    required this.aggregation,
    this.adapterId,
    this.value,
    this.knownCount = 0,
    this.unknownCount = 0,
  }) : assert(status == MeasurementStatus.measured ? value != null : true);

  final String kind;
  final String? adapterId;
  final MeasurementStatus status;
  final String unit;
  final String scope;
  final String aggregation;
  final int? value;
  final int knownCount;
  final int unknownCount;
}

/// Finding totals using stable tier and adapter names.
class FindingStatistics {
  /// Creates immutable finding totals.
  FindingStatistics({
    required this.total,
    required Map<String, int> byTier,
    required Map<String, int> byReportingAdapter,
    required Map<String, Map<String, int>> byReportingAdapterAndTier,
    required Map<String, int> byRule,
    required Map<String, int> byNodeKind,
    required Map<String, int> byClassificationReason,
  }) : byTier = Map.unmodifiable(byTier),
       byReportingAdapter = Map.unmodifiable(byReportingAdapter),
       byReportingAdapterAndTier = Map.unmodifiable({
         for (final entry in byReportingAdapterAndTier.entries)
           entry.key: Map<String, int>.unmodifiable(entry.value),
       }),
       byRule = Map.unmodifiable(byRule),
       byNodeKind = Map.unmodifiable(byNodeKind),
       byClassificationReason = Map.unmodifiable(byClassificationReason);

  /// Aggregates [findings] without interpreting absent byte values as zero.
  factory FindingStatistics.fromFindings(List<Finding> findings) {
    final byTier = {for (final tier in Confidence.values) tier.label: 0};
    final byAdapter = <String, int>{};
    final byRule = <String, int>{};
    final byKind = <String, int>{};
    final byReason = <String, int>{};
    final byAdapterAndTier = <String, Map<String, int>>{};
    for (final finding in findings) {
      byTier[finding.confidence.label] = byTier[finding.confidence.label]! + 1;
      final adapter = finding.reportingAdapterId ?? 'unknown';
      byAdapter.update(adapter, (count) => count + 1, ifAbsent: () => 1);
      final adapterTiers = byAdapterAndTier.putIfAbsent(
        adapter,
        () => {for (final tier in Confidence.values) tier.label: 0},
      );
      adapterTiers[finding.confidence.label] =
          adapterTiers[finding.confidence.label]! + 1;
      byRule.update(finding.ruleId, (count) => count + 1, ifAbsent: () => 1);
      byKind.update(
        finding.node.kind.name,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
      for (final reason in finding.classificationReasons) {
        byReason.update(reason.code, (count) => count + 1, ifAbsent: () => 1);
      }
    }
    return FindingStatistics(
      total: findings.length,
      byTier: Map.unmodifiable(byTier),
      byReportingAdapter: Map.unmodifiable(byAdapter),
      byReportingAdapterAndTier: Map.unmodifiable({
        for (final entry in byAdapterAndTier.entries)
          entry.key: Map<String, int>.unmodifiable(entry.value),
      }),
      byRule: Map.unmodifiable(byRule),
      byNodeKind: Map.unmodifiable(byKind),
      byClassificationReason: Map.unmodifiable(byReason),
    );
  }

  final int total;
  final Map<String, int> byTier;
  final Map<String, int> byReportingAdapter;
  final Map<String, Map<String, int>> byReportingAdapterAndTier;
  final Map<String, int> byRule;
  final Map<String, int> byNodeKind;
  final Map<String, int> byClassificationReason;
}

/// Deduplicated blocker impact statistics.
class BlockerStatistics {
  /// Creates blocker statistics.
  BlockerStatistics({
    required this.recorded,
    required this.activeUnique,
    this.unboundUnique = 0,
    required this.affectedFindings,
    required Map<String, int> byProducer,
  }) : byProducer = Map.unmodifiable(byProducer);

  final int recorded;
  final int activeUnique;
  final int unboundUnique;
  final int affectedFindings;
  final Map<String, int> byProducer;
}

/// Facts and output from one graph construction/classification pass.
class AnalysisPassReport {
  /// Creates an immutable analysis pass.
  AnalysisPassReport({
    required this.id,
    required this.purpose,
    required this.elapsedMicros,
    required this.nodeCount,
    required this.edgeCount,
    required this.rootCount,
    required this.recordedBlockerCount,
    required this.danglingEdgeCount,
    this.danglingRootCount = 0,
    required List<AdapterRunReport> adapterRuns,
    required this.findingStatistics,
    List<Blocker> unboundBlockers = const [],
    required this.blockerStatistics,
    required List<RunMeasurement> measurements,
    required this.exclusionPolicyVersion,
    required Map<String, int> exclusionsByReason,
    this.round,
  }) : adapterRuns = List.unmodifiable(adapterRuns),
       unboundBlockers = List.unmodifiable(unboundBlockers),
       measurements = List.unmodifiable(measurements),
       exclusionsByReason = Map.unmodifiable(exclusionsByReason);

  final String id;
  final AnalysisPassPurpose purpose;
  final int? round;
  final int elapsedMicros;
  final int nodeCount;
  final int edgeCount;
  final int rootCount;
  final int recordedBlockerCount;
  final int danglingEdgeCount;
  final int danglingRootCount;
  final List<AdapterRunReport> adapterRuns;
  final FindingStatistics findingStatistics;
  final List<Blocker> unboundBlockers;
  final BlockerStatistics blockerStatistics;
  final List<RunMeasurement> measurements;
  final int exclusionPolicyVersion;
  final Map<String, int> exclusionsByReason;
}

/// Sanitized non-finding diagnostic emitted during a run.
class RunDiagnostic {
  /// Creates a diagnostic.
  const RunDiagnostic({required this.code, required this.message, this.phase});

  final String code;
  final String message;
  final String? phase;
}

/// Terminal disposition of one finding considered by an apply invocation.
enum ApplyFindingOutcomeStatus {
  committed,
  rejectedRecovered,
  blocked,
  skippedDependency,
  remaining,
  recoveryRequired,
}

/// Immutable apply evidence retained even when a later scan omits the finding.
class ApplyFindingOutcome {
  /// Creates one per-finding apply outcome.
  ApplyFindingOutcome({
    required this.finding,
    required this.status,
    required this.reasonCode,
    required this.reason,
    this.round,
    this.transactionId,
    this.rollbackVerified,
    List<String> relatedNodeIds = const [],
  }) : relatedNodeIds = List.unmodifiable(relatedNodeIds);

  final Finding finding;
  final ApplyFindingOutcomeStatus status;
  final String reasonCode;
  final String reason;
  final int? round;
  final String? transactionId;
  final bool? rollbackVerified;
  final List<String> relatedNodeIds;

  /// Stable graph identity used to replace lifecycle updates for one finding.
  String get findingId => finding.node.id;

  /// Validates status-specific recovery evidence.
  void validate() {
    if (reasonCode.isEmpty || reason.isEmpty) {
      throw StateError('Apply finding outcomes require a reason.');
    }
    if (status == ApplyFindingOutcomeStatus.rejectedRecovered &&
        rollbackVerified != true) {
      throw StateError(
        'Rejected/recovered findings require verified rollback evidence.',
      );
    }
    if (status == ApplyFindingOutcomeStatus.recoveryRequired &&
        rollbackVerified == true) {
      throw StateError(
        'Recovery-required findings cannot claim verified rollback.',
      );
    }
    if ((status == ApplyFindingOutcomeStatus.committed ||
            status == ApplyFindingOutcomeStatus.rejectedRecovered ||
            status == ApplyFindingOutcomeStatus.recoveryRequired) &&
        transactionId == null) {
      throw StateError(
        'Transactional apply finding outcomes require a transaction ID.',
      );
    }
  }
}

/// Structured apply counters. Auxiliary actions never increment finding totals.
class ApplyStatistics {
  /// Creates apply statistics.
  const ApplyStatistics({
    required this.rounds,
    required this.findingsCommitted,
    required this.findingsRejectedRecovered,
    required this.findingsBlocked,
    required this.findingsSkippedDependency,
    required this.findingsRemaining,
    required this.actionsDeclared,
    required this.actionsCommitted,
    required this.actionsRolledBack,
    required this.actionsFailedRecovered,
    required this.transactionsBegun,
    required this.transactionsCommitted,
    required this.transactionsRolledBackVerified,
    required this.transactionsRecoveryRequired,
    required this.transactionsNonTerminal,
    required this.verificationAttempts,
    required this.sourceBytesRemoved,
  });

  /// Empty apply metrics for dry-run, no-op, and pre-mutation failure reports.
  static const empty = ApplyStatistics(
    rounds: 0,
    findingsCommitted: 0,
    findingsRejectedRecovered: 0,
    findingsBlocked: 0,
    findingsSkippedDependency: 0,
    findingsRemaining: 0,
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

  final int rounds;
  final int findingsCommitted;
  final int findingsRejectedRecovered;
  final int findingsBlocked;
  final int findingsSkippedDependency;
  final int findingsRemaining;
  final int actionsDeclared;
  final int actionsCommitted;
  final int actionsRolledBack;
  final int actionsFailedRecovered;
  final int transactionsBegun;
  final int transactionsCommitted;
  final int transactionsRolledBackVerified;
  final int transactionsRecoveryRequired;
  final int transactionsNonTerminal;
  final int verificationAttempts;
  final int sourceBytesRemoved;

  /// Validates the terminal transaction partition.
  void validate() {
    final terminal =
        transactionsCommitted +
        transactionsRolledBackVerified +
        transactionsRecoveryRequired +
        transactionsNonTerminal;
    if (transactionsBegun != terminal) {
      throw StateError(
        'Apply transaction counters do not partition begun transactions.',
      );
    }
  }
}

/// Immutable authorization boundary and initial logical plan for apply.
class ApplySelectionReport {
  /// Creates validated selection evidence.
  ApplySelectionReport({
    required this.mode,
    required List<String> requestedFindingIds,
    required List<String> plannedFindingIds,
    this.planFingerprint,
  }) : requestedFindingIds = List.unmodifiable(requestedFindingIds),
       plannedFindingIds = List.unmodifiable(plannedFindingIds) {
    _validateSortedUnique(this.requestedFindingIds, 'requested finding IDs');
    _validateSortedUnique(this.plannedFindingIds, 'planned finding IDs');
    if (mode == FindingSelectionMode.exact &&
        this.requestedFindingIds.isEmpty) {
      throw StateError('Exact apply selection requires finding IDs.');
    }
    if (mode == FindingSelectionMode.allEligible &&
        this.requestedFindingIds.isNotEmpty) {
      throw StateError('All-eligible selection cannot contain requested IDs.');
    }
    if (mode == FindingSelectionMode.exact &&
        this.plannedFindingIds
            .toSet()
            .difference(this.requestedFindingIds.toSet())
            .isNotEmpty) {
      throw StateError('Exact apply plans cannot add logical findings.');
    }
    final fingerprint = planFingerprint;
    if (fingerprint != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
      throw StateError('Apply plan fingerprint must be SHA-256.');
    }
    if (this.plannedFindingIds.isEmpty != (fingerprint == null)) {
      throw StateError(
        'Apply plan fingerprint must exist exactly when findings are planned.',
      );
    }
  }

  /// Historical all-eligible behavior or an exact hard allowlist.
  final FindingSelectionMode mode;

  /// Sorted, case-sensitive IDs explicitly requested by the user.
  final List<String> requestedFindingIds;

  /// Sorted logical finding IDs admitted to the initial plan.
  final List<String> plannedFindingIds;

  /// SHA-256 over the canonical initial logical and physical plan.
  final String? planFingerprint;

  static void _validateSortedUnique(List<String> values, String label) {
    if (values.any((value) => value.isEmpty) ||
        values.toSet().length != values.length) {
      throw StateError('$label must be non-empty and unique.');
    }
    final sorted = values.toList()..sort();
    for (var index = 0; index < values.length; index++) {
      if (values[index] != sorted[index]) {
        throw StateError('$label must be sorted.');
      }
    }
  }
}

/// Complete immutable output of one CLI invocation.
class RunReport {
  /// Creates and validates a report.
  RunReport({
    required this.identity,
    required this.status,
    required this.exitCode,
    required this.partialApplied,
    required this.projectRoot,
    required this.packageName,
    this.analysisMode = AnalysisMode.application,
    required List<String> requestedAdapters,
    List<AdapterReportDefinition> adapterReportDefinitions = const [],
    required this.targetMatrix,
    required this.rootCoverage,
    required List<AnalysisPassReport> analysisPasses,
    required List<Finding> findings,
    required List<RunDiagnostic> diagnostics,
    List<VerificationAttemptReport> verificationAttempts = const [],
    List<ApplyFindingOutcome> applyFindingOutcomes = const [],
    this.applySelection,
    this.applyStatistics,
    this.quarantinePath,
    List<String> acceptedRiskCodes = const [],
    this.riskAcceptanceSource = RiskAcceptanceSource.notRequired,
  }) : requestedAdapters = List.unmodifiable(requestedAdapters),
       adapterReportDefinitions = List.unmodifiable(
         adapterReportDefinitions.map((definition) => definition.snapshot()),
       ),
       analysisPasses = List.unmodifiable(analysisPasses),
       findings = List.unmodifiable(findings),
       diagnostics = List.unmodifiable(diagnostics),
       verificationAttempts = List.unmodifiable(verificationAttempts),
       applyFindingOutcomes = List.unmodifiable(applyFindingOutcomes),
       acceptedRiskCodes = List.unmodifiable(acceptedRiskCodes) {
    final adapterIds = <String>{};
    for (final definition in adapterReportDefinitions) {
      definition.validate();
      if (!adapterIds.add(definition.adapterId)) {
        throw StateError(
          'Duplicate adapter report definition: ${definition.adapterId}',
        );
      }
    }
    applyStatistics?.validate();
    final outcomeIds = <String>{};
    for (final outcome in applyFindingOutcomes) {
      outcome.validate();
      if (!outcomeIds.add(outcome.findingId)) {
        throw StateError(
          'Duplicate apply finding outcome: ${outcome.findingId}',
        );
      }
    }
    if (applySelection != null && identity.command != RunCommand.apply) {
      throw StateError('Finding selection evidence belongs only to apply.');
    }
  }

  /// Public JSON schema version.
  static const int schemaVersion = 3;

  final RunIdentity identity;
  final RunStatus status;
  final int exitCode;
  final bool partialApplied;
  final String projectRoot;
  final String packageName;
  final AnalysisMode analysisMode;
  final List<String> requestedAdapters;
  final List<AdapterReportDefinition> adapterReportDefinitions;
  final TargetMatrix targetMatrix;
  final RootCoverage rootCoverage;
  final List<AnalysisPassReport> analysisPasses;
  final List<Finding> findings;
  final List<RunDiagnostic> diagnostics;
  final List<VerificationAttemptReport> verificationAttempts;
  final List<ApplyFindingOutcome> applyFindingOutcomes;
  final ApplySelectionReport? applySelection;
  final ApplyStatistics? applyStatistics;
  final String? quarantinePath;
  final List<String> acceptedRiskCodes;
  final RiskAcceptanceSource riskAcceptanceSource;

  /// Final pass statistics, or empty totals when analysis never completed.
  FindingStatistics get finalFindingStatistics => analysisPasses.isEmpty
      ? FindingStatistics.fromFindings(const [])
      : analysisPasses.last.findingStatistics;
}
