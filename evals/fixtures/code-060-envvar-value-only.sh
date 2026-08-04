#!/usr/bin/env bash
# CODE-060: escape-hatch detection reads EnvVar.Value only, missing ValueFrom.
FIXTURE_NAME="code-060-envvar-value-only"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/engine_args.go <<'GO'
package llmisvc

import corev1 "k8s.io/api/core/v1"

func injectEngineArgs(container *corev1.Container, args string) {
	container.Env = append(container.Env, corev1.EnvVar{Name: "VLLM_ARGS", Value: args})
}
GO
commit "initial engine arg injection"
write_file pkg/controller/llmisvc/engine_args.go <<'GO'
package llmisvc

import corev1 "k8s.io/api/core/v1"

// injectEngineArgs sets VLLM_ARGS unless the user already provided their own value.
func injectEngineArgs(container *corev1.Container, args string) {
	for _, e := range container.Env {
		if e.Name == "VLLM_ARGS" && e.Value != "" {
			// User opted out by setting the variable themselves.
			return
		}
	}
	container.Env = append(container.Env, corev1.EnvVar{Name: "VLLM_ARGS", Value: args})
}
GO
commit "let users override VLLM_ARGS"
emit_repo
