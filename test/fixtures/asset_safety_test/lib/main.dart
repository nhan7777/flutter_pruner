import 'gen/assets.gen.dart';

void main() {
  useAssets();
}

void useAssets() {
  final fileName = DateTime.now().year.toString();
  consumeAsset(HeaderDriftAssets.getterDrift.path);
  consumeAsset(HeaderDriftAssets.wrapperDrift.path);
  consumeAsset(HeaderDriftAssets.unresolved.path);
  consumeAsset(HeaderDriftAssets.rawGetter);
  RiveAnimation.asset('assets/unknown_sink.riv');
  consumeResource('assets/dynamic_$fileName.png');
  dynamic opaquePath = DateTime.now().toString();
  opaquePath = 'assets/opaque_variable.png';
  renderResource(opaquePath);
  send({'path': 'assets/nested_payload.mp3'});
  consume(path: 'assets/named_payload.png');
}

void consumeAsset(String path) {}

void consumeResource(String path) {}

void renderResource(String path) {}

void send(Object? payload) {}

void consume({required String path}) {}

class RiveAnimation {
  RiveAnimation.asset(String path);
}
