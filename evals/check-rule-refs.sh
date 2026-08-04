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
#
# Usage: bash evals/check-rule-refs.sh

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RULES="$ROOT/skills/model-serving-review/knowledge/review-rules.md"
EXAMPLES="$ROOT/skills/model-serving-review/knowledge/examples.md"

RULE_RE='[A-Z]+-[0-9]{3}'
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

# --- 2. defined but unclaimed by any agent ---
for rule in $(echo "$defined" | uniq); do
  if ! grep -rqE "\b${rule}\b|\b${rule%%-*}-\*" "$ROOT/agents" 2>/dev/null; then
    fail "$rule is defined but no agent prompt claims it or its family"
  fi
done

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
