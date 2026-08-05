#!/usr/bin/env bash
set -euo pipefail

# merge-findings.sh — Collapse duplicate findings and turn agreement into confidence.
#
# Overlapping rules are deliberate: CTL-100 and BUG-010 are the same defect from
# two angles, and go_files reaches two agents, so one defect can arrive two or
# three times. Nothing merged them, and the fact that two independent agents hit
# the same line — the strongest signal available — was thrown away.
#
# Reads a JSON array of Pass-1 findings on stdin, each tagged with the agent that
# produced it, and writes the merged array on stdout. No model call.
#
# Two findings merge when they share a file, sit within 3 lines of each other (or
# name the same function), and their rules are in the same overlap class. Same
# rule ID is always its own class.
#
# The merged finding keeps the highest severity, the union of rule IDs in
# rule_ids, and confidence max(confidences) + 10 per extra agent, capped at 95.
# The cap is above the 90 verification threshold on purpose: a finding two agents
# independently agree on has earned skipping the skeptic.
#
# Usage: bash merge-findings.sh <<'EOF'
#        [{"rule_id": "CTL-100", "agent": "controller-reviewer", ...}]
#        EOF
#        bash merge-findings.sh --self-check

MERGE=$(cat <<'JQ'
# Rules that describe the same defect from different angles. Explicit, not
# guessed from families — CTL-100 and CTL-110 are both controller rules and are
# not the same finding.
def classes: [
  ["CTL-100", "BUG-010", "MIG-010"],
  ["CTL-150", "CTL-160"],
  ["SEC-080", "BUG-050"],
  ["CTL-120", "CODE-080"]
];

def related($a; $b):
  $a == $b or (classes | any(index($a) != null and index($b) != null));

def lineno:
  (. // "") | tostring | capture("(?<n>[0-9]+)") // null | if . then (.n | tonumber) else null end;

def norm:
  (. // "") | tostring | ascii_downcase | gsub("^\\s+|\\s+$"; "");

# Line numbers when both sides have one, otherwise the function name they point at.
def near($x; $y):
  ($x | lineno) as $a | ($y | lineno) as $b
  | if $a != null and $b != null then (($a - $b) | fabs) <= 3
    else ($x | norm) == ($y | norm) and ($x | norm) != ""
    end;

def cluster:
  reduce .[] as $f ([];
    . as $acc
    | ((first($acc | to_entries[]
        | select(.value | any(
            .file == $f.file
            and related(.rule_id; $f.rule_id)
            and near(.line_hint; $f.line_hint)))
        | .key)) // -1) as $i
    | if $i == -1 then $acc + [[$f]] else ($acc | .[$i] += [$f]) end
  );

def collapse:
  (sort_by(.confidence // 0) | last) as $primary
  | ([.[].rule_id] | unique) as $rules
  | ([.[].agent // "unknown"] | unique) as $agents
  | ((map(.confidence // 0) | max) + 10 * (($agents | length) - 1)) as $conf
  | (map(select(.rule_id != $primary.rule_id)
         | "- \(.rule_id) (\(.agent // "unknown")): \(.summary // "")")
     | join("\n")) as $also
  | $primary
    + { rule_ids: $rules,
        agents: $agents,
        severity: (if any(.[]; .severity == "MUST") then "MUST" else "SHOULD" end),
        confidence: ([$conf, 95] | min) }
    + (if $also == "" then {} else {detail: "\($primary.detail // "")\n\nAlso matched:\n\($also)"} end);

cluster | map(collapse)
JQ
)

if [[ "${1:-}" == "--self-check" ]]; then
  check() {
    local name=$1 input=$2 filter=$3
    echo "$input" | jq "$MERGE" | jq -e "$filter" >/dev/null \
      && echo "ok   $name" || { echo "FAIL $name" >&2; exit 1; }
  }

  # Same defect, two agents, two rules in one class, lines 3 apart: one finding.
  check "merges an overlap class" '[
    {"rule_id":"CTL-100","agent":"controller-reviewer","file":"a.go","line_hint":"40","severity":"SHOULD","confidence":70},
    {"rule_id":"BUG-010","agent":"safety-reviewer","file":"a.go","line_hint":"42","severity":"MUST","confidence":80}
  ]' 'length == 1 and .[0].rule_ids == ["BUG-010","CTL-100"] and .[0].severity == "MUST" and .[0].confidence == 90'

  # Unrelated rules on the same line stay apart.
  check "keeps unrelated rules apart" '[
    {"rule_id":"CTL-100","agent":"controller-reviewer","file":"a.go","line_hint":"40","confidence":70},
    {"rule_id":"CTL-110","agent":"controller-reviewer","file":"a.go","line_hint":"40","confidence":70}
  ]' 'length == 2'

  # Same rule, far apart, stays two findings.
  check "keeps distant lines apart" '[
    {"rule_id":"CTL-010","agent":"controller-reviewer","file":"a.go","line_hint":"10","confidence":70},
    {"rule_id":"CTL-010","agent":"controller-reviewer","file":"a.go","line_hint":"90","confidence":70}
  ]' 'length == 2'

  # Non-numeric hints fall back to the function name.
  check "matches on function name" '[
    {"rule_id":"CTL-010","agent":"controller-reviewer","file":"a.go","line_hint":"reconcileRouter","confidence":70},
    {"rule_id":"CTL-010","agent":"safety-reviewer","file":"a.go","line_hint":"reconcileRouter","confidence":70}
  ]' 'length == 1 and .[0].confidence == 80'

  # One agent twice never earns the agreement bonus, and the cap holds.
  check "caps confidence at 95" '[
    {"rule_id":"CTL-100","agent":"a","file":"a.go","line_hint":"40","confidence":90},
    {"rule_id":"BUG-010","agent":"b","file":"a.go","line_hint":"40","confidence":90},
    {"rule_id":"MIG-010","agent":"c","file":"a.go","line_hint":"40","confidence":90}
  ]' '.[0].confidence == 95'

  echo "self-check passed"
  exit 0
fi

input=$(cat)
[[ -n "${input// }" ]] || input='[]'
echo "$input" | jq "$MERGE"
