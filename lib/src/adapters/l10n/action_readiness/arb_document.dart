import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'immutable_bytes.dart';

/// Stable categories for ARB parse rejection.
enum ArbParseFailureKind {
  /// The input is not well-formed UTF-8.
  invalidUtf8,

  /// The input begins with a UTF-16 byte-order mark.
  unsupportedBom,

  /// The input contains a NUL byte.
  nulByte,

  /// JSON comment syntax appears outside a string.
  comment,

  /// An object or array has a trailing comma.
  trailingComma,

  /// The complete input is not valid JSON.
  malformedJson,

  /// The JSON root is not an object.
  nonObjectRoot,

  /// Two top-level key tokens decode to the same string.
  duplicateDecodedKey,
}

/// The result of parsing an ARB byte snapshot.
sealed class ArbParseResult {
  const ArbParseResult();
}

/// A successfully parsed byte-precise ARB document.
final class ArbParseSuccess extends ArbParseResult {
  /// Creates a successful result for [document].
  const ArbParseSuccess(this.document);

  /// The parsed document.
  final ArbDocument document;
}

/// A typed ARB parse rejection.
final class ArbParseFailure extends ArbParseResult {
  /// Creates a rejection of [kind] at an optional source [byteOffset].
  const ArbParseFailure(this.kind, {this.byteOffset});

  /// The stable rejection category.
  final ArbParseFailureKind kind;

  /// The zero-based offset in the original bytes, when available.
  final int? byteOffset;
}

/// A top-level ARB object member and its exact source spans.
final class ArbMember {
  /// Creates an immutable description of one parsed member.
  const ArbMember({
    required this.decodedKey,
    required this.keySpan,
    required this.valueSpan,
    required this.memberSpan,
    required this.decodedValue,
  });

  /// The JSON-decoded key.
  final String decodedKey;

  /// The complete JSON string token for the key.
  final ByteSpan keySpan;

  /// The complete JSON token for the value.
  final ByteSpan valueSpan;

  /// The range from the opening key quote through the value token.
  final ByteSpan memberSpan;

  /// The deeply immutable JSON-decoded value.
  final Object? decodedValue;
}

/// A comma connecting two adjacent top-level members.
final class ArbDelimiter {
  /// Creates a delimiter between two source-order member indexes.
  const ArbDelimiter({
    required this.leftMemberIndex,
    required this.rightMemberIndex,
    required this.commaSpan,
  });

  /// The member immediately before the comma.
  final int leftMemberIndex;

  /// The member immediately after the comma.
  final int rightMemberIndex;

  /// The one-byte comma range.
  final ByteSpan commaSpan;
}

/// The result of applying a byte-precise member edit.
sealed class ArbDocumentEditResult {
  const ArbDocumentEditResult();
}

/// A reconstructed ARB snapshot and its original-source removal ranges.
final class ArbDocumentEditReady extends ArbDocumentEditResult {
  /// Creates a ready edit result.
  const ArbDocumentEditReady({required this.bytes, required this.removedSpans});

  /// The immutable reconstructed bytes.
  final ImmutableBytes bytes;

  /// Sorted, non-overlapping half-open ranges removed from the source.
  final List<ByteSpan> removedSpans;
}

/// A stable edit rejection.
final class ArbDocumentEditRejected extends ArbDocumentEditResult {
  /// Creates a rejection identified by [detailCode].
  const ArbDocumentEditRejected(this.detailCode);

  /// The machine-readable rejection detail.
  final String detailCode;
}

/// A validated, byte-precise top-level ARB object.
final class ArbDocument {
  ArbDocument._({
    required this.source,
    required List<ArbMember> members,
    required List<ArbDelimiter> delimiters,
  }) : members = List.unmodifiable(members),
       delimiters = List.unmodifiable(delimiters);

  /// Parses [bytes] without retaining caller-owned mutable storage.
  static ArbParseResult parse(List<int> bytes) {
    final source = ImmutableBytes.copyOf(bytes);
    final snapshot = source.copy();

    if (_startsWith(snapshot, const [0xff, 0xfe]) ||
        _startsWith(snapshot, const [0xfe, 0xff])) {
      return const ArbParseFailure(
        ArbParseFailureKind.unsupportedBom,
        byteOffset: 0,
      );
    }

    final contentStart = _startsWith(snapshot, const [0xef, 0xbb, 0xbf])
        ? 3
        : 0;
    final invalidUtf8Offset = _firstInvalidUtf8Offset(snapshot, contentStart);
    if (invalidUtf8Offset != null) {
      return ArbParseFailure(
        ArbParseFailureKind.invalidUtf8,
        byteOffset: invalidUtf8Offset,
      );
    }

    for (var index = contentStart; index < snapshot.length; index++) {
      if (snapshot[index] == 0) {
        return ArbParseFailure(ArbParseFailureKind.nulByte, byteOffset: index);
      }
    }

    final lexicalFailure = _findUnsupportedJsonSyntax(snapshot, contentStart);
    if (lexicalFailure != null) return lexicalFailure;

    final text = utf8.decode(snapshot.sublist(contentStart));
    late final Object? decodedRoot;
    try {
      decodedRoot = jsonDecode(text);
    } on FormatException catch (error) {
      return ArbParseFailure(
        ArbParseFailureKind.malformedJson,
        byteOffset: _sourceByteOffset(text, error.offset, contentStart),
      );
    }

    if (decodedRoot is! Map<String, Object?>) {
      return ArbParseFailure(
        ArbParseFailureKind.nonObjectRoot,
        byteOffset: _firstNonWhitespace(snapshot, contentStart),
      );
    }

    final scanner = _ArbStructuralScanner(snapshot, contentStart: contentStart);
    final scanned = scanner.scan();
    if (scanned case _ScanDuplicate(:final byteOffset)) {
      return ArbParseFailure(
        ArbParseFailureKind.duplicateDecodedKey,
        byteOffset: byteOffset,
      );
    }

    final success = scanned as _ScanSuccess;
    return ArbParseSuccess(
      ArbDocument._(
        source: source,
        members: success.members,
        delimiters: success.delimiters,
      ),
    );
  }

  /// The exact immutable source snapshot.
  final ImmutableBytes source;

  /// Top-level members in source order.
  final List<ArbMember> members;

  /// Top-level commas in source order.
  final List<ArbDelimiter> delimiters;

  /// Returns the member whose decoded key equals [decodedKey].
  ArbMember? member(String decodedKey) {
    for (final member in members) {
      if (member.decodedKey == decodedKey) return member;
    }
    return null;
  }

  /// Removes exactly [decodedKeys], preserving every unowned source byte.
  ArbDocumentEditResult removeMembers(Set<String> decodedKeys) {
    final indexesByKey = <String, int>{
      for (var index = 0; index < members.length; index++)
        members[index].decodedKey: index,
    };
    if (decodedKeys.any((key) => !indexesByKey.containsKey(key))) {
      return const ArbDocumentEditRejected('member-not-found');
    }

    final removedIndexes =
        decodedKeys.map((key) => indexesByKey[key]!).toList(growable: false)
          ..sort();
    if (removedIndexes.isEmpty) {
      return ArbDocumentEditReady(
        bytes: ImmutableBytes.copyOf(source.copy()),
        removedSpans: const [],
      );
    }

    final spans = <ByteSpan>[];
    var cursor = 0;
    while (cursor < removedIndexes.length) {
      final runStart = removedIndexes[cursor];
      var runEnd = runStart;
      cursor++;
      while (cursor < removedIndexes.length &&
          removedIndexes[cursor] == runEnd + 1) {
        runEnd = removedIndexes[cursor];
        cursor++;
      }

      if (runEnd + 1 < members.length) {
        for (var index = runStart; index <= runEnd; index++) {
          spans.add(members[index].memberSpan);
          spans.add(delimiters[index].commaSpan);
        }
      } else {
        if (runStart > 0) spans.add(delimiters[runStart - 1].commaSpan);
        for (var index = runStart; index <= runEnd; index++) {
          spans.add(members[index].memberSpan);
          if (index < runEnd) spans.add(delimiters[index].commaSpan);
        }
      }
    }

    final removedSpans = _sortAndCoalesce(spans);
    final original = source.copy();
    final output = BytesBuilder(copy: false);
    var sourceCursor = 0;
    for (final span in removedSpans) {
      output.add(original.sublist(sourceCursor, span.start));
      sourceCursor = span.endExclusive;
    }
    output.add(original.sublist(sourceCursor));

    return ArbDocumentEditReady(
      bytes: ImmutableBytes.copyOf(output.takeBytes()),
      removedSpans: List.unmodifiable(removedSpans),
    );
  }
}

sealed class _ScanResult {
  const _ScanResult();
}

final class _ScanSuccess extends _ScanResult {
  const _ScanSuccess(this.members, this.delimiters);

  final List<ArbMember> members;
  final List<ArbDelimiter> delimiters;
}

final class _ScanDuplicate extends _ScanResult {
  const _ScanDuplicate(this.byteOffset);

  final int byteOffset;
}

final class _ArbStructuralScanner {
  _ArbStructuralScanner(this.bytes, {required this.contentStart})
    : cursor = contentStart;

  final Uint8List bytes;
  final int contentStart;
  int cursor;

  _ScanResult scan() {
    _skipWhitespace();
    cursor++;
    _skipWhitespace();

    final members = <ArbMember>[];
    final delimiters = <ArbDelimiter>[];
    final decodedKeys = <String>{};
    if (bytes[cursor] == _closeBrace) {
      return const _ScanSuccess([], []);
    }

    int? pendingCommaOffset;
    while (true) {
      final keyStart = cursor;
      final keyEnd = _scanString(cursor);
      final decodedKey =
          jsonDecode(utf8.decode(bytes.sublist(keyStart, keyEnd))) as String;
      if (!decodedKeys.add(decodedKey)) return _ScanDuplicate(keyStart);

      cursor = keyEnd;
      _skipWhitespace();
      cursor++;
      _skipWhitespace();

      final valueStart = cursor;
      final valueEnd = _scanValue();
      final decodedValue = _deepFreeze(
        jsonDecode(utf8.decode(bytes.sublist(valueStart, valueEnd))),
      );
      final memberIndex = members.length;
      members.add(
        ArbMember(
          decodedKey: decodedKey,
          keySpan: ByteSpan(keyStart, keyEnd),
          valueSpan: ByteSpan(valueStart, valueEnd),
          memberSpan: ByteSpan(keyStart, valueEnd),
          decodedValue: decodedValue,
        ),
      );
      if (pendingCommaOffset != null) {
        delimiters.add(
          ArbDelimiter(
            leftMemberIndex: memberIndex - 1,
            rightMemberIndex: memberIndex,
            commaSpan: ByteSpan(pendingCommaOffset, pendingCommaOffset + 1),
          ),
        );
      }

      cursor = valueEnd;
      _skipWhitespace();
      if (bytes[cursor] == _closeBrace) break;
      pendingCommaOffset = cursor;
      cursor++;
      _skipWhitespace();
    }

    return _ScanSuccess(members, delimiters);
  }

  int _scanValue() {
    final first = bytes[cursor];
    if (first == _quote) return _scanString(cursor);
    if (first == _openBrace || first == _openBracket) {
      return _scanContainer(cursor);
    }

    var end = cursor;
    while (cursor < bytes.length &&
        bytes[cursor] != _comma &&
        bytes[cursor] != _closeBrace) {
      cursor++;
      if (!_isWhitespace(bytes[cursor - 1])) end = cursor;
    }
    return end;
  }

  int _scanContainer(int start) {
    var index = start;
    var depth = 0;
    while (index < bytes.length) {
      final byte = bytes[index];
      if (byte == _quote) {
        index = _scanString(index);
        continue;
      }
      if (byte == _openBrace || byte == _openBracket) depth++;
      if (byte == _closeBrace || byte == _closeBracket) {
        depth--;
        if (depth == 0) return index + 1;
      }
      index++;
    }
    return index;
  }

  int _scanString(int start) {
    var index = start + 1;
    while (index < bytes.length) {
      final byte = bytes[index];
      if (byte == _backslash) {
        index += 2;
        continue;
      }
      if (byte == _quote) return index + 1;
      index++;
    }
    return index;
  }

  void _skipWhitespace() {
    while (cursor < bytes.length && _isWhitespace(bytes[cursor])) {
      cursor++;
    }
  }
}

ArbParseFailure? _findUnsupportedJsonSyntax(Uint8List bytes, int contentStart) {
  var inString = false;
  var escaped = false;
  for (var index = contentStart; index < bytes.length; index++) {
    final byte = bytes[index];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (byte == _backslash) {
        escaped = true;
      } else if (byte == _quote) {
        inString = false;
      }
      continue;
    }

    if (byte == _quote) {
      inString = true;
      continue;
    }
    if (byte == _slash && index + 1 < bytes.length) {
      final next = bytes[index + 1];
      if (next == _slash || next == _asterisk) {
        return ArbParseFailure(ArbParseFailureKind.comment, byteOffset: index);
      }
    }
    if (byte == _comma) {
      var lookahead = index + 1;
      while (lookahead < bytes.length && _isWhitespace(bytes[lookahead])) {
        lookahead++;
      }
      if (lookahead < bytes.length &&
          (bytes[lookahead] == _closeBrace ||
              bytes[lookahead] == _closeBracket)) {
        return ArbParseFailure(
          ArbParseFailureKind.trailingComma,
          byteOffset: index,
        );
      }
    }
  }
  return null;
}

int? _firstInvalidUtf8Offset(Uint8List bytes, int start) {
  var index = start;
  while (index < bytes.length) {
    final first = bytes[index];
    if (first <= 0x7f) {
      index++;
      continue;
    }

    var length = 0;
    var secondMin = 0x80;
    var secondMax = 0xbf;
    if (first >= 0xc2 && first <= 0xdf) {
      length = 2;
    } else if (first >= 0xe0 && first <= 0xef) {
      length = 3;
      if (first == 0xe0) secondMin = 0xa0;
      if (first == 0xed) secondMax = 0x9f;
    } else if (first >= 0xf0 && first <= 0xf4) {
      length = 4;
      if (first == 0xf0) secondMin = 0x90;
      if (first == 0xf4) secondMax = 0x8f;
    } else {
      return index;
    }

    if (index + length > bytes.length) return index;
    final second = bytes[index + 1];
    if (second < secondMin || second > secondMax) return index;
    for (var continuation = 2; continuation < length; continuation++) {
      final byte = bytes[index + continuation];
      if (byte < 0x80 || byte > 0xbf) return index;
    }
    index += length;
  }
  return null;
}

Object? _deepFreeze(Object? value) {
  if (value is Map<String, Object?>) {
    return UnmodifiableMapView<String, Object?>(<String, Object?>{
      for (final entry in value.entries) entry.key: _deepFreeze(entry.value),
    });
  }
  if (value is List<Object?>) {
    return List<Object?>.unmodifiable(value.map(_deepFreeze));
  }
  return value;
}

List<ByteSpan> _sortAndCoalesce(List<ByteSpan> spans) {
  spans.sort((left, right) => left.start.compareTo(right.start));
  final result = <ByteSpan>[];
  for (final span in spans) {
    if (result.isEmpty || result.last.endExclusive < span.start) {
      result.add(ByteSpan(span.start, span.endExclusive));
      continue;
    }
    final previous = result.removeLast();
    result.add(
      ByteSpan(
        previous.start,
        previous.endExclusive > span.endExclusive
            ? previous.endExclusive
            : span.endExclusive,
      ),
    );
  }
  return result;
}

bool _startsWith(Uint8List bytes, List<int> prefix) {
  if (bytes.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    if (bytes[index] != prefix[index]) return false;
  }
  return true;
}

int _firstNonWhitespace(Uint8List bytes, int start) {
  var index = start;
  while (index < bytes.length && _isWhitespace(bytes[index])) {
    index++;
  }
  return index;
}

int? _sourceByteOffset(String text, int? stringOffset, int contentStart) {
  if (stringOffset == null) return null;
  final safeOffset = stringOffset.clamp(0, text.length);
  return contentStart + utf8.encode(text.substring(0, safeOffset)).length;
}

bool _isWhitespace(int byte) =>
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d;

const _quote = 0x22;
const _asterisk = 0x2a;
const _comma = 0x2c;
const _slash = 0x2f;
const _openBracket = 0x5b;
const _backslash = 0x5c;
const _closeBracket = 0x5d;
const _openBrace = 0x7b;
const _closeBrace = 0x7d;
