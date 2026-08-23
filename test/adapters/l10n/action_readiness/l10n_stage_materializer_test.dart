import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  group('DefaultL10nStageMaterializer', () {
    late Directory scratch;
    late Directory projectRoot;
    late int allocatedRoots;

    setUp(() {
      scratch = Directory.systemTemp.createTempSync('l10n-materializer-test-');
      projectRoot = Directory(p.join(scratch.path, 'project'))..createSync();
      allocatedRoots = 0;
    });

    tearDown(() {
      if (scratch.existsSync()) {
        scratch.deleteSync(recursive: true);
      }
    });

    DefaultL10nStageMaterializer materializer({
      L10nStageDirectoryAllocator? allocator,
      L10nStageOperationHook? hook,
      Directory? systemTempRoot,
    }) {
      return DefaultL10nStageMaterializer.testing(
        expectedToolchainIdentity: _identity,
        canonicalSystemTempRoot:
            systemTempRoot ??
            Directory(Directory.systemTemp.resolveSymbolicLinksSync()),
        canonicalOriginalProjectRoot: projectRoot.resolveSymbolicLinksSync(),
        rootAllocator:
            allocator ??
            () async {
              allocatedRoots++;
              return Directory(p.join(scratch.path, 'stage-$allocatedRoots'))
                ..createSync();
            },
        operationHook: hook,
      );
    }

    test(
      'copies only frozen stage bytes with exact paths, modes, and absence',
      () async {
        final snapshot = _snapshot();
        final stage = materializer();
        final result = await stage.materialize(snapshot);

        expect(result.ready, isTrue);
        expect(result.failures, isEmpty);
        expect(result.cleanupLease.createdRoots, hasLength(2));
        expect(
          () => result.cleanupLease.createdRoots.clear(),
          throwsUnsupportedError,
        );
        expect(
          () => result.failures.add(
            const L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.internalFailure,
              stage: 'test',
              detailCode: 'test',
            ),
          ),
          throwsUnsupportedError,
        );
        final pair = result.pair!;
        expect(
          pair.baseline.directory.resolveSymbolicLinksSync(),
          isNot(pair.candidate.directory.resolveSymbolicLinksSync()),
        );
        expect(
          p.isWithin(projectRoot.path, pair.baseline.directory.path),
          isFalse,
        );
        expect(
          p.isWithin(projectRoot.path, pair.candidate.directory.path),
          isFalse,
        );
        final canonicalSystemTemp = Directory.systemTemp
            .resolveSymbolicLinksSync();
        expect(
          p.isWithin(canonicalSystemTemp, pair.baseline.directory.path),
          isTrue,
        );
        expect(
          p.isWithin(canonicalSystemTemp, pair.candidate.directory.path),
          isTrue,
        );
        expect(pair.baseline.identity, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(pair.candidate.identity, matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(pair.baseline.identity, isNot(pair.candidate.identity));
        expect(pair.copiedBytes, _presentStageByteCount(snapshot) * 2);
        expect(pair.baseline.publishablePaths, {
          'lib/l10n/app_en.arb',
          'lib/generated/app.dart',
        });
        expect(pair.candidate.publishablePaths, pair.baseline.publishablePaths);
        expect(
          () => pair.baseline.publishablePaths.add('later'),
          throwsUnsupportedError,
        );

        for (final root in [pair.baseline, pair.candidate]) {
          for (final entry in snapshot.entries.values) {
            final staged = File(
              p.joinAll([
                root.directory.path,
                ...entry.relativePosixPath.split('/'),
              ]),
            );
            switch (entry.state) {
              case L10nSnapshotAbsent():
                expect(
                  FileSystemEntity.typeSync(staged.path, followLinks: false),
                  FileSystemEntityType.notFound,
                  reason: entry.relativePosixPath,
                );
              case L10nSnapshotPresent(:final stageBytes, :final posixMode):
                expect(staged.readAsBytesSync(), stageBytes.copy());
                if (!Platform.isWindows && posixMode != null) {
                  expect(staged.statSync().mode & 0xfff, posixMode);
                }
            }
          }
          expect(
            _relativeRegularFiles(root.directory),
            snapshot.entries.values
                .where((entry) => entry.state is L10nSnapshotPresent)
                .map((entry) => entry.relativePosixPath)
                .toSet(),
          );
          expect(
            _relativeDirectories(root.directory),
            _expectedParentDirectories(snapshot),
          );
        }
        expect(
          File(
            p.join(
              pair.baseline.directory.path,
              '.dart_tool/package_config.json',
            ),
          ).readAsBytesSync(),
          [3],
          reason: 'materialization must use stageBytes, never sourceBytes',
        );

        final cleanup = await stage.cleanup(result.cleanupLease);
        expect(cleanup.failures, isEmpty);
        expect(() => cleanup.failures.clear(), throwsUnsupportedError);
        expect(cleanup.baselineRemoved, isTrue);
        expect(cleanup.candidateRemoved, isTrue);
      },
    );

    test('keeps the production toolchain lease capability in the API', () {
      DefaultL10nStageMaterializer productionFactory(
        L10nToolchainResolved toolchain,
      ) => DefaultL10nStageMaterializer(toolchain: toolchain);
      L10nGenerationWorkingRoot seal(L10nStageRoot root) =>
          root.sealForGeneration();

      expect(productionFactory, isA<Function>());
      expect(seal, isA<Function>());
    });

    test(
      'production never falls back when the bound lease is unavailable',
      () async {
        final stage = DefaultL10nStageMaterializer(
          toolchain: _unboundToolchain(),
        );

        final result = await stage.materialize(_snapshot());

        expect(result.pair, isNull);
        expect(result.cleanupLease.createdRoots, isEmpty);
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.materializationFailed,
          'stage-root-create-failed',
        );
      },
    );

    test(
      'seal revalidates the complete root and requires the candidate edit',
      () async {
        final stage = materializer();
        final snapshot = _snapshot();
        final result = await stage.materialize(snapshot);
        final pair = result.pair!;

        expect(
          pair.candidate.sealForGeneration,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'candidate-arbs-not-installed',
            ),
          ),
        );

        File(
          p.join(pair.baseline.directory.path, 'lib/main.dart'),
        ).writeAsStringSync('void tampered() {}\n');
        expect(
          pair.baseline.sealForGeneration,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'stage-root-verification-failed',
            ),
          ),
        );

        expect(
          await stage.installCandidateArbs(
            pair.candidate,
            snapshot.mutationPlan.candidateArbBytes,
          ),
          isEmpty,
        );
        expect(
          pair.candidate.sealForGeneration,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'testing-stage-root-has-no-generation-capability',
            ),
          ),
        );
        await stage.cleanup(result.cleanupLease);
      },
    );

    test('rejects a snapshot bound to another toolchain identity', () async {
      final stage = materializer();

      final result = await stage.materialize(
        _snapshot(
          toolchainIdentity:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      );

      expect(result.pair, isNull);
      expect(result.cleanupLease.createdRoots, isEmpty);
      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.toolchainDrift,
        'stage-toolchain-identity-mismatch',
      );
    });

    test('baseline and candidate never share file inodes', () async {
      final stage = materializer();
      final result = await stage.materialize(_snapshot());
      final pair = result.pair!;
      final relativePath = 'lib/l10n/app_en.arb';
      final baseline = File(p.join(pair.baseline.directory.path, relativePath));
      final candidate = File(
        p.join(pair.candidate.directory.path, relativePath),
      );

      candidate.writeAsStringSync('{"candidate":true}');
      expect(baseline.readAsStringSync(), '{"dead":"Dead"}');
      if (!Platform.isWindows) {
        expect(_inode(baseline.path), isNot(_inode(candidate.path)));
      }

      await stage.cleanup(result.cleanupLease);
    });

    test(
      'publishes but does not synthesize an absent optional sidecar',
      () async {
        final stage = materializer();
        final result = await stage.materialize(_snapshot(withSidecar: true));
        final pair = result.pair!;

        expect(
          pair.baseline.publishablePaths,
          contains('build/untranslated.json'),
        );
        for (final root in [pair.baseline, pair.candidate]) {
          expect(
            FileSystemEntity.typeSync(
              p.join(root.directory.path, 'build/untranslated.json'),
              followLinks: false,
            ),
            FileSystemEntityType.notFound,
          );
        }
        await stage.cleanup(result.cleanupLease);
      },
    );

    test(
      'installs the complete exact ARB replacement set only in candidate',
      () async {
        final stage = materializer();
        final snapshot = _snapshot();
        final result = await stage.materialize(snapshot);
        final pair = result.pair!;
        final arbPath = 'lib/l10n/app_en.arb';
        final before = File(p.join(pair.baseline.directory.path, arbPath));
        final candidate = File(p.join(pair.candidate.directory.path, arbPath));
        final replacements = snapshot.mutationPlan.candidateArbBytes;
        final candidateMode = candidate.statSync().mode & 0xfff;
        final nonArbBefore = <String, ({List<int> bytes, int? mode})>{};
        for (final entry in snapshot.entries.values) {
          if (entry.state is! L10nSnapshotPresent ||
              entry.role == L10nSnapshotRole.arbTemplate ||
              entry.role == L10nSnapshotRole.arbLocale) {
            continue;
          }
          final file = File(
            p.joinAll([
              pair.candidate.directory.path,
              ...entry.relativePosixPath.split('/'),
            ]),
          );
          nonArbBefore[entry.relativePosixPath] = (
            bytes: file.readAsBytesSync(),
            mode: Platform.isWindows ? null : file.statSync().mode & 0xfff,
          );
        }

        expect(
          await stage.installCandidateArbs(pair.candidate, replacements),
          isEmpty,
        );
        expect(before.readAsStringSync(), '{"dead":"Dead"}');
        expect(candidate.readAsBytesSync(), replacements[arbPath]!.copy());
        if (!Platform.isWindows) {
          expect(candidate.statSync().mode & 0xfff, candidateMode);
        }
        for (final entry in nonArbBefore.entries) {
          final file = File(
            p.joinAll([pair.candidate.directory.path, ...entry.key.split('/')]),
          );
          expect(file.readAsBytesSync(), entry.value.bytes, reason: entry.key);
          if (!Platform.isWindows) {
            expect(
              file.statSync().mode & 0xfff,
              entry.value.mode,
              reason: entry.key,
            );
          }
        }

        final second = await stage.installCandidateArbs(
          pair.candidate,
          replacements,
        );
        _expectFailure(
          second,
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'candidate-arbs-already-installed',
        );
        await stage.cleanup(result.cleanupLease);
      },
    );

    test(
      'a partial multi-ARB install consumes candidate edit authority',
      () async {
        var candidateWrites = 0;
        final stage = materializer(
          hook: (operation, root, relativePath) async {
            if (operation == L10nStageOperation.beforeCandidateArbWrite &&
                ++candidateWrites == 2) {
              throw const FileSystemException(
                'injected second candidate write failure',
              );
            }
          },
        );
        final snapshot = _snapshot(withSecondArb: true);
        final result = await stage.materialize(snapshot);
        final pair = result.pair!;
        final replacements = snapshot.mutationPlan.candidateArbBytes;
        final first = File(
          p.join(pair.candidate.directory.path, 'lib/l10n/app_en.arb'),
        );
        final second = File(
          p.join(pair.candidate.directory.path, 'lib/l10n/app_fr.arb'),
        );
        final secondBefore = second.readAsBytesSync();

        final failures = await stage.installCandidateArbs(
          pair.candidate,
          replacements,
        );

        _expectFailure(
          failures,
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'candidate-arb-installation-failed',
        );
        expect(
          first.readAsBytesSync(),
          replacements['lib/l10n/app_en.arb']!.copy(),
        );
        expect(second.readAsBytesSync(), secondBefore);
        _expectFailure(
          await stage.installCandidateArbs(pair.candidate, replacements),
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'candidate-arbs-already-installed',
        );
        expect(
          pair.candidate.sealForGeneration,
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'candidate-arbs-not-installed',
            ),
          ),
        );

        final cleanup = await stage.cleanup(result.cleanupLease);
        expect(cleanup.failures, isEmpty);
        expect(cleanup.baselineRemoved, isTrue);
        expect(cleanup.candidateRemoved, isTrue);
      },
    );

    test('revalidates candidate paths after the pre-write hook', () async {
      if (Platform.isWindows) return;
      final outside = Directory(p.join(scratch.path, 'candidate-outside'))
        ..createSync();
      final outsideArb = File(p.join(outside.path, 'app_en.arb'))
        ..writeAsStringSync('outside-authority');
      final outsideSentinel = File(p.join(outside.path, 'sentinel.txt'))
        ..writeAsStringSync('sentinel');
      var swapped = false;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (swapped ||
              operation != L10nStageOperation.beforeCandidateArbWrite) {
            return;
          }
          swapped = true;
          final l10n = Directory(p.join(root.path, 'lib/l10n'));
          l10n.renameSync(p.join(scratch.path, 'displaced-l10n'));
          Link(l10n.path).createSync(outside.path);
        },
      );
      final snapshot = _snapshot();
      final result = await stage.materialize(snapshot);
      final pair = result.pair!;

      final failures = await stage.installCandidateArbs(
        pair.candidate,
        snapshot.mutationPlan.candidateArbBytes,
      );

      _expectFailure(
        failures,
        L10nEvidenceRejectionCode.editPostconditionFailed,
        'candidate-arb-installation-failed',
      );
      expect(outsideArb.readAsStringSync(), 'outside-authority');
      expect(outsideSentinel.readAsStringSync(), 'sentinel');
      expect(pair.candidate.safeToDelete, isFalse);
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'candidate-root-unsafe-to-delete',
      );
    });

    test('rejects a candidate hard-link swap before writing', () async {
      if (Platform.isWindows) return;
      final outsideArb = File(p.join(scratch.path, 'outside-hardlink.arb'))
        ..writeAsStringSync('{"dead":"Dead"}');
      final chmod = Process.runSync('/bin/chmod', ['0644', outsideArb.path]);
      expect(chmod.exitCode, 0, reason: '${chmod.stderr}');
      var swapped = false;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (swapped ||
              operation != L10nStageOperation.beforeCandidateArbWrite) {
            return;
          }
          swapped = true;
          final candidateArb = File(
            p.joinAll([root.path, ...relativePath!.split('/')]),
          )..deleteSync();
          final link = Process.runSync('/bin/ln', [
            outsideArb.path,
            candidateArb.path,
          ]);
          expect(link.exitCode, 0, reason: '${link.stderr}');
        },
      );
      final snapshot = _snapshot();
      final result = await stage.materialize(snapshot);
      final pair = result.pair!;

      final failures = await stage.installCandidateArbs(
        pair.candidate,
        snapshot.mutationPlan.candidateArbBytes,
      );

      _expectFailure(
        failures,
        L10nEvidenceRejectionCode.editPostconditionFailed,
        'candidate-arb-installation-failed',
      );
      expect(outsideArb.readAsStringSync(), '{"dead":"Dead"}');
      expect(pair.candidate.safeToDelete, isFalse);
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'candidate-root-unsafe-to-delete',
      );
    });

    test('never edits a candidate already marked unsafe', () async {
      final stage = materializer();
      final snapshot = _snapshot();
      final result = await stage.materialize(snapshot);
      final pair = result.pair!;
      final candidateArb = File(
        p.join(pair.candidate.directory.path, 'lib/l10n/app_en.arb'),
      );
      final before = candidateArb.readAsBytesSync();
      pair.candidate.markUnsafeToDelete();

      final failures = await stage.installCandidateArbs(
        pair.candidate,
        snapshot.mutationPlan.candidateArbBytes,
      );

      _expectFailure(
        failures,
        L10nEvidenceRejectionCode.editPostconditionFailed,
        'candidate-root-invalid',
      );
      expect(candidateArb.readAsBytesSync(), before);
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'candidate-root-unsafe-to-delete',
      );
    });

    test('rechecks candidate safety after the pre-write hook', () async {
      late L10nStageRoot candidate;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (operation == L10nStageOperation.beforeCandidateArbWrite) {
            candidate.markUnsafeToDelete();
          }
        },
      );
      final snapshot = _snapshot();
      final result = await stage.materialize(snapshot);
      candidate = result.pair!.candidate;
      final candidateArb = File(
        p.join(candidate.directory.path, 'lib/l10n/app_en.arb'),
      );
      final before = candidateArb.readAsBytesSync();

      final failures = await stage.installCandidateArbs(
        candidate,
        snapshot.mutationPlan.candidateArbBytes,
      );

      _expectFailure(
        failures,
        L10nEvidenceRejectionCode.editPostconditionFailed,
        'candidate-arb-installation-failed',
      );
      expect(candidateArb.readAsBytesSync(), before);
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'candidate-root-unsafe-to-delete',
      );
    });

    test(
      'rejects the exact ARB key with non-witnessed replacement bytes',
      () async {
        final stage = materializer();
        final result = await stage.materialize(_snapshot());
        final pair = result.pair!;
        final candidate = File(
          p.join(pair.candidate.directory.path, 'lib/l10n/app_en.arb'),
        );
        final before = candidate.readAsBytesSync();

        final failures = await stage.installCandidateArbs(pair.candidate, {
          'lib/l10n/app_en.arb': ImmutableBytes.copyOf(
            '{"tampered":true}'.codeUnits,
          ),
        });

        _expectFailure(
          failures,
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'candidate-arb-replacement-bytes-mismatch',
        );
        expect(candidate.readAsBytesSync(), before);
        await stage.cleanup(result.cleanupLease);
      },
    );

    test('rejects baseline and foreign candidate stage authorities', () async {
      final first = materializer();
      final second = materializer();
      final firstResult = await first.materialize(_snapshot());
      final secondResult = await second.materialize(_snapshot());
      final replacements = _snapshot().mutationPlan.candidateArbBytes;

      for (final root in [
        firstResult.pair!.baseline,
        secondResult.pair!.candidate,
      ]) {
        final failures = await first.installCandidateArbs(root, replacements);
        _expectFailure(
          failures,
          L10nEvidenceRejectionCode.editPostconditionFailed,
          'candidate-root-invalid',
        );
      }
      expect(
        File(
          p.join(
            firstResult.pair!.baseline.directory.path,
            'lib/l10n/app_en.arb',
          ),
        ).readAsStringSync(),
        '{"dead":"Dead"}',
      );
      await first.cleanup(firstResult.cleanupLease);
      await second.cleanup(secondResult.cleanupLease);
    });

    test(
      'rejects incomplete or broadened candidate ARB replacement sets',
      () async {
        for (final replacements in <Map<String, ImmutableBytes>>[
          const {},
          {
            'lib/l10n/app_en.arb': ImmutableBytes.copyOf('{}'.codeUnits),
            'lib/main.dart': ImmutableBytes.copyOf('changed'.codeUnits),
          },
          {'../escape.arb': ImmutableBytes.copyOf('{}'.codeUnits)},
        ]) {
          final stage = materializer();
          final result = await stage.materialize(_snapshot());
          final pair = result.pair!;
          final candidate = File(
            p.join(pair.candidate.directory.path, 'lib/l10n/app_en.arb'),
          );
          final before = candidate.readAsBytesSync();

          final failures = await stage.installCandidateArbs(
            pair.candidate,
            replacements,
          );

          _expectFailure(
            failures,
            L10nEvidenceRejectionCode.editPostconditionFailed,
            'candidate-arb-replacement-set-mismatch',
          );
          expect(candidate.readAsBytesSync(), before);
          await stage.cleanup(result.cleanupLease);
        }
      },
    );

    test(
      'rejects roots inside the project or outside declared system temp',
      () async {
        final declaredTemp = Directory(p.join(scratch.path, 'declared-temp'))
          ..createSync();
        final cases = <({Directory root, Directory systemTemp})>[
          (
            root: Directory(p.join(projectRoot.path, 'stage')),
            systemTemp: Directory(
              Directory.systemTemp.resolveSymbolicLinksSync(),
            ),
          ),
          (
            root: Directory(p.join(scratch.path, 'outside-declared-temp')),
            systemTemp: declaredTemp,
          ),
        ];
        for (final entry in cases) {
          final stage = materializer(
            systemTempRoot: entry.systemTemp,
            allocator: () async => entry.root..createSync(recursive: true),
          );

          final result = await stage.materialize(_snapshot());

          expect(result.pair, isNull);
          _expectFailure(
            result.failures,
            L10nEvidenceRejectionCode.materializationFailed,
            'stage-root-location-unsupported',
          );
          expect(entry.root.listSync(), isEmpty, reason: entry.root.path);
          final cleanup = await stage.cleanup(result.cleanupLease);
          expect(cleanup.baselineRemoved, isFalse);
          expect(entry.root.existsSync(), isTrue);
          _expectFailure(
            cleanup.failures,
            L10nEvidenceRejectionCode.cleanupFailed,
            'baseline-root-unsafe-to-delete',
          );
        }
      },
    );

    test('rejects identical or nested baseline and candidate roots', () async {
      for (final nested in [false, true]) {
        final shared = Directory(p.join(scratch.path, 'shared-$nested'))
          ..createSync();
        var calls = 0;
        final stage = materializer(
          allocator: () async {
            calls++;
            if (calls == 1 || !nested) return shared;
            return Directory(p.join(shared.path, 'candidate'))..createSync();
          },
        );

        final result = await stage.materialize(_snapshot());

        expect(result.pair, isNull, reason: 'nested=$nested');
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.materializationFailed,
          'stage-roots-not-independent',
        );
        await stage.cleanup(result.cleanupLease);
      }
    });

    test('returns a cleanup lease after partial root allocation', () async {
      final stage = materializer(
        allocator: () async {
          allocatedRoots++;
          if (allocatedRoots == 2) {
            throw const FileSystemException('injected allocation failure');
          }
          return Directory(p.join(scratch.path, 'partial-root'))..createSync();
        },
      );

      final result = await stage.materialize(_snapshot());

      expect(result.ready, isFalse);
      expect(result.pair, isNull);
      expect(result.cleanupLease.createdRoots, hasLength(1));
      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.materializationFailed,
        'stage-root-create-failed',
      );
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      expect(result.cleanupLease.consumed, isTrue);
    });

    test(
      'retains an unsafe cleanup handle after allocated-root validation fails',
      () async {
        final allocatedPath = File(p.join(scratch.path, 'allocated-as-file'))
          ..writeAsStringSync('not-a-directory');
        final stage = materializer(
          allocator: () async => Directory(allocatedPath.path),
        );

        final result = await stage.materialize(_snapshot());

        expect(result.pair, isNull);
        expect(result.cleanupLease.createdRoots, hasLength(1));
        expect(result.cleanupLease.createdRoots.single.safeToDelete, isFalse);
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.materializationFailed,
          'stage-root-create-failed',
        );
        final cleanup = await stage.cleanup(result.cleanupLease);
        expect(cleanup.baselineRemoved, isFalse);
        expect(allocatedPath.readAsStringSync(), 'not-a-directory');
        _expectFailure(
          cleanup.failures,
          L10nEvidenceRejectionCode.cleanupFailed,
          'baseline-root-unsafe-to-delete',
        );
      },
    );

    test(
      'cleans every registered root after a partial file write failure',
      () async {
        var writes = 0;
        final stage = materializer(
          hook: (operation, root, relativePath) async {
            if (operation == L10nStageOperation.beforeFileWrite &&
                ++writes == 3) {
              throw const FileSystemException('injected write failure');
            }
          },
        );

        final result = await stage.materialize(_snapshot());

        expect(result.pair, isNull);
        expect(result.cleanupLease.createdRoots, hasLength(2));
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.materializationFailed,
          'stage-file-write-failed',
        );
        final roots = result.cleanupLease.createdRoots
            .map((root) => root.directory.path)
            .toList();
        final cleanup = await stage.cleanup(result.cleanupLease);
        expect(cleanup.failures, isEmpty);
        expect(roots.every((path) => !Directory(path).existsSync()), isTrue);
      },
    );

    test(
      'rejects link parents, path escape, and ASCII-fold collisions',
      () async {
        final outside = Directory(p.join(scratch.path, 'outside'))
          ..createSync();
        final outsideSentinel = File(p.join(outside.path, 'sentinel.txt'))
          ..writeAsStringSync('outside-authority');
        final cases = <String, Future<void> Function(Directory)>{
          if (!Platform.isWindows)
            'stage-link-unsupported': (root) async {
              final target = Directory(p.join(root.path, 'safe-target'))
                ..createSync();
              Link(p.join(root.path, 'lib')).createSync(target.path);
            },
          if (!Platform.isWindows)
            'stage-path-escape': (root) async {
              Link(p.join(root.path, 'lib')).createSync(outside.path);
            },
          'stage-parent-not-directory': (root) async {
            File(p.join(root.path, 'lib')).writeAsStringSync('not a parent');
          },
          'stage-path-casefold-collision': (root) async {
            Directory(p.join(root.path, 'Lib')).createSync();
          },
        };
        for (final entry in cases.entries) {
          var injected = false;
          final stage = materializer(
            hook: (operation, root, relativePath) async {
              if (!injected &&
                  operation == L10nStageOperation.afterRootRegistered) {
                injected = true;
                await entry.value(root);
              }
            },
          );

          final result = await stage.materialize(_snapshot());

          expect(result.pair, isNull, reason: entry.key);
          _expectFailure(
            result.failures,
            L10nEvidenceRejectionCode.materializationFailed,
            entry.key,
          );
          expect(
            File(p.join(outside.path, 'l10n/app_en.arb')).existsSync(),
            isFalse,
          );
          final cleanup = await stage.cleanup(result.cleanupLease);
          expect(outsideSentinel.readAsStringSync(), 'outside-authority');
          if (entry.key == 'stage-link-unsupported' ||
              entry.key == 'stage-path-escape') {
            expect(cleanup.baselineRemoved, isFalse);
            _expectFailure(
              cleanup.failures,
              L10nEvidenceRejectionCode.cleanupFailed,
              'baseline-root-unsafe-to-delete',
            );
          }
        }
      },
    );

    test('normalizes known staged parent directories to mode 0700', () async {
      if (Platform.isWindows) return;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (operation != L10nStageOperation.afterRootRegistered) return;
          final lib = Directory(p.join(root.path, 'lib'))..createSync();
          final result = Process.runSync('/bin/chmod', ['0775', lib.path]);
          expect(result.exitCode, 0, reason: '${result.stderr}');
        },
      );

      final result = await stage.materialize(_snapshot());

      expect(result.ready, isTrue);
      for (final root in [result.pair!.baseline, result.pair!.candidate]) {
        expect(
          Directory(p.join(root.directory.path, 'lib')).statSync().mode & 0xfff,
          0x1c0,
        );
      }
      final cleanup = await stage.cleanup(result.cleanupLease);
      expect(cleanup.failures, isEmpty);
    });

    test('rejects group-writable stage modes before child writes', () async {
      if (Platform.isWindows) return;
      var writes = 0;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (operation == L10nStageOperation.beforeFileWrite) writes++;
        },
      );

      final result = await stage.materialize(_snapshot(arbMode: 0x1b4));

      expect(result.pair, isNull);
      expect(writes, 0);
      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.materializationFailed,
        'stage-file-mode-unsupported',
      );
      await stage.cleanup(result.cleanupLease);
    });

    test('rejects absent POSIX stage modes before allocation', () async {
      if (Platform.isWindows) return;
      var allocations = 0;
      final stage = materializer(
        allocator: () async {
          allocations++;
          return Directory(p.join(scratch.path, 'unexpected-allocation'))
            ..createSync();
        },
      );

      final result = await stage.materialize(_snapshot(withoutArbMode: true));

      expect(result.pair, isNull);
      expect(allocations, 0);
      expect(result.cleanupLease.createdRoots, isEmpty);
      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.materializationFailed,
        'stage-file-mode-unsupported',
      );
    });

    test('rejects unreadable POSIX stage modes before allocation', () async {
      if (Platform.isWindows) return;
      var allocations = 0;
      final stage = materializer(
        allocator: () async {
          allocations++;
          return Directory(p.join(scratch.path, 'unexpected-allocation'))
            ..createSync();
        },
      );

      final result = await stage.materialize(_snapshot(arbMode: 0x80));

      expect(result.pair, isNull);
      expect(allocations, 0);
      expect(result.cleanupLease.createdRoots, isEmpty);
      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.materializationFailed,
        'stage-file-mode-unsupported',
      );
    });

    test('cleanup is single-use and retains roots marked unsafe', () async {
      final stage = materializer();
      final result = await stage.materialize(_snapshot());
      final pair = result.pair!;
      pair.baseline.markUnsafeToDelete();

      final first = await stage.cleanup(result.cleanupLease);

      expect(first.baselineRemoved, isFalse);
      expect(first.candidateRemoved, isTrue);
      expect(pair.baseline.directory.existsSync(), isTrue);
      _expectFailure(
        first.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'baseline-root-unsafe-to-delete',
      );
      final second = await stage.cleanup(result.cleanupLease);
      expect(second.baselineRemoved, isFalse);
      expect(second.candidateRemoved, isFalse);
      _expectFailure(
        second.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'cleanup-lease-consumed',
      );
    });

    test(
      'cleanup continues after an injected candidate delete failure',
      () async {
        Directory? candidateDirectory;
        final stage = materializer(
          hook: (operation, root, relativePath) async {
            if (operation == L10nStageOperation.beforeCleanupDelete &&
                root.path == candidateDirectory?.path) {
              throw const FileSystemException('injected cleanup failure');
            }
          },
        );
        final result = await stage.materialize(_snapshot());
        final pair = result.pair!;
        candidateDirectory = pair.candidate.directory;

        final cleanup = await stage.cleanup(result.cleanupLease);

        expect(cleanup.baselineRemoved, isTrue);
        expect(cleanup.candidateRemoved, isFalse);
        expect(pair.baseline.directory.existsSync(), isFalse);
        expect(pair.candidate.directory.existsSync(), isTrue);
        _expectFailure(
          cleanup.failures,
          L10nEvidenceRejectionCode.cleanupFailed,
          'candidate-root-delete-failed',
        );
      },
    );

    test('cleanup verifies absence after deletion', () async {
      Directory? candidateDirectory;
      var recreated = false;
      final stage = materializer(
        hook: (operation, root, relativePath) async {
          if (!recreated &&
              operation == L10nStageOperation.afterCleanupDelete &&
              root.path == candidateDirectory?.path) {
            recreated = true;
            root.createSync();
          }
        },
      );
      final result = await stage.materialize(_snapshot());
      final pair = result.pair!;
      candidateDirectory = pair.candidate.directory;

      final cleanup = await stage.cleanup(result.cleanupLease);

      expect(cleanup.baselineRemoved, isTrue);
      expect(cleanup.candidateRemoved, isFalse);
      expect(pair.candidate.directory.existsSync(), isTrue);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'candidate-root-deletion-unconfirmed',
      );
    });

    test('cleanup refuses a root recreated at the recorded pathname', () async {
      final stage = materializer();
      final result = await stage.materialize(_snapshot());
      final pair = result.pair!;
      final original = pair.baseline.directory;
      final moved = Directory('${original.path}-moved');
      original.renameSync(moved.path);
      Directory(original.path).createSync();

      final cleanup = await stage.cleanup(result.cleanupLease);

      expect(cleanup.baselineRemoved, isFalse);
      expect(cleanup.candidateRemoved, isTrue);
      expect(Directory(original.path).existsSync(), isTrue);
      expect(moved.existsSync(), isTrue);
      _expectFailure(
        cleanup.failures,
        L10nEvidenceRejectionCode.cleanupFailed,
        'baseline-root-identity-drift',
      );
    });
  });
}

const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

L10nToolchainResolved _unboundToolchain() => L10nToolchainResolved(
  canonicalFlutterExecutable: '/test/flutter/bin/flutter',
  canonicalSdkRoot: '/test/flutter',
  launch: const L10nToolchainLaunch(
    canonicalDartExecutable: '/test/flutter/bin/cache/dart-sdk/bin/dart',
    canonicalFlutterToolsPackageConfig:
        '/test/flutter/packages/flutter_tools/.dart_tool/package_config.json',
    canonicalFlutterToolsSnapshot:
        '/test/flutter/bin/cache/flutter_tools.snapshot',
  ),
  selection: const ProjectSelectorSelection(),
  generationArgs: const ['gen-l10n'],
  directProbeArgs: const ['--version', '--machine'],
  environmentOverrides: const {},
  selectorHashesByRelativePath: const {},
  machineIdentity: FlutterMachineIdentity(
    frameworkVersion: Version(3, 41, 5),
    frameworkRevision: '1111111111111111111111111111111111111111',
    engineRevision: '2222222222222222222222222222222222222222',
    dartSdkVersion: '3.9.2',
  ),
  originalSelectionProbeSha256: _identity,
  identitySha256: _identity,
);

L10nFamilySnapshot _snapshot({
  int? arbMode,
  String toolchainIdentity = _identity,
  bool withSidecar = false,
  bool withoutArbMode = false,
  bool withSecondArb = false,
}) {
  final arbBytes = ImmutableBytes.copyOf('{"dead":"Dead"}'.codeUnits);
  final localeArbBytes = ImmutableBytes.copyOf('{"dead":"Mort"}'.codeUnits);
  final projectedPackageBytes = ImmutableBytes.copyOf([3]);
  final entries = <String, L10nSnapshotEntry>{
    'pubspec.yaml': _entry(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      ImmutableBytes.copyOf('name: fixture\n'.codeUnits),
    ),
    'pubspec.lock': _entry(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      ImmutableBytes.copyOf('packages: {}\n'.codeUnits),
    ),
    'l10n.yaml': _absent('l10n.yaml', L10nSnapshotRole.l10nConfig),
    '.dart_tool/package_config.json': L10nSnapshotEntry(
      relativePosixPath: '.dart_tool/package_config.json',
      role: L10nSnapshotRole.packageConfig,
      state: L10nSnapshotPresent(
        sourceBytes: ImmutableBytes.copyOf([9]),
        stageBytes: projectedPackageBytes,
        sourceSha256: ImmutableBytes.copyOf([9]).sha256Hex,
        posixMode: _mode(0x180),
      ),
    ),
    '.dart_tool/package_graph.json': _absent(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
    ),
    'analysis_options.yaml': _absent(
      'analysis_options.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'dart_test.yaml': _absent(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'lib/l10n/app_en.arb': withoutArbMode
        ? L10nSnapshotEntry(
            relativePosixPath: 'lib/l10n/app_en.arb',
            role: L10nSnapshotRole.arbTemplate,
            state: L10nSnapshotPresent(
              sourceBytes: arbBytes,
              stageBytes: arbBytes,
              sourceSha256: arbBytes.sha256Hex,
              posixMode: null,
            ),
          )
        : _entry(
            'lib/l10n/app_en.arb',
            L10nSnapshotRole.arbTemplate,
            arbBytes,
            posixMode: arbMode,
          ),
    if (withSecondArb)
      'lib/l10n/app_fr.arb': _entry(
        'lib/l10n/app_fr.arb',
        L10nSnapshotRole.arbLocale,
        localeArbBytes,
      ),
    'lib/main.dart': _entry(
      'lib/main.dart',
      L10nSnapshotRole.analyzerSource,
      ImmutableBytes.copyOf('void main() {}\n'.codeUnits),
    ),
    'lib/generated/app.dart': _absent(
      'lib/generated/app.dart',
      L10nSnapshotRole.generatedBase,
    ),
    if (withSidecar)
      'build/untranslated.json': _absent(
        'build/untranslated.json',
        L10nSnapshotRole.untranslatedSidecar,
      ),
  };
  return L10nFamilySnapshot(
    entries: entries,
    mutationPlan: _mutationPlan(withSecondArb: withSecondArb),
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {'dead'},
    expectedGeneratedMemberKindsByKey: const {
      'dead': ArbGeneratedMemberKind.getter,
    },
    expectedGeneratedPaths: const {'lib/generated/app.dart'},
    optionalUntranslatedPath: withSidecar ? 'build/untranslated.json' : null,
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

L10nArbMutationPlan _mutationPlan({bool withSecondArb = false}) {
  final parsed = ArbDocument.parse('{"dead":"Dead"}'.codeUnits);
  final localeParsed = ArbDocument.parse('{"dead":"Mort"}'.codeUnits);
  return (L10nArbMutationPlanner.plan(
            templatePath: 'lib/l10n/app_en.arb',
            documentsByPath: {
              'lib/l10n/app_en.arb': (parsed as ArbParseSuccess).document,
              if (withSecondArb)
                'lib/l10n/app_fr.arb':
                    (localeParsed as ArbParseSuccess).document,
            },
            selectedKeys: const ['dead'],
          )
          as L10nArbMutationPlanReady)
      .plan;
}

L10nSnapshotEntry _entry(
  String path,
  L10nSnapshotRole role,
  ImmutableBytes bytes, {
  int? posixMode,
}) => L10nSnapshotEntry(
  relativePosixPath: path,
  role: role,
  state: L10nSnapshotPresent(
    sourceBytes: bytes,
    stageBytes: bytes,
    sourceSha256: bytes.sha256Hex,
    posixMode: posixMode ?? _mode(0x1a4),
  ),
);

L10nSnapshotEntry _absent(String path, L10nSnapshotRole role) =>
    L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: const L10nSnapshotAbsent(),
    );

int? _mode(int value) => Platform.isWindows ? null : value;

int _presentStageByteCount(L10nFamilySnapshot snapshot) => snapshot
    .entries
    .values
    .where((entry) => entry.state is L10nSnapshotPresent)
    .map((entry) => (entry.state as L10nSnapshotPresent).stageBytes.length)
    .fold(0, (sum, length) => sum + length);

Set<String> _relativeRegularFiles(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .where(
      (entity) =>
          FileSystemEntity.typeSync(entity.path, followLinks: false) ==
          FileSystemEntityType.file,
    )
    .map((entity) => p.relative(entity.path, from: root.path))
    .map((relative) => relative.split(p.separator).join('/'))
    .toSet();

Set<String> _relativeDirectories(Directory root) => root
    .listSync(recursive: true, followLinks: false)
    .where(
      (entity) =>
          FileSystemEntity.typeSync(entity.path, followLinks: false) ==
          FileSystemEntityType.directory,
    )
    .map((entity) => p.relative(entity.path, from: root.path))
    .map((relative) => relative.split(p.separator).join('/'))
    .toSet();

Set<String> _expectedParentDirectories(L10nFamilySnapshot snapshot) {
  final result = <String>{};
  for (final entry in snapshot.entries.values) {
    if (entry.state is! L10nSnapshotPresent) continue;
    final segments = entry.relativePosixPath.split('/');
    for (var length = 1; length < segments.length; length++) {
      result.add(segments.take(length).join('/'));
    }
  }
  return result;
}

void _expectFailure(
  List<L10nEvidenceFailure> failures,
  L10nEvidenceRejectionCode code,
  String detailCode,
) {
  expect(
    failures,
    contains(
      isA<L10nEvidenceFailure>()
          .having((failure) => failure.code, 'code', code)
          .having((failure) => failure.detailCode, 'detailCode', detailCode),
    ),
  );
}

String _inode(String path) {
  final result = Platform.isMacOS
      ? Process.runSync('/usr/bin/stat', ['-f', '%d:%i', path])
      : Process.runSync('stat', ['-c', '%d:%i', path]);
  expect(result.exitCode, 0, reason: '${result.stderr}');
  return (result.stdout as String).trim();
}
