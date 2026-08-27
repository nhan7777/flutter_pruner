import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _cleanBlockerId = 'clean-path-replacement-toctou';
const _cleanBlockerReason =
    'Production quarantine clean now uses recoverable identity-bound '
    'no-replace moves, and release admission requires exact-candidate hosted '
    'Linux, macOS, and Windows evidence for race resistance, crash '
    'reconciliation, and restore.';
const _cleanEvidencePaths = [
  'lib/src/quarantine/clean_move_backend.dart',
  'lib/src/quarantine/recoverable_clean_store.dart',
  'lib/src/quarantine/native/posix_clean_move_backend.dart',
  'lib/src/quarantine/native/windows_clean_move_backend.dart',
  'lib/src/quarantine/quarantine_manager.dart',
  'test/quarantine/recoverable_clean_store_test.dart',
  'test/quarantine/recoverable_clean_recovery_process_test.dart',
  'test/quarantine/posix_clean_move_backend_test.dart',
  'test/quarantine/windows_clean_move_backend_test.dart',
  'test/quarantine/quarantine_manager_test.dart',
  'test/cli/quarantine_command_test.dart',
  'test/cli/rollback_command_test.dart',
  'tool/generate_clean_blocker_evidence.dart',
  'test/core/clean_blocker_evidence_generator_test.dart',
];

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

  for (final mode in const [
    (name: 'default admission', manifestOnly: false),
    (name: 'manifest-only admission', manifestOnly: true),
  ]) {
    test(
      '${mode.name} checks active blockers before hosted evidence',
      () async {
        _writeManifest(root, [
          _activeCleanBlocker(root),
          _resolvedHostedBlocker(root),
        ]);

        expect(
          Directory(p.join(root.path, '.superpowers')).existsSync(),
          isFalse,
        );
        final result = await _runVerifier(
          verifier,
          root,
          manifestOnly: mode.manifestOnly,
        );

        expect(result.exitCode, 1);
        expect(result.stderr, contains(_cleanBlockerId));
        expect(result.stderr, isNot(contains('hosted evidence')));
        expect(result.stdout, isEmpty);
      },
    );
  }

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
            'path': _relativePosix(testFile.path, root.path),
            'name': 'hostile path race preserves foreign object',
          },
        ],
        requiredArtifacts: [
          {
            'path': _relativePosix(artifact.path, root.path),
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

  test('hosted evidence remains mandatory when no blocker is active', () async {
    _writeManifest(root, [_resolvedHostedBlocker(root)]);

    final result = await _runVerifier(verifier, root);

    expect(result.exitCode, 2);
    expect(
      result.stderr,
      contains('Resolved hosted blockers require hosted evidence'),
    );
    expect(result.stderr, isNot(contains(_cleanBlockerId)));
  });

  test('status-only resolution cannot admit release', () async {
    final evidence = File(
      p.join(root.path, 'test', 'reporting', 'writer_test.dart'),
    )..createSync(recursive: true);
    _writeManifest(root, [
      _blocker(
        status: 'resolved',
        evidence: [_relativePosix(evidence.path, root.path)],
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
        evidence: [_relativePosix(testFile.path, root.path)],
        requiredTestRuns: [
          {
            'platform': 'linux',
            'path': _relativePosix(testFile.path, root.path),
            'name': 'exact resolution test',
          },
        ],
        requiredArtifacts: [
          {
            'path': _relativePosix(artifact.path, root.path),
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
        'path': _relativePosix(testFile.path, root.path),
        'name': 'walks every directory suffix relative to its retained parent',
      };
      _writeManifest(root, [
        _blocker(
          status: 'resolved',
          requiredTestRuns: [requiredRun],
          requiredArtifacts: [
            {
              'path': _relativePosix(artifact.path, root.path),
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
      hostedFile.writeAsStringSync('{"schemaVersion":2}\n');
      final invalid = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(invalid.exitCode, 2);
      expect(invalid.stderr, contains('Invalid hosted evidence'));

      hostedFile.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'blockerId': 'report-writer-hostile-path-race',
          'commitSha': commit,
          'platform': 'linux',
          'filesystem': 'NTFS',
          'testRuns': [
            {...requiredRun, 'status': 'passed'},
          ],
        }),
      );
      final wrongPlatform = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(wrongPlatform.exitCode, 2);
      expect(wrongPlatform.stderr, contains('identity mismatch'));

      hostedFile.writeAsStringSync(
        jsonEncode({
          'schemaVersion': 1,
          'blockerId': 'report-writer-hostile-path-race',
          'commitSha': commit,
          'platform': 'windows',
          'filesystem': 'ReFS',
          'testRuns': [
            {...requiredRun, 'status': 'passed'},
          ],
        }),
      );
      final wrongFilesystem = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(wrongFilesystem.exitCode, 2);
      expect(wrongFilesystem.stderr, contains('identity mismatch'));

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
          'testRuns': const <Object?>[],
        }),
      );
      final incomplete = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(incomplete.exitCode, 2);
      expect(incomplete.stderr, contains('Incomplete hosted test runs'));

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
    'multi-platform hosted evidence requires every declared platform',
    () async {
      final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('void main() {}\n');
      final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"accepted":true}\n');
      final artifactSha = sha256.convert(artifact.readAsBytesSync()).toString();
      const commit = '0123456789abcdef0123456789abcdef01234567';
      final runs = <String, Map<String, Object?>>{
        for (final platform in const ['linux', 'macos', 'windows'])
          platform: {
            'platform': platform,
            'path': _relativePosix(testFile.path, root.path),
            'name': '$platform preserves clean authority',
          },
      };
      final blocker =
          _blocker(
              id: _cleanBlockerId,
              status: 'resolved',
              evidence: [_relativePosix(testFile.path, root.path)],
              requiredTestRuns: runs.values.toList(growable: false),
              requiredArtifacts: [
                {
                  'path': _relativePosix(artifact.path, root.path),
                  'sha256': artifactSha,
                },
              ],
            )
            ..['requiredHostedEvidence'] = [
              for (final entry in runs.entries)
                {
                  'platform': entry.key,
                  'filesystem': switch (entry.key) {
                    'linux' => 'renameat2',
                    'macos' => 'renameatx_np',
                    'windows' => 'NTFS',
                    _ => throw StateError('unreachable'),
                  },
                  'testRuns': [entry.value],
                },
            ];
      _writeManifest(root, [blocker]);
      final evidenceDirectory = Directory(p.join(root.path, 'hosted'))
        ..createSync();
      for (final platform in const ['linux', 'windows']) {
        _writeHostedEvidence(
          evidenceDirectory,
          blockerId: _cleanBlockerId,
          commit: commit,
          platform: platform,
          filesystem: platform == 'linux' ? 'renameat2' : 'NTFS',
          run: runs[platform]!,
        );
      }

      final missingMacos = await _runVerifier(
        verifier,
        root,
        manifestOnly: true,
        hostedEvidenceDirectory: evidenceDirectory,
        expectedCommit: commit,
      );
      expect(missingMacos.exitCode, 2);
      expect(
        missingMacos.stderr,
        contains('Missing hosted evidence for $_cleanBlockerId on macos'),
      );

      _writeHostedEvidence(
        evidenceDirectory,
        blockerId: _cleanBlockerId,
        commit: commit,
        platform: 'macos',
        filesystem: 'renameatx_np',
        run: runs['macos']!,
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
      expect(accepted.stdout, contains('No active release blockers'));
    },
  );

  test(
    'evidence mode defers hosted artifact validation to admission',
    () async {
      final deferredPlatform = Platform.isWindows ? 'linux' : 'windows';
      final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
        ..createSync(recursive: true);
      final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
        ..createSync(recursive: true)
        ..writeAsStringSync('{"accepted":true}\n');
      final artifactSha = sha256.convert(artifact.readAsBytesSync()).toString();
      final requiredRun = {
        'platform': deferredPlatform,
        'path': _relativePosix(testFile.path, root.path),
        'name': 'hostile path race preserves foreign object',
      };
      _writeManifest(root, [
        _blocker(
          status: 'resolved',
          requiredTestRuns: [requiredRun],
          requiredArtifacts: [
            {
              'path': _relativePosix(artifact.path, root.path),
              'sha256': artifactSha,
            },
          ],
          requiredHostedEvidence: {
            'platform': deferredPlatform,
            'filesystem': 'fixture-fs',
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
    'repository registry binds clean resolution to all hosted platforms',
    () async {
      final decoded =
          jsonDecode(File('tool/release_blockers.json').readAsStringSync())
              as Map<String, Object?>;
      final blockers = decoded['blockers']! as List<Object?>;
      final clean = blockers.whereType<Map<String, Object?>>().singleWhere(
        (blocker) => blocker['id'] == _cleanBlockerId,
      );
      expect(
        clean.keys,
        unorderedEquals([
          'id',
          'status',
          'severity',
          'reason',
          'evidence',
          'requiredTestRuns',
          'requiredArtifacts',
          'requiredHostedEvidence',
        ]),
      );
      expect(clean['status'], 'resolved');
      expect(clean['severity'], 'critical');
      expect(clean['reason'], _cleanBlockerReason);
      expect(clean['evidence'], _cleanEvidencePaths);
      final hosted = clean['requiredHostedEvidence']! as List<Object?>;
      expect(hosted, hasLength(3));
      expect(
        hosted.whereType<Map<String, Object?>>().map(
          (contract) => (contract['platform'], contract['filesystem']),
        ),
        unorderedEquals(const [
          ('linux', 'renameat2'),
          ('macos', 'renameatx_np'),
          ('windows', 'NTFS'),
        ]),
      );
      expect(clean['requiredTestRuns'], isNotEmpty);
      expect(clean['requiredArtifacts'], isNotEmpty);

      final result = await _runVerifier(verifier, Directory.current);

      expect(result.exitCode, 2);
      expect(result.stderr, contains('hosted evidence'));
      // Windows conformance tests include process barriers that cannot be
      // nested safely inside the same full-suite invocation. CI runs the
      // verifier in isolation immediately after this suite succeeds.
      if (!Platform.isWindows) {
        final evidence = await _runVerifier(
          verifier,
          Directory.current,
          runTests: true,
        );
        expect(evidence.exitCode, 0);
        expect(
          evidence.stdout,
          'Resolved blocker evidence passed.\n'
          '0 active release blockers remain.\n',
        );
        expect(evidence.stderr, isEmpty);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('repository CI collects exact-SHA clean evidence from every OS', () {
    final workflow = File('.github/workflows/ci.yml').readAsStringSync();

    expect(
      RegExp(r'clean_evidence:\s+true').allMatches(workflow),
      hasLength(3),
    );
    expect(
      workflow,
      contains('dart run tool/generate_clean_blocker_evidence.dart'),
    );
    expect(
      workflow,
      contains(r'clean-blocker-evidence-${{ matrix.os }}-${{ github.sha }}'),
    );
    expect(
      workflow,
      contains(r'pattern: clean-blocker-evidence-*-${{ github.sha }}'),
    );
    expect(workflow, contains('merge-multiple: true'));
  });
}

Map<String, Object?> _activeCleanBlocker(Directory root) {
  for (final path in _cleanEvidencePaths) {
    File(p.joinAll([root.path, ...p.posix.split(path)]))
      ..createSync(recursive: true)
      ..writeAsStringSync('');
  }
  return {
    'id': _cleanBlockerId,
    'status': 'active',
    'severity': 'critical',
    'reason': _cleanBlockerReason,
    'evidence': _cleanEvidencePaths,
  };
}

Map<String, Object?> _resolvedHostedBlocker(Directory root) {
  final testFile = File(p.join(root.path, 'test', 'resolution_test.dart'))
    ..createSync(recursive: true)
    ..writeAsStringSync('void main() {}\n');
  final artifact = File(p.join(root.path, 'evidence', 'resolution.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync('{"accepted":true}\n');
  final requiredRun = {
    'platform': 'windows',
    'path': _relativePosix(testFile.path, root.path),
    'name': 'hosted fixture preserves foreign bytes',
  };
  return _blocker(
    id: 'resolved-hosted-fixture',
    status: 'resolved',
    evidence: [_relativePosix(testFile.path, root.path)],
    requiredTestRuns: [requiredRun],
    requiredArtifacts: [
      {
        'path': _relativePosix(artifact.path, root.path),
        'sha256': sha256.convert(artifact.readAsBytesSync()).toString(),
      },
    ],
    requiredHostedEvidence: {
      'platform': 'windows',
      'filesystem': 'NTFS',
      'testRuns': [requiredRun],
    },
  );
}

Map<String, Object?> _blocker({
  String id = 'report-writer-hostile-path-race',
  required String status,
  String reason = 'Atomic filesystem ownership is unavailable.',
  List<String> evidence = const [
    'test/reporting/recoverable_report_writer_test.dart',
  ],
  List<Map<String, Object?>>? requiredTestRuns,
  List<Map<String, Object?>>? requiredArtifacts,
  Map<String, Object?>? requiredHostedEvidence,
}) => {
  'id': id,
  'status': status,
  'severity': 'critical',
  'reason': reason,
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

void _writeHostedEvidence(
  Directory directory, {
  required String blockerId,
  required String commit,
  required String platform,
  required String filesystem,
  required Map<String, Object?> run,
}) {
  File(p.join(directory.path, '$blockerId-$platform.json')).writeAsStringSync(
    jsonEncode({
      'schemaVersion': 1,
      'blockerId': blockerId,
      'commitSha': commit,
      'platform': platform,
      'filesystem': filesystem,
      'testRuns': [
        {...run, 'status': 'passed'},
      ],
    }),
  );
}

String _relativePosix(String path, String root) =>
    p.relative(path, from: root).replaceAll(r'\', '/');

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
