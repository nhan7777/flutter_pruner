# V2 natural-accuracy replay

This replay evaluates finding-level accuracy for the V2 route and localization
adapters against independent exhaustive static oracles. It is a correctness
benchmark, not a scan-time or memory benchmark.

The retained replay ran on Flutter Pruner commit
`7dc495b5699d6afe6fc18828ea81964042e28f5e` with Dart 3.9.2 on macOS arm64.
That commit contains the behavior change in `f461cb8`; its later test-formatting
commit does not alter runtime code. The compact machine-readable record is
[`benchmark/baselines/v2-natural-accuracy-7dc495b.json`](../../benchmark/baselines/v2-natural-accuracy-7dc495b.json).

## Result

| Corpus | Adapter | Cases | TP | TN | FP | FN |
|---|---|---:|---:|---:|---:|---:|
| Smooth App | l10n | 1,780 | 323 | 1,457 | 0 | 0 |
| Smooth App | go_router | 19 | 0 | 19 | 0 | 0 |
| GSY normalized-equivalent | l10n | 403 | 17 | 386 | 0 | 0 |
| GitJournal | l10n | 419 | 38 | 381 | 0 | 0 |
| **Overall** | | **2,621** | **378** | **2,243** | **0** | **0** |

The three graded scans reported 378 findings. Every finding remained `REVIEW`;
`SAFE=0` and `HIGH=0`. The replay therefore measures finding precision and
recall without implying apply eligibility.

The pre-fix oracle exposed 11 Smooth localization false negatives and 11 Smooth
route false positives. Application-reachable consumer filtering recovered the
localization keys that were referenced only from tests or unreachable library
code. Local path-wrapper/static-value tracing, redirects and child-to-parent
retention removed the incorrect route findings.

## Corpus identity

| Project | Repository commit | Config SHA-256 | Package-config SHA-256 | `pubspec.lock` SHA-256 |
|---|---|---|---|---|
| Smooth App | `bac71afd115f72e379c0b501b95e5ede20ecd636` | `59dc83948c3ef90c91199af0e520c487c8cac801e1cad46adad6fc3a4c53256d` | `e80ccea81376c9e7a62ff416fad89cfe04097b3267c5b1246595a77f424457d0` | `7c72596202e74900ea8e12a61209ac5bde02522440847d1f6c8940df28b4a260` |
| GSY | `2b6c49008afc44b90fee869dedf8e59a86482953` | `088014c7fc747e62ba52e705374da2e6fb12aea87fa4f0cdd9a0d3935d916beb` | `aa95a1403db9d9bd434addd133a13702a05bc9688fab255301066cb7c489fa95` | `cbacadbd02cc4c5bc957767b7383dc16281736e9cdfb902493f406a06292824f` |
| GitJournal | `c8a67e098db06335762f822d7733c330f4bd0d6b` | `9da39c1fee335715130cfcfd9c3b056277c0597694ab5de21857177fa98a96d5` | `b2546f98c441ccef9ef9239294cf623b5db86cfb32c6738a1fe34977ab3417d9` | `64232187946cd795ddb6b1ae85d8bd538de0d65601f4f4fb5d3fea090c67d4dd` |

The repositories were cloned from:

- `https://github.com/openfoodfacts/smooth-app.git`
- `https://github.com/CarGuo/gsy_github_app_flutter.git`
- `https://github.com/GitJournal/GitJournal.git`

## Oracle contract

The l10n oracle enumerates every template ARB message, maps exact generated
members back to Dart references, and resolves the local-package import closure
from configured entrypoints. Candidate-unused sets were validated by removing
them in a reversible fixture, regenerating localization output and running the
project analyzer. Smooth App also produced a debug application bundle after all
323 confirmed-unused keys were removed. Templates and generated outputs were
then restored and checked.

The route oracle independently enumerates every `GoRoute`, composes constant
paths, and traces direct navigation, `AppRoutes`, local path wrappers, redirects
and nested parents. The oracle does not treat absence of a runtime observation
as proof of non-use.

The four oracle SHA-256 values are retained in the baseline JSON. The raw
oracles, grader, scan reports and mutation evidence live in the external
benchmark workspace and are intentionally not copied into this package. A
reader can verify identity from hashes, but cannot regenerate the oracle from
this repository alone. This is an explicit evidence boundary, not a claim of a
self-contained benchmark.

## Replay shape

With the external oracle workspace available, each project is scanned using its
pinned `flutter_pruner_v2_accuracy.yaml`:

```bash
dart run bin/flutter_pruner.dart scan \
  --format json \
  --output /tmp/<project>-scan.json \
  --adapter l10n \
  --config /path/to/<project>/flutter_pruner_v2_accuracy.yaml \
  --project /path/to/<project>
```

Smooth App adds `--adapter go_router`. The external grader compares the same
scan report separately with its l10n and route oracles. Before and after every
scan, the replay captures `git status --porcelain` and sorted SHA-256 values for
all ARB files.

For this retained run, all three project status snapshots and all ARB hash lists
were byte-identical before and after scanning. The Flutter Pruner checkout was
also unchanged. No finding was applied.

## Malformed-input check

The original GSY template contains a duplicate top-level key and is not used for
accuracy grading. The normalized-equivalent input removes the earlier duplicate
entry while retaining the effective later value. A separate scan of the
original input produced zero findings but retained two unbound l10n blockers:
the duplicate ARB key and analyzer failure for the configured generated output.
Terminal output reported `ANALYSIS LIMITED`; it did not present the empty
inventory as clean.

## Limits

- The metric is static application compile-removability, not device runtime
  coverage or proof about external consumers.
- `GetIt` is not scored because none of the pinned project snapshots supplied a
  suitable natural inventory.
- The result is tied to the exact source, project, config, lock and oracle hashes
  above. It is not a floating claim about newer project revisions.
- Raw scan durations are not performance results and are not used as release
  thresholds.
