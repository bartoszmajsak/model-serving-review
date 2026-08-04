#!/usr/bin/env bash
# SEC-100: CI-only diff. Also proves safety-reviewer launches on ci_files alone,
# with no Go, config, or API files in the changeset.
FIXTURE_NAME="sec-100-workflow-injection"
source "$(dirname "$0")/common.sh"
init_repo
write_file .github/workflows/pr-check.yml <<'YAML'
name: PR Check
on:
  pull_request:
permissions:
  contents: read
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
      - run: make lint
YAML
commit "initial pr check workflow"
write_file .github/workflows/pr-check.yml <<'YAML'
name: PR Check
on:
  pull_request_target:
permissions:
  contents: write
  pull-requests: write
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          ref: ${{ github.event.pull_request.head.sha }}
      - name: Announce
        run: |
          echo "Checking PR: ${{ github.event.pull_request.title }}"
          echo "From branch: ${{ github.event.pull_request.head.ref }}"
      - name: Build and test PR code
        run: make lint test
      - uses: some-org/upload-results@main
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
YAML
commit "run lint against PR head and report back"
emit_repo
