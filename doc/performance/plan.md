# Performance evaluation and optimization plan

This document defines the current performance roadmap for Flutter Pruner. It
supersedes the original architecture-only estimates: measured evidence is
authoritative, and no optimization may weaken the fail-closed safety model.

Implementation details and completed work are tracked in
[`status.md`](status.md). Contributor commands and the result-sharing policy are
in [`profiling.md`](profiling.md).

## Goals

- Keep scan and apply analysis semantically identical.
- Improve wall time and memory without dropping diagnostics, blockers, roots,
  target conditions, generated-code evidence, or verification boundaries.
- Make every performance claim reproducible with a public synthetic fixture.
- Prevent benchmark artifacts from exposing private projects or local-machine
  information.

## Measurement contract

Performance changes must be evaluated with:

1. the same Dart SDK and dependency resolution;
2. the same machine, power mode, fixture, adapters, and command arguments;
3. at least one warmup and three measured iterations;
4. median, minimum, maximum, and every raw sample;
5. node, edge, blocker, and finding-count equivalence for performance-only
   changes;
6. a non-profiled final comparison, because `--profile` adds instrumentation.

The committed Small baseline is generated entirely by
`tool/generate_perf_fixture.dart`. Medium, Large, and XL fixtures are generated
on demand so large source trees are not stored in Git.

## Current architecture

```text
ProjectAnalyzer
  ├─ shared AdapterServices
  │    └─ DartAnalysisWorkspace
  │         ├─ sorted Dart-file inventory
  │         └─ resolved-library future cache
  ├─ DartAdapter
  │    ├─ semantic declarations and references
  │    └─ lint-inclusive CLI diagnostics overlapped with semantic work
  ├─ AssetAdapter
  │    └─ reuses the shared DartAnalysisWorkspace
  ├─ DuplicateAdapter
  │    └─ size grouping, then streaming SHA-256 for collision groups
  ├─ ReachabilityGraph
  │    ├─ incoming and outgoing edge indexes
  │    ├─ blocker indexes
  │    └─ mutation-invalidated target analysis cache
  └─ FindingGenerator
```

## Completed optimizations

| Area | Current implementation | Safety invariant |
|---|---|---|
| Analyzer workspace | Dart and asset adapters share one workspace and resolution cache | Resolution failures still create blockers |
| CLI diagnostics | Starts before semantic analysis and is awaited before findings are finalized | Lint-only diagnostics remain available; failure still blocks |
| Graph queries | Incoming edges and blockers are indexed; target analysis is cached until mutation | Public query results remain immutable snapshots |
| Duplicate hashing | Files are grouped by size before streaming SHA-256 | Only byte-identical files share a digest group |
| Asset hashing | File content is streamed | Digest semantics are unchanged |
| Path traversal | Cheap lexical exclusions precede expensive filesystem work | Canonical boundary checks remain fail closed |
| Diagnostic parsing | File content and line metadata are cached per source | Diagnostic IDs and offsets remain unchanged |
| Instrumentation | Total, adapter, finding, and Dart subphase timings are available | Profiling is opt in and does not affect normal scans |

## Decisions from profiling

### Keep lint-inclusive CLI analysis

Direct `package:analyzer` sessions do not provide the complete project lint
execution path. Removing `dart analyze --format=machine` would lose lint-only
diagnostics such as `avoid_unused_constructor_parameters`. The subprocess is
therefore overlapped with semantic work instead of removed.

### Do not parallelize AST visitors with `Future.wait`

AST visitors are synchronous and execute in the current isolate. Wrapping them
in futures does not create CPU parallelism. A combined visitor is justified
only after a public synthetic profile shows traversal is a material bottleneck
and the combined implementation preserves every reference and blocker fact.

### Do not queue every analyzer resolution concurrently

Analyzer 12 routes `getResolvedLibrary` requests through one
`AnalysisDriver` scheduler in the current isolate. Queueing hundreds of futures
does not make that CPU work parallel and can retain resolved libraries while
per-unit diagnostic requests wait behind the queue. Any new strategy must be
bounded and benchmarked for peak memory as well as wall time.

### Keep graph metadata immutable

Deferring or disabling metadata freezing would change a public correctness
contract. Batch mutation is not accepted without a synthetic benchmark showing
a material graph-construction bottleneck and tests proving that caller-owned
metadata cannot mutate graph state.

## Next work

### P1: Stable public baselines

- Run Small, Medium, Large, and XL fixtures on a designated reference machine.
- Record Dart version, processor count, warmups, samples, graph counts, and peak
  RSS.
- Define regression thresholds only after variance is known across repeated
  runs.

### P1: Semantic resolution investigation

- Measure cold cache, warm operating-system cache, and analyzer byte-store
  behavior separately.
- Count library, part, generated, excluded, cache-hit, and failed resolution
  requests.
- Prototype bounded prefetch only if analyzer scheduling evidence supports it.
- Reject any design that changes diagnostics or increases unresolved coverage.

### P2: Duplicate-heavy fixture

- Add deterministic distributions for unique sizes, same-size unique content,
  large duplicate groups, and large individual files.
- Measure bytes read, hash count, wall time, and peak RSS.
- Consider a bounded long-lived isolate pool only when hashing dominates.

### P2: Persistent incremental analysis design

Persistent caching remains deferred until the cache format includes complete
invalidation evidence for:

- source content and analysis options;
- package config and analyzer/Dart versions;
- imports, exports, parts, conditional directives, and generated inputs;
- unresolved-reference facts and source-scoped blockers;
- target matrix, root coverage, path policy, and adapter versions;
- corruption detection and an atomic fallback to a full scan.

A stale cache must never turn incomplete evidence into `SAFE`.

## Acceptance gates

An optimization is ready only when all applicable gates pass:

- `dart format --output=none --set-exit-if-changed .`
- `dart analyze --fatal-infos`
- `dart test --concurrency=1`
- `dart pub publish --dry-run`
- unchanged graph/finding aggregates for performance-only changes
- benchmark median improves outside normal run-to-run variance
- no new absolute paths, private identifiers, raw target reports, or source data
  in committed artifacts
- documentation and changelog describe stable behavior, not one-off local
  investigation details

## Privacy rules

Synthetic fixtures are the only benchmark inputs suitable for committed raw
results. Benchmark output redacts the project path by default. The
`--include-project-path` option is for local troubleshooting only.

For private workloads, contributors may report a high-level conclusion in a
review, but must reproduce the bottleneck with a synthetic fixture before
adding numbers to the repository. Never commit target source, asset names,
package names, symbols, diagnostics, finding IDs, report paths, user names, host
names, or absolute paths.

## Public references

- [Dart analyzer package](https://pub.dev/packages/analyzer)
- [Dart DevTools](https://dart.dev/tools/devtools)
- [Dart formatter](https://dart.dev/tools/dart-format)
- [Flutter Pruner architecture](../architecture.md)
- [Flutter Pruner graph model](../graph-model.md)
