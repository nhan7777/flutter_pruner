import 'dart:isolate';

typedef BackgroundCallback = void Function();

void main() {
  final localCallback = workmanagerCallback;
  registerWithWorkmanager(localCallback);
  Isolate.spawn(isolateCallback, 'start');
  PluginUtilities.getCallbackHandle(callbackFromHelper());
}

void registerWithWorkmanager(BackgroundCallback callback) {
  Workmanager().initialize(callback);
}

BackgroundCallback callbackFromHelper() => helperCallback;

void workmanagerCallback() {}

void isolateCallback(String message) {}

void helperCallback() {}

// A persisted callback handle may be invoked from native code in a later
// isolate or app launch. The registration helper itself is intentionally not
// reachable from main, so ordinary caller-to-callee reachability is
// insufficient to retain the callback.
void persistCallbackHandle() {
  PluginUtilities.getCallbackHandle(persistedCallback);
}

void persistedCallback() {}

dynamic runtimeCallback;

void persistUnknownCallbackHandle() {
  PluginUtilities.getCallbackHandle(runtimeCallback);
}

class UnresolvedCallbackCandidate {}

void persistStaticCallbackHandle() {
  PluginUtilities.getCallbackHandle(BackgroundCallbacks.persisted);
}

class BackgroundCallbacks {
  static void persisted() {}
}

@pragma('vm:entry-point')
final Object nativeTopLevelToken = Object();

class NativeFields {
  @pragma('vm:entry-point')
  static final Object callbackToken = Object();
}

class Workmanager {
  void initialize(BackgroundCallback callback) {}
}

class PluginUtilities {
  static Object? getCallbackHandle(Function callback) => Object();
}
