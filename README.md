# Model Serving Review

Domain-specific code review for [KServe](https://github.com/kserve/kserve)
and [odh-model-controller](https://github.com/opendatahub-io/odh-model-controller), powered by rules extracted from
1,200+ expert review comments and 342 Jira bugs (93 Blocker, 63 Critical).

Works as a Claude Code plugin — install once, invoke from any KServe checkout.

## What it does

Runs a multi-agent review pipeline on your diff:

1. **Gather context** — extracts diffs, classifies files, fetches cross-repo references
2. **Parallel review** — specialized agents check controller correctness, API consistency, config/overlay discipline,
   and security/migration safety
3. **Adversarial verification** — a verifier agent refutes false positives
4. **Report** — ranked findings with rule IDs, severity, and fix suggestions

Coverage spans 80+ rules across controller patterns, API design, upstream sync, kustomize config, TLS/security,
migration safety, testing, naming, cross-repo coordination, and 14 bug-prone patterns derived from real incidents.

## Install

### From a marketplace

If your team maintains a skills marketplace (e.g., `opendatahub-io/skills-registry`), ask to have this repo added. Then:

```
/plugin install model-serving-review@<marketplace-name>
```

### As a standalone marketplace

Register this repo directly as a single-plugin marketplace:

```
/plugin marketplace add <owner>/model-serving-review
/plugin install model-serving-review@model-serving-review
```

### Local development install

See [Local testing](#local-testing) below.

## Usage

From inside a KServe or odh-model-controller checkout:

```
/model-serving-review
```

### Options

| Flag             | Description                                               |
|------------------|-----------------------------------------------------------|
| *(empty)*        | Diff current branch vs merge-base with default branch     |
| `--staged`       | Review only staged changes                                |
| `--unstaged`     | Review only unstaged changes                              |
| `--branch`       | Same as empty (explicit)                                  |
| `--base <ref>`   | Diff HEAD vs a specific ref                               |
| `<PR-URL>`       | GitHub PR URL — clones to temp dir, diffs against PR base |
| `--focus <path>` | Only review files matching this path prefix               |
| `--comment <PR>` | Post results as a PR comment (requires user approval)     |

### Examples

```bash
# Review current branch
/model-serving-review

# Review a remote PR
/model-serving-review https://github.com/kserve/kserve/pull/1234

# Review only staged changes
/model-serving-review --staged

# Focus on controller code
/model-serving-review --focus pkg/controller/
```

## Prerequisites

- [Claude Code](https://docs.claude.com/en/docs/claude-code) with plugin support
- `git`, `jq`, `curl` available in PATH
- `gh` CLI (for PR URL mode and cross-repo lookups)

## Repository structure

```
.claude-plugin/
  marketplace.json              # Plugin manifest — declares skills + agents
agents/
  controller-reviewer.md        # Controller/reconciler correctness
  api-reviewer.md               # API type consistency and K8s conventions
  config-reviewer.md            # Kustomize, overlays, naming
  safety-reviewer.md            # Security, migration, testing, bug patterns
  finding-verifier.md           # Adversarial false-positive filter
skills/
  model-serving-review/
    SKILL.md                    # Orchestrator — drives the review pipeline
    knowledge/
      review-rules.md           # 80+ review rules with IDs and severity
      examples.md               # Concrete patterns from review history
      critical-areas.md         # Bug-density map for risk-weighted attention
      checklist.md              # Unconditional floor under the rules, reported as LOCAL
    scripts/
      fetch-context.sh          # Gathers diffs, classifies files, fetches refs
      bundle-rules.sh           # Slices the rubric into one rule bundle per agent
      merge-findings.sh         # Dedups overlapping findings, agreement raises confidence
      save-findings.sh          # Writes findings and coverage in the grader's schema
      repo.sh                   # Sandboxed git/gh operations for agents
      validate-cmd.sh           # PreToolUse hook — command whitelist for agents
      cleanup.sh                # Removes temp review directories
evals/
  evals.json                    # Assertions: expected rules, files, finding counts
  run-evals.sh                  # Sets up synthetic repos from fixtures
  grade-results.sh              # Grades skill output against assertions
  fixtures/
    common.sh                   # Shared helpers (init_repo, write_file, commit)
    ctl-010-deep-nesting.sh     # One fixture per rule or scenario
    ...                         # one per rule or scenario; see evals.json for the full list
```

## Local testing

### 1. Register as a local marketplace

From the root of this repo:

```
/plugin marketplace add ./
```

This registers the current directory as a marketplace. Claude Code reads `.claude-plugin/marketplace.json` to discover
the plugin.

### 2. Install the plugin

```
/plugin
```

Select **model-serving-review** and install it (user or project scope).

### 3. Test the skill

Switch to a KServe checkout with some changes and invoke:

```
/model-serving-review
```

Or test against a specific PR:

```
/model-serving-review https://github.com/kserve/kserve/pull/1234
```

### 4. Clean up after testing

Remove the local marketplace:

```
/plugin marketplace remove model-serving-review
```

Then reinstall from the git-hosted marketplace when ready.

### Iterating on changes

After editing skill, agent, or script files:

1. Reinstall the plugin: `/plugin install model-serving-review@model-serving-review`
2. Start a new conversation (`/clear` or new session) so Claude reloads the updated definitions
3. Run the skill against a known PR to verify

### Verifying the hook sandbox

The `validate-cmd.sh` hook restricts what bash commands agents can run (only `repo.sh` wrapper, `wc`, and safe pipe
targets). To test it:

```bash
# Should allow
echo '{"tool_input":{"command":"bash scripts/repo.sh /tmp/repo diff HEAD~1"}}' | bash skills/model-serving-review/scripts/validate-cmd.sh

# Should deny
echo '{"tool_input":{"command":"rm -rf /"}}' | bash skills/model-serving-review/scripts/validate-cmd.sh
```

## How the rules were built

1. Exported 1,219 review comments from kserve/kserve and opendatahub-io/kserve PRs
2. Exported 759 Jira bugs (156 Blocker/Critical) from RHOAIENG and INFERENG projects
3. Clustered by failure mode and extracted recurring patterns
4. Assigned rule IDs (CTL-*, API-*, CFG-*, SEC-*, MIG-*, TST-*, NAM-*, XREPO-*, BUG-*, CODE-*)
5. Built concrete examples from real review comments
6. Ranked files by bug density to create the risk map

## Evals

The `evals/` directory contains a test harness that measures recall and precision of the review skill against synthetic
repos with planted violations.

### Running evals

```bash
# 1. Set up all fixture repos (or pass specific names)
bash evals/run-evals.sh

# 2. For each fixture, invoke the skill from its repo_dir
cd /tmp/eval-fixture-ctl-010-deep-nesting-XXXXXX
/model-serving-review --base HEAD~1

# 3. Collect its findings and coverage — the skill writes both in the grader's schema
cp /tmp/model-serving-findings.json $RESULTS_DIR/ctl-010-deep-nesting/output.json
cp /tmp/model-serving-coverage.json $RESULTS_DIR/ctl-010-deep-nesting/coverage.json

# 4. Grade results
bash evals/grade-results.sh $RESULTS_DIR
```

Step 2 is the only manual part. The skill writes `/tmp/model-serving-findings.json` on every run
(including clean ones, as `[]`), so step 3 is a copy rather than a transcription of the report table.
The path is fixed, so run fixtures one at a time. `coverage.json` is only needed by fixtures that
assert `expected_coverage`; copying it always is cheaper than remembering which ones do.

### How fixtures work

Each fixture script in `evals/fixtures/` sources `common.sh` and creates a two-commit git repo: an initial clean state,
then a commit introducing the violation under test. The runner calls `fetch-context.sh` to produce a review directory,
then the skill reviews the diff between the two commits.

### Grading criteria

The grader (`grade-results.sh`) checks the skill's JSON output against assertions in `evals.json`:

- **Recall** — did the skill find the expected rule violations?
- **Precision** — did it avoid flagging unexpected rules?
- **File match** — did it identify the correct file?
- **Finding count** — is the count within the expected min/max bounds?
- **Coverage** — did the agent actually evaluate the rules in `expected_coverage`? Every other check
  above is satisfied by an agent that skipped the rule entirely; this one is not. A rule that comes
  back `not_applicable`, or that is missing from `coverage.json` altogether, fails the assertion.

### Eval categories

Category names below are the literal `category` values in `evals.json`, so counts can be regenerated rather than
maintained by hand:

```bash
grep -o '"category": "[^"]*"' evals/evals.json | sort | uniq -c
```

| Category           | Purpose                                                      |
|--------------------|--------------------------------------------------------------|
| `controller`       | CTL-* rule detection                                         |
| `api`              | API-* rule detection                                         |
| `config`           | CFG, NAM, XREPO, SYNC-010..030 rule detection                |
| `sync`             | SYNC-040..070 — ODH build tags, hook pairs, RBAC isolation   |
| `security`         | SEC-* rule detection                                         |
| `bug-pattern`      | BUG-* rule detection                                         |
| `migration`        | MIG-* rule detection                                         |
| `testing`          | TST-* rule detection                                         |
| `negative`         | Clean code — should produce zero or near-zero findings       |
| `routing`          | File classification reaches the intended reviewer            |
| `integration`      | Multi-rule and multi-dimension detection in a single review  |
| `security-hardening` | Prompt injection resistance — injected instructions in diffs |

### Adding a new eval

1. Create a fixture script in `evals/fixtures/<id>.sh` following the pattern in existing fixtures
2. Add a corresponding entry to `evals/evals.json` with `id`, `category`, `description`, and `assertions`
3. Run the fixture to verify it sets up correctly: `bash evals/run-evals.sh <id>`

## Contributing

### Adding a new rule

1. Add the rule to `skills/model-serving-review/knowledge/review-rules.md` with a unique ID and severity
2. Add a concrete example to `skills/model-serving-review/knowledge/examples.md`
3. If the rule applies to a specific subsystem, add it to the relevant agent's "Rules to check" list
4. Test against a PR that should trigger the new rule

### Adding a checklist item

The checklist is the floor under the rules: every one of the 88 rules is gated on a code kind, so nothing else in the
plugin applies to a PR the rubric does not recognize. Items are synthesized by subtraction — a convention the project
states, minus what the linters fail on, minus what `make precommit` verifies, minus what a rule covers. An item must be
unconditional, checkable from the diff alone, and fixable by the author without a maintainer conversation. If deciding
whether it applies takes judgment, write a rule instead.

1. Run the subtraction against the target repo's `.golangci.yml` and its `precommit` target, not from memory
2. Add the item to `skills/model-serving-review/knowledge/checklist.md` — no rule IDs, the checker enforces this
3. Findings land as `LOCAL` at severity SHOULD with confidence capped at 75

A repo can carry its own without touching this plugin: the `**Checklist**:` section of its
`.github/PULL_REQUEST_TEMPLATE.md` and `.model-serving-review/checklist.md` are both picked up at review time and
appended to every agent bundle.

### Modifying an agent

Agent definitions are in `agents/`. Each has:

- **Frontmatter** — name, description, tools, hooks
- **System prompt** — what to check, how to access data, output format

After changes, test by running the full skill against a PR with known issues in that agent's domain.

## License

Apache-2.0
