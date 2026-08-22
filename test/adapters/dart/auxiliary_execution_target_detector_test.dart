import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:flutter_pruner/src/adapters/dart/auxiliary_execution_target_detector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('G3 AuxiliaryExecutionTargetDetector', () {
    final configured = <BuildTarget>[
      BuildTarget(
        name: 'android-debug',
        platform: 'android',
        flavor: 'debug',
        entrypoint: 'lib/main_debug.dart',
        dartDefines: const {'MODE': 'debug'},
      ),
      BuildTarget(
        name: 'web',
        platform: 'web',
        entrypoint: 'lib/main_web.dart',
      ),
    ];
    late ProjectContext project;
    late AuxiliaryExecutionTargetDetector detector;

    setUp(() {
      project = ProjectContext(
        root: Directory('/project'),
        pubspec: const {'name': 'app'},
        packageName: 'app',
        targets: configured,
      );
      detector = AuxiliaryExecutionTargetDetector(project);
    });

    test('explicit VM and browser tests have closed environments', () async {
      final vmLibrary = await _resolveMetadataLibrary('''
@TestOn('vm')
library;
import 'package:test/test.dart';
void main() {}
''');
      final browserLibrary = await _resolveMetadataLibrary('''
@TestOn('browser')
library;
import 'package:test/test.dart';
void main() {}
''');
      final vm = detector.detectTest(
        relativePath: 'test/vm_test.dart',
        library: vmLibrary,
      );
      final browser = detector.detectTest(
        relativePath: 'test/browser_test.dart',
        library: browserLibrary,
      );

      expect(vm.target.environmentComplete, isTrue);
      expect(vm.target.environmentValues['dart.library.io'], 'true');
      expect(vm.target.environmentValues['dart.library.html'], 'false');
      expect(vm.target.environmentValues['dart.library.ui'], 'false');
      expect(browser.target.environmentComplete, isTrue);
      expect(browser.target.environmentValues['dart.library.io'], 'false');
      expect(browser.target.environmentValues['dart.library.html'], 'true');
      expect(vm.issues, isEmpty);
      expect(browser.issues, isEmpty);
    });

    test('Flutter SDK metadata closes dart.library.ui accurately', () async {
      final flutterProject = ProjectContext(
        root: Directory('/project'),
        pubspec: const {
          'name': 'app',
          'dependencies': {
            'flutter': {'sdk': 'flutter'},
          },
        },
        packageName: 'app',
        targets: configured,
      );
      final flutterDetector = AuxiliaryExecutionTargetDetector(flutterProject);
      final vmLibrary = await _resolveMetadataLibrary('''
@TestOn('vm')
library;
import 'package:test/test.dart';
void main() {}
''');
      final browserLibrary = await _resolveMetadataLibrary('''
@TestOn('browser')
library;
import 'package:test/test.dart';
void main() {}
''');

      final vm = flutterDetector.detectTest(
        relativePath: 'test/vm_test.dart',
        library: vmLibrary,
      );
      final browser = flutterDetector.detectTest(
        relativePath: 'test/browser_test.dart',
        library: browserLibrary,
      );

      expect(vm.target.environmentValues['dart.library.ui'], 'true');
      expect(browser.target.environmentValues['dart.library.ui'], 'true');
    });

    test(
      'unannotated and mixed tests remain explicit incomplete facts',
      () async {
        final unannotated = detector.detectTest(
          relativePath: 'test/default_test.dart',
        );
        final mixedLibrary = await _resolveMetadataLibrary('''
@TestOn('vm || browser')
library;
import 'package:test/test.dart';
void main() {}
''');
        final mixed = detector.detectTest(
          relativePath: 'test/mixed_test.dart',
          library: mixedLibrary,
        );

        for (final detection in [unannotated, mixed]) {
          expect(detection.target.environmentComplete, isFalse);
          expect(detection.issues.single.requiresGlobalBlocker, isFalse);
          expect(detection.target.id, startsWith('aux:test:'));
        }
      },
    );

    test(
      'comments strings malformed unresolved and same-named TestOn stay open',
      () async {
        final adversarialSources = <String>[
          "library;\n// @TestOn('vm')\nvoid main() {}",
          "library;\nconst marker = \"@TestOn('vm')\";\nvoid main() {}",
          '''
@TestOn('vm')
library;
class TestOn {
  const TestOn(String value);
}
void main() {}
''',
          '''
@TestOn('vm')
library;
void main() {}
''',
          '''
@TestOn(selectedPlatform)
library;
import 'package:test/test.dart';
const selectedPlatform = 'vm';
void main() {}
''',
          '''
@TestOn('node')
library;
import 'package:test/test.dart';
void main() {}
''',
          '''
@TestOn('vm || browser')
library;
import 'package:test/test.dart';
void main() {}
''',
        ];

        for (final source in adversarialSources) {
          final library = await _resolveMetadataLibrary(source);
          final detection = detector.detectTest(
            relativePath: 'test/adversarial_test.dart',
            library: library,
          );
          expect(detection.target.environmentComplete, isFalse, reason: source);
        }
      },
    );

    test('tracked project test metadata can close one environment', () async {
      final root = await Directory.systemTemp.createTemp('g3-test-metadata-');
      addTearDown(() => root.deleteSync(recursive: true));
      File(p.join(root.path, 'dart_test.yaml')).writeAsStringSync('''
platforms:
  - chrome
  - firefox
''');
      final configuredProject = ProjectContext(
        root: root,
        pubspec: const {'name': 'app'},
        packageName: 'app',
        targets: configured,
      );

      final detection = AuxiliaryExecutionTargetDetector(
        configuredProject,
      ).detectTest(relativePath: 'test/project_default_test.dart');

      expect(detection.target.environmentComplete, isTrue);
      expect(detection.target.environmentValues['dart.library.html'], 'true');
      expect(detection.issues, isEmpty);
    });

    test('runtime matching preserves full compatible source target', () {
      final detection = detector.detectRuntime(
        callbackIdentity: 'dart:app/lib/callback.dart#worker',
        capability: CallbackBoundaryCapability.dartVm,
      );

      expect(detection.targets, hasLength(1));
      final runtime = detection.targets.single;
      expect(runtime.sourceConfiguredTarget, configured.first);
      expect(runtime.sourceConfiguredTarget!.flavor, 'debug');
      expect(runtime.sourceConfiguredTarget!.entrypoint, 'lib/main_debug.dart');
      expect(runtime.environmentValues['MODE'], 'debug');
      expect(runtime.environmentValues['dart.library.io'], 'true');
      expect(
        detection.targets.any(
          (target) => target.sourceConfiguredTarget?.platform == 'web',
        ),
        isFalse,
      );
    });

    test(
      'runtime identities preserve flavor entrypoint and define variants',
      () {
        final variants = [
          BuildTarget(
            name: 'base',
            platform: 'android',
            flavor: 'prod',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'MODE': 'base'},
          ),
          BuildTarget(
            name: 'flavor',
            platform: 'android',
            flavor: 'staging',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'MODE': 'base'},
          ),
          BuildTarget(
            name: 'entrypoint',
            platform: 'android',
            flavor: 'prod',
            entrypoint: 'lib/main_other.dart',
            dartDefines: const {'MODE': 'base'},
          ),
          BuildTarget(
            name: 'define',
            platform: 'android',
            flavor: 'prod',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'MODE': 'other'},
          ),
        ];
        final variantProject = ProjectContext(
          root: Directory('/project'),
          pubspec: const {'name': 'app'},
          packageName: 'app',
          targets: variants,
        );
        final detection = AuxiliaryExecutionTargetDetector(variantProject)
            .detectRuntime(
              callbackIdentity: 'dart:app/lib/callback.dart#worker',
              capability: CallbackBoundaryCapability.workmanagerMobile,
            );

        expect(detection.targets, hasLength(4));
        expect(
          detection.targets.map((target) => target.id).toSet(),
          hasLength(4),
        );
        expect(
          detection.targets.map((target) => target.sourceConfiguredTarget),
          containsAll(variants),
        );
      },
    );

    test('unsupported or unknown runtime capability remains incomplete', () {
      final webOnly = ProjectContext(
        root: Directory('/project'),
        pubspec: const {'name': 'app'},
        packageName: 'app',
        targets: [configured.last],
      );
      final webDetector = AuxiliaryExecutionTargetDetector(webOnly);

      for (final capability in [
        CallbackBoundaryCapability.dartVm,
        CallbackBoundaryCapability.unknown,
      ]) {
        final detection = webDetector.detectRuntime(
          callbackIdentity: 'dart:app/lib/callback.dart#worker',
          capability: capability,
        );
        expect(detection.targets, hasLength(1));
        expect(detection.targets.single.environmentComplete, isFalse);
        expect(detection.targets.single.sourceConfiguredTarget, isNull);
        expect(detection.issues.single.requiresGlobalBlocker, isTrue);
      }
    });

    test('reserved SDK define conflicts fail closed', () {
      final conflictingProject = ProjectContext(
        root: Directory('/project'),
        pubspec: const {'name': 'app'},
        packageName: 'app',
        targets: [
          BuildTarget(
            name: 'android-conflict',
            platform: 'android',
            entrypoint: 'lib/main.dart',
            dartDefines: const {'dart.library.io': 'false'},
          ),
        ],
      );
      final detection = AuxiliaryExecutionTargetDetector(conflictingProject)
          .detectRuntime(
            callbackIdentity: 'dart:app/lib/callback.dart#worker',
            capability: CallbackBoundaryCapability.ffiNative,
          );

      expect(detection.targets.single.environmentComplete, isFalse);
      expect(detection.issues.single.code, 'reserved-environment-conflict');
    });

    test('external package target is explicit and incomplete', () {
      final detection = detector.detectExternal('lib/app.dart');

      expect(detection.target.domain, AuxiliaryExecutionDomain.external);
      expect(detection.target.environmentComplete, isFalse);
      expect(detection.target.sourceConfiguredTarget, isNull);
      expect(detection.issues.single.requiresGlobalBlocker, isFalse);
    });
  });
}

var _metadataLibrarySequence = 0;

Future<ResolvedLibraryResult> _resolveMetadataLibrary(String source) async {
  final projectRoot = Directory.current;
  final fixtureDirectory = Directory(
    p.join(
      projectRoot.path,
      'test',
      'g3_test_on_tmp_${pid}_${_metadataLibrarySequence++}',
    ),
  )..createSync(recursive: true);
  addTearDown(() {
    if (fixtureDirectory.existsSync()) {
      fixtureDirectory.deleteSync(recursive: true);
    }
  });
  final file = File(p.join(fixtureDirectory.path, 'metadata.dart'))
    ..writeAsStringSync(source);
  final project = ProjectContext(
    root: projectRoot,
    pubspec: const {
      'name': 'flutter_pruner',
      'environment': {'sdk': '^3.9.0'},
    },
    packageName: 'flutter_pruner',
    targets: [
      BuildTarget(
        name: 'test',
        platform: 'android',
        entrypoint: 'lib/flutter_pruner.dart',
      ),
    ],
  );
  final result = await DartAnalysisWorkspace(project).resolveLibrary(file.path);
  if (result is! ResolvedLibraryResult) {
    throw StateError('Metadata fixture did not resolve as a Dart library.');
  }
  return result;
}
