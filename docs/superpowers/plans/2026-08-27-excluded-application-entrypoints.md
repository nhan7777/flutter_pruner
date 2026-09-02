# Excluded Application Entrypoints Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add explicit fail-closed authority for known non-launchable application `main()` files, truthfully rebind the Smooth scanner-coverage fixture, and rerun Smooth Stage 1 as R5.

**Architecture:** `TargetMatrix` owns immutable reason-bearing exclusions beside supported `BuildTarget` values. Configuration and `ProjectContext` validate the authority, while `DefaultDartExecutionContextService` matches exact analyzer-resolved exclusions without creating targets or roots and blocks stale exclusions. The retained Smooth fixture then declares four real supported targets and two exact exclusions; existing manifest digest gates bind the new bytes before R5.

**Tech Stack:** Dart 3.11.0 via `/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart`, analyzer resolved libraries, YAML project configuration, SHA-256-bound JSON corpus manifests, package:test.

**Spec:** `docs/superpowers/specs/2026-08-27-excluded-application-entrypoints-design.md`

## Global Constraints

- Preserve unrelated dirty worktree changes; do not stash, reset, checkout, stage, format unrelated files, commit, push, open a PR, publish, or release.
- Use `/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart` for every repository Dart command.
- Do not run root Flutter tests.
- Production code must contain no Smooth-specific repository name, path, SHA, guard, stub, or exception.
- Keep the Stage 1 oracle at 367 positives total and Smooth at 312 positives / 1,468 negatives / zero oracle mismatch.
- Do not change `ReachabilityGraph`, blocker projection, `selected-node-retained`, l10n preflight, mutation policy, or restoration policy.
- Do not edit the retained Smooth source checkout at `/Users/nhan/Desktop/flutter_pruner_benchmar_sample/smooth-app`; only its corpus fixture overlay may change.
- Review task diffs by before/after snapshots because commits are forbidden in this worktree.

---

### Task 1: Immutable exclusion authority and strict configuration parsing

**Files:**
- Modify: `lib/src/core/project/target_matrix.dart`
- Modify: `lib/src/core/project/project_config.dart`
- Modify: `lib/src/core/project/project_context.dart`
- Modify: `lib/src/cli/commands/init_command.dart`
- Modify: `doc/flutter_pruner.yaml.md`
- Modify: `test/core/target_matrix_test.dart`
- Modify: `test/core/project_context_test.dart`
- Modify: `test/cli/init_command_test.dart`

**Interfaces:**
- Produces: `ExcludedApplicationEntrypoint({required String path, required String reason})`.
- Produces: `TargetMatrix.excludedEntrypoints` as an unmodifiable list.
- Produces: YAML `target_matrix.excluded_entrypoints` containing exact `{path, reason}` mappings.
- Consumes: existing `ProjectSourcePath.validate`, `ProjectPathPolicy`, `AnalysisMode`, and `TargetMatrixStatus` invariants.

- [ ] **Step 1: Add RED value-model tests**

Add tests to `test/core/target_matrix_test.dart` that construct a declared matrix with a mutable exclusion list, mutate the caller list, and assert the matrix still contains exactly:

```dart
const ExcludedApplicationEntrypoint(
  path: 'lib/guard.dart',
  reason: 'tracked launcher guard is not supported',
)
```

Assert `matrix.excludedEntrypoints.clear()` throws `UnsupportedError`. Add constructor rejection tests for duplicate exclusion paths, whitespace-only reasons, overlap with `BuildTarget.entrypoint`, and exclusions on a non-`declaredComplete` matrix.

- [ ] **Step 2: Add RED configuration tests**

In `test/core/project_context_test.dart`, write `lib/guard.dart` and a complete application config containing:

```yaml
excluded_entrypoints:
  - path: lib/guard.dart
    reason: tracked launcher guard is not supported
```

Assert the loaded target matrix exposes the exact value. Add table-driven rejection cases for:

```text
package mode
package-internal mode
complete: false
duplicate path
path overlapping a configured target
missing path
build/guard.dart
unknown mapping key
empty reason
whitespace-only reason
```

Also prove omission and `excluded_entrypoints: []` retain an empty immutable list, and a direct `ProjectContext` in a non-application mode rejects a matrix containing exclusions.

- [ ] **Step 3: Run Task 1 RED**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/core/target_matrix_test.dart \
  test/core/project_context_test.dart
```

Expected: compilation fails because `ExcludedApplicationEntrypoint` and `TargetMatrix.excludedEntrypoints` do not exist.

- [ ] **Step 4: Implement the immutable value and matrix invariants**

In `target_matrix.dart`, add:

```dart
final class ExcludedApplicationEntrypoint {
  const ExcludedApplicationEntrypoint({
    required this.path,
    required this.reason,
  });

  final String path;
  final String reason;

  @override
  bool operator ==(Object other) =>
      other is ExcludedApplicationEntrypoint &&
      other.path == path &&
      other.reason == reason;

  @override
  int get hashCode => Object.hash(path, reason);
}
```

Extend `TargetMatrix` with optional `List<ExcludedApplicationEntrypoint> excludedEntrypoints = const []`, snapshot it with `List.unmodifiable`, and expose the final list. Before constructing the snapshot, throw `ArgumentError` when:

```dart
excludedEntrypoints.any((entry) => entry.reason.trim().isEmpty)
excluded paths are duplicated
excluded paths overlap targets.map((target) => target.entrypoint)
excludedEntrypoints.isNotEmpty &&
    status != TargetMatrixStatus.declaredComplete
```

Extend `TargetMatrix.declared` with the same optional named list.

- [ ] **Step 5: Parse and validate YAML authority**

In `ProjectConfig.load`, admit only `excluded_entrypoints` as the new `target_matrix` key. Parse `null` as an empty list; otherwise require a list of mappings with exactly `path` and `reason`. Validate each path through `_validateProjectFile` using `ProjectSourceKind.applicationEntrypoint` and `allowGenerated: false`. Reject non-empty exclusions unless mode is `AnalysisMode.application` and `completeValue` is true. Reject duplicates and target overlap with stable `ProjectConfigException` messages, then pass the list into `TargetMatrix`.

In the `ProjectContext` constructor body, reject a non-application context whose target matrix contains exclusions. Revalidate direct-API exclusion paths against the effective `pathPolicy`, require the canonical validated result to equal the stored path, and translate invalid values to `ArgumentError`; this prevents direct API callers from bypassing YAML path safety.

- [ ] **Step 6: Document and generate the optional authority**

Add an application-only `excluded_entrypoints: []` block plus a concise comment
to the config rendered by `init`. The generator must not infer exclusions or
populate owner reasons. Update `test/cli/init_command_test.dart` to assert the
empty block is present for application output and absent for package modes.

Extend `doc/flutter_pruner.yaml.md` with the exact mapping shape, application +
complete-only rule, parser rejection rules, analyzer drift blocker, and the
distinction between an exclusion and a supported target. Do not include Smooth
paths in public documentation.

- [ ] **Step 7: Run Task 1 GREEN**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/core/target_matrix_test.dart \
  test/core/project_context_test.dart \
  test/cli/init_command_test.dart
```

Expected: all tests pass.

- [ ] **Step 8: Review checkpoint without commit**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart analyze \
  lib/src/core/project/target_matrix.dart \
  lib/src/core/project/project_config.dart \
  lib/src/core/project/project_context.dart \
  lib/src/cli/commands/init_command.dart \
  test/core/target_matrix_test.dart \
  test/core/project_context_test.dart \
  test/cli/init_command_test.dart
git diff --check -- \
  lib/src/core/project/target_matrix.dart \
  lib/src/core/project/project_config.dart \
  lib/src/core/project/project_context.dart \
  lib/src/cli/commands/init_command.dart \
  doc/flutter_pruner.yaml.md \
  test/core/target_matrix_test.dart \
  test/core/project_context_test.dart \
  test/cli/init_command_test.dart
```

Expected: no analyzer issue and no whitespace error. Confirm no filename, comment, throw-expression, or repository heuristic was added.

---

### Task 2: Analyzer-resolved exclusion matching

**Files:**
- Modify: `lib/src/adapters/dart/dart_execution_context_service.dart`
- Modify: `test/adapters/dart/dart_execution_context_service_test.dart`
- Modify: `test/adapters/dart_execution_reachability_service_test.dart`

**Interfaces:**
- Consumes: `ProjectContext.targetMatrix.excludedEntrypoints` from Task 1.
- Produces: exact classified-but-not-rooted matching for excluded `main()` libraries.
- Produces: global issue code `excluded-dart-entrypoint-unresolved` when any declared exclusion does not resolve to a project-owned non-generated analyzer entry point.
- Preserves: existing `unclassified-dart-entrypoint` for every other selected unconfigured `main()`.

- [ ] **Step 1: Add RED context-service regressions**

Extend the existing execution-root fixture tests with a complete application matrix whose configured target is `lib/main.dart` and whose exclusion is:

```dart
const ExcludedApplicationEntrypoint(
  path: 'scripts/guard.dart',
  reason: 'tracked guard is not launchable',
)
```

For `scripts/guard.dart` containing `void main() {}`, assert:

```dart
snapshot.roots.map((root) => root.nodeId)
// contains neither the library nor #main IDs for scripts/guard.dart

snapshot.auxiliaryExecutionTargets
// contains no target sourced from scripts/guard.dart

snapshot.issues
// contains neither unclassified-dart-entrypoint nor
// excluded-dart-entrypoint-unresolved
```

Add controls proving:

- an excluded file without `main()` produces one global `excluded-dart-entrypoint-unresolved` issue;
- an analyzer-excluded configured exclusion produces the same global issue;
- a generated excluded main cannot enter through direct API path validation;
- a second unlisted `scripts/unknown.dart` still produces global `unclassified-dart-entrypoint`;
- the exclusion reason never becomes a target or root reason.

- [ ] **Step 2: Add RED reachability regression**

In `test/adapters/dart_execution_reachability_service_test.dart`, build a configured app target importing an excluded guard library and an ordinary live library. Assert the guard's declaration is not a root, ordinary imports remain reachable from the configured target, graph integrity is complete, and no source-less exclusion blocker is emitted. Add a stale-exclusion control and assert its global issue is projected as a source-less blocker.

- [ ] **Step 3: Run Task 2 RED**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/adapters/dart/dart_execution_context_service_test.dart \
  test/adapters/dart_execution_reachability_service_test.dart
```

Expected: the valid exclusion still emits `unclassified-dart-entrypoint`, and the stale-exclusion assertion has no matching issue.

- [ ] **Step 4: Implement exact pass-shared matching**

At the start of `DefaultDartExecutionContextService._build`, derive canonical absolute paths from `project.targetMatrix.excludedEntrypoints`:

```dart
final excludedEntrypointPaths = <String>{
  for (final exclusion in project.targetMatrix.excludedEntrypoints)
    p.normalize(p.absolute(project.resolve(exclusion.path))),
};
final matchedExcludedEntrypoints = <String>{};
```

In the existing non-test `entryPoint != null` branch, after configured-target rooting and before adding a path to `potentialUnclassifiedEntrypoints`, match only when all are true:

```dart
configuredTargets.isEmpty
!generatedPath
excludedEntrypointPaths.contains(canonicalLibraryPath)
DartIds.isModeledProjectLibrary(
  project,
  result.element,
  ownership: ownership,
)
```

Record the exact canonical path in `matchedExcludedEntrypoints`, add no root, and skip only the `potentialUnclassifiedEntrypoints.add` operation. Do not skip the remainder of library analysis, so imports, callbacks, spawn URI facts, and ordinary references are preserved.

After analyzer traversal and before the existing unclassified-entrypoint check, compute sorted unmatched exclusions. If non-empty, add one global issue:

```dart
addGlobalIssue(
  'excluded-dart-entrypoint-unresolved',
  'a declared excluded entrypoint did not resolve to a project-owned non-generated main()',
);
```

Do not include the owner reason or absolute path in durable blocker text.

- [ ] **Step 5: Run Task 2 GREEN**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/adapters/dart/dart_execution_context_service_test.dart \
  test/adapters/dart_execution_reachability_service_test.dart
```

Expected: all tests pass, the valid exclusion creates no execution root, and both stale and unlisted controls remain globally blocking.

- [ ] **Step 6: Run adjacent auxiliary-context regression**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/adapters/dart/auxiliary_execution_target_detector_test.dart \
  test/adapters/dart/dart_execution_context_service_test.dart \
  test/adapters/dart_execution_reachability_service_test.dart
```

Expected: all tests pass with existing test-driver and integration-test environment identities unchanged.

- [ ] **Step 7: Review checkpoint without commit**

Run scoped analyze and `git diff --check`. Confirm the diff does not remove or scope down `unclassified-dart-entrypoint`, and exclusions create neither `AuxiliaryExecutionTarget` nor `DartExecutionRootFact`.

---

### Task 3: Correct and rebind the frozen Smooth coverage authority

**Files:**
- Modify: `/Users/nhan/Desktop/flutter_pruner_benchmar_sample/worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml`
- Modify: `benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart`
- Modify: `benchmark/accuracy/src/l10n_mutation_manifest.dart`
- Modify: `benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json`
- Modify: `test/benchmark/accuracy/l10n_mutation_manifest_test.dart`
- Modify: `test/benchmark/accuracy/l10n_readiness_production_test.dart`

**Interfaces:**
- Consumes: exact Smooth source authority at commit `bac71afd115f72e379c0b501b95e5ede20ecd636`.
- Produces: corrected coverage fixture SHA-256 `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527`.
- Produces: a regenerated root manifest with unchanged totals and oracle identities.
- Preserves: Smooth normalization manifest bytes and SHA-256 `5072c958b6c304714820fec43301927f3621df60efd97a69b213871a63899792`.

- [ ] **Step 1: Add RED manifest authority assertions**

Change the Smooth scanner-coverage overlay expectation in `test/benchmark/accuracy/l10n_mutation_manifest_test.dart` from `59dc83948c3ef90c91199af0e520c487c8cac801e1cad46adad6fc3a4c53256d` to `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527`.

In `test/benchmark/accuracy/l10n_readiness_production_test.dart`, add a real temporary scanner-config case using the four supported targets and two exclusions from the spec. Load it through the production project-view path and assert the exact target tuples plus exact exclusions survive authority loading.

- [ ] **Step 2: Run Task 3 RED**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/benchmark/accuracy/l10n_mutation_manifest_test.dart \
  test/benchmark/accuracy/l10n_readiness_production_test.dart
```

Expected: the frozen manifest still exposes the old Smooth coverage-fixture digest; the production config assertion also fails before Tasks 1-2 are wired through the real loader.

- [ ] **Step 3: Replace only the retained fixture overlay**

Use `apply_patch` to replace the complete contents of the retained fixture with:

```yaml
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android-google-play
      platform: android
      entrypoint: lib/entrypoints/android/main_google_play.dart
    - name: android-fdroid
      platform: android
      entrypoint: lib/entrypoints/android/main_fdroid.dart
    - name: ios-app-store
      platform: ios
      entrypoint: lib/entrypoints/ios/main_ios.dart
    - name: macos-app-store
      platform: macos
      entrypoint: lib/entrypoints/ios/main_ios.dart
  excluded_entrypoints:
    - path: lib/main.dart
      reason: launcher guard terminates and is not a supported launch target
    - path: lib/entrypoints/android/main_samsung_gallery.dart
      reason: tracked dormant stub throws and has no retained launch or release invocation
```

Run:

```bash
shasum -a 256 /Users/nhan/Desktop/flutter_pruner_benchmar_sample/worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml
```

Expected: exactly `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527`. Verify the retained source checkout remains clean.

- [ ] **Step 4: Rebind both code authorities**

Replace only the old Smooth scanner-coverage SHA with the new SHA in:

```text
benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart
benchmark/accuracy/src/l10n_mutation_manifest.dart
```

Leave every other fixture, normalization, oracle, repository, toolchain, and policy digest unchanged.

- [ ] **Step 5: Regenerate the canonical manifests**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart run \
  benchmark/accuracy/build_l10n_mutation_readiness_manifest.dart \
  --evidence-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample/results/v2-natural-accuracy-2026-08-18 \
  --smooth-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/smooth-app \
  --gsy-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/gsy_github_app_flutter \
  --gitjournal-repository /Users/nhan/Desktop/flutter_pruner_benchmar_sample/GitJournal \
  --gitjournal-flutter /Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --output-directory benchmark/accuracy/manifests
```

Expected: exit 0, all retained repositories remain status-clean, the root manifest binds the new Smooth fixture digest, and the three oracle hashes plus totals 367 / 2,235 / 2,602 remain unchanged.

- [ ] **Step 6: Prove generated scope is minimal**

Compare generated manifest changes. Expected:

- `l10n-mutation-readiness-v2.json` changes only at the Smooth scanner coverage overlay digest;
- `smooth-normalized-family-v1.json`, `gsy-normalized-family-v2.json`, and `gitjournal-normalized-family-v1.json` have unchanged SHA-256 values;
- no oracle case, expected member map, verification argv, toolchain identity, or denominator changes.

If generation changes anything else, stop and diagnose before continuing.

- [ ] **Step 7: Run Task 3 GREEN**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/benchmark/accuracy/l10n_mutation_manifest_test.dart \
  test/benchmark/accuracy/l10n_readiness_production_test.dart
```

Expected: all tests pass.

- [ ] **Step 8: Review checkpoint without commit**

Run scoped analyze and `git diff --check`. Independently compare the four target tuples and two exclusions against retained Smooth README, workflows, and source at the pinned commit. Confirm no retained source checkout status changed.

---

### Task 4: Full verification and Smooth Stage 1 R5

**Files:**
- Create: `.superpowers/sdd/2026-08-27-excluded-application-entrypoints/progress.md`
- Create: `.superpowers/sdd/2026-08-27-excluded-application-entrypoints/task-4-report.md`
- Evidence output: `/Users/nhan/Desktop/flutter_pruner_stage1_smoke/l10n-stage1-family-smooth-v2-2026-08-27-r5.json`

**Interfaces:**
- Consumes: Tasks 1-3, exact SDK registry, exact retained corpus, and regenerated root manifest.
- Produces: fresh test/analyze/cleanliness evidence and one terminal R5 artifact.
- Produces: either production acceptance or a preserved exact new blocker; never an inferred pass.

- [ ] **Step 1: Run targeted implementation tests**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/core/target_matrix_test.dart \
  test/core/project_context_test.dart \
  test/adapters/dart/auxiliary_execution_target_detector_test.dart \
  test/adapters/dart/dart_execution_context_service_test.dart \
  test/adapters/dart_execution_reachability_service_test.dart \
  test/adapters/l10n/action_readiness/l10n_family_preflight_test.dart \
  test/benchmark/accuracy/l10n_readiness_production_test.dart
```

Expected: all tests pass.

- [ ] **Step 2: Run benchmark regression suites**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
  test/benchmark/accuracy/corpus_mutation_evidence_test.dart \
  test/benchmark/accuracy/l10n_mutation_manifest_test.dart \
  test/benchmark/accuracy/l10n_mutation_readiness_test.dart \
  test/benchmark/accuracy/l10n_readiness_production_test.dart
```

Expected: all tests pass with unchanged denominators.

- [ ] **Step 3: Run repository analysis and diff validation**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart analyze
git diff --check
```

Expected: `No issues found!` and no diff-check output.

- [ ] **Step 4: Freeze pre-run identities and cleanliness**

Record:

```bash
git rev-parse HEAD
shasum -a 256 benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json
shasum -a 256 benchmark/accuracy/manifests/smooth-normalized-family-v1.json
shasum -a 256 /Users/nhan/Desktop/flutter_pruner_benchmar_sample/worktrees/v2-natural-accuracy/smooth/packages/smooth_app/flutter_pruner_v2_accuracy.yaml
git status --porcelain=v1
```

Require empty `git status --porcelain=v1` in:

```text
/Users/nhan/Desktop/flutter_pruner_benchmar_sample/GitJournal
/Users/nhan/Desktop/flutter_pruner_benchmar_sample/gsy_github_app_flutter
/Users/nhan/Desktop/flutter_pruner_benchmar_sample/smooth-app
```

The Flutter Pruner worktree may remain dirty only with the known plan changes. Abort R5 if any retained source repository is dirty or any authority digest does not match the reviewed Task 3 state.

- [ ] **Step 5: Run Smooth family R5 exactly once**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart run \
  benchmark/accuracy/l10n_mutation_readiness.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json \
  --corpus-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --sdk 3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter \
  --output /Users/nhan/Desktop/flutter_pruner_stage1_smoke/l10n-stage1-family-smooth-v2-2026-08-27-r5.json \
  --family smooth
```

Do not interrupt a CPU-bound run while its lease is valid. Do not delete the stable hidden lease file; after process exit, use `lsof` to prove no process holds it.

- [ ] **Step 6: Evaluate every acceptance field**

Require:

```text
status = passed
staticPositiveCandidates = 312
staticNegativeNonCandidates = 1468
staticOracleMismatchCount = 0
acceptedFamilyBatches = 1
fullPolicyFailures = 0
provenRestorations = 1
originalProjectDriftCount = 0
unexpectedWritesForAccepted = 0
acceptedInternalVerdict = true
corpusPolicyPassed = true
restorationProven = true
verdictFailures = []
```

If any value differs, retain R5 as failure evidence, trace the new exact producer with `superpowers:systematic-debugging`, and do not change the oracle, manifest scope, graph, blocker scope, or policy to force acceptance.

- [ ] **Step 7: Final verification and report**

Re-run `git diff --check`; verify all three retained source repositories remain clean; compute the R5 artifact SHA-256; verify the coverage fixture remains `9c50b97122bc7dc037f87f8bcd85e0ce05ba92ddadbb3d6e3ab5e52974ca3527`; record root-manifest and normalization hashes, exact test counts, analyze output, R5 exit, acceptance fields, lease-handle result, and the exact changed file list in `task-4-report.md`.

Do not commit or push.
