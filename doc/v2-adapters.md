# V2 adapter behavior

This document describes the shipped behavior of the V2 adapters. It is an
as-built contract, not the original task plan. The graph and confidence engine
remain domain-neutral; every V2 adapter emits evidence and blockers through the
same adapter API used by the earlier analyzers.

All three V2 finding kinds are review-only. They have no deterministic inverse,
do not expose an apply action, and cannot become `SAFE` or `HIGH`.

| Adapter | Finding rule | Graph node | Exact consumer-use edge |
|---|---|---|---|
| `go_router` | `PRN-ROUTE-001` | `route` | `navigatesTo` |
| `get_it` | `PRN-DI-001` | `diRegistration` | `resolves` |
| `l10n` | `PRN-L10N-001` | `localizationKey` | `references` |

Each adapter declares `dependsOn: ['dart']`. A filtered scan therefore runs the
Dart adapter as support so V2 references always originate from modeled caller
nodes instead of becoming dangling graph edges.

## Application-reachable consumer closure

Route and localization declarations are inventoried across the selected
package, but their Dart consumers come from one pass-shared analyzer-resolved
execution snapshot. It holds per-target configured proven/retained paths and
per-context auxiliary proven/retained paths; `globalUsageUnitPaths` is their
retained union. The closure is package-config aware and includes part units.

Exact test, runtime, and external consumers contribute global usage. An
incomplete auxiliary context stays retained with its context blocker rather
than becoming an unused route/key. Sources owned by a nested package are not
selected candidates in a parent scan; scan that package separately.

The closure is used as an exclusion boundary only when the relevant evidence is
complete. A missing entrypoint, unresolved local directive, analyzer resolution
failure, unknown conditional environment, or incomplete auxiliary context
retains the possible branch and emits a domain-scoped blocker. This fallback
can add review work, but it cannot silently manufacture an unused result.

`GetIt` does not currently apply this application-closure filter. Its open
runtime/container model already keeps supported findings review-only and emits
blockers around unsupported lookup state.

## Routes (`go_router`)

The route inventory recognizes analyzer-resolved `GoRoute` constructors,
constant `path:` and optional constant `name:` values. Nested `GoRoute` paths
are composed by segment, and a reachable child retains its enclosing `GoRoute`
through a graph edge. `ShellRoute` is traversed but does not become a graph node
or contribute a path segment; a nested `GoRoute` therefore attaches to its
nearest enclosing `GoRoute`, when present.

Exact navigation evidence includes:

- direct resolved `go`, `push`, `replace`, and `pushReplacement` calls;
- direct resolved named variants such as `goNamed` and `pushNamed`;
- path arguments forwarded directly through a resolved local method wrapper;
- constant fields, getters and expression-bodied helpers used to build paths;
- constant interpolation, concatenation, adjacent strings and route patterns;
- a statically known path with a runtime query portion; and
- return values from `redirect:` callbacks on `GoRoute` or `GoRouter`.

Local wrapper tracing is deliberately path-only. A wrapper that forwards a
route name into `goNamed` or another named API is not modeled as an exact named
reference. Dynamic receivers, opaque locations, ambiguous route patterns,
generated callers, unresolved declarations and external deep-link channels
emit scoped blockers instead of liveness evidence.

## Dependency injection (`GetIt`)

The adapter models direct registrations and exact lookups on analyzer-resolved
base-scope `GetIt` containers. Registration identity includes the resolved Dart
type and an optional constant instance name. Supported factories and singleton
forms share that identity, and an exact lookup emits a `resolves` edge from its
Dart caller to the registration.

Multiple containers, runtime or dynamic receivers, non-constant instance names,
scope APIs, generated `Injectable` wiring, and unsupported registration shapes
remain uncertainty boundaries. Generated-wiring probes add protection/blocker
evidence; they do not claim to reproduce the runtime container state. Generated
Dart provenance is not usage by itself: only a modeled artifact chain or exact
caller edge can retain an observed declaration.

## Localization (`gen-l10n`)

The adapter reads `l10n.yaml` and the configured template ARB file, then maps
message keys to getters or methods on the current real-source generated output
under `lib/`. `@key` metadata and locale markers are not message nodes. Exact
resolved accessor calls and property reads from the complete application
consumer closure retain their matching ARB keys.

Duplicate top-level keys, locale-only messages, malformed metadata, stale or
missing generated siblings, generated-output analyzer errors, ambiguous member
shapes and custom runtime lookup APIs emit blockers. A parse failure that
produces no localization nodes is still reported as an unbound blocker; zero
findings is not presented as a clean inventory.

## Reporting and evidence boundaries

JSON schema v3 records unbound final-pass blockers in the top-level blocker
registry and exposes their count as `statistics.blockers.unboundUnique`. The
terminal renders the same condition as `ANALYSIS LIMITED` and suppresses clean
guidance.

The V2 accuracy replay covers natural `go_router` and localization declarations
in three public projects. It does not measure `GetIt`, device runtime behavior,
or external consumers. See
[`performance/v2-natural-accuracy.md`](performance/v2-natural-accuracy.md) for
the exact corpus pins, oracle contract and retained result.

## Regression-test map

- `test/adapters/go_router_adapter_test.dart`
- `test/adapters/go_router_route_path_test.dart`
- `test/adapters/go_router_deep_link_probe_test.dart`
- `test/adapters/get_it_adapter_test.dart` and `test/adapters/get_it/`
- `test/adapters/l10n_adapter_test.dart` and `test/adapters/l10n/`
- `test/cli/formatters/json_formatter_test.dart`
- `test/cli/formatters/human_formatter_test.dart`
- `test/core/reachability_graph_test.dart`
