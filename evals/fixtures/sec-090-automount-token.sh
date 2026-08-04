#!/usr/bin/env bash
# SEC-090: brand-new sidecar workload, no K8s API calls, default SA + automounted token.
FIXTURE_NAME="sec-090-automount-token"
source "$(dirname "$0")/common.sh"
init_repo
write_file config/llmisvcconfig/config-llm-metrics.yaml <<'YAML'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-metrics
spec: {}
YAML
commit "initial metrics config"
write_file config/llmisvcconfig/config-llm-metrics.yaml <<'YAML'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-metrics
spec:
  template:
    containers:
      - name: metrics-exporter
        image: kserve-metrics-exporter:latest
        ports:
          - containerPort: 9090
            name: metrics
        args:
          - --scrape-target=http://127.0.0.1:8080/metrics
YAML
commit "add metrics exporter sidecar"
emit_repo
