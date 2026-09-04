# Architecture

Flutter Pruner is a small stable engine plus a set of replaceable adapters. This
document explains the layering and, more usefully, why the boundaries are where
they are.

---

## Layers

```text
┌─────────────────────────────────────────────┐
│  bin/flutter_pruner.dart                    │  process entry, exit codes
├─────────────────────────────────────────────┤
│  lib/src/cli/                               │  commands, flags, output
├─────────────────────────────────────────────┤
│  lib/src/adapters/                          │  ← contributions land here
│    registry.dart      ordering              │
│    analyzer_adapter.dart  the contract      │
│    <domain>/          assets, routes, di…   │
├─────────────────────────────────────────────┤
│  lib/src/core/                              │  ← changes rarely
│    graph/       nodes, edges, reachability  │
│    confidence/  predicates, findings        │
│    project/     pubspec, targets, paths     │
└─────────────────────────────────────────────┘
```

Dependencies point downward only. Graph/confidence policy is domain-neutral;
the shared project layer owns `pubspec.yaml`, target/root declarations and the
verification policy used by both scan and apply.

---

## Why graph policy knows nothing about Flutter domains

The graph/confidence layer has no concept of an asset or route. It handles
nodes, edges, conditions and reachability. Reading project configuration is a
shared service; interpreting Flutter asset or framework semantics stays in
adapters.

This is not abstraction for its own sake. It follows from one prediction about
where change comes from:

`package:analyzer` makes breaking changes on its own schedule, and its element
model is explicitly not a stability guarantee. Flutter ships four stable
releases a year, each potentially changing asset handling, manifest formats or
build behaviour. The ecosystem churns hardest at exactly the point where the tool
touches it.

Reachability over a conditional graph, by contrast, is settled computer science.
It will not need to change.

So the boundary is drawn to keep churn out of the part that must stay stable.
When `analyzer` 9 breaks the element model, the fix is contained to adapters. If
the engine imported `analyzer`, every such release would be a rewrite.

The practical consequence for contributors: the engine has no `analyzer`
dependency, so core tests run in milliseconds with no resolution and no fixture
projects.

---

## How a scan runs

```text
ProjectContext.load()      read pubspec, resolve build targets
        │
AdapterRegistry.resolve()  filter by appliesTo, topologically sort
        │
for each adapter:          adapter.analyze(project, GraphBuilder)
        │                    ↳ nodes, edges, roots, blockers
        │
graph.unreachableAcrossAll(targets)
        │
ConfidenceClassifier      hard gates + explicit manual risks
        │
Finding                    tier + evidence + blockers + why-not-safe
        │
AnalysisSnapshot           graph, adapter, timing and exclusion metrics
        │
RunReport                  lifecycle + typed statistics
        │
reporter                   human or JSON
```

One graph, built by every applicable adapter, then queried once. Not one pass
per domain — that would lose the cross-domain chains that make the tool worth
running.

---

## GraphBuilder: why adapters cannot write directly

Adapters receive a `GraphBuilder`, not the graph. The builder wraps the graph
with the adapter's `producerId` and stamps it onto everything written.

That gives provenance for free. When a finding is wrong, the report says which
adapter produced the edge. Without it, debugging a bad deletion means bisecting
adapters by hand.

It also keeps the write surface small — `addNode`, `addEdge`, `addReference`,
`addRoot`, `protect`, `addBlocker`, `evidence`. An adapter cannot reorder
reachability or reach into another adapter's nodes, so a bad adapter degrades its
own domain rather than corrupting the run.

---

## Adapter independence

`dependsOn` stays empty when an adapter does not need another adapter's graph
facts included in the final selected graph or read during analysis. An adapter
that emits edges from Dart callers declares `dependsOn: ['dart']`, so a filtered
scan includes the Dart support it needs.

The registry topologically sorts and rejects cycles. Keep dependencies narrow:
the graph accepts future endpoints, so endpoint creation order alone does not
require a dependency. Dependencies select or order adapters only when their
facts must be included or read.

Independence is achievable because the graph is the integration point. The asset
adapter creates `asset:app/assets/logo.webp` because it read `pubspec.yaml`. The
Dart adapter creates an edge to that same id because it resolved
`AssetImage('assets/logo.webp')`. Neither knows the other exists; ids do the
joining. Order does not matter, because edges may point at nodes that do not
exist yet.

---

## CLI shape

The CLI selects one project per invocation. `--project <path>` anchors
configuration, reports, quarantine, and recovery; without it, the current
directory is selected. `init`, `scan`, and `apply` also accept one positional
project path for compatibility. `init` creates the reviewable
`<project>/.flutter_pruner/config.yaml`. In an interactive terminal it builds an
in-memory draft through an always-visible, numbered analysis-mode choice with a
conservative detected default, followed by yes/no-first questions. It writes
nothing until final confirmation. The terminal presentation groups the draft
into spaced sections and uses semantic ANSI color and text weight when the
terminal supports them, while preserving icon-and-label cues without color.
Scripted runs remain flag-driven and never read stdin. It starts
with `target_matrix.complete: false`; `init --complete` is an explicit
project-owner assertion after reviewing every target. It never asserts
external-consumer coverage. Reusable and hybrid projects auto-detect as
`package`; `package-internal` must be selected explicitly.

Application target discovery consumes native Android flavor and shared iOS
scheme entrypoint mappings as concrete `(platform, flavor, entrypoint,
dart-defines)` tuples. It does not generate a Cartesian product. Ambiguous,
missing, or conflicting metadata prevents an automatic completeness claim;
conditional Dart imports/exports are a non-owner-resolvable blocker until the
graph models their target conditions. Config source paths are validated below
the CLI so both the wizard and hand-edited YAML enforce project containment,
reject symlinks/generated/part files, and validate the expected Dart role.

`scan` and `apply` require a valid preferred, legacy, or explicit configuration
and never invoke `init` themselves. A missing config exits `1` with a contextual
init command. Apply additionally requires complete analysis coverage before it
starts analysis, including in dry-run mode. `package` is always scan-only.
`package-internal` records `externalConsumersCovered: false`; eligible HIGH
mutations require `[y/N]` confirmation or `--yes` when non-interactive.

`scan` is read-only with respect to the selected project's source and assets. It
has no mutation path for findings; its only write is the tool-owned audit report.
Users evaluating a deletion tool on a real codebase need source immutability to
be a structural guarantee rather than a promise, so finding mutation lives in a
different command entirely.

Every completed scan and handled apply outcome writes a unique run-ID report
under `<project>/.flutter_pruner/reports/`; format and path options only override
the defaults. Apply quarantines mutations under
`<project>/.flutter_pruner/quarantine/<run-id>`. Configuration discovery still
reads a legacy root `flutter_pruner.yaml`; rollback and quarantine management
use the same selected project and also read
`<project>/.flutter_pruner_quarantine` recovery data. An ambiguous
legacy/current run ID requires an explicit `--quarantine` path.

Exit codes are meaningful, because CI is a first-class use case:

| Code | Meaning |
|---|---|
| 0 | scan completed, or apply reached a clean fixed point |
| 1 | configuration/verifier/hash/recovery failure |
| 2 | apply safely stopped with applicable findings remaining |
| 64 | usage error (`EX_USAGE`) |
| 70 | internal error |

`scan` reports findings but returns `0` when analysis succeeds. CI consumers
should evaluate JSON tiers explicitly. `apply` uses `2` for a safe stop or
no-progress outcome and reserves `1` for infrastructure or recovery failures.

## Apply transactions

`scan` and `apply` call the same `ProjectAnalyzer`. Apply then builds a
dependency-closed SCC plan, snapshots all touched paths and requires the exact
configured verifier policy for baseline, candidate and rollback checks.
Manifest V3 records atomic-unit/round IDs, accepted verification-wave evidence,
policy hash, required and observed step IDs, and a terminal `committed`,
`rolledBackVerified`, or `recoveryRequired` state. Within each non-empty round,
apply journals every ordered transaction as applied, verifies the combined
candidate state once, then commits the entire accepted wave through one journal
revision. A rejected or unavailable wave causes the whole run to be restored to
its original baseline before the rollback verifier runs. For a regular file,
that rollback contract covers captured bytes and POSIX permission bits where the
platform exposes them. A verified rollback ends as `safeStopped` (exit `2`) with
no mutation retained; an unverified restore leaves `recoveryRequired` evidence
for manual recovery.
`partialApplied` remains a schema-v3 compatibility signal for an uncertain
working-copy state, not a claim that a safe stop retained earlier commits.
Apply rescans until no applicable finding remains.

For a regular-file mutation, apply moves the original path into quarantine,
prepares the candidate away from the project path, then publishes it with
no-replace semantics. Restore first displaces the current path into recovery
staging and publishes the original snapshot through the same no-replace
boundary. If a path is recreated or its hash changes at an observed boundary,
both copies are retained and the ledger becomes `recoveryRequired`; the tool
does not overwrite the recreated path.

Quarantine clean uses a separate recoverable logical-move protocol. It anchors
the quarantine base, writes immutable intent revisions, and moves each exact
run into `.clean-retained/v1` through native no-replace operations. Restart
reconciliation distinguishes an exact not-moved intent, an exact retained
tree, and ambiguous drift; only the first two can terminalize automatically.
Restore revalidates the complete retained tree digest before the same native
boundary moves it back. Release admission binds these production artifacts to
exact-SHA hosted `renameat2`, `renameatx_np`, and NTFS conformance evidence.

These are path-race protections, not a claim of crash-durable filesystem
atomicity. The current implementation does not `fsync` directories, use
`renameat2` durability semantics, or eliminate a microscopic concurrent
open-file-descriptor append after the path checks. A power loss or adversarial
writer in those gaps must be treated as manual recovery territory.

Rollback is not a general metadata-preservation protocol. It intentionally does
not restore xattrs, ACLs, `uid`/`gid`, or hard-link topology; callers requiring
those properties need a filesystem-aware backup or version-control recovery.

The quarantine manifest is the canonical recovery ledger. `RunReport` is its
observability projection: useful for CI, audit and trend analysis, but never a
source from which rollback reconstructs bytes. Logical findings, physical file
actions, transactions and verifier attempts are separate counter domains so an
auxiliary import cleanup cannot be mistaken for another finding.

JSON output is a supported interface, not a debug dump. It is what CI diffing,
editor integrations and dashboards consume, so it changes under the same
compatibility expectations as the Dart API.

Every project traversal uses one `ProjectPathPolicy`. It prunes tool-owned
quarantine/report/config state, build and dependency caches, editor/agent state,
symlinks and paths outside the declared root. The policy and its observed
exclusions are versioned in the run report; adapters do not maintain independent
directory blacklists.

---

## Testing strategy

Core is unit-tested with hand-built graphs — no fixtures, no `analyzer`, no
resolution. Adapters are tested against fixture projects under
`test/fixtures/`, each exercising one behaviour.

Every adapter must cover four cases: the thing is found when unused, **not**
found when referenced, produces a blocker when the reference is dynamic, and
stays protected when protected. The last two are where cleanup tools actually
fail, and where a "happy path only" test suite gives false comfort.

CI runs the test matrix on the minimum supported Dart SDK and on `stable`. The
matrix exists specifically to catch `analyzer` breakage early, which is the
predicted failure mode described above.

---

## Where to go next

- [`graph-model.md`](graph-model.md) — nodes, edges, conditional reachability
- [`confidence-model.md`](confidence-model.md) — hard gates, explicit risks and tiers
- [`flutter-facts.md`](flutter-facts.md) — verified framework behaviour, with sources
- [`contributing/how-to-add-adapter.md`](contributing/how-to-add-adapter.md) — the practical walkthrough
