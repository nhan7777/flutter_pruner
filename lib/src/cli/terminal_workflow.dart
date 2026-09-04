import 'formatters/quarantine_formatter.dart';
import 'terminal_text_metrics.dart';

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

  static const _metrics = TerminalTextMetrics();

  /// Starts a visually distinct workflow section.
  void section(String label, {String? detail}) {
    final displayLabel = QuarantineFormatter.terminalSafe(label);
    final displayDetail = detail == null
        ? null
        : QuarantineFormatter.terminalSafe(detail);
    _sink.writeln();
    for (final line in _metrics.wrap('◆ $displayLabel', width: _width)) {
      _sink.writeln(_style(line, '$_bold$_cyan'));
    }
    if (displayDetail != null) {
      _writeWrapped(displayDetail, indent: '  ', style: _dim);
    }
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
    _writeWrapped(
      QuarantineFormatter.terminalSafe(value),
      indent: '    ',
      style: _dim,
    );
  }

  void _writeStatus({
    required String icon,
    required String label,
    required String value,
    required String color,
    String? detail,
  }) {
    final displayLabel = QuarantineFormatter.terminalSafe(label);
    final displayValue = QuarantineFormatter.terminalSafe(value);
    final displayDetail = detail == null
        ? null
        : QuarantineFormatter.terminalSafe(detail);
    const labelWidth = 12;
    final paddedLabel = _padRight(displayLabel, labelWidth);
    final visiblePrefix = '  $icon $paddedLabel ';
    final styledPrefix =
        '  ${_style(icon, color)} '
        '${_style(paddedLabel, '$_bold$color')} ';
    if (_metrics.visibleWidth(visiblePrefix) +
            _metrics.visibleWidth(displayValue) <=
        _width) {
      _sink.writeln('$styledPrefix$displayValue');
    } else {
      for (final line in _metrics.wrap(
        styledPrefix.trimRight(),
        width: _width,
      )) {
        _sink.writeln(line);
      }
      _writeWrapped(displayValue, indent: '    ');
    }
    if (displayDetail != null) {
      _writeWrapped(displayDetail, indent: '    ', style: _dim);
    }
  }

  void _writeWrapped(
    String value, {
    required String indent,
    String style = '',
  }) {
    for (final line in _metrics.wrap(
      value,
      width: _width,
      firstIndent: indent,
      continuationIndent: indent,
    )) {
      _sink.writeln(_style(line, style));
    }
  }

  int get _width => lineWidth < 12 ? 12 : lineWidth;

  String _style(String value, String style) =>
      style.isEmpty ? value : '$style$value$_reset';

  String _padRight(String value, int width) {
    final spaces = width - _metrics.visibleWidth(value);
    return spaces > 0 ? '$value${List.filled(spaces, ' ').join()}' : value;
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
