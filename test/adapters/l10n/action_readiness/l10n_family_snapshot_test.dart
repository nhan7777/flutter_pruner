import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

void main() {
  group('L10nFamilySnapshot', () {
    test('deep-freezes every caller-owned collection and project semantic', () {
      final sourceBytes = <int>[...'{"dead":"Dead"}'.codeUnits];
      final stageBytes = <int>[...'{"dead":"Dead"}'.codeUnits];
      final entry = L10nSnapshotEntry(
        relativePosixPath: 'lib/l10n/app_en.arb',
        role: L10nSnapshotRole.arbTemplate,
        state: L10nSnapshotPresent(
          sourceBytes: ImmutableBytes.copyOf(sourceBytes),
          stageBytes: ImmutableBytes.copyOf(stageBytes),
          sourceSha256:
              'dce35ba2ee8148c977bbb42d8ced3e23b1b8c26b4fe1d4a18bc88145aaec0261',
          posixMode: 0x1a4,
        ),
      );
      final entries = <String, L10nSnapshotEntry>{
        ..._fixedAuthorityEntries(),
        entry.relativePosixPath: entry,
        'lib/main.dart': L10nSnapshotEntry(
          relativePosixPath: 'lib/main.dart',
          role: L10nSnapshotRole.analyzerSource,
          state: L10nSnapshotPresent(
            sourceBytes: ImmutableBytes.copyOf([10]),
            stageBytes: ImmutableBytes.copyOf([10]),
            sourceSha256:
                '01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b',
            posixMode: 0x1a4,
          ),
        ),
        'lib/l10n/app.dart': L10nSnapshotEntry(
          relativePosixPath: 'lib/l10n/app.dart',
          role: L10nSnapshotRole.generatedBase,
          state: const L10nSnapshotAbsent(),
        ),
        'lib/l10n/helper.dart': L10nSnapshotEntry(
          relativePosixPath: 'lib/l10n/helper.dart',
          role: L10nSnapshotRole.verificationInput,
          state: L10nSnapshotPresent(
            sourceBytes: ImmutableBytes.copyOf([7]),
            stageBytes: ImmutableBytes.copyOf([7]),
            sourceSha256:
                'ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879',
            posixMode: 0x1a4,
          ),
        ),
      };
      final selectedNodeIds = <String>{'l10n:fixture:dead'};
      final selectedKeys = <String>{'dead'};
      final memberKinds = <String, ArbGeneratedMemberKind>{
        'dead': ArbGeneratedMemberKind.getter,
      };
      final generatedPaths = <String>{'lib/l10n/app.dart'};
      final closurePaths = <String>{'lib/main.dart'};
      final siblings = <String>{'lib/l10n/helper.dart'};
      final pubspec = <dynamic, dynamic>{
        'name': 'fixture',
        'nested': <dynamic, dynamic>{
          'values': <Object?>['one'],
        },
      };
      final snapshot = L10nFamilySnapshot(
        entries: entries,
        mutationPlan: _mutationPlan(),
        selectedNodeIds: selectedNodeIds,
        selectedKeys: selectedKeys,
        expectedGeneratedMemberKindsByKey: memberKinds,
        expectedGeneratedPaths: generatedPaths,
        optionalUntranslatedPath: null,
        verificationClosure: L10nVerificationClosure(
          projectOwnedDartPaths: closurePaths,
          analyzerRootIdentity: _testIdentity,
        ),
        analysisOptionsProjection: L10nAnalysisOptionsProjection(
          projectOwnedPaths: const {},
          externalAuthorities: const [],
          contextAuthorityIdentity: _testIdentity,
        ),
        provenUnrelatedOutputSiblings: siblings,
        familyFingerprint: _testIdentity,
        selectionFingerprint: _testIdentity,
        l10nAnalysisFingerprint: _testIdentity,
        configurationIdentity: _testIdentity,
        packageConfigProjectionIdentity: _testIdentity,
        packageResolutionIdentity: _testIdentity,
        toolchainIdentity: _testIdentity,
        projectSemantics: L10nProjectSemantics(
          pubspec: pubspec,
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

      sourceBytes[0] = 99;
      stageBytes[0] = 99;
      entries.clear();
      selectedNodeIds.clear();
      selectedKeys.clear();
      memberKinds.clear();
      generatedPaths.clear();
      closurePaths.clear();
      siblings.clear();
      (pubspec['nested'] as Map<dynamic, dynamic>)['later'] = true;

      final captured = snapshot.entries['lib/l10n/app_en.arb']!.state;
      expect(captured, isA<L10nSnapshotPresent>());
      expect(
        (captured as L10nSnapshotPresent).sourceBytes.copy(),
        '{"dead":"Dead"}'.codeUnits,
      );
      expect(captured.stageBytes.copy(), '{"dead":"Dead"}'.codeUnits);
      expect(captured.sourceSha256, captured.sourceBytes.sha256Hex);
      expect(captured.posixMode, 0x1a4);
      expect(snapshot.selectedNodeIds, {'l10n:fixture:dead'});
      expect(snapshot.selectedKeys, {'dead'});
      expect(snapshot.expectedGeneratedPaths, {'lib/l10n/app.dart'});
      expect(snapshot.analyzerClosurePaths, {'lib/main.dart'});
      expect(
        snapshot.verificationClosure.projectOwnedDartPaths,
        snapshot.analyzerClosurePaths,
      );
      expect(snapshot.provenUnrelatedOutputSiblings, {'lib/l10n/helper.dart'});
      expect((snapshot.projectSemantics.pubspec['nested'] as Map)['values'], [
        'one',
      ]);
      expect(() => snapshot.entries.clear(), throwsA(isA<UnsupportedError>()));
      expect(
        () => snapshot.selectedKeys.add('later'),
        throwsA(isA<UnsupportedError>()),
      );
      expect(
        () => (snapshot.projectSemantics.pubspec['nested'] as Map)['later'] =
            true,
        throwsA(isA<UnsupportedError>()),
      );
    });

    test('sorts path and identity maps and retains explicit absence', () {
      final absent = L10nSnapshotEntry(
        relativePosixPath: 'build/untranslated.json',
        role: L10nSnapshotRole.untranslatedSidecar,
        state: const L10nSnapshotAbsent(),
      );
      final present = L10nSnapshotEntry(
        relativePosixPath: 'lib/main.dart',
        role: L10nSnapshotRole.analyzerSource,
        state: L10nSnapshotPresent(
          sourceBytes: ImmutableBytes.copyOf([7]),
          stageBytes: ImmutableBytes.copyOf([7]),
          sourceSha256:
              'ca358758f6d27e6cf45272937977a748fd88391db679ceda7dc7bf1f005ee879',
          posixMode: null,
        ),
      );
      final snapshot = L10nFamilySnapshot(
        entries: {
          ..._fixedAuthorityEntries(),
          present.relativePosixPath: present,
          absent.relativePosixPath: absent,
          'lib/generated/app.dart': L10nSnapshotEntry(
            relativePosixPath: 'lib/generated/app.dart',
            role: L10nSnapshotRole.generatedBase,
            state: const L10nSnapshotAbsent(),
          ),
          'lib/generated/app_vi.dart': L10nSnapshotEntry(
            relativePosixPath: 'lib/generated/app_vi.dart',
            role: L10nSnapshotRole.generatedLanguage,
            state: const L10nSnapshotAbsent(),
          ),
          'lib/l10n/app_en.arb': L10nSnapshotEntry(
            relativePosixPath: 'lib/l10n/app_en.arb',
            role: L10nSnapshotRole.arbTemplate,
            state: L10nSnapshotPresent(
              sourceBytes: ImmutableBytes.copyOf(
                '{"welcome":"Welcome","dead":"Dead"}'.codeUnits,
              ),
              stageBytes: ImmutableBytes.copyOf(
                '{"welcome":"Welcome","dead":"Dead"}'.codeUnits,
              ),
              sourceSha256:
                  '0d19317b3b3531a8ac188162bbd4024ff87036ebdc65d336e5f1fd6ade83b801',
              posixMode: null,
            ),
          ),
        },
        mutationPlan: _mutationPlan(
          source: '{"welcome":"Welcome","dead":"Dead"}',
        ),
        selectedNodeIds: const {'l10n:fixture:dead'},
        selectedKeys: const {'dead'},
        expectedGeneratedMemberKindsByKey: const {
          'welcome': ArbGeneratedMemberKind.getter,
          'dead': ArbGeneratedMemberKind.getter,
        },
        expectedGeneratedPaths: const {
          'lib/generated/app_vi.dart',
          'lib/generated/app.dart',
        },
        optionalUntranslatedPath: absent.relativePosixPath,
        verificationClosure: L10nVerificationClosure(
          projectOwnedDartPaths: const {'lib/main.dart'},
          analyzerRootIdentity: _testIdentity,
        ),
        analysisOptionsProjection: L10nAnalysisOptionsProjection(
          projectOwnedPaths: const {},
          externalAuthorities: const [],
          contextAuthorityIdentity: _testIdentity,
        ),
        provenUnrelatedOutputSiblings: const {},
        familyFingerprint: _testIdentity,
        selectionFingerprint: _testIdentity,
        l10nAnalysisFingerprint: _testIdentity,
        configurationIdentity: _testIdentity,
        packageConfigProjectionIdentity: _testIdentity,
        packageResolutionIdentity: _testIdentity,
        toolchainIdentity: _testIdentity,
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

      expect(snapshot.entries.keys, [
        '.dart_tool/package_config.json',
        '.dart_tool/package_graph.json',
        'analysis_options.yaml',
        'build/untranslated.json',
        'dart_test.yaml',
        'l10n.yaml',
        'lib/generated/app.dart',
        'lib/generated/app_vi.dart',
        'lib/l10n/app_en.arb',
        'lib/main.dart',
        'pubspec.lock',
        'pubspec.yaml',
      ]);
      expect(
        snapshot.entries[absent.relativePosixPath]!.state,
        isA<L10nSnapshotAbsent>(),
      );
      expect(snapshot.expectedGeneratedMemberKindsByKey.keys, [
        'dead',
        'welcome',
      ]);
      expect(snapshot.expectedGeneratedPaths, {
        'lib/generated/app.dart',
        'lib/generated/app_vi.dart',
      });
    });

    test('rejects a forged source digest and an incomplete closure entry', () {
      expect(
        () => L10nSnapshotPresent(
          sourceBytes: ImmutableBytes.copyOf([1]),
          stageBytes: ImmutableBytes.copyOf([1]),
          sourceSha256: 'forged',
          posixMode: null,
        ),
        throwsArgumentError,
      );

      expect(
        () => L10nFamilySnapshot(
          entries: {
            'lib/generated/app.dart': L10nSnapshotEntry(
              relativePosixPath: 'lib/generated/app.dart',
              role: L10nSnapshotRole.generatedBase,
              state: const L10nSnapshotAbsent(),
            ),
          },
          mutationPlan: _mutationPlan(),
          selectedNodeIds: const {'node'},
          selectedKeys: const {'dead'},
          expectedGeneratedMemberKindsByKey: const {
            'dead': ArbGeneratedMemberKind.getter,
          },
          expectedGeneratedPaths: const {},
          optionalUntranslatedPath: null,
          verificationClosure: L10nVerificationClosure(
            projectOwnedDartPaths: const {'lib/main.dart'},
            analyzerRootIdentity: _testIdentity,
          ),
          analysisOptionsProjection: L10nAnalysisOptionsProjection(
            projectOwnedPaths: const {},
            externalAuthorities: const [],
            contextAuthorityIdentity: _testIdentity,
          ),
          provenUnrelatedOutputSiblings: const {},
          familyFingerprint: _testIdentity,
          selectionFingerprint: _testIdentity,
          l10nAnalysisFingerprint: _testIdentity,
          configurationIdentity: _testIdentity,
          packageConfigProjectionIdentity: _testIdentity,
          packageResolutionIdentity: _testIdentity,
          toolchainIdentity: _testIdentity,
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
        ),
        throwsStateError,
      );
    });

    test('rejects unsafe portable paths', () {
      for (final path in const [
        'C:/escape.dart',
        'https://example.test/input.dart',
        'lib/café.dart',
        'lib/a%20.dart',
        'lib/a?.dart',
        'lib/a#b.dart',
      ]) {
        expect(
          () => L10nSnapshotEntry(
            relativePosixPath: path,
            role: L10nSnapshotRole.analyzerSource,
            state: const L10nSnapshotAbsent(),
          ),
          throwsArgumentError,
          reason: path,
        );
      }
    });

    test('rejects a mutation plan forged from different ARB bytes and keys', () {
      const arbPath = 'lib/l10n/app_en.arb';
      expect(
        () => L10nFamilySnapshot(
          entries: {
            ..._fixedAuthorityEntries(),
            arbPath: L10nSnapshotEntry(
              relativePosixPath: arbPath,
              role: L10nSnapshotRole.arbTemplate,
              state: L10nSnapshotPresent(
                sourceBytes: ImmutableBytes.copyOf('{"live":"Live"}'.codeUnits),
                stageBytes: ImmutableBytes.copyOf('{"live":"Live"}'.codeUnits),
                sourceSha256:
                    '52d1b16e9490b80a8a5039c74a25f6c52863c811b09ff6b3401bda89f8ddc8e5',
                posixMode: null,
              ),
            ),
            'lib/main.dart': L10nSnapshotEntry(
              relativePosixPath: 'lib/main.dart',
              role: L10nSnapshotRole.analyzerSource,
              state: L10nSnapshotPresent(
                sourceBytes: ImmutableBytes.copyOf([10]),
                stageBytes: ImmutableBytes.copyOf([10]),
                sourceSha256:
                    '01ba4719c80b6fe911b091a7c05124b64eeece964e09c058ef8f9805daca546b',
                posixMode: null,
              ),
            ),
            'lib/generated/app.dart': L10nSnapshotEntry(
              relativePosixPath: 'lib/generated/app.dart',
              role: L10nSnapshotRole.generatedBase,
              state: const L10nSnapshotAbsent(),
            ),
          },
          mutationPlan: _mutationPlan(),
          selectedNodeIds: const {'l10n:fixture:live'},
          selectedKeys: const {'live'},
          expectedGeneratedMemberKindsByKey: const {
            'live': ArbGeneratedMemberKind.getter,
          },
          expectedGeneratedPaths: const {'lib/generated/app.dart'},
          optionalUntranslatedPath: null,
          verificationClosure: L10nVerificationClosure(
            projectOwnedDartPaths: const {'lib/main.dart'},
            analyzerRootIdentity: _testIdentity,
          ),
          analysisOptionsProjection: L10nAnalysisOptionsProjection(
            projectOwnedPaths: const {},
            externalAuthorities: const [],
            contextAuthorityIdentity: _testIdentity,
          ),
          provenUnrelatedOutputSiblings: const {},
          familyFingerprint: _testIdentity,
          selectionFingerprint: _testIdentity,
          l10nAnalysisFingerprint: _testIdentity,
          configurationIdentity: _testIdentity,
          packageConfigProjectionIdentity: _testIdentity,
          packageResolutionIdentity: _testIdentity,
          toolchainIdentity: _testIdentity,
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
        ),
        throwsStateError,
      );
    });
  });
}

const _testIdentity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

L10nArbMutationPlan _mutationPlan({String source = '{"dead":"Dead"}'}) {
  final parsed = ArbDocument.parse(source.codeUnits);
  final result = L10nArbMutationPlanner.plan(
    templatePath: 'lib/l10n/app_en.arb',
    documentsByPath: {
      'lib/l10n/app_en.arb': (parsed as ArbParseSuccess).document,
    },
    selectedKeys: const ['dead'],
  );
  return (result as L10nArbMutationPlanReady).plan;
}

Map<String, L10nSnapshotEntry> _fixedAuthorityEntries() => {
  'pubspec.yaml': L10nSnapshotEntry(
    relativePosixPath: 'pubspec.yaml',
    role: L10nSnapshotRole.pubspec,
    state: _presentBytes([1]),
  ),
  'pubspec.lock': L10nSnapshotEntry(
    relativePosixPath: 'pubspec.lock',
    role: L10nSnapshotRole.lockfile,
    state: _presentBytes([2]),
  ),
  'l10n.yaml': L10nSnapshotEntry(
    relativePosixPath: 'l10n.yaml',
    role: L10nSnapshotRole.l10nConfig,
    state: const L10nSnapshotAbsent(),
  ),
  '.dart_tool/package_config.json': L10nSnapshotEntry(
    relativePosixPath: '.dart_tool/package_config.json',
    role: L10nSnapshotRole.packageConfig,
    state: _presentBytes([3]),
  ),
  '.dart_tool/package_graph.json': L10nSnapshotEntry(
    relativePosixPath: '.dart_tool/package_graph.json',
    role: L10nSnapshotRole.packageGraph,
    state: const L10nSnapshotAbsent(),
  ),
  'analysis_options.yaml': L10nSnapshotEntry(
    relativePosixPath: 'analysis_options.yaml',
    role: L10nSnapshotRole.verificationInput,
    state: const L10nSnapshotAbsent(),
  ),
  'dart_test.yaml': L10nSnapshotEntry(
    relativePosixPath: 'dart_test.yaml',
    role: L10nSnapshotRole.verificationInput,
    state: const L10nSnapshotAbsent(),
  ),
};

L10nSnapshotPresent _presentBytes(List<int> bytes) {
  final frozen = ImmutableBytes.copyOf(bytes);
  return L10nSnapshotPresent(
    sourceBytes: frozen,
    stageBytes: frozen,
    sourceSha256: frozen.sha256Hex,
    posixMode: null,
  );
}
