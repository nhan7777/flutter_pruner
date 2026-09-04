import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart' as args;
import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/cli/command_runner.dart';
import 'package:flutter_pruner/src/cli/commands/rollback_command.dart';
import 'package:flutter_pruner/src/cli/terminal_text_metrics.dart';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'package:flutter_pruner/src/quarantine/manifest.dart';
import 'package:flutter_pruner/src/quarantine/quarantine_manager.dart';
import 'package:flutter_pruner/src/verification/verification_policy.dart';
import 'package:flutter_pruner/src/verification/verification_runner.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test(
    'rollback uses terminal columns when COLUMNS is absent before project mutation',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final quarantine = Directory(
          p.join(
            project.path,
            '.flutter_pruner',
            'quarantine',
            'invalid-manifest',
          ),
        )..createSync(recursive: true);
        File(
          p.join(quarantine.path, 'manifest.json'),
        ).writeAsStringSync('{not json');
        final sentinel = File(p.join(project.path, 'lib', 'sentinel.dart'));
        sentinel.parent.createSync(recursive: true);
        sentinel.writeAsStringSync('void untouched() {}\n');

        final result = await _runRollbackCaptured(
          args.CommandRunner<int>('flutter_pruner', 'fixture')
            ..addCommand(RollbackCommand(environment: () => const {})),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'invalid-manifest',
          ],
          32,
        );

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        const metrics = TerminalTextMetrics();
        expect(
          result.stderr.split('\n').where((line) => line.isNotEmpty),
          everyElement(
            predicate<String>((line) => metrics.visibleWidth(line) <= 32),
          ),
        );
        final rendered = result.stderr.replaceAll('\n', '');
        expect(rendered, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          rendered,
          contains('Working copy: no project bytes were changed.'),
        );
        expect(rendered, contains('Verification: not started.'));
        expect(
          rendered,
          contains('Quarantine: preserved at ${quarantine.path}.'),
        );
        expect(rendered, contains('Clean: not attempted.'));
        expect(
          rendered,
          contains("flutter_pruner 'quarantine' 'inspect' '--project'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(sentinel.readAsStringSync(), 'void untouched() {}\n');
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'hostile recovery action preserves exact raw argv without terminal injection',
    () async {
      final fixtureRoot = Directory.systemTemp.createTempSync(
        'rollback_hostile_action_',
      );
      final hostileSegment = Platform.isWindows
          ? "project-'quoted FORGED ACTION ROW\u0085\u202e"
          : "project-'quoted\nFORGED ACTION ROW\x1b[31m\u202e";
      final project = Directory(p.join(fixtureRoot.path, hostileSegment));
      try {
        project.createSync(recursive: true);
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_hostile_action\n');
        final quarantine = Directory(
          p.join(
            project.path,
            '.flutter_pruner',
            'quarantine',
            'invalid-manifest',
          ),
        )..createSync(recursive: true);
        File(
          p.join(quarantine.path, 'manifest.json'),
        ).writeAsStringSync('{not json');

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(),
          ['rollback', '--project', project.path, 'invalid-manifest'],
        );

        expect(result.exitCode, 1);
        expect(result.stderr, isNot(contains('\x1b')));
        expect(
          result.stderr,
          isNot(matches(RegExp(r'^FORGED', multiLine: true))),
        );
        final lines = const LineSplitter().convert(result.stderr);
        final argvLabel = lines.indexOf(
          'Exact action argv (JSON; invoke without a shell):',
        );
        expect(argvLabel, greaterThanOrEqualTo(0));
        final decoded = (jsonDecode(lines[argvLabel + 1]) as List<dynamic>)
            .cast<String>();
        final expectedProject = p.normalize(p.absolute(project.path));
        expect(decoded, <String>[
          'flutter_pruner',
          'quarantine',
          'inspect',
          '--project',
          expectedProject,
          '--quarantine',
          p.dirname(quarantine.path),
          'invalid-manifest',
        ]);

        final executed = await Process.run(Platform.resolvedExecutable, [
          'run',
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          ...decoded.skip(1),
        ], workingDirectory: Directory.current.path);
        final executedOutput = '${executed.stdout}\n${executed.stderr}';
        expect(executed.exitCode, 1);
        expect(executedOutput, contains('invalid_manifest'));
        expect(executedOutput, isNot(contains('\x1b')));
        expect(
          executedOutput,
          isNot(matches(RegExp(r'^FORGED', multiLine: true))),
        );
      } finally {
        if (fixtureRoot.existsSync()) fixtureRoot.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('V3 rollback runs verifier before claiming verified terminal', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      final run = await _createCompletedV3Run(project, runId: 'verified-v3');
      final verifier = _FixedRollbackVerifier(
        project,
        _verificationResult(project, passed: true),
      );

      final result = await _runRollbackCaptured(
        FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
        ['rollback', '--project', project.path, 'verified-v3'],
      );

      expect(result.exitCode, 0);
      expect(result.stderr, isEmpty);
      expect(result.stdout, contains('ROLLBACK COMPLETE'));
      expect(result.stdout, contains('Rollback: verified'));
      expect(
        result.stdout,
        contains('Quarantine: preserved at ${run.quarantine.path}'),
      );
      expect(result.stdout, contains("flutter_pruner 'quarantine' 'clean'"));
      expect(result.stdout, isNot(contains('flutter_pruner rollback')));
      expect(verifier.invocationCount, 1);
      expect(run.source.readAsStringSync(), 'void original() {}\n');
      final manifest = await run.manager.readManifest(run.quarantine);
      expect(manifest.fullRollbackVerified, isTrue);
      expect(
        await run.manager.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.rolledBackVerified,
      );
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'V3 rollback --clean reports verified restore and retained evidence',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'verified-clean-v3',
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'verified-clean-v3',
          ],
        );

        expect(result.exitCode, 0);
        expect(result.stderr, isEmpty);
        expect(result.stdout, contains('ROLLBACK COMPLETE'));
        expect(result.stdout, contains('Rollback: verified'));
        expect(
          result.stdout,
          contains('Quarantine clean: retained for recovery'),
        );
        expect(result.stdout, contains('Operation ID: clean-'));
        expect(result.stdout, contains('Disk space: retained'));
        expect(result.stdout, contains('Recovery copy:'));
        expect(result.stdout, isNot(contains('flutter_pruner rollback')));
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isFalse);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback restores a multi-file batch including an empty file',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3MultiFileRun(
          project,
          runId: 'multi-empty-v3',
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          ['rollback', '--project', project.path, 'multi-empty-v3'],
        );

        expect(result.exitCode, 0);
        expect(result.stderr, isEmpty);
        expect(result.stdout, contains('Rollback: verified'));
        expect(result.stdout, contains('Restored files: 2'));
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.empty.readAsBytesSync(), isEmpty);
        expect(
          File(
            p.join(
              run.quarantine.path,
              'cases',
              'case-1',
              'lib',
              'source.dart',
            ),
          ).readAsStringSync(),
          'void original() {}\n',
        );
        expect(
          File(
            p.join(run.quarantine.path, 'cases', 'case-2', 'lib', 'empty.dart'),
          ).readAsBytesSync(),
          isEmpty,
        );
        expect(run.quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback verifier failure preserves evidence and blocks clean',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'failed-verifier-v3',
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: false),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'failed-verifier-v3',
          ],
        );

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          result.stderr,
          contains('Working copy: original bytes were restored.'),
        );
        expect(
          result.stderr,
          contains('Verification: did not reproduce the recorded baseline.'),
        );
        expect(
          result.stderr,
          contains('Quarantine: recovery required at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        final manifest = await run.manager.readManifest(run.quarantine);
        expect(manifest.fullRollbackVerified, isFalse);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
        await expectLater(
          run.manager.validateCleanQuarantine(runId: 'failed-verifier-v3'),
          throwsA(isA<QuarantineException>()),
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback verifier exception preserves restored bytes and typed recovery',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'verifier-exception-v3',
        );
        final verifier = _ThrowingRollbackVerifier(
          project,
          StateError('injected verifier exception'),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'verifier-exception-v3',
          ],
        );

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          result.stderr,
          contains('Working copy: original bytes were restored.'),
        );
        expect(
          result.stderr,
          contains(
            'Verification: failed before complete evidence was returned.',
          ),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test('V3 rollback chmod during verifier cannot terminalize or clean', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      final run = await _createCompletedV3Run(
        project,
        runId: 'chmod-during-verifier-v3',
        originalPosixMode: 0x1ed,
      );
      final verifier = _MutatingRollbackVerifier(
        project,
        _verificationResult(project, passed: true),
        () => _chmod(run.source, 0x1a4),
      );

      final result = await _runRollbackCaptured(
        FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
        [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'chmod-during-verifier-v3',
        ],
      );

      expect(result.exitCode, 1);
      expect(
        result.stderr,
        contains(
          'Failure: working-copy revalidation failed before journal terminalization.',
        ),
      );
      expect(
        result.stderr,
        contains(
          'Working copy: restored state was invalidated before journal terminalization.',
        ),
      );
      expect(
        result.stderr,
        contains(
          'Verification: prior result invalidated by working-copy revalidation.',
        ),
      );
      expect(result.stderr, contains('Observed state: POSIX mode mismatch.'));
      expect(result.stderr, contains('Observed path: ${run.source.path}'));
      expect(
        result.stderr,
        isNot(contains('Working copy: original bytes were restored.')),
      );
      expect(result.stderr, isNot(contains('Verification: verified.')));
      expect(result.stderr, contains('Clean: not attempted.'));
      expect(verifier.invocationCount, 1);
      expect(run.source.readAsStringSync(), 'void original() {}\n');
      expect(_posixMode(run.source), 0x1a4);
      expect(run.quarantine.existsSync(), isTrue);
      final manifest = await run.manager.readManifest(run.quarantine);
      expect(manifest.fullRollbackVerified, isFalse);
      expect(
        await run.manager.readRunLifecycleState(run.quarantine),
        QuarantineRunLifecycleState.recoveryRequired,
      );
      await expectLater(
        run.manager.validateCleanQuarantine(runId: 'chmod-during-verifier-v3'),
        throwsA(isA<QuarantineException>()),
      );
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'V3 rollback byte drift during verifier invalidates restored evidence before terminalization',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'bytes-during-verifier-v3',
        );
        final verifier = _MutatingRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
          () =>
              run.source.writeAsStringSync('void drifted() {}\n', flush: true),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'bytes-during-verifier-v3',
          ],
        );

        expect(result.exitCode, 1);
        expect(
          result.stderr,
          contains(
            'Failure: working-copy revalidation failed before journal terminalization.',
          ),
        );
        expect(result.stderr, contains('Observed state: byte mismatch.'));
        expect(result.stderr, contains('Observed path: ${run.source.path}'));
        expect(
          result.stderr,
          isNot(contains('Working copy: original bytes were restored.')),
        );
        expect(result.stderr, isNot(contains('Verification: verified.')));
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void drifted() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(
          (await run.manager.readManifest(run.quarantine)).fullRollbackVerified,
          isFalse,
        );
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  for (final drift in _SnapshotDriftKind.values) {
    test(
      'V3 rollback ${drift.name} drift in retained snapshot does not blame the working copy',
      () async {
        if (drift == _SnapshotDriftKind.mode &&
            !Platform.isLinux &&
            !Platform.isMacOS) {
          return;
        }
        final fixtureRoot = Directory.systemTemp.createTempSync(
          'rollback_project_',
        );
        final project = drift == _SnapshotDriftKind.bytes
            ? (Directory(
                p.join(
                  fixtureRoot.path,
                  Platform.isWindows
                      ? 'snapshot FORGED SNAPSHOT ROW\u0085\u202e'
                      : 'snapshot\nFORGED SNAPSHOT ROW\x1b[31m\u202e',
                ),
              )..createSync())
            : fixtureRoot;
        try {
          final run = await _createCompletedV3Run(
            project,
            runId: 'snapshot-${drift.name}-v3',
            originalPosixMode: drift == _SnapshotDriftKind.mode ? 0x1ed : null,
          );
          final snapshot = File(
            p.join(
              run.quarantine.path,
              'cases',
              'case-1',
              'lib',
              'source.dart',
            ),
          );
          final originalBytes = snapshot.readAsBytesSync();
          final originalMode = drift == _SnapshotDriftKind.mode
              ? _posixMode(snapshot)
              : null;
          List<int>? workingCopyBytesBeforeSnapshotDrift;
          int? workingCopyModeBeforeSnapshotDrift;
          final verifier = _MutatingRollbackVerifier(
            project,
            _verificationResult(project, passed: true),
            () {
              workingCopyBytesBeforeSnapshotDrift = run.source
                  .readAsBytesSync();
              if (drift == _SnapshotDriftKind.mode) {
                workingCopyModeBeforeSnapshotDrift = _posixMode(run.source);
              }
              switch (drift) {
                case _SnapshotDriftKind.bytes:
                  snapshot.writeAsStringSync(
                    'void corruptSnapshot() {}\n',
                    flush: true,
                  );
                case _SnapshotDriftKind.mode:
                  _chmod(snapshot, 0x1a4);
                case _SnapshotDriftKind.type:
                  final path = snapshot.path;
                  snapshot.deleteSync();
                  Directory(path).createSync();
                case _SnapshotDriftKind.missing:
                  snapshot.deleteSync();
              }
            },
          );

          final result = await _runRollbackCaptured(
            FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
            [
              'rollback',
              '--clean',
              '--project',
              project.path,
              'snapshot-${drift.name}-v3',
            ],
          );

          expect(result.exitCode, 1);
          expect(result.stdout, isEmpty);
          expect(
            result.stderr,
            contains(
              'Failure: retained run-original authority failed revalidation before journal terminalization.',
            ),
          );
          expect(
            result.stderr,
            contains(
              'Working copy: not revalidated after retained authority failure.',
            ),
          );
          expect(
            result.stderr,
            contains(
              'Verification: completed, but cannot authorize terminalization because retained authority evidence failed revalidation.',
            ),
          );
          expect(
            result.stderr,
            contains('Observed role: run-original snapshot.'),
          );
          expect(
            result.stderr,
            contains(
              'Observed state: ${switch (drift) {
                _SnapshotDriftKind.bytes => 'byte mismatch',
                _SnapshotDriftKind.mode => 'POSIX mode mismatch',
                _SnapshotDriftKind.type => 'non-regular file',
                _SnapshotDriftKind.missing => 'missing',
              }}.',
            ),
          );
          if (drift == _SnapshotDriftKind.bytes) {
            final visibleSnapshotPath = snapshot.path
                .replaceAll('\n', r'\n')
                .replaceAll('\x1b', r'\x1B')
                .replaceAll('\u0085', r'\u0085')
                .replaceAll('\u202e', r'\u202E');
            expect(
              result.stderr.replaceAll('\n', ''),
              contains('Observed path: $visibleSnapshotPath'),
            );
            final visibleQuarantinePath = run.quarantine.path
                .replaceAll('\n', r'\n')
                .replaceAll('\x1b', r'\x1B')
                .replaceAll('\u0085', r'\u0085')
                .replaceAll('\u202e', r'\u202E');
            expect(
              result.stderr.replaceAll('\n', ''),
              contains(
                'Quarantine: recovery required; run-original authority is corrupt at $visibleQuarantinePath.',
              ),
            );
            expect(result.stderr, isNot(contains('\x1b')));
            expect(
              result.stderr.replaceAll('\n', ''),
              contains(
                Platform.isWindows
                    ? r' FORGED SNAPSHOT ROW\u0085\u202E'
                    : r'\nFORGED SNAPSHOT ROW\x1B[31m\u202E',
              ),
            );
            expect(result.stderr, isNot(contains('\u202e')));
          } else {
            expect(
              result.stderr.replaceAll('\n', ''),
              contains('Observed path: ${snapshot.path}'),
            );
            expect(
              result.stderr.replaceAll('\n', ''),
              contains(
                'Quarantine: recovery required; run-original authority is corrupt at ${run.quarantine.path}.',
              ),
            );
          }
          expect(result.stderr, contains('Clean: not attempted.'));
          if (drift == _SnapshotDriftKind.bytes) {
            final lines = const LineSplitter().convert(result.stderr);
            final argvLabel = lines.indexOf(
              'Exact action argv (JSON; invoke without a shell):',
            );
            expect(argvLabel, greaterThanOrEqualTo(0));
            expect(
              (jsonDecode(lines[argvLabel + 1]) as List<dynamic>)
                  .cast<String>(),
              <String>[
                'flutter_pruner',
                'quarantine',
                'inspect',
                '--project',
                p.normalize(p.absolute(project.path)),
                '--quarantine',
                run.quarantine.parent.path,
                'snapshot-bytes-v3',
              ],
            );
          } else {
            expect(
              result.stderr,
              contains("flutter_pruner 'quarantine' 'inspect'"),
            );
            expect(
              RegExp(
                "flutter_pruner 'quarantine' 'inspect'",
              ).allMatches(result.stderr),
              hasLength(1),
            );
          }
          expect(
            result.stderr,
            isNot(
              contains(
                'Working copy: restored state was invalidated before journal terminalization.',
              ),
            ),
          );
          expect(
            result.stderr,
            isNot(
              contains(
                'Verification: prior result invalidated by working-copy revalidation.',
              ),
            ),
          );
          expect(result.stderr, isNot(contains('Verification: verified.')));
          expect(result.stderr, isNot(contains('flutter_pruner rollback')));
          expect(result.stderr, isNot(contains('flutter_pruner apply')));
          expect(
            result.stderr,
            isNot(contains("flutter_pruner 'quarantine' 'clean'")),
          );
          expect(
            result.stderr,
            isNot(matches(RegExp(r'\bretry\b', caseSensitive: false))),
          );
          expect(verifier.invocationCount, 1);
          expect(workingCopyBytesBeforeSnapshotDrift, originalBytes);
          expect(run.source.readAsBytesSync(), originalBytes);
          if (originalMode != null) {
            expect(workingCopyModeBeforeSnapshotDrift, originalMode);
            expect(_posixMode(run.source), originalMode);
          }
          expect(run.quarantine.existsSync(), isTrue);
          expect(
            await run.manager.readRunLifecycleState(run.quarantine),
            QuarantineRunLifecycleState.recoveryRequired,
          );
        } finally {
          if (fixtureRoot.existsSync()) fixtureRoot.deleteSync(recursive: true);
        }
      },
    );
  }

  test(
    'verified rollback preserves evidence when logical clean cannot start',
    () async {
      if (!Platform.isLinux && !Platform.isMacOS) return;
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      Directory? quarantineBase;
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'delete-unknown-v3',
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );
        quarantineBase = run.quarantine.parent;
        _chmodPath(quarantineBase.path, 0x16d);

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'delete-unknown-v3',
          ],
        );

        expect(result.exitCode, 1);
        expect(result.stdout, contains('Rollback: verified'));
        expect(result.stdout, contains('Quarantine clean: preserved'));
        expect(result.stdout, contains(run.quarantine.path));
        expect(result.stdout, contains('Backend: recoverableLogicalMove'));
        expect(result.stderr, contains("flutter_pruner 'quarantine' 'list'"));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('Unexpected error')),
        );
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('flutter_pruner rollback')),
        );
      } finally {
        if (quarantineBase != null && quarantineBase.existsSync()) {
          _chmodPath(quarantineBase.path, 0x1ed);
        }
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'verified rollback reports clean validation failure as preserved evidence',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'clean-preserved-v3',
        );
        var verifierReturned = false;
        var artifactInjected = false;
        final verifier = _MutatingRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
          () => verifierReturned = true,
        );
        QuarantineManager managerFactory(Directory root) => QuarantineManager(
          root,
          journalHook: (point) {
            if (!verifierReturned ||
                artifactInjected ||
                point != QuarantineJournalPoint.temporaryPromoted) {
              return;
            }
            artifactInjected = true;
            final recovery = File(
              p.join(run.quarantine.path, 'recovery', 'injected', 'bytes'),
            );
            recovery.parent.createSync(recursive: true);
            recovery.writeAsStringSync('preserve me');
          },
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
          ..addCommand(
            RollbackCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: managerFactory,
            ),
          );

        final result = await _runRollbackCaptured(runner, [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'clean-preserved-v3',
        ]);

        expect(result.exitCode, 1);
        expect(result.stdout, contains('Rollback: verified'));
        expect(result.stdout, contains('Quarantine clean: preserved'));
        expect(result.stdout, contains(run.quarantine.path));
        expect(result.stdout, contains('Backend: recoverableLogicalMove'));
        expect(result.stderr, contains("flutter_pruner 'quarantine' 'list'"));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('Unexpected error')),
        );
        expect(
          '${result.stdout}\n${result.stderr}',
          isNot(contains('flutter_pruner rollback')),
        );
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(
          File(
            p.join(run.quarantine.path, 'recovery', 'injected', 'bytes'),
          ).readAsStringSync(),
          'preserve me',
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback journal terminalization failure keeps verified bytes and evidence',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'terminalization-failure-v3',
        );
        var verifierReturned = false;
        var faultThrown = false;
        final verifier = _MutatingRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
          () => verifierReturned = true,
        );
        QuarantineManager managerFactory(Directory root) => QuarantineManager(
          root,
          journalHook: (point) {
            if (verifierReturned &&
                !faultThrown &&
                point == QuarantineJournalPoint.beforePrimaryMoveToPrevious) {
              faultThrown = true;
              throw StateError('injected terminalization failure');
            }
          },
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
          ..addCommand(
            RollbackCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: managerFactory,
            ),
          );

        final result = await _runRollbackCaptured(runner, [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'terminalization-failure-v3',
        ]);

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          result.stderr,
          contains(
            'Failure: terminal journal persistence failed after restored state was revalidated.',
          ),
        );
        expect(
          result.stderr,
          contains('Working copy: original bytes were restored.'),
        );
        expect(result.stderr, contains('Verification: verified.'));
        expect(result.stderr, contains('injected terminalization failure'));
        expect(
          result.stderr,
          contains('Quarantine: recovery required at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(faultThrown, isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 restore failure before target displacement proves working copy unchanged',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'restore-before-v3',
        );
        final snapshot = File(
          p.join(run.quarantine.path, 'cases', 'case-1', 'lib', 'source.dart'),
        );
        final snapshotBytesBefore = snapshot.readAsBytesSync();
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );
        QuarantineManager managerFactory(Directory root) => QuarantineManager(
          root,
          restoreHook: (context) {
            if (context.point ==
                QuarantineRestorePoint.beforeTargetDisplacement) {
              throw StateError('injected pre-displacement restore failure');
            }
          },
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
          ..addCommand(
            RollbackCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: managerFactory,
            ),
          );

        final result = await _runRollbackCaptured(runner, [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'restore-before-v3',
        ]);

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(
          result.stderr,
          contains('Failure: restore stopped before project bytes changed.'),
        );
        expect(
          result.stderr,
          contains('Working copy: no project bytes were changed.'),
        );
        expect(result.stderr, contains('Verification: not started.'));
        expect(
          result.stderr,
          contains('Quarantine: recovery required at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 0);
        expect(run.source.readAsStringSync(), 'void modified() {}\n');
        expect(snapshot.readAsBytesSync(), snapshotBytesBefore);
        expect(run.quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 restore failure after original install reports restored unverified bytes',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'restore-after-v3',
        );
        final snapshot = File(
          p.join(run.quarantine.path, 'cases', 'case-1', 'lib', 'source.dart'),
        );
        final snapshotBytesBefore = snapshot.readAsBytesSync();
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );
        QuarantineManager managerFactory(Directory root) => QuarantineManager(
          root,
          restoreHook: (context) {
            if (context.point == QuarantineRestorePoint.afterOriginalInstall) {
              throw StateError('injected post-install restore failure');
            }
          },
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
          ..addCommand(
            RollbackCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: managerFactory,
            ),
          );

        final result = await _runRollbackCaptured(runner, [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'restore-after-v3',
        ]);

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(
          result.stderr,
          contains('Failure: restore stopped after project bytes changed.'),
        );
        expect(
          result.stderr,
          contains('Working copy: original bytes were restored.'),
        );
        expect(result.stderr, contains('Verification: not started.'));
        expect(
          result.stderr,
          contains('Quarantine: recovery required at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 0);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(snapshot.readAsBytesSync(), snapshotBytesBefore);
        expect(run.quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback accepts the same sanitized baseline-red evidence',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'baseline-red-v3',
          baselinePassed: false,
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: false),
        );

        final exitCode = await FlutterPrunerCommandRunner(
          verifierFactory: (_) => verifier,
        ).run(['rollback', '--project', project.path, 'baseline-red-v3']);

        expect(exitCode, 0);
        expect(verifier.invocationCount, 1);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        final manifest = await run.manager.readManifest(run.quarantine);
        expect(manifest.fullRollbackVerified, isTrue);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.rolledBackVerified,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'V3 rollback unconfirmed verifier termination stays recovery-required',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'unsafe-verifier-v3',
        );
        final guard = _PostVerifierGuard();
        final verifier = _UnconfirmedRollbackVerifier(
          project,
          onInvoke: guard.activate,
        );
        final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
          ..addCommand(
            RollbackCommand(
              verifierFactory: (_) => verifier,
              quarantineManagerFactory: (root) =>
                  _NoPostVerifierReadManager(root, guard),
            ),
          );

        final result = await _runRollbackCaptured(runner, [
          'rollback',
          '--clean',
          '--project',
          project.path,
          'unsafe-verifier-v3',
        ]);

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          result.stderr,
          contains(
            'Working copy: original bytes were restored; verifier outcome is unconfirmed.',
          ),
        );
        expect(
          result.stderr,
          contains('Verification: process termination could not be confirmed.'),
        );
        expect(
          result.stderr,
          contains('Quarantine: recovery required at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not attempted.'));
        expect(
          result.stderr,
          contains(
            'Do not run apply, rollback, or clean while the verifier process tree may still be alive.',
          ),
        );
        expect(
          result.stderr,
          contains('After termination is independently confirmed, inspect:'),
        );
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 1);
        expect(guard.postOutcomeCalls, isEmpty);
        expect(run.source.readAsStringSync(), 'void original() {}\n');
        expect(run.quarantine.existsSync(), isTrue);
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.recoveryRequired,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  for (final cancellation in <({Exception error, String label})>[
    (
      error: const ProcessCancellationBeforeLaunchException(
        ProcessSignal.sigint,
      ),
      label: 'before-launch cancellation',
    ),
    (
      error: const ProcessCancellationConfirmedException(
        ProcessSignal.sigterm,
        5151,
      ),
      label: 'confirmed cancellation',
    ),
  ]) {
    test(
      'V3 rollback ${cancellation.label} retains recovery-required instead of signal exit',
      () async {
        final project = Directory.systemTemp.createTempSync(
          'rollback_project_',
        );
        try {
          final run = await _createCompletedV3Run(
            project,
            runId: 'cancelled-verifier-${cancellation.error.runtimeType}',
          );
          final verifier = _CancelledRollbackVerifier(
            project,
            cancellation.error,
          );

          final result = await _runRollbackCaptured(
            FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
            [
              'rollback',
              '--clean',
              '--project',
              project.path,
              'cancelled-verifier-${cancellation.error.runtimeType}',
            ],
          );

          expect(result.exitCode, 1);
          expect(result.stdout, isEmpty);
          expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
          expect(
            result.stderr,
            contains(
              cancellation.error is ProcessCancellationBeforeLaunchException
                  ? 'Verification: not started.'
                  : 'Verification: failed before complete evidence was returned.',
            ),
          );
          expect(result.stderr, contains(cancellation.error.toString()));
          expect(result.stderr, contains('Clean: not attempted.'));
          expect(verifier.invocationCount, 1);
          expect(run.source.readAsStringSync(), 'void original() {}\n');
          expect(run.quarantine.existsSync(), isTrue);
          expect(
            await run.manager.readRunLifecycleState(run.quarantine),
            QuarantineRunLifecycleState.recoveryRequired,
          );
        } finally {
          if (project.existsSync()) project.deleteSync(recursive: true);
        }
      },
    );
  }

  for (final helper in <String>['atomic-publish', 'chmod']) {
    test(
      'V3 rollback unconfirmed $helper helper avoids post-error working-copy inspection',
      () async {
        if (!Platform.isLinux && !Platform.isMacOS) return;
        final project = Directory.systemTemp.createTempSync(
          'rollback_project_',
        );
        try {
          final run = await _createCompletedV3Run(
            project,
            runId: 'unsafe-$helper-v3',
            originalPosixMode: helper == 'chmod' ? 0x1ed : null,
          );
          final processRunner = _UnconfirmedAfterSuccessfulRollbackHelper(
            processId: helper == 'chmod' ? 5252 : 5353,
          );
          final verifier = _FixedRollbackVerifier(
            project,
            _verificationResult(project, passed: true),
          );
          final runner = args.CommandRunner<int>('flutter_pruner', 'fixture')
            ..addCommand(
              RollbackCommand(
                verifierFactory: (_) => verifier,
                quarantineManagerFactory: (root) => QuarantineManager(
                  root,
                  atomicPublishProcessRunner: helper == 'atomic-publish'
                      ? processRunner
                      : const ManagedProcessRunner(),
                  permissionProcessRunner: helper == 'chmod'
                      ? processRunner
                      : const ManagedProcessRunner(),
                ),
              ),
            );

          final result = await _runRollbackCaptured(runner, [
            'rollback',
            '--clean',
            '--project',
            project.path,
            'unsafe-$helper-v3',
          ]);

          expect(result.exitCode, 1);
          expect(result.stdout, isEmpty);
          expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
          expect(
            result.stderr,
            contains(
              'Working copy: restore outcome is unknown; project bytes may be partial.',
            ),
          );
          expect(result.stderr, contains('Verification: not started.'));
          expect(result.stderr, contains('Clean: not attempted.'));
          expect(result.stderr, contains('PID ${processRunner.processId}'));
          expect(processRunner.invocationCount, 1);
          expect(verifier.invocationCount, 0);
          expect(run.quarantine.existsSync(), isTrue);
          expect(
            await run.manager.readRunLifecycleState(run.quarantine),
            QuarantineRunLifecycleState.recoveryRequired,
          );
        } finally {
          if (project.existsSync()) project.deleteSync(recursive: true);
        }
      },
    );
  }

  test(
    'V3 rollback with legacy baseline evidence fails before mutation',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        final run = await _createCompletedV3Run(
          project,
          runId: 'legacy-evidence-v3',
          baselinePassed: null,
        );
        final verifier = _FixedRollbackVerifier(
          project,
          _verificationResult(project, passed: true),
        );

        final result = await _runRollbackCaptured(
          FlutterPrunerCommandRunner(verifierFactory: (_) => verifier),
          ['rollback', '--project', project.path, 'legacy-evidence-v3'],
        );

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          result.stderr,
          contains('Working copy: no project bytes were changed.'),
        );
        expect(result.stderr, contains('Verification: not started.'));
        expect(
          result.stderr,
          contains('Quarantine: preserved at ${run.quarantine.path}.'),
        );
        expect(result.stderr, contains('Clean: not requested.'));
        expect(
          result.stderr,
          contains("flutter_pruner 'quarantine' 'inspect'"),
        );
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(verifier.invocationCount, 0);
        expect(run.source.readAsStringSync(), 'void modified() {}\n');
        expect(
          await run.manager.readRunLifecycleState(run.quarantine),
          QuarantineRunLifecycleState.completed,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback uses the new project quarantine from another working directory',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'source.dart'));
        source.parent.createSync(recursive: true);
        source.writeAsStringSync('void original() {}\n');

        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(runId: 'run-1');
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-0001',
          findingId: 'dart:rollback_test/lib/source.dart#original',
          file: source,
          operationType: QuarantineOperationType.declaration,
        );
        source.writeAsStringSync('void modified() {}\n');
        await manager.recordCaseApplied(
          quarantineDir: quarantine,
          caseId: 'case-0001',
        );
        await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'run-1',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), 'void original() {}\n');
        final restored = await manager.readManifest(quarantine);
        expect(restored.fullRollbackVerified, isTrue);
        expect(restored.fullRollbackAtUtc, isNotNull);
        expect(restored.cases.single.status, QuarantineCaseStatus.rolledBack);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback --clean preserves unjournaled working-copy recovery bytes',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'source.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        const interrupted = 'void unjournaled() {}\n';
        source.writeAsStringSync(original);

        final manager = QuarantineManager(project);
        final quarantine = await manager.createCaseQuarantine(
          runId: 'recovery-run',
        );
        await manager.beginCase(
          quarantineDir: quarantine,
          caseId: 'case-0001',
          findingId: 'dart:rollback_test/lib/source.dart#original',
          file: source,
          operationType: QuarantineOperationType.declaration,
        );
        source.writeAsStringSync(interrupted);

        final result = await Process.run(
          Platform.resolvedExecutable,
          [
            p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
            'rollback',
            '--clean',
            '--project',
            project.path,
            'recovery-run',
          ],
          environment: <String, String>{
            ...Platform.environment,
            'COLUMNS': '32',
          },
        );

        expect(result.exitCode, 1);
        expect(result.stdout, isEmpty);
        const metrics = TerminalTextMetrics();
        expect(
          result.stderr.toString().split('\n').where((line) => line.isNotEmpty),
          everyElement(
            predicate<String>((line) => metrics.visibleWidth(line) <= 32),
          ),
        );
        final rendered = result.stderr.toString().replaceAll('\n', '');
        expect(rendered, contains('ROLLBACK RECOVERY REQUIRED'));
        expect(
          rendered,
          contains('Working copy: no project bytes were changed.'),
        );
        expect(rendered, contains('Verification: not started.'));
        expect(
          rendered,
          contains('Quarantine: recovery required at ${quarantine.path}.'),
        );
        expect(rendered, contains('Clean: not attempted.'));
        expect(rendered, contains("flutter_pruner 'quarantine' 'inspect'"));
        expect(result.stderr, isNot(contains('Unexpected error')));
        expect(source.readAsStringSync(), interrupted);
        expect(quarantine.existsSync(), isTrue);
        final recovery = File(
          p.join(
            quarantine.path,
            'recovery',
            'case-0001',
            'lib',
            'source.dart',
          ),
        );
        expect(recovery.readAsStringSync(), interrupted);
        final manifest = await manager.readManifest(quarantine);
        expect(manifest.fullRollbackVerified, isFalse);
        expect(manifest.cases.single.status, QuarantineCaseStatus.backedUp);

        final cleanResult = await Process.run(Platform.resolvedExecutable, [
          p.join(Directory.current.path, 'bin', 'flutter_pruner.dart'),
          'quarantine',
          'clean',
          '--project',
          project.path,
          'recovery-run',
        ]);
        expect(cleanResult.exitCode, 1);
        expect(cleanResult.stderr, contains('is not cleanable'));
        expect(recovery.readAsStringSync(), interrupted);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  test('rollback falls back to the legacy project quarantine', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final source = File(p.join(project.path, 'lib', 'source.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void original() {}\n');

      final manager = QuarantineManager(project);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'legacy-run',
        quarantineBase: QuarantineManager.legacyQuarantineDir,
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'dart:rollback_test/lib/source.dart#original',
        file: source,
        operationType: QuarantineOperationType.declaration,
      );
      source.writeAsStringSync('void modified() {}\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'legacy-run',
      ]);

      expect(exitCode, 0);
      expect(source.readAsStringSync(), 'void original() {}\n');
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'rollback restores V1 mode and removes adjacent publish anchor',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'legacy.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void legacy() {}\n';
        source.writeAsStringSync(original);
        final originalPosixMode = Platform.isLinux || Platform.isMacOS
            ? 0x1ed
            : null;
        if (originalPosixMode != null) _chmod(source, originalPosixMode);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
          posixMode: originalPosixMode,
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'v1-run',
          entries: [entry],
        );
        await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'v1-run',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), original);
        if (originalPosixMode != null) {
          expect(_posixMode(source), originalPosixMode);
        }
        expect(
          source.parent
              .listSync(followLinks: false)
              .where(
                (entity) => p
                    .basename(entity.path)
                    .startsWith('.flutter_pruner-restore-'),
              ),
          isEmpty,
        );
        source.writeAsStringSync(
          'void editedAfterRollback() {}\n',
          flush: true,
        );
        expect(
          source.parent
              .listSync(followLinks: false)
              .whereType<File>()
              .where(
                (file) =>
                    file.path != source.path &&
                    file.readAsStringSync() ==
                        'void editedAfterRollback() {}\n',
              ),
          isEmpty,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test(
    'rollback resumes interrupted V1 staging in the tool workspace',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'interrupted.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void original() {}\n';
        const modified = 'void modified() {}\n';
        source.writeAsStringSync(original);
        final originalPosixMode = Platform.isLinux || Platform.isMacOS
            ? 0x1ed
            : null;
        if (originalPosixMode != null) _chmod(source, originalPosixMode);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
          posixMode: originalPosixMode,
          operationType: QuarantineOperationType.declaration,
          modifiedSha256: sha256.convert(utf8.encode(modified)).toString(),
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'interrupted-v1',
          entries: [entry],
        );
        final snapshot = await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );
        source.writeAsStringSync(modified);

        final token = sha256
            .convert(utf8.encode(p.normalize(p.absolute(snapshot.path))))
            .toString()
            .substring(0, 16);
        final staging = Directory(
          p.join(
            project.path,
            '.flutter_pruner',
            'tmp',
            'restore',
            'v1-interrupted-v1-$token',
          ),
        );
        staging.createSync(recursive: true);
        final restoredStage = await snapshot.copy(
          p.join(staging.path, 'restored'),
        );
        final displacedStage = await source.copy(
          p.join(staging.path, 'displaced'),
        );
        if (originalPosixMode != null) {
          _chmod(restoredStage, originalPosixMode);
          _chmod(displacedStage, originalPosixMode);
        }
        source.deleteSync();

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'interrupted-v1',
        ]);

        expect(exitCode, 0);
        expect(source.readAsStringSync(), original);
        if (originalPosixMode != null) {
          expect(_posixMode(source), originalPosixMode);
        }
        expect(snapshot.existsSync(), isFalse);
        expect(staging.existsSync(), isFalse);
        expect(
          File(
            '${source.path}.flutter_pruner_restore_interrupted-v1.staging',
          ).existsSync(),
          isFalse,
        );
        expect(
          File(
            '${source.path}.flutter_pruner_restore_interrupted-v1.recovery',
          ).existsSync(),
          isFalse,
        );
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
      }
    },
  );

  test('rollback refuses fresh V1 modified bytes with chmod drift', () async {
    if (!Platform.isLinux && !Platform.isMacOS) return;
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final source = File(p.join(project.path, 'lib', 'mode-drift.dart'));
      source.parent.createSync(recursive: true);
      const original = 'void original() {}\n';
      const modified = 'void modified() {}\n';
      source.writeAsStringSync(original);
      _chmod(source, 0x1ed);
      final entry = QuarantineEntry(
        originalPath: source.path,
        sha256: sha256.convert(source.readAsBytesSync()).toString(),
        sizeBytes: source.lengthSync(),
        posixMode: 0x1ed,
        operationType: QuarantineOperationType.declaration,
        modifiedSha256: sha256.convert(utf8.encode(modified)).toString(),
      );
      final manager = QuarantineManager(project);
      final quarantine = await manager.createQuarantine(
        runId: 'fresh-v1-mode-drift',
        entries: [entry],
      );
      final snapshot = await manager.quarantineFile(
        file: source,
        expectedSha256: entry.sha256,
        quarantineDir: quarantine,
        originalPath: source.path,
      );
      source.writeAsStringSync(modified, flush: true);
      _chmod(source, 0x1a4);

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'fresh-v1-mode-drift',
      ]);

      expect(exitCode, 1);
      expect(source.readAsStringSync(), modified);
      expect(_posixMode(source), 0x1a4);
      expect(snapshot.existsSync(), isTrue);
      expect(
        (await manager.readManifest(quarantine)).fullRollbackVerified,
        isFalse,
      );
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
    }
  });

  test(
    'rollback refuses a V1 restore through a symlinked project parent',
    () async {
      final project = Directory.systemTemp.createTempSync('rollback_project_');
      final outside = Directory.systemTemp.createTempSync('rollback_outside_');
      try {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
        final source = File(p.join(project.path, 'lib', 'blocked.dart'));
        source.parent.createSync(recursive: true);
        const original = 'void blocked() {}\n';
        source.writeAsStringSync(original);
        final entry = QuarantineEntry(
          originalPath: source.path,
          sha256: sha256.convert(source.readAsBytesSync()).toString(),
          sizeBytes: source.lengthSync(),
        );
        final manager = QuarantineManager(project);
        final quarantine = await manager.createQuarantine(
          runId: 'symlink-parent',
          entries: [entry],
        );
        await manager.quarantineFile(
          file: source,
          expectedSha256: entry.sha256,
          quarantineDir: quarantine,
          originalPath: source.path,
        );
        source.parent.deleteSync();
        Link(p.join(project.path, 'lib')).createSync(outside.path);
        final outsideTarget = File(p.join(outside.path, 'blocked.dart'));

        final exitCode = await FlutterPrunerCommandRunner().run([
          'rollback',
          '--project',
          project.path,
          'symlink-parent',
        ]);

        expect(exitCode, 1);
        expect(outsideTarget.existsSync(), isFalse);
        expect(quarantine.existsSync(), isTrue);
      } finally {
        if (project.existsSync()) project.deleteSync(recursive: true);
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      }
    },
  );

  test('rollback refuses a V1 entry outside the selected project', () async {
    final project = Directory.systemTemp.createTempSync('rollback_project_');
    final outside = Directory.systemTemp.createTempSync('rollback_outside_');
    try {
      File(
        p.join(project.path, 'pubspec.yaml'),
      ).writeAsStringSync('name: rollback_test\n');
      final external = File(p.join(outside.path, 'external.dart'));
      external.writeAsStringSync('void external() {}\n');
      final entry = QuarantineEntry(
        originalPath: external.path,
        sha256: sha256.convert(external.readAsBytesSync()).toString(),
        sizeBytes: external.lengthSync(),
      );
      final quarantine = await QuarantineManager(
        project,
      ).createQuarantine(runId: 'outside-v1', entries: [entry]);

      final exitCode = await FlutterPrunerCommandRunner().run([
        'rollback',
        '--project',
        project.path,
        'outside-v1',
      ]);

      expect(exitCode, 1);
      expect(external.readAsStringSync(), 'void external() {}\n');
      expect(quarantine.existsSync(), isTrue);
    } finally {
      if (project.existsSync()) project.deleteSync(recursive: true);
      if (outside.existsSync()) outside.deleteSync(recursive: true);
    }
  });

  test('rollback refuses a quarantine recorded for another project', () async {
    final selected = Directory.systemTemp.createTempSync('rollback_selected_');
    final recorded = Directory.systemTemp.createTempSync('rollback_recorded_');
    try {
      for (final project in [selected, recorded]) {
        File(
          p.join(project.path, 'pubspec.yaml'),
        ).writeAsStringSync('name: rollback_test\n');
      }
      final source = File(p.join(recorded.path, 'lib', 'source.dart'));
      source.parent.createSync(recursive: true);
      source.writeAsStringSync('void original() {}\n');

      final selectedQuarantineBase = p.join(
        selected.path,
        QuarantineManager.defaultQuarantineDir,
      );
      final manager = QuarantineManager(recorded);
      final quarantine = await manager.createCaseQuarantine(
        runId: 'wrong-project',
        quarantineBase: selectedQuarantineBase,
      );
      await manager.beginCase(
        quarantineDir: quarantine,
        caseId: 'case-0001',
        findingId: 'dart:rollback_test/lib/source.dart#original',
        file: source,
        operationType: QuarantineOperationType.declaration,
      );
      source.writeAsStringSync('void modified() {}\n');
      await manager.recordCaseApplied(
        quarantineDir: quarantine,
        caseId: 'case-0001',
      );
      await manager.keepCase(quarantineDir: quarantine, caseId: 'case-0001');

      final result = await _runRollbackCaptured(FlutterPrunerCommandRunner(), [
        'rollback',
        '--clean',
        '--project',
        selected.path,
        'wrong-project',
      ]);

      expect(result.exitCode, 1);
      expect(result.stdout, isEmpty);
      expect(result.stderr, contains('ROLLBACK RECOVERY REQUIRED'));
      expect(
        result.stderr,
        contains('Working copy: no project bytes were changed.'),
      );
      expect(result.stderr, contains('Verification: not started.'));
      expect(result.stderr, contains('Selected project: ${selected.path}'));
      expect(result.stderr, contains('Recorded project: ${recorded.path}'));
      expect(result.stderr, contains('Clean: not attempted.'));
      expect(result.stderr, contains("flutter_pruner 'quarantine' 'inspect'"));
      expect(result.stderr, isNot(contains('Unexpected error')));
      expect(source.readAsStringSync(), 'void modified() {}\n');
    } finally {
      if (selected.existsSync()) selected.deleteSync(recursive: true);
      if (recorded.existsSync()) recorded.deleteSync(recursive: true);
    }
  });
}

enum _SnapshotDriftKind { bytes, mode, type, missing }

Future<({QuarantineManager manager, Directory quarantine, File source})>
_createCompletedV3Run(
  Directory project, {
  required String runId,
  bool? baselinePassed = true,
  int? originalPosixMode,
}) async {
  File(
    p.join(project.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: rollback_test\n');
  final source = File(p.join(project.path, 'lib', 'source.dart'));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync('void original() {}\n');
  if (originalPosixMode != null) _chmod(source, originalPosixMode);
  final policy = VerificationPolicy.flutterDefault;
  final baselineResult = _verificationResult(
    project,
    passed: baselinePassed ?? true,
  );
  final manager = QuarantineManager(project);
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    verificationPolicyHash: policy.hash,
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: policy.hash,
      requiredStepIds: policy.requiredStepIds,
      observedStepIds: policy.requiredStepIds,
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'rollback-test-toolchain',
      available: true,
      passed: baselinePassed,
      comparisonBaseline: baselinePassed == null
          ? null
          : baselineResult.toBaselineEvidence(),
    ),
  );
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    round: 1,
    componentId: 'unit:rollback',
    findingIds: const ['finding-1'],
    caseIds: const ['case-1'],
  );
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: 'case-1',
    findingId: 'finding-1',
    file: source,
    operationType: QuarantineOperationType.declaration,
    transactionId: 'tx-1',
  );
  source.writeAsStringSync('void modified() {}\n');
  await manager.recordCaseApplied(quarantineDir: quarantine, caseId: 'case-1');
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    caseIds: const ['case-1'],
  );
  await manager.verifyTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    policyHash: policy.hash,
    requiredStepIds: policy.requiredStepIds,
    observedStepIds: policy.requiredStepIds,
  );
  await manager.commitTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
  );
  await manager.completeApplyRun(quarantineDir: quarantine);
  return (manager: manager, quarantine: quarantine, source: source);
}

Future<
  ({QuarantineManager manager, Directory quarantine, File source, File empty})
>
_createCompletedV3MultiFileRun(
  Directory project, {
  required String runId,
}) async {
  File(
    p.join(project.path, 'pubspec.yaml'),
  ).writeAsStringSync('name: rollback_test\n');
  final source = File(p.join(project.path, 'lib', 'source.dart'));
  final empty = File(p.join(project.path, 'lib', 'empty.dart'));
  source.parent.createSync(recursive: true);
  source.writeAsStringSync('void original() {}\n');
  empty.writeAsBytesSync(const []);
  final policy = VerificationPolicy.flutterDefault;
  final baselineResult = _verificationResult(project, passed: true);
  final manager = QuarantineManager(project);
  final quarantine = await manager.createCaseQuarantine(
    runId: runId,
    verificationPolicyHash: policy.hash,
    baselineVerification: QuarantineVerificationEvidence(
      policyHash: policy.hash,
      requiredStepIds: policy.requiredStepIds,
      observedStepIds: policy.requiredStepIds,
      workingDirectory: p.normalize(p.absolute(project.path)),
      toolchainIdentity: 'rollback-test-toolchain',
      available: true,
      passed: true,
      comparisonBaseline: baselineResult.toBaselineEvidence(),
    ),
  );
  await manager.beginTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    round: 1,
    componentId: 'unit:rollback',
    findingIds: const ['finding-1', 'finding-2'],
    caseIds: const ['case-1', 'case-2'],
  );
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: 'case-1',
    findingId: 'finding-1',
    file: source,
    operationType: QuarantineOperationType.declaration,
    transactionId: 'tx-1',
  );
  await manager.beginCase(
    quarantineDir: quarantine,
    caseId: 'case-2',
    findingId: 'finding-2',
    file: empty,
    operationType: QuarantineOperationType.declaration,
    transactionId: 'tx-1',
  );
  source.writeAsStringSync('void modified() {}\n');
  empty.writeAsStringSync('not empty\n');
  for (final caseId in const ['case-1', 'case-2']) {
    await manager.recordCaseApplied(quarantineDir: quarantine, caseId: caseId);
  }
  await manager.recordTransactionApplied(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    caseIds: const ['case-1', 'case-2'],
  );
  await manager.verifyTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
    policyHash: policy.hash,
    requiredStepIds: policy.requiredStepIds,
    observedStepIds: policy.requiredStepIds,
  );
  await manager.commitTransaction(
    quarantineDir: quarantine,
    transactionId: 'tx-1',
  );
  await manager.completeApplyRun(quarantineDir: quarantine);
  return (
    manager: manager,
    quarantine: quarantine,
    source: source,
    empty: empty,
  );
}

VerificationResult _verificationResult(
  Directory project, {
  required bool passed,
}) {
  final policy = VerificationPolicy.flutterDefault;
  return VerificationResult(
    passed: passed,
    steps: [
      VerificationStep(
        name: policy.requiredStepIds[0],
        parserKind: policy.requiredParserKinds[0],
        passed: passed,
        exitCode: passed ? 0 : 1,
        stdout: passed
            ? 'No issues found!'
            : 'error • broken • lib/source.dart:1:1 • test_error\n'
                  '1 issue found.',
        stderr: '',
        duration: Duration.zero,
      ),
      VerificationStep(
        name: policy.requiredStepIds[1],
        parserKind: policy.requiredParserKinds[1],
        passed: true,
        exitCode: 0,
        stdout: '00:00 +1: All tests passed!',
        stderr: '',
        duration: Duration.zero,
      ),
    ],
    failedStep: passed ? null : policy.requiredStepIds.first,
    policyHash: policy.hash,
    requiredStepIds: policy.requiredStepIds,
    requiredParserKinds: policy.requiredParserKinds,
    workingDirectory: p.normalize(p.absolute(project.path)),
    toolchainIdentity: 'rollback-test-toolchain',
  );
}

class _FixedRollbackVerifier extends VerificationRunner {
  _FixedRollbackVerifier(super.projectRoot, this.result);

  final VerificationResult result;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    return result;
  }
}

class _MutatingRollbackVerifier extends VerificationRunner {
  _MutatingRollbackVerifier(super.projectRoot, this.result, this.mutate);

  final VerificationResult result;
  final void Function() mutate;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) async {
    invocationCount++;
    mutate();
    return result;
  }
}

class _ThrowingRollbackVerifier extends VerificationRunner {
  _ThrowingRollbackVerifier(super.projectRoot, this.error);

  final Object error;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) {
    invocationCount++;
    return Future.error(error);
  }
}

void _chmod(File file, int mode) {
  _chmodPath(file.path, mode);
}

void _chmodPath(String path, int mode) {
  final result = Process.runSync('/bin/chmod', [mode.toRadixString(8), path]);
  if (result.exitCode != 0) {
    throw StateError('chmod failed: ${result.stderr}');
  }
}

int _posixMode(File file) => file.statSync().mode & 0xfff;

class _UnconfirmedRollbackVerifier extends VerificationRunner {
  _UnconfirmedRollbackVerifier(super.projectRoot, {this.onInvoke});

  final void Function()? onInvoke;

  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) {
    invocationCount++;
    onInvoke?.call();
    return Future.error(
      const ProcessTerminationUnconfirmedException(
        processId: 42,
        message: 'injected unconfirmed verifier termination',
      ),
    );
  }
}

class _CancelledRollbackVerifier extends VerificationRunner {
  _CancelledRollbackVerifier(super.projectRoot, this.cancellation);

  final Exception cancellation;
  var invocationCount = 0;

  @override
  Future<VerificationResult> verify({
    VerificationPolicy policy = VerificationPolicy.flutterDefault,
    Duration timeout = VerificationRunner.defaultTimeout,
  }) {
    invocationCount++;
    return Future<VerificationResult>.error(cancellation);
  }
}

class _UnconfirmedAfterSuccessfulRollbackHelper
    implements ProcessExecutionRunner {
  _UnconfirmedAfterSuccessfulRollbackHelper({required this.processId});

  final int processId;
  final ProcessExecutionRunner _delegate = const ManagedProcessRunner();
  var invocationCount = 0;

  @override
  Future<ManagedProcessResult> run(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    required Duration timeout,
    required int maxOutputBytesPerStream,
  }) async {
    invocationCount++;
    await _delegate.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      timeout: timeout,
      maxOutputBytesPerStream: maxOutputBytesPerStream,
    );
    throw ProcessTerminationUnconfirmedException(
      processId: processId,
      message: 'helper PID $processId termination could not be confirmed',
      triggerSignal: ProcessSignal.sigterm,
    );
  }
}

final class _PostVerifierGuard {
  var active = false;
  final postOutcomeCalls = <String>[];

  void activate() => active = true;

  void record(String operation) {
    if (!active) return;
    postOutcomeCalls.add(operation);
    throw StateError('post-verifier operation forbidden: $operation');
  }
}

final class _NoPostVerifierReadManager extends QuarantineManager {
  _NoPostVerifierReadManager(super.projectRoot, this.guard);

  final _PostVerifierGuard guard;

  @override
  Future<QuarantineManifest> readManifest(Directory quarantineDir) {
    guard.record('readManifest');
    return super.readManifest(quarantineDir);
  }

  @override
  Future<void> verifyRunOriginalBytes({required Directory quarantineDir}) {
    guard.record('verifyRunOriginalBytes');
    return super.verifyRunOriginalBytes(quarantineDir: quarantineDir);
  }
}

Future<_CapturedRollbackRun> _runRollbackCaptured(
  args.CommandRunner<int> runner,
  List<String> arguments, [
  int? terminalColumns,
]) async {
  final capturedStdout = _RecordingStdout(
    terminalColumnsOverride: terminalColumns,
  );
  final capturedStderr = _RecordingStdout(
    terminalColumnsOverride: terminalColumns,
  );
  final exitCode = await IOOverrides.runZoned(
    () => runner.run(arguments),
    stdout: () => capturedStdout,
    stderr: () => capturedStderr,
  );
  await capturedStdout.close();
  await capturedStderr.close();
  return _CapturedRollbackRun(
    exitCode: exitCode ?? 0,
    stdout: capturedStdout.text,
    stderr: capturedStderr.text,
  );
}

final class _CapturedRollbackRun {
  const _CapturedRollbackRun({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

class _RecordingStdout implements Stdout {
  _RecordingStdout({this.terminalColumnsOverride});

  final _buffer = StringBuffer();
  final int? terminalColumnsOverride;

  String get text => _buffer.toString();

  @override
  Encoding encoding = utf8;

  @override
  String lineTerminator = '\n';

  @override
  bool get hasTerminal => terminalColumnsOverride != null;

  @override
  bool get supportsAnsiEscapes => false;

  @override
  int get terminalColumns =>
      terminalColumnsOverride ??
      (throw const StdoutException('not a terminal'));

  @override
  int get terminalLines => throw const StdoutException('not a terminal');

  @override
  IOSink get nonBlocking => this;

  @override
  void add(List<int> data) => _buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) => _buffer.write(error);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future<void> close() async {}

  @override
  Future<void> get done => Future.value();

  @override
  Future<void> flush() async {}

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) {
    _buffer
      ..write(object)
      ..write(lineTerminator);
  }
}
