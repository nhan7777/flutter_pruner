import 'dart:io';

import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('root test discovery excludes fixture subprojects', () {
    final config = loadYaml(File('dart_test.yaml').readAsStringSync());
    expect(config, isA<YamlMap>());
    final rawPaths = (config as YamlMap)['paths'];
    expect(rawPaths, isA<YamlList>());
    final paths = rawPaths as YamlList;
    expect(
      paths.map((value) => value.toString()),
      orderedEquals(const [
        'test/adapters',
        'test/apply',
        'test/benchmark',
        'test/cli',
        'test/core',
        'test/quarantine',
        'test/reporting',
        'test/verification',
        'test/public_api_core_immutability_test.dart',
        'test/public_api_reporting_immutability_test.dart',
      ]),
    );
    expect(
      paths.any((value) => value.toString().startsWith('test/fixtures')),
      isFalse,
    );
  });
}
