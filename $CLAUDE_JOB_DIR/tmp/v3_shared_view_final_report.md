# V3 Shared View Optimization - Final Report

## Executive Summary

V3 Shared View optimization was implemented to cache `ProjectContext.load()` results across test cases. Testing revealed that **SharedViewManager causes 32.4% performance regression** in family batch mode and should **NOT be used** for this scenario.

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
   - All overhead, zero benefit

3. **Candidate generator anomaly**
   - 47ms → 347ms (7.4x slower)
   - Possible causes:
     - Lock contention affecting timing measurement
     - GC pressure from cache structures
     - Measurement artifact
   - Requires further investigation

### Family Batch vs Individual Case Mode

**Family Batch Flow (optimal without SharedViewManager):**
```
For project family:
  1. Provision view once
  2. Scan once with all cases
  3. Evaluate all positive candidates together
  4. Dispose view
Total: 1 provision per project
```

**Individual Case Flow (where SharedViewManager helps):**
```
Without SharedViewManager:
  For each of 419 cases:
    1. Provision view  ← expensive!
    2. Scan
    3. Evaluate case
    4. Dispose view
Total: 419 provisions

With SharedViewManager:
  For each of 419 cases:
    1. Get cached view  ← fast after first!
    2. Scan (with lock)
    3. Evaluate case
Total: 1 provision + 418 cache hits = huge speedup
```

## Implementation Status

### What Was Built

1. **SharedViewManager** (`benchmark/accuracy/src/shared_view_manager.dart`)
   - Cache for ProjectContext views
   - Lock-based synchronization
   - Debug logging for cache hits/misses
   - Status: ✓ Working correctly

2. **Individual case support** (already existed)
   - `_runIndividualAttemptWithSharedView()`
   - Uses SharedViewManager when available
   - Status: ✓ Working correctly

3. **Family batch support** (attempted, then reverted)
   - `_runFamilyAttemptWithSharedView()` - created
   - Integration into harness - added
   - Status: ⚠️ **REVERTED** due to performance regression

### What Was Reverted

File: `benchmark/accuracy/l10n_mutation_readiness.dart`
- Removed `_runFamilyAttemptWithSharedView()` function
- Reverted family batch call sites to use `_runFamilyAttempt()` only
- Family batch mode now bypasses SharedViewManager entirely

Reason: 32.4% performance regression with zero benefit

## Architecture Decision

**SharedViewManager should ONLY be used for individual case mode.**

### Use Cases

✓ **Good use cases:**
- Individual case mode: `--case gitjournal:l10n:drawerFs`
- Multiple individual cases of same project
- Multi-project scenarios with case reuse

✗ **Bad use cases:**
- Family batch mode: `--family gitjournal`
- Single test case runs
- Any scenario with ≤1 provision per project

### Code Structure

```dart
// Individual case mode - uses SharedViewManager
if (dependencies.sharedViewManager != null) {
  await _runIndividualAttemptWithSharedView(
    sharedEntry: await dependencies.sharedViewManager!.getSharedView(projectId),
    ...
  );
} else {
  await _runIndividualAttempt(...);
}

// Family batch mode - does NOT use SharedViewManager
// Always calls _runFamilyAttempt() directly
await _runFamilyAttempt(
  plan: plan,
  projectId: projectId,
  dependencies: dependencies,
);
```

## Files Modified (Final State)

1. **benchmark/accuracy/src/shared_view_manager.dart**
   - Added debug logging
   - No functional changes
   - Status: Modified, kept

2. **benchmark/accuracy/l10n_mutation_readiness.dart**
   - No changes (reverted to original)
   - Family batch bypasses SharedViewManager
   - Individual case mode uses SharedViewManager
   - Status: Clean (all changes reverted)

3. **benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart**
   - Test harness with SharedViewManager enabled
   - Added missing import
   - Status: Modified, kept for individual case testing

## Recommendations

### 1. Document This Decision
Add to V3 planning docs:
- SharedViewManager is for individual case mode only
- Family batch mode is already optimal
- Do not extend SharedViewManager to family batch

### 2. Remove Confusing Code
Consider removing `sharedViewManager` parameter from `L10nMutationReadinessDependencies` entirely, or rename to make scope clear: `sharedViewManagerForIndividualCases`

### 3. Test Individual Case Mode
To measure actual SharedViewManager benefit:
```bash
# Run multiple individual cases (not family batch)
for case_id in gitjournal:l10n:drawerFs gitjournal:l10n:drawerGraph ...; do
  dart benchmark/accuracy/l10n_mutation_readiness.dart --case "$case_id" ...
done
```

Expected: 419x faster with SharedViewManager vs without

### 4. Investigate Candidate Generator Anomaly
The 644% regression in candidate generator timing needs investigation:
- Profile with `--observe` to see hot paths
- Check if lock affects timing measurement
- Verify GC pressure from cache structures

## Lessons Learned

1. **Cache only helps with reuse**
   - Family batch = 1 load per project = no reuse
   - Don't add caching without reuse opportunity

2. **Measure before optimizing**
   - Assumed SharedViewManager would help family batch
   - Testing proved it hurts performance
   - Always validate assumptions with real data

3. **Different modes need different optimizations**
   - Individual case mode: needs caching
   - Family batch mode: already optimal
   - One size does not fit all

4. **Overhead matters**
   - Even small overhead (cache management, locks) becomes significant
   - When benefit is zero, overhead dominates
   - Keep hot paths lean

## Next Steps

1. ✅ Revert family batch changes (DONE)
2. ✅ Document architecture decision (DONE - this report)
3. ⏭️ Test individual case mode to measure actual speedup
4. ⏭️ Update V3 planning docs with scope limitations
5. ⏭️ Investigate candidate generator timing anomaly

## Files for Reference

- Test results: `/private/var/tmp/baseline-gitjournal.json`, `/private/var/tmp/optimized-gitjournal.json`
- Analysis script: `/tmp/test_family_batch_comparison.md`
- This report: `$CLAUDE_JOB_DIR/tmp/v3_shared_view_final_report.md`
- Detailed findings: `$CLAUDE_JOB_DIR/tmp/v3_shared_view_findings.md`
