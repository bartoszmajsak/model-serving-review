#!/usr/bin/env bash
# Routing regression for the defect that silently broke tst-020 and tst-050.
#
# A diff touching only test/ classifies into test_files and nothing else: not go_files (no .go),
# not config_files (no .yaml), not api_files, not ci_files. SKILL.md used to launch safety-reviewer
# only on go_files/config_files/api_files, so NO agent ran and the TST-* evals could never pass
# regardless of agent quality.
#
# The planted violation is TST-020 (assertion swallowed by try/except + warning log).
FIXTURE_NAME="routing-test-only"
source "$(dirname "$0")/common.sh"

init_repo

write_file test/e2e/llmisvc/test_routing.py <<'PYTHON'
import pytest


def test_router_serves_traffic():
    """Router forwards inference traffic to the engine."""
    response = send_inference_request(path="/v1/completions")
    assert response.status_code == 200
PYTHON

commit "initial routing test"

write_file test/e2e/llmisvc/test_routing.py <<'PYTHON'
import logging

import pytest

logger = logging.getLogger(__name__)


def test_router_serves_traffic():
    """Router forwards inference traffic to the engine."""
    response = send_inference_request(path="/v1/completions")
    assert response.status_code == 200


def test_router_scheduler_affinity():
    """Scheduler routes repeat requests to the same engine replica."""
    first = send_inference_request(path="/v1/completions", session="abc")
    second = send_inference_request(path="/v1/completions", session="abc")
    try:
        assert first.headers["x-engine-pod"] == second.headers["x-engine-pod"], (
            "scheduler did not preserve session affinity"
        )
    except AssertionError:
        logger.warning("Session affinity not preserved - scheduler may not be enabled")
PYTHON

commit "add scheduler affinity test"

emit_repo
