#!/usr/bin/env bash
FIXTURE_NAME="api-100-phase-and-bare-conditions"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/gie/v1alpha2/inference_pool_types.go <<'GO'
package v1alpha2

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type InferencePoolSpec struct {
	// +optional
	Selector map[string]string `json:"selector,omitempty"`
}

type InferencePoolStatus struct{}

type InferencePool struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              InferencePoolSpec   `json:"spec,omitempty"`
	Status            InferencePoolStatus `json:"status,omitempty"`
}
GO
commit "initial inference pool types"

write_file pkg/apis/gie/v1alpha2/inference_pool_types.go <<'GO'
package v1alpha2

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type InferencePoolSpec struct {
	// +optional
	Selector map[string]string `json:"selector,omitempty"`
}

type InferencePoolStatus struct {
	// Conditions describe the current state of the pool.
	// +optional
	Conditions []metav1.Condition `json:"conditions,omitempty"`

	// Phase is a coarse summary of the pool state.
	// One of: Pending, Provisioning, Ready, Failed.
	// +optional
	Phase string `json:"phase,omitempty"`
}

type InferencePool struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              InferencePoolSpec   `json:"spec,omitempty"`
	Status            InferencePoolStatus `json:"status,omitempty"`
}
GO
commit "add pool status conditions and phase"

emit_repo
