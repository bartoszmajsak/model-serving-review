#!/usr/bin/env bash
FIXTURE_NAME="api-070-unsafe-numeric-types"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/serving/v1alpha1/llm_router_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type LLMRouterSpec struct {
	// +optional
	Replicas *int32 `json:"replicas,omitempty"`
}

type LLMRouter struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              LLMRouterSpec `json:"spec,omitempty"`
}
GO
commit "initial router types"

write_file pkg/apis/serving/v1alpha1/llm_router_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type LLMRouterSpec struct {
	// +optional
	Replicas *int32 `json:"replicas,omitempty"`

	// MaxConnections is the connection ceiling per router replica.
	// +optional
	MaxConnections int `json:"maxConnections,omitempty"`

	// Weight is the relative traffic weight for this router.
	// +optional
	Weight uint16 `json:"weight,omitempty"`

	// ScaleFactor multiplies the computed queue depth.
	// +optional
	ScaleFactor float64 `json:"scaleFactor,omitempty"`

	// Timeout for upstream requests, in seconds.
	// +optional
	Timeout int64 `json:"timeout,omitempty"`
}

type LLMRouter struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              LLMRouterSpec `json:"spec,omitempty"`
}
GO
commit "add router tuning fields"

emit_repo
