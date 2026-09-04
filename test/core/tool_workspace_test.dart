import 'dart:io';

import 'package:flutter_pruner/src/core/project/tool_workspace.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('tool_workspace_test_');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test('anchors generated paths to the selected project', () {
    final workspace = ToolWorkspace(project);

    expect(
      workspace.configFile.path,
      p.join(project.path, '.flutter_pruner', 'config.yaml'),
    );
    expect(
      workspace.quarantineDirectory.path,
      p.join(project.path, '.flutter_pruner', 'quarantine'),
    );
    expect(
      workspace.retainedCleanDirectory.path,
      p.join(
        project.path,
        '.flutter_pruner',
        'quarantine',
        '.clean-retained',
        'v1',
      ),
    );
    expect(
      workspace.resolveReportFile('scan.json').path,
      p.join(project.path, '.flutter_pruner', 'reports', 'scan.json'),
    );
  });

  test('resolves retained clean storage below every selected base', () {
    final workspace = ToolWorkspace(project);
    final selected = workspace.resolveQuarantineDirectory(
      '.flutter_pruner/custom',
    );

    expect(
      workspace.retainedCleanDirectoryFor(selected).path,
      p.join(selected.path, '.clean-retained', 'v1'),
    );
  });

  test('relative report paths cannot escape the tool workspace', () {
    final workspace = ToolWorkspace(project);

    expect(
      () => workspace.resolveReportFile('../outside.json'),
      throwsA(isA<ToolWorkspaceException>()),
    );
  });

  test('relative quarantine overrides stay in managed recovery locations', () {
    final workspace = ToolWorkspace(project);

    expect(
      workspace.resolveQuarantineDirectory('.flutter_pruner/custom').path,
      p.join(project.path, '.flutter_pruner', 'custom'),
    );
    expect(
      () => workspace.resolveQuarantineDirectory('unmanaged-quarantine'),
      throwsA(isA<ToolWorkspaceException>()),
    );
  });

  test('discovers the new config before the legacy config', () {
    final workspace = ToolWorkspace(project);
    workspace.legacyConfigFile.writeAsStringSync('legacy');
    workspace.configFile.parent.createSync(recursive: true);
    workspace.configFile.writeAsStringSync('preferred');

    expect(workspace.discoveredConfigFile.path, workspace.configFile.path);
  });

  test('rejects a symlinked tool workspace that escapes the project', () {
    final outside = Directory.systemTemp.createTempSync(
      'tool_workspace_outside_',
    );
    addTearDown(() {
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    });
    Link(
      p.join(project.path, ToolWorkspace.directoryName),
    ).createSync(outside.path);

    expect(
      () => ToolWorkspace(project).validateManagedLayout(),
      throwsA(isA<ToolWorkspaceException>()),
    );
  });
}
