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
- [ ] Check `ProjectAnalyzer` integration point for resolver
- [ ] Verify backward compatibility with V2 review-only mode
- [ ] Add test: analyzer without readiness resolver stays V2 review-only
- [ ] Add test: readiness resolver only activates with explicit opt-in

#### B.2: Edge Case Coverage
- [ ] Test: package mode returns empty index
- [ ] Test: package-internal mode sets hasExternalConsumerExposure
- [ ] Test: nodes with integrity blockers are excluded
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
- [ ] Load l10n.yaml for each candidate family
- [ ] Verify arb-dir exists and is writable
- [ ] Verify template-arb-file exists
- [ ] Enumerate all locale ARB files in arb-dir
- [ ] Add blocker reason codes: ConfigMissing, ArbDirUnreadable, TemplateAbsent

#### C.2: Generated Output Ownership
- [ ] Compute expected output paths from config:
  - `{output-dir}/{output-localization-file}.dart`
  - `{output-dir}/{output-class}_*.dart` per locale
- [ ] Check each output file exists
- [ ] Add blocker: GeneratedOutputAbsent
- [ ] Verify output files are within project root
- [ ] Add blocker: GeneratedOutputOutsideProject

#### C.3: Config Fingerprint
- [ ] Compute hash of:
  - Flutter SDK version (`flutter --version --machine`)
  - l10n.yaml content (SHA256)
  - arb-dir path (canonical, resolved symlinks)
- [ ] Store in `configurationFingerprint` field
- [ ] Use for transaction verification later

#### C.4: Complete Mutation Footprint
- [ ] Include in physicalPaths:
  - All locale ARB files (not just template)
  - All generated .dart outputs
  - l10n.yaml (read-only, but affects generation)
- [ ] Group by family correctly
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
- [ ] Create staging directory structure:
  ```
  /tmp/flutter_pruner_staging_{familyId}_{timestamp}/
    l10n.yaml          (copied)
    lib/l10n/*.arb     (copied, then mutated)
    .dart_tool/        (fresh, for gen-l10n)
  ```
- [ ] Copy l10n.yaml and all ARB files to staging
- [ ] Set up staging as mini-project for gen-l10n

#### D.2: Preflight Validation
- [ ] Before staging: revalidate readiness conditions
- [ ] Check all source files still exist with expected hashes
- [ ] Check no concurrent modifications since analysis
- [ ] Return early with blocker if preconditions changed

#### D.3: Staging Mutation
- [ ] Edit ARB files in staging dir only
- [ ] Run `flutter gen-l10n` with staging as working directory
- [ ] Override output-dir to write into staging
- [ ] Capture stdout/stderr for diagnostics

#### D.4: Output Inspection
- [ ] List all files created in staging output-dir
- [ ] Verify expected files present
- [ ] Verify no unexpected files
- [ ] Compute SHA256 for each generated file
- [ ] Store as candidate hashes

#### D.5: Quarantine Transaction with Candidate Bytes
- [ ] Build QuarantineEntry for each file:
  - originalPath (relative to project root)
  - Live baseline SHA256 (current project state)
  - Candidate SHA256 (from staging)
  - Candidate bytes (read from staging)
  - posixMode
  - wasAbsentBeforeTransaction flag
- [ ] Pass entries to `createCaseQuarantine()` — NOT `const []`
- [ ] Journal includes:
  - Finding IDs
  - Config fingerprint
  - Toolchain fingerprint (Flutter SDK version)
  - Policy fingerprint (verification commands)

#### D.6: TOCTOU Revalidation
- [ ] Before install: re-read live files
- [ ] Compute current SHA256
- [ ] Compare with baseline from analysis
- [ ] If mismatch: abort with ConcurrentModification error
- [ ] If path collision (expected absent but now exists): abort

#### D.7: Atomic Installation
- [ ] Install candidate bytes through quarantine manager
- [ ] Use quarantine's atomic write protocol
- [ ] Ensure all files installed or none
- [ ] Update transaction state: installing → installed

#### D.8: Verification Integration
- [ ] After install: trigger verification (separate step)
- [ ] Verification runs project tests/build
- [ ] If pass: commit transaction
- [ ] If fail: rollback transaction (quarantine restores from journal)

#### D.9: Rollback Without Generator
- [ ] Rollback reads candidate bytes from journal
- [ ] Restores original bytes atomically
- [ ] Does NOT run gen-l10n
- [ ] Verifies restoration by comparing SHA256

#### D.10: Failure Handling
- [ ] Handle failure at each transition point:
  - Preflight failure → no staging created
  - Staging mutation failure → clean up staging, no transaction
  - Generation failure → clean up staging, no transaction
  - Journal creation failure → clean up staging
  - Install failure → rollback via quarantine
  - Verification failure → rollback via quarantine
  - Commit failure → attempt recovery, mark quarantine blocked

**Acceptance:** No unjournaled writes; fail at any step restores byte/mode/status; candidate output only committed after complete family verification pass.

---

## Phase E: Focused Verification

### Test Coverage Needed

#### E.1: Resolver Tests
- [ ] Unit: family grouping
- [ ] Unit: path extraction from node origins
- [ ] Unit: integrity blocker detection
- [ ] Unit: package mode returns empty
- [ ] Unit: malformed node IDs skipped

#### E.2: Footprint Tests
- [ ] Unit: physical paths include all ARBs + generated outputs
- [ ] Unit: family→paths mapping unique
- [ ] Unit: config fingerprint computation
- [ ] Unit: stale output detection

#### E.3: Mutation Tests
- [ ] Integration: remove one key, verify ARB edited in staging
- [ ] Integration: remove multiple keys same family
- [ ] Integration: multiple locales (en, vi, ja)
- [ ] Integration: metadata companion (@key) removed
- [ ] Integration: generated output replaced correctly
- [ ] Integration: generated output for absent key removed

#### E.4: Failure Injection
- [ ] Before/after each quarantine transition:
  - intentFlushed
  - beforeMove
  - metadataFlushed
  - retainedVerified
  - committedJournalFlushed
- [ ] Verify recovery from each failure point

#### E.5: Apply Tests
- [ ] Exact selection matches mutation
- [ ] Stale snapshot detected
- [ ] Concurrent modification detected
- [ ] Generator failure in staging
- [ ] Verifier rejection triggers rollback
- [ ] Commit failure handling

#### E.6: Regression Tests
- [ ] V2 adapters stay REVIEW-only
- [ ] Scan without mutation works
- [ ] Package mode no action
- [ ] Report schema unchanged (except approved fields)

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
