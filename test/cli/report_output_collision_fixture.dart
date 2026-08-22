import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

enum ReportOutputAliasVariant {
  normalizedDirect,
  finalSymlink,
  intermediateSymlink,
  selectedRootSymlink,
}

final class ReportOutputCollisionFixture {
  ReportOutputCollisionFixture._({
    required this.project,
    required this.projectSelectionPath,
    required this.requestedOutputPath,
    required this.source,
    required this.foreignSentinel,
    required this.links,
  }) : _sourceSnapshot = _FileSnapshot.capture(source),
       _foreignSnapshot = _FileSnapshot.capture(foreignSentinel),
       _linkSnapshots = links.map(_LinkSnapshot.capture).toList();

  factory ReportOutputCollisionFixture.create(
    Directory project,
    ReportOutputAliasVariant variant,
  ) {
    final source = File(p.join(project.path, 'lib', 'main.dart'));
    final foreignSentinel = File(p.join(project.path, 'foreign-sentinel.bin'))
      ..writeAsBytesSync(const [0, 1, 2, 3, 254, 255]);
    final links = <Link>[];
    var projectSelectionPath = project.path;
    late final String requestedOutputPath;

    switch (variant) {
      case ReportOutputAliasVariant.normalizedDirect:
        Directory(p.join(project.path, 'lib', 'nested')).createSync();
        requestedOutputPath = p.join(
          project.path,
          'lib',
          'nested',
          '..',
          'main.dart',
        );
      case ReportOutputAliasVariant.finalSymlink:
        final alias = Link(p.join(project.path, 'report-alias.json'))
          ..createSync(foreignSentinel.path);
        links.add(alias);
        requestedOutputPath = alias.path;
      case ReportOutputAliasVariant.intermediateSymlink:
        final alias = Link(p.join(project.path, 'report-parent'))
          ..createSync(source.parent.path);
        links.add(alias);
        requestedOutputPath = p.join(alias.path, 'main.dart');
      case ReportOutputAliasVariant.selectedRootSymlink:
        final alias = Link('${project.path}.selected-root')
          ..createSync(project.path);
        links.add(alias);
        projectSelectionPath = alias.path;
        requestedOutputPath = source.path;
    }

    return ReportOutputCollisionFixture._(
      project: project,
      projectSelectionPath: projectSelectionPath,
      requestedOutputPath: requestedOutputPath,
      source: source,
      foreignSentinel: foreignSentinel,
      links: links,
    );
  }

  final Directory project;
  final String projectSelectionPath;
  final String requestedOutputPath;
  final File source;
  final File foreignSentinel;
  final List<Link> links;
  final _FileSnapshot _sourceSnapshot;
  final _FileSnapshot _foreignSnapshot;
  final List<_LinkSnapshot> _linkSnapshots;

  void expectRetained() {
    _sourceSnapshot.expectRetained(source, label: 'selected source');
    _foreignSnapshot.expectRetained(foreignSentinel, label: 'foreign sentinel');
    for (var index = 0; index < links.length; index++) {
      _linkSnapshots[index].expectRetained(links[index]);
    }
    expect(transactionArtifacts(), isEmpty);
  }

  List<String> transactionArtifacts() {
    final artifacts = <String>[];
    if (!project.existsSync()) return artifacts;
    for (final entity in project.listSync(
      recursive: true,
      followLinks: false,
    )) {
      final relative = p.relative(entity.path, from: project.path);
      final basename = p.basename(entity.path);
      final isQuarantine =
          relative == '.flutter_pruner/quarantine' ||
          p.isWithin('.flutter_pruner/quarantine', relative);
      final isReportTransaction =
          basename.endsWith('.tmp') ||
          basename.endsWith('.previous') ||
          basename.contains('.flutter_pruner.lock');
      final isOperationLock = relative == '.flutter_pruner/operation.lock';
      final isUnexpectedReport = relative.startsWith(
        '.flutter_pruner/reports/',
      );
      if (isQuarantine ||
          isReportTransaction ||
          isOperationLock ||
          isUnexpectedReport) {
        artifacts.add(p.normalize(p.absolute(entity.path)));
      }
    }
    artifacts.sort();
    return artifacts;
  }

  void dispose() {
    for (final link in links.reversed) {
      if (FileSystemEntity.typeSync(link.path, followLinks: false) ==
          FileSystemEntityType.link) {
        link.deleteSync();
      }
    }
  }
}

final class _FileSnapshot {
  const _FileSnapshot({
    required this.bytes,
    required this.mode,
    required this.sha256Digest,
  });

  factory _FileSnapshot.capture(File file) {
    final bytes = file.readAsBytesSync();
    return _FileSnapshot(
      bytes: List.unmodifiable(bytes),
      mode: file.statSync().mode & 0xfff,
      sha256Digest: sha256.convert(bytes).toString(),
    );
  }

  final List<int> bytes;
  final int mode;
  final String sha256Digest;

  void expectRetained(File file, {required String label}) {
    final retainedBytes = file.readAsBytesSync();
    expect(retainedBytes, orderedEquals(bytes), reason: '$label bytes');
    expect(file.statSync().mode & 0xfff, mode, reason: '$label POSIX mode');
    expect(
      sha256.convert(retainedBytes).toString(),
      sha256Digest,
      reason: '$label SHA-256',
    );
  }
}

final class _LinkSnapshot {
  const _LinkSnapshot({
    required this.path,
    required this.target,
    required this.canonicalTarget,
  });

  factory _LinkSnapshot.capture(Link link) => _LinkSnapshot(
    path: p.normalize(p.absolute(link.path)),
    target: link.targetSync(),
    canonicalTarget: p.normalize(link.resolveSymbolicLinksSync()),
  );

  final String path;
  final String target;
  final String canonicalTarget;

  void expectRetained(Link link) {
    expect(p.normalize(p.absolute(link.path)), path);
    expect(
      FileSystemEntity.typeSync(link.path, followLinks: false),
      FileSystemEntityType.link,
      reason: '$path type',
    );
    expect(link.targetSync(), target, reason: '$path target spelling');
    expect(
      p.normalize(link.resolveSymbolicLinksSync()),
      canonicalTarget,
      reason: '$path canonical target',
    );
  }
}
