import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/graph/build_condition.dart';
import '../core/project/project_source_path.dart';

/// One discovery ambiguity that requires an owner decision.
class InitDiscoveryIssue {
  /// Creates an issue and the yes/no question that resolves it.
  const InitDiscoveryIssue({
    required this.message,
    required this.resolution,
    this.ownerResolvable = true,
  });

  /// Evidence that prevents an automatic completeness claim.
  final String message;

  /// Question whose `Yes` answer confirms the issue is intentionally excluded.
  final String resolution;

  /// Whether an explicit owner confirmation can clear this issue.
  final bool ownerResolvable;
}

/// Conservative project facts proposed by the interactive `init` wizard.
class InitDiscovery {
  /// Creates immutable discovery output.
  const InitDiscovery({required this.targets, required this.issues});

  /// Concrete target tuples, never a platform/entrypoint Cartesian product.
  final List<BuildTarget> targets;

  /// Conflicts or stale references that an owner must resolve.
  final List<InitDiscoveryIssue> issues;
}

/// Discovers concrete Flutter application target tuples from native metadata.
class InitTargetDiscovery {
  /// Creates a discovery service for [projectRoot].
  const InitTargetDiscovery(this.projectRoot);

  /// Selected project root.
  final Directory projectRoot;

  static const _platforms = [
    'android',
    'ios',
    'web',
    'macos',
    'linux',
    'windows',
  ];

  /// Returns target suggestions and unresolved discovery evidence.
  InitDiscovery discoverApplication() {
    final issues = <InitDiscoveryIssue>[];
    final targets = <BuildTarget>[];
    final nativeMappings = <String, Map<String, String>>{
      'android': _androidMappings(),
      'ios': _iosMappings(),
    };
    final existingEntrypoints = _existingApplicationEntrypoints();
    final detectedPlatforms = _platforms
        .where(
          (platform) =>
              Directory(p.join(projectRoot.path, platform)).existsSync(),
        )
        .toList(growable: false);
    final platforms = detectedPlatforms.isEmpty
        ? const ['android']
        : detectedPlatforms;

    for (final platform in platforms) {
      final mappings = nativeMappings[platform] ?? const <String, String>{};
      if (mappings.isNotEmpty) {
        for (final entry in mappings.entries) {
          final normalized = _validatedEntrypoint(
            entry.value,
            issues: issues,
            evidence: '$platform flavor ${entry.key}',
          );
          if (normalized == null) continue;
          targets.add(
            BuildTarget(
              name: _uniqueName(targets, '$platform-${entry.key}'),
              platform: platform,
              flavor: entry.key,
              entrypoint: normalized,
            ),
          );
        }
        continue;
      }
      for (final entrypoint in existingEntrypoints) {
        final flavor = _flavorFromEntrypoint(entrypoint);
        targets.add(
          BuildTarget(
            name: _uniqueName(targets, '$platform-${flavor ?? 'default'}'),
            platform: platform,
            flavor: flavor,
            entrypoint: entrypoint,
          ),
        );
      }
    }

    final mappedEntrypoints = targets
        .map((target) => target.entrypoint)
        .toSet();
    for (final entrypoint in existingEntrypoints) {
      if (mappedEntrypoints.contains(entrypoint)) continue;
      issues.add(
        InitDiscoveryIssue(
          message:
              '$entrypoint exists but no native build target references it.',
          resolution: 'Is $entrypoint intentionally not shipped?',
        ),
      );
    }
    _addMissingEntrypointIssues(existingEntrypoints, issues);
    _addFlavorNamingIssues(nativeMappings, issues);
    _addConditionalSourceIssue(issues);

    targets.sort((left, right) => left.name.compareTo(right.name));
    return InitDiscovery(
      targets: List.unmodifiable(targets),
      issues: List.unmodifiable(issues),
    );
  }

  Map<String, String> _androidMappings() {
    final candidates = [
      File(p.join(projectRoot.path, 'android', 'app', 'build.gradle')),
      File(p.join(projectRoot.path, 'android', 'app', 'build.gradle.kts')),
    ];
    final file = candidates
        .where((candidate) => candidate.existsSync())
        .firstOrNull;
    if (file == null) return const {};
    final mappings = <String, String>{};
    final lines = file.readAsLinesSync();
    var depth = 0;
    int? flavorsDepth;
    int? flavorDepth;
    String? currentFlavor;
    for (final line in lines) {
      final trimmed = line.trim();
      if (flavorsDepth == null &&
          RegExp(r'^productFlavors\b').hasMatch(trimmed) &&
          trimmed.contains('{')) {
        flavorsDepth = depth + 1;
      } else if (flavorsDepth != null &&
          currentFlavor == null &&
          depth == flavorsDepth) {
        final flavorMatch = RegExp(
          r'^(?:create\(["\x27]([^"\x27]+)["\x27]\)|([A-Za-z_][\w-]*))\s*\{',
        ).firstMatch(trimmed);
        if (flavorMatch != null) {
          currentFlavor = flavorMatch.group(1) ?? flavorMatch.group(2);
          flavorDepth = depth + 1;
        }
      }
      if (currentFlavor != null) {
        final targetMatch = RegExp(
          r'flutter\.target\s*(?:=\s*)?["\x27]([^"\x27]+)["\x27]',
        ).firstMatch(trimmed);
        if (targetMatch != null) {
          mappings[currentFlavor] = targetMatch.group(1)!;
        }
      }

      depth += _braceDelta(line);
      if (flavorDepth != null && depth < flavorDepth) {
        currentFlavor = null;
        flavorDepth = null;
      }
      if (flavorsDepth != null && depth < flavorsDepth) flavorsDepth = null;
    }
    return mappings;
  }

  Map<String, String> _iosMappings() {
    final directory = Directory(
      p.join(
        projectRoot.path,
        'ios',
        'Runner.xcodeproj',
        'xcshareddata',
        'xcschemes',
      ),
    );
    if (!directory.existsSync()) return const {};
    final mappings = <String, String>{};
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.xcscheme')) continue;
      final match = RegExp(
        r'argument\s*=\s*["\x27]-t\s+([^"\x27\s]+)',
      ).firstMatch(entity.readAsStringSync());
      if (match == null) continue;
      final flavor = p.basenameWithoutExtension(entity.path);
      mappings[flavor] = match.group(1)!;
    }
    return mappings;
  }

  List<String> _existingApplicationEntrypoints() {
    final lib = Directory(p.join(projectRoot.path, 'lib'));
    if (!lib.existsSync()) return const [];
    final result = <String>[];
    for (final entity in lib.listSync()) {
      if (entity is! File) continue;
      final basename = p.basename(entity.path);
      if (!RegExp(r'^main(?:_[A-Za-z0-9_-]+)?\.dart$').hasMatch(basename)) {
        continue;
      }
      try {
        result.add(
          ProjectSourcePath.validate(
            projectRoot,
            entity.path,
            field: 'detected application entrypoint',
            kind: ProjectSourceKind.applicationEntrypoint,
            allowAbsoluteInput: true,
          ),
        );
      } on ProjectSourcePathException {
        continue;
      }
    }
    result.sort();
    return result;
  }

  String? _validatedEntrypoint(
    String path, {
    required List<InitDiscoveryIssue> issues,
    required String evidence,
  }) {
    try {
      return ProjectSourcePath.validate(
        projectRoot,
        path,
        field: '$evidence entrypoint',
        kind: ProjectSourceKind.applicationEntrypoint,
        allowAbsoluteInput: true,
      );
    } on ProjectSourcePathException catch (error) {
      issues.add(
        InitDiscoveryIssue(
          message: error.message,
          resolution: 'Is the $evidence target no longer supported?',
        ),
      );
      return null;
    }
  }

  void _addMissingEntrypointIssues(
    List<String> existing,
    List<InitDiscoveryIssue> issues,
  ) {
    final references = <String>{};
    final files = [
      File(p.join(projectRoot.path, '.vscode', 'launch.json')),
      File(p.join(projectRoot.path, 'README.md')),
    ];
    for (final file in files) {
      if (!file.existsSync()) continue;
      for (final match in RegExp(
        r'lib/main(?:_[A-Za-z0-9_-]+)?\.dart',
      ).allMatches(file.readAsStringSync())) {
        references.add(match.group(0)!);
      }
    }
    for (final reference in references.difference(existing.toSet())) {
      issues.add(
        InitDiscoveryIssue(
          message:
              '$reference is referenced by project metadata but is missing.',
          resolution: 'Is the $reference reference stale and not shipped?',
        ),
      );
    }
  }

  void _addFlavorNamingIssues(
    Map<String, Map<String, String>> mappings,
    List<InitDiscoveryIssue> issues,
  ) {
    final nativeFlavors = mappings.values.expand((map) => map.keys).toSet();
    if (!nativeFlavors.contains('production')) return;
    final readme = File(p.join(projectRoot.path, 'README.md'));
    if (!readme.existsSync() ||
        !RegExp(r'--flavor\s+prod\b').hasMatch(readme.readAsStringSync())) {
      return;
    }
    issues.add(
      const InitDiscoveryIssue(
        message:
            'Project documentation uses flavor "prod" while native metadata '
            'uses "production".',
        resolution: 'Is "production" the canonical shipped flavor?',
      ),
    );
  }

  void _addConditionalSourceIssue(List<InitDiscoveryIssue> issues) {
    final lib = Directory(p.join(projectRoot.path, 'lib'));
    if (!lib.existsSync()) return;
    for (final entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final contents = entity.readAsStringSync();
      if (RegExp(r'\b(?:import|export)\s+[^;]+\s+if\s*\(').hasMatch(contents)) {
        issues.add(
          const InitDiscoveryIssue(
            message:
                'Conditional Dart imports/exports require target-aware graph '
                'coverage that is not implemented yet.',
            resolution:
                'Keep coverage incomplete until conditional branches are '
                'modelled?',
            ownerResolvable: false,
          ),
        );
        return;
      }
    }
  }

  String? _flavorFromEntrypoint(String entrypoint) {
    final basename = p.posix.basenameWithoutExtension(entrypoint);
    if (basename == 'main') return null;
    return basename.startsWith('main_') ? basename.substring(5) : null;
  }

  String _uniqueName(List<BuildTarget> existing, String preferred) {
    final names = existing.map((target) => target.name).toSet();
    if (!names.contains(preferred)) return preferred;
    var suffix = 2;
    while (names.contains('$preferred-$suffix')) {
      suffix++;
    }
    return '$preferred-$suffix';
  }

  int _braceDelta(String line) =>
      '{'.allMatches(line).length - '}'.allMatches(line).length;
}

extension<T> on Iterable<T> {
  T? get firstOrNull {
    final iterator = this.iterator;
    return iterator.moveNext() ? iterator.current : null;
  }
}
