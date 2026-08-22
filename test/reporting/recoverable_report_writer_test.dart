import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_pruner/src/reporting/recoverable_report_writer.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('dart:io destination resolution and success', () {
    test('creates a new absolute report without transaction residue', () async {
      final root = await _temporaryDirectory('new');
      final requested = File(p.join(root.path, 'nested', 'report.json'));
      const writer = RecoverableReportWriter();

      final resolved = await writer.resolve(requested);
      await writer.write(
        resolved,
        runId: 'run-1',
        writeTo: (sink) => sink.write('{"status":"complete"}'),
      );

      expect(p.isAbsolute(resolved.requestedPath), isTrue);
      expect(p.isAbsolute(resolved.canonicalPath), isTrue);
      expect(requested.readAsStringSync(), '{"status":"complete"}');
      expect(_transactionNames(requested.parent), isEmpty);
    });

    test('replaces an empty report and removes backup and lock', () async {
      final root = await _temporaryDirectory('empty_replacement');
      final requested = File(p.join(root.path, 'report.json'))
        ..writeAsBytesSync([]);
      const writer = RecoverableReportWriter();

      await writer.write(
        await writer.resolve(requested),
        runId: 'run-empty',
        writeTo: (sink) => sink.write('new bytes'),
      );

      expect(requested.readAsStringSync(), 'new bytes');
      expect(_transactionNames(root), isEmpty);
    });

    test('real callback failure preserves arbitrary original bytes', () async {
      final root = await _temporaryDirectory('original_bytes');
      final requested = File(p.join(root.path, 'report.json'))
        ..writeAsBytesSync([0, 255, 1, 254, 2]);
      const writer = RecoverableReportWriter();

      final error = await _captureException(() async {
        await writer.write(
          await writer.resolve(requested),
          runId: 'real-write-failure',
          writeTo: (sink) {
            sink.write('partial replacement');
            throw StateError('callback failed');
          },
        );
      });

      expect(error, isA<ReportPersistenceFailure>());
      expect(error.phase, ReportPersistencePhase.write);
      expect(requested.readAsBytesSync(), [0, 255, 1, 254, 2]);
      expect(_transactionNames(root), isEmpty);
    });

    test(
      'replaces a regular-file symlink target without replacing link',
      () async {
        final root = await _temporaryDirectory('file_link');
        final target = File(p.join(root.path, 'target', 'report.json'));
        target.parent.createSync(recursive: true);
        target.writeAsStringSync('old bytes');
        final alias = Link(p.join(root.path, 'alias.json'));
        if (!await _createLink(alias, target.path)) return;
        const writer = RecoverableReportWriter();

        final resolved = await writer.resolve(File(alias.path));
        await writer.write(
          resolved,
          runId: 'run-link',
          writeTo: (sink) => sink.write('new bytes'),
        );

        expect(resolved.requestedPath, p.normalize(p.absolute(alias.path)));
        expect(resolved.canonicalPath, target.resolveSymbolicLinksSync());
        expect(target.readAsStringSync(), 'new bytes');
        expect(
          FileSystemEntity.typeSync(alias.path, followLinks: false),
          FileSystemEntityType.link,
        );
        expect(_transactionNames(target.parent), isEmpty);
      },
    );

    test('resolves a missing leaf below a symlinked existing parent', () async {
      final root = await _temporaryDirectory('parent_link');
      final targetParent = Directory(p.join(root.path, 'real'))..createSync();
      final aliasParent = Link(p.join(root.path, 'alias'));
      if (!await _createLink(aliasParent, targetParent.path)) return;
      final requested = File(p.join(aliasParent.path, 'nested', 'report.json'));
      const writer = RecoverableReportWriter();

      final resolved = await writer.resolve(requested);
      await writer.write(
        resolved,
        runId: 'run-parent-link',
        writeTo: (sink) => sink.write('through canonical parent'),
      );

      final canonical = File(
        p.join(
          targetParent.resolveSymbolicLinksSync(),
          'nested',
          'report.json',
        ),
      );
      expect(resolved.canonicalPath, canonical.path);
      expect(canonical.readAsStringSync(), 'through canonical parent');
      expect(
        FileSystemEntity.typeSync(aliasParent.path, followLinks: false),
        FileSystemEntityType.link,
      );
      expect(_transactionNames(canonical.parent), isEmpty);
    });

    test('rejects a dangling link before any transaction mutation', () async {
      final root = await _temporaryDirectory('dangling');
      final link = Link(p.join(root.path, 'report.json'));
      if (!await _createLink(link, p.join(root.path, 'missing.json'))) return;

      await expectLater(
        const RecoverableReportWriter().resolve(File(link.path)),
        throwsA(
          isA<ReportPersistenceFailure>()
              .having(
                (error) => error.phase,
                'phase',
                ReportPersistencePhase.resolveDestination,
              )
              .having(
                (error) => error.canonicalDestination,
                'canonical destination',
                isNull,
              )
              .having((error) => error.artifacts, 'artifacts', isEmpty),
        ),
      );
      expect(_transactionNames(root), isEmpty);
    });

    test('rejects a symlink cycle before any transaction mutation', () async {
      final root = await _temporaryDirectory('cycle');
      final first = Link(p.join(root.path, 'first.json'));
      final second = Link(p.join(root.path, 'second.json'));
      if (!await _createLink(first, second.path)) return;
      await second.create(first.path);

      await expectLater(
        const RecoverableReportWriter().resolve(File(first.path)),
        throwsA(
          isA<ReportPersistenceFailure>().having(
            (error) => error.phase,
            'phase',
            ReportPersistencePhase.resolveDestination,
          ),
        ),
      );
      expect(_transactionNames(root), isEmpty);
    });

    test('rejects a symlink to a directory without mutation', () async {
      final root = await _temporaryDirectory('directory_link');
      final target = Directory(p.join(root.path, 'directory'))..createSync();
      final link = Link(p.join(root.path, 'report.json'));
      if (!await _createLink(link, target.path)) return;

      await expectLater(
        const RecoverableReportWriter().resolve(File(link.path)),
        throwsA(
          isA<ReportPersistenceFailure>().having(
            (error) => error.phase,
            'phase',
            ReportPersistencePhase.resolveDestination,
          ),
        ),
      );
      expect(_transactionNames(root), isEmpty);
    });

    test('a fresh Dart process persists a complete report cleanly', () async {
      final root = await _temporaryDirectory('fresh_process');
      final script = File(p.join(root.path, 'writer.dart'));
      final destination = File(p.join(root.path, 'result', 'report.json'));
      script.writeAsStringSync(r'''
import 'dart:io';

import 'package:flutter_pruner/src/reporting/recoverable_report_writer.dart';

Future<void> main(List<String> arguments) async {
  const writer = RecoverableReportWriter();
  final destination = await writer.resolve(File(arguments.single));
  await writer.write(
    destination,
    runId: 'fresh-process',
    writeTo: (sink) => sink.write('{"process":"fresh"}'),
  );
}
''');

      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=${p.absolute('.dart_tool/package_config.json')}',
        script.path,
        destination.path,
      ], workingDirectory: Directory.current.path);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(destination.readAsStringSync(), '{"process":"fresh"}');
      expect(_transactionNames(destination.parent), isEmpty);
    });

    test(
      'symlink alias and canonical path contend on one stable lock',
      () async {
        final root = await _temporaryDirectory('alias_contention');
        final target = File(p.join(root.path, 'target.json'))
          ..writeAsStringSync('old');
        final alias = Link(p.join(root.path, 'alias.json'));
        if (!await _createLink(alias, target.path)) return;
        final gate = _GatedOwnerOperations();
        final firstWriter = RecoverableReportWriter(operations: gate);
        const secondWriter = RecoverableReportWriter();
        final aliasDestination = await firstWriter.resolve(File(alias.path));
        final canonicalDestination = await secondWriter.resolve(target);
        expect(
          aliasDestination.canonicalPath,
          canonicalDestination.canonicalPath,
        );

        final first = firstWriter.write(
          aliasDestination,
          runId: 'first',
          writeTo: (sink) => sink.write('first report'),
        );
        await gate.ownerConfirmed;

        await expectLater(
          secondWriter.write(
            canonicalDestination,
            runId: 'second',
            writeTo: (sink) => sink.write('second report'),
          ),
          throwsA(
            isA<ReportPersistenceRecoveryRequiredException>().having(
              (error) => error.phase,
              'phase',
              ReportPersistencePhase.lock,
            ),
          ),
        );

        gate.release();
        await first;
        expect(target.readAsStringSync(), 'first report');
        expect(_transactionNames(root), isEmpty);
      },
    );

    test(
      'interrupted process leaves exact artifacts and old bytes authoritative',
      () async {
        final root = await _temporaryDirectory('interrupted_process');
        final script = File(p.join(root.path, 'interrupted_writer.dart'));
        final destination = File(p.join(root.path, 'report.json'))
          ..writeAsStringSync('sentinel bytes');
        script.writeAsStringSync(r'''
import 'dart:async';
import 'dart:io';

import 'package:flutter_pruner/src/reporting/recoverable_report_writer.dart';

Future<ReportOutputSink> blockedOpen(String path) async {
  await File(path).create(exclusive: true);
  stdout.writeln('STAGED');
  await stdout.flush();
  return Completer<ReportOutputSink>().future;
}

Future<void> main(List<String> arguments) async {
  final writer = RecoverableReportWriter(sinkFactory: blockedOpen);
  final destination = await writer.resolve(File(arguments.single));
  await writer.write(
    destination,
    runId: 'interrupted',
    writeTo: (sink) => sink.write('unreachable'),
  );
}
''');
        final process = await Process.start(Platform.resolvedExecutable, [
          '--packages=${p.absolute('.dart_tool/package_config.json')}',
          script.path,
          destination.path,
        ], workingDirectory: Directory.current.path);
        addTearDown(() async {
          process.kill();
          await process.exitCode;
        });
        expect(
          await process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10)),
          'STAGED',
        );
        expect(process.kill(), isTrue);
        await process.exitCode;

        const writer = RecoverableReportWriter();
        final resolved = await writer.resolve(destination);
        final error = await _captureException(
          () => writer.write(
            resolved,
            runId: 'after-interruption',
            writeTo: (sink) => sink.write('new bytes'),
          ),
        );
        final canonicalDirectory = p.dirname(resolved.canonicalPath);
        final basename = p.basename(resolved.canonicalPath);
        final expectedArtifacts = [
          p.join(
            canonicalDirectory,
            '.$basename.flutter_pruner.interrupted.tmp',
          ),
          p.join(canonicalDirectory, '.$basename.flutter_pruner.lock'),
        ]..sort();

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.discovery);
        expect(error.artifacts, expectedArtifacts);
        expect(destination.readAsStringSync(), 'sentinel bytes');
      },
    );

    test(
      'independent report batch uses distinct transaction identities',
      () async {
        final root = await _temporaryDirectory('batch');
        const writer = RecoverableReportWriter();
        final first = File(p.join(root.path, 'first.json'));
        final second = File(p.join(root.path, 'second.json'));

        await Future.wait([
          writer.write(
            await writer.resolve(first),
            runId: 'batch-first',
            writeTo: (sink) => sink.write('first bytes'),
          ),
          writer.write(
            await writer.resolve(second),
            runId: 'batch-second',
            writeTo: (sink) => sink.write('second bytes'),
          ),
        ]);

        expect(first.readAsStringSync(), 'first bytes');
        expect(second.readAsStringSync(), 'second bytes');
        expect(_transactionNames(root), isEmpty);
      },
    );
  });

  group('deterministic state machine', () {
    test('success closes before rename and leaves no residue', () async {
      final fixture = _Fixture(oldContents: 'old bytes');

      await fixture.write((sink) => sink.write('new bytes'));

      expect(fixture.operations.files[fixture.destination], 'new bytes');
      expect(
        fixture.operations.events,
        containsAllInOrder([
          'discover',
          'create-lock',
          'write-lock-owner',
          'discover',
          'open-temp',
          'write',
          'flush',
          'close',
          'move-previous',
          'promote',
          'delete-previous',
          'release-lock',
        ]),
      );
      expect(fixture.operations.transactionArtifacts, isEmpty);
    });

    for (final mode in _OwnerWriteMode.values.where(
      (mode) => mode != _OwnerWriteMode.success,
    )) {
      test('owner-token ${mode.name} failure retains unowned lock', () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          ownerWriteMode: mode,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.writeLockOwner);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.files, contains(fixture.lock));
        expect(error.artifacts, [fixture.lock]);
        expect(fixture.operations.deleteOwnedLockCalls, 0);
        switch (mode) {
          case _OwnerWriteMode.beforeBytes:
            expect(fixture.operations.files[fixture.lock], isEmpty);
          case _OwnerWriteMode.partial:
            expect(fixture.operations.files[fixture.lock], 'partial-owner');
          case _OwnerWriteMode.mismatch:
            expect(fixture.operations.files[fixture.lock], 'foreign-owner');
          case _OwnerWriteMode.success:
            fail('Success is excluded from this parameterized test.');
        }
      });
    }

    test(
      'callback failure closes and preserves previous bytes exactly',
      () async {
        final fixture = _Fixture(oldContents: 'old\u0000bytes');

        final error = await fixture.captureFailure((sink) {
          sink.write('partial new bytes');
          throw StateError('TOP SECRET REPORT BODY');
        });

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.write);
        expect(error.toString(), isNot(contains('TOP SECRET REPORT BODY')));
        expect(fixture.operations.files[fixture.destination], 'old\u0000bytes');
        expect(fixture.sink.closeCalls, 1);
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    for (final entry in <(_FailurePoint, ReportPersistencePhase)>[
      (_FailurePoint.sinkWrite, ReportPersistencePhase.write),
      (_FailurePoint.flush, ReportPersistencePhase.flush),
      (_FailurePoint.close, ReportPersistencePhase.close),
    ]) {
      test('${entry.$1.name} failure preserves old destination', () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: entry.$1,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, entry.$2);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.sink.closeCalls, 1);
        expect(fixture.operations.transactionArtifacts, isEmpty);
      });
    }

    test('callback failure remains primary when close also fails', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.close,
      );

      final error = await fixture.captureFailure((_) {
        throw StateError('callback failed first');
      });

      expect(error.phase, ReportPersistencePhase.write);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
      expect(fixture.operations.transactionArtifacts, isEmpty);
    });

    test('flush failure remains primary when close also fails', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.flush,
        secondaryFailurePoint: _FailurePoint.close,
      );

      final error = await fixture.captureFailure(
        (sink) => sink.write('new bytes'),
      );

      expect(error.phase, ReportPersistencePhase.flush);
      expect(fixture.sink.closeCalls, 1);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
      expect(fixture.operations.transactionArtifacts, isEmpty);
    });

    test(
      'open failure after temp creation cleans it and preserves old bytes',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.openAfterCreate,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.open);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    test(
      'first rename failure leaves previous destination authoritative',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.movePrevious,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.movePrevious);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    test(
      'partial first rename failure restores the exact previous bytes',
      () async {
        final fixture = _Fixture(
          oldContents: 'old\u0000bytes',
          failurePoint: _FailurePoint.movePreviousAfterEffect,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.movePrevious);
        expect(fixture.operations.files[fixture.destination], 'old\u0000bytes');
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    test(
      'destructive first rename failure retains lock and blocks a writer',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.movePreviousDisappear,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.restore);
        expect(fixture.operations.files, isNot(contains(fixture.destination)));
        expect(error.artifacts, [fixture.lock]);
        expect(fixture.operations.files, contains(fixture.lock));
        expect(fixture.operations.deleteOwnedLockCalls, 0);

        var secondCallbackRan = false;
        final secondError = await _captureException(
          () => fixture.writer.write(
            ResolvedReportDestination(
              requestedPath: '/requested/report.json',
              canonicalPath: fixture.destination,
            ),
            runId: 'run-2',
            writeTo: (_) => secondCallbackRan = true,
          ),
        );

        expect(secondError, isA<ReportPersistenceRecoveryRequiredException>());
        expect(secondError.phase, ReportPersistencePhase.lock);
        expect(secondError.artifacts, [fixture.lock]);
        expect(secondCallbackRan, isFalse);
        expect(fixture.operations.files, isNot(contains(fixture.destination)));
        expect(fixture.operations.files, contains(fixture.lock));
      },
    );

    test(
      'promotion failure restores previous bytes before reporting failure',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.promote,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.promote);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    for (final point in [
      _FailurePoint.promote,
      _FailurePoint.promoteAfterEffect,
    ]) {
      test(
        '${point.name} on new file restores previous nonexistence',
        () async {
          final fixture = _Fixture(oldContents: null, failurePoint: point);

          final error = await fixture.captureFailure(
            (sink) => sink.write('new bytes'),
          );

          expect(error, isA<ReportPersistenceFailure>());
          expect(error.phase, ReportPersistencePhase.promote);
          expect(
            fixture.operations.files,
            isNot(contains(fixture.destination)),
          );
          expect(fixture.operations.transactionArtifacts, isEmpty);
        },
      );
    }

    test(
      'partial promotion failure still restores previous authority',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.promoteAfterEffect,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.promote);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    test(
      'restore after-effect confirms old authority and contains failure',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.promote,
          secondaryFailurePoint: _FailurePoint.restoreAfterEffect,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.promote);
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.files, isNot(contains(fixture.previous)));
        expect(fixture.operations.transactionArtifacts, isEmpty);
        expect(fixture.operations.deleteOwnedLockCalls, 1);
      },
    );

    test(
      'destination delete after-effect restores nonexistence and releases lock',
      () async {
        final fixture = _Fixture(
          oldContents: null,
          failurePoint: _FailurePoint.promoteAfterEffect,
          secondaryFailurePoint: _FailurePoint.deleteDestinationAfterEffect,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('uncommitted new bytes'),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.promote);
        expect(error.artifacts, isEmpty);
        expect(fixture.operations.files, isNot(contains(fixture.destination)));
        expect(fixture.operations.files, isNot(contains(fixture.temp)));
        expect(fixture.operations.files, isNot(contains(fixture.previous)));
        expect(fixture.operations.files, isNot(contains(fixture.lock)));
        expect(fixture.operations.deleteOwnedLockCalls, 1);

        fixture.operations.failurePoints.clear();
        final laterWriter = RecoverableReportWriter(
          operations: fixture.operations,
          sinkFactory: fixture.sinkFactory.open,
        );
        await laterWriter.write(
          ResolvedReportDestination(
            requestedPath: '/requested/report.json',
            canonicalPath: fixture.destination,
          ),
          runId: 'run-1',
          writeTo: (sink) => sink.write('later report bytes'),
        );

        expect(
          fixture.operations.files[fixture.destination],
          'later report bytes',
        );
        expect(fixture.operations.transactionArtifacts, isEmpty);
      },
    );

    test(
      'unconfirmed new destination retains lock and blocks later writers',
      () async {
        final fixture = _Fixture(
          oldContents: null,
          failurePoint: _FailurePoint.promoteAfterEffect,
          secondaryFailurePoint: _FailurePoint.deleteDestination,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('uncommitted new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.restore);
        expect(
          fixture.operations.files[fixture.destination],
          'uncommitted new bytes',
        );
        expect(error.artifacts, [fixture.lock]);
        expect(fixture.operations.files, contains(fixture.lock));
        expect(fixture.operations.deleteOwnedLockCalls, 0);

        var secondCallbackRan = false;
        final secondError = await _captureException(
          () => fixture.writer.write(
            ResolvedReportDestination(
              requestedPath: '/requested/report.json',
              canonicalPath: fixture.destination,
            ),
            runId: 'run-2',
            writeTo: (_) => secondCallbackRan = true,
          ),
        );

        expect(secondError, isA<ReportPersistenceRecoveryRequiredException>());
        expect(secondError.phase, ReportPersistencePhase.lock);
        expect(secondError.artifacts, [fixture.lock]);
        expect(secondCallbackRan, isFalse);
        expect(
          fixture.operations.files[fixture.destination],
          'uncommitted new bytes',
        );
      },
    );

    test(
      'failed restore retains previous and requires manual recovery',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.promote,
          secondaryFailurePoint: _FailurePoint.restore,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.restore);
        expect(fixture.operations.files, isNot(contains(fixture.destination)));
        expect(fixture.operations.files[fixture.previous], 'old bytes');
        expect(error.artifacts, [fixture.lock, fixture.previous]..sort());
        expect(fixture.operations.files, contains(fixture.lock));
        expect(fixture.operations.deleteOwnedLockCalls, 0);
      },
    );

    test(
      'restore and temp cleanup failures list every surviving artifact',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.promote,
          secondaryFailurePoint: _FailurePoint.restore,
          tertiaryFailurePoint: _FailurePoint.deleteTemp,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.restore);
        expect(
          error.artifacts,
          [fixture.lock, fixture.previous, fixture.temp]..sort(),
        );
        expect(fixture.operations.files, contains(fixture.lock));
        expect(fixture.operations.deleteOwnedLockCalls, 0);
      },
    );

    test('failed temp cleanup preserves old bytes and lists temp', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.deleteTemp,
      );

      final error = await fixture.captureFailure((_) {
        throw StateError('write failed');
      });

      expect(error, isA<ReportPersistenceRecoveryRequiredException>());
      expect(error.phase, ReportPersistencePhase.cleanup);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
      expect(error.artifacts, [fixture.lock, fixture.temp]..sort());
      expect(fixture.operations.files, contains(fixture.lock));
      expect(fixture.operations.deleteOwnedLockCalls, 0);
    });

    test('failed lock cleanup before promotion requires recovery', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.releaseLock,
      );

      final error = await fixture.captureFailure((_) {
        throw StateError('write failed');
      });

      expect(error, isA<ReportPersistenceRecoveryRequiredException>());
      expect(error.phase, ReportPersistencePhase.releaseLock);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
      expect(error.artifacts, [fixture.lock]);
    });

    test(
      'failed backup deletion keeps new destination authoritative',
      () async {
        final fixture = _Fixture(
          oldContents: 'old bytes',
          failurePoint: _FailurePoint.deletePrevious,
        );

        final error = await fixture.captureFailure(
          (sink) => sink.write('complete new report'),
        );

        expect(
          error,
          isA<ReportPersistenceCommittedCleanupRequiredException>(),
        );
        expect(error.phase, ReportPersistencePhase.deletePrevious);
        expect(
          fixture.operations.files[fixture.destination],
          'complete new report',
        );
        expect(fixture.operations.files[fixture.previous], 'old bytes');
        expect(error.artifacts, [fixture.previous]);
      },
    );

    test('post-commit cleanup lists both previous and lock residue', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.deletePrevious,
        secondaryFailurePoint: _FailurePoint.releaseLock,
      );

      final error = await fixture.captureFailure(
        (sink) => sink.write('complete new report'),
      );

      expect(error, isA<ReportPersistenceCommittedCleanupRequiredException>());
      expect(error.phase, ReportPersistencePhase.deletePrevious);
      expect(
        fixture.operations.files[fixture.destination],
        'complete new report',
      );
      expect(error.artifacts, [fixture.lock, fixture.previous]..sort());
    });

    for (final point in [
      _FailurePoint.releaseLock,
      _FailurePoint.ownerMismatch,
    ]) {
      test('${point.name} after promotion never restores old bytes', () async {
        final fixture = _Fixture(oldContents: 'old bytes', failurePoint: point);

        final error = await fixture.captureFailure(
          (sink) => sink.write('complete new report'),
        );

        expect(
          error,
          isA<ReportPersistenceCommittedCleanupRequiredException>(),
        );
        expect(error.phase, ReportPersistencePhase.releaseLock);
        expect(
          fixture.operations.files[fixture.destination],
          'complete new report',
        );
        expect(error.artifacts, [fixture.lock]);
        expect(fixture.operations.files, isNot(contains(fixture.previous)));
      });
    }

    test(
      'pre-existing stable lock is retained and destination untouched',
      () async {
        final fixture = _Fixture(oldContents: 'old bytes');
        fixture.operations.files[fixture.lock] = 'existing-owner';

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.lock);
        expect(error.artifacts, [fixture.lock]);
        expect(fixture.operations.files[fixture.lock], 'existing-owner');
        expect(fixture.operations.files[fixture.destination], 'old bytes');
        expect(fixture.operations.deleteOwnedLockCalls, 0);
      },
    );

    test('lock failure with raced artifact requires recovery', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.createLockWithTemp,
      );

      final error = await fixture.captureFailure(
        (sink) => sink.write('new bytes'),
      );

      expect(error, isA<ReportPersistenceRecoveryRequiredException>());
      expect(error.phase, ReportPersistencePhase.lock);
      expect(error.artifacts, [fixture.operations.racedTemp]);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
    });

    test(
      'all stale temp and previous artifacts are rejected before lock',
      () async {
        final fixture = _Fixture(oldContents: 'old bytes');
        final otherTemp = p.join(
          p.dirname(fixture.destination),
          '.report.json.flutter_pruner.other.tmp',
        );
        fixture.operations.files
          ..[fixture.temp] = 'stale current-run bytes'
          ..[otherTemp] = 'stale other-run bytes'
          ..[fixture.previous] = 'recovery bytes';

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.discovery);
        expect(
          error.artifacts,
          [otherTemp, fixture.temp, fixture.previous]..sort(),
        );
        expect(fixture.operations.events, isNot(contains('create-lock')));
        expect(fixture.operations.files[fixture.destination], 'old bytes');
      },
    );

    test('failed discovery cannot claim that recovery is clean', () async {
      final fixture = _Fixture(
        oldContents: 'old bytes',
        failurePoint: _FailurePoint.discovery,
      );
      fixture.operations.files[fixture.previous] = 'recovery bytes';

      final error = await fixture.captureFailure(
        (sink) => sink.write('new bytes'),
      );

      expect(error, isA<ReportPersistenceRecoveryRequiredException>());
      expect(error.phase, ReportPersistencePhase.discovery);
      expect(error.artifacts, [fixture.previous]);
      expect(fixture.operations.files[fixture.destination], 'old bytes');
      expect(fixture.operations.events, isNot(contains('create-lock')));
    });

    test(
      'artifact race after locking releases owned lock and fails closed',
      () async {
        final fixture = _Fixture(oldContents: 'old bytes');
        fixture.operations.injectArtifactOnRecheck = true;

        final error = await fixture.captureFailure(
          (sink) => sink.write('new bytes'),
        );

        expect(error, isA<ReportPersistenceRecoveryRequiredException>());
        expect(error.phase, ReportPersistencePhase.discovery);
        expect(error.artifacts, [fixture.operations.racedTemp]);
        expect(fixture.operations.files, isNot(contains(fixture.lock)));
        expect(fixture.operations.files[fixture.destination], 'old bytes');
      },
    );
  });

  group('blocked hostile path races', () {
    for (final point in [
      _HostilePromotionPoint.beforeEffect,
      _HostilePromotionPoint.afterEffect,
    ]) {
      test(
        '${point.name} foreign destination survives and requires recovery',
        () async {
          final root = await _temporaryDirectory(
            'foreign_destination_${point.name}',
          );
          final destination = File(p.join(root.path, 'report.json'));
          const foreignBytes = <int>[0, 255, 1, 254, 2, 253];
          final operations = _HostilePromotionOperations(
            point: point,
            foreignBytes: foreignBytes,
          );
          final writer = RecoverableReportWriter(operations: operations);
          final resolved = await writer.resolve(destination);

          final error = await _captureException(
            () => writer.write(
              resolved,
              runId: 'foreign-${point.name}',
              writeTo: (sink) => sink.write('complete report bytes'),
            ),
          );
          final retainedBytes = destination.existsSync()
              ? destination.readAsBytesSync()
              : null;
          final retainedMode = destination.existsSync()
              ? destination.statSync().mode & 0xfff
              : null;

          expect(
            <String, Object?>{
              'recoveryRequired':
                  error is ReportPersistenceRecoveryRequiredException,
              'type': FileSystemEntity.typeSync(
                destination.path,
                followLinks: false,
              ),
              'bytesRetained':
                  retainedBytes != null &&
                  base64Encode(retainedBytes) == base64Encode(foreignBytes),
              'sha256Retained':
                  retainedBytes != null &&
                  sha256.convert(retainedBytes).toString() ==
                      sha256.convert(foreignBytes).toString(),
              'modeRetained': retainedMode == operations.foreignMode,
            },
            <String, Object?>{
              'recoveryRequired': true,
              'type': FileSystemEntityType.file,
              'bytesRetained': true,
              'sha256Retained': true,
              'modeRetained': true,
            },
          );
        },
        skip: _blockedHostileRaceSkip,
      );
    }

    test(
      'lock symlink swap preserves external target and requires recovery',
      () async {
        final root = await _temporaryDirectory('lock_symlink_swap');
        final destination = File(p.join(root.path, 'report.json'));
        final external = File(p.join(root.path, 'external.bin'))
          ..writeAsBytesSync(const [0, 255, 3, 252, 4, 251]);
        final probe = Link(p.join(root.path, 'link-probe'));
        if (!await _createLink(probe, external.path)) return;
        await probe.delete();
        final originalBytes = external.readAsBytesSync();
        final originalMode = external.statSync().mode & 0xfff;
        final originalSha256 = sha256.convert(originalBytes).toString();
        final operations = _LockSymlinkSwapOperations(external);
        final writer = RecoverableReportWriter(operations: operations);

        Object? failure;
        try {
          await writer.write(
            await writer.resolve(destination),
            runId: 'lock-symlink-swap',
            writeTo: (sink) => sink.write('complete report bytes'),
          );
        } catch (error) {
          failure = error;
        }
        final retainedBytes = external.readAsBytesSync();

        expect(
          <String, Object?>{
            'recoveryRequired':
                failure is ReportPersistenceRecoveryRequiredException,
            'bytesRetained':
                base64Encode(retainedBytes) == base64Encode(originalBytes),
            'sha256Retained':
                sha256.convert(retainedBytes).toString() == originalSha256,
            'modeRetained': external.statSync().mode & 0xfff == originalMode,
            'destinationExists': destination.existsSync(),
          },
          <String, Object?>{
            'recoveryRequired': true,
            'bytesRetained': true,
            'sha256Retained': true,
            'modeRetained': true,
            'destinationExists': false,
          },
        );
      },
      skip: _blockedHostileRaceSkip,
    );
  });

  group('stable diagnostics', () {
    test('all persistence exception strings are stable and sanitized', () {
      final errors = <ReportPersistenceException>[
        ReportPersistenceFailure(
          phase: ReportPersistencePhase.write,
          requestedDestination: '/requested/report.json',
          canonicalDestination: null,
          artifacts: const [],
          cause: StateError('SECRET REPORT BODY'),
        ),
        const ReportPersistenceRecoveryRequiredException(
          phase: ReportPersistencePhase.restore,
          requestedDestination: '/requested/report.json',
          canonicalDestination: '/canonical/report.json',
          artifacts: ['/canonical/.report.json.flutter_pruner.previous'],
          cause: FileSystemException('SECRET REPORT BODY'),
        ),
        const ReportPersistenceCommittedCleanupRequiredException(
          phase: ReportPersistencePhase.releaseLock,
          requestedDestination: '/requested/report.json',
          canonicalDestination: '/canonical/report.json',
          artifacts: ['/canonical/.report.json.flutter_pruner.lock'],
          cause: FormatException('SECRET REPORT BODY'),
        ),
      ];

      expect(errors.map((error) => error.toString()), [
        'Report persistence failed; phase=write; '
            'requested="/requested/report.json"; canonical=<unresolved>; '
            'artifacts=[]; cause=state',
        'Report persistence recovery required; phase=restore; '
            'requested="/requested/report.json"; '
            'canonical="/canonical/report.json"; '
            'artifacts=["/canonical/.report.json.flutter_pruner.previous"]; '
            'cause=filesystem',
        'Report saved but persistence cleanup is required; '
            'phase=releaseLock; requested="/requested/report.json"; '
            'canonical="/canonical/report.json"; '
            'artifacts=["/canonical/.report.json.flutter_pruner.lock"]; '
            'cause=format',
      ]);
      for (final error in errors) {
        expect(error.toString(), isNot(contains('SECRET REPORT BODY')));
      }
    });

    test(
      'resolution failure has unresolved canonical path and no artifacts',
      () async {
        final operations = _FakeOperations('/canonical/report.json')
          ..resolveFailure = StateError('source report contents');
        final writer = RecoverableReportWriter(operations: operations);

        final error = await _captureException(
          () => writer.resolve(File('/requested/report.json')),
        );

        expect(error, isA<ReportPersistenceFailure>());
        expect(error.phase, ReportPersistencePhase.resolveDestination);
        expect(error.canonicalDestination, isNull);
        expect(error.artifacts, isEmpty);
        expect(error.toString(), contains('canonical=<unresolved>'));
        expect(error.toString(), isNot(contains('source report contents')));
        expect(operations.events, ['resolve']);
      },
    );
  });
}

Future<Directory> _temporaryDirectory(String suffix) async {
  final directory = await Directory.systemTemp.createTemp(
    'flutter_pruner_report_writer_${suffix}_',
  );
  addTearDown(() async {
    if (directory.existsSync()) await directory.delete(recursive: true);
  });
  return directory;
}

Future<bool> _createLink(Link link, String target) async {
  try {
    await link.create(target);
    return true;
  } on FileSystemException catch (error) {
    markTestSkipped(
      'Symbolic links are unavailable: ${error.osError?.errorCode}',
    );
    return false;
  }
}

List<String> _transactionNames(Directory directory) {
  if (!directory.existsSync()) return const [];
  return directory
      .listSync()
      .map((entity) => p.basename(entity.path))
      .where((name) => name.contains('.flutter_pruner.'))
      .toList()
    ..sort();
}

Future<ReportPersistenceException> _captureException(
  Future<void> Function() callback,
) async {
  try {
    await callback();
  } on ReportPersistenceException catch (error) {
    return error;
  }
  fail('Expected a ReportPersistenceException.');
}

enum _FailurePoint {
  none,
  discovery,
  createLockWithTemp,
  openAfterCreate,
  sinkWrite,
  flush,
  close,
  movePrevious,
  movePreviousAfterEffect,
  movePreviousDisappear,
  promote,
  promoteAfterEffect,
  restore,
  restoreAfterEffect,
  deleteTemp,
  deleteDestination,
  deleteDestinationAfterEffect,
  deletePrevious,
  releaseLock,
  ownerMismatch,
}

enum _OwnerWriteMode { success, beforeBytes, partial, mismatch }

const _blockedHostileRaceSkip =
    'BLOCKED: dart:io has no portable atomic owner-bound lock or '
    'no-clobber promotion primitive.';

enum _HostilePromotionPoint { beforeEffect, afterEffect }

final class _HostilePromotionOperations implements ReportFileOperations {
  _HostilePromotionOperations({
    required this.point,
    required this.foreignBytes,
  });

  final _HostilePromotionPoint point;
  final List<int> foreignBytes;
  final ReportFileOperations _delegate = const IoReportFileOperations();
  int? foreignMode;

  @override
  Future<ResolvedReportDestination> resolveDestination(String requestedPath) =>
      _delegate.resolveDestination(requestedPath);

  @override
  Future<void> createParent(String destination) =>
      _delegate.createParent(destination);

  @override
  Future<void> createExclusive(String path) => _delegate.createExclusive(path);

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) =>
      _delegate.writeAndConfirmLockOwner(path, ownerToken);

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<void> rename(String from, String to) async {
    if (!from.endsWith('.tmp')) {
      await _delegate.rename(from, to);
      return;
    }
    final foreign = File(to)..writeAsBytesSync(foreignBytes);
    foreignMode = foreign.statSync().mode & 0xfff;
    if (point == _HostilePromotionPoint.beforeEffect) {
      throw FileSystemException('promotion failed before effect', to);
    }
    await _delegate.rename(from, to);
    throw FileSystemException('promotion failed after effect', to);
  }

  @override
  Future<void> delete(String path) => _delegate.delete(path);

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) =>
      _delegate.deleteOwnedLock(path, ownerToken);

  @override
  Future<List<String>> transactionArtifactsFor(String destination) =>
      _delegate.transactionArtifactsFor(destination);
}

final class _LockSymlinkSwapOperations implements ReportFileOperations {
  _LockSymlinkSwapOperations(this.external);

  final File external;
  final ReportFileOperations _delegate = const IoReportFileOperations();

  @override
  Future<ResolvedReportDestination> resolveDestination(String requestedPath) =>
      _delegate.resolveDestination(requestedPath);

  @override
  Future<void> createParent(String destination) =>
      _delegate.createParent(destination);

  @override
  Future<void> createExclusive(String path) async {
    await _delegate.createExclusive(path);
    await File(path).delete();
    await Link(path).create(external.path);
  }

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) =>
      _delegate.writeAndConfirmLockOwner(path, ownerToken);

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<void> rename(String from, String to) => _delegate.rename(from, to);

  @override
  Future<void> delete(String path) => _delegate.delete(path);

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) =>
      _delegate.deleteOwnedLock(path, ownerToken);

  @override
  Future<List<String>> transactionArtifactsFor(String destination) =>
      _delegate.transactionArtifactsFor(destination);
}

final class _Fixture {
  _Fixture({
    required String? oldContents,
    _FailurePoint failurePoint = _FailurePoint.none,
    _FailurePoint secondaryFailurePoint = _FailurePoint.none,
    _FailurePoint tertiaryFailurePoint = _FailurePoint.none,
    _OwnerWriteMode ownerWriteMode = _OwnerWriteMode.success,
  }) : operations = _FakeOperations(
         p.join(Directory.systemTemp.path, 'fake-canonical', 'report.json'),
         ownerWriteMode: ownerWriteMode,
         failurePoints: {
           failurePoint,
           secondaryFailurePoint,
           tertiaryFailurePoint,
         },
       ) {
    if (oldContents != null) operations.files[destination] = oldContents;
    sinkFactory = _FakeSinkFactory(operations);
    writer = RecoverableReportWriter(
      operations: operations,
      sinkFactory: sinkFactory.open,
    );
  }

  final _FakeOperations operations;
  late final _FakeSinkFactory sinkFactory;
  late final RecoverableReportWriter writer;

  String get destination => operations.destination;
  String get lock => operations.lock;
  String get previous => operations.previous;
  String get temp => operations.temp;
  _FakeReportOutputSink get sink => sinkFactory.lastSink!;

  Future<void> write(ReportSinkCallback callback) => writer.write(
    ResolvedReportDestination(
      requestedPath: p.join(
        Directory.systemTemp.path,
        'fake-requested',
        'report.json',
      ),
      canonicalPath: destination,
    ),
    runId: 'run-1',
    writeTo: callback,
  );

  Future<ReportPersistenceException> captureFailure(
    ReportSinkCallback callback,
  ) => _captureException(() => write(callback));
}

final class _FakeOperations implements ReportFileOperations {
  _FakeOperations(
    this.destination, {
    this.ownerWriteMode = _OwnerWriteMode.success,
    Set<_FailurePoint>? failurePoints,
  }) : failurePoints = failurePoints ?? <_FailurePoint>{};

  final String destination;
  final _OwnerWriteMode ownerWriteMode;
  final Set<_FailurePoint> failurePoints;
  final Map<String, String> files = {};
  final List<String> events = [];
  Object? resolveFailure;
  var deleteOwnedLockCalls = 0;
  var artifactDiscoveryCalls = 0;
  var injectArtifactOnRecheck = false;

  String get directory => p.dirname(destination);
  String get basename => p.basename(destination);
  String get lock => p.join(directory, '.$basename.flutter_pruner.lock');
  String get previous =>
      p.join(directory, '.$basename.flutter_pruner.previous');
  String get temp => p.join(directory, '.$basename.flutter_pruner.run-1.tmp');
  String get racedTemp =>
      p.join(directory, '.$basename.flutter_pruner.raced.tmp');

  List<String> get transactionArtifacts {
    final prefix = '.$basename.flutter_pruner.';
    final artifacts = files.keys.where((path) {
      final name = p.basename(path);
      return path != destination &&
          (name == '.$basename.flutter_pruner.previous' ||
              (name.startsWith(prefix) && name.endsWith('.tmp')) ||
              name == '.$basename.flutter_pruner.lock');
    }).toList()..sort();
    return artifacts;
  }

  @override
  Future<ResolvedReportDestination> resolveDestination(
    String requestedPath,
  ) async {
    events.add('resolve');
    if (resolveFailure case final failure?) {
      Error.throwWithStackTrace(failure, StackTrace.current);
    }
    return ResolvedReportDestination(
      requestedPath: p.normalize(p.absolute(requestedPath)),
      canonicalPath: destination,
    );
  }

  @override
  Future<void> createParent(String destination) async {
    events.add('create-parent');
  }

  @override
  Future<void> createExclusive(String path) async {
    events.add('create-lock');
    if (failurePoints.contains(_FailurePoint.createLockWithTemp)) {
      files[racedTemp] = 'raced bytes';
      throw FileSystemException('lock failed after artifact race');
    }
    if (files.containsKey(path)) throw FileSystemException('already exists');
    files[path] = '';
  }

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) async {
    events.add('write-lock-owner');
    switch (ownerWriteMode) {
      case _OwnerWriteMode.success:
        files[path] = ownerToken;
      case _OwnerWriteMode.beforeBytes:
        throw FileSystemException('owner write failed before bytes');
      case _OwnerWriteMode.partial:
        files[path] = 'partial-owner';
        throw FileSystemException('owner write was partial');
      case _OwnerWriteMode.mismatch:
        files[path] = 'foreign-owner';
        throw StateError('owner token mismatch');
    }
  }

  @override
  Future<bool> exists(String path) async => files.containsKey(path);

  @override
  Future<void> rename(String from, String to) async {
    final point = switch ((from, to)) {
      (final source, final target)
          when source == destination && target == previous =>
        _FailurePoint.movePrevious,
      (final source, final target)
          when source == temp && target == destination =>
        _FailurePoint.promote,
      (final source, final target)
          when source == previous && target == destination =>
        _FailurePoint.restore,
      _ => _FailurePoint.none,
    };
    events.add(switch (point) {
      _FailurePoint.movePrevious => 'move-previous',
      _FailurePoint.promote => 'promote',
      _FailurePoint.restore => 'restore',
      _ => 'rename',
    });
    final failAfterEffect =
        (point == _FailurePoint.movePrevious &&
            failurePoints.contains(_FailurePoint.movePreviousAfterEffect)) ||
        (point == _FailurePoint.promote &&
            failurePoints.contains(_FailurePoint.promoteAfterEffect)) ||
        (point == _FailurePoint.restore &&
            failurePoints.contains(_FailurePoint.restoreAfterEffect));
    if (point == _FailurePoint.movePrevious &&
        failurePoints.contains(_FailurePoint.movePreviousDisappear)) {
      files.remove(from);
      throw FileSystemException('movePrevious lost its source before failing');
    }
    if (failurePoints.contains(point) && !failAfterEffect) {
      throw FileSystemException('${point.name} failed');
    }
    final contents = files.remove(from);
    if (contents == null) throw FileSystemException('source missing: $from');
    files[to] = contents;
    if (failAfterEffect) {
      throw FileSystemException('${point.name} failed after effect');
    }
  }

  @override
  Future<void> delete(String path) async {
    final isTemp = p.basename(path).endsWith('.tmp');
    if (isTemp && failurePoints.contains(_FailurePoint.deleteTemp)) {
      events.add('delete-temp');
      throw FileSystemException('temp deletion failed');
    }
    if (path == destination &&
        failurePoints.contains(_FailurePoint.deleteDestination)) {
      events.add('delete-destination');
      throw FileSystemException('destination deletion failed');
    }
    if (path == destination &&
        failurePoints.contains(_FailurePoint.deleteDestinationAfterEffect)) {
      events.add('delete-destination');
      if (files.remove(path) == null) {
        throw FileSystemException('delete target missing: $path');
      }
      throw FileSystemException('destination deletion failed after effect');
    }
    if (path == previous &&
        failurePoints.contains(_FailurePoint.deletePrevious)) {
      events.add('delete-previous');
      throw FileSystemException('previous deletion failed');
    }
    events.add(
      path == previous
          ? 'delete-previous'
          : path == destination
          ? 'delete-destination'
          : 'delete-temp',
    );
    if (files.remove(path) == null) {
      throw FileSystemException('delete target missing: $path');
    }
  }

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) async {
    events.add('release-lock');
    deleteOwnedLockCalls++;
    if (failurePoints.contains(_FailurePoint.releaseLock)) {
      throw FileSystemException('lock deletion failed');
    }
    if (failurePoints.contains(_FailurePoint.ownerMismatch)) {
      files[path] = 'foreign-owner';
      return false;
    }
    if (files[path] != ownerToken) return false;
    files.remove(path);
    return true;
  }

  @override
  Future<List<String>> transactionArtifactsFor(String destination) async {
    events.add('discover');
    artifactDiscoveryCalls++;
    if (failurePoints.contains(_FailurePoint.discovery)) {
      throw FileSystemException('artifact discovery failed');
    }
    if (injectArtifactOnRecheck && artifactDiscoveryCalls == 2) {
      files[racedTemp] = 'raced bytes';
    }
    final prefix = '.$basename.flutter_pruner.';
    return files.keys.where((path) {
      final name = p.basename(path);
      return name == '.$basename.flutter_pruner.previous' ||
          (name.startsWith(prefix) && name.endsWith('.tmp'));
    }).toList()..sort();
  }
}

final class _FakeSinkFactory {
  _FakeSinkFactory(this.operations);

  final _FakeOperations operations;
  _FakeReportOutputSink? lastSink;

  Future<ReportOutputSink> open(String path) async {
    operations.events.add('open-temp');
    if (operations.files.containsKey(path)) {
      throw FileSystemException('temp already exists');
    }
    operations.files[path] = '';
    if (operations.failurePoints.contains(_FailurePoint.openAfterCreate)) {
      throw FileSystemException('open failed after create');
    }
    return lastSink = _FakeReportOutputSink(operations, path);
  }
}

final class _FakeReportOutputSink implements ReportOutputSink {
  _FakeReportOutputSink(this.operations, this.path);

  final _FakeOperations operations;
  final String path;
  var closeCalls = 0;

  @override
  void write(Object? object) {
    operations.events.add('write');
    if (operations.failurePoints.contains(_FailurePoint.sinkWrite)) {
      throw StateError('sink rejected SECRET REPORT BODY');
    }
    operations.files[path] = '${operations.files[path]}$object';
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    write(objects.join(separator));
  }

  @override
  void writeCharCode(int charCode) {
    write(String.fromCharCode(charCode));
  }

  @override
  void writeln([Object? object = '']) {
    write('$object\n');
  }

  @override
  Future<void> flush() async {
    operations.events.add('flush');
    if (operations.failurePoints.contains(_FailurePoint.flush)) {
      throw FileSystemException('flush failed');
    }
  }

  @override
  Future<void> close() async {
    operations.events.add('close');
    closeCalls++;
    if (operations.failurePoints.contains(_FailurePoint.close)) {
      throw FileSystemException('close failed');
    }
  }
}

final class _GatedOwnerOperations implements ReportFileOperations {
  final IoReportFileOperations _delegate = const IoReportFileOperations();
  final Completer<void> _confirmed = Completer<void>();
  final Completer<void> _release = Completer<void>();

  Future<void> get ownerConfirmed => _confirmed.future;

  void release() => _release.complete();

  @override
  Future<ResolvedReportDestination> resolveDestination(String requestedPath) =>
      _delegate.resolveDestination(requestedPath);

  @override
  Future<void> createParent(String destination) =>
      _delegate.createParent(destination);

  @override
  Future<void> createExclusive(String path) => _delegate.createExclusive(path);

  @override
  Future<void> writeAndConfirmLockOwner(String path, String ownerToken) async {
    await _delegate.writeAndConfirmLockOwner(path, ownerToken);
    _confirmed.complete();
    await _release.future;
  }

  @override
  Future<bool> exists(String path) => _delegate.exists(path);

  @override
  Future<void> rename(String from, String to) => _delegate.rename(from, to);

  @override
  Future<void> delete(String path) => _delegate.delete(path);

  @override
  Future<bool> deleteOwnedLock(String path, String ownerToken) =>
      _delegate.deleteOwnedLock(path, ownerToken);

  @override
  Future<List<String>> transactionArtifactsFor(String destination) =>
      _delegate.transactionArtifactsFor(destination);
}
