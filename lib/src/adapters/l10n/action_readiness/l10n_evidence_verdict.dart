import 'dart:collection';
import 'dart:typed_data';

import 'l10n_evidence_failure.dart';
import 'l10n_output_reconciler.dart';

/// Whether the complete internal l10n evidence pipeline accepted a change.
enum L10nEvidenceStatus {
  /// Every required Stage 1 evidence gate succeeded.
  accepted,

  /// At least one stable evidence failure rejected the change.
  rejected,
}

/// Immutable, redacted result of one complete l10n evidence evaluation.
final class L10nEvidenceVerdict {
  /// Creates a deterministic verdict from stable failures and redacted facts.
  factory L10nEvidenceVerdict({
    required L10nEvidenceStatus status,
    required Iterable<L10nEvidenceFailure> failures,
    required String familyFingerprint,
    required String selectionFingerprint,
    required String configurationIdentity,
    required String packageResolutionIdentity,
    required String toolchainIdentity,
    required Map<String, String> baselineInventoryHashes,
    required Map<String, String> candidateInventoryHashes,
    required Map<String, Object?> mutationSummary,
    required Map<String, Object?> verificationSummary,
    required Map<String, Object?> timingAndResourceMetrics,
  }) {
    final frozenFailures = _sortedFailures(failures);
    if ((status == L10nEvidenceStatus.accepted) != frozenFailures.isEmpty) {
      throw ArgumentError(
        'An accepted verdict has no failures and a rejected verdict has at '
        'least one.',
      );
    }

    _validateSha256(familyFingerprint, 'familyFingerprint');
    _validateSha256(selectionFingerprint, 'selectionFingerprint');
    _validateSha256(configurationIdentity, 'configurationIdentity');
    _validateSha256(packageResolutionIdentity, 'packageResolutionIdentity');
    _validateSha256(toolchainIdentity, 'toolchainIdentity');

    return L10nEvidenceVerdict._(
      status: status,
      reasonCodes: _reasonCodes(frozenFailures),
      failures: frozenFailures,
      familyFingerprint: familyFingerprint,
      selectionFingerprint: selectionFingerprint,
      configurationIdentity: configurationIdentity,
      packageResolutionIdentity: packageResolutionIdentity,
      toolchainIdentity: toolchainIdentity,
      baselineInventoryHashes: _freezeInventoryHashes(
        baselineInventoryHashes,
        'baselineInventoryHashes',
      ),
      candidateInventoryHashes: _freezeInventoryHashes(
        candidateInventoryHashes,
        'candidateInventoryHashes',
      ),
      mutationSummary: _freezeRedactedMap(mutationSummary, 'mutationSummary'),
      verificationSummary: _freezeRedactedMap(
        verificationSummary,
        'verificationSummary',
      ),
      timingAndResourceMetrics: _freezeRedactedMap(
        timingAndResourceMetrics,
        'timingAndResourceMetrics',
      ),
    );
  }

  const L10nEvidenceVerdict._({
    required this.status,
    required this.reasonCodes,
    required this.failures,
    required this.familyFingerprint,
    required this.selectionFingerprint,
    required this.configurationIdentity,
    required this.packageResolutionIdentity,
    required this.toolchainIdentity,
    required this.baselineInventoryHashes,
    required this.candidateInventoryHashes,
    required this.mutationSummary,
    required this.verificationSummary,
    required this.timingAndResourceMetrics,
  });

  /// Accepted or rejected terminal state.
  final L10nEvidenceStatus status;

  /// Unique failure categories in declaration order.
  final List<L10nEvidenceRejectionCode> reasonCodes;

  /// Stable, sorted, duplicate-free failure details.
  final List<L10nEvidenceFailure> failures;

  /// Root-independent identity of the selected l10n family.
  final String familyFingerprint;

  /// Root-independent identity of the exact requested selection.
  final String selectionFingerprint;

  /// Strict generation-configuration identity.
  final String configurationIdentity;

  /// Frozen package-resolution identity.
  final String packageResolutionIdentity;

  /// Frozen Flutter/Dart toolchain identity.
  final String toolchainIdentity;

  /// Deterministically ordered hashes of baseline inventories.
  final Map<String, String> baselineInventoryHashes;

  /// Deterministically ordered hashes of candidate inventories.
  final Map<String, String> candidateInventoryHashes;

  /// Redacted selected-key, byte-span, path, and mutation-hash facts.
  final Map<String, Object?> mutationSummary;

  /// Redacted fixed-policy verification facts.
  final Map<String, Object?> verificationSummary;

  /// Redacted monotonic timing and process-resource metrics.
  final Map<String, Object?> timingAndResourceMetrics;

  /// Serializes the internal evidence without bytes, raw output, host paths,
  /// or environment values.
  Map<String, Object?> toInternalJson() => _freezeRedactedMap(<String, Object?>{
    'status': status.name,
    'reasonCodes': <Object?>[for (final code in reasonCodes) code.name],
    'failures': <Object?>[
      for (final failure in failures)
        <String, Object?>{
          'code': failure.code.name,
          'stage': failure.stage,
          'detailCode': failure.detailCode,
          if (failure.relativePath != null)
            'relativePath': failure.relativePath,
        },
    ],
    'familyFingerprint': familyFingerprint,
    'selectionFingerprint': selectionFingerprint,
    'configurationIdentity': configurationIdentity,
    'packageResolutionIdentity': packageResolutionIdentity,
    'toolchainIdentity': toolchainIdentity,
    'baselineInventoryHashes': baselineInventoryHashes,
    'candidateInventoryHashes': candidateInventoryHashes,
    'mutationSummary': mutationSummary,
    'verificationSummary': verificationSummary,
    'timingAndResourceMetrics': timingAndResourceMetrics,
  }, 'internalJson');
}

/// Verdict plus the exact publishable changes retained only on acceptance.
final class L10nEvidenceEvaluation {
  /// Creates an evaluation and prevents a partial change set from escaping a
  /// rejected verdict.
  L10nEvidenceEvaluation({
    required this.verdict,
    L10nWitnessedChangeSet? witnessedChangeSet,
  }) : witnessedChangeSet = verdict.status == L10nEvidenceStatus.accepted
           ? witnessedChangeSet
           : null {
    if (verdict.status == L10nEvidenceStatus.accepted &&
        this.witnessedChangeSet == null) {
      throw ArgumentError(
        'An accepted evaluation requires a witnessed change set.',
      );
    }
  }

  /// Complete immutable evidence verdict.
  final L10nEvidenceVerdict verdict;

  /// Exact replacements for an accepted verdict, otherwise null.
  final L10nWitnessedChangeSet? witnessedChangeSet;
}

List<L10nEvidenceFailure> _sortedFailures(
  Iterable<L10nEvidenceFailure> source,
) {
  final ordered = List<L10nEvidenceFailure>.of(source)..sort(_compareFailures);
  final result = <L10nEvidenceFailure>[];
  for (final failure in ordered) {
    _validateFailure(failure);
    if (result.isEmpty || _compareFailures(result.last, failure) != 0) {
      result.add(failure);
    }
  }
  return List<L10nEvidenceFailure>.unmodifiable(result);
}

List<L10nEvidenceRejectionCode> _reasonCodes(
  Iterable<L10nEvidenceFailure> failures,
) => List<L10nEvidenceRejectionCode>.unmodifiable(
  SplayTreeSet<L10nEvidenceRejectionCode>(
    (left, right) => left.index.compareTo(right.index),
  )..addAll(failures.map((failure) => failure.code)),
);

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  var comparison = left.code.index.compareTo(right.code.index);
  if (comparison != 0) return comparison;
  comparison = left.stage.compareTo(right.stage);
  if (comparison != 0) return comparison;
  comparison = _compareNullable(left.relativePath, right.relativePath);
  if (comparison != 0) return comparison;
  return left.detailCode.compareTo(right.detailCode);
}

int _compareNullable(String? left, String? right) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return left.compareTo(right);
}

void _validateFailure(L10nEvidenceFailure failure) {
  if (!_stableCode.hasMatch(failure.stage)) {
    throw ArgumentError.value(failure.stage, 'failure.stage');
  }
  if (!_stableCode.hasMatch(failure.detailCode)) {
    throw ArgumentError.value(failure.detailCode, 'failure.detailCode');
  }
  final relativePath = failure.relativePath;
  if (relativePath != null && !_isSafeRelativePath(relativePath)) {
    throw ArgumentError.value(relativePath, 'failure.relativePath');
  }
}

Map<String, String> _freezeInventoryHashes(
  Map<String, String> source,
  String name,
) {
  final result = SplayTreeMap<String, String>();
  for (final entry in source.entries) {
    _validateRedactedString(entry.key, '$name.key');
    if (entry.key.isEmpty) {
      throw ArgumentError.value(entry.key, '$name.key');
    }
    _validateSha256(entry.value, '$name.${entry.key}');
    _freezeRedactedValue(
      entry.value,
      key: entry.key,
      name: '$name.${entry.key}',
    );
    result[entry.key] = entry.value;
  }
  return Map<String, String>.unmodifiable(result);
}

Map<String, Object?> _freezeRedactedMap(
  Map<String, Object?> source,
  String name,
) {
  final result = SplayTreeMap<String, Object?>();
  for (final entry in source.entries) {
    if (entry.key.isEmpty) {
      throw ArgumentError.value(entry.key, '$name.key');
    }
    _validateRedactedString(entry.key, '$name.key');
    result[entry.key] = _freezeRedactedValue(
      entry.value,
      key: entry.key,
      name: '$name.${entry.key}',
    );
  }
  return Map<String, Object?>.unmodifiable(result);
}

Object? _freezeRedactedValue(
  Object? value, {
  required String key,
  required String name,
}) {
  final environmentProjection = _environmentProjectionKind(key);
  if (environmentProjection != null) {
    return _freezeEnvironmentProjection(
      value,
      kind: environmentProjection,
      name: name,
    );
  }
  final streamOrOutput = _streamOrOutputKey(key);
  if (streamOrOutput) return _freezeStreamProjection(value, name);
  if (_streamIdentityKey(key)) {
    if (value is String && _sha256.hasMatch(value)) return value;
    throw ArgumentError.value(value, name, 'stream identity must be SHA-256');
  }
  if (_unsafeStreamDerivedKey(key) || _forbidsValue(key)) {
    throw ArgumentError.value(value, name, 'field may expose sensitive data');
  }
  if (value == null || value is bool || value is int) return value;
  if (value is double) {
    if (!value.isFinite) throw ArgumentError.value(value, name);
    return value;
  }
  if (value is String) {
    _validateRedactedString(value, name);
    return value;
  }
  if (value is TypedData) {
    throw ArgumentError.value(value, name, 'bytes are not serializable');
  }
  if (value is Map) {
    final nested = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      final nestedKey = entry.key;
      if (nestedKey is! String || nestedKey.isEmpty) {
        throw ArgumentError.value(nestedKey, '$name.key');
      }
      _validateRedactedString(nestedKey, '$name.key');
      nested[nestedKey] = _freezeRedactedValue(
        entry.value,
        key: nestedKey,
        name: '$name.$nestedKey',
      );
    }
    return Map<String, Object?>.unmodifiable(nested);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(<Object?>[
      for (var index = 0; index < value.length; index++)
        _freezeRedactedValue(value[index], key: '', name: '$name[$index]'),
    ]);
  }
  throw ArgumentError.value(value, name, 'unsupported redacted value');
}

Object _freezeStreamProjection(Object? value, String name) {
  if (value is String && _sha256.hasMatch(value)) return value;
  if (value is! Map) {
    throw ArgumentError.value(value, name, 'raw output is not serializable');
  }
  final keys = value.keys.toSet();
  if (keys.length != _redactedStreamKeys.length ||
      !keys.containsAll(_redactedStreamKeys)) {
    throw ArgumentError.value(
      keys,
      '$name.key',
      'raw output projection has an invalid schema',
    );
  }
  final sha = value['sha256'];
  final capturedBytes = value['capturedBytes'];
  final omittedBytes = value['omittedBytes'];
  final truncated = value['truncated'];
  if (sha is! String || !_sha256.hasMatch(sha)) {
    throw ArgumentError.value(sha, '$name.sha256');
  }
  if (capturedBytes is! int || capturedBytes < 0) {
    throw ArgumentError.value(capturedBytes, '$name.capturedBytes');
  }
  if (omittedBytes is! int || omittedBytes < 0) {
    throw ArgumentError.value(omittedBytes, '$name.omittedBytes');
  }
  if (truncated is! bool || truncated != (omittedBytes > 0)) {
    throw ArgumentError.value(truncated, '$name.truncated');
  }
  return Map<String, Object?>.unmodifiable(<String, Object?>{
    'capturedBytes': capturedBytes,
    'omittedBytes': omittedBytes,
    'sha256': sha,
    'truncated': truncated,
  });
}

Object _freezeEnvironmentProjection(
  Object? value, {
  required _EnvironmentProjectionKind kind,
  required String name,
}) => switch (kind) {
  _EnvironmentProjectionKind.identity =>
    value is String && _sha256.hasMatch(value)
        ? value
        : throw ArgumentError.value(value, name),
  _EnvironmentProjectionKind.count =>
    value is int && value >= 0 ? value : throw ArgumentError.value(value, name),
  _EnvironmentProjectionKind.forbidden => throw ArgumentError.value(
    value,
    name,
    'environment values are forbidden',
  ),
};

enum _EnvironmentProjectionKind { identity, count, forbidden }

_EnvironmentProjectionKind? _environmentProjectionKind(String key) {
  final normalized = _normalizeKey(key);
  final environmentLike =
      normalized.contains('environment') ||
      normalized == 'env' ||
      normalized.startsWith('env') ||
      normalized.endsWith('env') ||
      normalized.contains('envhash') ||
      normalized.contains('envsha256') ||
      normalized.contains('envidentity') ||
      normalized.contains('envcount') ||
      normalized.contains('envvalues');
  if (!environmentLike) return null;
  if (normalized.endsWith('count')) {
    return _EnvironmentProjectionKind.count;
  }
  if (normalized.endsWith('hash') ||
      normalized.endsWith('sha256') ||
      normalized.endsWith('identity')) {
    return _EnvironmentProjectionKind.identity;
  }
  return _EnvironmentProjectionKind.forbidden;
}

bool _forbidsValue(String key) {
  final normalized = _normalizeKey(key);
  if (_forbiddenValueKeys.contains(normalized)) return true;
  if (normalized.startsWith('raw')) return true;
  return false;
}

bool _streamOrOutputKey(String key) {
  final normalized = _normalizeKey(key);
  return normalized == 'output' ||
      normalized.endsWith('stdout') ||
      normalized.endsWith('stderr') ||
      normalized.endsWith('output');
}

bool _streamIdentityKey(String key) {
  final normalized = _normalizeKey(key);
  final streamDerived =
      normalized.contains('stdout') ||
      normalized.contains('stderr') ||
      normalized.contains('output');
  return streamDerived &&
      (normalized.endsWith('hash') ||
          normalized.endsWith('sha256') ||
          normalized.endsWith('identity'));
}

bool _unsafeStreamDerivedKey(String key) {
  final normalized = _normalizeKey(key);
  if (normalized.contains('stdout') || normalized.contains('stderr')) {
    return true;
  }
  return normalized.contains('output') &&
      (normalized.endsWith('text') ||
          normalized.endsWith('content') ||
          normalized.endsWith('value') ||
          normalized.endsWith('payload') ||
          normalized.endsWith('bytes'));
}

String _normalizeKey(String key) =>
    key.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');

void _validateRedactedString(String value, String name) {
  if (_containsControlCharacters.hasMatch(value) ||
      value.contains('\\') ||
      _looksLikeAbsolutePath(value)) {
    throw ArgumentError.value(value, name, 'contains an unsafe path or text');
  }
}

bool _looksLikeAbsolutePath(String value) =>
    _embeddedPosixAbsolutePath.hasMatch(value) ||
    _embeddedDoubleSlashAbsolutePath.hasMatch(value) ||
    _embeddedFileUri.hasMatch(value) ||
    _embeddedWindowsAbsolutePath.hasMatch(value);

bool _isSafeRelativePath(String value) {
  if (value == '.') return true;
  if (value.isEmpty ||
      _looksLikeAbsolutePath(value) ||
      _containsControlCharacters.hasMatch(value) ||
      value.contains('\\') ||
      value.endsWith('/')) {
    return false;
  }
  final segments = value.split('/');
  return segments.every(
    (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
  );
}

void _validateSha256(String value, String name) {
  if (!_sha256.hasMatch(value)) throw ArgumentError.value(value, name);
}

final RegExp _sha256 = RegExp(r'^[0-9a-f]{64}$');
final RegExp _stableCode = RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$');
final RegExp _containsControlCharacters = RegExp(r'[\u0000-\u001f\u007f]');
final RegExp _embeddedPosixAbsolutePath = RegExp(r'(^|[^A-Za-z0-9._/-])/(?!/)');
final RegExp _embeddedDoubleSlashAbsolutePath = RegExp(
  r'(^|\s|["\x27=(\[{,;])//',
);
final RegExp _embeddedFileUri = RegExp(
  r'(^|[^A-Za-z0-9])file:/',
  caseSensitive: false,
);
final RegExp _embeddedWindowsAbsolutePath = RegExp(
  r'(^|[^A-Za-z0-9._-])[A-Za-z]:[/\\]',
);
const Set<String> _forbiddenValueKeys = <String>{
  'sourcebytes',
  'beforebytes',
  'afterbytes',
  'rawoutput',
  'rawstdout',
  'rawstderr',
  'environment',
  'environmentvalues',
  'env',
  'envvalues',
  'dartdefines',
};
const Set<String> _redactedStreamKeys = <String>{
  'sha256',
  'capturedBytes',
  'omittedBytes',
  'truncated',
};
