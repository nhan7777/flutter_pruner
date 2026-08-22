import 'dart:ffi';
import 'dart:isolate';

import 'package:flutter/ui.dart';
import 'package:sibling/sibling.dart';
import 'package:workmanager/workmanager.dart';

import 'conditional.dart';

const vmEntryPragmaName = 'vm:entry-point';

@pragma('vm:entry-point')
void vmEntry() => selected();

@pragma(vmEntryPragmaName)
void constantVmEntry() {}

void isolateWorker(Object? _) {}

void startIsolate() => Isolate.spawn(isolateWorker, null);

void startSecondIsolate() => Isolate.spawn(isolateWorker, null);

void startSiblingIsolate() => Isolate.spawn(siblingEntry, null);

void workmanagerCallback() {}

void startWorkmanager() => Workmanager.initialize(workmanagerCallback);

void dartUiCallback() {}

void startDartUi() => PluginUtilities.getCallbackHandle(dartUiCallback);

@Native<Void Function()>(symbol: 'ffiNativeCallback')
external void ffiNativeCallback();

class A {
  @pragma('vm:entry-point')
  static void run() {}
}

class B {
  @pragma('vm:entry-point')
  static void run() {}
}

class Constructed {
  @pragma('vm:entry-point')
  Constructed.named();
}

enum CallbackEnum {
  value;

  @pragma('vm:entry-point')
  void run() {}
}

extension type CallbackExtensionType(int value) {
  @pragma('vm:entry-point')
  void run() {}
}

extension on int {
  @pragma('vm:entry-point')
  void unnamedCallback() {}
}

extension on int {
  // Comments and whitespace are intentionally different from the first copy.
  @pragma('vm:entry-point')
  void unnamedCallback() {}
}

/// Documentation must not participate in the executable identity.
@Deprecated('oracle declaration metadata')
extension on String {
  @pragma('vm:entry-point')
  void unnamedCallback() {}
}

void unrelatedSibling() {}

class SameNamedDecoy {
  void spawn(void Function(Object?) callback, Object? message) {}

  void initialize(void Function() callback) {}

  void getCallbackHandle(void Function() callback) {}
}

void unknownSpawnCallback(Object? _) {}

void unknownCallback() {}

void startSameNamedDecoy() {
  final decoy = SameNamedDecoy();
  decoy.spawn(unknownSpawnCallback, null);
  decoy.initialize(unknownCallback);
  decoy.getCallbackHandle(unknownCallback);
}
