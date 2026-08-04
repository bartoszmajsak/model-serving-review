#!/usr/bin/env bash
# CTL-130: volume names derived from a list index flow into the pod template.
FIXTURE_NAME="ctl-130-index-derived-name"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/workload.go <<'GO'
package llmisvc

import corev1 "k8s.io/api/core/v1"

func adapterVolumes(llmSvc *LLMInferenceService) []corev1.Volume {
	return nil
}
GO
commit "initial workload builder"
write_file pkg/controller/llmisvc/workload.go <<'GO'
package llmisvc

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"
)

func adapterVolumes(llmSvc *LLMInferenceService) []corev1.Volume {
	volumes := make([]corev1.Volume, 0, len(llmSvc.Spec.Model.Adapters))
	for i, adapter := range llmSvc.Spec.Model.Adapters {
		volumes = append(volumes, corev1.Volume{
			Name: fmt.Sprintf("adapter-%d", i),
			VolumeSource: corev1.VolumeSource{
				PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
					ClaimName: adapter.ClaimName,
				},
			},
		})
	}
	return volumes
}

func adapterMounts(llmSvc *LLMInferenceService) []corev1.VolumeMount {
	mounts := make([]corev1.VolumeMount, 0, len(llmSvc.Spec.Model.Adapters))
	for i, adapter := range llmSvc.Spec.Model.Adapters {
		mounts = append(mounts, corev1.VolumeMount{
			Name:      fmt.Sprintf("adapter-%d", i),
			MountPath: "/mnt/adapters/" + adapter.Name,
		})
	}
	return mounts
}
GO
commit "mount model adapters into the engine pod"
emit_repo
