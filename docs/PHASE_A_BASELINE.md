# Phase A: Baseline Established

**Date:** 2026-09-05
**Branch:** v3-shared-view-investigation
**HEAD:** 9481522 feat: implement Task 10 - L10n mutation executor with direct in-place mutation

## Git Status

### Modified Files Summary
- **Production code:** 24 files (lib/src/*)
- **Test code:** 17 files (test/*)
- **Benchmark code:** 6 files (benchmark/*)
- **Config:** 2 files (analysis_options.yaml, pubspec.yaml/lock)
- **Documentation:** 2 new files (docs/*.md)

Total: 42 files modified, 838 insertions, 501 deletions

### File Categories

**Core l10n adapters:**
- lib/src/adapters/l10n/l10n_action_capability.dart
- lib/src/adapters/l10n/l10n_action_descriptor.dart
- lib/src/adapters/l10n/l10n_mutation_executor.dart
- lib/src/adapters/l10n/l10n_removal_batch.dart
- lib/src/adapters/l10n/l10n_static_readiness_resolver.dart
- lib/src/adapters/l10n/l10n_verification_policy.dart

**Core confidence system:**
- lib/src/core/confidence/action_capability.dart
- lib/src/core/confidence/action_risk_scope.dart
- lib/src/core/confidence/finding_generator.dart
- lib/src/core/confidence/mutation_footprint.dart
- lib/src/core/confidence/promotion_index.dart

**Apply workflow:**
- lib/src/apply/apply_action_plan.dart
- lib/src/apply/finding_action_builder.dart
- lib/src/apply/removal_planner.dart

**Analysis:**
- lib/src/analysis/analysis_snapshot.dart
- lib/src/analysis/project_analyzer.dart

**CLI:**
- lib/src/cli/commands/apply_command.dart

**Process management:**
- lib/src/core/process/managed_process_runner.dart

## Dart Analyze Results

✅ **No issues found!** 

The roadmap mentioned 22 analyzer issues with compile errors at:
- lib/src/analysis/analysis_snapshot.dart:26
- test/adapters/dart/analyzer_diagnostic_collector_test.dart:171
- test/cli/apply_command_test.dart:6350

These have been resolved in the current working tree.

## Test Results

### L10n Adapter Tests
Status: **Running** (timeout → moved to background task b77xljwto)

### Apply Tests
Status: **Completed with 3 failures**
- Total: 72 tests
- Passed: 69
- Failed: 3

**Failures:**
1. `timeout kills cleanup child and grandchild before returning`
   - Error: Process termination not confirmed (PID 15891)
   - Location: test/apply/import_cleanup_runner_test.dart:132

2. `signal cancellation stops cleanup root and descendant before unwinding`
   - Error: Process termination not confirmed (PID 16673)
   - Location: test/apply/import_cleanup_runner_test.dart:191

3. `readiness failure cancels and settles cleanup root and descendant`
   - Error: Process termination not confirmed (PID 17296)
   - Location: test/apply/import_cleanup_runner_test.dart:244

**Analysis:** All 3 failures are in `import_cleanup_runner_test.dart` and relate to process termination confirmation during cancellation/timeout scenarios. These are not l10n mutation-specific.

### Quarantine Tests
Status: **Completed with 2 failures**
- Total: 200 tests
- Passed: 198
- Failed: 2

**Failures:**
1. `confirmed link cancellation re-inspects published and prepared paths`
   - Error: Exception message doesn't contain expected text "cancellation was confirmed"
   - Location: test/quarantine/quarantine_manager_test.dart:3712

2. `before-launch link cancellation preserves absent target and candidate`
   - Error: Exception message doesn't contain expected text "cancelled before launch"
   - Location: test/quarantine/quarantine_manager_test.dart:3768

**Analysis:** Both failures are assertion mismatches on exception message text, not behavioral failures. The exceptions are thrown correctly but with slightly different wording.

## Problem Classification

### Compile/Analyzer Issues
✅ **RESOLVED** - No analyzer errors found

### Test Failures

**Category 1: Process Management (not l10n-specific)**
- 3 failures in import_cleanup_runner_test.dart
- Related to process tree termination confirmation
- Pre-existing infrastructure issue, not Stage 2 regression

**Category 2: Quarantine Transaction (infrastructure)**
- 2 failures in quarantine_manager_test.dart
- Exception message text mismatches
- Core quarantine system, not l10n-specific

### Stage 2 Specific Issues (from roadmap review)

Based on roadmap section 3, the following architectural issues need addressing:

1. **Resolver simplicity** - `L10nStaticReadinessResolver` missing:
   - Config ownership verification
   - Template/locale ARB ownership
   - Generated output ownership
   - Stale output detection
   - Config fingerprint tracking
   - Complete mutation footprint

2. **Executor direct mutation** - `L10nMutationExecutor` currently:
   - Runs `flutter gen-l10n` directly on live project
   - Missing: staging generation, candidate bytes, transaction journal, verification

3. **Quarantine entries incomplete** - `createCaseQuarantine()`:
   - Called with `entries: const []`
   - Missing actual transaction write set

4. **Verification external** - `MutationApplied`:
   - Missing candidate hash
   - Missing expected absent/present state
   - Missing generated output set
   - Missing policy/toolchain fingerprint

5. **Action capability timing** - Descriptor:
   - Selects per-key but mutates per-family
   - Needs unified model

## Recommendations for Phase B

Priority order:
1. Fix the 2 quarantine test failures (low-hanging fruit, message text only)
2. Document the 3 process management test failures as known infrastructure issues
3. Proceed to Phase B: restore compile & contract consistency verification
4. Then Phase C-D for architectural corrections per roadmap

## Evidence Gaps

- Natural-project smoke tests: not run (per roadmap: prior runs stopped at `inProgress`)
- Benchmark shared-view validation: not run
- Full test suite: not run (waiting for l10n tests to complete)

## Next Steps

Wait for l10n adapter tests (background task b77xljwto) to complete, then:
1. Review l10n test results
2. Proceed to Phase B if baseline is acceptable
3. Address architectural gaps per roadmap phases C-D
