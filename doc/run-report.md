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

A mutating `apply` writes monotonic canonical snapshots below
`.flutter_pruner/quarantine/<run-id>/reports/objects/`. Each authoritative
snapshot is named `run-report-<sequence>.json` and is covered by an immutable
commit record. The quarantine manifest remains the canonical rollback ledger;
reports are observability projections and are never used to restore files.

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

Every completed scan and handled apply outcome writes a unique immutable report
object. Managed scan output uses `.flutter_pruner/reports/objects/` with its
authority record in `.flutter_pruner/reports/commits/`. Apply keeps monotonic
canonical JSON objects with the quarantine and exports the selected terminal
format separately. Self-contained HTML is the default, with a JSON v3 payload
embedded in the report. The terminal renders the human summary and highlights
the actual committed object path.
`--format`/`apply --report-format` select another representation;
`--output`/`apply --report-output` override the automatic destination. Relative
overrides remain contained below the report directory, while absolute
destinations remain supported. An exact override is single-assignment: both the
requested path and its adjacent hidden `<name>.commit.json` authority must be
absent. Flutter Pruner never overwrites either path.

A report becomes READY only after its object bytes have been flushed, reread,
hashed, recorded in a commit, and revalidated through retained directory and
file capabilities. Apply canonical JSON and its external export for one state
share one all-or-none batch commit. If export creation fails after mutation, a
later canonical-only sequence records that failure; earlier report objects are
never rewritten. A formatter, object, commit, close, or reachability failure may
leave immutable orphan artifacts, but cannot produce a valid READY result for
that incomplete batch.

## Legacy JSON v2 compatibility exports

Schema v2 is a compatibility format, not the default integration format. A v2
projection is checked before an immutable report object is created. It is
rejected when it would contain more than 250,000 blocker occurrences, more
than 2,000,000 affected-node-ID occurrences, or more than 100,000 affected
node IDs for any one blocker occurrence. The command returns a handled error
and leaves an existing requested output unchanged; it never truncates the
report or substitutes schema v3 for an explicit v2 request.

For accepted projections below those fixed limits, schema v2 keeps its legacy
compact bytes exactly, including key order, omission behavior, escaping, and
sorted affected-node-ID arrays. New consumers should select schema v3 instead:
it retains the deduplicated blocker registry and is not subject to the v2
compatibility projection limits.

Report persistence is append-only: it exclusively creates objects and commits
through native retained-directory capabilities and exposes no rename, replace,
delete, or restore operation. Existing regular files, empty files, links, and
other occupied destinations are collisions and remain unchanged. This is not a
sudden-power-loss durability claim: containing-directory metadata flushing is
not yet proven on every supported filesystem.

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
| `statistics.blockers` | Recorded blockers, active unique blockers, unbound unique blockers and affected findings |
| `statistics.exclusions` | Paths observed and rejected by the central path policy |
| `blockers` | Deduplicated blocker registry referenced by stable IDs from findings, plus final-pass blockers that could not attach to an inventoried node |
| `verificationAttempts` | Sanitized baseline, candidate and rollback verifier evidence |
| `apply` | Logical finding, physical action and transaction counters plus per-finding outcomes |
| `presentation.adapters` | Adapter-scoped labels, typed detail fields and measurement definitions captured for offline rendering |
| `findings` | Final finding set with reporting ownership and domain details |

Absolute project paths are retained where recovery/audit identity requires them.
Each file finding also includes `projectRelativeOrigin` for stable comparisons.
Verifier stdout, stderr, environment variables and raw command arguments are not
persisted in the report.

JSON is emitted in compact form because blocker-to-finding relationships can be
large. Field order and blocker-registry key order are deterministic, and exact
duplicate blocker facts share one stable registry entry and one ID per finding.
Use `jq` or another JSON viewer when an indented local view is needed.

`statistics.blockers.unboundUnique` counts final-pass blockers whose namespace
or explicit node scope matched no inventoried node. They remain in the top-level
registry even when `findings` is empty, so malformed source input cannot be
misreported as a clean inventory. Terminal output presents the same condition
as an analysis-limited warning.

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
