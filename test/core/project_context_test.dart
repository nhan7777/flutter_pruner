import 'dart:io';

import 'package:flutter_pruner/src/core/graph/build_condition.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory project;

  setUp(() {
    project = Directory.systemTemp.createTempSync('project_context_test_');
    File(p.join(project.path, 'pubspec.yaml')).writeAsStringSync('''
name: coverage_test
environment:
  sdk: ^3.9.0
''');
    final mainFile = File(p.join(project.path, 'lib', 'main.dart'));
    mainFile.parent.createSync(recursive: true);
    mainFile.writeAsStringSync('void main() {}\n');
  });

  tearDown(() {
    if (project.existsSync()) project.deleteSync(recursive: true);
  });

  test(
    'no config keeps exploratory targets but marks coverage incomplete',
    () async {
      final context = await ProjectContext.load(project);

      expect(context.targetMatrix.status, TargetMatrixStatus.inferredDefault);
      expect(context.rootCoverage.mode, RootCoverageMode.inferred);
      expect(context.analysisCoverageComplete, isFalse);
      expect(context.targets.single.entrypoint, 'lib/main.dart');
    },
  );

  test('valid application config declares complete coverage', () async {
    _writeConfig(project, complete: true);

    final context = await ProjectContext.load(project);

    expect(context.targetMatrix.status, TargetMatrixStatus.declaredComplete);
    expect(context.rootCoverage.mode, RootCoverageMode.applicationEntrypoints);
    expect(context.analysisCoverageComplete, isTrue);
  });

  test('non-application API context requires explicit root coverage', () {
    final context = ProjectContext(
      root: project,
      pubspec: const {'name': 'coverage_test'},
      packageName: 'coverage_test',
      analysisMode: AnalysisMode.packageInternal,
      targets: [
        BuildTarget(
          name: 'package',
          platform: 'android',
          entrypoint: 'lib/coverage_test.dart',
        ),
      ],
    );

    expect(context.targetMatrix.isComplete, isTrue);
    expect(context.rootCoverage.mode, RootCoverageMode.inferred);
    expect(context.rootCoverage.internalBoundaryComplete, isFalse);
    expect(context.analysisCoverageComplete, isFalse);
    expect(context.rootCoverage.issues, contains(contains('packageInternal')));
  });

  test('incompatible explicit root coverage is downgraded', () {
    for (final coverage in [
      RootCoverage.applicationApi(),
      RootCoverage(
        mode: RootCoverageMode.inferred,
        complete: true,
        source: 'invalid inference',
      ),
    ]) {
      final context = ProjectContext(
        root: project,
        pubspec: const {'name': 'coverage_test'},
        packageName: 'coverage_test',
        analysisMode: AnalysisMode.packageInternal,
        targets: [
          BuildTarget(
            name: 'package',
            platform: 'android',
            entrypoint: 'lib/coverage_test.dart',
          ),
        ],
        rootCoverage: coverage,
      );

      expect(context.rootCoverage.mode, RootCoverageMode.inferred);
      expect(context.analysisCoverageComplete, isFalse);
      expect(context.rootCoverage.issues, contains(contains('incompatible')));
    }
  });

  test('snapshots direct collection inputs and nested configuration', () {
    final assetPaths = <Object?>['assets/original.png'];
    final pubspec = <dynamic, dynamic>{
      'name': 'coverage_test',
      'dependencies': <dynamic, dynamic>{'flutter': 'sdk'},
      'flutter': <dynamic, dynamic>{'assets': assetPaths},
    };
    final targets = [
      BuildTarget(
        name: 'android',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ];
    final arguments = ['analyze', '--fatal-infos'];
    final commands = [
      VerificationCommand(
        id: 'analyze',
        executable: 'dart',
        arguments: arguments,
      ),
    ];
    final context = ProjectContext(
      root: project,
      pubspec: pubspec,
      packageName: 'coverage_test',
      targets: targets,
      verificationPolicy: VerificationPolicy(commands: commands),
    );

    (pubspec['dependencies'] as Map)['flutter'] = 'mutated';
    assetPaths.add('assets/late.png');
    targets.clear();
    arguments.add('mutated');
    commands.clear();

    expect(context.hasDependency('flutter'), isTrue);
    expect(context.dependencies, {'flutter'});
    expect(context.flutterSection['assets'], ['assets/original.png']);
    expect(context.targets, hasLength(1));
    expect(context.verificationPolicy.commands, hasLength(1));
    expect(context.verificationPolicy.commands.single.arguments, [
      'analyze',
      '--fatal-infos',
    ]);
    expect(() => context.pubspec['late'] = true, throwsUnsupportedError);
    expect(
      () => (context.flutterSection['assets'] as List).add('assets/late.png'),
      throwsUnsupportedError,
    );
    expect(() => context.dependencies.add('late'), throwsUnsupportedError);
    expect(() => context.targets.clear(), throwsUnsupportedError);
    expect(
      () => context.verificationPolicy.commands.clear(),
      throwsUnsupportedError,
    );
    expect(
      () => context.verificationPolicy.commands.single.arguments.add('late'),
      throwsUnsupportedError,
    );
  });

  test('load snapshots additional excluded paths', () async {
    final report = p.join(project.path, 'generated-report.json');
    final exclusions = [report];
    final context = await ProjectContext.load(
      project,
      additionalExcludedPaths: exclusions,
    );

    exclusions.clear();

    expect(context.pathPolicy.shouldExclude(report), isTrue);
  });

  test('discovers config inside the tool workspace', () async {
    final config = File(p.join(project.path, '.flutter_pruner', 'config.yaml'));
    config.parent.createSync(recursive: true);
    _writeConfig(project, complete: true, file: config);

    final context = await ProjectContext.load(project);

    expect(context.targetMatrix.status, TargetMatrixStatus.declaredComplete);
    expect(context.targetMatrix.source, config.path);
  });

  test('partial target matrix remains incomplete', () async {
    _writeConfig(project, complete: false);

    final context = await ProjectContext.load(project);

    expect(context.targetMatrix.status, TargetMatrixStatus.declaredPartial);
    expect(context.analysisCoverageComplete, isFalse);
  });

  test('conditional imports cap declared-complete coverage', () async {
    File(p.join(project.path, 'lib', 'conditional.dart')).writeAsStringSync(
      "import 'io.dart' if (dart.library.html) 'web.dart';\n",
    );
    _writeConfig(project, complete: true);

    final context = await ProjectContext.load(project);

    expect(context.targetMatrix.status, TargetMatrixStatus.declaredPartial);
    expect(context.analysisCoverageComplete, isFalse);
    expect(
      context.targetMatrix.issues,
      contains(contains('conditional Dart imports/exports')),
    );
  });

  test(
    'conditional imports in configured non-lib entrypoints cap coverage',
    () async {
      final binMain = File(p.join(project.path, 'bin', 'main.dart'));
      binMain.parent.createSync(recursive: true);
      binMain.writeAsStringSync(
        "import 'helper.dart';\n"
        'void main() {}\n',
      );
      File(p.join(project.path, 'bin', 'helper.dart')).writeAsStringSync(
        "import 'io.dart' if (dart.library.html) 'web.dart';\n",
      );
      File(p.join(project.path, 'bin', 'io.dart')).writeAsStringSync('');
      File(p.join(project.path, 'bin', 'web.dart')).writeAsStringSync('');
      File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: command
      platform: linux
      entrypoint: bin/main.dart
''');

      final context = await ProjectContext.load(project);

      expect(context.targetMatrix.status, TargetMatrixStatus.declaredPartial);
      expect(context.analysisCoverageComplete, isFalse);
      expect(
        context.targetMatrix.issues,
        contains(contains('conditional Dart imports/exports')),
      );
    },
  );

  test(
    'conditional imports in relative entrypoint closure cap coverage',
    () async {
      final binMain = File(p.join(project.path, 'bin', 'main.dart'));
      binMain.parent.createSync(recursive: true);
      binMain.writeAsStringSync(
        "import '../shared/helper.dart';\n"
        'void main() {}\n',
      );
      final shared = Directory(p.join(project.path, 'shared'))
        ..createSync(recursive: true);
      File(p.join(shared.path, 'helper.dart')).writeAsStringSync(
        "import 'io.dart' if (dart.library.html) 'web.dart';\n",
      );
      File(p.join(shared.path, 'io.dart')).writeAsStringSync('');
      File(p.join(shared.path, 'web.dart')).writeAsStringSync('');
      File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: command
      platform: linux
      entrypoint: bin/main.dart
''');

      final context = await ProjectContext.load(project);

      expect(context.targetMatrix.status, TargetMatrixStatus.declaredPartial);
      expect(context.analysisCoverageComplete, isFalse);
      expect(
        context.targetMatrix.issues,
        contains(contains('conditional Dart imports/exports')),
      );
    },
  );

  test(
    'package completes its internal boundary but not external coverage',
    () async {
      final packageEntry = File(
        p.join(project.path, 'lib', 'coverage_test.dart'),
      )..writeAsStringSync('export \'main.dart\';\n');
      expect(packageEntry.existsSync(), isTrue);
      File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: package
  public_entrypoints:
    - lib/coverage_test.dart
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/coverage_test.dart
''');

      final context = await ProjectContext.load(project);

      expect(context.targetMatrix.isComplete, isTrue);
      expect(context.analysisMode, AnalysisMode.package);
      expect(context.rootCoverage.internalBoundaryComplete, isTrue);
      expect(context.rootCoverage.externalConsumersCovered, isFalse);
      expect(context.rootCoverage.complete, isFalse);
      expect(context.analysisCoverageComplete, isTrue);
    },
  );

  test(
    'loads an argv-only verification policy without shell parsing',
    () async {
      _writeConfig(
        project,
        complete: true,
        verification: '''
verification:
  steps:
    - id: analyze
      argv: [fvm, flutter, analyze, --fatal-infos]
''',
      );

      final context = await ProjectContext.load(project);

      expect(context.verificationPolicy.commands, hasLength(1));
      expect(context.verificationPolicy.commands.single.executable, 'fvm');
      expect(context.verificationPolicy.commands.single.arguments, [
        'flutter',
        'analyze',
        '--fatal-infos',
      ]);
    },
  );

  test('duplicate verification step IDs fail closed', () async {
    _writeConfig(
      project,
      complete: true,
      verification: '''
verification:
  steps:
    - id: verify
      argv: [dart, analyze]
    - id: verify
      argv: [dart, test]
''',
    );

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          contains('step IDs must be unique'),
        ),
      ),
    );
  });

  test('duplicate target names fail before analysis', () async {
    File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: duplicate
      platform: android
      entrypoint: lib/main.dart
    - name: duplicate
      platform: ios
      entrypoint: lib/main.dart
''');

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          contains('must be unique'),
        ),
      ),
    );
  });

  test('unknown config keys fail closed', () async {
    File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
  root_coverge: typo
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
''');

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          contains('unknown key'),
        ),
      ),
    );
  });

  test(
    'package-internal keeps local coverage separate from consumers',
    () async {
      File(
        p.join(project.path, 'lib', 'coverage_test.dart'),
      ).writeAsStringSync("export 'main.dart';\n");
      File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: package-internal
  public_entrypoints:
    - lib/coverage_test.dart
target_matrix:
  complete: true
  targets:
    - name: android
      platform: android
      entrypoint: lib/coverage_test.dart
''');

      final context = await ProjectContext.load(project);

      expect(context.analysisMode, AnalysisMode.packageInternal);
      expect(context.rootCoverage.mode, RootCoverageMode.packageInternal);
      expect(context.analysisCoverageComplete, isTrue);
      expect(context.rootCoverage.internalBoundaryComplete, isTrue);
      expect(context.rootCoverage.externalConsumersCovered, isFalse);
    },
  );

  test('removed root_coverage reports a migration error', () async {
    File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
  root_coverage: application-entrypoints
target_matrix:
  complete: false
  targets: []
''');

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          contains('root_coverage was removed'),
        ),
      ),
    );
  });

  test('removed workspace mode reports the accepted v1 modes', () async {
    File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: workspace
target_matrix:
  complete: false
  targets: []
''');

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          allOf(
            contains('Unsupported analysis.mode: workspace'),
            contains('package-internal'),
          ),
        ),
      ),
    );
  });

  test('application rejects package public entrypoints', () async {
    File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: application
  public_entrypoints:
    - lib/main.dart
target_matrix:
  complete: false
  targets: []
''');

    await expectLater(
      ProjectContext.load(project),
      throwsA(
        isA<ProjectLoadException>().having(
          (error) => error.message,
          'message',
          contains('public_entrypoints is only valid'),
        ),
      ),
    );
  });

  test('both package modes require public entrypoints', () async {
    for (final mode in ['package', 'package-internal']) {
      File(p.join(project.path, 'flutter_pruner.yaml')).writeAsStringSync('''
version: 1
analysis:
  mode: $mode
target_matrix:
  complete: false
  targets: []
''');

      await expectLater(
        ProjectContext.load(project),
        throwsA(
          isA<ProjectLoadException>().having(
            (error) => error.message,
            'message',
            contains('requires analysis.public_entrypoints'),
          ),
        ),
        reason: mode,
      );
    }
  });

  test('an unparseable project source keeps the matrix partial', () async {
    File(
      p.join(project.path, 'lib', 'broken.dart'),
    ).writeAsStringSync('void {\n');
    _writeConfig(project, complete: true);

    final context = await ProjectContext.load(project);

    expect(context.targetMatrix.status, TargetMatrixStatus.declaredPartial);
  });
}

void _writeConfig(
  Directory project, {
  required bool complete,
  String verification = '',
  File? file,
}) {
  (file ?? File(p.join(project.path, 'flutter_pruner.yaml'))).writeAsStringSync(
    '''
version: 1
analysis:
  mode: application
target_matrix:
  complete: $complete
  targets:
    - name: android
      platform: android
      entrypoint: lib/main.dart
$verification
''',
  );
}
