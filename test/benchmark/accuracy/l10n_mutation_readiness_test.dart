import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/reporting/recoverable_report_writer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../../benchmark/accuracy/l10n_mutation_readiness.dart';

const _fakeSha256 =
    '0000000000000000000000000000000000000000000000000000000000000000';
const _productionManifestSha256 =
    '6c64080eb30fd59ad55db439ddaf17cc8340785828df31a53d0433669032387a';

void main() {
  group('strict argv', () {
    late Directory sandbox;
    late List<String> sdkArguments;

    setUp(() {
      sandbox = _canonicalTempDirectory('l10n-readiness-options-');
      sdkArguments = [
        for (final version in const ['3.41.5', '3.44.1', '3.44.9'])
          '$version=${_flutterBinary(sandbox, version).path}',
      ];
    });

    tearDown(() => sandbox.deleteSync(recursive: true));

    test('accepts the complete explicit contract', () {
      final resume = File(p.join(sandbox.path, 'resume.json'))
        ..writeAsStringSync('{}');
      final options = L10nMutationReadinessOptions.parse([
        '--manifest',
        'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
        '--corpus-root',
        sandbox.path,
        for (final sdk in sdkArguments) ...['--sdk', sdk],
        '--output',
        resume.path,
        '--resume',
        resume.path,
        '--case',
        'smooth:about_this_app',
      ]);

      expect(options.manifestPath, startsWith('benchmark/accuracy/'));
      expect(options.corpusRoot.path, sandbox.path);
      expect(options.sdkFlutterByVersion.keys, ['3.41.5', '3.44.1', '3.44.9']);
      expect(options.resumeFile!.path, resume.path);
      expect(options.caseSelection, 'smooth:about_this_app');
      expect(options.familySelection, isNull);
    });

    test('rejects missing, duplicate, noncanonical, and ambiguous input', () {
      final valid = [
        '--manifest',
        'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
        '--corpus-root',
        sandbox.path,
        for (final sdk in sdkArguments) ...['--sdk', sdk],
        '--output',
        p.join(sandbox.path, 'result.json'),
      ];
      final otherBinary = _flutterBinary(sandbox, 'other');
      final resume = File(p.join(sandbox.path, 'resume.json'))
        ..writeAsStringSync('{}');
      final sharedSdk = sdkArguments.first.split('=').last;
      final invalid = <List<String>>[
        valid.sublist(0, valid.length - 4),
        [...valid, '--sdk', sdkArguments.first],
        [
          ...valid.sublist(0, 8),
          '--sdk',
          '9.9.9=${otherBinary.path}',
          ...valid.sublist(10),
        ],
        _replaceValue(valid, '--manifest', '/absolute/manifest.json'),
        _replaceValue(valid, '--manifest', '../manifest.json'),
        _replaceValue(valid, '--corpus-root', 'relative/corpus'),
        _replaceValue(
          valid,
          '--output',
          p.join(sandbox.path, '..', p.basename(sandbox.path), 'result.json'),
        ),
        [...valid, '--case', 'smooth:key', '--family', 'smooth'],
        [...valid, '--resume', resume.path],
        [
          '--manifest',
          'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
          '--corpus-root',
          sandbox.path,
          for (final version in const ['3.41.5', '3.44.1', '3.44.9']) ...[
            '--sdk',
            '$version=$sharedSdk',
          ],
          '--output',
          p.join(sandbox.path, 'shared-sdk-result.json'),
        ],
        [...valid, '--output', p.join(sandbox.path, 'other.json')],
        [...valid, '--unknown', 'value'],
        [...valid, 'positional'],
      ];

      for (var index = 0; index < invalid.length; index++) {
        expect(
          () => L10nMutationReadinessOptions.parse(invalid[index]),
          throwsFormatException,
          reason: 'invalid argv $index',
        );
      }
    });
  });

  group('production manifest plan', () {
    late Directory sandbox;
    late Directory corpusRoot;
    late Map<String, Directory> repositories;

    setUp(() {
      sandbox = _canonicalTempDirectory('l10n-production-plan-builder-');
      corpusRoot = Directory(p.join(sandbox.path, 'corpus'))
        ..createSync(recursive: true);
      Directory(p.join(corpusRoot.path, 'results')).createSync();
      repositories = {
        'gitjournal': Directory(p.join(corpusRoot.path, 'GitJournal'))
          ..createSync(),
        'gsy': Directory(p.join(corpusRoot.path, 'gsy_github_app_flutter'))
          ..createSync(),
        'smooth': Directory(p.join(corpusRoot.path, 'smooth-app'))
          ..createSync(),
      };
    });

    tearDown(() => sandbox.deleteSync(recursive: true));

    test('loads the complete frozen production scope', () async {
      final options = _productionOptions(
        sandbox: sandbox,
        corpusRoot: corpusRoot,
      );
      final plan = await buildProductionL10nReadinessPlanFromManifest(
        options,
        identities: _productionIdentities(),
        retainedRepositoriesByProject: repositories,
      );

      expect(plan.profile, L10nReadinessProfile.productionStage1);
      expect(plan.oracleVersion, 'l10n-mutation-readiness-v2');
      expect(plan.oracleCases, hasLength(2602));
      expect(plan.individualCaseIds, hasLength(367));
      expect(plan.familyProjectIds, ['gitjournal', 'gsy', 'smooth']);
      expect(plan.mutationNegativeFixtures, hasLength(14));
      expect(
        plan.expectedDenominators.toJson(),
        L10nReadinessDenominators.productionFull.toJson(),
      );
      expect(
        plan.individualCaseIds,
        orderedEquals([...plan.individualCaseIds]..sort()),
      );
      expect(plan.artifactRoot.path, p.join(corpusRoot.path, 'results'));
    });

    test('case and family scopes retain the complete project oracle', () async {
      const rows = <(String, String, int, int)>[
        ('gitjournal', 'drawerFs', 38, 381),
        ('gsy', 'app_back_tip', 17, 386),
        ('smooth', 'about_this_app', 312, 1468),
      ];
      for (final (projectId, key, positives, negatives) in rows) {
        for (final family in [false, true]) {
          final options = _productionOptions(
            sandbox: sandbox,
            corpusRoot: corpusRoot,
            caseSelection: family ? null : '$projectId:$key',
            familySelection: family ? projectId : null,
            outputName: '$projectId-${family ? 'family' : 'case'}.json',
          );
          final plan = await buildProductionL10nReadinessPlanFromManifest(
            options,
            identities: _productionIdentities(),
            retainedRepositoriesByProject: repositories,
          );

          expect(plan.oracleCases, hasLength(positives + negatives));
          expect(plan.oracleCases.map((entry) => entry.projectId).toSet(), {
            projectId,
          });
          expect(plan.expectedDenominators.staticPositiveCandidates, positives);
          expect(
            plan.expectedDenominators.staticNegativeNonCandidates,
            negatives,
          );
          expect(plan.expectedDenominators.individualKeys, family ? 0 : 1);
          expect(plan.expectedDenominators.familyBatches, family ? 1 : 0);
          expect(plan.expectedDenominators.mutationNegativeFixtures, 0);
          expect(plan.expectedDenominators.requiredRestorations, 1);
        }
      }
    });

    test(
      'rejects negative or unknown smoke cases and aliased repositories',
      () {
        Future<L10nReadinessPlan> load({
          required String selection,
          Map<String, Directory>? roots,
        }) => buildProductionL10nReadinessPlanFromManifest(
          _productionOptions(
            sandbox: sandbox,
            corpusRoot: corpusRoot,
            caseSelection: selection,
            outputName: '${selection.hashCode}.json',
          ),
          identities: _productionIdentities(),
          retainedRepositoriesByProject: roots ?? repositories,
        );

        expect(
          load(selection: 'gitjournal:actionsNewChecklist'),
          throwsFormatException,
        );
        expect(
          load(selection: 'smooth:not_a_manifest_key'),
          throwsFormatException,
        );
        expect(
          load(
            selection: 'smooth:about_this_app',
            roots: {...repositories, 'smooth': repositories['gsy']!},
          ),
          throwsFormatException,
        );
        expect(
          buildProductionL10nReadinessPlanFromManifest(
            _productionOptions(
              sandbox: sandbox,
              corpusRoot: corpusRoot,
              caseSelection: 'smooth:about_this_app',
              outputName: 'manifest-identity-drift.json',
            ),
            identities: {
              ..._productionIdentities(),
              'manifestSha256': _fakeSha256,
            },
            retainedRepositoriesByProject: repositories,
          ),
          throwsFormatException,
        );
        expect(
          buildProductionL10nReadinessPlanFromManifest(
            _productionOptions(
              sandbox: sandbox,
              corpusRoot: corpusRoot,
              caseSelection: 'smooth:about_this_app',
              outputName: '.l10n-readiness-forbidden-smoke.json',
              outputParentOverride: Directory.current,
            ),
            identities: _productionIdentities(),
            retainedRepositoriesByProject: repositories,
          ),
          throwsFormatException,
        );
      },
    );
  });

  test(
    'full orchestration is fail-closed and follows the mutation order',
    () async {
      final fixture = _Fixture();
      final exitCode = await runL10nMutationReadiness(
        fixture.argv(),
        dependencies: fixture.dependencies(),
      );

      expect(exitCode, 0);
      expect(fixture.calls, [
        'plan:full',
        'checkpoint',
        'provision:alpha',
        'scan:alpha',
        'static-gate:alpha',
        'evaluator:new',
        'verdict:alpha:l10n:unused_even_when_old_oracle_was_false',
        'corpus:alpha:l10n:unused_even_when_old_oracle_was_false',
        'restoration:alpha:l10n:unused_even_when_old_oracle_was_false',
        'dispose:alpha',
        'checkpoint',
        'provision:alpha',
        'scan:alpha',
        'static-gate:alpha',
        'evaluator:new',
        'verdict:family:alpha',
        'corpus:family:alpha',
        'restoration:family:alpha',
        'dispose:alpha',
        'checkpoint',
        'negative:raw-gsy',
        'checkpoint',
        'checkpoint',
      ]);
      final artifact =
          jsonDecode(fixture.store.writes.last) as Map<String, Object?>;
      expect(artifact.keys.toSet(), {
        'schemaVersion',
        'artifactKind',
        'oracleVersion',
        'status',
        'scope',
        'identities',
        'projects',
        'cases',
        'familyBatches',
        'mutationNegativeFixtures',
        'performance',
        'summary',
      });
      expect(artifact['status'], 'passed');
      expect((artifact['scope']! as Map)['completeRun'], isFalse);
      final summary = artifact['summary']! as Map<String, Object?>;
      expect(summary, containsPair('acceptedIndividualKeys', 1));
      expect(summary, containsPair('acceptedFamilyBatches', 1));
      expect(summary, containsPair('staticPositiveCandidates', 1));
      expect(summary, containsPair('staticNegativeNonCandidates', 1));
      expect(summary, containsPair('mutationNegativeFixturesPassed', 1));
      expect(summary, containsPair('provenRestorations', 2));
      expect(summary, containsPair('requiredRestorations', 2));
      expect(summary, containsPair('publicSafeL10n', 0));
      expect(summary, containsPair('publicHighL10n', 0));
      expect(summary, containsPair('publicApplyEligibleL10n', 0));
      expect(summary, containsPair('publicProposedL10nActions', 0));
      expect(fixture.store.writes.last, endsWith('\n'));
      expect(fixture.store.writes.last, isNot(contains(fixture.sandbox.path)));
      expect(
        fixture.store.writes.last,
        isNot(contains(fixture.mutationAuthority)),
      );
    },
  );

  test(
    'project eligibility rejection skips repeated individual evaluation',
    () async {
      final fixture = _Fixture(enableProjectEligibilityPreflight: true)
        ..evidenceAccepted = false;

      expect(
        await runL10nMutationReadiness(
          fixture.argv(),
          dependencies: fixture.dependencies(),
        ),
        1,
      );
      expect(fixture.calls.where((call) => call == 'scan:alpha'), hasLength(1));
      expect(
        fixture.calls,
        isNot(
          contains('verdict:alpha:l10n:unused_even_when_old_oracle_was_false'),
        ),
      );
      final artifact = jsonDecode(fixture.store.writes.last) as Map;
      final record = (artifact['cases'] as List).single as Map;
      expect(record['failureReason'], 'projectEligibilityRejected');
      expect(artifact['status'], 'failed');
    },
  );

  test(
    'a positive remains required when expectedScannerPresence was false',
    () async {
      final fixture = _Fixture()..scanner.omitFalseLegacyPositive = true;
      final exitCode = await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: fixture.dependencies(),
      );

      expect(exitCode, 1);
      expect(fixture.calls, isNot(contains(startsWith('evaluator:'))));
      expect(fixture.calls, isNot(contains(startsWith('verdict:'))));
      expect(fixture.calls, contains('dispose:alpha'));
      final artifact =
          jsonDecode(fixture.store.writes.last) as Map<String, Object?>;
      expect(artifact['status'], 'failed');
    },
  );

  test('negative candidates and public actionability block mutation', () async {
    for (final mutate in <void Function(_FakeScanner)>[
      (scanner) => scanner.negativeIsCandidate = true,
      (scanner) => scanner.publicSafe = 1,
      (scanner) => scanner.publicHigh = 1,
      (scanner) => scanner.publicApplyEligible = 1,
      (scanner) => scanner.publicProposed = 1,
    ]) {
      final fixture = _Fixture();
      mutate(fixture.scanner);

      expect(
        await runL10nMutationReadiness(
          fixture.argv(),
          dependencies: fixture.dependencies(),
        ),
        1,
      );
      expect(fixture.calls, isNot(contains(startsWith('verdict:'))));
      fixture.close();
    }
  });

  test(
    'static closure rejects missing, duplicate, and unknown identities',
    () async {
      for (final mutate in <void Function(_FakeScanner)>[
        (scanner) => scanner.omitNegativeActualNode = true,
        (scanner) => scanner.duplicateActualNodeIds = true,
        (scanner) => scanner.addUnknownActualNode = true,
        (scanner) => scanner.addUnknownCandidate = true,
      ]) {
        final fixture = _Fixture();
        mutate(fixture.scanner);

        expect(
          await runL10nMutationReadiness(
            fixture.argv(
              caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
            ),
            dependencies: fixture.dependencies(),
          ),
          1,
        );
        expect(fixture.calls, isNot(contains(startsWith('verdict:'))));
        expect(fixture.calls, isNot(contains(startsWith('corpus:'))));
        expect(fixture.calls, contains('dispose:alpha'));
        expect(
          fixture.calls.lastIndexOf('dispose:alpha'),
          lessThan(fixture.calls.lastIndexOf('checkpoint')),
        );
        fixture.close();
      }
    },
  );

  test(
    'scan evidence cannot drift between individual and family work',
    () async {
      final fixture = _Fixture()..scanner.driftAuthorityAfterFirstScan = true;

      expect(
        await runL10nMutationReadiness(
          fixture.argv(),
          dependencies: fixture.dependencies(),
        ),
        2,
      );
      expect(fixture.calls.where((call) => call == 'scan:alpha'), hasLength(2));
      expect(
        fixture.calls.where((call) => call == 'dispose:alpha'),
        hasLength(2),
      );
      expect(fixture.store.writes, hasLength(2));
      final checkpoint =
          jsonDecode(fixture.store.writes.last) as Map<String, Object?>;
      expect(checkpoint['status'], 'inProgress');
      expect(checkpoint['cases'], hasLength(1));
      expect(checkpoint['familyBatches'], isEmpty);
      expect(checkpoint['mutationNegativeFixtures'], isEmpty);
      expect(
        ((checkpoint['projects']! as List<Object?>).single!
            as Map<String, Object?>)['scanAuthorityIdentity'],
        'scan-authority-v1',
      );
    },
  );

  test('scoped denominators are exact for case and family runs', () async {
    final caseFixture = _Fixture();
    expect(
      await runL10nMutationReadiness(
        caseFixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: caseFixture.dependencies(),
      ),
      0,
    );
    var artifact = jsonDecode(caseFixture.store.writes.last) as Map;
    var summary = artifact['summary'] as Map;
    expect(summary['requiredIndividualKeys'], 1);
    expect(summary['requiredFamilyBatches'], 0);
    expect(summary['requiredMutationNegativeFixtures'], 0);
    expect(summary['requiredRestorations'], 1);

    final familyFixture = _Fixture();
    expect(
      await runL10nMutationReadiness(
        familyFixture.argv(familySelection: 'alpha'),
        dependencies: familyFixture.dependencies(),
      ),
      0,
    );
    artifact = jsonDecode(familyFixture.store.writes.last) as Map;
    summary = artifact['summary'] as Map;
    expect(summary['requiredIndividualKeys'], 0);
    expect(summary['requiredFamilyBatches'], 1);
    expect(summary['requiredMutationNegativeFixtures'], 0);
    expect(summary['requiredRestorations'], 1);
  });

  test('failed evidence keeps the denominator and exits nonzero', () async {
    final fixture = _Fixture()..evidenceAccepted = false;

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: fixture.dependencies(),
      ),
      1,
    );
    final artifact = jsonDecode(fixture.store.writes.last) as Map;
    final summary = artifact['summary'] as Map;
    final record = (artifact['cases'] as List).single as Map;
    final evidence = record['evidence'] as Map;
    expect(summary['acceptedIndividualKeys'], 0);
    expect(summary['requiredIndividualKeys'], 1);
    expect(summary['provenRestorations'], 0);
    expect(summary['fullPolicyFailures'], 0);
    expect(record['failureReason'], 'internalVerdictRejected');
    expect(evidence['corpusPolicyIdentity'], 'notRun');
    expect(evidence['restorationIdentity'], 'notRun');
    expect(evidence['verdictFailures'], [
      {
        'code': 'scanBlockerPresent',
        'detailCode': 'selected-node-retained',
        'stage': 'family-preflight',
      },
    ]);
    expect(fixture.calls, [
      'plan:case',
      'checkpoint',
      'provision:alpha',
      'scan:alpha',
      'static-gate:alpha',
      'evaluator:new',
      'verdict:alpha:l10n:unused_even_when_old_oracle_was_false',
      'dispose:alpha',
      'checkpoint',
      'checkpoint',
    ]);
  });

  test('corpus and restoration failures remain terminal evidence', () async {
    for (final expectation
        in <
          ({
            bool policy,
            bool restoration,
            int policyFailures,
            int restorations,
          })
        >[
          (
            policy: false,
            restoration: true,
            policyFailures: 1,
            restorations: 1,
          ),
          (
            policy: true,
            restoration: false,
            policyFailures: 0,
            restorations: 0,
          ),
          (
            policy: false,
            restoration: false,
            policyFailures: 1,
            restorations: 0,
          ),
        ]) {
      final fixture = _Fixture()
        ..corpusPolicyPassed = expectation.policy
        ..restorationProven = expectation.restoration;

      expect(
        await runL10nMutationReadiness(
          fixture.argv(
            caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
          ),
          dependencies: fixture.dependencies(),
        ),
        1,
      );
      expect(fixture.calls, contains(startsWith('corpus:')));
      expect(fixture.calls, contains(startsWith('restoration:')));
      expect(fixture.calls, contains('dispose:alpha'));
      final artifact = jsonDecode(fixture.store.writes.last) as Map;
      final summary = artifact['summary'] as Map;
      final record = (artifact['cases'] as List).single as Map;
      expect(summary['requiredIndividualKeys'], 1);
      expect(summary['acceptedIndividualKeys'], 0);
      expect(summary['fullPolicyFailures'], expectation.policyFailures);
      expect(summary['provenRestorations'], expectation.restorations);
      expect(record['failureReason'], 'corpusEvidenceRejected');
      expect(fixture.store.writes, hasLength(3));
    }
  });

  test(
    'accepted corpus blockers reject individual and family evidence',
    () async {
      for (final expectation in <({String kind, int writes, bool drift})>[
        (kind: 'case', writes: 1, drift: false),
        (kind: 'case', writes: 0, drift: true),
        (kind: 'family', writes: 1, drift: false),
        (kind: 'family', writes: 0, drift: true),
      ]) {
        final fixture = _Fixture()
          ..unexpectedWriteCount = expectation.writes
          ..originalProjectDrift = expectation.drift;
        final family = expectation.kind == 'family';

        expect(
          await runL10nMutationReadiness(
            fixture.argv(
              caseSelection: family
                  ? null
                  : 'alpha:unused_even_when_old_oracle_was_false',
              familySelection: family ? 'alpha' : null,
            ),
            dependencies: fixture.dependencies(),
          ),
          1,
        );
        final artifact = jsonDecode(fixture.store.writes.last) as Map;
        final summary = artifact['summary'] as Map;
        final records = artifact[family ? 'familyBatches' : 'cases'] as List;
        expect(
          (records.single as Map)['failureReason'],
          'corpusEvidenceRejected',
        );
        expect(summary['unexpectedWritesForAccepted'], expectation.writes);
        expect(summary['originalProjectDriftCount'], expectation.drift ? 1 : 0);
        expect(
          summary[family ? 'acceptedFamilyBatches' : 'acceptedIndividualKeys'],
          0,
        );
        expect(fixture.calls, contains('dispose:alpha'));
      }
    },
  );

  test('malformed fresh internal evidence aborts before checkpoint', () async {
    final fixture = _Fixture()..malformedInternalEvidence = true;

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, contains('dispose:alpha'));
    expect(fixture.calls, isNot(contains(startsWith('corpus:'))));
    expect(fixture.store.writes, hasLength(1));
  });

  test(
    'unexpected attempt failures dispose without terminal attempt evidence',
    () async {
      for (final configure in <void Function(_Fixture)>[
        (fixture) => fixture.evaluatorThrows = true,
        (fixture) => fixture.corpusThrows = true,
        (fixture) => fixture.disposeThrows = true,
        (fixture) => fixture.wrongInternalSelection = true,
      ]) {
        final fixture = _Fixture();
        configure(fixture);

        expect(
          await runL10nMutationReadiness(
            fixture.argv(
              caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
            ),
            dependencies: fixture.dependencies(),
          ),
          2,
        );
        expect(fixture.calls, contains('dispose:alpha'));
        expect(fixture.store.writes, hasLength(1));
        if (fixture.evaluatorThrows || fixture.wrongInternalSelection) {
          expect(fixture.calls, isNot(contains(startsWith('corpus:'))));
        }
      }
    },
  );

  test(
    'family rejection and infrastructure failures stay fail-closed',
    () async {
      final rejected = _Fixture()..evidenceAccepted = false;
      expect(
        await runL10nMutationReadiness(
          rejected.argv(familySelection: 'alpha'),
          dependencies: rejected.dependencies(),
        ),
        1,
      );
      expect(rejected.calls, isNot(contains(startsWith('corpus:'))));
      expect(rejected.calls, contains('dispose:alpha'));
      final rejectedArtifact = jsonDecode(rejected.store.writes.last) as Map;
      expect(
        ((rejectedArtifact['familyBatches'] as List).single
            as Map)['failureReason'],
        'internalVerdictRejected',
      );

      for (final configure in <void Function(_Fixture)>[
        (fixture) => fixture.evaluatorThrows = true,
        (fixture) => fixture.corpusThrows = true,
        (fixture) => fixture.disposeThrows = true,
        (fixture) => fixture.wrongInternalSelection = true,
      ]) {
        final fixture = _Fixture();
        configure(fixture);
        expect(
          await runL10nMutationReadiness(
            fixture.argv(familySelection: 'alpha'),
            dependencies: fixture.dependencies(),
          ),
          2,
        );
        expect(fixture.calls, contains('dispose:alpha'));
        expect(fixture.store.writes, hasLength(1));
        if (fixture.evaluatorThrows || fixture.wrongInternalSelection) {
          expect(fixture.calls, isNot(contains(startsWith('corpus:'))));
        }
      }
    },
  );

  test(
    'fresh corpus results stay bound to case and family selections',
    () async {
      for (final family in const [false, true]) {
        final fixture = _Fixture()..wrongCorpusSelection = true;

        expect(
          await runL10nMutationReadiness(
            fixture.argv(
              caseSelection: family
                  ? null
                  : 'alpha:unused_even_when_old_oracle_was_false',
              familySelection: family ? 'alpha' : null,
            ),
            dependencies: fixture.dependencies(),
          ),
          2,
        );
        expect(fixture.calls, contains(startsWith('corpus:')));
        expect(fixture.calls, contains('dispose:alpha'));
        expect(fixture.store.writes, hasLength(1));
        final checkpoint =
            jsonDecode(fixture.store.writes.single) as Map<String, Object?>;
        expect(checkpoint['status'], 'inProgress');
        expect(checkpoint[family ? 'familyBatches' : 'cases'], isEmpty);
        fixture.close();
      }
    },
  );

  test('checkpoint failure occurs only after disposal and exits two', () async {
    final fixture = _Fixture()..checkpointFailureWrite = 2;

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    final checkpointIndexes = <int>[
      for (var index = 0; index < fixture.calls.length; index++)
        if (fixture.calls[index] == 'checkpoint') index,
    ];
    expect(
      fixture.calls.indexOf('dispose:alpha'),
      allOf(
        greaterThan(checkpointIndexes.first),
        lessThan(checkpointIndexes.last),
      ),
    );
    expect(fixture.calls.where((call) => call == 'checkpoint'), hasLength(2));
    expect(fixture.store.writes, hasLength(1));
  });

  test(
    'checkpoint claim, read, preflight, and release failures are closed',
    () async {
      const selection = 'alpha:unused_even_when_old_oracle_was_false';

      final claim = _Fixture()..checkpointClaimThrows = true;
      expect(
        await runL10nMutationReadiness(
          claim.argv(caseSelection: selection),
          dependencies: claim.dependencies(),
        ),
        2,
      );
      expect(claim.calls, ['plan:case']);
      expect(claim.store.claimAttempts, 1);
      expect(claim.store.releaseAttempts, 0);

      final preflight = _Fixture()..checkpointFailureWrite = 1;
      expect(
        await runL10nMutationReadiness(
          preflight.argv(caseSelection: selection),
          dependencies: preflight.dependencies(),
        ),
        2,
      );
      expect(preflight.calls, ['plan:case', 'checkpoint']);
      expect(preflight.store.releaseAttempts, 1);

      final resumeFile = File(
        p.join(preflight.sandbox.path, 'read-failure.json'),
      )..writeAsStringSync('{}');
      final read = _Fixture(existingSandbox: preflight.sandbox)
        ..checkpointReadThrows = true;
      expect(
        await runL10nMutationReadiness(
          read.argv(caseSelection: selection, resume: resumeFile),
          dependencies: read.dependencies(),
        ),
        2,
      );
      expect(read.calls, ['plan:case', 'resume:read']);
      expect(read.store.releaseAttempts, 1);

      final release = _Fixture()..checkpointReleaseThrows = true;
      expect(
        await runL10nMutationReadiness(
          release.argv(caseSelection: selection),
          dependencies: release.dependencies(),
        ),
        2,
      );
      expect(release.store.writes, hasLength(3));
      expect(release.store.releaseAttempts, 1);
    },
  );

  test(
    'negative dependency exceptions never become terminal evidence',
    () async {
      final fixture = _Fixture()..negativeMode = _NegativeMode.throwUnexpected;

      expect(
        await runL10nMutationReadiness(
          fixture.argv(),
          dependencies: fixture.dependencies(),
        ),
        2,
      );
      expect(fixture.calls.last, 'negative:raw-gsy');
      expect(fixture.store.writes, hasLength(3));
    },
  );

  test('returned negative rejections remain failed and resumable', () async {
    for (final mode in const [
      _NegativeMode.notRejected,
      _NegativeMode.disallowedReason,
    ]) {
      final first = _Fixture()..negativeMode = mode;
      expect(
        await runL10nMutationReadiness(
          first.argv(),
          dependencies: first.dependencies(),
        ),
        1,
      );
      final terminal = first.store.writes.last;
      final negative =
          ((jsonDecode(terminal) as Map)['mutationNegativeFixtures'] as List)
                  .single
              as Map;
      expect(negative['status'], 'failed');
      final resume = File(p.join(first.sandbox.path, 'negative-resume.json'))
        ..writeAsStringSync(terminal);
      final second = _Fixture(existingSandbox: first.sandbox)
        ..store.resumeValue = jsonDecode(terminal);

      expect(
        await runL10nMutationReadiness(
          second.argv(resume: resume),
          dependencies: second.dependencies(),
        ),
        1,
      );
      expect(second.calls, ['plan:full', 'resume:read']);
    }
  });

  test('resume skips only complete passed terminal records', () async {
    final first = _Fixture();
    expect(
      await runL10nMutationReadiness(
        first.argv(),
        dependencies: first.dependencies(),
      ),
      0,
    );
    final resume = File(p.join(first.sandbox.path, 'resume.json'))
      ..writeAsStringSync(first.store.writes.last);
    final second = _Fixture(existingSandbox: first.sandbox);
    second.store.resumeValue = jsonDecode(first.store.writes.last);

    expect(
      await runL10nMutationReadiness(
        second.argv(resume: resume),
        dependencies: second.dependencies(),
      ),
      0,
    );
    expect(second.calls, ['plan:full', 'resume:read']);
    first.close();
  });

  test(
    'valid partial resume keeps passed work and runs only pending records',
    () async {
      final first = _Fixture();
      expect(
        await runL10nMutationReadiness(
          first.argv(),
          dependencies: first.dependencies(),
        ),
        0,
      );
      final partial = first.store.writes[1];
      final resume = File(p.join(first.sandbox.path, 'partial.json'))
        ..writeAsStringSync(partial);
      final second = _Fixture(existingSandbox: first.sandbox)
        ..store.resumeValue = jsonDecode(partial);

      expect(
        await runL10nMutationReadiness(
          second.argv(resume: resume),
          dependencies: second.dependencies(),
        ),
        0,
      );
      expect(second.calls, isNot(contains(startsWith('verdict:alpha:l10n:'))));
      expect(second.calls, contains('verdict:family:alpha'));
      expect(second.calls, contains('negative:raw-gsy'));
    },
  );

  test(
    'complete in-progress resume writes only the terminal projection',
    () async {
      final first = _Fixture();
      expect(
        await runL10nMutationReadiness(
          first.argv(),
          dependencies: first.dependencies(),
        ),
        0,
      );
      final completeInProgress =
          first.store.writes[first.store.writes.length - 2];
      expect((jsonDecode(completeInProgress) as Map)['status'], 'inProgress');
      final resume = File(
        p.join(first.sandbox.path, 'complete-in-progress.json'),
      )..writeAsStringSync(completeInProgress);
      final second = _Fixture(existingSandbox: first.sandbox)
        ..store.resumeValue = jsonDecode(completeInProgress);

      expect(
        await runL10nMutationReadiness(
          second.argv(resume: resume),
          dependencies: second.dependencies(),
        ),
        0,
      );
      expect(second.calls, ['plan:full', 'resume:read', 'checkpoint']);
      expect(
        (jsonDecode(second.store.writes.single) as Map)['status'],
        'passed',
      );
    },
  );

  test('terminal failed records are immutable on resume', () async {
    final first = _Fixture()..evidenceAccepted = false;
    final caseArg = 'alpha:unused_even_when_old_oracle_was_false';
    expect(
      await runL10nMutationReadiness(
        first.argv(caseSelection: caseArg),
        dependencies: first.dependencies(),
      ),
      1,
    );
    final resume = File(p.join(first.sandbox.path, 'failed.json'))
      ..writeAsStringSync(first.store.writes.last);
    final second = _Fixture(existingSandbox: first.sandbox)
      ..store.resumeValue = jsonDecode(first.store.writes.last);

    expect(
      await runL10nMutationReadiness(
        second.argv(caseSelection: caseArg, resume: resume),
        dependencies: second.dependencies(),
      ),
      1,
    );
    expect(second.calls, ['plan:case', 'resume:read']);
  });

  test(
    'stale, unknown, duplicate, and partial resume fail before mutation or write',
    () async {
      final seed = _Fixture();
      expect(
        await runL10nMutationReadiness(
          seed.argv(),
          dependencies: seed.dependencies(),
        ),
        0,
      );
      final original =
          jsonDecode(seed.store.writes.last) as Map<String, Object?>;
      final mutations = <void Function(Map<String, Object?>)>[
        (json) =>
            (json['identities']! as Map<String, Object?>)['manifestSha256'] =
                'stale',
        (json) => (json['cases']! as List<Object?>).add({
          ...(json['cases']! as List<Object?>).first! as Map<String, Object?>,
          'caseId': 'alpha:l10n:unknown',
        }),
        (json) => (json['cases']! as List<Object?>).add(
          jsonDecode(jsonEncode((json['cases']! as List<Object?>).first)),
        ),
        (json) =>
            ((json['cases']! as List<Object?>).first!
                    as Map<String, Object?>)['status'] =
                'running',
        (json) =>
            (json['summary']!
                    as Map<String, Object?>)['acceptedIndividualKeys'] =
                999,
        (json) => json['unknown'] = true,
        (json) =>
            ((json['cases']! as List<Object?>).first!
                    as Map<String, Object?>)['unknown'] =
                true,
        (json) {
          final negative =
              (json['mutationNegativeFixtures']! as List<Object?>).single!
                  as Map<String, Object?>;
          negative['observedReason'] = null;
          negative['evidenceIdentity'] = null;
        },
        (json) {
          final record =
              (json['cases']! as List<Object?>).single! as Map<String, Object?>;
          final evidence = record['evidence']! as Map<String, Object?>;
          evidence['selectionIdentity'] = 'alpha:l10n:wrong-selection';
        },
      ];

      for (var index = 0; index < mutations.length; index++) {
        final fixture = _Fixture(existingSandbox: seed.sandbox);
        final resumeJson =
            jsonDecode(jsonEncode(original))! as Map<String, Object?>;
        mutations[index](resumeJson);
        fixture.store.resumeValue = resumeJson;
        final resume = File(p.join(seed.sandbox.path, 'resume-$index.json'))
          ..writeAsStringSync('{}');

        expect(
          await runL10nMutationReadiness(
            fixture.argv(resume: resume),
            dependencies: fixture.dependencies(),
          ),
          2,
          reason: 'resume mutation $index',
        );
        expect(fixture.calls, ['plan:full', 'resume:read']);
      }
      seed.close();
    },
  );

  test('resume rejects unsorted terminal record arrays', () async {
    final seed = _Fixture(extraNegativeFixture: true);
    expect(
      await runL10nMutationReadiness(
        seed.argv(),
        dependencies: seed.dependencies(),
      ),
      0,
    );
    final resumeJson =
        jsonDecode(seed.store.writes.last)! as Map<String, Object?>;
    final records = resumeJson['mutationNegativeFixtures']! as List<Object?>;
    final first = records.first;
    records[0] = records[1];
    records[1] = first;
    final resume = File(p.join(seed.sandbox.path, 'unsorted.json'))
      ..writeAsStringSync('{}');
    final fixture = _Fixture(
      existingSandbox: seed.sandbox,
      extraNegativeFixture: true,
    )..store.resumeValue = resumeJson;

    expect(
      await runL10nMutationReadiness(
        fixture.argv(resume: resume),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, ['plan:full', 'resume:read']);
  });

  test(
    'resume rejects failed project scan or missing passed node binding',
    () async {
      final seed = _Fixture();
      expect(
        await runL10nMutationReadiness(
          seed.argv(),
          dependencies: seed.dependencies(),
        ),
        0,
      );
      final original =
          jsonDecode(seed.store.writes.last) as Map<String, Object?>;
      final mutations = <void Function(Map<String, Object?>)>[
        (json) {
          final project =
              (json['projects']! as List<Object?>).single!
                  as Map<String, Object?>;
          project['status'] = 'failed';
          project['scanAuthorityIdentity'] = null;
        },
        (json) {
          final record =
              (json['cases']! as List<Object?>).single! as Map<String, Object?>;
          record['actualNodeId'] = null;
        },
      ];

      for (var index = 0; index < mutations.length; index++) {
        final resumeJson =
            jsonDecode(jsonEncode(original))! as Map<String, Object?>;
        mutations[index](resumeJson);
        final resume = File(p.join(seed.sandbox.path, 'forged-$index.json'))
          ..writeAsStringSync('{}');
        final fixture = _Fixture(existingSandbox: seed.sandbox)
          ..store.resumeValue = resumeJson;

        expect(
          await runL10nMutationReadiness(
            fixture.argv(resume: resume),
            dependencies: fixture.dependencies(),
          ),
          2,
        );
        expect(fixture.calls, ['plan:full', 'resume:read']);
      }
    },
  );

  test('resume rejects unredacted identity on a valid failed scan', () async {
    final seed = _Fixture()..scanner.negativeIsCandidate = true;
    expect(
      await runL10nMutationReadiness(
        seed.argv(),
        dependencies: seed.dependencies(),
      ),
      1,
    );
    final forged = jsonDecode(seed.store.writes.last) as Map<String, Object?>;
    final project =
        (forged['projects']! as List<Object?>).single! as Map<String, Object?>;
    expect(project['status'], 'failed');
    project['scanAuthorityIdentity'] = '/private/tmp/leaked-authority';
    final resume = File(p.join(seed.sandbox.path, 'failed-scan-forged.json'))
      ..writeAsStringSync('{}');
    final fixture = _Fixture(existingSandbox: seed.sandbox)
      ..store.resumeValue = forged;

    expect(
      await runL10nMutationReadiness(
        fixture.argv(resume: resume),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, ['plan:full', 'resume:read']);
  });

  test('output cannot alias an SDK authority', () async {
    final fixture = _Fixture();
    final sdkFile = File(fixture.sdkArguments.first.split('=').last);

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
          output: sdkFile,
        ),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, isEmpty);
  });

  test(
    'production smoke scope is explicit and never baseline-complete',
    () async {
      final fixture = _Fixture(productionProfile: true);
      final artifactRoot = _canonicalTempDirectory('l10n-production-smoke-');
      addTearDown(() => artifactRoot.deleteSync(recursive: true));

      expect(
        await runL10nMutationReadiness(
          fixture.argv(
            caseSelection: 'smooth:unused_even_when_old_oracle_was_false',
            output: File(p.join(artifactRoot.path, 'smoke.json')),
          ),
          dependencies: fixture.dependencies(),
        ),
        0,
      );
      final artifact = jsonDecode(fixture.store.writes.last) as Map;
      expect(artifact['scope'], {
        'completeRun': false,
        'kind': 'case',
        'profile': 'productionStage1',
        'selection': 'smooth:unused_even_when_old_oracle_was_false',
      });
    },
  );

  test(
    'production plan rejects invalid hashes and repeated protected roots',
    () async {
      for (final fault in const [
        _ProductionPlanFault.invalidHash,
        _ProductionPlanFault.repeatedProtectedRoot,
      ]) {
        final fixture = _Fixture(
          productionProfile: true,
          productionPlanFault: fault,
        );
        final artifactRoot = _canonicalTempDirectory('l10n-production-plan-');
        addTearDown(() => artifactRoot.deleteSync(recursive: true));

        expect(
          await runL10nMutationReadiness(
            fixture.argv(
              caseSelection: 'smooth:unused_even_when_old_oracle_was_false',
              output: File(p.join(artifactRoot.path, 'smoke.json')),
            ),
            dependencies: fixture.dependencies(),
          ),
          2,
        );
        expect(fixture.calls, ['plan:case']);
        expect(fixture.store.writes, isEmpty);
        fixture.close();
      }
    },
  );

  test('production output cannot be placed inside a protected root', () async {
    final fixture = _Fixture(productionProfile: true);
    final output = File(
      p.join(fixture.protectedRoots.first.path, 'smoke.json'),
    );

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'smooth:unused_even_when_old_oracle_was_false',
          output: output,
        ),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, ['plan:case']);
    expect(fixture.store.claimAttempts, 0);
    expect(fixture.store.writes, isEmpty);
  });

  test('full production scope cannot shrink its frozen denominators', () async {
    final fixture = _Fixture(productionProfile: true);

    expect(
      await runL10nMutationReadiness(
        fixture.argv(),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, ['plan:full']);
    expect(fixture.store.writes, isEmpty);
  });

  test('selected argv scope must match the loaded work plan', () async {
    final fixture = _Fixture(scopeMismatch: true);

    expect(
      await runL10nMutationReadiness(
        fixture.argv(
          caseSelection: 'alpha:unused_even_when_old_oracle_was_false',
        ),
        dependencies: fixture.dependencies(),
      ),
      2,
    );
    expect(fixture.calls, ['plan:case']);
    expect(fixture.store.writes, isEmpty);
  });

  test(
    'canonical JSON is recursive, deterministic, and newline terminated',
    () {
      final first = canonicalL10nReadinessJson({
        'z': 1,
        'a': {
          'z': true,
          'a': [
            {'z': 2, 'a': 1},
          ],
        },
      });
      final second = canonicalL10nReadinessJson({
        'a': {
          'a': [
            {'a': 1, 'z': 2},
          ],
          'z': true,
        },
        'z': 1,
      });

      expect(first, second);
      expect(first, startsWith('{\n  "a"'));
      expect(first, endsWith('\n'));
    },
  );

  test('complete fake artifacts ignore plan and map insertion order', () async {
    final first = _Fixture(extraNegativeFixture: true);
    final second = _Fixture(extraNegativeFixture: true, reversePlanOrder: true);

    expect(
      await runL10nMutationReadiness(
        first.argv(),
        dependencies: first.dependencies(),
      ),
      0,
    );
    expect(
      await runL10nMutationReadiness(
        second.argv(),
        dependencies: second.dependencies(),
      ),
      0,
    );
    expect(second.store.writes.last, first.store.writes.last);
  });

  test(
    'file checkpoint store holds one lease and replaces atomically',
    () async {
      final sandbox = _canonicalTempDirectory('l10n-store-');
      final output = File(p.join(sandbox.path, 'result.json'));
      final staleFixedTemp = File('${output.path}.tmp.$pid')
        ..writeAsStringSync('unrelated stale file');
      final store = FileL10nReadinessCheckpointStore(maxResumeBytes: 1024);
      final lease = await store.claim(output);
      try {
        await expectLater(
          FileL10nReadinessCheckpointStore(maxResumeBytes: 1024).claim(output),
          throwsA(isA<FileSystemException>()),
        );
        await lease.write(canonicalL10nReadinessJson({'value': 1}));
        await lease.write(canonicalL10nReadinessJson({'value': 2}));

        expect(await lease.read(), {'value': 2});
        expect(staleFixedTemp.readAsStringSync(), 'unrelated stale file');
        expect(
          sandbox
              .listSync(followLinks: false)
              .map((entry) => p.basename(entry.path))
              .where((name) => name.contains('.checkpoint-')),
          isEmpty,
        );
      } finally {
        await lease.release();
      }

      final secondLease = await store.claim(output);
      await secondLease.release();
      expect(
        sandbox
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where((entry) => p.basename(entry.path).contains('.lock')),
        isEmpty,
      );
      sandbox.deleteSync(recursive: true);
    },
  );

  test(
    'file checkpoint store rejects noncanonical and oversized resume',
    () async {
      final sandbox = _canonicalTempDirectory('l10n-store-read-');
      final resume = File(p.join(sandbox.path, 'resume.json'));
      final store = FileL10nReadinessCheckpointStore(maxResumeBytes: 64);
      resume.writeAsStringSync('{}');
      final lease = await store.claim(resume);

      try {
        for (final malformed in <String>[
          '{"b":1,"a":2}',
          '{\n  "a": 1,\n  "a": 2\n}\n',
          'x' * 65,
        ]) {
          resume.writeAsStringSync(malformed);
          await expectLater(lease.read(), throwsFormatException);
        }
      } finally {
        await lease.release();
      }
      sandbox.deleteSync(recursive: true);
    },
  );

  test(
    'file checkpoint store restores the prior checkpoint on promotion failure',
    () async {
      final sandbox = _canonicalTempDirectory('l10n-store-promotion-');
      final output = File(p.join(sandbox.path, 'result.json'))
        ..writeAsStringSync(canonicalL10nReadinessJson({'value': 1}));
      final operations = _FailingPromotionOperations(output.path);
      final store = FileL10nReadinessCheckpointStore(
        maxResumeBytes: 1024,
        reportWriter: RecoverableReportWriter(operations: operations),
      );
      final lease = await store.claim(output);

      try {
        await expectLater(
          lease.write(canonicalL10nReadinessJson({'value': 2})),
          throwsA(isA<ReportPersistenceFailure>()),
        );
        expect(await lease.read(), {'value': 1});
        expect(
          sandbox.listSync(followLinks: false).map((entry) => entry.path),
          isNot(contains(operations.previousPath)),
        );
      } finally {
        await lease.release();
        sandbox.deleteSync(recursive: true);
      }
    },
  );

  test(
    'file checkpoint store never truncates a lease-path collision',
    () async {
      final sandbox = _canonicalTempDirectory('l10n-store-lease-collision-');
      final output = File(p.join(sandbox.path, 'result.json'));
      final leasePath = p.join(sandbox.path, '.result.json.l10n-stage1.lease');
      final sentinel = File(p.join(sandbox.path, 'sentinel'))
        ..writeAsStringSync('must-not-change');
      final store = FileL10nReadinessCheckpointStore(maxResumeBytes: 1024);

      File(leasePath).writeAsStringSync('unrelated regular file');
      await expectLater(store.claim(output), throwsA(anything));
      expect(File(leasePath).readAsStringSync(), 'unrelated regular file');
      File(leasePath).deleteSync();

      if (!Platform.isWindows) {
        final link = await Process.run('ln', [sentinel.path, leasePath]);
        expect(link.exitCode, 0, reason: '${link.stderr}');
        await expectLater(store.claim(output), throwsA(anything));
        expect(sentinel.readAsStringSync(), 'must-not-change');
      }
      sandbox.deleteSync(recursive: true);
    },
  );

  test('production denominator constant remains frozen', () {
    expect(L10nReadinessDenominators.productionFull.toJson(), {
      'individualKeys': 367,
      'familyBatches': 3,
      'staticPositiveCandidates': 367,
      'staticNegativeNonCandidates': 2235,
      'mutationNegativeFixtures': 14,
      'requiredRestorations': 370,
    });
  });
}

File _flutterBinary(Directory sandbox, String version) {
  final binary = File(p.join(sandbox.path, 'sdk', version, 'bin', 'flutter'))
    ..createSync(recursive: true);
  return File(binary.resolveSymbolicLinksSync());
}

Directory _canonicalTempDirectory(String prefix) {
  final created = Directory.systemTemp.createTempSync(prefix);
  return Directory(created.resolveSymbolicLinksSync());
}

final class _FailingPromotionOperations implements ReportFileOperations {
  _FailingPromotionOperations(this.destinationPath);

  final String destinationPath;
  final _delegate = const IoReportFileOperations();
  var _promotionFailed = false;

  String get previousPath => p.join(
    p.dirname(destinationPath),
    '.${p.basename(destinationPath)}.flutter_pruner.previous',
  );

  @override
  Future<void> createExclusive(String path) => _delegate.createExclusive(path);

  @override
  Future<void> createParent(String destination) =>
      _delegate.createParent(destination);

  @override
  Future<void> delete(String path) => _delegate.delete(path);

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) =>
      _delegate.deleteOwnedLock(path, ownerToken);

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<void> rename(String from, String to) {
    if (!_promotionFailed &&
        p.equals(to, destinationPath) &&
        p.basename(from).endsWith('.tmp')) {
      _promotionFailed = true;
      throw const FileSystemException('synthetic promotion failure');
    }
    return _delegate.rename(from, to);
  }

  @override
  Future<ResolvedReportDestination> resolveDestination(String requestedPath) =>
      _delegate.resolveDestination(requestedPath);

  @override
  Future<List<String>> transactionArtifactsFor(String destination) =>
      _delegate.transactionArtifactsFor(destination);

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) =>
      _delegate.writeAndConfirmLockOwner(path, ownerToken);
}

List<String> _replaceValue(List<String> argv, String option, String value) {
  final result = [...argv];
  result[result.indexOf(option) + 1] = value;
  return result;
}

L10nMutationReadinessOptions _productionOptions({
  required Directory sandbox,
  required Directory corpusRoot,
  String? caseSelection,
  String? familySelection,
  String outputName = 'full.json',
  Directory? outputParentOverride,
}) {
  final outputParent =
      outputParentOverride ??
      (caseSelection == null && familySelection == null
            ? Directory(p.join(corpusRoot.path, 'results'))
            : Directory(p.join(sandbox.path, 'smoke'))
        ..createSync(recursive: true));
  return L10nMutationReadinessOptions.parse([
    '--manifest',
    'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
    '--corpus-root',
    corpusRoot.path,
    for (final version in const ['3.41.5', '3.44.1', '3.44.9']) ...[
      '--sdk',
      '$version=${_flutterBinary(sandbox, 'production-$version').path}',
    ],
    '--output',
    p.join(outputParent.path, outputName),
    if (caseSelection != null) ...['--case', caseSelection],
    if (familySelection != null) ...['--family', familySelection],
  ]);
}

Map<String, Object?> _productionIdentities() => const {
  'coverageSpecSha256': _fakeSha256,
  'implementationSha256': _fakeSha256,
  'manifestSha256': _productionManifestSha256,
  'negativeRecipeMatrixSha256': _fakeSha256,
  'policySetSha256': _fakeSha256,
  'repositorySetSha256': _fakeSha256,
  'sdkSetSha256': _fakeSha256,
};

enum _ProductionPlanFault { none, invalidHash, repeatedProtectedRoot }

final class _Fixture {
  _Fixture({
    Directory? existingSandbox,
    this.extraNegativeFixture = false,
    this.productionProfile = false,
    this.scopeMismatch = false,
    this.reversePlanOrder = false,
    this.productionPlanFault = _ProductionPlanFault.none,
    this.enableProjectEligibilityPreflight = false,
  }) : sandbox =
           existingSandbox ??
           _canonicalTempDirectory('l10n-readiness-harness-') {
    for (final version in const ['3.41.5', '3.44.1', '3.44.9']) {
      sdkArguments.add('$version=${_flutterBinary(sandbox, version).path}');
    }
    scanner = _FakeScanner(calls);
    store = _FakeStore(calls);
    if (productionProfile) {
      for (final project in const ['gitjournal', 'gsy', 'smooth']) {
        protectedRoots.add(
          Directory(
            p.join(
              sandbox.path,
              'corpora',
              productionPlanFault == _ProductionPlanFault.repeatedProtectedRoot
                  ? 'shared'
                  : project,
            ),
          )..createSync(recursive: true),
        );
      }
    }
    addTearDown(close);
  }

  final Directory sandbox;
  final calls = <String>[];
  final sdkArguments = <String>[];
  final String mutationAuthority = 'process-local-mutation-authority-secret';
  final protectedRoots = <Directory>[];
  late final _FakeScanner scanner;
  late final _FakeStore store;
  bool evidenceAccepted = true;
  bool corpusPolicyPassed = true;
  bool restorationProven = true;
  int unexpectedWriteCount = 0;
  bool originalProjectDrift = false;
  bool malformedInternalEvidence = false;
  bool evaluatorThrows = false;
  bool corpusThrows = false;
  bool disposeThrows = false;
  bool wrongInternalSelection = false;
  bool wrongCorpusSelection = false;
  int? checkpointFailureWrite;
  bool checkpointClaimThrows = false;
  bool checkpointReadThrows = false;
  bool checkpointReleaseThrows = false;
  _NegativeMode negativeMode = _NegativeMode.passed;
  final bool extraNegativeFixture;
  final bool productionProfile;
  final bool scopeMismatch;
  final bool reversePlanOrder;
  final _ProductionPlanFault productionPlanFault;
  final bool enableProjectEligibilityPreflight;
  bool _ownsSandbox = true;

  List<String> argv({
    String? caseSelection,
    String? familySelection,
    File? resume,
    File? output,
  }) => [
    '--manifest',
    'benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json',
    '--corpus-root',
    sandbox.path,
    for (final sdk in sdkArguments) ...['--sdk', sdk],
    '--output',
    output?.path ?? resume?.path ?? p.join(sandbox.path, 'result.json'),
    if (resume != null) ...['--resume', resume.path],
    if (caseSelection != null) ...['--case', caseSelection],
    if (familySelection != null) ...['--family', familySelection],
  ];

  L10nMutationReadinessDependencies dependencies() {
    store.failureWrite = checkpointFailureWrite;
    store.claimThrows = checkpointClaimThrows;
    store.readThrows = checkpointReadThrows;
    store.releaseThrows = checkpointReleaseThrows;
    return L10nMutationReadinessDependencies(
      loadPlan: (options) async {
        final kind = options.caseSelection != null
            ? 'case'
            : options.familySelection != null
            ? 'family'
            : 'full';
        calls.add('plan:$kind');
        return _plan(options);
      },
      provisionView: (projectId) async {
        calls.add('provision:$projectId');
        return _FakeView(projectId, calls, disposeThrows: disposeThrows);
      },
      scanner: scanner,
      evaluatorFactory: () {
        calls.add('evaluator:new');
        return _FakeEvaluator(
          calls,
          accepted: evidenceAccepted,
          malformed: malformedInternalEvidence,
          mutationAuthority: mutationAuthority,
          throwsUnexpected: evaluatorThrows,
          wrongSelection: wrongInternalSelection,
        );
      },
      corpusEvidenceRunner: _FakeCorpusRunner(
        calls,
        expectedMutationAuthority: mutationAuthority,
        corpusPolicyPassed: corpusPolicyPassed,
        restorationProven: restorationProven,
        unexpectedWriteCount: unexpectedWriteCount,
        originalProjectDrift: originalProjectDrift,
        throwsUnexpected: corpusThrows,
        wrongSelection: wrongCorpusSelection,
      ),
      negativeFixtureRunner: _FakeNegativeRunner(calls, mode: negativeMode),
      checkpointStore: store,
      monotonicMicros: _FakeClock(),
      onStaticGate: (projectId) => calls.add('static-gate:$projectId'),
      enableProjectEligibilityPreflight: enableProjectEligibilityPreflight,
    );
  }

  L10nReadinessPlan _plan(L10nMutationReadinessOptions options) {
    final projectId = productionProfile ? 'smooth' : 'alpha';
    final positive = L10nReadinessOracleCase(
      caseId: '$projectId:l10n:unused_even_when_old_oracle_was_false',
      projectId: projectId,
      decodedKey: 'unused_even_when_old_oracle_was_false',
      mutationPositive: true,
      expectedScannerPresence: false,
    );
    final negative = L10nReadinessOracleCase(
      caseId: '$projectId:l10n:used_key',
      projectId: projectId,
      decodedKey: 'used_key',
      mutationPositive: false,
      expectedScannerPresence: false,
    );
    final isCase = options.caseSelection != null;
    final isFamily = options.familySelection != null;
    final effectiveCase = isCase && !scopeMismatch;
    final effectiveFamily = isFamily || isCase && scopeMismatch;
    return L10nReadinessPlan(
      profile: productionProfile
          ? L10nReadinessProfile.productionStage1
          : L10nReadinessProfile.syntheticContract,
      oracleVersion: 'fake-oracle-v1',
      identities: productionProfile
          ? {
              'coverageSpecSha256':
                  productionPlanFault == _ProductionPlanFault.invalidHash
                  ? '0' * 63
                  : _fakeSha256,
              'implementationSha256': _fakeSha256,
              'manifestSha256': _fakeSha256,
              'negativeRecipeMatrixSha256': _fakeSha256,
              'policySetSha256': _fakeSha256,
              'repositorySetSha256': _fakeSha256,
              'sdkSetSha256': _fakeSha256,
            }
          : const {
              'configSha256': 'config-v1',
              'manifestSha256': 'manifest-v1',
              'packageAuthoritySha256': 'package-v1',
              'policySha256': 'policy-v1',
              'repositorySha': '0123456789012345678901234567890123456789',
              'toolchainProbeSha256': 'toolchain-v1',
            },
      oracleCases: reversePlanOrder
          ? [negative, positive]
          : [positive, negative],
      individualCaseIds: effectiveFamily ? const [] : [positive.caseId],
      familyProjectIds: effectiveCase ? const [] : [projectId],
      mutationNegativeFixtures: isCase || isFamily
          ? const {}
          : reversePlanOrder
          ? {
              if (extraNegativeFixture)
                'z-fixture': const ['unsupportedConfiguration'],
              'raw-gsy': const ['analysisLimited'],
            }
          : {
              'raw-gsy': const ['analysisLimited'],
              if (extraNegativeFixture)
                'z-fixture': const ['unsupportedConfiguration'],
            },
      expectedDenominators: effectiveCase
          ? const L10nReadinessDenominators(
              individualKeys: 1,
              familyBatches: 0,
              staticPositiveCandidates: 1,
              staticNegativeNonCandidates: 1,
              mutationNegativeFixtures: 0,
              requiredRestorations: 1,
            )
          : effectiveFamily
          ? const L10nReadinessDenominators(
              individualKeys: 0,
              familyBatches: 1,
              staticPositiveCandidates: 1,
              staticNegativeNonCandidates: 1,
              mutationNegativeFixtures: 0,
              requiredRestorations: 1,
            )
          : L10nReadinessDenominators(
              individualKeys: 1,
              familyBatches: 1,
              staticPositiveCandidates: 1,
              staticNegativeNonCandidates: 1,
              mutationNegativeFixtures: extraNegativeFixture ? 2 : 1,
              requiredRestorations: 2,
            ),
      artifactRoot: options.outputFile.parent,
      protectedRoots: protectedRoots,
    );
  }

  void close() {
    if (_ownsSandbox && sandbox.existsSync()) {
      sandbox.deleteSync(recursive: true);
      _ownsSandbox = false;
    }
  }
}

final class _FakeView implements L10nReadinessProjectView {
  _FakeView(this.projectId, this.calls, {required this.disposeThrows});

  @override
  final String projectId;
  final List<String> calls;
  final bool disposeThrows;

  @override
  Future<void> dispose() async {
    calls.add('dispose:$projectId');
    if (disposeThrows) throw StateError('synthetic dispose failure');
  }
}

final class _FakeScanner implements L10nHarnessScanner {
  _FakeScanner(this.calls);

  final List<String> calls;
  bool omitFalseLegacyPositive = false;
  bool omitNegativeActualNode = false;
  bool duplicateActualNodeIds = false;
  bool addUnknownActualNode = false;
  bool addUnknownCandidate = false;
  bool driftAuthorityAfterFirstScan = false;
  bool negativeIsCandidate = false;
  int publicSafe = 0;
  int publicHigh = 0;
  int publicApplyEligible = 0;
  int publicProposed = 0;
  var _scanCount = 0;

  @override
  Future<L10nStaticScanResult> scan(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> oracleCases,
  ) async {
    calls.add('scan:${view.projectId}');
    _scanCount++;
    final positive = oracleCases.singleWhere((entry) => entry.mutationPositive);
    final negative = oracleCases.singleWhere(
      (entry) => !entry.mutationPositive,
    );
    return L10nStaticScanResult(
      authorityIdentity: driftAuthorityAfterFirstScan && _scanCount > 1
          ? 'scan-authority-v2'
          : 'scan-authority-v1',
      actualNodeIdByOracleCaseId: {
        if (!omitFalseLegacyPositive) positive.caseId: 'l10n:alpha:unused',
        if (!omitNegativeActualNode)
          negative.caseId: duplicateActualNodeIds
              ? 'l10n:alpha:unused'
              : 'l10n:alpha:used',
        if (addUnknownActualNode)
          'alpha:l10n:unknown-oracle': 'l10n:alpha:unknown-node',
      },
      candidateOracleCaseIds: {
        if (!omitFalseLegacyPositive) positive.caseId,
        if (negativeIsCandidate) negative.caseId,
        if (addUnknownCandidate) 'alpha:l10n:unknown-candidate',
      },
      publicSafeL10n: publicSafe,
      publicHighL10n: publicHigh,
      publicApplyEligibleL10n: publicApplyEligible,
      publicProposedL10nActions: publicProposed,
    );
  }
}

final class _FakeEvaluator implements L10nEvidenceEvaluator {
  _FakeEvaluator(
    this.calls, {
    required this.accepted,
    required this.malformed,
    required this.mutationAuthority,
    required this.throwsUnexpected,
    required this.wrongSelection,
  });

  final List<String> calls;
  final bool accepted;
  final bool malformed;
  final Object mutationAuthority;
  final bool throwsUnexpected;
  final bool wrongSelection;

  @override
  Future<L10nInternalEvidenceResult> evaluateIndividual(
    L10nReadinessProjectView view,
    L10nReadinessOracleCase oracleCase,
    L10nStaticScanResult scan,
  ) async {
    calls.add('verdict:${oracleCase.caseId}');
    if (throwsUnexpected) throw StateError('synthetic evaluator failure');
    return _internalEvidence(
      wrongSelection ? 'alpha:l10n:wrong-selection' : oracleCase.caseId,
      accepted,
      malformed: malformed,
      mutationAuthority: mutationAuthority,
    );
  }

  @override
  Future<L10nInternalEvidenceResult> evaluateFamily(
    L10nReadinessProjectView view,
    List<L10nReadinessOracleCase> positiveCases,
    L10nStaticScanResult scan,
  ) async {
    calls.add('verdict:family:${view.projectId}');
    if (throwsUnexpected) throw StateError('synthetic evaluator failure');
    return _internalEvidence(
      wrongSelection ? 'family:wrong-project' : 'family:${view.projectId}',
      accepted,
      malformed: malformed,
      mutationAuthority: mutationAuthority,
    );
  }
}

L10nInternalEvidenceResult _internalEvidence(
  String selectionIdentity,
  bool accepted, {
  required bool malformed,
  required Object mutationAuthority,
}) => L10nInternalEvidenceResult(
  selectionIdentity: selectionIdentity,
  accepted: accepted,
  mutationAuthority: accepted ? mutationAuthority : null,
  bytesCopied: 41,
  stageMicros: malformed ? -1 : 101,
  baselineGeneratorMicros: 11,
  candidateGeneratorMicros: 13,
  sampledPeakRssBytes: 1024,
  verdictIdentity: 'verdict-v1',
  verdictFailures: accepted
      ? const []
      : [
          L10nVerdictFailure(
            code: 'scanBlockerPresent',
            stage: 'family-preflight',
            detailCode: 'selected-node-retained',
          ),
        ],
);

final class _FakeCorpusRunner implements L10nCorpusEvidenceRunner {
  _FakeCorpusRunner(
    this.calls, {
    required this.expectedMutationAuthority,
    required this.corpusPolicyPassed,
    required this.restorationProven,
    required this.unexpectedWriteCount,
    required this.originalProjectDrift,
    required this.throwsUnexpected,
    required this.wrongSelection,
  });

  final List<String> calls;
  final Object expectedMutationAuthority;
  final bool corpusPolicyPassed;
  final bool restorationProven;
  final int unexpectedWriteCount;
  final bool originalProjectDrift;
  final bool throwsUnexpected;
  final bool wrongSelection;

  @override
  Future<L10nCorpusEvidenceResult> run(
    L10nReadinessProjectView view,
    String selectionIdentity,
    L10nInternalEvidenceResult acceptedVerdict,
  ) async {
    if (!acceptedVerdict.accepted ||
        acceptedVerdict.mutationAuthority == null) {
      throw StateError('corpus runner received a rejected verdict');
    }
    if (!identical(
      acceptedVerdict.mutationAuthority,
      expectedMutationAuthority,
    )) {
      throw StateError('corpus runner received the wrong mutation authority');
    }
    calls.add('corpus:$selectionIdentity');
    if (throwsUnexpected) throw StateError('synthetic corpus failure');
    calls.add('restoration:$selectionIdentity');
    return L10nCorpusEvidenceResult(
      selectionIdentity: wrongSelection
          ? 'wrong:$selectionIdentity'
          : selectionIdentity,
      corpusPolicyPassed: corpusPolicyPassed,
      restorationProven: restorationProven,
      unexpectedWriteCount: unexpectedWriteCount,
      originalProjectDrift: originalProjectDrift,
      policyMicros: 17,
      sampledPeakRssBytes: 1024,
      corpusPolicyIdentity: 'policy-v1',
      restorationIdentity: 'restoration-v1',
    );
  }
}

enum _NegativeMode { passed, notRejected, disallowedReason, throwUnexpected }

final class _FakeNegativeRunner implements L10nMutationNegativeFixtureRunner {
  _FakeNegativeRunner(this.calls, {required this.mode});

  final List<String> calls;
  final _NegativeMode mode;

  @override
  Future<L10nMutationNegativeResult> run(
    String fixtureId,
    List<String> allowedReasons,
  ) async {
    calls.add('negative:$fixtureId');
    if (mode == _NegativeMode.throwUnexpected) {
      throw StateError('synthetic negative runner failure');
    }
    return L10nMutationNegativeResult(
      rejected: mode != _NegativeMode.notRejected,
      observedReason: mode == _NegativeMode.disallowedReason
          ? 'unexpectedReason'
          : allowedReasons.single,
      evidenceIdentity: 'negative-v1',
    );
  }
}

final class _FakeStore implements L10nReadinessCheckpointStore {
  _FakeStore(this.calls);

  final List<String> calls;
  final writes = <String>[];
  Object? resumeValue;
  int? failureWrite;
  int attemptedWrites = 0;
  bool claimThrows = false;
  bool readThrows = false;
  bool releaseThrows = false;
  int claimAttempts = 0;
  int releaseAttempts = 0;

  @override
  Future<L10nReadinessCheckpointLease> claim(File file) async {
    claimAttempts++;
    if (claimThrows) throw StateError('synthetic claim failure');
    return _FakeLease(this);
  }
}

final class _FakeLease implements L10nReadinessCheckpointLease {
  _FakeLease(this.store);

  final _FakeStore store;

  @override
  Future<Object?> read() async {
    store.calls.add('resume:read');
    if (store.readThrows) throw StateError('synthetic read failure');
    return store.resumeValue;
  }

  @override
  Future<void> write(String canonicalJson) async {
    store.calls.add('checkpoint');
    store.attemptedWrites++;
    if (store.failureWrite == store.attemptedWrites) {
      throw StateError('synthetic checkpoint failure');
    }
    store.writes.add(canonicalJson);
  }

  @override
  Future<void> release() async {
    store.releaseAttempts++;
    if (store.releaseThrows) throw StateError('synthetic release failure');
  }
}

final class _FakeClock implements MonotonicMicros {
  var _value = 0;

  @override
  int now() => _value++;
}
