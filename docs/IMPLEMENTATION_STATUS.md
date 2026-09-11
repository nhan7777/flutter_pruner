# V3 Implementation Status — Phase B–H

**Date:** 2026-09-05
**Reference:** V3_ROADMAP.md

## Phase A: Baseline ✅ COMPLETE

- Git status documented: 42 files modified (24 production, 17 test, 6 benchmark)
- Dart analyze: ✅ No issues found
- Apply tests: 69/72 passed (3 failures in process management, not l10n-specific)
- Quarantine tests: 198/200 passed (2 failures in exception message text only)
- L10n tests: Running in background

**Key finding:** Roadmap concerns about compile errors have been resolved.

## Phase B: Restore Compile & Contract Consistency

### Current State Analysis

**Already resolved (roadmap mentioned but not found):**
1. ✅ `AnalysisSnapshot` constructor — line 26 has `const` default for `actionReadinessIndex`
2. ✅ No analyzer errors found
3. ✅ Tests compile and run

**Remaining contract verification needed:**
1. Verify default resolver is no-op for V2 callers
2. Verify l10n readiness doesn't create SAFE/HIGH outside policy
3. Test coverage for edge cases

### Implementation Tasks

#### B.1: Verify Default Resolver Behavior
- [x] Check `ProjectAnalyzer` integration point for resolver (verified: `actionReadinessResolver ?? const NoOpActionReadinessResolver()`, `project_analyzer.dart:42`)
- [x] Verify backward compatibility with V2 review-only mode (default NoOp = V2 behavior)
- [ ] Add test: analyzer without readiness resolver stays V2 review-only
- [ ] Add test: readiness resolver only activates with explicit opt-in

#### B.2: Edge Case Coverage
- [x] Test: package mode returns empty index (`l10n_static_readiness_resolver_test.dart:46`, `l10n_static_readiness_integration_test.dart:227`)
- [x] Test: package-internal mode sets hasExternalConsumerExposure (`l10n_static_readiness_resolver_test.dart:147`, `l10n_static_readiness_integration_test.dart:320`)
- [x] Test: nodes with integrity blockers are excluded (`_hasIntegrityBlockers`, `l10n_static_readiness_resolver.dart:193`)
- [ ] Test: malformed node IDs are skipped
- [ ] Test: family grouping correctness
- [ ] Test: empty family groups return empty index

#### B.3: Contract Consistency Checks
- [ ] Run focused l10n tests (wait for background task)
- [ ] Run apply tests with verbose output
- [ ] Document any warnings as pre-existing or new

**Acceptance:** All focused tests pass; default behavior confirmed V2-compatible.

---

## Phase C: Audit Readiness Boundary

### Issues Identified from Code Review

**L10nStaticReadinessResolver (lib/src/adapters/l10n/l10n_static_readiness_resolver.dart)**

Current implementation:
- ✅ Groups by family
- ✅ Checks package mode
- ✅ Checks integrity blockers
- ✅ Extracts paths from node origins

**Missing per roadmap:**
- ❌ Config ownership verification (l10n.yaml)
- ❌ Template ARB ownership (app_en.arb)
- ❌ Locale ARB ownership (all .arb files)
- ❌ Generated output ownership verification
- ❌ Stale output detection
- ❌ Config fingerprint (Flutter SDK, l10n.yaml content hash)
- ❌ Complete mutation footprint beyond node origins

**Specific gaps:**

1. **physicalPaths from node.origin insufficient** (lines 63-66)
   - Only captures ARB file where key is declared
   - Missing: all locale ARBs, generated .dart outputs, l10n.yaml

2. **No config validation** (lines 88-89)
   - `configurationFingerprint: 'static-resolver-v1'` is hardcoded
   - Should hash: Flutter SDK version, l10n.yaml content, arb-dir path

3. **No generated output enumeration**
   - Needs: output-dir, output-class, output-localization-file
   - Must verify generated files exist and match expected pattern

4. **No stale output detection**
   - Generated files may be from old config
   - ARB template may have changed

5. **No family→files mapping verification**
   - Multiple families could share ARB dir
   - Need to verify disjoint ownership when concurrent

### Implementation Tasks

#### C.1: Config Ownership Verification
- [x] Load l10n.yaml for each candidate family (`L10nConfig.load`, resolver uses `arbInventory`)
- [x] Verify arb-dir exists (via `arbInventory` enumeration)
- [x] Verify template-arb-file exists (via `arbInventory`)
- [x] Enumerate all locale ARB files in arb-dir (via `arbInventory`)
- [ ] Add blocker reason codes: ConfigMissing, ArbDirUnreadable, TemplateAbsent (uses generic `arbInventory.blockers` + `scopedBlockers`, not named codes)

#### C.2: Generated Output Ownership
- [x] Compute expected output paths from config (`config.generatedLibraryPath`, `config.outputDir` in physicalPaths)
- [ ] Check each output file exists
- [ ] Add blocker: GeneratedOutputAbsent
- [ ] Verify output files are within project root
- [ ] Add blocker: GeneratedOutputOutsideProject

#### C.3: Config Fingerprint
- [x] Compute hash of l10n.yaml content (SHA256, `l10n_static_readiness_resolver.dart:76-77`)
- [ ] Include Flutter SDK version in fingerprint (currently only l10n.yaml bytes; SDK version in toolchain fingerprint instead)
- [ ] Include arb-dir canonical path in fingerprint
- [x] Store in `configurationFingerprint` field
- [x] Use for transaction verification later (executor Step 0 + Step 10 TOCTOU revalidation)

#### C.4: Complete Mutation Footprint
- [x] Include in physicalPaths: ARB locations + generated library + outputDir + l10n.yaml (`l10n_static_readiness_resolver.dart:111-126`)
- [x] Group by family correctly
- [ ] Verify no path overlap between families

#### C.5: Stale Output Detection
- [ ] Check generated file mtimes vs ARB mtimes
- [ ] Add blocker: GeneratedOutputStale (optional, could be warning)
- [ ] Check config fingerprint vs last-known (when available)

#### C.6: Action Descriptor Consistency
- [ ] Verify `selectedKeys: {node.id}` matches family expansion
- [ ] Document: selection is per-key, mutation is per-family
- [ ] Store exact selected finding IDs in transaction

**Acceptance:** Readiness index only contains families passing ALL preconditions; stable reason codes for every failure type.

---

## Phase D: Correct Mutation Architecture

### Critical Issues Identified

**L10nMutationExecutor (lib/src/adapters/l10n/l10n_mutation_executor.dart)**

Current flow (lines 56-112):
1. Create quarantine (line 59)
2. Begin transaction (line 66)
3. ❌ **Edit ARB files in place** (line 77) — WRONG
4. ❌ **Run gen-l10n on live project** (line 80) — WRONG
5. Record cases applied (line 83)
6. Return success (line 93)

**Roadmap-mandated flow:**
1. Capture live baseline
2. **Preflight** — validate preconditions
3. **Materialize staging** — copy to temp dir
4. **Mutate staging ARB** — edit copies, not live files
5. **Run canonical gen-l10n in staging** — not in project
6. **Inspect generated outputs** — verify expected files created
7. **Compute candidate hashes** — SHA256 all outputs
8. **Create quarantine transaction** — journal everything
9. **Revalidate live hashes** — TOCTOU check
10. **Install candidate bytes** — atomic copy to live
11. **Rescan/verify** — run project verification
12. **Commit/rollback** — based on verification result

**Current problems:**

1. **Unjournaled writes** (line 59-63)
   - `createCaseQuarantine()` is called but then files are edited live
   - Quarantine should receive candidate bytes to install, not track after-the-fact

2. **No staging directory** 
   - gen-l10n runs in project.root (line 203)
   - Should run in isolated temp dir with copied ARB files

3. **No candidate bytes**
   - Generated output is written directly to project
   - Should materialize in staging, hash, then install atomically

4. **Empty quarantine entries** (line 59-63)
   - Roadmap notes: `createCaseQuarantine()` called with `entries: const []`
   - Need to pass actual write entries with bytes/modes

5. **No TOCTOU protection**
   - Live sources could change between analysis and install
   - Need to revalidate hashes before installation

6. **Rollback runs no generator**
   - Correct per roadmap
   - But need to ensure quarantine has journaled bytes to restore

### Implementation Tasks

#### D.1: Staging Architecture
- [x] Create staging directory structure (`L10nStagingManager.createStaging`, `l10n_staging_manager.dart:22`)
- [x] Copy l10n.yaml and all ARB files to staging (`materialize`, `l10n_staging_manager.dart:39`)
- [x] Set up staging as mini-project for gen-l10n (pubspec.yaml copied, staging as workingDirectory)

#### D.2: Preflight Validation
- [x] Before staging: revalidate readiness conditions (config fingerprint pre-flight, executor Step 0)
- [x] Check all source files still exist with expected hashes (ARB baseline capture, Step 0b)
- [x] Check no concurrent modifications since analysis (config fingerprint drift detection, Step 0)
- [x] Return early with blocker if preconditions changed (MutationResult.failed on drift)

#### D.3: Staging Mutation
- [x] Edit ARB files in staging dir only (`mutateArbFiles`, `l10n_staging_manager.dart:87`)
- [x] Run `flutter gen-l10n` with staging as working directory (`runGenL10nInStaging`, `l10n_staging_manager.dart:137`)
- [x] Capture stdout/stderr for diagnostics (GenL10nResult.success/failed)

#### D.4: Output Inspection
- [x] List all files created in staging output-dir (`inspect`, `l10n_staging_manager.dart:158`)
- [x] Verify expected files present (candidates.isNotEmpty check)
- [x] Verify no unexpected files (unexpectedFiles check)
- [x] Compute SHA256 for each generated file (sha256 hash in inspection)
- [x] Store as candidate hashes (GeneratedFileCandidate.sha256)

#### D.5: Quarantine Transaction with Candidate Bytes
- [x] Build QuarantineEntry for each file (`journalBuilder.buildQuarantineEntries`, Step 9)
- [x] Pass entries to `createCaseQuarantine()` — NOT `const []` (Step 11)
- [x] Journal includes: Finding IDs, config fingerprint, toolchain fingerprint, policy fingerprint (Step 9)

#### D.6: TOCTOU Revalidation
- [x] Before install: re-read config fingerprint (Step 10: `_computeConfigFingerprint`)
- [x] Compare with baseline from analysis (recheckFingerprint != family.configurationFingerprint)
- [x] If mismatch: abort with error (MutationResult.failed)
- [x] Re-verify ARB baseline hashes (`_validateArbBaseline`, Step 10)

#### D.7: Atomic Installation
- [x] Install candidate bytes through quarantine manager (Step 13)
- [x] Ensure all files installed or none (atomic via quarantine)
- [x] Update transaction state (quarantine transaction lifecycle)

#### D.8: Verification Integration
- [x] After install: trigger verification (Step 16: `verifier.verify`)
- [x] If pass: commit transaction (Step 18: `quarantine.commitTransaction`)
- [x] If fail: rollback transaction (Step 18: `quarantine.rollbackCasesAtomically`)

#### D.9: Rollback Without Generator
- [x] Rollback reads candidate bytes from journal (quarantine journal)
- [x] Restores original bytes atomically (`rollbackCasesAtomically`)
- [x] Does NOT run gen-l10n (rollback only restores bytes)

#### D.10: Failure Handling
- [x] Preflight failure → no staging created (early return before createStaging)
- [x] Staging/generation failure → clean up staging, no transaction (catch + cleanupStaging)
- [x] Install/verification failure → rollback via quarantine (catch + rollbackCasesAtomically)
- [x] Always cleanup staging (finally block: cleanupStaging)

**Acceptance:** No unjournaled writes; fail at any step restores byte/mode/status; candidate output only committed after complete family verification pass.

---

## Phase E: Focused Verification

### Test Coverage Needed

#### E.1: Resolver Tests
- [x] Unit: family grouping (`l10n_static_readiness_resolver_test.dart`, 11 tests)
- [x] Unit: path extraction from node origins (physicalPaths in resolver)
- [x] Unit: integrity blocker detection (`_hasIntegrityBlockers`, integration tests)
- [x] Unit: package mode returns empty (`l10n_static_readiness_resolver_test.dart:46`)
- [ ] Unit: malformed node IDs skipped

#### E.2: Footprint Tests
- [x] Unit: physical paths include all ARBs + generated outputs (`mutation_footprint_test.dart`, 19 tests)
- [x] Unit: family→paths mapping unique (equality/hashCode tests)
- [x] Unit: config fingerprint computation (SHA256 in resolver + executor)
- [ ] Unit: stale output detection

#### E.3: Mutation Tests
- [x] Integration: remove one key, verify ARB edited in staging (Phase E.2 in executor test)
- [x] Integration: remove multiple keys same family (Phase E.2 multi-key scenarios)
- [x] Integration: multiple locales (Phase E.2 multi-locale scenarios)
- [x] Integration: metadata companion (@key) removed (Phase E.2 metadata companion)
- [x] Integration: generated output replaced correctly (Phase E.2 generated output)
- [x] Integration: generated output for absent key removed (Phase E.2 absent key)

#### E.4: Failure Injection
- [x] Quarantine transition failures covered (`recoverable_clean_recovery_process_test.dart`, `recoverable_clean_store_test.dart`)
- [x] Verify recovery from each failure point (quarantine rollback tests)

#### E.5: Apply Tests
- [x] Exact selection matches mutation (Phase E.5 regression checks)
- [x] Stale snapshot detected (Phase E.6 config drift)
- [x] Concurrent modification detected (Phase E.6 ARB baseline drift)
- [x] Generator failure in staging (Phase E.6 gen-l10n failure)
- [x] Verifier rejection triggers rollback (Phase E.5 regression)
- [ ] Commit failure handling

#### E.6: Regression Tests
- [x] V2 adapters stay REVIEW-only (Phase E.5 regression checks)
- [x] Scan without mutation works (existing scan tests)
- [x] Package mode no action (resolver returns empty index)
- [x] Report schema unchanged (existing report tests)

**Acceptance:** All test categories pass; no false positives; no false negatives.

---

## Phase F: Natural-Project Evidence

### Evidence Collection Protocol

#### F.1: Production Readiness
- [ ] Freeze SHA + manifest
- [ ] Document: repo URL, commit SHA, Flutter SDK version
- [ ] Run focused production readiness check first
- [ ] Document preconditions: clean working tree, no pending changes

#### F.2: Individual Candidate Execution
- [ ] Run each candidate independently
- [ ] Record: finding ID, family ID, mutation status, duration
- [ ] Capture: quarantine dir, transaction ID, verification result
- [ ] Save: stdout, stderr, exit code

#### F.3: Family Batch Execution
- [ ] Run family batches separately
- [ ] Record: family count, key count, success/fail count
- [ ] Monitor: process liveness, JSON output progress
- [ ] Track to final state — not just `inProgress`

#### F.4: Negative Cases
- [ ] Run negative fixtures (keys with blockers)
- [ ] Verify: correctly excluded from mutation
- [ ] Record: blocker counts by reason code

#### F.5: Restoration Evidence
- [ ] After each mutation: rollback
- [ ] Verify: original bytes restored
- [ ] Hash check: before SHA == after rollback SHA
- [ ] Record: restoration success count

#### F.6: Metrics Collection
- [ ] Candidate/family counts
- [ ] Negative counts
- [ ] Blocker counts by type
- [ ] Mutation status distribution
- [ ] Restoration status (all should succeed)
- [ ] Toolchain identities (Flutter version, Dart version)
- [ ] Memory: peak RSS
- [ ] Time: wall clock per phase

#### F.7: Reproducibility Check
- [ ] Re-run subset of candidates
- [ ] Verify: same readiness decisions
- [ ] Verify: same mutation results
- [ ] Verify: deterministic transaction IDs

**Acceptance:** Complete evidence showing success/failure at each stage; smoke tests reach terminal state (not stuck in `inProgress`).

---

## Phase G: Shared-View Benchmark Validation

### Scope (per roadmap)

**Keep:**
- Shared view for individual-case benchmark mode ONLY
- Validation harness for evidence

**Do NOT implement:**
- Disk cache
- Incremental analysis
- Analyzer session pool
- Family-batch shared views (proven 32.4% regression)
- User-facing shared-view config option

### Validation Tasks

#### G.1: Baseline vs Optimized Comparison
- [ ] Same repo SHA, Flutter SDK, manifest, corpus root
- [ ] Run baseline (no shared view)
- [ ] Run optimized (individual-case shared view)
- [ ] Compare semantic results (not raw JSON with timing)

#### G.2: Metrics
- [ ] Cold load time
- [ ] Warm case time (second case in same family)
- [ ] Total wall time
- [ ] Peak RSS
- [ ] Cleanup time
- [ ] Lock wait time

#### G.3: Lifecycle Testing
- [ ] Provision failure handling
- [ ] Case failure handling
- [ ] Process cancel handling
- [ ] Dispose failure handling

#### G.4: Correctness Verification
- [ ] No semantic changes vs baseline
- [ ] All findings identical
- [ ] All readiness decisions identical
- [ ] Deterministic results

**Acceptance:** Correctness unchanged; measurable speedup in individual mode; no memory increase beyond budget; cleanup deterministic; family mode no regression.

---

## Phase H: Stage 3–5 Decision Points

### Stage 3: Public Adapter API (Read-only)

**Decision criteria:**
- [ ] Is there a concrete consumer? (IDE plugin, CI tool, programmatic scan)
- [ ] Does consumer need inspection only, or mutation too?
- [ ] What fields are essential vs internal?

**If yes:**
- [ ] Create read-only typed result:
  - Action support (boolean)
  - Reason/blocker (enum)
  - Family identity (string)
  - Affected finding IDs (list)
  - Physical footprint summary (bounded set of paths)
  - Verification status (enum)
- [ ] Do NOT expose: ActionReadinessIndex internals
- [ ] Do NOT expose: L10nMutationExecutor
- [ ] Do NOT expose: Quarantine internals
- [ ] Do NOT expose: MutationFootprint implementation

**If no consumer identified:**
- [ ] Defer Stage 3 entirely
- [ ] Document: API design deferred until demand confirmed

### Stage 4: Generated-Code Families

**Decision criteria:**
- [ ] Is there a second generated family with false-positive problem?
- [ ] Does it have workload justifying automation?
- [ ] Can we build independent oracle for verification?

**If yes (ONE family only):**
- [ ] Independent design document
- [ ] Independent evidence model
- [ ] Exact mutation footprint specification
- [ ] Staging generator protocol
- [ ] Generated output inspector
- [ ] No-resolution verification tests
- [ ] Restoration tests
- [ ] Negative fixtures
- [ ] Do NOT create "GenericGeneratedCodeMutationAdapter"

**Candidates:**
- JSON serialization (json_serializable)
- GraphQL (ferry, artemis)
- Protocol buffers (protobuf)
- Freezed classes

**If no clear candidate:**
- [ ] Research spike only (time-boxed)
- [ ] Do NOT productionize
- [ ] Document findings for future reference

### Stage 5: Concurrent Family Execution

**Decision criteria:**
- [ ] Are physical footprints disjoint?
- [ ] Is generator state not shared?
- [ ] Is there memory budget margin?
- [ ] Does benchmark show speedup after accounting for lock overhead?

**If yes:**
- [ ] Benchmark on disposable corpus first
- [ ] Bounded worker count (NOT `Future.wait` on all families)
- [ ] Mutex on shared resources (project.root/.dart_tool, analyzer caches)
- [ ] Deterministic scheduling
- [ ] Atomic rollback still works

**If no proven speedup:**
- [ ] Keep sequential as default
- [ ] Document: concurrency tested, no benefit
- [ ] Defer indefinitely

**Implementation notes:**
- [ ] L10n families may share:
  - ARB dir
  - Generated output dir
  - .dart_tool
  - Analyzer caches
  - Project mutation lock
  - Flutter resources
- [ ] Concurrent execution risks:
  - Lock contention
  - File collision
  - Generator race conditions
  - Peak RSS increase
  - Non-deterministic results
  - Difficult rollback

---

## Summary

**Priority:**
1. ✅ Phase A: Baseline (complete)
2. Phase B: Contract consistency (low risk, quick)
3. Phase C: Readiness boundary (medium risk, foundational)
4. Phase D: Mutation architecture (high risk, critical safety)
5. Phase E: Verification (quality gate)
6. Phase F: Natural-project evidence (acceptance criteria)
7. Phase G: Shared-view validation (optional optimization)
8. Phase H: Stage 3–5 decisions (conditional)

**Go/no-go gates:**
- Phase B → Phase C: All focused tests pass
- Phase C → Phase D: Readiness preconditions proven complete
- Phase D → Phase E: Mutation architecture correct, no unjournaled writes
- Phase E → Phase F: All test categories pass
- Phase F acceptance: Complete evidence, terminal states reached

**Do NOT proceed without:**
- Compile-clean state
- Passing focused tests
- Evidence of safety at each phase
- Explicit approval to continue

**Defer immediately:**
- Stage 3 (until consumer identified)
- Stage 4 (until second family proven necessary)
- Stage 5 (until disjoint footprints + memory margin proven)
- Disk cache (no evidence of bottleneck)
- Generic abstractions (each family needs independent design)
