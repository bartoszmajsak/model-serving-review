#!/usr/bin/env bash
set -euo pipefail

# check-rule-refs.sh — rule-ID referential integrity.
#
# Catches the class of drift that let SEC-075 be referenced by an agent prompt, an eval
# fixture, and the README for months without ever being defined in review-rules.md.
#
# Checks:
#   1. every rule ID cited in agents/, evals.json, or README.md is defined in review-rules.md
#   2. every rule defined in review-rules.md is claimed by at least one agent prompt
#   3. no rule ID is defined twice
#   4. rule IDs are in ascending order within their family
#   5. checklist.md cites no rule ID — a checklist item that restates a rule double-reports
#
# Usage: bash evals/check-rule-refs.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RULES="$ROOT/skills/model-serving-review/knowledge/review-rules.md"
EXAMPLES="$ROOT/skills/model-serving-review/knowledge/examples.md"

# Rule IDs are exactly three digits. The trailing \b keeps longer numeric suffixes
# (Jira keys like RHOAIENG-64702 cited in rule text) from being read as rule IDs.
RULE_RE='\b[A-Z]+-[0-9]{3}\b'
FAILED=0

fail() { echo "FAIL: $*" >&2; FAILED=1; }

# Defined rules: bold headings of the form **FAMILY-NNN | SEVERITY | applicability**
defined=$(grep -oE "^\*\*${RULE_RE} \|" "$RULES" | grep -oE "$RULE_RE" | sort)

# --- 3. duplicate definitions ---
if dupes=$(echo "$defined" | uniq -d) && [[ -n "$dupes" ]]; then
  fail "rule defined more than once in review-rules.md: $(echo "$dupes" | tr '\n' ' ')"
fi

# --- 4. ordering within family ---
# Compare the file order against the sorted order, per family.
file_order=$(grep -oE "^\*\*${RULE_RE} \|" "$RULES" | grep -oE "$RULE_RE")
for family in $(echo "$file_order" | cut -d- -f1 | uniq); do
  actual=$(echo "$file_order" | grep "^${family}-")
  expected=$(echo "$actual" | sort -t- -k2 -n)
  if [[ "$actual" != "$expected" ]]; then
    fail "$family rules are out of order in review-rules.md"
    diff <(echo "$actual") <(echo "$expected") | sed 's/^/      /' >&2 || true
  fi
done

# --- 1. referenced but never defined ---
# Referenced anywhere a rule ID is meant to be authoritative.
referenced=$(grep -rhoE "$RULE_RE" \
  "$ROOT/agents" "$ROOT/evals/evals.json" "$ROOT/README.md" "$ROOT/AGENTS.md" \
  2>/dev/null | sort -u)

for rule in $referenced; do
  if ! echo "$defined" | grep -qx "$rule"; then
    where=$(grep -rlE "\b${rule}\b" "$ROOT/agents" "$ROOT/evals/evals.json" "$ROOT/README.md" "$ROOT/AGENTS.md" 2>/dev/null \
      | sed "s|^$ROOT/||" | tr '\n' ' ')
    fail "$rule is referenced but has no definition in review-rules.md (cited in: $where)"
  fi
done

# --- 2. defined but unrouted, and the bundler can slice it ---
# Checked by running bundle-rules.sh for real rather than grepping the agent files:
# a rule merely mentioned in an agent's prose is not routed to it, and a rule that
# routes but slices empty reaches the agent as a heading with no text.
BUNDLE_TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-rule-refs-XXXXXX")
trap 'rm -rf "$BUNDLE_TMP"' EXIT

# is_odh=true so the SYNC rules route; no changed files, so no risk section.
jq -n --arg rd "$BUNDLE_TMP" \
  '{review_dir: $rd, is_odh: true, files: []}' > "$BUNDLE_TMP/metadata.json"

if bash "$ROOT/skills/model-serving-review/scripts/bundle-rules.sh" \
     "$BUNDLE_TMP/metadata.json" >/dev/null 2>&1; then
  routed=$(grep -hoE '^- [A-Z]+-[0-9]{3}$' "$BUNDLE_TMP"/rules/*.md | cut -d' ' -f2 | sort -u)

  for rule in $(echo "$defined" | uniq); do
    echo "$routed" | grep -qx "$rule" \
      || fail "$rule is defined but no agent's 'Rules to check' line routes it"

    slice="$BUNDLE_TMP/rules/by-id/${rule}.md"
    [[ -s "$slice" ]] && grep -q "^\*\*${rule} |" "$slice" \
      || fail "$rule does not slice cleanly — the verifier would get an empty rule body"
  done

  for rule in $routed; do
    echo "$defined" | grep -qx "$rule" \
      || fail "$rule is routed to an agent but has no definition in review-rules.md"
  done
else
  fail "bundle-rules.sh failed — agent routing cannot be verified"
fi

# --- 5. the checklist stays out of the rubric's business ---
# An item that restates a rule reports the same defect twice under two labels, and
# merge-findings.sh cannot collapse them: LOCAL is in no overlap class. Citing a rule
# ID is the visible symptom of that, so it is a failure, not a style note.
CHECKLIST="$ROOT/skills/model-serving-review/knowledge/checklist.md"
if [[ -f "$CHECKLIST" ]]; then
  if cited=$(grep -oE "$RULE_RE" "$CHECKLIST" | sort -u) && [[ -n "$cited" ]]; then
    fail "checklist.md cites rule IDs ($(echo "$cited" | tr '\n' ' ')) — an item that needs a rule's authority belongs in review-rules.md"
  fi
else
  fail "checklist.md is missing — bundle-rules.sh appends it to every bundle"
fi

# --- informational: rules with no example ---
missing_examples=""
for rule in $(echo "$defined" | uniq); do
  grep -qE "\b${rule}\b" "$EXAMPLES" || missing_examples+="$rule "
done

total=$(echo "$defined" | uniq | wc -l | tr -d ' ')
echo "checked $total defined rules"
[[ -n "$missing_examples" ]] && echo "note: no example for: $missing_examples"

if [[ $FAILED -eq 0 ]]; then
  echo "OK: rule references are consistent"
else
  exit 1
fi
