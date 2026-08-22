import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/accuracy_model.dart';
import '../../../benchmark/accuracy/src/oracle_finding_policy.dart';
import '../../../benchmark/accuracy/src/project_manifest.dart';
import '../../../benchmark/accuracy/src/scanner_graph_observation.dart';

void main() {
  test('parses exact membership and deep-freezes nodes and membership', () {
    final input = _exactObservation();
    final observation = ScannerGraphObservation.fromJson(input);

    expect(observation.nodes.single.id, 'dart:lib/a.dart#unused');
    expect(observation.provenByExecutionTarget['app:ios'], <String>{
      'dart:lib/a.dart#unused',
    });
    expect(
      () => observation.nodes.add(observation.nodes.single),
      throwsUnsupportedError,
    );
    expect(
      () => observation.provenByExecutionTarget['app:ios']!.add('dart:evil'),
      throwsUnsupportedError,
    );
  });

  test('rejects unknown membership nodes and malformed contexts', () {
    final unknown = _exactObservation();
    (unknown['provenByExecutionTarget'] as Map<String, Object?>)['app:ios'] =
        <String>['dart:missing'];
    expect(
      () => ScannerGraphObservation.fromJson(unknown),
      throwsFormatException,
    );

    final malformed = _exactObservation();
    final retained =
        malformed['retainedByExecutionTarget'] as Map<String, Object?>;
    retained['ios'] = retained.remove('app:ios');
    expect(
      () => ScannerGraphObservation.fromJson(malformed),
      throwsFormatException,
    );
  });

  test('rejects noncanonical paths in targets and graph nodes', () {
    for (final path in const <String>[
      '/lib/a.dart',
      r'lib\a.dart',
      'lib//a.dart',
      'lib/./a.dart',
      'lib/../a.dart',
      'lib/a\u0000.dart',
    ]) {
      final target = _exactObservation();
      ((target['configuredTargets'] as List<Object?>).single!
              as Map<String, Object?>)['entrypoint'] =
          path;
      expect(
        () => ScannerGraphObservation.fromJson(target),
        throwsFormatException,
        reason: 'target $path',
      );

      final node = _exactObservation();
      ((node['nodes'] as List<Object?>).single!
              as Map<String, Object?>)['projectRelativeOrigin'] =
          path;
      expect(
        () => ScannerGraphObservation.fromJson(node),
        throwsA(anyOf(isA<FormatException>(), isA<ArgumentError>())),
        reason: 'node $path',
      );
    }
  });

  test('round-trips full auxiliary wire IDs without a second aux prefix', () {
    const external = 'aux:external:lib/scan_test.dart';
    const runtime =
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
    final input = _exactObservation();
    input['auxiliaryExecutionTargets'] = <Object?>[
      _wireAuxiliary(external, 'external'),
      _wireAuxiliary(runtime, 'runtime'),
    ];
    for (final membership in <String>[
      'provenByExecutionTarget',
      'retainedByExecutionTarget',
    ]) {
      (input[membership] as Map<String, Object?>)
        ..[external] = const <String>[]
        ..[runtime] = const <String>[];
    }

    final observation = ScannerGraphObservation.fromJson(input);
    expect(
      observation.auxiliaryExecutionTargets.map(
        (target) => target.executionContextId,
      ),
      <String>[external, runtime],
    );

    final doubled = _exactObservation();
    doubled['auxiliaryExecutionTargets'] = <Object?>[
      _wireAuxiliary('aux:runtime:aux:callback', 'runtime'),
    ];
    expect(
      () => ScannerGraphObservation.fromJson(doubled),
      throwsFormatException,
    );
  });

  test(
    'raw observation mutation cannot mutate a separately established OracleCase',
    () {
      final input = _exactObservation();
      final observation = ScannerGraphObservation.fromJson(input);
      final caseValue = _case();
      final nodes = input['nodes'] as List<Object?>;
      (nodes.single! as Map<String, Object?>)['kind'] = 'asset';
      (input['retainedByExecutionTarget'] as Map<String, Object?>)['app:ios'] =
          <String>[];

      expect(caseValue.isRetainedIn('app:ios'), isTrue);
      expect(observation.nodes.single.kind, 'dartDeclaration');
      expect(observation.retainedByExecutionTarget['app:ios'], <String>{
        'dart:lib/a.dart#unused',
      });
    },
  );

  test(
    'binds exact and duplicates-only membership to the selected scan artifact',
    () {
      final exactInput = _exactObservation();
      final exactBytes = utf8.encode(jsonEncode(exactInput));
      final exact = ScannerGraphObservation.fromUtf8(exactBytes);
      exact.validateForArtifact(
        manifest: _graphManifest(
          mode: ScannerGraphMembershipMode.exact,
          expectedContexts: const <String>['app:ios'],
          rawObservationSha256: sha256.convert(exactBytes).toString(),
        ),
        scanKey: 'selected',
        expectedPackageName: 'sample',
      );

      final duplicates = _exactObservation()
        ..['membershipAvailable'] = false
        ..['provenByExecutionTarget'] = <String, Object?>{}
        ..['retainedByExecutionTarget'] = <String, Object?>{};
      final duplicateBytes = utf8.encode(jsonEncode(duplicates));
      final observation = ScannerGraphObservation.fromUtf8(duplicateBytes);
      observation.validateForArtifact(
        manifest: _graphManifest(
          mode: ScannerGraphMembershipMode.notApplicable,
          expectedContexts: const <String>[],
          rawObservationSha256: sha256.convert(duplicateBytes).toString(),
        ),
        scanKey: 'selected',
        expectedPackageName: 'sample',
      );
    },
  );

  test('rejects non-v1 graph observation before any node is accepted', () {
    expect(
      () => ScannerGraphObservation.fromJson(<String, Object?>{'version': 2}),
      throwsFormatException,
    );
  });

  test(
    'rejects nonempty capture issues and graph schema/artifact mismatch',
    () {
      final withIssues = _exactObservation()..['issues'] = <String>['global'];
      expect(
        () => ScannerGraphObservation.fromJson(withIssues),
        throwsFormatException,
      );

      final input = _exactObservation();
      final bytes = utf8.encode(jsonEncode(input));
      final observation = ScannerGraphObservation.fromUtf8(bytes);
      expect(
        () => observation.validateForArtifact(
          manifest: _graphManifest(
            mode: ScannerGraphMembershipMode.exact,
            expectedContexts: const <String>['app:ios'],
            rawObservationSha256: sha256.convert(bytes).toString(),
            graphSchemaVersion: 2,
          ),
          scanKey: 'selected',
          expectedPackageName: 'sample',
        ),
        throwsFormatException,
      );
    },
  );
}

Map<String, Object?> _exactObservation() => <String, Object?>{
  'version': 1,
  'identity': <String, Object?>{
    'toolSha': 'tool',
    'projectGitSha': 'project',
    'configSha256': _sha,
    'packageConfigSha256': _sha,
    'packageName': 'sample',
    'projectRoot': '/project',
  },
  'configuredTargets': <Object?>[
    <String, Object?>{
      'name': 'app:ios',
      'platform': 'ios',
      'entrypoint': 'lib/main.dart',
      'dartDefines': <String, Object?>{},
    },
  ],
  'auxiliaryExecutionTargets': <Object?>[],
  'auxiliaryExecutionTargetIssues': <Object?>[],
  'membershipAvailable': true,
  'nodes': <Object?>[
    <String, Object?>{
      'id': 'dart:lib/a.dart#unused',
      'kind': 'dartDeclaration',
      'projectRelativeOrigin': 'lib/a.dart',
    },
  ],
  'provenByExecutionTarget': <String, Object?>{
    'app:ios': <Object?>['dart:lib/a.dart#unused'],
  },
  'retainedByExecutionTarget': <String, Object?>{
    'app:ios': <Object?>['dart:lib/a.dart#unused'],
  },
  'issues': <Object?>[],
};

Map<String, Object?> _wireAuxiliary(String id, String domain) =>
    <String, Object?>{
      'id': id,
      'domain': domain,
      'environmentValues': const <String, String>{},
      'environmentComplete': true,
      'reason': 'wire auxiliary target',
    };

OracleCase _case() {
  final coverage = ExpectedAnalysisCoverage(
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
  final key = CandidateKey(
    kind: OracleCandidateKind.dartDeclaration,
    canonicalId: 'dart:lib/a.dart#unused',
  );
  return OracleCase(
    key: key,
    reportExpectation: ReportExpectation.shouldNotReport,
    removalTruth: RemovalTruth.retained,
    findingContract: const OracleFindingPolicy().contractFor(
      key: key,
      reportExpectation: ReportExpectation.shouldNotReport,
      removalTruth: RemovalTruth.retained,
      coverage: coverage,
      independentlyKnownPredicates: const <String, bool>{},
      independentlyKnownRiskCodes: const <String>{},
    ),
    reachableByExecutionTarget: <String, Set<String>>{
      'app:ios': <String>{'dart:lib/a.dart#unused'},
    },
    retainedByExecutionTarget: <String, Set<String>>{
      'app:ios': <String>{'dart:lib/a.dart#unused'},
    },
    evidence: <OracleEvidence>[
      OracleEvidence(
        kind: OracleEvidenceKind.analyzerElement,
        source: 'test',
        description: 'resolved declaration',
      ),
      OracleEvidence(
        kind: OracleEvidenceKind.targetClosure,
        source: 'test',
        description: 'exact target use',
      ),
    ],
    rationale: 'exact configured use retains the declaration',
  );
}

const _sha = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

AccuracyProjectManifest _graphManifest({
  required ScannerGraphMembershipMode mode,
  required List<String> expectedContexts,
  required String rawObservationSha256,
  int graphSchemaVersion = 1,
}) {
  final target = OracleTarget(
    name: 'app:ios',
    platform: 'ios',
    entrypoint: 'lib/main.dart',
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
    configSha256: _sha,
    packageConfigSha256: _sha,
    lockfileSha256: _sha,
    toolPackageConfigSha256: _sha,
    toolLockfileSha256: _sha,
    originalManagedFingerprint: _sha,
    worktreeManagedFingerprint: _sha,
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
    expectedCoverage: ExpectedAnalysisCoverage(
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
    ),
    targets: <OracleTarget>[target],
    oracleAuxiliaryExecutionTargets: const [],
    scans: <String, FrozenScanArtifact>{
      'selected': FrozenScanArtifact(
        rawReportPath: '/result/report.json',
        rawReportSha256: _sha,
        scannerArgv: const <String>['dart'],
        scannerArgvSha256: _sha,
        jsonSchemaVersion: 3,
        requestedAdapters: const <String>['duplicates'],
        expectedAuxiliaryExecutionTargets: const [],
        graphMembershipMode: mode,
        expectedGraphMembershipContextIds: expectedContexts,
        graphObservation: FrozenScannerGraphArtifact(
          rawObservationPath: '/result/graph.raw.json',
          rawObservationSha256: rawObservationSha256,
          observationReportPath: '/result/graph.json',
          observationReportSha256: _sha,
          captureArgv: const <String>['dart'],
          captureArgvSha256: _sha,
          schemaVersion: graphSchemaVersion,
        ),
      ),
    },
  );
}
