import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/adapters/adapter_report_definition.dart';
import 'package:flutter_pruner/src/apply/finding_action_builder.dart';
import 'package:flutter_pruner/src/apply/finding_selection.dart';
import 'package:flutter_pruner/src/apply/removal_planner.dart';
import 'package:flutter_pruner/src/cli/formatters/json_formatter.dart';
import 'package:flutter_pruner/src/cli/formatters/report_formatter.dart';
import 'package:flutter_pruner/src/core/confidence/classification_reason.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding.dart';
import 'package:flutter_pruner/src/core/graph/evidence.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/reporting/run_report.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'inventory binds reviewed JSON presentation values without rewriting v2',
    () {
      final inventory =
          jsonDecode(
                File(
                  'test/cli/fixtures/cli_surface_inventory.json',
                ).readAsStringSync(),
              )
              as Map<String, Object?>;
      final entries = (inventory['surfaces']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final v2 = const JsonFormatter(
        version: 2,
      ).format(_v2WireContractReport());
      final v3 = const JsonFormatter().format(_v2WireContractReport());

      for (final command in ['saved json v2 report', 'saved json v3 report']) {
        final output = switch (command) {
          'saved json v2 report' => v2,
          'saved json v3 report' => v3,
          _ => throw StateError('unreachable'),
        };
        final semanticValues = _classifyReviewedJsonSemantics(output);
        final expected = entries
            .where((entry) => entry['command'] == command)
            .map((entry) => entry['semanticPath']! as String)
            .toSet();
        _expectSemanticInventory(semanticValues, expected, command);

        final document = jsonDecode(output) as Map<String, Object?>;
        final removed = Map<String, Object?>.of(document)..remove('version');
        expect(
          () => _expectSemanticInventory(
            _classifyReviewedJsonSemantics(jsonEncode(removed)),
            expected,
            command,
          ),
          throwsA(isA<TestFailure>()),
          reason: 'the semantic classifier must reject artifact removal',
        );
        final added = Map<String, Object?>.of(document)
          ..['diagnostics'] = const [
            {'message': 'C3 reviewed semantic addition'},
          ];
        expect(
          () => _expectSemanticInventory(
            _classifyReviewedJsonSemantics(jsonEncode(added)),
            expected,
            command,
          ),
          throwsA(isA<TestFailure>()),
          reason:
              'the semantic classifier must reject additions at a reviewed path',
        );
      }
    },
  );

  test('v2 legacy wire contract matches frozen UTF-8 bytes', () {
    final rendered = utf8.encode(
      const JsonFormatter(version: 2).format(_v2WireContractReport()),
    );

    expect(rendered, _v2WireContractFixture.readAsBytesSync());
  });

  test('v2 retained fixture ignores A2 apply preview evidence', () {
    final rendered = utf8.encode(
      const JsonFormatter(
        version: 2,
      ).format(_v2WireContractReport(withApplyPreviewEvidence: true)),
    );

    expect(rendered, _v2WireContractFixture.readAsBytesSync());
  });

  test('v2 legacy wire contract retains selectors and streams identically', () {
    const formatter = JsonFormatter(version: 2);
    final rendered = formatter.format(_v2WireContractReport());
    final streamed = StringBuffer();
    formatter.writeTo(_v2WireContractReport(), streamed);

    expect(streamed.toString(), rendered);

    final fixtureBytes = _v2WireContractFixture.readAsBytesSync();
    final fixtureText = utf8.decode(fixtureBytes);
    final output = jsonDecode(fixtureText) as Map<String, Object?>;

    expect(fixtureText, contains('Unicode caf\u00e9 ✓'));
    expect(fixtureText, contains(r'\"route\"'));
    expect(fixtureText, contains(r'\\segment'));
    expect(fixtureText, contains(r'\u0001'));
    expect(fixtureText, contains(r'\n'));
    expect(fixtureText, contains(r'\t'));
    expect(fixtureText, contains('https://example.test/a/b//route'));

    expect(output['version'], 2);
    final summary = output['summary'] as Map<String, Object?>;
    expect(summary['safe'], 1);
    expect(summary['high'], 0);
    expect(summary['review'], 0);
    expect(summary['protected'], 1);
    expect(summary['totalSourceBytes'], 13);

    final coverage = output['analysisCoverage'] as Map<String, Object?>;
    expect(coverage.containsKey('analysisMode'), isFalse);
    expect(coverage['targetMatrix'], {
      'status': 'declaredPartial',
      'complete': false,
      'source': '.flutter_pruner/config.json',
      'issues': ['web target omitted'],
      'targets': [
        {
          'name': 'android-prod',
          'platform': 'android',
          'entrypoint': 'lib/main.dart',
          'flavor': 'prod',
          'dartDefines': {'API_PATH': 'https://example.test/a/b//route'},
        },
        {
          'name': 'ios-default',
          'platform': 'ios',
          'entrypoint': 'lib/main.dart',
          'dartDefines': <String, String>{},
        },
      ],
    });
    final targets =
        ((coverage['targetMatrix'] as Map<String, Object?>)['targets']
                as List<Object?>)
            .cast<Map<String, Object?>>();
    expect(targets.first['flavor'], 'prod');
    expect(targets.last.containsKey('flavor'), isFalse);
    expect(coverage['roots'], {
      'mode': 'packagePublicApi',
      'complete': false,
      'source': 'lib/public_api.dart',
      'publicEntrypoints': ['lib/public_api.dart'],
      'issues': ['external consumer path is unknown'],
    });

    final findings = (output['findings'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(findings, hasLength(2));
    final protected = findings.first;
    final safe = findings.last;
    for (final finding in findings) {
      expect(finding.containsKey('retainedIn'), isFalse);
      expect(finding.containsKey('auxiliaryRetainedIn'), isFalse);
      expect(
        (finding['predicates'] as Map<String, Object?>).containsKey(
          'notRetained',
        ),
        isFalse,
      );
    }
    expect(protected['classificationReasons'], [
      'dynamic-reference',
      'external-consumers-not-scanned',
    ]);
    expect(protected['protectionReasons'], ['public API "entry" \\ keep']);
    expect(protected['sourceBytes'], 13);
    expect(protected['proposedAction'], 'remove "legacy" \\ never');
    expect(
      protected['whyNotSafe'],
      'rule not on auto-fix allowlist; reachable in at least one target; '
      'an unresolved dynamic construct could match; node is protected; '
      'node may be part of a public API surface; edit is not reversibly '
      'invertible; analysis target/root coverage is incomplete; '
      'no supported apply action exists',
    );
    expect(
      (protected['node'] as Map<String, Object?>)['id'],
      'asset:app/assets/đặc-biệt/"quote"\\segment\u0001\n\t/slash//like',
    );
    final evidence = (protected['evidence'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(evidence, hasLength(2));
    expect(evidence.first, {
      'kind': 'configuration',
      'producer': 'asset/scanner',
      'description':
          'Unicode café ✓, quote " and backslash \\; control \u0001\n\t; https://example.test/a/b//route',
      'exact': false,
      'location': 'pubspec.yaml:12:7',
    });
    expect(evidence.last, {
      'kind': 'runtimeObservation',
      'producer': 'asset/scanner',
      'description': 'Observed without a source location',
      'exact': true,
    });
    expect(evidence.first['location'], 'pubspec.yaml:12:7');
    expect(evidence.last.containsKey('location'), isFalse);
    final blockers = (protected['blockers'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(blockers, hasLength(4));
    expect(blockers.first, {
      'producer': 'route/api',
      'reason': 'unresolved "route" \\ name',
      'location': 'lib/routes.dart:7:3',
      'sourceNodeId': 'route:app:/legacy//:id',
    });
    expect(blockers.first.containsKey('affectedNodeIds'), isFalse);
    expect(blockers[1], blockers[2]);
    expect(blockers[1], {
      'producer': 'route/api',
      'reason': 'unresolved "route" \\ name',
      'location': 'lib/routes.dart:8:3',
      'sourceNodeId': 'route:app:/legacy//:id',
      'affectedNamespace': 'assets/path//like/',
      'affectedNodeIds': ['node:a', 'node:z'],
    });
    expect(blockers.last, {
      'producer': 'route/api',
      'reason': 'unscoped blocker lacks optional locator fields',
    });
    expect(blockers.first['location'], 'lib/routes.dart:7:3');
    expect(blockers.first['sourceNodeId'], 'route:app:/legacy//:id');
    expect(blockers.last.containsKey('location'), isFalse);
    expect(blockers.last.containsKey('sourceNodeId'), isFalse);

    for (final optionalField in [
      'protectionReasons',
      'blockers',
      'evidence',
      'proposedAction',
      'sourceBytes',
      'whyNotSafe',
    ]) {
      expect(safe.containsKey(optionalField), isFalse);
    }
    expect(safe['classificationReasons'], isEmpty);
    expect(safe['confidence'], 'SAFE');
  });

  test('ReportFormatter writeTo defaults to format', () {
    final formatter = _StringOnlyFormatter();
    final sink = StringBuffer();

    formatter.writeTo(_report(), sink);

    expect(sink.toString(), 'formatted report');
    expect(formatter.formatCalls, 1);
  });

  test('v2 preflight rejects before either public path emits output', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 0,
        maxAffectedNodeIdReferences: 0,
        maxAffectedNodeIdsPerBlocker: 0,
      ),
    );
    final report = _report(
      blockers: [Blocker(producer: 'adapter', reason: 'not admitted')],
    );
    final sink = _ChunkObservingSink();

    expect(
      () => formatter.format(report),
      throwsA(isA<JsonV2CompatibilityLimitException>()),
    );
    expect(
      () => formatter.writeTo(report, sink),
      throwsA(isA<JsonV2CompatibilityLimitException>()),
    );
    expect(sink.chunks, isEmpty);
  });

  test('v2 writeTo streams compact token-sized chunks', () {
    const formatter = JsonFormatter(version: 2);
    final sink = _ChunkObservingSink();
    final expected = utf8.decode(_v2WireContractFixture.readAsBytesSync());

    formatter.writeTo(_v2WireContractReport(), sink);

    expect(sink.toString(), expected);
    expect(
      sink.chunks.every((chunk) => chunk.length < expected.length),
      isTrue,
      reason:
          'This checks write routing/shape, not heap allocation: no sink write '
          'may contain the complete report-sized payload.',
    );
  });

  test(
    'v2 preflight returns the complete repeated compatibility projection',
    () {
      final repeated = Blocker(
        producer: 'adapter',
        reason: 'dynamic lookup',
        affectedNodeIds: {'node:one', 'node:two'},
      );
      final formatter = JsonFormatter(
        version: 2,
        v2Limits: JsonV2SerializationLimits(
          maxBlockerReferences: 2,
          maxAffectedNodeIdReferences: 4,
          maxAffectedNodeIdsPerBlocker: 2,
        ),
      );

      final size = formatter.preflight(_report(blockers: [repeated, repeated]));

      expect(size, isNotNull);
      expect(size!.blockerReferences, 2);
      expect(size.affectedNodeIdReferences, 4);
      expect(size.largestAffectedNodeIdsPerBlocker, 2);
    },
  );

  test('v2 preflight accepts zero occurrences at zero limits', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 0,
        maxAffectedNodeIdReferences: 0,
        maxAffectedNodeIdsPerBlocker: 0,
      ),
    );

    final size = formatter.preflight(_report(zeroFindings: true));

    expect(size, isNotNull);
    expect(size!.blockerReferences, 0);
    expect(size.affectedNodeIdReferences, 0);
    expect(size.largestAffectedNodeIdsPerBlocker, 0);
  });

  test('v2 preflight rejects the first blocker reference beyond its limit', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 1,
        maxAffectedNodeIdReferences: 10,
        maxAffectedNodeIdsPerBlocker: 10,
      ),
    );

    expect(
      () => formatter.preflight(
        _report(
          blockers: [
            Blocker(producer: 'adapter', reason: 'first'),
            Blocker(producer: 'adapter', reason: 'one too many'),
          ],
        ),
      ),
      throwsA(
        isA<JsonV2CompatibilityLimitException>()
            .having(
              (error) => error.limitName,
              'limitName',
              'maxBlockerReferences',
            )
            .having((error) => error.limit, 'limit', 1)
            .having((error) => error.observed, 'observed', 2),
      ),
    );
  });

  test('v2 preflight rejects the first expanded ID beyond its limit', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 10,
        maxAffectedNodeIdReferences: 2,
        maxAffectedNodeIdsPerBlocker: 10,
      ),
    );

    expect(
      () => formatter.preflight(
        _report(
          blockers: [
            Blocker(
              producer: 'adapter',
              reason: 'one too many IDs',
              affectedNodeIds: {'node:one', 'node:two', 'node:three'},
            ),
          ],
        ),
      ),
      throwsA(
        isA<JsonV2CompatibilityLimitException>()
            .having(
              (error) => error.limitName,
              'limitName',
              'maxAffectedNodeIdReferences',
            )
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observed, 'observed', 3),
      ),
    );
  });

  test('v2 preflight rejects an oversized blocker before ID expansion', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 10,
        maxAffectedNodeIdReferences: 10,
        maxAffectedNodeIdsPerBlocker: 2,
      ),
    );

    expect(
      () => formatter.preflight(
        _report(
          blockers: [
            Blocker(
              producer: 'adapter',
              reason: 'oversized',
              affectedNodeIds: {'node:one', 'node:two', 'node:three'},
            ),
          ],
        ),
      ),
      throwsA(
        isA<JsonV2CompatibilityLimitException>()
            .having(
              (error) => error.limitName,
              'limitName',
              'maxAffectedNodeIdsPerBlocker',
            )
            .having((error) => error.limit, 'limit', 2)
            .having((error) => error.observed, 'observed', 3),
      ),
    );
  });

  test('v2 preflight stops at the first violating occurrence', () {
    final formatter = JsonFormatter(
      version: 2,
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 1,
        maxAffectedNodeIdReferences: 100,
        maxAffectedNodeIdsPerBlocker: 100,
      ),
    );

    expect(
      () => formatter.preflight(
        _report(
          blockers: [
            Blocker(producer: 'adapter', reason: 'first'),
            Blocker(producer: 'adapter', reason: 'violating occurrence'),
            Blocker(
              producer: 'adapter',
              reason: 'later fan-out',
              affectedNodeIds: {'node:one', 'node:two', 'node:three'},
            ),
          ],
        ),
      ),
      throwsA(
        isA<JsonV2CompatibilityLimitException>().having(
          (error) => error.observed,
          'observed',
          2,
        ),
      ),
    );
  });

  test(
    'v2 preflight exception text exposes only limit counts and v3 guidance',
    () {
      final formatter = JsonFormatter(
        version: 2,
        v2Limits: JsonV2SerializationLimits(
          maxBlockerReferences: 10,
          maxAffectedNodeIdReferences: 10,
          maxAffectedNodeIdsPerBlocker: 1,
        ),
      );

      JsonV2CompatibilityLimitException? error;
      try {
        formatter.preflight(
          _report(
            blockers: [
              Blocker(
                producer: 'adapter',
                reason: 'secret/path.dart:12',
                affectedNodeIds: {'node:secret/a', 'node:secret/b'},
              ),
            ],
          ),
        );
      } on JsonV2CompatibilityLimitException catch (caught) {
        error = caught;
      }

      expect(error, isNotNull);
      final text = error.toString();
      expect(text, contains('maxAffectedNodeIdsPerBlocker'));
      expect(text, contains('2 > 1'));
      expect(text, contains('--json-version 3'));
      expect(text, isNot(contains('node:secret')));
      expect(text, isNot(contains('secret/path.dart')));
    },
  );

  test('v3 preflight is not subject to v2 compatibility limits', () {
    final formatter = JsonFormatter(
      v2Limits: JsonV2SerializationLimits(
        maxBlockerReferences: 0,
        maxAffectedNodeIdReferences: 0,
        maxAffectedNodeIdsPerBlocker: 0,
      ),
    );

    expect(
      formatter.preflight(
        _report(
          blockers: [
            Blocker(
              producer: 'adapter',
              reason: 'v3 remains unbounded',
              affectedNodeIds: {'node:one'},
            ),
          ],
        ),
      ),
      isNull,
    );
  });

  test('v2 serialization limits reject each negative input', () {
    expect(
      () => JsonV2SerializationLimits(maxBlockerReferences: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxBlockerReferences',
        ),
      ),
    );
    expect(
      () => JsonV2SerializationLimits(maxAffectedNodeIdReferences: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxAffectedNodeIdReferences',
        ),
      ),
    );
    expect(
      () => JsonV2SerializationLimits(maxAffectedNodeIdsPerBlocker: -1),
      throwsA(
        isA<ArgumentError>().having(
          (error) => error.name,
          'name',
          'maxAffectedNodeIdsPerBlocker',
        ),
      ),
    );
  });

  test('v3 separates typed measurements and duplicate details', () {
    final rendered = const JsonFormatter().format(_report());
    expect(rendered, isNot(contains('\x1B[')));
    final output = jsonDecode(rendered) as Map;

    expect(output['version'], 3);
    final coverage = output['analysisCoverage'] as Map;
    expect(coverage['analysisMode'], 'application');
    expect((coverage['roots'] as Map)['internalBoundaryComplete'], isTrue);
    expect((coverage['roots'] as Map)['externalConsumersCovered'], isTrue);
    final graph =
        (((output['execution'] as Map)['analysisPasses'] as List).single
                as Map)['graph']
            as Map;
    expect(graph['danglingEdges'], 0);
    expect(graph['danglingRoots'], 2);
    expect(
      (output['statistics'] as Map).containsKey('totalSourceBytes'),
      isFalse,
    );
    final measurements = (output['statistics'] as Map)['measurements'] as List;
    expect((measurements.single as Map)['value'], 4);
    expect((measurements.single as Map)['adapterId'], 'duplicates');
    final finding = (output['findings'] as List).single as Map;
    expect(finding['reportingAdapterId'], 'duplicates');
    expect(finding['manualRiskCodes'], isEmpty);
    expect(finding['applyEligible'], isFalse);
    expect((finding['predicates'] as Map)['notRetained'], isFalse);
    expect(finding['retainedIn'], ['alpha', 'zeta']);
    expect(finding['auxiliaryRetainedIn'], [
      'aux:runtime:callback',
      'aux:test:support',
    ]);
    expect((finding['details'] as Map)['paths'], [
      'assets/a.png',
      'assets/b.png',
    ]);
  });

  test('v3 snapshots auxiliary coverage and per-context graph integrity', () {
    final sourceTarget = BuildTarget(
      name: 'android-prod',
      platform: 'android',
      entrypoint: 'lib/main_prod.dart',
      flavor: 'prod',
      dartDefines: const {'Z_LAST': '2', 'A_FIRST': '1'},
    );
    final auxiliaryTarget = AuxiliaryExecutionTarget(
      id: 'aux:runtime:callback:android',
      domain: AuxiliaryExecutionDomain.runtime,
      environmentValues: const {'Z_LAST': '2', 'A_FIRST': '1'},
      environmentComplete: true,
      reason: 'native callback\ncontext',
      sourceConfiguredTarget: sourceTarget,
    );
    final report = _report(
      auxiliaryExecutionTargets: [auxiliaryTarget],
      auxiliaryExecutionTargetIssues: const [
        AuxiliaryExecutionTargetRegistryIssue(
          id: 'aux:runtime:conflict',
          acceptedDefinitionSha256: 'accepted',
          rejectedDefinitionSha256: 'rejected',
          reason: 'conflicting\ttarget',
        ),
      ],
      integrityByExecutionTarget: {
        auxiliaryTarget.id: ExecutionTargetIntegrityReport(
          id: auxiliaryTarget.id,
          domain: 'auxiliary',
          complete: false,
          danglingEdgeCount: 1,
          danglingRootCount: 0,
          incompleteReasons: const ['zeta reason', 'alpha\t reason'],
        ),
      },
      unattributedIntegrity: ExecutionTargetIntegrityReport(
        id: 'unattributed',
        domain: 'unattributed',
        complete: false,
        danglingEdgeCount: 0,
        danglingRootCount: 1,
      ),
    );

    final output = jsonDecode(const JsonFormatter().format(report)) as Map;
    final coverage = output['analysisCoverage'] as Map;
    expect(coverage['auxiliaryExecutionTargets'], [
      {
        'id': auxiliaryTarget.id,
        'domain': 'runtime',
        'environmentValues': {'A_FIRST': '1', 'Z_LAST': '2'},
        'environmentComplete': true,
        'reason': 'native callback context',
        'sourceConfiguredTarget': {
          'name': 'android-prod',
          'platform': 'android',
          'entrypoint': 'lib/main_prod.dart',
          'flavor': 'prod',
          'dartDefines': {'A_FIRST': '1', 'Z_LAST': '2'},
        },
      },
    ]);
    expect(coverage['auxiliaryExecutionTargetIssues'], [
      {
        'id': 'aux:runtime:conflict',
        'acceptedDefinitionSha256': 'accepted',
        'rejectedDefinitionSha256': 'rejected',
        'reason': 'conflicting target',
      },
    ]);
    final graph =
        (((output['execution'] as Map)['analysisPasses'] as List).single
                as Map)['graph']
            as Map;
    expect(graph['integrityByExecutionTarget'], {
      'app:android': {
        'id': 'app:android',
        'domain': 'configuredTarget',
        'complete': true,
        'danglingEdges': 0,
        'danglingRoots': 0,
        'incompleteReasons': <String>[],
      },
      auxiliaryTarget.id: {
        'id': auxiliaryTarget.id,
        'domain': 'auxiliary',
        'complete': false,
        'danglingEdges': 1,
        'danglingRoots': 0,
        'incompleteReasons': ['alpha reason', 'zeta reason'],
      },
      'unattributed': {
        'id': 'unattributed',
        'domain': 'unattributed',
        'complete': false,
        'danglingEdges': 0,
        'danglingRoots': 1,
        'incompleteReasons': <String>[],
      },
    });
  });

  test('v3 rejects an incomplete context inventory before writing', () {
    final report = _report(omitConfiguredIntegrity: true);
    const formatter = JsonFormatter();
    final sink = StringBuffer();

    expect(() => formatter.writeTo(report, sink), throwsStateError);
    expect(sink.toString(), isEmpty);
  });

  test('v3 rejects integrity records it cannot serialize coherently', () {
    void expectRejected(String key, ExecutionTargetIntegrityReport integrity) {
      final report = _report(integrityByExecutionTarget: {key: integrity});
      const formatter = JsonFormatter();
      expect(() => formatter.format(report), throwsStateError);
      final sink = StringBuffer();
      expect(() => formatter.writeTo(report, sink), throwsStateError);
      expect(sink.toString(), isEmpty);
    }

    expectRejected(
      'app:ios',
      ExecutionTargetIntegrityReport(
        id: 'app:ios',
        domain: 'configuredTarget',
        complete: false,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
        incompleteReasons: const ['\n\t'],
      ),
    );
    expectRejected(
      'app:ios',
      ExecutionTargetIntegrityReport(
        id: 'app:ios',
        domain: 'configuredTarget',
        complete: false,
        danglingEdgeCount: -1,
        danglingRootCount: 0,
      ),
    );
    expectRejected(
      'app:ios',
      ExecutionTargetIntegrityReport(
        id: 'app:android',
        domain: 'configuredTarget',
        complete: true,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
      ),
    );
    expectRejected(
      'app:ios',
      ExecutionTargetIntegrityReport(
        id: 'app:ios',
        domain: 'auxiliary',
        complete: true,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
      ),
    );
    expectRejected(
      'app:ios',
      ExecutionTargetIntegrityReport(
        id: 'app:ios',
        domain: 'configuredTarget',
        complete: true,
        danglingEdgeCount: 1,
        danglingRootCount: 0,
      ),
    );
    expectRejected(
      'aux:test:test/bad\n_test.dart:vm',
      ExecutionTargetIntegrityReport(
        id: 'aux:test:test/bad\n_test.dart:vm',
        domain: 'auxiliary',
        complete: true,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
      ),
    );
    expectRejected(
      'aux:runtime:aux:callback',
      ExecutionTargetIntegrityReport(
        id: 'aux:runtime:aux:callback',
        domain: 'auxiliary',
        complete: true,
        danglingEdgeCount: 0,
        danglingRootCount: 0,
      ),
    );
  });

  test('v3 accepts canonical path and hash execution-target IDs', () {
    const external = 'aux:external:lib/scan_test.dart';
    const executable =
        'aux:runtime:executable:tool/a_b.dart~0123456789abcdef:incomplete';
    const configured = 'app:android';
    final report = _report(
      auxiliaryExecutionTargets: [
        AuxiliaryExecutionTarget(
          id: external,
          domain: AuxiliaryExecutionDomain.external,
          environmentValues: const {},
          environmentComplete: false,
          reason: 'external public surface',
        ),
        AuxiliaryExecutionTarget(
          id: executable,
          domain: AuxiliaryExecutionDomain.runtime,
          environmentValues: const {},
          environmentComplete: false,
          reason: 'runtime executable',
        ),
      ],
      integrityByExecutionTarget: {
        for (final id in [external, executable, configured])
          id: ExecutionTargetIntegrityReport(
            id: id,
            domain: id.startsWith('app:') ? 'configuredTarget' : 'auxiliary',
            complete: true,
            danglingEdgeCount: 0,
            danglingRootCount: 0,
          ),
      },
    );

    final output = jsonDecode(const JsonFormatter().format(report)) as Map;
    final graph =
        (((output['execution'] as Map)['analysisPasses'] as List).single
                as Map)['graph']
            as Map;
    expect(
      (graph['integrityByExecutionTarget'] as Map).keys,
      containsAll([external, executable, configured]),
    );
  });

  test('v2 compatibility retains legacy selectors for one cycle', () {
    final output =
        jsonDecode(const JsonFormatter(version: 2).format(_report())) as Map;

    expect(output['version'], 2);
    final summary = output['summary'] as Map;
    expect(summary['safe'], 0);
    expect(summary['review'], 1);
    expect(summary['totalSourceBytes'], 4);
    expect(output.containsKey('presentation'), isFalse);
    expect(
      (output['analysisCoverage'] as Map).containsKey('analysisMode'),
      isFalse,
    );
    final finding = (output['findings'] as List).single as Map;
    expect(finding.containsKey('retainedIn'), isFalse);
    expect(finding.containsKey('auxiliaryRetainedIn'), isFalse);
    expect((finding['predicates'] as Map).containsKey('notRetained'), isFalse);
  });

  test('v3 snapshots adapter-scoped typed presentation metadata', () {
    final output =
        jsonDecode(const JsonFormatter().format(_presentationReport()))
            as Map<String, Object?>;

    final presentation = output['presentation'] as Map<String, Object?>;
    final adapters = (presentation['adapters'] as List<Object?>)
        .cast<Map<String, Object?>>();
    expect(adapters.map((adapter) => adapter['id']), ['locales', 'routes']);
    final routes = adapters.singleWhere((adapter) => adapter['id'] == 'routes');
    expect(routes['displayName'], 'Route catalog');
    expect(routes['description'], 'Route-specific report copy.');
    final routePresentation =
        (routes['findings'] as List<Object?>).single as Map<String, Object?>;
    expect(routePresentation['ruleId'], 'PRN-ROUTE-001');
    expect(routePresentation['title'], 'Unlinked destination');
    expect((routePresentation['details'] as List).single, {
      'key': 'sharedDetail',
      'label': 'Route payload bytes',
      'valueType': 'bytes',
      'description': 'Serialized route payload size.',
    });

    final findings = (output['findings'] as List<Object?>)
        .cast<Map<String, Object?>>();
    final routeFinding = findings.singleWhere(
      (finding) => finding['reportingAdapterId'] == 'routes',
    );
    final localeFinding = findings.singleWhere(
      (finding) => finding['reportingAdapterId'] == 'locales',
    );
    expect(routeFinding['details'], {'sharedDetail': 128});
    expect(localeFinding['details'], {'sharedDetail': 2});
    expect((routeFinding['measurements'] as List).single, {
      'kind': 'route-source-bytes',
      'status': 'measured',
      'unit': 'bytes',
      'value': 128,
    });
    final measurements = (output['statistics'] as Map)['measurements'] as List;
    expect((measurements.single as Map)['adapterId'], 'routes');

    final v2 =
        jsonDecode(
              const JsonFormatter(version: 2).format(_presentationReport()),
            )
            as Map;
    expect(v2.containsKey('presentation'), isFalse);
  });

  test('v3 preserves apply outcomes independently of final findings', () {
    final output =
        jsonDecode(
              const JsonFormatter().format(_report(withApplyOutcome: true)),
            )
            as Map;

    expect(output['findings'], isEmpty);
    final outcomes = (output['apply'] as Map)['findingOutcomes'] as List;
    expect((output['apply'] as Map)['authorization'], {
      'acceptedRiskCodes': ['external-consumers-not-scanned'],
      'source': 'yesFlag',
    });
    final outcome = outcomes.single as Map;
    expect(outcome['findingId'], 'duplicate:test:abc');
    expect(outcome['status'], 'blocked');
    expect(outcome['reasonCode'], 'retained_consumer');
    expect(outcome['rollbackVerified'], isNull);
    expect(outcome['relatedNodeIds'], ['consumer:a', 'consumer:z']);
    final finding = outcome['finding'] as Map;
    expect(finding['title'], 'duplicate');
    expect(((finding['node'] as Map)['projectRelativeOrigin']), 'assets/a.png');
    expect((finding['predicates'] as Map)['notRetained'], isFalse);
    expect(finding['retainedIn'], ['alpha', 'zeta']);
    expect(finding['auxiliaryRetainedIn'], [
      'aux:runtime:callback',
      'aux:test:support',
    ]);
  });

  test('v3 serializes the initial physical plan and preview projection', () {
    final output =
        jsonDecode(const JsonFormatter().format(_augmentedApplyReport()))
            as Map<String, Object?>;

    final apply = output['apply'] as Map<String, Object?>;
    expect((apply['selection'] as Map<String, Object?>), {
      'mode': 'exact',
      'requestedFindingIds': ['finding-a', 'finding-b'],
      'plannedFindingIds': ['finding-a', 'finding-b'],
      'planFingerprint': 'a' * 64,
      'actualPreviewFingerprint': _previewFingerprint,
      'expectedPreviewFingerprint': _previewFingerprint,
      'previewComparison': 'matched',
    });
    expect(apply['initialPlan'], {
      'canonicalVersion': 1,
      'scope': 'complete_exact_selection',
      'planFingerprint': 'a' * 64,
      'units': [
        {
          'order': 0,
          'id': 'unit-a',
          'findingIds': ['finding-a'],
          'dependencyUnitIds': <String>[],
          'actions': [
            {
              'order': 0,
              'logicalFindingId': 'finding-a',
              'journalFindingId': 'finding-a@cleanup',
              'operation': 'cleanupImports',
              'projectRelativePath': 'lib/importer.dart',
              'label': 'cleanup "café ✓"\n',
              'countsTowardSummary': false,
              'cleanupTargetPath': 'lib/dead.dart',
            },
          ],
        },
        {
          'order': 1,
          'id': 'unit-b',
          'findingIds': ['finding-b'],
          'dependencyUnitIds': ['unit-a'],
          'actions': [
            {
              'order': 0,
              'logicalFindingId': 'finding-b',
              'journalFindingId': 'finding-b@variant',
              'operation': 'deleteFile',
              'projectRelativePath': 'assets/dead@2x.png',
              'label': 'resolution variant assets/dead@2x.png',
              'countsTowardSummary': false,
            },
            {
              'order': 1,
              'logicalFindingId': 'finding-b',
              'journalFindingId': 'finding-b',
              'operation': 'removeFinding',
              'projectRelativePath': 'lib/dead.dart',
              'countsTowardSummary': true,
            },
            {
              'order': 2,
              'logicalFindingId': 'finding-b',
              'journalFindingId': 'finding-b@generated',
              'operation': 'deleteFile',
              'projectRelativePath': 'lib/dead.g.dart',
              'label': 'generated companion lib/dead.g.dart',
              'countsTowardSummary': false,
            },
          ],
        },
      ],
      'blocked': [
        {
          'findingId': 'finding-c',
          'reason': 'retainedConsumer',
          'blockedBy': 'dart:consumer',
        },
      ],
      'preview': {
        'version': 1,
        'fingerprint': _previewFingerprint,
        'sources': [
          {
            'projectRelativePath': 'assets/dead@2x.png',
            'canonicalPath': _canonicalChild('assets/dead@2x.png'),
            'sha256': '1' * 64,
            'sizeBytes': 3,
            'posixMode': 420,
          },
          {
            'projectRelativePath': 'lib/dead.dart',
            'canonicalPath': _canonicalChild('lib/dead.dart'),
            'sha256': '2' * 64,
            'sizeBytes': 0,
            'posixMode': null,
          },
          {
            'projectRelativePath': 'lib/dead.g.dart',
            'canonicalPath': _canonicalChild('lib/dead.g.dart'),
            'sha256': '3' * 64,
            'sizeBytes': 9,
            'posixMode': 384,
          },
          {
            'projectRelativePath': 'lib/importer.dart',
            'canonicalPath': _canonicalChild('lib/importer.dart'),
            'sha256': '4' * 64,
            'sizeBytes': 1,
            'posixMode': 420,
          },
        ],
      },
    });

    final rendered = const JsonFormatter().format(_augmentedApplyReport());
    expect(rendered, contains(r'cleanup \"café ✓\"\n'));
  });

  test('v3 retains mismatched preview expectation tokens', () {
    final output =
        jsonDecode(
              const JsonFormatter().format(
                _augmentedApplyReport(
                  expectedPreviewFingerprint: 'v1:${'b' * 64}',
                ),
              ),
            )
            as Map<String, Object?>;

    final selection =
        (output['apply'] as Map<String, Object?>)['selection']
            as Map<String, Object?>;
    expect(selection['actualPreviewFingerprint'], _previewFingerprint);
    expect(selection['expectedPreviewFingerprint'], 'v1:${'b' * 64}');
    expect(selection['previewComparison'], 'mismatched');
  });

  test('v2 ignores augmented apply preview fields byte-for-byte', () {
    const formatter = JsonFormatter(version: 2);

    expect(
      formatter.format(_augmentedApplyReport()),
      formatter.format(_plainApplyReport()),
    );
  });

  test('v3 deduplicates blocker identities and streams deterministically', () {
    final first = Blocker(
      producer: 'dart',
      reason: 'unresolved semantic reference',
      location: 'lib/example.dart',
      affectedNodeIds: {'dart:test/b', 'dart:test/a'},
    );
    final duplicate = Blocker(
      producer: 'dart',
      reason: 'unresolved semantic reference',
      location: 'lib/example.dart',
      affectedNodeIds: {'dart:test/a', 'dart:test/b'},
    );
    final report = _report(blockers: [first, first, duplicate]);
    const formatter = JsonFormatter();

    final rendered = formatter.format(report);
    final streamed = StringBuffer();
    formatter.writeTo(report, streamed);
    final output = jsonDecode(rendered) as Map;

    expect(rendered, streamed.toString());
    expect(rendered, isNot(contains('\n')));
    expect(formatter.format(report), rendered);
    expect((output['blockers'] as Map), hasLength(1));
    expect(
      ((output['findings'] as List).single as Map)['blockerIds'],
      hasLength(1),
    );
  });

  test('v3 preserves an unbound inventory blocker with zero findings', () {
    final blocker = Blocker(
      producer: 'l10n',
      reason: 'duplicate top-level ARB key prevents inventory construction',
      location: 'lib/l10n/app_en.arb:4:3',
      affectedNamespace: 'l10n:test:',
    );
    final output =
        jsonDecode(
              const JsonFormatter().format(
                _report(zeroFindings: true, recordedBlockers: [blocker]),
              ),
            )
            as Map;

    expect(output['findings'], isEmpty);
    final blockers = output['blockers'] as Map;
    expect(blockers, hasLength(1));
    expect(
      (blockers.values.single as Map)['reason'],
      'duplicate top-level ARB key prevents inventory construction',
    );
    expect((output['statistics'] as Map)['blockers'], {
      'recorded': 1,
      'activeUnique': 0,
      'unboundUnique': 1,
      'affectedFindings': 0,
      'byProducer': <String, int>{},
    });
  });
}

/// Traverses parsed JSON, rather than its source bytes, so indentation, key
/// ordering, and escaping cannot hide a presentation-contract change.
Set<String> _classifyReviewedJsonSemantics(String serialized) {
  final allValues = _extractJsonSemanticValues(serialized);
  return {
    for (final value in allValues)
      if (_isReviewedSemanticPath(value.split('=').first)) value,
  };
}

const _reviewedSemanticPathPatterns = <String>[
  r'^\$\.version$',
  r'^\$\.findings\[[0-9]+\]\.(?:title|confidence|whyNotSafe|proposedAction)$',
  r'^\$\.findings\[[0-9]+\]\.blockers\[[0-9]+\]\.reason$',
  r'^\$\.findings\[[0-9]+\]\.evidence\[[0-9]+\]\.description$',
  r'^\$\.diagnostics\[[0-9]+\]\.(?:reason|message|label|detail)$',
];

bool _isReviewedSemanticPath(String path) => _reviewedSemanticPathPatterns.any(
  (pattern) => RegExp(pattern).hasMatch(path),
);

void _expectSemanticInventory(
  Set<String> actual,
  Set<String> expected,
  String command,
) {
  expect(
    actual,
    expected,
    reason:
        '$command semantic inventory must exactly equal the independently '
        'classified reviewed path/value set',
  );
}

Set<String> _extractJsonSemanticValues(String serialized) {
  final values = <String>{};

  void visit(Object? value, String path) {
    switch (value) {
      case final Map<Object?, Object?> map:
        for (final entry in map.entries) {
          visit(entry.value, '$path.${entry.key}');
        }
      case final List<Object?> list:
        for (final (index, item) in list.indexed) {
          visit(item, '$path[$index]');
        }
      case final String string:
        values.add('$path=${jsonEncode(string)}');
      case final num number:
        values.add('$path=$number');
      case final bool boolean:
        values.add('$path=$boolean');
      case null:
        values.add('$path=null');
    }
  }

  visit(jsonDecode(serialized), r'$');
  return values;
}

final _v2WireContractFixture = File('test/fixtures/v2_json_wire_contract.json');

final class _StringOnlyFormatter extends ReportFormatter {
  var formatCalls = 0;

  @override
  String format(RunReport report) {
    formatCalls++;
    return 'formatted report';
  }
}

final class _ChunkObservingSink implements StringSink {
  final chunks = <String>[];

  @override
  void write(Object? object) {
    chunks.add(object.toString());
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    write(objects.join(separator));
  }

  @override
  void writeln([Object? object = '']) {
    write('$object\n');
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  String toString() => chunks.join();
}

RunReport _v2WireContractReport({bool withApplyPreviewEvidence = false}) {
  final emptyIds = Blocker(
    producer: 'route/api',
    reason: 'unresolved "route" \\ name',
    location: 'lib/routes.dart:7:3',
    sourceNodeId: 'route:app:/legacy//:id',
  );
  final duplicate = Blocker(
    producer: 'route/api',
    reason: 'unresolved "route" \\ name',
    location: 'lib/routes.dart:8:3',
    sourceNodeId: 'route:app:/legacy//:id',
    affectedNamespace: 'assets/path//like/',
    affectedNodeIds: {'node:z', 'node:a'},
  );
  final missingLocator = Blocker(
    producer: 'route/api',
    reason: 'unscoped blocker lacks optional locator fields',
  );
  final protected = Finding(
    ruleId: 'PRN-WIRE-001',
    node: GraphNode(
      id: 'asset:app/assets/đặc-biệt/"quote"\\segment\u0001\n\t/slash//like',
      kind: NodeKind.asset,
      origin: Uri.file('/project/assets/đặc-biệt.png'),
    ),
    confidence: Confidence.protected,
    title: 'Đường dẫn "quoted" \\control\nnext\t/end//?q=✓',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: false,
      noDynamicBlockers: false,
      notProtected: false,
      noPublicApiRisk: false,
      hasDeterministicInverse: false,
      notRetained: false,
      analysisCoverageComplete: false,
      actionSupported: false,
    ),
    evidence: const [
      Evidence(
        kind: EvidenceKind.configuration,
        producer: 'asset/scanner',
        description:
            'Unicode café ✓, quote " and backslash \\; control \u0001\n\t; https://example.test/a/b//route',
        location: 'pubspec.yaml:12:7',
      ),
      Evidence(
        kind: EvidenceKind.runtimeObservation,
        producer: 'asset/scanner',
        description: 'Observed without a source location',
        exact: true,
      ),
    ],
    blockers: [emptyIds, duplicate, duplicate, missingLocator],
    protectionReasons: const ['public API "entry" \\ keep'],
    unreachableIn: const ['android-prod'],
    reachableIn: const ['ios-staging'],
    retainedIn: const ['ios-staging'],
    auxiliaryRetainedIn: const ['aux:external:public-api'],
    proposedAction: 'remove "legacy" \\ never',
    sourceBytes: 13,
    classificationReasons: const [
      ClassificationReason.dynamicReference,
      ClassificationReason.externalConsumersNotScanned,
    ],
  );
  final safe = Finding(
    ruleId: 'PRN-WIRE-002',
    node: GraphNode(
      id: 'dart:app/lib/safe.dart#unused',
      kind: NodeKind.declaration,
      origin: Uri.file('/project/lib/safe.dart'),
    ),
    confidence: Confidence.safe,
    title: 'Unused safe declaration',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: true,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: true,
      notRetained: true,
    ),
  );
  final initialPlan = withApplyPreviewEvidence ? _initialPlanReport() : null;
  final selection = initialPlan == null
      ? null
      : ApplySelectionReport(
          mode: FindingSelectionMode.exact,
          requestedFindingIds: const ['finding-a', 'finding-b'],
          plannedFindingIds: const ['finding-a', 'finding-b'],
          planFingerprint: 'a' * 64,
          actualPreviewFingerprint: initialPlan.preview!.fingerprint,
          expectedPreviewFingerprint: initialPlan.preview!.fingerprint,
        );
  return RunReport(
    identity: RunIdentity(
      id: 'v2-wire-contract',
      command: withApplyPreviewEvidence ? RunCommand.apply : RunCommand.scan,
      toolVersion: 'legacy-v2',
      startedAtUtc: DateTime.utc(2026, 8, 20),
      finishedAtUtc: DateTime.utc(2026, 8, 20, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    canonicalProjectRoot: initialPlan?.preview?.canonicalProjectRoot,
    packageName: 'wire-contract',
    requestedAdapters: const ['assets', 'dart'],
    targetMatrix: TargetMatrix(
      status: TargetMatrixStatus.declaredPartial,
      source: '.flutter_pruner/config.json',
      issues: const ['web target omitted'],
      targets: [
        BuildTarget(
          name: 'android-prod',
          platform: 'android',
          entrypoint: 'lib/main.dart',
          flavor: 'prod',
          dartDefines: {'API_PATH': 'https://example.test/a/b//route'},
        ),
        BuildTarget(
          name: 'ios-default',
          platform: 'ios',
          entrypoint: 'lib/main.dart',
        ),
      ],
    ),
    rootCoverage: RootCoverage(
      mode: RootCoverageMode.packagePublicApi,
      source: 'lib/public_api.dart',
      internalBoundaryComplete: true,
      externalConsumersCovered: false,
      publicEntrypoints: const ['lib/public_api.dart'],
      issues: const ['external consumer path is unknown'],
    ),
    analysisPasses: const [],
    findings: [protected, safe],
    diagnostics: const [],
    applySelection: selection,
    applyInitialPlan: initialPlan,
  );
}

RunReport _report({
  bool withApplyOutcome = false,
  bool zeroFindings = false,
  List<Blocker> blockers = const [],
  List<Blocker> recordedBlockers = const [],
  List<AuxiliaryExecutionTarget> auxiliaryExecutionTargets = const [],
  List<AuxiliaryExecutionTargetRegistryIssue> auxiliaryExecutionTargetIssues =
      const [],
  Map<String, ExecutionTargetIntegrityReport> integrityByExecutionTarget =
      const {},
  bool omitConfiguredIntegrity = false,
  ExecutionTargetIntegrityReport? unattributedIntegrity,
}) {
  final finding = Finding(
    ruleId: 'PRN-DUP-001',
    node: GraphNode(
      id: 'duplicate:test:abc',
      kind: NodeKind.duplicateGroup,
      origin: Uri.file('/project/assets/a.png'),
      sizeBytes: 4,
      metadata: const {
        'paths': ['assets/b.png', 'assets/a.png'],
        'fileCount': 2,
        'sizePerFile': 4,
      },
    ),
    confidence: Confidence.review,
    title: 'duplicate',
    predicates: const SafetyPredicates(
      ruleAllowsAutoFix: false,
      unreachableAcrossAllTargets: true,
      noDynamicBlockers: true,
      notProtected: true,
      noPublicApiRisk: true,
      hasDeterministicInverse: false,
      notRetained: false,
    ),
    retainedIn: const ['zeta', 'alpha', 'zeta'],
    auxiliaryRetainedIn: const [
      'aux:test:support',
      'aux:runtime:callback',
      'aux:test:support',
    ],
    classificationReasons: const [ClassificationReason.retainedOnly],
    blockers: blockers,
    reportingAdapterId: 'duplicates',
    sourceBytes: 4,
  );
  final statistics = FindingStatistics.fromFindings(
    zeroFindings ? const [] : [finding],
  );
  final pass = AnalysisPassReport(
    id: 'analysis-001',
    purpose: AnalysisPassPurpose.initial,
    elapsedMicros: 10,
    nodeCount: 1,
    edgeCount: 0,
    rootCount: 0,
    recordedBlockerCount: recordedBlockers.length,
    danglingEdgeCount: 0,
    danglingRootCount: 2,
    integrityByExecutionTarget: {
      if (!omitConfiguredIntegrity)
        'app:android': ExecutionTargetIntegrityReport(
          id: 'app:android',
          domain: 'configuredTarget',
          complete: true,
          danglingEdgeCount: 0,
          danglingRootCount: 0,
        ),
      ...integrityByExecutionTarget,
    },
    unattributedIntegrity: unattributedIntegrity,
    auxiliaryExecutionTargets: auxiliaryExecutionTargets,
    auxiliaryExecutionTargetIssues: auxiliaryExecutionTargetIssues,
    adapterRuns: const [
      AdapterRunReport(
        id: 'duplicates',
        name: 'Duplicate detector',
        role: AdapterRunRole.reporting,
        status: AdapterRunStatus.executed,
        elapsedMicros: 10,
        nodesAdded: 1,
        edgesAdded: 0,
        blockersAdded: 0,
      ),
    ],
    findingStatistics: statistics,
    unboundBlockers: recordedBlockers,
    blockerStatistics: BlockerStatistics(
      recorded: recordedBlockers.length,
      activeUnique: 0,
      unboundUnique: zeroFindings ? recordedBlockers.length : 0,
      affectedFindings: 0,
      byProducer: {},
    ),
    measurements: const [
      RunMeasurement(
        kind: 'duplicate-potential-reclaimable-bytes',
        adapterId: 'duplicates',
        status: MeasurementStatus.measured,
        unit: 'bytes',
        scope: 'duplicate-inventory',
        aggregation: 'within-duplicate-groups-only',
        value: 4,
        knownCount: 1,
      ),
    ],
    exclusionPolicyVersion: 1,
    exclusionsByReason: const {},
  );
  return RunReport(
    identity: RunIdentity(
      id: 'run-test',
      command: withApplyOutcome ? RunCommand.apply : RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: const ['duplicates'],
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: [pass],
    findings: withApplyOutcome || zeroFindings ? const [] : [finding],
    diagnostics: const [],
    acceptedRiskCodes: withApplyOutcome
        ? const ['external-consumers-not-scanned']
        : const [],
    riskAcceptanceSource: withApplyOutcome
        ? RiskAcceptanceSource.yesFlag
        : RiskAcceptanceSource.notRequired,
    applyFindingOutcomes: withApplyOutcome
        ? [
            ApplyFindingOutcome(
              finding: finding,
              status: ApplyFindingOutcomeStatus.blocked,
              reasonCode: 'retained_consumer',
              reason: 'A retained consumer still references this finding.',
              relatedNodeIds: const ['consumer:z', 'consumer:a'],
            ),
          ]
        : const [],
    applyStatistics: withApplyOutcome
        ? const ApplyStatistics(
            rounds: 0,
            findingsCommitted: 0,
            findingsRejectedRecovered: 0,
            findingsBlocked: 1,
            findingsSkippedDependency: 0,
            findingsRemaining: 1,
            actionsDeclared: 0,
            actionsCommitted: 0,
            actionsRolledBack: 0,
            actionsFailedRecovered: 0,
            transactionsBegun: 0,
            transactionsCommitted: 0,
            transactionsRolledBackVerified: 0,
            transactionsRecoveryRequired: 0,
            transactionsNonTerminal: 0,
            verificationAttempts: 0,
            sourceBytesRemoved: 0,
          )
        : null,
  );
}

RunReport _presentationReport() {
  final route = _presentationFinding(
    id: 'routes:test:/orphan',
    adapter: 'routes',
    kind: NodeKind.route,
    sourceBytes: 128,
    metadata: const {'sharedDetail': 128, 'notPresented': 'discarded'},
  );
  final locale = _presentationFinding(
    id: 'locales:test:orphan',
    adapter: 'locales',
    kind: NodeKind.localizationKey,
    sourceBytes: 2,
    metadata: const {'sharedDetail': 2},
  );
  final statistics = FindingStatistics.fromFindings([route, locale]);
  return RunReport(
    identity: RunIdentity(
      id: 'presentation-test',
      command: RunCommand.scan,
      toolVersion: 'test',
      startedAtUtc: DateTime.utc(2026, 8, 14),
      finishedAtUtc: DateTime.utc(2026, 8, 14, 0, 0, 1),
      elapsedMicros: 1000000,
    ),
    status: RunStatus.completed,
    exitCode: 0,
    partialApplied: false,
    projectRoot: '/project',
    packageName: 'test',
    requestedAdapters: const ['routes', 'locales'],
    adapterReportDefinitions: [_localesDefinition, _routesDefinition],
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
    analysisPasses: [
      AnalysisPassReport(
        id: 'presentation-pass',
        purpose: AnalysisPassPurpose.initial,
        elapsedMicros: 1,
        nodeCount: 2,
        edgeCount: 0,
        rootCount: 0,
        recordedBlockerCount: 0,
        danglingEdgeCount: 0,
        integrityByExecutionTarget: {
          'app:android': ExecutionTargetIntegrityReport(
            id: 'app:android',
            domain: 'configuredTarget',
            complete: true,
            danglingEdgeCount: 0,
            danglingRootCount: 0,
          ),
        },
        adapterRuns: const [],
        findingStatistics: statistics,
        blockerStatistics: BlockerStatistics(
          recorded: 0,
          activeUnique: 0,
          affectedFindings: 0,
          byProducer: {},
        ),
        measurements: const [
          RunMeasurement(
            kind: 'route-source-bytes',
            adapterId: 'routes',
            status: MeasurementStatus.measured,
            unit: 'bytes',
            value: 128,
            scope: 'route-findings',
            aggregation: 'sum',
          ),
        ],
        exclusionPolicyVersion: 1,
        exclusionsByReason: const {},
      ),
    ],
    findings: [route, locale],
    diagnostics: const [],
  );
}

Finding _presentationFinding({
  required String id,
  required String adapter,
  required NodeKind kind,
  required int sourceBytes,
  required Map<String, Object?> metadata,
}) => Finding(
  ruleId: adapter == 'routes' ? 'PRN-ROUTE-001' : 'PRN-LOCALE-001',
  node: GraphNode(
    id: id,
    kind: kind,
    origin: Uri.file('/project/lib/example.dart'),
    metadata: metadata,
  ),
  confidence: Confidence.review,
  title: adapter == 'routes' ? 'Unlinked destination' : 'Orphan locale',
  predicates: const SafetyPredicates(
    ruleAllowsAutoFix: false,
    unreachableAcrossAllTargets: true,
    noDynamicBlockers: true,
    notProtected: true,
    noPublicApiRisk: true,
    hasDeterministicInverse: false,
    notRetained: true,
  ),
  reportingAdapterId: adapter,
  sourceBytes: sourceBytes,
);

final _routesDefinition = AdapterReportDefinition(
  adapterId: 'routes',
  displayName: 'Route catalog',
  description: 'Route-specific report copy.',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.route,
      ruleId: 'PRN-ROUTE-001',
      title: 'Unlinked destination',
      nodeLabel: 'Destination',
      description: 'A route with no observed navigation.',
      measurementKind: 'route-source-bytes',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Route payload bytes',
          valueType: AdapterReportDetailValueType.bytes,
          description: 'Serialized route payload size.',
        ),
      ],
    ),
  ],
  measurements: [
    AdapterReportMeasurementDefinition(
      kind: 'route-source-bytes',
      label: 'Route source bytes',
      unit: 'bytes',
    ),
  ],
);

final _localesDefinition = AdapterReportDefinition(
  adapterId: 'locales',
  displayName: 'Locale catalog',
  findings: [
    AdapterFindingReportDefinition(
      nodeKind: NodeKind.localizationKey,
      ruleId: 'PRN-LOCALE-001',
      title: 'Orphan locale',
      nodeLabel: 'Locale key',
      details: [
        AdapterReportDetailDefinition(
          key: 'sharedDetail',
          label: 'Locale plural forms',
          valueType: AdapterReportDetailValueType.integer,
        ),
      ],
    ),
  ],
);

String get _previewFingerprint => _initialPlanReport().preview!.fingerprint;

RunReport _augmentedApplyReport({String? expectedPreviewFingerprint}) {
  final initialPlan = _initialPlanReport();
  return _applyReportWith(
    selection: ApplySelectionReport(
      mode: FindingSelectionMode.exact,
      requestedFindingIds: const ['finding-a', 'finding-b'],
      plannedFindingIds: const ['finding-a', 'finding-b'],
      planFingerprint: 'a' * 64,
      actualPreviewFingerprint: initialPlan.preview!.fingerprint,
      expectedPreviewFingerprint:
          expectedPreviewFingerprint ?? initialPlan.preview!.fingerprint,
    ),
    initialPlan: initialPlan,
  );
}

RunReport _plainApplyReport() => _applyReportWith();

RunReport _applyReportWith({
  ApplySelectionReport? selection,
  ApplyInitialPlanReport? initialPlan,
}) => RunReport(
  identity: RunIdentity(
    id: 'apply-preview-report',
    command: RunCommand.apply,
    toolVersion: 'test',
    startedAtUtc: DateTime.utc(2026, 8, 25),
    finishedAtUtc: DateTime.utc(2026, 8, 25, 0, 0, 1),
    elapsedMicros: 1000000,
  ),
  status: RunStatus.dryRun,
  exitCode: 0,
  partialApplied: false,
  projectRoot: _canonicalProjectRoot,
  canonicalProjectRoot: initialPlan?.preview?.canonicalProjectRoot,
  packageName: 'test',
  requestedAdapters: const ['dart'],
  targetMatrix: TargetMatrix.declared(const []),
  rootCoverage: RootCoverage.applicationApi(),
  analysisPasses: const [],
  findings: const [],
  diagnostics: const [],
  applySelection: selection,
  applyInitialPlan: initialPlan,
  applyStatistics: ApplyStatistics.empty,
);

ApplyInitialPlanReport _initialPlanReport() => ApplyInitialPlanReport(
  canonicalVersion: 1,
  scope: ApplyInitialPlanScope.completeExactSelection,
  planFingerprint: 'a' * 64,
  units: [
    ApplyPlanUnitReport(
      order: 0,
      id: 'unit-a',
      findingIds: const ['finding-a'],
      dependencyUnitIds: const [],
      actions: [
        ApplyPlanActionReport(
          order: 0,
          logicalFindingId: 'finding-a',
          journalFindingId: 'finding-a@cleanup',
          operation: FindingActionOperation.cleanupImports,
          projectRelativePath: 'lib/importer.dart',
          label: 'cleanup "café ✓"\n',
          countsTowardSummary: false,
          cleanupTargetPath: 'lib/dead.dart',
        ),
      ],
    ),
    ApplyPlanUnitReport(
      order: 1,
      id: 'unit-b',
      findingIds: const ['finding-b'],
      dependencyUnitIds: const ['unit-a'],
      actions: [
        ApplyPlanActionReport(
          order: 0,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b@variant',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'assets/dead@2x.png',
          label: 'resolution variant assets/dead@2x.png',
          countsTowardSummary: false,
        ),
        ApplyPlanActionReport(
          order: 1,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b',
          operation: FindingActionOperation.removeFinding,
          projectRelativePath: 'lib/dead.dart',
          countsTowardSummary: true,
        ),
        ApplyPlanActionReport(
          order: 2,
          logicalFindingId: 'finding-b',
          journalFindingId: 'finding-b@generated',
          operation: FindingActionOperation.deleteFile,
          projectRelativePath: 'lib/dead.g.dart',
          label: 'generated companion lib/dead.g.dart',
          countsTowardSummary: false,
        ),
      ],
    ),
  ],
  blocked: [
    ApplyPlanBlockReport(
      findingId: 'finding-c',
      reason: PlanBlockReason.retainedConsumer,
      blockedBy: 'dart:consumer',
    ),
  ],
  preview: ApplyPreviewReport(
    version: 1,
    canonicalProjectRoot: _canonicalProjectRoot,
    planFingerprint: 'a' * 64,
    sources: [
      ApplySourceSnapshotReport(
        projectRelativePath: 'assets/dead@2x.png',
        canonicalPath: _canonicalChild('assets/dead@2x.png'),
        sha256: '1' * 64,
        sizeBytes: 3,
        posixMode: 420,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/dead.dart',
        canonicalPath: _canonicalChild('lib/dead.dart'),
        sha256: '2' * 64,
        sizeBytes: 0,
        posixMode: null,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/dead.g.dart',
        canonicalPath: _canonicalChild('lib/dead.g.dart'),
        sha256: '3' * 64,
        sizeBytes: 9,
        posixMode: 384,
      ),
      ApplySourceSnapshotReport(
        projectRelativePath: 'lib/importer.dart',
        canonicalPath: _canonicalChild('lib/importer.dart'),
        sha256: '4' * 64,
        sizeBytes: 1,
        posixMode: 420,
      ),
    ],
  ),
);

String get _canonicalProjectRoot => Platform.isWindows
    ? p.windows.normalize(r'C:\project')
    : p.posix.normalize('/project');

String _canonicalChild(String relativePath) {
  final context = Platform.isWindows ? p.windows : p.posix;
  return context.joinAll(<String>[
    _canonicalProjectRoot,
    ...p.posix.split(relativePath),
  ]);
}
