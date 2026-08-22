import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/reporting/native/posix_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    stderr.writeln('Expected: <mode> <report-directory> <ready> <release>');
    exitCode = 64;
    return;
  }
  final mode = arguments[0];
  final reportDirectory = Directory(arguments[1]);
  final ready = File(arguments[2]);
  final release = File(arguments[3]);
  final directory = await PosixReportObjectBackend().anchor(reportDirectory);

  try {
    switch (mode) {
      case 'parent-swap':
        ready.writeAsStringSync('anchored', flush: true);
        await _waitForRelease(release);
        final object = await directory.createExclusive('report.json');
        try {
          await object.write(const [1, 2, 3]);
          await object.flush();
          await object.rewind();
          final bytes = await object.read(32);
          ReportObjectBackendFailure? reachabilityFailure;
          try {
            await directory.verifyReachable();
          } on ReportObjectBackendException catch (error) {
            reachabilityFailure = error.category;
          }
          stdout.write(
            jsonEncode({
              'bytes': bytes,
              'reachabilityFailure': reachabilityFailure?.name,
            }),
          );
        } finally {
          await object.close();
        }
      case 'object-swap':
        final object = await directory.createExclusive('report.json');
        try {
          await object.write(const [1, 3, 5, 7]);
          await object.flush();
          final before = await object.identity();
          ready.writeAsStringSync('created', flush: true);
          await _waitForRelease(release);
          await object.rewind();
          final bytes = await object.read(32);
          final after = await object.identity();
          stdout.write(
            jsonEncode({
              'bytes': bytes,
              'sameIdentity': before == after,
              'objectId': after.objectId,
            }),
          );
        } finally {
          await object.close();
        }
      default:
        stderr.writeln('Unknown mode.');
        exitCode = 64;
    }
  } finally {
    await directory.close();
  }
}

Future<void> _waitForRelease(File release) async {
  final timeout = Stopwatch()..start();
  while (!release.existsSync()) {
    if (timeout.elapsed >= const Duration(seconds: 30)) {
      throw TimeoutException('Timed out waiting for release barrier.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
