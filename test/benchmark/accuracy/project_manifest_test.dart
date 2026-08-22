import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/project_manifest.dart';

void main() {
  group('AccuracyProjectManifest.fromJson', () {
    test('freezes the complete full and per-adapter artifact inventory', () {
      final manifest = AccuracyProjectManifest.fromJson(_acceptedManifest());

      expect(manifest.label, 'sample');
      expect(manifest.expectedCoverage.analysisMode, 'application');
      expect(manifest.expectedCoverage.targetMatrixStatus, 'declaredComplete');
      expect(manifest.expectedCoverage.rootMode, 'applicationEntrypoints');
      expect(manifest.targets.first.dartDefines, {'API': 'v1'});
      expect(
        manifest.scans['full']!.graphMembershipMode,
        ScannerGraphMembershipMode.exact,
      );
      expect(
        manifest.scans['adapter:duplicates']!.graphMembershipMode,
        ScannerGraphMembershipMode.notApplicable,
      );
      expect(manifest.scans['full']!.expectedGraphMembershipContextIds, [
        'app:ios',
        'app:web',
        'aux:test:widget',
      ]);
      expect(manifest.scans.keys, <String>[
        'full',
        ..._adapterIds.map((adapter) => 'adapter:$adapter'),
      ]);
    });

    test('accepts real-v3 package mode with a relative public API tuple', () {
      final json = _acceptedManifest();
      final coverage = json['expectedCoverage'] as Map<String, Object?>;
      coverage
        ..['analysisMode'] = 'package'
        ..['rootMode'] = 'packagePublicApi'
        ..['publicEntrypoints'] = <Object?>['lib/api.dart'];
      expect(AccuracyProjectManifest.fromJson(json).label, 'sample');
    });

    test('rejects every required identity and coverage field when omitted', () {
      final requiredTopLevel = <String>[
        'manifestSchemaVersion',
        'label',
        'projectRoot',
        'projectGitSha',
        'packageRoot',
        'flutterVersion',
        'dartVersion',
        'toolSha',
        'configSha256',
        'packageConfigSha256',
        'lockfileSha256',
        'toolPackageConfigSha256',
        'toolLockfileSha256',
        'originalManagedFingerprint',
        'worktreeManagedFingerprint',
        'rootPolicyVersion',
        'candidateBoundaryPolicyVersion',
        'findingContractPolicyVersion',
        'manifestValidationMode',
        'redactionRoots',
        'expectedCoverage',
        'targets',
        'oracleAuxiliaryExecutionTargets',
        'scans',
      ];

      for (final key in requiredTopLevel) {
        final json = _acceptedManifest()..remove(key);
        expect(
          () => AccuracyProjectManifest.fromJson(json),
          throwsFormatException,
          reason: 'missing $key must not be inferred',
        );
      }

      final coverageFields = <String>[
        'analysisMode',
        'auxiliaryExecutionTargetIssuesPresent',
        'auxiliaryExecutionTargetIssues',
        'targetMatrixStatus',
        'targetMatrixComplete',
        'targetMatrixSource',
        'targetMatrixIssues',
        'rootMode',
        'rootCoverageComplete',
        'internalBoundaryComplete',
        'externalConsumersCovered',
        'rootSource',
        'publicEntrypoints',
        'rootIssues',
      ];
      for (final key in coverageFields) {
        final json = _acceptedManifest();
        (json['expectedCoverage'] as Map<String, Object?>).remove(key);
        expect(
          () => AccuracyProjectManifest.fromJson(json),
          throwsFormatException,
          reason: 'coverage must explicitly include $key',
        );
      }
    });

    test(
      'rejects unknown versions, modes, domains, relative roots and shell argv',
      () {
        final cases = <Map<String, Object?>>[
          _with('manifestSchemaVersion', 99),
          _with('rootPolicyVersion', 99),
          _with('candidateBoundaryPolicyVersion', 99),
          _with('findingContractPolicyVersion', 99),
          _withPath('projectRoot', 'relative/project'),
          _withCoverage('analysisMode', 'guess'),
          _withCoverage('targetMatrixStatus', 'complete'),
          _withCoverage('rootMode', 'guess'),
          _withAuxiliary('domain', 'guess'),
          _withScan('scannerArgv', <Object?>['scan --format json']),
          _withGraph('schemaVersion', 99),
          _withScan('jsonSchemaVersion', 99),
        ];

        for (final json in cases) {
          expect(
            () => AccuracyProjectManifest.fromJson(json),
            throwsFormatException,
          );
        }
      },
    );

    test('rejects missing graph observation identities and report data', () {
      const keys = <String>[
        'rawObservationPath',
        'rawObservationSha256',
        'observationReportPath',
        'observationReportSha256',
        'captureArgv',
        'captureArgvSha256',
        'schemaVersion',
      ];
      for (final key in keys) {
        final json = _acceptedManifest();
        final graph =
            ((json['scans'] as Map<String, Object?>)['full']
                    as Map<String, Object?>)['graphObservation']
                as Map<String, Object?>;
        graph.remove(key);
        expect(
          () => AccuracyProjectManifest.fromJson(json),
          throwsFormatException,
          reason: 'graph observation must retain $key',
        );
      }
    });

    test('rejects duplicate target and auxiliary identities', () {
      final duplicateTarget = _acceptedManifest();
      (duplicateTarget['targets'] as List<Object?>).add(
        _target(name: 'app:ios', platform: 'android'),
      );
      expect(
        () => AccuracyProjectManifest.fromJson(duplicateTarget),
        throwsFormatException,
      );

      final duplicateAuxiliary = _acceptedManifest();
      (duplicateAuxiliary['oracleAuxiliaryExecutionTargets'] as List<Object?>)
          .add(_auxiliary());
      expect(
        () => AccuracyProjectManifest.fromJson(duplicateAuxiliary),
        throwsFormatException,
      );
    });

    test('validates and projects canonical execution contexts immediately', () {
      final canonical = _acceptedManifest();
      ((canonical['targets'] as List<Object?>).first
              as Map<String, Object?>)['name'] =
          'ios';
      _useCanonicalEvaluationContextIds(canonical);
      final manifest = AccuracyProjectManifest.fromJson(canonical);
      expect(manifest.targets.first.executionContextId, 'app:ios');
      expect(
        manifest.oracleAuxiliaryExecutionTargets.single.executionContextId,
        'aux:test:widget',
      );
      expect(manifest.scans['full']!.expectedGraphMembershipContextIds, [
        'app:ios',
        'app:web',
        'aux:test:widget',
      ]);

      for (final invalidName in ['', 'app:', 'app:bad\nname']) {
        final invalid = _acceptedManifest();
        ((invalid['targets'] as List<Object?>).first
                as Map<String, Object?>)['name'] =
            invalidName;
        expect(
          () => AccuracyProjectManifest.fromJson(invalid),
          invalidName.isEmpty
              ? throwsFormatException
              : throwsA(
                  isA<FormatException>().having(
                    (error) => error.message,
                    'message',
                    contains('canonical configured execution context'),
                  ),
                ),
          reason: invalidName,
        );
      }

      final configuredTupleAuxiliary = _acceptedManifest();
      ((configuredTupleAuxiliary['oracleAuxiliaryExecutionTargets']
                      as List<Object?>)
                  .single
              as Map<String, Object?>)['id'] =
          'test:app:ios';
      expect(
        () => AccuracyProjectManifest.fromJson(configuredTupleAuxiliary),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('canonical auxiliary execution context'),
          ),
        ),
      );

      final mismatchedDomain = _acceptedManifest();
      ((mismatchedDomain['oracleAuxiliaryExecutionTargets'] as List<Object?>)
                  .single
              as Map<String, Object?>)['domain'] =
          'runtime';
      expect(
        () => AccuracyProjectManifest.fromJson(mismatchedDomain),
        throwsFormatException,
      );
    });

    test('enforces per-scan auxiliary and graph membership contracts', () {
      final unknownScanAux = _acceptedManifest();
      final full =
          (unknownScanAux['scans'] as Map<String, Object?>)['full']
              as Map<String, Object?>;
      (full['expectedAuxiliaryExecutionTargets'] as List<Object?>)[0] =
          _auxiliary(id: 'runtime:missing');
      expect(
        () => AccuracyProjectManifest.fromJson(unknownScanAux),
        throwsFormatException,
      );

      final badExactMembership = _acceptedManifest();
      final contextIds =
          ((badExactMembership['scans'] as Map<String, Object?>)['full']
                  as Map<String, Object?>)['expectedGraphMembershipContextIds']
              as List<Object?>;
      contextIds.removeLast();
      expect(
        () => AccuracyProjectManifest.fromJson(badExactMembership),
        throwsFormatException,
      );

      final badDuplicateRegistry = _acceptedManifest();
      final duplicates =
          (badDuplicateRegistry['scans']
                  as Map<String, Object?>)['adapter:duplicates']
              as Map<String, Object?>;
      duplicates['expectedAuxiliaryExecutionTargets'] = <Object?>[_auxiliary()];
      expect(
        () => AccuracyProjectManifest.fromJson(badDuplicateRegistry),
        throwsFormatException,
      );

      final badNotApplicable = _acceptedManifest();
      final isolated =
          (badNotApplicable['scans']
                  as Map<String, Object?>)['adapter:duplicates']
              as Map<String, Object?>;
      isolated['requestedAdapters'] = <Object?>['dart'];
      expect(
        () => AccuracyProjectManifest.fromJson(badNotApplicable),
        throwsFormatException,
      );
    });

    test('requires both full and isolated artifacts', () {
      final noFull = _acceptedManifest();
      (noFull['scans'] as Map<String, Object?>).remove('full');
      expect(
        () => AccuracyProjectManifest.fromJson(noFull),
        throwsFormatException,
      );

      final noIsolated = _acceptedManifest();
      (noIsolated['scans'] as Map<String, Object?>).remove('adapter:dart');
      expect(
        () => AccuracyProjectManifest.fromJson(noIsolated),
        throwsFormatException,
      );
    });

    test('rejects incomplete, extra, swapped, or unsorted scan inventory', () {
      final missingAdapter = _acceptedManifest();
      (missingAdapter['scans'] as Map<String, Object?>).remove('adapter:l10n');
      expect(
        () => AccuracyProjectManifest.fromJson(missingAdapter),
        throwsFormatException,
      );

      final extraAdapter = _acceptedManifest();
      (extraAdapter['scans']
          as Map<String, Object?>)['adapter:unknown'] = _scan(
        scanKey: 'adapter:unknown',
        requestedAdapters: <Object?>['unknown'],
        auxiliaries: <Object?>[_auxiliary()],
        graphMembershipMode: 'exact',
        contextIds: <Object?>['app:ios', 'app:web', 'aux:test:widget'],
      );
      expect(
        () => AccuracyProjectManifest.fromJson(extraAdapter),
        throwsFormatException,
      );

      final swapped = _acceptedManifest();
      final scans = swapped['scans'] as Map<String, Object?>;
      scans['adapter:duplicates'] = scans['full']!;
      expect(
        () => AccuracyProjectManifest.fromJson(swapped),
        throwsFormatException,
      );

      final unsorted = _acceptedManifest();
      ((unsorted['scans'] as Map<String, Object?>)['full']
          as Map<String, Object?>)['requestedAdapters'] = <Object?>[
        'dart',
        'assets',
        'duplicates',
        'get_it',
        'go_router',
        'l10n',
      ];
      expect(
        () => AccuracyProjectManifest.fromJson(unsorted),
        throwsFormatException,
      );
    });

    test(
      'binds scan keys to hashes, structural argv, and unique artifacts',
      () {
        final dummyHash = _acceptedManifest();
        ((dummyHash['scans'] as Map<String, Object?>)['full']
            as Map<String, Object?>)['scannerArgvSha256'] = _sha(
          '0',
        );
        expect(
          () => AccuracyProjectManifest.fromJson(dummyHash),
          throwsFormatException,
        );

        final missingSelector = _acceptedManifest();
        final dart =
            (missingSelector['scans'] as Map<String, Object?>)['adapter:dart']
                as Map<String, Object?>;
        dart['scannerArgv'] = <Object?>[
          '/tool/bin/flutter_pruner',
          'scan',
          '/project/pkg',
        ];
        dart['scannerArgvSha256'] = _argvSha(
          dart['scannerArgv'] as List<Object?>,
        );
        expect(
          () => AccuracyProjectManifest.fromJson(missingSelector),
          throwsFormatException,
        );

        final duplicateOutput = _acceptedManifest();
        final duplicateOutputScan =
            (duplicateOutput['scans'] as Map<String, Object?>)['full']
                as Map<String, Object?>;
        (duplicateOutputScan['scannerArgv'] as List<Object?>).addAll(<Object?>[
          '--output',
          '/result/another.json',
        ]);
        duplicateOutputScan['scannerArgvSha256'] = _argvSha(
          duplicateOutputScan['scannerArgv'] as List<Object?>,
        );
        expect(
          () => AccuracyProjectManifest.fromJson(duplicateOutput),
          throwsFormatException,
        );

        final reused = _acceptedManifest();
        final scans = reused['scans'] as Map<String, Object?>;
        final duplicate = scans['adapter:assets'] as Map<String, Object?>;
        duplicate['rawReportPath'] =
            (scans['full'] as Map<String, Object?>)['rawReportPath'];
        expect(
          () => AccuracyProjectManifest.fromJson(reused),
          throwsFormatException,
        );

        final lexicalAlias = _acceptedManifest();
        ((lexicalAlias['scans'] as Map<String, Object?>)['adapter:assets']
                as Map<String, Object?>)['rawReportPath'] =
            '/result/./full.scan.json';
        expect(
          () => AccuracyProjectManifest.fromJson(lexicalAlias),
          throwsFormatException,
        );

        final shell = _acceptedManifest();
        final full =
            (shell['scans'] as Map<String, Object?>)['full']
                as Map<String, Object?>;
        full['scannerArgv'] = <Object?>['sh', '-c', 'scan /project/pkg'];
        full['scannerArgvSha256'] = _argvSha(
          full['scannerArgv'] as List<Object?>,
        );
        expect(
          () => AccuracyProjectManifest.fromJson(shell),
          throwsFormatException,
        );

        final spaces = _acceptedManifest();
        _replacePathValues(spaces, '/project', '/project/A & B');
        _refreshArgvHashes(spaces);
        expect(AccuracyProjectManifest.fromJson(spaces).label, 'sample');

        final swappedCommands = _acceptedManifest();
        final fullScan =
            (swappedCommands['scans'] as Map<String, Object?>)['full']
                as Map<String, Object?>;
        final graph = fullScan['graphObservation'] as Map<String, Object?>;
        fullScan['scannerArgv'] = graph['captureArgv'];
        fullScan['scannerArgvSha256'] = _argvSha(
          fullScan['scannerArgv'] as List<Object?>,
        );
        expect(
          () => AccuracyProjectManifest.fromJson(swappedCommands),
          throwsFormatException,
        );
      },
    );

    test('rejects each independent capture command shape violation', () {
      const requiredOptions = <String>[
        '--project',
        '--config',
        '--json-version',
        '--report-output',
        '--observation-output',
      ];
      for (final option in requiredOptions) {
        final json = _acceptedManifest();
        final capture = _captureArgvFrom(json, 'full');
        _removeOption(capture, option);
        _refreshArgvHashes(json);
        expect(
          () => AccuracyProjectManifest.fromJson(json),
          throwsFormatException,
          reason: 'missing $option',
        );
      }

      final duplicate = _acceptedManifest();
      final duplicateCapture = _captureArgvFrom(duplicate, 'full');
      duplicateCapture.addAll(<Object?>[
        '--report-output',
        '/result/other.json',
      ]);
      _refreshArgvHashes(duplicate);
      expect(
        () => AccuracyProjectManifest.fromJson(duplicate),
        throwsFormatException,
      );

      final unrelated = _acceptedManifest();
      _captureArgvFrom(unrelated, 'full')[2] = '/tool/bin/unrelated.dart';
      _refreshArgvHashes(unrelated);
      expect(
        () => AccuracyProjectManifest.fromJson(unrelated),
        throwsFormatException,
      );

      final swapped = _acceptedManifest();
      final scan =
          (swapped['scans'] as Map<String, Object?>)['full']
              as Map<String, Object?>;
      final graph = scan['graphObservation'] as Map<String, Object?>;
      graph['captureArgv'] = scan['scannerArgv'];
      _refreshArgvHashes(swapped);
      expect(
        () => AccuracyProjectManifest.fromJson(swapped),
        throwsFormatException,
      );

      final selectorCases = <void Function(List<Object?>)>[
        (argv) => _removeOption(argv, '--adapter'),
        (argv) => argv[argv.indexOf('--adapter') + 1] = 'assets',
        (argv) => argv.addAll(<Object?>['--adapter', 'dart']),
      ];
      for (final mutate in selectorCases) {
        final json = _acceptedManifest();
        mutate(_captureArgvFrom(json, 'adapter:dart'));
        _refreshArgvHashes(json);
        expect(
          () => AccuracyProjectManifest.fromJson(json),
          throwsFormatException,
        );
      }
    });

    test(
      'rejects unknown nested fields and noncanonical target/auxiliary tuples',
      () {
        final unknownField = _acceptedManifest();
        (unknownField['expectedCoverage'] as Map<String, Object?>)['invented'] =
            true;
        expect(
          () => AccuracyProjectManifest.fromJson(unknownField),
          throwsFormatException,
        );

        final unsortedTargets = _acceptedManifest();
        final targets = unsortedTargets['targets'] as List<Object?>;
        targets.setAll(0, targets.reversed.toList());
        expect(
          () => AccuracyProjectManifest.fromJson(unsortedTargets),
          throwsFormatException,
        );

        final mismatchedDomain = _acceptedManifest();
        ((mismatchedDomain['oracleAuxiliaryExecutionTargets'] as List<Object?>)
                    .single
                as Map<String, Object?>)['id'] =
            'runtime:widget';
        expect(
          () => AccuracyProjectManifest.fromJson(mismatchedDomain),
          throwsFormatException,
        );

        final unknownSourceTarget = _acceptedManifest();
        ((unknownSourceTarget['oracleAuxiliaryExecutionTargets']
                    as List<Object?>)
                .single
            as Map<String, Object?>)['sourceConfiguredTarget'] = _target(
          name: 'app:missing',
          platform: 'ios',
        );
        expect(
          () => AccuracyProjectManifest.fromJson(unknownSourceTarget),
          throwsFormatException,
        );

        final inconsistentCoverage = _acceptedManifest();
        (inconsistentCoverage['expectedCoverage']
                as Map<String, Object?>)['targetMatrixComplete'] =
            false;
        expect(
          () => AccuracyProjectManifest.fromJson(inconsistentCoverage),
          throwsFormatException,
        );

        final incompatibleRoot = _acceptedManifest();
        (incompatibleRoot['expectedCoverage']
                as Map<String, Object?>)['rootMode'] =
            'packagePublicApi';
        expect(
          () => AccuracyProjectManifest.fromJson(incompatibleRoot),
          throwsFormatException,
        );

        final absoluteEntrypoint = _acceptedManifest();
        ((absoluteEntrypoint['targets'] as List<Object?>).first
                as Map<String, Object?>)['entrypoint'] =
            '/project/lib/main.dart';
        expect(
          () => AccuracyProjectManifest.fromJson(absoluteEntrypoint),
          throwsFormatException,
        );

        final escapingEntrypoint = _acceptedManifest();
        ((escapingEntrypoint['targets'] as List<Object?>).first
                as Map<String, Object?>)['entrypoint'] =
            '../main.dart';
        expect(
          () => AccuracyProjectManifest.fromJson(escapingEntrypoint),
          throwsFormatException,
        );

        final applicationPublicApi = _acceptedManifest();
        (applicationPublicApi['expectedCoverage']
            as Map<String, Object?>)['publicEntrypoints'] = <Object?>[
          'lib/api.dart',
        ];
        expect(
          () => AccuracyProjectManifest.fromJson(applicationPublicApi),
          throwsFormatException,
        );

        final packageWithoutApi = _acceptedManifest();
        final packageCoverage =
            packageWithoutApi['expectedCoverage'] as Map<String, Object?>;
        packageCoverage
          ..['analysisMode'] = 'package'
          ..['rootMode'] = 'packagePublicApi';
        expect(
          () => AccuracyProjectManifest.fromJson(packageWithoutApi),
          throwsFormatException,
        );
      },
    );

    test('accepted mode rejects allowance and incomplete coverage', () {
      final withAllowance = _acceptedManifest()
        ..['analysisHealthAllowance'] = _allowance();
      expect(
        () => AccuracyProjectManifest.fromJson(withAllowance),
        throwsFormatException,
      );

      final missingRegistryField = _acceptedManifest();
      (missingRegistryField['expectedCoverage']
              as Map<
                String,
                Object?
              >)['auxiliaryExecutionTargetIssuesPresent'] =
          false;
      expect(
        () => AccuracyProjectManifest.fromJson(missingRegistryField),
        throwsFormatException,
      );

      final nonEmptyIssues = _acceptedManifest();
      (nonEmptyIssues['expectedCoverage']
          as Map<String, Object?>)['rootIssues'] = <Object?>[
        '/project/unproven.dart',
      ];
      expect(
        () => AccuracyProjectManifest.fromJson(nonEmptyIssues),
        throwsFormatException,
      );
    });

    test(
      'capture-only exact allowance rejects integrity drift and accepts legacy map absence',
      () {
        final capture = _acceptedManifest();
        capture['manifestValidationMode'] = 'capture-only';
        capture['expectedCoverage'] = _captureCoverage();
        capture['analysisHealthAllowance'] = _allowance();
        expect(
          AccuracyProjectManifest.fromJson(capture).analysisHealthAllowance,
          isNotNull,
        );

        final legacyAbsent = _captureManifest();
        final legacyAllowance =
            legacyAbsent['analysisHealthAllowance'] as Map<String, Object?>;
        (legacyAllowance['danglingCountsByPassAndExecutionTargetId']
                as Map<String, Object?>)
            .remove('adapter:l10n|analysis-001');
        (legacyAllowance['passIdsWithIntegrityMapAbsent'] as List<Object?>).add(
          'adapter:l10n|analysis-001',
        );
        expect(
          AccuracyProjectManifest.fromJson(
            legacyAbsent,
          ).analysisHealthAllowance,
          isNotNull,
        );

        final drift = _acceptedManifest();
        drift['manifestValidationMode'] = 'capture-only';
        drift['expectedCoverage'] = _captureCoverage();
        final allowance = _allowance();
        (allowance['danglingCountsByPassId']
            as Map<String, Object?>)['full|analysis-001'] = <String, Object?>{
          'edges': 9,
          'roots': 0,
        };
        drift['analysisHealthAllowance'] = allowance;
        expect(
          () => AccuracyProjectManifest.fromJson(drift),
          throwsFormatException,
        );
      },
    );

    test(
      'rejects allowance buckets outside the closed scan/pass vocabulary',
      () {
        final invalidDiagnostic = _captureManifest();
        ((invalidDiagnostic['analysisHealthAllowance']
                    as Map<String, Object?>)['diagnosticCountsByCodePhase']
                as Map<String, Object?>)['full|unknown|analysis'] =
            0;
        expect(
          () => AccuracyProjectManifest.fromJson(invalidDiagnostic),
          throwsFormatException,
        );

        final invalidPass = _captureManifest();
        final allowance =
            invalidPass['analysisHealthAllowance'] as Map<String, Object?>;
        final aggregate =
            allowance['danglingCountsByPassId'] as Map<String, Object?>;
        aggregate
          ..remove('adapter:l10n|analysis-001')
          ..['adapter:l10n|unknown-pass'] = <String, Object?>{
            'edges': 0,
            'roots': 0,
          };
        expect(
          () => AccuracyProjectManifest.fromJson(invalidPass),
          throwsFormatException,
        );

        final missingDiagnostic = _captureManifest();
        ((missingDiagnostic['analysisHealthAllowance']
                    as Map<String, Object?>)['diagnosticCountsByCodePhase']
                as Map<String, Object?>)
            .remove('adapter:l10n|package-internal-boundary|analysis');
        expect(
          () => AccuracyProjectManifest.fromJson(missingDiagnostic),
          throwsFormatException,
        );

        final emptyDiagnostics = _captureManifest();
        ((emptyDiagnostics['analysisHealthAllowance']
                    as Map<String, Object?>)['diagnosticCountsByCodePhase']
                as Map<String, Object?>)
            .clear();
        expect(
          () => AccuracyProjectManifest.fromJson(emptyDiagnostics),
          throwsFormatException,
        );
      },
    );

    test(
      'deep freezes targets, environments, registries, scans and health maps',
      () {
        final manifest = AccuracyProjectManifest.fromJson(_captureManifest());

        expect(
          () => manifest.targets.first.dartDefines['X'] = 'y',
          throwsUnsupportedError,
        );
        expect(
          () =>
              manifest
                      .oracleAuxiliaryExecutionTargets
                      .single
                      .environmentValues['X'] =
                  'y',
          throwsUnsupportedError,
        );
        expect(
          () => manifest.scans['x'] = manifest.scans['full']!,
          throwsUnsupportedError,
        );
        expect(
          () => manifest.scans['full']!.expectedGraphMembershipContextIds.add(
            'bad',
          ),
          throwsUnsupportedError,
        );
        expect(
          () =>
              manifest
                      .analysisHealthAllowance!
                      .diagnosticCountsByCodePhase['x'] =
                  0,
          throwsUnsupportedError,
        );
        expect(
          () =>
              manifest.redactionRoots['project'].aliases.add('/other-project'),
          throwsUnsupportedError,
        );
      },
    );
  });

  group('AccuracyProjectManifest.toRedactedJson', () {
    test(
      'keeps identities while redacting known roots, argv and issue text',
      () {
        final json = _acceptedManifest();
        final coverage = json['expectedCoverage'] as Map<String, Object?>;
        json['manifestValidationMode'] = 'capture-only';
        coverage['targetMatrixIssues'] = <Object?>[
          r'C:\alias\project\lib\broken.dart',
          r'\\server\share\tool\logs\tool.txt',
        ];
        coverage['rootIssues'] = <Object?>[
          'file:///result/raw.json',
          '/worktree/cache/missing.dart',
          '--output=/private/unmapped/report.json',
          r'failed:path=C:\private\mixed\report.json',
          'file:/private/unknown.json',
        ];
        final redacted = AccuracyProjectManifest.fromJson(
          json,
        ).toRedactedJson();
        final rendered = jsonEncode(redacted);

        expect(redacted['label'], 'sample');
        expect(redacted['projectGitSha'], _sha('a'));
        expect(redacted['targets'], isNotEmpty);
        expect(rendered, contains(r'$PROJECT/lib/broken.dart'));
        expect(rendered, contains(r'$TOOL/logs/tool.txt'));
        expect(rendered, contains(r'$RESULT/raw.json'));
        expect(rendered, isNot(contains('/project/')));
        expect(rendered, isNot(contains(r'C:\alias')));
        expect(rendered, isNot(contains('file:///')));
        expect(rendered, isNot(contains('/worktree/')));
        expect(rendered, isNot(contains('/private/')));
        expect(rendered, isNot(contains(r'C:\private')));
        expect(rendered, contains('scannerArgvTemplate'));
        expect(rendered, isNot(contains('scannerArgv":[')));
      },
    );

    test('hashes unknown path-valued sources and unprovable issue text', () {
      final json = _acceptedManifest();
      json['manifestValidationMode'] = 'capture-only';
      final full =
          (json['scans'] as Map<String, Object?>)['full']
              as Map<String, Object?>;
      full['rawReportPath'] = '/unknown/raw.json';
      final scannerArgv = full['scannerArgv'] as List<Object?>;
      scannerArgv[scannerArgv.indexOf('--output') + 1] = '/unknown/raw.json';
      full['scannerArgvSha256'] = _argvSha(scannerArgv);
      (json['expectedCoverage'] as Map<String, Object?>)['rootIssues'] =
          <Object?>['failed at \\host\\private\\a.dart'];

      final redacted = AccuracyProjectManifest.fromJson(json).toRedactedJson();
      final scan =
          (redacted['scans'] as Map<String, Object?>)['full']
              as Map<String, Object?>;
      expect(scan['rawReportPath'], isA<Map<String, Object?>>());
      expect(jsonEncode(redacted), isNot(contains('/unknown/raw.json')));
      expect(jsonEncode(redacted), isNot(contains(r'\\host')));
    });

    test('hashes each embedded absolute-path form independently', () {
      const issues = <String>[
        '--output=/private/report.json',
        'failed:path=/private/source.dart',
        'file:/private/source.dart',
        'item[/private/source.dart]',
        r'windows=C:\\private\\source.dart',
        r'unc=\\\\server\\private\\source.dart',
      ];
      for (final issue in issues) {
        final json = _acceptedManifest();
        json['manifestValidationMode'] = 'capture-only';
        (json['expectedCoverage'] as Map<String, Object?>)['rootIssues'] =
            <Object?>[issue];
        final rendered = jsonEncode(
          AccuracyProjectManifest.fromJson(json).toRedactedJson(),
        );
        expect(rendered, isNot(contains('/private/')), reason: issue);
        expect(rendered, isNot(contains(r'C:\\private')), reason: issue);
        expect(rendered, isNot(contains(r'\\\\server')), reason: issue);
      }
    });

    test('retains well-formed HTTP and HTTPS tuple values', () {
      final json = _acceptedManifest();
      for (final target in json['targets'] as List<Object?>) {
        (target as Map<String, Object?>)['dartDefines'] = <String, Object?>{
          'HTTP_ENDPOINT': 'http://example.test/api',
          'HTTPS_ENDPOINT': 'https://example.test/api',
        };
      }
      final auxiliary =
          (json['oracleAuxiliaryExecutionTargets'] as List<Object?>).single
              as Map<String, Object?>;
      auxiliary['environmentValues'] = <String, Object?>{
        'HTTP_ENDPOINT': 'http://example.test/api',
        'HTTPS_ENDPOINT': 'https://example.test/api',
      };
      for (final scan in (json['scans'] as Map<String, Object?>).values) {
        final registries =
            (scan as Map<String, Object?>)['expectedAuxiliaryExecutionTargets']
                as List<Object?>;
        if (registries.isNotEmpty) {
          (registries.single
              as Map<String, Object?>)['environmentValues'] = <String, Object?>{
            'HTTP_ENDPOINT': 'http://example.test/api',
            'HTTPS_ENDPOINT': 'https://example.test/api',
          };
        }
      }

      final redacted = AccuracyProjectManifest.fromJson(json).toRedactedJson();
      final redactedAuxiliary =
          (redacted['oracleAuxiliaryExecutionTargets'] as List<Object?>).single
              as Map<String, Object?>;
      for (final target in redacted['targets'] as List<Object?>) {
        expect(
          (target as Map<String, Object?>)['dartDefines'],
          <String, String>{
            'HTTP_ENDPOINT': 'http://example.test/api',
            'HTTPS_ENDPOINT': 'https://example.test/api',
          },
        );
      }
      expect(redactedAuxiliary['environmentValues'], <String, String>{
        'HTTP_ENDPOINT': 'http://example.test/api',
        'HTTPS_ENDPOINT': 'https://example.test/api',
      });
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{
            'mixed': 'https://example.test/api /private/leak.dart',
          },
        ),
        throwsStateError,
      );
    });

    test('accepts a complete bracketed IPv6 HTTP URI span', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{'ipv6': 'https://[::1]/api'},
        ),
        returnsNormally,
      );
    });

    test('accepts a complete user-info query and path HTTP URI span', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(<
          String,
          Object?
        >{
          'ordinary':
              'https://user:pass@example.test:8443/api/v1?lang=vi&next=%2Fdocs#overview',
        }),
        returnsNormally,
      );
    });

    test('honors trailing punctuation after a complete URI span', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{'punctuated': '(https://example.test/api).'},
        ),
        returnsNormally,
      );
    });

    test('does not let a valid URI mask an adjacent real path', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{
            'adjacent': 'https://example.test/api | /private/leak.dart',
          },
        ),
        throwsStateError,
      );
    });

    test('does not exempt an HTTP candidate with a malformed port', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{
            'value': 'https://example.test:bad/private/leak.dart',
          },
        ),
        throwsStateError,
      );
    });

    test('does not exempt an HTTP scheme attached to a path token prefix', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{
            'value': 'prefixhttps://example.test/private/leak.dart',
          },
        ),
        throwsStateError,
      );
    });

    test('rejects a redacted payload containing any absolute-path leakage', () {
      expect(
        () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
          <String, Object?>{
            'posix': '/leak/file.dart',
            'windows': r'C:\leak\file.dart',
            'unc': r'\\host\share\file.dart',
            'uri': 'file:///leak/file.dart',
            '--output=/private/leak.json': 'harmless',
            'nested': <Object?>['failed:path=/private/leak.json'],
          },
        ),
        throwsStateError,
      );
    });

    test(
      'rejects every non-path-token delimiter and permits relative paths',
      () {
        const delimiters = <String>['{', '|', '>', '[', ',', ';', '=', ':'];
        for (final delimiter in delimiters) {
          expect(
            () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
              <String, Object?>{'issue': '$delimiter/private/file.dart'},
            ),
            throwsStateError,
            reason: 'value delimiter $delimiter',
          );
          expect(
            () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
              <String, Object?>{'$delimiter/private/file.dart': 'value'},
            ),
            throwsStateError,
            reason: 'key delimiter $delimiter',
          );
        }
        expect(
          () => AccuracyProjectManifest.assertRedactedJsonPathSafe(
            <String, Object?>{
              'relative': 'lib/src/file.dart',
              'package': 'package:foo/bar.dart',
            },
          ),
          returnsNormally,
        );
      },
    );
  });
}

Map<String, Object?> _acceptedManifest() => <String, Object?>{
  'manifestSchemaVersion': 1,
  'label': 'sample',
  'projectRoot': '/project',
  'projectGitSha': _sha('a'),
  'packageRoot': '/project/pkg',
  'flutterVersion': '3.47.0',
  'dartVersion': '3.13.0',
  'toolSha': _sha('b'),
  'configSha256': _sha('c'),
  'packageConfigSha256': _sha('d'),
  'lockfileSha256': _sha('e'),
  'toolPackageConfigSha256': _sha('f'),
  'toolLockfileSha256': _sha('0'),
  'originalManagedFingerprint': _sha('1'),
  'worktreeManagedFingerprint': _sha('2'),
  'rootPolicyVersion': 2,
  'candidateBoundaryPolicyVersion': 1,
  'findingContractPolicyVersion': 1,
  'manifestValidationMode': 'accepted',
  'redactionRoots': <String, Object?>{
    'project': <String, Object?>{
      'canonicalPath': '/project',
      'aliases': <Object?>[r'C:\alias\project'],
    },
    'worktree': <String, Object?>{
      'canonicalPath': '/worktree',
      'aliases': <Object?>[],
    },
    'tool': <String, Object?>{
      'canonicalPath': '/tool',
      'aliases': <Object?>[r'\\server\share\tool'],
    },
    'result': <String, Object?>{
      'canonicalPath': '/result',
      'aliases': <Object?>[],
    },
  },
  'expectedCoverage': _acceptedCoverage(),
  'targets': <Object?>[
    _target(name: 'app:ios', platform: 'ios'),
    _target(name: 'app:web', platform: 'web'),
  ],
  'oracleAuxiliaryExecutionTargets': <Object?>[_auxiliary()],
  'scans': <String, Object?>{
    'full': _scan(
      scanKey: 'full',
      requestedAdapters: List<Object?>.from(_adapterIds),
      auxiliaries: <Object?>[_auxiliary()],
      graphMembershipMode: 'exact',
      contextIds: <Object?>['app:ios', 'app:web', 'aux:test:widget'],
    ),
    for (final adapter in _adapterIds)
      'adapter:$adapter': _scan(
        scanKey: 'adapter:$adapter',
        requestedAdapters: <Object?>[adapter],
        auxiliaries: adapter == 'duplicates'
            ? <Object?>[]
            : <Object?>[_auxiliary()],
        graphMembershipMode: adapter == 'duplicates'
            ? 'notApplicable'
            : 'exact',
        contextIds: adapter == 'duplicates'
            ? <Object?>[]
            : <Object?>['app:ios', 'app:web', 'aux:test:widget'],
      ),
  },
};

Map<String, Object?> _captureManifest() {
  final json = _acceptedManifest();
  json['manifestValidationMode'] = 'capture-only';
  json['expectedCoverage'] = _captureCoverage();
  json['analysisHealthAllowance'] = _allowance();
  return json;
}

void _useCanonicalEvaluationContextIds(Map<String, Object?> json) {
  final scans = json['scans'] as Map<String, Object?>;
  for (final scan in scans.values.cast<Map<String, Object?>>()) {
    final contexts = scan['expectedGraphMembershipContextIds'] as List<Object?>;
    for (var index = 0; index < contexts.length; index += 1) {
      if (contexts[index] == 'test:widget') {
        contexts[index] = 'aux:test:widget';
      }
    }
  }
  final allowance = json['analysisHealthAllowance'];
  if (allowance is! Map<String, Object?>) return;
  final byPass =
      allowance['danglingCountsByPassAndExecutionTargetId']
          as Map<String, Object?>;
  for (final counts in byPass.values.cast<Map<String, Object?>>()) {
    final testCounts = counts.remove('test:widget');
    if (testCounts != null) counts['aux:test:widget'] = testCounts;
  }
}

Map<String, Object?> _acceptedCoverage() => <String, Object?>{
  'analysisMode': 'application',
  'auxiliaryExecutionTargetIssuesPresent': true,
  'auxiliaryExecutionTargetIssues': <Object?>[],
  'targetMatrixStatus': 'declaredComplete',
  'targetMatrixComplete': true,
  'targetMatrixSource': '/project/tool/targets.json',
  'targetMatrixIssues': <Object?>[],
  'rootMode': 'applicationEntrypoints',
  'rootCoverageComplete': true,
  'internalBoundaryComplete': true,
  'externalConsumersCovered': true,
  'rootSource': '/project/tool/targets.json',
  'publicEntrypoints': <Object?>[],
  'rootIssues': <Object?>[],
};

Map<String, Object?> _captureCoverage() => <String, Object?>{
  ..._acceptedCoverage(),
  'analysisMode': 'application',
  'auxiliaryExecutionTargetIssuesPresent': false,
  'auxiliaryExecutionTargetIssues': <Object?>[
    <String, Object?>{
      'id': 'legacy:missing',
      'acceptedDefinitionSha256': _sha('3'),
      'rejectedDefinitionSha256': _sha('4'),
      'reason': 'legacy capture only',
    },
  ],
  'targetMatrixStatus': 'declaredPartial',
  'targetMatrixComplete': false,
  'targetMatrixIssues': <Object?>['legacy state'],
  'rootMode': 'inferred',
  'rootCoverageComplete': false,
  'internalBoundaryComplete': false,
  'externalConsumersCovered': false,
  'rootIssues': <Object?>['legacy state'],
};

Map<String, Object?> _target({
  required String name,
  required String platform,
}) => <String, Object?>{
  'name': name,
  'platform': platform,
  'entrypoint': 'lib/main.dart',
  'flavor': null,
  'dartDefines': <String, Object?>{'API': 'v1'},
};

Map<String, Object?> _auxiliary({String id = 'test:widget'}) =>
    <String, Object?>{
      'id': id,
      'domain': 'test',
      'environmentValues': <String, Object?>{'MODE': 'test'},
      'environmentComplete': true,
      'reason': 'widget suite',
      'sourceConfiguredTarget': null,
    };

Map<String, Object?> _scan({
  required String scanKey,
  required List<Object?> requestedAdapters,
  required List<Object?> auxiliaries,
  required String graphMembershipMode,
  required List<Object?> contextIds,
}) => <String, Object?>{
  'rawReportPath': '/result/$scanKey.scan.json',
  'rawReportSha256': _sha('5'),
  'scannerArgv': _scanArgv(scanKey),
  'scannerArgvSha256': _argvSha(_scanArgv(scanKey)),
  'jsonSchemaVersion': 3,
  'requestedAdapters': requestedAdapters,
  'expectedAuxiliaryExecutionTargets': auxiliaries,
  'graphMembershipMode': graphMembershipMode,
  'expectedGraphMembershipContextIds': contextIds,
  'graphObservation': <String, Object?>{
    'rawObservationPath': '/result/$scanKey.observation.raw.json',
    'rawObservationSha256': _sha('7'),
    'observationReportPath': '/result/$scanKey.observation.json',
    'observationReportSha256': _sha('8'),
    'captureArgv': _captureArgv(scanKey),
    'captureArgvSha256': _argvSha(_captureArgv(scanKey)),
    'schemaVersion': 1,
  },
};

Map<String, Object?> _allowance() => <String, Object?>{
  'policyVersion': 1,
  'diagnosticCountsByCodePhase': <String, Object?>{
    for (final scanKey in _scanKeys)
      '$scanKey|package-internal-boundary|analysis': 0,
  },
  'danglingCountsByPassId': <String, Object?>{
    for (final scanKey in _scanKeys)
      '$scanKey|analysis-001': <String, Object?>{'edges': 0, 'roots': 0},
  },
  'danglingCountsByPassAndExecutionTargetId': <String, Object?>{
    for (final scanKey in _scanKeys)
      '$scanKey|analysis-001': <String, Object?>{
        'app:ios': <String, Object?>{'edges': 0, 'roots': 0},
        'app:web': <String, Object?>{'edges': 0, 'roots': 0},
        if (scanKey != 'adapter:duplicates')
          'aux:test:widget': <String, Object?>{'edges': 0, 'roots': 0},
        'unattributed': <String, Object?>{'edges': 0, 'roots': 0},
      },
  },
  'passIdsWithIntegrityMapAbsent': <Object?>[],
};

const _adapterIds = <String>[
  'assets',
  'dart',
  'duplicates',
  'get_it',
  'go_router',
  'l10n',
];

const _scanKeys = <String>[
  'full',
  'adapter:assets',
  'adapter:dart',
  'adapter:duplicates',
  'adapter:get_it',
  'adapter:go_router',
  'adapter:l10n',
];

List<Object?> _scanArgv(String scanKey) => <Object?>[
  '/tool/dart-sdk/bin/dart',
  'run',
  '/tool/bin/flutter_pruner.dart',
  'scan',
  '--project',
  '/project/pkg',
  '--config',
  '/project/tool/targets.json',
  '--format',
  'json',
  '--json-version',
  '3',
  '--output',
  '/result/$scanKey.scan.json',
  if (scanKey != 'full') ...<Object?>['--adapter', scanKey.substring(8)],
];

List<Object?> _captureArgv(String scanKey) => <Object?>[
  '/tool/dart-sdk/bin/dart',
  'run',
  '/tool/benchmark/accuracy/capture_scanner_graph.dart',
  '--project',
  '/project/pkg',
  '--config',
  '/project/tool/targets.json',
  '--json-version',
  '3',
  '--report-output',
  '/result/$scanKey.observation.json',
  '--observation-output',
  '/result/$scanKey.observation.raw.json',
  if (scanKey != 'full') ...<Object?>['--adapter', scanKey.substring(8)],
];

String _argvSha(List<Object?> argv) =>
    sha256.convert(utf8.encode(jsonEncode(argv))).toString();

void _replacePathValues(Object? value, String from, String to) {
  if (value is Map<String, Object?>) {
    for (final entry in value.entries.toList()) {
      final current = entry.value;
      if (current is String) {
        value[entry.key] = current.replaceAll(from, to);
      } else {
        _replacePathValues(current, from, to);
      }
    }
  } else if (value is List<Object?>) {
    for (var index = 0; index < value.length; index++) {
      final current = value[index];
      if (current is String) {
        value[index] = current.replaceAll(from, to);
      } else {
        _replacePathValues(current, from, to);
      }
    }
  }
}

void _refreshArgvHashes(Map<String, Object?> manifest) {
  for (final value in (manifest['scans'] as Map<String, Object?>).values) {
    final scan = value as Map<String, Object?>;
    scan['scannerArgvSha256'] = _argvSha(scan['scannerArgv'] as List<Object?>);
    final graph = scan['graphObservation'] as Map<String, Object?>;
    graph['captureArgvSha256'] = _argvSha(
      graph['captureArgv'] as List<Object?>,
    );
  }
}

List<Object?> _captureArgvFrom(Map<String, Object?> manifest, String scanKey) =>
    (((manifest['scans'] as Map<String, Object?>)[scanKey]
                as Map<String, Object?>)['graphObservation']
            as Map<String, Object?>)['captureArgv']
        as List<Object?>;

void _removeOption(List<Object?> argv, String option) {
  final index = argv.indexOf(option);
  if (index == -1 || index + 1 >= argv.length) {
    throw StateError('missing test option $option');
  }
  argv.removeRange(index, index + 2);
}

Map<String, Object?> _with(String key, Object? value) {
  final json = _acceptedManifest();
  json[key] = value;
  return json;
}

Map<String, Object?> _withPath(String key, String value) => _with(key, value);

Map<String, Object?> _withCoverage(String key, Object? value) {
  final json = _acceptedManifest();
  (json['expectedCoverage'] as Map<String, Object?>)[key] = value;
  return json;
}

Map<String, Object?> _withAuxiliary(String key, Object? value) {
  final json = _acceptedManifest();
  ((json['oracleAuxiliaryExecutionTargets'] as List<Object?>).single
          as Map<String, Object?>)[key] =
      value;
  return json;
}

Map<String, Object?> _withScan(String key, Object? value) {
  final json = _acceptedManifest();
  ((json['scans'] as Map<String, Object?>)['full']
          as Map<String, Object?>)[key] =
      value;
  return json;
}

Map<String, Object?> _withGraph(String key, Object? value) {
  final json = _acceptedManifest();
  final scan =
      (json['scans'] as Map<String, Object?>)['full'] as Map<String, Object?>;
  final graph = scan['graphObservation'] as Map<String, Object?>;
  graph[key] = value;
  return json;
}

String _sha(String fill) => List<String>.filled(64, fill).join();
