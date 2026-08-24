import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../../benchmark/apply_verification_wave_benchmark.dart';

const _policyHash =
    '7777777777777777777777777777777777777777777777777777777777777777';

void main() {
  test('freezes the v2 block sampling protocol', () {
    expect(applyVerificationWaveBenchmarkSchemaVersion, 2);
    expect(
      applyVerificationWaveProtocolId,
      'apply-verification-wave-v2-block3-pairs6',
    );
    expect(sampleRepetitionsPerBlock, 3);
    expect(blockElapsedMicros([100, 110, 90]), 300);
  });

  test('freezes maximum absolute A/A noise and paired median', () {
    final deltas = [0.01, -0.03, 0.02, -0.01, 0.04, 0.0];
    expect(frozenNoiseThreshold(deltas), 0.04);
    expect(median(deltas), closeTo(0.005, 0.000001));
    expect(counterbalancedPairSchedule, ['AB', 'BA', 'AB', 'BA', 'AB', 'BA']);
  });

  test('paired relative delta is positive when B is faster', () {
    expect(
      pairedRelativeDelta(
        const Duration(microseconds: 100),
        const Duration(microseconds: 75),
      ),
      0.25,
    );
  });

  test('A/A block orientation follows the scheduled order', () {
    final record = aaBlockPairRecord(
      order: 'BA',
      firstRepetitions: const [
        {
          'elapsedMicros': 75,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 85,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 80,
          'contract': {'finalHash': 'same'},
        },
      ],
      secondRepetitions: const [
        {
          'elapsedMicros': 100,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 110,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 90,
          'contract': {'finalHash': 'same'},
        },
      ],
    );

    expect(record['firstBlockElapsedMicros'], 240);
    expect(record['secondBlockElapsedMicros'], 300);
    expect(record['pairedRelativeDelta'], 0.2);
    expect((record['firstRepetitions'] as List), hasLength(3));
    expect((record['secondRepetitions'] as List), hasLength(3));
  });

  test('A/B block retains repetitions and compares A with B', () {
    final record = abBlockPairRecord(
      order: 'BA',
      aRepetitions: const [
        {
          'elapsedMicros': 100,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 110,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 90,
          'contract': {'finalHash': 'same'},
        },
      ],
      bRepetitions: const [
        {
          'elapsedMicros': 75,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 85,
          'contract': {'finalHash': 'same'},
        },
        {
          'elapsedMicros': 80,
          'contract': {'finalHash': 'same'},
        },
      ],
    );

    expect(record['aBlockElapsedMicros'], 300);
    expect(record['bBlockElapsedMicros'], 240);
    expect(record['pairedRelativeDelta'], 0.2);
    expect((record['aRepetitions'] as List), hasLength(3));
    expect((record['bRepetitions'] as List), hasLength(3));
  });

  test(
    'block builders reject malformed blocks and admission is profile exact',
    () {
      expect(
        () => abBlockPairRecord(
          order: 'invalid',
          aRepetitions: const [],
          bRepetitions: const [],
        ),
        throwsArgumentError,
      );
      expect(
        isProfileAdmitted(
          profile: 'control-1x1',
          medianImprovement: -0.04,
          noiseThreshold: 0.04,
          fasterPairs: 0,
        ),
        isTrue,
      );
      expect(
        isProfileAdmitted(
          profile: 'fanout-12x1',
          medianImprovement: 0.05,
          noiseThreshold: 0.04,
          fasterPairs: 5,
        ),
        isTrue,
      );
      expect(
        isProfileAdmitted(
          profile: 'chain-2plus-rounds',
          medianImprovement: 0.04,
          noiseThreshold: 0.04,
          fasterPairs: 6,
        ),
        isFalse,
      );
    },
  );

  group('frozen A/A artifact validation', () {
    test('accepts the exact v2 protocol and input identities', () {
      expect(
        () => validateFrozenAaArtifact(
          _frozenAaArtifact(),
          expectedIdentity: _benchmarkIdentity(),
        ),
        returnsNormally,
      );
    });

    for (final mutation in <String, Object?>{
      'schemaVersion': 1,
      'protocolId': 'other-protocol',
      'status': 'complete',
      'sampleRepetitionsPerBlock': 1,
      'schedule': const ['AB'],
      'fixtureSha256': '1' * 64,
      'aExecutableSha256': '2' * 64,
      'bExecutableSha256': '3' * 64,
      'aProgramSha256': '7' * 64,
      'bProgramSha256': '8' * 64,
      'harnessSha256': '4' * 64,
      'boundaryPatchSha256': '5' * 64,
      'verificationWavePatchSha256': '6' * 64,
    }.entries) {
      test('rejects a mismatched ${mutation.key}', () {
        final artifact = _frozenAaArtifact()..[mutation.key] = mutation.value;
        expect(
          () => validateFrozenAaArtifact(
            artifact,
            expectedIdentity: _benchmarkIdentity(),
          ),
          throwsStateError,
        );
      });
    }
  });

  test('phase state moves only from absent to frozen to complete', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_phase_');
    final output = File('${directory.path}/artifact.json');
    try {
      await runAaPhase(
        output: output,
        profile: 'control-1x1',
        identity: _benchmarkIdentity(),
        warmup: () async {},
        measurePairs: (addPair) async {
          for (final order in counterbalancedPairSchedule) {
            addPair(_aaBlock(order));
          }
        },
      );
      expect(_readArtifact(output)['status'], 'aa-frozen');
      expect(
        () => runAaPhase(
          output: output,
          profile: 'control-1x1',
          identity: _benchmarkIdentity(),
          warmup: () async {},
          measurePairs: (_) async {},
        ),
        throwsStateError,
      );

      final cohort = _writeCohort(directory, output);
      await runAbPhase(
        output: output,
        cohortAaArtifacts: cohort,
        expectedIdentity: _benchmarkIdentity(),
        warmup: () async {},
        measurePairs: (addPair) async {
          for (final order in counterbalancedPairSchedule) {
            addPair(_abBlock(order));
          }
        },
      );
      final completed = _readArtifact(output);
      expect(completed['status'], 'complete');
      expect(completed['admitted'], isTrue);
      expect(completed['abPairs'], hasLength(6));
      expect(_readArtifact(cohort.first)['status'], 'aa-frozen');
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('A/B failure invalidates the complete fixture without retry', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_invalid_');
    final output = File('${directory.path}/artifact.json');
    try {
      await runAaPhase(
        output: output,
        profile: 'control-1x1',
        identity: _benchmarkIdentity(),
        warmup: () async {},
        measurePairs: (addPair) async {
          for (final order in counterbalancedPairSchedule) {
            addPair(_aaBlock(order));
          }
        },
      );

      await expectLater(
        runAbPhase(
          output: output,
          cohortAaArtifacts: _writeCohort(directory, output),
          expectedIdentity: _benchmarkIdentity(),
          warmup: () async {},
          measurePairs: (addPair) async {
            addPair(_abBlock('AB'));
            throw const BenchmarkStudyInvalidException(
              BenchmarkInvalidReason.contractMismatch,
            );
          },
        ),
        throwsA(isA<BenchmarkStudyInvalidException>()),
      );
      final invalid = _readArtifact(output);
      expect(invalid['status'], 'invalid');
      expect(invalid['admitted'], isFalse);
      expect(invalid['invalidReasonCode'], 'contract_mismatch');
      expect(invalid['abPairs'], hasLength(1));
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('A/A warmup failure persists an invalid lifecycle artifact', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_aa_fail_');
    final output = File('${directory.path}/artifact.json');
    try {
      await expectLater(
        runAaPhase(
          output: output,
          profile: 'control-1x1',
          identity: _benchmarkIdentity(),
          warmup: () => throw const BenchmarkStudyInvalidException(
            BenchmarkInvalidReason.processExit,
          ),
          measurePairs: (_) async {},
        ),
        throwsA(isA<BenchmarkStudyInvalidException>()),
      );
      expect(_readArtifact(output), containsPair('status', 'invalid'));
      expect(
        _readArtifact(output),
        containsPair('invalidReasonCode', 'process_exit'),
      );
      expect(_readArtifact(output)['aaPairs'], isEmpty);
      await expectLater(
        runAaPhase(
          output: output,
          profile: 'control-1x1',
          identity: _benchmarkIdentity(),
          warmup: () async {},
          measurePairs: (_) async {},
        ),
        throwsStateError,
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test(
    'process-exit diagnostic is immutable sanitized and byte bounded',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'wave_v2_diagnostic_',
      );
      final studyRoot = Directory('${directory.path}/study')..createSync();
      final sampleProject = Directory('${studyRoot.path}/sample')..createSync();
      final evidenceRoot = Directory(
        '${directory.path}/artifact.json.failure-evidence',
      );
      File('${sampleProject.path}/sentinel').writeAsStringSync('failed state');
      final stdout =
          '${'x' * 700} ${sampleProject.path} '
          '\u001b[31mTOKEN=raw-secret\u001b[0m';
      final stderr =
          '${'y' * 700} ${studyRoot.path} '
          'PASSWORD=raw-password Authorization: Bearer raw-authorization';
      try {
        final diagnostic = await retainProcessExitEvidence(
          sampleProject: sampleProject,
          evidenceRoot: evidenceRoot,
          context: const BenchmarkSampleContext(
            phase: 'aa',
            profile: 'chain-2plus-rounds',
            pair: 5,
            order: 'AB',
            block: 'second',
            repetition: 2,
            variant: 'A',
          ),
          exitCode: 29,
          stdout: stdout,
          stderr: stderr,
        );

        expect(diagnostic, {
          'phase': 'aa',
          'profile': 'chain-2plus-rounds',
          'pair': 5,
          'order': 'AB',
          'block': 'second',
          'repetition': 2,
          'variant': 'A',
          'exitCode': 29,
          'stdout': {
            'byteCount': utf8.encode(stdout).length,
            'sha256': matches(RegExp(r'^[0-9a-f]{64}$')),
            'sanitizedTail': isA<String>(),
          },
          'stderr': {
            'byteCount': utf8.encode(stderr).length,
            'sha256': matches(RegExp(r'^[0-9a-f]{64}$')),
            'sanitizedTail': isA<String>(),
          },
          'evidenceRef': 'artifact.json.failure-evidence/sample-project',
        });
        final encoded = jsonEncode(diagnostic);
        expect(encoded, isNot(contains('raw-secret')));
        expect(encoded, isNot(contains('raw-password')));
        expect(encoded, isNot(contains('raw-authorization')));
        expect(encoded, isNot(contains(sampleProject.path)));
        expect(encoded, isNot(contains(studyRoot.path)));
        expect(encoded, isNot(contains('\u001b[')));
        expect(encoded, isNot(contains('argv')));
        expect(encoded, isNot(contains('environment')));
        expect(encoded, contains('<sample-project>'));
        expect(encoded, contains('<study-root>'));
        expect(encoded, contains('TOKEN=<redacted>'));
        expect(encoded, contains('PASSWORD=<redacted>'));
        expect(encoded, contains('Authorization=<redacted>'));
        for (final stream in const ['stdout', 'stderr']) {
          final evidence = diagnostic[stream]! as Map<String, Object?>;
          expect(
            utf8.encode(evidence['sanitizedTail']! as String).length,
            lessThanOrEqualTo(processExitDiagnosticTailByteLimit),
          );
          expect(() => evidence['sha256'] = 'mutated', throwsUnsupportedError);
        }
        expect(() => diagnostic['exitCode'] = 0, throwsUnsupportedError);
        expect(
          File('${evidenceRoot.path}/diagnostic.json').readAsStringSync(),
          jsonEncode(diagnostic),
        );
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'process-exit evidence survives cleanup and invalid lifecycle',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'wave_v2_failure_lifecycle_',
      );
      final output = File('${directory.path}/artifact.json');
      final studyRoot = Directory('${directory.path}/study')..createSync();
      final sampleProject = Directory('${studyRoot.path}/sample')..createSync();
      const failedContent = 'failed state';
      File('${sampleProject.path}/sentinel').writeAsStringSync(failedContent);
      final quarantineEvidence = File(
        '${sampleProject.path}/.flutter_pruner/quarantine/manifest.json',
      )..createSync(recursive: true);
      quarantineEvidence.writeAsStringSync('{"state":"failed"}');
      final evidenceRoot = Directory('${output.path}.failure-evidence');
      try {
        await expectLater(
          runAaPhase(
            output: output,
            profile: 'chain-2plus-rounds',
            identity: _benchmarkIdentity(),
            warmup: () async {},
            measurePairs: (addPair) async {
              for (final order in counterbalancedPairSchedule.take(4)) {
                addPair(_aaBlock(order));
              }
              final diagnostic = await retainProcessExitEvidence(
                sampleProject: sampleProject,
                evidenceRoot: evidenceRoot,
                context: const BenchmarkSampleContext(
                  phase: 'aa',
                  profile: 'chain-2plus-rounds',
                  pair: 5,
                  order: 'AB',
                  block: 'second',
                  repetition: 1,
                  variant: 'A',
                ),
                exitCode: 29,
                stdout: 'bounded stdout',
                stderr: 'bounded stderr',
              );
              throw BenchmarkStudyInvalidException.withDiagnostic(
                BenchmarkInvalidReason.processExit,
                diagnostic,
              );
            },
          ),
          throwsA(isA<BenchmarkStudyInvalidException>()),
        );
        cleanupBenchmarkStudyRoot(studyRoot);

        expect(studyRoot.existsSync(), isFalse);
        expect(
          File(
            '${evidenceRoot.path}/sample-project/sentinel',
          ).readAsStringSync(),
          failedContent,
        );
        expect(
          File(
            '${evidenceRoot.path}/sample-project/.flutter_pruner/'
            'quarantine/manifest.json',
          ).readAsStringSync(),
          '{"state":"failed"}',
        );
        final invalid = _readArtifact(output);
        expect(invalid['status'], 'invalid');
        expect(invalid['invalidReasonCode'], 'process_exit');
        expect(invalid['aaPairs'], hasLength(4));
        expect(
          invalid['failureDiagnostic'],
          jsonDecode(
            File('${evidenceRoot.path}/diagnostic.json').readAsStringSync(),
          ),
        );
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('successful-study cleanup removes its temporary root', () {
    final studyRoot = Directory.systemTemp.createTempSync(
      'wave_v2_success_cleanup_',
    );
    File('${studyRoot.path}/sample').writeAsStringSync('complete');

    cleanupBenchmarkStudyRoot(studyRoot);

    expect(studyRoot.existsSync(), isFalse);
  });

  test('A/B cohort barrier rejects incomplete cohort before warmup', () async {
    for (final cohortSize in [1, 2]) {
      final directory = Directory.systemTemp.createTempSync('wave_v2_cohort_');
      final output = File('${directory.path}/control.json')
        ..writeAsStringSync(jsonEncode(_frozenAaArtifact()));
      final cohort = _writeCohort(directory, output).take(cohortSize).toList();
      var warmed = false;
      try {
        await expectLater(
          runAbPhase(
            output: output,
            cohortAaArtifacts: cohort,
            expectedIdentity: _benchmarkIdentity(),
            warmup: () async => warmed = true,
            measurePairs: (_) async {},
          ),
          throwsA(isA<BenchmarkStudyInvalidException>()),
        );
        expect(warmed, isFalse);
        expect(_readArtifact(output)['status'], 'invalid');
      } finally {
        directory.deleteSync(recursive: true);
      }
    }
  });

  test(
    'A/B requires a detached immutable snapshot of the current A/A artifact',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'wave_v2_detached_cohort_',
      );
      final output = File('${directory.path}/control.json')
        ..writeAsStringSync(jsonEncode(_frozenAaArtifact()));
      final cohort = _writeCohort(directory, output);
      cohort[0] = output;
      var warmed = false;
      try {
        await expectLater(
          runAbPhase(
            output: output,
            cohortAaArtifacts: cohort,
            expectedIdentity: _benchmarkIdentity(),
            warmup: () async => warmed = true,
            measurePairs: (_) async {},
          ),
          throwsStateError,
        );
        expect(warmed, isFalse);
        expect(_readArtifact(output)['status'], 'aa-frozen');
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test(
    'A/B cohort barrier rejects malformed and identity-drifted cohorts',
    () async {
      for (final mutation in ['malformed', 'identity']) {
        final directory = Directory.systemTemp.createTempSync(
          'wave_v2_cohort_bad_',
        );
        final output = File('${directory.path}/control.json')
          ..writeAsStringSync(jsonEncode(_frozenAaArtifact()));
        final cohort = _writeCohort(directory, output);
        if (mutation == 'malformed') {
          cohort[1].writeAsStringSync('{broken');
        } else {
          final drifted = _readArtifact(cohort[1])
            ..['harnessSha256'] = '9' * 64;
          cohort[1].writeAsStringSync(jsonEncode(drifted));
        }
        var warmed = false;
        try {
          await expectLater(
            runAbPhase(
              output: output,
              cohortAaArtifacts: cohort,
              expectedIdentity: _benchmarkIdentity(),
              warmup: () async => warmed = true,
              measurePairs: (_) async {},
            ),
            throwsA(anything),
          );
          expect(warmed, isFalse);
          expect(_readArtifact(output)['status'], 'invalid');
        } finally {
          directory.deleteSync(recursive: true);
        }
      }
    },
  );

  test('A/B rejects terminal and malformed artifact states', () async {
    final directory = Directory.systemTemp.createTempSync('wave_v2_state_');
    final output = File('${directory.path}/artifact.json');
    try {
      for (final state in const ['complete', 'invalid']) {
        output.writeAsStringSync(
          jsonEncode(_frozenAaArtifact()..['status'] = state),
        );
        await expectLater(
          runAbPhase(
            output: output,
            cohortAaArtifacts: const [],
            expectedIdentity: _benchmarkIdentity(),
            warmup: () async {},
            measurePairs: (_) async {},
          ),
          throwsStateError,
        );
      }
      output.writeAsStringSync('{malformed');
      await expectLater(
        runAbPhase(
          output: output,
          cohortAaArtifacts: const [],
          expectedIdentity: _benchmarkIdentity(),
          warmup: () async {},
          measurePairs: (_) async {},
        ),
        throwsFormatException,
      );
    } finally {
      directory.deleteSync(recursive: true);
    }
  });

  test('CLI rejects an unknown benchmark phase', () {
    expect(
      () => createApplyVerificationBenchmarkParser().parse([
        '--phase',
        'unknown',
      ]),
      throwsFormatException,
    );
  });

  for (final missing in const ['--a-program', '--b-program']) {
    test('CLI requires $missing', () {
      final arguments = [
        '--phase',
        'aa',
        '--fixture',
        'fixture',
        '--a-executable',
        'runtime-a',
        '--b-executable',
        'runtime-b',
        '--a-program',
        'program-a',
        '--b-program',
        'program-b',
        '--output',
        'output',
        '--generator',
        'generator',
        '--boundary-patch',
        'boundary',
        '--verification-wave-patch',
        'wave',
      ];
      final optionIndex = arguments.indexOf(missing);
      arguments.removeRange(optionIndex, optionIndex + 2);

      expect(
        () => parseApplyVerificationBenchmarkArguments(arguments),
        throwsFormatException,
      );
    });
  }

  test('runtime invocation places the AOT program before apply arguments', () {
    final invocation = benchmarkProcessInvocation(
      runtime: File('/sdk/dartaotruntime'),
      program: File('/study/program.aot'),
      applyArguments: const ['--adapter', 'dart', '--yes'],
      project: Directory('/study/project'),
    );

    expect(invocation.executable, '/sdk/dartaotruntime');
    expect(invocation.arguments, [
      '/study/program.aot',
      'apply',
      '--adapter',
      'dart',
      '--yes',
      '/study/project',
    ]);
  });

  test('extracts semantically validated report evidence', () {
    expect(extractSanitizedReportEvidence(_canonicalReport(), waveMode: true), {
      'runElapsedMicros': 25000000,
      'verificationElapsedMicros': 17000000,
      'candidateVerificationElapsedMicros': 11000000,
      'analysisElapsedMicros': 5000000,
      'unaccountedElapsedMicros': 3000000,
      'verificationAttempts': 3,
      'verificationPolicyHash': _policyHash,
      'verificationAttemptTransactionIds': [
        ['tx-a'],
        ['tx-b'],
      ],
      'verificationWaveIds': ['wave-r001', 'wave-r002'],
    });
  });

  test('accepts a complete available baseline-red comparison baseline', () {
    final report = _canonicalReport();
    final attempts = report['verificationAttempts']! as List<Object?>;
    final baseline = attempts.first! as Map<String, Object?>;
    final steps = baseline['steps']! as List<Object?>;
    (steps.single! as Map<String, Object?>)['passed'] = false;
    final candidate = attempts[1]! as Map<String, Object?>;
    final candidateSteps = candidate['steps']! as List<Object?>;
    (candidateSteps.single! as Map<String, Object?>)['passed'] = false;

    expect(
      extractSanitizedReportEvidence(report, waveMode: true),
      containsPair('verificationAttempts', 3),
    );
  });

  test('rejects a wave ID that does not exactly encode its round', () {
    final report = _canonicalReport();
    final attempts = report['verificationAttempts']! as List<Object?>;
    (attempts[1]! as Map<String, Object?>)['waveId'] = 'wave-r999';

    expect(
      () => extractSanitizedReportEvidence(report, waveMode: true),
      throwsA(isA<BenchmarkStudyInvalidException>()),
    );
  });

  test('rejects missing, negative, and over-accounted report timing', () {
    final missing = _canonicalReport()..remove('run');
    expect(
      () => extractSanitizedReportEvidence(missing, waveMode: true),
      throwsA(isA<BenchmarkStudyInvalidException>()),
    );
    final negative = _canonicalReport();
    (negative['run']! as Map<String, Object?>)['elapsedMicros'] = -1;
    expect(
      () => extractSanitizedReportEvidence(negative, waveMode: true),
      throwsA(isA<BenchmarkStudyInvalidException>()),
    );
    final overAccounted = _canonicalReport();
    (overAccounted['run']! as Map<String, Object?>)['elapsedMicros'] = 21000000;
    expect(
      () => extractSanitizedReportEvidence(overAccounted, waveMode: true),
      throwsA(isA<BenchmarkStudyInvalidException>()),
    );
  });

  test('rejects forged verification-attempt semantics', () {
    for (final mutation in [
      'incomplete',
      'candidate-unaccepted',
      'policy',
      'step-order',
      'empty-membership',
      'singular-mismatch',
      'wrong-round',
    ]) {
      final report =
          jsonDecode(jsonEncode(_canonicalReport())) as Map<String, Object?>;
      final attempts = report['verificationAttempts']! as List<Object?>;
      final candidate = attempts[1]! as Map<String, Object?>;
      switch (mutation) {
        case 'incomplete':
          candidate['complete'] = false;
        case 'candidate-unaccepted':
          candidate['accepted'] = false;
        case 'policy':
          candidate['policyHash'] = '8' * 64;
        case 'step-order':
          candidate['observedStepIds'] = const ['other'];
        case 'empty-membership':
          candidate['transactionIds'] = const [];
        case 'singular-mismatch':
          candidate['transactionId'] = 'tx-forged';
        case 'wrong-round':
          candidate['round'] = 2;
      }
      expect(
        () => extractSanitizedReportEvidence(report, waveMode: true),
        throwsA(isA<BenchmarkStudyInvalidException>()),
        reason: mutation,
      );
    }
  });

  test('profile contract is checked against frozen expectations', () {
    final contract = frozenProfileExpectation(
      'control-1x1',
      waveMode: true,
    ).toContract();
    expect(
      () => validateFrozenProfileContract(
        'control-1x1',
        contract,
        waveMode: true,
      ),
      returnsNormally,
    );
    contract['finalHash'] = '9' * 64;
    expect(
      () => validateFrozenProfileContract(
        'control-1x1',
        contract,
        waveMode: true,
      ),
      throwsA(isA<BenchmarkStudyInvalidException>()),
    );
  });

  test(
    'input identity hashes source files and toolchain inputs itself',
    () async {
      final directory = Directory.systemTemp.createTempSync(
        'wave_v2_identity_',
      );
      try {
        final fixture = Directory('${directory.path}/fixture')..createSync();
        File('${fixture.path}/source').writeAsStringSync('fixture');
        final a = File('${directory.path}/a')..writeAsStringSync('a');
        final b = File('${directory.path}/b')..writeAsStringSync('b');
        final programA = File('${directory.path}/a.aot')
          ..writeAsStringSync('program-a');
        final programB = File('${directory.path}/b.aot')
          ..writeAsStringSync('program-b');
        final harness = File('${directory.path}/harness')
          ..writeAsStringSync('harness');
        final generator = File('${directory.path}/generator')
          ..writeAsStringSync('generator');
        final boundary = File('${directory.path}/boundary')
          ..writeAsStringSync('boundary');
        final wave = File('${directory.path}/wave')..writeAsStringSync('wave');
        final first = await createBenchmarkInputIdentity(
          fixture: fixture,
          executableA: a,
          executableB: b,
          programA: programA,
          programB: programB,
          harness: harness,
          generator: generator,
          boundaryPatch: boundary,
          verificationWavePatch: wave,
          dartToolchainIdentity: 'dart-test',
          flutterToolchainIdentity: 'flutter-test',
          applyArguments: const ['--yes'],
        );
        boundary.writeAsStringSync('forged');
        programA.writeAsStringSync('forged-program-a');
        final second = await createBenchmarkInputIdentity(
          fixture: fixture,
          executableA: a,
          executableB: b,
          programA: programA,
          programB: programB,
          harness: harness,
          generator: generator,
          boundaryPatch: boundary,
          verificationWavePatch: wave,
          dartToolchainIdentity: 'dart-test',
          flutterToolchainIdentity: 'flutter-test',
          applyArguments: const ['--yes'],
        );
        expect(first.boundaryPatchSha256, isNot(second.boundaryPatchSha256));
        expect(first.aProgramSha256, isNot(second.aProgramSha256));
        expect(first.aExecutableSha256, second.aExecutableSha256);
        expect(first.generatorSha256, second.generatorSha256);
      } finally {
        directory.deleteSync(recursive: true);
      }
    },
  );

  test('validates exact A and B repetition contracts', () {
    final a = _repetitionContracts(verifierInvocationCount: 3, waveCount: 0);
    final b = _repetitionContracts(verifierInvocationCount: 2, waveCount: 1);

    expect(
      () => validateBenchmarkRepetitionContracts(
        a,
        expectedTransactions: 2,
        expectedRounds: 1,
        expectedVerifierInvocations: 3,
        expectedWaves: 0,
      ),
      returnsNormally,
    );
    expect(
      () => validateBenchmarkRepetitionContracts(
        b,
        expectedTransactions: 2,
        expectedRounds: 1,
        expectedVerifierInvocations: 2,
        expectedWaves: 1,
      ),
      returnsNormally,
    );
  });

  test('reads case statuses from the manifest top-level case journal', () {
    expect(
      benchmarkManifestCaseStatuses({
        'transactions': [
          {
            'transactionId': 'tx-a',
            'caseIds': ['case-a'],
          },
        ],
        'cases': [
          {'caseId': 'case-a', 'status': 'kept'},
        ],
      }),
      ['kept'],
    );
  });

  for (final mutation in const [
    'finalHash',
    'transactionIds',
    'transactionCount',
    'roundCount',
    'verifierInvocationCount',
    'waveCount',
  ]) {
    test('rejects a repetition contract with wrong $mutation', () {
      final contracts = _repetitionContracts(
        verifierInvocationCount: 3,
        waveCount: 0,
      );
      contracts[1][mutation] = switch (mutation) {
        'finalHash' => 'b' * 64,
        'transactionIds' => const ['tx-b', 'tx-a'],
        _ => 99,
      };
      expect(
        () => validateBenchmarkRepetitionContracts(
          contracts,
          expectedTransactions: 2,
          expectedRounds: 1,
          expectedVerifierInvocations: 3,
          expectedWaves: 0,
        ),
        throwsA(isA<BenchmarkStudyInvalidException>()),
      );
    });
  }

  test('retains raw chronological A/A pair evidence', () {
    final record = aaPairRecord(
      order: 'BA',
      first: const Duration(microseconds: 80),
      second: const Duration(microseconds: 100),
      firstContract: const {'finalHash': 'same'},
      secondContract: const {'finalHash': 'same'},
    );

    expect(record, {
      'order': 'BA',
      'firstElapsedMicros': 80,
      'secondElapsedMicros': 100,
      'pairedRelativeDelta': 0.2,
      'firstContract': {'finalHash': 'same'},
      'secondContract': {'finalHash': 'same'},
    });
  });

  test('retains raw A/B durations and correctness contracts', () {
    final record = abPairRecord(
      order: 'AB',
      a: const Duration(microseconds: 100),
      b: const Duration(microseconds: 75),
      aContract: const {'verifierInvocationCount': 13},
      bContract: const {'verifierInvocationCount': 2},
    );

    expect(record, {
      'order': 'AB',
      'aElapsedMicros': 100,
      'bElapsedMicros': 75,
      'pairedRelativeDelta': 0.25,
      'aContract': {'verifierInvocationCount': 13},
      'bContract': {'verifierInvocationCount': 2},
    });
  });

  test('benchmark source does not invoke dependency hydration', () {
    final source = File(
      'benchmark/apply_verification_wave_benchmark.dart',
    ).readAsStringSync();
    expect(source, isNot(contains("'pub', 'get'")));
    expect(source, contains("'aa-frozen'"));
  });
}

BenchmarkInputIdentity _benchmarkIdentity() => BenchmarkInputIdentity(
  fixtureSha256: 'a' * 64,
  aExecutableSha256: 'b' * 64,
  bExecutableSha256: 'c' * 64,
  aProgramSha256: '5' * 64,
  bProgramSha256: '6' * 64,
  harnessSha256: 'd' * 64,
  generatorSha256: '1' * 64,
  boundaryPatchSha256: 'e' * 64,
  verificationWavePatchSha256: 'f' * 64,
  dartToolchainSha256: '2' * 64,
  flutterToolchainSha256: '3' * 64,
  applyArgumentsSha256: '4' * 64,
);

Map<String, Object?> _frozenAaArtifact() => {
  'schemaVersion': 2,
  'protocolId': 'apply-verification-wave-v2-block3-pairs6',
  'profile': 'control-1x1',
  'status': 'aa-frozen',
  'sampleRepetitionsPerBlock': 3,
  'schedule': ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'],
  'noiseThreshold': 0.0,
  'aaPairedRelativeDeltas': [0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
  'verificationPolicyHash': _policyHash,
  'aaPairs': [
    for (final order in const ['AB', 'BA', 'AB', 'BA', 'AB', 'BA'])
      _aaBlock(order),
  ],
  ..._benchmarkIdentity().toJson(),
};

Map<String, Object?> _readArtifact(File file) =>
    jsonDecode(file.readAsStringSync()) as Map<String, Object?>;

Map<String, Object?> _aaBlock(String order) => aaBlockPairRecord(
  order: order,
  firstRepetitions: _blockRepetitions(100),
  secondRepetitions: _blockRepetitions(100),
);

Map<String, Object?> _abBlock(String order) => abBlockPairRecord(
  order: order,
  aRepetitions: _blockRepetitions(100),
  bRepetitions: _blockRepetitions(80),
);

List<Map<String, Object?>> _blockRepetitions(int elapsedMicros) => [
  for (var index = 0; index < 3; index++)
    {
      'elapsedMicros': elapsedMicros,
      'contract': const {'finalHash': 'same'},
      'timings': const {'verificationPolicyHash': _policyHash},
    },
];

Map<String, Object?> _canonicalReport() => {
  'version': 3,
  'run': {
    'command': 'apply',
    'status': 'completed',
    'exitCode': 0,
    'elapsedMicros': 25000000,
  },
  'execution': {
    'analysisPasses': [
      {'elapsedMicros': 2000000},
      {'elapsedMicros': 3000000},
    ],
  },
  'verificationAttempts': [
    {
      'purpose': 'baseline',
      'complete': true,
      'available': true,
      'accepted': true,
      'policyHash': _policyHash,
      'requiredStepIds': ['analyze'],
      'observedStepIds': ['analyze'],
      'steps': [
        {
          'id': 'analyze',
          'passed': true,
          'available': true,
          'elapsedMicros': 6000000,
        },
      ],
    },
    {
      'purpose': 'candidate',
      'round': 1,
      'waveId': 'wave-r001',
      'transactionId': 'tx-a',
      'transactionIds': ['tx-a'],
      'complete': true,
      'available': true,
      'accepted': true,
      'policyHash': _policyHash,
      'requiredStepIds': ['analyze'],
      'observedStepIds': ['analyze'],
      'steps': [
        {
          'id': 'analyze',
          'passed': true,
          'available': true,
          'elapsedMicros': 5000000,
        },
      ],
    },
    {
      'purpose': 'candidate',
      'round': 2,
      'waveId': 'wave-r002',
      'transactionId': 'tx-b',
      'transactionIds': ['tx-b'],
      'complete': true,
      'available': true,
      'accepted': true,
      'policyHash': _policyHash,
      'requiredStepIds': ['analyze'],
      'observedStepIds': ['analyze'],
      'steps': [
        {
          'id': 'analyze',
          'passed': true,
          'available': true,
          'elapsedMicros': 6000000,
        },
      ],
    },
  ],
};

List<Map<String, Object?>> _repetitionContracts({
  required int verifierInvocationCount,
  required int waveCount,
}) => [
  for (var index = 0; index < 3; index++)
    {
      'finalHash': 'a' * 64,
      'transactionIds': const ['tx-a', 'tx-b'],
      'transactionCount': 2,
      'roundCount': 1,
      'verifierInvocationCount': verifierInvocationCount,
      'waveCount': waveCount,
    },
];

List<File> _writeCohort(Directory directory, File current) {
  final control = File('${directory.path}/control-aa-frozen.json')
    ..writeAsStringSync(current.readAsStringSync());
  final fanout = File('${directory.path}/fanout.json');
  final chain = File('${directory.path}/chain.json');
  fanout.writeAsStringSync(
    jsonEncode(
      _frozenAaArtifact()
        ..['profile'] = 'fanout-12x1'
        ..['fixtureSha256'] = '5' * 64,
    ),
  );
  chain.writeAsStringSync(
    jsonEncode(
      _frozenAaArtifact()
        ..['profile'] = 'chain-2plus-rounds'
        ..['fixtureSha256'] = '6' * 64,
    ),
  );
  return [control, fanout, chain];
}
