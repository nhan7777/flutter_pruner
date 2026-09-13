#!/usr/bin/env bash
# Benchmark: end-to-end scan analysis time on a deterministic synthetic
# fixture. Prints METRIC lines; exits non-zero on failure or when the
# graph/finding shape drifts from the pinned expectation (correctness guard).
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || dirname -- "$SCRIPT_DIR")"
cd "$REPO_ROOT"

PROFILE="${BENCH_PROFILE:-medium}"
WARMUP="${BENCH_WARMUP:-1}"
ITERATIONS="${BENCH_ITERATIONS:-3}"
FIXTURE_ROOT="${BENCH_FIXTURE_ROOT:-/tmp/flutter_pruner_benchmark}"
FIXTURE="$FIXTURE_ROOT/$PROFILE"
RESULT="$FIXTURE_ROOT/$PROFILE-result.json"

# Pinned expected shape per profile (nodes edges blockers findings).
case "$PROFILE" in
  small)  EXPECT="5602 5600 0 200" ;;
  medium) EXPECT="33002 33000 0 1000" ;;
  *) echo "unsupported BENCH_PROFILE=$PROFILE" >&2; exit 2 ;;
esac

# Regenerate the fixture every run so generator drift cannot leak between runs.
# NOTE: it must live outside any path containing /build/ or the Dart adapter
# classifies every file as a generated artifact.
rm -rf "$FIXTURE"
dart run tool/generate_perf_fixture.dart --profile "$PROFILE" --output "$FIXTURE" >/dev/null
mkdir -p "$FIXTURE/.dart_tool" "$FIXTURE/.flutter_pruner"
cat > "$FIXTURE/.dart_tool/package_config.json" <<EOF
{
  "configVersion": 2,
  "packages": [
    {
      "name": "flutter_pruner_perf_$PROFILE",
      "rootUri": "../",
      "packageUri": "lib/",
      "languageVersion": "3.9"
    }
  ]
}
EOF
cat > "$FIXTURE/.flutter_pruner/config.yaml" <<'EOF'
version: 1
analysis:
  mode: application
target_matrix:
  complete: true
  targets:
    - name: android-default
      platform: android
      entrypoint: lib/main.dart
    - name: ios-default
      platform: ios
      entrypoint: lib/main.dart
  excluded_entrypoints: []
verification:
  steps:
    - id: dart-analyze
      argv: [dart, analyze, --fatal-infos, --fatal-warnings]
EOF

dart run benchmark/scan_benchmark.dart \
  --project "$FIXTURE" \
  --warmup "$WARMUP" \
  --iterations "$ITERATIONS" > "$RESULT"

jq -r --arg expect "$EXPECT" '
  def ms: . / 1000 | . * 100 | round / 100;
  ([.samples[] | "\(.nodes) \(.edges) \(.blockers) \(.findings)"] | unique) as $shapes
  | if $shapes != [$expect] then
      error("graph shape drift: got \($shapes) expected [\($expect)]")
    else . end
  | ([.samples[].elapsedMicros] | sort) as $e
  | ([.samples[].findingElapsedMicros] | sort) as $f
  | ([.samples[] | .adapters[] | select(.id=="dart") | .elapsedMicros] | sort) as $d
  | ([.samples[] | .adapters[] | select(.id=="duplicates") | .elapsedMicros] | sort) as $dup
  | "METRIC scan_median_ms=\($e[$e|length/2|floor] | ms)",
    "METRIC scan_min_ms=\($e[0] | ms)",
    "METRIC scan_max_ms=\($e[-1] | ms)",
    "METRIC dart_adapter_median_ms=\($d[$d|length/2|floor] | ms)",
    "METRIC duplicates_adapter_median_ms=\($dup[$dup|length/2|floor] | ms)",
    "METRIC finding_median_ms=\($f[$f|length/2|floor] | ms)",
    "ASI nodes=\(.samples[0].nodes)",
    "ASI edges=\(.samples[0].edges)",
    "ASI findings=\(.samples[0].findings)"
' "$RESULT"
