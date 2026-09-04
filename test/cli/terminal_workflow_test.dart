import 'package:flutter_pruner/src/cli/terminal_progress.dart';
import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:flutter_pruner/src/cli/terminal_workflow.dart';
import 'package:test/test.dart';

void main() {
  test('uses semantic icon and text labels for workflow states', () {
    final output = StringBuffer();
    TerminalWorkflow(sink: output, lineWidth: 80)
      ..section('ROUND 1', detail: 'Two atomic transactions')
      ..info('PLAN', 'Two findings ready')
      ..success('VERIFIED', 'Baseline accepted')
      ..warning('BLOCKED', 'Retained consumer')
      ..failure('VERIFY', 'Tool unavailable')
      ..recovery('RECOVERY', 'Manual inspection required');

    final rendered = output.toString();
    final plain = _stripAnsi(rendered);
    expect(rendered, contains('\x1B[32m'));
    expect(rendered, contains('\x1B[33m'));
    expect(rendered, contains('\x1B[31m'));
    expect(plain, contains('✓ VERIFIED'));
    expect(plain, contains('! BLOCKED'));
    expect(plain, contains('✕ VERIFY'));
    expect(plain, contains('! RECOVERY'));
  });

  test('wraps without losing long paths or exceeding terminal width', () {
    const token =
        '/project/.flutter_pruner/quarantine/run-1234567890/manifest.json';
    final output = StringBuffer();
    TerminalWorkflow(sink: output, lineWidth: 32).warning(
      'RECOVERY',
      'Inspect the recovery journal before continuing.',
      detail: token,
    );

    final plain = _stripAnsi(output.toString());
    const metrics = TerminalTextMetrics();
    expect(
      plain.split('\n').where((line) => line.isNotEmpty),
      everyElement(
        predicate<String>((line) => metrics.visibleWidth(line) <= 32),
      ),
    );
    expect(plain.replaceAll(RegExp(r'\s+'), ''), contains(token));
  });

  test('wraps CJK, combining text, and emoji at terminal-cell boundaries', () {
    const detail = '界界e\u0301😀/quarantine/emoji-😀/manifest.json';
    final output = StringBuffer();
    TerminalWorkflow(
      sink: output,
      lineWidth: 20,
    ).warning('RECOVERY', 'Inspect before continuing.', detail: detail);

    final plain = _stripAnsi(output.toString());
    const metrics = TerminalTextMetrics();
    expect(
      plain.split('\n').where((line) => line.isNotEmpty),
      everyElement(
        predicate<String>((line) => metrics.visibleWidth(line) <= 20),
      ),
    );
    expect(plain.replaceAll(RegExp(r'\s+'), ''), contains(detail));
  });

  test('wraps a Unicode workflow section header by terminal cells', () {
    final output = StringBuffer();
    TerminalWorkflow(
      sink: output,
      lineWidth: 20,
    ).section('界e\u0301😀 very long section heading');

    const metrics = TerminalTextMetrics();
    final plain = _stripAnsi(output.toString());
    expect(
      plain.split('\n').where((line) => line.isNotEmpty),
      everyElement(
        predicate<String>((line) => metrics.visibleWidth(line) <= 20),
      ),
    );
    expect(
      plain.replaceAll(RegExp(r'\s+'), ''),
      contains('界e\u0301😀verylongsectionheading'),
    );
  });

  test('progress followed by a section has exactly one blank line', () {
    final output = StringBuffer();
    final progress = TerminalProgress(sink: output, animated: false);
    final workflow = TerminalWorkflow(sink: output);

    progress
      ..start('Dart declaration analyzer')
      ..finish(succeeded: true);
    workflow.section('PLAN READY');

    expect(
      _stripAnsi(output.toString()),
      '• Scanning Dart declaration analyzer…\n\n◆ PLAN READY\n',
    );
  });

  test('repeated workflow sections have exactly one blank separator', () {
    final output = StringBuffer();
    final workflow = TerminalWorkflow(sink: output);

    workflow
      ..section('PLAN READY')
      ..section('REVERSIBLE APPLY');

    expect(
      _stripAnsi(output.toString()),
      '\n◆ PLAN READY\n\n◆ REVERSIBLE APPLY\n',
    );
  });

  test('verification and recovery transcripts keep their phase spacing', () {
    final output = StringBuffer();
    final workflow = TerminalWorkflow(sink: output);

    workflow
      ..section('VERIFICATION')
      ..success('VERIFIED', 'dart test · 0s')
      ..section('RECOVERY')
      ..recovery('RECOVERY', 'Manual inspection required');

    expect(
      _stripAnsi(output.toString()),
      '\n◆ VERIFICATION\n'
      '  ✓ VERIFIED     dart test · 0s\n'
      '\n◆ RECOVERY\n'
      '  ! RECOVERY     Manual inspection required\n',
    );
  });

  test('renders every dynamic workflow value as a terminal-safe escape', () {
    const hostile =
        'unsafe\nFORGED\r\x1B[2K\x1B[?25l\u009b31m\u202e\u2028\u2029\u2066';
    final output = StringBuffer();
    final workflow = TerminalWorkflow(sink: output);

    workflow
      ..section(hostile, detail: hostile)
      ..info(hostile, hostile, detail: hostile)
      ..success(hostile, hostile, detail: hostile)
      ..warning(hostile, hostile, detail: hostile)
      ..failure(hostile, hostile, detail: hostile)
      ..recovery(hostile, hostile, detail: hostile)
      ..detail(hostile);

    final plain = _stripAnsi(output.toString());
    const escaped =
        r'unsafe\nFORGED\r\x1B[2K\x1B[?25l\u009B31m\u202E\u2028\u2029\u2066';
    expect(plain, contains(escaped));
    expect(
      plain,
      isNot(
        matches(
          RegExp(
            r'[\r\x1b\u0080-\u009f\u061c\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069]',
          ),
        ),
      ),
    );
  });
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
