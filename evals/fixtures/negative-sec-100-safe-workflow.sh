#!/usr/bin/env bash
# Precision: pull_request_target used the way kserve already uses it.
# SHA-pinned action, ref: master (not PR head), event data via env, scoped permissions.
# Must NOT be flagged as SEC-100.
FIXTURE_NAME="negative-sec-100-safe-workflow"
source "$(dirname "$0")/common.sh"
init_repo
write_file .github/workflows/pr-title-check.yml <<'YAML'
name: PR Title Check
on:
  pull_request_target:
permissions:
  contents: read
jobs:
  title:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
        with:
          ref: master
YAML
commit "initial title check"
write_file .github/workflows/pr-title-check.yml <<'YAML'
name: PR Title Check
on:
  pull_request_target:
permissions:
  contents: read
jobs:
  title:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
        with:
          ref: master
      - name: Validate conventional commit prefix
        # Do not use ${{ github.event.pull_request.title }} directly in run command.
        env:
          TITLE: ${{ github.event.pull_request.title }}
        run: |
          if ! echo "$TITLE" | grep -qE '^(feat|fix|docs|chore)(\(.+\))?: '; then
            echo "PR title must use a conventional commit prefix"
            exit 1
          fi
YAML
commit "validate PR title prefix"
emit_repo
