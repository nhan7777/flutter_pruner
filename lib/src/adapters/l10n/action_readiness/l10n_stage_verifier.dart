import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../analysis/analysis_snapshot.dart';
import '../../../analysis/project_analyzer.dart';
import '../../../core/graph/node.dart';
import '../../../core/project/project_context.dart';
import '../../analyzer_adapter.dart';
import '../../dart/analyzer_diagnostic_collector.dart';
import '../../dart/dart_adapter.dart';
import '../arb_inventory.dart';
import '../l10n_adapter.dart';
import 'arb_document.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_family_preflight.dart';
import 'l10n_family_snapshot.dart';
import 'l10n_generated_member_inspector.dart';
import 'l10n_generation_config.dart';
import 'l10n_stage_inventory.dart';
import 'l10n_stage_materializer.dart';
import 'l10n_toolchain.dart';

const _verificationStage = 'stage-verification';
const _comparisonStage = 'stage-verification-comparison';
const _packageConfigPath = '.dart_tool/package_config.json';

/// Fixed, command-free verification policy for one staged l10n root.
final class L10nStageVerificationPolicy {
  /// Creates the sole schema-v1 policy.
  const L10nStageVerificationPolicy();

  /// Stable policy schema.
  static const int schemaVersion = 1;

  /// Ordered in-process verification steps.
  static const List<String> steps = <String>[
    'arb-postconditions',
    'generated-member-identity',
    'dart-l10n-graph',
    'publishable-path-immutability',
  ];

  /// Root-independent identity of [schemaVersion] and [steps].
  String get hash => _policyIdentity;
}

final String _policyIdentity = _hashCanonical(<String, Object?>{
  'schemaVersion': L10nStageVerificationPolicy.schemaVersion,
  'steps': L10nStageVerificationPolicy.steps,
});

/// One complete fixed-policy result for a baseline or candidate stage.
final class L10nStageVerificationResult {
  /// Creates a deeply immutable deterministic result.
  L10nStageVerificationResult({
    required this.accepted,
    required Iterable<L10nEvidenceFailure> failures,
    required this.policyIdentity,
    required this.analyzerRootIdentity,
    required this.packageResolutionIdentity,
    required this.toolchainIdentity,
    required this.publishableBeforeIdentity,
    required this.publishableAfterIdentity,
    required Map<String, Object?> summary,
  }) : failures = _sortedFailures(failures),
       summary = _freezeStringMap(summary) {
    if (accepted != this.failures.isEmpty) {
      throw ArgumentError(
        'accepted must be true exactly when failures is empty',
      );
    }
    for (final identity in <String>[
      policyIdentity,
      analyzerRootIdentity,
      packageResolutionIdentity,
      toolchainIdentity,
      publishableBeforeIdentity,
      publishableAfterIdentity,
    ]) {
      if (!_isSha256(identity)) {
        throw ArgumentError.value(identity, 'identity');
      }
    }
  }

  /// Whether every fixed verification step succeeded.
  final bool accepted;

  /// Deterministically sorted stable failures.
  final List<L10nEvidenceFailure> failures;

  /// Fixed policy identity.
  final String policyIdentity;

  /// Frozen analyzer closure authority after structural revalidation.
  final String analyzerRootIdentity;

  /// Frozen package-resolution authority after staged mapping validation.
  final String packageResolutionIdentity;

  /// Frozen toolchain authority used by generation and verification.
  final String toolchainIdentity;

  /// Protected-path state before verification.
  final String publishableBeforeIdentity;

  /// Protected-path state after verification.
  final String publishableAfterIdentity;

  /// Redacted immutable counts and semantic identities.
  final Map<String, Object?> summary;
}

/// Compares only authorities that baseline and candidate must share.
final class L10nStageVerificationComparator {
  const L10nStageVerificationComparator._();

  /// Returns deterministic identity mismatches without comparing intentional
  /// publishable byte differences between the two roots.
  static List<L10nEvidenceFailure> compare({
    required L10nStageVerificationResult baseline,
    required L10nStageVerificationResult candidate,
  }) {
    final failures = <L10nEvidenceFailure>[];
    void requireEqual(String left, String right, String detailCode) {
      if (left == right) return;
      failures.add(_failure(detailCode, stage: _comparisonStage));
    }

    requireEqual(
      baseline.policyIdentity,
      candidate.policyIdentity,
      'verification-policy-identity-mismatch',
    );
    requireEqual(
      baseline.analyzerRootIdentity,
      candidate.analyzerRootIdentity,
      'analyzer-root-identity-mismatch',
    );
    requireEqual(
      baseline.packageResolutionIdentity,
      candidate.packageResolutionIdentity,
      'package-resolution-identity-mismatch',
    );
    requireEqual(
      baseline.toolchainIdentity,
      candidate.toolchainIdentity,
      'toolchain-identity-mismatch',
    );
    final baselineGraph = baseline.summary['retainedL10nGraphIdentity'];
    final candidateGraph = candidate.summary['retainedL10nGraphIdentity'];
    if ((baselineGraph != null || candidateGraph != null) &&
        (baselineGraph is! String ||
            candidateGraph is! String ||
            baselineGraph != candidateGraph)) {
      failures.add(
        _failure(
          'retained-l10n-graph-identity-mismatch',
          stage: _comparisonStage,
        ),
      );
    }
    final baselineMembers = baseline.summary['retainedGeneratedMemberIdentity'];
    final candidateMembers =
        candidate.summary['retainedGeneratedMemberIdentity'];
    if ((baselineMembers != null || candidateMembers != null) &&
        (baselineMembers is! String ||
            candidateMembers is! String ||
            baselineMembers != candidateMembers)) {
      failures.add(
        _failure(
          'retained-generated-member-identity-mismatch',
          stage: _comparisonStage,
        ),
      );
    }
    return _sortedFailures(failures);
  }
}

/// Narrow in-process analyzer seam used by deterministic verifier tests.
typedef L10nStageAnalysisRunner =
    Future<AnalysisSnapshot> Function(
      ProjectContext stagedProject,
      Set<String> only,
    );

/// Verifies one staged root without package resolution or project commands.
abstract interface class L10nStageVerifier {
  /// Runs the fixed policy against one already generated stage.
  Future<L10nStageVerificationResult> verify({
    required L10nStageRoot stage,
    required L10nFamilySnapshot snapshot,
    required Set<String> expectedRemovedKeys,
    required L10nToolchainResolved toolchain,
  });
}

/// Production fixed-policy staged verifier.
final class DefaultL10nStageVerifier implements L10nStageVerifier {
  /// Creates the production verifier. The analyzer catalog is fixed internally
  /// so no generic verification runner or user command can be injected.
  DefaultL10nStageVerifier({required L10nGeneratedMemberInspector inspector})
    : _inspector = inspector,
      _analysisRunner = _runStageAnalysis;

  /// Creates a deterministic test instance with one narrow semantic seam.
  DefaultL10nStageVerifier.testing({
    required L10nGeneratedMemberInspector inspector,
    required L10nStageAnalysisRunner analysisRunner,
  }) : _inspector = inspector,
       _analysisRunner = analysisRunner;

  final L10nGeneratedMemberInspector _inspector;
  final L10nStageAnalysisRunner _analysisRunner;

  @override
  Future<L10nStageVerificationResult> verify({
    required L10nStageRoot stage,
    required L10nFamilySnapshot snapshot,
    required Set<String> expectedRemovedKeys,
    required L10nToolchainResolved toolchain,
  }) async {
    final removedKeys = SplayTreeSet<String>.of(expectedRemovedKeys);
    final protectedPaths = SplayTreeSet<String>.of(<String>{
      ...snapshot.entries.keys,
      ...stage.publishablePaths,
    });
    final failures = <L10nEvidenceFailure>[];
    final summary = <String, Object?>{
      'policySteps': L10nStageVerificationPolicy.steps,
      'stageRole': stage.role.name,
      'expectedRemovedKeys': removedKeys.toList(growable: false),
      'protectedPathCount': protectedPaths.length,
    };

    var before = L10nStageInventoryCapture.unavailable();
    var after = L10nStageInventoryCapture.unavailable();
    var beforeIdentity = _unavailableIdentity('before');
    var afterIdentity = _unavailableIdentity('after');
    ProjectContext? stagedProject;
    L10nGenerationConfig? config;

    try {
      before = await L10nStageInventory.capture(
        stage.directory,
        captureBytesFor: protectedPaths,
      );
      beforeIdentity = _protectedIdentity(before, protectedPaths);
      if (!before.valid) {
        failures.add(_failure('publishable-inventory-unavailable'));
      }

      if (failures.isEmpty) {
        _validateStageBinding(
          stage: stage,
          snapshot: snapshot,
          removedKeys: removedKeys,
          toolchain: toolchain,
          failures: failures,
        );
      }

      if (failures.isEmpty) {
        stagedProject = _stagedProject(stage, snapshot);
        _validateAnalyzerContext(stagedProject, snapshot, failures);
      }

      if (failures.isEmpty && stagedProject != null) {
        config = await _loadAndValidateConfig(
          stagedProject: stagedProject,
          snapshot: snapshot,
          toolchain: toolchain,
          failures: failures,
        );
      }

      if (failures.isEmpty && stagedProject != null) {
        _validatePackageResolution(
          inventory: before,
          stagedProject: stagedProject,
          snapshot: snapshot,
          toolchain: toolchain,
          failures: failures,
        );
      }

      if (failures.isEmpty) {
        _validateFrozenStageInputs(
          inventory: before,
          snapshot: snapshot,
          failures: failures,
        );
      }

      if (failures.isEmpty) {
        _validateAnalyzerClosure(
          inventory: before,
          snapshot: snapshot,
          failures: failures,
        );
      }

      if (failures.isEmpty) {
        final arbCount = _verifyArbs(
          inventory: before,
          snapshot: snapshot,
          removedKeys: removedKeys,
          failures: failures,
        );
        summary['arbDocumentCount'] = arbCount;
      }

      if (failures.isEmpty && stagedProject != null && config != null) {
        final inspection = await _inspector.inspect(
          stagedProject: stagedProject,
          config: config,
          expectedMemberKindsByKey: snapshot.expectedGeneratedMemberKindsByKey,
        );
        summary['generatedMemberIdentity'] = inspection.identity;
        summary['generatedMemberCount'] = inspection.membersByMessageKey.length;
        failures.addAll(inspection.failures);
        if (inspection.failures.isEmpty) {
          _validateGeneratedMembers(
            inspection: inspection,
            snapshot: snapshot,
            removedKeys: removedKeys,
            relativePath: config.baseOutputPath,
            failures: failures,
          );
          summary['retainedGeneratedMemberIdentity'] = _hashCanonical({
            'lookup': inspection.lookupIdentity,
            'members': {
              for (final key in snapshot.expectedGeneratedMemberKindsByKey.keys)
                if (!snapshot.selectedKeys.contains(key))
                  key: {
                    'kind': inspection.membersByMessageKey[key]?.name,
                    'signature': inspection.memberIdentitiesByMessageKey[key],
                  },
            },
          });
        }
      }

      if (failures.isEmpty && stagedProject != null) {
        final analysis = await _analysisRunner(stagedProject, const <String>{
          'l10n',
        });
        final failureCountBeforeAnalysisValidation = failures.length;
        _validateAnalysis(
          analysis: analysis,
          stagedProject: stagedProject,
          snapshot: snapshot,
          removedKeys: removedKeys,
          failures: failures,
        );
        if (failures.length == failureCountBeforeAnalysisValidation) {
          final allFamilyIds = _familyNodeIds(
            stagedProject,
            snapshot,
            const {},
          );
          if (stage.role == L10nStageRole.baseline) {
            final baselineIdentity = const L10nAnalysisFingerprintProjector()
                .project(analysis: analysis, familyNodeIds: allFamilyIds);
            if (baselineIdentity != snapshot.l10nAnalysisFingerprint) {
              failures.add(_failure('baseline-l10n-graph-identity-mismatch'));
            }
          }
          final retainedIds = _familyNodeIds(
            stagedProject,
            snapshot,
            snapshot.selectedKeys,
          );
          summary['retainedL10nGraphIdentity'] =
              const L10nAnalysisFingerprintProjector().project(
                analysis: analysis,
                familyNodeIds: retainedIds,
              );
        }
        summary['analyzerAdapterIds'] = analysis.adapterIds;
        summary['graphNodeCount'] = analysis.graph.nodeCount;
        summary['graphEdgeCount'] = analysis.graph.edgeCount;
        summary['graphBlockerCount'] = analysis.graph.blockers.length;
      }
    } on Object {
      failures.add(
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.internalFailure,
          stage: _verificationStage,
          detailCode: 'stage-verification-internal-failure',
        ),
      );
    } finally {
      try {
        after = await L10nStageInventory.capture(
          stage.directory,
          captureBytesFor: protectedPaths,
        );
        afterIdentity = _protectedIdentity(after, protectedPaths);
        if (!after.valid) {
          failures.add(_failure('publishable-inventory-unavailable'));
        }
        if (after.valid && stagedProject != null) {
          _validatePackageResolution(
            inventory: after,
            stagedProject: stagedProject,
            snapshot: snapshot,
            toolchain: toolchain,
            failures: failures,
          );
        }
        for (final path in _changedProtectedPaths(
          before,
          after,
          protectedPaths,
        )) {
          failures.add(
            _failure('publishable-path-mutated', relativePath: path),
          );
        }
      } on Object {
        failures.add(_failure('publishable-inventory-unavailable'));
      }
    }

    summary['publishableBeforeIdentity'] = beforeIdentity;
    summary['publishableAfterIdentity'] = afterIdentity;
    final frozenFailures = _sortedFailures(failures);
    final resultToolchainIdentity = _isSha256(toolchain.identitySha256)
        ? toolchain.identitySha256
        : _unavailableIdentity('toolchain');
    return L10nStageVerificationResult(
      accepted: frozenFailures.isEmpty,
      failures: frozenFailures,
      policyIdentity: const L10nStageVerificationPolicy().hash,
      analyzerRootIdentity: snapshot.verificationClosure.analyzerRootIdentity,
      packageResolutionIdentity: snapshot.packageResolutionIdentity,
      toolchainIdentity: resultToolchainIdentity,
      publishableBeforeIdentity: beforeIdentity,
      publishableAfterIdentity: afterIdentity,
      summary: summary,
    );
  }
}

Future<AnalysisSnapshot> _runStageAnalysis(
  ProjectContext project,
  Set<String> only,
) => ProjectAnalyzer(
  project: project,
  only: only,
  adapterCatalog: <AnalyzerAdapter>[
    DartAdapter(collectAnalyzerDiagnostics: _skipAnalyzerDiagnostics),
    const L10nAdapter(),
  ],
).analyze();

Future<AnalyzerDiagnosticCollection> _skipAnalyzerDiagnostics(
  ProjectContext _,
) async => const AnalyzerDiagnosticCollection.skipped();

void _validateStageBinding({
  required L10nStageRoot stage,
  required L10nFamilySnapshot snapshot,
  required Set<String> removedKeys,
  required L10nToolchainResolved toolchain,
  required List<L10nEvidenceFailure> failures,
}) {
  if (!stage.safeToDelete) {
    failures.add(_failure('stage-root-unsafe'));
  } else if (!stage.revalidateIdentity()) {
    failures.add(_failure('stage-root-identity-drift'));
  }
  try {
    final requested = p.normalize(p.absolute(stage.directory.path));
    final canonical = p.normalize(stage.directory.resolveSymbolicLinksSync());
    if (requested != canonical) {
      failures.add(_failure('stage-root-identity-drift'));
    }
  } on FileSystemException {
    failures.add(_failure('stage-root-identity-drift'));
  }
  if (stage.toolchainIdentity != snapshot.toolchainIdentity ||
      toolchain.identitySha256 != snapshot.toolchainIdentity) {
    failures.add(
      const L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.toolchainDrift,
        stage: _verificationStage,
        detailCode: 'stage-toolchain-identity-mismatch',
      ),
    );
  }
  final expected = stage.role == L10nStageRole.baseline
      ? const <String>{}
      : snapshot.selectedKeys;
  if (!_sameStrings(expected, removedKeys)) {
    failures.add(_failure('verification-selection-mismatch'));
  }
}

ProjectContext _stagedProject(
  L10nStageRoot stage,
  L10nFamilySnapshot snapshot,
) {
  final semantics = snapshot.projectSemantics;
  return ProjectContext(
    root: stage.directory,
    pubspec: semantics.pubspec,
    packageName: semantics.packageName,
    analysisMode: semantics.analysisMode,
    targetMatrix: semantics.targetMatrix,
    rootCoverage: semantics.rootCoverage,
  );
}

void _validateAnalyzerContext(
  ProjectContext project,
  L10nFamilySnapshot snapshot,
  List<L10nEvidenceFailure> failures,
) {
  final result = const L10nAnalyzerContextAuthorityProjector().project(project);
  switch (result) {
    case L10nAnalyzerContextAuthorityProjectionRejected(:final failure):
      failures.add(
        _failure(
          'analyzer-context-authority-invalid',
          relativePath: failure.relativePath,
        ),
      );
    case L10nAnalyzerContextAuthorityProjectionReady(:final projection):
      if (projection.identity !=
          snapshot.analysisOptionsProjection.contextAuthorityIdentity) {
        failures.add(_failure('analyzer-context-authority-mismatch'));
      }
  }
}

Future<L10nGenerationConfig?> _loadAndValidateConfig({
  required ProjectContext stagedProject,
  required L10nFamilySnapshot snapshot,
  required L10nToolchainResolved toolchain,
  required List<L10nEvidenceFailure> failures,
}) async {
  final loaded = await const DefaultL10nGenerationConfigLoader().load(
    project: stagedProject,
    toolchain: toolchain.machineIdentity,
  );
  switch (loaded) {
    case L10nGenerationConfigRejected(failures: final rejectedFailures):
      // Preserve the strict loader's typed failure identities.
      failures.addAll(rejectedFailures);
      return null;
    case L10nGenerationConfigReady(:final config):
      if (config.configurationIdentity != snapshot.configurationIdentity) {
        failures.add(_failure('configuration-identity-mismatch'));
        return null;
      }
      return config;
  }
}

void _validatePackageResolution({
  required L10nStageInventoryCapture inventory,
  required ProjectContext stagedProject,
  required L10nFamilySnapshot snapshot,
  required L10nToolchainResolved toolchain,
  required List<L10nEvidenceFailure> failures,
}) {
  final entry = inventory.entries[_packageConfigPath];
  final bytes = entry?.capturedBytes;
  if (entry?.kind != L10nStageEntryKind.regularFile || bytes == null) {
    failures.add(
      const L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.packageResolutionDrift,
        stage: _verificationStage,
        detailCode: 'package-config-unavailable',
        relativePath: _packageConfigPath,
      ),
    );
    return;
  }
  final result = const L10nPackageConfigProjector().project(
    sourceBytes: bytes.copy(),
    canonicalProjectRoot: stagedProject.root.resolveSymbolicLinksSync(),
    selectedPackageName: stagedProject.packageName,
    toolchain: toolchain,
  );
  switch (result) {
    case L10nPackageConfigProjectionRejected(:final failure):
      failures.add(
        L10nEvidenceFailure(
          code: failure.code,
          stage: _verificationStage,
          detailCode: failure.detailCode == 'selected-package-root-mismatch'
              ? 'selected-package-root-not-stage'
              : failure.detailCode,
          relativePath: _packageConfigPath,
        ),
      );
    case L10nPackageConfigProjectionReady(:final projection):
      if (projection.authorityIdentity !=
          snapshot.packageConfigProjectionIdentity) {
        failures.add(
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.packageResolutionDrift,
            stage: _verificationStage,
            detailCode: 'package-authority-identity-mismatch',
            relativePath: _packageConfigPath,
          ),
        );
      }
  }
}

void _validateAnalyzerClosure({
  required L10nStageInventoryCapture inventory,
  required L10nFamilySnapshot snapshot,
  required List<L10nEvidenceFailure> failures,
}) {
  final expected = snapshot.verificationClosure.projectOwnedDartPaths;
  final actual = <String>{
    for (final entry in inventory.entries.entries)
      if (entry.value.kind == L10nStageEntryKind.regularFile &&
          entry.key.endsWith('.dart'))
        entry.key,
  };
  final changed = <String>{
    ...expected.where((path) => !actual.contains(path)),
    ...actual.where((path) => !expected.contains(path)),
  }.toList()..sort();
  for (final path in changed) {
    failures.add(_failure('analyzer-closure-incomplete', relativePath: path));
  }
  if (changed.isNotEmpty) return;

  for (final path in expected) {
    final snapshotEntry = snapshot.entries[path];
    if (snapshotEntry == null || snapshotEntry.state is! L10nSnapshotPresent) {
      failures.add(_failure('analyzer-closure-incomplete', relativePath: path));
      continue;
    }
    if (snapshotEntry.role != L10nSnapshotRole.analyzerSource) continue;
    final expectedState = snapshotEntry.state as L10nSnapshotPresent;
    final actualEntry = inventory.entries[path]!;
    if (actualEntry.sha256 != expectedState.stageBytes.sha256Hex ||
        actualEntry.posixMode != expectedState.posixMode) {
      failures.add(
        _failure('analyzer-closure-identity-drift', relativePath: path),
      );
    }
  }
}

void _validateFrozenStageInputs({
  required L10nStageInventoryCapture inventory,
  required L10nFamilySnapshot snapshot,
  required List<L10nEvidenceFailure> failures,
}) {
  for (final snapshotEntry in snapshot.entries.values) {
    if (_hasDedicatedStageValidation(snapshotEntry.role)) continue;
    final actual = inventory.entries[snapshotEntry.relativePosixPath];
    final expected = snapshotEntry.state;
    final matches = switch (expected) {
      L10nSnapshotAbsent() => actual == null,
      L10nSnapshotPresent() =>
        actual?.kind == L10nStageEntryKind.regularFile &&
            actual?.sha256 == expected.stageBytes.sha256Hex &&
            actual?.posixMode == expected.posixMode,
    };
    if (matches) continue;

    final packageAuthority =
        snapshotEntry.role == L10nSnapshotRole.lockfile ||
        snapshotEntry.role == L10nSnapshotRole.packageConfig ||
        snapshotEntry.role == L10nSnapshotRole.packageGraph;
    failures.add(
      L10nEvidenceFailure(
        code: packageAuthority
            ? L10nEvidenceRejectionCode.packageResolutionDrift
            : L10nEvidenceRejectionCode.candidateVerificationFailed,
        stage: _verificationStage,
        detailCode: packageAuthority
            ? 'staged-package-input-drift'
            : 'staged-verification-input-drift',
        relativePath: snapshotEntry.relativePosixPath,
      ),
    );
  }
}

bool _hasDedicatedStageValidation(L10nSnapshotRole role) => switch (role) {
  L10nSnapshotRole.arbTemplate ||
  L10nSnapshotRole.arbLocale ||
  L10nSnapshotRole.generatedBase ||
  L10nSnapshotRole.generatedLanguage ||
  L10nSnapshotRole.untranslatedSidecar ||
  L10nSnapshotRole.analyzerSource => true,
  _ => false,
};

int _verifyArbs({
  required L10nStageInventoryCapture inventory,
  required L10nFamilySnapshot snapshot,
  required Set<String> removedKeys,
  required List<L10nEvidenceFailure> failures,
}) {
  var count = 0;
  for (final entry in snapshot.entries.values) {
    if (entry.role != L10nSnapshotRole.arbTemplate &&
        entry.role != L10nSnapshotRole.arbLocale) {
      continue;
    }
    count++;
    final path = entry.relativePosixPath;
    final originalState = entry.state;
    final currentBytes = inventory.entries[path]?.capturedBytes;
    if (originalState is! L10nSnapshotPresent || currentBytes == null) {
      failures.add(_failure('candidate-arb-missing', relativePath: path));
      continue;
    }
    final currentParsed = ArbDocument.parse(currentBytes.copy());
    if (currentParsed is! ArbParseSuccess) {
      failures.add(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.arbParseFailure,
          stage: _verificationStage,
          detailCode: 'candidate-arb-parse-failed',
          relativePath: path,
        ),
      );
      continue;
    }
    final originalParsed = ArbDocument.parse(originalState.stageBytes.copy());
    if (originalParsed is! ArbParseSuccess) {
      failures.add(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.internalFailure,
          stage: _verificationStage,
          detailCode: 'snapshot-arb-parse-failed',
          relativePath: path,
        ),
      );
      continue;
    }
    final current = currentParsed.document;
    var selectedFailure = false;
    for (final key in removedKeys) {
      if (current.member(key) != null) {
        failures.add(
          _failure('selected-arb-member-present', relativePath: path),
        );
        selectedFailure = true;
        break;
      }
      if (current.member('@$key') != null) {
        failures.add(
          _failure('selected-arb-companion-present', relativePath: path),
        );
        selectedFailure = true;
        break;
      }
    }
    if (selectedFailure) continue;

    final original = originalParsed.document;
    final retainedOriginal = <String, ArbMember>{
      for (final member in original.members)
        if (!_selectedArbMember(member.decodedKey, removedKeys))
          member.decodedKey: member,
    };
    final retainedCurrent = <String, ArbMember>{
      for (final member in current.members)
        if (!_selectedArbMember(member.decodedKey, removedKeys))
          member.decodedKey: member,
    };
    var drift = !_sameStrings(
      retainedOriginal.keys.toSet(),
      retainedCurrent.keys.toSet(),
    );
    if (!drift) {
      for (final key in retainedOriginal.keys) {
        final left = original.source.slice(retainedOriginal[key]!.memberSpan);
        final right = current.source.slice(retainedCurrent[key]!.memberSpan);
        if (!left.contentEquals(right)) {
          drift = true;
          break;
        }
      }
    }
    if (drift) {
      failures.add(_failure('retained-arb-token-drift', relativePath: path));
    }
  }
  return count;
}

bool _selectedArbMember(String key, Set<String> removedKeys) =>
    removedKeys.contains(key) ||
    (key.startsWith('@') &&
        !key.startsWith('@@') &&
        removedKeys.contains(key.substring(1)));

void _validateGeneratedMembers({
  required L10nGeneratedMemberInspection inspection,
  required L10nFamilySnapshot snapshot,
  required Set<String> removedKeys,
  required String relativePath,
  required List<L10nEvidenceFailure> failures,
}) {
  for (final key in removedKeys) {
    if (inspection.membersByMessageKey.containsKey(key)) {
      failures.add(
        _failure(
          'selected-generated-member-present',
          relativePath: relativePath,
        ),
      );
    }
  }
  for (final expected in snapshot.expectedGeneratedMemberKindsByKey.entries) {
    if (removedKeys.contains(expected.key)) continue;
    final actual = inspection.membersByMessageKey[expected.key];
    if (actual == null) {
      failures.add(
        _failure(
          'retained-generated-member-missing',
          relativePath: relativePath,
        ),
      );
    } else if (actual != expected.value) {
      failures.add(
        _failure(
          'retained-generated-member-shape-mismatch',
          relativePath: relativePath,
        ),
      );
    }
  }
}

void _validateAnalysis({
  required AnalysisSnapshot analysis,
  required ProjectContext stagedProject,
  required L10nFamilySnapshot snapshot,
  required Set<String> removedKeys,
  required List<L10nEvidenceFailure> failures,
}) {
  if (!identical(analysis.project, stagedProject) ||
      analysis.project.root.resolveSymbolicLinksSync() !=
          stagedProject.root.resolveSymbolicLinksSync()) {
    failures.add(_failure('staged-analysis-root-mismatch'));
    return;
  }
  if (analysis.adapterIds.length != 2 ||
      analysis.adapterIds[0] != 'dart' ||
      analysis.adapterIds[1] != 'l10n') {
    failures.add(_failure('staged-analysis-adapter-set-mismatch'));
    return;
  }
  if (!analysis.graphIntegrity.complete) {
    failures.add(_failure('staged-graph-integrity-incomplete'));
    return;
  }

  final namespace = ArbInventory.namespaceFor(stagedProject);
  final allFamilyIds = _familyNodeIds(stagedProject, snapshot, const {});
  final familyBlocker = analysis.graph.blockers.any(
    (blocker) => allFamilyIds.any(blocker.couldAddress),
  );
  if (familyBlocker) {
    failures.add(
      const L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.scanBlockerPresent,
        stage: _verificationStage,
        detailCode: 'staged-l10n-blocker',
      ),
    );
    return;
  }

  final expectedKinds = <String, ArbGeneratedMemberKind>{
    for (final entry in snapshot.expectedGeneratedMemberKindsByKey.entries)
      if (!removedKeys.contains(entry.key)) entry.key: entry.value,
  };
  final expectedIds = <String>{
    for (final key in expectedKinds.keys)
      '$namespace${Uri.encodeComponent(key)}',
  };
  final actualNodes = analysis.graph
      .nodesOfKind(NodeKind.localizationKey)
      .where((node) => node.id.startsWith(namespace))
      .toList(growable: false);
  if (!_sameStrings(expectedIds, actualNodes.map((node) => node.id).toSet())) {
    failures.add(_failure('staged-l10n-graph-mismatch'));
    return;
  }
  for (final node in actualNodes) {
    final key = node.metadata['key'];
    if (key is! String ||
        expectedKinds[key]?.name != node.metadata['memberKind'] ||
        analysis.graph.nodeOwner(node.id) != 'l10n') {
      failures.add(_failure('staged-l10n-graph-mismatch'));
      return;
    }
  }
}

Set<String> _familyNodeIds(
  ProjectContext project,
  L10nFamilySnapshot snapshot,
  Set<String> excludedKeys,
) {
  final namespace = ArbInventory.namespaceFor(project);
  return SplayTreeSet<String>.of(
    snapshot.expectedGeneratedMemberKindsByKey.keys
        .where((key) => !excludedKeys.contains(key))
        .map((key) => '$namespace${Uri.encodeComponent(key)}'),
  );
}

String _protectedIdentity(
  L10nStageInventoryCapture inventory,
  Set<String> protectedPaths,
) => _hashCanonical(<String, Object?>{
  'valid': inventory.valid,
  'paths': <String, Object?>{
    for (final path in protectedPaths)
      path: _stableEntryIdentity(inventory.entries[path]),
  },
  'invalidProtectedPaths': <String>[
    for (final path in inventory.invalidPaths)
      if (path == '.' || protectedPaths.contains(path)) path,
  ],
});

Map<String, Object?> _stableEntryIdentity(L10nStageEntry? entry) =>
    entry == null
    ? const <String, Object?>{'kind': 'absent'}
    : <String, Object?>{
        'kind': entry.kind.name,
        'sha256': entry.sha256,
        'posixMode': entry.posixMode,
      };

Map<String, Object?> _mutationEntryIdentity(L10nStageEntry? entry) => {
  ..._stableEntryIdentity(entry),
  'authorityIdentity': entry?.authorityIdentity,
};

List<String> _changedProtectedPaths(
  L10nStageInventoryCapture before,
  L10nStageInventoryCapture after,
  Set<String> protectedPaths,
) => <String>[
  for (final path in protectedPaths)
    if (jsonEncode(_mutationEntryIdentity(before.entries[path])) !=
        jsonEncode(_mutationEntryIdentity(after.entries[path])))
      path,
];

String _unavailableIdentity(String phase) =>
    _hashCanonical(<String, Object?>{'unavailable': phase});

L10nEvidenceFailure _failure(
  String detailCode, {
  String stage = _verificationStage,
  String? relativePath,
}) => L10nEvidenceFailure(
  code: L10nEvidenceRejectionCode.candidateVerificationFailed,
  stage: stage,
  detailCode: detailCode,
  relativePath: relativePath,
);

List<L10nEvidenceFailure> _sortedFailures(
  Iterable<L10nEvidenceFailure> source,
) {
  final sorted = List<L10nEvidenceFailure>.of(source)..sort(_compareFailures);
  final result = <L10nEvidenceFailure>[];
  for (final failure in sorted) {
    if (result.isEmpty || _compareFailures(result.last, failure) != 0) {
      result.add(failure);
    }
  }
  return List<L10nEvidenceFailure>.unmodifiable(result);
}

int _compareFailures(L10nEvidenceFailure left, L10nEvidenceFailure right) {
  var comparison = left.code.index.compareTo(right.code.index);
  if (comparison != 0) return comparison;
  comparison = left.stage.compareTo(right.stage);
  if (comparison != 0) return comparison;
  comparison = _compareNullable(left.relativePath, right.relativePath);
  if (comparison != 0) return comparison;
  return left.detailCode.compareTo(right.detailCode);
}

int _compareNullable(String? left, String? right) {
  if (left == null) return right == null ? 0 : -1;
  if (right == null) return 1;
  return left.compareTo(right);
}

Map<String, Object?> _freezeStringMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable(
      SplayTreeMap<String, Object?>.of(<String, Object?>{
        for (final entry in source.entries)
          entry.key: _freezeValue(entry.value),
      }),
    );

Object? _freezeValue(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Map) {
    final entries = value.entries.toList()
      ..sort((left, right) => '${left.key}'.compareTo('${right.key}'));
    return Map<Object?, Object?>.unmodifiable(<Object?, Object?>{
      for (final entry in entries) entry.key: _freezeValue(entry.value),
    });
  }
  if (value is Iterable) {
    return List<Object?>.unmodifiable(value.map<Object?>(_freezeValue));
  }
  throw ArgumentError.value(value, 'summary', 'contains unsupported value');
}

String _hashCanonical(Map<String, Object?> value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

bool _sameStrings(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
