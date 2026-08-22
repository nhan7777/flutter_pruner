import 'dart:io';

import 'package:flutter_pruner/src/cli/init_target_discovery.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('init_target_discovery_test_');
    for (final name in ['main.dart', 'main_ci.dart', 'main_uat.dart']) {
      File(p.join(root.path, 'lib', name))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
    }
    File(p.join(root.path, 'android', 'app', 'build.gradle'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
android {
  productFlavors {
    ci {
      flutter.target = "lib/main_ci.dart"
    }
    uat {
      flutter.target = "lib/main_uat.dart"
    }
    production {
      flutter.target = "lib/main.dart"
    }
  }
}
''');
    final schemes = Directory(
      p.join(root.path, 'ios', 'Runner.xcodeproj', 'xcshareddata', 'xcschemes'),
    )..createSync(recursive: true);
    for (final mapping in {
      'ci': 'lib/main_ci.dart',
      'uat': 'lib/main_uat.dart',
      'production': 'lib/main.dart',
    }.entries) {
      File(p.join(schemes.path, '${mapping.key}.xcscheme')).writeAsStringSync(
        '<CommandLineArgument argument="-t ${mapping.value}"/>',
      );
    }
    File(p.join(root.path, 'README.md')).writeAsStringSync('''
flutter run --flavor prod -t lib/main.dart
flutter run --flavor dev -t lib/main_dev.dart
''');
    File(p.join(root.path, '.vscode', 'launch.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"program":"lib/main_staging.dart"}');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('preserves concrete native tuples instead of a Cartesian product', () {
    final discovery = InitTargetDiscovery(root).discoverApplication();

    expect(discovery.targets, hasLength(6));
    expect(
      discovery.targets
          .map(
            (target) =>
                '${target.platform}|${target.flavor}|${target.entrypoint}',
          )
          .toSet(),
      {
        'android|ci|lib/main_ci.dart',
        'android|uat|lib/main_uat.dart',
        'android|production|lib/main.dart',
        'ios|ci|lib/main_ci.dart',
        'ios|uat|lib/main_uat.dart',
        'ios|production|lib/main.dart',
      },
    );
    expect(
      discovery.issues.map((issue) => issue.message),
      containsAll([
        contains('lib/main_dev.dart'),
        contains('lib/main_staging.dart'),
        contains('uses flavor "prod"'),
      ]),
    );
  });

  test(
    'conditional imports are a non-owner-resolvable completeness blocker',
    () {
      File(
        p.join(root.path, 'lib', 'conditional.dart'),
      ).writeAsStringSync("import 'a.dart' if (dart.library.io) 'b.dart';\n");

      final discovery = InitTargetDiscovery(root).discoverApplication();

      expect(
        discovery.issues,
        contains(
          isA<InitDiscoveryIssue>()
              .having(
                (issue) => issue.ownerResolvable,
                'ownerResolvable',
                isFalse,
              )
              .having(
                (issue) => issue.message,
                'message',
                contains('Conditional Dart imports'),
              ),
        ),
      );
    },
  );

  test('resolved SDK condition is syntactically owner-complete', () {
    File(p.join(root.path, 'lib', 'conditional.dart')).writeAsStringSync(
      "import 'a.dart' if (dart.library.io == 'false') 'b.dart';\n",
    );
    File(p.join(root.path, 'lib', 'a.dart')).writeAsStringSync('');
    File(p.join(root.path, 'lib', 'b.dart')).writeAsStringSync('');

    final discovery = InitTargetDiscovery(root).discoverApplication();

    expect(
      discovery.issues.where(
        (issue) => issue.message.contains('Conditional Dart imports'),
      ),
      isEmpty,
    );
  });
}
