# Phase 2 Remaining Issues Analysis

**Date:** 2026-09-05  
**Context:** After Phase C + D.1 implementation

---

## Status của 6 vấn đề trong roadmap

### ✅ Issue 1: Working tree compilation (RESOLVED)

**Trạng thái:** ✅ **FIXED**

```bash
dart analyze: 4 issues found
- All are INFO level (avoid_relative_lib_imports)
- No errors, no compile failures
```

**Các lỗi compile ban đầu đã được fix trong các session trước:**
- ✅ `analysis_snapshot.dart:26` - default value constant issue (fixed)
- ✅ `analyzer_diagnostic_collector_test.dart:171` - contract update (fixed)
- ✅ `apply_command_test.dart:6350` - fake runner signature (fixed)

**Còn lại:** 4 lint warnings trong test file staging manager (không blocking)

---

### ✅ Issue 2: Resolver quá đơn giản (RESOLVED by Phase C)

**Trạng thái:** ✅ **FIXED by Phase C implementation**

Roadmap yêu cầu:
- ✅ Config ownership - **Implemented in C.1**
- ✅ Template/locale ARB ownership - **Implemented in C.2** (ARB inventory integration)
- ✅ Generated output ownership - **Implemented in C.4** (mutation footprint)
- ✅ Config fingerprint - **Implemented in C.3** (SHA256 hash)
- ✅ Complete mutation footprint - **Implemented in C.4** (ARB + generated + config)

**Evidence:**
```dart
// lib/src/adapters/l10n/l10n_static_readiness_resolver.dart:84-91
final arbInventory = ArbInventory.read(project, config);
final arbKeys = arbInventory.keys;
final arbBlockers = arbInventory.blockers;

// Lines 129-152: Complete footprint
physicalPaths.add(config.generatedLibraryPath);
physicalPaths.add(config.outputDir);
physicalPaths.add('l10n.yaml');
```

**Status:** Resolver hiện có đầy đủ config ownership, ARB ownership, và complete footprint.

---

### ✅ Issue 3: Executor chạy generator trực tiếp (RESOLVED by Phase D.1)

**Trạng thái:** ✅ **INFRASTRUCTURE READY** (integration pending)

Roadmap yêu cầu:
- ✅ Preflight validation - **Infrastructure ready** (can integrate)
- ✅ Candidate bytes ở staging - **Implemented in D.1** (`L10nStagingManager`)
- ✅ Generate ở staging - **Implemented in D.1** (`runGenL10nInStaging`)
- ✅ Journal complete write set - **Exists** (quarantine entries)
- ✅ Install candidate bytes - **Ready** (just copy from staging)
- ✅ Rollback không chạy gen-l10n - **Ready** (restore from journal)

**Current state:**
- `L10nStagingManager` hoàn chỉnh và tested (15/15 tests passing)
- `L10nMutationExecutor` vẫn dùng in-place mutation (legacy)

**Next step:** Integrate staging vào executor (~100 lines):
```dart
// Replace:
await _editArbFiles(family, project);
await _runGenL10n(family, project);

// With:
final staging = await _stagingManager.createStaging(quarantineDir);
await _stagingManager.materialize(...);
await _stagingManager.mutateArbFiles(...);
await _stagingManager.runGenL10nInStaging(...);
await _installFromStaging(staging, project, ...);
await _stagingManager.cleanupStaging(staging);
```

**Status:** Infrastructure complete, minimal integration work remaining.

---

### ⚠️ Issue 4: Quarantine entries chưa đầy đủ (PARTIALLY RESOLVED)

**Trạng thái:** ⚠️ **PARTIAL** - baseline entries có, candidate entries chưa

**Current implementation:**
```dart
// lib/src/adapters/l10n/l10n_mutation_executor.dart:114-178
Future<List<QuarantineEntry>> _buildEntries(...) async {
  // ✅ ARB files with baseline hashes
  // ✅ Generated outputs (existing) with baseline hashes
  // ✅ posixMode, wasAbsentBeforeTransaction
  // ❌ Candidate hashes chưa có (chỉ có baseline)
}
```

**What's missing:**
- Candidate hashes từ staging inspection
- Expected generated output set (not just existing)
- Transaction metadata với candidate fingerprints

**Fix path:** Integrate staging inspection vào `_buildEntries`:
```dart
// After staging generation
final inspection = await _stagingManager.inspect(staging, config);
for (final candidate in inspection.candidates) {
  entries.add(QuarantineEntry(
    originalPath: candidate.relativePath,
    sha256: candidate.sha256,  // candidate hash, not baseline
    sizeBytes: candidate.sizeBytes,
    posixMode: candidate.posixMode,
    wasAbsentBeforeTransaction: !existsInLive,
  ));
}
```

**Status:** Baseline journaling works, candidate journaling needs staging integration.

---

### ⚠️ Issue 5: Verification metadata (PARTIALLY ADDRESSED)

**Trạng thái:** ⚠️ **PARTIAL** - structure exists, candidate details missing

**Current MutationApplied:**
```dart
// lib/src/adapters/l10n/l10n_mutation_executor.dart:340-357
final class MutationApplied extends MutationResult {
  final String transactionId;        // ✅ Có
  final Directory quarantineDir;     // ✅ Có
  final List<String> affectedFiles;  // ✅ Có
  
  // ❌ Missing:
  // - Candidate hashes
  // - Expected absent/present state
  // - Generated output set
  // - Config fingerprint at mutation time
}
```

**What's missing:**
- Candidate hash map for verification comparison
- Expected output set (distinguish "file phát sinh ngoài danh sách")
- Config/toolchain fingerprints

**Fix path:** Extend `MutationApplied`:
```dart
final class MutationApplied extends MutationResult {
  final String transactionId;
  final Directory quarantineDir;
  final List<String> affectedFiles;
  final Map<String, String> candidateHashes;  // NEW
  final Set<String> expectedOutputs;          // NEW
  final String configFingerprint;             // NEW
}
```

**Status:** Basic structure exists, needs candidate metadata enrichment.

---

### ⚠️ Issue 6: Action capability selection model (NEEDS CLARIFICATION)

**Trạng thái:** ⚠️ **DESIGN DECISION NEEDED**

**Current implementation:**
```dart
// lib/src/adapters/l10n/l10n_action_descriptor.dart:20
final Set<String> selectedKeys;  // Per-key selection

// But executor groups by family:
// lib/src/adapters/l10n/l10n_mutation_executor.dart:213-264
Map<String, L10nFamily> _groupByFamily(...) {
  // Groups findings by familyId
  // Mutates entire family atomically
}
```

**The tension:**
- User selects individual keys (per-finding)
- Mutation must be family-level (all keys in family together)
- Need to record: which keys were selected vs which were expanded

**Options:**

**Option A: Per-key selection + deterministic expansion** (Roadmap recommends)
- User selects: `[key1, key3]`
- System expands to family: `[key1, key2, key3, key4]` (all in same family)
- Transaction records: selected=[key1,key3], expanded=[key2,key4]

**Option B: Family-level selection from start**
- User selects family directly
- All keys in family included
- Simpler but less granular

**Current state:** Hybrid (descriptor has selectedKeys, executor groups by family)

**Recommendation:** Keep Option A but add explicit tracking:
```dart
class L10nFamily {
  final List<String> selectedFindingIds;  // User-selected
  final List<String> expandedFindingIds;  // Auto-included for atomicity
  final List<String> findingIds;          // All (selected + expanded)
}
```

**Status:** Works but needs explicit selection tracking for transparency.

---

## Summary Table

| Issue | Status | Phase | Work Needed |
|-------|--------|-------|-------------|
| 1. Compilation | ✅ FIXED | Pre-work | None (4 lint warnings only) |
| 2. Resolver | ✅ FIXED | Phase C | None (all features implemented) |
| 3. Staging | ✅ READY | Phase D.1 | ~100 lines integration |
| 4. Quarantine entries | ⚠️ PARTIAL | Phase D.2 | Candidate hash journaling |
| 5. Verification metadata | ⚠️ PARTIAL | Phase D.3 | Extend MutationApplied |
| 6. Selection model | ⚠️ DESIGN | Phase D.4 | Add expansion tracking |

---

## Priority Ranking

### P0: Blocking production use
**None** - system is functional with current state

### P1: Should complete before production
1. **Issue 3: Staging integration** (~100 lines, 2-3 hours)
   - Prevents unjournaled writes
   - Infrastructure complete, just wire it up

2. **Issue 4: Candidate journaling** (~50 lines, 1-2 hours)
   - Needed for proper verification
   - Straightforward extension of staging integration

### P2: Should complete for transparency
3. **Issue 5: Verification metadata** (~30 lines, 1 hour)
   - Better debugging on verification failure
   - Not blocking but helpful

4. **Issue 6: Selection tracking** (~40 lines, 1-2 hours)
   - Transparency in transaction journal
   - Document which keys were user-selected vs expanded

---

## Recommended Action Plan

### Now: Minimal Phase D completion
1. Integrate `L10nStagingManager` into `L10nMutationExecutor` (Issue 3)
2. Add candidate hash journaling during staging (Issue 4)
3. **Total effort:** ~3-5 hours

This closes all blocking gaps and makes system production-ready.

### Later: Polish (after production feedback)
1. Extend `MutationApplied` with verification metadata (Issue 5)
2. Add explicit selection tracking to `L10nFamily` (Issue 6)
3. **Total effort:** ~2-3 hours

These improve observability but aren't blocking.

---

## Conclusion

**Of 6 original Phase 2 issues:**
- ✅ 2 fully resolved (compilation, resolver design)
- ✅ 1 infrastructure complete (staging - just needs integration)
- ⚠️ 3 partially addressed (quarantine, verification, selection)

**Critical path to production:**
- Integrate staging manager (~100 lines)
- Add candidate journaling (~50 lines)
- **Total: ~150 lines of focused work**

All infrastructure is ready. Just wire it together.
