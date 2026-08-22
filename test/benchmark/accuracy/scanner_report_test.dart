import 'dart:convert';
import 'dart:io';

// Production wire compatibility only. The oracle parser deliberately does not
// import production formatter or truth/policy types.
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart'
    as production;
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart'
    as production;
import 'package:flutter_pruner/src/core/confidence/confidence.dart'
    as production;
import 'package:flutter_pruner/src/core/confidence/finding.dart' as production;
import 'package:flutter_pruner/src/core/graph/evidence.dart' as production;
import 'package:flutter_pruner/src/core/graph/execution_target.dart'
    as production;
import 'package:flutter_pruner/src/core/graph/node.dart' as production;
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart'
    as production;
import 'package:flutter_pruner/src/core/project/project_context.dart'
    as production;
import 'package:flutter_pruner/src/core/project/target_matrix.dart'
    as production;
import 'package:flutter_pruner/src/reporting/run_report.dart' as production;
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/accuracy_model.dart';
import '../../../benchmark/accuracy/src/project_manifest.dart';
import '../../../benchmark/accuracy/src/scanner_report.dart';

void main() {
  final fixture = File('test/fixtures/accuracy/scanner_v3_all_rules.json');

  test(
    'parses v3 fixture with every built-in rule and typed detail shapes',
    () {
      final report = ScannerReport.fromUtf8(fixture.readAsBytesSync());

      expect(report.version, 3);
      expect(report.findings, hasLength(8));
      expect(
        report.findings.map((finding) => finding.ruleId),
        containsAll(<String>[
          'PRN-DART-001',
          'PRN-DART-002',
          'PRN-DART-003',
          'PRN-ASSET-001',
          'PRN-DUP-001',
          'PRN-DI-001',
          'PRN-ROUTE-001',
          'PRN-L10N-001',
        ]),
      );
      expect(
        report.findings
            .singleWhere((finding) => finding.ruleId == 'PRN-DART-003')
            .candidateKey
            .canonicalId,
        'dart-diagnostic:sample/lib/c.dart#unused_element@0',
      );
      expect(
        report.findings
            .singleWhere((finding) => finding.ruleId == 'PRN-DUP-001')
            .details['paths'],
        <String>['assets/a.png', 'assets/b.png'],
      );
      expect(report.rawSha256, matches(RegExp(r'^[a-f0-9]{64}$')));
    },
  );

  test('deep-freezes nested scanner finding details and measurements', () {
    final decoded =
        jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    final report = ScannerReport.fromJson(decoded);
    final duplicate = report.findings.singleWhere(
      (finding) => finding.ruleId == 'PRN-DUP-001',
    );

    expect(
      () =>
          (duplicate.details['paths'] as List<Object?>).add('assets/evil.png'),
      throwsUnsupportedError,
    );
    expect(
      () => duplicate.measurements.add(<String, Object?>{}),
      throwsUnsupportedError,
    );
  });

  test('rejects duplicate exact finding identities', () {
    final decoded =
        jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    final findings = (decoded['findings'] as List<Object?>);
    findings.add(Map<String, Object?>.from(findings.first! as Map));

    expect(() => ScannerReport.fromJson(decoded), throwsFormatException);
  });

  test(
    'rejects an exact rule-kind mismatch instead of prefix matching Dart IDs',
    () {
      final decoded =
          jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
      final first =
          (decoded['findings'] as List<Object?>).first! as Map<String, Object?>;
      first['ruleId'] = 'PRN-DART-002';

      expect(() => ScannerReport.fromJson(decoded), throwsFormatException);
    },
  );

  test('rejects an applyable route even when all predicates claim safety', () {
    final decoded =
        jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    final route = (decoded['findings'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((finding) => finding['ruleId'] == 'PRN-ROUTE-001');
    route['confidence'] = 'SAFE';
    route['applyEligible'] = true;
    route['proposedAction'] = 'remove';

    expect(() => ScannerReport.fromJson(decoded), throwsFormatException);
  });

  test(
    'rejects unknown fields, invalid predicates, and negative aggregates',
    () {
      final unknown =
          jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
      unknown['scannerAuthoritativeTruth'] = true;
      expect(() => ScannerReport.fromJson(unknown), throwsFormatException);

      final unknownPredicate =
          jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
      final unknownPredicates =
          ((unknownPredicate['findings'] as List<Object?>).first!
                  as Map<String, Object?>)['predicates']
              as Map<String, Object?>;
      unknownPredicates['retainedByUnknownContext'] = true;
      expect(
        () => ScannerReport.fromJson(unknownPredicate),
        throwsFormatException,
      );

      final missing = _fixtureJson();
      final missingPredicates =
          ((missing['findings'] as List<Object?>).first!
                  as Map<String, Object?>)['predicates']
              as Map<String, Object?>;
      missingPredicates.remove('notRetained');
      expect(() => ScannerReport.fromJson(missing), throwsFormatException);

      final wrongType = _fixtureJson();
      final wrongTypePredicates =
          ((wrongType['findings'] as List<Object?>).first!
                  as Map<String, Object?>)['predicates']
              as Map<String, Object?>;
      wrongTypePredicates['notRetained'] = 'true';
      expect(() => ScannerReport.fromJson(wrongType), throwsFormatException);

      final negative =
          jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
      final graph =
          ((((negative['execution'] as Map<String, Object?>)['analysisPasses']
                          as List<Object?>)
                      .single!
                  as Map<String, Object?>)['graph']
              as Map<String, Object?>);
      graph['danglingEdges'] = -1;
      expect(() => ScannerReport.fromJson(negative), throwsFormatException);
    },
  );

  test(
    'retains presence separately from normalized legacy empty collections',
    () {
      final decoded =
          jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
      final coverage = decoded['analysisCoverage'] as Map<String, Object?>;
      coverage.remove('auxiliaryExecutionTargets');
      coverage.remove('auxiliaryExecutionTargetIssues');
      final finding =
          (decoded['findings'] as List<Object?>).first! as Map<String, Object?>;
      finding.remove('retainedIn');
      finding.remove('auxiliaryRetainedIn');

      final report = ScannerReport.fromJson(decoded);
      expect(report.coverage.auxiliaryExecutionTargets, isEmpty);
      expect(report.coverage.auxiliaryExecutionTargetsPresent, isFalse);
      expect(report.coverage.auxiliaryExecutionTargetIssues, isEmpty);
      expect(report.coverage.auxiliaryExecutionTargetIssuesPresent, isFalse);
      expect(report.findings.first.retainedIn, isEmpty);
      expect(report.findings.first.retainedInPresent, isFalse);
      expect(report.findings.first.auxiliaryRetainedInPresent, isFalse);
    },
  );

  test(
    'accepted validation requires additive facts and exact integrity contexts',
    () {
      final bytes = utf8.encode(
        jsonEncode(_withIntegrityEvidence(_fixtureJson())),
      );
      final report = ScannerReport.fromUtf8(bytes);
      final manifest = _manifest(report.rawSha256!);

      report.validateForArtifact(
        manifest: manifest,
        scanKey: 'full',
        expectedPackageName: 'sample',
        validation: ScannerReportValidation.accepted,
        independentInventoryBounds: _fixtureInventoryBounds,
      );

      final decoded = _withIntegrityEvidence(_fixtureJson());
      final graph =
          ((((decoded['execution'] as Map<String, Object?>)['analysisPasses']
                          as List<Object?>)
                      .single!
                  as Map<String, Object?>)['graph']
              as Map<String, Object?>);
      (graph['integrityByExecutionTarget'] as Map<String, Object?>).remove(
        'unattributed',
      );
      final incomplete = ScannerReport.fromJson(decoded);
      expect(
        () => incomplete.validateForArtifact(
          manifest: manifest,
          scanKey: 'full',
          expectedPackageName: 'sample',
          validation: ScannerReportValidation.accepted,
        ),
        throwsFormatException,
      );
    },
  );

  test('rejects missing or incoherent per-context integrity evidence', () {
    final missing = _withIntegrityEvidence(_fixtureJson());
    _integrity(missing)['app:ios'] = <String, Object?>{
      'id': 'app:ios',
      'domain': 'configuredTarget',
      'complete': true,
      'danglingEdges': 0,
      'danglingRoots': 0,
    };
    expect(() => ScannerReport.fromJson(missing), throwsFormatException);

    final wrongDomain = _withIntegrityEvidence(_fixtureJson());
    (_integrity(wrongDomain)['app:ios'] as Map<String, Object?>)['domain'] =
        'auxiliary';
    expect(() => ScannerReport.fromJson(wrongDomain), throwsFormatException);

    final unknown = _withIntegrityEvidence(_fixtureJson());
    (_integrity(unknown)['app:ios'] as Map<String, Object?>)['domain'] =
        'unknown';
    expect(() => ScannerReport.fromJson(unknown), throwsFormatException);

    final inconsistent = _withIntegrityEvidence(_fixtureJson());
    final app = _integrity(inconsistent)['app:ios'] as Map<String, Object?>;
    app
      ..['complete'] = true
      ..['danglingEdges'] = 1;
    expect(() => ScannerReport.fromJson(inconsistent), throwsFormatException);

    final unsanitized = _withIntegrityEvidence(_fixtureJson());
    final unsanitizedApp =
        _integrity(unsanitized)['app:ios'] as Map<String, Object?>;
    unsanitizedApp
      ..['complete'] = false
      ..['danglingEdges'] = 1
      ..['incompleteReasons'] = <String>['zeta reason', 'alpha\treason'];
    expect(() => ScannerReport.fromJson(unsanitized), throwsFormatException);
  });

  test('accepts canonical path and hash auxiliary integrity IDs', () {
    const external = 'aux:external:lib/scan_test.dart';
    const executable =
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
    final valid = _withIntegrityEvidence(_fixtureJson());
    _integrity(valid)
      ..[external] = _integrityRecord(external)
      ..[executable] = _integrityRecord(executable);
    expect(() => ScannerReport.fromJson(valid), returnsNormally);

    const newline = 'aux:test:test/bad\n_test.dart:vm';
    final invalid = _withIntegrityEvidence(_fixtureJson());
    _integrity(invalid)[newline] = _integrityRecord(newline);
    expect(() => ScannerReport.fromJson(invalid), throwsFormatException);
  });

  test(
    'production auxiliary wire IDs round-trip through coverage and integrity',
    () {
      const external = 'aux:external:lib/scan_test.dart';
      const runtime =
          'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
      final value = _withIntegrityEvidence(_fixtureJson());
      final coverage = value['analysisCoverage'] as Map<String, Object?>;
      coverage['auxiliaryExecutionTargets'] = <Object?>[
        _productionAuxiliaryWire(external, 'external'),
        _productionAuxiliaryWire(runtime, 'runtime'),
      ];
      _integrity(value)
        ..[external] = _integrityRecord(external)
        ..[runtime] = _integrityRecord(runtime);

      final report = ScannerReport.fromJson(value);
      expect(
        report.coverage.auxiliaryExecutionTargets.map(
          (target) => target.executionContextId,
        ),
        <String>[external, runtime],
      );
      expect(
        report.analysisPasses.single.integrityByExecutionTarget.keys,
        containsAll(<String>[external, runtime]),
      );

      final doubled = _withIntegrityEvidence(_fixtureJson());
      final doubledCoverage =
          doubled['analysisCoverage'] as Map<String, Object?>;
      doubledCoverage['auxiliaryExecutionTargets'] = <Object?>[
        _productionAuxiliaryWire('aux:aux:test:widget', 'test'),
      ];
      expect(() => ScannerReport.fromJson(doubled), throwsFormatException);
    },
  );

  test('production formatter auxiliary wire validates accepted contexts', () {
    const external = 'aux:external:lib/scan_test.dart';
    const runtime =
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
    final sourceTarget = production.BuildTarget(
      name: 'android-default',
      platform: 'android',
      entrypoint: 'lib/main_default.dart',
    );
    final targets = <production.AuxiliaryExecutionTarget>[
      production.AuxiliaryExecutionTarget(
        id: external,
        domain: production.AuxiliaryExecutionDomain.external,
        environmentValues: const <String, String>{},
        environmentComplete: true,
        reason: 'external scanner path',
      ),
      production.AuxiliaryExecutionTarget(
        id: runtime,
        domain: production.AuxiliaryExecutionDomain.runtime,
        environmentValues: const <String, String>{},
        environmentComplete: true,
        reason: 'runtime executable path',
        sourceConfiguredTarget: sourceTarget,
      ),
    ];
    final report = ScannerReport.fromUtf8(
      utf8.encode(
        production.JsonFormatter().format(
          _productionWireReport(auxiliaryExecutionTargets: targets),
        ),
      ),
    );
    final oracleTargets = report.coverage.auxiliaryExecutionTargets;
    expect(oracleTargets.map((target) => target.executionContextId), <String>[
      external,
      runtime,
    ]);
    expect(
      report.analysisPasses.single.integrityByExecutionTarget.keys,
      containsAll(<String>[
        'app:android',
        'app:android-default',
        external,
        runtime,
        'unattributed',
      ]),
    );
    report.validateForArtifact(
      manifest: _manifest(
        report.rawSha256!,
        auxiliaryTargets: oracleTargets,
        requestedAdapters: const <String>['duplicates'],
        coverage: _productionCoverage(),
        targets: <OracleTarget>[
          OracleTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
          OracleTarget(
            name: 'android-default',
            platform: 'android',
            entrypoint: 'lib/main_default.dart',
          ),
        ],
      ),
      scanKey: 'full',
      expectedPackageName: 'sample',
      validation: ScannerReportValidation.accepted,
      independentInventoryBounds: _fixtureInventoryBounds,
    );
  });

  test('rejects integrity aggregates outside deduplicated-union bounds', () {
    final disjointUnattributed = _withIntegrityEvidence(_fixtureJson());
    _setIntegrityCounts(disjointUnattributed, 'app:ios', edges: 2, roots: 3);
    _setIntegrityCounts(
      disjointUnattributed,
      'unattributed',
      edges: 2,
      roots: 3,
    );
    _setAggregateCounts(disjointUnattributed, edges: 2, roots: 3);
    expect(
      () => ScannerReport.fromJson(disjointUnattributed),
      throwsFormatException,
    );

    final lower = _withSecondConfiguredIntegrity(_fixtureJson());
    _setIntegrityCounts(lower, 'app:ios', edges: 3, roots: 4);
    _setIntegrityCounts(lower, 'app:android', edges: 2, roots: 3);
    _setIntegrityCounts(lower, 'unattributed', edges: 2, roots: 2);
    _setAggregateCounts(lower, edges: 5, roots: 6);
    expect(() => ScannerReport.fromJson(lower), returnsNormally);

    final upper = _withSecondConfiguredIntegrity(_fixtureJson());
    _setIntegrityCounts(upper, 'app:ios', edges: 3, roots: 4);
    _setIntegrityCounts(upper, 'app:android', edges: 2, roots: 3);
    _setIntegrityCounts(upper, 'unattributed', edges: 2, roots: 2);
    _setAggregateCounts(upper, edges: 7, roots: 9);
    expect(() => ScannerReport.fromJson(upper), returnsNormally);

    final overlap = _withSecondConfiguredIntegrity(_fixtureJson());
    _setIntegrityCounts(overlap, 'app:ios', edges: 3, roots: 4);
    _setIntegrityCounts(overlap, 'app:android', edges: 2, roots: 3);
    _setIntegrityCounts(overlap, 'unattributed', edges: 2, roots: 2);
    _setAggregateCounts(overlap, edges: 6, roots: 7);
    expect(() => ScannerReport.fromJson(overlap), returnsNormally);

    final onlyUnattributed = _withIntegrityEvidence(_fixtureJson());
    _integrity(onlyUnattributed).remove('app:ios');
    _setIntegrityCounts(onlyUnattributed, 'unattributed', edges: 2, roots: 3);
    _setAggregateCounts(onlyUnattributed, edges: 2, roots: 3);
    expect(() => ScannerReport.fromJson(onlyUnattributed), returnsNormally);
  });

  test('accepted validation rejects an incomplete expected context', () {
    final value = _withIntegrityEvidence(_fixtureJson());
    final app = _integrity(value)['app:ios'] as Map<String, Object?>;
    app
      ..['complete'] = false
      ..['incompleteReasons'] = <String>['unknown context'];
    final report = ScannerReport.fromUtf8(utf8.encode(jsonEncode(value)));

    expect(
      () => report.validateForArtifact(
        manifest: _manifest(report.rawSha256!),
        scanKey: 'full',
        expectedPackageName: 'sample',
        validation: ScannerReportValidation.accepted,
        independentInventoryBounds: _fixtureInventoryBounds,
      ),
      throwsFormatException,
    );
  });

  test(
    'accepted validation requires a complete expected auxiliary context',
    () {
      final value = _withIntegrityEvidence(_fixtureJson());
      final auxiliary = OracleAuxiliaryExecutionTarget(
        id: 'runtime:callback',
        domain: OracleAuxiliaryDomain.runtime,
        environmentValues: const <String, String>{},
        environmentComplete: true,
        reason: 'callback entrypoint',
      );
      final coverage = value['analysisCoverage'] as Map<String, Object?>;
      coverage['auxiliaryExecutionTargets'] = <Object?>[
        <String, Object?>{
          'id': auxiliary.executionContextId,
          'domain': 'runtime',
          'environmentValues': const <String, String>{},
          'environmentComplete': true,
          'reason': auxiliary.reason,
        },
      ];
      _integrity(value)[auxiliary.executionContextId] = <String, Object?>{
        'id': auxiliary.executionContextId,
        'domain': 'auxiliary',
        'complete': false,
        'danglingEdges': 0,
        'danglingRoots': 0,
        'incompleteReasons': const <String>['unknown context'],
      };
      final report = ScannerReport.fromUtf8(utf8.encode(jsonEncode(value)));

      expect(
        () => report.validateForArtifact(
          manifest: _manifest(
            report.rawSha256!,
            auxiliaryTargets: <OracleAuxiliaryExecutionTarget>[auxiliary],
          ),
          scanKey: 'full',
          expectedPackageName: 'sample',
          validation: ScannerReportValidation.accepted,
        ),
        throwsFormatException,
      );
    },
  );

  test('accepts the production v3 enum wire names without aliases', () {
    final decoded =
        jsonDecode(fixture.readAsStringSync()) as Map<String, Object?>;
    (decoded['run'] as Map<String, Object?>)['status'] = 'completed';
    final pass =
        ((decoded['execution'] as Map<String, Object?>)['analysisPasses']
                    as List<Object?>)
                .single!
            as Map<String, Object?>;
    pass['purpose'] = 'initial';
    final adapter = (pass['adapters'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((value) => value['id'] == 'dart');
    adapter['role'] = 'reporting';
    adapter['status'] = 'executed';
    final findings = (decoded['findings'] as List<Object?>)
        .cast<Map<String, Object?>>();
    (findings.first['node'] as Map<String, Object?>)['kind'] = 'declaration';
    (findings.singleWhere((value) => value['ruleId'] == 'PRN-DI-001')['node']
            as Map<String, Object?>)['kind'] =
        'diRegistration';

    expect(() => ScannerReport.fromJson(decoded), returnsNormally);
  });

  test(
    'strict manifest fixture freezes the full and isolated scan inventory',
    () {
      final manifestJson =
          jsonDecode(
                File(
                  'test/fixtures/accuracy/strict_manifest_v1.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final manifest = AccuracyProjectManifest.fromJson(manifestJson);

      expect(
        manifest.scans.keys,
        containsAll(<String>['full', 'adapter:dart', 'adapter:duplicates']),
      );
      expect(
        manifest.scans['adapter:dart']!.graphMembershipMode,
        ScannerGraphMembershipMode.exact,
      );
      expect(
        manifest.scans['adapter:duplicates']!.graphMembershipMode,
        ScannerGraphMembershipMode.notApplicable,
      );

      final swapped =
          jsonDecode(jsonEncode(manifestJson)) as Map<String, Object?>;
      final scans = swapped['scans'] as Map<String, Object?>;
      (scans['adapter:duplicates']
              as Map<String, Object?>)['expectedAuxiliaryExecutionTargets'] =
          <Object?>[
            <String, Object?>{
              'id': 'test:illegal',
              'domain': 'test',
              'environmentValues': <String, Object?>{},
              'environmentComplete': true,
              'reason': 'illegal global registry leak',
              'sourceConfiguredTarget': null,
            },
          ];
      expect(
        () => AccuracyProjectManifest.fromJson(swapped),
        throwsFormatException,
      );
    },
  );

  test(
    'binds strict manifest selection before accepting support-adapter leaks',
    () {
      final reportJson = _fixtureJson();
      final coverage = reportJson['analysisCoverage'] as Map<String, Object?>;
      (coverage['targetMatrix'] as Map<String, Object?>)['source'] =
          '/project/tool/targets.json';
      (coverage['roots'] as Map<String, Object?>)['source'] =
          '/project/tool/targets.json';
      final execution = reportJson['execution'] as Map<String, Object?>;
      execution['requestedAdapters'] = <String>['assets'];
      final adapters =
          ((execution['analysisPasses'] as List<Object?>).single!
                  as Map<String, Object?>)['adapters']
              as List<Object?>;
      final dart = adapters.cast<Map<String, Object?>>().singleWhere(
        (adapter) => adapter['id'] == 'dart',
      );
      dart['role'] = 'support';
      _removeRunMeasurement(reportJson, 'dart');
      final report = ScannerReport.fromUtf8(
        utf8.encode(jsonEncode(reportJson)),
      );
      final manifest = _strictManifestWithReportSha(
        'adapter:assets',
        report.rawSha256!,
      );
      expect(
        () => report.validateForArtifact(
          manifest: manifest,
          scanKey: 'adapter:assets',
          expectedPackageName: 'sample',
          validation: ScannerReportValidation.accepted,
        ),
        throwsFormatException,
      );

      execution['requestedAdapters'] = <String>['duplicates'];
      final duplicateReport = ScannerReport.fromUtf8(
        utf8.encode(jsonEncode(reportJson)),
      );
      final duplicateManifest = _strictManifestWithReportSha(
        'adapter:duplicates',
        duplicateReport.rawSha256!,
      );
      expect(
        () => duplicateReport.validateForArtifact(
          manifest: duplicateManifest,
          scanKey: 'adapter:duplicates',
          expectedPackageName: 'sample',
          validation: ScannerReportValidation.accepted,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'accepts the parsed strict full artifact with Dart reporting selected',
    () {
      final value = _fixtureJson();
      final coverage = value['analysisCoverage'] as Map<String, Object?>;
      (coverage['targetMatrix'] as Map<String, Object?>)['source'] =
          '/project/tool/targets.json';
      (coverage['roots'] as Map<String, Object?>)['source'] =
          '/project/tool/targets.json';
      final report = ScannerReport.fromUtf8(utf8.encode(jsonEncode(value)));
      report.validateForArtifact(
        manifest: _strictManifestWithReportSha('full', report.rawSha256!),
        scanKey: 'full',
        expectedPackageName: 'sample',
        validation: ScannerReportValidation.accepted,
        independentInventoryBounds: _fixtureInventoryBounds,
      );
    },
  );

  test(
    'recomputes typed finding statistics and exact measurement vocabulary',
    () {
      final corruptStats = _fixtureJson();
      ((corruptStats['statistics'] as Map<String, Object?>)['findings']
              as Map<String, Object?>)['total'] =
          9;
      expect(() => ScannerReport.fromJson(corruptStats), throwsFormatException);

      final corruptMeasurement = _fixtureJson();
      final finding =
          (corruptMeasurement['findings'] as List<Object?>).first!
              as Map<String, Object?>;
      ((finding['measurements'] as List<Object?>).single!
              as Map<String, Object?>)['kind'] =
          'asset-family-source-bytes';
      expect(
        () => ScannerReport.fromJson(corruptMeasurement),
        throwsFormatException,
      );
    },
  );

  test('rejects missing required details and invalid measurement state', () {
    final missing = _fixtureJson();
    final asset = (missing['findings'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((finding) => finding['ruleId'] == 'PRN-ASSET-001');
    (asset['details'] as Map<String, Object?>).remove('baseSizeBytes');
    expect(() => ScannerReport.fromJson(missing), throwsFormatException);

    final unavailable = _fixtureJson();
    final measurement =
        (((unavailable['findings'] as List<Object?>).first!
                        as Map<String, Object?>)['measurements']
                    as List<Object?>)
                .single!
            as Map<String, Object?>;
    measurement['status'] = 'unknown';
    measurement['value'] = 1;
    expect(() => ScannerReport.fromJson(unavailable), throwsFormatException);
  });

  test('requires measured asset and duplicate finding values', () {
    for (final ruleId in const <String>['PRN-ASSET-001', 'PRN-DUP-001']) {
      for (final status in const <String>['unknown', 'notApplicable']) {
        final value = _fixtureJson();
        final finding = (value['findings'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((finding) => finding['ruleId'] == ruleId);
        final measurement =
            (finding['measurements'] as List<Object?>).single!
                as Map<String, Object?>;
        measurement
          ..['status'] = status
          ..['value'] = null;

        expect(
          () => ScannerReport.fromJson(value),
          throwsFormatException,
          reason: '$ruleId must reject $status',
        );
      }
    }
  });

  test('rejects noncanonical paths across typed scanner-report fields', () {
    final mutations = <void Function(Map<String, Object?>)>[
      (value) {
        final coverage = value['analysisCoverage'] as Map<String, Object?>;
        final matrix = coverage['targetMatrix'] as Map<String, Object?>;
        ((matrix['targets'] as List<Object?>).single!
                as Map<String, Object?>)['entrypoint'] =
            'lib//main.dart';
      },
      (value) {
        final coverage = value['analysisCoverage'] as Map<String, Object?>;
        final roots = coverage['roots'] as Map<String, Object?>;
        roots['publicEntrypoints'] = <String>['lib/../public.dart'];
      },
      (value) {
        final finding =
            (value['findings'] as List<Object?>).first! as Map<String, Object?>;
        (finding['node'] as Map<String, Object?>)['projectRelativeOrigin'] =
            'lib//a.dart';
      },
      (value) {
        final duplicate = (value['findings'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((finding) => finding['ruleId'] == 'PRN-DUP-001');
        (duplicate['details'] as Map<String, Object?>)['paths'] = <String>[
          'assets//a.png',
          'assets/b.png',
        ];
      },
      (value) {
        final finding =
            (value['findings'] as List<Object?>).first! as Map<String, Object?>;
        finding['evidence'] = <Object?>[
          <String, Object?>{
            'kind': 'analyzerElement',
            'producer': 'test',
            'description': 'hostile location',
            'exact': true,
            'location': 'lib//a.dart:1',
          },
        ];
      },
      (value) {
        final route = (value['findings'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((finding) => finding['ruleId'] == 'PRN-ROUTE-001');
        (route['details'] as Map<String, Object?>)['declaredAt'] =
            'lib/./routes.dart:7';
      },
      (value) {
        final l10n = (value['findings'] as List<Object?>)
            .cast<Map<String, Object?>>()
            .singleWhere((finding) => finding['ruleId'] == 'PRN-L10N-001');
        (l10n['details'] as Map<String, Object?>)['declaredAt'] =
            'lib/l10n/../app_en.arb:1';
      },
    ];

    for (final mutate in mutations) {
      final value = _fixtureJson();
      mutate(value);
      expect(() => ScannerReport.fromJson(value), throwsFormatException);
    }
  });

  test('bounds measured inventories by independent counts and bytes', () {
    for (final mutation in <void Function(Map<String, Object?>)>[
      (measurement) => measurement['knownCount'] = 2,
      (measurement) => measurement['unknownCount'] = 1,
      (measurement) => measurement['value'] = 4,
    ]) {
      final value = _withIntegrityEvidence(_fixtureJson());
      final measurements =
          (value['statistics'] as Map<String, Object?>)['measurements']
              as List<Object?>;
      final asset = measurements.cast<Map<String, Object?>>().singleWhere(
        (measurement) => measurement['adapterId'] == 'assets',
      );
      mutation(asset);
      final report = ScannerReport.fromUtf8(utf8.encode(jsonEncode(value)));

      expect(
        () => report.validateForArtifact(
          manifest: _manifest(report.rawSha256!),
          scanKey: 'full',
          expectedPackageName: 'sample',
          validation: ScannerReportValidation.accepted,
          independentInventoryBounds: _fixtureInventoryBounds,
        ),
        throwsFormatException,
      );
    }
  });

  test('requires dense tiers and exact reporting-support closure', () {
    final sparse = _fixtureJson();
    final byTier =
        ((sparse['statistics'] as Map<String, Object?>)['findings']
                as Map<String, Object?>)['byTier']
            as Map<String, Object?>;
    byTier.remove('SAFE');
    expect(() => ScannerReport.fromJson(sparse), throwsFormatException);

    final nonApplicable = _fixtureJson();
    final pass =
        ((nonApplicable['execution'] as Map<String, Object?>)['analysisPasses']
                    as List<Object?>)
                .single!
            as Map<String, Object?>;
    final duplicate = (pass['adapters'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((adapter) => adapter['id'] == 'duplicates');
    duplicate['status'] = 'notApplicable';
    duplicate['reason'] = 'dependency absent';
    (duplicate['contributions'] as Map<String, Object?>)['nodes'] = 0;
    _removeRunMeasurement(nonApplicable, 'duplicates');
    final report = ScannerReport.fromUtf8(
      utf8.encode(jsonEncode(nonApplicable)),
    );
    expect(
      () => report.validateForArtifact(
        manifest: _manifest(report.rawSha256!),
        scanKey: 'full',
        expectedPackageName: 'sample',
        validation: ScannerReportValidation.accepted,
      ),
      throwsFormatException,
    );
  });

  test('reconstructs every production canonical candidate identity exactly', () {
    final report = ScannerReport.fromUtf8(fixture.readAsBytesSync());
    expect(report.findings.map((finding) => finding.candidateKey.canonicalId), <
      String
    >[
      'dart:sample/lib/a.dart#unused',
      'dart:sample/lib/b.dart',
      'dart-diagnostic:sample/lib/c.dart#unused_element@0',
      'asset:sample/assets/a.png',
      'duplicate:sample:aaaaaaaaaaaa',
      'di:registration|c2FtcGxl|aW50ZXJmYWNlfGNHRmphMkZuWlRwellXMXdiR1V2YzJWeWRtbGpaUzVrWVhKMHxVMlZ5ZG1salpRfG5vbk51bGxhYmxlfDA|YWJzZW50|YmFzZQ|0|bGliL3NlcnZpY2VzLmRhcnRANDI',
      'route:sample:/legacy',
      'l10n:sample:app.title',
    ]);
  });

  test(
    'production JsonFormatter v3 wire is accepted by the independent parser',
    () {
      final bytes = utf8.encode(
        production.JsonFormatter().format(_productionWireReport()),
      );
      final report = ScannerReport.fromUtf8(bytes);
      expect(
        report.findings.single.candidateKey.canonicalId,
        'duplicate:sample:aaaaaaaaaaaa',
      );
      expect(report.statistics['findings'], isNotNull);
    },
  );

  test(
    'AnalysisSnapshot production pass characterizes executed inventories',
    () {
      final report = ScannerReport.fromUtf8(
        utf8.encode(production.JsonFormatter().format(_snapshotWireReport())),
      );
      final measurements = report.statistics['measurements'] as List<Object?>;
      expect(
        measurements.map((value) => (value as Map<String, Object?>)['kind']),
        <String>[
          'asset-family-source-bytes',
          'duplicate-potential-reclaimable-bytes',
          'dart-finding-source-bytes',
        ],
      );
    },
  );

  test(
    'AnalysisSnapshot accepts empty executed inventory measurements at zero',
    () {
      final report = ScannerReport.fromUtf8(
        utf8.encode(
          production.JsonFormatter().format(_emptySnapshotWireReport()),
        ),
      );
      final measurements = report.statistics['measurements'] as List<Object?>;
      expect(
        measurements.map((value) => (value as Map<String, Object?>)['value']),
        <Object?>[0, 0, 0],
      );
    },
  );

  test(
    'recomputes active blocker statistics from finding blocker identities',
    () {
      final value = _fixtureJson();
      value['blockers'] = <String, Object?>{
        'blocker-1': <String, Object?>{
          'producer': 'dart',
          'reason': 'unresolved generated consumer',
        },
      };
      ((value['findings'] as List<Object?>).first!
          as Map<String, Object?>)['blockerIds'] = <String>[
        'blocker-1',
      ];
      final blockerStats =
          (value['statistics'] as Map<String, Object?>)['blockers']
              as Map<String, Object?>;
      blockerStats
        ..['recorded'] = 1
        ..['activeUnique'] = 1
        ..['unboundUnique'] = 0
        ..['affectedFindings'] = 1
        ..['byProducer'] = <String, int>{'dart': 1};
      final graph =
          (((value['execution'] as Map<String, Object?>)['analysisPasses']
                          as List<Object?>)
                      .single!
                  as Map<String, Object?>)['graph']
              as Map<String, Object?>;
      graph['blockersRecorded'] = 1;
      expect(() => ScannerReport.fromJson(value), returnsNormally);

      blockerStats['activeUnique'] = 0;
      expect(() => ScannerReport.fromJson(value), throwsFormatException);

      blockerStats['activeUnique'] = 1;
      graph['blockersRecorded'] = 0;
      expect(() => ScannerReport.fromJson(value), throwsFormatException);
    },
  );

  test('validates constant-name and named-scope GetIt graph identities', () {
    final value = _fixtureJson();
    final finding = (value['findings'] as List<Object?>)
        .cast<Map<String, Object?>>()
        .singleWhere((item) => item['ruleId'] == 'PRN-DI-001');
    final details = finding['details'] as Map<String, Object?>;
    details
      ..['instanceNameState'] = 'constant'
      ..['instanceName'] = 'blue'
      ..['scope'] = 'named:child'
      ..['environments'] = 'dev,prod';
    String encode(String text) => base64UrlEncode(utf8.encode(text));
    final type = details['canonicalType']! as String;
    (finding['node'] as Map<String, Object?>)['id'] =
        'di:registration|${encode('sample')}|${encode(type)}|'
        '${encode('constant|${encode('blue')}')}|'
        '${encode('named|${encode('child')}')}|2|${encode('dev')}|'
        '${encode('prod')}|${encode('lib/services.dart@42')}';
    expect(() => ScannerReport.fromJson(value), returnsNormally);

    details['scope'] = 'base';
    expect(() => ScannerReport.fromJson(value), throwsFormatException);
  });

  test('rejects non-v3 scanner report before any finding is accepted', () {
    expect(
      () => ScannerReport.fromJson(<String, Object?>{'version': 2}),
      throwsFormatException,
    );
  });
}

const _fixtureInventoryBounds = <String, ScannerInventoryBound>{
  'assets': ScannerInventoryBound(maximumCount: 1, maximumValueBytes: 3),
  'duplicates': ScannerInventoryBound(maximumCount: 1, maximumValueBytes: 2),
};

Map<String, Object?> _fixtureJson() =>
    jsonDecode(
          File(
            'test/fixtures/accuracy/scanner_v3_all_rules.json',
          ).readAsStringSync(),
        )
        as Map<String, Object?>;

Map<String, Object?> _withIntegrityEvidence(Map<String, Object?> value) {
  for (final entry in _integrity(value).entries) {
    final domain = switch (entry.key) {
      'unattributed' => 'unattributed',
      String _ when entry.key.startsWith('aux:') => 'auxiliary',
      _ => 'configuredTarget',
    };
    final counts = entry.value as Map<String, Object?>;
    counts
      ..['id'] = entry.key
      ..['domain'] = domain
      ..['complete'] =
          counts['danglingEdges'] == 0 && counts['danglingRoots'] == 0
      ..['incompleteReasons'] = const <String>[];
  }
  return value;
}

Map<String, Object?> _withSecondConfiguredIntegrity(
  Map<String, Object?> value,
) {
  _withIntegrityEvidence(value);
  _integrity(value)['app:android'] = <String, Object?>{
    'id': 'app:android',
    'domain': 'configuredTarget',
    'complete': true,
    'danglingEdges': 0,
    'danglingRoots': 0,
    'incompleteReasons': const <String>[],
  };
  return value;
}

Map<String, Object?> _integrityRecord(String id) => <String, Object?>{
  'id': id,
  'domain': 'auxiliary',
  'complete': true,
  'danglingEdges': 0,
  'danglingRoots': 0,
  'incompleteReasons': const <String>[],
};

Map<String, Object?> _productionAuxiliaryWire(String id, String domain) =>
    <String, Object?>{
      'id': id,
      'domain': domain,
      'environmentValues': const <String, String>{},
      'environmentComplete': true,
      'reason': 'production auxiliary target',
    };

Map<String, Object?> _integrity(Map<String, Object?> value) {
  final execution = value['execution'] as Map<String, Object?>;
  final pass =
      (execution['analysisPasses'] as List<Object?>).single!
          as Map<String, Object?>;
  final graph = pass['graph'] as Map<String, Object?>;
  return graph['integrityByExecutionTarget'] as Map<String, Object?>;
}

void _setIntegrityCounts(
  Map<String, Object?> value,
  String contextId, {
  int edges = 0,
  int roots = 0,
}) {
  final context = _integrity(value)[contextId] as Map<String, Object?>;
  context
    ..['complete'] = edges == 0 && roots == 0
    ..['danglingEdges'] = edges
    ..['danglingRoots'] = roots
    ..['incompleteReasons'] = const <String>[];
}

void _setAggregateCounts(
  Map<String, Object?> value, {
  int edges = 0,
  int roots = 0,
}) {
  final execution = value['execution'] as Map<String, Object?>;
  final pass =
      (execution['analysisPasses'] as List<Object?>).single!
          as Map<String, Object?>;
  final graph = pass['graph'] as Map<String, Object?>;
  graph
    ..['danglingEdges'] = edges
    ..['danglingRoots'] = roots;
}

void _removeRunMeasurement(Map<String, Object?> report, String adapter) {
  final statistics = report['statistics'] as Map<String, Object?>;
  (statistics['measurements'] as List<Object?>).removeWhere(
    (value) => (value as Map<String, Object?>)['adapterId'] == adapter,
  );
}

AccuracyProjectManifest _strictManifestWithReportSha(
  String scanKey,
  String sha,
) {
  final value =
      jsonDecode(
            File(
              'test/fixtures/accuracy/strict_manifest_v1.json',
            ).readAsStringSync(),
          )
          as Map<String, Object?>;
  ((value['scans'] as Map<String, Object?>)[scanKey]
          as Map<String, Object?>)['rawReportSha256'] =
      sha;
  return AccuracyProjectManifest.fromJson(value);
}

// This helper intentionally uses the production writer solely to characterize
// the public v3 wire. It never participates in oracle truth or policy.
production.RunReport _emptySnapshotWireReport() {
  final project = production.ProjectContext(
    root: Directory('/project'),
    pubspec: const <String, Object?>{'name': 'sample'},
    packageName: 'sample',
    targets: <production.BuildTarget>[
      production.BuildTarget(
        name: 'app:ios',
        platform: 'ios',
        entrypoint: 'lib/main.dart',
      ),
    ],
  );
  const adapters = <production.AdapterRunReport>[
    production.AdapterRunReport(
      id: 'assets',
      name: 'Asset analyzer',
      role: production.AdapterRunRole.reporting,
      status: production.AdapterRunStatus.executed,
      elapsedMicros: 1,
      nodesAdded: 0,
      edgesAdded: 0,
      blockersAdded: 0,
    ),
    production.AdapterRunReport(
      id: 'duplicates',
      name: 'Duplicate file detector',
      role: production.AdapterRunRole.reporting,
      status: production.AdapterRunStatus.executed,
      elapsedMicros: 1,
      nodesAdded: 0,
      edgesAdded: 0,
      blockersAdded: 0,
    ),
    production.AdapterRunReport(
      id: 'dart',
      name: 'Dart declaration analyzer',
      role: production.AdapterRunRole.reporting,
      status: production.AdapterRunStatus.executed,
      elapsedMicros: 1,
      nodesAdded: 0,
      edgesAdded: 0,
      blockersAdded: 0,
    ),
  ];
  final graph = production.ReachabilityGraph();
  final integrity = graph.integrityFor(project.targets);
  final pass =
      production.AnalysisSnapshot(
        project: project,
        graph: graph,
        graphIntegrity: integrity,
        findings: const <production.Finding>[],
        adapterIds: const <String>['assets', 'duplicates', 'dart'],
        adapterRuns: adapters,
        elapsedMicros: 1,
        exclusions: project.pathPolicy.snapshot(),
      ).toPassReport(
        id: 'analysis-001',
        purpose: production.AnalysisPassPurpose.initial,
      );
  return production.RunReport(
    identity: production.RunIdentity(
      id: 'empty-snapshot-wire',
      command: production.RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026),
      finishedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      elapsedMicros: 1,
    ),
    status: production.RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'sample',
    requestedAdapters: const <String>['assets', 'duplicates', 'dart'],
    targetMatrix: project.targetMatrix,
    rootCoverage: project.rootCoverage,
    analysisPasses: <production.AnalysisPassReport>[pass],
    findings: const <production.Finding>[],
    diagnostics: const <production.RunDiagnostic>[],
  );
}

production.RunReport _snapshotWireReport() {
  final project = production.ProjectContext(
    root: Directory('/project'),
    pubspec: const <String, Object?>{'name': 'sample'},
    packageName: 'sample',
    targets: <production.BuildTarget>[
      production.BuildTarget(
        name: 'app:ios',
        platform: 'ios',
        entrypoint: 'lib/main.dart',
      ),
    ],
  );
  final blocker = production.Blocker(
    producer: 'dart',
    reason: 'unresolved generated consumer',
  );
  final duplicateNode = production.GraphNode(
    id: 'duplicate:sample:aaaaaaaaaaaa',
    kind: production.NodeKind.duplicateGroup,
    origin: Uri.file('/project/assets/a.png'),
    sizeBytes: 2,
    metadata: const <String, Object?>{
      'paths': <String>['assets/a.png', 'assets/b.png'],
      'fileCount': 2,
      'sizePerFile': 2,
      'groupSourceBytes': 4,
      'potentialReclaimableBytes': 2,
    },
  );
  final dartNode = production.GraphNode(
    id: 'dart:sample/lib/dead.dart#unused',
    kind: production.NodeKind.declaration,
    origin: Uri.file('/project/lib/dead.dart'),
  );
  final graph = production.ReachabilityGraph()
    ..addNode(duplicateNode)
    ..addNode(
      production.GraphNode(
        id: 'asset:sample/assets/a.png',
        kind: production.NodeKind.asset,
        origin: Uri.file('/project/assets/a.png'),
        sizeBytes: 3,
      ),
    )
    ..addNode(dartNode)
    ..addBlocker(blocker);
  final duplicate = production.Finding(
    ruleId: 'PRN-DUP-001',
    node: duplicateNode,
    confidence: production.Confidence.review,
    title: 'Duplicate file',
    predicates: const production.SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
    ),
    blockers: <production.Blocker>[blocker],
    reportingAdapterId: 'duplicates',
    sourceBytes: 2,
  );
  final dart = production.Finding(
    ruleId: 'PRN-DART-001',
    node: dartNode,
    confidence: production.Confidence.review,
    title: 'Unused declaration',
    predicates: const production.SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
    ),
    reportingAdapterId: 'dart',
  );
  final integrity = graph.integrityFor(project.targets);
  final pass =
      production.AnalysisSnapshot(
        project: project,
        graph: graph,
        graphIntegrity: integrity,
        findings: <production.Finding>[duplicate, dart],
        adapterIds: const <String>['assets', 'duplicates', 'dart'],
        adapterRuns: const <production.AdapterRunReport>[
          production.AdapterRunReport(
            id: 'assets',
            name: 'Asset analyzer',
            role: production.AdapterRunRole.reporting,
            status: production.AdapterRunStatus.executed,
            elapsedMicros: 1,
            nodesAdded: 1,
            edgesAdded: 0,
            blockersAdded: 0,
          ),
          production.AdapterRunReport(
            id: 'duplicates',
            name: 'Duplicate file detector',
            role: production.AdapterRunRole.reporting,
            status: production.AdapterRunStatus.executed,
            elapsedMicros: 1,
            nodesAdded: 1,
            edgesAdded: 0,
            blockersAdded: 0,
          ),
          production.AdapterRunReport(
            id: 'dart',
            name: 'Dart declaration analyzer',
            role: production.AdapterRunRole.reporting,
            status: production.AdapterRunStatus.executed,
            elapsedMicros: 1,
            nodesAdded: 1,
            edgesAdded: 0,
            blockersAdded: 0,
          ),
        ],
        elapsedMicros: 1,
        exclusions: project.pathPolicy.snapshot(),
      ).toPassReport(
        id: 'analysis-001',
        purpose: production.AnalysisPassPurpose.initial,
      );
  return production.RunReport(
    identity: production.RunIdentity(
      id: 'snapshot-wire',
      command: production.RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026),
      finishedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      elapsedMicros: 1,
    ),
    status: production.RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'sample',
    requestedAdapters: const <String>['assets', 'duplicates', 'dart'],
    targetMatrix: project.targetMatrix,
    rootCoverage: project.rootCoverage,
    analysisPasses: <production.AnalysisPassReport>[pass],
    findings: <production.Finding>[duplicate, dart],
    diagnostics: const <production.RunDiagnostic>[],
  );
}

production.RunReport _productionWireReport({
  List<production.AuxiliaryExecutionTarget> auxiliaryExecutionTargets =
      const <production.AuxiliaryExecutionTarget>[],
}) {
  final finding = production.Finding(
    ruleId: 'PRN-DUP-001',
    node: production.GraphNode(
      id: 'duplicate:sample:aaaaaaaaaaaa',
      kind: production.NodeKind.duplicateGroup,
      origin: Uri.file('/project/assets/a.png'),
      sizeBytes: 2,
      metadata: const <String, Object?>{
        'paths': <String>['assets/a.png', 'assets/b.png'],
        'fileCount': 2,
        'sizePerFile': 2,
        'groupSourceBytes': 4,
        'potentialReclaimableBytes': 2,
      },
    ),
    confidence: production.Confidence.review,
    title: 'Duplicate file',
    predicates: const production.SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
    ),
    reportingAdapterId: 'duplicates',
    sourceBytes: 2,
  );
  final statistics = production.FindingStatistics.fromFindings(
    <production.Finding>[finding],
  );
  return production.RunReport(
    identity: production.RunIdentity(
      id: 'wire-compat',
      command: production.RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026),
      finishedAtUtc: DateTime.utc(2026, 1, 1, 0, 0, 1),
      elapsedMicros: 1,
    ),
    status: production.RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'sample',
    requestedAdapters: const <String>['duplicates'],
    targetMatrix: production.TargetMatrix.declared(<production.BuildTarget>[
      production.BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
      production.BuildTarget(
        name: 'android-default',
        platform: 'android',
        entrypoint: 'lib/main_default.dart',
      ),
    ]),
    rootCoverage: production.RootCoverage.applicationApi(),
    analysisPasses: <production.AnalysisPassReport>[
      production.AnalysisPassReport(
        id: 'analysis-001',
        purpose: production.AnalysisPassPurpose.initial,
        elapsedMicros: 1,
        nodeCount: 1,
        edgeCount: 0,
        rootCount: 0,
        recordedBlockerCount: 0,
        danglingEdgeCount: 0,
        integrityByExecutionTarget:
            <String, production.ExecutionTargetIntegrityReport>{
              'app:android': production.ExecutionTargetIntegrityReport(
                id: 'app:android',
                domain: 'configuredTarget',
                complete: true,
                danglingEdgeCount: 0,
                danglingRootCount: 0,
              ),
              'app:android-default': production.ExecutionTargetIntegrityReport(
                id: 'app:android-default',
                domain: 'configuredTarget',
                complete: true,
                danglingEdgeCount: 0,
                danglingRootCount: 0,
              ),
              for (final target in auxiliaryExecutionTargets)
                target.id: production.ExecutionTargetIntegrityReport(
                  id: target.id,
                  domain: 'auxiliary',
                  complete: true,
                  danglingEdgeCount: 0,
                  danglingRootCount: 0,
                ),
            },
        unattributedIntegrity: production.ExecutionTargetIntegrityReport(
          id: 'unattributed',
          domain: 'unattributed',
          complete: true,
          danglingEdgeCount: 0,
          danglingRootCount: 0,
        ),
        auxiliaryExecutionTargets: auxiliaryExecutionTargets,
        adapterRuns: const <production.AdapterRunReport>[
          production.AdapterRunReport(
            id: 'duplicates',
            name: 'Duplicate file detector',
            role: production.AdapterRunRole.reporting,
            status: production.AdapterRunStatus.executed,
            elapsedMicros: 1,
            nodesAdded: 1,
            edgesAdded: 0,
            blockersAdded: 0,
          ),
        ],
        findingStatistics: statistics,
        blockerStatistics: production.BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: const <String, int>{},
        ),
        measurements: const <production.RunMeasurement>[
          production.RunMeasurement(
            kind: 'duplicate-potential-reclaimable-bytes',
            adapterId: 'duplicates',
            status: production.MeasurementStatus.measured,
            unit: 'bytes',
            value: 2,
            scope: 'duplicate-inventory',
            aggregation: 'within-duplicate-groups-only',
            knownCount: 1,
          ),
        ],
        exclusionPolicyVersion: 1,
        exclusionsByReason: const <String, int>{},
      ),
    ],
    findings: <production.Finding>[finding],
    diagnostics: const <production.RunDiagnostic>[],
  );
}

ExpectedAnalysisCoverage _productionCoverage() => ExpectedAnalysisCoverage(
  analysisMode: 'application',
  auxiliaryExecutionTargetIssuesPresent: true,
  auxiliaryExecutionTargetIssues: const [],
  targetMatrixStatus: 'declaredComplete',
  targetMatrixComplete: true,
  targetMatrixSource: 'api',
  targetMatrixIssues: const [],
  rootMode: 'applicationEntrypoints',
  rootCoverageComplete: true,
  internalBoundaryComplete: true,
  externalConsumersCovered: true,
  rootSource: 'api',
  publicEntrypoints: const [],
  rootIssues: const [],
);

AccuracyProjectManifest _manifest(
  String reportSha, {
  List<OracleAuxiliaryExecutionTarget> auxiliaryTargets = const [],
  List<String> requestedAdapters = const <String>[
    'assets',
    'dart',
    'duplicates',
    'get_it',
    'go_router',
    'l10n',
  ],
  ExpectedAnalysisCoverage? coverage,
  List<OracleTarget> targets = const <OracleTarget>[],
}) {
  const sha =
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
  final manifestTargets = targets.isEmpty
      ? <OracleTarget>[
          OracleTarget(
            name: 'app:ios',
            platform: 'ios',
            entrypoint: 'lib/main.dart',
          ),
        ]
      : targets;
  final expectedCoverage =
      coverage ??
      ExpectedAnalysisCoverage(
        analysisMode: 'application',
        auxiliaryExecutionTargetIssuesPresent: true,
        auxiliaryExecutionTargetIssues: const [],
        targetMatrixStatus: 'declaredComplete',
        targetMatrixComplete: true,
        targetMatrixSource: '/project/flutter_pruner.yaml',
        targetMatrixIssues: const [],
        rootMode: 'applicationEntrypoints',
        rootCoverageComplete: true,
        internalBoundaryComplete: true,
        externalConsumersCovered: true,
        rootSource: '/project/flutter_pruner.yaml',
        publicEntrypoints: const [],
        rootIssues: const [],
      );
  return AccuracyProjectManifest(
    manifestSchemaVersion: 1,
    label: 'sample',
    projectRoot: '/project',
    projectGitSha: 'project',
    packageRoot: '/project',
    flutterVersion: 'flutter',
    dartVersion: 'dart',
    toolSha: 'tool',
    configSha256: sha,
    packageConfigSha256: sha,
    lockfileSha256: sha,
    toolPackageConfigSha256: sha,
    toolLockfileSha256: sha,
    originalManagedFingerprint: sha,
    worktreeManagedFingerprint: sha,
    rootPolicyVersion: 2,
    candidateBoundaryPolicyVersion: 1,
    findingContractPolicyVersion: 1,
    manifestValidationMode: 'accepted',
    redactionRoots: ManifestRedactionRoots(
      roots: <String, RedactionRoot>{
        'project': RedactionRoot('/project', const []),
        'worktree': RedactionRoot('/worktree', const []),
        'tool': RedactionRoot('/tool', const []),
        'result': RedactionRoot('/result', const []),
      },
    ),
    expectedCoverage: expectedCoverage,
    targets: manifestTargets,
    oracleAuxiliaryExecutionTargets: auxiliaryTargets,
    scans: <String, FrozenScanArtifact>{
      'full': FrozenScanArtifact(
        rawReportPath: '/result/report.json',
        rawReportSha256: reportSha,
        scannerArgv: const <String>['dart'],
        scannerArgvSha256: sha,
        jsonSchemaVersion: 3,
        requestedAdapters: requestedAdapters,
        expectedAuxiliaryExecutionTargets: auxiliaryTargets,
        graphMembershipMode: ScannerGraphMembershipMode.exact,
        expectedGraphMembershipContextIds: (<String>[
          ...manifestTargets.map((target) => target.executionContextId),
          ...auxiliaryTargets.map((target) => target.executionContextId),
        ]..sort()),
        graphObservation: FrozenScannerGraphArtifact(
          rawObservationPath: '/result/graph.raw.json',
          rawObservationSha256: sha,
          observationReportPath: '/result/graph.json',
          observationReportSha256: sha,
          captureArgv: const <String>['dart'],
          captureArgvSha256: sha,
          schemaVersion: 1,
        ),
      ),
    },
  );
}
