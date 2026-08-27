import 'dart:convert';

import '../../quarantine/quarantine_clean_executor.dart';
import '../../quarantine/quarantine_manager.dart';
import '../../quarantine/recoverable_clean_inspection.dart';
import '../../quarantine/recoverable_clean_store.dart';
import '../terminal_text_metrics.dart';

/// Renders read-only quarantine inventory and inspection evidence.
abstract final class QuarantineFormatter {
  /// Default maximum number of inventory records written by `quarantine list`.
  static const defaultListLimit = 50;
  static const _metrics = TerminalTextMetrics();

  /// Renders complete clean-plan evidence without granting delete authority.
  static String formatCleanPlanHuman(
    QuarantineCleanPlan plan, {
    int lineWidth = 160,
  }) {
    final buffer = StringBuffer()
      ..writeln(_heading('QUARANTINE CLEAN PREVIEW'))
      ..writeln('')
      ..writeln('  Scope: ${terminalSafe(plan.scope.name)}')
      ..writeln('  Targets: ${plan.targets.length}')
      ..writeln('  Fingerprint: ${terminalSafe(plan.fingerprint)}');
    for (final base in plan.canonicalBases) {
      buffer.writeln('  Canonical base: ${terminalSafe(base)}');
    }
    buffer
      ..writeln('  Backend: ${terminalSafe(plan.backend.name)}')
      ..writeln('  Batch atomic: ${plan.backend.batchAtomic ? 'yes' : 'no'}')
      ..writeln(
        '  Identity-bound delete: '
        '${plan.backend.identityBoundDelete ? 'yes' : 'no'}',
      )
      ..writeln(
        '  Identity-bound move: '
        '${plan.backend.identityBoundMove ? 'yes' : 'no'}',
      )
      ..writeln(
        '  Physical delete: ${plan.backend.physicalDelete ? 'yes' : 'no'}',
      )
      ..writeln(
        '  Crash-recoverable receipt: '
        '${plan.backend.crashRecoverableReceipt ? 'yes' : 'no'}',
      )
      ..writeln(
        '  Release eligible: ${plan.backend.releaseEligible ? 'yes' : 'no'}',
      )
      ..writeln('  Disk space reclaimed: no');
    if (plan.backend.blockerCode case final blocker?) {
      buffer.writeln(
        '${_style('!', _yellow)} Blocker: ${terminalSafe(blocker)}',
      );
    }
    for (var index = 0; index < plan.targets.length; index++) {
      final target = plan.targets[index];
      buffer
        ..writeln('')
        ..writeln('  ${index + 1}. ${terminalSafe(target.runId)}')
        ..writeln('     Path: ${terminalSafe(target.canonicalPath)}');
    }
    buffer
      ..writeln('')
      ..writeln(_style('No quarantine evidence was removed.', _dim));
    return _wrapHuman(buffer.toString(), lineWidth: lineWidth);
  }

  /// Serializes complete clean-plan evidence as one ANSI-free JSON document.
  static String formatCleanPlanJson(QuarantineCleanPlan plan) =>
      _terminalSafeJsonEncode(<String, Object?>{
        'schemaVersion': 1,
        'kind': 'quarantineCleanPlan',
        'scope': plan.scope.name,
        'canonicalBases': plan.canonicalBases,
        'targetCount': plan.targets.length,
        'targets': plan.targets
            .map(
              (target) => <String, Object?>{
                'runId': target.runId,
                'canonicalPath': target.canonicalPath,
                'layoutSha256': target.layoutSha256,
                'journalRevision': target.journalRevision,
                'payloadSha256': target.payloadSha256,
                'authority': target.authority.name,
                'repairAction': target.repairAction.name,
              },
            )
            .toList(growable: false),
        'fingerprint': plan.fingerprint,
        'backend': <String, Object?>{
          'version': CleanBackendDisclosure.version,
          'name': plan.backend.name,
          'batchAtomic': plan.backend.batchAtomic,
          'identityBoundDelete': plan.backend.identityBoundDelete,
          'identityBoundMove': plan.backend.identityBoundMove,
          'physicalDelete': plan.backend.physicalDelete,
          'crashRecoverableReceipt': plan.backend.crashRecoverableReceipt,
          'releaseEligible': plan.backend.releaseEligible,
          'blockerCode': plan.backend.blockerCode,
        },
      });

  /// Renders a current-process clean receipt without claiming crash durability.
  static String formatCleanResultHuman(
    QuarantineCleanResult result, {
    int lineWidth = 160,
  }) {
    final logical =
        result.operationId != null ||
        result.outcomes.any(
          (outcome) =>
              outcome.state == QuarantineCleanTargetState.retained ||
              outcome.state == QuarantineCleanTargetState.recoveryRequired,
        );
    final completeLogical =
        logical &&
        result.failureCode == null &&
        result.outcomes.every(
          (outcome) => outcome.state == QuarantineCleanTargetState.retained,
        );
    final buffer = StringBuffer(
      '${_heading(completeLogical ? 'QUARANTINE LOGICALLY CLEANED' : 'QUARANTINE CLEAN RECEIPT')}\n',
    );
    for (final outcome in result.outcomes) {
      buffer
        ..writeln('')
        ..writeln(
          '  ${_cleanOutcomeLabel(outcome.state)}: '
          '${terminalSafe(outcome.runId)}',
        )
        ..writeln('  Path: ${terminalSafe(outcome.canonicalPath)}');
      if (outcome.retainedPath case final retainedPath?) {
        buffer.writeln('  Recovery copy: ${terminalSafe(retainedPath)}');
      }
      if (outcome.operationId case final operationId?) {
        buffer
          ..writeln('  Operation ID: ${terminalSafe(operationId)}')
          ..writeln(
            '  Restore with: flutter_pruner quarantine retained restore '
            '${terminalSafe(operationId)} ${terminalSafe(outcome.runId)}',
          );
      }
      if (outcome.physicalBytesRetained) {
        buffer.writeln('  Disk space: retained');
      }
      if (outcome.failureCode case final code?) {
        buffer.writeln(
          '  Failure: ${terminalSafe(code)} — '
          '${terminalSafe(outcome.failureMessage!)}',
        );
      }
    }
    buffer.writeln('');
    if (logical) {
      buffer
        ..writeln(
          result.operationId == null
              ? '  Operations: recorded per target'
              : '  Operation ID: ${terminalSafe(result.operationId!)}',
        )
        ..writeln('  Fingerprint: ${terminalSafe(result.fingerprint)}')
        ..writeln(
          '  Mutation attempted: ${result.mutationAttempted ? 'yes' : 'no'}',
        )
        ..writeln('  Physical delete: no')
        ..writeln('  Receipt: crash-recoverable journal evidence.');
    } else {
      buffer
        ..writeln('  Fingerprint: ${terminalSafe(result.fingerprint)}')
        ..writeln(
          '  Deletion attempted: ${result.deletionAttempted ? 'yes' : 'no'}',
        )
        ..writeln('  Receipt: not crash-durable proof.')
        ..writeln(
          'This receipt describes only the current process. Inspect quarantine evidence before another action.',
        );
    }
    return _wrapHuman(buffer.toString(), lineWidth: lineWidth);
  }

  /// Serializes one ANSI-free current-process clean receipt.
  static String formatCleanResultJson(QuarantineCleanResult result) {
    final logical =
        result.operationId != null ||
        result.outcomes.any(
          (outcome) =>
              outcome.state == QuarantineCleanTargetState.retained ||
              outcome.state == QuarantineCleanTargetState.recoveryRequired,
        );
    return _terminalSafeJsonEncode(<String, Object?>{
      'schemaVersion': logical ? 2 : 1,
      'kind': 'quarantineCleanResult',
      'fingerprint': result.fingerprint,
      if (logical) 'operationId': result.operationId,
      if (logical) 'mutationAttempted': result.mutationAttempted,
      if (logical) 'physicalDelete': false,
      if (!logical) 'deletionAttempted': result.deletionAttempted,
      'complete':
          result.failureCode == null &&
          result.outcomes.every(
            (outcome) =>
                outcome.state ==
                (logical
                    ? QuarantineCleanTargetState.retained
                    : QuarantineCleanTargetState.removed),
          ),
      'receiptCrashDurable': logical,
      'outcomes': result.outcomes
          .map(
            (outcome) => <String, Object?>{
              'runId': outcome.runId,
              'canonicalPath': outcome.canonicalPath,
              'state': outcome.state.name,
              if (outcome.retainedPath != null)
                'retainedPath': outcome.retainedPath,
              if (outcome.operationId != null)
                'operationId': outcome.operationId,
              if (logical)
                'physicalBytesRetained': outcome.physicalBytesRetained,
              if (outcome.failureCode != null)
                'failure': <String, Object?>{
                  'code': outcome.failureCode,
                  'message': outcome.failureMessage,
                },
            },
          )
          .toList(growable: false),
      if (result.failureCode != null)
        'failure': <String, Object?>{
          'code': result.failureCode,
          'message': result.failureMessage,
        },
    });
  }

  /// Renders retained logical-clean operations and their recovery state.
  static String formatRetainedListHuman(
    List<RecoverableCleanInspection> inspections, {
    int lineWidth = 160,
  }) {
    if (inspections.isEmpty) {
      return _wrapHuman(
        '${_style('No retained clean operations found.', _dim)}\n',
        lineWidth: lineWidth,
      );
    }
    final buffer = StringBuffer('${_heading('Retained clean operations:')}\n');
    for (final inspection in inspections) {
      buffer
        ..writeln()
        ..writeln(
          '  ${terminalSafe(inspection.operationId)} · '
          '${terminalSafe(inspection.state.name)}',
        )
        ..writeln('  Base: ${terminalSafe(inspection.quarantineBasePath)}')
        ..writeln('  Evidence: ${terminalSafe(inspection.observationCode)}');
    }
    return _wrapHuman(buffer.toString(), lineWidth: lineWidth);
  }

  /// Serializes retained logical-clean operations as one JSON document.
  static String formatRetainedListJson(
    List<RecoverableCleanInspection> inspections,
  ) => _terminalSafeJsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'kind': 'retainedCleanList',
    'total': inspections.length,
    'operations': inspections
        .map(
          (inspection) => <String, Object?>{
            'operationId': inspection.operationId,
            'quarantineBasePath': inspection.quarantineBasePath,
            'state': inspection.state.name,
            'observationCode': inspection.observationCode,
            'runIds': inspection.transaction?.targets
                .map((target) => target.runId)
                .toList(growable: false),
          },
        )
        .toList(growable: false),
  });

  /// Renders a confirmed no-replace retained restore receipt.
  static String formatRetainedRestoreHuman(
    RecoverableCleanRestoreResult result, {
    int lineWidth = 160,
  }) => _wrapHuman(
    '${_heading('QUARANTINE RETAINED RUN RESTORED')}\n\n'
    '  Operation ID: ${terminalSafe(result.operationId)}\n'
    '  Run ID: ${terminalSafe(result.runId)}\n'
    '  Active path: ${terminalSafe(result.activePath)}\n'
    '  Restore used an identity-bound no-replace move.\n',
    lineWidth: lineWidth,
  );

  /// Serializes a confirmed retained restore as one JSON document.
  static String formatRetainedRestoreJson(
    RecoverableCleanRestoreResult result,
  ) => _terminalSafeJsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'kind': 'retainedCleanRestore',
    'operationId': result.operationId,
    'runId': result.runId,
    'activePath': result.activePath,
    'noReplace': true,
  });

  /// Renders a truthful legacy-backend failure without inventing a fingerprint.
  ///
  /// Outcomes come from the caller's prevalidated inventory and current-process
  /// delete returns. They are not reconstructed by rereading a partially
  /// deleted quarantine tree.
  static String formatLegacyCleanOutcomeUnknownHuman(
    List<QuarantineCleanTargetOutcome> outcomes, {
    int lineWidth = 160,
  }) {
    final buffer = StringBuffer(
      '${_style('QUARANTINE CLEAN OUTCOME UNKNOWN', '$_bold$_yellow')}\n',
    );
    for (final outcome in outcomes) {
      buffer
        ..writeln('')
        ..writeln(
          '  ${_cleanOutcomeLabel(outcome.state)}: '
          '${terminalSafe(outcome.runId)}',
        )
        ..writeln('  Path: ${terminalSafe(outcome.canonicalPath)}');
    }
    buffer
      ..writeln('')
      ..writeln('Evidence may be partial.')
      ..writeln('Backend: currentRecursiveDelete')
      ..writeln('Blocker: CLEAN-TOCTOU-1')
      ..writeln('Receipt: current process only; not crash-durable proof.');
    return _wrapHuman(buffer.toString(), lineWidth: lineWidth);
  }

  static String _cleanOutcomeLabel(QuarantineCleanTargetState state) =>
      switch (state) {
        QuarantineCleanTargetState.removed => 'Removed',
        QuarantineCleanTargetState.retained => 'Retained',
        QuarantineCleanTargetState.preserved => 'Preserved',
        QuarantineCleanTargetState.notAttempted => 'Not attempted',
        QuarantineCleanTargetState.outcomeUnknown => 'Outcome unknown',
        QuarantineCleanTargetState.recoveryRequired => 'Recovery required',
      };

  /// Prints the human quarantine inventory without omitting invalid evidence.
  static String formatListHuman({
    required List<QuarantineInspection> items,
    required int total,
    required int limit,
    int lineWidth = 160,
  }) {
    if (total == 0) {
      return _wrapHuman(
        '${_style('No quarantines found.', _dim)}\n',
        lineWidth: lineWidth,
      );
    }
    final buffer = StringBuffer(
      '${_heading('Quarantine inventory ($total):')}\n',
    );
    for (final item in items) {
      buffer.writeln();
      switch (item) {
        case InvalidQuarantineInspection():
          buffer.writeln(_style('! ATTENTION', '$_bold$_yellow'));
          buffer.writeln('  Path: ${terminalSafe(item.path)}');
          buffer.writeln('  Evidence: ${item.errorCode} — ${item.message}');
        case ValidQuarantineInspection():
          buffer.writeln(
            '  ${_styledLifecycle(_listStatusLabel(item))} · ${item.runId}',
          );
          buffer.writeln('  Created: ${_utc(item.timestamp)}');
          buffer.writeln('  Entries: ${item.entryCount}');
          buffer.writeln('  Path: ${terminalSafe(item.path)}');
          buffer.writeln('  Authority: ${item.authority.authority.name}');
          if (item.authority.repairAction != ManifestRepairAction.none) {
            buffer.writeln(
              '  Repair: ${_repairGuidance(item.authority.repairAction)}',
            );
          }
          buffer.writeln('  Cleanable: ${item.cleanable ? 'yes' : 'no'}');
      }
    }
    if (items.length < total) {
      buffer.writeln();
      buffer.writeln(
        'Showing ${items.length} of $total quarantine entries. '
        'Use --limit ${_nextLimit(limit, total)} to show more.',
      );
    }
    return _wrapHuman(buffer.toString(), lineWidth: lineWidth);
  }

  /// Serializes the stable list schema as one ANSI-free JSON document.
  static String formatListJson({
    required String projectRoot,
    required List<QuarantineInspection> items,
    required int total,
  }) => _terminalSafeJsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'projectRoot': projectRoot,
    'total': total,
    'returned': items.length,
    'truncated': items.length < total,
    'items': items.map(_listItemJson).toList(growable: false),
  });

  /// Prints the complete validated diagnostic evidence for one run.
  static String formatInspectHuman(
    ValidQuarantineInspection inspection, {
    int lineWidth = 160,
  }) {
    final authority = inspection.authority;
    final buffer = StringBuffer()
      ..writeln(_heading('Quarantine: ${inspection.runId}'))
      ..writeln('')
      ..writeln('  Lifecycle: ${_styledLifecycle(_lifecycleLabel(inspection))}')
      ..writeln('  Path: ${terminalSafe(inspection.path)}')
      ..writeln('  Authority: ${authority.authority.name}')
      ..writeln('  Revision: ${authority.revision}')
      ..writeln('  Checksum: ${authority.payloadSha256}')
      ..writeln('  Repair: ${_repairGuidance(authority.repairAction)}')
      ..writeln(
        '  Transactions: ${_transactionSummary(inspection.transactions)}',
      )
      ..writeln('  Cleanable: ${inspection.cleanable ? 'yes' : 'no'}')
      ..writeln('')
      ..writeln(_style('Canonical manifest:', _bold))
      ..writeln(
        const JsonEncoder.withIndent(
          '  ',
        ).convert(_displaySafeJson(authority.canonicalDocument)),
      );
    return _wrapHuman(
      buffer.toString(),
      lineWidth: lineWidth,
      preserveCanonicalManifest: true,
    );
  }

  /// Serializes validated inspection evidence as one ANSI-free JSON document.
  static String formatInspectJson({
    required String projectRoot,
    required ValidQuarantineInspection inspection,
  }) => _terminalSafeJsonEncode(<String, Object?>{
    'schemaVersion': 1,
    'projectRoot': projectRoot,
    ..._validItemJson(inspection),
    'authority': inspection.authority.authority.name,
    'repairAction': inspection.authority.repairAction.name,
    'transactions': _transactionsJson(inspection.transactions),
    'canonicalManifest': inspection.authority.canonicalDocument,
  });

  static Object _listItemJson(QuarantineInspection inspection) =>
      switch (inspection) {
        InvalidQuarantineInspection() => <String, Object?>{
          'kind': 'invalid',
          'path': inspection.path,
          'error': <String, Object?>{
            'code': inspection.errorCode,
            'message': inspection.message,
          },
          'blocksApply': inspection.blocksApply,
        },
        ValidQuarantineInspection() => _validItemJson(inspection),
      };

  static Map<String, Object?> _validItemJson(ValidQuarantineInspection item) =>
      <String, Object?>{
        'kind': 'valid',
        'runId': item.runId,
        'createdAtUtc': item.timestamp.toUtc().toIso8601String(),
        'entryCount': item.entryCount,
        'path': item.path,
        'lifecycle': item.lifecycle?.name,
        'cleanable': item.cleanable,
        'recoveryRequired': item.recoveryRequired,
        'journalRevision': item.authority.revision,
        'payloadSha256': item.authority.payloadSha256,
      };

  static Map<String, Object?> _transactionsJson(
    QuarantineTransactionSummary summary,
  ) => <String, Object?>{
    'total': summary.total,
    'pending': summary.pending,
    'applied': summary.applied,
    'verified': summary.verified,
    'committed': summary.committed,
    'rolledBackVerified': summary.rolledBackVerified,
    'recoveryRequired': summary.recoveryRequired,
  };

  static String _lifecycleLabel(ValidQuarantineInspection inspection) {
    if (inspection.recoveryRequired) return 'RECOVERY REQUIRED';
    return switch (inspection.lifecycle) {
      QuarantineRunLifecycleState.active => 'ACTIVE',
      QuarantineRunLifecycleState.completed => 'COMPLETED',
      QuarantineRunLifecycleState.recoveryRequired => 'RECOVERY REQUIRED',
      QuarantineRunLifecycleState.rolledBackVerified =>
        'ROLLED BACK · VERIFIED',
      null => inspection.cleanable ? 'COMPLETED' : 'ATTENTION',
    };
  }

  static String _styledLifecycle(String value) {
    final style =
        value.contains('RECOVERY REQUIRED') || value.contains('ATTENTION')
        ? '$_bold$_yellow'
        : value == 'ACTIVE'
        ? '$_bold$_cyan'
        : '$_bold$_green';
    return _style(value, style);
  }

  static String _heading(String value) => _style(value, '$_bold$_cyan');

  static String _wrapHuman(
    String value, {
    required int lineWidth,
    bool preserveCanonicalManifest = false,
  }) {
    if (preserveCanonicalManifest) {
      final marker = value.indexOf('Canonical manifest:');
      if (marker >= 0) {
        final tailOffset = value.indexOf('\n', marker) + 1;
        // The following pretty JSON is intentionally unwrapped so it remains
        // directly decodable. Use `--format json` for exact machine evidence.
        return '${_wrapHuman(value.substring(0, tailOffset), lineWidth: lineWidth)}'
            '${value.substring(tailOffset)}';
      }
    }
    return value
        .split('\n')
        .expand(
          (line) => line.isEmpty
              ? const ['']
              : _metrics.wrap(line, width: lineWidth < 12 ? 12 : lineWidth),
        )
        .join('\n');
  }

  static String _style(String value, String style) => '$style$value$_reset';

  static String _listStatusLabel(ValidQuarantineInspection inspection) {
    final lifecycle = _lifecycleLabel(inspection);
    if (inspection.authority.repairAction == ManifestRepairAction.none) {
      return lifecycle;
    }
    return 'ATTENTION · REPAIR REQUIRED · $lifecycle';
  }

  static String _utc(DateTime value) =>
      '${value.toUtc().toIso8601String()} UTC';

  static int _nextLimit(int limit, int total) {
    final doubled = limit * 2;
    return doubled > total ? total : doubled;
  }

  static String _repairGuidance(
    ManifestRepairAction action,
  ) => switch (action) {
    ManifestRepairAction.none => 'No repair required',
    ManifestRepairAction.discardUncommittedTemporary =>
      'Discard the uncommitted temporary manifest only through a locked recovery operation',
    ManifestRepairAction.promoteTemporary =>
      'Promote the temporary manifest only through a locked recovery operation',
    ManifestRepairAction.restorePrevious =>
      'Restore the previous manifest only through a locked recovery operation',
  };

  static String _transactionSummary(QuarantineTransactionSummary summary) =>
      '${summary.total} total · ${summary.pending} pending · '
      '${summary.applied} applied · ${summary.verified} verified · '
      '${summary.committed} committed · '
      '${summary.rolledBackVerified} rolled back verified · '
      '${summary.recoveryRequired} recovery required';

  /// Encodes exact raw argv as one terminal-safe, JSON-decodable line.
  ///
  /// JSON already escapes most ASCII controls. This additionally escapes raw
  /// DEL, C1, bidi, and line-separator code points with JSON-compatible Unicode
  /// escapes, so decoding reproduces the original argv without terminal effects.
  static String formatExactArgvJson(List<String> argv) {
    return _escapeTerminalUnsafeJson(jsonEncode(argv));
  }

  static String _terminalSafeJsonEncode(Object? value) =>
      _escapeTerminalUnsafeJson(jsonEncode(value));

  static String _escapeTerminalUnsafeJson(String encoded) {
    final buffer = StringBuffer();
    for (final rune in encoded.runes) {
      if (rune <= 0x1f || rune == 0x7f || _isDisplayUnsafeUnicode(rune)) {
        buffer.write(_jsonUnicodeEscape(rune));
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  static String _jsonUnicodeEscape(int rune) {
    if (rune <= 0xffff) {
      return '\\u${rune.toRadixString(16).padLeft(4, '0').toUpperCase()}';
    }
    final scalar = rune - 0x10000;
    final high = 0xd800 + (scalar >> 10);
    final low = 0xdc00 + (scalar & 0x3ff);
    return '\\u${high.toRadixString(16).toUpperCase()}'
        '\\u${low.toRadixString(16).toUpperCase()}';
  }

  /// Renders an untrusted text field without terminal control effects.
  ///
  /// JSON preserves the original string; this display projection is deliberately
  /// full-length and uses visible escapes for control and bidi formatting code
  /// points so data cannot create a new terminal row or ANSI sequence.
  /// Successful machine JSON keeps the original value instead of this display
  /// projection.
  static String terminalSafe(String value) {
    final buffer = StringBuffer();
    for (final rune in value.runes) {
      switch (rune) {
        case 0x0a:
          buffer.write(r'\n');
        case 0x0d:
          buffer.write(r'\r');
        case 0x09:
          buffer.write(r'\t');
        default:
          if (rune <= 0x1f || rune == 0x7f) {
            buffer.write(
              '\\x${rune.toRadixString(16).padLeft(2, '0').toUpperCase()}',
            );
          } else if (_isDisplayUnsafeUnicode(rune)) {
            buffer.write(
              '\\u${rune.toRadixString(16).padLeft(4, '0').toUpperCase()}',
            );
          } else {
            buffer.writeCharCode(rune);
          }
      }
    }
    return buffer.toString();
  }

  /// Recursively projects canonical JSON into a terminal-safe display value.
  ///
  /// Only string keys and values change. The pretty encoder still owns the
  /// structural indentation and newlines, so this remains readable JSON.
  static Object? _displaySafeJson(Object? value) => switch (value) {
    String() => terminalSafe(value),
    Map<Object?, Object?>() => <String, Object?>{
      for (final entry in value.entries)
        terminalSafe(_requireJsonKey(entry.key)): _displaySafeJson(entry.value),
    },
    List<Object?>() => value.map(_displaySafeJson).toList(growable: false),
    _ => value,
  };

  static String _requireJsonKey(Object? value) {
    if (value is! String) {
      throw ArgumentError.value(value, 'canonical JSON key');
    }
    return value;
  }

  static bool _isDisplayUnsafeUnicode(int rune) =>
      (rune >= 0x80 && rune <= 0x9f) ||
      rune == 0x061c ||
      rune == 0x200e ||
      rune == 0x200f ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      (rune >= 0x202a && rune <= 0x202e) ||
      (rune >= 0x2066 && rune <= 0x2069);
}

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _dim = '\x1B[2m';
const _green = '\x1B[32m';
const _yellow = '\x1B[33m';
const _cyan = '\x1B[36m';
