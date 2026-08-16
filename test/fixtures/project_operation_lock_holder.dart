import 'dart:io';

import 'package:flutter_pruner/src/core/project/project_operation_lock.dart';
import 'package:flutter_pruner/src/core/project/tool_workspace.dart';

Future<void> main(List<String> arguments) async {
  final workspace = ToolWorkspace(Directory(arguments.single));
  final lock = await ProjectOperationLock.acquire(
    workspace: workspace,
    operation: 'holder',
  );
  stdout.writeln('LOCKED');
  await stdin.first;
  await lock.release();
}
