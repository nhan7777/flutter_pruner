# Excluded Application Entrypoints Design

Date: 2026-08-27
Status: Approved

## Summary

Flutter Pruner currently treats every analyzer-resolved project-owned
`main()` outside a configured target or recognized auxiliary surface as an
unclassified executable. That fail-closed rule correctly exposed that the
frozen Smooth scanner-coverage fixture omitted real launch entrypoints, but
the current configuration model cannot distinguish a real omitted launch
target from a tracked `main()` that the project owner explicitly declares is
not launchable.

Add an exact, reason-bearing `target_matrix.excluded_entrypoints` authority for
application mode. A declared-complete target matrix may use it to identify
known project-owned `main()` files that are deliberately not supported launch
targets. Unknown, overlapping, duplicate, missing, generated, or analyzer-
unresolved exclusions remain fail-closed.

The first production use corrects the frozen Smooth coverage fixture. Its
supported matrix will contain the exact Android Google Play, Android F-Droid,
iOS App Store, and macOS App Store entrypoint/platform tuples. Its launcher
guard and dormant Samsung stub will be explicit exclusions rather than fake
targets. The corpus oracle, denominators, mutation policy, reachability graph,
and preflight rules remain unchanged.

## Evidence and Root Cause

Smooth Stage 1 R4 retained all 312 selected nodes because of the global issue:

`unclassified-dart-entrypoint: a selected main() is outside configured and recognized execution surfaces`

The auxiliary test-context implementation is not the producer. R4 resolved 27
complete auxiliary contexts with zero directive issues and zero incomplete
auxiliary target IDs. The remaining issue came from the frozen Smooth fixture,
which declared only Android and iOS targets at `lib/main.dart` while asserting
`complete: true`.

Authority at retained Smooth commit
`bac71afd115f72e379c0b501b95e5ede20ecd636` proves:

- README and local run guidance use
  `lib/entrypoints/android/main_google_play.dart` for Android;
- release workflows build Google Play and F-Droid by passing their exact
  entrypoint paths with `flutter build ... -t`; they do not pass Flutter
  `--flavor` or `--dart-define` values;
- iOS release workflows build
  `lib/entrypoints/ios/main_ios.dart`, and the tracked source documents that
  the same entrypoint supports macOS;
- `lib/main.dart` prints that the app must not start through that file and then
  terminates;
- `lib/entrypoints/android/main_samsung_gallery.dart` is a dormant stub whose
  `main()` throws `Missing Samsung Galaxy Store URI!`; no retained run or
  release authority invokes it.

Simply keeping the two `lib/main.dart` branches would misrepresent unsupported
launches as supported targets. Simply removing them would make the guard
unclassified. Ignoring every imported library that happens to define `main()`
would weaken the global omission detector and could hide a real launch target.
An explicit exclusion authority is therefore the smallest truthful model.

## Configuration Contract

`target_matrix` accepts one new optional key:

```yaml
target_matrix:
  complete: true
  targets:
    - name: android-google-play
      platform: android
      entrypoint: lib/entrypoints/android/main_google_play.dart
  excluded_entrypoints:
    - path: lib/main.dart
      reason: launcher guard terminates and is not a supported launch target
```

Each exclusion contains exactly two required keys:

- `path`: a canonical project-relative application Dart source path;
- `reason`: a non-empty owner assertion explaining why the file is not a
  supported launch target.

Exclusions are valid only when `analysis.mode` is `application` and
`target_matrix.complete` is `true`. An omitted key means no exclusions. An
explicit empty list is accepted and is equivalent to omission.

The parser rejects:

- exclusions in package or package-internal mode;
- exclusions attached to a partial target matrix;
- unknown keys, duplicate paths, empty reasons, absolute or escaping paths,
  missing files, non-Dart files, links that violate the existing project path
  policy, and generated paths;
- a path that also appears in any configured target.

The YAML declaration is owner-supplied coverage authority, not an inferred
heuristic. Flutter Pruner never adds exclusions from filenames, imports,
comments, control flow, or repository identity.

## Data Model

Add an immutable `ExcludedApplicationEntrypoint` value with `path` and
`reason`. `TargetMatrix` owns a deeply immutable list named
`excludedEntrypoints`; existing constructors default it to empty so API callers
that do not use exclusions retain current behavior.

`ProjectConfig.load` validates YAML exclusions and passes snapshots into the
target matrix. `ProjectContext` exposes them only through its target matrix;
there is no second coverage registry.

Equality-sensitive or identity-sensitive target behavior remains based solely
on `BuildTarget`. An exclusion is not a build target, does not produce an
execution context, does not add roots, and does not contribute environment,
platform, flavor, or Dart-define facts.

## Analyzer and Reachability Semantics

`DefaultDartExecutionContextService` resolves exclusions during the same
pass-shared analyzer traversal used to discover `main()` declarations.

For every configured exclusion:

1. canonicalize its path with the existing project path policy;
2. require a project-owned, non-generated, analyzer-resolved library at that
   exact path;
3. require that the library exposes an analyzer-resolved entry point;
4. mark that exact entrypoint as classified-but-not-rooted;
5. emit no target and no execution root.

After traversal, any exclusion not matched to such a library produces one
global `excluded-dart-entrypoint-unresolved` issue. Configured targets still
win no precedence because overlap is rejected before analysis. Every other
unconfigured `main()` continues to produce the existing global
`unclassified-dart-entrypoint` issue.

Exclusions only classify executable surfaces. They do not suppress ordinary
imports, references, declarations, dynamic invocation, callback boundaries,
spawn-URI boundaries, generated provenance, or l10n usage facts. Code imported
by a real target remains reachable through that target normally.

No change is made to `ReachabilityGraph`, blocker projection,
`selected-node-retained`, or family preflight.

## Smooth Fixture Rebinding

The corrected frozen Smooth scanner-coverage fixture will declare these exact
supported targets:

| Name | Platform | Entrypoint |
|---|---|---|
| `android-google-play` | `android` | `lib/entrypoints/android/main_google_play.dart` |
| `android-fdroid` | `android` | `lib/entrypoints/android/main_fdroid.dart` |
| `ios-app-store` | `ios` | `lib/entrypoints/ios/main_ios.dart` |
| `macos-app-store` | `macos` | `lib/entrypoints/ios/main_ios.dart` |

All four targets have absent `flavor` and empty `dart_defines`, matching the
retained commands rather than interpreting workflow variable `FLAVOR` as the
Flutter `--flavor` option.

It will declare these exclusions:

| Path | Reason authority |
|---|---|
| `lib/main.dart` | tracked launcher guard says the app must not start there and terminates |
| `lib/entrypoints/android/main_samsung_gallery.dart` | tracked dormant stub throws and has no retained launch/release invocation |

The fixture bytes receive a new SHA-256. The manifest builder, frozen manifest
loader, and generated `l10n-mutation-readiness-v2.json` must all bind the same
new digest. No source checkout file is edited; only the retained fixture
overlay and Flutter Pruner-owned evidence bindings change.

## Failure Handling

- Malformed exclusions fail configuration loading.
- An exclusion that drifts away from an analyzer-resolved `main()` becomes a
  global blocker; it is never silently ignored.
- A newly introduced unconfigured `main()` remains a global blocker even when
  other exclusions exist.
- Partial target authority cannot use exclusions to appear complete.
- Exclusions cannot carry platform, flavor, defines, or target identity and
  therefore cannot be mistaken for executable environments.
- Fixture digest drift prevents corpus view provisioning before scanner use.
- R5 remains rejected if any scanner, oracle, preflight, mutation,
  verification, restoration, or internal-verdict gate fails.

## Testing

Implementation follows red-green-refactor.

### Configuration and model tests

- parse a declared-complete application matrix with one reason-bearing
  exclusion and prove deep immutability;
- reject package mode, partial matrices, overlap, duplicates, missing paths,
  generated paths, unknown keys, and empty reasons;
- preserve current behavior when `excluded_entrypoints` is absent or empty.

### Execution-context tests

- an exact excluded analyzer-resolved `main()` creates neither a target nor a
  root and does not emit `unclassified-dart-entrypoint`;
- an exclusion whose file has no analyzer-resolved `main()` emits the global
  `excluded-dart-entrypoint-unresolved` issue;
- an additional unlisted `main()` still emits
  `unclassified-dart-entrypoint`;
- configured, excluded, test, integration-test, test-driver, standalone, and
  spawn-URI surfaces remain distinct.

### Fixture and production regression

- bind the corrected Smooth fixture to the exact supported target and
  exclusion matrix above;
- update every expected fixture digest and regenerate the root manifest;
- run focused config/context/reachability and production-harness tests with
  `/Users/nhan/fvm/versions/3.44.9/bin/cache/dart-sdk/bin/dart`;
- run repository-wide `dart analyze` and `git diff --check`;
- require all retained corpus repositories to remain clean;
- run Smooth Stage 1 R5 into a new artifact, preserving 312 positives, 1,468
  negatives, and zero oracle mismatch;
- record exact source fingerprint, root-manifest SHA-256, Smooth normalization
  SHA-256, corrected coverage-fixture SHA-256, artifact SHA-256, terminal gate,
  mutation/restoration counts, and internal verdict.

R5 is production acceptance evidence only if every configured gate accepts.
Otherwise retain it as failure evidence and restart root-cause analysis without
changing the oracle or weakening policy.

## Non-Goals

- No Smooth-specific production adapter behavior.
- No heuristic detection of guards, stubs, throws, or imported `main()` files.
- No change to which l10n keys are positive or negative.
- No new target inference, environment inference, or platform alias.
- No relaxation of global blocker scope or incomplete-context handling.
- No mutation of the retained Smooth source checkout.
- No commit, push, PR, publication, or release operation.
