import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../../core/project/project_context.dart';

/// Inventory of all assets discovered in the project and its dependencies.
class AssetInventory {
  AssetInventory._();

  /// Assets from the main package, keyed by logical key.
  final Map<String, AssetEntry> assets = {};

  /// Assets from package dependencies (protected).
  final List<AssetEntry> packageAssets = [];

  /// Discovers all assets from pubspecs and disk.
  static Future<AssetInventory> discover(ProjectContext project) async {
    final inventory = AssetInventory._();

    // 1. Discover main package assets
    await inventory._discoverMainPackageAssets(project);

    // 2. Discover resolution variants for all assets
    await inventory._discoverResolutionVariants(project);

    // 3. Discover package assets from dependencies
    await inventory._discoverPackageAssets(project);

    return inventory;
  }

  Future<void> _discoverMainPackageAssets(ProjectContext project) async {
    final flutterSection = project.flutterSection;
    final assetDeclarations = flutterSection['assets'];

    if (assetDeclarations is! List) return;

    for (final entry in assetDeclarations) {
      if (entry is String) {
        await _processAssetDeclaration(project, entry, hasTransformers: false);
      } else if (entry is Map) {
        final path = entry['path'];
        if (path is String) {
          await _processAssetDeclaration(
            project,
            path,
            hasTransformers: entry['transformers'] != null,
          );
        }
      }
    }
  }

  Future<void> _processAssetDeclaration(
    ProjectContext project,
    String path, {
    required bool hasTransformers,
  }) async {
    if (path.endsWith('/')) {
      // Directory declaration - only direct children
      final dir = Directory(project.resolve(path));
      if (!dir.existsSync()) return;

      await for (final entity in dir.list(followLinks: false)) {
        if (project.pathPolicy.shouldExcludeTraversalEntry(entity)) continue;
        if (entity is File) {
          final basename = p.basename(entity.path);
          final logicalKey = path + basename;
          await _addAssetEntry(
            project,
            logicalKey,
            entity,
            hasTransformers,
            declaredByDirectory: true,
          );
        }
      }
    } else {
      // Single file
      final file = File(project.resolve(path));
      if (file.existsSync()) {
        await _addAssetEntry(
          project,
          path,
          file,
          hasTransformers,
          declaredByDirectory: false,
        );
      }
    }
  }

  Future<void> _addAssetEntry(
    ProjectContext project,
    String logicalKey,
    File file,
    bool hasTransformers, {
    required bool declaredByDirectory,
  }) async {
    final sizeBytes = await file.length();
    final sha256Hash = await _computeSha256(file);

    assets[logicalKey] = AssetEntry(
      logicalKey: logicalKey,
      sourceUri: file.uri,
      package: project.packageName,
      sizeBytes: sizeBytes,
      sha256: sha256Hash,
      hasTransformers: hasTransformers,
      declaredByDirectory: declaredByDirectory,
      variants: [],
    );
  }

  Future<void> _discoverResolutionVariants(ProjectContext project) async {
    for (final entry in assets.values.toList()) {
      final assetFile = File.fromUri(entry.sourceUri);
      final parentDir = assetFile.parent;
      final basename = p.basename(assetFile.path);

      final variantDirs =
          parentDir
              .listSync(followLinks: false)
              .whereType<Directory>()
              .where(
                (directory) => RegExp(
                  r'^\d+(?:\.\d+)?x$',
                ).hasMatch(p.basename(directory.path)),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final variantDir in variantDirs) {
        final ratio = double.tryParse(
          p.basename(variantDir.path).replaceFirst(RegExp(r'x$'), ''),
        );
        if (ratio == null) continue;
        final variantFile = File(p.join(variantDir.path, basename));
        if (variantFile.existsSync()) {
          final sizeBytes = await variantFile.length();
          final sha256Hash = await _computeSha256(variantFile);

          entry.variants.add(
            VariantEntry(
              ratio: ratio,
              sourceUri: variantFile.uri,
              sizeBytes: sizeBytes,
              sha256: sha256Hash,
            ),
          );
        }
      }
    }
  }

  Future<void> _discoverPackageAssets(ProjectContext project) async {
    final packageConfigFile = File(
      p.join(project.root.path, '.dart_tool', 'package_config.json'),
    );

    if (!packageConfigFile.existsSync()) return;

    try {
      final configJson = jsonDecode(await packageConfigFile.readAsString());
      if (configJson is! Map) return;

      final packages = configJson['packages'];
      if (packages is! List) return;

      for (final pkg in packages) {
        if (pkg is! Map) continue;

        final packageName = pkg['name'] as String?;
        final rootUri = pkg['rootUri'] as String?;
        if (packageName == null || rootUri == null) continue;
        if (packageName == project.packageName) continue;

        // Resolve package root
        final packageRoot = _resolvePackageRoot(project.root.path, rootUri);

        await _discoverPackageAssetsFromPubspec(packageName, packageRoot);
      }
    } catch (e) {
      // Ignore package config errors
    }
  }

  Directory _resolvePackageRoot(String projectRoot, String rootUri) {
    if (rootUri.startsWith('file://')) {
      return Directory(Uri.parse(rootUri).toFilePath());
    } else {
      final dartToolPath = p.join(projectRoot, '.dart_tool');
      return Directory(p.normalize(p.join(dartToolPath, rootUri)));
    }
  }

  Future<void> _discoverPackageAssetsFromPubspec(
    String packageName,
    Directory packageRoot,
  ) async {
    final pubspecFile = File(p.join(packageRoot.path, 'pubspec.yaml'));
    if (!pubspecFile.existsSync()) return;

    try {
      final pubspecContent = await pubspecFile.readAsString();
      final pubspec = loadYaml(pubspecContent);
      if (pubspec is! Map) return;

      final flutter = pubspec['flutter'];
      if (flutter is! Map) return;

      final assetsList = flutter['assets'];
      if (assetsList is! List) return;

      for (final assetPath in assetsList) {
        if (assetPath is! String) continue;

        final logicalKey = 'packages/$packageName/$assetPath';
        final assetFile = File(p.join(packageRoot.path, assetPath));

        if (assetFile.existsSync()) {
          final sizeBytes = await assetFile.length();
          final sha256Hash = await _computeSha256(assetFile);

          final entry = AssetEntry(
            logicalKey: logicalKey,
            sourceUri: assetFile.uri,
            package: packageName,
            sizeBytes: sizeBytes,
            sha256: sha256Hash,
            hasTransformers: false,
            declaredByDirectory: false,
            variants: [],
          );

          packageAssets.add(entry);
        }
      }
    } catch (e) {
      // Ignore errors parsing dependency pubspecs
    }
  }

  Future<String> _computeSha256(File file) async =>
      (await sha256.bind(file.openRead()).first).toString();
}

/// A declared asset with its source location and metadata.
class AssetEntry {
  /// Creates an asset entry.
  AssetEntry({
    required this.logicalKey,
    required this.sourceUri,
    required this.package,
    required this.sizeBytes,
    required this.sha256,
    required this.hasTransformers,
    required this.declaredByDirectory,
    required this.variants,
  });

  /// The logical key used in code (e.g., 'assets/logo.png').
  final String logicalKey;

  /// Source file URI on disk.
  final Uri sourceUri;

  /// Package name this asset belongs to.
  final String package;

  /// Size in bytes on disk.
  final int sizeBytes;

  /// SHA-256 hash of file contents.
  final String sha256;

  /// Whether this asset has build-time transformers.
  final bool hasTransformers;

  /// Whether a parent directory declaration bundles this asset.
  final bool declaredByDirectory;

  /// Resolution variants (1.5x, 2.0x, 3.0x, 4.0x).
  final List<VariantEntry> variants;

  /// Total source bytes for the base asset and every resolution variant.
  int get familySizeBytes =>
      sizeBytes +
      variants.fold(0, (total, variant) => total + variant.sizeBytes);

  /// Node ID for this asset.
  String get nodeId => 'asset:$package/$logicalKey';
}

/// A resolution variant (1.5x, 2.0x, etc.) of an asset.
class VariantEntry {
  /// Creates a variant entry.
  VariantEntry({
    required this.ratio,
    required this.sourceUri,
    required this.sizeBytes,
    required this.sha256,
  });

  /// Device pixel ratio (1.5, 2.0, 3.0, or 4.0).
  final double ratio;

  /// Source file URI on disk.
  final Uri sourceUri;

  /// Size in bytes on disk.
  final int sizeBytes;

  /// SHA-256 hash of file contents.
  final String sha256;

  /// Node ID for this variant, derived from parent asset.
  String nodeId(AssetEntry parent) {
    final logicalKey = parent.logicalKey;
    final dir = p.dirname(logicalKey);
    final basename = p.basename(logicalKey);
    final variantPath = dir == '.'
        ? '${ratio}x/$basename'
        : '$dir/${ratio}x/$basename';
    return 'asset:${parent.package}/$variantPath';
  }
}
