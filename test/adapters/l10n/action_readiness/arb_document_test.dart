import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/arb_document.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/immutable_bytes.dart';
import 'package:test/test.dart';

void main() {
  group('ArbDocument.parse valid inputs', () {
    final cases =
        <
          ({
            String name,
            List<int> bytes,
            List<_ExpectedMember> members,
            List<_ExpectedDelimiter> delimiters,
          })
        >[
          (
            name: 'compact JSON has exact token spans',
            bytes: utf8.encode('{"hello":"Hello"}'),
            members: const [
              _ExpectedMember(
                key: 'hello',
                keySpan: (1, 8),
                valueSpan: (9, 16),
                memberSpan: (1, 16),
                value: 'Hello',
              ),
            ],
            delimiters: const [],
          ),
          (
            name: 'pretty CRLF JSON keeps whitespace outside ownership',
            bytes: utf8.encode('{\r\n  "a": "A",\r\n  "b": "B"\r\n}\r\n'),
            members: const [
              _ExpectedMember(
                key: 'a',
                keySpan: (5, 8),
                valueSpan: (10, 13),
                memberSpan: (5, 13),
                value: 'A',
              ),
              _ExpectedMember(
                key: 'b',
                keySpan: (18, 21),
                valueSpan: (23, 26),
                memberSpan: (18, 26),
                value: 'B',
              ),
            ],
            delimiters: const [
              _ExpectedDelimiter(left: 0, right: 1, commaSpan: (13, 14)),
            ],
          ),
          (
            name: 'UTF-8 BOM and non-ASCII tokens use byte offsets',
            bytes: [0xef, 0xbb, 0xbf, ...utf8.encode('{"é":"✓"}')],
            members: const [
              _ExpectedMember(
                key: 'é',
                keySpan: (4, 8),
                valueSpan: (9, 14),
                memberSpan: (4, 14),
                value: '✓',
              ),
            ],
            delimiters: const [],
          ),
        ];

    for (final testCase in cases) {
      test(testCase.name, () {
        final document = _expectSuccess(testCase.bytes);

        expect(document.source.copy(), testCase.bytes);
        expect(document.members, hasLength(testCase.members.length));
        for (var index = 0; index < testCase.members.length; index++) {
          final actual = document.members[index];
          final expected = testCase.members[index];
          expect(actual.decodedKey, expected.key);
          _expectSpan(actual.keySpan, expected.keySpan);
          _expectSpan(actual.valueSpan, expected.valueSpan);
          _expectSpan(actual.memberSpan, expected.memberSpan);
          expect(actual.decodedValue, expected.value);
        }

        expect(document.delimiters, hasLength(testCase.delimiters.length));
        for (var index = 0; index < testCase.delimiters.length; index++) {
          final actual = document.delimiters[index];
          final expected = testCase.delimiters[index];
          expect(actual.leftMemberIndex, expected.left);
          expect(actual.rightMemberIndex, expected.right);
          _expectSpan(actual.commaSpan, expected.commaSpan);
        }
      });
    }

    test('parses nested values and escaped punctuation from a fixture', () {
      final bytes = _fixtureBytes('compact_nested.arb');
      final document = _expectSuccess(bytes);

      expect(document.members.map((member) => member.decodedKey), [
        'nested',
        'café',
        '鍵',
      ]);
      expect(document.member('nested')!.decodedValue, {
        'items': [
          1,
          {'punctuation': r'\",:{}[]'},
        ],
      });
      expect(document.member('café')!.decodedValue, 'literal');
      expect(document.member('鍵')!.decodedValue, 'escaped key');
      expect(
        utf8.decode(
          document.source.slice(document.member('鍵')!.keySpan).copy(),
        ),
        '"\\u9375"',
      );
    });

    test(
      'parses ICU plural and select strings without treating braces as JSON',
      () {
        final document = _expectSuccess(_fixtureBytes('pretty_icu.arb'));

        expect(
          document.member('cart')!.decodedValue,
          '{count, plural, =0 {Empty} one {1 item} other {{count} items}}',
        );
        expect(
          document.member('status')!.decodedValue,
          '{gender, select, male {His} female {Her} other {Their}}',
        );
      },
    );

    test('deep-freezes exposed decoded maps, lists, and nested maps', () {
      final document = _expectSuccess(
        utf8.encode('{"nested":{"items":[{"value":1}]}}'),
      );
      final nested =
          document.member('nested')!.decodedValue as Map<String, Object?>;
      final items = nested['items']! as List<Object?>;
      final item = items.single as Map<String, Object?>;

      expect(() => nested['new'] = true, throwsUnsupportedError);
      expect(() => items.add(2), throwsUnsupportedError);
      expect(() => item['value'] = 2, throwsUnsupportedError);
      expect(() => document.members.clear(), throwsUnsupportedError);
      expect(() => document.delimiters.clear(), throwsUnsupportedError);
    });
  });

  group('ArbDocument.parse rejected inputs', () {
    final cases =
        <
          ({
            String name,
            List<int> bytes,
            ArbParseFailureKind kind,
            int? byteOffset,
          })
        >[
          (
            name: 'invalid UTF-8',
            bytes: [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x22, 0xc3, 0x28, 0x22, 0x7d],
            kind: ArbParseFailureKind.invalidUtf8,
            byteOffset: 6,
          ),
          (
            name: 'UTF-16 little-endian BOM',
            bytes: [0xff, 0xfe, 0x7b, 0x00, 0x7d, 0x00],
            kind: ArbParseFailureKind.unsupportedBom,
            byteOffset: 0,
          ),
          (
            name: 'UTF-16 big-endian BOM',
            bytes: [0xfe, 0xff, 0x00, 0x7b, 0x00, 0x7d],
            kind: ArbParseFailureKind.unsupportedBom,
            byteOffset: 0,
          ),
          (
            name: 'NUL byte',
            bytes: [0x7b, 0x22, 0x61, 0x22, 0x3a, 0x00, 0x31, 0x7d],
            kind: ArbParseFailureKind.nulByte,
            byteOffset: 5,
          ),
          (
            name: 'line comment',
            bytes: utf8.encode('{"a":1,// no\n"b":2}'),
            kind: ArbParseFailureKind.comment,
            byteOffset: 7,
          ),
          (
            name: 'block comment',
            bytes: utf8.encode('{"a":/* no */1}'),
            kind: ArbParseFailureKind.comment,
            byteOffset: 5,
          ),
          (
            name: 'object trailing comma',
            bytes: utf8.encode('{"a":1,}'),
            kind: ArbParseFailureKind.trailingComma,
            byteOffset: 6,
          ),
          (
            name: 'nested array trailing comma',
            bytes: utf8.encode('{"a":[1,2,]}'),
            kind: ArbParseFailureKind.trailingComma,
            byteOffset: 9,
          ),
          (
            name: 'malformed escape',
            bytes: utf8.encode('{"a":"\\q"}'),
            kind: ArbParseFailureKind.malformedJson,
            byteOffset: null,
          ),
          (
            name: 'malformed document',
            bytes: utf8.encode('{"a":1'),
            kind: ArbParseFailureKind.malformedJson,
            byteOffset: null,
          ),
          (
            name: 'array root',
            bytes: utf8.encode('[1,2]'),
            kind: ArbParseFailureKind.nonObjectRoot,
            byteOffset: 0,
          ),
          (
            name: 'scalar root',
            bytes: utf8.encode('true'),
            kind: ArbParseFailureKind.nonObjectRoot,
            byteOffset: 0,
          ),
          (
            name: 'duplicate literal key',
            bytes: utf8.encode('{"a":1,"a":2}'),
            kind: ArbParseFailureKind.duplicateDecodedKey,
            byteOffset: 7,
          ),
          (
            name: 'literal versus escaped decoded-key collision',
            bytes: utf8.encode('{"a":1,"\\u0061":2}'),
            kind: ArbParseFailureKind.duplicateDecodedKey,
            byteOffset: 7,
          ),
        ];

    for (final testCase in cases) {
      test('rejects ${testCase.name}', () {
        final result = ArbDocument.parse(testCase.bytes);

        expect(result, isA<ArbParseFailure>());
        final failure = result as ArbParseFailure;
        expect(failure.kind, testCase.kind);
        if (testCase.byteOffset != null) {
          expect(failure.byteOffset, testCase.byteOffset);
        }
      });
    }

    test(
      'does not classify comment punctuation inside a string as a comment',
      () {
        final document = _expectSuccess(
          utf8.encode('{"url":"https://example.test/a/*literal*/"}'),
        );

        expect(
          document.member('url')!.decodedValue,
          'https://example.test/a/*literal*/',
        );
      },
    );
  });

  group('ArbDocument.removeMembers', () {
    final cases = <({String name, Set<String> keys, String expected})>[
      (name: 'first', keys: {'a'}, expected: '{ "b":2, "c":3}'),
      (name: 'middle', keys: {'b'}, expected: '{"a":1,  "c":3}'),
      (name: 'final', keys: {'c'}, expected: '{"a":1, "b":2 }'),
      (name: 'adjacent', keys: {'a', 'b'}, expected: '{  "c":3}'),
      (name: 'non-adjacent', keys: {'a', 'c'}, expected: '{ "b":2 }'),
      (name: 'all', keys: {'a', 'b', 'c'}, expected: '{  }'),
      (name: 'none', keys: const {}, expected: '{"a":1, "b":2, "c":3}'),
    ];

    for (final testCase in cases) {
      test(
        'reconstructs ${testCase.name} removal from original spans once',
        () {
          final original = utf8.encode('{"a":1, "b":2, "c":3}');
          final document = _expectSuccess(original);
          final result = document.removeMembers(testCase.keys);

          expect(result, isA<ArbDocumentEditReady>());
          final ready = result as ArbDocumentEditReady;
          expect(utf8.decode(ready.bytes.copy()), testCase.expected);
          expect(
            _applySpansOnce(original, ready.removedSpans),
            ready.bytes.copy(),
          );
          _expectSurvivingBytesAreOriginal(original, ready);
          expect(ArbDocument.parse(ready.bytes.copy()), isA<ArbParseSuccess>());
          _expectSortedNonOverlapping(ready.removedSpans);
          expect(() => ready.removedSpans.clear(), throwsUnsupportedError);
        },
      );
    }

    test('removes explicitly selected message and companion member keys', () {
      final original = utf8.encode(
        '{"message":"Hello", "@message":{"description":"Greeting"}, '
        '"@unrelated":{"description":"Keep"}}',
      );
      final document = _expectSuccess(original);
      final result = document.removeMembers({'message', '@message'});

      expect(result, isA<ArbDocumentEditReady>());
      final ready = result as ArbDocumentEditReady;
      final reparsed = _expectSuccess(ready.bytes.copy());
      expect(reparsed.member('message'), isNull);
      expect(reparsed.member('@message'), isNull);
      expect(reparsed.member('@unrelated'), isNotNull);
      expect(_applySpansOnce(original, ready.removedSpans), ready.bytes.copy());
      _expectSurvivingBytesAreOriginal(original, ready);
    });

    test('preserves BOM, CRLF, braces, and final newline outside spans', () {
      final original = <int>[
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('{\r\n  "a": "A",\r\n  "b": "B"\r\n}\r\n'),
      ];
      final document = _expectSuccess(original);
      final result = document.removeMembers({'a', 'b'});

      expect(result, isA<ArbDocumentEditReady>());
      final ready = result as ArbDocumentEditReady;
      expect(ready.bytes.copy(), [
        0xef,
        0xbb,
        0xbf,
        ...utf8.encode('{\r\n  \r\n  \r\n}\r\n'),
      ]);
      expect(_applySpansOnce(original, ready.removedSpans), ready.bytes.copy());
      _expectSurvivingBytesAreOriginal(original, ready);
      expect(ArbDocument.parse(ready.bytes.copy()), isA<ArbParseSuccess>());
    });

    test('rejects a member name absent from the parsed document', () {
      final document = _expectSuccess(utf8.encode('{"a":1}'));

      final result = document.removeMembers({'missing'});

      expect(result, isA<ArbDocumentEditRejected>());
      expect(
        (result as ArbDocumentEditRejected).detailCode,
        'member-not-found',
      );
    });
  });
}

final class _ExpectedMember {
  const _ExpectedMember({
    required this.key,
    required this.keySpan,
    required this.valueSpan,
    required this.memberSpan,
    required this.value,
  });

  final String key;
  final (int, int) keySpan;
  final (int, int) valueSpan;
  final (int, int) memberSpan;
  final Object? value;
}

final class _ExpectedDelimiter {
  const _ExpectedDelimiter({
    required this.left,
    required this.right,
    required this.commaSpan,
  });

  final int left;
  final int right;
  final (int, int) commaSpan;
}

ArbDocument _expectSuccess(List<int> bytes) {
  final result = ArbDocument.parse(bytes);
  expect(result, isA<ArbParseSuccess>());
  return (result as ArbParseSuccess).document;
}

void _expectSpan(ByteSpan actual, (int, int) expected) {
  expect((actual.start, actual.endExclusive), expected);
}

List<int> _fixtureBytes(String name) {
  return File(
    'test/fixtures/l10n_action_readiness/parser/$name',
  ).readAsBytesSync();
}

Uint8List _applySpansOnce(List<int> source, List<ByteSpan> spans) {
  final output = BytesBuilder(copy: false);
  var cursor = 0;
  for (final span in spans) {
    output.add(source.sublist(cursor, span.start));
    cursor = span.endExclusive;
  }
  output.add(source.sublist(cursor));
  return output.takeBytes();
}

void _expectSurvivingBytesAreOriginal(
  List<int> original,
  ArbDocumentEditReady ready,
) {
  final expectedOrigins = <int>[];
  var spanIndex = 0;
  for (var sourceIndex = 0; sourceIndex < original.length; sourceIndex++) {
    while (spanIndex < ready.removedSpans.length &&
        sourceIndex >= ready.removedSpans[spanIndex].endExclusive) {
      spanIndex++;
    }
    final removed =
        spanIndex < ready.removedSpans.length &&
        sourceIndex >= ready.removedSpans[spanIndex].start;
    if (!removed) expectedOrigins.add(sourceIndex);
  }

  final actual = ready.bytes.copy();
  expect(actual, hasLength(expectedOrigins.length));
  for (var outputIndex = 0; outputIndex < actual.length; outputIndex++) {
    expect(actual[outputIndex], original[expectedOrigins[outputIndex]]);
  }
}

void _expectSortedNonOverlapping(List<ByteSpan> spans) {
  for (var index = 1; index < spans.length; index++) {
    expect(spans[index - 1].endExclusive, lessThan(spans[index].start + 1));
  }
}
