import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/scan_command.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 4) {
    stderr.writeln('Expected: <project> <output> <ready-file> <release-file>');
    exitCode = 64;
    return;
  }

  final backend = _ProcessBarrierReportObjectBackend(
    readyFile: File(arguments[2]),
    releaseFile: File(arguments[3]),
  );
  final runner = FlutterPrunerCommandRunner(
    scanCommandFactory: () => ScanCommand(reportBackend: backend),
  );

  exitCode = await runner.run([
    'scan',
    '--adapter',
    'dart',
    '--format',
    'json',
    '--json-version',
    '3',
    '--output',
    arguments[1],
    arguments[0],
  ]);
}

final class _ProcessBarrierReportObjectBackend implements ReportObjectBackend {
  _ProcessBarrierReportObjectBackend({
    required this.readyFile,
    required this.releaseFile,
  });

  final File readyFile;
  final File releaseFile;
  final ReportObjectBackend _delegate = createIoReportObjectBackend();
  var _blocked = false;

  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) async =>
      _ProcessBarrierAnchoredDirectory(
        delegate: await _delegate.anchor(directory),
        shouldBlock: () => !_blocked,
        markBlocked: () => _blocked = true,
        readyFile: readyFile,
        releaseFile: releaseFile,
      );
}

final class _ProcessBarrierAnchoredDirectory
    implements AnchoredReportDirectory {
  const _ProcessBarrierAnchoredDirectory({
    required this.delegate,
    required this.shouldBlock,
    required this.markBlocked,
    required this.readyFile,
    required this.releaseFile,
  });

  final AnchoredReportDirectory delegate;
  final bool Function() shouldBlock;
  final void Function() markBlocked;
  final File readyFile;
  final File releaseFile;

  @override
  String get canonicalPath => delegate.canonicalPath;

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async {
    if (shouldBlock()) {
      markBlocked();
      readyFile.writeAsStringSync(
        jsonEncode({
          'phase': 'create-exclusive',
          'destination': '$canonicalPath${Platform.pathSeparator}$leaf',
        }),
        flush: true,
      );
      await _waitForRelease();
    }
    return delegate.createExclusive(leaf);
  }

  Future<void> _waitForRelease() async {
    final timeout = Stopwatch()..start();
    while (!releaseFile.existsSync()) {
      if (timeout.elapsed >= const Duration(seconds: 30)) {
        throw TimeoutException('Timed out waiting for parent barrier release.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  @override
  Future<void> close() => delegate.close();

  @override
  Future<ExistingReportObject> openExisting(String leaf) =>
      delegate.openExisting(leaf);

  @override
  Future<void> verifyReachable() => delegate.verifyReachable();
}
