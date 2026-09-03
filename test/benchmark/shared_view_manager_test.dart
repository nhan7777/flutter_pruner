import 'dart:async';

import 'package:test/test.dart';

import '../../benchmark/accuracy/l10n_mutation_readiness.dart';
import '../../benchmark/accuracy/src/shared_view_manager.dart';

class MockL10nReadinessProjectView implements L10nReadinessProjectView {
  @override
  final String projectId;

  bool disposed = false;

  MockL10nReadinessProjectView({required this.projectId});

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  group('SharedViewManager', () {
    late SharedViewManager manager;
    late Map<String, int> provisionCallCount;
    late Map<String, MockL10nReadinessProjectView> mockViews;

    setUp(() {
      provisionCallCount = {};
      mockViews = {};

      manager = SharedViewManager(
        provisionView: (projectId) async {
          provisionCallCount[projectId] =
              (provisionCallCount[projectId] ?? 0) + 1;

          if (!mockViews.containsKey(projectId)) {
            mockViews[projectId] = MockL10nReadinessProjectView(
              projectId: projectId,
            );
          }

          return mockViews[projectId]!;
        },
      );
    });

    test('getSharedView creates view on first access', () async {
      final entry = await manager.getSharedView('project1');

      expect(entry.view, isNotNull);
      expect(entry.scanLock, isNotNull);
      expect(provisionCallCount['project1'], equals(1));
    });

    test('getSharedView returns cached view on subsequent access', () async {
      final entry1 = await manager.getSharedView('project1');
      final entry2 = await manager.getSharedView('project1');

      expect(identical(entry1, entry2), isTrue);
      expect(provisionCallCount['project1'], equals(1));
    });

    test('getSharedView deduplicates concurrent loads', () async {
      final futures = List.generate(
        10,
        (_) => manager.getSharedView('project1'),
      );

      final entries = await Future.wait(futures);

      expect(entries.every((e) => identical(e, entries.first)), isTrue);
      expect(provisionCallCount['project1'], equals(1));
    });

    test('getSharedView handles multiple projects', () async {
      final entry1 = await manager.getSharedView('project1');
      final entry2 = await manager.getSharedView('project2');
      final entry3 = await manager.getSharedView('project1');

      expect(identical(entry1, entry3), isTrue);
      expect(identical(entry1, entry2), isFalse);
      expect(provisionCallCount['project1'], equals(1));
      expect(provisionCallCount['project2'], equals(1));
    });

    test('touch updates lastAccessed timestamp', () async {
      final entry = await manager.getSharedView('project1');
      final initialTimestamp = entry.lastAccessed;

      await Future.delayed(Duration(milliseconds: 10));
      entry.touch();

      expect(entry.lastAccessed.isAfter(initialTimestamp), isTrue);
    });

    test('withScanLock acquires per-project lock', () async {
      final results = <int>[];
      final futures = <Future<void>>[];

      for (var i = 0; i < 5; i++) {
        futures.add(
          manager.withScanLock('project1', () async {
            results.add(i);
            await Future.delayed(Duration(milliseconds: 10));
          }),
        );
      }

      await Future.wait(futures);

      expect(results, equals([0, 1, 2, 3, 4]));
    });

    test('withScanLock allows concurrent access to different projects',
        () async {
      final project1Start = <DateTime>[];
      final project2Start = <DateTime>[];

      await Future.wait([
        manager.withScanLock('project1', () async {
          project1Start.add(DateTime.now());
          await Future.delayed(Duration(milliseconds: 50));
        }),
        manager.withScanLock('project2', () async {
          project2Start.add(DateTime.now());
          await Future.delayed(Duration(milliseconds: 50));
        }),
      ]);

      final timeDiff =
          project1Start.first.difference(project2Start.first).inMilliseconds.abs();
      expect(timeDiff < 30, isTrue,
          reason: 'Projects should start concurrently');
    });

    test('disposeAll cleans up all views', () async {
      await manager.getSharedView('project1');
      await manager.getSharedView('project2');

      expect(manager.cachedProjectCount, equals(2));

      await manager.disposeAll();

      expect(manager.cachedProjectCount, equals(0));
      expect(mockViews['project1']!.disposed, isTrue);
      expect(mockViews['project2']!.disposed, isTrue);
    });

    test('cachedProjectCount returns correct count', () async {
      expect(manager.cachedProjectCount, equals(0));

      await manager.getSharedView('project1');
      expect(manager.cachedProjectCount, equals(1));

      await manager.getSharedView('project2');
      expect(manager.cachedProjectCount, equals(2));

      await manager.getSharedView('project1');
      expect(manager.cachedProjectCount, equals(2));
    });

    test('cachedProjectIds returns all cached project IDs', () async {
      await manager.getSharedView('project1');
      await manager.getSharedView('project2');
      await manager.getSharedView('project3');

      final ids = manager.cachedProjectIds.toSet();
      expect(ids, equals({'project1', 'project2', 'project3'}));
    });
  });
}
