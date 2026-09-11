import 'dart:io';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_evidence_failure.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generated_member_inspector.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';
import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_toolchain.dart';
import 'package:flutter_pruner/src/adapters/l10n/arb_inventory.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

void main() {
  late Directory scratch;
  var fixtureIndex = 0;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync(
      'l10n-generated-member-inspector-test-',
    );
    fixtureIndex = 0;
  });

  tearDown(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  test('inspects only the configured localization output class', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: r'''
abstract class AppLocalizations {
  String get decoy;
}

abstract class CustomStrings {
  String get live;
  String greeting(String name);
}
''',
    );
    File(
      p.join(fixture.project.root.path, 'lib', 'generated', 'decoy.dart'),
    ).writeAsStringSync(r'''
abstract class CustomStrings {
  String get decoy;
}
''');

    final inspection = await _inspect(fixture, {
      'decoy': ArbGeneratedMemberKind.getter,
      'greeting': ArbGeneratedMemberKind.method,
      'live': ArbGeneratedMemberKind.getter,
    });

    expect(inspection.membersByMessageKey, {
      'greeting': ArbGeneratedMemberKind.method,
      'live': ArbGeneratedMemberKind.getter,
    });
    expect(inspection.failures, isEmpty);
    expect(inspection.identity, matches(_sha256Pattern));
  });

  test('reports removed getters and methods that are still present', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: r'''
abstract class CustomStrings {
  String get retained;
  String get removedGetter;
  String removedMethod(int count);
}
''',
    );

    final inspection = await _inspect(fixture, const {
      'removedMethod': ArbGeneratedMemberKind.method,
      'retained': ArbGeneratedMemberKind.getter,
      'removedGetter': ArbGeneratedMemberKind.getter,
    });

    expect(inspection.membersByMessageKey, {
      'removedGetter': ArbGeneratedMemberKind.getter,
      'removedMethod': ArbGeneratedMemberKind.method,
      'retained': ArbGeneratedMemberKind.getter,
    });
    expect(inspection.failures, isEmpty);
  });

  test(
    'distinguishes retained missing members from their actual wrong shape',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String expectedGetter(String value);
  String get expectedMethod;
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'expectedGetter': ArbGeneratedMemberKind.getter,
        'expectedMethod': ArbGeneratedMemberKind.method,
        'missing': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, {
        'expectedGetter': ArbGeneratedMemberKind.method,
        'expectedMethod': ArbGeneratedMemberKind.getter,
      });
      expect(inspection.membersByMessageKey, isNot(contains('missing')));
      expect(inspection.failures, isEmpty);
    },
  );

  test(
    'rejects an ambiguous getter and method identity for one message key',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String get conflicted;
  String conflicted();
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'conflicted': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(inspection, detailCode: 'generated-member-ambiguous');
    },
  );

  test(
    'accepts placeholder methods and binds their exact resolved signature',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String itemCount(int count, {required String noun});
}
''',
        useNamedParameters: true,
      );
      const expected = {'itemCount': ArbGeneratedMemberKind.method};

      final first = await _inspect(fixture, expected);
      fixture.output.writeAsStringSync(
        _withGeneratedLookup(r'''
abstract class CustomStrings {
  String itemCount(num count, {required Object noun});
}
''', nullableGetter: true),
      );
      final second = await _inspect(fixture, expected);

      expect(first.membersByMessageKey, expected);
      expect(second.membersByMessageKey, expected);
      expect(first.failures, isEmpty);
      expect(second.failures, isEmpty);
      expect(second.identity, isNot(first.identity));
      expect(
        second.memberIdentitiesByMessageKey['itemCount'],
        isNot(first.memberIdentitiesByMessageKey['itemCount']),
      );
    },
  );

  test('rejects a non-String generated message return type', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: r'''
abstract class CustomStrings {
  int get live;
}
''',
    );

    final inspection = await _inspect(fixture, const {
      'live': ArbGeneratedMemberKind.getter,
    });

    expect(inspection.membersByMessageKey, isEmpty);
    _expectOnlyFailure(
      inspection,
      detailCode: 'generated-member-shape-invalid',
    );
  });

  test('rejects a generic lookup', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: r'''
import 'build_context.dart';

abstract class CustomStrings {
  static CustomStrings? of<T>(BuildContext context) => null;
  String get live;
}
''',
    );

    final inspection = await _inspect(fixture, const {
      'live': ArbGeneratedMemberKind.getter,
    });

    expect(inspection.membersByMessageKey, isEmpty);
    _expectOnlyFailure(
      inspection,
      detailCode: 'generated-lookup-shape-mismatch',
    );
  });

  test('binds the resolved BuildContext declaration origin', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: r'''
abstract class CustomStrings {
  String get live;
}
''',
    );
    const expected = {'live': ArbGeneratedMemberKind.getter};
    final imported = await _inspect(fixture, expected);

    fixture.output.writeAsStringSync(r'''
class BuildContext {}

abstract class CustomStrings {
  static CustomStrings? of(BuildContext context) => null;
  String get live;
}
''');
    final inLibrary = await _inspect(fixture, expected);

    expect(imported.failures, isEmpty);
    expect(inLibrary.failures, isEmpty);
    expect(imported.lookupIdentity, matches(_sha256Pattern));
    expect(inLibrary.lookupIdentity, matches(_sha256Pattern));
    expect(inLibrary.lookupIdentity, isNot(imported.lookupIdentity));
    expect(inLibrary.identity, isNot(imported.identity));
  });

  test(
    'supports nullable and non-nullable generated lookup differences',
    () async {
      final nullable = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
import 'build_context.dart';

abstract class CustomStrings {
  static CustomStrings? of(BuildContext context) => null;
  String get live;
}
''',
        nullableGetter: true,
      );
      final nonNullable = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
import 'build_context.dart';

abstract class CustomStrings {
  static CustomStrings of(BuildContext context) => throw UnimplementedError();
  String get live;
}
''',
        nullableGetter: false,
      );
      const expected = {'live': ArbGeneratedMemberKind.getter};

      final nullableInspection = await _inspect(nullable, expected);
      final nonNullableInspection = await _inspect(nonNullable, expected);

      expect(nullableInspection.membersByMessageKey, expected);
      expect(nonNullableInspection.membersByMessageKey, expected);
      expect(nullableInspection.failures, isEmpty);
      expect(nonNullableInspection.failures, isEmpty);
      expect(
        nonNullableInspection.identity,
        isNot(nullableInspection.identity),
      );
    },
  );

  for (final mismatch in const [
    (configuredNullable: true, declaredNullable: false),
    (configuredNullable: false, declaredNullable: true),
  ]) {
    test('rejects static of return nullability '
        '${mismatch.declaredNullable} when configuration is '
        '${mismatch.configuredNullable}', () async {
      final questionMark = mismatch.declaredNullable ? '?' : '';
      final returnBody = mismatch.declaredNullable
          ? 'null'
          : 'throw UnimplementedError()';
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source:
            '''
import 'build_context.dart';

abstract class CustomStrings {
  static CustomStrings$questionMark of(BuildContext context) => $returnBody;
  String get live;
}
''',
        nullableGetter: mismatch.configuredNullable,
      );

      final inspection = await _inspect(fixture, const {
        'live': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(
        inspection,
        detailCode: 'generated-lookup-nullability-mismatch',
      );
    });
  }

  test(
    'rejects a missing configured output class with a typed failure',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class DifferentStrings {
  String get live;
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'live': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(
        inspection,
        detailCode: 'configured-output-class-missing',
      );
    },
  );

  test(
    'rejects an ambiguous configured output class with a typed failure',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String get live;
}

abstract class CustomStrings {
  String get live;
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'live': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(
        inspection,
        detailCode: 'configured-output-class-ambiguous',
      );
    },
  );

  test(
    'rejects generated library parse failure without partial members',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String get live => ;
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'live': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(
        inspection,
        detailCode: 'generated-library-parse-failed',
      );
    },
  );

  test(
    'rejects generated library resolution failure without partial members',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
import 'missing_generated_dependency.dart';

abstract class CustomStrings {
  String get live;
}
''',
      );

      final inspection = await _inspect(fixture, const {
        'live': ArbGeneratedMemberKind.getter,
      });

      expect(inspection.membersByMessageKey, isEmpty);
      _expectOnlyFailure(
        inspection,
        detailCode: 'generated-library-resolution-failed',
      );
    },
  );

  test('rejects a missing configured generated library', () async {
    final fixture = await _createFixture(
      scratch,
      fixtureIndex++,
      source: 'abstract class CustomStrings {}\n',
    );
    fixture.output.deleteSync();

    final inspection = await _inspect(fixture, const {
      'live': ArbGeneratedMemberKind.getter,
    });

    expect(inspection.membersByMessageKey, isEmpty);
    _expectOnlyFailure(inspection, detailCode: 'generated-library-missing');
  });

  test(
    'identity is deterministic, root independent, and order independent',
    () async {
      const source = r'''
abstract class CustomStrings {
  String get alpha;
  String beta(int count);
}
''';
      final firstFixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: source,
      );
      final secondFixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: source,
      );

      final first = await _inspect(firstFixture, {
        'beta': ArbGeneratedMemberKind.method,
        'alpha': ArbGeneratedMemberKind.getter,
      });
      final repeated = await _inspect(firstFixture, {
        'alpha': ArbGeneratedMemberKind.getter,
        'beta': ArbGeneratedMemberKind.method,
      });
      final relocated = await _inspect(secondFixture, const {
        'alpha': ArbGeneratedMemberKind.getter,
        'beta': ArbGeneratedMemberKind.method,
      });

      expect(first.identity, repeated.identity);
      expect(first.identity, relocated.identity);
      expect(first.lookupIdentity, repeated.lookupIdentity);
      expect(first.lookupIdentity, relocated.lookupIdentity);
      expect(first.lookupIdentity, matches(_sha256Pattern));
      expect(first.membersByMessageKey.keys, ['alpha', 'beta']);
      expect(first.failures, isEmpty);
    },
  );

  test(
    'inspection values defensively freeze maps, lists, and caller input',
    () async {
      final fixture = await _createFixture(
        scratch,
        fixtureIndex++,
        source: r'''
abstract class CustomStrings {
  String get live;
}
''',
      );
      final expected = <String, ArbGeneratedMemberKind>{
        'live': ArbGeneratedMemberKind.getter,
      };

      final inspection = await _inspect(fixture, expected);
      expected['lateMutation'] = ArbGeneratedMemberKind.method;

      expect(inspection.membersByMessageKey, {
        'live': ArbGeneratedMemberKind.getter,
      });
      expect(
        () => inspection.membersByMessageKey['other'] =
            ArbGeneratedMemberKind.getter,
        throwsUnsupportedError,
      );
      expect(() => inspection.failures.clear(), throwsUnsupportedError);
    },
  );
}

final _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

final class _Fixture {
  const _Fixture({
    required this.project,
    required this.config,
    required this.output,
  });

  final ProjectContext project;
  final L10nGenerationConfig config;
  final File output;
}

Future<_Fixture> _createFixture(
  Directory scratch,
  int index, {
  required String source,
  bool nullableGetter = true,
  bool useNamedParameters = false,
}) async {
  final root = Directory(p.join(scratch.path, 'project-$index'))
    ..createSync(recursive: true);
  final arbDirectory = Directory(p.join(root.path, 'lib', 'l10n'))
    ..createSync(recursive: true);
  final outputDirectory = Directory(p.join(root.path, 'lib', 'generated'))
    ..createSync(recursive: true);
  File(
    p.join(outputDirectory.path, 'build_context.dart'),
  ).writeAsStringSync('abstract class BuildContext {}\n');

  File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('''
name: staged_l10n_fixture
environment:
  sdk: ">=3.9.0 <4.0.0"
dependencies:
  flutter:
    sdk: flutter
flutter:
  generate: true
''');
  File(p.join(root.path, 'l10n.yaml')).writeAsStringSync('''
arb-dir: lib/l10n
template-arb-file: app_en.arb
output-dir: lib/generated
output-localization-file: custom_strings.dart
output-class: CustomStrings
nullable-getter: $nullableGetter
use-named-parameters: $useNamedParameters
synthetic-package: false
format: false
''');
  File(
    p.join(arbDirectory.path, 'app_en.arb'),
  ).writeAsStringSync('{"@@locale":"en","live":"Live"}\n');
  final generatedSource = _withGeneratedLookup(
    source,
    nullableGetter: nullableGetter,
  );
  final output = File(p.join(outputDirectory.path, 'custom_strings.dart'))
    ..writeAsStringSync(generatedSource);

  final project = await ProjectContext.load(root);
  final loaded = await const DefaultL10nGenerationConfigLoader().load(
    project: project,
    toolchain: _toolchain,
  );
  if (loaded case L10nGenerationConfigRejected(:final failures)) {
    fail(
      'unexpected fixture config rejection: '
      '${failures.map((failure) => failure.detailCode).join(', ')}',
    );
  }
  return _Fixture(
    project: project,
    config: (loaded as L10nGenerationConfigReady).config,
    output: output,
  );
}

Future<L10nGeneratedMemberInspection> _inspect(
  _Fixture fixture,
  Map<String, ArbGeneratedMemberKind> expected,
) => const L10nGeneratedMemberInspector().inspect(
  stagedProject: fixture.project,
  config: fixture.config,
  expectedMemberKindsByKey: expected,
);

void _expectOnlyFailure(
  L10nGeneratedMemberInspection inspection, {
  required String detailCode,
}) {
  expect(inspection.failures, hasLength(1));
  final failure = inspection.failures.single;
  expect(failure.code, L10nEvidenceRejectionCode.candidateVerificationFailed);
  expect(failure.stage, 'generated-member-inspection');
  expect(failure.detailCode, detailCode);
  expect(failure.relativePath, 'lib/generated/custom_strings.dart');
}

String _withGeneratedLookup(String source, {required bool nullableGetter}) {
  if (!source.contains('abstract class CustomStrings {') ||
      RegExp(
        r'static\s+CustomStrings\??\s+of(?:\s*<[^>]+>)?\s*\(',
      ).hasMatch(source)) {
    return source;
  }
  final questionMark = nullableGetter ? '?' : '';
  final returnBody = nullableGetter ? 'null' : 'throw UnimplementedError()';
  final import = source.contains('class BuildContext {}')
      ? ''
      : "import 'build_context.dart';\n\n";
  return '$import${source.replaceAll('abstract class CustomStrings {', '''abstract class CustomStrings {
  static CustomStrings$questionMark of(BuildContext context) => $returnBody;''')}';
}

final _toolchain = FlutterMachineIdentity(
  frameworkVersion: Version(3, 41, 5),
  frameworkRevision: '2c9eb20739dfec95e2c74bd3dfa4601b0a8a36aa',
  engineRevision: '4141414141414141414141414141414141414141',
  dartSdkVersion: '3.11.3',
);
