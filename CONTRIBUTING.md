# Contributing to Flutter Pruner

Contributions are welcome. The architecture was designed so that adding analysis
capability does not require touching the engine, and so that a first PR can be
small.

Flutter Pruner is `1.0.0` and solo-maintained. Built-in asset, duplicate-file,
and Dart declaration adapters are implemented. If you want to build something
substantial, open a draft PR or a discussion first so we do not duplicate work.

---

## Ways to contribute

**Add an analyzer adapter.** The main extension point — routes, DI, localization,
fonts. See [the walkthrough](doc/contributing/how-to-add-adapter.md).

**Add test fixtures.** A small project under `test/fixtures/` that exercises a
real edge case is genuinely valuable, and needs no engine knowledge. Dynamic
asset loading, deep links, custom plugin/background callback registries,
dart-define branches — if you have hit one in production, encode it.

**Reduce false positives.** If the tool reports something that is actually used,
that is the highest-priority class of bug. A failing test with a fixture is a
complete report.

**Fix documentation.** Especially [flutter-facts.md](doc/flutter-facts.md) — if a
claim there is out of date, that is a correctness bug, because adapters are built
on it.

---

## Reporting a bug

The one thing to always include: **Flutter and Dart version** (`flutter --version`)
plus a minimal reproduction.

For a false positive, say what the tool reported and how the thing is really
referenced. That second half is what makes it fixable.

---

## Development setup

Requires Dart SDK 3.9 or newer. Flutter is not required to work on the engine.

```bash
git clone https://github.com/nhan7777/flutter_pruner
cd flutter_pruner
dart pub get
dart test
```

Running against a real project:

```bash
cd /path/to/some/flutter/project
dart run /path/to/flutter_pruner/bin/flutter_pruner.dart init
# Review .flutter_pruner/config.yaml, especially targets and analysis mode.
dart run /path/to/flutter_pruner/bin/flutter_pruner.dart scan
```

`init` writes the project-local configuration; `scan` requires that reviewed
configuration and is read-only with respect to project source and assets.

---

## Read these first

Two documents will save you time, and reviewers will assume you have read them:

- [graph-model.md](doc/graph-model.md) — nodes, edges, conditional reachability,
  blockers. Explains why reachability is per build target.
- [confidence-model.md](doc/confidence-model.md) — the eight predicates gating
  `SAFE`, and why tiers rather than a score.

---

## The model, in short

There is **one** `GraphNode` class and **one** `GraphEdge` class. Domains are
distinguished by the `NodeKind` / `EdgeKind` enums and by an id scheme prefix, not
by subclassing:

```dart
graph.addNode(
  GraphNode(
    id: 'route:${project.packageName}:/product/:id',
    kind: NodeKind.route,
    origin: Uri.parse('route:${project.packageName}:/product/:id'),
    displayName: '/product/:id',
  ),
  producer: 'routes',
);
```

Do not create `RouteNode` or `NavigatesToEdge` classes. Equality is id equality,
which is what makes adapters idempotent — two adapters discovering the same asset
produce one node, and neither needs to know the other exists.

Node ids must be stable across machines: derive paths through
`project.relative(path)`, never absolute paths.

## Public API compatibility

Public report and adapter-presentation constructors defensively snapshot and
freeze collection inputs. Consequently, constructors that accept collections
are intentionally non-`const`. A source-breaking change to this public API
requires a future major release. `VerificationPolicy` is exported for API
callers.

`AdapterRegistry.builtIn` is runtime immutable. For a custom adapter set in a
test or integration, pass it explicitly instead of mutating that list:

```dart
final adapters = AdapterRegistry.resolve(
  adapters: [const AssetAdapter(), const MyAdapter()],
);
```

Only changes to Flutter Pruner's built-ins belong in the `builtIn` initializer.

---

## Code style

```bash
dart format --output=none --set-exit-if-changed .
dart analyze         # must be clean; --fatal-infos in CI
```

Beyond that, [Effective Dart](https://dart.dev/effective-dart). Public members
need doc comments (`public_member_api_docs` is on). Document what an adapter
**cannot** see, not just what it can — that tells the next maintainer which
missed findings are known limitations rather than bugs.

---

## Tests

Every adapter PR needs fixture-based tests covering four cases:

1. the thing **is** reported when genuinely unused
2. the thing is **not** reported when normally referenced
3. a dynamic reference produces a **blocker**, not a confident verdict
4. anything protected **stays** protected

Cases 3 and 4 are where cleanup tools actually fail, so a happy-path-only suite
will be sent back.

```dart
test('does not report an asset loaded through an interpolated path', () async {
  final project = await loadFixture('dynamic_asset');
  final graph = ReachabilityGraph();

  await const AssetAdapter().analyze(project, GraphBuilder(graph, 'assets'));

  expect(graph.blockersFor('asset:fixture:assets/icons/home.png'), isNotEmpty);
});
```

Note `GraphBuilder(graph, 'assets')` — the second argument is the producing
adapter's id, stamped onto everything written so bad findings are traceable to
their source.

Core engine changes need unit tests with hand-built graphs. No fixtures, no
`analyzer`, no resolution — core tests run in milliseconds and should stay that
way.

Bug fixes need a regression test that fails before the fix.

---

## Documentation conventions

Public documentation must be understandable without access to a maintainer's
machine or another repository.

- Use synthetic project, package, symbol, and asset names in examples.
- Do not include private project names, absolute local paths, temporary
  directories, CI run IDs, retained evidence locations, or local benchmark
  timings.
- Keep temporary implementation plans, personal work logs, and tool-specific
  instructions outside the repository.
- Describe product behavior and stable contracts; keep one-off release evidence
  in the release process rather than the roadmap or changelog.
- Verify every relative link and every documented CLI option before opening a
  pull request.
- Cite primary public sources for claims about Flutter, Dart, filesystems, or
  platform behavior.

Use sentence case for headings and keep code examples copyable. If a real-world
edge case matters, reduce it to a public fixture before documenting it.

---

## Pull requests

One task, one PR. Branch from `main`, use
[conventional commits](https://www.conventionalcommits.org/):

```text
feat: add RouteAdapter for go_router
fix: asset resolution variants reported as separate findings
docs: correct l10n synthetic package timeline
```

Then (use the non-mutating formatter check unless your change intentionally
needs formatting):

```bash
dart format --output=none --set-exit-if-changed .
dart analyze
dart test
```

CI runs format/analyze, package dry-run, a CLI smoke test, and the full suite on
the Dart 3.9 floor and `stable` Linux, plus `stable` macOS and Windows. The
matrix is configured to catch `package:analyzer` and platform-process breakage;
do not describe a platform as verified until its hosted job has executed.

Review looks for:

- stable, scheme-prefixed node ids
- `exact: true` only where a single target was genuinely resolved
- a blocker for every unresolvable dynamic construct
- fixtures covering the dynamic and protected cases
- no new `SAFE` path that bypasses a safety predicate

Draft PRs are encouraged. An early question costs a comment; a wrong approach
discovered late costs your week.

This is solo-maintained, so review is not instant. If a PR goes quiet for a while,
a ping is fine rather than rude.

---

## Rules that are not negotiable

These are all failure modes with real user cost:

1. **Never widen `SAFE` to make a test pass.** If something is genuinely safe, a
   predicate is computed wrongly — fix the computation. Otherwise it belongs in a
   lower tier.
2. **Absence of a runtime observation proves nothing.** A trace can prove use; it
   can never prove disuse.
3. **Protection outranks everything**, including zero references.
4. **Never delete generated output.** Change the input and regenerate.
5. **Report source bytes as source bytes.** Binary impact requires measuring the
   release artifact.
6. **Facts need sources.** A claim about Flutter behaviour in a doc or comment
   needs a primary-source URL.
7. **A recovery failure is not a partial success.** Preserve the whole-run
   baseline or surface `recoveryRequired`; do not leave a prior atomic unit
   presented as committed after a later run failure.
8. **Do not overstate path atomicity.** The implementation protects observed
   rename/recreation races with displacement and no-replace publication, but it
   has no directory `fsync`/`renameat2` durability protocol and cannot eliminate
   a microscopic open-FD append race. Preserve evidence and require recovery.
9. **Do not overstate rollback metadata.** The regular-file contract restores
   bytes and POSIX permission bits where available; it excludes xattrs, ACLs,
   `uid`/`gid`, and hard-link topology.

`BuildTarget` and `TargetMatrix` snapshot their public inputs defensively. Their
public API is governed by Semantic Versioning; source-breaking changes require a
future major release.

---

## Unclaimed work

Highest-impact adapters, none started:

- routes — `go_router`, `auto_route`, plain `Navigator`
- DI registrations — `get_it`, `injectable`, `riverpod`
- localization keys — ARB / `gen-l10n`
- unused font weights and variants

[ROADMAP.md](ROADMAP.md) has the current state. Comment on the relevant issue, or
open one, before starting something large.

---

## Code of conduct

Be respectful and constructive. Give specific feedback, ask clarifying questions,
assume good faith. Dismissiveness and condescension are not welcome regardless of
how correct the underlying point is.

---

## License

By contributing you agree your code is licensed under the MIT License.

---

## Questions

- [Discussions](https://github.com/nhan7777/flutter_pruner/discussions)
- [Issues](https://github.com/nhan7777/flutter_pruner/issues)
- [Architecture docs](doc/architecture.md)
