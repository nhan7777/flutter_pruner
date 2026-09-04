# Flutter Auxiliary Test Contexts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Model `test_driver/` and `integration_test/` with exact typed Flutter execution environments so unrelated incomplete-context uncertainty no longer over-retains Smooth App's 312 oracle-removable l10n nodes.

**Architecture:** Add a test-only multi-target detection result while leaving executable/runtime/external single-target detection unchanged. Resolve exact driver/integration package imports, derive one standalone VM driver target or one integration target per declared configured Flutter target, and let the existing context service, directive resolver, graph, l10n adapter, and preflight consume those targets without exemptions.

**Tech Stack:** Dart 3.44.9, analyzer resolved-library APIs, Flutter Pruner reachability graph, `package:test`, the Stage 1 l10n corpus harness.

**Spec:** `docs/superpowers/specs/2026-08-27-flutter-auxiliary-test-contexts-design.md`

## Global Constraints

- Keep `selected-node-retained`, l10n preflight, `ReachabilityGraph`, the Stage 1 manifest, all denominators, and all oracle classifications unchanged.
- Production code must contain no Smooth-specific repository name, path, SHA, or exception.
- A complete derivation uses exact resolved imports and tracked project/target facts; otherwise emit exactly one incomplete target with a typed issue.
- Preserve configured target name, platform, flavor, entrypoint, and Dart defines through `sourceConfiguredTarget`.
- Never merge configured target variants merely because their SDK environment maps are equal.
- Recognized integration platforms are exactly `android`, `ios`, `macos`, `linux`, `windows`, and `web`.
- Preserve generated-test forced-incomplete behavior and all current `test/`, browser, `@TestOn`, `dart_test.yaml`, and `patrol_test/` behavior.
- Use `/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart`; do not run root Flutter tests.
- The worktree is already dirty. Preserve unrelated changes and do not stash, reset, reformat unrelated files, commit, push, open a pull request, or publish.
- Use `apply_patch` for edits and format only the Dart files touched by this plan.

## File Structure

- Modify `lib/src/adapters/dart/auxiliary_execution_target_detector.dart`: own test-surface authority recognition and exact test-target derivation.
- Modify `lib/src/adapters/dart/dart_execution_context_service.dart`: fan one resolved test library's roots out to every derived test target.
- Modify `test/adapters/dart/auxiliary_execution_target_detector_test.dart`: unit coverage for result invariants, import authority, VM driver semantics, integration matrix expansion, and fail-closed cases.
- Modify `test/adapters/dart/dart_execution_context_service_test.dart`: analyzer-resolved package fixtures, multi-target root registration, configured-driver non-duplication, and incomplete fallback.
- Modify `test/adapters/dart_execution_reachability_service_test.dart`: prove conditional branches remain target-specific after the new contexts are registered; do not duplicate detector assertions.
- Retain `docs/superpowers/specs/2026-08-27-flutter-auxiliary-test-contexts-design.md` as the approved contract.

---

### Task 1: Test-target detection value contract

**Files:**
- Modify: `lib/src/adapters/dart/auxiliary_execution_target_detector.dart:15-64`
- Test: `test/adapters/dart/auxiliary_execution_target_detector_test.dart`

**Interfaces:**
- Consumes: `AuxiliaryExecutionTarget`, `AuxiliaryExecutionTargetDetectionIssue`.
- Produces: `TestAuxiliaryExecutionTargetDetection({required List<AuxiliaryExecutionTarget> targets, List<AuxiliaryExecutionTargetDetectionIssue> issues = const []})`, immutable `targets`, immutable `issues`.

- [ ] **Step 1: Write constructor-invariant tests**

Add tests that construct `_completeTestTarget('a')` and `_incompleteTestTarget('a')` and assert:

```dart
expect(
  () => TestAuxiliaryExecutionTargetDetection(targets: const []),
  throwsArgumentError,
);
expect(
  () => TestAuxiliaryExecutionTargetDetection(
    targets: [complete, complete],
  ),
  throwsArgumentError,
);
expect(
  () => TestAuxiliaryExecutionTargetDetection(targets: [incomplete]),
  throwsArgumentError,
);
expect(
  () => TestAuxiliaryExecutionTargetDetection(
    targets: [complete],
    issues: const [
      AuxiliaryExecutionTargetDetectionIssue(
        code: 'test-environment-incomplete',
        reason: 'incomplete',
        requiresGlobalBlocker: false,
      ),
    ],
  ),
  throwsArgumentError,
);
```

Also prove a non-empty unique all-complete issue-free list and exactly one incomplete issue-bearing list are deeply immutable.

- [ ] **Step 2: Run the new test and verify RED**

Run:

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test test/adapters/dart/auxiliary_execution_target_detector_test.dart
```

Expected: compilation fails because `TestAuxiliaryExecutionTargetDetection` does not exist.

- [ ] **Step 3: Add the immutable result type**

Implement beside `AuxiliaryExecutionTargetDetection`:

```dart
final class TestAuxiliaryExecutionTargetDetection {
  TestAuxiliaryExecutionTargetDetection({
    required List<AuxiliaryExecutionTarget> targets,
    List<AuxiliaryExecutionTargetDetectionIssue> issues = const [],
  }) : targets = List.unmodifiable(targets),
       issues = List.unmodifiable(issues) {
    if (targets.isEmpty ||
        targets.map((target) => target.id).toSet().length != targets.length) {
      throw ArgumentError('Test targets must be non-empty and uniquely identified.');
    }
    if (issues.isEmpty) {
      if (targets.any((target) => !target.environmentComplete)) {
        throw ArgumentError('Complete test detection contains an incomplete target.');
      }
    } else if (targets.length != 1 || targets.single.environmentComplete) {
      throw ArgumentError('Incomplete test detection must contain one incomplete target.');
    }
  }

  final List<AuxiliaryExecutionTarget> targets;
  final List<AuxiliaryExecutionTargetDetectionIssue> issues;
}
```

Do not modify `AuxiliaryExecutionTargetDetection` or `RuntimeAuxiliaryExecutionTargetDetection`.

- [ ] **Step 4: Run the detector test and verify GREEN**

Run the command from Step 2. Expected: all tests pass.

- [ ] **Step 5: Review checkpoint without commit**

Run:

```bash
git diff --check -- lib/src/adapters/dart/auxiliary_execution_target_detector.dart test/adapters/dart/auxiliary_execution_target_detector_test.dart
git diff --stat -- lib/src/adapters/dart/auxiliary_execution_target_detector.dart test/adapters/dart/auxiliary_execution_target_detector_test.dart
```

Expected: no whitespace errors and only the two scoped files changed by this task.

---

### Task 2: Exact standalone `test_driver` authority

**Files:**
- Modify: `lib/src/adapters/dart/auxiliary_execution_target_detector.dart:1-157,420-470` (including the `target_matrix.dart` import for the declared-complete gate)
- Test: `test/adapters/dart/auxiliary_execution_target_detector_test.dart`

**Interfaces:**
- Consumes: `ResolvedLibraryResult`, `_sdkEnvironment`, `_stablePathId`, `TestAuxiliaryExecutionTargetDetection`.
- Produces: `detectTest(...) -> TestAuxiliaryExecutionTargetDetection`; exact URI predicate `_directlyImportsAny`.

- [ ] **Step 1: Add analyzer-resolved driver fixture support and failing tests**

Add a test helper that creates a canonical temp project with:

```text
.dart_tool/package_config.json
lib/driver_case.dart
fake_packages/integration_test/lib/integration_test_driver.dart
fake_packages/integration_test/lib/integration_test_driver_extended.dart
fake_packages/integration_test/lib/integration_test.dart
fake_packages/flutter_driver/lib/flutter_driver.dart
```

Map the fake packages explicitly in package config, resolve `lib/driver_case.dart` with `DartAnalysisWorkspace`, and return its `ResolvedLibraryResult`.

Add tests proving:

```dart
final resolved = await _resolveAuxiliaryImportLibrary('''
import 'package:integration_test/integration_test_driver_extended.dart';
void main() {}
''');
final result = flutterDetector.detectTest(
  relativePath: 'test_driver/screenshot_driver.dart',
  library: resolved,
);
expect(result.issues, isEmpty);
expect(result.targets, hasLength(1));
expect(result.targets.single.environmentValues, {
  'dart.library.io': 'true',
  'dart.library.html': 'false',
  'dart.library.js_interop': 'false',
  'dart.library.ui': 'false',
});
expect(result.targets.single.id, endsWith(':driver-vm'));
```

Add negative cases for no recognized import, a transitive-only recognized import, a same-named local library, and mixed/invalid explicit `@TestOn`; each must return one incomplete target with `test-environment-incomplete`. Add an exact `@TestOn('vm')` driver case and require the same standalone `dart.library.ui = false` environment.

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test test/adapters/dart/auxiliary_execution_target_detector_test.dart --name 'test_driver'
```

Expected: current detector returns an incomplete single-target result or has the old return type.

- [ ] **Step 3: Change `detectTest` to the test multi-target result**

Change its signature to:

```dart
TestAuxiliaryExecutionTargetDetection detectTest({
  required String relativePath,
  ResolvedLibraryResult? library,
})
```

Wrap existing VM/browser/Patrol/incomplete targets in `targets: [...]`. Update existing detector tests from `.target` to `.targets.single` without changing their assertions.

- [ ] **Step 4: Add exact direct-import authority and driver derivation**

Freeze these exact source URIs:

```dart
const _driverLibraryUris = {
  'package:flutter_driver/flutter_driver.dart',
  'package:integration_test/integration_test_driver.dart',
  'package:integration_test/integration_test_driver_extended.dart',
};
```

Implement `_directlyImportsAny` from `library.element.firstFragment.importedLibraries`, comparing each imported library's `firstFragment.source.uri.toString()` to the frozen set. Evaluate the `test_driver` branch before the generic VM/browser branch. Accept absent metadata or an effective exact `vm` selector, reject every other selector, and require the first path segment, Flutter SDK authority, and a direct recognized import.

Return:

```dart
TestAuxiliaryExecutionTargetDetection(
  targets: [
    AuxiliaryExecutionTarget(
      id: 'aux:test:${_stablePathId(relativePath)}:driver-vm',
      domain: AuxiliaryExecutionDomain.test,
      environmentValues: _sdkEnvironment('vm', flutterUiAvailable: false),
      environmentComplete: true,
      reason: 'Flutter drive test driver uses the standalone host Dart VM',
    ),
  ],
)
```

Do not recognize substring matches, transitive imports, unresolved imports, or directory name alone.

- [ ] **Step 5: Run the complete detector suite and verify GREEN**

Run the full detector test file. Expected: all prior and new tests pass.

- [ ] **Step 6: Review checkpoint without commit**

Run `git diff --check` and inspect the scoped diff. Confirm no change to production graph/preflight files.

---

### Task 3: Exact `integration_test` matrix expansion

**Files:**
- Modify: `lib/src/adapters/dart/auxiliary_execution_target_detector.dart`
- Test: `test/adapters/dart/auxiliary_execution_target_detector_test.dart`

**Interfaces:**
- Consumes: `ProjectContext.targetMatrix`, `BuildTarget`, `_targetIdentity`, `_shortHash`, `_sdkEnvironment`.
- Produces: `_integrationTestTargets(relativePath, library)` returning either all exact complete targets or one incomplete result.

- [ ] **Step 1: Write failing matrix-expansion tests**

Use a resolved library with a direct `package:integration_test/integration_test.dart` import and a Flutter project whose `TargetMatrix` is `declaredComplete`.

Assert an Android/iOS matrix returns two targets with IDs ending in `:integration-<16-char-target-hash>`, exact SDK environments, and exact `sourceConfiguredTarget` values. Add a flavor/define test:

```dart
expect(result.targets.map((target) => target.sourceConfiguredTarget), {
  BuildTarget(
    name: 'android-staging',
    platform: 'android',
    flavor: 'staging',
    entrypoint: 'lib/main.dart',
    dartDefines: const {'MODE': 'staging'},
  ),
  BuildTarget(
    name: 'android-prod',
    platform: 'android',
    flavor: 'prod',
    entrypoint: 'lib/main.dart',
    dartDefines: const {'MODE': 'prod'},
  ),
});
```

Add exact web expectations (`io=false`, `html=true`, `js_interop=true`, `ui=true`) and fail-closed tests for missing direct import, inferred/partial/empty matrices, unsupported platforms, reserved-define conflicts, and one invalid target among otherwise valid targets.

- [ ] **Step 2: Run integration-target tests and verify RED**

Run:

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test test/adapters/dart/auxiliary_execution_target_detector_test.dart --name 'integration_test'
```

Expected: no matrix expansion exists.

- [ ] **Step 3: Implement atomic matrix derivation**

Add:

```dart
const _integrationTestLibraryUri =
    'package:integration_test/integration_test.dart';
const _flutterApplicationPlatforms = {
  'android',
  'ios',
  'macos',
  'linux',
  'windows',
  'web',
};
```

Require Flutter SDK authority, a direct exact import, and `project.targetMatrix.status == TargetMatrixStatus.declaredComplete`. Treat exact `vm` test metadata as a native-platform matrix filter and exact `browser` metadata as a web-platform filter; absent metadata keeps the full matrix, while empty/mixed/conflicting metadata rejects. For each retained configured target, start with `_sdkEnvironment(target.platform, flutterUiAvailable: true)`, copy every non-reserved define, and reject the whole matrix when a reserved `dart.library.*` define disagrees with the SDK value.

On complete success, emit one target per configured target:

```dart
AuxiliaryExecutionTarget(
  id: 'aux:test:${_stablePathId(relativePath)}:'
      'integration-${_shortHash(_targetIdentity(target))}',
  domain: AuxiliaryExecutionDomain.test,
  environmentValues: environment,
  environmentComplete: true,
  reason: 'Flutter integration test copied from a declared application target',
  sourceConfiguredTarget: target,
)
```

Sort by ID. If any prerequisite or member fails, return exactly one `:incomplete` target and one scoped `test-environment-incomplete` issue; never return a valid subset.

- [ ] **Step 4: Run detector tests and verify GREEN**

Run the full detector test file. Expected: all tests pass with unchanged ordinary test/Patrol behavior.

- [ ] **Step 5: Format only detector files**

Run:

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart format lib/src/adapters/dart/auxiliary_execution_target_detector.dart test/adapters/dart/auxiliary_execution_target_detector_test.dart
git diff --check -- lib/src/adapters/dart/auxiliary_execution_target_detector.dart test/adapters/dart/auxiliary_execution_target_detector_test.dart
```

Expected: formatter changes only these two files and diff check passes.

---

### Task 4: Context-service multi-target root registration

**Files:**
- Modify: `lib/src/adapters/dart/dart_execution_context_service.dart:430-482`
- Test: `test/adapters/dart/dart_execution_context_service_test.dart:590-690,1995-2045`

**Interfaces:**
- Consumes: `TestAuxiliaryExecutionTargetDetection.targets` and `.issues`.
- Produces: one library root and optional `main()` declaration root per derived auxiliary target.

- [ ] **Step 1: Upgrade the execution-root fixture and write failing tests**

Extend `_createExecutionRootFixture` with `bool includeFlutterIntegrationPackages = false`. When true, write fake exact libraries for `integration_test` and `flutter_driver`, add those packages to package config, include Flutter/integration-test dependency facts in `ProjectContext.pubspec`, and accept an explicit `TargetMatrix`.

Replace the broad existing test with assertions that one recognized integration library is rooted under both Android and iOS derived target IDs; one recognized driver library is rooted under exactly one `:driver-vm` ID; every root ID resolves to one registered target; neither emits `test-environment-incomplete`; a driver without `main()` gets only a library root; configured `test_driver/main.dart` remains configured-only. Add an unrecognized-import control that remains one incomplete target.

- [ ] **Step 2: Run context tests and verify RED**

Run the exact integration and driver test names separately:

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test test/adapters/dart/dart_execution_context_service_test.dart --name 'integration_test'
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test test/adapters/dart/dart_execution_context_service_test.dart --name 'test_driver'
```

Expected: the service still assumes `detection.target` and cannot register multiple targets.

- [ ] **Step 3: Fan roots out atomically**

In the `testRunnerSurface` branch:

```dart
final detection = detector.detectTest(
  relativePath: relativePath,
  library: result,
);
final executionTargets = [
  for (final target in detection.targets)
    if (generatedPath) _forceIncompleteRuntimeTarget(target) else target,
];
for (final target in executionTargets) {
  addTarget(target);
}
detection.issues.forEach(addIssue);
```

Move generated/library/main root construction inside a loop over `executionTargets`, using `target.id`. Add `_generatedExecutableMainIssue` once per generated library, not once per target. Leave configured-entrypoint de-duplication unchanged.

- [ ] **Step 4: Run context and detector tests and verify GREEN**

Run both complete test files. Expected: all tests pass.

- [ ] **Step 5: Format scoped files and review without commit**

Format only the detector/context production and test files, run `git diff --check`, and confirm `l10n_family_preflight.dart` and `reachability_graph.dart` are unchanged by this plan.

---

### Task 5: Reachability regression for context contamination

**Files:**
- Test: `test/adapters/dart/dart_execution_context_service_test.dart`
- Conditional test: `test/adapters/dart_execution_reachability_service_test.dart`

**Interfaces:**
- Consumes: production `DefaultDartExecutionContextService` and `DefaultDartExecutionReachabilityService`.
- Produces: regression evidence that recognized Flutter auxiliary surfaces are complete and conditional applicability is target-specific.

- [ ] **Step 1: Add the end-to-end regression**

Build a fixture containing a recognized integration test, a recognized driver, and:

```dart
// lib/platform_value.dart
export 'platform_native.dart'
    if (dart.library.html) 'platform_web.dart';
```

Resolve context and reachability snapshots. Assert both recognized surface target sets are complete, no reachability issue contains `conditional Dart imports/exports are incomplete`, Android/iOS integration targets select the native branch, and web selects the web branch. Add an unrecognized integration sibling and prove it remains incomplete and retains both conditional branches.

- [ ] **Step 2: Verify the test detects the old behavior**

Run the regression before applying Tasks 2-4. If those tasks are already green, temporarily revert only the detector hunk with `apply_patch`, observe the regression fail, then restore the hunk with `apply_patch`. Do not use `git checkout` or `git reset`.

- [ ] **Step 3: Run regression GREEN**

Run the context and reachability test files. Expected: recognized contexts and exact branches pass; the unrecognized control remains incomplete.

- [ ] **Step 4: Review checkpoint without commit**

Run `git diff --check` and verify the regression did not add a generic allow-list or suppress a blocker.

---

### Task 6: Scoped verification and Smooth current-manifest evidence

**Files:**
- No additional production files expected.
- Evidence output: `/Users/nhan/Desktop/flutter_pruner_stage1_smoke/l10n-stage1-family-smooth-v2-2026-08-27-r4.json`

**Interfaces:**
- Consumes: current root manifest SHA, exact retained corpus repositories, exact Flutter SDK authorities, and the production scanner/evaluator/corpus runner.
- Produces: terminal Smooth family artifact or an exact new blocker for renewed diagnosis.

- [ ] **Step 1: Run targeted tests**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart test \
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

Expected: all tests pass with unchanged manifest denominators.

- [ ] **Step 3: Run repository analysis**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart analyze
```

Expected: `No issues found!`

- [ ] **Step 4: Verify authorities and corpus cleanliness**

Record SHA-256 for the root and Smooth normalization manifests. Require empty `git status --porcelain=v1` output in GitJournal, Smooth, and GSY before execution; abort if any retained repository is dirty.

- [ ] **Step 5: Run Smooth family R4**

```bash
/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart run \
  benchmark/accuracy/l10n_mutation_readiness.dart \
  --manifest benchmark/accuracy/manifests/l10n-mutation-readiness-v2.json \
  --corpus-root /Users/nhan/Desktop/flutter_pruner_benchmar_sample \
  --sdk 3.41.5=/Users/nhan/fvm/versions/3.41.5/bin/flutter \
  --sdk 3.44.1=/Users/nhan/fvm/versions/3.44.1/bin/flutter \
  --sdk 3.44.9=/Users/nhan/fvm/versions/3.44.9/bin/flutter \
  --output /Users/nhan/Desktop/flutter_pruner_stage1_smoke/l10n-stage1-family-smooth-v2-2026-08-27-r4.json \
  --family smooth
```

Do not interrupt a CPU-bound run while its lease is valid. The stable hidden lease file is deliberately retained; verify no process holds its handle after exit rather than deleting it.

- [ ] **Step 6: Evaluate the artifact without weakening gates**

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

If any field differs, preserve the artifact and report the exact new gate. Do not edit the oracle, manifest, preflight, graph, or policy to force a pass.

- [ ] **Step 7: Final cleanliness and evidence record**

Run `git diff --check`, confirm no temporary diagnostic source remains, confirm all three retained repositories are clean, compute the R4 artifact SHA-256, and report the exact worktree diff. Do not commit or push.
