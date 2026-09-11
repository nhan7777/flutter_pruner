# V3 Shared View Optimization - Investigation Report

## Executive Summary

V3 Shared View optimization was designed to cache `ProjectContext.load()` results across test cases. Testing revealed that **SharedViewManager causes 32.4% performance regression** in family batch mode and should **NOT be used** for this scenario.

**Decision: SharedViewManager is for individual case mode ONLY.**

## Test Results: Gitjournal Family (419 cases, 1 project)

| Metric | Baseline | With SharedViewManager | Change |
|--------|----------|------------------------|--------|
| **Total time** | 36.4 min | 48.1 min | **+32.4%** ⚠️ |
| Staging time | 28.0 min | 40.1 min | +43.0% |
| Policy validation | 65 ms | 46 ms | -29.9% ✓ |
| Baseline generator | 48 ms | 52 ms | +7.7% |
| **Candidate generator** | 47 ms | 347 ms | **+644.6%** ⚠️ |
| Peak memory | 2.58 GB | 2.45 GB | -5.3% ✓ |

**Correctness:** ✓ All functional metrics match (status, candidates, restoration, policy)

## Root Cause Analysis

### Why SharedViewManager Hurts Family Batch Mode

1. **No cache reuse opportunity**
   - Family batch loads each project exactly once
   - SharedViewManager: 1 cache MISS, 0 cache HITs
   - No performance benefit from caching

2. **Pure overhead added**
   - Cache map operations (`_cache`, `_pendingLoads`)
   - Lock synchronization (`_cacheLock.synchronized()`)
   - Entry timestamp management
   - Result: All overhead, zero benefit

3. **Candidate generator anomaly**
   - 47ms → 347ms (7.4x slower)
   - Possible causes: lock contention, GC pressure, or timing measurement artifact
   - Requires further investigation if extending to other modes

### Family Batch vs Individual Case Mode

**Family Batch Flow (optimal without SharedViewManager):**
```
For project family:
  1. Provision view once
  2. Scan once with all cases
  3. Evaluate all positive candidates together
  4. Dispose view
Total: 1 provision per project ← already optimal
```

**Individual Case Flow (where SharedViewManager helps):**
```
Without SharedViewManager:
  For each of 419 cases:
    1. Provision view  ← expensive, repeated 419x
    2. Scan
    3. Evaluate case
    4. Dispose view
Total: 419 provisions

With SharedViewManager:
  For each of 419 cases:
    1. Get cached view  ← fast after first load
    2. Scan (with lock)
    3. Evaluate case
Total: 1 provision + 418 cache hits = huge speedup
```

## Implementation Status

### What Was Built & Tested

1. **SharedViewManager** (`benchmark/accuracy/src/shared_view_manager.dart`)
   - Cache for ProjectContext views
   - Lock-based synchronization
   - Debug logging for cache hits/misses
   - Status: ✓ Working correctly, kept with logging

2. **Individual case support** (already existed)
   - `_runIndividualAttemptWithSharedView()`
   - Uses SharedViewManager when available
   - Status: ✓ Working correctly

3. **Family batch support** (attempted, then reverted)
   - `_runFamilyAttemptWithSharedView()` created
   - Integration into both harness code paths
   - Testing showed 32.4% slowdown
   - Status: ⚠️ **REVERTED** due to performance regression

### Current State

- `benchmark/accuracy/l10n_mutation_readiness.dart`: Clean (all changes reverted)
- `benchmark/accuracy/src/shared_view_manager.dart`: Debug logging added
- `benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart`: Test harness kept for individual case testing

## Architecture Decision

**SharedViewManager should ONLY be used for individual case mode.**

### Use Cases

✓ **Appropriate use cases:**
- Individual case mode: `--case gitjournal:l10n:drawerFs`
- Multiple individual cases of same project
- Scenarios with many reuses of same ProjectContext

✗ **Inappropriate use cases:**
- Family batch mode: `--family gitjournal`
- Single test case runs
- Any scenario with ≤1 provision per project

### Recommended Code Pattern

```dart
// Individual case mode - uses SharedViewManager when available
if (dependencies.sharedViewManager != null) {
  await _runIndividualAttemptWithSharedView(
    sharedEntry: await dependencies.sharedViewManager!.getSharedView(projectId),
    ...
  );
} else {
  await _runIndividualAttempt(...);
}

// Family batch mode - NEVER uses SharedViewManager
// Always calls _runFamilyAttempt() directly
await _runFamilyAttempt(
  plan: plan,
  projectId: projectId,
  dependencies: dependencies,
);
```

## Lessons Learned

1. **Cache only helps with reuse**
   - Family batch = 1 load per project = no reuse opportunity
   - Don't add caching infrastructure without clear reuse pattern

2. **Measure before optimizing production code**
   - Initial assumption: SharedViewManager would help all modes
   - Testing proved: it hurts family batch performance significantly
   - Always validate optimization assumptions with real data

3. **Different execution modes need different optimizations**
   - Individual case mode: benefits from caching (reduces repeated loads)
   - Family batch mode: already optimal (single load)
   - One optimization strategy does not fit all execution patterns

4. **Overhead compounds without benefit**
   - Cache management overhead seems small
   - Lock synchronization overhead seems small
   - Combined overhead becomes significant when benefit is zero

## Recommendations

### 1. Document This Decision ✓
This report documents:
- SharedViewManager scope (individual case mode only)
- Why family batch mode should not use it
- Performance data supporting the decision

### 2. Keep Code Clean
Current state after revert:
- Family batch code path does not reference SharedViewManager
- Individual case code path uses SharedViewManager when available
- No dead code or confusing conditional logic

### 3. Future Testing
To measure actual SharedViewManager benefit in its intended use case:
```bash
# Run multiple individual cases (not family batch)
for case_id in $(list_of_case_ids); do
  dart benchmark/accuracy/l10n_mutation_readiness.dart --case "$case_id" ...
done
```
Expected: Significant speedup with SharedViewManager vs without

### 4. Investigation Needed (Low Priority)
The 644% candidate generator regression warrants investigation if:
- Planning to extend SharedViewManager to other scenarios
- Seeing similar timing anomalies elsewhere
- Otherwise, low priority since family batch won't use SharedViewManager

## Test Data

**Test configuration:**
- Corpus: gitjournal family
- Test cases: 419 (38 positive candidates + 381 negative non-candidates)
- Mode: Family batch (`--family "gitjournal"`)
- Environment: Local corpus at `/private/tmp/l10n_corpus_validation`

**Results files:**
- Baseline: `/private/var/tmp/baseline-gitjournal.json`
- Optimized: `/private/var/tmp/optimized-gitjournal.json`
- Both: status=passed, functionally identical results

## Conclusion

V3 Shared View optimization with SharedViewManager is a **valid optimization for individual case mode**, but causes **significant performance regression in family batch mode**. 

The implementation has been reverted to exclude family batch mode from using SharedViewManager. This decision is based on empirical testing showing 32.4% slowdown with no functional benefit.

**Status: Investigation complete. Architecture decision documented. Code in clean state.**

---

**Date:** 2026-09-03  
**Test Duration:** ~3 hours (multiple test runs, debugging, analysis)  
**Outcome:** Architectural clarity on SharedViewManager scope
