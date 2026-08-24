# Using Flutter Pruner safely

This guide covers the operational decisions around scanning, applying, and
recovering a Dart or Flutter project. For a disposable walkthrough, start with
the [CLI example](../example/README.md). For implementation details, see the
[architecture](architecture.md).

## Workflow at a glance

| Command | Purpose | Changes project sources or assets? |
|---|---|---|
| `flutter_pruner init` | Declare the project boundary, targets, and verification policy | No |
| `flutter_pruner scan` | Analyze and save a report | No |
| `flutter_pruner apply --dry-run` | Validate and preview the eligible plan | No |
| `flutter_pruner apply` | Quarantine originals, mutate, rescan, and verify | Yes |
| `flutter_pruner rollback <run-id>` | Restore a quarantined run and verify it | Yes |

`scan` and dry-run still create tool-owned state under `.flutter_pruner/`.

## Prepare the project

Start from a clean Git worktree or a verified filesystem backup. Run `init`
from the package or application root:

```bash
flutter_pruner init
```

Review `.flutter_pruner/config.yaml` before scanning. In particular, confirm:

- the analysis mode matches the boundary you own;
- every supported platform, flavor, entrypoint, and Dart define is represented;
- package public entrypoints are complete;
- verification commands are appropriate for this project;
- exclusions do not hide project-owned code or assets that can retain findings.

Flutter Pruner never marks target coverage complete merely because it discovered
a plausible default. See the [configuration reference](flutter_pruner.yaml.md)
for every field.

## Choose the analysis boundary

| Mode | Use it when | Actionability |
|---|---|---|
| `application` | This project owns the complete application boundary | `SAFE` findings may be applied |
| `package` | Unknown applications or packages may consume the public API | Audit-only; apply and dry-run are disabled |
| `package-internal` | You intentionally evaluate only this package's local boundary | Private `SAFE` and one narrowly allowlisted `HIGH` risk may be applied |

Reusable and hybrid projects default conservatively to `package`. Both package
modes require at least one `public_entrypoints` entry so public exports and
their dependency closure remain reachable.

`package-internal` does not prove that external consumers are safe. It warns on
every run, and an eligible `HIGH` batch requires interactive acknowledgement or
`--yes`. That flag accepts only the documented package-internal risk; it does
not bypass coverage, blockers, planning, verification, or quarantine.

## Declare complete coverage

A target is defined by its platform, entrypoint, flavor, and Dart defines.
`target_matrix.complete: true` is a project-owner assertion that every supported
combination has been declared.

Incomplete targets, unknown conditional branches, unresolved entrypoints, or
unsupported execution contexts retain affected code and prevent `SAFE` or
`HIGH`. Test, tool, benchmark, example, isolate, and other auxiliary execution
contexts can also retain candidates; an incomplete auxiliary context never
becomes proof that something is unused.

If the terminal prints `ANALYSIS LIMITED`, resolve the listed coverage or
semantic warnings before considering an apply.

## Scan and review

Run all configured analyzers:

```bash
flutter_pruner scan
```

Select one or more adapters when investigating a specific domain:

```bash
flutter_pruner scan --adapter dart --adapter assets
```

The terminal summarizes coverage, findings, blockers, and the saved report path.
A completed scan can exit 0 while still reporting findings. Exit 0 means the
command completed; it does not mean that nothing was found.

### Confidence tiers

| Tier | Meaning | Mutation policy |
|---|---|---|
| `SAFE` | All shared hard gates passed and no manual risk remains | Eligible in application and package-internal modes |
| `HIGH` | Hard gates passed with exactly one allowlisted manual risk | Package-internal only, after acknowledgement |
| `REVIEW` | Evidence is incomplete, ambiguous, unsupported, or has multiple risks | Never applied |
| `PROTECTED` | A framework or ownership rule requires the item to remain | Never applied |

Protection takes precedence over every other result. Unknown runtime behavior,
dynamic references, generated-code uncertainty, and dangling graph evidence
reduce confidence instead of being ignored.

Routes, GetIt registrations, localization keys, and duplicate groups are
review-only. `sourceBytes` describes source files on disk, not a promised
change in the release artifact.

For the predicate-level policy, see the
[confidence model](confidence-model.md).

## Preview a plan

Always preview before mutation:

```bash
flutter_pruner apply --dry-run
```

To operate on a smaller reviewed set, repeat exact finding IDs:

```bash
flutter_pruner apply --dry-run \
  --finding-id 'dart:my_app/lib/example.dart#_unusedHelper' \
  --finding-id 'asset:my_app:assets/legacy.png'
```

IDs are exact and case-sensitive. The requested batch must:

- contain no duplicate or empty IDs;
- resolve to current findings;
- contain only apply-eligible findings;
- already be dependency-closed.

Flutter Pruner never adds an unrequested logical finding. An unknown,
non-actionable, blocked, or incomplete selection stops before verification or
quarantine.

## Apply and verify

After reviewing the same plan, remove `--dry-run`:

```bash
flutter_pruner apply \
  --finding-id 'dart:my_app/lib/example.dart#_unusedHelper'
```

A mutating run:

1. acquires the project operation lock;
2. rejects non-terminal historical quarantine state;
3. captures the verification baseline;
4. builds a dependency-closed plan;
5. quarantines originals before editing;
6. stages each non-empty fixed-point round and verifies its combined state once;
7. commits the accepted wave, then rescans for the next round;
8. keeps the result only after the whole run completes.

The command is all-or-nothing at the run level. If a later mutation, rescan,
verification, convergence check, or canonical report fails, Flutter Pruner
attempts to restore every mutation from that run to its original baseline and
verifies the restoration.

Do not edit the same paths or start another mutating Flutter Pruner command
while apply is running.

## Reports and CI

HTML is the default report format and works offline. JSON schema v3 is the
recommended machine interface.

Managed scan reports use:

```text
.flutter_pruner/reports/store/objects/scan-<run-id>.html
.flutter_pruner/reports/store/commits/<run-id>-1.commit.json
```

Apply exports its selected terminal format under `.flutter_pruner/reports/` and
keeps monotonic canonical JSON snapshots with a mutating run's quarantine.
The terminal always prints the actual committed object path.

Export JSON for CI:

```bash
flutter_pruner scan --format json --output scan.json
```

A relative override is contained below the report directory. An absolute
destination is also supported. The requested file and its adjacent hidden
authority record must both be absent; exact output paths are single-assignment
and are never overwritten. Use a fresh CI workspace or a unique output name for
every run.

Do not use the process exit code as a finding threshold. Inspect the report, for
example:

```bash
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' .flutter_pruner/reports/scan.json
```

Reports can include absolute project paths, verification step IDs and working
directories, toolchain identity, diagnostics, symbol names, and finding
evidence. Review and sanitize them before sharing.

See [structured run reports](run-report.md) for schema fields, exit codes,
immutable persistence, JSON v2 compatibility limits, and additional CI
selectors.

## Rollback and recovery

List retained runs:

```bash
flutter_pruner quarantine list
```

Restore one run:

```bash
flutter_pruner rollback <run-id>
```

Quarantine lives under `.flutter_pruner/quarantine/<run-id>`. Its checksummed
manifest is the authoritative rollback ledger. Reports are observability
artifacts and are never used to restore project files.

Use `rollback <run-id> --clean` only when restoration has completed and the
quarantine should also be removed. Keeping the quarantine until the project has
been reviewed gives you more recovery evidence.

### If recovery is required

`recoveryRequired` means Flutter Pruner could not prove that the original
working-copy state was restored. Stop using mutating commands, inspect the
quarantine and report, and recover the project before continuing.

A successfully recovered failed run does not retain earlier mutations. If
recovery cannot be proven, Flutter Pruner reports the uncertainty instead of
presenting a partial success.

### Rollback limits

For regular files, rollback restores captured bytes and POSIX permission bits
where the platform exposes them. It does not restore:

- extended attributes;
- ACLs;
- ownership (`uid`/`gid`);
- hard-link topology.

Use version control or a filesystem backup whenever those properties matter.
The transaction model protects documented process and path-race boundaries; it
is not a universal filesystem or sudden-power-loss transaction.

## Important analysis limits

- Static analysis can prove known references, but the absence of a runtime
  observation cannot prove that something is unused.
- Custom callback registries, reflection-like behavior, external deep links,
  platform manifests, and dynamic asset paths require explicit modeling or
  project policy.
- Built-in callback boundaries cover
  `PluginUtilities.getCallbackHandle`, `Isolate.spawn`, and
  `Workmanager.initialize`; custom registries remain a boundary.
- Generated-file provenance is evidence, not liveness. Generated uncertainty
  retains affected source rather than granting deletion authority.
- Package analysis cannot discover unknown external consumers.
- Source-byte totals are not release binary-size estimates.

Resolve uncertainty by improving configuration, adding a supported adapter, or
leaving the finding in `REVIEW`. Do not widen `SAFE` to obtain more findings.

## Common problems

| Symptom | What to do |
|---|---|
| “Run `flutter_pruner init`” | Initialize the selected project and review its configuration |
| `ANALYSIS LIMITED` | Resolve the listed target, parser, adapter, or blocker evidence |
| Package apply is refused | Keep audit-only `package` mode or explicitly choose the intended local boundary |
| Report collision | Choose an absent output path or use the automatic unique destination |
| `recoveryRequired` | Stop mutation; inspect quarantine and restore before continuing |
| Report is too sensitive to share | Sanitize it or reproduce the issue with a public fixture |

## Related documentation

- [Project configuration](flutter_pruner.yaml.md)
- [Structured run reports](run-report.md)
- [Architecture](architecture.md)
- [Graph model](graph-model.md)
- [Confidence model](confidence-model.md)
- [V2 adapter behavior](v2-adapters.md)
- [Contributor guide](../CONTRIBUTING.md)
