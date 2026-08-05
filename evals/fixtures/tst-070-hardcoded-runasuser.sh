#!/usr/bin/env bash
FIXTURE_NAME="tst-070-hardcoded-runasuser"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/opendatahub-io/kserve.git"

write_file test/e2e/llmisvc/fixtures.py <<'PY'
import os

RUN_AS_NON_ROOT = os.environ.get("RUN_AS_NON_ROOT", "false").lower() == "true"

LLMD_SIMULATOR_SECURITY_CONTEXT = (
    {"runAsNonRoot": True, "allowPrivilegeEscalation": False}
    if RUN_AS_NON_ROOT
    else {}
)


def create_service_account_with_inference_access(name, namespace=None):
    namespace = namespace or os.environ.get("KSERVE_TEST_NAMESPACE", "kserve-ci-e2e-test")
    ...
PY
commit "initial e2e fixtures"

write_file test/e2e/llmisvc/test_llm_auth.py <<'PY'
from .fixtures import create_service_account_with_inference_access

SECURITY_CONTEXT = {
    "runAsNonRoot": True,
    "runAsUser": 65532,
    "runAsGroup": 65532,
}


def test_llm_auth_enabled(test_case):
    sa_name = "llm-auth-sa"
    create_service_account_with_inference_access(sa_name)

    container = {
        "name": "main",
        "image": "quay.io/llm-d/simulator:latest",
        "command": ["/app/simulator"],
        "args": ["--port", "8000"],
        "securityContext": SECURITY_CONTEXT,
    }
    deploy_llmisvc(test_case, container, enable_tls=True)
    assert_inference_succeeds(test_case, sa_name)
PY
commit "add llm auth e2e test"

emit_repo
