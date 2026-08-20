import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:flutter_pruner/src/core/project/project_language_version.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync(
      'project_language_version_test_',
    );
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('resolves the lower bound of a caret sdk constraint', () {
    _writePubspec(root, 'sdk: ^3.9.0');

    expect(ProjectLanguageVersion.resolve(root), Version(3, 9, 0));
  });

  test('resolves the lower bound of a ranged sdk constraint', () {
    _writePubspec(root, "sdk: '>=3.5.0 <4.0.0'");

    expect(ProjectLanguageVersion.resolve(root), Version(3, 5, 0));
  });

  test('falls back to the running SDK when no sdk bound is declared', () {
    _writePubspec(root, null);

    expect(ProjectLanguageVersion.resolve(root), _runningSdkLanguageVersion());
  });

  test('falls back to the running SDK when there is no pubspec', () {
    expect(ProjectLanguageVersion.resolve(root), _runningSdkLanguageVersion());
  });

  test('falls back to the running SDK when the pubspec cannot be parsed', () {
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: [\n');

    expect(ProjectLanguageVersion.resolve(root), _runningSdkLanguageVersion());
  });

  test('parses project sources at the project version, not the newest', () {
    _writePubspec(root, 'sdk: ^2.19.0');

    // Records require language 3.0, so a 2.19 project must not parse them.
    final parsed = parseString(
      content: '(int, int) pair() => (1, 2);\n',
      featureSet: ProjectLanguageVersion.featureSetFor(root),
      throwIfDiagnostics: false,
    );

    expect(parsed.errors, isNotEmpty);
  });
}

void _writePubspec(Directory root, String? sdkLine) {
  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: language_version_fixture
${sdkLine == null ? '' : 'environment:\n  $sdkLine'}
''');
}

Version _runningSdkLanguageVersion() {
  final running = Version.parse(Platform.version.split(' ').first);
  return Version(running.major, running.minor, 0);
}
