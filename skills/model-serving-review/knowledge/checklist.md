# Base checklist

The floor under the rubric. Every rule in `review-rules.md` is gated on a code kind — the broadest of
the 88 still only applies to reconciler code — so nothing in this plugin applies to *every* PR. These
items do.

A checklist item is what is left after subtracting the machines:

```
checklist item = a convention the project states
               - anything the linter config already fails on
               - anything `make precommit` already regenerates or verifies
               - anything the 88 rules already cover
```

The subtraction is not optional. KServe enables 47 golangci linters, and `make precommit` runs
boilerplate headers, code generation, manifests, `go mod tidy`, action pinning and CRD sync — all of
it before a reviewer opens the diff. Restating any of it here produces a finding the author has
already seen from CI, which is exactly how a review bot gets muted.

**The bar.** An item qualifies only if it is unconditional, checkable from the diff alone, and fixable
by the author without a maintainer conversation. **If deciding whether it applies takes judgment, it
is a rule, not a checklist item.** That test is what stops this file from silting up into a second,
worse rubric.

**How findings from here are reported.** Tagged `LOCAL`, never a rule ID. Severity is at most SHOULD
and confidence is capped at 75, because no eval fixture validates these the way fixtures validate
rules. A checklist item never suppresses a rule, and never outranks one.

**Do not cite a rule ID in this file.** An item that restates a rule produces the same defect twice
under two labels, and the merge step cannot collapse them — `LOCAL` is in no overlap class. If an item
needs a rule's authority to be worth reporting, it belongs in `review-rules.md` instead.

## Items

- **A behavior change ships with a test that exercises it.** A new code path, flag, field, or changed
  default needs something in the diff that fails when the change is reverted. Tests that only assert
  the code compiles or that re-state the implementation do not count. (The rubric already covers the
  narrower case of a bug fix without a regression test; this is the feature half of the same ask, and
  it is the one the PR template puts first.)

- **A value nobody can derive says why it has that value.** A timeout, retry count, buffer size, magic
  string, or workaround introduced by the diff carries a comment explaining the choice — where the
  number came from, or what breaks without it. This is the diff-checkable half of "has code been
  commented, particularly in hard-to-understand areas": not a demand for prose, just for the one thing
  a future reader cannot reconstruct.

- **A user-facing change points at its documentation.** New API field, new flag, changed default,
  changed error message a user acts on. KServe docs live in the separate `kserve/website` repo, so
  the change cannot be in this diff — the PR has to say where it is, or that none is needed. Flag the
  silence, not the missing file.

- **An image version bump is the only thing in its PR.** If the diff changes an image tag or digest —
  `params.env`, a kustomization, a chart value, a manifest — nothing else may ride along. This is the
  repo's own instruction to reviewers, and the reason is release mechanics: an image bump has to be
  revertable on its own.

## Maintaining this file

Before adding an item, run the subtraction against the target repo, not from memory: read its
`.golangci.yml` enabled list and its `precommit` target. An item that overlaps either is a defect in
the item.

Repo-local checklists are picked up at review time from the target repo — `.github/PULL_REQUEST_TEMPLATE.md`
and `.model-serving-review/checklist.md` — and are held to the same bar. Nothing here needs editing to
review a fork or the midstream.
