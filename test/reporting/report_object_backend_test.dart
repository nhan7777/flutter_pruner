import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:flutter_pruner/src/reporting/io_report_object_backend.dart';
import 'package:flutter_pruner/src/reporting/report_object_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('report object leaf validation', () {
    test('accepts generated and explicit-output compatible leaves', () {
      for (final leaf in <String>[
        'scan-20260822T000000.000000Z_0123456789abcdefabcd.json',
        'apply-run_1-export.html',
        'My report 1.json',
        '報告.json',
      ]) {
        expect(() => validateReportObjectLeaf(leaf), returnsNormally);
      }
    });

    test('rejects traversal, alternate separators, controls, and aliases', () {
      for (final leaf in <String>[
        '',
        '.',
        '..',
        '../report.json',
        'nested/report.json',
        r'nested\report.json',
        'stream:report.json',
        'report.json.',
        'report.json ',
        'CON',
        'lpt1.txt',
        'report\u0000.json',
        'report\u007f.json',
      ]) {
        expect(
          () => validateReportObjectLeaf(leaf),
          throwsA(
            isA<ReportObjectBackendException>().having(
              (error) => error.category,
              'category',
              ReportObjectBackendFailure.invalidLeaf,
            ),
          ),
          reason: leaf,
        );
      }
    });
  });

  test(
    'exclusive capability uses one retained object for write and read',
    () async {
      final object = _MemoryExclusiveReportObject(
        ReportObjectIdentity(
          storageId: 'memory-store',
          objectId: 'object-1',
          byteLength: 0,
        ),
      );
      final directory = _MemoryAnchoredReportDirectory(object);
      final created = await directory.createExclusive('report.json');

      await created.write(const [1, 2, 3, 4]);
      await created.flush();
      await created.rewind();

      expect(await created.read(32), const [1, 2, 3, 4]);
      expect(
        await created.identity(),
        ReportObjectIdentity(
          storageId: 'memory-store',
          objectId: 'object-1',
          byteLength: 4,
        ),
      );
      expect(directory.createdObject, same(created));
      expect(object.flushCount, 1);
    },
  );

  test(
    'complete write retries short native writes without losing bytes',
    () async {
      final offsets = <int>[];
      final requested = <int>[];
      final counts = <int>[2, 1, 3];

      await writeAllReportBytes(6, (offset, length) async {
        offsets.add(offset);
        requested.add(length);
        return counts.removeAt(0);
      });

      expect(offsets, const [0, 2, 3]);
      expect(requested, const [6, 4, 3]);
    },
  );

  test('complete write fails closed on an impossible native result', () async {
    await expectLater(
      writeAllReportBytes(4, (_, _) async => 0),
      throwsA(
        isA<ReportObjectBackendException>().having(
          (error) => error.category,
          'category',
          ReportObjectBackendFailure.unsupportedCapability,
        ),
      ),
    );
  });

  group('first-error precedence', () {
    test('retains body error when close also fails', () async {
      final bodyError = StateError('write failed');
      var closeCalled = false;

      await expectLater(
        runWithReportCapability<void>(
          body: () async => throw bodyError,
          close: () async {
            closeCalled = true;
            throw StateError('close failed');
          },
        ),
        throwsA(same(bodyError)),
      );
      expect(closeCalled, isTrue);
    });

    test('reports close error when the body succeeds', () async {
      final closeError = StateError('close failed');

      await expectLater(
        runWithReportCapability<void>(
          body: () async {},
          close: () async => throw closeError,
        ),
        throwsA(same(closeError)),
      );
    });
  });

  test('capability interfaces expose no path mutation methods', () {
    final root = Directory.current.path;
    final source = File(
      p.join(root, 'lib', 'src', 'reporting', 'report_object_backend.dart'),
    ).readAsStringSync();
    final unit = parseString(content: source, throwIfDiagnostics: true).unit;
    final methods = <String, Set<String>>{};

    for (final declaration in unit.declarations.whereType<ClassDeclaration>()) {
      if (!const {
        'ReportObjectBackend',
        'AnchoredReportDirectory',
        'ExclusiveReportObject',
        'ExistingReportObject',
      }.contains(declaration.namePart.typeName.lexeme)) {
        continue;
      }
      methods[declaration.namePart.typeName.lexeme] = declaration.body.members
          .whereType<MethodDeclaration>()
          .map((method) => method.name.lexeme)
          .toSet();
    }

    expect(methods, {
      'ReportObjectBackend': {'anchor'},
      'AnchoredReportDirectory': {
        'canonicalPath',
        'createExclusive',
        'openExisting',
        'verifyReachable',
        'close',
      },
      'ExclusiveReportObject': {
        'write',
        'flush',
        'rewind',
        'read',
        'identity',
        'close',
      },
      'ExistingReportObject': {'rewind', 'read', 'identity', 'close'},
    });
  });

  group('IO backend dispatch', () {
    test('routes only recognized production platform families', () {
      final posix = _MemoryReportObjectBackend();
      final windows = _MemoryReportObjectBackend();

      expect(
        createIoReportObjectBackend(
          hostPlatform: ReportHostPlatform.linux,
          posixFactory: () => posix,
          windowsFactory: () => windows,
        ),
        same(posix),
      );
      expect(
        createIoReportObjectBackend(
          hostPlatform: ReportHostPlatform.macos,
          posixFactory: () => posix,
          windowsFactory: () => windows,
        ),
        same(posix),
      );
      expect(
        createIoReportObjectBackend(
          hostPlatform: ReportHostPlatform.windows,
          posixFactory: () => posix,
          windowsFactory: () => windows,
        ),
        same(windows),
      );
    });

    test('fails closed when a recognized capability is unavailable', () {
      expect(
        () => createIoReportObjectBackend(
          hostPlatform: ReportHostPlatform.windows,
          windowsFactory: () => throw const ReportObjectBackendException(
            category: ReportObjectBackendFailure.unsupportedCapability,
            operation: 'test-capability',
          ),
        ),
        throwsA(
          isA<ReportObjectBackendException>().having(
            (error) => error.category,
            'category',
            ReportObjectBackendFailure.unsupportedCapability,
          ),
        ),
      );
    });

    test('rejects unsupported platforms without disclosing host input', () {
      late ReportObjectBackendException error;
      try {
        createIoReportObjectBackend(
          hostPlatform: ReportHostPlatform.unsupported,
        );
        fail('unsupported platform unexpectedly selected a backend');
      } on ReportObjectBackendException catch (caught) {
        error = caught;
      }

      expect(error.category, ReportObjectBackendFailure.unsupportedPlatform);
      expect(
        error.toString(),
        isNot(contains(Platform.operatingSystemVersion)),
      );
      expect(error.toString(), isNot(contains(Directory.current.path)));
    });
  });
}

final class _MemoryReportObjectBackend implements ReportObjectBackend {
  @override
  Future<AnchoredReportDirectory> anchor(Directory directory) {
    throw UnimplementedError();
  }
}

final class _MemoryAnchoredReportDirectory implements AnchoredReportDirectory {
  _MemoryAnchoredReportDirectory(this.createdObject);

  final _MemoryExclusiveReportObject createdObject;

  @override
  String get canonicalPath => '/memory/reports';

  @override
  Future<void> close() async {}

  @override
  Future<ExclusiveReportObject> createExclusive(String leaf) async {
    validateReportObjectLeaf(leaf);
    return createdObject;
  }

  @override
  Future<ExistingReportObject> openExisting(String leaf) {
    throw UnimplementedError();
  }

  @override
  Future<void> verifyReachable() async {}
}

final class _MemoryExclusiveReportObject implements ExclusiveReportObject {
  _MemoryExclusiveReportObject(this._initialIdentity);

  final ReportObjectIdentity _initialIdentity;
  final List<int> _bytes = [];
  var _offset = 0;
  var flushCount = 0;

  @override
  Future<void> close() async {}

  @override
  Future<void> flush() async {
    flushCount++;
  }

  @override
  Future<ReportObjectIdentity> identity() async => ReportObjectIdentity(
    storageId: _initialIdentity.storageId,
    objectId: _initialIdentity.objectId,
    byteLength: _bytes.length,
  );

  @override
  Future<List<int>> read(int maximumBytes) async {
    final end = (_offset + maximumBytes).clamp(0, _bytes.length);
    final result = _bytes.sublist(_offset, end);
    _offset = end;
    return result;
  }

  @override
  Future<void> rewind() async {
    _offset = 0;
  }

  @override
  Future<void> write(List<int> bytes) async {
    _bytes.addAll(bytes);
    _offset = _bytes.length;
  }
}
