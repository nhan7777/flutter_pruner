/// Frozen production mutation-negative recipes for the l10n Stage 1 harness.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:path/path.dart' as p;

import '../l10n_mutation_readiness.dart';

const _defaultTimeout = Duration(minutes: 5);
const _defaultOutputLimit = 4 * 1024 * 1024;

/// One frozen behavioral recipe that must prove an exact rejection reason.
final class ProductionL10nNegativeRecipe {
  const ProductionL10nNegativeRecipe({
    required this.observedReason,
    required this.testPath,
    required this.testName,
  });

  final String observedReason;
  final String testPath;
  final String testName;
}

/// Scanner-independent negative matrix bound into production run identities.
const productionL10nNegativeRecipes = <String, ProductionL10nNegativeRecipe>{
  'candidate-output-created': ProductionL10nNegativeRecipe(
    observedReason: 'outputFamilyAmbiguous',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart',
    testName: 'rejects sidecar creation and deletion in the candidate',
  ),
  'candidate-output-deleted': ProductionL10nNegativeRecipe(
    observedReason: 'outputFamilyAmbiguous',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart',
    testName: 'rejects candidate generated path deletion and type drift',
  ),
  'cleanup-failure': ProductionL10nNegativeRecipe(
    observedReason: 'cleanupFailed',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_stage_materializer_test.dart',
    testName: 'cleanup is single-use and retains roots marked unsafe',
  ),
  'locale-only-key': ProductionL10nNegativeRecipe(
    observedReason: 'arbFamilyIncomplete',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart',
    testName: 'rejects locale-only messages atomically',
  ),
  'malformed-arb': ProductionL10nNegativeRecipe(
    observedReason: 'arbParseFailure',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_stage_verifier_test.dart',
    testName: 'reparses and verifies every locale ARB',
  ),
  'package-resolution-drift': ProductionL10nNegativeRecipe(
    observedReason: 'packageResolutionDrift',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart',
    testName: 'classifies raw lock and package-file drift as package drift',
  ),
  'path-escape': ProductionL10nNegativeRecipe(
    observedReason: 'invalidInputPath',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_generation_config_test.dart',
    testName: 'rejects parent traversal in arb-dir',
  ),
  'pseudo-key-selection': ProductionL10nNegativeRecipe(
    observedReason: 'invalidSelection',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_arb_mutation_planner_test.dart',
    testName: 'rejects pseudo-key selection',
  ),
  'scan-blocker': ProductionL10nNegativeRecipe(
    observedReason: 'scanBlockerPresent',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart',
    testName: 'rejects active family blockers and dangling endpoints',
  ),
  'source-drift': ProductionL10nNegativeRecipe(
    observedReason: 'sourceDrift',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart',
    testName: 'rejects changed source bytes with a stable relative path',
  ),
  'stale-live-output': ProductionL10nNegativeRecipe(
    observedReason: 'staleGeneratedOutput',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart',
    testName: 'rejects stale baseline missing',
  ),
  'toolchain-drift': ProductionL10nNegativeRecipe(
    observedReason: 'toolchainDrift',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_snapshot_revalidator_test.dart',
    testName: 'preserves stable toolchain drift without leaking paths',
  ),
  'unexpected-stage-write': ProductionL10nNegativeRecipe(
    observedReason: 'unexpectedStageWrite',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_output_reconciler_test.dart',
    testName: 'rejects unexpected create in either generator tree',
  ),
  'unknown-config-option': ProductionL10nNegativeRecipe(
    observedReason: 'unsupportedConfiguration',
    testPath:
        'test/adapters/l10n/action_readiness/l10n_generation_config_test.dart',
    testName: 'rejects an unknown string key',
  ),
};

/// Stable identity of fixture IDs, reasons, source paths, and test selectors.
String productionL10nNegativeRecipeMatrixIdentity({
  Map<String, ProductionL10nNegativeRecipe> recipes =
      productionL10nNegativeRecipes,
}) => _hashCanonical({
  'schema': 'l10n-negative-recipe-matrix-v1',
  'recipes': {
    for (final fixtureId in recipes.keys.toList()..sort())
      fixtureId: {
        'observedReason': recipes[fixtureId]!.observedReason,
        'testName': recipes[fixtureId]!.testName,
        'testPath': recipes[fixtureId]!.testPath,
      },
  },
});

/// Stable matrix identity extended with every exact recipe source byte hash.
String productionL10nNegativeRecipeAuthorityIdentity(
  Directory repositoryRoot, {
  Map<String, ProductionL10nNegativeRecipe> recipes =
      productionL10nNegativeRecipes,
}) {
  final root = _canonicalDirectory(repositoryRoot);
  return _hashCanonical({
    'matrixIdentity': productionL10nNegativeRecipeMatrixIdentity(
      recipes: recipes,
    ),
    'schema': 'l10n-negative-recipe-authority-v1',
    'sources': {
      for (final path
          in recipes.values.map((recipe) => recipe.testPath).toSet().toList()
            ..sort())
        path: sha256
            .convert(_canonicalRecipeFile(root, path).readAsBytesSync())
            .toString(),
    },
  });
}

/// Runs each frozen behavior test at most once through a bounded child process.
final class ProductionL10nMutationNegativeFixtureRunner
    implements L10nMutationNegativeFixtureRunner {
  ProductionL10nMutationNegativeFixtureRunner({
    required Directory repositoryRoot,
    ProcessExecutionRunner processRunner = const ManagedProcessRunner(),
    Duration timeout = _defaultTimeout,
    int maxOutputBytesPerStream = _defaultOutputLimit,
    String? expectedMatrixAuthorityIdentity,
  }) : this._(
         repositoryRoot: repositoryRoot,
         dartExecutable: Platform.resolvedExecutable,
         processRunner: processRunner,
         timeout: timeout,
         maxOutputBytesPerStream: maxOutputBytesPerStream,
         recipes: productionL10nNegativeRecipes,
         expectedMatrixAuthorityIdentity: expectedMatrixAuthorityIdentity,
       );

  ProductionL10nMutationNegativeFixtureRunner.testing({
    required Directory repositoryRoot,
    required String dartExecutable,
    required ProcessExecutionRunner processRunner,
    required Map<String, ProductionL10nNegativeRecipe> recipes,
    Duration timeout = _defaultTimeout,
    int maxOutputBytesPerStream = _defaultOutputLimit,
    String? expectedMatrixAuthorityIdentity,
  }) : this._(
         repositoryRoot: repositoryRoot,
         dartExecutable: dartExecutable,
         processRunner: processRunner,
         timeout: timeout,
         maxOutputBytesPerStream: maxOutputBytesPerStream,
         recipes: recipes,
         expectedMatrixAuthorityIdentity: expectedMatrixAuthorityIdentity,
       );

  ProductionL10nMutationNegativeFixtureRunner._({
    required Directory repositoryRoot,
    required this.dartExecutable,
    required ProcessExecutionRunner processRunner,
    required this.timeout,
    required this.maxOutputBytesPerStream,
    required Map<String, ProductionL10nNegativeRecipe> recipes,
    required String? expectedMatrixAuthorityIdentity,
  }) : repositoryRoot = _canonicalDirectory(repositoryRoot),
       _processRunner = processRunner,
       recipes = Map.unmodifiable(recipes) {
    if (dartExecutable.isEmpty ||
        timeout <= Duration.zero ||
        maxOutputBytesPerStream <= 0 ||
        recipes.isEmpty) {
      throw ArgumentError('Negative fixture runner authority is malformed.');
    }
    for (final entry in recipes.entries) {
      _validateRecipe(entry.key, entry.value);
      _canonicalRecipeFile(this.repositoryRoot, entry.value.testPath);
    }
    _matrixAuthorityIdentity = productionL10nNegativeRecipeAuthorityIdentity(
      this.repositoryRoot,
      recipes: this.recipes,
    );
    if (expectedMatrixAuthorityIdentity != null &&
        expectedMatrixAuthorityIdentity != _matrixAuthorityIdentity) {
      throw StateError('Negative fixture matrix authority drifted.');
    }
  }

  final Directory repositoryRoot;
  final String dartExecutable;
  final ProcessExecutionRunner _processRunner;
  final Duration timeout;
  final int maxOutputBytesPerStream;
  final Map<String, ProductionL10nNegativeRecipe> recipes;
  final Set<String> _consumed = {};
  late final String _matrixAuthorityIdentity;

  @override
  Future<L10nMutationNegativeResult> run(
    String fixtureId,
    List<String> allowedReasons,
  ) async {
    final recipe = recipes[fixtureId];
    if (recipe == null ||
        allowedReasons.length != 1 ||
        allowedReasons.single != recipe.observedReason ||
        !_consumed.add(fixtureId)) {
      throw StateError('Negative fixture authority is foreign or consumed.');
    }
    if (productionL10nNegativeRecipeAuthorityIdentity(
          repositoryRoot,
          recipes: recipes,
        ) !=
        _matrixAuthorityIdentity) {
      throw StateError('Negative fixture matrix drifted before execution.');
    }
    final file = _canonicalRecipeFile(repositoryRoot, recipe.testPath);
    final before = await file.readAsBytes();
    final sourceIdentity = sha256.convert(before).toString();
    final result = await _processRunner.run(
      dartExecutable,
      [
        'test',
        recipe.testPath,
        '--name',
        recipe.testName,
        '--reporter',
        'json',
      ],
      workingDirectory: repositoryRoot.path,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
    );
    final after = await file.readAsBytes();
    if (!_sameBytes(before, after) ||
        sourceIdentity != sha256.convert(after).toString()) {
      throw StateError('Negative fixture recipe changed during execution.');
    }
    final rejected = _exactTestPassed(result, recipe.testName);
    return L10nMutationNegativeResult(
      rejected: rejected,
      observedReason: recipe.observedReason,
      evidenceIdentity: _hashCanonical({
        'fixtureId': fixtureId,
        'matrixAuthorityIdentity': _matrixAuthorityIdentity,
        'observedReason': recipe.observedReason,
        'processExitCode': result.exitCode,
        'recipeSourceSha256': sourceIdentity,
        'rejected': rejected,
        'schema': 'l10n-negative-fixture-evidence-v1',
      }),
    );
  }
}

bool _exactTestPassed(ManagedProcessResult result, String testName) {
  if (result.exitCode != 0 || result.timedOut || result.outputTruncated) {
    return false;
  }
  final starts = <int, String>{};
  final successful = <int>{};
  var done = false;
  try {
    for (final line in const LineSplitter().convert(result.stdout.text)) {
      if (line.isEmpty) continue;
      final event = jsonDecode(line);
      if (event is! Map<String, Object?>) return false;
      if (event['type'] == 'testStart') {
        final test = event['test'];
        if (test is! Map<String, Object?> ||
            test['id'] is! int ||
            test['name'] is! String) {
          return false;
        }
        starts[test['id']! as int] = test['name']! as String;
      } else if (event['type'] == 'testDone') {
        final id = event['testID'];
        if (id is int &&
            event['result'] == 'success' &&
            event['skipped'] == false &&
            event['hidden'] == false) {
          successful.add(id);
        }
      } else if (event['type'] == 'done') {
        done = event['success'] == true;
      }
    }
  } on FormatException {
    return false;
  }
  final matching = starts.entries
      .where((entry) => entry.value.endsWith(testName))
      .map((entry) => entry.key)
      .toList(growable: false);
  return done &&
      matching.length == 1 &&
      successful.length == 1 &&
      successful.single == matching.single;
}

void _validateRecipe(String fixtureId, ProductionL10nNegativeRecipe recipe) {
  if (!_safeIdentity(fixtureId) ||
      !_safeIdentity(recipe.observedReason) ||
      !_safeRelativePath(recipe.testPath) ||
      !recipe.testPath.startsWith('test/') ||
      !recipe.testPath.endsWith('_test.dart') ||
      recipe.testName.isEmpty ||
      recipe.testName.length > 256 ||
      recipe.testName.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    throw ArgumentError('Negative fixture recipe is malformed.');
  }
}

File _canonicalRecipeFile(Directory root, String relativePath) {
  final file = File(p.join(root.path, relativePath));
  if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
          FileSystemEntityType.file ||
      !p.isWithin(root.path, file.path) ||
      !p.equals(file.resolveSymbolicLinksSync(), file.path)) {
    throw ArgumentError('Negative fixture recipe source is not canonical.');
  }
  return file;
}

Directory _canonicalDirectory(Directory directory) {
  if (!directory.existsSync()) {
    throw ArgumentError('Negative fixture repository does not exist.');
  }
  return Directory(directory.resolveSymbolicLinksSync());
}

bool _safeIdentity(String value) =>
    value.isNotEmpty &&
    value.length <= 256 &&
    RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(value);

bool _safeRelativePath(String value) {
  final normalized = value.replaceAll('\\', '/');
  final segments = p.posix.split(normalized);
  return value == normalized &&
      p.posix.normalize(value) == value &&
      segments.every(
        (segment) =>
            segment.isNotEmpty &&
            segment != '.' &&
            segment != '..' &&
            RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(segment),
      );
}

bool _sameBytes(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String _hashCanonical(Map<String, Object?> value) =>
    sha256.convert(utf8.encode(canonicalL10nReadinessJson(value))).toString();
