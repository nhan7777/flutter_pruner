import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _frameworkVersion = '3.38.7';
const _frameworkRevision = '3b62efc2a3da49882f43c372e0bc53daef7295a6';
const _engineRevision = '3838383838383838383838383838383838383838';
const _engineContentHash = '3838383838383838383838383838383838383838';
const _dartVersion = '3.10.7';
const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _outputPath = 'lib/generated/app.dart';
const _templatePath = 'lib/l10n/app_en.arb';
const _fixedEnvironment = <String, String>{
  'CI': 'true',
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  'LANG': 'en_US.UTF-8',
  'LC_ALL': 'en_US.UTF-8',
};

void main() {
  group('ProcessL10nGenerator bound launch', () {
    setUp(() {
      if (Platform.isWindows) {
        markTestSkipped(
          'Task 6 currently requires POSIX host executable authority.',
        );
      }
    });

    test(
      'uses the resolver-bound command exactly and consumes one stage once',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result(stdout: 'generation-complete'.codeUnits);
          },
        );
        final generator = const ProcessL10nGenerator(
          timeout: Duration(minutes: 2),
          maxOutputBytesPerStream: 4096,
        );
        final stage = fixture.pair.baseline;

        expect(stage.role, L10nStageRole.baseline);
        expect(stage.toolchainIdentity, fixture.toolchain.identitySha256);
        expect(stage.generationOutputPaths.toList(), [_outputPath]);
        expect(
          () => stage.generationOutputPaths.add('lib/generated/rogue.dart'),
          throwsUnsupportedError,
        );

        final run = await generator.generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.phase, L10nGenerationPhase.baseline);
        expect(run.failures, isEmpty);
        expect(run.processResult!.exitCode, 0);
        expect(run.before.entries, isNot(contains(_outputPath)));
        expect(
          run.after.entries[_outputPath]!.capturedBytes!.copy(),
          'generated'.codeUnits,
        );
        expect(
          run.after.entries['lib/generated']!.kind,
          L10nStageEntryKind.directory,
        );
        expect(run.commandIdentity, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(
          () => run.failures.add(_internalFailure),
          throwsUnsupportedError,
        );

        expect(fixture.runner.calls, hasLength(2));
        final probe = fixture.runner.calls.first;
        final generation = fixture.runner.calls.last;
        final sdkRoot = p.dirname(p.dirname(fixture.canonicalFlutter));
        final sandboxRoot = generation.sandboxRoot;
        expect(generation.executable, '/test/sandbox-exec');
        expect(generation.arguments, [
          '-D',
          'SANDBOX_ROOT=$sandboxRoot',
          '-D',
          'WRITE_ROOT=${stage.directory.resolveSymbolicLinksSync()}',
          '-p',
          '(version 1)(allow default)(deny network*)'
              '(deny file-write*)'
              '(allow file-write* (subpath (param "SANDBOX_ROOT")))'
              '(allow file-write* (subpath (param "WRITE_ROOT")))',
          p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
          p.join(sdkRoot, 'bin', 'cache', 'flutter_tools.snapshot'),
          'gen-l10n',
        ]);
        expect(generation.workingDirectory, stage.directory.path);
        expect(generation.timeout, const Duration(minutes: 2));
        expect(generation.maxOutputBytesPerStream, 4096);
        expect(generation.includeParentEnvironment, isFalse);
        expect(generation.environmentOverrides.keys.toSet(), {
          ..._fixedEnvironment.keys,
          'FLUTTER_ROOT',
          'FLUTTER_ALREADY_LOCKED',
          'HOME',
          'XDG_CONFIG_HOME',
          'PUB_CACHE',
          'TMPDIR',
          'PATH',
        });
        for (final entry in _fixedEnvironment.entries) {
          expect(
            generation.environmentOverrides,
            containsPair(entry.key, entry.value),
          );
        }
        expect(generation.environmentOverrides['FLUTTER_ROOT'], sdkRoot);
        expect(
          generation.environmentOverrides['FLUTTER_ALREADY_LOCKED'],
          'true',
        );
        expect(
          generation.environmentOverrides['HOME'],
          p.join(sandboxRoot, 'home'),
        );
        expect(
          generation.environmentOverrides['XDG_CONFIG_HOME'],
          p.join(sandboxRoot, 'xdg-config'),
        );
        expect(
          generation.environmentOverrides['PUB_CACHE'],
          p.join(sandboxRoot, 'pub-cache'),
        );
        expect(
          generation.environmentOverrides['TMPDIR'],
          p.join(sandboxRoot, 'tmp'),
        );
        expect(
          generation.environmentOverrides['PATH'],
          p.join(sandboxRoot, 'bin'),
        );
        expect(generation.arguments, isNot(contains('-c')));
        expect(
          generation.arguments.skip(generation.arguments.length - 1),
          isNot(containsAllInOrder(const ['pub', 'get'])),
        );
        expect(probe.sandboxRoot, isNot(sandboxRoot));
        expect(Directory(sandboxRoot).existsSync(), isFalse);

        final consumed = await generator.generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(fixture.runner.calls, hasLength(2));
        expect(consumed.processResult, isNull);
        _expectFailure(
          consumed.failures,
          L10nEvidenceRejectionCode.baselineGenerationFailed,
          'stage-root-generation-capability-consumed',
          stage: 'baseline-generation',
        );
      },
    );

    test(
      'rejects phase and root-role mismatch before consuming the stage',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'candidate');
            return _result();
          },
        );
        const generator = ProcessL10nGenerator();
        final candidate = fixture.pair.candidate;
        final invalidInventoryPath = File(
          p.join(candidate.directory.path, 'bad%name.txt'),
        )..writeAsStringSync('must not be inventoried');

        await expectLater(
          generator.generate(
            stage: candidate,
            toolchain: fixture.toolchain,
            phase: L10nGenerationPhase.baseline,
            outputPaths: const {_outputPath},
          ),
          throwsArgumentError,
        );
        expect(fixture.runner.calls, hasLength(1));
        expect(candidate.safeToDelete, isTrue);
        invalidInventoryPath.deleteSync();

        await fixture.installCandidateArbs();
        final run = await generator.generate(
          stage: candidate,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.candidate,
          outputPaths: const {_outputPath},
        );

        expect(run.failures, isEmpty);
        expect(fixture.runner.calls, hasLength(2));
      },
    );

    test(
      'requires the stage-owned exact generation allowlist before inventory',
      () async {
        final fixture = await _createBoundFixture(
          withSidecar: true,
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result();
          },
        );
        const generator = ProcessL10nGenerator();
        final stage = fixture.pair.baseline;
        expect(stage.generationOutputPaths.toList(), [
          'build/untranslated.json',
          _outputPath,
        ]);

        for (final wrongPaths in <Set<String>>[
          const {},
          const {_outputPath},
          const {
            _outputPath,
            'build/untranslated.json',
            'lib/generated/extra.dart',
          },
          const {_templatePath},
          const {'../outside.dart'},
          const {'LIB/generated/app.dart', 'build/untranslated.json'},
          {p.join(stage.directory.path, 'absolute.dart')},
        ]) {
          await expectLater(
            generator.generate(
              stage: stage,
              toolchain: fixture.toolchain,
              phase: L10nGenerationPhase.baseline,
              outputPaths: wrongPaths,
            ),
            throwsArgumentError,
            reason: '$wrongPaths',
          );
        }
        expect(fixture.runner.calls, hasLength(1));

        final valid = await generator.generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath, 'build/untranslated.json'},
        );
        expect(valid.failures, isEmpty);
        expect(
          valid.after.entries,
          isNot(contains('build/untranslated.json')),
          reason: 'Task 11 reconciles allowed optional-output absence.',
        );
        expect(fixture.runner.calls, hasLength(2));
      },
    );

    test(
      'reports toolchain identity mismatch without consuming the stage',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result();
          },
        );
        const generator = ProcessL10nGenerator();
        final stage = fixture.pair.baseline;
        final drifted = _copyToolchain(
          fixture.toolchain,
          identitySha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        );

        final rejected = await generator.generate(
          stage: stage,
          toolchain: drifted,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(rejected.processResult, isNull);
        expect(rejected.before.fingerprint, rejected.after.fingerprint);
        _expectFailure(
          rejected.failures,
          L10nEvidenceRejectionCode.toolchainDrift,
          'stage-toolchain-identity-mismatch',
          stage: 'baseline-generation',
        );
        expect(fixture.runner.calls, hasLength(1));

        final valid = await generator.generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );
        expect(valid.failures, isEmpty);
        expect(fixture.runner.calls, hasLength(2));
      },
    );

    test(
      'binds command identity stably to toolchain and stage authority',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result();
          },
        );
        const generator = ProcessL10nGenerator();
        final stage = fixture.pair.baseline;
        final drifted = _copyToolchain(
          fixture.toolchain,
          identitySha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        );

        final firstRejected = await generator.generate(
          stage: stage,
          toolchain: drifted,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );
        final secondRejected = await generator.generate(
          stage: stage,
          toolchain: drifted,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(secondRejected.commandIdentity, firstRejected.commandIdentity);
        expect(
          firstRejected.toRedactedJson()['commandIdentity'],
          firstRejected.commandIdentity,
        );

        final firstRun = await generator.generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );
        expect(firstRun.failures, isEmpty);
        expect(
          firstRun.commandIdentity,
          isNot(firstRejected.commandIdentity),
          reason: 'the bound toolchain identity must affect command identity',
        );

        final secondMaterialization = await fixture.materializer.materialize(
          fixture.snapshot,
        );
        expect(secondMaterialization.ready, isTrue);
        addTearDown(() async {
          if (!secondMaterialization.cleanupLease.consumed) {
            await fixture.materializer.cleanup(
              secondMaterialization.cleanupLease,
            );
          }
        });
        final secondRun = await generator.generate(
          stage: secondMaterialization.pair!.baseline,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(secondRun.failures, isEmpty);
        expect(
          secondRun.commandIdentity,
          isNot(firstRun.commandIdentity),
          reason: 'the bound stage authority must affect command identity',
        );
        expect(firstRun.commandIdentity, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(secondRun.commandIdentity, matches(RegExp(r'^[a-f0-9]{64}$')));
      },
    );

    test(
      'blocks an invalid pre-run inventory without following its link',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (_) =>
              throw StateError('Generation must not be attempted.'),
        );
        final stage = fixture.pair.baseline;
        final outside = File(p.join(fixture.scratch.path, 'outside.txt'))
          ..writeAsStringSync('outside-secret');
        Link(p.join(stage.directory.path, 'escape')).createSync(outside.path);

        final run = await const ProcessL10nGenerator().generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult, isNull);
        expect(run.before.invalidPaths, ['escape']);
        expect(run.after.fingerprint, run.before.fingerprint);
        expect(run.after.entries, isNot(contains('escape/outside.txt')));
        expect(stage.safeToDelete, isFalse);
        expect(fixture.runner.calls, hasLength(1));
        expect(outside.readAsStringSync(), 'outside-secret');
        _expectFailure(
          run.failures,
          L10nEvidenceRejectionCode.unexpectedStageWrite,
          'pre-generation-inventory-invalid',
          stage: 'baseline-generation',
          relativePath: 'escape',
        );
      },
    );

    test(
      'maps a genuine stage lease seal rejection without escaping',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (_) =>
              throw StateError('Generation must not be attempted.'),
        );
        final stage = fixture.pair.baseline;
        final stagedMain = File(p.join(stage.directory.path, 'lib/main.dart'));
        final outside = File(p.join(fixture.scratch.path, 'outside-main.dart'))
          ..writeAsBytesSync(stagedMain.readAsBytesSync());
        _chmod(outside.path, 0x1a4);
        stagedMain.deleteSync();
        final link = Process.runSync('/bin/ln', [
          outside.path,
          stagedMain.path,
        ]);
        expect(link.exitCode, 0, reason: '${link.stderr}');

        final run = await const ProcessL10nGenerator().generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult, isNull);
        expect(run.after.entries, isEmpty);
        expect(run.after.invalidPaths, ['.']);
        expect(stage.safeToDelete, isFalse);
        expect(fixture.runner.calls, hasLength(1));
        _expectFailure(
          run.failures,
          L10nEvidenceRejectionCode.baselineGenerationFailed,
          'generation-working-root-hardlink-unsupported',
          stage: 'baseline-generation',
        );
      },
    );

    for (final phase in L10nGenerationPhase.values) {
      test(
        'maps ${phase.name} nonzero exit and retains partial output',
        () async {
          final fixture = await _createBoundFixture(
            generationResponder: (call) {
              _writeStageFile(call.workingDirectory, _outputPath, 'partial');
              return _result(exitCode: 23, stderr: 'compile failed'.codeUnits);
            },
          );
          final stage = await fixture.stageFor(phase);

          final run = await const ProcessL10nGenerator().generate(
            stage: stage,
            toolchain: fixture.toolchain,
            phase: phase,
            outputPaths: const {_outputPath},
          );

          expect(run.processResult!.exitCode, 23);
          expect(
            run.after.entries[_outputPath]!.capturedBytes!.copy(),
            'partial'.codeUnits,
          );
          _expectFailure(
            run.failures,
            _phaseFailureCode(phase),
            'generation-process-nonzero-exit',
            stage: '${phase.name}-generation',
          );
        },
      );

      test('maps ${phase.name} confirmed timeout to its phase', () async {
        final fixture = await _createBoundFixture(
          generationResponder: (_) => _result(exitCode: -1, timedOut: true),
        );
        final stage = await fixture.stageFor(phase);

        final run = await const ProcessL10nGenerator().generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: phase,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult!.timedOut, isTrue);
        _expectFailure(
          run.failures,
          _phaseFailureCode(phase),
          'generation-process-timeout',
          stage: '${phase.name}-generation',
        );
      });
    }

    test(
      'rejects either bounded stream truncation with exact evidence',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result(
              stdout: 'stdout-prefix'.codeUnits,
              stdoutOmittedBytes: 17,
              stderr: 'stderr-prefix'.codeUnits,
              stderrOmittedBytes: 29,
            );
          },
        );

        final run = await const ProcessL10nGenerator().generate(
          stage: fixture.pair.baseline,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult!.stdout.capturedBytes, 13);
        expect(run.processResult!.stdout.omittedBytes, 17);
        expect(run.processResult!.stderr.capturedBytes, 13);
        expect(run.processResult!.stderr.omittedBytes, 29);
        _expectFailure(
          run.failures,
          L10nEvidenceRejectionCode.generatorOutputTruncated,
          'generator-output-truncated',
          stage: 'baseline-generation',
        );
      },
    );

    test(
      'captures partial writes and retains the root when termination is unconfirmed',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'uncertain');
            throw const ProcessTerminationUnconfirmedException(
              processId: 404,
              message: 'secret host process detail',
            );
          },
        );
        final stage = fixture.pair.baseline;

        final run = await const ProcessL10nGenerator().generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult, isNull);
        expect(run.after.entries, isEmpty);
        expect(run.after.invalidPaths, ['.']);
        expect(run.after.fingerprint, isNot(run.before.fingerprint));
        expect(run.after.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(stage.safeToDelete, isFalse);
        expect(
          Directory(fixture.runner.calls.last.sandboxRoot).existsSync(),
          isTrue,
        );
        _expectFailure(
          run.failures,
          L10nEvidenceRejectionCode.generatorTerminationUnconfirmed,
          'generator-termination-unconfirmed',
          stage: 'baseline-generation',
        );
        final redacted = run.toRedactedJson();
        final encoded = jsonEncode(redacted);
        expect(redacted['process'], isNull);
        expect(encoded, isNot(contains('secret host process detail')));
        expect(encoded, isNot(contains('processId')));
        expect(encoded, isNot(contains(stage.directory.path)));

        final cleanup = await fixture.cleanup();
        expect(cleanup.baselineRemoved, isFalse);
        expect(stage.directory.existsSync(), isTrue);
        _expectFailure(
          cleanup.failures,
          L10nEvidenceRejectionCode.cleanupFailed,
          'baseline-root-unsafe-to-delete',
          stage: 'stage-cleanup',
        );
      },
    );

    test(
      'freezes the exact output set and reports every unexpected write',
      () async {
        final requested = <String>{_outputPath};
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            requested
              ..clear()
              ..add('rogue.txt');
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            _writeStageFile(call.workingDirectory, 'rogue.txt', 'rogue');
            _writeStageFile(
              call.workingDirectory,
              'pubspec.yaml',
              'name: mutated\n',
            );
            File(
              p.join(call.workingDirectory, 'lib', 'main.dart'),
            ).deleteSync();
            _chmod(
              p.join(call.workingDirectory, 'lib', 'l10n', 'app_en.arb'),
              0x180,
            );
            File(p.join(call.workingDirectory, 'pubspec.lock')).deleteSync();
            final replacement = Directory(
              p.join(call.workingDirectory, 'pubspec.lock'),
            )..createSync();
            _chmod(replacement.path, 0x1c0);
            return _result();
          },
        );

        final run = await const ProcessL10nGenerator().generate(
          stage: fixture.pair.baseline,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: requested,
        );

        expect(run.after.entries[_outputPath]!.capturedBytes, isNotNull);
        expect(run.after.entries['rogue.txt']!.capturedBytes, isNull);
        expect(
          run.failures
              .where(
                (failure) =>
                    failure.code ==
                    L10nEvidenceRejectionCode.unexpectedStageWrite,
              )
              .map((failure) => failure.relativePath)
              .toList(),
          [
            _templatePath,
            'lib/main.dart',
            'pubspec.lock',
            'pubspec.yaml',
            'rogue.txt',
          ],
        );
        for (final failure in run.failures) {
          expect(failure.stage, 'baseline-generation');
          expect(failure.detailCode, 'unexpected-stage-write');
        }
        expect(
          run.failures.where(
            (failure) => failure.relativePath == 'lib/generated',
          ),
          isEmpty,
          reason:
              'Required parent directories are structural allowlist entries.',
        );
      },
    );

    test('rejects a nonregular entity at an allowed output path', () async {
      final fixture = await _createBoundFixture(
        generationResponder: (call) {
          Directory(
            p.joinAll([call.workingDirectory, ..._outputPath.split('/')]),
          ).createSync(recursive: true);
          return _result();
        },
      );

      final run = await const ProcessL10nGenerator().generate(
        stage: fixture.pair.baseline,
        toolchain: fixture.toolchain,
        phase: L10nGenerationPhase.baseline,
        outputPaths: const {_outputPath},
      );

      expect(
        run.after.entries[_outputPath]!.kind,
        L10nStageEntryKind.directory,
      );
      _expectFailure(
        run.failures,
        L10nEvidenceRejectionCode.unexpectedStageWrite,
        'unexpected-stage-write',
        stage: 'baseline-generation',
        relativePath: _outputPath,
      );
    });

    test(
      'does not scan a root made unsafe by the bound post-run check',
      () async {
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            _chmod(p.join(call.workingDirectory, _outputPath), 0);
            return _result();
          },
        );
        final stage = fixture.pair.baseline;

        final run = await const ProcessL10nGenerator().generate(
          stage: stage,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );

        expect(run.processResult, isNull);
        expect(run.after.entries, isEmpty);
        expect(run.after.invalidPaths, ['.']);
        expect(stage.safeToDelete, isFalse);
        _expectFailure(
          run.failures,
          L10nEvidenceRejectionCode.baselineGenerationFailed,
          'generation-working-root-postcondition-failed',
          stage: 'baseline-generation',
        );
        expect(
          run.failures
              .map(
                (failure) =>
                    '${failure.code.name}|${failure.relativePath}|'
                    '${failure.detailCode}',
              )
              .toList(),
          [
            'baselineGenerationFailed|null|'
                'generation-working-root-postcondition-failed',
            'unexpectedStageWrite|.|unexpected-stage-write',
          ],
          reason: 'An unavailable capture is unknown, not mass deletion.',
        );
        expect(
          jsonEncode(run.toRedactedJson()),
          isNot(contains(stage.directory.path)),
        );
      },
    );

    test(
      'records monotonic timing, RSS, and only redacted process JSON',
      () async {
        const stdoutSecret = 'stdout-secret';
        const stderrSecret = 'stderr-secret';
        final fixture = await _createBoundFixture(
          generationResponder: (call) {
            _writeStageFile(call.workingDirectory, _outputPath, 'generated');
            return _result(
              stdout: stdoutSecret.codeUnits,
              stdoutOmittedBytes: 7,
              stderr: stderrSecret.codeUnits,
              stderrOmittedBytes: 11,
              resourceObservation: const ProcessTreeResourceObservation(
                status: ProcessResourceObservationStatus.measured,
                sampleCount: 4,
                sampledPeakRssBytes: 987654,
              ),
            );
          },
        );
        final clock = _SequenceClock([1000, 1125]);
        final generator = ProcessL10nGenerator.testing(
          monotonicMicros: clock.read,
          timeout: const Duration(seconds: 9),
          maxOutputBytesPerStream: 64,
        );

        final run = await generator.generate(
          stage: fixture.pair.baseline,
          toolchain: fixture.toolchain,
          phase: L10nGenerationPhase.baseline,
          outputPaths: const {_outputPath},
        );
        final json = run.toRedactedJson();
        final encoded = jsonEncode(json);
        final process = json['process']! as Map<String, Object?>;
        final stdout = process['stdout']! as Map<String, Object?>;
        final stderr = process['stderr']! as Map<String, Object?>;
        final resource =
            process['resourceObservation']! as Map<String, Object?>;

        expect(run.elapsedMicros, 125);
        expect(fixture.runner.calls.last.timeout, const Duration(seconds: 9));
        expect(fixture.runner.calls.last.maxOutputBytesPerStream, 64);
        expect(json['phase'], 'baseline');
        expect(json['beforeFingerprint'], run.before.fingerprint);
        expect(json['afterFingerprint'], run.after.fingerprint);
        expect(json['elapsedMicros'], 125);
        expect(json['commandIdentity'], run.commandIdentity);
        expect(process['exitCode'], 0);
        expect(process['timedOut'], isFalse);
        expect(stdout, {
          'sha256':
              'a832c091bbb10065239619510fe074f1bf6979102577ffb0dfe2be460ef3df05',
          'capturedBytes': 13,
          'omittedBytes': 7,
          'truncated': true,
        });
        expect(stderr, {
          'sha256':
              'c3d0194d34c7e914ba84db2e5c12561ee29a32d44a00e77f5887bdd1062a3561',
          'capturedBytes': 13,
          'omittedBytes': 11,
          'truncated': true,
        });
        expect(resource, {
          'status': 'measured',
          'sampleCount': 4,
          'sampledPeakRssBytes': 987654,
        });
        expect((json['failures']! as List<Object?>).single, {
          'code': 'generatorOutputTruncated',
          'stage': 'baseline-generation',
          'detailCode': 'generator-output-truncated',
        });
        expect(encoded, isNot(contains(stdoutSecret)));
        expect(encoded, isNot(contains(stderrSecret)));
        expect(encoded, isNot(contains(fixture.pair.baseline.directory.path)));
        expect(encoded, isNot(contains(fixture.project.path)));
        expect(json.keys.toSet(), {
          'phase',
          'beforeFingerprint',
          'afterFingerprint',
          'process',
          'failures',
          'elapsedMicros',
          'commandIdentity',
        });
      },
    );
  });

  test('generation evidence sorts failures by stable identity fields', () {
    final unavailable = L10nStageInventoryCapture.unavailable();
    final run = L10nGenerationRun(
      phase: L10nGenerationPhase.baseline,
      before: unavailable,
      after: unavailable,
      processResult: null,
      failures: const [
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.unexpectedStageWrite,
          stage: 'baseline-generation',
          detailCode: 'unexpected-stage-write',
          relativePath: 'z.dart',
        ),
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.baselineGenerationFailed,
          stage: 'baseline-generation',
          detailCode: 'z-detail',
          relativePath: 'z.dart',
        ),
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.baselineGenerationFailed,
          stage: 'baseline-generation',
          detailCode: 'null-path-detail',
        ),
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.baselineGenerationFailed,
          stage: 'baseline-generation',
          detailCode: 'a-detail',
          relativePath: 'a.dart',
        ),
      ],
      elapsedMicros: 0,
      commandIdentity: _identity,
    );

    expect(
      run.failures
          .map(
            (failure) =>
                '${failure.code.name}|${failure.stage}|'
                '${failure.relativePath}|${failure.detailCode}',
          )
          .toList(),
      [
        'baselineGenerationFailed|baseline-generation|null|null-path-detail',
        'baselineGenerationFailed|baseline-generation|a.dart|a-detail',
        'baselineGenerationFailed|baseline-generation|z.dart|z-detail',
        'unexpectedStageWrite|baseline-generation|z.dart|unexpected-stage-write',
      ],
    );
  });

  test(
    'real SDK opt-in honors raw yaml and confines writes to staged outputs',
    () async {
      if (!Platform.isMacOS) {
        markTestSkipped('Production process confinement is Darwin-only.');
        return;
      }
      final configured = Platform.environment['FLUTTER_PRUNER_L10N_TEST_SDK'];
      if (configured == null || configured.isEmpty) {
        markTestSkipped(
          'FLUTTER_PRUNER_L10N_TEST_SDK is not set for explicit opt-in.',
        );
        return;
      }

      await _runRealSdkFixture(configured);
    },
  );
}

const _internalFailure = L10nEvidenceFailure(
  code: L10nEvidenceRejectionCode.internalFailure,
  stage: 'test',
  detailCode: 'test',
);

typedef _GenerationResponder =
    FutureOr<ManagedProcessResult> Function(_RecordedProcessCall call);

final class _BoundFixture {
  _BoundFixture._({
    required this.scratch,
    required this.project,
    required this.canonicalFlutter,
    required this.runner,
    required this.toolchain,
    required this.snapshot,
    required this.materializer,
    required this.materialization,
  });

  final Directory scratch;
  final Directory project;
  final String canonicalFlutter;
  final _RecordingProcessRunner runner;
  final L10nToolchainResolved toolchain;
  final L10nFamilySnapshot snapshot;
  final DefaultL10nStageMaterializer materializer;
  final L10nStageMaterializationResult materialization;
  L10nStageCleanupResult? _cleanupResult;

  L10nStagePair get pair => materialization.pair!;

  static Future<_BoundFixture> create({
    required _GenerationResponder generationResponder,
    bool withSidecar = false,
  }) async {
    final scratch = Directory.systemTemp.createTempSync('l10n-generator-test-');
    final project = Directory(p.join(scratch.path, 'project'))..createSync();
    try {
      final canonicalFlutter = _createFlutterSdk(scratch);
      File(
        p.join(project.path, '.fvmrc'),
      ).writeAsStringSync('{"flutter":"$_frameworkVersion"}\n');
      final runner = _RecordingProcessRunner(
        canonicalSdkRoot: p.dirname(p.dirname(canonicalFlutter)),
        generationResponder: generationResponder,
      );
      final resolution =
          await DefaultL10nToolchainResolver.testing(
            processRunner: runner,
            processConfinement: const _TestProcessConfinementBackend(),
          ).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({
              Version.parse(_frameworkVersion): canonicalFlutter,
            }),
            selection: const ProjectSelectorSelection(),
          );
      if (resolution case L10nToolchainRejected(:final failure)) {
        throw StateError('Fixture toolchain rejected: ${failure.detailCode}');
      }
      final toolchain = resolution as L10nToolchainResolved;
      final snapshot = _snapshot(
        toolchainIdentity: toolchain.identitySha256,
        optionalUntranslatedPath: withSidecar
            ? 'build/untranslated.json'
            : null,
      );
      final materializer = DefaultL10nStageMaterializer(toolchain: toolchain);
      final materialization = await materializer.materialize(snapshot);
      if (!materialization.ready) {
        final details = materialization.failures
            .map((failure) => failure.detailCode)
            .join(',');
        await materializer.cleanup(materialization.cleanupLease);
        throw StateError('Fixture staging rejected: $details');
      }
      return _BoundFixture._(
        scratch: scratch,
        project: project,
        canonicalFlutter: canonicalFlutter,
        runner: runner,
        toolchain: toolchain,
        snapshot: snapshot,
        materializer: materializer,
        materialization: materialization,
      );
    } catch (_) {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<void> installCandidateArbs() async {
    final failures = await materializer.installCandidateArbs(
      pair.candidate,
      snapshot.mutationPlan.candidateArbBytes,
    );
    if (failures.isNotEmpty) {
      throw StateError(
        'Fixture candidate edit rejected: '
        '${failures.map((failure) => failure.detailCode).join(',')}',
      );
    }
  }

  Future<L10nStageRoot> stageFor(L10nGenerationPhase phase) async {
    if (phase == L10nGenerationPhase.baseline) return pair.baseline;
    await installCandidateArbs();
    return pair.candidate;
  }

  Future<L10nStageCleanupResult> cleanup() async {
    return _cleanupResult ??= await materializer.cleanup(
      materialization.cleanupLease,
    );
  }

  Future<void> dispose() async {
    if (!materialization.cleanupLease.consumed) await cleanup();
    for (final root in materialization.cleanupLease.createdRoots) {
      if (root.directory.existsSync()) {
        // Test-only residue removal happens after the product cleanup result is
        // captured; production never falls back to an unauthorised delete.
        root.directory.deleteSync(recursive: true);
      }
    }
    for (final sandboxRoot
        in runner.calls.map((call) => call.sandboxRoot).toSet()) {
      final sandbox = Directory(sandboxRoot);
      if (sandbox.existsSync()) {
        // Task 6 intentionally retains uncertain sandboxes. The test harness
        // removes them only after asserting that production retained them.
        sandbox.deleteSync(recursive: true);
      }
    }
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

Future<_BoundFixture> _createBoundFixture({
  required _GenerationResponder generationResponder,
  bool withSidecar = false,
}) async {
  final fixture = await _BoundFixture.create(
    generationResponder: generationResponder,
    withSidecar: withSidecar,
  );
  addTearDown(fixture.dispose);
  return fixture;
}

final class _RecordedProcessCall {
  _RecordedProcessCall({
    required this.executable,
    required List<String> arguments,
    required this.workingDirectory,
    required this.timeout,
    required this.maxOutputBytesPerStream,
    required Map<String, String> environmentOverrides,
    required this.includeParentEnvironment,
  }) : arguments = List<String>.unmodifiable(arguments),
       environmentOverrides = Map<String, String>.unmodifiable(
         environmentOverrides,
       );

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Duration timeout;
  final int maxOutputBytesPerStream;
  final Map<String, String> environmentOverrides;
  final bool includeParentEnvironment;

  String get sandboxRoot => p.dirname(environmentOverrides['HOME']!);
}

final class _RecordingProcessRunner implements L10nTestProcessRunner {
  _RecordingProcessRunner({
    required this.canonicalSdkRoot,
    required this.generationResponder,
  });

  final String canonicalSdkRoot;
  final _GenerationResponder generationResponder;
  final List<_RecordedProcessCall> calls = [];

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  }) async {
    final call = _RecordedProcessCall(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
      environmentOverrides: environmentOverrides,
      includeParentEnvironment: includeParentEnvironment,
    );
    calls.add(call);
    if (arguments.length >= 2 &&
        arguments[arguments.length - 2] == '--version' &&
        arguments.last == '--machine') {
      return _result(stdout: _machineBytes(canonicalSdkRoot));
    }
    return generationResponder(call);
  }
}

final class _TestProcessConfinementBackend
    implements L10nProcessConfinementBackend {
  const _TestProcessConfinementBackend();

  static const authority = L10nProcessConfinementAuthority(
    backendIdentity: 'test-confinement-v1',
    requestedExecutable: '/test/sandbox-exec',
    requestedExecutableType: FileSystemEntityType.file,
    canonicalExecutable: '/test/sandbox-exec',
    executableSha256:
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    executableByteLength: 1,
    executablePosixMode: 0x1ed,
    policyIdentity:
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
  );

  @override
  L10nProcessConfinementAuthority captureAuthority() => authority;

  @override
  L10nConfinedCommand confine({
    required L10nProcessConfinementAuthority expectedAuthority,
    required String sandboxRoot,
    required String? writableRoot,
    required String executable,
    required List<String> arguments,
  }) {
    if (!_sameConfinementAuthority(expectedAuthority, authority)) {
      throw const L10nProcessConfinementException(
        'host-confinement-authority-drift',
      );
    }
    final profile = writableRoot == null
        ? '(version 1)(allow default)(deny network*)'
              '(deny file-write*)'
              '(allow file-write* (subpath (param "SANDBOX_ROOT")))'
        : '(version 1)(allow default)(deny network*)'
              '(deny file-write*)'
              '(allow file-write* (subpath (param "SANDBOX_ROOT")))'
              '(allow file-write* (subpath (param "WRITE_ROOT")))';
    return L10nConfinedCommand(
      executable: authority.canonicalExecutable,
      arguments: [
        '-D',
        'SANDBOX_ROOT=$sandboxRoot',
        if (writableRoot != null) ...['-D', 'WRITE_ROOT=$writableRoot'],
        '-p',
        profile,
        executable,
        ...arguments,
      ],
    );
  }
}

bool _sameConfinementAuthority(
  L10nProcessConfinementAuthority left,
  L10nProcessConfinementAuthority right,
) =>
    left.backendIdentity == right.backendIdentity &&
    left.requestedExecutable == right.requestedExecutable &&
    left.requestedExecutableType == right.requestedExecutableType &&
    left.canonicalExecutable == right.canonicalExecutable &&
    left.executableSha256 == right.executableSha256 &&
    left.executableByteLength == right.executableByteLength &&
    left.executablePosixMode == right.executablePosixMode &&
    left.policyIdentity == right.policyIdentity;

final class _SequenceClock {
  _SequenceClock(List<int> values) : _values = List<int>.of(values);

  final List<int> _values;
  var _index = 0;

  int read() {
    if (_index >= _values.length) throw StateError('Clock exhausted.');
    return _values[_index++];
  }
}

ManagedProcessResult _result({
  int exitCode = 0,
  List<int> stdout = const [],
  int stdoutOmittedBytes = 0,
  List<int> stderr = const [],
  int stderrOmittedBytes = 0,
  bool timedOut = false,
  ProcessTreeResourceObservation resourceObservation =
      ProcessTreeResourceObservation.unsupported,
}) => ManagedProcessResult(
  exitCode: exitCode,
  stdout: BoundedProcessOutput(
    capturedPayload: stdout,
    omittedBytes: stdoutOmittedBytes,
  ),
  stderr: BoundedProcessOutput(
    capturedPayload: stderr,
    omittedBytes: stderrOmittedBytes,
  ),
  timedOut: timedOut,
  resourceObservation: resourceObservation,
);

List<int> _machineBytes(String canonicalSdkRoot) => utf8.encode(
  jsonEncode({
    'frameworkVersion': _frameworkVersion,
    'channel': 'stable',
    'repositoryUrl': 'https://github.com/flutter/flutter.git',
    'frameworkRevision': _frameworkRevision,
    'frameworkCommitDate': '2026-01-01 00:00:00 +0000',
    'engineRevision': _engineRevision,
    'engineCommitDate': '2026-01-01 00:00:00.000Z',
    'engineContentHash': _engineContentHash,
    'engineBuildDate': '2026-01-01 00:00:00.000',
    'dartSdkVersion': _dartVersion,
    'devToolsVersion': 'fixture-devtools',
    'flutterVersion': _frameworkVersion,
    'flutterRoot': canonicalSdkRoot,
  }),
);

String _createFlutterSdk(Directory scratch) {
  final sdk = Directory(p.join(scratch.path, 'sdk-$_frameworkVersion'))
    ..createSync();
  final pubCache = Directory(p.join(scratch.path, 'sdk-pub-cache'))
    ..createSync();
  final dependencyRoot = Directory(
    p.join(pubCache.path, 'hosted', 'pub.dev', 'fixture_dependency-1.0.0'),
  )..createSync(recursive: true);
  Directory(p.join(dependencyRoot.path, 'lib')).createSync();
  File(
    p.join(dependencyRoot.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: fixture_dependency\nversion: 1.0.0\n');

  final flutter = File(p.join(sdk.path, 'bin', 'flutter'));
  final bundledDart = File(
    p.join(sdk.path, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
  );
  for (final executable in [flutter, bundledDart]) {
    executable
      ..createSync(recursive: true)
      ..writeAsStringSync('toolchain fixture\n');
    _chmod(executable.path, 0x1ed);
  }
  File(p.join(sdk.path, 'bin/internal/engine.version'))
    ..createSync(recursive: true)
    ..writeAsStringSync('$_engineRevision\n');
  final controlContents = <String, String>{
    'bin/cache/flutter_tools.snapshot': 'fixture snapshot\n',
    'bin/cache/flutter_tools.stamp': '$_frameworkRevision:\n',
    'bin/cache/engine.stamp': '$_engineRevision\n',
    'bin/cache/engine.realm': '\n',
    'bin/cache/engine-dart-sdk.stamp': '$_engineRevision\n',
    'bin/cache/engine_stamp.stamp': _engineRevision,
    'bin/cache/dart-sdk/version': '$_dartVersion\n',
    'bin/cache/flutter.version.json':
        '{\n'
        '  "frameworkVersion": "$_frameworkVersion",\n'
        '  "channel": "stable",\n'
        '  "repositoryUrl": "https://github.com/flutter/flutter.git",\n'
        '  "frameworkRevision": "$_frameworkRevision",\n'
        '  "frameworkCommitDate": "2026-01-01 00:00:00 +0000",\n'
        '  "engineRevision": "$_engineRevision",\n'
        '  "engineCommitDate": "2026-01-01 00:00:00.000Z",\n'
        '  "engineContentHash": "$_engineContentHash",\n'
        '  "engineBuildDate": "2026-01-01 00:00:00.000",\n'
        '  "dartSdkVersion": "$_dartVersion",\n'
        '  "devToolsVersion": "fixture-devtools",\n'
        '  "flutterVersion": "$_frameworkVersion"\n'
        '}',
    'bin/cache/engine_stamp.json':
        '{"build_date":"2026-01-01T00:00:00.000000",'
        '"build_time_ms":1767225600000,'
        '"git_revision":"$_engineRevision",'
        '"git_revision_date":"2026-01-01T00:00:00+00:00",'
        '"content_hash":"$_engineContentHash"}',
  };
  for (final entry in controlContents.entries) {
    File(p.join(sdk.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
  Directory(
    p.join(sdk.path, 'packages', 'flutter_tools', 'lib'),
  ).createSync(recursive: true);
  File(
    p.join(sdk.path, 'packages', 'flutter_tools', 'pubspec.yaml'),
  ).writeAsStringSync('name: flutter_tools\nversion: 0.0.0\n');
  File(
    p.join(sdk.path, 'packages', 'flutter_tools', 'pubspec.lock'),
  ).writeAsStringSync('packages: {}\n');
  File(
      p.join(
        sdk.path,
        'packages',
        'flutter_tools',
        '.dart_tool',
        'package_config.json',
      ),
    )
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '{"configVersion":2,'
      '"packages":[{"name":"fixture_dependency",'
      '"rootUri":"${Uri.file(dependencyRoot.resolveSymbolicLinksSync())}",'
      '"packageUri":"lib/","languageVersion":"3.0"},'
      '{"name":"flutter_tools","rootUri":"../",'
      '"packageUri":"lib/","languageVersion":"3.0"}],'
      '"generator":"pub","generatorVersion":"$_dartVersion",'
      '"pubCache":"${Uri.file(pubCache.resolveSymbolicLinksSync())}"}\n',
    );

  final canonicalFlutter = flutter.resolveSymbolicLinksSync();
  _sdkGitFile(canonicalFlutter, 'refs/heads/stable')
    ..createSync(recursive: true)
    ..writeAsStringSync('$_frameworkRevision\n');
  _sdkGitFile(
    canonicalFlutter,
    'HEAD',
  ).writeAsStringSync('ref: refs/heads/stable\n');
  _sdkGitFile(
    canonicalFlutter,
    'config',
  ).writeAsStringSync('[core]\n\trepositoryformatversion = 0\n');
  return canonicalFlutter;
}

File _sdkGitFile(String canonicalFlutter, String relativePath) =>
    File(p.join(p.dirname(p.dirname(canonicalFlutter)), '.git', relativePath))
      ..createSync(recursive: true);

L10nFamilySnapshot _snapshot({
  required String toolchainIdentity,
  Map<String, List<int>>? sourceFiles,
  Set<String> expectedGeneratedPaths = const {_outputPath},
  String? optionalUntranslatedPath,
}) {
  final files = sourceFiles ?? _defaultSourceFiles;
  final templatePath = files.containsKey('lib/i18n/messages_en.arb')
      ? 'lib/i18n/messages_en.arb'
      : _templatePath;
  final localePaths =
      files.keys.where((path) => path.endsWith('.arb')).toList(growable: false)
        ..sort();
  final generatedPaths = expectedGeneratedPaths.toList(growable: false)..sort();
  final entries = <String, L10nSnapshotEntry>{
    'pubspec.yaml': _presentEntry(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      files['pubspec.yaml']!,
    ),
    'pubspec.lock': _presentEntry(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      files['pubspec.lock']!,
    ),
    'l10n.yaml': _presentEntry(
      'l10n.yaml',
      L10nSnapshotRole.l10nConfig,
      files['l10n.yaml']!,
    ),
    '.dart_tool/package_config.json': _presentEntry(
      '.dart_tool/package_config.json',
      L10nSnapshotRole.packageConfig,
      files['.dart_tool/package_config.json']!,
      posixMode: 0x180,
    ),
    '.dart_tool/package_graph.json': _absentEntry(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
    ),
    'analysis_options.yaml': _absentEntry(
      'analysis_options.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'dart_test.yaml': _absentEntry(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    for (final path in localePaths)
      path: _presentEntry(
        path,
        path == templatePath
            ? L10nSnapshotRole.arbTemplate
            : L10nSnapshotRole.arbLocale,
        files[path]!,
      ),
    'lib/main.dart': _presentEntry(
      'lib/main.dart',
      L10nSnapshotRole.analyzerSource,
      files['lib/main.dart']!,
    ),
    for (final path in generatedPaths)
      path: _absentEntry(
        path,
        path == generatedPaths.first
            ? L10nSnapshotRole.generatedBase
            : L10nSnapshotRole.generatedLanguage,
      ),
    if (optionalUntranslatedPath != null)
      optionalUntranslatedPath: _absentEntry(
        optionalUntranslatedPath,
        L10nSnapshotRole.untranslatedSidecar,
      ),
  };
  final mutationPlan = _mutationPlan(
    templatePath: templatePath,
    arbBytesByPath: {for (final path in localePaths) path: files[path]!},
  );
  return L10nFamilySnapshot(
    entries: entries,
    mutationPlan: mutationPlan,
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {'dead'},
    expectedGeneratedMemberKindsByKey: const {
      'dead': ArbGeneratedMemberKind.getter,
    },
    expectedGeneratedPaths: expectedGeneratedPaths,
    optionalUntranslatedPath: optionalUntranslatedPath,
    verificationClosure: L10nVerificationClosure(
      projectOwnedDartPaths: const {'lib/main.dart'},
      analyzerRootIdentity: _identity,
    ),
    analysisOptionsProjection: L10nAnalysisOptionsProjection(
      projectOwnedPaths: const {},
      externalAuthorities: const [],
      contextAuthorityIdentity: _identity,
    ),
    provenUnrelatedOutputSiblings: const {},
    familyFingerprint: _identity,
    selectionFingerprint: _identity,
    l10nAnalysisFingerprint: _identity,
    configurationIdentity: _identity,
    packageConfigProjectionIdentity: _identity,
    packageResolutionIdentity: _identity,
    toolchainIdentity: toolchainIdentity,
    projectSemantics: L10nProjectSemantics(
      pubspec: const {'name': 'fixture'},
      packageName: 'fixture',
      analysisMode: AnalysisMode.application,
      targetMatrix: TargetMatrix.declared([
        BuildTarget(
          name: 'app',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ]),
      rootCoverage: RootCoverage.applicationApi(),
    ),
  );
}

final _defaultSourceFiles = <String, List<int>>{
  'pubspec.yaml': 'name: fixture\n'.codeUnits,
  'pubspec.lock': 'packages: {}\n'.codeUnits,
  'l10n.yaml':
      'arb-dir: lib/l10n\n'
              'template-arb-file: app_en.arb\n'
              'output-dir: lib/generated\n'
              'output-localization-file: app.dart\n'
          .codeUnits,
  '.dart_tool/package_config.json':
      '{"configVersion":2,"packages":[]}\n'.codeUnits,
  _templatePath: '{"dead":"Dead"}\n'.codeUnits,
  'lib/main.dart': 'void main() {}\n'.codeUnits,
};

L10nSnapshotEntry _presentEntry(
  String path,
  L10nSnapshotRole role,
  List<int> source, {
  int posixMode = 0x1a4,
}) {
  final bytes = ImmutableBytes.copyOf(source);
  return L10nSnapshotEntry(
    relativePosixPath: path,
    role: role,
    state: L10nSnapshotPresent(
      sourceBytes: bytes,
      stageBytes: bytes,
      sourceSha256: bytes.sha256Hex,
      posixMode: Platform.isWindows ? null : posixMode,
    ),
  );
}

L10nSnapshotEntry _absentEntry(String path, L10nSnapshotRole role) =>
    L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: const L10nSnapshotAbsent(),
    );

L10nArbMutationPlan _mutationPlan({
  required String templatePath,
  required Map<String, List<int>> arbBytesByPath,
}) {
  final documents = <String, ArbDocument>{};
  for (final entry in arbBytesByPath.entries) {
    final parsed = ArbDocument.parse(entry.value);
    if (parsed is! ArbParseSuccess) {
      throw StateError('Invalid fixture ARB: ${entry.key}');
    }
    documents[entry.key] = parsed.document;
  }
  final result = L10nArbMutationPlanner.plan(
    templatePath: templatePath,
    documentsByPath: documents,
    selectedKeys: const ['dead'],
  );
  if (result is! L10nArbMutationPlanReady) {
    throw StateError('Invalid fixture mutation plan.');
  }
  return result.plan;
}

L10nToolchainResolved _copyToolchain(
  L10nToolchainResolved source, {
  required String identitySha256,
}) => L10nToolchainResolved(
  canonicalFlutterExecutable: source.canonicalFlutterExecutable,
  canonicalSdkRoot: source.canonicalSdkRoot,
  launch: source.launch,
  selection: source.selection,
  generationArgs: source.generationArgs,
  directProbeArgs: source.directProbeArgs,
  environmentOverrides: source.environmentOverrides,
  selectorHashesByRelativePath: source.selectorHashesByRelativePath,
  machineIdentity: source.machineIdentity,
  originalSelectionProbeSha256: source.originalSelectionProbeSha256,
  identitySha256: identitySha256,
);

L10nEvidenceRejectionCode _phaseFailureCode(L10nGenerationPhase phase) =>
    switch (phase) {
      L10nGenerationPhase.baseline =>
        L10nEvidenceRejectionCode.baselineGenerationFailed,
      L10nGenerationPhase.candidate =>
        L10nEvidenceRejectionCode.candidateGenerationFailed,
    };

void _expectFailure(
  List<L10nEvidenceFailure> failures,
  L10nEvidenceRejectionCode code,
  String detailCode, {
  required String stage,
  String? relativePath,
}) {
  expect(
    failures,
    contains(
      isA<L10nEvidenceFailure>()
          .having((failure) => failure.code, 'code', code)
          .having((failure) => failure.stage, 'stage', stage)
          .having((failure) => failure.detailCode, 'detailCode', detailCode)
          .having(
            (failure) => failure.relativePath,
            'relativePath',
            relativePath,
          ),
    ),
  );
}

void _writeStageFile(String root, String relativePath, String contents) {
  final file = File(p.joinAll([root, ...relativePath.split('/')]));
  file.parent.createSync(recursive: true);
  if (!Platform.isWindows) {
    var current = file.parent;
    final canonicalRoot = Directory(root).resolveSymbolicLinksSync();
    while (p.isWithin(canonicalRoot, current.path)) {
      _chmod(current.path, 0x1c0);
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
  }
  file.writeAsStringSync(contents);
  if (!Platform.isWindows) _chmod(file.path, 0x1a4);
}

void _chmod(String path, int mode) {
  final result = Process.runSync(
    '/bin/chmod',
    [mode.toRadixString(8).padLeft(4, '0'), path],
    environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    includeParentEnvironment: false,
  );
  if (result.exitCode != 0) {
    throw StateError('Could not set fixture mode.');
  }
}

Future<void> _runRealSdkFixture(String configured) async {
  final requested = File(p.normalize(File(configured).absolute.path));
  if (!p.isAbsolute(configured) ||
      configured != p.normalize(configured) ||
      FileSystemEntity.typeSync(requested.path, followLinks: false) !=
          FileSystemEntityType.file) {
    fail(
      'FLUTTER_PRUNER_L10N_TEST_SDK must name an absolute canonical regular '
      'Flutter executable.',
    );
  }
  final canonicalFlutter = requested.resolveSymbolicLinksSync();
  if (canonicalFlutter != configured || requested.statSync().mode & 0x49 == 0) {
    fail(
      'FLUTTER_PRUNER_L10N_TEST_SDK must name an executable canonical binary.',
    );
  }
  final sdkRoot = p.dirname(p.dirname(canonicalFlutter));
  final versionControl =
      jsonDecode(
            File(
              p.join(sdkRoot, 'bin', 'cache', 'flutter.version.json'),
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  final versionText = versionControl['frameworkVersion'];
  if (versionText is! String ||
      !const {'3.38.7', '3.41.5', '3.44.1', '3.44.9'}.contains(versionText)) {
    fail('The opt-in SDK must be one exact Stage 1 supported version.');
  }
  final version = Version.parse(versionText);
  final scratch = Directory.systemTemp.createTempSync('l10n-generator-real-');
  final project = Directory(p.join(scratch.path, 'project'))..createSync();
  L10nStageMaterializationResult? materialization;
  DefaultL10nStageMaterializer? materializer;
  try {
    _copyFixtureTree(
      Directory(
        p.join(
          Directory.current.path,
          'test',
          'fixtures',
          'l10n_action_readiness',
          'process',
          'real_project',
        ),
      ),
      project,
    );
    File(
      p.join(project.path, '.fvmrc'),
    ).writeAsStringSync('{"flutter":"$versionText"}\n');
    final packageConfig =
        File(p.join(project.path, '.dart_tool', 'package_config.json'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            '{"configVersion":2,"packages":['
            '{"name":"fixture","rootUri":"../",'
            '"packageUri":"lib/","languageVersion":"3.0"}],'
            '"generator":"flutter_pruner_fixture"}\n',
          );
    final originalFingerprint = _regularTreeFingerprint(project);
    final resolution = await const DefaultL10nToolchainResolver().resolve(
      originalProjectRoot: project,
      sdkRegistry: L10nSdkRegistry({version: canonicalFlutter}),
      selection: const ProjectSelectorSelection(),
    );
    if (resolution case L10nToolchainRejected(:final failure)) {
      fail('Opt-in SDK rejected: ${failure.detailCode}');
    }
    final toolchain = resolution as L10nToolchainResolved;
    final expectedOutputs = <String>{
      'lib/generated/strings.dart',
      'lib/generated/strings_en.dart',
      'lib/generated/strings_fr.dart',
    };
    final sourceFiles = <String, List<int>>{
      for (final path in const [
        'pubspec.yaml',
        'pubspec.lock',
        'l10n.yaml',
        '.dart_tool/package_config.json',
        'lib/i18n/messages_en.arb',
        'lib/i18n/messages_fr.arb',
        'lib/main.dart',
      ])
        path: File(
          p.joinAll([project.path, ...path.split('/')]),
        ).readAsBytesSync(),
    };
    final snapshot = _snapshot(
      toolchainIdentity: toolchain.identitySha256,
      sourceFiles: sourceFiles,
      expectedGeneratedPaths: expectedOutputs,
    );
    materializer = DefaultL10nStageMaterializer(toolchain: toolchain);
    materialization = await materializer.materialize(snapshot);
    if (!materialization.ready) {
      fail(
        'Opt-in stage rejected: '
        '${materialization.failures.map((failure) => failure.detailCode).join(',')}',
      );
    }
    final stage = materialization.pair!.baseline;
    final stagedLock = File(p.join(stage.directory.path, 'pubspec.lock'));
    final stagedPackageConfig = File(
      p.join(stage.directory.path, '.dart_tool', 'package_config.json'),
    );
    final lockHash = sha256.convert(stagedLock.readAsBytesSync()).toString();
    final packageConfigHash = sha256
        .convert(stagedPackageConfig.readAsBytesSync())
        .toString();

    final run = await const ProcessL10nGenerator().generate(
      stage: stage,
      toolchain: toolchain,
      phase: L10nGenerationPhase.baseline,
      outputPaths: expectedOutputs,
    );

    expect(
      run.processResult!.exitCode,
      0,
      reason: utf8.decode(
        run.processResult!.stderr.capturedPayload,
        allowMalformed: true,
      ),
    );
    expect(run.failures, isEmpty);
    for (final path in expectedOutputs) {
      expect(run.after.entries[path]!.kind, L10nStageEntryKind.regularFile);
      expect(run.after.entries[path]!.capturedBytes, isNotNull);
    }
    final baseOutput = File(
      p.join(stage.directory.path, 'lib', 'generated', 'strings.dart'),
    );
    expect(baseOutput.readAsStringSync(), contains('class Strings'));
    expect(
      File(
        p.join(
          stage.directory.path,
          'lib',
          'generated',
          'app_localizations.dart',
        ),
      ).existsSync(),
      isFalse,
    );
    expect(_changedPaths(run.before, run.after), {
      'lib/generated',
      ...expectedOutputs,
    });
    expect(sha256.convert(stagedLock.readAsBytesSync()).toString(), lockHash);
    expect(
      sha256.convert(stagedPackageConfig.readAsBytesSync()).toString(),
      packageConfigHash,
    );
    expect(_regularTreeFingerprint(project), originalFingerprint);
    expect(packageConfig.existsSync(), isTrue);

    final cleanup = await materializer.cleanup(materialization.cleanupLease);
    expect(cleanup.failures, isEmpty);
    expect(cleanup.baselineRemoved, isTrue);
    expect(cleanup.candidateRemoved, isTrue);
  } finally {
    if (materialization != null &&
        materializer != null &&
        !materialization.cleanupLease.consumed) {
      await materializer.cleanup(materialization.cleanupLease);
    }
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

void _copyFixtureTree(Directory source, Directory destination) {
  if (!source.existsSync()) throw StateError('Real generator fixture missing.');
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(target).createSync(recursive: true);
    } else if (type == FileSystemEntityType.file) {
      File(target)
        ..createSync(recursive: true)
        ..writeAsBytesSync(File(entity.path).readAsBytesSync());
    } else {
      throw StateError('Unsupported real fixture entity.');
    }
  }
}

String _regularTreeFingerprint(Directory root) {
  final files =
      root
          .listSync(recursive: true, followLinks: false)
          .where(
            (entity) =>
                FileSystemEntity.typeSync(entity.path, followLinks: false) ==
                FileSystemEntityType.file,
          )
          .toList(growable: false)
        ..sort((left, right) => left.path.compareTo(right.path));
  final bytes = <int>[];
  for (final file in files) {
    final relative = p
        .relative(file.path, from: root.path)
        .split(p.separator)
        .join('/');
    final payload = File(file.path).readAsBytesSync();
    bytes
      ..addAll(utf8.encode('${relative.length}:$relative'))
      ..add(0)
      ..addAll(utf8.encode('${payload.length}:'))
      ..addAll(payload)
      ..add(0);
  }
  return sha256.convert(bytes).toString();
}

Set<String> _changedPaths(
  L10nStageInventoryCapture before,
  L10nStageInventoryCapture after,
) {
  final paths = <String>{...before.entries.keys, ...after.entries.keys};
  return {
    for (final path in paths)
      if (!_sameEntry(before.entries[path], after.entries[path])) path,
  };
}

bool _sameEntry(L10nStageEntry? left, L10nStageEntry? right) =>
    left != null &&
    right != null &&
    left.relativePath == right.relativePath &&
    left.kind == right.kind &&
    left.sha256 == right.sha256 &&
    left.posixMode == right.posixMode;
