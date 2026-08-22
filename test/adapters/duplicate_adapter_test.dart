import 'dart:io';

import 'package:flutter_pruner/flutter_pruner.dart';
import 'package:flutter_pruner/src/adapters/duplicate/duplicate_adapter.dart';
import 'package:flutter_pruner/src/analysis/project_analyzer.dart';
import 'package:flutter_pruner/src/apply/mode_apply_policy.dart';
import 'package:test/test.dart';

void main() {
  group('DuplicateAdapter', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('duplicate_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<ProjectContext> createProject({
      required Map<String, String> files,
      String? pubspecContent,
    }) async {
      final libDir = Directory('${tempDir.path}/lib');
      await libDir.create(recursive: true);

      for (final entry in files.entries) {
        final file = File('${tempDir.path}/${entry.key}');
        await file.parent.create(recursive: true);
        await file.writeAsString(entry.value);
      }

      final pubspecFile = File('${tempDir.path}/pubspec.yaml');
      await pubspecFile.writeAsString(
        pubspecContent ??
            '''
name: test_project
version: 1.0.0
environment:
  sdk: ^3.9.0
publish_to: none
''',
      );

      return ProjectContext.load(tempDir);
    }

    test('reports duplicate group when 2+ files are identical', () async {
      final project = await createProject(
        files: {
          'lib/a.txt': 'identical content',
          'lib/b.txt': 'identical content',
          'lib/c.txt': 'identical content',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      expect(node.metadata['fileCount'], 3);
      expect(node.metadata['paths'], hasLength(3));
      expect(node.metadata['paths'], contains('lib/a.txt'));
      expect(node.metadata['paths'], contains('lib/b.txt'));
      expect(node.metadata['paths'], contains('lib/c.txt'));
      expect(node.displayName, '3 identical files');
      expect(node.sizeBytes, isNotNull);
      expect(node.sizeBytes! > 0, isTrue);
    });

    test('does not report unique files', () async {
      final project = await createProject(
        files: {
          'lib/a.txt': 'unique content A',
          'lib/b.txt': 'unique content B',
          'lib/c.txt': 'unique content C',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, isEmpty);
    });

    test('hashes only files that collide by size', () async {
      final project = await createProject(
        files: {'lib/one.txt': '1', 'lib/two.txt': '22'},
      );
      final hashedPaths = <String>[];
      final adapter = DuplicateAdapter(
        fileDigestComputer: (file) async {
          hashedPaths.add(project.relative(file.path));
          return file.path;
        },
      );

      await adapter.analyze(
        project,
        GraphBuilder(ReachabilityGraph(), 'duplicates'),
      );

      expect(hashedPaths, isNot(contains('lib/one.txt')));
      expect(hashedPaths, isNot(contains('lib/two.txt')));
    });

    test('excludes generated files', () async {
      final project = await createProject(
        files: {
          'lib/model.g.dart': 'generated code',
          'lib/copy.g.dart': 'generated code',
          'lib/freezed.freezed.dart': 'freezed generated',
          'lib/copy.freezed.dart': 'freezed generated',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, isEmpty);
    });

    test('handles empty files correctly', () async {
      final project = await createProject(
        files: {'lib/empty1.txt': '', 'lib/empty2.txt': ''},
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      expect(node.metadata['fileCount'], 2);
      expect(node.metadata['sizePerFile'], 0);
      expect(node.sizeBytes, 0);
    });

    test('calculates waste as (N-1) × fileSize', () async {
      final project = await createProject(
        files: {
          'lib/dup1.txt': 'X' * 100,
          'lib/dup2.txt': 'X' * 100,
          'lib/dup3.txt': 'X' * 100,
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      expect(node.metadata['fileCount'], 3);
      expect(node.metadata['sizePerFile'], 100);
      expect(node.sizeBytes, 200);
    });

    test('node ID uses package name and hash prefix', () async {
      final project = await createProject(
        files: {'lib/a.txt': 'content', 'lib/b.txt': 'content'},
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      expect(node.id, startsWith('duplicate:test_project:'));
      expect(node.id.length, 'duplicate:test_project:'.length + 12);
    });

    test('stores full SHA-256 hash in node', () async {
      final project = await createProject(
        files: {'lib/a.txt': 'test content', 'lib/b.txt': 'test content'},
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      expect(node.sha256, isNotNull);
      expect(node.sha256!.length, 64);
      expect(RegExp(r'^[a-f0-9]{64}$').hasMatch(node.sha256!), isTrue);
    });

    test('sorts paths in metadata for stable output', () async {
      final project = await createProject(
        files: {
          'lib/z.txt': 'content',
          'lib/a.txt': 'content',
          'lib/m.txt': 'content',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      final node = nodes.first;
      final paths = node.metadata['paths'] as List;

      expect(paths, ['lib/a.txt', 'lib/m.txt', 'lib/z.txt']);
    });

    test('appliesTo returns true for all projects', () async {
      final project = await createProject(
        files: {'lib/main.dart': 'void main() {}'},
      );
      final adapter = const DuplicateAdapter();
      expect(adapter.appliesTo(project), isTrue);
    });

    test('handles files in subdirectories', () async {
      final project = await createProject(
        files: {
          'lib/ui/widgets/button.dart': 'widget code',
          'lib/legacy/widgets/button.dart': 'widget code',
          'assets/docs/readme.txt': 'docs',
          'assets/backup/readme.txt': 'docs',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(2));
    });

    test('excludes build and tool directories', () async {
      final project = await createProject(
        files: {
          'lib/a.txt': 'content',
          'lib/b.txt': 'content',
          'build/app.dill': 'build output',
          'build/copy.dill': 'build output',
          '.dart_tool/package_config.json': '{}',
          '.dart_tool/copy.json': '{}',
        },
      );

      final graph = ReachabilityGraph();
      final adapter = const DuplicateAdapter();

      await adapter.analyze(project, GraphBuilder(graph, 'duplicates'));

      final nodes = graph.nodes.where((n) => n.kind == NodeKind.duplicateGroup);
      expect(nodes, hasLength(1));

      final node = nodes.first;
      final paths = node.metadata['paths'] as List;
      expect(paths, ['lib/a.txt', 'lib/b.txt']);
      expect(paths.any((p) => p.toString().contains('build')), isFalse);
      expect(paths.any((p) => p.toString().contains('.dart_tool')), isFalse);
    });

    test('excludes quarantine and agent-owned files', () async {
      final project = await createProject(
        files: {
          'lib/a.txt': 'content',
          'lib/b.txt': 'content',
          '.flutter_pruner/reports/scan.json': 'tool only',
          '.flutter_pruner/reports/copy.json': 'tool only',
          '.flutter_pruner_quarantine/run/snapshot.txt': 'quarantine only',
          '.flutter_pruner_quarantine/run/copy.txt': 'quarantine only',
          '.agent/notes/one.txt': 'agent only',
          '.agent/notes/two.txt': 'agent only',
        },
      );

      final graph = ReachabilityGraph();
      await const DuplicateAdapter().analyze(
        project,
        GraphBuilder(graph, 'duplicates'),
      );

      final nodes = graph.nodesOfKind(NodeKind.duplicateGroup).toList();
      expect(nodes, hasLength(1));
      expect(nodes.single.metadata['paths'], ['lib/a.txt', 'lib/b.txt']);
      expect(
        project.pathPolicy.snapshot().byReason.keys,
        containsAll([
          'directory:.flutter_pruner',
          'directory:.flutter_pruner_quarantine',
          'directory:.agent',
        ]),
      );
    });

    test('adapter-only project analysis reports duplicate findings', () async {
      final project = await createProject(
        files: {'lib/a.txt': 'same', 'lib/b.txt': 'same'},
      );

      final snapshot = await ProjectAnalyzer(
        project: project,
        only: {'duplicates'},
      ).analyze();

      expect(snapshot.findings, hasLength(1));
      expect(snapshot.findings.single.reportingAdapterId, 'duplicates');
      expect(snapshot.findings.single.node.id, startsWith('duplicate:'));
    });

    test(
      'freezes isolated duplicate fingerprints against the full subset',
      () async {
        final project = await createProject(
          files: {
            'lib/a.txt': 'same duplicate payload',
            'lib/b.txt': 'same duplicate payload',
            'lib/unique.txt': 'unique payload',
          },
        );

        final full = await ProjectAnalyzer(project: project).analyze();
        final isolated = await ProjectAnalyzer(
          project: project,
          only: {'duplicates'},
        ).analyze();

        const expectedFingerprints = <String>[
          'duplicate:test_project:eb54f6701061\u0000duplicates\u0000PRN-DUP-001\u0000REVIEW\u0000false',
        ];

        expect(isolated.adapterIds, ['duplicates']);
        expect(isolated.findings, hasLength(expectedFingerprints.length));
        expect(
          isolated.findings.every(
            (finding) => finding.reportingAdapterId == 'duplicates',
          ),
          isTrue,
        );
        expect(
          _findingFingerprints(isolated.findings, project),
          expectedFingerprints,
        );
        expect(
          _findingFingerprints(
            isolated.findings.where(
              (finding) => finding.reportingAdapterId == 'duplicates',
            ),
            project,
          ),
          expectedFingerprints,
        );
        expect(
          _findingFingerprints(
            full.findings.where(
              (finding) => finding.reportingAdapterId == 'duplicates',
            ),
            project,
          ),
          _findingFingerprints(isolated.findings, project),
        );
        expect(
          isolated.findings.every(
            (finding) =>
                finding.confidence.name == 'review' &&
                finding.proposedAction == null &&
                !ModeApplyPolicy.allows(project.analysisMode, finding),
          ),
          isTrue,
        );
      },
    );
  });
}

List<String> _findingFingerprints(
  Iterable<Finding> findings,
  ProjectContext project,
) =>
    findings
        .map(
          (finding) => [
            finding.node.id,
            finding.reportingAdapterId,
            finding.ruleId,
            finding.confidence.label,
            ModeApplyPolicy.allows(project.analysisMode, finding),
          ].join('\u0000'),
        )
        .toList()
      ..sort();
