import 'package:path/path.dart' as p;

import '../../core/confidence/classification_reason.dart';
import '../../core/confidence/confidence.dart';
import '../../core/confidence/finding.dart';
import '../../core/graph/node.dart';
import '../../core/project/analysis_mode.dart';
import '../../reporting/run_report.dart';
import 'report_formatter.dart';

/// Formats a complete run as concise human-readable text.
class HumanFormatter implements ReportFormatter {
  /// Creates a human formatter.
  const HumanFormatter({
    this.verbose = false,
    this.lineWidth = 160,
    this.reportPath,
    this.reportFormat,
  });

  /// Whether execution timings and exclusion detail are expanded.
  final bool verbose;

  /// Visible terminal width used for responsive layout.
  final int lineWidth;

  /// Report destination displayed after the complete terminal report.
  final String? reportPath;

  /// Format of the report at [reportPath].
  final String? reportFormat;

  @override
  String format(RunReport report) {
    if (report.identity.command == RunCommand.apply) {
      return _formatApply(report);
    }
    final buffer = StringBuffer();
    final pass = report.analysisPasses.isEmpty
        ? null
        : report.analysisPasses.last;
    final warnings = _analysisWarnings(report, pass);
    buffer.writeln(_style('FLUTTER PRUNER', '${_Ansi.bold}${_Ansi.cyan}'));
    buffer.writeln(
      _style(
        '${warnings.isEmpty ? '✓ SCAN COMPLETED' : '⚠ SCAN COMPLETED WITH WARNINGS'} '
        '· ${report.findings.length} ${report.findings.length == 1 ? 'finding' : 'findings'}',
        warnings.isEmpty
            ? '${_Ansi.bold}${_Ansi.green}'
            : '${_Ansi.bold}${_Ansi.yellow}',
      ),
    );

    if (report.findings.isNotEmpty) {
      _writeDecisionSummary(buffer, report.finalFindingStatistics);
    }
    if (warnings.isNotEmpty) {
      buffer.writeln();
      _writeWarnings(buffer, report, pass);
    }

    if (report.findings.isEmpty) {
      buffer.writeln();
      _writeWrapped(
        buffer,
        warnings.isEmpty
            ? 'No unused candidates found under declared coverage.'
            : 'No findings reported. Results may be incomplete until the warnings above are resolved.',
        style: warnings.isEmpty ? _Ansi.green : _Ansi.yellow,
      );
      if (verbose && pass != null) _writeDiagnostics(buffer, report, pass);
      _writeReportNoticeAtEnd(buffer);
      return buffer.toString().trimRight();
    }

    if (pass != null) {
      _writeImpact(buffer, pass.measurements);
      _writeAttention(buffer, pass.blockerStatistics);
    }
    if (!_hasBlockingAnalysisWarning(report, pass)) {
      _writeNextAction(buffer, report);
    }

    buffer.writeln();
    buffer.writeln(
      _style(
        'FINDINGS · ${report.findings.length} reported',
        '${_Ansi.bold}${_Ansi.cyan}',
      ),
    );
    final byConfidence = <Confidence, List<Finding>>{};
    for (final finding in report.findings) {
      (byConfidence[finding.confidence] ??= []).add(finding);
    }
    buffer.writeln();
    _writeFindingsBoard(buffer, report, byConfidence);
    if (verbose && pass != null) _writeDiagnostics(buffer, report, pass);
    _writeReportNoticeAtEnd(buffer);
    return buffer.toString().trimRight();
  }

  String _formatApply(RunReport report) {
    final buffer = StringBuffer();
    final outcomes = report.applyFindingOutcomes;
    final requiresRecovery = _applyRequiresRecovery(report);
    final verificationUnavailable = _hasUnavailableVerification(report);
    final status = _applyStatusPresentation(
      report,
      requiresRecovery: requiresRecovery,
      verificationUnavailable: verificationUnavailable,
    );

    buffer.writeln(_style('FLUTTER PRUNER', '${_Ansi.bold}${_Ansi.cyan}'));
    _writeWrapped(
      buffer,
      '${status.marker} ${status.label} · ${outcomes.length} '
      '${outcomes.length == 1 ? 'outcome' : 'outcomes'}',
      style: '${_Ansi.bold}${status.color}',
    );
    _writeApplyMetrics(buffer, report);

    buffer.writeln();
    buffer.writeln(_style('OUTCOMES', '${_Ansi.bold}${_Ansi.cyan}'));
    buffer.writeln();
    if (outcomes.isEmpty) {
      _writeWrapped(
        buffer,
        report.status == RunStatus.noChanges
            ? 'No actionable findings were found. Nothing was changed.'
            : 'No finding outcomes were recorded for this run.',
        style: _Ansi.dim,
      );
    } else {
      _writeApplyOutcomeBoard(buffer, report);
    }

    buffer.writeln();
    _writeApplyVerification(buffer, report);

    buffer.writeln();
    _writeApplyReversibility(
      buffer,
      report,
      requiresRecovery: requiresRecovery,
    );

    buffer.writeln();
    _writeApplyNextAction(
      buffer,
      report,
      requiresRecovery: requiresRecovery,
      verificationUnavailable: verificationUnavailable,
    );
    _writeReportNoticeAtEnd(buffer);
    return buffer.toString().trimRight();
  }

  void _writeApplyMetrics(StringBuffer buffer, RunReport report) {
    final outcomes = report.applyFindingOutcomes;
    int count(ApplyFindingOutcomeStatus status) =>
        outcomes.where((outcome) => outcome.status == status).length;

    final committed = count(ApplyFindingOutcomeStatus.committed);
    final restored = count(ApplyFindingOutcomeStatus.rejectedRecovered);
    final blocked = count(ApplyFindingOutcomeStatus.blocked);
    final skipped = count(ApplyFindingOutcomeStatus.skippedDependency);
    final remaining = count(ApplyFindingOutcomeStatus.remaining);
    final recovery = count(ApplyFindingOutcomeStatus.recoveryRequired);
    final statistics = report.applyStatistics;
    final recoveryTransactions =
        (statistics?.transactionsRecoveryRequired ?? 0) +
        (statistics?.transactionsNonTerminal ?? 0);
    var recoveryAttention = recovery > recoveryTransactions
        ? recovery
        : recoveryTransactions;
    if (report.status == RunStatus.recoveryRequired && recoveryAttention == 0) {
      recoveryAttention = 1;
    }
    final values = report.status == RunStatus.dryRun
        ? <({String text, String color})>[
            (text: '$remaining ready', color: _Ansi.cyan),
            (
              text: '${blocked + skipped} blocked or retained',
              color: _Ansi.yellow,
            ),
            (text: '0 files changed', color: _Ansi.green),
            (
              text: '$recoveryAttention recovery attention',
              color: _Ansi.magenta,
            ),
          ]
        : <({String text, String color})>[
            (text: '$committed committed', color: _Ansi.green),
            (text: '$restored restored', color: _Ansi.cyan),
            (
              text: '${blocked + skipped + remaining} not applied',
              color: _Ansi.yellow,
            ),
            (
              text: '$recoveryAttention recovery attention',
              color: _Ansi.magenta,
            ),
          ];
    if (lineWidth >= 100) {
      buffer.writeln(
        values.map((value) => _style(value.text, value.color)).join(' · '),
      );
      return;
    }
    for (final value in values) {
      buffer.writeln('  ${_style(value.text, value.color)}');
    }
  }

  bool _applyRequiresRecovery(RunReport report) {
    final statistics = report.applyStatistics;
    return report.status == RunStatus.recoveryRequired ||
        (statistics?.transactionsRecoveryRequired ?? 0) > 0 ||
        (statistics?.transactionsNonTerminal ?? 0) > 0 ||
        report.applyFindingOutcomes.any(
          (outcome) =>
              outcome.status == ApplyFindingOutcomeStatus.recoveryRequired,
        );
  }

  bool _hasUnavailableVerification(RunReport report) =>
      report.verificationAttempts.any((attempt) => !attempt.available) ||
      report.verificationAttempts.any((attempt) => !attempt.complete);

  ({String marker, String label, String color}) _applyStatusPresentation(
    RunReport report, {
    required bool requiresRecovery,
    required bool verificationUnavailable,
  }) {
    if (requiresRecovery) {
      return (
        marker: '⛔',
        label: 'APPLY RECOVERY REQUIRED',
        color: _Ansi.magenta,
      );
    }
    if (report.status == RunStatus.internalError) {
      return (marker: '⛔', label: 'APPLY INTERNAL ERROR', color: _Ansi.magenta);
    }
    if (report.status == RunStatus.interrupted) {
      return (marker: '⚠', label: 'APPLY INTERRUPTED', color: _Ansi.yellow);
    }
    if (verificationUnavailable) {
      return (
        marker: '⚠',
        label: 'APPLY VERIFICATION UNAVAILABLE',
        color: _Ansi.yellow,
      );
    }
    if (report.status == RunStatus.dryRun && _dryRunReadyCount(report) == 0) {
      return (
        marker: '⚠',
        label: 'APPLY PREVIEW BLOCKED · NO FILES CHANGED',
        color: _Ansi.yellow,
      );
    }
    if (report.partialApplied && report.status == RunStatus.safeStopped) {
      return (
        marker: '⚠',
        label: 'APPLY SAFE STOP · RECOVERY ATTENTION',
        color: _Ansi.yellow,
      );
    }
    return switch (report.status) {
      RunStatus.completed => (
        marker: '✓',
        label: 'APPLY COMPLETED',
        color: _Ansi.green,
      ),
      RunStatus.noChanges => (
        marker: '✓',
        label: 'APPLY NO CHANGES',
        color: _Ansi.green,
      ),
      RunStatus.dryRun => (
        marker: '✓',
        label: 'APPLY PREVIEW READY · NO FILES CHANGED',
        color: _Ansi.cyan,
      ),
      RunStatus.safeStopped => (
        marker: '⚠',
        label: 'APPLY STOPPED SAFELY · NO MUTATION RETAINED',
        color: _Ansi.yellow,
      ),
      RunStatus.infrastructureFailure => (
        marker: '⚠',
        label: 'APPLY BLOCKED · INFRASTRUCTURE FAILURE',
        color: _Ansi.yellow,
      ),
      RunStatus.recoveryRequired => (
        marker: '⛔',
        label: 'APPLY RECOVERY REQUIRED',
        color: _Ansi.magenta,
      ),
      RunStatus.internalError => (
        marker: '⛔',
        label: 'APPLY INTERNAL ERROR',
        color: _Ansi.magenta,
      ),
      RunStatus.interrupted => (
        marker: '⚠',
        label: 'APPLY INTERRUPTED',
        color: _Ansi.yellow,
      ),
    };
  }

  void _writeApplyOutcomeBoard(StringBuffer buffer, RunReport report) {
    final byLane = <_ApplyOutcomeLane, List<ApplyFindingOutcome>>{
      for (final lane in _applyPresentationOrder) lane: [],
    };
    for (final outcome in report.applyFindingOutcomes) {
      byLane[_applyOutcomeLane(outcome.status)]!.add(outcome);
    }
    final width = lineWidth < 12 ? 12 : lineWidth;
    if (width < 60) {
      for (final lane in _applyPresentationOrder) {
        _writeCompactApplyLane(buffer, lane, byLane[lane]!, report, width);
      }
      return;
    }

    final columnCount = verbose
        ? 1
        : width >= 200
        ? 4
        : width >= 89
        ? 2
        : 1;
    const gap = ' ';
    final laneWidth = (width - gap.length * (columnCount - 1)) ~/ columnCount;
    for (
      var start = 0;
      start < _applyPresentationOrder.length;
      start += columnCount
    ) {
      final end = start + columnCount > _applyPresentationOrder.length
          ? _applyPresentationOrder.length
          : start + columnCount;
      final rendered = <List<String>>[
        for (final lane in _applyPresentationOrder.sublist(start, end))
          _renderApplyLane(
            lane,
            byLane[lane]!,
            report,
            laneWidth,
            showLimit: verbose
                ? null
                : columnCount > 1
                ? 6
                : 10,
          ),
      ];
      final height = rendered.fold<int>(
        0,
        (current, lane) => lane.length > current ? lane.length : current,
      );
      for (var line = 0; line < height; line++) {
        buffer.writeln(
          rendered
              .map(
                (lane) =>
                    line < lane.length ? lane[line] : _fill(' ', laneWidth),
              )
              .join(gap)
              .trimRight(),
        );
      }
      if (end < _applyPresentationOrder.length) buffer.writeln();
    }
  }

  List<String> _renderApplyLane(
    _ApplyOutcomeLane lane,
    List<ApplyFindingOutcome> outcomes,
    RunReport report,
    int totalWidth, {
    required int? showLimit,
  }) {
    final contentWidth = totalWidth - 2;
    final innerWidth = contentWidth - 2;
    final lines = <String>[
      _border('┌', '┐', contentWidth),
      _laneLine(
        '${_applyLaneIcon(lane)} ${_applyLaneLabel(lane, report)} '
        '(${outcomes.length}) · ${_applyLaneQualifier(lane, report, outcomes)}',
        contentWidth,
        style: '${_Ansi.bold}${_applyLaneColor(lane)}',
      ),
      _border('├', '┤', contentWidth),
    ];
    if (outcomes.isEmpty) {
      lines
        ..add(_laneLine('No findings', contentWidth, style: _Ansi.dim))
        ..add(_border('└', '┘', contentWidth));
      return lines;
    }
    final shown = showLimit == null
        ? outcomes
        : outcomes.take(showLimit).toList(growable: false);
    for (var index = 0; index < shown.length; index++) {
      if (index > 0) lines.add(_border('├', '┤', contentWidth));
      final outcome = shown[index];
      lines
        ..add(_laneLine(outcome.finding.title, contentWidth, style: _Ansi.bold))
        ..add(
          _laneLine(
            _displayOrigin(outcome.finding, report.projectRoot, innerWidth),
            contentWidth,
            style: _Ansi.dim,
          ),
        )
        ..add(
          _laneLine(
            _applyOutcomeStatusLabel(outcome, report),
            contentWidth,
            style: _applyLaneColor(lane),
          ),
        )
        ..add(_laneLine(_fitEnd(outcome.reason, innerWidth), contentWidth));
    }
    if (showLimit != null && outcomes.length > showLimit) {
      lines
        ..add(_border('├', '┤', contentWidth))
        ..add(
          _laneLine(
            '... +${outcomes.length - showLimit} more · use --verbose',
            contentWidth,
            style: _Ansi.dim,
          ),
        );
    }
    lines.add(_border('└', '┘', contentWidth));
    return lines;
  }

  void _writeCompactApplyLane(
    StringBuffer buffer,
    _ApplyOutcomeLane lane,
    List<ApplyFindingOutcome> outcomes,
    RunReport report,
    int width,
  ) {
    buffer.writeln(
      _style(
        _fitEnd(
          '${_applyLaneIcon(lane)} ${_applyLaneLabel(lane, report)} '
          '(${outcomes.length}) · ${_applyLaneQualifier(lane, report, outcomes)}',
          width,
        ),
        '${_Ansi.bold}${_applyLaneColor(lane)}',
      ),
    );
    if (outcomes.isEmpty) {
      buffer.writeln(_style('  No findings', _Ansi.dim));
    }
    final shown = verbose ? outcomes : outcomes.take(10);
    for (final outcome in shown) {
      buffer.writeln(
        '  ${_style(_fitEnd(outcome.finding.title, width - 2), _Ansi.bold)}',
      );
      buffer.writeln(
        _style(
          '    ${_displayOrigin(outcome.finding, report.projectRoot, width - 4)}',
          _Ansi.dim,
        ),
      );
      buffer.writeln(
        '    ${_style(_fitEnd(_applyOutcomeStatusLabel(outcome, report), width - 4), _applyLaneColor(lane))}',
      );
      buffer.writeln('    ${_fitEnd(outcome.reason, width - 4)}');
    }
    if (!verbose && outcomes.length > 10) {
      buffer.writeln(
        _style(
          '  ${_fitEnd('... +${outcomes.length - 10} more · use --verbose', width - 2)}',
          _Ansi.dim,
        ),
      );
    }
    if (lane != _applyPresentationOrder.last) buffer.writeln();
  }

  _ApplyOutcomeLane _applyOutcomeLane(
    ApplyFindingOutcomeStatus status,
  ) => switch (status) {
    ApplyFindingOutcomeStatus.committed => _ApplyOutcomeLane.committed,
    ApplyFindingOutcomeStatus.rejectedRecovered => _ApplyOutcomeLane.restored,
    ApplyFindingOutcomeStatus.blocked ||
    ApplyFindingOutcomeStatus.skippedDependency ||
    ApplyFindingOutcomeStatus.remaining => _ApplyOutcomeLane.notApplied,
    ApplyFindingOutcomeStatus.recoveryRequired => _ApplyOutcomeLane.recovery,
  };

  String _applyLaneLabel(_ApplyOutcomeLane lane, RunReport report) =>
      switch (lane) {
        _ApplyOutcomeLane.committed => 'COMMITTED',
        _ApplyOutcomeLane.restored => 'RESTORED',
        _ApplyOutcomeLane.notApplied =>
          report.status == RunStatus.dryRun ? 'READY / BLOCKED' : 'NOT APPLIED',
        _ApplyOutcomeLane.recovery => 'RECOVERY',
      };

  String _applyLaneQualifier(
    _ApplyOutcomeLane lane,
    RunReport report,
    List<ApplyFindingOutcome> outcomes,
  ) {
    if (lane == _ApplyOutcomeLane.notApplied &&
        report.status == RunStatus.dryRun) {
      final ready = outcomes
          .where(
            (outcome) => outcome.status == ApplyFindingOutcomeStatus.remaining,
          )
          .length;
      final blocked = outcomes.length - ready;
      if (ready > 0 && blocked > 0) return '$ready ready · $blocked blocked';
      if (ready > 0) return '$ready ready · preview only';
      return '$blocked blocked or retained';
    }
    return switch (lane) {
      _ApplyOutcomeLane.committed => 'changes kept',
      _ApplyOutcomeLane.restored => 'rollback verified',
      _ApplyOutcomeLane.notApplied => 'blocked, skipped or remaining',
      _ApplyOutcomeLane.recovery => 'manual action required',
    };
  }

  int _dryRunReadyCount(RunReport report) => report.applyFindingOutcomes
      .where((outcome) => outcome.status == ApplyFindingOutcomeStatus.remaining)
      .length;

  String _applyLaneIcon(_ApplyOutcomeLane lane) => switch (lane) {
    _ApplyOutcomeLane.committed => '✓',
    _ApplyOutcomeLane.restored => '↺',
    _ApplyOutcomeLane.notApplied => '•',
    _ApplyOutcomeLane.recovery => '!',
  };

  String _applyLaneColor(_ApplyOutcomeLane lane) => switch (lane) {
    _ApplyOutcomeLane.committed => _Ansi.green,
    _ApplyOutcomeLane.restored => _Ansi.cyan,
    _ApplyOutcomeLane.notApplied => _Ansi.yellow,
    _ApplyOutcomeLane.recovery => _Ansi.magenta,
  };

  String _applyOutcomeStatusLabel(
    ApplyFindingOutcome outcome,
    RunReport report,
  ) => switch (outcome.status) {
    ApplyFindingOutcomeStatus.committed => 'COMMITTED · change kept',
    ApplyFindingOutcomeStatus.rejectedRecovered =>
      'RESTORED · rollback verified',
    ApplyFindingOutcomeStatus.blocked => 'BLOCKED · no mutation',
    ApplyFindingOutcomeStatus.skippedDependency =>
      'SKIPPED · dependency retained',
    ApplyFindingOutcomeStatus.remaining =>
      report.status == RunStatus.dryRun
          ? 'READY · PREVIEW ONLY'
          : 'NOT APPLIED · remains',
    ApplyFindingOutcomeStatus.recoveryRequired => 'RECOVERY REQUIRED',
  };

  void _writeApplyVerification(StringBuffer buffer, RunReport report) {
    buffer.writeln(_style('VERIFICATION', '${_Ansi.bold}${_Ansi.cyan}'));
    if (report.verificationAttempts.isEmpty) {
      final message = switch (report.status) {
        RunStatus.dryRun => 'Preview only · no verification was run.',
        RunStatus.noChanges => 'No changes · no verification was needed.',
        _ => 'No verification attempts were recorded.',
      };
      _writeWrapped(buffer, message, style: _Ansi.dim);
      return;
    }
    for (final purpose in VerificationAttemptPurpose.values) {
      final attempts = report.verificationAttempts
          .where((attempt) => attempt.purpose == purpose)
          .toList(growable: false);
      if (attempts.isEmpty) continue;
      final accepted = attempts.where((attempt) => attempt.accepted).length;
      final unavailable = attempts
          .where((attempt) => !attempt.available || !attempt.complete)
          .length;
      final rejected = attempts
          .where(
            (attempt) =>
                attempt.available && attempt.complete && !attempt.accepted,
          )
          .length;
      final label = switch (purpose) {
        VerificationAttemptPurpose.baseline => 'Baseline',
        VerificationAttemptPurpose.candidate => 'Candidate',
        VerificationAttemptPurpose.rollback => 'Rollback',
      };
      final status = unavailable > 0
          ? 'UNAVAILABLE'
          : rejected > 0
          ? 'REJECTED'
          : 'ACCEPTED';
      final color = unavailable > 0 || rejected > 0
          ? _Ansi.yellow
          : _Ansi.green;
      _writeLabeledRow(
        buffer,
        icon: unavailable > 0 || rejected > 0 ? '!' : '✓',
        label: label,
        value:
            '$status · ${attempts.length} attempted · $accepted accepted · '
            '$rejected rejected · $unavailable unavailable',
        color: color,
      );
    }
  }

  void _writeApplyReversibility(
    StringBuffer buffer,
    RunReport report, {
    required bool requiresRecovery,
  }) {
    if (requiresRecovery || report.partialApplied) {
      buffer.writeln(
        _style(
          requiresRecovery ? 'RECOVERY' : 'RECOVERY ATTENTION',
          '${_Ansi.bold}${_Ansi.magenta}',
        ),
      );
      _writeWrapped(
        buffer,
        report.partialApplied
            ? 'The compatibility partialApplied flag marks an uncertain '
                  'working-copy state. Inspect the quarantine manifest before '
                  'taking any recovery action; it does not prove changes remain. '
                  'Do not rerun apply.'
            : 'Inspect the quarantine manifest before taking any recovery action. '
                  'Do not rerun apply.',
        style: _Ansi.magenta,
      );
      if (report.quarantinePath != null) {
        _writeLabeledRow(
          buffer,
          icon: '!',
          label: 'Manifest',
          value: _displayLocation(
            p.join(report.quarantinePath!, 'manifest.json'),
            report.projectRoot,
            lineWidth - 16,
          ),
          color: _Ansi.magenta,
        );
      }
      return;
    }
    if (report.status == RunStatus.safeStopped) {
      buffer.writeln(_style('ROLLBACK VERIFIED', '${_Ansi.bold}${_Ansi.cyan}'));
      _writeWrapped(
        buffer,
        'No mutation from this run was retained after verified rollback '
        '(or no mutation began).',
        style: _Ansi.cyan,
      );
      if (report.quarantinePath != null) {
        _writeLabeledRow(
          buffer,
          icon: '↺',
          label: 'Evidence',
          value: _displayLocation(
            p.join(report.quarantinePath!, 'manifest.json'),
            report.projectRoot,
            lineWidth - 16,
          ),
          color: _Ansi.cyan,
        );
      }
      return;
    }
    buffer.writeln(_style('REVERSIBILITY', '${_Ansi.bold}${_Ansi.cyan}'));
    if (report.quarantinePath == null) {
      _writeWrapped(
        buffer,
        report.status == RunStatus.dryRun
            ? 'Preview only · no quarantine was created.'
            : 'No quarantine was created for this run.',
        style: _Ansi.dim,
      );
      return;
    }
    _writeLabeledRow(
      buffer,
      icon: '↺',
      label: 'Quarantine',
      value: _displayLocation(
        report.quarantinePath!,
        report.projectRoot,
        lineWidth - 16,
      ),
      color: _Ansi.cyan,
    );
    _writeWrapped(buffer, 'Rollback command:', style: _Ansi.dim);
    buffer.writeln(
      _style(
        'flutter_pruner rollback --project ${_shellQuote(report.projectRoot)} '
            '--quarantine ${_shellQuote(p.dirname(report.quarantinePath!))} '
            '${_shellQuote(report.identity.id)}',
        '${_Ansi.bold}${_Ansi.cyan}',
      ),
    );
  }

  void _writeApplyNextAction(
    StringBuffer buffer,
    RunReport report, {
    required bool requiresRecovery,
    required bool verificationUnavailable,
  }) {
    buffer.writeln(_style('NEXT ACTION', '${_Ansi.bold}${_Ansi.cyan}'));
    final action = requiresRecovery
        ? 'Inspect the quarantine manifest; recover deliberately. Do not rerun apply.'
        : verificationUnavailable
        ? 'Restore verification availability before attempting another apply.'
        : switch (report.status) {
            RunStatus.completed =>
              'Review the committed changes and retain the quarantine until accepted.',
            RunStatus.noChanges => 'No action required.',
            RunStatus.dryRun =>
              _dryRunReadyCount(report) > 0
                  ? 'Review this preview, then rerun the reviewed invocation without --dry-run.'
                  : 'Resolve blocked or retained findings before attempting apply.',
            RunStatus.safeStopped =>
              report.partialApplied
                  ? 'Inspect the quarantine manifest before another apply; '
                        'the working-copy evidence is uncertain.'
                  : 'Re-scan, then resolve blocked or remaining findings before '
                        'another apply.',
            RunStatus.infrastructureFailure =>
              'Restore the required infrastructure before attempting apply again.',
            RunStatus.recoveryRequired =>
              'Inspect the quarantine manifest; recover deliberately. Do not rerun apply.',
            RunStatus.internalError =>
              reportPath == null
                  ? report.quarantinePath == null
                        ? 'Inspect the terminal diagnostics before attempting another apply.'
                        : 'Inspect the terminal diagnostics and quarantine before attempting another apply.'
                  : 'Inspect the report and diagnostics before attempting another apply.',
            RunStatus.interrupted =>
              'Inspect the report before deciding whether another apply is safe.',
          };
    _writeLabeledRow(
      buffer,
      icon: requiresRecovery ? '!' : '→',
      label: 'Action',
      value: action,
      color: requiresRecovery ? _Ansi.magenta : _Ansi.green,
    );
  }

  String _shellQuote(String value) => "'${value.replaceAll("'", "'\"'\"'")}'";

  void _writeReportNoticeAtEnd(StringBuffer buffer) {
    if (reportPath == null) return;
    buffer.writeln();
    _writeReportNotice(buffer, reportPath!, reportFormat);
  }

  void _writeReportNotice(StringBuffer buffer, String path, String? format) {
    final label = switch (format) {
      'html' => 'HTML REPORT READY',
      'json' => 'JSON REPORT READY',
      _ => 'TEXT REPORT READY',
    };
    buffer.writeln(_style('✓ $label', '${_Ansi.bold}${_Ansi.green}'));
    buffer.writeln(path);
  }

  void _writeDecisionSummary(
    StringBuffer buffer,
    FindingStatistics statistics,
  ) {
    final summaries = <({String text, String color})>[
      (
        text: '${statistics.byTier['SAFE'] ?? 0} ready to preview',
        color: _Ansi.green,
      ),
      (
        text: '${statistics.byTier['HIGH'] ?? 0} require opt-in',
        color: _Ansi.yellow,
      ),
      (
        text: '${statistics.byTier['REVIEW'] ?? 0} need inspection',
        color: _Ansi.cyan,
      ),
      (
        text: '${statistics.byTier['PROTECTED'] ?? 0} kept',
        color: _Ansi.magenta,
      ),
    ];
    if (lineWidth >= 100) {
      buffer.writeln(
        summaries
            .map((summary) => _style(summary.text, summary.color))
            .join(' · '),
      );
      return;
    }
    for (final summary in summaries) {
      buffer.writeln('  ${_style(summary.text, summary.color)}');
    }
  }

  void _writeWarnings(
    StringBuffer buffer,
    RunReport report,
    AnalysisPassReport? pass,
  ) {
    buffer.writeln(_style('ANALYSIS LIMITED', '${_Ansi.bold}${_Ansi.yellow}'));
    if (!report.targetMatrix.isComplete) {
      _writeLabeledRow(
        buffer,
        icon: '!',
        label: 'Targets',
        value: 'Incomplete · SAFE/HIGH disabled',
        detail:
            'Add every supported platform, flavor and entrypoint to '
            '.flutter_pruner/config.yaml.',
        color: _Ansi.yellow,
      );
    }
    final packageAuditOnly = report.analysisMode == AnalysisMode.package;
    final packageInternal = report.analysisMode == AnalysisMode.packageInternal;
    if (!report.rootCoverage.internalBoundaryComplete) {
      _writeLabeledRow(
        buffer,
        icon: '!',
        label: 'Entry roots',
        value: 'Incomplete · SAFE/HIGH disabled',
        detail: report.rootCoverage.issues.isEmpty
            ? 'Declare every root in .flutter_pruner/config.yaml.'
            : report.rootCoverage.issues.map(_sentenceCase).join(' · '),
        color: _Ansi.yellow,
      );
    } else if (!report.rootCoverage.externalConsumersCovered) {
      if (packageAuditOnly) {
        _writeLabeledRow(
          buffer,
          icon: '!',
          label: 'Consumers',
          value: 'Open world · audit only',
          detail:
              'Reusable packages may have external consumers that this scan '
              'cannot see.',
          color: _Ansi.yellow,
        );
      } else if (packageInternal) {
        _writeLabeledRow(
          buffer,
          icon: '!',
          label: 'Boundary',
          value: 'Package-internal · external consumers not scanned',
          detail:
              'Private local findings may be SAFE; externally addressable '
              'findings are HIGH and require confirmation before mutation.',
          color: _Ansi.yellow,
        );
      }
    }
    final danglingEdges = pass?.danglingEdgeCount ?? 0;
    final danglingRoots = pass?.danglingRootCount ?? 0;
    if (danglingEdges > 0 || danglingRoots > 0) {
      final unresolvedFacts = [
        if (danglingEdges > 0)
          '$danglingEdges unresolved '
              '${danglingEdges == 1 ? 'reference' : 'references'}',
        if (danglingRoots > 0)
          '$danglingRoots unresolved '
              '${danglingRoots == 1 ? 'root' : 'roots'}',
      ];
      _writeLabeledRow(
        buffer,
        icon: '!',
        label: 'Graph',
        value: '${unresolvedFacts.join(' · ')} · results downgraded',
        detail: danglingRoots > 0
            ? 'Configured roots point to unregistered nodes; some findings '
                  'may be missing or require manual review.'
            : 'Some findings may be missing or require manual review.',
        color: _Ansi.yellow,
      );
    }
    final next = packageAuditOnly
        ? 'Validate REVIEW findings against external consumers; do not apply '
              'them automatically.'
        : !report.targetMatrix.isComplete ||
              !report.rootCoverage.internalBoundaryComplete
        ? 'Run flutter_pruner init, review .flutter_pruner/config.yaml, then re-scan.'
        : 'Run flutter_pruner --verbose scan to inspect diagnostics before '
              'applying changes.';
    _writeLabeledRow(
      buffer,
      icon: '→',
      label: 'Next',
      value: next,
      color: _Ansi.yellow,
    );
  }

  void _writeImpact(StringBuffer buffer, List<RunMeasurement> measurements) {
    String? duplicateImpact;
    String? assetInventory;
    for (final measurement in measurements) {
      if (measurement.status != MeasurementStatus.measured ||
          measurement.value == null ||
          measurement.value == 0) {
        continue;
      }
      switch (measurement.kind) {
        case 'duplicate-potential-reclaimable-bytes':
          duplicateImpact =
              'Up to ${_formatBytes(measurement.value!)} reclaimable';
        case 'asset-family-source-bytes':
          assetInventory = '${_formatBytes(measurement.value!)} scanned';
      }
    }
    if (duplicateImpact == null && assetInventory == null) return;
    buffer.writeln();
    buffer.writeln(_style('POTENTIAL IMPACT', '${_Ansi.bold}${_Ansi.cyan}'));
    if (duplicateImpact != null) {
      _writeLabeledRow(
        buffer,
        icon: '◆',
        label: 'Duplicates',
        value: duplicateImpact,
        color: _Ansi.cyan,
      );
    }
    if (assetInventory != null) {
      _writeLabeledRow(
        buffer,
        icon: '◇',
        label: 'Assets',
        value: assetInventory,
        detail: 'Inventory only · not estimated savings',
        color: _Ansi.cyan,
      );
    }
  }

  void _writeAttention(StringBuffer buffer, BlockerStatistics statistics) {
    if (statistics.affectedFindings == 0) return;
    buffer.writeln();
    buffer.writeln(_style('NEEDS REVIEW', '${_Ansi.bold}${_Ansi.cyan}'));
    _writeLabeledRow(
      buffer,
      icon: '?',
      label: 'References',
      value:
          '${statistics.affectedFindings} '
          '${statistics.affectedFindings == 1 ? 'finding' : 'findings'} affected '
          '· manual inspection required',
      color: _Ansi.yellow,
    );
  }

  void _writeNextAction(StringBuffer buffer, RunReport report) {
    final stats = report.finalFindingStatistics.byTier;
    final project = _quotedProject(report.projectRoot);
    final String label;
    final String? command;
    if (report.analysisMode == AnalysisMode.package ||
        !report.targetMatrix.isComplete ||
        !report.rootCoverage.internalBoundaryComplete) {
      return;
    } else if ((stats['SAFE'] ?? 0) > 0) {
      label = 'Preview SAFE changes';
      command = 'flutter_pruner apply --dry-run --project $project';
    } else if ((stats['HIGH'] ?? 0) > 0) {
      label = 'Preview eligible HIGH findings';
      command = 'flutter_pruner apply --dry-run --project $project';
    } else if ((stats['REVIEW'] ?? 0) > 0) {
      label = 'Inspect REVIEW findings and resolve the reasons below';
      command = null;
    } else {
      label = 'No automatic changes are available';
      command = null;
    }
    buffer.writeln();
    buffer.writeln(_style('NEXT ACTION', '${_Ansi.bold}${_Ansi.cyan}'));
    _writeLabeledRow(
      buffer,
      icon: '→',
      label: 'Action',
      value: label,
      color: _Ansi.green,
    );
    if (command != null) {
      _writeWrapped(
        buffer,
        command,
        indent: '    ',
        style: '${_Ansi.bold}${_Ansi.green}',
      );
    }
  }

  String _quotedProject(String path) => '"${path.replaceAll('"', r'\"')}"';

  void _writeAdapterMatrix(StringBuffer buffer, AnalysisPassReport pass) {
    buffer.writeln(
      _style(
        'Adapter       Role       SAFE HIGH REVIEW PROTECTED  Findings  Time',
        '${_Ansi.bold}${_Ansi.cyan}',
      ),
    );
    for (final adapter in pass.adapterRuns) {
      final findingCount =
          pass.findingStatistics.byReportingAdapter[adapter.id] ?? 0;
      final adapterFindings = adapter.role == AdapterRunRole.reporting
          ? findingCount
          : 0;
      final tiers =
          pass.findingStatistics.byReportingAdapterAndTier[adapter.id] ??
          {for (final tier in Confidence.values) tier.label: 0};
      final time = '${(adapter.elapsedMicros / 1000).toStringAsFixed(0)}ms';
      buffer.writeln(
        '${adapter.id.padRight(13)}'
        '${adapter.role.name.padRight(11)}'
        '${tiers['SAFE'].toString().padLeft(4)} '
        '${tiers['HIGH'].toString().padLeft(4)} '
        '${tiers['REVIEW'].toString().padLeft(6)} '
        '${tiers['PROTECTED'].toString().padLeft(9)}  '
        '${adapterFindings.toString().padLeft(8)}  $time',
      );
    }
    final stats = pass.findingStatistics;
    buffer.writeln(
      '${'TOTAL'.padRight(24)}'
      '${(stats.byTier['SAFE'] ?? 0).toString().padLeft(4)} '
      '${(stats.byTier['HIGH'] ?? 0).toString().padLeft(4)} '
      '${(stats.byTier['REVIEW'] ?? 0).toString().padLeft(6)} '
      '${(stats.byTier['PROTECTED'] ?? 0).toString().padLeft(9)}  '
      '${stats.total.toString().padLeft(8)}',
    );
  }

  void _writeMeasurements(
    StringBuffer buffer,
    RunReport report,
    List<RunMeasurement> measurements,
  ) {
    buffer.writeln('Measurements (rows are not additive)');
    for (final measurement in measurements) {
      final value = measurement.status == MeasurementStatus.measured
          ? _formatBytes(measurement.value!)
          : measurement.status.name;
      buffer.writeln(
        '  ${_measurementLabel(report, measurement)}: '
        '$value (${measurement.scope})',
      );
    }
    if (measurements.isEmpty) buffer.writeln('  none');
  }

  String _measurementLabel(RunReport report, RunMeasurement measurement) {
    for (final adapter in report.adapterReportDefinitions) {
      if (adapter.adapterId != measurement.adapterId) continue;
      return adapter.measurementFor(measurement.kind)?.label ??
          measurement.kind;
    }
    return measurement.kind;
  }

  void _writeDiagnostics(
    StringBuffer buffer,
    RunReport report,
    AnalysisPassReport pass,
  ) {
    buffer.writeln();
    buffer.writeln(_style('DIAGNOSTICS', '${_Ansi.bold}${_Ansi.cyan}'));
    buffer.writeln(
      'Run: ${report.identity.id} · ${report.status.name} · '
      '${(report.identity.elapsedMicros / 1000).toStringAsFixed(0)}ms',
    );
    buffer.writeln();
    _writeAdapterMatrix(buffer, pass);
    buffer.writeln();
    _writeMeasurements(buffer, report, pass.measurements);
    buffer.writeln();
    buffer.writeln(
      'Blockers: ${pass.blockerStatistics.activeUnique} active unique; '
      'affect ${pass.blockerStatistics.affectedFindings} findings '
      '(${pass.blockerStatistics.recorded} recorded)',
    );
    final excluded = pass.exclusionsByReason.values.fold<int>(
      0,
      (sum, count) => sum + count,
    );
    buffer.writeln(
      'Exclusions: $excluded observed paths · '
      'policy v${pass.exclusionPolicyVersion}',
    );
    for (final entry in pass.exclusionsByReason.entries) {
      buffer.writeln('  ${entry.key}: ${entry.value}');
    }
    buffer.writeln(
      'Graph: ${pass.nodeCount} nodes · ${pass.edgeCount} edges · '
      '${pass.rootCount} roots · ${pass.danglingEdgeCount} dangling edges · '
      '${pass.danglingRootCount} dangling roots',
    );
  }

  void _writeFindingsBoard(
    StringBuffer buffer,
    RunReport report,
    Map<Confidence, List<Finding>> byConfidence,
  ) {
    final width = lineWidth < 12 ? 12 : lineWidth;
    if (width < 60) {
      for (final confidence in _presentationOrder) {
        final findings = [...byConfidence[confidence] ?? const <Finding>[]]
          ..sort((left, right) => _compareFindings(confidence, left, right));
        _writeCompactLane(buffer, confidence, findings, report, width);
      }
      return;
    }

    final columnCount = verbose
        ? 1
        : width >= 200
        ? 4
        : width >= 89
        ? 2
        : 1;
    const gap = ' ';
    final laneWidth = (width - gap.length * (columnCount - 1)) ~/ columnCount;
    for (
      var start = 0;
      start < _presentationOrder.length;
      start += columnCount
    ) {
      final end = start + columnCount > _presentationOrder.length
          ? _presentationOrder.length
          : start + columnCount;
      final rendered = <List<String>>[];
      final showLimit = verbose
          ? null
          : columnCount > 1
          ? 6
          : 10;
      for (final confidence in _presentationOrder.sublist(start, end)) {
        final findings = [...byConfidence[confidence] ?? const <Finding>[]]
          ..sort((left, right) => _compareFindings(confidence, left, right));
        rendered.add(
          _renderLane(
            confidence,
            findings,
            report,
            laneWidth,
            showLimit: showLimit,
          ),
        );
      }
      final height = rendered.fold<int>(
        0,
        (current, lane) => lane.length > current ? lane.length : current,
      );
      for (var line = 0; line < height; line++) {
        buffer.writeln(
          rendered
              .map(
                (lane) =>
                    line < lane.length ? lane[line] : _fill(' ', laneWidth),
              )
              .join(gap)
              .trimRight(),
        );
      }
      if (end < _presentationOrder.length) buffer.writeln();
    }
  }

  List<String> _renderLane(
    Confidence confidence,
    List<Finding> findings,
    RunReport report,
    int totalWidth, {
    required int? showLimit,
  }) {
    final contentWidth = totalWidth - 2;
    final innerWidth = contentWidth - 2;
    final lines = <String>[
      _border('┌', '┐', contentWidth),
      _laneLine(
        '${_tierIcon(confidence)} ${confidence.label} (${findings.length}) · '
        '${_tierQualifier(confidence)}',
        contentWidth,
        style: '${_Ansi.bold}${_tierColor(confidence)}',
      ),
      _border('├', '┤', contentWidth),
    ];
    if (findings.isEmpty) {
      lines
        ..add(_laneLine('No findings', contentWidth, style: _Ansi.dim))
        ..add(_border('└', '┘', contentWidth));
      return lines;
    }

    final shown = showLimit == null
        ? findings
        : findings.take(showLimit).toList(growable: false);
    for (var index = 0; index < shown.length; index++) {
      if (index > 0) lines.add(_border('├', '┤', contentWidth));
      final finding = shown[index];
      lines
        ..add(_laneLine(finding.title, contentWidth, style: _Ansi.bold))
        ..add(
          _laneLine(
            _displayOrigin(finding, report.projectRoot, innerWidth),
            contentWidth,
            style: _Ansi.dim,
          ),
        );
      final metadata = _findingMetadata(finding);
      if (metadata != null) {
        lines.add(
          _laneLine(metadata, contentWidth, style: _tierColor(confidence)),
        );
      }

      if (finding.node.kind.name == 'duplicateGroup') {
        final paths =
            (finding.node.metadata['paths'] as List<Object?>? ?? const [])
                .whereType<String>()
                .toList();
        final pathLimit = verbose ? paths.length : 5;
        for (final duplicatePath in paths.take(pathLimit)) {
          lines.add(
            _laneLine(
              '- ${_displayLocation(duplicatePath, report.projectRoot, innerWidth - 2)}',
              contentWidth,
              style: _Ansi.dim,
            ),
          );
        }
        if (paths.length > pathLimit) {
          lines.add(
            _laneLine(
              '... ${paths.length - pathLimit} more paths',
              contentWidth,
              style: _Ansi.dim,
            ),
          );
        }
      }

      final details = _findingDetails(
        finding,
        report.projectRoot,
        innerWidth - 2,
      );
      final shownDetails = verbose ? details : details.take(1);
      for (final detail in shownDetails) {
        final remaining = !verbose && details.length > 1
            ? ' · +${details.length - 1} more'
            : '';
        lines.add(
          _laneLine(
            '${finding.confidence == Confidence.safe ? '→' : '↳'} '
            '$detail$remaining',
            contentWidth,
          ),
        );
      }
    }
    if (showLimit != null && findings.length > showLimit) {
      lines
        ..add(_border('├', '┤', contentWidth))
        ..add(
          _laneLine(
            '... +${findings.length - showLimit} more · use --verbose',
            contentWidth,
            style: _Ansi.dim,
          ),
        );
    }
    lines.add(_border('└', '┘', contentWidth));
    return lines;
  }

  void _writeCompactLane(
    StringBuffer buffer,
    Confidence confidence,
    List<Finding> findings,
    RunReport report,
    int width,
  ) {
    buffer.writeln(
      _style(
        _fitEnd(
          '${_tierIcon(confidence)} ${confidence.label} (${findings.length}) · '
          '${_tierQualifier(confidence)}',
          width,
        ),
        '${_Ansi.bold}${_tierColor(confidence)}',
      ),
    );
    if (findings.isEmpty) {
      buffer.writeln(
        _style('  ${_fitEnd('No findings', width - 2)}', _Ansi.dim),
      );
    }
    final showLimit = verbose ? findings.length : 10;
    for (final finding in findings.take(showLimit)) {
      buffer.writeln(
        '  ${_style(_fitEnd(finding.title, width - 2), _Ansi.bold)}',
      );
      buffer.writeln(
        _style(
          '    ${_displayOrigin(finding, report.projectRoot, width - 4)}',
          _Ansi.dim,
        ),
      );
      final details = _findingDetails(finding, report.projectRoot, width - 6);
      final shownDetails = verbose ? details : details.take(1);
      for (final detail in shownDetails) {
        final remaining = !verbose && details.length > 1
            ? ' · +${details.length - 1} more'
            : '';
        buffer.writeln('    ↳ ${_fitEnd('$detail$remaining', width - 6)}');
      }
    }
    if (findings.length > showLimit) {
      buffer.writeln(
        _style(
          '  ${_fitEnd('... +${findings.length - showLimit} more · use --verbose', width - 2)}',
          _Ansi.dim,
        ),
      );
    }
    if (confidence != _presentationOrder.last) buffer.writeln();
  }

  List<String> _findingDetails(
    Finding finding,
    String projectRoot,
    int maxWidth,
  ) {
    if (finding.confidence == Confidence.safe) {
      return finding.proposedAction == null
          ? const []
          : [_fitEnd(finding.proposedAction!, maxWidth)];
    }
    final details = <String>[];
    if (finding.confidence == Confidence.protected) {
      details.addAll(finding.protectionReasons);
    }
    for (final blocker in finding.blockers) {
      if (blocker.location == null) {
        details.add(blocker.reason);
        continue;
      }
      final prefix = '${blocker.reason} at ';
      var locationWidth = maxWidth - _runeLength(prefix);
      if (locationWidth < 12) locationWidth = maxWidth ~/ 2;
      final prefixWidth = maxWidth - locationWidth;
      details.add(
        '${_fitEnd(prefix, prefixWidth)}'
        '${_displayLocation(blocker.location!, projectRoot, locationWidth)}',
      );
    }
    for (final reason in finding.classificationReasons) {
      if (finding.blockers.isNotEmpty &&
          reason == ClassificationReason.dynamicReference) {
        continue;
      }
      details.add(reason.humanDescription);
    }
    if (details.isEmpty && finding.whyNotSafe != null) {
      details.add(finding.whyNotSafe!);
    }
    if (details.isEmpty && finding.confidence == Confidence.protected) {
      details.add('Protected from automatic changes');
    }
    return details.map((detail) => _fitEnd(detail, maxWidth)).toSet().toList();
  }

  String? _findingMetadata(Finding finding) {
    final sourceBytes = finding.sourceBytes;
    return switch (finding.node.kind) {
      NodeKind.asset =>
        sourceBytes == null
            ? 'Asset · size unavailable'
            : 'Asset · ${_formatBytes(sourceBytes)} source',
      NodeKind.duplicateGroup =>
        sourceBytes == null
            ? 'Duplicate group · size unavailable'
            : 'Duplicate group · up to ${_formatBytes(sourceBytes)} reclaimable',
      NodeKind.route => switch (finding.node.metadata['path']) {
        final String path => 'Route · $path',
        _ => 'Route',
      },
      _ => null,
    };
  }

  String _displayOrigin(Finding finding, String projectRoot, int maxWidth) {
    final origin = finding.node.origin;
    final value = origin.scheme == 'file'
        ? _relativeFilePath(origin.toFilePath(), projectRoot)
        : origin.toString();
    return _middleTrimPath(value, maxWidth);
  }

  String _displayLocation(String location, String projectRoot, int maxWidth) {
    final match = _sourceLocationPattern.firstMatch(location);
    final path = match?.group(1) ?? location;
    final suffix = match?.group(2) ?? '';
    final value = path.startsWith('file:')
        ? _relativeFileUri(path, projectRoot)
        : _relativeFilePath(path, projectRoot);
    return _middleTrimPath('$value$suffix', maxWidth);
  }

  String _relativeFileUri(String value, String projectRoot) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.scheme != 'file') return value;
    return _relativeFilePath(uri.toFilePath(), projectRoot);
  }

  String _relativeFilePath(String value, String projectRoot) {
    if (!p.isAbsolute(value)) return value.replaceAll(r'\', '/');
    final normalizedRoot = p.normalize(projectRoot);
    final normalizedValue = p.normalize(value);
    if (normalizedValue == normalizedRoot) return '.';
    if (p.isWithin(normalizedRoot, normalizedValue)) {
      return p
          .relative(normalizedValue, from: normalizedRoot)
          .replaceAll(r'\', '/');
    }
    return normalizedValue.replaceAll(r'\', '/');
  }

  String _middleTrimPath(String value, int maxWidth) {
    if (_runeLength(value) <= maxWidth) return value;
    if (maxWidth <= 3) return _takeStart(value, maxWidth);

    final match = _sourceLocationPattern.firstMatch(value);
    final path = match?.group(1) ?? value;
    final suffix = match?.group(2) ?? '';
    final normalized = path.replaceAll(r'\', '/');
    final parts = normalized
        .split('/')
        .where((part) => part.isNotEmpty)
        .toList();
    if (parts.length >= 5) {
      final candidates = <String>[
        '${parts.take(2).join('/')}/.../${parts.skip(parts.length - 2).join('/')}$suffix',
        '${parts.first}/.../${parts.skip(parts.length - 2).join('/')}$suffix',
        '.../${parts.skip(parts.length - 2).join('/')}$suffix',
      ];
      for (final candidate in candidates) {
        if (_runeLength(candidate) <= maxWidth) return candidate;
      }
    }

    final basename = parts.isEmpty ? normalized : parts.last;
    final compactPrefix = parts.length > 1 ? '.../' : '';
    final available =
        maxWidth - _runeLength(compactPrefix) - _runeLength(suffix);
    if (available > 0) {
      return '$compactPrefix${_trimFileName(basename, available)}$suffix';
    }
    return _middleTrimText(value, maxWidth);
  }

  String _trimFileName(String value, int maxWidth) {
    if (_runeLength(value) <= maxWidth) return value;
    final dot = value.lastIndexOf('.');
    if (dot <= 0) return _middleTrimText(value, maxWidth);
    final extension = value.substring(dot);
    final stem = value.substring(0, dot);
    final stemWidth = maxWidth - _runeLength(extension);
    if (stemWidth < 4) return _middleTrimText(value, maxWidth);
    return '${_middleTrimText(stem, stemWidth)}$extension';
  }

  String _middleTrimText(String value, int maxWidth) {
    if (_runeLength(value) <= maxWidth) return value;
    if (maxWidth <= 3) return _takeStart(value, maxWidth);
    final available = maxWidth - 3;
    final left = (available + 1) ~/ 2;
    final right = available - left;
    return '${_takeStart(value, left)}...${_takeEnd(value, right)}';
  }

  String _fitEnd(String value, int maxWidth) {
    if (_runeLength(value) <= maxWidth) return value;
    if (maxWidth <= 3) return _takeStart(value, maxWidth);
    return '${_takeStart(value, maxWidth - 3)}...';
  }

  String _laneLine(String value, int width, {String style = ''}) {
    final innerWidth = width - 2;
    final fitted = _fitEnd(value, innerWidth);
    final padded = '$fitted${_fill(' ', innerWidth - _runeLength(fitted))}';
    return '${_style('│', _Ansi.dim)} ${_style(padded, style)} '
        '${_style('│', _Ansi.dim)}';
  }

  String _border(String left, String right, int width) =>
      _style('$left${_fill('─', width)}$right', _Ansi.dim);

  String _tierIcon(Confidence confidence) => switch (confidence) {
    Confidence.safe => '✓',
    Confidence.high => '▲',
    Confidence.review => '?',
    Confidence.protected => '◆',
  };

  String _tierQualifier(Confidence confidence) => switch (confidence) {
    Confidence.safe => 'ready to preview',
    Confidence.high => 'review before opt-in',
    Confidence.review => 'manual inspection',
    Confidence.protected => 'always kept',
  };

  int _compareFindings(Confidence confidence, Finding left, Finding right) {
    if (confidence == Confidence.safe || confidence == Confidence.high) {
      final sizeCompare = (right.sourceBytes ?? -1).compareTo(
        left.sourceBytes ?? -1,
      );
      if (sizeCompare != 0) return sizeCompare;
    }
    return left.node.origin.toString().compareTo(right.node.origin.toString());
  }

  String _tierColor(Confidence confidence) => switch (confidence) {
    Confidence.safe => _Ansi.green,
    Confidence.high => _Ansi.yellow,
    Confidence.review => _Ansi.cyan,
    Confidence.protected => _Ansi.magenta,
  };

  String _style(String value, String style) =>
      style.isEmpty ? value : '$style$value${_Ansi.reset}';

  void _writeLabeledRow(
    StringBuffer buffer, {
    required String icon,
    required String label,
    required String value,
    required String color,
    String? detail,
  }) {
    const labelWidth = 12;
    final paddedLabel = label.padRight(labelWidth);
    final visiblePrefix = '  $icon $paddedLabel ';
    final styledPrefix =
        '  ${_style(icon, color)} '
        '${_style(paddedLabel, '${_Ansi.bold}$color')} ';
    if (_runeLength(visiblePrefix) + _runeLength(value) <= lineWidth) {
      buffer.writeln('$styledPrefix$value');
    } else {
      buffer.writeln(styledPrefix.trimRight());
      _writeWrapped(buffer, value, indent: '    ');
    }
    if (detail != null) {
      _writeWrapped(buffer, detail, indent: '    ', style: _Ansi.dim);
    }
  }

  void _writeWrapped(
    StringBuffer buffer,
    String value, {
    String indent = '',
    String style = '',
  }) {
    final remainingWidth = lineWidth - _runeLength(indent);
    final available = remainingWidth > 0 ? remainingWidth : 1;
    final words = value.split(RegExp(r'\s+'));
    var line = '';
    for (final word in words) {
      final candidate = line.isEmpty ? word : '$line $word';
      if (_runeLength(candidate) <= available) {
        line = candidate;
        continue;
      }
      if (line.isNotEmpty) buffer.writeln(_style('$indent$line', style));
      line = _runeLength(word) <= available ? word : _fitEnd(word, available);
    }
    if (line.isNotEmpty) buffer.writeln(_style('$indent$line', style));
  }

  String _fill(String value, int count) =>
      count <= 0 ? '' : List.filled(count, value).join();

  int _runeLength(String value) => value.runes.length;

  String _takeStart(String value, int count) =>
      String.fromCharCodes(value.runes.take(count));

  String _takeEnd(String value, int count) {
    if (count <= 0) return '';
    final runes = value.runes.toList();
    return String.fromCharCodes(runes.skip(runes.length - count));
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KiB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  List<String> _analysisWarnings(RunReport report, AnalysisPassReport? pass) {
    final warnings = <String>[];
    if (!report.targetMatrix.isComplete) {
      warnings.add(
        'Target coverage is incomplete; add every supported platform, '
        'flavor and entrypoint to .flutter_pruner/config.yaml. '
        'SAFE and HIGH are disabled.',
      );
    }
    if (!report.rootCoverage.internalBoundaryComplete) {
      if (report.rootCoverage.issues.isEmpty) {
        warnings.add(
          'Entry-root coverage is incomplete; declare every externally '
          'reachable root in .flutter_pruner/config.yaml.',
        );
      } else {
        warnings.addAll(
          report.rootCoverage.issues.map(
            (issue) => '${_sentenceCase(issue)}; SAFE and HIGH are disabled.',
          ),
        );
      }
    } else if (report.analysisMode == AnalysisMode.package) {
      warnings.add(
        'Reusable-package consumers are not scanned; package mode is '
        'review-only and cannot be applied.',
      );
    } else if (report.analysisMode == AnalysisMode.packageInternal) {
      warnings.add(
        'Package-internal boundary only; external consumers were not scanned.',
      );
    }
    final danglingEdges = pass?.danglingEdgeCount ?? 0;
    if (danglingEdges > 0) {
      warnings.add(
        '$danglingEdges graph '
        '${danglingEdges == 1 ? 'reference could' : 'references could'} not '
        'be resolved; findings may be missing or downgraded.',
      );
    }
    final danglingRoots = pass?.danglingRootCount ?? 0;
    if (danglingRoots > 0) {
      warnings.add(
        '$danglingRoots graph '
        '${danglingRoots == 1 ? 'root points' : 'roots point'} to '
        'unregistered nodes; findings are downgraded.',
      );
    }
    return warnings;
  }

  bool _hasBlockingAnalysisWarning(
    RunReport report,
    AnalysisPassReport? pass,
  ) =>
      report.analysisMode == AnalysisMode.package ||
      !report.targetMatrix.isComplete ||
      !report.rootCoverage.internalBoundaryComplete ||
      (pass?.danglingEdgeCount ?? 0) > 0 ||
      (pass?.danglingRootCount ?? 0) > 0;

  String _sentenceCase(String value) {
    if (value.isEmpty) return value;
    return '${value[0].toUpperCase()}${value.substring(1)}';
  }

  static final RegExp _sourceLocationPattern = RegExp(
    r'^(.*?)(:\d+(?::\d+)?)$',
  );

  static const List<Confidence> _presentationOrder = [
    Confidence.safe,
    Confidence.high,
    Confidence.review,
    Confidence.protected,
  ];

  static const List<_ApplyOutcomeLane> _applyPresentationOrder = [
    _ApplyOutcomeLane.committed,
    _ApplyOutcomeLane.restored,
    _ApplyOutcomeLane.notApplied,
    _ApplyOutcomeLane.recovery,
  ];
}

enum _ApplyOutcomeLane { committed, restored, notApplied, recovery }

abstract final class _Ansi {
  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String cyan = '\x1B[36m';
  static const String magenta = '\x1B[35m';
}
