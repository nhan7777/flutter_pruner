import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

/// Resolves the Dart language version an analysed project's own sources are
/// written for.
///
/// Parsing must never use `FeatureSet.latestLanguageVersion()`. That is the
/// newest version `package:analyzer` knows about, which runs ahead of the
/// released SDK, so a syntax-affecting feature enabled there rejects sources
/// that are valid for the project. Primary constructors are the current
/// example: with them enabled, `final` on a formal parameter — valid Dart, and
/// what the `prefer_final_parameters` lint asks for — becomes a syntax error.
final class ProjectLanguageVersion {
  ProjectLanguageVersion._();

  /// Feature set for parsing sources owned by the project at [projectRoot].
  static FeatureSet featureSetFor(Directory projectRoot) =>
      _featureSet(resolve(projectRoot));

  /// Feature set for a project whose `pubspec.yaml` is already parsed.
  static FeatureSet featureSetForPubspec(Map<dynamic, dynamic> pubspec) =>
      _featureSet(_declaredLanguageVersion(pubspec) ?? runningSdkVersion);

  /// The language version sources at [projectRoot] are written for.
  ///
  /// Falls back to the language version of the SDK running this tool when the
  /// project declares no usable `environment.sdk` bound.
  static Version resolve(Directory projectRoot) {
    final file = File(p.join(projectRoot.path, 'pubspec.yaml'));
    if (!file.existsSync()) return runningSdkVersion;
    Object? parsed;
    try {
      parsed = loadYaml(file.readAsStringSync());
    } catch (_) {
      return runningSdkVersion;
    }
    if (parsed is! Map) return runningSdkVersion;
    return _declaredLanguageVersion(parsed) ?? runningSdkVersion;
  }

  /// Language version of the SDK executing this tool.
  static Version get runningSdkVersion {
    try {
      final running = Version.parse(Platform.version.split(' ').first);
      return Version(running.major, running.minor, 0);
    } catch (_) {
      // Matches this package's declared minimum SDK.
      return Version(3, 9, 0);
    }
  }

  static FeatureSet _featureSet(Version languageVersion) =>
      FeatureSet.fromEnableFlags2(
        sdkLanguageVersion: languageVersion,
        flags: const [],
      );

  static Version? _declaredLanguageVersion(Map<dynamic, dynamic> pubspec) {
    final environment = pubspec['environment'];
    if (environment is! Map) return null;
    final sdk = environment['sdk'];
    if (sdk is! String) return null;
    try {
      final constraint = VersionConstraint.parse(sdk);
      if (constraint is! VersionRange) return null;
      final min = constraint.min;
      if (min == null) return null;
      // A language version is major.minor; the patch component is irrelevant.
      return Version(min.major, min.minor, 0);
    } on FormatException {
      return null;
    }
  }
}
