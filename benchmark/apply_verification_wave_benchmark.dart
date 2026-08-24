import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const applyVerificationWaveBenchmarkSchemaVersion = 2;
const applyVerificationWaveProtocolId =
    'apply-verification-wave-v2-block3-pairs6';
const sampleRepetitionsPerBlock = 3;
const counterbalancedPairSchedule = ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'];
const processExitDiagnosticTailByteLimit = 512;

/// Independently executable phases of the v2 admission protocol.
enum BenchmarkPhase { aa, ab }

/// Stable reasons that invalidate a complete fixture study.
enum BenchmarkInvalidReason {
  processExit('process_exit'),
  dependencyDrift('dependency_drift'),
  reportMissing('report_missing'),
  contractMismatch('contract_mismatch'),
  identityDrift('identity_drift'),
  artifactState('artifact_state');

  const BenchmarkInvalidReason(this.wireName);

  /// Sanitized artifact value.
  final String wireName;
}

/// Coordinates identifying one attempted benchmark sample.
final class BenchmarkSampleContext {
  /// Creates an immutable sample coordinate.
  const BenchmarkSampleContext({
    required this.phase,
    required this.profile,
    required this.pair,
    required this.order,
    required this.block,
    required this.repetition,
    required this.variant,
  });

  final String phase;
  final String profile;
  final int pair;
  final String order;
  final String block;
  final int repetition;
  final String variant;

  Map<String, Object?> toJson() => {
    'phase': phase,
    'profile': profile,
    'pair': pair,
    'order': order,
    'block': block,
    'repetition': repetition,
    'variant': variant,
  };
}

/// Failure carrying a sanitized benchmark invalidation reason and evidence.
final class BenchmarkStudyInvalidException implements Exception {
  /// Creates a benchmark invalidation.
  const BenchmarkStudyInvalidException(this.reason) : diagnostic = null;

  /// Creates a benchmark invalidation with an immutable diagnostic snapshot.
  BenchmarkStudyInvalidException.withDiagnostic(
    this.reason,
    Map<String, Object?> diagnostic,
  ) : diagnostic = _immutableJsonMap(diagnostic);

  /// Stable reason for invalidating the complete fixture study.
  final BenchmarkInvalidReason reason;

  /// Sanitized process evidence, when the invalidation came from a process.
  final Map<String, Object?>? diagnostic;
}

/// Frozen hashes that bind one benchmark artifact to its exact inputs.
final class BenchmarkInputIdentity {
  /// Creates a validated benchmark input identity.
  BenchmarkInputIdentity({
    required this.fixtureSha256,
    required this.aExecutableSha256,
    required this.bExecutableSha256,
    required this.aProgramSha256,
    required this.bProgramSha256,
    required this.harnessSha256,
    required this.generatorSha256,
    required this.boundaryPatchSha256,
    required this.verificationWavePatchSha256,
    required this.dartToolchainSha256,
    required this.flutterToolchainSha256,
    required this.applyArgumentsSha256,
  }) {
    for (final digest in toJson().values) {
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
        throw ArgumentError('Benchmark identities must be lowercase SHA-256.');
      }
    }
  }

  /// Hydrated fixture directory digest.
  final String fixtureSha256;

  /// Compiled legacy executable digest.
  final String aExecutableSha256;

  /// Compiled verification-wave executable digest.
  final String bExecutableSha256;

  /// Compiled legacy AOT program digest.
  final String aProgramSha256;

  /// Compiled verification-wave AOT program digest.
  final String bProgramSha256;

  /// Benchmark harness source digest.
  final String harnessSha256;

  /// Fixture generator source digest.
  final String generatorSha256;

  /// Shared auxiliary-test boundary patch digest.
  final String boundaryPatchSha256;

  /// Verification-wave production and test patch digest.
  final String verificationWavePatchSha256;

  /// Exact Dart SDK identity digest.
  final String dartToolchainSha256;

  /// Exact Flutter SDK identity digest.
  final String flutterToolchainSha256;

  /// Ordered apply argument policy digest.
  final String applyArgumentsSha256;

  /// Converts this identity to artifact fields.
  Map<String, String> toJson() => {
    'fixtureSha256': fixtureSha256,
    'aExecutableSha256': aExecutableSha256,
    'bExecutableSha256': bExecutableSha256,
    'aProgramSha256': aProgramSha256,
    'bProgramSha256': bProgramSha256,
    'harnessSha256': harnessSha256,
    'generatorSha256': generatorSha256,
    'boundaryPatchSha256': boundaryPatchSha256,
    'verificationWavePatchSha256': verificationWavePatchSha256,
    'dartToolchainSha256': dartToolchainSha256,
    'flutterToolchainSha256': flutterToolchainSha256,
    'applyArgumentsSha256': applyArgumentsSha256,
  };
}

/// Hashes every executable, source, patch, SDK, and ordered policy input.
Future<BenchmarkInputIdentity> createBenchmarkInputIdentity({
  required Directory fixture,
  required File executableA,
  required File executableB,
  required File programA,
  required File programB,
  required File harness,
  required File generator,
  required File boundaryPatch,
  required File verificationWavePatch,
  required String dartToolchainIdentity,
  required String flutterToolchainIdentity,
  required List<String> applyArguments,
}) async => BenchmarkInputIdentity(
  fixtureSha256: await _directorySha256(fixture),
  aExecutableSha256: await _fileSha256(executableA),
  bExecutableSha256: await _fileSha256(executableB),
  aProgramSha256: await _fileSha256(programA),
  bProgramSha256: await _fileSha256(programB),
  harnessSha256: await _fileSha256(harness),
  generatorSha256: await _fileSha256(generator),
  boundaryPatchSha256: await _fileSha256(boundaryPatch),
  verificationWavePatchSha256: await _fileSha256(verificationWavePatch),
  dartToolchainSha256: _stringSha256(dartToolchainIdentity),
  flutterToolchainSha256: _stringSha256(flutterToolchainIdentity),
  applyArgumentsSha256: _stringSha256(jsonEncode(applyArguments)),
);

/// Rejects any A/A artifact that is not bound to the exact v2 protocol inputs.
void validateFrozenAaArtifact(
  Map<String, Object?> artifact, {
  required BenchmarkInputIdentity expectedIdentity,
}) {
  final expected = <String, Object?>{
    'schemaVersion': applyVerificationWaveBenchmarkSchemaVersion,
    'protocolId': applyVerificationWaveProtocolId,
    'status': 'aa-frozen',
    'sampleRepetitionsPerBlock': sampleRepetitionsPerBlock,
    'schedule': counterbalancedPairSchedule,
    ...expectedIdentity.toJson(),
  };
  for (final entry in expected.entries) {
    final actual = artifact[entry.key];
    final matches = entry.value is List<String>
        ? _sameStrings(actual, entry.value! as List<String>)
        : actual == entry.value;
    if (!matches) {
      throw StateError('Frozen A/A artifact mismatches ${entry.key}.');
    }
  }
}

/// Runs A/A once and exclusively freezes its noise artifact.
Future<void> runAaPhase({
  required File output,
  required String profile,
  required BenchmarkInputIdentity identity,
  required Future<void> Function() warmup,
  required Future<void> Function(
    void Function(Map<String, Object?> pair) addPair,
  )
  measurePairs,
}) async {
  if (output.existsSync()) {
    throw StateError('A/A output already exists.');
  }
  final pairs = <Map<String, Object?>>[];
  final artifact = <String, Object?>{
    'schemaVersion': applyVerificationWaveBenchmarkSchemaVersion,
    'protocolId': applyVerificationWaveProtocolId,
    'profile': profile,
    'status': 'aa-running',
    'sampleRepetitionsPerBlock': sampleRepetitionsPerBlock,
    'schedule': counterbalancedPairSchedule,
    'aaPairs': pairs,
    ...identity.toJson(),
    'memory': 'informational-no-process-tree-sampler',
  };
  await output.parent.create(recursive: true);
  await output.create(exclusive: true);
  await _writeArtifact(output, artifact);
  try {
    await warmup();
    await measurePairs(pairs.add);
    _validatePairSequence(pairs);
    final metrics = recomputeAaMetrics(pairs);
    artifact
      ..['status'] = 'aa-frozen'
      ..addAll(metrics)
      ..['verificationPolicyHash'] = verificationPolicyFromPairs(pairs, const [
        'firstRepetitions',
        'secondRepetitions',
      ]);
    await _writeArtifact(output, artifact);
  } catch (error) {
    final reason = error is BenchmarkStudyInvalidException
        ? error.reason
        : BenchmarkInvalidReason.artifactState;
    artifact
      ..['status'] = 'invalid'
      ..['admitted'] = false
      ..['invalidReasonCode'] = reason.wireName
      ..['aaPairs'] = pairs;
    if (error is BenchmarkStudyInvalidException && error.diagnostic != null) {
      artifact['failureDiagnostic'] = error.diagnostic;
    }
    await _writeArtifact(output, artifact);
    rethrow;
  }
}

/// Runs A/B only from one exact immutable A/A artifact.
Future<void> runAbPhase({
  required File output,
  required List<File> cohortAaArtifacts,
  required BenchmarkInputIdentity expectedIdentity,
  required Future<void> Function() warmup,
  required Future<void> Function(
    void Function(Map<String, Object?> pair) addPair,
  )
  measurePairs,
}) async {
  if (!output.existsSync()) {
    throw StateError('A/B requires an existing A/A artifact.');
  }
  if (cohortAaArtifacts.any((artifact) => _sameFile(output, artifact))) {
    throw StateError('A/B requires detached immutable A/A cohort snapshots.');
  }
  final decoded = jsonDecode(await output.readAsString());
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('Benchmark artifact must be a JSON object.');
  }
  final artifact = Map<String, Object?>.from(decoded);
  if (artifact['schemaVersion'] !=
          applyVerificationWaveBenchmarkSchemaVersion ||
      artifact['status'] != 'aa-frozen') {
    throw StateError('A/B requires one v2 aa-frozen artifact.');
  }

  final pairs = <Map<String, Object?>>[];
  try {
    try {
      validateFrozenAaArtifact(artifact, expectedIdentity: expectedIdentity);
    } on StateError {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.identityDrift,
      );
    }
    await validateAaCohort(
      cohortAaArtifacts,
      currentArtifact: artifact,
      expectedIdentity: expectedIdentity,
    );
    _validateFrozenAaPayload(artifact);
    await warmup();
    await measurePairs(pairs.add);
    _validatePairSequence(pairs);
    final metrics = recomputeAbMetrics(pairs);
    final medianImprovement = metrics['medianImprovement']! as double;
    final fasterPairs = metrics['fasterPairs']! as int;
    final noiseThreshold = (artifact['noiseThreshold']! as num).toDouble();
    final profile = artifact['profile']! as String;
    final abPolicy = verificationPolicyFromPairs(pairs, const [
      'aRepetitions',
      'bRepetitions',
    ]);
    if (abPolicy != artifact['verificationPolicyHash']) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.identityDrift,
      );
    }
    artifact
      ..['status'] = 'complete'
      ..['abPairs'] = pairs
      ..addAll(metrics)
      ..['admitted'] = isProfileAdmitted(
        profile: profile,
        medianImprovement: medianImprovement,
        noiseThreshold: noiseThreshold,
        fasterPairs: fasterPairs,
      );
    await _writeArtifact(output, artifact);
  } catch (error) {
    final reason = error is BenchmarkStudyInvalidException
        ? error.reason
        : BenchmarkInvalidReason.artifactState;
    artifact
      ..['status'] = 'invalid'
      ..['admitted'] = false
      ..['invalidReasonCode'] = reason.wireName
      ..['abPairs'] = pairs;
    if (error is BenchmarkStudyInvalidException && error.diagnostic != null) {
      artifact['failureDiagnostic'] = error.diagnostic;
    }
    await _writeArtifact(output, artifact);
    rethrow;
  }
}

bool _sameFile(File left, File right) {
  final leftPath = p.normalize(p.absolute(left.path));
  final rightPath = p.normalize(p.absolute(right.path));
  if (p.equals(leftPath, rightPath)) return true;
  try {
    return FileSystemEntity.identicalSync(leftPath, rightPath);
  } on FileSystemException {
    return false;
  }
}

const _fixedProfiles = ['control-1x1', 'fanout-12x1', 'chain-2plus-rounds'];

/// Enforces the all-fixture A/A barrier before any A/B warmup.
Future<void> validateAaCohort(
  List<File> files, {
  required Map<String, Object?> currentArtifact,
  required BenchmarkInputIdentity expectedIdentity,
}) async {
  if (files.length != _fixedProfiles.length) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  final profiles = <String>{};
  Map<String, Object?>? shared;
  for (final file in files) {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.artifactState,
      );
    }
    final artifact = Map<String, Object?>.from(decoded);
    final profile = artifact['profile'];
    if (profile is! String ||
        !_fixedProfiles.contains(profile) ||
        !profiles.add(profile)) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.artifactState,
      );
    }
    if (artifact['schemaVersion'] !=
            applyVerificationWaveBenchmarkSchemaVersion ||
        artifact['protocolId'] != applyVerificationWaveProtocolId ||
        artifact['status'] != 'aa-frozen') {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.artifactState,
      );
    }
    _validateFrozenAaPayload(artifact);
    shared ??= artifact;
    for (final key in const [
      'aExecutableSha256',
      'bExecutableSha256',
      'aProgramSha256',
      'bProgramSha256',
      'harnessSha256',
      'generatorSha256',
      'boundaryPatchSha256',
      'verificationWavePatchSha256',
      'dartToolchainSha256',
      'flutterToolchainSha256',
      'applyArgumentsSha256',
      'verificationPolicyHash',
    ]) {
      if (artifact[key] != shared[key]) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.identityDrift,
        );
      }
    }
  }
  if (!profiles.containsAll(_fixedProfiles)) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  validateFrozenAaArtifact(currentArtifact, expectedIdentity: expectedIdentity);
}

void _validateFrozenAaPayload(Map<String, Object?> artifact) {
  final pairs = artifact['aaPairs'];
  final threshold = artifact['noiseThreshold'];
  final profile = artifact['profile'];
  if (pairs is! List ||
      pairs.length != counterbalancedPairSchedule.length ||
      threshold is! num ||
      threshold < 0 ||
      profile is! String) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  final rawPairs = pairs
      .map((pair) => Map<String, Object?>.from(pair as Map))
      .toList(growable: false);
  final recomputed = recomputeAaMetrics(rawPairs);
  _requireStoredMetric(
    artifact,
    'noiseThreshold',
    recomputed['noiseThreshold']! as num,
  );
  if (jsonEncode(artifact['aaPairedRelativeDeltas']) !=
      jsonEncode(recomputed['aaPairedRelativeDeltas'])) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  if (artifact['verificationPolicyHash'] !=
      verificationPolicyFromPairs(rawPairs, const [
        'firstRepetitions',
        'secondRepetitions',
      ])) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.identityDrift,
    );
  }
}

void _validatePairSequence(List<Map<String, Object?>> pairs) {
  if (pairs.length != counterbalancedPairSchedule.length) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  for (var index = 0; index < pairs.length; index++) {
    if (pairs[index]['order'] != counterbalancedPairSchedule[index]) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.artifactState,
      );
    }
  }
}

/// Extracts only aggregate phase timings and the real verifier attempt count.
Map<String, Object?> extractSanitizedReportEvidence(
  Map<String, Object?> report, {
  required bool waveMode,
}) {
  try {
    if (report['version'] != 3) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.reportMissing,
      );
    }
    final run = _requiredObjectMap(report, 'run');
    if (run['command'] != 'apply' ||
        run['status'] != 'completed' ||
        run['exitCode'] != 0) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
    final runElapsedMicros = _nonnegativeInt(run, 'elapsedMicros');
    final execution = _requiredObjectMap(report, 'execution');
    final analysisPasses = _requiredObjectList(execution, 'analysisPasses');
    var analysisElapsedMicros = 0;
    for (final pass in analysisPasses) {
      analysisElapsedMicros += _nonnegativeInt(pass, 'elapsedMicros');
    }
    final attempts = _requiredObjectList(report, 'verificationAttempts');
    if (attempts.isEmpty || attempts.first['purpose'] != 'baseline') {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
    var verificationElapsedMicros = 0;
    var candidateVerificationElapsedMicros = 0;
    final verificationAttemptTransactionIds = <Object?>[];
    final verificationWaveIds = <String>[];
    String? policyHash;
    List<String>? requiredSteps;
    for (var attemptIndex = 0; attemptIndex < attempts.length; attemptIndex++) {
      final attempt = attempts[attemptIndex];
      final purpose = attemptIndex == 0 ? 'baseline' : 'candidate';
      if (attempt['purpose'] != purpose ||
          attempt['complete'] != true ||
          attempt['available'] != true ||
          attempt['accepted'] != true) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.contractMismatch,
        );
      }
      final attemptPolicy = attempt['policyHash'];
      final required = _requiredStrings(attempt, 'requiredStepIds');
      final observed = _requiredStrings(attempt, 'observedStepIds');
      if (attemptPolicy is! String ||
          attemptPolicy.isEmpty ||
          required.isEmpty ||
          !_sameStrings(observed, required)) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.contractMismatch,
        );
      }
      policyHash ??= attemptPolicy;
      requiredSteps ??= required;
      if (attemptPolicy != policyHash ||
          !_sameStrings(required, requiredSteps)) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.contractMismatch,
        );
      }
      if (attemptIndex == 0) {
        if (attempt.containsKey('waveId') ||
            attempt.containsKey('transactionId') ||
            attempt.containsKey('transactionIds')) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.contractMismatch,
          );
        }
      } else if (waveMode) {
        final waveId = attempt['waveId'];
        final round = attempt['round'];
        final transactionIds = _requiredStrings(attempt, 'transactionIds');
        final expectedWaveId = round is int
            ? 'wave-r${round.toString().padLeft(3, '0')}'
            : null;
        if (waveId is! String ||
            waveId != expectedWaveId ||
            round is! int ||
            round != attemptIndex ||
            transactionIds.isEmpty) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.contractMismatch,
          );
        }
        verificationWaveIds.add(waveId);
        if (transactionIds.length == 1
            ? attempt['transactionId'] != transactionIds.single
            : attempt.containsKey('transactionId')) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.contractMismatch,
          );
        }
        verificationAttemptTransactionIds.add(transactionIds);
      } else if (attempt['transactionId'] is! String ||
          attempt.containsKey('waveId') ||
          attempt.containsKey('transactionIds')) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.contractMismatch,
        );
      } else {
        verificationAttemptTransactionIds.add(attempt['transactionId']);
      }
      final steps = _requiredObjectList(attempt, 'steps');
      if (steps.length != required.length) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.contractMismatch,
        );
      }
      var attemptElapsedMicros = 0;
      for (var stepIndex = 0; stepIndex < steps.length; stepIndex++) {
        final step = steps[stepIndex];
        if (step['id'] != required[stepIndex] ||
            step['passed'] is! bool ||
            step['available'] != true) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.contractMismatch,
          );
        }
        attemptElapsedMicros += _nonnegativeInt(step, 'elapsedMicros');
      }
      verificationElapsedMicros += attemptElapsedMicros;
      if (purpose == 'candidate') {
        candidateVerificationElapsedMicros += attemptElapsedMicros;
      }
    }
    final accountedElapsedMicros =
        verificationElapsedMicros + analysisElapsedMicros;
    if (runElapsedMicros < accountedElapsedMicros) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
    return {
      'runElapsedMicros': runElapsedMicros,
      'verificationElapsedMicros': verificationElapsedMicros,
      'candidateVerificationElapsedMicros': candidateVerificationElapsedMicros,
      'analysisElapsedMicros': analysisElapsedMicros,
      'unaccountedElapsedMicros': runElapsedMicros - accountedElapsedMicros,
      'verificationAttempts': attempts.length,
      'verificationPolicyHash': policyHash,
      'verificationAttemptTransactionIds': verificationAttemptTransactionIds,
      'verificationWaveIds': verificationWaveIds,
    };
  } on BenchmarkStudyInvalidException {
    rethrow;
  } catch (_) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
}

List<String> _requiredStrings(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! List || value.any((item) => item is! String)) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
  return value.cast<String>();
}

/// Frozen, profile-specific correctness oracle independent of observed runs.
final class FrozenProfileExpectation {
  const FrozenProfileExpectation({
    required this.finalHash,
    required this.transactionIds,
    required this.rounds,
    required this.waveTransactionIds,
  });

  final String finalHash;
  final List<String> transactionIds;
  final int rounds;
  final List<List<String>> waveTransactionIds;

  Map<String, Object?> toContract() => {
    'finalHash': finalHash,
    'transactionIds': transactionIds,
    'transactionCount': transactionIds.length,
    'roundCount': rounds,
    'transactionRounds': transactionIds
        .map((id) => int.parse(id.substring(4, 7)))
        .toList(growable: false),
    'lifecycleState': 'completed',
    'transactionStatuses': [for (final _ in transactionIds) 'committed'],
    'caseStatuses': [for (final _ in transactionIds) 'kept'],
    'waveCount': waveTransactionIds.length,
    'waveIds': [
      for (var index = 0; index < waveTransactionIds.length; index++)
        'wave-r${(index + 1).toString().padLeft(3, '0')}',
    ],
    'waveTransactionIds': waveTransactionIds,
    'verificationAttemptTransactionIds': waveTransactionIds.isEmpty
        ? transactionIds
        : waveTransactionIds,
    'verificationWaveIds': [
      for (var index = 0; index < waveTransactionIds.length; index++)
        'wave-r${(index + 1).toString().padLeft(3, '0')}',
    ],
  };
}

const _profileExpectations = <String, FrozenProfileExpectation>{
  'control-1x1': FrozenProfileExpectation(
    finalHash:
        '20b802cc8b8e8450d51b4d0e3129f8a12234fcecdb837c46d08ba07d2241d4ab',
    transactionIds: ['tx-r001-684bc85bbc3c8df4'],
    rounds: 1,
    waveTransactionIds: [
      ['tx-r001-684bc85bbc3c8df4'],
    ],
  ),
  'fanout-12x1': FrozenProfileExpectation(
    finalHash:
        'd0424daf77bf0eba2561cafa19fea8443721d7adf49a94535a7a84974328a3cc',
    transactionIds: [
      'tx-r001-46a49063e4f578de',
      'tx-r001-4879542beff1b8c1',
      'tx-r001-1cdd750b56674f5f',
      'tx-r001-11ac5552f25e1263',
      'tx-r001-b5167248ff914a16',
      'tx-r001-d1f66fa0e986d053',
      'tx-r001-c2d88b290f349e98',
      'tx-r001-5e91c5a2f6f94bdf',
      'tx-r001-f02c6c3d45391824',
      'tx-r001-6131a648ad0402fb',
      'tx-r001-3a2235ac8378de35',
      'tx-r001-d6654ce277b33c8a',
    ],
    rounds: 1,
    waveTransactionIds: [
      [
        'tx-r001-46a49063e4f578de',
        'tx-r001-4879542beff1b8c1',
        'tx-r001-1cdd750b56674f5f',
        'tx-r001-11ac5552f25e1263',
        'tx-r001-b5167248ff914a16',
        'tx-r001-d1f66fa0e986d053',
        'tx-r001-c2d88b290f349e98',
        'tx-r001-5e91c5a2f6f94bdf',
        'tx-r001-f02c6c3d45391824',
        'tx-r001-6131a648ad0402fb',
        'tx-r001-3a2235ac8378de35',
        'tx-r001-d6654ce277b33c8a',
      ],
    ],
  ),
  'chain-2plus-rounds': FrozenProfileExpectation(
    finalHash:
        '34977be4ee49a99cd4e51ec4eedea77ff48cc8ab67ebe343176b332ecb0b1ff8',
    transactionIds: [
      'tx-r001-d658d0dcda49860a',
      'tx-r001-f005296c3145a378',
      'tx-r002-3dcde5f611f53f8e',
      'tx-r002-d460280f9eb71e6e',
    ],
    rounds: 2,
    waveTransactionIds: [
      ['tx-r001-d658d0dcda49860a', 'tx-r001-f005296c3145a378'],
      ['tx-r002-3dcde5f611f53f8e', 'tx-r002-d460280f9eb71e6e'],
    ],
  ),
};

FrozenProfileExpectation frozenProfileExpectation(
  String profile, {
  required bool waveMode,
}) {
  final expectation = _profileExpectations[profile];
  if (expectation == null) throw ArgumentError.value(profile, 'profile');
  if (waveMode) return expectation;
  return FrozenProfileExpectation(
    finalHash: expectation.finalHash,
    transactionIds: expectation.transactionIds,
    rounds: expectation.rounds,
    waveTransactionIds: const [],
  );
}

/// Rejects a run unless it exactly matches the immutable fixture oracle.
void validateFrozenProfileContract(
  String profile,
  Map<String, Object?> contract, {
  required bool waveMode,
}) {
  final expected = frozenProfileExpectation(
    profile,
    waveMode: waveMode,
  ).toContract();
  for (final entry in expected.entries) {
    if (jsonEncode(contract[entry.key]) != jsonEncode(entry.value)) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
  }
}

/// Validates three exact fresh-copy contracts for one measured block.
void validateBenchmarkRepetitionContracts(
  List<Map<String, Object?>> contracts, {
  required int expectedTransactions,
  required int expectedRounds,
  required int expectedVerifierInvocations,
  required int expectedWaves,
  String? profile,
  bool? waveMode,
}) {
  if (contracts.length != sampleRepetitionsPerBlock) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.contractMismatch,
    );
  }
  final first = contracts.first;
  final firstHash = first['finalHash'];
  final firstTransactionIds = first['transactionIds'];
  if (firstHash is! String ||
      !RegExp(r'^[0-9a-f]{64}$').hasMatch(firstHash) ||
      firstTransactionIds is! List ||
      firstTransactionIds.length != expectedTransactions ||
      firstTransactionIds.any((value) => value is! String) ||
      firstTransactionIds.toSet().length != firstTransactionIds.length) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.contractMismatch,
    );
  }
  for (final contract in contracts) {
    if (contract['finalHash'] != firstHash ||
        jsonEncode(contract['transactionIds']) !=
            jsonEncode(firstTransactionIds) ||
        contract['transactionCount'] != expectedTransactions ||
        contract['roundCount'] != expectedRounds ||
        contract['verifierInvocationCount'] != expectedVerifierInvocations ||
        contract['waveCount'] != expectedWaves) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
    if (profile != null && waveMode != null) {
      validateFrozenProfileContract(profile, contract, waveMode: waveMode);
    }
  }
}

Map<String, Object?> _requiredObjectMap(
  Map<String, Object?> source,
  String key,
) {
  final value = source[key];
  if (value is! Map) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
  return Map<String, Object?>.from(value);
}

List<Map<String, Object?>> _requiredObjectList(
  Map<String, Object?> source,
  String key,
) {
  final value = source[key];
  if (value is! List) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
  return value
      .map((item) {
        if (item is! Map) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.reportMissing,
          );
        }
        return Map<String, Object?>.from(item);
      })
      .toList(growable: false);
}

int _nonnegativeInt(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! int) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
  if (value < 0) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.contractMismatch,
    );
  }
  return value;
}

bool _sameStrings(Object? actual, List<String> expected) {
  if (actual is! List || actual.length != expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

int blockElapsedMicros(List<int> repetitions) {
  if (repetitions.length != sampleRepetitionsPerBlock ||
      repetitions.any((value) => value <= 0)) {
    throw ArgumentError('A measured block requires three positive runs.');
  }
  return repetitions.reduce((a, b) => a + b);
}

double pairedRelativeDelta(Duration a, Duration b) =>
    (a.inMicroseconds - b.inMicroseconds) / a.inMicroseconds;

double median(List<double> values) {
  if (values.isEmpty) throw ArgumentError('median requires samples');
  final sorted = [...values]..sort();
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd
      ? sorted[middle]
      : (sorted[middle - 1] + sorted[middle]) / 2;
}

double frozenNoiseThreshold(List<double> aaDeltas) =>
    aaDeltas.map((value) => value.abs()).reduce((a, b) => a > b ? a : b);

/// Recomputes A/A totals, deltas, and frozen noise solely from repetitions.
Map<String, Object?> recomputeAaMetrics(List<Map<String, Object?>> pairs) {
  _validatePairSequence(pairs);
  final deltas = <double>[];
  for (final pair in pairs) {
    final first = _rawBlockElapsed(pair['firstRepetitions']);
    final second = _rawBlockElapsed(pair['secondRepetitions']);
    final delta = pair['order'] == 'AB'
        ? (first - second) / first
        : (second - first) / second;
    _requireStoredMetric(pair, 'firstBlockElapsedMicros', first);
    _requireStoredMetric(pair, 'secondBlockElapsedMicros', second);
    _requireStoredMetric(pair, 'pairedRelativeDelta', delta);
    deltas.add(delta);
  }
  return {
    'noiseThreshold': frozenNoiseThreshold(deltas),
    'aaPairedRelativeDeltas': deltas,
  };
}

/// Recomputes A/B totals, deltas, median, and wins solely from repetitions.
Map<String, Object?> recomputeAbMetrics(List<Map<String, Object?>> pairs) {
  _validatePairSequence(pairs);
  final deltas = <double>[];
  for (final pair in pairs) {
    final a = _rawBlockElapsed(pair['aRepetitions']);
    final b = _rawBlockElapsed(pair['bRepetitions']);
    final delta = (a - b) / a;
    _requireStoredMetric(pair, 'aBlockElapsedMicros', a);
    _requireStoredMetric(pair, 'bBlockElapsedMicros', b);
    _requireStoredMetric(pair, 'pairedRelativeDelta', delta);
    deltas.add(delta);
  }
  return {
    'abPairedRelativeDeltas': deltas,
    'medianImprovement': median(deltas),
    'fasterPairs': deltas.where((delta) => delta > 0).length,
  };
}

/// Derives and validates one policy identity from all raw repetitions.
String verificationPolicyFromPairs(
  List<Map<String, Object?>> pairs,
  List<String> repetitionKeys,
) {
  String? policy;
  for (final pair in pairs) {
    for (final key in repetitionKeys) {
      final repetitions = pair[key];
      if (repetitions is! List) {
        throw const BenchmarkStudyInvalidException(
          BenchmarkInvalidReason.artifactState,
        );
      }
      for (final repetition in repetitions) {
        if (repetition is! Map || repetition['timings'] is! Map) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.artifactState,
          );
        }
        final value = (repetition['timings']! as Map)['verificationPolicyHash'];
        if (value is! String || value.isEmpty) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.artifactState,
          );
        }
        policy ??= value;
        if (value != policy) {
          throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.identityDrift,
          );
        }
      }
    }
  }
  if (policy == null) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  return policy;
}

int _rawBlockElapsed(Object? value) {
  if (value is! List || value.length != sampleRepetitionsPerBlock) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
  final elapsed = <int>[];
  for (final repetition in value) {
    if (repetition is! Map || repetition['elapsedMicros'] is! int) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.artifactState,
      );
    }
    elapsed.add(repetition['elapsedMicros']! as int);
  }
  try {
    return blockElapsedMicros(elapsed);
  } on ArgumentError {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
}

void _requireStoredMetric(
  Map<String, Object?> source,
  String key,
  num recomputed,
) {
  final stored = source[key];
  if (stored is! num ||
      (stored.toDouble() - recomputed.toDouble()).abs() > 1e-12) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.artifactState,
    );
  }
}

Map<String, Object?> aaBlockPairRecord({
  required String order,
  required List<Map<String, Object?>> firstRepetitions,
  required List<Map<String, Object?>> secondRepetitions,
}) {
  _validatePairOrder(order);
  final firstBlockElapsedMicros = _blockElapsedFromEvidence(firstRepetitions);
  final secondBlockElapsedMicros = _blockElapsedFromEvidence(secondRepetitions);
  final first = Duration(microseconds: firstBlockElapsedMicros);
  final second = Duration(microseconds: secondBlockElapsedMicros);
  return {
    'order': order,
    'firstRepetitions': List<Map<String, Object?>>.unmodifiable(
      firstRepetitions,
    ),
    'secondRepetitions': List<Map<String, Object?>>.unmodifiable(
      secondRepetitions,
    ),
    'firstBlockElapsedMicros': firstBlockElapsedMicros,
    'secondBlockElapsedMicros': secondBlockElapsedMicros,
    'pairedRelativeDelta': order == 'AB'
        ? pairedRelativeDelta(first, second)
        : pairedRelativeDelta(second, first),
  };
}

Map<String, Object?> abBlockPairRecord({
  required String order,
  required List<Map<String, Object?>> aRepetitions,
  required List<Map<String, Object?>> bRepetitions,
}) {
  _validatePairOrder(order);
  final aBlockElapsedMicros = _blockElapsedFromEvidence(aRepetitions);
  final bBlockElapsedMicros = _blockElapsedFromEvidence(bRepetitions);
  return {
    'order': order,
    'aRepetitions': List<Map<String, Object?>>.unmodifiable(aRepetitions),
    'bRepetitions': List<Map<String, Object?>>.unmodifiable(bRepetitions),
    'aBlockElapsedMicros': aBlockElapsedMicros,
    'bBlockElapsedMicros': bBlockElapsedMicros,
    'pairedRelativeDelta': pairedRelativeDelta(
      Duration(microseconds: aBlockElapsedMicros),
      Duration(microseconds: bBlockElapsedMicros),
    ),
  };
}

bool isProfileAdmitted({
  required String profile,
  required double medianImprovement,
  required double noiseThreshold,
  required int fasterPairs,
}) => profile == 'control-1x1'
    ? medianImprovement >= -noiseThreshold
    : medianImprovement > noiseThreshold && fasterPairs >= 5;

int _blockElapsedFromEvidence(List<Map<String, Object?>> repetitions) =>
    blockElapsedMicros(
      repetitions.map((item) => item['elapsedMicros'] as int).toList(),
    );

void _validatePairOrder(String order) {
  if (order != 'AB' && order != 'BA') {
    throw ArgumentError.value(order, 'order', 'must be AB or BA');
  }
}

/// Creates the strict command-line contract for the v2 benchmark phases.
ArgParser createApplyVerificationBenchmarkParser() => ArgParser()
  ..addOption(
    'phase',
    allowed: BenchmarkPhase.values.map((phase) => phase.name),
    mandatory: true,
  )
  ..addOption('fixture', mandatory: true)
  ..addOption('a-executable', mandatory: true)
  ..addOption('b-executable', mandatory: true)
  ..addOption('a-program', mandatory: true)
  ..addOption('b-program', mandatory: true)
  ..addOption('output', mandatory: true)
  ..addOption('generator', mandatory: true)
  ..addOption('boundary-patch', mandatory: true)
  ..addOption('verification-wave-patch', mandatory: true)
  ..addMultiOption('aa-cohort-artifact')
  ..addMultiOption(
    'apply-arg',
    defaultsTo: const ['--adapter', 'dart', '--yes'],
  );

/// Parses and fail-closes every path required before benchmark execution.
ArgResults parseApplyVerificationBenchmarkArguments(List<String> arguments) {
  final results = createApplyVerificationBenchmarkParser().parse(arguments);
  for (final option in const [
    'phase',
    'fixture',
    'a-executable',
    'b-executable',
    'a-program',
    'b-program',
    'output',
    'generator',
    'boundary-patch',
    'verification-wave-patch',
  ]) {
    if (!results.wasParsed(option)) {
      throw FormatException('Missing required option --$option.');
    }
  }
  return results;
}

/// Builds the exact runtime argv used for warmups and measured samples.
({String executable, List<String> arguments}) benchmarkProcessInvocation({
  required File runtime,
  required File program,
  required List<String> applyArguments,
  required Directory project,
}) => (
  executable: runtime.path,
  arguments: List<String>.unmodifiable([
    program.path,
    'apply',
    ...applyArguments,
    project.path,
  ]),
);

/// Preserves a failed synthetic sample and returns bounded sanitized evidence.
Future<Map<String, Object?>> retainProcessExitEvidence({
  required Directory sampleProject,
  required Directory evidenceRoot,
  required BenchmarkSampleContext context,
  required int exitCode,
  required String stdout,
  required String stderr,
}) async {
  if (evidenceRoot.existsSync()) {
    throw StateError('Process-exit evidence already exists.');
  }
  await evidenceRoot.create(recursive: true);
  final preservedProject = Directory(
    p.join(evidenceRoot.path, 'sample-project'),
  );
  await _copyDirectory(
    sampleProject,
    preservedProject,
    excludeFlutterPruner: false,
  );
  final diagnostic = _immutableJsonMap({
    ...context.toJson(),
    'exitCode': exitCode,
    'stdout': _sanitizedStreamEvidence(stdout, sampleProject),
    'stderr': _sanitizedStreamEvidence(stderr, sampleProject),
    'evidenceRef': p.join(p.basename(evidenceRoot.path), 'sample-project'),
  });
  await File(
    p.join(evidenceRoot.path, 'diagnostic.json'),
  ).writeAsString(jsonEncode(diagnostic), flush: true);
  return diagnostic;
}

/// Removes only the ephemeral study root; retained sidecars live outside it.
void cleanupBenchmarkStudyRoot(Directory studyRoot) {
  if (studyRoot.existsSync()) {
    studyRoot.deleteSync(recursive: true);
  }
}

Map<String, Object?> aaPairRecord({
  required String order,
  required Duration first,
  required Duration second,
  required Map<String, Object?> firstContract,
  required Map<String, Object?> secondContract,
}) {
  final delta = order == 'AB'
      ? pairedRelativeDelta(first, second)
      : pairedRelativeDelta(second, first);
  return {
    'order': order,
    'firstElapsedMicros': first.inMicroseconds,
    'secondElapsedMicros': second.inMicroseconds,
    'pairedRelativeDelta': delta,
    'firstContract': firstContract,
    'secondContract': secondContract,
  };
}

Map<String, Object?> abPairRecord({
  required String order,
  required Duration a,
  required Duration b,
  required Map<String, Object?> aContract,
  required Map<String, Object?> bContract,
}) => {
  'order': order,
  'aElapsedMicros': a.inMicroseconds,
  'bElapsedMicros': b.inMicroseconds,
  'pairedRelativeDelta': pairedRelativeDelta(a, b),
  'aContract': aContract,
  'bContract': bContract,
};

Future<void> main(List<String> arguments) async {
  final options = parseApplyVerificationBenchmarkArguments(arguments);
  final phase = BenchmarkPhase.values.byName(options.option('phase')!);
  final fixture = Directory(p.absolute(options.option('fixture')!));
  final executableA = File(p.absolute(options.option('a-executable')!));
  final executableB = File(p.absolute(options.option('b-executable')!));
  final programA = File(p.absolute(options.option('a-program')!));
  final programB = File(p.absolute(options.option('b-program')!));
  final output = File(p.absolute(options.option('output')!));
  final generator = File(p.absolute(options.option('generator')!));
  final boundaryPatch = File(p.absolute(options.option('boundary-patch')!));
  final verificationWavePatch = File(
    p.absolute(options.option('verification-wave-patch')!),
  );
  for (final required in [
    File(p.join(fixture.path, 'pubspec.lock')),
    File(p.join(fixture.path, '.dart_tool', 'package_config.json')),
    executableA,
    executableB,
    programA,
    programB,
    generator,
    boundaryPatch,
    verificationWavePatch,
  ]) {
    if (!required.existsSync()) {
      throw StateError(
        'Benchmark input is not hydrated or compiled: ${required.path}',
      );
    }
  }
  final fixtureContract =
      jsonDecode(
            await File(
              p.join(fixture.path, 'fixture-contract.json'),
            ).readAsString(),
          )
          as Map<String, dynamic>;
  final profile = fixtureContract['profile'] as String;
  final expectedUnits = fixtureContract['expectedUnits'] as int;
  final expectedRounds = fixtureContract['expectedRounds'] as int;
  final argumentsForApply = options.multiOption('apply-arg');
  final flutterVersion = await Process.run('flutter', const [
    '--version',
    '--machine',
  ]);
  if (flutterVersion.exitCode != 0) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.identityDrift,
    );
  }
  final identity = await createBenchmarkInputIdentity(
    fixture: fixture,
    executableA: executableA,
    executableB: executableB,
    programA: programA,
    programB: programB,
    harness: File(Platform.script.toFilePath()),
    generator: generator,
    boundaryPatch: boundaryPatch,
    verificationWavePatch: verificationWavePatch,
    dartToolchainIdentity: Platform.version,
    flutterToolchainIdentity: flutterVersion.stdout as String,
    applyArguments: argumentsForApply,
  );
  final studyRoot = Directory.systemTemp.createTempSync('apply_wave_study_');
  final evidenceRoot = Directory('${output.path}.failure-evidence');
  try {
    Future<List<Map<String, Object?>>> measureBlock(
      File executable,
      File program, {
      required int expectedVerifierInvocations,
      required int expectedWaves,
      required BenchmarkSampleContext context,
    }) => _sampleBlock(
      executable: executable,
      program: program,
      fixture: fixture,
      studyRoot: studyRoot,
      evidenceRoot: evidenceRoot,
      applyArguments: argumentsForApply,
      expectedTransactions: expectedUnits,
      expectedRounds: expectedRounds,
      expectedVerifierInvocations: expectedVerifierInvocations,
      expectedWaves: expectedWaves,
      profile: profile,
      waveMode: expectedWaves > 0,
      context: context,
    );

    Future<void> warmup(
      File executable,
      File program, {
      required int expectedVerifierInvocations,
      required int expectedWaves,
      required String phase,
      required String variant,
    }) async {
      final sample = await _sample(
        executable,
        program,
        fixture,
        studyRoot,
        argumentsForApply,
        waveMode: expectedWaves > 0,
        evidenceRoot: evidenceRoot,
        context: BenchmarkSampleContext(
          phase: phase,
          profile: profile,
          pair: 0,
          order: 'warmup',
          block: 'warmup',
          repetition: 1,
          variant: variant,
        ),
      );
      _requireExpectedContract(
        sample.contract,
        expectedTransactions: expectedUnits,
        expectedRounds: expectedRounds,
        expectedVerifierInvocations: expectedVerifierInvocations,
        expectedWaves: expectedWaves,
        profile: profile,
        waveMode: expectedWaves > 0,
      );
    }

    switch (phase) {
      case BenchmarkPhase.aa:
        await runAaPhase(
          output: output,
          profile: profile,
          identity: identity,
          warmup: () => warmup(
            executableA,
            programA,
            expectedVerifierInvocations: 1 + expectedUnits,
            expectedWaves: 0,
            phase: 'aa',
            variant: 'A',
          ),
          measurePairs: (addPair) async {
            for (
              var pairIndex = 0;
              pairIndex < counterbalancedPairSchedule.length;
              pairIndex++
            ) {
              final order = counterbalancedPairSchedule[pairIndex];
              addPair(
                aaBlockPairRecord(
                  order: order,
                  firstRepetitions: await measureBlock(
                    executableA,
                    programA,
                    expectedVerifierInvocations: 1 + expectedUnits,
                    expectedWaves: 0,
                    context: BenchmarkSampleContext(
                      phase: 'aa',
                      profile: profile,
                      pair: pairIndex + 1,
                      order: order,
                      block: 'first',
                      repetition: 0,
                      variant: 'A',
                    ),
                  ),
                  secondRepetitions: await measureBlock(
                    executableA,
                    programA,
                    expectedVerifierInvocations: 1 + expectedUnits,
                    expectedWaves: 0,
                    context: BenchmarkSampleContext(
                      phase: 'aa',
                      profile: profile,
                      pair: pairIndex + 1,
                      order: order,
                      block: 'second',
                      repetition: 0,
                      variant: 'A',
                    ),
                  ),
                ),
              );
            }
          },
        );
      case BenchmarkPhase.ab:
        await runAbPhase(
          output: output,
          cohortAaArtifacts: options
              .multiOption('aa-cohort-artifact')
              .map((path) => File(p.absolute(path)))
              .toList(growable: false),
          expectedIdentity: identity,
          warmup: () async {
            await warmup(
              executableA,
              programA,
              expectedVerifierInvocations: 1 + expectedUnits,
              expectedWaves: 0,
              phase: 'ab',
              variant: 'A',
            );
            await warmup(
              executableB,
              programB,
              expectedVerifierInvocations: 1 + expectedRounds,
              expectedWaves: expectedRounds,
              phase: 'ab',
              variant: 'B',
            );
          },
          measurePairs: (addPair) async {
            for (
              var pairIndex = 0;
              pairIndex < counterbalancedPairSchedule.length;
              pairIndex++
            ) {
              final order = counterbalancedPairSchedule[pairIndex];
              late final List<Map<String, Object?>> a;
              late final List<Map<String, Object?>> b;
              if (order == 'AB') {
                a = await measureBlock(
                  executableA,
                  programA,
                  expectedVerifierInvocations: 1 + expectedUnits,
                  expectedWaves: 0,
                  context: BenchmarkSampleContext(
                    phase: 'ab',
                    profile: profile,
                    pair: pairIndex + 1,
                    order: order,
                    block: 'first',
                    repetition: 0,
                    variant: 'A',
                  ),
                );
                b = await measureBlock(
                  executableB,
                  programB,
                  expectedVerifierInvocations: 1 + expectedRounds,
                  expectedWaves: expectedRounds,
                  context: BenchmarkSampleContext(
                    phase: 'ab',
                    profile: profile,
                    pair: pairIndex + 1,
                    order: order,
                    block: 'second',
                    repetition: 0,
                    variant: 'B',
                  ),
                );
              } else {
                b = await measureBlock(
                  executableB,
                  programB,
                  expectedVerifierInvocations: 1 + expectedRounds,
                  expectedWaves: expectedRounds,
                  context: BenchmarkSampleContext(
                    phase: 'ab',
                    profile: profile,
                    pair: pairIndex + 1,
                    order: order,
                    block: 'first',
                    repetition: 0,
                    variant: 'B',
                  ),
                );
                a = await measureBlock(
                  executableA,
                  programA,
                  expectedVerifierInvocations: 1 + expectedUnits,
                  expectedWaves: 0,
                  context: BenchmarkSampleContext(
                    phase: 'ab',
                    profile: profile,
                    pair: pairIndex + 1,
                    order: order,
                    block: 'second',
                    repetition: 0,
                    variant: 'A',
                  ),
                );
              }
              for (var index = 0; index < sampleRepetitionsPerBlock; index++) {
                _requireSameCorrectness(
                  a[index]['contract']! as Map<String, Object?>,
                  b[index]['contract']! as Map<String, Object?>,
                );
              }
              addPair(
                abBlockPairRecord(
                  order: order,
                  aRepetitions: a,
                  bRepetitions: b,
                ),
              );
            }
          },
        );
    }
  } finally {
    cleanupBenchmarkStudyRoot(studyRoot);
  }
}

Future<_Sample> _sample(
  File executable,
  File program,
  Directory fixture,
  Directory studyRoot,
  List<String> applyArguments, {
  required bool waveMode,
  required Directory evidenceRoot,
  required BenchmarkSampleContext context,
}) async {
  final project = Directory(
    p.join(studyRoot.path, 'sample-${DateTime.now().microsecondsSinceEpoch}'),
  );
  await _copyDirectory(fixture, project);
  final lockfile = File(p.join(project.path, 'pubspec.lock'));
  final packageConfig = File(
    p.join(project.path, '.dart_tool', 'package_config.json'),
  );
  final lockfileBefore = await _fileSha256(lockfile);
  final packageConfigBefore = await _fileSha256(packageConfig);
  final watch = Stopwatch()..start();
  final invocation = benchmarkProcessInvocation(
    runtime: executable,
    program: program,
    applyArguments: applyArguments,
    project: project,
  );
  final result = await Process.run(
    invocation.executable,
    invocation.arguments,
    workingDirectory: project.path,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  watch.stop();
  if (result.exitCode != 0) {
    final diagnostic = await retainProcessExitEvidence(
      sampleProject: project,
      evidenceRoot: evidenceRoot,
      context: context,
      exitCode: result.exitCode,
      stdout: result.stdout as String,
      stderr: result.stderr as String,
    );
    throw BenchmarkStudyInvalidException.withDiagnostic(
      BenchmarkInvalidReason.processExit,
      diagnostic,
    );
  }
  if (await _fileSha256(lockfile) != lockfileBefore ||
      await _fileSha256(packageConfig) != packageConfigBefore) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.dependencyDrift,
    );
  }
  final report = await _readCanonicalReport(project);
  final timings = extractSanitizedReportEvidence(report, waveMode: waveMode);
  return _Sample(
    elapsed: watch.elapsed,
    contract: await _correctnessContract(project, timings: timings),
    timings: timings,
  );
}

Future<List<Map<String, Object?>>> _sampleBlock({
  required File executable,
  required File program,
  required Directory fixture,
  required Directory studyRoot,
  required Directory evidenceRoot,
  required List<String> applyArguments,
  required int expectedTransactions,
  required int expectedRounds,
  required int expectedVerifierInvocations,
  required int expectedWaves,
  required String profile,
  required bool waveMode,
  required BenchmarkSampleContext context,
}) async {
  final samples = <_Sample>[];
  for (var index = 0; index < sampleRepetitionsPerBlock; index++) {
    samples.add(
      await _sample(
        executable,
        program,
        fixture,
        studyRoot,
        applyArguments,
        waveMode: waveMode,
        evidenceRoot: evidenceRoot,
        context: BenchmarkSampleContext(
          phase: context.phase,
          profile: context.profile,
          pair: context.pair,
          order: context.order,
          block: context.block,
          repetition: index + 1,
          variant: context.variant,
        ),
      ),
    );
  }
  validateBenchmarkRepetitionContracts(
    samples.map((sample) => sample.contract).toList(growable: false),
    expectedTransactions: expectedTransactions,
    expectedRounds: expectedRounds,
    expectedVerifierInvocations: expectedVerifierInvocations,
    expectedWaves: expectedWaves,
    profile: profile,
    waveMode: waveMode,
  );
  return samples.map((sample) => sample.evidence).toList(growable: false);
}

Future<Map<String, Object?>> _readCanonicalReport(Directory project) async {
  final reports =
      project
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (file) => RegExp(
              r'^run-report-[0-9]+\.json$',
            ).hasMatch(p.basename(file.path)),
          )
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  if (reports.isEmpty) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
  try {
    final decoded = jsonDecode(await reports.last.readAsString());
    if (decoded is! Map) {
      throw const FormatException('canonical report is not an object');
    }
    return Map<String, Object?>.from(decoded);
  } catch (_) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.reportMissing,
    );
  }
}

Future<Map<String, Object?>> _correctnessContract(
  Directory project, {
  required Map<String, Object?> timings,
}) async {
  final manifests = project
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((file) => p.basename(file.path) == 'manifest.json')
      .toList();
  if (manifests.length != 1) {
    throw StateError('Expected exactly one quarantine manifest');
  }
  final manifest =
      jsonDecode(await manifests.single.readAsString()) as Map<String, dynamic>;
  final transactions = (manifest['transactions'] as List<dynamic>)
      .cast<Map<String, dynamic>>();
  final waves =
      ((manifest['verificationWaves'] as List<dynamic>?) ?? const <dynamic>[])
          .cast<Map<String, dynamic>>();
  final rounds = transactions.map((item) => item['round'] as int).toSet();
  final caseStatuses = benchmarkManifestCaseStatuses(manifest);
  return {
    'finalHash': await _sourceTreeSha256(project),
    'transactionIds': transactions
        .map((item) => item['transactionId'])
        .toList(),
    'roundCount': rounds.length,
    'transactionRounds': transactions
        .map((item) => item['round'])
        .toList(growable: false),
    'transactionCount': transactions.length,
    'waveCount': waves.length,
    'waveIds': waves.map((wave) => wave['verificationWaveId']).toList(),
    'waveTransactionIds': waves
        .map((wave) => wave['transactionIds'])
        .toList(growable: false),
    'lifecycleState':
        (manifest['_runLifecycle'] as Map<String, dynamic>)['state'],
    'transactionStatuses': transactions
        .map((item) => item['status'])
        .toList(growable: false),
    'caseStatuses': caseStatuses,
    'verifierInvocationCount': timings['verificationAttempts'],
    'verificationPolicyHash': timings['verificationPolicyHash'],
    'verificationAttemptTransactionIds':
        timings['verificationAttemptTransactionIds'],
    'verificationWaveIds': timings['verificationWaveIds'],
  };
}

/// Reads compatibility case status evidence from the authoritative V3 journal.
List<String> benchmarkManifestCaseStatuses(Map<String, Object?> manifest) {
  final rawCases = manifest['cases'];
  if (rawCases is! List) {
    throw const BenchmarkStudyInvalidException(
      BenchmarkInvalidReason.contractMismatch,
    );
  }
  final statuses = <String>[];
  for (final rawCase in rawCases) {
    if (rawCase is! Map || rawCase['status'] is! String) {
      throw const BenchmarkStudyInvalidException(
        BenchmarkInvalidReason.contractMismatch,
      );
    }
    statuses.add(rawCase['status']! as String);
  }
  return List<String>.unmodifiable(statuses);
}

void _requireSameCorrectness(Map<String, Object?> a, Map<String, Object?> b) {
  for (final key in const [
    'finalHash',
    'transactionIds',
    'roundCount',
    'transactionCount',
  ]) {
    if (jsonEncode(a[key]) != jsonEncode(b[key])) {
      throw StateError('Correctness contract mismatch for $key');
    }
  }
}

void _requireExpectedContract(
  Map<String, Object?> contract, {
  required int expectedTransactions,
  required int expectedRounds,
  required int expectedVerifierInvocations,
  required int expectedWaves,
  required String profile,
  required bool waveMode,
}) {
  final expected = <String, int>{
    'transactionCount': expectedTransactions,
    'roundCount': expectedRounds,
    'verifierInvocationCount': expectedVerifierInvocations,
    'waveCount': expectedWaves,
  };
  for (final entry in expected.entries) {
    if (contract[entry.key] != entry.value) {
      throw StateError(
        'Correctness contract mismatch for ${entry.key}: '
        'expected ${entry.value}, observed ${contract[entry.key]}',
      );
    }
  }
  validateFrozenProfileContract(profile, contract, waveMode: waveMode);
}

Future<String> _sourceTreeSha256(Directory project) async {
  final roots = ['lib', 'test'];
  final bytes = BytesBuilder();
  for (final root in roots) {
    final directory = Directory(p.join(project.path, root));
    if (!directory.existsSync()) continue;
    final files = directory.listSync(recursive: true).whereType<File>().toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      bytes
        ..add(utf8.encode(p.relative(file.path, from: project.path)))
        ..addByte(0)
        ..add(await file.readAsBytes());
    }
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

Future<String> _directorySha256(Directory directory) async {
  final files = directory.listSync(recursive: true).whereType<File>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final bytes = BytesBuilder();
  for (final file in files) {
    bytes
      ..add(utf8.encode(p.relative(file.path, from: directory.path)))
      ..addByte(0)
      ..add(await file.readAsBytes());
  }
  return sha256.convert(bytes.takeBytes()).toString();
}

Future<String> _fileSha256(File file) async =>
    sha256.convert(await file.readAsBytes()).toString();

String _stringSha256(String value) =>
    sha256.convert(utf8.encode(value)).toString();

Map<String, Object?> _sanitizedStreamEvidence(
  String value,
  Directory sampleProject,
) {
  final bytes = utf8.encode(value);
  var sanitized = value
      .replaceAll(RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]'), '')
      .replaceAll(sampleProject.path, '<sample-project>')
      .replaceAll(sampleProject.parent.path, '<study-root>');
  sanitized = sanitized.replaceAllMapped(
    RegExp(
      r'\b(token|password|secret|authorization|api[_-]?key)\s*[:=]\s*(?:Bearer\s+)?\S+',
      caseSensitive: false,
    ),
    (match) => '${match.group(1)}=<redacted>',
  );
  sanitized = sanitized.replaceAllMapped(
    RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
    (_) => '\u{fffd}',
  );
  return Map<String, Object?>.unmodifiable({
    'byteCount': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
    'sanitizedTail': _boundedUtf8Tail(
      sanitized,
      processExitDiagnosticTailByteLimit,
    ),
  });
}

String _boundedUtf8Tail(String value, int byteLimit) {
  final runes = value.runes.toList(growable: false);
  var start = runes.length;
  var bytes = 0;
  while (start > 0) {
    final runeBytes = utf8.encode(String.fromCharCode(runes[start - 1])).length;
    if (bytes + runeBytes > byteLimit) break;
    bytes += runeBytes;
    start--;
  }
  return String.fromCharCodes(runes.skip(start));
}

Map<String, Object?> _immutableJsonMap(Map<String, Object?> value) =>
    Map<String, Object?>.unmodifiable(
      value.map((key, item) => MapEntry(key, _immutableJsonValue(item))),
    );

Object? _immutableJsonValue(Object? value) {
  if (value is Map<String, Object?>) {
    return _immutableJsonMap(value);
  }
  if (value is Map) {
    return _immutableJsonMap(Map<String, Object?>.from(value));
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_immutableJsonValue));
  }
  return value;
}

Future<void> _copyDirectory(
  Directory source,
  Directory destination, {
  bool excludeFlutterPruner = true,
}) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    if (excludeFlutterPruner &&
        relative.startsWith('.flutter_pruner${p.separator}')) {
      continue;
    }
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      await Directory(target).create(recursive: true);
    } else if (entity is File) {
      await File(target).parent.create(recursive: true);
      await entity.copy(target);
    }
  }
}

Future<void> _writeArtifact(File output, Map<String, Object?> artifact) async {
  await output.parent.create(recursive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(artifact)}\n',
    flush: true,
  );
}

final class _Sample {
  const _Sample({
    required this.elapsed,
    required this.contract,
    required this.timings,
  });

  final Duration elapsed;
  final Map<String, Object?> contract;
  final Map<String, Object?> timings;

  Map<String, Object?> get evidence => {
    'elapsedMicros': elapsed.inMicroseconds,
    'contract': contract,
    'timings': timings,
  };
}
