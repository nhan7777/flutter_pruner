# Structured run reports

Flutter Pruner JSON schema v3 describes a complete command invocation, not just
a list of findings. It is the stable interface for CI, audit logs and future
trend dashboards. The HTML formatter is a self-contained interactive view of
the same v3 payload.

```bash
flutter_pruner scan --project path/to/app
flutter_pruner apply --project path/to/app
flutter_pruner scan --project path/to/app --format json
flutter_pruner apply --project path/to/app --report-format json
```

A mutating `apply` that reaches a handled terminal outcome also atomically writes
`.flutter_pruner/quarantine/<run-id>/run-report.json`. The quarantine manifest
remains the canonical rollback ledger; the report is an observability projection
and is never used to restore files.

Schema v3 records `analysisMode`, `internalBoundaryComplete`,
`externalConsumersCovered`, per-finding `manualRiskCodes`/`applyEligible`, and
apply authorization (`acceptedRiskCodes` plus `interactive`, `yesFlag`, or
`notRequired`). Apply reports also include an additive `apply.selection`
record. This optional v3 field keeps existing schema-v3 readers backward
compatible; no schema bump is required. JSON v2 remains unchanged.

The canonical quarantine manifest records a completed full restore as
`fullRollback.status: restored`, its UTC timestamp, and `verified: true` only
after every restored regular file matches its pre-apply SHA-256 snapshot and
captured POSIX permission bits where available. Restored cases become
`rolledBack`; affected transactions become `rolledBackVerified`. The manifest
does not claim to restore xattrs, ACLs, `uid`/`gid`, or hard-link topology.

A run with committed transaction units is not terminal merely because those
units are individually committed. The manifest records a strict run-level
completion marker only after fixed-point convergence, canonical report writing,
and all other run obligations succeed. Historical or interrupted journal state
without that marker blocks a later apply unless a verified full rollback proves
the older run is terminal.

Every completed scan and handled apply outcome writes a unique
`<command>-<run-id>.<extension>` file below the selected project's
`<project>/.flutter_pruner/reports/`. Self-contained HTML is the default, with a
JSON v3 payload embedded in the report. The terminal still renders the human
summary and highlights the resolved path after the complete result.
`--format`/`apply --report-format` select another representation;
`--output`/`apply --report-output` override the automatic destination. Relative
overrides remain contained below the report directory, while absolute
destinations remain supported.

## Interactive HTML report

An HTML report contains its CSS, JavaScript and schema v3 JSON data in one file,
with no remote fonts, scripts, images or network requests. It can be opened
offline and provides:

- status and coverage gates before any suggested apply command;
- a decision banner that distinguishes recovery, failed, partial, audit-only
  and dry-run-ready states without relying on color alone;
- tier counts, search, adapter/blocker/apply-outcome filters, stable finding
  links and expandable evidence for every finding;
- per-finding apply dispositions, transaction and rollback-verification facts;
- verification attempts with step-level availability, exit and duration facts;
- diagnostics, adapter, blocker, exclusion and typed-measurement views; and
- copyable safe CLI guidance, theme, JSON download and print controls.

The controls never execute shell commands. Recovery states deliberately do not
offer an automatic rollback command: inspect the canonical quarantine ledger and
transaction evidence before taking another action. Run any copied command in a
terminal after reviewing it. Reports retain absolute project and verification
paths for local audit identity, so review them before sharing the file outside
the team.

The workbench initially renders at most 100 matching findings, then exposes a
`Show more` control. Search and filters still operate on the full embedded
dataset, deep links expand their target even beyond the first batch, and print
temporarily renders the complete filtered result. The report uses system fonts,
contains no remote dependencies, preserves a static safety summary when
JavaScript is unavailable, and honors system dark-mode and reduced-motion
preferences.

## Top-level contract

| Field | Meaning |
|---|---|
| `version` | Schema version, currently `3` |
| `run` | Identity, UTC timestamps, monotonic elapsed time, status and exit code |
| `analysisCoverage` | Declared target matrix and root coverage used for classification |
| `execution.analysisPasses` | Initial, fixed-point rescan and final scan facts |
| `statistics.findings` | Counts by tier, reporting adapter, rule, node kind and reason |
| `statistics.measurements` | Typed, scoped quantities; rows are not implicitly additive |
| `statistics.blockers` | Recorded blockers, active unique blockers and affected findings |
| `statistics.exclusions` | Paths observed and rejected by the central path policy |
| `blockers` | Deduplicated blocker registry referenced by stable IDs from findings |
| `verificationAttempts` | Sanitized baseline, candidate and rollback verifier evidence |
| `apply` | Logical finding, physical action and transaction counters plus per-finding outcomes |
| `presentation.adapters` | Adapter-scoped labels, typed detail fields and measurement definitions captured for offline rendering |
| `findings` | Final finding set with reporting ownership and domain details |

Absolute project paths are retained where recovery/audit identity requires them.
Each file finding also includes `projectRelativeOrigin` for stable comparisons.
Verifier stdout, stderr, environment variables and raw command arguments are not
persisted in the report.

## Status and exit code

| Status | Exit | Meaning |
|---|---:|---|
| `completed`, `noChanges`, `dryRun` | 0 | Successful run or intentional no-mutation result |
| `safeStopped` | 2 | The apply run stopped safely; no mutation from this run was retained after verified rollback (or no mutation began), and applicable work may remain |
| `infrastructureFailure` | 1 | Configuration, verifier, hash or I/O precondition failed |
| `recoveryRequired` | 1 | Bytes or rollback verification need manual recovery |
| `internalError` | 70 | Unexpected tool error |

`partialApplied` is retained for JSON v3 compatibility. In current
all-or-nothing apply runs, it is **not** evidence that a previously committed
transaction remains in the working copy. When true, treat it as compatibility
evidence that the working-copy state may be uncertain and inspect the manifest
and transaction evidence before continuing. A `safeStopped` result (exit `2`)
means the run retained no mutation after verified whole-run rollback (or no
mutation began). `recoveryRequired`, and an internal failure with incomplete
recovery evidence, can leave the working copy uncertain.

## Counter domains

Never compare counters from different domains as if they represented the same
unit:

- `apply.findings` counts unique logical findings. A finding is counted once
  even when it appears across multiple analysis rounds.
- `apply.actions` counts physical mutation cases. Import cleanup, generated
  companions and empty-file deletion can make this larger than finding count.
- `apply.transactions` counts atomic SCC/shared-file units. A begun transaction
  must end in exactly one of `committed`, `rolledBackVerified`,
  `recoveryRequired`, or `nonTerminal`.
- `verificationAttempts` counts whole verifier invocations; each contains its
  configured step records.

Normal terminal runs have `transactions.nonTerminal == 0`. Auxiliary actions
never increment logical finding counters.

### Exact apply selection

`apply.selection` records the authorization boundary independently of finding
outcomes:

| Field | Meaning |
|---|---|
| `mode` | `allEligible` for historical full-scope apply, or `exact` for repeatable `--finding-id` values |
| `requestedFindingIds` | Sorted, case-sensitive CLI allowlist; empty only in `allEligible` mode |
| `plannedFindingIds` | Sorted logical findings admitted to the initial dependency-closed plan |
| `planFingerprint` | SHA-256 of the canonical initial logical and physical plan, or null when no plan was admitted |

Unknown IDs have no finding object, so they appear in selection evidence and a
selection diagnostic rather than a fabricated finding outcome. Known members
of an invalid batch receive a `remaining` outcome with a batch-level reason;
blocked members receive `blocked`. A successful exact run requires committed
transaction finding IDs to equal the requested set and the final scan to contain
none of those requested IDs at any confidence tier. Unselected findings remain
in the final `findings` array but do not affect exact convergence.

New V3 quarantine manifests persist the same selection mode, sorted requested
IDs, and plan fingerprint. Every transaction finding ID must be a subset of
that evidence. A completed exact journal must cover every requested ID;
malformed or legacy misplaced selection evidence fails closed. Older manifests
without this optional record remain readable under their historical rules.

### Per-finding apply outcomes

`apply.findingOutcomes` preserves the item-level result even when a committed
finding disappears from the final convergence scan. Each record includes a
finding snapshot, stable reason code, related nodes, and optional round and
transaction identity. Status values are:

| Status | Meaning |
|---|---|
| `committed` | The owning transaction passed verification and was committed |
| `rejectedRecovered` | The attempted transaction was restored and rollback-verified |
| `blocked` | The dependency-closed planner would not start the finding |
| `skippedDependency` | A retained or rejected dependency prevented the attempt |
| `remaining` | The finding was still applicable without a more specific disposition |
| `recoveryRequired` | Transaction bytes or rollback verification require manual recovery |

`rollbackVerified` is true only for a completed, verified restore under the
regular-file contract (bytes plus POSIX permission bits where available, not
xattrs, ACLs, `uid`/`gid`, or hard-link topology). The
`apply.findings.remaining` counter remains the canonical final-scan count and is
not derived by counting outcome rows, because a blocked or rejected finding may
also remain visible after convergence.

## Typed byte measurements

Schema v3 has no grand `totalSourceBytes`. Current measurement kinds include:

| Kind | Scope and semantics |
|---|---|
| `asset-family-source-bytes` | Unique declared asset families, including resolution variants |
| `duplicate-potential-reclaimable-bytes` | Bytes reclaimable only within detected duplicate groups |
| `dart-finding-source-bytes` | Source bytes attributable to Dart findings; often `unknown` |
| `apply.sourceBytesRemoved` | Net source bytes removed across unique touched paths in this run |

Every measurement includes `status`, `unit`, `scope`, `aggregation`,
`knownCount`, and `unknownCount`. `unknown` is not zero. Source bytes are not a
claim about AAB/IPA size; release artifact comparison remains the authority for
binary impact.

## Adapter ownership

Support adapters may execute without reporting findings. For example,
`--adapter assets` can execute Dart analysis to provide roots and declaration
reachability. Inspect `execution.analysisPasses[].adapters[].role` and
`.status`; use `finding.reportingAdapterId` for finding attribution.

### Adapter presentation catalogs

`presentation.adapters` is a snapshot of each participating adapter's
`reportDefinition`, with each entry identified by its raw adapter id. An entry
provides its display name;
for every reportable node kind, the raw rule id plus a finding title and node
label; typed detail-field labels; and adapter-scoped measurement labels and
units. HTML uses this embedded catalog, so it remains usable offline even if the
locally installed adapters later change.

The catalog is presentation metadata, not a policy extension point. Raw IDs
remain in findings, statistics, and measurements for stable machine processing.
Only the core can set classification reasons, confidence/safety predicates, or
action capability; an adapter definition cannot promote a finding to `SAFE` or
authorize apply. Rule ids remain audit identity rather than action authority;
built-in adapter and rule identities are reserved by the registry.

## CI selectors

Schema v3:

```bash
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' path/to/app/.flutter_pruner/reports/scan.json
```

Existing consumers can request schema v2 during one migration cycle:

```bash
flutter_pruner scan --project path/to/app --format json --json-version 2 --output scan-v2.json
jq -e '.summary.safe == 0 and .summary.high == 0' path/to/app/.flutter_pruner/reports/scan-v2.json
```

V2 preserves the historical selectors and ambiguous `totalSourceBytes` only for
compatibility. New integrations should use v3 typed measurements.

See the [report schema migration policy](report-schema-migration.md) for the
additive-change rules, compatibility window, and removal requirements.
