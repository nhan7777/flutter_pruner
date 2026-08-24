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
- Graph edge insertion uses the hash set's value lookup instead of linearly
  scanning every accepted edge before insertion. Duplicate identity and exact-
  evidence preference remain unchanged. A deterministic scaling benchmark
  exercises the growth gate and both duplicate insertion orders remain covered.
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
  cumulative execution-context discovery, directive resolution, per-context
  closure, graph emission, file enumeration, library resolution, AST visitor,
  session diagnostics, CLI diagnostics, and CLI-wait timings without adding
  stopwatch bookkeeping to ordinary scans.
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
- Graph replay observations: frozen AppFlowy and ServerBox detached worktrees
  can be scanned read-only with their project-matched Flutter/Dart SDKs and
  external report destinations. These observations record scanner output,
  toolchain/config/package-config identities, and before/after fingerprints;
  they are not an independent accuracy denominator or natural mutation test.
- Apply verification waves: each non-empty fixed-point round verifies and
  commits its ordered atomic units as one recoverable wave. A controlled v2
  A/A--A/B synthetic study admitted the default-on orchestration independently
  of analyzer-rescan work; details and scope follow below.

The measured Small fixture contains 200 Dart files, 30,000 LOC, 100 asset
files, and 5,000 graph-reference seeds. Three post-warmup samples measured
1.036 s, 1.212 s, and 1.792 s (median 1.212 s), producing 5,602 nodes and 5,400
edges. Raw samples are in
`benchmark/baselines/small-macos-arm64-dart-3.9.2.json`.

Only synthetic-fixture timing measurements are committed as performance
baselines. The V2 accuracy baseline contains classifications, corpus pins and
hashes but no real-project source, absolute path or timing threshold. See
`profiling.md` for the comparison and redaction protocol for local timing work.

### Apply verification-wave admission

The v2 admission study compared detached source materializations from
`df09c2c6e3dcdce978e30383af3b250df5829df7`: A included the analyzer auxiliary-
test boundary correction required by both sides, and B added only the apply
verification-wave patch. Flutter dependency hydration and AOT compilation were
outside the measured interval. Every measured sample used a fresh copy of the
same hydrated fixture, and each profile ran six counterbalanced `AB`, `BA`,
`AB`, `BA`, `AB`, `BA` pairs with three repetitions per block.

| Synthetic profile | Shape | Frozen A/A noise | Median paired change | Faster pairs | Admission |
|---|---:|---:|---:|---:|---:|
| `control-1x1` | 1 unit / 1 round | 4.91% | -0.43% | 3/6 | pass: regression within noise |
| `fanout-12x1` | 12 units / 1 round | 4.80% | +67.52% | 6/6 | pass |
| `chain-2plus-rounds` | 4 units / 2 rounds | 1.57% | +28.97% | 6/6 | pass |

The aggregate artifact is
`benchmark/baselines/apply-verification-wave-v2-attempt12-admission-macos-arm64-dart-3.13.1.json`
(SHA-256
`52acface5c420500d3a6a59bd1716efd25c6c2054cc6cec88d2c2bd9c07b5ce1`).
It binds the raw artifacts, A/B programs, harness, generator, boundary patch,
verification-wave patch, SDKs, apply arguments, and verification policy by
SHA-256. All correctness contracts, final source hashes, transaction sets,
round counts, and verifier invocation counts matched exactly. The structural
change is `1 + U` verifier invocations to `1 + R`, where `U` is the atomic-unit
count and `R` is the non-empty fixed-point-round count.

This admits the optimization for the three synthetic fixtures only. Runtime
benefit on a real project depends on verifier cost and units per round; no
universal percentage or memory claim is made. Analyzer-rescan performance is a
separate optimization and was not present in either side of this comparison,
so its measurements must not be added to these percentages. There is no
combined-candidate performance claim.

A local diagnostic, non-threshold GSY replay attributed the hash-lookup change
independently. The baseline was the clean tool commit
`080d7201a93de27e45a45766d40d8b7b0ff95fd0`; the candidate was that same
checkout with only the `_edges.lookup(edge)` production hunk applied. That hunk
was later committed in `ebcd89aec06946dd20596dbf5f2347256f801b4b`. The
candidate was not a clean checkout of `ebcd89a`, so these results are not exact-
commit release evidence.

The harness invoked the committed scan benchmark as follows for each tool root:

```text
dart run <benchmark-root>/run_invoice_benchmarks.dart \
  --tool-root <baseline-or-candidate-tool-root> \
  --output <empty-result-directory> \
  --snapshot gsy --gsy-root <gsy-worktree> --warmup 1 --iterations 3
```

The inner timed command used all registered adapters and
`--ignore-project-config`. The target was GSY commit
`2b6c49008afc44b90fee869dedf8e59a86482953` with package-config SHA-256
`c937b8f54ace4c4af46a5b9162e5dbf0622d40abe2d7299cc0ffad992561e4fd` and
lockfile SHA-256
`773a178e2cce166796e061af198d82a44320e934d6e6e5301668329ef686ad08`.
Both sides ran on the same MacBookPro18,3 (Apple M1 Pro, 8 cores, 16 GB),
Flutter 3.44.1 / Dart 3.12.1.

| Measurement | Baseline | Candidate | Change |
|---|---:|---:|---:|
| Analysis samples | 137.881, 127.442, 112.065 s | 106.130, 101.281, 101.543 s | — |
| Median analysis | 127.442 s | 101.543 s | -20.3% |
| Timed scan-benchmark user + system CPU time | 589.23 s | 480.10 s | -18.5% |
| Sampled process-tree average CPU | 114.22% | 111.01% | -3.21 pp |
| Sampled process-tree peak CPU | 323.2% | 293.8% | -29.4 pp |
| Observed process-tree peak RSS | 2,538.625 MiB | 2,002.016 MiB | -21.1% |

Timed CPU covers the inner scan benchmark, one warm-up, three measured samples,
report construction, and descendants; it excludes outer harness orchestration
and its `ps` sampler. Process-tree CPU/RSS was sampled every 200 ms; CPU may
exceed 100% when multiple cores are active. Every measured sample retained
exactly 932 nodes, 24,489 edges, 3,510 blockers, 186 findings, and identical
per-adapter node/edge/blocker counts. No graph/finding fingerprint was captured,
so the replay is supporting diagnostic evidence rather than an independent
accuracy proof or a committed release threshold; deterministic semantic
regression tests remain the acceptance gate.

The corrected O3/O4 graph-oracle admission gates now pass their regression and
independent-review evidence. This does not turn graph replay scans into an
independent natural accuracy denominator: no refreshed confusion matrix,
false-positive total, or deletion authority is claimed until the separate O7
one-to-one grading is accepted. Scanner findings remain observations rather
than ground truth.

## Deferred after feasibility review

- Context-indexed directive closure: a deterministic profile counter confirms
  that candidate-edge examinations currently grow quadratically with context
  count (16x work when contexts scale 4x in the fixed-topology benchmark). The
  experimental index reduced that counter to linear growth, but the pinned GSY
  replay regressed median analysis by 7.9% versus hash lookup alone and raised
  peak RSS slightly. The representation-preserving experiment was reverted.
- Real-project apply/rollback timing on GSY: the controlled declaration fixture
  is retained by incomplete runtime/test auxiliary contexts and has active
  dynamic blockers, so current HEAD correctly classifies it as REVIEW and
  refuses mutation before verification. No apply timing is claimed. Creating a
  benchmark number by suppressing those facts would weaken the fail-closed
  contract; apply/rollback correctness remains covered by the controlled test
  suite until an independently apply-eligible real-project fixture exists.

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
