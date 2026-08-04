#!/usr/bin/env bash
# Precision: pod does not set automountServiceAccountToken, but its dedicated
# ServiceAccount already sets it to false — the setting is inherited.
# Must NOT be flagged as SEC-090.
FIXTURE_NAME="negative-sec-090-sa-disables-automount"
source "$(dirname "$0")/common.sh"
init_repo
write_file config/llmisvcconfig/config-llm-cache.yaml <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-cache-warmer
automountServiceAccountToken: false
YAML
commit "initial cache warmer service account"
write_file config/llmisvcconfig/config-llm-cache.yaml <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kserve-cache-warmer
automountServiceAccountToken: false
---
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-cache
spec:
  template:
    serviceAccountName: kserve-cache-warmer
    containers:
      - name: cache-warmer
        image: kserve-cache-warmer:latest
        args:
          - --source=http://127.0.0.1:8080/models
YAML
commit "add cache warmer using the dedicated service account"
emit_repo
