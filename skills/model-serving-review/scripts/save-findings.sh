#!/usr/bin/env bash
set -euo pipefail

# save-findings.sh — Persist the review's final findings array as JSON.
#
# The skill renders findings as a markdown table, which is unusable for grading.
# This writes the same findings in the schema evals/grade-results.sh already
# expects, so an eval run is a copy instead of a hand-transcription.
#
# Deliberately outside the review directory: cleanup.sh wipes /tmp/model-serving-review-*
# at the end of every review, and the findings have to outlive that.
#
# ponytail: one well-known path, so two concurrent reviews clobber each other.
# Nobody runs two at once; key it by work_dir if that ever stops being true.
#
# Usage: bash save-findings.sh <<'EOF'
#        [{"rule_id": "CTL-010", "severity": "MUST", "file": "...", ...}]
#        EOF

OUT="${MODEL_SERVING_FINDINGS:-/tmp/model-serving-findings.json}"

input=$(cat)

# An empty review is a valid result — record it as such rather than a broken file.
[[ -n "${input// }" ]] || input='[]'

echo "$input" | jq -e 'type == "array"' >/dev/null 2>&1 || {
  echo "error: expected a JSON array of findings" >&2
  exit 1
}

echo "$input" | jq '.' > "$OUT"
echo "$OUT"
