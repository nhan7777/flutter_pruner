/// Shared, scanner-independent value types for the accuracy oracle.
library;

import 'oracle_finding_policy.dart';

/// A configured application execution target used by the independent oracle.
final class OracleTarget {
  /// Creates an immutable configured execution target.
  OracleTarget({
    required this.name,
    required this.platform,
    required this.entrypoint,
    this.flavor,
    Map<String, String> dartDefines = const {},
  }) : dartDefines = Map.unmodifiable(Map<String, String>.from(dartDefines));

  /// Stable configured target identity, such as `app:ios`.
  final String name;

  /// Platform selected for this target.
  final String platform;

  /// Project-relative entrypoint frozen for this target.
  final String entrypoint;

  /// Optional declared flavor; `null` is preserved as part of the target tuple.
  final String? flavor;

  /// Immutable Dart define environment for this target.
  final Map<String, String> dartDefines;

  /// Canonical configured execution-context identity.
  String get executionContextId {
    final result = name.startsWith('app:') ? name : 'app:$name';
    if (!isCanonicalConfiguredExecutionTargetId(result)) {
      throw StateError('configured target name is not a canonical app: ID');
    }
    return result;
  }
}

/// Domain in which an auxiliary execution target is exercised.
enum OracleAuxiliaryDomain {
  /// A test-only target.
  test,

  /// A runtime-only target.
  runtime,

  /// A target reached by an external consumer.
  external,
}

/// An independent non-configured execution target known to the oracle.
final class OracleAuxiliaryExecutionTarget {
  /// Creates an immutable auxiliary execution target.
  OracleAuxiliaryExecutionTarget({
    required this.id,
    required this.domain,
    required Map<String, String> environmentValues,
    required this.environmentComplete,
    required this.reason,
    OracleTarget? sourceConfiguredTarget,
  }) : environmentValues = Map.unmodifiable(
         Map<String, String>.from(environmentValues),
       ),
       sourceConfiguredTarget = sourceConfiguredTarget == null
           ? null
           : OracleTarget(
               name: sourceConfiguredTarget.name,
               platform: sourceConfiguredTarget.platform,
               entrypoint: sourceConfiguredTarget.entrypoint,
               flavor: sourceConfiguredTarget.flavor,
               dartDefines: sourceConfiguredTarget.dartDefines,
             );

  /// Stable auxiliary target identity, such as `test:widget`.
  final String id;

  /// Domain in which this target is evaluated.
  final OracleAuxiliaryDomain domain;

  /// Immutable environment values specific to this target.
  final Map<String, String> environmentValues;

  /// Whether the target environment is complete enough for exact reachability.
  final bool environmentComplete;

  /// Auditable reason this target belongs to the independent root universe.
  final String reason;

  /// Optional configured target from which this auxiliary target was derived.
  final OracleTarget? sourceConfiguredTarget;

  /// Canonical auxiliary execution-context identity.
  String get executionContextId {
    if (!isCanonicalLogicalAuxiliaryId(id, domain)) {
      throw StateError('auxiliary target ID does not match its domain');
    }
    final result = 'aux:$id';
    if (!isCanonicalExecutionTargetId(result)) {
      throw StateError('auxiliary target does not produce a canonical aux: ID');
    }
    return result;
  }
}

/// Candidate categories owned independently by the accuracy oracle.
enum OracleCandidateKind {
  /// One Dart library candidate.
  dartLibrary,

  /// One Dart declaration candidate.
  dartDeclaration,

  /// One analyzer unused-code diagnostic candidate.
  analyzerDiagnostic,

  /// One declared asset candidate.
  asset,

  /// One byte-identical duplicate group.
  duplicateGroup,

  /// One GetIt registration candidate.
  getItRegistration,

  /// One go_router declaration candidate.
  route,

  /// One localization-key candidate.
  localizationKey,
}

/// Domain from which a canonical oracle root is reached.
enum OracleRootDomain {
  /// A configured application target.
  configured,

  /// An independently evaluated test context.
  test,

  /// An independently evaluated runtime callback context.
  runtime,

  /// An independently evaluated external-consumer context.
  external,
}

/// Whether the candidate belongs in the scanner report.
enum ReportExpectation {
  /// The candidate must be reported under the declared contract.
  shouldReport,

  /// The candidate must not be reported under the declared contract.
  shouldNotReport,

  /// Available evidence cannot decide report presence.
  indeterminate,
}

/// Whether removal is correct within the explicitly declared scope.
enum RemovalTruth {
  /// Removal is independently proven correct in the declared scope.
  removableInDeclaredScope,

  /// The candidate must be retained.
  retained,

  /// Available evidence cannot grant either retention or removal authority.
  indeterminate,
}

/// Scanner-independent evidence categories retained by an oracle case.
enum OracleEvidenceKind {
  /// A resolved analyzer element identity.
  analyzerElement,

  /// Membership in an independently traversed target closure.
  targetClosure,

  /// A resolved static asset argument.
  staticAssetArgument,

  /// A resolved generated localization accessor use.
  generatedAccessorUse,

  /// A frozen project-manifest fact.
  manifest,

  /// A content digest.
  contentHash,

  /// A build outcome after a controlled mutation.
  mutationBuild,

  /// A runtime outcome after a controlled mutation.
  mutationRuntime,

  /// A recorded manual decision with explicit rationale.
  manualAdjudication,
}

/// Stable value identity for exactly one oracle candidate.
final class CandidateKey {
  /// Creates a nonempty canonical candidate identity.
  CandidateKey({required this.kind, required this.canonicalId}) {
    if (canonicalId.isEmpty) {
      throw ArgumentError.value(
        canonicalId,
        'canonicalId',
        'must not be empty',
      );
    }
  }

  /// Candidate category.
  final OracleCandidateKind kind;

  /// Canonical identity reconstructed independently for this category.
  final String canonicalId;

  @override
  bool operator ==(Object other) =>
      other is CandidateKey &&
      other.kind == kind &&
      other.canonicalId == canonicalId;

  @override
  int get hashCode => Object.hash(kind, canonicalId);

  @override
  String toString() => '${kind.name}:$canonicalId';
}

/// Kinds of roots admitted by the versioned independent root policy.
enum OracleRootKind {
  /// An explicitly configured application entrypoint.
  configuredApplicationEntrypoint,

  /// A modeled test library.
  testLibrary,

  /// A non-test main selected by an exact condition.
  conditionalMain,

  /// A declaration protected by `vm:entry-point` semantics.
  pragmaVmEntrypoint,

  /// A native callback entry boundary.
  nativeCallback,

  /// A public package entrypoint.
  publicPackageEntrypoint,
}

/// One immutable independent graph root.
final class OracleRoot {
  /// Creates a root associated only with canonical execution contexts.
  OracleRoot({
    required this.kind,
    required this.canonicalNodeId,
    required this.sourcePath,
    required Set<String> executionTargetIds,
    required this.reason,
  }) : executionTargetIds = Set.unmodifiable(
         Set<String>.from(executionTargetIds),
       ) {
    if (canonicalNodeId.isEmpty || sourcePath.isEmpty || reason.isEmpty) {
      throw ArgumentError(
        'oracle root identity, path, and reason are required',
      );
    }
    if (this.executionTargetIds.isEmpty ||
        this.executionTargetIds.any(
          (id) => !isCanonicalExecutionTargetId(id),
        )) {
      throw ArgumentError.value(
        this.executionTargetIds,
        'executionTargetIds',
        'must contain only canonical app:/aux: context identities',
      );
    }
  }

  /// Root category.
  final OracleRootKind kind;

  /// Canonical graph-node identity rooted in every declared context.
  final String canonicalNodeId;

  /// Project-relative source path.
  final String sourcePath;

  /// Immutable canonical context identities in which this is a root.
  final Set<String> executionTargetIds;

  /// Auditable reason this root is admitted.
  final String reason;
}

/// One immutable item of scanner-independent evidence.
final class OracleEvidence {
  /// Creates evidence with nonempty source and description.
  OracleEvidence({
    required this.kind,
    required this.source,
    required this.description,
  }) {
    if (source.isEmpty || description.isEmpty) {
      throw ArgumentError(
        'oracle evidence source and description are required',
      );
    }
  }

  /// Evidence category.
  final OracleEvidenceKind kind;

  /// Stable producer or artifact identity.
  final String source;

  /// Auditable evidence summary.
  final String description;
}

/// Independently derived constraints for a scanner finding.
final class OracleFindingContract {
  /// Rejects caller-selected finding authority.
  factory OracleFindingContract({
    required String adapterId,
    required String ruleId,
    required Set<String> allowedConfidenceTiers,
    required bool expectedApplyEligible,
    required Map<String, bool> requiredSafetyPredicates,
    required Set<OracleEvidenceKind> requiredEvidenceKinds,
    required Set<String> requiredRiskCodes,
  }) => throw ArgumentError(
    'OracleFindingContract must be derived by OracleFindingPolicy.contractFor',
  );

  /// Creates a contract through the policy library's unforgeable authority.
  OracleFindingContract.policyOwned(
    OracleFindingPolicyAuthority authority, {
    required CandidateKey candidateKey,
    required ReportExpectation reportExpectation,
    required RemovalTruth removalTruth,
    required this.adapterId,
    required this.ruleId,
    required Set<String> allowedConfidenceTiers,
    required this.expectedApplyEligible,
    required Map<String, bool> requiredSafetyPredicates,
    required Set<OracleEvidenceKind> requiredEvidenceKinds,
    required Set<String> requiredRiskCodes,
  }) : _authority = authority,
       _candidateKey = candidateKey,
       _reportExpectation = reportExpectation,
       _removalTruth = removalTruth,
       allowedConfidenceTiers = Set.unmodifiable(
         Set<String>.from(allowedConfidenceTiers),
       ),
       requiredSafetyPredicates = Map.unmodifiable(
         Map<String, bool>.from(requiredSafetyPredicates),
       ),
       requiredEvidenceKinds = Set.unmodifiable(
         Set<OracleEvidenceKind>.from(requiredEvidenceKinds),
       ),
       requiredRiskCodes = Set.unmodifiable(
         Set<String>.from(requiredRiskCodes),
       ) {
    if (adapterId.isEmpty || ruleId.isEmpty) {
      throw ArgumentError('finding adapter and rule identities are required');
    }
    const tiers = <String>{'PROTECTED', 'REVIEW', 'HIGH', 'SAFE'};
    if (!tiers.containsAll(this.allowedConfidenceTiers)) {
      throw ArgumentError.value(
        this.allowedConfidenceTiers,
        'allowedConfidenceTiers',
        'contains an unknown confidence tier',
      );
    }
    if (expectedApplyEligible &&
        !this.allowedConfidenceTiers.any(
          (tier) => tier == 'SAFE' || tier == 'HIGH',
        )) {
      throw ArgumentError(
        'apply eligibility requires an allowed SAFE or HIGH tier',
      );
    }
    if (this.requiredEvidenceKinds.isEmpty) {
      throw ArgumentError.value(
        this.requiredEvidenceKinds,
        'requiredEvidenceKinds',
        'must retain at least one independent evidence kind',
      );
    }
    if (this.requiredRiskCodes.any((code) => code.isEmpty)) {
      throw ArgumentError.value(
        this.requiredRiskCodes,
        'requiredRiskCodes',
        'must not contain an empty risk code',
      );
    }
  }

  /// Expected adapter identity.
  final String adapterId;

  /// Expected stable rule identity.
  final String ruleId;

  /// Narrowest independently defensible scanner confidence tiers.
  final Set<String> allowedConfidenceTiers;

  /// Whether this finding may enter apply under the declared mode policy.
  final bool expectedApplyEligible;

  /// Every safety predicate whose value is independently known.
  final Map<String, bool> requiredSafetyPredicates;

  /// Independent evidence categories required before this contract is usable.
  final Set<OracleEvidenceKind> requiredEvidenceKinds;

  /// Exact independently known risk codes required on the scanner finding.
  final Set<String> requiredRiskCodes;

  final OracleFindingPolicyAuthority _authority;
  final CandidateKey _candidateKey;
  final ReportExpectation _reportExpectation;
  final RemovalTruth _removalTruth;

  /// Whether [tier] is independently allowed for this case.
  bool allowsConfidenceTier(String tier) =>
      allowedConfidenceTiers.contains(tier);

  bool _matchesCase(
    CandidateKey candidateKey,
    ReportExpectation reportExpectation,
    RemovalTruth removalTruth,
  ) =>
      _authority.isCanonical &&
      _candidateKey == candidateKey &&
      _reportExpectation == reportExpectation &&
      _removalTruth == removalTruth;
}

/// One scanner-independent candidate with separate report and removal axes.
final class OracleCase {
  /// Creates a case over exact reachable and conservative retained closures.
  OracleCase({
    required this.key,
    required this.reportExpectation,
    required this.removalTruth,
    required this.findingContract,
    required Map<String, Set<String>> reachableByExecutionTarget,
    required Map<String, Set<String>> retainedByExecutionTarget,
    required List<OracleEvidence> evidence,
    required this.rationale,
  }) : reachableByExecutionTarget = _freezeClosures(reachableByExecutionTarget),
       retainedByExecutionTarget = _freezeClosures(retainedByExecutionTarget),
       evidence = List.unmodifiable(List<OracleEvidence>.from(evidence)) {
    if (rationale.isEmpty) {
      throw ArgumentError.value(rationale, 'rationale', 'must not be empty');
    }
    if (!findingContract._matchesCase(key, reportExpectation, removalTruth)) {
      throw ArgumentError(
        'finding contract must be canonically derived for the case key and truth axes',
      );
    }
    _validateEvidence();
    _validateClosuresAndTruth();
  }

  /// Candidate identity.
  final CandidateKey key;

  /// Independent finding-presence truth.
  final ReportExpectation reportExpectation;

  /// Independent deletion-authority truth.
  final RemovalTruth removalTruth;

  /// Independently derived adapter, rule, tier, predicate, and apply contract.
  final OracleFindingContract findingContract;

  /// Exact canonical-node closure for every declared execution context.
  final Map<String, Set<String>> reachableByExecutionTarget;

  /// Conservative retained canonical-node closure for every context.
  final Map<String, Set<String>> retainedByExecutionTarget;

  /// Immutable evidence used to establish this case.
  final List<OracleEvidence> evidence;

  /// Human-auditable truth rationale.
  final String rationale;

  /// Sorted configured target names in which this candidate is retained.
  List<String> get retainedIn => List.unmodifiable(
    (retainedByExecutionTarget.entries
        .where(
          (entry) =>
              entry.key.startsWith('app:') &&
              entry.value.contains(key.canonicalId),
        )
        .map((entry) => entry.key.substring(4))
        .toList()
      ..sort()),
  );

  /// Sorted full auxiliary context identities retaining this candidate.
  List<String> get auxiliaryRetainedIn => List.unmodifiable(
    (retainedByExecutionTarget.entries
        .where(
          (entry) =>
              entry.key.startsWith('aux:') &&
              entry.value.contains(key.canonicalId),
        )
        .map((entry) => entry.key)
        .toList()
      ..sort()),
  );

  /// Whether the candidate is exactly reachable in [executionTargetId].
  bool isReachableIn(String executionTargetId) =>
      reachableByExecutionTarget[executionTargetId]?.contains(
        key.canonicalId,
      ) ??
      false;

  /// Whether the candidate is conservatively retained in [executionTargetId].
  bool isRetainedIn(String executionTargetId) =>
      retainedByExecutionTarget[executionTargetId]?.contains(key.canonicalId) ??
      false;

  void _validateEvidence() {
    if (evidence.isEmpty) {
      throw ArgumentError.value(
        evidence,
        'evidence',
        'must retain independent evidence for every oracle case',
      );
    }
    final identities =
        <({OracleEvidenceKind kind, String source, String description})>{};
    for (final item in evidence) {
      final identity = (
        kind: item.kind,
        source: item.source,
        description: item.description,
      );
      if (!identities.add(identity)) {
        throw ArgumentError.value(
          evidence,
          'evidence',
          'must not contain duplicate evidence records',
        );
      }
    }
    final actualKinds = evidence.map((item) => item.kind).toSet();
    if (!actualKinds.containsAll(findingContract.requiredEvidenceKinds)) {
      throw ArgumentError.value(
        actualKinds,
        'evidence',
        'does not cover every contract-required evidence kind',
      );
    }
  }

  void _validateClosuresAndTruth() {
    final nonGraph =
        key.kind == OracleCandidateKind.duplicateGroup ||
        key.kind == OracleCandidateKind.analyzerDiagnostic;
    if (nonGraph) {
      if (reachableByExecutionTarget.isNotEmpty ||
          retainedByExecutionTarget.isNotEmpty) {
        throw ArgumentError(
          '${key.kind.name} candidates require explicit empty closures',
        );
      }
      return;
    }
    if (reachableByExecutionTarget.isEmpty ||
        retainedByExecutionTarget.isEmpty) {
      throw ArgumentError(
        'graph candidates require a declared context universe',
      );
    }
    final reachableContexts = reachableByExecutionTarget.keys.toSet();
    final retainedContexts = retainedByExecutionTarget.keys.toSet();
    if (reachableContexts.length != retainedContexts.length ||
        !reachableContexts.containsAll(retainedContexts)) {
      throw ArgumentError(
        'reachable and retained closures must declare the same context universe',
      );
    }
    if (reachableContexts.any((id) => !isCanonicalExecutionTargetId(id))) {
      throw ArgumentError(
        'closure contexts must use canonical app:/aux: identities',
      );
    }
    for (final context in reachableContexts) {
      final reachable = reachableByExecutionTarget[context]!;
      final retained = retainedByExecutionTarget[context]!;
      if (!retained.containsAll(reachable)) {
        throw ArgumentError(
          'exact reachability must be a subset of retained closure for $context',
        );
      }
    }

    final exactContexts = reachableContexts
        .where((context) => isReachableIn(context))
        .toSet();
    final retainedOnlyContexts = retainedContexts
        .where((context) => isRetainedIn(context) && !isReachableIn(context))
        .toSet();
    if (retainedOnlyContexts.any((context) => context.startsWith('app:'))) {
      throw ArgumentError(
        'configured contexts cannot contain retained-only candidate membership',
      );
    }
    if (exactContexts.isNotEmpty &&
        (reportExpectation != ReportExpectation.shouldNotReport ||
            removalTruth != RemovalTruth.retained)) {
      throw ArgumentError(
        'exact use requires shouldNotReport and retained truth',
      );
    }
    if (reportExpectation == ReportExpectation.shouldNotReport &&
        exactContexts.isEmpty) {
      throw ArgumentError(
        'shouldNotReport requires exact candidate reachability in a declared context',
      );
    }
    if (exactContexts.isEmpty &&
        retainedOnlyContexts.isNotEmpty &&
        (reportExpectation != ReportExpectation.indeterminate ||
            removalTruth != RemovalTruth.indeterminate)) {
      throw ArgumentError(
        'retained-only auxiliary presence requires indeterminate truth axes',
      );
    }
    final runtimeOrExternalRetention = retainedContexts.any(
      (context) =>
          (context.startsWith('aux:runtime:') ||
              context.startsWith('aux:external:')) &&
          isRetainedIn(context),
    );
    if (runtimeOrExternalRetention &&
        removalTruth == RemovalTruth.removableInDeclaredScope) {
      throw ArgumentError(
        'runtime or external retention cannot grant removal authority',
      );
    }
  }
}

Map<String, Set<String>> _freezeClosures(Map<String, Set<String>> closures) {
  if (closures.entries.any(
    (entry) => entry.key.isEmpty || entry.value.any((nodeId) => nodeId.isEmpty),
  )) {
    throw ArgumentError(
      'closure context and canonical node identities must not be empty',
    );
  }
  return Map.unmodifiable(
    closures.map(
      (context, nodes) =>
          MapEntry(context, Set<String>.unmodifiable(Set<String>.from(nodes))),
    ),
  );
}

/// Whether [value] is a canonical full scanner wire execution-target ID.
bool isCanonicalExecutionTargetId(String value) =>
    isCanonicalConfiguredExecutionTargetId(value) ||
    OracleAuxiliaryDomain.values.any(
      (domain) => isCanonicalAuxiliaryWireId(value, domain),
    );

/// Whether [value] is a canonical full configured-target wire ID.
bool isCanonicalConfiguredExecutionTargetId(String value) =>
    _hasNonControlSuffix(value, 'app:');

/// Whether [value] is a canonical full auxiliary-target wire ID for [domain].
bool isCanonicalAuxiliaryWireId(String value, OracleAuxiliaryDomain domain) {
  final prefix = 'aux:${domain.name}:';
  if (!_hasNonControlSuffix(value, prefix)) return false;
  final suffix = value.substring(prefix.length);
  return !suffix.startsWith('app:') && !suffix.startsWith('aux:');
}

/// Removes exactly one full auxiliary wire prefix for the logical oracle ID.
String logicalAuxiliaryIdFromWire(String value, OracleAuxiliaryDomain domain) {
  if (!isCanonicalAuxiliaryWireId(value, domain)) {
    throw ArgumentError.value(value, 'value', 'invalid auxiliary wire ID');
  }
  return '${domain.name}:${value.substring('aux:${domain.name}:'.length)}';
}

/// Whether [value] is the logical, non-wire oracle auxiliary identity.
bool isCanonicalLogicalAuxiliaryId(String value, OracleAuxiliaryDomain domain) {
  final prefix = '${domain.name}:';
  if (!_hasNonControlSuffix(value, prefix)) return false;
  final suffix = value.substring(prefix.length);
  return !suffix.startsWith('app:') && !suffix.startsWith('aux:');
}

bool _hasNonControlSuffix(String value, String prefix) =>
    value.startsWith(prefix) &&
    value.length > prefix.length &&
    !RegExp(r'[\u0000-\u001f\u007f]').hasMatch(value);
