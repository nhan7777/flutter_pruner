import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';

Future<void> main(List<String> arguments) async {
  final exitCode = await FlutterPrunerCommandRunner().run(arguments);
  exit(exitCode);
}
