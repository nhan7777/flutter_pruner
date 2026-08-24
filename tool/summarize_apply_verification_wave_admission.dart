import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../benchmark/apply_verification_wave_benchmark.dart';

const _profileOrder = ['control-1x1', 'fanout-12x1', 'chain-2plus-rounds'];

const _profileContracts = <String, ({int units, int rounds})>{
  'control-1x1': (units: 1, rounds: 1),
  'fanout-12x1': (units: 12, rounds: 1),
  'chain-2plus-rounds': (units: 4, rounds: 2),
};

const _sharedIdentityKeys = [
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
];

/// Summarizes exactly one completed raw artifact for each frozen profile.
Future<Map<String, Object?>> summarizeApplyVerificationWaveAdmission(
  List<File> rawArtifacts,
) async {
  try {
    if (rawArtifacts.length != _profileOrder.length) {
      return _invalidSummary();
    }
    final byProfile = <String, ({Map<String, Object?> artifact, String sha})>{};
    for (final file in rawArtifacts) {
      final bytes = await file.readAsBytes();
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) return _invalidSummary();
      final artifact = Map<String, Object?>.from(decoded);
      final profile = artifact['profile'];
      if (profile is! String ||
          !_profileContracts.containsKey(profile) ||
          byProfile.containsKey(profile)) {
        return _invalidSummary();
      }
      byProfile[profile] = (
        artifact: artifact,
        sha: sha256.convert(bytes).toString(),
      );
    }
    if (byProfile.keys.toSet().length != _profileOrder.length) {
      return _invalidSummary();
    }

    Map<String, Object?>? firstArtifact;
    final profiles = <Map<String, Object?>>[];
    for (final profile in _profileOrder) {
      final raw = byProfile[profile];
      if (raw == null || !_validateRawArtifact(raw.artifact, profile)) {
        return _invalidSummary();
      }
      firstArtifact ??= raw.artifact;
      for (final key in _sharedIdentityKeys) {
        if (raw.artifact[key] != firstArtifact[key]) {
          return _invalidSummary();
        }
      }
      final aaMetrics = recomputeAaMetrics(_rawPairs(raw.artifact['aaPairs']));
      final abMetrics = recomputeAbMetrics(_rawPairs(raw.artifact['abPairs']));
      final medianImprovement = abMetrics['medianImprovement']! as double;
      final noiseThreshold = aaMetrics['noiseThreshold']! as double;
      final fasterPairs = abMetrics['fasterPairs']! as int;
      final aaPolicy = verificationPolicyFromPairs(
        _rawPairs(raw.artifact['aaPairs']),
        const ['firstRepetitions', 'secondRepetitions'],
      );
      final abPolicy = verificationPolicyFromPairs(
        _rawPairs(raw.artifact['abPairs']),
        const ['aRepetitions', 'bRepetitions'],
      );
      if (!_storedMetricMatches(
            raw.artifact['noiseThreshold'],
            noiseThreshold,
          ) ||
          !_storedMetricMatches(
            raw.artifact['medianImprovement'],
            medianImprovement,
          ) ||
          raw.artifact['fasterPairs'] != fasterPairs ||
          jsonEncode(raw.artifact['aaPairedRelativeDeltas']) !=
              jsonEncode(aaMetrics['aaPairedRelativeDeltas']) ||
          jsonEncode(raw.artifact['abPairedRelativeDeltas']) !=
              jsonEncode(abMetrics['abPairedRelativeDeltas']) ||
          raw.artifact['verificationPolicyHash'] != aaPolicy ||
          aaPolicy != abPolicy) {
        return _invalidSummary();
      }
      final admitted = isProfileAdmitted(
        profile: profile,
        medianImprovement: medianImprovement,
        noiseThreshold: noiseThreshold,
        fasterPairs: fasterPairs,
      );
      if (raw.artifact['admitted'] != admitted) return _invalidSummary();
      profiles.add({
        'profile': profile,
        'admitted': admitted,
        'medianImprovement': medianImprovement,
        'noiseThreshold': noiseThreshold,
        'fasterPairs': fasterPairs,
        'rawArtifactSha256': raw.sha,
      });
    }
    final admitted = profiles.every((profile) => profile['admitted'] == true);
    return {
      'schemaVersion': applyVerificationWaveBenchmarkSchemaVersion,
      'protocolId': applyVerificationWaveProtocolId,
      'status': admitted ? 'admitted' : 'not-admitted',
      'defaultOnOptimizationAdmitted': admitted,
      'profiles': profiles,
      for (final key in _sharedIdentityKeys) key: firstArtifact![key],
      'performanceClaim': admitted
          ? {
              'scope': 'synthetic-fixture-admission',
              'metric': 'median-paired-relative-delta',
            }
          : null,
    };
  } catch (_) {
    return _invalidSummary();
  }
}

bool _validateRawArtifact(Map<String, Object?> artifact, String profile) {
  if (artifact['schemaVersion'] !=
          applyVerificationWaveBenchmarkSchemaVersion ||
      artifact['protocolId'] != applyVerificationWaveProtocolId ||
      artifact['status'] != 'complete' ||
      artifact['sampleRepetitionsPerBlock'] != sampleRepetitionsPerBlock ||
      !_sameSchedule(artifact['schedule']) ||
      artifact['profile'] != profile ||
      artifact['noiseThreshold'] is! num ||
      (artifact['noiseThreshold']! as num) < 0 ||
      artifact['medianImprovement'] is! num ||
      artifact['fasterPairs'] is! int ||
      artifact['admitted'] is! bool ||
      !_hasSha256(artifact['fixtureSha256'])) {
    return false;
  }
  for (final key in _sharedIdentityKeys) {
    if (!_hasSha256(artifact[key])) return false;
  }
  final contract = _profileContracts[profile]!;
  return _validatePairs(
        artifact['aaPairs'],
        profile: profile,
        waveMode: false,
        firstKey: 'firstRepetitions',
        secondKey: 'secondRepetitions',
        expectedTransactions: contract.units,
        expectedRounds: contract.rounds,
        firstVerifierAttempts: 1 + contract.units,
        firstWaves: 0,
        secondVerifierAttempts: 1 + contract.units,
        secondWaves: 0,
      ) &&
      _validatePairs(
        artifact['abPairs'],
        profile: profile,
        waveMode: true,
        firstKey: 'aRepetitions',
        secondKey: 'bRepetitions',
        expectedTransactions: contract.units,
        expectedRounds: contract.rounds,
        firstVerifierAttempts: 1 + contract.units,
        firstWaves: 0,
        secondVerifierAttempts: 1 + contract.rounds,
        secondWaves: contract.rounds,
      );
}

bool _validatePairs(
  Object? value, {
  required String profile,
  required bool waveMode,
  required String firstKey,
  required String secondKey,
  required int expectedTransactions,
  required int expectedRounds,
  required int firstVerifierAttempts,
  required int firstWaves,
  required int secondVerifierAttempts,
  required int secondWaves,
}) {
  if (value is! List || value.length != counterbalancedPairSchedule.length) {
    return false;
  }
  try {
    for (var index = 0; index < value.length; index++) {
      final pair = Map<String, Object?>.from(value[index] as Map);
      if (pair['order'] != counterbalancedPairSchedule[index]) return false;
      final first = _rawContracts(pair[firstKey]);
      final second = _rawContracts(pair[secondKey]);
      validateBenchmarkRepetitionContracts(
        first,
        expectedTransactions: expectedTransactions,
        expectedRounds: expectedRounds,
        expectedVerifierInvocations: firstVerifierAttempts,
        expectedWaves: firstWaves,
        profile: profile,
        waveMode: waveMode && firstWaves > 0,
      );
      validateBenchmarkRepetitionContracts(
        second,
        expectedTransactions: expectedTransactions,
        expectedRounds: expectedRounds,
        expectedVerifierInvocations: secondVerifierAttempts,
        expectedWaves: secondWaves,
        profile: profile,
        waveMode: waveMode && secondWaves > 0,
      );
      for (
        var repetition = 0;
        repetition < sampleRepetitionsPerBlock;
        repetition++
      ) {
        if (jsonEncode(first[repetition]['finalHash']) !=
                jsonEncode(second[repetition]['finalHash']) ||
            jsonEncode(first[repetition]['transactionIds']) !=
                jsonEncode(second[repetition]['transactionIds'])) {
          return false;
        }
      }
      _validateRawTimings(pair[firstKey], firstVerifierAttempts);
      _validateRawTimings(pair[secondKey], secondVerifierAttempts);
    }
    return true;
  } catch (_) {
    return false;
  }
}

List<Map<String, Object?>> _rawContracts(Object? repetitions) {
  if (repetitions is! List || repetitions.length != sampleRepetitionsPerBlock) {
    throw const FormatException('invalid repetition count');
  }
  return repetitions
      .map((repetition) {
        final evidence = Map<String, Object?>.from(repetition as Map);
        final elapsed = evidence['elapsedMicros'];
        if (elapsed is! int || elapsed <= 0) {
          throw const FormatException('invalid outer elapsed time');
        }
        return Map<String, Object?>.from(evidence['contract']! as Map);
      })
      .toList(growable: false);
}

void _validateRawTimings(Object? repetitions, int expectedAttempts) {
  for (final repetition in repetitions! as List) {
    final evidence = Map<String, Object?>.from(repetition as Map);
    final timings = Map<String, Object?>.from(evidence['timings']! as Map);
    for (final key in const [
      'runElapsedMicros',
      'verificationElapsedMicros',
      'candidateVerificationElapsedMicros',
      'analysisElapsedMicros',
      'unaccountedElapsedMicros',
    ]) {
      final value = timings[key];
      if (value is! int || value < 0) {
        throw const FormatException('invalid timing evidence');
      }
    }
    if (timings['verificationAttempts'] != expectedAttempts) {
      throw const FormatException('invalid verifier attempt evidence');
    }
  }
}

bool _sameSchedule(Object? value) {
  if (value is! List || value.length != counterbalancedPairSchedule.length) {
    return false;
  }
  for (var index = 0; index < value.length; index++) {
    if (value[index] != counterbalancedPairSchedule[index]) return false;
  }
  return true;
}

bool _hasSha256(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

List<Map<String, Object?>> _rawPairs(Object? value) {
  if (value is! List) throw const FormatException('invalid pair list');
  return value
      .map((pair) => Map<String, Object?>.from(pair as Map))
      .toList(growable: false);
}

bool _storedMetricMatches(Object? stored, num recomputed) =>
    stored is num && (stored.toDouble() - recomputed.toDouble()).abs() <= 1e-12;

Map<String, Object?> _invalidSummary() => {
  'schemaVersion': applyVerificationWaveBenchmarkSchemaVersion,
  'protocolId': applyVerificationWaveProtocolId,
  'status': 'invalid',
  'defaultOnOptimizationAdmitted': false,
  'performanceClaim': null,
  'profiles': const <Object?>[],
  'invalidReasonCode': 'artifact_state',
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addMultiOption('artifact')
    ..addOption('output', mandatory: true);
  final options = parser.parse(arguments);
  final artifacts = options
      .multiOption('artifact')
      .map((path) => File(p.absolute(path)))
      .toList(growable: false);
  final output = File(p.absolute(options.option('output')!));
  if (output.existsSync()) {
    throw StateError('Aggregate output already exists: ${output.path}');
  }
  final summary = await summarizeApplyVerificationWaveAdmission(artifacts);
  await output.parent.create(recursive: true);
  await output.create(exclusive: true);
  await output.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(summary)}\n',
    flush: true,
  );
  if (summary['status'] == 'invalid') exitCode = 1;
}
