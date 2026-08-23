import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

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
const _darwinSandboxExecPath = '/usr/bin/sandbox-exec';
const _darwinProbeProfile =
    '(version 1)(allow default)(deny network*)'
    '(deny file-write*)'
    '(allow file-write* (subpath (param "SANDBOX_ROOT")))';
const _darwinGenerationProfile =
    '$_darwinProbeProfile'
    '(allow file-write* (subpath (param "WRITE_ROOT")))';
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

/// Frozen OS-enforced process-confinement authority.
final class L10nProcessConfinementAuthority {
  /// Creates immutable confinement authority evidence.
  const L10nProcessConfinementAuthority({
    required this.backendIdentity,
    required this.requestedExecutable,
    required this.requestedExecutableType,
    required this.canonicalExecutable,
    required this.executableSha256,
    required this.executableByteLength,
    required this.executablePosixMode,
    required this.policyIdentity,
  });

  /// Versioned backend and command grammar identity.
  final String backendIdentity;

  /// Exact host path requested for the kernel boundary launcher.
  final String requestedExecutable;

  /// Unfollowed type of [requestedExecutable].
  final FileSystemEntityType requestedExecutableType;

  /// Canonical regular executable target.
  final String canonicalExecutable;

  /// SHA-256 of the exact executable bytes.
  final String executableSha256;

  /// Exact executable byte length.
  final int executableByteLength;

  /// Exact requested executable target POSIX mode.
  final int executablePosixMode;

  /// Length-framed identity of every static profile and parameter grammar.
  final String policyIdentity;
}

/// Shell-free physical command produced by an OS confinement backend.
final class L10nConfinedCommand {
  /// Creates an immutable physical command.
  L10nConfinedCommand({
    required this.executable,
    required List<String> arguments,
  }) : arguments = List<String>.unmodifiable(arguments);

  /// Exact confinement executable.
  final String executable;

  /// Exact argv passed without shell interpretation.
  final List<String> arguments;
}

/// Stable confinement setup/revalidation failure.
final class L10nProcessConfinementException implements Exception {
  /// Creates a failure with a non-secret [detailCode].
  const L10nProcessConfinementException(this.detailCode);

  /// Stable machine-readable detail.
  final String detailCode;
}

/// OS boundary used for every direct Flutter-tools snapshot process.
abstract interface class L10nProcessConfinementBackend {
  /// Captures exact immutable launcher and static-policy authority.
  L10nProcessConfinementAuthority captureAuthority();

  /// Wraps [executable] and [arguments] in an enforcing physical command.
  ///
  /// A null [writableRoot] is the probe policy. Generation supplies its
  /// canonical stage root as the sole additional writable subtree.
  L10nConfinedCommand confine({
    required L10nProcessConfinementAuthority expectedAuthority,
    required String sandboxRoot,
    required String? writableRoot,
    required String executable,
    required List<String> arguments,
  });
}

/// Marker for a test-only process runner paired with an injected fake guard.
///
/// Implementations are trusted in-process test infrastructure. Production
/// composition never accepts an injected confinement backend.
abstract interface class L10nTestProcessRunner
    implements ProcessExecutionRunner {}

/// Production confinement: Darwin sandbox-exec, fail-closed elsewhere.
final class DefaultL10nProcessConfinementBackend
    implements L10nProcessConfinementBackend {
  /// Creates the production confinement backend.
  const DefaultL10nProcessConfinementBackend();

  @override
  L10nProcessConfinementAuthority captureAuthority() {
    if (!Platform.isMacOS) {
      throw const L10nProcessConfinementException('os-confinement-unsupported');
    }
    try {
      final executable = _captureHostExecutable(_darwinSandboxExecPath);
      return L10nProcessConfinementAuthority(
        backendIdentity: 'darwin-sandbox-exec-v1',
        requestedExecutable: executable.requestedPath,
        requestedExecutableType: executable.requestedPathType,
        canonicalExecutable: executable.canonicalPath,
        executableSha256: executable.sha256,
        executableByteLength: executable.byteLength,
        executablePosixMode: executable.posixMode,
        policyIdentity: _darwinConfinementPolicyIdentity(),
      );
    } on _ResolutionSignal {
      throw const L10nProcessConfinementException(
        'host-confinement-authority-invalid',
      );
    }
  }

  @override
  L10nConfinedCommand confine({
    required L10nProcessConfinementAuthority expectedAuthority,
    required String sandboxRoot,
    required String? writableRoot,
    required String executable,
    required List<String> arguments,
  }) {
    final current = captureAuthority();
    if (!_sameConfinementAuthority(current, expectedAuthority)) {
      throw const L10nProcessConfinementException(
        'host-confinement-authority-drift',
      );
    }
    final canonicalSandbox = _canonicalConfinementRoot(sandboxRoot);
    final canonicalWritable = writableRoot == null
        ? null
        : _canonicalConfinementRoot(writableRoot);
    if (!p.isAbsolute(executable) || executable.contains('\u0000')) {
      throw const L10nProcessConfinementException(
        'confinement-command-invalid',
      );
    }
    final profile = canonicalWritable == null
        ? _darwinProbeProfile
        : _darwinGenerationProfile;
    return L10nConfinedCommand(
      executable: current.requestedExecutable,
      arguments: [
        '-D',
        'SANDBOX_ROOT=$canonicalSandbox',
        if (canonicalWritable != null) ...[
          '-D',
          'WRITE_ROOT=$canonicalWritable',
        ],
        '-p',
        profile,
        executable,
        ...List<String>.of(arguments),
      ],
    );
  }
}

/// Single-use owned root lease created by the frozen toolchain boundary.
///
/// Task 9 materializes fresh copied bytes only beneath [directory], then calls
/// [seal] before Task 10 can request generation.
///
/// A concurrently hostile same-UID process can still mutate pathname state
/// between scans; callers must not expose the lease to such an actor. The OS
/// boundary closes child-process network and cross-root writes, not that
/// trusted in-process/concurrent-host threat boundary.
final class L10nGenerationRootLease {
  L10nGenerationRootLease._({
    required this.directory,
    required _CanonicalSdk sdk,
    required _HostPathIdentity rootIdentity,
  }) : _sdk = sdk,
       _rootIdentity = rootIdentity;

  /// Unique canonical 0700 system-temporary root owned by this lease.
  final Directory directory;

  final _CanonicalSdk _sdk;
  final _HostPathIdentity _rootIdentity;
  bool _sealed = false;
  bool _unsafeToDelete = false;
  bool _cleanupConsumed = false;

  /// Whether later cleanup may still remove the owned root.
  bool get safeToDelete => !_unsafeToDelete;

  /// Marks the root diagnostic residue after process/identity uncertainty.
  void markUnsafeToDelete() {
    _unsafeToDelete = true;
  }

  /// Deletes this exact owned root once, after identity and tree validation.
  void cleanup() {
    if (_cleanupConsumed) {
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-consumed',
      );
    }
    _cleanupConsumed = true;
    if (_unsafeToDelete) {
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-unconfirmed',
      );
    }
    try {
      _captureGenerationTree(
        directory.path,
        statAuthority: _sdk.statAuthority,
        expectedRootIdentity: _rootIdentity,
        requireExactRootMode: true,
      );
      directory.deleteSync(recursive: true);
      if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const _GenerationRootSignal(
          'generation-working-root-cleanup-unconfirmed',
        );
      }
    } on _GenerationRootSignal {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-unconfirmed',
      );
    } on _ResolutionSignal {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-unconfirmed',
      );
    } on FileSystemException {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-unconfirmed',
      );
    } catch (_) {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-cleanup-unconfirmed',
      );
    }
  }

  /// Freezes exact pre-generation inventory and proves no hard links exist.
  L10nGenerationWorkingRoot seal() {
    if (_sealed) {
      throw const L10nToolchainLaunchException(
        'generation-working-root-lease-consumed',
      );
    }
    _sealed = true;
    try {
      final snapshot = _captureGenerationTree(
        directory.path,
        statAuthority: _sdk.statAuthority,
        expectedRootIdentity: _rootIdentity,
        requireExactRootMode: true,
      );
      return L10nGenerationWorkingRoot._(lease: this, frozenSnapshot: snapshot);
    } on _GenerationRootSignal catch (signal) {
      _unsafeToDelete = true;
      throw L10nToolchainLaunchException(signal.detailCode);
    } on _ResolutionSignal {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-inventory-unavailable',
      );
    } on FileSystemException {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-inventory-unavailable',
      );
    } catch (_) {
      _unsafeToDelete = true;
      throw const L10nToolchainLaunchException(
        'generation-working-root-inventory-unavailable',
      );
    }
  }
}

/// Sealed single-use generation capability accepted by
/// [L10nToolchainLaunch.runGeneration].
final class L10nGenerationWorkingRoot {
  L10nGenerationWorkingRoot._({
    required L10nGenerationRootLease lease,
    required _GenerationTreeSnapshot frozenSnapshot,
  }) : _lease = lease,
       _frozenSnapshot = frozenSnapshot;

  final L10nGenerationRootLease _lease;
  final _GenerationTreeSnapshot _frozenSnapshot;
  bool _consumed = false;

  /// Canonical owned directory exposed for inventory consumers.
  Directory get directory => _lease.directory;

  /// Whether Task 9 cleanup may remove this root.
  bool get safeToDelete => _lease.safeToDelete;

  void _consumeAndValidate(_CanonicalSdk sdk) {
    if (_consumed) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'generation-working-root-capability-consumed',
      );
    }
    _consumed = true;
    if (!identical(_lease._sdk, sdk) &&
        !_sameCanonicalSdkAuthority(_lease._sdk, sdk)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'generation-working-root-authority-drift',
      );
    }
    late final _GenerationTreeSnapshot current;
    try {
      current = _captureGenerationTree(
        directory.path,
        statAuthority: sdk.statAuthority,
        expectedRootIdentity: _lease._rootIdentity,
        requireExactRootMode: true,
      );
    } on _GenerationRootSignal catch (signal) {
      _lease.markUnsafeToDelete();
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: signal.detailCode,
      );
    }
    if (!_sameGenerationTreeSnapshot(current, _frozenSnapshot)) {
      _lease.markUnsafeToDelete();
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'generation-working-root-inventory-drift',
      );
    }
  }

  void _validatePostRun(_CanonicalSdk sdk) {
    try {
      _captureGenerationTree(
        directory.path,
        statAuthority: sdk.statAuthority,
        expectedRootIdentity: _lease._rootIdentity,
        requireExactRootMode: true,
      );
    } catch (_) {
      _lease.markUnsafeToDelete();
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'generation-working-root-postcondition-failed',
      );
    }
  }

  void _markUnsafeToDelete() => _lease.markUnsafeToDelete();
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
  }) : canonicalOriginalProjectRoot = null,
       _frozenSdk = null;

  L10nToolchainLaunch._bound({
    required this.canonicalDartExecutable,
    required this.canonicalFlutterToolsPackageConfig,
    required this.canonicalFlutterToolsSnapshot,
    required this.canonicalOriginalProjectRoot,
    required _CanonicalSdk frozenSdk,
  }) : _frozenSdk = frozenSdk;

  /// Canonical bundled Dart executable invoked for every toolchain process.
  final String canonicalDartExecutable;

  /// Canonical Flutter-tools package configuration frozen as cache provenance.
  ///
  /// The precompiled snapshot is launched without `--packages`; external
  /// package roots and pubspecs are path/content provenance controls, not
  /// runtime source-execution authority.
  final String canonicalFlutterToolsPackageConfig;

  /// Canonical Flutter-tools snapshot passed to Dart.
  final String canonicalFlutterToolsSnapshot;

  /// Canonical frozen original project root for generation separation.
  final String? canonicalOriginalProjectRoot;

  final _CanonicalSdk? _frozenSdk;

  /// Creates the only root lease accepted by [runGeneration].
  L10nGenerationRootLease createGenerationRootLease() {
    final sdk = _frozenSdk;
    if (sdk == null) {
      throw const L10nToolchainLaunchException('frozen-launch-drift');
    }
    try {
      return _createGenerationRootLease(sdk);
    } on _GenerationRootSignal catch (signal) {
      throw L10nToolchainLaunchException(signal.detailCode);
    } on _ResolutionSignal {
      throw const L10nToolchainLaunchException(
        'generation-working-root-unavailable',
      );
    } catch (_) {
      throw const L10nToolchainLaunchException(
        'generation-working-root-unavailable',
      );
    }
  }

  List<String> _physicalArgumentsFor(Iterable<String> logicalArguments) =>
      List<String>.unmodifiable([
        canonicalFlutterToolsSnapshot,
        ...List<String>.of(logicalArguments),
      ]);

  /// Runs generation through the same isolated, revalidated snapshot seam.
  Future<ManagedProcessResult> runGeneration({
    required L10nGenerationWorkingRoot workingRoot,
    required L10nToolchainResolved expected,
    required List<String> logicalArguments,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    var processAttempted = false;
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
      final frozenSdk = _frozenSdk;
      if (frozenSdk == null) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'frozen-launch-drift',
        );
      }
      final sdk = _canonicalSdkFor(
        expected.canonicalFlutterExecutable,
        processConfinement: frozenSdk.processConfinement,
        executionRunner: frozenSdk.executionRunner,
        testExecutionRunner: frozenSdk.testExecutionRunner,
        canonicalOriginalProjectRoot: frozenSdk.originalProjectRoot,
      );
      final canonicalWorkingDirectory = _canonicalSandboxProtectedDirectory(
        workingRoot.directory.path,
        role: 'generation-run',
      );
      if (_rootsOverlap(canonicalWorkingDirectory, sdk.originalProjectRoot) ||
          _rootsOverlap(canonicalWorkingDirectory, sdk.root)) {
        throw const _ResolutionSignal(
          code: L10nEvidenceRejectionCode.toolchainUnavailable,
          detailCode: 'generation-working-root-unsupported',
        );
      }
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
      workingRoot._consumeAndValidate(sdk);
      processAttempted = true;
      var terminationUnconfirmed = false;
      try {
        final result = await _runSnapshotProcess(
          processRunner: frozenSdk.executionRunner,
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
        if (signal.detailCode == 'generation-run-termination-unconfirmed') {
          terminationUnconfirmed = true;
          workingRoot._markUnsafeToDelete();
        }
        rethrow;
      } finally {
        if (!terminationUnconfirmed) workingRoot._validatePostRun(sdk);
      }
    } on _ResolutionSignal catch (signal) {
      throw L10nToolchainLaunchException(signal.detailCode);
    } catch (_) {
      if (processAttempted) workingRoot._markUnsafeToDelete();
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

/// Default fail-closed resolver with a frozen production managed runner.
///
/// The Dart process is an in-process trust boundary: production offers no
/// runner or confinement injection, while the explicit test-only constructor
/// freezes an exact marker runner that only composes guarded argv.
final class DefaultL10nToolchainResolver implements L10nToolchainResolver {
  /// Creates the production resolver with its non-injectable managed runner.
  const DefaultL10nToolchainResolver()
    : _processRunner = const ManagedProcessRunner(),
      _processConfinement = const DefaultL10nProcessConfinementBackend(),
      _testExecutionRunner = null;

  /// Creates a resolver for unit tests that only compose guarded argv.
  ///
  /// A launch resolved here is frozen to the identical marker runner and
  /// cannot later execute through a production managed runner.
  DefaultL10nToolchainResolver.testing({
    required L10nTestProcessRunner processRunner,
    required L10nProcessConfinementBackend processConfinement,
  }) : _processRunner = processRunner,
       _processConfinement = processConfinement,
       _testExecutionRunner = processRunner {
    if (processRunner is ManagedProcessRunner) {
      throw ArgumentError.value(
        processRunner,
        'processRunner',
        'must not be a production managed runner',
      );
    }
  }

  final ProcessExecutionRunner _processRunner;
  final L10nProcessConfinementBackend _processConfinement;
  final L10nTestProcessRunner? _testExecutionRunner;

  @override
  Future<L10nToolchainResolution> resolve({
    required Directory originalProjectRoot,
    required L10nSdkRegistry sdkRegistry,
    required L10nToolchainSelection selection,
  }) async {
    try {
      _requireProductionConfinementAvailable();
      final workingDirectory = _validatedProjectRoot(originalProjectRoot);
      final canonicalProject = Directory(workingDirectory);
      final selected = switch (selection) {
        ProjectSelectorSelection() => _projectSelection(
          canonicalProject,
          sdkRegistry,
        ),
        RetainedEvidenceSelection() => _retainedSelection(
          selection,
          sdkRegistry,
        ),
      };
      final sdk = _canonicalSdkFor(
        selected.registeredExecutable,
        processConfinement: _processConfinement,
        executionRunner: _processRunner,
        testExecutionRunner: _testExecutionRunner,
        canonicalOriginalProjectRoot: workingDirectory,
      );
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
          canonicalProject,
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
    try {
      _requireProductionConfinementAvailable();
    } on _ResolutionSignal catch (signal) {
      return _changed(signal.detailCode);
    }
    if (!_validFrozenCommands(expected)) {
      return _changed('frozen-command-drift');
    }
    try {
      final workingDirectory = _validatedProjectRoot(originalProjectRoot);
      final canonicalProject = Directory(workingDirectory);
      final expectedVersion = expected.machineIdentity.frameworkVersion;
      if (!_isSupportedVersion(expectedVersion) ||
          !_isCompleteIdentity(expected.machineIdentity)) {
        return _changed('frozen-identity-invalid');
      }

      late final Map<String, String> selectorHashes;
      if (expected.selection is ProjectSelectorSelection) {
        final selector = _readProjectSelectors(canonicalProject);
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
        sdk = _canonicalSdkFor(
          expected.canonicalFlutterExecutable,
          processConfinement: _processConfinement,
          executionRunner: _processRunner,
          testExecutionRunner: _testExecutionRunner,
          canonicalOriginalProjectRoot: workingDirectory,
        );
      } on _ResolutionSignal catch (signal) {
        if (_isGitIdentityDetail(signal.detailCode)) {
          return _changed(signal.detailCode, relativePath: signal.relativePath);
        }
        return _changed(switch (signal.detailCode) {
          'registry-executable-unavailable' => 'canonical-executable-drift',
          'os-confinement-unsupported' => signal.detailCode,
          _ => 'canonical-sdk-drift',
        });
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
          canonicalProject,
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

  void _requireProductionConfinementAvailable() {
    if (_testExecutionRunner != null) return;
    try {
      _processConfinement.captureAuthority();
    } on L10nProcessConfinementException catch (error) {
      throw _ResolutionSignal(
        code: error.detailCode == 'os-confinement-unsupported'
            ? L10nEvidenceRejectionCode.unsupportedConfiguration
            : L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: error.detailCode,
      );
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
    final confined = sdk.processConfinement.confine(
      expectedAuthority: sdk.confinementAuthority,
      sandboxRoot: sandbox.root.path,
      writableRoot: role == 'generation-run' ? canonicalWorkingDirectory : null,
      executable: launch.canonicalDartExecutable,
      arguments: launch._physicalArgumentsFor(logicalArguments),
    );
    final result = await processRunner.run(
      confined.executable,
      confined.arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
      environmentOverrides: sandbox.environmentOverrides,
      includeParentEnvironment: false,
    );
    if (!_sameConfinementAuthority(
      sdk.processConfinement.captureAuthority(),
      sdk.confinementAuthority,
    )) {
      retainSandbox = true;
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-confinement-drift',
      );
    }
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
  } on L10nProcessConfinementException catch (error) {
    if (error.detailCode == 'host-confinement-authority-drift') {
      retainSandbox = true;
    }
    throw _ResolutionSignal(
      code: error.detailCode == 'os-confinement-unsupported'
          ? L10nEvidenceRejectionCode.unsupportedConfiguration
          : L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: error.detailCode == 'host-confinement-authority-drift'
          ? '$role-confinement-drift'
          : error.detailCode,
    );
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
  _requireHostExecutableStillMatches(sdk.statAuthority);
  Directory? root;
  _HostPathIdentity? createdIdentity;
  try {
    final systemTemp = Directory.systemTemp.absolute;
    final canonicalSystemTemp = p.normalize(
      systemTemp.resolveSymbolicLinksSync(),
    );
    final pubCache =
        sdk.launchManifest.packageResolutionAuthority.canonicalPubCache;
    if (_sandboxLocationConflicts(
          canonicalSystemTemp,
          canonicalWorkingDirectory,
        ) ||
        _sandboxLocationConflicts(canonicalSystemTemp, sdk.root) ||
        _sandboxLocationConflicts(canonicalSystemTemp, pubCache)) {
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
        _sandboxLocationConflicts(canonicalRoot, sdk.root) ||
        _sandboxLocationConflicts(canonicalRoot, pubCache)) {
      throw _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: '$role-sandbox-location-unsupported',
      );
    }
    root = Directory(canonicalRoot);
    createdIdentity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: sdk.statAuthority,
    );
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
    final rootIdentity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: sdk.statAuthority,
    );
    final whichIdentity = _captureHostPathIdentity(
      which.path,
      statAuthority: sdk.statAuthority,
    );
    if (rootIdentity.entityType != _HostPathEntityType.directory ||
        rootIdentity.posixMode != 0x1c0 ||
        whichIdentity.entityType != _HostPathEntityType.regularFile ||
        whichIdentity.posixMode != 0x1c0 ||
        whichIdentity.linkCount != 1 ||
        whichIdentity.device != rootIdentity.device) {
      throw const FormatException();
    }
    final sandbox = _ProbeSandbox(
      root: Directory(canonicalRoot),
      environmentOverrides: environment,
      whichCanonicalPath: p.normalize(which.resolveSymbolicLinksSync()),
      rootState: Directory(canonicalRoot).statSync(),
      whichState: which.statSync(),
      rootIdentity: rootIdentity,
      whichIdentity: whichIdentity,
      statAuthority: sdk.statAuthority,
    );
    _validateProbeSandbox(sandbox);
    _requireHostExecutableStillMatches(sdk.chmodAuthority);
    _requireHostExecutableStillMatches(sdk.shellAuthority);
    _requireHostExecutableStillMatches(sdk.statAuthority);
    return sandbox;
  } on _ResolutionSignal {
    _cleanupUnlaunchedProbeSandbox(
      root,
      role: role,
      expectedIdentity: createdIdentity,
      statAuthority: sdk.statAuthority,
    );
    rethrow;
  } on FileSystemException {
    _cleanupUnlaunchedProbeSandbox(
      root,
      role: role,
      expectedIdentity: createdIdentity,
      statAuthority: sdk.statAuthority,
    );
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-unavailable',
    );
  } on ProcessException {
    _cleanupUnlaunchedProbeSandbox(
      root,
      role: role,
      expectedIdentity: createdIdentity,
      statAuthority: sdk.statAuthority,
    );
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-unavailable',
    );
  } on FormatException {
    _cleanupUnlaunchedProbeSandbox(
      root,
      role: role,
      expectedIdentity: createdIdentity,
      statAuthority: sdk.statAuthority,
    );
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

bool _rootsOverlap(String left, String right) =>
    left == right || p.isWithin(left, right) || p.isWithin(right, left);

L10nGenerationRootLease _createGenerationRootLease(_CanonicalSdk sdk) {
  _requireHostExecutableStillMatches(sdk.chmodAuthority);
  _requireHostExecutableStillMatches(sdk.statAuthority);
  Directory? root;
  String? canonicalSystemTemp;
  _HostPathIdentity? createdIdentity;
  var returnedLease = false;
  try {
    canonicalSystemTemp = p.normalize(
      Directory.systemTemp.absolute.resolveSymbolicLinksSync(),
    );
    final pubCache =
        sdk.launchManifest.packageResolutionAuthority.canonicalPubCache;
    if (_sandboxLocationConflicts(
          canonicalSystemTemp,
          sdk.originalProjectRoot,
        ) ||
        _sandboxLocationConflicts(canonicalSystemTemp, sdk.root) ||
        _sandboxLocationConflicts(canonicalSystemTemp, pubCache)) {
      throw const _GenerationRootSignal(
        'generation-working-root-location-unsupported',
      );
    }
    root = Directory(
      canonicalSystemTemp,
    ).createTempSync('flutter-pruner-l10n-generation-');
    final canonicalRoot = p.normalize(root.resolveSymbolicLinksSync());
    if (!p.isWithin(canonicalSystemTemp, canonicalRoot) ||
        _rootsOverlap(canonicalRoot, sdk.originalProjectRoot) ||
        _rootsOverlap(canonicalRoot, sdk.root) ||
        _rootsOverlap(canonicalRoot, pubCache)) {
      throw const _GenerationRootSignal(
        'generation-working-root-location-unsupported',
      );
    }
    root = Directory(canonicalRoot);
    createdIdentity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: sdk.statAuthority,
    );
    final chmod = Process.runSync(
      sdk.chmodAuthority.canonicalPath,
      ['700', canonicalRoot],
      workingDirectory: canonicalSystemTemp,
      environment: const {'LANG': 'C', 'LC_ALL': 'C'},
      includeParentEnvironment: false,
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    );
    if (chmod.exitCode != 0) {
      throw const _GenerationRootSignal('generation-working-root-unavailable');
    }
    _requireHostExecutableStillMatches(sdk.chmodAuthority);
    _requireHostExecutableStillMatches(sdk.statAuthority);
    final identity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: sdk.statAuthority,
    );
    if (identity.entityType != _HostPathEntityType.directory ||
        identity.posixMode != 0x1c0) {
      throw const _GenerationRootSignal('generation-working-root-unavailable');
    }
    final lease = L10nGenerationRootLease._(
      directory: Directory(canonicalRoot),
      sdk: sdk,
      rootIdentity: identity,
    );
    returnedLease = true;
    return lease;
  } on _GenerationRootSignal {
    rethrow;
  } on FileSystemException {
    throw const _GenerationRootSignal('generation-working-root-unavailable');
  } on ProcessException {
    throw const _GenerationRootSignal('generation-working-root-unavailable');
  } finally {
    if (!returnedLease && root != null && canonicalSystemTemp != null) {
      try {
        if (createdIdentity == null) {
          throw const _GenerationRootSignal(
            'generation-working-root-creation-cleanup-unconfirmed',
          );
        }
        final canonicalRoot = p.normalize(root.resolveSymbolicLinksSync());
        final currentIdentity = _captureHostPathIdentity(
          canonicalRoot,
          statAuthority: sdk.statAuthority,
        );
        if (!p.isWithin(canonicalSystemTemp, canonicalRoot) ||
            !_sameGenerationRootIdentity(currentIdentity, createdIdentity)) {
          throw const _GenerationRootSignal(
            'generation-working-root-creation-cleanup-unconfirmed',
          );
        }
        Directory(canonicalRoot).deleteSync(recursive: true);
        if (FileSystemEntity.typeSync(canonicalRoot, followLinks: false) !=
            FileSystemEntityType.notFound) {
          throw const _GenerationRootSignal(
            'generation-working-root-creation-cleanup-unconfirmed',
          );
        }
      } catch (_) {
        throw const _GenerationRootSignal(
          'generation-working-root-creation-cleanup-unconfirmed',
        );
      }
    }
  }
}

String _darwinConfinementPolicyIdentity() {
  final hasher = _FramedIdentityHasher();
  hasher.addText('schema', 'darwin-sandbox-exec-policy-v1');
  hasher.addText('probeProfile', _darwinProbeProfile);
  hasher.addText('generationProfile', _darwinGenerationProfile);
  hasher.addText('sandboxParameter', 'SANDBOX_ROOT');
  hasher.addText('generationParameter', 'WRITE_ROOT');
  return hasher.digest();
}

String _canonicalConfinementRoot(String path) {
  try {
    final normalized = p.normalize(path);
    if (!p.isAbsolute(normalized) ||
        path.contains('\u0000') ||
        FileSystemEntity.typeSync(normalized, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const FormatException();
    }
    final canonical = p.normalize(
      Directory(normalized).resolveSymbolicLinksSync(),
    );
    if (canonical != normalized) throw const FormatException();
    return canonical;
  } on FileSystemException {
    throw const L10nProcessConfinementException('confinement-root-invalid');
  } on FormatException {
    throw const L10nProcessConfinementException('confinement-root-invalid');
  }
}

bool _sameConfinementAuthority(
  L10nProcessConfinementAuthority left,
  L10nProcessConfinementAuthority right,
) =>
    left.backendIdentity == right.backendIdentity &&
    left.requestedExecutable == right.requestedExecutable &&
    left.requestedExecutableType == right.requestedExecutableType &&
    left.canonicalExecutable == right.canonicalExecutable &&
    left.executableSha256 == right.executableSha256 &&
    left.executableByteLength == right.executableByteLength &&
    left.executablePosixMode == right.executablePosixMode &&
    left.policyIdentity == right.policyIdentity;

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
  } on _ResolutionSignal {
    throw _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: '$role-sandbox-cleanup-unconfirmed',
    );
  }
}

void _validateProbeSandbox(_ProbeSandbox sandbox) {
  final rootPath = p.normalize(sandbox.root.absolute.path);
  final rootBefore = sandbox.root.statSync();
  final rootIdentityBefore = _captureHostPathIdentity(
    rootPath,
    statAuthority: sandbox.statAuthority,
  );
  if (FileSystemEntity.typeSync(rootPath, followLinks: false) !=
          FileSystemEntityType.directory ||
      p.normalize(sandbox.root.resolveSymbolicLinksSync()) != rootPath ||
      rootBefore.mode & 0xfff != 0x1c0 ||
      !_sameHostPathIdentity(rootIdentityBefore, sandbox.rootIdentity) ||
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
  final whichIdentityBefore = _captureHostPathIdentity(
    which.path,
    statAuthority: sandbox.statAuthority,
  );
  if (FileSystemEntity.typeSync(which.path, followLinks: false) !=
          FileSystemEntityType.file ||
      p.normalize(which.resolveSymbolicLinksSync()) !=
          sandbox.whichCanonicalPath ||
      before.mode & 0xfff != 0x1c0 ||
      !_sameHostPathIdentity(whichIdentityBefore, sandbox.whichIdentity) ||
      !_sameArtifactFileState(before, sandbox.whichState) ||
      !_sameBytes(which.readAsBytesSync(), _sandboxWhichBytes)) {
    throw const FormatException();
  }
  final after = which.statSync();
  final rootAfter = sandbox.root.statSync();
  final whichIdentityAfter = _captureHostPathIdentity(
    which.path,
    statAuthority: sandbox.statAuthority,
  );
  final rootIdentityAfter = _captureHostPathIdentity(
    rootPath,
    statAuthority: sandbox.statAuthority,
  );
  if (!_sameArtifactFileState(before, after) ||
      !_sameArtifactFileState(after, sandbox.whichState) ||
      !_sameHostPathIdentity(whichIdentityAfter, sandbox.whichIdentity) ||
      !_sameArtifactFileState(rootBefore, rootAfter) ||
      !_sameArtifactFileState(rootAfter, sandbox.rootState) ||
      !_sameHostPathIdentity(rootIdentityAfter, sandbox.rootIdentity)) {
    throw const FormatException();
  }
}

void _cleanupUnlaunchedProbeSandbox(
  Directory? root, {
  required String role,
  required _HostPathIdentity? expectedIdentity,
  required _HostExecutableAuthority statAuthority,
}) {
  if (root == null) return;
  try {
    if (expectedIdentity == null) throw const FormatException();
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
    final currentIdentity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: statAuthority,
    );
    if (!_sameGenerationRootIdentity(currentIdentity, expectedIdentity)) {
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
  } on _ResolutionSignal {
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
    current = _canonicalSdkFor(
      registeredExecutable,
      processConfinement: expected.processConfinement,
      executionRunner: expected.executionRunner,
      testExecutionRunner: expected.testExecutionRunner,
      canonicalOriginalProjectRoot: expected.originalProjectRoot,
    );
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
    left.originalProjectRoot == right.originalProjectRoot &&
    identical(left.executionRunner, right.executionRunner) &&
    identical(left.testExecutionRunner, right.testExecutionRunner) &&
    _sameCanonicalGitHead(left.gitHead, right.gitHead) &&
    _samePosixLaunchManifest(left.launchManifest, right.launchManifest) &&
    _sameHostExecutableAuthority(left.shellAuthority, right.shellAuthority) &&
    _sameHostExecutableAuthority(left.chmodAuthority, right.chmodAuthority) &&
    _sameHostExecutableAuthority(left.statAuthority, right.statAuthority) &&
    _sameConfinementAuthority(
      left.confinementAuthority,
      right.confinementAuthority,
    );

String _validatedProjectRoot(Directory originalProjectRoot) {
  try {
    final absolute = p.normalize(originalProjectRoot.absolute.path);
    if (FileSystemEntity.typeSync(absolute, followLinks: true) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException();
    }
    return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'project-root-unavailable',
    );
  }
}

_CanonicalSdk _canonicalSdkFor(
  String registeredExecutable, {
  required L10nProcessConfinementBackend processConfinement,
  required ProcessExecutionRunner executionRunner,
  required L10nTestProcessRunner? testExecutionRunner,
  required String canonicalOriginalProjectRoot,
}) {
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
    final pubCache =
        launchManifest.packageResolutionAuthority.canonicalPubCache;
    if (_rootsOverlap(pubCache, root) ||
        _rootsOverlap(pubCache, canonicalOriginalProjectRoot)) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-package-config-invalid',
      );
    }
    final shellAuthority = _captureHostExecutable('/bin/sh');
    final chmodAuthority = _captureHostExecutable('/bin/chmod');
    final statAuthority = _captureHostExecutable('/usr/bin/stat');
    final confinementAuthority = processConfinement.captureAuthority();
    final canonicalFlutter = launchManifest
        .entriesByRelativePath[p.join('bin', _flutterExecutableName)];
    if (canonicalFlutter == null ||
        canonicalFlutter.canonicalPath != executable) {
      throw const FormatException();
    }
    return _CanonicalSdk(
      executable: executable,
      root: root,
      originalProjectRoot: canonicalOriginalProjectRoot,
      gitHead: gitHead,
      launchManifest: launchManifest,
      shellAuthority: shellAuthority,
      chmodAuthority: chmodAuthority,
      statAuthority: statAuthority,
      processConfinement: processConfinement,
      confinementAuthority: confinementAuthority,
      executionRunner: executionRunner,
      testExecutionRunner: testExecutionRunner,
    );
  } on L10nProcessConfinementException catch (error) {
    throw _ResolutionSignal(
      code: error.detailCode == 'os-confinement-unsupported'
          ? L10nEvidenceRejectionCode.unsupportedConfiguration
          : L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: error.detailCode,
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
    final packageResolutionAuthority = _validateFlutterToolsPackageConfig(
      entries,
    );
    return _PosixLaunchManifest(
      entriesByRelativePath: entries,
      packageResolutionAuthority: packageResolutionAuthority,
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
  final currentPackageResolution = _validateFlutterToolsPackageConfig(
    sdk.launchManifest.entriesByRelativePath,
    expectedDartVersion: dartSdkVersion,
  );
  if (!_samePackageResolutionAuthority(
    currentPackageResolution,
    sdk.launchManifest.packageResolutionAuthority,
  )) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
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

_PackageResolutionAuthority _validateFlutterToolsPackageConfig(
  Map<String, _LaunchManifestEntry> entries, {
  String? expectedDartVersion,
}) {
  const invalid = _ResolutionSignal(
    code: L10nEvidenceRejectionCode.toolchainUnavailable,
    detailCode: 'registry-sdk-package-config-invalid',
  );
  final packageConfigEntry = _manifestFileEntry(
    entries,
    _flutterToolsPackageConfigPath,
  );
  final packageConfigBytes = _manifestFileContent(
    entries,
    _flutterToolsPackageConfigPath,
  );
  final parsed = ArbDocument.parse(packageConfigBytes);
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
    throw invalid;
  }
  final values = {
    for (final member in parsed.document.members)
      member.decodedKey: member.decodedValue,
  };
  final configVersion = values['configVersion'];
  final packagesMember = parsed.document.members.singleWhere(
    (member) => member.decodedKey == 'packages',
  );
  final generatorVersion = values['generatorVersion'];
  final pubCacheValue = values['pubCache'];
  if (configVersion is! int ||
      configVersion != 2 ||
      values['generator'] != 'pub' ||
      generatorVersion is! String ||
      !_isExactDartVersion(generatorVersion) ||
      pubCacheValue is! String ||
      (expectedDartVersion != null &&
          generatorVersion != expectedDartVersion)) {
    throw invalid;
  }
  final dartLanguage = _majorMinor(generatorVersion);
  final packageConfigPath = packageConfigEntry.canonicalPath;
  final flutterToolsRoot = p.normalize(p.dirname(p.dirname(packageConfigPath)));
  final sdkRoot = p.normalize(p.dirname(p.dirname(flutterToolsRoot)));
  final pubCache = _canonicalLocalFileUriDirectory(pubCacheValue);
  _requireCanonicalAuthorityDirectoryTree(pubCache, boundary: pubCache);
  final pubCacheMode = Directory(pubCache).statSync().mode & 0xfff;
  final rawRecords = _rawJsonArrayElements(
    packageConfigBytes.sublist(
      packagesMember.valueSpan.start,
      packagesMember.valueSpan.endExclusive,
    ),
  );
  if (rawRecords.isEmpty) throw invalid;
  final names = <String>{};
  var flutterToolsCount = 0;
  final externalRoots = <_PackageRootAuthority>[];
  for (final rawRecord in rawRecords) {
    final record = ArbDocument.parse(rawRecord);
    const recordKeys = {'name', 'rootUri', 'packageUri', 'languageVersion'};
    if (record is! ArbParseSuccess ||
        record.document.members.length != recordKeys.length ||
        !_sameStringSet(
          record.document.members.map((member) => member.decodedKey),
          recordKeys,
        )) {
      throw invalid;
    }
    final package = {
      for (final member in record.document.members)
        member.decodedKey: member.decodedValue,
    };
    final name = package['name'];
    final rootUri = package['rootUri'];
    final packageUri = package['packageUri'];
    final languageVersion = package['languageVersion'];
    if (name is! String ||
        !RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name) ||
        !names.add(name) ||
        rootUri is! String ||
        packageUri != 'lib/' ||
        languageVersion is! String ||
        !_validLanguageVersion(languageVersion, dartLanguage)) {
      throw invalid;
    }
    if (name == 'flutter_tools') {
      flutterToolsCount++;
      if (rootUri != '../' ||
          p.normalize(
                Uri.file(packageConfigPath).resolve(rootUri).toFilePath(),
              ) !=
              flutterToolsRoot) {
        throw invalid;
      }
      _requireCanonicalAuthorityDirectoryTree(
        flutterToolsRoot,
        boundary: sdkRoot,
      );
      _requirePackageLib(flutterToolsRoot, boundary: sdkRoot);
      continue;
    }
    final canonicalRoot = _canonicalLocalFileUriDirectory(rootUri);
    if (!p.isWithin(pubCache, canonicalRoot)) throw invalid;
    _requireCanonicalAuthorityDirectoryTree(canonicalRoot, boundary: pubCache);
    final rootMode = Directory(canonicalRoot).statSync().mode & 0xfff;
    final lib = _capturePackageLib(canonicalRoot, boundary: pubCache);
    final pubspec = _capturePackagePubspec(
      canonicalRoot,
      expectedPackageName: name,
    );
    externalRoots.add(
      _PackageRootAuthority(
        packageName: name,
        canonicalRoot: canonicalRoot,
        rootMode: rootMode,
        canonicalLib: lib.$1,
        libMode: lib.$2,
        pubspec: pubspec,
      ),
    );
  }
  if (flutterToolsCount != 1) throw invalid;
  externalRoots.sort((left, right) {
    final byName = left.packageName.compareTo(right.packageName);
    return byName != 0
        ? byName
        : left.canonicalRoot.compareTo(right.canonicalRoot);
  });
  return _PackageResolutionAuthority(
    canonicalPubCache: pubCache,
    pubCacheMode: pubCacheMode,
    externalRoots: externalRoots,
  );
}

bool _isExactDartVersion(String value) {
  try {
    return Version.parse(value).toString() == value;
  } on FormatException {
    return false;
  }
}

(int, int) _majorMinor(String value) {
  final version = Version.parse(value);
  return (version.major, version.minor);
}

bool _validLanguageVersion(String value, (int, int) maximum) {
  final match = RegExp(r'^(2|[3-9][0-9]*)\.(0|[1-9][0-9]*)$').firstMatch(value);
  if (match == null) return false;
  final candidate = (int.parse(match.group(1)!), int.parse(match.group(2)!));
  return candidate.$1 < maximum.$1 ||
      (candidate.$1 == maximum.$1 && candidate.$2 <= maximum.$2);
}

List<List<int>> _rawJsonArrayElements(List<int> bytes) {
  var start = 0;
  var end = bytes.length;
  while (start < end && _isJsonWhitespace(bytes[start])) {
    start++;
  }
  while (end > start && _isJsonWhitespace(bytes[end - 1])) {
    end--;
  }
  if (end - start < 2 || bytes[start] != 0x5b || bytes[end - 1] != 0x5d) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
  final result = <List<int>>[];
  var elementStart = start + 1;
  var objectDepth = 0;
  var arrayDepth = 0;
  var inString = false;
  var escaped = false;
  for (var index = start + 1; index < end - 1; index++) {
    final byte = bytes[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (byte == 0x5c) {
        escaped = true;
      } else if (byte == 0x22) {
        inString = false;
      }
      continue;
    }
    if (byte == 0x22) {
      inString = true;
    } else if (byte == 0x7b) {
      objectDepth++;
    } else if (byte == 0x7d) {
      objectDepth--;
    } else if (byte == 0x5b) {
      arrayDepth++;
    } else if (byte == 0x5d) {
      arrayDepth--;
    } else if (byte == 0x2c && objectDepth == 0 && arrayDepth == 0) {
      result.add(_trimJsonBytes(bytes, elementStart, index));
      elementStart = index + 1;
    }
    if (objectDepth < 0 || arrayDepth < 0) {
      throw const _ResolutionSignal(
        code: L10nEvidenceRejectionCode.toolchainUnavailable,
        detailCode: 'registry-sdk-package-config-invalid',
      );
    }
  }
  final last = _trimJsonBytes(bytes, elementStart, end - 1);
  if (last.isNotEmpty) result.add(last);
  if (inString || objectDepth != 0 || arrayDepth != 0) {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
  return result;
}

List<int> _trimJsonBytes(List<int> bytes, int start, int end) {
  while (start < end && _isJsonWhitespace(bytes[start])) {
    start++;
  }
  while (end > start && _isJsonWhitespace(bytes[end - 1])) {
    end--;
  }
  return bytes.sublist(start, end);
}

bool _isJsonWhitespace(int byte) =>
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d;

String _canonicalLocalFileUriDirectory(String raw) {
  try {
    final uri = Uri.parse(raw);
    if (raw.isEmpty ||
        uri.scheme != 'file' ||
        uri.host.isNotEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException();
    }
    final path = p.normalize(uri.toFilePath());
    if (!p.isAbsolute(path) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.directory ||
        Uri.file(path).toString() != raw) {
      throw const FormatException();
    }
    final canonical = p.normalize(Directory(path).resolveSymbolicLinksSync());
    if (canonical != path) throw const FormatException();
    return canonical;
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
}

void _requireCanonicalAuthorityDirectoryTree(
  String path, {
  required String boundary,
}) {
  try {
    if (path != boundary && !p.isWithin(boundary, path)) {
      throw const FormatException();
    }
    var current = boundary;
    _requireCanonicalPackageDirectory(current);
    for (final component in p.split(p.relative(path, from: boundary))) {
      if (component == '.') continue;
      current = p.join(current, component);
      _requireCanonicalPackageDirectory(current);
    }
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  } on FormatException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  }
}

void _requireCanonicalPackageDirectory(String path) {
  if (FileSystemEntity.typeSync(path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const FormatException();
  }
  final directory = Directory(path);
  final before = directory.statSync();
  final canonical = p.normalize(directory.resolveSymbolicLinksSync());
  final after = directory.statSync();
  if (canonical != p.normalize(path) ||
      before.type != FileSystemEntityType.directory ||
      before.mode & 0x12 != 0 ||
      !_sameArtifactFileState(before, after)) {
    throw const FormatException();
  }
}

String _requirePackageLib(String root, {required String boundary}) {
  final captured = _capturePackageLib(root, boundary: boundary);
  if (captured.$2 == null) throw const FormatException();
  return captured.$1;
}

(String, int?) _capturePackageLib(String root, {required String boundary}) {
  final lib = p.join(root, 'lib');
  if (!p.isWithin(root, lib)) throw const FormatException();
  final type = FileSystemEntity.typeSync(lib, followLinks: false);
  if (type == FileSystemEntityType.notFound) return (lib, null);
  if (type != FileSystemEntityType.directory) throw const FormatException();
  _requireCanonicalAuthorityDirectoryTree(lib, boundary: boundary);
  return (lib, Directory(lib).statSync().mode & 0xfff);
}

_PackagePubspecAuthority _capturePackagePubspec(
  String root, {
  required String expectedPackageName,
}) {
  try {
    final path = p.join(root, 'pubspec.yaml');
    if (!p.isWithin(root, path) ||
        FileSystemEntity.typeSync(path, followLinks: false) !=
            FileSystemEntityType.file) {
      throw const FormatException();
    }
    final file = File(path);
    final canonical = p.normalize(file.resolveSymbolicLinksSync());
    final before = file.statSync();
    final mode = before.mode & 0xfff;
    if (canonical != path ||
        before.type != FileSystemEntityType.file ||
        mode & 0x12 != 0) {
      throw const FormatException();
    }
    final bytes = file.readAsBytesSync();
    final decoded = loadYaml(utf8.decode(bytes));
    if (decoded is! YamlMap || decoded['name'] != expectedPackageName) {
      throw const FormatException();
    }
    final after = file.statSync();
    if (!_sameArtifactFileState(before, after) ||
        p.normalize(file.resolveSymbolicLinksSync()) != canonical) {
      throw const FormatException();
    }
    return _PackagePubspecAuthority(
      canonicalPath: canonical,
      sha256: sha256.convert(bytes).toString(),
      byteLength: bytes.length,
      posixMode: mode,
    );
  } on FileSystemException {
    throw const _ResolutionSignal(
      code: L10nEvidenceRejectionCode.toolchainUnavailable,
      detailCode: 'registry-sdk-package-config-invalid',
    );
  } on FormatException {
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
const _flutterToolsPubspecPath = 'packages/flutter_tools/pubspec.yaml';
const _flutterToolsPubspecLockPath = 'packages/flutter_tools/pubspec.lock';
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
  _flutterToolsPubspecPath,
  _flutterToolsPubspecLockPath,
};
const _controlInputPaths = <String>[
  _flutterToolsStampPath,
  _engineStampPath,
  _engineRealmPath,
  _engineDartSdkStampPath,
  _engineVersionPath,
  _flutterToolsPackageConfigPath,
  _flutterToolsPubspecPath,
  _flutterToolsPubspecLockPath,
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
    left.canonicalFlutterToolsSnapshot == right.canonicalFlutterToolsSnapshot &&
    left.canonicalOriginalProjectRoot == right.canonicalOriginalProjectRoot;

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
  hasher.addText(
    'executionDomain',
    sdk.testExecutionRunner == null ? 'production' : 'test-only',
  );
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
  hasher.addText(
    'executionDomain',
    sdk.testExecutionRunner == null ? 'production' : 'test-only',
  );
  _addLaunch(hasher, sdk.launch);
  _addHostAuthority(hasher, 'shellAuthority', sdk.shellAuthority);
  _addHostAuthority(hasher, 'chmodAuthority', sdk.chmodAuthority);
  _addHostAuthority(hasher, 'statAuthority', sdk.statAuthority);
  hasher.addText('statDialect', _hostStatDialectIdentity);
  _addConfinementAuthority(hasher, sdk.confinementAuthority);
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
  _addPackageResolutionAuthority(
    hasher,
    sdk.launchManifest.packageResolutionAuthority,
  );
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
  hasher.addText(
    'launch.canonicalOriginalProjectRoot',
    launch.canonicalOriginalProjectRoot ?? 'unbound',
  );
}

void _addPackageResolutionAuthority(
  _FramedIdentityHasher hasher,
  _PackageResolutionAuthority authority,
) {
  hasher.addText('packageConfig.pubCache', authority.canonicalPubCache);
  hasher.addText(
    'packageConfig.pubCacheMode',
    authority.pubCacheMode.toRadixString(8),
  );
  hasher.addText(
    'packageConfig.externalRootCount',
    authority.externalRoots.length.toString(),
  );
  for (final root in authority.externalRoots) {
    hasher.addText('packageConfig.packageName', root.packageName);
    hasher.addText('packageConfig.canonicalRoot', root.canonicalRoot);
    hasher.addText('packageConfig.rootMode', root.rootMode.toRadixString(8));
    hasher.addText('packageConfig.canonicalLib', root.canonicalLib);
    hasher.addText(
      'packageConfig.libMode',
      root.libMode?.toRadixString(8) ?? 'absent',
    );
    hasher.addText('packageConfig.pubspecPath', root.pubspec.canonicalPath);
    hasher.addText('packageConfig.pubspecSha256', root.pubspec.sha256);
    hasher.addText(
      'packageConfig.pubspecByteLength',
      root.pubspec.byteLength.toString(),
    );
    hasher.addText(
      'packageConfig.pubspecMode',
      root.pubspec.posixMode.toRadixString(8),
    );
  }
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

void _addConfinementAuthority(
  _FramedIdentityHasher hasher,
  L10nProcessConfinementAuthority authority,
) {
  hasher.addText('confinement.backendIdentity', authority.backendIdentity);
  hasher.addText(
    'confinement.requestedExecutable',
    authority.requestedExecutable,
  );
  hasher.addText(
    'confinement.requestedExecutableType',
    authority.requestedExecutableType == FileSystemEntityType.file
        ? 'regular-file'
        : 'symbolic-link',
  );
  hasher.addText(
    'confinement.canonicalExecutable',
    authority.canonicalExecutable,
  );
  hasher.addText('confinement.executableSha256', authority.executableSha256);
  hasher.addText(
    'confinement.executableByteLength',
    authority.executableByteLength.toString(),
  );
  hasher.addText(
    'confinement.executablePosixMode',
    authority.executablePosixMode.toRadixString(8),
  );
  hasher.addText('confinement.policyIdentity', authority.policyIdentity);
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
    required this.rootIdentity,
    required this.whichIdentity,
    required this.statAuthority,
  }) : environmentOverrides = _sortedUnmodifiableMap(environmentOverrides);

  final Directory root;
  final Map<String, String> environmentOverrides;
  final String whichCanonicalPath;
  final FileStat rootState;
  final FileStat whichState;
  final _HostPathIdentity rootIdentity;
  final _HostPathIdentity whichIdentity;
  final _HostExecutableAuthority statAuthority;
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
    required this.originalProjectRoot,
    required this.gitHead,
    required this.launchManifest,
    required this.shellAuthority,
    required this.chmodAuthority,
    required this.statAuthority,
    required this.processConfinement,
    required this.confinementAuthority,
    required this.executionRunner,
    required this.testExecutionRunner,
  });

  final String executable;
  final String root;
  final String originalProjectRoot;
  final _CanonicalGitHead gitHead;
  final _PosixLaunchManifest launchManifest;
  final _HostExecutableAuthority shellAuthority;
  final _HostExecutableAuthority chmodAuthority;
  final _HostExecutableAuthority statAuthority;
  final L10nProcessConfinementBackend processConfinement;
  final L10nProcessConfinementAuthority confinementAuthority;
  final ProcessExecutionRunner executionRunner;
  final L10nTestProcessRunner? testExecutionRunner;

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
    canonicalOriginalProjectRoot: originalProjectRoot,
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
    required this.packageResolutionAuthority,
  }) : entriesByRelativePath = Map<String, _LaunchManifestEntry>.unmodifiable(
         SplayTreeMap<String, _LaunchManifestEntry>.of(entriesByRelativePath),
       );

  final Map<String, _LaunchManifestEntry> entriesByRelativePath;
  final _PackageResolutionAuthority packageResolutionAuthority;
}

final class _PackageResolutionAuthority {
  _PackageResolutionAuthority({
    required this.canonicalPubCache,
    required this.pubCacheMode,
    required List<_PackageRootAuthority> externalRoots,
  }) : externalRoots = List.unmodifiable(externalRoots);

  final String canonicalPubCache;
  final int pubCacheMode;
  final List<_PackageRootAuthority> externalRoots;
}

final class _PackageRootAuthority {
  const _PackageRootAuthority({
    required this.packageName,
    required this.canonicalRoot,
    required this.rootMode,
    required this.canonicalLib,
    required this.libMode,
    required this.pubspec,
  });

  final String packageName;
  final String canonicalRoot;
  final int rootMode;
  final String canonicalLib;
  final int? libMode;
  final _PackagePubspecAuthority pubspec;
}

final class _PackagePubspecAuthority {
  const _PackagePubspecAuthority({
    required this.canonicalPath,
    required this.sha256,
    required this.byteLength,
    required this.posixMode,
  });

  final String canonicalPath;
  final String sha256;
  final int byteLength;
  final int posixMode;
}

bool _samePackageResolutionAuthority(
  _PackageResolutionAuthority left,
  _PackageResolutionAuthority right,
) {
  if (left.canonicalPubCache != right.canonicalPubCache ||
      left.pubCacheMode != right.pubCacheMode ||
      left.externalRoots.length != right.externalRoots.length) {
    return false;
  }
  for (var index = 0; index < left.externalRoots.length; index++) {
    final a = left.externalRoots[index];
    final b = right.externalRoots[index];
    if (a.packageName != b.packageName ||
        a.canonicalRoot != b.canonicalRoot ||
        a.rootMode != b.rootMode ||
        a.canonicalLib != b.canonicalLib ||
        a.libMode != b.libMode ||
        a.pubspec.canonicalPath != b.pubspec.canonicalPath ||
        a.pubspec.sha256 != b.pubspec.sha256 ||
        a.pubspec.byteLength != b.pubspec.byteLength ||
        a.pubspec.posixMode != b.pubspec.posixMode) {
      return false;
    }
  }
  return true;
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
  if (!_samePackageResolutionAuthority(
        left.packageResolutionAuthority,
        right.packageResolutionAuthority,
      ) ||
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

enum _HostPathEntityType { regularFile, directory }

final class _HostPathIdentity {
  const _HostPathIdentity({
    required this.entityType,
    required this.device,
    required this.inode,
    required this.linkCount,
    required this.posixMode,
    required this.byteLength,
  });

  final _HostPathEntityType entityType;
  final int device;
  final int inode;
  final int linkCount;
  final int posixMode;
  final int byteLength;
}

final class _GenerationTreeSnapshot {
  _GenerationTreeSnapshot({
    required this.rootIdentity,
    required Map<String, _GenerationTreeEntry> entriesByRelativePath,
  }) : entriesByRelativePath = Map.unmodifiable(
         SplayTreeMap<String, _GenerationTreeEntry>.of(entriesByRelativePath),
       );

  final _HostPathIdentity rootIdentity;
  final Map<String, _GenerationTreeEntry> entriesByRelativePath;
}

final class _GenerationTreeEntry {
  const _GenerationTreeEntry({required this.identity, required this.sha256});

  final _HostPathIdentity identity;
  final String? sha256;
}

_GenerationTreeSnapshot _captureGenerationTree(
  String rootPath, {
  required _HostExecutableAuthority statAuthority,
  required _HostPathIdentity expectedRootIdentity,
  required bool requireExactRootMode,
}) {
  try {
    _requireHostExecutableStillMatches(statAuthority);
    final canonicalRoot = p.normalize(
      Directory(rootPath).resolveSymbolicLinksSync(),
    );
    if (canonicalRoot != p.normalize(rootPath) ||
        FileSystemEntity.typeSync(canonicalRoot, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw const _GenerationRootSignal(
        'generation-working-root-identity-drift',
      );
    }
    final rootIdentity = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: statAuthority,
    );
    if (!_sameGenerationRootIdentity(rootIdentity, expectedRootIdentity) ||
        rootIdentity.entityType != _HostPathEntityType.directory ||
        (requireExactRootMode && rootIdentity.posixMode != 0x1c0)) {
      throw const _GenerationRootSignal(
        'generation-working-root-identity-drift',
      );
    }
    final entities = Directory(canonicalRoot).listSync(
      recursive: true,
      followLinks: false,
    )..sort((left, right) => left.path.compareTo(right.path));
    final entries = SplayTreeMap<String, _GenerationTreeEntry>();
    for (final entity in entities) {
      final normalized = p.normalize(entity.absolute.path);
      if (!p.isWithin(canonicalRoot, normalized)) {
        throw const _GenerationRootSignal(
          'generation-working-root-path-escape',
        );
      }
      final relative = p.relative(normalized, from: canonicalRoot);
      final type = FileSystemEntity.typeSync(normalized, followLinks: false);
      if (type != FileSystemEntityType.file &&
          type != FileSystemEntityType.directory) {
        throw const _GenerationRootSignal(
          'generation-working-root-link-unsupported',
        );
      }
      final canonical = p.normalize(entity.resolveSymbolicLinksSync());
      if (canonical != normalized || !p.isWithin(canonicalRoot, canonical)) {
        throw const _GenerationRootSignal(
          'generation-working-root-path-escape',
        );
      }
      final before = entity.statSync();
      final identityBefore = _captureHostPathIdentity(
        normalized,
        statAuthority: statAuthority,
      );
      final expectedType = type == FileSystemEntityType.file
          ? _HostPathEntityType.regularFile
          : _HostPathEntityType.directory;
      if (identityBefore.entityType != expectedType ||
          identityBefore.device != rootIdentity.device ||
          identityBefore.posixMode & 0x12 != 0) {
        throw const _GenerationRootSignal(
          'generation-working-root-mode-unsupported',
        );
      }
      String? contentSha256;
      if (expectedType == _HostPathEntityType.regularFile) {
        if (identityBefore.linkCount != 1) {
          throw const _GenerationRootSignal(
            'generation-working-root-hardlink-unsupported',
          );
        }
        contentSha256 = sha256
            .convert(File(normalized).readAsBytesSync())
            .toString();
      }
      final after = entity.statSync();
      final identityAfter = _captureHostPathIdentity(
        normalized,
        statAuthority: statAuthority,
      );
      if (!_sameArtifactFileState(before, after) ||
          !_sameHostPathIdentity(identityBefore, identityAfter)) {
        throw const _GenerationRootSignal(
          'generation-working-root-inventory-unstable',
        );
      }
      entries[relative] = _GenerationTreeEntry(
        identity: identityAfter,
        sha256: contentSha256,
      );
    }
    _requireHostExecutableStillMatches(statAuthority);
    final rootAfter = _captureHostPathIdentity(
      canonicalRoot,
      statAuthority: statAuthority,
    );
    if (!_sameGenerationRootIdentity(rootAfter, expectedRootIdentity)) {
      throw const _GenerationRootSignal(
        'generation-working-root-identity-drift',
      );
    }
    return _GenerationTreeSnapshot(
      rootIdentity: rootAfter,
      entriesByRelativePath: entries,
    );
  } on _GenerationRootSignal {
    rethrow;
  } on _ResolutionSignal {
    throw const _GenerationRootSignal(
      'generation-working-root-inventory-unavailable',
    );
  } on FileSystemException {
    throw const _GenerationRootSignal(
      'generation-working-root-inventory-unavailable',
    );
  } on ProcessException {
    throw const _GenerationRootSignal(
      'generation-working-root-inventory-unavailable',
    );
  } on FormatException {
    throw const _GenerationRootSignal(
      'generation-working-root-inventory-unavailable',
    );
  }
}

_HostPathIdentity _captureHostPathIdentity(
  String path, {
  required _HostExecutableAuthority statAuthority,
}) {
  _requireHostExecutableStillMatches(statAuthority);
  final arguments = switch (_hostStatDialectIdentity) {
    'darwin-stat-v1' => ['-f', '%HT\t%d\t%i\t%l\t%p\t%z', path],
    'gnu-linux-stat-v1' => ['--printf=%F\t%d\t%i\t%h\t%a\t%s', '--', path],
    _ => throw const FormatException(),
  };
  final result = Process.runSync(
    statAuthority.canonicalPath,
    arguments,
    workingDirectory: p.dirname(path),
    environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    includeParentEnvironment: false,
    stdoutEncoding: utf8,
    stderrEncoding: utf8,
  );
  _requireHostExecutableStillMatches(statAuthority);
  if (result.exitCode != 0 || result.stderr != '') {
    throw const FormatException();
  }
  final fields = (result.stdout as String).trim().split('\t');
  if (fields.length != 6) throw const FormatException();
  final entityType = switch (fields[0]) {
    'Regular File' ||
    'regular file' ||
    'regular empty file' => _HostPathEntityType.regularFile,
    'Directory' || 'directory' => _HostPathEntityType.directory,
    _ => throw const FormatException(),
  };
  return _HostPathIdentity(
    entityType: entityType,
    device: int.parse(fields[1]),
    inode: int.parse(fields[2]),
    linkCount: int.parse(fields[3]),
    posixMode: int.parse(fields[4], radix: 8) & 0xfff,
    byteLength: int.parse(fields[5]),
  );
}

String get _hostStatDialectIdentity {
  if (Platform.isMacOS) return 'darwin-stat-v1';
  if (Platform.isLinux) return 'gnu-linux-stat-v1';
  return 'unsupported-stat-v1';
}

bool _sameHostPathIdentity(_HostPathIdentity left, _HostPathIdentity right) =>
    left.entityType == right.entityType &&
    left.device == right.device &&
    left.inode == right.inode &&
    left.linkCount == right.linkCount &&
    left.posixMode == right.posixMode &&
    left.byteLength == right.byteLength;

bool _sameGenerationRootIdentity(
  _HostPathIdentity left,
  _HostPathIdentity right,
) =>
    left.entityType == right.entityType &&
    left.device == right.device &&
    left.inode == right.inode &&
    left.posixMode == right.posixMode;

bool _sameGenerationTreeSnapshot(
  _GenerationTreeSnapshot left,
  _GenerationTreeSnapshot right,
) {
  if (!_sameHostPathIdentity(left.rootIdentity, right.rootIdentity) ||
      left.entriesByRelativePath.length != right.entriesByRelativePath.length) {
    return false;
  }
  for (final entry in left.entriesByRelativePath.entries) {
    final other = right.entriesByRelativePath[entry.key];
    if (other == null ||
        !_sameHostPathIdentity(entry.value.identity, other.identity) ||
        entry.value.sha256 != other.sha256) {
      return false;
    }
  }
  return true;
}

final class _GenerationRootSignal implements Exception {
  const _GenerationRootSignal(this.detailCode);

  final String detailCode;
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
