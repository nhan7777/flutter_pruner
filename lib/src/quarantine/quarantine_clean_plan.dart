import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'clean_move_backend.dart';
import 'manifest_authority.dart';

/// Whether a clean preview addresses one explicit run or every selected run.
enum CleanScope {
  /// One explicit quarantine run.
  targeted,

  /// Every cleanable run in the selected quarantine bases.
  all,
}

/// Filesystem and journal evidence for one reviewed clean target.
final class QuarantineCleanTarget {
  /// Creates immutable evidence for a single quarantine run.
  const QuarantineCleanTarget({
    required this.runId,
    required this.canonicalPath,
    required this.layoutSha256,
    required this.journalRevision,
    required this.payloadSha256,
    required this.authority,
    required this.repairAction,
    this.rootIdentity,
    this.retainedDestinationComponents = const <String>[],
  });

  /// Validated run identifier.
  final String runId;

  /// Canonical absolute quarantine directory path.
  final String canonicalPath;

  /// Complete portable no-follow tree digest.
  final String layoutSha256;

  /// Authoritative manifest journal revision.
  final int journalRevision;

  /// Authoritative manifest payload checksum.
  final String payloadSha256;

  /// Manifest candidate selected by the read-only authority decision.
  final ManifestCandidateName authority;

  /// Repair a later mutating resolver would need to perform.
  final ManifestRepairAction repairAction;

  /// Stable root identity required by the recoverable logical-move backend.
  final CleanObjectIdentity? rootIdentity;

  /// Base-relative retained destination bound into a logical-clean plan.
  final List<String> retainedDestinationComponents;

  Map<String, Object?> _toCanonicalJson({required int version}) =>
      <String, Object?>{
        'runId': runId,
        'canonicalPath': canonicalPath,
        'layoutSha256': layoutSha256,
        'journalRevision': journalRevision,
        'payloadSha256': payloadSha256,
        'authority': authority.name,
        'repairAction': repairAction.name,
        if (version >= 2) 'rootIdentity': rootIdentity?.toJson(),
        if (version >= 2)
          'retainedDestinationComponents': retainedDestinationComponents,
      };
}

/// Truthful disclosure of the currently shipped recursive-delete backend.
final class CleanBackendDisclosure {
  /// Creates a backend disclosure.
  const CleanBackendDisclosure({
    required this.name,
    required this.batchAtomic,
    required this.identityBoundDelete,
    required this.crashRecoverableReceipt,
    required this.releaseEligible,
    required this.blockerCode,
    this.identityBoundMove = false,
    this.physicalDelete = true,
  });

  /// Version of the disclosure fields included in clean fingerprints.
  static const int version = 1;

  /// Existing backend retained for compatibility; not new execution authority.
  static const CleanBackendDisclosure currentRecursiveDelete =
      CleanBackendDisclosure(
        name: 'currentRecursiveDelete',
        batchAtomic: false,
        identityBoundDelete: false,
        identityBoundMove: false,
        physicalDelete: true,
        crashRecoverableReceipt: false,
        releaseEligible: false,
        blockerCode: 'CLEAN-TOCTOU-1',
      );

  /// Recoverable logical move retained while hosted evidence is pending.
  static const CleanBackendDisclosure recoverableLogicalMove =
      CleanBackendDisclosure(
        name: 'recoverableLogicalMove',
        batchAtomic: false,
        identityBoundDelete: false,
        identityBoundMove: true,
        physicalDelete: false,
        crashRecoverableReceipt: true,
        releaseEligible: false,
        blockerCode: 'CLEAN-TOCTOU-1',
      );

  /// Stable backend name.
  final String name;

  /// Whether a multi-target cleanup is atomic.
  final bool batchAtomic;

  /// Whether deletion is bound to the identity validated by the planner.
  final bool identityBoundDelete;

  /// Whether the logical move is bound to the validated root identity.
  final bool identityBoundMove;

  /// Whether this backend physically destroys retained bytes.
  final bool physicalDelete;

  /// Whether a crash leaves a durable, recoverable outcome receipt.
  final bool crashRecoverableReceipt;

  /// Whether this backend is eligible for the new destructive clean flow.
  final bool releaseEligible;

  /// Release blocker that prevents production integration, when any.
  final String? blockerCode;

  Map<String, Object?> _toCanonicalJson({required int planVersion}) =>
      <String, Object?>{
        'version': planVersion,
        'name': name,
        'batchAtomic': batchAtomic,
        'identityBoundDelete': identityBoundDelete,
        if (planVersion >= 2) 'identityBoundMove': identityBoundMove,
        if (planVersion >= 2) 'physicalDelete': physicalDelete,
        'crashRecoverableReceipt': crashRecoverableReceipt,
        'releaseEligible': releaseEligible,
        'blockerCode': blockerCode,
      };
}

/// Immutable, non-destructive preview of quarantine evidence to be cleaned.
///
/// The fingerprint detects changes observed between planning calls. It is not
/// a pathname lease, an identity-bound delete capability, or authority to call
/// a recursive-delete backend.
final class QuarantineCleanPlan {
  QuarantineCleanPlan._({
    required this.fingerprint,
    required this.scope,
    required List<String> canonicalBases,
    required List<QuarantineCleanTarget> targets,
    required this.backend,
  }) : canonicalBases = List<String>.unmodifiable(canonicalBases),
       targets = List<QuarantineCleanTarget>.unmodifiable(targets);

  /// Builds and fingerprints an already validated plan projection.
  factory QuarantineCleanPlan.fromEvidence({
    required CleanScope scope,
    required List<String> canonicalBases,
    required List<QuarantineCleanTarget> targets,
    CleanBackendDisclosure backend =
        CleanBackendDisclosure.currentRecursiveDelete,
  }) {
    final logicalPlan =
        backend.name == CleanBackendDisclosure.recoverableLogicalMove.name ||
        targets.any(
          (target) =>
              target.rootIdentity != null ||
              target.retainedDestinationComponents.isNotEmpty,
        );
    final fingerprintVersion = logicalPlan ? 2 : 1;
    if (logicalPlan) {
      for (final target in targets) {
        if (target.rootIdentity == null ||
            target.retainedDestinationComponents.isEmpty) {
          throw ArgumentError(
            'Logical clean targets require identity and destination evidence.',
          );
        }
        for (final component in target.retainedDestinationComponents) {
          validateCleanPathComponent(component);
        }
      }
    }
    final sortedBases = canonicalBases.toSet().toList()..sort();
    final sortedTargets = List<QuarantineCleanTarget>.of(targets)
      ..sort((left, right) {
        final runId = left.runId.compareTo(right.runId);
        return runId == 0
            ? left.canonicalPath.compareTo(right.canonicalPath)
            : runId;
      });
    final canonical = <String, Object?>{
      'version': fingerprintVersion,
      'scope': scope.name,
      'canonicalBases': sortedBases,
      'targets': sortedTargets
          .map((target) => target._toCanonicalJson(version: fingerprintVersion))
          .toList(growable: false),
      'backend': backend._toCanonicalJson(planVersion: fingerprintVersion),
    };
    final digest = sha256
        .convert(utf8.encode(jsonEncode(canonical)))
        .toString();
    return QuarantineCleanPlan._(
      fingerprint: 'v$fingerprintVersion:$digest',
      scope: scope,
      canonicalBases: sortedBases,
      targets: sortedTargets,
      backend: backend,
    );
  }

  /// Clean-plan fingerprint schema version.
  static const int version = 2;

  /// Versioned fingerprint over this exact evidence projection.
  final String fingerprint;

  /// Whether the plan targets one run or all selected runs.
  final CleanScope scope;

  /// Sorted, canonical quarantine bases included in discovery.
  final List<String> canonicalBases;

  /// Deterministically ordered, fully validated clean targets.
  final List<QuarantineCleanTarget> targets;

  /// Backend limitations bound into [fingerprint].
  final CleanBackendDisclosure backend;
}
