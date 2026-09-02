/// Strict, scanner-independent inputs for the l10n mutation corpus.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _supportedSchemaVersion = 1;
const _supportedOracleVersion = 'l10n-mutation-readiness-v2';
const _rootManifestSha256 =
    '30be93d927bb1153ad7482fe5c20904a21489419a558b449bb43d8e9e3e9fbb9';

// Partial manifest SHA (gitjournal + smooth only, no GSY)
const _partialManifestSha256 =
    '0dda708cc3d394260b32af8cd43f67117d885afa6ece3dea96f2a8a445c4c437';
const _normalizationManifestSha256ByName = <String, String>{
  'gsy-normalized-family-v2.json':
      '00c994f3fa48fc40ff1a1a35e8ea3fd0011ca3801da2e75acfa297009c761c59',
  'gitjournal-normalized-family-v1.json':
      '5df0eacb70a4a69769eeadc0626329c636ababcb6cb1a8d0bf3fb3504a7c568c',
  'smooth-normalized-family-v2.json':
      'd3a92834a95694fe22cb3c1c00934150fba63a93085381b86f138bf4b5aa53ca',
};

const _smoothFullPolicyCorrectionIds = <String>{
  'smooth:l10n:barcode_barcode',
  'smooth:l10n:category_picker_no_category_found_button',
  'smooth:l10n:category_picker_no_category_found_message',
  'smooth:l10n:dev_preferences_migration_subtitle',
  'smooth:l10n:email_body_account_deletion',
  'smooth:l10n:importance_label',
  'smooth:l10n:pct_match',
  'smooth:l10n:product_search_button_download_more',
  'smooth:l10n:product_search_no_more_results',
  'smooth:l10n:user_profile_title_id_default',
  'smooth:l10n:user_profile_title_id_email',
};

const _normalizationPathsByProject = <String, List<String>>{
  'gsy': [
    'lib/common/localization/l10n/app_en.arb',
    'lib/common/localization/l10n/app_ja.arb',
    'lib/common/localization/l10n/app_ko.arb',
    'lib/common/localization/l10n/app_zh.arb',
  ],
  'gitjournal': [
    'lib/l10n/app_de.arb',
    'lib/l10n/app_es.arb',
    'lib/l10n/app_fa.arb',
    'lib/l10n/app_fi.arb',
    'lib/l10n/app_fr.arb',
    'lib/l10n/app_hi.arb',
    'lib/l10n/app_hu.arb',
    'lib/l10n/app_id.arb',
    'lib/l10n/app_it.arb',
    'lib/l10n/app_ja.arb',
    'lib/l10n/app_ko.arb',
    'lib/l10n/app_pl.arb',
    'lib/l10n/app_pt.arb',
    'lib/l10n/app_pt_br.arb',
    'lib/l10n/app_ru.arb',
    'lib/l10n/app_sv.arb',
    'lib/l10n/app_ta.arb',
    'lib/l10n/app_vi.arb',
    'lib/l10n/app_zh.arb',
    'lib/l10n/app_zh_Hans.arb',
    'lib/l10n/app_zh_TW.arb',
  ],
};

const _frozenProjects = <String, _FrozenProject>{
  'gitjournal': _FrozenProject(
    repositoryRevision: 'c8a67e098db06335762f822d7733c330f4bd0d6b',
    packageRoot: '.',
    arbDirectory: 'lib/l10n',
    templateArbPath: 'lib/l10n/app_en.arb',
    toolchainVersion: '3.41.5',
    sourceOracleSha256:
        'e07dafbb2b3cdecba0e928a08f0025ed8cc8bc161e0979dec73bb460b13ffc77',
    positiveKeys: 38,
    negativeKeys: 381,
  ),
  'gsy': _FrozenProject(
    repositoryRevision: '2b6c49008afc44b90fee869dedf8e59a86482953',
    packageRoot: '.',
    arbDirectory: 'lib/common/localization/l10n',
    templateArbPath: 'lib/common/localization/l10n/app_en.arb',
    toolchainVersion: '3.44.1',
    sourceOracleSha256:
        '9e113537db5e2a7b057bffc0d1ff74ce6799c2b31b36b89ff36bcf3afda65d35',
    positiveKeys: 17,
    negativeKeys: 386,
  ),
  'smooth': _FrozenProject(
    repositoryRevision: 'bac71afd115f72e379c0b501b95e5ede20ecd636',
    packageRoot: 'packages/smooth_app',
    arbDirectory: 'packages/smooth_app/lib/l10n',
    templateArbPath: 'packages/smooth_app/lib/l10n/app_en.arb',
    toolchainVersion: '3.44.9',
    sourceOracleSha256:
        '3ba9fb5be7bb70dcb68856cf4339c3e80626d30844fbc93dd7c81ecf5cc99020',
    positiveKeys: 312,
    negativeKeys: 1468,
  ),
};

const _frozenNegativeReasons = <String, List<String>>{
  'scan-blocker': ['scanBlockerPresent'],
  'pseudo-key-selection': ['invalidSelection'],
  'unknown-config-option': ['unsupportedConfiguration'],
  'path-escape': ['invalidInputPath'],
  'locale-only-key': ['arbFamilyIncomplete'],
  'malformed-arb': ['arbParseFailure'],
  'stale-live-output': ['staleGeneratedOutput'],
  'candidate-output-created': ['outputFamilyAmbiguous'],
  'candidate-output-deleted': ['outputFamilyAmbiguous'],
  'unexpected-stage-write': ['unexpectedStageWrite'],
  'source-drift': ['sourceDrift'],
  'package-resolution-drift': ['packageResolutionDrift'],
  'toolchain-drift': ['toolchainDrift'],
  'cleanup-failure': ['cleanupFailed'],
};

const _topLevelKeys = <String>{
  'schemaVersion',
  'oracleVersion',
  'sourceOracles',
  'oracleCorrections',
  'totals',
  'families',
  'cases',
  'mutationNegativeFixtures',
  'publicSurfaceBaseline',
};

/// Independent truth for one corpus case.
enum L10nMutationTruth {
  /// The key is independently confirmed unused and is mutation-authoritative.
  mutationPositive,

  /// The key is independently confirmed used and carries no mutation authority.
  mutationNegative,
}

/// Frozen aggregate denominators for the l10n corpus.
final class L10nMutationTotals {
  const L10nMutationTotals({
    required this.positiveKeys,
    required this.negativeKeys,
    required this.families,
    required this.individualMutationAttempts,
    required this.familyMutationAttempts,
    required this.requiredRestorations,
  });

  final int positiveKeys;
  final int negativeKeys;
  final int families;
  final int individualMutationAttempts;
  final int familyMutationAttempts;
  final int requiredRestorations;
}

/// Identity of one independently captured source oracle.
final class L10nMutationSourceOracle {
  const L10nMutationSourceOracle({
    required this.relativePath,
    required this.sha256,
  });

  final String relativePath;
  final String sha256;
}

/// One non-secret file overlaid while provisioning a disposable corpus.
final class L10nFixtureOverlay {
  L10nFixtureOverlay({
    required this.relativePath,
    required this.sourceIdentity,
    required this.purpose,
    required this.sha256,
    required this.containsSecrets,
  }) {
    _requireRelativePath(relativePath, 'fixture overlay relativePath');
    _requireRelativePath(sourceIdentity, 'fixture overlay sourceIdentity');
    _requireNonEmpty(purpose, 'fixture overlay purpose');
    _requireSha256(sha256, 'fixture overlay sha256');
    if (containsSecrets) {
      throw const FormatException('fixture overlays must be non-secret');
    }
  }

  final String relativePath;
  final String sourceIdentity;
  final String purpose;
  final String sha256;
  final bool containsSecrets;
}

/// A half-open byte span removed by a normalization overlay.
final class L10nRemovedByteSpan {
  const L10nRemovedByteSpan({required this.start, required this.endExclusive});

  final int start;
  final int endExclusive;
}

/// One byte range copied from the immutable original over a target range.
final class L10nCopiedByteSpan {
  const L10nCopiedByteSpan({
    required this.start,
    required this.endExclusive,
    required this.sourceStart,
    required this.sourceEndExclusive,
  });

  final int start;
  final int endExclusive;
  final int sourceStart;
  final int sourceEndExclusive;
}

/// One ARB transformation in a validated normalization manifest.
final class L10nNormalizedArb {
  L10nNormalizedArb({
    required this.relativePath,
    required this.originalSha256,
    required this.replacementSha256,
    required this.canonicalDecodedObjectSha256,
    List<L10nCopiedByteSpan> copiedByteSpans = const [],
    required List<L10nRemovedByteSpan> removedByteSpans,
    required this.decodedObjectEquivalent,
    required this.replacementHasDuplicateDecodedKeys,
  }) : copiedByteSpans = List.unmodifiable(
         List<L10nCopiedByteSpan>.from(copiedByteSpans),
       ),
       removedByteSpans = List.unmodifiable(
         List<L10nRemovedByteSpan>.from(removedByteSpans),
       );

  final String relativePath;
  final String originalSha256;
  final String replacementSha256;
  final String canonicalDecodedObjectSha256;
  final List<L10nCopiedByteSpan> copiedByteSpans;
  final List<L10nRemovedByteSpan> removedByteSpans;
  final bool decodedObjectEquivalent;
  final bool replacementHasDuplicateDecodedKeys;
}

/// One generated output whose exact baseline changes after ARB normalization.
final class L10nNormalizedGeneratedOutput {
  L10nNormalizedGeneratedOutput({
    required this.relativePath,
    required this.originalSha256,
    required this.replacementSha256,
    required this.posixMode,
  }) {
    _requireRelativePath(relativePath, 'normalized generated output path');
    _requireSha256(originalSha256, 'normalized generated original SHA-256');
    _requireSha256(
      replacementSha256,
      'normalized generated replacement SHA-256',
    );
    if (originalSha256 == replacementSha256) {
      throw const FormatException(
        'normalized generated output must change declared bytes',
      );
    }
    if (posixMode < 0 || posixMode > 0xfff) {
      throw const FormatException('normalized generated POSIX mode is invalid');
    }
  }

  final String relativePath;
  final String originalSha256;
  final String replacementSha256;
  final int posixMode;
}

/// Exact generated-output baseline derived after declared ARB normalization.
final class L10nNormalizedGeneratedBaseline {
  L10nNormalizedGeneratedBaseline({
    required List<L10nNormalizedGeneratedOutput> changedOutputs,
  }) : changedOutputs = List.unmodifiable(
         List<L10nNormalizedGeneratedOutput>.from(changedOutputs),
       ) {
    if (this.changedOutputs.isEmpty) {
      throw const FormatException(
        'normalized generated baseline must name changed outputs',
      );
    }
    final paths = this.changedOutputs
        .map((output) => output.relativePath)
        .toList(growable: false);
    _requireSortedUnique(paths, 'normalized generated output path');
  }

  final List<L10nNormalizedGeneratedOutput> changedOutputs;
}

/// Strict content loaded from a linked normalization manifest.
final class L10nNormalizationManifest {
  L10nNormalizationManifest({
    required this.schemaVersion,
    required this.normalizationVersion,
    required this.repositoryRevision,
    required this.policy,
    required this.sourceSha256,
    required List<L10nNormalizedArb> changedArbs,
    this.generatedBaseline,
  }) : changedArbs = List.unmodifiable(
         List<L10nNormalizedArb>.from(changedArbs),
       ) {
    if ((schemaVersion == 3) != (generatedBaseline != null)) {
      throw const FormatException(
        'normalization schema and generated baseline authority disagree',
      );
    }
  }

  final int schemaVersion;
  final String normalizationVersion;
  final String repositoryRevision;
  final String policy;
  final String sourceSha256;
  final List<L10nNormalizedArb> changedArbs;
  final L10nNormalizedGeneratedBaseline? generatedBaseline;
}

/// Link and application policy for one family normalization.
final class L10nNormalizationOverlay {
  L10nNormalizationOverlay({
    required this.manifest,
    required this.policy,
    this.normalizationManifest,
  }) {
    _requireRelativePath(manifest, 'normalization overlay manifest');
    if (p.posix.basename(manifest) != manifest || !manifest.endsWith('.json')) {
      throw const FormatException(
        'normalization overlay manifest must be a relative JSON file name',
      );
    }
    if (policy != 'apply-declared-byte-transforms') {
      throw const FormatException('unknown normalization overlay policy');
    }
  }

  /// Relative linked manifest file name, as declared in the root manifest.
  final String manifest;

  /// Exact application policy.
  final String policy;

  /// Validated linked content when loaded through [L10nMutationManifest.read].
  final L10nNormalizationManifest? normalizationManifest;
}

/// One canonical non-shell Flutter verification command.
final class CorpusVerificationCommand {
  CorpusVerificationCommand({
    required this.workingDirectoryRelativeToRepository,
    required List<String> argumentsAfterCanonicalFlutter,
  }) : argumentsAfterCanonicalFlutter = List.unmodifiable(
         List<String>.from(argumentsAfterCanonicalFlutter),
       ),
       identity = _commandIdentity(
         workingDirectoryRelativeToRepository,
         argumentsAfterCanonicalFlutter,
       ) {
    _validateVerificationCommand(
      workingDirectoryRelativeToRepository,
      this.argumentsAfterCanonicalFlutter,
    );
  }

  final String workingDirectoryRelativeToRepository;
  final List<String> argumentsAfterCanonicalFlutter;
  final String identity;
}

/// Immutable mutation and verification authority for one retained project.
final class L10nMutationProjectManifest {
  /// Creates a validated project value for corpus fakes and factories.
  L10nMutationProjectManifest({
    required this.id,
    required this.repositoryRevision,
    required this.packageRootRelative,
    required this.toolchainVersion,
    required List<CorpusVerificationCommand> verificationPolicy,
    this.arbDirectoryRelative,
    this.templateArbPathRelative,
    List<String> arbPathsRelative = const [],
    List<L10nFixtureOverlay> fixtureOverlays = const [],
    List<L10nNormalizationOverlay> normalizationOverlays = const [],
    Map<String, Object?> toolchainSelectionEvidence = const {},
  }) : verificationPolicy = List.unmodifiable(
         List<CorpusVerificationCommand>.from(verificationPolicy),
       ),
       arbPathsRelative = List.unmodifiable(
         List<String>.from(arbPathsRelative),
       ),
       fixtureOverlays = List.unmodifiable(
         List<L10nFixtureOverlay>.from(fixtureOverlays),
       ),
       normalizationOverlays = List.unmodifiable(
         List<L10nNormalizationOverlay>.from(normalizationOverlays),
       ),
       toolchainSelectionEvidence = _deepFreezeMap(toolchainSelectionEvidence) {
    if (!RegExp(r'^[a-z0-9][a-z0-9_-]*$').hasMatch(id)) {
      throw const FormatException('project id is not canonical');
    }
    _requireGitSha(repositoryRevision, 'project repositoryRevision');
    _requireRelativePath(packageRootRelative, 'project packageRootRelative');
    _requireNonEmpty(toolchainVersion, 'project toolchainVersion');
    if (verificationPolicy.isEmpty) {
      throw const FormatException('verification policy must not be empty');
    }
    _requireUnique(
      verificationPolicy.map((command) => command.identity),
      'verification command identity',
    );
    if (arbDirectoryRelative != null) {
      _requireRelativePath(
        arbDirectoryRelative!,
        'project arbDirectoryRelative',
      );
    }
    if (templateArbPathRelative != null) {
      _requireRelativePath(
        templateArbPathRelative!,
        'project templateArbPathRelative',
      );
    }
    for (final path in this.arbPathsRelative) {
      _requireRelativePath(path, 'project arb path');
    }
  }

  final String id;
  final String repositoryRevision;
  final String packageRootRelative;
  final String toolchainVersion;
  final List<CorpusVerificationCommand> verificationPolicy;
  final String? arbDirectoryRelative;
  final String? templateArbPathRelative;
  final List<String> arbPathsRelative;
  final List<L10nFixtureOverlay> fixtureOverlays;
  final List<L10nNormalizationOverlay> normalizationOverlays;
  final Map<String, Object?> toolchainSelectionEvidence;
}

/// One immutable scanner-independent truth row.
final class L10nMutationCase {
  L10nMutationCase({
    required this.canonicalNodeId,
    required this.projectId,
    required this.decodedKey,
    required this.truth,
    required this.expectedScannerPresence,
    required Map<String, List<String>> expectedArbMembersByPath,
  }) : expectedArbMembersByPath = Map.unmodifiable(
         expectedArbMembersByPath.map(
           (path, members) => MapEntry(
             path,
             List<String>.unmodifiable(List<String>.from(members)),
           ),
         ),
       );

  final String canonicalNodeId;
  final String projectId;
  final String decodedKey;
  final L10nMutationTruth truth;
  final bool expectedScannerPresence;

  /// Exact mutation authority. Empty for every mutation-negative row.
  final Map<String, List<String>> expectedArbMembersByPath;

  bool get isMutationPositive => truth == L10nMutationTruth.mutationPositive;
}

/// Strictly parsed frozen l10n mutation-readiness oracle.
final class L10nMutationManifest {
  factory L10nMutationManifest.fromJson(Map<String, Object?> json) {
    return _L10nMutationManifestParser(json).parse();
  }

  /// Reads a UTF-8 root manifest and validates linked normalization content.
  factory L10nMutationManifest.read(File file) {
    final bytes = file.readAsBytesSync();
    final actualSha = sha256.convert(bytes).toString();
    final isPartial = actualSha == _partialManifestSha256;
    if (actualSha != _rootManifestSha256 && !isPartial) {
      throw FormatException(
        'mutation root manifest SHA-256 drift: expected $_rootManifestSha256 '
        'or $_partialManifestSha256, got $actualSha'
      );
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    final json = _asStringMap(decoded, 'manifest');
    return _L10nMutationManifestParser(
      json,
      normalizationLoader: (name, project) =>
          _readNormalizationManifest(file.parent, name, project),
      isPartialManifest: isPartial,
    ).parse();
  }

  L10nMutationManifest._({
    required this.schemaVersion,
    required this.oracleVersion,
    required Map<String, L10nMutationSourceOracle> sourceOracles,
    required this.totals,
    required List<L10nMutationProjectManifest> projects,
    required List<L10nMutationCase> cases,
    required Map<String, List<String>> mutationNegativeReasons,
    required Map<String, Object?> publicSurfaceBaseline,
  }) : sourceOracles = Map.unmodifiable(
         Map<String, L10nMutationSourceOracle>.from(sourceOracles),
       ),
       projects = List.unmodifiable(
         List<L10nMutationProjectManifest>.from(projects),
       ),
       projectsById = Map.unmodifiable({
         for (final project in projects) project.id: project,
       }),
       cases = List.unmodifiable(List<L10nMutationCase>.from(cases)),
       mutationNegativeReasons = Map.unmodifiable(
         mutationNegativeReasons.map(
           (reason, codes) => MapEntry(
             reason,
             List<String>.unmodifiable(List<String>.from(codes)),
           ),
         ),
       ),
       publicSurfaceBaseline = _deepFreezeMap(publicSurfaceBaseline);

  final int schemaVersion;
  final String oracleVersion;
  final Map<String, L10nMutationSourceOracle> sourceOracles;
  final L10nMutationTotals totals;
  final List<L10nMutationProjectManifest> projects;
  final Map<String, L10nMutationProjectManifest> projectsById;
  final List<L10nMutationCase> cases;
  final Map<String, List<String>> mutationNegativeReasons;
  final Map<String, Object?> publicSurfaceBaseline;
}

typedef _NormalizationLoader =
    L10nNormalizationManifest Function(
      String name,
      L10nMutationProjectManifest project,
    );

final class _L10nMutationManifestParser {
  _L10nMutationManifestParser(
    this.json, {
    this.normalizationLoader,
    this.isPartialManifest = false,
  });

  final Map<String, Object?> json;
  final _NormalizationLoader? normalizationLoader;
  final bool isPartialManifest;

  L10nMutationManifest parse() {
    _requireExactKeys(json, _topLevelKeys, 'manifest');
    final reader = _ObjectReader(json, 'manifest');
    final schemaVersion = reader.integer('schemaVersion');
    if (schemaVersion != _supportedSchemaVersion) {
      throw const FormatException('unsupported mutation manifest schema');
    }
    final oracleVersion = reader.string('oracleVersion');
    if (oracleVersion != _supportedOracleVersion) {
      throw const FormatException('unsupported mutation oracle version');
    }

    final sourceOracles = _parseSourceOracles(reader.map('sourceOracles'));
    _parseOracleCorrections(reader.map('oracleCorrections'));
    final totals = _parseTotals(reader.map('totals'));
    final projects = _parseProjects(reader.list('families'));
    final projectsById = {for (final project in projects) project.id: project};
    final cases = _parseCases(reader.list('cases'), projectsById);
    final reasons = _parseNegativeReasons(
      reader.map('mutationNegativeFixtures'),
    );
    final publicSurface = _parsePublicSurface(
      reader.map('publicSurfaceBaseline'),
    );
    reader.finish();
    _validateDenominators(totals, projects, cases);
    _validateOracleCorrections(cases);

    return L10nMutationManifest._(
      schemaVersion: schemaVersion,
      oracleVersion: oracleVersion,
      sourceOracles: sourceOracles,
      totals: totals,
      projects: projects,
      cases: cases,
      mutationNegativeReasons: reasons,
      publicSurfaceBaseline: publicSurface,
    );
  }

  void _parseOracleCorrections(Map<String, Object?> json) {
    const keys = <String>{
      'policy',
      'reclassifiedCaseIds',
      'sourceTruthLabel',
      'correctedTruthLabel',
    };
    _requireExactKeys(json, keys, 'oracleCorrections');
    final reader = _ObjectReader(json, 'oracleCorrections');
    if (reader.string('policy') != 'full-production-verification-policy' ||
        reader.string('sourceTruthLabel') != 'mutation-positive' ||
        reader.string('correctedTruthLabel') != 'mutation-negative') {
      throw const FormatException('oracle correction authority drift');
    }
    final ids = _stringList(
      reader.list('reclassifiedCaseIds'),
      'oracleCorrections.reclassifiedCaseIds',
    );
    reader.finish();
    _requireSortedUnique(ids, 'oracle correction case ID');
    if (!_sameStrings(ids, _smoothFullPolicyCorrectionIds.toList()..sort())) {
      throw const FormatException('oracle correction membership drift');
    }
  }

  Map<String, L10nMutationSourceOracle> _parseSourceOracles(
    Map<String, Object?> json,
  ) {
    _requireExactKeys(json, _frozenProjects.keys.toSet(), 'sourceOracles');
    final result = <String, L10nMutationSourceOracle>{};
    for (final project in _frozenProjects.keys.toList()..sort()) {
      final reader = _ObjectReader(
        _asStringMap(json[project], 'sourceOracles.$project'),
        'sourceOracles.$project',
      );
      final relativePath = reader.string('relativePath');
      final hash = reader.string('sha256');
      reader.finish();
      if (relativePath != '$project-l10n-oracle.json') {
        throw const FormatException(
          'source oracle path differs from frozen input',
        );
      }
      _requireSha256(hash, 'source oracle sha256');
      if (hash != _frozenProjects[project]!.sourceOracleSha256) {
        throw const FormatException(
          'source oracle SHA-256 differs from frozen input',
        );
      }
      result[project] = L10nMutationSourceOracle(
        relativePath: relativePath,
        sha256: hash,
      );
    }
    return result;
  }

  L10nMutationTotals _parseTotals(Map<String, Object?> json) {
    const keys = <String>{
      'positiveKeys',
      'negativeKeys',
      'families',
      'individualMutationAttempts',
      'familyMutationAttempts',
      'requiredRestorations',
    };
    _requireExactKeys(json, keys, 'totals');
    final reader = _ObjectReader(json, 'totals');
    final totals = L10nMutationTotals(
      positiveKeys: reader.integer('positiveKeys'),
      negativeKeys: reader.integer('negativeKeys'),
      families: reader.integer('families'),
      individualMutationAttempts: reader.integer('individualMutationAttempts'),
      familyMutationAttempts: reader.integer('familyMutationAttempts'),
      requiredRestorations: reader.integer('requiredRestorations'),
    );
    reader.finish();
    // Skip strict denominator validation for partial manifests
    if (!isPartialManifest) {
      if (totals.positiveKeys != 367 ||
          totals.negativeKeys != 2235 ||
          totals.families != 3 ||
          totals.individualMutationAttempts != 367 ||
          totals.familyMutationAttempts != 3 ||
          totals.requiredRestorations != 370) {
        throw const FormatException('mutation corpus denominator drift');
      }
    }
    return totals;
  }

  List<L10nMutationProjectManifest> _parseProjects(List<Object?> values) {
    final projects = <L10nMutationProjectManifest>[];
    for (var index = 0; index < values.length; index++) {
      projects.add(
        _parseProject(_asStringMap(values[index], 'families[$index]'), index),
      );
    }
    final ids = projects.map((project) => project.id).toList();
    _requireSortedUnique(ids, 'project');
    if (!_sameStrings(ids, _frozenProjects.keys.toList()..sort())) {
      throw const FormatException('unknown or missing mutation project');
    }
    return projects;
  }

  L10nMutationProjectManifest _parseProject(
    Map<String, Object?> json,
    int index,
  ) {
    const keys = <String>{
      'project',
      'repositorySha',
      'packageRoot',
      'arbDirectory',
      'templateArbPath',
      'arbPaths',
      'expectedConfigurationStatus',
      'expectedFamilyBatchStatus',
      'toolchainSelectionEvidence',
      'verificationPolicy',
      'fixtureOverlays',
      'normalizationOverlays',
    };
    _requireExactKeys(json, keys, 'families[$index]');
    final reader = _ObjectReader(json, 'families[$index]');
    final id = reader.string('project');
    final frozen = _frozenProjects[id];
    if (frozen == null) {
      throw const FormatException('unknown mutation project');
    }
    final repositoryRevision = reader.string('repositorySha');
    final packageRoot = reader.string('packageRoot');
    final arbDirectory = reader.string('arbDirectory');
    final templateArbPath = reader.string('templateArbPath');
    if (repositoryRevision != frozen.repositoryRevision ||
        packageRoot != frozen.packageRoot ||
        arbDirectory != frozen.arbDirectory ||
        templateArbPath != frozen.templateArbPath) {
      throw FormatException('$id family identity differs from frozen input');
    }
    _requireGitSha(repositoryRevision, '$id repositorySha');
    _requireRelativePath(packageRoot, '$id packageRoot');
    _requireRelativePath(arbDirectory, '$id arbDirectory');
    _requireRelativePath(templateArbPath, '$id templateArbPath');

    final arbPaths = _stringList(reader.list('arbPaths'), '$id arbPaths');
    _requireSortedUnique(arbPaths, '$id ARB path');
    if (arbPaths.isEmpty || !arbPaths.contains(templateArbPath)) {
      throw FormatException('$id ARB paths omit the template');
    }
    for (final path in arbPaths) {
      _requireRelativePath(path, '$id ARB path');
      if (!path.startsWith('$arbDirectory/') || !path.endsWith('.arb')) {
        throw FormatException('$id ARB path is outside its family');
      }
    }
    if (reader.string('expectedConfigurationStatus') != 'supported' ||
        reader.string('expectedFamilyBatchStatus') != 'accepted') {
      throw FormatException('$id family status is not accepted');
    }

    final toolchain = _parseToolchain(
      id,
      reader.map('toolchainSelectionEvidence'),
    );
    final commands = _parsePolicy(
      id,
      frozen.toolchainVersion,
      reader.list('verificationPolicy'),
    );
    final fixtureOverlays = _parseFixtureOverlays(
      id,
      reader.list('fixtureOverlays'),
    );
    final normalizationOverlays = _parseNormalizationOverlays(
      id,
      reader.list('normalizationOverlays'),
      repositoryRevision,
      arbPaths,
    );
    reader.finish();

    return L10nMutationProjectManifest(
      id: id,
      repositoryRevision: repositoryRevision,
      packageRootRelative: packageRoot,
      toolchainVersion: frozen.toolchainVersion,
      verificationPolicy: commands,
      arbDirectoryRelative: arbDirectory,
      templateArbPathRelative: templateArbPath,
      arbPathsRelative: arbPaths,
      fixtureOverlays: fixtureOverlays,
      normalizationOverlays: normalizationOverlays,
      toolchainSelectionEvidence: toolchain,
    );
  }

  Map<String, Object?> _parseToolchain(
    String project,
    Map<String, Object?> json,
  ) {
    final expected = project == 'gitjournal'
        ? const <String, Object?>{
            'frameworkVersion': '3.41.5',
            'frameworkRevision': '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
            'engineRevision': '052f31d115eceda8cbff1b3481fcde4330c4ae12',
            'bundledDartVersion': '3.11.3',
            'ciResolutionEvidenceSha256':
                '4980a6207c2caa7a0f65cbc7b1390eb1fffe18f3dad3e7bb0b072cf033dd94d3',
            'probeArgv': ['flutter', '--version', '--machine'],
            'boundedProbeOutputSha256':
                'f1635a2a13f5ca240c48dc4fb8e0fab82758ce6aedeb66a3664af7d38844989c',
          }
        : <String, Object?>{
            'evidencePath': '.fvmrc',
            'evidenceSha256': project == 'gsy'
                ? '6829953e403e4e06af06fadc4e33258c78a09fe460a3625835116c31cf4e20a9'
                : 'b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94',
            'frameworkVersion': _frozenProjects[project]!.toolchainVersion,
            'selectionKind': 'pinned-fvm-config',
          };
    _requireExactKeys(json, expected.keys.toSet(), '$project toolchain');
    if (!_deepEquals(json, expected)) {
      throw FormatException(
        '$project toolchain evidence differs from frozen input',
      );
    }
    return _deepFreezeMap(json);
  }

  List<CorpusVerificationCommand> _parsePolicy(
    String project,
    String toolchainVersion,
    List<Object?> values,
  ) {
    final commands = <CorpusVerificationCommand>[];
    for (var index = 0; index < values.length; index++) {
      final path = '$project verificationPolicy[$index]';
      final json = _asStringMap(values[index], path);
      _requireExactKeys(json, const {
        'workingDirectory',
        'executable',
        'arguments',
      }, path);
      final reader = _ObjectReader(json, path);
      final workingDirectory = reader.string('workingDirectory');
      final executable = reader.map('executable');
      _requireExactKeys(executable, const {
        'kind',
        'version',
      }, '$path executable');
      final executableReader = _ObjectReader(executable, '$path executable');
      if (executableReader.string('kind') != 'flutterByVersion' ||
          executableReader.string('version') != toolchainVersion) {
        throw FormatException(
          '$project verification executable is not canonical',
        );
      }
      executableReader.finish();
      final arguments = _stringList(
        reader.list('arguments'),
        '$path arguments',
      );
      reader.finish();
      commands.add(
        CorpusVerificationCommand(
          workingDirectoryRelativeToRepository: workingDirectory,
          argumentsAfterCanonicalFlutter: arguments,
        ),
      );
    }
    _validateCanonicalPolicy(project, commands);
    return commands;
  }

  List<L10nFixtureOverlay> _parseFixtureOverlays(
    String project,
    List<Object?> values,
  ) {
    final overlays = <L10nFixtureOverlay>[];
    for (var index = 0; index < values.length; index++) {
      final path = '$project fixtureOverlays[$index]';
      final json = _asStringMap(values[index], path);
      _requireExactKeys(json, const {
        'relativePath',
        'sourceIdentity',
        'purpose',
        'sha256',
        'containsSecrets',
      }, path);
      final reader = _ObjectReader(json, path);
      overlays.add(
        L10nFixtureOverlay(
          relativePath: reader.string('relativePath'),
          sourceIdentity: reader.string('sourceIdentity'),
          purpose: reader.string('purpose'),
          sha256: reader.string('sha256'),
          containsSecrets: reader.boolean('containsSecrets'),
        ),
      );
      reader.finish();
    }
    _requireSortedUnique(
      overlays.map((overlay) => overlay.relativePath).toList(),
      '$project fixture overlay path',
    );
    _validateFrozenFixtureOverlays(
      project,
      overlays,
      allowPartialManifest: isPartialManifest,
    );
    return overlays;
  }

  List<L10nNormalizationOverlay> _parseNormalizationOverlays(
    String project,
    List<Object?> values,
    String repositoryRevision,
    List<String> arbPaths,
  ) {
    final overlays = <L10nNormalizationOverlay>[];
    for (var index = 0; index < values.length; index++) {
      final path = '$project normalizationOverlays[$index]';
      final json = _asStringMap(values[index], path);
      _requireExactKeys(json, const {'manifest', 'policy'}, path);
      final reader = _ObjectReader(json, path);
      final manifest = reader.string('manifest');
      final policy = reader.string('policy');
      reader.finish();
      final provisional = L10nMutationProjectManifest(
        id: project,
        repositoryRevision: repositoryRevision,
        packageRootRelative: _frozenProjects[project]!.packageRoot,
        toolchainVersion: _frozenProjects[project]!.toolchainVersion,
        verificationPolicy: [
          CorpusVerificationCommand(
            workingDirectoryRelativeToRepository: '.',
            argumentsAfterCanonicalFlutter: const ['analyze', '--no-pub'],
          ),
        ],
        arbDirectoryRelative: _frozenProjects[project]!.arbDirectory,
        templateArbPathRelative: _frozenProjects[project]!.templateArbPath,
        arbPathsRelative: arbPaths,
      );
      final loaded = normalizationLoader?.call(manifest, provisional);
      overlays.add(
        L10nNormalizationOverlay(
          manifest: manifest,
          policy: policy,
          normalizationManifest: loaded,
        ),
      );
    }
    _requireSortedUnique(
      overlays.map((overlay) => overlay.manifest).toList(),
      '$project normalization manifest',
    );
    final expectedManifest = switch (project) {
      'gsy' => 'gsy-normalized-family-v2.json',
      'gitjournal' => 'gitjournal-normalized-family-v1.json',
      'smooth' => 'smooth-normalized-family-v2.json',
      _ => null,
    };
    if (expectedManifest == null) {
      if (overlays.isNotEmpty) {
        throw FormatException(
          '$project must not declare normalization authority',
        );
      }
    } else if (overlays.length != 1 ||
        overlays.single.manifest != expectedManifest ||
        overlays.single.policy != 'apply-declared-byte-transforms') {
      throw FormatException(
        '$project normalization authority differs from frozen input',
      );
    }
    return overlays;
  }
}

List<L10nMutationCase> _parseCases(
  List<Object?> values,
  Map<String, L10nMutationProjectManifest> projectsById,
) {
  final cases = <L10nMutationCase>[];
  final ids = <String>{};
  final projectKeys = <String>{};
  for (var index = 0; index < values.length; index++) {
    final path = 'cases[$index]';
    final json = _asStringMap(values[index], path);
    final truthValue = json['truthLabel'];
    final truth = switch (truthValue) {
      'mutation-positive' => L10nMutationTruth.mutationPositive,
      'mutation-negative' => L10nMutationTruth.mutationNegative,
      _ => throw const FormatException('unknown mutation truth label'),
    };
    final expectedKeys = <String>{
      'canonicalNodeId',
      'project',
      'decodedKey',
      'truthLabel',
      'expectedScannerPresence',
      if (truth == L10nMutationTruth.mutationPositive)
        'expectedArbMembersByPath',
    };
    _requireExactKeys(json, expectedKeys, path);
    final reader = _ObjectReader(json, path);
    final canonicalNodeId = reader.string('canonicalNodeId');
    final projectId = reader.string('project');
    final project = projectsById[projectId];
    if (project == null) {
      throw const FormatException('case refers to an unknown project');
    }
    final decodedKey = reader.string('decodedKey');
    _requireNonEmpty(decodedKey, 'case decodedKey');
    if (_containsControl(decodedKey)) {
      throw const FormatException(
        'case decodedKey contains control characters',
      );
    }
    if (canonicalNodeId != '$projectId:l10n:$decodedKey') {
      throw const FormatException('case canonical node ID is inconsistent');
    }
    if (!ids.add(canonicalNodeId)) {
      throw const FormatException('duplicate case canonical node ID');
    }
    if (!projectKeys.add('$projectId\u0000$decodedKey')) {
      throw const FormatException('duplicate project and decoded key');
    }
    reader.string('truthLabel');
    final expectedScannerPresence = reader.boolean('expectedScannerPresence');
    final members = truth == L10nMutationTruth.mutationPositive
        ? _parseExpectedMembers(
            reader.map('expectedArbMembersByPath'),
            project,
            decodedKey,
            path,
          )
        : const <String, List<String>>{};
    reader.finish();
    cases.add(
      L10nMutationCase(
        canonicalNodeId: canonicalNodeId,
        projectId: projectId,
        decodedKey: decodedKey,
        truth: truth,
        expectedScannerPresence: expectedScannerPresence,
        expectedArbMembersByPath: members,
      ),
    );
  }
  _requireSortedUnique(
    cases.map((entry) => entry.canonicalNodeId).toList(),
    'case canonical node ID',
  );
  return cases;
}

Map<String, List<String>> _parseExpectedMembers(
  Map<String, Object?> json,
  L10nMutationProjectManifest project,
  String decodedKey,
  String casePath,
) {
  if (json.isEmpty) {
    throw const FormatException('mutation-positive case has no ARB authority');
  }
  final paths = json.keys.toList();
  _requireSortedUnique(paths, '$casePath ARB member path');
  if (!json.containsKey(project.templateArbPathRelative)) {
    throw const FormatException(
      'mutation-positive authority omits the template ARB',
    );
  }
  final allowedPaths = project.arbPathsRelative.toSet();
  final result = <String, List<String>>{};
  for (final path in paths) {
    if (!allowedPaths.contains(path)) {
      throw const FormatException(
        'mutation authority names an unknown ARB path',
      );
    }
    final members = _stringList(
      _asList(json[path], '$casePath expectedArbMembersByPath.$path'),
      '$casePath expectedArbMembersByPath.$path',
    );
    _requireSortedUnique(members, '$casePath ARB member');
    final expected = members.length == 1
        ? <String>[decodedKey]
        : <String>['@$decodedKey', decodedKey];
    if (!_sameStrings(members, expected)) {
      throw const FormatException(
        'mutation-positive ARB members are not exact',
      );
    }
    result[path] = members;
  }
  return result;
}

Map<String, List<String>> _parseNegativeReasons(Map<String, Object?> json) {
  _requireExactKeys(
    json,
    _frozenNegativeReasons.keys.toSet(),
    'mutationNegativeFixtures',
  );
  final result = <String, List<String>>{};
  for (final reason in _frozenNegativeReasons.keys) {
    final codes = _stringList(
      _asList(json[reason], 'mutationNegativeFixtures.$reason'),
      'mutationNegativeFixtures.$reason',
    );
    if (!_sameStrings(codes, _frozenNegativeReasons[reason]!)) {
      throw const FormatException('mutation-negative reason mapping drift');
    }
    result[reason] = codes;
  }
  return result;
}

Map<String, Object?> _parsePublicSurface(Map<String, Object?> json) {
  const keys = <String>{
    'captureBoundary',
    'cliOptionNames',
    'findings',
    'fixture',
    'htmlScanSha256',
    'jsonScanSha256',
    'reportSchemaKeys',
    'scanHelpSha256',
    'stagingRootNormalization',
    'terminalScanSha256',
    'timingFieldsRemoved',
    'topLevelHelpSha256',
  };
  _requireExactKeys(json, keys, 'publicSurfaceBaseline');
  final reader = _ObjectReader(json, 'publicSurfaceBaseline');
  if (reader.string('captureBoundary') != 'argv-only-child-process') {
    throw const FormatException('public-surface capture boundary drift');
  }
  final options = _stringList(reader.list('cliOptionNames'), 'cliOptionNames');
  _requireSortedUnique(options, 'public-surface CLI option');
  if (options.isEmpty) {
    throw const FormatException('public-surface CLI options are empty');
  }
  _parsePublicSurfaceFindings(reader.list('findings'));
  final fixture = reader.string('fixture');
  _requireRelativePath(fixture, 'public-surface fixture');
  if (fixture != 'test/fixtures/l10n_test') {
    throw const FormatException('public-surface fixture drift');
  }
  for (final field in const [
    'htmlScanSha256',
    'jsonScanSha256',
    'scanHelpSha256',
    'terminalScanSha256',
    'topLevelHelpSha256',
  ]) {
    _requireSha256(reader.string(field), 'publicSurfaceBaseline.$field');
  }
  final schemaKeys = _stringList(
    reader.list('reportSchemaKeys'),
    'reportSchemaKeys',
  );
  _requireSortedUnique(schemaKeys, 'public-surface report schema key');
  if (schemaKeys.isEmpty) {
    throw const FormatException('public-surface report schema is empty');
  }
  _parseStagingNormalization(reader.map('stagingRootNormalization'));
  final timingFields = _stringList(
    reader.list('timingFieldsRemoved'),
    'timingFieldsRemoved',
  );
  _requireSortedUnique(timingFields, 'public-surface timing field');
  reader.finish();
  return _deepFreezeMap(json);
}

void _parsePublicSurfaceFindings(List<Object?> values) {
  if (values.isEmpty) {
    throw const FormatException('public-surface findings are empty');
  }
  final ids = <String>[];
  for (var index = 0; index < values.length; index++) {
    final path = 'publicSurfaceBaseline.findings[$index]';
    final json = _asStringMap(values[index], path);
    _requireExactKeys(json, const {
      'id',
      'tier',
      'classificationReasons',
      'blockerIdentities',
    }, path);
    final reader = _ObjectReader(json, path);
    final id = reader.string('id');
    _requireNonEmpty(id, '$path id');
    ids.add(id);
    if (reader.string('tier') != 'REVIEW') {
      throw const FormatException('public-surface finding tier drift');
    }
    final reasons = _stringList(
      reader.list('classificationReasons'),
      '$path classificationReasons',
    );
    final blockers = _stringList(
      reader.list('blockerIdentities'),
      '$path blockerIdentities',
    );
    _requireUnique(reasons, '$path classification reason');
    _requireUnique(blockers, '$path blocker identity');
    reader.finish();
  }
  _requireSortedUnique(ids, 'public-surface finding ID');
}

void _parseStagingNormalization(Map<String, Object?> json) {
  const expected = <String, Object?>{
    'creation': 'Directory.systemTemp.createTempSync',
    'stablePlaceholder': '<PUBLIC_SURFACE_STAGING_ROOT>',
    'linkPolicy': 'reject-all-links',
    'cleanupIdentity': 'canonical-path-and-exclusive-marker',
  };
  _requireExactKeys(
    json,
    expected.keys.toSet(),
    'publicSurfaceBaseline.stagingRootNormalization',
  );
  if (!_deepEquals(json, expected)) {
    throw const FormatException('public-surface staging policy drift');
  }
}

void _validateDenominators(
  L10nMutationTotals totals,
  List<L10nMutationProjectManifest> projects,
  List<L10nMutationCase> cases,
) {
  final positive = cases
      .where((entry) => entry.truth == L10nMutationTruth.mutationPositive)
      .length;
  final negative = cases.length - positive;
  if (positive != totals.positiveKeys ||
      negative != totals.negativeKeys ||
      projects.length != totals.families ||
      totals.individualMutationAttempts != positive ||
      totals.familyMutationAttempts != projects.length ||
      totals.requiredRestorations != positive + projects.length) {
    throw const FormatException('mutation manifest count drift');
  }
  for (final project in projects) {
    final spec = _frozenProjects[project.id]!;
    final projectCases = cases.where((entry) => entry.projectId == project.id);
    final projectPositive = projectCases
        .where((entry) => entry.truth == L10nMutationTruth.mutationPositive)
        .length;
    final projectNegative = projectCases.length - projectPositive;
    if (projectPositive != spec.positiveKeys ||
        projectNegative != spec.negativeKeys) {
      throw FormatException('${project.id} mutation denominator drift');
    }
  }
}

void _validateOracleCorrections(List<L10nMutationCase> cases) {
  final byId = {for (final entry in cases) entry.canonicalNodeId: entry};
  for (final id in _smoothFullPolicyCorrectionIds) {
    final entry = byId[id];
    if (entry == null ||
        entry.truth != L10nMutationTruth.mutationNegative ||
        entry.expectedScannerPresence ||
        entry.expectedArbMembersByPath.isNotEmpty) {
      throw const FormatException('oracle correction case authority drift');
    }
  }
}

void _validateCanonicalPolicy(
  String project,
  List<CorpusVerificationCommand> commands,
) {
  final expected = switch (project) {
    'smooth' => const [
      (
        'packages/smooth_app',
        ['analyze', '--no-pub', '--fatal-infos', '--fatal-warnings'],
      ),
      ('packages/smooth_app', ['test', '--no-pub']),
    ],
    'gsy' => const [
      ('.', ['analyze', '--no-pub']),
      ('.', ['test', '--no-pub']),
    ],
    'gitjournal' => const [
      ('.', ['analyze', '--no-pub', '--no-fatal-infos']),
      ('.', ['test', '--no-pub']),
    ],
    _ => throw const FormatException('unknown mutation project policy'),
  };
  if (commands.length != expected.length) {
    throw FormatException('$project verification policy is not canonical');
  }
  for (var index = 0; index < commands.length; index++) {
    final command = commands[index];
    if (command.workingDirectoryRelativeToRepository != expected[index].$1 ||
        !_sameStrings(
          command.argumentsAfterCanonicalFlutter,
          expected[index].$2,
        )) {
      throw FormatException('$project verification policy is not canonical');
    }
  }
}

void _validateVerificationCommand(
  String workingDirectory,
  List<String> arguments,
) {
  _requireRelativePath(workingDirectory, 'verification working directory');
  if (arguments.isEmpty) {
    throw const FormatException('verification arguments must not be empty');
  }
  for (final argument in arguments) {
    if (argument.isEmpty || _containsControl(argument)) {
      throw const FormatException('verification argument is not canonical');
    }
    if (_isShellArgument(argument)) {
      throw const FormatException(
        'shell or wrapper verification argv is forbidden',
      );
    }
    if (_containsOutsideRepositoryPath(argument)) {
      throw const FormatException(
        'verification argv must not address paths outside the repository',
      );
    }
  }
  if (arguments.where((argument) => argument == '--no-pub').length != 1) {
    throw const FormatException('verification command requires one --no-pub');
  }
  switch (arguments.first) {
    case 'analyze':
    case 'test':
      break;
    case 'build':
      const buildTargets = {
        'aar',
        'apk',
        'appbundle',
        'bundle',
        'ios',
        'ios-framework',
        'linux',
        'macos',
        'web',
        'windows',
      };
      if (arguments.length < 3 || !buildTargets.contains(arguments[1])) {
        throw const FormatException('Flutter build command is not canonical');
      }
    default:
      throw const FormatException('custom verification command is forbidden');
  }
}

bool _isShellArgument(String value) {
  const exact = {
    'sh',
    'bash',
    'zsh',
    'cmd',
    'cmd.exe',
    'powershell',
    'pwsh',
    'flutter',
    'fvm',
    '-c',
    '/c',
    '&&',
    '||',
    ';',
    '|',
    '>',
    '>>',
    '<',
  };
  return exact.contains(value) ||
      value.contains('&&') ||
      value.contains('||') ||
      value.contains('|') ||
      value.contains('&') ||
      value.contains(';') ||
      value.contains('>') ||
      value.contains('<') ||
      value.contains('`') ||
      value.contains(r'$(');
}

bool _containsOutsideRepositoryPath(String argument) {
  return <String>{argument, ...argument.split('=')}.any(_isOutsidePath);
}

bool _isOutsidePath(String value) {
  final lower = value.toLowerCase();
  final slashNormalized = value.replaceAll('\\', '/');
  final segments = slashNormalized.split('/');
  return value.startsWith('/') ||
      value.startsWith('\\') ||
      value.startsWith('~') ||
      lower.startsWith('file:') ||
      RegExp(r'^[a-zA-Z]:').hasMatch(value) ||
      segments.contains('..');
}

String _commandIdentity(String workingDirectory, List<String> arguments) {
  final canonical = jsonEncode({
    'argumentsAfterCanonicalFlutter': List<String>.from(arguments),
    'workingDirectoryRelativeToRepository': workingDirectory,
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

void _validateFrozenFixtureOverlays(
  String project,
  List<L10nFixtureOverlay> overlays, {
  bool allowPartialManifest = false,
}) {
  // Skip GSY validation when using partial manifest (gitjournal + smooth only)
  if (allowPartialManifest && project == 'gsy') {
    return;
  }

  final expected = switch (project) {
    'gitjournal' => const [
      (
        relativePath: 'flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gitjournal/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        sha256:
            '4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05',
      ),
      (
        relativePath: 'lib/.env.dart',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gitjournal/lib/.env.dart',
        purpose: 'non-secret environment stub',
        sha256:
            'a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33',
      ),
    ],
    'gsy' => const [
      (
        relativePath: 'flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gsy/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        sha256:
            '59dc83948c3ef90c91199af0e520c487c8cac801e1cad46adad6fc3a4c53256d',
      ),
      (
        relativePath: 'lib/common/config/ignoreConfig.dart',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/gsy/lib/common/config/ignoreConfig.dart',
        purpose: 'non-secret ignored configuration stub',
        sha256:
            'cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe',
      ),
    ],
    'smooth' => const [
      (
        relativePath: '.fvmrc',
        sourceIdentity: 'worktrees/v3-stage1/smooth/.fvmrc',
        purpose: 'toolchain selector authority',
        sha256:
            'b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94',
      ),
      (
        relativePath: 'packages/smooth_app/flutter_pruner_v2_accuracy.yaml',
        sourceIdentity:
            'worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml',
        purpose: 'scanner coverage authority',
        sha256:
            '9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527',
      ),
    ],
    _ => throw FormatException('$project fixture overlay authority drift'),
  };
  if (overlays.length != expected.length) {
    throw FormatException('$project fixture overlay authority drift');
  }
  for (var index = 0; index < overlays.length; index++) {
    final overlay = overlays[index];
    final authority = expected[index];
    if (overlay.relativePath != authority.relativePath ||
        overlay.sourceIdentity != authority.sourceIdentity ||
        overlay.purpose != authority.purpose ||
        overlay.sha256 != authority.sha256 ||
        overlay.containsSecrets) {
      throw FormatException('$project fixture overlay authority drift');
    }
  }
}

L10nNormalizationManifest _readNormalizationManifest(
  Directory baseDirectory,
  String name,
  L10nMutationProjectManifest project,
) {
  _requireRelativePath(name, 'normalization manifest');
  final expectedHash = _normalizationManifestSha256ByName[name];
  if (p.posix.basename(name) != name || expectedHash == null) {
    throw const FormatException('unknown normalization manifest');
  }
  final file = File(p.join(baseDirectory.path, name));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const FormatException(
      'normalization manifest must be a regular non-link file',
    );
  }
  final bytes = file.readAsBytesSync();
  final sourceHash = sha256.convert(bytes).toString();
  if (sourceHash != expectedHash) {
    throw const FormatException('normalization manifest SHA-256 drift');
  }
  final json = _asStringMap(
    jsonDecode(utf8.decode(bytes)),
    'normalizationManifest',
  );
  return _parseNormalizationManifest(json, sourceHash, project);
}

L10nNormalizationManifest _parseNormalizationManifest(
  Map<String, Object?> json,
  String sourceHash,
  L10nMutationProjectManifest project,
) {
  const baseKeys = <String>{
    'schemaVersion',
    'normalizationVersion',
    'repositorySha',
    'policy',
    'changedArbs',
  };
  final rawSchema = json['schemaVersion'];
  final keys = rawSchema == 3 ? {...baseKeys, 'generatedBaseline'} : baseKeys;
  _requireExactKeys(json, keys, 'normalizationManifest');
  final reader = _ObjectReader(json, 'normalizationManifest');
  final schemaVersion = reader.integer('schemaVersion');
  final version = reader.string('normalizationVersion');
  final repositoryRevision = reader.string('repositorySha');
  final policy = reader.string('policy');
  final expectedVersion = switch (project.id) {
    'gsy' => 'gsy-normalized-family-v2',
    'gitjournal' => 'gitjournal-normalized-family-v1',
    'smooth' => 'smooth-normalized-family-v2',
    _ => null,
  };
  final expectedPolicy = switch (project.id) {
    'gsy' => 'retain-last-effective-decoded-top-level-member-at-first-position',
    'gitjournal' => 'remove-generator-ignored-extraneous-members',
    'smooth' => 'remove-generator-ignored-or-inconsistent-locale-members',
    _ => null,
  };
  final expectedSchema = project.id == 'smooth' ? 3 : 2;
  if (schemaVersion != expectedSchema ||
      version != expectedVersion ||
      repositoryRevision != project.repositoryRevision ||
      policy != expectedPolicy) {
    throw const FormatException('normalization manifest identity drift');
  }
  final changedValues = reader.list('changedArbs');
  final changedArbs = <L10nNormalizedArb>[];
  for (var index = 0; index < changedValues.length; index++) {
    changedArbs.add(
      _parseNormalizedArb(
        _asStringMap(
          changedValues[index],
          'normalizationManifest.changedArbs[$index]',
        ),
        project,
        index,
      ),
    );
  }
  final generatedBaseline = schemaVersion == 3
      ? _parseNormalizedGeneratedBaseline(
          reader.map('generatedBaseline'),
          project,
        )
      : null;
  reader.finish();
  final paths = changedArbs.map((arb) => arb.relativePath).toList();
  _requireSortedUnique(paths, 'normalization ARB path');
  final expectedPaths = project.id == 'smooth'
      ? project.arbPathsRelative
      : _normalizationPathsByProject[project.id];
  if (expectedPaths == null || !_sameStrings(paths, expectedPaths)) {
    throw const FormatException('normalization ARB membership drift');
  }
  return L10nNormalizationManifest(
    schemaVersion: schemaVersion,
    normalizationVersion: version,
    repositoryRevision: repositoryRevision,
    policy: policy,
    sourceSha256: sourceHash,
    changedArbs: changedArbs,
    generatedBaseline: generatedBaseline,
  );
}

L10nNormalizedGeneratedBaseline _parseNormalizedGeneratedBaseline(
  Map<String, Object?> json,
  L10nMutationProjectManifest project,
) {
  const context = 'normalizationManifest.generatedBaseline';
  _requireExactKeys(json, const {'policy', 'changedOutputs'}, context);
  final reader = _ObjectReader(json, context);
  if (reader.string('policy') !=
      'regenerate-after-normalization-with-pinned-toolchain') {
    throw const FormatException('unknown normalized generated policy');
  }
  final values = reader.list('changedOutputs');
  reader.finish();
  final outputs = <L10nNormalizedGeneratedOutput>[];
  for (var index = 0; index < values.length; index++) {
    final outputContext = '$context.changedOutputs[$index]';
    final outputJson = _asStringMap(values[index], outputContext);
    _requireExactKeys(outputJson, const {
      'relativePath',
      'originalSha256',
      'replacementSha256',
      'posixMode',
    }, outputContext);
    final outputReader = _ObjectReader(outputJson, outputContext);
    final relativePath = outputReader.string('relativePath');
    final originalHash = outputReader.string('originalSha256');
    final replacementHash = outputReader.string('replacementSha256');
    final posixMode = outputReader.integer('posixMode');
    outputReader.finish();
    _requireRelativePath(relativePath, '$outputContext relativePath');
    if (!relativePath.startsWith('${project.arbDirectoryRelative}/') ||
        !relativePath.endsWith('.dart') ||
        project.arbPathsRelative.contains(relativePath)) {
      throw const FormatException(
        'normalized generated output is outside its family',
      );
    }
    outputs.add(
      L10nNormalizedGeneratedOutput(
        relativePath: relativePath,
        originalSha256: originalHash,
        replacementSha256: replacementHash,
        posixMode: posixMode,
      ),
    );
  }
  return L10nNormalizedGeneratedBaseline(changedOutputs: outputs);
}

L10nNormalizedArb _parseNormalizedArb(
  Map<String, Object?> json,
  L10nMutationProjectManifest project,
  int index,
) {
  const keys = <String>{
    'relativePath',
    'originalSha256',
    'replacementSha256',
    'canonicalDecodedObjectSha256',
    'copiedByteSpans',
    'removedByteSpans',
    'decodedObjectEquivalent',
    'replacementHasDuplicateDecodedKeys',
  };
  final context = 'normalizationManifest.changedArbs[$index]';
  _requireExactKeys(json, keys, context);
  final reader = _ObjectReader(json, context);
  final relativePath = reader.string('relativePath');
  _requireRelativePath(relativePath, '$context relativePath');
  if (!project.arbPathsRelative.contains(relativePath)) {
    throw const FormatException('normalization names an unknown ARB path');
  }
  final originalHash = reader.string('originalSha256');
  final replacementHash = reader.string('replacementSha256');
  final canonicalHash = reader.string('canonicalDecodedObjectSha256');
  _requireSha256(originalHash, '$context originalSha256');
  _requireSha256(replacementHash, '$context replacementSha256');
  _requireSha256(canonicalHash, '$context canonicalDecodedObjectSha256');
  if (originalHash == replacementHash) {
    throw const FormatException('normalization must change declared bytes');
  }
  final copyValues = reader.list('copiedByteSpans');
  if (project.id == 'gsy' && copyValues.isEmpty) {
    throw const FormatException('normalization requires copied byte spans');
  }
  if (project.id != 'gsy' && copyValues.isNotEmpty) {
    throw const FormatException(
      'Removal normalization must only remove declared members',
    );
  }
  final copies = <L10nCopiedByteSpan>[];
  var previousCopyEnd = -1;
  for (var copyIndex = 0; copyIndex < copyValues.length; copyIndex++) {
    final copyPath = '$context.copiedByteSpans[$copyIndex]';
    final copyJson = _asStringMap(copyValues[copyIndex], copyPath);
    _requireExactKeys(copyJson, const {
      'start',
      'endExclusive',
      'sourceStart',
      'sourceEndExclusive',
    }, copyPath);
    final copyReader = _ObjectReader(copyJson, copyPath);
    final start = copyReader.integer('start');
    final end = copyReader.integer('endExclusive');
    final sourceStart = copyReader.integer('sourceStart');
    final sourceEnd = copyReader.integer('sourceEndExclusive');
    copyReader.finish();
    if (start < 0 ||
        start < previousCopyEnd ||
        end <= start ||
        sourceStart < 0 ||
        sourceEnd <= sourceStart) {
      throw const FormatException('normalization copy spans are not canonical');
    }
    copies.add(
      L10nCopiedByteSpan(
        start: start,
        endExclusive: end,
        sourceStart: sourceStart,
        sourceEndExclusive: sourceEnd,
      ),
    );
    previousCopyEnd = end;
  }
  final spanValues = reader.list('removedByteSpans');
  if (spanValues.isEmpty) {
    throw const FormatException('normalization requires removed byte spans');
  }
  final spans = <L10nRemovedByteSpan>[];
  var previousEnd = -1;
  for (var spanIndex = 0; spanIndex < spanValues.length; spanIndex++) {
    final spanPath = '$context.removedByteSpans[$spanIndex]';
    final spanJson = _asStringMap(spanValues[spanIndex], spanPath);
    _requireExactKeys(spanJson, const {'start', 'endExclusive'}, spanPath);
    final spanReader = _ObjectReader(spanJson, spanPath);
    final start = spanReader.integer('start');
    final end = spanReader.integer('endExclusive');
    spanReader.finish();
    if (start < 0 || start < previousEnd || end <= start) {
      throw const FormatException('normalization byte spans are not canonical');
    }
    spans.add(L10nRemovedByteSpan(start: start, endExclusive: end));
    previousEnd = end;
  }
  final equivalent = reader.boolean('decodedObjectEquivalent');
  final hasDuplicates = reader.boolean('replacementHasDuplicateDecodedKeys');
  reader.finish();
  final expectedEquivalent = project.id == 'gsy';
  if (equivalent != expectedEquivalent || hasDuplicates) {
    throw const FormatException(
      'normalization decoded-object authority is unsafe',
    );
  }
  final targets = <({int start, int endExclusive})>[
    for (final copy in copies)
      (start: copy.start, endExclusive: copy.endExclusive),
    for (final span in spans)
      (start: span.start, endExclusive: span.endExclusive),
  ]..sort((left, right) => left.start.compareTo(right.start));
  for (var targetIndex = 1; targetIndex < targets.length; targetIndex++) {
    if (targets[targetIndex].start < targets[targetIndex - 1].endExclusive) {
      throw const FormatException('normalization transform targets overlap');
    }
  }
  return L10nNormalizedArb(
    relativePath: relativePath,
    originalSha256: originalHash,
    replacementSha256: replacementHash,
    canonicalDecodedObjectSha256: canonicalHash,
    copiedByteSpans: copies,
    removedByteSpans: spans,
    decodedObjectEquivalent: equivalent,
    replacementHasDuplicateDecodedKeys: hasDuplicates,
  );
}

final class _FrozenProject {
  const _FrozenProject({
    required this.repositoryRevision,
    required this.packageRoot,
    required this.arbDirectory,
    required this.templateArbPath,
    required this.toolchainVersion,
    required this.sourceOracleSha256,
    required this.positiveKeys,
    required this.negativeKeys,
  });

  final String repositoryRevision;
  final String packageRoot;
  final String arbDirectory;
  final String templateArbPath;
  final String toolchainVersion;
  final String sourceOracleSha256;
  final int positiveKeys;
  final int negativeKeys;
}

final class _ObjectReader {
  _ObjectReader(this.values, this.context);

  final Map<String, Object?> values;
  final String context;
  final Set<String> _read = {};

  Object? _take(String key) {
    if (!values.containsKey(key)) {
      throw FormatException('$context is missing $key');
    }
    _read.add(key);
    return values[key];
  }

  String string(String key) {
    final value = _take(key);
    if (value is! String) {
      throw FormatException('$context.$key must be a string');
    }
    return value;
  }

  int integer(String key) {
    final value = _take(key);
    if (value is! int) {
      throw FormatException('$context.$key must be an integer');
    }
    return value;
  }

  bool boolean(String key) {
    final value = _take(key);
    if (value is! bool) {
      throw FormatException('$context.$key must be a boolean');
    }
    return value;
  }

  Map<String, Object?> map(String key) =>
      _asStringMap(_take(key), '$context.$key');

  List<Object?> list(String key) => _asList(_take(key), '$context.$key');

  void finish() {
    if (_read.length != values.length) {
      throw FormatException('$context contains an unread field');
    }
  }
}

Map<String, Object?> _asStringMap(Object? value, String context) {
  if (value is! Map) throw FormatException('$context must be an object');
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$context contains a non-string key');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

List<Object?> _asList(Object? value, String context) {
  if (value is! List) throw FormatException('$context must be a list');
  return List<Object?>.from(value);
}

List<String> _stringList(List<Object?> values, String context) {
  final result = <String>[];
  for (final value in values) {
    if (value is! String) {
      throw FormatException('$context must contain strings');
    }
    result.add(value);
  }
  return result;
}

void _requireExactKeys(
  Map<String, Object?> json,
  Set<String> expected,
  String context,
) {
  final actual = json.keys.toSet();
  if (actual.length != expected.length || !actual.containsAll(expected)) {
    throw FormatException('$context has unknown or missing fields');
  }
}

void _requireNonEmpty(String value, String context) {
  if (value.isEmpty || _containsControl(value)) {
    throw FormatException('$context must be a non-empty printable string');
  }
}

void _requireGitSha(String value, String context) {
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
    throw FormatException('$context must be a lowercase Git SHA');
  }
}

void _requireSha256(String value, String context) {
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('$context must be a lowercase SHA-256');
  }
}

void _requireRelativePath(String value, String context) {
  if (value.isEmpty ||
      _containsControl(value) ||
      value.contains('\\') ||
      value.startsWith('/') ||
      value.startsWith('~') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      p.posix.isAbsolute(value) ||
      p.posix.normalize(value) != value ||
      (value != '.' &&
          value.split('/').any((part) => part.isEmpty || part == '.')) ||
      value.split('/').contains('..')) {
    throw FormatException('$context must stay inside the repository');
  }
}

bool _containsControl(String value) =>
    value.runes.any((rune) => rune < 0x20 || rune == 0x7f);

void _requireSortedUnique(List<String> values, String context) {
  final sorted = List<String>.from(values)..sort();
  if (!_sameStrings(values, sorted) || values.toSet().length != values.length) {
    throw FormatException('$context values must be sorted and unique');
  }
}

void _requireUnique(Iterable<String> values, String context) {
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(value)) throw FormatException('duplicate $context');
  }
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _deepEquals(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

Map<String, Object?> _deepFreezeMap(Map<String, Object?> source) {
  return Map.unmodifiable(
    source.map((key, value) => MapEntry(key, _deepFreeze(value))),
  );
}

Object? _deepFreeze(Object? value) {
  if (value is Map) {
    return _deepFreezeMap(_asStringMap(value, 'immutable value'));
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_deepFreeze));
  }
  return value;
}
