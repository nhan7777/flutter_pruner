import 'dart:convert';
import 'dart:io';

import 'package:analyzer/dart/analysis/results.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/adapters/dart/auxiliary_execution_target_detector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/analysis_mode.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:flutter_pruner/src/core/project/target_matrix.dart';
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

      expect(vm.targets.single.environmentComplete, isTrue);
      expect(vm.targets.single.environmentValues['dart.library.io'], 'true');
      expect(vm.targets.single.environmentValues['dart.library.html'], 'false');
      expect(vm.targets.single.environmentValues['dart.library.ui'], 'false');
      expect(browser.targets.single.environmentComplete, isTrue);
      expect(
        browser.targets.single.environmentValues['dart.library.io'],
        'false',
      );
      expect(
        browser.targets.single.environmentValues['dart.library.html'],
        'true',
      );
      expect(vm.issues, isEmpty);
      expect(browser.issues, isEmpty);
    });

    test('test detection rejects invalid target and issue combinations', () {
      final complete = _completeTestTarget('a');
      final incomplete = _incompleteTestTarget('a');
      const issue = AuxiliaryExecutionTargetDetectionIssue(
        code: 'test-environment-incomplete',
        reason: 'incomplete',
        requiresGlobalBlocker: false,
      );

      expect(
        () => TestAuxiliaryExecutionTargetDetection(targets: const []),
        throwsArgumentError,
      );
      expect(
        () => TestAuxiliaryExecutionTargetDetection(
          targets: [complete, complete],
        ),
        throwsArgumentError,
      );
      expect(
        () => TestAuxiliaryExecutionTargetDetection(targets: [incomplete]),
        throwsArgumentError,
      );
      expect(
        () => TestAuxiliaryExecutionTargetDetection(
          targets: [complete],
          issues: const [issue],
        ),
        throwsArgumentError,
      );
    });

    test('test detection target and issue lists are deeply immutable', () {
      final completeSource = [_completeTestTarget('a')];
      final completeDetection = TestAuxiliaryExecutionTargetDetection(
        targets: completeSource,
      );
      completeSource.clear();

      expect(completeDetection.targets, hasLength(1));
      expect(() => completeDetection.targets.clear(), throwsUnsupportedError);
      expect(completeDetection.issues, isEmpty);
      expect(
        () => completeDetection.issues.add(_testIssue()),
        throwsUnsupportedError,
      );

      final incompleteSource = [_incompleteTestTarget('b')];
      final issueSource = [_testIssue()];
      final incompleteDetection = TestAuxiliaryExecutionTargetDetection(
        targets: incompleteSource,
        issues: issueSource,
      );
      incompleteSource.clear();
      issueSource.clear();

      expect(incompleteDetection.targets, hasLength(1));
      expect(incompleteDetection.issues, hasLength(1));
      expect(
        () => incompleteDetection.targets.add(_completeTestTarget('c')),
        throwsUnsupportedError,
      );
      expect(() => incompleteDetection.issues.clear(), throwsUnsupportedError);
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

      expect(vm.targets.single.environmentValues['dart.library.ui'], 'true');
      expect(
        browser.targets.single.environmentValues['dart.library.ui'],
        'true',
      );
    });

    test('unannotated Flutter unit tests use the Flutter host VM', () {
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

      final detection = AuxiliaryExecutionTargetDetector(
        flutterProject,
      ).detectTest(relativePath: 'test/widget_test.dart');

      expect(detection.targets.single.environmentComplete, isTrue);
      expect(detection.targets.single.id, endsWith(':vm'));
      expect(detection.targets.single.environmentValues, {
        'dart.library.io': 'true',
        'dart.library.html': 'false',
        'dart.library.js_interop': 'false',
        'dart.library.ui': 'true',
      });
      expect(detection.issues, isEmpty);
    });

    group('test_driver exact standalone authority', () {
      late AuxiliaryExecutionTargetDetector flutterDetector;

      setUp(() {
        flutterDetector = AuxiliaryExecutionTargetDetector(
          ProjectContext(
            root: Directory('/project'),
            pubspec: const {
              'name': 'app',
              'dependencies': {
                'flutter': {'sdk': 'flutter'},
              },
            },
            packageName: 'app',
            targets: configured,
          ),
        );
      });

      test(
        'closes exact direct driver imports on the standalone Dart VM',
        () async {
          final resolved = await _resolveAuxiliaryImportLibrary('''
import 'package:integration_test/integration_test_driver_extended.dart';

void main() {}
''');

          final result = flutterDetector.detectTest(
            relativePath: 'test_driver/screenshot_driver.dart',
            library: resolved,
          );

          expect(result.issues, isEmpty);
          expect(result.targets, hasLength(1));
          expect(result.targets.single.environmentValues, {
            'dart.library.io': 'true',
            'dart.library.html': 'false',
            'dart.library.js_interop': 'false',
            'dart.library.ui': 'false',
          });
          expect(result.targets.single.id, endsWith(':driver-vm'));
        },
      );

      test('accepts exact vm metadata for direct driver imports', () async {
        final resolved = await _resolveAuxiliaryImportLibrary('''
@TestOn('vm')
library;

import 'package:test_api/src/backend/configuration/test_on.dart';
import 'package:integration_test/integration_test_driver.dart';

void main() {}
''');

        final result = flutterDetector.detectTest(
          relativePath: 'test_driver/vm_driver.dart',
          library: resolved,
        );

        expect(result.issues, isEmpty);
        expect(result.targets, hasLength(1));
        expect(result.targets.single.environmentValues, {
          'dart.library.io': 'true',
          'dart.library.html': 'false',
          'dart.library.js_interop': 'false',
          'dart.library.ui': 'false',
        });
        expect(result.targets.single.id, endsWith(':driver-vm'));
      });

      test(
        'rejects directory-only driver cases without a recognized direct import',
        () async {
          final resolved = await _resolveAuxiliaryImportLibrary('''
import 'package:integration_test/integration_test.dart';

void main() {}
''');

          final result = flutterDetector.detectTest(
            relativePath: 'test_driver/empty_driver.dart',
            library: resolved,
          );

          _expectIncompleteTestDetection(result);
        },
      );

      test('rejects transitive-only recognized driver imports', () async {
        final resolved = await _resolveAuxiliaryImportLibrary(
          '''
import 'bridge.dart';

void main() {}
''',
          extraFiles: {
            'lib/bridge.dart': '''
import 'package:integration_test/integration_test_driver_extended.dart';
''',
          },
        );

        final result = flutterDetector.detectTest(
          relativePath: 'test_driver/transitive_driver.dart',
          library: resolved,
        );

        _expectIncompleteTestDetection(result);
      });

      test('rejects same-named local driver libraries', () async {
        final resolved = await _resolveAuxiliaryImportLibrary(
          '''
import 'integration_test_driver_extended.dart';

void main() {}
''',
          extraFiles: {
            'lib/integration_test_driver_extended.dart':
                'void localDriverStub() {}\n',
          },
        );

        final result = flutterDetector.detectTest(
          relativePath: 'test_driver/local_name_driver.dart',
          library: resolved,
        );

        _expectIncompleteTestDetection(result);
      });

      test('rejects non-vm explicit test metadata for driver files', () async {
        for (final source in [
          '''
@TestOn('browser')
library;

import 'package:test_api/src/backend/configuration/test_on.dart';
import 'package:integration_test/integration_test_driver.dart';

void main() {}
''',
          '''
@TestOn('vm || browser')
library;

import 'package:test_api/src/backend/configuration/test_on.dart';
import 'package:integration_test/integration_test_driver_extended.dart';

void main() {}
''',
          '''
@TestOn('node')
library;

import 'package:test_api/src/backend/configuration/test_on.dart';
import 'package:flutter_driver/flutter_driver.dart';

void main() {}
''',
        ]) {
          final resolved = await _resolveAuxiliaryImportLibrary(source);
          final result = flutterDetector.detectTest(
            relativePath: 'test_driver/invalid_driver.dart',
            library: resolved,
          );
          _expectIncompleteTestDetection(result);
        }
      });
    });

    group('integration_test exact matrix expansion', () {
      test(
        'integration_test expands an Android/iOS declared-complete matrix exactly',
        () async {
          final configuredTargets = [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
            BuildTarget(
              name: 'ios',
              platform: 'ios',
              entrypoint: 'lib/main.dart',
            ),
          ];
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: configuredTargets,
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/app_test.dart',
            library: resolved,
          );

          expect(result.issues, isEmpty);
          expect(
            result.targets,
            orderedEquals(
              _sortedIntegrationTargets([
                AuxiliaryExecutionTarget(
                  id: _expectedIntegrationTargetId(
                    'integration_test/app_test.dart',
                    configuredTargets.first,
                  ),
                  domain: AuxiliaryExecutionDomain.test,
                  environmentValues: const {
                    'dart.library.io': 'true',
                    'dart.library.html': 'false',
                    'dart.library.js_interop': 'false',
                    'dart.library.ui': 'true',
                  },
                  environmentComplete: true,
                  reason:
                      'Flutter integration test copied from a declared application target',
                  sourceConfiguredTarget: configuredTargets.first,
                ),
                AuxiliaryExecutionTarget(
                  id: _expectedIntegrationTargetId(
                    'integration_test/app_test.dart',
                    configuredTargets.last,
                  ),
                  domain: AuxiliaryExecutionDomain.test,
                  environmentValues: const {
                    'dart.library.io': 'true',
                    'dart.library.html': 'false',
                    'dart.library.js_interop': 'false',
                    'dart.library.ui': 'true',
                  },
                  environmentComplete: true,
                  reason:
                      'Flutter integration test copied from a declared application target',
                  sourceConfiguredTarget: configuredTargets.last,
                ),
              ]),
            ),
          );
        },
      );

      test(
        'integration_test rejects non-application and non-exact Flutter authority',
        () async {
          TargetMatrix completeMatrix() => TargetMatrix(
            targets: [
              BuildTarget(
                name: 'android',
                platform: 'android',
                entrypoint: 'lib/main.dart',
              ),
            ],
            status: TargetMatrixStatus.declaredComplete,
            source: 'fixture',
          );

          final projects = <String, ProjectContext>{
            'package analysis mode': ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              analysisMode: AnalysisMode.package,
              targetMatrix: completeMatrix(),
              rootCoverage: RootCoverage(
                mode: RootCoverageMode.packagePublicApi,
                internalBoundaryComplete: true,
                externalConsumersCovered: true,
                source: 'fixture',
              ),
            ),
            'non-application root coverage': ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: completeMatrix(),
              rootCoverage: RootCoverage(
                mode: RootCoverageMode.inferred,
                internalBoundaryComplete: false,
                externalConsumersCovered: false,
                source: 'fixture',
              ),
            ),
            'flutter_test dev dependency only': ProjectContext(
              root: Directory('/project'),
              pubspec: const {
                'name': 'app',
                'dev_dependencies': {
                  'flutter_test': {'sdk': 'flutter'},
                },
              },
              packageName: 'app',
              targetMatrix: completeMatrix(),
            ),
            'versioned Flutter dependency': ProjectContext(
              root: Directory('/project'),
              pubspec: const {
                'name': 'app',
                'dependencies': {'flutter': '^3.44.0'},
              },
              packageName: 'app',
              targetMatrix: completeMatrix(),
            ),
            'non-Flutter SDK dependency': ProjectContext(
              root: Directory('/project'),
              pubspec: const {
                'name': 'app',
                'dependencies': {
                  'flutter': {'sdk': 'dart'},
                },
              },
              packageName: 'app',
              targetMatrix: completeMatrix(),
            ),
          };
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          for (final entry in projects.entries) {
            final result = AuxiliaryExecutionTargetDetector(entry.value)
                .detectTest(
                  relativePath: 'integration_test/app_test.dart',
                  library: resolved,
                );

            _expectIncompleteTestDetection(result);
            expect(
              result.issues.single.requiresGlobalBlocker,
              isFalse,
              reason: entry.key,
            );
          }
        },
      );

      test(
        'integration_test preserves flavor define and entrypoint variants',
        () async {
          final configuredTargets = [
            BuildTarget(
              name: 'android-staging',
              platform: 'android',
              flavor: 'staging',
              entrypoint: 'lib/main.dart',
              dartDefines: const {'MODE': 'staging'},
            ),
            BuildTarget(
              name: 'android-prod',
              platform: 'android',
              flavor: 'prod',
              entrypoint: 'lib/main.dart',
              dartDefines: const {'MODE': 'prod'},
            ),
          ];
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: configuredTargets,
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/flavored_test.dart',
            library: resolved,
          );

          expect(result.issues, isEmpty);
          expect(result.targets, hasLength(2));
          expect(
            result.targets.map((target) => target.sourceConfiguredTarget),
            {configuredTargets.first, configuredTargets.last},
          );
          expect(
            result.targets.map((target) => target.environmentValues['MODE']),
            {'staging', 'prod'},
          );
          expect(result.targets.map((target) => target.id).toSet(), {
            _expectedIntegrationTargetId(
              'integration_test/flavored_test.dart',
              configuredTargets.first,
            ),
            _expectedIntegrationTargetId(
              'integration_test/flavored_test.dart',
              configuredTargets.last,
            ),
          });
        },
      );

      test(
        'integration_test does not merge equal SDK environments from distinct targets',
        () async {
          final configuredTargets = [
            BuildTarget(
              name: 'android-a',
              platform: 'android',
              flavor: 'staging',
              entrypoint: 'lib/main_a.dart',
            ),
            BuildTarget(
              name: 'android-b',
              platform: 'android',
              flavor: 'prod',
              entrypoint: 'lib/main_b.dart',
            ),
          ];
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: configuredTargets,
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/duplicate_env_test.dart',
            library: resolved,
          );

          expect(result.issues, isEmpty);
          expect(result.targets, hasLength(2));
          expect(
            result.targets.map((target) => target.sourceConfiguredTarget),
            {configuredTargets.first, configuredTargets.last},
          );
          for (final target in result.targets) {
            expect(target.environmentValues, {
              'dart.library.io': 'true',
              'dart.library.html': 'false',
              'dart.library.js_interop': 'false',
              'dart.library.ui': 'true',
            });
          }
        },
      );

      test(
        'integration_test uses exact web SDK values for web application targets',
        () async {
          final configuredTargets = [
            BuildTarget(
              name: 'web',
              platform: 'web',
              entrypoint: 'lib/main_web.dart',
            ),
          ];
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: configuredTargets,
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/web_test.dart',
            library: resolved,
          );

          expect(result.issues, isEmpty);
          expect(result.targets.single.environmentValues, {
            'dart.library.io': 'false',
            'dart.library.html': 'true',
            'dart.library.js_interop': 'true',
            'dart.library.ui': 'true',
          });
        },
      );

      test(
        'integration_test applies vm and browser metadata as matrix filters',
        () async {
          final configuredTargets = [
            BuildTarget(
              name: 'android',
              platform: 'android',
              entrypoint: 'lib/main.dart',
            ),
            BuildTarget(
              name: 'web',
              platform: 'web',
              entrypoint: 'lib/main_web.dart',
            ),
          ];
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: configuredTargets,
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final vmResolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(testOn: 'vm'),
          );
          final browserResolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(testOn: 'browser'),
          );

          final vmResult = detector.detectTest(
            relativePath: 'integration_test/native_test.dart',
            library: vmResolved,
          );
          final browserResult = detector.detectTest(
            relativePath: 'integration_test/browser_test.dart',
            library: browserResolved,
          );

          expect(vmResult.issues, isEmpty);
          expect(
            vmResult.targets.map((target) => target.sourceConfiguredTarget),
            {configuredTargets.first},
          );
          expect(
            vmResult.targets.single.environmentValues['dart.library.ui'],
            'true',
          );
          expect(browserResult.issues, isEmpty);
          expect(
            browserResult.targets.map(
              (target) => target.sourceConfiguredTarget,
            ),
            {configuredTargets.last},
          );
          expect(browserResult.targets.single.environmentValues, {
            'dart.library.io': 'false',
            'dart.library.html': 'true',
            'dart.library.js_interop': 'true',
            'dart.library.ui': 'true',
          });
        },
      );

      test(
        'integration_test rejects mixed metadata instead of falling back to the full matrix',
        () async {
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                  BuildTarget(
                    name: 'web',
                    platform: 'web',
                    entrypoint: 'lib/main_web.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(testOn: 'vm || browser'),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/mixed_test.dart',
            library: resolved,
          );

          _expectIncompleteTestDetection(result);
        },
      );

      test(
        'integration_test rejects non-exact tracked project platform metadata aliases',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'g3-integration-project-platform-alias_${pid}_',
          );
          addTearDown(() => root.deleteSync(recursive: true));
          File(p.join(root.path, 'dart_test.yaml')).writeAsStringSync('''
platforms:
  - chrome
''');
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: root,
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'web',
                    platform: 'web',
                    entrypoint: 'lib/main_web.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/alias_test.dart',
            library: resolved,
          );

          _expectIncompleteTestDetection(result);
        },
      );

      test(
        'integration_test rejects mixed tracked browser metadata aliases',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'g3-integration-project-platform-mixed_${pid}_',
          );
          addTearDown(() => root.deleteSync(recursive: true));
          File(p.join(root.path, 'dart_test.yaml')).writeAsStringSync('''
platforms:
  - chrome
  - firefox
''');
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: root,
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'web',
                    platform: 'web',
                    entrypoint: 'lib/main_web.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/mixed_browser_alias_test.dart',
            library: resolved,
          );

          _expectIncompleteTestDetection(result);
        },
      );

      test(
        'integration_test rejects missing direct imports and incomplete matrices',
        () async {
          final noImport = await _resolveAuxiliaryImportLibrary('''
void main() {}
''');
          final completeDetector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );

          _expectIncompleteTestDetection(
            completeDetector.detectTest(
              relativePath: 'integration_test/no_import_test.dart',
              library: noImport,
            ),
          );

          for (final project in [
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                ],
                status: TargetMatrixStatus.inferredDefault,
                source: 'built-in default',
              ),
            ),
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredPartial,
                source: 'fixture',
              ),
            ),
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: const [],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          ]) {
            _expectIncompleteTestDetection(
              AuxiliaryExecutionTargetDetector(project).detectTest(
                relativePath: 'integration_test/app_test.dart',
                library: await _resolveAuxiliaryImportLibrary(
                  _integrationTestSource(),
                ),
              ),
            );
          }
        },
      );

      test(
        'integration_test rejects unsupported configured platforms',
        () async {
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                  BuildTarget(
                    name: 'fuchsia',
                    platform: 'fuchsia',
                    entrypoint: 'lib/main_fuchsia.dart',
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/unsupported_test.dart',
            library: resolved,
          );

          _expectIncompleteTestDetection(result);
        },
      );

      test('integration_test rejects reserved SDK define conflicts', () async {
        final detector = AuxiliaryExecutionTargetDetector(
          ProjectContext(
            root: Directory('/project'),
            pubspec: _flutterApplicationPubspec,
            packageName: 'app',
            targetMatrix: TargetMatrix(
              targets: [
                BuildTarget(
                  name: 'android',
                  platform: 'android',
                  entrypoint: 'lib/main.dart',
                  dartDefines: const {'dart.library.io': 'false'},
                ),
              ],
              status: TargetMatrixStatus.declaredComplete,
              source: 'fixture',
            ),
          ),
        );
        final resolved = await _resolveAuxiliaryImportLibrary(
          _integrationTestSource(),
        );

        final result = detector.detectTest(
          relativePath: 'integration_test/conflict_test.dart',
          library: resolved,
        );

        expect(result.targets, hasLength(1));
        expect(result.targets.single.environmentComplete, isFalse);
        expect(result.targets.single.id, endsWith(':incomplete'));
        expect(result.issues, hasLength(1));
        expect(result.issues.single.code, 'reserved-environment-conflict');
        expect(result.issues.single.requiresGlobalBlocker, isTrue);
        expect(
          result.issues.single.reason,
          'configured integration target conflicts with SDK-owned '
          'dart.library.io',
        );
      });

      test(
        'integration_test rejects the whole matrix when one configured target is invalid',
        () async {
          final detector = AuxiliaryExecutionTargetDetector(
            ProjectContext(
              root: Directory('/project'),
              pubspec: _flutterApplicationPubspec,
              packageName: 'app',
              targetMatrix: TargetMatrix(
                targets: [
                  BuildTarget(
                    name: 'android',
                    platform: 'android',
                    entrypoint: 'lib/main.dart',
                  ),
                  BuildTarget(
                    name: 'android-conflict',
                    platform: 'android',
                    entrypoint: 'lib/main_conflict.dart',
                    dartDefines: const {'dart.library.ui': 'false'},
                  ),
                ],
                status: TargetMatrixStatus.declaredComplete,
                source: 'fixture',
              ),
            ),
          );
          final resolved = await _resolveAuxiliaryImportLibrary(
            _integrationTestSource(),
          );

          final result = detector.detectTest(
            relativePath: 'integration_test/atomic_failure_test.dart',
            library: resolved,
          );

          expect(result.targets, hasLength(1));
          expect(result.targets.single.id, endsWith(':incomplete'));
          expect(result.targets.single.environmentComplete, isFalse);
          expect(result.targets.single.sourceConfiguredTarget, isNull);
          expect(result.issues, hasLength(1));
          expect(result.issues.single.code, 'reserved-environment-conflict');
          expect(result.issues.single.requiresGlobalBlocker, isTrue);
          expect(
            result.issues.single.reason,
            'configured integration target conflicts with SDK-owned '
            'dart.library.ui',
          );
        },
      );
    });

    test(
      'Patrol tests close only against an explicit complete device matrix',
      () {
        const patrolPubspec = {
          'name': 'app',
          'dependencies': {
            'flutter': {'sdk': 'flutter'},
          },
          'dev_dependencies': {'patrol': '^4.6.1'},
          'patrol': {'test_directory': 'patrol_test'},
        };
        final nativeTargets = [
          BuildTarget(
            name: 'android',
            platform: 'android',
            entrypoint: 'lib/main.dart',
          ),
          BuildTarget(
            name: 'ios',
            platform: 'ios',
            entrypoint: 'lib/main.dart',
          ),
        ];
        final completeNative = ProjectContext(
          root: Directory('/project'),
          pubspec: patrolPubspec,
          packageName: 'app',
          targets: nativeTargets,
        );
        final partialNative = ProjectContext(
          root: Directory('/project'),
          pubspec: patrolPubspec,
          packageName: 'app',
          targetMatrix: TargetMatrix(
            targets: nativeTargets,
            status: TargetMatrixStatus.declaredPartial,
            source: 'test',
          ),
        );
        final nativeAndWeb = ProjectContext(
          root: Directory('/project'),
          pubspec: patrolPubspec,
          packageName: 'app',
          targets: [
            ...nativeTargets,
            BuildTarget(
              name: 'web',
              platform: 'web',
              entrypoint: 'lib/main.dart',
            ),
          ],
        );
        final nativeWithDefines = ProjectContext(
          root: Directory('/project'),
          pubspec: patrolPubspec,
          packageName: 'app',
          targets: [
            BuildTarget(
              name: 'android-defined',
              platform: 'android',
              entrypoint: 'lib/main.dart',
              dartDefines: const {'MODE': 'test'},
            ),
          ],
        );
        final missingPatrolConfig = ProjectContext(
          root: Directory('/project'),
          pubspec: const {
            'name': 'app',
            'dependencies': {
              'flutter': {'sdk': 'flutter'},
            },
            'dev_dependencies': {'patrol': '^4.6.1'},
          },
          packageName: 'app',
          targets: nativeTargets,
        );

        TestAuxiliaryExecutionTargetDetection detect(ProjectContext project) =>
            AuxiliaryExecutionTargetDetector(
              project,
            ).detectTest(relativePath: 'patrol_test/app_regression_test.dart');

        final closed = detect(completeNative);
        expect(closed.targets.single.environmentComplete, isTrue);
        expect(closed.targets.single.id, endsWith(':patrol-native'));
        expect(closed.targets.single.environmentValues, {
          'dart.library.io': 'true',
          'dart.library.html': 'false',
          'dart.library.js_interop': 'false',
          'dart.library.ui': 'true',
        });
        expect(closed.issues, isEmpty);

        for (final open in [
          detect(partialNative),
          detect(nativeAndWeb),
          detect(nativeWithDefines),
          detect(missingPatrolConfig),
        ]) {
          expect(open.targets.single.environmentComplete, isFalse);
          expect(open.issues.single.code, 'test-environment-incomplete');
        }
      },
    );

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
          expect(detection.targets.single.environmentComplete, isFalse);
          expect(detection.issues.single.requiresGlobalBlocker, isFalse);
          expect(detection.targets.single.id, startsWith('aux:test:'));
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
          expect(
            detection.targets.single.environmentComplete,
            isFalse,
            reason: source,
          );
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

      expect(detection.targets.single.environmentComplete, isTrue);
      expect(
        detection.targets.single.environmentValues['dart.library.html'],
        'true',
      );
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

AuxiliaryExecutionTarget _completeTestTarget(String id) =>
    AuxiliaryExecutionTarget(
      id: 'aux:test:$id',
      domain: AuxiliaryExecutionDomain.test,
      environmentValues: const {'dart.library.io': 'true'},
      environmentComplete: true,
      reason: 'complete',
    );

AuxiliaryExecutionTarget _incompleteTestTarget(String id) =>
    AuxiliaryExecutionTarget(
      id: 'aux:test:$id',
      domain: AuxiliaryExecutionDomain.test,
      environmentValues: const {},
      environmentComplete: false,
      reason: 'incomplete',
    );

AuxiliaryExecutionTargetDetectionIssue _testIssue() =>
    const AuxiliaryExecutionTargetDetectionIssue(
      code: 'test-environment-incomplete',
      reason: 'incomplete',
      requiresGlobalBlocker: false,
    );

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

void _expectIncompleteTestDetection(
  TestAuxiliaryExecutionTargetDetection result,
) {
  expect(result.targets, hasLength(1));
  expect(result.targets.single.environmentComplete, isFalse);
  expect(result.targets.single.id, endsWith(':incomplete'));
  expect(result.issues, hasLength(1));
  expect(result.issues.single.code, 'test-environment-incomplete');
  expect(result.issues.single.requiresGlobalBlocker, isFalse);
}

var _auxiliaryImportLibrarySequence = 0;

const _flutterApplicationPubspec = {
  'name': 'app',
  'dependencies': {
    'flutter': {'sdk': 'flutter'},
  },
};

Future<ResolvedLibraryResult> _resolveAuxiliaryImportLibrary(
  String source, {
  Map<String, String> extraFiles = const {},
}) async {
  final root = await Directory.systemTemp.createTemp(
    'g3-aux-driver_${pid}_${_auxiliaryImportLibrarySequence++}_',
  );
  addTearDown(() {
    if (root.existsSync()) {
      root.deleteSync(recursive: true);
    }
  });

  _writeAuxiliaryFixtureFile(root, 'pubspec.yaml', '''
name: aux_driver_fixture
publish_to: none
environment:
  sdk: ^3.9.0
''');
  _writeAuxiliaryFixtureFile(
    root,
    '.dart_tool/package_config.json',
    jsonEncode({
      'configVersion': 2,
      'packages': [
        _packageConfigPackage('aux_driver_fixture', '../'),
        _packageConfigPackage(
          'integration_test',
          '../fake_packages/integration_test/',
        ),
        _packageConfigPackage(
          'flutter_driver',
          '../fake_packages/flutter_driver/',
        ),
        _packageConfigPackage('test_api', '../fake_packages/test_api/'),
      ],
    }),
  );
  _writeAuxiliaryFixtureFile(root, 'lib/driver_case.dart', source);
  _writeAuxiliaryFixtureFile(
    root,
    'fake_packages/integration_test/lib/integration_test_driver.dart',
    'void integrationTestDriver() {}\n',
  );
  _writeAuxiliaryFixtureFile(
    root,
    'fake_packages/integration_test/lib/integration_test_driver_extended.dart',
    'void integrationTestDriverExtended() {}\n',
  );
  _writeAuxiliaryFixtureFile(
    root,
    'fake_packages/integration_test/lib/integration_test.dart',
    'void integrationTestBinding() {}\n',
  );
  _writeAuxiliaryFixtureFile(
    root,
    'fake_packages/flutter_driver/lib/flutter_driver.dart',
    'void flutterDriverBinding() {}\n',
  );
  _writeAuxiliaryFixtureFile(
    root,
    'fake_packages/test_api/lib/src/backend/configuration/test_on.dart',
    '''
class TestOn {
  const TestOn(this.expression);

  final String expression;
}
''',
  );
  for (final entry in extraFiles.entries) {
    _writeAuxiliaryFixtureFile(root, entry.key, entry.value);
  }

  final project = await ProjectContext.load(
    root,
    targets: [
      BuildTarget(
        name: 'test',
        platform: 'android',
        entrypoint: 'lib/main.dart',
      ),
    ],
  );
  final result = await DartAnalysisWorkspace(
    project,
  ).resolveLibrary(p.join(root.path, 'lib', 'driver_case.dart'));
  if (result is! ResolvedLibraryResult) {
    throw StateError(
      'Auxiliary import fixture did not resolve as a Dart library.',
    );
  }
  return result;
}

Map<String, Object?> _packageConfigPackage(String name, String rootUri) => {
  'name': name,
  'rootUri': rootUri,
  'packageUri': 'lib/',
  'languageVersion': '3.9',
};

void _writeAuxiliaryFixtureFile(
  Directory root,
  String relativePath,
  String contents,
) {
  File(p.join(root.path, relativePath))
    ..createSync(recursive: true)
    ..writeAsStringSync(contents);
}

String _integrationTestSource({String? testOn}) {
  if (testOn == null) {
    return '''
import 'package:integration_test/integration_test.dart';

void main() {}
''';
  }
  return '''
@TestOn('$testOn')
library;

import 'package:test_api/src/backend/configuration/test_on.dart';
import 'package:integration_test/integration_test.dart';

void main() {}
''';
}

String _expectedIntegrationTargetId(String relativePath, BuildTarget target) =>
    'aux:test:${_stablePathIdForTest(relativePath)}:'
    'integration-${_targetIdentityHashForTest(target)}';

String _stablePathIdForTest(String path) {
  final normalized = path.replaceAll('\\', '/');
  final sanitized = normalized.replaceAll(RegExp(r'[^A-Za-z0-9._/-]'), '_');
  return sanitized == normalized
      ? sanitized
      : '$sanitized~${_shortHashForTest(normalized)}';
}

String _targetIdentityHashForTest(BuildTarget target) => _shortHashForTest(
  jsonEncode({
    'name': target.name,
    'platform': target.platform,
    'flavor': target.flavor,
    'entrypoint': target.entrypoint,
    'dartDefines': Map.fromEntries(
      target.dartDefines.entries.toList()
        ..sort((left, right) => left.key.compareTo(right.key)),
    ),
  }),
);

String _shortHashForTest(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 16);

List<AuxiliaryExecutionTarget> _sortedIntegrationTargets(
  List<AuxiliaryExecutionTarget> targets,
) => [...targets]..sort((left, right) => left.id.compareTo(right.id));
