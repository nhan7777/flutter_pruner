import 'dart:async';

/// Formats the package-internal analysis warning as a prominent terminal rail.
String packageInternalWarning(String packageName) =>
    '$_bold$_yellow⚠  WARNING · PACKAGE INTERNAL$_reset '
    '$_bold$_magenta($packageName)$_reset\n'
    '$_yellow┃$_reset $_bold'
    'Only references inside this package are analysed.$_reset\n'
    '$_yellow┃ External applications and packages may still use public '
    'symbols,$_reset\n'
    '$_yellow┃ deep imports, and package assets.$_reset';

/// Renders styled scan progress without polluting redirected output.
class TerminalProgress {
  /// Creates progress output for [sink].
  ///
  /// Animation is enabled only when [animated] is true. [startTicker] exists
  /// so frame rendering can be exercised deterministically in tests.
  TerminalProgress({
    required StringSink sink,
    required bool animated,
    void Function() Function(void Function())? startTicker,
  }) : _sink = sink,
       _animated = animated,
       _startTicker = startTicker ?? _startTimer;

  final StringSink _sink;
  final bool _animated;
  final void Function() Function(void Function()) _startTicker;

  String? _label;
  String? _activity;
  void Function()? _cancelTicker;
  var _frameIndex = 0;

  /// Writes the selected project as a compact colored context line.
  void writeProject(String path) {
    _sink.writeln('$_bold$_magenta◆ PROJECT$_reset  $_cyan$path$_reset');
  }

  /// Starts one activity, completing the previous activity first.
  void start(String label, {String activity = 'Scanning'}) {
    _completeCurrent();
    _label = label;
    _activity = activity;
    _frameIndex = 0;
    if (!_animated) {
      _sink.writeln(
        '$_cyan•$_reset $_italic'
        '$_dim'
        '$activity $label...$_reset',
      );
      return;
    }
    _drawFrame();
    _cancelTicker = _startTicker(_advanceFrame);
  }

  /// Stops animation, restores a complete terminal line, and adds separation.
  void finish({required bool succeeded}) {
    if (_label != null) {
      if (succeeded) {
        _completeCurrent();
      } else {
        _cancelTicker?.call();
        if (_animated) _sink.write('\r$_clearLine');
        _sink.writeln(
          '$_yellow!$_reset $_italic$_dim${_label!} stopped$_reset',
        );
        _label = null;
        _activity = null;
        _cancelTicker = null;
      }
    }
    _sink.writeln();
  }

  void _advanceFrame() {
    if (_label == null) return;
    _frameIndex = (_frameIndex + 1) % _frames.length;
    _drawFrame();
  }

  void _drawFrame() {
    final color = _spinnerColors[_frameIndex % _spinnerColors.length];
    _sink.write(
      '\r$_clearLine$color${_frames[_frameIndex]}$_reset '
      '$_italic'
      '$_cyan'
      '${_activity!} ${_label!}...$_reset',
    );
  }

  void _completeCurrent() {
    final label = _label;
    if (label == null) return;
    _cancelTicker?.call();
    if (_animated) {
      _sink
        ..write('\r$_clearLine')
        ..writeln('$_green✓$_reset $_italic$_dim$label$_reset');
    }
    _label = null;
    _activity = null;
    _cancelTicker = null;
  }

  static void Function() _startTimer(void Function() tick) {
    final timer = Timer.periodic(
      const Duration(milliseconds: 80),
      (_) => tick(),
    );
    return timer.cancel;
  }

  static const _frames = ['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];
  static const _spinnerColors = [_cyan, _magenta, _yellow];
  static const _clearLine = '\x1B[2K';
  static const _dim = '\x1B[2m';
  static const _italic = '\x1B[3m';
  static const _green = '\x1B[32m';
  static const _cyan = '\x1B[36m';
}

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _yellow = '\x1B[33m';
const _magenta = '\x1B[35m';
