import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _blockerId = 'clean-path-replacement-toctou';

final _sharedTestRuns = <({String path, String name})>[
  (
    path: 'test/quarantine/recoverable_clean_store_test.dart',
    name: 'logical clean retains exact bytes and commits a durable journal',
  ),
  (
    path: 'test/quarantine/recoverable_clean_store_test.dart',
    name: 'restore uses no-replace move and never overwrites an active run',
  ),
  for (final point in [
    'intentFlushed',
    'beforeMove',
    'afterMove',
    'metadataFlushed',
    'retainedVerified',
    'committedJournalFlushed',
  ])
    (
      path: 'test/quarantine/recoverable_clean_recovery_process_test.dart',
      name: 'restart reconciles a hard process exit at $point',
    ),
];

const _posixTestRuns = <({String path, String name})>[
  (
    path: 'test/quarantine/posix_clean_move_backend_test.dart',
    name: 'destination collision preserves both source and foreign bytes',
  ),
  (
    path: 'test/quarantine/posix_clean_move_backend_test.dart',
    name: 'rejects a symlinked directory component without touching its target',
  ),
  (
    path: 'test/quarantine/posix_clean_move_backend_test.dart',
    name: 'base pathname replacement blocks the move and preserves both trees',
  ),
];

const _windowsTestRuns = <({String path, String name})>[
  (
    path: 'test/quarantine/windows_clean_move_backend_test.dart',
    name: 'Windows NTFS no-replace collision preserves both directory trees',
  ),
  (
    path: 'test/quarantine/windows_clean_move_backend_test.dart',
    name: 'reparse directories are rejected without a rename',
  ),
  (
    path: 'test/quarantine/windows_clean_move_backend_test.dart',
    name: 'base identity replacement blocks the move',
  ),
];

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/generate_clean_blocker_evidence.dart '
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
    stderr.writeln(
      'Hosted clean evidence commit does not match repository HEAD.',
    );
    exitCode = 2;
    return;
  }
  final platform = _currentPlatform();
  if (platform == null) {
    stderr.writeln('Hosted clean evidence requires Linux, macOS, or Windows.');
    exitCode = 2;
    return;
  }
  final testRuns = <({String path, String name})>[
    ..._sharedTestRuns,
    if (platform.name == 'windows') ..._windowsTestRuns else ..._posixTestRuns,
  ];

  final observed = <Map<String, Object?>>[];
  final reporterDirectory = await Directory.systemTemp.createTemp(
    'flutter_pruner_clean_evidence_',
  );
  try {
    for (var index = 0; index < testRuns.length; index++) {
      final testRun = testRuns[index];
      final reporter = File(p.join(reporterDirectory.path, '$index.json'));
      final result = await Process.run(Platform.resolvedExecutable, [
        'test',
        '--reporter=silent',
        '--file-reporter=json:${reporter.path}',
        '--name',
        '^${RegExp.escape(testRun.name)}\$',
        testRun.path,
      ], workingDirectory: options.root.path);
      final status = reporter.existsSync()
          ? _observedTest(await reporter.readAsString(), testRun.name)
          : 'missing';
      if (result.exitCode != 0 || status != 'passed') {
        stderr.writeln(
          '${testRun.path} :: ${testRun.name} was $status '
          '(exit ${result.exitCode}).',
        );
        exitCode = 3;
        return;
      }
      observed.add({
        'platform': platform.name,
        'path': testRun.path,
        'name': testRun.name,
        'status': 'passed',
      });
    }
  } finally {
    if (reporterDirectory.existsSync()) {
      await reporterDirectory.delete(recursive: true);
    }
  }

  options.output.createSync(recursive: true);
  final output = File(
    p.join(options.output.path, '$_blockerId-${platform.name}.json'),
  );
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert({'schemaVersion': 1, 'blockerId': _blockerId, 'commitSha': options.commit, 'platform': platform.name, 'filesystem': platform.filesystem, 'testRuns': observed})}\n',
    flush: true,
  );
  stdout.writeln(output.path);
}

({String name, String filesystem})? _currentPlatform() {
  if (Platform.isLinux) return (name: 'linux', filesystem: 'renameat2');
  if (Platform.isMacOS) return (name: 'macos', filesystem: 'renameatx_np');
  if (Platform.isWindows) return (name: 'windows', filesystem: 'NTFS');
  return null;
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
