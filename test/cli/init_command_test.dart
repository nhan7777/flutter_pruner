import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/init_prompt.dart';
import 'package:flutter_pruner/src/core/project/project_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

late Directory tempDir;

void main() {
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('init_command_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'detects an application and writes an incomplete config by default',
    () async {
      final project = _project('app', name: 'example_app', application: true);

      final exitCode = await FlutterPrunerCommandRunner().run([
        'init',
        project.path,
      ]);

      expect(exitCode, 0);
      final config = File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      );
      expect(config.readAsStringSync(), contains('mode: application'));
      expect(config.readAsStringSync(), contains('complete: false'));
      final loaded = await ProjectConfig.load(config, projectRoot: project);
      expect(loaded.targetMatrix.isComplete, isFalse);
      expect(
        File(
          p.join(project.path, '.flutter_pruner', '.gitignore'),
        ).readAsStringSync(),
        allOf(contains('!.gitignore'), contains('!config.yaml')),
      );
    },
  );

  test('detects a package and declares its public library', () async {
    final project = _project('package', name: 'example_package');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      project.path,
    ]);

    expect(exitCode, 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    final content = config.readAsStringSync();
    expect(content, contains('mode: package'));
    expect(content, isNot(contains('root_coverage:')));
    expect(content, contains('    - lib/example_package.dart'));
    final loaded = await ProjectConfig.load(config, projectRoot: project);
    expect(loaded.rootCoverage.publicEntrypoints, ['lib/example_package.dart']);
  });

  test('package-internal requires an explicit type selection', () async {
    final project = _project('internal', name: 'internal_package');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      '--type',
      'package-internal',
      '--complete',
      project.path,
    ]);

    expect(exitCode, 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    final loaded = await ProjectConfig.load(config, projectRoot: project);
    expect(loaded.analysisMode.wireName, 'package-internal');
    expect(loaded.targetMatrix.isComplete, isTrue);
    expect(loaded.rootCoverage.internalBoundaryComplete, isTrue);
    expect(loaded.rootCoverage.externalConsumersCovered, isFalse);
  });

  test('--complete explicitly declares a complete target matrix', () async {
    final project = _project(
      'complete',
      name: 'complete_app',
      application: true,
    );

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      '--complete',
      project.path,
    ]);

    expect(exitCode, 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    final loaded = await ProjectConfig.load(config, projectRoot: project);
    expect(loaded.targetMatrix.isComplete, isTrue);
  });

  test('--complete rejects unsupported conditional imports', () async {
    final project = _project(
      'conditional_complete',
      name: 'conditional_complete_app',
      application: true,
    );
    File(p.join(project.path, 'lib', 'conditional.dart')).writeAsStringSync(
      "import 'io.dart' if (dart.library.html) 'web.dart';\n",
    );

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      '--type',
      'application',
      '--entrypoint',
      'lib/main.dart',
      '--platform',
      'android',
      '--complete',
      project.path,
    ]);

    expect(exitCode, 64);
    expect(
      File(p.join(project.path, '.flutter_pruner', 'config.yaml')).existsSync(),
      isFalse,
    );
  });

  test('accepts complete target coverage for a reusable package', () async {
    final project = _project('open_world', name: 'open_world_package');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      '--complete',
      project.path,
    ]);

    expect(exitCode, 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    final loaded = await ProjectConfig.load(config, projectRoot: project);
    expect(loaded.analysisMode.wireName, 'package');
    expect(loaded.targetMatrix.isComplete, isTrue);
    expect(loaded.rootCoverage.externalConsumersCovered, isFalse);
  });

  test('prefers package mode for a hybrid project', () async {
    final project = _project(
      'hybrid',
      name: 'hybrid_package',
      application: true,
    );
    File(
      p.join(project.path, 'lib', 'hybrid_package.dart'),
    ).writeAsStringSync('library hybrid_package;\n');

    final defaultExitCode = await FlutterPrunerCommandRunner().run([
      'init',
      project.path,
    ]);

    expect(defaultExitCode, 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    expect(config.readAsStringSync(), contains('mode: package'));
    expect(config.readAsStringSync(), contains('complete: false'));
  });

  test(
    'keeps a complete hybrid project in conservative package mode',
    () async {
      final project = _project(
        'hybrid_complete',
        name: 'hybrid_complete_package',
        application: true,
      );
      File(
        p.join(project.path, 'lib', 'hybrid_complete_package.dart'),
      ).writeAsStringSync('library hybrid_complete_package;\n');

      final completeExitCode = await FlutterPrunerCommandRunner().run([
        'init',
        '--complete',
        project.path,
      ]);

      expect(completeExitCode, 0);
      final config = File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      );
      final loaded = await ProjectConfig.load(config, projectRoot: project);
      expect(loaded.analysisMode.wireName, 'package');
      expect(loaded.targetMatrix.isComplete, isTrue);
    },
  );

  test(
    'requires an explicit application assertion for secondary public libraries',
    () async {
      final project = _project(
        'secondary_library',
        name: 'secondary_library_app',
        application: true,
      );
      File(
        p.join(project.path, 'lib', 'api.dart'),
      ).writeAsStringSync('library api;\n');

      final implicitExitCode = await FlutterPrunerCommandRunner().run([
        'init',
        '--complete',
        project.path,
      ]);

      expect(implicitExitCode, 64);
      final config = File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      );
      expect(config.existsSync(), isFalse);

      final explicitExitCode = await FlutterPrunerCommandRunner().run([
        'init',
        '--type',
        'application',
        '--complete',
        project.path,
      ]);

      expect(explicitExitCode, 0);
      final loaded = await ProjectConfig.load(config, projectRoot: project);
      expect(loaded.targetMatrix.isComplete, isTrue);
    },
  );

  test(
    'does not overwrite either new or legacy config without --force',
    () async {
      final project = _project(
        'existing',
        name: 'existing_app',
        application: true,
      );
      final legacy = File(p.join(project.path, 'flutter_pruner.yaml'))
        ..writeAsStringSync('legacy config\n');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'init',
        project.path,
      ]);

      expect(exitCode, 1);
      expect(legacy.readAsStringSync(), 'legacy config\n');
      expect(
        File(
          p.join(project.path, '.flutter_pruner', 'config.yaml'),
        ).existsSync(),
        isFalse,
      );
    },
  );

  test('--force preserves the previous config as a backup', () async {
    final project = _project('forced', name: 'forced_app', application: true);
    expect(await FlutterPrunerCommandRunner().run(['init', project.path]), 0);
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    config.writeAsStringSync('${config.readAsStringSync()}# owner edit\n');

    final exitCode = await FlutterPrunerCommandRunner().run([
      'init',
      '--force',
      project.path,
    ]);

    expect(exitCode, 0);
    final backup = File('${config.path}.bak');
    expect(backup.readAsStringSync(), contains('# owner edit'));
    await expectLater(
      ProjectConfig.load(config, projectRoot: project),
      completes,
    );
  });

  test(
    'resolves --project from another directory without changing global cwd',
    () async {
      final project = _project(
        'external',
        name: 'external_app',
        application: true,
      );
      final originalCwd = Directory.current.path;
      final unrelated = Directory(p.join(tempDir.path, 'unrelated'))
        ..createSync();

      final exitCode = await FlutterPrunerCommandRunner().run([
        'init',
        '--project',
        project.path,
      ]);

      expect(exitCode, 0);
      expect(Directory.current.path, originalCwd);
      expect(
        File(
          p.join(unrelated.path, '.flutter_pruner', 'config.yaml'),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(project.path, '.flutter_pruner', 'config.yaml'),
        ).existsSync(),
        isTrue,
      );
    },
  );

  test(
    'interactive defaults create a conservative application config',
    () async {
      final project = _project(
        'interactive',
        name: 'interactive_app',
        application: true,
      );
      final prompt = _FakeInitPrompt(['', '', '', '', '', '']);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', project.path]);

      expect(exitCode, 0);
      final config = File(
        p.join(project.path, '.flutter_pruner', 'config.yaml'),
      );
      expect(config.readAsStringSync(), contains('complete: false'));
      expect(
        prompt.transcript,
        allOf(
          contains('Analysis modes:'),
          contains('1) application (default)'),
          contains('2) package'),
          contains('3) package-internal'),
          contains('Select mode [1]:'),
        ),
      );
      expect(prompt.transcript, contains('Use these detected targets? [Y/n]'));
      expect(
        prompt.transcript,
        contains(
          'Have you declared every shipped platform, flavor, entrypoint',
        ),
      );
      expect(
        prompt.transcript,
        contains('Review configuration:\n  Analysis mode: application'),
      );
      expect(prompt.transcript, contains('Write the configuration? [Y/n]'));
    },
  );

  test(
    'interactive package menu exposes every mode and keeps the safe default',
    () async {
      final project = _project('interactive_package', name: 'menu_package');
      final prompt = _FakeInitPrompt(['', '', '', '', '', '']);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', project.path]);

      expect(exitCode, 0);
      final loaded = await ProjectConfig.load(
        File(p.join(project.path, '.flutter_pruner', 'config.yaml')),
        projectRoot: project,
      );
      expect(loaded.analysisMode.wireName, 'package');
      _expectInOrder(prompt.transcript, [
        'Analysis modes:',
        'Select mode [2]:',
        'Review configuration:',
        'Action policy: audit only',
        'Write the configuration? [Y/n]',
      ]);
      expect(
        prompt.transcript,
        allOf(
          contains('1) application'),
          contains('2) package (default)'),
          contains('3) package-internal'),
          contains('Select mode [2]:'),
        ),
      );
    },
  );

  test(
    'interactive package menu validates input and selects package-internal',
    () async {
      final project = _project('interactive_internal', name: 'menu_internal');
      final prompt = _FakeInitPrompt(['9', '3', '', '', 'y', '', '']);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', project.path]);

      expect(exitCode, 0);
      final loaded = await ProjectConfig.load(
        File(p.join(project.path, '.flutter_pruner', 'config.yaml')),
        projectRoot: project,
      );
      expect(loaded.analysisMode.wireName, 'package-internal');
      expect(loaded.targetMatrix.isComplete, isTrue);
      expect(loaded.rootCoverage.internalBoundaryComplete, isTrue);
      expect(loaded.rootCoverage.externalConsumersCovered, isFalse);
      expect(
        prompt.transcript,
        allOf(
          contains(
            'Invalid value: Enter 1, 2, or 3 (application, package, or '
            'package-internal).',
          ),
          contains('Package-internal can produce actionable SAFE findings'),
          contains('Analysis mode: package-internal'),
          contains(
            'Action policy: SAFE can be applied; eligible HIGH requires '
            'confirmation.',
          ),
        ),
      );
    },
  );

  test(
    'interactive package accepts a non-conventional public library path',
    () async {
      final project = _project('custom_barrel', name: 'custom_barrel_package');
      File(
        p.join(project.path, 'lib', 'custom_barrel_package.dart'),
      ).deleteSync();
      File(
        p.join(project.path, 'lib', 'api.dart'),
      ).writeAsStringSync('library api;\n');
      final prompt = _FakeInitPrompt(['3', 'lib/api.dart', '', '', '', '', '']);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', project.path]);

      expect(exitCode, 0);
      final loaded = await ProjectConfig.load(
        File(p.join(project.path, '.flutter_pruner', 'config.yaml')),
        projectRoot: project,
      );
      expect(loaded.analysisMode.wireName, 'package-internal');
      expect(loaded.rootCoverage.publicEntrypoints, ['lib/api.dart']);
      expect(
        prompt.transcript,
        allOf(
          contains('No conventional entrypoint was detected'),
          contains('Default public library cannot be used'),
          contains('Enter another public library path.'),
          contains('Public library path:'),
        ),
      );
    },
  );

  test('interactive cancellation at mode selection writes no state', () async {
    final project = _project(
      'mode_cancelled',
      name: 'mode_cancelled_app',
      application: true,
    );
    final prompt = _FakeInitPrompt([null]);

    final exitCode = await FlutterPrunerCommandRunner(
      initPrompt: prompt,
    ).run(['init', project.path]);

    expect(exitCode, 0);
    expect(
      Directory(p.join(project.path, '.flutter_pruner')).existsSync(),
      isFalse,
    );
    expect(prompt.transcript, contains('Cancelled; no files were written.'));
  });

  test(
    'interactive entrypoint validation reprompts for an outside path',
    () async {
      final project = _project(
        'path_validation',
        name: 'path_validation_app',
        application: true,
      );
      final outside = File(p.join(tempDir.path, 'outside.dart'))
        ..writeAsStringSync('void main() {}\n');
      final prompt = _FakeInitPrompt([
        '',
        'n',
        '',
        '',
        outside.path,
        '',
        '',
        'n',
        'n',
        '',
        '',
        '',
      ]);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', project.path]);

      expect(exitCode, 0);
      expect(
        prompt.transcript,
        contains('Invalid value: entrypoint escapes the project'),
      );
      final loaded = await ProjectConfig.load(
        File(p.join(project.path, '.flutter_pruner', 'config.yaml')),
        projectRoot: project,
      );
      expect(loaded.targetMatrix.targets.single.entrypoint, 'lib/main.dart');
    },
  );

  test('interactive cancellation writes no tool state', () async {
    final project = _project(
      'cancelled',
      name: 'cancelled_app',
      application: true,
    );
    final prompt = _FakeInitPrompt(['', '', '', '', '', 'n']);

    final exitCode = await FlutterPrunerCommandRunner(
      initPrompt: prompt,
    ).run(['init', project.path]);

    expect(exitCode, 0);
    expect(
      Directory(p.join(project.path, '.flutter_pruner')).existsSync(),
      isFalse,
    );
    expect(prompt.transcript, contains('Cancelled; no files were written.'));
  });

  test('interactive replacement defaults to no and preserves bytes', () async {
    final project = _project(
      'replacement',
      name: 'replacement_app',
      application: true,
    );
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('owner bytes\n');
    final prompt = _FakeInitPrompt(['']);

    final exitCode = await FlutterPrunerCommandRunner(
      initPrompt: prompt,
    ).run(['init', project.path]);

    expect(exitCode, 0);
    expect(config.readAsStringSync(), 'owner bytes\n');
    expect(File('${config.path}.bak').existsSync(), isFalse);
  });

  test(
    'explicit interactive mode fails instead of reading a non-terminal',
    () async {
      final project = _project(
        'non_terminal',
        name: 'non_terminal_app',
        application: true,
      );
      final prompt = _FakeInitPrompt(const [], isInteractive: false);

      final exitCode = await FlutterPrunerCommandRunner(
        initPrompt: prompt,
      ).run(['init', '--interactive', project.path]);

      expect(exitCode, 64);
      expect(
        Directory(p.join(project.path, '.flutter_pruner')).existsSync(),
        isFalse,
      );
    },
  );

  test('init suggests the short scan command from project cwd', () async {
    final project = _project(
      'cwd_next',
      name: 'cwd_next_app',
      application: true,
    );

    final result = await Process.run(Platform.resolvedExecutable, [
      p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
      'init',
      '--no-interactive',
    ], workingDirectory: project.path);

    expect(result.exitCode, 0, reason: result.stderr as String);
    expect(result.stdout, contains('Next: flutter_pruner scan'));
    expect(result.stdout, isNot(contains('scan --project')));
  });
}

class _FakeInitPrompt implements InitPrompt {
  _FakeInitPrompt(Iterable<String?> responses, {this.isInteractive = true})
    : _responses = List<String?>.from(responses);

  final List<String?> _responses;
  final StringBuffer _output = StringBuffer();
  var _index = 0;

  String get transcript => _output.toString();

  @override
  final bool isInteractive;

  @override
  String? readLine() =>
      _index < _responses.length ? _responses[_index++] : null;

  @override
  void write(String value) => _output.write(value);

  @override
  void writeln([String value = '']) => _output.writeln(value);
}

Directory _project(
  String directoryName, {
  required String name,
  bool application = false,
}) {
  final project = Directory(p.join(tempDir.path, directoryName))
    ..createSync(recursive: true);
  File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: $name
environment:
  sdk: ^3.9.0
''');
  final entrypoint = File(
    p.join(project.path, 'lib', application ? 'main.dart' : '$name.dart'),
  )..createSync(recursive: true);
  entrypoint.writeAsStringSync('void main() {}\n');
  return project;
}

void _expectInOrder(String value, List<String> fragments) {
  var offset = 0;
  for (final fragment in fragments) {
    final index = value.indexOf(fragment, offset);
    expect(index, greaterThanOrEqualTo(0), reason: 'Missing "$fragment"');
    offset = index + fragment.length;
  }
}
