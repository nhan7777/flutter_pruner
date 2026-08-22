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

void main() {
  late Directory scratch;
  late Directory project;
  late String flutter38;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('l10n-toolchain-test-');
    project = Directory(p.join(scratch.path, 'project'))..createSync();
    flutter38 = _createFlutterSdk(scratch, 'sdk-3.38.7');
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  group('project selector resolution', () {
    setUp(_requirePosixResolverHost);
    test(
      'matches root .fvmrc delegation to the canonical direct probe',
      () async {
        _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
        final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(machineBytes)),
          _ProcessReply.result(
            _successfulProbe(machineBytes, stderr: [0, 255]),
          ),
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
        expect(resolved.environmentOverrides, _environmentOverrides);
        expect(resolved.selectorHashesByRelativePath.keys, ['.fvmrc']);
        expect(
          resolved.selectorHashesByRelativePath['.fvmrc'],
          sha256.convert(_fixtureBytes('fvmrc/.fvmrc')).toString(),
        );
        expect(resolved.machineIdentity.frameworkVersion, Version(3, 38, 7));
        expect(resolved.machineIdentity.frameworkRevision, 'framework-3.38.7');
        expect(resolved.machineIdentity.engineRevision, 'engine-3.38.7');
        expect(resolved.machineIdentity.dartSdkVersion, '3.10.7');
        expect(resolved.originalSelectionProbeSha256, matches(_sha256Pattern));
        expect(resolved.identitySha256, matches(_sha256Pattern));

        expect(runner.calls, hasLength(2));
        _expectCall(
          runner.calls[0],
          executable: 'fvm',
          arguments: ['flutter', '--version', '--machine'],
          project: project,
        );
        _expectCall(
          runner.calls[1],
          executable: flutter38,
          arguments: ['--version', '--machine'],
          project: project,
        );
      },
    );

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

    test('rejects wrapper and direct machine identity mismatch', () async {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(
          _successfulProbe(_fixtureBytes('machine/flutter_3_38_7.json')),
        ),
        _ProcessReply.result(
          _successfulProbe(
            _machineBytes(
              version: '3.38.7',
              frameworkRevision: 'other-framework',
              engineRevision: 'engine-3.38.7',
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
        detailCode: 'probe-identity-mismatch',
      );
    });
  });

  group('probe failure handling', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('rejects truncated delegated output', () async {
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
        detailCode: 'selection-probe-truncated',
      );
    });

    test('rejects a nonzero direct probe', () async {
      final machineBytes = _fixtureBytes('machine/flutter_3_38_7.json');
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(machineBytes)),
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
        _ProcessReply.result(_successfulProbe(machineBytes)),
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

        _expectRejected(
          resolution,
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selection-probe-termination-unconfirmed',
        );
      },
    );

    test('rejects an unavailable wrapper without exception text', () async {
      final runner = _FakeProcessRunner([
        _ProcessReply.error(const FileSystemException('machine-specific path')),
      ]);

      final resolution = await _resolve38(project, flutter38, runner);

      _expectRejected(
        resolution,
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selection-probe-unavailable',
      );
    });

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
        detailCode: 'selection-probe-output-invalid',
      );
    });
  });

  group('retained evidence selection', () {
    setUp(_requirePosixResolverHost);
    test(
      'binds valid source/probe hashes and probes only the registry binary',
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
        expect(resolved.machineIdentity.frameworkRevision, 'framework-3.41.5');
        expect(runner.calls, hasLength(1));
        _expectCall(
          runner.calls.single,
          executable: flutter41,
          arguments: ['--version', '--machine'],
          project: project,
        );
      },
    );

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
              frameworkRevision: 'framework-3.41.5',
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
        detailCode: 'retained-identity-mismatch',
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
                  frameworkRevision: 'framework-retained',
                  engineRevision: 'engine-retained',
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
        for (var index = 0; index < 4; index++)
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
        frameworkRevision: 'framework-3.38.7',
        engineRevision: 'engine-3.38.7',
        dartSdkVersion: '3.10.7',
      );
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(pretty)),
        _ProcessReply.result(_successfulProbe(pretty)),
        _ProcessReply.result(_successfulProbe(compact)),
        _ProcessReply.result(_successfulProbe(pretty)),
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

  group('within-probe temporal drift', () {
    setUp(_requirePosixResolverHost);
    setUp(() {
      _installFixture(project, 'fvmrc/.fvmrc', '.fvmrc');
    });

    test('resolve rejects selector mutation during delegated probe', () async {
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
        _ProcessReply.result(_successfulProbe(stable)),
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
          _ProcessReply.result(_successfulProbe(stable)),
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
      'revalidate rejects selector mutation during delegated probe',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(
            _successfulProbe(stable),
            beforeReturn: () {
              File(
                p.join(project.path, '.fvmrc'),
              ).writeAsStringSync('{ "flutter": "3.38.7" }\n');
            },
          ),
          _ProcessReply.result(_successfulProbe(stable)),
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
          _ProcessReply.result(_successfulProbe(stable)),
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
          for (var index = 0; index < 4; index++)
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
        expect(runner.calls, hasLength(4));
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
          for (var index = 0; index < 4; index++)
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
        expect(runner.calls, hasLength(2));
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
      expect(
        runner.calls.every((call) => call.executable == flutter41),
        isTrue,
      );
    });

    test('detects retained direct identity drift', () async {
      final stable = _fixtureBytes('machine/flutter_3_41_5.json');
      final changed = _machineBytes(
        version: '3.41.5',
        frameworkRevision: 'framework-3.41.5',
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

      _expectChanged(result, detailCode: 'direct-probe-drift');
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
      expect(runner.calls, hasLength(2));
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

    test('detects delegated machine identity drift', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final changed = _machineBytes(
        version: '3.38.7',
        frameworkRevision: 'changed-framework',
        engineRevision: 'engine-3.38.7',
        dartSdkVersion: '3.10.7',
      );
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(changed)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(result, detailCode: 'delegated-probe-drift');
      expect(runner.calls, hasLength(3));
    });

    test('detects direct machine identity drift', () async {
      final stable = _fixtureBytes('machine/flutter_3_38_7.json');
      final changed = _machineBytes(
        version: '3.38.7',
        frameworkRevision: 'framework-3.38.7',
        engineRevision: 'changed-engine',
        dartSdkVersion: '3.10.7',
      );
      final runner = _FakeProcessRunner([
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(stable)),
        _ProcessReply.result(_successfulProbe(changed)),
      ]);
      final resolver = DefaultL10nToolchainResolver(processRunner: runner);
      final expected = await _resolved38(project, flutter38, resolver);

      final result = await resolver.revalidate(
        originalProjectRoot: project,
        expected: expected,
      );

      _expectChanged(result, detailCode: 'direct-probe-drift');
      expect(runner.calls, hasLength(4));
    });

    test(
      'detects exact probe byte drift with unchanged parsed identity',
      () async {
        final stable = _fixtureBytes('machine/flutter_3_38_7.json');
        final compact = _machineBytes(
          version: '3.38.7',
          frameworkRevision: 'framework-3.38.7',
          engineRevision: 'engine-3.38.7',
          dartSdkVersion: '3.10.7',
        );
        final runner = _FakeProcessRunner([
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.result(_successfulProbe(compact)),
          _ProcessReply.result(_successfulProbe(stable)),
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
          _ProcessReply.result(_successfulProbe(stable)),
          _ProcessReply.error(const FileSystemException('host path')),
        ]);
        final resolver = DefaultL10nToolchainResolver(processRunner: runner);
        final expected = await _resolved38(project, flutter38, resolver);

        final result = await resolver.revalidate(
          originalProjectRoot: project,
          expected: expected,
        );

        _expectChanged(result, detailCode: 'selection-probe-unavailable');
      },
    );
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
          selection: const ProjectSelectorSelection(),
          generationArgs: const ['gen-l10n'],
          directProbeArgs: const ['--version', '--machine'],
          environmentOverrides: _environmentOverrides,
          selectorHashesByRelativePath: const {},
          machineIdentity: FlutterMachineIdentity(
            frameworkVersion: Version(3, 38, 7),
            frameworkRevision: 'framework-3.38.7',
            engineRevision: 'engine-3.38.7',
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
  frameworkRevision: 'framework-3.41.5',
  engineRevision: 'engine-3.41.5',
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
  List<String>? generationArgs,
  List<String>? directProbeArgs,
  Map<String, String>? environmentOverrides,
}) => L10nToolchainResolved(
  canonicalFlutterExecutable: source.canonicalFlutterExecutable,
  canonicalSdkRoot: source.canonicalSdkRoot,
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

void _expectCall(
  _ProcessCall call, {
  required String executable,
  required List<String> arguments,
  required Directory project,
}) {
  expect(call.executable, executable);
  expect(call.arguments, arguments);
  expect(call.workingDirectory, project.absolute.path);
  expect(call.timeout, const Duration(seconds: 30));
  expect(call.maxOutputBytesPerStream, 1024 * 1024);
  expect(call.environmentOverrides, _environmentOverrides);
  expect(call.includeParentEnvironment, isTrue);
  expect(call.environmentOverrides, isNot(contains('HOME')));
  expect(call.environmentOverrides, isNot(contains('PUB_CACHE')));
}

String _createFlutterSdk(Directory scratch, String name) {
  final sdk = Directory(p.join(scratch.path, name))..createSync();
  final flutter = File(p.join(sdk.path, 'bin', _flutterExecutableName));
  final dartLauncher = File(p.join(sdk.path, 'bin', _dartLauncherName));
  final bundledDart = File(
    p.join(sdk.path, 'bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
  );
  for (final executable in [flutter, dartLauncher, bundledDart]) {
    executable.createSync(recursive: true);
    executable.writeAsStringSync('toolchain fixture\n');
    if (!Platform.isWindows) {
      final chmod = Process.runSync('chmod', ['755', executable.path]);
      if (chmod.exitCode != 0) {
        throw StateError('Could not make fixture executable.');
      }
    }
  }
  return flutter.resolveSymbolicLinksSync();
}

String get _flutterExecutableName =>
    Platform.isWindows ? 'flutter.bat' : 'flutter';

String get _dartLauncherName => Platform.isWindows ? 'dart.bat' : 'dart';

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
}) =>
    '{"frameworkVersion":"$version",'
            '"frameworkRevision":"$frameworkRevision",'
            '"engineRevision":"$engineRevision",'
            '"dartSdkVersion":"$dartSdkVersion"}'
        .codeUnits;

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
    calls.add(
      _ProcessCall(
        executable: executable,
        arguments: List<String>.of(arguments),
        workingDirectory: workingDirectory,
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
        environmentOverrides: Map<String, String>.of(environmentOverrides),
        includeParentEnvironment: includeParentEnvironment,
      ),
    );
    if (_replies.isEmpty) throw StateError('Unexpected process call.');
    final reply = _replies.removeAt(0);
    reply.beforeReturn?.call();
    if (reply.error case final error?) throw error;
    return reply.result!;
  }
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
  });

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Duration timeout;
  final int maxOutputBytesPerStream;
  final Map<String, String> environmentOverrides;
  final bool includeParentEnvironment;
}

final class _ProcessReply {
  const _ProcessReply.result(this.result, {this.beforeReturn}) : error = null;

  const _ProcessReply.error(this.error) : result = null, beforeReturn = null;

  final ManagedProcessResult? result;
  final Exception? error;
  final void Function()? beforeReturn;
}
