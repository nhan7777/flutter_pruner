/// Versioned, scanner-independent finding contracts for the accuracy oracle.
library;

import 'accuracy_model.dart';
import 'project_manifest.dart';

/// Unforgeable capability used only by this library to create contracts.
final class OracleFindingPolicyAuthority {
  const OracleFindingPolicyAuthority._();

  /// Whether this instance came from the canonical policy library.
  bool get isCanonical => identical(this, _findingPolicyAuthority);
}

const _findingPolicyAuthority = OracleFindingPolicyAuthority._();

const _knownPredicateNames = <String>{
  'ruleAllowsAutoFix',
  'unreachableAcrossAllTargets',
  'noDynamicBlockers',
  'notProtected',
  'noPublicApiRisk',
  'hasDeterministicInverse',
  'analysisCoverageComplete',
  'actionSupported',
};

const _knownRiskCodes = <String>{
  'external-consumers-not-scanned',
  'broad-removal-scope',
};

const _findingIdentityByKind =
    <OracleCandidateKind, ({String adapterId, String ruleId})>{
      OracleCandidateKind.dartLibrary: (
        adapterId: 'dart',
        ruleId: 'PRN-DART-002',
      ),
      OracleCandidateKind.dartDeclaration: (
        adapterId: 'dart',
        ruleId: 'PRN-DART-001',
      ),
      OracleCandidateKind.analyzerDiagnostic: (
        adapterId: 'dart',
        ruleId: 'PRN-DART-003',
      ),
      OracleCandidateKind.asset: (adapterId: 'assets', ruleId: 'PRN-ASSET-001'),
      OracleCandidateKind.duplicateGroup: (
        adapterId: 'duplicates',
        ruleId: 'PRN-DUP-001',
      ),
      OracleCandidateKind.getItRegistration: (
        adapterId: 'get_it',
        ruleId: 'PRN-DI-001',
      ),
      OracleCandidateKind.route: (
        adapterId: 'go_router',
        ruleId: 'PRN-ROUTE-001',
      ),
      OracleCandidateKind.localizationKey: (
        adapterId: 'l10n',
        ruleId: 'PRN-L10N-001',
      ),
    };

const _requiredEvidenceKindsByKind =
    <OracleCandidateKind, Set<OracleEvidenceKind>>{
      OracleCandidateKind.dartLibrary: {
        OracleEvidenceKind.analyzerElement,
        OracleEvidenceKind.targetClosure,
      },
      OracleCandidateKind.dartDeclaration: {
        OracleEvidenceKind.analyzerElement,
        OracleEvidenceKind.targetClosure,
      },
      OracleCandidateKind.analyzerDiagnostic: {
        OracleEvidenceKind.analyzerElement,
      },
      OracleCandidateKind.asset: {
        OracleEvidenceKind.manifest,
        OracleEvidenceKind.targetClosure,
      },
      OracleCandidateKind.duplicateGroup: {OracleEvidenceKind.contentHash},
      OracleCandidateKind.getItRegistration: {
        OracleEvidenceKind.analyzerElement,
        OracleEvidenceKind.targetClosure,
      },
      OracleCandidateKind.route: {
        OracleEvidenceKind.analyzerElement,
        OracleEvidenceKind.targetClosure,
      },
      OracleCandidateKind.localizationKey: {
        OracleEvidenceKind.manifest,
        OracleEvidenceKind.targetClosure,
      },
    };

const _potentiallyActionableKinds = <OracleCandidateKind>{
  OracleCandidateKind.dartLibrary,
  OracleCandidateKind.dartDeclaration,
  OracleCandidateKind.asset,
};

const _fixedReviewKinds = <OracleCandidateKind>{
  OracleCandidateKind.analyzerDiagnostic,
  OracleCandidateKind.duplicateGroup,
  OracleCandidateKind.getItRegistration,
  OracleCandidateKind.route,
  OracleCandidateKind.localizationKey,
};

/// Derives finding authority only from oracle truth and frozen coverage facts.
final class OracleFindingPolicy {
  /// Version of the independent finding-contract policy.
  static const int version = 1;

  /// Creates the stateless policy.
  const OracleFindingPolicy();

  /// Returns the narrowest defensible finding contract for [key].
  OracleFindingContract contractFor({
    required CandidateKey key,
    required ReportExpectation reportExpectation,
    required RemovalTruth removalTruth,
    required ExpectedAnalysisCoverage coverage,
    required Map<String, bool> independentlyKnownPredicates,
    required Set<String> independentlyKnownRiskCodes,
  }) {
    final unknownPredicates = independentlyKnownPredicates.keys.toSet()
      ..removeAll(_knownPredicateNames);
    if (unknownPredicates.isNotEmpty) {
      throw ArgumentError.value(
        unknownPredicates,
        'independentlyKnownPredicates',
        'contains unknown safety predicate names',
      );
    }
    final unknownRisks = independentlyKnownRiskCodes.difference(
      _knownRiskCodes,
    );
    if (unknownRisks.isNotEmpty) {
      throw ArgumentError.value(
        unknownRisks,
        'independentlyKnownRiskCodes',
        'contains unknown risk codes',
      );
    }

    final identity = _findingIdentityByKind[key.kind];
    if (identity == null) {
      throw StateError('finding identity table is incomplete for ${key.kind}');
    }
    final requiredEvidenceKinds = _requiredEvidenceKindsByKind[key.kind];
    if (requiredEvidenceKinds == null || requiredEvidenceKinds.isEmpty) {
      throw StateError('evidence table is incomplete for ${key.kind}');
    }
    final predicates = Map<String, bool>.from(independentlyKnownPredicates);
    _recordDerived(
      predicates,
      'unreachableAcrossAllTargets',
      reportExpectation == ReportExpectation.shouldReport,
    );
    _recordDerived(
      predicates,
      'analysisCoverageComplete',
      _analysisCoverageComplete(coverage),
    );
    if (coverage.externalConsumersCovered) {
      _recordDerived(predicates, 'noPublicApiRisk', true);
    }

    final potentiallyActionable = _potentiallyActionableKinds.contains(
      key.kind,
    );
    if (!potentiallyActionable) {
      _recordDerived(predicates, 'actionSupported', false);
      _recordDerived(predicates, 'hasDeterministicInverse', false);
      _recordDerived(predicates, 'ruleAllowsAutoFix', false);
    } else if (predicates.containsKey('actionSupported')) {
      _recordDerived(
        predicates,
        'ruleAllowsAutoFix',
        predicates['actionSupported']!,
      );
    }

    _validateRiskPredicateConsistency(
      predicates,
      independentlyKnownRiskCodes,
      coverage,
    );

    final tier = _tierFor(
      kind: key.kind,
      reportExpectation: reportExpectation,
      removalTruth: removalTruth,
      coverage: coverage,
      predicates: predicates,
      riskCodes: independentlyKnownRiskCodes,
    );
    final allowedTiers = tier == null ? const <String>{} : <String>{tier};
    final applyEligible = _applyEligible(
      tier: tier,
      reportExpectation: reportExpectation,
      removalTruth: removalTruth,
      analysisMode: coverage.analysisMode,
      riskCodes: independentlyKnownRiskCodes,
    );

    return OracleFindingContract.policyOwned(
      _findingPolicyAuthority,
      candidateKey: key,
      reportExpectation: reportExpectation,
      removalTruth: removalTruth,
      adapterId: identity.adapterId,
      ruleId: identity.ruleId,
      allowedConfidenceTiers: allowedTiers,
      expectedApplyEligible: applyEligible,
      requiredSafetyPredicates: predicates,
      requiredEvidenceKinds: requiredEvidenceKinds,
      requiredRiskCodes: independentlyKnownRiskCodes,
    );
  }
}

String? _tierFor({
  required OracleCandidateKind kind,
  required ReportExpectation reportExpectation,
  required RemovalTruth removalTruth,
  required ExpectedAnalysisCoverage coverage,
  required Map<String, bool> predicates,
  required Set<String> riskCodes,
}) {
  if (reportExpectation != ReportExpectation.shouldReport) return null;
  if (_fixedReviewKinds.contains(kind)) return 'REVIEW';
  if (predicates['notProtected'] == false) return 'PROTECTED';
  if (coverage.analysisMode == 'package') return 'REVIEW';
  if (removalTruth != RemovalTruth.removableInDeclaredScope ||
      !predicates.containsKey('noPublicApiRisk') ||
      !_classificationHardGatesHold(predicates)) {
    return 'REVIEW';
  }
  if (riskCodes.isEmpty) return 'SAFE';
  if (riskCodes.length == 1) return 'HIGH';
  return 'REVIEW';
}

bool _classificationHardGatesHold(Map<String, bool> predicates) =>
    const <String>[
      'ruleAllowsAutoFix',
      'unreachableAcrossAllTargets',
      'noDynamicBlockers',
      'notProtected',
      'hasDeterministicInverse',
      'analysisCoverageComplete',
      'actionSupported',
    ].every((name) => predicates[name] == true);

bool _applyEligible({
  required String? tier,
  required ReportExpectation reportExpectation,
  required RemovalTruth removalTruth,
  required String analysisMode,
  required Set<String> riskCodes,
}) {
  if (reportExpectation != ReportExpectation.shouldReport ||
      removalTruth != RemovalTruth.removableInDeclaredScope) {
    return false;
  }
  return switch (analysisMode) {
    'application' => tier == 'SAFE',
    'package' => false,
    'package-internal' =>
      tier == 'SAFE' ||
          tier == 'HIGH' &&
              riskCodes.length == 1 &&
              riskCodes.contains('external-consumers-not-scanned'),
    _ => false,
  };
}

bool _analysisCoverageComplete(ExpectedAnalysisCoverage coverage) {
  final rootModeMatches = switch (coverage.analysisMode) {
    'application' => coverage.rootMode == 'applicationEntrypoints',
    'package' => coverage.rootMode == 'packagePublicApi',
    'package-internal' => coverage.rootMode == 'packageInternal',
    _ => false,
  };
  final publicEntrypointsMatch = coverage.analysisMode == 'application'
      ? coverage.publicEntrypoints.isEmpty
      : coverage.publicEntrypoints.isNotEmpty;
  final modeCoverageComplete = switch (coverage.analysisMode) {
    'application' =>
      coverage.rootCoverageComplete &&
          coverage.internalBoundaryComplete &&
          coverage.externalConsumersCovered,
    'package' =>
      coverage.rootCoverageComplete &&
          coverage.internalBoundaryComplete &&
          coverage.externalConsumersCovered,
    'package-internal' => coverage.internalBoundaryComplete,
    _ => false,
  };
  return coverage.auxiliaryExecutionTargetIssuesPresent &&
      coverage.auxiliaryExecutionTargetIssues.isEmpty &&
      coverage.targetMatrixStatus == 'declaredComplete' &&
      coverage.targetMatrixComplete &&
      coverage.targetMatrixIssues.isEmpty &&
      modeCoverageComplete &&
      coverage.rootIssues.isEmpty &&
      rootModeMatches &&
      publicEntrypointsMatch;
}

void _recordDerived(Map<String, bool> predicates, String name, bool value) {
  final existing = predicates[name];
  if (existing != null && existing != value) {
    throw ArgumentError(
      'independent predicate $name=$existing conflicts with derived $value',
    );
  }
  predicates[name] = value;
}

void _validateRiskPredicateConsistency(
  Map<String, bool> predicates,
  Set<String> riskCodes,
  ExpectedAnalysisCoverage coverage,
) {
  final externalRisk = riskCodes.contains('external-consumers-not-scanned');
  if (externalRisk &&
      (coverage.externalConsumersCovered ||
          predicates['noPublicApiRisk'] != false)) {
    throw ArgumentError(
      'external-consumer risk requires uncovered consumers and public API risk',
    );
  }
  if (!externalRisk &&
      coverage.analysisMode == 'package-internal' &&
      !coverage.externalConsumersCovered &&
      predicates['noPublicApiRisk'] == false) {
    throw ArgumentError(
      'known public API risk requires external-consumers-not-scanned',
    );
  }
}
