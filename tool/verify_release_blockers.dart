import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _allowedPlatforms = {'linux', 'macos', 'windows'};
const _sha256Pattern = r'^[0-9a-f]{64}$';

Future<void> main(List<String> arguments) async {
  final options = _Options.parse(arguments);
  if (options == null) {
    stderr.writeln(
      'Usage: dart run tool/verify_release_blockers.dart '
      '[--manifest-only|--run-tests] '
      '[--hosted-evidence-dir path --expected-commit sha] [root]',
    );
    exitCode = 64;
    return;
  }

  final manifest = File(
    p.join(options.root.path, 'tool', 'release_blockers.json'),
  );

  try {
    final blockers = await _loadBlockers(manifest, options.root);
    if (options.mode != _VerificationMode.evidenceOnly) {
      await _validateHostedEvidence(blockers, options);
    }
    final active = blockers.where((blocker) => blocker.status == 'active');
    if (options.mode != _VerificationMode.evidenceOnly && active.isNotEmpty) {
      stderr.writeln('Release blocked by ${active.length} active issue(s):');
      for (final blocker in active) {
        stderr.writeln(
          '- [${blocker.severity}] ${blocker.id}: ${blocker.reason}',
        );
      }
      exitCode = 1;
      return;
    }

    if (options.mode != _VerificationMode.manifestOnly) {
      await _runResolutionTests(blockers, options.root);
    }
    if (options.mode == _VerificationMode.evidenceOnly) {
      stdout.writeln('Resolved blocker evidence passed.');
      stdout.writeln(
        active.length == 1
            ? '1 active release blocker remains.'
            : '${active.length} active release blockers remain.',
      );
      return;
    }
    stdout.writeln('No active release blockers.');
  } on _ResolutionTestFailure catch (error) {
    stderr.writeln('Resolved release blocker evidence failed: $error');
    exitCode = 3;
  } on Object catch (error) {
    stderr.writeln('Invalid release blocker manifest: $error');
    exitCode = 2;
  }
}

Future<List<_Blocker>> _loadBlockers(File manifest, Directory root) async {
  final decoded = jsonDecode(await manifest.readAsString());
  if (decoded is! Map<String, Object?> || decoded['schemaVersion'] != 3) {
    throw const FormatException('Expected schemaVersion 3.');
  }
  final rawBlockers = decoded['blockers'];
  if (rawBlockers is! List<Object?> || rawBlockers.isEmpty) {
    throw const FormatException('Expected a nonempty blockers list.');
  }

  final ids = <String>{};
  final blockers = <_Blocker>[];
  for (final rawBlocker in rawBlockers) {
    if (rawBlocker is! Map<String, Object?>) {
      throw const FormatException('Every blocker must be an object.');
    }
    final id = _requiredText(rawBlocker, 'id');
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id)) {
      throw FormatException('Invalid blocker id: $id');
    }
    if (!ids.add(id)) throw FormatException('Duplicate blocker id: $id');
    final status = _requiredText(rawBlocker, 'status');
    if (status != 'active' && status != 'resolved') {
      throw FormatException('Invalid blocker status for $id: $status');
    }
    final severity = _requiredText(rawBlocker, 'severity');
    final reason = _requiredText(rawBlocker, 'reason');
    final evidence = _requiredRelativePaths(rawBlocker, 'evidence', root);

    final hasResolution =
        rawBlocker.containsKey('requiredTestRuns') ||
        rawBlocker.containsKey('requiredArtifacts');
    if (status == 'resolved' && !hasResolution) {
      throw FormatException(
        'Resolved blocker $id requires requiredTestRuns and '
        'requiredArtifacts.',
      );
    }

    final requiredTestRuns = hasResolution
        ? _requiredTestRuns(rawBlocker, root)
        : const <_RequiredTestRun>[];
    final requiredArtifacts = hasResolution
        ? await _requiredArtifacts(rawBlocker, root)
        : const <_RequiredArtifact>[];
    final requiredHostedEvidence =
        rawBlocker.containsKey('requiredHostedEvidence')
        ? _requiredHostedEvidence(rawBlocker, root, requiredTestRuns)
        : null;

    blockers.add(
      _Blocker(
        id: id,
        status: status,
        severity: severity,
        reason: reason,
        evidence: evidence,
        requiredTestRuns: requiredTestRuns,
        requiredArtifacts: requiredArtifacts,
        requiredHostedEvidence: requiredHostedEvidence,
      ),
    );
  }
  return List.unmodifiable(blockers);
}

String _requiredText(Map<String, Object?> source, String key) {
  final value = source[key];
  if (value is! String || value.isEmpty || _hasControl(value)) {
    throw FormatException('Expected nonempty control-free $key.');
  }
  return value;
}

List<String> _requiredRelativePaths(
  Map<String, Object?> source,
  String key,
  Directory root,
) {
  final raw = source[key];
  if (raw is! List<Object?> || raw.isEmpty) {
    throw FormatException('Expected a nonempty $key list.');
  }
  final result = <String>[];
  final unique = <String>{};
  for (final value in raw) {
    if (value is! String || !_isCanonicalRelativePosix(value)) {
      throw FormatException('Invalid repository-relative $key path: $value');
    }
    if (!unique.add(value)) {
      throw FormatException('Duplicate $key path: $value');
    }
    if (!_rootFile(root, value).existsSync()) {
      throw FormatException('$key path does not exist: $value');
    }
    result.add(value);
  }
  return List.unmodifiable(result);
}

List<_RequiredTestRun> _requiredTestRuns(
  Map<String, Object?> source,
  Directory root,
) {
  final raw = source['requiredTestRuns'];
  if (raw is! List<Object?> || raw.isEmpty) {
    throw const FormatException('Expected nonempty requiredTestRuns.');
  }
  final result = <_RequiredTestRun>[];
  final identities = <String>{};
  for (final entry in raw) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException(
        'Every requiredTestRuns entry must be an object.',
      );
    }
    if (entry.keys.toSet().difference({
          'platform',
          'path',
          'name',
        }).isNotEmpty ||
        entry.length != 3) {
      throw FormatException(
        'Invalid requiredTestRuns entry keys: ${entry.keys}',
      );
    }
    final platform = _requiredText(entry, 'platform');
    final path = _requiredText(entry, 'path');
    final name = _requiredText(entry, 'name');
    if (!_allowedPlatforms.contains(platform)) {
      throw FormatException('Invalid required test platform: $platform');
    }
    if (!_isCanonicalRelativePosix(path) ||
        !path.startsWith('test/') ||
        !path.endsWith('_test.dart')) {
      throw FormatException('Invalid requiredTestRuns path: $path');
    }
    if (!_rootFile(root, path).existsSync()) {
      throw FormatException('requiredTestRuns path does not exist: $path');
    }
    if (!identities.add('$platform\u0000$path\u0000$name')) {
      throw FormatException(
        'Duplicate required test run: $platform :: $path :: $name',
      );
    }
    result.add(_RequiredTestRun(platform: platform, path: path, name: name));
  }
  return List.unmodifiable(result);
}

Future<List<_RequiredArtifact>> _requiredArtifacts(
  Map<String, Object?> source,
  Directory root,
) async {
  final raw = source['requiredArtifacts'];
  if (raw is! List<Object?> || raw.isEmpty) {
    throw const FormatException('Expected nonempty requiredArtifacts.');
  }
  final result = <_RequiredArtifact>[];
  final paths = <String>{};
  for (final entry in raw) {
    if (entry is! Map<String, Object?>) {
      throw const FormatException(
        'Every requiredArtifacts entry must be an object.',
      );
    }
    if (entry.keys.toSet().difference({'path', 'sha256'}).isNotEmpty ||
        entry.length != 2) {
      throw FormatException(
        'Invalid requiredArtifacts entry keys: ${entry.keys}',
      );
    }
    final path = _requiredText(entry, 'path');
    final expectedSha = _requiredText(entry, 'sha256');
    if (!_isCanonicalRelativePosix(path) || !paths.add(path)) {
      throw FormatException(
        'Invalid or duplicate required artifact path: $path',
      );
    }
    if (!RegExp(_sha256Pattern).hasMatch(expectedSha)) {
      throw FormatException('Invalid artifact SHA-256 for $path.');
    }
    final file = _rootFile(root, path);
    if (!file.existsSync()) {
      throw FormatException('Required artifact does not exist: $path');
    }
    final actualSha = await sha256.bind(file.openRead()).first;
    if (actualSha.toString() != expectedSha) {
      throw FormatException('artifact SHA-256 mismatch for $path.');
    }
    result.add(_RequiredArtifact(path: path, sha256: expectedSha));
  }
  return List.unmodifiable(result);
}

_RequiredHostedEvidence _requiredHostedEvidence(
  Map<String, Object?> source,
  Directory root,
  List<_RequiredTestRun> requiredTestRuns,
) {
  final raw = source['requiredHostedEvidence'];
  if (raw is! Map<String, Object?> ||
      raw.keys.toSet().difference({
        'platform',
        'filesystem',
        'testRuns',
      }).isNotEmpty ||
      raw.length != 3) {
    throw const FormatException('Invalid requiredHostedEvidence contract.');
  }
  final platform = _requiredText(raw, 'platform');
  if (!_allowedPlatforms.contains(platform)) {
    throw FormatException('Invalid hosted evidence platform: $platform');
  }
  final filesystem = _requiredText(raw, 'filesystem');
  final testRuns = _requiredTestRuns({
    'requiredTestRuns': raw['testRuns'],
  }, root);
  if (testRuns.any((run) => run.platform != platform)) {
    throw const FormatException(
      'Hosted evidence testRuns must use the hosted platform.',
    );
  }
  final requiredIdentities = requiredTestRuns
      .map((run) => run.identity)
      .toSet();
  if (!testRuns.every((run) => requiredIdentities.contains(run.identity))) {
    throw const FormatException(
      'Hosted evidence testRuns must be declared requiredTestRuns.',
    );
  }
  return _RequiredHostedEvidence(
    platform: platform,
    filesystem: filesystem,
    testRuns: testRuns,
  );
}

Future<void> _validateHostedEvidence(
  List<_Blocker> blockers,
  _Options options,
) async {
  final hosted = blockers.where(
    (blocker) =>
        blocker.status == 'resolved' && blocker.requiredHostedEvidence != null,
  );
  if (hosted.isEmpty) return;
  final directory = options.hostedEvidenceDirectory;
  final expectedCommit = options.expectedCommit;
  if (directory == null || expectedCommit == null) {
    throw const FormatException(
      'Resolved hosted blockers require hosted evidence and expected commit.',
    );
  }
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(expectedCommit)) {
    throw const FormatException('Invalid expected hosted evidence commit.');
  }
  for (final blocker in hosted) {
    final contract = blocker.requiredHostedEvidence!;
    final file = File(p.join(directory.path, '${blocker.id}.json'));
    if (!file.existsSync()) {
      throw FormatException('Missing hosted evidence for ${blocker.id}.');
    }
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, Object?> || decoded['schemaVersion'] != 1) {
      throw FormatException('Invalid hosted evidence for ${blocker.id}.');
    }
    if (decoded.keys.toSet().difference({
          'schemaVersion',
          'blockerId',
          'commitSha',
          'platform',
          'filesystem',
          'testRuns',
        }).isNotEmpty ||
        decoded.length != 6 ||
        decoded['blockerId'] != blocker.id ||
        decoded['commitSha'] != expectedCommit ||
        decoded['platform'] != contract.platform ||
        decoded['filesystem'] != contract.filesystem) {
      throw FormatException(
        'Hosted evidence identity mismatch for ${blocker.id}.',
      );
    }
    final rawRuns = decoded['testRuns'];
    if (rawRuns is! List<Object?>) {
      throw FormatException('Invalid hosted test runs for ${blocker.id}.');
    }
    final observed = <String>{};
    for (final rawRun in rawRuns) {
      if (rawRun is! Map<String, Object?> ||
          rawRun.keys.toSet().difference({
            'platform',
            'path',
            'name',
            'status',
          }).isNotEmpty ||
          rawRun.length != 4 ||
          rawRun['status'] != 'passed') {
        throw FormatException(
          'Hosted test run did not pass for ${blocker.id}.',
        );
      }
      final run = _RequiredTestRun(
        platform: _requiredText(rawRun, 'platform'),
        path: _requiredText(rawRun, 'path'),
        name: _requiredText(rawRun, 'name'),
      );
      if (!observed.add(run.identity)) {
        throw FormatException('Duplicate hosted test run for ${blocker.id}.');
      }
    }
    final expected = contract.testRuns.map((run) => run.identity).toSet();
    if (observed.length != expected.length || !observed.containsAll(expected)) {
      throw FormatException('Incomplete hosted test runs for ${blocker.id}.');
    }
  }
}

Future<void> _runResolutionTests(
  List<_Blocker> blockers,
  Directory root,
) async {
  final platform = _currentPlatform();
  for (final blocker in blockers.where((entry) => entry.status == 'resolved')) {
    for (final requiredTest in blocker.requiredTestRuns.where(
      (run) => run.platform == platform,
    )) {
      final result = await Process.run(Platform.resolvedExecutable, [
        'test',
        '--reporter=json',
        '--name',
        '^${RegExp.escape(requiredTest.name)}\$',
        requiredTest.path,
      ], workingDirectory: root.path);
      final observed = _observedTest(
        result.stdout as String,
        requiredTest.name,
      );
      if (result.exitCode != 0 || observed != _ObservedTest.passed) {
        throw _ResolutionTestFailure(
          '${blocker.id}: ${requiredTest.path} :: ${requiredTest.name} '
          'was ${observed.name} (exit ${result.exitCode}).',
        );
      }
    }
  }
}

_ObservedTest _observedTest(String output, String expectedName) {
  final namesById = <int, String>{};
  _ObservedTest result = _ObservedTest.missing;
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
    if (result != _ObservedTest.missing) return _ObservedTest.duplicate;
    result = decoded['skipped'] == true
        ? _ObservedTest.skipped
        : decoded['result'] == 'success'
        ? _ObservedTest.passed
        : _ObservedTest.failed;
  }
  return result;
}

String _currentPlatform() {
  if (Platform.isLinux) return 'linux';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  throw UnsupportedError('Unsupported release evidence platform.');
}

bool _isCanonicalRelativePosix(String value) {
  if (value.isEmpty || _hasControl(value) || value.contains('\\')) return false;
  if (p.posix.isAbsolute(value) || p.posix.normalize(value) != value) {
    return false;
  }
  return !p.posix
      .split(value)
      .any((part) => part.isEmpty || part == '.' || part == '..');
}

bool _hasControl(String value) =>
    value.codeUnits.any((unit) => unit <= 0x1f || unit == 0x7f);

File _rootFile(Directory root, String relativePosixPath) =>
    File(p.joinAll([root.path, ...p.posix.split(relativePosixPath)]));

final class _Options {
  const _Options({
    required this.root,
    required this.mode,
    required this.hostedEvidenceDirectory,
    required this.expectedCommit,
  });

  final Directory root;
  final _VerificationMode mode;
  final Directory? hostedEvidenceDirectory;
  final String? expectedCommit;

  static _Options? parse(List<String> arguments) {
    var mode = _VerificationMode.admission;
    var modeWasExplicit = false;
    String? rootPath;
    String? hostedEvidencePath;
    String? expectedCommit;
    for (var index = 0; index < arguments.length; index++) {
      final argument = arguments[index];
      if (argument == '--manifest-only') {
        if (modeWasExplicit) return null;
        mode = _VerificationMode.manifestOnly;
        modeWasExplicit = true;
      } else if (argument == '--run-tests') {
        if (modeWasExplicit) return null;
        mode = _VerificationMode.evidenceOnly;
        modeWasExplicit = true;
      } else if (argument == '--hosted-evidence-dir') {
        if (hostedEvidencePath != null || index + 1 >= arguments.length) {
          return null;
        }
        hostedEvidencePath = arguments[++index];
      } else if (argument == '--expected-commit') {
        if (expectedCommit != null || index + 1 >= arguments.length) {
          return null;
        }
        expectedCommit = arguments[++index];
      } else if (argument.startsWith('-') || rootPath != null) {
        return null;
      } else {
        rootPath = argument;
      }
    }
    return _Options(
      root: Directory(rootPath ?? Directory.current.path),
      mode: mode,
      hostedEvidenceDirectory: hostedEvidencePath == null
          ? null
          : Directory(hostedEvidencePath),
      expectedCommit: expectedCommit,
    );
  }
}

enum _VerificationMode { admission, manifestOnly, evidenceOnly }

final class _Blocker {
  const _Blocker({
    required this.id,
    required this.status,
    required this.severity,
    required this.reason,
    required this.evidence,
    required this.requiredTestRuns,
    required this.requiredArtifacts,
    required this.requiredHostedEvidence,
  });

  final String id;
  final String status;
  final String severity;
  final String reason;
  final List<String> evidence;
  final List<_RequiredTestRun> requiredTestRuns;
  final List<_RequiredArtifact> requiredArtifacts;
  final _RequiredHostedEvidence? requiredHostedEvidence;
}

final class _RequiredTestRun {
  const _RequiredTestRun({
    required this.platform,
    required this.path,
    required this.name,
  });

  final String platform;
  final String path;
  final String name;

  String get identity => '$platform\u0000$path\u0000$name';
}

final class _RequiredHostedEvidence {
  const _RequiredHostedEvidence({
    required this.platform,
    required this.filesystem,
    required this.testRuns,
  });

  final String platform;
  final String filesystem;
  final List<_RequiredTestRun> testRuns;
}

final class _RequiredArtifact {
  const _RequiredArtifact({required this.path, required this.sha256});

  final String path;
  final String sha256;
}

enum _ObservedTest { missing, duplicate, skipped, failed, passed }

final class _ResolutionTestFailure implements Exception {
  const _ResolutionTestFailure(this.message);

  final String message;

  @override
  String toString() => message;
}
