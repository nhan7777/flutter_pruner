# Workflow and safety model

> **Purpose:** understand what each command does and when it is safe.
> **Time:** 4 minutes. **Requires:** [quickstart](quickstart.md).

## The five steps

| Command | Purpose | Changes sources? |
|---|---|---|
| `init` | Declare boundary, targets, verification policy | No |
| `scan` | Analyze and save a report | No |
| `apply --dry-run` | Validate and preview the plan | No |
| `apply` | Quarantine originals, mutate, rescan, verify | Yes |
| `rollback <run-id>` | Restore a quarantined run and verify | Yes |

`scan` and dry-run still create tool-owned state under `.flutter_pruner/`.

## Confidence tiers

| Tier | Meaning | Can apply? |
|---|---|---|
| `SAFE` | All gates passed, no manual risk | Yes |
| `HIGH` | One known manual risk | Package-internal only, after acknowledgement |
| `REVIEW` | Evidence incomplete or ambiguous | Never |
| `PROTECTED` | Must be kept | Never |

`PROTECTED` always wins. Routes, GetIt registrations, localization keys, and
duplicate groups are review-only.

A completed scan exits 0 even with findings. Exit 0 means the command
completed, not that nothing was found.

## Analysis modes

| Mode | Use when | Actionability |
|---|---|---|
| `application` | You own the complete app boundary | `SAFE` may be applied |
| `package` | External consumers are unknown | Audit-only |
| `package-internal` | You evaluate only this package locally | `SAFE` and one allowlisted `HIGH` |

Reusable projects default to `package`. Both package modes require at least
one `public_entrypoints` entry.

## Preview before mutation

```bash
flutter_pruner apply --dry-run
```

For a smaller reviewed set, repeat exact finding IDs:

```bash
flutter_pruner apply --dry-run --finding-id <exact-id>
```

IDs are exact and case-sensitive. The batch must be dependency-closed;
Flutter Pruner never adds an unrequested finding.

## Apply and recover

A mutating run quarantines originals before editing, verifies after each
round, and restores everything if any step fails. It is all-or-nothing.

```bash
flutter_pruner quarantine list
flutter_pruner quarantine inspect <run-id>
flutter_pruner rollback <run-id>
```

Keep quarantine data until the result is reviewed. Quarantine inspection is
read-only — it reports invalid journals instead of repairing them.

**Stop on `recoveryRequired`.** Inspect quarantine before running anything
else.

## Next steps

- [CLI and CI reference](reference.md) — flags, exit codes, JSON reports.
- [Project configuration](flutter_pruner.yaml.md) — every config field.
