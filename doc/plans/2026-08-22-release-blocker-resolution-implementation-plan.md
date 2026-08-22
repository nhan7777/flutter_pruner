# Release Blocker Resolution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace unsafe report replacement with immutable committed artifacts,
make JSON v3 context identity symmetric, finish the blocked O3/O4 oracle gates,
and bind release resolution to executable evidence.

**Architecture:** Report persistence is an append-only object and commit store
backed by a same-handle exclusive native capability. Context identities are
validated at production construction, aggregate, and formatter boundaries while
the benchmark oracle stays independently implemented. O3/O4 are re-baselined
into bounded acceptance gates before any natural-project accuracy claim.

**Tech Stack:** Dart 3.9-compatible `dart:ffi`, libc/libSystem/Windows system
APIs, `package:crypto`, `package:test`, JSON v2/v3 formatters, GitHub Actions.

**Spec:** `doc/plans/2026-08-22-release-blocker-resolution-design.md`

## Global Constraints

- Preserve the Dart SDK floor `^3.9.0`; canonical formatting and analysis use
  Dart 3.13.0.
- Preserve JSON v2 bytes exactly.
- Preserve full `BuildTarget` and auxiliary target tuples; identity keys are
  not substitutes for environment facts.
- Never add rename, replace, delete, restore, or advisory-lock authority to the
  native persistence interface.
- Unsupported platform/filesystem/path semantics fail closed.
- Quarantine `manifest.json` remains rollback authority.
- Keep every release blocker active until its exact executable evidence passes.
- Preserve unrelated worktree changes and keep the Git index empty.
- Do not commit, push, tag, release, or publish without separate authorization.

---

### Task 1: Split blockers and make resolution evidence-bound

**Files:**
- Modify: `tool/release_blockers.json`
- Modify: `tool/verify_release_blockers.dart`
- Modify: `test/core/release_blocker_gate_test.dart`
- Modify: `.github/workflows/ci.yml`

**Interfaces:**
- Produces registry schema version 2 with `requiredTests`, `requiredPlatforms`,
  and `requiredArtifacts` for resolved entries.
- Produces verifier modes `--manifest-only` and `--run-tests`.

- [ ] **Step 1: Write RED tests for false resolution**

  Add controlled manifests proving that `status: resolved` without exact test
  IDs/platforms/artifacts exits 2, and that O3/O4 remains separately active
  when the JSON identity entry is resolved.

- [ ] **Step 2: Run the focused test and confirm RED**

  Run:

  ```bash
  dart test test/core/release_blocker_gate_test.dart -r expanded
  ```

  Expected: the new schema/evidence assertions fail against schema version 1.

- [ ] **Step 3: Implement schema v2 and split the registry**

  Parse exact lists, reject duplicate blocker/test/platform IDs, require
  repository-relative artifact paths plus lowercase SHA-256, and add the active
  `corrected-oracle-o3-o4-incomplete` entry.

- [ ] **Step 4: Bind CI matrix evidence**

  Each Linux/macOS/Windows test leg runs the blocker test verifier after the
  full suite. A final `release-admission` job depends on every matrix leg and
  package/analyze/smoke jobs. Active blockers deliberately fail only release
  admission, not earlier diagnostic jobs.

- [ ] **Step 5: Verify focused gates**

  Run the focused test, the verifier against the repository, scoped analyze,
  format check for touched Dart files, and `git diff --check`. The repository
  verifier must still exit 1 and name all active blockers.

- [ ] **Step 6: Review checkpoint**

  Inspect the exact diff and index. Do not commit without separate authority.

### Task 2: Close production context identity asymmetry (C0)

**Files:**
- Create: `lib/src/core/graph/execution_context_identity.dart`
- Modify: `lib/src/core/graph/execution_target.dart`
- Modify: `lib/src/core/project/target_matrix.dart`
- Modify: `lib/src/cli/formatters/json_formatter.dart`
- Modify: `test/core/build_condition_test.dart`
- Modify: `test/core/target_matrix_test.dart`
- Modify: `test/cli/formatters/json_formatter_test.dart`
- Modify: `test/benchmark/accuracy/scanner_report_test.dart`

**Interfaces:**

```dart
String configuredExecutionContextId(String rawTargetName);
void validateAuxiliaryExecutionContextId(
  String id,
  AuxiliaryExecutionDomain domain,
);
String executionContextDomain(String id, {bool allowUnattributed = false});
```

- [ ] **Step 1: Write RED constructor and collision tests**

  Reject empty/control configured names, empty/control/nested auxiliary suffixes,
  `web` plus `app:web`, and two different full tuples with one derived ID.
  Preserve literal valid path/hash/colon auxiliary IDs.

- [ ] **Step 2: Confirm RED**

  Run the three focused production test files and confirm each new assertion
  fails because the current constructor/matrix accepts the invalid input.

- [ ] **Step 3: Implement the private production grammar**

  Keep public signatures and stored raw `BuildTarget.name` unchanged. Validate
  snapshots at intake and use the helper for graph/report keys.

- [ ] **Step 4: Add JSON v3 whole-context preflight RED/GREEN cycle**

  A malformed or duplicate coverage context must throw before a tracking sink
  receives its first token. The valid writer output must parse with the
  independent oracle and match configured, auxiliary, and unattributed sets.

- [ ] **Step 5: Freeze JSON v2**

  Run the retained v2 fixture test and compare its SHA-256 before/after.

- [ ] **Step 6: Verify C0**

  Run all context, formatter, reporting, and accuracy tests, scoped analyze,
  touched-file format, and diff checks. Keep O3/O4 blocker active.

### Task 3: Define immutable commit values and validation

**Files:**
- Create: `lib/src/reporting/report_commit.dart`
- Create: `lib/src/reporting/report_commit_validator.dart`
- Create: `test/reporting/report_commit_test.dart`

**Interfaces:**

```dart
final class ReportObjectRecord {
  const ReportObjectRecord({
    required this.role,
    required this.relativePath,
    required this.format,
    required this.reportSchemaVersion,
    required this.byteLength,
    required this.sha256,
  });
}

final class ReportCommit {
  String canonicalPayload();
  String encode();
  static ReportCommit parse(String source);
}
```

- [ ] **Step 1: Write RED value/parser tests**

  Use literal canonical JSON and digests. Reject partial JSON, extra/missing
  keys, invalid run/sequence, duplicate roles/paths, escaping paths, non-hex
  hashes, incorrect payload digest, and non-committed state.

- [ ] **Step 2: Confirm RED**

  Run `dart test test/reporting/report_commit_test.dart -r expanded`; expected
  compile failure because the production types do not exist.

- [ ] **Step 3: Implement minimal immutable values**

  Deep-freeze object lists, encode keys deterministically, compute the payload
  digest with `package:crypto`, and parse exact JSON shapes.

- [ ] **Step 4: Verify GREEN and mutation cases**

  Run the focused file and mentally mutate every validation branch; add only
  missing behavior tests.

### Task 4: Add capability-only report backend

**Files:**
- Create: `lib/src/reporting/report_object_backend.dart`
- Create: `lib/src/reporting/io_report_object_backend.dart`
- Create: `test/reporting/report_object_backend_test.dart`

**Interfaces:**

```dart
abstract interface class ReportObjectBackend {
  Future<AnchoredReportDirectory> anchor(Directory directory);
}

abstract interface class AnchoredReportDirectory {
  Future<ExclusiveReportObject> createExclusive(String leaf);
  Future<ExistingReportObject> openExisting(String leaf);
  Future<void> verifyReachable();
  Future<void> close();
}
```

- [ ] **Step 1: Write RED contract tests using a capability fake**

  Prove leaf validation, same-handle write/read/identity, short-write retry,
  first-error precedence, no mutation methods, and fail-closed unsupported
  capability results.

- [ ] **Step 2: Confirm RED**

  Run the focused test and observe missing interfaces/behavior.

- [ ] **Step 3: Implement the platform-neutral contract**

  Keep the fake in test support. Production dispatch recognizes only Linux,
  macOS, and Windows; other platforms throw a sanitized unsupported exception.

- [ ] **Step 4: Verify GREEN**

  Run the contract test and scoped analysis.

### Task 5: Implement POSIX direct-FFI backend

**Files:**
- Create: `lib/src/reporting/native/posix_report_object_backend.dart`
- Create: `lib/src/reporting/native/posix_bindings.dart`
- Create: `test/reporting/posix_report_object_backend_test.dart`

**Interfaces:**
- Implements Task 4 with `openat`, `read`, `write`, `lseek`, `fstat`, `fsync`,
  and `close` only.

- [ ] **Step 1: Write real-filesystem RED tests**

  Use child processes and deterministic barriers for existing regular/empty
  files, final symlinks, parent rename/swap, collision, short/interrupted
  writes, and object identity. Assert foreign bytes/hash/type/mode/path remain
  exact and no reopen-by-path occurs.

- [ ] **Step 2: Confirm RED against pure `dart:io` behavior**

  The retained lock/temp race tests must still demonstrate the original defect;
  the new backend tests fail because the POSIX implementation is absent.

- [ ] **Step 3: Implement direct bindings**

  Resolve libc/libSystem, use platform-correct constants, retry `EINTR`, handle
  short reads/writes, sanitize errno categories, and retain parent/object FDs.
  Do not expose `unlinkat` or rename bindings.

- [ ] **Step 4: Verify APFS locally**

  Run the focused backend/process tests on macOS, scoped analysis, and install
  smoke with Dart 3.9 plus canonical Dart 3.13 where available.

### Task 6: Implement Windows direct-FFI backend

**Files:**
- Create: `lib/src/reporting/native/windows_report_object_backend.dart`
- Create: `lib/src/reporting/native/windows_bindings.dart`
- Create: `test/reporting/windows_report_object_backend_test.dart`

**Interfaces:**
- Implements Task 4 with retained directory/file handles, `CREATE_NEW`, no
  reparse following, restrictive sharing, `WriteFile`, `ReadFile`,
  `FlushFileBuffers`, and stable file-ID queries.

- [ ] **Step 1: Write platform-gated RED process tests**

  Cover final reparse insertion, parent swap/rename denial, foreign collisions,
  short/error paths, and exact file-ID retention. On non-Windows the tests
  validate only static dispatch and do not report a skipped release gate.

- [ ] **Step 2: Implement bindings and backend**

  Use system DLLs directly, close every retained handle, map NT/Win32 errors to
  stable categories, and fail preflight outside proven NTFS semantics.

- [ ] **Step 3: Run hosted Windows evidence when push is authorized**

  The blocker remains active until the exact test IDs pass on the supported
  Windows matrix. Local non-Windows compilation is not acceptance evidence.

### Task 7: Build immutable object writer and commit store

**Files:**
- Create: `lib/src/reporting/immutable_report_store.dart`
- Create: `lib/src/reporting/report_recovery_inspector.dart`
- Create: `test/reporting/immutable_report_store_test.dart`
- Create: `test/reporting/report_recovery_inspector_test.dart`

**Interfaces:**

```dart
final class ImmutableReportStore {
  Future<CommittedReport> writeBatch({
    required ReportCommitIdentity identity,
    required List<ReportObjectWrite> objects,
  });
}
```

- [ ] **Step 1: Write RED object/commit lifecycle tests**

  Cover partial object, complete orphan, partial/corrupt commit, hash mismatch,
  foreign object/commit collision, multi-object batch failure, valid commit,
  and READY eligibility.

- [ ] **Step 2: Confirm RED**

  Run the two focused tests; expected missing implementation failures.

- [ ] **Step 3: Implement object streaming and read-back**

  Feed formatter tokens into UTF-8 bytes, hash/count exact bytes, flush and
  reread the retained handle, then write and reparse the commit record.

- [ ] **Step 4: Implement read-only recovery classification**

  No branch may rename or delete. Return immutable classifications and
  sanitized artifact paths only.

- [ ] **Step 5: Verify GREEN**

  Run focused store/backend/reporting tests and scoped analysis.

### Task 8: Migrate scan report persistence

**Files:**
- Modify: `lib/src/reporting/report_output_identity.dart`
- Modify: `lib/src/cli/commands/scan_command.dart`
- Modify: `lib/src/core/project/tool_workspace.dart`
- Modify: `test/cli/scan_command_test.dart`
- Modify: `test/cli/report_persistence_race_child.dart`

**Interfaces:**
- `FrozenReportOutputIdentity` owns an anchored capability and explicit
  single-assignment policy.
- Scan receives `CommittedReport.actualObjectPath` for terminal output.

- [ ] **Step 1: Convert the four retained skip cases to RED normal tests**

  Update expectations to immutable object/commit behavior, exact foreign
  retention, exit 1 on collision, recovery-required diagnostics, and no READY.

- [ ] **Step 2: Confirm RED**

  Run writer and real scan child tests without `--run-skipped`; confirm the old
  writer fails the hostile assertions.

- [ ] **Step 3: Route scan through `ImmutableReportStore`**

  Preflight before analysis, remove stable overwrite behavior, emit READY only
  after commit validation, and keep v2/v3 formatter failure identity.

- [ ] **Step 4: Remove the old recoverable rename transaction**

  Retain compatible sanitized exception categories only where CLI behavior
  consumes them. No old lock/previous/temp cleanup code remains reachable.

- [ ] **Step 5: Verify scan**

  Run reporting plus scan command tests, real child-process barriers, JSON v2
  bytes, scoped analyze, and format/diff checks.

### Task 9: Migrate apply canonical and external reports

**Files:**
- Modify: `lib/src/cli/commands/apply_command.dart`
- Modify: `test/cli/apply_command_test.dart`
- Modify: `test/fixtures/canonical_report_failure_verifier.dart`

**Interfaces:**
- Every material state gets a monotonic immutable report sequence.
- Canonical and external outputs for one state use one batch commit.

- [ ] **Step 1: Write RED apply batch/sequence tests**

  Prove no canonical overwrite, immutable later failure reports, all-or-none
  external/canonical authority, no READY for incomplete batches, and unchanged
  quarantine rollback authority.

- [ ] **Step 2: Confirm RED**

  Run the focused apply cases and observe the current `_writeReportFile`
  replacing behavior.

- [ ] **Step 3: Replace `_writeReportFile`**

  Route every call through the shared immutable store, remove temp/previous/
  rename/delete logic, and preserve truthful terminal fallback behavior.

- [ ] **Step 4: Verify apply safety**

  Run apply command, quarantine, rollback, operation-lock, and mutation-safety
  suites plus scoped analysis.

### Task 10: Close O3 remediation gates

**Files:**
- Modify: `benchmark/accuracy/src/scanner_report.dart`
- Modify: `benchmark/accuracy/src/scanner_graph_observation.dart`
- Modify: `test/benchmark/accuracy/scanner_report_test.dart`
- Modify: `test/benchmark/accuracy/scanner_graph_observation_test.dart`

**Interfaces:**
- O3-R1 requires exact asset/duplicate finding state and bounded inventories.
- O3-R2 requires canonical project-relative POSIX paths for every path-bearing
  field and exact graph membership.

- [ ] **Step 1: RED asset/duplicate state tests**

  Reject unknown/not-applicable measured states and forged inventories larger
  than independently frozen counts.

- [ ] **Step 2: GREEN O3-R1**

  Implement exact domain/state/count admission and run all scanner-report
  tests.

- [ ] **Step 3: RED canonical path tests**

  Reject absolute, backslash, empty segment, dot/dot-dot, repeated separator,
  non-normalized, control, and escaping paths in every report/observation field.

- [ ] **Step 4: GREEN O3-R2**

  Centralize oracle-local path validation without importing production code,
  then run all accuracy tests and fresh independent review.

### Task 11: Close O4 remediation gates

**Files:**
- Modify: `benchmark/accuracy/src/root_universe.dart`
- Modify: `test/benchmark/accuracy/root_universe_test.dart`
- Modify: `test/fixtures/benchmark_accuracy_oracle/`

**Interfaces:**
- O4-R1 owns sibling-package boundaries/callbacks, public owner validity, and
  symlink evidence.
- O4-R2 owns closure-strength joins, constant pragma/full executable identity,
  and ordered repeated show/hide semantics.

- [x] **Step 1: Build real sibling/symlink RED fixtures**

  Reconstruct from Git-index contents; prove sibling callbacks/back-edges are
  not dropped and invalid owners fail closed.

- [x] **Step 2: GREEN O4-R1**

  Preserve canonical owner package/path identity across package boundaries and
  classify unresolved ownership as an issue.

- [x] **Step 3: Build semantic RED fixtures**

  Cover constant-evaluated pragmas, full executable identity, retained-first
  then exact traversal, cycles, and repeated ordered show/hide combinators.

- [x] **Step 4: GREEN O4-R2**

  Use an explicit closure-strength lattice and analyzer constant evaluation;
  bump root/callback policy versions and regenerate the root manifest.

- [ ] **Step 5: Verify O4 independently**

  Run reconstructed fixture tests, all accuracy tests, scoped analysis, and a
  fresh independent safety review. Do not start O5/O6 before acceptance.

  Local verification on 2026-08-22 passed 121 accuracy tests, the complete
  1,233-test suite with three declared platform/legacy skips, Dart 3.13 full
  analysis, and Dart 3.9.2 scoped analysis/root tests. Independent safety
  review remains required before this step can be accepted.

### Task 12: Refresh natural evidence and release admission

**Files:**
- Modify: `benchmark/baselines/` only with sanitized accepted aggregates
- Modify: `doc/performance/v2-natural-accuracy.md`
- Modify: `doc/release-readiness.md`
- Modify: `CHANGELOG.md`
- Modify: `tool/release_blockers.json`

**Interfaces:**
- Produces exact-SHA AppFlowy/ServerBox captures and accepted O7 artifacts.

- [ ] **Step 1: Run controlled fixture acceptance**

  Require zero diagnostics/dangling facts, exact context memberships, exhaustive
  denominator, and no unclassified case before real-project capture.

- [ ] **Step 2: Recapture AppFlowy and ServerBox read-only**

  Use detached pinned SHAs, exact toolchain/config/package-config identities,
  process-tree metrics, raw report hashes, restoration evidence, and independent
  truth. Do not apply.

- [ ] **Step 3: Run O7 one-to-one grading**

  Only O7 may emit the accepted confusion matrix. Preserve uncertainty counts
  and distinguish scanner observations from independent labels.

- [ ] **Step 4: Resolve blockers only with evidence**

  Add exact test/platform/artifact data to registry entries, run the verifier,
  and retain any entry whose full matrix is not available.

- [ ] **Step 5: Run final repository gates**

  Run focused suites, canonical Dart 3.13 analyze, full serial suite, Dart 3.9
  and stable install smoke, package dry-run, self-scan SAFE/HIGH gate, and
  three-project safety replay. Hosted matrix evidence requires separate push
  authorization.

- [ ] **Step 6: Review checkpoint**

  Report exact retained SHA, active blockers, test counts, skipped tests,
  package contents, and remaining external authorization. Do not commit, push,
  tag, release, or publish without separate instructions.
