import 'dart:async';

import 'cli_signal_coordinator.dart';
import 'formatters/quarantine_formatter.dart';

/// Formats the package-internal analysis warning as a prominent terminal rail.
String packageInternalWarning(String packageName) {
  final displayPackageName = QuarantineFormatter.terminalSafe(packageName);
  return '$_bold$_yellow⚠  WARNING · PACKAGE INTERNAL$_reset '
      '$_bold$_magenta($displayPackageName)$_reset\n'
      '$_yellow┃$_reset $_bold'
      'Only references inside this package are analysed.$_reset\n'
      '$_yellow┃ External applications and packages may still use public '
      'symbols,$_reset\n'
      '$_yellow┃ deep imports, and package assets.$_reset';
}

/// Renders styled scan progress without polluting redirected output.
class TerminalProgress {
  /// Creates progress output for [sink].
  ///
  /// Animation is enabled only when [animated] is true. [startTicker] exists
  /// so frame rendering can be exercised deterministically in tests.
  TerminalProgress({
    required StringSink sink,
    required bool animated,
    CliSignalCoordinator? signalCoordinator,
    void Function() Function(void Function())? startTicker,
  }) : _sink = sink,
       _animated = animated,
       _signalCoordinator = signalCoordinator,
       _startTicker = startTicker ?? _startTimer;

  final StringSink _sink;
  final bool _animated;
  final CliSignalCoordinator? _signalCoordinator;
  final void Function() Function(void Function()) _startTicker;

  _ProgressActivity? _current;
  void Function()? _cancelTicker;
  var _frameIndex = 0;

  /// Writes the selected project as a compact colored context line.
  void writeProject(String path) {
    final displayPath = QuarantineFormatter.terminalSafe(path);
    _sink.writeln('$_bold$_magenta◆ PROJECT$_reset  $_cyan$displayPath$_reset');
  }

  /// Starts one activity, completing the previous activity first.
  void start(String label, {String activity = 'Scanning'}) {
    _finishCurrent(succeeded: true);
    final current = _ProgressActivity(
      label: QuarantineFormatter.terminalSafe(label),
      activity: QuarantineFormatter.terminalSafe(activity),
    );
    _current = current;
    _frameIndex = 0;
    if (!_animated) {
      _sink.writeln(
        '$_cyan•$_reset $_italic'
        '$_dim'
        '${current.activity} ${current.label}…$_reset',
      );
      return;
    }
    _drawFrame(current);
    _signalCoordinator?.setActiveLineClearer(_clearActiveAnimatedLine);
    _cancelTicker = _startTicker(() => _advanceFrame(current));
  }

  /// Stops the active activity and restores a complete terminal line.
  void finish({required bool succeeded}) {
    _finishCurrent(succeeded: succeeded);
  }

  void _advanceFrame(_ProgressActivity activity) {
    if (!identical(_current, activity) ||
        activity.state != _ProgressActivityState.active) {
      return;
    }
    _frameIndex = (_frameIndex + 1) % _frames.length;
    _drawFrame(activity);
  }

  void _drawFrame(_ProgressActivity activity) {
    final color = _spinnerColors[_frameIndex % _spinnerColors.length];
    _sink.write(
      '\r$_clearLine$color${_frames[_frameIndex]}$_reset '
      '$_italic'
      '$_cyan'
      '${activity.activity} ${activity.label}…$_reset',
    );
  }

  void _finishCurrent({required bool succeeded}) {
    final current = _current;
    if (current == null || current.state != _ProgressActivityState.active) {
      return;
    }
    current.state = _ProgressActivityState.finished;
    _current = null;
    final cancelTicker = _cancelTicker;
    _cancelTicker = null;
    cancelTicker?.call();
    if (_animated) {
      _signalCoordinator?.setActiveLineClearer(null);
      _sink.write('\r$_clearLine');
      if (succeeded) {
        _sink.writeln('$_green✓$_reset $_italic$_dim${current.label}$_reset');
      } else {
        _sink.writeln(
          '$_yellow!$_reset $_italic$_dim${current.label} stopped$_reset',
        );
      }
    } else if (!succeeded) {
      _sink.writeln(
        '$_yellow!$_reset $_italic$_dim${current.label} stopped$_reset',
      );
    }
  }

  void _clearActiveAnimatedLine() {
    final current = _current;
    if (!_animated ||
        current == null ||
        current.state != _ProgressActivityState.active) {
      return;
    }
    current.state = _ProgressActivityState.finished;
    _current = null;
    final cancelTicker = _cancelTicker;
    _cancelTicker = null;
    cancelTicker?.call();
    _signalCoordinator?.setActiveLineClearer(null);
    _sink.write('\r$_clearLine\n');
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

enum _ProgressActivityState { active, finished }

final class _ProgressActivity {
  _ProgressActivity({required this.label, required this.activity});

  final String label;
  final String activity;
  var state = _ProgressActivityState.active;
}

const _reset = '\x1B[0m';
const _bold = '\x1B[1m';
const _yellow = '\x1B[33m';
const _magenta = '\x1B[35m';
