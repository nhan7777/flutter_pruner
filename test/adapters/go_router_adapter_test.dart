import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/go_router/route_inventory.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Future<ProjectContext> loadFixture() =>
    ProjectContext.load(Directory(p.absolute('test/fixtures/go_router_test')));

void main() {
  group('RouteInventory', () {
    test('composes full paths for nested and top-level routes', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      expect(inventory.byNodeId.values.map((entry) => entry.fullPath).toSet(), {
        '/',
        '/details',
        '/orphan',
        '/dead',
        '/settings',
        '/shell-child',
        '/flags/:code',
      });
    });

    test('indexes routes that declare a name', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      expect(
        inventory.nodeIdByNameKey['route:go_router_test:#name=details'],
        'route:go_router_test:/details',
      );
      expect(
        inventory.nodeIdByNameKey.containsKey(
          'route:go_router_test:#name=orphan',
        ),
        isFalse,
      );
    });

    test('records a project-relative origin and location', () async {
      final project = await loadFixture();
      final inventory = await RouteInventory.discover(
        project,
        workspace: DartAnalysisWorkspace(project),
      );

      final dead = inventory.byNodeId['route:go_router_test:/dead']!;
      expect(project.relative(dead.origin.toFilePath()), 'lib/main.dart');
      expect(dead.location, startsWith('lib/main.dart:'));
    });
  });
}
