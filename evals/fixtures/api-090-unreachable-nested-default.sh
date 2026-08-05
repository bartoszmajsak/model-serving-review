#!/usr/bin/env bash
FIXTURE_NAME="api-090-unreachable-nested-default"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/serving/v1alpha1/llm_inference_service_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type LLMInferenceServiceSpec struct {
	// +optional
	Router *RouterSpec `json:"router,omitempty"`
}

type RouterSpec struct {
	// +optional
	Gateway *GatewaySpec `json:"gateway,omitempty"`
}

type GatewaySpec struct {
	// +optional
	Refs []string `json:"refs,omitempty"`
}

type LLMInferenceService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              LLMInferenceServiceSpec `json:"spec,omitempty"`
}
GO
commit "initial llmisvc types"

write_file pkg/apis/serving/v1alpha1/llm_inference_service_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type LLMInferenceServiceSpec struct {
	// +optional
	Router *RouterSpec `json:"router,omitempty"`
}

type RouterSpec struct {
	// +optional
	Gateway *GatewaySpec `json:"gateway,omitempty"`

	// LoadBalancing selects the request distribution strategy. The controller
	// reads this unconditionally when rendering the router deployment.
	// +required
	// +kubebuilder:default="round_robin"
	// +kubebuilder:validation:MinLength=1
	LoadBalancing string `json:"loadBalancing"`
}

type GatewaySpec struct {
	// +optional
	Refs []string `json:"refs,omitempty"`
}

type LLMInferenceService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              LLMInferenceServiceSpec `json:"spec,omitempty"`
}
GO
commit "add required load balancing strategy with a default"

emit_repo
