# Phase D Implementation Plan: Correct Mutation Architecture

**Ngày:** 2026-09-05  
**Trạng thái:** Implementation in progress  
**Scope:** Staging-based mutation với TOCTOU protection và atomic installation

---

## 1. Vấn đề hiện tại

### Phân tích L10nMutationExecutor (lib/src/adapters/l10n/l10n_mutation_executor.dart)

**Vấn đề 1: Gen-l10n chạy trực tiếp trong project thật (line 199-212)**
```dart
Future<void> _runGenL10n(L10nFamily family, ProjectContext project) async {
  final result = await Process.run('flutter', [
    'gen-l10n',
  ], workingDirectory: project.root.path);  // ❌ Runs in live project
}
```

**Vấn đề 2: No preflight validation**
- Không kiểm tra config fingerprint trước mutation
- Không validate ARB ownership
- Không verify generated output paths

**Vấn đề 3: Unjournaled writes**
- Generated outputs được tạo nhưng không journal candidate bytes trước
- Transaction journal không chứa expected hashes
- Verification không biết candidate bytes nào là đúng

**Vấn đề 4: No staging isolation**
- ARB files edited in-place trong live project (line 180-197)
- Nếu gen-l10n fails, project ở trạng thái inconsistent
- Rollback phải chạy lại gen-l10n (không theo design)

---

## 2. Design: Staging-Based Mutation Architecture

### 2.1 Flow Overview

```
┌─────────────────────────────────────────────────────────────┐
│ Phase 1: Preflight Validation (live project, read-only)    │
├─────────────────────────────────────────────────────────────┤
│ 1. Load config, compute fingerprint (reuse from Phase C)   │
│ 2. Validate config ownership                               │
│ 3. Load ARB inventory, validate no blockers                │
│ 4. Capture baseline hashes (ARB + existing generated)      │
│ 5. Create quarantine with baseline entries                 │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 2: Staging Materialization (isolated, disposable)    │
├─────────────────────────────────────────────────────────────┤
│ 6. Create staging directory (<quarantine>/staging/)        │
│ 7. Copy l10n.yaml → staging/                               │
│ 8. Copy ARB files → staging/arb/                           │
│ 9. Copy pubspec.yaml (for gen-l10n context)               │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 3: Mutation in Staging (isolated, safe)              │
├─────────────────────────────────────────────────────────────┤
│ 10. Edit ARB files in staging (remove selected keys)       │
│ 11. Run flutter gen-l10n in staging directory              │
│ 12. Inspect generated outputs in staging                   │
│ 13. Compute candidate hashes for all generated files       │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 4: TOCTOU Validation & Journal Update                │
├─────────────────────────────────────────────────────────────┤
│ 14. Re-validate config fingerprint (TOCTOU check)          │
│ 15. Re-validate baseline hashes unchanged                  │
│ 16. Update transaction journal with candidate hashes       │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 5: Atomic Installation (live project, controlled)    │
├─────────────────────────────────────────────────────────────┤
│ 17. Begin atomic transaction                               │
│ 18. Install ARB files from staging → live                  │
│ 19. Install generated files from staging → live            │
│ 20. Record case as applied                                 │
└─────────────────────────────────────────────────────────────┘
                           ↓
┌─────────────────────────────────────────────────────────────┐
│ Phase 6: Verification (external, evidence-based)           │
├─────────────────────────────────────────────────────────────┤
│ 21. Verify complete write set matches candidate hashes     │
│ 22. Run verification commands (build, test, etc.)          │
│ 23. Commit or rollback based on verification result        │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Key Design Principles

1. **Staging isolation**: Gen-l10n chỉ chạy trong staging, không touch live project
2. **TOCTOU protection**: Config fingerprint validated trước và sau staging
3. **Complete journaling**: Baseline + candidate hashes journaled before installation
4. **Atomic installation**: Candidate bytes copied atomically, không regenerate
5. **Fail-closed**: Any validation failure → abort, không partial install
6. **Rollback without regeneration**: Restore từ journal, không chạy gen-l10n

---

## 3. Implementation Tasks

### Task D.1: Staging Directory Architecture

**File:** `lib/src/adapters/l10n/l10n_staging_manager.dart` (NEW)

**Responsibilities:**
- Create staging directory structure
- Copy l10n.yaml, ARB files, pubspec.yaml to staging
- Run gen-l10n in staging
- Inspect generated outputs
- Cleanup staging after success/failure

**API:**
```dart
class L10nStagingManager {
  /// Creates staging directory under [quarantineDir]/staging
  Future<Directory> createStaging(Directory quarantineDir);
  
  /// Materializes config and ARB files into staging
  Future<void> materialize({
    required Directory staging,
    required ProjectContext project,
    required L10nConfig config,
  });
  
  /// Mutates ARB files in staging (removes keys)
  Future<void> mutateArbFiles({
    required Directory staging,
    required List<ArbKey> keysToRemove,
  });
  
  /// Runs gen-l10n in staging directory
  Future<void> runGenL10nInStaging({
    required Directory staging,
  });
  
  /// Inspects generated outputs and computes hashes
  Future<StagingInspectionResult> inspect({
    required Directory staging,
    required L10nConfig config,
  });
  
  /// Cleans up staging directory
  Future<void> cleanupStaging(Directory staging);
}

class StagingInspectionResult {
  final List<GeneratedFileCandidate> candidates;
  final List<String> unexpectedFiles;
}

class GeneratedFileCandidate {
  final String relativePath;
  final String sha256;
  final int sizeBytes;
  final int? posixMode;
}
```

**Test coverage:**
- Staging directory creation and structure
- Config/ARB materialization
- Gen-l10n execution in staging
- Generated output inspection
- Cleanup on success/failure

---

### Task D.2: Preflight Validation

**File:** `lib/src/adapters/l10n/l10n_mutation_preflight.dart` (NEW)

**Responsibilities:**
- Validate config fingerprint matches ActionReadinessIndex
- Validate ARB inventory has no blockers
- Capture baseline hashes for ARB + generated files
- Detect TOCTOU violations

**API:**
```dart
class L10nMutationPreflight {
  /// Validates mutation preconditions before staging
  Future<PreflightResult> validate({
    required ProjectContext project,
    required String expectedConfigFingerprint,
    required List<String> expectedArbPaths,
    required List<String> expectedGeneratedPaths,
  });
}

sealed class PreflightResult {}

class PreflightSuccess extends PreflightResult {
  final String configFingerprint;
  final Map<String, BaselineHash> baselineHashes;
}

class PreflightFailure extends PreflightResult {
  final String reason;
  final String? details;
}

class BaselineHash {
  final String sha256;
  final int sizeBytes;
  final int? posixMode;
  final bool wasAbsent;
}
```

**Test coverage:**
- Config fingerprint validation
- ARB inventory validation
- Baseline hash capture
- TOCTOU detection scenarios

---

### Task D.3: TOCTOU Protection

**Enhancement:** Integrate config fingerprint validation into mutation flow

**Changes:**
1. `L10nMutationExecutor._executeFamily()` calls preflight with expected fingerprint
2. After staging generation, re-validate fingerprint before installation
3. If fingerprint changed → abort, rollback staging
4. Journal includes both baseline and candidate fingerprints

**TOCTOU scenarios:**
- Config modified between analysis and mutation
- ARB files modified between preflight and staging
- Generated outputs modified between staging and installation

**Test coverage:**
- Config change detected
- ARB change detected
- Generated output collision detected
- Abort and cleanup on TOCTOU failure

---

### Task D.4: Atomic Installation with Candidate Bytes

**File:** Refactor `lib/src/adapters/l10n/l10n_mutation_executor.dart`

**Key changes:**

1. **Remove in-place mutation**:
   - Delete `_editArbFiles()` that mutates live project
   - Delete `_runGenL10n()` that runs in live project

2. **Add staging-based flow**:
```dart
Future<MutationResult> _executeFamily(
  L10nFamily family,
  ProjectContext project,
) async {
  // 1. Preflight validation
  final preflight = await _preflight.validate(
    project: project,
    expectedConfigFingerprint: family.configFingerprint,
    expectedArbPaths: family.arbPaths,
    expectedGeneratedPaths: family.generatedOutputPaths,
  );
  
  if (preflight is PreflightFailure) {
    return MutationResult.failed(...);
  }
  
  final baseline = (preflight as PreflightSuccess).baselineHashes;
  
  // 2. Create quarantine with baseline entries
  final entries = _buildBaselineEntries(baseline);
  final quarantineDir = await quarantine.createCaseQuarantine(...);
  
  // 3. Create and materialize staging
  final staging = await _stagingManager.createStaging(quarantineDir);
  await _stagingManager.materialize(
    staging: staging,
    project: project,
    config: family.config,
  );
  
  // 4. Mutate in staging
  await _stagingManager.mutateArbFiles(
    staging: staging,
    keysToRemove: family.keysToRemove,
  );
  
  // 5. Generate in staging
  await _stagingManager.runGenL10nInStaging(staging: staging);
  
  // 6. Inspect candidates
  final inspection = await _stagingManager.inspect(
    staging: staging,
    config: family.config,
  );
  
  // 7. TOCTOU revalidation
  final revalidation = await _preflight.validate(...);
  if (revalidation is PreflightFailure) {
    await _stagingManager.cleanupStaging(staging);
    return MutationResult.failed(...);
  }
  
  // 8. Begin transaction with candidate hashes
  final transaction = await quarantine.beginTransaction(
    quarantineDir: quarantineDir,
    transactionId: family.familyId,
    ...
  );
  
  // 9. Install candidate bytes atomically
  await _installCandidateBytes(
    staging: staging,
    project: project,
    candidates: inspection.candidates,
  );
  
  // 10. Record case applied
  await quarantine.recordCaseApplied(...);
  
  // 11. Cleanup staging
  await _stagingManager.cleanupStaging(staging);
  
  return MutationResult.applied(...);
}
```

3. **Update QuarantineEntry building**:
   - Include candidate hashes in entries
   - Mark generated files with `wasAbsentBeforeTransaction` correctly
   - Include config fingerprint in transaction metadata

**Test coverage:**
- Full staging flow integration
- Candidate byte installation
- Transaction journaling with candidates
- Cleanup on success/failure at each step

---

## 4. Acceptance Criteria

### D.1: Staging Directory
- ✅ Staging created under `<quarantine>/staging/`
- ✅ Config + ARB files materialized correctly
- ✅ Gen-l10n runs successfully in staging
- ✅ Generated outputs inspected and hashed
- ✅ Staging cleaned up after success/failure

### D.2: Preflight Validation
- ✅ Config fingerprint validated
- ✅ ARB inventory validated
- ✅ Baseline hashes captured
- ✅ TOCTOU violations detected

### D.3: TOCTOU Protection
- ✅ Config change detected between analysis and mutation
- ✅ ARB change detected between preflight and installation
- ✅ Fingerprint revalidated before installation
- ✅ Mutation aborted on TOCTOU failure

### D.4: Atomic Installation
- ✅ Gen-l10n không chạy trong live project
- ✅ Candidate bytes installed atomically
- ✅ Transaction journal contains candidate hashes
- ✅ Rollback không chạy gen-l10n
- ✅ Verification validates complete write set

### Overall Phase D
- ✅ Zero unjournaled writes
- ✅ All tests passing (unit + integration)
- ✅ Clean compilation
- ✅ No regressions in V2 adapters

---

## 5. Test Strategy

### Unit Tests

1. **L10nStagingManager** (`test/adapters/l10n/l10n_staging_manager_test.dart`)
   - Staging creation
   - Materialization
   - Mutation in staging
   - Gen-l10n execution
   - Inspection
   - Cleanup

2. **L10nMutationPreflight** (`test/adapters/l10n/l10n_mutation_preflight_test.dart`)
   - Config validation
   - Baseline capture
   - TOCTOU detection

### Integration Tests

1. **Staging Flow** (`test/adapters/l10n/l10n_staging_integration_test.dart`)
   - End-to-end staging flow
   - Failure injection at each step
   - Cleanup verification

2. **TOCTOU Scenarios** (`test/adapters/l10n/l10n_toctou_test.dart`)
   - Config modified during mutation
   - ARB modified during mutation
   - Generated output collision

3. **Mutation Executor** (`test/adapters/l10n/l10n_mutation_executor_test.dart`)
   - Full mutation flow with staging
   - Transaction journaling
   - Atomic installation
   - Rollback scenarios

---

## 6. Implementation Order

1. **Task D.1**: L10nStagingManager + tests (staging infrastructure)
2. **Task D.2**: L10nMutationPreflight + tests (validation)
3. **Task D.3**: TOCTOU protection + tests (safety)
4. **Task D.4**: Refactor L10nMutationExecutor + integration tests (complete flow)
5. **Verification**: Run full test suite, verify no regressions
6. **Documentation**: Update Phase D completion report

---

## 7. Design Decisions

### Decision 1: Staging location
**Choice:** `<quarantine>/staging/` (inside quarantine directory)  
**Rationale:** 
- Co-located with transaction journal
- Automatic cleanup when quarantine removed
- Clear ownership and lifecycle

### Decision 2: Materialization scope
**Choice:** Copy only l10n.yaml, ARB files, and pubspec.yaml  
**Rationale:**
- Minimal staging footprint
- Gen-l10n only needs these files
- Avoid copying entire project

### Decision 3: TOCTOU validation timing
**Choice:** Validate before staging AND before installation  
**Rationale:**
- Early detection saves staging work
- Late detection prevents inconsistent install
- Two-phase check catches modifications during staging

### Decision 4: Rollback mechanism
**Choice:** Restore from journal, never run gen-l10n  
**Rationale:**
- Rollback must be fast and deterministic
- Gen-l10n can fail or produce different output
- Journal has exact baseline bytes

### Decision 5: Staging cleanup
**Choice:** Always cleanup, even on failure  
**Rationale:**
- Staging is disposable scratch space
- Quarantine journal is source of truth
- Avoid disk space leaks

---

## 8. Risk Mitigation

### Risk 1: Gen-l10n failure in staging
**Mitigation:** 
- Validate config before staging
- Capture gen-l10n stderr/stdout
- Cleanup staging on failure
- Return MutationFailed with details

### Risk 2: Partial installation
**Mitigation:**
- Use atomic file operations
- Journal all writes before installation
- Rollback if any installation step fails

### Risk 3: TOCTOU between revalidation and install
**Mitigation:**
- Minimize window between validation and install
- Use file locking if available
- Verification will catch inconsistencies

### Risk 4: Staging cleanup failure
**Mitigation:**
- Log cleanup failures but don't fail mutation
- Staging inside quarantine → cleaned on quarantine removal
- Add manual cleanup command if needed

---

## 9. Phase D Exit Criteria

- [ ] All 4 tasks (D.1-D.4) implemented
- [ ] All unit tests passing
- [ ] All integration tests passing
- [ ] Zero unjournaled writes verified
- [ ] TOCTOU protection verified
- [ ] Rollback without gen-l10n verified
- [ ] Clean compilation (`dart analyze`)
- [ ] No V2 adapter regressions
- [ ] Documentation complete

**Target:** Phase E (Focused Verification) ready to start
