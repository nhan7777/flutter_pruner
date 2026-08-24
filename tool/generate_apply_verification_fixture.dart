import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

const applyVerificationFixtureProfiles = <String, ({int units, int rounds})>{
  'control-1x1': (units: 1, rounds: 1),
  'fanout-12x1': (units: 12, rounds: 1),
  'chain-2plus-rounds': (units: 4, rounds: 2),
};

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'profile',
      allowed: applyVerificationFixtureProfiles.keys,
      mandatory: true,
    )
    ..addOption('output', mandatory: true)
    ..addFlag(
      'hydrate',
      negatable: false,
      help: 'Run flutter pub get after generation, outside benchmark timing.',
    );
  final options = parser.parse(arguments);
  final profile = options.option('profile')!;
  final output = Directory(p.absolute(options.option('output')!));
  await generateApplyVerificationFixture(profile: profile, output: output);
  if (options.flag('hydrate')) {
    final result = await Process.run('flutter', const [
      'pub',
      'get',
    ], workingDirectory: output.path);
    if (result.exitCode != 0) {
      stderr
        ..write(result.stdout)
        ..write(result.stderr);
      exitCode = result.exitCode;
      return;
    }
  }
  final expectation = applyVerificationFixtureProfiles[profile]!;
  stdout.writeln(
    'Generated $profile at ${output.path}: '
    'U=${expectation.units}, R=${expectation.rounds}.',
  );
}

Future<void> generateApplyVerificationFixture({
  required String profile,
  required Directory output,
}) async {
  if (!applyVerificationFixtureProfiles.containsKey(profile)) {
    throw ArgumentError.value(profile, 'profile', 'unknown fixture profile');
  }
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError(
      'Output directory must be absent or empty: ${output.path}',
    );
  }
  await output.create(recursive: true);
  final lib = Directory(p.join(output.path, 'lib', 'src'));
  await lib.create(recursive: true);
  await File(p.join(output.path, 'pubspec.yaml')).writeAsString('''
name: flutter_pruner_apply_${profile.replaceAll('-', '_')}
publish_to: none
environment:
  sdk: ^3.9.0
dependencies:
  flutter:
    sdk: flutter
dev_dependencies:
  test: any
''');
  await File(p.join(output.path, 'flutter_pruner.yaml')).writeAsString('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: benchmark
      platform: android
      entrypoint: lib/main.dart
''');
  await File(
    p.join(output.path, 'dart_test.yaml'),
  ).writeAsString('platforms: [vm]\n');
  final testDirectory = Directory(p.join(output.path, 'test'));
  await testDirectory.create();
  await File(p.join(testDirectory.path, 'smoke_test.dart')).writeAsString('''
import 'package:test/test.dart';

void main() {
  test('fixture passes', () {
    expect(1 + 1, 2);
  });
}
''');

  switch (profile) {
    case 'control-1x1':
      await _writeImportedUnits(output, count: 1);
      break;
    case 'fanout-12x1':
      await _writeImportedUnits(output, count: 12);
      break;
    case 'chain-2plus-rounds':
      await File(
        p.join(output.path, 'lib', 'main.dart'),
      ).writeAsString('void main() {}\n');
      for (var index = 0; index < 2; index++) {
        await File(p.join(lib.path, 'chain_$index.dart')).writeAsString('''
library chain_$index;

void _unusedChain$index() {}
''');
      }
      break;
  }
  await File(p.join(output.path, 'fixture-contract.json')).writeAsString(
    '{"profile":"$profile",'
    '"expectedUnits":${applyVerificationFixtureProfiles[profile]!.units},'
    '"expectedRounds":${applyVerificationFixtureProfiles[profile]!.rounds}}\n',
  );
}

Future<void> _writeImportedUnits(Directory output, {required int count}) async {
  final imports = StringBuffer();
  final calls = StringBuffer();
  for (var index = 0; index < count; index++) {
    imports.writeln("import 'src/unit_$index.dart';");
    calls.writeln('  retained$index();');
    await File(
      p.join(output.path, 'lib', 'src', 'unit_$index.dart'),
    ).writeAsString('''
void retained$index() {}
void _unused$index() {}
''');
  }
  await File(
    p.join(output.path, 'lib', 'main.dart'),
  ).writeAsString('$imports\nvoid main() {\n$calls}\n');
}
