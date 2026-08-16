import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';
import '../../core/project/project_operation_lock.dart';
import '../../core/project/tool_workspace.dart';
import '../../quarantine/manifest.dart';
import '../../quarantine/quarantine_manager.dart';
import '../../verification/verification_runner.dart';
import '../project_command_support.dart';

/// Restores files from quarantine back to their original locations.
///
/// Restores quarantined regular-file bytes and POSIX modes where available;
/// success requires rollback verification.
class RollbackCommand extends Command<int> {
  /// Creates the rollback command.
  RollbackCommand({VerificationRunner Function(Directory)? verifierFactory})
    : _verifierFactory = verifierFactory ?? VerificationRunner.new {
    argParser
      ..addFlag(
        'clean',
        negatable: false,
        help: 'Remove quarantine directory after successful rollback.',
      )
      ..addOption(
        'quarantine',
        help:
            'Quarantine directory. Defaults to .flutter_pruner/quarantine in '
            'the selected project.',
      );
    addProjectOption(argParser);
  }

  final VerificationRunner Function(Directory) _verifierFactory;

  @override
  String get name => 'rollback';

  @override
  String get description =>
      'Restore files from quarantine. Reverses an apply operation.';

  @override
  String get invocation => '${super.invocation} <run-id>';

  @override
  Future<int> run() async {
    final args = argResults!;
    final clean = args.flag('clean');

    if (args.rest.length != 1) {
      stderr.writeln('Error: run-id required.');
      stderr.writeln('');
      stderr.writeln('Usage: $invocation');
      stderr.writeln('');
      stderr.writeln(
        'To see available quarantines: flutter_pruner quarantine list',
      );
      return 1;
    }

    final runId = args.rest.first;

    try {
      QuarantineManager.validateRunId(runId);
      final workspace = resolveToolWorkspace(args);
      final quarantineDir = _locateQuarantine(
        workspace,
        args.option('quarantine'),
        runId,
      );
      final operationLock = await ProjectOperationLock.acquire(
        workspace: workspace,
        operation: clean ? 'rollback-clean' : 'rollback',
      );
      try {
        return await _runLocked(
          workspace: workspace,
          quarantineDir: quarantineDir,
          runId: runId,
          clean: clean,
        );
      } finally {
        await operationLock.release();
      }
    } on ProjectSelectionException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on ToolWorkspaceException catch (e) {
      stderr.writeln('Error: $e');
      return 64;
    } on QuarantineException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    } on ProjectOperationLockException catch (e) {
      stderr.writeln('Error: $e');
      return 1;
    } catch (e) {
      stderr.writeln('Unexpected error: $e');
      return 1;
    }
  }

  Future<int> _runLocked({
    required ToolWorkspace workspace,
    required Directory quarantineDir,
    required String runId,
    required bool clean,
  }) async {
    final locator = QuarantineManager(workspace.projectRoot);
    final manifest = await locator.readManifest(quarantineDir);
    final projectDir = Directory(
      manifest.projectRoot ?? _inferProjectRoot(manifest),
    );
    _requireSelectedProject(workspace.projectRoot, projectDir);
    final quarantineManager = QuarantineManager(projectDir);

    stdout.writeln('Restoring from quarantine: $runId');
    if (manifest.usesTransactionJournal) {
      await _restoreVerifiedV3(
        quarantineManager: quarantineManager,
        quarantineDir: quarantineDir,
        manifest: manifest,
        projectDir: projectDir,
      );
      stdout.writeln('✓ Restored all files and verified the original state.');
    } else {
      await quarantineManager.restore(
        quarantineDir: quarantineDir,
        runId: runId,
      );
      stdout.writeln('✓ Restored all files successfully.');
    }

    if (clean) {
      stdout.writeln('Cleaning quarantine...');
      await quarantineManager.cleanQuarantine(
        runId: runId,
        quarantineBase: p.dirname(quarantineDir.path),
      );
      stdout.writeln('✓ Quarantine removed.');
    } else {
      final projectArgument = projectDir.path.replaceAll('"', r'\"');
      stdout.writeln(
        'Quarantine preserved. Use "flutter_pruner rollback --clean '
        '--project \'$projectArgument\' $runId" to remove it.',
      );
    }

    return 0;
  }

  Future<void> _restoreVerifiedV3({
    required QuarantineManager quarantineManager,
    required Directory quarantineDir,
    required QuarantineManifest manifest,
    required Directory projectDir,
  }) async {
    final baseline = manifest.baselineVerification;
    final project = await ProjectContext.load(projectDir);
    final expectedWorkingDirectory = p.normalize(p.absolute(projectDir.path));
    final comparisonBaseline = baseline?.comparisonBaseline;
    if (baseline == null ||
        !baseline.available ||
        baseline.passed == null ||
        comparisonBaseline == null ||
        !comparisonBaseline.isComplete ||
        baseline.policyHash != manifest.verificationPolicyHash ||
        baseline.policyHash != project.verificationPolicy.hash ||
        baseline.workingDirectory != expectedWorkingDirectory ||
        comparisonBaseline.policyHash != baseline.policyHash ||
        comparisonBaseline.workingDirectory != baseline.workingDirectory ||
        comparisonBaseline.toolchainIdentity != baseline.toolchainIdentity ||
        comparisonBaseline.steps.every((step) => step.passed) !=
            baseline.passed ||
        !_isCompleteStepEvidence(
          baseline.requiredStepIds,
          baseline.observedStepIds,
        ) ||
        !_sameStringSet(
          baseline.requiredStepIds,
          project.verificationPolicy.requiredStepIds,
        )) {
      throw QuarantineException(
        'V3 rollback cannot prove its original verification baseline. '
        'No project bytes were changed.',
      );
    }

    await quarantineManager.markRunRecoveryRequired(
      quarantineDir: quarantineDir,
      reason: 'Manual full-run rollback is in progress.',
    );
    await quarantineManager.restoreRunBytes(quarantineDir: quarantineDir);

    final restored = await _verifierFactory(
      projectDir,
    ).verify(policy: project.verificationPolicy);
    final observedStepIds = restored.steps.map((step) => step.name).toList();
    final comparison = restored.compareToBaselineEvidence(comparisonBaseline);
    final evidenceMatches =
        restored.isComplete &&
        restored.isAvailable &&
        restored.policyHash == baseline.policyHash &&
        restored.workingDirectory == baseline.workingDirectory &&
        restored.toolchainIdentity == baseline.toolchainIdentity &&
        _sameStringSet(restored.requiredStepIds, baseline.requiredStepIds) &&
        _isCompleteStepEvidence(restored.requiredStepIds, observedStepIds) &&
        comparison.accepted;
    if (!evidenceMatches) {
      throw QuarantineException(
        'Original bytes were restored, but verification did not reproduce '
        'the recorded baseline. The run remains recovery-required and its '
        'quarantine was preserved.',
      );
    }

    await quarantineManager.completeVerifiedFullRollback(
      quarantineDir: quarantineDir,
      reason: 'Manual full-run rollback verified.',
      verificationEvidence: QuarantineVerificationEvidence(
        policyHash: restored.policyHash,
        requiredStepIds: restored.requiredStepIds,
        observedStepIds: observedStepIds,
        workingDirectory: restored.workingDirectory,
        toolchainIdentity: restored.toolchainIdentity,
        available: restored.isAvailable,
        passed: restored.passed,
        comparisonBaseline: restored.toBaselineEvidence(),
      ),
      baselineEquivalent: true,
    );
  }

  bool _isCompleteStepEvidence(List<String> required, List<String> observed) =>
      required.isNotEmpty && _sameStringSet(required, observed);

  bool _sameStringSet(List<String> left, List<String> right) {
    final leftSet = left.toSet();
    final rightSet = right.toSet();
    return left.length == leftSet.length &&
        right.length == rightSet.length &&
        leftSet.difference(rightSet).isEmpty &&
        rightSet.difference(leftSet).isEmpty;
  }

  Directory _locateQuarantine(
    ToolWorkspace workspace,
    String? explicitBase,
    String runId,
  ) {
    if (explicitBase != null) {
      return Directory(
        p.join(workspace.resolveQuarantineDirectory(explicitBase).path, runId),
      );
    }

    final matches = [
      for (final base in _defaultQuarantineBases(workspace))
        Directory(p.join(base.path, runId)),
    ].where((directory) => directory.existsSync()).toList();
    if (matches.length > 1) {
      throw QuarantineException(
        'Ambiguous quarantine run $runId found in both default locations. '
        'Pass --quarantine to select one.',
      );
    }
    return matches.isEmpty
        ? Directory(
            p.join(_defaultQuarantineBases(workspace).first.path, runId),
          )
        : matches.single;
  }

  List<Directory> _defaultQuarantineBases(ToolWorkspace workspace) => [
    workspace.resolveQuarantineDirectory(
      QuarantineManager.defaultQuarantineDir,
    ),
    workspace.resolveQuarantineDirectory(QuarantineManager.legacyQuarantineDir),
  ];

  void _requireSelectedProject(Directory selected, Directory recorded) {
    final selectedPath = _canonicalPath(selected);
    final recordedPath = _canonicalPath(recorded);
    if (p.equals(selectedPath, recordedPath)) return;
    throw QuarantineException(
      'Quarantine belongs to $recordedPath, not the selected project '
      '$selectedPath.',
    );
  }

  String _canonicalPath(Directory directory) {
    try {
      return p.normalize(directory.resolveSymbolicLinksSync());
    } on FileSystemException {
      return p.normalize(p.absolute(directory.path));
    }
  }

  String _inferProjectRoot(QuarantineManifest manifest) {
    final paths = [
      ...manifest.entries.map((entry) => entry.originalPath),
      ...manifest.cases.map((item) => item.entry.originalPath),
    ];
    if (paths.isEmpty) {
      throw QuarantineException(
        'Legacy manifest has no entries from which to infer the project root.',
      );
    }

    var current = File(paths.first).parent;
    while (true) {
      if (File(p.join(current.path, 'pubspec.yaml')).existsSync()) {
        return current.path;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    throw QuarantineException(
      'Cannot infer project root for legacy quarantine $name.',
    );
  }
}
