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
without changing sources or assets. `apply --dry-run` validates and shows the
frozen **initial physical plan**: its action order and every source path
snapshotted before a mutation could begin. Only `apply` can mutate the project.

For an all-eligible apply, that preview is intentionally only the initial
round: later rescans can discover more eligible work. For an exact,
dependency-closed `--finding-id` batch, the preview covers that complete
selection. A declaration action means "edit the declaration"; it can delete a
now-empty file only when no retained importer prevents that deletion.

Use `--project path/to/project` from another directory. For a disposable
first run, follow the [complete example](example/README.md).

## CLI and automation contract

Run `flutter_pruner` with no arguments for top-level help. `quarantine` also
shows its own subcommand help when used bare; `q` is its alias. Both
`flutter_pruner help <path>` and `flutter_pruner <path> --help` show the same
help for a command path. Help lists canonical names first and shows aliases
beside their owner.

Help and human results use concise sentence-case copy: descriptions and
progress labels are fragments, while results, warnings, errors, empty states,
and next actions are direct statements. Unknown commands and invalid arguments
write usage to stderr and exit `64`.

Completed, report-renderable `scan` and `apply` outcomes render a human summary
on stdout; this is never a JSON API. Failure paths can leave stdout empty and
use stderr plus a saved report when one commits. Their machine-readable evidence
is the saved report. Use `--format json --output <file>` to save JSON v3 for
automation. `apply` also accepts `--report-format` and `--report-output` with
identical behavior; the shorter spellings are preferred in new commands and
documentation.

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

## Preview, bind, apply, and recover

To limit a reviewed plan, repeat `--finding-id` once for each distinct exact
finding ID (duplicates are rejected). This binding outline uses placeholders,
not copy-paste finding IDs:

```text
flutter_pruner apply --dry-run \
  --finding-id <exact-finding-id> \
  --format json --output <unused-report.json>

flutter_pruner apply \
  --finding-id <same-exact-finding-id> \
  --expect-preview-fingerprint <saved-v1-fingerprint>
```

The complete selection must remain eligible and dependency-closed; Flutter
Pruner does not silently add an unrequested logical finding. Read the full
token at `.apply.initialPlan.preview.fingerprint` in the saved JSON v3 report;
replace the output placeholder with an unused filename. A relative output is
stored below `.flutter_pruner/reports/`; inspect that resolved file with
`jq -r '.apply.initialPlan.preview.fingerprint' <saved-report-path>`. Repeat
every finding ID exactly in the apply command.
The token is review-binding evidence, not a secret and not a general approval:
it is accepted only for that exact selection and never authorizes later
all-eligible rounds. A stale or mismatched token safely stops before
verification, quarantine, or source mutation.

To inspect and restore an applied run:

```bash
flutter_pruner quarantine list --project path/to/project
flutter_pruner quarantine inspect <run-id> --project path/to/project
flutter_pruner rollback <run-id> --project path/to/project
```

Keep quarantine data until the resulting project has been reviewed and
verified. The [operational guide](doc/using-flutter-pruner.md) explains modes,
selection, recovery states, and rollback limits. In particular, quarantine
inspection is read-only: it reports invalid or repair-required journals instead
of repairing them. Production `quarantine clean` now performs an
identity-bound, no-replace logical move into `.clean-retained/v1`; it retains
all physical bytes and therefore does not reclaim disk space. Use
`quarantine retained list|inspect|restore` for durable recovery evidence.
Release admission resolves `CLEAN-TOCTOU-1` only when the exact candidate
commit supplies passing hosted Linux, macOS, and Windows conformance artifacts;
missing, stale, skipped, or mismatched evidence still blocks release.

## Reports

Every completed scan and handled apply outcome saves a unique immutable report.
HTML is the default and works offline; JSON v3 is available for CI. The terminal
prints the actual committed report path. A failure report that was committed is
announced on stderr as `Failure report saved: <path>`; a report-write failure is
announced as `Error: report was not saved: <reason>`. A close failure after a
commit still retains the committed path as the authority, but the command exits
`70`.

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
