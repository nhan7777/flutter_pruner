# Flutter Auxiliary Test Contexts Design

Date: 2026-08-27
Status: Approved

## Summary

Flutter Pruner currently models unannotated files below `test/` as Flutter
host-VM tests, but leaves files below `integration_test/` and `test_driver/`
with incomplete execution environments. On Smooth App, those two incomplete
auxiliary targets make conditional-directive uncertainty pass-wide. The l10n
adapter then emits a source-less namespace blocker, causing every one of the
312 independently oracle-removable l10n nodes to appear retained in every
auxiliary projection.

This change will model the two Flutter test surfaces with typed, explicit
environments. It will not weaken `selected-node-retained`, scope away a real
blocker, change the Stage 1 oracle, or add a Smooth-specific exemption.

## Evidence and Root Cause

The current Smooth Stage 1 artifact proves:

- static detection still matches the oracle: 312 positive candidates and
  1,468 negative non-candidates, with zero mismatch;
- family preflight rejects before mutation with
  `scanBlockerPresent / selected-node-retained`;
- the retained projection contains all 312 selected nodes for 25 otherwise
  complete VM test targets and two incomplete targets:
  `integration_test/app_test.dart` and
  `test_driver/screenshot_driver.dart`.

The data flow producing the false retention is:

1. `AuxiliaryExecutionTargetDetector.detectTest` only infers a Flutter host VM
   for files whose first path segment is `test`.
2. `integration_test/` and `test_driver/` therefore receive empty,
   `environmentComplete: false` targets.
3. Conditional directive applicability is unknown for those targets.
4. The unresolved directive state is promoted to a pass-level reachability
   issue.
5. The l10n adapter projects the pass-level issue as a source-less blocker over
   the complete l10n namespace.
6. Source-less blockers are deliberately active in every retained closure, so
   all 312 Smooth nodes fail family preflight.

This is an execution-context modeling gap. Changing expected outcomes or
removing the preflight gate would conceal the gap and violate the frozen Stage
1 evidence contract.

## Requirements

### Safety invariants

- Keep the three-family denominator and the 367 independently frozen positive
  keys unchanged.
- Keep `selected-node-retained` and every current l10n action-readiness gate
  unchanged.
- Do not add repository names, paths, hashes, or Smooth-specific behavior to
  production adapters.
- A surface is complete only when one or more exact environments can be
  derived from tracked project facts.
- Missing, partial, conflicting, or heterogeneous authority remains explicit
  `environmentComplete: false` evidence.
- Preserve exact target identity, Dart defines, flavor, platform, and
  entrypoint whenever a configured target supplies the environment.
- Do not merge distinct environments into one synthetic target.

### Surface semantics

#### `test/`

Retain existing behavior for `@TestOn`, tracked `dart_test.yaml`, Flutter
host-VM inference, browser tests, and incomplete mixed/unknown selectors.

#### `patrol_test/`

Retain the existing closed native-device rule and its existing fail-closed
checks.

#### `test_driver/`

A selected Flutter package may model an unannotated `test_driver/*.dart`
library as a standalone host-Dart-VM driver when it is a non-generated,
analyzer-resolved test-runner root, resolves a direct import of the recognized
Flutter driver or integration-test driver library, and no explicit `@TestOn`
or tracked test-platform authority contradicts VM execution. The recognized
imports are frozen exact package URIs rather than substring matches:

- `package:flutter_driver/flutter_driver.dart`
- `package:integration_test/integration_test_driver.dart`
- `package:integration_test/integration_test_driver_extended.dart`

Flutter tooling launches this driver with the engine Dart binary, not inside a
Flutter application or the Flutter widget-test shell. The target therefore
uses the standalone host-VM SDK environment:

- `dart.library.io = true`
- `dart.library.html = false`
- `dart.library.js_interop = false`
- `dart.library.ui = false`

Explicit browser, mixed, malformed, or contradictory metadata remains governed
by the current metadata rules and cannot be overridden by the directory name.

#### `integration_test/`

An unannotated `integration_test/*.dart` library is expanded over the exact
configured application targets only when:

- the project is a Flutter application;
- the resolved library directly imports the recognized Flutter
  application-side URI `package:integration_test/integration_test.dart`;
- the target matrix is declared complete;
- at least one configured target is compatible with Flutter integration-test
  execution; and
- every emitted environment can be constructed without an SDK-owned define
  conflict.

Each emitted auxiliary target copies its source configured target and receives
the exact SDK library environment plus all non-reserved Dart defines. Android,
iOS, macOS, Linux, Windows, and web are the only recognized Flutter application
platforms. Distinct configured targets remain distinct even if their current
SDK library maps happen to be equal. Unsupported platforms are not guessed.

If no target can be emitted, or any declared target that may execute the test
cannot be modeled exactly, the detector returns one explicit incomplete target
and a scoped issue. The detector never silently shrinks a declared complete
matrix.

Explicit `@TestOn` or tracked project test-platform metadata remains
authoritative as a matrix filter, not as a replacement host environment.
`vm` retains recognized native configured targets and `browser` retains
recognized web configured targets; the integration target still copies its
exact configured Flutter environment with `dart.library.ui = true`. An empty,
conflicting, mixed, or unsupported filter remains incomplete rather than
falling back to the unfiltered application matrix.

## API and Data Flow

`TestAuxiliaryExecutionTargetDetection` will represent a non-empty immutable
list of test targets. The existing single-target
`AuxiliaryExecutionTargetDetection` remains unchanged for executable,
incomplete-runtime, and external-consumer detection. Test-detection issues
remain immutable and describe the whole derivation. Constructor invariants
will reject:

- an empty target list;
- duplicate target IDs;
- conflicting definitions under one ID; and
- an issue-free derivation containing an incomplete target; and
- an issue-bearing derivation that is not exactly one incomplete target.

`AuxiliaryExecutionTargetDetector.detectTest` will:

1. resolve explicit file/project test-platform metadata first;
2. apply the existing `test/` and `patrol_test/` rules;
3. derive the host-VM `test_driver/` target;
4. derive one `integration_test/` target per exact configured environment; or
5. return one incomplete target with a scoped issue.

`DefaultDartExecutionContextService` will register every returned target and
attach the same test library and `main()` roots to each target. Existing target
definition conflict checks remain authoritative. Downstream directive,
reachability, l10n usage, graph, and preflight components consume the resulting
targets without special cases.

Target IDs will retain the existing stable path identity and add an explicit
environment suffix. Matrix-derived integration targets will include the full
configured-target identity hash rather than only a platform label, preventing
flavor/define variants from aliasing.

## Failure Handling

- Analyzer resolution failure remains a global execution-context issue.
- Test metadata that is malformed, contradictory, mixed, or unsupported emits
  one incomplete target and the existing scoped issue.
- An incomplete/partial application matrix cannot close an integration-test
  environment.
- Reserved `dart.library.*` define conflicts remain globally blocking.
- Duplicate derived IDs with unequal target definitions remain globally
  blocking in the context service.
- Generated test roots keep their current forced-incomplete behavior.

No failure path falls back from an incomplete integration context to a host VM
or to the first configured device.

## Testing

Implementation follows red-green-refactor.

### Detector tests

- `test_driver/` with a recognized resolved driver import produces exactly one
  complete standalone host-VM target with `dart.library.ui = false`.
- `test_driver/` without a recognized driver import remains incomplete.
- explicit contradictory metadata prevents directory inference.
- a complete Android/iOS matrix produces two distinct complete integration
  targets, each preserving its source configured target.
- flavor and non-reserved define variants remain distinct.
- a complete web target produces exact web SDK values.
- partial, empty, unsupported, or reserved-define-conflicting matrices remain
  incomplete.
- ordinary `test/`, `patrol_test/`, browser, mixed, and malformed cases retain
  their current behavior.

### Context-service and graph tests

- one integration-test library is rooted in every derived target.
- target registration remains deterministic and rejects definition conflicts.
- exact auxiliary conditional imports resolve independently per integration
  target.
- an incomplete integration target continues to retain affected nodes and
  report incomplete integrity.
- unrelated complete VM tests are no longer contaminated by a falsely
  incomplete Flutter surface.

### Production regression

- Run targeted detector/context/reachability/l10n preflight tests.
- Run the current benchmark production suites and repository analyzer.
- Recreate the disposable Smooth production view and prove both formerly
  incomplete surfaces are now explicit complete targets.
- Rerun the Smooth current-manifest Stage 1 family corpus.
- Accept success only if static counts remain 312/1,468 with zero mismatch,
  internal family verdict is accepted, full corpus policy passes, restoration
  is proven, original-project drift is false, and unexpected writes are zero.

If Smooth still rejects, retain the rejection and restart root-cause analysis;
do not alter the oracle or weaken preflight.

## Non-goals

- No public l10n actionability or apply/quarantine path.
- No Stage 1 denominator or manifest correction.
- No generic suppression of source-less blockers.
- No change to configured application target semantics.
- No claim that every third-party custom integration runner is modeled.
- No commit, push, pull request, or publication as part of implementation.
