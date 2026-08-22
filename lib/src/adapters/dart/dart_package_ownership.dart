import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../core/project/generated_dart_path.dart';
import '../../core/project/project_context.dart';

/// Physical ownership of a Dart source visible to the selected analyzer root.
enum DartSourceOwnership {
  /// The source belongs to the package selected for this scan.
  selectedPackage,

  /// The source belongs to a consistently identified different package.
  externalPackage,

  /// Available ownership facts are absent, unreadable, or contradictory.
  unknown,
}

/// Immutable ownership disposition for one physical source path.
final class DartSourceOwner {
  /// Creates an ownership disposition.
  const DartSourceOwner({
    required this.ownership,
    required this.packageName,
    required this.packageRoot,
    required this.reason,
  });

  /// Selected, external, or fail-closed unknown ownership.
  final DartSourceOwnership ownership;

  /// Proven package name, when available.
  final String? packageName;

  /// Canonical absolute package root, when available.
  final String? packageRoot;

  /// Stable explanation for the disposition.
  final String reason;
}

/// Resolves package-config and physical pubspec ownership for Dart sources.
final class DartPackageOwnership {
  DartPackageOwnership._({
    required ProjectContext project,
    required String selectedLexicalRoot,
    required String selectedRoot,
    required List<_PackageRoot> packageRoots,
    required List<_PhysicalPackageRoot> physicalRoots,
    required Set<String> duplicateRoots,
    required String? configurationIssue,
  }) : _project = project,
       _selectedLexicalRoot = selectedLexicalRoot,
       _selectedRoot = selectedRoot,
       _packageRoots = packageRoots,
       _physicalRoots = physicalRoots,
       _duplicateRoots = duplicateRoots,
       _configurationIssue = configurationIssue;

  static final Expando<DartPackageOwnership> _snapshots =
      Expando<DartPackageOwnership>('DartPackageOwnership');

  /// Discovers one immutable ownership snapshot for [project].
  static DartPackageOwnership discover(ProjectContext project) {
    return _snapshots[project] ??= _discover(project);
  }

  static DartPackageOwnership _discover(ProjectContext project) {
    final selectedLexicalRoot = p.normalize(p.absolute(project.root.path));
    final selectedRoot = _canonicalDirectoryPath(project.root.path);
    final configFile = File(
      p.join(project.root.path, '.dart_tool', 'package_config.json'),
    );
    if (!configFile.existsSync()) {
      return DartPackageOwnership._(
        project: project,
        selectedLexicalRoot: selectedLexicalRoot,
        selectedRoot: selectedRoot,
        packageRoots: const [],
        physicalRoots: const [],
        duplicateRoots: const {},
        configurationIssue: 'package configuration is missing',
      );
    }

    try {
      final decoded = jsonDecode(configFile.readAsStringSync());
      if (decoded is! Map<String, Object?> ||
          decoded['configVersion'] != 2 ||
          decoded['packages'] is! List<Object?>) {
        throw const FormatException('invalid package configuration shape');
      }

      final packageRoots = <_PackageRoot>[];
      final names = <String>{};
      for (final value in decoded['packages']! as List<Object?>) {
        if (value is! Map<String, Object?>) {
          throw const FormatException('invalid package entry');
        }
        final name = value['name'];
        final rootUriValue = value['rootUri'];
        final packageUriValue = value['packageUri'];
        if (name is! String ||
            name.isEmpty ||
            rootUriValue is! String ||
            rootUriValue.isEmpty ||
            packageUriValue is! String ||
            packageUriValue.isEmpty ||
            !names.add(name)) {
          throw const FormatException('invalid or duplicate package entry');
        }

        final rootUri = _resolveDirectoryUri(
          configFile.parent.absolute.uri,
          rootUriValue,
        );
        final packageUri = Uri.parse(packageUriValue);
        if (packageUri.hasScheme || packageUri.isAbsolute) {
          throw const FormatException('packageUri must be relative');
        }
        final resolvedPackageUri = rootUri.resolveUri(packageUri);
        if (!resolvedPackageUri.isScheme('file')) {
          throw const FormatException('package roots must use file URIs');
        }

        final rootPath = _canonicalDirectoryPath(rootUri.toFilePath());
        final packagePath = _canonicalDirectoryPath(
          resolvedPackageUri.toFilePath(),
        );
        if (packagePath != rootPath && !p.isWithin(rootPath, packagePath)) {
          throw const FormatException('packageUri escapes its package root');
        }
        packageRoots.add(_PackageRoot(name: name, path: rootPath));
      }

      final countsByRoot = <String, int>{};
      for (final root in packageRoots) {
        countsByRoot.update(root.path, (count) => count + 1, ifAbsent: () => 1);
      }
      final duplicateRoots = {
        for (final entry in countsByRoot.entries)
          if (entry.value > 1) entry.key,
      };
      packageRoots.sort((left, right) {
        final length = right.path.length.compareTo(left.path.length);
        return length != 0 ? length : left.name.compareTo(right.name);
      });
      final physicalSnapshot = _snapshotPhysicalPackageRoots({
        selectedRoot,
        ...packageRoots.map((root) => root.path),
      });
      return DartPackageOwnership._(
        project: project,
        selectedLexicalRoot: selectedLexicalRoot,
        selectedRoot: selectedRoot,
        packageRoots: List.unmodifiable(packageRoots),
        physicalRoots: physicalSnapshot.roots,
        duplicateRoots: Set.unmodifiable(duplicateRoots),
        configurationIssue: physicalSnapshot.issue,
      );
    } on Object {
      return DartPackageOwnership._(
        project: project,
        selectedLexicalRoot: selectedLexicalRoot,
        selectedRoot: selectedRoot,
        packageRoots: const [],
        physicalRoots: const [],
        duplicateRoots: const {},
        configurationIssue: 'package configuration is malformed or unreadable',
      );
    }
  }

  /// Selected project whose ownership is being resolved.
  final ProjectContext _project;
  final String _selectedLexicalRoot;
  final String _selectedRoot;
  final List<_PackageRoot> _packageRoots;
  final List<_PhysicalPackageRoot> _physicalRoots;
  final Set<String> _duplicateRoots;
  final String? _configurationIssue;

  /// Resolves the physical owner of [path] without falling back to containment.
  DartSourceOwner ownerOf(String path) {
    final absolutePath = p.normalize(p.absolute(path));
    final canonicalPath = _canonicalFilePath(absolutePath);
    final lexicalInsideSelected =
        _contains(_selectedLexicalRoot, absolutePath) ||
        _contains(_selectedRoot, absolutePath);
    final canonicalInsideSelected = _contains(_selectedRoot, canonicalPath);
    if (lexicalInsideSelected && !canonicalInsideSelected) {
      return const DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: 'source escapes the selected package through a symlink',
      );
    }
    if (!lexicalInsideSelected && canonicalInsideSelected) {
      return const DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: 'source enters the selected package through a symlink alias',
      );
    }

    final issue = _configurationIssue;
    if (issue != null) {
      return DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: issue,
      );
    }

    final matchingRoots = _packageRoots
        .where((root) => _contains(root.path, canonicalPath))
        .toList(growable: false);
    final configOwner = matchingRoots.firstOrNull;
    if (configOwner != null && _duplicateRoots.contains(configOwner.path)) {
      return const DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: 'multiple packages claim the same package root',
      );
    }

    final searchFloor = _contains(_selectedRoot, canonicalPath)
        ? _selectedRoot
        : configOwner?.path;
    if (searchFloor == null) {
      return const DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: 'source is outside every admitted package root',
      );
    }
    final physicalOwner = _physicalRoots
        .where(
          (root) =>
              _contains(searchFloor, root.path) &&
              _contains(root.path, canonicalPath),
        )
        .firstOrNull;
    if (physicalOwner == null || physicalOwner.name == null) {
      return const DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: null,
        packageRoot: null,
        reason: 'no readable owning pubspec was found',
      );
    }

    final effectiveConfigOwner =
        configOwner != null &&
            configOwner.path != physicalOwner.path &&
            _contains(configOwner.path, physicalOwner.path)
        ? null
        : configOwner;
    if (effectiveConfigOwner == null) {
      if (physicalOwner.name != _project.packageName &&
          _contains(_selectedRoot, physicalOwner.path)) {
        return DartSourceOwner(
          ownership: DartSourceOwnership.externalPackage,
          packageName: physicalOwner.name,
          packageRoot: physicalOwner.path,
          reason: 'nested pubspec establishes an unclaimed external package',
        );
      }
      return DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: physicalOwner.name,
        packageRoot: physicalOwner.path,
        reason: 'package configuration does not claim the physical owner',
      );
    }

    if (effectiveConfigOwner.name != physicalOwner.name ||
        effectiveConfigOwner.path != physicalOwner.path) {
      return DartSourceOwner(
        ownership: DartSourceOwnership.unknown,
        packageName: physicalOwner.name,
        packageRoot: physicalOwner.path,
        reason: 'package configuration conflicts with the nearest pubspec',
      );
    }
    if (physicalOwner.name == _project.packageName) {
      if (physicalOwner.path != _selectedRoot) {
        return DartSourceOwner(
          ownership: DartSourceOwnership.unknown,
          packageName: physicalOwner.name,
          packageRoot: physicalOwner.path,
          reason: 'selected package name is mapped to a different root',
        );
      }
      return DartSourceOwner(
        ownership: DartSourceOwnership.selectedPackage,
        packageName: physicalOwner.name,
        packageRoot: physicalOwner.path,
        reason: 'package configuration and pubspec select this package',
      );
    }
    return DartSourceOwner(
      ownership: DartSourceOwnership.externalPackage,
      packageName: physicalOwner.name,
      packageRoot: physicalOwner.path,
      reason: 'package configuration and pubspec select an external package',
    );
  }

  /// Whether [path] is a non-generated source owned by the selected package.
  bool isSelectedSource(String path) =>
      ownerOf(path).ownership == DartSourceOwnership.selectedPackage &&
      !isGeneratedDartPath(path);

  /// Whether [path] is generated output owned by the selected package.
  bool isSelectedGeneratedSource(String path) =>
      ownerOf(path).ownership == DartSourceOwnership.selectedPackage &&
      isGeneratedDartPath(path);
}

final class _PackageRoot {
  const _PackageRoot({required this.name, required this.path});

  final String name;
  final String path;
}

final class _PhysicalPackageRoot {
  const _PhysicalPackageRoot({required this.name, required this.path});

  final String? name;
  final String path;
}

final class _PhysicalPackageSnapshot {
  const _PhysicalPackageSnapshot({required this.roots, required this.issue});

  final List<_PhysicalPackageRoot> roots;
  final String? issue;
}

_PhysicalPackageSnapshot _snapshotPhysicalPackageRoots(
  Set<String> candidateRoots,
) {
  final orderedCandidates = candidateRoots.toList()
    ..sort((left, right) {
      final length = left.length.compareTo(right.length);
      return length != 0 ? length : left.compareTo(right);
    });
  final scanRoots = <String>[];
  for (final candidate in orderedCandidates) {
    if (scanRoots.any((root) => _contains(root, candidate))) continue;
    scanRoots.add(candidate);
  }

  final physicalByPath = <String, _PhysicalPackageRoot>{};
  try {
    for (final scanRoot in scanRoots) {
      final directory = Directory(scanRoot);
      if (!directory.existsSync()) continue;
      final pending = <Directory>[directory];
      while (pending.isNotEmpty) {
        final current = pending.removeLast();
        final pubspec = File(p.join(current.path, 'pubspec.yaml'));
        if (pubspec.existsSync()) {
          physicalByPath[current.path] = _readPhysicalPackageRoot(
            pubspec,
            current.path,
          );
        }
        for (final entity in current.listSync(followLinks: false)) {
          if (entity is! Directory) continue;
          final basename = p.basename(entity.path);
          if (basename == '.git' ||
              basename == '.dart_tool' ||
              basename == 'build') {
            continue;
          }
          pending.add(entity);
        }
      }
    }
  } on FileSystemException {
    return const _PhysicalPackageSnapshot(
      roots: [],
      issue: 'physical package ownership is unreadable',
    );
  }

  final roots = physicalByPath.values.toList()
    ..sort((left, right) {
      final length = right.path.length.compareTo(left.path.length);
      return length != 0 ? length : left.path.compareTo(right.path);
    });
  return _PhysicalPackageSnapshot(roots: List.unmodifiable(roots), issue: null);
}

_PhysicalPackageRoot _readPhysicalPackageRoot(File pubspec, String root) {
  try {
    final decoded = loadYaml(pubspec.readAsStringSync());
    if (decoded is Map) {
      final name = decoded['name'];
      if (name is String && name.isNotEmpty) {
        return _PhysicalPackageRoot(name: name, path: root);
      }
    }
  } on Object {
    // The unreadable owner is retained in the snapshot and fails closed.
  }
  return _PhysicalPackageRoot(name: null, path: root);
}

Uri _resolveDirectoryUri(Uri base, String value) {
  final parsed = Uri.parse(value);
  final resolved = parsed.hasScheme ? parsed : base.resolveUri(parsed);
  if (!resolved.isScheme('file') || resolved.hasQuery || resolved.hasFragment) {
    throw const FormatException('package root must be a local directory URI');
  }
  final text = resolved.toString();
  return Uri.parse(text.endsWith('/') ? text : '$text/');
}

String _canonicalDirectoryPath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

String _canonicalFilePath(String path) {
  final absolute = p.normalize(p.absolute(path));
  try {
    return p.normalize(File(absolute).resolveSymbolicLinksSync());
  } on FileSystemException {
    return absolute;
  }
}

bool _contains(String root, String path) =>
    p.equals(root, path) || p.isWithin(root, path);
