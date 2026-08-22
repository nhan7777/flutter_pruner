import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/accuracy_model.dart';
import '../../../benchmark/accuracy/src/oracle_finding_policy.dart';
import '../../../benchmark/accuracy/src/project_manifest.dart';

void main() {
  group('CandidateKey', () {
    test('has stable value equality and rejects an empty canonical ID', () {
      final first = CandidateKey(
        kind: OracleCandidateKind.dartDeclaration,
        canonicalId: 'dart:app/lib/a.dart#unused',
      );
      final same = CandidateKey(
        kind: OracleCandidateKind.dartDeclaration,
        canonicalId: 'dart:app/lib/a.dart#unused',
      );
      final otherKind = CandidateKey(
        kind: OracleCandidateKind.dartLibrary,
        canonicalId: 'dart:app/lib/a.dart#unused',
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(otherKind));
      expect(
        () => CandidateKey(
          kind: OracleCandidateKind.dartDeclaration,
          canonicalId: '',
        ),
        throwsArgumentError,
      );
    });
  });

  test('configured, auxiliary, and root values deep-freeze nested state', () {
    final defines = <String, String>{'API': 'one'};
    final configured = OracleTarget(
      name: 'app:ios',
      platform: 'ios',
      entrypoint: 'lib/main.dart',
      flavor: 'prod',
      dartDefines: defines,
    );
    defines['API'] = 'changed';

    final environment = <String, String>{'dart.library.io': 'true'};
    final auxiliary = OracleAuxiliaryExecutionTarget(
      id: 'test:widget',
      domain: OracleAuxiliaryDomain.test,
      environmentValues: environment,
      environmentComplete: true,
      reason: 'widget test root',
      sourceConfiguredTarget: configured,
    );
    environment['dart.library.io'] = 'false';

    final contexts = <String>{'aux:test:widget'};
    final root = OracleRoot(
      kind: OracleRootKind.testLibrary,
      canonicalNodeId: 'dart:app/test/widget_test.dart',
      sourcePath: 'test/widget_test.dart',
      executionTargetIds: contexts,
      reason: 'all test libraries are roots',
    );
    contexts.add('app:ios');

    expect(configured.dartDefines, {'API': 'one'});
    expect(configured.executionContextId, 'app:ios');
    expect(auxiliary.environmentValues, {'dart.library.io': 'true'});
    expect(auxiliary.executionContextId, 'aux:test:widget');
    expect(auxiliary.sourceConfiguredTarget!.dartDefines, {'API': 'one'});
    expect(root.executionTargetIds, {'aux:test:widget'});
    expect(
      () => configured.dartDefines['NEW'] = 'value',
      throwsUnsupportedError,
    );
    expect(
      () => auxiliary.environmentValues['NEW'] = 'value',
      throwsUnsupportedError,
    );
    expect(
      () => root.executionTargetIds.add('app:ios'),
      throwsUnsupportedError,
    );
  });

  test('canonical execution contexts retain production path and hash IDs', () {
    const external = 'aux:external:lib/scan_test.dart';
    const runtime =
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
    const callback = 'aux:runtime:vmPragma.bGliL2NhbGxiYWNrcy5kYXJ0.dm1FbnRyeQ';
    const configured = 'app:ios/staging~entry:preview';

    expect(isCanonicalExecutionTargetId(configured), isTrue);
    expect(isCanonicalExecutionTargetId(external), isTrue);
    expect(isCanonicalExecutionTargetId(runtime), isTrue);
    expect(isCanonicalExecutionTargetId(callback), isTrue);
    expect(
      OracleTarget(
        name: configured,
        platform: 'ios',
        entrypoint: 'lib/main.dart',
      ).executionContextId,
      configured,
    );
    final logical = logicalAuxiliaryIdFromWire(
      runtime,
      OracleAuxiliaryDomain.runtime,
    );
    expect(
      logical,
      'runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete',
    );
    expect(
      OracleAuxiliaryExecutionTarget(
        id: logical,
        domain: OracleAuxiliaryDomain.runtime,
        environmentValues: const <String, String>{},
        environmentComplete: true,
        reason: 'canonical runtime entry',
      ).executionContextId,
      runtime,
    );

    for (final invalid in <String>[
      'app:',
      'aux:test:',
      'aux:aux:test:widget',
      'aux:test:aux:widget',
      'aux:test:bad\nwidget',
    ]) {
      expect(isCanonicalExecutionTargetId(invalid), isFalse, reason: invalid);
    }
  });

  test('configured target IDs prefix raw names exactly once', () {
    OracleTarget target(String name) => OracleTarget(
      name: name,
      platform: 'android',
      entrypoint: 'lib/main.dart',
    );

    expect(target('android').executionContextId, 'app:android');
    expect(target('android-default').executionContextId, 'app:android-default');
    expect(target('app:android').executionContextId, 'app:android');

    for (final invalid in <String>['', 'app:', 'android\npreview']) {
      expect(() => target(invalid).executionContextId, throwsStateError);
    }
  });

  test('case closures are immutable, exact, and project in stable order', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartDeclaration,
      canonicalId: 'dart:app/lib/src/unused.dart#unused',
    );
    final appIosReachable = <String>{key.canonicalId};
    final reachable = <String, Set<String>>{
      'app:web': <String>{key.canonicalId},
      'aux:test:zeta': <String>{key.canonicalId},
      'app:ios': appIosReachable,
      'aux:test:alpha': <String>{key.canonicalId},
    };
    final retained = <String, Set<String>>{
      for (final entry in reachable.entries)
        entry.key: <String>{...entry.value, 'dart:app/lib/main.dart'},
    };
    final evidence = <OracleEvidence>[
      OracleEvidence(
        kind: OracleEvidenceKind.analyzerElement,
        source: 'resolved-unit',
        description: 'resolved declaration identity',
      ),
      OracleEvidence(
        kind: OracleEvidenceKind.targetClosure,
        source: 'independent-root-universe',
        description: 'exact closure membership',
      ),
    ];
    final oracleCase = OracleCase(
      key: key,
      reportExpectation: ReportExpectation.shouldNotReport,
      removalTruth: RemovalTruth.retained,
      findingContract: _contract(
        key,
        reportExpectation: ReportExpectation.shouldNotReport,
        removalTruth: RemovalTruth.retained,
      ),
      reachableByExecutionTarget: reachable,
      retainedByExecutionTarget: retained,
      evidence: evidence,
      rationale: 'reachable in exact configured and test closures',
    );

    appIosReachable.clear();
    reachable.clear();
    retained.clear();
    evidence.clear();

    expect(oracleCase.isReachableIn('app:ios'), isTrue);
    expect(oracleCase.retainedIn, ['ios', 'web']);
    expect(oracleCase.auxiliaryRetainedIn, ['aux:test:alpha', 'aux:test:zeta']);
    expect(
      () => oracleCase.reachableByExecutionTarget['app:ios']!.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => oracleCase.retainedByExecutionTarget.clear(),
      throwsUnsupportedError,
    );
    expect(() => oracleCase.evidence.clear(), throwsUnsupportedError);
  });

  test(
    'case rejects incomplete universes, invalid identities, and bad subsets',
    () {
      final key = CandidateKey(
        kind: OracleCandidateKind.asset,
        canonicalId: 'asset:app/assets/a.png',
      );

      expect(
        () => _case(
          key,
          reachable: {'app:ios': <String>{}},
          retained: {'app:web': <String>{}},
        ),
        throwsArgumentError,
      );
      expect(
        () => _case(
          key,
          reachable: {
            'app:ios': {key.canonicalId},
          },
          retained: {'app:ios': <String>{}},
        ),
        throwsArgumentError,
      );
      expect(
        () => _case(
          key,
          reachable: {'app:ios': <String>{}},
          retained: {
            'app:ios': {''},
          },
        ),
        throwsArgumentError,
      );
      for (final invalid in [
        'ios',
        'test:widget',
        'aux:guess:value',
        'aux:test:app:ios',
      ]) {
        expect(
          () => _case(
            key,
            reachable: {invalid: <String>{}},
            retained: {invalid: <String>{}},
          ),
          throwsArgumentError,
          reason: invalid,
        );
      }
    },
  );

  test('exact auxiliary use is globally retained and never removable', () {
    for (final context in [
      'aux:test:widget',
      'aux:runtime:callback',
      'aux:external:consumer',
    ]) {
      final key = CandidateKey(
        kind: OracleCandidateKind.dartDeclaration,
        canonicalId: 'dart:app/lib/api.dart#used',
      );
      final oracleCase = _case(
        key,
        reportExpectation: ReportExpectation.shouldNotReport,
        removalTruth: RemovalTruth.retained,
        reachable: {
          context: {key.canonicalId},
        },
        retained: {
          context: {key.canonicalId},
        },
      );

      expect(oracleCase.isRetainedIn(context), isTrue);
      expect(
        () => _case(
          key,
          reportExpectation: ReportExpectation.shouldReport,
          removalTruth: RemovalTruth.removableInDeclaredScope,
          reachable: {
            context: {key.canonicalId},
          },
          retained: {
            context: {key.canonicalId},
          },
        ),
        throwsArgumentError,
      );
    }
  });

  test('shouldNotReport requires exact candidate membership', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartDeclaration,
      canonicalId: 'dart:app/lib/api.dart#maybeUsed',
    );

    expect(
      () => _case(
        key,
        reportExpectation: ReportExpectation.shouldNotReport,
        removalTruth: RemovalTruth.retained,
        reachable: {'app:ios': <String>{}},
        retained: {'app:ios': <String>{}},
      ),
      throwsArgumentError,
    );
    final unusedButRetained = _case(
      key,
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.retained,
      reachable: {'app:ios': <String>{}},
      retained: {'app:ios': <String>{}},
    );
    expect(unusedButRetained.reportExpectation, ReportExpectation.shouldReport);
    expect(unusedButRetained.removalTruth, RemovalTruth.retained);
  });

  test('incomplete auxiliary retained union keeps both axes indeterminate', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartLibrary,
      canonicalId: 'dart:app/lib/conditional_io.dart',
    );
    final oracleCase = _case(
      key,
      reportExpectation: ReportExpectation.indeterminate,
      removalTruth: RemovalTruth.indeterminate,
      reachable: {'aux:runtime:unknown': <String>{}},
      retained: {
        'aux:runtime:unknown': {key.canonicalId},
      },
    );

    expect(oracleCase.isReachableIn('aux:runtime:unknown'), isFalse);
    expect(oracleCase.isRetainedIn('aux:runtime:unknown'), isTrue);
    expect(
      () => _case(
        key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        reachable: {'aux:runtime:unknown': <String>{}},
        retained: {
          'aux:runtime:unknown': {key.canonicalId},
        },
      ),
      throwsArgumentError,
    );
  });

  test('non-graph candidates require explicit empty closures', () {
    for (final kind in [
      OracleCandidateKind.duplicateGroup,
      OracleCandidateKind.analyzerDiagnostic,
    ]) {
      final key = CandidateKey(kind: kind, canonicalId: '${kind.name}:one');
      final oracleCase = _case(
        key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
      );
      expect(oracleCase.reachableByExecutionTarget, isEmpty);
      expect(oracleCase.retainedByExecutionTarget, isEmpty);
      expect(
        () => _case(
          key,
          reachable: {'app:ios': <String>{}},
          retained: {'app:ios': <String>{}},
        ),
        throwsArgumentError,
      );
    }
  });

  test(
    'report and removal axes remain independent for review observations',
    () {
      final key = CandidateKey(
        kind: OracleCandidateKind.route,
        canonicalId: 'route:app/settings',
      );
      final oracleCase = _case(
        key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
        reachable: {'app:ios': <String>{}},
        retained: {'app:ios': <String>{}},
      );

      expect(oracleCase.reportExpectation, ReportExpectation.shouldReport);
      expect(oracleCase.removalTruth, RemovalTruth.retained);
    },
  );

  test('cases require complete immutable policy-owned evidence', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartDeclaration,
      canonicalId: 'dart:app/lib/src/unused.dart#unused',
    );
    final contract = _contract(key);
    final analyzerEvidence = OracleEvidence(
      kind: OracleEvidenceKind.analyzerElement,
      source: 'resolved-unit',
      description: 'resolved declaration identity',
    );
    final closureEvidence = OracleEvidence(
      kind: OracleEvidenceKind.targetClosure,
      source: 'root-universe',
      description: 'absent from every exact closure',
    );

    for (final incomplete in <List<OracleEvidence>>[
      const [],
      [analyzerEvidence],
      [closureEvidence],
    ]) {
      expect(
        () => _case(
          key,
          findingContract: contract,
          evidence: incomplete,
          reachable: {'app:ios': <String>{}},
          retained: {'app:ios': <String>{}},
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => _case(
        key,
        findingContract: contract,
        evidence: [analyzerEvidence, closureEvidence, analyzerEvidence],
        reachable: {'app:ios': <String>{}},
        retained: {'app:ios': <String>{}},
      ),
      throwsArgumentError,
    );

    final mutableRisks = <String>{'broad-removal-scope'};
    final immutableContract = _contract(
      key,
      independentlyKnownRiskCodes: mutableRisks,
    );
    mutableRisks.clear();
    final evidence = <OracleEvidence>[analyzerEvidence, closureEvidence];
    final oracleCase = _case(
      key,
      findingContract: immutableContract,
      evidence: evidence,
      reachable: {'app:ios': <String>{}},
      retained: {'app:ios': <String>{}},
    );
    evidence.clear();

    expect(oracleCase.evidence, hasLength(2));
    expect(immutableContract.requiredEvidenceKinds, {
      OracleEvidenceKind.analyzerElement,
      OracleEvidenceKind.targetClosure,
    });
    expect(immutableContract.requiredRiskCodes, {'broad-removal-scope'});
    expect(
      () => immutableContract.requiredEvidenceKinds.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => immutableContract.requiredRiskCodes.clear(),
      throwsUnsupportedError,
    );
  });

  test('rejects a forged SAFE Dart contract with manual evidence', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartDeclaration,
      canonicalId: 'dart:app/lib/src/forged.dart#unused',
    );

    expect(
      () => OracleCase(
        key: key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        findingContract: OracleFindingContract(
          adapterId: 'assets',
          ruleId: 'PRN-ASSET-001',
          allowedConfidenceTiers: const {'SAFE'},
          expectedApplyEligible: true,
          requiredSafetyPredicates: const {'scannerSaysSafe': true},
          requiredEvidenceKinds: const {OracleEvidenceKind.manualAdjudication},
          requiredRiskCodes: const {},
        ),
        reachableByExecutionTarget: const {'app:ios': <String>{}},
        retainedByExecutionTarget: const {'app:ios': <String>{}},
        evidence: [
          OracleEvidence(
            kind: OracleEvidenceKind.manualAdjudication,
            source: 'forged-scanner-contract',
            description: 'caller-selected deletion authority',
          ),
        ],
        rationale: 'must not accept caller-selected finding authority',
      ),
      throwsArgumentError,
    );
  });

  test('rejects a canonical contract for another candidate or truth axes', () {
    final key = CandidateKey(
      kind: OracleCandidateKind.dartDeclaration,
      canonicalId: 'dart:app/lib/src/unused.dart#unused',
    );
    final assetKey = CandidateKey(
      kind: OracleCandidateKind.asset,
      canonicalId: 'asset:app/assets/unused.png',
    );
    final assetContract = _contract(assetKey);

    expect(
      () => OracleCase(
        key: key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        findingContract: assetContract,
        reachableByExecutionTarget: const {'app:ios': <String>{}},
        retainedByExecutionTarget: const {'app:ios': <String>{}},
        evidence: _evidenceFor(assetContract.requiredEvidenceKinds),
        rationale: 'a policy contract is bound to exactly one candidate',
      ),
      throwsArgumentError,
    );

    final removableContract = _contract(key);
    expect(
      () => OracleCase(
        key: key,
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
        findingContract: removableContract,
        reachableByExecutionTarget: const {'app:ios': <String>{}},
        retainedByExecutionTarget: const {'app:ios': <String>{}},
        evidence: _evidenceFor(removableContract.requiredEvidenceKinds),
        rationale: 'a policy contract is bound to exact truth axes',
      ),
      throwsArgumentError,
    );
  });
}

OracleCase _case(
  CandidateKey key, {
  ReportExpectation reportExpectation = ReportExpectation.shouldReport,
  RemovalTruth removalTruth = RemovalTruth.removableInDeclaredScope,
  Map<String, Set<String>> reachable = const {},
  Map<String, Set<String>> retained = const {},
  OracleFindingContract? findingContract,
  List<OracleEvidence>? evidence,
}) {
  final contract =
      findingContract ??
      _contract(
        key,
        reportExpectation: reportExpectation,
        removalTruth: removalTruth,
      );
  return OracleCase(
    key: key,
    reportExpectation: reportExpectation,
    removalTruth: removalTruth,
    findingContract: contract,
    reachableByExecutionTarget: reachable,
    retainedByExecutionTarget: retained,
    evidence: evidence ?? _evidenceFor(contract.requiredEvidenceKinds),
    rationale: 'test case',
  );
}

OracleFindingContract _contract(
  CandidateKey key, {
  ReportExpectation reportExpectation = ReportExpectation.shouldReport,
  RemovalTruth removalTruth = RemovalTruth.removableInDeclaredScope,
  Set<String> independentlyKnownRiskCodes = const {},
}) => const OracleFindingPolicy().contractFor(
  key: key,
  reportExpectation: reportExpectation,
  removalTruth: removalTruth,
  coverage: _coverage(),
  independentlyKnownPredicates: const {
    'noDynamicBlockers': true,
    'notProtected': true,
  },
  independentlyKnownRiskCodes: independentlyKnownRiskCodes,
);

ExpectedAnalysisCoverage _coverage() => ExpectedAnalysisCoverage(
  analysisMode: 'application',
  auxiliaryExecutionTargetIssuesPresent: true,
  auxiliaryExecutionTargetIssues: const [],
  targetMatrixStatus: 'declaredComplete',
  targetMatrixComplete: true,
  targetMatrixSource: '/external/config.yaml',
  targetMatrixIssues: const [],
  rootMode: 'applicationEntrypoints',
  rootCoverageComplete: true,
  internalBoundaryComplete: true,
  externalConsumersCovered: true,
  rootSource: '/external/config.yaml',
  publicEntrypoints: const [],
  rootIssues: const [],
);

List<OracleEvidence> _evidenceFor(Set<OracleEvidenceKind> kinds) => [
  for (final kind in kinds)
    OracleEvidence(
      kind: kind,
      source: 'test-${kind.name}',
      description: 'independent ${kind.name} evidence',
    ),
];
