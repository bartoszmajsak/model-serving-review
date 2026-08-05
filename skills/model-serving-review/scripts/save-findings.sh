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
# Accepts either a bare findings array or {"findings": [...], "coverage": [...]}.
# Coverage is written alongside rather than inside, so findings.json stays the flat
# array grade-results.sh already reads.
#
# Usage: bash save-findings.sh <<'EOF'
#        {"findings": [...], "coverage": [{"rule_id": "CTL-010", "verdict": "clean"}]}
#        EOF

OUT="${MODEL_SERVING_FINDINGS:-/tmp/model-serving-findings.json}"
COV="${MODEL_SERVING_COVERAGE:-${OUT%/*}/model-serving-coverage.json}"

input=$(cat)

# An empty review is a valid result — record it as such rather than a broken file.
[[ -n "${input// }" ]] || input='[]'

kind=$(echo "$input" | jq -r 'type' 2>/dev/null) || kind=""

case "$kind" in
  array)
    echo "$input" | jq '.' > "$OUT"
    echo '[]' > "$COV"
    ;;
  object)
    echo "$input" | jq -e 'has("findings") and (.findings | type == "array")' >/dev/null || {
      echo "error: object form needs a 'findings' array" >&2
      exit 1
    }
    echo "$input" | jq '.findings' > "$OUT"
    echo "$input" | jq '.coverage // []' > "$COV"
    ;;
  *)
    echo "error: expected a JSON array of findings, or {findings, coverage}" >&2
    exit 1
    ;;
esac

echo "$OUT"
echo "$COV"
