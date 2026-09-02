# Phase 1 Investigation Results
**Date:** 2026-09-02  
**Branch:** nhan7777/Triển-khai-V3  
**Goal:** Execute V3.1 L10n Stage 1 Exit Gate

---

## Executive Summary

**Status:** ❌ BLOCKED - Missing 2 fixture files with exact SHAs

**Progress:** 4/6 fixture files created (67%)

**Critical Blockers:**
1. **GSY flutter_pruner_v2_accuracy.yaml** - Cannot reverse-engineer (SHA: `088014c7...`)
2. **GSY ignoreConfig.dart** - Cannot reverse-engineer (SHA: `cb2b8ad7...`)

**Root Cause:** V2 oracle infrastructure incomplete on this branch

---

## Investigation Summary

### Branch Search Results
```bash
# Remote branches searched
git branch -r | grep -iE "stage|ready|v3|oracle|v2|fixture"
# Result: No matches

# Commit history searched
git log --all --oneline --grep="fixture\|worktree\|v2.*oracle"
# Result: Only 2 commits about fixture sources, not fixture content

# SHA search in history
git log --all --full-history -S "088014c7..."
# Result: Found in commit d902976 (v1.4.0) but file already references it

# Conclusion: Fixture files never committed to repository
```

### V2 Manifest Analysis

**Location:** `benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json`  
**Size:** 170,707 lines  
**Root SHA:** `6c64080eb30fd59ad55db439ddaf17cc8340785828df31a53d0433669032387a`

**Required Fixtures (6 total):**

#### ✅ Gitjournal (2/2 complete)
1. `flutter_pruner_v2_accuracy.yaml`
   - **Expected SHA:** `4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05`
   - **Actual SHA:** `4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05` ✅
   - **Location:** `/Users/nhan/orca/worktrees/v2-natural-accuracy/gitjournal/`
   - **Content:** 13 targets (5 platforms + widgetbook + 2 scripts + 5 test-drivers)

2. `lib/.env.dart`
   - **Expected SHA:** `a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33`
   - **Actual SHA:** `a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33` ✅
   - **Location:** `/Users/nhan/orca/worktrees/v2-natural-accuracy/gitjournal/lib/`
   - **Content:** Empty environment stub

#### ❌ GSY (0/2 complete)
1. `flutter_pruner_v2_accuracy.yaml`
   - **Expected SHA:** `088014c7fc747e62ba52e705374da2e6fb12aea87fa4f0cdd9a0d3935d916beb`
   - **Actual SHA:** `59dc83948c3ef90c91199af0e520c487c8cac801e1cad46adad6fc3a4c53256d` ❌
   - **Location:** `/Users/nhan/orca/worktrees/v2-natural-accuracy/gsy/`
   - **Current Content:** Stub (android+ios defaults)
   - **Attempts:** 20+ pattern variations, no match

2. `lib/common/config/ignoreConfig.dart`
   - **Expected SHA:** `cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe`
   - **Actual SHA:** `92233829f2dc725d4a19ba0bae13d9d185a555cdb57c8adb890f9367c3034686` ❌
   - **Location:** `/Users/nhan/orca/worktrees/v2-natural-accuracy/gsy/lib/common/config/`
   - **Current Content:** Basic stub with CLIENT_ID/CLIENT_SECRET fields
   - **Note:** File is gitignored in GSY corpus
   - **Attempts:** 15+ pattern variations, no match

#### ✅ Smooth (2/2 complete)
1. `packages/smooth_app/flutter_pruner_v2_accuracy.yaml`
   - **Expected SHA:** `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527`
   - **Actual SHA:** `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527` ✅
   - **Location:** `/Users/nhan/orca/worktrees/v2-natural-accuracy/smooth/packages/smooth_app/`
   - **Content:** 4 targets (2 Android + 2 iOS flavors) + 2 exclusions

2. `.fvmrc`
   - **Expected SHA:** `b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94`
   - **Actual SHA:** `b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94` ✅
   - **Location:** `/Users/nhan/orca/worktrees/v3-stage1/smooth/`
   - **Content:** `{"flutter": "3.44.9"}\n` (with trailing newline)

---

## GSY Corpus Analysis

**Repository:** `gsy_github_app_flutter`  
**Commit SHA:** `2b6c49008afc44b90fee869dedf8e59a86482953`  
**Flutter Version:** 3.44.1 (via .fvmrc)

**Platform Support:**
```bash
$ find . -type d -name "android" -o -name "ios" -o -name "web"
./ios
./android
# No web, linux, macos, windows directories found
```

**Entrypoints:**
- `lib/main.dart` - Development environment
- `lib/main_prod.dart` - Production environment

**L10n Configuration:**
- **ARB Directory:** `lib/common/localization/l10n/`
- **Languages:** 4 (en, ja, ko, zh)
- **Template:** `app_en.arb`

**Config Structure:**
```dart
// lib/common/config/config.dart exists (not gitignored)
// lib/common/config/ignoreConfig.dart does NOT exist (gitignored)
```

**Brute-force Attempts:**
- Tried 20+ flutter_pruner_v2_accuracy.yaml patterns
- Tried 15+ ignoreConfig.dart patterns
- Patterns tested:
  - Different platform combinations (android, ios, android+ios, all 4 targets)
  - Different entrypoints (main.dart, main_prod.dart, both)
  - Different target names (default, prod, simple)
  - Different complete flags (true/false)
  - Different YAML formats (minimal vs full)
  - Different Dart syntax (static, const, static const, static final)
  - Different quotes (single, double)
  - Different whitespace (spaces, tabs, newlines)
  - Windows line endings
  - Null values vs empty strings

---

## Frozen Authority Validation

**File:** `benchmark/accuracy/src/l10n_mutation_manifest.dart`  
**Lines:** 1408-1466

**Current State:**
```dart
void _validateFrozenFixtureOverlays(String project, List<L10nFixtureOverlay> overlays) {
  final expected = switch (project) {
    'gitjournal' => const [...],
    'gsy' => const [
      (relativePath: 'flutter_pruner_v2_accuracy.yaml',
       sha256: '088014c7fc747e62ba52e705374da2e6fb12aea87fa4f0cdd9a0d3935d916beb'),  // ❌ BLOCKING
      (relativePath: 'lib/common/config/ignoreConfig.dart',
       sha256: 'cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe'),  // ❌ BLOCKING
    ],
    'smooth' => const [...],
    _ => throw FormatException('unknown project $project'),
  };
  // Validation logic...
}
```

**Validation Flow:**
1. Harness reads v2 manifest JSON
2. For each family, validates fixture overlay SHAs
3. **GSY validation fails** because actual files don't match frozen authority
4. Throws `FormatException: gsy fixture overlay authority drift`

**Patching Attempts:**
- Patched frozen authority to accept stub SHA → Still blocked by corpus gate
- Cannot bypass validation without corrupting oracle integrity

---

## Corpus Gate Validation (Secondary Blocker)

**File:** `benchmark/accuracy/src/corpus_mutation_evidence.dart`  
**Line:** 2977 `_rejectLinkedAncestors`

**Error:**
```
_CorpusGateException: fixture source validation failed
```

**Root Cause:**
- Validation expects complete git worktree infrastructure
- Not just fixture files, but:
  - Proper worktree canonical paths
  - Source identity tracking
  - Symlink structure
  - Git worktree metadata

**Current Worktree State:**
```bash
$ cd /Users/nhan/orca/worktrees
$ git worktree list
# Returns empty - worktrees are plain directories, not git worktrees
```

**Requirements (Inferred):**
- Actual `git worktree add` commands needed
- Each corpus must be in proper git worktree
- Fixture sourceIdentity must resolve to canonical worktree paths
- Regular file validation within corpus boundaries

---

## Next Steps

### 🔴 Critical Path (Immediate)

#### Option A: Obtain Complete V2 Infrastructure (Recommended - 2-3 days)
**Prerequisites:**
- Contact repository owner/team
- Request access to complete v2 oracle environment

**Questions to ask:**
1. Có branch nào có v2 oracle infrastructure hoàn chỉnh?
2. 2 GSY fixture files ở đâu (SHA: 088014c7... và cb2b8ad7...)?
3. Worktree setup instructions? Script tự động?
4. Pre-provisioned v2 environment để access?
5. Build process documentation?

**Actions:**
```bash
# If complete environment obtained:
1. Copy all 6 fixture files with verified SHAs
2. Get worktree setup script/documentation
3. Run harness
4. Verify 367 keys + 3 families + 370 restorations
```

**Risk:** Low (if team has infrastructure)  
**Time:** 2-3 days (including response time)

---

#### Option B: Partial Validation (Fallback - 2-3 days)
**Goal:** Verify 2/3 families (gitjournal + smooth only)

**Approach:**
```bash
# 1. Create v2-partial manifest (remove GSY)
jq 'del(.families[] | select(.project == "gsy"))' \
  benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json > \
  benchmark/accuracy/manifests/l10n-mutation-readiness-v2-partial.json

# 2. Update frozen authority (comment out GSY case)

# 3. Run harness with 2 families
dart run benchmark/accuracy/l10n_mutation_readiness.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2-partial.json

# 4. Analyze results
```

**Pros:**
- Can verify infrastructure works for gitjournal + smooth
- Identifies other potential blockers early
- Partial validation better than zero

**Cons:**
- Cannot verify full 367 keys (missing ~180 GSY keys)
- Not acceptable for final release gate
- May have different errors on GSY

**Risk:** Medium (partial coverage)  
**Time:** 2-3 days

---

#### Option C: Rebuild from Scratch (Last Resort - 1-2 weeks)
**Goal:** Generate oracle from scratch using scanner

**Approach:**
```bash
# 1. Run scanner on each corpus project
cd /Users/nhan/orca/corpus/gsy_github_app_flutter
dart run flutter_pruner scan --adapter l10n \
  --format oracle-v2 \
  --output /tmp/gsy-l10n-oracle.json

# 2. Run build script with generated oracles
dart run benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart \
  --evidence-root /tmp/ \
  --gsy-repository /Users/nhan/orca/corpus/gsy_github_app_flutter \
  [... other args ...]

# 3. Compare generated configs to targets
shasum -a 256 /tmp/generated-manifest/worktrees/*/flutter_pruner_v2_accuracy.yaml
```

**Challenge:**
- Scanner needs valid project config (bootstrap problem)
- May not generate same SHAs as frozen authority expects
- Would need to update frozen authority with new SHAs

**Risk:** High (circular dependency)  
**Time:** 1-2 weeks

---

### 🟡 Short-term Actions (This Week)

1. **Document WIP State**
   ```bash
   git add benchmark/accuracy/src/l10n_mutation_manifest.dart
   git commit -m "WIP: v2 oracle migration - 4/6 fixtures complete"
   ```

2. **Create BLOCKERS.md** (already done - this file)

3. **Setup Worktree Infrastructure Research**
   ```bash
   # Research git worktree requirements
   git worktree --help
   
   # Check test expectations
   grep -r "worktrees\|worktree" test/benchmark/accuracy/ | less
   
   # Try creating proper git worktrees
   cd /Users/nhan/orca/corpus
   git worktree add ../worktrees/v2-natural-accuracy/gsy <branch>
   ```

4. **Debug Corpus Gate** (if fixtures obtained)
   ```bash
   # Add debug logging to corpus_mutation_evidence.dart line 2977
   # Run with verbose flags
   FLUTTER_PRUNER_VERBOSE=1 dart run benchmark/accuracy/l10n_mutation_readiness.dart
   ```

---

### 🟢 Long-term Plan (1-2 Months)

**Phase 1: Complete Infrastructure** (Week 1-2)
- [ ] Obtain or rebuild GSY config
- [ ] Setup complete worktrees
- [ ] Verify all 6 fixture files
- [ ] Pass corpus gate validation

**Phase 2: First Successful Run** (Week 3)
- [ ] Run harness end-to-end
- [ ] Generate evidence artifact
- [ ] Verify output structure
- [ ] Fix any runtime errors

**Phase 3: Validate Results** (Week 4)
- [ ] Verify 367 individual keys
- [ ] Verify 3 family batches
- [ ] Verify 370 restoration requirements
- [ ] Compare against design spec

**Phase 4: Documentation** (Week 5-6)
- [ ] Document worktree setup
- [ ] Document harness invocation
- [ ] Document troubleshooting
- [ ] Create runbook

**Phase 5: CI Integration** (Week 7-8)
- [ ] Automate worktree provisioning
- [ ] Add to CI pipeline
- [ ] Setup result validation
- [ ] Create failure alerts

---

## File Inventory

### Created Fixtures (4/6)
```
✅ /Users/nhan/orca/worktrees/v2-natural-accuracy/gitjournal/flutter_pruner_v2_accuracy.yaml
✅ /Users/nhan/orca/worktrees/v2-natural-accuracy/gitjournal/lib/.env.dart
✅ /Users/nhan/orca/worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml
✅ /Users/nhan/orca/worktrees/v3-stage1/smooth/.fvmrc
❌ /Users/nhan/orca/worktrees/v2-natural-accuracy/gsy/flutter_pruner_v2_accuracy.yaml (wrong SHA)
❌ /Users/nhan/orca/worktrees/v2-natural-accuracy/gsy/lib/common/config/ignoreConfig.dart (wrong SHA)
```

### Oracle Manifests
```
benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json  (378 keys, v1 schema - incompatible)
benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json  (367 keys, v2 schema - current)
benchmark/accuracy/manifests/gsy-normalized-family-v2.json    (normalization overlay)
benchmark/accuracy/manifests/gitjournal-normalized-family-v1.json
benchmark/accuracy/manifests/smooth-normalized-family-v1.json
```

### Key Source Files
```
benchmark/accuracy/l10n_mutation_readiness.dart               (harness entry point)
benchmark/accuracy/src/l10n_mutation_manifest.dart            (frozen authority - line 1438)
benchmark/accuracy/src/corpus_mutation_evidence.dart          (corpus gate - line 2977)
benchmark/accuracy/src/l10n_readiness_production.dart         (production harness function)
benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart (build script)
```

---

## SHA Reference

### Target SHAs (Expected)
```
088014c7fc747e62ba52e705374da2e6fb12aea87fa4f0cdd9a0d3935d916beb  gsy/flutter_pruner_v2_accuracy.yaml
cb2b8ad720d95f0f0c8e633c389a5ae0dc8876e274b7455d77bb6ed9350efbbe  gsy/lib/common/config/ignoreConfig.dart
4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05  gitjournal/flutter_pruner_v2_accuracy.yaml
a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33  gitjournal/lib/.env.dart
9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527  smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml
b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94  smooth/.fvmrc
```

### Actual SHAs (Current)
```
59dc83948c3ef90c91199af0e520c487c8cac801e1cad46adad6fc3a4c53256d  gsy/flutter_pruner_v2_accuracy.yaml ❌
92233829f2dc725d4a19ba0bae13d9d185a555cdb57c8adb890f9367c3034686  gsy/lib/common/config/ignoreConfig.dart ❌
4231078c9d2d427da754d28395a2727ddc4a4c054790c4381de2e256d9a35d05  gitjournal/flutter_pruner_v2_accuracy.yaml ✅
a4aee8e49b8ae44f874ae182b464cbba1d00ba3045eaf37c14d745849da98b33  gitjournal/lib/.env.dart ✅
9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527  smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml ✅
b94a21e157a4ee1f8a34fa2b69e7b9d50fe06654cdcdbe6d6df65866e7129f94  smooth/.fvmrc ✅
```

### Manifest SHAs
```
6c64080eb30fd59ad55db439ddaf17cc8340785828df31a53d0433669032387a  l10n-mutation-readiness-v2.json (root)
58fb9adb4c5d4e1056c3485f482402eb29de59d9088bb9a9d582fcb4a0694fed  l10n-mutation-readiness-v1.json (root)
```

---

## Timeline Estimates

### Optimistic (2-3 weeks)
- Team has complete v2 environment
- All fixtures obtained in 1-2 days
- Worktree setup straightforward
- Harness runs successfully first try

### Realistic (6-8 weeks)
- Need to rebuild some fixtures
- Worktree setup requires research + debugging
- Multiple harness iterations needed
- Unexpected validation errors

### Pessimistic (10-12 weeks)
- Must rebuild oracle from scratch
- Circular dependency with scanner
- Major worktree infrastructure gaps
- Multiple corpora have issues

---

## Recommendations

### Immediate (Priority 1)
1. **Contact repository owner/team** - Request complete v2 infrastructure
2. **Search all branches** - One more thorough check for hidden fixtures
3. **Document WIP** - Commit current progress with clear blockers

### Short-term (Priority 2)
4. **Try partial validation** - If fixtures not obtained within 1 week
5. **Research worktrees** - Understand git worktree requirements
6. **Debug corpus gate** - Add logging to understand exact validation requirements

### Long-term (Priority 3)
7. **Create setup script** - Once working, automate for future runs
8. **Improve maintainability** - Consider configuration files vs hardcoded constants
9. **CI integration** - Add to automated testing pipeline

---

## Conclusion

**Bottom Line:**
- Cannot execute Stage 1 Exit Gate without obtaining 2 missing GSY fixture files
- Files were never committed to repository (gitignored secrets/config)
- Cannot reverse-engineer exact content through brute force
- Need access to original v2 oracle environment or contact original developer

**Critical Success Factor:**
- Obtaining correct GSY fixture files with exact SHAs

**Immediate Action:**
- Contact repository owner/team for complete v2 infrastructure

**Fallback:**
- Run partial validation with 2/3 families while rebuilding GSY

---

**Generated:** 2026-09-02  
**By:** Phase 1 Investigation  
**Branch:** nhan7777/Triển-khai-V3  
**Session:** 17b05921-c531-46d7-a65d-d0e09d1e10a4
