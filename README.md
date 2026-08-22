# Flutter Pruner

<p align="center">
  <img
    src="doc/images/flutter_pruner_banner.png"
    alt="Flutter Pruner — semantic cleanup for Flutter and Dart projects"
    width="100%"
  >
</p>

<p align="center">
  <a href="https://pub.dev/packages/flutter_pruner"><img src="https://img.shields.io/pub/v/flutter_pruner.svg?logo=dart&amp;logoColor=white" alt="pub package"></a>
  <a href="https://pub.dev/packages/flutter_pruner/score"><img src="https://img.shields.io/pub/points/flutter_pruner?logo=dart&amp;logoColor=white" alt="pub points"></a>
  <a href="https://github.com/nhan7777/flutter_pruner/actions/workflows/ci.yml"><img src="https://github.com/nhan7777/flutter_pruner/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://pub.dev/publishers/nhanlee.dev"><img src="https://img.shields.io/badge/publisher-nhanlee.dev-0175C2?logo=dart&amp;logoColor=white" alt="verified publisher: nhanlee.dev"></a>
  <a href="https://dart.dev/"><img src="https://img.shields.io/badge/Dart-%5E3.9.0-0175C2?logo=dart&amp;logoColor=white" alt="Dart SDK 3.9 or newer"></a>
  <a href="https://github.com/nhan7777/flutter_pruner/actions/workflows/ci.yml"><img src="https://img.shields.io/badge/platform-Linux%20%7C%20macOS%20%7C%20Windows-5C6BC0" alt="tested on Linux, macOS and Windows"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/nhan7777/flutter_pruner" alt="License"></a>
</p>

<p align="center">
  <strong>Safety-first semantic cleanup for Dart and Flutter.</strong><br>
  Find unreachable declarations and assets, review the evidence, then apply only
  changes allowed by the configured safety policy.
</p>

Flutter Pruner connects Dart declarations, libraries, assets, routes,
localization keys, and dependency registrations in one semantic graph. It
fails closed when coverage or evidence is incomplete.

> **Before applying:** use a clean Git worktree, review
> `.flutter_pruner/config.yaml`, and run `apply --dry-run`. A scan does not
> modify project sources or assets, but it does create reports under
> `.flutter_pruner/`.

## Quick start

Flutter Pruner requires Dart SDK 3.9 or newer.

### Install on macOS, Ubuntu, or Windows

```bash
dart pub global activate flutter_pruner
```

If the command is not found, add Pub's executable directory to `PATH`:

| Platform | Pub executable directory |
|---|---|
| macOS / Ubuntu | `$HOME/.pub-cache/bin` |
| Windows | `%LOCALAPPDATA%\Pub\Cache\bin` |

For CI or environments without a global executable:

```bash
dart pub global run flutter_pruner:flutter_pruner <command>
```

### Run the safe workflow

From the Flutter or Dart project you want to inspect:

```bash
flutter_pruner init
flutter_pruner scan
flutter_pruner apply --dry-run
flutter_pruner apply
```

`init` creates the project boundary and target configuration. `scan` analyzes
without changing sources or assets. `apply --dry-run` shows the eligible plan;
only `apply` can mutate the project.

Use `--project path/to/project` from another directory. For a disposable
first run, follow the [complete example](example/README.md).

## Read this before applying

- **Start from a clean Git worktree or verified backup.** Rollback is a recovery
  layer, not a replacement for version control.
- **Review the generated configuration.** Target coverage is declared by the
  project owner; Flutter Pruner never infers that every platform, flavor,
  entrypoint, or Dart define is covered.
- **Treat packages as open world.** `package` mode is audit-only because external
  consumers are unknown. `package-internal` deliberately ignores those consumers
  and requires explicit acknowledgement for eligible `HIGH` findings.
- **Static analysis has limits.** Dynamic strings, custom runtime registries,
  generated wiring, external deep links, and unresolved references reduce
  confidence instead of being ignored.
- **Stop on `recoveryRequired`.** Do not run another mutating command until the
  quarantine and report have been inspected and the project has been recovered.
- **Keep your own backup when metadata matters.** Regular-file rollback restores
  captured bytes and POSIX permissions where available, not ACLs, extended
  attributes, ownership, or hard-link topology.

See [Using Flutter Pruner safely](doc/using-flutter-pruner.md) before applying
to an important project.

## What it finds

| Area | Detection | Apply policy |
|---|---|---|
| Dart | Unreachable top-level declarations and empty libraries | Safety and mode controlled |
| Assets | Assets unreachable from live Dart code | Safety and mode controlled |
| Routes | `go_router` declarations and resolved navigation | Review only |
| Dependency injection | Direct base-scope `GetIt` registrations and lookups | Review only |
| Localization | ARB keys and current real-source `gen-l10n` accessors | Review only |
| Duplicates | Byte-identical files grouped with SHA-256 | Review only |

Member-level Dart deletion, dependency removal, fuzzy image matching, and binary
size attribution are outside the current scope.

## Understand the result

| Tier | What it means | Eligible for `apply`? |
|---|---|---|
| `SAFE` | Every hard gate passed and no manual risk remains | Yes, in application and package-internal modes |
| `HIGH` | Hard gates passed with exactly one known manual risk | Package-internal only, after acknowledgement |
| `REVIEW` | Evidence is incomplete, ambiguous, or unsupported | Never |
| `PROTECTED` | The item must be kept even if it appears unused | Never |

`PROTECTED` always wins. Framework-specific route, GetIt, localization, and
duplicate findings remain review-only.

A successful `scan` exits 0 even when findings exist. CI must inspect the JSON
report instead of treating the process exit code as “nothing found”:

```bash
flutter_pruner scan --format json --output scan.json
```

The selected output must not already exist. See the
[CI selectors](doc/run-report.md#ci-selectors) for stable checks.

## Preview, apply, and recover

To limit a reviewed plan, repeat an exact finding ID:

```bash
flutter_pruner apply --dry-run \
  --finding-id 'dart:my_app/lib/example.dart#_unusedHelper'

flutter_pruner apply \
  --finding-id 'dart:my_app/lib/example.dart#_unusedHelper'
```

The complete selection must remain eligible and dependency-closed; Flutter
Pruner does not silently add an unrequested logical finding.

To inspect and restore an applied run:

```bash
flutter_pruner quarantine list
flutter_pruner rollback <run-id>
```

Keep quarantine data until the resulting project has been reviewed and
verified. The [operational guide](doc/using-flutter-pruner.md) explains modes,
selection, recovery states, and rollback limits.

## Reports

Every completed scan and handled apply outcome saves a unique immutable report.
HTML is the default and works offline; JSON v3 is available for CI. The terminal
prints the actual committed report path.

Reports can contain absolute project paths, verification step IDs and working
directories, toolchain identity, and diagnostics. Review them before sharing.

See [structured run reports](doc/run-report.md) for storage layout, schema,
status, exit codes, compatibility limits, and CI examples.

## Upgrade or uninstall

```bash
dart pub global activate flutter_pruner
dart pub global deactivate flutter_pruner
```

## Documentation

**Using the CLI**

- [Using Flutter Pruner safely](doc/using-flutter-pruner.md)
- [Disposable first-run example](example/README.md)
- [Project configuration](doc/flutter_pruner.yaml.md)
- [Run reports and CI](doc/run-report.md)

**Understanding the safety model**

- [Architecture](doc/architecture.md)
- [Graph model](doc/graph-model.md)
- [Confidence model](doc/confidence-model.md)
- [Route, GetIt, and localization adapters](doc/v2-adapters.md)
- [Verified Flutter facts](doc/flutter-facts.md)

**Developing Flutter Pruner**

- [Contributor guide](CONTRIBUTING.md)
- [Adapter authoring guide](doc/contributing/how-to-add-adapter.md)
- [Release readiness](doc/release-readiness.md)
- [Roadmap](ROADMAP.md)

Found a false positive or focused feature request? Open an
[issue](https://github.com/nhan7777/flutter_pruner/issues). False `SAFE`
findings, data loss, and broken rollback are release-blocking defects.

## License

MIT — see [LICENSE](LICENSE).
