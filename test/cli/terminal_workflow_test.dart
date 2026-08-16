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
    expect(
      plain.split('\n').where((line) => line.isNotEmpty),
      everyElement(predicate<String>((line) => line.runes.length <= 32)),
    );
    expect(plain.replaceAll(RegExp(r'\s+'), ''), contains(token));
  });
}

String _stripAnsi(String value) =>
    value.replaceAll(RegExp(r'\x1B\[[0-9;]*m'), '');
