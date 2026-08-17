# Performance profiling

This guide is the contributor contract for reproducible and shareable
performance evidence. Prefer generated fixtures for committed baselines. Real
projects may be used locally, but their identity, paths, source-derived names,
diagnostics, and raw reports must not enter the repository.

Use the benchmark runner to collect repeatable phase timings from the same
reporting path as `scan`:

```bash
dart run benchmark/scan_benchmark.dart \
  --project /path/to/project \
  --warmup 1 \
  --iterations 5 > benchmark-result.json
```

The JSON field `project` is `<redacted>` by default. The local-only
`--include-project-path` flag emits the absolute path for troubleshooting; do
not use it for output that will be committed, attached to an issue, or pasted
into a pull request.

Add `--profile` to include cumulative Dart-adapter subphase timings in each
sample. This mode measures file enumeration, library resolution, declaration
and reference visitors, unresolved-reference indexing, session diagnostics,
the lint-inclusive CLI analyzer, and the final wait for that process:

```bash
dart run benchmark/scan_benchmark.dart \
  --project /path/to/project \
  --only dart \
  --warmup 0 \
  --iterations 1 \
  --profile
```

Profiling adds Stopwatch bookkeeping and is intended for bottleneck diagnosis,
not release thresholds. Use an ordinary non-profiled run for before/after wall
time comparisons.

Every ordinary benchmark sample also measures JSON v3 report construction and
serialization as `reportElapsedMicros`, `reportBytes`, and
`reportOverheadPercent`. A release gate can enforce a median ceiling:

```bash
dart run benchmark/scan_benchmark.dart \
  --project /tmp/flutter_pruner_perf_small \
  --iterations 3 \
  --max-report-overhead-percent 10
```

Use the dedicated synthetic fan-out benchmark when blocker relationships, not
project analysis, dominate report cost:

```bash
dart run benchmark/json_report_benchmark.dart \
  --findings 500 \
  --blockers 1000 \
  --warmup 1 \
  --iterations 3
```

It constructs no source fixture and emits only aggregate counts, elapsed
samples, and report bytes. Keep findings, unique blockers, and
`blockerFindingLinks` identical when comparing serializer revisions.

Generate a synthetic profile outside the repository, then benchmark it:

```bash
dart run tool/generate_perf_fixture.dart \
  --profile small \
  --output /tmp/flutter_pruner_perf_small
dart run benchmark/scan_benchmark.dart \
  --project /tmp/flutter_pruner_perf_small \
  --iterations 3
```

Profiles are `small`, `medium`, `large`, and `xl`. Generated fixtures are not
committed because the largest profile contains 10,000 Dart files and 20,000
assets. Keep the generated directory and hardware fixed when comparing changes.

## Comparison protocol

1. Use the same Dart version, machine, power mode, fixture, adapter selection,
   warmup count, and iteration count for both revisions.
2. Run at least one warmup and three measured iterations for release evidence.
3. Compare medians and retain every raw sample; do not compare only each run's
   fastest value.
4. Confirm node, edge, blocker, and finding counts are unchanged when the change
   is intended to affect performance only.
5. Use `--profile` to locate a bottleneck, then use a non-profiled run for the
   final wall-time comparison.

`--ignore-project-config` constructs a generic application context for
benchmarking a project whose Flutter Pruner config cannot be loaded. It does
not prove coverage or finding safety. Never present findings from such a run as
actionable scan results.

## Sharing results safely

Before sharing benchmark JSON, verify that it contains none of the following:

- absolute paths, user names, host names, repository names, or package names;
- source file names, symbols, diagnostic messages, finding IDs, or report paths;
- dependency names or configuration values that identify a private product;
- source, assets, generated reports, or `.flutter_pruner` state from the target.

Share the command shape, tool revision, Dart version, processor count, fixture
profile, iteration policy, elapsed samples, and aggregate graph counts. For a
private workload, publish a reduced synthetic fixture that reproduces the
bottleneck instead of committing the raw result.

For CPU sampling with DevTools:

```bash
dart --observe bin/flutter_pruner.dart scan --format json
```

Open the printed VM service URL in Dart DevTools and record the CPU profile.
For process-level wall time and peak RSS, wrap the normal CLI on macOS:

```bash
/usr/bin/time -lp dart run bin/flutter_pruner.dart scan --format json
```

On Linux, use `/usr/bin/time -v`. Store the Dart version, processor count,
project revision, fixture profile, warmup count, and every raw sample with the
result; cross-machine numbers are not directly comparable.
