import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:test/test.dart';

import '../../../benchmark/accuracy/src/l10n_mutation_manifest.dart';
import '../../../benchmark/accuracy/src/l10n_readiness_change_set_rebaser.dart';

void main() {
  group('rebaseL10nWitnessedChangeSetToRepository', () {
    test('defensively copies a repository-root package change set', () {
      final original = _changeSet(
        arbPath: 'lib/l10n/app_en.arb',
        generatedPath: 'lib/l10n/app_localizations.dart',
      );

      final rebased = rebaseL10nWitnessedChangeSetToRepository(
        project: _project(
          packageRoot: '.',
          arbPaths: const ['lib/l10n/app_en.arb'],
        ),
        packageChangeSet: original,
      );

      expect(rebased, isNot(same(original)));
      expect(rebased.arbReplacements.keys, ['lib/l10n/app_en.arb']);
      expect(rebased.generatedReplacements.keys, [
        'lib/l10n/app_localizations.dart',
      ]);
      expect(
        rebased.arbReplacements.values.single,
        isNot(same(original.arbReplacements.values.single)),
      );
      expect(
        rebased.generatedReplacements.values.single,
        isNot(same(original.generatedReplacements.values.single)),
      );
      expect(rebased.fingerprint, original.fingerprint);
    });

    test('prefixes Smooth ARB and generated paths exactly once', () {
      final original = _changeSet(
        arbPath: 'lib/l10n/app_en.arb',
        generatedPath: 'lib/l10n/app_localizations.dart',
      );

      final rebased = rebaseL10nWitnessedChangeSetToRepository(
        project: _project(
          packageRoot: 'packages/smooth_app',
          arbPaths: const ['packages/smooth_app/lib/l10n/app_en.arb'],
        ),
        packageChangeSet: original,
      );

      expect(rebased.arbReplacements.keys, [
        'packages/smooth_app/lib/l10n/app_en.arb',
      ]);
      expect(rebased.generatedReplacements.keys, [
        'packages/smooth_app/lib/l10n/app_localizations.dart',
      ]);
      final originalArb = original.arbReplacements.values.single;
      final rebasedArb = rebased.arbReplacements.values.single;
      expect(rebasedArb.beforeBytes.copy(), originalArb.beforeBytes.copy());
      expect(rebasedArb.afterBytes.copy(), originalArb.afterBytes.copy());
      expect(rebasedArb.beforeMode, originalArb.beforeMode);
      expect(rebasedArb.afterMode, originalArb.afterMode);
      final originalGenerated = original.generatedReplacements.values.single;
      final rebasedGenerated = rebased.generatedReplacements.values.single;
      expect(
        rebasedGenerated.beforeBytes.copy(),
        originalGenerated.beforeBytes.copy(),
      );
      expect(
        rebasedGenerated.afterBytes.copy(),
        originalGenerated.afterBytes.copy(),
      );
      expect(rebasedGenerated.beforeMode, originalGenerated.beforeMode);
      expect(rebasedGenerated.afterMode, originalGenerated.afterMode);
      expect(rebased.fingerprint, isNot(original.fingerprint));
    });

    test('rejects a package-root prefix already present in any input path', () {
      final inputs = [
        _changeSet(
          arbPath: 'packages/smooth_app/lib/l10n/app_en.arb',
          generatedPath: 'lib/l10n/app_localizations.dart',
        ),
        _changeSet(
          arbPath: 'lib/l10n/app_en.arb',
          generatedPath: 'packages/smooth_app/lib/l10n/app_localizations.dart',
        ),
      ];

      for (final alreadyRebased in inputs) {
        expect(
          () => rebaseL10nWitnessedChangeSetToRepository(
            project: _project(
              packageRoot: 'packages/smooth_app',
              arbPaths: const ['packages/smooth_app/lib/l10n/app_en.arb'],
            ),
            packageChangeSet: alreadyRebased,
          ),
          throwsFormatException,
        );
      }
    });

    test('rejects a rebased ARB outside the manifest authority', () {
      final unknownArb = _changeSet(
        arbPath: 'lib/l10n/app_unknown.arb',
        generatedPath: 'lib/l10n/app_localizations.dart',
      );

      expect(
        () => rebaseL10nWitnessedChangeSetToRepository(
          project: _project(
            packageRoot: 'packages/smooth_app',
            arbPaths: const ['packages/smooth_app/lib/l10n/app_en.arb'],
          ),
          packageChangeSet: unknownArb,
        ),
        throwsFormatException,
      );
    });
  });
}

L10nMutationProjectManifest _project({
  required String packageRoot,
  required List<String> arbPaths,
}) => L10nMutationProjectManifest(
  id: 'smooth',
  repositoryRevision: '0123456789012345678901234567890123456789',
  packageRootRelative: packageRoot,
  toolchainVersion: '3.38.7',
  verificationPolicy: [
    CorpusVerificationCommand(
      workingDirectoryRelativeToRepository: packageRoot,
      argumentsAfterCanonicalFlutter: const ['analyze', '--no-pub'],
    ),
  ],
  arbDirectoryRelative: packageRoot == '.'
      ? 'lib/l10n'
      : '$packageRoot/lib/l10n',
  templateArbPathRelative: arbPaths.single,
  arbPathsRelative: arbPaths,
);

L10nWitnessedChangeSet _changeSet({
  required String arbPath,
  required String generatedPath,
}) => L10nWitnessedChangeSet(
  arbReplacements: {
    arbPath: _replacement(
      arbPath,
      before: const [0x7b, 0x22, 0x64, 0x22, 0x3a, 0x31, 0x7d],
      after: const [0x7b, 0x7d],
      mode: 0x1a4,
    ),
  },
  generatedReplacements: {
    generatedPath: _replacement(
      generatedPath,
      before: const [0x67, 0x65, 0x74, 0x20, 0x64],
      after: const [0x2f, 0x2f],
      mode: 0x1a0,
    ),
  },
);

L10nFileReplacement _replacement(
  String path, {
  required List<int> before,
  required List<int> after,
  required int mode,
}) => L10nFileReplacement(
  relativePath: path,
  beforeBytes: ImmutableBytes.copyOf(before),
  afterBytes: ImmutableBytes.copyOf(after),
  beforeMode: mode,
  afterMode: mode,
);
