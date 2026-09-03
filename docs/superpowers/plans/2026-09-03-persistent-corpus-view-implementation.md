# Implementation Plan: Persistent Corpus View Cache

**Mục tiêu:** Giảm benchmark runtime từ 180+ giờ xuống ~2 giờ bằng cách reuse corpus view và ProjectContext cho multiple cases của cùng project.

**Ngày tạo:** 2026-09-03  
**Độ ưu tiên:** HIGH  
**Estimated effort:** 2-4 tuần  

---

## 1. Architecture Overview

### Current flow (slow):
```
For each of 367 cases:
  1. provisionView(projectId) 
     → create new corpus view (~30s)
     → ProjectContext.load() (~25-30 min)
     → DartAnalysisWorkspace() (~5 min)
  2. scan(view, [single case]) (~1-2 min)
  3. dispose view
  
Total: ~30+ min × 367 = 180+ hours
```

### New flow (fast):
```
For each unique project (3 projects):
  1. getOrCreateSharedView(projectId)
     → create corpus view once (~30s)
     → ProjectContext.load() once (~25-30 min)
     → DartAnalysisWorkspace() once (~5 min)
     → cache for reuse

For each case in that project:
  2. getSharedView(projectId) → return cached view
  3. scan(cachedView, [single case]) (~1-2 min)
  
Cleanup:
  4. disposeAllSharedViews() after all cases done

Total: ~30 min × 3 projects + ~2 min × 367 scans = ~120 minutes
```

---

## 2. Technical Design

### 2.1. Core Components

**New class: `SharedViewManager`**

Manages lifecycle của persistent corpus views:

```dart
// File: benchmark/accuracy/src/shared_view_manager.dart

import 'dart:async';
import 'package:synchronized/synchronized.dart';

/// Manages persistent corpus views shared across multiple cases.
final class SharedViewManager {
  SharedViewManager({
    required this.viewFactory,
  });
  
  final ProductionL10nReadinessProjectViewFactory viewFactory;
  
  // Cached views: projectId → view
  final Map<String, _SharedView> _views = {};
  
  // In-flight creation futures to deduplicate concurrent requests
  final Map<String, Future<_SharedView>> _creationFutures = {};
  
  // Per-project locks for thread-safe scanning
  final Map<String, Lock> _scanLocks = {};
  
  /// Gets or creates a shared view for the project.
  Future<ProductionL10nReadinessProjectView> getSharedView(
    String projectId,
  ) async {
    // Check if already cached
    final cached = _views[projectId];
    if (cached != null) {
      cached.touch(); // Update last-used timestamp
      print('[SHARED VIEW] Reusing cached view for $projectId');
      return cached.view;
    }
    
    // Check if creation is in-flight
    final inFlight = _creationFutures[projectId];
    if (inFlight != null) {
      print('[SHARED VIEW] Waiting for in-flight creation of $projectId');
      final shared = await inFlight;
      return shared.view;
    }
    
    // Create new view
    print('[SHARED VIEW] Creating new view for $projectId');
    final future = _createSharedView(projectId);
    _creationFutures[projectId] = future;
    
    try {
      final shared = await future;
      _views[projectId] = shared;
      _scanLocks[projectId] = Lock();
      return shared.view;
    } finally {
      _creationFutures.remove(projectId);
    }
  }
  
  /// Wraps scan with per-project lock for thread safety.
  Future<T> withScanLock<T>(
    String projectId,
    Future<T> Function() callback,
  ) async {
    final lock = _scanLocks[projectId];
    if (lock == null) {
      throw StateError('No scan lock for project $projectId');
    }
    return await lock.synchronized(callback);
  }
  
  /// Disposes all shared views.
  Future<void> disposeAll() async {
    print('[SHARED VIEW] Disposing ${_views.length} shared views');
    final errors = <Object>[];
    
    for (final entry in _views.entries) {
      try {
        await entry.value.dispose();
      } catch (e) {
        errors.add(e);
        print('[SHARED VIEW] Error disposing ${entry.key}: $e');
      }
    }
    
    _views.clear();
    _scanLocks.clear();
    _creationFutures.clear();
    
    if (errors.isNotEmpty) {
      throw StateError(
        'Failed to dispose ${errors.length} shared views: $errors',
      );
    }
  }
  
  Future<_SharedView> _createSharedView(String projectId) async {
    final view = await viewFactory.provision(projectId);
    return _SharedView(
      view: view,
      projectId: projectId,
      createdAt: DateTime.now(),
      lastUsedAt: DateTime.now(),
    );
  }
}

/// Internal wrapper for shared view with metadata.
final class _SharedView {
  _SharedView({
    required this.view,
    required this.projectId,
    required this.createdAt,
    required this.lastUsedAt,
  });
  
  final ProductionL10nReadinessProjectView view;
  final String projectId;
  final DateTime createdAt;
  DateTime lastUsedAt;
  
  void touch() {
    lastUsedAt = DateTime.now();
  }
  
  Future<void> dispose() async {
    await view.dispose();
  }
}
```

**Dependencies:**
```yaml
# pubspec.yaml
dependencies:
  synchronized: ^3.1.0  # For Lock()
```

### 2.2. Interface Changes

**Extend `L10nMutationReadinessDependencies`:**

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart

final class L10nMutationReadinessDependencies {
  const L10nMutationReadinessDependencies({
    required this.loadPlan,
    required this.provisionView,
    required this.scanner,
    required this.evaluatorFactory,
    required this.corpusEvidenceRunner,
    required this.negativeFixtureRunner,
    required this.checkpointStore,
    required this.monotonicMicros,
    this.onStaticGate,
    this.enableProjectEligibilityPreflight = false,
    // NEW: Optional shared view manager
    this.sharedViewManager,
  });

  final L10nReadinessPlanLoader loadPlan;
  final L10nReadinessViewProvisioner provisionView;
  final L10nHarnessScanner scanner;
  final L10nEvidenceEvaluatorFactory evaluatorFactory;
  final L10nCorpusEvidenceRunner corpusEvidenceRunner;
  final L10nMutationNegativeFixtureRunner negativeFixtureRunner;
  final L10nReadinessCheckpointStore checkpointStore;
  final MonotonicMicros monotonicMicros;
  final void Function(String projectId)? onStaticGate;
  final bool enableProjectEligibilityPreflight;
  
  // NEW: Optional manager for persistent views
  final SharedViewManager? sharedViewManager;
  
  /// Helper to get view using shared manager if available.
  Future<L10nReadinessProjectView> getView(String projectId) async {
    final manager = sharedViewManager;
    if (manager != null) {
      return await manager.getSharedView(projectId);
    }
    return await provisionView(projectId);
  }
  
  /// Helper to dispose view only if not shared.
  Future<void> disposeView(L10nReadinessProjectView view) async {
    if (sharedViewManager == null) {
      await view.dispose();
    }
    // If shared, don't dispose - manager handles it
  }
}
```

### 2.3. Update benchmark orchestration

**Modify individual case loop:**

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart:1330-1357

// BEFORE:
for (final caseId in [...plan.individualCaseIds]..sort()) {
  if (artifact.cases.containsKey(caseId)) continue;
  final oracleCase = artifact.oracleById[caseId]!;
  // ... eligibility checks ...
  final attempt = await _runIndividualAttempt(
    plan: plan,
    oracleCase: oracleCase,
    dependencies: dependencies,
  );
  artifact.recordProject(attempt.project);
  artifact.cases[caseId] = attempt.record;
  await _writeCheckpoint(lease, artifact);
}

// AFTER:
for (final caseId in [...plan.individualCaseIds]..sort()) {
  if (artifact.cases.containsKey(caseId)) continue;
  final oracleCase = artifact.oracleById[caseId]!;
  // ... eligibility checks ...
  
  // Use helper method that respects shared view manager
  final attempt = await _runIndividualAttemptWithSharedView(
    plan: plan,
    oracleCase: oracleCase,
    dependencies: dependencies,
  );
  artifact.recordProject(attempt.project);
  artifact.cases[caseId] = attempt.record;
  await _writeCheckpoint(lease, artifact);
}
```

**New helper method:**

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart

Future<_AttemptRecord> _runIndividualAttemptWithSharedView({
  required L10nReadinessPlan plan,
  required L10nReadinessOracleCase oracleCase,
  required L10nMutationReadinessDependencies dependencies,
}) async {
  final start = dependencies.monotonicMicros.now();
  L10nReadinessProjectView? view;
  _StaticProjectRecord? project;
  L10nEvidenceResult? evidence;
  String? actualNodeId;
  var failureReason = 'staticOracleMismatch';
  Object? attemptError;
  StackTrace? attemptStackTrace;
  
  try {
    // Use helper to get view (shared or new)
    view = await dependencies.getView(oracleCase.projectId);
    
    if (view.projectId != oracleCase.projectId) {
      throw const FormatException('provisioned project identity drift');
    }
    
    final projectCases = _projectCases(plan, oracleCase.projectId);
    
    // Wrap scan with lock if using shared views
    final scan = await _scanWithOptionalLock(
      dependencies,
      view,
      projectCases,
      oracleCase.projectId,
    );
    
    dependencies.onStaticGate?.call(oracleCase.projectId);
    project = _evaluateStaticGate(oracleCase.projectId, projectCases, scan);
    
    if (!project.passed) {
      failureReason = 'staticOracleMismatch';
    } else {
      actualNodeId = scan.actualNodeIdByOracleCaseId[oracleCase.caseId];
      final evaluator = dependencies.evaluatorFactory();
      final internal = await evaluator.evaluateIndividual(
        view,
        oracleCase,
        scan,
      );
      if (internal.selectionIdentity != oracleCase.caseId) {
        throw const FormatException('internal evidence selection drift');
      }
      final corpus = internal.accepted
          ? await dependencies.corpusEvidenceRunner.run(
              view,
              oracleCase.caseId,
              internal,
            )
          : null;
      evidence = L10nEvidenceResult.fromInternal(
        oracleCase.caseId,
        internal,
        corpus,
      );
      failureReason = !internal.accepted
          ? 'internalVerdictRejected'
          : evidence.passed
          ? ''
          : 'corpusEvidenceRejected';
    }
  } catch (error, stackTrace) {
    attemptError = error;
    attemptStackTrace = stackTrace;
  }
  
  // Dispose only if not shared
  if (view != null) {
    try {
      await dependencies.disposeView(view);
    } catch (error, stackTrace) {
      attemptError ??= error;
      attemptStackTrace ??= stackTrace;
    }
  }
  
  if (attemptError != null) {
    Error.throwWithStackTrace(attemptError, attemptStackTrace!);
  }
  
  if (project == null) {
    throw StateError('individual attempt produced no static project record');
  }
  
  final passed = project.passed && evidence?.passed == true;
  final record = <String, Object?>{
    'actualNodeId': actualNodeId,
    'attemptMicros': _elapsed(start, dependencies.monotonicMicros.now()),
    'caseId': oracleCase.caseId,
    'evidence': evidence?.toJson(),
    'failureReason': passed ? null : failureReason,
    'projectId': oracleCase.projectId,
    'status': passed ? 'passed' : 'failed',
  };
  _validateProjectRecord(project.json, plan);
  _validateCaseRecord(record, {oracleCase.caseId: oracleCase});
  return _AttemptRecord(project: project, record: record);
}

Future<L10nHarnessScanResult> _scanWithOptionalLock(
  L10nMutationReadinessDependencies dependencies,
  L10nReadinessProjectView view,
  List<L10nReadinessOracleCase> projectCases,
  String projectId,
) async {
  final manager = dependencies.sharedViewManager;
  if (manager != null) {
    // Thread-safe scan with lock
    return await manager.withScanLock(
      projectId,
      () => dependencies.scanner.scan(view, projectCases),
    );
  }
  // No lock needed for non-shared views
  return await dependencies.scanner.scan(view, projectCases);
}
```

### 2.4. Cleanup phase

**Add cleanup at end of benchmark:**

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart:1386-1400

Future<int> runL10nMutationReadiness(
  List<String> arguments, {
  required L10nMutationReadinessDependencies dependencies,
}) async {
  // ... existing setup ...
  
  L10nReadinessCheckpointLease? lease;
  var result = 2;
  try {
    // ... existing benchmark logic ...
    
    await _writeCheckpoint(lease, artifact, finalArtifact: true);
    result = artifact.status == 'passed' ? 0 : 1;
  } catch (error, stackTrace) {
    _debugReadinessError(error, stackTrace);
    result = 2;
  }
  
  // NEW: Dispose shared views
  final manager = dependencies.sharedViewManager;
  if (manager != null) {
    try {
      await manager.disposeAll();
    } catch (error, stackTrace) {
      _debugReadinessError(error, stackTrace);
      result = 2;
    }
  }
  
  if (lease != null) {
    try {
      await lease.release();
    } catch (_) {
      result = 2;
    }
  }
  return result;
}
```

### 2.5. Production composition changes

**Update composition to create shared view manager:**

```dart
// File: benchmark/accuracy/src/l10n_readiness_production.dart:893-946

final class ProductionL10nReadinessComposition {
  ProductionL10nReadinessComposition._({
    required this.dependencies,
    required this.authorities,
    this.sharedViewManager,  // NEW
  });

  final SharedViewManager? sharedViewManager;  // NEW
  
  static Future<ProductionL10nReadinessComposition> create(
    L10nMutationReadinessOptions options, {
    ProductionL10nAuthorityLoaderBase? authorityLoader,
    bool enableSharedViews = false,  // NEW parameter
  }) async {
    final loader = authorityLoader ?? ProductionL10nAuthorityLoader();
    final authorities = await loader.load(options);
    
    // ... existing validation ...
    
    final viewFactory = ProductionL10nReadinessProjectViewFactory(
      manifest: authorities.manifest,
      retainedRepositoriesByProject: authorities.retainedRepositoriesByProject,
      sdkFlutterByVersion: options.sdkFlutterByVersion,
    );
    
    // NEW: Create shared view manager if enabled
    final SharedViewManager? sharedViewManager = enableSharedViews
        ? SharedViewManager(viewFactory: viewFactory)
        : null;
    
    final dependencies = L10nMutationReadinessDependencies(
      loadPlan: (runtimeOptions) async {
        if (_optionsIdentity(runtimeOptions) != optionsIdentity) {
          throw StateError('Production readiness argv authority drifted.');
        }
        return buildProductionL10nReadinessPlanFromManifest(
          runtimeOptions,
          identities: authorities.identities,
          retainedRepositoriesByProject:
              authorities.retainedRepositoriesByProject,
        );
      },
      provisionView: (projectId) async {
        await loader.revalidateProject(options, authorities, projectId);
        return viewFactory.provision(projectId);
      },
      scanner: ProductionL10nHarnessScanner(),
      evaluatorFactory: ProductionL10nEvidenceEvaluator.new,
      corpusEvidenceRunner: ProductionL10nCorpusEvidenceRunner(),
      negativeFixtureRunner: ProductionL10nMutationNegativeFixtureRunner(
        repositoryRoot: options.repositoryRoot,
        expectedMatrixAuthorityIdentity:
            authorities.identities['negativeRecipeMatrixSha256']! as String,
      ),
      checkpointStore: FileL10nReadinessCheckpointStore(),
      monotonicMicros: const _ProductionMonotonicMicros(),
      enableProjectEligibilityPreflight: true,
      sharedViewManager: sharedViewManager,  // NEW
    );
    
    return ProductionL10nReadinessComposition._(
      dependencies: dependencies,
      authorities: authorities,
      sharedViewManager: sharedViewManager,  // NEW
    );
  }
}
```

**Update entry point:**

```dart
// File: benchmark/accuracy/src/l10n_readiness_production.dart:954-976

Future<int> runProductionL10nMutationReadiness(
  List<String> arguments, {
  ProductionL10nAuthorityLoaderBase? authorityLoader,
  bool enableSharedViews = false,  // NEW parameter
}) async {
  try {
    final options = L10nMutationReadinessOptions.parse(arguments);
    final composition = await ProductionL10nReadinessComposition.create(
      options,
      authorityLoader: authorityLoader,
      enableSharedViews: enableSharedViews,  // NEW
    );
    return await runL10nMutationReadiness(
      List.unmodifiable(arguments),
      dependencies: composition.dependencies,
    );
  } catch (error, stackTrace) {
    if (Platform.environment['FLUTTER_PRUNER_STAGE1_DEBUG'] == '1') {
      stderr
        ..writeln(error)
        ..writeln(stackTrace);
    }
    return 2;
  }
}
```

---

## 3. Implementation Phases

### Phase 1: Core infrastructure (Week 1)

**Tasks:**
- [ ] Create `shared_view_manager.dart` with `SharedViewManager` class
- [ ] Add `synchronized` dependency to `pubspec.yaml`
- [ ] Add `sharedViewManager` field to `L10nMutationReadinessDependencies`
- [ ] Add `getView()` and `disposeView()` helper methods
- [ ] Unit tests for `SharedViewManager`:
  - Test view creation and caching
  - Test concurrent access deduplication
  - Test lock mechanism
  - Test disposal

**Acceptance criteria:**
- [ ] Unit tests pass
- [ ] No compilation errors
- [ ] Code review approved

---

### Phase 2: Benchmark integration (Week 2)

**Tasks:**
- [ ] Create `_runIndividualAttemptWithSharedView()` method
- [ ] Create `_scanWithOptionalLock()` helper
- [ ] Update individual case loop to use new method
- [ ] Add cleanup in `runL10nMutationReadiness()`
- [ ] Update `ProductionL10nReadinessComposition.create()` with `enableSharedViews` parameter
- [ ] Update `runProductionL10nMutationReadiness()` with `enableSharedViews` parameter

**Acceptance criteria:**
- [ ] Benchmark compiles successfully
- [ ] Can run with `enableSharedViews: false` (backward compatible)
- [ ] No regressions in existing tests

---

### Phase 3: Test harness updates (Week 2)

**Tasks:**
- [ ] Update `test_l10n_mutation_readiness_v3.dart` to enable shared views
- [ ] Create `test_l10n_mutation_readiness_v3_shared.dart` variant
- [ ] Add performance logging to measure cache hit rate
- [ ] Add memory profiling instrumentation

**Test script:**
```dart
// File: benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart

#!/usr/bin/env dart

import 'dart:io';
import 'package:flutter_pruner/src/core/process/managed_process_runner.dart';
import 'l10n_mutation_readiness.dart';
import 'src/l10n_readiness_production.dart';

class TestAuthorityLoader implements ProductionL10nAuthorityLoaderBase {
  final ProductionL10nAuthorityLoader _delegate;

  TestAuthorityLoader()
      : _delegate = ProductionL10nAuthorityLoader.testing(
          processRunner: const ManagedProcessRunner(),
          gitExecutable: Platform.isWindows ? 'git.exe' : '/usr/bin/git',
          enforceRetainedProbeHash: false,
          enforceManifestHash: false,
        );

  @override
  Future<ProductionL10nAuthoritySnapshot> load(
    L10nMutationReadinessOptions options,
  ) async {
    print('[DEBUG] TestAuthorityLoader.load() called');
    final result = await _delegate.load(options);
    print('[DEBUG] TestAuthorityLoader.load() completed');
    return result;
  }

  @override
  Future<void> revalidateProject(
    L10nMutationReadinessOptions options,
    ProductionL10nAuthoritySnapshot snapshot,
    String projectId,
  ) async {
    print('[DEBUG] TestAuthorityLoader.revalidateProject($projectId) called');
    await _delegate.revalidateProject(options, snapshot, projectId);
    print('[DEBUG] TestAuthorityLoader.revalidateProject($projectId) completed');
  }
}

Future<void> main(List<String> arguments) async {
  print('[DEBUG] V3 test harness with SHARED VIEWS starting');
  print('[DEBUG] Args: $arguments');
  
  final stopwatch = Stopwatch()..start();
  
  final exitCode = await runProductionL10nMutationReadiness(
    arguments,
    authorityLoader: TestAuthorityLoader(),
    enableSharedViews: true,  // ENABLE SHARED VIEWS
  );
  
  stopwatch.stop();
  
  print('[DEBUG] Completed with exit code: $exitCode');
  print('[DEBUG] Total elapsed time: ${stopwatch.elapsed}');
  print('[DEBUG] Total elapsed minutes: ${stopwatch.elapsed.inMinutes}');
  
  exit(exitCode);
}
```

**Acceptance criteria:**
- [ ] Script runs without errors
- [ ] Logs show cache hits for subsequent cases
- [ ] Performance improvement visible

---

### Phase 4: Validation & performance testing (Week 3)

**Tasks:**
- [ ] Run baseline benchmark without shared views (save results)
- [ ] Run benchmark with shared views (save results)
- [ ] Compare results byte-by-byte for correctness
- [ ] Measure performance improvement
- [ ] Profile memory usage
- [ ] Identify any regressions

**Validation script:**
```bash
#!/bin/bash
# File: benchmark/accuracy/validate_shared_views.sh

echo "Running baseline (no shared views)..."
dart benchmark/accuracy/test_l10n_mutation_readiness_v3.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2-gsy-patched.json \
  --corpus-root /private/tmp/corpus \
  --output /tmp/baseline-results.json \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --sdk 3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter

echo "Running with shared views..."
dart benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2-gsy-patched.json \
  --corpus-root /private/tmp/corpus \
  --output /tmp/shared-results.json \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --sdk 3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter

echo "Comparing results..."
diff <(jq --sort-keys . /tmp/baseline-results.json) \
     <(jq --sort-keys . /tmp/shared-results.json)

if [ $? -eq 0 ]; then
  echo "✅ Results match exactly!"
else
  echo "❌ Results differ!"
  exit 1
fi
```

**Acceptance criteria:**
- [ ] Results match 100% (bit-for-bit identical)
- [ ] Runtime reduced by >90% (from 180h to <3h)
- [ ] Memory usage <4GB
- [ ] No crashes or hangs

---

### Phase 5: Refinement & production rollout (Week 4)

**Tasks:**
- [ ] Address any issues from validation
- [ ] Add configuration flag to enable/disable shared views
- [ ] Update documentation
- [ ] Merge to main branch
- [ ] Enable in CI
- [ ] Monitor production runs

**Documentation updates:**
- [ ] Update `doc/flutter_pruner.yaml.md` with shared views option
- [ ] Add section to `docs/superpowers/specs/2026-08-22-safe-l10n-removal-v3-1-design.md`
- [ ] Create runbook for troubleshooting shared views

**Acceptance criteria:**
- [ ] PR merged
- [ ] CI green
- [ ] Documentation updated
- [ ] No production incidents

---

## 4. Testing Strategy

### 4.1. Unit tests

**File: `test/benchmark/shared_view_manager_test.dart`**

```dart
import 'package:flutter_pruner/benchmark/accuracy/src/shared_view_manager.dart';
import 'package:test/test.dart';

void main() {
  group('SharedViewManager', () {
    late MockViewFactory factory;
    late SharedViewManager manager;
    
    setUp(() {
      factory = MockViewFactory();
      manager = SharedViewManager(viewFactory: factory);
    });
    
    tearDown(() async {
      await manager.disposeAll();
    });
    
    test('creates view on first access', () async {
      final view = await manager.getSharedView('project1');
      expect(view, isNotNull);
      expect(factory.createCount, equals(1));
    });
    
    test('reuses view on subsequent access', () async {
      final view1 = await manager.getSharedView('project1');
      final view2 = await manager.getSharedView('project1');
      
      expect(identical(view1, view2), isTrue);
      expect(factory.createCount, equals(1));
    });
    
    test('creates separate views for different projects', () async {
      final view1 = await manager.getSharedView('project1');
      final view2 = await manager.getSharedView('project2');
      
      expect(identical(view1, view2), isFalse);
      expect(factory.createCount, equals(2));
    });
    
    test('deduplicates concurrent creation requests', () async {
      final futures = List.generate(
        10,
        (_) => manager.getSharedView('project1'),
      );
      
      final views = await Future.wait(futures);
      
      expect(views.every((v) => identical(v, views.first)), isTrue);
      expect(factory.createCount, equals(1));
    });
    
    test('withScanLock serializes concurrent scans', () async {
      final view = await manager.getSharedView('project1');
      final results = <int>[];
      
      Future<void> scan(int id) async {
        await manager.withScanLock('project1', () async {
          results.add(id);
          await Future.delayed(Duration(milliseconds: 10));
        });
      }
      
      await Future.wait([
        scan(1),
        scan(2),
        scan(3),
      ]);
      
      expect(results.length, equals(3));
      expect(results.toSet().length, equals(3)); // All unique
    });
    
    test('disposeAll cleans up all views', () async {
      await manager.getSharedView('project1');
      await manager.getSharedView('project2');
      await manager.getSharedView('project3');
      
      await manager.disposeAll();
      
      expect(factory.disposeCount, equals(3));
    });
  });
}
```

### 4.2. Integration tests

**File: `test/benchmark/shared_views_integration_test.dart`**

```dart
import 'dart:io';
import 'package:test/test.dart';

void main() {
  group('Shared views integration', () {
    test('benchmark completes with shared views enabled', () async {
      final result = await Process.run(
        'dart',
        [
          'benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart',
          '--manifest',
          'benchmark/accuracy/manifests/test-mini-manifest.json',
          '--corpus-root',
          '/tmp/test-corpus',
          '--output',
          '/tmp/test-output.json',
        ],
      );
      
      expect(result.exitCode, equals(0));
    }, timeout: Timeout(Duration(hours: 2)));
    
    test('results match baseline', () async {
      // Run baseline
      final baseline = await Process.run(
        'dart',
        [
          'benchmark/accuracy/test_l10n_mutation_readiness_v3.dart',
          '--manifest',
          'benchmark/accuracy/manifests/test-mini-manifest.json',
          '--corpus-root',
          '/tmp/test-corpus',
          '--output',
          '/tmp/baseline.json',
        ],
      );
      expect(baseline.exitCode, equals(0));
      
      // Run with shared views
      final shared = await Process.run(
        'dart',
        [
          'benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart',
          '--manifest',
          'benchmark/accuracy/manifests/test-mini-manifest.json',
          '--corpus-root',
          '/tmp/test-corpus',
          '--output',
          '/tmp/shared.json',
        ],
      );
      expect(shared.exitCode, equals(0));
      
      // Compare results
      final baselineJson = await File('/tmp/baseline.json').readAsString();
      final sharedJson = await File('/tmp/shared.json').readAsString();
      
      expect(sharedJson, equals(baselineJson));
    }, timeout: Timeout(Duration(hours: 4)));
  });
}
```

### 4.3. Performance benchmarks

**File: `benchmark/accuracy/measure_shared_views_performance.dart`**

```dart
import 'dart:io';

Future<void> main() async {
  print('Measuring baseline performance...');
  final baselineStopwatch = Stopwatch()..start();
  final baselineResult = await Process.run(
    'dart',
    [
      'benchmark/accuracy/test_l10n_mutation_readiness_v3.dart',
      '--manifest',
      'benchmark/accuracy/manifests/l10n-mutation-readiness-v2-gsy-patched.json',
      '--corpus-root',
      '/private/tmp/corpus',
      '--output',
      '/tmp/baseline-results.json',
      '--sdk',
      '3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter',
      '--sdk',
      '3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter',
      '--sdk',
      '3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter',
    ],
  );
  baselineStopwatch.stop();
  
  print('Measuring shared views performance...');
  final sharedStopwatch = Stopwatch()..start();
  final sharedResult = await Process.run(
    'dart',
    [
      'benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart',
      '--manifest',
      'benchmark/accuracy/manifests/l10n-mutation-readiness-v2-gsy-patched.json',
      '--corpus-root',
      '/private/tmp/corpus',
      '--output',
      '/tmp/shared-results.json',
      '--sdk',
      '3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter',
      '--sdk',
      '3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter',
      '--sdk',
      '3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter',
    ],
  );
  sharedStopwatch.stop();
  
  print('\n=== Performance Comparison ===');
  print('Baseline time: ${baselineStopwatch.elapsed}');
  print('Shared views time: ${sharedStopwatch.elapsed}');
  print('Speedup: ${baselineStopwatch.elapsed.inMilliseconds / sharedStopwatch.elapsed.inMilliseconds}x');
  print('Time saved: ${baselineStopwatch.elapsed - sharedStopwatch.elapsed}');
  
  final speedup = baselineStopwatch.elapsed.inMilliseconds / 
                  sharedStopwatch.elapsed.inMilliseconds;
  if (speedup > 50) {
    print('✅ Performance target achieved (>50x speedup)');
  } else {
    print('⚠️  Performance target not met (<50x speedup)');
  }
}
```

---

## 5. Risk Mitigation

### 5.1. Concurrent access issues

**Risk:** Multiple cases accessing same view simultaneously cause race conditions.

**Mitigation:**
- Use `synchronized` package for per-project locks
- Wrap all scan operations in `withScanLock()`
- Add tests for concurrent access patterns

**Rollback:** Disable shared views via feature flag.

### 5.2. Memory leaks

**Risk:** Views not properly disposed, causing OOM.

**Mitigation:**
- Explicit `disposeAll()` in finally block
- Add memory profiling to tests
- Monitor RSS in production

**Rollback:** Disable shared views via feature flag.

### 5.3. Stale analysis results

**Risk:** Analyzer cache returns stale results after l10n generation.

**Mitigation:**
- Document that l10n generation invalidates cache
- Consider invalidating analyzer paths after generation
- Add tests that verify fresh analysis

**Rollback:** Disable shared views via feature flag.

### 5.4. Corpus view mutation

**Risk:** One case mutates corpus view, affecting others.

**Mitigation:**
- Document corpus view immutability contract
- Add assertions to detect unexpected mutations
- Consider copy-on-write for mutable operations

**Rollback:** Disable shared views via feature flag.

---

## 6. Success Metrics

**Performance:**
- [ ] Benchmark runtime <3 hours (from 180+ hours) = **>60x speedup**
- [ ] First case per project: ~30 minutes
- [ ] Subsequent cases: <5 minutes each
- [ ] Memory usage: <4GB peak RSS

**Correctness:**
- [ ] 100% result parity with baseline (bit-for-bit)
- [ ] All 367 individual cases produce identical evidence
- [ ] No analyzer resolution errors

**Reliability:**
- [ ] No crashes or hangs
- [ ] Deterministic across multiple runs
- [ ] Works on macOS, Linux, Windows CI

---

## 7. Rollout Checklist

**Pre-launch:**
- [ ] All unit tests passing
- [ ] Integration tests passing
- [ ] Performance benchmarks meet targets
- [ ] Code review approved
- [ ] Documentation updated

**Launch:**
- [ ] Feature flag created (default: disabled)
- [ ] Gradual rollout: 10% → 50% → 100%
- [ ] Monitor error rates and performance
- [ ] Collect feedback from team

**Post-launch:**
- [ ] Analyze production metrics
- [ ] Address any issues
- [ ] Update best practices
- [ ] Consider enabling by default

---

## 8. Timeline

| Week | Phase | Deliverables |
|------|-------|--------------|
| 1 | Core infrastructure | `SharedViewManager` class, unit tests |
| 2 | Benchmark integration | Updated orchestration, test harness |
| 3 | Validation | Correctness verification, performance testing |
| 4 | Production rollout | Feature flag, CI integration, documentation |

**Total estimated time:** 4 weeks

**Dependencies:**
- `synchronized` package
- Access to corpus repositories
- CI environment for testing

**Blockers:**
- None identified

---

## 9. Alternative Approaches Considered

### 9.1. Workspace-level cache only
**Rejected:** Too complex, high risk of stale references.

### 9.2. Disk cache
**Deferred:** Phase 3 optional enhancement, not on critical path.

### 9.3. Family batch only
**Complementary:** Can combine with shared views for even better performance.

---

## 10. Open Questions

1. **Q:** Should we cache across benchmark runs (persistent disk cache)?  
   **A:** Defer to Phase 3, not needed for initial 60x speedup.

2. **Q:** What if analyzer internal state is not thread-safe?  
   **A:** Locks protect against concurrent access. If still issues, fall back to single-threaded.

3. **Q:** How to handle l10n generation invalidating cache?  
   **A:** Document as known limitation. Consider invalidation in future if needed.

---

**Document version:** 1.0  
**Last updated:** 2026-09-03  
**Owner:** Nhan Lee  
**Reviewers:** TBD
