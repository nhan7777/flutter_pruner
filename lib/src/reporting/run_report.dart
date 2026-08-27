// ignore_for_file: public_member_api_docs

import 'package:path/path.dart' as p;

import '../adapters/adapter_report_definition.dart';
import '../apply/apply_preview_evidence.dart';
import '../apply/finding_action_builder.dart';
import '../apply/finding_selection.dart';
import '../apply/removal_planner.dart';
import '../core/confidence/confidence.dart';
import '../core/confidence/finding.dart';
import '../core/graph/evidence.dart';
import '../core/graph/execution_target.dart';
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
    this.waveId,
    List<String> transactionIds = const [],
  }) : requiredStepIds = List.unmodifiable(requiredStepIds),
       observedStepIds = List.unmodifiable(observedStepIds),
       steps = List.unmodifiable(steps),
       transactionIds = List.unmodifiable(transactionIds) {
    final hasValidIds =
        transactionIds.isNotEmpty &&
        transactionIds.toSet().length == transactionIds.length;
    switch (purpose) {
      case VerificationAttemptPurpose.baseline:
        if (waveId != null ||
            transactionId != null ||
            transactionIds.isNotEmpty) {
          throw StateError('Baseline verification cannot have wave identity.');
        }
      case VerificationAttemptPurpose.candidate:
        if (waveId == null || !hasValidIds) {
          throw StateError('Candidate verification requires wave membership.');
        }
        if (transactionIds.length == 1) {
          if (transactionId != transactionIds.single) {
            throw StateError(
              'Single-transaction candidate requires matching singular identity.',
            );
          }
        } else if (transactionId != null) {
          throw StateError(
            'Multi-transaction candidate cannot have singular identity.',
          );
        }
      case VerificationAttemptPurpose.rollback:
        if (waveId != null || transactionIds.isNotEmpty) {
          throw StateError(
            'Rollback verification cannot have wave membership.',
          );
        }
    }
  }

  final VerificationAttemptPurpose purpose;
  final int? round;
  final String? transactionId;
  final String? waveId;
  final List<String> transactionIds;
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

/// Immutable graph integrity for one configured or auxiliary context.
class ExecutionTargetIntegrityReport {
  /// Creates one per-context integrity record.
  ExecutionTargetIntegrityReport({
    required this.id,
    required this.domain,
    required this.complete,
    required this.danglingEdgeCount,
    required this.danglingRootCount,
    List<String> incompleteReasons = const [],
  }) : incompleteReasons = List.unmodifiable(incompleteReasons);

  /// Stable execution-context ID.
  final String id;

  /// `configuredTarget`, `auxiliary`, or `unattributed`.
  final String domain;

  /// Whether this context has no dangling or incomplete facts.
  final bool complete;

  /// Number of dangling edges attributed to this context.
  final int danglingEdgeCount;

  /// Number of dangling roots attributed to this context.
  final int danglingRootCount;

  /// Stable reasons the context is incomplete.
  final List<String> incompleteReasons;
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
    Map<String, ExecutionTargetIntegrityReport> integrityByExecutionTarget =
        const {},
    ExecutionTargetIntegrityReport? unattributedIntegrity,
    List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets = const [],
    List<AuxiliaryExecutionTargetRegistryIssue> auxiliaryExecutionTargetIssues =
        const [],
    required List<AdapterRunReport> adapterRuns,
    required this.findingStatistics,
    List<Blocker> unboundBlockers = const [],
    required this.blockerStatistics,
    required List<RunMeasurement> measurements,
    required this.exclusionPolicyVersion,
    required Map<String, int> exclusionsByReason,
    this.round,
  }) : integrityByExecutionTarget = Map.unmodifiable(
         integrityByExecutionTarget,
       ),
       unattributedIntegrity =
           unattributedIntegrity ??
           ExecutionTargetIntegrityReport(
             id: 'unattributed',
             domain: 'unattributed',
             complete: true,
             danglingEdgeCount: 0,
             danglingRootCount: 0,
           ),
       auxiliaryExecutionTargets = List.unmodifiable(auxiliaryExecutionTargets),
       auxiliaryExecutionTargetIssues = List.unmodifiable(
         auxiliaryExecutionTargetIssues,
       ),
       adapterRuns = List.unmodifiable(adapterRuns),
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
  final Map<String, ExecutionTargetIntegrityReport> integrityByExecutionTarget;
  final ExecutionTargetIntegrityReport unattributedIntegrity;
  final List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets;
  final List<AuxiliaryExecutionTargetRegistryIssue>
  auxiliaryExecutionTargetIssues;
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

/// How completely the initial physical plan represents the requested apply.
enum ApplyInitialPlanScope { initialRoundOnly, completeExactSelection }

/// Comparison between a captured preview and an optional expected token.
enum ApplyPreviewComparison { notRequested, matched, mismatched }

/// Immutable scalar projection of one planned physical operation.
final class ApplyPlanActionReport {
  /// Creates and validates one physical action projection.
  ApplyPlanActionReport({
    required this.order,
    required this.logicalFindingId,
    required this.journalFindingId,
    required this.operation,
    required String projectRelativePath,
    this.label,
    required this.countsTowardSummary,
    String? cleanupTargetPath,
  }) : projectRelativePath = ApplySourceSnapshot.normalizeProjectRelativePath(
         projectRelativePath,
       ),
       cleanupTargetPath = cleanupTargetPath == null
           ? null
           : ApplySourceSnapshot.normalizeProjectRelativePath(
               cleanupTargetPath,
             ) {
    if (order < 0) {
      throw StateError('Physical action order cannot be negative.');
    }
    if (logicalFindingId.isEmpty || journalFindingId.isEmpty) {
      throw StateError('Physical action finding identities cannot be empty.');
    }
    if (label != null && label!.isEmpty) {
      throw StateError('Physical action labels cannot be empty.');
    }
    if (operation == FindingActionOperation.cleanupImports &&
        this.cleanupTargetPath == null) {
      throw StateError('Import cleanup requires its project-relative target.');
    }
    if (operation != FindingActionOperation.cleanupImports &&
        this.cleanupTargetPath != null) {
      throw StateError('Only import cleanup can have a cleanup target.');
    }
  }

  /// Zero-based execution order within the owning atomic unit.
  final int order;

  /// Logical finding authorizing the physical operation.
  final String logicalFindingId;

  /// Effective unique identity written to transaction evidence.
  final String journalFindingId;

  /// Executor operation applied to [projectRelativePath].
  final FindingActionOperation operation;

  /// Canonical project-relative source path snapshotted for this action.
  final String projectRelativePath;

  /// Optional operation-specific human label.
  final String? label;

  /// Whether this action increments logical finding summary counters.
  final bool countsTowardSummary;

  /// Project-relative library removed from an importer, when applicable.
  final String? cleanupTargetPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyPlanActionReport &&
          order == other.order &&
          logicalFindingId == other.logicalFindingId &&
          journalFindingId == other.journalFindingId &&
          operation == other.operation &&
          projectRelativePath == other.projectRelativePath &&
          label == other.label &&
          countsTowardSummary == other.countsTowardSummary &&
          cleanupTargetPath == other.cleanupTargetPath;

  @override
  int get hashCode => Object.hash(
    order,
    logicalFindingId,
    journalFindingId,
    operation,
    projectRelativePath,
    label,
    countsTowardSummary,
    cleanupTargetPath,
  );
}

/// Immutable scalar projection of one planner atomic unit.
final class ApplyPlanUnitReport {
  /// Creates and validates one ordered unit projection.
  ApplyPlanUnitReport({
    required this.order,
    required this.id,
    required List<String> findingIds,
    required List<String> dependencyUnitIds,
    required List<ApplyPlanActionReport> actions,
  }) : findingIds = List<String>.unmodifiable(findingIds),
       dependencyUnitIds = List<String>.unmodifiable(dependencyUnitIds),
       actions = List<ApplyPlanActionReport>.unmodifiable(actions) {
    if (order < 0 || id.isEmpty) {
      throw StateError('Apply plan unit identity and order must be valid.');
    }
    _validateNonEmptyUniqueValues(this.findingIds, 'unit finding IDs');
    _validateUniqueValues(this.dependencyUnitIds, 'unit dependency IDs');
    if (this.actions.isEmpty) {
      throw StateError('Apply plan units must contain physical actions.');
    }
    final projectedFindingIds = <String>{};
    for (var index = 0; index < this.actions.length; index++) {
      final action = this.actions[index];
      if (action.order != index) {
        throw StateError('Physical action order must be contiguous.');
      }
      if (!this.findingIds.contains(action.logicalFindingId)) {
        throw StateError(
          'Physical action does not belong to its unit finding IDs.',
        );
      }
      projectedFindingIds.add(action.logicalFindingId);
    }
    if (projectedFindingIds.length != this.findingIds.length) {
      throw StateError('Every unit finding must project physical work.');
    }
  }

  /// Zero-based consumer-first unit order.
  final int order;

  /// Stable planner atomic-unit identity.
  final String id;

  /// Logical finding IDs in authoritative planner order.
  final List<String> findingIds;

  /// Dependency unit IDs in authoritative planner order.
  final List<String> dependencyUnitIds;

  /// Physical operations in exact execution order.
  final List<ApplyPlanActionReport> actions;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyPlanUnitReport &&
          order == other.order &&
          id == other.id &&
          _listEquals(findingIds, other.findingIds) &&
          _listEquals(dependencyUnitIds, other.dependencyUnitIds) &&
          _listEquals(actions, other.actions);

  @override
  int get hashCode => Object.hash(
    order,
    id,
    Object.hashAll(findingIds),
    Object.hashAll(dependencyUnitIds),
    Object.hashAll(actions),
  );
}

/// Immutable scalar projection of one planner-owned block.
final class ApplyPlanBlockReport {
  /// Creates a blocked-finding projection.
  ApplyPlanBlockReport({
    required this.findingId,
    required this.reason,
    required this.blockedBy,
  }) {
    if (findingId.isEmpty || blockedBy.isEmpty) {
      throw StateError('Apply plan block identities cannot be empty.');
    }
  }

  /// Logical finding excluded from the physical plan.
  final String findingId;

  /// Planner-owned reason for the block.
  final PlanBlockReason reason;

  /// Retained graph identity that prevents removal.
  final String blockedBy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyPlanBlockReport &&
          findingId == other.findingId &&
          reason == other.reason &&
          blockedBy == other.blockedBy;

  @override
  int get hashCode => Object.hash(findingId, reason, blockedBy);
}

/// Immutable report projection of one preview source snapshot.
final class ApplySourceSnapshotReport {
  /// Creates and validates a source snapshot projection.
  factory ApplySourceSnapshotReport({
    required String projectRelativePath,
    required String canonicalPath,
    required String sha256,
    required int sizeBytes,
    required int? posixMode,
  }) {
    final snapshot = ApplySourceSnapshot(
      projectRelativePath: projectRelativePath,
      canonicalPath: canonicalPath,
      sha256: sha256,
      sizeBytes: sizeBytes,
      posixMode: posixMode,
    );
    return ApplySourceSnapshotReport._(
      projectRelativePath: snapshot.projectRelativePath,
      canonicalPath: snapshot.canonicalPath,
      sha256: snapshot.sha256,
      sizeBytes: snapshot.sizeBytes,
      posixMode: snapshot.posixMode,
    );
  }

  /// Projects one validated domain snapshot without changing its facts.
  factory ApplySourceSnapshotReport.fromSnapshot(
    ApplySourceSnapshot snapshot,
  ) => ApplySourceSnapshotReport(
    projectRelativePath: snapshot.projectRelativePath,
    canonicalPath: snapshot.canonicalPath,
    sha256: snapshot.sha256,
    sizeBytes: snapshot.sizeBytes,
    posixMode: snapshot.posixMode,
  );

  const ApplySourceSnapshotReport._({
    required this.projectRelativePath,
    required this.canonicalPath,
    required this.sha256,
    required this.sizeBytes,
    required this.posixMode,
  });

  /// Canonical project-relative source path.
  final String projectRelativePath;

  /// Canonical absolute source path.
  final String canonicalPath;

  /// Lowercase SHA-256 of the source bytes.
  final String sha256;

  /// Exact source byte length.
  final int sizeBytes;

  /// POSIX permission and special bits, or null when unavailable.
  final int? posixMode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplySourceSnapshotReport &&
          projectRelativePath == other.projectRelativePath &&
          canonicalPath == other.canonicalPath &&
          sha256 == other.sha256 &&
          sizeBytes == other.sizeBytes &&
          posixMode == other.posixMode;

  @override
  int get hashCode => Object.hash(
    projectRelativePath,
    canonicalPath,
    sha256,
    sizeBytes,
    posixMode,
  );
}

/// Immutable report projection of captured apply preview evidence.
final class ApplyPreviewReport {
  /// Creates and validates one versioned preview projection from complete
  /// canonical evidence.
  factory ApplyPreviewReport({
    required int version,
    required String canonicalProjectRoot,
    required String? planFingerprint,
    required List<ApplySourceSnapshotReport> sources,
  }) {
    if (version != ApplyPreviewEvidence.canonicalVersion) {
      throw StateError('Unsupported apply preview version: $version.');
    }
    final sourceSnapshot = List<ApplySourceSnapshotReport>.unmodifiable(
      sources,
    );
    final relativePaths = <String>{};
    final canonicalPaths = <String>{};
    for (var index = 0; index < sourceSnapshot.length; index++) {
      final source = sourceSnapshot[index];
      if (!relativePaths.add(source.projectRelativePath) ||
          !canonicalPaths.add(
            _canonicalSourcePathIdentity(source.canonicalPath),
          )) {
        throw StateError('Apply preview report sources must be unique.');
      }
      if (index > 0 &&
          _compareSources(sourceSnapshot[index - 1], source) >= 0) {
        throw StateError('Apply preview report sources must be sorted.');
      }
    }
    final evidence = ApplyPreviewEvidence(
      canonicalProjectRoot: canonicalProjectRoot,
      planFingerprint: planFingerprint,
      sources: sourceSnapshot
          .map(
            (source) => ApplySourceSnapshot(
              projectRelativePath: source.projectRelativePath,
              canonicalPath: source.canonicalPath,
              sha256: source.sha256,
              sizeBytes: source.sizeBytes,
              posixMode: source.posixMode,
            ),
          )
          .toList(growable: false),
    );
    return ApplyPreviewReport._(
      version: version,
      canonicalProjectRoot: evidence.canonicalProjectRoot,
      planFingerprint: evidence.planFingerprint,
      fingerprint: evidence.fingerprint,
      sources: sourceSnapshot,
    );
  }

  /// Projects validated domain evidence into report-only scalar values.
  factory ApplyPreviewReport.fromEvidence(ApplyPreviewEvidence evidence) =>
      ApplyPreviewReport(
        version: ApplyPreviewEvidence.canonicalVersion,
        canonicalProjectRoot: evidence.canonicalProjectRoot,
        planFingerprint: evidence.planFingerprint,
        sources: evidence.sources
            .map(ApplySourceSnapshotReport.fromSnapshot)
            .toList(growable: false),
      );

  const ApplyPreviewReport._({
    required this.version,
    required this.canonicalProjectRoot,
    required this.planFingerprint,
    required this.fingerprint,
    required this.sources,
  });

  /// Canonical preview encoding version.
  final int version;

  /// Canonical project root included in the preview token payload.
  ///
  /// This binding fact remains report-internal in A2 and A3 serialization.
  final String canonicalProjectRoot;

  /// Action-plan fingerprint included in the preview token payload.
  ///
  /// This binding fact remains report-internal in A2 and A3 serialization.
  final String? planFingerprint;

  /// Full `v1:<lowercase SHA-256>` preview token.
  final String fingerprint;

  /// Unique source snapshots in canonical order.
  final List<ApplySourceSnapshotReport> sources;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyPreviewReport &&
          version == other.version &&
          canonicalProjectRoot == other.canonicalProjectRoot &&
          planFingerprint == other.planFingerprint &&
          fingerprint == other.fingerprint &&
          _listEquals(sources, other.sources);

  @override
  int get hashCode => Object.hash(
    version,
    canonicalProjectRoot,
    planFingerprint,
    fingerprint,
    Object.hashAll(sources),
  );
}

/// Immutable initial physical plan exposed by apply reports.
final class ApplyInitialPlanReport {
  /// Creates and validates an initial physical plan projection.
  ApplyInitialPlanReport({
    required this.canonicalVersion,
    required this.scope,
    required this.planFingerprint,
    required List<ApplyPlanUnitReport> units,
    required List<ApplyPlanBlockReport> blocked,
    this.preview,
  }) : units = List<ApplyPlanUnitReport>.unmodifiable(units),
       blocked = List<ApplyPlanBlockReport>.unmodifiable(blocked) {
    if (canonicalVersion != 1) {
      throw StateError(
        'Unsupported initial apply plan version: $canonicalVersion.',
      );
    }
    if (planFingerprint != null &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(planFingerprint!)) {
      throw StateError('Apply plan fingerprint must be lowercase SHA-256.');
    }
    if (this.units.isEmpty != (planFingerprint == null)) {
      throw StateError(
        'Apply plan fingerprint must exist exactly when units are planned.',
      );
    }

    final unitIds = <String>{};
    final findingIds = <String>{};
    final journalIdentities = <String>{};
    final actionIdentities =
        <(String, String, FindingActionOperation, String, String?)>{};
    for (var index = 0; index < this.units.length; index++) {
      final unit = this.units[index];
      if (unit.order != index) {
        throw StateError('Apply plan unit order must be contiguous.');
      }
      if (!unitIds.add(unit.id)) {
        throw StateError('Apply plan unit IDs must be unique.');
      }
      for (final findingId in unit.findingIds) {
        if (!findingIds.add(findingId)) {
          throw StateError('A logical finding cannot belong to several units.');
        }
      }
      for (final action in unit.actions) {
        if (!journalIdentities.add(action.journalFindingId)) {
          throw StateError(
            'Effective journal action identities must be unique.',
          );
        }
        if (!actionIdentities.add((
          unit.id,
          action.logicalFindingId,
          action.operation,
          action.projectRelativePath,
          action.cleanupTargetPath,
        ))) {
          throw StateError(
            'Composite physical action identities must be unique.',
          );
        }
      }
    }
    for (final unit in this.units) {
      for (final dependencyId in unit.dependencyUnitIds) {
        if (dependencyId == unit.id || !unitIds.contains(dependencyId)) {
          throw StateError('Apply plan dependencies must name another unit.');
        }
      }
    }

    final blockedFindingIds = <String>{};
    for (final item in this.blocked) {
      if (!blockedFindingIds.add(item.findingId) ||
          findingIds.contains(item.findingId)) {
        throw StateError('Apply plan blocks must be unique and unplanned.');
      }
    }
    final preview = this.preview;
    if (preview != null) {
      if (preview.planFingerprint != planFingerprint) {
        throw StateError(
          'Apply preview evidence belongs to a different action plan.',
        );
      }
      final actionPaths = this.units
          .expand((unit) => unit.actions)
          .map((action) => action.projectRelativePath)
          .toSet();
      final sourcePaths = preview.sources
          .map((source) => source.projectRelativePath)
          .toSet();
      if (actionPaths.length != sourcePaths.length ||
          !actionPaths.containsAll(sourcePaths)) {
        throw StateError(
          'Apply preview sources must match planned action sources.',
        );
      }
    }
  }

  /// Canonical initial-plan projection version.
  final int canonicalVersion;

  /// Whether later all-eligible rounds may discover additional work.
  final ApplyInitialPlanScope scope;

  /// SHA-256 over canonical initial plan topology, or null when empty.
  final String? planFingerprint;

  /// Planner units in exact physical execution order.
  final List<ApplyPlanUnitReport> units;

  /// Planner-owned blocks in their reported order.
  final List<ApplyPlanBlockReport> blocked;

  /// Captured source evidence, when snapshotting completed.
  final ApplyPreviewReport? preview;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApplyInitialPlanReport &&
          canonicalVersion == other.canonicalVersion &&
          scope == other.scope &&
          planFingerprint == other.planFingerprint &&
          _listEquals(units, other.units) &&
          _listEquals(blocked, other.blocked) &&
          preview == other.preview;

  @override
  int get hashCode => Object.hash(
    canonicalVersion,
    scope,
    planFingerprint,
    Object.hashAll(units),
    Object.hashAll(blocked),
    preview,
  );
}

/// Immutable authorization boundary and initial logical plan for apply.
class ApplySelectionReport {
  /// Creates validated selection evidence.
  ApplySelectionReport({
    required this.mode,
    required List<String> requestedFindingIds,
    required List<String> plannedFindingIds,
    this.planFingerprint,
    this.actualPreviewFingerprint,
    this.expectedPreviewFingerprint,
    ApplyPreviewComparison? previewComparison,
  }) : requestedFindingIds = List.unmodifiable(requestedFindingIds),
       plannedFindingIds = List.unmodifiable(plannedFindingIds),
       previewComparison = _validatedPreviewComparison(
         actualPreviewFingerprint,
         expectedPreviewFingerprint,
         plannedFindingIds.isNotEmpty,
         previewComparison,
       ) {
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
    if (expectedPreviewFingerprint != null &&
        mode != FindingSelectionMode.exact) {
      throw StateError('Preview expectations require exact selection.');
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

  /// Preview token captured for the current physical plan and source state.
  final String? actualPreviewFingerprint;

  /// Full token supplied to bind an exact-selection apply, when requested.
  final String? expectedPreviewFingerprint;

  /// Validated comparison derived from actual and expected preview tokens.
  final ApplyPreviewComparison previewComparison;

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
    String? canonicalProjectRoot,
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
    this.applyInitialPlan,
    this.applyStatistics,
    this.quarantinePath,
    List<String> acceptedRiskCodes = const [],
    this.riskAcceptanceSource = RiskAcceptanceSource.notRequired,
  }) : canonicalProjectRoot = canonicalProjectRoot == null
           ? null
           : ApplySourceSnapshot.validateCanonicalAbsolutePath(
               canonicalProjectRoot,
               label: 'Canonical report project root',
             ),
       requestedAdapters = List.unmodifiable(requestedAdapters),
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
    if (applyInitialPlan != null && identity.command != RunCommand.apply) {
      throw StateError('Initial physical plans belong only to apply.');
    }
    if (this.canonicalProjectRoot != null &&
        identity.command != RunCommand.apply) {
      throw StateError('Canonical apply roots belong only to apply reports.');
    }
    _validateInitialPlanSelection(applySelection, applyInitialPlan);
    final previewRoot = applyInitialPlan?.preview?.canonicalProjectRoot;
    if (previewRoot != null) {
      final reportRoot = this.canonicalProjectRoot;
      if (reportRoot == null ||
          _canonicalSourcePathIdentity(reportRoot) !=
              _canonicalSourcePathIdentity(previewRoot)) {
        throw StateError(
          'Apply preview evidence belongs to a different project root.',
        );
      }
    }
  }

  /// Public JSON schema version.
  static const int schemaVersion = 3;

  final RunIdentity identity;
  final RunStatus status;
  final int exitCode;
  final bool partialApplied;
  final String projectRoot;

  /// Canonical root used only to validate apply preview binding.
  ///
  /// This binding fact remains report-internal in A2 and A3 serialization.
  final String? canonicalProjectRoot;

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
  final ApplyInitialPlanReport? applyInitialPlan;
  final ApplyStatistics? applyStatistics;
  final String? quarantinePath;
  final List<String> acceptedRiskCodes;
  final RiskAcceptanceSource riskAcceptanceSource;

  /// Final pass statistics, or empty totals when analysis never completed.
  FindingStatistics get finalFindingStatistics => analysisPasses.isEmpty
      ? FindingStatistics.fromFindings(const [])
      : analysisPasses.last.findingStatistics;

  /// Auxiliary execution contexts from the final completed analysis pass.
  List<AuxiliaryExecutionTarget> get auxiliaryExecutionTargets =>
      analysisPasses.isEmpty
      ? const []
      : analysisPasses.last.auxiliaryExecutionTargets;

  /// Rejected auxiliary target definitions from the final analysis pass.
  List<AuxiliaryExecutionTargetRegistryIssue>
  get auxiliaryExecutionTargetIssues => analysisPasses.isEmpty
      ? const []
      : analysisPasses.last.auxiliaryExecutionTargetIssues;
}

ApplyPreviewComparison _validatedPreviewComparison(
  String? actual,
  String? expected,
  bool hasPlannedFindings,
  ApplyPreviewComparison? supplied,
) {
  if (actual != null && !isValidApplyPreviewFingerprint(actual)) {
    throw StateError('Actual preview fingerprint must be a full v1 token.');
  }
  if (expected != null && !isValidApplyPreviewFingerprint(expected)) {
    throw StateError('Expected preview fingerprint must be a full v1 token.');
  }
  if (expected != null && actual == null) {
    throw StateError('Preview expectation requires captured preview evidence.');
  }
  final derived = expected == null
      ? ApplyPreviewComparison.notRequested
      : hasPlannedFindings && actual == expected
      ? ApplyPreviewComparison.matched
      : ApplyPreviewComparison.mismatched;
  if (supplied != null && supplied != derived) {
    throw StateError('Preview comparison contradicts the captured tokens.');
  }
  return derived;
}

void _validateInitialPlanSelection(
  ApplySelectionReport? selection,
  ApplyInitialPlanReport? initialPlan,
) {
  if (initialPlan == null) {
    if (selection?.actualPreviewFingerprint != null) {
      throw StateError('Captured preview evidence requires an initial plan.');
    }
    return;
  }
  if (selection == null) {
    throw StateError('Initial physical plan requires selection evidence.');
  }
  if (initialPlan.planFingerprint != selection.planFingerprint) {
    throw StateError('Initial plan fingerprint does not match selection.');
  }
  final plannedFindingIds =
      initialPlan.units
          .expand((unit) => unit.findingIds)
          .toList(growable: false)
        ..sort();
  if (!_listEquals(plannedFindingIds, selection.plannedFindingIds)) {
    throw StateError(
      'Initial plan finding union does not match planned selection IDs.',
    );
  }
  final requiredScope = selection.mode == FindingSelectionMode.exact
      ? ApplyInitialPlanScope.completeExactSelection
      : ApplyInitialPlanScope.initialRoundOnly;
  if (initialPlan.scope != requiredScope) {
    throw StateError('Initial plan scope does not match selection mode.');
  }
  if (initialPlan.preview?.fingerprint != selection.actualPreviewFingerprint) {
    throw StateError('Initial plan preview does not match selection evidence.');
  }
}

void _validateNonEmptyUniqueValues(List<String> values, String label) {
  if (values.isEmpty) {
    throw StateError('$label cannot be empty.');
  }
  _validateUniqueValues(values, label);
}

void _validateUniqueValues(List<String> values, String label) {
  if (values.any((value) => value.isEmpty) ||
      values.toSet().length != values.length) {
    throw StateError('$label must contain non-empty unique values.');
  }
}

int _compareSources(
  ApplySourceSnapshotReport left,
  ApplySourceSnapshotReport right,
) {
  final relative = left.projectRelativePath.compareTo(
    right.projectRelativePath,
  );
  return relative != 0
      ? relative
      : left.canonicalPath.compareTo(right.canonicalPath);
}

String _canonicalSourcePathIdentity(String path) =>
    p.posix.isAbsolute(path) ? path : path.toLowerCase();

bool _listEquals<T>(List<T> left, List<T> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}
