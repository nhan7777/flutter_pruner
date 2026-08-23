import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_preflight.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_family_snapshot.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_materializer.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_stage_verifier.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/analysis/analysis_snapshot.dart';
import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/graph/edge.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

const _verificationStage = 'stage-verification';
const _comparisonStage = 'stage-verification-comparison';
const _templatePath = 'lib/l10n/app_en.arb';
const _localePath = 'lib/l10n/app_vi.arb';
const _outputPath = 'lib/generated/app.dart';
const _mainPath = 'lib/main.dart';
const _selectedKey = 'dead';
const _identity =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

void main() {
  group('L10nStageVerificationPolicy', () {
    test('is a fixed versioned in-process policy', () {
      const policy = L10nStageVerificationPolicy();

      expect(L10nStageVerificationPolicy.schemaVersion, 1);
      expect(L10nStageVerificationPolicy.steps, const [
        'arb-postconditions',
        'generated-member-identity',
        'dart-l10n-graph',
        'publishable-path-immutability',
      ]);
      expect(policy.hash, matches(_sha256Pattern));
      expect(const L10nStageVerificationPolicy().hash, policy.hash);
      expect(
        () => L10nStageVerificationPolicy.steps.add('project-command'),
        throwsUnsupportedError,
      );
    });

    test('production verifier exposes only the fixed inspector dependency', () {
      expect(
        DefaultL10nStageVerifier(
          inspector: const L10nGeneratedMemberInspector(),
        ),
        isA<L10nStageVerifier>(),
      );
    });
  });

  group('L10nStageVerificationResult', () {
    test('sorts failures and deeply freezes a deterministic summary', () {
      final mutableItems = <Object?>[
        <String, Object?>{'z': 2, 'a': 1},
      ];
      final mutableSummary = <String, Object?>{
        'z': mutableItems,
        'a': <String, Object?>{'z': true, 'a': false},
      };
      final result = L10nStageVerificationResult(
        accepted: false,
        failures: const [
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.candidateVerificationFailed,
            stage: _verificationStage,
            detailCode: 'z-detail',
            relativePath: 'z.dart',
          ),
          L10nEvidenceFailure(
            code: L10nEvidenceRejectionCode.arbParseFailure,
            stage: _verificationStage,
            detailCode: 'a-detail',
            relativePath: 'a.arb',
          ),
        ],
        policyIdentity: _hash('policy'),
        analyzerRootIdentity: _hash('analyzer'),
        packageResolutionIdentity: _hash('packages'),
        toolchainIdentity: _hash('toolchain'),
        publishableBeforeIdentity: _hash('before'),
        publishableAfterIdentity: _hash('after'),
        summary: mutableSummary,
      );
      mutableItems.clear();
      mutableSummary.clear();

      expect(result.accepted, isFalse);
      expect(result.failures.map((failure) => failure.code).toList(), [
        L10nEvidenceRejectionCode.arbParseFailure,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
      ]);
      expect(result.summary.keys, ['a', 'z']);
      expect((result.summary['a']! as Map).keys, ['a', 'z']);
      expect(result.summary['z'], [
        {'a': 1, 'z': 2},
      ]);
      expect(() => result.failures.clear(), throwsUnsupportedError);
      expect(() => result.summary.clear(), throwsUnsupportedError);
      expect(
        () => (result.summary['z']! as List<Object?>).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (result.summary['a']! as Map<Object?, Object?>).clear(),
        throwsUnsupportedError,
      );
    });

    test('requires accepted and failure state to agree', () {
      expect(
        () => _result(
          accepted: true,
          failures: const [
            L10nEvidenceFailure(
              code: L10nEvidenceRejectionCode.internalFailure,
              stage: _verificationStage,
              detailCode: 'fixture',
            ),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => _result(accepted: false, failures: const []),
        throwsArgumentError,
      );
    });

    test('compares only frozen baseline-candidate authority identities', () {
      final baseline = _result();
      final matching = _result(
        publishableBeforeIdentity: _hash('candidate-publishable'),
        publishableAfterIdentity: _hash('candidate-publishable'),
      );

      final matchingFailures = L10nStageVerificationComparator.compare(
        baseline: baseline,
        candidate: matching,
      );

      expect(matchingFailures, isEmpty);
      expect(() => matchingFailures.clear(), throwsUnsupportedError);

      final mismatches =
          <({String detail, L10nStageVerificationResult Function() candidate})>[
            (
              detail: 'verification-policy-identity-mismatch',
              candidate: () => _result(policyIdentity: _hash('other-policy')),
            ),
            (
              detail: 'analyzer-root-identity-mismatch',
              candidate: () =>
                  _result(analyzerRootIdentity: _hash('other-analyzer')),
            ),
            (
              detail: 'package-resolution-identity-mismatch',
              candidate: () =>
                  _result(packageResolutionIdentity: _hash('other-packages')),
            ),
            (
              detail: 'toolchain-identity-mismatch',
              candidate: () =>
                  _result(toolchainIdentity: _hash('other-toolchain')),
            ),
          ];
      for (final mismatch in mismatches) {
        final failures = L10nStageVerificationComparator.compare(
          baseline: baseline,
          candidate: mismatch.candidate(),
        );
        _expectOnlyFailure(
          failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          mismatch.detail,
          stage: _comparisonStage,
        );
      }
    });
  });

  group('DefaultL10nStageVerifier', () {
    test(
      'production runner executes the fixed in-process Dart and l10n catalog',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);

        final result = await fixture.verifyCandidate(
          DefaultL10nStageVerifier(
            inspector: const L10nGeneratedMemberInspector(),
          ),
        );

        expect(
          result.failures,
          isEmpty,
          reason: result.failures
              .map(
                (failure) =>
                    '${failure.code.name}/${failure.stage}/'
                    '${failure.relativePath}/${failure.detailCode}',
              )
              .join(', '),
        );
        expect(result.accepted, isTrue);
        expect(result.summary['analyzerAdapterIds'], const ['dart', 'l10n']);
        expect(result.summary['graphNodeCount'], isA<int>());
        expect(result.summary['graphEdgeCount'], isA<int>());
        expect(result.summary['graphBlockerCount'], isA<int>());
      },
    );

    test(
      'constructs the staged ProjectContext directly and accepts both roots',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        final observedRoots = <String>[];
        final observedFilters = <Set<String>>[];
        final verifier = fixture.verifier(
          analysisRunner: (project, only) async {
            observedRoots.add(project.root.resolveSymbolicLinksSync());
            observedFilters.add(Set<String>.of(only));
            expect(
              project.packageName,
              fixture.snapshot.projectSemantics.packageName,
            );
            expect(
              project.analysisMode,
              fixture.snapshot.projectSemantics.analysisMode,
            );
            expect(project.targetMatrix.targets.single.entrypoint, _mainPath);
            expect(
              project.rootCoverage.mode,
              RootCoverageMode.applicationEntrypoints,
            );
            // A malformed staged flutter_pruner.yaml is deliberately present.
            // ProjectContext.load would discover it; direct construction does not.
            return _analysisFor(project);
          },
        );

        final baseline = await verifier.verify(
          stage: fixture.pair.baseline,
          snapshot: fixture.snapshot,
          expectedRemovedKeys: const {},
          toolchain: fixture.toolchain,
        );
        final candidate = await verifier.verify(
          stage: fixture.pair.candidate,
          snapshot: fixture.snapshot,
          expectedRemovedKeys: const {_selectedKey},
          toolchain: fixture.toolchain,
        );

        expect(baseline.accepted, isTrue);
        expect(candidate.accepted, isTrue);
        expect(baseline.failures, isEmpty);
        expect(candidate.failures, isEmpty);
        expect(observedRoots, [
          fixture.pair.baseline.directory.resolveSymbolicLinksSync(),
          fixture.pair.candidate.directory.resolveSymbolicLinksSync(),
        ]);
        expect(observedFilters, [
          const {'l10n'},
          const {'l10n'},
        ]);
        expect(baseline.policyIdentity, candidate.policyIdentity);
        expect(
          candidate.policyIdentity,
          const L10nStageVerificationPolicy().hash,
        );
        expect(baseline.analyzerRootIdentity, candidate.analyzerRootIdentity);
        expect(
          candidate.analyzerRootIdentity,
          fixture.snapshot.verificationClosure.analyzerRootIdentity,
        );
        expect(
          baseline.packageResolutionIdentity,
          candidate.packageResolutionIdentity,
        );
        expect(
          candidate.packageResolutionIdentity,
          fixture.snapshot.packageResolutionIdentity,
        );
        expect(baseline.toolchainIdentity, fixture.toolchain.identitySha256);
        expect(candidate.toolchainIdentity, fixture.toolchain.identitySha256);
        expect(
          baseline.publishableBeforeIdentity,
          baseline.publishableAfterIdentity,
        );
        expect(
          candidate.publishableBeforeIdentity,
          candidate.publishableAfterIdentity,
        );
        expect(
          baseline.publishableBeforeIdentity,
          isNot(candidate.publishableBeforeIdentity),
        );
        expect(
          candidate.summary['policySteps'],
          L10nStageVerificationPolicy.steps,
        );
        expect(() => candidate.summary.clear(), throwsUnsupportedError);
      },
    );

    test(
      'allows analyzer cache writes outside protected publishable paths',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        final verifier = fixture.verifier(
          analysisRunner: (project, only) async {
            final cache = File(
              p.join(
                project.root.path,
                '.dart_tool',
                'analysis-cache',
                'state',
              ),
            );
            cache.parent.createSync(recursive: true);
            cache.writeAsStringSync('tool-owned cache\n');
            return _analysisFor(project);
          },
        );

        final result = await fixture.verifyCandidate(verifier);

        expect(result.accepted, isTrue);
        expect(
          result.publishableBeforeIdentity,
          result.publishableAfterIdentity,
        );
      },
    );

    test('rejects retained l10n graph semantic drift across roots', () async {
      final fixture = await _VerifierFixture.create(baselineRetainedEdge: true);
      addTearDown(fixture.dispose);
      final baseline = await fixture
          .verifier(
            analysisRunner: (project, only) async =>
                _analysisFor(project, withRetainedEdge: true),
          )
          .verify(
            stage: fixture.pair.baseline,
            snapshot: fixture.snapshot,
            expectedRemovedKeys: const {},
            toolchain: fixture.toolchain,
          );
      final candidate = await fixture.verifyCandidate(fixture.verifier());

      expect(baseline.accepted, isTrue);
      expect(candidate.accepted, isTrue);
      _expectOnlyFailure(
        L10nStageVerificationComparator.compare(
          baseline: baseline,
          candidate: candidate,
        ),
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'retained-l10n-graph-identity-mismatch',
        stage: _comparisonStage,
      );
    });

    test('rejects retained generated signature drift across roots', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final baseline = await fixture.verifier().verify(
        stage: fixture.pair.baseline,
        snapshot: fixture.snapshot,
        expectedRemovedKeys: const {},
        toolchain: fixture.toolchain,
      );
      fixture.writeCandidateOutput(
        _generatedSource("  String get alive => 'Alive';\n"),
      );
      final candidate = await fixture.verifyCandidate(fixture.verifier());

      expect(baseline.accepted, isTrue);
      expect(candidate.accepted, isTrue);
      _expectOnlyFailure(
        L10nStageVerificationComparator.compare(
          baseline: baseline,
          candidate: candidate,
        ),
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'retained-generated-member-identity-mismatch',
        stage: _comparisonStage,
      );
    });

    test('binds the generated lookup signature across roots', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final baseline = await fixture.verifier().verify(
        stage: fixture.pair.baseline,
        snapshot: fixture.snapshot,
        expectedRemovedKeys: const {},
        toolchain: fixture.toolchain,
      );
      fixture.writeCandidateOutput(
        _candidateGeneratedSource.replaceFirst(
          'BuildContext context',
          'BuildContext ctx',
        ),
      );
      final candidate = await fixture.verifyCandidate(fixture.verifier());

      expect(baseline.accepted, isTrue);
      expect(candidate.accepted, isTrue);
      _expectOnlyFailure(
        L10nStageVerificationComparator.compare(
          baseline: baseline,
          candidate: candidate,
        ),
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'retained-generated-member-identity-mismatch',
        stage: _comparisonStage,
      );
    });

    test('rejects selected ARB messages or companions that remain', () async {
      for (final member in const ['dead', '@dead']) {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        fixture.writeCandidateArb(
          member == 'dead'
              ? '{"@@locale":"en","alive":"Alive","dead":"Dead"}\n'
              : '{"@@locale":"en","alive":"Alive",'
                    '"@dead":{"description":"still here"}}\n',
        );

        final result = await fixture.verifyCandidate(fixture.verifier());

        _expectOnlyFailure(
          result.failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          member == 'dead'
              ? 'selected-arb-member-present'
              : 'selected-arb-companion-present',
          stage: _verificationStage,
          relativePath: _templatePath,
        );
      }
    });

    test('reparses and verifies every locale ARB', () async {
      final selected = await _VerifierFixture.create();
      addTearDown(selected.dispose);
      selected.writeCandidateLocaleArb(
        '{"@@locale":"vi","alive":"Song","dead":"Chet"}\n',
      );
      _expectOnlyFailure(
        (await selected.verifyCandidate(selected.verifier())).failures,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'selected-arb-member-present',
        stage: _verificationStage,
        relativePath: _localePath,
      );

      final malformed = await _VerifierFixture.create();
      addTearDown(malformed.dispose);
      malformed.writeCandidateLocaleArb('{"alive":');
      _expectOnlyFailure(
        (await malformed.verifyCandidate(malformed.verifier())).failures,
        L10nEvidenceRejectionCode.arbParseFailure,
        'candidate-arb-parse-failed',
        stage: _verificationStage,
        relativePath: _localePath,
      );
    });

    test(
      'rejects retained ARB token drift and malformed candidate bytes',
      () async {
        final drift = await _VerifierFixture.create();
        addTearDown(drift.dispose);
        drift.writeCandidateArb(
          '{"@@locale":"en", "alive":"Changed spacing and value"}\n',
        );
        _expectOnlyFailure(
          (await drift.verifyCandidate(drift.verifier())).failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          'retained-arb-token-drift',
          stage: _verificationStage,
          relativePath: _templatePath,
        );

        final lexicalDrift = await _VerifierFixture.create();
        addTearDown(lexicalDrift.dispose);
        lexicalDrift.writeCandidateArb(
          r'{"@@locale":"en","alive":"\u0041live"}'
          '\n',
        );
        _expectOnlyFailure(
          (await lexicalDrift.verifyCandidate(
            lexicalDrift.verifier(),
          )).failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          'retained-arb-token-drift',
          stage: _verificationStage,
          relativePath: _templatePath,
        );

        final malformed = await _VerifierFixture.create();
        addTearDown(malformed.dispose);
        malformed.writeCandidateArb('{"alive":');
        _expectOnlyFailure(
          (await malformed.verifyCandidate(malformed.verifier())).failures,
          L10nEvidenceRejectionCode.arbParseFailure,
          'candidate-arb-parse-failed',
          stage: _verificationStage,
          relativePath: _templatePath,
        );
      },
    );

    test('rejects selected generated members that remain', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      fixture.writeCandidateOutput(_baselineGeneratedSource);

      final result = await fixture.verifyCandidate(fixture.verifier());

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'selected-generated-member-present',
        stage: _verificationStage,
        relativePath: _outputPath,
      );
    });

    test('propagates selected generated-member ambiguity', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      fixture.writeCandidateOutput(
        _generatedSource('''
  String get alive;
  String get dead;
  String dead();
'''),
      );

      final result = await fixture.verifyCandidate(fixture.verifier());

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'generated-member-ambiguous',
        stage: 'generated-member-inspection',
        relativePath: _outputPath,
      );
    });

    test(
      'rejects missing or wrong-shaped retained generated members',
      () async {
        final cases = <({String source, String detail})>[
          (
            source: _generatedSource(''),
            detail: 'retained-generated-member-missing',
          ),
          (
            source: _generatedSource('  String alive();\n'),
            detail: 'retained-generated-member-shape-mismatch',
          ),
        ];
        for (final testCase in cases) {
          final fixture = await _VerifierFixture.create();
          addTearDown(fixture.dispose);
          fixture.writeCandidateOutput(testCase.source);

          final result = await fixture.verifyCandidate(fixture.verifier());

          _expectOnlyFailure(
            result.failures,
            L10nEvidenceRejectionCode.candidateVerificationFailed,
            testCase.detail,
            stage: _verificationStage,
            relativePath: _outputPath,
          );
        }
      },
    );

    test(
      'rejects an incomplete staged analyzer closure before analysis',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        File(
          p.join(fixture.pair.candidate.directory.path, _mainPath),
        ).deleteSync();
        var analysisCalled = false;
        final verifier = fixture.verifier(
          analysisRunner: (project, only) async {
            analysisCalled = true;
            return _analysisFor(project);
          },
        );

        final result = await fixture.verifyCandidate(verifier);

        expect(analysisCalled, isFalse);
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          'analyzer-closure-incomplete',
          relativePath: _mainPath,
        );
      },
    );

    test('rejects a byte-identical replacement stage root', () async {
      if (Platform.isWindows) return;
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      _replaceDirectoryWithCopy(fixture.pair.candidate.directory);

      final result = await fixture.verifyCandidate(fixture.verifier());

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'stage-root-identity-drift',
        stage: _verificationStage,
      );
      expect(fixture.pair.candidate.safeToDelete, isFalse);
    });

    test('returns typed drift for a malformed toolchain identity', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final malformed = _toolchain(
        Directory(fixture.toolchain.canonicalSdkRoot),
        identitySha256: 'malformed',
      );

      final result = await fixture.verifier().verify(
        stage: fixture.pair.candidate,
        snapshot: fixture.snapshot,
        expectedRemovedKeys: const {_selectedKey},
        toolchain: malformed,
      );

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.toolchainDrift,
        'stage-toolchain-identity-mismatch',
        stage: _verificationStage,
      );
      expect(result.toolchainIdentity, matches(_sha256Pattern));
      expect(result.toolchainIdentity, isNot('malformed'));
    });

    test('rejects extra or drifted staged analyzer sources', () async {
      final cases = <({String label, void Function(_VerifierFixture) mutate})>[
        (
          label: 'extra-source',
          mutate: (fixture) {
            final file = File(
              p.join(fixture.pair.candidate.directory.path, 'lib/extra.dart'),
            );
            file.writeAsStringSync('const extra = true;\n');
          },
        ),
        (
          label: 'source-bytes',
          mutate: (fixture) {
            File(
              p.join(fixture.pair.candidate.directory.path, _mainPath),
            ).writeAsStringSync('void main() { throw StateError("drift"); }\n');
          },
        ),
        if (!Platform.isWindows)
          (
            label: 'source-mode',
            mutate: (fixture) {
              _setFileMode(
                File(p.join(fixture.pair.candidate.directory.path, _mainPath)),
                0x180,
              );
            },
          ),
      ];
      for (final testCase in cases) {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        testCase.mutate(fixture);
        var analysisCalled = false;
        final result = await fixture.verifyCandidate(
          fixture.verifier(
            analysisRunner: (project, only) async {
              analysisCalled = true;
              return _analysisFor(project);
            },
          ),
        );

        expect(analysisCalled, isFalse, reason: testCase.label);
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          testCase.label == 'extra-source'
              ? 'analyzer-closure-incomplete'
              : 'analyzer-closure-identity-drift',
          relativePath: testCase.label == 'extra-source'
              ? 'lib/extra.dart'
              : _mainPath,
        );
      }
    });

    test(
      'rejects a selected package mapping back to the live project',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        fixture.rewriteSelectedPackageRoot(
          fixture.originalProject.uri.toString(),
        );
        var analysisCalled = false;
        final verifier = fixture.verifier(
          analysisRunner: (project, only) async {
            analysisCalled = true;
            return _analysisFor(project);
          },
        );

        final result = await fixture.verifyCandidate(verifier);

        expect(analysisCalled, isFalse);
        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.packageResolutionDrift,
          'selected-package-root-not-stage',
          relativePath: '.dart_tool/package_config.json',
        );
      },
    );

    test('rejects semantically valid staged package-authority drift', () async {
      final cases = <({String path, void Function(File) mutate})>[
        (
          path: '.dart_tool/package_config.json',
          mutate: (file) {
            final decoded = jsonDecode(file.readAsStringSync());
            file.writeAsStringSync(
              const JsonEncoder.withIndent('  ').convert(decoded),
            );
          },
        ),
        (
          path: 'pubspec.lock',
          mutate: (file) {
            file.writeAsStringSync('packages: {}\n# staged drift\n');
          },
        ),
      ];
      for (final testCase in cases) {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        testCase.mutate(
          File(p.join(fixture.pair.candidate.directory.path, testCase.path)),
        );
        var analysisCalled = false;
        final result = await fixture.verifyCandidate(
          fixture.verifier(
            analysisRunner: (project, only) async {
              analysisCalled = true;
              return _analysisFor(project);
            },
          ),
        );

        expect(analysisCalled, isFalse, reason: testCase.path);
        _expectOnlyFailure(
          result.failures,
          L10nEvidenceRejectionCode.packageResolutionDrift,
          testCase.path == '.dart_tool/package_config.json'
              ? 'package-authority-identity-mismatch'
              : 'staged-package-input-drift',
          stage: _verificationStage,
          relativePath: testCase.path,
        );
      }
    });

    test(
      'rejects an external package root that is no longer read-only',
      () async {
        if (Platform.isWindows) return;
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        Process.runSync('chmod', ['0775', fixture.flutterPackage.path]);

        final result = await fixture.verifyCandidate(fixture.verifier());

        _expectFailure(
          result.failures,
          L10nEvidenceRejectionCode.packageResolutionDrift,
          'external-package-root-writable',
          relativePath: '.dart_tool/package_config.json',
        );
      },
    );

    test('rejects read-only external package authority drift', () async {
      if (Platform.isWindows) return;
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final pubspec = File(p.join(fixture.flutterPackage.path, 'pubspec.yaml'));
      _setFileMode(pubspec, 0x1a4);
      pubspec.writeAsStringSync('name: flutter\n# authority drift\n');
      _setFileMode(pubspec, 0x124);

      final result = await fixture.verifyCandidate(fixture.verifier());

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'package-authority-identity-mismatch',
        stage: _verificationStage,
        relativePath: '.dart_tool/package_config.json',
      );
    });

    test('rejects external analyzer-source content drift', () async {
      if (Platform.isWindows) return;
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      File(
        p.join(fixture.flutterPackage.path, 'lib', 'widgets.dart'),
      ).writeAsStringSync('class ChangedWidget {}\n');
      var analysisCalled = false;

      final result = await fixture.verifyCandidate(
        fixture.verifier(
          analysisRunner: (project, only) async {
            analysisCalled = true;
            return _analysisFor(project);
          },
        ),
      );

      expect(analysisCalled, isFalse);
      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'package-authority-identity-mismatch',
        stage: _verificationStage,
        relativePath: '.dart_tool/package_config.json',
      );
    });

    test('rejects external analyzer-source ABA drift', () async {
      if (Platform.isWindows) return;
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final source = File(
        p.join(fixture.flutterPackage.path, 'lib', 'widgets.dart'),
      );
      final original = source.readAsBytesSync();
      final verifier = fixture.verifier(
        analysisRunner: (project, only) async {
          source.writeAsStringSync('class TransientWidget {}\n');
          await Future<void>.delayed(const Duration(milliseconds: 2));
          final analysis = _analysisFor(project);
          source.writeAsBytesSync(original, flush: true);
          return analysis;
        },
      );

      final result = await fixture.verifyCandidate(verifier);

      _expectOnlyFailure(
        result.failures,
        L10nEvidenceRejectionCode.packageResolutionDrift,
        'package-authority-identity-mismatch',
        stage: _verificationStage,
        relativePath: '.dart_tool/package_config.json',
      );
    });

    test('rejects dangling staged graph endpoints', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final verifier = fixture.verifier(
        analysisRunner: (project, only) async =>
            _analysisFor(project, withDanglingEdge: true),
      );

      final result = await fixture.verifyCandidate(verifier);

      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.candidateVerificationFailed,
        'staged-graph-integrity-incomplete',
      );
    });

    test('rejects a new blocker addressing the retained l10n family', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final verifier = fixture.verifier(
        analysisRunner: (project, only) async =>
            _analysisFor(project, withFamilyBlocker: true),
      );

      final result = await fixture.verifyCandidate(verifier);

      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'staged-l10n-blocker',
      );
    });

    test('rejects a broad blocker that can address the l10n family', () async {
      final fixture = await _VerifierFixture.create();
      addTearDown(fixture.dispose);
      final verifier = fixture.verifier(
        analysisRunner: (project, only) async =>
            _analysisFor(project, withBroadFamilyBlocker: true),
      );

      final result = await fixture.verifyCandidate(verifier);

      _expectFailure(
        result.failures,
        L10nEvidenceRejectionCode.scanBlockerPresent,
        'staged-l10n-blocker',
      );
    });

    test(
      'rejects verification-time mutation of ARB config or generated paths',
      () async {
        for (final path in [_templatePath, 'l10n.yaml', _outputPath]) {
          final fixture = await _VerifierFixture.create();
          addTearDown(fixture.dispose);
          final verifier = fixture.verifier(
            analysisRunner: (project, only) async {
              File(p.join(project.root.path, path)).writeAsStringSync(
                path.endsWith('.arb')
                    ? '{"@@locale":"en","alive":"Alive"}\n '
                    : path.endsWith('.yaml')
                    ? '${File(p.join(project.root.path, path)).readAsStringSync()}# cache\n'
                    : '${File(p.join(project.root.path, path)).readAsStringSync()}\n',
              );
              return _analysisFor(project);
            },
          );

          final result = await fixture.verifyCandidate(verifier);

          expect(result.accepted, isFalse, reason: path);
          expect(
            result.publishableAfterIdentity,
            isNot(result.publishableBeforeIdentity),
            reason: path,
          );
          _expectFailure(
            result.failures,
            L10nEvidenceRejectionCode.candidateVerificationFailed,
            'publishable-path-mutated',
            relativePath: path,
          );
        }
      },
    );

    test(
      'rejects protected-path ABA mutation restored before return',
      () async {
        final fixture = await _VerifierFixture.create();
        addTearDown(fixture.dispose);
        final mainFile = File(
          p.join(fixture.pair.candidate.directory.path, _mainPath),
        );
        final originalBytes = mainFile.readAsBytesSync();
        final originalMode = Platform.isWindows
            ? null
            : mainFile.statSync().mode & 0xfff;
        final verifier = fixture.verifier(
          analysisRunner: (project, only) async {
            mainFile.writeAsStringSync('void main() => transientDrift();\n');
            await Future<void>.delayed(const Duration(milliseconds: 2));
            final analysis = _analysisFor(project);
            mainFile.writeAsBytesSync(originalBytes, flush: true);
            if (originalMode != null) _setFileMode(mainFile, originalMode);
            return analysis;
          },
        );

        final result = await fixture.verifyCandidate(verifier);

        _expectOnlyFailure(
          result.failures,
          L10nEvidenceRejectionCode.candidateVerificationFailed,
          'publishable-path-mutated',
          stage: _verificationStage,
          relativePath: _mainPath,
        );
        expect(
          mainFile.readAsBytesSync(),
          originalBytes,
          reason: 'the exploit restores bytes but must not restore authority',
        );
      },
    );
  });
}

L10nStageVerificationResult _result({
  bool accepted = true,
  List<L10nEvidenceFailure> failures = const [],
  String? policyIdentity,
  String? analyzerRootIdentity,
  String? packageResolutionIdentity,
  String? toolchainIdentity,
  String? publishableBeforeIdentity,
  String? publishableAfterIdentity,
}) => L10nStageVerificationResult(
  accepted: accepted,
  failures: failures,
  policyIdentity: policyIdentity ?? _hash('policy'),
  analyzerRootIdentity: analyzerRootIdentity ?? _hash('analyzer'),
  packageResolutionIdentity: packageResolutionIdentity ?? _hash('packages'),
  toolchainIdentity: toolchainIdentity ?? _hash('toolchain'),
  publishableBeforeIdentity: publishableBeforeIdentity ?? _hash('publishable'),
  publishableAfterIdentity: publishableAfterIdentity ?? _hash('publishable'),
  summary: const {
    'policySteps': [
      'arb-postconditions',
      'generated-member-identity',
      'dart-l10n-graph',
      'publishable-path-immutability',
    ],
  },
);

void _expectOnlyFailure(
  List<L10nEvidenceFailure> failures,
  L10nEvidenceRejectionCode code,
  String detailCode, {
  required String stage,
  String? relativePath,
}) {
  expect(failures, hasLength(1));
  _expectFailure(
    failures,
    code,
    detailCode,
    stage: stage,
    relativePath: relativePath,
  );
}

void _expectFailure(
  List<L10nEvidenceFailure> failures,
  L10nEvidenceRejectionCode code,
  String detailCode, {
  String? stage,
  String? relativePath,
}) {
  final matches = failures.where(
    (failure) =>
        failure.code == code &&
        failure.detailCode == detailCode &&
        (stage == null || failure.stage == stage) &&
        (relativePath == null || failure.relativePath == relativePath),
  );
  expect(
    matches,
    hasLength(1),
    reason:
        '$code/$stage/$relativePath/$detailCode in '
        '${failures.map((failure) => '${failure.code.name}/'
            '${failure.stage}/${failure.relativePath}/'
            '${failure.detailCode}').join(', ')}',
  );
}

final class _VerifierFixture {
  _VerifierFixture._({
    required this.scratch,
    required this.originalProject,
    required this.flutterPackage,
    required this.toolchain,
    required this.snapshot,
    required this.materializer,
    required this.materialization,
  });

  final Directory scratch;
  final Directory originalProject;
  final Directory flutterPackage;
  final L10nToolchainResolved toolchain;
  final L10nFamilySnapshot snapshot;
  final DefaultL10nStageMaterializer materializer;
  final L10nStageMaterializationResult materialization;

  L10nStagePair get pair => materialization.pair!;

  static Future<_VerifierFixture> create({
    bool baselineRetainedEdge = false,
  }) async {
    final allocatedScratch = Directory.systemTemp.createTempSync(
      'l10n-stage-verifier-test-',
    );
    final scratch = Directory(allocatedScratch.resolveSymbolicLinksSync());
    try {
      final originalProject = Directory(p.join(scratch.path, 'live-project'))
        ..createSync(recursive: true);
      final fakeSdk = Directory(p.join(scratch.path, 'flutter-sdk'))
        ..createSync(recursive: true);
      final flutterPackage = Directory(
        p.join(fakeSdk.path, 'packages', 'flutter'),
      )..createSync(recursive: true);
      Directory(p.join(flutterPackage.path, 'lib')).createSync();
      File(
        p.join(flutterPackage.path, 'lib', 'widgets.dart'),
      ).writeAsStringSync('abstract class BuildContext {}\n');
      File(
        p.join(flutterPackage.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: flutter\n');

      final toolchain = _toolchain(fakeSdk);
      final packageConfigBytes = utf8.encode(
        jsonEncode({
          'configVersion': 2,
          'packages': [
            {
              'name': 'fixture',
              'rootUri': '../',
              'packageUri': 'lib/',
              'languageVersion': '3.9',
            },
            {
              'name': 'flutter',
              'rootUri': flutterPackage.uri.toString(),
              'packageUri': 'lib/',
              'languageVersion': '3.9',
            },
          ],
          'generator': 'pub',
          'generatorVersion': toolchain.machineIdentity.dartSdkVersion,
          'flutterRoot': fakeSdk.uri.toString(),
          'flutterVersion': '${toolchain.machineIdentity.frameworkVersion}',
        }),
      );
      _writeOriginalFixture(originalProject, packageConfigBytes);
      _makeExternalPackageReadOnly(flutterPackage);

      final project = ProjectContext(
        root: originalProject,
        pubspec: _pubspec,
        packageName: 'fixture',
        analysisMode: AnalysisMode.application,
        targetMatrix: TargetMatrix.declared([
          BuildTarget(name: 'app', platform: 'android', entrypoint: _mainPath),
        ]),
        rootCoverage: RootCoverage.applicationApi(),
      );
      final loaded = await const DefaultL10nGenerationConfigLoader().load(
        project: project,
        toolchain: toolchain.machineIdentity,
      );
      if (loaded is! L10nGenerationConfigReady) {
        throw StateError(
          'Fixture generation config was rejected: '
          '${(loaded as L10nGenerationConfigRejected).failures.map((failure) => failure.detailCode).join(',')}',
        );
      }
      final analyzerContext = const L10nAnalyzerContextAuthorityProjector()
          .project(project);
      if (analyzerContext is! L10nAnalyzerContextAuthorityProjectionReady) {
        throw StateError(
          'Fixture analyzer context was rejected: '
          '${(analyzerContext as L10nAnalyzerContextAuthorityProjectionRejected).failure.detailCode}',
        );
      }
      final packageProjection = const L10nPackageConfigProjector().project(
        sourceBytes: packageConfigBytes,
        canonicalProjectRoot: originalProject.resolveSymbolicLinksSync(),
        selectedPackageName: project.packageName,
        toolchain: toolchain,
      );
      if (packageProjection is! L10nPackageConfigProjectionReady) {
        throw StateError(
          'Fixture package projection was rejected: '
          '${(packageProjection as L10nPackageConfigProjectionRejected).failure.detailCode}',
        );
      }
      final l10nAnalysisIdentity = const L10nAnalysisFingerprintProjector()
          .project(
            analysis: _analysisFor(
              project,
              withRetainedEdge: baselineRetainedEdge,
            ),
            familyNodeIds: const {'l10n:fixture:alive', 'l10n:fixture:dead'},
          );
      final snapshot = _snapshot(
        packageConfigBytes: packageConfigBytes,
        configurationIdentity: loaded.config.configurationIdentity,
        toolchainIdentity: toolchain.identitySha256,
        analysisContextIdentity: analyzerContext.projection.identity,
        packageAuthorityIdentity:
            packageProjection.projection.authorityIdentity,
        l10nAnalysisIdentity: l10nAnalysisIdentity,
      );
      var allocation = 0;
      final materializer = DefaultL10nStageMaterializer.testing(
        expectedToolchainIdentity: toolchain.identitySha256,
        canonicalSystemTempRoot: Directory(
          Directory.systemTemp.resolveSymbolicLinksSync(),
        ),
        canonicalOriginalProjectRoot: originalProject
            .resolveSymbolicLinksSync(),
        rootAllocator: () async {
          allocation++;
          return Directory(p.join(scratch.path, 'stage-$allocation'))
            ..createSync();
        },
      );
      final materialization = await materializer.materialize(snapshot);
      if (!materialization.ready) {
        throw StateError(
          'Fixture stage was rejected: '
          '${materialization.failures.map((failure) => failure.detailCode).join(',')}',
        );
      }
      final installFailures = await materializer.installCandidateArbs(
        materialization.pair!.candidate,
        snapshot.mutationPlan.candidateArbBytes,
      );
      if (installFailures.isNotEmpty) {
        throw StateError(
          'Fixture candidate ARB install failed: '
          '${installFailures.map((failure) => failure.detailCode).join(',')}',
        );
      }
      final fixture = _VerifierFixture._(
        scratch: scratch,
        originalProject: originalProject,
        flutterPackage: flutterPackage,
        toolchain: toolchain,
        snapshot: snapshot,
        materializer: materializer,
        materialization: materialization,
      );
      fixture.writeCandidateOutput(_candidateGeneratedSource);
      return fixture;
    } catch (_) {
      if (!Platform.isWindows) {
        Process.runSync('chmod', ['-R', 'u+w', scratch.path]);
      }
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
      rethrow;
    }
  }

  DefaultL10nStageVerifier verifier({
    L10nStageAnalysisRunner? analysisRunner,
  }) => DefaultL10nStageVerifier.testing(
    inspector: const L10nGeneratedMemberInspector(),
    analysisRunner:
        analysisRunner ??
        (project, only) async {
          expect(only, const {'l10n'});
          return _analysisFor(project);
        },
  );

  Future<L10nStageVerificationResult> verifyCandidate(
    L10nStageVerifier verifier,
  ) => verifier.verify(
    stage: pair.candidate,
    snapshot: snapshot,
    expectedRemovedKeys: const {_selectedKey},
    toolchain: toolchain,
  );

  void writeCandidateArb(String source) {
    final file = File(p.join(pair.candidate.directory.path, _templatePath));
    file.writeAsStringSync(source);
    _setFileMode(file, 0x1a4);
  }

  void writeCandidateLocaleArb(String source) {
    final file = File(p.join(pair.candidate.directory.path, _localePath));
    file.writeAsStringSync(source);
    _setFileMode(file, 0x1a4);
  }

  void writeCandidateOutput(String source) {
    final file = File(p.join(pair.candidate.directory.path, _outputPath));
    file.writeAsStringSync(source);
    _setFileMode(file, 0x1a4);
  }

  void rewriteSelectedPackageRoot(String rootUri) {
    final file = File(
      p.join(
        pair.candidate.directory.path,
        '.dart_tool',
        'package_config.json',
      ),
    );
    final decoded = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
    final packages = decoded['packages']! as List<Object?>;
    final selected = packages.cast<Map<String, Object?>>().singleWhere(
      (record) => record['name'] == 'fixture',
    );
    selected['rootUri'] = rootUri;
    file.writeAsStringSync(jsonEncode(decoded));
    _setFileMode(file, 0x180);
  }

  Future<void> dispose() async {
    try {
      if (!materialization.cleanupLease.consumed) {
        await materializer.cleanup(materialization.cleanupLease);
      }
    } finally {
      if (!Platform.isWindows && scratch.existsSync()) {
        Process.runSync('chmod', ['-R', 'u+w', scratch.path]);
      }
      if (scratch.existsSync()) scratch.deleteSync(recursive: true);
    }
  }
}

void _writeOriginalFixture(Directory root, List<int> packageConfigBytes) {
  void write(String relativePath, String contents) {
    final file = File(p.join(root.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  write('pubspec.yaml', _pubspecSource);
  write('pubspec.lock', 'packages: {}\n');
  write('l10n.yaml', _l10nYamlSource);
  write(
    'analysis_options.yaml',
    'analyzer:\n  errors:\n    unused_import: warning\n',
  );
  write('flutter_pruner.yaml', 'this: [is deliberately malformed\n');
  write(_mainPath, 'void main() {}\n');
  write(_templatePath, _sourceArb);
  write(_localePath, _localeArb);
  write(_outputPath, _baselineGeneratedSource);
  final packageConfig = File(
    p.join(root.path, '.dart_tool', 'package_config.json'),
  );
  packageConfig.parent.createSync(recursive: true);
  packageConfig.writeAsBytesSync(packageConfigBytes);
}

L10nFamilySnapshot _snapshot({
  required List<int> packageConfigBytes,
  required String configurationIdentity,
  required String toolchainIdentity,
  required String analysisContextIdentity,
  required String packageAuthorityIdentity,
  required String l10nAnalysisIdentity,
}) {
  final sourceArbBytes = ImmutableBytes.copyOf(utf8.encode(_sourceArb));
  final localeArbBytes = ImmutableBytes.copyOf(utf8.encode(_localeArb));
  final parsed = ArbDocument.parse(sourceArbBytes.copy());
  final localeParsed = ArbDocument.parse(localeArbBytes.copy());
  if (parsed is! ArbParseSuccess || localeParsed is! ArbParseSuccess) {
    throw StateError('Fixture ARBs did not parse.');
  }
  final planned = L10nArbMutationPlanner.plan(
    templatePath: _templatePath,
    documentsByPath: {
      _templatePath: parsed.document,
      _localePath: localeParsed.document,
    },
    selectedKeys: const {_selectedKey},
  );
  if (planned is! L10nArbMutationPlanReady) {
    throw StateError('Fixture ARB mutation was rejected.');
  }
  final entries = <String, L10nSnapshotEntry>{
    'pubspec.yaml': _present(
      'pubspec.yaml',
      L10nSnapshotRole.pubspec,
      utf8.encode(_pubspecSource),
    ),
    'pubspec.lock': _present(
      'pubspec.lock',
      L10nSnapshotRole.lockfile,
      utf8.encode('packages: {}\n'),
    ),
    'l10n.yaml': _present(
      'l10n.yaml',
      L10nSnapshotRole.l10nConfig,
      utf8.encode(_l10nYamlSource),
    ),
    '.dart_tool/package_config.json': _present(
      '.dart_tool/package_config.json',
      L10nSnapshotRole.packageConfig,
      packageConfigBytes,
      mode: _mode(0x180),
    ),
    '.dart_tool/package_graph.json': _absent(
      '.dart_tool/package_graph.json',
      L10nSnapshotRole.packageGraph,
    ),
    'analysis_options.yaml': _present(
      'analysis_options.yaml',
      L10nSnapshotRole.verificationInput,
      utf8.encode('analyzer:\n  errors:\n    unused_import: warning\n'),
    ),
    'dart_test.yaml': _absent(
      'dart_test.yaml',
      L10nSnapshotRole.verificationInput,
    ),
    'flutter_pruner.yaml': _present(
      'flutter_pruner.yaml',
      L10nSnapshotRole.verificationInput,
      utf8.encode('this: [is deliberately malformed\n'),
    ),
    _mainPath: _present(
      _mainPath,
      L10nSnapshotRole.analyzerSource,
      utf8.encode('void main() {}\n'),
    ),
    _templatePath: _present(
      _templatePath,
      L10nSnapshotRole.arbTemplate,
      sourceArbBytes.copy(),
    ),
    _localePath: _present(
      _localePath,
      L10nSnapshotRole.arbLocale,
      localeArbBytes.copy(),
    ),
    _outputPath: _present(
      _outputPath,
      L10nSnapshotRole.generatedBase,
      utf8.encode(_baselineGeneratedSource),
    ),
  };
  return L10nFamilySnapshot(
    entries: entries,
    mutationPlan: planned.plan,
    selectedNodeIds: const {'l10n:fixture:dead'},
    selectedKeys: const {_selectedKey},
    expectedGeneratedMemberKindsByKey: const {
      'alive': ArbGeneratedMemberKind.getter,
      'dead': ArbGeneratedMemberKind.getter,
    },
    expectedGeneratedPaths: const {_outputPath},
    optionalUntranslatedPath: null,
    verificationClosure: L10nVerificationClosure(
      projectOwnedDartPaths: const {_mainPath, _outputPath},
      analyzerRootIdentity: _hash('analyzer-root'),
    ),
    analysisOptionsProjection: L10nAnalysisOptionsProjection(
      projectOwnedPaths: const {'analysis_options.yaml'},
      externalAuthorities: const [],
      contextAuthorityIdentity: analysisContextIdentity,
    ),
    provenUnrelatedOutputSiblings: const {},
    familyFingerprint: _hash('family'),
    selectionFingerprint: _hash('selection'),
    l10nAnalysisFingerprint: l10nAnalysisIdentity,
    configurationIdentity: configurationIdentity,
    packageConfigProjectionIdentity: packageAuthorityIdentity,
    packageResolutionIdentity: _hash('package-resolution'),
    toolchainIdentity: toolchainIdentity,
    projectSemantics: L10nProjectSemantics(
      pubspec: _pubspec,
      packageName: 'fixture',
      analysisMode: AnalysisMode.application,
      targetMatrix: TargetMatrix.declared([
        BuildTarget(name: 'app', platform: 'android', entrypoint: _mainPath),
      ]),
      rootCoverage: RootCoverage.applicationApi(),
    ),
  );
}

L10nSnapshotEntry _present(
  String path,
  L10nSnapshotRole role,
  List<int> bytes, {
  int? mode,
}) {
  final immutable = ImmutableBytes.copyOf(bytes);
  return L10nSnapshotEntry(
    relativePosixPath: path,
    role: role,
    state: L10nSnapshotPresent(
      sourceBytes: immutable,
      stageBytes: immutable,
      sourceSha256: immutable.sha256Hex,
      posixMode: mode ?? _mode(0x1a4),
    ),
  );
}

L10nSnapshotEntry _absent(String path, L10nSnapshotRole role) =>
    L10nSnapshotEntry(
      relativePosixPath: path,
      role: role,
      state: const L10nSnapshotAbsent(),
    );

AnalysisSnapshot _analysisFor(
  ProjectContext project, {
  bool withDanglingEdge = false,
  bool withFamilyBlocker = false,
  bool withBroadFamilyBlocker = false,
  bool withRetainedEdge = false,
}) {
  final graph = ReachabilityGraph();
  final arbFile = File(p.join(project.root.path, _templatePath));
  final decoded =
      jsonDecode(arbFile.readAsStringSync()) as Map<String, Object?>;
  final messageKeys = decoded.keys.where((key) => !key.startsWith('@')).toList()
    ..sort();
  for (final key in messageKeys) {
    graph.addNode(
      GraphNode(
        id: 'l10n:fixture:$key',
        kind: NodeKind.localizationKey,
        origin: arbFile.uri,
        displayName: key,
        metadata: {
          'key': key,
          'memberKind': ArbGeneratedMemberKind.getter.name,
        },
      ),
      producer: 'l10n',
    );
  }
  if (withRetainedEdge) {
    const consumerId = 'dart:fixture/lib/main.dart#consumer';
    graph.addNode(
      GraphNode(
        id: consumerId,
        kind: NodeKind.declaration,
        origin: File(p.join(project.root.path, _mainPath)).uri,
        displayName: 'consumer',
      ),
      producer: 'dart',
    );
    graph.addEdge(
      GraphEdge(
        from: consumerId,
        to: 'l10n:fixture:alive',
        kind: EdgeKind.references,
        evidence: const Evidence(
          kind: EvidenceKind.generatedAccessor,
          producer: 'l10n',
          description: 'retained generated accessor reference',
          exact: true,
        ),
      ),
    );
  }
  if (withDanglingEdge) {
    graph.addEdge(
      GraphEdge(
        from: 'dart:fixture/lib/missing.dart#missing',
        to: 'l10n:fixture:alive',
        kind: EdgeKind.references,
        evidence: const Evidence(
          kind: EvidenceKind.generatedAccessor,
          producer: 'l10n',
          description: 'deliberately dangling staged reference',
          exact: true,
        ),
      ),
    );
  }
  if (withFamilyBlocker) {
    graph.addBlocker(
      Blocker(
        producer: 'l10n',
        reason: 'deliberately new staged family blocker',
        affectedNamespace: 'l10n:fixture:',
      ),
    );
  }
  if (withBroadFamilyBlocker) {
    graph.addBlocker(
      Blocker(
        producer: 'l10n',
        reason: 'deliberately broad l10n blocker',
        affectedNamespace: 'l10n:',
      ),
    );
  }
  return AnalysisSnapshot(
    project: project,
    graph: graph,
    graphIntegrity: graph.integrityFor(project.targets),
    findings: const [],
    adapterIds: const ['dart', 'l10n'],
    adapterRuns: const [],
    elapsedMicros: 1,
    exclusions: project.pathPolicy.snapshot(),
  );
}

L10nToolchainResolved _toolchain(
  Directory sdk, {
  String identitySha256 = _identity,
}) => L10nToolchainResolved(
  canonicalFlutterExecutable: p.join(sdk.path, 'bin', 'flutter'),
  canonicalSdkRoot: sdk.resolveSymbolicLinksSync(),
  launch: L10nToolchainLaunch(
    canonicalDartExecutable: p.join(
      sdk.path,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      'dart',
    ),
    canonicalFlutterToolsPackageConfig: p.join(
      sdk.path,
      'packages',
      'flutter_tools',
      '.dart_tool',
      'package_config.json',
    ),
    canonicalFlutterToolsSnapshot: p.join(
      sdk.path,
      'bin',
      'cache',
      'flutter_tools.snapshot',
    ),
  ),
  selection: const ProjectSelectorSelection(),
  generationArgs: const ['gen-l10n'],
  directProbeArgs: const ['--version', '--machine'],
  environmentOverrides: const {},
  selectorHashesByRelativePath: const {},
  machineIdentity: FlutterMachineIdentity(
    frameworkVersion: Version(3, 41, 5),
    frameworkRevision: '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
    engineRevision: '4141414141414141414141414141414141414141',
    dartSdkVersion: '3.11.3',
  ),
  originalSelectionProbeSha256: _identity,
  identitySha256: identitySha256,
);

void _makeExternalPackageReadOnly(Directory package) {
  if (Platform.isWindows) return;
  Process.runSync('chmod', ['0444', p.join(package.path, 'pubspec.yaml')]);
  Process.runSync('chmod', ['0555', p.join(package.path, 'lib')]);
  Process.runSync('chmod', ['0555', package.path]);
}

void _setFileMode(File file, int mode) {
  if (Platform.isWindows) return;
  final result = Process.runSync('chmod', [
    mode.toRadixString(8).padLeft(4, '0'),
    file.path,
  ]);
  if (result.exitCode != 0) {
    throw StateError('Could not set fixture mode for ${file.path}.');
  }
}

void _replaceDirectoryWithCopy(Directory root) {
  final rootMode = root.statSync().mode & 0xfff;
  final backup = Directory('${root.path}-replaced');
  root.renameSync(backup.path);
  root.createSync();
  final entities = backup.listSync(recursive: true, followLinks: false)
    ..sort((left, right) => left.path.length.compareTo(right.path.length));
  for (final entity in entities) {
    final relative = p.relative(entity.path, from: backup.path);
    final destination = p.join(root.path, relative);
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      Directory(destination).createSync(recursive: true);
      Process.runSync('chmod', [
        (entity.statSync().mode & 0xfff).toRadixString(8).padLeft(4, '0'),
        destination,
      ]);
    } else if (type == FileSystemEntityType.file) {
      final source = File(entity.path);
      final file = File(destination);
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(source.readAsBytesSync());
      _setFileMode(file, source.statSync().mode & 0xfff);
    } else {
      throw StateError('Unexpected fixture entity: ${entity.path}');
    }
  }
  Process.runSync('chmod', [
    rootMode.toRadixString(8).padLeft(4, '0'),
    root.path,
  ]);
}

int? _mode(int value) => Platform.isWindows ? null : value;

String _hash(String value) => sha256.convert(utf8.encode(value)).toString();

String _generatedSource(String members) =>
    '''
class BuildContext {}

abstract class AppLocalizations {
  static AppLocalizations? of(BuildContext context) => null;
$members}
''';

const _sourceArb =
    '{"@@locale":"en","alive":"Alive","dead":"Dead",'
    '"@dead":{"description":"Remove exactly"}}\n';

const _localeArb = '{"@@locale":"vi","alive":"Song","dead":"Chet"}\n';

final _baselineGeneratedSource = _generatedSource('''
  String get alive;
  String get dead;
''');

final _candidateGeneratedSource = _generatedSource('''
  String get alive;
''');

const _pubspecSource = '''
name: fixture
environment:
  sdk: ">=3.9.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''';

const Map<String, Object?> _pubspec = {
  'name': 'fixture',
  'environment': {'sdk': '>=3.9.0 <4.0.0'},
  'dependencies': {
    'flutter': {'sdk': 'flutter'},
  },
  'flutter': {'generate': true},
};

const _l10nYamlSource = '''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-dir: lib/generated
output-localization-file: app.dart
output-class: AppLocalizations
nullable-getter: true
synthetic-package: false
format: false
''';
