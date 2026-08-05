#!/usr/bin/env bash
# Negative CFG-050: guarded base template plus a preset that legitimately assumes parallelism is set.
FIXTURE_NAME="negative-cfg-050-guarded-and-preset"
source "$(dirname "$0")/common.sh"
init_repo
write_file config/llmisvcconfig/base-vllm.yaml <<'YAML'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-template
spec:
  template:
    containers:
      - name: main
        args:
          - --model={{ .Spec.Model.URI }}
YAML
commit "base vllm template"
write_file config/llmisvcconfig/base-vllm.yaml <<'YAML'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-template
spec:
  template:
    containers:
      - name: main
        args:
          - --model={{ .Spec.Model.URI }}
          {{- if and .Spec.Parallelism .Spec.Parallelism.Tensor }}
          - --tensor-parallel-size={{ .Spec.Parallelism.Tensor }}
          {{- end }}
          - --shutdown-timeout={{ if .Spec.Prefill }}{{ shutdownTimeout .Spec.Prefill.Template 15 }}{{ else }}{{ shutdownTimeout nil 15 }}{{ end }}
YAML
write_file config/llmisvcconfig/base-vllm-worker-data-parallel.yaml <<'YAML'
apiVersion: serving.kserve.io/v1alpha2
kind: LLMInferenceServiceConfig
metadata:
  name: kserve-config-llm-worker-data-parallel
spec:
  # Only selected by an LLMInferenceService that configures spec.parallelism,
  # so the parent is guaranteed non-nil here.
  template:
    containers:
      - name: main
        args:
          - --data-parallel-size={{ .Spec.Parallelism.Data }}
YAML
commit "add guarded parallelism args and the data-parallel worker preset"
emit_repo
