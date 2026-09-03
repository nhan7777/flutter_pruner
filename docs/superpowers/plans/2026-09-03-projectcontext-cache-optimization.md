# Plan: ProjectContext Cache Optimization - Chiến lược dài hạn

**Ngày tạo:** 2026-09-03  
**Tác giả:** Nhan Lee  
**Mục tiêu:** Giảm thời gian benchmark từ 180+ giờ xuống ~1-2 giờ bằng cách cache ProjectContext.load() results

---

## 1. Bối cảnh kỹ thuật

### 1.1. Vấn đề hiện tại

**Chi phí per-case trong benchmark:**
```dart
// Mỗi case trong 367 individual cases:
1. provision() → tạo corpus view mới
2. ProjectContext.load() → parse pubspec, load analyzer contexts (~30+ phút)
3. DartAnalysisWorkspace() → khởi tạo AnalysisContextCollection
4. scanner.scan() → phân tích tĩnh Dart
5. dispose() → cleanup

Total: ~30+ phút/case × 367 cases = 180+ giờ
```

**Nguyên nhân bottleneck:**

Code tại `benchmark/accuracy/src/l10n_readiness_production.dart:191-195`:
```dart
final context = await ProjectContext.load(
  corpusView.packageRoot,
  configFile: _scannerCoverageConfigFile(project, corpusView),
);
```

`ProjectContext.load()` thực hiện:
- Parse `pubspec.yaml`
- Khởi tạo `AnalysisContextCollection` (analyzer cache rỗng)
- Load tất cả Dart files trong project
- Build dependency graph

**Quan sát quan trọng:**
- GitJournal: 420 cases cùng 1 project → load 420 lần giống nhau
- GSY: 404 cases cùng 1 project → load 404 lần giống nhau  
- Smooth: 0 cases trong v2-gsy-patched manifest (có trong v1 manifest với 3 cases)

---

## 2. Phân tích kỹ thuật sâu

### 2.1. ProjectContext architecture

**File: `lib/src/core/project/project_context.dart:21-40`**

```dart
class ProjectContext {
  ProjectContext({
    required this.root,
    required Map<dynamic, dynamic> pubspec,
    required this.packageName,
    this.analysisMode = AnalysisMode.application,
    // ...
  })
  
  static Future<ProjectContext> load(Directory directory, {...}) async {
    final pubspecFile = File(p.join(directory.path, 'pubspec.yaml'));
    // Parse pubspec
    // Load config
    // Initialize workspace
    return ProjectContext(...);
  }
}
```

**Các thành phần immutable (cacheable):**
- `root: Directory` - corpus view path (thay đổi mỗi lần)
- `pubspec: Map` - nội dung pubspec.yaml (giống nhau trong cùng project)
- `packageName: String` - từ pubspec (giống nhau)
- `targetMatrix: TargetMatrix` - build targets (giống nhau)
- `pathPolicy: ProjectPathPolicy` - exclusion rules (giống nhau)

**Các thành phần mutable (không cacheable trực tiếp):**
- `root.path` - đường dẫn corpus view khác nhau mỗi lần

### 2.2. DartAnalysisWorkspace architecture

**File: `lib/src/adapters/dart/dart_analysis_workspace.dart:65-78`**

```dart
final class DartAnalysisWorkspace {
  DartAnalysisWorkspace(ProjectContext project)
    : _project = project,
      _ownership = DartPackageOwnership.discover(project),
      collection = AnalysisContextCollection(
        includedPaths: [p.normalize(p.absolute(project.root.path))],
      );
      
  final AnalysisContextCollection collection;
  final Map<String, Future<SomeResolvedLibraryResult>> _libraryCache = {};
}
```

**Chi phí:**
- `AnalysisContextCollection` constructor: ~20-25 phút
- Scan tất cả Dart files trong project
- Build analyzer internal structures

**Cache behavior:**
- `_libraryCache`: per-workspace, không persist
- Mỗi workspace mới → empty cache → re-resolve tất cả

### 2.3. Corpus view lifecycle

**File: `benchmark/accuracy/src/corpus_mutation_evidence.dart`**

```dart
sealed class CorpusProjectViewOutcome {
  CorpusProjectView view; // Temporary directory
}

abstract class CorpusProjectViewFactory {
  Future<CorpusProjectViewOutcome> create({
    required L10nMutationProjectManifest project,
    required String retainedRepositoryPath,
    required String canonicalFlutterExecutable,
  });
}
```

**Corpus view là temporary directory:**
- Mỗi case tạo view mới tại `/private/var/folders/.../flutter-pruner-corpus-view-*`
- Apply fixture overlays (flutter_pruner_v2_accuracy.yaml, .env.dart)
- Generate l10n files
- Dispose sau khi xong

**Vấn đề:** `project.root.path` khác nhau mỗi lần → không thể cache ProjectContext trực tiếp

---

## 3. Chiến lược cache - 3 approaches

### Approach 1: Workspace-level cache (Recommended)

**Ý tưởng:** Cache `DartAnalysisWorkspace` thay vì `ProjectContext`

**Lý do:**
- `ProjectContext` phụ thuộc vào `root.path` (thay đổi)
- `DartAnalysisWorkspace` phụ thuộc vào nội dung project (giống nhau)
- Analyzer cache nằm trong workspace, không phải context

**Implementation:**

```dart
// File: benchmark/accuracy/src/l10n_readiness_production.dart

final class ProductionL10nReadinessProjectViewFactory {
  // Thêm cache
  final Map<String, _CachedWorkspace> _workspaceCache = {};
  
  Future<ProductionL10nReadinessProjectView> provision(String projectId) async {
    final project = manifest.projectsById[projectId];
    final retained = retainedRepositoriesByProject[projectId];
    final flutter = sdkFlutterByVersion[project.toolchainVersion];
    
    final corpusView = await _viewFactory.create(...);
    
    // Cache key: projectId + repositorySha + configFile hash
    final cacheKey = _buildCacheKey(projectId, project, corpusView);
    
    final cached = _workspaceCache[cacheKey];
    if (cached != null && _isValid(cached, corpusView)) {
      print('[CACHE HIT] Reusing workspace for $projectId');
      return ProductionL10nReadinessProjectView(
        projectId: projectId,
        manifest: project,
        corpusView: corpusView,
        project: cached.context,
        workspace: cached.workspace, // Reuse!
        canonicalFlutterExecutable: flutter.path,
      );
    }
    
    print('[CACHE MISS] Creating new workspace for $projectId');
    final context = await ProjectContext.load(
      corpusView.packageRoot,
      configFile: _scannerCoverageConfigFile(project, corpusView),
    );
    final workspace = DartAnalysisWorkspace(context);
    
    _workspaceCache[cacheKey] = _CachedWorkspace(
      context: context,
      workspace: workspace,
      createdAt: DateTime.now(),
    );
    
    return ProductionL10nReadinessProjectView(...);
  }
}

final class _CachedWorkspace {
  final ProjectContext context;
  final DartAnalysisWorkspace workspace;
  final DateTime createdAt;
}
```

**Vấn đề kỹ thuật:**

1. **ProjectContext.root.path mismatch:**
   - Context được load từ corpus view cũ
   - Scan mới dùng corpus view mới (path khác)
   - → Analyzer có thể fail khi resolve relative paths

2. **Corpus view disposal:**
   - Corpus view cũ đã bị dispose
   - Workspace vẫn reference files trong corpus view đó
   - → File not found errors

3. **Fixture overlay differences:**
   - Mỗi corpus view apply overlays mới
   - Generated l10n files có thể khác nhau
   - → Stale cache issue

**Giải pháp:**

```dart
bool _isValid(_CachedWorkspace cached, CorpusProjectView newView) {
  // Check nếu corpus view path cũ còn tồn tại
  if (!Directory(cached.context.root.path).existsSync()) {
    return false;
  }
  
  // Check fixture overlay hashes match
  final oldOverlayHash = _hashOverlays(cached.context.root);
  final newOverlayHash = _hashOverlays(newView.packageRoot);
  if (oldOverlayHash != newOverlayHash) {
    return false;
  }
  
  return true;
}
```

**Rủi ro:**
- **Medium:** Race conditions nếu 2 cases cùng project chạy parallel
- **Low:** Memory leak nếu không clear cache
- **High:** Stale analysis results nếu corpus view đã thay đổi

**Estimated improvement:**
- First case per project: 30+ phút
- Subsequent cases: ~2-5 phút (chỉ scan, không load)
- Total: ~90 phút cho 3 projects + 367 scans

---

### Approach 2: Persistent corpus view (More reliable)

**Ý tưởng:** Giữ 1 corpus view cho mỗi project, không dispose giữa các cases

**Implementation:**

```dart
final class ProductionL10nReadinessComposition {
  // Persistent corpus views
  final Map<String, _PersistentProjectView> _persistentViews = {};
  
  Future<_PersistentProjectView> _getOrCreateView(String projectId) async {
    if (_persistentViews.containsKey(projectId)) {
      print('[REUSE] Persistent view for $projectId');
      return _persistentViews[projectId]!;
    }
    
    print('[CREATE] New persistent view for $projectId');
    final view = await _viewFactory.create(...);
    final context = await ProjectContext.load(view.corpusView.packageRoot, ...);
    final workspace = DartAnalysisWorkspace(context);
    
    final persistent = _PersistentProjectView(
      corpusView: view,
      context: context,
      workspace: workspace,
    );
    _persistentViews[projectId] = persistent;
    return persistent;
  }
  
  Future<void> dispose() async {
    for (final view in _persistentViews.values) {
      await view.dispose();
    }
    _persistentViews.clear();
  }
}
```

**Thay đổi trong benchmark flow:**

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart

// Thay vì:
for (final caseId in plan.individualCaseIds) {
  final view = await dependencies.provisionView(projectId); // Mỗi lần mới
  final scan = await scanner.scan(view, [case]);
  await view.dispose(); // Dispose ngay
}

// Thành:
for (final caseId in plan.individualCaseIds) {
  final view = await dependencies.getSharedView(projectId); // Reuse
  final scan = await scanner.scan(view, [case]);
  // Không dispose, giữ lại
}
```

**Rủi ro:**
- **Low:** Đơn giản hơn approach 1
- **Medium:** Cần refactor interface `provisionView()` → `getSharedView()`
- **Low:** Memory usage cao hơn (3 corpus views cùng lúc)

**Estimated improvement:**
- GitJournal: 1 load (~30 phút) + 420 scans (~5 phút/scan) = ~60 phút
- GSY: 1 load (~30 phút) + 404 scans (~5 phút/scan) = ~60 phút
- Total: ~120 phút

---

### Approach 3: Analyzer session pooling (Đơn giản nhất)

**Ý tưởng:** Reuse analyzer `AnalysisSession` giữa các cases

**File: `lib/src/adapters/dart/dart_analysis_workspace.dart:80`**

```dart
final Map<String, Future<SomeResolvedLibraryResult>> _libraryCache = {};
```

**Implementation:**

```dart
final class AnalyzerSessionPool {
  final Map<String, AnalysisSession> _sessions = {};
  
  AnalysisSession getOrCreate(String projectId, Directory root) {
    if (_sessions.containsKey(projectId)) {
      print('[SESSION REUSE] $projectId');
      return _sessions[projectId]!;
    }
    
    print('[SESSION CREATE] $projectId');
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(p.absolute(root.path))],
    );
    final session = collection.contexts.first.currentSession;
    _sessions[projectId] = session;
    return session;
  }
}
```

**Vấn đề:**
- `AnalysisSession` tied to specific root path
- Mỗi corpus view có path khác nhau
- → Session không reusable

**Rủi ro:**
- **High:** Không hoạt động với changing corpus view paths
- **N/A:** Phải combine với approach 2

---

## 4. Recommendation: Hybrid Approach 2 + Family Batch

**Chiến lược:**

1. **Ngắn hạn (1-2 tuần):** Chỉ chạy family batch mode
   - Skip individual cases
   - Verify 3 family batches pass trong <2 giờ
   - Giảm scope từ 367 → 3 attempts

2. **Trung hạn (2-4 tuần):** Implement persistent corpus view (Approach 2)
   - Refactor `provisionView()` → `getSharedView()`
   - Keep 1 corpus view per project
   - Reuse ProjectContext + DartAnalysisWorkspace

3. **Dài hạn (1-2 tháng):** Thêm incremental analysis
   - Cache resolved library results
   - Only re-analyze changed files
   - Persist cache to disk

**Implementation phases:**

### Phase 1: Skip individual cases (1 ngày)

```dart
// File: benchmark/accuracy/test_l10n_mutation_readiness_v3_family_only.dart

final class TestComposition {
  static L10nMutationReadinessDependencies createFamilyOnly() {
    return L10nMutationReadinessDependencies(
      // ...existing...
      enableProjectEligibilityPreflight: true, // Already set
      // Thêm flag mới:
      skipIndividualCases: true, // NEW FLAG
    );
  }
}
```

```dart
// File: benchmark/accuracy/l10n_mutation_readiness.dart:1330

if (!dependencies.skipIndividualCases) { // NEW CHECK
  for (final caseId in [...plan.individualCaseIds]..sort()) {
    // ... existing individual case loop ...
  }
}
```

### Phase 2: Persistent corpus view (1-2 tuần)

```dart
// File: benchmark/accuracy/src/l10n_readiness_production.dart

final class ProductionL10nReadinessComposition {
  final Map<String, _PersistentProjectView> _persistentViews = {};
  
  Future<ProductionL10nReadinessProjectView> getSharedView(
    String projectId,
  ) async {
    // Implementation từ Approach 2
  }
  
  Future<void> dispose() async {
    for (final view in _persistentViews.values) {
      await view.corpusView.dispose();
    }
    _persistentViews.clear();
  }
}

final class _PersistentProjectView {
  final CorpusProjectView corpusView;
  final ProjectContext context;
  final DartAnalysisWorkspace workspace;
  
  _PersistentProjectView({
    required this.corpusView,
    required this.context,
    required this.workspace,
  });
}
```

**Interface changes:**

```dart
// OLD:
abstract class L10nMutationReadinessDependencies {
  Future<L10nReadinessProjectView> Function(String projectId) provisionView;
}

// NEW:
abstract class L10nMutationReadinessDependencies {
  Future<L10nReadinessProjectView> Function(String projectId) getSharedView;
  Future<void> Function() disposeSharedViews;
}
```

### Phase 3: Disk cache (1 tháng)

```dart
// File: lib/src/adapters/dart/dart_analysis_workspace_cache.dart

final class DartAnalysisWorkspaceCache {
  static const _cacheVersion = 'v1';
  
  Future<DartAnalysisWorkspace?> load({
    required String projectId,
    required String repositorySha,
    required Directory root,
  }) async {
    final cacheDir = Directory('.flutter_pruner_cache/workspaces');
    final cacheKey = '$projectId-$repositorySha-$_cacheVersion';
    final cacheFile = File('${cacheDir.path}/$cacheKey.cache');
    
    if (!cacheFile.existsSync()) return null;
    
    // Deserialize workspace state
    final data = jsonDecode(await cacheFile.readAsString());
    
    // Reconstruct AnalysisContextCollection
    final collection = AnalysisContextCollection(
      includedPaths: [p.normalize(p.absolute(root.path))],
    );
    
    // Warm up _libraryCache from disk
    final workspace = DartAnalysisWorkspace._fromCache(
      project: ...,
      collection: collection,
      cachedLibraries: data['libraries'],
    );
    
    return workspace;
  }
  
  Future<void> save(
    DartAnalysisWorkspace workspace,
    String projectId,
    String repositorySha,
  ) async {
    // Serialize workspace state to disk
  }
}
```

**Rủi ro:** analyzer internal state không serializable → có thể không feasible

---

## 5. Rủi ro kỹ thuật chi tiết

### 5.1. Concurrency issues

**Vấn đề:**
```dart
// Case 1 và Case 2 cùng project chạy parallel:
Task 1: getSharedView('gitjournal') → creates view
Task 2: getSharedView('gitjournal') → finds existing view
Task 1: scan(view, case1) → mutates workspace cache
Task 2: scan(view, case2) → reads stale cache
```

**Giải pháp:**
```dart
final Map<String, Future<_PersistentProjectView>> _viewCreationFutures = {};

Future<_PersistentProjectView> getSharedView(String projectId) async {
  // Deduplicate concurrent creation
  if (_viewCreationFutures.containsKey(projectId)) {
    return await _viewCreationFutures[projectId]!;
  }
  
  if (_persistentViews.containsKey(projectId)) {
    return _persistentViews[projectId]!;
  }
  
  final future = _createView(projectId);
  _viewCreationFutures[projectId] = future;
  
  try {
    final view = await future;
    _persistentViews[projectId] = view;
    return view;
  } finally {
    _viewCreationFutures.remove(projectId);
  }
}
```

**Mutex cho scan:**
```dart
final Map<String, Lock> _scanLocks = {};

Future<ScanResult> scan(ProjectView view, List<Case> cases) async {
  final lock = _scanLocks.putIfAbsent(view.projectId, () => Lock());
  return await lock.synchronized(() async {
    return await _doScan(view, cases);
  });
}
```

### 5.2. Memory management

**Vấn đề:**
- 3 corpus views × ~400MB each = 1.2GB
- 3 workspaces × ~500MB analyzer cache = 1.5GB
- Total: ~2.7GB memory usage

**Giải pháp:**
```dart
class _PersistentProjectView {
  DateTime lastUsed = DateTime.now();
  
  void touch() {
    lastUsed = DateTime.now();
  }
}

Future<void> _evictStaleViews() async {
  final now = DateTime.now();
  final staleThreshold = Duration(minutes: 30);
  
  for (final entry in _persistentViews.entries.toList()) {
    if (now.difference(entry.value.lastUsed) > staleThreshold) {
      print('[EVICT] Stale view: ${entry.key}');
      await entry.value.corpusView.dispose();
      _persistentViews.remove(entry.key);
    }
  }
}
```

### 5.3. Corpus view mutation

**Vấn đề:**
```dart
// L10n generation mutates corpus view:
await generator.generate(view.packageRoot); // Writes files
// Analyzer cache now stale for generated files
```

**Giải pháp:**
```dart
final class _PersistentProjectView {
  final Set<String> _generatedFiles = {};
  
  Future<void> invalidateGenerated() async {
    for (final path in _generatedFiles) {
      workspace.invalidatePath(path);
    }
    _generatedFiles.clear();
  }
  
  Future<void> recordGenerated(List<String> paths) async {
    _generatedFiles.addAll(paths);
  }
}
```

### 5.4. Fixture overlay staleness

**Vấn đề:**
- Corpus view apply overlays (flutter_pruner_v2_accuracy.yaml)
- Overlays define coverage scope
- Different cases có thể cần different overlays

**Manifest evidence:**
```json
"fixtureOverlays": [
  {
    "relativePath": "flutter_pruner_v2_accuracy.yaml",
    "sha256": "4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05"
  }
]
```

**Giải pháp:**
```dart
String _buildCacheKey(String projectId, L10nMutationProjectManifest project) {
  final overlayHashes = project.fixtureOverlays
      .map((o) => o['sha256'])
      .join('-');
  return '$projectId-${project.repositorySha}-$overlayHashes';
}

bool _isCompatible(_PersistentProjectView view, L10nMutationProjectManifest project) {
  final currentKey = _buildCacheKey(view.projectId, view.manifest);
  final requestedKey = _buildCacheKey(project.projectId, project);
  return currentKey == requestedKey;
}
```

---

## 6. Testing strategy

### 6.1. Unit tests

```dart
// test/adapters/l10n/persistent_corpus_view_test.dart

void main() {
  group('PersistentCorpusViewFactory', () {
    test('reuses view for same project', () async {
      final factory = PersistentCorpusViewFactory(...);
      
      final view1 = await factory.getSharedView('gitjournal');
      final view2 = await factory.getSharedView('gitjournal');
      
      expect(identical(view1.workspace, view2.workspace), isTrue);
    });
    
    test('creates separate views for different projects', () async {
      final factory = PersistentCorpusViewFactory(...);
      
      final view1 = await factory.getSharedView('gitjournal');
      final view2 = await factory.getSharedView('gsy');
      
      expect(identical(view1.workspace, view2.workspace), isFalse);
    });
    
    test('invalidates cache when overlays change', () async {
      final factory = PersistentCorpusViewFactory(...);
      
      final view1 = await factory.getSharedView('gitjournal');
      
      // Simulate overlay change
      final manifestV2 = manifest.copyWith(
        fixtureOverlays: [...differentOverlays],
      );
      
      final view2 = await factory.getSharedView('gitjournal');
      
      expect(identical(view1.workspace, view2.workspace), isFalse);
    });
  });
}
```

### 6.2. Integration tests

```dart
// benchmark/accuracy/test/persistent_view_benchmark_test.dart

void main() {
  test('individual cases reuse workspace', () async {
    final stopwatch = Stopwatch()..start();
    
    final dependencies = TestDependencies.withPersistentViews();
    final result = await runL10nMutationReadiness(
      ['--manifest', 'test-manifest.json', ...],
      dependencies: dependencies,
    );
    
    stopwatch.stop();
    
    expect(result, equals(0));
    expect(stopwatch.elapsed.inMinutes, lessThan(120)); // <2 hours
    
    // Verify workspace was reused
    final stats = dependencies.getStats();
    expect(stats.workspaceCreations, equals(3)); // Only 3 projects
    expect(stats.scanCalls, equals(367)); // All cases scanned
  });
}
```

### 6.3. Correctness verification

```dart
// Chạy với và không có cache, verify results identical:

void main() {
  test('cached results match non-cached', () async {
    // Run without cache
    final resultNoCache = await runBenchmark(useCache: false);
    
    // Run with cache
    final resultWithCache = await runBenchmark(useCache: true);
    
    // Compare all findings
    expect(
      resultWithCache.staticPositiveCandidates,
      equals(resultNoCache.staticPositiveCandidates),
    );
    expect(
      resultWithCache.staticNegativeNonCandidates,
      equals(resultNoCache.staticNegativeNonCandidates),
    );
    
    // Deep compare evidence
    for (final caseId in resultNoCache.cases.keys) {
      final evidenceNoCache = resultNoCache.cases[caseId]!['evidence'];
      final evidenceWithCache = resultWithCache.cases[caseId]!['evidence'];
      expect(evidenceWithCache, equals(evidenceNoCache));
    }
  });
}
```

---

## 7. Rollout plan

### Week 1: Family-only mode
- [ ] Add `skipIndividualCases` flag
- [ ] Test family batch completes in <2 hours
- [ ] Verify 3 family batches pass

### Week 2-3: Persistent view prototype
- [ ] Implement `_PersistentProjectView`
- [ ] Refactor `provisionView()` → `getSharedView()`
- [ ] Add concurrency locks
- [ ] Unit tests

### Week 4: Integration testing
- [ ] Run full benchmark with persistent views
- [ ] Compare results with non-cached baseline
- [ ] Profile memory usage
- [ ] Fix bugs

### Week 5-6: Production rollout
- [ ] Enable in CI
- [ ] Monitor for regressions
- [ ] Document cache behavior

### Week 7-8: Disk cache (optional)
- [ ] Investigate analyzer serialization
- [ ] Prototype disk cache
- [ ] Benchmark cold vs warm cache

---

## 8. Success metrics

**Performance:**
- [ ] Benchmark completes in <2 hours (from 180+ hours)
- [ ] Memory usage <4GB
- [ ] No OOM crashes

**Correctness:**
- [ ] 100% result parity with non-cached baseline
- [ ] All 367 cases pass/fail identically
- [ ] Evidence hashes match

**Reliability:**
- [ ] No flaky failures
- [ ] Deterministic across runs
- [ ] Works on CI and local

---

## 9. Fallback plan

Nếu persistent view approach không feasible:

1. **Fallback to family-only mode permanently**
   - Accept 3 family batches as sufficient coverage
   - Skip individual case validation
   - Reduce scope but keep reliability

2. **Pre-warm analyzer cache**
   - Run full analysis once per project
   - Save resolved units to disk
   - Load cache before benchmark
   - Still slower but more reliable than runtime cache

3. **Parallel execution with isolated workspaces**
   - Run 3 projects in parallel
   - Each project gets dedicated machine/container
   - No cache, just raw parallelism
   - 180 hours / 3 = 60 hours per project
   - With beefy machines: ~30-40 hours total

---

## 10. Tóm tắt rủi ro

| Rủi ro | Mức độ | Giảm thiểu |
|--------|--------|------------|
| Race conditions giữa concurrent scans | Medium | Thêm mutex per project |
| Memory leak từ stale views | Medium | LRU eviction + dispose |
| Corpus view disposal conflicts | High | Reference counting + disposal queue |
| Analyzer cache staleness | High | Invalidate on l10n generation |
| Fixture overlay mismatch | Medium | Cache key include overlay hashes |
| ProjectContext root.path drift | High | Keep persistent view, không dispose |
| Serialization không feasible | Low | Skip disk cache (phase 3) |

**Khuyến nghị cuối cùng:**
- **Implement Approach 2 (Persistent corpus view)**
- **Skip Approach 3 (Disk cache) unless phase 2 succeeds**
- **Start with family-only mode to validate approach**
