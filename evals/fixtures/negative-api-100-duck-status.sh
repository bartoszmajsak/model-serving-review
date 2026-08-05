#!/usr/bin/env bash
FIXTURE_NAME="negative-api-100-duck-status"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/apis/serving/v1alpha2/llm_inference_service_types.go <<'GO'
package v1alpha2

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	duckv1 "knative.dev/pkg/apis/duck/v1"
)

type LLMInferenceServiceSpec struct {
	// +optional
	Replicas *int32 `json:"replicas,omitempty"`
}

type LLMInferenceServiceStatus struct {
	duckv1.Status `json:",inline"`
}

type LLMInferenceService struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`
	Spec              LLMInferenceServiceSpec   `json:"spec,omitempty"`
	Status            LLMInferenceServiceStatus `json:"status,omitempty"`
}
GO

write_file pkg/apis/serving/v1alpha2/llm_inference_service_lifecycle.go <<'GO'
package v1alpha2

import "knative.dev/pkg/apis"

const (
	WorkloadReady apis.ConditionType = "WorkloadReady"
	RouterReady   apis.ConditionType = "RouterReady"
)

var conditionSet = apis.NewLivingConditionSet(WorkloadReady, RouterReady)

func (s *LLMInferenceServiceStatus) MarkWorkloadReady() {
	conditionSet.Manage(s).MarkTrue(WorkloadReady)
}
GO
commit "initial llmisvc types"

write_file pkg/apis/serving/v1alpha2/llm_inference_service_lifecycle.go <<'GO'
package v1alpha2

import "knative.dev/pkg/apis"

const (
	WorkloadReady apis.ConditionType = "WorkloadReady"
	RouterReady   apis.ConditionType = "RouterReady"
	// SchedulerReady tracks the inference scheduler deployment.
	SchedulerReady apis.ConditionType = "SchedulerReady"
)

var conditionSet = apis.NewLivingConditionSet(WorkloadReady, RouterReady, SchedulerReady)

func (s *LLMInferenceServiceStatus) MarkWorkloadReady() {
	conditionSet.Manage(s).MarkTrue(WorkloadReady)
}

func (s *LLMInferenceServiceStatus) MarkSchedulerNotReady(reason, messageFormat string, args ...interface{}) {
	conditionSet.Manage(s).MarkFalse(SchedulerReady, reason, messageFormat, args...)
}
GO
commit "add scheduler readiness condition"

emit_repo
