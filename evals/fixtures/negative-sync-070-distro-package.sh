#!/usr/bin/env bash
FIXTURE_NAME="negative-sync-070-distro-package"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/opendatahub-io/kserve.git"

write_file pkg/controller/v1alpha2/llmisvc/controller.go <<'GO'
package llmisvc

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

//+kubebuilder:rbac:groups=serving.kserve.io,resources=llminferenceservices,verbs=get;list;watch

type LLMISVCReconciler struct{}

func (r *LLMISVCReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO

write_file pkg/controller/v1alpha2/llmisvc/distro/controller_rbac_odh.go <<'GO'
// Package distro carries midstream-only kubebuilder RBAC markers.
//
// It has no build tag on purpose: controller-gen must scan it in every build
// configuration, and the file contains no executable code for a build
// constraint to exclude. Makefile.overrides.mk runs a separate controller-gen
// invocation over this package to produce the ODH-only ClusterRole.
package distro

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch
GO
commit "initial controller with distro rbac package"

write_file pkg/controller/v1alpha2/llmisvc/distro/controller_rbac_odh.go <<'GO'
// Package distro carries midstream-only kubebuilder RBAC markers.
//
// It has no build tag on purpose: controller-gen must scan it in every build
// configuration, and the file contains no executable code for a build
// constraint to exclude. Makefile.overrides.mk runs a separate controller-gen
// invocation over this package to produce the ODH-only ClusterRole.
package distro

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch
//+kubebuilder:rbac:groups=infrastructure.opendatahub.io,resources=hardwareprofiles,verbs=get;list;watch
GO
commit "grant hardware profile read access to the ODH role"

emit_repo
