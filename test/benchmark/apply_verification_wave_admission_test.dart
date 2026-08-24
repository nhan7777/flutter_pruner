import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../benchmark/apply_verification_wave_benchmark.dart';
import '../../tool/summarize_apply_verification_wave_admission.dart';

const _policyHash =
    '7777777777777777777777777777777777777777777777777777777777777777';

void main() {
  test('admits exactly three valid profiles in fixed order', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_summary_');
    try {
      final files = <File>[
        _writeRaw(directory, _completedArtifact('chain-2plus-rounds')),
        _writeRaw(directory, _completedArtifact('control-1x1')),
        _writeRaw(directory, _completedArtifact('fanout-12x1')),
      ];

      final summary = await summarizeApplyVerificationWaveAdmission(files);

      expect(summary['schemaVersion'], 2);
      expect(summary['protocolId'], 'apply-verification-wave-v2-block3-pairs6');
      expect(summary['status'], 'admitted');
      expect(summary['defaultOnOptimizationAdmitted'], isTrue);
      expect(
        (summary['profiles'] as List).cast<Map<String, Object?>>().map(
          (profile) => profile['profile'],
        ),
        ['control-1x1', 'fanout-12x1', 'chain-2plus-rounds'],
      );
      expect(
        (summary['profiles'] as List).cast<Map<String, Object?>>().map(
          (profile) => profile['admitted'],
        ),
        everyElement(isTrue),
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('valid performance miss is not admitted without a claim', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_no_admit_');
    try {
      final fanout = _completedArtifact('fanout-12x1', performanceMiss: true);
      final summary = await summarizeApplyVerificationWaveAdmission([
        _writeRaw(directory, _completedArtifact('control-1x1')),
        _writeRaw(directory, fanout),
        _writeRaw(directory, _completedArtifact('chain-2plus-rounds')),
      ]);

      expect(summary['status'], 'not-admitted');
      expect(summary['defaultOnOptimizationAdmitted'], isFalse);
      expect(summary['performanceClaim'], isNull);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('duplicate profile and identity disagreement are invalid', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_bad_input_');
    try {
      final duplicate = await summarizeApplyVerificationWaveAdmission([
        _writeRaw(directory, _completedArtifact('control-1x1'), suffix: 'a'),
        _writeRaw(directory, _completedArtifact('control-1x1'), suffix: 'b'),
        _writeRaw(directory, _completedArtifact('chain-2plus-rounds')),
      ]);
      expect(duplicate['status'], 'invalid');

      final drifted = _completedArtifact('fanout-12x1')
        ..['harnessSha256'] = '9' * 64;
      final identityDrift = await summarizeApplyVerificationWaveAdmission([
        _writeRaw(directory, _completedArtifact('control-1x1'), suffix: 'c'),
        _writeRaw(directory, drifted, suffix: 'd'),
        _writeRaw(
          directory,
          _completedArtifact('chain-2plus-rounds'),
          suffix: 'e',
        ),
      ]);
      expect(identityDrift['status'], 'invalid');
      expect(identityDrift['defaultOnOptimizationAdmitted'], isFalse);

      final programDrifted = _completedArtifact('fanout-12x1')
        ..['aProgramSha256'] = '8' * 64;
      final programIdentityDrift =
          await summarizeApplyVerificationWaveAdmission([
            _writeRaw(
              directory,
              _completedArtifact('control-1x1'),
              suffix: 'f',
            ),
            _writeRaw(directory, programDrifted, suffix: 'g'),
            _writeRaw(
              directory,
              _completedArtifact('chain-2plus-rounds'),
              suffix: 'h',
            ),
          ]);
      expect(programIdentityDrift['status'], 'invalid');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('forged stored performance metrics are invalid', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_forged_');
    try {
      final forged = _completedArtifact('fanout-12x1')
        ..['medianImprovement'] = 0.99
        ..['noiseThreshold'] = 0.0
        ..['fasterPairs'] = 6
        ..['admitted'] = true;
      final summary = await summarizeApplyVerificationWaveAdmission([
        _writeRaw(directory, _completedArtifact('control-1x1')),
        _writeRaw(directory, forged),
        _writeRaw(directory, _completedArtifact('chain-2plus-rounds')),
      ]);
      expect(summary['status'], 'invalid');
      expect(summary['performanceClaim'], isNull);
    } finally {
      directory.deleteSync(recursive: true);
    }
  });
}

File _writeRaw(
  Directory directory,
  Map<String, Object?> artifact, {
  String suffix = '',
}) {
  final profile = artifact['profile'];
  final file = File('${directory.path}/$profile$suffix.json');
  file.writeAsStringSync('${jsonEncode(artifact)}\n');
  return file;
}

Map<String, Object?> _completedArtifact(
  String profile, {
  bool performanceMiss = false,
}) {
  final metrics = switch (profile) {
    'control-1x1' => (bElapsed: 100, units: 1, rounds: 1),
    'fanout-12x1' => (
      bElapsed: performanceMiss ? 100 : 70,
      units: 12,
      rounds: 1,
    ),
    'chain-2plus-rounds' => (bElapsed: 80, units: 4, rounds: 2),
    _ => throw ArgumentError.value(profile),
  };
  final aRepetitions = _rawRepetitions(
    profile: profile,
    units: metrics.units,
    rounds: metrics.rounds,
    verificationAttempts: 1 + metrics.units,
    waveCount: 0,
    elapsedMicros: 100,
  );
  final bRepetitions = _rawRepetitions(
    profile: profile,
    units: metrics.units,
    rounds: metrics.rounds,
    verificationAttempts: 1 + metrics.rounds,
    waveCount: metrics.rounds,
    elapsedMicros: metrics.bElapsed,
  );
  final aaPairs = [
    for (final order in const ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'])
      aaBlockPairRecord(
        order: order,
        firstRepetitions: aRepetitions,
        secondRepetitions: aRepetitions,
      ),
  ];
  final abPairs = [
    for (final order in const ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'])
      abBlockPairRecord(
        order: order,
        aRepetitions: aRepetitions,
        bRepetitions: bRepetitions,
      ),
  ];
  final aaMetrics = recomputeAaMetrics(aaPairs);
  final abMetrics = recomputeAbMetrics(abPairs);
  final admitted = isProfileAdmitted(
    profile: profile,
    medianImprovement: abMetrics['medianImprovement']! as double,
    noiseThreshold: aaMetrics['noiseThreshold']! as double,
    fasterPairs: abMetrics['fasterPairs']! as int,
  );
  return {
    'schemaVersion': 2,
    'protocolId': 'apply-verification-wave-v2-block3-pairs6',
    'profile': profile,
    'status': 'complete',
    'sampleRepetitionsPerBlock': 3,
    'schedule': ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'],
    ...aaMetrics,
    ...abMetrics,
    'admitted': admitted,
    'aaPairs': aaPairs,
    'abPairs': abPairs,
    'fixtureSha256': switch (profile) {
      'control-1x1' => 'a' * 64,
      'fanout-12x1' => 'b' * 64,
      _ => 'c' * 64,
    },
    'aExecutableSha256': 'd' * 64,
    'bExecutableSha256': 'e' * 64,
    'aProgramSha256': '7' * 64,
    'bProgramSha256': '8' * 64,
    'harnessSha256': 'f' * 64,
    'generatorSha256': '3' * 64,
    'boundaryPatchSha256': '1' * 64,
    'verificationWavePatchSha256': '2' * 64,
    'dartToolchainSha256': '4' * 64,
    'flutterToolchainSha256': '5' * 64,
    'applyArgumentsSha256': '6' * 64,
    'verificationPolicyHash': _policyHash,
  };
}

List<Map<String, Object?>> _rawRepetitions({
  required String profile,
  required int units,
  required int rounds,
  required int verificationAttempts,
  required int waveCount,
  required int elapsedMicros,
}) => [
  for (var index = 0; index < 3; index++)
    {
      'elapsedMicros': elapsedMicros,
      'contract': {
        ...frozenProfileExpectation(
          profile,
          waveMode: waveCount > 0,
        ).toContract(),
        'verifierInvocationCount': verificationAttempts,
        'verificationPolicyHash': _policyHash,
      },
      'timings': {
        'runElapsedMicros': 90,
        'verificationElapsedMicros': 60,
        'candidateVerificationElapsedMicros': 30,
        'analysisElapsedMicros': 20,
        'unaccountedElapsedMicros': 10,
        'verificationAttempts': verificationAttempts,
        'verificationPolicyHash': _policyHash,
      },
    },
];
