#!/usr/bin/env bash
FIXTURE_NAME="negative-api-080-legit-zero-value"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/serving/v1alpha1/llm_scaling_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type ScalingSpec struct {
	// +required
	MaxReplicas int32 `json:"maxReplicas"`
}

type LLMScaling struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ScalingSpec `json:"spec,omitempty"`
}
GO
commit "initial scaling types"

write_file pkg/apis/serving/v1alpha1/llm_scaling_types.go <<'GO'
package v1alpha1

import metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

type ScalingSpec struct {
	// +required
	MaxReplicas int32 `json:"maxReplicas"`

	// MinReplicas is the lower bound for the autoscaler. Zero enables
	// scale-to-zero, which is a supported configuration.
	// +required
	// +kubebuilder:validation:Minimum=0
	MinReplicas int32 `json:"minReplicas"`

	// Annotations to merge onto the generated autoscaler object. An empty map
	// means "add nothing".
	// +optional
	Annotations map[string]string `json:"annotations,omitempty"`

	// TargetUtilizationPercent is the scaling target.
	// +optional
	// +kubebuilder:validation:Minimum=1
	// +kubebuilder:validation:Maximum=100
	TargetUtilizationPercent *int32 `json:"targetUtilizationPercent,omitempty"`
}

type LLMScaling struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              ScalingSpec `json:"spec,omitempty"`
}
GO
commit "add autoscaling bounds"

emit_repo
