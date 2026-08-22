import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _environmentOverrides = <String, String>{
  'CI': 'true',
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  'LANG': 'en_US.UTF-8',
  'LC_ALL': 'en_US.UTF-8',
};

const _frameworkRevision38 = '3b62efc2a3da49882f43c372e0bc53daef7295a6';
const _frameworkRevision41 = '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa';
const _frameworkRevision44 = '924134a44c189315be2148659913dda1671cbe99';
const _otherFrameworkRevision = '1111111111111111111111111111111111111111';
const _engineRevision38 = '3838383838383838383838383838383838383838';
const _engineRevision41 = '4141414141414141414141414141414141414141';
const _engineRevision44 = '4444444444444444444444444444444444444444';
const _machineFlutterRootPlaceholder = '<canonical-sdk-root>';
const _tmpdirBoundaryChild = 'FLUTTER_PRUNER_TEST_TMPDIR_BOUNDARY_CHILD';
const _tmpdirBoundaryProject = 'FLUTTER_PRUNER_TEST_TMPDIR_BOUNDARY_PROJECT';
const _tmpdirBoundaryFlutter = 'FLUTTER_PRUNER_TEST_TMPDIR_BOUNDARY_FLUTTER';

void main() {
  late Directory scratch;
  late Directory project;
  late String flutter38;
  late bool ownsScratch;

  setUp(() {
    if (Platform.environment[_tmpdirBoundaryChild] == 'true') {
      ownsScratch = false;
      project = Directory(Platform.environment[_tmpdirBoundaryProject]!);
      flutter38 = Platform.environment[_tmpdirBoundaryFlutter]!;
      scratch = Directory(p.dirname(project.path));
      return;
    }
    ownsScratch = true;
    scratch = Directory.systemTemp.createTempSync('l10n-toolchain-test-');
    project = Directory(p.join(scratch.path, 'project'))..createSync();
    flutter38 = _createFlutterSdk(scratch, 'sdk-3.38.7');
  });

  tearDown(() {
    if (ownsScratch && scratch.existsSync()) {
      scratch.deleteSync(recursive: true);
    }
  });

  group('project selector resolution', () {
    setUp(_requirePosixResolverHost);
    test(
      'launches one bundled Dart snapshot probe in an isolated sandbox',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        final resolved = resolution as L10nToolchainResolved;
        final sdkRoot = p.dirname(p.dirname(flutter38));
        expect(runner.calls, hasLength(1));
        final call = runner.calls.single;
        expect(
          call.executable,
          p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', 'dart'),
        );
        expect(call.arguments, [
          '--packages=${p.join(sdkRoot, 'packages', 'flutter_tools', '.dart_tool', 'package_config.json')}',
          p.join(sdkRoot, 'bin', 'cache', 'flutter_tools.snapshot'),
          '--version',
          '--machine',
        ]);
        expect(call.includeParentEnvironment, isFalse);
        expect(call.environmentOverrides.keys.toSet(), {
          'CI',
          'FLUTTER_SUPPRESS_ANALYTICS',
          'LANG',
          'LC_ALL',
          'FLUTTER_ROOT',
          'FLUTTER_ALREADY_LOCKED',
          'HOME',
          'XDG_CONFIG_HOME',
          'PUB_CACHE',
          'TMPDIR',
          'PATH',
        });
        expect(call.environmentOverrides['FLUTTER_ROOT'], sdkRoot);
        expect(call.environmentOverrides['FLUTTER_ALREADY_LOCKED'], 'true');
        expect(call.sandboxObservation, isNotNull);
        final sandbox = call.sandboxObservation!;
        expect(sandbox.whichBytes, '#!/bin/sh\nexit 1\n'.codeUnits);
        expect(sandbox.whichExecutable, isTrue);
        expect(sandbox.allOwnedDirectoriesPresent, isTrue);
        expect(Directory(sandbox.root).existsSync(), isFalse);
        expect(resolved.originalSelectionProbeSha256, matches(_sha256Pattern));
      },
    );

    test(
      'generation uses the same frozen direct-snapshot sandbox seam',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
          _ProcessReply.result(_successfulProbe(const [])),
        ]);
        final resolved =
            (await _resolve38(project, flutter38, runner))
                as L10nToolchainResolved;

        final result = await resolved.launch.runGeneration(
          processRunner: runner,
          workingDirectory: project,
          expected: resolved,
          logicalArguments: resolved.generationArgs,
          timeout: const Duration(minutes: 2),
          maxOutputBytesPerStream: 4242,
        );

        expect(result.exitCode, 0);
        expect(runner.calls, hasLength(2));
        final probe = runner.calls.first;
        final generation = runner.calls.last;
        expect(generation.timeout, const Duration(minutes: 2));
        expect(generation.maxOutputBytesPerStream, 4242);
        expect(generation.executable, probe.executable);
        expect(generation.arguments, [...probe.arguments.take(2), 'gen-l10n']);
        expect(generation.includeParentEnvironment, isFalse);
        expect(generation.sandboxObservation, isNotNull);
        expect(
          generation.sandboxObservation!.root,
          isNot(probe.sandboxObservation!.root),
        );
        expect(
          Directory(generation.sandboxObservation!.root).existsSync(),
          isFalse,
        );
      },
    );

    test(
      'generation seam rejects logical argv outside frozen evidence',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);
        final resolved =
            (await _resolve38(project, flutter38, runner))
                as L10nToolchainResolved;

        await expectLater(
          resolved.launch.runGeneration(
            processRunner: runner,
            workingDirectory: project,
            expected: resolved,
            logicalArguments: const ['gen-l10n', '--forged'],
            timeout: const Duration(minutes: 2),
            maxOutputBytesPerStream: 4242,
          ),
          throwsA(
            isA<L10nToolchainLaunchException>().having(
              (error) => error.detailCode,
              'detailCode',
              'frozen-command-drift',
            ),
          ),
        );
        expect(runner.calls, hasLength(1));
      },
    );

    test('generation seam maps an unexpected prelaunch error', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);
      final resolved =
          (await _resolve38(project, flutter38, runner))
              as L10nToolchainResolved;

      await expectLater(
        resolved.launch.runGeneration(
          processRunner: runner,
          workingDirectory: project,
          expected: resolved,
          logicalArguments: _ThrowingStringList(),
          timeout: const Duration(minutes: 2),
          maxOutputBytesPerStream: 4242,
        ),
        throwsA(
          isA<L10nToolchainLaunchException>().having(
            (error) => error.detailCode,
            'detailCode',
            'generation-run-unexpected-failure',
          ),
        ),
      );
      expect(runner.calls, hasLength(1));
    });

    for (final policy in const [
      (Duration.zero, 4242),
      (Duration(minutes: 2), -1),
    ]) {
      test('generation seam rejects invalid process policy $policy', () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);
        final resolved =
            (await _resolve38(project, flutter38, runner))
                as L10nToolchainResolved;

        await expectLater(
          resolved.launch.runGeneration(
            processRunner: runner,
            workingDirectory: project,
            expected: resolved,
            logicalArguments: resolved.generationArgs,
            timeout: policy.$1,
            maxOutputBytesPerStream: policy.$2,
          ),
          throwsA(
            isA<L10nToolchainLaunchException>().having(
              (error) => error.detailCode,
              'detailCode',
              'generation-run-policy-invalid',
            ),
          ),
        );
        expect(runner.calls, hasLength(1));
      });
    }

    for (final drift in [
      'bundled Dart bytes',
      'Flutter tools snapshot bytes',
      'package config authority bytes',
      'Flutter provenance bytes',
      'Git HEAD authority representation',
    ]) {
      test('generation rejects post-resolution $drift before launch', () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
          _ProcessReply.result(_successfulProbe(const [])),
        ]);
        final resolved =
            (await _resolve38(project, flutter38, runner))
                as L10nToolchainResolved;
        switch (drift) {
          case 'bundled Dart bytes':
            final dart = File(resolved.launch.canonicalDartExecutable)
              ..writeAsStringSync('replacement Dart fixture\n');
            _makeExecutable(dart);
          case 'Flutter tools snapshot bytes':
            File(
              resolved.launch.canonicalFlutterToolsSnapshot,
            ).writeAsStringSync('replacement snapshot fixture\n');
          case 'package config authority bytes':
            final packageConfig = File(
              resolved.launch.canonicalFlutterToolsPackageConfig,
            );
            packageConfig.writeAsBytesSync([
              ...packageConfig.readAsBytesSync(),
              0x20,
            ]);
          case 'Flutter provenance bytes':
            final flutter = File(resolved.canonicalFlutterExecutable)
              ..writeAsStringSync('replacement Flutter provenance\n');
            _makeExecutable(flutter);
          case 'Git HEAD authority representation':
            _sdkGitFile(
              resolved.canonicalFlutterExecutable,
              'HEAD',
            ).writeAsStringSync('$_frameworkRevision38\n');
        }

        await expectLater(
          resolved.launch.runGeneration(
            processRunner: runner,
            workingDirectory: project,
            expected: resolved,
            logicalArguments: resolved.generationArgs,
            timeout: const Duration(minutes: 2),
            maxOutputBytesPerStream: 4242,
          ),
          throwsA(
            isA<L10nToolchainLaunchException>().having(
              (error) => error.detailCode,
              'detailCode',
              'generation-toolchain-drift',
            ),
          ),
        );
        expect(runner.calls, hasLength(1));
      });
    }

    test('rejects a missing version cache control before launch', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      _sdkArtifact(flutter38, 'bin/cache/flutter.version.json').deleteSync();
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-version-control-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects Dart version cache mismatch before launch', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      _sdkArtifact(
        flutter38,
        'bin/cache/dart-sdk/version',
      ).writeAsStringSync('0.0.0\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-dart-version-mismatch',
      );
      expect(runner.calls, isEmpty);
    });

    test('matches root .fvmrc to the canonical direct probe', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);

      final resolution = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
        selection: const ProjectSelectorSelection(),
      );

      final resolved = resolution as L10nToolchainResolved;
      expect(resolved.canonicalFlutterExecutable, flutter38);
      expect(
        resolved.canonicalSdkRoot,
        Directory(p.dirname(p.dirname(flutter38))).resolveSymbolicLinksSync(),
      );
      expect(resolved.selection, isA<ProjectSelectorSelection>());
      expect(resolved.generationArgs, ['gen-l10n']);
      expect(resolved.directProbeArgs, ['--version', '--machine']);
      expect(resolved.environmentOverrides, {
        ..._environmentOverrides,
        'FLUTTER_ROOT': resolved.canonicalSdkRoot,
        'FLUTTER_ALREADY_LOCKED': 'true',
      });
      expect(resolved.selectorHashesByRelativePath.keys, ['.fvmrc']);
      expect(
        resolved.selectorHashesByRelativePath['.fvmrc'],
        sha256.convert(_fixtureBytes('fvmrc/.fvmrc')).toString(),
      );
      expect(resolved.machineIdentity.frameworkVersion, Version(3, 38, 7));
      expect(resolved.machineIdentity.frameworkRevision, _frameworkRevision38);
      expect(resolved.machineIdentity.engineRevision, _engineRevision38);
      expect(resolved.machineIdentity.dartSdkVersion, '3.10.7');
      expect(resolved.originalSelectionProbeSha256, matches(_sha256Pattern));
      expect(resolved.identitySha256, matches(_sha256Pattern));

      expect(runner.calls, hasLength(1));
      _expectDirectCall(
        runner.calls.single,
        canonicalFlutter: flutter38,
        logicalArguments: ['--version', '--machine'],
        project: project,
      );
    });

    test('supports the legacy .fvm/fvm_config.json selector', () async {
      _installFixture(
        project,
        'fvm_config/.fvm/fvm_config.json',
        '.fvm/fvm_config.json',
      );
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final machineBytes = _fixtureBytes('machine/flutter_3_41_5.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
            selection: const ProjectSelectorSelection(),
          );

      final resolved = resolution as L10nToolchainResolved;
      expect(resolved.machineIdentity.frameworkVersion, Version(3, 41, 5));
      expect(resolved.selectorHashesByRelativePath.keys, [
        '.fvm/fvm_config.json',
      ]);
    });

    test('resolves the exact supported 3.44.1 toolchain', () async {
      File(
        p.join(project.path, '.fvmrc'),
      ).writeAsStringSync('{"flutter":"3.44.1"}\n');
      final flutter44 = _createFlutterSdk(scratch, 'sdk-3.44.1');
      final machineBytes = _fixtureBytes('machine/flutter_3_44_1.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 44, 1): flutter44}),
            selection: const ProjectSelectorSelection(),
          );

      final resolved = resolution as L10nToolchainResolved;
      expect(resolved.machineIdentity.frameworkVersion, Version(3, 44, 1));
      expect(resolved.canonicalFlutterExecutable, flutter44);
    });

    test('fingerprints all agreeing supported selector files', () async {
      File(p.join(project.path, '.fvmrc'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"flutter":"3.41.5"}\n');
      _installFixture(
        project,
        'fvm_config/.fvm/fvm_config.json',
        '.fvm/fvm_config.json',
      );
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final machineBytes = _fixtureBytes('machine/flutter_3_41_5.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
            selection: const ProjectSelectorSelection(),
          );

      expect(
        (resolution as L10nToolchainResolved).selectorHashesByRelativePath.keys,
        ['.fvm/fvm_config.json', '.fvmrc'],
      );
    });

    test(
      'rejects disagreement between supported selectors before probing',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        _installFixture(
          project,
          'fvm_config/.fvm/fvm_config.json',
          '.fvm/fvm_config.json',
        );
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({
                Version(3, 38, 7): flutter38,
                Version(3, 41, 5): _createFlutterSdk(scratch, 'sdk-3.41.5'),
              }),
              selection: const ProjectSelectorSelection(),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selector-version-conflict',
        );
        expect(runner.calls, isEmpty);
      },
    );

    test('rejects an unknown selector shape before probing', () async {
      _installFixture(project, 'selectors/unknown_fvmrc.json', '.fvmrc');
      final runner = _FakeProcessRunner(const []);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
            selection: const ProjectSelectorSelection(),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-shape-unknown',
        relativePath: '.fvmrc',
      );
      expect(runner.calls, isEmpty);
    });

    for (final selectorCase in [
      ('selectors/fvmrc_extra.json', '.fvmrc'),
      ('selectors/fvmrc_duplicate.json', '.fvmrc'),
      ('selectors/fvm_config_extra.json', '.fvm/fvm_config.json'),
      ('selectors/fvm_config_duplicate.json', '.fvm/fvm_config.json'),
    ]) {
      test('rejects non-exact selector shape ${selectorCase.$1}', () async {
        _installFixture(project, selectorCase.$1, selectorCase.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({
                Version(3, 38, 7): flutter38,
                Version(3, 41, 5): _createFlutterSdk(scratch, 'sdk-3.41.5'),
              }),
              selection: const ProjectSelectorSelection(),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selector-shape-unknown',
          relativePath: selectorCase.$2,
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects a final selector-file symlink', () async {
      final external = File(p.join(scratch.path, 'external.fvmrc'))
        ..writeAsBytesSync(_fixtureBytes('fvmrc/.fvmrc'));
      Link(p.join(project.path, '.fvmrc')).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-not-regular',
        relativePath: '.fvmrc',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symlinked .fvm selector path component', () async {
      final externalFvm = Directory(p.join(scratch.path, 'external-fvm'))
        ..createSync();
      File(
        p.join(externalFvm.path, 'fvm_config.json'),
      ).writeAsBytesSync(_fixtureBytes('fvm_config/.fvm/fvm_config.json'));
      Link(p.join(project.path, '.fvm')).createSync(externalFvm.path);
      final runner = _FakeProcessRunner(const []);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter38}),
            selection: const ProjectSelectorSelection(),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-path-symlink',
        relativePath: '.fvm/fvm_config.json',
      );
      expect(runner.calls, isEmpty);
    });

    for (final unsupported in ['3.38.8', '^3.38.7', '3.38.7-dev.1', '3.38']) {
      test('rejects unsupported exact selector version $unsupported', () async {
        File(
          p.join(project.path, '.fvmrc'),
        ).writeAsStringSync('{"flutter":"$unsupported"}');
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
              selection: const ProjectSelectorSelection(),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'unsupported-version',
          relativePath: '.fvmrc',
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects a missing registry mapping before probing', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final runner = _FakeProcessRunner(const []);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry(const {}),
            selection: const ProjectSelectorSelection(),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-mapping-missing',
      );
      expect(runner.calls, isEmpty);
    });

    test(
      'never trusts .fvm/flutter_sdk without a supported selector',
      () async {
        final link = Link(p.join(project.path, '.fvm', 'flutter_sdk'));
        link.parent.createSync(recursive: true);
        link.createSync(p.dirname(p.dirname(flutter38)));
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
              selection: const ProjectSelectorSelection(),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selector-missing',
        );
        expect(runner.calls, isEmpty);
      },
      skip: Platform.isWindows ? 'symlink creation is not portable' : false,
    );

    test(
      'rejects direct machine identity that differs from controls',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(
              _machineBytes(
                version: '3.38.7',
                frameworkRevision: _otherFrameworkRevision,
                engineRevision: _engineRevision38,
                dartSdkVersion: '3.10.7',
              ),
            ),
          ),
        ]);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
              selection: const ProjectSelectorSelection(),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-identity-mismatch',
        );
      },
    );
  });

  group('probe failure handling', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('rejects truncated direct output', () async {
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(
            _fixtureBytes('machine/flutter_3_38_7.json'),
            stdoutOmittedBytes: 1,
          ),
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-truncated',
      );
    });

    test('rejects a nonzero direct probe', () async {
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes, exitCode: 2)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-nonzero',
      );
    });

    test('rejects a timed-out direct probe', () async {
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes, timedOut: true)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-timeout',
      );
    });

    test(
      'rejects unconfirmed process-tree termination without exception text',
      () async {
        final runner = _FakeProcessRunner([
          _ProcessReply.error(
            const ProcessTerminationUnconfirmedException(
              processId: 987,
              message: 'host-specific failure text',
            ),
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        final sandboxRoot = runner.calls.single.sandboxObservation!.root;
        addTearDown(() {
          final sandbox = Directory(sandboxRoot);
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-termination-unconfirmed',
        );
        expect(Directory(sandboxRoot).existsSync(), isTrue);
      },
    );

    test(
      'retains a sandbox whose which authority changed after launch',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        late final _FakeProcessRunner runner;
        runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              final sandbox = runner.calls.single.sandboxObservation!;
              File(
                p.join(sandbox.root, 'bin', 'which'),
              ).writeAsStringSync('#!/bin/sh\nexit 0\n');
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        final sandboxRoot = runner.calls.single.sandboxObservation!.root;
        addTearDown(() {
          final sandbox = Directory(sandboxRoot);
          if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
        });
        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-sandbox-cleanup-unconfirmed',
        );
        expect(Directory(sandboxRoot).existsSync(), isTrue);
      },
    );

    test(
      'rejects cleanup when the original sandbox root was replaced',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        late final _FakeProcessRunner runner;
        late String displacedRoot;
        runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              final call = runner.calls.single;
              final sandbox = call.sandboxObservation!;
              displacedRoot = '${sandbox.root}-displaced';
              Directory(sandbox.root).renameSync(displacedRoot);
              Directory(sandbox.root).createSync();
              for (final key in const [
                'HOME',
                'XDG_CONFIG_HOME',
                'PUB_CACHE',
                'TMPDIR',
                'PATH',
              ]) {
                Directory(call.environmentOverrides[key]!).createSync();
              }
              final which = File(
                p.join(call.environmentOverrides['PATH']!, 'which'),
              )..writeAsStringSync('#!/bin/sh\nexit 1\n');
              final chmod = Process.runSync(
                '/bin/chmod',
                ['700', which.path],
                environment: const {'LANG': 'C', 'LC_ALL': 'C'},
                includeParentEnvironment: false,
              );
              expect(chmod.exitCode, 0);
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        final sandboxRoot = runner.calls.single.sandboxObservation!.root;
        addTearDown(() {
          for (final path in [sandboxRoot, displacedRoot]) {
            final directory = Directory(path);
            if (directory.existsSync()) directory.deleteSync(recursive: true);
          }
        });
        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-sandbox-cleanup-unconfirmed',
        );
        expect(Directory(sandboxRoot).existsSync(), isTrue);
        expect(Directory(displacedRoot).existsSync(), isTrue);
      },
    );

    test('retains a sandbox whose which exact mode changed', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      late final _FakeProcessRunner runner;
      runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(stable),
          beforeReturn: () {
            final sandbox = runner.calls.single.sandboxObservation!;
            final chmod = Process.runSync(
              '/bin/chmod',
              ['0711', p.join(sandbox.root, 'bin', 'which')],
              environment: const {'LANG': 'C', 'LC_ALL': 'C'},
              includeParentEnvironment: false,
            );
            expect(chmod.exitCode, 0);
          },
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      final sandboxRoot = runner.calls.single.sandboxObservation!.root;
      addTearDown(() {
        final sandbox = Directory(sandboxRoot);
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });
      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-sandbox-cleanup-unconfirmed',
      );
      expect(Directory(sandboxRoot).existsSync(), isTrue);
    });

    for (final boundary in const ['project', 'SDK']) {
      test(
        'rejects parent TMPDIR inside the $boundary before materialization',
        () async {
          if (Platform.environment[_tmpdirBoundaryChild] == 'true') {
            final tempRoot = Directory.systemTemp;
            final baseline = tempRoot
                .listSync()
                .map((entity) => p.basename(entity.path))
                .toSet();
            final stable = _fixtureBytes('machine/flutter_3_38_7.json');
            final runner = _FakeProcessRunner([
              _ProcessReply.result(_successfulProbe(stable)),
            ]);

            final resolution = await _resolve38(project, flutter38, runner);

            _expectRejected(
              resolution,
              code: L10nEvidenceRejectionCode.toolchainUnavailable,
              detailCode: 'direct-probe-sandbox-location-unsupported',
            );
            expect(runner.calls, isEmpty);
            expect(
              tempRoot
                  .listSync()
                  .map((entity) => p.basename(entity.path))
                  .toSet(),
              baseline,
            );
            return;
          }

          _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
          final tempRoot = boundary == 'project'
              ? project
              : (Directory(
                  p.join(
                    p.dirname(p.dirname(flutter38)),
                    'host-controlled-tmp',
                  ),
                )..createSync());
          final testName =
              'rejects parent TMPDIR inside the $boundary before materialization';
          final result = Process.runSync(
            Platform.resolvedExecutable,
            [
              'test',
              'test/adapters/l10n/action_readiness/l10n_toolchain_test.dart',
              '-n',
              testName,
            ],
            workingDirectory: Directory.current.path,
            environment: {
              ...Platform.environment,
              'TMPDIR': tempRoot.path,
              _tmpdirBoundaryChild: 'true',
              _tmpdirBoundaryProject: project.path,
              _tmpdirBoundaryFlutter: flutter38,
            },
            includeParentEnvironment: false,
            stdoutEncoding: utf8,
            stderrEncoding: utf8,
          );
          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}\n${result.stderr}',
          );
        },
      );
    }

    test(
      'rejects an unavailable direct launcher without exception text',
      () async {
        final runner = _FakeProcessRunner([
          _ProcessReply.error(
            const FileSystemException('machine-specific path'),
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-unavailable',
        );
      },
    );

    test('rejects an unconfirmed machine JSON identity', () async {
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe('{"frameworkVersion":7}'.codeUnits),
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-output-invalid',
      );
    });

    test('rejects a legacy partial machine object', () async {
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(
            ('{"frameworkVersion":"3.38.7",'
                    '"frameworkRevision":"$_frameworkRevision38",'
                    '"engineRevision":"$_engineRevision38",'
                    '"dartSdkVersion":"3.10.7"}')
                .codeUnits,
          ),
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-output-invalid',
      );
    });

    test(
      'rejects direct metadata that differs from version controls',
      () async {
        final machine = Map<String, Object?>.from(
          jsonDecode(
                String.fromCharCodes(
                  _fixtureBytes('machine/flutter_3_38_7.json'),
                ),
              )
              as Map<String, Object?>,
        )..['channel'] = 'beta';
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(jsonEncode(machine).codeUnits)),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-identity-mismatch',
        );
      },
    );

    test('rejects duplicate direct machine keys', () async {
      final duplicated = String.fromCharCodes(
        _fixtureBytes('machine/flutter_3_38_7.json'),
      ).replaceFirst('{', '{"frameworkVersion":"3.38.7",');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(duplicated.codeUnits)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-output-invalid',
      );
    });

    test('rejects null direct machine values', () async {
      final machine = Map<String, Object?>.from(
        jsonDecode(
              String.fromCharCodes(
                _fixtureBytes('machine/flutter_3_38_7.json'),
              ),
            )
            as Map<String, Object?>,
      )..['devToolsVersion'] = null;
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(jsonEncode(machine).codeUnits)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-identity-mismatch',
      );
    });

    test('rejects nonempty direct stderr', () async {
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(
            _fixtureBytes('machine/flutter_3_38_7.json'),
            stderr: 'unexpected warning\n'.codeUnits,
          ),
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-stderr-nonempty',
      );
    });
  });

  group('launch artifact validation', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('rejects a symlinked Flutter tools snapshot before probing', () async {
      final snapshot = _sdkArtifact(
        flutter38,
        'bin/cache/flutter_tools.snapshot',
      );
      final target = File(p.join(scratch.path, 'outside.snapshot'))
        ..writeAsStringSync('outside snapshot\n');
      snapshot.deleteSync();
      Link(snapshot.path).createSync(target.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-structure-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    for (final artifact in const [
      ('bin/cache/dart-sdk/bin/dart', 'registry-sdk-structure-invalid'),
      (
        'bin/cache/flutter.version.json',
        'registry-sdk-version-control-invalid',
      ),
      ('bin/cache/engine_stamp.json', 'registry-sdk-engine-stamp-invalid'),
      ('bin/cache/engine_stamp.stamp', 'registry-sdk-engine-stamp-invalid'),
      ('bin/cache/dart-sdk/version', 'registry-sdk-dart-version-mismatch'),
      (
        'packages/flutter_tools/.dart_tool/package_config.json',
        'registry-sdk-package-config-invalid',
      ),
    ]) {
      test('rejects symlinked direct authority ${artifact.$1}', () async {
        final source = _sdkArtifact(flutter38, artifact.$1);
        final outside = File(
          p.join(scratch.path, 'outside-${artifact.$1.replaceAll('/', '-')}'),
        )..writeAsBytesSync(source.readAsBytesSync());
        source.deleteSync();
        Link(source.path).createSync(outside.path);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: artifact.$2,
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects an unreadable launch artifact before probing', () async {
      final snapshot = _sdkArtifact(
        flutter38,
        'bin/cache/flutter_tools.snapshot',
      );
      final chmod = Process.runSync(
        '/bin/chmod',
        ['000', snapshot.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-artifact-unreadable',
      );
      expect(runner.calls, isEmpty);
    });
  });

  group('retained evidence selection', () {
    setUp(_requirePosixResolverHost);
    test(
      'binds valid source/probe hashes and probes only the direct snapshot',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_41_5.json');
        final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);
        const evidenceSha =
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        const probeSha =
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
              selection: RetainedEvidenceSelection(
                expectedIdentity: _identity41,
                evidenceSha256: evidenceSha,
                probeOutputSha256: probeSha,
              ),
            );

        final resolved = resolution as L10nToolchainResolved;
        expect(resolved.selection, isA<RetainedEvidenceSelection>());
        expect(resolved.selectorHashesByRelativePath, isEmpty);
        expect(resolved.originalSelectionProbeSha256, probeSha);
        expect(
          resolved.machineIdentity.frameworkRevision,
          _frameworkRevision41,
        );
        expect(runner.calls, hasLength(1));
        _expectDirectCall(
          runner.calls.single,
          canonicalFlutter: flutter41,
          logicalArguments: ['--version', '--machine'],
          project: project,
        );
      },
    );

    test('rejects retained revision that differs from registry Git HEAD', () async {
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      _sdkGitFile(
        flutter41,
        'refs/heads/stable',
      ).writeAsStringSync('$_otherFrameworkRevision\n');
      final runner = _FakeProcessRunner(const []);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
            selection: RetainedEvidenceSelection(
              expectedIdentity: _identity41,
              evidenceSha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              probeOutputSha256:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-framework-identity-mismatch',
      );
      expect(runner.calls, isEmpty);
    });

    for (final hashes in [
      (
        'short',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      (
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      (
        'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        'not-hex-not-hex-not-hex-not-hex-not-hex-not-hex-not-hex-not-hex-',
      ),
    ]) {
      test('rejects invalid retained evidence hashes ${hashes.$1}', () async {
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter38}),
              selection: RetainedEvidenceSelection(
                expectedIdentity: _identity41,
                evidenceSha256: hashes.$1,
                probeOutputSha256: hashes.$2,
              ),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'retained-evidence-invalid',
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects direct identity that differs from retained identity', () async {
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(
            _machineBytes(
              version: '3.41.5',
              frameworkRevision: _frameworkRevision41,
              engineRevision: 'different-engine',
              dartSdkVersion: '3.11.3',
            ),
          ),
        ),
      ]);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
            selection: RetainedEvidenceSelection(
              expectedIdentity: _identity41,
              evidenceSha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              probeOutputSha256:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'direct-probe-identity-mismatch',
      );
    });

    for (final version in [
      Version(3, 45, 0),
      Version.parse('3.41.5-dev.1'),
      Version.parse('3.41.5+forged'),
    ]) {
      test('classifies retained version $version as unsupported', () async {
        final runner = _FakeProcessRunner(const []);

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: L10nSdkRegistry(const {}),
              selection: RetainedEvidenceSelection(
                expectedIdentity: FlutterMachineIdentity(
                  frameworkVersion: version,
                  frameworkRevision: _otherFrameworkRevision,
                  engineRevision: '2222222222222222222222222222222222222222',
                  dartSdkVersion: 'dart-retained',
                ),
                evidenceSha256:
                    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
                probeOutputSha256:
                    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
              ),
            );

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          detailCode: 'unsupported-version',
        );
        expect(runner.calls, isEmpty);
      });
    }
  });

  group('identity and immutability', () {
    setUp(_requirePosixResolverHost);
    test('is stable across caller registry map order', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        for (var index = 0; index < 2; index++)
          _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final firstInput = <Version, String>{
        Version(3, 41, 5): flutter41,
        Version(3, 38, 7): flutter38,
      };
      final secondInput = <Version, String>{
        Version(3, 38, 7): flutter38,
        Version(3, 41, 5): flutter41,
      };

      final first = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry(firstInput),
        selection: const ProjectSelectorSelection(),
      );
      final second = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry(secondInput),
        selection: const ProjectSelectorSelection(),
      );

      expect(
        (first as L10nToolchainResolved).identitySha256,
        (second as L10nToolchainResolved).identitySha256,
      );
    });

    test(
      'copies registry input and returns sorted unmodifiable collections',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);
        final registryInput = <Version, String>{Version(3, 38, 7): flutter38};
        final registry = L10nSdkRegistry(registryInput);
        registryInput[Version(3, 38, 7)] = p.join(scratch.path, 'changed');

        final resolution =
            await DefaultL10nToolchainResolver(processRunner: runner).resolve(
              originalProjectRoot: project,
              sdkRegistry: registry,
              selection: const ProjectSelectorSelection(),
            );

        final resolved = resolution as L10nToolchainResolved;
        expect(resolved.canonicalFlutterExecutable, flutter38);
        expect(
          () => resolved.generationArgs.add('unexpected'),
          throwsUnsupportedError,
        );
        expect(
          () => resolved.directProbeArgs.add('unexpected'),
          throwsUnsupportedError,
        );
        expect(
          () => resolved.environmentOverrides['HOME'] = '/tmp/fake',
          throwsUnsupportedError,
        );
        expect(
          () => resolved.selectorHashesByRelativePath.clear(),
          throwsUnsupportedError,
        );
        expect(resolved.environmentOverrides.keys, [
          'CI',
          'FLUTTER_ALREADY_LOCKED',
          'FLUTTER_ROOT',
          'FLUTTER_SUPPRESS_ANALYTICS',
          'LANG',
          'LC_ALL',
        ]);
      },
    );

    test('changes identity for exact bounded probe output bytes', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final pretty = _fixtureBytes('machine/flutter_3_38_7.json');
      final compact = _machineBytes(
        version: '3.38.7',
        frameworkRevision: _frameworkRevision38,
        engineRevision: _engineRevision38,
        dartSdkVersion: '3.10.7',
      );
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(pretty)),
        _ProcessReply.result(_successfulProbe(compact)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);

      final first = await _resolve38(
        project,
        flutter38,
        runner,
        resolver: resolver,
      );
      final second = await _resolve38(
        project,
        flutter38,
        runner,
        resolver: resolver,
      );

      expect(
        (first as L10nToolchainResolved).identitySha256,
        isNot((second as L10nToolchainResolved).identitySha256),
      );
    });
  });

  group('SDK Git HEAD identity', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('rejects a group-writable .git authority root', () async {
      final git = _sdkGitDirectory(flutter38);
      final chmod = Process.runSync(
        '/bin/chmod',
        ['0777', git.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a group-writable Git ref ancestor before probing', () async {
      final refs = Directory(p.join(_sdkGitDirectory(flutter38).path, 'refs'));
      final chmod = Process.runSync(
        '/bin/chmod',
        ['0777', refs.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test(
      'rejects a group-writable Git ref ancestor before revalidation probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        final refs = Directory(
          p.join(_sdkGitDirectory(flutter38).path, 'refs'),
        );
        final chmod = Process.runSync(
          '/bin/chmod',
          ['0777', refs.path],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        expect(chmod.exitCode, 0);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'registry-sdk-git-ref-invalid');
        expect(runner.calls, hasLength(1));
      },
    );

    for (final unsafeLeaf in const [
      ('config', 'config', 'registry-sdk-git-config-invalid'),
      ('HEAD', 'HEAD', 'registry-sdk-git-head-invalid'),
      ('loose ref', 'refs/heads/stable', 'registry-sdk-git-ref-invalid'),
      ('packed ref', 'packed-refs', 'registry-sdk-git-ref-invalid'),
    ]) {
      test('rejects a group-writable Git ${unsafeLeaf.$1}', () async {
        if (unsafeLeaf.$1 == 'packed ref') {
          _sdkGitFile(flutter38, 'refs/heads/stable').deleteSync();
          _sdkGitFile(
            flutter38,
            'packed-refs',
          ).writeAsStringSync('$_frameworkRevision38 refs/heads/stable\n');
        }
        final leaf = _sdkGitFile(flutter38, unsafeLeaf.$2);
        final chmod = Process.runSync(
          '/bin/chmod',
          ['0666', leaf.path],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        expect(chmod.exitCode, 0);
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: unsafeLeaf.$3,
        );
        expect(runner.calls, isEmpty);
      });
    }

    test(
      'rejects exact Git leaf mode drift before revalidation probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        final head = _sdkGitFile(flutter38, 'HEAD');
        final chmod = Process.runSync(
          '/bin/chmod',
          ['0600', head.path],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        expect(chmod.exitCode, 0);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'identity-drift');
        expect(runner.calls, hasLength(1));
      },
    );

    test(
      'rejects a symbolic loose-ref change during the direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        _writeLooseGitRef(
          flutter38,
          'refs/heads/alternate',
          '$_otherFrameworkRevision\n',
        );
        final stableRef = _sdkGitFile(flutter38, 'refs/heads/stable');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              stableRef.writeAsStringSync('ref: refs/heads/alternate\n');
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
        expect(runner.calls, hasLength(1));
      },
    );

    test('rejects HEAD drift during the direct registry probe', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final head = _sdkGitFile(flutter38, 'HEAD');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(stable),
          beforeReturn: () {
            head.writeAsStringSync('$_otherFrameworkRevision\n');
          },
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'canonical-sdk-changed-during-probe',
      );
      expect(runner.calls, hasLength(1));
    });

    test(
      'rejects HEAD drift before revalidation starts another probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        _sdkGitFile(
          flutter38,
          'refs/heads/stable',
        ).writeAsStringSync('$_otherFrameworkRevision\n');

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(
          result,
          detailCode: 'registry-sdk-framework-identity-mismatch',
        );
        expect(runner.calls, hasLength(1));
      },
    );

    test('accepts and revalidates an exact detached lowercase HEAD', () async {
      _sdkGitFile(
        flutter38,
        'HEAD',
      ).writeAsStringSync('$_frameworkRevision38\n');
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        for (var index = 0; index < 2; index++)
          _ProcessReply.result(_successfulProbe(stable)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);

      final expected = await _resolved38(project, flutter38, resolver);
      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      expect(result, isA<L10nToolchainStillMatches>());
      expect(runner.calls, hasLength(2));
    });

    test('accepts an exact symbolic loose-ref chain', () async {
      _sdkGitFile(
        flutter38,
        'refs/heads/stable',
      ).writeAsStringSync('ref: refs/heads/release\n');
      _writeLooseGitRef(
        flutter38,
        'refs/heads/release',
        '$_frameworkRevision38\n',
      );
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      expect(resolution, isA<L10nToolchainResolved>());
      expect(runner.calls, hasLength(1));
    });

    test('accepts a strict packed-only HEAD fallback', () async {
      _sdkGitFile(flutter38, 'refs/heads/stable').deleteSync();
      _sdkGitFile(flutter38, 'packed-refs').writeAsStringSync(
        '# pack-refs with: peeled fully-peeled sorted \n'
        '$_frameworkRevision38 refs/heads/stable\n'
        '2222222222222222222222222222222222222222 refs/tags/example\n'
        '^3333333333333333333333333333333333333333\n',
      );
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        for (var index = 0; index < 2; index++)
          _ProcessReply.result(_successfulProbe(stable)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);

      final expected = await _resolved38(project, flutter38, resolver);
      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      expect(result, isA<L10nToolchainStillMatches>());
      expect(runner.calls, hasLength(2));
    });

    test('loose ref wins without consulting malformed packed refs', () async {
      _sdkGitFile(
        flutter38,
        'packed-refs',
      ).writeAsStringSync('malformed packed data\n');
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      expect(resolution, isA<L10nToolchainResolved>());
      expect(runner.calls, hasLength(1));
    });

    for (final packedCase in [
      (
        'malformed',
        'not-an-object refs/heads/stable\n',
        'registry-sdk-git-ref-invalid',
      ),
      (
        'duplicate',
        '$_frameworkRevision38 refs/heads/stable\n'
            '$_otherFrameworkRevision refs/heads/stable\n',
        'registry-sdk-packed-ref-ambiguous',
      ),
      (
        'unknown header capability',
        '# pack-refs with: future-format \n'
            '$_frameworkRevision38 refs/heads/stable\n',
        'registry-sdk-git-ref-invalid',
      ),
      (
        'duplicate header capability',
        '# pack-refs with: sorted sorted \n'
            '$_frameworkRevision38 refs/heads/stable\n',
        'registry-sdk-git-ref-invalid',
      ),
    ]) {
      test('rejects ${packedCase.$1} packed refs before probing', () async {
        _sdkGitFile(flutter38, 'refs/heads/stable').deleteSync();
        _sdkGitFile(flutter38, 'packed-refs').writeAsStringSync(packedCase.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: packedCase.$3,
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects a symlinked .git directory', () async {
      final git = _sdkGitDirectory(flutter38);
      final external = Directory(p.join(scratch.path, 'external-git'))
        ..createSync();
      File(
        p.join(external.path, 'HEAD'),
      ).writeAsStringSync('$_frameworkRevision38\n');
      git.deleteSync(recursive: true);
      Link(git.path).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symlinked Git HEAD file', () async {
      final head = _sdkGitFile(flutter38, 'HEAD');
      final external = File(p.join(scratch.path, 'external-head'))
        ..writeAsStringSync('$_frameworkRevision38\n');
      head.deleteSync();
      Link(head.path).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-head-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symlinked loose-ref ancestor', () async {
      final heads = Directory(
        _sdkGitFile(flutter38, 'refs/heads/stable').parent.path,
      );
      final external = Directory(p.join(scratch.path, 'external-heads'))
        ..createSync();
      File(
        p.join(external.path, 'stable'),
      ).writeAsStringSync('$_frameworkRevision38\n');
      heads.deleteSync(recursive: true);
      Link(heads.path).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symlinked loose-ref file', () async {
      final stableRef = _sdkGitFile(flutter38, 'refs/heads/stable');
      final external = File(p.join(scratch.path, 'external-ref'))
        ..writeAsStringSync('$_frameworkRevision38\n');
      stableRef.deleteSync();
      Link(stableRef.path).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    for (final invalidHead in [
      ('traversal', 'ref: refs/heads/../../outside\n'),
      ('control byte', 'ref: refs/heads/control\u0001name\n'),
      ('double dot', 'ref: refs/heads/double..dot\n'),
      ('lock suffix', 'ref: refs/heads/trailing.lock\n'),
    ]) {
      test('rejects unsafe symbolic ref ${invalidHead.$1}', () async {
        _sdkGitFile(flutter38, 'HEAD').writeAsStringSync(invalidHead.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-ref-invalid',
        );
        expect(runner.calls, isEmpty);
      });
    }

    for (final invalidOid in [
      ('uppercase', 'ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD\n'),
      ('short', '1234\n'),
      ('nonhex', 'gggggggggggggggggggggggggggggggggggggggg\n'),
      ('CRLF', '$_frameworkRevision38\r\n'),
    ]) {
      test('rejects invalid loose-ref object ${invalidOid.$1}', () async {
        _sdkGitFile(
          flutter38,
          'refs/heads/stable',
        ).writeAsStringSync(invalidOid.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-ref-invalid',
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects a detached HEAD without its exact LF terminator', () async {
      _sdkGitFile(flutter38, 'HEAD').writeAsStringSync(_frameworkRevision38);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-head-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symbolic ref chain beyond the fixed bound', () async {
      _sdkGitFile(
        flutter38,
        'refs/heads/stable',
      ).writeAsStringSync('ref: refs/heads/chain-0\n');
      for (var index = 0; index < 17; index++) {
        _writeLooseGitRef(
          flutter38,
          'refs/heads/chain-$index',
          index == 16
              ? '$_frameworkRevision38\n'
              : 'ref: refs/heads/chain-${index + 1}\n',
        );
      }
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a symbolic loose-ref cycle', () async {
      _sdkGitFile(
        flutter38,
        'refs/heads/stable',
      ).writeAsStringSync('ref: refs/heads/release\n');
      _writeLooseGitRef(
        flutter38,
        'refs/heads/release',
        'ref: refs/heads/stable\n',
      );
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects linked-worktree gitfile layout', () async {
      final git = _sdkGitDirectory(flutter38)..deleteSync(recursive: true);
      File(git.path).writeAsStringSync('gitdir: ../shared/worktrees/sdk\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a commondir layout before probing', () async {
      _sdkGitFile(flutter38, 'commondir').writeAsStringSync('../..\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a reftable authority layout before probing', () async {
      Directory(
        _sdkGitFile(flutter38, 'reftable').path,
      ).createSync(recursive: true);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    for (final configCase in [
      (
        'external files ref backend',
        '[core]\n'
            '\trepositoryformatversion = 1\n'
            '[extensions]\n'
            '\trefStorage = files:///outside\n',
      ),
      (
        'reftable ref backend',
        '[core]\n'
            '\trepositoryformatversion = 1\n'
            '[extensions]\n'
            '\trefStorage = reftable\n',
      ),
      (
        'unsupported repository format',
        '[core]\n\trepositoryformatversion = 1\n',
      ),
      (
        'external include',
        '[core]\n'
            '\trepositoryformatversion = 0\n'
            '[include]\n'
            '\tpath = /outside/config\n',
      ),
      (
        'conditional external include',
        '[core]\n'
            '\trepositoryformatversion = 0\n'
            '[includeIf "gitdir:/outside/"]\n'
            '\tpath = /outside/config\n',
      ),
      (
        'duplicate repository format',
        '[core]\n'
            '\trepositoryformatversion = 0\n'
            '\trepositoryformatversion = 0\n',
      ),
      (
        'duplicate ref backend',
        '[core]\n'
            '\trepositoryformatversion = 1\n'
            '[extensions]\n'
            '\trefStorage = files\n'
            '\trefStorage = files\n',
      ),
      (
        'control byte',
        '[core]\n\trepositoryformatversion = 0\n#\u0000hidden\n',
      ),
    ]) {
      test('rejects ${configCase.$1} Git config before probing', () async {
        _sdkGitFile(flutter38, 'config').writeAsStringSync(configCase.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-config-invalid',
        );
        expect(runner.calls, isEmpty);
      });
    }

    test('rejects a symlinked Git config file', () async {
      final config = _sdkGitFile(flutter38, 'config');
      final external = File(p.join(scratch.path, 'external-git-config'))
        ..writeAsStringSync('[core]\n\trepositoryformatversion = 0\n');
      config.deleteSync();
      Link(config.path).createSync(external.path);
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-config-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects Git config byte drift during the direct probe', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final config = _sdkGitFile(flutter38, 'config');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(stable),
          beforeReturn: () {
            config.writeAsStringSync(
              '[core]\n'
              '\trepositoryformatversion = 0\n'
              '[advice]\n'
              '\tdetachedHead = false\n',
            );
          },
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'canonical-sdk-changed-during-probe',
      );
      expect(runner.calls, hasLength(1));
    });

    test(
      'rejects machine revision that differs from Git before direct probe',
      () async {
        _sdkGitFile(
          flutter38,
          'refs/heads/stable',
        ).writeAsStringSync('$_otherFrameworkRevision\n');
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-framework-identity-mismatch',
        );
        expect(runner.calls, isEmpty);
      },
    );

    test(
      'same OID with changed HEAD authority representation is frozen drift',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        _sdkGitFile(
          flutter38,
          'HEAD',
        ).writeAsStringSync('$_frameworkRevision38\n');

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'identity-drift');
        expect(runner.calls, hasLength(1));
      },
    );
  });

  group('POSIX launch control semantics', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('rejects a group-writable canonical SDK root', () async {
      final sdkRoot = Directory(p.dirname(p.dirname(flutter38)));
      final chmod = Process.runSync(
        '/bin/chmod',
        ['0777', sdkRoot.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-structure-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a group-writable bound artifact ancestor', () async {
      final cache = Directory(
        p.join(p.dirname(p.dirname(flutter38)), 'bin', 'cache'),
      );
      final chmod = Process.runSync(
        '/bin/chmod',
        ['0777', cache.path],
        environment: const {'LANG': 'C', 'LC_ALL': 'C'},
        includeParentEnvironment: false,
      );
      expect(chmod.exitCode, 0);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-structure-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    for (final unsafeArtifact in [
      (
        p.join('bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
        '0777',
        'registry-sdk-structure-invalid',
      ),
      (
        'bin/cache/flutter_tools.snapshot',
        '0666',
        'registry-sdk-structure-invalid',
      ),
      (
        'packages/flutter_tools/.dart_tool/package_config.json',
        '0666',
        'registry-sdk-package-config-invalid',
      ),
      (
        'bin/cache/flutter.version.json',
        '0666',
        'registry-sdk-version-control-invalid',
      ),
    ]) {
      test('rejects group-writable authority ${unsafeArtifact.$1}', () async {
        final artifact = _sdkArtifact(flutter38, unsafeArtifact.$1);
        final chmod = Process.runSync(
          '/bin/chmod',
          [unsafeArtifact.$2, artifact.path],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        expect(chmod.exitCode, 0);
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: unsafeArtifact.$3,
        );
        expect(runner.calls, isEmpty);
      });
    }

    for (final relativePath in const [
      'bin/cache/engine.stamp',
      'bin/internal/engine.version',
    ]) {
      test(
        'rejects $relativePath that disagrees with machine identity',
        () async {
          _sdkArtifact(
            flutter38,
            relativePath,
          ).writeAsStringSync('stale-engine-revision\n');
          final runner = _FakeProcessRunner(const []);

          final resolution = await _resolve38(project, flutter38, runner);

          _expectRejected(
            resolution,
            code: L10nEvidenceRejectionCode.toolchainUnavailable,
            detailCode: 'registry-sdk-engine-identity-mismatch',
          );
          expect(runner.calls, isEmpty);
        },
      );
    }

    test(
      'rejects a non-OID engine revision across agreeing controls',
      () async {
        const invalidRevision = 'engine-invalid';
        _replaceEngineRevision(
          flutter38,
          from: _fixtureEngineRevision('sdk-3.38.7'),
          to: invalidRevision,
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(
              _machineBytes(
                version: '3.38.7',
                frameworkRevision: _frameworkRevision38,
                engineRevision: invalidRevision,
                dartSdkVersion: '3.10.7',
              ),
            ),
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-version-control-invalid',
        );
        expect(runner.calls, isEmpty);
      },
    );

    for (final malformed in const [
      (
        'bin/cache/flutter.version.json',
        '{"frameworkVersion":"3.38.7"}\n',
        'registry-sdk-version-control-invalid',
      ),
      (
        'bin/cache/engine_stamp.json',
        '{"build_date":"date","build_time_ms":"1",'
            '"git_revision":"$_engineRevision38",'
            '"git_revision_date":"date",'
            '"content_hash":"3838383838383838383838383838383838383838"}',
        'registry-sdk-engine-stamp-invalid',
      ),
      (
        'packages/flutter_tools/.dart_tool/package_config.json',
        '{"configVersion":2,"packages":[],"generator":"pub",'
            '"generatorVersion":"3.10.7","pubCache":"file:///cache",'
            '"extra":true}\n',
        'registry-sdk-package-config-invalid',
      ),
      (
        'bin/cache/dart-sdk/version',
        '3.10.7',
        'registry-sdk-dart-version-mismatch',
      ),
    ]) {
      test('rejects malformed direct control ${malformed.$1}', () async {
        _sdkArtifact(flutter38, malformed.$1).writeAsStringSync(malformed.$2);
        final runner = _FakeProcessRunner(const []);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: malformed.$3,
        );
        expect(runner.calls, isEmpty);
      });
    }

    for (final duplicate in const [
      (
        'bin/cache/flutter.version.json',
        'frameworkVersion',
        '"3.38.7"',
        'registry-sdk-version-control-invalid',
      ),
      (
        'bin/cache/engine_stamp.json',
        'build_time_ms',
        '1767225600000',
        'registry-sdk-engine-stamp-invalid',
      ),
    ]) {
      test(
        'rejects duplicate key ${duplicate.$2} in ${duplicate.$1}',
        () async {
          final control = _sdkArtifact(flutter38, duplicate.$1);
          control.writeAsStringSync(
            control.readAsStringSync().replaceFirst(
              '{',
              '{"${duplicate.$2}":${duplicate.$3},',
            ),
          );
          final runner = _FakeProcessRunner(const []);

          final resolution = await _resolve38(project, flutter38, runner);

          _expectRejected(
            resolution,
            code: L10nEvidenceRejectionCode.toolchainUnavailable,
            detailCode: duplicate.$4,
          );
          expect(runner.calls, isEmpty);
        },
      );
    }

    test('rejects a Dart SDK stamp that disagrees with engine stamp', () async {
      _sdkArtifact(
        flutter38,
        'bin/cache/engine-dart-sdk.stamp',
      ).writeAsStringSync('stale-dart-engine\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-dart-stamp-mismatch',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects a nonempty engine realm', () async {
      _sdkArtifact(
        flutter38,
        'bin/cache/engine.realm',
      ).writeAsStringSync('custom-realm\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'registry-sdk-engine-realm-unsupported',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects an incompatible Flutter-tools stamp', () async {
      _sdkArtifact(
        flutter38,
        'bin/cache/flutter_tools.stamp',
      ).writeAsStringSync('stale-framework-revision:\n');
      final runner = _FakeProcessRunner(const []);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-flutter-tools-stamp-incompatible',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects an empty Flutter-tools snapshot', () async {
      _sdkArtifact(
        flutter38,
        'bin/cache/flutter_tools.snapshot',
      ).writeAsBytesSync(const []);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-cache-state-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('rejects an empty Flutter-tools package configuration', () async {
      _sdkArtifact(
        flutter38,
        'packages/flutter_tools/.dart_tool/package_config.json',
      ).writeAsBytesSync(const []);
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-package-config-invalid',
      );
      expect(runner.calls, isEmpty);
    });

    test('checks retained controls before invoking the registry binary', () async {
      _sdkArtifact(
        flutter38,
        'bin/cache/engine.stamp',
      ).writeAsStringSync('stale-engine-revision\n');
      final runner = _FakeProcessRunner(const []);

      final resolution =
          await DefaultL10nToolchainResolver(processRunner: runner).resolve(
            originalProjectRoot: project,
            sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
            selection: RetainedEvidenceSelection(
              expectedIdentity: FlutterMachineIdentity(
                frameworkVersion: Version(3, 38, 7),
                frameworkRevision: _frameworkRevision38,
                engineRevision: _engineRevision38,
                dartSdkVersion: '3.10.7',
              ),
              evidenceSha256:
                  'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
              probeOutputSha256:
                  'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
            ),
          );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-engine-identity-mismatch',
      );
      expect(runner.calls, isEmpty);
    });

    test('revalidation checks stale controls before another probe', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);
      _sdkArtifact(
        flutter38,
        'bin/cache/engine.stamp',
      ).writeAsStringSync('stale-engine-revision\n');

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(
        result,
        detailCode: 'registry-sdk-engine-identity-mismatch',
      );
      expect(runner.calls, hasLength(1));
    });

    test(
      'rejects a group-writable artifact ancestor before revalidation probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        final cache = Directory(
          p.join(p.dirname(p.dirname(flutter38)), 'bin', 'cache'),
        );
        final chmod = Process.runSync(
          '/bin/chmod',
          ['0777', cache.path],
          environment: const {'LANG': 'C', 'LC_ALL': 'C'},
          includeParentEnvironment: false,
        );
        expect(chmod.exitCode, 0);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'canonical-sdk-drift');
        expect(runner.calls, hasLength(1));
      },
    );
  });

  group('within-probe temporal drift', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('resolve rejects selector mutation during the direct probe', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(stable),
          beforeReturn: () {
            File(
              p.join(project.path, '.fvmrc'),
            ).writeAsStringSync('{ "flutter": "3.38.7" }\n');
          },
        ),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-changed-during-probe',
      );
    });

    test(
      'resolve rejects SDK structure deletion during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final bundledDart = File(
          p.join(
            p.dirname(p.dirname(flutter38)),
            'bin',
            'cache',
            'dart-sdk',
            'bin',
            _bundledDartName,
          ),
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: bundledDart.deleteSync,
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      },
    );

    test(
      'resolve rejects same-realpath Flutter overwrite during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              final flutter = File(flutter38)
                ..writeAsStringSync('overwritten flutter\n');
              _makeExecutable(flutter);
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      },
    );

    test(
      'resolve rejects same-realpath snapshot overwrite during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final snapshot = _sdkArtifact(
          flutter38,
          'bin/cache/flutter_tools.snapshot',
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              snapshot.writeAsStringSync('overwritten snapshot\n');
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      },
    );

    for (final relativePath in const [
      'bin/cache/flutter.version.json',
      'bin/cache/engine_stamp.json',
      'bin/cache/dart-sdk/version',
      'packages/flutter_tools/.dart_tool/package_config.json',
    ]) {
      test('resolve rejects $relativePath drift during direct probe', () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final control = _sdkArtifact(flutter38, relativePath);
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              control.writeAsBytesSync([...control.readAsBytesSync(), 0x20]);
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
        expect(runner.calls, hasLength(1));
      });
    }

    test(
      'resolve rejects bound artifact mode drift during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final control = _sdkArtifact(
          flutter38,
          'packages/flutter_tools/.dart_tool/package_config.json',
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              final chmod = Process.runSync(
                '/bin/chmod',
                ['0600', control.path],
                environment: const {'LANG': 'C', 'LC_ALL': 'C'},
                includeParentEnvironment: false,
              );
              expect(chmod.exitCode, 0);
            },
          ),
        ]);

        final resolution = await _resolve38(project, flutter38, runner);

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
        expect(runner.calls, hasLength(1));
      },
    );

    test(
      'revalidate rejects selector mutation during the direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              File(
                p.join(project.path, '.fvmrc'),
              ).writeAsStringSync('{ "flutter": "3.38.7" }\n');
            },
          ),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'selector-changed-during-probe');
      },
    );

    test(
      'revalidate rejects canonical executable replacement during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final replacementFlutter = _createFlutterSdk(
          scratch,
          'replacement-sdk-3.38.7',
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              File(flutter38).deleteSync();
              Link(flutter38).createSync(replacementFlutter);
            },
          ),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(
          result,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      },
    );

    test(
      'revalidate rejects same-realpath Flutter overwrite during direct probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              final flutter = File(flutter38)
                ..writeAsStringSync('overwritten flutter\n');
              _makeExecutable(flutter);
            },
          ),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(
          result,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      },
    );
  });

  group('revalidation', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test(
      'returns the frozen identity when every boundary still matches',
      () async {
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
          _ProcessReply.result(_successfulProbe(machineBytes)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        expect(result, isA<L10nToolchainStillMatches>());
        expect(
          (result as L10nToolchainStillMatches).identitySha256,
          expected.identitySha256,
        );
        expect(runner.calls, hasLength(2));
      },
    );

    for (final forgery in [
      'generation argv',
      'direct probe argv',
      'HOME override',
      'PUB_CACHE override',
      'missing locale override',
    ]) {
      test('rejects forged frozen $forgery with copied identity', () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        final forged = switch (forgery) {
          'generation argv' => _copyResolved(
            expected,
            generationArgs: ['gen-l10n', '--synthetic-package'],
          ),
          'direct probe argv' => _copyResolved(
            expected,
            directProbeArgs: ['--machine', '--version'],
          ),
          'HOME override' => _copyResolved(
            expected,
            environmentOverrides: {
              ...expected.environmentOverrides,
              'HOME': '/forged/home',
            },
          ),
          'PUB_CACHE override' => _copyResolved(
            expected,
            environmentOverrides: {
              ...expected.environmentOverrides,
              'PUB_CACHE': '/forged/cache',
            },
          ),
          'missing locale override' => _copyResolved(
            expected,
            environmentOverrides: {
              for (final entry in expected.environmentOverrides.entries)
                if (entry.key != 'LC_ALL') entry.key: entry.value,
            },
          ),
          _ => throw StateError('Unhandled forgery case.'),
        };

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: forged,
        );

        _expectChanged(result, detailCode: 'frozen-command-drift');
        expect(runner.calls, hasLength(1));
      });
    }

    for (final forgery in [
      'bundled Dart path',
      'Flutter tools package config path',
      'Flutter tools snapshot path',
    ]) {
      test('rejects forged frozen $forgery with copied identity', () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);
        final launch = expected.launch;
        final forged = _copyResolved(
          expected,
          launch: switch (forgery) {
            'bundled Dart path' => L10nToolchainLaunch(
              canonicalDartExecutable:
                  '${launch.canonicalDartExecutable}.forged',
              canonicalFlutterToolsPackageConfig:
                  launch.canonicalFlutterToolsPackageConfig,
              canonicalFlutterToolsSnapshot:
                  launch.canonicalFlutterToolsSnapshot,
            ),
            'Flutter tools package config path' => L10nToolchainLaunch(
              canonicalDartExecutable: launch.canonicalDartExecutable,
              canonicalFlutterToolsPackageConfig:
                  '${launch.canonicalFlutterToolsPackageConfig}.forged',
              canonicalFlutterToolsSnapshot:
                  launch.canonicalFlutterToolsSnapshot,
            ),
            'Flutter tools snapshot path' => L10nToolchainLaunch(
              canonicalDartExecutable: launch.canonicalDartExecutable,
              canonicalFlutterToolsPackageConfig:
                  launch.canonicalFlutterToolsPackageConfig,
              canonicalFlutterToolsSnapshot:
                  '${launch.canonicalFlutterToolsSnapshot}.forged',
            ),
            _ => throw StateError('Unhandled launch forgery case.'),
          },
        );

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: forged,
        );

        _expectChanged(result, detailCode: 'frozen-launch-drift');
        expect(runner.calls, hasLength(1));
      });
    }

    test('revalidates unchanged retained evidence without selectors', () async {
      final stable = _fixtureBytes('machine/flutter_3_41_5.json');
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final resolution = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
        selection: RetainedEvidenceSelection(
          expectedIdentity: _identity41,
          evidenceSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          probeOutputSha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      );

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: resolution as L10nToolchainResolved,
      );

      expect(result, isA<L10nToolchainStillMatches>());
      expect(runner.calls, hasLength(2));
      final sdkRoot = p.dirname(p.dirname(flutter41));
      expect(
        runner.calls.every(
          (call) =>
              call.executable ==
              p.join(
                sdkRoot,
                'bin',
                'cache',
                'dart-sdk',
                'bin',
                _bundledDartName,
              ),
        ),
        isTrue,
      );
    });

    test('detects retained direct identity drift', () async {
      final stable = _fixtureBytes('machine/flutter_3_41_5.json');
      final changed = _machineBytes(
        version: '3.41.5',
        frameworkRevision: _frameworkRevision41,
        engineRevision: 'changed-retained-engine',
        dartSdkVersion: '3.11.3',
      );
      final flutter41 = _createFlutterSdk(scratch, 'sdk-3.41.5');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(changed)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final resolution = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry({Version(3, 41, 5): flutter41}),
        selection: RetainedEvidenceSelection(
          expectedIdentity: _identity41,
          evidenceSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          probeOutputSha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      );

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: resolution as L10nToolchainResolved,
      );

      _expectChanged(result, detailCode: 'direct-probe-identity-mismatch');
    });

    test('detects selector byte mutation before another probe', () async {
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);
      File(
        p.join(project.path, '.fvmrc'),
      ).writeAsStringSync('{ "flutter": "3.38.7" }\n');

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(result, detailCode: 'selector-hash-drift');
      expect(runner.calls, hasLength(1));
    });

    test('detects canonical executable path loss', () async {
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
        _ProcessReply.result(_successfulProbe(machineBytes)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);
      File(flutter38).deleteSync();

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(result, detailCode: 'canonical-executable-drift');
    });

    test('detects direct machine identity drift', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final changed = _machineBytes(
        version: '3.38.7',
        frameworkRevision: _frameworkRevision38,
        engineRevision: 'changed-engine',
        dartSdkVersion: '3.10.7',
      );
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(changed)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(result, detailCode: 'direct-probe-identity-mismatch');
      expect(runner.calls, hasLength(2));
    });

    test(
      'detects exact probe byte drift with unchanged parsed identity',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final compact = _machineBytes(
          version: '3.38.7',
          frameworkRevision: _frameworkRevision38,
          engineRevision: _engineRevision38,
          dartSdkVersion: '3.10.7',
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(compact)),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'identity-drift');
      },
    );

    test(
      'turns revalidation probe failure into stable toolchain drift',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.error(const FileSystemException('host path')),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'direct-probe-unavailable');
      },
    );
  });

  group('installed SDK direct integration', () {
    setUp(_requirePosixResolverHost);

    for (final sdk in const [
      (
        version: '3.41.5',
        frameworkRevision: _frameworkRevision41,
        dartVersion: '3.11.3',
        environmentKey: 'FLUTTER_PRUNER_TEST_FLUTTER_3_41_5',
      ),
      (
        version: '3.44.1',
        frameworkRevision: _frameworkRevision44,
        dartVersion: '3.12.1',
        environmentKey: 'FLUTTER_PRUNER_TEST_FLUTTER_3_44_1',
      ),
    ]) {
      test(
        'resolves installed Flutter ${sdk.version} without a wrapper',
        () async {
          final configuredFlutter = Platform.environment[sdk.environmentKey];
          if (configuredFlutter == null || configuredFlutter.isEmpty) {
            markTestSkipped(
              '${sdk.environmentKey} is not set for explicit SDK opt-in.',
            );
            return;
          }
          final registeredFlutter = File(configuredFlutter);
          if (!registeredFlutter.existsSync()) {
            fail(
              '${sdk.environmentKey} does not name an installed Flutter executable.',
            );
          }
          final canonicalFlutter = registeredFlutter.resolveSymbolicLinksSync();
          File(
            p.join(project.path, '.fvmrc'),
          ).writeAsStringSync('{"flutter":"${sdk.version}"}\n');
          final runner = _RecordingProcessRunner(const ManagedProcessRunner());

          final resolution =
              await DefaultL10nToolchainResolver(processRunner: runner).resolve(
                originalProjectRoot: project,
                sdkRegistry: L10nSdkRegistry({
                  Version.parse(sdk.version): canonicalFlutter,
                }),
                selection: const ProjectSelectorSelection(),
              );

          expect(resolution, isA<L10nToolchainResolved>());
          final resolved = resolution as L10nToolchainResolved;
          expect(
            resolved.machineIdentity.frameworkRevision,
            sdk.frameworkRevision,
          );
          expect(resolved.machineIdentity.dartSdkVersion, sdk.dartVersion);
          expect(runner.calls, hasLength(1));
          _expectDirectCall(
            runner.calls.single,
            canonicalFlutter: canonicalFlutter,
            logicalArguments: ['--version', '--machine'],
            project: project,
          );
          expect(
            Directory(
              runner.calls.single.sandboxObservation!.root,
            ).existsSync(),
            isFalse,
          );
        },
      );
    }
  });

  test(
    'Windows host rejects argv-only Flutter evidence and revalidation',
    () async {
      final runner = _FakeProcessRunner(const []);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final resolution = await resolver.resolve(
        originalProjectRoot: project,
        sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter38}),
        selection: const ProjectSelectorSelection(),
      );

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'windows-command-model-unsupported',
      );

      final revalidation = await resolver.revalidate(
        originalProjectRoot: project,
        expected: L10nToolchainResolved(
          canonicalFlutterExecutable: flutter38,
          canonicalSdkRoot: p.dirname(p.dirname(flutter38)),
          launch: L10nToolchainLaunch(
            canonicalDartExecutable: flutter38,
            canonicalFlutterToolsPackageConfig: flutter38,
            canonicalFlutterToolsSnapshot: flutter38,
          ),
          selection: const ProjectSelectorSelection(),
          generationArgs: const ['gen-l10n'],
          directProbeArgs: const ['--version', '--machine'],
          environmentOverrides: _environmentOverrides,
          selectorHashesByRelativePath: const {},
          machineIdentity: FlutterMachineIdentity(
            frameworkVersion: Version(3, 38, 7),
            frameworkRevision: _frameworkRevision38,
            engineRevision: _engineRevision38,
            dartSdkVersion: '3.10.7',
          ),
          originalSelectionProbeSha256:
              'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          identitySha256:
              'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        ),
      );

      _expectChanged(
        revalidation,
        detailCode: 'windows-command-model-unsupported',
      );
      expect(runner.calls, isEmpty);
    },
    skip: Platform.isWindows ? false : 'Windows-host assertion',
  );
}

final _identity41 = FlutterMachineIdentity(
  frameworkVersion: Version(3, 41, 5),
  frameworkRevision: _frameworkRevision41,
  engineRevision: _engineRevision41,
  dartSdkVersion: '3.11.3',
);

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

void _requirePosixResolverHost() {
  if (Platform.isWindows) {
    markTestSkipped('POSIX resolver contract');
  }
}

Future<L10nToolchainResolution> _resolve38(
  Directory project,
  String flutter,
  _FakeProcessRunner runner, {
  DefaultL10nToolchainResolver? resolver,
}) => (resolver ?? DefaultL10nToolchainResolver(processRunner: runner)).resolve(
  originalProjectRoot: project,
  sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter}),
  selection: const ProjectSelectorSelection(),
);

Future<L10nToolchainResolved> _resolved38(
  Directory project,
  String flutter,
  DefaultL10nToolchainResolver resolver,
) async {
  final result = await resolver.resolve(
    originalProjectRoot: project,
    sdkRegistry: L10nSdkRegistry({Version(3, 38, 7): flutter}),
    selection: const ProjectSelectorSelection(),
  );
  return result as L10nToolchainResolved;
}

L10nToolchainResolved _copyResolved(
  L10nToolchainResolved source, {
  L10nToolchainLaunch? launch,
  List<String>? generationArgs,
  List<String>? directProbeArgs,
  Map<String, String>? environmentOverrides,
}) => L10nToolchainResolved(
  canonicalFlutterExecutable: source.canonicalFlutterExecutable,
  canonicalSdkRoot: source.canonicalSdkRoot,
  launch: launch ?? source.launch,
  selection: source.selection,
  generationArgs: generationArgs ?? source.generationArgs,
  directProbeArgs: directProbeArgs ?? source.directProbeArgs,
  environmentOverrides: environmentOverrides ?? source.environmentOverrides,
  selectorHashesByRelativePath: source.selectorHashesByRelativePath,
  machineIdentity: source.machineIdentity,
  originalSelectionProbeSha256: source.originalSelectionProbeSha256,
  identitySha256: source.identitySha256,
);

void _expectRejected(
  L10nToolchainResolution resolution, {
  required L10nEvidenceRejectionCode code,
  required String detailCode,
  String? relativePath,
}) {
  expect(resolution, isA<L10nToolchainRejected>());
  final failure = (resolution as L10nToolchainRejected).failure;
  expect(failure.code, code);
  expect(failure.stage, 'toolchain-resolution');
  expect(failure.detailCode, detailCode);
  expect(failure.relativePath, relativePath);
}

void _expectChanged(
  L10nToolchainRevalidationResult result, {
  required String detailCode,
}) {
  expect(result, isA<L10nToolchainChanged>());
  final failure = (result as L10nToolchainChanged).failure;
  expect(failure.code, L10nEvidenceRejectionCode.toolchainDrift);
  expect(failure.stage, 'toolchain-revalidation');
  expect(failure.detailCode, detailCode);
}

void _expectDirectCall(
  _ProcessCall call, {
  required String canonicalFlutter,
  required List<String> logicalArguments,
  required Directory project,
}) {
  final sdkRoot = p.dirname(p.dirname(canonicalFlutter));
  expect(
    call.executable,
    p.join(sdkRoot, 'bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
  );
  expect(call.arguments, [
    '--packages=${p.join(sdkRoot, 'packages', 'flutter_tools', '.dart_tool', 'package_config.json')}',
    p.join(sdkRoot, 'bin', 'cache', 'flutter_tools.snapshot'),
    ...logicalArguments,
  ]);
  expect(call.workingDirectory, project.absolute.path);
  expect(call.timeout, const Duration(seconds: 30));
  expect(call.maxOutputBytesPerStream, 1024 * 1024);
  expect(call.includeParentEnvironment, isFalse);
  expect(call.environmentOverrides, containsPair('FLUTTER_ROOT', sdkRoot));
  expect(
    call.environmentOverrides,
    containsPair('FLUTTER_ALREADY_LOCKED', 'true'),
  );
  expect(
    call.environmentOverrides.keys,
    containsAll(_environmentOverrides.keys),
  );
  expect(call.sandboxObservation, isNotNull);
}

String _createFlutterSdk(Directory scratch, String name) {
  final sdk = Directory(p.join(scratch.path, name))..createSync();
  final frameworkRevision = _fixtureFrameworkRevision(name);
  final engineRevision = _fixtureEngineRevision(name);
  final engineContentHash = _fixtureEngineContentHash(name);
  final flutter = File(p.join(sdk.path, 'bin', _flutterExecutableName));
  final bundledDart = File(
    p.join(sdk.path, 'bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
  );
  for (final executable in [flutter, bundledDart]) {
    executable.createSync(recursive: true);
    executable.writeAsStringSync('toolchain fixture\n');
    if (!Platform.isWindows) _makeExecutable(executable);
  }
  File(p.join(sdk.path, 'bin/internal/engine.version'))
    ..createSync(recursive: true)
    ..writeAsStringSync('$engineRevision\n');
  final controlContents = <String, String>{
    'bin/cache/flutter_tools.snapshot': 'fixture snapshot\n',
    'bin/cache/flutter_tools.stamp': '$frameworkRevision:\n',
    'bin/cache/engine.stamp': '$engineRevision\n',
    'bin/cache/engine.realm': '\n',
    'bin/cache/engine-dart-sdk.stamp': '$engineRevision\n',
    'bin/cache/engine_stamp.stamp': engineRevision,
    'bin/cache/dart-sdk/version': '${_fixtureDartVersion(name)}\n',
    'bin/cache/flutter.version.json':
        '{\n'
        '  "frameworkVersion": "${_fixtureFlutterVersion(name)}",\n'
        '  "channel": "stable",\n'
        '  "repositoryUrl": "https://github.com/flutter/flutter.git",\n'
        '  "frameworkRevision": "$frameworkRevision",\n'
        '  "frameworkCommitDate": "2026-01-01 00:00:00 +0000",\n'
        '  "engineRevision": "$engineRevision",\n'
        '  "engineCommitDate": "2026-01-01 00:00:00.000Z",\n'
        '  "engineContentHash": "$engineContentHash",\n'
        '  "engineBuildDate": "2026-01-01 00:00:00.000",\n'
        '  "dartSdkVersion": "${_fixtureDartVersion(name)}",\n'
        '  "devToolsVersion": "fixture-devtools",\n'
        '  "flutterVersion": "${_fixtureFlutterVersion(name)}"\n'
        '}',
    'bin/cache/engine_stamp.json':
        '{"build_date":"2026-01-01T00:00:00.000000",'
        '"build_time_ms":1767225600000,'
        '"git_revision":"$engineRevision",'
        '"git_revision_date":"2026-01-01T00:00:00+00:00",'
        '"content_hash":"$engineContentHash"}',
  };
  for (final entry in controlContents.entries) {
    File(p.join(sdk.path, entry.key))
      ..createSync(recursive: true)
      ..writeAsStringSync(entry.value);
  }
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
      '"packages":[{"name":"flutter_tools","rootUri":"../",'
      '"packageUri":"lib/","languageVersion":"3.0"}],'
      '"generator":"pub",'
      '"generatorVersion":"${_fixtureDartVersion(name)}",'
      '"pubCache":"file:///fixture/pub-cache"}\n',
    );
  _writeLooseGitRef(
    flutter.resolveSymbolicLinksSync(),
    'refs/heads/stable',
    '$frameworkRevision\n',
  );
  _sdkGitFile(
    flutter.resolveSymbolicLinksSync(),
    'HEAD',
  ).writeAsStringSync('ref: refs/heads/stable\n');
  _sdkGitFile(
    flutter.resolveSymbolicLinksSync(),
    'config',
  ).writeAsStringSync('[core]\n\trepositoryformatversion = 0\n');
  return flutter.resolveSymbolicLinksSync();
}

Directory _sdkGitDirectory(String canonicalFlutter) =>
    Directory(p.join(p.dirname(p.dirname(canonicalFlutter)), '.git'));

File _sdkGitFile(String canonicalFlutter, String relativePath) =>
    File(p.join(_sdkGitDirectory(canonicalFlutter).path, relativePath));

void _writeLooseGitRef(
  String canonicalFlutter,
  String relativeRef,
  String contents,
) {
  _sdkGitFile(canonicalFlutter, relativeRef)
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String _fixtureFrameworkRevision(String sdkName) => switch (sdkName) {
  final String name when name.contains('3.38.7') => _frameworkRevision38,
  final String name when name.contains('3.41.5') => _frameworkRevision41,
  final String name when name.contains('3.44.1') => _frameworkRevision44,
  _ => throw ArgumentError.value(sdkName, 'sdkName'),
};

String _fixtureEngineRevision(String sdkName) => switch (sdkName) {
  final String name when name.contains('3.38.7') => _engineRevision38,
  final String name when name.contains('3.41.5') => _engineRevision41,
  final String name when name.contains('3.44.1') => _engineRevision44,
  _ => throw ArgumentError.value(sdkName, 'sdkName'),
};

String _fixtureFlutterVersion(String sdkName) => switch (sdkName) {
  final String name when name.contains('3.38.7') => '3.38.7',
  final String name when name.contains('3.41.5') => '3.41.5',
  final String name when name.contains('3.44.1') => '3.44.1',
  _ => throw ArgumentError.value(sdkName, 'sdkName'),
};

String _fixtureDartVersion(String sdkName) => switch (sdkName) {
  final String name when name.contains('3.38.7') => '3.10.7',
  final String name when name.contains('3.41.5') => '3.11.3',
  final String name when name.contains('3.44.1') => '3.12.0',
  _ => throw ArgumentError.value(sdkName, 'sdkName'),
};

String _fixtureEngineContentHash(String sdkName) => switch (sdkName) {
  final String name when name.contains('3.38.7') =>
    '3838383838383838383838383838383838383838',
  final String name when name.contains('3.41.5') =>
    '4141414141414141414141414141414141414141',
  final String name when name.contains('3.44.1') =>
    '4444444444444444444444444444444444444444',
  _ => throw ArgumentError.value(sdkName, 'sdkName'),
};

File _sdkArtifact(String canonicalFlutter, String relativePath) =>
    File(p.join(p.dirname(p.dirname(canonicalFlutter)), relativePath));

void _replaceEngineRevision(
  String canonicalFlutter, {
  required String from,
  required String to,
}) {
  for (final relativePath in const [
    'bin/internal/engine.version',
    'bin/cache/engine.stamp',
    'bin/cache/engine-dart-sdk.stamp',
    'bin/cache/engine_stamp.stamp',
    'bin/cache/flutter.version.json',
    'bin/cache/engine_stamp.json',
  ]) {
    final file = _sdkArtifact(canonicalFlutter, relativePath);
    file.writeAsStringSync(file.readAsStringSync().replaceAll(from, to));
  }
}

void _makeExecutable(File file) {
  final chmod = Process.runSync(
    '/bin/chmod',
    ['755', file.path],
    environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    includeParentEnvironment: false,
  );
  if (chmod.exitCode != 0) {
    throw StateError('Could not make fixture executable.');
  }
}

String get _flutterExecutableName =>
    Platform.isWindows ? 'flutter.bat' : 'flutter';

String get _bundledDartName => Platform.isWindows ? 'dart.exe' : 'dart';

void _installFixture(
  Directory project,
  String fixtureRelativePath,
  String projectRelativePath,
) {
  final destination = File(p.join(project.path, projectRelativePath));
  destination.createSync(recursive: true);
  destination.writeAsBytesSync(_fixtureBytes(fixtureRelativePath));
}

List<int> _fixtureBytes(String relativePath) => File(
  p.join(
    Directory.current.path,
    'test',
    'fixtures',
    'l10n_action_readiness',
    'toolchains',
    relativePath,
  ),
).readAsBytesSync();

List<int> _machineBytes({
  required String version,
  required String frameworkRevision,
  required String engineRevision,
  required String dartSdkVersion,
}) => utf8.encode(
  jsonEncode({
    'frameworkVersion': version,
    'channel': 'stable',
    'repositoryUrl': 'https://github.com/flutter/flutter.git',
    'frameworkRevision': frameworkRevision,
    'frameworkCommitDate': '2026-01-01 00:00:00 +0000',
    'engineRevision': engineRevision,
    'engineCommitDate': '2026-01-01 00:00:00.000Z',
    'engineContentHash': _fixtureEngineContentHash(version),
    'engineBuildDate': '2026-01-01 00:00:00.000',
    'dartSdkVersion': dartSdkVersion,
    'devToolsVersion': 'fixture-devtools',
    'flutterVersion': version,
    'flutterRoot': _machineFlutterRootPlaceholder,
  }),
);

ManagedProcessResult _successfulProbe(
  List<int> stdout, {
  List<int> stderr = const [],
  int exitCode = 0,
  bool timedOut = false,
  int stdoutOmittedBytes = 0,
  int stderrOmittedBytes = 0,
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
  resourceObservation: const ProcessTreeResourceObservation(
    status: ProcessResourceObservationStatus.unreliable,
    sampleCount: 9,
    sampledPeakRssBytes: 123456,
  ),
);

final class _FakeProcessRunner implements ProcessExecutionRunner {
  _FakeProcessRunner(List<_ProcessReply> replies)
    : _replies = List<_ProcessReply>.of(replies);

  final List<_ProcessReply> _replies;
  final List<_ProcessCall> calls = [];

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
    final sandboxObservation = _SandboxObservation.capture(
      environmentOverrides,
    );
    calls.add(
      _ProcessCall(
        executable: executable,
        arguments: List<String>.of(arguments),
        workingDirectory: workingDirectory,
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
        environmentOverrides: Map<String, String>.of(environmentOverrides),
        includeParentEnvironment: includeParentEnvironment,
        sandboxObservation: sandboxObservation,
      ),
    );
    if (_replies.isEmpty) throw StateError('Unexpected process call.');
    final reply = _replies.removeAt(0);
    reply.beforeReturn?.call();
    if (reply.error case final error?) throw error;
    return _materializeMachineRoot(
      reply.result!,
      environmentOverrides['FLUTTER_ROOT'],
    );
  }
}

final class _RecordingProcessRunner implements ProcessExecutionRunner {
  _RecordingProcessRunner(this._delegate);

  final ProcessExecutionRunner _delegate;
  final List<_ProcessCall> calls = [];

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
    Map<String, String> environmentOverrides = const {},
    bool includeParentEnvironment = true,
  }) {
    calls.add(
      _ProcessCall(
        executable: executable,
        arguments: List<String>.of(arguments),
        workingDirectory: workingDirectory,
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
        environmentOverrides: Map<String, String>.of(environmentOverrides),
        includeParentEnvironment: includeParentEnvironment,
        sandboxObservation: _SandboxObservation.capture(environmentOverrides),
      ),
    );
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
}

ManagedProcessResult _materializeMachineRoot(
  ManagedProcessResult result,
  String? flutterRoot,
) {
  if (flutterRoot == null ||
      !utf8
          .decode(result.stdout.capturedPayload, allowMalformed: true)
          .contains(_machineFlutterRootPlaceholder)) {
    return result;
  }
  final escapedRoot = jsonEncode(flutterRoot);
  final materialized = utf8
      .decode(result.stdout.capturedPayload)
      .replaceAll(
        _machineFlutterRootPlaceholder,
        escapedRoot.substring(1, escapedRoot.length - 1),
      );
  return ManagedProcessResult(
    exitCode: result.exitCode,
    stdout: BoundedProcessOutput(
      capturedPayload: utf8.encode(materialized),
      omittedBytes: result.stdout.omittedBytes,
    ),
    stderr: result.stderr,
    timedOut: result.timedOut,
    resourceObservation: result.resourceObservation,
  );
}

final class _ProcessCall {
  const _ProcessCall({
    required this.executable,
    required this.arguments,
    required this.workingDirectory,
    required this.timeout,
    required this.maxOutputBytesPerStream,
    required this.environmentOverrides,
    required this.includeParentEnvironment,
    required this.sandboxObservation,
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Duration timeout;
  final int maxOutputBytesPerStream;
  final Map<String, String> environmentOverrides;
  final bool includeParentEnvironment;
  final _SandboxObservation? sandboxObservation;
}

final class _SandboxObservation {
  const _SandboxObservation({
    required this.root,
    required this.whichBytes,
    required this.whichExecutable,
    required this.allOwnedDirectoriesPresent,
  });

  static _SandboxObservation? capture(Map<String, String> environment) {
    final home = environment['HOME'];
    final path = environment['PATH'];
    final xdg = environment['XDG_CONFIG_HOME'];
    final pubCache = environment['PUB_CACHE'];
    final tmp = environment['TMPDIR'];
    if (home == null ||
        path == null ||
        xdg == null ||
        pubCache == null ||
        tmp == null) {
      return null;
    }
    final root = p.dirname(home);
    final which = File(p.join(path, 'which'));
    return _SandboxObservation(
      root: root,
      whichBytes: which.existsSync() ? which.readAsBytesSync() : const [],
      whichExecutable: which.existsSync() && which.statSync().mode & 0x49 != 0,
      allOwnedDirectoriesPresent: [
        home,
        path,
        xdg,
        pubCache,
        tmp,
      ].every((directory) => Directory(directory).existsSync()),
    );
  }

  final String root;
  final List<int> whichBytes;
  final bool whichExecutable;
  final bool allOwnedDirectoriesPresent;
}

final class _ProcessReply {
  const _ProcessReply.result(this.result, {this.beforeReturn}) : error = null;

  const _ProcessReply.error(this.error) : result = null, beforeReturn = null;

  final ManagedProcessResult? result;
  final Exception? error;
  final void Function()? beforeReturn;
}

final class _ThrowingStringList extends ListBase<String> {
  @override
  int get length => throw StateError('unexpected test list failure');

  @override
  set length(int value) => throw UnsupportedError('immutable test list');

  @override
  String operator [](int index) => throw StateError('unexpected test access');

  @override
  void operator []=(int index, String value) =>
      throw UnsupportedError('immutable test list');
}
