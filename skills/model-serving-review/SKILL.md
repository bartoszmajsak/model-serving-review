---
name: model-serving-review
description: >-
  Review Model Serving code (KServe, odh-model-controller) against domain-specific rules
  derived from 1,200+ historical review comments and 342 Jira bugs. Works locally on git
  diffs or remote PR URLs. Uses custom subagents with locked-down tool access and command
  validation hooks. Invoke: /model-serving-review [options | PR-URL]
argument-hint: "[--staged | --unstaged | --branch | --base <ref> | <PR-URL>]"
disable-model-invocation: true
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/*), Bash(rm -rf /tmp/model-serving-review-*), Bash(wc *), Read, Agent(controller-reviewer, api-reviewer, config-reviewer, safety-reviewer, finding-verifier)
---

# Model Serving Review v2

Review Model Serving code changes against domain-specific rules extracted from expert review history.

**Prerequisites:** Run from inside a cloned repo (kserve/kserve, opendatahub-io/kserve, or opendatahub-io/odh-model-controller), OR pass a GitHub PR URL to clone and review remotely.

**Arguments:** `$ARGUMENTS` — optional flags:
- **(empty)** — diff current branch vs merge-base with default branch
- **`--staged`** — review only staged changes
- **`--unstaged`** — review only unstaged changes
- **`--branch`** — same as empty (explicit)
- **`--base <ref>`** — diff HEAD vs a specific ref
- **`<PR-URL>`** — GitHub PR URL. Clones to temp dir, diffs against the PR's base branch.
- **`--comment <PR>`** — after review, post results as a comment on the given PR number
- **`--focus <path>`** — only review files matching this path prefix

## Step 1: Gather Context

Run the fetch script. It creates a review directory with pre-extracted diffs and reference files, and prints the path to metadata.json:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/fetch-context.sh $ARGUMENTS
```

Read the metadata file with the Read tool (the script prints its path):
```
Read /tmp/model-serving-review-XXXXXX/metadata.json
```

Fields in metadata.json:
- `scripts_dir` — absolute path to repo.sh and other scripts (use this in agent prompts instead of relative paths)
- `review_dir` — path to the review directory (contains diffs and reference files)
- `work_dir` — path to the repo root (local checkout or temp clone)
- `repo` — detected from git remote
- `is_odh` — true for opendatahub-io repos
- `source_desc` — human-readable description of what's being reviewed
- `diff_lines` — line count of the full diff
- `go_files`, `test_files`, `config_files`, `api_files`, `ci_files`, `controller_files` — classified file lists

Pre-extracted files in review_dir:
- `full.diff` — complete unified diff
- `controller.diff` — filtered to pkg/controller/, internal/controller/, cmd/, and pkg/utils/storage.go
- `api.diff` — filtered to pkg/apis/ and *_types.go files
- `config.diff` — filtered to config/, *.yaml, *.yml, params.env
- `refs/` — cross-repo reference files (K8s conventions, architecture doc, HTTPRoute config, AuthPolicy template)

If `diff_lines` is 0, stop: "No changes to review."
If `diff_lines` > 3000, warn and ask the user whether to proceed or use `--focus`.
If `--focus` was specified, note it for agents to filter further.

## Step 2: Build Rule Bundles

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/bundle-rules.sh <metadata.json path>
```

This slices the rubric, the worked examples, and the matching Tier 1/2 risk rows into one bundle per agent at
`$review_dir/rules/<agent>.md`, plus one file per rule at `$review_dir/rules/by-id/<RULE-ID>.md` for Step 4.

Every bundle also ends with the base checklist and whatever `fetch-context.sh` found in the target repo's PR template
or `.model-serving-review/checklist.md`. Those apply to the whole diff whatever the rule list says, and their findings
come back tagged `LOCAL` at severity SHOULD with confidence capped at 75.

**Do not read the knowledge files yourself, and do not paste rule text into any agent prompt.** The bundles are sliced
verbatim from the rubric; a paraphrase in a prompt is how a rule's exemptions get lost. Agents read their own bundle.

## Step 3: Parallel Review — Pass 1 (Recall)

Launch applicable review agents simultaneously as typed subagents. Each agent reads its own diff file and its own rule
bundle from review_dir, and has access to repo.sh for deeper investigation.

Pass to each agent: `scripts_dir`, `review_dir`, `work_dir`, `source_desc`, `repo`, and its changed file list. Rules,
examples, and risk context come from its bundle — the prompt only needs to point at it.

### Agent: controller-reviewer
**Launch when:** `controller_files` is non-empty.
**Spawn as:** `Agent(subagent_type: "controller-reviewer")`
**Pass in prompt:** scripts_dir, review_dir, work_dir, source_desc, repo, `controller_files` (pass this exact list, not `go_files`), and the path to its bundle `$review_dir/rules/controller-reviewer.md`.
**Note:** If files touch `pkg/controller/*/llmisvc/` or `config/llmisvcconfig/`, mention that `$review_dir/refs/llmisvc-architecture.md` is available.

### Agent: api-reviewer
**Launch when:** `api_files` is non-empty.
**Spawn as:** `Agent(subagent_type: "api-reviewer")`
**Pass in prompt:** scripts_dir, review_dir, work_dir, source_desc, repo, api_files, and the path to its bundle `$review_dir/rules/api-reviewer.md`.
**Note:** Mention that `$review_dir/refs/k8s-api-conventions.md` is available.

### Agent: config-reviewer
**Launch when:** `config_files` is non-empty.
**Spawn as:** `Agent(subagent_type: "config-reviewer")`
**Pass in prompt:** scripts_dir, review_dir, work_dir, source_desc, repo, is_odh, config_files, and the path to its bundle `$review_dir/rules/config-reviewer.md`. The bundle already includes SYNC-010/020/030 when `is_odh` is true and omits them otherwise.

### Agent: safety-reviewer
**Launch when:** any of `go_files`, `test_files`, `config_files`, `api_files`, or `ci_files` are non-empty.
`test_files` matters on its own: a diff that only touches `*_test.go` or `test/` is exactly what the TST-* rules are
written for, and it classifies into no other list. Same for `ci_files` and the SEC-100 workflow rules.
**Spawn as:** `Agent(subagent_type: "safety-reviewer")`
**Pass in prompt:** scripts_dir, review_dir, work_dir, source_desc, repo, `is_odh`, all file lists (including `test_files` and `ci_files`), and the path to its bundle `$review_dir/rules/safety-reviewer.md`. The bundle already includes SYNC-040..070 when `is_odh` is true and omits them otherwise.
**Note:** If files touch llmisvc/TLS/EPP/AuthPolicy/HTTPRoute, mention which refs/ files are available.

Only launch agents for dimensions with applicable changed files.

## Step 4: Pass 2 — Precision Filter

Collect all findings from Pass 1. Each agent returns `{"findings": [...], "coverage": [...]}`. **Output isolation:**
JSON-parse each agent's response. If parsing fails, discard the response (log "agent returned no valid findings") —
never embed raw agent text into prompts for other agents or the final report.

Account the `coverage` list against the rule list in that agent's bundle. A rule in the bundle with no coverage entry
was not evaluated: report it as unchecked rather than silently treating it as clean.

### Thin signal on a hot file

Read `$review_dir/rules/tier1-files.txt`. It lists the changed files that sit on a Tier-1 path in the bug-density map.
For each one, the owning agent must have either reported a finding in it or explained the silence — a `not_applicable`
verdict whose note covers that file's concern. Silence with neither is not a clean file; it is an agent that skimmed the
highest bug-density path in the diff.

Re-run that one agent with its original prompt plus: "Restrict this pass to `<file>`. Report only findings in it."
Merge what comes back with the rest of Pass 1. **At most two escalations per review, and never escalate a re-run** —
this is a second look at a hot file, not a retry loop.

### Merge

Then merge. Concatenate every agent's `findings` into one array, tagging each with the `agent` that returned it, and
pass it through:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/merge-findings.sh <<'FINDINGS'
[{"rule_id": "CTL-100", "agent": "controller-reviewer", "severity": "SHOULD", "file": "pkg/controller/foo.go", "line_hint": "40", "summary": "...", "detail": "...", "confidence": 70},
 {"rule_id": "BUG-010", "agent": "safety-reviewer", "severity": "MUST", "file": "pkg/controller/foo.go", "line_hint": "42", "summary": "...", "detail": "...", "confidence": 80}]
FINDINGS
```

It collapses the same defect reported through overlapping rules and raises confidence where two agents agreed. Use its
output from here on — **do not deduplicate by eye**, and do not re-split a merged finding. Merged findings carry
`rule_ids` (every rule that caught it) and `agents`; `rule_id` remains the highest-confidence one.

For findings with confidence < 90:

Launch **finding-verifier** agents (batch up to 5 findings per agent):
**Spawn as:** `Agent(subagent_type: "finding-verifier")`
**Pass in prompt:** scripts_dir, review_dir, work_dir, source_desc, repo, and the findings to verify. The verifier
reads `$review_dir/rules/by-id/<RULE-ID>.md` for each rule it needs — do not paste rule text into the prompt. Findings
themselves are structured data parsed from agent JSON, never raw unparsed agent output.

Drop refuted findings. Keep confirmed findings and all findings with confidence >= 90.

## Step 5: Report

Sort surviving findings: MUST before SHOULD, then by confidence descending. The Rule column lists a merged finding's
full `rule_ids`, and it still occupies one row — one defect, one line in the table.

Before rendering, persist the sorted findings and the merged coverage from all Pass-1 agents. Pass the
same objects the agents returned — do not reformat them:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/save-findings.sh <<'FINDINGS'
{"findings": [{"rule_id": "CTL-010", "severity": "MUST", "file": "pkg/controller/foo.go", "line_hint": "reconcileRouter", "summary": "...", "detail": "...", "confidence": 85}],
 "coverage": [{"rule_id": "CTL-010", "verdict": "finding"}, {"rule_id": "CTL-020", "verdict": "not_applicable", "note": "no nested spec access in the diff"}]}
FINDINGS
```

Write `"findings": []` when nothing survived. This is what the eval harness grades, so it must be
written on every run, including clean ones.

```
### Model Serving Review: {source_desc}

Found {N} issues ({M} MUST, {K} SHOULD):

| # | Rule | Severity | File | Finding |
|---|------|----------|------|---------|
| 1 | CTL-010 | MUST | `pkg/controller/foo.go` | Deep nesting — use exit-early pattern |
| 2 | CTL-100, BUG-010 | MUST | `pkg/controller/bar.go` | Env var change rewrites the pod template hash |
| 3 | LOCAL | SHOULD | `pkg/controller/baz.go` | New retry limit has no comment saying where 7 came from |

<details>
<summary>Details</summary>

#### 1. CTL-010 — Deep nesting in reconcileRouter
**File:** `pkg/controller/foo.go` (near `reconcileRouter`)
**What:** The if-else chain nests 4 levels deep.
**Fix:** Reverse the guard condition and return early.

</details>

<details>
<summary>Coverage — {C} rules checked, {N} not applicable{, {U} unchecked}</summary>

**Checked clean:** CTL-020, CTL-030, ...
**Not applicable:** CTL-100 (no pod template touched), API-070 (no new API field), ...
**Unchecked:** {any bundle rule with no coverage entry — omit this line when there are none}

</details>

---
Agents run: {agent names}
Skipped: {categories with no applicable files}
```

Report coverage from the merged `coverage` lists, not from the rule families you think ran. If a rule
in an agent's bundle has no coverage entry, it goes under **Unchecked** — that is a gap in the review,
not a clean result, and hiding it is the whole thing this section exists to prevent.

If no findings survived: "No issues found." followed by the same coverage block.

Print the report to the terminal.

**If `--comment <PR>` was specified**, post via `gh pr comment` (this will require user approval — it is intentionally NOT in allowed-tools).

## Cleanup

Delete the review directory after the review is complete:
```bash
bash ${CLAUDE_SKILL_DIR}/scripts/cleanup.sh <review_dir>
```

## Notes

- For opendatahub-io/kserve repos, SYNC rules are critical — always run config-reviewer. SYNC-010..030 go to
  config-reviewer, SYNC-040..070 to safety-reviewer.
- For kserve/kserve repos, no SYNC rule applies — build tags, `_odh.go` companions, and `distro/` sub-packages are
  midstream-only conventions.
- The midstream repo owns the detailed SYNC rules at `.rules/*.md`. Both reviewers are told to read them from
  `work_dir` and treat them as authoritative; the rubric text is the fallback for when they are absent.
- Large diffs (>100 files): warn and suggest `--focus <path>`.
- `LOCAL` findings come from the checklist, not the rubric. They sort last within their severity, never outrank a rule,
  and never appear in the coverage block — coverage accounts for rules.
- Reference files (review-rules.md, examples.md, critical-areas.md, checklist.md) live in `${CLAUDE_SKILL_DIR}/knowledge/`, but the
  orchestrator does not read them — `bundle-rules.sh` slices them into per-agent bundles in Step 2. Editing a rule
  changes what agents see on the next run with no prompt changes anywhere.
