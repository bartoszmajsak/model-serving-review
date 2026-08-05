#!/usr/bin/env bash
# Negative CODE-070: strategic merge for the user-settable container, wholesale
# assignment only for a child Service the controller fully owns.
FIXTURE_NAME="negative-code-070-owned-child"
source "$(dirname "$0")/common.sh"
init_repo
write_file pkg/controller/llmisvc/workload_storage.go <<'GO'
package llmisvc

import corev1 "k8s.io/api/core/v1"

func applyStorageContainer(initContainer *corev1.Container, userSpec *corev1.Container) error {
	return nil
}
GO
commit "storage container hook"
write_file pkg/controller/llmisvc/workload_storage.go <<'GO'
package llmisvc

import (
	"fmt"

	corev1 "k8s.io/api/core/v1"

	"github.com/kserve/kserve/pkg/utils"
)

// applyStorageContainer applies the user's ClusterStorageContainer overrides on top
// of the controller-built storage initializer.
func applyStorageContainer(initContainer *corev1.Container, userSpec *corev1.Container) error {
	if userSpec == nil {
		return nil
	}
	merged, err := utils.MergeContainerWithPatch(*initContainer, *userSpec)
	if err != nil {
		return fmt.Errorf("failed to merge storage container spec: %w", err)
	}
	*initContainer = merged
	return nil
}

// headlessService is created and owned entirely by the controller — there is no
// user-facing override path for it.
func headlessService(name string, ports []corev1.ServicePort) *corev1.Service {
	svc := &corev1.Service{}
	svc.Name = name
	svc.Spec.ClusterIP = corev1.ClusterIPNone
	svc.Spec.Ports = ports
	return svc
}
GO
commit "merge user storage container overrides"
emit_repo
