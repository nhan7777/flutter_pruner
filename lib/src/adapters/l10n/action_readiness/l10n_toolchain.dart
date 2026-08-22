import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import '../../../core/process/managed_process_runner.dart';
import 'arb_document.dart';
import 'l10n_evidence_failure.dart';

const _environmentOverrides = <String, String>{
  'CI': 'true',
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  'LANG': 'en_US.UTF-8',
  'LC_ALL': 'en_US.UTF-8',
};
const _generationArgs = <String>['gen-l10n'];
const _directProbeArgs = <String>['--version', '--machine'];
const _delegatedProbeArgs = <String>['flutter', '--version', '--machine'];
const _probeTimeout = Duration(seconds: 30);
const _maxProbeOutputBytesPerStream = 1024 * 1024;
const _sha256Pattern = r'^[0-9a-f]{64}$';
const _resolutionStage = 'toolchain-resolution';
const _revalidationStage = 'toolchain-revalidation';

/// Immutable mapping from supported Flutter versions to provisioned binaries.
final class L10nSdkRegistry {
  /// Copies the caller-owned [canonicalFlutterByVersion] mapping.
  L10nSdkRegistry(Map<Version, String> canonicalFlutterByVersion)
    : _canonicalFlutterByVersion = Map<Version, String>.unmodifiable(
        Map<Version, String>.of(canonicalFlutterByVersion),
      );

  final Map<Version, String> _canonicalFlutterByVersion;

  /// Returns the registered Flutter executable for the exact [version].
  String? executableFor(Version version) => _canonicalFlutterByVersion[version];
}

/// Evidence source used to select an exact Flutter toolchain.
sealed class L10nToolchainSelection {
  /// Creates a toolchain selection.
  const L10nToolchainSelection();
}

/// Selects Flutter from supported FVM files in the original project root.
final class ProjectSelectorSelection extends L10nToolchainSelection {
  /// Creates project-selector evidence.
  const ProjectSelectorSelection();
}

/// Selects Flutter from a retained, externally reviewed evidence identity.
final class RetainedEvidenceSelection extends L10nToolchainSelection {
  /// Creates retained evidence for a toolchain with no synthetic selector.
  const RetainedEvidenceSelection({
    required this.expectedIdentity,
    required this.evidenceSha256,
    required this.probeOutputSha256,
  });

  /// Complete machine identity frozen by the retained evidence.
  final FlutterMachineIdentity expectedIdentity;

  /// SHA-256 of the retained source evidence.
  final String evidenceSha256;

  /// SHA-256 of the retained original selection probe output.
  final String probeOutputSha256;
}

/// Exact identity reported by `flutter --version --machine`.
final class FlutterMachineIdentity {
  /// Creates a complete Flutter machine identity.
  const FlutterMachineIdentity({
    required this.frameworkVersion,
    required this.frameworkRevision,
    required this.engineRevision,
    required this.dartSdkVersion,
  });

  /// Exact supported framework semantic version.
  final Version frameworkVersion;

  /// Exact framework revision.
  final String frameworkRevision;

  /// Exact engine revision.
  final String engineRevision;

  /// Exact bundled Dart SDK identity string.
  final String dartSdkVersion;
}

/// Result of resolving a canonical Flutter toolchain.
sealed class L10nToolchainResolution {
  /// Creates a resolution result.
  const L10nToolchainResolution();
}

/// Frozen canonical Flutter command and all selection evidence.
final class L10nToolchainResolved extends L10nToolchainResolution {
  /// Creates a frozen resolution and defensively copies its collections.
  L10nToolchainResolved({
    required this.canonicalFlutterExecutable,
    required this.canonicalSdkRoot,
    required this.selection,
    required List<String> generationArgs,
    required List<String> directProbeArgs,
    required Map<String, String> environmentOverrides,
    required Map<String, String> selectorHashesByRelativePath,
    required this.machineIdentity,
    required this.originalSelectionProbeSha256,
    required this.identitySha256,
  }) : generationArgs = List<String>.unmodifiable(generationArgs),
       directProbeArgs = List<String>.unmodifiable(directProbeArgs),
       environmentOverrides = _sortedUnmodifiableMap(environmentOverrides),
       selectorHashesByRelativePath = _sortedUnmodifiableMap(
         selectorHashesByRelativePath,
       );

  /// Canonical realpath of the directly invoked Flutter executable.
  final String canonicalFlutterExecutable;

  /// Canonical realpath of the executable's Flutter SDK root.
  final String canonicalSdkRoot;

  /// Evidence source that selected this toolchain.
  final L10nToolchainSelection selection;

  /// Arguments used for generation in later staging roots.
  final List<String> generationArgs;

  /// Arguments used to probe the canonical executable directly.
  final List<String> directProbeArgs;

  /// Sorted non-secret environment overrides used by every probe and run.
  final Map<String, String> environmentOverrides;

  /// Sorted SHA-256 fingerprints of every supported present selector.
  final Map<String, String> selectorHashesByRelativePath;

  /// Machine identity confirmed by every applicable probe.
  final FlutterMachineIdentity machineIdentity;

  /// Hash of delegated probe evidence or retained probe evidence.
  final String originalSelectionProbeSha256;

  /// Length/NUL-framed identity of paths, selection, probes, and overrides.
  final String identitySha256;
}

/// Resolution rejected with a stable structured failure.
final class L10nToolchainRejected extends L10nToolchainResolution {
  /// Creates a rejected toolchain resolution.
  const L10nToolchainRejected(this.failure);

  /// Stable failure identity.
  final L10nEvidenceFailure failure;
}

/// Result of checking a previously frozen toolchain again.
sealed class L10nToolchainRevalidationResult {
  /// Creates a revalidation result.
  const L10nToolchainRevalidationResult();
}

/// Confirms that every frozen toolchain identity component still matches.
final class L10nToolchainStillMatches extends L10nToolchainRevalidationResult {
  /// Creates a successful revalidation.
  const L10nToolchainStillMatches(this.identitySha256);

  /// Freshly recomputed identity, equal to the frozen identity.
  final String identitySha256;
}

/// Reports stable structured toolchain drift.
final class L10nToolchainChanged extends L10nToolchainRevalidationResult {
  /// Creates a changed result.
  const L10nToolchainChanged(this.failure);

  /// Stable drift identity.
  final L10nEvidenceFailure failure;
}

/// Resolves and later revalidates an exact Flutter toolchain.
abstract interface class L10nToolchainResolver {
  /// Resolves selection evidence to a provisioned canonical Flutter binary.
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  });

  /// Rechecks every identity component captured in [expected].
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  });
}

/// Default fail-closed toolchain resolver backed by a managed process runner.
final class DefaultL10nToolchainResolver implements L10nToolchainResolver {
  /// Creates a resolver using [processRunner] for argv-only machine probes.
  const DefaultL10nToolchainResolver({
    required ProcessExecutionRunner processRunner,
  }) : _processRunner = processRunner;

  final ProcessExecutionRunner _processRunner;

  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) async {
    if (Platform.isWindows) {
      return const L10nToolchainRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.unsupportedConfiguration,
          stage: _resolutionStage,
          detailCode: 'windows-command-model-unsupported',
        ),
      );
    }
    try {
      _requireSupportedParentFlutterToolArgs();
      final workingDirectory = _validatedProjectRoot(originalProjectRoot);
      final selected = switch (selection) {
        ProjectSelectorSelection() => _projectSelection(
          originalProjectRoot,
          sdkRegistry,
        ),
        RetainedEvidenceSelection() => _retainedSelection(
          selection,
          sdkRegistry,
        ),
      };
      final sdk = _canonicalSdkFor(selected.registeredExecutable);

      _ProbeEvidence? delegatedProbe;
      if (selection is ProjectSelectorSelection) {
        delegatedProbe = await _probe(
          executable: 'fvm',
          arguments: _delegatedProbeArgs,
          workingDirectory: workingDirectory,
          environmentOverrides: _environmentOverrides,
          role: 'selection-probe',
        );
        if (!_sameVersion(
          delegatedProbe.identity.frameworkVersion,
          selected.version,
        )) {
          throw const _ResolutionSignal(
            code: L10nEvidenceRejectionCode.toolchainUnavailable,
            detailCode: 'selection-probe-identity-mismatch',
          );
        }
        _requireSdkStillMatches(
          selected.registeredExecutable,
          sdk,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      }
      _requireLaunchControlsCompatible(sdk.launchManifest, switch (selection) {
        ProjectSelectorSelection() => delegatedProbe!.identity,
        RetainedEvidenceSelection() => selection.expectedIdentity,
      });

      final directProbe = await _probe(
        executable: sdk.executable,
        arguments: _directProbeArgs,
        workingDirectory: workingDirectory,
        environmentOverrides: _environmentOverrides,
        role: 'direct-probe',
      );
      if (!_sameVersion(
        directProbe.identity.frameworkVersion,
        selected.version,
      )) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-identity-mismatch',
        );
      }

      if (delegatedProbe != null &&
          !_sameIdentity(delegatedProbe.identity, directProbe.identity)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'probe-identity-mismatch',
        );
      }
      if (selection is RetainedEvidenceSelection &&
          !_sameIdentity(selection.expectedIdentity, directProbe.identity)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'retained-identity-mismatch',
        );
      }

      if (selection is ProjectSelectorSelection) {
        _requireSelectorsStillMatch(
          originalProjectRoot,
          version: selected.version,
          hashes: selected.selectorHashes,
          detailCode: 'selector-changed-during-probe',
        );
      }
      _requireSdkStillMatches(
        selected.registeredExecutable,
        sdk,
        detailCode: 'canonical-sdk-changed-during-probe',
      );

      final machineIdentity = directProbe.identity;
      _requireLaunchControlsCompatible(sdk.launchManifest, machineIdentity);
      final originalSelectionProbeSha256 = switch (selection) {
        ProjectSelectorSelection() => _probeEvidenceSha256(
          delegatedProbe!,
          _environmentOverrides,
        ),
        RetainedEvidenceSelection() => selection.probeOutputSha256,
      };
      final identitySha256 = _toolchainIdentitySha256(
        sdk: sdk,
        selection: selection,
        selectorHashes: selected.selectorHashes,
        selectedVersion: selected.version,
        machineIdentity: machineIdentity,
        originalSelectionProbeSha256: originalSelectionProbeSha256,
        delegatedProbe: delegatedProbe,
        directProbe: directProbe,
        generationArgs: _generationArgs,
        directProbeArgs: _directProbeArgs,
        environmentOverrides: _environmentOverrides,
      );

      return L10nToolchainResolved(
        canonicalFlutterExecutable: sdk.executable,
        canonicalSdkRoot: sdk.root,
        selection: selection,
        generationArgs: _generationArgs,
        directProbeArgs: _directProbeArgs,
        environmentOverrides: _environmentOverrides,
        selectorHashesByRelativePath: selected.selectorHashes,
        machineIdentity: machineIdentity,
        originalSelectionProbeSha256: originalSelectionProbeSha256,
        identitySha256: identitySha256,
      );
    } on _ResolutionSignal catch (signal) {
      return L10nToolchainRejected(signal.failure(_resolutionStage));
    } catch (_) {
      return const L10nToolchainRejected(
        L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.internalFailure,
          stage: _resolutionStage,
          detailCode: 'unexpected-resolution-failure',
        ),
      );
    }
  }

  @override
  Future<L10nToolchainRevalidationResult> revalidate({
    required Directory originalProjectRoot,
    required L10nToolchainResolved expected,
  }) async {
    if (Platform.isWindows) {
      return _changed('windows-command-model-unsupported');
    }
    try {
      _requireSupportedParentFlutterToolArgs();
    } on _ResolutionSignal catch (signal) {
      return _changed(signal.detailCode);
    }
    if (!_validFrozenCommands(expected)) {
      return _changed('frozen-command-drift');
    }
    try {
      final workingDirectory = _validatedProjectRoot(originalProjectRoot);
      final expectedVersion = expected.machineIdentity.frameworkVersion;
      if (!_isSupportedVersion(expectedVersion) ||
          !_isCompleteIdentity(expected.machineIdentity)) {
        return _changed('frozen-identity-invalid');
      }

      late final Map<String, String> selectorHashes;
      _ProbeEvidence? delegatedProbe;
      if (expected.selection is ProjectSelectorSelection) {
        final selector = _readProjectSelectors(originalProjectRoot);
        if (!_sameStringSet(
          selector.hashes.keys,
          expected.selectorHashesByRelativePath.keys,
        )) {
          return _changed('selector-set-drift');
        }
        for (final entry in selector.hashes.entries) {
          if (expected.selectorHashesByRelativePath[entry.key] != entry.value) {
            return _changed('selector-hash-drift', relativePath: entry.key);
          }
        }
        if (!_sameVersion(selector.version, expectedVersion)) {
          return _changed('selector-version-drift');
        }
        selectorHashes = selector.hashes;
      } else {
        if (expected.selectorHashesByRelativePath.isNotEmpty) {
          return _changed('retained-selector-drift');
        }
        final retained = expected.selection as RetainedEvidenceSelection;
        if (!_validSha256(retained.evidenceSha256) ||
            !_validSha256(retained.probeOutputSha256) ||
            !_sameIdentity(
              retained.expectedIdentity,
              expected.machineIdentity,
            )) {
          return _changed('retained-evidence-drift');
        }
        selectorHashes = const {};
      }

      late final _CanonicalSdk sdk;
      try {
        sdk = _canonicalSdkFor(expected.canonicalFlutterExecutable);
      } on _ResolutionSignal catch (signal) {
        return _changed(
          signal.detailCode == 'registry-executable-unavailable'
              ? 'canonical-executable-drift'
              : 'canonical-sdk-drift',
        );
      }
      if (sdk.executable != expected.canonicalFlutterExecutable) {
        return _changed('canonical-executable-drift');
      }
      if (sdk.root != expected.canonicalSdkRoot) {
        return _changed('canonical-sdk-drift');
      }
      _requireLaunchControlsCompatible(
        sdk.launchManifest,
        expected.machineIdentity,
      );

      if (expected.selection is ProjectSelectorSelection) {
        try {
          delegatedProbe = await _probe(
            executable: 'fvm',
            arguments: _delegatedProbeArgs,
            workingDirectory: workingDirectory,
            environmentOverrides: expected.environmentOverrides,
            role: 'selection-probe',
          );
        } on _ResolutionSignal catch (signal) {
          return _changed(signal.detailCode, relativePath: signal.relativePath);
        }
        if (!_sameIdentity(delegatedProbe.identity, expected.machineIdentity)) {
          return _changed('delegated-probe-drift');
        }
        _requireSdkStillMatches(
          expected.canonicalFlutterExecutable,
          sdk,
          detailCode: 'canonical-sdk-changed-during-probe',
        );
      }

      late final _ProbeEvidence directProbe;
      try {
        directProbe = await _probe(
          executable: sdk.executable,
          arguments: expected.directProbeArgs,
          workingDirectory: workingDirectory,
          environmentOverrides: expected.environmentOverrides,
          role: 'direct-probe',
        );
      } on _ResolutionSignal catch (signal) {
        return _changed(signal.detailCode, relativePath: signal.relativePath);
      }
      if (!_sameIdentity(directProbe.identity, expected.machineIdentity)) {
        return _changed('direct-probe-drift');
      }

      if (expected.selection is ProjectSelectorSelection) {
        _requireSelectorsStillMatch(
          originalProjectRoot,
          version: expectedVersion,
          hashes: selectorHashes,
          detailCode: 'selector-changed-during-probe',
        );
      }
      _requireSdkStillMatches(
        expected.canonicalFlutterExecutable,
        sdk,
        detailCode: 'canonical-sdk-changed-during-probe',
      );
      _requireLaunchControlsCompatible(
        sdk.launchManifest,
        expected.machineIdentity,
      );

      final originalSelectionProbeSha256 = switch (expected.selection) {
        ProjectSelectorSelection() => _probeEvidenceSha256(
          delegatedProbe!,
          expected.environmentOverrides,
        ),
        RetainedEvidenceSelection() => expected.originalSelectionProbeSha256,
      };
      final identitySha256 = _toolchainIdentitySha256(
        sdk: sdk,
        selection: expected.selection,
        selectorHashes: selectorHashes,
        selectedVersion: expectedVersion,
        machineIdentity: expected.machineIdentity,
        originalSelectionProbeSha256: originalSelectionProbeSha256,
        delegatedProbe: delegatedProbe,
        directProbe: directProbe,
        generationArgs: expected.generationArgs,
        directProbeArgs: expected.directProbeArgs,
        environmentOverrides: expected.environmentOverrides,
      );
      if (identitySha256 != expected.identitySha256 ||
          originalSelectionProbeSha256 !=
              expected.originalSelectionProbeSha256) {
        return _changed('identity-drift');
      }
      return L10nToolchainStillMatches(identitySha256);
    } on _ResolutionSignal catch (signal) {
      return _changed(signal.detailCode, relativePath: signal.relativePath);
    } catch (_) {
      return _changed('unexpected-revalidation-failure');
    }
  }

  _SelectedToolchain _projectSelection(
    Directory originalProjectRoot,
    L10nSdkRegistry sdkRegistry,
  ) {
    final selectors = _readProjectSelectors(originalProjectRoot);
    final executable = sdkRegistry.executableFor(selectors.version);
    if (executable == null) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-mapping-missing',
      );
    }
    return _SelectedToolchain(
      version: selectors.version,
      registeredExecutable: executable,
      selectorHashes: selectors.hashes,
    );
  }

  _SelectedToolchain _retainedSelection(
    RetainedEvidenceSelection selection,
    L10nSdkRegistry sdkRegistry,
  ) {
    if (!_validSha256(selection.evidenceSha256) ||
        !_validSha256(selection.probeOutputSha256) ||
        !_hasStructurallyCompleteIdentity(selection.expectedIdentity)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'retained-evidence-invalid',
      );
    }
    final version = selection.expectedIdentity.frameworkVersion;
    if (!_isSupportedVersion(version)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'unsupported-version',
      );
    }
    final executable = sdkRegistry.executableFor(version);
    if (executable == null) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-mapping-missing',
      );
    }
    return _SelectedToolchain(
      version: version,
      registeredExecutable: executable,
      selectorHashes: const {},
    );
  }

  Future<_ProbeEvidence> _probe({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environmentOverrides,
    required String role,
  }) async {
    late final ManagedProcessResult result;
    try {
      result = await _processRunner.run(
        executable,
        arguments,
        workingDirectory: workingDirectory,
        timeout: _probeTimeout,
        maxOutputBytesPerStream: _maxProbeOutputBytesPerStream,
        environmentOverrides: environmentOverrides,
        includeParentEnvironment: true,
      );
    } on ProcessTerminationUnconfirmedException {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-termination-unconfirmed',
      );
    } catch (_) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-unavailable',
      );
    }

    if (result.timedOut) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-timeout',
      );
    }
    if (result.outputTruncated) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-truncated',
      );
    }
    if (result.exitCode != 0) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-nonzero',
      );
    }

    final stdout = result.stdout.capturedPayload;
    final stderr = result.stderr.capturedPayload;
    late final FlutterMachineIdentity identity;
    try {
      identity = _parseMachineIdentity(stdout);
    } on FormatException {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-output-invalid',
      );
    }
    return _ProbeEvidence(
      executable: executable,
      arguments: arguments,
      stdout: stdout,
      stderr: stderr,
      identity: identity,
    );
  }
}

Uint8List? _readSelectorFileBytes(Directory projectRoot, String relativePath) {
  final rootPath = p.normalize(projectRoot.absolute.path);
  final components = p.split(relativePath);
  var current = rootPath;
  try {
    for (var index = 0; index < components.length - 1; index++) {
      current = p.join(current, components[index]);
      final type = FileSystemEntity.typeSync(current, followLinks: false);
      if (type == FileSystemEntityType.notFound) return null;
      if (type == FileSystemEntityType.link) {
        throw _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selector-path-symlink',
          relativePath: relativePath,
        );
      }
      if (type != FileSystemEntityType.directory) {
        throw _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'selector-not-regular',
          relativePath: relativePath,
        );
      }
    }

    final file = File(p.join(rootPath, relativePath));
    final type = FileSystemEntity.typeSync(file.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-not-regular',
        relativePath: relativePath,
      );
    }
    final canonicalRoot = p.normalize(
      Directory(rootPath).resolveSymbolicLinksSync(),
    );
    final canonicalFile = p.normalize(file.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalRoot, canonicalFile)) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-path-escape',
        relativePath: relativePath,
      );
    }
    return file.readAsBytesSync();
  } on _ResolutionSignal {
    rethrow;
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'selector-unreadable',
      relativePath: relativePath,
    );
  }
}

_ProjectSelectors _readProjectSelectors(Directory projectRoot) {
  const supportedSelectors = <(String, String)>[
    ('.fvm/fvm_config.json', 'flutterSdkVersion'),
    ('.fvmrc', 'flutter'),
  ];
  final bytesByPath = SplayTreeMap<String, Uint8List>();
  for (final selector in supportedSelectors) {
    final bytes = _readSelectorFileBytes(projectRoot, selector.$1);
    if (bytes != null) bytesByPath[selector.$1] = bytes;
  }
  if (bytesByPath.isEmpty) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'selector-missing',
    );
  }

  final versionByPath = SplayTreeMap<String, String>();
  for (final selector in supportedSelectors) {
    final bytes = bytesByPath[selector.$1];
    if (bytes == null) continue;
    final parsed = ArbDocument.parse(bytes);
    if (parsed is! ArbParseSuccess ||
        parsed.document.members.length != 1 ||
        parsed.document.members.single.decodedKey != selector.$2 ||
        parsed.document.members.single.decodedValue is! String) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-shape-unknown',
        relativePath: selector.$1,
      );
    }
    final rawVersion = parsed.document.members.single.decodedValue! as String;
    if (rawVersion.isEmpty || rawVersion != rawVersion.trim()) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'selector-shape-unknown',
        relativePath: selector.$1,
      );
    }
    versionByPath[selector.$1] = rawVersion;
  }

  final rawVersions = versionByPath.values.toSet();
  if (rawVersions.length != 1) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'selector-version-conflict',
    );
  }
  final rawVersion = rawVersions.single;
  final version = _supportedVersion(rawVersion);
  if (version == null) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.unsupportedConfiguration,
      detailCode: 'unsupported-version',
      relativePath: versionByPath.keys.first,
    );
  }
  final hashes = SplayTreeMap<String, String>();
  for (final entry in bytesByPath.entries) {
    hashes[entry.key] = sha256.convert(entry.value).toString();
  }
  return _ProjectSelectors(version: version, hashes: hashes);
}

void _requireSelectorsStillMatch(
  Directory projectRoot, {
  required Version version,
  required Map<String, String> hashes,
  required String detailCode,
}) {
  late final _ProjectSelectors current;
  try {
    current = _readProjectSelectors(projectRoot);
  } on _ResolutionSignal {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
  if (!_sameVersion(current.version, version) ||
      !_sameStringMap(current.hashes, hashes)) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

void _requireSdkStillMatches(
  String registeredExecutable,
  _CanonicalSdk expected, {
  required String detailCode,
}) {
  late final _CanonicalSdk current;
  try {
    current = _canonicalSdkFor(registeredExecutable);
  } on _ResolutionSignal {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
  if (current.executable != expected.executable ||
      current.root != expected.root ||
      !_samePosixLaunchManifest(
        current.launchManifest,
        expected.launchManifest,
      )) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

String _validatedProjectRoot(Directory originalProjectRoot) {
  final absolute = p.normalize(originalProjectRoot.absolute.path);
  if (FileSystemEntity.typeSync(absolute, followLinks: true) !=
      FileSystemEntityType.directory) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'project-root-unavailable',
    );
  }
  return absolute;
}

_CanonicalSdk _canonicalSdkFor(String registeredExecutable) {
  try {
    final requested = File(
      p.normalize(File(registeredExecutable).absolute.path),
    );
    if (FileSystemEntity.typeSync(requested.path, followLinks: true) !=
        FileSystemEntityType.file) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-executable-unavailable',
      );
    }
    final executable = p.normalize(requested.resolveSymbolicLinksSync());
    final executableFile = File(executable);
    final stat = executableFile.statSync();
    if (stat.type != FileSystemEntityType.file ||
        (!_isExecutable(stat) && !Platform.isWindows)) {
      throw const FormatException();
    }
    if (p.basename(executable) != _flutterExecutableName ||
        p.basename(p.dirname(executable)) != 'bin') {
      throw const FormatException();
    }
    final rootDirectory = Directory(p.dirname(p.dirname(executable)));
    if (FileSystemEntity.typeSync(rootDirectory.path, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    final root = p.normalize(rootDirectory.resolveSymbolicLinksSync());
    final expectedExecutable = File(
      p.join(root, 'bin', _flutterExecutableName),
    ).resolveSymbolicLinksSync();
    if (p.normalize(expectedExecutable) != executable) {
      throw const FormatException();
    }

    final launchManifest = _capturePosixLaunchManifest(root);
    final canonicalFlutter = launchManifest
        .entriesByRelativePath[p.join('bin', _flutterExecutableName)];
    if (canonicalFlutter == null ||
        canonicalFlutter.canonicalPath != executable) {
      throw const FormatException();
    }
    return _CanonicalSdk(
      executable: executable,
      root: root,
      launchManifest: launchManifest,
    );
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-executable-unavailable',
    );
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-structure-invalid',
    );
  }
}

_PosixLaunchManifest _capturePosixLaunchManifest(String root) {
  try {
    final entries = SplayTreeMap<String, _LaunchManifestEntry>();
    for (final spec in _fixedLaunchFileSpecs) {
      entries[spec.relativePath] = _captureLaunchFile(root, spec);
    }
    _captureInternalTree(root, 'bin/internal', entries);
    _requireStableInternalFiles(entries);

    final pubspec = File(p.join(root, _flutterToolsPubspecPath));
    final lock = File(p.join(root, _flutterToolsLockPath));
    final pubspecOlderThanLock = pubspec.lastModifiedSync().isBefore(
      lock.lastModifiedSync(),
    );
    if (!pubspecOlderThanLock) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-cache-freshness-invalid',
      );
    }
    final snapshotNonEmpty =
        _manifestFileEntry(entries, _flutterToolsSnapshotPath).byteLength! > 0;
    if (!snapshotNonEmpty) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-cache-state-invalid',
      );
    }
    final packageConfigNonEmpty =
        _manifestFileEntry(
          entries,
          _flutterToolsPackageConfigPath,
        ).byteLength! >
        0;
    if (!packageConfigNonEmpty) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-package-config-invalid',
      );
    }
    return _PosixLaunchManifest(
      entriesByRelativePath: entries,
      bootstrapHookAbsent: true,
      flutterToolsPubspecOlderThanLock: pubspecOlderThanLock,
      flutterToolsSnapshotNonEmpty: snapshotNonEmpty,
      flutterToolsPackageConfigNonEmpty: packageConfigNonEmpty,
    );
  } on _ResolutionSignal {
    rethrow;
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-artifact-unreadable',
    );
  }
}

void _captureInternalTree(
  String root,
  String relativeDirectory,
  SplayTreeMap<String, _LaunchManifestEntry> entries,
) {
  entries[relativeDirectory] = _captureLaunchDirectory(root, relativeDirectory);
  final children =
      Directory(p.join(root, relativeDirectory)).listSync(followLinks: false)
        ..sort(
          (left, right) => p
              .normalize(left.absolute.path)
              .compareTo(p.normalize(right.absolute.path)),
        );
  for (final child in children) {
    final childPath = p.normalize(File(child.path).absolute.path);
    if (!p.isWithin(root, childPath)) {
      throw const FormatException();
    }
    final relativePath = p.normalize(p.relative(childPath, from: root));
    if (p.isAbsolute(relativePath) || p.split(relativePath).contains('..')) {
      throw const FormatException();
    }
    if (relativePath == _bootstrapHookPath) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.unsupportedConfiguration,
        detailCode: 'registry-sdk-bootstrap-unsupported',
      );
    }
    final type = FileSystemEntity.typeSync(child.path, followLinks: false);
    if (type == FileSystemEntityType.file) {
      entries[relativePath] = _captureLaunchFile(
        root,
        _LaunchFileSpec(
          relativePath: relativePath,
          requiresExecutable: _requiredExecutableInternalFiles.contains(
            relativePath,
          ),
        ),
      );
    } else if (type == FileSystemEntityType.directory) {
      _captureInternalTree(root, relativePath, entries);
    } else {
      throw const FormatException();
    }
  }
}

_LaunchManifestEntry _captureLaunchDirectory(String root, String relativePath) {
  final path = _requireSafeLaunchPath(
    root,
    relativePath,
    FileSystemEntityType.directory,
  );
  final directory = Directory(path);
  final canonicalPath = p.normalize(directory.resolveSymbolicLinksSync());
  if (!p.isWithin(root, canonicalPath)) throw const FormatException();
  final stat = directory.statSync();
  if (stat.type != FileSystemEntityType.directory) {
    throw const FormatException();
  }
  return _LaunchManifestEntry(
    canonicalPath: canonicalPath,
    type: _LaunchManifestEntryType.directory,
    sha256: null,
    byteLength: null,
    requiresExecutable: false,
    executable: null,
    semanticContent: null,
  );
}

_LaunchManifestEntry _captureLaunchFile(String root, _LaunchFileSpec spec) {
  final path = _requireSafeLaunchPath(
    root,
    spec.relativePath,
    FileSystemEntityType.file,
  );
  final file = File(path);
  final canonicalPath = p.normalize(file.resolveSymbolicLinksSync());
  if (!p.isWithin(root, canonicalPath)) throw const FormatException();
  final before = file.statSync();
  final executable = _isExecutable(before);
  if (before.type != FileSystemEntityType.file ||
      (spec.requiresExecutable && !executable)) {
    throw const FormatException();
  }

  final bytes = file.readAsBytesSync();
  final after = file.statSync();
  final canonicalPathAfterRead = p.normalize(file.resolveSymbolicLinksSync());
  if (!_sameArtifactFileState(before, after) ||
      canonicalPathAfterRead != canonicalPath) {
    throw const FormatException();
  }
  return _LaunchManifestEntry(
    canonicalPath: canonicalPath,
    type: _LaunchManifestEntryType.regularFile,
    sha256: sha256.convert(bytes).toString(),
    byteLength: bytes.length,
    requiresExecutable: spec.requiresExecutable,
    executable: executable,
    semanticContent: _semanticControlContentPaths.contains(spec.relativePath)
        ? bytes
        : null,
  );
}

_LaunchManifestEntry _manifestFileEntry(
  Map<String, _LaunchManifestEntry> entries,
  String relativePath,
) {
  final entry = entries[relativePath];
  if (entry == null || entry.type != _LaunchManifestEntryType.regularFile) {
    throw const FormatException();
  }
  return entry;
}

List<int> _manifestFileContent(
  Map<String, _LaunchManifestEntry> entries,
  String relativePath,
) {
  final content = _manifestFileEntry(entries, relativePath).semanticContent;
  if (content == null) throw const FormatException();
  return content;
}

void _requireSupportedParentFlutterToolArgs() {
  final inherited = Platform.environment['FLUTTER_TOOL_ARGS'];
  if (inherited != null && inherited.isNotEmpty) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.unsupportedConfiguration,
      detailCode: 'parent-flutter-tool-args-unsupported',
    );
  }
}

void _requireLaunchControlsCompatible(
  _PosixLaunchManifest manifest,
  FlutterMachineIdentity machineIdentity,
) {
  final engineStamp = _trimmedManifestText(
    manifest,
    _engineStampPath,
    detailCode: 'registry-sdk-engine-identity-mismatch',
  );
  final engineVersion = _trimmedManifestText(
    manifest,
    _engineVersionPath,
    detailCode: 'registry-sdk-engine-identity-mismatch',
  );
  if (engineStamp.isEmpty ||
      engineStamp != machineIdentity.engineRevision ||
      engineVersion != machineIdentity.engineRevision) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-engine-identity-mismatch',
    );
  }

  final dartStamp = _trimmedManifestText(
    manifest,
    _engineDartSdkStampPath,
    detailCode: 'registry-sdk-dart-stamp-mismatch',
  );
  if (dartStamp != engineStamp) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-dart-stamp-mismatch',
    );
  }

  final engineRealm = _trimmedManifestText(
    manifest,
    _engineRealmPath,
    detailCode: 'registry-sdk-engine-realm-unsupported',
  );
  if (engineRealm.isNotEmpty) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.unsupportedConfiguration,
      detailCode: 'registry-sdk-engine-realm-unsupported',
    );
  }

  final flutterToolsStamp = _shellCommandSubstitutionText(
    manifest,
    _flutterToolsStampPath,
    detailCode: 'registry-sdk-flutter-tools-stamp-incompatible',
  );
  if (flutterToolsStamp != '${machineIdentity.frameworkRevision}:') {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-flutter-tools-stamp-incompatible',
    );
  }
}

String _trimmedManifestText(
  _PosixLaunchManifest manifest,
  String relativePath, {
  required String detailCode,
}) {
  try {
    return utf8
        .decode(
          _manifestFileContent(manifest.entriesByRelativePath, relativePath),
        )
        .trim();
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

String _shellCommandSubstitutionText(
  _PosixLaunchManifest manifest,
  String relativePath, {
  required String detailCode,
}) {
  final bytes = _manifestFileContent(
    manifest.entriesByRelativePath,
    relativePath,
  );
  var end = bytes.length;
  while (end > 0 && bytes[end - 1] == 0x0a) {
    end--;
  }
  try {
    return utf8.decode(bytes.sublist(0, end));
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

String _requireSafeLaunchPath(
  String root,
  String relativePath,
  FileSystemEntityType finalType,
) {
  final components = p.split(relativePath);
  var current = root;
  for (var index = 0; index < components.length; index++) {
    current = p.join(current, components[index]);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    final expectedType = index == components.length - 1
        ? finalType
        : FileSystemEntityType.directory;
    if (type != expectedType) throw const FormatException();
  }
  return current;
}

void _requireStableInternalFiles(Map<String, _LaunchManifestEntry> entries) {
  for (final relativePath in _requiredStableInternalFiles) {
    final entry = entries[relativePath];
    if (entry == null || entry.type != _LaunchManifestEntryType.regularFile) {
      throw const FormatException();
    }
  }
}

List<_LaunchFileSpec> get _fixedLaunchFileSpecs => [
  _LaunchFileSpec(
    relativePath: p.join('bin', _flutterExecutableName),
    requiresExecutable: true,
  ),
  _LaunchFileSpec(
    relativePath: p.join('bin', _dartLauncherName),
    requiresExecutable: true,
  ),
  _LaunchFileSpec(
    relativePath: p.join('bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
    requiresExecutable: true,
  ),
  _LaunchFileSpec(
    relativePath: p.join('bin', 'cache', 'flutter_tools.snapshot'),
    requiresExecutable: false,
  ),
  for (final relativePath in _controlInputPaths)
    _LaunchFileSpec(relativePath: relativePath, requiresExecutable: false),
];

const _bootstrapHookPath = 'bin/internal/bootstrap.sh';
const _flutterToolsPubspecPath = 'packages/flutter_tools/pubspec.yaml';
const _flutterToolsLockPath = 'packages/flutter_tools/pubspec.lock';
const _flutterToolsPackageConfigPath =
    'packages/flutter_tools/.dart_tool/package_config.json';
const _flutterToolsSnapshotPath = 'bin/cache/flutter_tools.snapshot';
const _flutterToolsStampPath = 'bin/cache/flutter_tools.stamp';
const _engineStampPath = 'bin/cache/engine.stamp';
const _engineRealmPath = 'bin/cache/engine.realm';
const _engineDartSdkStampPath = 'bin/cache/engine-dart-sdk.stamp';
const _engineVersionPath = 'bin/internal/engine.version';
const _semanticControlContentPaths = <String>{
  _flutterToolsStampPath,
  _engineStampPath,
  _engineRealmPath,
  _engineDartSdkStampPath,
  _engineVersionPath,
};
const _requiredStableInternalFiles = <String>{
  'bin/internal/shared.sh',
  'bin/internal/update_engine_version.sh',
  'bin/internal/update_dart_sdk.sh',
  'bin/internal/content_aware_hash.sh',
  'bin/internal/engine.version',
};
const _requiredExecutableInternalFiles = <String>{
  'bin/internal/update_engine_version.sh',
  'bin/internal/update_dart_sdk.sh',
  'bin/internal/content_aware_hash.sh',
};
const _controlInputPaths = <String>[
  _flutterToolsStampPath,
  _engineStampPath,
  _engineRealmPath,
  _engineDartSdkStampPath,
  _flutterToolsPubspecPath,
  _flutterToolsLockPath,
  _flutterToolsPackageConfigPath,
];

bool _sameArtifactFileState(FileStat left, FileStat right) =>
    left.type == right.type &&
    left.mode == right.mode &&
    left.size == right.size &&
    left.modified == right.modified &&
    left.changed == right.changed;

bool _isExecutable(FileStat stat) => stat.mode & 0x49 != 0;

String get _flutterExecutableName =>
    Platform.isWindows ? 'flutter.bat' : 'flutter';

String get _dartLauncherName => Platform.isWindows ? 'dart.bat' : 'dart';

String get _bundledDartName => Platform.isWindows ? 'dart.exe' : 'dart';

FlutterMachineIdentity _parseMachineIdentity(List<int> bytes) {
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) throw const FormatException();
  final rawVersion = _requiredIdentityString(decoded, 'frameworkVersion');
  final version = _supportedVersion(rawVersion);
  if (version == null) throw const FormatException();
  return FlutterMachineIdentity(
    frameworkVersion: version,
    frameworkRevision: _requiredIdentityString(decoded, 'frameworkRevision'),
    engineRevision: _requiredIdentityString(decoded, 'engineRevision'),
    dartSdkVersion: _requiredIdentityString(decoded, 'dartSdkVersion'),
  );
}

String _requiredIdentityString(Map<String, dynamic> machine, String key) {
  final value = machine[key];
  if (value is! String || value.isEmpty || value != value.trim()) {
    throw const FormatException();
  }
  return value;
}

Version? _supportedVersion(String value) => switch (value) {
  '3.38.7' => Version(3, 38, 7),
  '3.41.5' => Version(3, 41, 5),
  '3.44.1' => Version(3, 44, 1),
  _ => null,
};

bool _isSupportedVersion(Version version) {
  final supported = _supportedVersion(version.toString());
  return supported != null && _sameVersion(version, supported);
}

bool _isCompleteIdentity(FlutterMachineIdentity identity) =>
    _isSupportedVersion(identity.frameworkVersion) &&
    _hasStructurallyCompleteIdentity(identity);

bool _hasStructurallyCompleteIdentity(FlutterMachineIdentity identity) =>
    _validIdentityString(identity.frameworkRevision) &&
    _validIdentityString(identity.engineRevision) &&
    _validIdentityString(identity.dartSdkVersion);

bool _validIdentityString(String value) =>
    value.isNotEmpty && value == value.trim();

bool _sameIdentity(FlutterMachineIdentity left, FlutterMachineIdentity right) =>
    _sameVersion(left.frameworkVersion, right.frameworkVersion) &&
    left.frameworkRevision == right.frameworkRevision &&
    left.engineRevision == right.engineRevision &&
    left.dartSdkVersion == right.dartSdkVersion;

bool _sameVersion(Version left, Version right) => left == right;

bool _validSha256(String value) => RegExp(_sha256Pattern).hasMatch(value);

bool _validFrozenCommands(L10nToolchainResolved expected) =>
    _sameStringList(expected.generationArgs, _generationArgs) &&
    _sameStringList(expected.directProbeArgs, _directProbeArgs) &&
    _sameStringMap(expected.environmentOverrides, _environmentOverrides) &&
    !expected.environmentOverrides.containsKey('HOME') &&
    !expected.environmentOverrides.containsKey('PUB_CACHE');

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameStringMap(Map<String, String> left, Map<String, String> right) {
  if (left.length != right.length) return false;
  for (final entry in left.entries) {
    if (right[entry.key] != entry.value) return false;
  }
  return true;
}

bool _sameStringSet(Iterable<String> left, Iterable<String> right) {
  final leftSet = left.toSet();
  final rightSet = right.toSet();
  return leftSet.length == rightSet.length && leftSet.containsAll(rightSet);
}

Map<String, String> _sortedUnmodifiableMap(Map<String, String> source) =>
    Map<String, String>.unmodifiable(SplayTreeMap<String, String>.of(source));

String _probeEvidenceSha256(
  _ProbeEvidence probe,
  Map<String, String> environmentOverrides,
) {
  final hasher = _FramedIdentityHasher();
  hasher.addText('schema', 'l10n-selection-probe-v1');
  _addProbe(hasher, 'selection', probe);
  _addOverrides(hasher, environmentOverrides);
  return hasher.digest();
}

String _toolchainIdentitySha256({
  required _CanonicalSdk sdk,
  required L10nToolchainSelection selection,
  required Map<String, String> selectorHashes,
  required Version selectedVersion,
  required FlutterMachineIdentity machineIdentity,
  required String originalSelectionProbeSha256,
  required _ProbeEvidence? delegatedProbe,
  required _ProbeEvidence directProbe,
  required List<String> generationArgs,
  required List<String> directProbeArgs,
  required Map<String, String> environmentOverrides,
}) {
  final hasher = _FramedIdentityHasher();
  hasher.addText('schema', 'l10n-toolchain-v1');
  hasher.addText('canonicalFlutterExecutable', sdk.executable);
  hasher.addText('canonicalSdkRoot', sdk.root);
  hasher.addText(
    'launchManifestEntryCount',
    sdk.launchManifest.entriesByRelativePath.length.toString(),
  );
  hasher.addText(
    'launchManifest.bootstrapHookAbsent',
    sdk.launchManifest.bootstrapHookAbsent.toString(),
  );
  hasher.addText(
    'launchManifest.flutterToolsPubspecOlderThanLock',
    sdk.launchManifest.flutterToolsPubspecOlderThanLock.toString(),
  );
  hasher.addText(
    'launchManifest.flutterToolsSnapshotNonEmpty',
    sdk.launchManifest.flutterToolsSnapshotNonEmpty.toString(),
  );
  hasher.addText(
    'launchManifest.flutterToolsPackageConfigNonEmpty',
    sdk.launchManifest.flutterToolsPackageConfigNonEmpty.toString(),
  );
  for (final entry in sdk.launchManifest.entriesByRelativePath.entries) {
    hasher.addText('launchManifest.relativePath', entry.key);
    hasher.addText('launchManifest.canonicalPath', entry.value.canonicalPath);
    hasher.addText('launchManifest.entryType', entry.value.type.name);
    hasher.addText(
      'launchManifest.sha256',
      entry.value.sha256 ?? 'not-applicable',
    );
    hasher.addText(
      'launchManifest.byteLength',
      entry.value.byteLength?.toString() ?? 'not-applicable',
    );
    hasher.addText(
      'launchManifest.requiresExecutable',
      entry.value.requiresExecutable.toString(),
    );
    hasher.addText(
      'launchManifest.executable',
      entry.value.executable?.toString() ?? 'not-applicable',
    );
  }
  for (final entry in SplayTreeMap<String, String>.of(selectorHashes).entries) {
    hasher.addText('selectorPath', entry.key);
    hasher.addText('selectorSha256', entry.value);
  }
  hasher.addText('selectedVersion', selectedVersion.toString());
  switch (selection) {
    case ProjectSelectorSelection():
      hasher.addText('selectionKind', 'project-selector');
    case RetainedEvidenceSelection():
      hasher.addText('selectionKind', 'retained-evidence');
      hasher.addText('retainedEvidenceSha256', selection.evidenceSha256);
      hasher.addText('retainedProbeOutputSha256', selection.probeOutputSha256);
      _addMachineIdentity(
        hasher,
        'retainedExpectedIdentity',
        selection.expectedIdentity,
      );
  }
  hasher.addText('originalSelectionProbeSha256', originalSelectionProbeSha256);
  if (delegatedProbe != null) {
    _addProbe(hasher, 'delegatedProbe', delegatedProbe);
  }
  _addProbe(hasher, 'directProbe', directProbe);
  for (final argument in generationArgs) {
    hasher.addText('generationArg', argument);
  }
  for (final argument in directProbeArgs) {
    hasher.addText('directProbeArg', argument);
  }
  _addOverrides(hasher, environmentOverrides);
  _addMachineIdentity(hasher, 'machineIdentity', machineIdentity);
  return hasher.digest();
}

void _addProbe(
  _FramedIdentityHasher hasher,
  String prefix,
  _ProbeEvidence probe,
) {
  hasher.addText('$prefix.executable', probe.executable);
  hasher.addText('$prefix.argumentCount', probe.arguments.length.toString());
  for (final argument in probe.arguments) {
    hasher.addText('$prefix.argument', argument);
  }
  hasher.addBytes('$prefix.stdout', probe.stdout);
  hasher.addBytes('$prefix.stderr', probe.stderr);
}

void _addOverrides(
  _FramedIdentityHasher hasher,
  Map<String, String> environmentOverrides,
) {
  for (final entry in SplayTreeMap<String, String>.of(
    environmentOverrides,
  ).entries) {
    hasher.addText('environmentOverrideKey', entry.key);
    hasher.addText('environmentOverrideValue', entry.value);
  }
  hasher.addText('includeParentEnvironment', 'true');
}

void _addMachineIdentity(
  _FramedIdentityHasher hasher,
  String prefix,
  FlutterMachineIdentity identity,
) {
  hasher.addText(
    '$prefix.frameworkVersion',
    identity.frameworkVersion.toString(),
  );
  hasher.addText('$prefix.frameworkRevision', identity.frameworkRevision);
  hasher.addText('$prefix.engineRevision', identity.engineRevision);
  hasher.addText('$prefix.dartSdkVersion', identity.dartSdkVersion);
}

L10nToolchainChanged _changed(String detailCode, {String? relativePath}) =>
    L10nToolchainChanged(
      L10nEvidenceFailure(
        code: L10nEvidenceRejectionCode.toolchainDrift,
        stage: _revalidationStage,
        detailCode: detailCode,
        relativePath: relativePath,
      ),
    );

final class _FramedIdentityHasher {
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  void addText(String label, String value) {
    addBytes(label, utf8.encode(value));
  }

  void addBytes(String label, List<int> value) {
    _addFrame(utf8.encode(label));
    _addFrame(value);
  }

  void _addFrame(List<int> value) {
    _bytes.add(ascii.encode(value.length.toString()));
    _bytes.addByte(0);
    _bytes.add(value);
    _bytes.addByte(0);
  }

  String digest() => sha256.convert(_bytes.takeBytes()).toString();
}

final class _ProjectSelectors {
  _ProjectSelectors({
    required this.version,
    required Map<String, String> hashes,
  }) : hashes = _sortedUnmodifiableMap(hashes);

  final Version version;
  final Map<String, String> hashes;
}

final class _SelectedToolchain {
  _SelectedToolchain({
    required this.version,
    required this.registeredExecutable,
    required Map<String, String> selectorHashes,
  }) : selectorHashes = _sortedUnmodifiableMap(selectorHashes);

  final Version version;
  final String registeredExecutable;
  final Map<String, String> selectorHashes;
}

final class _CanonicalSdk {
  _CanonicalSdk({
    required this.executable,
    required this.root,
    required this.launchManifest,
  });

  final String executable;
  final String root;
  final _PosixLaunchManifest launchManifest;
}

final class _PosixLaunchManifest {
  _PosixLaunchManifest({
    required Map<String, _LaunchManifestEntry> entriesByRelativePath,
    required this.bootstrapHookAbsent,
    required this.flutterToolsPubspecOlderThanLock,
    required this.flutterToolsSnapshotNonEmpty,
    required this.flutterToolsPackageConfigNonEmpty,
  }) : entriesByRelativePath = Map<String, _LaunchManifestEntry>.unmodifiable(
         SplayTreeMap<String, _LaunchManifestEntry>.of(entriesByRelativePath),
       );

  final Map<String, _LaunchManifestEntry> entriesByRelativePath;
  final bool bootstrapHookAbsent;
  final bool flutterToolsPubspecOlderThanLock;
  final bool flutterToolsSnapshotNonEmpty;
  final bool flutterToolsPackageConfigNonEmpty;
}

final class _LaunchFileSpec {
  const _LaunchFileSpec({
    required this.relativePath,
    required this.requiresExecutable,
  });

  final String relativePath;
  final bool requiresExecutable;
}

enum _LaunchManifestEntryType { directory, regularFile }

final class _LaunchManifestEntry {
  _LaunchManifestEntry({
    required this.canonicalPath,
    required this.type,
    required this.sha256,
    required this.byteLength,
    required this.requiresExecutable,
    required this.executable,
    required List<int>? semanticContent,
  }) : semanticContent = semanticContent == null
           ? null
           : List<int>.unmodifiable(semanticContent);

  final String canonicalPath;
  final _LaunchManifestEntryType type;
  final String? sha256;
  final int? byteLength;
  final bool requiresExecutable;
  final bool? executable;
  final List<int>? semanticContent;
}

bool _samePosixLaunchManifest(
  _PosixLaunchManifest left,
  _PosixLaunchManifest right,
) {
  if (left.bootstrapHookAbsent != right.bootstrapHookAbsent ||
      left.flutterToolsPubspecOlderThanLock !=
          right.flutterToolsPubspecOlderThanLock ||
      left.flutterToolsSnapshotNonEmpty != right.flutterToolsSnapshotNonEmpty ||
      left.flutterToolsPackageConfigNonEmpty !=
          right.flutterToolsPackageConfigNonEmpty ||
      left.entriesByRelativePath.length != right.entriesByRelativePath.length) {
    return false;
  }
  for (final entry in left.entriesByRelativePath.entries) {
    final other = right.entriesByRelativePath[entry.key];
    if (other == null ||
        entry.value.canonicalPath != other.canonicalPath ||
        entry.value.type != other.type ||
        entry.value.sha256 != other.sha256 ||
        entry.value.byteLength != other.byteLength ||
        entry.value.requiresExecutable != other.requiresExecutable ||
        entry.value.executable != other.executable) {
      return false;
    }
  }
  return true;
}

final class _ProbeEvidence {
  _ProbeEvidence({
    required this.executable,
    required List<String> arguments,
    required List<int> stdout,
    required List<int> stderr,
    required this.identity,
  }) : arguments = List<String>.unmodifiable(arguments),
       stdout = Uint8List.fromList(stdout),
       stderr = Uint8List.fromList(stderr);

  final String executable;
  final List<String> arguments;
  final Uint8List stdout;
  final Uint8List stderr;
  final FlutterMachineIdentity identity;
}

final class _ResolutionSignal implements Exception {
  const _ResolutionSignal({
    required this.code,
    required this.detailCode,
    this.relativePath,
  });

  final L10nEvidenceRejectionCode code;
  final String detailCode;
  final String? relativePath;

  L10nEvidenceFailure failure(String stage) => L10nEvidenceFailure(
    code: code,
    stage: stage,
    detailCode: detailCode,
    relativePath: relativePath,
  );
}
