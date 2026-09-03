/// Test harness for l10n mutation readiness with shared views enabled.
///
/// Usage:
///   dart benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart \
///     --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2-gsy-patched.json \
///     --corpus-root /tmp/l10n_corpus \
///     --output /tmp/l10n_shared_output.json \
///     --sdk /path/to/flutter-3.10.0 \
///     --sdk /path/to/flutter-3.19.0 \
///     --sdk /path/to/flutter-3.24.0

import 'dart:io';

import 'package:path/path.dart' as p;

import 'l10n_mutation_readiness.dart';
import 'src/l10n_readiness_production.dart';

Future<void> main(List<String> arguments) async {
  print('[V3 Shared Test] Starting with shared views enabled');
  print('[V3 Shared Test] Arguments: $arguments');

  final stopwatch = Stopwatch()..start();

  try {
    final options = L10nMutationReadinessOptions.parse(arguments);
    print('[V3 Shared Test] Parsed options successfully');
    print('[V3 Shared Test] Manifest: ${options.manifestFile.path}');
    print('[V3 Shared Test] Output: ${options.outputFile.path}');
    print('[V3 Shared Test] Corpus root: ${options.corpusRoot.path}');

    final composition = await ProductionL10nReadinessComposition.create(
      options,
      enableSharedViews: true,
    );
    print('[V3 Shared Test] Composition created with shared views enabled');

    final exitCode = await runL10nMutationReadiness(
      List.unmodifiable(arguments),
      dependencies: composition.dependencies,
    );

    stopwatch.stop();
    final elapsed = stopwatch.elapsed;
    print('[V3 Shared Test] Completed in ${elapsed.inSeconds}s');
    print('[V3 Shared Test] Exit code: $exitCode');

    if (exitCode == 0) {
      print('[V3 Shared Test] SUCCESS');
    } else {
      print('[V3 Shared Test] FAILED with exit code $exitCode');
    }

    exit(exitCode);
  } catch (error, stackTrace) {
    stopwatch.stop();
    print('[V3 Shared Test] ERROR after ${stopwatch.elapsed.inSeconds}s');
    print('[V3 Shared Test] $error');
    print('[V3 Shared Test] $stackTrace');
    exit(1);
  }
}
