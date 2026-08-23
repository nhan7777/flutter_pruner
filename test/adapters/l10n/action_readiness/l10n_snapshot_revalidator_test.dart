import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_preflight.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_snapshot_revalidator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _templatePath = 'lib/l10n/app_en.arb';
const _localePath = 'lib/l10n/app_vi.arb';
const _outputPath = 'lib/generated/app.dart';
const _mainPath = 'lib/main.dart';
const _selectedKey = 'dead';
const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('DefaultL10nSnapshotRevalidator', () {
    test(
      'returns freshly proven immutable identities when still current',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final resolver = _Resolver(
          L10nToolchainStillMatches(fixture.toolchain.identitySha256),
        );
        final loader = _ConfigLoader();
        final revalidator = DefaultL10nSnapshotRevalidator(
          toolchainResolver: resolver,
          configLoader: loader,
        );

        final result = await revalidator.revalidate(
          originalProjectRoot: fixture.projectRoot,
          snapshot: fixture.snapshot,
          toolchain: fixture.toolchain,
        );

        expect(result, isA<L10nSnapshotStillCurrent>());
        final current = result as L10nSnapshotStillCurrent;
        expect(
          current.sourceIdentity,
          const L10nSnapshotSourceIdentityProjector().project(fixture.snapshot),
        );
        expect(
          current.packageResolutionIdentity,
          fixture.snapshot.packageResolutionIdentity,
        );
        expect(current.toolchainIdentity, fixture.toolchain.identitySha256);
        expect(resolver.revalidateCalls, 1);
        expect(loader.loadCalls, 1);
      },
    );

    test('rejects changed source bytes with a stable relative path', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.projectRoot.path, _templatePath),
      ).writeAsStringSync('${_sourceArb.trimRight()} ');

      final result = await fixture.revalidate();

      final drifted = result as L10nSnapshotDrifted;
      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'source-entry-drift',
        relativePath: _templatePath,
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test(
      'rejects present-to-absent and absent-to-present source state',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        File(p.join(fixture.projectRoot.path, _localePath)).deleteSync();
        File(
          p.join(fixture.projectRoot.path, 'dart_test.yaml'),
        ).writeAsStringSync('tags: {}\n');

        final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

        _expectFailure(
          drifted,
          L10nEvidenceRejectionCode.sourceDrift,
          'source-entry-drift',
          relativePath: _localePath,
        );
        _expectFailure(
          drifted,
          L10nEvidenceRejectionCode.sourceDrift,
          'source-entry-drift',
          relativePath: 'dart_test.yaml',
        );
      },
    );

    test('rejects source mode drift', () async {
      if (Platform.isWindows) return;
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final file = File(p.join(fixture.projectRoot.path, _templatePath));
      _setMode(file, 0x180);

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'source-entry-drift',
        relativePath: _templatePath,
      );
    });

    test(
      'classifies raw lock and package-file drift as package drift',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        File(
          p.join(fixture.projectRoot.path, 'pubspec.lock'),
        ).writeAsStringSync('packages:\n  changed: true\n');
        File(
            p.join(
              fixture.projectRoot.path,
              '.dart_tool',
              'package_graph.json',
            ),
          )
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('{}\n');

        final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

        for (final path in const [
          'pubspec.lock',
          '.dart_tool/package_graph.json',
        ]) {
          _expectFailure(
            drifted,
            L10nEvidenceRejectionCode.packageResolutionDrift,
            'package-entry-drift',
            relativePath: path,
          );
        }
      },
    );

    test('rejects selected package mapping drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final file = File(
        p.join(fixture.projectRoot.path, '.dart_tool', 'package_config.json'),
      );
      final decoded =
          jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      final packages = decoded['packages']! as List<Object?>;
      packages.cast<Map<String, Object?>>().first['rootUri'] = fixture
          .flutterPackage
          .uri
          .toString();
      file.writeAsStringSync(jsonEncode(decoded));

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'selected-package-root-mismatch',
        relativePath: '.dart_tool/package_config.json',
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test('rejects a forged retained package-resolution identity', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final forged = _copySnapshot(
        fixture.snapshot,
        packageResolutionIdentity: _hash('forged-package-resolution'),
      );

      final drifted =
          await fixture.revalidate(snapshot: forged) as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'package-resolution-identity-drift',
      );
    });

    test('rejects canonical external package authority drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.flutterPackage.path, 'lib', 'widgets.dart'),
      ).writeAsStringSync('abstract class ChangedBuildContext {}\n');

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'package-authority-identity-drift',
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test('rejects external analyzer-options authority drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.flutterPackage.path, 'lib', 'options.yaml'),
      ).writeAsStringSync('analyzer:\n  errors:\n    dead_code: error\n');

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'analysis-options-external-drift',
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test('rejects newly admitted ARB and Dart analyzer members', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.projectRoot.path, 'lib/l10n/app_fr.arb'),
      ).writeAsStringSync('{"@@locale":"fr","alive":"Vivant"}\n');
      File(
        p.join(fixture.projectRoot.path, 'lib/extra.dart'),
      ).writeAsStringSync('void extra() {}\n');

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'arb-family-membership-drift',
      );
      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'analyzer-closure-membership-drift',
      );
    });

    test('rejects output-directory sibling membership drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.projectRoot.path, 'lib/generated/notes.txt'),
      ).writeAsStringSync('new output sibling\n');

      final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'output-sibling-membership-drift',
      );
    });

    test(
      'sandwiches toolchain drift with complete membership passes',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);

        final drifted =
            await fixture.revalidate(
                  beforeFinalAuthorityPass: () async {
                    File(
                      p.join(fixture.projectRoot.path, 'lib/l10n/app_fr.arb'),
                    ).writeAsStringSync('{"@@locale":"fr","alive":"Vivant"}\n');
                    File(
                      p.join(fixture.projectRoot.path, 'lib/new.dart'),
                    ).writeAsStringSync('void addedAfterFirstPass() {}\n');
                    File(
                      p.join(
                        fixture.projectRoot.path,
                        'lib/generated/notes.txt',
                      ),
                    ).writeAsStringSync('late sibling\n');
                  },
                )
                as L10nSnapshotDrifted;

        for (final detailCode in const [
          'arb-family-membership-drift',
          'analyzer-closure-membership-drift',
          'output-sibling-membership-drift',
        ]) {
          _expectFailure(
            drifted,
            L10nEvidenceRejectionCode.sourceDrift,
            detailCode,
          );
        }
      },
    );

    test('maps strict configuration rejection to typed source drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final loader = _ConfigLoader(
        result: L10nGenerationConfigRejected(const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.unsupportedConfiguration,
            stage: 'injected',
            detailCode: 'unsupported-flutter-version',
            relativePath: '/private/source/l10n.yaml',
          ),
        ]),
      );

      final drifted =
          await fixture.revalidate(configLoader: loader) as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'strict-configuration-unsupported-flutter-version',
      );
      _expectRedacted(drifted, fixture.scratch.path);
      expect(
        drifted.failures.any((failure) => failure.relativePath != null),
        isFalse,
      );
    });

    test(
      'rejects a freshly loaded strict configuration identity change',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final file = File(p.join(fixture.projectRoot.path, 'l10n.yaml'));
        file.writeAsStringSync(
          file.readAsStringSync().replaceFirst(
            'nullable-getter: true',
            'nullable-getter: false',
          ),
        );

        final drifted = await fixture.revalidate() as L10nSnapshotDrifted;

        _expectFailure(
          drifted,
          L10nEvidenceRejectionCode.sourceDrift,
          'strict-configuration-identity-drift',
        );
      },
    );

    test('preserves stable toolchain drift without leaking paths', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final resolver = _Resolver(
        const L10nToolchainChanged(
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.toolchainDrift,
            stage: 'toolchain-revalidation',
            detailCode: 'selector-hash-drift',
            relativePath: '.fvmrc',
          ),
        ),
      );

      final drifted =
          await fixture.revalidate(resolver: resolver) as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.toolchainDrift,
        'selector-hash-drift',
        relativePath: '.fvmrc',
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test('converts dependency exceptions to redacted typed drift', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final resolver = _Resolver.throwing(
        StateError('secret at ${fixture.scratch.path}'),
      );
      final loader = _ConfigLoader(
        error: StateError('secret at ${fixture.projectRoot.path}'),
      );

      final drifted =
          await fixture.revalidate(resolver: resolver, configLoader: loader)
              as L10nSnapshotDrifted;

      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.sourceDrift,
        'strict-configuration-revalidation-failed',
      );
      _expectFailure(
        drifted,
        L10nEvidenceRejectionCode.toolchainDrift,
        'toolchain-revalidation-failed',
      );
      _expectRedacted(drifted, fixture.scratch.path);
    });

    test(
      'rejects byte-identical source replacement during revalidation',
      () async {
        if (Platform.isWindows) return;
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final file = File(p.join(fixture.projectRoot.path, _templatePath));
        final bytes = file.readAsBytesSync();
        final mode = file.statSync().mode & 0xfff;
        final resolver = _Resolver(
          L10nToolchainStillMatches(fixture.toolchain.identitySha256),
          beforeReturn: () async {
            final replaced = File('${file.path}.replaced');
            file.renameSync(replaced.path);
            file.writeAsBytesSync(bytes, flush: true);
            _setMode(file, mode);
            replaced.deleteSync();
          },
        );

        final drifted =
            await fixture.revalidate(resolver: resolver) as L10nSnapshotDrifted;

        _expectFailure(
          drifted,
          L10nEvidenceRejectionCode.sourceDrift,
          'source-entry-authority-raced',
          relativePath: _templatePath,
        );
        expect(file.readAsBytesSync(), bytes);
      },
    );
  });

  group('L10nSnapshotDrifted', () {
    test('sorts, de-duplicates, and defensively freezes failures', () {
      final mutable = <L10nEvidenceFailure>[
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.toolchainDrift,
          stage: 'z',
          detailCode: 'z',
        ),
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.sourceDrift,
          stage: 'a',
          detailCode: 'a',
        ),
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.sourceDrift,
          stage: 'a',
          detailCode: 'a',
        ),
      ];
      final result = L10nSnapshotDrifted(mutable);
      mutable.clear();

      expect(result.failures, hasLength(2));
      expect(result.failures.first.code, L10nEvidenceRejectionCode.sourceDrift);
      expect(() => result.failures.clear(), throwsUnsupportedError);
      expect(() => L10nSnapshotDrifted(const []), throwsArgumentError);
      expect(
        () => L10nSnapshotDrifted(const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.internalFailure,
            stage: 'snapshot-revalidation',
            detailCode: 'wrong-domain',
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => L10nSnapshotDrifted(const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.sourceDrift,
            stage: 'snapshot-revalidation',
            detailCode: 'source-entry-drift',
            relativePath: '/private/project/lib/main.dart',
          ),
        ]),
        throwsArgumentError,
      );
      expect(
        () => L10nSnapshotDrifted(const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.sourceDrift,
            stage: 'snapshot revalidation: /private/project',
            detailCode: 'exception: secret',
          ),
        ]),
        throwsArgumentError,
      );
    });
  });
}

final class _Resolver implements L10nToolchainResolver {
  _Resolver(this.result, {this.beforeReturn}) : error = null;

  _Resolver.throwing(this.error) : result = null, beforeReturn = null;

  final L10nToolchainRevalidationResult? result;
  final Object? error;
  final Future<void> Function()? beforeReturn;
  int revalidateCalls = 0;

  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) => throw UnsupportedError('not used');

  @override
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  }) async {
    revalidateCalls++;
    final thrown = error;
    if (thrown != null) _throwInjected(thrown);
    await beforeReturn?.call();
    return result!;
  }
}

final class _ConfigLoader implements L10nGenerationConfigLoader {
  _ConfigLoader({this.result, this.error});

  final L10nGenerationConfigLoadResult? result;
  final Object? error;
  int loadCalls = 0;

  @override
  Future<L10nGenerationConfigLoadResult> load({
    required ProjectContext project,
    required FlutterMachineIdentity toolchain,
  }) async {
    loadCalls++;
    final thrown = error;
    if (thrown != null) _throwInjected(thrown);
    final injected = result;
    if (injected != null) return injected;
    return const DefaultL10nGenerationConfigLoader().load(
      project: project,
      toolchain: toolchain,
    );
  }
}

final class _Fixture {
  _Fixture._({
    required this.scratch,
    required this.projectRoot,
    required this.flutterPackage,
    required this.toolchain,
    required this.snapshot,
  });

  final Directory scratch;
  final Directory projectRoot;
  final Directory flutterPackage;
  final L10nToolchainResolved toolchain;
  final L10nFamilySnapshot snapshot;

  Future<L10nSnapshotRevalidationResult> revalidate({
    L10nToolchainResolver? resolver,
    L10nGenerationConfigLoader? configLoader,
    L10nFamilySnapshot? snapshot,
    Future<void> Function()? beforeFinalAuthorityPass,
  }) {
    final resolvedResolver =
        resolver ??
        _Resolver(L10nToolchainStillMatches(toolchain.identitySha256));
    final resolvedLoader = configLoader ?? _ConfigLoader();
    final revalidator = beforeFinalAuthorityPass == null
        ? DefaultL10nSnapshotRevalidator(
            toolchainResolver: resolvedResolver,
            configLoader: resolvedLoader,
          )
        : DefaultL10nSnapshotRevalidator.testing(
            toolchainResolver: resolvedResolver,
            configLoader: resolvedLoader,
            beforeFinalAuthorityPass: beforeFinalAuthorityPass,
          );
    return revalidator.revalidate(
      originalProjectRoot: projectRoot,
      snapshot: snapshot ?? this.snapshot,
      toolchain: toolchain,
    );
  }

  static Future<_Fixture> create() async {
    final allocated = Directory.systemTemp.createTempSync(
      'l10n-snapshot-revalidator-test-',
    );
    final scratch = Directory(allocated.resolveSymbolicLinksSync());
    try {
      final projectRoot = Directory(p.join(scratch.path, 'project'))
        ..createSync();
      final sdk = Directory(p.join(scratch.path, 'flutter-sdk'))..createSync();
      final flutterPackage = Directory(p.join(sdk.path, 'packages', 'flutter'))
        ..createSync(recursive: true);
      Directory(p.join(flutterPackage.path, 'lib')).createSync();
      File(
        p.join(flutterPackage.path, 'lib', 'widgets.dart'),
      ).writeAsStringSync('abstract class BuildContext {}\n');
      File(
        p.join(flutterPackage.path, 'lib', 'options.yaml'),
      ).writeAsStringSync('analyzer:\n  errors: {}\n');
      File(
        p.join(flutterPackage.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: flutter\n');
      final toolchain = _toolchain(sdk);
      final packageConfigBytes = utf8.encode(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'fixture',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.9',
            },
            {
              'name': 'flutter',
              'rootUri': flutterPackage.uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.9',
            },
          ],
          'generator': 'pub',
          'generatorVersion': toolchain.machineIdentity.dartSdkVersion,
          'flutterRoot': sdk.uri.toString(),
          'flutterVersion': '${toolchain.machineIdentity.frameworkVersion}',
        }),
      );
      _writeProject(projectRoot, packageConfigBytes);
      final project = _project(projectRoot);
      final configResult = await const DefaultL10nGenerationConfigLoader().load(
        project: project,
        toolchain: toolchain.machineIdentity,
      );
      if (configResult is! L10nGenerationConfigReady) {
        throw StateError('fixture config rejected');
      }
      final contextResult = const L10nAnalyzerContextAuthorityProjector()
          .project(project);
      if (contextResult is! L10nAnalyzerContextAuthorityProjectionReady) {
        throw StateError('fixture context rejected');
      }
      final packageResult = const L10nPackageConfigProjector().project(
        sourceBytes: packageConfigBytes,
        canonicalProjectRoot: projectRoot.resolveSymbolicLinksSync(),
        selectedPackageName: 'fixture',
        toolchain: toolchain,
      );
      if (packageResult is! L10nPackageConfigProjectionReady) {
        throw StateError('fixture package projection rejected');
      }
      return _Fixture._(
        scratch: scratch,
        projectRoot: projectRoot,
        flutterPackage: flutterPackage,
        toolchain: toolchain,
        snapshot: _snapshot(
          projectRoot: projectRoot,
          flutterPackage: flutterPackage,
          packageConfigBytes: packageConfigBytes,
          configurationIdentity: configResult.config.configurationIdentity,
          contextIdentity: contextResult.projection.identity,
          packageProjection: packageResult.projection,
          toolchainIdentity: toolchain.identitySha256,
        ),
      );
    } catch (_) {
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      rethrow;
    }
  }

  void dispose() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  }
}

ProjectContext _project(Directory root) => ProjectContext(
  root: root,
  pubspec: _pubspec,
  packageName: 'fixture',
  analysisMode: AnalysisMode.application,
  targetMatrix: TargetMatrix.declared([
    BuildTarget(name: 'app', platform: 'android', entrypoint: _mainPath),
  ]),
  rootCoverage: RootCoverage.applicationApi(),
);

void _writeProject(Directory root, List<int> packageConfigBytes) {
  void write(String relativePath, String contents) {
    final file = File(p.join(root.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  write('pubspec.yaml', _pubspecSource);
  write('pubspec.lock', 'packages: {}\n');
  write('l10n.yaml', _l10nYamlSource);
  write('analysis_options.yaml', _analysisOptionsSource);
  write(_mainPath, 'void main() {}\n');
  write(_templatePath, _sourceArb);
  write(_localePath, _localeArb);
  write(_outputPath, _generatedSource);
  final packageConfig = File(
    p.join(root.path, '.dart_tool', 'package_config.json'),
  );
  packageConfig.parent.createSync(recursive: true);
  packageConfig.writeAsBytesSync(packageConfigBytes);
}

L10nFamilySnapshot _snapshot({
  required Directory projectRoot,
  required Directory flutterPackage,
  required List<int> packageConfigBytes,
  required String configurationIdentity,
  required String contextIdentity,
  required L10nPackageConfigProjection packageProjection,
  required String toolchainIdentity,
}) {
  final template = ImmutableBytes.copyOf(utf8.encode(_sourceArb));
  final locale = ImmutableBytes.copyOf(utf8.encode(_localeArb));
  final parsedTemplate = ArbDocument.parse(template.copy());
  final parsedLocale = ArbDocument.parse(locale.copy());
  if (parsedTemplate is! ArbParseSuccess || parsedLocale is! ArbParseSuccess) {
    throw StateError('fixture ARB rejected');
  }
  final mutation = L10nArbMutationPlanner.plan(
    templatePath: _templatePath,
    documentsByPath: {
      _templatePath: parsedTemplate.document,
      _localePath: parsedLocale.document,
    },
    selectedKeys: const {_selectedKey},
  );
  if (mutation is! L10nArbMutationPlanReady) {
    throw StateError('fixture mutation rejected');
  }
  L10nSnapshotEntry present(String path, L10nSnapshotRole role) {
    final file = File(p.join(projectRoot.path, path));
    final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
    return L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: L10nSnapshotPresent(
        sourceBytes: bytes,
        stageBytes: bytes,
        sourceSha256: bytes.sha256Hex,
        posixMode: Platform.isWindows ? null : file.statSync().mode & 0xfff,
      ),
    );
  }

  L10nSnapshotEntry absent(String path, L10nSnapshotRole role) =>
      L10nSnapshotEntry(
        relativePosixPath: path,
        role: role,
        state: const L10nSnapshotAbsent(),
      );

  final provisional = L10nFamilySnapshot(
    entries: {
      'pubspec.yaml': present('pubspec.yaml', L10nSnapshotRole.pubspec),
      'pubspec.lock': present('pubspec.lock', L10nSnapshotRole.lockfile),
      'l10n.yaml': present('l10n.yaml', L10nSnapshotRole.l10nConfig),
      '.dart_tool/package_config.json': present(
        '.dart_tool/package_config.json',
        L10nSnapshotRole.packageConfig,
      ),
      '.dart_tool/package_graph.json': absent(
        '.dart_tool/package_graph.json',
        L10nSnapshotRole.packageGraph,
      ),
      'analysis_options.yaml': present(
        'analysis_options.yaml',
        L10nSnapshotRole.verificationInput,
      ),
      'dart_test.yaml': absent(
        'dart_test.yaml',
        L10nSnapshotRole.verificationInput,
      ),
      _mainPath: present(_mainPath, L10nSnapshotRole.analyzerSource),
      _templatePath: present(_templatePath, L10nSnapshotRole.arbTemplate),
      _localePath: present(_localePath, L10nSnapshotRole.arbLocale),
      _outputPath: present(_outputPath, L10nSnapshotRole.generatedBase),
    },
    mutationPlan: mutation.plan,
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {_selectedKey},
    expectedGeneratedMemberKindsByKey: const {
      'alive': ArbGeneratedMemberKind.getter,
      'dead': ArbGeneratedMemberKind.getter,
    },
    expectedGeneratedPaths: const {_outputPath},
    optionalUntranslatedPath: null,
    verificationClosure: L10nVerificationClosure(
      projectOwnedDartPaths: const {_mainPath, _outputPath},
      analyzerRootIdentity: _hash('analyzer'),
    ),
    analysisOptionsProjection: L10nAnalysisOptionsProjection(
      projectOwnedPaths: const {'analysis_options.yaml'},
      externalAuthorities: [_externalOptionsAuthority(flutterPackage)],
      contextAuthorityIdentity: contextIdentity,
    ),
    provenUnrelatedOutputSiblings: const {},
    familyFingerprint: _hash('family'),
    selectionFingerprint: _hash('selection'),
    l10nAnalysisFingerprint: _hash('analysis'),
    configurationIdentity: configurationIdentity,
    packageConfigProjectionIdentity: packageProjection.authorityIdentity,
    packageResolutionIdentity: _hash('packages'),
    toolchainIdentity: toolchainIdentity,
    projectSemantics: L10nProjectSemantics(
      pubspec: _pubspec,
      packageName: 'fixture',
      analysisMode: AnalysisMode.application,
      targetMatrix: TargetMatrix.declared([
        BuildTarget(name: 'app', platform: 'android', entrypoint: _mainPath),
      ]),
      rootCoverage: RootCoverage.applicationApi(),
    ),
  );
  return _copySnapshot(
    provisional,
    packageResolutionIdentity:
        const L10nSnapshotPackageResolutionIdentityProjector().project(
          snapshot: provisional,
          packageProjection: packageProjection,
        ),
  );
}

L10nToolchainResolved _toolchain(Directory sdk) => L10nToolchainResolved(
  canonicalFlutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
  canonicalSdkRoot: sdk.resolveSymbolicLinksSync(),
  launch: L10nToolchainLaunch(
    canonicalDartExecutable: p.join(
      sdk.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'dart',
    ),
    canonicalFlutterToolsPackageConfig: p.join(
      sdk.path,
      'packages',
      'flutter_tools',
      '.dart_tool',
      'package_config.json',
    ),
    canonicalFlutterToolsSnapshot: p.join(
      sdk.path,
      'bin',
      'cache',
      'flutter_tools.snapshot',
    ),
  ),
  selection: const ProjectSelectorSelection(),
  generationArgs: const ['gen-l10n'],
  directProbeArgs: const ['--version', '--machine'],
  environmentOverrides: const {},
  selectorHashesByRelativePath: const {},
  machineIdentity: FlutterMachineIdentity(
    frameworkVersion: Version(3, 41, 5),
    frameworkRevision: '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
    engineRevision: '4141414141414141414141414141414141414141',
    dartSdkVersion: '3.11.3',
  ),
  originalSelectionProbeSha256: _identity,
  identitySha256: _identity,
);

L10nFamilySnapshot _copySnapshot(
  L10nFamilySnapshot source, {
  required String packageResolutionIdentity,
}) => L10nFamilySnapshot(
  entries: source.entries,
  mutationPlan: source.mutationPlan,
  selectedNodeIds: source.selectedNodeIds,
  selectedKeys: source.selectedKeys,
  expectedGeneratedMemberKindsByKey: source.expectedGeneratedMemberKindsByKey,
  expectedGeneratedPaths: source.expectedGeneratedPaths,
  optionalUntranslatedPath: source.optionalUntranslatedPath,
  verificationClosure: source.verificationClosure,
  analysisOptionsProjection: source.analysisOptionsProjection,
  provenUnrelatedOutputSiblings: source.provenUnrelatedOutputSiblings,
  familyFingerprint: source.familyFingerprint,
  selectionFingerprint: source.selectionFingerprint,
  l10nAnalysisFingerprint: source.l10nAnalysisFingerprint,
  configurationIdentity: source.configurationIdentity,
  packageConfigProjectionIdentity: source.packageConfigProjectionIdentity,
  packageResolutionIdentity: packageResolutionIdentity,
  toolchainIdentity: source.toolchainIdentity,
  projectSemantics: source.projectSemantics,
);

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

void _expectFailure(
  L10nSnapshotDrifted result,
  L10nEvidenceRejectionCode code,
  String detailCode, {
  String? relativePath,
}) {
  expect(
    result.failures.where(
      (failure) =>
          failure.code == code &&
          failure.detailCode == detailCode &&
          (relativePath == null || failure.relativePath == relativePath),
    ),
    hasLength(1),
    reason: result.failures
        .map(
          (failure) =>
              '${failure.code.name}/${failure.stage}/'
              '${failure.relativePath}/${failure.detailCode}',
        )
        .join(', '),
  );
}

void _expectRedacted(L10nSnapshotDrifted result, String absolutePath) {
  for (final failure in result.failures) {
    expect(failure.stage, isNot(contains(absolutePath)));
    expect(failure.detailCode, isNot(contains(absolutePath)));
    expect(failure.relativePath, isNot(contains(absolutePath)));
  }
}

void _setMode(File file, int mode) {
  final result = Process.runSync('chmod', [
    mode.toRadixString(8).padLeft(4, '0'),
    file.path,
  ]);
  if (result.exitCode != 0) throw StateError('chmod failed');
}

Never _throwInjected(Object value) {
  if (value is Error) throw value;
  if (value is Exception) throw value;
  throw StateError('Injected value is not throwable.');
}

L10nExternalAnalysisOptionsAuthority _externalOptionsAuthority(
  Directory packageRoot,
) {
  final file = File(p.join(packageRoot.path, 'lib', 'options.yaml'));
  final before = file.statSync();
  final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
  final after = file.statSync();
  if (before.size != after.size || before.modified != after.modified) {
    throw StateError('external options changed while captured');
  }
  return L10nExternalAnalysisOptionsAuthority(
    canonicalPath: file.resolveSymbolicLinksSync(),
    authorityRoot: packageRoot.resolveSymbolicLinksSync(),
    sourceBytes: bytes,
    posixMode: Platform.isWindows ? null : before.mode & 0xfff,
    size: before.size,
    modifiedMicros: before.modified.microsecondsSinceEpoch,
    changedMicros: before.changed.microsecondsSinceEpoch,
  );
}

const _sourceArb =
    '{"@@locale":"en","alive":"Alive","dead":"Dead",'
    '"@dead":{"description":"Remove exactly"}}\n';
const _localeArb = '{"@@locale":"vi","alive":"Song","dead":"Chet"}\n';
const _generatedSource = '''
class BuildContext {}

abstract class AppLocalizations {
  static AppLocalizations? of(BuildContext context) => null;
  String get alive;
  String get dead;
}
''';
const _pubspecSource = '''
name: fixture
environment:
  sdk: ">=3.9.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''';
const Map<String, Object?> _pubspec = {
  'name': 'fixture',
  'environment': {'sdk': '>=3.9.0 <4.0.0'},
  'dependencies': {
    'flutter': {'sdk': 'flutter'},
  },
  'flutter': {'generate': true},
};
const _l10nYamlSource = '''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-dir: lib/generated
output-localization-file: app.dart
output-class: AppLocalizations
nullable-getter: true
synthetic-package: false
format: false
''';
const _analysisOptionsSource = '''
include: package:flutter/options.yaml
analyzer:
  errors: {}
''';
