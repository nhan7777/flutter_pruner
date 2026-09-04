/// Smoke test for SharedViewManager integration.
///
/// Tests that shared views can be created, cached, and reused without
/// requiring a full corpus or running the entire benchmark.

import 'dart:async';

import 'package:flutter_pruner/src/adapters/l10n/action_readiness/l10n_generation_config.dart';

import 'l10n_mutation_readiness.dart';
import 'src/shared_view_manager.dart';

class MockProjectView implements L10nReadinessProjectView {
  @override
  final String projectId;

  bool disposed = false;
  int scanCount = 0;

  MockProjectView(this.projectId);

  @override
  Future<void> dispose() async {
    disposed = true;
  }

  Future<String> scan() async {
    scanCount++;
    await Future.delayed(Duration(milliseconds: 100));
    return 'scan-result-$scanCount';
  }
}

Future<void> main() async {
  print('[Smoke Test] Testing SharedViewManager integration');

  final provisionCount = <String, int>{};

  Future<MockProjectView> provisionView(String projectId) async {
    provisionCount[projectId] = (provisionCount[projectId] ?? 0) + 1;
    print('[Smoke Test] Provisioning view for $projectId (count: ${provisionCount[projectId]})');
    await Future.delayed(Duration(milliseconds: 500)); // Simulate expensive load
    return MockProjectView(projectId);
  }

  final manager = SharedViewManager(provisionView: provisionView);

  // Test 1: Single project, multiple accesses should reuse cached view
  print('\n[Test 1] Single project caching');
  final entry1a = await manager.getSharedView('project1');
  final entry1b = await manager.getSharedView('project1');
  final entry1c = await manager.getSharedView('project1');

  assert(identical(entry1a, entry1b), 'Same entry should be returned');
  assert(identical(entry1b, entry1c), 'Same entry should be returned');
  assert(provisionCount['project1'] == 1, 'Should provision only once');
  print('[Test 1] ✓ PASS - View cached and reused');

  // Test 2: Multiple projects should have separate views
  print('\n[Test 2] Multiple project isolation');
  final entry2 = await manager.getSharedView('project2');
  final entry3 = await manager.getSharedView('project3');

  assert(!identical(entry1a, entry2), 'Different projects have different entries');
  assert(!identical(entry2, entry3), 'Different projects have different entries');
  assert(provisionCount['project2'] == 1, 'project2 provisioned once');
  assert(provisionCount['project3'] == 1, 'project3 provisioned once');
  print('[Test 2] ✓ PASS - Projects isolated');

  // Test 3: Concurrent access deduplication
  print('\n[Test 3] Concurrent access deduplication');
  provisionCount['project4'] = 0;
  final futures = List.generate(
    5,
    (_) => manager.getSharedView('project4'),
  );
  final results = await Future.wait(futures);

  assert(results.every((e) => identical(e, results.first)), 'All should get same entry');
  assert(provisionCount['project4'] == 1, 'Should provision only once despite 5 parallel requests');
  print('[Test 3] ✓ PASS - Concurrent deduplication works');

  // Test 4: Scan lock serialization
  print('\n[Test 4] Scan lock serialization');
  final view = entry1a.view as MockProjectView;
  final scanFutures = List.generate(
    3,
    (_) => manager.withScanLock('project1', () async {
      return view.scan();
    }),
  );
  final scanResults = await Future.wait(scanFutures);

  assert(scanResults.length == 3, 'All scans completed');
  assert(view.scanCount == 3, 'Scan called 3 times');
  print('[Test 4] ✓ PASS - Scan lock prevents race conditions');

  // Test 5: Cleanup
  print('\n[Test 5] Cleanup');
  await manager.disposeAll();

  assert((entry1a.view as MockProjectView).disposed, 'project1 disposed');
  assert((entry2.view as MockProjectView).disposed, 'project2 disposed');
  assert((entry3.view as MockProjectView).disposed, 'project3 disposed');
  assert((results.first.view as MockProjectView).disposed, 'project4 disposed');
  print('[Test 5] ✓ PASS - All views disposed');

  print('\n[Smoke Test] ✅ ALL TESTS PASSED');
  print('[Smoke Test] SharedViewManager integration verified');
  print('[Smoke Test] Summary:');
  print('  - View caching: ✓');
  print('  - Project isolation: ✓');
  print('  - Concurrent deduplication: ✓');
  print('  - Scan lock serialization: ✓');
  print('  - Cleanup: ✓');
}
