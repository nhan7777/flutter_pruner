#!/usr/bin/env dart
// Test harness that bypasses GSY fixture validation for partial validation

import 'dart:io';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'l10n_mutation_readiness.dart';
import 'src/l10n_readiness_production.dart';

/// Test authority loader that skips frozen fixture hash enforcement
class TestAuthorityLoader implements ProductionL10nAuthorityLoaderBase {
  final ProductionL10nAuthorityLoader _delegate;

  TestAuthorityLoader()
      : _delegate = ProductionL10nAuthorityLoader.testing(
          processRunner: const ManagedProcessRunner(),
          gitExecutable: Platform.isWindows ? 'git.exe' : '/usr/bin/git',
          enforceRetainedProbeHash: false, // Bypass probe hash check
        );

  @override
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  ) =>
      _delegate.load(options);

  @override
  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  ) =>
      _delegate.revalidateProject(options, snapshot, projectId);
}

Future<void> main(List<String> arguments) async {
  try {
    // Run with test authority loader that doesn't enforce probe hashes
    final exitCode = await runProductionL10nMutationReadiness(
      arguments,
      authorityLoader: TestAuthorityLoader(),
    );
    exit(exitCode);
  } catch (error, stackTrace) {
    stderr.writeln('Error: $error');
    stderr.writeln(stackTrace);
    exit(2);
  }
}
