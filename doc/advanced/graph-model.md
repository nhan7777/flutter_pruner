# The graph model

Everything Flutter Pruner reports comes from one data structure: a directed
graph with conditional edges. This document explains why it is shaped that way,
because the shape is the reason the tool can be trusted with a `--fix` flag.

---

## Why a graph at all

The naive approach is per-domain search. Ask "is `logo.webp` mentioned
anywhere?", grep, report if not. That fails on real projects in three ways.

It cannot express indirection. `logo.webp` is referenced by
`brand_assets.dart`, which is referenced only by a widget nobody routes to. The
asset is genuinely dead, but every domain examined alone sees a live reference.

It cannot express conditions. `debug_overlay.dart` is referenced from real code
guarded by `kDebugMode`, so it ships in no release build. Whether it is dead
depends on which build you are asking about.

It cannot express cross-domain liveness, which is where most real waste lives:
an unrouted screen holding the only reference to a widget holding the only
reference to a 400 KB image, plus the localization keys that only that screen
renders. Delete the route and four other domains become dead — but only if you
can see the whole chain at once.

A graph handles all three, and gives one place to reason about safety instead of
one per domain.

---

## Nodes

A node is anything a user might want to delete: a Dart declaration, an asset, a
route, a DI registration, a dependency, a localization key. `NodeKind`
enumerates the current set.

Nodes are identified by a string id, and **equality is id equality** — nothing
else is compared. That makes adapters idempotent: two adapters discovering the
same asset produce one node, and neither needs to know about the other.

Ids follow a scheme prefix so they are readable in reports and never collide
across domains:

```text
dart:app/lib/home/home_page.dart#HomePage
asset:app/assets/images/logo.webp
route:app:/product/:id
di:app:PaymentService@stripe:prod
dep:app:package:dio
```

Two properties matter. Ids must be **stable** across machines and runs, so
paths are always relative with forward slashes — otherwise CI report diffing
produces noise on every platform change. And ids must be **precise enough to
distinguish things that are genuinely different**: `get<Api>()` and
`get<Api>(instanceName: 'mock')` are separate registrations, so the instance
name belongs in the id.

---

## Edges

An edge means "the source keeps the target alive". `EdgeKind` distinguishes how,
which is what makes reports explainable rather than just correct — `loadsAsset`
and `mayLoadAsset` are the difference between a finding and a warning.

Two fields carry the weight.

**Evidence** records how the edge was established, and specifically whether it
is `exact`. An exact edge resolved to exactly one unambiguous target via the
element model. A `symbolicPattern` edge from `'assets/flags/$code.png'` is not
exact: it proves *something* in that directory is used, without saying what.

**Condition** records when the edge applies. This is the field that makes the
model correct on real projects, and it is covered below.

Edges may reference nodes that do not exist yet. Adapters run in an order the
registry decides, and forcing every adapter to create both endpoints would make
them depend on each other. `danglingEdges` surfaces unresolved endpoints for
diagnostics instead.

---

## Roots

Reachability needs a starting set. A configured root is only a configured
application `main()` entrypoint. It is not one global root set: each one carries
the complete target tuple — `name`, `platform`, `flavor`, `entrypoint`, and
`dart_defines` — so it is evaluated only for that declared build.

Everything entered from outside that configured application entrypoint is a
separate **auxiliary execution target**: tests are `aux:test:`, VM/FFI pragma,
plugin/native, and platform-callback boundaries are `aux:runtime:`, and public
external-consumer surfaces are `aux:external:`. Their stable IDs are
domain-qualified and their environment is either complete or explicitly
incomplete. They contribute global retention but never masquerade as a
configured application target. A duplicate or conflicting auxiliary ID is an
integrity issue, not a second source of proof.

The asymmetry here is the single most important design fact in the project:

> A missing root produces a confident, wrong deletion.
> An unnecessary root produces a missed finding.

Those costs are not comparable. A missed finding is mild annoyance. A wrong
deletion silently breaks a push-notification handler that only fails in
production, on a subset of devices, days later. Adapters are therefore
instructed to be generous with roots, and reviewers do not object to a root that
looks unnecessary.

---

## Conditional reachability

A single global "is this reachable" boolean is wrong, because reachability
depends on what you are building. `flutter build apk --release --flavor prod`
and `flutter build web --profile` tree-shake differently and include different
code.

Conceptually, configured **proven** reachability is computed per target:

```text
P(target) = reachable( configured proven roots(target), exact edges applicable to target )
```

The corresponding configured-proven absence condition is:

```text
absentFromConfiguredProven(node) ⟺ ∀ target ∈ targets : node ∉ P(target)
```

The older `reachableFor`, `reachableForAll`, and `unreachableAcrossAll` APIs are
conservative compatibility projections over `legacyReachable`. They include
fail-closed retention and auxiliary influence, so they remain useful for legacy
consumers but cannot implement the conceptual proven formula, prove absence, or
authorize a finding/action. `unreachableAcrossAll` still rejects an empty
target list rather than returning every node: that legacy compatibility request
would otherwise be vacuously true and dangerously misleading. Current graph
and finding work reads `analyzeFor` snapshots: each exposes configured proven
and retained closures for the complete configured tuple, plus auxiliary proven
and retained closures for each exact auxiliary identity. Unknown or incomplete
facts expand retained closure; they never become proof that a node is absent.

`BuildCondition` carries platforms, flavors, entrypoints and **dart-defines**,
or an exact configured/auxiliary execution-target identity. Exact identities
are used for analyzer-resolved directive and execution-context facts; a broad
condition is never silently reused as proof for an auxiliary context. The last
one is easy to overlook and matters: `--dart-define` values become compile-time
constants, `bool.fromEnvironment` folds, and whole branches vanish before tree
shaking runs. Code that is live under `--dart-define=ENABLE_BETA=true` does not
exist in the default build.

The resolver knows SDK-owned `dart.library.io`, `dart.library.html`, and
`dart.library.js_interop` from the selected platform, plus explicitly declared
`dart_defines`. An unknown condition key, a missing value, or an incomplete
auxiliary environment selects every still-possible directive branch, records a
context blocker, and retains the affected closure. It cannot select a default
branch as exact evidence or make a candidate `SAFE`/`HIGH`.

---

## Blockers

A blocker records that something unresolvable could reach part of the graph.
`'assets/icons/$name.png'` means some file in that directory is used, and static
analysis cannot say which.

Blockers exist because two situations look identical to a naive tool and demand
opposite actions:

| Situation | Correct action |
|---|---|
| No reference exists | report it, safe to remove |
| A reference exists but could not be resolved | report it, do not remove |

Without blockers the second collapses into the first, and the tool confidently
deletes files that are loaded at runtime. This is the failure mode that makes
users distrust cleanup tools permanently, usually after exactly one incident.

Blockers are scoped. `affectedNamespace: 'assets/icons/'` covers one directory;
`affectedNodeIds` covers a specific set. A blocker with neither covers
**everything** and downgrades the whole run, so scoping is a review requirement
rather than a nicety.

That default is chosen deliberately. The alternative — an unscoped blocker
covering nothing — means an adapter author who forgets to scope one gets zero
protection while believing they added some. An over-broad downgrade is noticed
within one run; silent absent protection is noticed after a bad deletion.

A blocker does not veto a finding. It caps confidence and appears in the report
as the reason, so the user can look at the call site and decide what the tool
could not.

If a scoped blocker matches no inventoried node, the final report still retains
it as an unbound blocker and warns that the inventory may be empty or
incomplete. This is important for parse failures such as a duplicate ARB key:
zero nodes and zero findings are not evidence of a clean domain.

A blocked node is retained, so its outgoing dependencies are traversed as live.
The blocked node itself remains reportable as `REVIEW`; only its dependency
closure is excluded from automatic deletion. Otherwise a generated model could
be retained correctly while one of its source base classes was incorrectly
reported `SAFE`.

---

## Ownership, generated libraries, and empty libraries

Selected-package ownership is a graph boundary. A parent package scan does not
claim a nested package's sources are unused: nested, external, and unknown
owners are excluded from selected candidates and retained fail-closed. Scan
each package at its own root to make claims about that package.

A standalone generated library inside the selected package has a stable,
non-reportable `dart-generated:` artifact node. It becomes proven only through
a target-selected import/export or exact generated caller edge; discovering a
`.g.dart` file is provenance, not liveness. Generated parts remain represented
by their owning library. Unresolved generated callers use bounded blockers, so
they retain rather than create deletion authority.

An empty Dart library is not a stale URI override. It is handled exactly like
any other selected library: an exact configured or auxiliary path retains it;
an unreachable one is assessed by the ordinary all-context safety predicates.
This prevents an exported or target-conditional empty library from being
misclassified solely because it has no declarations.

---

## Protection

Protection is stronger than a blocker: a protected node is never
auto-deletable, regardless of reachability. Public API of a published package,
platform manifest entries, explicit user keep-rules.

Protection wins over everything, including a total absence of references. When
a node is both protected and unreachable, the report says "unreferenced, but
protected because …" — which is useful information, not a suppressed finding.
Like a blocked node, a protected node keeps its outgoing dependency closure
alive even while the protected node itself remains reportable.

---

## What graph policy does not do

Graph policy has no opinion about Flutter. It does not know what an asset is or
what `context.go()` means. Shared project loading reads `pubspec.yaml` and the
target/root config; domain interpretation remains in adapters.

That boundary is deliberate and load-bearing for the contribution model. The
engine can stay stable while the ecosystem-specific parts churn — and they will
churn, because `package:analyzer` makes breaking changes on a schedule of its
own choosing.

See [`confidence-model.md`](confidence-model.md) for how graph facts become a
tier, and [`architecture.md`](architecture.md) for how the pieces fit together.
