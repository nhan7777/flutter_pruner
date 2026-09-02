import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/corpus_mutation_evidence.dart';
import '../../../benchmark/accuracy/src/l10n_mutation_manifest.dart';

void main() {
  late Directory suiteRoot;
  late Directory retainedRepository;
  late File canonicalFlutter;
  late String repositoryRevision;
  late L10nMutationProjectManifest project;

  setUpAll(() {
    suiteRoot = Directory.systemTemp.createTempSync(
      'flutter-pruner-corpus-evidence-test-',
    );
    retainedRepository = Directory(p.join(suiteRoot.path, 'retained'))
      ..createSync();
    _writeFixtureRepository(retainedRepository);
    _git(retainedRepository, ['init', '-q']);
    _git(retainedRepository, ['config', 'user.email', 'fixture@example.test']);
    _git(retainedRepository, ['config', 'user.name', 'Fixture']);
    _git(retainedRepository, ['add', '.']);
    _git(retainedRepository, ['commit', '-qm', 'fixture']);
    repositoryRevision = _gitText(retainedRepository, ['rev-parse', 'HEAD']);

    canonicalFlutter = File(p.join(suiteRoot.path, 'sdk', 'bin', 'flutter'));
    canonicalFlutter.parent.createSync(recursive: true);
    canonicalFlutter.writeAsStringSync('#!/bin/sh\nexit 99\n');
    _chmod(canonicalFlutter, 0x1ed);

    project = L10nMutationProjectManifest(
      id: 'smooth',
      repositoryRevision: repositoryRevision,
      packageRootRelative: 'packages/smooth_app',
      toolchainVersion: '3.38.7',
      verificationPolicy: [
        CorpusVerificationCommand(
          workingDirectoryRelativeToRepository: '.',
          argumentsAfterCanonicalFlutter: const [
            'analyze',
            '--no-pub',
            '--fatal-infos',
            '--fatal-warnings',
            '.',
          ],
        ),
        CorpusVerificationCommand(
          workingDirectoryRelativeToRepository: 'packages/smooth_app',
          argumentsAfterCanonicalFlutter: const ['test', '--no-pub'],
        ),
      ],
      arbDirectoryRelative: 'packages/smooth_app/lib/l10n',
      templateArbPathRelative: 'packages/smooth_app/lib/l10n/app_en.arb',
      arbPathsRelative: const [
        'packages/smooth_app/lib/l10n/app_en.arb',
        'packages/smooth_app/lib/l10n/app_fr.arb',
      ],
    );
  });

  tearDownAll(() {
    if (suiteRoot.existsSync()) suiteRoot.deleteSync(recursive: true);
  });

  group('DefaultCorpusProjectViewFactory', () {
    test(
      'creates an exact-revision no-local copy, provisions once, and owns disposal',
      () async {
        final runner = _CorpusProcessRunner();
        final factory = DefaultCorpusProjectViewFactory(processRunner: runner);
        final retainedArb = File(
          p.join(
            retainedRepository.path,
            'packages',
            'smooth_app',
            'lib',
            'l10n',
            'app_en.arb',
          ),
        );
        final retainedBefore = retainedArb.readAsBytesSync();
        final retainedStatusBefore = _gitStatusBytes(retainedRepository);

        final result = await factory.create(
          project: project,
          retainedRepositoryPath: retainedRepository.path,
          canonicalFlutterExecutable: canonicalFlutter.path,
        );

        final view = (result as CorpusProjectViewReady).view;
        addTearDown(() async {
          await view.dispose();
        });
        expect(view.repositoryRevision, repositoryRevision);
        expect(view.repositoryRoot.path, isNot(retainedRepository.path));
        expect(
          p.equals(
            view.packageRoot.path,
            p.join(view.repositoryRoot.path, 'packages', 'smooth_app'),
          ),
          isTrue,
        );
        expect(view.provisionedBaselineFingerprint, matches(_sha256));
        expect(view.baselineGitStatusIdentity, matches(_sha256));
        expect(
          File(
            p.join(view.packageRoot.path, '.dart_tool', 'package_config.json'),
          ).existsSync(),
          isTrue,
        );
        expect(
          runner.flutterInvocations
              .where((entry) => entry.arguments.firstOrNull == 'pub')
              .map((entry) => entry.arguments),
          [
            const ['pub', 'get', '--offline'],
          ],
        );
        expect(
          runner.flutterInvocations.map((entry) => entry.arguments),
          [
            const ['--version', '--machine'],
            const ['pub', 'get', '--offline'],
            const ['--version', '--machine'],
          ],
          reason: 'toolchain authority must bracket the only resolution',
        );
        final clone = runner.gitInvocations.singleWhere(
          (entry) => entry.arguments.contains('clone'),
        );
        expect(clone.arguments, contains('--no-local'));
        expect(clone.arguments, contains('--no-hardlinks'));
        expect(clone.arguments, contains('--no-checkout'));
        expect(clone.arguments, contains('--no-tags'));
        expect(
          File(
            p.join(
              view.repositoryRoot.path,
              '.git',
              'objects',
              'info',
              'alternates',
            ),
          ).existsSync(),
          isFalse,
        );
        expect(_gitText(view.repositoryRoot, const ['remote']), isEmpty);
        expect(
          File(
            p.join(view.repositoryRoot.path, '.git', 'config'),
          ).readAsStringSync(),
          isNot(contains(retainedRepository.path)),
        );

        final copiedArb = File(
          p.join(
            view.repositoryRoot.path,
            'packages',
            'smooth_app',
            'lib',
            'l10n',
            'app_en.arb',
          ),
        );
        copiedArb.writeAsStringSync('copy-only\n');
        expect(retainedArb.readAsBytesSync(), retainedBefore);
        expect(_gitStatusBytes(retainedRepository), retainedStatusBefore);

        final ownedRoot = view.repositoryRoot.parent;
        expect(await view.dispose(), isTrue);
        expect(ownedRoot.existsSync(), isFalse);
      },
    );

    test(
      'returns a redacted provisioning failure and leaves source untouched',
      () async {
        final runner = _CorpusProcessRunner(pubGetExitCode: 69);
        final retainedBefore = _gitStatusBytes(retainedRepository);

        final result =
            await DefaultCorpusProjectViewFactory(processRunner: runner).create(
              project: project,
              retainedRepositoryPath: retainedRepository.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final rejected = result as CorpusProjectViewRejected;
        expect(
          rejected.outcome.status,
          CorpusMutationEvidenceStatus.provisioningFailed,
        );
        expect(rejected.outcome.restorationVerified, isFalse);
        _expectRedacted(rejected.outcome.commandResults, suiteRoot.path);
        expect(_gitStatusBytes(retainedRepository), retainedBefore);
      },
    );

    test(
      'rejects retained Git control drift even when status stays clean',
      () async {
        final retained = Directory.systemTemp.createTempSync(
          'flutter-pruner-retained-control-',
        );
        addTearDown(() {
          if (retained.existsSync()) retained.deleteSync(recursive: true);
        });
        _writeRootPackageRepository(retained);
        final firstRevision = _commitFixtureRepository(retained);
        _git(retained, ['commit', '--allow-empty', '-qm', 'same tree']);
        final expectedRevision = _gitText(retained, const [
          'rev-parse',
          'HEAD',
        ]);
        final statusBefore = _gitStatusBytes(retained);
        final runner = _CorpusProcessRunner(
          onPubGet: (_) {
            _git(retained, ['update-ref', 'HEAD', firstRevision]);
          },
        );

        final result =
            await DefaultCorpusProjectViewFactory(processRunner: runner).create(
              project: _rootProject(id: 'fixture', revision: expectedRevision),
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final rejected = result as CorpusProjectViewRejected;
        expect(
          rejected.outcome.commandResults.single['status'],
          'retainedRepositoryDrift',
        );
        expect(_gitStatusBytes(retained), statusBefore);
        expect(_gitText(retained, const ['rev-parse', 'HEAD']), firstRevision);
      },
    );

    test('does not delete an owned root whose safe mode drifted', () async {
      if (!_posix) return;
      Directory? ownedRoot;
      final runner = _CorpusProcessRunner(
        pubGetExitCode: 69,
        onPubGet: (packageRoot) {
          ownedRoot = packageRoot.parent.parent.parent;
          _chmodDirectory(ownedRoot!, 0x1ed);
        },
      );
      addTearDown(() {
        final root = ownedRoot;
        if (root != null && root.existsSync()) {
          _chmodDirectory(root, 0x1c0);
          root.deleteSync(recursive: true);
        }
      });

      final result =
          await DefaultCorpusProjectViewFactory(processRunner: runner).create(
            project: project,
            retainedRepositoryPath: retainedRepository.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final rejected = result as CorpusProjectViewRejected;
      expect(rejected.outcome.commandResults.single['status'], 'cleanupFailed');
      expect(ownedRoot, isNotNull);
      expect(ownedRoot!.existsSync(), isTrue);
    });

    test(
      'keeps a preexisting temp base and deletes only its fresh owned child',
      () async {
        final preexisting = Directory.systemTemp.createTempSync(
          'flutter-pruner-corpus-view-',
        );
        final sentinel = File(p.join(preexisting.path, 'belongs-to-caller'))
          ..writeAsStringSync('keep\n');
        addTearDown(() {
          if (preexisting.existsSync()) preexisting.deleteSync(recursive: true);
        });

        final result =
            await DefaultCorpusProjectViewFactory(
              processRunner: _CorpusProcessRunner(),
              temporaryDirectoryFactory: (_) => preexisting,
            ).create(
              project: project,
              retainedRepositoryPath: retainedRepository.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final view = (result as CorpusProjectViewReady).view;
        final ownedChild = view.repositoryRoot.parent;
        expect(
          ownedChild.parent.resolveSymbolicLinksSync(),
          preexisting.resolveSymbolicLinksSync(),
        );
        expect(ownedChild.path, isNot(preexisting.path));
        expect(await view.dispose(), isTrue);
        expect(ownedChild.existsSync(), isFalse);
        expect(preexisting.existsSync(), isTrue);
        expect(sentinel.readAsStringSync(), 'keep\n');
        expect(
          File(
            p.join(preexisting.path, '.flutter-pruner-corpus-owner'),
          ).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'rejects an allocator root nested inside the retained repository',
      () async {
        final retained = Directory.systemTemp.createTempSync(
          'flutter-pruner-retained-overlap-',
        );
        addTearDown(() {
          if (retained.existsSync()) retained.deleteSync(recursive: true);
        });
        _writeRootPackageRepository(retained);
        final revision = _commitFixtureRepository(retained);
        final nested = Directory(
          p.join(retained.path, 'flutter-pruner-corpus-view-nested'),
        )..createSync();
        _chmodDirectory(nested, 0x1c0);
        final statusBefore = _gitStatusBytes(retained);

        final result =
            await DefaultCorpusProjectViewFactory(
              processRunner: _CorpusProcessRunner(),
              temporaryDirectoryFactory: (_) => nested,
            ).create(
              project: _rootProject(id: 'fixture', revision: revision),
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        expect(result, isA<CorpusProjectViewRejected>());
        expect(nested.existsSync(), isTrue);
        expect(nested.listSync(), isEmpty);
        expect(_gitStatusBytes(retained), statusBefore);
      },
    );

    test('accepts an exact tracked fixture overlay', () async {
      final retained = Directory(p.join(suiteRoot.path, 'tracked-exact'))
        ..createSync(recursive: true);
      _writeRootPackageRepository(retained);
      const overlayPath = 'lib/.env.dart';
      const sourceIdentity = 'fixture-authority/exact/lib/.env.dart';
      const fixtureSource = 'const fixtureEnvironment = "test";\n';
      final sourceFile = File(p.join(suiteRoot.path, sourceIdentity));
      sourceFile.parent.createSync(recursive: true);
      sourceFile.writeAsStringSync(fixtureSource);
      _chmod(sourceFile, 0x1a4);
      final target = File(_rootPath(retained, overlayPath));
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(fixtureSource);
      _chmod(target, 0x1a4);
      final revision = _commitFixtureRepository(retained);
      final retainedStatusBefore = _gitStatusBytes(retained);
      final runner = _CorpusProcessRunner();

      final creation =
          await DefaultCorpusProjectViewFactory(processRunner: runner).create(
            project: _rootProject(
              id: 'fixture',
              revision: revision,
              fixtureOverlays: [
                L10nFixtureOverlay(
                  relativePath: overlayPath,
                  sourceIdentity: sourceIdentity,
                  purpose: 'non-secret deterministic config stub',
                  sha256: ImmutableBytes.copyOf(
                    sourceFile.readAsBytesSync(),
                  ).sha256Hex,
                  containsSecrets: false,
                ),
              ],
            ),
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final view = (creation as CorpusProjectViewReady).view;
      addTearDown(view.dispose);
      expect(
        File(_rootPath(view.repositoryRoot, overlayPath)).readAsStringSync(),
        fixtureSource,
      );
      expect(
        runner.flutterInvocations.where(
          (entry) => entry.arguments.firstOrNull == 'pub',
        ),
        hasLength(1),
      );
      expect(_gitStatusBytes(retained), retainedStatusBefore);
    });

    test('accepts an authority-bound toolchain selector replacement', () async {
      final retained = Directory(p.join(suiteRoot.path, 'selector-replacement'))
        ..createSync(recursive: true);
      _writeRootPackageRepository(retained);
      const sourceIdentity = 'fixture-authority/toolchain/.fvmrc';
      const selector = '{\n  "flutter": "3.38.7"\n}\n';
      final sourceFile = File(p.join(suiteRoot.path, sourceIdentity));
      sourceFile.parent.createSync(recursive: true);
      sourceFile.writeAsStringSync(selector);
      _chmod(sourceFile, 0x1a4);
      final selectorHash = ImmutableBytes.copyOf(
        sourceFile.readAsBytesSync(),
      ).sha256Hex;
      final target = File(_rootPath(retained, '.fvmrc'));
      target.writeAsStringSync('{\n  "flutter": "3.37.0"\n}\n');
      _chmod(target, 0x1a4);
      final revision = _commitFixtureRepository(retained);
      final retainedStatusBefore = _gitStatusBytes(retained);
      final runner = _CorpusProcessRunner();

      final creation =
          await DefaultCorpusProjectViewFactory(processRunner: runner).create(
            project: _rootProject(
              id: 'fixture',
              revision: revision,
              fixtureOverlays: [
                L10nFixtureOverlay(
                  relativePath: '.fvmrc',
                  sourceIdentity: sourceIdentity,
                  purpose: 'toolchain selector authority',
                  sha256: selectorHash,
                  containsSecrets: false,
                ),
              ],
              toolchainSelectionEvidence: {
                'evidencePath': '.fvmrc',
                'evidenceSha256': selectorHash,
                'frameworkVersion': '3.38.7',
                'selectionKind': 'pinned-fvm-config',
              },
            ),
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final view = (creation as CorpusProjectViewReady).view;
      addTearDown(view.dispose);
      expect(
        File(_rootPath(view.repositoryRoot, '.fvmrc')).readAsStringSync(),
        selector,
      );
      expect(_gitStatusBytes(retained), retainedStatusBefore);
    });

    test('rejects mismatched tracked fixture bytes before pub get', () async {
      final retained = Directory(p.join(suiteRoot.path, 'tracked-mismatch'))
        ..createSync(recursive: true);
      _writeRootPackageRepository(retained);
      const overlayPath = 'lib/.env.dart';
      const sourceIdentity = 'fixture-authority/mismatch/lib/.env.dart';
      final sourceFile = File(p.join(suiteRoot.path, sourceIdentity));
      sourceFile.parent.createSync(recursive: true);
      sourceFile.writeAsStringSync('const fixtureEnvironment = "test";\n');
      _chmod(sourceFile, 0x1a4);
      final target = File(_rootPath(retained, overlayPath));
      target.parent.createSync(recursive: true);
      target.writeAsStringSync('const fixtureEnvironment = "foreign";\n');
      _chmod(target, 0x1a4);
      final revision = _commitFixtureRepository(retained);
      final retainedStatusBefore = _gitStatusBytes(retained);
      final runner = _CorpusProcessRunner();

      final creation =
          await DefaultCorpusProjectViewFactory(processRunner: runner).create(
            project: _rootProject(
              id: 'fixture',
              revision: revision,
              fixtureOverlays: [
                L10nFixtureOverlay(
                  relativePath: overlayPath,
                  sourceIdentity: sourceIdentity,
                  purpose: 'non-secret deterministic config stub',
                  sha256: ImmutableBytes.copyOf(
                    sourceFile.readAsBytesSync(),
                  ).sha256Hex,
                  containsSecrets: false,
                ),
              ],
            ),
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      expect(creation, isA<CorpusProjectViewRejected>());
      expect(
        runner.flutterInvocations.where(
          (entry) => entry.arguments.firstOrNull == 'pub',
        ),
        isEmpty,
      );
      expect(_gitStatusBytes(retained), retainedStatusBefore);
    });

    test('accepts canonical Flutter ephemeral outputs from pub get', () async {
      final scenario = await _provision(
        project: project,
        retainedRepository: retainedRepository,
        canonicalFlutter: canonicalFlutter,
        onPubGet: _writeFlutterEphemeralOutputs,
      );
      addTearDown(scenario.view.dispose);

      for (final path in _flutterEphemeralPaths) {
        expect(
          File(_rootPath(scenario.view.packageRoot, path)).existsSync(),
          isTrue,
        );
      }
    });

    test('preserves tracked Flutter ephemeral inputs during pub get', () async {
      final retained = Directory(p.join(suiteRoot.path, 'tracked-ephemeral'))
        ..createSync(recursive: true);
      _writeRootPackageRepository(retained);
      for (final relativePath in _flutterEphemeralPaths) {
        final file = File(_rootPath(retained, relativePath));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync('tracked $relativePath\n');
      }
      final revision = _commitFixtureRepository(retained);
      final retainedStatusBefore = _gitStatusBytes(retained);

      final creation =
          await DefaultCorpusProjectViewFactory(
            processRunner: _CorpusProcessRunner(),
          ).create(
            project: _rootProject(id: 'fixture', revision: revision),
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final view = (creation as CorpusProjectViewReady).view;
      addTearDown(view.dispose);
      for (final relativePath in _flutterEphemeralPaths) {
        expect(
          File(_rootPath(view.repositoryRoot, relativePath)).readAsStringSync(),
          'tracked $relativePath\n',
        );
      }
      expect(_gitStatusBytes(retained), retainedStatusBefore);
    });

    test('detects drift in a provisioned Flutter ephemeral output', () async {
      final scenario = await _provision(
        project: project,
        retainedRepository: retainedRepository,
        canonicalFlutter: canonicalFlutter,
        onPubGet: _writeFlutterEphemeralOutputs,
      );
      addTearDown(scenario.view.dispose);
      File(
        _rootPath(scenario.view.packageRoot, _flutterEphemeralPaths.first),
      ).writeAsStringSync('drift\n');

      final outcome = await _runScenario(scenario, project, canonicalFlutter);

      expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
      expect(outcome.commandResults.single['status'], 'sourceDrift');
      expect(scenario.processRunner.policyInvocations, isEmpty);
    });

    test(
      'copies a real-shape ignored fixture only from its source authority',
      () async {
        final retained = Directory(p.join(suiteRoot.path, 'gsy'))
          ..createSync(recursive: true);
        _writeRootPackageRepository(retained);
        const overlayPath = 'lib/common/config/ignoreConfig.dart';
        const sourceIdentity = 'worktrees/v2-natural-accuracy/gsy/$overlayPath';
        final sourceFile = File(
          p.joinAll([
            suiteRoot.path,
            'worktrees',
            'v2-natural-accuracy',
            'gsy',
            ...overlayPath.split('/'),
          ]),
        );
        sourceFile.parent.createSync(recursive: true);
        sourceFile.writeAsStringSync('const ignoredFixture = true;\n');
        _chmod(sourceFile, 0x1a4);
        final sourceBytes = sourceFile.readAsBytesSync();
        File(p.join(retained.path, '.gitignore')).writeAsStringSync(
          '$overlayPath\n.dart_tool/\n.flutter-plugins\n'
          '.flutter-plugins-dependencies\n',
        );
        final revision = _commitFixtureRepository(retained);
        final retainedStatusBefore = _gitStatusBytes(retained);
        final overlay = L10nFixtureOverlay(
          relativePath: overlayPath,
          sourceIdentity: sourceIdentity,
          purpose: 'non-secret deterministic config stub',
          sha256: ImmutableBytes.copyOf(sourceFile.readAsBytesSync()).sha256Hex,
          containsSecrets: false,
        );
        final fixtureProject = _rootProject(
          id: 'fixture',
          revision: revision,
          fixtureOverlays: [overlay],
        );
        final processRunner = _CorpusProcessRunner();

        final creation =
            await DefaultCorpusProjectViewFactory(
              processRunner: processRunner,
            ).create(
              project: fixtureProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final view = (creation as CorpusProjectViewReady).view;
        addTearDown(() async {
          await view.dispose();
        });
        expect(
          File(_rootPath(view.repositoryRoot, overlayPath)).readAsBytesSync(),
          sourceFile.readAsBytesSync(),
        );
        expect(File(_rootPath(retained, overlayPath)).existsSync(), isFalse);
        expect(sourceFile.readAsStringSync(), 'const ignoredFixture = true;\n');
        expect(_gitStatusBytes(retained), retainedStatusBefore);
        expect(
          view.repositoryRoot.path,
          isNot(startsWith(p.dirname(retained.path))),
        );

        final wrongHashProject = _rootProject(
          id: 'fixture',
          revision: revision,
          fixtureOverlays: [
            L10nFixtureOverlay(
              relativePath: overlayPath,
              sourceIdentity: overlay.sourceIdentity,
              purpose: overlay.purpose,
              sha256: _hashA,
              containsSecrets: false,
            ),
          ],
        );
        final rejectedRunner = _CorpusProcessRunner();
        final rejected =
            await DefaultCorpusProjectViewFactory(
              processRunner: rejectedRunner,
            ).create(
              project: wrongHashProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );
        expect(rejected, isA<CorpusProjectViewRejected>());
        expect(
          rejectedRunner.flutterInvocations.where(
            (entry) => entry.arguments.firstOrNull == 'pub',
          ),
          isEmpty,
        );
        expect(_gitStatusBytes(retained), retainedStatusBefore);

        final driftRunner = _CorpusProcessRunner(
          onPubGet: (packageRoot) {
            File(
              _rootPath(packageRoot, overlayPath),
            ).writeAsStringSync('pub drift\n');
          },
        );
        final drifted =
            await DefaultCorpusProjectViewFactory(
              processRunner: driftRunner,
            ).create(
              project: fixtureProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );
        final driftOutcome = (drifted as CorpusProjectViewRejected).outcome;
        expect(
          driftOutcome.commandResults.single['status'],
          'overlayTargetDrift',
        );
        expect(sourceFile.readAsStringSync(), 'const ignoredFixture = true;\n');
        expect(_gitStatusBytes(retained), retainedStatusBefore);

        final physicalDriftRunner = _CorpusProcessRunner(
          onPubGet: (_) {
            sourceFile.deleteSync();
            sourceFile.writeAsBytesSync(sourceBytes, flush: true);
            _chmod(sourceFile, 0x1a4);
            sourceFile.setLastModifiedSync(
              sourceFile.lastModifiedSync().add(const Duration(seconds: 2)),
            );
          },
        );
        final physicallyDrifted =
            await DefaultCorpusProjectViewFactory(
              processRunner: physicalDriftRunner,
            ).create(
              project: fixtureProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );
        expect(physicallyDrifted, isA<CorpusProjectViewRejected>());
        expect(
          (physicallyDrifted as CorpusProjectViewRejected)
              .outcome
              .commandResults
              .single['status'],
          'retainedRepositoryDrift',
        );

        var statusInvocations = 0;
        final lateDriftRunner = _CorpusProcessRunner(
          onGitInvocation: (invocation) {
            if (!invocation.arguments.contains('status')) return;
            statusInvocations++;
            if (statusInvocations == 5) {
              sourceFile.writeAsStringSync('late source drift\n', flush: true);
            }
          },
        );
        final lateDrifted =
            await DefaultCorpusProjectViewFactory(
              processRunner: lateDriftRunner,
            ).create(
              project: fixtureProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );
        expect(statusInvocations, 5);
        expect(lateDrifted, isA<CorpusProjectViewRejected>());
        expect(
          (lateDrifted as CorpusProjectViewRejected)
              .outcome
              .commandResults
              .single['status'],
          'retainedRepositoryDrift',
        );
        expect(sourceFile.readAsStringSync(), 'late source drift\n');
        sourceFile.writeAsBytesSync(sourceBytes, flush: true);
        _chmod(sourceFile, 0x1a4);
        expect(_gitStatusBytes(retained), retainedStatusBefore);
      },
    );

    test('rejects pub mutation of a non-overlay tracked source', () async {
      final retainedStatusBefore = _gitStatusBytes(retainedRepository);
      final runner = _CorpusProcessRunner(
        onPubGet: (packageRoot) {
          File(
            p.join(packageRoot.path, 'lib', 'l10n', 'app_fr.arb'),
          ).writeAsStringSync('{"pub":"drift"}\n');
        },
      );

      final result =
          await DefaultCorpusProjectViewFactory(processRunner: runner).create(
            project: project,
            retainedRepositoryPath: retainedRepository.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final rejected = result as CorpusProjectViewRejected;
      expect(
        rejected.outcome.commandResults.single['status'],
        'pubSourceDrift',
      );
      expect(_gitStatusBytes(retainedRepository), retainedStatusBefore);
    });

    test(
      'rejects a same-version toolchain with the wrong declared revision before pub',
      () async {
        final wrongRevisionProject = L10nMutationProjectManifest(
          id: project.id,
          repositoryRevision: project.repositoryRevision,
          packageRootRelative: project.packageRootRelative,
          toolchainVersion: project.toolchainVersion,
          verificationPolicy: project.verificationPolicy,
          arbDirectoryRelative: project.arbDirectoryRelative,
          templateArbPathRelative: project.templateArbPathRelative,
          arbPathsRelative: project.arbPathsRelative,
          toolchainSelectionEvidence: const {
            'frameworkVersion': '3.38.7',
            'frameworkRevision': 'cccccccccccccccccccccccccccccccccccccccc',
          },
        );
        final runner = _CorpusProcessRunner(
          toolchainMachine: const {
            'frameworkVersion': '3.38.7',
            'frameworkRevision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
            'engineRevision': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            'dartSdkVersion': '3.10.7',
          },
        );

        final result =
            await DefaultCorpusProjectViewFactory(processRunner: runner).create(
              project: wrongRevisionProject,
              retainedRepositoryPath: retainedRepository.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        expect(result, isA<CorpusProjectViewRejected>());
        expect(
          runner.flutterInvocations.where(
            (entry) => entry.arguments.firstOrNull == 'pub',
          ),
          isEmpty,
        );
      },
    );

    test(
      'rejects second-probe Git drift before any later Git invocation',
      () async {
        late _CorpusProcessRunner runner;
        late int gitCountAtDrift;
        runner = _CorpusProcessRunner(
          onToolchainProbe: (occurrence) {
            if (occurrence != 2) return;
            final clone = runner.gitInvocations.firstWhere(
              (invocation) => invocation.arguments.contains('clone'),
            );
            final repository = Directory(clone.arguments.last);
            File(
              p.join(repository.path, '.git', 'config'),
            ).writeAsStringSync('[core]\n\tbare = true\n');
            gitCountAtDrift = runner.gitInvocations.length;
          },
        );

        final result =
            await DefaultCorpusProjectViewFactory(processRunner: runner).create(
              project: project,
              retainedRepositoryPath: retainedRepository.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final rejected = result as CorpusProjectViewRejected;
        expect(
          rejected.outcome.commandResults.single['status'],
          'protectedAuthorityDrift',
        );
        expect(runner.gitInvocations, hasLength(gitCountAtDrift));
      },
    );

    test(
      'rejects missing GSY normalization and normalization on other projects',
      () async {
        final invalidProjects = [
          _rootProject(id: 'gsy', revision: repositoryRevision),
          _rootProject(
            id: 'other',
            revision: repositoryRevision,
            normalizationOverlays: [
              L10nNormalizationOverlay(
                manifest: 'gsy-normalized-family-v2.json',
                policy: 'apply-declared-byte-transforms',
              ),
            ],
          ),
        ];

        for (final invalid in invalidProjects) {
          final runner = _CorpusProcessRunner();
          final result =
              await DefaultCorpusProjectViewFactory(
                processRunner: runner,
              ).create(
                project: invalid,
                retainedRepositoryPath: retainedRepository.path,
                canonicalFlutterExecutable: canonicalFlutter.path,
              );
          expect(result, isA<CorpusProjectViewRejected>());
          expect(runner.gitInvocations, isEmpty);
          expect(runner.flutterInvocations, isEmpty);
        }
      },
    );

    test(
      'installs position-preserving semantic normalization only after pub get',
      () async {
        final retained = Directory(p.join(suiteRoot.path, 'gsy-normalized'))
          ..createSync();
        _writeRootPackageRepository(retained);
        for (final relativePath in _gsyArbPaths) {
          final file = File(_rootPath(retained, relativePath));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(_duplicateArb);
        }
        final revision = _commitFixtureRepository(retained);
        final normalization = _syntheticNormalizationManifest(revision);
        final normalizedProject = _rootProject(
          id: 'gsy',
          revision: revision,
          arbPathsRelative: _gsyArbPaths,
          normalizationOverlays: [
            L10nNormalizationOverlay(
              manifest: 'gsy-normalized-family-v2.json',
              policy: 'apply-declared-byte-transforms',
              normalizationManifest: normalization,
            ),
          ],
        );
        final runner = _CorpusProcessRunner(
          onPubGet: (packageRoot) {
            for (final relativePath in _gsyArbPaths) {
              expect(
                File(_rootPath(packageRoot, relativePath)).readAsStringSync(),
                _duplicateArb,
                reason: 'pub get must observe the retained semantic baseline',
              );
            }
          },
        );

        final creation =
            await DefaultCorpusProjectViewFactory(
              processRunner: runner,
              normalizationManifestLoaderForTesting: (_, _) => normalization,
            ).create(
              project: normalizedProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final view = (creation as CorpusProjectViewReady).view;
        addTearDown(view.dispose);
        for (final relativePath in _gsyArbPaths) {
          final contents = File(
            _rootPath(view.repositoryRoot, relativePath),
          ).readAsStringSync();
          expect(contents, _positionPreservingNormalizedArb);
        }
      },
    );

    test(
      'regenerates an exact normalized generated baseline after pub get',
      () async {
        const generatedPath =
            'lib/common/localization/l10n/app_localizations.dart';
        const beforeGenerated = '// original generated baseline\n';
        const afterGenerated = '// normalized generated baseline\n';
        final retained = Directory(
          p.join(suiteRoot.path, 'gsy-normalized-generated'),
        )..createSync();
        _writeRootPackageRepository(retained);
        for (final relativePath in _gsyArbPaths) {
          final file = File(_rootPath(retained, relativePath));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(_duplicateArb);
        }
        final generated = File(_rootPath(retained, generatedPath));
        generated.parent.createSync(recursive: true);
        generated.writeAsStringSync(beforeGenerated);
        const legitimatePackageFiles = <String, String>{
          'ios/AppIcon.icon/Assets/1 - Layer 2.svg': '<svg />\n',
          'ios/Runner/Assets.xcassets/BrandingImage.imageset/'
                  'BrandingImage@2x.png':
              'png fixture\n',
        };
        for (final entry in legitimatePackageFiles.entries) {
          final file = File(_rootPath(retained, entry.key));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(entry.value);
        }
        final revision = _commitFixtureRepository(retained);
        final normalization = _syntheticNormalizationManifest(
          revision,
          generatedBaseline: L10nNormalizedGeneratedBaseline(
            changedOutputs: [
              L10nNormalizedGeneratedOutput(
                relativePath: generatedPath,
                originalSha256: ImmutableBytes.copyOf(
                  utf8.encode(beforeGenerated),
                ).sha256Hex,
                replacementSha256: ImmutableBytes.copyOf(
                  utf8.encode(afterGenerated),
                ).sha256Hex,
                posixMode: 0x1a4,
              ),
            ],
          ),
        );
        final normalizedProject = _rootProject(
          id: 'gsy',
          revision: revision,
          arbPathsRelative: _gsyArbPaths,
          normalizationOverlays: [
            L10nNormalizationOverlay(
              manifest: 'gsy-normalized-family-v2.json',
              policy: 'apply-declared-byte-transforms',
              normalizationManifest: normalization,
            ),
          ],
        );
        final runner = _CorpusProcessRunner(
          onPubGet: (packageRoot) {
            for (final relativePath in _gsyArbPaths) {
              expect(
                File(_rootPath(packageRoot, relativePath)).readAsStringSync(),
                _duplicateArb,
              );
            }
          },
          onGenL10n: (packageRoot) {
            for (final relativePath in _gsyArbPaths) {
              expect(
                File(_rootPath(packageRoot, relativePath)).readAsStringSync(),
                _positionPreservingNormalizedArb,
              );
            }
            File(
              _rootPath(packageRoot, generatedPath),
            ).writeAsStringSync(afterGenerated);
          },
        );

        final creation =
            await DefaultCorpusProjectViewFactory(
              processRunner: runner,
              normalizationManifestLoaderForTesting: (_, _) => normalization,
            ).create(
              project: normalizedProject,
              retainedRepositoryPath: retained.path,
              canonicalFlutterExecutable: canonicalFlutter.path,
            );

        final view = (creation as CorpusProjectViewReady).view;
        addTearDown(view.dispose);
        expect(
          File(
            _rootPath(view.repositoryRoot, generatedPath),
          ).readAsStringSync(),
          afterGenerated,
        );
        for (final entry in legitimatePackageFiles.entries) {
          expect(
            File(_rootPath(view.repositoryRoot, entry.key)).readAsStringSync(),
            entry.value,
          );
        }
        expect(runner.flutterInvocations.map((entry) => entry.arguments), [
          const ['--version', '--machine'],
          const ['pub', 'get', '--offline'],
          const ['gen-l10n'],
          const ['--version', '--machine'],
        ]);
      },
    );

    test('rejects an undeclared normalized generator write', () async {
      const generatedPath =
          'lib/common/localization/l10n/app_localizations.dart';
      const beforeGenerated = '// original generated baseline\n';
      const afterGenerated = '// normalized generated baseline\n';
      final retained = Directory(
        p.join(suiteRoot.path, 'gsy-normalized-undeclared-write'),
      )..createSync();
      _writeRootPackageRepository(retained);
      for (final relativePath in _gsyArbPaths) {
        final file = File(_rootPath(retained, relativePath));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(_duplicateArb);
      }
      final generated = File(_rootPath(retained, generatedPath));
      generated.parent.createSync(recursive: true);
      generated.writeAsStringSync(beforeGenerated);
      final revision = _commitFixtureRepository(retained);
      final normalization = _syntheticNormalizationManifest(
        revision,
        generatedBaseline: L10nNormalizedGeneratedBaseline(
          changedOutputs: [
            L10nNormalizedGeneratedOutput(
              relativePath: generatedPath,
              originalSha256: ImmutableBytes.copyOf(
                utf8.encode(beforeGenerated),
              ).sha256Hex,
              replacementSha256: ImmutableBytes.copyOf(
                utf8.encode(afterGenerated),
              ).sha256Hex,
              posixMode: 0x1a4,
            ),
          ],
        ),
      );
      final normalizedProject = _rootProject(
        id: 'gsy',
        revision: revision,
        arbPathsRelative: _gsyArbPaths,
        normalizationOverlays: [
          L10nNormalizationOverlay(
            manifest: 'gsy-normalized-family-v2.json',
            policy: 'apply-declared-byte-transforms',
            normalizationManifest: normalization,
          ),
        ],
      );
      final runner = _CorpusProcessRunner(
        onGenL10n: (packageRoot) {
          File(
            _rootPath(packageRoot, generatedPath),
          ).writeAsStringSync(afterGenerated);
          File(
            _rootPath(packageRoot, 'README.md'),
          ).writeAsStringSync('undeclared generator write\n');
        },
      );

      final creation =
          await DefaultCorpusProjectViewFactory(
            processRunner: runner,
            normalizationManifestLoaderForTesting: (_, _) => normalization,
          ).create(
            project: normalizedProject,
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      final rejected = creation as CorpusProjectViewRejected;
      expect(
        rejected.outcome.commandResults.single['status'],
        'managedAuthorityDrift',
      );
      expect(_gitStatusBytes(retained), isEmpty);
    });

    test(
      'rejects unsafe normalization copy spans before installation',
      () async {
        final retained = Directory(p.join(suiteRoot.path, 'gsy-invalid-copy'))
          ..createSync();
        _writeRootPackageRepository(retained);
        for (final relativePath in _gsyArbPaths) {
          final file = File(_rootPath(retained, relativePath));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(_duplicateArb);
        }
        final revision = _commitFixtureRepository(retained);
        final invalidManifests = <L10nNormalizationManifest>[
          _syntheticNormalizationManifest(
            revision,
            copyMutation: (copy) => L10nCopiedByteSpan(
              start: copy.sourceStart,
              endExclusive: copy.sourceEndExclusive,
              sourceStart: copy.sourceStart,
              sourceEndExclusive: copy.sourceEndExclusive,
            ),
          ),
          _syntheticNormalizationManifest(
            revision,
            copyMutation: (copy) => L10nCopiedByteSpan(
              start: copy.start,
              endExclusive: copy.endExclusive,
              sourceStart: copy.sourceStart,
              sourceEndExclusive: _duplicateArb.length + 1,
            ),
          ),
        ];

        for (final normalization in invalidManifests) {
          final project = _rootProject(
            id: 'gsy',
            revision: revision,
            arbPathsRelative: _gsyArbPaths,
            normalizationOverlays: [
              L10nNormalizationOverlay(
                manifest: 'gsy-normalized-family-v2.json',
                policy: 'apply-declared-byte-transforms',
                normalizationManifest: normalization,
              ),
            ],
          );
          final result =
              await DefaultCorpusProjectViewFactory(
                processRunner: _CorpusProcessRunner(),
                normalizationManifestLoaderForTesting: (_, _) => normalization,
              ).create(
                project: project,
                retainedRepositoryPath: retained.path,
                canonicalFlutterExecutable: canonicalFlutter.path,
              );

          expect(result, isA<CorpusProjectViewRejected>());
        }
      },
    );

    test('does not trust a forged embedded GSY normalization object', () async {
      final retained = Directory(p.join(suiteRoot.path, 'gsy-forged'))
        ..createSync();
      _writeRootPackageRepository(retained);
      for (final path in _gsyArbPaths) {
        final file = File(_rootPath(retained, path));
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(_duplicateArb);
      }
      final revision = _commitFixtureRepository(retained);
      final embedded = _syntheticNormalizationManifest(revision);
      final manifestDirectory = Directory(
        p.join(suiteRoot.path, 'forged-manifest'),
      )..createSync();
      File(
        p.join(manifestDirectory.path, 'gsy-normalized-family-v2.json'),
      ).writeAsStringSync('{}\n');
      final forgedProject = _rootProject(
        id: 'gsy',
        revision: revision,
        arbPathsRelative: _gsyArbPaths,
        normalizationOverlays: [
          L10nNormalizationOverlay(
            manifest: 'gsy-normalized-family-v2.json',
            policy: 'apply-declared-byte-transforms',
            normalizationManifest: embedded,
          ),
        ],
      );
      final runner = _CorpusProcessRunner();

      final result =
          await DefaultCorpusProjectViewFactory(
            processRunner: runner,
            manifestDirectory: manifestDirectory,
          ).create(
            project: forgedProject,
            retainedRepositoryPath: retained.path,
            canonicalFlutterExecutable: canonicalFlutter.path,
          );

      expect(result, isA<CorpusProjectViewRejected>());
      expect(
        runner.flutterInvocations.where(
          (entry) => entry.arguments.firstOrNull == 'pub',
        ),
        isEmpty,
      );
    });
  });

  group('CorpusVerificationPolicyValidator', () {
    test(
      'rejects traversal, resolution, shells, wrappers, and missing no-pub',
      () {
        final validator = const CorpusVerificationPolicyValidator();

        for (final invalid in <({String cwd, List<String> argv})>[
          (cwd: '../escape', argv: const ['analyze', '--no-pub']),
          (cwd: '/tmp', argv: const ['test', '--no-pub']),
          (cwd: '.', argv: const ['analyze']),
          (cwd: '.', argv: const ['pub', 'get', '--offline']),
          (cwd: '.', argv: const ['fvm', 'flutter', 'test', '--no-pub']),
          (cwd: '.', argv: const ['sh', '-c', 'flutter test --no-pub']),
          (cwd: '.', argv: const ['test', '--no-pub', '&&', 'echo']),
          (cwd: '.', argv: const ['test', '--no-pub', '/tmp/escape_test.dart']),
          (cwd: '.', argv: const ['test', '--no-pub', r'C:\escape']),
          (cwd: '.', argv: const ['test', '--no-pub', r'\\server\share']),
          (cwd: '.', argv: const ['test', '--no-pub', 'file:///tmp/input']),
          (cwd: '.', argv: const ['test', '--no-pub', 'file:/tmp/input']),
          (cwd: '.', argv: const ['test', '--no-pub', 'file:%2F%2Ftmp']),
          (cwd: '.', argv: const ['test', '--no-pub', '../outside']),
          (cwd: '.', argv: const ['test', '--no-pub', r'..\outside']),
          (cwd: '.', argv: const ['test', '--no-pub', '--output=/tmp/out']),
          (cwd: '.', argv: const ['test', '--no-pub', '--foo=../outside']),
          (cwd: '.', argv: const ['test', '--no-pub', '~/outside']),
          (cwd: '.', argv: const ['test', '--', '--no-pub']),
          (cwd: '.', argv: const ['test', '--no-pub', '--pub']),
          (cwd: '.', argv: const ['test', '--no-pub', '--pub=true']),
        ]) {
          expect(
            () => validator.validateRaw(
              workingDirectoryRelativeToRepository: invalid.cwd,
              argumentsAfterCanonicalFlutter: invalid.argv,
            ),
            throwsArgumentError,
            reason: '${invalid.cwd} ${invalid.argv}',
          );
        }

        expect(
          () => validator.validateRaw(
            workingDirectoryRelativeToRepository: '.',
            argumentsAfterCanonicalFlutter: const ['build', 'apk', '--no-pub'],
          ),
          returnsNormally,
        );
      },
    );
  });

  group('CorpusMutationEvidenceOutcome', () {
    test(
      'rejects empty, unknown, leaking, and status-inconsistent evidence',
      () {
        final passed = _processEvidence(status: 'passed', exitCode: 0);
        final gate = <String, Object?>{
          'identity': _hashA,
          'status': 'installFailed',
        };

        for (final invalid
            in <
              ({
                CorpusMutationEvidenceStatus status,
                List<Map<String, Object?>> results,
              })
            >[
              (status: CorpusMutationEvidenceStatus.passed, results: const []),
              (status: CorpusMutationEvidenceStatus.passed, results: [gate]),
              (
                status: CorpusMutationEvidenceStatus.fullPolicyFailed,
                results: [passed],
              ),
              (
                status: CorpusMutationEvidenceStatus.provisioningFailed,
                results: [
                  <String, Object?>{
                    'identity': _hashA,
                    'status': 'provisioningFailed',
                    'stdoutText': 'SECRET_TOKEN',
                  },
                ],
              ),
              (
                status: CorpusMutationEvidenceStatus.provisioningFailed,
                results: [
                  <String, Object?>{
                    'identity': _hashA,
                    'status': '/private/corpus/path',
                  },
                ],
              ),
            ]) {
          expect(
            () => _evidenceOutcome(
              status: invalid.status,
              commandResults: invalid.results,
            ),
            throwsArgumentError,
            reason: '${invalid.status} ${invalid.results}',
          );
        }
      },
    );

    test('accepts every internally emitted closed gate status', () {
      for (final status in const <String>[
        'checkoutRevisionDrift',
        'cleanupFailed',
        'cloneRetainedAuthority',
        'cloneSharesObjectAuthority',
        'installFailed',
        'managedAuthorityDrift',
        'nonZeroExit',
        'overlayTargetDrift',
        'outputTruncated',
        'processInfrastructureFailure',
        'protectedAuthorityDrift',
        'provisioningFailed',
        'pubSourceDrift',
        'repositoryRevisionDrift',
        'restorationFailed',
        'retainedRepositoryDrift',
        'sourceDrift',
        'terminationUnconfirmed',
        'timedOut',
        'toolchainDrift',
        'view-busy-or-poisoned',
        'viewIdentityDrift',
      ]) {
        expect(
          () => _evidenceOutcome(
            status: CorpusMutationEvidenceStatus.provisioningFailed,
            commandResults: [
              <String, Object?>{'identity': _hashA, 'status': status},
            ],
          ),
          returnsNormally,
          reason: status,
        );
      }
    });
  });

  group('DefaultCorpusMutationEvidenceRunner', () {
    test('a disposing view rejects a concurrent run atomically', () async {
      final lease = _BlockingLease();
      final view = CorpusProjectView(
        repositoryRoot: retainedRepository,
        packageRoot: Directory(
          p.join(retainedRepository.path, 'packages', 'smooth_app'),
        ),
        repositoryRevision: repositoryRevision,
        provisionedBaselineFingerprint: _hashA,
        baselineGitStatusIdentity: _hashB,
        cleanupLease: lease,
      );
      final disposing = view.dispose();
      await lease.started.future;

      final outcome =
          await DefaultCorpusMutationEvidenceRunner(
            processRunner: _CorpusProcessRunner(),
          ).run(
            project: project,
            view: view,
            canonicalFlutterExecutable: canonicalFlutter.path,
            changeSet: _changeSet(retainedRepository),
            candidateIdentity: '${_candidateIdentity}_disposing',
            familyIdentity: _familyIdentity,
          );

      expect(outcome.status, CorpusMutationEvidenceStatus.provisioningFailed);
      expect(outcome.commandResults.single['status'], 'view-busy-or-poisoned');
      lease.release.complete();
      expect(await disposing, isTrue);
      expect(await view.dispose(), isTrue);
    });

    test('rejects an empty change set before claiming the view', () async {
      final scenario = await _provision(
        project: project,
        retainedRepository: retainedRepository,
        canonicalFlutter: canonicalFlutter,
      );
      addTearDown(() async {
        await scenario.view.dispose();
      });

      expect(
        () =>
            DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: L10nWitnessedChangeSet(
                arbReplacements: const {},
                generatedReplacements: const {},
              ),
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            ),
        throwsArgumentError,
      );

      final valid = await _runScenario(scenario, project, canonicalFlutter);
      expect(valid.status, CorpusMutationEvidenceStatus.passed);
    });

    test(
      'rejects generated-only and authority replacements before claiming the view',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final valid = _changeSet(scenario.view.repositoryRoot);
        final gitConfig = File(
          p.join(scenario.view.repositoryRoot.path, '.git', 'config'),
        );
        final configBefore = gitConfig.readAsBytesSync();
        final configMode = _posix ? gitConfig.statSync().mode & 0xfff : null;
        final configReplacement = L10nFileReplacement(
          relativePath: '.git/config',
          beforeBytes: ImmutableBytes.copyOf(configBefore),
          afterBytes: ImmutableBytes.copyOf([...configBefore, 0x0a]),
          beforeMode: configMode,
          afterMode: configMode,
        );

        for (final invalid in [
          L10nWitnessedChangeSet(
            arbReplacements: const {},
            generatedReplacements: valid.generatedReplacements,
          ),
          L10nWitnessedChangeSet(
            arbReplacements: {'.git/config': configReplacement},
            generatedReplacements: const {},
          ),
        ]) {
          await expectLater(
            DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: invalid,
              candidateIdentity: '${_candidateIdentity}_${invalid.fingerprint}',
              familyIdentity: _familyIdentity,
            ),
            throwsArgumentError,
          );
        }

        expect(gitConfig.readAsBytesSync(), configBefore);
        final outcome = await _runScenario(scenario, project, canonicalFlutter);
        expect(outcome.status, CorpusMutationEvidenceStatus.passed);
      },
    );

    test(
      'installs defensively, runs the full policy sequentially, and restores',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final changeSet = _changeSet(scenario.view.repositoryRoot);
        final originalArb = _fileState(scenario.view.repositoryRoot, _arbPath);
        final originalGenerated = _fileState(
          scenario.view.repositoryRoot,
          _generatedPath,
        );

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: changeSet,
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.passed);
        expect(outcome.installedChangeSetHash, changeSet.fingerprint);
        expect(outcome.restorationVerified, isTrue);
        expect(
          outcome.beforeManagedFingerprint,
          outcome.afterManagedFingerprint,
        );
        expect(_fileState(scenario.view.repositoryRoot, _arbPath), originalArb);
        expect(
          _fileState(scenario.view.repositoryRoot, _generatedPath),
          originalGenerated,
        );
        expect(
          scenario.processRunner.policyInvocations.map(
            (entry) => entry.arguments.first,
          ),
          ['analyze', 'test'],
        );
        expect(outcome.commandResults, hasLength(2));
        expect(
          outcome.commandResults.map((entry) => entry['identity']),
          project.verificationPolicy.map((entry) => entry.identity),
        );
        _expectRedacted(outcome.commandResults, suiteRoot.path);
        expect(
          () => outcome.commandResults.add(const {'leak': true}),
          throwsUnsupportedError,
        );
        expect(
          () => outcome.commandResults.first['leak'] = true,
          throwsUnsupportedError,
        );
      },
    );

    test(
      'preflights every before byte and mode before the first write',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final changeSet = _changeSet(scenario.view.repositoryRoot);
        final arbBefore = _fileState(scenario.view.repositoryRoot, _arbPath);
        final generated = File(
          _rootPath(scenario.view.repositoryRoot, _generatedPath),
        )..writeAsStringSync('source drift\n');

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: changeSet,
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(_fileState(scenario.view.repositoryRoot, _arbPath), arbBefore);
        expect(generated.readAsStringSync(), 'source drift\n');
        expect(scenario.processRunner.policyInvocations, isEmpty);
        expect(outcome.commandResults.single['status'], 'sourceDrift');
      },
    );

    test(
      'rejects pre-run Git authority drift before any process invocation',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final gitCount = scenario.processRunner.gitInvocations.length;
        final flutterCount = scenario.processRunner.flutterInvocations.length;
        File(
          p.join(scenario.view.repositoryRoot.path, '.git', 'config'),
        ).writeAsStringSync('[core]\n\tbare = true\n');

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.commandResults.single['status'], 'sourceDrift');
        expect(scenario.processRunner.gitInvocations, hasLength(gitCount));
        expect(
          scenario.processRunner.flutterInvocations,
          hasLength(flutterCount),
        );
        expect(await scenario.view.dispose(), isTrue);
      },
    );

    test(
      'journals a mid-write exception and restores every touched path in reverse',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final changeSet = _changeSet(scenario.view.repositoryRoot);
        final delegate = const DefaultCorpusManagedFileOperations();
        final operations = _FaultingFileOperations(
          delegate,
          throwAfterCandidatePath: _generatedPath,
        );

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
              fileOperations: operations,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: changeSet,
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.fullPolicyFailed);
        expect(outcome.restorationVerified, isTrue);
        expect(operations.restoredPaths, [_generatedPath, _arbPath]);
        expect(scenario.processRunner.policyInvocations, isEmpty);
        _expectBeforeFiles(scenario.view.repositoryRoot);
      },
    );

    test(
      'a failed command still runs the remaining policy and restores',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          policyExitCodes: const {'analyze': 1},
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.fullPolicyFailed);
        expect(outcome.restorationVerified, isTrue);
        expect(
          scenario.processRunner.policyInvocations.map(
            (entry) => entry.arguments.first,
          ),
          ['analyze', 'test'],
        );
        expect(outcome.commandResults.first['status'], 'nonZeroExit');
        expect(outcome.commandResults.last['status'], 'passed');
        _expectBeforeFiles(scenario.view.repositoryRoot);
      },
    );

    test(
      'confirmed timeout and truncation reject but restore exact bytes',
      () async {
        for (final fault in const [
          _PolicyFault.timeout,
          _PolicyFault.truncated,
        ]) {
          final scenario = await _provision(
            project: project,
            retainedRepository: retainedRepository,
            canonicalFlutter: canonicalFlutter,
            policyFault: fault,
          );
          addTearDown(() async {
            await scenario.view.dispose();
          });

          final outcome = await _runScenario(
            scenario,
            project,
            canonicalFlutter,
            candidateIdentity: '${_candidateIdentity}_${fault.name}',
          );

          expect(
            outcome.status,
            CorpusMutationEvidenceStatus.fullPolicyFailed,
            reason: fault.name,
          );
          expect(outcome.restorationVerified, isTrue, reason: fault.name);
          expect(
            outcome.commandResults.first['status'],
            fault == _PolicyFault.timeout ? 'timedOut' : 'outputTruncated',
          );
          _expectBeforeFiles(scenario.view.repositoryRoot);
        }
      },
    );

    test(
      'unconfirmed termination poisons the view and never races restoration',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          policyFault: _PolicyFault.unconfirmed,
        );
        final changeSet = _changeSet(scenario.view.repositoryRoot);

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: changeSet,
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.restorationVerified, isFalse);
        expect(scenario.view.isPoisoned, isTrue);
        expect(await scenario.view.dispose(), isFalse);
        expect(
          File(
            _rootPath(scenario.view.repositoryRoot, _arbPath),
          ).readAsStringSync(),
          _afterArb,
        );
        expect(
          outcome.commandResults.single['status'],
          'terminationUnconfirmed',
        );
        _expectRedacted(outcome.commandResults, suiteRoot.path);
      },
    );

    test(
      'unconfirmed termination cannot fall through when fingerprinting fails',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          policyFault: _PolicyFault.unconfirmed,
          breakManagedFingerprintOnUnconfirmed: true,
        );
        addTearDown(() {
          final ownedRoot = scenario.view.repositoryRoot.parent;
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
        });
        final operations = _FaultingFileOperations(
          const DefaultCorpusManagedFileOperations(),
        );

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
              fileOperations: operations,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: _changeSet(scenario.view.repositoryRoot),
              candidateIdentity: '${_candidateIdentity}_fingerprint',
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.restorationVerified, isFalse);
        expect(operations.restoredPaths, isEmpty);
        expect(scenario.view.isPoisoned, isTrue);
        expect(await scenario.view.dispose(), isFalse);
      },
    );

    test(
      'unconfirmed post-install Git status never starts restoration',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() {
          final ownedRoot = scenario.view.repositoryRoot.parent;
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
        });
        scenario.processRunner.armUnconfirmedGitStatus(occurrence: 2);
        final operations = _FaultingFileOperations(
          const DefaultCorpusManagedFileOperations(),
        );

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
              fileOperations: operations,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: _changeSet(scenario.view.repositoryRoot),
              candidateIdentity: '${_candidateIdentity}_git_unconfirmed',
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(
          outcome.commandResults.single['status'],
          'terminationUnconfirmed',
        );
        expect(operations.restoredPaths, isEmpty);
        expect(scenario.view.isPoisoned, isTrue);
        expect(await scenario.view.dispose(), isFalse);
        expect(
          File(
            _rootPath(scenario.view.repositoryRoot, _arbPath),
          ).readAsStringSync(),
          _afterArb,
        );
      },
    );

    test('restoration failure overrides an earlier policy failure', () async {
      final scenario = await _provision(
        project: project,
        retainedRepository: retainedRepository,
        canonicalFlutter: canonicalFlutter,
        policyExitCodes: const {'analyze': 1},
      );
      addTearDown(() async {
        // Test cleanup is intentionally independent from the production lease.
        final ownedRoot = scenario.view.repositoryRoot.parent;
        if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
      });
      final operations = _FaultingFileOperations(
        const DefaultCorpusManagedFileOperations(),
        throwBeforeRestorePath: _arbPath,
      );

      final outcome =
          await DefaultCorpusMutationEvidenceRunner(
            processRunner: scenario.processRunner,
            fileOperations: operations,
          ).run(
            project: project,
            view: scenario.view,
            canonicalFlutterExecutable: canonicalFlutter.path,
            changeSet: _changeSet(scenario.view.repositoryRoot),
            candidateIdentity: _candidateIdentity,
            familyIdentity: _familyIdentity,
          );

      expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
      expect(outcome.restorationVerified, isFalse);
      expect(
        outcome.commandResults.any(
          (entry) => entry['status'] == 'restorationFailed',
        ),
        isTrue,
      );
    });

    test(
      'protected lock drift during policy is restoration-authoritative',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          mutateProtectedAuthority: true,
        );
        addTearDown(() async {
          final ownedRoot = scenario.view.repositoryRoot.parent;
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
        });

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.restorationVerified, isFalse);
        expect(
          outcome.commandResults.any(
            (entry) => entry['status'] == 'protectedAuthorityDrift',
          ),
          isTrue,
        );
      },
    );

    test(
      'ignored resolution authority drift is restoration-authoritative',
      () async {
        late _ProvisionedScenario scenario;
        scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          onPubGet: (packageRoot) {
            final graph = File(
              p.join(packageRoot.path, '.dart_tool', 'package_graph.json'),
            );
            graph.parent.createSync(recursive: true);
            graph.writeAsStringSync('{"packages":[]}\n');
          },
          onFirstPolicy: (_) {
            File(
              p.join(
                scenario.view.packageRoot.path,
                '.dart_tool',
                'package_graph.json',
              ),
            ).writeAsStringSync('{"drift":true}\n');
          },
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.restorationVerified, isFalse);
        expect(
          outcome.commandResults.any(
            (entry) => entry['status'] == 'protectedAuthorityDrift',
          ),
          isTrue,
        );
        expect(await scenario.view.dispose(), isTrue);
      },
    );

    test(
      'cleanup marker drift cannot pass or delete through the lease',
      () async {
        late _ProvisionedScenario scenario;
        scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          onFirstPolicy: (_) {
            File(
              p.join(
                scenario.view.repositoryRoot.parent.path,
                '.flutter-pruner-corpus-owner',
              ),
            ).writeAsStringSync('forged marker\n');
          },
        );
        addTearDown(() {
          final ownedRoot = scenario.view.repositoryRoot.parent;
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
        });

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.restorationVerified, isFalse);
        expect(
          outcome.commandResults.any(
            (entry) => entry['status'] == 'protectedAuthorityDrift',
          ),
          isTrue,
        );
        expect(await scenario.view.dispose(), isFalse);
      },
    );

    test(
      'repository-root symlink drift poisons without restoring outside',
      () async {
        if (!_posix) return;
        final external = Directory.systemTemp.createTempSync(
          'flutter-pruner-corpus-external-',
        );
        final outsideArb = File(_rootPath(external, _arbPath));
        final outsideGenerated = File(_rootPath(external, _generatedPath));
        outsideArb.parent.createSync(recursive: true);
        outsideArb.writeAsStringSync('outside-arb\n');
        outsideGenerated.parent.createSync(recursive: true);
        outsideGenerated.writeAsStringSync('outside-generated\n');
        late _ProvisionedScenario scenario;
        late Directory displacedRepository;
        scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          onFirstPolicy: (_) {
            final repository = scenario.view.repositoryRoot;
            displacedRepository = Directory('${repository.path}.displaced');
            repository.renameSync(displacedRepository.path);
            Link(repository.path).createSync(external.path);
          },
        );
        final ownedRoot = scenario.view.repositoryRoot.parent;
        addTearDown(() {
          if (FileSystemEntity.typeSync(
                scenario.view.repositoryRoot.path,
                followLinks: false,
              ) ==
              FileSystemEntityType.link) {
            Link(scenario.view.repositoryRoot.path).deleteSync();
          }
          if (displacedRepository.existsSync()) {
            displacedRepository.renameSync(scenario.view.repositoryRoot.path);
          }
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
          if (external.existsSync()) external.deleteSync(recursive: true);
        });
        final operations = _FaultingFileOperations(
          const DefaultCorpusManagedFileOperations(),
        );

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
              fileOperations: operations,
            ).run(
              project: project,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: _changeSet(scenario.view.repositoryRoot),
              candidateIdentity: '${_candidateIdentity}_root_symlink',
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(operations.restoredPaths, isEmpty);
        expect(outsideArb.readAsStringSync(), 'outside-arb\n');
        expect(outsideGenerated.readAsStringSync(), 'outside-generated\n');
        expect(scenario.view.isPoisoned, isTrue);
        expect(await scenario.view.dispose(), isFalse);
      },
    );

    test(
      'a policy-mutated managed third state is still restored exactly',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
          mutateManagedAuthority: true,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });

        final outcome = await _runScenario(scenario, project, canonicalFlutter);

        expect(outcome.status, CorpusMutationEvidenceStatus.fullPolicyFailed);
        expect(outcome.restorationVerified, isTrue);
        _expectBeforeFiles(scenario.view.repositoryRoot);
      },
    );

    test('restoration detaches a same-byte managed hardlink', () async {
      if (!_posix) return;
      final external = File(p.join(suiteRoot.path, 'external-managed.arb'))
        ..writeAsStringSync(_afterArb);
      late _ProvisionedScenario scenario;
      scenario = await _provision(
        project: project,
        retainedRepository: retainedRepository,
        canonicalFlutter: canonicalFlutter,
        onFirstPolicy: (invocation) {
          final target = File(_rootPath(scenario.view.repositoryRoot, _arbPath))
            ..deleteSync();
          final linked = Process.runSync('/bin/ln', [
            external.path,
            target.path,
          ]);
          if (linked.exitCode != 0) throw StateError('hardlink fixture failed');
        },
      );
      addTearDown(() async {
        await scenario.view.dispose();
      });

      final outcome = await _runScenario(scenario, project, canonicalFlutter);

      expect(outcome.status, CorpusMutationEvidenceStatus.fullPolicyFailed);
      expect(outcome.restorationVerified, isTrue);
      expect(
        outcome.commandResults.any(
          (entry) => entry['status'] == 'managedAuthorityDrift',
        ),
        isTrue,
      );
      final target = File(_rootPath(scenario.view.repositoryRoot, _arbPath));
      expect(target.readAsStringSync(), _beforeArb);
      expect(external.readAsStringSync(), _afterArb);
      target.writeAsStringSync('detached\n');
      expect(external.readAsStringSync(), _afterArb);
    });

    test(
      'rejects a caller-swapped policy before installing any bytes',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          final ownedRoot = scenario.view.repositoryRoot.parent;
          if (ownedRoot.existsSync()) ownedRoot.deleteSync(recursive: true);
        });
        final swapped = L10nMutationProjectManifest(
          id: project.id,
          repositoryRevision: project.repositoryRevision,
          packageRootRelative: project.packageRootRelative,
          toolchainVersion: project.toolchainVersion,
          verificationPolicy: [project.verificationPolicy.last],
          arbDirectoryRelative: project.arbDirectoryRelative,
          templateArbPathRelative: project.templateArbPathRelative,
          arbPathsRelative: project.arbPathsRelative,
        );
        final arbBefore = _fileState(scenario.view.repositoryRoot, _arbPath);

        final outcome =
            await DefaultCorpusMutationEvidenceRunner(
              processRunner: scenario.processRunner,
            ).run(
              project: swapped,
              view: scenario.view,
              canonicalFlutterExecutable: canonicalFlutter.path,
              changeSet: _changeSet(scenario.view.repositoryRoot),
              candidateIdentity: _candidateIdentity,
              familyIdentity: _familyIdentity,
            );

        expect(outcome.status, CorpusMutationEvidenceStatus.restorationFailed);
        expect(outcome.commandResults.single['status'], 'viewIdentityDrift');
        expect(_fileState(scenario.view.repositoryRoot, _arbPath), arbBefore);
        expect(scenario.processRunner.policyInvocations, isEmpty);
      },
    );

    test(
      'a proven restoration permits explicit sequential warm reuse',
      () async {
        final scenario = await _provision(
          project: project,
          retainedRepository: retainedRepository,
          canonicalFlutter: canonicalFlutter,
        );
        addTearDown(() async {
          await scenario.view.dispose();
        });
        final first = await _runScenario(scenario, project, canonicalFlutter);
        final policyCount = scenario.processRunner.policyInvocations.length;

        final second = await _runScenario(
          scenario,
          project,
          canonicalFlutter,
          candidateIdentity: '${_candidateIdentity}_second',
        );

        expect(first.status, CorpusMutationEvidenceStatus.passed);
        expect(second.status, CorpusMutationEvidenceStatus.passed);
        expect(second.restorationVerified, isTrue);
        expect(
          scenario.processRunner.policyInvocations,
          hasLength(policyCount * 2),
        );
      },
    );
  });

  test(
    'corpus evidence has no dependency on production apply or quarantine',
    () {
      final source = File(
        'benchmark/accuracy/src/corpus_mutation_evidence.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('/apply/')));
      expect(source, isNot(contains('/quarantine/')));
      expect(source, isNot(contains('src/apply')));
      expect(source, isNot(contains('src/quarantine')));
    },
  );
}

const _arbPath = 'packages/smooth_app/lib/l10n/app_en.arb';
const _generatedPath = 'packages/smooth_app/lib/l10n/app_localizations.dart';
const _beforeArb = '{"alive":"Alive","dead":"Dead"}\n';
const _afterArb = '{"alive":"Alive"}\n';
const _beforeGenerated = 'String get dead => "Dead";\n';
const _afterGenerated = '// dead removed\n';
const _duplicateArb = '{"dup":"old","alive":"yes","dup":"kept","tail":"ok"}\n';
const _positionPreservingNormalizedArb =
    '{"dup":"kept","alive":"yes","tail":"ok"}\n';
const _gsyArbPaths = <String>[
  'lib/common/localization/l10n/app_en.arb',
  'lib/common/localization/l10n/app_ja.arb',
  'lib/common/localization/l10n/app_ko.arb',
  'lib/common/localization/l10n/app_zh.arb',
];
const _flutterEphemeralPaths = <String>[
  'ios/Flutter/ephemeral/flutter_lldb_helper.py',
  'ios/Flutter/ephemeral/flutter_lldbinit',
];
const _candidateIdentity =
    'candidate_0123456789abcdef0123456789abcdef0123456789abcdef';
const _familyIdentity =
    'family_0123456789abcdef0123456789abcdef0123456789abcdef';
const _hashA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _hashB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
final _sha256 = RegExp(r'^[0-9a-f]{64}$');

Map<String, Object?> _processEvidence({
  required String status,
  required int exitCode,
}) => <String, Object?>{
  'identity': _hashA,
  'status': status,
  'exitCode': exitCode,
  'timedOut': false,
  'outputTruncated': false,
  'stdoutSha256': _hashA,
  'stdoutCapturedBytes': 0,
  'stdoutOmittedBytes': 0,
  'stderrSha256': _hashB,
  'stderrCapturedBytes': 0,
  'stderrOmittedBytes': 0,
  'resourceStatus': 'unsupported',
  'resourceSampleCount': 0,
};

CorpusMutationEvidenceOutcome _evidenceOutcome({
  required CorpusMutationEvidenceStatus status,
  required List<Map<String, Object?>> commandResults,
}) => CorpusMutationEvidenceOutcome(
  status: status,
  candidateIdentity: _candidateIdentity,
  familyIdentity: _familyIdentity,
  installedChangeSetHash: _hashA,
  policyHash: _hashA,
  commandResults: commandResults,
  beforeManagedFingerprint: _hashB,
  afterManagedFingerprint: _hashB,
  restorationVerified:
      status == CorpusMutationEvidenceStatus.passed ||
      status == CorpusMutationEvidenceStatus.fullPolicyFailed,
);

L10nNormalizationManifest _syntheticNormalizationManifest(
  String revision, {
  L10nCopiedByteSpan Function(L10nCopiedByteSpan copy)? copyMutation,
  L10nNormalizedGeneratedBaseline? generatedBaseline,
}) {
  const first = '"dup":"old"';
  const effective = '"dup":"kept"';
  final firstStart = _duplicateArb.indexOf(first);
  final effectiveStart = _duplicateArb.lastIndexOf(effective);
  final removedStart = effectiveStart;
  final removedEnd = removedStart + effective.length + 1;
  final originalHash = ImmutableBytes.copyOf(
    utf8.encode(_duplicateArb),
  ).sha256Hex;
  final replacementHash = ImmutableBytes.copyOf(
    utf8.encode(_positionPreservingNormalizedArb),
  ).sha256Hex;
  final canonicalHash = ImmutableBytes.copyOf(
    utf8.encode('{"alive":"yes","dup":"kept","tail":"ok"}'),
  ).sha256Hex;
  final copy = L10nCopiedByteSpan(
    start: firstStart,
    endExclusive: firstStart + first.length,
    sourceStart: effectiveStart,
    sourceEndExclusive: effectiveStart + effective.length,
  );
  return L10nNormalizationManifest(
    schemaVersion: generatedBaseline == null ? 2 : 3,
    normalizationVersion: 'gsy-normalized-family-v2',
    repositoryRevision: revision,
    policy: 'retain-last-effective-decoded-top-level-member-at-first-position',
    sourceSha256:
        '00c994f3fa48fc40ff1a1a35e8ea3fd0011ca3801da2e75acfa297009c761c59',
    generatedBaseline: generatedBaseline,
    changedArbs: [
      for (final path in _gsyArbPaths)
        L10nNormalizedArb(
          relativePath: path,
          originalSha256: originalHash,
          replacementSha256: replacementHash,
          canonicalDecodedObjectSha256: canonicalHash,
          copiedByteSpans: [copyMutation?.call(copy) ?? copy],
          removedByteSpans: [
            L10nRemovedByteSpan(start: removedStart, endExclusive: removedEnd),
          ],
          decodedObjectEquivalent: true,
          replacementHasDuplicateDecodedKeys: false,
        ),
    ],
  );
}

Future<_ProvisionedScenario> _provision({
  required L10nMutationProjectManifest project,
  required Directory retainedRepository,
  required File canonicalFlutter,
  Map<String, int> policyExitCodes = const {},
  _PolicyFault policyFault = _PolicyFault.none,
  bool mutateProtectedAuthority = false,
  bool mutateManagedAuthority = false,
  bool breakManagedFingerprintOnUnconfirmed = false,
  void Function(_Invocation invocation)? onFirstPolicy,
  void Function(Directory packageRoot)? onPubGet,
}) async {
  final processRunner = _CorpusProcessRunner(
    policyExitCodes: policyExitCodes,
    policyFault: policyFault,
    mutateProtectedAuthority: mutateProtectedAuthority,
    mutateManagedAuthority: mutateManagedAuthority,
    breakManagedFingerprintOnUnconfirmed: breakManagedFingerprintOnUnconfirmed,
    onFirstPolicy: onFirstPolicy,
    onPubGet: onPubGet,
  );
  final creation =
      await DefaultCorpusProjectViewFactory(
        processRunner: processRunner,
      ).create(
        project: project,
        retainedRepositoryPath: retainedRepository.path,
        canonicalFlutterExecutable: canonicalFlutter.path,
      );
  expect(creation, isA<CorpusProjectViewReady>());
  return _ProvisionedScenario(
    (creation as CorpusProjectViewReady).view,
    processRunner,
  );
}

Future<CorpusMutationEvidenceOutcome> _runScenario(
  _ProvisionedScenario scenario,
  L10nMutationProjectManifest project,
  File canonicalFlutter, {
  String candidateIdentity = _candidateIdentity,
}) {
  return DefaultCorpusMutationEvidenceRunner(
    processRunner: scenario.processRunner,
  ).run(
    project: project,
    view: scenario.view,
    canonicalFlutterExecutable: canonicalFlutter.path,
    changeSet: _changeSet(scenario.view.repositoryRoot),
    candidateIdentity: candidateIdentity,
    familyIdentity: _familyIdentity,
  );
}

L10nWitnessedChangeSet _changeSet(Directory root) {
  L10nFileReplacement replacement(String path, String after) {
    final file = File(_rootPath(root, path));
    final stat = file.statSync();
    return L10nFileReplacement(
      relativePath: path,
      beforeBytes: ImmutableBytes.copyOf(file.readAsBytesSync()),
      afterBytes: ImmutableBytes.copyOf(utf8.encode(after)),
      beforeMode: _posix ? stat.mode & 0xfff : null,
      afterMode: _posix ? stat.mode & 0xfff : null,
    );
  }

  final arb = replacement(_arbPath, _afterArb);
  final generated = replacement(_generatedPath, _afterGenerated);
  return L10nWitnessedChangeSet(
    arbReplacements: {arb.relativePath: arb},
    generatedReplacements: {generated.relativePath: generated},
  );
}

void _expectBeforeFiles(Directory root) {
  expect(File(_rootPath(root, _arbPath)).readAsStringSync(), _beforeArb);
  expect(
    File(_rootPath(root, _generatedPath)).readAsStringSync(),
    _beforeGenerated,
  );
}

void _writeFlutterEphemeralOutputs(Directory packageRoot) {
  for (final path in _flutterEphemeralPaths) {
    final file = File(_rootPath(packageRoot, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('generated $path\n');
  }
}

({String sha256, int? mode}) _fileState(Directory root, String path) {
  final file = File(_rootPath(root, path));
  return (
    sha256: ImmutableBytes.copyOf(file.readAsBytesSync()).sha256Hex,
    mode: _posix ? file.statSync().mode & 0xfff : null,
  );
}

void _writeFixtureRepository(Directory root) {
  void write(String path, String source) {
    final file = File(_rootPath(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  write('packages/smooth_app/pubspec.yaml', 'name: smooth_app\n');
  write('packages/smooth_app/pubspec.lock', 'packages: {}\n');
  write('packages/smooth_app/l10n.yaml', 'arb-dir: lib/l10n\n');
  write(_arbPath, _beforeArb);
  write(
    'packages/smooth_app/lib/l10n/app_fr.arb',
    '{"alive":"Vivant","dead":"Mort"}\n',
  );
  write(_generatedPath, _beforeGenerated);
  write('README.md', 'retained fixture\n');
  write(
    '.gitignore',
    '.dart_tool/\n.flutter-plugins\n.flutter-plugins-dependencies\n',
  );
}

void _writeRootPackageRepository(Directory root) {
  void write(String path, String source) {
    final file = File(_rootPath(root, path));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(source);
  }

  write('pubspec.yaml', 'name: corpus_fixture\n');
  write('pubspec.lock', 'packages: {}\n');
  write('l10n.yaml', 'arb-dir: lib/l10n\n');
  write('README.md', 'retained root fixture\n');
  write(
    '.gitignore',
    '.dart_tool/\n.flutter-plugins\n.flutter-plugins-dependencies\n',
  );
}

String _commitFixtureRepository(Directory root) {
  _git(root, ['init', '-q']);
  _git(root, ['config', 'user.email', 'fixture@example.test']);
  _git(root, ['config', 'user.name', 'Fixture']);
  _git(root, ['add', '.']);
  _git(root, ['commit', '-qm', 'fixture']);
  return _gitText(root, const ['rev-parse', 'HEAD']);
}

L10nMutationProjectManifest _rootProject({
  required String id,
  required String revision,
  List<L10nFixtureOverlay> fixtureOverlays = const [],
  List<L10nNormalizationOverlay> normalizationOverlays = const [],
  List<String> arbPathsRelative = const [],
  Map<String, Object?> toolchainSelectionEvidence = const {},
}) => L10nMutationProjectManifest(
  id: id,
  repositoryRevision: revision,
  packageRootRelative: '.',
  toolchainVersion: '3.38.7',
  verificationPolicy: [
    CorpusVerificationCommand(
      workingDirectoryRelativeToRepository: '.',
      argumentsAfterCanonicalFlutter: const ['test', '--no-pub'],
    ),
  ],
  arbDirectoryRelative: arbPathsRelative.isEmpty
      ? null
      : 'lib/common/localization/l10n',
  templateArbPathRelative: arbPathsRelative.isEmpty
      ? null
      : arbPathsRelative.first,
  arbPathsRelative: arbPathsRelative,
  fixtureOverlays: fixtureOverlays,
  normalizationOverlays: normalizationOverlays,
  toolchainSelectionEvidence: toolchainSelectionEvidence,
);

void _git(Directory root, List<String> arguments) {
  final result = Process.runSync('git', arguments, workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw StateError('git fixture command failed: ${result.stderr}');
  }
}

String _gitText(Directory root, List<String> arguments) {
  final result = Process.runSync('git', arguments, workingDirectory: root.path);
  if (result.exitCode != 0) throw StateError('git fixture read failed');
  return (result.stdout as String).trim();
}

List<int> _gitStatusBytes(Directory root) {
  final result = Process.runSync(
    'git',
    const ['status', '--porcelain=v2', '-z', '--untracked-files=all'],
    workingDirectory: root.path,
    stdoutEncoding: null,
  );
  if (result.exitCode != 0) throw StateError('git status failed');
  return List<int>.unmodifiable(result.stdout as List<int>);
}

void _chmod(File file, int mode) {
  if (!_posix) return;
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8),
    file.path,
  ]);
  if (result.exitCode != 0) throw StateError('chmod fixture failed');
}

void _chmodDirectory(Directory directory, int mode) {
  if (!_posix) return;
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8),
    directory.path,
  ]);
  if (result.exitCode != 0) throw StateError('chmod directory fixture failed');
}

void _expectRedacted(Object? value, String absoluteRoot) {
  if (value is String) {
    expect(value, isNot(contains(absoluteRoot)));
    expect(value, isNot(contains(_beforeArb)));
    expect(value, isNot(contains(_afterArb)));
  } else if (value is Map) {
    for (final entry in value.entries) {
      _expectRedacted(entry.key, absoluteRoot);
      _expectRedacted(entry.value, absoluteRoot);
    }
  } else if (value is Iterable) {
    for (final entry in value) {
      _expectRedacted(entry, absoluteRoot);
    }
  }
}

bool get _posix => Platform.isLinux || Platform.isMacOS;

String _rootPath(Directory root, String relativePath) =>
    p.joinAll([root.path, ...relativePath.split('/')]);

final class _ProvisionedScenario {
  const _ProvisionedScenario(this.view, this.processRunner);

  final CorpusProjectView view;
  final _CorpusProcessRunner processRunner;
}

final class _BlockingLease implements CorpusProjectViewLease {
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> dispose() async {
    if (!started.isCompleted) started.complete();
    await release.future;
    return true;
  }
}

enum _PolicyFault { none, timeout, truncated, unconfirmed }

final class _Invocation {
  const _Invocation(this.executable, this.arguments, this.workingDirectory);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
}

final class _CorpusProcessRunner implements ProcessExecutionRunner {
  _CorpusProcessRunner({
    this.pubGetExitCode = 0,
    this.policyExitCodes = const {},
    this.policyFault = _PolicyFault.none,
    this.mutateProtectedAuthority = false,
    this.mutateManagedAuthority = false,
    this.breakManagedFingerprintOnUnconfirmed = false,
    this.onPubGet,
    this.onGenL10n,
    this.onGitInvocation,
    this.toolchainMachine,
    this.onFirstPolicy,
    this.onToolchainProbe,
  });

  final int pubGetExitCode;
  final Map<String, int> policyExitCodes;
  final _PolicyFault policyFault;
  final bool mutateProtectedAuthority;
  final bool mutateManagedAuthority;
  final bool breakManagedFingerprintOnUnconfirmed;
  final void Function(Directory packageRoot)? onPubGet;
  final void Function(Directory packageRoot)? onGenL10n;
  final void Function(_Invocation invocation)? onGitInvocation;
  final Map<String, Object?>? toolchainMachine;
  final void Function(_Invocation invocation)? onFirstPolicy;
  final void Function(int occurrence)? onToolchainProbe;
  final List<_Invocation> gitInvocations = [];
  final List<_Invocation> flutterInvocations = [];
  final List<_Invocation> policyInvocations = [];
  final ProcessExecutionRunner _delegate = const ManagedProcessRunner();
  var _faultInjected = false;
  var _toolchainProbeCount = 0;
  int? _unconfirmedGitStatusAt;
  var _armedGitStatusCount = 0;

  void armUnconfirmedGitStatus({required int occurrence}) {
    _unconfirmedGitStatusAt = occurrence;
    _armedGitStatusCount = 0;
  }

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
    final invocation = _Invocation(
      executable,
      List<String>.unmodifiable(arguments),
      workingDirectory,
    );
    if (p.basename(executable) != 'flutter') {
      gitInvocations.add(invocation);
      onGitInvocation?.call(invocation);
      if (_unconfirmedGitStatusAt != null && arguments.contains('status')) {
        _armedGitStatusCount++;
        if (_armedGitStatusCount == _unconfirmedGitStatusAt) {
          throw const ProcessTerminationUnconfirmedException(
            processId: 84,
            message: 'private git child detail',
          );
        }
      }
      return _delegate.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
        environmentOverrides: environmentOverrides,
        includeParentEnvironment: includeParentEnvironment,
      );
    }

    flutterInvocations.add(invocation);
    if (arguments case ['pub', 'get', '--offline']) {
      onPubGet?.call(Directory(workingDirectory));
      if (pubGetExitCode == 0) {
        final config = File(
          p.join(workingDirectory, '.dart_tool', 'package_config.json'),
        );
        config.parent.createSync(recursive: true);
        config.writeAsStringSync('{"configVersion":2,"packages":[]}\n');
      }
      return _processResult(exitCode: pubGetExitCode);
    }
    if (arguments case ['gen-l10n']) {
      onGenL10n?.call(Directory(workingDirectory));
      return _processResult();
    }
    if (arguments case ['--version', '--machine']) {
      _toolchainProbeCount++;
      onToolchainProbe?.call(_toolchainProbeCount);
      return _processResult(
        stdout: jsonEncode(
          toolchainMachine ??
              const <String, Object?>{
                'frameworkVersion': '3.38.7',
                'frameworkRevision': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                'engineRevision': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
                'dartSdkVersion': '3.10.7',
              },
        ),
      );
    }

    policyInvocations.add(invocation);
    if (policyInvocations.length == 1) onFirstPolicy?.call(invocation);
    if (mutateProtectedAuthority && policyInvocations.length == 1) {
      File(
        p.join(workingDirectory, 'packages', 'smooth_app', 'pubspec.lock'),
      ).writeAsStringSync('packages:\n  drift: true\n');
    }
    if (mutateManagedAuthority && policyInvocations.length == 1) {
      File(
        p.join(
          workingDirectory,
          'packages',
          'smooth_app',
          'lib',
          'l10n',
          'app_en.arb',
        ),
      ).writeAsStringSync('{"policy":"third-state"}\n');
    }
    if (!_faultInjected) {
      _faultInjected = true;
      switch (policyFault) {
        case _PolicyFault.timeout:
          return _processResult(exitCode: -1, timedOut: true);
        case _PolicyFault.truncated:
          return _processResult(stdout: 'prefix', stdoutOmittedBytes: 9);
        case _PolicyFault.unconfirmed:
          if (breakManagedFingerprintOnUnconfirmed) {
            File(
              p.join(
                workingDirectory,
                'packages',
                'smooth_app',
                'lib',
                'l10n',
                'app_en.arb',
              ),
            ).deleteSync();
          }
          throw const ProcessTerminationUnconfirmedException(
            processId: 42,
            message: 'private fixture detail',
          );
        case _PolicyFault.none:
          break;
      }
    }
    return _processResult(exitCode: policyExitCodes[arguments.first] ?? 0);
  }
}

ManagedProcessResult _processResult({
  int exitCode = 0,
  String stdout = '',
  String stderr = '',
  int stdoutOmittedBytes = 0,
  int stderrOmittedBytes = 0,
  bool timedOut = false,
}) {
  return ManagedProcessResult(
    exitCode: exitCode,
    stdout: BoundedProcessOutput(
      capturedPayload: utf8.encode(stdout),
      omittedBytes: stdoutOmittedBytes,
    ),
    stderr: BoundedProcessOutput(
      capturedPayload: utf8.encode(stderr),
      omittedBytes: stderrOmittedBytes,
    ),
    timedOut: timedOut,
  );
}

final class _FaultingFileOperations implements CorpusManagedFileOperations {
  _FaultingFileOperations(
    this.delegate, {
    this.throwAfterCandidatePath,
    this.throwBeforeRestorePath,
  });

  final CorpusManagedFileOperations delegate;
  final String? throwAfterCandidatePath;
  final String? throwBeforeRestorePath;
  final List<String> restoredPaths = [];

  @override
  Future<void> installCandidate({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  }) async {
    await delegate.installCandidate(
      repositoryRoot: repositoryRoot,
      replacement: replacement,
    );
    if (replacement.relativePath == throwAfterCandidatePath) {
      throw StateError('private install exception');
    }
  }

  @override
  Future<void> restoreBefore({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  }) async {
    restoredPaths.add(replacement.relativePath);
    if (replacement.relativePath == throwBeforeRestorePath) {
      throw StateError('private restoration exception');
    }
    await delegate.restoreBefore(
      repositoryRoot: repositoryRoot,
      replacement: replacement,
    );
  }
}
