import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generator.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_output_reconciler.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_inventory.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:test/test.dart';

const _defaultOutput = 'lib/generated/app.dart';
const _sidecar = 'build/untranslated.json';
const _templateArb = 'lib/l10n/app_en.arb';
const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _reconciliationStage = 'output-reconciliation';

void main() {
  group('L10nGenerationAllowlist', () {
    test('freezes sorted project-relative paths and rejects overlap', () {
      final replacementPaths = <String>{
        'lib/generated/z.dart',
        'lib/generated/a.dart',
      };
      final unrelatedPaths = <String>{
        'lib/generated/manual_z.dart',
        'lib/generated/manual_a.dart',
      };
      final allowlist = L10nGenerationAllowlist(
        replacementOutputPaths: replacementPaths,
        untranslatedSidecarPath: _sidecar,
        provenUnrelatedSiblingPaths: unrelatedPaths,
      );
      replacementPaths.add('lib/generated/late.dart');
      unrelatedPaths.clear();

      expect(allowlist.replacementOutputPaths.toList(), [
        'lib/generated/a.dart',
        'lib/generated/z.dart',
      ]);
      expect(allowlist.provenUnrelatedSiblingPaths.toList(), [
        'lib/generated/manual_a.dart',
        'lib/generated/manual_z.dart',
      ]);
      expect(allowlist.untranslatedSidecarPath, _sidecar);
      expect(
        () => allowlist.replacementOutputPaths.add('lib/generated/no.dart'),
        throwsUnsupportedError,
      );
      expect(
        () => allowlist.provenUnrelatedSiblingPaths.clear(),
        throwsUnsupportedError,
      );

      for (final invalid in const [
        '',
        '.',
        '/absolute.dart',
        '../escape.dart',
        'lib/../../escape.dart',
        r'lib\generated\app.dart',
        r'C:\stage\app.dart',
      ]) {
        expect(
          () => L10nGenerationAllowlist(
            replacementOutputPaths: {invalid},
            untranslatedSidecarPath: null,
            provenUnrelatedSiblingPaths: const {},
          ),
          throwsArgumentError,
          reason: invalid,
        );
      }
      expect(
        () => L10nGenerationAllowlist(
          replacementOutputPaths: const {_defaultOutput, _sidecar},
          untranslatedSidecarPath: _sidecar,
          provenUnrelatedSiblingPaths: const {},
        ),
        throwsArgumentError,
      );
      expect(
        () => L10nGenerationAllowlist(
          replacementOutputPaths: const {_defaultOutput},
          untranslatedSidecarPath: null,
          provenUnrelatedSiblingPaths: const {_defaultOutput},
        ),
        throwsArgumentError,
      );
      expect(
        () => L10nGenerationAllowlist(
          replacementOutputPaths: const {'lib/generated'},
          untranslatedSidecarPath: null,
          provenUnrelatedSiblingPaths: const {'lib/generated/helper.dart'},
        ),
        throwsArgumentError,
      );
    });
  });

  group('L10nWitnessedChangeSet', () {
    test('rejects cross-map case-fold and ancestor aliases', () {
      L10nFileReplacement replacement(String path) => L10nFileReplacement(
        relativePath: path,
        beforeBytes: ImmutableBytes.copyOf(utf8.encode('before\n')),
        afterBytes: ImmutableBytes.copyOf(utf8.encode('after\n')),
        beforeMode: 0x1a4,
        afterMode: 0x1a4,
      );

      expect(
        () => L10nWitnessedChangeSet(
          arbReplacements: {'lib/Foo.arb': replacement('lib/Foo.arb')},
          generatedReplacements: {'lib/foo.arb': replacement('lib/foo.arb')},
        ),
        throwsArgumentError,
      );
      expect(
        () => L10nWitnessedChangeSet(
          arbReplacements: {'lib/file.arb': replacement('lib/file.arb')},
          generatedReplacements: {
            'lib/file.arb/child': replacement('lib/file.arb/child'),
          },
        ),
        throwsArgumentError,
      );
    });
  });

  group('DefaultL10nOutputReconciler', () {
    test(
      'reproduces live output exactly and witnesses ARB and generated deltas',
      () {
        final scenario = _defaultScenario();

        final ready = _expectReady(_reconcile(scenario));

        expect(ready.changeSet.arbReplacements.keys.toList(), [_templateArb]);
        final arb = ready.changeSet.arbReplacements[_templateArb]!;
        expect(
          utf8.decode(arb.beforeBytes.copy()),
          '{"alive":"Alive",'
          '"dead":"Dead"}\n',
        );
        expect(utf8.decode(arb.afterBytes.copy()), '{"alive":"Alive"}\n');
        expect(arb.beforeMode, 0x1a4);
        expect(arb.afterMode, 0x1a4);

        expect(ready.changeSet.generatedReplacements.keys.toList(), [
          _defaultOutput,
        ]);
        final generated =
            ready.changeSet.generatedReplacements[_defaultOutput]!;
        expect(
          generated.beforeBytes.contentEquals(
            _fixtureEvidence('default/live_app.dart').bytes,
          ),
          isTrue,
        );
        expect(
          generated.afterBytes.contentEquals(
            _fixtureEvidence('default/candidate_app.dart').bytes,
          ),
          isTrue,
        );
        expect(generated.beforeMode, 0x1a4);
        expect(generated.afterMode, generated.beforeMode);
        expect(ready.changeSet.fingerprint, matches(RegExp(r'^[a-f0-9]{64}$')));
      },
    );

    test(
      'governs ARB inputs beside generated outputs without sibling aliasing',
      () {
        final scenario = _sharedArbAndOutputDirectoryScenario();

        final ready = _expectReady(_reconcile(scenario));

        expect(ready.changeSet.arbReplacements.keys, {'lib/l10n/app_en.arb'});
        expect(ready.changeSet.generatedReplacements.keys, {
          'lib/l10n/app.dart',
        });
      },
    );

    test('returns deeply immutable sorted replacements and byte values', () {
      final scenario = _defaultScenario(
        siblings: {
          'lib/generated/z_helper.dart': _bytesEvidence('int z = 1;\n'),
          'lib/generated/a_helper.dart': _bytesEvidence('int a = 1;\n'),
        },
        provenSiblings: const {
          'lib/generated/z_helper.dart',
          'lib/generated/a_helper.dart',
        },
      );
      final ready = _expectReady(_reconcile(scenario));
      final generated = ready.changeSet.generatedReplacements[_defaultOutput]!;
      final copied = generated.afterBytes.copy();
      copied[0] ^= 0xff;

      expect(
        generated.afterBytes.contentEquals(
          _fixtureEvidence('default/candidate_app.dart').bytes,
        ),
        isTrue,
      );
      expect(
        () => ready.changeSet.arbReplacements.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => ready.changeSet.generatedReplacements[_defaultOutput] = generated,
        throwsUnsupportedError,
      );
      expect(
        ready.changeSet.generatedReplacements.values
            .map((replacement) => replacement.relativePath)
            .toList(),
        [_defaultOutput],
      );
    });

    for (final drift in _BaselineDrift.values) {
      test('rejects stale baseline ${drift.name}', () {
        final scenario = _defaultScenario();
        final live = _fixtureEvidence('default/live_app.dart');
        final afterEntry = switch (drift) {
          _BaselineDrift.missing => null,
          _BaselineDrift.type => _directory(_defaultOutput),
          _BaselineDrift.bytes => _file(
            _defaultOutput,
            _bytesEvidence('class Stale {}\n'),
          ),
          _BaselineDrift.mode => _file(_defaultOutput, live, mode: 0x180),
        };
        final baseline = _replaceAfterEntry(
          scenario.baseline,
          _defaultOutput,
          afterEntry,
        );

        _expectOnlyFailure(
          _reconcile(scenario, baseline: baseline),
          L10nEvidenceRejectionCode.staleGeneratedOutput,
          'baseline-output-mismatch',
          stage: _reconciliationStage,
          relativePath: _defaultOutput,
        );
      });
    }

    test('rejects a live-missing output created by baseline generation', () {
      final scenario = _defaultScenario(
        liveOutputPresent: false,
        candidateOutputPresent: false,
      );
      final baseline = _replaceAfterEntry(
        scenario.baseline,
        _defaultOutput,
        _file(_defaultOutput, _fixtureEvidence('default/live_app.dart')),
      );

      _expectOnlyFailure(
        _reconcile(scenario, baseline: baseline),
        L10nEvidenceRejectionCode.staleGeneratedOutput,
        'baseline-output-mismatch',
        stage: _reconciliationStage,
        relativePath: _defaultOutput,
      );
    });

    test('rejects a required output absent live and after baseline', () {
      final scenario = _defaultScenario(
        liveOutputPresent: false,
        candidateOutputPresent: false,
      );

      _expectOnlyFailure(
        _reconcile(scenario),
        L10nEvidenceRejectionCode.staleGeneratedOutput,
        'baseline-output-mismatch',
        stage: _reconciliationStage,
        relativePath: _defaultOutput,
      );
    });

    test(
      'rejects an unchanged generated-provenance sibling despite a proof claim',
      () {
        const sibling = 'lib/generated/legacy.g.dart';
        final scenario = _defaultScenario(
          siblings: {
            sibling: _fixtureEvidence('default/generated_sibling.dart'),
          },
          provenSiblings: const {sibling},
        );

        _expectOnlyFailure(
          _reconcile(scenario),
          L10nEvidenceRejectionCode.outputFamilyAmbiguous,
          'generated-provenance-sibling-unowned',
          stage: _reconciliationStage,
          relativePath: sibling,
        );
      },
    );

    test('rejects content-declared generated provenance despite proof', () {
      const sibling = 'lib/generated/legacy.dart';
      final scenario = _defaultScenario(
        siblings: {sibling: _fixtureEvidence('default/generated_sibling.dart')},
        provenSiblings: const {sibling},
      );

      _expectOnlyFailure(
        _reconcile(scenario),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'generated-provenance-sibling-unowned',
        stage: _reconciliationStage,
        relativePath: sibling,
      );
    });

    test('rejects intl generated provenance despite an ordinary path', () {
      const sibling = 'lib/generated/messages_all.dart';
      final scenario = _defaultScenario(
        siblings: {
          sibling: _bytesEvidence(
            '// Copyright fixture\n'
            '// DO NOT EDIT. This is code generated via '
            'package:intl/generate_localized.dart\n'
            'class MessagesAll {}\n',
          ),
        },
        provenSiblings: const {sibling},
      );

      _expectOnlyFailure(
        _reconcile(scenario),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'generated-provenance-sibling-unowned',
        stage: _reconciliationStage,
        relativePath: sibling,
      );
    });

    test('rejects an unchanged unowned output-family sibling', () {
      const sibling = 'lib/generated/app_legacy.dart';
      final scenario = _defaultScenario(
        siblings: {sibling: _bytesEvidence('class AppLegacy {}\n')},
      );

      _expectOnlyFailure(
        _reconcile(scenario),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'unowned-output-family-sibling',
        stage: _reconciliationStage,
        relativePath: sibling,
      );
    });

    test('rejects an unchanged inventory-only output-family sibling', () {
      const sibling = 'lib/generated/app_rogue.dart';
      final scenario = _defaultScenario();
      final entry = _file(
        sibling,
        _bytesEvidence('class AppRogue {}\n'),
        capture: false,
      );

      _expectOnlyFailure(
        _reconcile(
          scenario,
          baseline: _withStableEntry(scenario.baseline, sibling, entry),
          candidate: _withStableEntry(scenario.candidate, sibling, entry),
        ),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'unowned-output-family-sibling',
        stage: _reconciliationStage,
        relativePath: sibling,
      );
    });

    test('rejects an unchanged pre-run file outside snapshot authority', () {
      const path = 'lib/foreign.dart';
      final scenario = _defaultScenario();
      final entry = _file(
        path,
        _bytesEvidence('class ForeignInput {}\n'),
        capture: false,
      );

      _expectOnlyFailure(
        _reconcile(
          scenario,
          baseline: _withStableEntry(scenario.baseline, path, entry),
        ),
        L10nEvidenceRejectionCode.baselineGenerationFailed,
        'baseline-stage-prestate-extra',
        stage: _reconciliationStage,
        relativePath: path,
      );
    });

    test('accepts a proven unrelated sibling only while exactly unchanged', () {
      const sibling = 'lib/generated/helper.dart';
      final scenario = _defaultScenario(
        siblings: {sibling: _fixtureEvidence('default/unrelated_helper.dart')},
        provenSiblings: const {sibling},
      );

      expect(_reconcile(scenario), isA<L10nReconciliationReady>());

      final changedCandidate = _replaceAfterEntry(
        scenario.candidate,
        sibling,
        _file(sibling, _bytesEvidence('String helper() => "changed";\n')),
      );
      _expectOnlyFailure(
        _reconcile(scenario, candidate: changedCandidate),
        L10nEvidenceRejectionCode.unexpectedStageWrite,
        'unexpected-stage-write',
        stage: 'candidate-generation',
        relativePath: sibling,
      );
    });

    test('rejects an allowlist that diverges from snapshot authority', () {
      const sibling = 'lib/generated/helper.dart';
      final scenario = _defaultScenario(
        withSidecar: true,
        siblings: {sibling: _fixtureEvidence('default/unrelated_helper.dart')},
        provenSiblings: const {sibling},
      );
      final mismatches = [
        L10nGenerationAllowlist(
          replacementOutputPaths: const {'lib/generated/other.dart'},
          untranslatedSidecarPath: _sidecar,
          provenUnrelatedSiblingPaths: const {sibling},
        ),
        L10nGenerationAllowlist(
          replacementOutputPaths: const {_defaultOutput},
          untranslatedSidecarPath: null,
          provenUnrelatedSiblingPaths: const {sibling},
        ),
        L10nGenerationAllowlist(
          replacementOutputPaths: const {_defaultOutput},
          untranslatedSidecarPath: _sidecar,
          provenUnrelatedSiblingPaths: const {},
        ),
      ];

      for (final mismatched in mismatches) {
        _expectOnlyFailure(
          _reconcile(scenario, allowlist: mismatched),
          L10nEvidenceRejectionCode.outputFamilyAmbiguous,
          'generation-allowlist-snapshot-mismatch',
          stage: _reconciliationStage,
        );
      }
    });

    for (final mutation in _UnexpectedMutation.values) {
      test('rejects unexpected ${mutation.name} in either generator tree', () {
        final scenario = _defaultScenario();
        final phase = mutation.index.isEven
            ? L10nGenerationPhase.baseline
            : L10nGenerationPhase.candidate;
        final original = phase == L10nGenerationPhase.baseline
            ? scenario.baseline
            : scenario.candidate;
        final changed = _unexpectedMutation(original, mutation);

        _expectOnlyFailure(
          _reconcile(
            scenario,
            baseline: phase == L10nGenerationPhase.baseline ? changed : null,
            candidate: phase == L10nGenerationPhase.candidate ? changed : null,
          ),
          L10nEvidenceRejectionCode.unexpectedStageWrite,
          'unexpected-stage-write',
          stage: '${phase.name}-generation',
          relativePath: 'tmp/${mutation.name}.txt',
        );
      });
    }

    test('accepts a configured sidecar absent in every witnessed state', () {
      final scenario = _defaultScenario(withSidecar: true);

      final ready = _expectReady(_reconcile(scenario));

      expect(ready.changeSet.generatedReplacements, isNot(contains(_sidecar)));
    });

    test('witnesses an exact present sidecar replacement', () {
      final scenario = _defaultScenario(
        withSidecar: true,
        liveSidecar: _bytesEvidence('{"dead":["en"]}\n'),
        candidateSidecar: _bytesEvidence('{}\n'),
      );

      final ready = _expectReady(_reconcile(scenario));
      final sidecar = ready.changeSet.generatedReplacements[_sidecar]!;

      expect(utf8.decode(sidecar.beforeBytes.copy()), '{"dead":["en"]}\n');
      expect(utf8.decode(sidecar.afterBytes.copy()), '{}\n');
      expect(sidecar.beforeMode, 0x1a4);
      expect(sidecar.afterMode, sidecar.beforeMode);
    });

    test('rejects candidate generated and sidecar mode drift', () {
      final generatedScenario = _defaultScenario();
      final generatedCandidate = _replaceAfterEntry(
        generatedScenario.candidate,
        _defaultOutput,
        _file(
          _defaultOutput,
          _fixtureEvidence('default/candidate_app.dart'),
          mode: 0x180,
        ),
      );
      _expectOnlyFailure(
        _reconcile(generatedScenario, candidate: generatedCandidate),
        L10nEvidenceRejectionCode.candidateGenerationFailed,
        'candidate-output-mode-mismatch',
        stage: _reconciliationStage,
        relativePath: _defaultOutput,
      );

      final sidecarScenario = _defaultScenario(
        withSidecar: true,
        liveSidecar: _bytesEvidence('{"dead":["en"]}\n'),
        candidateSidecar: _bytesEvidence('{}\n'),
      );
      final sidecarCandidate = _replaceAfterEntry(
        sidecarScenario.candidate,
        _sidecar,
        _file(_sidecar, _bytesEvidence('{}\n'), mode: 0x180),
      );
      _expectOnlyFailure(
        _reconcile(sidecarScenario, candidate: sidecarCandidate),
        L10nEvidenceRejectionCode.candidateGenerationFailed,
        'candidate-output-mode-mismatch',
        stage: _reconciliationStage,
        relativePath: _sidecar,
      );
    });

    test('rejects sidecar creation and deletion in the candidate', () {
      final creation = _defaultScenario(
        withSidecar: true,
        candidateSidecar: _bytesEvidence('{}\n'),
      );
      _expectOnlyFailure(
        _reconcile(creation),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'candidate-output-shape-changed',
        stage: _reconciliationStage,
        relativePath: _sidecar,
      );

      final deletion = _defaultScenario(
        withSidecar: true,
        liveSidecar: _bytesEvidence('{"dead":["en"]}\n'),
      );
      _expectOnlyFailure(
        _reconcile(deletion),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'candidate-output-shape-changed',
        stage: _reconciliationStage,
        relativePath: _sidecar,
      );
    });

    test('rejects a stale present sidecar baseline', () {
      final scenario = _defaultScenario(
        withSidecar: true,
        liveSidecar: _bytesEvidence('{"dead":["en"]}\n'),
        candidateSidecar: _bytesEvidence('{"dead":["en"]}\n'),
      );
      final baseline = _replaceAfterEntry(
        scenario.baseline,
        _sidecar,
        _file(_sidecar, _bytesEvidence('{}\n')),
      );

      _expectOnlyFailure(
        _reconcile(scenario, baseline: baseline),
        L10nEvidenceRejectionCode.staleGeneratedOutput,
        'baseline-output-mismatch',
        stage: _reconciliationStage,
        relativePath: _sidecar,
      );
    });

    test('honors a custom output directory, filename, and class', () {
      final scenario = _customScenario();

      final ready = _expectReady(_reconcile(scenario));

      expect(ready.changeSet.generatedReplacements.keys.toList(), [
        'lib/i18n/generated/strings.dart',
      ]);
      final replacement = ready.changeSet.generatedReplacements.values.single;
      expect(
        utf8.decode(replacement.beforeBytes.copy()),
        contains('class Strings'),
      );
      expect(
        utf8.decode(replacement.afterBytes.copy()),
        isNot(contains('get dead')),
      );
      expect(
        scenario.snapshot.entries['l10n.yaml']!.state,
        isA<L10nSnapshotPresent>(),
      );
    });

    test('maps regional locales to one base-language generated file', () {
      final scenario = _regionalScenario();

      final ready = _expectReady(_reconcile(scenario));

      expect(scenario.snapshot.expectedGeneratedPaths.toList(), [
        'lib/generated/strings.dart',
        'lib/generated/strings_en.dart',
        'lib/generated/strings_fr.dart',
      ]);
      expect(
        scenario.snapshot.expectedGeneratedPaths,
        isNot(contains('lib/generated/strings_en_US.dart')),
      );
      expect(ready.changeSet.generatedReplacements.keys.toList(), [
        'lib/generated/strings.dart',
        'lib/generated/strings_en.dart',
        'lib/generated/strings_fr.dart',
      ]);
      expect(ready.changeSet.arbReplacements.keys.toList(), [
        'lib/i18n/messages_en.arb',
        'lib/i18n/messages_en_US.arb',
        'lib/i18n/messages_fr.arb',
      ]);
    });

    test('checks but does not journal a no-op locale ARB', () {
      const noOpPath = 'lib/i18n/messages_fr.arb';
      final scenario = _regionalScenario(frenchHasSelectedKey: false);

      final ready = _expectReady(_reconcile(scenario));

      expect(ready.changeSet.arbReplacements, isNot(contains(noOpPath)));
      expect(
        ready.changeSet.generatedReplacements,
        isNot(contains('lib/generated/strings_fr.dart')),
      );

      final wrongNoOp = _bytesEvidence(
        '{"@@locale":"fr","alive":"Different"}\n',
      );
      final beforeEntries = Map<String, L10nStageEntry>.of(
        scenario.candidate.before.entries,
      )..[noOpPath] = _file(noOpPath, wrongNoOp, capture: false);
      final afterEntries = Map<String, L10nStageEntry>.of(
        scenario.candidate.after.entries,
      )..[noOpPath] = _file(noOpPath, wrongNoOp, capture: false);
      final candidate = _copyRun(
        scenario.candidate,
        before: _capture(beforeEntries),
        after: _capture(afterEntries),
      );

      _expectOnlyFailure(
        _reconcile(scenario, candidate: candidate),
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'candidate-arb-prestate-mismatch',
        stage: _reconciliationStage,
        relativePath: noOpPath,
      );
    });

    test('rejects candidate generated path deletion and type drift', () {
      final deletion = _scenarioWithSecondaryOutput(
        liveSecondary: _bytesEvidence('class LanguageOutput {}\n'),
        candidateSecondary: null,
      );
      _expectOnlyFailure(
        _reconcile(deletion),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'candidate-output-shape-changed',
        stage: _reconciliationStage,
        relativePath: 'lib/generated/app_en.dart',
      );

      final typeDrift = _scenarioWithSecondaryOutput(
        liveSecondary: _bytesEvidence('class LanguageOutput {}\n'),
        candidateSecondary: _bytesEvidence('class LanguageOutput {}\n'),
      );
      final candidate = _replaceAfterEntry(
        typeDrift.candidate,
        'lib/generated/app_en.dart',
        _directory('lib/generated/app_en.dart'),
      );
      _expectOnlyFailure(
        _reconcile(typeDrift, candidate: candidate),
        L10nEvidenceRejectionCode.outputFamilyAmbiguous,
        'candidate-output-shape-changed',
        stage: _reconciliationStage,
        relativePath: 'lib/generated/app_en.dart',
      );
    });

    test(
      'propagates either generator run failure and refuses a change set',
      () {
        for (final phase in L10nGenerationPhase.values) {
          final scenario = _defaultScenario(commandSalt: phase.name);
          final failure = L10nEvidenceFailure(
            code: phase == L10nGenerationPhase.baseline
                ? L10nEvidenceRejectionCode.baselineGenerationFailed
                : L10nEvidenceRejectionCode.candidateGenerationFailed,
            stage: '${phase.name}-generation',
            detailCode: 'generation-process-nonzero',
          );
          final failed = _copyRun(
            phase == L10nGenerationPhase.baseline
                ? scenario.baseline
                : scenario.candidate,
            failures: [failure],
          );

          _expectOnlyFailure(
            _reconcile(
              scenario,
              baseline: phase == L10nGenerationPhase.baseline ? failed : null,
              candidate: phase == L10nGenerationPhase.candidate ? failed : null,
            ),
            failure.code,
            failure.detailCode,
            stage: failure.stage,
          );
        }
      },
    );

    test('rejects swapped generation phases before reconciliation', () {
      final scenario = _defaultScenario();
      final wrongBaseline = _copyRun(
        scenario.baseline,
        phase: L10nGenerationPhase.candidate,
      );
      _expectOnlyFailure(
        _reconcile(scenario, baseline: wrongBaseline),
        L10nEvidenceRejectionCode.baselineGenerationFailed,
        'generation-phase-mismatch',
        stage: _reconciliationStage,
      );

      final wrongCandidate = _copyRun(
        scenario.candidate,
        phase: L10nGenerationPhase.baseline,
      );
      _expectOnlyFailure(
        _reconcile(scenario, candidate: wrongCandidate),
        L10nEvidenceRejectionCode.candidateGenerationFailed,
        'generation-phase-mismatch',
        stage: _reconciliationStage,
      );
    });

    test('rejects a baseline and candidate command identity collision', () {
      final scenario = _defaultScenario();
      final candidate = _copyRun(
        scenario.candidate,
        commandIdentity: scenario.baseline.commandIdentity,
      );

      _expectOnlyFailure(
        _reconcile(scenario, candidate: candidate),
        L10nEvidenceRejectionCode.toolchainDrift,
        'generation-command-identity-collision',
        stage: _reconciliationStage,
      );
    });

    test(
      'rejects candidate pre-run ARBs outside snapshot mutation authority',
      () {
        final scenario = _defaultScenario();
        final sourceArb = _bytesEvidence('{"alive":"Alive","dead":"Dead"}\n');
        final beforeEntries = Map<String, L10nStageEntry>.of(
          scenario.candidate.before.entries,
        )..[_templateArb] = _file(_templateArb, sourceArb, capture: false);
        final afterEntries = Map<String, L10nStageEntry>.of(
          scenario.candidate.after.entries,
        )..[_templateArb] = _file(_templateArb, sourceArb, capture: false);
        final candidate = _copyRun(
          scenario.candidate,
          before: _capture(beforeEntries),
          after: _capture(afterEntries),
        );

        _expectOnlyFailure(
          _reconcile(scenario, candidate: candidate),
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          'candidate-arb-prestate-mismatch',
          stage: _reconciliationStage,
          relativePath: _templateArb,
        );
      },
    );

    test(
      'rejects invalid, unavailable, or incompletely captured inventories',
      () {
        final scenario = _defaultScenario();
        final unavailable = _copyRun(
          scenario.baseline,
          before: L10nStageInventoryCapture.unavailable(),
          after: L10nStageInventoryCapture.unavailable(),
        );
        _expectFailureCode(
          _reconcile(scenario, baseline: unavailable),
          L10nEvidenceRejectionCode.unexpectedStageWrite,
        );

        final invalidAfter = _copyRun(
          scenario.candidate,
          after: _capture(
            scenario.candidate.after.entries,
            invalidPaths: const {'escape'},
          ),
        );
        _expectFailureCode(
          _reconcile(scenario, candidate: invalidAfter),
          L10nEvidenceRejectionCode.unexpectedStageWrite,
        );

        final output = scenario.baseline.after.entries[_defaultOutput]!;
        final uncaptured = _replaceAfterEntry(
          scenario.baseline,
          _defaultOutput,
          L10nStageEntry(
            relativePath: output.relativePath,
            kind: output.kind,
            sha256: output.sha256,
            posixMode: output.posixMode,
            capturedBytes: null,
          ),
        );
        _expectFailureCode(
          _reconcile(scenario, baseline: uncaptured),
          L10nEvidenceRejectionCode.staleGeneratedOutput,
        );

        final source = scenario.baseline.before.entries['lib/main.dart']!;
        final corrupt = L10nStageEntry(
          relativePath: source.relativePath,
          kind: source.kind,
          sha256: source.sha256,
          posixMode: source.posixMode,
          capturedBytes: ImmutableBytes.copyOf(utf8.encode('corrupt\n')),
        );
        _expectOnlyFailure(
          _reconcile(
            scenario,
            baseline: _withStableEntry(
              scenario.baseline,
              source.relativePath,
              corrupt,
            ),
          ),
          L10nEvidenceRejectionCode.unexpectedStageWrite,
          'inventory-entry-evidence-invalid',
          stage: 'baseline-generation',
          relativePath: source.relativePath,
        );
      },
    );

    test(
      'rejects unreported nonzero, timeout, null, and truncated processes',
      () {
        final cases =
            <
              ({
                String name,
                L10nGenerationPhase phase,
                ManagedProcessResult? process,
                L10nEvidenceRejectionCode code,
              })
            >[
              (
                name: 'nonzero',
                phase: L10nGenerationPhase.baseline,
                process: _process(exitCode: 7),
                code: L10nEvidenceRejectionCode.baselineGenerationFailed,
              ),
              (
                name: 'timeout',
                phase: L10nGenerationPhase.candidate,
                process: _process(exitCode: -1, timedOut: true),
                code: L10nEvidenceRejectionCode.candidateGenerationFailed,
              ),
              (
                name: 'missing result',
                phase: L10nGenerationPhase.baseline,
                process: null,
                code: L10nEvidenceRejectionCode.baselineGenerationFailed,
              ),
              (
                name: 'truncated output',
                phase: L10nGenerationPhase.candidate,
                process: _process(stdoutOmittedBytes: 1),
                code: L10nEvidenceRejectionCode.generatorOutputTruncated,
              ),
            ];

        for (final testCase in cases) {
          final scenario = _defaultScenario(commandSalt: testCase.name);
          final original = testCase.phase == L10nGenerationPhase.baseline
              ? scenario.baseline
              : scenario.candidate;
          final failed = _copyRun(original, processResult: testCase.process);

          _expectFailureCode(
            _reconcile(
              scenario,
              baseline: testCase.phase == L10nGenerationPhase.baseline
                  ? failed
                  : null,
              candidate: testCase.phase == L10nGenerationPhase.candidate
                  ? failed
                  : null,
            ),
            testCase.code,
            reason: testCase.name,
          );
        }
      },
    );

    test('sorts and freezes every rejected failure', () {
      final rejected = L10nReconciliationRejected([
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.outputFamilyAmbiguous,
          stage: _reconciliationStage,
          detailCode: 'z-detail',
          relativePath: 'z.dart',
        ),
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.staleGeneratedOutput,
          stage: _reconciliationStage,
          detailCode: 'z-detail',
          relativePath: 'z.dart',
        ),
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.staleGeneratedOutput,
          stage: _reconciliationStage,
          detailCode: 'null-path',
        ),
        const L10nEvidenceFailure(
          code: L10nEvidenceRejectionCode.staleGeneratedOutput,
          stage: _reconciliationStage,
          detailCode: 'a-detail',
          relativePath: 'a.dart',
        ),
      ]);

      expect(
        rejected.failures
            .map(
              (failure) =>
                  '${failure.code.name}|${failure.stage}|'
                  '${failure.relativePath}|${failure.detailCode}',
            )
            .toList(),
        [
          'staleGeneratedOutput|output-reconciliation|null|null-path',
          'staleGeneratedOutput|output-reconciliation|a.dart|a-detail',
          'staleGeneratedOutput|output-reconciliation|z.dart|z-detail',
          'outputFamilyAmbiguous|output-reconciliation|z.dart|z-detail',
        ],
      );
      expect(
        () => rejected.failures.add(
          const L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.internalFailure,
            stage: 'test',
            detailCode: 'test',
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test(
      'fingerprint ignores input order and stage identity but binds bytes and mode',
      () {
        final first = _expectReady(
          _reconcile(_regionalScenario(commandSalt: 'stage-root-one')),
        );
        final reordered = _expectReady(
          _reconcile(
            _regionalScenario(
              commandSalt: 'stage-root-two',
              reverseInputs: true,
            ),
          ),
        );
        final byteChanged = _expectReady(
          _reconcile(
            _defaultScenario(
              candidateOutput: _bytesEvidence('class Different {}\n'),
            ),
          ),
        );
        final defaultReady = _expectReady(_reconcile(_defaultScenario()));
        final modeChanged = _expectReady(
          _reconcile(_defaultScenario(outputMode: 0x180)),
        );

        expect(reordered.changeSet.fingerprint, first.changeSet.fingerprint);
        expect(
          byteChanged.changeSet.fingerprint,
          isNot(defaultReady.changeSet.fingerprint),
        );
        expect(
          modeChanged.changeSet.fingerprint,
          isNot(defaultReady.changeSet.fingerprint),
        );
        for (final path in [
          ...first.changeSet.arbReplacements.keys,
          ...first.changeSet.generatedReplacements.keys,
        ]) {
          expect(_isProjectRelativePosix(path), isTrue, reason: path);
        }
      },
    );
  });
}

enum _BaselineDrift { missing, type, bytes, mode }

enum _UnexpectedMutation { create, modify, delete, link, type, mode, content }

final class _FileEvidence {
  _FileEvidence(ImmutableBytes bytes, {required this.mode})
    : bytes = ImmutableBytes.copyOf(bytes.copy());

  final ImmutableBytes bytes;
  final int? mode;
}

final class _Scenario {
  const _Scenario({
    required this.snapshot,
    required this.allowlist,
    required this.baseline,
    required this.candidate,
  });

  final L10nFamilySnapshot snapshot;
  final L10nGenerationAllowlist allowlist;
  final L10nGenerationRun baseline;
  final L10nGenerationRun candidate;
}

_Scenario _defaultScenario({
  bool liveOutputPresent = true,
  bool candidateOutputPresent = true,
  _FileEvidence? candidateOutput,
  int outputMode = 0x1a4,
  bool withSidecar = false,
  _FileEvidence? liveSidecar,
  _FileEvidence? candidateSidecar,
  Map<String, _FileEvidence> siblings = const {},
  Set<String> provenSiblings = const {},
  String commandSalt = 'default',
}) {
  final live = _fixtureEvidence('default/live_app.dart', mode: outputMode);
  final candidate =
      candidateOutput ??
      _fixtureEvidence('default/candidate_app.dart', mode: outputMode);
  return _buildScenario(
    templatePath: _templateArb,
    arbSources: {
      _templateArb: utf8.encode('{"alive":"Alive","dead":"Dead"}\n'),
    },
    baseOutputPath: _defaultOutput,
    expectedOutputPaths: const [_defaultOutput],
    liveOutputs: {_defaultOutput: liveOutputPresent ? live : null},
    candidateOutputs: {
      _defaultOutput: candidateOutputPresent ? candidate : null,
    },
    l10nYaml:
        'arb-dir: lib/l10n\n'
        'template-arb-file: app_en.arb\n'
        'output-dir: lib/generated\n'
        'output-localization-file: app.dart\n'
        'output-class: AppLocalizations\n'
        'synthetic-package: false\n',
    optionalSidecarPath: withSidecar ? _sidecar : null,
    liveSidecar: liveSidecar,
    candidateSidecar: candidateSidecar,
    siblings: siblings,
    provenSiblings: provenSiblings,
    commandSalt: commandSalt,
  );
}

_Scenario _customScenario() => _buildScenario(
  templatePath: 'assets/i18n/messages_en.arb',
  arbSources: {
    'assets/i18n/messages_en.arb': utf8.encode(
      '{"alive":"Alive","dead":"Dead"}\n',
    ),
  },
  baseOutputPath: 'lib/i18n/generated/strings.dart',
  expectedOutputPaths: const ['lib/i18n/generated/strings.dart'],
  liveOutputs: {
    'lib/i18n/generated/strings.dart': _fixtureEvidence(
      'custom/live_strings.dart',
    ),
  },
  candidateOutputs: {
    'lib/i18n/generated/strings.dart': _fixtureEvidence(
      'custom/candidate_strings.dart',
    ),
  },
  l10nYaml:
      'arb-dir: assets/i18n\n'
      'template-arb-file: messages_en.arb\n'
      'output-dir: lib/i18n/generated\n'
      'output-localization-file: strings.dart\n'
      'output-class: Strings\n'
      'synthetic-package: false\n',
);

_Scenario _sharedArbAndOutputDirectoryScenario() => _buildScenario(
  templatePath: 'lib/l10n/app_en.arb',
  arbSources: {
    'lib/l10n/app_en.arb': utf8.encode('{"alive":"Alive","dead":"Dead"}\n'),
  },
  baseOutputPath: 'lib/l10n/app.dart',
  expectedOutputPaths: const ['lib/l10n/app.dart'],
  liveOutputs: {'lib/l10n/app.dart': _fixtureEvidence('default/live_app.dart')},
  candidateOutputs: {
    'lib/l10n/app.dart': _fixtureEvidence('default/candidate_app.dart'),
  },
  l10nYaml:
      'arb-dir: lib/l10n\n'
      'template-arb-file: app_en.arb\n'
      'output-dir: lib/l10n\n'
      'output-localization-file: app.dart\n'
      'output-class: AppLocalizations\n'
      'synthetic-package: false\n',
);

_Scenario _regionalScenario({
  String commandSalt = 'regional',
  bool reverseInputs = false,
  bool frenchHasSelectedKey = true,
}) {
  const outputs = [
    'lib/generated/strings.dart',
    'lib/generated/strings_en.dart',
    'lib/generated/strings_fr.dart',
  ];
  return _buildScenario(
    templatePath: 'lib/i18n/messages_en.arb',
    arbSources: {
      'lib/i18n/messages_en.arb': _fixtureBytes('regional/messages_en.arb'),
      'lib/i18n/messages_en_US.arb': _fixtureBytes(
        'regional/messages_en_US.arb',
      ),
      'lib/i18n/messages_fr.arb': _fixtureBytes(
        frenchHasSelectedKey
            ? 'regional/messages_fr.arb'
            : 'regional/messages_fr_without_dead.arb',
      ),
    },
    baseOutputPath: outputs.first,
    expectedOutputPaths: outputs,
    liveOutputs: {
      outputs[0]: _fixtureEvidence('regional/live_strings.dart'),
      outputs[1]: _fixtureEvidence('regional/live_strings_en.dart'),
      outputs[2]: _fixtureEvidence(
        frenchHasSelectedKey
            ? 'regional/live_strings_fr.dart'
            : 'regional/candidate_strings_fr.dart',
      ),
    },
    candidateOutputs: {
      outputs[0]: _fixtureEvidence('regional/candidate_strings.dart'),
      outputs[1]: _fixtureEvidence('regional/candidate_strings_en.dart'),
      outputs[2]: _fixtureEvidence('regional/candidate_strings_fr.dart'),
    },
    l10nYaml:
        'arb-dir: lib/i18n\n'
        'template-arb-file: messages_en.arb\n'
        'output-dir: lib/generated\n'
        'output-localization-file: strings.dart\n'
        'output-class: Strings\n'
        'synthetic-package: false\n',
    commandSalt: commandSalt,
    reverseInputs: reverseInputs,
  );
}

_Scenario _scenarioWithSecondaryOutput({
  required _FileEvidence? liveSecondary,
  required _FileEvidence? candidateSecondary,
}) => _buildScenario(
  templatePath: _templateArb,
  arbSources: {_templateArb: utf8.encode('{"alive":"Alive","dead":"Dead"}\n')},
  baseOutputPath: _defaultOutput,
  expectedOutputPaths: const [_defaultOutput, 'lib/generated/app_en.dart'],
  liveOutputs: {
    _defaultOutput: _fixtureEvidence('default/live_app.dart'),
    'lib/generated/app_en.dart': liveSecondary,
  },
  candidateOutputs: {
    _defaultOutput: _fixtureEvidence('default/candidate_app.dart'),
    'lib/generated/app_en.dart': candidateSecondary,
  },
  l10nYaml:
      'arb-dir: lib/l10n\n'
      'template-arb-file: app_en.arb\n'
      'output-dir: lib/generated\n'
      'output-localization-file: app.dart\n'
      'synthetic-package: false\n',
);

_Scenario _buildScenario({
  required String templatePath,
  required Map<String, List<int>> arbSources,
  required String baseOutputPath,
  required List<String> expectedOutputPaths,
  required Map<String, _FileEvidence?> liveOutputs,
  required Map<String, _FileEvidence?> candidateOutputs,
  required String l10nYaml,
  String? optionalSidecarPath,
  _FileEvidence? liveSidecar,
  _FileEvidence? candidateSidecar,
  Map<String, _FileEvidence> siblings = const {},
  Set<String> provenSiblings = const {},
  String commandSalt = 'scenario',
  bool reverseInputs = false,
}) {
  if (liveOutputs.keys
          .toSet()
          .difference(expectedOutputPaths.toSet())
          .isNotEmpty ||
      expectedOutputPaths
          .toSet()
          .difference(liveOutputs.keys.toSet())
          .isNotEmpty ||
      candidateOutputs.keys
          .toSet()
          .difference(expectedOutputPaths.toSet())
          .isNotEmpty ||
      expectedOutputPaths
          .toSet()
          .difference(candidateOutputs.keys.toSet())
          .isNotEmpty) {
    throw StateError('Fixture output maps must be exact.');
  }
  final orderedArbs = reverseInputs
      ? arbSources.entries.toList().reversed
      : arbSources.entries;
  final orderedOutputs = reverseInputs
      ? expectedOutputPaths.reversed
      : expectedOutputPaths;
  final entries = <String, L10nSnapshotEntry>{
    'pubspec.yaml': _presentSnapshot(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      utf8.encode('name: fixture\n'),
    ),
    'pubspec.lock': _presentSnapshot(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      utf8.encode('packages: {}\n'),
    ),
    'l10n.yaml': _presentSnapshot(
      'l10n.yaml',
      L10nSnapshotRole.l10nConfig,
      utf8.encode(l10nYaml),
    ),
    '.dart_tool/package_config.json': _presentSnapshot(
      '.dart_tool/package_config.json',
      L10nSnapshotRole.packageConfig,
      utf8.encode('{"configVersion":2,"packages":[]}\n'),
    ),
    '.dart_tool/package_graph.json': _absentSnapshot(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
    ),
    'analysis_options.yaml': _absentSnapshot(
      'analysis_options.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'dart_test.yaml': _absentSnapshot(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'lib/main.dart': _presentSnapshot(
      'lib/main.dart',
      L10nSnapshotRole.analyzerSource,
      utf8.encode('void main() {}\n'),
    ),
    for (final arb in orderedArbs)
      arb.key: _presentSnapshot(
        arb.key,
        arb.key == templatePath
            ? L10nSnapshotRole.arbTemplate
            : L10nSnapshotRole.arbLocale,
        arb.value,
      ),
    for (final path in orderedOutputs)
      path: liveOutputs[path] == null
          ? _absentSnapshot(
              path,
              path == baseOutputPath
                  ? L10nSnapshotRole.generatedBase
                  : L10nSnapshotRole.generatedLanguage,
            )
          : _presentSnapshotEvidence(
              path,
              path == baseOutputPath
                  ? L10nSnapshotRole.generatedBase
                  : L10nSnapshotRole.generatedLanguage,
              liveOutputs[path]!,
            ),
    if (optionalSidecarPath != null)
      optionalSidecarPath: liveSidecar == null
          ? _absentSnapshot(
              optionalSidecarPath,
              L10nSnapshotRole.untranslatedSidecar,
            )
          : _presentSnapshotEvidence(
              optionalSidecarPath,
              L10nSnapshotRole.untranslatedSidecar,
              liveSidecar,
            ),
    for (final sibling in siblings.entries)
      sibling.key: _presentSnapshotEvidence(
        sibling.key,
        L10nSnapshotRole.analyzerSource,
        sibling.value,
      ),
  };
  final documents = <String, ArbDocument>{};
  for (final arb in arbSources.entries) {
    final parsed = ArbDocument.parse(arb.value);
    if (parsed is! ArbParseSuccess) {
      throw StateError('Fixture ARB failed to parse: ${arb.key}');
    }
    documents[arb.key] = parsed.document;
  }
  final planResult = L10nArbMutationPlanner.plan(
    templatePath: templatePath,
    documentsByPath: documents,
    selectedKeys: const ['dead'],
  );
  if (planResult is! L10nArbMutationPlanReady) {
    throw StateError('Fixture mutation plan was rejected.');
  }
  final template = documents[templatePath]!;
  final memberKinds = <String, ArbGeneratedMemberKind>{
    for (final member in template.members)
      if (!member.decodedKey.startsWith('@'))
        member.decodedKey: ArbGeneratedMemberKind.getter,
  };
  final analyzerPaths = <String>{
    for (final entry in entries.entries)
      if (entry.key.endsWith('.dart') &&
          entry.value.state is L10nSnapshotPresent)
        entry.key,
  };
  final snapshot = L10nFamilySnapshot(
    entries: entries,
    mutationPlan: planResult.plan,
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {'dead'},
    expectedGeneratedMemberKindsByKey: memberKinds,
    expectedGeneratedPaths: expectedOutputPaths.toSet(),
    optionalUntranslatedPath: optionalSidecarPath,
    verificationClosure: L10nVerificationClosure(
      projectOwnedDartPaths: analyzerPaths,
      analyzerRootIdentity: _hash('analyzer'),
    ),
    analysisOptionsProjection: L10nAnalysisOptionsProjection(
      projectOwnedPaths: const {},
      externalAuthorities: const [],
      contextAuthorityIdentity: _hash('analysis-options'),
    ),
    provenUnrelatedOutputSiblings: provenSiblings,
    familyFingerprint: _hash('family'),
    selectionFingerprint: _hash('selection'),
    l10nAnalysisFingerprint: _hash('l10n-analysis'),
    configurationIdentity: _hash('configuration'),
    packageConfigProjectionIdentity: _hash('package-projection'),
    packageResolutionIdentity: _hash('package-resolution'),
    toolchainIdentity: _identity,
    projectSemantics: L10nProjectSemantics(
      pubspec: const {'name': 'fixture'},
      packageName: 'fixture',
      analysisMode: AnalysisMode.application,
      targetMatrix: TargetMatrix.declared([
        BuildTarget(
          name: 'app',
          platform: 'android',
          entrypoint: 'lib/main.dart',
        ),
      ]),
      rootCoverage: RootCoverage.applicationApi(),
    ),
  );
  final capturePaths = <String>{
    ...expectedOutputPaths,
    if (optionalSidecarPath != null) optionalSidecarPath,
  };
  final baselineBeforeEntries = _entriesFromSnapshot(
    snapshot,
    candidateArbs: false,
    capturePaths: capturePaths,
  );
  final baselineAfterEntries = Map<String, L10nStageEntry>.of(
    baselineBeforeEntries,
  );
  final candidateBeforeEntries = _entriesFromSnapshot(
    snapshot,
    candidateArbs: true,
    capturePaths: capturePaths,
  );
  final candidateAfterEntries = Map<String, L10nStageEntry>.of(
    candidateBeforeEntries,
  );
  _applyFileStates(
    candidateAfterEntries,
    candidateOutputs,
    capturePaths: capturePaths,
  );
  if (optionalSidecarPath != null) {
    _applyFileStates(candidateAfterEntries, {
      optionalSidecarPath: candidateSidecar,
    }, capturePaths: capturePaths);
  }
  return _Scenario(
    snapshot: snapshot,
    allowlist: L10nGenerationAllowlist(
      replacementOutputPaths: expectedOutputPaths.toSet(),
      untranslatedSidecarPath: optionalSidecarPath,
      provenUnrelatedSiblingPaths: provenSiblings,
    ),
    baseline: _run(
      L10nGenerationPhase.baseline,
      baselineBeforeEntries,
      baselineAfterEntries,
      commandSalt: '$commandSalt-baseline',
    ),
    candidate: _run(
      L10nGenerationPhase.candidate,
      candidateBeforeEntries,
      candidateAfterEntries,
      commandSalt: '$commandSalt-candidate',
    ),
  );
}

Map<String, L10nStageEntry> _entriesFromSnapshot(
  L10nFamilySnapshot snapshot, {
  required bool candidateArbs,
  required Set<String> capturePaths,
}) {
  final entries = <String, L10nStageEntry>{};
  for (final snapshotEntry in snapshot.entries.values) {
    final state = snapshotEntry.state;
    if (state is! L10nSnapshotPresent) continue;
    final path = snapshotEntry.relativePosixPath;
    final bytes =
        candidateArbs &&
            snapshot.mutationPlan.candidateArbBytes.containsKey(path)
        ? snapshot.mutationPlan.candidateArbBytes[path]!
        : state.stageBytes;
    _ensureParents(entries, path);
    entries[path] = _file(
      path,
      _FileEvidence(bytes, mode: state.posixMode),
      capture: capturePaths.contains(path),
    );
  }
  return entries;
}

void _applyFileStates(
  Map<String, L10nStageEntry> entries,
  Map<String, _FileEvidence?> states, {
  required Set<String> capturePaths,
}) {
  for (final state in states.entries) {
    if (state.value == null) {
      entries.remove(state.key);
      continue;
    }
    _ensureParents(entries, state.key);
    entries[state.key] = _file(
      state.key,
      state.value!,
      capture: capturePaths.contains(state.key),
    );
  }
}

void _ensureParents(Map<String, L10nStageEntry> entries, String path) {
  final parts = path.split('/');
  for (var length = 1; length < parts.length; length++) {
    final parent = parts.take(length).join('/');
    entries.putIfAbsent(parent, () => _directory(parent));
  }
}

L10nSnapshotEntry _presentSnapshot(
  String path,
  L10nSnapshotRole role,
  List<int> bytes, {
  int? mode = 0x1a4,
}) => _presentSnapshotEvidence(
  path,
  role,
  _FileEvidence(ImmutableBytes.copyOf(bytes), mode: mode),
);

L10nSnapshotEntry _presentSnapshotEvidence(
  String path,
  L10nSnapshotRole role,
  _FileEvidence evidence,
) => L10nSnapshotEntry(
  relativePosixPath: path,
  role: role,
  state: L10nSnapshotPresent(
    sourceBytes: evidence.bytes,
    stageBytes: evidence.bytes,
    sourceSha256: evidence.bytes.sha256Hex,
    posixMode: evidence.mode,
  ),
);

L10nSnapshotEntry _absentSnapshot(String path, L10nSnapshotRole role) =>
    L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: const L10nSnapshotAbsent(),
    );

L10nStageEntry _file(
  String path,
  _FileEvidence evidence, {
  int? mode,
  bool capture = true,
}) => L10nStageEntry(
  relativePath: path,
  kind: L10nStageEntryKind.regularFile,
  sha256: evidence.bytes.sha256Hex,
  posixMode: mode ?? evidence.mode,
  capturedBytes: capture ? evidence.bytes : null,
);

L10nStageEntry _directory(String path, {int? mode = 0x1c0}) => L10nStageEntry(
  relativePath: path,
  kind: L10nStageEntryKind.directory,
  sha256: null,
  posixMode: mode,
  capturedBytes: null,
);

L10nStageEntry _link(String path) => L10nStageEntry(
  relativePath: path,
  kind: L10nStageEntryKind.symbolicLink,
  sha256: null,
  posixMode: null,
  capturedBytes: null,
);

L10nGenerationRun _run(
  L10nGenerationPhase phase,
  Map<String, L10nStageEntry> before,
  Map<String, L10nStageEntry> after, {
  required String commandSalt,
}) => L10nGenerationRun(
  phase: phase,
  before: _capture(before),
  after: _capture(after),
  processResult: _process(),
  failures: const [],
  elapsedMicros: 10,
  commandIdentity: _hash(commandSalt),
);

const _notProvided = Object();

L10nGenerationRun _copyRun(
  L10nGenerationRun source, {
  L10nGenerationPhase? phase,
  L10nStageInventoryCapture? before,
  L10nStageInventoryCapture? after,
  Object? processResult = _notProvided,
  List<L10nEvidenceFailure>? failures,
  String? commandIdentity,
}) => L10nGenerationRun(
  phase: phase ?? source.phase,
  before: before ?? source.before,
  after: after ?? source.after,
  processResult: identical(processResult, _notProvided)
      ? source.processResult
      : processResult as ManagedProcessResult?,
  failures: failures ?? source.failures,
  elapsedMicros: source.elapsedMicros,
  commandIdentity: commandIdentity ?? source.commandIdentity,
);

L10nGenerationRun _replaceAfterEntry(
  L10nGenerationRun run,
  String path,
  L10nStageEntry? replacement,
) {
  final entries = Map<String, L10nStageEntry>.of(run.after.entries);
  if (replacement == null) {
    entries.remove(path);
  } else {
    _ensureParents(entries, path);
    entries[path] = replacement;
  }
  return _copyRun(run, after: _capture(entries));
}

L10nGenerationRun _withStableEntry(
  L10nGenerationRun run,
  String path,
  L10nStageEntry entry,
) {
  final before = Map<String, L10nStageEntry>.of(run.before.entries)
    ..[path] = entry;
  final after = Map<String, L10nStageEntry>.of(run.after.entries)
    ..[path] = entry;
  return _copyRun(run, before: _capture(before), after: _capture(after));
}

L10nGenerationRun _unexpectedMutation(
  L10nGenerationRun run,
  _UnexpectedMutation mutation,
) {
  final path = 'tmp/${mutation.name}.txt';
  final before = Map<String, L10nStageEntry>.of(run.before.entries)
    ..putIfAbsent('tmp', () => _directory('tmp'));
  final after = Map<String, L10nStageEntry>.of(run.after.entries)
    ..putIfAbsent('tmp', () => _directory('tmp'));
  final original = _bytesEvidence('before\n');
  final changed = _bytesEvidence('after\n');
  switch (mutation) {
    case _UnexpectedMutation.create:
      after[path] = _file(path, changed, capture: false);
    case _UnexpectedMutation.modify:
      before[path] = _file(path, original, capture: false);
      after[path] = _file(path, changed, mode: 0x180, capture: false);
    case _UnexpectedMutation.delete:
      before[path] = _file(path, original, capture: false);
      after.remove(path);
    case _UnexpectedMutation.link:
      after[path] = _link(path);
    case _UnexpectedMutation.type:
      before[path] = _file(path, original, capture: false);
      after[path] = _directory(path);
    case _UnexpectedMutation.mode:
      before[path] = _file(path, original, capture: false);
      after[path] = _file(path, original, mode: 0x180, capture: false);
    case _UnexpectedMutation.content:
      before[path] = _file(path, original, capture: false);
      after[path] = _file(path, changed, capture: false);
  }
  final invalidPaths = mutation == _UnexpectedMutation.link
      ? <String>{path}
      : const <String>{};
  return _copyRun(
    run,
    before: _capture(before),
    after: _capture(after, invalidPaths: invalidPaths),
  );
}

L10nStageInventoryCapture _capture(
  Map<String, L10nStageEntry> entries, {
  Set<String> invalidPaths = const {},
}) => L10nStageInventoryCapture(
  entries: entries,
  invalidPaths: invalidPaths,
  fingerprint: _inventoryFingerprint(entries, invalidPaths),
);

String _inventoryFingerprint(
  Map<String, L10nStageEntry> entries,
  Iterable<String> invalidPaths,
) {
  final sorted = SplayTreeMap<String, L10nStageEntry>.of(entries);
  return sha256
      .convert(
        utf8.encode(
          jsonEncode({
            'entries': [
              for (final entry in sorted.values)
                {
                  'path': entry.relativePath,
                  'kind': entry.kind.name,
                  'sha256': entry.sha256,
                  'mode': entry.posixMode,
                },
            ],
            'invalidPaths': invalidPaths.toList()..sort(),
          }),
        ),
      )
      .toString();
}

ManagedProcessResult _process({
  int exitCode = 0,
  bool timedOut = false,
  int stdoutOmittedBytes = 0,
}) => ManagedProcessResult(
  exitCode: exitCode,
  stdout: BoundedProcessOutput(
    capturedPayload: const [],
    omittedBytes: stdoutOmittedBytes,
  ),
  stderr: BoundedProcessOutput(capturedPayload: const [], omittedBytes: 0),
  timedOut: timedOut,
);

L10nReconciliationResult _reconcile(
  _Scenario scenario, {
  L10nGenerationAllowlist? allowlist,
  L10nGenerationRun? baseline,
  L10nGenerationRun? candidate,
}) => DefaultL10nOutputReconciler().reconcile(
  liveSnapshot: scenario.snapshot,
  allowlist: allowlist ?? scenario.allowlist,
  baseline: baseline ?? scenario.baseline,
  candidate: candidate ?? scenario.candidate,
);

L10nReconciliationReady _expectReady(L10nReconciliationResult result) {
  expect(result, isA<L10nReconciliationReady>());
  return result as L10nReconciliationReady;
}

L10nReconciliationRejected _expectRejected(L10nReconciliationResult result) {
  expect(result, isA<L10nReconciliationRejected>());
  return result as L10nReconciliationRejected;
}

void _expectOnlyFailure(
  L10nReconciliationResult result,
  L10nEvidenceRejectionCode code,
  String detailCode, {
  required String stage,
  String? relativePath,
}) {
  final rejected = _expectRejected(result);
  expect(rejected.failures, hasLength(1));
  final failure = rejected.failures.single;
  expect(failure.code, code);
  expect(failure.stage, stage);
  expect(failure.detailCode, detailCode);
  expect(failure.relativePath, relativePath);
}

void _expectFailureCode(
  L10nReconciliationResult result,
  L10nEvidenceRejectionCode code, {
  String? reason,
}) {
  final rejected = _expectRejected(result);
  expect(
    rejected.failures.map((failure) => failure.code),
    contains(code),
    reason: reason,
  );
}

_FileEvidence _fixtureEvidence(String relativePath, {int? mode = 0x1a4}) =>
    _FileEvidence(
      ImmutableBytes.copyOf(_fixtureBytes(relativePath)),
      mode: mode,
    );

List<int> _fixtureBytes(String relativePath) => File(
  '${Directory.current.path}/test/fixtures/l10n_action_readiness/'
  'output_families/$relativePath',
).readAsBytesSync();

_FileEvidence _bytesEvidence(String value, {int? mode = 0x1a4}) =>
    _FileEvidence(ImmutableBytes.copyOf(utf8.encode(value)), mode: mode);

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

bool _isProjectRelativePosix(String path) =>
    path.isNotEmpty &&
    !path.startsWith('/') &&
    !path.contains(r'\') &&
    !path.split('/').any((segment) => segment.isEmpty || segment == '..');
