#!/usr/bin/env bash
# CFG-050: llmisvcconfig template dereferences the optional *ParallelismSpec parent unguarded.
FIXTURE_NAME="cfg-050-unguarded-template-parent"
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
          - --tensor-parallel-size={{ .Spec.Parallelism.Tensor }}
          - --data-parallel-size={{ or .Spec.Parallelism.Data 1 }}
          - --shutdown-timeout={{ shutdownTimeout .Spec.Prefill.Template 15 }}
YAML
commit "wire parallelism into the base template"
emit_repo
