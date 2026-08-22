import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/accuracy_model.dart';
import '../../../benchmark/accuracy/src/project_manifest.dart';
import '../../../benchmark/accuracy/src/root_universe.dart';

void main() {
  final fixture =
      Platform.environment['ROOT_UNIVERSE_FIXTURE'] ??
      p.join(
        Directory.current.path,
        'test',
        'fixtures',
        'benchmark_accuracy_oracle',
      );

  test('builds isolated Web, VM, runtime, and external closures', () async {
    final universe = await RootUniverseBuilder(
      manifest: _manifest(),
      projectRoot: fixture,
      packageRoot: fixture,
    ).build();

    expect(universe.rootPolicyVersion, RootUniverseBuilder.policyVersion);
    expect(universe.callbackCapabilities.version, 2);
    expect(
      universe.issues,
      isEmpty,
      reason: 'fixture sources must resolve without analyzer errors',
    );
    expect(
      universe.exactClosureByExecutionTarget['app:web'],
      containsAll(<String>{
        'lib:lib/main_web.dart',
        'lib:lib/src/conditional_web.dart',
        'lib:lib/src/conditional_equality_web.dart',
        'lib:lib/src/sibling_feature.dart',
      }),
      reason: 'full string equality condition mode == web selects Web branch',
    );
    expect(
      universe.exactClosureByExecutionTarget['aux:test:dm1fdGVzdA'],
      contains('lib:lib/src/conditional_io.dart'),
    );
    expect(
      universe.exactClosureByExecutionTarget['aux:test:dm1fdGVzdA'],
      isNot(contains('lib:lib/src/conditional_web.dart')),
    );
    expect(
      universe
          .exactClosureByExecutionTarget['aux:runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dm1FbnRyeQ'],
      isEmpty,
    );
    expect(
      universe
          .retainedClosureByExecutionTarget['aux:runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dm1FbnRyeQ'],
      containsAll(<String>{
        'decl:lib/callbacks.dart#vmEntry',
        'lib:lib/src/conditional_io.dart',
        'lib:lib/src/conditional_web.dart',
      }),
    );
    expect(
      universe.exactClosureByExecutionTarget['aux:external:public-api'],
      containsAll(<String>{
        'decl:lib/src/public_part.dart#publicPartValue',
        'decl:lib/public.dart#publicUsesImportedCallback',
        'decl:lib/src/reexport.dart#publicReexport',
      }),
    );
    expect(
      universe.retainedClosureByExecutionTarget['aux:external:public-api'],
      contains('decl:lib/src/public_part.dart#publicPartValue'),
    );
    expect(
      universe.retainedClosureByExecutionTarget['aux:external:public-api'],
      isNot(contains('lib:lib/callbacks.dart')),
      reason: 'public-surface traversal must not follow imports',
    );
    expect(
      universe.retainedClosureByExecutionTarget['aux:external:public-api'],
      isNot(contains('decl:lib/src/reexport.dart#hiddenReexport')),
      reason: 'show combinator must constrain external declarations',
    );
    expect(
      universe.retainedClosureByExecutionTarget['aux:external:public-api'],
      isNot(contains('decl:lib/src/conditional_web.dart#selected')),
      reason: 'outer show must block transitive exports',
    );
  });

  test('does not root a callback owner sibling and tracks source ownership', () async {
    final universe = await RootUniverseBuilder(
      manifest: _manifest(),
      projectRoot: fixture,
      packageRoot: fixture,
    ).build();

    final runtimeRoots = universe.roots
        .where(
          (root) => root.executionTargetIds.contains(
            'aux:runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dm1FbnRyeQ',
          ),
        )
        .map((root) => root.canonicalNodeId)
        .toSet();
    expect(runtimeRoots, contains('decl:lib/callbacks.dart#vmEntry'));
    expect(runtimeRoots, contains('lib:lib/callbacks.dart'));
    for (final context in [
      'aux:runtime:isolateSpawn.bGliL2NhbGxiYWNrcy5kYXJ0.aXNvbGF0ZVdvcmtlcg',
      'aux:runtime:workmanagerInitialize.bGliL2NhbGxiYWNrcy5kYXJ0.d29ya21hbmFnZXJDYWxsYmFjaw',
      'aux:runtime:ffiNativeCallback.bGliL2NhbGxiYWNrcy5kYXJ0.ZmZpTmF0aXZlQ2FsbGJhY2s',
    ]) {
      expect(
        universe.roots
            .where((root) => root.executionTargetIds.contains(context))
            .map((root) => root.canonicalNodeId),
        contains('lib:lib/callbacks.dart'),
        reason: '$context has a resolved callback-owner root',
      );
    }
    expect(
      universe.roots
          .where(
            (root) => root.executionTargetIds.contains(
              'aux:runtime:isolateSpawn.bGliL2NhbGxiYWNrcy5kYXJ0.aXNvbGF0ZVdvcmtlcg',
            ),
          )
          .map((root) => root.canonicalNodeId),
      contains('decl:lib/callbacks.dart#isolateWorker'),
    );
    expect(
      universe.executionTargets
          .where(
            (target) =>
                target.id ==
                'aux:runtime:isolateSpawn.bGliL2NhbGxiYWNrcy5kYXJ0.aXNvbGF0ZVdvcmtlcg',
          )
          .length,
      1,
      reason: 'multiple invocations of the same executable deduplicate',
    );
    expect(
      universe.roots.map((root) => root.canonicalNodeId),
      containsAll(<String>{
        'decl:lib/callbacks.dart#constantVmEntry',
        'decl:lib/callbacks.dart#A.run',
        'decl:lib/callbacks.dart#B.run',
        'decl:lib/callbacks.dart#Constructed.named',
        'decl:lib/callbacks.dart#CallbackEnum.run',
        'decl:lib/callbacks.dart#CallbackExtensionType.run',
      }),
    );
    final unnamedExtensionRoots = universe.roots
        .map((root) => root.canonicalNodeId)
        .where(
          (node) =>
              node.startsWith('decl:lib/callbacks.dart#unnamed-extension:') &&
              node.endsWith('.unnamedCallback'),
        )
        .toSet();
    expect(unnamedExtensionRoots, hasLength(3));
    expect(
      unnamedExtensionRoots
          .where(
            (node) => RegExp(
              r'#unnamed-extension:[0-9a-f]{64}~[12]\.unnamedCallback$',
            ).hasMatch(node),
          )
          .length,
      2,
      reason: 'token-identical declarations use deterministic ordinals',
    );
    expect(unnamedExtensionRoots.join('\n'), isNot(contains('extension@')));
    expect(
      universe.issues,
      isNot(contains('[callback-identity-unavailable] lib/callbacks.dart')),
      reason: 'declaration metadata must share the analyzer fragment locator',
    );
    expect(
      runtimeRoots,
      isNot(contains('decl:lib/callbacks.dart#unrelatedSibling')),
    );
    expect(
      universe.executionTargets.map((target) => target.id),
      isNot(contains(startsWith('aux:runtime:dartUiCallback.'))),
      reason: 'a package:flutter ui stub is not a production dart:ui fact',
    );
    expect(universe.uncertainties.join('\n'), contains('[unknown-callback]'));
    expect(
      universe.sourceBoundary['lib/nested/lib/nested.dart']!.kind,
      SourceBoundaryKind.nestedPackageOwned,
    );
    expect(
      universe.sourceBoundary['lib/generated.g.dart']!.kind,
      SourceBoundaryKind.generated,
    );
    expect(
      universe.sourceBoundary['bin/not_a_root.dart']!.kind,
      SourceBoundaryKind.modeled,
    );
    for (final path in [
      'bin/not_a_root.dart',
      'tool/not_a_root.dart',
      'benchmark/not_a_root.dart',
      'example/not_a_root.dart',
      'integration_test/not_a_root.dart',
    ]) {
      expect(
        universe.roots.map((root) => root.sourcePath),
        isNot(contains(path)),
        reason: '$path is not an inferred root',
      );
    }
  });

  test('retains sibling-package callbacks and their back-edges', () async {
    final universe = await RootUniverseBuilder(
      manifest: _manifest(),
      projectRoot: fixture,
      packageRoot: fixture,
    ).build();
    const siblingPath = 'dependencies/sibling/lib/sibling.dart';
    const isolateTarget =
        'aux:runtime:isolateSpawn.ZGVwZW5kZW5jaWVzL3NpYmxpbmcvbGliL3NpYmxpbmcuZGFydA.c2libGluZ0VudHJ5';

    expect(
      universe.roots
          .where((root) => root.executionTargetIds.contains(isolateTarget))
          .map((root) => root.canonicalNodeId),
      containsAll(<String>{
        'decl:$siblingPath#siblingEntry',
        'lib:$siblingPath',
      }),
    );
    expect(
      universe.retainedClosureByExecutionTarget[isolateTarget],
      contains('lib:lib/conditional.dart'),
      reason: 'a sibling callback can import back into the selected package',
    );
    expect(universe.sourceBoundary[siblingPath]!.owner, 'sibling');
  });

  test(
    'retains project-external sibling callbacks under their package owner',
    () async {
      final sandbox = Directory.systemTemp.createTempSync(
        'root_external_sibling_',
      );
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });
      final selected = Directory(p.join(sandbox.path, 'app'))..createSync();
      final sibling = Directory(p.join(sandbox.path, 'shared_folder'))
        ..createSync();
      File(
        p.join(selected.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: selected_app\nenvironment:\n  sdk: ^3.9.0\n');
      File(p.join(sibling.path, 'pubspec.yaml')).writeAsStringSync(
        'name: actual_sibling\nenvironment:\n  sdk: ^3.9.0\n',
      );
      File(p.join(selected.path, 'lib', 'main.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "import 'package:actual_sibling/sibling.dart';\n"
          'void main() => siblingEntry();\n',
        );
      File(
        p.join(selected.path, 'lib', 'back.dart'),
      ).writeAsStringSync('void selectedBackEdge() {}\n');
      File(p.join(sibling.path, 'lib', 'sibling.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "import 'package:selected_app/back.dart';\n"
          "@pragma('vm:entry-point')\n"
          'void siblingEntry() => selectedBackEdge();\n',
        );
      File(p.join(selected.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"selected_app","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"actual_sibling","rootUri":"../../shared_folder/","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      File(p.join(sibling.path, '.dart_tool', 'package_config.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"selected_app","rootUri":"../../app/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"actual_sibling","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
      const siblingPath = 'shared_folder/lib/sibling.dart';
      const callbackTarget =
          'runtime:vmPragma.c2hhcmVkX2ZvbGRlci9saWIvc2libGluZy5kYXJ0.c2libGluZ0VudHJ5';

      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          entrypoint: 'lib/main.dart',
          publicEntrypoints: const [],
          auxiliaryTargets: [
            OracleAuxiliaryExecutionTarget(
              id: callbackTarget,
              domain: OracleAuxiliaryDomain.runtime,
              environmentValues: const {'callback.kind': 'vmPragma'},
              environmentComplete: false,
              reason: 'no unique compatible vmPragma target',
            ),
          ],
        ),
        projectRoot: sandbox.path,
        packageRoot: selected.path,
      ).build();

      expect(universe.issues, isEmpty);
      expect(universe.sourceBoundary[siblingPath]!.owner, 'actual_sibling');
      expect(
        universe.retainedClosureByExecutionTarget['aux:$callbackTarget'],
        containsAll(<String>{
          'decl:$siblingPath#siblingEntry',
          'lib:app/lib/back.dart',
        }),
      );
    },
  );

  test(
    'preserves sibling public ownership across package boundaries',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          publicEntrypoints: const ['lib/public_sibling.dart'],
        ),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();

      expect(
        universe.exactClosureByExecutionTarget['aux:external:public-api'],
        contains('decl:dependencies/sibling/lib/sibling.dart#siblingEntry'),
      );
      expect(
        universe.sourceBoundary['dependencies/sibling/lib/sibling.dart']!.owner,
        'sibling',
      );
      expect(universe.issues, isNot(contains(startsWith('[public-owner-'))));
    },
  );

  test('fails closed when a public declaration owner is invalid', () async {
    final sandbox = Directory.systemTemp.createTempSync('invalid_owner_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    await _copyFixture(Directory(fixture), sandbox);
    File(
      p.join(sandbox.path, 'lib', 'public_invalid_owner.dart'),
    ).writeAsStringSync("part 'src/invalid_public_part.dart';\n");
    File(
      p.join(sandbox.path, 'lib', 'src', 'invalid_public_part.dart'),
    ).writeAsStringSync(
      "part of '../different_owner.dart';\n\n"
      'void invalidOwnerDeclaration() {}\n',
    );
    final universe = await RootUniverseBuilder(
      manifest: _manifest(
        publicEntrypoints: const ['lib/public_invalid_owner.dart'],
      ),
      projectRoot: sandbox.path,
      packageRoot: sandbox.path,
    ).build();

    expect(
      universe.issues,
      contains('[public-owner-invalid] lib/src/invalid_public_part.dart'),
    );
    expect(
      universe.exactClosureByExecutionTarget['aux:external:public-api'],
      isNot(
        contains(
          'decl:lib/src/invalid_public_part.dart#invalidOwnerDeclaration',
        ),
      ),
    );
    expect(
      universe.retainedClosureByExecutionTarget['aux:external:public-api'],
      contains('decl:lib/src/invalid_public_part.dart#invalidOwnerDeclaration'),
    );
  });

  test(
    'does not make child exports exact through an invalid exporter',
    () async {
      final sandbox = Directory.systemTemp.createTempSync('invalid_exporter_');
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });
      await _copyFixture(Directory(fixture), sandbox);
      File(
        p.join(sandbox.path, 'lib', 'public_invalid_exporter.dart'),
      ).writeAsStringSync(
        "export 'src/valid_export_child.dart';\n\n"
        'void brokenExporter( {\n',
      );
      File(
        p.join(sandbox.path, 'lib', 'src', 'valid_export_child.dart'),
      ).writeAsStringSync('void retainedChildDeclaration() {}\n');

      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          publicEntrypoints: const ['lib/public_invalid_exporter.dart'],
        ),
        projectRoot: sandbox.path,
        packageRoot: sandbox.path,
      ).build();

      expect(
        universe.issues,
        contains('[public-owner-invalid] lib/public_invalid_exporter.dart'),
      );
      expect(
        universe.retainedClosureByExecutionTarget['aux:external:public-api'],
        contains(
          'decl:lib/src/valid_export_child.dart#retainedChildDeclaration',
        ),
      );
      expect(
        universe.exactClosureByExecutionTarget['aux:external:public-api'],
        isNot(
          contains(
            'decl:lib/src/valid_export_child.dart#retainedChildDeclaration',
          ),
        ),
      );
    },
  );

  test(
    'freezes all outward collections and serializes deterministically',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();

      expect(
        () => universe.roots.add(universe.roots.first),
        throwsUnsupportedError,
      );
      expect(
        () => universe.exactClosureByExecutionTarget['app:web']!.add('forged'),
        throwsUnsupportedError,
      );
      expect(universe.toRootManifestJson(), universe.toRootManifestJson());
      expect(universe.toRootManifestJson(), isNot(contains(fixture)));
    },
  );

  test(
    'reports package-config and unknown callback failures without omission',
    () async {
      final manifest = _manifest();
      final missing = await RootUniverseBuilder(
        manifest: _manifest(
          auxiliaryTargets: manifest.oracleAuxiliaryExecutionTargets
              .where(
                (target) => !target.id.contains(
                  'ZGVwZW5kZW5jaWVzL3NpYmxpbmcvbGliL3NpYmxpbmcuZGFydA',
                ),
              )
              .toList(),
        ),
        projectRoot: fixture,
        packageRoot: fixture,
        packageConfigPath: p.join(fixture, 'missing.json'),
      ).build();
      expect(missing.issues.join('\n'), contains('[package-config-invalid]'));

      final unknown = await RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      expect(unknown.uncertainties.join('\n'), contains('[unknown-callback]'));
    },
  );

  test('rejects duplicate and borrowed execution contexts', () {
    expect(
      () => RootUniverse(
        rootPolicyVersion: 2,
        callbackCapabilities: const CallbackCapabilityTable(version: 2),
        roots: const [],
        executionTargets: [
          RootExecutionTarget.configured(_manifest().targets.single),
          RootExecutionTarget.configured(_manifest().targets.single),
        ],
        exactClosureByExecutionTarget: const {},
        retainedClosureByExecutionTarget: const {},
        sourceBoundary: OracleSourceBoundary(entries: const {}),
        issues: const [],
        uncertainties: const [],
      ),
      throwsArgumentError,
    );
    expect(
      () => RootExecutionTarget.auxiliary(
        OracleAuxiliaryExecutionTarget(
          id: 'test:borrowed',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {'test.platform': 'vm'},
          environmentComplete: true,
          reason: 'test fixture',
        ),
        sourceTarget: _manifest().targets.single,
      ),
      throwsArgumentError,
    );
  });

  test(
    'keeps the dart-ui capability classifier exact outside normal builder',
    () {
      expect(isExactDartUiCallbackLibraryUri('dart:ui'), isTrue);
      expect(
        isExactDartUiCallbackLibraryUri('package:flutter/ui.dart'),
        isFalse,
      );
    },
  );

  test('rejects incompatible policy versions before traversal', () async {
    await expectLater(
      RootUniverseBuilder(
        manifest: _manifest(rootPolicyVersion: 99),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build(),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: fixture,
        packageRoot: fixture,
        callbackCapabilities: const CallbackCapabilityTable(version: 99),
      ).build(),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('rejects missing and extra auxiliary target definitions', () async {
    await expectLater(
      RootUniverseBuilder(
        manifest: _manifest(auxiliaryTargets: const []),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build(),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      RootUniverseBuilder(
        manifest: _manifest(
          auxiliaryTargets: [
            ..._manifest().oracleAuxiliaryExecutionTargets,
            OracleAuxiliaryExecutionTarget(
              id: 'test:extra',
              domain: OracleAuxiliaryDomain.test,
              environmentValues: const {'test.platform': 'vm'},
              environmentComplete: true,
              reason: 'extra target',
            ),
          ],
        ),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build(),
      throwsA(isA<ArgumentError>()),
    );
  });

  test(
    'rejects configured Dart defines overriding reserved library keys',
    () async {
      await expectLater(
        RootUniverseBuilder(
          manifest: _manifest(
            dartDefines: const {'dart.library.html': 'false'},
          ),
          projectRoot: fixture,
          packageRoot: fixture,
        ).build(),
        throwsA(isA<ArgumentError>()),
      );
    },
  );

  test(
    'rejects recursive absolute and UNC path leakage during serialization',
    () {
      final target = RootExecutionTarget.configured(_manifest().targets.single);
      final universe = RootUniverse(
        rootPolicyVersion: 2,
        callbackCapabilities: const CallbackCapabilityTable(version: 2),
        roots: [
          OracleRoot(
            kind: OracleRootKind.configuredApplicationEntrypoint,
            canonicalNodeId: 'lib:lib/main_web.dart',
            sourcePath: r'\\server\share\entry.dart',
            executionTargetIds: {target.id},
            reason: 'fixture',
          ),
        ],
        executionTargets: [target],
        exactClosureByExecutionTarget: {
          target.id: {'lib:lib/main_web.dart'},
        },
        retainedClosureByExecutionTarget: {
          target.id: {'lib:lib/main_web.dart'},
        },
        sourceBoundary: OracleSourceBoundary(
          entries: {
            r'\\server\share\entry.dart': const SourceBoundaryEntry(
              path: r'\\server\share\entry.dart',
              kind: SourceBoundaryKind.modeled,
              owner: r'\\server\share',
              reason: 'fixture',
            ),
          },
        ),
        issues: const [],
        uncertainties: const [],
      );
      expect(universe.toRootManifestJson, throwsStateError);
    },
  );

  test('rejects dot-segment root paths during serialization', () {
    final target = RootExecutionTarget.configured(_manifest().targets.single);
    final universe = RootUniverse(
      rootPolicyVersion: 2,
      callbackCapabilities: const CallbackCapabilityTable(version: 2),
      roots: [
        OracleRoot(
          kind: OracleRootKind.configuredApplicationEntrypoint,
          canonicalNodeId: 'lib:lib/main_web.dart',
          sourcePath: 'lib/../outside.dart',
          executionTargetIds: {target.id},
          reason: 'fixture',
        ),
      ],
      executionTargets: [target],
      exactClosureByExecutionTarget: {
        target.id: {'lib:lib/main_web.dart'},
      },
      retainedClosureByExecutionTarget: {
        target.id: {'lib:lib/main_web.dart'},
      },
      sourceBoundary: OracleSourceBoundary(
        entries: const {
          'lib/main_web.dart': SourceBoundaryEntry(
            path: 'lib/main_web.dart',
            kind: SourceBoundaryKind.modeled,
            owner: 'fixture',
            reason: 'fixture',
          ),
        },
      ),
      issues: const [],
      uncertainties: const [],
    );

    expect(universe.toRootManifestJson, throwsStateError);
  });

  test(
    'uses complete project-relative test IDs without basename collisions',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      expect(
        universe.executionTargets.map((target) => target.id),
        containsAll(<String>{
          'aux:test:YS9zYW1l',
          'aux:test:Yi9zYW1l',
          'aux:test:YS0tYg',
          'aux:test:YS9i',
        }),
      );
    },
  );

  test('treats a selected nested package as its own modeled package', () async {
    final nested = p.join(fixture, 'lib', 'nested');
    final universe = await RootUniverseBuilder(
      manifest: _manifest(
        entrypoint: 'lib/nested.dart',
        publicEntrypoints: const [],
        auxiliaryTargets: const [],
      ),
      projectRoot: fixture,
      packageRoot: nested,
    ).build();
    expect(
      universe.sourceBoundary['lib/nested/lib/nested.dart']!.kind,
      SourceBoundaryKind.modeled,
    );
    expect(
      universe.exactClosureByExecutionTarget['app:web'],
      contains('lib:lib/nested/lib/nested.dart'),
    );
  });

  test(
    'records Dart symlinks as excluded fail-closed source evidence',
    () async {
      final sandbox = Directory.systemTemp.createTempSync('root_symlink_');
      addTearDown(() {
        if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
      });
      await _copyFixture(Directory(fixture), sandbox);
      await _runGit(sandbox.path, ['init', '--quiet']);
      await _runGit(sandbox.path, ['add', '--all']);
      final targetBlob = File(
        p.join(sandbox.parent.path, '${p.basename(sandbox.path)}-link-target'),
      )..writeAsStringSync('main_web.dart');
      addTearDown(() {
        if (targetBlob.existsSync()) targetBlob.deleteSync();
      });
      final objectId = (await _runGit(sandbox.path, [
        'hash-object',
        '-w',
        targetBlob.path,
      ])).trim();
      await _runGit(sandbox.path, [
        'update-index',
        '--add',
        '--cacheinfo',
        '120000,$objectId,lib/linked.dart',
      ]);
      final inventory = await OracleGitIndexInventory.capture(sandbox.path);
      expect(inventory.modes['lib/linked.dart'], '120000');
      File(
        p.join(sandbox.path, 'lib', 'linked.dart'),
      ).writeAsStringSync('// symlink blob materialized as a regular file\n');
      File(
        p.join(sandbox.path, 'lib', 'untracked.dart'),
      ).writeAsStringSync('void untracked() {}\n');
      File(
        p.join(
          sandbox.path,
          'dependencies',
          'sibling',
          'lib',
          'untracked_callback.dart',
        ),
      ).writeAsStringSync(
        "@pragma('vm:entry-point')\nvoid untrackedSiblingCallback() {}\n",
      );

      final universe = await RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: sandbox.path,
        packageRoot: sandbox.path,
        gitIndexInventory: inventory,
      ).build();

      expect(universe.issues, contains('[source-symlink] lib/linked.dart'));
      expect(
        universe.issues,
        contains('[source-untracked] lib/untracked.dart'),
      );
      expect(
        universe.issues,
        contains(
          '[source-untracked] dependencies/sibling/lib/untracked_callback.dart',
        ),
      );
      expect(universe.issues, isNot(contains('[package-config-invalid]')));
      expect(
        universe.sourceBoundary['lib/linked.dart']?.kind,
        SourceBoundaryKind.excluded,
      );
      expect(
        universe.sourceBoundary['lib/untracked.dart']?.kind,
        SourceBoundaryKind.excluded,
      );
      expect(
        universe.roots.map((root) => root.sourcePath),
        isNot(contains('dependencies/sibling/lib/untracked_callback.dart')),
      );
      expect(
        universe.exactClosureByExecutionTarget.values.expand((nodes) => nodes),
        isNot(contains('lib:lib/linked.dart')),
      );
    },
  );

  test('rejects tracked Dart bytes that diverge from the Git index', () async {
    final sandbox = Directory.systemTemp.createTempSync('root_index_bytes_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    await _copyFixture(Directory(fixture), sandbox);
    await _runGit(sandbox.path, ['init', '--quiet']);
    await _runGit(sandbox.path, ['add', '--all']);
    final inventory = await OracleGitIndexInventory.capture(sandbox.path);
    final main = File(p.join(sandbox.path, 'lib', 'main_web.dart'));
    main.writeAsStringSync('${main.readAsStringSync()}// dirty oracle bytes\n');

    final universe = await RootUniverseBuilder(
      manifest: _manifest(),
      projectRoot: sandbox.path,
      packageRoot: sandbox.path,
      gitIndexInventory: inventory,
    ).build();

    expect(
      universe.issues,
      contains('[source-index-content-mismatch] lib/main_web.dart'),
    );
    expect(universe.exactClosureByExecutionTarget['app:web'], isEmpty);
  });

  test('rejects a Git index that changes after inventory capture', () async {
    final sandbox = Directory.systemTemp.createTempSync('root_index_changed_');
    addTearDown(() {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    });
    await _copyFixture(Directory(fixture), sandbox);
    await _runGit(sandbox.path, ['init', '--quiet']);
    await _runGit(sandbox.path, ['add', '--all']);
    final inventory = await OracleGitIndexInventory.capture(sandbox.path);
    final main = File(p.join(sandbox.path, 'lib', 'main_web.dart'));
    main.writeAsStringSync('${main.readAsStringSync()}// staged replacement\n');
    await _runGit(sandbox.path, ['add', 'lib/main_web.dart']);

    final universe = await RootUniverseBuilder(
      manifest: _manifest(),
      projectRoot: sandbox.path,
      packageRoot: sandbox.path,
      gitIndexInventory: inventory,
    ).build();

    expect(
      universe.issues,
      contains('[source-index-object-mismatch] lib/main_web.dart'),
    );
    expect(universe.exactClosureByExecutionTarget['app:web'], isEmpty);
  });

  test('rejects a Git index inventory captured from another project', () async {
    final first = Directory.systemTemp.createTempSync('root_index_first_');
    final second = Directory.systemTemp.createTempSync('root_index_second_');
    addTearDown(() {
      if (first.existsSync()) first.deleteSync(recursive: true);
      if (second.existsSync()) second.deleteSync(recursive: true);
    });
    await _copyFixture(Directory(fixture), first);
    await _copyFixture(Directory(fixture), second);
    await _runGit(first.path, ['init', '--quiet']);
    await _runGit(first.path, ['add', '--all']);
    await _runGit(second.path, ['init', '--quiet']);
    await _runGit(second.path, ['add', '--all']);
    final foreignInventory = await OracleGitIndexInventory.capture(first.path);

    expect(
      () => RootUniverseBuilder(
        manifest: _manifest(),
        projectRoot: second.path,
        packageRoot: second.path,
        gitIndexInventory: foreignInventory,
      ).build(),
      throwsArgumentError,
    );
  });

  test(
    'retains distinct public declarations with an ambiguous same-name export',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          publicEntrypoints: const ['lib/public_ambiguous.dart'],
        ),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      final retained =
          universe.retainedClosureByExecutionTarget['aux:external:public-api']!;
      expect(retained, contains('decl:lib/src/public_a.dart#samePublicName'));
      expect(retained, contains('decl:lib/src/public_b.dart#samePublicName'));
      expect(
        universe.exactClosureByExecutionTarget['aux:external:public-api'],
        isNot(contains('decl:lib/src/public_a.dart#samePublicName')),
      );
      expect(
        universe.uncertainties.join('\n'),
        contains('[public-namespace-ambiguous]'),
      );
    },
  );

  test(
    'applies repeated show and mixed hide combinators in source order',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          publicEntrypoints: const ['lib/public_combinators.dart'],
        ),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      final retained =
          universe.retainedClosureByExecutionTarget['aux:external:public-api']!;
      expect(retained, contains('decl:lib/src/reexport.dart#publicReexport'));
      expect(
        retained,
        isNot(contains('decl:lib/src/reexport.dart#hiddenReexport')),
      );
    },
  );

  test(
    'upgrades retained-first traversal when an exact path arrives',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(
          publicEntrypoints: const ['lib/public_strength.dart'],
        ),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      final exact =
          universe.exactClosureByExecutionTarget['aux:external:public-api']!;
      final retained =
          universe.retainedClosureByExecutionTarget['aux:external:public-api']!;

      expect(exact, contains('lib:lib/src/strength_shared.dart'));
      expect(retained, contains('lib:lib/src/strength_fallback.dart'));
      expect(retained, contains('lib:lib/src/strength_shared.dart'));
    },
  );

  test(
    'terminates exact public export cycles without losing members',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(publicEntrypoints: const ['lib/public_cycle.dart']),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      final exact =
          universe.exactClosureByExecutionTarget['aux:external:public-api']!;

      expect(
        exact,
        containsAll(<String>{
          'decl:lib/src/cycle_a.dart#cycleA',
          'decl:lib/src/cycle_b.dart#cycleB',
        }),
      );
    },
  );

  test(
    'collects multi-variable and extension-type external declarations',
    () async {
      final universe = await RootUniverseBuilder(
        manifest: _manifest(publicEntrypoints: const ['lib/public_kinds.dart']),
        projectRoot: fixture,
        packageRoot: fixture,
      ).build();
      expect(
        universe.exactClosureByExecutionTarget['aux:external:public-api'],
        containsAll(<String>{
          'decl:lib/public_kinds.dart#firstValue',
          'decl:lib/public_kinds.dart#secondValue',
          'decl:lib/public_kinds.dart#PublicExtensionType',
        }),
      );
    },
  );
}

Future<void> _copyFixture(Directory source, Directory destination) async {
  await destination.create(recursive: true);
  await for (final entity in source.list(followLinks: false)) {
    final targetPath = p.join(destination.path, p.basename(entity.path));
    switch (entity) {
      case File():
        await entity.copy(targetPath);
      case Directory():
        await _copyFixture(entity, Directory(targetPath));
      case Link():
        await Link(targetPath).create(await entity.target());
    }
  }
}

Future<String> _runGit(String workingDirectory, List<String> arguments) async {
  final result = await Process.run('git', [
    '-C',
    workingDirectory,
    ...arguments,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Git fixture command failed: ${result.stderr}');
  }
  return result.stdout as String;
}

AccuracyProjectManifest _manifest({
  int rootPolicyVersion = 2,
  List<OracleAuxiliaryExecutionTarget>? auxiliaryTargets,
  Map<String, String> dartDefines = const {'mode': 'web'},
  String entrypoint = 'lib/main_web.dart',
  List<String> publicEntrypoints = const ['lib/public.dart'],
}) => AccuracyProjectManifest(
  manifestSchemaVersion: 1,
  label: 'root-universe-fixture',
  projectRoot: '/external/fixture',
  projectGitSha: 'a' * 40,
  packageRoot: '/external/fixture',
  flutterVersion: '3.47.0',
  dartVersion: '3.13.0',
  toolSha: 'b' * 40,
  configSha256: 'c' * 64,
  packageConfigSha256: 'd' * 64,
  lockfileSha256: 'e' * 64,
  toolPackageConfigSha256: 'f' * 64,
  toolLockfileSha256: '0' * 64,
  originalManagedFingerprint: '1' * 64,
  worktreeManagedFingerprint: '2' * 64,
  rootPolicyVersion: rootPolicyVersion,
  candidateBoundaryPolicyVersion: 1,
  findingContractPolicyVersion: 1,
  manifestValidationMode: 'accepted',
  redactionRoots: ManifestRedactionRoots(
    roots: {'project': RedactionRoot('/external/fixture', const [])},
  ),
  expectedCoverage: ExpectedAnalysisCoverage(
    analysisMode: 'application',
    auxiliaryExecutionTargetIssuesPresent: true,
    auxiliaryExecutionTargetIssues: const [],
    targetMatrixStatus: 'declaredComplete',
    targetMatrixComplete: true,
    targetMatrixSource: 'fixture',
    targetMatrixIssues: const [],
    rootMode: 'applicationEntrypoints',
    rootCoverageComplete: true,
    internalBoundaryComplete: true,
    externalConsumersCovered: false,
    rootSource: 'fixture',
    publicEntrypoints: publicEntrypoints,
    rootIssues: const [],
  ),
  targets: [
    OracleTarget(
      name: 'app:web',
      platform: 'web',
      entrypoint: entrypoint,
      dartDefines: dartDefines,
    ),
  ],
  oracleAuxiliaryExecutionTargets:
      auxiliaryTargets ??
      [
        OracleAuxiliaryExecutionTarget(
          id: 'test:YS0tYg',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {
            'test.platform': 'vm',
            'dart.library.io': 'true',
            'dart.library.html': 'false',
          },
          environmentComplete: true,
          reason: 'fixture test platform vm',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'test:YS9i',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {
            'test.platform': 'vm',
            'dart.library.io': 'true',
            'dart.library.html': 'false',
          },
          environmentComplete: true,
          reason: 'fixture test platform vm',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'test:YS9zYW1l',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {
            'test.platform': 'vm',
            'dart.library.io': 'true',
            'dart.library.html': 'false',
          },
          environmentComplete: true,
          reason: 'fixture test platform vm',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'test:Yi9zYW1l',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {
            'test.platform': 'vm',
            'dart.library.io': 'true',
            'dart.library.html': 'false',
          },
          environmentComplete: true,
          reason: 'fixture test platform vm',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'test:c3VwcG9ydA',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {'test.platform': 'unknown'},
          environmentComplete: false,
          reason: 'unannotated test platform',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'test:dm1fdGVzdA',
          domain: OracleAuxiliaryDomain.test,
          environmentValues: const {
            'test.platform': 'vm',
            'dart.library.io': 'true',
            'dart.library.html': 'false',
          },
          environmentComplete: true,
          reason: 'fixture test platform vm',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.Y29uc3RhbnRWbUVudHJ5',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.QS5ydW4',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.Qi5ydW4',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.Q29uc3RydWN0ZWQubmFtZWQ',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.Q2FsbGJhY2tFbnVtLnJ1bg',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.Q2FsbGJhY2tFeHRlbnNpb25UeXBlLnJ1bg',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dW5uYW1lZC1leHRlbnNpb246NTYzNzJhYTk4ODUwMTI5ZGVjMDdmNDhiYTI5Nzc5MmVkNDMyMTQzMDVkMDYzZjMxZmYzMDNjNWQzZTI4MDQxNn4xLnVubmFtZWRDYWxsYmFjaw',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dW5uYW1lZC1leHRlbnNpb246NTYzNzJhYTk4ODUwMTI5ZGVjMDdmNDhiYTI5Nzc5MmVkNDMyMTQzMDVkMDYzZjMxZmYzMDNjNWQzZTI4MDQxNn4yLnVubmFtZWRDYWxsYmFjaw',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dW5uYW1lZC1leHRlbnNpb246Yjk0N2NhOGRmNDMzM2MyYjM0NDE4Mjg1ZmIzMzY4NzFkMTFiMTJhM2QzZGQzMmZjMzMxOWFiNTgxZGU0M2Y3Ny51bm5hbWVkQ2FsbGJhY2s',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dm1FbnRyeQ',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:isolateSpawn.bGliL2NhbGxiYWNrcy5kYXJ0.aXNvbGF0ZVdvcmtlcg',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'isolateSpawn'},
          environmentComplete: false,
          reason: 'no unique compatible isolateSpawn target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:isolateSpawn.ZGVwZW5kZW5jaWVzL3NpYmxpbmcvbGliL3NpYmxpbmcuZGFydA.c2libGluZ0VudHJ5',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'isolateSpawn'},
          environmentComplete: false,
          reason: 'no unique compatible isolateSpawn target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:vmPragma.ZGVwZW5kZW5jaWVzL3NpYmxpbmcvbGliL3NpYmxpbmcuZGFydA.c2libGluZ0VudHJ5',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'vmPragma'},
          environmentComplete: false,
          reason: 'no unique compatible vmPragma target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:workmanagerInitialize.bGliL2NhbGxiYWNrcy5kYXJ0.d29ya21hbmFnZXJDYWxsYmFjaw',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'workmanagerInitialize'},
          environmentComplete: false,
          reason: 'no unique compatible workmanagerInitialize target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:unknown_bGliL2NhbGxiYWNrcy5kYXJ0',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'unknown'},
          environmentComplete: false,
          reason: 'unresolved or same-named callback capability',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'runtime:ffiNativeCallback.bGliL2NhbGxiYWNrcy5kYXJ0.ZmZpTmF0aXZlQ2FsbGJhY2s',
          domain: OracleAuxiliaryDomain.runtime,
          environmentValues: const {'callback.kind': 'ffiNativeCallback'},
          environmentComplete: false,
          reason: 'no unique compatible ffiNativeCallback target',
        ),
        OracleAuxiliaryExecutionTarget(
          id: 'external:public-api',
          domain: OracleAuxiliaryDomain.external,
          environmentValues: const {'consumer': 'unknown'},
          environmentComplete: false,
          reason: 'open external consumer surface',
        ),
      ],
  scans: const {},
);
