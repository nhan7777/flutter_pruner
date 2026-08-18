# How to add an analyzer adapter

An adapter teaches Flutter Pruner about one domain. Assets, routes, dependency
injection and localization are each an adapter. Adding one is the main way to
extend the tool, and it does not require touching the engine.

Budget roughly a day for a first adapter, most of it spent on edge cases rather
than on the happy path.

---

## The mental model

The engine builds one graph and asks a single question per build target:

> starting from the roots, what can I reach?

Anything unreachable is a candidate for removal. Your adapter's job is to put
the right nodes and edges in that graph so the answer is correct.

```text
     roots ──edge──> node ──edge──> node
                       │
                    blocker  ← "something unresolved could reach this"
```

Four things you contribute:

| You add | Meaning | Effect |
|---|---|---|
| **Node** | a thing that could be unused | becomes reportable |
| **Edge** | "A keeps B alive" | makes B reachable from A |
| **Root** | an entry point | reachability starts here |
| **Blocker** | an unresolved dynamic construct | lowers confidence |

The asymmetry to internalise: **adding a node risks a false positive, adding an
edge or root risks a missed finding.** Missing a finding annoys someone. A false
positive deletes their production callback. When unsure, add the root.

---

## Step 1 — Decide what your nodes are

Ask: what is the smallest thing a user would want to delete?

For routes it is a route path, not the widget behind it (the widget will be
handled by the Dart adapter). For DI it is a registration, keyed by type *and*
instance name *and* scope, because `get<Api>()` and
`get<Api>(instanceName: 'mock')` are different registrations.

Pick a node id scheme prefixed with your adapter id, and keep it stable across
runs and machines:

```text
route:app:/product/:id
di:app:PaymentService@stripe:prod
l10n:app:checkout_button_label
```

Use `project.relative(path)` for anything path-derived. Absolute paths differ
between machines and break report diffing in CI.

---

## Step 2 — Write the adapter

Copy [`adapter-template.dart`](adapter-template.dart) into
`lib/src/adapters/<your_domain>/`.

```dart
class RouteAdapter extends AnalyzerAdapter {
  const RouteAdapter();

  @override
  String get id => 'routes';

  @override
  String get name => 'Route analyzer (go_router)';

  @override
  AdapterReportDefinition get reportDefinition =>
      const AdapterReportDefinition(
        adapterId: 'routes',
        displayName: 'Route analyzer (go_router)',
        description: 'Finds routes that have no semantic navigation path.',
        findings: [
          AdapterFindingReportDefinition(
            nodeKind: NodeKind.route,
            ruleId: 'PRN-ROUTE-001',
            title: 'Unused route',
            nodeLabel: 'Route',
            description: 'A route with no path from the configured roots.',
            measurementKind: 'route-source-bytes',
            details: [
              AdapterReportDetailDefinition(
                key: 'path',
                label: 'Route path',
                valueType: AdapterReportDetailValueType.path,
                description: 'The application path registered for this route.',
              ),
            ],
          ),
        ],
        measurements: [
          AdapterReportMeasurementDefinition(
            kind: 'route-source-bytes',
            label: 'Route source size',
            unit: 'bytes',
            description: 'Source bytes associated with the route definition.',
          ),
        ],
      );

  @override
  Set<String> get findingNodeSchemes => const {'route'};

  @override
  bool appliesTo(ProjectContext project) =>
      project.hasDependency('go_router');

  @override
  Future<void> analyze(ProjectContext project, GraphBuilder graph) async {
    // 1. Declare nodes for each route you find.
    // 2. Add edges for each navigation call site.
    // 3. Protect routes reachable from outside the app.
    // 4. Record blockers for navigation you could not resolve.
  }
}
```

`appliesTo` returning `false` is normal and cheap — most projects will not use
most adapters.

### Define report presentation alongside the adapter

`reportDefinition` is the adapter-owned presentation catalog. It declares the
adapter display name, each reported node kind's stable rule id, finding title,
node label, typed metadata fields, and any adapter-scoped measurements. Use
`AdapterReportDetailValueType` to describe the actual metadata value:
`text`, `integer`, `boolean`, `bytes`, `path`, or `paths`. The registry checks
that the definition identity matches `id` and `name`, and rejects duplicate
node kinds, rule ids, detail keys, and measurement kinds.

Set `measurementKind` on a finding definition when its `GraphNode.sizeBytes`
should be projected under one of the declared measurement definitions. A
measurement definition supplies report semantics and labels; it does not
estimate bytes or authorize an action.

These labels are local to the adapter. They are an additive presentation layer:
the raw adapter id, rule id, node kind, metadata key, and measurement kind
remain the stable wire codes. Schema v3 snapshots the catalog at
`presentation.adapters` so an HTML report can render it offline without
consulting the installed adapter registry.

This contract cannot change analysis or apply policy. Adapters still contribute
nodes, edges, roots, protections, and blockers through `GraphBuilder`; the core
alone decides reachability, confidence tier, classification reasons, safety
predicates, and action capability. In particular, an adapter label or rule must
never make a finding `SAFE` or authorize a mutation. Rule ids are reporting
identity only and are not inputs to the core action-capability decision. The
registry also reserves the built-in adapter ids and rule ids, so a contributor
cannot impersonate an `assets`, `duplicates`, or `dart` capability.

---

## Step 3 — Resolve references semantically, not textually

This is the difference between this tool and a grep script, so it is worth doing
properly.

Do **not** search for the string `"/product/"` across the repo. That matches
comments, test fixtures, changelogs and unrelated strings. Instead resolve the
invocation through the analyzer and confirm it really is the API you care about,
then evaluate the argument.

Mark evidence `exact: true` only when you resolved a single unambiguous target.
A pattern match is not exact:

```dart
// Exact: one constant string, one target.
graph.addReference(
  from: callerId,
  to: 'route:${project.packageName}:$literalPath',
  kind: EdgeKind.navigatesTo,
  evidence: graph.evidence(
    kind: EvidenceKind.constString,
    description: "context.go('$literalPath')",
    exact: true,
    location: location,
  ),
);

// Not exact: interpolated, so it protects candidates but proves nothing.
graph.addBlocker(
  reason: 'route path built from a non-constant expression',
  location: location,
  affectedNamespace: '/product/',
);
```

---

## Step 4 — Handle the dynamic cases honestly

Every domain has constructs static analysis cannot resolve. Enumerate them
deliberately and record a blocker for each. The failure mode to avoid is
concluding "no reference found, therefore dead" when the real situation is
"I could not see the reference".

Read [`doc/flutter-facts.md`](../flutter-facts.md) before writing this part.
It lists the verified hazards: deep links activating routes with no in-app
caller, plugin background handlers invoked through opaque callback handles,
`--dart-define` changing which branches exist, string-identified platform
channels and FFI symbols.

Scope blockers when you can. `affectedNamespace: 'assets/flags/'` protects a
directory; a blocker with no namespace protects everything and makes the tool
useless.

---

## Step 5 — Add fixtures and tests

A fixture is a small project under `test/fixtures/<name>/` that exercises one
behaviour. Fixtures are excluded from analysis, so they can be deliberately
messy.

```text
test/fixtures/unused_route/
  pubspec.yaml
  lib/
    main.dart      declares /home and /unused, navigates only to /home
```

Test the positive case, the negative case, and the dynamic case:

```dart
test('reports a route with no navigation call site', () async {
  final project = await loadFixture('unused_route');
  final graph = ReachabilityGraph();

  await const RouteAdapter().analyze(project, GraphBuilder(graph, 'routes'));

  expect(graph.hasNode('route:fixture:/unused'), isTrue);
  expect(graph.incomingTo('route:fixture:/unused'), isEmpty);
});

test('does not report a route reachable by deep link', () async {
  final project = await loadFixture('deep_link_route');
  final graph = ReachabilityGraph();

  await const RouteAdapter().analyze(project, GraphBuilder(graph, 'routes'));

  expect(graph.isProtected('route:fixture:/product/:id'), isTrue);
});
```

At minimum, cover:

- the thing is found when genuinely unused
- the thing is **not** reported when referenced normally
- a dynamic reference produces a blocker rather than a confident verdict
- anything protected stays protected

---

## Step 6 — Register it

Add your adapter to `AdapterRegistry.builtIn` in
`lib/src/adapters/registry.dart`:

```dart
static final List<AnalyzerAdapter> builtIn = <AnalyzerAdapter>[
  const AssetAdapter(),
  const RouteAdapter(), // <- here
];
```

Registration has three parts: implement `id`/`name`, provide a matching
`reportDefinition`, and add the adapter to `AdapterRegistry.builtIn`. Override
`findingNodeSchemes` only when the stable graph-node scheme is different from
the adapter id. The registry validates every built-in definition before it
filters or orders adapters, so invalid report metadata cannot be hidden by an
`--adapter` selection.

---

## Step 7 — Open the pull request

```bash
dart format .
dart analyze
dart test
```

Then open a PR. A draft PR with a rough approach and a question is welcome — it
is much cheaper to redirect an approach early than after a week of work.

Review looks for:

- nodes have stable, scheme-prefixed ids
- `exact: true` only where a single target was genuinely resolved
- dynamic constructs produce blockers
- fixtures cover the dynamic and protected cases, not just the happy path
- no new `SAFE` path that skips a safety predicate

---

## Protection patterns and framework wiring

Some classes appear unused in static analysis but are actually instantiated by
frameworks at runtime. Your adapter should protect these where applicable.

### When to Add Protection

Add protection when:
1. **Framework registration** — the class is registered in a DI container, router,
   or state manager via annotations or naming conventions
2. **Generated code references** — build_runner generates code that references the
   class, but that reference won't appear in the graph yet
3. **Reflection or opaque callbacks** — the framework finds classes via
   string names, annotations, or runtime inspection

### Pattern-Based Protection

The Dart adapter uses suffix-based heuristics for common patterns:

```dart
// In declaration_visitor.dart
String? _frameworkProtectionReason(String name) {
  if (name.endsWith('Module')) {
    return 'DI module — registered via @module annotation';
  }
  if (name.endsWith('Bloc') || name.toLowerCase().endsWith('bloc')) {
    return 'BLoC state manager — registered via BlocProvider';
  }
  return null;
}
```

### Limitations of Pattern Matching

These are **heuristics**, not guarantees. They fail when projects use:
- Different naming conventions
- Non-English names
- Typos or abbreviations
- Different architectural patterns entirely

Document the patterns you protect and their limitations clearly. Users must
understand that `SAFE` findings still require review when their codebase uses
uncommon conventions.

See [`doc/confidence-model.md`](../confidence-model.md#framework-protection-rules)
for the full list of built-in patterns.

---

## Rules that are not negotiable

These exist because the cost of violating them is someone's broken production
build:

1. **Never widen `SAFE` to make a test pass.** Add a tier or a blocker.
2. **Absence of a runtime observation proves nothing.** A trace can prove use;
   it can never prove disuse.
3. **Protection outranks everything**, including a total absence of references.
4. **Never delete generated output directly.** Change the input and regenerate.
5. **Report source bytes as source bytes.** Binary impact requires measuring the
   release artifact.

---

## Where to look for examples

`DuplicateAdapter` is the smallest complete example: one node kind and no
analyzer use.

`AssetAdapter` is the reference for semantic resolution: inventory, exact
reference resolution, bounded string evaluation and scoped blockers.

`GoRouterAdapter` is the reference for a third-party framework. It resolves a
package API through the element model, composes a derived identity (the full
route path), and blocks its whole namespace when external route channels make
absence-of-reference meaningless. It also demonstrates the ordering rule:
declare `dependsOn: ['dart']` when edges start at Dart declarations, and never
emit an edge to a node no adapter contributes. One dangling edge downgrades
every finding in the run.
