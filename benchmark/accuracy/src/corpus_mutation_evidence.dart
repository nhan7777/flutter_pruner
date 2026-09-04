/// Disposable complete-corpus mutation evidence for the private l10n harness.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;

import 'l10n_mutation_manifest.dart';

const _defaultTimeout = Duration(minutes: 20);
const _defaultOutputLimit = 4 * 1024 * 1024;
const _ownedPrefix = 'flutter-pruner-corpus-view-';
const _markerName = '.flutter-pruner-corpus-owner';
const _managedFingerprintSchema = 'corpus-managed-files-v1';
const _policyFingerprintSchema = 'corpus-policy-v1';
const _protectedFingerprintSchema = 'corpus-protected-authority-v1';
const _viewFingerprintSchema = 'corpus-project-view-v1';
const _normalizationManifestSha256ByProject = <String, String>{
  'gsy': '00c994f3fa48fc40ff1a1a35e8ea3fd0011ca3801da2e75acfa297009c761c59',
  'gitjournal':
      '5df0eacb70a4a69769eeadc0626329c636ababcb6cb1a8d0bf3fb3504a7c568c',
  'smooth': 'd3a92834a95694fe22cb3c1c00934150fba63a93085381b86f138bf4b5aa53ca',
};
const _gsyNormalizedPaths = <String>[
  'lib/common/localization/l10n/app_en.arb',
  'lib/common/localization/l10n/app_ja.arb',
  'lib/common/localization/l10n/app_ko.arb',
  'lib/common/localization/l10n/app_zh.arb',
];
const _gitjournalNormalizedPaths = <String>[
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
];
const _gitjournalArbPaths = <String>[
  'lib/l10n/app_de.arb',
  'lib/l10n/app_en.arb',
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
];
const _flutterPubEphemeralPaths = <String>[
  'ios/Flutter/ephemeral/flutter_lldb_helper.py',
  'ios/Flutter/ephemeral/flutter_lldbinit',
];

/// Final state of one complete-corpus mutation transaction.
enum CorpusMutationEvidenceStatus {
  /// Every command passed, managed files were restored byte-for-byte with
  /// their modes, and raw Git/protected authority remained equivalent.
  passed,

  /// Installation/policy failed, then managed files and authority were proven.
  fullPolicyFailed,

  /// Restoration or its proof failed and authoritatively overrides policy.
  restorationFailed,

  /// The disposable exact-revision project view could not be provisioned.
  provisioningFailed,
}

/// Redaction-safe evidence from one corpus mutation transaction.
final class CorpusMutationEvidenceOutcome {
  CorpusMutationEvidenceOutcome({
    required this.status,
    required this.candidateIdentity,
    required this.familyIdentity,
    required this.installedChangeSetHash,
    required this.policyHash,
    required List<Map<String, Object?>> commandResults,
    required this.beforeManagedFingerprint,
    required this.afterManagedFingerprint,
    required this.restorationVerified,
  }) : commandResults = List<Map<String, Object?>>.unmodifiable(
         commandResults.map(_deepFreezeMap),
       ) {
    _requireRedactedIdentity(candidateIdentity, 'candidateIdentity');
    _requireRedactedIdentity(familyIdentity, 'familyIdentity');
    for (final identity in <String>[
      installedChangeSetHash,
      policyHash,
      beforeManagedFingerprint,
      afterManagedFingerprint,
    ]) {
      if (!_isSha256(identity)) {
        throw ArgumentError('Corpus evidence hashes must be SHA-256 values.');
      }
    }
    for (final result in this.commandResults) {
      _validateCommandResult(result);
    }
    if (this.commandResults.isEmpty) {
      throw ArgumentError(
        'Corpus evidence must contain a command or gate result.',
      );
    }
    final allCommandsPassed = this.commandResults.every(
      (result) => _isPassingProcessResult(result),
    );
    switch (status) {
      case CorpusMutationEvidenceStatus.passed:
        if (!allCommandsPassed) {
          throw ArgumentError('Passed corpus evidence contains a failed gate.');
        }
        if (!restorationVerified ||
            beforeManagedFingerprint != afterManagedFingerprint) {
          throw ArgumentError(
            'A completed corpus transaction requires managed-file '
            'restoration and authority equivalence.',
          );
        }
        break;
      case CorpusMutationEvidenceStatus.fullPolicyFailed:
        if (allCommandsPassed) {
          throw ArgumentError(
            'Failed corpus evidence contains no failed gate.',
          );
        }
        if (!restorationVerified ||
            beforeManagedFingerprint != afterManagedFingerprint) {
          throw ArgumentError(
            'A completed corpus transaction requires managed-file '
            'restoration and authority equivalence.',
          );
        }
        break;
      case CorpusMutationEvidenceStatus.restorationFailed:
      case CorpusMutationEvidenceStatus.provisioningFailed:
        if (restorationVerified) {
          throw ArgumentError(
            'A failed restoration/provisioning cannot be verified restored.',
          );
        }
        break;
    }
  }

  final CorpusMutationEvidenceStatus status;
  final String candidateIdentity;
  final String familyIdentity;
  final String installedChangeSetHash;
  final String policyHash;
  final List<Map<String, Object?>> commandResults;
  final String beforeManagedFingerprint;
  final String afterManagedFingerprint;
  final bool restorationVerified;
}

/// One provisioned, privately owned complete project copy.
final class CorpusProjectView {
  CorpusProjectView({
    required this.repositoryRoot,
    required this.packageRoot,
    required this.repositoryRevision,
    required this.provisionedBaselineFingerprint,
    required this.baselineGitStatusIdentity,
    CorpusProjectViewLease? cleanupLease,
    String? protectedAuthorityFingerprint,
    String? toolchainProbeIdentity,
    String? projectBindingIdentity,
    String? policyIdentity,
    List<int>? rawBaselineGitStatus,
    Map<String, String>? overlayTargetLogicalFingerprints,
    Map<String, String>? overlayTargetPhysicalFingerprints,
  }) : _cleanupLease = cleanupLease,
       _protectedAuthorityFingerprint = protectedAuthorityFingerprint,
       _toolchainProbeIdentity = toolchainProbeIdentity,
       _projectBindingIdentity = projectBindingIdentity,
       _policyIdentity = policyIdentity,
       _rawBaselineGitStatus = rawBaselineGitStatus == null
           ? null
           : Uint8List.fromList(rawBaselineGitStatus),
       _overlayTargetLogicalFingerprints = Map<String, String>.unmodifiable(
         overlayTargetLogicalFingerprints ?? const {},
       ),
       _overlayTargetPhysicalFingerprints = Map<String, String>.unmodifiable(
         overlayTargetPhysicalFingerprints ?? const {},
       ) {
    if (!_isGitSha(repositoryRevision) ||
        !_isSha256(provisionedBaselineFingerprint) ||
        !_isSha256(baselineGitStatusIdentity)) {
      throw ArgumentError('Corpus project view identities are malformed.');
    }
    if (_overlayTargetLogicalFingerprints.keys.toSet().length !=
            _overlayTargetPhysicalFingerprints.keys.toSet().length ||
        !_overlayTargetLogicalFingerprints.keys.every(
          _overlayTargetPhysicalFingerprints.containsKey,
        )) {
      throw ArgumentError('Corpus overlay authorities are inconsistent.');
    }
    for (final entry in _overlayTargetLogicalFingerprints.entries) {
      if (!_isSafeRelativePath(entry.key) ||
          !_isSha256(entry.value) ||
          !_isSha256(_overlayTargetPhysicalFingerprints[entry.key]!)) {
        throw ArgumentError('Corpus overlay authority is malformed.');
      }
    }
  }

  final Directory repositoryRoot;
  final Directory packageRoot;
  final String repositoryRevision;
  final String provisionedBaselineFingerprint;
  final String baselineGitStatusIdentity;
  final CorpusProjectViewLease? _cleanupLease;
  final String? _protectedAuthorityFingerprint;
  final String? _toolchainProbeIdentity;
  final String? _projectBindingIdentity;
  final String? _policyIdentity;
  final Uint8List? _rawBaselineGitStatus;
  final Map<String, String> _overlayTargetLogicalFingerprints;
  Map<String, String> _overlayTargetPhysicalFingerprints;
  _CorpusProjectViewLifecycle _lifecycle = _CorpusProjectViewLifecycle.ready;

  /// Whether an unconfirmed writer or failed restoration forbids reuse/delete.
  bool get isPoisoned =>
      _lifecycle == _CorpusProjectViewLifecycle.deletionUnsafe;

  /// Deletes only the privately owned view, after owner-marker verification.
  Future<bool> dispose() async {
    if (_lifecycle == _CorpusProjectViewLifecycle.disposed) return true;
    if (_lifecycle == _CorpusProjectViewLifecycle.running ||
        _lifecycle == _CorpusProjectViewLifecycle.disposing ||
        _lifecycle == _CorpusProjectViewLifecycle.deletionUnsafe ||
        _cleanupLease == null) {
      return false;
    }
    final previous = _lifecycle;
    _lifecycle = _CorpusProjectViewLifecycle.disposing;
    final disposed = await _cleanupLease.dispose();
    _lifecycle = disposed ? _CorpusProjectViewLifecycle.disposed : previous;
    return disposed;
  }

  bool _beginRun() {
    if (_lifecycle != _CorpusProjectViewLifecycle.ready) return false;
    _lifecycle = _CorpusProjectViewLifecycle.running;
    return true;
  }

  void _finishRun({required bool reusable, bool poison = false}) {
    if (poison || _lifecycle == _CorpusProjectViewLifecycle.deletionUnsafe) {
      _lifecycle = _CorpusProjectViewLifecycle.deletionUnsafe;
    } else {
      _lifecycle = reusable
          ? _CorpusProjectViewLifecycle.ready
          : _CorpusProjectViewLifecycle.nonReusable;
    }
  }

  void _refreshManagedOverlayPhysicalAuthority(
    Directory repository,
    Set<String> managedPaths,
  ) {
    final refreshed = Map<String, String>.from(
      _overlayTargetPhysicalFingerprints,
    );
    for (final path in managedPaths) {
      if (refreshed.containsKey(path)) {
        refreshed[path] = _entityFingerprint(
          repository,
          path,
          includePhysical: true,
        );
      }
    }
    _overlayTargetPhysicalFingerprints = Map.unmodifiable(refreshed);
  }
}

enum _CorpusProjectViewLifecycle {
  ready,
  running,
  nonReusable,
  disposing,
  disposed,
  deletionUnsafe,
}

/// Safe lifecycle authority for one factory-owned disposable root.
abstract interface class CorpusProjectViewLease {
  Future<bool> dispose();
}

/// Result of provisioning a disposable corpus project view.
sealed class CorpusProjectViewCreationResult {
  const CorpusProjectViewCreationResult();
}

/// Provisioning completed and returned exclusive view ownership.
final class CorpusProjectViewReady extends CorpusProjectViewCreationResult {
  const CorpusProjectViewReady(this.view);

  final CorpusProjectView view;
}

/// Provisioning rejected without exposing private locations or output.
final class CorpusProjectViewRejected extends CorpusProjectViewCreationResult {
  const CorpusProjectViewRejected(this.outcome);

  final CorpusMutationEvidenceOutcome outcome;
}

/// Creates exact-revision disposable project views without network access.
abstract interface class CorpusProjectViewFactory {
  Future<CorpusProjectViewCreationResult> create({
    required L10nMutationProjectManifest project,
    required String retainedRepositoryPath,
    required String canonicalFlutterExecutable,
  });
}

/// Selects a system-temporary base; owned code creates the final child itself.
typedef CorpusTemporaryDirectoryFactory = Directory Function(String prefix);

/// Defensive validator for argv-only canonical Flutter verification policies.
final class CorpusVerificationPolicyValidator {
  const CorpusVerificationPolicyValidator();

  /// Validates a raw command independently of manifest-parser validation.
  void validateRaw({
    required String workingDirectoryRelativeToRepository,
    required List<String> argumentsAfterCanonicalFlutter,
  }) {
    if (!_isSafeWorkingDirectory(workingDirectoryRelativeToRepository)) {
      throw ArgumentError.value(
        workingDirectoryRelativeToRepository,
        'workingDirectoryRelativeToRepository',
      );
    }
    if (argumentsAfterCanonicalFlutter.isEmpty) {
      throw ArgumentError('A verification command must not be empty.');
    }
    final command = argumentsAfterCanonicalFlutter.first;
    if (command != 'analyze' && command != 'test' && command != 'build') {
      throw ArgumentError.value(command, 'argumentsAfterCanonicalFlutter');
    }
    if (!argumentsAfterCanonicalFlutter.contains('--no-pub')) {
      throw ArgumentError('Every corpus verification command needs --no-pub.');
    }
    if (command == 'build' && argumentsAfterCanonicalFlutter.length < 3) {
      throw ArgumentError('A build policy must declare its build target.');
    }
    const forbiddenWords = <String>{
      'bash',
      'cmd',
      'dart',
      'fvm',
      'gen-l10n',
      'packages',
      'powershell',
      'pub',
      'pwsh',
      'sh',
      'zsh',
    };
    const shellTokens = <String>{'&&', '||', '|', ';', '>', '>>', '<'};
    for (final argument in argumentsAfterCanonicalFlutter) {
      if (argument.isEmpty ||
          argument.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
          forbiddenWords.contains(argument.toLowerCase()) ||
          shellTokens.contains(argument) ||
          argument == '--' ||
          argument == '--pub' ||
          argument.startsWith('--pub=') ||
          _argumentEscapesRepository(argument) ||
          argument.contains(r'$(') ||
          argument.contains('`')) {
        throw ArgumentError.value(argument, 'argumentsAfterCanonicalFlutter');
      }
    }
  }

  void _validateProject(L10nMutationProjectManifest project) {
    if (project.verificationPolicy.isEmpty) {
      throw ArgumentError('The complete corpus policy must not be empty.');
    }
    final identities = <String>{};
    for (final command in project.verificationPolicy) {
      validateRaw(
        workingDirectoryRelativeToRepository:
            command.workingDirectoryRelativeToRepository,
        argumentsAfterCanonicalFlutter: command.argumentsAfterCanonicalFlutter,
      );
      if (!identities.add(command.identity)) {
        throw ArgumentError('Duplicate corpus command identity.');
      }
    }
    final expectedManifest = switch (project.id) {
      'gsy' => 'gsy-normalized-family-v2.json',
      'gitjournal' => 'gitjournal-normalized-family-v1.json',
      'smooth'
          when project.repositoryRevision ==
              'bac71afd115f72e379c0b501b95e5ede20ecd636' =>
        'smooth-normalized-family-v2.json',
      _ => null,
    };
    final expectedPaths = switch (project.id) {
      'gsy' => _gsyNormalizedPaths,
      'gitjournal' => _gitjournalArbPaths,
      'smooth' => project.arbPathsRelative,
      _ => null,
    };
    if (expectedManifest == null) {
      if (project.normalizationOverlays.isNotEmpty) {
        throw ArgumentError(
          'Normalization is not authorized for ${project.id}.',
        );
      }
    } else if (project.normalizationOverlays.length != 1 ||
        project.normalizationOverlays.single.manifest != expectedManifest ||
        project.normalizationOverlays.single.policy !=
            'apply-declared-byte-transforms' ||
        !_sameStrings(project.arbPathsRelative, expectedPaths!)) {
      throw ArgumentError(
        '${project.id} requires its complete frozen normalization.',
      );
    }
  }
}

/// Exact install/restore operations, separated for deterministic fault tests.
abstract interface class CorpusManagedFileOperations {
  Future<void> installCandidate({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  });

  Future<void> restoreBefore({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  });
}

/// Real byte/mode-exact regular-file replacement operations.
final class DefaultCorpusManagedFileOperations
    implements CorpusManagedFileOperations {
  const DefaultCorpusManagedFileOperations();

  @override
  Future<void> installCandidate({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  }) => _replaceExisting(
    repositoryRoot: repositoryRoot,
    relativePath: replacement.relativePath,
    expectedBytes: replacement.beforeBytes,
    desiredBytes: replacement.afterBytes,
    expectedMode: replacement.beforeMode,
    desiredMode: replacement.afterMode,
  );

  @override
  Future<void> restoreBefore({
    required Directory repositoryRoot,
    required L10nFileReplacement replacement,
  }) => _replaceExisting(
    repositoryRoot: repositoryRoot,
    relativePath: replacement.relativePath,
    expectedBytes: replacement.afterBytes,
    desiredBytes: replacement.beforeBytes,
    expectedMode: replacement.afterMode,
    desiredMode: replacement.beforeMode,
    allowAnyCurrentState: true,
  );
}

/// Runs one witnessed change set inside a provisioned complete corpus view.
abstract interface class CorpusMutationEvidenceRunner {
  Future<CorpusMutationEvidenceOutcome> run({
    required L10nMutationProjectManifest project,
    required CorpusProjectView view,
    required String canonicalFlutterExecutable,
    required L10nWitnessedChangeSet changeSet,
    required String candidateIdentity,
    required String familyIdentity,
  });
}

/// Default local-clone factory with one pre-baseline offline resolution.
final class DefaultCorpusProjectViewFactory
    implements CorpusProjectViewFactory {
  DefaultCorpusProjectViewFactory({
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
    CorpusVerificationPolicyValidator policyValidator =
        const CorpusVerificationPolicyValidator(),
    CorpusTemporaryDirectoryFactory? temporaryDirectoryFactory,
    Directory? manifestDirectory,
    L10nNormalizationManifest Function(
      L10nMutationProjectManifest,
      L10nNormalizationOverlay,
    )?
    normalizationManifestLoaderForTesting,
    String? gitExecutable,
    Duration commandTimeout = _defaultTimeout,
    int maxOutputBytesPerStream = _defaultOutputLimit,
  }) : _processRunner = processRunner,
       _policyValidator = policyValidator,
       _temporaryDirectoryFactory =
           temporaryDirectoryFactory ?? _systemTemporaryBase,
       _manifestDirectory =
           manifestDirectory ??
           Directory(p.join('benchmark', 'accuracy', 'manifests')),
       _normalizationManifestLoaderForTesting =
           normalizationManifestLoaderForTesting,
       _gitExecutable = gitExecutable ?? _platformGitExecutable,
       _commandTimeout = commandTimeout,
       _maxOutputBytesPerStream = maxOutputBytesPerStream {
    if (commandTimeout <= Duration.zero || maxOutputBytesPerStream <= 0) {
      throw ArgumentError('Corpus process bounds must be positive.');
    }
  }

  final ProcessExecutionRunner _processRunner;
  final CorpusVerificationPolicyValidator _policyValidator;
  final CorpusTemporaryDirectoryFactory _temporaryDirectoryFactory;
  final Directory _manifestDirectory;
  final L10nNormalizationManifest Function(
    L10nMutationProjectManifest,
    L10nNormalizationOverlay,
  )?
  _normalizationManifestLoaderForTesting;
  final String _gitExecutable;
  final Duration _commandTimeout;
  final int _maxOutputBytesPerStream;

  @override
  Future<CorpusProjectViewCreationResult> create({
    required L10nMutationProjectManifest project,
    required String retainedRepositoryPath,
    required String canonicalFlutterExecutable,
  }) async {
    _OwnedProjectViewLease? lease;
    var failureStatus = 'provisioningFailed';
    try {
      _policyValidator._validateProject(project);
      final retained = _canonicalLocalDirectory(retainedRepositoryPath);
      final flutter = _canonicalFlutter(canonicalFlutterExecutable);
      final manifestDirectory = _manifestDirectory.absolute;
      final fixtureSources = _preflightFixtureSources(project, retained);
      lease = _OwnedProjectViewLease.create(
        _temporaryDirectoryFactory,
        disjointDirectories: [
          retained,
          if (fixtureSources.isNotEmpty)
            _canonicalDirectoryEntry(retained.parent),
          flutter.parent.parent,
          if (manifestDirectory.existsSync()) manifestDirectory,
        ],
      );
      final gitEnvironment = _isolatedGitEnvironment();
      final flutterIdentityBefore = _fileFingerprint(
        flutter,
        includePhysical: true,
      );
      final toolchainProbeBefore = await _probeToolchain(
        flutter,
        project,
        processRunner: _processRunner,
        timeout: _commandTimeout,
        maxOutputBytesPerStream: _maxOutputBytesPerStream,
      );
      if (flutterIdentityBefore !=
          _fileFingerprint(flutter, includePhysical: true)) {
        failureStatus = 'toolchainDrift';
        throw const _CorpusGateException();
      }

      final retainedGitControlBefore = _retainedGitControlFingerprint(retained);
      final retainedStatusBefore = await _gitStatus(
        retained,
        environment: gitEnvironment,
      );
      if (_retainedGitControlFingerprint(retained) !=
          retainedGitControlBefore) {
        failureStatus = 'retainedRepositoryDrift';
        throw const _CorpusGateException();
      }
      final retainedHead = await _gitText(retained, const [
        'rev-parse',
        'HEAD',
      ], environment: gitEnvironment);
      if (retainedHead != project.repositoryRevision ||
          _retainedGitControlFingerprint(retained) !=
              retainedGitControlBefore) {
        failureStatus = retainedHead == project.repositoryRevision
            ? 'retainedRepositoryDrift'
            : 'repositoryRevisionDrift';
        throw const _CorpusGateException();
      }
      var repository = Directory(p.join(lease.root.path, 'repository'));
      await _requireGitSuccess(
        [
          'clone',
          '--no-local',
          '--no-hardlinks',
          '--no-checkout',
          '--no-tags',
          '--',
          retained.path,
          repository.path,
        ],
        workingDirectory: lease.root,
        environment: gitEnvironment,
      );
      if (File(
        p.join(repository.path, '.git', 'objects', 'info', 'alternates'),
      ).existsSync()) {
        failureStatus = 'cloneSharesObjectAuthority';
        throw const _CorpusGateException();
      }
      await _requireGitSuccess(
        [
          '-C',
          repository.path,
          'checkout',
          '--detach',
          '--force',
          project.repositoryRevision,
        ],
        workingDirectory: lease.root,
        environment: gitEnvironment,
      );
      final checkedOutHead = await _gitText(repository, const [
        'rev-parse',
        'HEAD',
      ], environment: gitEnvironment);
      if (checkedOutHead != project.repositoryRevision) {
        failureStatus = 'checkoutRevisionDrift';
        throw const _CorpusGateException();
      }
      await _requireGitSuccess(
        ['-C', repository.path, 'remote', 'remove', 'origin'],
        workingDirectory: lease.root,
        environment: gitEnvironment,
      );
      final remotes = await _gitText(repository, const [
        'remote',
      ], environment: gitEnvironment);
      final gitConfig = _readRegularFile(
        File(p.join(repository.path, '.git', 'config')),
      ).bytes;
      if (remotes.isNotEmpty ||
          utf8
              .decode(gitConfig.copy(), allowMalformed: true)
              .contains(retained.path)) {
        failureStatus = 'cloneRetainedAuthority';
        throw const _CorpusGateException();
      }
      repository = _canonicalDirectoryEntry(repository);
      final expectedRepositoryPath = repository.path;
      lease.captureAuthority();
      _validateToolchainSelectionEvidence(
        project,
        repository,
        allowAuthorizedReplacement: true,
      );

      final packageRoot = _existingDirectoryWithin(
        repository,
        project.packageRootRelative,
      );
      final expectedPackagePath = packageRoot.path;
      final overlayPlan = _preflightOverlayWrites(
        project,
        retained,
        repository,
        fixtureSources,
      );
      for (final write in overlayPlan.fixtureWrites) {
        await _installOverlay(repository, write);
      }

      if (!_factoryViewAuthorityCurrent(
        lease: lease,
        repository: repository,
        packageRoot: packageRoot,
        expectedRepositoryPath: expectedRepositoryPath,
        expectedPackagePath: expectedPackagePath,
      )) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }
      final repositoryGitControlBeforePub = _retainedGitControlFingerprint(
        repository,
      );
      final packageLockRelative = p
          .relative(
            p.join(packageRoot.path, 'pubspec.lock'),
            from: repository.path,
          )
          .replaceAll('\\', '/');
      final flutterPubEphemeralPaths = <String>[
        for (final relativePath in _flutterPubEphemeralPaths)
          p
              .relative(
                p.join(packageRoot.path, relativePath),
                from: repository.path,
              )
              .replaceAll('\\', '/'),
      ];
      final trackedFlutterPubEphemeralPaths = (await _gitText(
        repository,
        ['ls-files', '--', ...flutterPubEphemeralPaths],
        environment: gitEnvironment,
      )).split('\n').where((entry) => entry.isNotEmpty).toSet();
      final generatedFlutterPubEphemeralPaths = flutterPubEphemeralPaths
          .where(
            (relativePath) =>
                !trackedFlutterPubEphemeralPaths.contains(relativePath),
          )
          .toList(growable: false);
      for (final relativePath in generatedFlutterPubEphemeralPaths) {
        if (FileSystemEntity.typeSync(
              _joinWithin(repository, relativePath),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw const _CorpusGateException();
        }
      }
      final sourceStatusBeforePub = await _gitStatus(
        repository,
        environment: gitEnvironment,
        excludedRelativePaths: [
          packageLockRelative,
          ...generatedFlutterPubEphemeralPaths,
        ],
      );
      if (_retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub ||
          !_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          )) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }

      final pubGet = await _processRunner.run(
        flutter.path,
        const ['pub', 'get', '--offline'],
        workingDirectory: packageRoot.path,
        timeout: _commandTimeout,
        maxOutputBytesPerStream: _maxOutputBytesPerStream,
      );
      if (!_processPassed(pubGet)) {
        if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
          stderr
            ..writeln(utf8.decode(pubGet.stdout.capturedPayload))
            ..writeln(utf8.decode(pubGet.stderr.capturedPayload));
        }
        failureStatus = _processStatus(pubGet);
        throw const _CorpusGateException();
      }
      if (!_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          ) ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }
      _validateToolchainSelectionEvidence(project, repository);
      if (flutterIdentityBefore !=
          _fileFingerprint(flutter, includePhysical: true)) {
        failureStatus = 'toolchainDrift';
        throw const _CorpusGateException();
      }
      if (!_overlayTargetsStillMatch(repository, overlayPlan.fixtureWrites)) {
        failureStatus = 'overlayTargetDrift';
        throw const _CorpusGateException();
      }
      for (final relativePath in flutterPubEphemeralPaths) {
        final type = FileSystemEntity.typeSync(
          _joinWithin(repository, relativePath),
          followLinks: false,
        );
        if (type != FileSystemEntityType.notFound) {
          _readRegularFile(_regularFileWithin(repository, relativePath));
        }
      }
      final sourceStatusAfterPub = await _gitStatus(
        repository,
        environment: gitEnvironment,
        excludedRelativePaths: [
          packageLockRelative,
          ...generatedFlutterPubEphemeralPaths,
        ],
      );
      if (!_sameBytes(sourceStatusBeforePub, sourceStatusAfterPub) ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub ||
          !_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          )) {
        failureStatus = 'pubSourceDrift';
        throw const _CorpusGateException();
      }
      for (final write in overlayPlan.normalizationWrites) {
        await _installOverlay(repository, write);
      }
      for (final baseline in overlayPlan.generatedBaselines) {
        final baselineFailure = await _regenerateNormalizedGeneratedBaseline(
          repository: repository,
          packageRoot: packageRoot,
          flutter: flutter,
          baseline: baseline,
          processRunner: _processRunner,
          timeout: _commandTimeout,
          maxOutputBytesPerStream: _maxOutputBytesPerStream,
        );
        if (baselineFailure != null) {
          failureStatus = baselineFailure;
          throw const _CorpusGateException();
        }
      }
      final overlayWrites = overlayPlan.allWrites;
      final toolchainProbeAfter = await _probeToolchain(
        flutter,
        project,
        processRunner: _processRunner,
        timeout: _commandTimeout,
        maxOutputBytesPerStream: _maxOutputBytesPerStream,
      );
      if (toolchainProbeBefore != toolchainProbeAfter ||
          flutterIdentityBefore !=
              _fileFingerprint(flutter, includePhysical: true)) {
        failureStatus = 'toolchainDrift';
        throw const _CorpusGateException();
      }
      final toolchainProbe = toolchainProbeAfter;
      if (!_overlayTargetsStillMatch(repository, overlayWrites)) {
        failureStatus = 'overlayTargetDrift';
        throw const _CorpusGateException();
      }
      if (!_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          ) ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }

      failureStatus = 'retainedRepositoryDrift';
      if (_retainedGitControlFingerprint(retained) !=
              retainedGitControlBefore ||
          !_fixtureSourcesStillMatch(fixtureSources)) {
        throw const _CorpusGateException();
      }
      final retainedStatusAfter = await _gitStatus(
        retained,
        environment: gitEnvironment,
      );
      if (_retainedGitControlFingerprint(retained) !=
          retainedGitControlBefore) {
        throw const _CorpusGateException();
      }
      final retainedHeadAfter = await _gitText(retained, const [
        'rev-parse',
        'HEAD',
      ], environment: gitEnvironment);
      if (!_sameBytes(retainedStatusBefore, retainedStatusAfter) ||
          retainedHeadAfter != retainedHead ||
          _retainedGitControlFingerprint(retained) !=
              retainedGitControlBefore ||
          !_fixtureSourcesStillMatch(fixtureSources)) {
        throw const _CorpusGateException();
      }
      failureStatus = 'protectedAuthorityDrift';
      if (!_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          ) ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub) {
        throw const _CorpusGateException();
      }
      final finalHead = await _gitText(repository, const [
        'rev-parse',
        'HEAD',
      ], environment: gitEnvironment);
      if (finalHead != project.repositoryRevision ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub ||
          !_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          )) {
        if (finalHead != project.repositoryRevision) {
          failureStatus = 'repositoryRevisionDrift';
        }
        throw const _CorpusGateException();
      }
      final baselineStatus = await _gitStatus(
        repository,
        environment: gitEnvironment,
      );
      if (_retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub ||
          !_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          )) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }
      final baselineStatusIdentity = _sha256(baselineStatus);
      final protectedAuthority = _protectedAuthorityFingerprint(
        project: project,
        repository: repository,
        packageRoot: packageRoot,
        canonicalFlutter: flutter,
        toolchainProbeIdentity: toolchainProbe,
      );
      final overlayLogicalFingerprints = <String, String>{
        for (final write in overlayWrites)
          write.relativePath: _entityFingerprint(
            repository,
            write.relativePath,
          ),
      };
      final overlayPhysicalFingerprints = <String, String>{
        for (final write in overlayWrites)
          write.relativePath: _entityFingerprint(
            repository,
            write.relativePath,
            includePhysical: true,
          ),
      };
      failureStatus = 'retainedRepositoryDrift';
      if (!_fixtureSourcesStillMatch(fixtureSources)) {
        throw const _CorpusGateException();
      }
      failureStatus = 'protectedAuthorityDrift';
      if (!_factoryViewAuthorityCurrent(
            lease: lease,
            repository: repository,
            packageRoot: packageRoot,
            expectedRepositoryPath: expectedRepositoryPath,
            expectedPackagePath: expectedPackagePath,
          ) ||
          _retainedGitControlFingerprint(repository) !=
              repositoryGitControlBeforePub) {
        failureStatus = 'protectedAuthorityDrift';
        throw const _CorpusGateException();
      }
      final viewFingerprint = _hashFields([
        _viewFingerprintSchema,
        project.id,
        project.repositoryRevision,
        project.packageRootRelative,
        protectedAuthority,
        baselineStatusIdentity,
        _policyHash(project),
        lease.authorityIdentity!,
        for (final path in overlayLogicalFingerprints.keys.toList()..sort())
          '$path:${overlayLogicalFingerprints[path]}',
      ]);
      return CorpusProjectViewReady(
        CorpusProjectView(
          repositoryRoot: repository,
          packageRoot: packageRoot,
          repositoryRevision: project.repositoryRevision,
          provisionedBaselineFingerprint: viewFingerprint,
          baselineGitStatusIdentity: baselineStatusIdentity,
          cleanupLease: lease,
          protectedAuthorityFingerprint: protectedAuthority,
          toolchainProbeIdentity: toolchainProbe,
          projectBindingIdentity: _projectBindingIdentity(project),
          policyIdentity: _policyHash(project),
          rawBaselineGitStatus: baselineStatus,
          overlayTargetLogicalFingerprints: overlayLogicalFingerprints,
          overlayTargetPhysicalFingerprints: overlayPhysicalFingerprints,
        ),
      );
    } on ProcessTerminationUnconfirmedException {
      failureStatus = 'terminationUnconfirmed';
      lease?.poison();
      return CorpusProjectViewRejected(
        _provisioningOutcome(project, failureStatus),
      );
    } catch (error, stackTrace) {
      if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
        stderr
          ..writeln(error)
          ..writeln(stackTrace);
      }
      if (lease != null && !lease.isPoisoned) {
        if (!await lease.dispose()) failureStatus = 'cleanupFailed';
      }
      return CorpusProjectViewRejected(
        _provisioningOutcome(project, failureStatus),
      );
    }
  }

  Future<void> _requireGitSuccess(
    List<String> arguments, {
    required Directory workingDirectory,
    required Map<String, String> environment,
  }) async {
    final result = await _processRunner.run(
      _gitExecutable,
      _isolatedGitArguments(arguments),
      workingDirectory: workingDirectory.path,
      timeout: _commandTimeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
      environmentOverrides: environment,
      includeParentEnvironment: false,
    );
    if (!_processPassed(result)) throw const _CorpusGateException();
  }

  Future<Uint8List> _gitStatus(
    Directory repository, {
    required Map<String, String> environment,
    List<String> excludedRelativePaths = const [],
  }) async {
    if (excludedRelativePaths.any((path) => !_isSafeRelativePath(path)) ||
        excludedRelativePaths.toSet().length != excludedRelativePaths.length) {
      throw const _CorpusGateException();
    }
    final result = await _processRunner.run(
      _gitExecutable,
      _isolatedGitArguments([
        '-C',
        repository.path,
        'status',
        '--porcelain=v2',
        '-z',
        '--untracked-files=all',
        '--ignore-submodules=none',
        if (excludedRelativePaths.isNotEmpty) ...[
          '--',
          '.',
          for (final path in excludedRelativePaths)
            ':(exclude,top,literal)$path',
        ],
      ]),
      workingDirectory: repository.path,
      timeout: _commandTimeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
      environmentOverrides: environment,
      includeParentEnvironment: false,
    );
    if (!_processPassed(result)) throw const _CorpusGateException();
    return result.stdout.capturedPayload;
  }

  Future<String> _gitText(
    Directory repository,
    List<String> arguments, {
    required Map<String, String> environment,
  }) async {
    final result = await _processRunner.run(
      _gitExecutable,
      _isolatedGitArguments(['-C', repository.path, ...arguments]),
      workingDirectory: repository.path,
      timeout: _commandTimeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
      environmentOverrides: environment,
      includeParentEnvironment: false,
    );
    if (!_processPassed(result)) throw const _CorpusGateException();
    return utf8.decode(result.stdout.capturedPayload).trim();
  }

  _OverlayWritePlan _preflightOverlayWrites(
    L10nMutationProjectManifest project,
    Directory retained,
    Directory repository,
    List<_FixtureSource> fixtureSources,
  ) {
    final fixtureWrites = <_OverlayWrite>[];
    for (final source in fixtureSources) {
      final targetPath = _joinWithin(repository, source.overlay.relativePath);
      if (FileSystemEntity.typeSync(targetPath, followLinks: false) ==
          FileSystemEntityType.notFound) {
        fixtureWrites.add(
          _OverlayWrite.createNew(
            source.overlay.relativePath,
            source.bytes,
            source.mode,
          ),
        );
      } else {
        final target = _regularFileWithin(
          repository,
          source.overlay.relativePath,
        );
        final state = _readRegularFile(target);
        if (!state.bytes.contentEquals(source.bytes) ||
            state.mode != source.mode) {
          final evidence = project.toolchainSelectionEvidence;
          final authorizedSelectorReplacement =
              source.overlay.purpose == 'toolchain selector authority' &&
              source.overlay.relativePath == evidence['evidencePath'] &&
              source.overlay.sha256 == evidence['evidenceSha256'] &&
              state.mode == source.mode;
          if (!authorizedSelectorReplacement) {
            throw const _CorpusGateException();
          }
        }
        fixtureWrites.add(
          _OverlayWrite.replace(
            source.overlay.relativePath,
            state.bytes,
            source.bytes,
            state.mode,
          ),
        );
      }
    }
    final normalizationWrites = <_OverlayWrite>[];
    final generatedBaselines = <L10nNormalizedGeneratedBaseline>[];
    for (final overlay in project.normalizationOverlays) {
      final manifest = _loadNormalizationManifest(project, overlay);
      _validateNormalizationManifest(project, manifest);
      final embedded = overlay.normalizationManifest;
      if (embedded != null && !_sameNormalizationManifest(embedded, manifest)) {
        throw const _CorpusGateException();
      }
      if (manifest.generatedBaseline case final baseline?) {
        generatedBaselines.add(baseline);
      }
      for (final arb in manifest.changedArbs) {
        final file = _regularFileWithin(repository, arb.relativePath);
        final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
        if (bytes.sha256Hex != arb.originalSha256) {
          throw const _CorpusGateException();
        }
        final replacement = _applyDeclaredByteTransforms(
          bytes,
          arb.copiedByteSpans,
          arb.removedByteSpans,
        );
        if (replacement.sha256Hex != arb.replacementSha256 ||
            arb.replacementHasDuplicateDecodedKeys ||
            !_normalizationSemanticsMatch(
              bytes,
              replacement,
              arb.canonicalDecodedObjectSha256,
              decodedObjectEquivalent: arb.decodedObjectEquivalent,
            )) {
          throw const _CorpusGateException();
        }
        normalizationWrites.add(
          _OverlayWrite.replace(
            arb.relativePath,
            bytes,
            replacement,
            _posixMode(file),
          ),
        );
      }
    }
    final plan = _OverlayWritePlan(
      fixtureWrites: fixtureWrites,
      normalizationWrites: normalizationWrites,
      generatedBaselines: generatedBaselines,
    );
    _validateOverlayWriteSet(plan.allWrites);
    for (final write in plan.allWrites) {
      final targetPath = _joinWithin(repository, write.relativePath);
      final type = FileSystemEntity.typeSync(targetPath, followLinks: false);
      if (write.mustCreate) {
        if (type != FileSystemEntityType.notFound) {
          throw const _CorpusGateException();
        }
      } else {
        final target = _regularFileWithin(repository, write.relativePath);
        final state = _readRegularFile(target);
        if (!state.bytes.contentEquals(write.beforeBytes!) ||
            state.mode != write.mode) {
          throw const _CorpusGateException();
        }
      }
    }
    return plan;
  }

  L10nNormalizationManifest _loadNormalizationManifest(
    L10nMutationProjectManifest project,
    L10nNormalizationOverlay overlay,
  ) {
    final testingLoader = _normalizationManifestLoaderForTesting;
    if (testingLoader != null) return testingLoader(project, overlay);
    return _parseNormalizationManifest(
      File(_joinWithin(_manifestDirectory, overlay.manifest)),
      project,
    );
  }
}

bool _sameNormalizationManifest(
  L10nNormalizationManifest left,
  L10nNormalizationManifest right,
) {
  if (left.schemaVersion != right.schemaVersion ||
      left.normalizationVersion != right.normalizationVersion ||
      left.repositoryRevision != right.repositoryRevision ||
      left.policy != right.policy ||
      left.sourceSha256 != right.sourceSha256 ||
      left.changedArbs.length != right.changedArbs.length ||
      !_sameGeneratedBaseline(
        left.generatedBaseline,
        right.generatedBaseline,
      )) {
    return false;
  }
  for (var index = 0; index < left.changedArbs.length; index++) {
    final a = left.changedArbs[index];
    final b = right.changedArbs[index];
    if (a.relativePath != b.relativePath ||
        a.originalSha256 != b.originalSha256 ||
        a.replacementSha256 != b.replacementSha256 ||
        a.canonicalDecodedObjectSha256 != b.canonicalDecodedObjectSha256 ||
        a.decodedObjectEquivalent != b.decodedObjectEquivalent ||
        a.replacementHasDuplicateDecodedKeys !=
            b.replacementHasDuplicateDecodedKeys ||
        a.copiedByteSpans.length != b.copiedByteSpans.length ||
        a.removedByteSpans.length != b.removedByteSpans.length) {
      return false;
    }
    for (var span = 0; span < a.copiedByteSpans.length; span++) {
      if (a.copiedByteSpans[span].start != b.copiedByteSpans[span].start ||
          a.copiedByteSpans[span].endExclusive !=
              b.copiedByteSpans[span].endExclusive ||
          a.copiedByteSpans[span].sourceStart !=
              b.copiedByteSpans[span].sourceStart ||
          a.copiedByteSpans[span].sourceEndExclusive !=
              b.copiedByteSpans[span].sourceEndExclusive) {
        return false;
      }
    }
    for (var span = 0; span < a.removedByteSpans.length; span++) {
      if (a.removedByteSpans[span].start != b.removedByteSpans[span].start ||
          a.removedByteSpans[span].endExclusive !=
              b.removedByteSpans[span].endExclusive) {
        return false;
      }
    }
  }
  return true;
}

bool _sameGeneratedBaseline(
  L10nNormalizedGeneratedBaseline? left,
  L10nNormalizedGeneratedBaseline? right,
) {
  if (left == null || right == null) return left == null && right == null;
  if (left.changedOutputs.length != right.changedOutputs.length) return false;
  for (var index = 0; index < left.changedOutputs.length; index++) {
    final a = left.changedOutputs[index];
    final b = right.changedOutputs[index];
    if (a.relativePath != b.relativePath ||
        a.originalSha256 != b.originalSha256 ||
        a.replacementSha256 != b.replacementSha256 ||
        a.posixMode != b.posixMode) {
      return false;
    }
  }
  return true;
}

void _validateNormalizationManifest(
  L10nMutationProjectManifest project,
  L10nNormalizationManifest manifest,
) {
  final paths = manifest.changedArbs
      .map((arb) => arb.relativePath)
      .toList(growable: false);
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
  final expectedPaths = switch (project.id) {
    'gsy' => _gsyNormalizedPaths,
    'gitjournal' => _gitjournalNormalizedPaths,
    'smooth' => project.arbPathsRelative,
    _ => null,
  };
  final expectedFamilyPaths = switch (project.id) {
    'gsy' => _gsyNormalizedPaths,
    'gitjournal' => _gitjournalArbPaths,
    'smooth' => project.arbPathsRelative,
    _ => null,
  };
  final expectedHash = _normalizationManifestSha256ByProject[project.id];
  final expectedSchema = manifest.generatedBaseline == null ? 2 : 3;
  if (manifest.schemaVersion != expectedSchema ||
      manifest.normalizationVersion != expectedVersion ||
      manifest.repositoryRevision != project.repositoryRevision ||
      manifest.policy != expectedPolicy ||
      manifest.sourceSha256 != expectedHash ||
      expectedPaths == null ||
      !_sameStrings(paths, expectedPaths) ||
      expectedFamilyPaths == null ||
      !_sameStrings(project.arbPathsRelative, expectedFamilyPaths)) {
    throw const _CorpusGateException();
  }
  if (project.id == 'smooth' && manifest.generatedBaseline == null) {
    throw const _CorpusGateException();
  }
  final expectedEquivalent = project.id == 'gsy';
  for (final arb in manifest.changedArbs) {
    if (arb.decodedObjectEquivalent != expectedEquivalent ||
        arb.replacementHasDuplicateDecodedKeys ||
        !_isSha256(arb.originalSha256) ||
        !_isSha256(arb.replacementSha256) ||
        !_isSha256(arb.canonicalDecodedObjectSha256) ||
        (project.id == 'gsy' && arb.copiedByteSpans.isEmpty) ||
        (project.id != 'gsy' && arb.copiedByteSpans.isNotEmpty) ||
        arb.removedByteSpans.isEmpty) {
      throw const _CorpusGateException();
    }
    var previousCopyEnd = -1;
    for (final span in arb.copiedByteSpans) {
      if (span.start < 0 ||
          span.start < previousCopyEnd ||
          span.endExclusive <= span.start ||
          span.sourceStart < 0 ||
          span.sourceEndExclusive <= span.sourceStart) {
        throw const _CorpusGateException();
      }
      previousCopyEnd = span.endExclusive;
    }
    var previousEnd = -1;
    for (final span in arb.removedByteSpans) {
      if (span.start < 0 ||
          span.start < previousEnd ||
          span.endExclusive <= span.start) {
        throw const _CorpusGateException();
      }
      previousEnd = span.endExclusive;
    }
  }
  final generated = manifest.generatedBaseline;
  if (generated != null) {
    final packagePrefix = project.packageRootRelative == '.'
        ? ''
        : '${project.packageRootRelative}/';
    final arbPrefix = '${project.arbDirectoryRelative}/';
    for (final output in generated.changedOutputs) {
      if (!_isSafeRelativePath(output.relativePath) ||
          !output.relativePath.startsWith(packagePrefix) ||
          !output.relativePath.startsWith(arbPrefix) ||
          !output.relativePath.endsWith('.dart') ||
          !_isSha256(output.originalSha256) ||
          !_isSha256(output.replacementSha256) ||
          output.originalSha256 == output.replacementSha256 ||
          output.posixMode < 0 ||
          output.posixMode > 0xfff ||
          project.arbPathsRelative.contains(output.relativePath)) {
        throw const _CorpusGateException();
      }
    }
  }
}

bool _sameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

/// Default sequential evidence transaction over one provisioned view.
final class DefaultCorpusMutationEvidenceRunner
    implements CorpusMutationEvidenceRunner {
  DefaultCorpusMutationEvidenceRunner({
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
    CorpusManagedFileOperations fileOperations =
        const DefaultCorpusManagedFileOperations(),
    CorpusVerificationPolicyValidator policyValidator =
        const CorpusVerificationPolicyValidator(),
    String? gitExecutable,
    Duration commandTimeout = _defaultTimeout,
    int maxOutputBytesPerStream = _defaultOutputLimit,
  }) : _processRunner = processRunner,
       _fileOperations = fileOperations,
       _policyValidator = policyValidator,
       _gitExecutable = gitExecutable ?? _platformGitExecutable,
       _commandTimeout = commandTimeout,
       _maxOutputBytesPerStream = maxOutputBytesPerStream {
    if (commandTimeout <= Duration.zero || maxOutputBytesPerStream <= 0) {
      throw ArgumentError('Corpus process bounds must be positive.');
    }
  }

  final ProcessExecutionRunner _processRunner;
  final CorpusManagedFileOperations _fileOperations;
  final CorpusVerificationPolicyValidator _policyValidator;
  final String _gitExecutable;
  final Duration _commandTimeout;
  final int _maxOutputBytesPerStream;

  @override
  Future<CorpusMutationEvidenceOutcome> run({
    required L10nMutationProjectManifest project,
    required CorpusProjectView view,
    required String canonicalFlutterExecutable,
    required L10nWitnessedChangeSet changeSet,
    required String candidateIdentity,
    required String familyIdentity,
  }) async {
    _requireRedactedIdentity(candidateIdentity, 'candidateIdentity');
    _requireRedactedIdentity(familyIdentity, 'familyIdentity');
    final witnessed = L10nWitnessedChangeSet(
      arbReplacements: changeSet.arbReplacements,
      generatedReplacements: changeSet.generatedReplacements,
    );
    final replacements = <L10nFileReplacement>[
      ...witnessed.arbReplacements.values,
      ...witnessed.generatedReplacements.values,
    ]..sort((left, right) => left.relativePath.compareTo(right.relativePath));
    final replacementPaths = replacements
        .map((replacement) => replacement.relativePath)
        .toSet();
    if (witnessed.arbReplacements.isEmpty) {
      throw ArgumentError(
        'Corpus mutation evidence requires an ARB replacement.',
      );
    }
    _validateWitnessedAuthority(project, witnessed);
    final policyHash = _policyHash(project);
    final emptyFingerprint = _hashFields([_managedFingerprintSchema, 'empty']);
    final results = <Map<String, Object?>>[];

    if (!view._beginRun()) {
      results.add(_gateResult('view-busy-or-poisoned'));
      return _outcome(
        status: CorpusMutationEvidenceStatus.provisioningFailed,
        candidateIdentity: candidateIdentity,
        familyIdentity: familyIdentity,
        changeSetHash: witnessed.fingerprint,
        policyHash: policyHash,
        commandResults: results,
        beforeFingerprint: emptyFingerprint,
        afterFingerprint: emptyFingerprint,
        restorationVerified: false,
      );
    }

    var beforeFingerprint = emptyFingerprint;
    var afterFingerprint = emptyFingerprint;
    var policyFailed = false;
    var restorationVerified = false;
    var unconfirmed = false;
    final journal = <L10nFileReplacement>[];
    try {
      _policyValidator._validateProject(project);
      final repository = _canonicalExistingViewRoot(view.repositoryRoot);
      final packageRoot = _existingDirectoryWithin(
        repository,
        project.packageRootRelative,
      );
      if (!p.equals(
            packageRoot.path,
            view.packageRoot.resolveSymbolicLinksSync(),
          ) ||
          view.repositoryRevision != project.repositoryRevision ||
          view._projectBindingIdentity != _projectBindingIdentity(project) ||
          view._policyIdentity != policyHash ||
          view._protectedAuthorityFingerprint == null ||
          view._toolchainProbeIdentity == null ||
          view._rawBaselineGitStatus == null) {
        results.add(_gateResult('viewIdentityDrift'));
        return _finishEarly(
          view: view,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          results: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
        );
      }
      final flutter = _canonicalFlutter(canonicalFlutterExecutable);
      final preProbeProtected = _protectedAuthorityFingerprint(
        project: project,
        repository: repository,
        packageRoot: packageRoot,
        canonicalFlutter: flutter,
        toolchainProbeIdentity: view._toolchainProbeIdentity,
      );
      if (!_viewFilesystemAuthorityCurrent(project, view) ||
          !_overlayBaselinesCurrent(repository, view) ||
          preProbeProtected != view._protectedAuthorityFingerprint) {
        results.add(_gateResult('sourceDrift'));
        return _finishEarly(
          view: view,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          results: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
        );
      }
      final toolchainProbe = await _probeToolchain(
        flutter,
        project,
        processRunner: _processRunner,
        timeout: _commandTimeout,
        maxOutputBytesPerStream: _maxOutputBytesPerStream,
      );
      if (toolchainProbe != view._toolchainProbeIdentity) {
        results.add(_gateResult('toolchainDrift'));
        return _finishEarly(
          view: view,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          results: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
        );
      }
      final protectedBefore = _protectedAuthorityFingerprint(
        project: project,
        repository: repository,
        packageRoot: packageRoot,
        canonicalFlutter: flutter,
        toolchainProbeIdentity: toolchainProbe,
      );
      if (!_viewFilesystemAuthorityCurrent(project, view) ||
          !_overlayBaselinesCurrent(repository, view) ||
          protectedBefore != view._protectedAuthorityFingerprint) {
        results.add(_gateResult('toolchainDrift'));
        return _finishEarly(
          view: view,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          results: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
        );
      }

      beforeFingerprint = _managedFingerprint(repository, replacements);
      var sourceDrift = false;
      for (final replacement in replacements) {
        if (!_replacementMatchesBefore(repository, replacement)) {
          sourceDrift = true;
        }
      }
      if (sourceDrift ||
          !_viewFilesystemAuthorityCurrent(project, view) ||
          !_overlayBaselinesCurrent(repository, view) ||
          protectedBefore != view._protectedAuthorityFingerprint) {
        results.add(_gateResult('sourceDrift'));
        afterFingerprint = _managedFingerprint(repository, replacements);
        view._finishRun(reusable: false);
        return _outcome(
          status: CorpusMutationEvidenceStatus.restorationFailed,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          commandResults: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
          restorationVerified: false,
        );
      }
      final baselineStatus = await _gitStatus(repository);
      if (!_sameBytes(baselineStatus, view._rawBaselineGitStatus) ||
          _sha256(baselineStatus) != view.baselineGitStatusIdentity ||
          !await _gitMetadataCurrent(repository, project.repositoryRevision)) {
        results.add(_gateResult('sourceDrift'));
        afterFingerprint = _managedFingerprint(repository, replacements);
        view._finishRun(reusable: false);
        return _outcome(
          status: CorpusMutationEvidenceStatus.restorationFailed,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          commandResults: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
          restorationVerified: false,
        );
      }

      try {
        for (final replacement in replacements) {
          journal.add(replacement);
          await _fileOperations.installCandidate(
            repositoryRoot: repository,
            replacement: replacement,
          );
        }
        if (!_managedMatchesAfter(repository, replacements)) {
          throw const _CorpusGateException();
        }
      } catch (_) {
        policyFailed = true;
        results.add(_gateResult('installFailed'));
      }

      Uint8List? installedStatus;
      Map<String, String>? installedPhysicalFingerprints;
      if (!policyFailed) {
        installedPhysicalFingerprints = {
          for (final replacement in replacements)
            replacement.relativePath: _entityFingerprint(
              repository,
              replacement.relativePath,
              includePhysical: true,
            ),
        };
        final driftStatus = _policyAuthorityDriftStatus(
          project: project,
          repository: repository,
          packageRoot: packageRoot,
          canonicalFlutter: flutter,
          toolchainProbeIdentity: toolchainProbe,
          expectedProtected: protectedBefore,
          view: view,
          replacements: replacements,
          installedPhysicalFingerprints: installedPhysicalFingerprints,
          replacementPaths: replacementPaths,
        );
        if (driftStatus != null) {
          policyFailed = true;
          results.add(_gateResult(driftStatus));
        } else {
          installedStatus = await _gitStatus(repository);
        }
      }
      if (!policyFailed) {
        for (final command in project.verificationPolicy) {
          final beforeCommandDrift = _policyAuthorityDriftStatus(
            project: project,
            repository: repository,
            packageRoot: packageRoot,
            canonicalFlutter: flutter,
            toolchainProbeIdentity: toolchainProbe,
            expectedProtected: protectedBefore,
            view: view,
            replacements: replacements,
            installedPhysicalFingerprints: installedPhysicalFingerprints!,
            replacementPaths: replacementPaths,
          );
          if (beforeCommandDrift != null ||
              !_sameBytes(installedStatus!, await _gitStatus(repository)) ||
              !await _gitMetadataCurrent(
                repository,
                project.repositoryRevision,
              )) {
            policyFailed = true;
            results.add(
              _gateResult(beforeCommandDrift ?? 'protectedAuthorityDrift'),
            );
            break;
          }
          final workingDirectory = _existingDirectoryWithin(
            repository,
            command.workingDirectoryRelativeToRepository,
          );
          try {
            final result = await _processRunner.run(
              flutter.path,
              command.argumentsAfterCanonicalFlutter,
              workingDirectory: workingDirectory.path,
              timeout: _commandTimeout,
              maxOutputBytesPerStream: _maxOutputBytesPerStream,
            );
            results.add(_commandResult(command.identity, result));
            if (!_processPassed(result)) policyFailed = true;
          } on ProcessTerminationUnconfirmedException {
            results.add(_gateResult('terminationUnconfirmed'));
            unconfirmed = true;
            policyFailed = true;
            final cleanupLease = view._cleanupLease;
            if (cleanupLease is _OwnedProjectViewLease) cleanupLease.poison();
            view._lifecycle = _CorpusProjectViewLifecycle.deletionUnsafe;
            break;
          } catch (_) {
            results.add(_gateResult('processInfrastructureFailure'));
            policyFailed = true;
            break;
          }
          final afterCommandDrift = _policyAuthorityDriftStatus(
            project: project,
            repository: repository,
            packageRoot: packageRoot,
            canonicalFlutter: flutter,
            toolchainProbeIdentity: toolchainProbe,
            expectedProtected: protectedBefore,
            view: view,
            replacements: replacements,
            installedPhysicalFingerprints: installedPhysicalFingerprints,
            replacementPaths: replacementPaths,
          );
          if (afterCommandDrift != null ||
              !_sameBytes(installedStatus, await _gitStatus(repository)) ||
              !await _gitMetadataCurrent(
                repository,
                project.repositoryRevision,
              )) {
            policyFailed = true;
            results.add(
              _gateResult(afterCommandDrift ?? 'protectedAuthorityDrift'),
            );
            break;
          }
        }
      }

      if (unconfirmed) {
        try {
          afterFingerprint = _managedFingerprint(repository, replacements);
        } catch (_) {
          afterFingerprint = emptyFingerprint;
        }
        view._finishRun(reusable: false, poison: true);
        return _outcome(
          status: CorpusMutationEvidenceStatus.restorationFailed,
          candidateIdentity: candidateIdentity,
          familyIdentity: familyIdentity,
          changeSetHash: witnessed.fingerprint,
          policyHash: policyHash,
          commandResults: results,
          beforeFingerprint: beforeFingerprint,
          afterFingerprint: afterFingerprint,
          restorationVerified: false,
        );
      }

      var restorationFailed = false;
      if (!_viewFilesystemAuthorityCurrent(project, view)) {
        restorationFailed = true;
        _markViewDeletionUnsafe(view);
      } else {
        for (final replacement in journal.reversed) {
          if (!_viewFilesystemAuthorityCurrent(project, view)) {
            restorationFailed = true;
            _markViewDeletionUnsafe(view);
            break;
          }
          try {
            await _fileOperations.restoreBefore(
              repositoryRoot: repository,
              replacement: replacement,
            );
          } catch (_) {
            restorationFailed = true;
          }
        }
      }
      final filesystemAuthorityAfterRestore = _viewFilesystemAuthorityCurrent(
        project,
        view,
      );
      if (!filesystemAuthorityAfterRestore) {
        restorationFailed = true;
        _markViewDeletionUnsafe(view);
      }
      if (filesystemAuthorityAfterRestore) {
        try {
          afterFingerprint = _managedFingerprint(repository, replacements);
        } catch (_) {
          afterFingerprint = emptyFingerprint;
          restorationFailed = true;
        }
      } else {
        afterFingerprint = emptyFingerprint;
      }
      Uint8List? restoredStatus;
      final localRestorationCurrent =
          !restorationFailed &&
          filesystemAuthorityAfterRestore &&
          beforeFingerprint == afterFingerprint &&
          _viewFilesystemAuthorityCurrent(project, view) &&
          _overlayRestorationCurrent(repository, view, replacementPaths) &&
          _protectedAuthorityStillCurrent(
            project: project,
            repository: repository,
            packageRoot: packageRoot,
            canonicalFlutter: flutter,
            toolchainProbeIdentity: toolchainProbe,
            expected: protectedBefore,
          );
      if (localRestorationCurrent) {
        try {
          restoredStatus = await _gitStatus(repository);
        } on ProcessTerminationUnconfirmedException {
          rethrow;
        } catch (_) {
          restorationFailed = true;
        }
      }
      restorationVerified =
          localRestorationCurrent &&
          restoredStatus != null &&
          _sameBytes(restoredStatus, view._rawBaselineGitStatus) &&
          _sha256(restoredStatus) == view.baselineGitStatusIdentity &&
          await _gitMetadataCurrent(repository, project.repositoryRevision) &&
          _viewFilesystemAuthorityCurrent(project, view) &&
          _overlayRestorationCurrent(repository, view, replacementPaths) &&
          _protectedAuthorityStillCurrent(
            project: project,
            repository: repository,
            packageRoot: packageRoot,
            canonicalFlutter: flutter,
            toolchainProbeIdentity: toolchainProbe,
            expected: protectedBefore,
          );
      if (!restorationVerified) {
        results.add(_gateResult('restorationFailed'));
      } else {
        view._refreshManagedOverlayPhysicalAuthority(
          repository,
          replacementPaths,
        );
      }
      final status = !restorationVerified
          ? CorpusMutationEvidenceStatus.restorationFailed
          : policyFailed
          ? CorpusMutationEvidenceStatus.fullPolicyFailed
          : CorpusMutationEvidenceStatus.passed;
      view._finishRun(reusable: restorationVerified);
      return _outcome(
        status: status,
        candidateIdentity: candidateIdentity,
        familyIdentity: familyIdentity,
        changeSetHash: witnessed.fingerprint,
        policyHash: policyHash,
        commandResults: results,
        beforeFingerprint: beforeFingerprint,
        afterFingerprint: afterFingerprint,
        restorationVerified: restorationVerified,
      );
    } on ProcessTerminationUnconfirmedException {
      final cleanupLease = view._cleanupLease;
      if (cleanupLease is _OwnedProjectViewLease) cleanupLease.poison();
      results.add(_gateResult('terminationUnconfirmed'));
      view._finishRun(reusable: false, poison: true);
      return _outcome(
        status: CorpusMutationEvidenceStatus.restorationFailed,
        candidateIdentity: candidateIdentity,
        familyIdentity: familyIdentity,
        changeSetHash: witnessed.fingerprint,
        policyHash: policyHash,
        commandResults: results,
        beforeFingerprint: beforeFingerprint,
        afterFingerprint: afterFingerprint,
        restorationVerified: false,
      );
    } catch (_) {
      if (_viewFilesystemAuthorityCurrent(project, view)) {
        for (final replacement in journal.reversed) {
          if (!_viewFilesystemAuthorityCurrent(project, view)) {
            _markViewDeletionUnsafe(view);
            break;
          }
          try {
            await _fileOperations.restoreBefore(
              repositoryRoot: view.repositoryRoot,
              replacement: replacement,
            );
          } catch (_) {
            // The final typed outcome below remains restoration-authoritative.
          }
        }
      } else {
        _markViewDeletionUnsafe(view);
      }
      if (_viewFilesystemAuthorityCurrent(project, view)) {
        try {
          afterFingerprint = _managedFingerprint(
            view.repositoryRoot,
            replacements,
          );
        } catch (_) {
          afterFingerprint = emptyFingerprint;
        }
      } else {
        afterFingerprint = emptyFingerprint;
      }
      results.add(_gateResult('restorationFailed'));
      view._finishRun(reusable: false);
      return _outcome(
        status: CorpusMutationEvidenceStatus.restorationFailed,
        candidateIdentity: candidateIdentity,
        familyIdentity: familyIdentity,
        changeSetHash: witnessed.fingerprint,
        policyHash: policyHash,
        commandResults: results,
        beforeFingerprint: beforeFingerprint,
        afterFingerprint: afterFingerprint,
        restorationVerified: false,
      );
    }
  }

  Future<Uint8List> _gitStatus(Directory repository) async {
    final result = await _processRunner.run(
      _gitExecutable,
      _isolatedGitArguments([
        '-C',
        repository.path,
        'status',
        '--porcelain=v2',
        '-z',
        '--untracked-files=all',
        '--ignore-submodules=none',
      ]),
      workingDirectory: repository.path,
      timeout: _commandTimeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
      environmentOverrides: _isolatedGitEnvironment(),
      includeParentEnvironment: false,
    );
    if (!_processPassed(result)) throw const _CorpusGateException();
    return result.stdout.capturedPayload;
  }

  Future<String> _gitText(Directory repository, List<String> arguments) async {
    final result = await _processRunner.run(
      _gitExecutable,
      _isolatedGitArguments(['-C', repository.path, ...arguments]),
      workingDirectory: repository.path,
      timeout: _commandTimeout,
      maxOutputBytesPerStream: _maxOutputBytesPerStream,
      environmentOverrides: _isolatedGitEnvironment(),
      includeParentEnvironment: false,
    );
    if (!_processPassed(result)) throw const _CorpusGateException();
    return utf8.decode(result.stdout.capturedPayload).trim();
  }

  Future<bool> _gitMetadataCurrent(
    Directory repository,
    String expectedRevision,
  ) async =>
      await _gitText(repository, const ['rev-parse', 'HEAD']) ==
          expectedRevision &&
      (await _gitText(repository, const ['remote'])).isEmpty;
}

final class _CorpusGateException implements Exception {
  const _CorpusGateException();
}

final class _OwnedProjectViewLease implements CorpusProjectViewLease {
  _OwnedProjectViewLease._(
    this.root,
    this._canonicalRoot,
    this._markerBytes,
    this._markerPhysicalIdentity,
  );

  factory _OwnedProjectViewLease.create(
    CorpusTemporaryDirectoryFactory directoryFactory, {
    required List<Directory> disjointDirectories,
  }) {
    final base = directoryFactory(_ownedPrefix);
    if (FileSystemEntity.typeSync(base.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const _CorpusGateException();
    }
    final canonicalBase = base.resolveSymbolicLinksSync();
    final canonicalSystemTemp = Directory.systemTemp.resolveSymbolicLinksSync();
    if (canonicalBase != canonicalSystemTemp &&
        !p.isWithin(canonicalSystemTemp, canonicalBase)) {
      throw const _CorpusGateException();
    }
    for (final directory in disjointDirectories) {
      final canonicalDirectory = directory.resolveSymbolicLinksSync();
      if (canonicalBase == canonicalDirectory ||
          p.isWithin(canonicalDirectory, canonicalBase)) {
        throw const _CorpusGateException();
      }
    }
    final root = Directory(canonicalBase).createTempSync(_ownedPrefix);
    try {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          (_isPosix && root.statSync().mode & 0xfff != 0x1c0)) {
        throw const _CorpusGateException();
      }
      final canonicalRoot = root.resolveSymbolicLinksSync();
      if (!p.isWithin(canonicalBase, canonicalRoot) ||
          !p.basename(canonicalRoot).startsWith(_ownedPrefix)) {
        throw const _CorpusGateException();
      }
      for (final directory in disjointDirectories) {
        final canonicalDirectory = directory.resolveSymbolicLinksSync();
        if (canonicalRoot == canonicalDirectory ||
            p.isWithin(canonicalRoot, canonicalDirectory) ||
            p.isWithin(canonicalDirectory, canonicalRoot)) {
          throw const _CorpusGateException();
        }
      }
      if (root.listSync(followLinks: false).isNotEmpty) {
        throw const _CorpusGateException();
      }
      final random = Random.secure();
      final markerBytes = Uint8List.fromList(
        List<int>.generate(32, (_) => random.nextInt(256)),
      );
      final marker = File(p.join(canonicalRoot, _markerName));
      marker.createSync(exclusive: true);
      if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const _CorpusGateException();
      }
      final handle = marker.openSync(mode: FileMode.writeOnly);
      try {
        handle.writeFromSync(markerBytes);
        handle.flushSync();
      } finally {
        handle.closeSync();
      }
      if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !_sameBytes(marker.readAsBytesSync(), markerBytes)) {
        throw const _CorpusGateException();
      }
      final entries = Directory(canonicalRoot).listSync(followLinks: false);
      if (entries.length != 1 ||
          entries.single.resolveSymbolicLinksSync() !=
              marker.resolveSymbolicLinksSync()) {
        throw const _CorpusGateException();
      }
      return _OwnedProjectViewLease._(
        Directory(canonicalRoot),
        canonicalRoot,
        markerBytes,
        _fileFingerprint(marker, includePhysical: true),
      );
    } catch (_) {
      try {
        if (root.existsSync()) root.deleteSync(recursive: true);
      } catch (_) {
        // The freshly allocated child may require external cleanup.
      }
      rethrow;
    }
  }

  final Directory root;
  final String _canonicalRoot;
  final Uint8List _markerBytes;
  final String _markerPhysicalIdentity;
  bool _disposed = false;
  bool _poisoned = false;
  String? _authorityIdentity;

  bool get isPoisoned => _poisoned;

  String? get authorityIdentity => _authorityIdentity;

  bool get authorityCurrent {
    final expected = _authorityIdentity;
    if (expected == null || _disposed) return false;
    try {
      return _captureAuthorityIdentity() == expected;
    } catch (_) {
      return false;
    }
  }

  void captureAuthority() {
    _authorityIdentity = _captureAuthorityIdentity();
  }

  String _captureAuthorityIdentity() {
    if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        root.resolveSymbolicLinksSync() != _canonicalRoot ||
        (_isPosix && root.statSync().mode & 0xfff != 0x1c0)) {
      throw const _CorpusGateException();
    }
    final marker = _regularFileWithin(root, _markerName);
    if (!_sameBytes(marker.readAsBytesSync(), _markerBytes) ||
        _fileFingerprint(marker, includePhysical: true) !=
            _markerPhysicalIdentity) {
      throw const _CorpusGateException();
    }
    final rootStat = root.statSync();
    return _hashFields([
      _canonicalRoot,
      rootStat.mode.toString(),
      rootStat.changed.microsecondsSinceEpoch.toString(),
      rootStat.modified.microsecondsSinceEpoch.toString(),
      _fileFingerprint(marker, includePhysical: true),
    ]);
  }

  void poison() => _poisoned = true;

  @override
  Future<bool> dispose() async {
    if (_poisoned) return false;
    if (_disposed) return true;
    try {
      if (FileSystemEntity.typeSync(root.path, followLinks: false) !=
              FileSystemEntityType.directory ||
          root.resolveSymbolicLinksSync() != _canonicalRoot ||
          (_isPosix && root.statSync().mode & 0xfff != 0x1c0)) {
        return false;
      }
      final marker = File(p.join(_canonicalRoot, _markerName));
      if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
              FileSystemEntityType.file ||
          !_sameBytes(marker.readAsBytesSync(), _markerBytes) ||
          _fileFingerprint(marker, includePhysical: true) !=
              _markerPhysicalIdentity) {
        return false;
      }
      if (_authorityIdentity != null && !authorityCurrent) return false;
      await root.delete(recursive: true);
      _disposed = !root.existsSync();
      return _disposed;
    } catch (_) {
      return false;
    }
  }
}

final class _FixtureSource {
  const _FixtureSource({
    required this.overlay,
    required this.authorityRoot,
    required this.sourceIdentity,
    required this.file,
    required this.bytes,
    required this.mode,
    required this.physicalFingerprint,
  });

  final L10nFixtureOverlay overlay;
  final Directory authorityRoot;
  final String sourceIdentity;
  final File file;
  final ImmutableBytes bytes;
  final int? mode;
  final String physicalFingerprint;
}

final class _OverlayWritePlan {
  _OverlayWritePlan({
    required List<_OverlayWrite> fixtureWrites,
    required List<_OverlayWrite> normalizationWrites,
    required List<L10nNormalizedGeneratedBaseline> generatedBaselines,
  }) : fixtureWrites = List.unmodifiable(fixtureWrites),
       normalizationWrites = List.unmodifiable(normalizationWrites),
       generatedBaselines = List.unmodifiable(generatedBaselines),
       allWrites = List.unmodifiable([
         ...fixtureWrites,
         ...normalizationWrites,
       ]);

  final List<_OverlayWrite> fixtureWrites;
  final List<_OverlayWrite> normalizationWrites;
  final List<L10nNormalizedGeneratedBaseline> generatedBaselines;
  final List<_OverlayWrite> allWrites;
}

final class _OverlayWrite {
  const _OverlayWrite._({
    required this.relativePath,
    required this.afterBytes,
    required this.mode,
    required this.mustCreate,
    this.beforeBytes,
  });

  factory _OverlayWrite.createNew(
    String relativePath,
    ImmutableBytes afterBytes,
    int? mode,
  ) => _OverlayWrite._(
    relativePath: relativePath,
    afterBytes: ImmutableBytes.copyOf(afterBytes.copy()),
    mode: mode,
    mustCreate: true,
  );

  factory _OverlayWrite.replace(
    String relativePath,
    ImmutableBytes beforeBytes,
    ImmutableBytes afterBytes,
    int? mode,
  ) => _OverlayWrite._(
    relativePath: relativePath,
    beforeBytes: ImmutableBytes.copyOf(beforeBytes.copy()),
    afterBytes: ImmutableBytes.copyOf(afterBytes.copy()),
    mode: mode,
    mustCreate: false,
  );

  final String relativePath;
  final ImmutableBytes? beforeBytes;
  final ImmutableBytes afterBytes;
  final int? mode;
  final bool mustCreate;
}

Directory _systemTemporaryBase(String _) => Directory.systemTemp;

String get _platformGitExecutable =>
    File('/usr/bin/git').existsSync() ? '/usr/bin/git' : 'git';

Directory _canonicalLocalDirectory(String path) {
  if (!p.isAbsolute(path) ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.directory) {
    throw const _CorpusGateException();
  }
  return Directory(Directory(path).resolveSymbolicLinksSync());
}

Directory _canonicalExistingViewRoot(Directory directory) {
  return _canonicalDirectoryEntry(directory);
}

Directory _canonicalDirectoryEntry(Directory directory) {
  final absolute = p.normalize(directory.absolute.path);
  if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _CorpusGateException();
  }
  final canonical = Directory(absolute).resolveSymbolicLinksSync();
  if (!p.equals(canonical, absolute)) throw const _CorpusGateException();
  return Directory(canonical);
}

File _canonicalFlutter(String path) {
  if (!p.isAbsolute(path) ||
      FileSystemEntity.typeSync(path, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const _CorpusGateException();
  }
  final file = File(File(path).resolveSymbolicLinksSync());
  if (p.basename(file.path) != 'flutter' ||
      (_isPosix && file.statSync().mode & 0x49 == 0)) {
    throw const _CorpusGateException();
  }
  return file;
}

Map<String, String> _isolatedGitEnvironment() =>
    Map<String, String>.unmodifiable({
      'GIT_ALLOW_PROTOCOL': 'file',
      'GIT_CONFIG_GLOBAL': Platform.isWindows ? 'NUL' : '/dev/null',
      'GIT_CONFIG_NOSYSTEM': '1',
      'GIT_LFS_SKIP_SMUDGE': '1',
      'GIT_NO_REPLACE_OBJECTS': '1',
      'GIT_OPTIONAL_LOCKS': '0',
      'GIT_TERMINAL_PROMPT': '0',
      'LANG': 'C',
      'LC_ALL': 'C',
    });

List<String> _isolatedGitArguments(List<String> arguments) => [
  '-c',
  'core.hooksPath=/dev/null',
  '-c',
  'core.autocrlf=false',
  ...arguments,
];

List<_FixtureSource> _preflightFixtureSources(
  L10nMutationProjectManifest project,
  Directory retained,
) {
  final sources = <_FixtureSource>[];
  final sourceAuthorityRoot = _canonicalDirectoryEntry(retained.parent);
  for (final overlay in project.fixtureOverlays) {
    if (overlay.containsSecrets) throw const _CorpusGateException();
    final file = _regularFileWithin(
      sourceAuthorityRoot,
      overlay.sourceIdentity,
    );
    if (p.equals(file.path, retained.path) ||
        p.isWithin(retained.path, file.path)) {
      throw const _CorpusGateException();
    }
    final state = _readRegularFile(file);
    if (state.bytes.sha256Hex != overlay.sha256 ||
        (_isPosix && state.mode != 0x1a4)) {
      throw const _CorpusGateException();
    }
    sources.add(
      _FixtureSource(
        overlay: overlay,
        authorityRoot: sourceAuthorityRoot,
        sourceIdentity: overlay.sourceIdentity,
        file: file,
        bytes: state.bytes,
        mode: state.mode,
        physicalFingerprint: _fileFingerprint(file, includePhysical: true),
      ),
    );
  }
  return List<_FixtureSource>.unmodifiable(sources);
}

void _validateToolchainSelectionEvidence(
  L10nMutationProjectManifest project,
  Directory repository, {
  bool allowAuthorizedReplacement = false,
}) {
  final evidence = project.toolchainSelectionEvidence;
  final declaredVersion = evidence['frameworkVersion'];
  if (declaredVersion != null && declaredVersion != project.toolchainVersion) {
    throw const _CorpusGateException();
  }
  final evidencePath = evidence['evidencePath'];
  final evidenceHash = evidence['evidenceSha256'];
  if (evidencePath == null && evidenceHash == null) return;
  if (evidencePath is! String ||
      !_isSafeRelativePath(evidencePath) ||
      evidenceHash is! String ||
      !_isSha256(evidenceHash)) {
    throw const _CorpusGateException();
  }
  final file = _regularFileWithin(repository, evidencePath);
  if (_readRegularFile(file).bytes.sha256Hex != evidenceHash) {
    final authorizedReplacement = project.fixtureOverlays.where(
      (overlay) =>
          overlay.relativePath == evidencePath &&
          overlay.sha256 == evidenceHash &&
          overlay.purpose == 'toolchain selector authority',
    );
    if (!allowAuthorizedReplacement || authorizedReplacement.length != 1) {
      throw const _CorpusGateException();
    }
  }
}

bool _fixtureSourcesStillMatch(List<_FixtureSource> sources) {
  try {
    for (final source in sources) {
      final current = _regularFileWithin(
        source.authorityRoot,
        source.sourceIdentity,
      );
      final state = _readRegularFile(current);
      if (!p.equals(current.path, source.file.path) ||
          !state.bytes.contentEquals(source.bytes) ||
          state.mode != source.mode ||
          _fileFingerprint(current, includePhysical: true) !=
              source.physicalFingerprint) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _overlayTargetsStillMatch(
  Directory repository,
  List<_OverlayWrite> writes,
) {
  try {
    for (final write in writes) {
      final state = _readRegularFile(
        _regularFileWithin(repository, write.relativePath),
      );
      if (!state.bytes.contentEquals(write.afterBytes) ||
          state.mode != write.mode) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _overlayBaselinesCurrent(Directory repository, CorpusProjectView view) {
  try {
    for (final entry in view._overlayTargetLogicalFingerprints.entries) {
      if (_entityFingerprint(repository, entry.key) != entry.value ||
          _entityFingerprint(repository, entry.key, includePhysical: true) !=
              view._overlayTargetPhysicalFingerprints[entry.key]) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _physicalReplacementsCurrent(
  Directory repository,
  Map<String, String> expected,
) {
  try {
    for (final entry in expected.entries) {
      if (_entityFingerprint(repository, entry.key, includePhysical: true) !=
          entry.value) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _nonManagedOverlayAuthorityCurrent(
  Directory repository,
  CorpusProjectView view,
  Set<String> managedPaths,
) {
  try {
    for (final entry in view._overlayTargetPhysicalFingerprints.entries) {
      if (!managedPaths.contains(entry.key) &&
          _entityFingerprint(repository, entry.key, includePhysical: true) !=
              entry.value) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _overlayRestorationCurrent(
  Directory repository,
  CorpusProjectView view,
  Set<String> managedPaths,
) {
  try {
    for (final entry in view._overlayTargetLogicalFingerprints.entries) {
      if (_entityFingerprint(repository, entry.key) != entry.value) {
        return false;
      }
      if (!managedPaths.contains(entry.key) &&
          _entityFingerprint(repository, entry.key, includePhysical: true) !=
              view._overlayTargetPhysicalFingerprints[entry.key]) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

void _validateOverlayWriteSet(List<_OverlayWrite> writes) {
  final folded = <String, String>{};
  final ordered = <String>[];
  for (final write in writes) {
    if (!_isSafeRelativePath(write.relativePath)) {
      throw const _CorpusGateException();
    }
    final key = write.relativePath.toLowerCase();
    if (folded.containsKey(key)) throw const _CorpusGateException();
    folded[key] = write.relativePath;
    ordered.add(key);
  }
  ordered.sort();
  for (var index = 0; index < ordered.length; index++) {
    for (var other = index + 1; other < ordered.length; other++) {
      if (ordered[other].startsWith('${ordered[index]}/')) {
        throw const _CorpusGateException();
      }
    }
  }
}

Future<void> _installOverlay(Directory repository, _OverlayWrite write) async {
  if (write.mustCreate) {
    final target = File(_joinWithin(repository, write.relativePath));
    _ensureSafeParentDirectories(repository, write.relativePath);
    await target.create(exclusive: true);
    if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const _CorpusGateException();
    }
    final handle = await target.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(write.afterBytes.copy());
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _setMode(target, write.mode);
    final state = _readRegularFile(target);
    if (!state.bytes.contentEquals(write.afterBytes) ||
        state.mode != write.mode) {
      throw const _CorpusGateException();
    }
    return;
  }
  await _replaceExisting(
    repositoryRoot: repository,
    relativePath: write.relativePath,
    expectedBytes: write.beforeBytes!,
    desiredBytes: write.afterBytes,
    expectedMode: write.mode,
    desiredMode: write.mode,
  );
}

Future<String?> _regenerateNormalizedGeneratedBaseline({
  required Directory repository,
  required Directory packageRoot,
  required File flutter,
  required L10nNormalizedGeneratedBaseline baseline,
  required ProcessExecutionRunner processRunner,
  required Duration timeout,
  required int maxOutputBytesPerStream,
}) async {
  final packagePaths = <String, L10nNormalizedGeneratedOutput>{};
  for (final output in baseline.changedOutputs) {
    final repositoryPath = _joinWithin(repository, output.relativePath);
    final relative = p
        .relative(repositoryPath, from: packageRoot.path)
        .replaceAll('\\', '/');
    if (!_isSafeRelativePath(relative) ||
        relative.startsWith('../') ||
        !relative.endsWith('.dart') ||
        packagePaths.containsKey(relative)) {
      return 'managedAuthorityDrift';
    }
    final before = _readRegularFile(_regularFileWithin(packageRoot, relative));
    if (before.bytes.sha256Hex != output.originalSha256 ||
        (_isPosix && before.mode != output.posixMode)) {
      return 'managedAuthorityDrift';
    }
    packagePaths[relative] = output;
  }

  late final Map<String, _NormalizedGenerationEntry> before;
  try {
    before = await _captureNormalizedGenerationTree(packageRoot);
  } on Object {
    return 'managedAuthorityDrift';
  }

  final result = await processRunner.run(
    flutter.path,
    const ['gen-l10n'],
    workingDirectory: packageRoot.path,
    timeout: timeout,
    maxOutputBytesPerStream: maxOutputBytesPerStream,
  );
  if (!_processPassed(result)) return _processStatus(result);

  late final Map<String, _NormalizedGenerationEntry> after;
  try {
    after = await _captureNormalizedGenerationTree(packageRoot);
  } on Object {
    return 'managedAuthorityDrift';
  }

  final paths = <String>{...before.keys, ...after.keys};
  final changed = <String>{};
  for (final path in paths) {
    if (before[path] != after[path]) {
      changed.add(path);
    }
  }
  if (!_sameStringSets(changed, packagePaths.keys.toSet())) {
    return 'managedAuthorityDrift';
  }
  for (final entry in packagePaths.entries) {
    final output = entry.value;
    final generated = after[entry.key];
    if (generated?.kind != _NormalizedGenerationEntryKind.regularFile ||
        generated?.sha256 != output.replacementSha256 ||
        (_isPosix && generated?.posixMode != output.posixMode)) {
      return 'managedAuthorityDrift';
    }
  }
  return null;
}

Future<Map<String, _NormalizedGenerationEntry>>
_captureNormalizedGenerationTree(Directory suppliedRoot) async {
  final root = _canonicalDirectoryEntry(suppliedRoot);
  final rootIdentity = _directoryPhysicalFingerprint(root);
  final enumerated = _enumerateNormalizedGenerationTree(root);
  final entries = SplayTreeMap<String, _NormalizedGenerationEntry>();
  for (final item in enumerated) {
    final path = item.entity.path;
    final canonical = p.normalize(item.entity.resolveSymbolicLinksSync());
    if (!p.equals(canonical, p.normalize(path)) ||
        !p.isWithin(root.path, canonical)) {
      throw const _CorpusGateException();
    }
    final initialType = FileSystemEntity.typeSync(path, followLinks: false);
    if (initialType == FileSystemEntityType.directory) {
      final before = item.entity.statSync();
      final after = item.entity.statSync();
      if (!_sameStableStat(before, after, FileSystemEntityType.directory)) {
        throw const _CorpusGateException();
      }
      entries[item.relativePath] = _NormalizedGenerationEntry(
        kind: _NormalizedGenerationEntryKind.directory,
        sha256: null,
        posixMode: _isPosix ? after.mode & 0xfff : null,
      );
      continue;
    }
    if (initialType != FileSystemEntityType.file) {
      throw const _CorpusGateException();
    }
    final file = File(canonical);
    final before = file.statSync();
    final digest = await sha256.bind(file.openRead()).first;
    final after = file.statSync();
    if (!_sameStableStat(before, after, FileSystemEntityType.file)) {
      throw const _CorpusGateException();
    }
    entries[item.relativePath] = _NormalizedGenerationEntry(
      kind: _NormalizedGenerationEntryKind.regularFile,
      sha256: digest.toString(),
      posixMode: _isPosix ? after.mode & 0xfff : null,
    );
  }
  final finalPaths = _enumerateNormalizedGenerationTree(
    root,
  ).map((item) => item.relativePath).toList(growable: false);
  if (_directoryPhysicalFingerprint(root) != rootIdentity ||
      !_sameStrings(
        enumerated.map((item) => item.relativePath).toList(growable: false),
        finalPaths,
      )) {
    throw const _CorpusGateException();
  }
  return Map.unmodifiable(entries);
}

List<({FileSystemEntity entity, String relativePath})>
_enumerateNormalizedGenerationTree(Directory root) {
  final entries = <({FileSystemEntity entity, String relativePath})>[];
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    final absolute = p.normalize(entity.absolute.path);
    if (!p.isWithin(root.path, absolute)) {
      throw const _CorpusGateException();
    }
    final relative = p
        .relative(absolute, from: root.path)
        .replaceAll('\\', '/');
    if (!_isEnumeratedPackagePath(relative)) {
      throw const _CorpusGateException();
    }
    entries.add((entity: entity, relativePath: relative));
  }
  entries.sort(
    (left, right) => left.relativePath.compareTo(right.relativePath),
  );
  for (var index = 1; index < entries.length; index++) {
    if (entries[index - 1].relativePath == entries[index].relativePath) {
      throw const _CorpusGateException();
    }
  }
  return entries;
}

bool _isEnumeratedPackagePath(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains('\u0000') ||
      value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) {
    return false;
  }
  return value
      .split('/')
      .every(
        (segment) => segment.isNotEmpty && segment != '.' && segment != '..',
      );
}

bool _sameStableStat(
  FileStat before,
  FileStat after,
  FileSystemEntityType expectedType,
) =>
    before.type == expectedType &&
    after.type == expectedType &&
    before.size == after.size &&
    before.mode == after.mode &&
    before.modified == after.modified &&
    before.changed == after.changed;

enum _NormalizedGenerationEntryKind { regularFile, directory }

final class _NormalizedGenerationEntry {
  const _NormalizedGenerationEntry({
    required this.kind,
    required this.sha256,
    required this.posixMode,
  });

  final _NormalizedGenerationEntryKind kind;
  final String? sha256;
  final int? posixMode;

  @override
  bool operator ==(Object other) =>
      other is _NormalizedGenerationEntry &&
      other.kind == kind &&
      other.sha256 == sha256 &&
      other.posixMode == posixMode;

  @override
  int get hashCode => Object.hash(kind, sha256, posixMode);
}

bool _sameStringSets(Set<String> left, Set<String> right) =>
    left.length == right.length && left.containsAll(right);

Future<void> _replaceExisting({
  required Directory repositoryRoot,
  required String relativePath,
  required ImmutableBytes expectedBytes,
  required ImmutableBytes desiredBytes,
  required int? expectedMode,
  required int? desiredMode,
  bool allowAnyCurrentState = false,
}) async {
  final target = _regularFileWithin(repositoryRoot, relativePath);
  var state = _readRegularFile(target);
  if (!allowAnyCurrentState &&
      (!state.bytes.contentEquals(expectedBytes) ||
          state.mode != expectedMode)) {
    throw const _CorpusGateException();
  }
  final random = Random.secure();
  final temporary = File(
    p.join(
      target.parent.path,
      '.${p.basename(target.path)}.corpus-${random.nextInt(1 << 32)}',
    ),
  );
  File? displaced;
  try {
    await temporary.create(exclusive: true);
    if (FileSystemEntity.typeSync(temporary.path, followLinks: false) !=
        FileSystemEntityType.file) {
      throw const _CorpusGateException();
    }
    final handle = await temporary.open(mode: FileMode.writeOnly);
    try {
      await handle.writeFrom(desiredBytes.copy());
      await handle.flush();
    } finally {
      await handle.close();
    }
    await _setMode(temporary, desiredMode);
    state = _readRegularFile(target);
    if (!allowAnyCurrentState &&
        (!state.bytes.contentEquals(expectedBytes) ||
            state.mode != expectedMode)) {
      throw const _CorpusGateException();
    }
    if (Platform.isWindows) {
      displaced = File(
        '${temporary.path}.displaced-${random.nextInt(1 << 32)}',
      );
      if (FileSystemEntity.typeSync(displaced.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        throw const _CorpusGateException();
      }
      await target.rename(displaced.path);
      try {
        await temporary.rename(target.path);
      } catch (_) {
        if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
                FileSystemEntityType.notFound &&
            FileSystemEntity.typeSync(displaced.path, followLinks: false) ==
                FileSystemEntityType.file) {
          await displaced.rename(target.path);
        }
        rethrow;
      }
      await displaced.delete();
    } else {
      await temporary.rename(target.path);
    }
    final installed = _readRegularFile(target);
    if (!installed.bytes.contentEquals(desiredBytes) ||
        installed.mode != desiredMode) {
      throw const _CorpusGateException();
    }
  } finally {
    if (temporary.existsSync()) {
      try {
        await temporary.delete();
      } catch (_) {
        // A leftover private sibling makes the surrounding transaction reject.
      }
    }
    if (displaced != null && displaced.existsSync()) {
      try {
        if (FileSystemEntity.typeSync(target.path, followLinks: false) ==
            FileSystemEntityType.notFound) {
          await displaced.rename(target.path);
        }
      } catch (_) {
        // The transaction will reject if the original entry cannot return.
      }
    }
  }
}

Future<void> _setMode(File file, int? mode) async {
  if (!_isPosix) {
    if (mode != null) throw const _CorpusGateException();
    return;
  }
  if (mode == null) throw const _CorpusGateException();
  final result = await Process.run('/bin/chmod', [
    mode.toRadixString(8),
    file.path,
  ]);
  if (result.exitCode != 0) throw const _CorpusGateException();
}

({ImmutableBytes bytes, int? mode}) _readRegularFile(File file) {
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _CorpusGateException();
  }
  final before = file.statSync();
  final bytes = ImmutableBytes.copyOf(file.readAsBytesSync());
  final after = file.statSync();
  if (before.type != FileSystemEntityType.file ||
      after.type != FileSystemEntityType.file ||
      before.size != after.size ||
      before.modified != after.modified ||
      before.changed != after.changed) {
    throw const _CorpusGateException();
  }
  return (bytes: bytes, mode: _isPosix ? after.mode & 0xfff : null);
}

int? _posixMode(File file) => _isPosix ? file.statSync().mode & 0xfff : null;

File _regularFileWithin(Directory root, String relativePath) {
  final canonicalRootDirectory = _canonicalDirectoryEntry(root);
  final target = File(_joinWithin(canonicalRootDirectory, relativePath));
  _rejectLinkedAncestors(canonicalRootDirectory, relativePath);
  if (FileSystemEntity.typeSync(target.path, followLinks: false) !=
      FileSystemEntityType.file) {
    throw const _CorpusGateException();
  }
  final canonicalRoot = canonicalRootDirectory.path;
  final canonicalTarget = target.resolveSymbolicLinksSync();
  if (!p.isWithin(canonicalRoot, canonicalTarget)) {
    throw const _CorpusGateException();
  }
  return File(canonicalTarget);
}

Directory _existingDirectoryWithin(Directory root, String relativePath) {
  final canonicalRootDirectory = _canonicalDirectoryEntry(root);
  final targetPath = relativePath == '.'
      ? canonicalRootDirectory.path
      : _joinWithin(canonicalRootDirectory, relativePath);
  if (relativePath != '.') {
    _rejectLinkedAncestors(canonicalRootDirectory, relativePath);
  }
  if (FileSystemEntity.typeSync(targetPath, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _CorpusGateException();
  }
  final canonicalRoot = canonicalRootDirectory.path;
  final canonicalTarget = Directory(targetPath).resolveSymbolicLinksSync();
  if (canonicalTarget != canonicalRoot &&
      !p.isWithin(canonicalRoot, canonicalTarget)) {
    throw const _CorpusGateException();
  }
  return Directory(canonicalTarget);
}

void _rejectLinkedAncestors(Directory root, String relativePath) {
  var cursor = _canonicalDirectoryEntry(root).path;
  final segments = relativePath.split('/');
  for (var index = 0; index < segments.length - 1; index++) {
    cursor = p.join(cursor, segments[index]);
    final type = FileSystemEntity.typeSync(cursor, followLinks: false);
    if (type != FileSystemEntityType.directory) {
      stderr.writeln('[DEBUG] _rejectLinkedAncestors failed: cursor=$cursor, type=$type, expectedSegment=${segments[index]}');
      throw const _CorpusGateException();
    }
  }
}

void _ensureSafeParentDirectories(Directory root, String relativePath) {
  var cursor = _canonicalDirectoryEntry(root).path;
  final segments = relativePath.split('/');
  for (var index = 0; index < segments.length - 1; index++) {
    cursor = p.join(cursor, segments[index]);
    final type = FileSystemEntity.typeSync(cursor, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      Directory(cursor).createSync();
    } else if (type != FileSystemEntityType.directory) {
      throw const _CorpusGateException();
    }
  }
}

String _joinWithin(Directory root, String relativePath) {
  if (!_isSafeRelativePath(relativePath)) throw const _CorpusGateException();
  final joined = p.normalize(
    p.joinAll([root.path, ...relativePath.split('/')]),
  );
  if (!p.isWithin(p.normalize(root.path), joined)) {
    throw const _CorpusGateException();
  }
  return joined;
}

bool _isSafeRelativePath(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value.contains(':') ||
      value.codeUnits.any((unit) => unit < 0x20 || unit > 0x7e)) {
    return false;
  }
  return value
      .split('/')
      .every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
      );
}

bool _isSafeWorkingDirectory(String value) =>
    value == '.' || _isSafeRelativePath(value);

bool _argumentEscapesRepository(String argument) {
  final candidates = <String>[
    argument,
    if (argument.startsWith('--') && argument.contains('='))
      argument.substring(argument.indexOf('=') + 1),
  ];
  for (final candidate in candidates) {
    if (candidate == '.') continue;
    final lower = candidate.toLowerCase();
    if (candidate.startsWith('/') ||
        candidate.startsWith('\\') ||
        candidate.startsWith('~') ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(candidate) ||
        lower.startsWith('file:') ||
        lower.contains('file://') ||
        lower.contains('://') ||
        candidate == '..' ||
        candidate.startsWith('../') ||
        candidate.startsWith('..\\') ||
        candidate.endsWith('/..') ||
        candidate.endsWith('\\..') ||
        candidate.contains('/../') ||
        candidate.contains('\\..\\')) {
      return true;
    }
  }
  return false;
}

ImmutableBytes _applyDeclaredByteTransforms(
  ImmutableBytes original,
  List<L10nCopiedByteSpan> copiedSpans,
  List<L10nRemovedByteSpan> removedSpans,
) {
  if (copiedSpans.isEmpty && removedSpans.isEmpty) {
    throw const _CorpusGateException();
  }
  final source = original.copy();
  final transforms =
      <
          ({
            int start,
            int endExclusive,
            int? sourceStart,
            int? sourceEndExclusive,
          })
        >[
          for (final span in copiedSpans)
            (
              start: span.start,
              endExclusive: span.endExclusive,
              sourceStart: span.sourceStart,
              sourceEndExclusive: span.sourceEndExclusive,
            ),
          for (final span in removedSpans)
            (
              start: span.start,
              endExclusive: span.endExclusive,
              sourceStart: null,
              sourceEndExclusive: null,
            ),
        ]
        ..sort((left, right) => left.start.compareTo(right.start));
  final output = BytesBuilder(copy: false);
  var cursor = 0;
  for (final transform in transforms) {
    final sourceStart = transform.sourceStart;
    final sourceEnd = transform.sourceEndExclusive;
    if (transform.start < cursor ||
        transform.endExclusive <= transform.start ||
        transform.endExclusive > source.length ||
        (sourceStart == null) != (sourceEnd == null) ||
        (sourceStart != null &&
            (sourceStart < 0 ||
                sourceEnd! <= sourceStart ||
                sourceEnd > source.length))) {
      throw const _CorpusGateException();
    }
    output.add(source.sublist(cursor, transform.start));
    if (sourceStart != null) {
      output.add(source.sublist(sourceStart, sourceEnd));
    }
    cursor = transform.endExclusive;
  }
  output.add(source.sublist(cursor));
  return ImmutableBytes.copyOf(output.takeBytes());
}

bool _normalizationSemanticsMatch(
  ImmutableBytes original,
  ImmutableBytes replacement,
  String expectedCanonicalHash, {
  required bool decodedObjectEquivalent,
}) {
  try {
    if (_hasDuplicateTopLevelKeys(replacement.copy())) return false;
    final originalObject = jsonDecode(utf8.decode(original.copy()));
    final replacementObject = jsonDecode(utf8.decode(replacement.copy()));
    final originalCanonical = jsonEncode(_canonicalizeJson(originalObject));
    final replacementCanonical = jsonEncode(
      _canonicalizeJson(replacementObject),
    );
    final canonical = decodedObjectEquivalent
        ? originalCanonical
        : replacementCanonical;
    return (!decodedObjectEquivalent ||
            originalCanonical == replacementCanonical) &&
        _sha256(utf8.encode(canonical)) == expectedCanonicalHash;
  } catch (_) {
    return false;
  }
}

Object? _canonicalizeJson(Object? value) {
  if (value is Map) {
    final result = SplayTreeMap<String, Object?>();
    for (final entry in value.entries) {
      if (entry.key is! String) throw const _CorpusGateException();
      result[entry.key as String] = _canonicalizeJson(entry.value);
    }
    return result;
  }
  if (value is List) {
    return value.map(_canonicalizeJson).toList(growable: false);
  }
  return value;
}

bool _hasDuplicateTopLevelKeys(List<int> bytes) {
  final keys = <String>{};
  var cursor = _skipWhitespace(bytes, 0);
  if (cursor >= bytes.length || bytes[cursor] != 0x7b) return true;
  cursor++;
  while (true) {
    cursor = _skipWhitespace(bytes, cursor);
    if (cursor < bytes.length && bytes[cursor] == 0x7d) {
      cursor++;
      return _skipWhitespace(bytes, cursor) != bytes.length;
    }
    if (cursor >= bytes.length || bytes[cursor] != 0x22) return true;
    final keyEnd = _skipJsonString(bytes, cursor);
    final key =
        jsonDecode(utf8.decode(bytes.sublist(cursor, keyEnd))) as String;
    if (!keys.add(key)) return true;
    cursor = _skipWhitespace(bytes, keyEnd);
    if (cursor >= bytes.length || bytes[cursor] != 0x3a) return true;
    cursor = _skipJsonValue(bytes, _skipWhitespace(bytes, cursor + 1));
    cursor = _skipWhitespace(bytes, cursor);
    if (cursor < bytes.length && bytes[cursor] == 0x2c) {
      cursor++;
    } else if (cursor >= bytes.length || bytes[cursor] != 0x7d) {
      return true;
    }
  }
}

int _skipWhitespace(List<int> bytes, int cursor) {
  while (cursor < bytes.length &&
      (bytes[cursor] == 0x20 ||
          bytes[cursor] == 0x09 ||
          bytes[cursor] == 0x0a ||
          bytes[cursor] == 0x0d)) {
    cursor++;
  }
  return cursor;
}

int _skipJsonString(List<int> bytes, int cursor) {
  if (cursor >= bytes.length || bytes[cursor] != 0x22) {
    throw const _CorpusGateException();
  }
  cursor++;
  while (cursor < bytes.length) {
    if (bytes[cursor] == 0x5c) {
      cursor += 2;
    } else if (bytes[cursor] == 0x22) {
      return cursor + 1;
    } else {
      cursor++;
    }
  }
  throw const _CorpusGateException();
}

int _skipJsonValue(List<int> bytes, int cursor) {
  if (cursor >= bytes.length) throw const _CorpusGateException();
  if (bytes[cursor] == 0x22) return _skipJsonString(bytes, cursor);
  if (bytes[cursor] == 0x7b || bytes[cursor] == 0x5b) {
    final stack = <int>[bytes[cursor] == 0x7b ? 0x7d : 0x5d];
    cursor++;
    while (cursor < bytes.length && stack.isNotEmpty) {
      final byte = bytes[cursor];
      if (byte == 0x22) {
        cursor = _skipJsonString(bytes, cursor);
      } else if (byte == 0x7b || byte == 0x5b) {
        stack.add(byte == 0x7b ? 0x7d : 0x5d);
        cursor++;
      } else if (byte == stack.last) {
        stack.removeLast();
        cursor++;
      } else {
        cursor++;
      }
    }
    if (stack.isNotEmpty) throw const _CorpusGateException();
    return cursor;
  }
  while (cursor < bytes.length &&
      bytes[cursor] != 0x2c &&
      bytes[cursor] != 0x7d &&
      bytes[cursor] != 0x5d &&
      bytes[cursor] != 0x20 &&
      bytes[cursor] != 0x09 &&
      bytes[cursor] != 0x0a &&
      bytes[cursor] != 0x0d) {
    cursor++;
  }
  return cursor;
}

L10nNormalizationManifest _parseNormalizationManifest(
  File file,
  L10nMutationProjectManifest project,
) {
  final source = _readRegularFile(file).bytes;
  final decoded = jsonDecode(utf8.decode(source.copy()));
  if (decoded is! Map) throw const _CorpusGateException();
  final root = decoded.cast<String, Object?>();
  const baseKeys = <String>{
    'schemaVersion',
    'normalizationVersion',
    'repositorySha',
    'policy',
    'changedArbs',
  };
  final schemaVersion = root['schemaVersion'];
  _requireExactKeys(
    root,
    schemaVersion == 3 ? {...baseKeys, 'generatedBaseline'} : baseKeys,
  );
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
      root['normalizationVersion'] != expectedVersion ||
      root['repositorySha'] != project.repositoryRevision ||
      root['policy'] != expectedPolicy ||
      root['changedArbs'] is! List) {
    throw const _CorpusGateException();
  }
  final arbs = <L10nNormalizedArb>[];
  for (final raw in root['changedArbs']! as List<Object?>) {
    if (raw is! Map) throw const _CorpusGateException();
    final entry = raw.cast<String, Object?>();
    _requireExactKeys(entry, const {
      'relativePath',
      'originalSha256',
      'copiedByteSpans',
      'removedByteSpans',
      'replacementSha256',
      'canonicalDecodedObjectSha256',
      'decodedObjectEquivalent',
      'replacementHasDuplicateDecodedKeys',
    });
    final copies = <L10nCopiedByteSpan>[];
    final rawCopies = entry['copiedByteSpans'];
    if (rawCopies is! List) throw const _CorpusGateException();
    for (final rawCopy in rawCopies) {
      if (rawCopy is! Map) throw const _CorpusGateException();
      final copy = rawCopy.cast<String, Object?>();
      _requireExactKeys(copy, const {
        'start',
        'endExclusive',
        'sourceStart',
        'sourceEndExclusive',
      });
      if (copy['start'] is! int ||
          copy['endExclusive'] is! int ||
          copy['sourceStart'] is! int ||
          copy['sourceEndExclusive'] is! int) {
        throw const _CorpusGateException();
      }
      copies.add(
        L10nCopiedByteSpan(
          start: copy['start']! as int,
          endExclusive: copy['endExclusive']! as int,
          sourceStart: copy['sourceStart']! as int,
          sourceEndExclusive: copy['sourceEndExclusive']! as int,
        ),
      );
    }
    final spans = <L10nRemovedByteSpan>[];
    final rawSpans = entry['removedByteSpans'];
    if (rawSpans is! List) throw const _CorpusGateException();
    for (final rawSpan in rawSpans) {
      if (rawSpan is! Map) throw const _CorpusGateException();
      final span = rawSpan.cast<String, Object?>();
      _requireExactKeys(span, const {'start', 'endExclusive'});
      if (span['start'] is! int || span['endExclusive'] is! int) {
        throw const _CorpusGateException();
      }
      spans.add(
        L10nRemovedByteSpan(
          start: span['start']! as int,
          endExclusive: span['endExclusive']! as int,
        ),
      );
    }
    final relativePath = entry['relativePath'];
    final originalHash = entry['originalSha256'];
    final replacementHash = entry['replacementSha256'];
    final canonicalHash = entry['canonicalDecodedObjectSha256'];
    if (relativePath is! String ||
        !_isSafeRelativePath(relativePath) ||
        originalHash is! String ||
        !_isSha256(originalHash) ||
        replacementHash is! String ||
        !_isSha256(replacementHash) ||
        canonicalHash is! String ||
        !_isSha256(canonicalHash) ||
        entry['decodedObjectEquivalent'] is! bool ||
        entry['replacementHasDuplicateDecodedKeys'] is! bool) {
      throw const _CorpusGateException();
    }
    arbs.add(
      L10nNormalizedArb(
        relativePath: relativePath,
        originalSha256: originalHash,
        replacementSha256: replacementHash,
        canonicalDecodedObjectSha256: canonicalHash,
        copiedByteSpans: copies,
        removedByteSpans: spans,
        decodedObjectEquivalent: entry['decodedObjectEquivalent']! as bool,
        replacementHasDuplicateDecodedKeys:
            entry['replacementHasDuplicateDecodedKeys']! as bool,
      ),
    );
  }
  if (arbs.isEmpty ||
      arbs.map((arb) => arb.relativePath).toSet().length != arbs.length) {
    throw const _CorpusGateException();
  }
  final generatedBaseline = schemaVersion == 3
      ? _parseCorpusGeneratedBaseline(root['generatedBaseline'], project)
      : null;
  return L10nNormalizationManifest(
    schemaVersion: schemaVersion! as int,
    normalizationVersion: expectedVersion!,
    repositoryRevision: project.repositoryRevision,
    policy: expectedPolicy!,
    sourceSha256: source.sha256Hex,
    changedArbs: arbs,
    generatedBaseline: generatedBaseline,
  );
}

L10nNormalizedGeneratedBaseline _parseCorpusGeneratedBaseline(
  Object? raw,
  L10nMutationProjectManifest project,
) {
  if (raw is! Map) throw const _CorpusGateException();
  final json = raw.cast<String, Object?>();
  _requireExactKeys(json, const {'policy', 'changedOutputs'});
  if (json['policy'] !=
          'regenerate-after-normalization-with-pinned-toolchain' ||
      json['changedOutputs'] is! List) {
    throw const _CorpusGateException();
  }
  final outputs = <L10nNormalizedGeneratedOutput>[];
  for (final rawOutput in json['changedOutputs']! as List<Object?>) {
    if (rawOutput is! Map) throw const _CorpusGateException();
    final output = rawOutput.cast<String, Object?>();
    _requireExactKeys(output, const {
      'relativePath',
      'originalSha256',
      'replacementSha256',
      'posixMode',
    });
    final relativePath = output['relativePath'];
    final originalHash = output['originalSha256'];
    final replacementHash = output['replacementSha256'];
    final posixMode = output['posixMode'];
    if (relativePath is! String ||
        !_isSafeRelativePath(relativePath) ||
        !relativePath.startsWith('${project.arbDirectoryRelative}/') ||
        !relativePath.endsWith('.dart') ||
        project.arbPathsRelative.contains(relativePath) ||
        originalHash is! String ||
        !_isSha256(originalHash) ||
        replacementHash is! String ||
        !_isSha256(replacementHash) ||
        originalHash == replacementHash ||
        posixMode is! int ||
        posixMode < 0 ||
        posixMode > 0xfff) {
      throw const _CorpusGateException();
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

void _requireExactKeys(Map<String, Object?> value, Set<String> expected) {
  if (value.keys.toSet().length != expected.length ||
      !value.keys.toSet().containsAll(expected)) {
    throw const _CorpusGateException();
  }
}

Future<String> _probeToolchain(
  File flutter,
  L10nMutationProjectManifest project, {
  required ProcessExecutionRunner processRunner,
  required Duration timeout,
  required int maxOutputBytesPerStream,
}) async {
  final result = await processRunner.run(
    flutter.path,
    const ['--version', '--machine'],
    workingDirectory: flutter.parent.path,
    timeout: timeout,
    maxOutputBytesPerStream: maxOutputBytesPerStream,
  );
  if (!_processPassed(result)) throw const _CorpusGateException();
  final decoded = jsonDecode(utf8.decode(result.stdout.capturedPayload));
  if (decoded is! Map ||
      decoded['frameworkVersion'] != project.toolchainVersion) {
    throw const _CorpusGateException();
  }
  final evidence = project.toolchainSelectionEvidence;
  bool mismatches(String evidenceKey, String machineKey) {
    final expected = evidence[evidenceKey];
    return expected != null && decoded[machineKey] != expected;
  }

  if (mismatches('frameworkVersion', 'frameworkVersion') ||
      mismatches('frameworkRevision', 'frameworkRevision') ||
      mismatches('engineRevision', 'engineRevision') ||
      mismatches('bundledDartVersion', 'dartSdkVersion')) {
    throw const _CorpusGateException();
  }
  final boundedProbeHash = evidence['boundedProbeOutputSha256'];
  if (boundedProbeHash != null &&
      boundedProbeHash != _sha256(result.stdout.capturedPayload)) {
    throw const _CorpusGateException();
  }
  return _hashFields([
    'corpus-toolchain-probe-v1',
    project.toolchainVersion,
    _sha256(result.stdout.capturedPayload),
  ]);
}

String _protectedAuthorityFingerprint({
  required L10nMutationProjectManifest project,
  required Directory repository,
  required Directory packageRoot,
  required File canonicalFlutter,
  required String toolchainProbeIdentity,
}) {
  final paths = <String>{
    '.git/config',
    '.git/commondir',
    '.git/gitdir',
    '.git/HEAD',
    '.git/index',
    '.git/config.worktree',
    '.git/info/exclude',
    '.git/info/grafts',
    '.git/info/sparse-checkout',
    '.git/objects/info/alternates',
    '.git/shallow',
    p
        .relative(
          p.join(packageRoot.path, 'pubspec.yaml'),
          from: repository.path,
        )
        .replaceAll('\\', '/'),
    p
        .relative(
          p.join(packageRoot.path, 'pubspec.lock'),
          from: repository.path,
        )
        .replaceAll('\\', '/'),
    p
        .relative(
          p.join(packageRoot.path, '.dart_tool', 'package_config.json'),
          from: repository.path,
        )
        .replaceAll('\\', '/'),
    p
        .relative(p.join(packageRoot.path, 'l10n.yaml'), from: repository.path)
        .replaceAll('\\', '/'),
    for (final relative in const [
      'analysis_options.yaml',
      'pubspec_overrides.yaml',
      '.dart_tool/package_config_subset',
      '.dart_tool/package_graph.json',
      '.dart_tool/version',
      '.flutter-plugins',
      '.flutter-plugins-dependencies',
    ])
      p
          .relative(p.join(packageRoot.path, relative), from: repository.path)
          .replaceAll('\\', '/'),
    for (final overlay in project.fixtureOverlays) overlay.relativePath,
    if (project.toolchainSelectionEvidence['evidencePath']
        case final String path)
      path,
  }.toList()..sort();
  final fields = <String>[
    _protectedFingerprintSchema,
    project.id,
    project.repositoryRevision,
    project.toolchainVersion,
    toolchainProbeIdentity,
    _fileFingerprint(canonicalFlutter, includePhysical: true),
    jsonEncode(_canonicalizeJson(project.toolchainSelectionEvidence)),
  ];
  for (final path in paths) {
    fields
      ..add(path)
      ..add(_entityFingerprint(repository, path, includePhysical: true));
  }
  for (final relative in _flutterPubEphemeralPaths) {
    final path = p
        .relative(p.join(packageRoot.path, relative), from: repository.path)
        .replaceAll('\\', '/');
    fields
      ..add(path)
      ..add(
        _optionalRegularFileFingerprint(
          repository,
          path,
          includePhysical: true,
        ),
      );
  }
  return _hashFields(fields);
}

String _retainedGitControlFingerprint(Directory repository) {
  final dotGitPath = p.join(repository.path, '.git');
  final dotGitType = FileSystemEntity.typeSync(dotGitPath, followLinks: false);
  late final Directory gitDirectory;
  final fields = <String>['retained-git-control-v1'];
  if (dotGitType == FileSystemEntityType.directory) {
    gitDirectory = Directory(Directory(dotGitPath).resolveSymbolicLinksSync());
    fields
      ..add('dot-git-directory')
      ..add(_directoryPhysicalFingerprint(gitDirectory));
  } else if (dotGitType == FileSystemEntityType.file) {
    final pointer = File(dotGitPath);
    final source = utf8.decode(_readRegularFile(pointer).bytes.copy()).trim();
    if (!source.startsWith('gitdir: ') || source.length == 'gitdir: '.length) {
      throw const _CorpusGateException();
    }
    fields
      ..add('dot-git-file')
      ..add(_fileFingerprint(pointer, includePhysical: true));
    gitDirectory = _resolveGitControlDirectory(
      source.substring('gitdir: '.length),
      repository,
    );
  } else {
    throw const _CorpusGateException();
  }

  final commonDirectoryFile = File(p.join(gitDirectory.path, 'commondir'));
  final commonDirectory =
      FileSystemEntity.typeSync(commonDirectoryFile.path, followLinks: false) ==
          FileSystemEntityType.notFound
      ? gitDirectory
      : _resolveGitControlDirectory(
          utf8
              .decode(_readRegularFile(commonDirectoryFile).bytes.copy())
              .trim(),
          gitDirectory,
        );
  fields
    ..add(_directoryPhysicalFingerprint(gitDirectory))
    ..add(_directoryPhysicalFingerprint(commonDirectory));
  for (final path in const [
    'HEAD',
    'index',
    'commondir',
    'gitdir',
    'config.worktree',
  ]) {
    fields
      ..add('git:$path')
      ..add(_entityFingerprint(gitDirectory, path, includePhysical: true));
  }
  for (final path in const [
    'config',
    'packed-refs',
    'shallow',
    'objects/info/alternates',
    'info/exclude',
    'info/grafts',
    'info/sparse-checkout',
  ]) {
    fields
      ..add('common:$path')
      ..add(_entityFingerprint(commonDirectory, path, includePhysical: true));
  }
  return _hashFields(fields);
}

Directory _resolveGitControlDirectory(String reference, Directory relativeTo) {
  if (reference.isEmpty || reference.contains('\u0000')) {
    throw const _CorpusGateException();
  }
  final unresolved = p.isAbsolute(reference)
      ? reference
      : p.join(relativeTo.path, reference);
  if (FileSystemEntity.typeSync(unresolved, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _CorpusGateException();
  }
  return Directory(Directory(unresolved).resolveSymbolicLinksSync());
}

String _directoryPhysicalFingerprint(Directory directory) {
  if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
      FileSystemEntityType.directory) {
    throw const _CorpusGateException();
  }
  final canonical = directory.resolveSymbolicLinksSync();
  final stat = Directory(canonical).statSync();
  return _hashFields([
    canonical,
    stat.mode.toString(),
    stat.changed.microsecondsSinceEpoch.toString(),
    stat.modified.microsecondsSinceEpoch.toString(),
  ]);
}

bool _protectedAuthorityStillCurrent({
  required L10nMutationProjectManifest project,
  required Directory repository,
  required Directory packageRoot,
  required File canonicalFlutter,
  required String toolchainProbeIdentity,
  required String expected,
}) {
  try {
    return _protectedAuthorityFingerprint(
          project: project,
          repository: repository,
          packageRoot: packageRoot,
          canonicalFlutter: canonicalFlutter,
          toolchainProbeIdentity: toolchainProbeIdentity,
        ) ==
        expected;
  } catch (_) {
    return false;
  }
}

bool _cleanupAuthorityCurrent(CorpusProjectView view) {
  final lease = view._cleanupLease;
  return lease is _OwnedProjectViewLease && lease.authorityCurrent;
}

bool _factoryViewAuthorityCurrent({
  required _OwnedProjectViewLease lease,
  required Directory repository,
  required Directory packageRoot,
  required String expectedRepositoryPath,
  required String expectedPackagePath,
}) {
  try {
    return lease.authorityCurrent &&
        p.equals(
          _canonicalDirectoryEntry(repository).path,
          expectedRepositoryPath,
        ) &&
        p.equals(
          _canonicalDirectoryEntry(packageRoot).path,
          expectedPackagePath,
        ) &&
        (p.equals(expectedPackagePath, expectedRepositoryPath) ||
            p.isWithin(expectedRepositoryPath, expectedPackagePath));
  } catch (_) {
    return false;
  }
}

bool _viewFilesystemAuthorityCurrent(
  L10nMutationProjectManifest project,
  CorpusProjectView view,
) {
  try {
    if (!_cleanupAuthorityCurrent(view)) return false;
    final repository = _canonicalDirectoryEntry(view.repositoryRoot);
    if (!p.equals(
      repository.path,
      p.normalize(view.repositoryRoot.absolute.path),
    )) {
      return false;
    }
    final expectedPackagePath = project.packageRootRelative == '.'
        ? repository.path
        : _joinWithin(repository, project.packageRootRelative);
    if (!p.equals(
      expectedPackagePath,
      p.normalize(view.packageRoot.absolute.path),
    )) {
      return false;
    }
    final packageRoot = _existingDirectoryWithin(
      repository,
      project.packageRootRelative,
    );
    return p.equals(packageRoot.path, expectedPackagePath);
  } catch (_) {
    return false;
  }
}

void _markViewDeletionUnsafe(CorpusProjectView view) {
  final lease = view._cleanupLease;
  if (lease is _OwnedProjectViewLease) lease.poison();
  view._lifecycle = _CorpusProjectViewLifecycle.deletionUnsafe;
}

String? _policyAuthorityDriftStatus({
  required L10nMutationProjectManifest project,
  required Directory repository,
  required Directory packageRoot,
  required File canonicalFlutter,
  required String toolchainProbeIdentity,
  required String expectedProtected,
  required CorpusProjectView view,
  required List<L10nFileReplacement> replacements,
  required Map<String, String> installedPhysicalFingerprints,
  required Set<String> replacementPaths,
}) {
  if (!_protectedAuthorityStillCurrent(
        project: project,
        repository: repository,
        packageRoot: packageRoot,
        canonicalFlutter: canonicalFlutter,
        toolchainProbeIdentity: toolchainProbeIdentity,
        expected: expectedProtected,
      ) ||
      !_viewFilesystemAuthorityCurrent(project, view) ||
      !_nonManagedOverlayAuthorityCurrent(repository, view, replacementPaths)) {
    return 'protectedAuthorityDrift';
  }
  if (!_managedMatchesAfter(repository, replacements) ||
      !_physicalReplacementsCurrent(
        repository,
        installedPhysicalFingerprints,
      )) {
    return 'managedAuthorityDrift';
  }
  return null;
}

void _validateWitnessedAuthority(
  L10nMutationProjectManifest project,
  L10nWitnessedChangeSet changeSet,
) {
  final declaredArbs = project.arbPathsRelative.toSet();
  for (final path in changeSet.arbReplacements.keys) {
    if (!declaredArbs.contains(path)) {
      throw ArgumentError('ARB replacement is outside the declared corpus.');
    }
  }
  for (final path in changeSet.generatedReplacements.keys) {
    if (declaredArbs.contains(path)) {
      throw ArgumentError('An ARB cannot be installed as generated output.');
    }
  }

  String packagePath(String relative) => project.packageRootRelative == '.'
      ? relative
      : '${project.packageRootRelative}/$relative';
  final exactProtected = <String>{
    packagePath('analysis_options.yaml'),
    packagePath('l10n.yaml'),
    packagePath('pubspec.lock'),
    packagePath('pubspec.yaml'),
    packagePath('pubspec_overrides.yaml'),
    packagePath('.flutter-plugins'),
    packagePath('.flutter-plugins-dependencies'),
    ...project.fixtureOverlays.map((overlay) => overlay.relativePath),
    if (project.toolchainSelectionEvidence['evidencePath']
        case final String path)
      path,
  }.map((path) => path.toLowerCase()).toSet();
  for (final replacement in <L10nFileReplacement>[
    ...changeSet.arbReplacements.values,
    ...changeSet.generatedReplacements.values,
  ]) {
    final path = replacement.relativePath;
    final lower = path.toLowerCase();
    final segments = lower.split('/');
    if (!_isSafeRelativePath(path) ||
        exactProtected.contains(lower) ||
        segments.contains('.git') ||
        segments.contains('.dart_tool')) {
      throw ArgumentError('Replacement overlaps corpus authority.');
    }
  }
}

String _fileFingerprint(File file, {bool includePhysical = false}) {
  final state = _readRegularFile(file);
  final stat = file.statSync();
  return _hashFields([
    state.bytes.sha256Hex,
    state.bytes.length.toString(),
    state.mode?.toString() ?? 'null',
    if (includePhysical) stat.changed.microsecondsSinceEpoch.toString(),
    if (includePhysical) stat.modified.microsecondsSinceEpoch.toString(),
  ]);
}

String _entityFingerprint(
  Directory root,
  String relativePath, {
  bool includePhysical = false,
}) {
  final path = _joinWithin(root, relativePath);
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) {
    _rejectLinkedAncestors(root, relativePath);
    return 'absent';
  }
  if (type != FileSystemEntityType.file) throw const _CorpusGateException();
  return _fileFingerprint(
    _regularFileWithin(root, relativePath),
    includePhysical: includePhysical,
  );
}

String _optionalRegularFileFingerprint(
  Directory root,
  String relativePath, {
  bool includePhysical = false,
}) {
  var cursor = _canonicalDirectoryEntry(root).path;
  final segments = relativePath.split('/');
  for (var index = 0; index < segments.length - 1; index++) {
    cursor = p.join(cursor, segments[index]);
    final type = FileSystemEntity.typeSync(cursor, followLinks: false);
    if (type == FileSystemEntityType.notFound) return 'absent';
    if (type != FileSystemEntityType.directory) {
      throw const _CorpusGateException();
    }
  }
  final type = FileSystemEntity.typeSync(
    _joinWithin(root, relativePath),
    followLinks: false,
  );
  if (type == FileSystemEntityType.notFound) return 'absent';
  if (type != FileSystemEntityType.file) throw const _CorpusGateException();
  return _fileFingerprint(
    _regularFileWithin(root, relativePath),
    includePhysical: includePhysical,
  );
}

String _managedFingerprint(
  Directory repository,
  List<L10nFileReplacement> replacements,
) {
  final fields = <String>[_managedFingerprintSchema];
  for (final replacement in replacements) {
    fields
      ..add(replacement.relativePath)
      ..add(_entityFingerprint(repository, replacement.relativePath));
  }
  return _hashFields(fields);
}

bool _replacementMatchesBefore(
  Directory repository,
  L10nFileReplacement replacement,
) {
  try {
    final state = _readRegularFile(
      _regularFileWithin(repository, replacement.relativePath),
    );
    return state.bytes.contentEquals(replacement.beforeBytes) &&
        state.mode == replacement.beforeMode;
  } catch (_) {
    return false;
  }
}

bool _replacementMatchesAfter(
  Directory repository,
  L10nFileReplacement replacement,
) {
  try {
    final state = _readRegularFile(
      _regularFileWithin(repository, replacement.relativePath),
    );
    return state.bytes.contentEquals(replacement.afterBytes) &&
        state.mode == replacement.afterMode;
  } catch (_) {
    return false;
  }
}

bool _managedMatchesAfter(
  Directory repository,
  List<L10nFileReplacement> replacements,
) => replacements.every(
  (replacement) => _replacementMatchesAfter(repository, replacement),
);

bool _processPassed(ManagedProcessResult result) =>
    result.exitCode == 0 && !result.timedOut && !result.outputTruncated;

String _processStatus(ManagedProcessResult result) {
  if (result.timedOut) return 'timedOut';
  if (result.outputTruncated) return 'outputTruncated';
  if (result.exitCode != 0) return 'nonZeroExit';
  return 'passed';
}

Map<String, Object?> _commandResult(
  String identity,
  ManagedProcessResult result,
) => {
  'identity': identity,
  'status': _processStatus(result),
  'exitCode': result.exitCode,
  'timedOut': result.timedOut,
  'outputTruncated': result.outputTruncated,
  'stdoutSha256': _sha256(result.stdout.capturedPayload),
  'stdoutCapturedBytes': result.stdout.capturedBytes,
  'stdoutOmittedBytes': result.stdout.omittedBytes,
  'stderrSha256': _sha256(result.stderr.capturedPayload),
  'stderrCapturedBytes': result.stderr.capturedBytes,
  'stderrOmittedBytes': result.stderr.omittedBytes,
  'resourceStatus': result.resourceObservation.status.name,
  'resourceSampleCount': result.resourceObservation.sampleCount,
  if (result.resourceObservation.sampledPeakRssBytes != null)
    'sampledPeakRssBytes': result.resourceObservation.sampledPeakRssBytes!,
};

Map<String, Object?> _gateResult(String status) => {
  'identity': _hashFields(['corpus-gate-v1', status]),
  'status': status,
};

CorpusMutationEvidenceOutcome _outcome({
  required CorpusMutationEvidenceStatus status,
  required String candidateIdentity,
  required String familyIdentity,
  required String changeSetHash,
  required String policyHash,
  required List<Map<String, Object?>> commandResults,
  required String beforeFingerprint,
  required String afterFingerprint,
  required bool restorationVerified,
}) => CorpusMutationEvidenceOutcome(
  status: status,
  candidateIdentity: candidateIdentity,
  familyIdentity: familyIdentity,
  installedChangeSetHash: changeSetHash,
  policyHash: policyHash,
  commandResults: commandResults,
  beforeManagedFingerprint: beforeFingerprint,
  afterManagedFingerprint: afterFingerprint,
  restorationVerified: restorationVerified,
);

CorpusMutationEvidenceOutcome _finishEarly({
  required CorpusProjectView view,
  required String candidateIdentity,
  required String familyIdentity,
  required String changeSetHash,
  required String policyHash,
  required List<Map<String, Object?>> results,
  required String beforeFingerprint,
  required String afterFingerprint,
}) {
  view._finishRun(reusable: false);
  return _outcome(
    status: CorpusMutationEvidenceStatus.restorationFailed,
    candidateIdentity: candidateIdentity,
    familyIdentity: familyIdentity,
    changeSetHash: changeSetHash,
    policyHash: policyHash,
    commandResults: results,
    beforeFingerprint: beforeFingerprint,
    afterFingerprint: afterFingerprint,
    restorationVerified: false,
  );
}

CorpusMutationEvidenceOutcome _provisioningOutcome(
  L10nMutationProjectManifest project,
  String failureStatus,
) {
  final empty = _hashFields([_managedFingerprintSchema, 'not-provisioned']);
  return _outcome(
    status: CorpusMutationEvidenceStatus.provisioningFailed,
    candidateIdentity: _hashFields(['unavailable-candidate', project.id]),
    familyIdentity: _hashFields([
      'corpus-family-v1',
      project.id,
      project.repositoryRevision,
    ]),
    changeSetHash: _hashFields(['not-installed']),
    policyHash: _policyHash(project),
    commandResults: [_gateResult(failureStatus)],
    beforeFingerprint: empty,
    afterFingerprint: empty,
    restorationVerified: false,
  );
}

String _policyHash(L10nMutationProjectManifest project) {
  final policy = project.verificationPolicy;
  final fields = <String>[
    _policyFingerprintSchema,
    project.id,
    project.repositoryRevision,
    project.packageRootRelative,
    project.toolchainVersion,
    policy.length.toString(),
  ];
  for (final command in policy) {
    fields
      ..add(command.identity)
      ..add(command.workingDirectoryRelativeToRepository)
      ..addAll(command.argumentsAfterCanonicalFlutter);
  }
  return _hashFields(fields);
}

String _projectBindingIdentity(L10nMutationProjectManifest project) =>
    _hashFields([
      'corpus-project-binding-v1',
      project.id,
      project.repositoryRevision,
      project.packageRootRelative,
      project.toolchainVersion,
      project.arbDirectoryRelative ?? 'null',
      project.templateArbPathRelative ?? 'null',
      ...project.arbPathsRelative,
      for (final overlay in project.fixtureOverlays)
        '${overlay.relativePath}:${overlay.sha256}:${overlay.sourceIdentity}',
      for (final overlay in project.normalizationOverlays)
        '${overlay.manifest}:${overlay.policy}:'
            '${overlay.normalizationManifest?.sourceSha256 ?? 'unloaded'}',
    ]);

String _hashFields(Iterable<String> fields) {
  final bytes = BytesBuilder(copy: false);
  for (final field in fields) {
    final encoded = utf8.encode(field);
    final length = ByteData(8)..setUint64(0, encoded.length);
    bytes
      ..add(length.buffer.asUint8List())
      ..add(encoded);
  }
  return _sha256(bytes.takeBytes());
}

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

Map<String, Object?> _deepFreezeMap(Map<String, Object?> source) =>
    Map<String, Object?>.unmodifiable({
      for (final entry in source.entries)
        entry.key: _deepFreezeValue(entry.value),
    });

Object? _deepFreezeValue(Object? value) {
  if (value is Map) {
    return _deepFreezeMap(value.cast<String, Object?>());
  }
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_deepFreezeValue));
  }
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  throw ArgumentError('Corpus command evidence must be JSON-safe.');
}

void _validateRedactedValue(Object? value) {
  if (value is String) {
    if (value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f) ||
        value.contains('/') ||
        value.contains('\\') ||
        p.isAbsolute(value) ||
        RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value) ||
        value.startsWith(r'\\') ||
        value.startsWith('file:')) {
      throw ArgumentError('Corpus evidence contains a private value.');
    }
  } else if (value is Map) {
    for (final entry in value.entries) {
      _validateRedactedValue(entry.key);
      _validateRedactedValue(entry.value);
    }
  } else if (value is Iterable) {
    for (final entry in value) {
      _validateRedactedValue(entry);
    }
  }
}

const _gateStatuses = <String>{
  'checkoutRevisionDrift',
  'cleanupFailed',
  'cloneRetainedAuthority',
  'cloneSharesObjectAuthority',
  'installFailed',
  'managedAuthorityDrift',
  'nonZeroExit',
  'overlayTargetDrift',
  'outputTruncated',
  'processInfrastructureFailure',
  'protectedAuthorityDrift',
  'provisioningFailed',
  'pubSourceDrift',
  'repositoryRevisionDrift',
  'retainedRepositoryDrift',
  'restorationFailed',
  'sourceDrift',
  'terminationUnconfirmed',
  'timedOut',
  'toolchainDrift',
  'view-busy-or-poisoned',
  'viewIdentityDrift',
};

void _validateCommandResult(Map<String, Object?> result) {
  const gateKeys = <String>{'identity', 'status'};
  const processKeys = <String>{
    'identity',
    'status',
    'exitCode',
    'timedOut',
    'outputTruncated',
    'stdoutSha256',
    'stdoutCapturedBytes',
    'stdoutOmittedBytes',
    'stderrSha256',
    'stderrCapturedBytes',
    'stderrOmittedBytes',
    'resourceStatus',
    'resourceSampleCount',
  };
  final keys = result.keys.toSet();
  final identity = result['identity'];
  final status = result['status'];
  if (identity is! String || !_isSha256(identity) || status is! String) {
    throw ArgumentError('Corpus command result identity is malformed.');
  }
  if (keys.length == gateKeys.length && keys.containsAll(gateKeys)) {
    if (!_gateStatuses.contains(status)) {
      throw ArgumentError('Unknown corpus gate status.');
    }
    return;
  }
  final hasPeak = keys.contains('sampledPeakRssBytes');
  if (keys.length != processKeys.length + (hasPeak ? 1 : 0) ||
      !keys.containsAll(processKeys) ||
      (hasPeak && result['sampledPeakRssBytes'] is! int)) {
    throw ArgumentError('Unknown corpus process-result field.');
  }
  for (final key in const [
    'stdoutCapturedBytes',
    'stdoutOmittedBytes',
    'stderrCapturedBytes',
    'stderrOmittedBytes',
    'resourceSampleCount',
  ]) {
    final value = result[key];
    if (value is! int || value < 0) {
      throw ArgumentError('Corpus process count is malformed.');
    }
  }
  if (result['exitCode'] is! int ||
      result['timedOut'] is! bool ||
      result['outputTruncated'] is! bool ||
      result['stdoutSha256'] is! String ||
      !_isSha256(result['stdoutSha256']! as String) ||
      result['stderrSha256'] is! String ||
      !_isSha256(result['stderrSha256']! as String) ||
      !const {
        'measured',
        'unsupported',
        'unreliable',
      }.contains(result['resourceStatus'])) {
    throw ArgumentError('Corpus process evidence is malformed.');
  }
  final exitCode = result['exitCode']! as int;
  final timedOut = result['timedOut']! as bool;
  final truncated = result['outputTruncated']! as bool;
  final statusValid = switch (status) {
    'passed' => exitCode == 0 && !timedOut && !truncated,
    'nonZeroExit' => exitCode != 0 && !timedOut && !truncated,
    'timedOut' => timedOut,
    'outputTruncated' => truncated && !timedOut,
    _ => false,
  };
  if (!statusValid ||
      (hasPeak && (result['sampledPeakRssBytes']! as int) < 0)) {
    throw ArgumentError('Corpus process status is inconsistent.');
  }
  _validateRedactedValue(result);
}

bool _isPassingProcessResult(Map<String, Object?> result) =>
    result.keys.length > 2 && result['status'] == 'passed';

void _requireRedactedIdentity(String value, String name) {
  if (value.isEmpty ||
      value.length > 256 ||
      !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value)) {
    throw ArgumentError.value(value, name);
  }
}

bool _isSha256(String value) => RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

bool _isGitSha(String value) => RegExp(r'^[0-9a-f]{40}$').hasMatch(value);

bool get _isPosix => Platform.isLinux || Platform.isMacOS;
