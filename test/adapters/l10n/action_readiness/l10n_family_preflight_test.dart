import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_preflight.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  group('L10nFamilyPreflight.capture', () {
    test(
      'keeps captured ARBs out of shared output-directory siblings',
      () async {
        final fixture = await _Fixture.create(
          sharedArbAndOutputDirectory: true,
        );
        addTearDown(fixture.dispose);

        final result = await fixture.capture();

        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
        final snapshot = (result as L10nFamilySnapshotReady).snapshot;
        expect(snapshot.provenUnrelatedOutputSiblings, {
          'lib/l10n/header.txt',
          'lib/l10n/helper.dart',
        });
        expect(
          snapshot.entries['lib/l10n/app_en.arb']!.role,
          L10nSnapshotRole.arbTemplate,
        );
        expect(
          snapshot.entries['lib/l10n/app_vi.arb']!.role,
          L10nSnapshotRole.arbLocale,
        );
      },
    );

    test(
      'captures exact immutable family with projected packages and base languages',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);

        final first = await fixture.capture();
        final second = await fixture.capture();

        expect(
          first,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(first),
        );
        expect(
          second,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(second),
        );
        final snapshot = (first as L10nFamilySnapshotReady).snapshot;
        final repeated = (second as L10nFamilySnapshotReady).snapshot;
        expect(snapshot.familyFingerprint, repeated.familyFingerprint);
        expect(snapshot.selectionFingerprint, repeated.selectionFingerprint);
        expect(
          snapshot.l10nAnalysisFingerprint,
          repeated.l10nAnalysisFingerprint,
        );
        expect(snapshot.l10nAnalysisFingerprint, hasLength(64));
        expect(
          snapshot.packageResolutionIdentity,
          repeated.packageResolutionIdentity,
        );
        expect(
          snapshot.verificationClosure.analyzerRootIdentity,
          repeated.verificationClosure.analyzerRootIdentity,
        );
        expect(
          snapshot.entries.keys.toList(),
          orderedEquals([...snapshot.entries.keys.toList()..sort()]),
        );
        expect(snapshot.selectedNodeIds, {fixture.selectedNodeId});
        expect(snapshot.selectedKeys, {'dead'});
        expect(snapshot.expectedGeneratedPaths, {
          'lib/generated/l10n/app.bundle.dart',
          'lib/generated/l10n/app_en.bundle.dart',
          'lib/generated/l10n/app_vi.bundle.dart',
        });
        expect(
          snapshot.expectedGeneratedPaths.where(
            (path) => path.contains('_en.'),
          ),
          hasLength(1),
          reason: 'en, en_US, and en_GB share one base-language output',
        );
        expect(snapshot.optionalUntranslatedPath, 'build/untranslated.json');
        expect(
          snapshot.entries['build/untranslated.json']!.state,
          isA<L10nSnapshotAbsent>(),
        );
        expect(
          snapshot.entries['dart_test.yaml']!.state,
          isA<L10nSnapshotAbsent>(),
        );
        expect(
          snapshot.entries['.dart_tool/package_graph.json']!.state,
          isA<L10nSnapshotAbsent>(),
        );
        expect(
          snapshot.entries['lib/l10n/header.txt']!.role,
          L10nSnapshotRole.header,
        );
        expect(
          snapshot.entries['config/base.yaml']!.role,
          L10nSnapshotRole.verificationInput,
        );
        expect(snapshot.provenUnrelatedOutputSiblings, {
          'lib/generated/l10n/helper.dart',
        });

        final pubspecState =
            snapshot.entries['pubspec.yaml']!.state as L10nSnapshotPresent;
        final livePubspec = File(
          p.join(fixture.projectRoot.path, 'pubspec.yaml'),
        ).readAsBytesSync();
        expect(pubspecState.sourceBytes.copy(), livePubspec);
        expect(pubspecState.stageBytes.copy(), livePubspec);
        expect(pubspecState.sourceSha256, pubspecState.sourceBytes.sha256Hex);
        if (Platform.isWindows) {
          expect(pubspecState.posixMode, isNull);
        } else {
          expect(
            pubspecState.posixMode,
            FileStat.statSync(
                  p.join(fixture.projectRoot.path, 'pubspec.yaml'),
                ).mode &
                0xfff,
          );
        }

        final packageState =
            snapshot.entries['.dart_tool/package_config.json']!.state
                as L10nSnapshotPresent;
        final sourcePackageText = utf8.decode(packageState.sourceBytes.copy());
        final stagePackageText = utf8.decode(packageState.stageBytes.copy());
        final canonicalExternalUri = Directory(
          fixture.externalRoot.resolveSymbolicLinksSync(),
        ).uri.toString();
        final canonicalFlutterUri = Directory(
          p.join(fixture.toolchain.canonicalSdkRoot, 'packages/flutter'),
        ).uri.toString();
        final canonicalAnalyzerSharedUri = Directory(
          Directory(
            p.join(fixture.container.path, '_fe_analyzer_shared'),
          ).resolveSymbolicLinksSync(),
        ).uri.toString();
        expect(sourcePackageText, contains('"rootUri":"../../external_dep/"'));
        expect(stagePackageText, contains(jsonEncode(canonicalExternalUri)));
        expect(stagePackageText, contains(jsonEncode(canonicalFlutterUri)));
        expect(
          stagePackageText,
          contains(jsonEncode(canonicalAnalyzerSharedUri)),
        );
        expect(
          stagePackageText
              .replaceFirst(
                jsonEncode(canonicalExternalUri),
                jsonEncode('../../external_dep/'),
              )
              .replaceFirst(
                jsonEncode(canonicalFlutterUri),
                jsonEncode('../../sdk/packages/flutter/'),
              )
              .replaceFirst(
                jsonEncode(canonicalAnalyzerSharedUri),
                jsonEncode('../../_fe_analyzer_shared/'),
              ),
          sourcePackageText,
          reason: 'projection may replace only rootUri token bytes',
        );
        final stageConfig =
            jsonDecode(stagePackageText) as Map<String, Object?>;
        final stagePackages = stageConfig['packages']! as List<Object?>;
        expect((stagePackages.first as Map<String, Object?>)['rootUri'], '../');
        final externalRecord = stagePackages
            .cast<Map<String, Object?>>()
            .singleWhere((record) => record['name'] == 'external_dep');
        expect(externalRecord['rootUri'], canonicalExternalUri);
        final flutterRecord = stagePackages
            .cast<Map<String, Object?>>()
            .singleWhere((record) => record['name'] == 'flutter');
        expect(flutterRecord['rootUri'], canonicalFlutterUri);
        final analyzerSharedRecord = stagePackages
            .cast<Map<String, Object?>>()
            .singleWhere((record) => record['name'] == '_fe_analyzer_shared');
        expect(analyzerSharedRecord['rootUri'], canonicalAnalyzerSharedUri);
        expect(
          snapshot.projectSemantics.pubspec['name'],
          'l10n_snapshot_fixture',
        );
        expect(snapshot.projectSemantics.targetMatrix.isComplete, isTrue);
        expect(snapshot.projectSemantics.rootCoverage.complete, isTrue);
        expect(
          snapshot.analyzerClosurePaths,
          snapshot.verificationClosure.projectOwnedDartPaths,
        );
        expect(
          snapshot.analyzerClosurePaths,
          containsAll([
            'lib/main.dart',
            'lib/generated/l10n/app.bundle.dart',
            'lib/generated/l10n/app_en.bundle.dart',
            'lib/generated/l10n/app_vi.bundle.dart',
          ]),
        );

        final externalPubspec = File(
          p.join(fixture.externalRoot.path, 'pubspec.yaml'),
        );
        externalPubspec.writeAsStringSync(
          '${externalPubspec.readAsStringSync()}# post-capture drift\n',
        );
        final reprojected = const L10nPackageConfigProjector().project(
          sourceBytes: fixture.packageConfig.readAsBytesSync(),
          canonicalProjectRoot: fixture.projectRoot.resolveSymbolicLinksSync(),
          selectedPackageName: fixture.project.packageName,
          toolchain: fixture.toolchain,
        );
        expect(reprojected, isA<L10nPackageConfigProjectionReady>());
        expect(
          (reprojected as L10nPackageConfigProjectionReady)
              .projection
              .authorityIdentity,
          isNot(snapshot.packageConfigProjectionIdentity),
        );
      },
    );

    test(
      'captures mixed local and package analysis-options includes and revalidates drift',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final externalOptions = File(
          p.join(
            fixture.container.path,
            '_fe_analyzer_shared/lib/options.yaml',
          ),
        );
        final externalNested = File(
          p.join(fixture.container.path, '_fe_analyzer_shared/lib/nested.yaml'),
        );
        externalOptions.writeAsStringSync('include: nested.yaml\n');
        const nestedBytes =
            'linter:\n  rules:\n    prefer_final_locals: true\n';
        externalNested.writeAsStringSync(nestedBytes);
        File(
          p.join(fixture.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
include:
  - package:_fe_analyzer_shared/options.yaml
  - config/base.yaml
''');

        final result = await fixture.capture();

        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
        final projection = (result as L10nFamilySnapshotReady)
            .snapshot
            .analysisOptionsProjection;
        expect(projection.projectOwnedPaths, {
          'analysis_options.yaml',
          'config/base.yaml',
        });
        expect(projection.externalAuthorities, hasLength(2));
        expect(
          projection.revalidate(),
          isA<L10nAnalysisOptionsRevalidationReady>(),
        );
        final contextProjection = const L10nAnalyzerContextAuthorityProjector()
            .project(fixture.project);
        expect(
          contextProjection,
          isA<L10nAnalyzerContextAuthorityProjectionReady>(),
        );
        expect(
          (contextProjection as L10nAnalyzerContextAuthorityProjectionReady)
              .projection
              .identity,
          projection.contextAuthorityIdentity,
        );

        externalNested.writeAsStringSync('$nestedBytes# drift\n');
        final directDrift = projection.revalidate();
        expect(directDrift, isA<L10nAnalysisOptionsRevalidationRejected>());
        expect(
          (directDrift as L10nAnalysisOptionsRevalidationRejected).failure.code,
          L10nEvidenceRejectionCode.sourceDrift,
        );
        externalNested.writeAsStringSync(nestedBytes);

        final preflight = L10nFamilyPreflight.testing(
          beforeSecondRead: () async {
            externalNested.writeAsStringSync('$nestedBytes# second drift\n');
          },
        );
        final drift = await fixture.capture(preflight: preflight);
        _expectFailure(
          drift,
          L10nEvidenceRejectionCode.sourceDrift,
          'analysis-options-external-drift',
        );
      },
    );

    test(
      'normalizes external analysis-options authority transitions at the barrier',
      () async {
        final transitions = <String>[
          'delete',
          'directory',
          if (!Platform.isWindows) 'symlink',
          if (!Platform.isWindows) 'mode',
        ];
        for (final transition in transitions) {
          final fixture = await _Fixture.create();
          addTearDown(fixture.dispose);
          final externalOptions = File(
            p.join(
              fixture.container.path,
              '_fe_analyzer_shared/lib/options.yaml',
            ),
          )..writeAsStringSync('linter:\n  rules:\n    avoid_print: true\n');
          File(
            p.join(fixture.projectRoot.path, 'analysis_options.yaml'),
          ).writeAsStringSync(
            'include: package:_fe_analyzer_shared/options.yaml\n',
          );

          final result = await fixture.capture(
            preflight: L10nFamilyPreflight.testing(
              beforeSecondRead: () async {
                switch (transition) {
                  case 'delete':
                    externalOptions.deleteSync();
                  case 'directory':
                    externalOptions.deleteSync();
                    Directory(externalOptions.path).createSync();
                  case 'symlink':
                    final replacement = File(
                      p.join(externalOptions.parent.path, 'replacement.yaml'),
                    )..writeAsBytesSync(externalOptions.readAsBytesSync());
                    externalOptions.deleteSync();
                    Link(externalOptions.path).createSync(replacement.path);
                  case 'mode':
                    _chmod(externalOptions, 0x180);
                }
              },
            ),
          );

          _expectFailure(
            result,
            L10nEvidenceRejectionCode.sourceDrift,
            'analysis-options-external-drift',
            reason: transition,
          );
        }
      },
    );

    test(
      'rejects unsafe, cyclic, and plugin analysis-options authorities',
      () async {
        final cases = <String, void Function(_Fixture)>{
          'cycle': (fixture) {
            File(
              p.join(fixture.projectRoot.path, 'config/base.yaml'),
            ).writeAsStringSync('include: ../analysis_options.yaml\n');
          },
          'escape': (fixture) {
            File(
              p.join(fixture.projectRoot.path, 'analysis_options.yaml'),
            ).writeAsStringSync('include: ../outside.yaml\n');
            File(
              p.join(fixture.container.path, 'outside.yaml'),
            ).writeAsStringSync('linter: {}\n');
          },
          'plugin': (fixture) {
            File(
              p.join(fixture.projectRoot.path, 'analysis_options.yaml'),
            ).writeAsStringSync('''
plugins:
  unsafe_plugin:
    path: ../plugin
''');
          },
        };
        for (final entry in cases.entries) {
          final fixture = await _Fixture.create();
          addTearDown(fixture.dispose);
          entry.value(fixture);

          final result = await fixture.capture();

          _expectFailure(
            result,
            L10nEvidenceRejectionCode.invalidInputPath,
            null,
            reason: entry.key,
          );
        }
      },
    );

    test(
      'accepts only unresolved inert legacy analyzer plugin identifiers',
      () async {
        final unresolved = await _Fixture.create();
        addTearDown(unresolved.dispose);
        File(
          p.join(unresolved.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
analyzer:
  plugins:
    - custom_lint
''');
        final unresolvedResult = await unresolved.capture();
        expect(
          unresolvedResult,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(unresolvedResult),
        );

        final resolved = await _Fixture.create();
        addTearDown(resolved.dispose);
        File(
          p.join(resolved.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
analyzer:
  plugins:
    - external_dep
''');
        _expectFailure(
          await resolved.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-plugins-unsupported',
        );

        final locked = await _Fixture.create();
        addTearDown(locked.dispose);
        File(
          p.join(locked.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
analyzer:
  plugins:
    - custom_lint
''');
        File(p.join(locked.projectRoot.path, 'pubspec.lock')).writeAsStringSync(
          '''
packages:
  custom_lint:
    dependency: transitive
    description:
      name: custom_lint
      sha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
      url: https://pub.dev
    source: hosted
    version: 0.7.0
sdks:
  dart: ">=3.9.0 <4.0.0"
''',
        );
        _expectFailure(
          await locked.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-plugins-unsupported',
        );

        final declared = await _Fixture.create(
          unresolvedDevDependency: 'custom_lint',
        );
        addTearDown(declared.dispose);
        File(
          p.join(declared.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
analyzer:
  plugins:
    - custom_lint
''');
        _expectFailure(
          await declared.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-plugins-unsupported',
        );

        final malformed = await _Fixture.create();
        addTearDown(malformed.dispose);
        File(
          p.join(malformed.projectRoot.path, 'analysis_options.yaml'),
        ).writeAsStringSync('''
analyzer:
  plugins:
    - ../plugin
''');
        _expectFailure(
          await malformed.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-plugins-unsupported',
        );
      },
    );

    test(
      'rejects nested and inherited analyzer authorities before workspace use',
      () async {
        final nested = await _Fixture.create();
        addTearDown(nested.dispose);
        final nestedOptions = File(
          p.join(nested.projectRoot.path, 'lib/nested/analysis_options.yaml'),
        );
        nestedOptions.parent.createSync(recursive: true);
        nestedOptions.writeAsStringSync('plugins: {}\n');
        _expectFailure(
          await nested.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-nested-unsupported',
        );

        final inherited = await _Fixture.create();
        addTearDown(inherited.dispose);
        File(
          p.join(inherited.projectRoot.path, 'analysis_options.yaml'),
        ).deleteSync();
        File(
          p.join(inherited.container.path, 'analysis_options.yaml'),
        ).writeAsStringSync('plugins: {}\n');
        _expectFailure(
          await inherited.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analysis-options-inherited-unsupported',
        );

        final gn = await _Fixture.create();
        addTearDown(gn.dispose);
        Directory(p.join(gn.projectRoot.path, '.jiri_root')).createSync();
        File(
          p.join(gn.projectRoot.path, '.fx-build-dir'),
        ).writeAsStringSync('out/debug\n');
        final gnSource = File(
          p.join(gn.projectRoot.path, 'gn/lib/source.dart'),
        );
        gnSource.parent.createSync(recursive: true);
        gnSource.writeAsStringSync('const gnSource = true;\n');
        File(
          p.join(gnSource.parent.path, 'BUILD.gn'),
        ).writeAsStringSync('# nested GN workspace\n');
        final generatedConfig = File(
          p.join(
            gn.projectRoot.path,
            'out/debug/dartlang/gen/gn/lib/source_package_config.json',
          ),
        );
        generatedConfig.parent.createSync(recursive: true);
        generatedConfig.writeAsStringSync(
          '{"configVersion":2,"packages":[]}\n',
        );
        _expectFailure(
          await gn.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          'analyzer-context-root-unsupported',
        );
      },
    );

    test(
      'ignores public action classification reasons for internal evidence',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final findings = [
          for (final finding in fixture.analysis.findings)
            finding.node.id == fixture.selectedNodeId
                ? _copyFinding(
                    finding,
                    classificationReasons: const [
                      ClassificationReason.unsupportedAction,
                      ClassificationReason.nonDeterministicInverse,
                      ClassificationReason.broadRemovalScope,
                    ],
                  )
                : finding,
        ];
        final analysis = _copyAnalysis(fixture.analysis, findings: findings);

        final result = await fixture.capture(analysis: analysis);

        expect(result, isA<L10nFamilySnapshotReady>());
      },
    );

    test(
      'uses a versioned first-dot output rule for every supported schema',
      () async {
        for (final version in const [(3, 38, 7), (3, 41, 5), (3, 44, 1)]) {
          final fixture = await _Fixture.create(
            frameworkVersion: Version(version.$1, version.$2, version.$3),
          );
          addTearDown(fixture.dispose);

          final result = await fixture.capture();

          expect(result, isA<L10nFamilySnapshotReady>(), reason: '$version');
          expect(
            (result as L10nFamilySnapshotReady).snapshot.expectedGeneratedPaths,
            {
              'lib/generated/l10n/app.bundle.dart',
              'lib/generated/l10n/app_en.bundle.dart',
              'lib/generated/l10n/app_vi.bundle.dart',
            },
            reason: '$version',
          );
        }
      },
    );

    test(
      'derives a valid locale from the ARB filename when @@locale is absent',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final locale = File(
          p.join(fixture.projectRoot.path, 'lib/l10n/app_vi.arb'),
        );
        final document =
            jsonDecode(locale.readAsStringSync()) as Map<String, Object?>;
        document.remove('@@locale');
        locale.writeAsStringSync(jsonEncode(document));

        final result = await fixture.capture();

        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
        expect(
          (result as L10nFamilySnapshotReady).snapshot.expectedGeneratedPaths,
          contains('lib/generated/l10n/app_vi.bundle.dart'),
        );
      },
    );

    test(
      'preserves duplicate selection until the mutation planner rejects it',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);

        final result = await fixture.capture(
          selectedNodeIds: [fixture.selectedNodeId, fixture.selectedNodeId],
        );

        _expectFailure(
          result,
          L10nEvidenceRejectionCode.invalidSelection,
          'selection-key-duplicate',
        );
      },
    );

    test('rejects an empty selection before planning', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      final result = await fixture.capture(selectedNodeIds: const []);

      _expectFailure(
        result,
        L10nEvidenceRejectionCode.invalidSelection,
        'selection-empty',
      );
    });

    test(
      'ignores unrelated full-scan adapter facts during l10n rerun',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        fixture.analysis.graph.addNode(
          GraphNode(
            id: 'route:l10n_snapshot_fixture:/unrelated',
            kind: NodeKind.route,
            origin: File(p.join(fixture.projectRoot.path, 'lib/main.dart')).uri,
            displayName: '/unrelated',
          ),
          producer: 'go_router',
        );
        final analysis = _copyAnalysis(
          fixture.analysis,
          adapterRuns: [
            ...fixture.analysis.adapterRuns,
            const AdapterRunReport(
              id: 'go_router',
              name: 'go_router',
              role: AdapterRunRole.reporting,
              status: AdapterRunStatus.executed,
              elapsedMicros: 1,
              nodesAdded: 1,
              edgesAdded: 0,
              blockersAdded: 0,
            ),
          ],
        );

        final result = await fixture.capture(analysis: analysis);

        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
      },
    );

    test('rejects missing and unsuccessful l10n adapter runs', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final without = _copyAnalysis(
        fixture.analysis,
        adapterRuns: fixture.analysis.adapterRuns
            .where((run) => run.id != 'l10n')
            .toList(),
      );
      final failedRuns = [
        for (final run in fixture.analysis.adapterRuns)
          run.id == 'l10n'
              ? AdapterRunReport(
                  id: run.id,
                  name: run.name,
                  role: run.role,
                  status: AdapterRunStatus.failed,
                  elapsedMicros: run.elapsedMicros,
                  nodesAdded: run.nodesAdded,
                  edgesAdded: run.edgesAdded,
                  blockersAdded: run.blockersAdded,
                  reason: 'fixture failure',
                )
              : run,
      ];

      _expectFailure(
        await fixture.capture(analysis: without),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'l10n-adapter-run-missing',
      );
      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(fixture.analysis, adapterRuns: failedRuns),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'l10n-adapter-run-not-executed',
      );
      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            adapterRuns: fixture.analysis.adapterRuns
                .where((run) => run.id != 'dart')
                .toList(),
          ),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'dart-support-run-not-executed',
      );
    });

    test('rejects wrong owner, kind, rule, origin, and key metadata', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final selected = fixture.selectedFinding;
      final cases = <String, ({GraphNode node, String producer, String? rule})>{
        'owner': (node: selected.node, producer: 'other', rule: null),
        'kind': (
          node: _copyNode(selected.node, kind: NodeKind.route),
          producer: 'l10n',
          rule: null,
        ),
        'rule': (node: selected.node, producer: 'l10n', rule: 'PRN-WRONG-001'),
        'origin': (
          node: _copyNode(
            selected.node,
            origin: File(
              p.join(fixture.projectRoot.path, 'lib/l10n/app_vi.arb'),
            ).uri,
          ),
          producer: 'l10n',
          rule: null,
        ),
        'metadata': (
          node: _copyNode(
            selected.node,
            metadata: {...selected.node.metadata, 'key': 7},
          ),
          producer: 'l10n',
          rule: null,
        ),
        'typed-wrong-key': (
          node: _copyNode(
            selected.node,
            metadata: {...selected.node.metadata, 'key': 'live'},
          ),
          producer: 'l10n',
          rule: null,
        ),
        'display-name': (
          node: _copyNode(selected.node, displayName: 'live'),
          producer: 'l10n',
          rule: null,
        ),
        'node-id': (
          node: _copyNode(selected.node, id: 'l10n:l10n_snapshot_fixture:live'),
          producer: 'l10n',
          rule: null,
        ),
      };

      for (final entry in cases.entries) {
        final graph = ReachabilityGraph()
          ..addNode(entry.value.node, producer: entry.value.producer);
        final finding = _copyFinding(
          selected,
          node: entry.value.node,
          ruleId: entry.value.rule,
        );
        final analysis = _copyAnalysis(
          fixture.analysis,
          graph: graph,
          findings: [finding],
        );
        _expectFailure(
          await fixture.capture(analysis: analysis),
          L10nEvidenceRejectionCode.invalidSelection,
          null,
          reason: entry.key,
        );
      }
      for (final reportingAdapterId in <String?>[null, 'other']) {
        _expectFailure(
          await fixture.capture(
            analysis: _copyAnalysis(
              fixture.analysis,
              findings: [
                _copyFinding(
                  selected,
                  reportingAdapterId: reportingAdapterId,
                  overrideReportingAdapterId: true,
                ),
              ],
            ),
          ),
          L10nEvidenceRejectionCode.invalidSelection,
          null,
          reason: 'reporting adapter $reportingAdapterId',
        );
      }
    });

    test('rejects pseudo and cross-family selections', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);

      _expectFailure(
        await fixture.capture(selectedNodeIds: const ['l10n:fixture:%40dead']),
        L10nEvidenceRejectionCode.invalidSelection,
        null,
      );
      final crossNode = _copyNode(
        fixture.selectedFinding.node,
        origin: File(
          p.join(fixture.projectRoot.path, 'lib/l10n/app_vi.arb'),
        ).uri,
      );
      final graph = ReachabilityGraph()..addNode(crossNode, producer: 'l10n');
      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            graph: graph,
            findings: [_copyFinding(fixture.selectedFinding, node: crossNode)],
          ),
        ),
        L10nEvidenceRejectionCode.invalidSelection,
        null,
      );
    });

    test('rejects selected reachable, retained, or protected nodes', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final selected = fixture.selectedFinding;

      final reachable = ReachabilityGraph()
        ..addNode(selected.node, producer: 'l10n')
        ..addRoot(selected.node.id, reason: 'fixture root');
      final retained = ReachabilityGraph()
        ..addNode(selected.node, producer: 'l10n')
        ..addBlocker(
          Blocker(
            producer: 'fixture',
            reason: 'active family uncertainty',
            affectedNodeIds: {selected.node.id},
          ),
        );
      final protected = ReachabilityGraph()
        ..addNode(selected.node, producer: 'l10n')
        ..protect(selected.node.id, reason: 'fixture keep');
      for (final entry in {
        'selected-node-reachable': reachable,
        'selected-node-retained': retained,
        'selected-node-protected': protected,
      }.entries) {
        _expectFailure(
          await fixture.capture(
            analysis: _copyAnalysis(
              fixture.analysis,
              graph: entry.value,
              findings: [selected],
            ),
          ),
          entry.key == 'selected-node-retained'
              ? L10nEvidenceRejectionCode.scanBlockerPresent
              : L10nEvidenceRejectionCode.invalidSelection,
          null,
          reason: entry.key,
        );
      }
    });

    test('rejects active family blockers and dangling endpoints', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final selected = fixture.selectedFinding;
      final blocked = ReachabilityGraph()
        ..addNode(selected.node, producer: 'l10n')
        ..addBlocker(
          Blocker(
            producer: 'fixture',
            reason: 'family input incomplete',
            affectedNamespace: 'l10n:l10n_snapshot_fixture:',
          ),
        );
      final dangling = ReachabilityGraph()
        ..addNode(selected.node, producer: 'l10n')
        ..addEdge(
          GraphEdge(
            from: 'dart:l10n_snapshot_fixture/lib/missing.dart',
            to: selected.node.id,
            kind: EdgeKind.references,
            evidence: const Evidence(
              kind: EvidenceKind.semanticReference,
              producer: 'fixture',
              description: 'dangling fixture edge',
              exact: true,
            ),
          ),
        );

      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            graph: blocked,
            findings: [selected],
          ),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        null,
      );
      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            graph: dangling,
            findings: [selected],
          ),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'graph-integrity-incomplete',
      );
    });

    test(
      'checks blockers across the family but ignores an unretained source',
      () async {
        final activeFixture = await _Fixture.create();
        addTearDown(activeFixture.dispose);
        final liveId = activeFixture.analysis.graph
            .nodesOfKind(NodeKind.localizationKey)
            .singleWhere((node) => node.metadata['key'] == 'live')
            .id;
        activeFixture.analysis.graph.addBlocker(
          Blocker(
            producer: 'fixture',
            reason: 'unselected sibling uncertainty',
            location: 'lib/active.dart:12:4',
            affectedNodeIds: {liveId},
          ),
        );
        final activeResult = await activeFixture.capture();
        _expectFailure(
          activeResult,
          L10nEvidenceRejectionCode.scanBlockerPresent,
          'active-family-blocker',
        );
        expect(
          (activeResult as L10nFamilySnapshotRejected)
              .failures
              .single
              .relativePath,
          'lib/active.dart',
        );

        final inactiveFixture = await _Fixture.create();
        addTearDown(inactiveFixture.dispose);
        final source = GraphNode(
          id: 'dart:l10n_snapshot_fixture/lib/unretained.dart',
          kind: NodeKind.dartLibrary,
          origin: File(
            p.join(inactiveFixture.projectRoot.path, 'lib/unretained.dart'),
          ).uri,
          displayName: 'unretained.dart',
        );
        inactiveFixture.analysis.graph
          ..addNode(source, producer: 'fixture')
          ..addBlocker(
            Blocker(
              producer: 'fixture',
              reason: 'inactive source-scoped uncertainty',
              sourceNodeId: source.id,
              affectedNodeIds: {
                inactiveFixture.analysis.graph
                    .nodesOfKind(NodeKind.localizationKey)
                    .singleWhere((node) => node.metadata['key'] == 'live')
                    .id,
              },
            ),
          );
        final analysis = _copyAnalysis(inactiveFixture.analysis);
        final result = await inactiveFixture.capture(
          analysis: analysis,
          preflight: L10nFamilyPreflight.testing(
            analysisRerunner: _FixedRerunner(analysis),
          ),
        );
        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
      },
    );

    test('rejects incomplete target and root coverage', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final partialTargetProject = _copyProject(
        fixture.project,
        targetMatrix: TargetMatrix(
          targets: fixture.project.targets,
          status: TargetMatrixStatus.declaredPartial,
          source: 'fixture',
          issues: const ['partial'],
        ),
      );
      final partialRootProject = _copyProject(
        fixture.project,
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.applicationEntrypoints,
          source: 'fixture',
          internalBoundaryComplete: false,
          externalConsumersCovered: false,
          issues: const ['partial'],
        ),
      );

      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            project: partialTargetProject,
          ),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'analysis-coverage-incomplete',
      );
      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(
            fixture.analysis,
            project: partialRootProject,
          ),
        ),
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'analysis-coverage-incomplete',
      );
    });

    test(
      'rejects a vacuous target matrix and preserves package open-world coverage',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final zeroTargetProject = _copyProject(
          fixture.project,
          targetMatrix: TargetMatrix.declared(const []),
        );
        _expectFailure(
          await fixture.capture(
            analysis: _copyAnalysis(
              fixture.analysis,
              project: zeroTargetProject,
            ),
          ),
          L10nEvidenceRejectionCode.scanBlockerPresent,
          'analysis-coverage-incomplete',
        );

        final packageProject = _copyProject(
          fixture.project,
          analysisMode: AnalysisMode.package,
          rootCoverage: RootCoverage(
            mode: RootCoverageMode.packagePublicApi,
            source: 'fixture',
            internalBoundaryComplete: true,
            externalConsumersCovered: false,
            publicEntrypoints: const ['lib/main.dart'],
          ),
        );
        final packageAnalysis = _copyAnalysis(
          fixture.analysis,
          project: packageProject,
        );
        final result = await fixture.capture(
          analysis: packageAnalysis,
          preflight: L10nFamilyPreflight.testing(
            analysisRerunner: _FixedRerunner(packageAnalysis),
          ),
        );

        expect(
          result,
          isA<L10nFamilySnapshotReady>(),
          reason: _describeResult(result),
        );
        final semantics =
            (result as L10nFamilySnapshotReady).snapshot.projectSemantics;
        expect(semantics.analysisMode, AnalysisMode.package);
        expect(semantics.rootCoverage.internalBoundaryComplete, isTrue);
        expect(semantics.rootCoverage.externalConsumersCovered, isFalse);
      },
    );

    test(
      'rejects semantic ARB disagreement and non-regular authorities',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final locale = File(
          p.join(fixture.projectRoot.path, 'lib/l10n/app_vi.arb'),
        );
        locale.writeAsStringSync('''
{"@@locale":"vi","live":"Live","dead":"Dead","localeOnly":"No"}
''');

        _expectFailure(
          await fixture.capture(),
          L10nEvidenceRejectionCode.arbFamilyIncomplete,
          null,
        );

        final other = await _Fixture.create();
        addTearDown(other.dispose);
        final header = File(
          p.join(other.projectRoot.path, 'lib/l10n/header.txt'),
        );
        header.deleteSync();
        Directory(header.path).createSync();
        _expectFailure(
          await other.capture(),
          L10nEvidenceRejectionCode.invalidInputPath,
          null,
        );
      },
    );

    test(
      'rejects live configuration bytes that disagree with analyzed semantics',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final pubspec = File(p.join(fixture.projectRoot.path, 'pubspec.yaml'));
        pubspec.writeAsStringSync(
          pubspec.readAsStringSync().replaceFirst(
            'description: Private V3.1 l10n family snapshot fixture.',
            'description: Drifted after the analyzed snapshot.',
          ),
        );
        final liveProject = await ProjectContext.load(
          fixture.projectRoot,
          targets: fixture.project.targets,
        );
        final reloaded = await const DefaultL10nGenerationConfigLoader().load(
          project: liveProject,
          toolchain: fixture.toolchain.machineIdentity,
        );
        expect(reloaded, isA<L10nGenerationConfigReady>());

        _expectFailure(
          await fixture.capture(
            generationConfig: (reloaded as L10nGenerationConfigReady).config,
          ),
          L10nEvidenceRejectionCode.sourceDrift,
          'project-pubspec-semantic-drift',
        );

        final yamlFixture = await _Fixture.create();
        addTearDown(yamlFixture.dispose);
        final yaml = File(p.join(yamlFixture.projectRoot.path, 'l10n.yaml'));
        yaml.writeAsStringSync('${yaml.readAsStringSync()}# drift\n');
        _expectFailure(
          await yamlFixture.capture(),
          L10nEvidenceRejectionCode.sourceDrift,
          'generation-config-yaml-drift',
        );
      },
    );

    test('rejects symlink input and unsafe output sibling', () async {
      if (Platform.isWindows) return;
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final header = File(
        p.join(fixture.projectRoot.path, 'lib/l10n/header.txt'),
      );
      final outside = File(p.join(fixture.container.path, 'outside.txt'))
        ..writeAsStringSync('outside');
      header.deleteSync();
      Link(header.path).createSync(outside.path);
      _expectFailure(
        await fixture.capture(),
        L10nEvidenceRejectionCode.invalidInputPath,
        null,
      );

      final dartSymlink = await _Fixture.create();
      addTearDown(dartSymlink.dispose);
      final linkedEntrypoint = p.join(
        dartSymlink.projectRoot.path,
        'lib/linked_main.dart',
      );
      Link(
        linkedEntrypoint,
      ).createSync(p.join(dartSymlink.projectRoot.path, 'lib/main.dart'));
      final linkedProject = _copyProject(
        dartSymlink.project,
        targetMatrix: TargetMatrix.declared([
          BuildTarget(
            name: 'app',
            platform: 'android',
            entrypoint: 'lib/linked_main.dart',
          ),
        ]),
      );
      _expectFailure(
        await dartSymlink.capture(
          analysis: _copyAnalysis(dartSymlink.analysis, project: linkedProject),
        ),
        L10nEvidenceRejectionCode.invalidInputPath,
        null,
      );

      final workspaceSymlink = await _Fixture.create();
      addTearDown(workspaceSymlink.dispose);
      Link(
        p.join(workspaceSymlink.projectRoot.path, 'lib/feature.dart'),
      ).createSync(p.join(workspaceSymlink.projectRoot.path, 'lib/main.dart'));
      _expectFailure(
        await workspaceSymlink.capture(),
        L10nEvidenceRejectionCode.invalidInputPath,
        null,
      );

      final other = await _Fixture.create();
      addTearDown(other.dispose);
      File(
        p.join(other.projectRoot.path, 'lib/generated/l10n/app_fr.bundle.dart'),
      ).writeAsStringSync('class UnexpectedFrench {}\n');
      _expectFailure(
        await other.capture(),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'unowned-output-family-sibling',
      );

      final casefold = await _Fixture.create();
      addTearDown(casefold.dispose);
      File(
        p.join(
          casefold.projectRoot.path,
          'lib/generated/l10n/app_en.bundle.dart',
        ),
      ).deleteSync();
      File(
        p.join(
          casefold.projectRoot.path,
          'lib/generated/l10n/App_en.bundle.dart',
        ),
      ).writeAsStringSync('class CaseFoldCollision {}\n');
      _expectFailure(
        await casefold.capture(),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'output-family-casefold-collision',
      );
    });

    test(
      'rejects missing selected package and duplicate package record fields',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        fixture.packageConfig.writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"external_dep","rootUri":"../../external_dep","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        _expectFailure(
          await fixture.capture(),
          L10nEvidenceRejectionCode.packageResolutionDrift,
          'selected-package-entry-missing',
        );

        final other = await _Fixture.create();
        addTearDown(other.dispose);
        other.packageConfig.writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"l10n_snapshot_fixture","rootUri":"../","root\\u0055ri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
        _expectFailure(
          await other.capture(),
          L10nEvidenceRejectionCode.packageResolutionDrift,
          'package-record-json-invalid',
        );
      },
    );

    test(
      'package projector accepts underscore names and an absent lib directory',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        Directory(
          p.join(fixture.container.path, '_fe_analyzer_shared/lib'),
        ).deleteSync(recursive: true);

        final result = const L10nPackageConfigProjector().project(
          sourceBytes: fixture.packageConfig.readAsBytesSync(),
          canonicalProjectRoot: fixture.projectRoot.resolveSymbolicLinksSync(),
          selectedPackageName: fixture.project.packageName,
          toolchain: fixture.toolchain,
        );

        expect(result, isA<L10nPackageConfigProjectionReady>());
        final projection =
            (result as L10nPackageConfigProjectionReady).projection;
        expect(
          projection.canonicalRootsByPackage,
          contains('_fe_analyzer_shared'),
        );
      },
    );

    test('package projector rebases nested project-owned packages', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final nestedPackage = Directory(
        p.join(fixture.projectRoot.path, 'packages/local_dependency'),
      )..createSync(recursive: true);
      Directory(p.join(nestedPackage.path, 'lib')).createSync();
      File(
        p.join(nestedPackage.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: local_dependency\n');
      File(
        p.join(nestedPackage.path, 'lib/local_dependency.dart'),
      ).writeAsStringSync('const localValue = 1;\n');
      final source = fixture.packageConfig.readAsStringSync().replaceFirst(
        '{"name":"external_dep"',
        '{"name":"local_dependency","rootUri":"../packages/local_dependency/",'
            '"packageUri":"lib/","languageVersion":"3.9"},\n  '
            '{"name":"external_dep"',
      );

      final result = const L10nPackageConfigProjector().project(
        sourceBytes: utf8.encode(source),
        canonicalProjectRoot: fixture.projectRoot.resolveSymbolicLinksSync(),
        selectedPackageName: fixture.project.packageName,
        toolchain: fixture.toolchain,
      );

      expect(result, isA<L10nPackageConfigProjectionReady>());
      final projection =
          (result as L10nPackageConfigProjectionReady).projection;
      expect(projection.projectOwnedRootsByPackage, {
        'local_dependency': 'packages/local_dependency',
      });
      final projected =
          jsonDecode(utf8.decode(projection.stageBytes.copy()))
              as Map<String, Object?>;
      final records = (projected['packages']! as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(
        records.singleWhere(
          (record) => record['name'] == 'local_dependency',
        )['rootUri'],
        '../packages/local_dependency/',
      );
    });

    test('captures nested package lib closure for isolated stages', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final nestedPackage = Directory(
        p.join(fixture.projectRoot.path, 'packages/local_dependency'),
      )..createSync(recursive: true);
      Directory(
        p.join(nestedPackage.path, 'lib/src'),
      ).createSync(recursive: true);
      File(p.join(nestedPackage.path, 'pubspec.yaml')).writeAsStringSync('''
name: local_dependency
environment:
  sdk: ^3.9.0
''');
      File(
        p.join(nestedPackage.path, 'analysis_options.yaml'),
      ).writeAsStringSync('''
analyzer:
  errors:
    unused_import: ignore
''');
      File(
        p.join(nestedPackage.path, 'lib/local_dependency.dart'),
      ).writeAsStringSync("export 'src/value.dart';\n");
      File(
        p.join(nestedPackage.path, 'lib/src/value.dart'),
      ).writeAsStringSync('const localValue = 1;\n');
      fixture.packageConfig.writeAsStringSync(
        fixture.packageConfig.readAsStringSync().replaceFirst(
          '{"name":"external_dep"',
          '{"name":"local_dependency",'
              '"rootUri":"../packages/local_dependency/",'
              '"packageUri":"lib/","languageVersion":"3.9"},\n  '
              '{"name":"external_dep"',
        ),
      );
      final main = File(p.join(fixture.projectRoot.path, 'lib/main.dart'));
      main.writeAsStringSync(
        "import 'package:local_dependency/local_dependency.dart';\n"
        '${main.readAsStringSync()}\n'
        'const capturedLocalValue = localValue;\n',
      );
      final analysis = await ProjectAnalyzer(
        project: fixture.project,
        only: const {'l10n'},
      ).analyze();
      final selected = analysis.graph
          .nodesOfKind(NodeKind.localizationKey)
          .singleWhere((node) => node.metadata['key'] == 'dead')
          .id;

      final result = await fixture.capture(
        analysis: analysis,
        selectedNodeIds: [selected],
      );

      expect(
        result,
        isA<L10nFamilySnapshotReady>(),
        reason: _describeResult(result),
      );
      final snapshot = (result as L10nFamilySnapshotReady).snapshot;
      expect(
        snapshot.entries.keys,
        containsAll(<String>[
          'packages/local_dependency/pubspec.yaml',
          'packages/local_dependency/analysis_options.yaml',
          'packages/local_dependency/lib/local_dependency.dart',
          'packages/local_dependency/lib/src/value.dart',
        ]),
      );
      expect(
        snapshot.verificationClosure.projectOwnedDartPaths,
        containsAll(<String>[
          'packages/local_dependency/lib/local_dependency.dart',
          'packages/local_dependency/lib/src/value.dart',
        ]),
      );
    });

    test(
      'package projector still rejects ancestor path dependencies',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        File(
          p.join(fixture.container.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: ancestor_dependency\n');
        final source = fixture.packageConfig.readAsStringSync().replaceFirst(
          '{"name":"external_dep"',
          '{"name":"ancestor_dependency","rootUri":"../../",'
              '"packageUri":"lib/","languageVersion":"3.9"},\n  '
              '{"name":"external_dep"',
        );

        final result = const L10nPackageConfigProjector().project(
          sourceBytes: utf8.encode(source),
          canonicalProjectRoot: fixture.projectRoot.resolveSymbolicLinksSync(),
          selectedPackageName: fixture.project.packageName,
          toolchain: fixture.toolchain,
        );

        expect(result, isA<L10nPackageConfigProjectionRejected>());
        expect(
          (result as L10nPackageConfigProjectionRejected).failure.detailCode,
          'external-package-overlaps-project',
        );
      },
    );

    test(
      'package projector rejects non-integer schema and noncanonical language',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final source = fixture.packageConfig.readAsStringSync();
        final cases = <String, String>{
          'schema': source.replaceFirst(
            '"configVersion":2',
            '"configVersion":2.0',
          ),
          'language': source.replaceFirst(
            '"languageVersion":"3.9"',
            '"languageVersion":"03.09"',
          ),
        };
        for (final entry in cases.entries) {
          final result = const L10nPackageConfigProjector().project(
            sourceBytes: utf8.encode(entry.value),
            canonicalProjectRoot: fixture.projectRoot
                .resolveSymbolicLinksSync(),
            selectedPackageName: fixture.project.packageName,
            toolchain: fixture.toolchain,
          );
          expect(
            result,
            isA<L10nPackageConfigProjectionRejected>(),
            reason: entry.key,
          );
        }
      },
    );

    test(
      'rejects package resolution bound to a different Flutter toolchain',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final original = fixture.packageConfig.readAsStringSync();
        fixture.packageConfig.writeAsStringSync(
          original.replaceFirst(
            '"flutterVersion":"3.41.5"',
            '"flutterVersion":"3.44.1"',
          ),
        );

        _expectFailure(
          await fixture.capture(),
          L10nEvidenceRejectionCode.packageResolutionDrift,
          'package-flutter-version-mismatch',
        );

        final otherSdkPackage = Directory(
          p.join(
            fixture.container.path,
            'other_sdk/packages/flutter_web_plugins',
          ),
        )..createSync(recursive: true);
        Directory(p.join(otherSdkPackage.path, 'lib')).createSync();
        File(
          p.join(otherSdkPackage.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: flutter_web_plugins\n');
        final flutterRecord =
            '{"name":"flutter","rootUri":"../../sdk/packages/flutter/","packageUri":"lib/","languageVersion":"3.9"}';
        final cases = <String, String>{
          'flutterRoot-null': original.replaceFirst(
            RegExp(r'"flutterRoot":"[^"]+"'),
            '"flutterRoot":null',
          ),
          'flutterVersion-null': original.replaceFirst(
            '"flutterVersion":"3.41.5"',
            '"flutterVersion":null',
          ),
          'generatorVersion-null': original.replaceFirst(
            '"generatorVersion":"3.11.3"',
            '"generatorVersion":null',
          ),
          'sdk-record': original.replaceFirst(
            flutterRecord,
            '$flutterRecord,\n  '
            '{"name":"flutter_web_plugins","rootUri":'
            '${jsonEncode(otherSdkPackage.uri.toString())},'
            '"packageUri":"lib/","languageVersion":"3.9"}',
          ),
        };
        for (final entry in cases.entries) {
          final result = const L10nPackageConfigProjector().project(
            sourceBytes: utf8.encode(entry.value),
            canonicalProjectRoot: fixture.projectRoot
                .resolveSymbolicLinksSync(),
            selectedPackageName: fixture.project.packageName,
            toolchain: fixture.toolchain,
          );
          expect(
            result,
            isA<L10nPackageConfigProjectionRejected>(),
            reason: entry.key,
          );
        }
      },
    );

    test(
      'normalizes external package authority transitions at the barrier',
      () async {
        for (final transition in const ['root-loss', 'symlink', 'pubspec']) {
          final fixture = await _Fixture.create();
          addTearDown(fixture.dispose);
          late final void Function() mutate;
          switch (transition) {
            case 'root-loss':
              mutate = () {
                fixture.externalRoot.renameSync(
                  p.join(fixture.container.path, 'external_dep_removed'),
                );
              };
            case 'pubspec':
              mutate = () {
                final pubspec = File(
                  p.join(fixture.externalRoot.path, 'pubspec.yaml'),
                );
                pubspec.writeAsStringSync(
                  '${pubspec.readAsStringSync()}# authority drift\n',
                );
              };
            case 'symlink':
              final cacheA = Directory(
                p.join(fixture.container.path, 'cache_a/external_dep'),
              )..createSync(recursive: true);
              final cacheB = Directory(
                p.join(fixture.container.path, 'cache_b/external_dep'),
              )..createSync(recursive: true);
              _copyTree(fixture.externalRoot, cacheA);
              _copyTree(fixture.externalRoot, cacheB);
              final cacheLink = Link(
                p.join(fixture.container.path, 'cache_link'),
              )..createSync(cacheA.parent.path);
              final logicalRoot = Directory(
                p.join(cacheLink.path, 'external_dep'),
              );
              fixture.packageConfig.writeAsStringSync(
                fixture.packageConfig.readAsStringSync().replaceFirst(
                  '"rootUri":"../../external_dep/"',
                  '"rootUri":${jsonEncode(logicalRoot.uri.toString())}',
                ),
              );
              mutate = () {
                cacheLink.deleteSync();
                cacheLink.createSync(cacheB.parent.path);
              };
          }

          final result = await fixture.capture(
            preflight: L10nFamilyPreflight.testing(
              beforeSecondRead: () async => mutate(),
            ),
          );

          _expectFailure(
            result,
            L10nEvidenceRejectionCode.packageResolutionDrift,
            'package-projection-second-read-drift',
            reason: transition,
          );
        }
      },
    );

    test('rejects incomplete analyzer closure', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final project = _copyProject(
        fixture.project,
        rootCoverage: RootCoverage(
          mode: RootCoverageMode.applicationEntrypoints,
          source: 'fixture',
          internalBoundaryComplete: true,
          externalConsumersCovered: true,
          publicEntrypoints: const ['lib/missing_public.dart'],
        ),
      );

      _expectFailure(
        await fixture.capture(
          analysis: _copyAnalysis(fixture.analysis, project: project),
        ),
        L10nEvidenceRejectionCode.invalidInputPath,
        'analyzer-root-file-missing',
      );
    });

    test('rejects a l10n rerun fingerprint mismatch', () async {
      final fixture = await _Fixture.create();
      addTearDown(fixture.dispose);
      final rerun = _copyAnalysis(fixture.analysis, findings: const []);
      final preflight = L10nFamilyPreflight.testing(
        analysisRerunner: _FixedRerunner(rerun),
      );

      final result = await fixture.capture(preflight: preflight);

      _expectFailure(
        result,
        L10nEvidenceRejectionCode.sourceDrift,
        'l10n-rerun-fingerprint-drift',
      );
    });

    test(
      'rejects exact byte drift at the deterministic second-read barrier',
      () async {
        final fixture = await _Fixture.create();
        addTearDown(fixture.dispose);
        final lock = File(p.join(fixture.projectRoot.path, 'pubspec.lock'));
        final preflight = L10nFamilyPreflight.testing(
          beforeSecondRead: () async {
            lock.writeAsStringSync('${lock.readAsStringSync()}# drift\n');
          },
        );

        final result = await fixture.capture(preflight: preflight);

        _expectFailure(
          result,
          L10nEvidenceRejectionCode.sourceDrift,
          'snapshot-source-drift',
        );
      },
    );

    test(
      'rejects absent-state and analyzer-membership drift at the barrier',
      () async {
        final absentFixture = await _Fixture.create();
        addTearDown(absentFixture.dispose);
        final absentResult = await absentFixture.capture(
          preflight: L10nFamilyPreflight.testing(
            beforeSecondRead: () async {
              final sidecar = File(
                p.join(
                  absentFixture.projectRoot.path,
                  'build/untranslated.json',
                ),
              );
              sidecar.parent.createSync(recursive: true);
              sidecar.writeAsStringSync('{}\n');
            },
          ),
        );
        _expectFailure(
          absentResult,
          L10nEvidenceRejectionCode.sourceDrift,
          'snapshot-source-drift',
        );

        final membershipFixture = await _Fixture.create();
        addTearDown(membershipFixture.dispose);
        final membershipResult = await membershipFixture.capture(
          preflight: L10nFamilyPreflight.testing(
            beforeSecondRead: () async {
              File(
                p.join(membershipFixture.projectRoot.path, 'lib/late.dart'),
              ).writeAsStringSync('const lateMember = true;\n');
            },
          ),
        );
        _expectFailure(
          membershipResult,
          L10nEvidenceRejectionCode.sourceDrift,
          'snapshot-membership-drift',
        );

        final malformedArbFixture = await _Fixture.create();
        addTearDown(malformedArbFixture.dispose);
        final malformedArbResult = await malformedArbFixture.capture(
          preflight: L10nFamilyPreflight.testing(
            beforeSecondRead: () async {
              Directory(
                p.join(
                  malformedArbFixture.projectRoot.path,
                  'lib/l10n/app_fr.arb',
                ),
              ).createSync();
            },
          ),
        );
        _expectFailure(
          malformedArbResult,
          L10nEvidenceRejectionCode.sourceDrift,
          'snapshot-membership-drift',
        );

        if (!Platform.isWindows) {
          final symlinkFixture = await _Fixture.create();
          addTearDown(symlinkFixture.dispose);
          final symlinkResult = await symlinkFixture.capture(
            preflight: L10nFamilyPreflight.testing(
              beforeSecondRead: () async {
                Link(
                  p.join(symlinkFixture.projectRoot.path, 'lib/late.dart'),
                ).createSync(
                  p.join(symlinkFixture.projectRoot.path, 'lib/main.dart'),
                );
              },
            ),
          );
          _expectFailure(
            symlinkResult,
            L10nEvidenceRejectionCode.sourceDrift,
            'snapshot-membership-drift',
          );
        }

        final optionsFixture = await _Fixture.create();
        addTearDown(optionsFixture.dispose);
        final optionsResult = await optionsFixture.capture(
          preflight: L10nFamilyPreflight.testing(
            beforeSecondRead: () async {
              File(
                p.join(
                  optionsFixture.projectRoot.path,
                  'lib/analysis_options.yaml',
                ),
              ).writeAsStringSync('plugins: {}\n');
            },
          ),
        );
        _expectFailure(
          optionsResult,
          L10nEvidenceRejectionCode.sourceDrift,
          'analyzer-context-authority-drift',
        );
      },
    );
  });
}

final class _Fixture {
  _Fixture._({
    required this.container,
    required this.projectRoot,
    required this.externalRoot,
    required this.project,
    required this.analysis,
    required this.config,
    required this.toolchain,
    required this.selectedNodeId,
  });

  final Directory container;
  final Directory projectRoot;
  final Directory externalRoot;
  final ProjectContext project;
  final AnalysisSnapshot analysis;
  final L10nGenerationConfig config;
  final L10nToolchainResolved toolchain;
  final String selectedNodeId;

  File get packageConfig =>
      File(p.join(projectRoot.path, '.dart_tool', 'package_config.json'));

  Finding get selectedFinding => analysis.findings.singleWhere(
    (finding) => finding.node.id == selectedNodeId,
  );

  static Future<_Fixture> create({
    Version? frameworkVersion,
    String? unresolvedDevDependency,
    bool sharedArbAndOutputDirectory = false,
  }) async {
    final selectedFrameworkVersion = frameworkVersion ?? Version(3, 41, 5);
    final createdContainer = await Directory.systemTemp.createTemp(
      'l10n_family_preflight_',
    );
    final container = Directory(createdContainer.resolveSymbolicLinksSync());
    final projectRoot = Directory(p.join(container.path, 'project'));
    final externalRoot = Directory(p.join(container.path, 'external_dep'));
    final analyzerSharedRoot = Directory(
      p.join(container.path, '_fe_analyzer_shared'),
    );
    final sdkRoot = Directory(p.join(container.path, 'sdk'));
    projectRoot.createSync(recursive: true);
    externalRoot.createSync(recursive: true);
    analyzerSharedRoot.createSync(recursive: true);
    Directory(
      p.join(sdkRoot.path, 'packages/flutter/lib'),
    ).createSync(recursive: true);
    _copyTree(
      Directory(p.absolute('test/fixtures/l10n_action_readiness/standard')),
      projectRoot,
    );
    if (sharedArbAndOutputDirectory) {
      final yaml = File(p.join(projectRoot.path, 'l10n.yaml'));
      yaml.writeAsStringSync(
        yaml.readAsStringSync().replaceFirst(
          'output-dir: lib/generated/l10n',
          'output-dir: lib/l10n',
        ),
      );
      final generatedDirectory = Directory(
        p.join(projectRoot.path, 'lib/generated/l10n'),
      );
      for (final file in generatedDirectory.listSync().whereType<File>()) {
        file.renameSync(
          p.join(projectRoot.path, 'lib/l10n', p.basename(file.path)),
        );
      }
      final main = File(p.join(projectRoot.path, 'lib/main.dart'));
      main.writeAsStringSync(
        main.readAsStringSync().replaceFirst(
          "'generated/l10n/app.bundle.dart'",
          "'l10n/app.bundle.dart'",
        ),
      );
    }
    if (unresolvedDevDependency != null) {
      final pubspec = File(p.join(projectRoot.path, 'pubspec.yaml'));
      pubspec.writeAsStringSync(
        '${pubspec.readAsStringSync()}\n'
        'dev_dependencies:\n'
        '  $unresolvedDevDependency: ^0.7.0\n',
      );
    }
    File(p.join(externalRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: external_dep
environment:
  sdk: ^3.9.0
''');
    Directory(p.join(externalRoot.path, 'lib')).createSync();
    File(
      p.join(externalRoot.path, 'lib/external_dep.dart'),
    ).writeAsStringSync('const externalValue = 1;\n');
    File(p.join(analyzerSharedRoot.path, 'pubspec.yaml')).writeAsStringSync('''
name: _fe_analyzer_shared
environment:
  sdk: ^3.9.0
''');
    Directory(p.join(analyzerSharedRoot.path, 'lib')).createSync();
    File(
      p.join(analyzerSharedRoot.path, 'lib/shared.dart'),
    ).writeAsStringSync('library shared;\n');
    File(
      p.join(sdkRoot.path, 'packages/flutter/pubspec.yaml'),
    ).writeAsStringSync('name: flutter\n');
    File(
      p.join(sdkRoot.path, 'packages/flutter/lib/flutter.dart'),
    ).writeAsStringSync('library flutter;\n');
    final packageConfig = File(
      p.join(projectRoot.path, '.dart_tool', 'package_config.json'),
    );
    packageConfig.parent.createSync(recursive: true);
    packageConfig.writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"l10n_snapshot_fixture","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"external_dep","rootUri":"../../external_dep/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"_fe_analyzer_shared","rootUri":"../../_fe_analyzer_shared/","packageUri":"lib/","languageVersion":"3.9"},
  {"name":"flutter","rootUri":"../../sdk/packages/flutter/","packageUri":"lib/","languageVersion":"3.9"}
],"generator":"pub","generatorVersion":"3.11.3","flutterRoot":${jsonEncode(Uri.file(sdkRoot.resolveSymbolicLinksSync()).toString())},"flutterVersion":"$selectedFrameworkVersion"}
''');

    final inferred = await ProjectContext.load(projectRoot);
    final project = ProjectContext(
      root: projectRoot,
      pubspec: inferred.pubspec,
      packageName: inferred.packageName,
      analysisMode: AnalysisMode.application,
      targetMatrix: TargetMatrix.declared([
        BuildTarget(
          name: 'app',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ]),
      rootCoverage: RootCoverage.applicationApi(),
    );
    final analysis = await ProjectAnalyzer(
      project: project,
      only: {'l10n'},
    ).analyze();
    final machineIdentity = FlutterMachineIdentity(
      frameworkVersion: selectedFrameworkVersion,
      frameworkRevision: '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
      engineRevision: 'fixture-engine-revision',
      dartSdkVersion: '3.11.3',
    );
    final toolchain = L10nToolchainResolved(
      canonicalFlutterExecutable: p.join(sdkRoot.path, 'bin/flutter'),
      canonicalSdkRoot: sdkRoot.resolveSymbolicLinksSync(),
      launch: L10nToolchainLaunch(
        canonicalDartExecutable: p.join(sdkRoot.path, 'bin/dart'),
        canonicalFlutterToolsPackageConfig: p.join(
          sdkRoot.path,
          'packages/flutter_tools/.dart_tool/package_config.json',
        ),
        canonicalFlutterToolsSnapshot: p.join(
          sdkRoot.path,
          'bin/cache/flutter_tools.snapshot',
        ),
      ),
      selection: RetainedEvidenceSelection(
        expectedIdentity: machineIdentity,
        evidenceSha256:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        probeOutputSha256:
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      ),
      generationArgs: const ['gen-l10n'],
      directProbeArgs: const ['--version', '--machine'],
      environmentOverrides: const {'CI': 'true'},
      selectorHashesByRelativePath: const {},
      machineIdentity: machineIdentity,
      originalSelectionProbeSha256:
          'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc',
      identitySha256:
          'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd',
    );
    final loaded = await const DefaultL10nGenerationConfigLoader().load(
      project: project,
      toolchain: machineIdentity,
    );
    if (loaded is! L10nGenerationConfigReady) {
      throw StateError('fixture strict config did not load');
    }
    final selectedNodeId = analysis.graph
        .nodesOfKind(NodeKind.localizationKey)
        .singleWhere((node) => node.metadata['key'] == 'dead')
        .id;
    return _Fixture._(
      container: container,
      projectRoot: projectRoot,
      externalRoot: externalRoot,
      project: project,
      analysis: analysis,
      config: loaded.config,
      toolchain: toolchain,
      selectedNodeId: selectedNodeId,
    );
  }

  Future<L10nFamilySnapshotResult> capture({
    AnalysisSnapshot? analysis,
    Iterable<String>? selectedNodeIds,
    L10nFamilyPreflight? preflight,
    L10nGenerationConfig? generationConfig,
  }) => (preflight ?? const L10nFamilyPreflight()).capture(
    analysis: analysis ?? this.analysis,
    selectedNodeIds: selectedNodeIds ?? [selectedNodeId],
    config: generationConfig ?? config,
    toolchain: toolchain,
  );

  Future<void> dispose() async {
    if (container.existsSync()) container.deleteSync(recursive: true);
  }
}

final class _FixedRerunner implements L10nAnalysisRerunner {
  const _FixedRerunner(this.snapshot);

  final AnalysisSnapshot snapshot;

  @override
  Future<AnalysisSnapshot> rerun(ProjectContext project) async => snapshot;
}

void _copyTree(Directory source, Directory destination) {
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final target = p.join(destination.path, relative);
    if (entity is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (entity is File) {
      File(target).parent.createSync(recursive: true);
      entity.copySync(target);
    }
  }
}

void _chmod(File file, int mode) {
  final result = Process.runSync('/bin/chmod', [
    mode.toRadixString(8),
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

void _expectFailure(
  L10nFamilySnapshotResult result,
  L10nEvidenceRejectionCode code,
  String? detailCode, {
  String? reason,
}) {
  expect(result, isA<L10nFamilySnapshotRejected>(), reason: reason);
  final failures = (result as L10nFamilySnapshotRejected).failures;
  expect(
    failures.map((failure) => failure.code),
    contains(code),
    reason: reason,
  );
  if (detailCode != null) {
    expect(
      failures.map((failure) => failure.detailCode),
      contains(detailCode),
      reason: reason,
    );
  }
}

String _describeResult(L10nFamilySnapshotResult result) => switch (result) {
  L10nFamilySnapshotReady() => 'ready',
  L10nFamilySnapshotRejected(:final failures) =>
    failures
        .map(
          (failure) =>
              '${failure.stage}/${failure.code.name}/${failure.detailCode}/'
              '${failure.relativePath ?? '-'}',
        )
        .join(', '),
};

AnalysisSnapshot _copyAnalysis(
  AnalysisSnapshot source, {
  ProjectContext? project,
  ReachabilityGraph? graph,
  List<Finding>? findings,
  List<AdapterRunReport>? adapterRuns,
}) {
  final selectedProject = project ?? source.project;
  final selectedGraph = graph ?? source.graph;
  return AnalysisSnapshot(
    project: selectedProject,
    graph: selectedGraph,
    graphIntegrity: selectedGraph.integrityFor(selectedProject.targets),
    findings: findings ?? source.findings,
    adapterIds: source.adapterIds,
    adapterRuns: adapterRuns ?? source.adapterRuns,
    elapsedMicros: source.elapsedMicros,
    findingElapsedMicros: source.findingElapsedMicros,
    exclusions: source.exclusions,
  );
}

ProjectContext _copyProject(
  ProjectContext source, {
  AnalysisMode? analysisMode,
  TargetMatrix? targetMatrix,
  RootCoverage? rootCoverage,
}) => ProjectContext(
  root: source.root,
  pubspec: source.pubspec,
  packageName: source.packageName,
  analysisMode: analysisMode ?? source.analysisMode,
  targetMatrix: targetMatrix ?? source.targetMatrix,
  rootCoverage: rootCoverage ?? source.rootCoverage,
  verificationPolicy: source.verificationPolicy,
  pathPolicy: source.pathPolicy,
);

GraphNode _copyNode(
  GraphNode source, {
  String? id,
  NodeKind? kind,
  Uri? origin,
  String? displayName,
  Map<String, Object?>? metadata,
}) => GraphNode(
  id: id ?? source.id,
  kind: kind ?? source.kind,
  origin: origin ?? source.origin,
  sizeBytes: source.sizeBytes,
  sha256: source.sha256,
  displayName: displayName ?? source.displayName,
  metadata: metadata ?? source.metadata,
);

Finding _copyFinding(
  Finding source, {
  GraphNode? node,
  String? ruleId,
  List<ClassificationReason>? classificationReasons,
  String? reportingAdapterId,
  bool overrideReportingAdapterId = false,
}) => Finding(
  ruleId: ruleId ?? source.ruleId,
  node: node ?? source.node,
  confidence: source.confidence,
  title: source.title,
  predicates: source.predicates,
  evidence: source.evidence,
  blockers: source.blockers,
  protectionReasons: source.protectionReasons,
  unreachableIn: source.unreachableIn,
  reachableIn: source.reachableIn,
  retainedIn: source.retainedIn,
  auxiliaryRetainedIn: source.auxiliaryRetainedIn,
  proposedAction: source.proposedAction,
  sourceBytes: source.sourceBytes,
  classificationReasons: classificationReasons ?? source.classificationReasons,
  manualRisks: source.manualRisks,
  reportingAdapterId: overrideReportingAdapterId
      ? reportingAdapterId
      : source.reportingAdapterId,
);
