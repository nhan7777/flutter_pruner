import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A validated half-open range of byte offsets.
final class ByteSpan {
  /// Creates a byte range from [start] through, but not including,
  /// [endExclusive].
  ByteSpan(this.start, this.endExclusive) {
    if (start < 0 || endExclusive < start) {
      throw RangeError.range(endExclusive, start, null, 'endExclusive');
    }
  }

  /// The inclusive start offset.
  final int start;

  /// The exclusive end offset.
  final int endExclusive;

  /// The number of bytes in this span.
  int get length => endExclusive - start;
}

/// An immutable, byte-exact value with a cached SHA-256 digest.
final class ImmutableBytes {
  ImmutableBytes._(this._bytes);

  /// Makes a defensive copy of [source].
  factory ImmutableBytes.copyOf(List<int> source) =>
      ImmutableBytes._(Uint8List.fromList(source));

  final Uint8List _bytes;

  late final String _sha256Hex = sha256.convert(_bytes).toString();

  /// The number of retained bytes.
  int get length => _bytes.length;

  /// Returns the byte at [index].
  int operator [](int index) => _bytes[index];

  /// The cached SHA-256 digest of the exact retained bytes.
  String get sha256Hex => _sha256Hex;

  /// Returns a defensive copy of the retained bytes.
  Uint8List copy() => Uint8List.fromList(_bytes);

  /// Returns an isolated byte value for [span].
  ImmutableBytes slice(ByteSpan span) {
    if (span.endExclusive > _bytes.length) {
      throw RangeError.range(
        span.endExclusive,
        0,
        _bytes.length,
        'span.endExclusive',
      );
    }
    return ImmutableBytes._(
      Uint8List.fromList(_bytes.sublist(span.start, span.endExclusive)),
    );
  }

  /// Whether [other] retains the same bytes in the same order.
  bool contentEquals(ImmutableBytes other) {
    if (length != other.length) return false;
    for (var index = 0; index < length; index++) {
      if (_bytes[index] != other[index]) return false;
    }
    return true;
  }
}
