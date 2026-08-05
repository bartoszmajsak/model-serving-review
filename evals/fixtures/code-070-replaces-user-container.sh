#!/usr/bin/env bash
# CODE-070: controller assigns fields from the user's storage container spec instead of merging it.
FIXTURE_NAME="code-070-replaces-user-container"
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

import corev1 "k8s.io/api/core/v1"

// applyStorageContainer applies the user's ClusterStorageContainer overrides on top
// of the controller-built storage initializer.
func applyStorageContainer(initContainer *corev1.Container, userSpec *corev1.Container) error {
	if userSpec == nil {
		return nil
	}
	if userSpec.Image != "" {
		initContainer.Image = userSpec.Image
	}
	if len(userSpec.Env) > 0 {
		initContainer.Env = userSpec.Env
	}
	if len(userSpec.VolumeMounts) > 0 {
		initContainer.VolumeMounts = userSpec.VolumeMounts
	}
	initContainer.Resources = userSpec.Resources
	return nil
}
GO
commit "let ClusterStorageContainer override the storage initializer"
emit_repo
