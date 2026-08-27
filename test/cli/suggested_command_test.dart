import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/suggested_command.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('SuggestedCommand', () {
    test('snapshots argv and renders hostile POSIX arguments literally', () {
      final arguments = <String>[
        '',
        'space value',
        "apostrophe's",
        '"double"',
        r'$(touch marker)',
        r'`touch marker`',
        '; & | [brackets]',
        'Tiếng Việt',
        'e\u0301',
        'line one\nline two',
      ];
      final command = SuggestedCommand.flutterPruner(arguments);
      arguments[0] = 'mutated';

      expect(command.argv, <String>[
        'flutter_pruner',
        '',
        ...arguments.skip(1),
      ]);
      expect(
        command.render(ShellDialect.posix),
        "flutter_pruner '' 'space value' 'apostrophe'\"'\"'s' '\"double\"' "
        "'\$(touch marker)' '`touch marker`' '; & | [brackets]' 'Tiếng Việt' "
        "'é' 'line one\nline two'",
      );
    });

    test('renders PowerShell arguments with doubled apostrophes', () {
      final command = SuggestedCommand.flutterPruner([
        '',
        "apostrophe's",
        r'$(touch marker)',
        'line one\nline two',
      ]);

      expect(
        command.render(ShellDialect.powerShell),
        r"""flutter_pruner '""' 'apostrophe''s' '$(touch marker)' 'line one
line two'""",
      );
    });

    test('quotes a dynamic executable with the selected shell dialect', () {
      final command = SuggestedCommand('bin/tool name', ['value']);

      expect(command.render(ShellDialect.posix), "'bin/tool name' 'value'");
      expect(
        command.render(ShellDialect.powerShell),
        "& 'bin/tool name' 'value'",
      );
    });

    test('rejects NUL in the executable or any argument', () {
      expect(
        () => SuggestedCommand('tool\u0000', const []),
        throwsArgumentError,
      );
      expect(
        () => SuggestedCommand.flutterPruner(['bad\u0000argument']),
        throwsArgumentError,
      );
    });

    test('uses an exact JSON argv fallback for terminal-unsafe values', () {
      final command = SuggestedCommand.flutterPruner([
        'quarantine',
        'inspect',
        'line one\nline two\x1b[31m',
      ]);

      expect(command.isTerminalSafe, isFalse);
      expect(
        command.renderForTerminal(ShellDialect.posix),
        'Exact action argv (JSON; invoke without a shell):\n'
        '["flutter_pruner","quarantine","inspect","line one\\nline two\\u001b[31m"]',
      );
    });

    test(
      'POSIX rendering reconstructs exact argv without evaluating hostile input',
      () async {
        if (Platform.isWindows) return;
        final temp = Directory.systemTemp.createTempSync('suggested_command_');
        try {
          final received = File(p.join(temp.path, 'received.json'));
          final marker = File(p.join(temp.path, 'marker'));
          final recorder = File(p.join(temp.path, 'record.dart'))
            ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  File(arguments.first).writeAsStringSync(jsonEncode(arguments.skip(1).toList()));
}
''');
          final hostile = <String>[
            '',
            'space value',
            "apostrophe's",
            '"double"',
            r'$(touch marker)',
            '`touch marker`',
            '; & | [brackets]',
            'Tiếng Việt',
            'e\u0301',
            'line one\nline two',
            '\$(touch ${marker.path})',
          ];
          final command = SuggestedCommand(Platform.resolvedExecutable, [
            recorder.path,
            received.path,
            ...hostile,
          ]);

          final result = await Process.run('zsh', [
            '-c',
            command.render(ShellDialect.posix),
          ]);

          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          expect(
            (jsonDecode(received.readAsStringSync()) as List<dynamic>)
                .cast<String>(),
            hostile,
          );
          expect(marker.existsSync(), isFalse);
        } finally {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    test(
      'PowerShell rendering reconstructs exact argv when PowerShell is hosted',
      () async {
        if (!Platform.isWindows) return;
        final available = Process.runSync('where.exe', ['powershell.exe']);
        if (available.exitCode != 0) return;
        final temp = Directory.systemTemp.createTempSync('suggested_command_');
        try {
          final received = File(p.join(temp.path, 'received.json'));
          final recorder = File(p.join(temp.path, 'record.dart'))
            ..writeAsStringSync('''
import 'dart:convert';
import 'dart:io';

void main(List<String> arguments) {
  File(arguments.first).writeAsStringSync(jsonEncode(arguments.skip(1).toList()));
}
''');
          final hostile = <String>[
            '',
            "apostrophe's",
            r'$(Write-Error forged)',
            'line one\nline two',
          ];
          final command = SuggestedCommand(Platform.resolvedExecutable, [
            recorder.path,
            received.path,
            ...hostile,
          ]);

          final result = await Process.run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            command.render(ShellDialect.powerShell),
          ]);

          expect(
            result.exitCode,
            0,
            reason: '${result.stdout}${result.stderr}',
          );
          expect(
            (jsonDecode(received.readAsStringSync()) as List<dynamic>)
                .cast<String>(),
            hostile,
          );
        } finally {
          if (temp.existsSync()) temp.deleteSync(recursive: true);
        }
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  });
}
