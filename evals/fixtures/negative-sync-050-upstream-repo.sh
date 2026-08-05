#!/usr/bin/env bash
# Same change shape as sync-050-untagged-ocp-import, but on kserve/kserve.
# SYNC rules are midstream-only conventions and must not fire here.
FIXTURE_NAME="negative-sync-050-upstream-repo"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/kserve/kserve.git"

write_file pkg/controller/v1beta1/inferenceservice/controller.go <<'GO'
package inferenceservice

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type InferenceServiceReconciler struct{}

func (r *InferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	return ctrl.Result{}, nil
}
GO
commit "initial controller"

write_file pkg/controller/v1beta1/inferenceservice/controller.go <<'GO'
package inferenceservice

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

//+kubebuilder:rbac:groups=route.openshift.io,resources=routes,verbs=get;list;watch

type InferenceServiceReconciler struct{}

func (r *InferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if err := r.reconcileRoute(ctx, req); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *InferenceServiceReconciler) reconcileRoute(ctx context.Context, req ctrl.Request) error {
	return nil
}
GO
commit "add route reconciliation"

emit_repo
