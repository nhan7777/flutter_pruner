import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../../tool/generate_apply_verification_fixture.dart';

void main() {
  for (final profile in applyVerificationFixtureProfiles.keys) {
    test('generates deterministic $profile coverage contract', () async {
      final output = Directory.systemTemp.createTempSync('apply_fixture_');
      try {
        await generateApplyVerificationFixture(
          profile: profile,
          output: output,
        );
        final config = File(
          p.join(output.path, 'flutter_pruner.yaml'),
        ).readAsStringSync();
        final pubspec = File(
          p.join(output.path, 'pubspec.yaml'),
        ).readAsStringSync();
        final smokeTest = File(p.join(output.path, 'test', 'smoke_test.dart'));
        final testConfig = File(p.join(output.path, 'dart_test.yaml'));
        final contract =
            jsonDecode(
                  File(
                    p.join(output.path, 'fixture-contract.json'),
                  ).readAsStringSync(),
                )
                as Map;
        expect(config, contains('complete: true'));
        expect(config, isNot(contains('verification:')));
        expect(pubspec, contains('sdk: flutter'));
        expect(pubspec, contains('test: any'));
        expect(pubspec, isNot(contains('flutter_test:')));
        expect(smokeTest.existsSync(), isTrue);
        expect(
          smokeTest.readAsStringSync(),
          contains('package:test/test.dart'),
        );
        expect(smokeTest.readAsStringSync(), contains("test('fixture passes'"));
        expect(testConfig.readAsStringSync(), 'platforms: [vm]\n');
        final generatedSources = Directory(
          p.join(output.path, 'lib'),
        ).listSync(recursive: true).whereType<File>();
        expect(
          generatedSources.any(
            (file) => file.readAsStringSync().contains('void _unused'),
          ),
          isTrue,
        );
        if (profile == 'chain-2plus-rounds') {
          final chainSources = generatedSources
              .where((file) => p.basename(file.path).startsWith('chain_'))
              .toList();
          expect(chainSources, hasLength(2));
          expect(
            chainSources.every(
              (file) => file.readAsStringSync().startsWith('library chain_'),
            ),
            isTrue,
          );
        }
        expect(
          contract['expectedUnits'],
          applyVerificationFixtureProfiles[profile]!.units,
        );
        expect(
          contract['expectedRounds'],
          applyVerificationFixtureProfiles[profile]!.rounds,
        );
      } finally {
        output.deleteSync(recursive: true);
      }
    });
  }
}
