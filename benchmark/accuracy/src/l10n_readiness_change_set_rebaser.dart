/// Package-root to repository-root change-set projection for the l10n harness.
library;

import 'dart:collection';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';

import 'l10n_mutation_manifest.dart';

/// Defensively copies [packageChangeSet] while rebasing every replacement onto
/// the repository coordinate system declared by [project].
L10nWitnessedChangeSet rebaseL10nWitnessedChangeSetToRepository({
  required L10nMutationProjectManifest project,
  required L10nWitnessedChangeSet packageChangeSet,
}) {
  final declaredArbs = project.arbPathsRelative.toSet();
  final arbs = _rebaseReplacements(
    packageChangeSet.arbReplacements,
    packageRootRelative: project.packageRootRelative,
  );
  if (arbs.keys.any((path) => !declaredArbs.contains(path))) {
    throw const FormatException(
      'Rebased ARB replacement is outside the manifest authority.',
    );
  }
  final generated = _rebaseReplacements(
    packageChangeSet.generatedReplacements,
    packageRootRelative: project.packageRootRelative,
  );
  return L10nWitnessedChangeSet(
    arbReplacements: arbs,
    generatedReplacements: generated,
  );
}

Map<String, L10nFileReplacement> _rebaseReplacements(
  Map<String, L10nFileReplacement> source, {
  required String packageRootRelative,
}) {
  final result = SplayTreeMap<String, L10nFileReplacement>();
  for (final replacement in source.values) {
    final path = _repositoryPath(replacement.relativePath, packageRootRelative);
    result[path] = L10nFileReplacement(
      relativePath: path,
      beforeBytes: replacement.beforeBytes,
      afterBytes: replacement.afterBytes,
      beforeMode: replacement.beforeMode,
      afterMode: replacement.afterMode,
    );
  }
  return result;
}

String _repositoryPath(String packagePath, String packageRootRelative) {
  if (packageRootRelative == '.') return packagePath;
  final prefix = '$packageRootRelative/';
  if (packagePath == packageRootRelative || packagePath.startsWith(prefix)) {
    throw const FormatException(
      'Change-set path is already repository-relative.',
    );
  }
  return '$prefix$packagePath';
}
