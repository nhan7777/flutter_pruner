import 'dart:io';

import 'package:flutter_pruner/src/adapters/dart/callback_boundary_detector.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_analysis_workspace.dart';
import 'package:flutter_pruner/src/adapters/dart/dart_package_ownership.dart';
import 'package:flutter_pruner/src/core/graph/execution_target.dart';
import 'package:flutter_pruner/src/core/project/project_context.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('G3 detects only reviewed resolved callback identities', () async {
    final directory = await Directory.systemTemp.createTemp('g3-callback-');
    addTearDown(() => directory.deleteSync(recursive: true));
    File(p.join(directory.path, 'pubspec.yaml'))
      ..createSync(recursive: true)
      ..writeAsStringSync('name: callback_test\nenvironment:\n  sdk: ^3.9.0\n');
    final mainFile = File(p.join(directory.path, 'lib/main.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
import 'dart:isolate' as sdk;

void worker(Object? message) {}
void unresolvedWorker() {}

void register() {
  sdk.Isolate.spawn(worker, null);
  Isolate.spawn(unresolvedWorker, null);
  PluginUtilities.getCallbackHandle(unresolvedWorker);
  Workmanager().initialize(unresolvedWorker);
}

class Isolate {
  static void spawn(void Function() callback, Object? message) {}
}

class Workmanager {}
extension LocalWorkmanagerExtension on Workmanager {
  void initialize(void Function() callback) {}
}
''');
    File(p.join(directory.path, '.dart_tool', 'package_config.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
{"configVersion":2,"packages":[
  {"name":"callback_test","rootUri":"../","packageUri":"lib/","languageVersion":"3.9"}
]}
''');
    final project = await ProjectContext.load(directory);
    final owner = DartPackageOwnership.discover(project).ownerOf(mainFile.path);
    expect(
      owner.ownership,
      DartSourceOwnership.selectedPackage,
      reason: owner.reason,
    );
    final workspace = DartAnalysisWorkspace(project);
    final resolved = await workspace.resolveLibrary(mainFile.path);
    final detection = CallbackBoundaryDetector(project).detect(resolved);

    expect(detection.boundaries, hasLength(4));
    final boundary = detection.boundaries.singleWhere(
      (fact) => fact.descriptor.capability == CallbackBoundaryCapability.dartVm,
    );
    expect(boundary.descriptor.description, 'dart:isolate Isolate.spawn');
    expect(boundary.descriptor.capability, CallbackBoundaryCapability.dartVm);
    expect(boundary.callbackNodeIds.single, endsWith('#worker'));
    expect(boundary.unresolved, isFalse);
    final sameNamed = detection.boundaries.singleWhere(
      (fact) => fact.descriptor.description == 'same-named Isolate.spawn',
    );
    expect(sameNamed.unresolved, isTrue);
    final unresolved = detection.boundaries.singleWhere(
      (fact) =>
          fact.descriptor.description ==
          'same-named PluginUtilities.getCallbackHandle',
    );
    expect(
      unresolved.descriptor.capability,
      CallbackBoundaryCapability.unknown,
    );
    expect(unresolved.unresolved, isTrue);
    final constructorReceiver = detection.boundaries.singleWhere(
      (fact) =>
          fact.descriptor.description == 'same-named Workmanager.initialize',
    );
    expect(
      constructorReceiver.descriptor.capability,
      CallbackBoundaryCapability.unknown,
    );
    expect(
      constructorReceiver.callbackNodeIds.single,
      endsWith('#unresolvedWorker'),
    );
    expect(constructorReceiver.unresolved, isTrue);
  });
}
