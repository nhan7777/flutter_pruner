import 'dart:convert';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_arb_mutation_planner.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:test/test.dart';

void main() {
  group('L10nArbMutationPlanner golden edits', () {
    final cases =
        <
          ({
            String name,
            String source,
            List<String> selectedKeys,
            String expected,
          })
        >[
          (
            name: 'first member',
            source: '{"a":1, "b":2, "c":3}',
            selectedKeys: const ['a'],
            expected: '{ "b":2, "c":3}',
          ),
          (
            name: 'middle member',
            source: '{"a":1, "b":2, "c":3}',
            selectedKeys: const ['b'],
            expected: '{"a":1,  "c":3}',
          ),
          (
            name: 'final member',
            source: '{"a":1, "b":2, "c":3}',
            selectedKeys: const ['c'],
            expected: '{"a":1, "b":2 }',
          ),
          (
            name: 'only member',
            source: '{"a":1}',
            selectedKeys: const ['a'],
            expected: '{}',
          ),
          (
            name: 'all members',
            source: '{ "a":1, "b":2, "c":3 }',
            selectedKeys: const ['a', 'b', 'c'],
            expected: '{    }',
          ),
          (
            name: 'adjacent run',
            source: '{"a":1, "b":2, "c":3, "d":4}',
            selectedKeys: const ['b', 'c'],
            expected: '{"a":1,   "d":4}',
          ),
          (
            name: 'non-adjacent runs',
            source: '{"a":1, "b":2, "c":3, "d":4}',
            selectedKeys: const ['a', 'c'],
            expected: '{ "b":2,  "d":4}',
          ),
        ];

    for (final testCase in cases) {
      test('removes ${testCase.name} against original byte spans', () {
        const path = 'lib/l10n/app_en.arb';
        final original = utf8.encode(testCase.source);

        final plan = _expectReady(
          templatePath: path,
          sourcesByPath: {path: original},
          selectedKeys: testCase.selectedKeys,
        );

        expect(
          utf8.decode(plan.candidateArbBytes[path]!.copy()),
          testCase.expected,
        );
        final removals = plan.removalsByPath[path]!;
        expect(
          removals.map((removal) => removal.decodedKey),
          testCase.selectedKeys,
        );
        for (final removal in removals) {
          final token = utf8.decode(
            original.sublist(removal.span.start, removal.span.endExclusive),
          );
          expect(jsonDecode('{$token}'), contains(removal.decodedKey));
        }
        expect(
          ArbDocument.parse(plan.candidateArbBytes[path]!.copy()),
          isA<ArbParseSuccess>(),
        );
      });
    }

    test('removes adjacent message and companion members', () {
      const path = 'lib/l10n/app_en.arb';
      const source =
          '{"keep":"K", "gone":"G", "@gone":{"description":"D"}, '
          '"tail":"T"}';

      final plan = _expectReady(
        templatePath: path,
        sourcesByPath: {path: utf8.encode(source)},
        selectedKeys: const ['gone'],
      );

      expect(
        utf8.decode(plan.candidateArbBytes[path]!.copy()),
        '{"keep":"K",   "tail":"T"}',
      );
      expect(plan.removalsByPath[path]!.map((removal) => removal.decodedKey), [
        'gone',
        '@gone',
      ]);
    });

    test('removes separated message and companion members', () {
      const path = 'lib/l10n/app_en.arb';
      const source =
          '{"gone":"G", "keep":"K", "@gone":{"description":"D"}, '
          '"tail":"T"}';

      final plan = _expectReady(
        templatePath: path,
        sourcesByPath: {path: utf8.encode(source)},
        selectedKeys: const ['gone'],
      );

      expect(
        utf8.decode(plan.candidateArbBytes[path]!.copy()),
        '{ "keep":"K",  "tail":"T"}',
      );
      expect(plan.removalsByPath[path]!.map((removal) => removal.decodedKey), [
        'gone',
        '@gone',
      ]);
    });

    test('accepts a locale that omits the selected message', () {
      const templatePath = 'lib/l10n/app_en.arb';
      const localePath = 'lib/l10n/app_vi.arb';
      const localeSource = '{"@@locale":"vi", "keep":"Giữ"}\n';

      final plan = _expectReady(
        templatePath: templatePath,
        sourcesByPath: {
          templatePath: utf8.encode(
            '{"@@locale":"en", "gone":"Gone", "keep":"Keep"}\n',
          ),
          localePath: utf8.encode(localeSource),
        },
        selectedKeys: const ['gone'],
      );

      expect(
        utf8.decode(plan.candidateArbBytes[localePath]!.copy()),
        localeSource,
      );
      expect(plan.removalsByPath[localePath], isEmpty);
    });

    test(
      'preserves UTF-8 BOM, CRLF, braces, whitespace, and final newline',
      () {
        const path = 'lib/l10n/app_en.arb';
        final source = <int>[
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode(
            '{\r\n  "@@locale": "en",\r\n  "gone": "Gone",\r\n'
            '  "@gone": {"description": "D"}\r\n}\r\n',
          ),
        ];

        final plan = _expectReady(
          templatePath: path,
          sourcesByPath: {path: source},
          selectedKeys: const ['gone'],
        );

        expect(plan.candidateArbBytes[path]!.copy(), [
          0xef,
          0xbb,
          0xbf,
          ...utf8.encode('{\r\n  "@@locale": "en"\r\n  \r\n  \r\n}\r\n'),
        ]);
      },
    );

    test(
      'preserves unrelated message metadata and @ or @@ members exactly',
      () {
        const path = 'lib/l10n/app_en.arb';
        const source =
            '{"@@locale":"en","@@context":"mobile","gone":"Gone",'
            '"@gone":{"description":"Remove"},"keep":"Keep",'
            '"@keep":{"description":"Keep exactly"}}';
        const expected =
            '{"@@locale":"en","@@context":"mobile",'
            '"keep":"Keep","@keep":{"description":"Keep exactly"}}';

        final plan = _expectReady(
          templatePath: path,
          sourcesByPath: {path: utf8.encode(source)},
          selectedKeys: const ['gone'],
        );

        expect(utf8.decode(plan.candidateArbBytes[path]!.copy()), expected);
        final original = _parse(source);
        final candidate = _parse(expected);
        for (final key in ['@@locale', '@@context', 'keep', '@keep']) {
          expect(
            _memberToken(candidate, key),
            _memberToken(original, key),
            reason: '$key must remain byte exact',
          );
        }
      },
    );

    test(
      'removes ICU plural and placeholder metadata but preserves select',
      () {
        const path = 'lib/l10n/app_en.arb';
        const source =
            '{"cart":"{count, plural, =0 {Empty} one {1 item} other '
            '{{count} items}}","@cart":{"placeholders":{"count":'
            '{"type":"int"}}},"status":"{gender, select, male {His} '
            'female {Her} other {Their}}","@status":{"placeholders":'
            '{"gender":{"type":"String"}}}}';

        final plan = _expectReady(
          templatePath: path,
          sourcesByPath: {path: utf8.encode(source)},
          selectedKeys: const ['cart'],
        );

        final candidate = _parseBytes(plan.candidateArbBytes[path]!.copy());
        expect(candidate.member('cart'), isNull);
        expect(candidate.member('@cart'), isNull);
        expect(
          candidate.member('status')!.decodedValue,
          '{gender, select, male {His} female {Her} other {Their}}',
        );
        expect(candidate.member('@status')!.decodedValue, {
          'placeholders': {
            'gender': {'type': 'String'},
          },
        });
        final original = _parse(source);
        expect(
          _memberToken(candidate, 'status'),
          _memberToken(original, 'status'),
        );
        expect(
          _memberToken(candidate, '@status'),
          _memberToken(original, '@status'),
        );
      },
    );
  });

  group('L10nArbMutationPlanner whole-family rejection', () {
    test('rejects an empty selected-key iterable', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"a":1}')},
        selectedKeys: const [],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.invalidSelection,
        detailCode: 'selection-empty',
      );
    });

    test('rejects an empty decoded key', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"a":1}')},
        selectedKeys: const [''],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.invalidSelection,
        detailCode: 'selection-key-empty',
      );
    });

    test('rejects duplicate decoded keys before set freezing', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"a":1}')},
        selectedKeys: const ['a', 'a'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.invalidSelection,
        detailCode: 'selection-key-duplicate',
      );
    });

    test('rejects pseudo-key selection', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {
          'app_en.arb': _parse(
            '{"a":1,"@a":{"description":"A"},"@@locale":"en"}',
          ),
        },
        selectedKeys: const ['@a'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.invalidSelection,
        detailCode: 'selection-key-pseudo',
      );
    });

    test('rejects a selected message missing from the template', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"keep":1}')},
        selectedKeys: const ['missing'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.invalidSelection,
        detailCode: 'selected-template-message-missing',
        relativePath: 'app_en.arb',
      );
    });

    test('rejects orphan metadata in any family document atomically', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {
          'app_en.arb': _parse('{"gone":"Gone"}'),
          'app_vi.arb': _parse(
            '{"@@locale":"vi","@orphan":{"description":"No owner"}}',
          ),
        },
        selectedKeys: const ['gone'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.arbFamilyIncomplete,
        detailCode: 'orphan-message-metadata',
        relativePath: 'app_vi.arb',
      );
    });

    test('rejects locale-only messages atomically', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {
          'app_en.arb': _parse('{"gone":"Gone","keep":"Keep"}'),
          'app_vi.arb': _parse(
            '{"gone":"Mất","keep":"Giữ","localeOnly":"Thêm"}',
          ),
        },
        selectedKeys: const ['gone'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.arbFamilyIncomplete,
        detailCode: 'locale-only-message',
        relativePath: 'app_vi.arb',
      );
    });

    test('rejects ambiguous locale identity atomically', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {
          'app_en.arb': _parse('{"@@locale":"en","gone":"Gone"}'),
          'app_vi.arb': _parse('{"@@locale":42,"gone":"Mất"}'),
        },
        selectedKeys: const ['gone'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.arbFamilyIncomplete,
        detailCode: 'locale-identity-ambiguous',
        relativePath: 'app_vi.arb',
      );
    });

    test('rejects when the template document is absent from the family', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_vi.arb': _parse('{"gone":"Mất"}')},
        selectedKeys: const ['gone'],
      );

      _expectFailure(
        result,
        code: L10nEvidenceRejectionCode.arbFamilyIncomplete,
        detailCode: 'template-document-missing',
        relativePath: 'app_en.arb',
      );
    });
  });

  group('L10nArbMutationPlan determinism and immutability', () {
    test('freezes a one-shot ordered selection exactly once', () {
      final plan = _expectReadyDocuments(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"a":1,"b":2,"keep":3}')},
        selectedKeys: _SinglePassIterable(['a', 'b']),
      );

      expect(
        plan.removalsByPath['app_en.arb']!.map((removal) => removal.decodedKey),
        ['a', 'b'],
      );
    });

    test('returns sorted immutable maps, lists, and defensive byte values', () {
      final plan = _expectReady(
        templatePath: 'z/app_en.arb',
        sourcesByPath: {
          'z/app_vi.arb': utf8.encode('{"@@locale":"vi","keep":"Giữ"}'),
          'z/app_en.arb': utf8.encode(
            '{"@@locale":"en","gone":"Gone","keep":"Keep"}',
          ),
        },
        selectedKeys: const ['gone'],
      );

      expect(plan.candidateArbBytes.keys, ['z/app_en.arb', 'z/app_vi.arb']);
      expect(plan.removalsByPath.keys, ['z/app_en.arb', 'z/app_vi.arb']);
      expect(() => plan.candidateArbBytes.clear(), throwsUnsupportedError);
      expect(() => plan.removalsByPath.clear(), throwsUnsupportedError);
      expect(
        () => plan.removalsByPath['z/app_en.arb']!.clear(),
        throwsUnsupportedError,
      );

      final returned = plan.candidateArbBytes['z/app_en.arb']!.copy();
      returned.fillRange(0, returned.length, 0);
      expect(
        plan.candidateArbBytes['z/app_en.arb']!.copy(),
        isNot(equals(returned)),
      );
      expect(
        ArbDocument.parse(plan.candidateArbBytes['z/app_en.arb']!.copy()),
        isA<ArbParseSuccess>(),
      );
    });

    test('fingerprint is deterministic across map and selection ordering', () {
      final documentsA = {
        'b.arb': _parse('{"a":"B","b":"B2","keep":"K"}'),
        'a.arb': _parse('{"a":"A","b":"A2","keep":"K"}'),
      };
      final documentsB = {
        'a.arb': documentsA['a.arb']!,
        'b.arb': documentsA['b.arb']!,
      };

      final first = _expectReadyDocuments(
        templatePath: 'a.arb',
        documentsByPath: documentsA,
        selectedKeys: const ['a', 'b'],
      );
      final second = _expectReadyDocuments(
        templatePath: 'a.arb',
        documentsByPath: documentsB,
        selectedKeys: const ['b', 'a'],
      );
      final different = _expectReadyDocuments(
        templatePath: 'a.arb',
        documentsByPath: documentsB,
        selectedKeys: const ['a'],
      );

      expect(first.mutationFingerprint, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(second.mutationFingerprint, first.mutationFingerprint);
      expect(different.mutationFingerprint, isNot(first.mutationFingerprint));
    });

    test('returns immutable stable structured failures', () {
      final result = L10nArbMutationPlanner.plan(
        templatePath: 'app_en.arb',
        documentsByPath: {'app_en.arb': _parse('{"a":1}')},
        selectedKeys: const ['', '@a'],
      );

      expect(result, isA<L10nArbMutationPlanRejected>());
      final failures = (result as L10nArbMutationPlanRejected).failures;
      expect(failures.map((failure) => failure.detailCode), [
        'selection-key-empty',
        'selection-key-pseudo',
      ]);
      expect(
        failures.map((failure) => failure.code),
        everyElement(L10nEvidenceRejectionCode.invalidSelection),
      );
      expect(
        failures.map((failure) => failure.stage),
        everyElement('arb-mutation-planning'),
      );
      expect(() => failures.clear(), throwsUnsupportedError);
    });
  });
}

L10nArbMutationPlan _expectReady({
  required String templatePath,
  required Map<String, List<int>> sourcesByPath,
  required Iterable<String> selectedKeys,
}) => _expectReadyDocuments(
  templatePath: templatePath,
  documentsByPath: {
    for (final entry in sourcesByPath.entries)
      entry.key: _parseBytes(entry.value),
  },
  selectedKeys: selectedKeys,
);

L10nArbMutationPlan _expectReadyDocuments({
  required String templatePath,
  required Map<String, ArbDocument> documentsByPath,
  required Iterable<String> selectedKeys,
}) {
  final result = L10nArbMutationPlanner.plan(
    templatePath: templatePath,
    documentsByPath: documentsByPath,
    selectedKeys: selectedKeys,
  );
  expect(result, isA<L10nArbMutationPlanReady>());
  return (result as L10nArbMutationPlanReady).plan;
}

void _expectFailure(
  L10nArbMutationPlanResult result, {
  required L10nEvidenceRejectionCode code,
  required String detailCode,
  String? relativePath,
}) {
  expect(result, isA<L10nArbMutationPlanRejected>());
  final failures = (result as L10nArbMutationPlanRejected).failures;
  expect(failures, hasLength(1));
  expect(failures.single.code, code);
  expect(failures.single.stage, 'arb-mutation-planning');
  expect(failures.single.detailCode, detailCode);
  expect(failures.single.relativePath, relativePath);
  expect(() => failures.clear(), throwsUnsupportedError);
}

ArbDocument _parse(String source) => _parseBytes(utf8.encode(source));

ArbDocument _parseBytes(List<int> bytes) {
  final result = ArbDocument.parse(bytes);
  expect(result, isA<ArbParseSuccess>());
  return (result as ArbParseSuccess).document;
}

String _memberToken(ArbDocument document, String key) {
  final member = document.member(key)!;
  return utf8.decode(document.source.slice(member.memberSpan).copy());
}

final class _SinglePassIterable extends Iterable<String> {
  _SinglePassIterable(this.values);

  final List<String> values;
  var _iterated = false;

  @override
  Iterator<String> get iterator {
    if (_iterated) throw StateError('selection iterated more than once');
    _iterated = true;
    return values.iterator;
  }
}
