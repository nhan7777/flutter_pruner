import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../../../core/project/project_context.dart';
import '../../dart/dart_analysis_workspace.dart';
import 'immutable_bytes.dart';
import 'l10n_evidence_failure.dart';
import 'l10n_family_preflight.dart';
import 'l10n_family_snapshot.dart';
import 'l10n_generation_config.dart';
import 'l10n_toolchain.dart';

const _stage = 'snapshot-revalidation';
const _packageConfigPath = '.dart_tool/package_config.json';

/// Typed result of checking whether a captured family authority is still live.
sealed class L10nSnapshotRevalidationResult {
  const L10nSnapshotRevalidationResult();
}

/// Every source, package, configuration, and toolchain authority still matches.
final class L10nSnapshotStillCurrent extends L10nSnapshotRevalidationResult {
  /// Creates one fully re-proven authority result.
  const L10nSnapshotStillCurrent({
    required this.sourceIdentity,
    required this.packageResolutionIdentity,
    required this.toolchainIdentity,
  });

  /// Fresh root-independent identity of every retained source state.
  final String sourceIdentity;

  /// Re-proven package resolution authority.
  final String packageResolutionIdentity;

  /// Re-proven canonical Flutter toolchain authority.
  final String toolchainIdentity;
}

/// One or more stable source, package, or toolchain drift facts.
final class L10nSnapshotDrifted extends L10nSnapshotRevalidationResult {
  /// Creates a sorted, de-duplicated, immutable non-empty drift result.
  L10nSnapshotDrifted(Iterable<L10nEvidenceFailure> failures)
    : failures = _sortedFailures(failures) {
    if (this.failures.isEmpty) {
      throw ArgumentError.value(failures, 'failures', 'must not be empty');
    }
    if (this.failures.any((failure) => !_validDriftFailure(failure))) {
      throw ArgumentError('A snapshot drift failure is not stable/redacted.');
    }
  }

  /// Deterministically sorted, de-duplicated, immutable drift facts.
  final List<L10nEvidenceFailure> failures;
}

/// Projects the root-independent source identity expected from one snapshot.
///
/// The revalidator returns this exact identity only after proving that every
/// live entry has the same state, bytes, hash, and mode.
final class L10nSnapshotSourceIdentityProjector {
  /// Creates the stateless source-identity projector.
  const L10nSnapshotSourceIdentityProjector();

  /// Hashes ordered entry path, role, presence, source hash, and POSIX mode.
  String project(L10nFamilySnapshot snapshot) =>
      _hashCanonical(<String, Object?>{
        'entries': <Object?>[
          for (final entry in snapshot.entries.values)
            <String, Object?>{
              'path': entry.relativePosixPath,
              'role': entry.role.name,
              ..._snapshotStateSourceIdentity(entry.state),
            },
        ],
      });
}

/// Rebuilds the exact package-resolution identity captured by preflight.
final class L10nSnapshotPackageResolutionIdentityProjector {
  /// Creates the stateless package-resolution projector.
  const L10nSnapshotPackageResolutionIdentityProjector();

  /// Hashes the fresh package projection and all retained package authorities.
  String project({
    required L10nFamilySnapshot snapshot,
    required L10nPackageConfigProjection packageProjection,
  }) => _hashCanonical(<String, Object?>{
    'projection': packageProjection.identity,
    'packageConfig': _snapshotEntryIdentity(
      snapshot.entries[_packageConfigPath]!,
    ),
    'lockfile': _snapshotEntryIdentity(snapshot.entries['pubspec.lock']!),
    'packageGraph': _snapshotEntryIdentity(
      snapshot.entries['.dart_tool/package_graph.json']!,
    ),
    'externalAnalysisOptions': snapshot.analysisOptionsProjection.identity,
  });
}

/// Rechecks a family snapshot without mutating the selected project.
abstract interface class L10nSnapshotRevalidator {
  /// Returns fresh identities or deterministic typed drift facts.
  Future<L10nSnapshotRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    Directory? toolchainAuthorityRoot,
    required L10nFamilySnapshot snapshot,
    required L10nToolchainResolved toolchain,
  });
}

/// Production fail-closed snapshot revalidator.
final class DefaultL10nSnapshotRevalidator implements L10nSnapshotRevalidator {
  /// Creates the production gate with explicit toolchain and config seams.
  DefaultL10nSnapshotRevalidator({
    required L10nToolchainResolver toolchainResolver,
    required L10nGenerationConfigLoader configLoader,
  }) : _toolchainResolver = toolchainResolver,
       _configLoader = configLoader,
       _beforeFinalAuthorityPass = null;

  /// Creates a deterministic test gate around the final authority pass.
  DefaultL10nSnapshotRevalidator.testing({
    required L10nToolchainResolver toolchainResolver,
    required L10nGenerationConfigLoader configLoader,
    required Future<void> Function() beforeFinalAuthorityPass,
  }) : _toolchainResolver = toolchainResolver,
       _configLoader = configLoader,
       _beforeFinalAuthorityPass = beforeFinalAuthorityPass;

  final L10nToolchainResolver _toolchainResolver;
  final L10nGenerationConfigLoader _configLoader;
  final Future<void> Function()? _beforeFinalAuthorityPass;

  /// Revalidates without resolving dependencies or mutating the source tree.
  @override
  Future<L10nSnapshotRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    Directory? toolchainAuthorityRoot,
    required L10nFamilySnapshot snapshot,
    required L10nToolchainResolved toolchain,
  }) async {
    final failures = <L10nEvidenceFailure>[];
    final canonicalRoot = _canonicalRoot(originalProjectRoot, failures);
    final firstRead = canonicalRoot == null
        ? const <String, _LiveEntryState>{}
        : _readSnapshotEntries(canonicalRoot, snapshot, failures);

    ProjectContext? project;
    L10nGenerationConfig? config;
    if (canonicalRoot != null) {
      project = _projectFor(originalProjectRoot, snapshot);
      config = await _revalidateConfiguration(
        loader: _configLoader,
        project: project,
        snapshot: snapshot,
        toolchain: toolchain,
        failures: failures,
      );
      if (config != null) {
        _revalidateArbMembership(
          canonicalRoot: canonicalRoot,
          config: config,
          snapshot: snapshot,
          failures: failures,
        );
        _revalidateOutputMembership(
          canonicalRoot: canonicalRoot,
          config: config,
          snapshot: snapshot,
          failures: failures,
        );
      }
      _revalidateAnalyzerAuthorities(
        canonicalRoot: canonicalRoot,
        project: project,
        snapshot: snapshot,
        failures: failures,
      );
      _revalidatePackageAuthority(
        canonicalRoot: canonicalRoot,
        snapshot: snapshot,
        toolchain: toolchain,
        sourceEntries: firstRead,
        failures: failures,
      );
    }

    final beforeFinalAuthorityPass = _beforeFinalAuthorityPass;
    if (beforeFinalAuthorityPass != null) {
      try {
        await beforeFinalAuthorityPass();
      } on Object {
        failures.add(_sourceFailure('authority-pass-hook-failed'));
      }
    }

    // The toolchain probe is linearized between two complete source/package/
    // analyzer membership passes. A mutation during the probe is therefore
    // observed by the final pass rather than escaping through a TOCTOU gap.
    final freshToolchainIdentity = await _revalidateToolchain(
      resolver: _toolchainResolver,
      originalProjectRoot: toolchainAuthorityRoot ?? originalProjectRoot,
      snapshot: snapshot,
      toolchain: toolchain,
      failures: failures,
    );

    final finalRead = canonicalRoot == null
        ? const <String, _LiveEntryState>{}
        : _readSnapshotEntries(canonicalRoot, snapshot, failures);
    String? freshPackageResolutionIdentity;
    if (canonicalRoot != null) {
      _rejectRacedEntries(
        snapshot: snapshot,
        before: firstRead,
        after: finalRead,
        failures: failures,
      );
      if (config != null) {
        _revalidateArbMembership(
          canonicalRoot: canonicalRoot,
          config: config,
          snapshot: snapshot,
          failures: failures,
        );
        _revalidateOutputMembership(
          canonicalRoot: canonicalRoot,
          config: config,
          snapshot: snapshot,
          failures: failures,
        );
      }
      _revalidateAnalyzerAuthorities(
        canonicalRoot: canonicalRoot,
        project: project!,
        snapshot: snapshot,
        failures: failures,
      );
      freshPackageResolutionIdentity = _revalidatePackageAuthority(
        canonicalRoot: canonicalRoot,
        snapshot: snapshot,
        toolchain: toolchain,
        sourceEntries: finalRead,
        failures: failures,
      );
    }

    final frozenFailures = _sortedFailures(failures);
    if (frozenFailures.isNotEmpty) {
      return L10nSnapshotDrifted(frozenFailures);
    }
    return L10nSnapshotStillCurrent(
      sourceIdentity: const L10nSnapshotSourceIdentityProjector().project(
        snapshot,
      ),
      packageResolutionIdentity: freshPackageResolutionIdentity!,
      toolchainIdentity: freshToolchainIdentity!,
    );
  }
}

String? _canonicalRoot(
  Directory originalProjectRoot,
  List<L10nEvidenceFailure> failures,
) {
  try {
    final requested = p.normalize(p.absolute(originalProjectRoot.path));
    if (FileSystemEntity.typeSync(requested, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('project root unavailable');
    }
    final canonical = p.normalize(
      Directory(requested).resolveSymbolicLinksSync(),
    );
    if (canonical != requested) {
      throw const FileSystemException('project root is not canonical');
    }
    return canonical;
  } on Object {
    failures.add(_sourceFailure('project-root-authority-drift'));
    return null;
  }
}

ProjectContext _projectFor(
  Directory originalProjectRoot,
  L10nFamilySnapshot snapshot,
) {
  final semantics = snapshot.projectSemantics;
  return ProjectContext(
    root: originalProjectRoot,
    pubspec: semantics.pubspec,
    packageName: semantics.packageName,
    analysisMode: semantics.analysisMode,
    targetMatrix: semantics.targetMatrix,
    rootCoverage: semantics.rootCoverage,
  );
}

Map<String, _LiveEntryState> _readSnapshotEntries(
  String canonicalRoot,
  L10nFamilySnapshot snapshot,
  List<L10nEvidenceFailure> failures,
) {
  final result = SplayTreeMap<String, _LiveEntryState>();
  for (final entry in snapshot.entries.values) {
    final packageAuthority = _isPackageEntry(entry.role);
    try {
      final live = _captureEntry(canonicalRoot, entry.relativePosixPath);
      result[entry.relativePosixPath] = live;
      if (!_matchesSnapshotState(live, entry.state)) {
        failures.add(
          _entryFailure(
            packageAuthority: packageAuthority,
            detailCode: packageAuthority
                ? 'package-entry-drift'
                : 'source-entry-drift',
            relativePath: entry.relativePosixPath,
          ),
        );
      }
    } on Object {
      failures.add(
        _entryFailure(
          packageAuthority: packageAuthority,
          detailCode: packageAuthority
              ? 'package-entry-drift'
              : 'source-entry-drift',
          relativePath: entry.relativePosixPath,
        ),
      );
    }
  }
  return Map<String, _LiveEntryState>.unmodifiable(result);
}

_LiveEntryState _captureEntry(String canonicalRoot, String relativePath) {
  final absolute = p.normalize(
    p.joinAll(<String>[canonicalRoot, ...relativePath.split('/')]),
  );
  if (!_within(canonicalRoot, absolute)) {
    throw const FileSystemException('snapshot path escaped');
  }
  var current = canonicalRoot;
  for (final segment in relativePath.split('/')) {
    current = p.join(current, segment);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw const FileSystemException('snapshot path contains a link');
    }
    if (type == FileSystemEntityType.notFound) break;
  }
  final type = FileSystemEntity.typeSync(absolute, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    return const _LiveEntryState.absent();
  }
  if (type != FileSystemEntityType.file) {
    throw const FileSystemException('snapshot path is not a regular file');
  }
  final file = File(absolute);
  final canonicalBefore = p.normalize(file.resolveSymbolicLinksSync());
  if (canonicalBefore != absolute || !_within(canonicalRoot, canonicalBefore)) {
    throw const FileSystemException('snapshot file is not canonical');
  }
  final before = file.statSync();
  final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
  final after = file.statSync();
  final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
  if (!_sameStat(before, after) || canonicalAfter != canonicalBefore) {
    throw const FileSystemException('snapshot file changed while read');
  }
  return _LiveEntryState.present(
    bytes: bytes,
    posixMode: Platform.isWindows ? null : before.mode & 0xfff,
    size: before.size,
    modifiedMicros: before.modified.microsecondsSinceEpoch,
    changedMicros: before.changed.microsecondsSinceEpoch,
  );
}

bool _matchesSnapshotState(
  _LiveEntryState live,
  L10nSnapshotFileState expected,
) => switch (expected) {
  L10nSnapshotAbsent() => !live.present,
  L10nSnapshotPresent() =>
    live.present &&
        live.bytes != null &&
        live.bytes!.sha256Hex == expected.sourceSha256 &&
        live.bytes!.contentEquals(expected.sourceBytes) &&
        live.posixMode == expected.posixMode,
};

void _rejectRacedEntries({
  required L10nFamilySnapshot snapshot,
  required Map<String, _LiveEntryState> before,
  required Map<String, _LiveEntryState> after,
  required List<L10nEvidenceFailure> failures,
}) {
  for (final entry in snapshot.entries.values) {
    final first = before[entry.relativePosixPath];
    final last = after[entry.relativePosixPath];
    if (first == null || last == null || first.sameAuthority(last)) continue;
    final packageAuthority = _isPackageEntry(entry.role);
    failures.add(
      _entryFailure(
        packageAuthority: packageAuthority,
        detailCode: packageAuthority
            ? 'package-entry-authority-raced'
            : 'source-entry-authority-raced',
        relativePath: entry.relativePosixPath,
      ),
    );
  }
}

Future<String?> _revalidateToolchain({
  required L10nToolchainResolver resolver,
  required Directory originalProjectRoot,
  required L10nFamilySnapshot snapshot,
  required L10nToolchainResolved toolchain,
  required List<L10nEvidenceFailure> failures,
}) async {
  if (toolchain.identitySha256 != snapshot.toolchainIdentity) {
    failures.add(_toolchainFailure('frozen-toolchain-identity-drift'));
  }
  try {
    final result = await resolver.revalidate(
      originalProjectRoot: originalProjectRoot,
      expected: toolchain,
    );
    switch (result) {
      case L10nToolchainStillMatches(:final identitySha256):
        if (identitySha256 != snapshot.toolchainIdentity ||
            identitySha256 != toolchain.identitySha256) {
          failures.add(_toolchainFailure('toolchain-identity-drift'));
          return null;
        }
        return identitySha256;
      case L10nToolchainChanged(:final failure):
        failures.add(
          _toolchainFailure(
            _safeDetail(failure.detailCode, 'toolchain-revalidation-drift'),
            relativePath: _safeRelativeOrNull(failure.relativePath),
          ),
        );
        return null;
    }
  } on Object {
    failures.add(_toolchainFailure('toolchain-revalidation-failed'));
    return null;
  }
}

Future<L10nGenerationConfig?> _revalidateConfiguration({
  required L10nGenerationConfigLoader loader,
  required ProjectContext project,
  required L10nFamilySnapshot snapshot,
  required L10nToolchainResolved toolchain,
  required List<L10nEvidenceFailure> failures,
}) async {
  try {
    final result = await loader.load(
      project: project,
      toolchain: toolchain.machineIdentity,
    );
    switch (result) {
      case L10nGenerationConfigReady(:final config):
        if (config.configurationIdentity != snapshot.configurationIdentity) {
          failures.add(_sourceFailure('strict-configuration-identity-drift'));
          return null;
        }
        return config;
      case L10nGenerationConfigRejected(failures: final rejected):
        if (rejected.isEmpty) {
          failures.add(
            _sourceFailure('strict-configuration-revalidation-rejected'),
          );
          return null;
        }
        for (final failure in rejected) {
          // Loader paths are not retained here: an injected or future loader
          // must not smuggle absolute paths into the evidence result.
          // Snapshot-entry checks already retain safe source attribution.
          failures.add(
            _sourceFailure(
              'strict-configuration-'
              '${_safeDetail(failure.detailCode, 'revalidation-rejected')}',
            ),
          );
        }
        return null;
    }
  } on Object {
    failures.add(_sourceFailure('strict-configuration-revalidation-failed'));
    return null;
  }
}

void _revalidateArbMembership({
  required String canonicalRoot,
  required L10nGenerationConfig config,
  required L10nFamilySnapshot snapshot,
  required List<L10nEvidenceFailure> failures,
}) {
  try {
    final arbRoot = p.normalize(
      p.joinAll(<String>[canonicalRoot, ...config.arbDirectory.split('/')]),
    );
    if (!_within(canonicalRoot, arbRoot) ||
        FileSystemEntity.typeSync(arbRoot, followLinks: false) !=
            FileSystemEntityType.directory ||
        p.normalize(Directory(arbRoot).resolveSymbolicLinksSync()) != arbRoot) {
      throw const FileSystemException('ARB directory unavailable');
    }
    final actual = <String>{};
    final folded = <String, String>{};
    for (final entity in Directory(arbRoot).listSync(followLinks: false)) {
      if (p.extension(entity.path).toLowerCase() != '.arb') continue;
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FileSystemException('ARB member is not a file');
      }
      final absolute = p.normalize(p.absolute(entity.path));
      if (!_within(canonicalRoot, absolute) ||
          p.normalize(File(absolute).resolveSymbolicLinksSync()) != absolute) {
        throw const FileSystemException('ARB member is not canonical');
      }
      final relative = _relative(canonicalRoot, absolute);
      final fold = _asciiFold(relative);
      if (folded.putIfAbsent(fold, () => relative) != relative) {
        throw const FileSystemException('ARB member case collision');
      }
      actual.add(relative);
    }
    final expected = <String>{
      for (final entry in snapshot.entries.values)
        if (entry.role == L10nSnapshotRole.arbTemplate ||
            entry.role == L10nSnapshotRole.arbLocale)
          entry.relativePosixPath,
    };
    if (!_sameStrings(expected, actual)) {
      failures.add(_sourceFailure('arb-family-membership-drift'));
    }
  } on Object {
    failures.add(_sourceFailure('arb-family-membership-drift'));
  }
}

void _revalidateOutputMembership({
  required String canonicalRoot,
  required L10nGenerationConfig config,
  required L10nFamilySnapshot snapshot,
  required List<L10nEvidenceFailure> failures,
}) {
  try {
    final outputRoot = p.normalize(
      p.joinAll(<String>[canonicalRoot, ...config.outputDirectory.split('/')]),
    );
    final type = FileSystemEntity.typeSync(outputRoot, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (snapshot.provenUnrelatedOutputSiblings.isNotEmpty) {
        failures.add(_sourceFailure('output-sibling-membership-drift'));
      }
      return;
    }
    if (!_within(canonicalRoot, outputRoot) ||
        type != FileSystemEntityType.directory ||
        p.normalize(Directory(outputRoot).resolveSymbolicLinksSync()) !=
            outputRoot) {
      throw const FileSystemException('output directory unavailable');
    }
    final expectedFamilyByFold = <String, String>{
      for (final path in snapshot.expectedGeneratedPaths)
        _asciiFold(path): path,
    };
    final arbInputPaths = <String>{
      for (final entry in snapshot.entries.values)
        if (entry.role == L10nSnapshotRole.arbTemplate ||
            entry.role == L10nSnapshotRole.arbLocale)
          entry.relativePosixPath,
    };
    final baseName = p.posix.basename(config.baseOutputPath);
    final dot = baseName.indexOf('.');
    if (dot <= 0) {
      throw const FileSystemException('output filename unavailable');
    }
    final stem = _asciiFold(baseName.substring(0, dot));
    final suffix = _asciiFold(baseName.substring(dot));
    final actualSiblings = <String>{};
    for (final entity in Directory(outputRoot).listSync(followLinks: false)) {
      final entityType = FileSystemEntity.typeSync(
        entity.path,
        followLinks: false,
      );
      if (entityType == FileSystemEntityType.directory) continue;
      if (entityType != FileSystemEntityType.file) {
        throw const FileSystemException('output sibling is not a file');
      }
      final absolute = p.normalize(p.absolute(entity.path));
      if (!_within(canonicalRoot, absolute) ||
          p.normalize(File(absolute).resolveSymbolicLinksSync()) != absolute) {
        throw const FileSystemException('output sibling is not canonical');
      }
      final relative = _relative(canonicalRoot, absolute);
      final expectedSpelling = expectedFamilyByFold[_asciiFold(relative)];
      if (expectedSpelling != null) {
        if (expectedSpelling != relative) {
          throw const FileSystemException('output family case drift');
        }
        continue;
      }
      if (relative == snapshot.optionalUntranslatedPath) continue;
      if (arbInputPaths.contains(relative)) continue;
      final name = _asciiFold(p.posix.basename(relative));
      if (name.startsWith('${stem}_') && name.endsWith(suffix)) {
        throw const FileSystemException('unowned output family sibling');
      }
      actualSiblings.add(relative);
    }
    if (!_sameStrings(snapshot.provenUnrelatedOutputSiblings, actualSiblings)) {
      failures.add(_sourceFailure('output-sibling-membership-drift'));
    }
  } on Object {
    failures.add(_sourceFailure('output-sibling-membership-drift'));
  }
}

void _revalidateAnalyzerAuthorities({
  required String canonicalRoot,
  required ProjectContext project,
  required L10nFamilySnapshot snapshot,
  required List<L10nEvidenceFailure> failures,
}) {
  try {
    final context = const L10nAnalyzerContextAuthorityProjector().project(
      project,
      nestedAuthorityPaths:
          snapshot.analysisOptionsProjection.nestedAuthorityPaths,
    );
    switch (context) {
      case L10nAnalyzerContextAuthorityProjectionReady(:final projection):
        if (projection.identity !=
            snapshot.analysisOptionsProjection.contextAuthorityIdentity) {
          failures.add(_sourceFailure('analyzer-context-authority-drift'));
        }
      case L10nAnalyzerContextAuthorityProjectionRejected():
        failures.add(_sourceFailure('analyzer-context-authority-drift'));
    }
  } on Object {
    failures.add(_sourceFailure('analyzer-context-authority-drift'));
  }

  final externalOptions = snapshot.analysisOptionsProjection.revalidate();
  if (externalOptions is L10nAnalysisOptionsRevalidationRejected) {
    failures.add(_sourceFailure('analysis-options-external-drift'));
  }

  try {
    for (final entity in Directory(
      canonicalRoot,
    ).listSync(recursive: true, followLinks: false)) {
      if (p.extension(entity.path).toLowerCase() == '.dart' &&
          FileSystemEntity.typeSync(entity.path, followLinks: false) ==
              FileSystemEntityType.link) {
        throw const FileSystemException('Dart source link found');
      }
    }
    final actual = <String>{};
    final folded = <String, String>{};
    for (final sourcePath in DartAnalysisWorkspace(project).dartFiles) {
      final absolute = p.normalize(p.absolute(sourcePath));
      if (!_within(canonicalRoot, absolute) ||
          FileSystemEntity.typeSync(absolute, followLinks: false) !=
              FileSystemEntityType.file ||
          p.normalize(File(absolute).resolveSymbolicLinksSync()) != absolute) {
        throw const FileSystemException('Analyzer source is not canonical');
      }
      final relative = _relative(canonicalRoot, absolute);
      final fold = _asciiFold(relative);
      if (folded.putIfAbsent(fold, () => relative) != relative) {
        throw const FileSystemException('Analyzer source case collision');
      }
      actual.add(relative);
    }
    if (!_sameStrings(
      snapshot.verificationClosure.projectOwnedDartPaths,
      actual,
    )) {
      failures.add(_sourceFailure('analyzer-closure-membership-drift'));
    }
  } on Object {
    failures.add(_sourceFailure('analyzer-closure-membership-drift'));
  }
}

String? _revalidatePackageAuthority({
  required String canonicalRoot,
  required L10nFamilySnapshot snapshot,
  required L10nToolchainResolved toolchain,
  required Map<String, _LiveEntryState> sourceEntries,
  required List<L10nEvidenceFailure> failures,
}) {
  final livePackage = sourceEntries[_packageConfigPath];
  if (livePackage?.bytes == null) {
    failures.add(
      _packageFailure(
        'package-config-authority-unavailable',
        relativePath: _packageConfigPath,
      ),
    );
    return null;
  }
  try {
    final result = const L10nPackageConfigProjector().project(
      sourceBytes: livePackage!.bytes!.copy(),
      canonicalProjectRoot: canonicalRoot,
      selectedPackageName: snapshot.projectSemantics.packageName,
      toolchain: toolchain,
    );
    switch (result) {
      case L10nPackageConfigProjectionRejected(:final failure):
        failures.add(
          _packageFailure(
            _safeDetail(failure.detailCode, 'package-projection-rejected'),
            relativePath: _safeRelativeOrNull(failure.relativePath),
          ),
        );
        return null;
      case L10nPackageConfigProjectionReady(:final projection):
        final expectedState = snapshot.entries[_packageConfigPath]?.state;
        final exactBytes =
            expectedState is L10nSnapshotPresent &&
            projection.sourceBytes.contentEquals(expectedState.sourceBytes) &&
            projection.stageBytes.contentEquals(expectedState.stageBytes);
        if (!exactBytes ||
            projection.authorityIdentity !=
                snapshot.packageConfigProjectionIdentity) {
          failures.add(_packageFailure('package-authority-identity-drift'));
        }
        final freshIdentity =
            const L10nSnapshotPackageResolutionIdentityProjector().project(
              snapshot: snapshot,
              packageProjection: projection,
            );
        if (freshIdentity != snapshot.packageResolutionIdentity) {
          failures.add(_packageFailure('package-resolution-identity-drift'));
        }
        return freshIdentity;
    }
  } on Object {
    failures.add(
      _packageFailure(
        'package-projection-revalidation-failed',
        relativePath: _packageConfigPath,
      ),
    );
    return null;
  }
}

Map<String, Object?> _snapshotEntryIdentity(L10nSnapshotEntry entry) {
  final state = entry.state;
  return <String, Object?>{
    'path': entry.relativePosixPath,
    'role': entry.role.name,
    if (state is L10nSnapshotPresent) ...<String, Object?>{
      'present': true,
      'sourceSha256': state.sourceSha256,
      'stageSha256': state.stageBytes.sha256Hex,
      'mode': state.posixMode,
    } else
      'present': false,
  };
}

Map<String, Object?> _snapshotStateSourceIdentity(
  L10nSnapshotFileState state,
) => switch (state) {
  L10nSnapshotAbsent() => const <String, Object?>{'present': false},
  L10nSnapshotPresent() => <String, Object?>{
    'present': true,
    'sha256': state.sourceSha256,
    'length': state.sourceBytes.length,
    'mode': state.posixMode,
  },
};

bool _isPackageEntry(L10nSnapshotRole role) =>
    role == L10nSnapshotRole.lockfile ||
    role == L10nSnapshotRole.packageConfig ||
    role == L10nSnapshotRole.packageGraph;

bool _validDriftFailure(L10nEvidenceFailure failure) {
  final validCode =
      failure.code == L10nEvidenceRejectionCode.sourceDrift ||
      failure.code == L10nEvidenceRejectionCode.packageResolutionDrift ||
      failure.code == L10nEvidenceRejectionCode.toolchainDrift;
  return validCode &&
      _validEvidenceToken(failure.stage) &&
      _validEvidenceToken(failure.detailCode) &&
      (failure.relativePath == null || _isSafeRelative(failure.relativePath!));
}

bool _validEvidenceToken(String value) =>
    value.length <= 128 &&
    RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(value);

L10nEvidenceFailure _entryFailure({
  required bool packageAuthority,
  required String detailCode,
  required String relativePath,
}) => L10nEvidenceFailure(
  code: packageAuthority
      ? L10nEvidenceRejectionCode.packageResolutionDrift
      : L10nEvidenceRejectionCode.sourceDrift,
  stage: _stage,
  detailCode: detailCode,
  relativePath: relativePath,
);

L10nEvidenceFailure _sourceFailure(String detailCode, {String? relativePath}) =>
    L10nEvidenceFailure(
      code: L10nEvidenceRejectionCode.sourceDrift,
      stage: _stage,
      detailCode: detailCode,
      relativePath: relativePath,
    );

L10nEvidenceFailure _packageFailure(
  String detailCode, {
  String? relativePath,
}) => L10nEvidenceFailure(
  code: L10nEvidenceRejectionCode.packageResolutionDrift,
  stage: _stage,
  detailCode: detailCode,
  relativePath: relativePath,
);

L10nEvidenceFailure _toolchainFailure(
  String detailCode, {
  String? relativePath,
}) => L10nEvidenceFailure(
  code: L10nEvidenceRejectionCode.toolchainDrift,
  stage: _stage,
  detailCode: detailCode,
  relativePath: relativePath,
);

String _safeDetail(String value, String fallback) =>
    _validEvidenceToken(value) ? value : fallback;

String? _safeRelativeOrNull(String? value) =>
    value != null && _isSafeRelative(value) ? value : null;

bool _isSafeRelative(String value) =>
    value.isNotEmpty &&
    !value.startsWith('/') &&
    !value.endsWith('/') &&
    !value.contains('\\') &&
    !value.contains(':') &&
    !value.contains('%') &&
    !value.contains('?') &&
    !value.contains('#') &&
    value
        .split('/')
        .every(
          (segment) =>
              segment.isNotEmpty &&
              segment != '.' &&
              segment != '..' &&
              RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
        ) &&
    !value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e);

bool _within(String root, String candidate) {
  final relative = p.relative(candidate, from: root);
  return relative == '.' ||
      (!p.isAbsolute(relative) &&
          relative != '..' &&
          !relative.startsWith('..${p.separator}'));
}

String _relative(String root, String absolute) =>
    p.relative(absolute, from: root).replaceAll('\\', '/');

String _asciiFold(String value) => String.fromCharCodes(
  value.codeUnits.map(
    (unit) => unit >= 0x41 && unit <= 0x5a ? unit + 0x20 : unit,
  ),
);

bool _sameStrings(Iterable<String> left, Iterable<String> right) {
  final a = left.toList()..sort();
  final b = right.toList()..sort();
  return a.length == b.length &&
      a.asMap().entries.every((entry) => entry.value == b[entry.key]);
}

bool _sameStat(FileStat left, FileStat right) =>
    left.type == right.type &&
    left.size == right.size &&
    left.mode == right.mode &&
    left.modified == right.modified &&
    left.changed == right.changed;

String _hashCanonical(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_typedCanonical(value)))).toString();

Object? _typedCanonical(Object? value) {
  if (value == null) return const ['null'];
  if (value is bool) return ['bool', value];
  if (value is String) return ['string', value];
  if (value is int) return ['int', '$value'];
  if (value is double) {
    if (!value.isFinite) throw ArgumentError.value(value, 'value');
    return ['double', value.toString()];
  }
  if (value is Map) {
    final entries =
        <List<Object?>>[
          for (final entry in value.entries)
            <Object?>[_typedCanonical(entry.key), _typedCanonical(entry.value)],
        ]..sort(
          (left, right) =>
              jsonEncode(left.first).compareTo(jsonEncode(right.first)),
        );
    return ['map', entries];
  }
  if (value is Set) {
    final values = value.map(_typedCanonical).toList()
      ..sort((left, right) => jsonEncode(left).compareTo(jsonEncode(right)));
    return ['set', values];
  }
  if (value is Iterable) return ['list', value.map(_typedCanonical).toList()];
  if (value is Enum) {
    return ['enum', value.runtimeType.toString(), value.name];
  }
  throw ArgumentError.value(value, 'value');
}

final class _LiveEntryState {
  const _LiveEntryState.absent()
    : present = false,
      bytes = null,
      posixMode = null,
      size = null,
      modifiedMicros = null,
      changedMicros = null;

  const _LiveEntryState.present({
    required this.bytes,
    required this.posixMode,
    required this.size,
    required this.modifiedMicros,
    required this.changedMicros,
  }) : present = true;

  final bool present;
  final ImmutableBytes? bytes;
  final int? posixMode;
  final int? size;
  final int? modifiedMicros;
  final int? changedMicros;

  bool sameAuthority(_LiveEntryState other) =>
      present == other.present &&
      posixMode == other.posixMode &&
      size == other.size &&
      modifiedMicros == other.modifiedMicros &&
      changedMicros == other.changedMicros &&
      ((bytes == null && other.bytes == null) ||
          (bytes != null &&
              other.bytes != null &&
              bytes!.contentEquals(other.bytes!)));
}

List<L10nEvidenceFailure> _sortedFailures(
  Iterable<L10nEvidenceFailure> source,
) {
  final sorted = source.toList(growable: false)..sort(_compareFailures);
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
