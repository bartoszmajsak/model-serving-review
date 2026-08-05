#!/usr/bin/env bash
FIXTURE_NAME="sync-050-untagged-ocp-import"
source "$(dirname "$0")/common.sh"
init_repo "https://github.com/opendatahub-io/kserve.git"

write_file pkg/controller/v1beta1/inferenceservice/controller.go <<'GO'
package inferenceservice

import (
	"context"

	ctrl "sigs.k8s.io/controller-runtime"
)

type InferenceServiceReconciler struct{}

func (r *InferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if err := r.reconcileDeployment(ctx, req); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *InferenceServiceReconciler) reconcileDeployment(ctx context.Context, req ctrl.Request) error {
	return nil
}
GO
commit "initial controller"

write_file pkg/controller/v1beta1/inferenceservice/controller.go <<'GO'
package inferenceservice

import (
	"context"

	routev1 "github.com/openshift/api/route/v1"
	ctrl "sigs.k8s.io/controller-runtime"
)

type InferenceServiceReconciler struct{}

func (r *InferenceServiceReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	if err := r.reconcileDeployment(ctx, req); err != nil {
		return ctrl.Result{}, err
	}
	// ODH only: expose the predictor through an OpenShift Route
	if err := r.reconcileODHRoute(ctx, req); err != nil {
		return ctrl.Result{}, err
	}
	return ctrl.Result{}, nil
}

func (r *InferenceServiceReconciler) reconcileDeployment(ctx context.Context, req ctrl.Request) error {
	return nil
}

func (r *InferenceServiceReconciler) reconcileODHRoute(ctx context.Context, req ctrl.Request) error {
	route := &routev1.Route{}
	_ = route
	// applyHardwareProfile is midstream-only
	return nil
}
GO
commit "expose predictor via OpenShift Route"

emit_repo
