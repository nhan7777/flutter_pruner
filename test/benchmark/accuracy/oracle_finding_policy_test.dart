import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/accuracy_model.dart';
import '../../../benchmark/accuracy/src/oracle_finding_policy.dart';
import '../../../benchmark/accuracy/src/project_manifest.dart';

void main() {
  const policy = OracleFindingPolicy();

  test('owns a complete frozen adapter and rule identity table', () {
    final expected =
        <
          OracleCandidateKind,
          ({String adapter, String rule, Set<OracleEvidenceKind> evidence})
        >{
          OracleCandidateKind.dartLibrary: (
            adapter: 'dart',
            rule: 'PRN-DART-002',
            evidence: {
              OracleEvidenceKind.analyzerElement,
              OracleEvidenceKind.targetClosure,
            },
          ),
          OracleCandidateKind.dartDeclaration: (
            adapter: 'dart',
            rule: 'PRN-DART-001',
            evidence: {
              OracleEvidenceKind.analyzerElement,
              OracleEvidenceKind.targetClosure,
            },
          ),
          OracleCandidateKind.analyzerDiagnostic: (
            adapter: 'dart',
            rule: 'PRN-DART-003',
            evidence: {OracleEvidenceKind.analyzerElement},
          ),
          OracleCandidateKind.asset: (
            adapter: 'assets',
            rule: 'PRN-ASSET-001',
            evidence: {
              OracleEvidenceKind.manifest,
              OracleEvidenceKind.targetClosure,
            },
          ),
          OracleCandidateKind.duplicateGroup: (
            adapter: 'duplicates',
            rule: 'PRN-DUP-001',
            evidence: {OracleEvidenceKind.contentHash},
          ),
          OracleCandidateKind.getItRegistration: (
            adapter: 'get_it',
            rule: 'PRN-DI-001',
            evidence: {
              OracleEvidenceKind.analyzerElement,
              OracleEvidenceKind.targetClosure,
            },
          ),
          OracleCandidateKind.route: (
            adapter: 'go_router',
            rule: 'PRN-ROUTE-001',
            evidence: {
              OracleEvidenceKind.analyzerElement,
              OracleEvidenceKind.targetClosure,
            },
          ),
          OracleCandidateKind.localizationKey: (
            adapter: 'l10n',
            rule: 'PRN-L10N-001',
            evidence: {
              OracleEvidenceKind.manifest,
              OracleEvidenceKind.targetClosure,
            },
          ),
        };

    for (final entry in expected.entries) {
      final contract = policy.contractFor(
        key: CandidateKey(kind: entry.key, canonicalId: '${entry.key.name}:x'),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
        coverage: _coverage(),
        independentlyKnownPredicates: const {
          'notProtected': true,
          'noDynamicBlockers': true,
        },
        independentlyKnownRiskCodes: const {},
      );
      expect(
        (contract.adapterId, contract.ruleId),
        (entry.value.adapter, entry.value.rule),
      );
      expect(contract.requiredEvidenceKinds, entry.value.evidence);
      expect(contract.requiredRiskCodes, isEmpty);
    }
  });

  test('application allows only SAFE for a fully proven supported removal', () {
    final predicates = _supportedPredicates();
    final contract = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(),
      independentlyKnownPredicates: predicates,
      independentlyKnownRiskCodes: const {},
    );
    predicates['notProtected'] = false;

    expect(contract.allowedConfidenceTiers, {'SAFE'});
    expect(contract.expectedApplyEligible, isTrue);
    expect(contract.requiredRiskCodes, isEmpty);
    expect(contract.requiredSafetyPredicates, {
      'ruleAllowsAutoFix': true,
      'unreachableAcrossAllTargets': true,
      'noDynamicBlockers': true,
      'notProtected': true,
      'noPublicApiRisk': true,
      'hasDeterministicInverse': true,
      'analysisCoverageComplete': true,
      'actionSupported': true,
    });
    expect(
      () => contract.requiredSafetyPredicates['new'] = true,
      throwsUnsupportedError,
    );
    expect(
      () => contract.allowedConfidenceTiers.add('REVIEW'),
      throwsUnsupportedError,
    );
  });

  test('application fails closed for incomplete root coverage', () {
    final contract = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(rootCoverageComplete: false),
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {},
    );

    expect(contract.allowedConfidenceTiers, {'REVIEW'});
    expect(contract.expectedApplyEligible, isFalse);
    expect(
      contract.requiredSafetyPredicates['analysisCoverageComplete'],
      isFalse,
    );
  });

  test('application fails closed for uncovered external consumers', () {
    final contract = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(
        rootCoverageComplete: false,
        externalConsumersCovered: false,
      ),
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {},
    );

    expect(contract.allowedConfidenceTiers, {'REVIEW'});
    expect(contract.expectedApplyEligible, isFalse);
    expect(
      contract.requiredSafetyPredicates['analysisCoverageComplete'],
      isFalse,
    );
  });

  test('package is report-only even when every removal fact is proven', () {
    final contract = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(
        analysisMode: 'package',
        rootMode: 'packagePublicApi',
        publicEntrypoints: const ['lib/api.dart'],
      ),
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {},
    );

    expect(contract.allowedConfidenceTiers, {'REVIEW'});
    expect(contract.expectedApplyEligible, isFalse);
  });

  test('package REVIEW contracts preserve exact empty and broad risk sets', () {
    final coverage = _coverage(
      analysisMode: 'package',
      rootMode: 'packagePublicApi',
      publicEntrypoints: const ['lib/api.dart'],
    );
    final emptyRisk = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: coverage,
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {},
    );
    final mutableRisks = <String>{'broad-removal-scope'};
    final broadRisk = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: coverage,
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: mutableRisks,
    );
    mutableRisks.clear();

    expect(emptyRisk.allowedConfidenceTiers, {'REVIEW'});
    expect(broadRisk.allowedConfidenceTiers, {'REVIEW'});
    expect(emptyRisk.requiredRiskCodes, isEmpty);
    expect(broadRisk.requiredRiskCodes, {'broad-removal-scope'});
    expect(
      () => broadRisk.requiredRiskCodes.add('external-consumers-not-scanned'),
      throwsUnsupportedError,
    );
  });

  group('package-internal', () {
    test('distinguishes private SAFE from exact external-consumer HIGH', () {
      final privateContract = policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(
          analysisMode: 'package-internal',
          rootMode: 'packageInternal',
          externalConsumersCovered: false,
          publicEntrypoints: const ['lib/api.dart'],
        ),
        independentlyKnownPredicates: _supportedPredicates(
          noPublicApiRisk: true,
        ),
        independentlyKnownRiskCodes: const {},
      );
      final publicContract = policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(
          analysisMode: 'package-internal',
          rootMode: 'packageInternal',
          externalConsumersCovered: false,
          publicEntrypoints: const ['lib/api.dart'],
        ),
        independentlyKnownPredicates: _supportedPredicates(
          noPublicApiRisk: false,
        ),
        independentlyKnownRiskCodes: const {'external-consumers-not-scanned'},
      );

      expect(privateContract.allowedConfidenceTiers, {'SAFE'});
      expect(privateContract.expectedApplyEligible, isTrue);
      expect(publicContract.allowedConfidenceTiers, {'HIGH'});
      expect(publicContract.expectedApplyEligible, isTrue);
      expect(
        publicContract.requiredSafetyPredicates['noPublicApiRisk'],
        isFalse,
      );
    });

    test('fails closed for incomplete boundaries or unknown public risk', () {
      final incompleteBoundary = policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(
          analysisMode: 'package-internal',
          rootMode: 'inferred',
          internalBoundaryComplete: false,
          externalConsumersCovered: false,
          publicEntrypoints: const ['lib/api.dart'],
        ),
        independentlyKnownPredicates: _supportedPredicates(),
        independentlyKnownRiskCodes: const {},
      );
      final unknownPublicRisk = policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(
          analysisMode: 'package-internal',
          rootMode: 'packageInternal',
          externalConsumersCovered: false,
          publicEntrypoints: const ['lib/api.dart'],
        ),
        independentlyKnownPredicates: _supportedPredicates(
          includePublicRisk: false,
        ),
        independentlyKnownRiskCodes: const {},
      );

      expect(incompleteBoundary.allowedConfidenceTiers, {'REVIEW'});
      expect(incompleteBoundary.expectedApplyEligible, isFalse);
      expect(
        incompleteBoundary.requiredSafetyPredicates['analysisCoverageComplete'],
        isFalse,
      );
      expect(unknownPublicRisk.allowedConfidenceTiers, {'REVIEW'});
      expect(unknownPublicRisk.expectedApplyEligible, isFalse);
      expect(
        unknownPublicRisk.requiredSafetyPredicates.containsKey(
          'noPublicApiRisk',
        ),
        isFalse,
      );
    });
  });

  test('unsupported Dart action and inverse permit REVIEW only', () {
    final contract = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(),
      independentlyKnownPredicates: {
        ..._supportedPredicates(),
        'actionSupported': false,
        'hasDeterministicInverse': false,
      },
      independentlyKnownRiskCodes: const {},
    );

    expect(contract.allowedConfidenceTiers, {'REVIEW'});
    expect(contract.allowsConfidenceTier('SAFE'), isFalse);
    expect(contract.expectedApplyEligible, isFalse);
  });

  test('fixed review-only kinds never become PROTECTED or actionable', () {
    for (final kind in [
      OracleCandidateKind.analyzerDiagnostic,
      OracleCandidateKind.duplicateGroup,
      OracleCandidateKind.getItRegistration,
      OracleCandidateKind.route,
      OracleCandidateKind.localizationKey,
    ]) {
      final contract = policy.contractFor(
        key: CandidateKey(kind: kind, canonicalId: '${kind.name}:fixed'),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(),
        independentlyKnownPredicates: const {
          'notProtected': false,
          'noDynamicBlockers': true,
        },
        independentlyKnownRiskCodes: const {},
      );

      expect(contract.allowedConfidenceTiers, {'REVIEW'}, reason: kind.name);
      expect(contract.expectedApplyEligible, isFalse, reason: kind.name);
      expect(
        contract.requiredSafetyPredicates['notProtected'],
        isFalse,
        reason: kind.name,
      );
    }
  });

  test('keeps protected and broad-scope findings out of apply', () {
    final protected = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.retained,
      coverage: _coverage(),
      independentlyKnownPredicates: {
        ..._supportedPredicates(),
        'notProtected': false,
      },
      independentlyKnownRiskCodes: const {},
    );
    final broadApplication = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(),
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {'broad-removal-scope'},
    );
    final broadPackageInternal = policy.contractFor(
      key: _dartDeclaration(),
      reportExpectation: ReportExpectation.shouldReport,
      removalTruth: RemovalTruth.removableInDeclaredScope,
      coverage: _coverage(
        analysisMode: 'package-internal',
        rootMode: 'packageInternal',
        publicEntrypoints: const ['lib/api.dart'],
      ),
      independentlyKnownPredicates: _supportedPredicates(),
      independentlyKnownRiskCodes: const {'broad-removal-scope'},
    );

    expect(protected.allowedConfidenceTiers, {'PROTECTED'});
    expect(protected.expectedApplyEligible, isFalse);
    expect(broadApplication.allowedConfidenceTiers, {'HIGH'});
    expect(broadApplication.expectedApplyEligible, isFalse);
    expect(broadPackageInternal.allowedConfidenceTiers, {'HIGH'});
    expect(broadPackageInternal.expectedApplyEligible, isFalse);
  });

  test(
    'reportable retained cases and analyzer diagnostics stay non-removable',
    () {
      final retained = policy.contractFor(
        key: CandidateKey(
          kind: OracleCandidateKind.route,
          canonicalId: 'route:app/settings',
        ),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
        coverage: _coverage(),
        independentlyKnownPredicates: const {
          'notProtected': true,
          'noDynamicBlockers': true,
        },
        independentlyKnownRiskCodes: const {},
      );
      final diagnostic = policy.contractFor(
        key: CandidateKey(
          kind: OracleCandidateKind.analyzerDiagnostic,
          canonicalId: 'dart-diagnostic:app/lib/a.dart#unused_element@1',
        ),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.retained,
        coverage: _coverage(),
        independentlyKnownPredicates: const {
          'notProtected': true,
          'noDynamicBlockers': true,
        },
        independentlyKnownRiskCodes: const {},
      );

      expect(retained.allowedConfidenceTiers, {'REVIEW'});
      expect(retained.expectedApplyEligible, isFalse);
      expect(
        (diagnostic.adapterId, diagnostic.ruleId),
        ('dart', 'PRN-DART-003'),
      );
      expect(diagnostic.allowedConfidenceTiers, {'REVIEW'});
      expect(diagnostic.expectedApplyEligible, isFalse);
    },
  );

  test('non-reportable and indeterminate cases grant no tier authority', () {
    for (final expectation in [
      ReportExpectation.shouldNotReport,
      ReportExpectation.indeterminate,
    ]) {
      final contract = policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: expectation,
        removalTruth: expectation == ReportExpectation.shouldNotReport
            ? RemovalTruth.retained
            : RemovalTruth.indeterminate,
        coverage: _coverage(),
        independentlyKnownPredicates: _supportedPredicates(),
        independentlyKnownRiskCodes: const {},
      );

      expect(contract.allowedConfidenceTiers, isEmpty);
      expect(contract.expectedApplyEligible, isFalse);
    }
  });

  test('rejects unknown policy inputs and conflicts with derived facts', () {
    expect(
      () => policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(),
        independentlyKnownPredicates: const {'scannerSaysSafe': true},
        independentlyKnownRiskCodes: const {},
      ),
      throwsArgumentError,
    );
    expect(
      () => policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(),
        independentlyKnownPredicates: _supportedPredicates(),
        independentlyKnownRiskCodes: const {'scanner-risk'},
      ),
      throwsArgumentError,
    );
    expect(
      () => policy.contractFor(
        key: _dartDeclaration(),
        reportExpectation: ReportExpectation.shouldReport,
        removalTruth: RemovalTruth.removableInDeclaredScope,
        coverage: _coverage(),
        independentlyKnownPredicates: {
          ..._supportedPredicates(),
          'analysisCoverageComplete': false,
        },
        independentlyKnownRiskCodes: const {},
      ),
      throwsArgumentError,
    );
  });
}

CandidateKey _dartDeclaration() => CandidateKey(
  kind: OracleCandidateKind.dartDeclaration,
  canonicalId: 'dart:app/lib/src/unused.dart#unused',
);

Map<String, bool> _supportedPredicates({
  bool noPublicApiRisk = true,
  bool includePublicRisk = true,
}) => <String, bool>{
  'noDynamicBlockers': true,
  'notProtected': true,
  if (includePublicRisk) 'noPublicApiRisk': noPublicApiRisk,
  'hasDeterministicInverse': true,
  'actionSupported': true,
};

ExpectedAnalysisCoverage _coverage({
  String analysisMode = 'application',
  String rootMode = 'applicationEntrypoints',
  bool internalBoundaryComplete = true,
  bool externalConsumersCovered = true,
  bool? rootCoverageComplete,
  List<String> publicEntrypoints = const [],
}) => ExpectedAnalysisCoverage(
  analysisMode: analysisMode,
  auxiliaryExecutionTargetIssuesPresent: true,
  auxiliaryExecutionTargetIssues: const [],
  targetMatrixStatus: 'declaredComplete',
  targetMatrixComplete: true,
  targetMatrixSource: '/external/config.yaml',
  targetMatrixIssues: const [],
  rootMode: rootMode,
  rootCoverageComplete:
      rootCoverageComplete ??
      internalBoundaryComplete && externalConsumersCovered,
  internalBoundaryComplete: internalBoundaryComplete,
  externalConsumersCovered: externalConsumersCovered,
  rootSource: '/external/config.yaml',
  publicEntrypoints: publicEntrypoints,
  rootIssues: const [],
);
