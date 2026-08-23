import 'dart:convert';
import 'dart:io';

Future<bool> _write(String path) async {
  try {
    await File(path).writeAsString('guarded write\n', flush: true);
    return true;
  } on FileSystemException {
    return false;
  }
}

Future<bool> _connect(int port) async {
  try {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      port,
      timeout: const Duration(seconds: 2),
    );
    socket.destroy();
    return true;
  } on SocketException {
    return false;
  }
}

Future<bool> _hardLink(String source, String destination) async {
  final result = await Process.run(
    '/bin/ln',
    [source, destination],
    environment: const {'LANG': 'C', 'LC_ALL': 'C'},
    includeParentEnvironment: false,
  );
  return result.exitCode == 0;
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 8) {
    stderr.writeln('expected eight arguments');
    exitCode = 64;
    return;
  }
  final result = <String, bool>{
    'protectedSiblingWrite': await _write(arguments[0]),
    'sdkLikeWrite': await _write(arguments[1]),
    'sandboxWrite': await _write(arguments[2]),
    'stageWrite': await _write(arguments[3]),
    'symlinkEscapeWrite': await _write(arguments[4]),
    'loopbackConnect': await _connect(int.parse(arguments[5])),
    'crossBoundaryHardLink': await _hardLink(arguments[6], arguments[7]),
  };
  stdout.writeln(jsonEncode(result));
}
