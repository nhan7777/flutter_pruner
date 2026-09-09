# CLI and CI reference

> **Purpose:** exact flags, exit codes, and report contracts for automation.
> **Time:** 3 minutes. **Requires:** [workflow](workflow.md).

## Commands

```
flutter_pruner init [--project <dir>]
flutter_pruner scan [--project <dir>] [--format json|html] [--output <file>]
flutter_pruner apply [--dry-run] [--finding-id <id>...] [--yes] [--project <dir>]
flutter_pruner rollback <run-id> [--project <dir>]
flutter_pruner quarantine list|inspect <run-id>|clean [--project <dir>]
```

`q` is an alias for `quarantine`. Run any command with `--help` for details.

## Common flags

| Flag | Commands | Purpose |
|---|---|---|
| `--project <dir>` | all | Project root, defaults to current directory |
| `--format json` | scan, apply | Save machine-readable JSON v3 report |
| `--output <file>` | scan, apply | Report destination, must not exist |
| `--dry-run` | apply | Preview without changing files |
| `--finding-id <id>` | apply | Exact finding, repeat for a batch |
| `--yes` | apply | Accept package-internal risk without prompting |

Advanced flags (`--adapter`, `--config`, `--quarantine`,
`--expect-preview-fingerprint`, `--json-version`) are documented in `--help`
and intended for debugging and automation handoffs.

## Exit codes

| Exit | Meaning |
|---|---|
| `0` | Completed (including dry-run and deliberate cancellation) |
| `1` | Operational failure (config, filesystem, verification) |
| `2` | Safe stop (not admitted, or rolled back with no mutation) |
| `64` | Usage error, usage printed to stderr |
| `70` | Internal failure, failure report named on stderr if committed |

## Reports

Every completed scan and handled apply saves one immutable report under
`.flutter_pruner/reports/`. HTML is the default and works offline. The
terminal prints the committed path.

For CI, save JSON and inspect it — never parse human stdout:

```bash
flutter_pruner scan --format json --output scan.json
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' scan.json
```

Reports may contain absolute paths and toolchain identity. Review before
sharing.

## Streams

Human results go to stdout. Progress, diagnostics, usage, and errors go to
stderr. JSON is selected with `--format json --output <file>`, never by
redirecting stdout.

## Next steps

- [Project configuration](flutter_pruner.yaml.md) — every config field.
- [Run reports](run-report.md) — full schema and storage layout.
