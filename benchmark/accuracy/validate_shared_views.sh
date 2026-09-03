#!/usr/bin/env bash
# Validation script for shared view optimization
# Compares baseline (no shared views) vs optimized (with shared views)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

MANIFEST="${MANIFEST:-$PROJECT_ROOT/benchmark/accuracy/manifests/l10n-mutation-readiness-v1.json}"
CORPUS_ROOT="${CORPUS_ROOT:-/tmp/l10n_corpus_validation}"
OUTPUT_BASELINE="${OUTPUT_BASELINE:-/tmp/l10n_baseline_output.json}"
OUTPUT_SHARED="${OUTPUT_SHARED:-/tmp/l10n_shared_output.json}"

# SDK paths (using FVM versions)
SDK_ARGS=(
  --sdk "3.41.5=${SDK_3_41_5:-$HOME/fvm/versions/3.41.5/bin/flutter}"
  --sdk "3.44.1=${SDK_3_44_1:-$HOME/fvm/versions/3.44.1/bin/flutter}"
  --sdk "3.44.9=${SDK_3_44_9:-$HOME/fvm/versions/3.44.9/bin/flutter}"
)

echo "=== L10n Mutation Readiness Shared View Validation ==="
echo "Manifest: $MANIFEST"
echo "Corpus root: $CORPUS_ROOT"
echo "Output baseline: $OUTPUT_BASELINE"
echo "Output shared: $OUTPUT_SHARED"
echo ""

# Clean previous outputs
rm -f "$OUTPUT_BASELINE" "$OUTPUT_SHARED"

echo "=== Phase 1: Baseline (no shared views) ==="
BASELINE_START=$(date +%s)
dart "$PROJECT_ROOT/benchmark/accuracy/l10n_mutation_readiness.dart" \
  --manifest "$MANIFEST" \
  --corpus-root "$CORPUS_ROOT" \
  --output "$OUTPUT_BASELINE" \
  "${SDK_ARGS[@]}"
BASELINE_END=$(date +%s)
BASELINE_DURATION=$((BASELINE_END - BASELINE_START))
echo "Baseline completed in ${BASELINE_DURATION}s"
echo ""

echo "=== Phase 2: Optimized (with shared views) ==="
SHARED_START=$(date +%s)
dart "$PROJECT_ROOT/benchmark/accuracy/test_l10n_mutation_readiness_v3_shared.dart" \
  --manifest "$MANIFEST" \
  --corpus-root "$CORPUS_ROOT" \
  --output "$OUTPUT_SHARED" \
  "${SDK_ARGS[@]}"
SHARED_END=$(date +%s)
SHARED_DURATION=$((SHARED_END - SHARED_START))
echo "Shared views completed in ${SHARED_DURATION}s"
echo ""

echo "=== Phase 3: Correctness Validation ==="
if ! command -v jq &> /dev/null; then
  echo "WARNING: jq not found, skipping JSON comparison"
  echo "Install jq for detailed comparison: https://stedolan.github.io/jq/"
else
  # Compare JSON outputs (excluding timing fields)
  jq --sort-keys 'del(.metadata.wallClockMicros, .metadata.timestamp, .cases[].attemptMicros, .familyBatches[].attemptMicros, .projects[].scanMicros)' "$OUTPUT_BASELINE" > /tmp/baseline_normalized.json
  jq --sort-keys 'del(.metadata.wallClockMicros, .metadata.timestamp, .cases[].attemptMicros, .familyBatches[].attemptMicros, .projects[].scanMicros)' "$OUTPUT_SHARED" > /tmp/shared_normalized.json

  if diff -q /tmp/baseline_normalized.json /tmp/shared_normalized.json > /dev/null; then
    echo "✓ Outputs are identical (excluding timing)"
  else
    echo "✗ Outputs differ!"
    echo "Run: diff /tmp/baseline_normalized.json /tmp/shared_normalized.json"
    exit 1
  fi
fi

echo ""
echo "=== Phase 4: Performance Summary ==="
echo "Baseline duration: ${BASELINE_DURATION}s"
echo "Shared duration: ${SHARED_DURATION}s"
if [ "$BASELINE_DURATION" -gt 0 ]; then
  SPEEDUP=$(awk "BEGIN {printf \"%.1f\", $BASELINE_DURATION / $SHARED_DURATION}")
  IMPROVEMENT=$(awk "BEGIN {printf \"%.1f\", 100 * (1 - $SHARED_DURATION / $BASELINE_DURATION)}")
  echo "Speedup: ${SPEEDUP}x"
  echo "Improvement: ${IMPROVEMENT}%"
fi

echo ""
echo "=== Validation Complete ==="
