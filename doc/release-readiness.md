# Release readiness

Release readiness is evidence-based. Passing unit tests is necessary, but a
cleanup tool also needs clean-tree replay, real-project fail-closed evidence,
and a reproducible reporting-overhead measurement.

## Automated repository gates

Run from the Flutter Pruner repository:

```bash
dart run tool/verify_release_blockers.dart --run-tests
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
dart pub publish --dry-run
dart run bin/flutter_pruner.dart scan \
  --adapter dart \
  --format json \
  --output self-scan.json
jq -e '
  .run.status == "completed" and
  .statistics.findings.byTier.SAFE == 0 and
  .statistics.findings.byTier.HIGH == 0
' .flutter_pruner/reports/self-scan.json
```

The local `--run-tests` mode validates retained artifacts and runs the required
tests for the current platform, but it is not release admission. Hosted CI
collects clean-path evidence independently from Linux, macOS, and Windows plus
the Windows report-capability artifact, then invokes the verifier with both
`--hosted-evidence-dir` and `--expected-commit`. The default admission mode
fails closed when any required exact-SHA artifact is absent, stale, duplicated,
skipped, or platform/filesystem mismatched.

For `CLEAN-TOCTOU-1`, the Linux artifact exercises the production `renameat2`
boundary, macOS exercises `renameatx_np`, and Windows exercises NTFS
no-replace behavior. Every platform also replays all durable-journal hard-exit
points and the retained restore collision contract. Passing the ordinary full
suite without these separately generated artifacts cannot admit a release.

The Windows evidence must prove object identity, not that NTFS always rejects a
directory rename. A retained handle may remain usable after its pathname moves;
the safe contract is that relative operations still target that retained object
and path revalidation rejects any replacement directory. Existing regular,
directory, and reparse leaves must all remain non-clobbering collisions.

Hosted CI remains the authority for the supported Dart floor and stable Linux,
macOS, and Windows matrix.

## V2 adapter accuracy gate

A release that changes route, GetIt, localization, graph-blocker, or V2 report
behavior must either reproduce the external natural-project oracle or prove
that those production paths are unchanged from the retained behavior commit:

```bash
git diff --exit-code f461cb8f44165cd0df09427ae0a813ad243ae5b3..HEAD -- \
  lib/src/adapters/dart/dart_application_reachability.dart \
  lib/src/adapters/go_router \
  lib/src/adapters/get_it \
  lib/src/adapters/l10n \
  lib/src/analysis/analysis_snapshot.dart \
  lib/src/cli/formatters/human_formatter.dart \
  lib/src/cli/formatters/json_formatter.dart \
  lib/src/core/graph/reachability_graph.dart \
  lib/src/reporting/run_report.dart
jq -e '
  .kind == "v2-natural-accuracy" and
  .overall.confirmedCases == 2621 and
  .overall.falsePositives == 0 and
  .overall.falseNegatives == 0 and
  .overall.reviewFindings == 378 and
  .overall.safeFindings == 0 and
  .overall.highFindings == 0
' benchmark/baselines/v2-natural-accuracy-7dc495b.json
```

The retained accuracy replay covers natural `go_router` and localization
declarations, not GetIt or device runtime behavior. Keep that evidence boundary
visible in release notes instead of generalizing the zero-error result. See
[`performance/v2-natural-accuracy.md`](performance/v2-natural-accuracy.md).

## Report-overhead gate

Generate a reproducible synthetic workload outside the repository, then fail
the benchmark when median JSON v3 report construction and serialization exceed
10 percent of analysis time:

```bash
dart run tool/generate_perf_fixture.dart \
  --profile medium \
  --output /tmp/flutter_pruner_release_fixture
dart run benchmark/scan_benchmark.dart \
  --project /tmp/flutter_pruner_release_fixture \
  --ignore-project-config \
  --warmup 1 \
  --iterations 3 \
  --max-report-overhead-percent 10
```

Use the same machine, Dart version, power mode, fixture, and iteration policy
when comparing releases. Do not commit private-project benchmark output.

## Three-project safety replay

`tool/verify_real_projects.dart` requires at least three project roots. It runs
JSON scan plus apply dry-run, asserts fail-closed tiers whenever coverage is
incomplete, accepts the expected package-mode apply refusal, and proves that
tracked project state is unchanged. Raw reports stay in the selected output
directory and can contain private identifiers; keep that directory outside the
repository.

```bash
dart run tool/verify_real_projects.dart \
  --project /path/to/project-a \
  --project /path/to/project-b \
  --project /path/to/project-c \
  --config /path/to/project-a-config.yaml \
  --config /path/to/project-b-config.yaml \
  --config /path/to/project-c-config.yaml \
  --output-dir /tmp/flutter_pruner-real-project-replay
```

The summary uses only `project-1`, `project-2`, and `project-3` labels. Do not
commit the raw reports or project-specific configurations.

## Mutating replay and rollback

Actual apply must run only on a disposable clean copy with a reviewed complete
application boundary. It is intentionally not automated against arbitrary real
project paths:

```bash
flutter_pruner scan --format json --output before.json
flutter_pruner apply --dry-run
flutter_pruner apply
flutter_pruner scan --format json --output after.json
flutter_pruner quarantine list
flutter_pruner rollback <run-id>
git diff --exit-code
```

Acceptance requires a fixed point with no remaining applicable `SAFE`, a
manifest recording complete policy-matched verification, byte restoration, and
an unchanged clean tree after rollback. Preserve the manifest and sanitized
summary as release evidence; never commit private paths, symbols, or reports.
