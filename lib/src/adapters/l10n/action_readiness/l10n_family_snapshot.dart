import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/project/analysis_mode.dart';
import '../../../core/project/target_matrix.dart';
import '../arb_inventory.dart';
import 'arb_document.dart';
import 'immutable_bytes.dart';
import 'l10n_arb_mutation_planner.dart';
import 'l10n_evidence_failure.dart';

/// Why one path is retained in an immutable l10n family snapshot.
enum L10nSnapshotRole {
  /// Project package manifest.
  pubspec,

  /// Frozen dependency lock authority.
  lockfile,

  /// Strict l10n.yaml authority, including explicit absence.
  l10nConfig,

  /// Configured template ARB.
  arbTemplate,

  /// Non-template ARB in the same configured family.
  arbLocale,

  /// Configured header-file input.
  header,

  /// Primary generated localization library.
  generatedBase,

  /// One generated base-language library.
  generatedLanguage,

  /// Optional untranslated-message sidecar.
  untranslatedSidecar,

  /// Live and stage-projected package configuration.
  packageConfig,

  /// Optional package-graph provenance.
  packageGraph,

  /// Project-owned Dart source in the analyzer closure.
  analyzerSource,

  /// Other finite input required by the fixed staged verifier.
  verificationInput,
}

/// Exact file state retained by the snapshot.
sealed class L10nSnapshotFileState {
  const L10nSnapshotFileState();
}

/// Exact present source bytes and the bytes installed into staging.
final class L10nSnapshotPresent extends L10nSnapshotFileState {
  /// Defensively copies both byte authorities and verifies [sourceSha256].
  L10nSnapshotPresent({
    required ImmutableBytes sourceBytes,
    required ImmutableBytes stageBytes,
    required this.sourceSha256,
    required this.posixMode,
  }) : sourceBytes = ImmutableBytes.copyOf(sourceBytes.copy()),
       stageBytes = ImmutableBytes.copyOf(stageBytes.copy()) {
    if (this.sourceBytes.sha256Hex != sourceSha256) {
      throw ArgumentError.value(
        sourceSha256,
        'sourceSha256',
        'must identify sourceBytes exactly',
      );
    }
    if (posixMode != null && (posixMode! < 0 || posixMode! > 0xfff)) {
      throw ArgumentError.value(posixMode, 'posixMode');
    }
  }

  /// Exact immutable bytes read from the selected project.
  final ImmutableBytes sourceBytes;

  /// Exact immutable bytes installed into a later stage.
  final ImmutableBytes stageBytes;

  /// SHA-256 of [sourceBytes].
  final String sourceSha256;

  /// Permission bits on POSIX, or null where POSIX modes are unavailable.
  final int? posixMode;
}

/// Explicitly records that a configured path did not exist.
final class L10nSnapshotAbsent extends L10nSnapshotFileState {
  /// Creates an explicit absence value.
  const L10nSnapshotAbsent();
}

/// One canonical project-relative path and its single primary role.
final class L10nSnapshotEntry {
  /// Creates a validated immutable entry.
  L10nSnapshotEntry({
    required this.relativePosixPath,
    required this.role,
    required this.state,
  }) {
    if (!_isSafeRelativePosixPath(relativePosixPath)) {
      throw ArgumentError.value(
        relativePosixPath,
        'relativePosixPath',
        'must be a canonical relative POSIX path',
      );
    }
  }

  /// Canonical path beneath the selected project root.
  final String relativePosixPath;

  /// Primary materialization/verification role for this path.
  final L10nSnapshotRole role;

  /// Exact present bytes or explicit absence.
  final L10nSnapshotFileState state;
}

/// Frozen project-owned analyzer enumeration and its byte identity.
final class L10nVerificationClosure {
  /// Defensively snapshots one complete project-owned Dart closure.
  L10nVerificationClosure({
    required Set<String> projectOwnedDartPaths,
    required this.analyzerRootIdentity,
  }) : projectOwnedDartPaths = _sortedSet(projectOwnedDartPaths) {
    if (!_isSha256(analyzerRootIdentity)) {
      throw ArgumentError.value(analyzerRootIdentity, 'analyzerRootIdentity');
    }
    if (this.projectOwnedDartPaths.any(
      (path) => !_isSafeRelativePosixPath(path) || !path.endsWith('.dart'),
    )) {
      throw ArgumentError.value(projectOwnedDartPaths, 'projectOwnedDartPaths');
    }
  }

  /// Every project-owned Dart file enumerated by a fresh analyzer workspace.
  final Set<String> projectOwnedDartPaths;

  /// Framed identity of every closure path, byte hash, and mode.
  final String analyzerRootIdentity;
}

/// One external analyzer-options file retained as a re-readable authority.
final class L10nExternalAnalysisOptionsAuthority {
  /// Creates an immutable external analyzer-options record.
  L10nExternalAnalysisOptionsAuthority({
    required this.canonicalPath,
    required this.authorityRoot,
    required ImmutableBytes sourceBytes,
    required this.posixMode,
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
  }) : sourceBytes = ImmutableBytes.copyOf(sourceBytes.copy()) {
    if (!p.isAbsolute(canonicalPath) ||
        !p.isAbsolute(authorityRoot) ||
        p.normalize(canonicalPath) != canonicalPath ||
        p.normalize(authorityRoot) != authorityRoot ||
        !p.isWithin(authorityRoot, canonicalPath)) {
      throw ArgumentError('External options authority path is invalid.');
    }
    if (posixMode != null && (posixMode! < 0 || posixMode! > 0xfff)) {
      throw ArgumentError.value(posixMode, 'posixMode');
    }
    if (size != this.sourceBytes.length ||
        modifiedMicros < 0 ||
        changedMicros < 0) {
      throw ArgumentError('External options authority facts are invalid.');
    }
  }

  /// Canonical absolute file path, retained only in this internal seam.
  final String canonicalPath;

  /// Canonical package root bounding [canonicalPath].
  final String authorityRoot;

  /// Exact bytes observed at capture.
  final ImmutableBytes sourceBytes;

  /// Permission bits on POSIX, or null on other platforms.
  final int? posixMode;

  /// Exact byte length observed at capture.
  final int size;

  /// Filesystem modification time observed at capture.
  final int modifiedMicros;

  /// Filesystem metadata-change time observed at capture.
  final int changedMicros;

  /// SHA-256 of [sourceBytes].
  String get sourceSha256 => sourceBytes.sha256Hex;

  Map<String, Object?> get _identity => {
    'canonicalPath': canonicalPath,
    'authorityRoot': authorityRoot,
    'sourceSha256': sourceSha256,
    'posixMode': posixMode,
    'size': size,
  };

  bool _matchesLive() {
    if (FileSystemEntity.typeSync(canonicalPath, followLinks: false) !=
        FileSystemEntityType.file) {
      return false;
    }
    final file = File(canonicalPath);
    final canonicalBefore = p.normalize(file.resolveSymbolicLinksSync());
    if (canonicalBefore != canonicalPath ||
        !p.isWithin(authorityRoot, canonicalBefore)) {
      return false;
    }
    final before = file.statSync();
    final bytes = file.readAsBytesSync();
    final after = file.statSync();
    final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
    final mode = Platform.isWindows ? null : before.mode & 0xfff;
    return canonicalAfter == canonicalBefore &&
        before.type == after.type &&
        before.size == after.size &&
        before.mode == after.mode &&
        before.modified == after.modified &&
        before.changed == after.changed &&
        mode == posixMode &&
        before.size == size &&
        before.modified.microsecondsSinceEpoch == modifiedMicros &&
        before.changed.microsecondsSinceEpoch == changedMicros &&
        sha256.convert(bytes).toString() == sourceSha256;
  }
}

/// Frozen project/external analyzer-options closure for later revalidation.
final class L10nAnalysisOptionsProjection {
  /// Creates a deterministic immutable options projection.
  L10nAnalysisOptionsProjection({
    required Iterable<String> projectOwnedPaths,
    required Iterable<L10nExternalAnalysisOptionsAuthority> externalAuthorities,
    required this.contextAuthorityIdentity,
  }) : projectOwnedPaths = _sortedSet(projectOwnedPaths.toSet()),
       externalAuthorities = List.unmodifiable(
         externalAuthorities.toList()..sort(
           (left, right) => left.canonicalPath.compareTo(right.canonicalPath),
         ),
       ) {
    if (this.projectOwnedPaths.any((path) => !_isSafeRelativePosixPath(path))) {
      throw ArgumentError.value(projectOwnedPaths, 'projectOwnedPaths');
    }
    final externalPaths = <String>{};
    if (this.externalAuthorities.any(
      (authority) => !externalPaths.add(authority.canonicalPath),
    )) {
      throw ArgumentError.value(externalAuthorities, 'externalAuthorities');
    }
    if (!_isSha256(contextAuthorityIdentity)) {
      throw ArgumentError.value(
        contextAuthorityIdentity,
        'contextAuthorityIdentity',
      );
    }
  }

  /// Project-relative options files that must be staged.
  final Set<String> projectOwnedPaths;

  /// External package options files that remain live but are re-readable.
  final List<L10nExternalAnalysisOptionsAuthority> externalAuthorities;

  /// Relative identity of analyzer contexts and their options/package files.
  final String contextAuthorityIdentity;

  /// Deterministic semantic identity of this closure.
  String get identity => sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'projectOwnedPaths': projectOwnedPaths.toList(growable: false),
            'contextAuthorityIdentity': contextAuthorityIdentity,
            'externalAuthorities': [
              for (final authority in externalAuthorities) authority._identity,
            ],
          }),
        ),
      )
      .toString();

  /// Re-reads every external authority without re-discovering new inputs.
  L10nAnalysisOptionsRevalidationResult revalidate() {
    try {
      if (externalAuthorities.any((authority) => !authority._matchesLive())) {
        return const L10nAnalysisOptionsRevalidationRejected(
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.sourceDrift,
            stage: 'family-snapshot-capture',
            detailCode: 'analysis-options-external-drift',
          ),
        );
      }
      return const L10nAnalysisOptionsRevalidationReady();
    } on Object {
      return const L10nAnalysisOptionsRevalidationRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.sourceDrift,
          stage: 'family-snapshot-capture',
          detailCode: 'analysis-options-external-drift',
        ),
      );
    }
  }
}

/// Typed outcome of an external analyzer-options second read.
sealed class L10nAnalysisOptionsRevalidationResult {
  const L10nAnalysisOptionsRevalidationResult();
}

/// Every retained external analyzer-options authority still matches.
final class L10nAnalysisOptionsRevalidationReady
    extends L10nAnalysisOptionsRevalidationResult {
  /// Creates a successful revalidation result.
  const L10nAnalysisOptionsRevalidationReady();
}

/// External analyzer-options authority changed or became unsafe.
final class L10nAnalysisOptionsRevalidationRejected
    extends L10nAnalysisOptionsRevalidationResult {
  /// Creates a typed rejection.
  const L10nAnalysisOptionsRevalidationRejected(this.failure);

  /// Stable drift identity.
  final L10nEvidenceFailure failure;
}

/// Deep immutable project semantics used to construct staged context directly.
final class L10nProjectSemantics {
  /// Deep-copies every mutable project semantic.
  L10nProjectSemantics({
    required Map<dynamic, dynamic> pubspec,
    required this.packageName,
    required this.analysisMode,
    required TargetMatrix targetMatrix,
    required RootCoverage rootCoverage,
  }) : pubspec = _freezeMap(pubspec),
       targetMatrix = TargetMatrix(
         targets: targetMatrix.targets,
         status: targetMatrix.status,
         source: targetMatrix.source,
         issues: targetMatrix.issues,
       ),
       rootCoverage = RootCoverage(
         mode: rootCoverage.mode,
         internalBoundaryComplete: rootCoverage.internalBoundaryComplete,
         externalConsumersCovered: rootCoverage.externalConsumersCovered,
         source: rootCoverage.source,
         publicEntrypoints: rootCoverage.publicEntrypoints,
         issues: rootCoverage.issues,
       ) {
    if (packageName.isEmpty) {
      throw ArgumentError.value(packageName, 'packageName');
    }
  }

  /// Parsed pubspec semantics, recursively frozen.
  final Map<dynamic, dynamic> pubspec;

  /// Selected package name.
  final String packageName;

  /// Exact selected analysis mode.
  final AnalysisMode analysisMode;

  /// Deep immutable target matrix.
  final TargetMatrix targetMatrix;

  /// Deep immutable root-coverage declaration.
  final RootCoverage rootCoverage;
}

/// Complete byte, semantic, package, analyzer, and toolchain authority for one
/// l10n family evaluation.
final class L10nFamilySnapshot {
  /// Creates and validates a defensive immutable family snapshot.
  L10nFamilySnapshot({
    required Map<String, L10nSnapshotEntry> entries,
    required this.mutationPlan,
    required Set<String> selectedNodeIds,
    required Set<String> selectedKeys,
    required Map<String, ArbGeneratedMemberKind>
    expectedGeneratedMemberKindsByKey,
    required Set<String> expectedGeneratedPaths,
    required this.optionalUntranslatedPath,
    required L10nVerificationClosure verificationClosure,
    required L10nAnalysisOptionsProjection analysisOptionsProjection,
    required Set<String> provenUnrelatedOutputSiblings,
    required this.familyFingerprint,
    required this.selectionFingerprint,
    required this.l10nAnalysisFingerprint,
    required this.configurationIdentity,
    required this.packageConfigProjectionIdentity,
    required this.packageResolutionIdentity,
    required this.toolchainIdentity,
    required L10nProjectSemantics projectSemantics,
  }) : entries = _sortedEntries(entries),
       selectedNodeIds = _sortedSet(selectedNodeIds),
       selectedKeys = _sortedSet(selectedKeys),
       expectedGeneratedMemberKindsByKey = _sortedKinds(
         expectedGeneratedMemberKindsByKey,
       ),
       expectedGeneratedPaths = _sortedSet(expectedGeneratedPaths),
       verificationClosure = L10nVerificationClosure(
         projectOwnedDartPaths: verificationClosure.projectOwnedDartPaths,
         analyzerRootIdentity: verificationClosure.analyzerRootIdentity,
       ),
       analysisOptionsProjection = L10nAnalysisOptionsProjection(
         projectOwnedPaths: analysisOptionsProjection.projectOwnedPaths,
         externalAuthorities: analysisOptionsProjection.externalAuthorities,
         contextAuthorityIdentity:
             analysisOptionsProjection.contextAuthorityIdentity,
       ),
       provenUnrelatedOutputSiblings = _sortedSet(
         provenUnrelatedOutputSiblings,
       ),
       projectSemantics = L10nProjectSemantics(
         pubspec: projectSemantics.pubspec,
         packageName: projectSemantics.packageName,
         analysisMode: projectSemantics.analysisMode,
         targetMatrix: projectSemantics.targetMatrix,
         rootCoverage: projectSemantics.rootCoverage,
       ) {
    _validate();
  }

  /// Entries in canonical relative-path order.
  final Map<String, L10nSnapshotEntry> entries;

  /// Complete immutable ARB edit attribution.
  final L10nArbMutationPlan mutationPlan;

  /// Selected canonical l10n graph-node IDs.
  final Set<String> selectedNodeIds;

  /// Selected decoded template keys.
  final Set<String> selectedKeys;

  /// Frozen generated getter/method shape for every template key.
  final Map<String, ArbGeneratedMemberKind> expectedGeneratedMemberKindsByKey;

  /// Complete expected generated base and language output paths.
  final Set<String> expectedGeneratedPaths;

  /// Configured untranslated-message sidecar path, when enabled.
  final String? optionalUntranslatedPath;

  /// Sole analyzer-closure authority retained for staged verification.
  final L10nVerificationClosure verificationClosure;

  /// Frozen analyzer-options closure and external revalidation seam.
  final L10nAnalysisOptionsProjection analysisOptionsProjection;

  /// Compatibility projection of [verificationClosure].
  Set<String> get analyzerClosurePaths =>
      verificationClosure.projectOwnedDartPaths;

  /// Output-directory siblings proven outside the managed family.
  final Set<String> provenUnrelatedOutputSiblings;

  /// Family-only identity, independent of the requested selection.
  final String familyFingerprint;

  /// Identity of family, exact selection, and mutation attribution.
  final String selectionFingerprint;

  /// Frozen l10n graph/finding semantic projection.
  final String l10nAnalysisFingerprint;

  /// Strict generation configuration identity.
  final String configurationIdentity;

  /// Project package resolution and external-root identity.
  final String packageConfigProjectionIdentity;

  /// Project package resolution and external-root identity.
  final String packageResolutionIdentity;

  /// Frozen canonical Flutter toolchain identity.
  final String toolchainIdentity;

  /// Staged verifier project semantics.
  final L10nProjectSemantics projectSemantics;

  void _validate() {
    if (selectedNodeIds.isEmpty || selectedKeys.isEmpty) {
      throw StateError('A family snapshot requires a non-empty selection.');
    }
    if (!expectedGeneratedMemberKindsByKey.keys.toSet().containsAll(
      selectedKeys,
    )) {
      throw StateError('Selected keys are absent from generated member kinds.');
    }
    if (selectedNodeIds.length != selectedKeys.length) {
      throw StateError('Selected node/key cardinality does not match.');
    }
    void requireFixedEntry(
      String path,
      L10nSnapshotRole role, {
      required bool present,
    }) {
      final matching = entries.values
          .where((entry) => entry.role == role)
          .toList(growable: false);
      final entry = entries[path];
      if (matching.length != 1 ||
          entry == null ||
          entry.role != role ||
          (present && entry.state is! L10nSnapshotPresent)) {
        throw StateError('Snapshot authority is incomplete: $path.');
      }
    }

    requireFixedEntry('pubspec.yaml', L10nSnapshotRole.pubspec, present: true);
    requireFixedEntry('pubspec.lock', L10nSnapshotRole.lockfile, present: true);
    requireFixedEntry('l10n.yaml', L10nSnapshotRole.l10nConfig, present: false);
    requireFixedEntry(
      '.dart_tool/package_config.json',
      L10nSnapshotRole.packageConfig,
      present: true,
    );
    requireFixedEntry(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
      present: false,
    );
    for (final path in const {'analysis_options.yaml', 'dart_test.yaml'}) {
      final entry = entries[path];
      if (entry == null || entry.role != L10nSnapshotRole.verificationInput) {
        throw StateError('Snapshot authority is incomplete: $path.');
      }
    }
    final expectedSelectedNodeIds = {
      for (final key in selectedKeys)
        'l10n:${Uri.encodeComponent(projectSemantics.packageName)}:'
            '${Uri.encodeComponent(key)}',
    };
    if (selectedNodeIds.difference(expectedSelectedNodeIds).isNotEmpty ||
        expectedSelectedNodeIds.difference(selectedNodeIds).isNotEmpty) {
      throw StateError('Selected node IDs do not match selected l10n keys.');
    }
    final semantics = projectSemantics;
    final expectedCoverageMode = switch (semantics.analysisMode) {
      AnalysisMode.application => RootCoverageMode.applicationEntrypoints,
      AnalysisMode.package => RootCoverageMode.packagePublicApi,
      AnalysisMode.packageInternal => RootCoverageMode.packageInternal,
    };
    if (!semantics.targetMatrix.isComplete ||
        semantics.targetMatrix.targets.isEmpty ||
        !semantics.rootCoverage.internalBoundaryComplete ||
        semantics.rootCoverage.mode != expectedCoverageMode ||
        (semantics.analysisMode.requiresPublicEntrypoints &&
            semantics.rootCoverage.publicEntrypoints.isEmpty) ||
        verificationClosure.projectOwnedDartPaths.isEmpty) {
      throw StateError('Snapshot project coverage is not complete.');
    }
    final requiredAnalyzerRoots = <String>{
      for (final target in semantics.targetMatrix.targets) target.entrypoint,
      ...semantics.rootCoverage.publicEntrypoints,
    };
    if (!verificationClosure.projectOwnedDartPaths.containsAll(
      requiredAnalyzerRoots,
    )) {
      throw StateError('Snapshot analyzer closure omits a declared root.');
    }
    if (expectedGeneratedPaths.intersection(requiredAnalyzerRoots).isNotEmpty) {
      throw StateError('Generated output collides with a declared root.');
    }
    for (final entry in entries.values) {
      final state = entry.state;
      if (entry.role != L10nSnapshotRole.packageConfig &&
          state is L10nSnapshotPresent &&
          !_sameImmutableBytes(state.sourceBytes, state.stageBytes)) {
        throw StateError(
          'Only package configuration may project different stage bytes.',
        );
      }
    }
    for (final path in verificationClosure.projectOwnedDartPaths) {
      final entry = entries[path];
      if (entry == null || entry.state is! L10nSnapshotPresent) {
        throw StateError(
          'Analyzer closure path has no present snapshot entry: $path',
        );
      }
    }
    for (final path in analysisOptionsProjection.projectOwnedPaths) {
      final entry = entries[path];
      if (entry == null ||
          entry.role != L10nSnapshotRole.verificationInput ||
          entry.state is! L10nSnapshotPresent) {
        throw StateError(
          'Analyzer options path has no present verification entry: $path',
        );
      }
    }
    for (final path in expectedGeneratedPaths) {
      final role = entries[path]?.role;
      if (role != L10nSnapshotRole.generatedBase &&
          role != L10nSnapshotRole.generatedLanguage) {
        throw StateError(
          'Generated path has no generated snapshot role: $path',
        );
      }
    }
    final generatedEntries = entries.values
        .where(
          (entry) =>
              entry.role == L10nSnapshotRole.generatedBase ||
              entry.role == L10nSnapshotRole.generatedLanguage,
        )
        .toList(growable: false);
    final generatedEntryPaths = generatedEntries
        .map((entry) => entry.relativePosixPath)
        .toSet();
    if (generatedEntries
                .where((entry) => entry.role == L10nSnapshotRole.generatedBase)
                .length !=
            1 ||
        generatedEntryPaths.difference(expectedGeneratedPaths).isNotEmpty ||
        expectedGeneratedPaths.difference(generatedEntryPaths).isNotEmpty) {
      throw StateError('Generated role paths do not match expected outputs.');
    }
    final untranslated = optionalUntranslatedPath;
    if (untranslated != null &&
        entries[untranslated]?.role != L10nSnapshotRole.untranslatedSidecar) {
      throw StateError('Optional untranslated path has no sidecar role.');
    }
    final sidecars = entries.values
        .where((entry) => entry.role == L10nSnapshotRole.untranslatedSidecar)
        .map((entry) => entry.relativePosixPath)
        .toSet();
    if ((untranslated == null && sidecars.isNotEmpty) ||
        (untranslated != null &&
            (sidecars.length != 1 || !sidecars.contains(untranslated)))) {
      throw StateError('Sidecar role/path authority is inconsistent.');
    }
    final analyzerSources = entries.values
        .where((entry) => entry.role == L10nSnapshotRole.analyzerSource)
        .map((entry) => entry.relativePosixPath);
    if (!verificationClosure.projectOwnedDartPaths.containsAll(
      analyzerSources,
    )) {
      throw StateError('Analyzer source is outside the verification closure.');
    }
    final arbPaths = entries.values
        .where(
          (entry) =>
              entry.role == L10nSnapshotRole.arbTemplate ||
              entry.role == L10nSnapshotRole.arbLocale,
        )
        .map((entry) => entry.relativePosixPath)
        .toSet();
    final candidatePaths = mutationPlan.candidateArbBytes.keys.toSet();
    final removalPaths = mutationPlan.removalsByPath.keys.toSet();
    final templatePaths = entries.values
        .where((entry) => entry.role == L10nSnapshotRole.arbTemplate)
        .map((entry) => entry.relativePosixPath)
        .toList(growable: false);
    if (arbPaths.any((path) => entries[path]!.state is! L10nSnapshotPresent) ||
        templatePaths.length != 1 ||
        candidatePaths.difference(arbPaths).isNotEmpty ||
        arbPaths.difference(candidatePaths).isNotEmpty ||
        removalPaths.difference(arbPaths).isNotEmpty ||
        arbPaths.difference(removalPaths).isNotEmpty) {
      throw StateError('Mutation plan does not match captured ARB family.');
    }
    final documents = <String, ArbDocument>{};
    for (final path in arbPaths) {
      final state = entries[path]!.state as L10nSnapshotPresent;
      final parsed = ArbDocument.parse(state.sourceBytes.copy());
      if (parsed is! ArbParseSuccess) {
        throw StateError('Captured ARB source bytes do not parse: $path');
      }
      documents[path] = parsed.document;
    }
    final templateMessageKeys = {
      for (final member in documents[templatePaths.single]!.members)
        if (!member.decodedKey.startsWith('@')) member.decodedKey,
    };
    if (templateMessageKeys
            .difference(expectedGeneratedMemberKindsByKey.keys.toSet())
            .isNotEmpty ||
        expectedGeneratedMemberKindsByKey.keys
            .toSet()
            .difference(templateMessageKeys)
            .isNotEmpty) {
      throw StateError('Generated member kinds do not match template keys.');
    }
    for (final key in templateMessageKeys) {
      final message = documents[templatePaths.single]!
          .member(key)
          ?.decodedValue;
      final metadata = documents[templatePaths.single]!
          .member('@$key')
          ?.decodedValue;
      final placeholders = metadata is Map ? metadata['placeholders'] : null;
      final expectedKind =
          (placeholders is Map && placeholders.isNotEmpty) ||
              (message is String &&
                  RegExp(r'\{\s*[A-Za-z_]\w*\s*(?:\}|,)').hasMatch(message))
          ? ArbGeneratedMemberKind.method
          : ArbGeneratedMemberKind.getter;
      if (message is! String ||
          expectedGeneratedMemberKindsByKey[key] != expectedKind) {
        throw StateError('Generated member kind does not match template.');
      }
    }
    final reconstructed = L10nArbMutationPlanner.plan(
      templatePath: templatePaths.single,
      documentsByPath: documents,
      selectedKeys: selectedKeys,
    );
    if (reconstructed is! L10nArbMutationPlanReady ||
        reconstructed.plan.mutationFingerprint !=
            mutationPlan.mutationFingerprint) {
      throw StateError('Mutation plan is not bound to snapshot source bytes.');
    }
    for (final path in provenUnrelatedOutputSiblings) {
      if (expectedGeneratedPaths.contains(path) || path == untranslated) {
        throw StateError('Managed output cannot be an unrelated sibling.');
      }
      final entry = entries[path];
      if (entry == null || entry.state is! L10nSnapshotPresent) {
        throw StateError('Proven output sibling is not captured: $path');
      }
    }
    for (final identity in [
      familyFingerprint,
      selectionFingerprint,
      l10nAnalysisFingerprint,
      configurationIdentity,
      packageConfigProjectionIdentity,
      packageResolutionIdentity,
      toolchainIdentity,
    ]) {
      if (!_isSha256(identity)) {
        throw StateError('Snapshot identity is not a canonical SHA-256.');
      }
    }
  }
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Map<String, L10nSnapshotEntry> _sortedEntries(
  Map<String, L10nSnapshotEntry> source,
) {
  final sorted = SplayTreeMap<String, L10nSnapshotEntry>();
  final folded = <String, String>{};
  for (final entry in source.entries) {
    if (entry.key != entry.value.relativePosixPath) {
      throw ArgumentError.value(
        entry.key,
        'entries',
        'entry key/path mismatch',
      );
    }
    final prior = folded[_asciiFold(entry.key)];
    if (prior != null && prior != entry.key) {
      throw ArgumentError('ASCII-folded snapshot path collision.');
    }
    folded[_asciiFold(entry.key)] = entry.key;
    sorted[entry.key] = entry.value;
  }
  return UnmodifiableMapView(sorted);
}

String _asciiFold(String value) => String.fromCharCodes(
  value.codeUnits.map(
    (unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
  ),
);

Map<String, ArbGeneratedMemberKind> _sortedKinds(
  Map<String, ArbGeneratedMemberKind> source,
) => UnmodifiableMapView(
  SplayTreeMap<String, ArbGeneratedMemberKind>.of(source),
);

Set<String> _sortedSet(Iterable<String> source) =>
    Set<String>.unmodifiable(SplayTreeSet<String>.of(source));

Map<dynamic, dynamic> _freezeMap(Map<dynamic, dynamic> source) =>
    Map<dynamic, dynamic>.unmodifiable({
      for (final entry in source.entries)
        _freezeValue(entry.key): _freezeValue(entry.value),
    });

Object? _freezeValue(Object? value) {
  if (value is Map) return _freezeMap(value);
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_freezeValue));
  }
  if (value is Set) {
    return Set<Object?>.unmodifiable(value.map(_freezeValue));
  }
  return value;
}

bool _isSafeRelativePosixPath(String value) {
  if (value.isEmpty ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains(':') ||
      value.contains('%') ||
      value.contains('?') ||
      value.contains('#') ||
      value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    return false;
  }
  final segments = value.split('/');
  return segments.every(
    (segment) =>
        segment.isNotEmpty &&
        segment != '.' &&
        segment != '..' &&
        RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
  );
}

bool _sameImmutableBytes(ImmutableBytes left, ImmutableBytes right) {
  final leftBytes = left.copy();
  final rightBytes = right.copy();
  if (leftBytes.length != rightBytes.length) return false;
  for (var index = 0; index < leftBytes.length; index++) {
    if (leftBytes[index] != rightBytes[index]) return false;
  }
  return true;
}
