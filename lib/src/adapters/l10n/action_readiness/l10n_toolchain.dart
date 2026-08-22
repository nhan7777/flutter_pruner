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

const _baseEnvironmentOverrides = <String, String>{
  'CI': 'true',
  'FLUTTER_SUPPRESS_ANALYTICS': 'true',
  'LANG': 'en_US.UTF-8',
  'LC_ALL': 'en_US.UTF-8',
};
const _generationArgs = <String>['gen-l10n'];
const _directProbeArgs = <String>['--version', '--machine'];
const _sandboxWhichBytes = <int>[
  0x23,
  0x21,
  0x2f,
  0x62,
  0x69,
  0x6e,
  0x2f,
  0x73,
  0x68,
  0x0a,
  0x65,
  0x78,
  0x69,
  0x74,
  0x20,
  0x31,
  0x0a,
];
const _sandboxEnvironmentPolicyVersion = 'l10n-probe-sandbox-v1';
const _sandboxDirectoryRoles = <String, String>{
  'HOME': 'home',
  'XDG_CONFIG_HOME': 'xdg-config',
  'PUB_CACHE': 'pub-cache',
  'TMPDIR': 'tmp',
  'PATH': 'bin',
};
const _probeTimeout = Duration(seconds: 30);
const _maxProbeOutputBytesPerStream = 1024 * 1024;
const _sha256Pattern = r'^[0-9a-f]{64}$';
const _gitObjectIdPattern = r'^[0-9a-f]{40}$';
const _maxGitSymbolicRefDepth = 16;
const _maxGitHeadOrLooseRefBytes = 4096;
const _maxGitConfigBytes = 1024 * 1024;
const _maxGitPackedRefsBytes = 16 * 1024 * 1024;
const _resolutionStage = 'toolchain-resolution';
const _revalidationStage = 'toolchain-revalidation';

/// Immutable mapping from supported Flutter versions to provisioned SDK roots.
final class L10nSdkRegistry {
  /// Copies the caller-owned [canonicalFlutterByVersion] mapping.
  L10nSdkRegistry(Map<Version, String> canonicalFlutterByVersion)
    : _canonicalFlutterByVersion = Map<Version, String>.unmodifiable(
        Map<Version, String>.of(canonicalFlutterByVersion),
      );

  final Map<Version, String> _canonicalFlutterByVersion;

  /// Returns the registered SDK's Flutter entrypoint for provenance only.
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

/// Exact identity reported by the bound Flutter-tools machine snapshot.
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

/// Frozen direct Dart launcher for the bound Flutter-tools snapshot.
final class L10nToolchainLaunch {
  /// Creates unbound physical fields for immutable result reconstruction.
  ///
  /// Only a launch returned by [L10nToolchainResolver.resolve] carries the
  /// private frozen authority required by [runGeneration].
  const L10nToolchainLaunch({
    required this.canonicalDartExecutable,
    required this.canonicalFlutterToolsPackageConfig,
    required this.canonicalFlutterToolsSnapshot,
  }) : _frozenSdk = null;

  L10nToolchainLaunch._bound({
    required this.canonicalDartExecutable,
    required this.canonicalFlutterToolsPackageConfig,
    required this.canonicalFlutterToolsSnapshot,
    required _CanonicalSdk frozenSdk,
  }) : _frozenSdk = frozenSdk;

  /// Canonical bundled Dart executable invoked for every toolchain process.
  final String canonicalDartExecutable;

  /// Canonical Flutter-tools package configuration passed to Dart.
  final String canonicalFlutterToolsPackageConfig;

  /// Canonical Flutter-tools snapshot passed to Dart.
  final String canonicalFlutterToolsSnapshot;

  final _CanonicalSdk? _frozenSdk;

  List<String> _physicalArgumentsFor(Iterable<String> logicalArguments) =>
      List<String>.unmodifiable([
        '--packages=$canonicalFlutterToolsPackageConfig',
        canonicalFlutterToolsSnapshot,
        ...List<String>.of(logicalArguments),
      ]);

  /// Runs generation through the same isolated, revalidated snapshot seam.
  Future<ManagedProcessResult> runGeneration({
    required ProcessExecutionRunner processRunner,
    required Directory workingDirectory,
    required L10nToolchainResolved expected,
    required List<String> logicalArguments,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    try {
      if (timeout <= Duration.zero || maxOutputBytesPerStream < 0) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'generation-run-policy-invalid',
        );
      }
      final frozenLogicalArguments = List<String>.unmodifiable(
        logicalArguments,
      );
      if (!_validFrozenCommands(expected) ||
          !_sameLaunch(this, expected.launch) ||
          !_sameStringList(frozenLogicalArguments, expected.generationArgs)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'frozen-command-drift',
        );
      }
      final canonicalWorkingDirectory = _validatedProjectRoot(workingDirectory);
      final sdk = _canonicalSdkFor(expected.canonicalFlutterExecutable);
      if (sdk.root != expected.canonicalSdkRoot ||
          !_sameLaunch(sdk.launch, this) ||
          !_sameStringMap(
            expected.environmentOverrides,
            _frozenEnvironmentOverrides(sdk.root),
          ) ||
          !_sameIdentity(
            _validatedSdkMachineIdentity(
              sdk,
              expected.machineIdentity.frameworkVersion,
            ),
            expected.machineIdentity,
          )) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'generation-toolchain-drift',
        );
      }
      _requireSdkStillMatches(
        expected.canonicalFlutterExecutable,
        sdk,
        detailCode: 'generation-toolchain-drift',
      );
      final result = await _runSnapshotProcess(
        processRunner: processRunner,
        launch: this,
        logicalArguments: frozenLogicalArguments,
        workingDirectory: canonicalWorkingDirectory,
        environmentOverrides: expected.environmentOverrides,
        sdk: sdk,
        role: 'generation-run',
        sdkDriftDetailCode: 'generation-toolchain-drift',
        timeout: timeout,
        maxOutputBytesPerStream: maxOutputBytesPerStream,
      );
      _requireSdkStillMatches(
        expected.canonicalFlutterExecutable,
        sdk,
        detailCode: 'generation-toolchain-drift',
      );
      return result;
    } on _ResolutionSignal catch (signal) {
      throw L10nToolchainLaunchException(signal.detailCode);
    } catch (_) {
      throw const L10nToolchainLaunchException(
        'generation-run-unexpected-failure',
      );
    }
  }
}

/// Stable fail-closed launch error for later staging generation.
final class L10nToolchainLaunchException implements Exception {
  /// Creates a launch rejection with a stable [detailCode].
  const L10nToolchainLaunchException(this.detailCode);

  /// Machine-readable launch rejection detail.
  final String detailCode;
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
    required this.launch,
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

  /// Canonical Flutter entrypoint used only to prove SDK registry provenance.
  final String canonicalFlutterExecutable;

  /// Canonical realpath of the executable's Flutter SDK root.
  final String canonicalSdkRoot;

  /// Honest physical bundled-Dart/snapshot launch authority.
  final L10nToolchainLaunch launch;

  /// Evidence source that selected this toolchain.
  final L10nToolchainSelection selection;

  /// Arguments used for generation in later staging roots.
  final List<String> generationArgs;

  /// Logical arguments used for the direct machine probe.
  final List<String> directProbeArgs;

  /// Frozen non-secret values extended by fresh sandbox paths per invocation.
  final Map<String, String> environmentOverrides;

  /// Sorted SHA-256 fingerprints of every supported present selector.
  final Map<String, String> selectorHashesByRelativePath;

  /// Machine identity confirmed by every applicable probe.
  final FlutterMachineIdentity machineIdentity;

  /// Hash of project-selection evidence or retained probe evidence.
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
  /// Resolves selection evidence to a provisioned canonical Flutter SDK.
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
      final environmentOverrides = _frozenEnvironmentOverrides(sdk.root);
      final controlIdentity = _validatedSdkMachineIdentity(
        sdk,
        selected.version,
      );
      if (selection is RetainedEvidenceSelection &&
          !_sameIdentity(selection.expectedIdentity, controlIdentity)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'retained-identity-mismatch',
        );
      }
      _requireSdkStillMatches(
        selected.registeredExecutable,
        sdk,
        detailCode: 'canonical-sdk-changed-during-probe',
      );

      final directProbe = await _probe(
        launch: sdk.launch,
        logicalArguments: _directProbeArgs,
        workingDirectory: workingDirectory,
        environmentOverrides: environmentOverrides,
        sdk: sdk,
        role: 'direct-probe',
      );
      if (!_sameIdentity(directProbe.identity, controlIdentity)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'direct-probe-identity-mismatch',
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
      final originalSelectionProbeSha256 = switch (selection) {
        ProjectSelectorSelection() => _projectSelectionEvidenceSha256(
          sdk: sdk,
          selectedVersion: selected.version,
          selectorHashes: selected.selectorHashes,
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
        directProbe: directProbe,
        generationArgs: _generationArgs,
        directProbeArgs: _directProbeArgs,
        environmentOverrides: environmentOverrides,
      );

      return L10nToolchainResolved(
        canonicalFlutterExecutable: sdk.executable,
        canonicalSdkRoot: sdk.root,
        launch: sdk.launch,
        selection: selection,
        generationArgs: _generationArgs,
        directProbeArgs: _directProbeArgs,
        environmentOverrides: environmentOverrides,
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
        if (_isGitIdentityDetail(signal.detailCode)) {
          return _changed(signal.detailCode, relativePath: signal.relativePath);
        }
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
      if (expected.launch._frozenSdk == null ||
          !_sameLaunchPaths(sdk.launch, expected.launch)) {
        return _changed('frozen-launch-drift');
      }
      final controlIdentity = _validatedSdkMachineIdentity(
        sdk,
        expectedVersion,
      );
      if (!_sameIdentity(controlIdentity, expected.machineIdentity)) {
        return _changed('registry-sdk-machine-control-drift');
      }
      if (!_sameLaunch(sdk.launch, expected.launch)) {
        return _changed('identity-drift');
      }
      _requireSdkStillMatches(
        expected.canonicalFlutterExecutable,
        sdk,
        detailCode: 'canonical-sdk-changed-during-probe',
      );

      late final _ProbeEvidence directProbe;
      try {
        directProbe = await _probe(
          launch: expected.launch,
          logicalArguments: expected.directProbeArgs,
          workingDirectory: workingDirectory,
          environmentOverrides: expected.environmentOverrides,
          sdk: sdk,
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

      final originalSelectionProbeSha256 = switch (expected.selection) {
        ProjectSelectorSelection() => _projectSelectionEvidenceSha256(
          sdk: sdk,
          selectedVersion: expectedVersion,
          selectorHashes: selectorHashes,
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
    required L10nToolchainLaunch launch,
    required List<String> logicalArguments,
    required String workingDirectory,
    required Map<String, String> environmentOverrides,
    required _CanonicalSdk sdk,
    required String role,
  }) async {
    final arguments = launch._physicalArgumentsFor(logicalArguments);
    final result = await _runSnapshotProcess(
      processRunner: _processRunner,
      launch: launch,
      logicalArguments: logicalArguments,
      workingDirectory: workingDirectory,
      environmentOverrides: environmentOverrides,
      sdk: sdk,
      role: role,
      sdkDriftDetailCode: 'canonical-sdk-changed-during-probe',
      timeout: _probeTimeout,
      maxOutputBytesPerStream: _maxProbeOutputBytesPerStream,
    );

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
    if (stderr.isNotEmpty) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-stderr-nonempty',
      );
    }
    late final FlutterMachineIdentity identity;
    try {
      identity = _parseMachineIdentity(stdout, sdk: sdk, role: role);
    } on FormatException {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-output-invalid',
      );
    }
    return _ProbeEvidence(
      executable: launch.canonicalDartExecutable,
      arguments: arguments,
      stdout: stdout,
      stderr: stderr,
      identity: identity,
    );
  }
}

Future<ManagedProcessResult> _runSnapshotProcess({
  required ProcessExecutionRunner processRunner,
  required L10nToolchainLaunch launch,
  required List<String> logicalArguments,
  required String workingDirectory,
  required Map<String, String> environmentOverrides,
  required _CanonicalSdk sdk,
  required String role,
  required String sdkDriftDetailCode,
  required Duration timeout,
  required int maxOutputBytesPerStream,
}) async {
  final canonicalWorkingDirectory = _canonicalSandboxProtectedDirectory(
    workingDirectory,
    role: role,
  );
  final sandbox = _createProbeSandbox(
    sdk: sdk,
    fixedEnvironmentOverrides: environmentOverrides,
    role: role,
    canonicalWorkingDirectory: canonicalWorkingDirectory,
  );
  var retainSandbox = false;
  try {
    _requireSdkStillMatches(
      sdk.executable,
      sdk,
      detailCode: sdkDriftDetailCode,
    );
    final result = await processRunner.run(
      launch.canonicalDartExecutable,
      launch._physicalArgumentsFor(logicalArguments),
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
      environmentOverrides: sandbox.environmentOverrides,
      includeParentEnvironment: false,
    );
    _requireSdkStillMatches(
      sdk.executable,
      sdk,
      detailCode: sdkDriftDetailCode,
    );
    return result;
  } on ProcessTerminationUnconfirmedException {
    retainSandbox = true;
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-termination-unconfirmed',
    );
  } on _ResolutionSignal {
    rethrow;
  } catch (_) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-unavailable',
    );
  } finally {
    if (!retainSandbox) {
      _validateAndCleanupProbeSandbox(sandbox, role: role);
    }
  }
}

_ProbeSandbox _createProbeSandbox({
  required _CanonicalSdk sdk,
  required Map<String, String> fixedEnvironmentOverrides,
  required String role,
  required String canonicalWorkingDirectory,
}) {
  _requireHostExecutableStillMatches(sdk.chmodAuthority);
  _requireHostExecutableStillMatches(sdk.shellAuthority);
  Directory? root;
  try {
    final systemTemp = Directory.systemTemp.absolute;
    final canonicalSystemTemp = p.normalize(
      systemTemp.resolveSymbolicLinksSync(),
    );
    if (_sandboxLocationConflicts(
          canonicalSystemTemp,
          canonicalWorkingDirectory,
        ) ||
        _sandboxLocationConflicts(canonicalSystemTemp, sdk.root)) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-sandbox-location-unsupported',
      );
    }
    root = systemTemp.createTempSync('flutter-pruner-l10n-$role-');
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    final canonicalRoot = p.normalize(root.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalSystemTemp, canonicalRoot)) {
      throw const FormatException();
    }
    if (_sandboxLocationConflicts(canonicalRoot, canonicalWorkingDirectory) ||
        _sandboxLocationConflicts(canonicalRoot, sdk.root)) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-sandbox-location-unsupported',
      );
    }
    root = Directory(canonicalRoot);
    final environment = <String, String>{...fixedEnvironmentOverrides};
    for (final entry in _sandboxDirectoryRoles.entries) {
      final directory = Directory(p.join(canonicalRoot, entry.value))
        ..createSync();
      environment[entry.key] = directory.path;
    }
    final which = File(p.join(environment['PATH']!, 'which'));
    which.createSync(exclusive: true);
    final handle = which.openSync(mode: FileMode.writeOnly);
    try {
      handle.writeFromSync(_sandboxWhichBytes);
      handle.flushSync();
    } finally {
      handle.closeSync();
    }
    final chmodResult = Process.runSync(
      sdk.chmodAuthority.canonicalPath,
      [
        '700',
        canonicalRoot,
        for (final key in _sandboxDirectoryRoles.keys) environment[key]!,
        which.path,
      ],
      workingDirectory: canonicalRoot,
      environment: const {'LANG': 'C', 'LC_ALL': 'C'},
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (chmodResult.exitCode != 0) throw const FormatException();
    final sandbox = _ProbeSandbox(
      root: Directory(canonicalRoot),
      environmentOverrides: environment,
      whichCanonicalPath: p.normalize(which.resolveSymbolicLinksSync()),
      rootState: Directory(canonicalRoot).statSync(),
      whichState: which.statSync(),
    );
    _validateProbeSandbox(sandbox);
    _requireHostExecutableStillMatches(sdk.chmodAuthority);
    _requireHostExecutableStillMatches(sdk.shellAuthority);
    return sandbox;
  } on _ResolutionSignal {
    _cleanupUnlaunchedProbeSandbox(root, role: role);
    rethrow;
  } on FileSystemException {
    _cleanupUnlaunchedProbeSandbox(root, role: role);
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-unavailable',
    );
  } on ProcessException {
    _cleanupUnlaunchedProbeSandbox(root, role: role);
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-unavailable',
    );
  } on FormatException {
    _cleanupUnlaunchedProbeSandbox(root, role: role);
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-unavailable',
    );
  }
}

String _canonicalSandboxProtectedDirectory(
  String path, {
  required String role,
}) {
  try {
    if (FileSystemEntity.typeSync(path, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    return p.normalize(Directory(path).resolveSymbolicLinksSync());
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-location-unsupported',
    );
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-location-unsupported',
    );
  }
}

bool _sandboxLocationConflicts(String candidate, String protectedRoot) =>
    candidate == protectedRoot || p.isWithin(protectedRoot, candidate);

void _validateAndCleanupProbeSandbox(
  _ProbeSandbox sandbox, {
  required String role,
}) {
  try {
    _validateProbeSandbox(sandbox);
    sandbox.root.deleteSync(recursive: true);
    if (FileSystemEntity.typeSync(sandbox.root.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('sandbox cleanup incomplete');
    }
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-cleanup-unconfirmed',
    );
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-cleanup-unconfirmed',
    );
  }
}

void _validateProbeSandbox(_ProbeSandbox sandbox) {
  final rootPath = p.normalize(sandbox.root.absolute.path);
  final rootBefore = sandbox.root.statSync();
  if (FileSystemEntity.typeSync(rootPath, followLinks: false) !=
          FileSystemEntityType.directory ||
      p.normalize(sandbox.root.resolveSymbolicLinksSync()) != rootPath ||
      rootBefore.mode & 0xfff != 0x1c0 ||
      !_sameArtifactFileState(rootBefore, sandbox.rootState)) {
    throw const FormatException();
  }
  for (final entry in _sandboxDirectoryRoles.entries) {
    final path = sandbox.environmentOverrides[entry.key];
    if (path == null ||
        path != p.join(rootPath, entry.value) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        p.normalize(Directory(path).resolveSymbolicLinksSync()) != path ||
        Directory(path).statSync().mode & 0xfff != 0x1c0) {
      throw const FormatException();
    }
  }
  final which = File(p.join(sandbox.environmentOverrides['PATH']!, 'which'));
  final before = which.statSync();
  if (FileSystemEntity.typeSync(which.path, followLinks: false) !=
          FileSystemEntityType.file ||
      p.normalize(which.resolveSymbolicLinksSync()) !=
          sandbox.whichCanonicalPath ||
      before.mode & 0xfff != 0x1c0 ||
      !_sameArtifactFileState(before, sandbox.whichState) ||
      !_sameBytes(which.readAsBytesSync(), _sandboxWhichBytes)) {
    throw const FormatException();
  }
  final after = which.statSync();
  final rootAfter = sandbox.root.statSync();
  if (!_sameArtifactFileState(before, after) ||
      !_sameArtifactFileState(after, sandbox.whichState) ||
      !_sameArtifactFileState(rootBefore, rootAfter) ||
      !_sameArtifactFileState(rootAfter, sandbox.rootState)) {
    throw const FormatException();
  }
}

void _cleanupUnlaunchedProbeSandbox(Directory? root, {required String role}) {
  if (root == null) return;
  try {
    final canonicalSystemTemp = p.normalize(
      Directory.systemTemp.absolute.resolveSymbolicLinksSync(),
    );
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    final canonicalRoot = p.normalize(root.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalSystemTemp, canonicalRoot)) {
      throw const FormatException();
    }
    Directory(canonicalRoot).deleteSync(recursive: true);
    if (FileSystemEntity.typeSync(canonicalRoot, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw const FileSystemException('sandbox cleanup incomplete');
    }
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-cleanup-unconfirmed',
    );
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-cleanup-unconfirmed',
    );
  }
}

void _requireHostExecutableStillMatches(_HostExecutableAuthority expected) {
  final current = _captureHostExecutable(expected.requestedPath);
  if (!_sameHostExecutableAuthority(current, expected)) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'host-launch-authority-drift',
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
  if (!_sameCanonicalSdkAuthority(current, expected)) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

bool _sameCanonicalSdkAuthority(_CanonicalSdk left, _CanonicalSdk right) =>
    left.executable == right.executable &&
    left.root == right.root &&
    _sameCanonicalGitHead(left.gitHead, right.gitHead) &&
    _samePosixLaunchManifest(left.launchManifest, right.launchManifest) &&
    _sameHostExecutableAuthority(left.shellAuthority, right.shellAuthority) &&
    _sameHostExecutableAuthority(left.chmodAuthority, right.chmodAuthority);

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
    _requireSafeAuthorityDirectory(
      root,
      containmentRoot: root,
      detailCode: 'registry-sdk-structure-invalid',
    );
    final expectedExecutable = File(
      p.join(root, 'bin', _flutterExecutableName),
    ).resolveSymbolicLinksSync();
    if (p.normalize(expectedExecutable) != executable) {
      throw const FormatException();
    }

    final gitHead = _captureCanonicalGitHead(root);
    final launchManifest = _capturePosixLaunchManifest(root);
    final shellAuthority = _captureHostExecutable('/bin/sh');
    final chmodAuthority = _captureHostExecutable('/bin/chmod');
    final canonicalFlutter = launchManifest
        .entriesByRelativePath[p.join('bin', _flutterExecutableName)];
    if (canonicalFlutter == null ||
        canonicalFlutter.canonicalPath != executable) {
      throw const FormatException();
    }
    return _CanonicalSdk(
      executable: executable,
      root: root,
      gitHead: gitHead,
      launchManifest: launchManifest,
      shellAuthority: shellAuthority,
      chmodAuthority: chmodAuthority,
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

_CanonicalGitHead _captureCanonicalGitHead(String sdkRoot) {
  final gitPath = p.normalize(p.join(sdkRoot, '.git'));
  if (_gitEntityType(
        gitPath,
        detailCode: 'registry-sdk-git-layout-unsupported',
      ) !=
      FileSystemEntityType.directory) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-layout-unsupported',
    );
  }

  late final String canonicalGitPath;
  try {
    canonicalGitPath = p.normalize(
      Directory(gitPath).resolveSymbolicLinksSync(),
    );
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-layout-unsupported',
    );
  }
  if (canonicalGitPath != gitPath || !p.isWithin(sdkRoot, canonicalGitPath)) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-layout-unsupported',
    );
  }
  _requireSafeAuthorityDirectory(
    canonicalGitPath,
    containmentRoot: sdkRoot,
    detailCode: 'registry-sdk-git-layout-unsupported',
  );

  final commondirType = _gitEntityType(
    p.join(canonicalGitPath, 'commondir'),
    detailCode: 'registry-sdk-git-layout-unsupported',
  );
  if (commondirType != FileSystemEntityType.notFound) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-layout-unsupported',
    );
  }
  for (final relativePath in const ['reftable', 'tables.list']) {
    final type = _gitEntityType(
      p.join(canonicalGitPath, relativePath),
      detailCode: 'registry-sdk-git-layout-unsupported',
    );
    if (type != FileSystemEntityType.notFound) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-layout-unsupported',
      );
    }
  }

  final authority = SplayTreeMap<String, _GitAuthorityFingerprint>();
  final config = _readGitAuthorityFile(
    canonicalGitPath,
    'config',
    detailCode: 'registry-sdk-git-config-invalid',
    maxBytes: _maxGitConfigBytes,
  )!;
  _validateCanonicalGitConfig(config.bytes);
  authority['config'] = config.fingerprint;
  final head = _readGitAuthorityFile(
    canonicalGitPath,
    'HEAD',
    detailCode: 'registry-sdk-git-head-invalid',
    maxBytes: _maxGitHeadOrLooseRefBytes,
  )!;
  authority['HEAD'] = head.fingerprint;
  final headValue = _parseGitAuthorityValue(
    head.bytes,
    nonSymbolicDetailCode: 'registry-sdk-git-head-invalid',
  );
  if (headValue.objectId case final objectId?) {
    return _CanonicalGitHead(
      canonicalGitPath: canonicalGitPath,
      authorityByRelativePath: authority,
      symbolicRefChain: const [],
      resolutionSource: _GitHeadResolutionSource.detached,
      finalObjectId: objectId,
    );
  }

  final symbolicRefChain = <String>[];
  final visited = <String>{};
  var currentRef = headValue.symbolicRef!;
  for (var depth = 0; depth < _maxGitSymbolicRefDepth; depth++) {
    if (!visited.add(currentRef)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    symbolicRefChain.add(currentRef);
    final loose = _readGitAuthorityFile(
      canonicalGitPath,
      currentRef,
      detailCode: 'registry-sdk-git-ref-invalid',
      maxBytes: _maxGitHeadOrLooseRefBytes,
      allowMissing: true,
    );
    if (loose == null) {
      final packed = _readGitAuthorityFile(
        canonicalGitPath,
        'packed-refs',
        detailCode: 'registry-sdk-git-ref-invalid',
        maxBytes: _maxGitPackedRefsBytes,
      )!;
      authority['packed-refs'] = packed.fingerprint;
      final packedObjectId = _resolvePackedRef(packed.bytes, currentRef);
      return _CanonicalGitHead(
        canonicalGitPath: canonicalGitPath,
        authorityByRelativePath: authority,
        symbolicRefChain: symbolicRefChain,
        resolutionSource: _GitHeadResolutionSource.packedRef,
        finalObjectId: packedObjectId,
      );
    }
    authority[currentRef] = loose.fingerprint;
    final looseValue = _parseGitAuthorityValue(
      loose.bytes,
      nonSymbolicDetailCode: 'registry-sdk-git-ref-invalid',
    );
    if (looseValue.objectId case final objectId?) {
      return _CanonicalGitHead(
        canonicalGitPath: canonicalGitPath,
        authorityByRelativePath: authority,
        symbolicRefChain: symbolicRefChain,
        resolutionSource: _GitHeadResolutionSource.looseRef,
        finalObjectId: objectId,
      );
    }
    currentRef = looseValue.symbolicRef!;
  }
  throw const _ResolutionSignal(
    code: L10nEvidenceRejectionCode.toolchainUnavailable,
    detailCode: 'registry-sdk-git-ref-invalid',
  );
}

void _validateCanonicalGitConfig(List<int> bytes) {
  late final String text;
  try {
    text = ascii.decode(bytes);
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-config-invalid',
    );
  }
  if (text.isEmpty ||
      !text.endsWith('\n') ||
      text.contains('\r') ||
      text.contains(r'\') ||
      text.codeUnits.any(
        (codeUnit) =>
            (codeUnit < 0x20 && codeUnit != 0x09 && codeUnit != 0x0a) ||
            codeUnit == 0x7f,
      )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-config-invalid',
    );
  }

  final sectionPattern = RegExp(
    r'^\[([A-Za-z][A-Za-z0-9.-]*)(?:[ \t]+"[^"\\]*")?\]$',
  );
  final variablePattern = RegExp(
    r'^([A-Za-z][A-Za-z0-9-]*)(?:[ \t]*=[ \t]*(.*))?$',
  );
  String? section;
  var repositoryFormatVersionCount = 0;
  for (final rawLine in text.substring(0, text.length - 1).split('\n')) {
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith(';')) {
      continue;
    }
    if (line.startsWith('[')) {
      final match = sectionPattern.firstMatch(line);
      if (match == null) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-config-invalid',
        );
      }
      section = match.group(1)!.toLowerCase();
      if (section == 'include' ||
          section.startsWith('include.') ||
          section == 'includeif' ||
          section.startsWith('includeif.') ||
          section == 'extensions' ||
          section.startsWith('extensions.')) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-config-invalid',
        );
      }
      continue;
    }

    final match = variablePattern.firstMatch(line);
    if (section == null || match == null) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-config-invalid',
      );
    }
    final key = match.group(1)!.toLowerCase();
    if (section == 'core' && key == 'repositoryformatversion') {
      repositoryFormatVersionCount++;
      if (repositoryFormatVersionCount != 1 || match.group(2) != '0') {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-config-invalid',
        );
      }
    }
  }
  if (repositoryFormatVersionCount != 1) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-config-invalid',
    );
  }
}

_CapturedGitAuthority? _readGitAuthorityFile(
  String canonicalGitPath,
  String relativePath, {
  required String detailCode,
  required int maxBytes,
  bool allowMissing = false,
}) {
  if (p.isAbsolute(relativePath) ||
      p.normalize(relativePath) != relativePath ||
      p.split(relativePath).any((component) => component == '..')) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
  final components = p.split(relativePath);
  var current = canonicalGitPath;
  for (var index = 0; index < components.length; index++) {
    current = p.join(current, components[index]);
    final type = _gitEntityType(current, detailCode: detailCode);
    final isFinal = index == components.length - 1;
    if (type == FileSystemEntityType.notFound && allowMissing) return null;
    final expected = isFinal
        ? FileSystemEntityType.file
        : FileSystemEntityType.directory;
    if (type != expected) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: detailCode,
      );
    }
    if (!isFinal) {
      _requireSafeAuthorityDirectory(
        current,
        containmentRoot: canonicalGitPath,
        detailCode: detailCode,
      );
    }
  }

  final file = File(current);
  try {
    final canonicalBefore = p.normalize(file.resolveSymbolicLinksSync());
    if (canonicalBefore != p.normalize(current) ||
        !p.isWithin(canonicalGitPath, canonicalBefore)) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: detailCode,
      );
    }
    final before = file.statSync();
    final posixMode = before.mode & 0xfff;
    if (before.type != FileSystemEntityType.file ||
        before.size < 0 ||
        before.size > maxBytes ||
        posixMode & 0x12 != 0) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: detailCode,
      );
    }
    final bytes = file.readAsBytesSync();
    final after = file.statSync();
    final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
    if (bytes.length != before.size ||
        !_sameArtifactFileState(before, after) ||
        canonicalAfter != canonicalBefore) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: detailCode,
      );
    }
    return _CapturedGitAuthority(
      bytes: bytes,
      fingerprint: _GitAuthorityFingerprint(
        canonicalPath: canonicalBefore,
        byteLength: bytes.length,
        sha256: sha256.convert(bytes).toString(),
        posixMode: posixMode,
      ),
    );
  } on _ResolutionSignal {
    rethrow;
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

FileSystemEntityType _gitEntityType(String path, {required String detailCode}) {
  try {
    return FileSystemEntity.typeSync(path, followLinks: false);
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

_ParsedGitAuthorityValue _parseGitAuthorityValue(
  List<int> bytes, {
  required String nonSymbolicDetailCode,
}) {
  final objectId = _exactGitObjectIdLine(bytes);
  if (objectId != null) {
    return _ParsedGitAuthorityValue(objectId: objectId, symbolicRef: null);
  }
  const symbolicPrefix = <int>[0x72, 0x65, 0x66, 0x3a, 0x20];
  if (bytes.length > symbolicPrefix.length + 1 &&
      bytes.last == 0x0a &&
      _startsWithBytes(bytes, symbolicPrefix)) {
    final refBytes = bytes.sublist(symbolicPrefix.length, bytes.length - 1);
    late final String ref;
    try {
      ref = ascii.decode(refBytes);
    } on FormatException {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    if (!_validGitRefName(ref)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    return _ParsedGitAuthorityValue(objectId: null, symbolicRef: ref);
  }
  throw _ResolutionSignal(
    code: L10nEvidenceRejectionCode.toolchainUnavailable,
    detailCode: nonSymbolicDetailCode,
  );
}

String _resolvePackedRef(List<int> bytes, String targetRef) {
  late final String text;
  try {
    text = ascii.decode(bytes);
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-ref-invalid',
    );
  }
  if (text.isEmpty || !text.endsWith('\n') || text.contains('\r')) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-ref-invalid',
    );
  }
  final lines = text.substring(0, text.length - 1).split('\n');
  if (lines.isEmpty || lines.any((line) => line.isEmpty)) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-ref-invalid',
    );
  }

  final objectIdsByRef = <String, String>{};
  var previousRef = '';
  var sorted = false;
  var mayHavePeeledLine = false;
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index];
    if (line.startsWith('#')) {
      if (index != 0 || !_validPackedRefsHeader(line)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-ref-invalid',
        );
      }
      sorted = line.split(' ').contains('sorted');
      mayHavePeeledLine = false;
      continue;
    }
    if (line.startsWith('^')) {
      if (!mayHavePeeledLine ||
          line.length != 41 ||
          !_validGitObjectId(line.substring(1))) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'registry-sdk-git-ref-invalid',
        );
      }
      mayHavePeeledLine = false;
      continue;
    }
    if (line.length < 42 || line.codeUnitAt(40) != 0x20) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    final objectId = line.substring(0, 40);
    final ref = line.substring(41);
    if (!_validGitObjectId(objectId) || !_validGitRefName(ref)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    if (objectIdsByRef.containsKey(ref)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-packed-ref-ambiguous',
      );
    }
    if (sorted && previousRef.isNotEmpty && previousRef.compareTo(ref) >= 0) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-git-ref-invalid',
      );
    }
    objectIdsByRef[ref] = objectId;
    previousRef = ref;
    mayHavePeeledLine = true;
  }
  final resolved = objectIdsByRef[targetRef];
  if (resolved == null) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-git-ref-invalid',
    );
  }
  return resolved;
}

bool _validPackedRefsHeader(String line) {
  const prefix = '# pack-refs with: ';
  if (!line.startsWith(prefix)) {
    return false;
  }
  var capabilities = line.substring(prefix.length);
  if (capabilities.endsWith(' ')) {
    capabilities = capabilities.substring(0, capabilities.length - 1);
  }
  if (capabilities.isEmpty) {
    return false;
  }

  const supportedCapabilities = <String>{'peeled', 'fully-peeled', 'sorted'};
  final values = capabilities.split(' ');
  return values.length == values.toSet().length &&
      values.every(supportedCapabilities.contains);
}

bool _validGitRefName(String ref) {
  if (!ref.startsWith('refs/') ||
      ref.length <= 'refs/'.length ||
      ref.endsWith('/') ||
      ref.endsWith('.') ||
      ref.contains('..') ||
      ref.contains('@{') ||
      ref.contains('//')) {
    return false;
  }
  for (final codeUnit in ref.codeUnits) {
    if (codeUnit <= 0x20 ||
        codeUnit >= 0x7f ||
        const <int>{
          0x7e,
          0x5e,
          0x3a,
          0x3f,
          0x2a,
          0x5b,
          0x5c,
        }.contains(codeUnit)) {
      return false;
    }
  }
  final components = ref.split('/');
  return components.every(
    (component) =>
        component.isNotEmpty &&
        !component.startsWith('.') &&
        !component.endsWith('.lock'),
  );
}

String? _exactGitObjectIdLine(List<int> bytes) {
  if (bytes.length != 41 || bytes.last != 0x0a) return null;
  late final String value;
  try {
    value = ascii.decode(bytes.sublist(0, 40));
  } on FormatException {
    return null;
  }
  return _validGitObjectId(value) ? value : null;
}

bool _validGitObjectId(String value) =>
    RegExp(_gitObjectIdPattern).hasMatch(value);

bool _startsWithBytes(List<int> bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

void _requireGitHeadMatchesMachine(
  _CanonicalGitHead gitHead,
  FlutterMachineIdentity machineIdentity,
) {
  if (!_validGitObjectId(machineIdentity.frameworkRevision) ||
      gitHead.finalObjectId != machineIdentity.frameworkRevision) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-framework-identity-mismatch',
    );
  }
}

bool _isGitIdentityDetail(String detailCode) =>
    detailCode.startsWith('registry-sdk-git-') ||
    detailCode == 'registry-sdk-packed-ref-ambiguous';

_PosixLaunchManifest _capturePosixLaunchManifest(String root) {
  try {
    final entries = SplayTreeMap<String, _LaunchManifestEntry>();
    for (final spec in _fixedLaunchFileSpecs) {
      try {
        entries[spec.relativePath] = _captureLaunchFile(root, spec);
      } on FormatException {
        if (spec.invalidDetailCode case final detailCode?) {
          throw _ResolutionSignal(
            code: L10nEvidenceRejectionCode.toolchainUnavailable,
            detailCode: detailCode,
          );
        }
        rethrow;
      }
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
    _validateFlutterToolsPackageConfig(entries);
    return _PosixLaunchManifest(entriesByRelativePath: entries);
  } on _ResolutionSignal {
    rethrow;
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-artifact-unreadable',
    );
  }
}

_HostExecutableAuthority _captureHostExecutable(String requestedPath) {
  try {
    final requestedPathType = FileSystemEntity.typeSync(
      requestedPath,
      followLinks: false,
    );
    if (!p.isAbsolute(requestedPath) ||
        (requestedPathType != FileSystemEntityType.file &&
            requestedPathType != FileSystemEntityType.link) ||
        FileSystemEntity.typeSync(requestedPath, followLinks: true) !=
            FileSystemEntityType.file) {
      throw const FormatException();
    }
    final file = File(requestedPath);
    final canonicalPath = p.normalize(file.resolveSymbolicLinksSync());
    final before = File(canonicalPath).statSync();
    final posixMode = before.mode & 0xfff;
    if (before.type != FileSystemEntityType.file ||
        !_isExecutable(before) ||
        posixMode & 0x12 != 0) {
      throw const FormatException();
    }
    final bytes = File(canonicalPath).readAsBytesSync();
    final after = File(canonicalPath).statSync();
    final canonicalAfter = p.normalize(file.resolveSymbolicLinksSync());
    if (!_sameArtifactFileState(before, after) ||
        canonicalAfter != canonicalPath) {
      throw const FormatException();
    }
    return _HostExecutableAuthority(
      requestedPath: requestedPath,
      requestedPathType: requestedPathType,
      canonicalPath: canonicalPath,
      sha256: sha256.convert(bytes).toString(),
      byteLength: bytes.length,
      executable: true,
      posixMode: posixMode,
    );
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'host-launch-authority-invalid',
    );
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'host-launch-authority-invalid',
    );
  }
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
  final posixMode = before.mode & 0xfff;
  if (before.type != FileSystemEntityType.file ||
      posixMode & 0x12 != 0 ||
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
    posixMode: posixMode,
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

Map<String, String> _frozenEnvironmentOverrides(String sdkRoot) =>
    _sortedUnmodifiableMap({
      ..._baseEnvironmentOverrides,
      'FLUTTER_ROOT': sdkRoot,
      'FLUTTER_ALREADY_LOCKED': 'true',
    });

FlutterMachineIdentity _validatedSdkMachineIdentity(
  _CanonicalSdk sdk,
  Version selectedVersion,
) {
  final versionControl = _exactJsonObject(
    sdk.launchManifest,
    _flutterVersionPath,
    _flutterVersionKeys,
    detailCode: 'registry-sdk-version-control-invalid',
  );
  String stringValue(String key) {
    final value = versionControl[key];
    if (value is! String || value.isEmpty || value != value.trim()) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-version-control-invalid',
      );
    }
    return value;
  }

  final frameworkVersionText = stringValue('frameworkVersion');
  final flutterVersionText = stringValue('flutterVersion');
  final frameworkVersion = _supportedVersion(frameworkVersionText);
  if (frameworkVersion == null ||
      !_sameVersion(frameworkVersion, selectedVersion) ||
      flutterVersionText != frameworkVersionText ||
      stringValue('channel') != 'stable' ||
      stringValue('repositoryUrl') !=
          'https://github.com/flutter/flutter.git') {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-version-control-invalid',
    );
  }
  for (final key in const [
    'frameworkCommitDate',
    'engineCommitDate',
    'engineBuildDate',
    'devToolsVersion',
  ]) {
    stringValue(key);
  }
  final frameworkRevision = stringValue('frameworkRevision');
  final engineRevision = stringValue('engineRevision');
  final engineContentHash = stringValue('engineContentHash');
  final dartSdkVersion = stringValue('dartSdkVersion');
  if (!_validGitObjectId(frameworkRevision) ||
      !_validGitObjectId(engineRevision) ||
      !_validGitObjectId(engineContentHash)) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-version-control-invalid',
    );
  }

  final identity = FlutterMachineIdentity(
    frameworkVersion: frameworkVersion,
    frameworkRevision: frameworkRevision,
    engineRevision: engineRevision,
    dartSdkVersion: dartSdkVersion,
  );
  _requireGitHeadMatchesMachine(sdk.gitHead, identity);
  _requireLaunchControlsCompatible(
    sdk.launchManifest,
    identity,
    engineContentHash: engineContentHash,
  );
  _validateFlutterToolsPackageConfig(
    sdk.launchManifest.entriesByRelativePath,
    expectedDartVersion: dartSdkVersion,
  );
  return identity;
}

void _requireLaunchControlsCompatible(
  _PosixLaunchManifest manifest,
  FlutterMachineIdentity machineIdentity, {
  required String engineContentHash,
}) {
  final exactEngineLine = utf8.encode('${machineIdentity.engineRevision}\n');
  if (!_sameBytes(
        _manifestFileContent(manifest.entriesByRelativePath, _engineStampPath),
        exactEngineLine,
      ) ||
      !_sameBytes(
        _manifestFileContent(
          manifest.entriesByRelativePath,
          _engineVersionPath,
        ),
        exactEngineLine,
      )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-engine-identity-mismatch',
    );
  }

  if (!_sameBytes(
    _manifestFileContent(
      manifest.entriesByRelativePath,
      _engineDartSdkStampPath,
    ),
    exactEngineLine,
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-dart-stamp-mismatch',
    );
  }

  if (!_sameBytes(
    _manifestFileContent(manifest.entriesByRelativePath, _engineRealmPath),
    const [0x0a],
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.unsupportedConfiguration,
      detailCode: 'registry-sdk-engine-realm-unsupported',
    );
  }

  if (!_sameBytes(
    _manifestFileContent(
      manifest.entriesByRelativePath,
      _flutterToolsStampPath,
    ),
    utf8.encode('${machineIdentity.frameworkRevision}:\n'),
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-flutter-tools-stamp-incompatible',
    );
  }

  final dartVersionBytes = _manifestFileContent(
    manifest.entriesByRelativePath,
    _dartSdkVersionPath,
  );
  if (!_sameBytes(
    dartVersionBytes,
    utf8.encode('${machineIdentity.dartSdkVersion}\n'),
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-dart-version-mismatch',
    );
  }

  final engineStampStamp = _manifestFileContent(
    manifest.entriesByRelativePath,
    _engineStampStampPath,
  );
  if (!_sameBytes(
    engineStampStamp,
    utf8.encode(machineIdentity.engineRevision),
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-engine-identity-mismatch',
    );
  }

  final engineStampJson = _exactJsonObject(
    manifest,
    _engineStampJsonPath,
    const {
      'build_date',
      'build_time_ms',
      'git_revision',
      'git_revision_date',
      'content_hash',
    },
    detailCode: 'registry-sdk-engine-stamp-invalid',
  );
  final buildDate = engineStampJson['build_date'];
  final buildTimeMs = engineStampJson['build_time_ms'];
  final gitRevision = engineStampJson['git_revision'];
  final gitRevisionDate = engineStampJson['git_revision_date'];
  final contentHash = engineStampJson['content_hash'];
  if (buildDate is! String ||
      buildDate.isEmpty ||
      buildDate != buildDate.trim() ||
      buildTimeMs is! int ||
      buildTimeMs <= 0 ||
      gitRevision != machineIdentity.engineRevision ||
      gitRevisionDate is! String ||
      gitRevisionDate.isEmpty ||
      gitRevisionDate != gitRevisionDate.trim() ||
      contentHash != engineContentHash) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-engine-stamp-invalid',
    );
  }
}

Map<String, Object?> _exactJsonObject(
  _PosixLaunchManifest manifest,
  String relativePath,
  Set<String> expectedKeys, {
  required String detailCode,
}) {
  final parsed = ArbDocument.parse(
    _manifestFileContent(manifest.entriesByRelativePath, relativePath),
  );
  if (parsed is! ArbParseSuccess ||
      !_sameStringSet(
        parsed.document.members.map((member) => member.decodedKey),
        expectedKeys,
      ) ||
      parsed.document.members.length != expectedKeys.length) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
  return Map<String, Object?>.unmodifiable({
    for (final member in parsed.document.members)
      member.decodedKey: member.decodedValue,
  });
}

void _validateFlutterToolsPackageConfig(
  Map<String, _LaunchManifestEntry> entries, {
  String? expectedDartVersion,
}) {
  final parsed = ArbDocument.parse(
    _manifestFileContent(entries, _flutterToolsPackageConfigPath),
  );
  const expectedKeys = {
    'configVersion',
    'packages',
    'generator',
    'generatorVersion',
    'pubCache',
  };
  if (parsed is! ArbParseSuccess ||
      parsed.document.members.length != expectedKeys.length ||
      !_sameStringSet(
        parsed.document.members.map((member) => member.decodedKey),
        expectedKeys,
      )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
  final values = {
    for (final member in parsed.document.members)
      member.decodedKey: member.decodedValue,
  };
  final packages = values['packages'];
  final generatorVersion = values['generatorVersion'];
  if (values['configVersion'] != 2 ||
      packages is! List<Object?> ||
      packages.isEmpty ||
      values['generator'] != 'pub' ||
      generatorVersion is! String ||
      generatorVersion.isEmpty ||
      values['pubCache'] is! String ||
      (values['pubCache']! as String).isEmpty ||
      (expectedDartVersion != null &&
          generatorVersion != expectedDartVersion)) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
  final names = <String>{};
  Map<Object?, Object?>? flutterTools;
  for (final package in packages) {
    if (package is! Map<Object?, Object?> ||
        package['name'] is! String ||
        package['rootUri'] is! String ||
        package['packageUri'] is! String ||
        package['languageVersion'] is! String ||
        !names.add(package['name']! as String)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-package-config-invalid',
      );
    }
    if (package['name'] == 'flutter_tools') flutterTools = package;
  }
  if (flutterTools == null ||
      flutterTools['rootUri'] != '../' ||
      flutterTools['packageUri'] != 'lib/') {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
}

String _requireSafeLaunchPath(
  String root,
  String relativePath,
  FileSystemEntityType finalType,
) {
  _requireSafeAuthorityDirectory(
    root,
    containmentRoot: root,
    detailCode: 'registry-sdk-structure-invalid',
  );
  final components = p.split(relativePath);
  var current = root;
  for (var index = 0; index < components.length; index++) {
    current = p.join(current, components[index]);
    final type = FileSystemEntity.typeSync(current, followLinks: false);
    final expectedType = index == components.length - 1
        ? finalType
        : FileSystemEntityType.directory;
    if (type != expectedType) throw const FormatException();
    if (expectedType == FileSystemEntityType.directory) {
      _requireSafeAuthorityDirectory(
        current,
        containmentRoot: root,
        detailCode: 'registry-sdk-structure-invalid',
      );
    }
  }
  return current;
}

void _requireSafeAuthorityDirectory(
  String path, {
  required String containmentRoot,
  required String detailCode,
}) {
  try {
    final normalizedPath = p.normalize(path);
    final normalizedRoot = p.normalize(containmentRoot);
    if (FileSystemEntity.typeSync(normalizedPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException();
    }
    final directory = Directory(normalizedPath);
    final canonicalBefore = p.normalize(directory.resolveSymbolicLinksSync());
    final before = directory.statSync();
    final posixMode = before.mode & 0xfff;
    if (canonicalBefore != normalizedPath ||
        (canonicalBefore != normalizedRoot &&
            !p.isWithin(normalizedRoot, canonicalBefore)) ||
        before.type != FileSystemEntityType.directory ||
        posixMode & 0x12 != 0) {
      throw const FormatException();
    }
    final after = directory.statSync();
    final canonicalAfter = p.normalize(directory.resolveSymbolicLinksSync());
    if (!_sameArtifactFileState(before, after) ||
        canonicalAfter != canonicalBefore) {
      throw const FormatException();
    }
  } on FileSystemException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  } on FormatException {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: detailCode,
    );
  }
}

List<_LaunchFileSpec> get _fixedLaunchFileSpecs => [
  _LaunchFileSpec(
    relativePath: p.join('bin', _flutterExecutableName),
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
    _LaunchFileSpec(
      relativePath: relativePath,
      requiresExecutable: false,
      invalidDetailCode: switch (relativePath) {
        _flutterVersionPath => 'registry-sdk-version-control-invalid',
        _engineStampJsonPath ||
        _engineStampStampPath => 'registry-sdk-engine-stamp-invalid',
        _dartSdkVersionPath => 'registry-sdk-dart-version-mismatch',
        _flutterToolsPackageConfigPath => 'registry-sdk-package-config-invalid',
        _ => null,
      },
    ),
];

const _flutterToolsPackageConfigPath =
    'packages/flutter_tools/.dart_tool/package_config.json';
const _flutterVersionKeys = <String>{
  'frameworkVersion',
  'channel',
  'repositoryUrl',
  'frameworkRevision',
  'frameworkCommitDate',
  'engineRevision',
  'engineCommitDate',
  'engineContentHash',
  'engineBuildDate',
  'dartSdkVersion',
  'devToolsVersion',
  'flutterVersion',
};
const _directMachineKeys = <String>{..._flutterVersionKeys, 'flutterRoot'};
const _flutterToolsSnapshotPath = 'bin/cache/flutter_tools.snapshot';
const _flutterToolsStampPath = 'bin/cache/flutter_tools.stamp';
const _engineStampPath = 'bin/cache/engine.stamp';
const _engineRealmPath = 'bin/cache/engine.realm';
const _engineDartSdkStampPath = 'bin/cache/engine-dart-sdk.stamp';
const _engineVersionPath = 'bin/internal/engine.version';
const _flutterVersionPath = 'bin/cache/flutter.version.json';
const _engineStampJsonPath = 'bin/cache/engine_stamp.json';
const _engineStampStampPath = 'bin/cache/engine_stamp.stamp';
const _dartSdkVersionPath = 'bin/cache/dart-sdk/version';
const _semanticControlContentPaths = <String>{
  _flutterToolsStampPath,
  _engineStampPath,
  _engineRealmPath,
  _engineDartSdkStampPath,
  _engineVersionPath,
  _flutterVersionPath,
  _engineStampJsonPath,
  _engineStampStampPath,
  _dartSdkVersionPath,
  _flutterToolsPackageConfigPath,
};
const _controlInputPaths = <String>[
  _flutterToolsStampPath,
  _engineStampPath,
  _engineRealmPath,
  _engineDartSdkStampPath,
  _engineVersionPath,
  _flutterToolsPackageConfigPath,
  _flutterVersionPath,
  _engineStampJsonPath,
  _engineStampStampPath,
  _dartSdkVersionPath,
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

String get _bundledDartName => Platform.isWindows ? 'dart.exe' : 'dart';

FlutterMachineIdentity _parseMachineIdentity(
  List<int> bytes, {
  required _CanonicalSdk sdk,
  required String role,
}) {
  final parsed = ArbDocument.parse(bytes);
  if (parsed is! ArbParseSuccess ||
      parsed.document.members.length != _directMachineKeys.length ||
      !_sameStringSet(
        parsed.document.members.map((member) => member.decodedKey),
        _directMachineKeys,
      )) {
    throw const FormatException();
  }
  final decoded = <String, Object?>{
    for (final member in parsed.document.members)
      member.decodedKey: member.decodedValue,
  };
  final versionControl = _exactJsonObject(
    sdk.launchManifest,
    _flutterVersionPath,
    _flutterVersionKeys,
    detailCode: 'registry-sdk-version-control-invalid',
  );
  for (final key in _flutterVersionKeys) {
    if (decoded[key] != versionControl[key]) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-identity-mismatch',
      );
    }
  }
  if (decoded['flutterRoot'] != sdk.root) {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-identity-mismatch',
    );
  }

  final rawVersion = _requiredIdentityString(decoded, 'frameworkVersion');
  final version = _supportedVersion(rawVersion);
  if (version == null) throw const FormatException();
  final frameworkRevision = _requiredIdentityString(
    decoded,
    'frameworkRevision',
  );
  final engineRevision = _requiredIdentityString(decoded, 'engineRevision');
  if (!_validGitObjectId(frameworkRevision) ||
      !_validGitObjectId(engineRevision)) {
    throw const FormatException();
  }
  return FlutterMachineIdentity(
    frameworkVersion: version,
    frameworkRevision: frameworkRevision,
    engineRevision: engineRevision,
    dartSdkVersion: _requiredIdentityString(decoded, 'dartSdkVersion'),
  );
}

String _requiredIdentityString(Map<String, Object?> machine, String key) {
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
    _validGitObjectId(identity.frameworkRevision) &&
    _validGitObjectId(identity.engineRevision) &&
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
    _sameStringMap(
      expected.environmentOverrides,
      _frozenEnvironmentOverrides(expected.canonicalSdkRoot),
    ) &&
    !expected.environmentOverrides.containsKey('HOME') &&
    !expected.environmentOverrides.containsKey('PUB_CACHE') &&
    p.isAbsolute(expected.launch.canonicalDartExecutable) &&
    p.isAbsolute(expected.launch.canonicalFlutterToolsPackageConfig) &&
    p.isAbsolute(expected.launch.canonicalFlutterToolsSnapshot);

bool _sameLaunch(L10nToolchainLaunch left, L10nToolchainLaunch right) {
  if (!_sameLaunchPaths(left, right)) return false;
  final leftSdk = left._frozenSdk;
  final rightSdk = right._frozenSdk;
  if (identical(leftSdk, rightSdk)) return true;
  if (leftSdk == null || rightSdk == null) return false;
  return _sameCanonicalSdkAuthority(leftSdk, rightSdk);
}

bool _sameLaunchPaths(L10nToolchainLaunch left, L10nToolchainLaunch right) =>
    left.canonicalDartExecutable == right.canonicalDartExecutable &&
    left.canonicalFlutterToolsPackageConfig ==
        right.canonicalFlutterToolsPackageConfig &&
    left.canonicalFlutterToolsSnapshot == right.canonicalFlutterToolsSnapshot;

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool _sameBytes(List<int> left, List<int> right) {
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

String _projectSelectionEvidenceSha256({
  required _CanonicalSdk sdk,
  required Version selectedVersion,
  required Map<String, String> selectorHashes,
}) {
  final hasher = _FramedIdentityHasher();
  hasher.addText('schema', 'l10n-project-selection-v1');
  hasher.addText('selectedVersion', selectedVersion.toString());
  hasher.addText('canonicalFlutterExecutable', sdk.executable);
  hasher.addText('canonicalSdkRoot', sdk.root);
  for (final entry in SplayTreeMap<String, String>.of(selectorHashes).entries) {
    hasher.addText('selectorPath', entry.key);
    hasher.addText('selectorSha256', entry.value);
  }
  return hasher.digest();
}

String _toolchainIdentitySha256({
  required _CanonicalSdk sdk,
  required L10nToolchainSelection selection,
  required Map<String, String> selectorHashes,
  required Version selectedVersion,
  required FlutterMachineIdentity machineIdentity,
  required String originalSelectionProbeSha256,
  required _ProbeEvidence directProbe,
  required List<String> generationArgs,
  required List<String> directProbeArgs,
  required Map<String, String> environmentOverrides,
}) {
  final hasher = _FramedIdentityHasher();
  hasher.addText('schema', 'l10n-toolchain-v1');
  hasher.addText('canonicalFlutterExecutable', sdk.executable);
  hasher.addText('canonicalSdkRoot', sdk.root);
  _addLaunch(hasher, sdk.launch);
  _addHostAuthority(hasher, 'shellAuthority', sdk.shellAuthority);
  _addHostAuthority(hasher, 'chmodAuthority', sdk.chmodAuthority);
  hasher.addText('gitHead.canonicalGitPath', sdk.gitHead.canonicalGitPath);
  hasher.addText('gitHead.resolutionSource', sdk.gitHead.resolutionSource.name);
  hasher.addText('gitHead.finalObjectId', sdk.gitHead.finalObjectId);
  hasher.addText(
    'gitHead.symbolicRefCount',
    sdk.gitHead.symbolicRefChain.length.toString(),
  );
  for (final ref in sdk.gitHead.symbolicRefChain) {
    hasher.addText('gitHead.symbolicRef', ref);
  }
  hasher.addText(
    'gitHead.authorityCount',
    sdk.gitHead.authorityByRelativePath.length.toString(),
  );
  for (final entry in sdk.gitHead.authorityByRelativePath.entries) {
    hasher.addText('gitHead.authorityRelativePath', entry.key);
    hasher.addText('gitHead.authorityCanonicalPath', entry.value.canonicalPath);
    hasher.addText(
      'gitHead.authorityByteLength',
      entry.value.byteLength.toString(),
    );
    hasher.addText('gitHead.authoritySha256', entry.value.sha256);
    hasher.addText(
      'gitHead.authorityPosixMode',
      entry.value.posixMode.toRadixString(8),
    );
  }
  hasher.addText(
    'launchManifestEntryCount',
    sdk.launchManifest.entriesByRelativePath.length.toString(),
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
    hasher.addText(
      'launchManifest.posixMode',
      entry.value.posixMode.toRadixString(8),
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
  _addProbe(hasher, 'directProbe', directProbe);
  for (final argument in generationArgs) {
    hasher.addText('generationArg', argument);
  }
  for (final argument in directProbeArgs) {
    hasher.addText('directProbeArg', argument);
  }
  _addOverrides(hasher, environmentOverrides);
  hasher.addText('sandboxPolicy', _sandboxEnvironmentPolicyVersion);
  hasher.addText('sandboxIncludeParentEnvironment', 'false');
  for (final entry in SplayTreeMap<String, String>.of(
    _sandboxDirectoryRoles,
  ).entries) {
    hasher.addText('sandboxEnvironmentKey', entry.key);
    hasher.addText('sandboxDirectoryRole', entry.value);
  }
  hasher.addBytes('sandboxWhichBytes', _sandboxWhichBytes);
  _addMachineIdentity(hasher, 'machineIdentity', machineIdentity);
  return hasher.digest();
}

void _addLaunch(_FramedIdentityHasher hasher, L10nToolchainLaunch launch) {
  hasher.addText(
    'launch.canonicalDartExecutable',
    launch.canonicalDartExecutable,
  );
  hasher.addText(
    'launch.canonicalFlutterToolsPackageConfig',
    launch.canonicalFlutterToolsPackageConfig,
  );
  hasher.addText(
    'launch.canonicalFlutterToolsSnapshot',
    launch.canonicalFlutterToolsSnapshot,
  );
}

void _addHostAuthority(
  _FramedIdentityHasher hasher,
  String prefix,
  _HostExecutableAuthority authority,
) {
  hasher.addText('$prefix.requestedPath', authority.requestedPath);
  hasher.addText(
    '$prefix.requestedPathType',
    authority.requestedPathType == FileSystemEntityType.file
        ? 'regular-file'
        : 'symbolic-link',
  );
  hasher.addText('$prefix.canonicalPath', authority.canonicalPath);
  hasher.addText('$prefix.sha256', authority.sha256);
  hasher.addText('$prefix.byteLength', authority.byteLength.toString());
  hasher.addText('$prefix.executable', authority.executable.toString());
  hasher.addText('$prefix.posixMode', authority.posixMode.toRadixString(8));
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
  hasher.addText('includeParentEnvironment', 'false');
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

final class _ProbeSandbox {
  _ProbeSandbox({
    required this.root,
    required Map<String, String> environmentOverrides,
    required this.whichCanonicalPath,
    required this.rootState,
    required this.whichState,
  }) : environmentOverrides = _sortedUnmodifiableMap(environmentOverrides);

  final Directory root;
  final Map<String, String> environmentOverrides;
  final String whichCanonicalPath;
  final FileStat rootState;
  final FileStat whichState;
}

enum _GitHeadResolutionSource { detached, looseRef, packedRef }

final class _CanonicalGitHead {
  _CanonicalGitHead({
    required this.canonicalGitPath,
    required Map<String, _GitAuthorityFingerprint> authorityByRelativePath,
    required List<String> symbolicRefChain,
    required this.resolutionSource,
    required this.finalObjectId,
  }) : authorityByRelativePath =
           Map<String, _GitAuthorityFingerprint>.unmodifiable(
             SplayTreeMap<String, _GitAuthorityFingerprint>.of(
               authorityByRelativePath,
             ),
           ),
       symbolicRefChain = List<String>.unmodifiable(symbolicRefChain);

  final String canonicalGitPath;
  final Map<String, _GitAuthorityFingerprint> authorityByRelativePath;
  final List<String> symbolicRefChain;
  final _GitHeadResolutionSource resolutionSource;
  final String finalObjectId;
}

final class _GitAuthorityFingerprint {
  const _GitAuthorityFingerprint({
    required this.canonicalPath,
    required this.byteLength,
    required this.sha256,
    required this.posixMode,
  });

  final String canonicalPath;
  final int byteLength;
  final String sha256;
  final int posixMode;
}

final class _CapturedGitAuthority {
  _CapturedGitAuthority({required List<int> bytes, required this.fingerprint})
    : bytes = Uint8List.fromList(bytes);

  final Uint8List bytes;
  final _GitAuthorityFingerprint fingerprint;
}

final class _ParsedGitAuthorityValue {
  const _ParsedGitAuthorityValue({
    required this.objectId,
    required this.symbolicRef,
  }) : assert((objectId == null) != (symbolicRef == null));

  final String? objectId;
  final String? symbolicRef;
}

bool _sameCanonicalGitHead(_CanonicalGitHead left, _CanonicalGitHead right) {
  if (left.canonicalGitPath != right.canonicalGitPath ||
      left.resolutionSource != right.resolutionSource ||
      left.finalObjectId != right.finalObjectId ||
      !_sameStringList(left.symbolicRefChain, right.symbolicRefChain) ||
      left.authorityByRelativePath.length !=
          right.authorityByRelativePath.length) {
    return false;
  }
  for (final entry in left.authorityByRelativePath.entries) {
    final other = right.authorityByRelativePath[entry.key];
    if (other == null ||
        entry.value.canonicalPath != other.canonicalPath ||
        entry.value.byteLength != other.byteLength ||
        entry.value.sha256 != other.sha256 ||
        entry.value.posixMode != other.posixMode) {
      return false;
    }
  }
  return true;
}

final class _CanonicalSdk {
  _CanonicalSdk({
    required this.executable,
    required this.root,
    required this.gitHead,
    required this.launchManifest,
    required this.shellAuthority,
    required this.chmodAuthority,
  });

  final String executable;
  final String root;
  final _CanonicalGitHead gitHead;
  final _PosixLaunchManifest launchManifest;
  final _HostExecutableAuthority shellAuthority;
  final _HostExecutableAuthority chmodAuthority;

  L10nToolchainLaunch get launch => L10nToolchainLaunch._bound(
    canonicalDartExecutable: _manifestFileEntry(
      launchManifest.entriesByRelativePath,
      p.join('bin', 'cache', 'dart-sdk', 'bin', _bundledDartName),
    ).canonicalPath,
    canonicalFlutterToolsPackageConfig: _manifestFileEntry(
      launchManifest.entriesByRelativePath,
      _flutterToolsPackageConfigPath,
    ).canonicalPath,
    canonicalFlutterToolsSnapshot: _manifestFileEntry(
      launchManifest.entriesByRelativePath,
      _flutterToolsSnapshotPath,
    ).canonicalPath,
    frozenSdk: this,
  );
}

final class _HostExecutableAuthority {
  const _HostExecutableAuthority({
    required this.requestedPath,
    required this.requestedPathType,
    required this.canonicalPath,
    required this.sha256,
    required this.byteLength,
    required this.executable,
    required this.posixMode,
  });

  final String requestedPath;
  final FileSystemEntityType requestedPathType;
  final String canonicalPath;
  final String sha256;
  final int byteLength;
  final bool executable;
  final int posixMode;
}

bool _sameHostExecutableAuthority(
  _HostExecutableAuthority left,
  _HostExecutableAuthority right,
) =>
    left.requestedPath == right.requestedPath &&
    left.requestedPathType == right.requestedPathType &&
    left.canonicalPath == right.canonicalPath &&
    left.sha256 == right.sha256 &&
    left.byteLength == right.byteLength &&
    left.executable == right.executable &&
    left.posixMode == right.posixMode;

final class _PosixLaunchManifest {
  _PosixLaunchManifest({
    required Map<String, _LaunchManifestEntry> entriesByRelativePath,
  }) : entriesByRelativePath = Map<String, _LaunchManifestEntry>.unmodifiable(
         SplayTreeMap<String, _LaunchManifestEntry>.of(entriesByRelativePath),
       );

  final Map<String, _LaunchManifestEntry> entriesByRelativePath;
}

final class _LaunchFileSpec {
  const _LaunchFileSpec({
    required this.relativePath,
    required this.requiresExecutable,
    this.invalidDetailCode,
  });

  final String relativePath;
  final bool requiresExecutable;
  final String? invalidDetailCode;
}

enum _LaunchManifestEntryType { regularFile }

final class _LaunchManifestEntry {
  _LaunchManifestEntry({
    required this.canonicalPath,
    required this.type,
    required this.sha256,
    required this.byteLength,
    required this.requiresExecutable,
    required this.executable,
    required this.posixMode,
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
  final int posixMode;
  final List<int>? semanticContent;
}

bool _samePosixLaunchManifest(
  _PosixLaunchManifest left,
  _PosixLaunchManifest right,
) {
  if (left.entriesByRelativePath.length != right.entriesByRelativePath.length) {
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
        entry.value.executable != other.executable ||
        entry.value.posixMode != other.posixMode) {
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
