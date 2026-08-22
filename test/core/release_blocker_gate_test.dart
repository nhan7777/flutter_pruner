import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String verifier;

  setUp(() {
    root = Directory.systemTemp.createTempSync('release_blocker_gate_');
    Directory(p.join(root.path, 'tool')).createSync(recursive: true);
    File(
      p.join(
        root.path,
        'test',
        'reporting',
        'recoverable_report_writer_test.dart',
      ),
    ).createSync(recursive: true);
    verifier = p.absolute('tool', 'verify_release_blockers.dart');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test(
    'active registry blocks release without relying on test labels',
    () async {
      _writeManifest(root, [_blocker(status: 'active')]);
      File(p.join(root.path, 'comment.txt')).writeAsStringSync(
        'All tests passed; no source-level BLOCKED label is required.\n',
      );

      final result = await _runVerifier(verifier, root);

      expect(result.exitCode, 1);
      expect(result.stderr, contains('report-writer-hostile-path-race'));
      expect(result.stdout, isEmpty);
    },
  );

  test(
    'evidence mode does not duplicate the release admission failure',
    () async {
      _writeManifest(root, [_blocker(status: 'active')]);

      final result = await _runVerifier(verifier, root, runTests: true);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Resolved blocker evidence passed'));
      expect(result.stdout, contains('1 active release blocker remains'));
      expect(result.stderr, isEmpty);
    },
  );

  test('only a validated resolved registry admits release', () async {
    final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('void main() {}\n');
    final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"accepted":true}\n');
    final artifactSha = sha256.convert(artifact.readAsBytesSync()).toString();
    _writeManifest(root, [
      _blocker(
        status: 'resolved',
        requiredTestRuns: [
          {
            'platform': 'linux',
            'path': p.relative(testFile.path, from: root.path),
            'name': 'hostile path race preserves foreign object',
          },
        ],
        requiredArtifacts: [
          {
            'path': p.relative(artifact.path, from: root.path),
            'sha256': artifactSha,
          },
        ],
      ),
    ]);

    final result = await _runVerifier(verifier, root, manifestOnly: true);

    expect(result.exitCode, 0);
    expect(result.stdout, contains('No active release blockers'));
    expect(result.stderr, isEmpty);
  });

  test('status-only resolution cannot admit release', () async {
    final evidence = File(
      p.join(root.path, 'test', 'reporting', 'writer_test.dart'),
    )..createSync(recursive: true);
    _writeManifest(root, [
      _blocker(
        status: 'resolved',
        evidence: [p.relative(evidence.path, from: root.path)],
      ),
    ]);

    final result = await _runVerifier(verifier, root, manifestOnly: true);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Invalid release blocker manifest'));
    expect(result.stderr, contains('requiredTestRuns'));
  });

  test('resolved artifact hash must match retained bytes', () async {
    final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
      ..createSync(recursive: true);
    final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
      ..createSync(recursive: true)
      ..writeAsStringSync('{"accepted":false}\n');
    _writeManifest(root, [
      _blocker(
        status: 'resolved',
        evidence: [p.relative(testFile.path, from: root.path)],
        requiredTestRuns: [
          {
            'platform': 'linux',
            'path': p.relative(testFile.path, from: root.path),
            'name': 'exact resolution test',
          },
        ],
        requiredArtifacts: [
          {
            'path': p.relative(artifact.path, from: root.path),
            'sha256': List.filled(64, '0').join(),
          },
        ],
      ),
    ]);

    final result = await _runVerifier(verifier, root, manifestOnly: true);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('artifact SHA-256 mismatch'));
  });

  test('malformed or label-only registry cannot admit release', () async {
    File(p.join(root.path, 'tool', 'release_blockers.json')).writeAsStringSync(
      jsonEncode({
        'schemaVersion': 1,
        'blockers': [
          {'id': 'looks-resolved-in-a-comment'},
        ],
      }),
    );

    final result = await _runVerifier(verifier, root);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Invalid release blocker manifest'));
  });

  test(
    'hosted evidence is SHA, platform, filesystem, and test bound',
    () async {
      final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
        ..createSync(recursive: true);
      final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"accepted":true}\n');
      final artifactSha = sha256.convert(artifact.readAsBytesSync()).toString();
      final requiredRun = {
        'platform': 'windows',
        'path': p.relative(testFile.path, from: root.path),
        'name': 'walks every directory suffix relative to its retained parent',
      };
      _writeManifest(root, [
        _blocker(
          status: 'resolved',
          requiredTestRuns: [requiredRun],
          requiredArtifacts: [
            {
              'path': p.relative(artifact.path, from: root.path),
              'sha256': artifactSha,
            },
          ],
          requiredHostedEvidence: {
            'platform': 'windows',
            'filesystem': 'NTFS',
            'testRuns': [requiredRun],
          },
        ),
      ]);
      final evidenceDirectory = Directory(p.join(root.path, 'hosted'))
        ..createSync();
      const commit = '0123456789abcdef0123456789abcdef01234567';

      final missing = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(missing.exitCode, 2);
      expect(missing.stderr, contains('hosted evidence'));

      final hostedFile = File(
        p.join(evidenceDirectory.path, 'report-writer-hostile-path-race.json'),
      );
      hostedFile.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'blockerId': 'report-writer-hostile-path-race',
          'commitSha': 'f' * 40,
          'platform': 'windows',
          'filesystem': 'NTFS',
          'testRuns': [
            {...requiredRun, 'status': 'passed'},
          ],
        }),
      );
      final wrongCommit = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(wrongCommit.exitCode, 2);
      expect(wrongCommit.stderr, contains('identity mismatch'));

      hostedFile.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'blockerId': 'report-writer-hostile-path-race',
          'commitSha': commit,
          'platform': 'windows',
          'filesystem': 'NTFS',
          'testRuns': [
            {...requiredRun, 'status': 'skipped'},
          ],
        }),
      );
      final skipped = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(skipped.exitCode, 2);
      expect(skipped.stderr, contains('did not pass'));

      hostedFile.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'blockerId': 'report-writer-hostile-path-race',
          'commitSha': commit,
          'platform': 'windows',
          'filesystem': 'NTFS',
          'testRuns': [
            {...requiredRun, 'status': 'passed'},
          ],
        }),
      );

      final accepted = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(accepted.exitCode, 0);
      expect(accepted.stderr, isEmpty);
    },
  );

  test(
    'evidence mode defers hosted artifact validation to admission',
    () async {
      final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
        ..createSync(recursive: true);
      final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"accepted":true}\n');
      final artifactSha = sha256.convert(artifact.readAsBytesSync()).toString();
      final requiredRun = {
        'platform': 'windows',
        'path': p.relative(testFile.path, from: root.path),
        'name': 'hostile path race preserves foreign object',
      };
      _writeManifest(root, [
        _blocker(
          status: 'resolved',
          requiredTestRuns: [requiredRun],
          requiredArtifacts: [
            {
              'path': p.relative(artifact.path, from: root.path),
              'sha256': artifactSha,
            },
          ],
          requiredHostedEvidence: {
            'platform': 'windows',
            'filesystem': 'NTFS',
            'testRuns': [requiredRun],
          },
        ),
      ]);

      final result = await _runVerifier(verifier, root, runTests: true);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Resolved blocker evidence passed'));
      expect(result.stderr, isEmpty);
    },
  );

  test(
    'repository registry binds report writer resolution to hosted evidence',
    () async {
      final result = await _runVerifier(verifier, Directory.current);
      final evidence = await _runVerifier(
        verifier,
        Directory.current,
        runTests: true,
      );

      expect(result.exitCode, 2);
      expect(result.stderr, contains('Resolved hosted blockers require'));
      expect(
        result.stderr,
        isNot(contains('corrected-oracle-o3-o4-incomplete')),
      );
      expect(evidence.exitCode, 0);
      expect(evidence.stdout, contains('0 active release blockers remain'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

Map<String, Object?> _blocker({
  required String status,
  List<String> evidence = const [
    'test/reporting/recoverable_report_writer_test.dart',
  ],
  List<Map<String, Object?>>? requiredTestRuns,
  List<Map<String, Object?>>? requiredArtifacts,
  Map<String, Object?>? requiredHostedEvidence,
}) => {
  'id': 'report-writer-hostile-path-race',
  'status': status,
  'severity': 'critical',
  'reason': 'Atomic filesystem ownership is unavailable.',
  'evidence': evidence,
  if (requiredTestRuns != null) 'requiredTestRuns': requiredTestRuns,
  if (requiredArtifacts != null) 'requiredArtifacts': requiredArtifacts,
  if (requiredHostedEvidence != null)
    'requiredHostedEvidence': requiredHostedEvidence,
};

void _writeManifest(Directory root, List<Map<String, Object?>> blockers) {
  File(
    p.join(root.path, 'tool', 'release_blockers.json'),
  ).writeAsStringSync(jsonEncode({'schemaVersion': 3, 'blockers': blockers}));
}

Future<ProcessResult> _runVerifier(
  String verifier,
  Directory root, {
  bool manifestOnly = false,
  bool runTests = false,
  Directory? hostedEvidenceDirectory,
  String? expectedCommit,
}) => Process.run(Platform.resolvedExecutable, [
  verifier,
  if (manifestOnly) '--manifest-only',
  if (runTests) '--run-tests',
  if (hostedEvidenceDirectory != null) ...[
    '--hosted-evidence-dir',
    hostedEvidenceDirectory.path,
  ],
  if (expectedCommit != null) ...['--expected-commit', expectedCommit],
  root.path,
]);
