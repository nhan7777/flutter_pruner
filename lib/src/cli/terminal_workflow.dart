/// Writes a compact, semantic rail for long-running terminal workflows.
///
/// Icons and labels always accompany color so redirected logs retain meaning.
class TerminalWorkflow {
  /// Creates a workflow writer for [sink].
  TerminalWorkflow({required StringSink sink, this.lineWidth = 160})
    : _sink = sink;

  final StringSink _sink;

  /// Visible terminal width used when wrapping detail text.
  final int lineWidth;

  /// Starts a visually distinct workflow section.
  void section(String label, {String? detail}) {
    _sink.writeln();
    _sink.writeln(_style('◆ $label', '$_bold$_cyan'));
    if (detail != null) _writeWrapped(detail, indent: '  ', style: _dim);
  }

  /// Writes neutral workflow information.
  void info(String label, String value, {String? detail}) {
    _writeStatus(
      icon: '◇',
      label: label,
      value: value,
      color: _cyan,
      detail: detail,
    );
  }

  /// Writes a successful workflow outcome.
  void success(String label, String value, {String? detail}) {
    _writeStatus(
      icon: '✓',
      label: label,
      value: value,
      color: _green,
      detail: detail,
    );
  }

  /// Writes a safely stopped or attention-required workflow outcome.
  void warning(String label, String value, {String? detail}) {
    _writeStatus(
      icon: '!',
      label: label,
      value: value,
      color: _yellow,
      detail: detail,
    );
  }

  /// Writes a failed workflow outcome.
  void failure(String label, String value, {String? detail}) {
    _writeStatus(
      icon: '✕',
      label: label,
      value: value,
      color: _red,
      detail: detail,
    );
  }

  /// Writes a manual-recovery-required outcome.
  void recovery(String label, String value, {String? detail}) {
    _writeStatus(
      icon: '!',
      label: label,
      value: value,
      color: _magenta,
      detail: detail,
    );
  }

  /// Writes secondary detail without introducing a new status.
  void detail(String value) {
    _writeWrapped(value, indent: '    ', style: _dim);
  }

  void _writeStatus({
    required String icon,
    required String label,
    required String value,
    required String color,
    String? detail,
  }) {
    const labelWidth = 12;
    final paddedLabel = label.padRight(labelWidth);
    final visiblePrefix = '  $icon $paddedLabel ';
    final styledPrefix =
        '  ${_style(icon, color)} '
        '${_style(paddedLabel, '$_bold$color')} ';
    if (_length(visiblePrefix) + _length(value) <= _width) {
      _sink.writeln('$styledPrefix$value');
    } else {
      _sink.writeln(styledPrefix.trimRight());
      _writeWrapped(value, indent: '    ');
    }
    if (detail != null) _writeWrapped(detail, indent: '    ', style: _dim);
  }

  void _writeWrapped(
    String value, {
    required String indent,
    String style = '',
  }) {
    final remainingWidth = _width - _length(indent);
    final available = remainingWidth > 0 ? remainingWidth : 1;
    final words = value.split(RegExp(r'\s+'));
    var line = '';
    for (final word in words) {
      final candidate = line.isEmpty ? word : '$line $word';
      if (_length(candidate) <= available) {
        line = candidate;
        continue;
      }
      if (line.isNotEmpty) {
        _sink.writeln(_style('$indent$line', style));
        line = '';
      }
      var remainder = word;
      while (_length(remainder) > available) {
        final chunk = _takeStart(remainder, available);
        _sink.writeln(_style('$indent$chunk', style));
        remainder = _takeEnd(remainder, _length(remainder) - available);
      }
      line = remainder;
    }
    if (line.isNotEmpty) _sink.writeln(_style('$indent$line', style));
  }

  int get _width => lineWidth < 12 ? 12 : lineWidth;

  String _style(String value, String style) =>
      style.isEmpty ? value : '$style$value$_reset';

  int _length(String value) => value.runes.length;

  String _takeStart(String value, int count) =>
      String.fromCharCodes(value.runes.take(count));

  String _takeEnd(String value, int count) {
    if (count <= 0) return '';
    final runes = value.runes.toList();
    return String.fromCharCodes(runes.skip(runes.length - count));
  }
}

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _dim = '\x1B[2m';
const _red = '\x1B[31m';
const _green = '\x1B[32m';
const _yellow = '\x1B[33m';
const _magenta = '\x1B[35m';
const _cyan = '\x1B[36m';
