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

Reachability needs a starting set. Roots are nodes reachable from outside the
Dart call graph: `main()`, `@pragma('vm:entry-point')` annotations, plugin
background handlers registered by callback handle, platform-invoked entry
points.

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

So reachability is computed per target:

```text
R(target) = reachable( roots(target), edges whose condition applies to target )
```

and a node is dead only when it is dead everywhere:

```text
dead(node) ⟺ ∀ target ∈ targets : node ∉ R(target)
```

`unreachableAcrossAll` implements exactly that, and deliberately throws on an
empty target list rather than returning everything — with no targets the formula
is vacuously true for every node, which would be a maximally dangerous answer
delivered with full confidence.

`BuildCondition` carries platforms, flavors, entrypoints and **dart-defines**.
The last one is easy to overlook and matters: `--dart-define` values become
compile-time constants, `bool.fromEnvironment` folds, and whole branches vanish
before tree shaking runs. Code that is live under
`--dart-define=ENABLE_BETA=true` does not exist in the default build.

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

## Structurally empty Dart libraries

A Dart library with no declarations and no directives cannot expose an API or
perform work. An import/export edge pointing at such a file is treated as a
stale URI rather than liveness evidence. Apply removes the exact directive,
the empty source, and any generated part companions in one atomic quarantine
group. A verification regression restores every file in that group byte for
byte. Import-only or export-only libraries do not use this exception; they
must still be unreachable across all build targets before becoming `SAFE`.

Apply plans actionable nodes as a consumer-to-dependency graph. Strongly
connected components, plus actions touching the same physical path, form the
smallest commit/rollback unit. Units execute consumer-first. After verified
progress the graph is rebuilt; this fixed-point loop removes a source file or
stale import revealed by an earlier declaration edit in the same invocation.

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
