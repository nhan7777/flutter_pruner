import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_verdict.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:test/test.dart';

const _family =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _selection =
    '2222222222222222222222222222222222222222222222222222222222222222';
const _configuration =
    '3333333333333333333333333333333333333333333333333333333333333333';
const _packages =
    '4444444444444444444444444444444444444444444444444444444444444444';
const _toolchain =
    '5555555555555555555555555555555555555555555555555555555555555555';
const _baselineA =
    '6666666666666666666666666666666666666666666666666666666666666666';
const _baselineZ =
    '7777777777777777777777777777777777777777777777777777777777777777';
const _candidate =
    '8888888888888888888888888888888888888888888888888888888888888888';
const _mutation =
    '9999999999999999999999999999999999999999999999999999999999999999';

void main() {
  group('L10nEvidenceVerdict', () {
    test('accepted verdict has no rejection evidence', () {
      final verdict = _verdict(status: L10nEvidenceStatus.accepted);

      expect(verdict.status, L10nEvidenceStatus.accepted);
      expect(verdict.reasonCodes, isEmpty);
      expect(verdict.failures, isEmpty);
      expect(verdict.toInternalJson(), containsPair('status', 'accepted'));
      expect(verdict.toInternalJson(), containsPair('reasonCodes', const []));
      expect(verdict.toInternalJson(), containsPair('failures', const []));
    });

    test('rejected verdict sorts and deduplicates codes and failures', () {
      final verdict = _verdict(
        status: L10nEvidenceStatus.rejected,
        failures: const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.internalFailure,
            stage: 'z-stage',
            detailCode: 'z-detail',
            relativePath: 'lib/z.dart',
          ),
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'selection',
            detailCode: 'z-detail',
          ),
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'selection',
            detailCode: 'a-detail',
          ),
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.invalidSelection,
            stage: 'selection',
            detailCode: 'a-detail',
          ),
        ],
      );

      expect(verdict.reasonCodes, [
        L10nEvidenceRejectionCode.invalidSelection,
        L10nEvidenceRejectionCode.internalFailure,
      ]);
      expect(
        verdict.failures
            .map(
              (failure) => (
                failure.code.name,
                failure.stage,
                failure.relativePath,
                failure.detailCode,
              ),
            )
            .toList(),
        [
          ('invalidSelection', 'selection', null, 'a-detail'),
          ('invalidSelection', 'selection', null, 'z-detail'),
          ('internalFailure', 'z-stage', 'lib/z.dart', 'z-detail'),
        ],
      );
      expect(verdict.toInternalJson()['reasonCodes'], [
        'invalidSelection',
        'internalFailure',
      ]);
      expect((verdict.toInternalJson()['failures']! as List<Object?>).first, {
        'code': 'invalidSelection',
        'stage': 'selection',
        'detailCode': 'a-detail',
      });
    });

    test('requires status and failure state to agree', () {
      expect(
        () => _verdict(
          status: L10nEvidenceStatus.accepted,
          failures: const [
            L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.internalFailure,
              stage: 'pipeline',
              detailCode: 'unexpected-failure',
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _verdict(status: L10nEvidenceStatus.rejected),
        throwsArgumentError,
      );
      expect(
        () => _verdict(
          status: L10nEvidenceStatus.rejected,
          failures: const [
            L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.internalFailure,
              stage: 'pipeline',
              detailCode: 'unsafe-path',
              relativePath: 'lib/\nsecret.dart',
            ),
          ],
        ),
        throwsArgumentError,
      );
    });

    test('defensively sorts and deeply freezes every collection', () {
      final failures = <L10nEvidenceFailure>[
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.cleanupFailed,
          stage: 'cleanup',
          detailCode: 'stage-root-retained',
        ),
      ];
      final baseline = <String, String>{'z': _baselineZ, 'a': _baselineA};
      final candidate = <String, String>{'output': _candidate};
      final selectedKeys = <Object?>['dead'];
      final pathSummary = <String, Object?>{
        'z': 2,
        'a': <Object?>[1, 2],
      };
      final mutation = <String, Object?>{
        'selectedKeys': selectedKeys,
        'paths': pathSummary,
      };
      final verification = <String, Object?>{
        'candidate': <String, Object?>{'passed': false},
      };
      final metrics = <String, Object?>{
        'elapsedMicros': 42,
        'samples': <Object?>[3, 5],
      };

      final verdict = _verdict(
        status: L10nEvidenceStatus.rejected,
        failures: failures,
        baselineInventoryHashes: baseline,
        candidateInventoryHashes: candidate,
        mutationSummary: mutation,
        verificationSummary: verification,
        timingAndResourceMetrics: metrics,
      );
      failures.clear();
      baseline.clear();
      candidate.clear();
      selectedKeys.clear();
      pathSummary.clear();
      mutation.clear();
      verification.clear();
      metrics.clear();

      expect(verdict.baselineInventoryHashes.keys, ['a', 'z']);
      expect(verdict.baselineInventoryHashes['a'], _baselineA);
      expect(verdict.candidateInventoryHashes['output'], _candidate);
      expect(verdict.mutationSummary.keys, ['paths', 'selectedKeys']);
      expect(verdict.mutationSummary['selectedKeys'], ['dead']);
      expect((verdict.mutationSummary['paths']! as Map).keys, ['a', 'z']);
      expect(verdict.failures, hasLength(1));

      expect(() => verdict.reasonCodes.clear(), throwsUnsupportedError);
      expect(() => verdict.failures.clear(), throwsUnsupportedError);
      expect(
        () => verdict.baselineInventoryHashes.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => verdict.candidateInventoryHashes.clear(),
        throwsUnsupportedError,
      );
      expect(() => verdict.mutationSummary.clear(), throwsUnsupportedError);
      expect(() => verdict.verificationSummary.clear(), throwsUnsupportedError);
      expect(
        () => verdict.timingAndResourceMetrics.clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            (verdict.mutationSummary['selectedKeys']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (verdict.mutationSummary['paths']! as Map<Object?, Object?>)
            .clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            (verdict.verificationSummary['candidate']! as Map<Object?, Object?>)
                .clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (verdict.timingAndResourceMetrics['samples']! as List<Object?>)
            .clear(),
        throwsUnsupportedError,
      );

      final json = verdict.toInternalJson();
      expect(() => json.clear(), throwsUnsupportedError);
      expect(
        () => (json['failures']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            ((json['failures']! as List<Object?>).first as Map<String, Object?>)
                .clear(),
        throwsUnsupportedError,
      );
    });

    test('validates every SHA-256 identity and inventory hash', () {
      for (final field in <String>[
        'familyFingerprint',
        'selectionFingerprint',
        'configurationIdentity',
        'packageResolutionIdentity',
        'toolchainIdentity',
      ]) {
        expect(
          () => _verdict(
            status: L10nEvidenceStatus.accepted,
            familyFingerprint: field == 'familyFingerprint' ? 'bad' : _family,
            selectionFingerprint: field == 'selectionFingerprint'
                ? 'A' * 64
                : _selection,
            configurationIdentity: field == 'configurationIdentity'
                ? '0' * 63
                : _configuration,
            packageResolutionIdentity: field == 'packageResolutionIdentity'
                ? 'g' * 64
                : _packages,
            toolchainIdentity: field == 'toolchainIdentity' ? '' : _toolchain,
          ),
          throwsArgumentError,
          reason: field,
        );
      }
      expect(
        () => _verdict(
          status: L10nEvidenceStatus.accepted,
          baselineInventoryHashes: const {'baseline': 'not-a-sha'},
        ),
        throwsArgumentError,
      );
      expect(
        () => _verdict(
          status: L10nEvidenceStatus.accepted,
          candidateInventoryHashes: const {'/private/stage': _candidate},
        ),
        throwsArgumentError,
      );
      expect(
        () => _verdict(
          status: L10nEvidenceStatus.accepted,
          baselineInventoryHashes: const {'stdoutText': _baselineA},
        ),
        throwsArgumentError,
      );
    });

    test('serializes only redacted hashes metrics and relative facts', () {
      const rawOutput = 'raw-stdout-secret';
      const environmentValue = 'environment-secret';
      const absolutePath = '/private/tmp/owned-stage';
      final verdict = _verdict(
        status: L10nEvidenceStatus.accepted,
        mutationSummary: const <String, Object?>{
          'mutationFingerprint': _mutation,
          'selectedKeys': <Object?>['dead'],
          'replacementPaths': <Object?>['lib/l10n/app_en.arb'],
        },
        verificationSummary: const <String, Object?>{
          'process': <String, Object?>{
            'stdout': <String, Object?>{
              'sha256': _baselineA,
              'capturedBytes': 17,
              'omittedBytes': 0,
              'truncated': false,
            },
          },
        },
        timingAndResourceMetrics: const <String, Object?>{
          'elapsedMicros': 123,
          'sampledPeakRssBytes': 456,
          'environmentIdentity': _configuration,
        },
      );

      final encoded = jsonEncode(verdict.toInternalJson());
      expect(encoded, contains(_mutation));
      expect(encoded, contains('sampledPeakRssBytes'));
      expect(encoded, contains('lib/l10n/app_en.arb'));
      expect(encoded, isNot(contains(rawOutput)));
      expect(encoded, isNot(contains(environmentValue)));
      expect(encoded, isNot(contains(absolutePath)));

      for (final unsafeSummary in <Map<String, Object?>>[
        <String, Object?>{
          'sourceBytes': Uint8List.fromList([1, 2, 3]),
        },
        const <String, Object?>{'stdout': rawOutput},
        const <String, Object?>{
          'stdout': <Object?>[114, 97, 119],
        },
        const <String, Object?>{
          'stdout': <String, Object?>{'text': rawOutput},
        },
        const <String, Object?>{
          'stdout': <String, Object?>{'sha256': rawOutput},
        },
        const <String, Object?>{'capturedOutput': rawOutput},
        const <String, Object?>{'stdoutSha256': rawOutput},
        const <String, Object?>{'capturedStdoutHash': rawOutput},
        const <String, Object?>{'stdoutText': rawOutput},
        const <String, Object?>{
          'environmentValues': <String, Object?>{'TOKEN': environmentValue},
        },
        const <String, Object?>{'environmentIdentity': environmentValue},
        const <String, Object?>{'stageRoot': absolutePath},
        const <String, Object?>{
          'note': 'verification failed at /private/tmp/owned-stage',
        },
        const <String, Object?>{
          'note': 'verification failed at //private/tmp/owned-stage',
        },
        const <String, Object?>{
          'note': 'verification failed at file:///private/tmp/owned-stage',
        },
        const <String, Object?>{'stageRoot': r'C:\temp\owned-stage'},
        const <String, Object?>{'stageRoot': 'file:///private/tmp/stage'},
      ]) {
        expect(
          () => _verdict(
            status: L10nEvidenceStatus.accepted,
            verificationSummary: unsafeSummary,
          ),
          throwsArgumentError,
          reason: '$unsafeSummary',
        );
      }

      expect(
        () => _verdict(
          status: L10nEvidenceStatus.rejected,
          failures: const [
            L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.internalFailure,
              stage: 'pipeline',
              detailCode: 'unsafe-path',
              relativePath: absolutePath,
            ),
          ],
        ),
        throwsArgumentError,
      );
    });
  });

  group('L10nEvidenceEvaluation', () {
    test('retains a witnessed change set only for an accepted verdict', () {
      final changeSet = _changeSet();
      final accepted = L10nEvidenceEvaluation(
        verdict: _verdict(status: L10nEvidenceStatus.accepted),
        witnessedChangeSet: changeSet,
      );
      final rejected = L10nEvidenceEvaluation(
        verdict: _verdict(
          status: L10nEvidenceStatus.rejected,
          failures: const [
            L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.candidateVerificationFailed,
              stage: 'verification',
              detailCode: 'candidate-rejected',
            ),
          ],
        ),
        witnessedChangeSet: changeSet,
      );

      expect(accepted.witnessedChangeSet, same(changeSet));
      expect(rejected.witnessedChangeSet, isNull);
      expect(
        () => L10nEvidenceEvaluation(
          verdict: _verdict(status: L10nEvidenceStatus.accepted),
        ),
        throwsArgumentError,
      );
    });
  });
}

L10nEvidenceVerdict _verdict({
  required L10nEvidenceStatus status,
  Iterable<L10nEvidenceFailure> failures = const [],
  String familyFingerprint = _family,
  String selectionFingerprint = _selection,
  String configurationIdentity = _configuration,
  String packageResolutionIdentity = _packages,
  String toolchainIdentity = _toolchain,
  Map<String, String> baselineInventoryHashes = const {'baseline': _baselineA},
  Map<String, String> candidateInventoryHashes = const {
    'candidate': _candidate,
  },
  Map<String, Object?> mutationSummary = const {
    'mutationFingerprint': _mutation,
  },
  Map<String, Object?> verificationSummary = const {'candidateAccepted': true},
  Map<String, Object?> timingAndResourceMetrics = const {'elapsedMicros': 1},
}) => L10nEvidenceVerdict(
  status: status,
  failures: failures,
  familyFingerprint: familyFingerprint,
  selectionFingerprint: selectionFingerprint,
  configurationIdentity: configurationIdentity,
  packageResolutionIdentity: packageResolutionIdentity,
  toolchainIdentity: toolchainIdentity,
  baselineInventoryHashes: baselineInventoryHashes,
  candidateInventoryHashes: candidateInventoryHashes,
  mutationSummary: mutationSummary,
  verificationSummary: verificationSummary,
  timingAndResourceMetrics: timingAndResourceMetrics,
);

L10nWitnessedChangeSet _changeSet() {
  final replacement = L10nFileReplacement(
    relativePath: 'lib/l10n/app_en.arb',
    beforeBytes: ImmutableBytes.copyOf(utf8.encode('{"dead":"Dead"}\n')),
    afterBytes: ImmutableBytes.copyOf(utf8.encode('{}\n')),
    beforeMode: 0x1a4,
    afterMode: 0x1a4,
  );
  return L10nWitnessedChangeSet(
    arbReplacements: {replacement.relativePath: replacement},
    generatedReplacements: const {},
  );
}
