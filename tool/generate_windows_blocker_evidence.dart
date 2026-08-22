import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _blockerId = 'report-writer-hostile-path-race';
const _testRuns = <({String path, String name})>[
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'walks every directory suffix relative to its retained parent',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'maps an existing directory leaf to a collision',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'creates and rereads bytes through one retained Windows handle',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'foreign regular and empty collisions remain byte exact',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'retained parent stays object-bound across hostile directory rename',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'retained object handle denies pathname replacement',
  ),
  (
    path: 'test/reporting/windows_report_object_backend_test.dart',
    name: 'final reparse collision is not followed or modified',
  ),
  (
    path: 'test/reporting/immutable_report_store_test.dart',
    name: 'valid batch becomes READY only through an exact commit',
  ),
  (
    path: 'test/reporting/immutable_report_store_test.dart',
    name: 'foreign object collision is byte and type exact with no commit',
  ),
  (
    path: 'test/reporting/report_recovery_inspector_test.dart',
    name: 'classifies an exact valid authority as committed',
  ),
  (
    path: 'test/reporting/report_recovery_inspector_test.dart',
    name: 'retained directory capabilities prevent authority substitution',
  ),
  (
    path: 'test/cli/scan_command_test.dart',
    name: 'blocked child process scan barrier preserves foreign destination',
  ),
  (
    path: 'test/cli/apply_command_test.dart',
    name: 'completed lifecycle is persisted before report becomes terminal',
  ),
];

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/generate_windows_blocker_evidence.dart '
      '--output directory --commit 40-hex-sha [root]',
    );
    exitCode = 64;
    return;
  }
  final head = await Process.run('git', [
    '-C',
    options.root.path,
    'rev-parse',
    'HEAD',
  ]);
  final observedHead = (head.stdout as String).trim().toLowerCase();
  if (head.exitCode != 0 || observedHead != options.commit) {
    stderr.writeln('Hosted evidence commit does not match repository HEAD.');
    exitCode = 2;
    return;
  }
  if (!Platform.isWindows) {
    stderr.writeln('Hosted Windows evidence requires a Windows runner.');
    exitCode = 2;
    return;
  }

  final observed = <Map<String, Object?>>[];
  for (final testRun in _testRuns) {
    final result = await Process.run(Platform.resolvedExecutable, [
      'test',
      '--reporter=json',
      '--name',
      '^${RegExp.escape(testRun.name)}\$',
      testRun.path,
    ], workingDirectory: options.root.path);
    final status = _observedTest(result.stdout as String, testRun.name);
    if (result.exitCode != 0 || status != 'passed') {
      stderr.writeln(
        '${testRun.path} :: ${testRun.name} was $status '
        '(exit ${result.exitCode}).',
      );
      exitCode = 3;
      return;
    }
    observed.add({
      'platform': 'windows',
      'path': testRun.path,
      'name': testRun.name,
      'status': 'passed',
    });
  }

  options.output.createSync(recursive: true);
  final output = File(p.join(options.output.path, '$_blockerId.json'));
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, 'blockerId': _blockerId, 'commitSha': options.commit, 'platform': 'windows', 'filesystem': 'NTFS', 'testRuns': observed})}\n',
    flush: true,
  );
  stdout.writeln(output.path);
}

String _observedTest(String output, String expectedName) {
  final namesById = <int, String>{};
  String? status;
  for (final line in const LineSplitter().convert(output)) {
    final decoded = jsonDecode(line);
    if (decoded is! Map<String, Object?>) continue;
    if (decoded['type'] == 'testStart') {
      final test = decoded['test'];
      if (test is Map<String, Object?> &&
          test['id'] is int &&
          test['name'] is String) {
        namesById[test['id']! as int] = test['name']! as String;
      }
    }
    if (decoded['type'] != 'testDone' || decoded['testID'] is! int) continue;
    if (namesById[decoded['testID']] != expectedName) continue;
    if (status != null) return 'duplicate';
    status = decoded['skipped'] == true
        ? 'skipped'
        : decoded['result'] == 'success'
        ? 'passed'
        : 'failed';
  }
  return status ?? 'missing';
}

final class _Options {
  const _Options({
    required this.root,
    required this.output,
    required this.commit,
  });

  final Directory root;
  final Directory output;
  final String commit;

  static _Options? parse(List<String> arguments) {
    String? output;
    String? commit;
    String? root;
    for (var index = 0; index < arguments.length; index++) {
      switch (arguments[index]) {
        case '--output':
          if (output != null || index + 1 >= arguments.length) return null;
          output = arguments[++index];
        case '--commit':
          if (commit != null || index + 1 >= arguments.length) return null;
          commit = arguments[++index];
        case final value when !value.startsWith('-') && root == null:
          root = value;
        default:
          return null;
      }
    }
    if (output == null ||
        commit == null ||
        !RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
      return null;
    }
    return _Options(
      root: Directory(root ?? Directory.current.path),
      output: Directory(output),
      commit: commit,
    );
  }
}
