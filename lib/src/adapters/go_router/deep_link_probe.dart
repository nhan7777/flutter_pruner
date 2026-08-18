import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/project/project_context.dart';

const String _unreadableMarker =
    'autoVerify="true" android.intent.action.VIEW android:scheme '
    'com.apple.developer.associated-domains CFBundleURLSchemes';

/// Whether a route URI can enter the app from outside its Dart call graph.
class DeepLinkEvidence {
  /// Creates deep-link evidence.
  DeepLinkEvidence({required this.enabled, required List<String> sources})
    : sources = List.unmodifiable(sources);

  /// Whether any external route channel was found.
  final bool enabled;

  /// Project-relative declarations or target identifiers that prove it.
  final List<String> sources;
}

/// Detects platform and web deep-link channels.
///
/// The probe decides only whether an external channel exists. It does not try
/// to map a domain or scheme to individual routes.
class DeepLinkProbe {
  DeepLinkProbe._();

  /// Detects deep-link configuration and inherently addressable web targets.
  static DeepLinkEvidence detect(ProjectContext project) {
    final sources = <String>{
      for (final target in project.targets)
        if (target.platform == 'web') 'target:${target.name}:web',
    };

    _scanFiles(
      project,
      'android/app/src',
      matches: (path) => p.basename(path) == 'AndroidManifest.xml',
      declaresDeepLinks: (contents) {
        final hasVerifiedFilter = contents.contains('autoVerify="true"');
        final hasViewAction =
            contents.contains('android.intent.action.VIEW') &&
            contents.contains('android:scheme');
        return hasVerifiedFilter || hasViewAction;
      },
      sources: sources,
    );

    for (final platformRoot in const ['ios', 'macos']) {
      _scanFiles(
        project,
        platformRoot,
        matches: (path) => path.endsWith('.entitlements'),
        declaresDeepLinks: (contents) =>
            contents.contains('com.apple.developer.associated-domains'),
        sources: sources,
      );
      _scanFiles(
        project,
        platformRoot,
        matches: (path) => p.basename(path) == 'Info.plist',
        declaresDeepLinks: (contents) =>
            contents.contains('CFBundleURLSchemes'),
        sources: sources,
      );
    }

    final orderedSources = sources.toList()..sort();
    return DeepLinkEvidence(
      enabled: orderedSources.isNotEmpty,
      sources: orderedSources,
    );
  }

  static void _scanFiles(
    ProjectContext project,
    String relativeRoot, {
    required bool Function(String path) matches,
    required bool Function(String contents) declaresDeepLinks,
    required Set<String> sources,
  }) {
    final directory = Directory(project.resolve(relativeRoot));
    if (!directory.existsSync()) return;

    final entities = <FileSystemEntity>[];
    try {
      entities.addAll(directory.listSync(recursive: true, followLinks: false));
    } on FileSystemException {
      sources.add(relativeRoot);
      return;
    }
    entities.sort((left, right) => left.path.compareTo(right.path));

    for (final entity in entities) {
      if (entity is! File || !matches(entity.path)) continue;
      if (project.pathPolicy.shouldExclude(entity.path)) continue;
      final contents = _read(entity);
      if (declaresDeepLinks(contents)) {
        sources.add(project.relative(entity.path));
      }
    }
  }

  static String _read(File file) {
    try {
      return file.readAsStringSync();
    } on FileSystemException {
      // Unreadable platform configuration is uncertainty, never absence.
      return _unreadableMarker;
    }
  }
}
