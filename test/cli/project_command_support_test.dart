import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:flutter_pruner/src/cli/project_command_support.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('project command suggestions', () {
    test('render a selected external project through SuggestedCommand', () {
      final root = Directory.systemTemp.createTempSync("project command ' ");
      try {
        final workspace = ToolWorkspace(root);

        expect(
          projectCommandFor(workspace, 'init'),
          "flutter_pruner 'init' '--project' '${root.path.replaceAll("'", "'\"'\"'")}'",
        );
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test('falls back to exact JSON argv for terminal-unsafe project paths', () {
      final root = Directory.systemTemp.createTempSync('project command line ');
      final unsafe = Directory(p.join(root.path, 'unsafe\u202eproject'));
      try {
        unsafe.createSync();
        final workspace = ToolWorkspace(unsafe);

        final suggestion = projectCommandFor(workspace, 'init');
        final lines = const LineSplitter().convert(suggestion);
        expect(
          lines.first,
          'Exact action argv (JSON; invoke without a shell):',
        );
        expect(jsonDecode(lines[1]) as List<dynamic>, <String>[
          'flutter_pruner',
          'init',
          '--project',
          unsafe.path,
        ]);
      } finally {
        root.deleteSync(recursive: true);
      }
    });

    test(
      'preflight does not interpolate a hostile project path into a shell command',
      () {
        final root = Directory.systemTemp.createTempSync('project preflight ');
        final unsafe = Directory(p.join(root.path, 'unsafe\u202eproject'));
        try {
          unsafe.createSync();
          final args = ArgParser()..addOption('project');
          final parsed = args.parse(['--project', unsafe.path]);
          final workspace = resolveToolWorkspace(parsed);

          expect(
            () => requireProjectConfig(workspace, null),
            throwsA(
              isA<ProjectConfigPreflightException>().having(
                (error) => error.message,
                'message',
                allOf(
                  contains('Exact action argv (JSON; invoke without a shell):'),
                  isNot(contains('\x1b')),
                ),
              ),
            ),
          );
        } finally {
          root.deleteSync(recursive: true);
        }
      },
    );
  });
}
