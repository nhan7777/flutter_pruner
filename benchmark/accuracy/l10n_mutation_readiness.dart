/// Internal, fail-closed orchestration contract for the l10n Stage 1 gate.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/recoverable_report_writer.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:path/path.dart' as p;

import 'src/l10n_mutation_manifest.dart';
import 'src/l10n_readiness_production.dart';

const _schemaVersion = 2;
const _artifactKind = 'flutter-pruner-l10n-stage1-readiness';
const _requiredSdkVersions = <String>{'3.41.5', '3.44.1', '3.44.9'};
const _topLevelKeys = <String>{
  'schemaVersion',
  'artifactKind',
  'oracleVersion',
  'status',
  'scope',
  'identities',
  'projects',
  'cases',
  'familyBatches',
  'mutationNegativeFixtures',
  'performance',
  'summary',
};

/// Parsed inputs for the private benchmark entrypoint.
final class L10nMutationReadinessOptions {
  L10nMutationReadinessOptions._({
    required this.repositoryRoot,
    required this.manifestPath,
    required this.manifestFile,
    required this.corpusRoot,
    required this.sdkFlutterByVersion,
    required this.outputFile,
    required this.resumeFile,
    required this.caseSelection,
    required this.familySelection,
  });

  factory L10nMutationReadinessOptions.parse(List<String> arguments) {
    const single = <String>{
      '--manifest',
      '--corpus-root',
      '--output',
      '--resume',
      '--case',
      '--family',
    };
    const allowed = <String>{...single, '--sdk'};
    final values = <String, String>{};
    final sdkValues = <String>[];
    for (var index = 0; index < arguments.length; index += 2) {
      if (index + 1 >= arguments.length) {
        throw const FormatException('every option requires one value');
      }
      final option = arguments[index];
      final value = arguments[index + 1];
      if (!allowed.contains(option) ||
          value.isEmpty ||
          value.startsWith('--')) {
        throw const FormatException('unknown or malformed readiness option');
      }
      if (option == '--sdk') {
        sdkValues.add(value);
      } else if (values.containsKey(option)) {
        throw const FormatException('duplicate readiness option');
      } else {
        values[option] = value;
      }
    }
    for (final required in const <String>{
      '--manifest',
      '--corpus-root',
      '--output',
    }) {
      if (!values.containsKey(required)) {
        throw const FormatException('missing required readiness option');
      }
    }
    if (values.containsKey('--case') && values.containsKey('--family')) {
      throw const FormatException(
        'case and family scopes are mutually exclusive',
      );
    }

    final manifestPath = values['--manifest']!;
    if (p.isAbsolute(manifestPath) ||
        p.normalize(manifestPath) != manifestPath ||
        !_safeRelativePath(manifestPath) ||
        !manifestPath.endsWith('.json')) {
      throw const FormatException(
        'manifest must be a canonical relative JSON path',
      );
    }
    final repositoryRoot = _canonicalDirectory(Directory.current);
    final manifestFile = File(p.join(repositoryRoot.path, manifestPath));
    if (FileSystemEntity.typeSync(manifestFile.path, followLinks: false) !=
            FileSystemEntityType.file ||
        !p.equals(manifestFile.resolveSymbolicLinksSync(), manifestFile.path) ||
        !p.isWithin(repositoryRoot.path, manifestFile.path)) {
      throw const FormatException('manifest authority is not canonical');
    }
    final corpusRoot = _absoluteExistingDirectory(values['--corpus-root']!);
    final resumeFile = values['--resume'] == null
        ? null
        : _canonicalExistingFile(values['--resume']!);
    final outputFile = _absoluteOutputFile(
      values['--output']!,
      resumeFile: resumeFile,
    );
    if (resumeFile != null && !p.equals(outputFile.path, resumeFile.path)) {
      throw const FormatException('resume must continue its output in place');
    }
    final caseSelection = values['--case'];
    final familySelection = values['--family'];
    if (caseSelection != null && !_validCaseSelection(caseSelection)) {
      throw const FormatException('case selection is malformed');
    }
    if (familySelection != null && !_safeIdentity(familySelection)) {
      throw const FormatException('family selection is malformed');
    }

    if (sdkValues.length != 3) {
      throw const FormatException('exactly three SDK mappings are required');
    }
    final sdkByVersion = SplayTreeMap<String, File>();
    for (final mapping in sdkValues) {
      final separator = mapping.indexOf('=');
      if (separator <= 0 || separator == mapping.length - 1) {
        throw const FormatException('SDK mapping is malformed');
      }
      final version = mapping.substring(0, separator);
      final path = mapping.substring(separator + 1);
      if (!_requiredSdkVersions.contains(version) ||
          sdkByVersion.containsKey(version)) {
        throw const FormatException('SDK version set is invalid');
      }
      final flutter = _canonicalExistingFile(path);
      if (p.basename(flutter.path) != 'flutter') {
        throw const FormatException('SDK mapping must name a flutter binary');
      }
      sdkByVersion[version] = flutter;
    }
    if (sdkByVersion.keys.toSet().difference(_requiredSdkVersions).isNotEmpty ||
        _requiredSdkVersions.difference(sdkByVersion.keys.toSet()).isNotEmpty) {
      throw const FormatException('SDK version set is invalid');
    }
    if (sdkByVersion.values.map((file) => file.path).toSet().length != 3) {
      throw const FormatException('SDK authorities must be distinct');
    }
    for (final flutter in sdkByVersion.values) {
      final sdkRoot = flutter.parent.parent.path;
      if (p.equals(outputFile.path, flutter.path) ||
          p.equals(outputFile.path, sdkRoot) ||
          p.isWithin(sdkRoot, outputFile.path)) {
        throw const FormatException('output overlaps an SDK authority');
      }
    }
    if (p.equals(outputFile.path, manifestFile.path)) {
      throw const FormatException('output overlaps the manifest authority');
    }
    return L10nMutationReadinessOptions._(
      repositoryRoot: repositoryRoot,
      manifestPath: manifestPath,
      manifestFile: manifestFile,
      corpusRoot: corpusRoot,
      sdkFlutterByVersion: Map.unmodifiable(sdkByVersion),
      outputFile: outputFile,
      resumeFile: resumeFile,
      caseSelection: caseSelection,
      familySelection: familySelection,
    );
  }

  /// Canonical source checkout captured while parsing argv.
  final Directory repositoryRoot;

  final String manifestPath;
  final File manifestFile;
  final Directory corpusRoot;
  final Map<String, File> sdkFlutterByVersion;
  final File outputFile;
  final File? resumeFile;
  final String? caseSelection;
  final String? familySelection;
}

/// Frozen denominators for one full or selected harness scope.
final class L10nReadinessDenominators {
  const L10nReadinessDenominators({
    required this.individualKeys,
    required this.familyBatches,
    required this.staticPositiveCandidates,
    required this.staticNegativeNonCandidates,
    required this.mutationNegativeFixtures,
    required this.requiredRestorations,
  });

  static const productionFull = L10nReadinessDenominators(
    individualKeys: 367,
    familyBatches: 3,
    staticPositiveCandidates: 367,
    staticNegativeNonCandidates: 2235,
    mutationNegativeFixtures: 14,
    requiredRestorations: 370,
  );

  final int individualKeys;
  final int familyBatches;
  final int staticPositiveCandidates;
  final int staticNegativeNonCandidates;
  final int mutationNegativeFixtures;
  final int requiredRestorations;

  Map<String, Object?> toJson() => {
    'individualKeys': individualKeys,
    'familyBatches': familyBatches,
    'staticPositiveCandidates': staticPositiveCandidates,
    'staticNegativeNonCandidates': staticNegativeNonCandidates,
    'mutationNegativeFixtures': mutationNegativeFixtures,
    'requiredRestorations': requiredRestorations,
  };
}

/// Whether a plan is a synthetic contract fixture or baseline-eligible
/// production Stage 1 evidence.
enum L10nReadinessProfile { syntheticContract, productionStage1 }

/// One immutable oracle row used by the harness contract.
final class L10nReadinessOracleCase {
  const L10nReadinessOracleCase({
    required this.caseId,
    required this.projectId,
    required this.decodedKey,
    required this.mutationPositive,
    required this.expectedScannerPresence,
  });

  final String caseId;
  final String projectId;
  final String decodedKey;
  final bool mutationPositive;

  /// Historical observation only. Current truth-positive rows must all be
  /// scanner candidates, including rows where this value is false.
  final bool expectedScannerPresence;
}

/// Fully bound work plan. Production construction is added separately from
/// this orchestration contract so tests never need real corpus processes.
final class L10nReadinessPlan {
  L10nReadinessPlan({
    required this.profile,
    required this.oracleVersion,
    required Map<String, Object?> identities,
    required List<L10nReadinessOracleCase> oracleCases,
    required List<String> individualCaseIds,
    required List<String> familyProjectIds,
    required Map<String, List<String>> mutationNegativeFixtures,
    required this.expectedDenominators,
    required Directory artifactRoot,
    required List<Directory> protectedRoots,
  }) : identities = Map.unmodifiable(
         _stringMap(_deepFreezeRedactedJson(identities)),
       ),
       oracleCases = List.unmodifiable(oracleCases),
       individualCaseIds = List.unmodifiable(individualCaseIds),
       familyProjectIds = List.unmodifiable(familyProjectIds),
       mutationNegativeFixtures = Map.unmodifiable(
         mutationNegativeFixtures.map(
           (key, value) => MapEntry(key, List<String>.unmodifiable(value)),
         ),
       ),
       artifactRoot = _canonicalDirectory(artifactRoot),
       protectedRoots = List.unmodifiable(
         protectedRoots.map(_canonicalDirectory),
       ) {
    _validatePlan(this);
  }

  final L10nReadinessProfile profile;
  final String oracleVersion;
  final Map<String, Object?> identities;
  final List<L10nReadinessOracleCase> oracleCases;
  final List<String> individualCaseIds;
  final List<String> familyProjectIds;
  final Map<String, List<String>> mutationNegativeFixtures;
  final L10nReadinessDenominators expectedDenominators;

  /// Runtime-only output authority. Absolute paths are never serialized.
  final Directory artifactRoot;

  /// Runtime-only corpus/source authorities that the output must not overlap.
  final List<Directory> protectedRoots;
}

/// Builds the immutable production work scope from the frozen manifest.
///
/// Repository, SDK, policy, recipe, coverage, and implementation authorities
/// are intentionally supplied as already-probed SHA-256 identities. The
/// production composition owns those expensive probes; this builder only
/// translates the independently parsed oracle into exact full/case/family
/// denominators and never consults scanner output.
final class ProductionL10nReadinessPlanBuilder {
  const ProductionL10nReadinessPlanBuilder();

  L10nReadinessPlan build({
    required L10nMutationReadinessOptions options,
    required L10nMutationManifest manifest,
    required Map<String, Object?> identities,
    required Map<String, Directory> retainedRepositoriesByProject,
  }) {
    const productionProjects = {'gitjournal', 'gsy', 'smooth'};
    const retainedDirectoryByProject = {
      'gitjournal': 'GitJournal',
      'gsy': 'gsy_github_app_flutter',
      'smooth': 'smooth-app',
    };
    if (manifest.projectsById.keys
            .toSet()
            .difference(productionProjects)
            .isNotEmpty ||
        productionProjects
            .difference(manifest.projectsById.keys.toSet())
            .isNotEmpty ||
        retainedRepositoriesByProject.keys
            .toSet()
            .difference(productionProjects)
            .isNotEmpty ||
        productionProjects
            .difference(retainedRepositoriesByProject.keys.toSet())
            .isNotEmpty) {
      throw const FormatException('production project authority set drift');
    }

    final protectedRoots = <Directory>[
      options.repositoryRoot,
      for (final projectId in productionProjects.toList()..sort())
        _productionRetainedRepository(
          options.corpusRoot,
          retainedDirectoryByProject[projectId]!,
          retainedRepositoriesByProject[projectId]!,
        ),
    ];
    if (protectedRoots.map((root) => root.path).toSet().length !=
        productionProjects.length + 1) {
      throw const FormatException('production repository authorities alias');
    }

    final allCases =
        manifest.cases
            .map(
              (entry) => L10nReadinessOracleCase(
                caseId: entry.canonicalNodeId,
                projectId: entry.projectId,
                decodedKey: entry.decodedKey,
                mutationPositive: entry.isMutationPositive,
                expectedScannerPresence: entry.expectedScannerPresence,
              ),
            )
            .toList(growable: false)
          ..sort((left, right) => left.caseId.compareTo(right.caseId));

    late final List<L10nReadinessOracleCase> oracleCases;
    late final List<String> individualCaseIds;
    late final List<String> familyProjectIds;
    late final Map<String, List<String>> negativeFixtures;
    if (options.caseSelection case final String selection) {
      final separator = selection.indexOf(':');
      final projectId = selection.substring(0, separator);
      final decodedKey = selection.substring(separator + 1);
      final matches = allCases
          .where(
            (entry) =>
                entry.projectId == projectId &&
                entry.decodedKey == decodedKey &&
                entry.mutationPositive,
          )
          .toList(growable: false);
      if (matches.length != 1) {
        throw const FormatException(
          'production case selection is not one positive oracle row',
        );
      }
      oracleCases = _productionProjectCases(allCases, projectId);
      individualCaseIds = [matches.single.caseId];
      familyProjectIds = const [];
      negativeFixtures = const {};
    } else if (options.familySelection case final String projectId) {
      if (!productionProjects.contains(projectId)) {
        throw const FormatException('production family selection is unknown');
      }
      oracleCases = _productionProjectCases(allCases, projectId);
      individualCaseIds = const [];
      familyProjectIds = [projectId];
      negativeFixtures = const {};
    } else {
      oracleCases = allCases;
      individualCaseIds = [
        for (final entry in allCases)
          if (entry.mutationPositive) entry.caseId,
      ];
      familyProjectIds = productionProjects.toList()..sort();
      negativeFixtures = {
        for (final entry in manifest.mutationNegativeReasons.entries)
          entry.key: [...entry.value]..sort(),
      };
    }

    final positives = oracleCases
        .where((entry) => entry.mutationPositive)
        .length;
    final negatives = oracleCases.length - positives;
    final denominators = L10nReadinessDenominators(
      individualKeys: individualCaseIds.length,
      familyBatches: familyProjectIds.length,
      staticPositiveCandidates: positives,
      staticNegativeNonCandidates: negatives,
      mutationNegativeFixtures: negativeFixtures.length,
      requiredRestorations: individualCaseIds.length + familyProjectIds.length,
    );
    final artifactRoot =
        options.caseSelection == null && options.familySelection == null
        ? _canonicalDirectory(
            Directory(p.join(options.corpusRoot.path, 'results')),
          )
        : _canonicalDirectory(options.outputFile.parent);
    final corpusPath = options.corpusRoot.path;
    final sourcePath = options.repositoryRoot.path;
    if ((options.caseSelection != null || options.familySelection != null) &&
        (p.equals(artifactRoot.path, corpusPath) ||
            p.isWithin(corpusPath, artifactRoot.path))) {
      throw const FormatException(
        'production smoke artifact must be outside the corpus root',
      );
    }
    if (p.equals(artifactRoot.path, sourcePath) ||
        p.isWithin(sourcePath, artifactRoot.path) ||
        p.isWithin(artifactRoot.path, sourcePath)) {
      throw const FormatException(
        'production artifact must be disjoint from the source checkout',
      );
    }

    return L10nReadinessPlan(
      profile: L10nReadinessProfile.productionStage1,
      oracleVersion: manifest.oracleVersion,
      identities: identities,
      oracleCases: oracleCases,
      individualCaseIds: individualCaseIds,
      familyProjectIds: familyProjectIds,
      mutationNegativeFixtures: negativeFixtures,
      expectedDenominators: denominators,
      artifactRoot: artifactRoot,
      protectedRoots: protectedRoots,
    );
  }
}

Directory _productionRetainedRepository(
  Directory corpusRoot,
  String expectedLeaf,
  Directory supplied,
) {
  final expectedPath = p.join(corpusRoot.path, expectedLeaf);
  if (!p.equals(supplied.path, expectedPath) ||
      FileSystemEntity.typeSync(supplied.path, followLinks: false) !=
          FileSystemEntityType.directory ||
      !p.equals(supplied.resolveSymbolicLinksSync(), supplied.path)) {
    throw const FormatException(
      'production retained repository layout is not canonical',
    );
  }
  return Directory(supplied.path);
}

List<L10nReadinessOracleCase> _productionProjectCases(
  List<L10nReadinessOracleCase> allCases,
  String projectId,
) {
  final cases = allCases
      .where((entry) => entry.projectId == projectId)
      .toList(growable: false);
  if (cases.isEmpty) {
    throw const FormatException('production project has no oracle cases');
  }
  return cases;
}

/// Reads the root and linked manifests through their frozen SHA-checked parser
/// before constructing a production scope.
/// This is deliberately not the complete production authority loader: callers
/// must supply identities from separately completed repository, SDK, coverage,
/// policy, recipe, and implementation probes. [main] remains disabled until
/// that composition exists, so synthetic hashes cannot become runnable proof.
Future<L10nReadinessPlan> buildProductionL10nReadinessPlanFromManifest(
  L10nMutationReadinessOptions options, {
  required Map<String, Object?> identities,
  required Map<String, Directory> retainedRepositoriesByProject,
}) async {
  _revalidateProductionManifestAuthority(options);
  final before = await options.manifestFile.readAsBytes();
  if (identities['manifestSha256'] != sha256.convert(before).toString()) {
    throw const FormatException('production manifest identity mismatch');
  }
  final manifest = L10nMutationManifest.read(options.manifestFile);
  final after = await options.manifestFile.readAsBytes();
  _revalidateProductionManifestAuthority(options);
  if (!_sameBytes(before, after)) {
    throw const FormatException('production manifest changed while loading');
  }
  return const ProductionL10nReadinessPlanBuilder().build(
    options: options,
    manifest: manifest,
    identities: identities,
    retainedRepositoriesByProject: retainedRepositoriesByProject,
  );
}

void _revalidateProductionManifestAuthority(
  L10nMutationReadinessOptions options,
) {
  final file = options.manifestFile;
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.equals(file.resolveSymbolicLinksSync(), file.path) ||
      !p.isWithin(options.repositoryRoot.path, file.path)) {
    throw const FormatException('production manifest authority drift');
  }
}

/// Minimal disposable-view authority exposed to the contract layer.
abstract interface class L10nReadinessProjectView {
  String get projectId;
  Future<void> dispose();
}

/// Static scan evidence bound to an opaque unchanged analysis authority.
final class L10nStaticScanResult {
  L10nStaticScanResult({
    required this.authorityIdentity,
    this.analysisAuthority,
    required Map<String, String> actualNodeIdByOracleCaseId,
    required Set<String> candidateOracleCaseIds,
    required this.publicSafeL10n,
    required this.publicHighL10n,
    required this.publicApplyEligibleL10n,
    required this.publicProposedL10nActions,
  }) : actualNodeIdByOracleCaseId = Map.unmodifiable(
         actualNodeIdByOracleCaseId,
       ),
       candidateOracleCaseIds = Set.unmodifiable(candidateOracleCaseIds) {
    if (!_safeRecordIdentity(authorityIdentity) ||
        publicSafeL10n < 0 ||
        publicHighL10n < 0 ||
        publicApplyEligibleL10n < 0 ||
        publicProposedL10nActions < 0 ||
        this.actualNodeIdByOracleCaseId.entries.any(
          (entry) =>
              !_safeRecordIdentity(entry.key) ||
              !_safeRecordIdentity(entry.value),
        ) ||
        this.candidateOracleCaseIds.any(
          (identity) => !_safeRecordIdentity(identity),
        )) {
      throw ArgumentError('static scan evidence is malformed or unredacted');
    }
  }

  final String authorityIdentity;

  /// Runtime-only immutable analysis authority. Production evaluation requires
  /// object identity with the snapshot retained by its disposable view.
  final Object? analysisAuthority;
  final Map<String, String> actualNodeIdByOracleCaseId;
  final Set<String> candidateOracleCaseIds;
  final int publicSafeL10n;
  final int publicHighL10n;
  final int publicApplyEligibleL10n;
  final int publicProposedL10nActions;
}

abstract interface class L10nHarnessScanner {
  Future<L10nStaticScanResult> scan(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> oracleCases,
  );
}

/// One stable, redaction-safe internal verdict failure.
final class L10nVerdictFailure {
  L10nVerdictFailure({
    required this.code,
    required this.stage,
    required this.detailCode,
    this.relativePath,
  }) {
    if (!_safeIdentity(code) ||
        !_safeIdentity(stage) ||
        !_safeIdentity(detailCode) ||
        relativePath != null && !_safeRelativePath(relativePath!)) {
      throw ArgumentError('verdict failure is not redaction-safe');
    }
  }

  final String code;
  final String stage;
  final String detailCode;
  final String? relativePath;

  Map<String, Object?> toJson() => {
    'code': code,
    'detailCode': detailCode,
    if (relativePath != null) 'relativePath': relativePath,
    'stage': stage,
  };
}

/// Internal pipeline result. [mutationAuthority] stays process-local and is
/// handed directly to the corpus runner only after an accepted verdict.
final class L10nInternalEvidenceResult {
  L10nInternalEvidenceResult({
    required this.selectionIdentity,
    required this.accepted,
    required this.mutationAuthority,
    required this.bytesCopied,
    required this.stageMicros,
    required this.baselineGeneratorMicros,
    required this.candidateGeneratorMicros,
    required this.sampledPeakRssBytes,
    required this.verdictIdentity,
    required List<L10nVerdictFailure> verdictFailures,
  }) : verdictFailures = List.unmodifiable(verdictFailures) {
    for (final value in <int>[
      bytesCopied,
      stageMicros,
      baselineGeneratorMicros,
      candidateGeneratorMicros,
      sampledPeakRssBytes,
    ]) {
      if (value < 0) {
        throw ArgumentError('internal evidence metrics must be non-negative');
      }
    }
    if (!_safeRecordIdentity(selectionIdentity) ||
        !_safeRecordIdentity(verdictIdentity) ||
        verdictIdentity == 'notRun' ||
        accepted != (mutationAuthority != null) ||
        accepted != this.verdictFailures.isEmpty) {
      throw ArgumentError('internal evidence authority is inconsistent');
    }
  }

  final String selectionIdentity;
  final bool accepted;
  final Object? mutationAuthority;
  final int bytesCopied;
  final int stageMicros;
  final int baselineGeneratorMicros;
  final int candidateGeneratorMicros;
  final int sampledPeakRssBytes;
  final String verdictIdentity;
  final List<L10nVerdictFailure> verdictFailures;
}

/// Complete-corpus policy and restoration result for one accepted verdict.
final class L10nCorpusEvidenceResult {
  L10nCorpusEvidenceResult({
    required this.selectionIdentity,
    required this.corpusPolicyPassed,
    required this.restorationProven,
    required this.unexpectedWriteCount,
    required this.originalProjectDrift,
    required this.policyMicros,
    required this.sampledPeakRssBytes,
    required this.corpusPolicyIdentity,
    required this.restorationIdentity,
  }) {
    for (final value in <int>[
      unexpectedWriteCount,
      policyMicros,
      sampledPeakRssBytes,
    ]) {
      if (value < 0) {
        throw ArgumentError('corpus evidence metrics must be non-negative');
      }
    }
    if (!_safeRecordIdentity(selectionIdentity) ||
        !_safeRecordIdentity(corpusPolicyIdentity) ||
        !_safeRecordIdentity(restorationIdentity) ||
        corpusPolicyIdentity == 'notRun' ||
        restorationIdentity == 'notRun') {
      throw ArgumentError('corpus evidence identity is malformed');
    }
  }

  final String selectionIdentity;
  final bool corpusPolicyPassed;
  final bool restorationProven;
  final int unexpectedWriteCount;
  final bool originalProjectDrift;
  final int policyMicros;
  final int sampledPeakRssBytes;
  final String corpusPolicyIdentity;
  final String restorationIdentity;
}

/// Redaction-safe terminal projection assembled only by the orchestrator.
final class L10nEvidenceResult {
  L10nEvidenceResult._({
    required this.selectionIdentity,
    required this.acceptedInternalVerdict,
    required this.corpusPolicyPassed,
    required this.restorationProven,
    required this.unexpectedWriteCount,
    required this.originalProjectDrift,
    required this.bytesCopied,
    required this.stageMicros,
    required this.baselineGeneratorMicros,
    required this.candidateGeneratorMicros,
    required this.policyMicros,
    required this.sampledPeakRssBytes,
    required this.verdictIdentity,
    required List<L10nVerdictFailure> verdictFailures,
    required this.corpusPolicyIdentity,
    required this.restorationIdentity,
  }) : verdictFailures = List.unmodifiable(verdictFailures);

  factory L10nEvidenceResult.fromInternal(
    String selectionIdentity,
    L10nInternalEvidenceResult internal,
    L10nCorpusEvidenceResult? corpus,
  ) {
    if (!_safeRecordIdentity(selectionIdentity) ||
        internal.selectionIdentity != selectionIdentity ||
        corpus != null && corpus.selectionIdentity != selectionIdentity ||
        internal.accepted != (corpus != null)) {
      throw ArgumentError('terminal evidence sequencing is inconsistent');
    }
    return L10nEvidenceResult._(
      selectionIdentity: selectionIdentity,
      acceptedInternalVerdict: internal.accepted,
      corpusPolicyPassed: corpus?.corpusPolicyPassed ?? false,
      restorationProven: corpus?.restorationProven ?? false,
      unexpectedWriteCount: corpus?.unexpectedWriteCount ?? 0,
      originalProjectDrift: corpus?.originalProjectDrift ?? false,
      bytesCopied: internal.bytesCopied,
      stageMicros: internal.stageMicros,
      baselineGeneratorMicros: internal.baselineGeneratorMicros,
      candidateGeneratorMicros: internal.candidateGeneratorMicros,
      policyMicros: corpus?.policyMicros ?? 0,
      sampledPeakRssBytes: corpus == null
          ? internal.sampledPeakRssBytes
          : internal.sampledPeakRssBytes > corpus.sampledPeakRssBytes
          ? internal.sampledPeakRssBytes
          : corpus.sampledPeakRssBytes,
      verdictIdentity: internal.verdictIdentity,
      verdictFailures: internal.verdictFailures,
      corpusPolicyIdentity: corpus?.corpusPolicyIdentity ?? 'notRun',
      restorationIdentity: corpus?.restorationIdentity ?? 'notRun',
    );
  }

  final String selectionIdentity;
  final bool acceptedInternalVerdict;
  final bool corpusPolicyPassed;
  final bool restorationProven;
  final int unexpectedWriteCount;
  final bool originalProjectDrift;
  final int bytesCopied;
  final int stageMicros;
  final int baselineGeneratorMicros;
  final int candidateGeneratorMicros;
  final int policyMicros;
  final int sampledPeakRssBytes;
  final String verdictIdentity;
  final List<L10nVerdictFailure> verdictFailures;
  final String corpusPolicyIdentity;
  final String restorationIdentity;

  bool get passed =>
      acceptedInternalVerdict &&
      corpusPolicyPassed &&
      restorationProven &&
      unexpectedWriteCount == 0 &&
      !originalProjectDrift;

  Map<String, Object?> toJson() => {
    'acceptedInternalVerdict': acceptedInternalVerdict,
    'baselineGeneratorMicros': baselineGeneratorMicros,
    'bytesCopied': bytesCopied,
    'candidateGeneratorMicros': candidateGeneratorMicros,
    'corpusPolicyIdentity': corpusPolicyIdentity,
    'corpusPolicyPassed': corpusPolicyPassed,
    'originalProjectDrift': originalProjectDrift,
    'policyMicros': policyMicros,
    'restorationIdentity': restorationIdentity,
    'restorationProven': restorationProven,
    'sampledPeakRssBytes': sampledPeakRssBytes,
    'selectionIdentity': selectionIdentity,
    'stageMicros': stageMicros,
    'unexpectedWriteCount': unexpectedWriteCount,
    'verdictFailures': [
      for (final failure in verdictFailures) failure.toJson(),
    ],
    'verdictIdentity': verdictIdentity,
  };
}

abstract interface class L10nEvidenceEvaluator {
  Future<L10nInternalEvidenceResult> evaluateIndividual(
    L10nReadinessProjectView view,
    L10nReadinessOracleCase oracleCase,
    L10nStaticScanResult scan,
  );

  Future<L10nInternalEvidenceResult> evaluateFamily(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> positiveCases,
    L10nStaticScanResult scan,
  );
}

abstract interface class L10nCorpusEvidenceRunner {
  Future<L10nCorpusEvidenceResult> run(
    L10nReadinessProjectView view,
    String selectionIdentity,
    L10nInternalEvidenceResult acceptedVerdict,
  );
}

typedef L10nEvidenceEvaluatorFactory = L10nEvidenceEvaluator Function();

final class L10nMutationNegativeResult {
  L10nMutationNegativeResult({
    required this.rejected,
    required this.observedReason,
    required this.evidenceIdentity,
  }) {
    if (!_safeIdentity(observedReason) ||
        !_safeRecordIdentity(evidenceIdentity) ||
        evidenceIdentity == 'notRun') {
      throw ArgumentError(
        'negative fixture evidence is malformed or unredacted',
      );
    }
  }

  final bool rejected;
  final String observedReason;
  final String evidenceIdentity;
}

abstract interface class L10nMutationNegativeFixtureRunner {
  Future<L10nMutationNegativeResult> run(
    String fixtureId,
    List<String> allowedReasons,
  );
}

abstract interface class L10nReadinessCheckpointStore {
  Future<L10nReadinessCheckpointLease> claim(File outputFile);
}

abstract interface class L10nReadinessCheckpointLease {
  Future<Object?> read();
  Future<void> write(String canonicalJson);
  Future<void> release();
}

abstract interface class MonotonicMicros {
  int now();
}

typedef L10nReadinessPlanLoader =
    Future<L10nReadinessPlan> Function(L10nMutationReadinessOptions options);
typedef L10nReadinessViewProvisioner =
    Future<L10nReadinessProjectView> Function(String projectId);

/// Explicit dependency surface for deterministic fake orchestration.
final class L10nMutationReadinessDependencies {
  const L10nMutationReadinessDependencies({
    required this.loadPlan,
    required this.provisionView,
    required this.scanner,
    required this.evaluatorFactory,
    required this.corpusEvidenceRunner,
    required this.negativeFixtureRunner,
    required this.checkpointStore,
    required this.monotonicMicros,
    this.onStaticGate,
    this.enableProjectEligibilityPreflight = false,
  });

  final L10nReadinessPlanLoader loadPlan;
  final L10nReadinessViewProvisioner provisionView;
  final L10nHarnessScanner scanner;
  final L10nEvidenceEvaluatorFactory evaluatorFactory;
  final L10nCorpusEvidenceRunner corpusEvidenceRunner;
  final L10nMutationNegativeFixtureRunner negativeFixtureRunner;
  final L10nReadinessCheckpointStore checkpointStore;
  final MonotonicMicros monotonicMicros;
  final void Function(String projectId)? onStaticGate;
  final bool enableProjectEligibilityPreflight;
}

/// Recursively sorts JSON object keys and appends exactly one final newline.
String canonicalL10nReadinessJson(Map<String, Object?> value) =>
    '${const JsonEncoder.withIndent('  ').convert(_canonicalize(value))}\n';

Object? _canonicalize(Object? value) {
  if (value is Map) {
    final sorted = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      if (entry.key is! String) {
        throw const FormatException('JSON object keys must be strings');
      }
      sorted[entry.key as String] = _canonicalize(entry.value);
    }
    return sorted;
  }
  if (value is List) return value.map(_canonicalize).toList(growable: false);
  if (value is num && !value.isFinite) {
    throw const FormatException('non-finite JSON numbers are forbidden');
  }
  if (value == null || value is String || value is bool || value is num) {
    return value;
  }
  throw const FormatException('value is not JSON-safe');
}

Object? _deepFreezeRedactedJson(Object? value) {
  if (value is Map) {
    final result = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      if (entry.key is! String || !_safeIdentity(entry.key as String)) {
        throw const FormatException('identity key is malformed');
      }
      result[entry.key as String] = _deepFreezeRedactedJson(entry.value);
    }
    return Map<String, Object?>.unmodifiable(result);
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_deepFreezeRedactedJson));
  }
  if (value is String) {
    if (!_redactedValue(value)) {
      throw const FormatException('identity value is unredacted');
    }
    return value;
  }
  if (value is num && !value.isFinite) {
    throw const FormatException('identity number is non-finite');
  }
  if (value == null || value is bool || value is num) return value;
  throw const FormatException('identity value is not JSON-safe');
}

bool _redactedValue(String value) =>
    value.isNotEmpty &&
    value.length <= 4096 &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]')) &&
    !value.contains('://') &&
    !value.toLowerCase().startsWith('file:') &&
    !p.isAbsolute(value) &&
    !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) &&
    !value.startsWith('~');

Map<String, Object?> _stringMap(Object? value) {
  if (value is! Map) throw const FormatException('expected JSON object');
  return value.map((key, item) {
    if (key is! String) throw const FormatException('expected string key');
    return MapEntry(key, item);
  });
}

Directory _absoluteExistingDirectory(String path) {
  if (!p.isAbsolute(path) || p.normalize(path) != path) {
    throw const FormatException(
      'directory path must be normalized and absolute',
    );
  }
  final directory = Directory(path);
  if (!directory.existsSync()) {
    throw const FormatException('directory does not exist');
  }
  return _canonicalDirectory(directory);
}

Directory _canonicalDirectory(Directory directory) {
  if (!directory.existsSync()) {
    throw const FormatException('authority directory does not exist');
  }
  return Directory(directory.resolveSymbolicLinksSync());
}

File _canonicalExistingFile(String path) {
  if (!p.isAbsolute(path) || p.normalize(path) != path) {
    throw const FormatException('file path must be canonical and absolute');
  }
  final file = File(path);
  if (!file.existsSync()) throw const FormatException('file does not exist');
  final canonical = File(file.resolveSymbolicLinksSync());
  if (!p.equals(canonical.path, path)) {
    throw const FormatException('file path must already be canonical');
  }
  return canonical;
}

File _absoluteOutputFile(String path, {required File? resumeFile}) {
  if (!p.isAbsolute(path) || p.normalize(path) != path) {
    throw const FormatException('output path must be normalized and absolute');
  }
  if (p.extension(path) != '.json') {
    throw const FormatException('output must be a JSON file');
  }
  final parent = _absoluteExistingDirectory(p.dirname(path));
  final canonicalParent = Directory(parent.resolveSymbolicLinksSync());
  final output = File(p.join(canonicalParent.path, p.basename(path)));
  final type = FileSystemEntity.typeSync(output.path, followLinks: false);
  if (type != FileSystemEntityType.notFound &&
      type != FileSystemEntityType.file) {
    throw const FormatException('output must be absent or a regular file');
  }
  if (type == FileSystemEntityType.file) {
    if (resumeFile == null ||
        !p.equals(
          File(output.resolveSymbolicLinksSync()).path,
          File(resumeFile.resolveSymbolicLinksSync()).path,
        )) {
      throw const FormatException(
        'an existing output must be the resumed artifact',
      );
    }
  }
  return output;
}

bool _safeRelativePath(String value) {
  final segments = p.posix.split(value.replaceAll('\\', '/'));
  return value.isNotEmpty &&
      !value.contains('\\') &&
      segments.every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
      );
}

bool _safeIdentity(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    value.length <= 256 &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

bool _validCaseSelection(String value) {
  final separator = value.indexOf(':');
  return separator > 0 &&
      separator == value.lastIndexOf(':') &&
      _safeIdentity(value.substring(0, separator)) &&
      _safeIdentity(value.substring(separator + 1));
}

void _validatePlan(L10nReadinessPlan plan) {
  if (!_safeIdentity(plan.oracleVersion) || plan.identities.isEmpty) {
    throw const FormatException('readiness plan identity is malformed');
  }
  final cases = <String, L10nReadinessOracleCase>{};
  for (final oracleCase in plan.oracleCases) {
    if (!_safeIdentity(oracleCase.projectId) ||
        !_safeIdentity(oracleCase.decodedKey) ||
        !_safeRecordIdentity(oracleCase.caseId) ||
        cases.containsKey(oracleCase.caseId)) {
      throw const FormatException('readiness oracle case is malformed');
    }
    cases[oracleCase.caseId] = oracleCase;
  }
  if (plan.individualCaseIds.toSet().length != plan.individualCaseIds.length ||
      plan.familyProjectIds.toSet().length != plan.familyProjectIds.length ||
      plan.mutationNegativeFixtures.keys.toSet().length !=
          plan.mutationNegativeFixtures.length) {
    throw const FormatException('readiness plan contains duplicate work');
  }
  for (final id in plan.individualCaseIds) {
    if (cases[id]?.mutationPositive != true) {
      throw const FormatException('individual selection is not positive');
    }
  }
  final projectIds = plan.oracleCases.map((entry) => entry.projectId).toSet();
  if (!plan.familyProjectIds.every(projectIds.contains)) {
    throw const FormatException('family selection is unknown');
  }
  for (final projectId in plan.familyProjectIds) {
    if (!plan.oracleCases.any(
      (entry) => entry.projectId == projectId && entry.mutationPositive,
    )) {
      throw const FormatException('family selection contains no positive key');
    }
  }
  for (final entry in plan.mutationNegativeFixtures.entries) {
    if (!_safeIdentity(entry.key) ||
        entry.value.isEmpty ||
        entry.value.any((reason) => !_safeIdentity(reason))) {
      throw const FormatException('negative fixture is malformed');
    }
  }
  final denominators = plan.expectedDenominators;
  if (denominators.individualKeys != plan.individualCaseIds.length ||
      denominators.familyBatches != plan.familyProjectIds.length ||
      denominators.mutationNegativeFixtures !=
          plan.mutationNegativeFixtures.length ||
      denominators.requiredRestorations !=
          denominators.individualKeys + denominators.familyBatches ||
      denominators.staticPositiveCandidates !=
          plan.oracleCases.where((entry) => entry.mutationPositive).length ||
      denominators.staticNegativeNonCandidates !=
          plan.oracleCases.where((entry) => !entry.mutationPositive).length) {
    throw const FormatException('readiness plan denominator drift');
  }
  if (plan.profile == L10nReadinessProfile.productionStage1) {
    const requiredIdentityKeys = <String>{
      'coverageSpecSha256',
      'implementationSha256',
      'manifestSha256',
      'negativeRecipeMatrixSha256',
      'policySetSha256',
      'repositorySetSha256',
      'sdkSetSha256',
    };
    if (projectIds.isEmpty ||
        projectIds.difference(const {
          'gitjournal',
          'gsy',
          'smooth',
        }).isNotEmpty ||
        plan.protectedRoots.map((root) => root.path).toSet().length < 3 ||
        plan.identities.keys
            .toSet()
            .difference(requiredIdentityKeys)
            .isNotEmpty ||
        requiredIdentityKeys
            .difference(plan.identities.keys.toSet())
            .isNotEmpty ||
        plan.identities.values.any(
          (value) =>
              value is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
        )) {
      throw const FormatException('production Stage 1 plan is incomplete');
    }
  }
}

void _validatePlanForOptions(
  L10nReadinessPlan plan,
  L10nMutationReadinessOptions options,
) {
  if (options.caseSelection case final String selection) {
    final separator = selection.indexOf(':');
    final projectId = selection.substring(0, separator);
    final decodedKey = selection.substring(separator + 1);
    if (plan.individualCaseIds.length != 1 ||
        plan.familyProjectIds.isNotEmpty ||
        plan.mutationNegativeFixtures.isNotEmpty) {
      throw const FormatException('case scope work plan drift');
    }
    final oracleCase = plan.oracleCases.singleWhere(
      (entry) => entry.caseId == plan.individualCaseIds.single,
      orElse: () => throw const FormatException('case scope is unknown'),
    );
    if (oracleCase.projectId != projectId ||
        oracleCase.decodedKey != decodedKey ||
        !oracleCase.mutationPositive) {
      throw const FormatException('case scope selection drift');
    }
    if (plan.profile == L10nReadinessProfile.productionStage1 &&
        plan.oracleCases.map((entry) => entry.projectId).toSet().difference({
          projectId,
        }).isNotEmpty) {
      throw const FormatException('production case scope project drift');
    }
  } else if (options.familySelection case final String selection) {
    if (plan.individualCaseIds.isNotEmpty ||
        plan.familyProjectIds.length != 1 ||
        plan.familyProjectIds.single != selection ||
        plan.mutationNegativeFixtures.isNotEmpty) {
      throw const FormatException('family scope work plan drift');
    }
    if (plan.profile == L10nReadinessProfile.productionStage1 &&
        plan.oracleCases.map((entry) => entry.projectId).toSet().difference({
          selection,
        }).isNotEmpty) {
      throw const FormatException('production family scope project drift');
    }
  } else if (plan.profile == L10nReadinessProfile.productionStage1) {
    const productionProjects = {'gitjournal', 'gsy', 'smooth'};
    final projectIds = plan.oracleCases.map((entry) => entry.projectId).toSet();
    if (!_sameDenominators(
          plan.expectedDenominators,
          L10nReadinessDenominators.productionFull,
        ) ||
        projectIds.difference(productionProjects).isNotEmpty ||
        productionProjects.difference(projectIds).isNotEmpty ||
        plan.familyProjectIds
            .toSet()
            .difference(productionProjects)
            .isNotEmpty ||
        productionProjects
            .difference(plan.familyProjectIds.toSet())
            .isNotEmpty) {
      throw const FormatException('full production scope denominator drift');
    }
  }
}

void _validateOutputAuthority(
  L10nReadinessPlan plan,
  L10nMutationReadinessOptions options,
) {
  final outputPath = options.outputFile.path;
  final artifactRoot = plan.artifactRoot.path;
  if (!p.isWithin(artifactRoot, outputPath)) {
    throw const FormatException('output is outside the artifact authority');
  }
  final protectedRoots = <Directory>{
    ...plan.protectedRoots,
    for (final flutter in options.sdkFlutterByVersion.values)
      flutter.parent.parent,
  };
  for (final root in protectedRoots) {
    final path = _canonicalDirectory(root).path;
    if (p.equals(outputPath, path) || p.isWithin(path, outputPath)) {
      throw const FormatException('output overlaps a protected authority');
    }
    if (plan.profile == L10nReadinessProfile.productionStage1 &&
        (p.equals(artifactRoot, path) ||
            p.isWithin(path, artifactRoot) ||
            p.isWithin(artifactRoot, path))) {
      throw const FormatException('artifact and protected roots overlap');
    }
  }
  if (plan.profile == L10nReadinessProfile.productionStage1 &&
      options.caseSelection == null &&
      options.familySelection == null) {
    final corpusRoot = _canonicalDirectory(options.corpusRoot).path;
    final expectedRoot = p.join(corpusRoot, 'results');
    if (!p.equals(artifactRoot, expectedRoot)) {
      throw const FormatException('production artifact root must be results');
    }
  }
}

bool _sameDenominators(
  L10nReadinessDenominators left,
  L10nReadinessDenominators right,
) => _jsonEquals(left.toJson(), right.toJson());

bool _safeRecordIdentity(String value) =>
    value.isNotEmpty &&
    value != '.' &&
    value != '..' &&
    value.length <= 512 &&
    RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);

/// Runs the contract-only readiness harness. Exit 0 means every denominator in
/// the selected scope passed, 1 means terminal evidence failed, and 2 means the
/// invocation, plan, resume artifact, dependency result, or checkpoint
/// authority was invalid.
Future<int> runL10nMutationReadiness(
  List<String> arguments, {
  required L10nMutationReadinessDependencies dependencies,
}) async {
  late final L10nMutationReadinessOptions options;
  late final L10nReadinessPlan plan;
  try {
    options = L10nMutationReadinessOptions.parse(arguments);
    plan = await dependencies.loadPlan(options);
    _validatePlanForOptions(plan, options);
    _validateOutputAuthority(plan, options);
  } catch (error, stackTrace) {
    _debugReadinessError(error, stackTrace);
    return 2;
  }

  L10nReadinessCheckpointLease? lease;
  var result = 2;
  try {
    lease = await dependencies.checkpointStore.claim(options.outputFile);
    late final _ReadinessArtifact artifact;
    if (options.resumeFile == null) {
      artifact = _ReadinessArtifact.empty(plan, options);
    } else {
      final value = await lease.read();
      artifact = _ReadinessArtifact.resume(plan, options, value);
    }
    final hasPendingWork = artifact.hasPendingWork;
    if (!hasPendingWork && artifact.terminalCheckpointPresent) {
      result = artifact.status == 'passed' ? 0 : 1;
    } else {
      if (hasPendingWork) {
        // Prove checkpoint persistence before provisioning any mutable view.
        await _writeCheckpoint(lease, artifact);
      }
      if (dependencies.enableProjectEligibilityPreflight) {
        for (final projectId in [...plan.familyProjectIds]..sort()) {
          if (artifact.familyBatches.containsKey(projectId)) continue;
          final attempt = await _runFamilyAttempt(
            plan: plan,
            projectId: projectId,
            dependencies: dependencies,
          );
          artifact.recordProject(attempt.project);
          artifact.familyBatches[projectId] = attempt.record;
          await _writeCheckpoint(lease, artifact);
        }
      }

      for (final caseId in [...plan.individualCaseIds]..sort()) {
        if (artifact.cases.containsKey(caseId)) continue;
        final oracleCase = artifact.oracleById[caseId]!;
        final eligibility = dependencies.enableProjectEligibilityPreflight
            ? artifact.familyBatches[oracleCase.projectId]
            : null;
        if (eligibility != null && eligibility['status'] == 'failed') {
          final project = artifact.projects[oracleCase.projectId];
          if (project == null) {
            throw StateError('eligibility scan evidence is unavailable');
          }
          artifact.cases[caseId] = _eligibilityRejectedCaseRecord(
            oracleCase,
            project,
            eligibility,
          );
          await _writeCheckpoint(lease, artifact);
          continue;
        }
        final attempt = await _runIndividualAttempt(
          plan: plan,
          oracleCase: oracleCase,
          dependencies: dependencies,
        );
        artifact.recordProject(attempt.project);
        artifact.cases[caseId] = attempt.record;
        await _writeCheckpoint(lease, artifact);
      }

      if (!dependencies.enableProjectEligibilityPreflight) {
        for (final projectId in [...plan.familyProjectIds]..sort()) {
          if (artifact.familyBatches.containsKey(projectId)) continue;
          final attempt = await _runFamilyAttempt(
            plan: plan,
            projectId: projectId,
            dependencies: dependencies,
          );
          artifact.recordProject(attempt.project);
          artifact.familyBatches[projectId] = attempt.record;
          await _writeCheckpoint(lease, artifact);
        }
      }

      final fixtureIds = plan.mutationNegativeFixtures.keys.toList()..sort();
      for (final fixtureId in fixtureIds) {
        if (artifact.mutationNegativeFixtures.containsKey(fixtureId)) continue;
        artifact.mutationNegativeFixtures[fixtureId] =
            await _runNegativeFixture(
              fixtureId,
              plan.mutationNegativeFixtures[fixtureId]!,
              plan,
              dependencies,
            );
        await _writeCheckpoint(lease, artifact);
      }

      await _writeCheckpoint(lease, artifact, finalArtifact: true);
      result = artifact.status == 'passed' ? 0 : 1;
    }
  } catch (error, stackTrace) {
    _debugReadinessError(error, stackTrace);
    result = 2;
  }
  if (lease != null) {
    try {
      await lease.release();
    } catch (_) {
      result = 2;
    }
  }
  return result;
}

void _debugReadinessError(Object error, StackTrace stackTrace) {
  if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
    stderr
      ..writeln(error)
      ..writeln(stackTrace);
  }
}

Future<void> _writeCheckpoint(
  L10nReadinessCheckpointLease lease,
  _ReadinessArtifact artifact, {
  bool finalArtifact = false,
}) => lease.write(
  canonicalL10nReadinessJson(artifact.toJson(finalArtifact: finalArtifact)),
);

Future<_AttemptRecord> _runIndividualAttempt({
  required L10nReadinessPlan plan,
  required L10nReadinessOracleCase oracleCase,
  required L10nMutationReadinessDependencies dependencies,
}) async {
  final start = dependencies.monotonicMicros.now();
  L10nReadinessProjectView? view;
  _StaticProjectRecord? project;
  L10nEvidenceResult? evidence;
  String? actualNodeId;
  var failureReason = 'staticOracleMismatch';
  Object? attemptError;
  StackTrace? attemptStackTrace;
  try {
    view = await dependencies.provisionView(oracleCase.projectId);
    if (view.projectId != oracleCase.projectId) {
      throw const FormatException('provisioned project identity drift');
    }
    final projectCases = _projectCases(plan, oracleCase.projectId);
    final scan = await dependencies.scanner.scan(view, projectCases);
    dependencies.onStaticGate?.call(oracleCase.projectId);
    project = _evaluateStaticGate(oracleCase.projectId, projectCases, scan);
    if (!project.passed) {
      failureReason = 'staticOracleMismatch';
    } else {
      actualNodeId = scan.actualNodeIdByOracleCaseId[oracleCase.caseId];
      final evaluator = dependencies.evaluatorFactory();
      final internal = await evaluator.evaluateIndividual(
        view,
        oracleCase,
        scan,
      );
      if (internal.selectionIdentity != oracleCase.caseId) {
        throw const FormatException('internal evidence selection drift');
      }
      final corpus = internal.accepted
          ? await dependencies.corpusEvidenceRunner.run(
              view,
              oracleCase.caseId,
              internal,
            )
          : null;
      evidence = L10nEvidenceResult.fromInternal(
        oracleCase.caseId,
        internal,
        corpus,
      );
      failureReason = !internal.accepted
          ? 'internalVerdictRejected'
          : evidence.passed
          ? ''
          : 'corpusEvidenceRejected';
    }
  } catch (error, stackTrace) {
    attemptError = error;
    attemptStackTrace = stackTrace;
  }
  if (view != null) {
    try {
      await view.dispose();
    } catch (error, stackTrace) {
      attemptError ??= error;
      attemptStackTrace ??= stackTrace;
    }
  }
  if (attemptError != null) {
    Error.throwWithStackTrace(attemptError, attemptStackTrace!);
  }
  if (project == null) {
    throw StateError('individual attempt produced no static project record');
  }
  final passed = project.passed && evidence?.passed == true;
  final record = <String, Object?>{
    'actualNodeId': actualNodeId,
    'attemptMicros': _elapsed(start, dependencies.monotonicMicros.now()),
    'caseId': oracleCase.caseId,
    'decodedKey': oracleCase.decodedKey,
    'evidence': evidence?.toJson(),
    'expectedScannerPresence': oracleCase.expectedScannerPresence,
    'failureReason': passed ? null : failureReason,
    'projectId': oracleCase.projectId,
    'status': passed ? 'passed' : 'failed',
  };
  _validateProjectRecord(project.json, plan);
  _validateCaseRecord(record, {oracleCase.caseId: oracleCase});
  return _AttemptRecord(project: project, record: record);
}

Future<_AttemptRecord> _runFamilyAttempt({
  required L10nReadinessPlan plan,
  required String projectId,
  required L10nMutationReadinessDependencies dependencies,
}) async {
  final start = dependencies.monotonicMicros.now();
  final projectCases = _projectCases(plan, projectId);
  final positives = projectCases
      .where((entry) => entry.mutationPositive)
      .toList(growable: false);
  L10nReadinessProjectView? view;
  _StaticProjectRecord? project;
  L10nEvidenceResult? evidence;
  var failureReason = 'staticOracleMismatch';
  Object? attemptError;
  StackTrace? attemptStackTrace;
  try {
    view = await dependencies.provisionView(projectId);
    if (view.projectId != projectId) {
      throw const FormatException('provisioned project identity drift');
    }
    final scan = await dependencies.scanner.scan(view, projectCases);
    dependencies.onStaticGate?.call(projectId);
    project = _evaluateStaticGate(projectId, projectCases, scan);
    if (!project.passed) {
      failureReason = 'staticOracleMismatch';
    } else {
      final evaluator = dependencies.evaluatorFactory();
      final internal = await evaluator.evaluateFamily(view, positives, scan);
      final selectionIdentity = 'family:$projectId';
      if (internal.selectionIdentity != selectionIdentity) {
        throw const FormatException('internal evidence selection drift');
      }
      final corpus = internal.accepted
          ? await dependencies.corpusEvidenceRunner.run(
              view,
              selectionIdentity,
              internal,
            )
          : null;
      evidence = L10nEvidenceResult.fromInternal(
        selectionIdentity,
        internal,
        corpus,
      );
      failureReason = !internal.accepted
          ? 'internalVerdictRejected'
          : evidence.passed
          ? ''
          : 'corpusEvidenceRejected';
    }
  } catch (error, stackTrace) {
    attemptError = error;
    attemptStackTrace = stackTrace;
  }
  if (view != null) {
    try {
      await view.dispose();
    } catch (error, stackTrace) {
      attemptError ??= error;
      attemptStackTrace ??= stackTrace;
    }
  }
  if (attemptError != null) {
    Error.throwWithStackTrace(attemptError, attemptStackTrace!);
  }
  if (project == null) {
    throw StateError('family attempt produced no static project record');
  }
  final passed = project.passed && evidence?.passed == true;
  final caseIds = positives.map((entry) => entry.caseId).toList()..sort();
  final record = <String, Object?>{
    'attemptMicros': _elapsed(start, dependencies.monotonicMicros.now()),
    'caseIds': caseIds,
    'evidence': evidence?.toJson(),
    'failureReason': passed ? null : failureReason,
    'projectId': projectId,
    'status': passed ? 'passed' : 'failed',
  };
  _validateProjectRecord(project.json, plan);
  _validateFamilyRecord(record, plan);
  return _AttemptRecord(project: project, record: record);
}

Future<Map<String, Object?>> _runNegativeFixture(
  String fixtureId,
  List<String> allowedReasons,
  L10nReadinessPlan plan,
  L10nMutationReadinessDependencies dependencies,
) async {
  final result = await dependencies.negativeFixtureRunner.run(
    fixtureId,
    List.unmodifiable(allowedReasons),
  );
  final passed =
      result.rejected && allowedReasons.contains(result.observedReason);
  final record = <String, Object?>{
    'allowedReasons': [...allowedReasons]..sort(),
    'evidenceIdentity': result.evidenceIdentity,
    'fixtureId': fixtureId,
    'observedReason': result.observedReason,
    'rejected': result.rejected,
    'status': passed ? 'passed' : 'failed',
  };
  _validateNegativeRecord(record, plan);
  return record;
}

Map<String, Object?> _eligibilityRejectedCaseRecord(
  L10nReadinessOracleCase oracleCase,
  Map<String, Object?> project,
  Map<String, Object?> family,
) {
  final staticMismatch = project['status'] == 'failed';
  if (staticMismatch != (family['failureReason'] == 'staticOracleMismatch')) {
    throw const FormatException('eligibility evidence is inconsistent');
  }
  return {
    'actualNodeId': null,
    'attemptMicros': 0,
    'caseId': oracleCase.caseId,
    'decodedKey': oracleCase.decodedKey,
    'evidence': null,
    'expectedScannerPresence': oracleCase.expectedScannerPresence,
    'failureReason': staticMismatch
        ? 'staticOracleMismatch'
        : 'projectEligibilityRejected',
    'projectId': oracleCase.projectId,
    'status': 'failed',
  };
}

List<L10nReadinessOracleCase> _projectCases(
  L10nReadinessPlan plan,
  String projectId,
) =>
    plan.oracleCases
        .where((entry) => entry.projectId == projectId)
        .toList(growable: false)
      ..sort((left, right) => left.caseId.compareTo(right.caseId));

_StaticProjectRecord _evaluateStaticGate(
  String projectId,
  List<L10nReadinessOracleCase> oracleCases,
  L10nStaticScanResult scan,
) {
  final knownIds = oracleCases.map((entry) => entry.caseId).toSet();
  var positiveCandidates = 0;
  var negativeNonCandidates = 0;
  var mismatches = 0;
  final actualIds = <String>{};
  for (final oracleCase in oracleCases) {
    final candidate = scan.candidateOracleCaseIds.contains(oracleCase.caseId);
    final actualNode = scan.actualNodeIdByOracleCaseId[oracleCase.caseId];
    if (actualNode == null ||
        !_safeRecordIdentity(actualNode) ||
        !actualIds.add(actualNode)) {
      mismatches++;
    }
    if (oracleCase.mutationPositive) {
      if (candidate) {
        positiveCandidates++;
      } else {
        mismatches++;
      }
    } else if (candidate) {
      mismatches++;
    } else {
      negativeNonCandidates++;
    }
  }
  mismatches += scan.candidateOracleCaseIds.difference(knownIds).length;
  mismatches += scan.actualNodeIdByOracleCaseId.keys
      .toSet()
      .difference(knownIds)
      .length;
  for (final value in <int>[
    scan.publicSafeL10n,
    scan.publicHighL10n,
    scan.publicApplyEligibleL10n,
    scan.publicProposedL10nActions,
  ]) {
    if (value < 0) mismatches++;
  }
  if (scan.publicSafeL10n != 0 ||
      scan.publicHighL10n != 0 ||
      scan.publicApplyEligibleL10n != 0 ||
      scan.publicProposedL10nActions != 0) {
    mismatches++;
  }
  if (!_safeRecordIdentity(scan.authorityIdentity)) mismatches++;
  return _StaticProjectRecord({
    'projectId': projectId,
    'publicApplyEligibleL10n': scan.publicApplyEligibleL10n,
    'publicHighL10n': scan.publicHighL10n,
    'publicProposedL10nActions': scan.publicProposedL10nActions,
    'publicSafeL10n': scan.publicSafeL10n,
    'scanAuthorityIdentity': scan.authorityIdentity,
    'staticNegativeNonCandidates': negativeNonCandidates,
    'staticOracleMismatchCount': mismatches,
    'staticPositiveCandidates': positiveCandidates,
    'status': mismatches == 0 ? 'passed' : 'failed',
  });
}

int _elapsed(int start, int end) {
  if (end < start) throw StateError('monotonic clock regressed');
  return end - start;
}

final class _AttemptRecord {
  const _AttemptRecord({required this.project, required this.record});

  final _StaticProjectRecord project;
  final Map<String, Object?> record;
}

final class _StaticProjectRecord {
  const _StaticProjectRecord(this.json);

  final Map<String, Object?> json;
  bool get passed => json['status'] == 'passed';
}

final class _ReadinessArtifact {
  _ReadinessArtifact._({
    required this.plan,
    required this.scope,
    required this.projects,
    required this.cases,
    required this.familyBatches,
    required this.mutationNegativeFixtures,
    required this.terminalCheckpointPresent,
  }) : oracleById = Map.unmodifiable({
         for (final oracleCase in plan.oracleCases)
           oracleCase.caseId: oracleCase,
       });

  factory _ReadinessArtifact.empty(
    L10nReadinessPlan plan,
    L10nMutationReadinessOptions options,
  ) => _ReadinessArtifact._(
    plan: plan,
    scope: _scopeFor(plan, options),
    projects: {},
    cases: {},
    familyBatches: {},
    mutationNegativeFixtures: {},
    terminalCheckpointPresent: false,
  );

  factory _ReadinessArtifact.resume(
    L10nReadinessPlan plan,
    L10nMutationReadinessOptions options,
    Object? value,
  ) {
    final root = _stringMap(value);
    _requireExactKeys(root, _topLevelKeys, 'artifact');
    if (root['schemaVersion'] != _schemaVersion ||
        root['artifactKind'] != _artifactKind ||
        root['oracleVersion'] != plan.oracleVersion ||
        !_jsonEquals(root['scope'], _scopeFor(plan, options)) ||
        !_jsonEquals(root['identities'], plan.identities)) {
      throw const FormatException('resume identity drift');
    }
    final performance = _objectList(root['performance'], 'performance');
    if (performance.isNotEmpty) {
      throw const FormatException(
        'contract artifact cannot resume performance',
      );
    }

    final projects = _parseRecords(
      root['projects'],
      identityKey: 'projectId',
      exactKeys: _projectRecordKeys,
      allowedIds: _requiredProjectIds(plan),
      validator: (record) => _validateProjectRecord(record, plan),
    );
    final individualIds = plan.individualCaseIds.toSet();
    final oracleById = {
      for (final oracleCase in plan.oracleCases) oracleCase.caseId: oracleCase,
    };
    final cases = _parseRecords(
      root['cases'],
      identityKey: 'caseId',
      exactKeys: _caseRecordKeys,
      allowedIds: individualIds,
      validator: (record) => _validateCaseRecord(record, oracleById),
    );
    final familyBatches = _parseRecords(
      root['familyBatches'],
      identityKey: 'projectId',
      exactKeys: _familyRecordKeys,
      allowedIds: plan.familyProjectIds.toSet(),
      validator: (record) => _validateFamilyRecord(record, plan),
    );
    final mutationNegativeFixtures = _parseRecords(
      root['mutationNegativeFixtures'],
      identityKey: 'fixtureId',
      exactKeys: _negativeRecordKeys,
      allowedIds: plan.mutationNegativeFixtures.keys.toSet(),
      validator: (record) => _validateNegativeRecord(record, plan),
    );
    final artifact = _ReadinessArtifact._(
      plan: plan,
      scope: _scopeFor(plan, options),
      projects: projects,
      cases: cases,
      familyBatches: familyBatches,
      mutationNegativeFixtures: mutationNegativeFixtures,
      terminalCheckpointPresent: root['status'] != 'inProgress',
    );
    for (final record in <Map<String, Object?>>[
      ...cases.values,
      ...familyBatches.values,
    ]) {
      final project = projects[record['projectId']];
      final staticMismatch = record['failureReason'] == 'staticOracleMismatch';
      if (project == null ||
          staticMismatch && project['status'] != 'failed' ||
          !staticMismatch && project['status'] != 'passed') {
        throw const FormatException(
          'mutation evidence lacks its exact project scan state',
        );
      }
    }
    for (final record in cases.values.where(
      (entry) => entry['failureReason'] == 'projectEligibilityRejected',
    )) {
      final family = familyBatches[record['projectId']];
      if (family == null ||
          family['status'] != 'failed' ||
          family['failureReason'] == 'staticOracleMismatch') {
        throw const FormatException(
          'eligibility rejection lacks its family evidence',
        );
      }
    }
    final referencedProjects = <String>{
      for (final record in [...cases.values, ...familyBatches.values])
        record['projectId']! as String,
    };
    if (projects.keys.toSet().difference(referencedProjects).isNotEmpty) {
      throw const FormatException('resume contains an orphan project scan');
    }
    final storedStatus = root['status'];
    if (!_jsonEquals(root['summary'], artifact.summary) ||
        storedStatus != 'inProgress' && storedStatus != artifact.status) {
      throw const FormatException('resume summary or status drift');
    }
    return artifact;
  }

  final L10nReadinessPlan plan;
  final Map<String, Object?> scope;
  final Map<String, L10nReadinessOracleCase> oracleById;
  final Map<String, Map<String, Object?>> projects;
  final Map<String, Map<String, Object?>> cases;
  final Map<String, Map<String, Object?>> familyBatches;
  final Map<String, Map<String, Object?>> mutationNegativeFixtures;
  final bool terminalCheckpointPresent;

  void recordProject(_StaticProjectRecord project) {
    final projectId = project.json['projectId']! as String;
    final existing = projects[projectId];
    if (existing != null && !_jsonEquals(existing, project.json)) {
      throw const FormatException('project scan evidence drifted across work');
    }
    projects[projectId] = Map.unmodifiable(project.json);
  }

  bool get hasPendingWork =>
      cases.length != plan.individualCaseIds.length ||
      familyBatches.length != plan.familyProjectIds.length ||
      mutationNegativeFixtures.length != plan.mutationNegativeFixtures.length;

  String get status {
    if (hasPendingWork) return 'inProgress';
    return _summaryPasses(summary) ? 'passed' : 'failed';
  }

  Map<String, Object?> get summary {
    final projectRecords = projects.values;
    final caseRecords = cases.values;
    final familyRecords = familyBatches.values;
    final negativeRecords = mutationNegativeFixtures.values;
    final evidence = <Map<String, Object?>>[
      for (final record in [...caseRecords, ...familyRecords])
        if (record['evidence'] case final Map<Object?, Object?> value)
          _stringMap(value),
    ];
    return {
      'acceptedFamilyBatches': familyRecords
          .where((record) => record['status'] == 'passed')
          .length,
      'acceptedIndividualKeys': caseRecords
          .where((record) => record['status'] == 'passed')
          .length,
      'fullPolicyFailures': evidence
          .where(
            (record) =>
                record['acceptedInternalVerdict'] == true &&
                record['corpusPolicyPassed'] != true,
          )
          .length,
      'mutationNegativeFixturesPassed': negativeRecords
          .where((record) => record['status'] == 'passed')
          .length,
      'originalProjectDriftCount': evidence
          .where((record) => record['originalProjectDrift'] == true)
          .length,
      'passedStaticProjects': projectRecords
          .where((record) => record['status'] == 'passed')
          .length,
      'passedPerformanceProjects': 0,
      'provenRestorations': evidence
          .where((record) => record['restorationProven'] == true)
          .length,
      'publicApplyEligibleL10n': _sum(
        projectRecords,
        'publicApplyEligibleL10n',
      ),
      'publicHighL10n': _sum(projectRecords, 'publicHighL10n'),
      'publicProposedL10nActions': _sum(
        projectRecords,
        'publicProposedL10nActions',
      ),
      'publicSafeL10n': _sum(projectRecords, 'publicSafeL10n'),
      'requiredFamilyBatches': plan.expectedDenominators.familyBatches,
      'requiredIndividualKeys': plan.expectedDenominators.individualKeys,
      'requiredMutationNegativeFixtures':
          plan.expectedDenominators.mutationNegativeFixtures,
      'requiredPerformanceProjects': 0,
      'requiredRestorations': plan.expectedDenominators.requiredRestorations,
      'requiredStaticProjects': _requiredProjectIds(plan).length,
      'requiredStaticNegativeNonCandidates':
          plan.expectedDenominators.staticNegativeNonCandidates,
      'requiredStaticPositiveCandidates':
          plan.expectedDenominators.staticPositiveCandidates,
      'staticNegativeNonCandidates': _sum(
        projectRecords,
        'staticNegativeNonCandidates',
      ),
      'staticOracleMismatchCount': _sum(
        projectRecords,
        'staticOracleMismatchCount',
      ),
      'staticPositiveCandidates': _sum(
        projectRecords,
        'staticPositiveCandidates',
      ),
      'unexpectedWritesForAccepted': evidence
          .where((record) => record['acceptedInternalVerdict'] == true)
          .fold<int>(
            0,
            (sum, record) => sum + (record['unexpectedWriteCount']! as int),
          ),
    };
  }

  Map<String, Object?> toJson({required bool finalArtifact}) => {
    'schemaVersion': _schemaVersion,
    'artifactKind': _artifactKind,
    'oracleVersion': plan.oracleVersion,
    'status': finalArtifact ? status : 'inProgress',
    'scope': scope,
    'identities': plan.identities,
    'projects': _sortedRecords(projects, 'projectId'),
    'cases': _sortedRecords(cases, 'caseId'),
    'familyBatches': _sortedRecords(familyBatches, 'projectId'),
    'mutationNegativeFixtures': _sortedRecords(
      mutationNegativeFixtures,
      'fixtureId',
    ),
    'performance': const <Object?>[],
    'summary': summary,
  };
}

const _projectRecordKeys = <String>{
  'projectId',
  'publicApplyEligibleL10n',
  'publicHighL10n',
  'publicProposedL10nActions',
  'publicSafeL10n',
  'scanAuthorityIdentity',
  'staticNegativeNonCandidates',
  'staticOracleMismatchCount',
  'staticPositiveCandidates',
  'status',
};
const _caseRecordKeys = <String>{
  'actualNodeId',
  'attemptMicros',
  'caseId',
  'decodedKey',
  'evidence',
  'expectedScannerPresence',
  'failureReason',
  'projectId',
  'status',
};
const _familyRecordKeys = <String>{
  'attemptMicros',
  'caseIds',
  'evidence',
  'failureReason',
  'projectId',
  'status',
};
const _negativeRecordKeys = <String>{
  'allowedReasons',
  'evidenceIdentity',
  'fixtureId',
  'observedReason',
  'rejected',
  'status',
};
const _evidenceKeys = <String>{
  'acceptedInternalVerdict',
  'baselineGeneratorMicros',
  'bytesCopied',
  'candidateGeneratorMicros',
  'corpusPolicyIdentity',
  'corpusPolicyPassed',
  'originalProjectDrift',
  'policyMicros',
  'restorationIdentity',
  'restorationProven',
  'sampledPeakRssBytes',
  'selectionIdentity',
  'stageMicros',
  'unexpectedWriteCount',
  'verdictFailures',
  'verdictIdentity',
};

Map<String, Object?> _scopeFor(
  L10nReadinessPlan plan,
  L10nMutationReadinessOptions options,
) {
  if (options.caseSelection != null) {
    return {
      'completeRun': false,
      'kind': 'case',
      'profile': plan.profile.name,
      'selection': options.caseSelection,
    };
  }
  if (options.familySelection != null) {
    return {
      'completeRun': false,
      'kind': 'family',
      'profile': plan.profile.name,
      'selection': options.familySelection,
    };
  }
  return {
    // Task 15A has no performance denominator. A contract artifact can pass
    // its selected mutation gates, but cannot claim the complete Stage 1 run.
    'completeRun': false,
    'kind': 'full',
    'profile': plan.profile.name,
    'selection': null,
  };
}

Map<String, Map<String, Object?>> _parseRecords(
  Object? value, {
  required String identityKey,
  required Set<String> exactKeys,
  required Set<String> allowedIds,
  required void Function(Map<String, Object?> record) validator,
}) {
  final list = _objectList(value, identityKey);
  final result = <String, Map<String, Object?>>{};
  String? previous;
  for (final item in list) {
    final record = _stringMap(item);
    _requireExactKeys(record, exactKeys, identityKey);
    final id = record[identityKey];
    if (id is! String ||
        !allowedIds.contains(id) ||
        result.containsKey(id) ||
        (previous != null && previous.compareTo(id) >= 0)) {
      throw const FormatException('resume record identity is invalid');
    }
    validator(record);
    result[id] = Map.unmodifiable(record);
    previous = id;
  }
  return result;
}

void _validateProjectRecord(
  Map<String, Object?> record,
  L10nReadinessPlan plan,
) {
  _requireTerminalStatus(record['status']);
  final status = record['status'];
  final identity = record['scanAuthorityIdentity'];
  if (identity is! String || !_safeRecordIdentity(identity)) {
    throw const FormatException('project scan identity is malformed');
  }
  for (final key in const [
    'publicApplyEligibleL10n',
    'publicHighL10n',
    'publicProposedL10nActions',
    'publicSafeL10n',
    'staticNegativeNonCandidates',
    'staticOracleMismatchCount',
    'staticPositiveCandidates',
  ]) {
    _nonNegativeInt(record[key], key);
  }
  final passedShape =
      record['staticOracleMismatchCount'] == 0 &&
      record['publicApplyEligibleL10n'] == 0 &&
      record['publicHighL10n'] == 0 &&
      record['publicProposedL10nActions'] == 0 &&
      record['publicSafeL10n'] == 0 &&
      record['staticPositiveCandidates'] ==
          plan.oracleCases
              .where(
                (entry) =>
                    entry.projectId == record['projectId'] &&
                    entry.mutationPositive,
              )
              .length &&
      record['staticNegativeNonCandidates'] ==
          plan.oracleCases
              .where(
                (entry) =>
                    entry.projectId == record['projectId'] &&
                    !entry.mutationPositive,
              )
              .length;
  if ((status == 'passed') != passedShape) {
    throw const FormatException('project record status is inconsistent');
  }
  if (status == 'failed' &&
      record['staticOracleMismatchCount'] == 0 &&
      record['publicApplyEligibleL10n'] == 0 &&
      record['publicHighL10n'] == 0 &&
      record['publicProposedL10nActions'] == 0 &&
      record['publicSafeL10n'] == 0) {
    throw const FormatException('failed project record has no failed gate');
  }
}

void _validateCaseRecord(
  Map<String, Object?> record,
  Map<String, L10nReadinessOracleCase> oracleById,
) {
  _requireTerminalStatus(record['status']);
  _nonNegativeInt(record['attemptMicros'], 'attemptMicros');
  final id = record['caseId']! as String;
  final oracle = oracleById[id];
  if (oracle == null ||
      record['projectId'] != oracle.projectId ||
      record['decodedKey'] != oracle.decodedKey ||
      record['expectedScannerPresence'] != oracle.expectedScannerPresence) {
    throw const FormatException('case record oracle drift');
  }
  final evidence = _validatedEvidence(record['evidence']);
  if (evidence != null && evidence['selectionIdentity'] != id) {
    throw const FormatException('case evidence selection drift');
  }
  final passed = evidence != null && _evidencePasses(evidence);
  final expectedFailureReasons = evidence == null
      ? const {'staticOracleMismatch', 'projectEligibilityRejected'}
      : evidence['acceptedInternalVerdict'] == false
      ? const {'internalVerdictRejected'}
      : const {'corpusEvidenceRejected'};
  if ((record['status'] == 'passed') != passed ||
      (passed && record['failureReason'] != null) ||
      (!passed && !expectedFailureReasons.contains(record['failureReason']))) {
    throw const FormatException('case record status is inconsistent');
  }
  final actualNodeId = record['actualNodeId'];
  if ((evidence != null) != (actualNodeId != null)) {
    throw const FormatException('case evidence lacks its actual node identity');
  }
  if (actualNodeId != null &&
      (actualNodeId is! String || !_safeRecordIdentity(actualNodeId))) {
    throw const FormatException('case node identity is malformed');
  }
}

void _validateFamilyRecord(
  Map<String, Object?> record,
  L10nReadinessPlan plan,
) {
  _requireTerminalStatus(record['status']);
  _nonNegativeInt(record['attemptMicros'], 'attemptMicros');
  final projectId = record['projectId']! as String;
  final expected =
      plan.oracleCases
          .where(
            (entry) => entry.projectId == projectId && entry.mutationPositive,
          )
          .map((entry) => entry.caseId)
          .toList()
        ..sort();
  final caseIds = _stringList(record['caseIds'], 'caseIds');
  if (!_jsonEquals(caseIds, expected)) {
    throw const FormatException('family selection drift');
  }
  final evidence = _validatedEvidence(record['evidence']);
  if (evidence != null &&
      evidence['selectionIdentity'] != 'family:$projectId') {
    throw const FormatException('family evidence selection drift');
  }
  final passed = evidence != null && _evidencePasses(evidence);
  final expectedFailureReason = evidence == null
      ? 'staticOracleMismatch'
      : evidence['acceptedInternalVerdict'] == false
      ? 'internalVerdictRejected'
      : 'corpusEvidenceRejected';
  if ((record['status'] == 'passed') != passed ||
      (passed && record['failureReason'] != null) ||
      (!passed && record['failureReason'] != expectedFailureReason)) {
    throw const FormatException('family record status is inconsistent');
  }
}

void _validateNegativeRecord(
  Map<String, Object?> record,
  L10nReadinessPlan plan,
) {
  _requireTerminalStatus(record['status']);
  final fixtureId = record['fixtureId']! as String;
  final expected = [...plan.mutationNegativeFixtures[fixtureId]!]..sort();
  final allowed = _stringList(record['allowedReasons'], 'allowedReasons');
  if (!_jsonEquals(allowed, expected)) {
    throw const FormatException('negative fixture allowlist drift');
  }
  final observed = record['observedReason'];
  final evidenceIdentity = record['evidenceIdentity'];
  if (observed is! String ||
      !_safeIdentity(observed) ||
      evidenceIdentity is! String ||
      !_safeRecordIdentity(evidenceIdentity) ||
      evidenceIdentity == 'notRun') {
    throw const FormatException('negative fixture evidence is malformed');
  }
  final passed = record['rejected'] == true && expected.contains(observed);
  if ((record['status'] == 'passed') != passed) {
    throw const FormatException('negative fixture status is inconsistent');
  }
  if (record['rejected'] is! bool) {
    throw const FormatException('negative fixture rejection is malformed');
  }
}

Map<String, Object?>? _validatedEvidence(Object? value) {
  if (value == null) return null;
  final evidence = _stringMap(value);
  _requireExactKeys(evidence, _evidenceKeys, 'evidence');
  for (final key in const [
    'bytesCopied',
    'stageMicros',
    'baselineGeneratorMicros',
    'candidateGeneratorMicros',
    'policyMicros',
    'sampledPeakRssBytes',
    'unexpectedWriteCount',
  ]) {
    _nonNegativeInt(evidence[key], key);
  }
  for (final key in const [
    'acceptedInternalVerdict',
    'corpusPolicyPassed',
    'originalProjectDrift',
    'restorationProven',
  ]) {
    if (evidence[key] is! bool) {
      throw const FormatException('evidence boolean is malformed');
    }
  }
  for (final key in const [
    'corpusPolicyIdentity',
    'restorationIdentity',
    'selectionIdentity',
    'verdictIdentity',
  ]) {
    final identity = evidence[key];
    if (identity is! String || !_safeRecordIdentity(identity)) {
      throw const FormatException('evidence identity is malformed');
    }
  }
  final verdictFailures = _objectList(
    evidence['verdictFailures'],
    'verdictFailures',
  );
  for (final value in verdictFailures) {
    final failure = _stringMap(value);
    final keys = failure.keys.toSet();
    if (!_jsonEquals(
      keys.toList()..sort(),
      <String>[
        'code',
        'detailCode',
        if (failure.containsKey('relativePath')) 'relativePath',
        'stage',
      ]..sort(),
    )) {
      throw const FormatException('verdict failure shape is malformed');
    }
    for (final key in const ['code', 'detailCode', 'stage']) {
      final token = failure[key];
      if (token is! String || !_safeIdentity(token)) {
        throw const FormatException('verdict failure token is malformed');
      }
    }
    final relativePath = failure['relativePath'];
    if (relativePath != null &&
        (relativePath is! String || !_safeRelativePath(relativePath))) {
      throw const FormatException('verdict failure path is malformed');
    }
  }
  final accepted = evidence['acceptedInternalVerdict']! as bool;
  final rejectedShape =
      evidence['corpusPolicyPassed'] == false &&
      evidence['restorationProven'] == false &&
      evidence['unexpectedWriteCount'] == 0 &&
      evidence['originalProjectDrift'] == false &&
      evidence['policyMicros'] == 0 &&
      evidence['corpusPolicyIdentity'] == 'notRun' &&
      evidence['restorationIdentity'] == 'notRun';
  if (accepted != verdictFailures.isEmpty ||
      !accepted && !rejectedShape ||
      accepted &&
          (evidence['corpusPolicyIdentity'] == 'notRun' ||
              evidence['restorationIdentity'] == 'notRun') ||
      evidence['verdictIdentity'] == 'notRun') {
    throw const FormatException('evidence sequencing is inconsistent');
  }
  return evidence;
}

bool _evidencePasses(Map<String, Object?> evidence) =>
    evidence['acceptedInternalVerdict'] == true &&
    evidence['corpusPolicyPassed'] == true &&
    evidence['restorationProven'] == true &&
    evidence['unexpectedWriteCount'] == 0 &&
    evidence['originalProjectDrift'] == false;

bool _summaryPasses(Map<String, Object?> summary) =>
    summary['acceptedIndividualKeys'] == summary['requiredIndividualKeys'] &&
    summary['acceptedFamilyBatches'] == summary['requiredFamilyBatches'] &&
    summary['staticPositiveCandidates'] ==
        summary['requiredStaticPositiveCandidates'] &&
    summary['staticNegativeNonCandidates'] ==
        summary['requiredStaticNegativeNonCandidates'] &&
    summary['mutationNegativeFixturesPassed'] ==
        summary['requiredMutationNegativeFixtures'] &&
    summary['provenRestorations'] == summary['requiredRestorations'] &&
    summary['passedStaticProjects'] == summary['requiredStaticProjects'] &&
    summary['fullPolicyFailures'] == 0 &&
    summary['unexpectedWritesForAccepted'] == 0 &&
    summary['originalProjectDriftCount'] == 0 &&
    summary['publicSafeL10n'] == 0 &&
    summary['publicHighL10n'] == 0 &&
    summary['publicApplyEligibleL10n'] == 0 &&
    summary['publicProposedL10nActions'] == 0 &&
    summary['staticOracleMismatchCount'] == 0 &&
    summary['passedPerformanceProjects'] ==
        summary['requiredPerformanceProjects'];

Set<String> _requiredProjectIds(L10nReadinessPlan plan) => {
  for (final caseId in plan.individualCaseIds)
    plan.oracleCases.singleWhere((entry) => entry.caseId == caseId).projectId,
  ...plan.familyProjectIds,
};

List<Map<String, Object?>> _sortedRecords(
  Map<String, Map<String, Object?>> records,
  String identityKey,
) {
  final values = records.values.map(Map<String, Object?>.from).toList();
  values.sort(
    (left, right) =>
        (left[identityKey]! as String).compareTo(right[identityKey]! as String),
  );
  return values;
}

int _sum(Iterable<Map<String, Object?>> records, String key) =>
    records.fold(0, (sum, record) => sum + (record[key]! as int));

List<Object?> _objectList(Object? value, String field) {
  if (value is! List) throw FormatException('$field must be an array');
  return List<Object?>.from(value);
}

List<String> _stringList(Object? value, String field) {
  final list = _objectList(value, field);
  if (list.any((entry) => entry is! String)) {
    throw FormatException('$field must contain strings');
  }
  return list.cast<String>();
}

void _requireExactKeys(
  Map<String, Object?> value,
  Set<String> expected,
  String field,
) {
  if (value.keys.toSet().difference(expected).isNotEmpty ||
      expected.difference(value.keys.toSet()).isNotEmpty) {
    throw FormatException('$field keys are invalid');
  }
}

void _requireTerminalStatus(Object? value) {
  if (value != 'passed' && value != 'failed') {
    throw const FormatException('record status must be terminal');
  }
}

int _nonNegativeInt(Object? value, String field) {
  if (value is! int || value < 0) {
    throw FormatException('$field must be a non-negative integer');
  }
  return value;
}

bool _jsonEquals(Object? left, Object? right) =>
    jsonEncode(_canonicalize(left)) == jsonEncode(_canonicalize(right));

const _defaultMaxResumeBytes = 8 * 1024 * 1024;
const _checkpointReadChunkBytes = 64 * 1024;
final _activeCheckpointOutputs = <String>{};

/// Bounded canonical store with a cooperative local-filesystem run lease.
///
/// The stable advisory-lock file is deliberately retained between runs. This
/// prevents a second cooperative writer from locking a newly-created inode
/// while a previous process still holds the original lock.
///
/// Task 15 runs this private harness sequentially in one CLI isolate. The
/// lease therefore excludes cooperative processes and duplicate claims in that
/// isolate; it is not a general multi-isolate lock within one Dart process.
/// Reported promotion failures restore the prior checkpoint through
/// [RecoverableReportWriter]. Like that writer, this store does not promise
/// crash durability, parent-directory fsync, or protection from a
/// non-cooperating process that swaps path components.
final class FileL10nReadinessCheckpointStore
    implements L10nReadinessCheckpointStore {
  FileL10nReadinessCheckpointStore({
    this.maxResumeBytes = _defaultMaxResumeBytes,
    ReportObjectBackend? objectBackend,
    RecoverableReportWriter? reportWriter,
  }) : _objectBackend = objectBackend ?? createIoReportObjectBackend(),
       _reportWriter = reportWriter ?? const RecoverableReportWriter() {
    if (maxResumeBytes <= 0) {
      throw ArgumentError.value(
        maxResumeBytes,
        'maxResumeBytes',
        'Must be positive.',
      );
    }
  }

  final int maxResumeBytes;
  final ReportObjectBackend _objectBackend;
  final RecoverableReportWriter _reportWriter;

  @override
  Future<L10nReadinessCheckpointLease> claim(File outputFile) async {
    final output = _validatedCheckpointPath(outputFile, allowMissing: true);
    if (!_activeCheckpointOutputs.add(output.path)) {
      throw const FileSystemException('checkpoint output is already claimed');
    }
    final lockFile = File(
      p.join(
        output.parent.path,
        '.${p.basename(output.path)}.l10n-stage1.lease',
      ),
    );
    RandomAccessFile? handle;
    try {
      await _prepareStableLease(output, lockFile);
      handle = await lockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.exclusive);
      if (FileSystemEntity.typeSync(lockFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('checkpoint lease identity drifted');
      }
      return _FileL10nReadinessCheckpointLease(
        store: this,
        outputFile: output,
        lockHandle: handle,
      );
    } catch (_) {
      if (handle != null) {
        try {
          await handle.close();
        } catch (_) {
          // The acquisition error remains authoritative.
        }
      }
      _activeCheckpointOutputs.remove(output.path);
      rethrow;
    }
  }

  Future<void> _prepareStableLease(File output, File lockFile) async {
    final lockLeaf = p.basename(lockFile.path);
    final magic = utf8.encode(
      'flutter-pruner-l10n-stage1-lease-v1\n'
      'output=${p.basename(output.path)}\n',
    );
    AnchoredReportDirectory? directory;
    ExclusiveReportObject? created;
    ExistingReportObject? existing;
    ExistingReportObject? outputObject;
    await _runPreservingPrimary<void>(
      () async {
        directory = await _objectBackend.anchor(output.parent);
        try {
          created = await directory!.createExclusive(lockLeaf);
        } on ReportObjectBackendException catch (error) {
          if (error.category != ReportObjectBackendFailure.collision) rethrow;
        }

        late final ReportObjectIdentity lockIdentity;
        if (created != null) {
          await created!.write(magic);
          await created!.flush();
          lockIdentity = await created!.identity();
          await created!.rewind();
          final readBack = await _readExactCheckpointBytes(
            magic.length,
            created!.read,
          );
          if (lockIdentity.byteLength != magic.length ||
              (await created!.read(1)).isNotEmpty ||
              !_sameBytes(magic, readBack)) {
            throw const FileSystemException(
              'checkpoint lease initialization drifted',
            );
          }
          await created!.close();
          created = null;
        } else {
          existing = await directory!.openExisting(lockLeaf);
          final before = await existing!.identity();
          if (before.byteLength != magic.length) {
            throw const FileSystemException(
              'checkpoint lease binding is invalid',
            );
          }
          await existing!.rewind();
          final readBack = await _readExactCheckpointBytes(
            magic.length,
            existing!.read,
          );
          final after = await existing!.identity();
          if (before != after ||
              (await existing!.read(1)).isNotEmpty ||
              !_sameBytes(magic, readBack)) {
            throw const FileSystemException(
              'checkpoint lease binding is invalid',
            );
          }
          lockIdentity = after;
          await existing!.close();
          existing = null;
        }

        if (FileSystemEntity.typeSync(output.path, followLinks: false) ==
            FileSystemEntityType.file) {
          outputObject = await directory!.openExisting(p.basename(output.path));
          final outputIdentity = await outputObject!.identity();
          if (lockIdentity.sameObjectAs(outputIdentity)) {
            throw const FileSystemException(
              'checkpoint lease aliases the output',
            );
          }
          await outputObject!.close();
          outputObject = null;
        }
        await directory!.verifyReachable();
      },
      [
        () async {
          if (created != null) await created!.close();
        },
        () async {
          if (existing != null) await existing!.close();
        },
        () async {
          if (outputObject != null) await outputObject!.close();
        },
        () async {
          if (directory != null) await directory!.close();
        },
      ],
    );
  }

  Future<Object?> _read(File outputFile) async {
    final output = _validatedCheckpointPath(outputFile, allowMissing: false);
    AnchoredReportDirectory? directory;
    ExistingReportObject? object;
    return _runPreservingPrimary<Object?>(
      () async {
        directory = await _objectBackend.anchor(output.parent);
        object = await directory!.openExisting(p.basename(output.path));
        final before = await object!.identity();
        if (before.byteLength <= 0 || before.byteLength > maxResumeBytes) {
          throw const FormatException('resume artifact size is invalid');
        }
        await object!.rewind();
        final bytes = await _readExactCheckpointBytes(
          before.byteLength,
          object!.read,
        );
        final extra = await object!.read(1);
        final after = await object!.identity();
        if (extra.isNotEmpty || before != after) {
          throw const FormatException('resume artifact changed while reading');
        }
        await directory!.verifyReachable();
        return _decodeCanonicalCheckpoint(bytes, maxResumeBytes);
      },
      [
        () async {
          if (object != null) await object!.close();
        },
        () async {
          if (directory != null) await directory!.close();
        },
      ],
    );
  }

  Future<void> _write(File outputFile, String canonicalJson) async {
    final output = _validatedCheckpointPath(outputFile, allowMissing: true);
    final bytes = utf8.encode(canonicalJson);
    _decodeCanonicalCheckpoint(bytes, maxResumeBytes);
    final destination = await _reportWriter.resolve(output);
    if (!p.equals(destination.canonicalPath, output.path)) {
      throw const FileSystemException(
        'checkpoint destination identity drifted',
      );
    }
    await _reportWriter.write(
      destination,
      runId: 'l10n-stage1-${_secureCheckpointToken()}',
      writeTo: (sink) => sink.write(canonicalJson),
    );
    final persisted = await _read(output);
    if (canonicalL10nReadinessJson(_stringMap(persisted)) != canonicalJson) {
      throw const FileSystemException('checkpoint read-back drifted');
    }
  }

  Future<void> _release(File outputFile, RandomAccessFile lockHandle) async {
    Object? primaryError;
    StackTrace? primaryStackTrace;
    try {
      await lockHandle.unlock();
    } catch (error, stackTrace) {
      primaryError = error;
      primaryStackTrace = stackTrace;
    }
    try {
      await lockHandle.close();
    } catch (error, stackTrace) {
      primaryError ??= error;
      primaryStackTrace ??= stackTrace;
    }
    _activeCheckpointOutputs.remove(outputFile.path);
    if (primaryError != null) {
      Error.throwWithStackTrace(primaryError, primaryStackTrace!);
    }
  }
}

final class _FileL10nReadinessCheckpointLease
    implements L10nReadinessCheckpointLease {
  _FileL10nReadinessCheckpointLease({
    required FileL10nReadinessCheckpointStore store,
    required File outputFile,
    required RandomAccessFile lockHandle,
  }) : _store = store,
       _outputFile = outputFile,
       _lockHandle = lockHandle;

  final FileL10nReadinessCheckpointStore _store;
  final File _outputFile;
  final RandomAccessFile _lockHandle;
  var _released = false;

  void _ensureActive() {
    if (_released) throw StateError('checkpoint lease is already released');
  }

  @override
  Future<Object?> read() {
    _ensureActive();
    return _store._read(_outputFile);
  }

  @override
  Future<void> write(String canonicalJson) {
    _ensureActive();
    return _store._write(_outputFile, canonicalJson);
  }

  @override
  Future<void> release() async {
    if (_released) return;
    _released = true;
    await _store._release(_outputFile, _lockHandle);
  }
}

File _validatedCheckpointPath(File file, {required bool allowMissing}) {
  if (!p.isAbsolute(file.path) || p.normalize(file.path) != file.path) {
    throw const FileSystemException('checkpoint path is not canonical');
  }
  final parent = file.parent;
  if (!parent.existsSync() ||
      !p.equals(parent.resolveSymbolicLinksSync(), parent.path)) {
    throw const FileSystemException('checkpoint parent is not canonical');
  }
  final canonical = File(p.join(parent.path, p.basename(file.path)));
  if (!p.equals(canonical.path, file.path)) {
    throw const FileSystemException('checkpoint path is not a direct child');
  }
  final type = FileSystemEntity.typeSync(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound && allowMissing) return canonical;
  if (type != FileSystemEntityType.file ||
      !p.equals(file.resolveSymbolicLinksSync(), file.path)) {
    throw const FileSystemException(
      'checkpoint is not a canonical regular file',
    );
  }
  return canonical;
}

Object? _decodeCanonicalCheckpoint(List<int> bytes, int maximumBytes) {
  if (bytes.isEmpty || bytes.length > maximumBytes) {
    throw const FormatException('checkpoint size is invalid');
  }
  final source = utf8.decode(bytes, allowMalformed: false);
  _validateCheckpointNesting(source);
  final decoded = jsonDecode(source);
  final root = _stringMap(decoded);
  if (canonicalL10nReadinessJson(root) != source) {
    throw const FormatException('checkpoint JSON is not canonical');
  }
  return root;
}

void _validateCheckpointNesting(String source) {
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (final unit in source.codeUnits) {
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (unit == 0x5c) {
        escaped = true;
      } else if (unit == 0x22) {
        inString = false;
      }
      continue;
    }
    if (unit == 0x22) {
      inString = true;
    } else if (unit == 0x7b || unit == 0x5b) {
      depth++;
      if (depth > 64) {
        throw const FormatException('checkpoint JSON is too deeply nested');
      }
    } else if (unit == 0x7d || unit == 0x5d) {
      depth--;
      if (depth < 0) {
        throw const FormatException('checkpoint JSON nesting is malformed');
      }
    }
  }
  if (depth != 0 || inString || escaped) {
    throw const FormatException('checkpoint JSON nesting is malformed');
  }
}

Future<List<int>> _readExactCheckpointBytes(
  int byteLength,
  Future<List<int>> Function(int maximumBytes) read,
) async {
  final result = <int>[];
  while (result.length < byteLength) {
    final remaining = byteLength - result.length;
    final chunk = await read(min(remaining, _checkpointReadChunkBytes));
    if (chunk.isEmpty || chunk.length > remaining) {
      throw const FormatException('checkpoint read was incomplete');
    }
    result.addAll(chunk);
  }
  return result;
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _secureCheckpointToken() {
  final random = Random.secure();
  final values = List<int>.generate(4, (_) => random.nextInt(0x100000000));
  return values.map((value) => value.toRadixString(16).padLeft(8, '0')).join();
}

Future<T> _runPreservingPrimary<T>(
  Future<T> Function() body,
  List<Future<void> Function()> cleanup,
) async {
  T? result;
  var completed = false;
  Object? primaryError;
  StackTrace? primaryStackTrace;
  try {
    result = await body();
    completed = true;
  } catch (error, stackTrace) {
    primaryError = error;
    primaryStackTrace = stackTrace;
  }
  for (final action in cleanup) {
    try {
      await action();
    } catch (error, stackTrace) {
      primaryError ??= error;
      primaryStackTrace ??= stackTrace;
    }
  }
  if (primaryError != null) {
    Error.throwWithStackTrace(primaryError, primaryStackTrace!);
  }
  if (!completed) throw StateError('checkpoint operation did not complete');
  return result as T;
}

Future<void> main(List<String> arguments) async {
  exitCode = await runProductionL10nMutationReadiness(arguments);
}
