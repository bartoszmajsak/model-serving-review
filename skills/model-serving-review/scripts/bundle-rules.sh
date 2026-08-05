#!/usr/bin/env bash
set -euo pipefail

# bundle-rules.sh — Slice the knowledge files into per-agent rule bundles.
#
# The orchestrator used to read all 2,300 lines of knowledge and hand-retype the
# applicable subset into each agent prompt, then retype rule text again for the
# verifier. Every one of those copies was an inference-cost paraphrase of text
# that awk can slice verbatim, and the most likely place for a precision fix to
# silently not reach the agent that needs it.
#
# Routing comes from the "**Rules to check:**" lines in agents/*.md — the same
# lines check-rule-refs.sh validates, so bundles and the checker cannot disagree.
#
# Writes:
#   $review_dir/rules/<agent>.md        one bundle per Pass-1 agent
#   $review_dir/rules/by-id/<RULE>.md   one file per rule, for the verifier
#   $review_dir/rules/tier1-files.txt   changed files on a Tier-1 hot path
#
# Usage: bash bundle-rules.sh <metadata.json>

META="${1:?Usage: bundle-rules.sh <metadata.json>}"
[[ -f "$META" ]] || { echo "error: no such metadata file: $META" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
KNOWLEDGE="$SCRIPT_DIR/../knowledge"
RULES="$KNOWLEDGE/review-rules.md"
EXAMPLES="$KNOWLEDGE/examples.md"
CRITICAL="$KNOWLEDGE/critical-areas.md"
AGENTS_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd -P)/agents"

for f in "$RULES" "$EXAMPLES" "$CRITICAL"; do
  [[ -f "$f" ]] || { echo "error: missing knowledge file: $f" >&2; exit 1; }
done
[[ -d "$AGENTS_DIR" ]] || { echo "error: agents dir not found at $AGENTS_DIR" >&2; exit 1; }

REVIEW_DIR=$(jq -r '.review_dir' "$META")
IS_ODH=$(jq -r '.is_odh' "$META")
OUT="$REVIEW_DIR/rules"
mkdir -p "$OUT/by-id"

ALL_RULES=$(grep -oE '^\*\*[A-Z]+-[0-9]{3} \|' "$RULES" | grep -oE '[A-Z]+-[0-9]{3}')

# Expand a routing spec ("CTL-*, CODE-*, MIG-050") into concrete rule IDs.
expand_spec() {
  local spec="$1" token
  # shellcheck disable=SC2001
  for token in $(echo "$spec" | tr ',' '\n' | tr -d ' '); do
    case "$token" in
      "")     ;;
      *-\*)   echo "$ALL_RULES" | grep "^${token%-*}-" || true ;;
      *)      echo "$token" ;;
    esac
  done
}

# Rule blocks run from their bold heading to the next heading. Section preambles
# live above the first rule and carry load-bearing context (the SYNC table names
# the .rules/ files that override the rubric), so a section is emitted whole-headed
# whenever any of its rules is selected.
slice_rules() {
  awk -v want="$1" '
    BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) W[a[i]] = 1 }
    /^## / { sec = $0; pre = ""; in_pre = 1; sec_done = 0; keep = 0; next }
    /^\*\*[A-Z]+-[0-9][0-9][0-9] \| / {
      in_pre = 0
      id = $1; sub(/^\*\*/, "", id)
      keep = (id in W)
      if (keep && !sec_done) { print sec; print ""; printf "%s", pre; sec_done = 1 }
      if (keep) print
      next
    }
    { if (in_pre) pre = pre $0 "\n"; else if (keep) print }
  ' "$RULES"
}

# Example sections run from "### Title (RULE-ID[, RULE-ID])" to the next heading.
# They carry the NOT A FINDING and Applicability boundary paragraphs, which are
# the difference between a verifier that checks exemptions and one that re-runs Pass 1.
slice_examples() {
  awk -v want="$1" '
    BEGIN { n = split(want, a, " "); for (i = 1; i <= n; i++) W[a[i]] = 1 }
    /^## / { keep = 0; next }
    /^### / {
      keep = 0
      ids = $0
      while (match(ids, /[A-Z]+-[0-9][0-9][0-9]/)) {
        id = substr(ids, RSTART, RLENGTH)
        if (id in W) keep = 1
        ids = substr(ids, RSTART + RLENGTH)
      }
      if (keep) print
      next
    }
    { if (keep) print }
  ' "$EXAMPLES"
}

# Tier rows whose backticked path matches a changed file. Bash glob matching so
# the wildcard rows (pkg/controller/*/llmisvc/...) resolve the way they read.
CHANGED=$(jq -r '.files[]?' "$META")
slice_risk() {
  local row path file matched
  while IFS= read -r row; do
    matched=""
    while read -r path; do
      [[ -n "$path" ]] || continue
      path="${path%/}"
      while IFS= read -r file; do
        # shellcheck disable=SC2053
        if [[ "$file" == $path || "$file" == $path/* || "$file" == *$path* ]]; then
          matched=yes; break
        fi
      done <<< "$CHANGED"
      [[ -n "$matched" ]] && break
    done < <(grep -oE '`[^`]+`' <<< "$row" | tr -d '`')
    if [[ -n "$matched" ]]; then echo "$row"; fi
  done < <(grep '^| `' "$CRITICAL")
}

RISK=$(slice_risk)

# The changed files that land on a Tier-1 row, one per line. An agent that comes
# back with nothing to say about one of these is the thin-signal case the
# orchestrator escalates on, and it needs the list without reading the map.
tier1_files() {
  local rows path file
  rows=$(awk '/^### Tier 1/ { t = 1; next } /^### Tier 2/ { t = 0 } t && /^\| `/' "$CRITICAL")
  [[ -n "$rows" ]] || return 0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    while read -r path; do
      path="${path%/}"
      # shellcheck disable=SC2053
      if [[ "$file" == $path || "$file" == $path/* || "$file" == *$path* ]]; then
        echo "$file"
        break
      fi
    done < <(grep -oE '`[^`]+`' <<< "$rows" | tr -d '`')
  done <<< "$CHANGED"
}

tier1_files | sort -u > "$OUT/tier1-files.txt"

write_bundle() {
  local agent="$1" ids="$2" dest="$OUT/${agent}.md"
  local count; count=$(wc -w <<< "$ids" | tr -d ' ')

  {
    echo "# Rule bundle: $agent"
    echo
    echo "You are accountable for exactly these $count rules. This list is closed —"
    echo "no rule outside it is yours, and every rule in it must be evaluated."
    echo
    echo "$ids" | tr ' ' '\n' | sed 's/^/- /'
    echo
    echo "## Rules"
    echo
    slice_rules "$ids"
    echo "## Examples"
    echo
    slice_examples "$ids"
    if [[ -n "$RISK" ]]; then
      echo "## Risk context for the changed files"
      echo
      echo "These paths are Tier 1/2 hot files in the bug-density map. Weight attention accordingly."
      echo
      echo "| Path/Pattern | Dominant Failure Mode |"
      echo "|---|---|"
      echo "$RISK"
      echo
    fi
  } > "$dest"

  echo "$agent: $count rules -> $dest"
}

# One file per rule: what the verifier gets, instead of the orchestrator
# paraphrasing the rule and its exemptions from memory.
write_by_id() {
  local rule
  for rule in $ALL_RULES; do
    {
      slice_rules "$rule"
      echo "## Example"
      echo
      slice_examples "$rule"
    } > "$OUT/by-id/${rule}.md"
  done
}

for agent_file in "$AGENTS_DIR"/*.md; do
  agent=$(basename "$agent_file" .md)
  spec=$(sed -n 's/^\*\*Rules to check:\*\* *//p' "$agent_file")
  [[ -n "$spec" ]] || continue

  if [[ "$IS_ODH" == "true" ]]; then
    odh_spec=$(sed -n 's/^\*\*Rules to check (ODH only):\*\* *//p' "$agent_file")
    [[ -n "$odh_spec" ]] && spec="$spec, $odh_spec"
  fi

  ids=$(expand_spec "$spec" | sort -u | tr '\n' ' ')
  ids="${ids% }"
  [[ -n "$ids" ]] || continue
  write_bundle "$agent" "$ids"
done

write_by_id
echo "by-id: $(echo "$ALL_RULES" | wc -l | tr -d ' ') rules -> $OUT/by-id/"
