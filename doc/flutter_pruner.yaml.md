# Project configuration

Flutter Pruner reads its project-local configuration from
`.flutter_pruner/config.yaml`. A root-level `flutter_pruner.yaml` remains
discoverable for compatibility, but `flutter_pruner init` writes the canonical
tool-owned path.

Create a conservative starting point with:

```bash
flutter_pruner init
```

The generated file does not claim complete coverage unless the project owner
explicitly selected `--complete` or confirmed completeness in the wizard.

## Schema version 1

```yaml
version: 1

analysis:
  mode: application

target_matrix:
  complete: true
  targets:
    - name: android-prod
      platform: android
      entrypoint: lib/main.dart
      flavor: prod
      dart_defines:
        APP_ENV: prod

verification:
  steps:
    - id: flutter-analyze
      argv: [flutter, analyze, --fatal-infos]
    - id: flutter-test
      argv: [flutter, test]
```

Unknown keys, duplicate target names or conditions, unsupported platforms,
missing files, absolute or out-of-project source paths, and non-string Dart
defines are rejected before analysis.

## Analysis modes

`analysis.mode` accepts exactly:

- `application`: executable entrypoints define a closed application boundary.
- `package`: reusable-package, open-world audit mode. All non-protected
  findings remain `REVIEW`; apply is disabled.
- `package-internal`: a deliberately closed local package boundary. Findings
  exposed to unscanned consumers can be `HIGH` only when that is their sole
  risk, and apply requires explicit acknowledgement.

Package modes also require one or more public entry libraries:

```yaml
analysis:
  mode: package
  public_entrypoints:
    - lib/my_package.dart
```

`analysis.root_coverage` is not part of config version 1. Root coverage is
derived from the selected mode and validated entrypoints.

## Target coverage

Each target requires a unique `name`, a supported `platform`, and an existing
project-relative `entrypoint`. Optional `flavor` and `dart_defines` values are
part of the target identity. Supported platforms are `android`, `ios`, `web`,
`macos`, `linux`, and `windows`.

`target_matrix.complete: true` is an owner assertion that every supported
platform, flavor, entrypoint, and Dart-define combination is represented. An
inferred or partial matrix cannot produce `SAFE` or `HIGH`. Conditional Dart
imports or exports currently force the effective matrix back to partial because
their branches are not yet modelled per target.

## Verification policy

Every verification step has a unique stable `id` and a non-empty argv array.
The first argv item is executed directly, without shell interpolation. If the
section is omitted, Flutter Pruner uses `flutter analyze --fatal-infos` and
`flutter test`.

Mutating apply runs execute the same complete policy for the baseline,
candidate, and rollback checks. Policy hashes, step IDs, parser contracts,
working directory, and toolchain identity must match; there is no configuration
or CLI switch that bypasses verification.

Keep the configuration under version control and review it whenever build
targets, public entrypoints, or verification commands change.
