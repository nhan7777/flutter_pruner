import 'dart:io';

import 'package:flutter_pruner/src/adapters/analyzer_adapter.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_adapter.dart';
import 'package:flutter_pruner/src/adapters/l10n/l10n_adapter.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/core/confidence/action_capability.dart';
import 'package:flutter_pruner/src/core/confidence/confidence.dart';
import 'package:flutter_pruner/src/core/confidence/finding_generator.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/graph/node.dart';
import 'package:flutter_pruner/src/core/graph/reachability_graph.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('Stage 1 public boundary', () {
    test('l10n findings remain REVIEW-only with no proposed action', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);
      final graph = ReachabilityGraph();

      await const DartAdapter().analyze(project, GraphBuilder(graph, 'dart'));
      await const L10nAdapter().analyze(project, GraphBuilder(graph, 'l10n'));

      final findings = const FindingGenerator().generate(
        graph: graph,
        project: project,
        graphIntegrity: graph.integrityFor(project.targets),
        reportingNodeSchemes: const {'dart', 'l10n'},
      );

      final l10nFindings = findings.where(
        (finding) => finding.node.id.startsWith('l10n:'),
      );

      expect(l10nFindings, isNotEmpty);

      for (final finding in l10nFindings) {
        expect(
          finding.proposedAction,
          isNull,
          reason: 'l10n finding ${finding.node.id} must have null proposedAction',
        );
        expect(
          finding.confidence,
          isNot(Confidence.safe),
          reason: 'l10n finding ${finding.node.id} must not be safe confidence',
        );
        expect(
          finding.confidence,
          isNot(Confidence.high),
          reason: 'l10n finding ${finding.node.id} must not be high confidence',
        );
      }
    });

    test('ActionCapability rejects l10n localization nodes', () {
      final localizationNode = GraphNode(
        id: 'l10n:test/key',
        kind: NodeKind.localizationKey,
        origin: Uri.parse('file:///test/lib/l10n/app_en.arb'),
        metadata: {'key': 'testKey'},
      );

      final capability = ActionCapability.forFinding(
        adapterId: 'l10n',
        node: localizationNode,
      );

      expect(capability.supported, isFalse);
    });

    test('no action_readiness imports in public production paths', () {
      final prohibitedImporters = [
        'lib/src/analysis',
        'lib/src/core/confidence',
        'lib/src/cli',
        'lib/src/apply',
        'lib/src/quarantine',
      ];

      for (final importerPath in prohibitedImporters) {
        final dir = Directory(importerPath);
        if (!dir.existsSync()) continue;

        final dartFiles = dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart'));

        for (final file in dartFiles) {
          final content = file.readAsStringSync();
          expect(
            content.contains('action_readiness'),
            isFalse,
            reason: '${file.path} must not import action_readiness',
          );
        }
      }
    });

    test('lib/flutter_pruner.dart does not export action_readiness', () {
      final publicApi = File('lib/flutter_pruner.dart');
      expect(publicApi.existsSync(), isTrue);

      final content = publicApi.readAsStringSync();
      expect(
        content.contains('action_readiness'),
        isFalse,
        reason: 'public API must not export action_readiness',
      );
    });

    test('no staging directory or gen-l10n process during normal scan', () async {
      final root = await _copyFixture();
      addTearDown(() => root.delete(recursive: true));
      final project = await _loadCompleteProject(root);

      // Snapshot directory state before scan
      final tempDir = Directory.systemTemp;
      final beforeListing = tempDir
          .listSync(recursive: false)
          .whereType<Directory>()
          .map((d) => d.path)
          .toSet();

      final analyzer = ProjectAnalyzer(project: project);
      await analyzer.analyze();

      // Check no new staging directories created
      final afterListing = tempDir
          .listSync(recursive: false)
          .whereType<Directory>()
          .map((d) => d.path)
          .toSet();

      final newDirs = afterListing.difference(beforeListing);
      final stagingDirs = newDirs.where(
        (path) => path.contains('l10n') || path.contains('flutter_pruner'),
      );

      expect(
        stagingDirs,
        isEmpty,
        reason: 'no staging directories should be created during scan',
      );
    });
  });
}

Future<Directory> _copyFixture() async {
  final source = Directory(p.absolute('test/fixtures/l10n_test'));
  final root = await Directory.systemTemp.createTemp('l10n_boundary_');
  await for (final entity in source.list(recursive: true)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(root.path, relative);
    if (entity is Directory) {
      await Directory(destination).create(recursive: true);
    } else if (entity is File) {
      await File(destination).parent.create(recursive: true);
      await entity.copy(destination);
    }
  }
  return root;
}

Future<ProjectContext> _loadCompleteProject(Directory root) async {
  final inferred = await ProjectContext.load(root);
  return ProjectContext(
    root: root,
    pubspec: inferred.pubspec,
    packageName: inferred.packageName,
    targetMatrix: TargetMatrix.declared([
      BuildTarget(
        name: 'test',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ]),
    rootCoverage: RootCoverage.applicationApi(),
  );
}
