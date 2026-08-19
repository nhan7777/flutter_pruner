# Evaluation and optimization implementation status

This status records the executable subset of [`plan.md`](plan.md). Estimated
impact in the original plan was treated as a hypothesis; changes below preserve
the fail-closed safety model and are covered by regression tests.

## Implemented

- Baseline tooling: deterministic generators for Small, Medium, Large, and XL;
  a repeatable JSON scan benchmark; profiling instructions; and one measured
  Small baseline on macOS arm64 with Dart 3.9.2.
- Phase timing: the existing run-report contract already records total and
  per-adapter `elapsedMicros` plus node, edge, and blocker deltas. The benchmark
  consumes that contract instead of printing a second JSON stream from the
  analyzer.
- Graph indexes: incoming edges are indexed by target node. Blockers are
  indexed for registered graph nodes, with the previous semantic fallback kept
  for arbitrary IDs that are not registered.
- Graph caching: retained and reachable sets are computed together once per
  complete build-target fingerprint and invalidated after graph mutation.
- Shared semantic workspace: Dart and asset adapters reuse one
  `AnalysisContextCollection`, one sorted Dart-file inventory, and one
  resolved-library future per path. The adapter API remains source-compatible
  through a default `analyzeWithServices` hook.
- Duplicate I/O: candidates are grouped by file size before hashing and only
  collision groups are hashed. SHA-256 consumes file streams instead of loading
  the largest file into one allocation. Asset inventory hashing is streaming as
  well. Quarantine integrity checks also stream file bytes so their peak
  allocation does not scale with the largest transaction file.
- Path fast path: lexical exclusions run before filesystem syscalls. Traversals
  using `followLinks: false` reuse the known entity type and do not repeat
  canonical resolution for every ordinary file.
- Diagnostic source cache: repeated machine diagnostics in one source file
  reuse file content and `LineInfo`.
- Dart subphase profiling: `benchmark/scan_benchmark.dart --profile` records
  cumulative file enumeration, library resolution, AST visitor, session
  diagnostics, CLI diagnostics, and CLI-wait timings without adding overhead to
  ordinary scans.
- Benchmark output redacts the analyzed project path by default. Contributors
  must opt in with `--include-project-path` for local-only troubleshooting and
  must not publish that output unchanged.
- JSON v3 report construction and serialization are measured separately from
  analysis. `--max-report-overhead-percent` makes the median overhead ceiling an
  executable release gate.
- JSON v3 caches each stable blocker ID once, lazily projects the sorted blocker
  registry and findings during encoding, and omits presentation whitespace.
  A dedicated synthetic benchmark reproduces high blocker-to-finding fan-out.
- Exact duplicate blockers are discarded before graph indexing. Retention uses
  a source-node work queue instead of rescanning every blocker at each fixed-
  point iteration; missing-source blockers remain unconditionally active.
- Concurrent lint diagnostics: the lint-inclusive `dart analyze` process starts
  before semantic graph construction and is awaited before diagnostic nodes are
  committed. This preserves the fail-closed lint contract while overlapping
  independent read-only work.
- V2 natural-accuracy replay: a compact SHA-pinned result records exhaustive
  oracle grading across Smooth App, GSY and GitJournal. This is a correctness
  replay, not a performance threshold; see
  [`v2-natural-accuracy.md`](v2-natural-accuracy.md).

The measured Small fixture contains 200 Dart files, 30,000 LOC, 100 asset
files, and 5,000 graph-reference seeds. Three post-warmup samples measured
1.036 s, 1.212 s, and 1.792 s (median 1.212 s), producing 5,602 nodes and 5,400
edges. Raw samples are in
`benchmark/baselines/small-macos-arm64-dart-3.9.2.json`.

Only synthetic-fixture timing measurements are committed as performance
baselines. The V2 accuracy baseline contains classifications, corpus pins and
hashes but no real-project source, absolute path or timing threshold. See
`profiling.md` for the comparison and redaction protocol for local timing work.

## Deferred after feasibility review

- Medium, Large, and XL baseline execution: the generator is available, but
  this run has no designated reference machine or accepted CPU/RAM/time budget.
  Recording those numbers on an arbitrary machine as release thresholds would
  be misleading.
- `SemanticUnitSummary` and persistent incremental cache: analyzer elements,
  conditional branches, generated-source facts, unresolved references, and
  source-scoped blockers form dependency-sensitive safety evidence. A per-file
  DTO without a complete invalidation graph can reuse stale evidence and create
  false `SAFE` results. This requires a separate cache-format and corruption /
  invalidation design before implementation.
- Removing `dart analyze`: direct `package:analyzer` usage does not provide the
  project's full lint execution path. The subprocess is already skipped when
  no `analysis_options.yaml` exists; removing it otherwise would lose
  diagnostics rather than merely improve performance. It now overlaps semantic
  resolution instead of extending the critical path sequentially.
- Parallel or merged AST visitors: Dart visitors execute on the same isolate,
  so wrapping them in futures does not create CPU parallelism. Publish a
  synthetic profile showing a meaningful traversal bottleneck before revisiting
  a combined visitor.
- Concurrent `getResolvedLibrary` calls: analyzer 12 queues requested libraries
  through one `AnalysisDriver` scheduler in the current isolate. `Future.wait`
  does not make its CPU work parallel and can retain hundreds of resolved
  libraries while per-unit diagnostics wait behind that queue. A bounded,
  measured analyzer architecture is required before changing resolution order.
- Batched graph mutation: current profiles do not show metadata freezing as a
  material bottleneck. Deferring it would weaken graph immutability without a
  reproducible synthetic benchmark demonstrating a meaningful gain.
- Same-run global file inventory cache: path-exclusion observations are reset
  per analysis pass and reported as safety evidence. Reusing an inventory
  without replaying those observations would make later apply rounds report a
  different boundary.
- Isolate hashing and graph/report parallelism: the current benchmark does not
  show duplicate hashing as the dominant Small-profile phase. Per-file isolate
  startup and graph serialization can cost more than they save. Add a
  duplicate-heavy benchmark and a bounded long-lived worker design before
  enabling concurrency.
- Committing generated fixture trees: XL expands to 30,000 files across Dart
  and assets. Fixtures are generated into an explicit empty directory to keep
  repository size and test checkout time bounded.
