#!/usr/bin/env bash
# One defect, two agents, two rules: the reconciler adds an env var to the pod
# template, which controller-reviewer sees as CTL-100 and safety-reviewer as
# BUG-010 ("See CTL-100 for the core rule"). The single hunk is deliberate —
# anything else in the diff would give the agents a second thing to report and
# the max_findings assertion could no longer prove the merge happened.
FIXTURE_NAME="dedup-ctl-100-bug-010"
source "$(dirname "$0")/common.sh"
init_repo

write_file pkg/controller/modelcar_reconciler.go <<'GO'
package controller

import (
	"context"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
)

func (r *ModelcarReconciler) buildContainer(svc *InferenceService) corev1.Container {
	return corev1.Container{
		Name:  "modelcar",
		Image: svc.Spec.Modelcar.Image,
		Env: []corev1.EnvVar{
			{Name: "MODEL_DIR", Value: "/mnt/models"},
		},
	}
}

func (r *ModelcarReconciler) reconcileDeployment(ctx context.Context, svc *InferenceService, deployment *appsv1.Deployment) error {
	deployment.Spec.Template.Spec.Containers = []corev1.Container{r.buildContainer(svc)}
	return r.Client.Update(ctx, deployment)
}
GO
commit "initial modelcar reconciler"

write_file pkg/controller/modelcar_reconciler.go <<'GO'
package controller

import (
	"context"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
)

func (r *ModelcarReconciler) buildContainer(svc *InferenceService) corev1.Container {
	return corev1.Container{
		Name:  "modelcar",
		Image: svc.Spec.Modelcar.Image,
		Env: []corev1.EnvVar{
			{Name: "MODEL_DIR", Value: "/mnt/models"},
			{Name: "KSERVE_CONTROLLER_VERSION", Value: controllerVersion},
		},
	}
}

func (r *ModelcarReconciler) reconcileDeployment(ctx context.Context, svc *InferenceService, deployment *appsv1.Deployment) error {
	deployment.Spec.Template.Spec.Containers = []corev1.Container{r.buildContainer(svc)}
	return r.Client.Update(ctx, deployment)
}
GO
commit "stamp the controller version into the modelcar container"

emit_repo
