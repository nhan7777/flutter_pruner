import 'package:characters/characters.dart';
import 'package:string_width/string_width.dart';

/// Measures and wraps human-terminal text without splitting grapheme clusters.
final class TerminalTextMetrics {
  /// Creates terminal text metrics.
  const TerminalTextMetrics();

  /// Returns the display-cell width of [value].
  ///
  /// Supported CSI SGR sequences are zero-width. Other terminal controls are
  /// rendered as visible escape text before measuring.
  int visibleWidth(String value) => _tokens(value)
      .whereType<_PrintableToken>()
      .fold(0, (width, token) => width + _clusterWidth(token.value));

  /// Wraps [value] at [width] display cells without splitting a grapheme or
  /// supported CSI SGR sequence.
  List<String> wrap(
    String value, {
    required int width,
    String firstIndent = '',
    String continuationIndent = '',
  }) {
    final lines = <String>[];
    final sgr = _SgrState();
    final safeContinuationIndent = _safeIndent(continuationIndent);
    var indent = _safeIndent(firstIndent);
    var contentWidth = 0;
    var contentCapacity = _contentCapacity(width, indent);
    var hasPrintableContent = false;
    var line = StringBuffer(indent);

    void beginContinuation() {
      indent = safeContinuationIndent;
      contentWidth = 0;
      contentCapacity = _contentCapacity(width, indent);
      hasPrintableContent = false;
      line = StringBuffer(indent);
      line.write(sgr.active);
    }

    void finishLine() {
      if (!hasPrintableContent) return;
      if (sgr.isActive) line.write(_reset);
      lines.add(line.toString());
      beginContinuation();
    }

    for (final token in _tokens(value)) {
      if (token case _SgrToken()) {
        line.write(token.value);
        sgr.accept(token.value);
        continue;
      }

      final printable = token as _PrintableToken;
      final clusterWidth = _clusterWidth(printable.value);
      if (hasPrintableContent &&
          contentWidth + clusterWidth > contentCapacity) {
        finishLine();
      }

      line.write(printable.value);
      contentWidth += clusterWidth;
      hasPrintableContent = true;
    }

    finishLine();
    return lines;
  }
}

const _reset = '\x1B[0m';
final _sgrPattern = RegExp(r'\x1B\[[0-9;]*m');

int _contentCapacity(int width, String indent) {
  final available = width - TerminalTextMetrics().visibleWidth(indent);
  return available < 1 ? 1 : available;
}

List<_Token> _tokens(String value) {
  final tokens = <_Token>[];
  final printable = StringBuffer();

  void flushPrintable() {
    if (printable.isEmpty) return;
    for (final cluster in printable.toString().characters) {
      tokens.add(_PrintableToken(cluster));
    }
    printable.clear();
  }

  for (var offset = 0; offset < value.length;) {
    final sgr = _sgrPattern.matchAsPrefix(value, offset);
    if (sgr != null) {
      flushPrintable();
      tokens.add(_SgrToken(sgr.group(0)!));
      offset = sgr.end;
      continue;
    }

    final rune = _runeAt(value, offset);
    printable.write(
      _isTerminalUnsafe(rune)
          ? _visibleEscape(rune)
          : String.fromCharCode(rune),
    );
    offset += rune > 0xFFFF ? 2 : 1;
  }
  flushPrintable();
  return tokens;
}

int _runeAt(String value, int offset) {
  final first = value.codeUnitAt(offset);
  if (first < 0xD800 || first > 0xDBFF || offset + 1 >= value.length) {
    return first;
  }
  final second = value.codeUnitAt(offset + 1);
  if (second < 0xDC00 || second > 0xDFFF) return first;
  return 0x10000 + ((first - 0xD800) << 10) + second - 0xDC00;
}

int _clusterWidth(String cluster) {
  final runes = cluster.runes.toList(growable: false);
  if (runes.isEmpty || runes.every(_isZeroWidthRune)) return 0;
  final measurable = String.fromCharCodes(
    runes.where((rune) => !_isZeroWidthRune(rune)),
  );
  if (_isFlag(runes) || _isKeycap(runes)) return 2;
  if (runes.contains(0xFE0E) && runes.any(_supportsEmojiVariation)) {
    return measurable.isEmpty ? 0 : 1;
  }
  if (runes.any(_isEmojiRune) ||
      (runes.contains(0xFE0F) && runes.any(_supportsEmojiVariation))) {
    return 2;
  }
  return stringWidth(measurable);
}

bool _isFlag(List<int> runes) =>
    runes.length == 2 &&
    runes.every((rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF);

bool _isKeycap(List<int> runes) =>
    runes.length >= 2 &&
    runes.last == 0x20E3 &&
    (runes.first == 0x23 ||
        runes.first == 0x2A ||
        (runes.first >= 0x30 && runes.first <= 0x39));

bool _isEmojiRune(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) || (rune >= 0x2600 && rune <= 0x27BF);

bool _supportsEmojiVariation(int rune) =>
    (rune >= 0x1F000 && rune <= 0x1FAFF) ||
    (rune >= 0x2194 && rune <= 0x2199) ||
    (rune >= 0x23ED && rune <= 0x23EF) ||
    (rune >= 0x23F1 && rune <= 0x23F2) ||
    (rune >= 0x23F8 && rune <= 0x23FA) ||
    (rune >= 0x2600 && rune <= 0x2604) ||
    (rune >= 0x2638 && rune <= 0x263A) ||
    (rune >= 0x2648 && rune <= 0x2653) ||
    (rune >= 0x2694 && rune <= 0x2697) ||
    (rune >= 0x26F0 && rune <= 0x26F5) ||
    (rune >= 0x2B05 && rune <= 0x2B07) ||
    _emojiVariationBaseSingles.contains(rune);

const _emojiVariationBaseSingles = <int>{
  0x00A9,
  0x00AE,
  0x203C,
  0x2049,
  0x2122,
  0x2139,
  0x21A9,
  0x21AA,
  0x231A,
  0x231B,
  0x2328,
  0x23CF,
  0x24C2,
  0x25AA,
  0x25AB,
  0x25B6,
  0x25C0,
  0x25FB,
  0x25FC,
  0x25FE,
  0x260E,
  0x2611,
  0x2614,
  0x2615,
  0x2618,
  0x261D,
  0x2620,
  0x2622,
  0x2623,
  0x2626,
  0x262A,
  0x262E,
  0x262F,
  0x2640,
  0x2642,
  0x265F,
  0x2660,
  0x2663,
  0x2665,
  0x2666,
  0x2668,
  0x267B,
  0x267E,
  0x267F,
  0x2692,
  0x2699,
  0x269B,
  0x269C,
  0x26A0,
  0x26A7,
  0x26AA,
  0x26B0,
  0x26B1,
  0x26BD,
  0x26BE,
  0x26C4,
  0x26C8,
  0x26CF,
  0x26D1,
  0x26D3,
  0x26E9,
  0x26F7,
  0x26F8,
  0x26F9,
  0x26FA,
  0x2702,
  0x2708,
  0x2709,
  0x270C,
  0x270D,
  0x270F,
  0x2712,
  0x2714,
  0x2716,
  0x271D,
  0x2721,
  0x2733,
  0x2734,
  0x2744,
  0x2747,
  0x2757,
  0x2763,
  0x2764,
  0x27A1,
  0x2934,
  0x2935,
  0x2B1B,
  0x2B1C,
  0x2B55,
  0x3030,
  0x303D,
  0x3297,
  0x3299,
};

bool _isZeroWidthRune(int rune) =>
    rune == 0x200D ||
    (rune >= 0x0300 && rune <= 0x036F) ||
    (rune >= 0x1AB0 && rune <= 0x1AFF) ||
    (rune >= 0x1DC0 && rune <= 0x1DFF) ||
    (rune >= 0x20D0 && rune <= 0x20FF) ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    (rune >= 0xFE20 && rune <= 0xFE2F) ||
    (rune >= 0xE0100 && rune <= 0xE01EF);

bool _isTerminalUnsafe(int rune) =>
    rune <= 0x1F ||
    (rune >= 0x7F && rune <= 0x9F) ||
    rune == 0x061C ||
    rune == 0x200E ||
    rune == 0x200F ||
    rune == 0x2028 ||
    rune == 0x2029 ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2066 && rune <= 0x2069);

String _visibleEscape(int rune) {
  switch (rune) {
    case 0x09:
      return r'\t';
    case 0x0A:
      return r'\n';
    case 0x0D:
      return r'\r';
  }
  if (rune <= 0xFF) {
    return '\\x${rune.toRadixString(16).padLeft(2, '0').toUpperCase()}';
  }
  if (rune <= 0xFFFF) {
    return '\\u${rune.toRadixString(16).padLeft(4, '0').toUpperCase()}';
  }
  return '\\u{${rune.toRadixString(16).toUpperCase()}}';
}

String _safeIndent(String value) {
  final buffer = StringBuffer();
  final sgr = _SgrState();
  for (final token in _tokens(value)) {
    buffer.write(token.value);
    if (token case _SgrToken()) sgr.accept(token.value);
  }
  if (sgr.isActive) buffer.write(_reset);
  return buffer.toString();
}

sealed class _Token {
  const _Token(this.value);

  final String value;
}

final class _PrintableToken extends _Token {
  const _PrintableToken(super.value);
}

final class _SgrToken extends _Token {
  const _SgrToken(super.value);
}

final class _SgrState {
  String active = '';

  bool get isActive => active.isNotEmpty;

  void accept(String sequence) {
    final parameters = sequence.substring(2, sequence.length - 1);
    final codes = parameters.isEmpty ? const ['0'] : parameters.split(';');
    if (codes.contains('0')) active = '';
    if (codes.any((code) => code != '0')) active += sequence;
  }
}
