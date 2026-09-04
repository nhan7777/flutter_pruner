import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'clean_move_backend.dart';

/// Durable phase of one target in a recoverable logical-clean transaction.
enum CleanTargetPhase {
  /// Intent is durable and no move is confirmed.
  planned,

  /// The move returned, but retained verification is not yet committed.
  moved,

  /// Exact retained identity and tree evidence are durably committed.
  retainedCommitted,

  /// The retained directory was moved back to its active run name.
  restoredCommitted,

  /// Durable intent was reconciled before any move crossed its boundary.
  abortedCommitted,

  /// Exact state cannot be proven without operator recovery.
  recoveryRequired,
}

/// Durable aggregate state of one recoverable logical-clean transaction.
enum CleanTransactionState {
  /// At least one ordered target is not terminal.
  active,

  /// Every selected target is retained and committed.
  committed,

  /// Every selected target has been restored to active inventory.
  restored,

  /// No selected target crossed its move boundary.
  aborted,

  /// Some targets are restored while others remain retained-committed.
  partiallyRestored,

  /// At least one target requires operator recovery.
  recoveryRequired,
}

/// Durable authority evidence for one selected quarantine run.
final class RecoverableCleanTargetRecord {
  /// Creates one validated immutable target record.
  RecoverableCleanTargetRecord({
    required this.runId,
    required List<String> sourceComponents,
    required List<String> destinationComponents,
    required this.identity,
    required this.layoutSha256,
    required this.journalRevision,
    required this.payloadSha256,
    required this.phase,
    this.observationCode,
  }) : sourceComponents = List<String>.unmodifiable(sourceComponents),
       destinationComponents = List<String>.unmodifiable(
         destinationComponents,
       ) {
    _validateRunId(runId);
    _validateComponents(this.sourceComponents);
    _validateComponents(this.destinationComponents);
    _validateSha256(layoutSha256, 'layoutSha256');
    _validateSha256(payloadSha256, 'payloadSha256');
    if (journalRevision < 0) {
      throw ArgumentError.value(
        journalRevision,
        'journalRevision',
        'Cannot be negative.',
      );
    }
    if (observationCode != null) {
      _validateToken(observationCode!, 'observationCode');
    }
  }

  /// Validated quarantine run identifier.
  final String runId;

  /// Directory-relative active source components.
  final List<String> sourceComponents;

  /// Directory-relative retained destination components.
  final List<String> destinationComponents;

  /// Stable root identity authorized by the clean plan.
  final CleanObjectIdentity identity;

  /// Complete no-follow tree digest authorized by the clean plan.
  final String layoutSha256;

  /// Authoritative quarantine manifest revision.
  final int journalRevision;

  /// Authoritative quarantine manifest payload checksum.
  final String payloadSha256;

  /// Current durable target phase.
  final CleanTargetPhase phase;

  /// Stable recovery observation code, when present.
  final String? observationCode;

  /// Canonical JSON projection included in transaction authority.
  Map<String, Object?> toJson() => <String, Object?>{
    'runId': runId,
    'sourceComponents': sourceComponents,
    'destinationComponents': destinationComponents,
    'identity': identity.toJson(),
    'layoutSha256': layoutSha256,
    'journalRevision': journalRevision,
    'payloadSha256': payloadSha256,
    'phase': phase.name,
    if (observationCode != null) 'observationCode': observationCode,
  };

  factory RecoverableCleanTargetRecord._fromJson(Map<String, dynamic> json) {
    _requireExactKeys(
      json,
      required: const <String>{
        'runId',
        'sourceComponents',
        'destinationComponents',
        'identity',
        'layoutSha256',
        'journalRevision',
        'payloadSha256',
        'phase',
      },
      optional: const <String>{'observationCode'},
    );
    try {
      return RecoverableCleanTargetRecord(
        runId: json['runId'] as String,
        sourceComponents: _stringList(json['sourceComponents']),
        destinationComponents: _stringList(json['destinationComponents']),
        identity: _identityFromJson(_stringMap(json['identity'])),
        layoutSha256: json['layoutSha256'] as String,
        journalRevision: json['journalRevision'] as int,
        payloadSha256: json['payloadSha256'] as String,
        phase: CleanTargetPhase.values.byName(json['phase'] as String),
        observationCode: json['observationCode'] as String?,
      );
    } on Object catch (error) {
      throw FormatException('Invalid recoverable clean target: $error');
    }
  }
}

/// Versioned checksummed authority for one recoverable logical-clean batch.
final class RecoverableCleanTransaction {
  RecoverableCleanTransaction._({
    required this.operationId,
    required this.projectPath,
    required this.quarantineBasePath,
    required this.quarantineBaseIdentity,
    required this.planFingerprint,
    required this.scope,
    required List<RecoverableCleanTargetRecord> targets,
    required this.state,
    required this.createdAtUtc,
    required this.updatedAtUtc,
  }) : targets = List<RecoverableCleanTargetRecord>.unmodifiable(targets);

  /// Creates validated transaction authority from typed evidence.
  factory RecoverableCleanTransaction.create({
    required String operationId,
    required String projectPath,
    required String quarantineBasePath,
    required CleanObjectIdentity quarantineBaseIdentity,
    required String planFingerprint,
    required String scope,
    required List<RecoverableCleanTargetRecord> targets,
    required CleanTransactionState state,
    required DateTime createdAtUtc,
    required DateTime updatedAtUtc,
  }) {
    _validateOperationId(operationId);
    _validateAbsoluteEvidencePath(projectPath, 'projectPath');
    _validateAbsoluteEvidencePath(quarantineBasePath, 'quarantineBasePath');
    if (!RegExp(r'^v[1-9][0-9]*:[0-9a-f]{64}$').hasMatch(planFingerprint)) {
      throw ArgumentError.value(
        planFingerprint,
        'planFingerprint',
        'Invalid fingerprint.',
      );
    }
    if (scope != 'targeted' && scope != 'all') {
      throw ArgumentError.value(scope, 'scope', 'Unknown clean scope.');
    }
    if (targets.isEmpty) {
      throw ArgumentError.value(targets, 'targets', 'Cannot be empty.');
    }
    final runIds = <String>{};
    var previousRunId = '';
    for (final target in targets) {
      if (!runIds.add(target.runId)) {
        throw ArgumentError.value(target.runId, 'targets', 'Duplicate run ID.');
      }
      if (previousRunId.isNotEmpty &&
          previousRunId.compareTo(target.runId) >= 0) {
        throw ArgumentError.value(targets, 'targets', 'Must be sorted.');
      }
      previousRunId = target.runId;
    }
    final created = createdAtUtc.toUtc();
    final updated = updatedAtUtc.toUtc();
    if (updated.isBefore(created)) {
      throw ArgumentError('updatedAtUtc precedes createdAtUtc.');
    }
    _validateState(state, targets);
    return RecoverableCleanTransaction._(
      operationId: operationId,
      projectPath: projectPath,
      quarantineBasePath: quarantineBasePath,
      quarantineBaseIdentity: quarantineBaseIdentity,
      planFingerprint: planFingerprint,
      scope: scope,
      targets: targets,
      state: state,
      createdAtUtc: created,
      updatedAtUtc: updated,
    );
  }

  /// Parses and verifies one complete transaction document.
  factory RecoverableCleanTransaction.fromJson(Map<String, dynamic> json) {
    _requireExactKeys(
      json,
      required: const <String>{
        'version',
        'operationId',
        'projectPath',
        'quarantineBasePath',
        'quarantineBaseIdentity',
        'planFingerprint',
        'scope',
        'targets',
        'state',
        'createdAtUtc',
        'updatedAtUtc',
        'checksumSha256',
      },
    );
    if (json['version'] != version) {
      throw const FormatException('Unsupported recoverable clean version.');
    }
    final authority = Map<String, dynamic>.from(json)..remove('checksumSha256');
    final checksum = json['checksumSha256'];
    if (checksum is! String || checksum != _checksum(authority)) {
      throw const FormatException('Recoverable clean checksum mismatch.');
    }
    try {
      final rawTargets = json['targets'] as List<dynamic>;
      return RecoverableCleanTransaction.create(
        operationId: json['operationId'] as String,
        projectPath: json['projectPath'] as String,
        quarantineBasePath: json['quarantineBasePath'] as String,
        quarantineBaseIdentity: _identityFromJson(
          _stringMap(json['quarantineBaseIdentity']),
        ),
        planFingerprint: json['planFingerprint'] as String,
        scope: json['scope'] as String,
        targets: rawTargets
            .map(
              (target) =>
                  RecoverableCleanTargetRecord._fromJson(_stringMap(target)),
            )
            .toList(growable: false),
        state: CleanTransactionState.values.byName(json['state'] as String),
        createdAtUtc: DateTime.parse(json['createdAtUtc'] as String),
        updatedAtUtc: DateTime.parse(json['updatedAtUtc'] as String),
      );
    } on FormatException {
      rethrow;
    } on Object catch (error) {
      throw FormatException('Invalid recoverable clean transaction: $error');
    }
  }

  /// Current transaction schema version.
  static const int version = 1;

  /// Globally unique opaque operation identifier.
  final String operationId;

  /// Canonical selected project path.
  final String projectPath;

  /// Canonical selected quarantine-base path.
  final String quarantineBasePath;

  /// Stable retained identity of the selected quarantine base.
  final CleanObjectIdentity quarantineBaseIdentity;

  /// Clean plan fingerprint reviewed before mutation.
  final String planFingerprint;

  /// Stable clean scope token: `targeted` or `all`.
  final String scope;

  /// Ordered target authority and recovery evidence.
  final List<RecoverableCleanTargetRecord> targets;

  /// Aggregate durable transaction state.
  final CleanTransactionState state;

  /// UTC transaction creation time.
  final DateTime createdAtUtc;

  /// UTC last journal update time.
  final DateTime updatedAtUtc;

  Map<String, Object?> _authorityJson() => <String, Object?>{
    'version': version,
    'operationId': operationId,
    'projectPath': projectPath,
    'quarantineBasePath': quarantineBasePath,
    'quarantineBaseIdentity': quarantineBaseIdentity.toJson(),
    'planFingerprint': planFingerprint,
    'scope': scope,
    'targets': targets.map((target) => target.toJson()).toList(growable: false),
    'state': state.name,
    'createdAtUtc': createdAtUtc.toUtc().toIso8601String(),
    'updatedAtUtc': updatedAtUtc.toUtc().toIso8601String(),
  };

  /// Complete canonical transaction document including its checksum.
  Map<String, Object?> toJson() {
    final authority = _authorityJson();
    return <String, Object?>{
      ...authority,
      'checksumSha256': _checksum(authority),
    };
  }
}

void _validateState(
  CleanTransactionState state,
  List<RecoverableCleanTargetRecord> targets,
) {
  final allCommitted = targets.every(
    (target) => target.phase == CleanTargetPhase.retainedCommitted,
  );
  final allRestored = targets.every(
    (target) => target.phase == CleanTargetPhase.restoredCommitted,
  );
  final allAborted = targets.every(
    (target) => target.phase == CleanTargetPhase.abortedCommitted,
  );
  final hasRecovery = targets.any(
    (target) => target.phase == CleanTargetPhase.recoveryRequired,
  );
  final hasRestored = targets.any(
    (target) =>
        target.phase == CleanTargetPhase.restoredCommitted ||
        target.phase == CleanTargetPhase.abortedCommitted,
  );
  final hasRetained = targets.any(
    (target) => target.phase == CleanTargetPhase.retainedCommitted,
  );
  final validPartialRestore = targets.every(
    (target) =>
        target.phase == CleanTargetPhase.restoredCommitted ||
        target.phase == CleanTargetPhase.abortedCommitted ||
        target.phase == CleanTargetPhase.retainedCommitted,
  );
  if ((state == CleanTransactionState.committed && !allCommitted) ||
      (state == CleanTransactionState.restored && !allRestored) ||
      (state == CleanTransactionState.aborted && !allAborted) ||
      (state == CleanTransactionState.partiallyRestored &&
          !(hasRestored && hasRetained && validPartialRestore)) ||
      (state == CleanTransactionState.recoveryRequired && !hasRecovery) ||
      (state == CleanTransactionState.active &&
          (allCommitted || allRestored || allAborted || hasRecovery))) {
    throw ArgumentError('Transaction state contradicts target phases.');
  }
}

CleanObjectIdentity _identityFromJson(Map<String, dynamic> json) {
  _requireExactKeys(
    json,
    required: const <String>{'storageId', 'objectId', 'kind'},
  );
  try {
    final storageId = json['storageId'] as String;
    final objectId = json['objectId'] as String;
    _validateToken(storageId, 'storageId');
    _validateToken(objectId, 'objectId');
    return CleanObjectIdentity(
      storageId: storageId,
      objectId: objectId,
      kind: CleanObjectKind.values.byName(json['kind'] as String),
    );
  } on Object catch (error) {
    throw FormatException('Invalid clean object identity: $error');
  }
}

String _checksum(Map<String, Object?> authority) =>
    sha256.convert(utf8.encode(jsonEncode(authority))).toString();

Map<String, dynamic> _stringMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected JSON object.');
  try {
    return value.map((key, item) => MapEntry(key as String, item));
  } on Object {
    throw const FormatException('Expected string JSON keys.');
  }
}

List<String> _stringList(Object? value) {
  if (value is! List) throw const FormatException('Expected JSON list.');
  try {
    return value.cast<String>().toList(growable: false);
  } on Object {
    throw const FormatException('Expected string list.');
  }
}

void _requireExactKeys(
  Map<String, dynamic> json, {
  required Set<String> required,
  Set<String> optional = const <String>{},
}) {
  final keys = json.keys.toSet();
  if (!keys.containsAll(required) ||
      !required.union(optional).containsAll(keys)) {
    throw const FormatException('Invalid recoverable clean document fields.');
  }
}

void _validateComponents(List<String> components) {
  if (components.isEmpty) {
    throw ArgumentError.value(components, 'components', 'Cannot be empty.');
  }
  for (final component in components) {
    validateCleanPathComponent(component);
  }
}

void _validateRunId(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,119}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'runId', 'Invalid run ID.');
  }
  validateCleanPathComponent(value);
}

void _validateOperationId(String value) {
  if (!RegExp(r'^clean-[0-9]{8}T[0-9]{12}Z-[0-9a-f]{8,64}$').hasMatch(value)) {
    throw ArgumentError.value(value, 'operationId', 'Invalid operation ID.');
  }
  validateCleanPathComponent(value);
}

void _validateAbsoluteEvidencePath(String value, String name) {
  final windows = RegExp(r'^[A-Za-z]:[\\/]');
  if (!(value.startsWith('/') || windows.hasMatch(value)) ||
      value.contains('\u0000')) {
    throw ArgumentError.value(value, name, 'Expected canonical absolute path.');
  }
}

void _validateSha256(String value, String name) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw ArgumentError.value(value, name, 'Expected lowercase SHA-256.');
  }
}

void _validateToken(String value, String name) {
  final invalid =
      value.isEmpty ||
      value.length > 256 ||
      value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);
  if (invalid) {
    throw ArgumentError.value(value, name, 'Invalid stable token.');
  }
}
